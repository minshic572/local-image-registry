#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -Fq -- "${expected}" "${file}" || fail "Expected ${file} to contain: ${expected}"
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"
    if grep -Fq -- "${unexpected}" "${file}"; then
        fail "Did not expect ${file} to contain sensitive text."
    fi
}

setup_case() {
    test_dir="$(mktemp -d)"
    runtime_dir="${test_dir}/runtime"
    bin_dir="${test_dir}/bin"
    log_dir="${test_dir}/logs"
    mkdir -p "${runtime_dir}/installer/harbor" "${bin_dir}" "${log_dir}"
    touch "${runtime_dir}/installer/harbor/docker-compose.yml"

    env_file="${test_dir}/harbor.env"
    cat > "${env_file}" <<EOF
HARBOR_HOSTNAME=harbor.local
HARBOR_SCHEME=http
HARBOR_STAGING_PORT=5002
HARBOR_FINAL_PORT=5001
HARBOR_RUNTIME_DIR=${runtime_dir}
HARBOR_INSECURE=true
EOF

    cat > "${runtime_dir}/migration-robot.json" <<'EOF'
{"name":"robot$local-migration","secret":"super-secret-token"}
EOF

    cat > "${bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
printf 'docker args:' >> "${COMMAND_LOG}"
printf ' <%s>' "$@" >> "${COMMAND_LOG}"
printf ' stdin-bytes=%s\n' "${#input}" >> "${COMMAND_LOG}"
[[ "${FAIL_DOCKER:-false}" == "true" ]] && exit 19
exit 0
EOF
    chmod +x "${bin_dir}/docker"

    cat > "${bin_dir}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
printf 'helm args:' >> "${COMMAND_LOG}"
printf ' <%s>' "$@" >> "${COMMAND_LOG}"
printf ' stdin-bytes=%s\n' "${#input}" >> "${COMMAND_LOG}"
[[ "${FAIL_HELM:-false}" == "true" ]] && exit 23
exit 0
EOF
    chmod +x "${bin_dir}/helm"

    cat > "${bin_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl args:' >> "${COMMAND_LOG}"
printf ' <%s>' "$@" >> "${COMMAND_LOG}"
printf '\n' >> "${COMMAND_LOG}"
[[ "${FAIL_CURL:-false}" == "true" ]] && exit 7
exit 0
EOF
    chmod +x "${bin_dir}/curl"
}

teardown_case() {
    rm -rf "${test_dir}"
}

run_login() {
    COMMAND_LOG="${log_dir}/commands.log" \
    HARBOR_ENV_FILE="${env_file}" \
    PATH="${bin_dir}:${PATH}" \
    "${PROJECT_ROOT}/scripts/harbor-login.sh" >"${log_dir}/stdout.log" 2>"${log_dir}/stderr.log"
}

test_staging_port_selected_by_default() {
    setup_case
    run_login
    assert_contains "${log_dir}/commands.log" "docker args: <login> <harbor.local:5002>"
    assert_contains "${log_dir}/commands.log" "helm args: <registry> <login> <harbor.local:5002>"
    teardown_case
}

test_final_port_selected_from_state() {
    setup_case
    printf 'HARBOR_ACTIVE_PORT=5001\n' > "${runtime_dir}/state.env"
    run_login
    assert_contains "${log_dir}/commands.log" "docker args: <login> <harbor.local:5001>"
    assert_contains "${log_dir}/commands.log" "curl args: <-fsS> <--resolve> <harbor.local:5001:127.0.0.1>"
    teardown_case
}

test_http_helm_uses_plain_http() {
    setup_case
    run_login
    assert_contains "${log_dir}/commands.log" "<--plain-http>"
    teardown_case
}

test_missing_credentials_file() {
    setup_case
    rm -f "${runtime_dir}/migration-robot.json"
    if run_login; then
        fail "Expected login to fail without credentials."
    fi
    assert_contains "${log_dir}/stderr.log" "Migration robot credentials not found"
    assert_contains "${log_dir}/stderr.log" "make harbor-init"
    teardown_case
}

test_invalid_credentials_json() {
    setup_case
    printf '{not-json\n' > "${runtime_dir}/migration-robot.json"
    if run_login; then
        fail "Expected login to fail with invalid credentials JSON."
    fi
    assert_contains "${log_dir}/stderr.log" "not valid JSON"
    assert_contains "${log_dir}/stderr.log" "make harbor-init"
    teardown_case
}

test_docker_login_failure() {
    setup_case
    if FAIL_DOCKER=true run_login; then
        fail "Expected login to fail when docker login fails."
    fi
    assert_contains "${log_dir}/stderr.log" "Docker login failed"
    assert_contains "${log_dir}/stderr.log" "Docker Desktop insecure registries"
    teardown_case
}

test_helm_login_failure() {
    setup_case
    if FAIL_HELM=true run_login; then
        fail "Expected login to fail when helm login fails."
    fi
    assert_contains "${log_dir}/stderr.log" "Helm registry login failed"
    assert_contains "${log_dir}/stderr.log" "Harbor is running"
    teardown_case
}

test_secret_not_logged() {
    setup_case
    run_login
    assert_not_contains "${log_dir}/stdout.log" "super-secret-token"
    assert_not_contains "${log_dir}/stderr.log" "super-secret-token"
    assert_not_contains "${log_dir}/commands.log" "super-secret-token"
    teardown_case
}

test_staging_port_selected_by_default
test_final_port_selected_from_state
test_http_helm_uses_plain_http
test_missing_credentials_file
test_invalid_credentials_json
test_docker_login_failure
test_helm_login_failure
test_secret_not_logged

echo "[OK] Harbor login tests passed"
