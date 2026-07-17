#!/usr/bin/env bash
# Stop Harbor and restart the preserved registry:2 instance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

main() {
    require_harbor_runtime
    echo "[ROLLBACK] Stopping Harbor..."
    harbor_compose down
    echo "[ROLLBACK] Starting ${LEGACY_REGISTRY_CONTAINER}..."
    docker start "${LEGACY_REGISTRY_CONTAINER}"
    {
        printf 'HARBOR_ACTIVE_PORT=%s\n' "${HARBOR_STAGING_PORT}"
        printf 'HARBOR_PHASE=rolled_back\n'
    } > "${HARBOR_STATE_FILE}"
    echo "[READY] registry:2 is serving localhost:${HARBOR_FINAL_PORT} again."
    echo "[INFO] Harbor data remains preserved in ${HARBOR_DATA_DIR}."
}

main "$@"
