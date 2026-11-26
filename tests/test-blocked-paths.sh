#!/usr/bin/env bash
# Tests for the paths that --ro-path and --rw-path refuse, in particular the
# credential directories that Claude Code's managed settings also deny reading
# (sandbox.filesystem.denyRead): ~/.aws, ~/.ssh, ~/.config/gh, ~/.azure and
# ~/.docker.
#
# Sources the library for validate_extra_path, so it needs no sandbox and no
# bwrap.  Needs bash 4 or newer.
# Run on any host:  tests/test-blocked-paths.sh

set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/bwrap_sandbox_lib.sh
source "${ROOT}/lib/bwrap_sandbox_lib.sh"
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
# validate_extra_path exits on a refusal: the launchers call it in $(...), so
# the tests do too.  A refusal counts only when it says why: any other failure
# (an unset variable, say) is not the blocked list at work.
refused() {
    local _out
    _out="$( (validate_extra_path "${_HOME}/$1" "$2") 2>&1)" && return 1
    [[ "${_out}" == *"is inside the blocked path"* ]]
}
allowed() { (validate_extra_path "${_HOME}/$1" "$2") > /dev/null 2>&1; }

# A home directory whose ancestors nobody else can write to, so it is made
# beside the repository's checkout, not in /tmp.
_HOME="$(mktemp -d "${ROOT}/.blocked-test.XXXXXX")"
trap 'rm -rf "${_HOME}"' EXIT
# The blocked list is built from these, which resolve_common_paths sets in the
# launchers, so give them values of their own: the test must not depend on the
# caller's environment.
export HOME="${_HOME}" XDG_CONFIG_HOME="${_HOME}/.config" \
    XDG_DATA_HOME="${_HOME}/.local/share" XDG_RUNTIME_DIR="${_HOME}/run"
mkdir -p "${_HOME}/.aws" "${_HOME}/.azure/sub" "${_HOME}/.config/gh" "${_HOME}/.ssh" \
    "${_HOME}/.docker" "${_HOME}/.azure-opencode-ro" "${_HOME}/Work"

for _dir in .aws .azure .azure/sub .config/gh .ssh .docker; do
    check "--ro-path ~/${_dir} is refused" refused "${_dir}" ro
    check "--rw-path ~/${_dir} is refused" refused "${_dir}" rw
done
check '--ro-path ~/.azure-opencode-ro is allowed (a different directory)' allowed .azure-opencode-ro ro
check '--rw-path ~/.azure-opencode-ro is allowed' allowed .azure-opencode-ro rw
check 'an ordinary directory is allowed' allowed Work ro

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
