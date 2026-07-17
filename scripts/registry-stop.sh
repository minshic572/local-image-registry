#!/usr/bin/env bash
# Stop Harbor while preserving all data.
set -euo pipefail
if [[ "${1:-}" == "--purge" ]]; then
    echo "[ERROR] Harbor purge is intentionally not automated." >&2
    echo "Back up Harbor, then remove its runtime and data directories explicitly." >&2
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/harbor-manage.sh" stop
