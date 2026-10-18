# `bw*` sandboxed CLI wrappers

The `bw*` wrappers in `bin/` run AI CLI tools inside a [bubblewrap][bwrap]
(`bwrap`) sandbox to enforce NSLS-II sandboxing policy: managed config,
masked privileged binaries, ephemeral auth on shared accounts, and
filesystem isolation from the rest of the host. See the NSLS-II
coding-agents documentation for the policy these wrappers implement.

All five wrappers source the shared library `lib/bwrap_sandbox_lib.sh`
for sandbox construction. Each wrapper's `--help` is the authoritative
option list; the tables below summarise the common surface.

[bwrap]: https://github.com/containers/bubblewrap

## Requirements

- `bash` >= 4.x (the wrappers use `[[ ]]` and arrays)
- `bubblewrap` (`bwrap`) >= 0.4.0
  - 0.5.0+ enables `--clearenv`
  - 0.6.3+ enables bind-over-ro-bind binary masking

## Managed system paths

When present, the wrappers expose administrator-managed paths as optional,
read-only mounts. They do not expose the rest of the corresponding `/etc`
configuration directories.

- OpenCode: `/etc/opencode/skills`
- OpenCode 2 (`bwopencode2`): `/etc/opencode/skills`, `/etc/opencode/agents`,
  `/etc/opencode/commands`, and `/etc/opencode/plugins`
- Codex: `/etc/codex/skills`
- Claude: `/etc/claude-code/.claude/skills` and
  `/etc/claude-code/managed-settings.json`
- Copilot: its deployment-defined shared-skill directory, when configured by
  the wrapper

## Shared agent skills

Shared agent skills are a deployment-managed skill collection. The deployment
defines the source repository or checkout and manages read-only aliases at the
paths above. When those aliases are present, `bwopencode`, `bwopencode2`,
`bwcodex`, and `bwclaude` mount them read-only into their sandboxes. A wrapper configured for
Copilot likewise mounts its deployment-defined shared-skill directory
read-only.

Contribute or update skills through the deployment's documented contribution
workflow; do not edit its deployed checkout or managed aliases directly.

## Common options

Every `bw*` wrapper accepts these options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help plus the underlying tool's help |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD` | Run `CMD` inside the sandbox instead of the tool |
| `--init-auth` | Persist auth credentials to the host (first-time setup; not available in `bwopencode2`) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |
| `--ro-path PATH` | Read-only mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--rw-path PATH` | Read-write mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |

Tool-specific options are listed in each wrapper's section below.

## `bwopencode`

Launches [opencode](https://opencode.ai) inside a bubblewrap sandbox.

```text
bwopencode [bwopencode-options] [opencode arguments...]
```

Persists database, logs, snapshots, storage, tool-output, and
project-dotfiles to the host data dir; `auth.json` is persisted only if
it already exists on the host (use `--init-auth` once to create it for
personal accounts).

| Option | Description |
| --- | --- |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

## `bwopencode2`

Launches [OpenCode 2](https://opencode.ai) (`opencode2`, npm `@opencode/cli`)
inside a bubblewrap sandbox. It is a separate wrapper from `bwopencode`
because OpenCode 2 uses different directories and has a background service
that must not be reachable from the sandbox.

```text
bwopencode2 [bwopencode2-options] [opencode2 arguments...]
```

Requires the `opencode2` command on `PATH`, which ansible installs when
`base_opencode2_enable` is true.

Accepts the common options above except `--init-auth`, plus `--github-tokens`
(same behavior as `bwopencode`).

### Isolation from OpenCode 1

OpenCode 2 migrates the OpenCode 1 session database one way and cannot load
OpenCode 1 plugins, so it always uses its own directories, matching the
ansible-installed `opencode2` wrapper. Inside the sandbox the wrapper sets
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` to
`~/.config/opencode2`, `~/.local/share/opencode2`, `~/.local/state/opencode2`,
and `~/.cache/opencode2`, even if the `opencode2` on `PATH` is a plain binary.
OpenCode 2 appends `opencode` to each, and the OpenCode 1 directories are never
mounted.

| Directory | Mount |
| --- | --- |
| `~/.config/opencode2/opencode` | read-only, symlinks resolved |
| `~/.local/share/opencode2/opencode` | read-write, the whole directory persists |
| `~/.cache/opencode2/opencode` | read-write (provider npm packages install here) |
| `~/.local/state/opencode2/opencode` | not persisted (ephemeral) |
| `<repo>/.opencode` | persistent copy under the data dir `project-dotfiles/<hash>`, so repository content cannot inject config or plugins |
| `/etc/opencode/opencode.json{,c}`, `skills`, `agents`, `commands`, `plugins` | read-only, when present |

The whole data directory is bound because the OpenCode 2 layout (database with
`-shm`/`-wal`, `log`, `repos`, `shell`, ...) is not documented. Credentials are
stored in the `credential` table of its database, so `opencode2 auth login`
persists across sessions without anything like `--init-auth` (OpenCode 2's
legacy `auth.json` is only an import source). State is not persisted, so the
last-used model and prompt history are not remembered between sessions.

Because `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` point at the opencode2 directories,
the wrapper mirrors the host's `$XDG_CONFIG_HOME/git`, `pixi/config.toml`,
`ccache` config, and `$XDG_CACHE_HOME/ccache` cache under the same relative
location in the opencode2 directories so git, pixi, and ccache keep working.
`~/.gitconfig` and other `$HOME`-relative files are unaffected.

### `--standalone` is enforced

By default OpenCode 2 connects to a shared background service (fixed port
49374) that survives the CLI and runs tools **outside** any sandbox. The
sandbox shares the host network, so a CLI started normally would hand tool
execution to that unsandboxed server. `bwopencode2` therefore:

- adds `--standalone` (a private in-process server inside the sandbox) when
  `opencode2` is started with no subcommand or a directory argument, or with
  `run`, `mini`, `models`, or `stats`;
- refuses (exit status 1) `--server`, `--standalone=...`, `--no-standalone`,
  and the `service`, `serve`, `api`, `pair`, and `reload` subcommands;
- passes the other subcommands (`auth`, `debug`, `mcp`, `plugin`, `session`,
  `upgrade`, `uninstall`, `acp`) through unchanged, since they do not accept
  `--standalone`.

The argument scan takes the first non-option argument as the subcommand; only
`--session`/`-s`, `--prompt`, `--log-level`, and `--completions` are known to
take a value, and nothing after `--` is inspected. `--exec` bypasses the scan
because its arguments belong to the command you run. The config directory is
read-only, so commands that write global config (for example `plugin add`)
fail; edit config on the host.

## `bwclaude`

Launches the [Claude CLI](https://docs.claude.com/en/docs/claude-code/overview) inside a bubblewrap sandbox.

```text
bwclaude [bwclaude-options] [claude arguments...]
```

Routes through the NSLS-II Hermes (AIFAPIM) gateway in Azure AI Foundry
mode. The wrapper forces `CLAUDE_CODE_USE_FOUNDRY=1` and plumbs:

- **`ANTHROPIC_FOUNDRY_BASE_URL`** — if not set, constructed as
  `https://${AIFAPIM_HOST}/anthropic`; override by exporting
  `ANTHROPIC_FOUNDRY_BASE_URL` on the host. If neither
  `ANTHROPIC_FOUNDRY_BASE_URL` nor `AIFAPIM_HOST` is set, the wrapper
  refuses to start with a clear error message.
- **`ANTHROPIC_FOUNDRY_API_KEY`** — taken from the host's
  `ANTHROPIC_FOUNDRY_API_KEY` if set, otherwise from `AIFAPIM_API_KEY`
  (the existing NSLS-II convention). If neither is set, the wrapper
  refuses to start with a clear error message rather than letting Claude
  Code fall back to the Azure SDK credential chain.

The legacy `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` env vars are *not*
honored in foundry mode and the wrapper no longer sets them.

Additional options:

| Option | Effect |
| --- | --- |
| `--debug` | Enable verbose debug logging: sets `ANTHROPIC_LOG=debug`, `NODE_DEBUG=http,https,tls`, and passes `--debug --verbose` to `claude` |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

On shared accounts, auth is ephemeral. On a personal machine, run
`bwclaude --init-auth` once to persist credentials.

## `bwcopilot`

Launches the [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli/about-github-copilot-in-the-cli)
inside a bubblewrap sandbox.

```text
bwcopilot [bwcopilot-options] [copilot arguments...]
```

Additional options:

| Option | Effect |
| --- | --- |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

On shared accounts, auth tokens are ephemeral. On a personal machine,
run `bwcopilot --init-auth` once to persist tokens.

### Shared skills

When configured by the wrapper, `bwcopilot` automatically exposes the
deployment-managed shared-skill directory read-only. Configure Copilot CLI's
documented `skillDirectories` in `$COPILOT_HOME/settings.json` (default:
`~/.copilot/settings.json`) to name that same directory.

When `$COPILOT_HOME/settings.json` exists as a regular file, `bwcopilot`
automatically mounts it read-only. This also supports a valid symlink: the
wrapper resolves its source and mounts that source at the logical
`$COPILOT_HOME/settings.json` destination. Dangling symlinks and directories
are skipped.

The read-only mount prevents Copilot's `/settings` slash command from
persisting changes in the sandbox. Edit settings on the host between sessions.

## `bwcodex`

Launches the [OpenAI Codex CLI](https://github.com/openai/codex) inside
a bubblewrap sandbox.

```text
bwcodex [bwcodex-options] [codex arguments...]
```

Two approved auth paths (configured in `~/.codex/config.toml`):

- **Hermes (AIFAPIM) routing** — provider block points at
  `https://${AIFAPIM_HOST}/openai/v1` with `x-api-key` header; the
  wrapper plumbs `AIFAPIM_HOST` and `AIFAPIM_API_KEY` through.
- **BNL ITD ChatGPT subscription** — `codex login` OAuth flow persists
  tokens to `~/.codex/auth.json`. Run once with `--init-auth` to make
  that file persist across sandbox invocations.

Additional options:

| Option | Effect |
| --- | --- |
| `--debug` | Enable verbose Codex logging (sets `RUST_LOG=debug`) |
| `--persist-config` | Bind-mount `~/.codex/config.toml` read-write into the sandbox so changes (e.g. project-trust grants) persist across sessions. Without this flag, `config.toml` is staged read-write into a per-session copy that is discarded on exit. Concurrent `--persist-config` sessions may race on writes |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

Note: Codex CLI also enforces its own inner Landlock-based sandbox for
agent tool calls. The outer `bwrap` here is complementary — it scopes
the entire Codex process tree, not just agent-issued commands.

## `lib/bwrap_sandbox_lib.sh`

Shared sandbox-building primitives sourced by all `bw*` wrappers. Not
intended to be executed directly. The library header documents the
public function surface (sandbox construction, dynamic mount discovery,
binary masking, environment scrubbing).
