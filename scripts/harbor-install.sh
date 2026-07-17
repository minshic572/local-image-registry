#!/usr/bin/env bash
# Install Harbor as an independent Docker Compose stack on Docker Desktop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

INSTALLER_NAME="harbor-online-installer-v${HARBOR_VERSION}.tgz"
INSTALLER_URL="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/${INSTALLER_NAME}"

main() {
    require_command docker
    require_command curl
    require_command python3
    require_command openssl
    require_command tar

    if ! docker info >/dev/null 2>&1; then
        echo "[ERROR] Docker Desktop is not running or is not accessible." >&2
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "[ERROR] Docker Compose v2 is required." >&2
        exit 1
    fi

    check_client_access
    check_architecture
    prepare_directories
    ensure_secrets
    download_installer
    render_config "${HARBOR_STAGING_PORT}"

    echo "[INSTALL] Starting Harbor ${HARBOR_VERSION} with Trivy on port ${HARBOR_STAGING_PORT}..."
    (
        cd "${HARBOR_INSTALLER_DIR}"
        ./install.sh --with-trivy
    )
    write_state "${HARBOR_STAGING_PORT}" "staging"
    wait_for_harbor

    echo "[READY] Harbor is available at $(harbor_url)"
    echo "[NEXT] Run 'make harbor-init', then inventory and migrate registry:2."
}

check_client_access() {
    if ! python3 - "${HARBOR_HOSTNAME}" <<'PY'
import socket, sys
try:
    socket.gethostbyname(sys.argv[1])
except OSError:
    raise SystemExit(1)
PY
    then
        echo "[ERROR] ${HARBOR_HOSTNAME} does not resolve on the host." >&2
        echo "Add '127.0.0.1 ${HARBOR_HOSTNAME}' to /etc/hosts, then retry." >&2
        exit 1
    fi

    if [[ "${HARBOR_SCHEME}" == "http" ]]; then
        local registry_config
        registry_config=$(docker info --format '{{json .RegistryConfig.IndexConfigs}}')
        if ! python3 - "${registry_config}" \
            "${HARBOR_HOSTNAME}:${HARBOR_STAGING_PORT}" \
            "${HARBOR_HOSTNAME}:${HARBOR_FINAL_PORT}" <<'PY'
import json, sys
configured = json.loads(sys.argv[1])
missing = [authority for authority in sys.argv[2:] if authority not in configured]
if missing:
    print("missing Docker insecure registries: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
        then
            echo "[ERROR] Configure both Harbor ports as insecure registries in Docker Desktop:" >&2
            echo "  ${HARBOR_HOSTNAME}:${HARBOR_STAGING_PORT}" >&2
            echo "  ${HARBOR_HOSTNAME}:${HARBOR_FINAL_PORT}" >&2
            echo "Then restart Docker Desktop and retry." >&2
            exit 1
        fi
    fi
}

check_architecture() {
    local server_arch
    server_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)
    if [[ "${server_arch}" == "arm64" || "${server_arch}" == "aarch64" ]]; then
        echo "[WARN] Harbor officially targets Linux hosts and some release images may be amd64-only." >&2
        echo "[WARN] Docker Desktop may run them under emulation with higher CPU and memory use." >&2
    fi
}

prepare_directories() {
    mkdir -p "${HARBOR_RUNTIME_DIR}/downloads" "${HARBOR_DATA_DIR}" "${HARBOR_LOG_DIR}"
    chmod 700 "${HARBOR_RUNTIME_DIR}"
}

ensure_secrets() {
    if [[ -f "${HARBOR_SECRETS_FILE}" ]]; then
        return
    fi
    umask 077
    {
        printf 'HARBOR_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 20)"
        printf 'HARBOR_DB_PASSWORD=%s\n' "$(openssl rand -hex 20)"
    } > "${HARBOR_SECRETS_FILE}"
    # shellcheck disable=SC1090
    source "${HARBOR_SECRETS_FILE}"
}

download_installer() {
    if [[ -x "${HARBOR_INSTALLER_DIR}/install.sh" ]]; then
        return
    fi

    local archive="${HARBOR_RUNTIME_DIR}/downloads/${INSTALLER_NAME}"
    local metadata="${HARBOR_RUNTIME_DIR}/downloads/release-v${HARBOR_VERSION}.json"
    echo "[DOWNLOAD] ${INSTALLER_URL}"
    curl -fL --retry 3 --output "${archive}" "${INSTALLER_URL}"
    curl -fL --retry 3 --output "${metadata}" \
        "https://api.github.com/repos/goharbor/harbor/releases/tags/v${HARBOR_VERSION}"
    verify_release_digest "${archive}" "${metadata}"

    mkdir -p "${HARBOR_RUNTIME_DIR}/installer"
    tar -xzf "${archive}" -C "${HARBOR_RUNTIME_DIR}/installer"
}

verify_release_digest() {
    local archive="$1"
    local metadata="$2"
    python3 - "${archive}" "${metadata}" "${INSTALLER_NAME}" <<'PY'
import hashlib, json, pathlib, sys
archive, metadata, name = map(pathlib.Path, sys.argv[1:])
release = json.loads(metadata.read_text())
asset = next((item for item in release.get("assets", []) if item.get("name") == str(name)), None)
expected = (asset or {}).get("digest", "")
if not expected:
    print("[WARN] GitHub release metadata has no asset digest; TLS download is the only verification.", file=sys.stderr)
    raise SystemExit(0)
actual = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit(f"Harbor installer digest mismatch: expected {expected}, got {actual}")
print(f"[OK] Verified installer digest: {actual}")
PY
}

render_config() {
    local port="$1"
    python3 "${SCRIPT_DIR}/render-harbor-config.py" \
        --template "${HARBOR_INSTALLER_DIR}/harbor.yml.tmpl" \
        --output "${HARBOR_CONFIG_FILE}" \
        --hostname "${HARBOR_HOSTNAME}" \
        --port "${port}" \
        --admin-password "${HARBOR_ADMIN_PASSWORD}" \
        --database-password "${HARBOR_DB_PASSWORD}" \
        --data-volume "${HARBOR_DATA_DIR}" \
        --log-location "${HARBOR_LOG_DIR}"
}

write_state() {
    local port="$1"
    local phase="$2"
    {
        printf 'HARBOR_ACTIVE_PORT=%s\n' "${port}"
        printf 'HARBOR_PHASE=%s\n' "${phase}"
    } > "${HARBOR_STATE_FILE}"
}

wait_for_harbor() {
    local attempt
    for attempt in $(seq 1 90); do
        if curl_harbor "$(harbor_url)/api/v2.0/health" >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    echo "[ERROR] Harbor did not become healthy within 180 seconds." >&2
    exit 1
}

main "$@"
