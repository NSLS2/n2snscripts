#!/usr/bin/env bash
# Tests for bin/bwopenchamber (argument handling, the environment and mounts it
# builds), through --dry-run.
#
# Needs bash and bwrap.  Uses a temporary HOME, a stub node, a stub OpenCode 2
# binary and a stub OpenChamber install, so it touches no real data and needs
# none of them installed.  --share-net keeps it independent of pasta and
# slirp4netns.  tests/bwopenchamber-harness accepts the development machine's
# bwrap; the library's owner check is not weakened for real runs.
# Run on any host:  tests/test-bwopenchamber.sh
#
# What it cannot show: a real launch (the sandbox, the private network, the
# server answering), which needs a host where bwrap is root-owned.  See
# docs/bw-wrappers.md ("bwopenchamber", manual check).

# shellcheck disable=SC2016  # patterns are single quoted on purpose
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${ROOT}/tests/bwopenchamber-harness"
T="$(mktemp -d "${TMPDIR:-/tmp}/bwopenchamber-test.XXXXXX")"
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
matches() { [[ "$1" =~ $2 ]]; }
# Number of lines of --dry-run output that set environment variable $2 (a value is
# printed REDACTED when the name holds PASSWORD or SECRET, so count the names).
env_lines() { grep -c "^  $2=" <<< "$1"; }

# ── fixtures ────────────────────────────────────────────────────────────

mkdir -p "${T}/home/.config/opencode2/opencode" "${T}/work" "${T}/oc2"
echo '{}' > "${T}/home/.config/opencode2/opencode/opencode.json"
mkdir -p "${T}/app/node_modules/@openchamber/web/bin"
echo '// stub' > "${T}/app/node_modules/@openchamber/web/bin/cli.js"
printf '#!/bin/sh\necho "opencode v2.2.7"\n' > "${T}/oc2/opencode.exe"
chmod +x "${T}/oc2/opencode.exe"
make_node() { # make_node DIR VERSION
    mkdir -p "$1"
    printf '#!/bin/sh\necho "v%s"\n' "$2" > "$1/node"
    chmod +x "$1/node"
}
make_node "${T}/node/24.14.0" 24.14.0
make_node "${T}/node/24.13.9" 24.13.9
make_node "${T}/node/22.23.2" 22.23.2
make_node "${T}/node/25.1.0" 25.1.0
NODE="${T}/node/24.14.0"
make_node_as() { # make_node_as DIR NAME VERSION: a stub Node under another name, as nodejs24 installs node-24
    mkdir -p "$1"
    printf '#!/bin/sh\necho "v%s"\n' "$3" > "$1/$2"
    chmod +x "$1/$2"
}
mkdir -p "${T}/no-nodes"
make_node_as "${T}/nodebin24" node-24 24.14.0
make_node_as "${T}/nodebin" node-24 24.14.0
make_node_as "${T}/nodebin" node-25 25.1.0
make_node_as "${T}/nodebin" nodejs22 22.23.2
mkdir -p "${T}/nodebin"
printf '#!/bin/sh\necho hello\n' > "${T}/nodebin/node-99"
printf '#!/bin/sh\necho "v26.0.0"\n' > "${T}/nodebin/node-26"
chmod +x "${T}/nodebin/node-99"
chmod -x "${T}/nodebin/node-26"
make_node_as "${T}/nodebin22" nodejs22 22.23.2
printf '#!/bin/sh\necho hello\n' > "${T}/nodebin22/node-99"
chmod +x "${T}/nodebin22/node-99"

# run [env VAR=VALUE ...] -- ARGS...: dry-run the launcher; sets OUT, ERR, RC.
# Host variables of the kinds the launcher must not pass on are cleared first.
run() {
    local -a _env=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
        _env+=("$1")
        shift
    done
    shift
    OUT="$(cd "${T}/work" && env -u OPENCODE_HOST -u OPENCODE_PORT -u OPENCODE_SKIP_START \
        -u OPENCODE_SERVER_PASSWORD -u OPENCODE_PASSWORD -u OPENCHAMBER_HOST \
        -u OPENCHAMBER_UI_PASSWORD -u OPENCHAMBER_RELAY_URL -u OPENCODE2_DB_GUARD \
        -u BWOPENCODE2_SERVE_PASSWORD -u BWOPENCODE2_SERVE_PORTS \
        -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u BWOPENCHAMBER_NODE \
        HOME="${T}/home" PATH="${NODE}:${PATH}" BWOPENCHAMBER_DIR="${T}/app" \
        BWOPENCHAMBER_NODE_DIRS="${T}/no-nodes" \
        HARNESS_OC2_BIN="${T}/oc2/opencode.exe" ${_env[@]+"${_env[@]}"} \
        "${HARNESS}" --dry-run --share-net "$@" 2> "${T}/err")"
    RC=$?
    ERR="$(cat "${T}/err")"
}

# ── the normal launch ────────────────────────────────────────────────────

run --
check 'a plain launch succeeds' rc_is 0
check 'runs the server in the foreground' contains "${OUT}" 'cli.js serve --foreground --host '
check 'takes the first port of the shared pool' contains "${OUT}" '--port 24700'
check 'runs the node that was found on PATH' contains "${OUT}" "-- ${NODE}/node "
check 'runs the stub install, not a host path' contains "${OUT}" "${T}/app/node_modules/@openchamber/web/bin/cli.js"
check 'mounts the install read-only' contains "${OUT}" "--ro-bind ${T}/app ${T}/app"
check 'enterprise mode is on' contains "${OUT}" 'OPENCHAMBER_ENTERPRISE_MODE=1'
check 'network access is not granted through the environment (the policy file does it)' [ "$(env_lines "${OUT}" OPENCHAMBER_ALLOW_NETWORK_ACCESS)" -eq 0 ]
check 'the push relay is off' contains "${OUT}" 'OPENCHAMBER_PUSH_RELAY_DISABLED=true'
check 'OpenCode is the installed binary' contains "${OUT}" "OPENCODE_BINARY=${T}/oc2/opencode.exe"
check 'the UI password is set and hidden' contains "${OUT}" "OPENCHAMBER_UI_PASSWORD='REDACTED'"
check 'a sign-in signing key is set and hidden' contains "${OUT}" "OPENCODE_JWT_SECRET='REDACTED'"
check 'the agent is told not to use the credentials it inherits' contains "${OUT}" 'never read, print or use them'
check 'a tmpfs covers the run directory (UI password file)' contains "${OUT}" "${T}/home/.local/share/openchamber/run"
check 'the data directory is the launcher own, not an OpenChamber outside a sandbox' \
    contains "${OUT}" "--bind ${T}/home/.local/share/bwopenchamber ${T}/home/.local/share/openchamber"
check 'the policy file is mounted read-only from a descriptor' contains "${OUT}" '--ro-bind-data'
check '... at the path OpenChamber reads' contains "${OUT}" '/etc/openchamber/policy.json'
check 'no host policy file is bound' lacks "${OUT}" '--ro-bind /etc/openchamber'
# The generated file is printed after the command as '# ' lines (--dry-run).
policy_text="$(sed -n '/filled by the relay with the OpenChamber policy file/,/^$/p' <<< "${OUT}" | sed -n 's/^# //p' | grep -E '^ *[{}"]')"
check 'the policy file is valid JSON' python3 -c 'import json,sys; json.loads(sys.argv[1])' "${policy_text}"
check 'the policy turns enterprise mode on' contains "${policy_text}" '"enterpriseMode": true'
check 'the policy allows the private network address (a file, so it governs)' contains "${policy_text}" '"allowNetworkAccess": true'
check 'the policy pins the installed OpenCode, which a saved setting then cannot override' contains "${policy_text}" "\"opencodeBinary\": \"${T}/oc2/opencode.exe\""
check 'the policy allows no extension' contains "${policy_text}" '"allowedExtensions": []'
check 'the policy hides the built-in skills catalogues' contains "${policy_text}" '"hideBuiltinSkillCatalogs": true'
check 'the policy holds no secret' lacks "${policy_text}" 'PASSWORD'
check 'the printed info names the ssh tunnel' contains "${ERR}" 'ssh -L 24700:127.'
check 'the sandbox is named' contains "${OUT}" 'BWRAP_SANDBOX=bwopenchamber'
check 'the agent is told what it runs under' contains "${OUT}" 'This session runs under OpenChamber'

# ── the port pool does not depend on running sessions ────────────────────

# Hold the first port on this user's publish address, as a real bwopenchamber or
# bwopencode2 --serve session would, then dry-run again: the stubbed probe means
# the answer does not change (without it the dry run would pick the next port).
run -- --ssh-config
busy_addr="$(sed -n 's/.*LocalForward 24700 \(127\.[0-9.]*\):24700.*/\1/p' <<< "${OUT}")"
python3 -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 24700))
s.listen()
time.sleep(40)' "${busy_addr}" &
busy_pid=$!
sleep 1
check 'the test holds the first port on the publish address' matches "${busy_addr}" '^127\.[0-9]+\.[0-9]+\.1$'
run --
check 'a port held by another session does not change the port the tests expect' contains "${OUT}" '--port 24700'
kill "${busy_pid}" 2> /dev/null
wait "${busy_pid}" 2> /dev/null

# ── arguments ────────────────────────────────────────────────────────────

for _args in '--host 0.0.0.0' '--lan' 'tunnel start' 'startup enable' 'connect-url --relay' '--ui-password x'; do
    # shellcheck disable=SC2086  # word splitting of the argument list is the point
    run -- ${_args}
    check "refuses the OpenChamber argument '${_args}'" rc_is 1
    check "  ... and says why ('${_args}')" contains "${ERR}" 'takes no OpenChamber arguments'
done

run -- --port 24705
check '--port inside the range is used' contains "${OUT}" '--port 24705'
run -- --port 3000
check '--port outside the range is refused' rc_is 1
run -- --port abc
check '--port that is not a number is refused' rc_is 1
run -- --port
check '--port without a value is refused' rc_is 1

run BWOPENCODE2_SERVE_PORTS=24800-24802 --
check 'the port range can be changed' contains "${OUT}" '--port 24800'
run BWOPENCODE2_SERVE_PORTS=49370-49380 --
check 'a range that holds the shared OpenCode service port is refused' rc_is 1

# ── what the host cannot inject ──────────────────────────────────────────

run OPENCODE_HOST=http://127.0.0.1:49374 OPENCODE_PORT=49374 OPENCODE_SKIP_START=true \
    OPENCODE_SERVER_PASSWORD=hostsecret1 OPENCODE_PASSWORD=hostsecret2 OPENCODE_JWT_SECRET=hostsecret4 \
    OPENCHAMBER_HOST=0.0.0.0 OPENCHAMBER_UI_PASSWORD=hostsecret3 OPENCHAMBER_RELAY_URL=wss://x.example/ws --
check 'launch with hostile host variables succeeds' rc_is 0
check 'OPENCODE_HOST is not passed' lacks "${OUT}" 'OPENCODE_HOST='
check 'OPENCODE_PORT is not passed' lacks "${OUT}" 'OPENCODE_PORT='
check 'OPENCODE_SKIP_START is not passed' lacks "${OUT}" 'OPENCODE_SKIP_START'
# --dry-run prints a variable whose name holds PASSWORD or SECRET as REDACTED, so
# the values cannot show: check the names, and that ours is the only one of each.
check 'no host OPENCODE_SERVER_PASSWORD is passed' lacks "${OUT}" 'OPENCODE_SERVER_PASSWORD='
check 'no host OPENCODE_PASSWORD is passed' lacks "${OUT}" 'OPENCODE_PASSWORD='
check 'the UI password is ours alone, not the host one' [ "$(env_lines "${OUT}" OPENCHAMBER_UI_PASSWORD)" -eq 1 ]
check 'the signing key is ours alone, not the host one' [ "$(env_lines "${OUT}" OPENCODE_JWT_SECRET)" -eq 1 ]
check 'no host secret value is printed' lacks "${OUT}${ERR}" 'hostsecret'
check 'OPENCHAMBER_HOST is not passed' lacks "${OUT}" 'OPENCHAMBER_HOST='
check 'no relay URL is passed' lacks "${OUT}" 'OPENCHAMBER_RELAY_URL'
check 'the dropped OPENCODE_* names are reported, not their values' contains "${ERR}" 'OPENCODE_HOST'

# ── password ─────────────────────────────────────────────────────────────

run BWOPENCODE2_SERVE_PASSWORD=short --
check 'a fixed password under 12 characters is refused' rc_is 1
run BWOPENCODE2_SERVE_PASSWORD=a-fixed-password-123 --
check 'a fixed password is accepted' rc_is 0
check '... and passed to the server as the UI password' contains "${OUT}" "OPENCHAMBER_UI_PASSWORD='REDACTED'"
check '... and never printed' lacks "${OUT}${ERR}" 'a-fixed-password-123'

# ── the sign-in signing key ──────────────────────────────────────────────

# och_make_jwt_secret in a subshell, so the launcher's options do not reach this script.
jwt_pair="$(
    # shellcheck source=../bin/bwopenchamber
    source "${ROOT}/bin/bwopenchamber"
    och_make_jwt_secret
    a="${OCH_JWT_SECRET}"
    och_make_jwt_secret
    printf '%s %s' "${a}" "${OCH_JWT_SECRET}"
)"
jwt_a="${jwt_pair% *}"
jwt_b="${jwt_pair#* }"
check 'the signing key is 64 hex characters' matches "${jwt_a}" '^[0-9a-f]{64}$'
check 'a new key is made each time' [ "${jwt_a}" != "${jwt_b}" ]

# ── --exec ───────────────────────────────────────────────────────────────

run -- --exec 'bash -c true'
check '--exec runs the command, not the server' contains "${OUT}" '-- bash -c true'
check '--exec sets up no UI password' [ "$(env_lines "${OUT}" OPENCHAMBER_UI_PASSWORD)" -eq 0 ]
check '--exec sets up no signing key' [ "$(env_lines "${OUT}" OPENCODE_JWT_SECRET)" -eq 0 ]
check '--exec starts no server' lacks "${OUT}" 'serve --foreground'
run -- --exec 'bash -c true' --port 24701
check '--exec with --port is refused' rc_is 1

# ── Node and installs ────────────────────────────────────────────────────

NODE="${T}/node/24.13.9" run --
check 'Node 24.13 is refused' rc_is 1
check '... and the version is named' contains "${ERR}" '24.13.9'
NODE="${T}/node/22.23.2" run --
check 'Node 22 is refused' rc_is 1
NODE="${T}/node/25.1.0" run --
check 'Node 25 is accepted' rc_is 0
NODE="${T}/node/24.14.0"

# ── which Node is used ───────────────────────────────────────────────────

# A side-by-side node-24 is found when PATH's node is too old (RHEL 10: nodejs 22 is
# the default, nodejs24 installs node-24).
NODE="${T}/node/22.23.2" run BWOPENCHAMBER_NODE_DIRS="${T}/nodebin24" --
check 'node 22 on PATH and a node-24 beside it: launches' rc_is 0
check '... with the node-24' contains "${OUT}" "-- ${T}/nodebin24/node-24 "
NODE="${T}/node/22.23.2" run BWOPENCHAMBER_NODE_DIRS="${T}/nodebin" --
check 'several versioned nodes: the newest that is new enough is used' contains "${OUT}" "-- ${T}/nodebin/node-25 "
check '... not one that is not executable' lacks "${OUT}" "${T}/nodebin/node-26"
NODE="${T}/node/24.14.0" run BWOPENCHAMBER_NODE_DIRS="${T}/nodebin" --
check 'a new enough node on PATH wins over versioned ones' contains "${OUT}" "-- ${T}/node/24.14.0/node "
NODE="${T}/node/22.23.2" run BWOPENCHAMBER_NODE="${T}/node/25.1.0/node" --
check 'BWOPENCHAMBER_NODE is used' contains "${OUT}" "-- ${T}/node/25.1.0/node "
NODE="${T}/node/24.14.0" run BWOPENCHAMBER_NODE="${T}/node/22.23.2/node" --
check 'BWOPENCHAMBER_NODE that is too old is an error, even with a good node on PATH' rc_is 1
check '... naming it and its version' contains "${ERR}" "${T}/node/22.23.2/node  22.23.2"
NODE="${T}/node/22.23.2" run BWOPENCHAMBER_NODE_DIRS="${T}/nodebin22" --
check 'no node that is new enough: refused' rc_is 1
check '... listing what was found with versions' contains "${ERR}" "${T}/node/22.23.2/node  22.23.2"
check '... and a binary that is not node' contains "${ERR}" "${T}/nodebin22/node-99  (no version)"
check '... and what to do on RHEL 10' contains "${ERR}" 'install nodejs24'
check '... and the override' contains "${ERR}" 'BWOPENCHAMBER_NODE=/path/to/node'
NODE="${T}/node/24.14.0" run -- --exec 'bash -c true'
check '--exec also finds a node' rc_is 0
NODE="${T}/node/24.14.0"

run BWOPENCHAMBER_DIR="${T}/missing" --
check 'a missing install is refused' rc_is 1
check '... with a message' contains "${ERR}" 'OpenChamber is not installed'

# ── --ssh-config and --help ──────────────────────────────────────────────

run -- --ssh-config
check '--ssh-config prints the forwards' contains "${OUT}" 'LocalForward 24700 127.'
check '--ssh-config prints every port of the pool' contains "${OUT}" 'LocalForward 24709 127.'
run -- --help
check '--help succeeds' rc_is 0
check '--help says no argument is passed through' contains "${OUT}" 'No OpenChamber argument is passed through'

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
