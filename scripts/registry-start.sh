#!/usr/bin/env bash
# Start the Harbor-backed local image registry.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/harbor-manage.sh" start
