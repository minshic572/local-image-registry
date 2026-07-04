#!/usr/bin/env bash
#
# registry-connect-kind.sh - Connect local registry to kind cluster
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-local-image-registry}"
KIND_CLUSTER="${DEFAULT_KIND_CLUSTER:-cyber-resilience}"
KIND_NETWORK="kind"
REGISTRY_HOST="local-image-registry"
REGISTRY_PORT=5000
REGISTRY_URL="http://${REGISTRY_HOST}:${REGISTRY_PORT}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Connect the local registry to a kind cluster so nodes can pull images
from it.

OPTIONS:
    --cluster NAME    Kind cluster name (default: cyber-resilience)
    --registry NAME   Registry container name (default: local-image-registry)
    -h, --help        Show this help message

REQUIREMENTS:
    - Docker must be running
    - Registry must be started (make start)
    - Kind cluster must exist (will NOT auto-create)
    - kubectl must be configured for the cluster

EXIT CODES:
    0 - Successfully connected registry to cluster
    1 - Error (cluster doesn't exist, registry not running, config failed)
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster)
                KIND_CLUSTER="$2"
                shift 2
                ;;
            --registry)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    echo "=== Connecting Registry to Kind Cluster ===" >&2
    echo "" >&2
    echo "  Cluster: ${KIND_CLUSTER}" >&2
    echo "  Registry: ${CONTAINER_NAME}" >&2
    echo "  Registry URL: ${REGISTRY_URL}" >&2
    echo "" >&2

    check_kind_cluster
    check_registry_running
    connect_registry_to_kind_network

    local failed=0
    configure_containerd_on_nodes || failed=$?

    create_configmap
    verify_connection || true

    echo "" >&2
    if [[ ${failed} -eq 0 ]]; then
        echo "[READY] Registry connected to kind cluster '${KIND_CLUSTER}'" >&2
        echo "" >&2
        echo "Usage:" >&2
        echo "  Pull images using: ${REGISTRY_HOST}:${REGISTRY_PORT}/image:tag" >&2
        echo "" >&2
        echo "Example:" >&2
        echo "  kubectl run test --image=${REGISTRY_HOST}:${REGISTRY_PORT}/myimage:tag" >&2
    else
        echo "[WARN] Registry connected, but some node configuration failed" >&2
        echo "[INFO] Some nodes may not be able to pull from local registry" >&2
        exit 1
    fi
}

check_kind_cluster() {
    echo "[CHECK] Verifying kind cluster '${KIND_CLUSTER}' exists..." >&2

    if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
        echo "[ERROR] Kind cluster '${KIND_CLUSTER}' does not exist." >&2
        echo "" >&2
        echo "Please create it first with:" >&2
        echo "  kind create cluster --name ${KIND_CLUSTER}" >&2
        echo "" >&2
        echo "This script will NOT auto-create the cluster." >&2
        exit 1
    fi
    echo "[OK] Cluster found" >&2
}

check_registry_running() {
    echo "[CHECK] Verifying registry is running..." >&2

    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "[ERROR] Registry container '${CONTAINER_NAME}' does not exist." >&2
        echo "" >&2
        echo "Please start it first with:" >&2
        echo "  make start" >&2
        exit 1
    fi

    if ! docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q "true"; then
        echo "[ERROR] Registry container '${CONTAINER_NAME}' is not running." >&2
        echo "" >&2
        echo "Please start it first with:" >&2
        echo "  make start" >&2
        exit 1
    fi
    echo "[OK] Registry is running" >&2
}

connect_registry_to_kind_network() {
    echo "[CONFIG] Connecting registry to kind network..." >&2

    if ! docker network inspect "${KIND_NETWORK}" >/dev/null 2>&1; then
        echo "  Creating network '${KIND_NETWORK}'..." >&2
        if ! docker network create "${KIND_NETWORK}" >/dev/null 2>&1; then
            echo "[ERROR] Failed to create kind network" >&2
            exit 1
        fi
    else
        echo "  Network '${KIND_NETWORK}' exists" >&2
    fi

    if docker network inspect "${KIND_NETWORK}" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
        echo "  Registry already connected to kind network" >&2
    else
        echo "  Connecting registry to kind network..." >&2
        if ! docker network connect "${KIND_NETWORK}" "${CONTAINER_NAME}"; then
            echo "[ERROR] Failed to connect registry to kind network" >&2
            exit 1
        fi
    fi
    echo "[OK] Registry connected to kind network" >&2
}

configure_containerd_on_nodes() {
    echo "[CONFIG] Configuring containerd on kind nodes..." >&2

    # Get node containers using kind CLI
    local node_containers
    node_containers=$(kind get nodes --name "${KIND_CLUSTER}" 2>/dev/null) || true

    if [[ -z "${node_containers}" ]]; then
        echo "[ERROR] Could not get nodes from kind cluster" >&2
        return 1
    fi

    local failed_nodes=0

    while IFS= read -r node_container; do
        [[ -z "${node_container}" ]] && continue

        echo "  Configuring node: ${node_container}" >&2

        if ! configure_single_node "${node_container}"; then
            echo "    [FAIL] Failed to configure ${node_container}" >&2
            failed_nodes=$((failed_nodes + 1))
        fi
    done <<< "${node_containers}"

    if [[ ${failed_nodes} -gt 0 ]]; then
        echo "[WARN] ${failed_nodes} node(s) failed configuration" >&2
        return 1
    fi

    echo "[OK] Containerd configured on all nodes" >&2
    return 0
}

configure_single_node() {
    local node_container="$1"

    local config_dir="/etc/containerd/certs.d"
    local hosts_dir="${config_dir}/${REGISTRY_HOST}:${REGISTRY_PORT}"
    local hosts_toml="${hosts_dir}/hosts.toml"

    # Check if node container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${node_container}$"; then
        echo "    [SKIP] Container ${node_container} not running" >&2
        return 1
    fi

    # Create the config directory
    if ! docker exec "${node_container}" mkdir -p "${hosts_dir}" 2>/dev/null; then
        echo "    [FAIL] Could not create config directory" >&2
        return 1
    fi

    # Write hosts.toml with the registry URL pointing to the actual registry
    # Note: Using the DNS name "local-image-registry" which is resolvable
    # within the kind Docker network
    local toml_content="server = \"http://${REGISTRY_HOST}:${REGISTRY_PORT}\"

[host.\"${REGISTRY_URL}\"]
  capabilities = [\"pull\", \"resolve\"]
"

    if ! docker exec "${node_container}" sh -c "cat > '${hosts_toml}' << 'TOMLEOF'
${toml_content}
TOMLEOF" 2>/dev/null; then
        echo "    [FAIL] Could not write hosts.toml" >&2
        return 1
    fi

    if ! docker exec "${node_container}" chmod 644 "${hosts_toml}" 2>/dev/null; then
        echo "    [FAIL] Could not set permissions on hosts.toml" >&2
        return 1
    fi

    # Verify the file was written correctly
    if ! docker exec "${node_container}" test -f "${hosts_toml}"; then
        echo "    [FAIL] hosts.toml not found after write" >&2
        return 1
    fi

    echo "    [OK] hosts.toml configured" >&2
    return 0
}

create_configmap() {
    echo "[CONFIG] Creating/updating ConfigMap for registry hosting..." >&2

    # Create ConfigMap YAML
    local cm_yaml
    cm_yaml=$(cat <<YAMLEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    hostFromCluster: "local-image-registry:5000"
    hostFromContainerRuntime: "local-image-registry:5000"
    description: "Local image registry accessible from kind cluster nodes"
YAMLEOF
)

    # Use kubectl apply for idempotent create/update
    if ! echo "${cm_yaml}" | kubectl apply -f -; then
        echo "[ERROR] Failed to create/update ConfigMap" >&2
        exit 1
    fi

    echo "[OK] ConfigMap created/updated" >&2
}

verify_connection() {
    echo "[VERIFY] Checking registry connectivity from cluster..." >&2

    # Use an image from local registry if available
    # Try to pull from the local registry using a test image
    local random_id=$((RANDOM % 10000))

    # Try using localhost:5001 first (from pod's perspective, use the ConfigMap hint)
    # Since we're verifying connectivity, use wget from busybox to check if registry is reachable
    if kubectl run "registry-check-${random_id}" \
        --image=busybox:latest \
        --rm -i --restart=Never -- \
        sh -c "wget -q -O /dev/null --timeout=10 'http://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/' || echo 'failed'" 2>/dev/null | grep -qv "failed"; then
        echo "[OK] Registry is accessible from cluster pods" >&2
        return 0
    else
        echo "[WARN] Could not verify registry connectivity from cluster" >&2
        echo "[INFO] This may be normal if containerd hasn't reloaded config" >&2
        echo "[INFO] To verify manually, run:" >&2
        echo "[INFO]   docker exec ${CONTAINER_NAME} wget -q -O /dev/null --timeout=5 http://localhost:5000/v2/" >&2
        return 1
    fi
}

main "$@"
