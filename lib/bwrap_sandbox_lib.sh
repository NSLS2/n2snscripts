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
#   - Binary resolution (resolve_tool_binary) setting _TOOL_BIN and _TOOL_CMD
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
#   - 0.5.0+: --clearenv (fallback: manual --unsetenv for each host var)
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

# Tool binary (set by tool-specific resolve_tool_binary)
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

# bwrap capability flags (set by detect_bwrap_capabilities)
HAS_CLEARENV=0
HAS_BIND_OVER_RO=0

# Kernel capability flags (set by detect_kernel_capabilities)
KERNEL_HAS_TIOCSTI_CAP_GUARD=0

# Git include tracking (used by parse_git_includes)
declare -A _GIT_INCLUDE_SEEN=()
GIT_INCLUDE_PATHS=()

# Working directory state (set by build_workdir_mount)
_BIND_DIR=""
_GIT_ROOT=""

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
#   0.5.0 - added --clearenv
#   0.6.3 - bind over ro-bind works (can mask binaries inside /usr)
detect_bwrap_capabilities() {
    local _bwrap_ver
    _bwrap_ver="$(bwrap --version)"
    _bwrap_ver="${_bwrap_ver##* }"            # "bubblewrap 0.11.0" -> "0.11.0"

    # --clearenv: Start with an empty environment (added in 0.5.0)
    # Fallback: manually unset all host env vars with --unsetenv
    HAS_CLEARENV=0
    if _version_ge "${_bwrap_ver}" "0.5.0"; then HAS_CLEARENV=1; fi

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

# ── Dynamic mount helpers ────────────────────────────────────────
# _MOUNTED_PREFIXES: tracks directory trees already covered by a bwrap
# bind so we never emit duplicate (or redundant sub-path) mounts.
# Keys are canonical paths; value is always 1.
# Pre-populated with unconditional mounts in build_dynamic_tool_mounts.

# _get_npm_prefix
#   Echo the npm global prefix (`npm prefix -g`), caching the result so the
#   subprocess is forked at most once per run even when several symlinked
#   tools are resolved.  Echoes the empty string if npm is not installed or
#   the lookup fails.
_get_npm_prefix() {
    if [[ "${_NPM_PREFIX_RESOLVED}" -eq 0 ]]; then
        _NPM_PREFIX="$(npm prefix -g 2> /dev/null || true)"
        _NPM_PREFIX_RESOLVED=1
    fi
    printf '%s' "${_NPM_PREFIX}"
}

# resolve_real_tool_binary TOOL_NAME
#   Return the path to the real (non-wrapper) binary for TOOL_NAME.
#
#   Problem: on managed hosts the dotfiles wrapper (e.g. ~/.local/bin/opencode)
#   precedes /usr/local/bin on PATH.  `command -v opencode` therefore resolves
#   to the wrapper, not the npm-installed binary.  resolve_and_mount_tool then
#   adds the wrapper's directory to SANDBOX_PATH and bind-mounts it into the
#   --clearenv sandbox.  Inside the sandbox the wrapper is visible on PATH, but
#   the env vars it needs (N2SNSCRIPTS_LIB, AZURE_*) are stripped, so it fails
#   with "cannot locate gpg-passwd.sh" — the double-invocation bug.
#
#   Fix: if `command -v TOOL_NAME` resolves to a dotfiles wrapper symlink
#   (detected by checking whether `readlink -f candidate` contains
#   "/config/scripts/"), skip it and return the npm-installed binary from
#   <npm_prefix>/bin/TOOL_NAME instead.  If the npm binary is also absent,
#   that means the real tool is not installed — exit with an error rather
#   than silently returning the wrapper (which would recreate the bug).
#
#   If the candidate is NOT a dotfiles wrapper (system package, already the
#   correct npm binary, etc.) it is returned as-is so non-npm tools are
#   unaffected.
#
#   Outputs the resolved path on stdout.  Callers assign with $(...).
resolve_real_tool_binary() {
    local tool_name="$1"
    local candidate real_candidate npm_prefix npm_bin

    candidate="$(command -v "${tool_name}" 2> /dev/null || true)"
    if [[ -z "${candidate}" ]]; then
        # Tool not on PATH at all — callers handle the empty-string case.
        printf '%s' "${candidate}"
        return 0
    fi

    # Detect dotfiles wrapper: the symlink target contains /config/scripts/
    # (the dotfiles convention for per-tool wrapper scripts).
    real_candidate="$(readlink -f "${candidate}" 2> /dev/null || printf '%s' "${candidate}")"
    if [[ "${real_candidate}" == */config/scripts/* ]]; then
        # candidate is a dotfiles wrapper — resolve to the real npm binary.
        npm_prefix="$(_get_npm_prefix)"
        npm_bin="${npm_prefix:+${npm_prefix}/bin/${tool_name}}"
        if [[ -n "${npm_bin}" && -x "${npm_bin}" ]]; then
            printf '%s' "${npm_bin}"
            return 0
        fi
        # The real binary is not installed.  Returning the wrapper would
        # recreate the double-invocation bug; error out instead.
        printf 'resolve_real_tool_binary: %s resolves to a dotfiles wrapper but %s is not installed or not executable.\n' \
            "${candidate}" "${tool_name}" >&2
        return 1
    fi

    # Not a dotfiles wrapper — return the candidate unchanged.
    printf '%s' "${candidate}"
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
    [[ "${dir}" == "${_HOME}"/* ]] || return 0
    local _rel="${dir#"${_HOME}"/}"
    local _accum="${_HOME}"
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
#   Calls _check_path_safe before emitting any mount — aborts if DIR
#   resolves into a blocked path (e.g. a tool binary that symlinks into
#   ~/.ssh or a misconfigured npm prefix pointing at $HOME).
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

    # Safety check before emitting the mount.  DIR is already a real
    # directory path (callers pass dirname() of a resolved binary or a
    # known path), so no additional readlink -f is needed.
    _check_path_safe "${dir}" "dynamic mount"

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
        npm_prefix="$(_get_npm_prefix)"
        if [[ -n "${npm_prefix}" ]] && [[ "${real_path}" == "${npm_prefix}"/* ]]; then
            # npm-installed: mount the whole prefix so lib/node_modules is reachable.
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
        npm_prefix="$(_get_npm_prefix)"
    fi
    [[ -n "${npm_prefix}" ]] && [[ -d "${npm_prefix}" ]] || return 0

    # Canonicalise before the safety check so symlinks in the prefix path
    # are resolved (npm itself may return a non-canonical path on some systems).
    local npm_prefix_canon
    npm_prefix_canon="$(readlink -f "${npm_prefix}" 2> /dev/null || echo "${npm_prefix}")"
    _check_path_safe "${npm_prefix_canon}" "npm global prefix"

    _mount_ro_dir_if_needed "${npm_prefix_canon}"
    _EXTRA_PATH_DIRS+=("${npm_prefix_canon}/bin")
}

# ── Git include parser ───────────────────────────────────────────

parse_git_includes() {
    local config_file="$1"
    [[ -f "${config_file}" ]] || return 0

    # Git resolves relative include paths relative to the location of
    # the config file (the symlink path, NOT the resolved target).
    local config_dir="${config_file%/*}"

    # Extract path values from [include] and [includeIf "..."] sections.
    # Matches lines like:  path = /some/path  or  path = ~/relative
    # Pure bash — no grep/sed/xargs subprocesses.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*) ]] || continue
        local path_val="${BASH_REMATCH[1]}"

        # Trim trailing whitespace
        path_val="${path_val%"${path_val##*[![:space:]]}"}"
        [[ -z "${path_val}" ]] && continue

        # Resolve ~/ prefix
        path_val="${path_val/#\~/${_HOME}}"

        # Resolve relative paths (relative to the config file's directory)
        if [[ "${path_val}" != /* ]]; then
            path_val="${config_dir}/${path_val}"
        fi

        # Resolve symlinks and canonicalize
        local resolved
        if [[ -L "${path_val}" ]]; then
            resolved="$(readlink -f "${path_val}" 2> /dev/null || echo "${path_val}")"
        else
            resolved="${path_val}"
        fi

        # Deduplicate
        if [[ -e "${resolved}" ]] && [[ -z "${_GIT_INCLUDE_SEEN["${resolved}"]:-}" ]]; then
            _GIT_INCLUDE_SEEN["${resolved}"]=1
            GIT_INCLUDE_PATHS+=("${resolved}")
        fi
    done < "${config_file}"
}

# Parse the standard git config files for include directives.
parse_all_git_includes() {
    if [[ -f "${_HOME}/.gitconfig" ]]; then
        parse_git_includes "${_HOME}/.gitconfig"
    fi
    if [[ -f "${XDG_CONFIG_HOME}/git/config" ]]; then
        parse_git_includes "${XDG_CONFIG_HOME}/git/config"
    fi
}

# ── Env var passthrough helper ───────────────────────────────────

pass_through_if_set() {
    local var_name="$1"
    local var_val="${!var_name:-}"
    if [[ -n "${var_val}" ]]; then
        BWRAP_ARGS+=(--setenv "${var_name}" "${var_val}")
    fi
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

# _check_path_safe CANON CONTEXT
#   Assert that the already-resolved canonical path CANON is safe to mount
#   into the sandbox.  Exits 1 with a descriptive error if it is not.
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

    # ── Ancestor-of-home check ───────────────────────────────────
    # Reject if canon IS $HOME or is a directory that contains $HOME
    # (i.e. /, /home, the username's parent dir, etc.).
    # "_is_prefix_of canon _HOME" means: canon is a prefix of _HOME.
    if _is_prefix_of "${canon}" "${_HOME}"; then
        echo "Error: ${context} '${canon}' is \$HOME or an ancestor of \$HOME." >&2
        echo "       Refusing to mount — this would expose the entire home tree." >&2
        exit 1
    fi

    # ── Sensitive-subtree checks ─────────────────────────────────
    # XDG_DATA_HOME is set by resolve_common_paths, which is always called
    # before any function that invokes _check_path_safe.
    local _blocked_prefix
    local _BLOCKED_PREFIXES=(
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
        # System
        "/root"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/sudoers.d"
    )
    for _blocked_prefix in "${_BLOCKED_PREFIXES[@]}"; do
        if _is_prefix_of "${_blocked_prefix}" "${canon}"; then
            echo "Error: ${context} '${canon}' is inside the blocked path '${_blocked_prefix}'." >&2
            echo "       Refusing to mount." >&2
            exit 1
        fi
    done
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
#     1. Expand leading ~/ then resolve to canonical path via readlink -f.
#     2. Verify the path exists on the host.
#     3. Delegate safety checks to _check_path_safe.
validate_extra_path() {
    local raw_path="$1"
    local mode="$2"

    # Expand a leading ~/ to $HOME (readlink -f won't do this for us).
    local expanded_path="${raw_path/#\~/${_HOME}}"

    # Resolve to canonical path (follows symlinks, removes . and ..).
    local canon
    canon="$(readlink -f "${expanded_path}" 2> /dev/null || true)"

    # ── Existence check ──────────────────────────────────────────
    if [[ -z "${canon}" ]] || ! [[ -e "${canon}" ]]; then
        echo "Error: --${mode}-path '${raw_path}': path does not exist." >&2
        exit 1
    fi

    # ── Safety check ─────────────────────────────────────────────
    _check_path_safe "${canon}" "--${mode}-path"

    # All checks passed — return the canonical path.
    echo "${canon}"
}

# ── Extra user path mounts ───────────────────────────────────────

# build_extra_path_mounts
#   Mount all paths accumulated in EXTRA_RO_PATHS and EXTRA_RW_PATHS.
#   Each path is validated by validate_extra_path before mounting.
#
#   Read-only paths: use _mount_ro_dir_if_needed for directories
#     (deduplication via _MOUNTED_PREFIXES); for files, emit --ro-bind
#     directly (no dedup needed — an individual file bind never subsumes
#     a directory tree).
#
#   Read-write paths: emit --bind directly for both files and directories.
#     For paths under $HOME, intermediate --dir entries are created first
#     so the bind mount point exists in the tmpfs.
#
#   Must be called AFTER build_dynamic_tool_mounts (which pre-populates
#   _MOUNTED_PREFIXES) and AFTER build_home_tmpfs (which creates the
#   $HOME tmpfs that intermediate --dir entries populate).
build_extra_path_mounts() {
    local _raw_path _canon _target

    # ── Read-only extra paths ────────────────────────────────────
    for _raw_path in "${EXTRA_RO_PATHS[@]+"${EXTRA_RO_PATHS[@]}"}"; do
        _canon="$(validate_extra_path "${_raw_path}" "ro")"

        if [[ -d "${_canon}" ]]; then
            # Directories: go through the dedup helper.
            _mount_ro_dir_if_needed "${_canon}"
        else
            # Files: --ro-bind directly.  Pre-create the file's parent
            # directory chain if it lives under $HOME (the tmpfs has no
            # subdirs yet); the file itself is the bind mount point.
            _emit_home_intermediate_dirs "${_canon%/*}" inclusive
            BWRAP_ARGS+=(--ro-bind "${_canon}" "${_canon}")
        fi
    done

    # ── Read-write extra paths ───────────────────────────────────
    for _raw_path in "${EXTRA_RW_PATHS[@]+"${EXTRA_RW_PATHS[@]}"}"; do
        _canon="$(validate_extra_path "${_raw_path}" "rw")"

        # Pre-create the intermediate --dir chain when the path is under
        # $HOME.  For a directory the chain includes the target itself (the
        # subsequent --bind lands on top of that --dir); for a file the
        # chain stops at the parent directory.
        if [[ -d "${_canon}" ]]; then
            _target="${_canon}"
        else
            _target="${_canon%/*}"
        fi
        _emit_home_intermediate_dirs "${_target}" inclusive

        BWRAP_ARGS+=(--bind "${_canon}" "${_canon}")
    done
}

# ── Path resolution ──────────────────────────────────────────────

resolve_common_paths() {
    _HOME="${HOME}"
    _PWD="${PWD}"

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
finalize_sandbox_path() {
    local _extra_dir
    for _extra_dir in "${_EXTRA_PATH_DIRS[@]+"${_EXTRA_PATH_DIRS[@]}"}"; do
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
    # On merged-/usr systems /bin, /sbin, /usr/bin, /usr/sbin all point to the
    # same directory.  Multiple prefixes therefore resolve to the same realpath,
    # which would emit duplicate --ro-bind /dev/null <path> flags.  Track which
    # real paths have already been masked and skip repeats.
    declare -A _MASKED_REAL_SEEN=()
    local _bin _prefix _candidate _real
    for _bin in "${_MASKED_BINS[@]}"; do
        # Search well-known prefixes covering RHEL, Debian, and Arch layouts.
        for _prefix in /usr/bin /usr/sbin /usr/lib/openssh /usr/libexec/openssh \
                       /bin /sbin; do
            _candidate="${_prefix}/${_bin}"
            # -e follows symlinks: true only if the full chain resolves to a
            # real file.  Broken alternatives entries (dangling symlinks) are
            # skipped, which is correct — there is no binary to mask.
            [[ -e "${_candidate}" ]] || continue

            # On RHEL/Debian the binary is often a symlink:
            #   /usr/bin/nc -> /etc/alternatives/nc -> /usr/bin/ncat
            # bwrap processes --ro-bind arguments in order.  At the point this
            # bind is applied, /etc/alternatives has not yet been mounted in the
            # sandbox, so bwrap cannot resolve the intermediate symlink and
            # reports "Can't create file at /usr/bin/nc".
            #
            # Fix: resolve to the canonical (symlink-free) path on the host and
            # use *that* as the bwrap destination.  The real file is always
            # directly accessible under /usr once --ro-bind /usr /usr is applied.
            _real="$(realpath "${_candidate}")"
            [[ -n "${_MASKED_REAL_SEEN[${_real}]:-}" ]] && continue
            _MASKED_REAL_SEEN["${_real}"]=1
            BWRAP_ARGS+=(--ro-bind /dev/null "${_real}")
        done
    done
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

    # Guard: reject dangerous working / git-root directories via the same
    # rules applied to --ro-path / --rw-path.  This catches $HOME itself,
    # ancestors of $HOME (/home, /), /root, ~/.ssh, and all other blocked
    # prefixes.  _BIND_DIR comes from git rev-parse or $PWD — both are
    # already canonical paths, so no readlink -f step is needed here.
    _check_path_safe "${_BIND_DIR}" "working directory"

    # If the bind dir is under HOME, create intermediate directories in the
    # tmpfs so the bind mount point is reachable.  _BIND_DIR is itself the
    # bind mount point, so only its ancestors are pre-created.
    _emit_home_intermediate_dirs "${_BIND_DIR}"
    BWRAP_ARGS+=(
        --bind "${_BIND_DIR}" "${_BIND_DIR}"
    )
}

# ── Git config (read-only) ──────────────────────────────────────
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
    if [[ -d "${XDG_CONFIG_HOME}/git" ]]; then
        # XDG_CONFIG_HOME is already validated by resolve_common_paths;
        # no additional check needed here.
        BWRAP_ARGS+=(--ro-bind "${XDG_CONFIG_HOME}/git" "${XDG_CONFIG_HOME}/git")
    fi

    # Git include files (read-only).
    # parse_git_includes already resolved symlinks in include paths via
    # readlink -f.  Check each resolved include path before mounting —
    # a git config could contain  path = ~/.ssh/id_rsa  or similar.
    declare -A _GIT_INC_DIRS_SEEN=()
    local inc_path local_parent
    for inc_path in "${GIT_INCLUDE_PATHS[@]+"${GIT_INCLUDE_PATHS[@]}"}"; do
        _check_path_safe "${inc_path}" "git include path"
        # Ensure parent directory exists as a mount point (deduplicated)
        local_parent="${inc_path%/*}"
        if [[ -z "${_GIT_INC_DIRS_SEEN["${local_parent}"]:-}" ]]; then
            _GIT_INC_DIRS_SEEN["${local_parent}"]=1
            BWRAP_ARGS+=(--dir "${local_parent}")
        fi
        BWRAP_ARGS+=(--ro-bind-try "${inc_path}" "${inc_path}")
    done
}

# ── Pixi cache (read-write) + config (read-only) ────────────────
build_pixi_mounts() {
    if [[ -d "${PIXI_HOME_DIR}" ]]; then
        BWRAP_ARGS+=(--bind "${PIXI_HOME_DIR}" "${PIXI_HOME_DIR}")
    fi

    # Pixi checks multiple config locations; bind any that exist.
    if [[ -f "${XDG_CONFIG_HOME}/pixi/config.toml" ]]; then
        BWRAP_ARGS+=(
            --dir "${XDG_CONFIG_HOME}/pixi"
            --ro-bind "${XDG_CONFIG_HOME}/pixi/config.toml" "${XDG_CONFIG_HOME}/pixi/config.toml"
        )
    fi
    if [[ -f "${_HOME}/.pixi/config.toml" ]]; then
        # Already available via the pixi overlay, but if the overlay is not
        # present (dir doesn't exist), bind it explicitly.
        if [[ ! -d "${PIXI_HOME_DIR}" ]]; then
            BWRAP_ARGS+=(--ro-bind "${_HOME}/.pixi/config.toml" "${_HOME}/.pixi/config.toml")
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

# ── Environment variables ────────────────────────────────────────
# Start from a clean environment and only pass through what we need.
build_env_vars() {
    if [[ "${HAS_CLEARENV}" -eq 1 ]]; then
        BWRAP_ARGS+=(--clearenv)
    else
        # Fallback for bwrap < 0.5.0: manually unset all host env vars.
        # We use compgen -e to list all exported vars and unset each one.
        # Note: we already exec with env -i, but --unsetenv ensures any
        # vars inherited through other means are also cleared.
        #
        # Read line-by-line (not `for x in $(...)`) so names are not
        # word-split on IFS, and skip anything that is not a portable
        # shell identifier — bash exports function definitions under names
        # like `BASH_FUNC_module%%`, which would become invalid --unsetenv
        # arguments.
        #
        # On HPC login nodes the exported-var count can reach the hundreds;
        # each becomes a separate --unsetenv pair, so this path can produce
        # a long bwrap command line.  That is unavoidable here and harmless
        # (well under ARG_MAX); the modern --clearenv path above avoids it.
        local _envvar
        while IFS= read -r _envvar; do
            [[ "${_envvar}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            BWRAP_ARGS+=(--unsetenv "${_envvar}")
        done < <(compgen -e)
    fi

    # Always set
    BWRAP_ARGS+=(
        --setenv HOME "${_HOME}"
        --setenv USER "${USER}"
        --setenv LOGNAME "${USER}"
        --setenv SHELL "${SANDBOX_SHELL}"
        --setenv PATH "${SANDBOX_PATH}"
        --setenv PWD "${_PWD}"
        --setenv TERM "${TERM:-xterm-256color}"
    )

    # Terminal
    pass_through_if_set COLORTERM
    pass_through_if_set TERM_PROGRAM

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
#   Echo the number of value arguments that bwrap flag FLAG consumes (0, 1,
#   or 2).  Used by print_dry_run to group flags with their values WITHOUT
#   guessing from the value's leading characters — a path value that happens
#   to start with "--" (e.g. a user-supplied --ro-path) must not be mistaken
#   for a new flag.  Only the flags this library actually emits are listed;
#   the default of 1 is a safe fallback for any single-value flag.
_bwrap_flag_arity() {
    case "$1" in
        --unshare-* | --share-net | --die-with-parent | --new-session | \
            --clearenv | --as-pid-1)
            echo 0
            ;;
        --ro-bind | --ro-bind-try | --bind | --bind-try | --dev-bind | \
            --dev-bind-try | --symlink | --setenv | \
            --file | --bind-data | --ro-bind-data)
            echo 2
            ;;
        --dir | --tmpfs | --proc | --dev | --unsetenv | --chdir | --hostname)
            echo 1
            ;;
        *)
            echo 1
            ;;
    esac
}

print_dry_run() {
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    # Mirror the exact invocation used by launch_sandbox:
    #   exec <env_bin> -i <vars> <bwrap_bin> <BWRAP_ARGS> -- <_TOOL_CMD> <TOOL_ARGS>
    printf "exec %s -i \\\\\n" "${_ENV_BIN}"
    printf "  HOME=%q \\\\\n"    "${_HOME}"
    printf "  USER=%q \\\\\n"    "${USER}"
    printf "  LOGNAME=%q \\\\\n" "${USER}"
    printf "  PATH=%q \\\\\n"    "/usr/bin:/bin"
    printf "  LANG=%q \\\\\n"    "${LANG:-C.UTF-8}"
    printf "  LC_CTYPE=%q \\\\\n" "${LC_CTYPE:-C.UTF-8}"
    printf "  %s \\\\\n" "${_BWRAP_BIN}"

    # Print bwrap arguments one flag-plus-values per line.  Each flag's
    # value count comes from _bwrap_flag_arity, so a value beginning with
    # "--" is grouped with its flag instead of being misread as a new flag.
    local i=0 arg _arity _j
    while [[ $i -lt ${#BWRAP_ARGS[@]} ]]; do
        arg="${BWRAP_ARGS[$i]}"
        _arity="$(_bwrap_flag_arity "${arg}")"
        printf "    %s" "${arg}"
        i=$((i + 1))
        for ((_j = 0; _j < _arity && i < ${#BWRAP_ARGS[@]}; _j++)); do
            printf " '%s'" "${BWRAP_ARGS[$i]}"
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
# `env` is resolved via resolve_env_bin (prefers /usr/bin/env) rather than
# via PATH lookup at exec time — this prevents a user shell script named
# "env" earlier on PATH from hijacking the launch.  See resolve_env_bin.
launch_sandbox() {
    local _BWRAP_BIN _ENV_BIN
    _BWRAP_BIN="$(command -v bwrap)"
    _ENV_BIN="$(resolve_env_bin)"

    exec "${_ENV_BIN}" -i \
        HOME="${_HOME}" \
        USER="${USER}" \
        LOGNAME="${USER}" \
        PATH="/usr/bin:/bin" \
        LANG="${LANG:-C.UTF-8}" \
        LC_CTYPE="${LC_CTYPE:-C.UTF-8}" \
        "${_BWRAP_BIN}" "${BWRAP_ARGS[@]}" -- "${_TOOL_CMD[@]}" ${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}
}
