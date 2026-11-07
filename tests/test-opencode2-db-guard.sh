#!/usr/bin/env bash
# Tests for lib/opencode2-db-lock.sh and bin/opencode2-db.
#
# Needs bash, flock, python3 (sqlite3 module).  Uses a temporary directory and
# a fake /proc, so it touches no real OpenCode data and needs no OpenCode.
# Run on any host:  tests/test-opencode2-db-guard.sh
#
# What it cannot show: locks across two hosts.  See docs/bw-wrappers.md
# ("Database guard", two-host check) for the manual test.

# shellcheck disable=SC2016  # the bash -c scripts are single quoted on purpose
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib/opencode2-db-lock.sh"
TOOL="${ROOT}/bin/opencode2-db"
T="$(mktemp -d "${TMPDIR:-/tmp}/oc2db-test.XXXXXX")"
PIDS=()
cleanup() {
    local _p
    for _p in "${PIDS[@]:-}"; do
        [[ -n "${_p}" ]] && kill "${_p}" 2> /dev/null
    done
    rm -rf "${T}"
}
trap cleanup EXIT
unset BWRAP_SANDBOX OPENCODE2_DB_GUARD

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
contains() { grep -q -- "$2" <<< "$1"; }

# ── fixtures ────────────────────────────────────────────────────────────

mkdir -p "${T}/inst/new" "${T}/inst/old"
printf '#!/bin/sh\necho "opencode v2.2.5"\n' > "${T}/inst/new/opencode.exe"
printf '#!/bin/sh\necho "opencode v2.2.4"\n' > "${T}/inst/old/opencode.exe"
chmod +x "${T}"/inst/*/opencode.exe
NEW="${T}/inst/new/opencode.exe"

# The real /proc holds the OpenCode running this very session; tests use an
# empty fake one unless they set OC2DB_PROC themselves.
mkdir -p "${T}/proc0/self/ns"
ln -sfn "pid:[4001]" "${T}/proc0/self/ns/pid"
export OC2DB_PROC="${T}/proc0"

# shellcheck source=../lib/opencode2-db-lock.sh
source "${LIB}"
HOST="$(oc2db_host)"

new_data() { # new_data NAME -> data dir with a database file
    mkdir -p "${T}/$1/opencode"
    : > "${T}/$1/opencode/opencode.db"
    printf '%s' "${T}/$1/opencode"
}
locks_of() { printf '%s' "$(oc2db_guard_dir "$1")/locks"; }

# run_guard DATA [ENV=VAL...]: run oc2db_guard in a fresh shell, print output
# and "rc=N".
run_guard() {
    local _data="$1"
    shift
    env OC2DB_TOOL=/nonexistent "$@" bash -c '
        set -euo pipefail; source "$1"; OC2DB_PROG=test
        oc2db_guard "$2" "$3" && echo rc=0 || echo "rc=$?"' _ "${LIB}" "${_data}" "${NEW}" 2>&1
}

# hold_lock LOCKFILE SECONDS: hold a shared lock from another process.
hold_lock() {
    mkdir -p "$(dirname -- "$1")"
    {
        exec 9<> "$1"
        flock -s 9
        exec sleep "$2"
    } &
    PIDS+=($!)
    sleep 0.3
}

lock_free() { flock -x -n "$1" true; }

# ── library ─────────────────────────────────────────────────────────────

D="$(new_data clean)"
OUT="$(run_guard "${D}")"
check "clean start is allowed" contains "${OUT}" 'rc=0'
check "clean start creates the session lock file" test -e "$(locks_of "${D}")/session@${HOST}@2.2.5.lock"

D="$(new_data twosessions)"
bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3"; exec sleep 6' _ "${LIB}" "${D}" "${NEW}" &
PIDS+=($!)
sleep 1
OUT="$(run_guard "${D}")"
check "second session of the same version on this host is allowed" contains "${OUT}" 'rc=0'
check "the running session holds its lock" bash -c '! flock -x -n "$1" true' _ "$(locks_of "${D}")/session@${HOST}@2.2.5.lock"

D="$(new_data otherhost)"
hold_lock "$(locks_of "${D}")/session@elsewhere.example@2.2.5.lock" 4
OUT="$(run_guard "${D}")"
check "a live session on another host is refused" contains "${OUT}" 'rc=1'
check "the refusal names the other host" contains "${OUT}" 'elsewhere.example'

D="$(new_data otherversion)"
hold_lock "$(locks_of "${D}")/session@${HOST}@2.2.4.lock" 4
OUT="$(run_guard "${D}")"
check "a live session of another version on this host is refused" contains "${OUT}" 'rc=1'
check "the refusal names the version" contains "${OUT}" '2.2.4'

# Same host and version, but the live holder recorded another build.
build_holder() { # build_holder LOCKFILE ID SECONDS
    mkdir -p "$(dirname -- "$1")"
    {
        exec 9<> "$1"
        printf '%s\n' "$2" >&9
        flock -s 9
        exec sleep "$3"
    } &
    PIDS+=($!)
    sleep 0.3
}
D="$(new_data samebuild)"
build_holder "$(locks_of "${D}")/session@${HOST}@2.2.5.lock" "1:999999999" 4
OUT="$(run_guard "${D}")"
check "a live session of the same version but another build is refused" contains "${OUT}" 'rc=1'
check "the refusal says the build differs" contains "${OUT}" 'different build'
D="$(new_data samebuild-ok)"
build_holder "$(locks_of "${D}")/session@${HOST}@2.2.5.lock" "$(oc2db_file_id "${NEW}")" 4
OUT="$(run_guard "${D}")"
check "a live session of the same build is allowed" contains "${OUT}" 'rc=0'
check "the session records its build id in the lock file" bash -c '[[ "$(head -n1 "$1")" == "$2" ]]' _ "$(locks_of "${D}")/session@${HOST}@2.2.5.lock" "$(oc2db_file_id "${NEW}")"

D="$(new_data stale)"
mkdir -p "$(locks_of "${D}")"
: > "$(locks_of "${D}")/session@gone.example@2.2.5.lock"
OUT="$(run_guard "${D}")"
check "a stale lock file of another host is ignored" contains "${OUT}" 'rc=0'
check "the stale lock file is removed" test ! -e "$(locks_of "${D}")/session@gone.example@2.2.5.lock"

D="$(new_data flag)"
mkdir -p "$(oc2db_guard_dir "${D}")"
printf 'Database check failed at test\nmalformed\n' > "$(oc2db_guard_dir "${D}")/CHECK-FAILED"
OUT="$(run_guard "${D}")"
check "the damage flag stops the launch" contains "${OUT}" 'rc=1'
check "the refusal shows the recorded problem" contains "${OUT}" 'malformed'

D="$(new_data off)"
OUT="$(run_guard "${D}" OPENCODE2_DB_GUARD=off)"
check "OPENCODE2_DB_GUARD=off skips the checks" contains "${OUT}" 'rc=0'
check "OPENCODE2_DB_GUARD=off takes no lock" test ! -e "$(locks_of "${D}")"

# Fake /proc: PID dirs with an exe link, environ, cwd and a PID namespace link.
fake_proc() { # fake_proc PID EXE NS [marker]
    local _d="${T}/proc/$1"
    mkdir -p "${_d}/ns" "${T}/proc/self/ns"
    ln -sfn "$2" "${_d}/exe"
    ln -sfn "pid:[$3]" "${_d}/ns/pid"
    ln -sfn "pid:[4001]" "${T}/proc/self/ns/pid"
    ln -sfn /tmp "${_d}/cwd"
    if [[ -n "${4:-}" ]]; then
        printf 'A=1\0OC2DB_GUARDED=1\0' > "${_d}/environ"
    else
        printf 'A=1\0' > "${_d}/environ"
    fi
}

D="$(new_data oldbuild)"
rm -rf "${T}/proc"
fake_proc 90001 "${T}/inst/old/opencode.exe" 4001 marker
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "a different build running on this host is refused" contains "${OUT}" 'rc=1'
check "the refusal lists the process" contains "${OUT}" '90001'

rm -rf "${T}/proc"
fake_proc 90002 "${T}/inst/new/opencode.exe" 4001
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "an unsandboxed process without the guard marker is refused" contains "${OUT}" 'rc=1'

rm -rf "${T}/proc"
fake_proc 90003 "${T}/inst/new/opencode.exe" 4001 marker
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "an unsandboxed process with the marker and the same build is allowed" contains "${OUT}" 'rc=0'

rm -rf "${T}/proc"
fake_proc 90004 "${T}/inst/new/opencode.exe" 4002
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "a sandboxed (other PID namespace) process of the same build is allowed" contains "${OUT}" 'rc=0'

rm -rf "${T}/proc"
fake_proc 90005 "${T}/inst/old/opencode.exe (deleted)" 4002
ln -sfn "${T}/inst/old/opencode.exe" "${T}/proc/90005/exe"
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "an old build in another PID namespace is refused" contains "${OUT}" 'rc=1'

# The lock must survive exec, and the backup job must not hold it.
D="$(new_data persist)"
printf '#!/bin/sh\necho "$@" >"%s/tool-args"\necho $$ >"%s/tool-pid"\nexec sleep 8\n' "${T}" "${T}" > "${T}/fake-tool"
chmod +x "${T}/fake-tool"
OC2DB_TOOL="${T}/fake-tool" bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3"; exec sleep 3' _ "${LIB}" "${D}" "${NEW}" &
PIDS+=($!)
sleep 1
LOCKFILE="$(locks_of "${D}")/session@${HOST}@2.2.5.lock"
check "the lock is held across exec" bash -c '! flock -x -n "$1" true' _ "${LOCKFILE}"
check "the backup job gets --data-dir before the subcommand" grep -q -- "^--data-dir ${D} backup --if-due" "${T}/tool-args"
sleep 3
check "the lock is released when the session ends, though the backup job still runs" lock_free "${LOCKFILE}"
[[ -s "${T}/tool-pid" ]] && kill "$(cat "${T}/tool-pid")" 2> /dev/null

# ── bin/opencode2-db ────────────────────────────────────────────────────

mkdir -p "${T}/py/share/opencode"
DB="${T}/py/share/opencode/opencode.db"
python3 - "${DB}" << 'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("pragma journal_mode=wal")
c.executescript("""
create table project(id text primary key, worktree text not null, vcs text, time_created int,
  time_updated int, time_active int, sandboxes text);
create table worktree(id integer primary key, project_id text, directory text, time_created int);
create table session_v2(id text primary key, project_id text, directory text, time_created int, time_updated int);
create table session_message(id integer primary key, session_id text, body text);
create table kv(key text primary key, value text);
""")
c.execute("insert into project values('p1','/a','git',1,2,0,'[]')")
c.execute("insert into session_v2 values('s1','p1','/a',1,5)")
for i in range(300):
    c.execute("insert into session_message(session_id, body) values('s1', ?)", ("x" * 500,))
c.commit()
c.close()
EOF
mkdir -p "${T}/job/opencode"
cp "${DB}" "${T}/job/opencode/opencode.db"
env -u OC2DB_TOOL OC2DB_BACKUP_DELAY=0 bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3"' _ "${LIB}" "${T}/job/opencode" "${NEW}"
for _ in $(seq 1 40); do
    compgen -G "${T}/job/opencode-db-guard/backups/opencode-*.db.gz" > /dev/null && break
    sleep 0.5
done
check "the guard starts the real backup tool, which writes a backup" compgen -G "${T}/job/opencode-db-guard/backups/opencode-*.db.gz" > /dev/null
PD="${T}/py/share/opencode"
GD="${T}/py/share/opencode-db-guard"

"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
check "backup writes a compressed copy" bash -c 'ls "$1"/backups/opencode-*.db.gz >/dev/null 2>&1' _ "${GD}"
check "backup --if-due does nothing within 24 hours" bash -c '[[ -z "$("$1" --data-dir "$2" backup --if-due)" ]]' _ "${TOOL}" "${PD}"
sleep 1.1
"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
sleep 1.1
"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
check "backup keeps only the newest N" bash -c '[[ "$(ls "$1"/backups/opencode-*.db.gz | wc -l)" -eq 2 ]]' _ "${GD}"

python3 - "${DB}" << 'EOF'
import os, sys
for ext in ("-wal", "-shm"):
    try:
        os.unlink(sys.argv[1] + ext)
    except FileNotFoundError:
        pass
f = open(sys.argv[1], "r+b")
f.seek(4096 * 20)
f.write(os.urandom(4096))
f.close()
EOF
"${TOOL}" --data-dir "${PD}" backup > /dev/null
check "a damaged database sets the damage flag" test -e "${GD}/CHECK-FAILED"
OUT="$(env OC2DB_TOOL=/nonexistent bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3" && echo rc=0 || echo "rc=$?"' _ "${LIB}" "${PD}" "${NEW}" 2>&1)"
check "the guard then refuses to start" contains "${OUT}" 'rc=1'

"${TOOL}" --data-dir "${PD}" restore --yes > /dev/null
check "restore clears the flag" test ! -e "${GD}/CHECK-FAILED"
check "restore keeps the damaged file" bash -c 'ls "$1"/opencode.db.corrupt-* >/dev/null 2>&1' _ "${PD}"
check "the restored database passes quick_check" python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute('pragma quick_check').fetchone()[0] == 'ok'
assert c.execute('select count(*) from session_message').fetchone()[0] == 300" "${DB}"

hold_lock "${GD}/locks/session@${HOST}@2.2.5.lock" 3
OUT="$("${TOOL}" --data-dir "${PD}" restore --yes 2>&1)"
check "restore refuses while a session lock is held" contains "${OUT}" 'sessions are running'
sleep 3

"${TOOL}" --data-dir "${PD}" rebuild --apply --yes > /dev/null
check "rebuild --apply gives a database that passes integrity_check" python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute('pragma integrity_check').fetchone()[0] == 'ok'
assert c.execute('select count(*) from session_message').fetchone()[0] == 300" "${DB}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
