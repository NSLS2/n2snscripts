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
for _b in google-chrome chromium xdg-open firefox; do
    printf '#!/bin/sh\ntouch "%s/ran-%s"\n' "${T}" "${_b}" > "${T}/bin/${_b}"
    chmod +x "${T}/bin/${_b}"
done

# xdg-mime: prints the default browser registered for http in the test, if any (the
# file default-browser holds its name, https-only-browser the one for https only).
printf '#!/bin/sh\n[ "$3" = x-scheme-handler/http ] && cat "%s/default-browser" 2>/dev/null\n' "${T}" > "${T}/bin/xdg-mime"
chmod +x "${T}/bin/xdg-mime"

# run [VAR=VALUE ...] -- ARGS...: dry-run the launcher; sets OUT, ERR, RC.  A
# desktop session is assumed (DISPLAY) unless the caller sets DISPLAY= ; PATH
# has the stub browsers first, so a browser the host has does not matter for
# the tests that name one.
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
