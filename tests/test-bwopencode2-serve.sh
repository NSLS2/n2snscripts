#!/usr/bin/env bash
# Tests for bwopencode2 --serve and --serve-open (argument handling, what is
# printed, the browser choice), through --dry-run.  The sign-in block printed
# inside the sandbox and the host-side helper are tested in
# tests/test_serve_signin.py.
#
# Needs bash and bwrap.  Uses a temporary HOME and a stub OpenCode 2 binary.
# --share-net keeps it independent of pasta and slirp4netns.
# Run on any host:  tests/test-bwopencode2-serve.sh

# shellcheck disable=SC2016  # patterns are single quoted on purpose
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${ROOT}/tests/bwopencode2-harness"
T="$(mktemp -d "${TMPDIR:-/tmp}/bwopencode2-serve-test.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

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
rc_is() { [[ "${RC}" -eq "$1" ]]; }

# ── fixtures ────────────────────────────────────────────────────────────

mkdir -p "${T}/home/.config/opencode2/opencode" "${T}/work" "${T}/oc2" "${T}/bin"
echo '{}' > "${T}/home/.config/opencode2/opencode/opencode.json"
printf '#!/bin/sh\necho "opencode v2.2.7"\n' > "${T}/oc2/opencode.exe"
chmod +x "${T}/oc2/opencode.exe"
# Browsers: stubs that record that they ran (a dry run must never run one).
# They are owned by the test user, so the harness accepts that user and this
# directory in place of root and the system directories (see the end of the
# file for the tests of the real rule).  Modes are set, not left to the umask.
chmod 755 "${T}/bin"
for _b in google-chrome chromium xdg-open firefox; do
    printf '#!/bin/sh\ntouch "%s/ran-%s"\n' "${T}" "${_b}" > "${T}/bin/${_b}"
    chmod 755 "${T}/bin/${_b}"
done

# xdg-mime: prints the default browser registered for http in the test, if any (the
# file default-browser holds its name, https-only-browser the one for https only).
printf '#!/bin/sh\n[ "$3" = x-scheme-handler/http ] && cat "%s/default-browser" 2>/dev/null\n' "${T}" > "${T}/bin/xdg-mime"
chmod 755 "${T}/bin/xdg-mime"

# run [VAR=VALUE ...] -- ARGS...: dry-run the launcher; sets OUT, ERR, RC.  A
# desktop session is assumed (DISPLAY) unless the caller sets DISPLAY= ; the
# harness looks for browsers only in the stub directory, as the test user, so
# a browser the host has does not matter (a caller can override these).
run() {
    local -a _env=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
        _env+=("$1")
        shift
    done
    shift
    OUT="$(cd "${T}/work" && env -u OPENCODE_PASSWORD -u OPENCODE_SERVER_PASSWORD \
        -u BWOPENCODE2_SERVE_PASSWORD -u BWOPENCODE2_SERVE_PORTS -u BWOPENCODE2_SERVE_BROWSER \
        -u OPENCODE2_DB_GUARD -u DISPLAY -u WAYLAND_DISPLAY \
        -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
        HOME="${T}/home" PATH="${T}/bin:${PATH}" DISPLAY=:0 \
        HARNESS_SERVE_OPEN_DIRS="${T}/bin" HARNESS_SERVE_OPEN_UID="$(id -u)" \
        HARNESS_OC2_BIN="${T}/oc2/opencode.exe" ${_env[@]+"${_env[@]}"} \
        "${HARNESS}" --dry-run --share-net "$@" 2> "${T}/err")"
    RC=$?
    ERR="$(cat "${T}/err")"
}

# ── --serve without --serve-open ─────────────────────────────────────────

run -- --serve
check 'a plain --serve succeeds' rc_is 0
check '... says it is starting and where' contains "${ERR}" 'starting the sandboxed OpenCode 2 web UI on 127.'
check '... says the sign-in details follow once the server is up' contains "${ERR}" 'printed once the server is up'
check '... does not mention --serve-open' lacks "${ERR}" '--serve-open'
check 'the sandbox command is the wrapper, given the ssh host and alias' contains "${OUT}" 'bwopencode2-serve'
check '... and a random password is announced to it as such' contains "${OUT}" '-oc random'
check 'the password is passed to the server (hidden)' contains "${OUT}" "OPENCODE_PASSWORD='REDACTED'"
check 'no browser ran' [ ! -e "${T}/ran-google-chrome" ]

check '--serve runs the wrapper in full mode' contains "${OUT}" 'random full'
run -- --serve-open
check '--serve-open with a browser runs the wrapper quietly (the host helper reports)' contains "${OUT}" 'random quiet'
run DISPLAY= -- --serve-open
check '--serve-open with no browser runs the wrapper in local mode' contains "${OUT}" 'random local'
check '... and gives it the reason' contains "${OUT}" 'neither\ DISPLAY\ nor\ WAYLAND_DISPLAY\ is\ set'

run BWOPENCODE2_SERVE_PASSWORD=a-fixed-password-123 -- --serve
check 'a fixed password is announced to the wrapper as fixed' contains "${OUT}" '-oc fixed'
check '... and never printed' lacks "${OUT}${ERR}" 'a-fixed-password-123'
run BWOPENCODE2_SERVE_PASSWORD='a-fixed-"quoted\\"-password' -- --serve
check 'a fixed password with a quote and a backslash is accepted' rc_is 0
run "BWOPENCODE2_SERVE_PASSWORD=a-fixed-password
extra-line = 1" -- --serve
check 'a fixed password with a newline is refused' rc_is 1
check '... saying why' contains "${ERR}" 'must not contain control characters'
check '... and never printed' lacks "${ERR}" 'extra-line'
run "BWOPENCODE2_SERVE_PASSWORD=a-fixed-password-$(printf '\t')tab" -- --serve
check 'a fixed password with a tab is refused too' rc_is 1

# ── --serve-open: arguments ──────────────────────────────────────────────

run -- --serve-open
check '--serve-open works by itself, without --serve' rc_is 0
check '... starts the same server as --serve' contains "${ERR}" 'starting the sandboxed OpenCode 2 web UI on 127.'
check '... and opens the browser' contains "${ERR}" "${T}/bin/google-chrome --app=http://127."
check '... with the same sandbox command as --serve' contains "${OUT}" 'bwopencode2-serve'
check '... and a random password announced to it' contains "${OUT}" '-oc random'
run -- --serve --serve-open
check '--serve --serve-open together mean the same' contains "${ERR}" "${T}/bin/google-chrome --app=http://127."
run -- --serve
check '--serve by itself opens nothing' lacks "${ERR}" '--serve-open'
check '... and starts no browser' [ ! -e "${T}/ran-google-chrome" ]
run -- --serve-open --exec true
check '--serve-open with --exec is refused (as --serve is)' rc_is 1
check '... and says why' contains "${ERR}" '--serve and --serve-open cannot be combined with --exec'
run -- --serve-open --serve-ssh-config
check '--serve-ssh-config still just prints the block' rc_is 0
run -- --serve-open extra-argument
check '--serve-open takes no opencode2 arguments' rc_is 1
run -- --serve-open --publish-addr 127.9.9.9
check '--serve-open cannot be combined with --publish-addr' rc_is 1

# ── --serve-open: the browser ────────────────────────────────────────────

run -- --serve --serve-open
check '--serve-open succeeds on a dry run' rc_is 0
check 'a Chromium-based browser is preferred and gets --app' contains "${ERR}" "${T}/bin/google-chrome --app=http://127."
check '... with a one-time link of its own' contains "${ERR}" '/auth/connect/CODE'
check '... started on this host once the server is up' contains "${ERR}" 'will be started on this host once the server is up'
check 'a dry run starts no browser' [ ! -e "${T}/ran-google-chrome" ]

run BWOPENCODE2_SERVE_BROWSER=xdg-open -- --serve --serve-open
check 'xdg-open gets the plain link' contains "${ERR}" "${T}/bin/xdg-open http://127."
check '... without --app' lacks "${ERR}" '--app='

run BWOPENCODE2_SERVE_BROWSER=firefox -- --serve-open
check 'another browser gets the plain link' contains "${ERR}" "${T}/bin/firefox http://127."

run BWOPENCODE2_SERVE_BROWSER=chromium -- --serve --serve-open
check 'chromium named by the user gets --app' contains "${ERR}" "${T}/bin/chromium --app=http://127."

run BWOPENCODE2_SERVE_BROWSER=no-such-browser-here -- --serve --serve-open
check 'a named browser that does not exist is an error' rc_is 1
check '... that names the variable' contains "${ERR}" 'BWOPENCODE2_SERVE_BROWSER'

run DISPLAY= -- --serve --serve-open
check 'no desktop session: still a normal launch' rc_is 0
check '... says nothing will be opened and why' contains "${ERR}" 'nothing will be opened (neither DISPLAY nor WAYLAND_DISPLAY is set'
check '... and says the link to open by hand is printed' contains "${ERR}" 'link to open by hand'
check '... and names no browser' lacks "${ERR}" '--app='

run DISPLAY= WAYLAND_DISPLAY=wayland-0 -- --serve --serve-open
check 'WAYLAND_DISPLAY alone counts as a desktop session' contains "${ERR}" 'will be started on this host'

# ── --serve-open: no browser installed (a workstation without one) ──────

# HARNESS_SERVE_OPEN_CANDIDATES= : none of the usual browsers is installed.  The
# stub xdg-open is on PATH, as the real one is on a GNOME host, but no default
# browser is registered: xdg-open would hand the link to the text editor.
rm -f "${T}/default-browser"
run HARNESS_SERVE_OPEN_CANDIDATES= -- --serve --serve-open
check 'no browser and no default browser: still a normal launch' rc_is 0
check '... nothing will be opened, and why' contains "${ERR}" 'nothing will be opened (no web browser found'
check '... xdg-open is not used' lacks "${ERR}" 'xdg-open'
check '... and no browser ran' [ ! -e "${T}/ran-xdg-open" ]

echo 'firefox.desktop' > "${T}/default-browser"
run HARNESS_SERVE_OPEN_CANDIDATES= -- --serve --serve-open
check 'a registered default browser is reached through xdg-open' contains "${ERR}" "${T}/bin/xdg-open http://127."
check '... without --app' lacks "${ERR}" '--app='
rm -f "${T}/default-browser"

# A default browser for https only: the link is http, so it does not count.
printf '#!/bin/sh\n[ "$3" = x-scheme-handler/https ] && echo firefox.desktop\n' > "${T}/bin/xdg-mime"
run HARNESS_SERVE_OPEN_CANDIDATES= -- --serve --serve-open
check 'a default browser for https only is not used for the http link' contains "${ERR}" 'nothing will be opened (no web browser found'
printf '#!/bin/sh\n[ "$3" = x-scheme-handler/http ] && cat "%s/default-browser" 2>/dev/null\n' "${T}" > "${T}/bin/xdg-mime"

run HARNESS_SERVE_OPEN_CANDIDATES=firefox -- --serve --serve-open
check 'firefox is used when it is installed' contains "${ERR}" "${T}/bin/firefox http://127."
check '... without --app' lacks "${ERR}" '--app='

run HARNESS_SERVE_OPEN_CANDIDATES="chromium firefox" -- --serve --serve-open
check 'a Chromium-based browser is tried before firefox' contains "${ERR}" "${T}/bin/chromium --app=http://127."

# ── --serve-open: the browser is never taken from where the sandbox can write ──

# These runs use the harness's directory and user (as above) unless they say
# otherwise.  A planted browser is a stub that records that it ran: a dry run
# never runs one, so what matters is which path the launcher would start.
mkdir -p "${T}/evil" "${T}/sys"
chmod 755 "${T}/evil" "${T}/sys"
printf '#!/bin/sh\ntouch "%s/ran-evil"\n' "${T}" > "${T}/evil/google-chrome"
chmod 755 "${T}/evil/google-chrome"

# 1. PATH is not searched: an evil browser first on PATH, outside the directories.
run PATH="${T}/evil:${T}/bin:${PATH}" -- --serve --serve-open
check 'a browser first on PATH, outside the system directories, is not used' lacks "${ERR}" "${T}/evil"
check '... the one in the system directory is' contains "${ERR}" "${T}/bin/google-chrome --app=http://127."

# 2. Only a browser on PATH and nowhere else: nothing is opened.
run HARNESS_SERVE_OPEN_DIRS="${T}/sys" -- --serve --serve-open
check 'a browser that is only on PATH is not found' rc_is 0
check '... nothing will be opened, and why' contains "${ERR}" 'nothing will be opened (no web browser found'
check '... the directories searched are named' contains "${ERR}" "${T}/sys"

# 3. A named browser is held to the same rule.
run PATH="${T}/evil:${PATH}" HARNESS_SERVE_OPEN_DIRS="${T}/sys" BWOPENCODE2_SERVE_BROWSER=google-chrome -- --serve-open
check 'a named browser that is only on PATH is refused' rc_is 1
check '... saying what is required' contains "${ERR}" 'owned by root and not writable by group or others'
run BWOPENCODE2_SERVE_BROWSER="${T}/evil/google-chrome" -- --serve-open
check 'a named absolute path outside the directories is accepted only when it passes' rc_is 0
check '... and it is then the one started' contains "${ERR}" "${T}/evil/google-chrome --app=http://127."
run BWOPENCODE2_SERVE_BROWSER=../evil/google-chrome -- --serve-open
check 'a relative path with a slash is refused' rc_is 1
run BWOPENCODE2_SERVE_BROWSER="${T}/bin/../evil/google-chrome" HARNESS_SERVE_OPEN_UID=0 -- --serve-open
check 'an absolute path owned by someone else is refused' rc_is 1

# 4. The file and its directories must not be writable by group or others.
chmod 775 "${T}/bin/google-chrome"
run -- --serve-open
check 'a group-writable browser is skipped' lacks "${ERR}" "${T}/bin/google-chrome"
check '... the next one is used' contains "${ERR}" "${T}/bin/chromium --app=http://127."
chmod 755 "${T}/bin/google-chrome"
chmod 777 "${T}/bin/chromium"
run HARNESS_SERVE_OPEN_CANDIDATES=chromium -- --serve-open
check 'a world-writable browser is not used' contains "${ERR}" 'nothing will be opened (no web browser found'
chmod 755 "${T}/bin/chromium"
chmod 775 "${T}/bin"
run -- --serve-open
check 'a browser in a group-writable directory is not used' lacks "${ERR}" "${T}/bin/google-chrome"
chmod 755 "${T}/bin"

# 5. A symlink is judged by its target: a root-owned name does not help a
# target that someone else can change, and a symlink to a good target works.
mkdir -p "${T}/real"
chmod 755 "${T}/real"
cp "${T}/bin/firefox" "${T}/real/firefox"
chmod 755 "${T}/real/firefox"
ln -sf "${T}/real/firefox" "${T}/bin/linked-firefox"
run HARNESS_SERVE_OPEN_CANDIDATES=linked-firefox -- --serve-open
check 'a symlink to a trusted file is accepted' contains "${ERR}" "${T}/bin/linked-firefox http://127."
chmod 777 "${T}/real/firefox"
run HARNESS_SERVE_OPEN_CANDIDATES=linked-firefox -- --serve-open
check 'a symlink to a writable file is not' contains "${ERR}" 'nothing will be opened (no web browser found'
chmod 755 "${T}/real/firefox"
chmod 777 "${T}/real"
run HARNESS_SERVE_OPEN_CANDIDATES=linked-firefox -- --serve-open
check 'a symlink to a file in a writable directory is not' contains "${ERR}" 'nothing will be opened (no web browser found'
chmod 755 "${T}/real"
rm -f "${T}/bin/linked-firefox"

# 6. xdg-open and xdg-mime are found the same way.
echo 'firefox.desktop' > "${T}/default-browser"
run HARNESS_SERVE_OPEN_CANDIDATES= HARNESS_SERVE_OPEN_DIRS="${T}/sys" PATH="${T}/bin:${PATH}" -- --serve-open
check 'xdg-mime and xdg-open on PATH only are not used' contains "${ERR}" 'nothing will be opened (no web browser found'
rm -f "${T}/default-browser"

# 7. The real rule.  The first two keep the stub directory (the test user's
# stubs are not owned by root, so they are refused) so the host's own browsers
# do not change the result.
run HARNESS_SERVE_OPEN_UID=0 -- --serve-open
check 'files not owned by root are refused under the real rule' contains "${ERR}" 'nothing will be opened (no web browser found'
run HARNESS_SERVE_OPEN_UID=0 BWOPENCODE2_SERVE_BROWSER=chromium -- --serve-open
check 'a named browser not owned by root is refused' rc_is 1
# With the real directories and owner (the host's own browsers count, so this runs
# only where one is installed): a root-owned one in a system directory is started.
_have=0
for _b in google-chrome google-chrome-stable chromium chromium-browser firefox; do
    for _d in /usr/bin /usr/local/bin /snap/bin; do
        [[ -x "${_d}/${_b}" ]] || continue
        _t="$(readlink -f "${_d}/${_b}")"
        [[ "$(stat -c %u "${_t}")" == 0 ]] && _have=1
    done
done
if [[ "${_have}" -eq 1 ]]; then
    run HARNESS_SERVE_OPEN_DIRS= HARNESS_SERVE_OPEN_UID= -- --serve-open
    check 'with the real directories and owner, a system browser is found' \
        grep -qE '(/usr/bin|/usr/local/bin|/snap/bin)/[a-z-]+ (--app=)?http://127\.' <<< "${ERR}"
fi

# ── nothing else changed ─────────────────────────────────────────────────

run -- --serve --serve-port 24705
check '--serve-port still works' contains "${ERR}" ':24705 (this host only)'
run -- --serve-open --serve-port 24705
check '--serve-port works with --serve-open by itself' contains "${ERR}" ':24705 (this host only)'
run -- --serve-port 24705
check '--serve-port without --serve or --serve-open is refused' rc_is 1
check '... and says why' contains "${ERR}" '--serve-port needs --serve or --serve-open'

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
