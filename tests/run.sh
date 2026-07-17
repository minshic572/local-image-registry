#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

echo "[TEST] Bash syntax"
for script in scripts/*.sh tests/*.sh; do
    bash -n "${script}"
done

echo "[TEST] Python syntax"
python3 - scripts/render-harbor-config.py scripts/registry-inventory.py tests/test_registry_inventory.py <<'PY'
import pathlib, sys
for filename in sys.argv[1:]:
    source = pathlib.Path(filename).read_text()
    compile(source, filename, "exec")
PY

echo "[TEST] Harbor config renderer"
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
cat > "${test_dir}/harbor.yml.tmpl" <<'EOF'
hostname: reg.mydomain.com
http:
  port: 80
harbor_admin_password: Harbor12345
database:
  password: root123
data_volume: /data
log:
  local:
    location: /var/log/harbor
EOF
python3 scripts/render-harbor-config.py \
    --template "${test_dir}/harbor.yml.tmpl" \
    --output "${test_dir}/harbor.yml" \
    --hostname harbor.local \
    --port 5002 \
    --admin-password admin-secret \
    --database-password db-secret \
    --data-volume /tmp/harbor-data \
    --log-location /tmp/harbor-log
grep -q '^hostname: harbor.local$' "${test_dir}/harbor.yml"
grep -q '^  port: 5002$' "${test_dir}/harbor.yml"
grep -q '^data_volume: /tmp/harbor-data$' "${test_dir}/harbor.yml"
grep -q '^    location: /tmp/harbor-log$' "${test_dir}/harbor.yml"

echo "[TEST] Registry inventory"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_registry_inventory.py

echo "[TEST] Existing configuration parser"
./scripts/mirror-images.sh --config config/images.cilium.yaml --dry-run >/dev/null

echo "[OK] All tests passed"
