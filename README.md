# n2snscripts

NSLS-II system scripts and shell libraries. Deployed to `/opt/nsls2/scripts`
on managed hosts via the Ansible base role.

## Layout

```text
bin/    Executable wrappers (sandboxed AI CLI tools, etc.)
lib/    Sourced shell libraries
etc/    Configuration assets (reserved)
docs/   Per-script and per-library documentation
```

## Contents

### `bin/`

| Script | Purpose | Docs |
| --- | --- | --- |
| `azoidcapp` | Create or reconcile an Entra ID OIDC app + service principal | [docs/azoidcapp.md](docs/azoidcapp.md) |
| `bwclaude` | Claude CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwcodex` | OpenAI Codex CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwcopilot` | GitHub Copilot CLI in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `bwopencode` | OpenCode in a bubblewrap sandbox | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `gh-protect-branch` | Apply NSLS-II standard branch protection to a GitHub repo (all branches); enables secret scanning and push protection; optionally restricts branch creation to named patterns | [docs/gh-protect-branch.md](docs/gh-protect-branch.md) |
| `pemdecompose` | List and verify certificates in a PEM file | [docs/pemdecompose.md](docs/pemdecompose.md) |

All `bw*` wrappers share `lib/bwrap_sandbox_lib.sh` for sandbox construction.

### `lib/`

| Library | Purpose | Docs |
| --- | --- | --- |
| `bwrap_sandbox_lib.sh` | Shared sandbox-building primitives for `bw*` wrappers | [docs/bw-wrappers.md](docs/bw-wrappers.md) |
| `gpg-passwd.sh` | `decrypt_env_file` helper for GPG-encrypted env files | [docs/gpg-passwd.md](docs/gpg-passwd.md) |

These libraries are sourced, not executed. Each library's header comment
documents its public function surface.

## Deployment

`n2snscripts` is deployed by the NSLS-II Ansible base role:

- Cloned to `/opt/nsls2/scripts` on managed hosts.
- `/etc/profile.d/n2snscripts.sh` exports the following for login shells:

  | Variable | Value |
  | --- | --- |
  | `N2SNSCRIPTS_BIN` | `/opt/nsls2/scripts/bin` |
  | `N2SNSCRIPTS_LIB` | `/opt/nsls2/scripts/lib` |

  and prepends `$N2SNSCRIPTS_BIN` to `PATH`.

Manual install on an unmanaged host:

```bash
git clone git@github.com:NSLS2/n2snscripts.git ~/n2snscripts
export N2SNSCRIPTS_BIN="${HOME}/n2snscripts/bin"
export N2SNSCRIPTS_LIB="${HOME}/n2snscripts/lib"
export PATH="${N2SNSCRIPTS_BIN}:${PATH}"
```

Add those three exports to your `~/.bashrc` or `~/.zshrc` for persistence.

## Requirements

- `bash` >= 4.x (the `bw*` wrappers use `[[ ]]` and arrays)
- `bubblewrap` (`bwrap`) >= 0.4.0 for the `bw*` wrappers
  - 0.5.0+ enables `--clearenv`
  - 0.6.3+ enables bind-over-ro-bind binary masking
- `gpg(1)` for `gpg-passwd.sh`
- `openssl(1)` for `pemdecompose`
- `python3 >= 3.9` (stdlib only, no pip dependencies) for `azoidcapp`
- `az` (Azure CLI) logged in via `az login` for `azoidcapp`
- `gh(1)` authenticated with `admin:repo` scope for `gh-protect-branch`

## Usage

### `bw*` sandboxed CLI wrappers

```text
bwopencode [bwopencode-options] [opencode arguments...]
bwclaude   [bwclaude-options]   [claude arguments...]
bwcopilot  [bwcopilot-options]  [copilot arguments...]
bwcodex    [bwcodex-options]    [codex arguments...]
```

Common wrapper options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help plus the underlying tool's help |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD` | Run `CMD` inside the sandbox instead of the tool |
| `--init-auth` | Persist auth credentials to the host (first-time setup) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |

`bwclaude` also supports `--debug`. See each script's `--help` for the
authoritative option list.

### `gh-protect-branch`

Apply NSLS-II standard branch protection to a GitHub repository. Enforces
PR reviews, signed commits, deletion and force-push blocking, and secret
scanning via a repository ruleset and a named-branch classic protection
rule. Optionally restricts who can create new branches.

```text
gh-protect-branch [--approvers <team-slug>] [--no-sign-commits]
                  [--restrict-branch-creation [--exclude-branches <csv>]]
                  <owner/repo> [branch]
gh-protect-branch --only-restrict-creation [--exclude-branches <csv>]
                  <owner/repo>
```

| Option | Effect |
| --- | --- |
| `--approvers <team-slug>` | Restrict stale-review dismissal to this team (team must exist in the org) |
| `--no-sign-commits` | Do not require signed commits |
| `--restrict-branch-creation` | Also apply a creation-restriction ruleset (additive) |
| `--only-restrict-creation` | Apply only the creation-restriction ruleset; skip full protection |
| `--exclude-branches <csv>` | Comma-separated fnmatch patterns allowed to be created (default: `main,preview`); requires `--restrict-branch-creation` or `--only-restrict-creation` |
| `<owner/repo>` | Repository in `owner/repo` format (required) |
| `[branch]` | Named branch for classic protection (default: `main`) |
| `-h`, `--help` | Show help and exit |

```bash
gh-protect-branch NSLS2/n2sndocs
gh-protect-branch --approvers n2sn-admins NSLS2/n2sndocs main
gh-protect-branch --only-restrict-creation \
    --exclude-branches main,preview NSLS2/n2sndocs
```

Exit codes: `0` success, `1` usage error or missing dependency,
`2` `gh` not authenticated, non-zero `gh` exit code on API failure.

### `gpg-passwd.sh`

Source the library and call `decrypt_env_file`:

```bash
source "${N2SNSCRIPTS_LIB}/gpg-passwd.sh"
decrypt_env_file "$HOME/.private_env.gpg" AIFAPIM_HOST AIFAPIM_API_KEY
```

Behaviour:

- Decrypts the file with `gpg --quiet --batch --yes --decrypt` and `eval`s
  the result into the current shell.
- Returns `0` on success, `0` (with warning) if the file is missing,
  `2` if a required variable is still empty after decrypt, `3` if `gpg`
  fails.

See the library header for the full contract.

### `azoidcapp`

Create or reconcile an Azure Entra ID OIDC web application and its
service principal. Sets an owner on both objects, ensures the standard
OIDC delegated Microsoft Graph scopes (`openid`, `email`, `profile`,
`offline_access`) plus the delegated `User.Read` scope, and grants
tenant-wide admin consent for those delegated permissions.

The script is **idempotent**: re-running with the same `--name` is
safe. Existing objects are reused; redirect URIs are unioned (never
removed); permissions and consent are reconciled to the desired state.

Authentication reuses the current `az` CLI session — no additional
credentials or Python packages are required.

```text
azoidcapp --name NAME --owner UPN --redirect-uri URI [options]
```

| Option | Effect |
| --- | --- |
| `-n`, `--name NAME` | Display name of the app registration (required) |
| `-o`, `--owner UPN` | Owner UPN/email resolved to an object ID (required) |
| `-r`, `--redirect-uri URI` | Web redirect URI; repeatable, minimum one |
| `-t`, `--tenant TENANT` | Tenant ID or domain for the `az` token request |
| `--json` | Emit a JSON result instead of a human-readable summary |
| `-h`, `--help` | Show help and exit |

Example:

```bash
azoidcapp \
  --name "My OIDC App" \
  --owner alice@example.com \
  --redirect-uri https://app.example.com/callback \
  --redirect-uri https://app.example.com/silent-callback
```

Exit codes: `0` success, `1` usage error, `2` `az` missing or not logged
in, `3` owner UPN not found, `4` a Microsoft Graph call failed.

Requires: `az` (Azure CLI, logged in via `az login`), `python3 >= 3.9`
(stdlib only — no pip dependencies).

### `pemdecompose`

List certificates in a combined PEM file. Useful for inspecting outputs of
the `acme_certificates` Ansible role (`server.pem`, `server.combined.pem`,
`server_chain.pem`).

```bash
pemdecompose server.combined.pem            # subject, issuer, sigalg per cert
pemdecompose --verify server.pem            # also check chain order
pemdecompose server.pem server_chain.pem    # multiple files, with banners
```

Blank lines and non-PEM text between PEM blocks are tolerated. Private-key
blocks in a combined file are skipped automatically (only certificate
blocks are inspected).

`--verify` checks that each cert (except the last in the file) is issued
by the next cert in the file, using `openssl verify -partial_chain` and a
DN match between issuer(N) and subject(N+1). Validity dates are not part
of the structural check, so expired roots do not cause `--verify` to fail.

Output is colourised when stdout is a TTY. Set `NO_COLOR=1` or pass
`--no-color` to suppress ANSI escapes.

Exit codes: `0` success, `1` usage error, `2` no certificates found in
some file, `3` openssl parse error, `4` `--verify` failed for at least
one chain link.

Requires only `openssl`.

See the per-script doc pages under [`docs/`](docs/) for full usage,
options, and caveats.

## AI disclosure

This repository's contents are largely AI-generated with human
review. See [`AI_DISCLOSURE.md`](AI_DISCLOSURE.md) for details.
