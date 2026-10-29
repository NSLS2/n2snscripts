#!/usr/bin/env bash
# bwrap_sandbox_lib.sh — Shared library for bubblewrap sandbox wrappers.
#
# Provides the common infrastructure for sandboxing CLI tools with bwrap:
#   - bwrap version detection and capability flags
#   - Dynamic mount helpers (deduplication, symlink resolution, npm detection)
#   - Git config include-path parsing
#   - Sandbox PATH construction
#   - Shell detection
#   - All shared bwrap mounts: base system, binary masking, /sys (cpu +
#     node topology, read-only), /etc, home tmpfs,
#     working directory, git config, pixi, ccache, npm, user bin, NSLS-II,
#     dynamic tool mounts, user-supplied extra paths (--ro-path / --rw-path)
#   - Environment variable framework (clean env + passthrough)
#   - Launch logic (dry-run printing and bwrap exec)
#
# Tool-specific wrapper scripts source this file and provide:
#   - Argument parsing (parse_wrapper_args) — must handle --ro-path/--rw-path
#     and accumulate values into the shared EXTRA_RO_PATHS/EXTRA_RW_PATHS arrays
#   - Binary resolution: call bwrap_resolve_tool NAME [HINT] (sets _TOOL_BIN and _TOOL_CMD)
#   - Help text (show_help)
#   - Tool-specific path resolution, host directory creation, mounts, and env vars
#   - main() orchestrating the build sequence — must call build_extra_path_mounts
#     after build_dynamic_tool_mounts
#
# Usage (in tool wrapper scripts):
#   SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
#   source "${SCRIPT_DIR}/bwrap_sandbox_lib.sh"
#
# Requires: bwrap >= 0.4.0 (RHEL 8)
#   - 0.4.0: base functionality
#   - 0.6.3+: bind over ro-bind (fallback: skip binary masking)

# Guard against double-sourcing.
[[ -n "${_BWRAP_SANDBOX_LIB_SOURCED:-}" ]] && return 0
_BWRAP_SANDBOX_LIB_SOURCED=1

# ═══════════════════════════════════════════════════════════════════
# Global state
# ═══════════════════════════════════════════════════════════════════

# Wrapper control flags (set by tool-specific parse_wrapper_args)
# shellcheck disable=SC2034  # used by tool wrappers that source this library
DRY_RUN=0
# shellcheck disable=SC2034  # used by tool wrappers that source this library
TEST_CMD=""
# shellcheck disable=SC2034  # used by tool wrappers that source this library
SHOW_HELP=0
# shellcheck disable=SC2034  # used by print_dry_run and launch_sandbox
TOOL_ARGS=()
# shellcheck disable=SC2034  # set by tool wrappers when --new-session is requested
FORCE_NEW_SESSION=0

# Extra user-supplied paths to mount into the sandbox.
# Populated by tool-specific parse_wrapper_args via --ro-path / --rw-path.
# Validated and mounted by build_extra_path_mounts.
# shellcheck disable=SC2034  # used by tool wrappers that source this library
EXTRA_RO_PATHS=()
# shellcheck disable=SC2034  # used by tool wrappers that source this library
EXTRA_RW_PATHS=()

# N2C access tokens requested with --n2c-token (names, or "all").
# Populated by add_n2c_token; mounted by build_n2c_token_mounts.
N2C_TOKENS=()

# Tool binary (set by bwrap_resolve_tool)
_TOOL_BIN=""
_TOOL_CMD=()

# bwrap construction
BWRAP_ARGS=()
declare -A _MOUNTED_PREFIXES=()
_EXTRA_PATH_DIRS=()

# Cached result of `npm prefix -g` (resolved at most once per run).
# _NPM_PREFIX_RESOLVED flips to 1 after the first lookup; _NPM_PREFIX holds
# the value (empty string if npm is absent or the lookup failed).
_NPM_PREFIX=""
_NPM_PREFIX_RESOLVED=0

# Sandbox environment
SANDBOX_PATH=""
SANDBOX_SHELL=""
# NAME=VALUE entries for variables forwarded from the host (pass_through_if_set,
# forward_env_by_prefix) and other values that may be secret.  They are given
# to bwrap through `env -i` (see launch_sandbox) rather than as --setenv
# arguments, so they never appear on bwrap's command line.
SANDBOX_ENV=()

# bwrap capability flags (set by detect_bwrap_capabilities)
HAS_BIND_OVER_RO=0

# Kernel capability flags (set by detect_kernel_capabilities)
KERNEL_HAS_TIOCSTI_CAP_GUARD=0

# Git include tracking (used by parse_git_includes).
# GIT_INCLUDE_PATHS holds the CANONICAL (realpath) include files;
# GIT_INCLUDE_VISIBLE holds, at the same index, the path git itself will
# open once every symlinked directory that precedes a ".." has been
# resolved physically (see _bwrap_include_visible_path).  They differ when a
# parent directory of the include is a symlink; build_git_mounts then mounts
# the content at both paths.
# _GIT_INCLUDE_SEEN is keyed by the RAW include path (as git computes it), not
# by (canonical, visible): two raw paths that reach the same file can need
# different directories to exist in the sandbox (GIT_INCLUDE_PREDIRS), so each
# distinct raw path is its own record; build_git_mounts de-duplicates the
# resulting binds and directories.
declare -A _GIT_INCLUDE_SEEN=()
# _GIT_INCLUDE_PARSED: config files already read by parse_git_includes, keyed
# by the path AS OPENED (not the canonical path: two symlinks to one file each
# need their own traversal, because their relative includes resolve against
# different directories).  Include loops end at the depth limit.
declare -A _GIT_INCLUDE_PARSED=()
# Maximum include nesting followed (git's own limit is 10).
_GIT_INCLUDE_MAX_DEPTH=10
GIT_INCLUDE_PATHS=()
GIT_INCLUDE_VISIBLE=()
# GIT_INCLUDE_PREDIRS: at the same index, a newline-separated list of
# directories that must exist in the sandbox so git can resolve ".." in the
# include path it opens (see _bwrap_include_visible_path).
GIT_INCLUDE_PREDIRS=()
# GIT_INCLUDE_LINKS: at the same index, a newline-separated list of symlinked
# directories that precede a ".." in the include path.  The sandbox $HOME is
# a tmpfs, so build_git_mounts recreates them with --symlink; the kernel then
# resolves ".." against the symlink target exactly as it does on the host.
GIT_INCLUDE_LINKS=()
# GIT_INCLUDE_RAW: at the same index, the include path exactly as git computes
# it (not normalised); used to find where git looks for the file when a
# symlinked directory could not be recreated (see _bwrap_include_lexical_path).
GIT_INCLUDE_RAW=()

# Results of _bwrap_canonicalize_safe / _bwrap_include_visible_path /
# _bwrap_path_blocked (globals, because _check_path_safe calls exit and must
# not run in a subshell).
_BWRAP_CANON=""
_BWRAP_INC_VISIBLE=""
_BWRAP_GIT_VALUE=""
_BWRAP_INC_PREDIRS=""
_BWRAP_INC_LINKS=""
_BWRAP_INC_LEXICAL=""
_BWRAP_INC_LEXDIRS=""
_BWRAP_LEX_DEST=""
_BWRAP_BLOCKED_KIND=""
_BWRAP_BLOCKED_PREFIX=""

# Symlinks already handled by _bwrap_git_recreate_link: path -> 0 (present or
# recreated in the sandbox) / 1 (could not be recreated).
declare -A _GIT_LINK_STATUS=()
# Subset of the failed symlinks above: LINK -> 1 when LINK exists in the
# sandbox as a plain directory (see _bwrap_git_recreate_link).
declare -A _GIT_LINK_CONFLICT=()

# Working directory state (set by build_workdir_mount)
_BIND_DIR=""
_GIT_ROOT=""

# Common paths (set by resolve_common_paths).  _HOME is the logical $HOME;
# _HOME_CANON is its readlink -f form.  They differ when home is reached
# through a symlink (NFS/automount), and the $HOME-or-ancestor check must
# consult both because candidate paths are canonicalized before it runs.
# _PWD is the physical (pwd -P) working directory.  _USER is $USER, which can
# be unset under `set -u` (cron/CI), with a fallback to bwrap_account_name.
_HOME=""
_HOME_CANON=""
_PWD=""
_USER=""

# ═══════════════════════════════════════════════════════════════════
# Shared helper functions
# ═══════════════════════════════════════════════════════════════════

# _version_ge A B
#   Return 0 (true) if dotted version A is greater than or equal to B.
#   Uses `sort -V` (GNU coreutils, bash 4.1-era and later) so that
#   multi-component versions like 0.11.0 sort correctly against 0.5.0 —
#   a plain string/integer comparison would mis-order 0.11 vs 0.5.
_version_ge() {
    local a="$1" b="$2"
    [[ "${a}" == "${b}" ]] && return 0
    # If the lexicographically-smallest version (per sort -V) is B, then A > B.
    [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${b}" ]]
}

# Feature detection by parsing the version string — much cheaper than
# grepping --help.
#
# Version history:
#   0.6.3 - bind over ro-bind works (can mask binaries inside /usr)
detect_bwrap_capabilities() {
    local _bwrap_ver
    _bwrap_ver="$(bwrap --version)"
    _bwrap_ver="${_bwrap_ver##* }"            # "bubblewrap 0.11.0" -> "0.11.0"

    # Bind over ro-bind: ability to bind-mount on top of a read-only bind
    # mount (e.g., masking /usr/bin/ssh after --ro-bind /usr /usr).
    # This works in 0.6.3+; earlier versions fail with "Permission denied".
    # Fallback: skip binary masking (security reduction — tools remain accessible)
    HAS_BIND_OVER_RO=0
    if _version_ge "${_bwrap_ver}" "0.6.3"; then HAS_BIND_OVER_RO=1; fi
}

# Detect kernel-level security features that affect bwrap argument choice.
#
# TIOCSTI capability guard (Linux 5.14+):
#   On kernels >= 5.14, the TIOCSTI ioctl requires CAP_SYS_ADMIN on any
#   tty that is not the process's own controlling terminal.  bwrap drops
#   all capabilities unconditionally, so TIOCSTI is already blocked at
#   the kernel level — making --new-session redundant for that threat.
#
#   On older kernels (e.g. RHEL 8 / 4.18), --new-session is the only
#   guard against TIOCSTI injection and must be kept.
#
#   We omit --new-session when this guard is present so that SIGWINCH
#   (terminal resize) is delivered correctly from tmux and other
#   multiplexers to the sandboxed process.
detect_kernel_capabilities() {
    local _kver
    _kver="$(uname -r)"
    _kver="${_kver%%-*}"            # strip suffix e.g. "5.14.0-427.el9" -> "5.14.0"

    KERNEL_HAS_TIOCSTI_CAP_GUARD=0
    if _version_ge "${_kver}" "5.14"; then KERNEL_HAS_TIOCSTI_CAP_GUARD=1; fi
}

detect_shell() {
    SANDBOX_SHELL="$(command -v bash 2> /dev/null || echo /bin/sh)"
}

# bwrap_check_account
#   Refuse to run for root and shared/service accounts.  The check itself is
#   /opt/nsls2/libexec/agent-account-check, deployed by ansible: it prints a
#   boxed refusal to stderr and exits non-zero for those accounts, and exits
#   0 silently otherwise.  Every launcher calls this first in main().
#   The path is deliberately hard-coded (not overridable from the environment,
#   which would let a user point it at /bin/true).  When the script is not
#   installed this is a no-op: hosts without the ansible deploy are still
#   protected by the filesystem ACLs on the agent installs.
bwrap_check_account() {
    local _checker="/opt/nsls2/libexec/agent-account-check"
    if [[ -f "${_checker}" && -x "${_checker}" ]]; then
        "${_checker}" || exit $?
    fi
}

# _bwrap_filter_path
#   Set _BWRAP_FILTERED_PATH to PATH with exact, non-empty entries from
#   N2SNSCRIPTS_TOOL_EXCLUDE_PATH removed.  Returns 1 when every PATH entry
#   was excluded (PATH="" would make command -v search the current dir).
#   A no-op for callers when N2SNSCRIPTS_TOOL_EXCLUDE_PATH is unset: they
#   should skip this function in that case.
_BWRAP_FILTERED_PATH=""
_bwrap_filter_path() {
    local _excluded_dir _path_dir _remaining_path="${PATH-}" _remaining_exclusions
    local _has_separator _has_exclusion_separator _is_excluded _retained_count=0
    local -a _excluded_dirs=() _filtered_dirs=()
    local IFS=:

    # Split manually rather than with read: read stops at the first newline,
    # while exclusion entries may themselves contain newlines.
    _remaining_exclusions="${N2SNSCRIPTS_TOOL_EXCLUDE_PATH}"
    while :; do
        if [[ "${_remaining_exclusions}" == *:* ]]; then
            _has_exclusion_separator=1
            _excluded_dir="${_remaining_exclusions%%:*}"
            _remaining_exclusions="${_remaining_exclusions#*:}"
        else
            _has_exclusion_separator=0
            _excluded_dir="${_remaining_exclusions}"
        fi
        [[ -n "${_excluded_dir}" ]] && _excluded_dirs+=("${_excluded_dir}")
        [[ "${_has_exclusion_separator}" -eq 1 ]] || break
    done

    while :; do
        if [[ "${_remaining_path}" == *:* ]]; then
            _has_separator=1
            _path_dir="${_remaining_path%%:*}"
            _remaining_path="${_remaining_path#*:}"
        else
            _has_separator=0
            _path_dir="${_remaining_path}"
        fi

        _is_excluded=0
        for _excluded_dir in "${_excluded_dirs[@]}"; do
            if [[ -n "${_excluded_dir}" && "${_path_dir}" == "${_excluded_dir}" ]]; then
                _is_excluded=1
                break
            fi
        done
        if [[ "${_is_excluded}" -eq 0 ]]; then
            _filtered_dirs+=("${_path_dir}")
            ((_retained_count += 1))
        fi

        [[ "${_has_separator}" -eq 1 ]] || break
    done

    # An empty retained entry is meaningful (it searches the current
    # directory), but an entirely filtered PATH must not become PATH="".
    [[ "${_retained_count}" -gt 0 ]] || return 1

    _BWRAP_FILTERED_PATH="${_filtered_dirs[*]}"
}

# bwrap_find_tool TOOL
#   Locate TOOL using PATH with exact, non-empty entries from
#   N2SNSCRIPTS_TOOL_EXCLUDE_PATH removed.  This affects lookup only.
bwrap_find_tool() {
    if [[ -z "${N2SNSCRIPTS_TOOL_EXCLUDE_PATH:-}" ]]; then
        command -v -- "$1"
        return
    fi

    _bwrap_filter_path || return 1
    local PATH="${_BWRAP_FILTERED_PATH}"
    command -v -- "$1"
}

# ── Agent binary resolution and the "restricted" box ─────────────
# NOTE: bwrap_account_name and bwrap_print_banner mirror the box drawing in
# the ansible template roles/base/templates/agent-account-check.sh.j2 in
# NSLS2/ansible (same UTF-8/ASCII glyphs, 78-column border, 76-column panel,
# colour rules and padding arithmetic).  The two copies must be kept in step:
# a change to the look of one box must be made in the other.

# bwrap_account_name
#   Print the current account name, or the numeric uid when the uid has no
#   name.  `id -un` can print the number and still fail for an unnamed uid,
#   so its exit status is ignored and an empty result falls back to `id -u`.
bwrap_account_name() {
    local _name
    _name="$(/usr/bin/id -un 2> /dev/null || true)"
    printf '%s\n' "${_name:-$(/usr/bin/id -u)}"
}

# _bwrap_banner_panel VERTICAL CONTENT STYLE RESET
#   One left-aligned panel line (76 columns of content between the borders).
_bwrap_banner_panel() {
    local _vertical="$1" _content="$2" _style="$3" _reset="$4"
    local _padding=$((76 - ${#_content}))

    printf '%s %s%s%s%*s %s\n' \
        "${_vertical}" "${_style}" "${_content}" "${_reset}" "${_padding}" '' "${_vertical}" >&2
}

# _bwrap_banner_centered VERTICAL CONTENT STYLE RESET
#   One centred panel line.
_bwrap_banner_centered() {
    local _vertical="$1" _content="$2" _style="$3" _reset="$4"
    local _padding=$((76 - ${#_content}))
    local _left_padding=$((_padding / 2))
    local _right_padding=$((_padding - _left_padding))

    printf '%s %*s%s%s%s%*s %s\n' \
        "${_vertical}" "${_left_padding}" '' "${_style}" "${_content}" "${_reset}" \
        "${_right_padding}" '' "${_vertical}" >&2
}

# bwrap_print_banner TITLE LINE...
#   Draw a boxed message on STDERR (never /dev/tty, so it works without a
#   terminal): blank line, box, blank line.  Layout: blank panel line,
#   centred bold-red TITLE between warning markers, blank panel line, each
#   LINE left-aligned (longer than 76 columns => truncated with an ellipsis
#   so the border stays aligned), blank panel line.  UTF-8 locales get
#   box-drawing glyphs; others get ASCII.  Colour only when stderr is a tty,
#   NO_COLOR is unset and TERM is set and not "dumb".
#   Mirrors agent-account-check.sh.j2 in NSLS2/ansible -- keep in step.
bwrap_print_banner() {
    local _title="$1"
    shift
    local _top_left _top_right _bottom_left _bottom_right
    local _horizontal _vertical _warning_marker _ellipsis
    local _style_reset='' _style_bold_red='' _border='' _column _line

    if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
        _top_left='┌'
        _top_right='┐'
        _bottom_left='└'
        _bottom_right='┘'
        _horizontal='─'
        _vertical='│'
        _warning_marker='⚠'
        _ellipsis='…'
    else
        _top_left='+'
        _top_right='+'
        _bottom_left='+'
        _bottom_right='+'
        _horizontal='-'
        _vertical='|'
        _warning_marker='[!]'
        _ellipsis='...'
    fi

    if [[ -t 2 && -z "${NO_COLOR:-}" && -n "${TERM:-}" && "${TERM}" != dumb ]]; then
        _style_reset=$'\033[0m'
        _style_bold_red=$'\033[1;31m'
    fi

    # tr is byte-oriented and corrupts multibyte box-drawing characters.
    for ((_column = 0; _column < 78; _column++)); do
        _border+="${_horizontal}"
    done

    printf '\n%s%s%s\n' "${_top_left}" "${_border}" "${_top_right}" >&2
    _bwrap_banner_panel "${_vertical}" '' '' "${_style_reset}"
    _bwrap_banner_centered "${_vertical}" "${_warning_marker}  ${_title}  ${_warning_marker}" \
        "${_style_bold_red}" "${_style_reset}"
    _bwrap_banner_panel "${_vertical}" '' '' "${_style_reset}"
    for _line in "$@"; do
        if ((${#_line} > 76)); then
            _line="${_line:0:76-${#_ellipsis}}${_ellipsis}"
        fi
        _bwrap_banner_panel "${_vertical}" "${_line}" '' "${_style_reset}"
    done
    _bwrap_banner_panel "${_vertical}" '' '' "${_style_reset}"
    printf '%s%s%s\n\n' "${_bottom_left}" "${_border}" "${_bottom_right}" >&2
}

# _bwrap_first_candidate NAME
#   Set _BWRAP_CANDIDATE to the first PATH entry (exclusion-filtered by
#   N2SNSCRIPTS_TOOL_EXCLUDE_PATH, like bwrap_find_tool) called NAME that
#   exists as a path or as a symlink -- even when it is not usable.  Returns
#   1 (and leaves it empty) when there is none.
_BWRAP_CANDIDATE=""
_bwrap_first_candidate() {
    local _name="$1" _search_path="${PATH-}" _dir _candidate _has_separator
    _BWRAP_CANDIDATE=""
    if [[ -n "${N2SNSCRIPTS_TOOL_EXCLUDE_PATH:-}" ]]; then
        _bwrap_filter_path || return 1
        _search_path="${_BWRAP_FILTERED_PATH}"
    fi

    while :; do
        if [[ "${_search_path}" == *:* ]]; then
            _has_separator=1
            _dir="${_search_path%%:*}"
            _search_path="${_search_path#*:}"
        else
            _has_separator=0
            _dir="${_search_path}"
        fi
        _candidate="${_dir:-.}/${_name}"
        if [[ -e "${_candidate}" || -L "${_candidate}" ]]; then
            _BWRAP_CANDIDATE="${_candidate}"
            return 0
        fi
        [[ "${_has_separator}" -eq 1 ]] || break
    done
    return 1
}

# _bwrap_symlink_is_restricted LINK
#   Return 0 when following the symlink LINK directory by directory from "/"
#   reaches a directory that exists but cannot be entered (`-d && ! -x`)
#   before the final file.  That is what an ansible ACL `group:<g>:---` on an
#   agent package directory looks like to a denied user: the symlink in
#   /usr/local/bin is visible but its target is `-e` false because a parent
#   directory cannot be traversed.  Returns 1 otherwise (including a
#   dangling link, where the missing component's parent IS enterable).
#   The raw `readlink` target is used (no -f); a relative target is resolved
#   against the link's directory; "." and ".." are handled lexically; a
#   component that is itself a symlink is resolved with `readlink -f` (a
#   failure counts as broken); at most 10 symlink hops are followed.
_bwrap_symlink_is_restricted() {
    local _link="$1" _hops=0 _target _resolved _next _comp _i _last
    local -a _parts

    while :; do
        ((_hops += 1))
        [[ "${_hops}" -le 10 ]] || return 1
        _target="$(readlink -- "${_link}")" || return 1
        [[ -n "${_target}" ]] || return 1
        if [[ "${_target}" != /* ]]; then
            [[ "${_link}" == /* ]] || _link="${PWD}/${_link}"
            _target="${_link%/*}/${_target}"
        fi

        _resolved="/"
        IFS='/' read -ra _parts <<< "${_target}"
        _last=$((${#_parts[@]} - 1))
        for ((_i = 0; _i <= _last; _i++)); do
            _comp="${_parts[_i]}"
            case "${_comp}" in
                '' | .) continue ;;
                ..)
                    _resolved="${_resolved%/*}"
                    [[ -n "${_resolved}" ]] || _resolved="/"
                    continue
                    ;;
            esac
            _next="${_resolved%/}/${_comp}"

            if [[ "${_i}" -eq "${_last}" ]]; then
                # Final component: another symlink hop, or the end of the road.
                if [[ -L "${_next}" ]]; then
                    _link="${_next}"
                    continue 2
                fi
                return 1
            fi

            if [[ -L "${_next}" ]]; then
                _next="$(readlink -f -- "${_next}")" || return 1
            fi
            [[ -e "${_next}" ]] || return 1
            [[ -d "${_next}" ]] || return 1
            if [[ ! -x "${_next}" ]]; then
                return 0
            fi
            _resolved="${_next}"
        done
        # Target ended in "/", "." or ".." (a directory): nothing more to follow.
        return 1
    done
}

# bwrap_show_tool_help NAME
#   Finish a launcher's --help after its own text has been printed.  When the
#   tool NAME is usable, re-exec the launcher as `--exec "NAME --help"` so the
#   tool's own help comes from inside the fully built sandbox.  Otherwise say
#   so and exit 0: the wrapper help must not depend on the tool being
#   installed.  Never returns.
bwrap_show_tool_help() {
    local _name="$1" _bin
    _bin="$(bwrap_find_tool "${_name}" 2> /dev/null || true)"
    if [[ -n "${_bin}" && -x "${_bin}" ]]; then
        exec "$0" --exec "${_bin} --help"
    fi
    echo "('${_name}' is not available here, so its own --help is not shown.)"
    exit 0
}

# bwrap_resolve_tool NAME [NOT_FOUND_HINT]
#   Resolve the agent binary NAME for a launcher, setting _TOOL_BIN and
#   _TOOL_CMD (TEST_CMD, split into words, overrides the command).  When NAME
#   cannot be used, exit 1 with a message that tells three cases apart:
#     restricted     NAME is a symlink whose target directory exists but
#                    cannot be entered (the ansible ACL on shared/service
#                    accounts): the same box as the ansible account check
#                    (without the docs links), naming the tool.
#     installed incorrectly
#                    a dangling symlink, or a file that is not executable.
#     not installed  nothing called NAME in PATH; NOT_FOUND_HINT (optional)
#                    is printed on a second line.
bwrap_resolve_tool() {
    local _name="$1" _hint="${2:-}" _account _max_name _suffix

    # `command -v` falls back to a non-executable file when no executable
    # NAME exists in PATH, so a result must also pass -x to count as found.
    _TOOL_BIN="$(bwrap_find_tool "${_name}" 2> /dev/null || true)"
    if [[ -n "${_TOOL_BIN}" && -x "${_TOOL_BIN}" ]]; then
        if [[ -n "${TEST_CMD}" ]]; then
            # Split TEST_CMD into array so multi-word commands work correctly.
            read -ra _TOOL_CMD <<< "${TEST_CMD}"
        else
            _TOOL_CMD=("${_TOOL_BIN}")
        fi
        return 0
    fi

    if ! _bwrap_first_candidate "${_name}"; then
        echo "Error: '${_name}' not found in PATH." >&2
        [[ -z "${_hint}" ]] || echo "${_hint}" >&2
        exit 1
    fi

    if [[ -L "${_BWRAP_CANDIDATE}" ]] && _bwrap_symlink_is_restricted "${_BWRAP_CANDIDATE}"; then
        _account="$(bwrap_account_name)"
        # Keep the line within the 76-column panel by truncating the account
        # name with the glyph set the box will use (same logic as the ansible
        # check).
        _suffix="' is a shared/service account."
        _max_name=$((76 - 1 - ${#_suffix}))
        if ((${#_account} > _max_name)); then
            if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
                _account="${_account:0:_max_name-1}…"
            else
                _account="${_account:0:_max_name-3}..."
            fi
        fi
        bwrap_print_banner 'AI coding agents cannot be run from this account' \
            "'${_account}${_suffix}" \
            "'${_name}' is not available to this account." \
            'Log in as yourself first:  su - YOUR-USERNAME'
        exit 1
    fi

    echo "Error: '${_name}' is installed incorrectly (${_BWRAP_CANDIDATE} points to a missing file or is not executable). Ask your system administrator." >&2
    exit 1
}

# _persist_bind_wanted PATH
#   True if PATH exists, or under --dry-run --init-auth: there a real run
#   would have created the stub file and bound it, so the bind is emitted for
#   an accurate dry-run even though the stub was not created.
_persist_bind_wanted() {
    [[ -e "$1" ]] || { [[ "${INIT_AUTH:-0}" -eq 1 ]] && [[ "${DRY_RUN}" -eq 1 ]]; }
}

# _expand_leading_tilde VALUE
#   Print VALUE with only a LEADING tilde expanded:
#     "~" / "~/path"        -> $HOME / $HOME/path
#     "~user" / "~user/p"   -> that user's home (getent passwd) [+ /p]
#     anything else         -> VALUE unchanged
#   Returns 1 (printing nothing) when a ~user reference cannot be resolved.
#   A blind ${VALUE/#\~/${_HOME}} substitution turns "~alice/foo" into
#   "${HOME}alice/foo", silently corrupting the path.
_expand_leading_tilde() {
    local value="$1" _rest _user _subpath="" _uhome
    # The patterns match a literal leading tilde (SC2088 false positive).
    # shellcheck disable=SC2088
    case "${value}" in
        "~")
            printf '%s' "${_HOME}"
            ;;
        "~/"*)
            printf '%s' "${_HOME}/${value#\~/}"
            ;;
        "~"*)
            _rest="${value#\~}"
            _user="${_rest%%/*}"
            [[ "${_rest}" == */* ]] && _subpath="/${_rest#*/}"
            _uhome="$(getent passwd "${_user}" 2> /dev/null | cut -d: -f6)"
            [[ -n "${_uhome}" ]] || return 1
            printf '%s' "${_uhome}${_subpath}"
            ;;
        *)
            printf '%s' "${value}"
            ;;
    esac
}

# ── Dynamic mount helpers ────────────────────────────────────────
# _MOUNTED_PREFIXES: tracks directory trees already covered by a bwrap
# bind so we never emit duplicate (or redundant sub-path) mounts.
# Keys are canonical paths; value is always 1.
# Pre-populated with unconditional mounts in build_dynamic_tool_mounts.

# _resolve_npm_prefix
#   Set _NPM_PREFIX to the npm global prefix (`npm prefix -g`), forking npm
#   at most once per run; empty if npm is absent or the lookup fails.
#   Must NOT be called inside $(...): the cache globals would be set in the
#   subshell and lost, so npm would run again on every lookup.  Callers invoke
#   it directly and then read ${_NPM_PREFIX}.
#   `npm prefix -g` writes a log under $npm_config_cache/_logs (default
#   ~/.npm/_logs); the cache is pointed at a throwaway directory so no run,
#   including --dry-run, leaves that behind on the host.
_resolve_npm_prefix() {
    [[ "${_NPM_PREFIX_RESOLVED}" -eq 1 ]] && return 0
    _NPM_PREFIX_RESOLVED=1
    _NPM_PREFIX=""
    command -v npm > /dev/null 2>&1 || return 0

    local _npm_tmp
    _npm_tmp="$(mktemp -d 2> /dev/null || true)"
    if [[ -n "${_npm_tmp}" ]]; then
        _NPM_PREFIX="$(npm_config_cache="${_npm_tmp}" npm prefix -g 2> /dev/null || true)"
        rm -rf -- "${_npm_tmp}"
    else
        _NPM_PREFIX="$(npm prefix -g 2> /dev/null || true)"
    fi
}

# _emit_home_intermediate_dirs DIR [MODE]
#   Emit `--dir` BWRAP_ARGS for the ancestor components of DIR that live
#   under $HOME, so the eventual bind mount point exists inside the tmpfs
#   $HOME (which starts out with no subdirectories).  No-op when DIR is not
#   under $HOME.
#
#   MODE:
#     "ancestors" (default) — emit --dir for every component strictly
#                  BETWEEN $HOME and DIR; DIR itself is left out because it
#                  will be the bind mount point.
#     "inclusive" — also emit --dir for DIR itself (use when DIR is a parent
#                  directory that must exist, e.g. the directory holding a
#                  file bind, or a read-write directory bind point).
_emit_home_intermediate_dirs() {
    local dir="$1" mode="${2:-ancestors}"
    # A canonicalized bind target can sit under _HOME_CANON rather than the
    # logical _HOME when home is symlinked; match against both.
    local _home_base
    if [[ "${dir}" == "${_HOME}"/* ]]; then
        _home_base="${_HOME}"
    elif [[ -n "${_HOME_CANON}" && "${dir}" == "${_HOME_CANON}"/* ]]; then
        _home_base="${_HOME_CANON}"
    else
        return 0
    fi
    local _rel="${dir#"${_home_base}"/}"
    local _accum="${_home_base}"
    local _parts _i _last
    IFS='/' read -ra _parts <<< "${_rel}"
    if [[ "${mode}" == "inclusive" ]]; then
        _last=${#_parts[@]}
    else
        _last=$((${#_parts[@]} - 1))
    fi
    for ((_i = 0; _i < _last; _i++)); do
        _accum="${_accum}/${_parts[$_i]}"
        BWRAP_ARGS+=(--dir "${_accum}")
    done
}

# _mount_ro_dir_if_needed DIR
#   Bind-mount DIR read-only into the sandbox, unless it (or a parent
#   tree) is already registered in _MOUNTED_PREFIXES.  If the bind is
#   actually emitted, DIR is added to _MOUNTED_PREFIXES so future calls
#   with the same path or a sub-path are no-ops.
#   Handles intermediate --dir entries for paths under $HOME.
#   Calls _check_bind_safe before emitting any mount — aborts if DIR
#   resolves into a blocked path (e.g. a tool binary that symlinks into
#   ~/.ssh or a misconfigured npm prefix pointing at $HOME) or contains one
#   (e.g. an on-PATH ~/.config holding ~/.config/gh).
_mount_ro_dir_if_needed() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0

    # Check whether dir is already covered by a registered prefix.  The walk
    # tests every ancestor including "/" itself so a (theoretical) registered
    # "/" prefix would de-duplicate correctly.
    local check="${dir}"
    while :; do
        if [[ -n "${_MOUNTED_PREFIXES["${check}"]:-}" ]]; then
            return 0  # already covered
        fi
        [[ "${check}" == "/" ]] && break
        check="${check%/*}"
        [[ -z "${check}" ]] && check="/"
    done

    # Safety check before emitting the mount, judged on the canonical target:
    # DIR can be a symlinked on-PATH directory (e.g. ~/bin2 -> ~/.ssh) and
    # bwrap follows the symlink when binding.  DIR itself is still the mount
    # point, so the tool stays reachable at the path it is invoked by.
    local _dir_canon
    _dir_canon="$(readlink -f -- "${dir}" 2> /dev/null || true)"
    [[ -n "${_dir_canon}" ]] || _dir_canon="${dir}"
    _check_bind_safe "${_dir_canon}" "dynamic mount"

    # Create intermediate --dir entries for paths under $HOME (the
    # tmpfs $HOME has no subdirectories yet).  DIR is the bind mount point,
    # so only its ancestors are pre-created.
    _emit_home_intermediate_dirs "${dir}"

    BWRAP_ARGS+=(--ro-bind "${dir}" "${dir}")
    _MOUNTED_PREFIXES["${dir}"]=1
}

# resolve_and_mount_tool BINARY_PATH
#   Given an absolute path to a binary (as returned by command -v),
#   mount its on-PATH directory AND — if it is a symlink — the real
#   binary's directory.  Both are passed through _mount_ro_dir_if_needed
#   so deduplication is automatic.
#   The on-PATH bin directory is added to _EXTRA_PATH_DIRS.
#   Special case: if the real binary resolves into the npm global prefix,
#   the entire prefix tree is mounted via _mount_npm_global_prefix (which
#   subsumes the narrow bin/ dir) rather than a narrow bind.
resolve_and_mount_tool() {
    local bin_path="$1"
    [[ -n "${bin_path}" ]] || return 0

    local cmd_dir real_path npm_prefix
    cmd_dir="$(dirname "${bin_path}")"

    # Record for SANDBOX_PATH even if the mount is skipped (dir already
    # covered): the path still needs to be on PATH inside the sandbox.
    _EXTRA_PATH_DIRS+=("${cmd_dir}")

    if [[ -L "${bin_path}" ]]; then
        real_path="$(readlink -f "${bin_path}")"
        _resolve_npm_prefix
        npm_prefix="${_NPM_PREFIX}"
        if [[ -n "${npm_prefix}" ]] && [[ "${real_path}" == "${npm_prefix}"/* ]]; then
            # npm-installed: mount the whole prefix so lib/node_modules is
            # reachable.  Also mount the on-PATH directory holding the symlink
            # (e.g. ~/.local/bin/claude -> npm prefix): otherwise the path the
            # tool is invoked by does not exist inside the sandbox.
            _mount_ro_dir_if_needed "${cmd_dir}"
            _mount_npm_global_prefix "${npm_prefix}"
            return 0
        fi
        _mount_ro_dir_if_needed "${cmd_dir}"
        _mount_ro_dir_if_needed "$(dirname "${real_path}")"
    else
        # Non-symlink binary: mount its directory.  _mount_ro_dir_if_needed
        # de-duplicates internally, so no prior prefix check is needed here.
        _mount_ro_dir_if_needed "${cmd_dir}"
    fi
}

# _mount_npm_global_prefix [PREFIX]
#   Mount the entire npm global prefix tree read-only and add its bin/
#   subdirectory to _EXTRA_PATH_DIRS.  PREFIX defaults to `npm prefix -g`.
#   Aborts if the resolved prefix is a blocked path — e.g. when npm has
#   been misconfigured with `npm config set prefix ~` (a common mistake
#   documented in npm's own install guide), which would expose the entire
#   home directory read-only inside the sandbox.
_mount_npm_global_prefix() {
    local npm_prefix="${1:-}"
    if [[ -z "${npm_prefix}" ]]; then
        _resolve_npm_prefix
        npm_prefix="${_NPM_PREFIX}"
    fi
    [[ -n "${npm_prefix}" ]] && [[ -d "${npm_prefix}" ]] || return 0

    # Canonicalise before the safety check so symlinks in the prefix path
    # are resolved (npm itself may return a non-canonical path on some systems).
    local npm_prefix_canon
    npm_prefix_canon="$(readlink -f "${npm_prefix}" 2> /dev/null || echo "${npm_prefix}")"
    _check_bind_safe "${npm_prefix_canon}" "npm global prefix"

    _mount_ro_dir_if_needed "${npm_prefix_canon}"
    _EXTRA_PATH_DIRS+=("${npm_prefix_canon}/bin")
}

# ── Git include parser ───────────────────────────────────────────

# _bwrap_git_decode_value RAW
#   Decode a git config value the way git does, so a quoted or commented
#   include path is recognised.  Result in _BWRAP_GIT_VALUE; returns 1 when the
#   value is not valid (unterminated quote, unknown escape).  Rules: leading
#   and trailing whitespace is dropped; a double quote toggles quoting; inside
#   or outside quotes the escapes \n \t \b \" \\ are decoded; outside quotes
#   an unescaped '#' or ';' starts a comment.  A trailing backslash (git's line
#   continuation) is not supported: such a value is treated as invalid and the
#   include is skipped.
_bwrap_git_decode_value() {
    local raw="$1" out="" c next i n=${#1} quoted=0 pending=""
    _BWRAP_GIT_VALUE=""
    for ((i = 0; i < n; i++)); do
        c="${raw:i:1}"
        if [[ "${c}" == "\\" ]]; then
            i=$((i + 1))
            [[ ${i} -lt ${n} ]] || return 1
            next="${raw:i:1}"
            case "${next}" in
                n) c=$'\n' ;;
                t) c=$'\t' ;;
                b) c=$'\b' ;;
                '"' | "\\") c="${next}" ;;
                *) return 1 ;;
            esac
            out+="${pending}${c}"
            pending=""
        elif [[ "${c}" == '"' ]]; then
            quoted=$((1 - quoted))
        elif [[ ${quoted} -eq 0 && ("${c}" == "#" || "${c}" == ";")   ]]; then
            break
        elif [[ ${quoted} -eq 0 && ("${c}" == " " || "${c}" == $'\t')   ]]; then
            # Whitespace outside quotes is kept only if more text follows.
            [[ -n "${out}" || -n "${pending}" ]] && pending+=" "
        else
            out+="${pending}${c}"
            pending=""
        fi
    done
    [[ ${quoted} -eq 0 ]] || return 1
    _BWRAP_GIT_VALUE="${out}"
}

# parse_git_includes CONFIG_FILE [DEPTH]
#   Record every [include] / [includeIf] "path =" target of CONFIG_FILE and
#   follow the included files recursively (DEPTH is the nesting level of
#   CONFIG_FILE: 0 for ~/.gitconfig and the XDG config; at most
#   _GIT_INCLUDE_MAX_DEPTH levels of includes are followed, like git).
#   CONFIG_FILE is the path as git opened it (not normalised): relative
#   includes resolve against its directory, and the kernel resolves any ".."
#   in it, exactly as for git.  A file is parsed once per path as opened, and
#   nesting stops at the depth limit, so include loops terminate; a canonical
#   path in a blocked location is never read (build_git_mounts refuses it at
#   mount time).  Conditions of
#   [includeIf] are not evaluated: every candidate is recorded.
parse_git_includes() {
    local config_file="$1" depth="${2:-0}" line
    [[ -f "${config_file}" && -r "${config_file}" ]] || return 0
    [[ "${depth}" -lt "${_GIT_INCLUDE_MAX_DEPTH}" ]] || return 0

    [[ -z "${_GIT_INCLUDE_PARSED["${config_file}"]:-}" ]] || return 0
    _GIT_INCLUDE_PARSED["${config_file}"]=1

    # Git resolves relative include paths relative to the location of
    # the config file (the symlink path, NOT the resolved target).
    local config_dir="${config_file%/*}"

    # Extract path values from [include] and [includeIf "..."] sections.
    # Matches lines like:  path = /some/path  or  path = ~/relative
    # Pure bash — no grep/sed/xargs subprocesses.
    #
    # `path` is only an include directive inside an include section: git's
    # parser is section-scoped, and a `path =` key elsewhere (for example
    # [difftool "x"] path = ...) must not be mounted, nor abort the launcher
    # when it points into a blocked location.  Section names are
    # case-insensitive; a key may follow the header on the same line.
    local _section_re='^[[:space:]]*\[[[:space:]]*([A-Za-z0-9.-]+)([[:space:]]+"([^"\\]|\\.)*")?[[:space:]]*\](.*)$'
    local _section_name in_include=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ${_section_re} ]]; then
            _section_name="${BASH_REMATCH[1],,}"
            line="${BASH_REMATCH[4]}"
            if [[ "${_section_name}" == "include" || "${_section_name}" == "includeif" ]]; then
                in_include=1
            else
                in_include=0
            fi
        fi
        [[ "${in_include}" -eq 1 ]] || continue

        # git variable names are case-insensitive.  The value is decoded the
        # way git does (quotes, escapes, trailing comments) before anything is
        # derived from it; an undecodable value is skipped.
        [[ "${line}" =~ ^[[:space:]]*[Pp][Aa][Tt][Hh][[:space:]]*=[[:space:]]*(.*) ]] || continue
        _bwrap_git_decode_value "${BASH_REMATCH[1]}" || continue
        local path_val="${_BWRAP_GIT_VALUE}"
        [[ -z "${path_val}" ]] && continue

        # Expand a leading ~ or ~user (git does both); skip the include when
        # ~user cannot be resolved rather than corrupting the path.
        path_val="$(_expand_leading_tilde "${path_val}")" || continue

        # Resolve relative paths (relative to the config file's directory)
        if [[ "${path_val}" != /* ]]; then
            path_val="${config_dir}/${path_val}"
        fi

        # Canonicalize ALWAYS (realpath), not only when the last component is
        # a symlink: a symlinked parent directory would otherwise hide the real
        # target from _check_path_safe.  The path git itself will open (and
        # therefore where the sandbox must provide the file) is worked out by
        # _bwrap_include_visible_path, which also reports the symlinked
        # directories before a ".." that build_git_mounts must recreate.
        local visible resolved predirs links
        _bwrap_include_visible_path "${path_val}"
        visible="${_BWRAP_INC_VISIBLE}"
        predirs="${_BWRAP_INC_PREDIRS}"
        links="${_BWRAP_INC_LINKS}"
        resolved="$(readlink -f "${path_val}" 2> /dev/null || true)"
        [[ -n "${resolved}" ]] || resolved="${visible}"

        # Deduplicate on the raw path as written (see _GIT_INCLUDE_SEEN)
        if [[ -e "${resolved}" ]] && [[ -z "${_GIT_INCLUDE_SEEN["${path_val}"]:-}" ]]; then
            _GIT_INCLUDE_SEEN["${path_val}"]=1
            GIT_INCLUDE_PATHS+=("${resolved}")
            GIT_INCLUDE_VISIBLE+=("${visible}")
            GIT_INCLUDE_PREDIRS+=("${predirs}")
            GIT_INCLUDE_LINKS+=("${links}")
            GIT_INCLUDE_RAW+=("${path_val}")
            # Nested includes: follow the included file unless it is blocked.
            if [[ -f "${resolved}" ]] && ! _bwrap_path_blocked "${resolved}"; then
                parse_git_includes "${path_val}" "$((depth + 1))"
            fi
        fi
    done < "${config_file}"
}

# Parse the standard git config files for include directives.
parse_all_git_includes() {
    if [[ -f "${_HOME}/.gitconfig" ]]; then
        parse_git_includes "${_HOME}/.gitconfig"
    fi
    if [[ -f "${XDG_CONFIG_HOME}/git/config" ]]; then
        # A config that resolves into a blocked location is not mounted
        # (see _bwrap_mount_xdg_git_files), so its includes are not followed.
        local _xdg_cfg_real
        _xdg_cfg_real="$(readlink -f "${XDG_CONFIG_HOME}/git/config" 2> /dev/null || true)"
        if [[ -z "${_xdg_cfg_real}" ]] || ! _bwrap_path_blocked "${_xdg_cfg_real}"; then
            parse_git_includes "${XDG_CONFIG_HOME}/git/config"
        fi
    fi
}

# ── Env var passthrough helper ───────────────────────────────────

# pass_through_if_set NAME
#   Forward the host variable NAME into the sandbox when it is non-empty.  The
#   value goes into SANDBOX_ENV (bwrap's environment), not onto bwrap's command
#   line.  A later `--setenv NAME` in BWRAP_ARGS still overrides it.
pass_through_if_set() {
    local var_name="$1"
    local var_val="${!var_name:-}"
    if [[ -n "${var_val}" ]]; then
        SANDBOX_ENV+=("${var_name}=${var_val}")
    fi
}

# forward_env_by_prefix PREFIX
#   Forward every exported environment variable whose name starts with PREFIX
#   (as NAME=VALUE entries in SANDBOX_ENV, like pass_through_if_set).  Uses
#   `while IFS= read -r` over `compgen -e`, so names are never word-split.
#   Values are passed as-is; print_dry_run redacts names that match
#   _is_secret_env_name.
#
#   Example:
#     forward_env_by_prefix GH_TOKEN_    # GH_TOKEN_NSLS2, GH_TOKEN_PERSONAL, ...
forward_env_by_prefix() {
    local _prefix="$1" _key
    while IFS= read -r _key; do
        if [[ "${_key}" == "${_prefix}"* ]]; then
            SANDBOX_ENV+=("${_key}=${!_key}")
        fi
    done < <(compgen -e)
}

# ── Path safety validation ───────────────────────────────────────

# _is_prefix_of A B
#   Returns 0 (true) if B == A or B starts with A/ (A is a parent of B).
#   Special-cases A="/" because the pattern "${A}/"* would become "//*"
#   which never matches any real path.
_is_prefix_of() {
    local a="$1" b="$2"
    # a="/" matches every absolute path; otherwise b must equal a or sit
    # directly beneath it (a/...).
    [[ "${a}" == "/" || "${b}" == "${a}" || "${b}" == "${a}/"* ]]
}

# _bwrap_load_blocked_prefixes
#   Fill the global array _BWRAP_BLOCKED_LIST with the sensitive locations
#   that are never mounted (see _check_path_safe for the rationale).
#   XDG_DATA_HOME is set by resolve_common_paths, which is always called
#   before any function that uses this list.
#   Callers compare CANONICAL paths, so each entry is listed both as written
#   and at its resolved target (readlink -f) when that differs: with
#   ~/.config/git -> ~/dotfiles/git the credentials file is matched as
#   ~/dotfiles/git/credentials too, and a symlinked ~/.git-credentials or ~/.ssh
#   is matched at its target.  readlink -f resolves a missing last component
#   against its (resolved) parent, so an entry that does not exist yet is
#   covered as well.  The list is built once per HOME/XDG combination.
_BWRAP_BLOCKED_LIST=()
_BWRAP_BLOCKED_KEY=""
_bwrap_load_blocked_prefixes() {
    local _key="${_HOME}|${XDG_CONFIG_HOME:-}|${XDG_DATA_HOME:-}|${XDG_RUNTIME_DIR:-}|${N2C_STATE_DIR:-}"
    [[ "${_key}" == "${_BWRAP_BLOCKED_KEY}" && ${#_BWRAP_BLOCKED_LIST[@]} -gt 0 ]] && return 0
    local -a _literal=(
        # SSH / GPG / cloud keys
        "${_HOME}/.ssh"
        "${_HOME}/.gnupg"
        "${_HOME}/.aws"
        "${_HOME}/.kube"
        "${_HOME}/.docker"
        # Package-manager credentials
        "${_HOME}/.netrc"
        "${_HOME}/.pypirc"
        "${_HOME}/.rattler"
        "${_HOME}/.yarnrc"
        "${_HOME}/.yarnrc.yml"
        "${_HOME}/.yarn"
        "${XDG_DATA_HOME}/uv/credentials"
        # Password managers
        "${_HOME}/.password-store"   # pass / gopass encrypted secret store
        "${_HOME}/.config/1Password" # 1Password CLI session/config
        "${_HOME}/.config/op"        # 1Password CLI (alternate path)
        # GitHub CLI tokens
        "${_HOME}/.config/gh"
        # n2c-token session: the MSAL cache holds the refresh token, which can
        # mint access tokens for every NSLS-II API.  Only the access-token files
        # are ever mounted (see build_n2c_token_mounts).
        "$(_n2c_state_dir)"
        # Default stores of git's "store" credential helper (plaintext).  Listing
        # them here makes the working-directory / --ro-path / --rw-path checks
        # refuse them, and refuse a directory that contains an existing one
        # (for example launching from ~/.config/git).
        "${_HOME}/.git-credentials"
        "${XDG_CONFIG_HOME}/git/credentials"
        # System
        "/root"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/sudoers.d"
    )
    local _e _r
    _BWRAP_BLOCKED_LIST=()
    for _e in "${_literal[@]}"; do
        _BWRAP_BLOCKED_LIST+=("${_e}")
        _r="$(readlink -f -- "${_e}" 2> /dev/null || true)"
        if [[ -n "${_r}" && "${_r}" != "${_e}" ]]; then
            _BWRAP_BLOCKED_LIST+=("${_r}")
        fi
    done
    _BWRAP_BLOCKED_KEY="${_key}"
}

# _bwrap_path_blocked CANON
#   Non-exiting form of the check below: return 0 (true) when the canonical
#   path CANON is blocked, 1 otherwise.  On a hit, _BWRAP_BLOCKED_KIND is
#   "home" (CANON is $HOME or an ancestor of it) or "prefix" (CANON is inside
#   the sensitive subtree _BWRAP_BLOCKED_PREFIX).  Used directly where a
#   blocked entry is skipped with a warning instead of aborting the launcher,
#   and by _check_path_safe, which prints the error and exits.
_bwrap_path_blocked() {
    local canon="$1"
    _BWRAP_BLOCKED_KIND=""
    _BWRAP_BLOCKED_PREFIX=""

    # Reject if canon IS $HOME or is a directory that contains $HOME
    # (i.e. /, /home, the username's parent dir, etc.).
    # "_is_prefix_of canon _HOME" means: canon is a prefix of _HOME.  The
    # canonical home is checked too: with a symlinked home (/home/u ->
    # /nfs/home/u) a canonical candidate /nfs/home/u is not a prefix of _HOME.
    if _is_prefix_of "${canon}" "${_HOME}" ||
        { [[ -n "${_HOME_CANON}" ]] && _is_prefix_of "${canon}" "${_HOME_CANON}"; }; then
        _BWRAP_BLOCKED_KIND="home"
        return 0
    fi

    local _blocked_prefix
    _bwrap_load_blocked_prefixes
    for _blocked_prefix in "${_BWRAP_BLOCKED_LIST[@]}"; do
        if _is_prefix_of "${_blocked_prefix}" "${canon}"; then
            _BWRAP_BLOCKED_KIND="prefix"
            _BWRAP_BLOCKED_PREFIX="${_blocked_prefix}"
            return 0
        fi
    done
    return 1
}

# _check_path_safe CANON CONTEXT
#   Assert that the already-resolved canonical path CANON is safe to mount
#   into the sandbox.  Exits 1 with a descriptive error if it is not.
#
#   This only asks whether CANON is itself blocked.  Callers that bind a path
#   into the sandbox should use _check_bind_safe, which also refuses a
#   directory that CONTAINS a blocked location.
#
#   CANON   : absolute, symlink-free path (output of readlink -f).
#   CONTEXT : short label used in error messages, e.g. "--ro-path",
#             "--rw-path", or "working directory".
#
#   Must be called AFTER resolve_common_paths so that XDG_DATA_HOME is set.
#   All build_* and validate_* functions satisfy this — they are called from
#   main() after resolve_common_paths.
#
#   Blocked conditions (all checked against the canonical path):
#     - CANON is $HOME or an ancestor of $HOME (/, /home, etc.) — would
#       expose the entire home tree inside the sandbox.
#     - CANON is inside any of the following sensitive subtrees:
#
#       SSH / GPG / cloud keys
#         ~/.ssh/          private keys and known_hosts
#         ~/.gnupg/        GPG private keys and keyrings
#         ~/.aws/          AWS credentials and config
#         ~/.kube/         Kubernetes cluster credentials (tokens, certs)
#         ~/.docker/       Docker registry auth (config.json with tokens)
#
#       Package-manager credentials
#         ~/.netrc         cleartext credentials for pip/git/curl/wget
#                          (used by pip, uv, curl, git-credential-netrc)
#         ~/.pypirc        twine/flit PyPI upload tokens and passwords
#         ~/.rattler/      pixi/rattler conda channel auth tokens
#                          (default path: ~/.rattler/credentials.json;
#                           can be overridden with RATTLER_AUTH_FILE)
#         ~/.yarnrc        yarn classic (v1) registry auth tokens
#         ~/.yarnrc.yml    yarn berry (v2+) per-user registry auth tokens
#         ~/.yarn/         yarn berry global config directory
#         $XDG_DATA_HOME/uv/credentials
#                          uv per-index auth tokens (`uv auth login`);
#                          default path ~/.local/share/uv/credentials
#                          (confirmed via `uv auth dir`)
#
#       Password managers
#         ~/.password-store    pass/gopass GPG-encrypted secret store
#         ~/.config/1Password  1Password CLI session and config
#         ~/.config/op         1Password CLI (alternate config path)
#
#       GitHub CLI
#         ~/.config/gh/    GitHub CLI auth tokens (hosts.yml, etc.)
#                          Note: bwcopilot intentionally mounts hosts.yml
#                          from this directory via build_gh_auth_mount,
#                          which bypasses this check by design — the block
#                          prevents USER-supplied paths (--ro-path) from
#                          reaching gh credentials in other wrappers.
#
#       System
#         /root            root's home directory
#         /etc/shadow      system password hashes
#         /etc/sudoers     sudo policy
#         /etc/sudoers.d/  sudo policy fragments
#
#   Does NOT check existence — the caller is responsible for that.
_check_path_safe() {
    local canon="$1"
    local context="$2"

    if _bwrap_path_blocked "${canon}"; then
        if [[ "${_BWRAP_BLOCKED_KIND}" == "home" ]]; then
            echo "Error: ${context} '${canon}' is \$HOME or an ancestor of \$HOME." >&2
            echo "       Refusing to mount — this would expose the entire home tree." >&2
        else
            echo "Error: ${context} '${canon}' is inside the blocked path '${_BWRAP_BLOCKED_PREFIX}'." >&2
            echo "       Refusing to mount." >&2
        fi
        exit 1
    fi
}

# EXTRA_BLOCKED_DIRS: launcher-specific locations that a mounted directory
# must not CONTAIN (they may be entered by other means, e.g. mounted file by
# file).  bwopencode2 sets it to its config directory, whose service.json is
# deliberately never mounted.  Existing paths only.
EXTRA_BLOCKED_DIRS=()

# _bwrap_contains_blocked CANON
#   Return 0 (true) when the canonical path CANON is, or is an ancestor of, a
#   blocked location that exists on disk (anything in the blocked list, a
#   symlink's target included, or an EXTRA_BLOCKED_DIRS entry); the offending
#   entry is left in _BWRAP_CONTAINED_BLOCKED.  Blocked locations that do not
#   exist are ignored.  Binding such a directory would expose the blocked
#   location through the parent mount (e.g. running from ~/.config would bind
#   ~/.config/gh read-write).  Does NOT check whether CANON itself is inside a
#   blocked tree: use _bwrap_bind_blocked or _check_bind_safe for that.
_bwrap_contains_blocked() {
    local canon="$1" _b _t
    _BWRAP_CONTAINED_BLOCKED=""
    _bwrap_load_blocked_prefixes
    for _b in "${_BWRAP_BLOCKED_LIST[@]}" "${EXTRA_BLOCKED_DIRS[@]+"${EXTRA_BLOCKED_DIRS[@]}"}"; do
        [[ -n "${_b}" ]] || continue
        [[ -e "${_b}" || -L "${_b}" ]] || continue
        _t="$(readlink -f -- "${_b}" 2> /dev/null || true)"
        if _is_prefix_of "${canon}" "${_b}" || { [[ -n "${_t}" ]] && _is_prefix_of "${canon}" "${_t}"; }; then
            _BWRAP_CONTAINED_BLOCKED="${_b}"
            return 0
        fi
    done
    return 1
}

# _bwrap_bind_blocked CANON
#   Non-exiting safety check for a path about to be bind-mounted: return 0
#   (true) when CANON is blocked (_bwrap_path_blocked) OR contains a blocked
#   location (_bwrap_contains_blocked).  Use where an unsafe candidate is
#   skipped with a warning instead of aborting the launcher.
_bwrap_bind_blocked() {
    _bwrap_path_blocked "$1" || _bwrap_contains_blocked "$1"
}

# _check_bind_safe CANON CONTEXT
#   The safety check for ANY path about to be bind-mounted: exit 1 with an
#   error when CANON is blocked (see _check_path_safe) or, for a directory
#   bound whole, contains a blocked location.  Use this at every bind-mount
#   site rather than _check_path_safe alone, which does not notice a
#   directory that contains a blocked path.
#
#   _check_path_safe on its own is for paths that are validated but not bound
#   whole: a tool-home directory that only has selected subpaths mounted
#   (see _check_dir_safe), or a symlink target about to be resolved.
_check_bind_safe() {
    local canon="$1" context="$2"
    _check_path_safe "${canon}" "${context}"
    if _bwrap_contains_blocked "${canon}"; then
        echo "Error: ${context} '${canon}' contains the blocked path '${_BWRAP_CONTAINED_BLOCKED}'. Refusing to mount." >&2
        exit 1
    fi
}

# _check_dir_safe PATH CONTEXT
#   Convenience wrapper around _check_path_safe for directory paths that may
#   or may not exist yet (e.g. tool-home dirs created later by ensure_host_dirs).
#
#   If PATH exists on the host, it is canonicalized via readlink -f first so
#   that symlinks in the path are resolved before the safety check.  If it does
#   not yet exist, the raw value is checked as-is; this still catches obviously
#   dangerous literals like $HOME, /root, or ~/.ssh even before the directory
#   is created.
#
#   PATH    : absolute path to check.
#   CONTEXT : short label for error messages (e.g. "PIXI_HOME", "CLAUDE_HOME").
_check_dir_safe() {
    local path="$1"
    local context="$2"
    local canon
    if [[ -e "${path}" ]]; then
        canon="$(readlink -f "${path}" 2> /dev/null || echo "${path}")"
    else
        canon="${path}"
    fi
    _check_path_safe "${canon}" "${context}"
}

# _bwrap_canonicalize_safe PATH CONTEXT
#   Canonicalize PATH with readlink -f (falls back to PATH itself when
#   readlink fails or PATH does not exist) and run _check_bind_safe on the
#   canonical result.  ALWAYS canonicalizes, so a symlinked parent directory
#   cannot hide a blocked target (bwrap's --ro-bind follows the symlink and
#   would mount the real file).
#
#   Pass "root" as MODE for a directory that is validated but NOT bound whole
#   (a tool-home directory that only has selected subpaths mounted): then only
#   _check_path_safe runs, as a contained blocked location is not exposed.
#
#   The canonical path is returned in the global _BWRAP_CANON, NOT on stdout:
#   the checks call exit 1, and inside $(...) that would only leave the
#   subshell and let the launcher carry on.
_bwrap_canonicalize_safe() {
    local path="$1"
    local context="$2"
    local mode="${3:-bind}"
    _BWRAP_CANON="$(readlink -f "${path}" 2> /dev/null || true)"
    [[ -n "${_BWRAP_CANON}" ]] || _BWRAP_CANON="${path}"
    if [[ "${mode}" == "root" ]]; then
        _check_path_safe "${_BWRAP_CANON}" "${context}"
    else
        _check_bind_safe "${_BWRAP_CANON}" "${context}"
    fi
}

# _bwrap_include_visible_path RAW
#   Work out where the sandbox must provide a git include so that git can open
#   the path it computed (RAW, not normalised).  Sets:
#     _BWRAP_INC_VISIBLE  the path as the kernel resolves it on the host:
#                         every component up to the LAST ".." is resolved
#                         physically (a symlinked directory is replaced by its
#                         target, so ".." means the parent of the TARGET, as
#                         on the host); components after it are kept as named
#     _BWRAP_INC_PREDIRS  newline-separated directories the kernel walks
#                         before the last ".." (they hold no data; they only
#                         have to exist in the sandbox)
#     _BWRAP_INC_LINKS    newline-separated symlinked directories met before
#                         the last ".."; the sandbox must provide them as
#                         symlinks (build_git_mounts recreates them) for the
#                         kernel to resolve ".." the same way there
#   Without a symlinked directory before a ".." this equals the lexical
#   normalisation of RAW and _BWRAP_INC_LINKS is empty.
_bwrap_include_visible_path() {
    local raw="$1" part cand phys="/" tail="" i last_dotdot=-1
    local -a parts=()
    local IFS=/
    _BWRAP_INC_PREDIRS=""
    _BWRAP_INC_LINKS=""
    read -r -a parts <<< "${raw}"
    for ((i = 0; i < ${#parts[@]}; i++)); do
        [[ "${parts[i]}" == ".." ]] && last_dotdot=${i}
    done
    for ((i = 0; i < ${#parts[@]}; i++)); do
        part="${parts[i]}"
        case "${part}" in
            '' | .) ;;
            ..)
                # phys is physical, so its parent is the physical parent
                [[ "${phys}" == "/" ]] || phys="${phys%/*}"
                [[ -n "${phys}" ]] || phys="/"
                ;;
            *)
                if [[ "${i}" -lt "${last_dotdot}" ]]; then
                    cand="${phys%/}/${part}"
                    if [[ -L "${cand}" ]]; then
                        _BWRAP_INC_LINKS+="${cand}"$'\n'
                        phys="$(readlink -f -- "${cand}" 2> /dev/null || true)"
                        [[ -n "${phys}" ]] || phys="${cand}"
                    else
                        phys="${cand}"
                    fi
                    _BWRAP_INC_PREDIRS+="${phys}"$'\n'
                else
                    tail+="/${part}"
                fi
                ;;
        esac
    done
    _BWRAP_INC_VISIBLE="${phys%/}${tail}"
}

# _bwrap_include_lexical_path RAW
#   Work out where git looks for an include in a sandbox where every symlinked
#   directory of RAW exists as a plain directory (so ".." is collapsed
#   lexically).  Sets:
#     _BWRAP_INC_LEXICAL  RAW normalised lexically
#     _BWRAP_INC_LEXDIRS  newline-separated directories the kernel walks
#                         before the last ".."
_bwrap_include_lexical_path() {
    local raw="$1" part cur="" i last_dotdot=-1
    local -a parts=()
    local IFS=/
    _BWRAP_INC_LEXDIRS=""
    read -r -a parts <<< "${raw}"
    for ((i = 0; i < ${#parts[@]}; i++)); do
        [[ "${parts[i]}" == ".." ]] && last_dotdot=${i}
    done
    for ((i = 0; i < ${#parts[@]}; i++)); do
        part="${parts[i]}"
        case "${part}" in
            '' | .) ;;
            ..) cur="${cur%/*}" ;;
            *)
                cur+="/${part}"
                [[ "${i}" -lt "${last_dotdot}" ]] && _BWRAP_INC_LEXDIRS+="${cur}"$'\n'
                ;;
        esac
    done
    _BWRAP_INC_LEXICAL="${cur:-/}"
}

# validate_extra_path RAW_PATH MODE
#   Validate a user-supplied path (from --ro-path or --rw-path) before
#   mounting it into the sandbox.
#
#   RAW_PATH : path string supplied by the user; may contain a leading ~/
#              or be relative — resolved via tilde expansion + readlink -f.
#   MODE     : "ro" or "rw" — used only in error messages.
#
#   On success: echoes the canonical resolved path to stdout.
#   On failure: prints an error to stderr and exits 1.
#
#   Steps:
#     1. Expand a leading ~ or ~user, then resolve to a canonical path via
#        readlink -f.
#     2. Verify the path exists on the host.
#     3. Delegate safety checks to _check_path_safe.
validate_extra_path() {
    local raw_path="$1"
    local mode="$2"

    # Expand a leading ~ or ~user (readlink -f won't do this for us).
    local expanded_path
    if ! expanded_path="$(_expand_leading_tilde "${raw_path}")"; then
        echo "Error: --${mode}-path '${raw_path}': cannot resolve the '~user' home directory." >&2
        exit 1
    fi

    # Resolve to canonical path (follows symlinks, removes . and ..).
    local canon
    canon="$(readlink -f "${expanded_path}" 2> /dev/null || true)"

    # ── Existence check ──────────────────────────────────────────
    if [[ -z "${canon}" ]] || ! [[ -e "${canon}" ]]; then
        echo "Error: --${mode}-path '${raw_path}': path does not exist." >&2
        exit 1
    fi

    # ── Safety check ─────────────────────────────────────────────
    _check_bind_safe "${canon}" "--${mode}-path"

    # All checks passed — return the canonical path.
    echo "${canon}"
}

# ── Extra user path mounts ───────────────────────────────────────

# build_extra_path_mounts
#   Mount all paths accumulated in EXTRA_RO_PATHS and EXTRA_RW_PATHS.
#   Each path is validated by validate_extra_path before mounting.
#
#   Binds are emitted ANCESTORS-FIRST across both modes: bwrap applies binds
#   in order and the last one covering a mount point wins, so a path nested
#   under another is emitted after its parent and overrides it.  This lets
#       --rw-path DIR --ro-path DIR/sub
#   keep DIR writable but DIR/sub read-only (and the reverse: a read-only
#   tree with one writable subdirectory).  A path given as both --ro-path and
#   --rw-path is rejected.
#
#   User paths are emitted DIRECTLY, not through the _MOUNTED_PREFIXES dedup
#   used for automatic mounts: that dedup would skip a child "covered" by a
#   parent bind (defeating the nesting, or a read-only subdirectory of the
#   read-write working directory), and would silently drop any path under a
#   pre-registered prefix such as /tmp, which is a tmpfs in the sandbox.
#
#   Must be called AFTER the automatic mount steps (working directory, tools,
#   system, home) so an explicit path overrides them, and AFTER
#   build_home_tmpfs (which creates the $HOME tmpfs that intermediate --dir
#   entries populate).
build_extra_path_mounts() {
    # Guarded expansion (not ${#arr[@]}): empty-array expansions are fragile
    # under `set -u` on bash < 4.4.
    [[ -z "${EXTRA_RO_PATHS[*]+x}${EXTRA_RW_PATHS[*]+x}" ]] && return 0

    local _raw_path _canon _mode
    local -A _mode_of=()

    # Validate everything up front.  validate_extra_path runs in a command
    # substitution, where its `exit 1` only leaves the subshell, so the
    # failure is propagated explicitly.
    for _raw_path in "${EXTRA_RO_PATHS[@]+"${EXTRA_RO_PATHS[@]}"}"; do
        _canon="$(validate_extra_path "${_raw_path}" "ro")" || exit 1
        _mode_of["${_canon}"]="ro"
    done
    for _raw_path in "${EXTRA_RW_PATHS[@]+"${EXTRA_RW_PATHS[@]}"}"; do
        _canon="$(validate_extra_path "${_raw_path}" "rw")" || exit 1
        if [[ "${_mode_of["${_canon}"]:-}" == "ro" ]]; then
            echo "Error: '${_canon}' was given as both --ro-path and --rw-path." >&2
            exit 1
        fi
        _mode_of["${_canon}"]="rw"
    done

    # Ancestors first: an ancestor is a byte prefix of its descendants, so a
    # plain LC_ALL=C sort orders it before them.  NUL-delimited end to end so a
    # path containing a newline stays one entry (mapfile -d needs bash 4.4, so
    # read in a loop).
    local -a _sorted=()
    local _sorted_path
    while IFS= read -r -d '' _sorted_path; do
        _sorted+=("${_sorted_path}")
    done < <(printf '%s\0' "${!_mode_of[@]}" | LC_ALL=C sort -z)

    # Destinations of every bind emitted so far.  A path with a bound
    # ancestor needs no intermediate --dir entries (the ancestor's host tree
    # already contains it), and a --dir there would clobber that bind.
    local -A _bound_dests=()
    local _bi=0 _bflag
    while [[ ${_bi} -lt ${#BWRAP_ARGS[@]} ]]; do
        _bflag="${BWRAP_ARGS[${_bi}]}"
        _bwrap_flag_arity "${_bflag}"
        case "${_bflag}" in
            --bind | --bind-try | --ro-bind | --ro-bind-try | --dev-bind | --dev-bind-try)
                _bound_dests["${BWRAP_ARGS[$((_bi + 2))]}"]=1
                ;;
        esac
        _bi=$((_bi + 1 + _BWRAP_FLAG_ARITY))
    done

    local _anc _has_bound_ancestor
    for _canon in "${_sorted[@]}"; do
        _mode="${_mode_of["${_canon}"]}"

        _has_bound_ancestor=0
        _anc="${_canon%/*}"
        [[ -n "${_anc}" ]] || _anc="/"
        while :; do
            if [[ -n "${_bound_dests["${_anc}"]:-}" ]]; then
                _has_bound_ancestor=1
                break
            fi
            [[ "${_anc}" == "/" ]] && break
            _anc="${_anc%/*}"
            [[ -n "${_anc}" ]] || _anc="/"
        done

        # Pre-create the intermediate --dir chain under $HOME.  A read-write
        # directory includes the target itself (the --bind lands on top of
        # that --dir); a read-only directory is its own mount point; a file
        # needs its parent chain.
        if [[ ${_has_bound_ancestor} -eq 0 ]]; then
            if [[ -d "${_canon}" && "${_mode}" == "rw" ]]; then
                _emit_home_intermediate_dirs "${_canon}" inclusive
            elif [[ -d "${_canon}" ]]; then
                _emit_home_intermediate_dirs "${_canon}"
            else
                _emit_home_intermediate_dirs "${_canon%/*}" inclusive
            fi
        fi

        if [[ "${_mode}" == "ro" ]]; then
            BWRAP_ARGS+=(--ro-bind "${_canon}" "${_canon}")
        else
            BWRAP_ARGS+=(--bind "${_canon}" "${_canon}")
        fi
        _bound_dests["${_canon}"]=1
    done
}

# ── N2C access tokens ────────────────────────────────────────────

# n2c-token (NSLS2/ansible roles/base) signs a user in once on the host and
# keeps a short-lived access token per API in
#   ${N2SN_CREDS_DIR:-${XDG_RUNTIME_DIR:-/run/user/UID}/nsls2/creds}/NAME/token
# It keeps the MSAL cache, which holds the refresh token, in
#   ${N2C_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/UID}/nsls2/n2c}
# These helpers use the same defaults.  Only token files are ever mounted.
_n2c_runtime_dir() {
    printf '%s\n' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
}

# _n2c_strip_slashes PATH
#   Print PATH without trailing slashes ("/" stays "/").  A trailing slash makes
#   `[[ -L ... ]]` follow the link, so a symlink given as "link/" would pass the
#   symlink checks below.
_n2c_strip_slashes() {
    local p="$1"
    while [[ "${p}" == */ && "${p}" != "/" ]]; do
        p="${p%/}"
    done
    printf '%s\n' "${p}"
}

_n2c_creds_root() {
    _n2c_strip_slashes "${N2SN_CREDS_DIR:-$(_n2c_runtime_dir)/nsls2/creds}"
}

_n2c_state_dir() {
    _n2c_strip_slashes "${N2C_STATE_DIR:-$(_n2c_runtime_dir)/nsls2/n2c}"
}

# add_n2c_token NAME
#   Record a --n2c-token argument.  NAME is "all" or a token name: lowercase
#   letters, digits and "-", starting and ending with a letter or digit.
add_n2c_token() {
    local name="$1"
    local name_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    if [[ ! "${name}" =~ ${name_re} ]]; then
        echo "Error: --n2c-token '${name}': expected 'all' or a token name (lowercase letters, digits and '-')." >&2
        exit 1
    fi
    N2C_TOKENS+=("${name}")
}

# _n2c_require_private DIR WHAT
#   Exit 1 unless DIR is a real directory (not a symlink) owned by the
#   current user with mode 0700.
_n2c_require_private() {
    local dir what="$2"
    dir="$(_n2c_strip_slashes "$1")"
    if [[ -L "${dir}" ]] || [[ ! -d "${dir}" ]] || [[ ! -O "${dir}" ]]; then
        echo "Error: ${what} '${dir}' must be a real directory owned by you (not a symlink). Refusing to mount N2C tokens." >&2
        exit 1
    fi
    if [[ "$(stat -c '%a' -- "${dir}" 2> /dev/null || true)" != "700" ]]; then
        echo "Error: ${what} '${dir}' must have mode 0700. Refusing to mount N2C tokens." >&2
        exit 1
    fi
}

# build_n2c_token_mounts
#   Add the token files requested with --n2c-token to EXTRA_RO_PATHS, so
#   build_extra_path_mounts validates and mounts each one read-only at its own
#   path.  Nothing is mounted unless --n2c-token was given.  "all" selects every
#   non-empty token under the credentials directory.  n2c-token rewrites a token
#   in place, so a mounted file sees every refresh.  When at least one token is
#   mounted, N2SN_CREDS_DIR (the canonical credentials directory) is set in the
#   sandbox environment, because the host's location variables are not passed in.
#
#   A requested token that is missing or empty only warns (run `n2c-token
#   login`).  A credentials directory or token directory that is a symlink, is
#   owned by someone else or is not mode 0700, or a token file that is a
#   symlink or not a regular file, is an error: the launch stops.
#
#   Must be called BEFORE build_extra_path_mounts.
build_n2c_token_mounts() {
    [[ -z "${N2C_TOKENS[*]+x}" ]] && return 0

    local root name tdir tfile want_all=0
    local -a names=() found=()
    local -A seen=()
    root="$(_n2c_creds_root)"

    for name in "${N2C_TOKENS[@]}"; do
        if [[ "${name}" == "all" ]]; then
            want_all=1
        elif [[ -z "${seen["${name}"]:-}" ]]; then
            seen["${name}"]=1
            names+=("${name}")
        fi
    done

    if [[ ! -e "${root}" && ! -L "${root}" ]]; then
        echo "Warning: N2C credentials directory '${root}' does not exist; no tokens mounted. Run: n2c-token login" >&2
        return 0
    fi
    _n2c_require_private "${root}" "N2C credentials directory"

    if [[ ${want_all} -eq 1 ]]; then
        names=()
        for tdir in "${root}"/*/; do
            [[ -e "${tdir}" || -L "${tdir}" ]] || continue
            tdir="${tdir%/}"
            name="${tdir##*/}"
            [[ "${name}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || continue
            names+=("${name}")
        done
    fi

    for name in "${names[@]+"${names[@]}"}"; do
        tdir="${root}/${name}"
        tfile="${tdir}/token"
        if [[ ! -e "${tdir}" && ! -L "${tdir}" ]]; then
            echo "Warning: no N2C token '${name}' (${tdir} does not exist); not mounted." >&2
            continue
        fi
        _n2c_require_private "${tdir}" "N2C token directory"
        if [[ -L "${tfile}" ]] || { [[ -e "${tfile}" ]] && [[ ! -f "${tfile}" ]]; }; then
            echo "Error: N2C token '${tfile}' must be a regular file, not a symlink. Refusing to mount N2C tokens." >&2
            exit 1
        fi
        if [[ ! -s "${tfile}" ]]; then
            if [[ ${want_all} -eq 0 ]]; then
                echo "Warning: N2C token '${name}' is missing or empty; not mounted. Run: n2c-token login" >&2
            fi
            continue
        fi
        found+=("${tfile}")
    done

    if [[ ${want_all} -eq 1 && ${#found[@]} -eq 0 ]]; then
        echo "Warning: no N2C tokens found in '${root}'; none mounted. Run: n2c-token login" >&2
    fi
    for tfile in "${found[@]+"${found[@]}"}"; do
        EXTRA_RO_PATHS+=("${tfile}")
    done

    # The sandbox environment is scrubbed (env -i), so tell consumers where the
    # tokens are, as they would find them on the host.  The files are mounted
    # at their canonical paths, so give the canonical credentials directory.
    if [[ ${#found[@]} -gt 0 ]]; then
        local croot
        croot="$(readlink -f -- "${root}" 2> /dev/null || true)"
        [[ -n "${croot}" ]] || croot="${root}"
        SANDBOX_ENV+=("N2SN_CREDS_DIR=${croot}")
    fi
}

# verify_n2c_state_not_exposed
#   Exit 1 when a bind mount in BWRAP_ARGS would expose the N2C session
#   directory, which holds the refresh token (see _n2c_state_dir).  The blocked
#   list refuses --ro-path and --rw-path, but the automatic whole-directory mounts
#   (npm and pixi caches, ccache, tool data and cache directories) are only
#   checked for being blocked themselves, so with N2C_STATE_DIR set inside one of
#   them the session directory would be mounted along with it.  This looks at the
#   finished mount list, so it covers every mount whatever added it.  Nothing is
#   checked while the directory does not exist.
#
#   Called by print_dry_run and launch_sandbox, after all mounts are built.
verify_n2c_state_not_exposed() {
    local state canon src flag i=0
    state="$(_n2c_state_dir)"
    [[ -e "${state}" ]] || return 0
    canon="$(readlink -f -- "${state}" 2> /dev/null || true)"
    while [[ ${i} -lt ${#BWRAP_ARGS[@]} ]]; do
        flag="${BWRAP_ARGS[${i}]}"
        _bwrap_flag_arity "${flag}"
        case "${flag}" in
            --bind | --bind-try | --ro-bind | --ro-bind-try | --dev-bind | --dev-bind-try)
                src="${BWRAP_ARGS[$((i + 1))]}"
                if _is_prefix_of "${src}" "${state}" ||
                    { [[ -n "${canon}" ]] && _is_prefix_of "${src}" "${canon}"; }; then
                    echo "Error: the mount of '${src}' would expose the N2C session directory '${state}' (it holds the refresh token)." >&2
                    echo "       Move N2C_STATE_DIR out of directories that the launcher mounts (for example ~/.npm, ~/.pixi, ~/.ccache)." >&2
                    exit 1
                fi
                ;;
        esac
        i=$((i + 1 + _BWRAP_FLAG_ARITY))
    done
}

# ── Path resolution ──────────────────────────────────────────────

resolve_common_paths() {
    _HOME="${HOME}"
    _HOME_CANON="$(readlink -f -- "${HOME}" 2> /dev/null || true)"
    [[ -n "${_HOME_CANON}" ]] || _HOME_CANON="${HOME}"
    # Physical working directory, so PWD in the sandbox agrees with the
    # canonical working-directory bind (git rev-parse also returns physical
    # paths).
    _PWD="$(pwd -P 2> /dev/null || true)"
    [[ -n "${_PWD}" ]] || _PWD="${PWD}"
    _USER="${USER:-$(bwrap_account_name)}"

    # XDG defaults
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${_HOME}/.config}"
    XDG_DATA_HOME="${XDG_DATA_HOME:-${_HOME}/.local/share}"
    XDG_CACHE_HOME="${XDG_CACHE_HOME:-${_HOME}/.cache}"

    # Pixi paths
    PIXI_HOME_DIR="${PIXI_HOME:-${_HOME}/.pixi}"

    # ccache paths
    # ccache cache: $CCACHE_DIR, else ~/.ccache if it exists (legacy), else $XDG_CACHE_HOME/ccache
    if [[ -n "${CCACHE_DIR:-}" ]]; then
        CCACHE_CACHE_DIR="${CCACHE_DIR}"
    elif [[ -d "${_HOME}/.ccache" ]]; then
        CCACHE_CACHE_DIR="${_HOME}/.ccache"
    else
        CCACHE_CACHE_DIR="${XDG_CACHE_HOME}/ccache"
    fi
    # ccache config: if legacy ~/.ccache dir exists, config is inside it;
    # otherwise $XDG_CONFIG_HOME/ccache
    if [[ -d "${_HOME}/.ccache" ]]; then
        CCACHE_CONFIG_DIR="${_HOME}/.ccache"
    else
        CCACHE_CONFIG_DIR="${XDG_CONFIG_HOME}/ccache"
    fi

    # npm paths
    NPM_CACHE_DIR="${NPM_CONFIG_CACHE:-${_HOME}/.npm}"

    # ── Safety checks on all user-controllable path roots ────────
    # These variables are set from env vars (XDG_*, PIXI_HOME, CCACHE_DIR,
    # NPM_CONFIG_CACHE) and control where entire directory trees are mounted
    # into the sandbox.  Validate each root once here so that every mount
    # derived from it is implicitly covered — no per-mount check needed for
    # sub-paths.  Paths that do not yet exist are checked against the blocked
    # list anyway (catches e.g. PIXI_HOME=~/.ssh before .pixi is created).
    _check_dir_safe "${XDG_CONFIG_HOME}"  "XDG_CONFIG_HOME"
    _check_dir_safe "${XDG_DATA_HOME}"    "XDG_DATA_HOME"
    _check_dir_safe "${XDG_CACHE_HOME}"   "XDG_CACHE_HOME"
    _check_dir_safe "${PIXI_HOME_DIR}"    "PIXI_HOME"
    _check_dir_safe "${CCACHE_CACHE_DIR}" "CCACHE_DIR (cache)"
    _check_dir_safe "${CCACHE_CONFIG_DIR}" "CCACHE_DIR (config)"
    _check_dir_safe "${NPM_CACHE_DIR}"    "NPM_CONFIG_CACHE"
}

# ── Sandbox PATH construction ────────────────────────────────────

init_sandbox_path() {
    SANDBOX_PATH="/usr/lib64/ccache:/usr/local/sbin:/usr/local/bin:/usr/bin"
    SANDBOX_PATH="${SANDBOX_PATH}:${PIXI_HOME_DIR}/bin"
    SANDBOX_PATH="${SANDBOX_PATH}:${_HOME}/bin"
    if [[ -d /nsls2/software/bin ]]; then
        SANDBOX_PATH="${SANDBOX_PATH}:/nsls2/software/bin"
    fi
    # Additional bin directories discovered during dynamic tool mounts are
    # appended to SANDBOX_PATH by finalize_sandbox_path.
}

# Append dynamically-discovered bin directories to SANDBOX_PATH.
# Deduplicates: the same dir can be recorded more than once (e.g. an npm bin
# dir added both as a tool's on-PATH dir and as the npm prefix's bin/), and a
# dir already present in the base SANDBOX_PATH need not be appended again.
finalize_sandbox_path() {
    local _extra_dir
    declare -A _path_seen=()
    # Seed with the base PATH entries so we don't re-append them.
    local _base_dir
    local -a _base_dirs=()
    IFS=':' read -ra _base_dirs <<< "${SANDBOX_PATH}"
    for _base_dir in "${_base_dirs[@]}"; do
        [[ -n "${_base_dir}" ]] && _path_seen["${_base_dir}"]=1
    done
    for _extra_dir in "${_EXTRA_PATH_DIRS[@]+"${_EXTRA_PATH_DIRS[@]}"}"; do
        [[ -z "${_extra_dir}" ]] && continue
        [[ -n "${_path_seen["${_extra_dir}"]:-}" ]] && continue
        _path_seen["${_extra_dir}"]=1
        SANDBOX_PATH="${SANDBOX_PATH}:${_extra_dir}"
    done
}

# ═══════════════════════════════════════════════════════════════════
# Shared sandbox construction functions
# ═══════════════════════════════════════════════════════════════════
# Each build_* function appends to the global BWRAP_ARGS array.
# They must be called in the correct order to produce valid bwrap
# arguments — see the tool wrapper's main() for the canonical sequence.

# ── Namespace isolation + base system (read-only) ────────────────
build_base_sandbox() {
    # --unshare-pid: Isolate the PID namespace so the sandbox cannot see
    #   or inspect host processes via /proc (prevents reading environ,
    #   cmdlines, and discovering services like ssh-agent).
    # --new-session: Calls setsid(2) — detaches the controlling terminal
    #   and creates a new session.  Originally added to block TIOCSTI
    #   ioctl keystroke injection into the parent terminal.  On kernels
    #   >= 5.14 TIOCSTI requires CAP_SYS_ADMIN (which bwrap drops), so
    #   the kernel guard subsumes the TIOCSTI side of this protection
    #   AND we want to omit --new-session so SIGWINCH (terminal resize)
    #   propagates correctly from tmux/screen to the sandboxed TUI.
    #
    #   Residual exposure when --new-session is omitted:
    #     - The sandbox keeps the controlling tty.  A direct
    #       open("/dev/tty") is mitigated in build_proc_dev_tmp by
    #       binding /dev/null over /dev/tty, but a malicious child can
    #       STILL reach the controlling tty via the inherited pty fds
    #       (fd 0/1/2), reachable as /proc/self/fd/0.  Closing the
    #       /proc/self/fd reopen path would require --unshare-user or
    #       hidepid=2 on /proc, neither of which we currently use.
    #     - Via that reopened fd, an attacker CAN:
    #         * write arbitrary bytes (display spoofing, escape
    #           sequences, fake TUI content)
    #         * call tcsetattr() to manipulate termios (disable echo)
    #     - Via that reopened fd, an attacker CANNOT
    #         * inject keystrokes via TIOCSTI — blocked by the 5.14
    #           kernel cap guard (returns EIO)
    #         * steal the foreground process group via tcsetpgrp —
    #           fails with ENOTTY (we have no controlling tty of our
    #           own, only an open fd to someone else's)
    #         * reliably read keystrokes — the TUI parent consumes
    #           them first, and the kernel gates this for non-CTTY fds
    #     - Escape-sequence-based attacks via stdout (OSC 52 clipboard
    #       hijack, terminal-response injection on legacy emulators)
    #       are NOT mitigated by --new-session either — stdout is
    #       already a direct path to the user's terminal.  These are
    #       the TUI's responsibility (filter tool output) and out of
    #       scope here.
    #
    #   Users can force --new-session via the wrapper's --new-session
    #   flag (which sets FORCE_NEW_SESSION=1), e.g. for non-interactive
    #   runs where SIGWINCH propagation is unimportant.  Note that
    #   --new-session does NOT close the /proc/self/fd reopen path — it
    #   only detaches the controlling terminal, not already-open fds
    #   held by other processes in the sandbox.
    # --die-with-parent: Kill the sandbox if the parent process exits, to
    #   prevent orphaned sandbox processes.
    # Network is shared so the tool can reach LLM APIs and GitHub OAuth.
    BWRAP_ARGS+=(
        --unshare-pid
        --die-with-parent
    )
    if [[ "${FORCE_NEW_SESSION}" -eq 1 ]] || [[ "${KERNEL_HAS_TIOCSTI_CAP_GUARD}" -eq 0 ]]; then
        BWRAP_ARGS+=(--new-session)
    fi

    # Base system (read-only)
    BWRAP_ARGS+=(
        --ro-bind /usr /usr
    )
    # /bin, /sbin, /lib, and /lib64 may be real directories (Debian-family)
    # or symlinks into /usr (Fedora/Arch).  Bind the real dir, or recreate
    # the symlink so tools expecting e.g. /bin/bash still work.
    local _dir
    for _dir in /bin /sbin /lib /lib64; do
        if [[ -L "${_dir}" ]]; then
            BWRAP_ARGS+=(--symlink "$(readlink "${_dir}")" "${_dir}")
        elif [[ -d "${_dir}" ]]; then
            BWRAP_ARGS+=(--ro-bind "${_dir}" "${_dir}")
        fi
    done
}

# ── Mask dangerous binaries ───────────────────────────────────────
# Bind /dev/null over security-sensitive binaries so attempts to
# execute them fail rather than silently working.
#
# This requires bwrap >= 0.6.3 which supports binding over paths inside
# an existing read-only bind mount.  On older versions, we skip masking
# entirely (the binaries remain accessible inside the sandbox).
#
# Must be the very last step of every launcher, after every other mount
# (user --ro-path / --rw-path included) and after the environment builders,
# some of which add binds (bwcodex binds SSL_CERT_FILE): a bind that covers a
# masked binary or its directory (e.g. --ro-path /usr or /usr/bin) emitted
# afterwards would hide the mask.
#
# Categories:
#   SSH           – lateral movement via remote shell / file transfer
#   Network       – arbitrary TCP/UDP connections, reverse shells
#   Kerberos      – ticket-based authentication to network services
#   Keyring       – kernel keyring manipulation
#   Priv-escalation – sudo/su/pkexec
#   Namespace     – sandbox escape via nsenter/unshare/chroot
build_binary_masks() {
    [[ "${HAS_BIND_OVER_RO}" -eq 1 ]] || return 0

    local _MASKED_BINS=(
        # SSH
        ssh scp sftp ssh-agent ssh-add ssh-keygen ssh-keyscan
        # Network
        telnet nc ncat netcat rsync rsh rlogin rexec
        # Kerberos
        kinit klist kdestroy kswitch
        # Keyring
        keyctl
        # Privilege escalation
        sudo su pkexec
        # Namespace / sandbox escape
        nsenter unshare chroot
    )
    # Canonicalize + dedupe the search prefixes once.  On merged-/usr systems
    # /bin, /sbin, /usr/bin, /usr/sbin resolve to the same directory; collapsing
    # them here avoids re-checking (and re-resolving) the same candidate under
    # several aliases.  Search prefixes cover RHEL, Debian, and Arch layouts.
    declare -A _prefix_seen=()
    local -a _canon_prefixes=()
    local _p _pc
    for _p in /usr/bin /usr/sbin /usr/lib/openssh /usr/libexec/openssh /bin /sbin; do
        [[ -d "${_p}" ]] || continue
        _pc="$(readlink -f "${_p}" 2> /dev/null || printf '%s' "${_p}")"
        [[ -n "${_prefix_seen["${_pc}"]:-}" ]] && continue
        _prefix_seen["${_pc}"]=1
        _canon_prefixes+=("${_pc}")
    done
    [[ ${#_canon_prefixes[@]} -gt 0 ]] || return 0

    # Collect every existing candidate binary across the unique prefixes.
    # -e follows symlinks: true only if the full chain resolves to a real file,
    # so dangling alternatives entries are skipped (correct — nothing to mask).
    local -a _candidates=()
    local _bin _candidate
    for _bin in "${_MASKED_BINS[@]}"; do
        for _pc in "${_canon_prefixes[@]}"; do
            _candidate="${_pc}/${_bin}"
            [[ -e "${_candidate}" ]] && _candidates+=("${_candidate}")
        done
    done
    [[ ${#_candidates[@]} -gt 0 ]] || return 0

    # On RHEL/Debian the binary is often a symlink:
    #   /usr/bin/nc -> /etc/alternatives/nc -> /usr/bin/ncat
    # bwrap processes --ro-bind arguments in order; at the point the bind is
    # applied /etc/alternatives is not yet mounted, so bwrap cannot resolve the
    # intermediate symlink ("Can't create file at /usr/bin/nc").  Resolve every
    # candidate to its canonical, symlink-free path (always reachable under /usr
    # once --ro-bind /usr /usr is applied) and mask *that*.  A single readlink
    # -f fork resolves all candidates at once (was one realpath fork each).
    declare -A _masked_real_seen=()
    local _real
    while IFS= read -r _real; do
        [[ -n "${_real}" ]] || continue
        [[ -n "${_masked_real_seen["${_real}"]:-}" ]] && continue
        _masked_real_seen["${_real}"]=1
        BWRAP_ARGS+=(--ro-bind /dev/null "${_real}")
    done < <(readlink -f "${_candidates[@]}")
}

build_proc_dev_tmp() {
    BWRAP_ARGS+=(
        --proc /proc
        --dev /dev
        --tmpfs /tmp
    )

    # Mask /dev/tty unless --new-session is active.
    #
    # With --new-session bwrap detaches the controlling terminal, so
    # open("/dev/tty") returns ENXIO inside the sandbox — there is no
    # tty to find.  Without --new-session (the default on kernels with
    # the TIOCSTI cap-guard, where we drop --new-session to let SIGWINCH
    # through), the sandboxed process inherits the controlling terminal
    # and can open /dev/tty as a direct, un-redirectable, un-loggable
    # channel to the user's terminal.  Binding /dev/null over /dev/tty
    # blocks the naïve open("/dev/tty") path.
    #
    # Scope of this mitigation: closes the obvious API path used by
    # legitimate tools (sudo, ssh-askpass, gpg-agent) and by naïve
    # malicious dependencies.  Does NOT close the procfs-fd-reopen
    # bypass — see the long comment in build_base_sandbox for the
    # threat-model details.  Closing that bypass needs a separate user
    # namespace or hidepid=2 on /proc.
    #
    # Programs typically use isatty(0/1/2) — which still works on the
    # inherited stdio fds — to detect interactivity, so masking
    # /dev/tty rarely breaks tools that aren't actively trying to
    # bypass stdio.
    if [[ "${FORCE_NEW_SESSION}" -ne 1 ]] && [[ "${KERNEL_HAS_TIOCSTI_CAP_GUARD}" -eq 1 ]]; then
        BWRAP_ARGS+=(--bind /dev/null /dev/tty)
    fi
}

# ── Selective /sys (read-only) ───────────────────────────────────
# Expose only CPU and NUMA-node topology so tools can size thread
# pools and place work sensibly (nproc/hwloc/OpenMP/BLAS, NUMA-aware
# allocators).  Everything else under /sys is deliberately omitted.
#
# Scope and rationale:
#   /sys/devices/system/cpu   — CPU topology, core/thread counts,
#                               online mask, cache layout.
#   /sys/devices/system/node  — NUMA node layout (cpulist, meminfo,
#                               distance); consulted by hwloc and
#                               NUMA-aware threading/BLAS libraries.
#
# Mounted read-only (--ro-bind), never --dev-bind: sysfs stays
# non-writable so the classic write vectors (changing hardware state,
# uevent helpers, cgroup/security nodes) are out of reach.  We do NOT
# bind all of /sys — that would pull in /sys/kernel, /sys/fs/cgroup,
# /sys/class, /sys/firmware, /sys/power, etc.  The only residual
# exposure from these two subtrees is host hardware fingerprinting
# (an info leak, largely redundant with /proc/cpuinfo which is already
# visible via --proc), not privilege escalation.
#
# --ro-bind-try so the sandbox still works on hosts/kernels where a
# node is absent (e.g. non-NUMA kernels lacking /sys/devices/system/node).
build_sys_mounts() {
    BWRAP_ARGS+=(
        --ro-bind-try /sys/devices/system/cpu /sys/devices/system/cpu
        --ro-bind-try /sys/devices/system/node /sys/devices/system/node
    )
}

# ── Selective /etc (read-only) ───────────────────────────────────
# Only expose what is needed for DNS, TLS, user identity, and NSS.
build_etc_mounts() {
    BWRAP_ARGS+=(
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf
        --ro-bind-try /etc/hosts /etc/hosts
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
        --ro-bind /etc/passwd /etc/passwd
        --ro-bind /etc/group /etc/group
        --ro-bind-try /etc/ssl /etc/ssl
        --ro-bind-try /etc/pki /etc/pki
        --ro-bind-try /etc/crypto-policies /etc/crypto-policies
        --ro-bind-try /etc/ca-certificates /etc/ca-certificates
        --ro-bind-try /etc/alternatives /etc/alternatives
        --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
        --ro-bind-try /etc/ld.so.conf /etc/ld.so.conf
        --ro-bind-try /etc/ld.so.conf.d /etc/ld.so.conf.d
        --ro-bind-try /etc/localtime /etc/localtime
        --ro-bind-try /etc/gitconfig /etc/gitconfig
    )
}

# ── OpenCode config requirement ───────────────────────────────────
# require_opencode_config WRAPPER USER_CONFIG_DIR
#   Exit 2 unless at least a minimal OpenCode config exists: a system-wide
#   /etc/opencode/opencode.json{,c} (deployed by ansible on managed hosts) or
#   a user opencode.json, opencode.jsonc or config.json in USER_CONFIG_DIR.
#   Either is sufficient; OpenCode layers the user config under the managed
#   one.  Without any, OpenCode starts with no provider or model and fails
#   with a confusing error of its own.  Only the files' presence is checked,
#   not their content.  OPENCODE_CONFIG* is not forwarded into the sandbox,
#   so it is no substitute.
require_opencode_config() {
    local _wrapper="$1" _user_dir="$2" _f
    for _f in /etc/opencode/opencode.json /etc/opencode/opencode.jsonc; do
        [[ -f "${_f}" && -r "${_f}" ]] && return 0
    done
    for _f in opencode.json opencode.jsonc config.json; do
        [[ -f "${_user_dir}/${_f}" && -r "${_user_dir}/${_f}" ]] && return 0
    done
    printf 'Error: %s needs at least a minimal OpenCode config to run.\n' "${_wrapper}" >&2
    printf '       No config was found in either place:\n' >&2
    printf '         /etc/opencode/opencode.json or opencode.jsonc  (system-wide; deployed by ansible)\n' >&2
    printf '         %s/opencode.json, opencode.jsonc or config.json  (user)\n' "${_user_dir}" >&2
    printf '       Create at least one.\n' >&2
    exit 2
}

# ── Managed system paths (read-only) ──────────────────────────────
# Bind a fixed, administrator-provided path only when it exists.  Resolve
# aliases before binding: the source can be an /etc symlink into the managed
# skills deployment, while the destination must remain the location the CLI
# discovers.  Callers provide literal paths; do not use this for user input.
build_managed_ro_bind() {
    local source="$1" target="$2" resolved
    [[ -e "${source}" ]] || return 0

    resolved="$(readlink -f "${source}")"
    [[ -e "${resolved}" ]] || return 0
    BWRAP_ARGS+=(--ro-bind "${resolved}" "${target}")
}

# ── Home directory (empty tmpfs, then selective mounts) ──────────
build_home_tmpfs() {
    BWRAP_ARGS+=(
        --tmpfs "${_HOME}"
    )

    # Create intermediate directories that are needed as mount points
    # inside the tmpfs $HOME.
    BWRAP_ARGS+=(
        --dir "${_HOME}/.config"
        --dir "${_HOME}/.local"
        --dir "${_HOME}/.local/share"
        --dir "${_HOME}/.cache"
        --dir "${_HOME}/bin"
    )
}

# ── Working directory (read-write) ────────────────────────────────
# If we are inside a git repo, bind the repo root so the tool can
# find .git and identify the project (sessions are keyed to the repo).
# Otherwise fall back to binding just $PWD.
# Sets globals: _BIND_DIR, _GIT_ROOT
build_workdir_mount() {
    _BIND_DIR="${_PWD}"
    _GIT_ROOT="$(git -C "${_PWD}" rev-parse --show-toplevel 2> /dev/null || true)"
    if [[ -n "${_GIT_ROOT}" ]]; then
        _BIND_DIR="${_GIT_ROOT}"
    fi

    # Canonicalize before the safety checks.  pwd -P and git rev-parse already
    # return physical paths, but resolving once more guarantees a symlinked
    # working directory (e.g. a symlink into ~/.ssh) cannot reach
    # _check_path_safe in its logical form.
    local _bind_canon
    _bind_canon="$(readlink -f -- "${_BIND_DIR}" 2> /dev/null || true)"
    [[ -n "${_bind_canon}" ]] && _BIND_DIR="${_bind_canon}"

    # Guard: reject dangerous working / git-root directories via the same
    # rules applied to --ro-path / --rw-path.  This catches $HOME itself,
    # ancestors of $HOME (/home, /), /root, ~/.ssh, and all other blocked
    # prefixes, and a directory that CONTAINS a blocked location (e.g.
    # ~/.config with ~/.config/gh): the whole tree is bound read-write.
    _check_bind_safe "${_BIND_DIR}" "working directory"

    # If the bind dir is under HOME, create intermediate directories in the
    # tmpfs so the bind mount point is reachable.  _BIND_DIR is itself the
    # bind mount point, so only its ancestors are pre-created.
    _emit_home_intermediate_dirs "${_BIND_DIR}"
    BWRAP_ARGS+=(
        --bind "${_BIND_DIR}" "${_BIND_DIR}"
    )
    # Register the read-write tree so a tool resolved from inside it (e.g.
    # node_modules/.bin or .pixi/envs/*/bin on PATH) does not get an --ro-bind
    # on top, which would make that subtree read-only (EROFS on install).
    # build_workdir_mount runs before build_dynamic_tool_mounts everywhere.
    _MOUNTED_PREFIXES["${_BIND_DIR}"]=1
}

# ── Git config (read-only) ──────────────────────────────────────

# _bwrap_already_mounted PATH
#   Return 0 when PATH lies inside a tree that is present in the sandbox with
#   its host content (symlinks included): the standard system trees, the /etc
#   DIRECTORY trees build_etc_mounts binds (never /etc itself: only selected
#   entries of it are bound, so e.g. /etc/xdg is NOT present), the working
#   directory, and the pixi / ccache / npm / ~/bin / registered mounts.
#   Anything else under the tmpfs $HOME is NOT present.
_bwrap_already_mounted() {
    local path="$1" _m
    for _m in /usr /bin /sbin /lib /lib64 \
            /etc/ssl /etc/pki /etc/crypto-policies /etc/ca-certificates \
            /etc/alternatives /etc/ld.so.conf.d /nsls2/software/bin \
            "${_BIND_DIR}" "${PIXI_HOME_DIR}" "${CCACHE_CONFIG_DIR}" \
            "${CCACHE_CACHE_DIR}" "${NPM_CACHE_DIR}" "${_HOME}/bin"; do
        [[ -n "${_m}" ]] || continue
        _is_prefix_of "${_m}" "${path}" && return 0
    done
    if [[ ${#_MOUNTED_PREFIXES[@]} -gt 0 ]]; then
        for _m in "${!_MOUNTED_PREFIXES[@]}"; do
            _is_prefix_of "${_m}" "${path}" && return 0
        done
    fi
    return 1
}

# _bwrap_is_bind_root PATH
#   Return 0 when PATH is EXACTLY the root of a directory the launcher binds
#   whole (the working directory, the pixi / ccache / npm / ~/bin trees, any
#   registered mount), other than the system trees /usr /bin /sbin /lib
#   /lib64 /proc /dev /tmp (those are real directories, or symlinks that
#   build_sys_mounts recreates as symlinks).  A bind's source is resolved, so
#   when PATH is a symlink the sandbox sees a plain directory at PATH; a
#   symlink strictly INSIDE a bound tree keeps its host form.
_bwrap_is_bind_root() {
    local path="$1" _m
    for _m in "${_BIND_DIR}" "${PIXI_HOME_DIR}" "${CCACHE_CONFIG_DIR}" \
            "${CCACHE_CACHE_DIR}" "${NPM_CACHE_DIR}" "${_HOME}/bin"; do
        [[ -n "${_m}" && "${_m}" == "${path}" ]] && return 0
    done
    if [[ ${#_MOUNTED_PREFIXES[@]} -gt 0 ]]; then
        for _m in "${!_MOUNTED_PREFIXES[@]}"; do
            case "${_m}" in
                /usr | /bin | /sbin | /lib | /lib64 | /proc | /dev | /tmp) continue ;;
            esac
            [[ "${_m}" == "${path}" ]] && return 0
        done
    fi
    return 1
}

# _bwrap_dest_in_args PATH
#   Return 0 when some element of BWRAP_ARGS equals PATH or lies below it
#   (--dir / --tmpfs / --bind / --ro-bind / --symlink destination, or a child
#   of PATH): PATH already exists in the sandbox as a directory (or other
#   object) or has been populated, so a --symlink at PATH would make bwrap
#   fail at startup.
_bwrap_dest_in_args() {
    local path="$1" _a
    for _a in "${BWRAP_ARGS[@]+"${BWRAP_ARGS[@]}"}"; do
        [[ "${_a}" == "${path}" || "${_a}" == "${path}"/* ]] && return 0
    done
    return 1
}

# _bwrap_git_recreate_link LINK
#   Make the symlinked directory LINK exist in the sandbox.  The sandbox
#   $HOME is a tmpfs, so a symlink under $HOME is lost; without it the kernel
#   resolves ".." in a git include path differently than on the host.  Emits
#   --symlink <real target> LINK (after the --dir ancestors) once per LINK.
#   Return 0 when LINK is present (already mounted, or recreated), 1 when it
#   cannot be: outside $HOME and not inside a mounted tree (symlinks outside
#   $HOME, e.g. under /etc, are never recreated), dangling, LINK or its target
#   inside a blocked location, LINK already present in BWRAP_ARGS, or LINK is
#   itself the root of a directory bind (_bwrap_is_bind_root; the last two are
#   warned about and never linked).
#   Ordering rule: bwrap fails at startup when --symlink's destination
#   exists.  build_home_tmpfs pre-creates ~/.config, ~/.local, ~/.local/share,
#   ~/.cache and ~/bin as directories and other mounts populate paths below
#   them before this runs, so a host symlink at such a path is NOT emitted;
#   the sandbox keeps the plain directory (_GIT_LINK_CONFLICT[LINK]=1).
_bwrap_git_recreate_link() {
    local link="$1" target
    if [[ -n "${_GIT_LINK_STATUS["${link}"]:-}" ]]; then
        return "${_GIT_LINK_STATUS["${link}"]}"
    fi
    _GIT_LINK_STATUS["${link}"]=1
    if _bwrap_is_bind_root "${link}"; then
        # The symlink IS the root of a directory bind (e.g. ~/bin -> dotfiles
        # with --ro-bind ~/bin ~/bin): the bind source is the symlink's
        # target, so the sandbox has a plain directory at LINK and ".."
        # through it resolves lexically.
        _GIT_LINK_CONFLICT["${link}"]=1
        printf 'Warning: %s is a symlink on the host but a plain directory in the sandbox\n' "${link}" >&2
        printf '         (it is the root of a directory mount); not recreated. Git includes that use ".."\n' >&2
        printf '         through it may not resolve.\n' >&2
        return 1
    fi
    if _bwrap_already_mounted "${link}"; then
        _GIT_LINK_STATUS["${link}"]=0
        return 0
    fi
    [[ "${link}" == "${_HOME}"/* ]] || return 1
    target="$(readlink -f -- "${link}" 2> /dev/null || true)"
    [[ -n "${target}" && -d "${target}" ]] || return 1
    if _bwrap_path_blocked "${link}" || _bwrap_path_blocked "${target}"; then
        echo "Warning: symlink ${link} resolves into a blocked location (${target}); not recreated." >&2
        return 1
    fi
    if _bwrap_dest_in_args "${link}"; then
        _GIT_LINK_CONFLICT["${link}"]=1
        printf 'Warning: %s is a symlink on the host but exists as a plain directory in the sandbox\n' "${link}" >&2
        printf '         (it is pre-created or already populated); not recreated. Git includes that use ".."\n' >&2
        printf '         through it may not resolve.\n' >&2
        return 1
    fi
    _emit_home_intermediate_dirs "${link}"
    BWRAP_ARGS+=(--symlink "${target}" "${link}")
    _GIT_LINK_STATUS["${link}"]=0
    return 0
}

# _bwrap_mount_xdg_git_files
#   Mount ONLY allowed_signers, config, ignore and attributes of
#   ${XDG_CONFIG_HOME}/git, each read-only and only when present.  The
#   directory itself is never bound: anything else in it (the "store"
#   credential helper's "credentials" file included) is never mounted, and a
#   file created on the host later never appears in the sandbox.  A file (or
#   the whole directory) that resolves into a blocked location is skipped
#   with a warning; a dangling symlink is skipped silently.  When the
#   directory is itself a symlink it is recreated as one and the files are
#   mounted at its real target, so ".." in includes resolves as on the host.
_bwrap_mount_xdg_git_files() {
    local gdir="${XDG_CONFIG_HOME}/git" gdir_real dest_dir name f f_real
    local -a names=() reals=()
    [[ -d "${gdir}" ]] || return 0
    gdir_real="$(readlink -f -- "${gdir}" 2> /dev/null || true)"
    [[ -n "${gdir_real}" ]] || return 0
    if _bwrap_path_blocked "${gdir_real}"; then
        echo "Warning: ${gdir} resolves into a blocked location (${gdir_real}); not mounted." >&2
        return 0
    fi
    for name in allowed_signers config ignore attributes; do
        f="${gdir}/${name}"
        [[ -e "${f}" ]] || continue
        f_real="$(readlink -f -- "${f}" 2> /dev/null || true)"
        [[ -n "${f_real}" && -f "${f_real}" ]] || continue
        if _bwrap_path_blocked "${f_real}"; then
            echo "Warning: ${f} resolves into a blocked location (${f_real}); not mounted." >&2
            continue
        fi
        names+=("${name}")
        reals+=("${f_real}")
    done
    [[ ${#names[@]} -gt 0 ]] || return 0

    dest_dir="${gdir}"
    if [[ -L "${gdir}" ]] && _bwrap_git_recreate_link "${gdir}"; then
        dest_dir="${gdir_real}"
    fi
    if [[ "${dest_dir}" == "${_HOME}"/* ]]; then
        _emit_home_intermediate_dirs "${dest_dir}" inclusive
    else
        BWRAP_ARGS+=(--dir "${dest_dir}")
    fi
    local _k
    for _k in "${!names[@]}"; do
        BWRAP_ARGS+=(--ro-bind "${reals[${_k}]}" "${dest_dir}/${names[${_k}]}")
    done
}

# _bwrap_git_lexical_mount RAW INC_PATH
#   Fallback for a git include whose symlinked directories exist in the
#   sandbox as plain directories: mount INC_PATH (read-only) at RAW collapsed
#   lexically, creating the directories git walks before the last ".." (the
#   caller's _GIT_INC_DIRS_SEEN / _GIT_INC_BOUND dedupe).  Returns 1 without
#   emitting the bind when that is not safe: the destination is outside $HOME
#   or blocked, is already in BWRAP_ARGS (never mounted over an existing
#   destination such as ~/.gitconfig or an XDG git file), or a walked
#   component is blocked, outside $HOME and not mounted, or a symlink that is
#   present in the sandbox as a symlink (not a plain directory).  Sets
#   _BWRAP_LEX_DEST on success.  Runs in the caller's shell (it appends to
#   BWRAP_ARGS), so it must not be used in a command substitution.
_bwrap_git_lexical_mount() {
    local raw="$1" inc_path="$2" d lex parent
    local -a dirs=()
    _BWRAP_LEX_DEST=""
    [[ -n "${raw}" ]] || return 1
    _bwrap_include_lexical_path "${raw}"
    lex="${_BWRAP_INC_LEXICAL}"
    [[ "${lex}" == "${_HOME}"/* && "${lex}" != "${inc_path}" ]] || return 1
    _bwrap_path_blocked "${lex}" && return 1
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        if _is_prefix_of "${d}" "${_HOME}"; then
            continue # $HOME or an ancestor: exists (the tmpfs mount point)
        elif [[ "${d}" == "${_HOME}"/* ]]; then
            _bwrap_path_blocked "${d}" && return 1
            if [[ -L "${d}" && -z "${_GIT_LINK_CONFLICT["${d}"]:-}" ]]; then
                return 1
            fi
            dirs+=("${d}")
        else
            _bwrap_already_mounted "${d}" || return 1
        fi
    done <<< "${_BWRAP_INC_LEXDIRS}"
    if [[ -z "${_GIT_INC_BOUND["${lex}"]:-}" ]]; then
        if _bwrap_dest_in_args "${lex}"; then
            printf 'Warning: not mounting git include at %s: that path is already in use in the sandbox.\n' "${lex}" >&2
            return 1
        fi
        for d in "${dirs[@]+"${dirs[@]}"}"; do
            [[ -z "${_GIT_INC_DIRS_SEEN["${d}"]:-}" ]] || continue
            _GIT_INC_DIRS_SEEN["${d}"]=1
            BWRAP_ARGS+=(--dir "${d}")
        done
        parent="${lex%/*}"
        if [[ "${parent}" != "${_HOME}" && -z "${_GIT_INC_DIRS_SEEN["${parent}"]:-}" ]]; then
            _GIT_INC_DIRS_SEEN["${parent}"]=1
            BWRAP_ARGS+=(--dir "${parent}")
        fi
        _GIT_INC_BOUND["${lex}"]=1
        BWRAP_ARGS+=(--ro-bind-try "${inc_path}" "${lex}")
    fi
    _BWRAP_LEX_DEST="${lex}"
    return 0
}

build_git_mounts() {
    # Resolve symlinks so we bind the real file (readlink -f is a no-op on
    # regular files).  Check the resolved target before emitting the bind:
    # ~/.gitconfig could be a symlink pointing anywhere on the filesystem.
    if [[ -f "${_HOME}/.gitconfig" ]]; then
        local _gitconfig_real
        _gitconfig_real="$(readlink -f "${_HOME}/.gitconfig")"
        _check_path_safe "${_gitconfig_real}" "\$HOME/.gitconfig (resolved)"
        BWRAP_ARGS+=(--ro-bind "${_gitconfig_real}" "${_HOME}/.gitconfig")
    fi
    _bwrap_mount_xdg_git_files

    # Git include files (read-only).
    # parse_git_includes canonicalized every include path with readlink -f
    # (GIT_INCLUDE_PATHS) and recorded the path git will actually open
    # (GIT_INCLUDE_VISIBLE).  Check each canonical path before mounting — a
    # git config could contain  path = ~/.ssh/id_rsa  or an include whose
    # parent directory is a symlink into a blocked tree.  When the visible
    # path differs from the canonical one (symlinked parent), also mount the
    # content at the visible path, since git opens the include there.
    declare -A _GIT_INC_DIRS_SEEN=()
    declare -A _GIT_INC_BOUND=()
    local inc_path inc_visible local_parent _i
    for _i in "${!GIT_INCLUDE_PATHS[@]}"; do
        inc_path="${GIT_INCLUDE_PATHS[${_i}]}"
        inc_visible="${GIT_INCLUDE_VISIBLE[${_i}]:-${inc_path}}"
        _check_path_safe "${inc_path}" "git include path"
        # Symlinked directories before a ".." in the include path: recreate
        # them so the kernel resolves ".." as on the host.  If one cannot be
        # recreated the include is mounted at its real path only.
        local _link _links_ok=1 _conflict_only=1
        while IFS= read -r _link; do
            [[ -n "${_link}" ]] || continue
            if ! _bwrap_git_recreate_link "${_link}"; then
                _links_ok=0
                [[ -n "${_GIT_LINK_CONFLICT["${_link}"]:-}" ]] || _conflict_only=0
            fi
        done <<< "${GIT_INCLUDE_LINKS[${_i}]:-}"
        local _lex=""
        if [[ "${_links_ok}" -eq 0 ]]; then
            inc_visible="${inc_path}"
            # Every symlink that could not be recreated exists in the sandbox
            # as a plain directory (conflict with a pre-created directory):
            # git resolves ".." there lexically, so provide the include at
            # its lexically collapsed path as well.  Never done when a
            # symlink failed for another reason (missing, blocked, outside
            # $HOME): that component does not exist in the sandbox.
            if [[ "${_conflict_only}" -eq 1 ]]; then
                _bwrap_git_lexical_mount "${GIT_INCLUDE_RAW[${_i}]:-}" "${inc_path}" && _lex="${_BWRAP_LEX_DEST}"
            fi
            if [[ -n "${_lex}" ]]; then
                printf 'Warning: git include %s: a symlinked directory is a plain directory in the sandbox;\n' "${GIT_INCLUDE_RAW[${_i}]}" >&2
                printf '         the include is also mounted at %s, where git looks for it there.\n' "${_lex}" >&2
            else
                printf 'Warning: git include %s needs a symlinked directory that cannot be recreated in\n' "${GIT_INCLUDE_VISIBLE[${_i}]:-${inc_path}}" >&2
                printf '         the sandbox; it is mounted at its real path (%s) only, so git may not find it.\n' "${inc_path}" >&2
            fi
        fi
        # Directories the kernel must traverse to resolve ".." in the include
        # path git opens (they hold no data; they only have to exist).
        local _predir
        while IFS= read -r _predir; do
            [[ -n "${_predir}" && -z "${_GIT_INC_DIRS_SEEN["${_predir}"]:-}" ]] || continue
            # Never create a directory inside a blocked location, not even an
            # empty one (a symlinked directory pointing there stays unresolved).
            ! _bwrap_path_blocked "${_predir}" || continue
            _GIT_INC_DIRS_SEEN["${_predir}"]=1
            BWRAP_ARGS+=(--dir "${_predir}")
        done <<< "${GIT_INCLUDE_PREDIRS[${_i}]:-}"
        if [[ -z "${_GIT_INC_BOUND["${inc_path}"]:-}" ]]; then
            _GIT_INC_BOUND["${inc_path}"]=1
            # Ensure parent directory exists as a mount point (deduplicated)
            local_parent="${inc_path%/*}"
            if [[ -z "${_GIT_INC_DIRS_SEEN["${local_parent}"]:-}" ]]; then
                _GIT_INC_DIRS_SEEN["${local_parent}"]=1
                BWRAP_ARGS+=(--dir "${local_parent}")
            fi
            BWRAP_ARGS+=(--ro-bind-try "${inc_path}" "${inc_path}")
        fi
        if [[ "${inc_visible}" != "${inc_path}" && -z "${_GIT_INC_BOUND["${inc_visible}"]:-}" ]]; then
            _GIT_INC_BOUND["${inc_visible}"]=1
            local_parent="${inc_visible%/*}"
            if [[ -z "${_GIT_INC_DIRS_SEEN["${local_parent}"]:-}" ]]; then
                _GIT_INC_DIRS_SEEN["${local_parent}"]=1
                BWRAP_ARGS+=(--dir "${local_parent}")
            fi
            BWRAP_ARGS+=(--ro-bind-try "${inc_path}" "${inc_visible}")
        fi
    done
}

# ── Pixi cache (read-write) + config (read-only) ────────────────
build_pixi_mounts() {
    if [[ -d "${PIXI_HOME_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${PIXI_HOME_DIR}" "${PIXI_HOME_DIR}")
    fi

    # Pixi checks multiple config locations; bind any that exist.
    # The config files can be symlinks (or live under a symlinked directory)
    # pointing anywhere: canonicalize and check before binding the real file.
    if [[ -f "${XDG_CONFIG_HOME}/pixi/config.toml" ]]; then
        _bwrap_canonicalize_safe "${XDG_CONFIG_HOME}/pixi/config.toml" "pixi config.toml (resolved)"
        BWRAP_ARGS+=(
            --dir "${XDG_CONFIG_HOME}/pixi"
            --ro-bind "${_BWRAP_CANON}" "${XDG_CONFIG_HOME}/pixi/config.toml"
        )
    fi
    if [[ -f "${_HOME}/.pixi/config.toml" ]]; then
        # Already available via the pixi overlay, but if the overlay is not
        # present (dir doesn't exist), bind it explicitly.
        if [[ ! -d "${PIXI_HOME_DIR}" ]]; then
            _bwrap_canonicalize_safe "${_HOME}/.pixi/config.toml" "\$HOME/.pixi/config.toml (resolved)"
            BWRAP_ARGS+=(--ro-bind "${_BWRAP_CANON}" "${_HOME}/.pixi/config.toml")
        fi
    fi
}

# ── ccache config (read-only) + cache (read-write) ──────────────
build_ccache_mounts() {
    if [[ -d "${CCACHE_CONFIG_DIR}" ]]; then
        BWRAP_ARGS+=(
            --dir "${CCACHE_CONFIG_DIR%/*}"
            --ro-bind "${CCACHE_CONFIG_DIR}" "${CCACHE_CONFIG_DIR}"
        )
    fi

    if [[ -d "${CCACHE_CACHE_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${CCACHE_CACHE_DIR}" "${CCACHE_CACHE_DIR}")
    fi
}

# ── npm config (read-only) + cache (read-write) ─────────────────
build_npm_mounts() {
    if [[ -f "${_HOME}/.npmrc" ]]; then
        BWRAP_ARGS+=(--ro-bind "${_HOME}/.npmrc" "${_HOME}/.npmrc")
    fi

    if [[ -d "${NPM_CACHE_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${NPM_CACHE_DIR}" "${NPM_CACHE_DIR}")
    fi
}

# ── User binaries (read-only) ───────────────────────────────────
build_user_bin_mount() {
    if [[ -d "${_HOME}/bin" ]]; then
        BWRAP_ARGS+=(--ro-bind "${_HOME}/bin" "${_HOME}/bin")
    fi
}

# ── Authoring directories (read-write, persistent) ──────────────
# The tools let users author reusable definitions (skills, agents, commands,
# prompts) as plain markdown under their config/home directory, and the agent
# is expected to be able to create and edit them from inside the sandbox.  The
# tool's home/config directory is a tmpfs, so each such directory must be
# bind-mounted read-write from its real host location to survive the session.
#
# _path_visible_from_host PATH
#   Return 0 when PATH already shows its host contents in the sandbox given
#   the mounts emitted so far, i.e. the LAST mount in BWRAP_ARGS covering PATH
#   (at PATH or an ancestor) is an identity bind (source == destination).  A
#   registered ancestor in _MOUNTED_PREFIXES is not enough: a later tmpfs (a
#   tool home such as CODEX_HOME=$PWD/.codex inside the working directory) or
#   a bind from a different source hides what an earlier bind exposed.
_path_visible_from_host() {
    local _path="$1" _i=0 _flag _src _dest _visible=0
    while [[ ${_i} -lt ${#BWRAP_ARGS[@]} ]]; do
        _flag="${BWRAP_ARGS[${_i}]}"
        _bwrap_flag_arity "${_flag}"
        case "${_flag}" in
            --tmpfs)
                _dest="${BWRAP_ARGS[$((_i + 1))]}"
                _is_prefix_of "${_dest}" "${_path}" && _visible=0
                ;;
            --bind | --ro-bind | --bind-try | --ro-bind-try | --dev-bind | --dev-bind-try)
                _src="${BWRAP_ARGS[$((_i + 1))]}"
                _dest="${BWRAP_ARGS[$((_i + 2))]}"
                if _is_prefix_of "${_dest}" "${_path}"; then
                    if [[ "${_src}" == "${_dest}" ]]; then
                        _visible=1
                    else
                        _visible=0
                    fi
                fi
                ;;
        esac
        _i=$((_i + 1 + _BWRAP_FLAG_ARITY))
    done
    [[ ${_visible} -eq 1 ]]
}

# _mount_authoring_dir DIR CREATE KIND [SRC]
#   Mount DIR read-write.  CREATE=1 creates it on the host first (skipped
#   under --dry-run, which must not mutate host state) so a first-time user
#   can author into it; CREATE=0 mounts it only when it already exists.  KIND
#   is the word used in warnings (e.g. "skill").
#
#   SRC is the host directory to mount at DIR, for when the tool looks in one
#   place and the files live in another (default: DIR itself).  CREATE and the
#   existence test apply to SRC.
#
#   The directory is resolved with readlink -f and bound whole at its logical
#   path, so entries created inside the sandbox persist on the host.  An
#   entry that is a symlink (a common layout symlinks each skill in from a
#   separate repository) would dangle, since that repository is not
#   otherwise mounted, so each symlink's resolved target is also bound
#   read-write at its own path.  Only that target is exposed, not the
#   repository around it.  A target that resolves into a blocked location, or
#   is a directory containing one, is skipped with a warning.  With a
#   distinct SRC a RELATIVE symlink would resolve against DIR inside the
#   sandbox rather than against SRC, so it is skipped with a warning.
#
#   bwrap cannot bind over a symlink inside a bound directory, so when DIR
#   itself is reached through a symlink (its resolved path differs from DIR)
#   the symlink targets are not bound this way.  That case falls back to
#   binding each entry individually, at its logical path, over a tmpfs
#   directory: existing entries work, but one created inside the sandbox is
#   discarded on exit.
#
#   A DIR that resolves into a blocked location, contains one, or is already
#   covered by an earlier bind (e.g. inside the working directory) is left
#   alone.  Must be called AFTER the tool's own home mount: that mount may be
#   a tmpfs that would hide a directory bound underneath it.
_mount_authoring_dir() {
    local _dir="$1" _create="$2" _kind="$3" _src="${4:-$1}"
    local _canon _entry _real _link

    if [[ ! -e "${_src}" ]]; then
        [[ "${_create}" -eq 1 ]] || return 0
    elif [[ ! -d "${_src}" ]]; then
        return 0
    fi

    # -m, not -f: a directory about to be created may have missing parents
    # too (a fresh ~/.config/opencode), and -f yields nothing for those.
    _canon="$(readlink -m -- "${_src}" 2> /dev/null || true)"
    [[ -n "${_canon}" ]] || return 0
    if _bwrap_bind_blocked "${_canon}"; then
        echo "Warning: ${_kind} directory '${_src}' resolves into or contains a blocked location (${_canon}); not mounted." >&2
        return 0
    fi
    if [[ "${_src}" == "${_dir}" ]]; then
        _path_visible_from_host "${_dir}" && return 0
    fi

    if [[ "${_create}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
        mkdir -p -- "${_canon}"
    fi

    _emit_home_intermediate_dirs "${_dir}" inclusive

    if [[ "${_src}" == "${_dir}" && "${_canon}" != "${_dir}" ]]; then
        [[ -d "${_canon}" ]] || return 0
        for _entry in "${_dir}"/* "${_dir}"/.[!.]* "${_dir}"/..?*; do
            [[ -e "${_entry}" ]] || continue
            _real="$(readlink -f -- "${_entry}" 2> /dev/null || true)"
            [[ -n "${_real}" ]] || continue
            if _bwrap_bind_blocked "${_real}"; then
                echo "Warning: ${_kind} '${_entry}' resolves into or contains a blocked location (${_real}); not mounted." >&2
                continue
            fi
            BWRAP_ARGS+=(--bind "${_real}" "${_entry}")
        done
        _MOUNTED_PREFIXES["${_dir}"]=1
        return 0
    fi

    BWRAP_ARGS+=(--bind "${_canon}" "${_dir}")
    _MOUNTED_PREFIXES["${_dir}"]=1

    [[ -d "${_canon}" ]] || return 0
    for _entry in "${_canon}"/* "${_canon}"/.[!.]* "${_canon}"/..?*; do
        [[ -L "${_entry}" ]] || continue
        _real="$(readlink -f -- "${_entry}" 2> /dev/null || true)"
        [[ -n "${_real}" && -e "${_real}" ]] || continue
        if [[ "${_src}" != "${_dir}" ]]; then
            _link="$(readlink -- "${_entry}" 2> /dev/null || true)"
            if [[ "${_link}" != /* ]]; then
                echo "Warning: ${_kind} '${_entry}' is a relative symlink and would not resolve at '${_dir}'; not mounted." >&2
                continue
            fi
        fi
        _path_visible_from_host "${_real}" && continue
        if _bwrap_bind_blocked "${_real}"; then
            echo "Warning: ${_kind} '${_entry}' resolves into or contains a blocked location (${_real}); not mounted." >&2
            continue
        fi
        _emit_home_intermediate_dirs "${_real}"
        BWRAP_ARGS+=(--bind "${_real}" "${_real}")
        _MOUNTED_PREFIXES["${_real}"]=1
    done
}

# build_authoring_dir_mounts KIND DIR...
#   Mount each DIR read-write, creating it on the host when missing so
#   authoring works out of the box.  Use for the tool's own (primary)
#   location of each kind of definition.  KIND is "skill", "agent",
#   "command" or "prompt".
build_authoring_dir_mounts() {
    local _kind="$1" _dir
    shift
    for _dir in "$@"; do
        _mount_authoring_dir "${_dir}" 1 "${_kind}"
    done
}

# build_authoring_dir_mounts_from KIND SRC DEST
#   Like build_authoring_dir_mounts for one directory, but mount the host
#   directory SRC (created when missing) at DEST, where the tool looks.
build_authoring_dir_mounts_from() {
    _mount_authoring_dir "$3" 1 "$1" "$2"
}

# build_personal_authoring_mounts KIND DIR...
#   Mount additional locations the tool also reads (e.g. ~/.claude/skills or
#   ~/.agents/skills) read-write.  Missing directories are skipped, not
#   created.
build_personal_authoring_mounts() {
    local _kind="$1" _dir
    shift
    for _dir in "$@"; do
        _mount_authoring_dir "${_dir}" 0 "${_kind}"
    done
}

# ── NSLS-II software (read-only) ────────────────────────────────
# Only bind if the directory exists on the host system.
build_nsls2_mount() {
    if [[ -d /nsls2/software/bin ]]; then
        BWRAP_ARGS+=(
            --dir /nsls2/software
            --ro-bind /nsls2/software/bin /nsls2/software/bin
        )
    fi
}

# ── Dynamic tool mounts (tool binary, pixi, npm global) ──────────
# Pre-populate _MOUNTED_PREFIXES with every directory tree that is
# already unconditionally mounted above so _mount_ro_dir_if_needed
# skips them without re-mounting.
build_dynamic_tool_mounts() {
    local _preloaded
    for _preloaded in \
            /usr /bin /sbin /lib /lib64 \
            /proc /dev /tmp \
            "${PIXI_HOME_DIR}" \
            "${_HOME}/bin" \
            /nsls2/software/bin; do
        [[ -e "${_preloaded}" ]] && _MOUNTED_PREFIXES["${_preloaded}"]=1
    done

    # Resolve each tool binary dynamically.  resolve_and_mount_tool handles
    # the symlink chain and detects npm-installed binaries automatically,
    # delegating to _mount_npm_global_prefix for those.
    local _tool_bin
    for _tool_bin in \
            "${_TOOL_BIN}" \
            "$(command -v pixi 2> /dev/null || true)"; do
        [[ -n "${_tool_bin}" ]] && resolve_and_mount_tool "${_tool_bin}"
    done

    # npm global prefix: mount even when the tool is not npm-installed so
    # that any globally-installed Node.js tools are available in the sandbox.
    _mount_npm_global_prefix

    finalize_sandbox_path
}

# ── OpenTUI inside Zellij ────────────────────────────────────────
# build_opentui_zellij_env  (OpenTUI tools only: bwopencode, bwopencode2)
#   Must run AFTER build_env_vars, whose --setenv TERM this overrides.
#
#   OpenTUI repaints only the cells it thinks changed.  For tmux, GNU Screen
#   and a TERM containing "alacritty" it moves the cursor explicitly after
#   wide characters, so one width mismatch with the multiplexer cannot shift
#   the rest of a line.  It never does that for Zellij, which leaves stale
#   regions on the screen until the window is resized.  The check reads TERM
#   when the TUI starts, so inside Zellij the sandbox gets TERM=alacritty
#   (the terminfo entry is in /usr/share/terminfo) and COLORTERM=truecolor,
#   because "alacritty" lacks the "256color" that OpenTUI uses to detect
#   colour depth.  OpenCode sets TERM back to xterm-256color for the commands
#   it runs.  Only the Zellij case changes.
#
#   BWRAP_OPENTUI_TERM   unset: alacritty; a value: use it; set but empty:
#                        keep TERM as it is.
build_opentui_zellij_env() {
    [[ -n "${ZELLIJ:-}" ]] || return 0

    local _term="${BWRAP_OPENTUI_TERM-alacritty}"
    [[ -n "${_term}" ]] || return 0
    if [[ ! "${_term}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        echo "Warning: ignoring BWRAP_OPENTUI_TERM='${_term}' (not a plain terminal name)" >&2
        return 0
    fi

    BWRAP_ARGS+=(--setenv TERM "${_term}")
    if [[ -z "${COLORTERM:-}" ]]; then
        SANDBOX_ENV+=("COLORTERM=truecolor")
    fi
}

# ── Environment variables ────────────────────────────────────────
# The sandbox environment is exactly bwrap's environment, which
# launch_sandbox builds from scratch with `env -i` (a few base variables plus
# SANDBOX_ENV), so no host variable reaches it unless passed through here.
# bwrap runs WITHOUT --clearenv so that environment is handed to the sandbox;
# the --setenv entries below are applied on top of it and take precedence.
build_env_vars() {
    # Always set
    BWRAP_ARGS+=(
        --setenv HOME "${_HOME}"
        --setenv USER "${_USER}"
        --setenv LOGNAME "${_USER}"
        --setenv SHELL "${SANDBOX_SHELL}"
        --setenv PATH "${SANDBOX_PATH}"
        --setenv PWD "${_PWD}"
        --setenv TERM "${TERM:-xterm-256color}"
    )

    # Terminal
    pass_through_if_set COLORTERM
    pass_through_if_set TERM_PROGRAM

    # Zellij: these only identify the session (no socket is mounted), so
    # OpenTUI can tell it runs inside Zellij.  Zellij drops zero-width
    # code points (emoji variation selectors, ZWJ) and has no grapheme width
    # mode, so OpenTUI's default width counting drifts from Zellij's and the
    # screen is left garbled until a resize.  Count each code point on its
    # own (OPENTUI_FORCE_WCWIDTH, which OpenTUI only tests for presence)
    # unless the user set it themselves.
    pass_through_if_set ZELLIJ
    pass_through_if_set ZELLIJ_SESSION_NAME
    pass_through_if_set ZELLIJ_PANE_ID
    if [[ -n "${OPENTUI_FORCE_WCWIDTH+x}" ]]; then
        SANDBOX_ENV+=("OPENTUI_FORCE_WCWIDTH=${OPENTUI_FORCE_WCWIDTH}")
    elif [[ -n "${ZELLIJ:-}" ]]; then
        SANDBOX_ENV+=("OPENTUI_FORCE_WCWIDTH=1")
    fi

    # Locale
    pass_through_if_set LANG
    pass_through_if_set LC_ALL
    pass_through_if_set LC_CTYPE
    pass_through_if_set LC_MESSAGES
    pass_through_if_set LC_COLLATE
    pass_through_if_set LC_NUMERIC
    pass_through_if_set LC_TIME
    pass_through_if_set LC_MONETARY

    # XDG (only if explicitly set by user)
    pass_through_if_set XDG_CONFIG_HOME
    pass_through_if_set XDG_DATA_HOME
    pass_through_if_set XDG_CACHE_HOME

    # Tool-specific
    pass_through_if_set CCACHE_DIR
    pass_through_if_set PIXI_HOME
    pass_through_if_set NPM_CONFIG_CACHE

    # Editor
    pass_through_if_set EDITOR
    pass_through_if_set VISUAL

    # Proxy
    pass_through_if_set HTTP_PROXY
    pass_through_if_set HTTPS_PROXY
    pass_through_if_set NO_PROXY
    pass_through_if_set http_proxy
    pass_through_if_set https_proxy
    pass_through_if_set no_proxy

    # Git identity
    pass_through_if_set GIT_AUTHOR_NAME
    pass_through_if_set GIT_AUTHOR_EMAIL
    pass_through_if_set GIT_COMMITTER_NAME
    pass_through_if_set GIT_COMMITTER_EMAIL
}

# ═══════════════════════════════════════════════════════════════════
# Shared launch functions
# ═══════════════════════════════════════════════════════════════════

# Resolve the `env` binary to an absolute path, immune to PATH shadowing.
#
# env is the very first program in the exec chain used by launch_sandbox;
# if it is shadowed (e.g., by a user script earlier on PATH named "env"),
# nothing downstream — bwrap, the tool itself — gets a chance to run
# correctly.  Users almost never have a legitimate reason to provide a
# local override of `env`, so we prefer the canonical /usr/bin/env.
#
# Resolution order:
#   1. /usr/bin/env if it exists and is executable (FHS-mandated location,
#      present on every Linux distro this script targets).
#   2. Fallback to `command -v env` for exotic systems (NixOS, etc.).
#      Note: this fallback IS susceptible to PATH shadowing — but if the
#      canonical location is absent, we have no better option.
#
# Echoes the resolved path to stdout.  Exits with an error if neither
# strategy finds an executable env.
resolve_env_bin() {
    if [[ -x /usr/bin/env ]]; then
        echo /usr/bin/env
        return 0
    fi
    local _env_bin
    _env_bin="$(command -v env 2> /dev/null || true)"
    if [[ -n "${_env_bin}" ]] && [[ -x "${_env_bin}" ]]; then
        echo "${_env_bin}"
        return 0
    fi
    echo "Error: cannot locate the 'env' binary (/usr/bin/env missing and no env on PATH)." >&2
    exit 1
}

# _bwrap_flag_arity FLAG
#   Set _BWRAP_FLAG_ARITY to the number of value arguments that bwrap flag
#   FLAG consumes (0, 1, or 2).  Used to walk BWRAP_ARGS (print_dry_run,
#   build_extra_path_mounts) grouping flags with their values WITHOUT
#   guessing from the value's leading characters — a path value that happens
#   to start with "--" (e.g. a user-supplied --ro-path) must not be mistaken
#   for a new flag.  Only the flags this library actually emits are listed;
#   the default of 1 is a safe fallback for any single-value flag.  Sets a
#   global rather than echoing so the walks do not fork once per argument.
_BWRAP_FLAG_ARITY=1
_bwrap_flag_arity() {
    case "$1" in
        --unshare-* | --share-net | --die-with-parent | --new-session | \
            --clearenv | --as-pid-1)
            _BWRAP_FLAG_ARITY=0
            ;;
        --ro-bind | --ro-bind-try | --bind | --bind-try | --dev-bind | \
            --dev-bind-try | --symlink | --setenv | \
            --file | --bind-data | --ro-bind-data)
            _BWRAP_FLAG_ARITY=2
            ;;
        --dir | --tmpfs | --proc | --dev | --unsetenv | --chdir | --hostname)
            _BWRAP_FLAG_ARITY=1
            ;;
        *)
            _BWRAP_FLAG_ARITY=1
            ;;
    esac
}

# _is_secret_env_name NAME
#   Return 0 if NAME looks like it holds a secret (case-insensitive match on
#   KEY, TOKEN, PASSWORD, SECRET or CREDENTIAL).  Used only by print_dry_run
#   to redact printed --setenv values; the real launch path never calls it.
_is_secret_env_name() {
    local _upper="${1^^}"
    case "${_upper}" in
        *KEY* | *TOKEN* | *PASSWORD* | *SECRET* | *CREDENTIAL*) return 0 ;;
        *) return 1 ;;
    esac
}

print_dry_run() {
    verify_n2c_state_not_exposed
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    # Mirror the exact invocation used by launch_sandbox:
    #   exec <env_bin> -i <base vars> <SANDBOX_ENV> <bwrap_bin> <BWRAP_ARGS> -- <_TOOL_CMD> <TOOL_ARGS>
    # Values of secret-looking variables (_is_secret_env_name) are printed as
    # REDACTED, on the env line and in --setenv; only the printed text changes.
    printf "exec %s -i \\\\\n" "${_ENV_BIN}"
    printf "  HOME=%q \\\\\n"    "${_HOME}"
    printf "  USER=%q \\\\\n"    "${_USER}"
    printf "  LOGNAME=%q \\\\\n" "${_USER}"
    printf "  PATH=%q \\\\\n"    "/usr/bin:/bin"
    local _entry _name
    for _entry in ${SANDBOX_ENV[@]+"${SANDBOX_ENV[@]}"}; do
        _name="${_entry%%=*}"
        if _is_secret_env_name "${_name}"; then
            printf "  %s='REDACTED' \\\\\n" "${_name}"
        else
            printf "  %s=%q \\\\\n" "${_name}" "${_entry#*=}"
        fi
    done
    printf "  %s \\\\\n" "${_BWRAP_BIN}"

    # Print bwrap arguments one flag-plus-values per line.  Each flag's
    # value count comes from _bwrap_flag_arity, so a value beginning with
    # "--" is grouped with its flag instead of being misread as a new flag.
    # Values are %q-quoted so a path containing a quote, space or other
    # special character still yields a valid, pasteable command.
    local i=0 arg _arity _j
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        arg="${BWRAP_ARGS[$i]}"
        _bwrap_flag_arity "${arg}"
        _arity="${_BWRAP_FLAG_ARITY}"
        printf "    %q" "${arg}"
        i=$((i + 1))
        for ((_j = 0; _j < _arity && i < ${#BWRAP_ARGS[@]}; _j++)); do
            # Redact the VALUE of secret-looking --setenv variables (only the
            # printed text changes; BWRAP_ARGS keeps the real values).
            if [[ "${arg}" == "--setenv" && "${_j}" -eq 1 ]] &&
                _is_secret_env_name "${BWRAP_ARGS[$((i - 1))]}"; then
                printf " 'REDACTED'"
            else
                printf " %q" "${BWRAP_ARGS[$i]}"
            fi
            i=$((i + 1))
        done
        printf " \\\\\n"
    done
    printf "    --"
    local _cmd_part
    for _cmd_part in "${_TOOL_CMD[@]}"; do printf " %q" "${_cmd_part}"; done
    local _arg
    for _arg in ${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}; do printf " %q" "${_arg}"; done
    printf "\n"
    exit 0
}

# Launch bwrap itself with a scrubbed environment so /proc/1/environ
# does not leak host variables (SSH_AUTH_SOCK, DBUS_SESSION_BUS_ADDRESS, etc.).
#
# Forwarded values (SANDBOX_ENV, which includes API keys and tokens) travel in
# bwrap's environment, not on its command line: /proc/<pid>/cmdline of the
# long-running bwrap process is readable by every local user (`ps`), while
# /proc/<pid>/environ is readable only by its owner.  They are on `env`'s own
# command line only for the instant before it execs bwrap.
#
# `env` is resolved via resolve_env_bin (prefers /usr/bin/env) rather than
# via PATH lookup at exec time — this prevents a user shell script named
# "env" earlier on PATH from hijacking the launch.  See resolve_env_bin.
launch_sandbox() {
    verify_n2c_state_not_exposed
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    exec "${_ENV_BIN}" -i \
        HOME="${_HOME}" \
        USER="${_USER}" \
        LOGNAME="${_USER}" \
        PATH="/usr/bin:/bin" \
        ${SANDBOX_ENV[@]+"${SANDBOX_ENV[@]}"} \
        "${_BWRAP_BIN}" "${BWRAP_ARGS[@]}" -- "${_TOOL_CMD[@]}" ${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}
}
