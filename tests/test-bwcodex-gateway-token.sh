#!/usr/bin/env bash
# Tests for how bwcodex reaches the AI gateway: with the n2c-token "aifapim"
# token (your own Entra token, a provider with an auth command, no key) when
# --n2c-token mounted it, and with the key from config.toml otherwise.
#
# Sources bin/bwcodex for build_codex_env (main is not run), so it needs no
# sandbox, no bwrap and no codex.  Needs bash 4 or newer.
# Run on any host:  tests/test-bwcodex-gateway-token.sh

# shellcheck disable=SC2016,SC2034  # patterns are single quoted on purpose; globals are read by the sourced script
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../bin/bwcodex
source "${ROOT}/bin/bwcodex"
# bwcodex turns these on for itself; a failing check must not end the tests.
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
is_one() { [[ "$1" == 1 ]]; }
is_empty() { [[ -z "$1" ]]; }

readonly TOKEN=/run/user/1000/nsls2/creds/aifapim/token
readonly KEY=not-a-real-key-AAAA
readonly HOST=gateway.example.org
readonly PROVIDER='-c model_provider="nsls2-hermes-token" -c model_providers.nsls2-hermes-token='

# env_body [VAR=VALUE...]: build_codex_env with the given host environment;
# prints what it added, then the exit code (the EXIT trap).  N2C_TOKEN_FILES
# is set by the caller, as build_n2c_token_mounts would.  Run it in a subshell:
# build_codex_env can exit.
env_body() {
    unset AIFAPIM_HOST AIFAPIM_API_KEY OPENAI_API_KEY
    local _kv
    for _kv in "$@"; do export "${_kv?}"; done
    BWRAP_ARGS=()
    SANDBOX_ENV=()
    TOOL_ARGS=(resume)
    # What bwrap_resolve_tool sets: the --exec command split into words, or the
    # codex it found.
    if [[ -n "${TEST_CMD}" ]]; then
        read -ra _TOOL_CMD <<< "${TEST_CMD}"
    else
        _TOOL_CMD=(/usr/local/bin/codex)
    fi
    trap 'printf "exit=%s\n" "$?"' EXIT
    build_codex_env 2>&1
    printf 'BWRAP %s\n' "${BWRAP_ARGS[*]-}"
    printf 'ENV %s\n' "${SANDBOX_ENV[*]-}"
    printf 'ARGS %s\n' "${TOOL_ARGS[*]-}"
    printf 'CMD %s\n' "${_TOOL_CMD[*]-}"
}
run_env() { (env_body "$@"); }
cmd_line() { grep '^CMD' <<< "$1"; }

# ── token mode ──────────────────────────────────────────────────────────

N2C_TOKEN_FILES=("${TOKEN}")
OUT="$(run_env)"
CMD="$(cmd_line "${OUT}")"
check 'token: the provider is chosen after the binary' \
    contains "${CMD}" "CMD /usr/local/bin/codex ${PROVIDER}"
check 'token: base URL defaults to hermes' \
    contains "${CMD}" 'base_url="https://hermes.nsls2.bnl.gov/openai/v1"'
check 'token: Responses API' contains "${CMD}" 'wire_api="responses"'
check 'token: auth command reads the token file' \
    contains "${CMD}" "auth={command=\"cat\", args=[\"${TOKEN}\"]}"
check 'token: the original arguments are still there' contains "${OUT}" 'ARGS resume'
check 'token: no key needed' contains "${OUT}" 'exit=0'
check 'token: no env_key in the provider' lacks "${CMD}" 'env_key'

OUT="$(run_env AIFAPIM_HOST="${HOST}")"
check 'token: AIFAPIM_HOST picks the gateway' \
    contains "$(cmd_line "${OUT}")" "base_url=\"https://${HOST}/openai/v1\""

OUT="$(run_env AIFAPIM_API_KEY="${KEY}")"
check 'token: a key on the host is not passed into the sandbox' lacks "${OUT}" "${KEY}"

TEST_CMD=bash OUT="$(run_env)"
check 'token: --exec bash gets no provider' lacks "${OUT}" 'model_provider'
TEST_CMD=/usr/local/bin/codex OUT="$(run_env)"
check 'token: --exec of codex gets the provider' contains "$(cmd_line "${OUT}")" 'model_provider'
TEST_CMD="codex exec" OUT="$(run_env)"
check 'token: --exec of codex with a subcommand gets it before the subcommand' \
    contains "$(cmd_line "${OUT}")" '} exec'
TEST_CMD="  /usr/local/bin/codex" OUT="$(run_env)"
check 'token: --exec of codex after leading blanks gets the provider' \
    contains "$(cmd_line "${OUT}")" 'model_provider'
TEST_CMD=$'codex\texec' OUT="$(run_env)"
check 'token: --exec of codex with a tab-separated argument gets the provider' \
    contains "$(cmd_line "${OUT}")" 'model_provider'
TEST_CMD=$'bash\tcodex' OUT="$(run_env)"
check 'token: --exec of bash with codex as an argument gets no provider' lacks "${OUT}" 'model_provider'
TEST_CMD='codex -- foo' OUT="$(run_env)"
check 'token: the provider goes before a -- of the --exec command' \
    contains "$(cmd_line "${OUT}")" '}} -- foo'
TEST_CMD=""

N2C_TOKEN_FILES=('/run/user/1000/a b/aifapim/token')
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

mount_env() { # mount_env TOKEN-NAME: --n2c-token NAME, then build_codex_env
    EXTRA_RO_PATHS=()
    N2C_TOKEN_FILES=()
    N2C_TOKENS=()
    add_n2c_token "$1"
    build_n2c_token_mounts 2> /dev/null
    run_env AIFAPIM_API_KEY="${KEY}"
}
OUT="$(mount_env all)"
check 'all: the aifapim token is found and used' \
    contains "$(cmd_line "${OUT}")" "args=[\"${CREDS}/aifapim/token\"]"
OUT="$(mount_env aifapim)"
check 'aifapim: used' contains "$(cmd_line "${OUT}")" "${CREDS}/aifapim/token"
OUT="$(mount_env observability)"
check 'observability only: key mode, the key goes through the environment' \
    contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"
check '... and no provider is added' lacks "${OUT}" 'model_provider'
unset N2SN_CREDS_DIR

# ── the aifapim token without --n2c-token ───────────────────────────────
# The automatic step adds it to whatever --n2c-token asked for, when its file
# exists, unless N2C_GATEWAY=off.  A second credentials directory has no
# aifapim file, as for someone without the gateway role.

CREDS2="${CREDS%/creds}/creds2"
mkdir -p "${CREDS2}/observability"
chmod 700 "${CREDS2}" "${CREDS2}/observability"
printf 'not-a-real-token\n' > "${CREDS2}/observability/token"
chmod 600 "${CREDS2}/observability/token"

# auto_env [NAME...]: --n2c-token NAME for each name, the automatic step, the
# mounts, then build_codex_env.  Prints the mounted files first.
auto_env() {
    EXTRA_RO_PATHS=()
    N2C_TOKEN_FILES=()
    N2C_TOKENS=()
    local _n
    for _n in "$@"; do add_n2c_token "${_n}"; done
    n2c_auto_gateway_token
    build_n2c_token_mounts 2> /dev/null
    printf 'FILES %s\n' "${N2C_TOKEN_FILES[*]-}"
    run_env AIFAPIM_API_KEY="${KEY}" AIFAPIM_HOST="${HOST}"
}
# auto_err [NAME...]: what the mount step says on stderr
auto_err() {
    EXTRA_RO_PATHS=()
    N2C_TOKEN_FILES=()
    N2C_TOKENS=()
    local _n
    for _n in "$@"; do add_n2c_token "${_n}"; done
    n2c_auto_gateway_token
    build_n2c_token_mounts 2>&1
}
files_line() { grep '^FILES' <<< "$1"; }

export N2SN_CREDS_DIR="${CREDS}"
OUT="$(auto_env)"
check 'automatic: no flag, token file exists: the token is mounted' \
    contains "$(files_line "${OUT}")" "${CREDS}/aifapim/token"
check '... and nothing else' lacks "$(files_line "${OUT}")" observability
check '... and token mode is used' contains "$(cmd_line "${OUT}")" 'model_provider'

OUT="$(auto_env observability)"
check '--n2c-token observability: aifapim is added to it' \
    contains "$(files_line "${OUT}")" "${CREDS}/aifapim/token"
check '... and observability is mounted too' contains "$(files_line "${OUT}")" "${CREDS}/observability/token"
check '... and token mode is used' contains "$(cmd_line "${OUT}")" 'model_provider'

OUT="$(auto_env aifapim)"
check '--n2c-token aifapim: used' contains "$(cmd_line "${OUT}")" 'model_provider'
check '... and mounted once' \
    is_one "$(grep -o "aifapim/token" <<< "$(files_line "${OUT}")" | wc -l | tr -d ' ')"

OUT="$(N2C_GATEWAY=off auto_env)"
check 'N2C_GATEWAY=off: nothing is mounted without a flag' \
    lacks "$(files_line "${OUT}")" aifapim
check '... and the key is used' contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"

OUT="$(N2C_GATEWAY=off auto_env all)"
check 'N2C_GATEWAY=off with --n2c-token all: aifapim is mounted (for skills)' \
    contains "$(files_line "${OUT}")" "${CREDS}/aifapim/token"
check '... but not used for the gateway' lacks "$(cmd_line "${OUT}")" 'model_provider'
check '... and the key is used' contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"

export N2SN_CREDS_DIR="${CREDS2}"
OUT="$(auto_env observability)"
check 'no aifapim file: only what was asked for is mounted' \
    lacks "$(files_line "${OUT}")" aifapim
check '... and the key is used' contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"
check 'no aifapim file, observability asked for: nothing is said' is_empty "$(auto_err observability)"
check 'no aifapim file, nothing asked for: nothing is said' is_empty "$(auto_err)"
check '--n2c-token aifapim without a file still warns' contains "$(auto_err aifapim)" "no N2C token 'aifapim'"
export N2SN_CREDS_DIR=/nonexistent/creds
check 'no credentials directory, no flag: nothing is said' is_empty "$(auto_err)"
unset N2SN_CREDS_DIR

# A --ro-path is canonicalised and mounted at its target, so a path that only
# looks like the token (a symlink, say) must not switch the token mode on.
N2C_TOKEN_FILES=()
EXTRA_RO_PATHS=("${TOKEN}")
OUT="$(run_env AIFAPIM_API_KEY="${KEY}")"
check 'a --ro-path ending in aifapim/token is not the token' lacks "${OUT}" 'model_provider'
check '... and key mode is used' contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"
EXTRA_RO_PATHS=()

# ── auth.json: not in token mode ────────────────────────────────────────
# Codex tries to refresh a ChatGPT login even when the provider does not use
# it, so an expired one there fails a gateway session.  The file is bound only
# without the token, or when --init-auth asks for it.

HOMEDIR="$(mktemp -d "${ROOT}/.codexhome-test.XXXXXX")"
trap 'rm -rf "${CREDS%/creds}" "${HOMEDIR}"' EXIT
CODEX_HOME_DIR="${HOMEDIR}/.codex"
mkdir -p "${CODEX_HOME_DIR}"
CODEX_CONFIG_FILE="${CODEX_HOME_DIR}/config.toml"
CODEX_AGENTS_FILE="${CODEX_HOME_DIR}/AGENTS.md"
CODEX_AUTH_FILE="${CODEX_HOME_DIR}/auth.json"
CODEX_HISTORY_FILE="${CODEX_HOME_DIR}/history.jsonl"
CODEX_DAEMON_SETTINGS_FILE="${CODEX_HOME_DIR}/app-server-daemon/settings.json"
SYSTEM_CODEX_CONFIG_FILE=/nonexistent
SYSTEM_CODEX_REQUIREMENTS_FILE=/nonexistent
printf '{}\n' > "${CODEX_AUTH_FILE}"
DRY_RUN=1
PERSIST_CONFIG=0

# home_args TOKEN-FILES INIT-AUTH: the bwrap arguments for the Codex home
home_args() {
    BWRAP_ARGS=()
    N2C_TOKEN_FILES=("${1:+${TOKEN}}")
    [[ -n "${1}" ]] || N2C_TOKEN_FILES=()
    INIT_AUTH="$2"
    build_codex_home_mount > /dev/null 2>&1
    printf '%s' "${BWRAP_ARGS[*]}"
}
AUTH_BIND="--bind ${CODEX_AUTH_FILE} ${CODEX_AUTH_FILE}"
check 'no token: auth.json is bound' contains "$(home_args '' 0)" "${AUTH_BIND}"
check 'token: auth.json is not bound' lacks "$(home_args yes 0)" "${AUTH_BIND}"
check 'token with --init-auth: auth.json is bound' contains "$(home_args yes 1)" "${AUTH_BIND}"
DRY_RUN=0
INIT_AUTH=0

# ── key mode ────────────────────────────────────────────────────────────

OUT="$(run_env AIFAPIM_API_KEY="${KEY}" AIFAPIM_HOST="${HOST}")"
check 'key: the key goes through the environment' contains "${OUT}" "AIFAPIM_API_KEY=${KEY}"
check 'key: the key is not on the bwrap command line' lacks "$(grep '^BWRAP' <<< "${OUT}")" "${KEY}"
check 'key: the command is not changed' contains "${OUT}" 'CMD /usr/local/bin/codex'
check 'key: OPENAI_API_KEY is a dummy for the provider preflight' \
    contains "${OUT}" '--setenv OPENAI_API_KEY dummy'

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
