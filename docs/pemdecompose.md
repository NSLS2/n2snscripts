# `pemdecompose`

Bash utility that lists the X.509 certificates in a PEM file, printing
the subject, issuer, and signature algorithm of each. Optionally verifies
that adjacent certificates form a valid chain in file order.

Private-key blocks in a combined PEM file (e.g. `server.combined.pem`
from the `acme_certificates` Ansible role) are skipped automatically —
only `CERTIFICATE` blocks are inspected. Blank lines and non-PEM text
between blocks are tolerated.

## Requirements

- `openssl`

## Usage

```text
pemdecompose [options] FILE [FILE...]
pemdecompose --help
```

| Option | Description |
| --- | --- |
| `--verify` | Verify each cert is issued by the next cert in the file (signature + issuer/subject DN match) |
| `-q`, `--quiet` | Suppress the per-file banner and inter-file blank line when multiple files are given |
| `--no-color`, `--no-colour` | Disable ANSI colour output (also disabled automatically when stdout is not a TTY or `NO_COLOR` is set) |
| `-h`, `--help` | Show help and exit |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Usage error (bad option, no input file, or an unreadable input file) |
| `2` | No certificates found in at least one input file |
| `3` | `openssl` parse error on at least one certificate |
| `4` | `--verify` failed for at least one chain link |
| `5` | Operational error (e.g. cannot create the temporary directory) |

## Examples

```bash
# Print subject, issuer, and signature algorithm for each cert
pemdecompose server.combined.pem

# Verify chain order as well
pemdecompose --verify server.pem

# Inspect multiple files (with per-file banners)
pemdecompose server.pem server_chain.pem

# Multiple files, no banners, no colour
pemdecompose --quiet --no-color server.pem server_chain.pem
```

## Notes

### `--verify` semantics

For each adjacent pair of certificates in the file, `--verify` checks:

- The issuer DN of certificate N matches the subject DN of certificate N+1.
- The signature verifies using `openssl verify -partial_chain`.

Validity dates are **not** part of the structural check — expired
intermediate or root certificates do not cause `--verify` to fail.

### Colour output

Output is colourised when stdout is a TTY. To suppress ANSI escapes,
either set the `NO_COLOR` environment variable or pass `--no-color`.
