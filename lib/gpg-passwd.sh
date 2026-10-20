#!/usr/bin/env bash
# gpg-passwd.sh — Decrypt GPG-encrypted env files into the current shell.
#
# Provides:
#   decrypt_env_file <gpg_file> [required_var ...]
#       Decrypt a gpg-encrypted env file and eval its contents in the
#       current shell. When required vars are listed, verify they are
#       non-empty after the eval.
#
#       Returns:
#         0 - success, or file is unreadable (warning emitted; caller may
#             continue)
#         2 - decrypt succeeded but a required variable is still unset
#             or empty (also returned when gpg_file argument is missing)
#         3 - gpg decrypt failed
#         4 - eval of decrypted content failed (syntax error or failing
#             command)
#
# Usage (in a caller script):
#   # Source the library by its installed path; substitute the correct
#   # path for the deployment layout.
#   # shellcheck source=/dev/null
#   source <path-to>/n2snscripts/lib/gpg-passwd.sh
#   decrypt_env_file "$HOME/.zshrc.private.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
#
# Calling convention under `set -e`:
#   decrypt_env_file runs `gpg` in a command substitution. Under a caller's
#   `set -e`, a non-zero exit from that command substitution can abort the
#   caller *before* it observes the function's return code, so the documented
#   return 3 (and return 2/0) are only reliably visible when the call is
#   guarded. Always capture the status explicitly, e.g.:
#       rc=0
#       decrypt_env_file "$HOME/.private.gpg" AIFAPIM_HOST || rc=$?
#       case "$rc" in ... esac
#   The trailing `|| rc=$?` both captures the code and suppresses `set -e`.
#
# Portability:
#   Works in both bash and zsh. Required-variable values are read by
#   indirection through `eval "value=\${$name:-}"`; the name is first
#   validated to be a plain shell identifier (and rejected if it starts with
#   the reserved __gpgpw_ prefix), so the eval can neither inject code nor
#   read one of this function's own locals. Bash `local -n` namerefs are not
#   available in zsh, so eval indirection is the portable alternative.

# Guard against double-sourcing.
[[ -n "${_GPG_PASSWD_LIB_SOURCED:-}" ]] && return 0
_GPG_PASSWD_LIB_SOURCED=1

# All function-local variables are prefixed `__gpgpw_` so the eval indirection
# below cannot read one of this function's own locals when a caller passes a
# required-var name that collides with a local. Required-var names that
# themselves start with `__gpgpw_`, or that are not plain shell identifiers,
# are rejected (return 2) to close the residual collision and injection risks.
decrypt_env_file() {
    local __gpgpw_file="${1:-}"
    shift || true
    local __gpgpw_required=("$@")

    if [[ -z "$__gpgpw_file" ]]; then
        printf 'decrypt_env_file: missing gpg_file argument\n' >&2
        return 2
    fi

    if [[ ! -r "$__gpgpw_file" ]]; then
        printf 'decrypt_env_file: %s not found or unreadable; skipping decrypt.\n' "$__gpgpw_file" >&2
        return 0
    fi

    local __gpgpw_decrypted __gpgpw_rc
    __gpgpw_decrypted="$(gpg --quiet --batch --yes --decrypt "$__gpgpw_file")"
    __gpgpw_rc=$?
    if ((__gpgpw_rc != 0)); then
        printf 'decrypt_env_file: gpg --decrypt %s failed (exit %d).\n' "$__gpgpw_file" "$__gpgpw_rc" >&2
        return 3
    fi
    # Capture the status directly: inside `if ! eval ...`, $? would be the
    # negated pipeline's status (always 0), not eval's.
    eval "$__gpgpw_decrypted"
    __gpgpw_rc=$?
    unset __gpgpw_decrypted
    if ((__gpgpw_rc != 0)); then
        printf 'decrypt_env_file: eval of decrypted content from %s failed (exit %d).\n' "$__gpgpw_file" "$__gpgpw_rc" >&2
        return 4
    fi

    local __gpgpw_var __gpgpw_value
    # Guard the expansion so an empty required-vars array does not trip
    # `set -u` on bash < 4.4.
    for __gpgpw_var in ${__gpgpw_required[@]+"${__gpgpw_required[@]}"}; do
        # Validate the name before the eval indirection below.  Reject the
        # reserved __gpgpw_ prefix (would read one of this function's locals)
        # and anything that is not a plain shell identifier (would let the
        # eval inject code).  Pure glob patterns so the check behaves
        # identically in bash and zsh.
        case "$__gpgpw_var" in
            __gpgpw_*)
                printf 'decrypt_env_file: required variable name %s is reserved (must not start with __gpgpw_).\n' "$__gpgpw_var" >&2
                return 2
                ;;
            '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*)
                printf 'decrypt_env_file: required variable name %s is not a valid shell identifier.\n' "$__gpgpw_var" >&2
                return 2
                ;;
        esac
        # eval indirection for portability: `local -n` namerefs are bash-only.
        # Safe: the name is a validated identifier, so only the caller's variable is read.
        eval "__gpgpw_value=\${$__gpgpw_var:-}"
        if [[ -z "$__gpgpw_value" ]]; then
            printf 'decrypt_env_file: required variable %s is still empty after decrypt.\n' "$__gpgpw_var" >&2
            return 2
        fi
    done

    return 0
}
