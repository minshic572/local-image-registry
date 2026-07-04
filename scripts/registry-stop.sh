#!/usr/bin/env bash
#
# registry-stop.sh - Stop local image registry
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-local-image-registry}"
VOLUME_NAME="${CONTAINER_NAME}-data"
PURGE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Stop the local image registry.

OPTIONS:
    --purge    Delete container and volume (all registry data will be lost)
    -h, --help Show this help message

EXAMPLES:
    $(basename "$0")              # Stop registry, keep data
    $(basename "$0") --purge      # Stop and delete registry, remove data
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)
                PURGE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo "=== Stopping Local Image Registry ==="

    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "[READY] Registry container does not exist, nothing to stop"
        exit 0
    fi

    if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q "true"; then
        echo "[INFO] Stopping container..."
        docker stop "${CONTAINER_NAME}"
        echo "[OK] Container stopped"
    else
        echo "[READY] Container exists but is not running"
    fi

    if [[ "${PURGE}" == "true" ]]; then
        echo "[INFO] Removing container..."
        docker rm "${CONTAINER_NAME}"

        if docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
            echo "[INFO] Removing volume..."
            docker volume rm "${VOLUME_NAME}"
        fi

        echo "[OK] Container and volume removed (all data deleted)"
    else
        echo "[OK] Registry stopped (data preserved)"
        echo "    Use '$(basename "$0") --purge' to delete data"
    fi
}

main "$@"
