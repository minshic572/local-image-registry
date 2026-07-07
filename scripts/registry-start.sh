#!/usr/bin/env bash
#
# registry-start.sh - Start local image registry using Docker
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-local-image-registry}"
HOST_PORT="${DEFAULT_REGISTRY_PORT:-5001}"
INTERNAL_PORT=5000
VOLUME_NAME="${CONTAINER_NAME}-data"

main() {
    echo "=== Starting Local Image Registry ==="

    if docker info >/dev/null 2>&1; then
        echo "[OK] Docker is running"
    else
        echo "[ERROR] Docker is not running. Please start Docker Desktop."
        exit 1
    fi

    if container_exists; then
        if container_running; then
            echo "[READY] Registry is already running"
            output_info
            exit 0
        else
            echo "[INFO] Container exists but is not running, starting it..."
            docker start "${CONTAINER_NAME}"
        fi
    else
        echo "[INFO] Creating new registry container..."
        docker run -d \
            --name "${CONTAINER_NAME}" \
            --restart=always \
            -p "${HOST_PORT}:${INTERNAL_PORT}" \
            -v "${VOLUME_NAME}:/var/lib/registry" \
            -e REGISTRY_STORAGE_DELETE_ENABLED=true \
            registry:2
    fi

    wait_for_registry
    echo ""
    echo "[READY] Registry started successfully"
    output_info
}

container_exists() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
    docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q "true"
}

wait_for_registry() {
    local max_attempts=30
    local attempt=1

    echo -n "[INFO] Waiting for registry to be ready"
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if curl -sf "http://localhost:${HOST_PORT}/v2/" >/dev/null 2>&1; then
            echo ""
            return 0
        fi
        echo -n "."
        sleep 1
        ((attempt++))
    done

    echo ""
    echo "[ERROR] Registry failed to become ready after ${max_attempts} seconds"
    exit 1
}

output_info() {
    echo ""
    echo "=== Registry Access Information ==="
    echo "  Host access (from host machine):"
    echo "    http://localhost:${HOST_PORT}"
    echo ""
    echo "  Docker network access (from containers):"
    echo "    http://${CONTAINER_NAME}:${INTERNAL_PORT}"
    echo ""
    echo "  Registry API:"
    echo "    http://localhost:${HOST_PORT}/v2/"
}

main "$@"
