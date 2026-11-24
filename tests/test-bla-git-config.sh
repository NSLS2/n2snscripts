#!/usr/bin/env bash
# Tests for the git config bla writes for a session: the commit identity, the
# credential helper for https://github.com, the keys the agent reads, and the
# messages about the push token and the profile collection mount.
#
# Sources bin/bla for its functions (main is not run), so it needs no agent
# account, no sudo and no /run/nsls2. Uses a temporary HOME, a made-up token
# and the real git.  Needs bash 4 or newer and git.
# Run on any host:  tests/test-bla-git-config.sh

# shellcheck disable=SC2016  # patterns are single quoted on purpose
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/bla-git-config-test.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

# shellcheck source=../bin/bla
source "${ROOT}/bin/bla"
# bla turns these on for itself; a failing check must not end the tests.
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
is() { [[ "$1" == "$2" ]]; }

# ── fixtures ────────────────────────────────────────────────────────────

readonly DUMMY=not-a-real-token-AAAA
readonly DUMMY2=not-a-real-token-BBBB
mkdir -p "${T}/home" "${T}/creds/github-push" "${T}/agent" "${T}/profile" "${T}/xdg"
TOKEN="${T}/creds/github-push/token"
printf '%s\n' "${DUMMY}" > "${TOKEN}"

# git with only the config under test: no system, user or repository config,
# and nothing to ask, so a helper that gives no answer makes git fail.
cd "${T}" || exit 1
g() {
    env -i PATH="${PATH}" HOME="${T}/home" XDG_CONFIG_HOME="${T}/xdg" \
        GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        git "$@"
}
# fill URL: what git would send for URL; sets OUT and RC.
fill() {
    local _proto="${1%%://*}" _host="${1#*://}"
    OUT="$(printf 'protocol=%s\nhost=%s\n\n' "${_proto}" "${_host}" | g credential fill 2> /dev/null)"
    RC=$?
}
# fill_asking URL: the same where git could ask: no GIT_TERMINAL_PROMPT=0, and
# an askpass that records being called and would supply an answer.
printf '#!/bin/sh\n: > "%s"\necho asked\n' "${T}/asked" > "${T}/askpass"
chmod +x "${T}/askpass"
fill_asking() {
    local _proto="${1%%://*}" _host="${1#*://}"
    rm -f "${T}/asked"
    OUT="$(printf 'protocol=%s\nhost=%s\n\n' "${_proto}" "${_host}" |
        env -i PATH="${PATH}" HOME="${T}/home" XDG_CONFIG_HOME="${T}/xdg" \
            GIT_CONFIG_NOSYSTEM=1 GIT_ASKPASS="${T}/askpass" \
            git credential fill 2> /dev/null)"
    RC=$?
}
not_asked() { [[ ! -e "${T}/asked" ]]; }
rc_is() { [[ "${RC}" -eq "$1" ]]; }
# refuses COMMAND...: COMMAND ends with die (in a subshell, so the tests go on).
refuses() { ! ("$@") 2> /dev/null; }
quiet() { "$@" > /dev/null 2>&1; }

write_git_config "${T}/home" alice "${TOKEN}" "${T}/profile" "${T}/agent"
CONFIG="$(< "${T}/home/.gitconfig")"

# ── the file ────────────────────────────────────────────────────────────

check 'git can read the config' quiet g config --list
check 'the token is not in the config' lacks "${CONFIG}" "${DUMMY}"
check 'the token path is in the config' contains "${CONFIG}" "${TOKEN}"
check 'the profile collection is a safe directory' \
    contains "$(g config --get-all safe.directory)" "${T}/profile"
check 'the agent directory is a safe directory' \
    contains "$(g config --get-all safe.directory)" "${T}/agent"

# ── identity ────────────────────────────────────────────────────────────

check 'the name is the agent account and the caller' \
    is "$(g config user.name)" "${AGENT_ACCOUNT} (${PROGRAM_NAME} for alice)"
check 'the email is the agent account on this host' \
    is "$(g config user.email)" "${AGENT_ACCOUNT}@$(uname -n)"
check 'bla.caller is the caller' is "$(g config bla.caller)" alice
check 'bla.agentDir is the agent directory' is "$(g config bla.agentDir)" "${T}/agent"
check 'bla.profileCollection is the profile collection' \
    is "$(g config bla.profileCollection)" "${T}/profile"

# ── credential helper ───────────────────────────────────────────────────

fill https://github.com
check 'github.com over https is answered' rc_is 0
check '... with the user name' contains "${OUT}" 'username=x-access-token'
check '... and the token' contains "${OUT}" "password=${DUMMY}"

printf '%s\n' "${DUMMY2}" > "${TOKEN}"
fill https://github.com
check 'a renewed token is picked up without rewriting the config' contains "${OUT}" "password=${DUMMY2}"

for _url in http://github.com https://gist.github.com https://example.com https://github.com.example.com; do
    fill "${_url}"
    check "${_url} gets no token" lacks "${OUT}" "${DUMMY2}"
done

HELPER="$(g config --get-all credential.https://github.com.helper | tail -n 1)"
check 'an earlier helper for the URL is dropped first' \
    is "$(g config --get-all credential.https://github.com.helper | head -n 1)" ''
for _op in store erase; do
    check "the helper says nothing for ${_op}" \
        is "$(sh -c "${HELPER#!} ${_op}" < /dev/null 2>&1)" ''
done
if command -v dash > /dev/null; then
    check 'the helper runs under dash' \
        contains "$(dash -c "${HELPER#!} get" < /dev/null 2>&1)" "password=${DUMMY2}"
fi

: > "${TOKEN}"
fill https://github.com
check 'an empty token gives no password' lacks "${OUT}" 'password='
check '... and git fails' rc_is 128
fill_asking https://github.com
check '... without asking, even where it could' not_asked
check '... and still fails' rc_is 128
check '... and gives no password' lacks "${OUT}" 'password='
rm -f "${TOKEN}"
fill https://github.com
check 'a missing token gives no password' lacks "${OUT}" 'password='
fill_asking https://github.com
check '... and git fails without asking' not_asked
check '... with the same status' rc_is 128
check 'with no token the helper tells git to stop' \
    is "$(sh -c "${HELPER#!} get" < /dev/null 2>&1)" 'quit=true'
fill_asking https://example.com
check 'the askpass fixture does get called for a host with no helper' test -e "${T}/asked"

# ── without a profile collection ────────────────────────────────────────

mkdir -p "${T}/home2"
write_git_config "${T}/home2" alice "${TOKEN}" "" "${T}/agent"
CONFIG2="$(< "${T}/home2/.gitconfig")"
check 'no profile collection: no bla.profileCollection' lacks "${CONFIG2}" 'profileCollection'
check 'no profile collection: the agent directory is still safe' contains "${CONFIG2}" "directory = ${T}/agent"
check 'no profile collection: bla.agentDir is still set' \
    is "$(HOME="${T}/home2" git config --file "${T}/home2/.gitconfig" bla.agentDir)" "${T}/agent"

for _bad in "/tmp/it's/token" '/tmp/$x/token' '/tmp/a"b/token' '/tmp/a\b/token' '/tmp/a`b`/token'; do
    check "a token path that cannot be quoted is refused: ${_bad}" \
        refuses write_git_config "${T}/home2" alice "${_bad}" "" "${T}/agent"
done

# ── messages ────────────────────────────────────────────────────────────

MSG="$(say_push_token_state "${TOKEN}" 2>&1)"
check 'no token: the agent cannot push' contains "${MSG}" 'can edit and commit but not push'
: > "${TOKEN}"
MSG="$(say_push_token_state "${TOKEN}" 2>&1)"
check 'empty token: the agent cannot push' contains "${MSG}" 'can edit and commit but not push'
printf '%s\n' "${DUMMY}" > "${TOKEN}"
MSG="$(say_push_token_state "${TOKEN}" 2>&1)"
check 'fresh token: the agent can push' contains "${MSG}" 'the agent can push'
check '... and the token is not printed' lacks "${MSG}" "${DUMMY}"
touch -t 202001010000 "${TOKEN}"
MSG="$(say_push_token_state "${TOKEN}" 2>&1)"
check 'old token: the agent cannot push' contains "${MSG}" 'over an hour old'
check '... and the token is not printed' lacks "${MSG}" "${DUMMY}"

MSG="$(say_how_to_publish "${T}/profile" "${T}/agent" 2>&1)"
check 'the hand-off names the pull command' contains "${MSG}" "cd ${T}/profile && git pull --ff-only"
check 'no profile collection: no hand-off message' is "$(say_how_to_publish '' "${T}/agent" 2>&1)" ''

# ── mount option ────────────────────────────────────────────────────────

check 'a writable profile collection is mounted read-write' \
    is "$(profile_mount_option "${T}/profile")" --rw-path
chmod 555 "${T}/profile"
if [[ "$(id -u)" -ne 0 ]]; then
    check 'an unwritable profile collection is mounted read-only' \
        is "$(profile_mount_option "${T}/profile")" --ro-path
fi
chmod 755 "${T}/profile"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
