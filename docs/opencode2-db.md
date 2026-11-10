# OpenCode 2 database guard and `opencode2-db`

OpenCode 2 keeps sessions, messages, projects, saved sign-in and plugin
storage in one SQLite file, `<data dir>/opencode.db`, and always opens it in
WAL mode. The data directory is in the home directory, which is NFS and is
mounted on every workstation and login host.

SQLite documents that WAL mode does not work on a network file system when more
than one host uses the file. The OpenCode 2 database has been damaged twice
(`database disk image is malformed`, the server answers HTTP 500 and the TUI
exits at once). The second time, two OpenCode builds had the file open within
the same 11 seconds. The cause is not proven; the guard removes the situations
SQLite says are unsafe, and the backups limit what a failure costs.

Three parts:

| Part | What it is |
| --- | --- |
| `lib/opencode2-db-lock.sh` | Library with `oc2db_guard`; sourced by `bwopencode2` and by the ansible `opencode2` wrapper |
| `bin/opencode2-db` | Command for the user: `status`, `backup`, `restore`, `rebuild`, `clear` |
| `tests/test-opencode2-db-guard.sh` | Automated tests (fake `/proc`, temporary data directory) |

## What the guard does at start

`oc2db_guard` runs on the host before OpenCode 2 starts.

| Situation | Result |
| --- | --- |
| The last daily check found damage (`CHECK-FAILED` flag) | Refuse; the message says how to recover |
| A session lock is held by another host | Refuse |
| A session lock is held on this host by a different OpenCode version | Refuse |
| A live session on this host with the same version recorded a different build of the binary (a reinstall of the same version while it runs) | Refuse |
| An OpenCode 2 process of this user on this host runs a different binary (an old build still running after an upgrade), in any PID namespace | Refuse |
| An unsandboxed OpenCode 2 process of this user on this host took no part in the locking (an older wrapper, started by hand, or the background service) | Refuse |
| Same host, same version, sessions that hold their lock | Allow; any number may run together |
| `OPENCODE2_DB_GUARD=off` | Skip every check, print a warning and log it |
| No `flock`, or the lock directory cannot be created | Warn and start (the guard must not stop people for a reason that is not a hazard) |

A refusal prints what it found (host, version, process ids, start time and
directory) and exits with status 1. Every refusal and override is logged with
`logger -t opencode2-db-guard`, so syslog (and Loki) show how often people run
sessions on two hosts.

### How the lock works

- Each session holds a shared `flock(2)` lock on
  `session@<host>@<version>.lock`. The lock is on a file descriptor opened by
  the launcher; the launcher's `exec` passes the descriptor on (through `env`
  and `bwrap` for `bwopencode2`), so the lock lasts as long as any process
  still has it open.
- Each session also writes the build id of its binary (device and inode) as the
  first line of its lock file, under `guard.lock`, so a launch compares builds
  even while the other launcher has not yet started its process.
- A launch first holds `guard.lock` exclusively, so two launches cannot both
  pass the checks, then tries an exclusive, non-blocking lock on every other
  session lock file. A file it can lock has no holder: it is removed.
- On NFSv4 the client turns `flock` into byte-range locks on the server, which
  is what makes them visible from other hosts. They have a lease: a host that
  dies releases its locks after about 90 seconds, so a refusal that names a
  host that is gone clears itself.
- Every process that OpenCode starts inherits the descriptor. A tool or
  background command that outlives OpenCode keeps the lock; the refusal then
  names the host, and ending that process frees it.
- If the home directory is mounted with `local_lock=all`, `local_lock=flock` or
  `nolock`, locks are local to one host and the cross-host check cannot see
  anything. The guard prints a warning in that case.

### Where the files are

Next to the data directory, not in it, so the sandbox (which mounts the data
directory read-write) cannot reach the locks, the backups or the flag:

```text
~/.local/share/opencode2/opencode               data directory (opencode.db)
~/.local/share/opencode2/opencode-db-guard/
    guard.lock
    locks/session@<host>@<version>.lock
    backups/opencode-<UTC>.db.gz                newest 3
    backups/last-success, backup.lock
    backup.log                                  output of the last backup job
    CHECK-FAILED                                present only after a failed check
```

### Daily backup

When the guard lets a launch through and the last backup is over 24 hours old,
it starts `opencode2-db backup --if-due --delay 30` in the background (`setsid`,
`nice -n 19`, `ionice -c 3`; it closes the session lock descriptor first so it
never holds the lock). The job:

1. copies the database with SQLite's backup API into `/var/tmp` (not NFS),
2. runs `PRAGMA quick_check` on the copy (about 20 seconds when run on a
   340 MB file over NFS, fast on local disk),
3. compresses the copy into `backups/` (about half the size) and keeps the
   newest 3,
4. on damage writes `CHECK-FAILED` and logs it; the next launch refuses.

A backup that cannot be made for another reason (no space, database busy) only
logs and tries again at the next launch. Damage that stops SQLite from reading
the file at all counts as damage, not as a failed backup.

## `opencode2-db`

Run it on the host, not in the sandbox (it refuses when `BWRAP_SANDBOX` is
set). It needs `python3` 3.7 or newer with the standard library only. The data
directory defaults to `~/.local/share/opencode2/opencode`; `--data-dir` changes
it.

| Command | Purpose |
| --- | --- |
| `opencode2-db status` | Locks held, backups, damage flag, last backup job |
| `opencode2-db backup [--if-due] [--delay S] [--keep N]` | Make a backup now |
| `opencode2-db restore [BACKUP] [--yes]` | Put a backup in place (default: newest) |
| `opencode2-db rebuild [--apply] [--accept-loss] [--yes]` | Copy readable tables into a new database |
| `opencode2-db clear` | Remove the damage flag without changing anything |

The database holds saved sign-in, so every file the tool makes (backups,
restored and rebuilt databases, temporary copies) is private (mode 0600, the
guard directory 0700); the launchers create the guard directory the same way.

`restore`, `rebuild` and `clear` take `guard.lock` and refuse while any session
lock is held. The damaged files are never deleted: they are renamed to
`opencode.db.corrupt-<date>` (with `-wal` and `-shm` alongside, and a time
suffix if the name exists).

### Recovering from a damaged database

Symptom: the TUI exits at once with `UnexpectedStatus: 500`, or the launcher
refuses with "the last database check found damage". The cause is in
`~/.local/share/opencode2/opencode/log/opencode.log`: `V1 migration failed ...
database disk image is malformed`.

1. Close every OpenCode 2 session on every host.
2. `opencode2-db status` shows the backups.
3. Prefer the backup: `opencode2-db restore`. Sessions made after the backup
   time are not in it; the damaged file is kept.
4. With no usable backup: `opencode2-db rebuild`. It copies each readable table
   into a new file, rebuilds `project` from `session_v2` and `worktree` when its
   rows are damaged (name, icon and commands are lost), leaves `kv` empty when it
   is damaged (plugin storage is lost), then checks `integrity_check` and
   `foreign_key_check` and compares row counts. Without `--apply` it only
   builds the file and reports; `--apply` puts it in place, and when data was
   lost (a table that could not be copied completely, `project` rebuilt, `kv`
   left empty, or the write-ahead log `opencode.db-wal` unusable so that
   transactions only in it are dropped) it also needs `--accept-loss`.
5. Start OpenCode 2 and check the session list. The first start after a restore
   may re-run the OpenCode 1 import: look for duplicate sessions.

The rebuild works on a private copy of the database and its WAL, so the
original is not changed until `--apply`.

## Using the library from another launcher

```bash
source /opt/nsls2/scripts/lib/opencode2-db-lock.sh
OC2DB_PROG=opencode2
oc2db_guard "$XDG_DATA_HOME/opencode" "$bin" || exit 1
exec "$bin" "$@"          # the lock descriptor stays open across exec
```

`oc2db_guard DATA_DIR [BIN]` returns 1 after printing why not. Pass the
OpenCode 2 binary as `BIN` so the version is read from it and running processes
can be compared with it; without it the version is `unknown` and the
different-build check is skipped. It exports `OC2DB_GUARDED=1`, which is how
other launches recognise an unsandboxed process that took part in the locking.

Do not call it for commands that never open the database (`--help`,
`--version`, `upgrade`, `update`, `uninstall`): `oc2db_needs_guard "$@"` returns
1 for those and 0 otherwise. It skips the value of `--session`/`-s`, `--prompt`
and `--log-level` (so `--prompt upgrade` is guarded), accepts a subcommand only
as the first positional word and looks for help and version flags anywhere
before `--`. `bwopencode2` also skips `--exec` and `--dry-run`.

## Environment variables

| Variable | Effect |
| --- | --- |
| `OPENCODE2_DB_GUARD=off` | Skip every check for this launch |
| `OPENCODE2_DB_BACKUPS=N` | Backups to keep; `0` turns backups off (default 3) |
| `OC2DB_PROG` | Program name in messages (set by the launcher) |
| `OC2DB_TMPDIR` | Where `opencode2-db` makes its temporary copies (default `/var/tmp`) |
| `OC2DB_PROC`, `OC2DB_TOOL`, `OC2DB_BACKUP_DELAY` | Test hooks: an alternate `/proc`, the backup command, and the seconds the background backup waits (default 30) |

## Limits

- A session that took no lock cannot be seen if it runs in another PID
  namespace (a sandbox started by `bwopencode2` before this guard existed) or on
  another host (an unsandboxed `opencode2` started before the wrapper used the
  guard). The backups are the safety net for those.
- Two sessions of the same build on one host still share a WAL database on NFS.
  SQLite accepts that on one host; NFS makes it less safe than local disk.
- The guard compares processes by their executable (device and inode). If the
  OpenCode binary is replaced while sessions run, the old sessions count as an
  old build until they exit, which is the point.

## Tests

```bash
tests/test-opencode2-db-guard.sh
```

Needs `bash`, `flock` and `python3`. It uses a temporary directory and a fake
`/proc` and prints `ok` or `FAIL` per case. It cannot show locks across two
hosts. To check that on real hosts, hold a lock on one and start the guard on
the other, with the home directory shared between them:

```bash
# host A
bash -c 'source lib/opencode2-db-lock.sh; OC2DB_PROG=test; oc2db_guard "$HOME/.local/share/opencode2/opencode" && sleep 120'
# host B, within the 120 seconds: must print "not starting" and exit 1
bash -c 'source lib/opencode2-db-lock.sh; OC2DB_PROG=test; oc2db_guard "$HOME/.local/share/opencode2/opencode"; echo rc=$?'
```
