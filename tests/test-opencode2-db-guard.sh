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

# hold_backup_window GUARDDIR SECONDS: another process holds the backup lock the
# way `opencode2-db backup` does while it reads the database.  Waits until held.
hold_backup_window() {
    rm -f "${T}/window-held"
    python3 - "${TOOL}" "$1" "$2" "${T}/window-held" << 'EOF' &
import importlib.machinery
import importlib.util
import sys
import time
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("oc2db", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("oc2db", loader))
loader.exec_module(mod)
with mod.backup_window(Path(sys.argv[2])) as reason:
    Path(sys.argv[4]).write_text("held" if reason is None else reason)
    time.sleep(float(sys.argv[3]))
EOF
    PIDS+=($!)
    for _ in $(seq 1 40); do
        [[ -e "${T}/window-held" ]] && break
        sleep 0.1
    done
}

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
check "a session refusal tells the user to close that session" contains "${OUT}" 'Close that session'

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

# A version that cannot be read gets a lock of its own, so two such sessions
# (which may be different builds) never share one.
mkdir -p "${T}/inst/noversion"
printf '#!/bin/sh\nexit 1\n' > "${T}/inst/noversion/opencode.exe"
chmod +x "${T}/inst/noversion/opencode.exe"
NOVER="${T}/inst/noversion/opencode.exe"
run_guard_bin() { # run_guard_bin DATA BIN: like run_guard, with another binary path
    env OC2DB_TOOL=/nonexistent bash -c '
        set -euo pipefail; source "$1"; OC2DB_PROG=test
        oc2db_guard "$2" "$3" && echo rc=0 || echo "rc=$?"' _ "${LIB}" "$1" "$2" 2>&1
}
D="$(new_data unknownver)"
OUT="$(run_guard_bin "${D}" "${NOVER}")"
check "a launch whose version cannot be read is allowed on a clean start" contains "${OUT}" 'rc=0'
check "it takes a lock file of its own, not a shared one" bash -c 'ls "$1"/session@"$2"@unknown-*.lock > /dev/null 2>&1 && [[ ! -e "$1/session@$2@unknown.lock" ]]' _ "$(locks_of "${D}")" "${HOST}"
OUT="$(run_guard_bin "${D}" "${NOVER}")"
check "a later launch removes the lock file of an ended session of unknown version" test "$(find "$(locks_of "${D}")" -name 'session@*unknown-*.lock' | wc -l)" -eq 1

D="$(new_data unknownver-two)"
bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3"; exec sleep 6' _ "${LIB}" "${D}" "${NOVER}" &
PIDS+=($!)
sleep 1
OUT="$(run_guard_bin "${D}" "${NOVER}")"
check "a second launch of unknown version is refused while one is running" contains "${OUT}" 'rc=1'
check "the refusal says the version could not be read" contains "${OUT}" 'could not be read'
OUT="$(run_guard "${D}")"
check "a launch of a known version is refused while one of unknown version is running" contains "${OUT}" 'rc=1'
OUT="$(run_guard_bin "${D}" "")"
check "an empty binary path counts as an unknown version too" contains "${OUT}" 'rc=1'

D="$(new_data knownthenunknown)"
bash -c 'set -euo pipefail; source "$1"; oc2db_guard "$2" "$3"; exec sleep 6' _ "${LIB}" "${D}" "${NEW}" &
PIDS+=($!)
sleep 1
OUT="$(run_guard_bin "${D}" "${NOVER}")"
check "a launch of unknown version is refused while one of a known version is running" contains "${OUT}" 'rc=1'

# A backup job holds locks/backup@HOST.lock while it reads the database.  A
# launch on ANOTHER host must refuse; on the same host it is harmless.  The
# other host is faked with a hostname shim.
mkdir -p "${T}/shim"
printf '#!/bin/sh\necho other.example\n' > "${T}/shim/hostname"
chmod +x "${T}/shim/hostname"
D="$(new_data backuplock)"
hold_backup_window "$(oc2db_guard_dir "${D}")" 5
check "the backup lock is held by the tool" test "$(cat "${T}/window-held")" = held
OUT="$(run_guard "${D}" PATH="${T}/shim:${PATH}")"
check "a launch on another host is refused while a backup holds its lock" contains "${OUT}" 'rc=1'
check "the refusal says a backup is running" contains "${OUT}" 'backup is running'
check "a backup refusal says to try again shortly" contains "${OUT}" 'Try again shortly'
check "a backup refusal does not tell the user to close a session" bash -c '! grep -q "Close that session" <<< "$1"' _ "${OUT}"
OUT="$(run_guard "${D}")"
check "a launch on the same host is allowed while a backup holds its lock" contains "${OUT}" 'rc=0'

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

# The marker is the first variable and the environment is far larger than a pipe
# buffer: `grep -q` must not stop reading early and make `tr` die of SIGPIPE,
# which under pipefail would report a guarded process as unlocked.
rm -rf "${T}/proc"
fake_proc 90006 "${T}/inst/new/opencode.exe" 4001 marker
python3 -c "
import sys
with open(sys.argv[1], 'ab') as f:
    f.write((b'X=' + b'y' * 100 + b'\\0') * 20000)" "${T}/proc/90006/environ"
OUT="$(run_guard "${D}" OC2DB_PROC="${T}/proc")"
check "a marked process with a very large environment is allowed (no SIGPIPE)" contains "${OUT}" 'rc=0'

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

# oc2db_needs_guard: which command lines open the database.
needs() { bash -c 'source "$1"; shift; oc2db_needs_guard "$@" && echo yes || echo no' _ "${LIB}" "$@"; }
check "no arguments need the guard" test "$(needs)" = yes
check "auth login needs the guard" test "$(needs auth login)" = yes
check "--version does not" test "$(needs --version)" = no
check "--help does not" test "$(needs --help)" = no
check "a help flag after a subcommand does not" test "$(needs debug --help)" = no
check "upgrade does not" test "$(needs upgrade)" = no
check "an option with a value before the subcommand does not hide it" test "$(needs --log-level debug upgrade)" = no
check "--prompt upgrade (a value, not a subcommand) needs the guard" test "$(needs --prompt upgrade)" = yes
check "-s upgrade needs the guard" test "$(needs -s upgrade)" = yes
check "upgrade as a later word needs the guard" test "$(needs run upgrade)" = yes
check "words after -- are never inspected" test "$(needs run -- --help)" = yes

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
# A backup of this host does not run while another host has a live session; it
# is not an error for the background job (--if-due), the next launch retries.
D="$(new_data skipbackup)"
hold_lock "$(locks_of "${D}")/session@elsewhere.example@2.2.5.lock" 5
OUT="$("${TOOL}" --data-dir "${D}" backup 2>&1)"
RC=$?
check "backup is skipped while another host has a live session" contains "${OUT}" 'another host'
check "a skipped manual backup exits non-zero" test "${RC}" -ne 0
check "a skipped backup writes nothing" bash -c '! compgen -G "$1/opencode-*.db.gz" > /dev/null' _ "$(oc2db_guard_dir "${D}")/backups"
"${TOOL}" --data-dir "${D}" backup --if-due > /dev/null 2>&1
check "a skipped --if-due backup exits 0" test "$?" -eq 0
sleep 4

# restore, rebuild and clear refuse while a backup holds its lock.
D="$(new_data backupblocks)"
hold_backup_window "$(oc2db_guard_dir "${D}")" 4
OUT="$("${TOOL}" --data-dir "${D}" clear 2>&1)"
check "clear refuses while a backup job holds its lock" contains "${OUT}" 'backup job'
sleep 4

# Two backups in the same second must not overwrite each other.
mkdir -p "${T}/dup/opencode"
cp "${DB}" "${T}/dup/opencode/opencode.db"
"${TOOL}" --data-dir "${T}/dup/opencode" backup --keep 5 > /dev/null
"${TOOL}" --data-dir "${T}/dup/opencode" backup --keep 5 > /dev/null
check "two backups in quick succession keep both files" bash -c '[[ "$(ls "$1"/backups/opencode-*.db.gz | wc -l)" -eq 2 ]]' _ "${T}/dup/opencode-db-guard"

# A rebuild never deletes an earlier rebuilt file, even in the same second.
"${TOOL}" --data-dir "${T}/dup/opencode" rebuild > /dev/null 2>&1
"${TOOL}" --data-dir "${T}/dup/opencode" rebuild > /dev/null 2>&1
check "two rebuilds keep both rebuilt files" bash -c '[[ "$(ls "$1"/opencode.db.rebuilt-* | wc -l)" -eq 2 ]]' _ "${T}/dup/opencode"

# Several recoveries in the same second must each keep the file they replace:
# the kept names never collide, and a kept file is never overwritten.
mkdir -p "${T}/swap/opencode"
if python3 - "${T}/swap/opencode" "${TOOL}" << 'EOF'; then
import importlib.machinery
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

data = Path(sys.argv[1])
gdir = data.parent / "opencode-db-guard"
gdir.mkdir()
loader = importlib.machinery.SourceFileLoader("oc2db", sys.argv[2])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("oc2db", loader))
loader.exec_module(mod)
mod.now_utc = lambda: datetime(2026, 11, 7, 12, 0, 0, tzinfo=timezone.utc)

for i in range(4):
    (data / "opencode.db").write_text("db%d" % i)
    (data / "opencode.db-wal").write_text("wal%d" % i)
    new = data / ("new%d" % i)
    new.write_text("new%d" % i)
    mod.swap_in(data, new, gdir)

kept = sorted(p.read_text() for p in data.glob("opencode.db.corrupt-*"))
want = sorted(["db%d" % i for i in range(4)] + ["wal%d" % i for i in range(4)])
assert kept == want, (kept, want)
assert (data / "opencode.db").read_text() == "new3"
EOF
    check "four recoveries in one second each keep the file they replace" true
else
    check "four recoveries in one second each keep the file they replace" false
fi

# A refusal because of a backup job says to try again shortly, not to close a session.
PD="${T}/py/share/opencode"
GD="${T}/py/share/opencode-db-guard"

"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
check "backup writes a compressed copy" bash -c 'ls "$1"/backups/opencode-*.db.gz >/dev/null 2>&1' _ "${GD}"
check "backup --if-due does nothing within 24 hours" bash -c '[[ -z "$("$1" --data-dir "$2" backup --if-due)" ]]' _ "${TOOL}" "${PD}"
sleep 1.1
"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
sleep 1.1
"${TOOL}" --data-dir "${PD}" backup --keep 2 > /dev/null
check "backups are private (mode 600, directory 700)" bash -c '[[ "$(stat -c %a "$1"/backups/opencode-*.db.gz | sort -u)" == 600 && "$(stat -c %a "$1"/backups)" == 700 ]]' _ "${GD}"
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
check "the restored database is private (mode 600)" bash -c '[[ "$(stat -c %a "$1")" == 600 ]]' _ "${DB}"
check "the restored database passes quick_check" python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute('pragma quick_check').fetchone()[0] == 'ok'
assert c.execute('select count(*) from session_message').fetchone()[0] == 300" "${DB}"

hold_lock "${GD}/locks/session@${HOST}@2.2.5.lock" 3
OUT="$("${TOOL}" --data-dir "${PD}" restore --yes 2>&1)"
check "restore refuses while a session lock is held" contains "${OUT}" 'using the database'
sleep 3

"${TOOL}" --data-dir "${PD}" rebuild --apply --yes > /dev/null
check "rebuild --apply gives a database that passes integrity_check" python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute('pragma integrity_check').fetchone()[0] == 'ok'
assert c.execute('select count(*) from session_message').fetchone()[0] == 300" "${DB}"

check "the rebuilt database is private (mode 600)" bash -c '[[ "$(stat -c %a "$1")" == 600 ]]' _ "${DB}"

# A damaged project table is rebuilt from sessions, which loses data: --apply
# then needs --accept-loss.
mkdir -p "${T}/lossy/share/opencode"
python3 - "${T}/lossy/share/opencode/opencode.db" << 'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
create table project(id text, worktree text, vcs text, time_created int, time_updated int, time_active int, sandboxes text);
create table worktree(id integer primary key, project_id text, directory text, time_created int);
create table session_v2(id text primary key, project_id text, directory text, time_created int, time_updated int);
""")
c.execute("insert into project values(NULL, NULL, NULL, NULL, NULL, NULL, NULL)")
c.execute("insert into worktree(project_id, directory, time_created) values('p1', '/a', 1)")
c.execute("insert into session_v2 values('s1', 'p1', '/a', 1, 5)")
c.commit()
EOF
LD="${T}/lossy/share/opencode"
if "${TOOL}" --data-dir "${LD}" rebuild --apply --yes > /dev/null 2>&1; then
    check "rebuild --apply refuses a lossy rebuild without --accept-loss" false
else
    check "rebuild --apply refuses a lossy rebuild without --accept-loss" true
fi
check "the refused rebuild left the original database in place" python3 -c "
import sqlite3, sys
assert sqlite3.connect(sys.argv[1]).execute('select count(*) from project where id is null').fetchone()[0] == 1" "${LD}/opencode.db"
"${TOOL}" --data-dir "${LD}" rebuild --apply --accept-loss --yes > /dev/null
check "rebuild --apply --accept-loss applies it" python3 -c "
import sqlite3, sys
assert sqlite3.connect(sys.argv[1]).execute('select id from project').fetchall() == [('p1',)]" "${LD}/opencode.db"

# A write-ahead log that SQLite cannot use is dropped by the rebuild, which loses
# the transactions only in it: the tool must report that. SQLite rarely fails to
# open a bad WAL, so the tool is loaded as a module and the first connect fails.
mkdir -p "${T}/walloss/share/opencode"
if python3 - "${T}/walloss/share/opencode" "${TOOL}" > /dev/null 2>&1 << 'EOF'; then
import importlib.machinery
import importlib.util
import shutil
import sqlite3
import sys
from pathlib import Path

data = Path(sys.argv[1])
live = sqlite3.connect(str(data / "opencode.db"))
live.execute("pragma journal_mode=wal")
live.execute("pragma wal_autocheckpoint=0")
live.execute("create table t(x)")
live.execute("insert into t values (1)")
live.commit()
# Copy while the writer is open, so that the -wal file still holds the data.
shutil.copyfile(str(data / "opencode.db"), str(data / "main.copy"))
shutil.copyfile(str(data / "opencode.db-wal"), str(data / "wal.copy"))
live.close()
for name in ("opencode.db", "opencode.db-wal", "opencode.db-shm"):
    (data / name).unlink(missing_ok=True)
(data / "main.copy").rename(data / "opencode.db")
(data / "wal.copy").rename(data / "opencode.db-wal")

loader = importlib.machinery.SourceFileLoader("oc2db", sys.argv[2])
spec = importlib.util.spec_from_loader("oc2db", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

work1 = data.parent / "work1"
work2 = data.parent / "work2"
work1.mkdir()
work2.mkdir()

conn, dropped = mod.open_source_copy(data, str(work1))
assert dropped is False, "a usable WAL must not be reported as dropped"
assert conn.execute("select count(*) from t").fetchone()[0] == 1, "the WAL data must be readable"
conn.close()

real_connect = mod.sqlite3.connect
calls = []


def failing_first(*args, **kwargs):
    calls.append(args)
    if len(calls) == 1:
        raise mod.sqlite3.DatabaseError("database disk image is malformed")
    return real_connect(*args, **kwargs)


mod.sqlite3.connect = failing_first
conn, dropped = mod.open_source_copy(data, str(work2))
assert dropped is True, "an unusable, non-empty WAL must be reported as dropped"
conn.close()
EOF
    check "a write-ahead log that cannot be used is reported as dropped" true
else
    check "a write-ahead log that cannot be used is reported as dropped" false
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
