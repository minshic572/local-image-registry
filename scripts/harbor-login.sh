#!/usr/bin/env bash
# Authenticate Docker and Helm to the active Harbor registry with the migration robot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

ROBOT_FILE="${HARBOR_RUNTIME_DIR}/migration-robot.json"

main() {
    require_command docker
    require_command helm
    require_command python3
    require_command curl
    require_harbor_runtime
    require_robot_credentials
    check_registry_reachable

    local registry username secret
    registry="$(harbor_registry)"
    read_robot_credentials

    echo "[LOGIN] Authenticating Docker to ${registry}"
    docker_login "${registry}" "${username}" "${secret}"

    echo "[LOGIN] Authenticating Helm to ${registry}"
    helm_login "${registry}" "${username}" "${secret}"

    verify_registry_auth "${username}" "${secret}"
    echo "[READY] Docker and Helm can push OCI artifacts to ${registry}"
}

require_robot_credentials() {
    if [[ ! -e "${ROBOT_FILE}" ]]; then
        echo "[ERROR] Migration robot credentials not found: ${ROBOT_FILE}" >&2
        echo "Run 'make harbor-init' after 'make harbor-install'." >&2
        exit 1
    fi
    if [[ ! -s "${ROBOT_FILE}" ]]; then
        echo "[ERROR] Migration robot credentials file is empty: ${ROBOT_FILE}" >&2
        echo "Run 'make harbor-init' to recreate the migration robot credentials." >&2
        exit 1
    fi
    if ! python3 - "${ROBOT_FILE}" <<'PY' >/dev/null
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    raise SystemExit(f"invalid JSON: {exc}")

if not isinstance(data.get("name"), str) or not data["name"]:
    raise SystemExit("missing robot name")
if not isinstance(data.get("secret"), str) or not data["secret"]:
    raise SystemExit("missing robot secret")
PY
    then
        echo "[ERROR] Migration robot credentials are not valid JSON with name and secret." >&2
        echo "Run 'make harbor-init' to recreate the migration robot credentials." >&2
        exit 1
    fi
}

read_robot_credentials() {
    local credentials
    credentials=$(python3 - "${ROBOT_FILE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
print(data["name"])
print(data["secret"])
PY
)
    username="$(printf '%s\n' "${credentials}" | sed -n '1p')"
    secret="$(printf '%s\n' "${credentials}" | sed -n '2p')"
}

check_registry_reachable() {
    if curl_harbor "$(harbor_url)/api/v2.0/health" >/dev/null 2>&1; then
        return
    fi
    echo "[ERROR] Harbor Registry is not reachable at $(harbor_url)." >&2
    echo "Run 'make start' and check 'make status'." >&2
    exit 1
}

docker_login() {
    local registry="$1"
    local username="$2"
    local secret="$3"
    if ! printf '%s' "${secret}" | docker login "${registry}" --username "${username}" --password-stdin >/dev/null 2>&1; then
        echo "[ERROR] Docker login failed for ${registry}." >&2
        echo "Check Docker Desktop insecure registries for ${registry}, then run 'make start' and retry." >&2
        exit 1
    fi
}

helm_login() {
    local registry="$1"
    local username="$2"
    local secret="$3"
    local args=(registry login "${registry}" --username "${username}" --password-stdin)
    if [[ "${HARBOR_SCHEME}" == "http" ]]; then
        args+=(--plain-http)
    fi
    if ! printf '%s' "${secret}" | helm "${args[@]}" >/dev/null 2>&1; then
        echo "[ERROR] Helm registry login failed for ${registry}." >&2
        echo "Check that Helm supports OCI registry login and that Harbor is running, then retry." >&2
        exit 1
    fi
}

verify_registry_auth() {
    local username="$1"
    local secret="$2"
    local netrc_file
    netrc_file="$(mktemp)"
    chmod 600 "${netrc_file}"
    {
        printf 'machine %s\n' "${HARBOR_HOSTNAME}"
        printf 'login %s\n' "${username}"
        printf 'password %s\n' "${secret}"
    } > "${netrc_file}"

    if ! curl_harbor --netrc-file "${netrc_file}" "$(harbor_url)/v2/" >/dev/null 2>&1; then
        rm -f "${netrc_file}"
        echo "[ERROR] Authenticated Registry API verification failed for $(harbor_registry)." >&2
        echo "Run 'make harbor-init' to confirm the migration robot exists, then retry." >&2
        exit 1
    fi
    rm -f "${netrc_file}"
    echo "[OK] Registry API authentication verified."
}

main "$@"
