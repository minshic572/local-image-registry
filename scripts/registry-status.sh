#!/usr/bin/env bash
# Show Harbor component and API health.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/harbor-manage.sh" status
