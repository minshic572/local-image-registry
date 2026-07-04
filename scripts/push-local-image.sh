#!/usr/bin/env bash
#
# push-local-image.sh - Push local Docker image to local registry
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/output"

SOURCE_IMAGE=""
TARGET_IMAGE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Push a local Docker image to the local registry.

OPTIONS:
    --source IMAGE    Source image (e.g., cyber-resilience/platform-api:dev)
    --target IMAGE    Target image (e.g., localhost:5001/cyber-resilience/platform-api:dev)
    -h, --help       Show this help message

EXAMPLES:
    $(basename "$0") --source myapp:v1 --target localhost:5001/myapp:v1

    $(basename "$0") \\
        --source cyber-resilience/platform-api:dev \\
        --target localhost:5001/cyber-resilience/platform-api:dev
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                SOURCE_IMAGE="$2"
                shift 2
                ;;
            --target)
                TARGET_IMAGE="$2"
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

    if [[ -z "${SOURCE_IMAGE}" ]]; then
        echo "[ERROR] --source is required" >&2
        usage
        exit 1
    fi

    if [[ -z "${TARGET_IMAGE}" ]]; then
        echo "[ERROR] --target is required" >&2
        usage
        exit 1
    fi

    echo "=== Pushing Local Image to Registry ===" >&2
    echo "" >&2
    echo "  Source: ${SOURCE_IMAGE}" >&2
    echo "  Target: ${TARGET_IMAGE}" >&2
    echo "" >&2

    check_image_exists
    tag_and_push
    record_to_lock
}

check_image_exists() {
    echo "[CHECK] Verifying source image exists..." >&2

    if ! docker image inspect "${SOURCE_IMAGE}" >/dev/null 2>&1; then
        echo "[ERROR] Source image '${SOURCE_IMAGE}' not found in local Docker" >&2
        echo "" >&2
        echo "Available images:" >&2
        docker images --format "{{.Repository}}:{{.Tag}}" | head -20 >&2
        exit 1
    fi

    local size
    size=$(docker image inspect "${SOURCE_IMAGE}" --format='{{.Size}}' | numfmt --to=iec 2>/dev/null || echo "unknown")
    echo "[OK] Source image found (size: ${size})" >&2
}

tag_and_push() {
    echo "[TAG] Tagging image..." >&2
    if ! docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}"; then
        echo "[ERROR] Failed to tag image" >&2
        exit 1
    fi
    echo "[OK] Image tagged as ${TARGET_IMAGE}" >&2

    echo "[PUSH] Pushing image to registry..." >&2
    if ! docker push "${TARGET_IMAGE}"; then
        echo "[ERROR] Failed to push image" >&2
        exit 1
    fi

    echo "[OK] Image pushed successfully" >&2

    # Get digest using crane (preferred) or fall back to docker inspect
    local digest=""
    if command -v crane &>/dev/null; then
        digest=$(crane digest "${TARGET_IMAGE}" 2>/dev/null) || true
    fi

    if [[ -z "${digest}" ]]; then
        # Fallback: try docker inspect
        digest=$(docker inspect "${TARGET_IMAGE}" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2) || true
    fi

    if [[ -n "${digest}" ]]; then
        echo "" >&2
        echo "  Digest: ${digest}" >&2
    fi
}

record_to_lock() {
    local lock_file="${OUTPUT_DIR}/local-images-lock.json"
    mkdir -p "${OUTPUT_DIR}"

    local name source target digest synced_at
    name=$(echo "${SOURCE_IMAGE}" | sed 's|:.*||')
    source="${SOURCE_IMAGE}"
    target="${TARGET_IMAGE}"
    synced_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Get digest
    digest=""
    if command -v crane &>/dev/null; then
        digest=$(crane digest "${TARGET_IMAGE}" 2>/dev/null) || true
    fi
    if [[ -z "${digest}" ]]; then
        digest=$(docker inspect "${TARGET_IMAGE}" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2) || true
    fi
    if [[ -z "${digest}" ]]; then
        digest="unknown"
    fi

    # Escape JSON strings
    name=$(json_escape "${name}")
    source=$(json_escape "${source}")
    target=$(json_escape "${target}")
    digest=$(json_escape "${digest}")

    # Read existing entries or start fresh
    local temp_file
    temp_file=$(mktemp)

    if [[ -f "${lock_file}" ]] && [[ -s "${lock_file}" ]]; then
        # File exists and has content
        # Remove trailing ] and add comma
        head -c -1 "${lock_file}" > "${temp_file}"
        echo "," >> "${temp_file}"
    else
        # Start new file
        echo "[" > "${temp_file}"
    fi

    cat >> "${temp_file}" <<EOF
  {
    "name": "${name}",
    "source": "${source}",
    "target": "${target}",
    "digest": "${digest}",
    "synced_at": "${synced_at}"
  }
]
EOF

    mv "${temp_file}" "${lock_file}"
    echo "[OK] Lock file updated: ${lock_file}" >&2
}

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "${str}"
}

main "$@"
