#!/usr/bin/env bash
# Stop registry:2 and move the verified Harbor deployment from staging to port 5001.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

REPORT_FILE="${PROJECT_ROOT}/output/harbor-migration-report.json"
FORCE=false

main() {
    [[ "${1:-}" == "--force" ]] && FORCE=true
    require_command docker
    require_command python3
    require_harbor_runtime
    validate_report
    confirm_cutover

    echo "[FREEZE] Stopping registry:2 container ${LEGACY_REGISTRY_CONTAINER}..."
    docker stop "${LEGACY_REGISTRY_CONTAINER}"

    if ! reconfigure_harbor "${HARBOR_FINAL_PORT}"; then
        echo "[ERROR] Harbor reconfiguration failed; restarting registry:2." >&2
        docker start "${LEGACY_REGISTRY_CONTAINER}" >/dev/null || true
        exit 1
    fi
    write_state
    wait_for_harbor

    echo "[READY] Cutover complete: ${HARBOR_SCHEME}://${HARBOR_HOSTNAME}:${HARBOR_FINAL_PORT}"
    echo "[INFO] registry:2 is stopped but its container and volume are preserved."
    echo "[INFO] Run 'make rollback' during the observation window if needed."
}

validate_report() {
    if [[ ! -s "${REPORT_FILE}" ]]; then
        echo "[ERROR] Migration report not found: ${REPORT_FILE}" >&2
        exit 1
    fi
    python3 - "${REPORT_FILE}" "${PROJECT_ROOT}/output/registry-v2-inventory.json" <<'PY'
import hashlib, json, sys
report = json.load(open(sys.argv[1]))
if report.get("failed") != 0 or report.get("total", 0) != report.get("verified", -1):
    raise SystemExit("migration report is not fully verified")
actual_inventory_hash = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
if report.get("inventory_sha256") != actual_inventory_hash:
    raise SystemExit("inventory changed after the last migration; run make migrate again")
if report.get("total", 0) == 0:
    print("[WARN] Migration report contains no tagged images.", file=sys.stderr)
PY
}

confirm_cutover() {
    [[ "${FORCE}" == "true" ]] && return
    echo "This stops registry:2 and changes Harbor from port ${HARBOR_STAGING_PORT} to ${HARBOR_FINAL_PORT}."
    printf 'Continue? [y/N] '
    local answer
    read -r answer
    [[ "${answer}" == "y" || "${answer}" == "Y" ]] || exit 0
}

reconfigure_harbor() {
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
    (
        cd "${HARBOR_INSTALLER_DIR}"
        ./prepare --with-trivy
        docker compose up -d
    )
}

write_state() {
    {
        printf 'HARBOR_ACTIVE_PORT=%s\n' "${HARBOR_FINAL_PORT}"
        printf 'HARBOR_PHASE=cutover\n'
    } > "${HARBOR_STATE_FILE}"
}

wait_for_harbor() {
    local attempt
    for attempt in $(seq 1 90); do
        if curl_harbor "${HARBOR_SCHEME}://${HARBOR_HOSTNAME}:${HARBOR_FINAL_PORT}/api/v2.0/health" >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    return 1
}

main "$@"
