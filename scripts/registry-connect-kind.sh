#!/usr/bin/env bash
# Configure kind containerd to pull from Harbor running on Docker Desktop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

KIND_CLUSTER="${DEFAULT_KIND_CLUSTER:-cyber-resilience}"
REGISTRY_HOST="${HARBOR_HOSTNAME}"
REGISTRY_PORT="$(active_harbor_port)"
REGISTRY_URL="${HARBOR_SCHEME}://${REGISTRY_HOST}:${REGISTRY_PORT}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--cluster NAME]

Configure all nodes in a kind cluster to resolve and pull public images from
Harbor at ${REGISTRY_HOST}:${REGISTRY_PORT}.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster) KIND_CLUSTER="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done

    if ! kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
        echo "[ERROR] kind cluster '${KIND_CLUSTER}' does not exist." >&2
        exit 1
    fi

    local failed=0 node
    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        configure_node "${node}" || failed=$((failed + 1))
    done < <(kind get nodes --name "${KIND_CLUSTER}")

    create_configmap
    if [[ ${failed} -gt 0 ]]; then
        echo "[ERROR] Failed to configure ${failed} kind node(s)." >&2
        exit 1
    fi
    echo "[READY] kind cluster '${KIND_CLUSTER}' uses ${REGISTRY_HOST}:${REGISTRY_PORT}."
}

configure_node() {
    local node="$1"
    local hosts_dir="/etc/containerd/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT}"
    local gateway_ip
    gateway_ip=$(docker exec "${node}" getent hosts host.docker.internal 2>/dev/null | awk 'NR == 1 {print $1}')
    if [[ -z "${gateway_ip}" ]]; then
        echo "[FAIL] ${node}: Docker Desktop host gateway is not resolvable." >&2
        return 1
    fi

    echo "[CONFIG] ${node}: ${REGISTRY_HOST} -> ${gateway_ip}"
    docker exec "${node}" sh -c \
        "grep -q '[[:space:]]${REGISTRY_HOST}\$' /etc/hosts || printf '%s %s\\n' '${gateway_ip}' '${REGISTRY_HOST}' >> /etc/hosts"
    docker exec "${node}" mkdir -p "${hosts_dir}"

    local skip_verify="false"
    [[ "${HARBOR_INSECURE}" == "true" ]] && skip_verify="true"
    docker exec -i "${node}" sh -c "cat > '${hosts_dir}/hosts.toml'" <<EOF
server = "${REGISTRY_URL}"

[host."${REGISTRY_URL}"]
  capabilities = ["pull", "resolve"]
  skip_verify = ${skip_verify}
EOF
    docker exec "${node}" chmod 644 "${hosts_dir}/hosts.toml"
}

create_configmap() {
    kubectl --context "kind-${KIND_CLUSTER}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY_HOST}:${REGISTRY_PORT}"
    hostFromCluster: "${REGISTRY_HOST}:${REGISTRY_PORT}"
    hostFromContainerRuntime: "${REGISTRY_HOST}:${REGISTRY_PORT}"
    help: "https://goharbor.io/docs/"
EOF
}

main "$@"
