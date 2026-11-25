#!/usr/bin/env bash
# Tests for pasta on Lustre clients: pasta's tap device gets its own name (-I
# sbx0) so that it cannot take the host's LNet interface down, and on a host
# with LNet loaded a pasta without --ns-ifname is not used.  See "Lustre
# clients" in lib/bwrap_sandbox_lib.sh.
#
# Sources the library and calls detect_net_capabilities under --dry-run, with
# a stub pasta that records every start, the fake slirp4netns of tests/fakes,
# and a made-up /sys/module.  Needs bash and python3; no bwrap, no
# /dev/net/tun, no network.
# Run on any host:  tests/test-net-lustre-guard.sh

# shellcheck disable=SC2016  # patterns are single quoted on purpose
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib/bwrap_sandbox_lib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/net-lustre-guard-test.XXXXXX")"
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
pasta_only_asked_for_help() { ! grep -qv -- '^--help$' "${T}/pasta.calls" 2> /dev/null; }

# ── fixtures ────────────────────────────────────────────────────────────

# The host tools the library uses on this path, and nothing else, so that a
# pasta or slirp4netns the machine has does not matter.
mkdir -p "${T}/tools" "${T}/pasta-bin" "${T}/slirp-bin" "${T}/mod-lnet/lnet" "${T}/mod-none/kvm"
for _t in bash env python3 timeout cat sort head; do
    ln -s "$(command -v "${_t}")" "${T}/tools/${_t}"
done
ln -s "${ROOT}/tests/fakes/bin/slirp4netns" "${T}/slirp-bin/slirp4netns"
# A stub pasta: logs the arguments of every start, prints a help text with or
# without --ns-ifname ($STUB_PASTA_NS_IFNAME=0).  Nothing here may start a
# real one.
cat > "${T}/pasta-bin/pasta" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_PASTA_CALLS}"
if [[ "$1" == --help ]]; then
    echo "Usage: pasta [OPTION]... [COMMAND [ARG]...]"
    [[ "${STUB_PASTA_NS_IFNAME:-1}" == 0 ]] || printf '  -I, --ns-ifname NAME\tnamespace interface name\n'
    printf '  --no-pidns\t\tDon'\''t spawn command in a new PID namespace\n'
fi
exit 0
EOF
chmod +x "${T}/pasta-bin/pasta"

# detect [VAR=VALUE ...] -- [PASTA] [SLIRP] [SETTING=VALUE ...]: run
# detect_net_capabilities with pasta and slirp4netns on PATH as asked ("pasta"
# and "slirp" or "-"), and the settings given to the library (MOD=lnet|none,
# FORCE=pasta|slirp4netns, SHARE=1, HOSTPORT=1).  Sets OUT, ERR, RC.
detect() {
    local -a _env=()
    local _path="${T}/tools" _mod=none _force="" _share=0 _hp=0 _s
    while [[ $# -gt 0 && "$1" != -- ]]; do
        _env+=("$1")
        shift
    done
    shift
    [[ "$1" != pasta ]] || _path="${T}/pasta-bin:${_path}"
    [[ "$2" != slirp ]] || _path="${T}/slirp-bin:${_path}"
    shift 2
    for _s in "$@"; do
        case "${_s}" in
            MOD=*) _mod="${_s#MOD=}" ;;
            FORCE=*) _force="${_s#FORCE=}" ;;
            SHARE=*) _share="${_s#SHARE=}" ;;
            HOSTPORT=*) _hp="${_s#HOSTPORT=}" ;;
        esac
    done
    rm -f "${T}/pasta.calls"
    OUT="$(env -i PATH="${_path}" HOME="${T}" STUB_PASTA_CALLS="${T}/pasta.calls" \
        ${_env[@]+"${_env[@]}"} \
        bash -c '
            source "$1" || exit 99
            _NET_SYSFS_MODULE_DIR="$2"
            DRY_RUN=1
            NET_BACKEND_FORCE="$3"
            NET_SHARE="$4"
            [[ "$5" != 1 ]] || NET_HOST_PORTS=(8080)
            detect_net_capabilities
            printf "backend=%s\n" "${_NET_BACKEND}"
            printf "args=%s\n" "${PASTA_ARGS[*]}"
        ' _ "${LIB}" "${T}/mod-${_mod}" "${_force}" "${_share}" "${_hp}" 2> "${T}/err")"
    RC=$?
    ERR="$(cat "${T}/err")"
}

# ── a host without Lustre: as before, plus -I ───────────────────────────

detect -- pasta slirp MOD=none
check 'no LNet: pasta is used' contains "${OUT}" 'backend=pasta'
check '... with its tap device named sbx0' contains "${OUT}" ' -I sbx0'
check '... and the other options unchanged' contains "${OUT}" '--config-net --no-map-gw'

detect STUB_PASTA_NS_IFNAME=0 -- pasta slirp MOD=none
check 'no LNet, pasta without --ns-ifname: pasta is still used' contains "${OUT}" 'backend=pasta'
check '... without -I' lacks "${OUT}" ' -I '

detect -- - slirp MOD=none
check 'no LNet, no pasta: slirp4netns' contains "${OUT}" 'backend=slirp4netns'

# ── a Lustre client with a pasta that has --ns-ifname ────────────────────

detect -- pasta slirp MOD=lnet
check 'LNet: pasta is used' contains "${OUT}" 'backend=pasta'
check '... with its tap device named sbx0' contains "${OUT}" ' -I sbx0'

detect -- pasta slirp MOD=lnet FORCE=pasta
check 'LNet, --net-backend pasta: pasta is used' contains "${OUT}" 'backend=pasta'
check '... with -I sbx0' contains "${OUT}" ' -I sbx0'

detect -- pasta slirp MOD=lnet FORCE=slirp4netns
check 'LNet, --net-backend slirp4netns: slirp4netns' contains "${OUT}" 'backend=slirp4netns'

detect -- pasta slirp MOD=lnet HOSTPORT=1
check 'LNet, --host-port (pasta only): pasta is used' contains "${OUT}" 'backend=pasta'

detect -- pasta slirp MOD=lnet SHARE=1
check 'LNet, --share-net: unchanged (no private network)' contains "${OUT}" 'backend=none'

# ── a Lustre client with a pasta that lacks --ns-ifname ──────────────────

detect STUB_PASTA_NS_IFNAME=0 -- pasta slirp MOD=lnet
check 'LNet, pasta without --ns-ifname: slirp4netns' contains "${OUT}" 'backend=slirp4netns'
check '... after pasta was asked for --help only' pasta_only_asked_for_help

detect STUB_PASTA_NS_IFNAME=0 -- pasta - MOD=lnet
check 'LNet, pasta without --ns-ifname, no slirp4netns: the launch stops (exit 3)' rc_is 3
check '... and says why' contains "${ERR}" 'This host has Lustre networking loaded'
check '... names the missing option' contains "${ERR}" '--ns-ifname'
check '... does not suggest sharing the host network' lacks "${ERR}" '--share-net'
check '... and pasta was only asked for --help' pasta_only_asked_for_help

detect STUB_PASTA_NS_IFNAME=0 -- pasta slirp MOD=lnet FORCE=pasta
check 'LNet, --net-backend pasta without --ns-ifname: the launch stops (exit 3)' rc_is 3
check '... and pasta was only asked for --help' pasta_only_asked_for_help

detect STUB_PASTA_NS_IFNAME=0 -- pasta slirp MOD=lnet HOSTPORT=1
check 'LNet, --host-port, pasta without --ns-ifname: the launch stops (exit 3)' rc_is 3

detect -- - - MOD=lnet
check 'LNet, no pasta and no slirp4netns: the launch stops (exit 3)' rc_is 3
check '... with the usual message, not the Lustre one' lacks "${ERR}" 'This host has Lustre networking loaded'

# ── the detection itself ─────────────────────────────────────────────────

check 'the library reads /sys/module by default' bash -c \
    'source "$1" && [[ "${_NET_SYSFS_MODULE_DIR}" == /sys/module ]]' _ "${LIB}"
check 'a module directory with lnet is a Lustre client' bash -c \
    'source "$1" && _NET_SYSFS_MODULE_DIR="$2" && _net_host_has_lnet' _ "${LIB}" "${T}/mod-lnet"
check 'a module directory without lnet is not a Lustre client' bash -c \
    'source "$1" && _NET_SYSFS_MODULE_DIR="$2" && ! _net_host_has_lnet' _ "${LIB}" "${T}/mod-none"
check 'the dry-run printer treats -I as an option with a value' grep -q -- '-t | -u | -T | -U | -I |' "${LIB}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
