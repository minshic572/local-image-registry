#!/usr/bin/env bash
#
# mirror-images.sh - Sync images from public registries to local registry
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/output"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

CONFIG_FILE=""
REGISTRY_HOST=""
PLATFORM=""
MODE=""
DRY_RUN=false
FORCE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync images from public registries to the local registry.

OPTIONS:
    --config FILE      Path to images config YAML file (required)
    --registry HOST    Override target registry host:port (default: from config)
    --platform PLAT    Platform for single-platform mode (e.g., linux/amd64)
    --mode MODE        Override mode: manifest-list or single-platform
    --dry-run          Show what would be synced without syncing (no registry required)
    --force            Force re-sync even if image exists
    -h, --help         Show this help message

EXAMPLES:
    $(basename "$0") --config config/images.cilium.yaml
    $(basename "$0") --config config/images.cilium.yaml --platform linux/amd64
    $(basename "$0") --config config/images.cilium.yaml --dry-run
    $(basename "$0") --config config/images.cilium.yaml --registry harbor.local:5001

CONFIG FORMAT:
    images:
      - name: cilium
        source: quay.io/cilium/cilium:v1.19.5
        target: harbor.local:5001/cilium/cilium:v1.19.5
        mode: manifest-list
        platforms:
          - linux/amd64
          - linux/arm64
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --registry)
                REGISTRY_HOST="$2"
                shift 2
                ;;
            --platform)
                PLATFORM="$2"
                shift 2
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
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

    if [[ -z "${CONFIG_FILE}" ]]; then
        echo "[ERROR] --config is required" >&2
        usage
        exit 1
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "[ERROR] Config file not found: ${CONFIG_FILE}" >&2
        exit 1
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        if [[ -z "${REGISTRY_HOST}" ]]; then
            REGISTRY_HOST=$(harbor_registry)
        fi
        check_dependencies
        check_registry_reachable
    fi

    echo "=== Mirroring Images to Local Registry ===" >&2
    echo "" >&2
    echo "  Config: ${CONFIG_FILE}" >&2
    [[ -n "${REGISTRY_HOST}" ]] && echo "  Registry override: ${REGISTRY_HOST}" >&2
    [[ -n "${MODE}" ]] && echo "  Mode override: ${MODE}" >&2
    [[ -n "${PLATFORM}" ]] && echo "  Platform: ${PLATFORM}" >&2
    [[ "${DRY_RUN}" == "true" ]] && echo "  [DRY RUN MODE]" >&2
    echo "" >&2

    mkdir -p "${OUTPUT_DIR}"

    local images
    images=$(parse_yaml "${CONFIG_FILE}")
    local image_count
    image_count=$(echo "${images}" | grep -c "^ENTRY^" || echo "0")

    echo "[INFO] Found ${image_count} images to sync" >&2
    echo "" >&2

    local lock_entries=()
    local sync_count=0
    local skip_count=0

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        local name source target img_mode platforms
        name=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f1)
        source=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f2)
        target=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f3)
        img_mode=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f4)
        platforms=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f6)

        # Apply CLI overrides
        if [[ -n "${MODE}" ]]; then
            img_mode="${MODE}"
        elif [[ -z "${img_mode}" ]]; then
            img_mode="manifest-list"
        fi

        # Determine effective mode considering --platform
        local effective_mode="${img_mode}"
        if [[ -n "${PLATFORM}" ]]; then
            effective_mode="single-platform"
        fi

        # Apply registry override
        local effective_target="${target}"
        if [[ -n "${REGISTRY_HOST}" ]]; then
            effective_target=$(apply_registry_override "${target}" "${REGISTRY_HOST}")
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "[DRY RUN] Would sync: ${source}" >&2
            echo "          -> ${effective_target}" >&2
            echo "          Mode: ${effective_mode}" >&2
            [[ -n "${platforms}" ]] && echo "          Platforms: ${platforms}" >&2
            echo "" >&2
            sync_count=$((sync_count + 1))
            continue
        fi

        local result
        local exit_code=0
        result=$(sync_image "${source}" "${effective_target}" "${effective_mode}" "${PLATFORM}") || exit_code=$?

        if [[ ${exit_code} -eq 0 ]]; then
            local source_digest target_digest
            # Parse result: first line is source_digest, second is target_digest
            source_digest=$(echo "${result}" | head -1)
            target_digest=$(echo "${result}" | tail -1)

            lock_entries+=("${name}|${source}|${effective_target}|${effective_mode}||${platforms}|${source_digest}|${target_digest}")
            sync_count=$((sync_count + 1))
        elif [[ ${exit_code} -eq 10 ]]; then
            echo "[SKIP] ${name}: ${source} (already exists, use --force to re-sync)" >&2
            skip_count=$((skip_count + 1))
        else
            echo "[FAIL] ${name}: ${source} (sync failed)" >&2
            skip_count=$((skip_count + 1))
        fi
        echo "" >&2
    done <<< "${images}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN COMPLETE] ${sync_count} images would be synced" >&2
        return 0
    fi

    if [[ ${sync_count} -gt 0 ]]; then
        write_lock_file "${lock_entries[@]}"
    else
        # Write empty lock file
        echo "[]" > "${OUTPUT_DIR}/images-lock.json"
    fi

    echo "=== Sync Complete ===" >&2
    echo "  Synced: ${sync_count}" >&2
    echo "  Skipped: ${skip_count}" >&2
    echo "  Lock file: ${OUTPUT_DIR}/images-lock.json" >&2

    # Return non-zero if all syncs failed
    if [[ ${sync_count} -eq 0 ]] && [[ ${skip_count} -gt 0 ]]; then
        return 1
    fi
}

apply_registry_override() {
    local original_target="$1"
    local new_registry="$2"

    # Replace only the registry host:port part, preserve the full path
    # e.g., harbor.local:5001/cilium/cilium:v1.19.5 -> registry.local:5000/cilium/cilium:v1.19.5
    # Extract path after the first / (which is the registry:port)
    local path="${original_target#*/}"

    echo "${new_registry}/${path}"
}

parse_yaml() {
    local file="$1"
    local current_entry=""
    local in_images=false

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Remove carriage returns
        line="${line//$'\r'/}"

        # Skip empty lines
        [[ -z "${line}" ]] && continue

        # Skip comment lines
        local trimmed
        trimmed=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ "${trimmed}" == \#* ]] && continue

        # Detect images section
        if [[ "${trimmed}" == "images:" ]]; then
            in_images=true
            continue
        fi

        # If we're not in images section, skip
        if [[ "${in_images}" != "true" ]]; then
            continue
        fi

        # Calculate leading spaces and content after leading spaces
        local leading_spaces="${line%%[![:space:]]*}"
        local after_leading="${line#"${leading_spaces}"}"

        # Detect image entry start (line that starts with "- name:" at proper indent)
        # We need to specifically check for "- name:" not just any "-"
        if [[ "${after_leading}" =~ ^-\ name:\ *(.*) ]]; then
            # Save previous entry
            if [[ -n "${current_entry}" ]]; then
                echo "ENTRY^${current_entry}"
            fi
            current_entry=""
            # Extract name value from "- name: value"
            local val="${BASH_REMATCH[1]}"
            val=$(echo "${val}" | tr -d '"' | tr -d "'")
            current_entry+="${val}|"
            continue
        fi

        # If we hit a line at root level (no indent), we're done
        if [[ -z "${leading_spaces}" ]] && [[ "${trimmed}" != -* ]]; then
            if [[ -n "${current_entry}" ]]; then
                echo "ENTRY^${current_entry}"
            fi
            current_entry=""
            in_images=false
            continue
        fi

        # Parse key-value pairs within image entries
        if [[ "${trimmed}" =~ ^source:\ *(.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            val=$(echo "${val}" | tr -d '"' | tr -d "'")
            current_entry+="${val}|"
        elif [[ "${trimmed}" =~ ^target:\ *(.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            val=$(echo "${val}" | tr -d '"' | tr -d "'")
            current_entry+="${val}|"
        elif [[ "${trimmed}" =~ ^mode:\ *(.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            val=$(echo "${val}" | tr -d '"' | tr -d "'")
            current_entry+="${val}|"
        elif [[ "${trimmed}" == "platforms:" ]]; then
            current_entry+="|"
        elif [[ "${trimmed}" =~ ^-\ *(.*) ]]; then
            # Platform list item
            local val="${BASH_REMATCH[1]}"
            val=$(echo "${val}" | tr -d '"' | tr -d "'")
            current_entry+="${val} "
        fi
    done < "${file}"

    # Don't forget the last entry
    if [[ -n "${current_entry}" ]]; then
        echo "ENTRY^${current_entry}"
    fi
}

check_dependencies() {
    echo "[CHECK] Checking dependencies..." >&2

    if ! command -v crane &>/dev/null; then
        echo "[ERROR] crane is not installed" >&2
        echo "" >&2
        echo "Install crane with:" >&2
        echo "  # macOS" >&2
        echo "  brew install crane" >&2
        echo "" >&2
        echo "  # Linux" >&2
        echo "  curl -sL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_amd64.tar.gz | tar xz" >&2
        echo "  mv crane /usr/local/bin/" >&2
        echo "" >&2
        exit 1
    fi

    echo "[OK] crane is available" >&2
}

check_registry_reachable() {
    local check_registry="${REGISTRY_HOST:-$(harbor_registry)}"
    echo -n "[CHECK] Registry at ${check_registry} is " >&2

    if curl -sf "${HARBOR_SCHEME}://${check_registry}/v2/" >/dev/null 2>&1; then
        echo "reachable" >&2
    else
        echo "NOT reachable" >&2
        echo "[ERROR] Registry is not running or not accessible" >&2
        echo "" >&2
        echo "Start registry with:" >&2
        echo "  make start" >&2
        exit 1
    fi
}

sync_image() {
    local source="$1"
    local target="$2"
    local img_mode="${3:-manifest-list}"
    local platform="$4"

    echo "[SYNC] ${source} -> ${target}" >&2
    echo "      Mode: ${img_mode}" >&2

    # Check if already exists (unless --force)
    if [[ "${FORCE}" != "true" ]]; then
        if image_exists "${target}"; then
            echo "      [SKIP] Image already exists (use --force to re-sync)" >&2
            return 10
        fi
    fi

    # Get source digest
    local source_digest
    source_digest=$(crane digest "${source}" 2>/dev/null) || source_digest="unknown"
    echo "      Source digest: ${source_digest}" >&2

    # Build crane command
    local crane_cmd=(crane copy)
    if [[ "${img_mode}" == "single-platform" ]] && [[ -n "${platform}" ]]; then
        crane_cmd+=(--platform "${platform}")
        echo "      Platform: ${platform}" >&2
    fi
    crane_cmd+=("${source}" "${target}")

    echo "      Running: ${crane_cmd[*]}" >&2

    if ! "${crane_cmd[@]}" 2>&1; then
        echo "      [ERROR] Failed to sync image" >&2
        return 1
    fi

    local target_digest
    target_digest=$(crane digest "${target}" 2>/dev/null) || target_digest="unknown"
    echo "      Target digest: ${target_digest}" >&2
    echo "      [OK] Synced successfully" >&2

    # Output only machine-readable data to stdout
    echo "${source_digest}"
    echo "${target_digest}"
}

image_exists() {
    local target="$1"

    # Parse target to extract registry, repo, and reference
    # Format can be: registry:port/repo:tag or registry:port/repo@sha256:digest

    # Remove scheme if present
    local registry_path="${target#*://}"

    # Extract registry:port (everything before the first /)
    local registry="${registry_path%%/*}"

    # Extract path after registry:port
    local path="${registry_path#*/}"

    # Extract reference (tag or digest) from path
    local repo ref
    if [[ "${path}" == *"@"* ]]; then
        repo="${path%%@*}"
        ref="${path#*@}"
    elif [[ "${path}" == *":"* ]]; then
        repo="${path%%:*}"
        ref="${path#*:}"
    else
        repo="${path}"
        ref="latest"
    fi

    # Build API path
    local api_path="/v2/${repo}/manifests/${ref}"

    # Try HEAD request to check if manifest exists
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" "${HARBOR_SCHEME}://${registry}${api_path}" 2>/dev/null) || true

    if [[ "${http_code}" == "200" ]]; then
        return 0
    fi

    return 1
}

write_lock_file() {
    local entries=("$@")

    local lock_file="${OUTPUT_DIR}/images-lock.json"

    {
        echo "["
        local first=true
        for entry in "${entries[@]}"; do
            local name source target mode _mode_dummy platforms source_digest target_digest
            IFS='|' read -r name source target mode _mode_dummy platforms source_digest target_digest <<< "${entry}"

            # Escape JSON strings
            name=$(json_escape "${name}")
            source=$(json_escape "${source}")
            target=$(json_escape "${target}")
            mode=$(json_escape "${mode}")
            source_digest=$(json_escape "${source_digest}")
            target_digest=$(json_escape "${target_digest}")

            # Convert platforms to JSON array
            local platforms_json="[]"
            if [[ -n "${platforms}" ]]; then
                local platform_items=""
                for p in ${platforms}; do
                    if [[ -n "${platform_items}" ]]; then
                        platform_items+=","
                    fi
                    platform_items+="\"$(json_escape "${p}")\""
                done
                platforms_json="[${platform_items}]"
            fi

            if [[ "${first}" == "true" ]]; then
                first=false
            else
                echo ","
            fi

            cat <<EOF
  {
    "name": "${name}",
    "source": "${source}",
    "target": "${target}",
    "mode": "${mode}",
    "platforms": ${platforms_json},
    "source_digest": "${source_digest}",
    "target_digest": "${target_digest}",
    "synced_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
EOF
        done
        echo ""
        echo "]"
    } > "${lock_file}"

    echo "[OK] Lock file written: ${lock_file}" >&2
}

json_escape() {
    local str="$1"
    # Escape backslashes, quotes, and control characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "${str}"
}

main "$@"
