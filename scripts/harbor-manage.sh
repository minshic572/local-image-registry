#!/usr/bin/env bash
# Manage the Harbor Docker Compose lifecycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

usage() {
    echo "Usage: $(basename "$0") {start|stop|status|logs}"
}

main() {
    local command="${1:-}"
    case "${command}" in
        start)
            harbor_compose up -d
            echo "[READY] Harbor started at $(harbor_url)"
            ;;
        stop)
            harbor_compose stop
            echo "[OK] Harbor stopped; data is preserved in ${HARBOR_DATA_DIR}"
            ;;
        status)
            harbor_compose ps
            echo ""
            if curl_harbor "$(harbor_url)/api/v2.0/health" >/dev/null 2>&1; then
                echo "[OK] Harbor API is healthy at $(harbor_url)"
            else
                echo "[ERROR] Harbor API is not healthy at $(harbor_url)" >&2
                exit 1
            fi
            ;;
        logs)
            harbor_compose logs --tail=200
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
