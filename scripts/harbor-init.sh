#!/usr/bin/env bash
# Create Harbor projects and a least-privilege migration robot account.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

ROBOT_FILE="${HARBOR_RUNTIME_DIR}/migration-robot.json"

main() {
    require_command curl
    require_command python3
    if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
        echo "[ERROR] Harbor secrets are missing. Run 'make harbor-install' first." >&2
        exit 1
    fi

    local project
    for project in ${HARBOR_PROJECTS}; do
        create_or_update_project "${project}"
    done
    create_robot
    echo "[READY] Harbor projects are initialized."
    echo "[INFO] Migration robot credentials: ${ROBOT_FILE}"
}

api_request() {
    curl_harbor -u "admin:${HARBOR_ADMIN_PASSWORD}" "$@"
}

project_payload() {
    local project="$1"
    python3 - "${project}" "${HARBOR_PUBLIC_PROJECTS}" <<'PY'
import json, sys
name, public = sys.argv[1], sys.argv[2].lower() == "true"
print(json.dumps({
    "project_name": name,
    "public": public,
    "metadata": {
        "public": str(public).lower(),
        "auto_scan": "true",
        "auto_sbom_generation": "true",
        "enable_content_trust": "false",
        "prevent_vul": "false",
        "reuse_sys_cve_allowlist": "true"
    }
}))
PY
}

create_or_update_project() {
    local project="$1"
    local payload http_code
    payload=$(project_payload "${project}")
    http_code=$(api_request -o /dev/null -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST "$(harbor_url)/api/v2.0/projects" \
        --data "${payload}" || true)
    case "${http_code}" in
        201)
            echo "[CREATE] Project ${project}"
            ;;
        409)
            api_request -o /dev/null -H 'Content-Type: application/json' \
                -X PUT "$(harbor_url)/api/v2.0/projects/${project}" \
                --data "${payload}"
            echo "[UPDATE] Project ${project}"
            ;;
        *)
            echo "[ERROR] Failed to create project ${project} (HTTP ${http_code})." >&2
            exit 1
            ;;
    esac
}

robot_payload() {
    python3 - ${HARBOR_PROJECTS} <<'PY'
import json, sys
permissions = []
for project in sys.argv[1:]:
    permissions.append({
        "kind": "project",
        "namespace": project,
        "access": [
            {"resource": "repository", "action": "pull"},
            {"resource": "repository", "action": "push"},
            {"resource": "artifact", "action": "read"},
            {"resource": "artifact", "action": "create"}
        ]
    })
print(json.dumps({
    "name": "local-migration",
    "description": "Registry v2 migration and local image mirroring",
    "disable": False,
    "duration": -1,
    "level": "system",
    "permissions": permissions
}))
PY
}

create_robot() {
    if [[ -s "${ROBOT_FILE}" ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("name") and d.get("secret")' "${ROBOT_FILE}" 2>/dev/null; then
        echo "[SKIP] Migration robot credentials already exist."
        return
    fi

    local payload response_file http_code
    payload=$(robot_payload)
    response_file=$(mktemp)
    http_code=$(api_request -o "${response_file}" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST "$(harbor_url)/api/v2.0/robots" \
        --data "${payload}" || true)
    if [[ "${http_code}" != "201" ]]; then
        echo "[ERROR] Failed to create migration robot (HTTP ${http_code})." >&2
        sed -n '1,20p' "${response_file}" >&2
        rm -f "${response_file}"
        exit 1
    fi
    umask 077
    mv "${response_file}" "${ROBOT_FILE}"
    chmod 600 "${ROBOT_FILE}"
    echo "[CREATE] System robot local-migration"
}

main "$@"
