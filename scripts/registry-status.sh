#!/usr/bin/env bash
#
# registry-status.sh - Check local image registry status
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-local-image-registry}"
HOST_PORT="${DEFAULT_REGISTRY_PORT:-5001}"

main() {
    echo "=== Local Image Registry Status ==="
    echo ""

    check_docker
    check_container
    check_http
    check_catalog

    echo ""
    echo "=== End of Status Check ==="
}

check_docker() {
    echo -n "[CHECK] Docker is "
    if docker info >/dev/null 2>&1; then
        echo "running"
    else
        echo "NOT running"
        echo "[ERROR] Please start Docker Desktop" >&2
        exit 1
    fi
}

check_container() {
    echo -n "[CHECK] Container '${CONTAINER_NAME}' is "
    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "NOT found"
        echo "[INFO] Container does not exist. Run 'make start' to create it." >&2
        exit 1
    fi

    local state
    state=$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
    echo "${state}"

    if [[ "${state}" != "running" ]]; then
        echo "[WARN] Container exists but is not running" >&2
        echo "[INFO] Run 'make start' to start the registry" >&2
        exit 1
    fi
}

check_http() {
    echo -n "[CHECK] HTTP API at localhost:${HOST_PORT}/v2/ is "
    if curl -sf "http://localhost:${HOST_PORT}/v2/" >/dev/null 2>&1; then
        echo "accessible"
    else
        echo "NOT accessible"
        echo "[ERROR] Registry is not responding to HTTP requests" >&2
        exit 1
    fi
}

check_catalog() {
    echo -n "[CHECK] Registry catalog: "

    local catalog
    catalog=$(curl -sf "http://localhost:${HOST_PORT}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')

    # Parse JSON properly using python3 (available on macOS and Linux)
    local count
    count=$(echo "${catalog}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("repositories",[])))' 2>/dev/null || echo "0")

    if [[ "${count}" == "0" ]]; then
        echo "empty (no images synced yet)"
    else
        echo "${count} repository/repositories found"
        echo ""
        echo "  Repositories:"
        # Extract repository names using python3
        echo "${catalog}" | python3 -c 'import sys,json; d=json.load(sys.stdin); [print("    - " + r) for r in d.get("repositories",[])]' 2>/dev/null || true
    fi
}

main "$@"
