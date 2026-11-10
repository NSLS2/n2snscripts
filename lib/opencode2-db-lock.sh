#!/usr/bin/env bash
# opencode2-db-lock.sh — keep two OpenCode 2 processes from sharing one
# SQLite database on NFS.  Source this file; it only defines functions.
#
# Why: OpenCode 2 keeps sessions, credentials and plugin storage in
# <data dir>/opencode.db and always puts it in WAL mode.  SQLite does not
# support WAL on a network file system when the file is used from more than one
# host, and two OpenCode builds writing to it at the same time damaged it
# (database disk image is malformed).  The home directory is NFS, so the same
# file can be reached from every workstation and login host.
#
# What oc2db_guard does, before OpenCode 2 starts:
#   - refuses when another host holds a session lock (live session there) or
#     a backup lock (its backup job is reading the database);
#   - refuses when this host has a session of a different version, a session of
#     the same version that recorded another build of the binary, or an
#     OpenCode 2 process that is not the binary about to run (an old build still
#     running after an upgrade);
#   - refuses when an unsandboxed OpenCode 2 process of this user on this host
#     did not take part in the locking (started by an older wrapper or by hand),
#     because it cannot be told apart from an old build;
#   - refuses when the last daily check found damage (flag file);
#   - otherwise takes a shared lock on a per host and version lock file, held
#     on a file descriptor that the caller's `exec` passes to OpenCode.  The
#     lock lasts as long as that descriptor stays open in any process.  When
#     the version cannot be read the lock file is per process id instead, so
#     such a session never shares a lock and any later launch refuses on it.
#   - starts the daily backup (bin/opencode2-db backup --if-due) in the
#     background when it is due.
#
# Locks are flock(2) locks; on NFSv4 the client turns them into byte-range
# locks held on the server, which is what makes them visible across hosts
# (they have a lease, so a host that dies releases them).  The lock and backup
# files live next to the data directory, not in it, so a sandbox that mounts the
# data directory read-write cannot reach them.
#
# Environment:
#   OPENCODE2_DB_GUARD=off     skip every check (logged)
#   OPENCODE2_DB_BACKUPS=N     backups to keep (default 3, 0 turns backups off)
#   OC2DB_PROG                 name used in messages (set by the caller)
#   OC2DB_PROC, OC2DB_TOOL,    test hooks (alternate /proc, backup tool, and the
#   OC2DB_BACKUP_DELAY         seconds the background backup waits, default 30)
#
# Usage (callers use `|| exit 1`):
#   source lib/opencode2-db-lock.sh
#   OC2DB_PROG=bwopencode2
#   oc2db_guard "$HOME/.local/share/opencode2/opencode" "$opencode_exe" || exit 1
#   exec ...            # the lock descriptor stays open across exec

[[ -n "${_OC2DB_LOCK_LIB_SOURCED:-}" ]] && return 0
_OC2DB_LOCK_LIB_SOURCED=1

_OC2DB_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The lock descriptor, kept open for the life of the process (and, through
# exec, of OpenCode).  Set by oc2db_guard.
OC2DB_SESSION_FD=""

oc2db_log() {
    # A failing or slow logger must never block a launch.
    timeout 5 logger -t opencode2-db-guard -p user.notice -- "$*" > /dev/null 2>&1 || true
}

oc2db_warn() {
    printf '%s: warning: %s\n' "${OC2DB_PROG:-opencode2}" "$*" >&2
    oc2db_log "warning: $*"
}

# Print the refusal: a reason line, detail lines, and how to proceed.
# Usage: oc2db_refuse REASON [DETAIL...]
oc2db_refuse() {
    local _reason="$1"
    shift
    {
        printf '%s: not starting, %s\n' "${OC2DB_PROG:-opencode2}" "${_reason}"
        local _line
        for _line in "$@"; do
            printf '  %s\n' "${_line}"
        done
        printf '  %s\n' "${OC2DB_REFUSE_HINT:-Close that session (and anything it started), then try again.}"
        printf '  Running anyway risks a corrupted database; to override once:\n'
        printf '    OPENCODE2_DB_GUARD=off %s ...\n' "${OC2DB_PROG:-opencode2}"
    } >&2
    oc2db_log "refused: ${_reason} user=${USER:-$(id -un)} host=$(oc2db_host)"
}

# Names go into file names: keep them to [A-Za-z0-9._-].
oc2db_sanitize() {
    local _s="${1//[^A-Za-z0-9._-]/_}"
    printf '%s' "${_s:-unknown}"
}

oc2db_host() {
    oc2db_sanitize "$(hostname 2> /dev/null || echo unknown)"
}

# Version of the binary about to run ("opencode v2.2.5" -> 2.2.5).
oc2db_version() {
    local _bin="$1" _out=""
    if [[ -x "${_bin}" ]]; then
        _out="$(timeout 10 "${_bin}" --version 2> /dev/null < /dev/null | grep -oE -m1 '[0-9]+\.[0-9]+\.[0-9][0-9A-Za-z._+-]*' || true)"
    fi
    oc2db_sanitize "${_out}"
}

# Directory for locks, backups and the damage flag: a sibling of the data
# directory (~/.local/share/opencode2/opencode-db-guard), outside the mount.
oc2db_guard_dir() {
    local _data="${1%/}"
    printf '%s/opencode-db-guard' "$(dirname -- "${_data}")"
}

# "<dev>:<inode>" of a file or of what a /proc/PID/exe link points at.
oc2db_file_id() {
    stat -L -c '%d:%i' -- "$1" 2> /dev/null
}

# Warn when NFS locks are local to this client, which makes the cross host
# check blind.
oc2db_check_lock_scope() {
    local _dir="$1" _opts
    command -v findmnt > /dev/null 2>&1 || return 0
    _opts="$(findmnt -n -o OPTIONS -T "${_dir}" 2> /dev/null || true)"
    if [[ "${_opts}" =~ (^|,)(nolock|local_lock=(all|flock))(,|$) ]]; then
        oc2db_warn "${_dir} is mounted with local-only locks (${BASH_REMATCH[2]}); sessions on other hosts cannot be seen"
    fi
}

# Find OpenCode 2 processes of this user that conflict with starting a session
# of the binary $1.  Fills _OC2DB_OTHER_BUILD and _OC2DB_UNLOCKED with
# "PID  START  DIRECTORY" lines.
#   other build: the running executable is not $1 (old build after an upgrade,
#                or a different install), in any PID namespace;
#   unlocked:    same PID namespace as the caller (unsandboxed) and no
#                OC2DB_GUARDED marker in its environment.
oc2db_scan_processes() {
    local _bin_id="$1" _proc="${OC2DB_PROC:-/proc}"
    local _d _pid _exe _base _id _ns _my_ns _desc
    _OC2DB_OTHER_BUILD=()
    _OC2DB_UNLOCKED=()
    _my_ns="$(readlink "${_proc}/self/ns/pid" 2> /dev/null || true)"
    for _d in "${_proc}"/[0-9]*; do
        _pid="${_d##*/}"
        [[ "${_pid}" == "$$" ]] && continue
        [[ -O "${_d}" ]] || continue
        _exe="$(readlink "${_d}/exe" 2> /dev/null)" || continue
        _base="${_exe% (deleted)}"
        [[ "${_base##*/}" == "opencode.exe" ]] || continue
        _desc="${_pid}  started $(ps -o lstart= -p "${_pid}" 2> /dev/null | tr -s ' ' || true)  in $(readlink "${_d}/cwd" 2> /dev/null || echo '?')"
        if [[ -n "${_bin_id}" ]]; then
            _id="$(oc2db_file_id "${_d}/exe" || true)"
            if [[ -n "${_id}" && "${_id}" != "${_bin_id}" ]]; then
                _OC2DB_OTHER_BUILD+=("${_desc}")
                continue
            fi
        fi
        _ns="$(readlink "${_d}/ns/pid" 2> /dev/null || true)"
        if [[ -n "${_ns}" && "${_ns}" == "${_my_ns}" ]]; then
            # grep without -q reads all its input: with -q it exits at the first
            # match and tr can die of SIGPIPE, which under the caller's pipefail
            # would report a guarded process as unlocked.
            if [[ -r "${_d}/environ" ]] && ! tr '\0' '\n' < "${_d}/environ" 2> /dev/null | grep -x 'OC2DB_GUARDED=1' > /dev/null; then
                _OC2DB_UNLOCKED+=("${_desc}")
            fi
        fi
    done
}

# Probe every session lock file and every backup lock file (backup@HOST.lock,
# held by `opencode2-db backup` while it reads the database).  A file we can
# lock exclusively has no holder: another host's or version's is stale and is
# removed.  A backup lock of this host is ignored: sessions and a backup on one
# host are safe together.  Fills
#   _OC2DB_HELD         "HOST VERSION" of live locks of another host or version;
#                       VERSION is "backup" for a backup job on another host
#   _OC2DB_BUILD_CLASH  "HOST VERSION" when the live holders of OUR lock file
#                       (this host, this version) recorded another build id
# A session writes its build id (device:inode of the binary) as the first line
# of its lock file, under guard.lock, so a build that has not started its
# process yet is still compared.
oc2db_probe_locks() {
    local _locks="$1" _own="$2" _bin_id="$3" _f _name _rest _host _ver _fd _recorded
    local _me
    _me="$(oc2db_host)"
    _OC2DB_HELD=()
    _OC2DB_BUILD_CLASH=()
    for _f in "${_locks}"/session@*.lock "${_locks}"/backup@*.lock; do
        [[ -e "${_f}" ]] || continue
        _name="${_f##*/}"
        if [[ "${_name}" == backup@* ]]; then
            _host="${_name#backup@}"
            _host="${_host%.lock}"
            [[ "${_host}" == "${_me}" ]] && continue
            if { exec {_fd}<> "${_f}"; } 2> /dev/null; then
                if flock -x -n "${_fd}" 2> /dev/null; then
                    rm -f -- "${_f}"
                else
                    _OC2DB_HELD+=("${_host} backup")
                fi
                exec {_fd}>&-
            fi
            continue
        fi
        if [[ "${_name}" == "${_own}" ]]; then
            if [[ -n "${_bin_id}" ]] && { exec {_fd}<> "${_f}"; } 2> /dev/null; then
                if ! flock -x -n "${_fd}" 2> /dev/null; then
                    _recorded=""
                    IFS= read -r _recorded < "${_f}" || true
                    if [[ -n "${_recorded}" && "${_recorded}" != "${_bin_id}" ]]; then
                        _rest="${_name#session@}"
                        _rest="${_rest%.lock}"
                        _OC2DB_BUILD_CLASH+=("${_rest%%@*} ${_rest#*@}")
                    fi
                fi
                exec {_fd}>&-
            fi
            continue
        fi
        if { exec {_fd}<> "${_f}"; } 2> /dev/null; then
            if flock -x -n "${_fd}" 2> /dev/null; then
                rm -f -- "${_f}"
            else
                _rest="${_name#session@}"
                _rest="${_rest%.lock}"
                _host="${_rest%%@*}"
                _ver="${_rest#*@}"
                _OC2DB_HELD+=("${_host} ${_ver}")
            fi
            exec {_fd}>&-
        fi
    done
}

# oc2db_needs_guard ARGS...: the opencode2 command line, as given to the
# launcher.  Returns 1 when it never opens the database (help, version,
# completions, upgrade, update, uninstall), 0 otherwise.  Options that take a
# value (--session/-s, --prompt, --log-level) are skipped with their value, so
# `--prompt upgrade` still needs the guard; only the first positional word can
# be a subcommand; help and version flags count anywhere before `--`.
oc2db_needs_guard() {
    local _skip=0 _first=1 _arg
    for _arg in "$@"; do
        if ((_skip)); then
            _skip=0
            continue
        fi
        case "${_arg}" in
            --)
                break
                ;;
            --help | -h | --version | -v | --completions | --completions=*)
                return 1
                ;;
            --session | -s | --prompt | --log-level)
                _skip=1
                ;;
            -*) ;;
            *)
                if ((_first)); then
                    _first=0
                    case "${_arg}" in
                        upgrade | update | uninstall) return 1 ;;
                    esac
                fi
                ;;
        esac
    done
    return 0
}

# oc2db_guard DATA_DIR [OPENCODE_BIN]
# Returns 0 to go ahead (with the session lock held on OC2DB_SESSION_FD), 1
# after printing why not.  Problems with the lock files themselves (no flock,
# read-only directory) warn and go ahead: the guard must not stop people for a
# reason that is not a hazard.
oc2db_guard() {
    local _data="$1" _bin="${2:-}"
    local _gdir _locks _host _ver _own _gfd _bin_id="" _h _line _hint _only_backup
    local -a _details

    if [[ "${OPENCODE2_DB_GUARD:-}" == "off" ]]; then
        oc2db_warn "OPENCODE2_DB_GUARD=off: database checks skipped (logged)"
        return 0
    fi
    if ! command -v flock > /dev/null 2>&1; then
        oc2db_warn "flock not found; database lock checks skipped"
        return 0
    fi

    _gdir="$(oc2db_guard_dir "${_data}")"
    _locks="${_gdir}/locks"
    if ! (umask 077 && mkdir -p "${_gdir}" "${_locks}") 2> /dev/null; then
        oc2db_warn "cannot create ${_gdir}; database lock checks skipped"
        return 0
    fi
    oc2db_check_lock_scope "${_gdir}"

    _host="$(oc2db_host)"
    _ver="unknown"
    if [[ -n "${_bin}" && -x "${_bin}" ]]; then
        _ver="$(oc2db_version "${_bin}")"
        _bin_id="$(oc2db_file_id "${_bin}" || true)"
    fi
    # A version that could not be read says nothing about the build, so such a
    # session gets a lock file of its own (by process id): no other session
    # shares it, and any later launch on this host refuses on it.
    if [[ "${_ver}" == "unknown" ]]; then
        _own="session@${_host}@unknown-$$.lock"
    else
        _own="session@${_host}@${_ver}.lock"
    fi

    # One launch checks at a time, so two launches cannot both pass.
    if ! { exec {_gfd}<> "${_gdir}/guard.lock"; } 2> /dev/null; then
        oc2db_warn "cannot open ${_gdir}/guard.lock; database lock checks skipped"
        return 0
    fi
    if ! flock -x -w 30 "${_gfd}" 2> /dev/null; then
        exec {_gfd}>&-
        oc2db_refuse "another launch has held the check lock for 30 s" \
            "lock: ${_gdir}/guard.lock"
        return 1
    fi

    if [[ -e "${_gdir}/CHECK-FAILED" ]]; then
        mapfile -t _details < "${_gdir}/CHECK-FAILED"
        exec {_gfd}>&-
        oc2db_refuse "the last database check found damage" \
            "${_details[@]}" \
            "Restore or rebuild it first: opencode2-db status" \
            "(the files are in ${_gdir})"
        return 1
    fi

    oc2db_probe_locks "${_locks}" "${_own}" "${_bin_id}"
    if ((${#_OC2DB_HELD[@]} > 0)); then
        _details=()
        for _h in "${_OC2DB_HELD[@]}"; do
            if [[ "${_h#* }" == "backup" ]]; then
                _details+=("a database backup is running on ${_h% *}")
            elif [[ "${_h#* }" == unknown* ]]; then
                _details+=("session lock held by ${_h% *} (OpenCode, version could not be read)")
            else
                _details+=("session lock held by ${_h% *} (OpenCode ${_h#* })")
            fi
        done
        if [[ "${_ver}" == "unknown" ]]; then
            _details+=("The version of this OpenCode 2 could not be read, so it cannot be shown to be the same build as a running session.")
        fi
        _details+=("The database is on NFS; two hosts, or two OpenCode versions, must not use it together.")
        exec {_gfd}>&-
        # Only backup jobs: they are short, so say to wait, not to close a session.
        _hint=""
        _only_backup=1
        for _h in "${_OC2DB_HELD[@]}"; do
            [[ "${_h#* }" == "backup" ]] || _only_backup=0
        done
        ((_only_backup)) && _hint="Try again shortly: a backup job reads the database for about a minute."
        # A session lock on this host with the same version is not in the list.
        OC2DB_REFUSE_HINT="${_hint}" oc2db_refuse "the database is in use by another host or OpenCode version" "${_details[@]}"
        return 1
    fi

    if ((${#_OC2DB_BUILD_CLASH[@]} > 0)); then
        _details=("a live session on this host with the same version (${_ver}) recorded a different build of the binary")
        _details+=("(for example a reinstall of the same version while it runs)")
        exec {_gfd}>&-
        oc2db_refuse "an OpenCode 2 of a different build is running on this host" "${_details[@]}"
        return 1
    fi

    oc2db_scan_processes "${_bin_id}"
    if ((${#_OC2DB_OTHER_BUILD[@]} > 0)); then
        _details=("OpenCode 2 process(es) of a different build than ${_bin:-this one} (${_ver}):")
        for _line in "${_OC2DB_OTHER_BUILD[@]}"; do
            _details+=("  ${_line}")
        done
        exec {_gfd}>&-
        oc2db_refuse "an old OpenCode 2 is still running on this host" "${_details[@]}"
        return 1
    fi
    if ((${#_OC2DB_UNLOCKED[@]} > 0)); then
        _details=("Unsandboxed OpenCode 2 process(es) that took no database lock (started by an older wrapper, by hand, or as the background service):")
        for _line in "${_OC2DB_UNLOCKED[@]}"; do
            _details+=("  ${_line}")
        done
        exec {_gfd}>&-
        oc2db_refuse "an OpenCode 2 on this host is not using the database guard" "${_details[@]}"
        return 1
    fi

    # Take the session lock last.  Shared: any number of sessions of this
    # version on this host may hold it together.
    if ! { exec {OC2DB_SESSION_FD}<> "${_locks}/${_own}"; } 2> /dev/null ||
        ! flock -s -n "${OC2DB_SESSION_FD}" 2> /dev/null; then
        oc2db_warn "cannot take the session lock ${_locks}/${_own}; continuing without it"
        OC2DB_SESSION_FD=""
    elif [[ -n "${_bin_id}" ]]; then
        printf '%s\n' "${_bin_id}" 1>&"${OC2DB_SESSION_FD}" 2> /dev/null || true
    fi
    export OC2DB_GUARDED=1
    exec {_gfd}>&-

    oc2db_backup_if_due "${_data}" "${_gdir}"
    return 0
}

# Start the daily backup in the background.  The job closes the session lock
# descriptor first, so it never keeps the session lock alive after OpenCode
# exits; while it reads the database it holds its own backup lock
# (opencode2-db backup_window), which launches on other hosts refuse on, and it
# skips the backup when another host has a live session.  It is detached so
# closing the terminal does not kill it.
oc2db_backup_if_due() {
    local _data="$1" _gdir="$2" _tool _keep="${OPENCODE2_DB_BACKUPS:-3}"
    [[ "${_keep}" == "0" ]] && return 0
    [[ -f "${_data}/opencode.db" ]] || return 0
    _tool="${OC2DB_TOOL:-${_OC2DB_LIB_DIR}/../bin/opencode2-db}"
    if [[ ! -x "${_tool}" ]] || ! command -v python3 > /dev/null 2>&1; then
        return 0
    fi
    local -a _run=(nice -n 19)
    command -v ionice > /dev/null 2>&1 && _run=(ionice -c 3 nice -n 19)
    command -v setsid > /dev/null 2>&1 && _run=(setsid "${_run[@]}")
    {
        [[ -n "${OC2DB_SESSION_FD}" ]] && exec {OC2DB_SESSION_FD}>&-
        exec "${_run[@]}" "${_tool}" --data-dir "${_data}" \
            backup --if-due --delay "${OC2DB_BACKUP_DELAY:-30}" --keep "${_keep}" \
            < /dev/null > "${_gdir}/backup.log" 2>&1
    } &
    disown 2> /dev/null || true
}
