#!/usr/bin/env bash
#
# generate-lock.sh - Generate lock file from config without syncing images
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/output"

CONFIG_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate a lock file from config without actually syncing images.
Useful for planning and auditing.

OPTIONS:
    --config FILE      Path to images config YAML file (required)
    -h, --help        Show this help message

EXAMPLE:
    $(basename "$0") --config config/images.cilium.yaml
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
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

    if [[ -z "${CONFIG_FILE}" ]]; then
        echo "[ERROR] --config is required" >&2
        usage
        exit 1
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "[ERROR] Config file not found: ${CONFIG_FILE}" >&2
        exit 1
    fi

    echo "=== Generating Lock File ===" >&2
    echo "" >&2
    echo "  Config: ${CONFIG_FILE}" >&2
    echo "" >&2

    mkdir -p "${OUTPUT_DIR}"

    local images
    images=$(parse_yaml "${CONFIG_FILE}")
    local image_count
    image_count=$(echo "${images}" | grep -c "^ENTRY^" || echo "0")

    echo "[INFO] Found ${image_count} images" >&2
    echo "" >&2

    local lock_entries=()

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        local name source target mode platforms
        name=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f1)
        source=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f2)
        target=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f3)
        mode=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f4)
        platforms=$(echo "${line}" | sed 's/^ENTRY^//' | cut -d'|' -f6)

        if [[ -z "${mode}" ]]; then
            mode="manifest-list"
        fi

        echo "  - ${name}" >&2
        echo "    source: ${source}" >&2
        echo "    target: ${target}" >&2
        echo "    mode: ${mode}" >&2
        [[ -n "${platforms}" ]] && echo "    platforms: ${platforms}" >&2
        echo "" >&2

        lock_entries+=("${name}|${source}|${target}|${mode}||${platforms}")
    done <<< "${images}"

    write_lock_file "${lock_entries[@]}"

    echo "[OK] Lock file generated: ${OUTPUT_DIR}/images-lock.json" >&2
    echo "" >&2
    echo "To sync images, run:" >&2
    echo "  make mirror-cilium" >&2
    echo "" >&2
    echo "Or sync manually:" >&2
    echo "  ./scripts/mirror-images.sh --config ${CONFIG_FILE}" >&2
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
            if [[ "${trimmed}" =~ ^-\ name:\ *(.*) ]]; then
                local val="${BASH_REMATCH[1]}"
                val=$(echo "${val}" | tr -d '"' | tr -d "'")
                current_entry+="${val}|"
            fi
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

write_lock_file() {
    local entries=("$@")

    local lock_file="${OUTPUT_DIR}/images-lock.json"

    {
        echo "["
        local first=true
        for entry in "${entries[@]}"; do
            local name source target mode _mode_dummy platforms
            IFS='|' read -r name source target mode _mode_dummy platforms <<< "${entry}"

            # Escape JSON strings
            name=$(json_escape "${name}")
            source=$(json_escape "${source}")
            target=$(json_escape "${target}")
            mode=$(json_escape "${mode}")

            # Convert platforms to JSON array
            local platforms_json="[]"
            if [[ -n "${platforms}" ]]; then
                # Split by space and build JSON array
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
    "source_digest": "",
    "target_digest": "",
    "synced_at": ""
  }
EOF
        done
        echo ""
        echo "]"
    } > "${lock_file}"
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
