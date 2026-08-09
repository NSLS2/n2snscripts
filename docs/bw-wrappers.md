# `bw*` sandboxed CLI wrappers

The `bw*` wrappers in `bin/` run AI CLI tools inside a [bubblewrap][bwrap]
(`bwrap`) sandbox to enforce NSLS-II sandboxing policy: managed config,
masked privileged binaries, ephemeral auth on shared accounts, and
filesystem isolation from the rest of the host. See the NSLS-II
coding-agents documentation for the policy these wrappers implement.

All four wrappers source the shared library `lib/bwrap_sandbox_lib.sh`
for sandbox construction. Each wrapper's `--help` is the authoritative
option list; the tables below summarise the common surface.

[bwrap]: https://github.com/containers/bubblewrap

## Requirements

- `bash` >= 4.x (the wrappers use `[[ ]]` and arrays)
- `bubblewrap` (`bwrap`) >= 0.4.0
  - 0.5.0+ enables `--clearenv`
  - 0.6.3+ enables bind-over-ro-bind binary masking

## Common options

Every `bw*` wrapper accepts these options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help plus the underlying tool's help |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD` | Run `CMD` inside the sandbox instead of the tool |
| `--init-auth` | Persist auth credentials to the host (first-time setup) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |

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

## `bwomp`

Launches Oh My Pi (`omp`) inside a bubblewrap sandbox.

```text
bwomp [bwomp-options] [omp arguments...]
```

Persists OMP config, prompt history, model cache DB, sessions,
terminal-sessions, top-level runtime/cache directories, worktrees, and
project `.omp/` state. `agent.db` contains auth tables and is therefore
auth-sensitive: it is copied into tmpfs by default so existing credentials
can be used for the session without persisting updates. Use `--init-auth`
only on personal accounts to bind-mount `agent.db` read-write and persist
OMP auth changes across sessions.

Profiles follow OMP's normal layout: `--profile NAME` or `OMP_PROFILE=NAME`
uses `~/.omp/profiles/NAME/agent`. `PI_CODING_AGENT_DIR` is honored when no
profile is selected. Extra OMP workspaces are not auto-mounted; use wrapper
`--ro-path` or `--rw-path` so the same blocked-path checks apply.

| Option | Description |
| --- | --- |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

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
