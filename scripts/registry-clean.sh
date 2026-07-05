#!/usr/bin/env bash
#
# registry-clean.sh - Clear all images from registry (reset to clean state)
#
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-local-image-registry}"
VOLUME_NAME="${CONTAINER_NAME}-data"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clear all images from the local registry. This will:
1. Stop the registry container
2. Remove the registry data volume
3. Restart the registry

OPTIONS:
    --force    Skip confirmation prompt
    -h, --help Show this help message

EXAMPLES:
    $(basename "$0")           # With confirmation
    $(basename "$0") --force   # Skip confirmation

EOF
}

main() {
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
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

    echo "=== Clearing Registry Data ==="
    echo ""

    # Check if registry exists
    if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "[INFO] Registry container does not exist"
        echo "[INFO] Nothing to clean"
        exit 0
    fi

    # Show current state
    local image_count
    image_count=$(curl -sf "http://localhost:${DEFAULT_REGISTRY_PORT:-5001}/v2/_catalog" 2>/dev/null | \
        python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("repositories",[])))' 2>/dev/null || echo "0")

    echo "  Container: ${CONTAINER_NAME}"
    echo "  Volume: ${VOLUME_NAME}"
    echo "  Current images: ${image_count}"
    echo ""

    # Confirmation
    if [[ "${force}" != "true" ]]; then
        echo "This will DELETE all images in the registry."
        echo -n "Continue? [y/N] "
        local answer
        read -r answer
        if [[ "${answer}" != "y" ]] && [[ "${answer}" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo ""
    echo "[INFO] Stopping registry container..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true

    echo "[INFO] Removing registry container..."
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true

    echo "[INFO] Removing registry data volume..."
    docker volume rm "${VOLUME_NAME}" 2>/dev/null || true

    echo ""
    echo "[INFO] Restarting registry..."
    ./scripts/registry-start.sh

    echo ""
    echo "[OK] Registry cleaned and restarted"
    echo "    All images have been deleted"
}

main "$@"
