#!/usr/bin/env bash
# Tests for how bwclaude reaches the AI gateway: with the n2c-token "aifapim"
# token (your own Entra token, an apiKeyHelper, no key) when it is mounted, and
# with a key in Foundry mode otherwise.
#
# Sources bin/bwclaude for build_claude_env (main is not run), so it needs no
# sandbox, no bwrap and no claude.  Needs bash 4 or newer.
# Run on any host:  tests/test-bwclaude-gateway-token.sh

# shellcheck disable=SC2016,SC2034  # patterns are single quoted on purpose; globals are read by the sourced script
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../bin/bwclaude
source "${ROOT}/bin/bwclaude"
# bwclaude turns these on for itself; a failing check must not end the tests.
set +o errexit

PASS=0
FAIL=0
check() { # check DESCRIPTION CONDITION-COMMAND...
    local _desc="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf 'ok    %s\n' "${_desc}"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "${_desc}"
    fi
}
contains() { grep -qF -- "$2" <<< "$1"; }
lacks() { ! grep -qF -- "$2" <<< "$1"; }

readonly TOKEN=/run/user/1000/nsls2/creds/aifapim/token
readonly KEY=not-a-real-key-AAAA
readonly HOST=gateway.example.org

# env_body [VAR=VALUE...]: build_claude_env with the given host environment;
# prints what it added, then the exit code (the EXIT trap).  EXTRA_RO_PATHS is
# set by the caller, as build_n2c_token_mounts would.  Run it in a subshell:
# build_claude_env can exit.
env_body() {
    unset AIFAPIM_HOST AIFAPIM_API_KEY ANTHROPIC_FOUNDRY_API_KEY \
        ANTHROPIC_FOUNDRY_BASE_URL CLAUDE_CODE_USE_FOUNDRY
    local _kv
    for _kv in "$@"; do export "${_kv?}"; done
    BWRAP_ARGS=()
    SANDBOX_ENV=()
    TOOL_ARGS=(--resume)
    trap 'printf "exit=%s\n" "$?"' EXIT
    build_claude_env 2>&1
    printf 'BWRAP %s\n' "${BWRAP_ARGS[*]-}"
    printf 'ENV %s\n' "${SANDBOX_ENV[*]-}"
    printf 'ARGS %s\n' "${TOOL_ARGS[*]-}"
}
run_env() { (env_body "$@"); }

# ── token mode ──────────────────────────────────────────────────────────

EXTRA_RO_PATHS=("${TOKEN}")
OUT="$(run_env)"
check 'token: base URL defaults to hermes' \
    contains "${OUT}" '--setenv ANTHROPIC_BASE_URL https://hermes.nsls2.bnl.gov/anthropic'
check 'token: apiKeyHelper reads the token file' \
    contains "${OUT}" "ARGS --settings {\"apiKeyHelper\":\"cat ${TOKEN}\"} --resume"
check 'token: Foundry mode is switched off' contains "${OUT}" '--unsetenv CLAUDE_CODE_USE_FOUNDRY'
check 'token: Foundry mode is not switched on' lacks "${OUT}" 'CLAUDE_CODE_USE_FOUNDRY 1'
check 'token: no key needed' contains "${OUT}" 'exit=0'
check 'token: no Foundry variables' lacks "${OUT}" 'ANTHROPIC_FOUNDRY'

OUT="$(run_env AIFAPIM_HOST=hermes-dev.nsls2.bnl.gov)"
check 'token: AIFAPIM_HOST picks the gateway' \
    contains "${OUT}" '--setenv ANTHROPIC_BASE_URL https://hermes-dev.nsls2.bnl.gov/anthropic'

OUT="$(run_env AIFAPIM_API_KEY="${KEY}" CLAUDE_CODE_USE_FOUNDRY=1)"
check 'token: a key on the host is not used' lacks "${OUT}" "${KEY}"
check 'token: a host CLAUDE_CODE_USE_FOUNDRY is unset again' \
    contains "${OUT}" '--unsetenv CLAUDE_CODE_USE_FOUNDRY'

TEST_CMD=bash OUT="$(run_env)"
check 'token: --exec gets no --settings' lacks "${OUT}" 'ARGS --settings'
TEST_CMD=""

EXTRA_RO_PATHS=('/run/user/1000/a b/aifapim/token')
OUT="$(run_env)"
check 'token: a path that needs quoting is refused' contains "${OUT}" 'may only contain'
check '... and stops the launch' contains "${OUT}" 'exit=1'

# ── --n2c-token all, through the real mount function ────────────────────
# The creds directory needs ancestors that nobody else can write to, so it is
# made beside the repository's checkout, not in /tmp.

CREDS="$(mktemp -d "${ROOT}/.n2c-all-test.XXXXXX")/creds"
trap 'rm -rf "${CREDS%/creds}"' EXIT
mkdir -p "${CREDS}/aifapim" "${CREDS}/observability"
chmod 700 "${CREDS}" "${CREDS}/aifapim" "${CREDS}/observability"
for _n in aifapim observability; do
    printf 'not-a-real-token\n' > "${CREDS}/${_n}/token"
    chmod 600 "${CREDS}/${_n}/token"
done
export N2SN_CREDS_DIR="${CREDS}"

mount_env() { # mount_env TOKEN-NAME: --n2c-token NAME, then build_claude_env
    EXTRA_RO_PATHS=()
    N2C_TOKENS=()
    add_n2c_token "$1"
    build_n2c_token_mounts 2> /dev/null
    env_body AIFAPIM_API_KEY="${KEY}" AIFAPIM_HOST="${HOST}"
}
OUT="$(mount_env all)"
check 'all: the aifapim token is found and used' \
    contains "${OUT}" "{\"apiKeyHelper\":\"cat ${CREDS}/aifapim/token\"}"
OUT="$(mount_env aifapim)"
check 'aifapim: used' contains "${OUT}" "cat ${CREDS}/aifapim/token"
OUT="$(mount_env observability)"
check 'observability only: key mode' contains "${OUT}" '--setenv CLAUDE_CODE_USE_FOUNDRY 1'
unset N2SN_CREDS_DIR

# ── key mode (legacy) ───────────────────────────────────────────────────

EXTRA_RO_PATHS=("/run/user/1000/nsls2/creds/observability/token")
OUT="$(run_env AIFAPIM_API_KEY="${KEY}" AIFAPIM_HOST=aifapim.nsls2.bnl.gov)"
check 'key: Foundry mode is on' contains "${OUT}" '--setenv CLAUDE_CODE_USE_FOUNDRY 1'
check 'key: Foundry base URL from AIFAPIM_HOST' \
    contains "${OUT}" '--setenv ANTHROPIC_FOUNDRY_BASE_URL https://aifapim.nsls2.bnl.gov/anthropic'
check 'key: the key goes through the environment' contains "${OUT}" "ENV ANTHROPIC_FOUNDRY_API_KEY=${KEY}"
check 'key: the key is not on the bwrap command line' lacks "$(grep '^BWRAP' <<< "${OUT}")" "${KEY}"
check 'key: no --settings' lacks "${OUT}" 'ARGS --settings'

OUT="$(run_env)"
check 'no key and no token: stops' contains "${OUT}" 'exit=1'
check '... and names --n2c-token aifapim' contains "${OUT}" 'bwclaude --n2c-token aifapim'

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
