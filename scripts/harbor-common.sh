#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

HARBOR_ENV_FILE="${HARBOR_ENV_FILE:-${PROJECT_ROOT}/config/harbor.env}"
if [[ -f "${HARBOR_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${HARBOR_ENV_FILE}"
fi

HARBOR_VERSION="${HARBOR_VERSION:-2.15.1}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.local}"
HARBOR_SCHEME="${HARBOR_SCHEME:-http}"
HARBOR_STAGING_PORT="${HARBOR_STAGING_PORT:-5002}"
HARBOR_FINAL_PORT="${HARBOR_FINAL_PORT:-5001}"
HARBOR_PROJECTS="${HARBOR_PROJECTS:-library cilium cyber-resilience falcosecurity helm}"
HARBOR_PUBLIC_PROJECTS="${HARBOR_PUBLIC_PROJECTS:-true}"
HARBOR_INSECURE="${HARBOR_INSECURE:-true}"
HARBOR_COMPOSE_PROJECT="${HARBOR_COMPOSE_PROJECT:-local-image-registry}"
LEGACY_REGISTRY_CONTAINER="${LEGACY_REGISTRY_CONTAINER:-local-image-registry}"
LEGACY_REGISTRY_HOST="${LEGACY_REGISTRY_HOST:-localhost:5001}"

resolve_from_root() {
    local path="$1"
    if [[ "${path}" = /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s\n' "${PROJECT_ROOT}/${path}"
    fi
}

HARBOR_RUNTIME_DIR="$(resolve_from_root "${HARBOR_RUNTIME_DIR:-.harbor}")"
HARBOR_DATA_DIR="$(resolve_from_root "${HARBOR_DATA_DIR:-.harbor/data}")"
HARBOR_LOG_DIR="$(resolve_from_root "${HARBOR_LOG_DIR:-.harbor/log}")"
HARBOR_INSTALLER_DIR="${HARBOR_RUNTIME_DIR}/installer/harbor"
HARBOR_SECRETS_FILE="${HARBOR_RUNTIME_DIR}/secrets.env"
HARBOR_STATE_FILE="${HARBOR_RUNTIME_DIR}/state.env"
HARBOR_COMPOSE_FILE="${HARBOR_INSTALLER_DIR}/docker-compose.yml"
HARBOR_CONFIG_FILE="${HARBOR_INSTALLER_DIR}/harbor.yml"
export COMPOSE_PROJECT_NAME="${HARBOR_COMPOSE_PROJECT}"

if [[ -f "${HARBOR_SECRETS_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${HARBOR_SECRETS_FILE}"
fi

active_harbor_port() {
    local active_port="${HARBOR_STAGING_PORT}"
    if [[ -f "${HARBOR_STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${HARBOR_STATE_FILE}"
        active_port="${HARBOR_ACTIVE_PORT:-${active_port}}"
    fi
    printf '%s\n' "${active_port}"
}

harbor_url() {
    printf '%s://%s:%s\n' "${HARBOR_SCHEME}" "${HARBOR_HOSTNAME}" "$(active_harbor_port)"
}

harbor_registry() {
    printf '%s:%s\n' "${HARBOR_HOSTNAME}" "$(active_harbor_port)"
}

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: ${command_name}" >&2
        return 1
    fi
}

require_harbor_runtime() {
    if [[ ! -f "${HARBOR_COMPOSE_FILE}" ]]; then
        echo "[ERROR] Harbor is not installed. Run 'make harbor-install' first." >&2
        return 1
    fi
}

harbor_compose() {
    require_harbor_runtime
    docker compose --file "${HARBOR_COMPOSE_FILE}" "$@"
}

normalize_harbor_compose() {
    local registry_cert="${HARBOR_DATA_DIR}/secret/registry/root.crt"
    local registry_config_cert="${HARBOR_INSTALLER_DIR}/common/config/registry/root.crt"
    if [[ -f "${registry_cert}" ]]; then
        cp "${registry_cert}" "${registry_config_cert}"
    fi

    python3 - "${HARBOR_COMPOSE_FILE}" "${registry_cert}" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
registry_cert = sys.argv[2]
lines = compose_file.read_text().splitlines()
rendered = []
index = 0
in_redis = False
while index < len(lines):
    if lines[index] == "  redis:":
        in_redis = True
    elif lines[index].startswith("  ") and not lines[index].startswith("    ") and lines[index] != "  redis:":
        in_redis = False

    if in_redis and lines[index].strip().startswith("image: goharbor/redis-photon:"):
        rendered.append("    image: redis:7-alpine")
        rendered.append("    command: [\"redis-server\", \"--dir\", \"/var/lib/redis\", \"--appendonly\", \"yes\"]")
        index += 1
        continue

    if (
        lines[index].strip() == "- type: bind"
        and index + 2 < len(lines)
        and lines[index + 1].strip() == f"source: {registry_cert}"
        and lines[index + 2].strip() == "target: /etc/registry/root.crt"
    ):
        index += 3
        continue
    rendered.append(lines[index])
    index += 1
compose_file.write_text("\n".join(rendered) + "\n")
PY
}

curl_harbor() {
    local curl_args=(-fsS)
    if [[ "${HARBOR_HOSTNAME}" == "localhost" ]]; then
        curl_args+=(--ipv6)
    elif [[ "${HARBOR_HOSTNAME}" != "127.0.0.1" && "${HARBOR_HOSTNAME}" != "::1" ]]; then
        curl_args+=(--resolve "${HARBOR_HOSTNAME}:$(active_harbor_port):127.0.0.1")
    fi
    if [[ "${HARBOR_INSECURE}" == "true" && "${HARBOR_SCHEME}" == "https" ]]; then
        curl_args+=(-k)
    fi
    curl "${curl_args[@]}" "$@"
}
