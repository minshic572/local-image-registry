#!/usr/bin/env bash
# Copy all inventoried registry:2 tags to Harbor and verify their digests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=harbor-common.sh
source "${SCRIPT_DIR}/harbor-common.sh"

INVENTORY_FILE="${PROJECT_ROOT}/output/registry-v2-inventory.json"
REPORT_FILE="${PROJECT_ROOT}/output/harbor-migration-report.json"

main() {
    require_command crane
    require_command python3
    require_command docker
    require_harbor_runtime
    if [[ ! -f "${INVENTORY_FILE}" ]]; then
        echo "[ERROR] Missing inventory: ${INVENTORY_FILE}" >&2
        echo "Run 'make inventory' first." >&2
        exit 1
    fi

    login_robot
    local records_file
    records_file=$(mktemp)
    : > "${records_file}"

    while IFS=$'\t' read -r repository tag source_digest; do
        [[ -z "${repository}" ]] && continue
        local target_repository source target target_digest status
        target_repository=$(map_repository "${repository}")
        source="${LEGACY_REGISTRY_HOST}/${repository}:${tag}"
        target="$(harbor_registry)/${target_repository}:${tag}"
        status="copied"

        echo "[COPY] ${source} -> ${target}"
        if ! crane_copy "${source}" "${target}"; then
            status="copy_failed"
            target_digest=""
        else
            target_digest=$(crane_digest "${target}" || true)
            if [[ -z "${target_digest}" || "${target_digest}" != "${source_digest}" ]]; then
                status="digest_mismatch"
            fi
        fi
        python3 - "${records_file}" "${repository}" "${target_repository}" "${tag}" \
            "${source_digest}" "${target_digest:-}" "${status}" <<'PY'
import json, sys
path, source_repo, target_repo, tag, source_digest, target_digest, status = sys.argv[1:]
with open(path, "a") as stream:
    stream.write(json.dumps({
        "source_repository": source_repo, "target_repository": target_repo,
        "tag": tag, "source_digest": source_digest,
        "target_digest": target_digest, "status": status
    }) + "\n")
PY
    done < <(inventory_rows)

    build_report "${records_file}"
    rm -f "${records_file}"
    if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if d["failed"] == 0 else 1)' "${REPORT_FILE}"; then
        echo "[ERROR] Migration completed with failures. See ${REPORT_FILE}" >&2
        exit 1
    fi
    echo "[READY] All inventoried tags copied with matching digests."
    echo "[NEXT] Run a final inventory after freezing writes, migrate again, then 'make cutover'."
}

login_robot() {
    local robot_file="${HARBOR_RUNTIME_DIR}/migration-robot.json"
    if [[ ! -s "${robot_file}" ]]; then
        echo "[ERROR] Migration robot credentials not found. Run 'make harbor-init'." >&2
        exit 1
    fi
    local username secret
    username=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "${robot_file}")
    secret=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secret"])' "${robot_file}")
    printf '%s' "${secret}" | docker login "$(harbor_registry)" --username "${username}" --password-stdin >/dev/null
}

inventory_rows() {
    python3 - "${INVENTORY_FILE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for repo in data["repositories"]:
    for item in repo["tags"]:
        print(repo["repository"], item["tag"], item["digest"], sep="\t")
PY
}

map_repository() {
    local repository="$1"
    if [[ "${repository}" == */* ]]; then
        printf '%s\n' "${repository}"
    else
        printf 'library/%s\n' "${repository}"
    fi
}

crane_copy() {
    local args=(copy)
    [[ "${HARBOR_INSECURE}" == "true" ]] && args+=(--insecure)
    crane "${args[@]}" "$1" "$2"
}

crane_digest() {
    local args=(digest)
    [[ "${HARBOR_INSECURE}" == "true" ]] && args+=(--insecure)
    crane "${args[@]}" "$1"
}

build_report() {
    local records_file="$1"
    python3 - "${records_file}" "${REPORT_FILE}" "${INVENTORY_FILE}" "$(harbor_registry)" <<'PY'
import hashlib, json, sys
records_path, report_path, inventory_path, target = sys.argv[1:]
records = [json.loads(line) for line in open(records_path) if line.strip()]
inventory_sha256 = hashlib.sha256(open(inventory_path, "rb").read()).hexdigest()
report = {
    "inventory": inventory_path,
    "inventory_sha256": inventory_sha256,
    "target": target,
    "total": len(records),
    "verified": sum(r["status"] == "copied" for r in records),
    "failed": sum(r["status"] != "copied" for r in records),
    "artifacts": records,
}
with open(report_path, "w") as stream:
    json.dump(report, stream, indent=2)
    stream.write("\n")
print(f"[REPORT] verified={report['verified']} failed={report['failed']}")
PY
}

main "$@"
