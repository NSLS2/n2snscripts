# `gpg-passwd.sh`

Shell library providing `decrypt_env_file`, a helper for sourcing
GPG-encrypted environment files into the current shell. Sourced, not
executed.

**Requires bash >= 4.3. Not zsh-safe.** The required-variable check uses a
`local -n` nameref, which does not exist in zsh and needs bash 4.3 or newer.
Source this only from bash callers.

## Usage

Source the library and call `decrypt_env_file`:

```bash
source "${N2SNSCRIPTS_LIB}/gpg-passwd.sh"
decrypt_env_file "$HOME/.private_env.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
```

### Calling under `set -e`

`decrypt_env_file` runs `gpg` inside a command substitution. Under a
caller's `set -e`, a non-zero exit from that substitution can abort the
caller *before* it reads the return code, so the return values below are only
reliably observed when the call is guarded. Always capture the status:

```bash
rc=0
decrypt_env_file "$HOME/.private_env.gpg" AIFAPIM_HOST AIFAPIM_API_KEY || rc=$?
# inspect $rc: 0 = ok/missing-file, 2 = required var empty / bad args,
#              3 = gpg failed
```

The trailing `|| rc=$?` both captures the code and suppresses `set -e`.

### Required-variable names

Required-variable names passed to `decrypt_env_file` must not begin with
`__gpgpw_`; that prefix is reserved for the function's own locals and such a
name is rejected with return code `2`.

## Behaviour

- Decrypts the file with `gpg --quiet --batch --yes --decrypt` and
  `eval`s the result into the current shell.
- Validates that each required variable named in the call is non-empty
  after decryption.

## Return codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `0` (with warning) | File is missing — no decrypt attempted |
| `2` | A required variable is still empty after decrypt |
| `3` | `gpg` failed (bad passphrase, malformed file, etc.) |
| `4` | `eval` of decrypted content failed (syntax error or failing command) |

See the library header comment for the full contract.
