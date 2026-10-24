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
- Copilot: the shared skills tree `/nsls2/agents/skills`, at the same path
  inside the sandbox

## Shared agent skills

Shared agent skills are a deployment-managed skill collection published to
`/nsls2/agents/skills`. The deployment links the system skill directories above
to it. When those links are present, `bwopencode`, `bwopencode2`, `bwcodex`,
and `bwclaude` resolve them and mount the shared tree read-only at the same
paths inside their sandboxes. `bwcopilot` has no system skill directory, so it
mounts `/nsls2/agents/skills` read-only at that path; list it in Copilot's
`skillDirectories` setting. `/nsls2/agents` itself is not mounted, so a skill
refers to files beside it with relative paths such as `../_site/nsls2.md`.

Contribute or update skills through the deployment's documented contribution
workflow; do not edit its deployed checkout or managed aliases directly.

## Authoring directories

Each wrapper mounts, read-write, the directories where its tool reads
user-authored markdown definitions, so skills, agents, commands and prompts
can be created and edited from inside the sandbox and persist on the host.
The primary directories are created on the host when missing (not under
`--dry-run`); the additional locations are mounted only when they already
exist.

| Wrapper | Primary (always created) | Additional (if present) |
| --- | --- | --- |
| `bwopencode` | `~/.config/opencode/{skills,agents,commands}` | `~/.claude/{skills,agents,commands}`, `~/.agents/{skills,agents}` |
| `bwopencode2` | `~/.config/opencode2/opencode/{skills,agents,commands}` | `~/.claude/{skills,agents,commands}`, `~/.agents/{skills,agents}` |
| `bwclaude` | `~/.claude/{skills,agents,commands}` (under `$CLAUDE_CONFIG_DIR` when that is set) | |
| `bwcopilot` | `~/.copilot/{skills,agents}` | `~/.agents/skills` |
| `bwcodex` | `~/.codex/{skills,prompts}` | `~/.agents/skills` |

A common setup keeps skills in a separate repository and symlinks each one in
(for example `~/.agents/skills/some-skill -> ~/src/.../skills/some-skill`).
Each such symlink's resolved target is mounted read-write too, so the skill
works in the sandbox and editing it edits its source repository; the rest of
that repository is not exposed. A symlink that resolves into a blocked
location (such as `~/.ssh`), or to a directory that contains one, is skipped
with a warning, as is an authoring directory that does.

If the authoring directory itself is a symlink (for example
`~/.config/opencode/skills -> ~/dotfiles/skills`), its resolved target is
mounted at the usual path, but symlinks inside it are not followed this way;
each entry is mounted individually instead. Existing entries work, but a new
top-level entry created in the sandbox is discarded on exit.

## Common options

Every `bw*` wrapper accepts these options:

| Option | Effect |
| --- | --- |
| `--help`, `-h` | Show wrapper help, then the underlying tool's help when the tool is installed |
| `--dry-run` | Print the `bwrap` command without executing it |
| `--exec CMD [ARGS...]` | Run `CMD` inside the sandbox instead of the tool. `CMD` is split on whitespace; following arguments are passed unchanged, e.g. `--exec bash -c 'env \| sort'` |
| `--init-auth` | Persist auth credentials to the host (first-time setup; not available in `bwopencode2`) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |
| `--ro-path PATH` | Read-only mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--rw-path PATH` | Read-write mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |

`--ro-path` and `--rw-path` may be nested: a path nested under another
overrides it, so `--rw-path DIR --ro-path DIR/sub` mounts `DIR` read-write but
keeps `DIR/sub` read-only (the reverse, a read-only tree with one writable
subdirectory, works too). A path given as both `--ro-path` and `--rw-path` is
rejected. The masks on privileged binaries are the very last step, applied after all
other mounts and the environment setup, so a path that covers their directory
(for example `--ro-path /usr`) does not undo them.

Tool-specific options are listed in each wrapper's section below.

## Account check

Every `bw*` launcher runs `/opt/nsls2/libexec/agent-account-check` first
(before parsing any option, including `--help` and `--dry-run`) when that
script is installed (it is deployed by ansible). The script refuses root and
members of the shared/service-account group with a boxed message on stderr and
a non-zero exit status; the launcher exits with that status. The path is fixed
and cannot be overridden from the environment. When the script is not
installed nothing happens (the ACLs on the agent installs still apply).

## Agent binary resolution

After the account check every launcher resolves its agent command with the
shared `bwrap_resolve_tool` library function and distinguishes three failures
(each exits 1):

- **Restricted.** The command on `PATH` is a symlink whose target directory
  exists but cannot be entered by you (for example the ansible ACL that denies
  shared/service accounts access to the agent package directory). The launcher
  prints the same box as the ansible account check, without the two
  documentation links and with an extra line naming the tool
  (`'<tool>' is not available to this account.`). The box code in
  `lib/bwrap_sandbox_lib.sh` mirrors
  `roles/base/templates/agent-account-check.sh.j2` in NSLS2/ansible; the two
  must be kept in step.
- **Installed incorrectly.** The command is a dangling symlink, or a file that
  is not executable:
  `Error: '<tool>' is installed incorrectly (<path> points to a missing file or
  is not executable). Ask your system administrator.`
- **Not installed.** `Error: '<tool>' not found in PATH.` (plus an install
  hint for `bwcopilot` and `bwopencode2`).

Entries listed in `N2SNSCRIPTS_TOOL_EXCLUDE_PATH` are ignored in all three
cases.

## Credentials and secrets handling

- **Only four files of the XDG git directory are mounted.** From the host
  `${XDG_CONFIG_HOME}/git` directory (default `~/.config/git`) the wrappers
  mount `allowed_signers`, `config`, `ignore` and `attributes`, each read-only
  and only if present. The directory itself is never bound: nothing else in it
  is mounted, including `credentials` (the default file of git's `store`
  credential helper, holding plaintext passwords or tokens), and files created
  on the host later never appear in the sandbox. A listed file (or the whole
  directory) that resolves into a blocked location is skipped with a warning
  (`Warning: <path> resolves into a blocked location (<resolved>); not
  mounted.`) rather than aborting; a dangling symlink is skipped silently.
  `~/.ssh` is never mounted by any path. `$HOME` itself is a tmpfs, so
  `~/.git-credentials` is never visible. A credential helper that stores
  secrets elsewhere (for example `credential.helper = store --file=PATH`, or a
  path pulled in through a git `include`) is not covered; keep such files out
  of mounted locations. Signing commits inside the sandbox is not possible
  (`ssh-add` and `ssh-keygen` are masked and no agent socket is passed in).
  `allowed_signers` is mounted read-only, but `git` verifies SSH signatures
  with `ssh-keygen`, which is masked as well, so verify signatures on the host.
- **Default git credential stores are blocked paths.** `~/.git-credentials`
  and `$XDG_CONFIG_HOME/git/credentials` (the plaintext files of git's `store`
  credential helper) are on the blocked list, so a working directory or git
  root that contains one that exists (for example launching from
  `~/.config/git`), `--ro-path`, `--rw-path` and an `[include]` pointing at
  either are refused.
- **Blocked paths are matched at their symlink targets too.** Every entry of
  the blocked list is checked both as written and at its resolved target, so
  with `~/.config/git -> ~/dotfiles/git` the file `~/dotfiles/git/credentials`
  is blocked, and a symlinked `~/.git-credentials`, `~/.ssh` or `~/.config` is
  blocked at its target. This applies to `--ro-path`, `--rw-path`, git includes
  and the directory checks alike.
- **Paths are resolved before the blocked-path check.** Config entries and
  config directories (`~/.config/opencode*`), git include files, and the XDG
  `git`, `pixi/config.toml` and `ccache` locations are canonicalized with
  `realpath` (`readlink -f`) before the blocked-path check, so a symlinked
  parent directory (for example `~/.config/opencode2 -> ~/.aws`) cannot hide a
  blocked target; such a setup is refused with an error. A git include reached
  through a symlinked directory is mounted at both its real path and the path
  git opens. `..` in an include path is not collapsed lexically, because the
  kernel applies it to a symlink's target. Directories the path walks through
  before a `..` (for example `~/dotfiles` in `~/dotfiles/../x.conf`) are created
  in the sandbox. Symlinked directories under `$HOME` before a `..` (including
  a symlinked `~/.config/git`, whose four files are then mounted at the real
  target) are recreated in the sandbox as symlinks to their real target, so
  `..` resolves as on the host; a symlink whose target is in a blocked location
  is never recreated. If a needed symlink cannot be recreated (outside `$HOME`
  and not in a mounted tree, or dangling or blocked), the include is mounted at
  its real path only, with a warning. A host symlink at a path the launcher
  pre-creates in the sandbox home (`~/.config`, `~/.local`, `~/.local/share`,
  `~/.cache`, `~/bin`), or at any path already created or populated by an
  earlier mount, is not recreated either (bwrap cannot create a symlink where a
  directory exists): the sandbox sees a plain directory there and a warning is
  printed. Git then resolves `..` through it lexically; when every unrecreated
  symlink of an include is of this kind, the include is additionally mounted at
  its lexically collapsed path (for example `~/.config/shared` for
  `~/.config/git/../shared`), unless that path is already in use (never over
  `~/.gitconfig` or an XDG git file). Symlinks outside `$HOME` (for example
  under `/etc`, where only selected entries are bound) are not recreated: the
  four XDG git files are then mounted at the host path of the symlinked
  directory. A symlink that is itself the root of a directory mount (for
  example `~/bin -> ~/dotfiles/bin`, bound as a plain directory at `~/bin`) is
  not recreated either: the sandbox has a plain directory there, a warning is
  printed and the lexical fallback above applies. A symlink strictly inside a
  mounted tree (for example inside the working directory) keeps its host form
  and needs nothing.
- **Git includes are followed recursively.** `[include]` / `[includeIf]`
  `path =` entries of `~/.gitconfig` and `${XDG_CONFIG_HOME}/git/config` are
  followed through nested includes to a depth of 10 (git's own limit), each
  file is read once (include loops terminate), and an included file that
  resolves into a blocked location is neither read nor mounted (the launcher
  refuses it). Distinct include paths as written each get their own traversal
  directories (`~/first/../common.conf` and `~/second/../common.conf` both
  work), even when they name the same file; identical mounts are emitted once.
- **A directory that contains a blocked location is refused.** The working
  directory (the git root when inside a repository), `--ro-path` and
  `--rw-path` are checked on their canonical path: besides `$HOME`, its
  ancestors and anything inside a blocked tree, a directory that contains a
  blocked location that exists is refused with `Error: <context> '<dir>'
  contains the blocked path '<path>'. Refusing to mount.` (for example running
  from `~/.config` when `~/.config/gh` exists, or from a git root above
  `~/.ssh`); blocked locations that do not exist are ignored. `bwopencode2`
  also refuses a directory that equals or contains `~/.config/opencode2/opencode`
  (for example `~/.config/opencode2`), because `service.json` there is
  deliberately never mounted and a whole-directory bind would expose it.
- **Known limitations of the git include handling.** `includeIf` conditions
  are not evaluated, so every candidate include is mounted; includes configured
  only through the environment or `git -c include.path=...` are not seen; include
  chains deeper than 10 are ignored; unusual symlink layouts (for example a
  symlink at a directory-bind root or under a path the launcher pre-creates)
  fall back to a warning and a lexical mount, and git may still not find the
  file. Include values are decoded the way git does (double quotes, the
  escapes `\n \t \b \" \\`, trailing `#` or `;` comments, any case of
  `path`); a value that git itself would reject is skipped, and so is one that
  ends in a backslash (git's line continuation is not supported). Includes are tracked per path as opened, so two symlinks to one config
  are both followed. In short: an unusual include or symlink layout can lose git
  settings inside the sandbox. That does not expose credentials, so it is
  treated as a limitation of the sandbox, not a bug, and the include handling is
  not being extended further.
- **Forwarded variables stay off the command line.** Values passed through
  from the host (API keys, `GH_TOKEN_*`, ...) are given to `bwrap` in its
  environment via `env -i`, not as `--setenv` arguments, so they do not
  appear in `ps` output for the running sandbox (`/proc/<pid>/environ` is
  readable only by you). They are visible on `env`'s own command line only
  for the instant before it starts `bwrap`.
- **`--dry-run` redacts secrets.** Every printed variable (on the `env -i`
  line or as `--setenv NAME VALUE`) whose `NAME` contains (case-insensitive)
  `KEY`, `TOKEN`, `PASSWORD`, `SECRET`, or `CREDENTIAL` is printed with the
  value `REDACTED`. Only the printed text is redacted; the real launch passes
  the real values.

## `bwopencode`

Launches [opencode](https://opencode.ai) inside a bubblewrap sandbox.

```text
bwopencode [bwopencode-options] [opencode arguments...]
```

Persists database, logs, plans, snapshots, storage, tool-output, and
project-dotfiles to the host data dir; `auth.json` is persisted only if
it already exists on the host (use `--init-auth` once to create it for
personal accounts).

Requires at least a minimal OpenCode config: `/etc/opencode/opencode.json` or
`opencode.jsonc` (deployed by ansible on managed hosts), or an `opencode.json`,
`opencode.jsonc` or `config.json` in `~/.config/opencode`. Either is enough.
If none exists the wrapper exits with status 2 before touching anything on the
host (`--dry-run` and `--exec` included; `--help` is unaffected). Only the
presence of a readable file is checked, not its content.

### `OPENCODE_*` environment allowlist

Only an allowlist of harmless `OPENCODE_*` behaviour toggles (46 names) is
forwarded from the host environment into the sandbox. **Behaviour change:**
any other host `OPENCODE_*` variable is now dropped (previously all were
passed). Sensitive or location-changing variables are deliberately excluded:
`OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` (the sandbox shares
the host network, so an agent holding the password could drive an
unsandboxed opencode server), `OPENCODE_API_KEY`, `OPENCODE_CONSOLE_TOKEN`,
`OPENCODE_CONFIG*` / `OPENCODE_TUI_CONFIG` / `OPENCODE_PERMISSION` (inject
config or permissions and bypass the managed config), `OPENCODE_AUTH_CONTENT`,
`OPENCODE_DB` / `OPENCODE_*_DB`, `OPENCODE_MODELS_URL` / `OPENCODE_MODELS_PATH`,
and path or URL overrides.

Forwarded: `OPENCODE_DISABLE_{AUTOCOMPACT,AUTOUPDATE,CLAUDE_CODE,
CLAUDE_CODE_PROMPT,CLAUDE_CODE_SKILLS,DEFAULT_PLUGINS,EMBEDDED_WEB_UI,
EXTERNAL_SKILLS,FFF,LSP_DOWNLOAD,MODELS_FETCH,MOUSE,PROJECT_CONFIG,PRUNE,
TERMINAL_TITLE}`, `OPENCODE_ENABLE_{EXA,EXPERIMENTAL_MODELS,PARALLEL,
QUESTION_TOOL}`, `OPENCODE_EXPERIMENTAL`, the `OPENCODE_EXPERIMENTAL_*`
feature flags listed in the `_OPENCODE_ENV_ALLOWLIST` array in
`bin/bwopencode` (including `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX`),
`OPENCODE_ALWAYS_NOTIFY_UPDATE`, `OPENCODE_FAST_BOOT`, `OPENCODE_LOG_LEVEL`,
`OPENCODE_PRINT_LOGS`, `OPENCODE_PURE`, and `OPENCODE_SHOW_TTFD`.
`OPENCODE_DISABLE_PROJECT_CONFIG` only disables a repository's own
`opencode.json` (stricter; it cannot override `/etc/opencode`).
`OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` is a numeric output limit; because
its name contains `TOKEN`, `--dry-run` prints its value as `REDACTED` (the
real value is passed). `AIFAPIM_HOST` and `AIFAPIM_API_KEY` are forwarded as
before. With `--dry-run`, the **names** (never values) of dropped `OPENCODE_*`
variables are printed to stderr. To permit another variable, add it to
`_OPENCODE_ENV_ALLOWLIST` in `bin/bwopencode`.

## `bwopencode2`

Launches [OpenCode 2](https://opencode.ai) (`opencode2`, npm `@opencode/cli`)
inside a bubblewrap sandbox. It is a separate wrapper from `bwopencode`
because OpenCode 2 uses different directories on the host and has a background
service that must not be reachable from the sandbox.

```text
bwopencode2 [bwopencode2-options] [opencode2 arguments...]
```

Requires the `opencode2` command on `PATH`, which the ansible base role
installs.

Requires at least a minimal OpenCode config, as `bwopencode` does: the
system-wide `/etc/opencode/opencode.json{,c}` (shared with `bwopencode`), or an
`opencode.json`, `opencode.jsonc` or `config.json` in
`~/.config/opencode2/opencode`. If neither exists the wrapper exits with
status 2. The OpenCode 1 config in `~/.config/opencode` is not used.

Accepts the common options above except `--init-auth`.

### Host directories and sandbox locations

On the host OpenCode 2 follows the ansible-installed `opencode2` wrapper's
convention of separate `opencode2` directories. Inside the sandbox everything is
mounted at the **standard** locations (the same ones `bwopencode` uses, under
`$XDG_CONFIG_HOME` and so on), so the wrapper sets no `XDG_*` variable and git,
pixi and ccache find their config where the shared library mounts it.

For the same reason the sandbox does not run the ansible
`/usr/local/bin/opencode2` wrapper: it exports
`XDG_*_HOME=~/.{config,local/share,local/state,cache}/opencode2`, which would
point OpenCode 2 at empty directories inside the sandbox (no config, plugins or
database) and pass those variables on to every tool it runs. `bwopencode2` runs
the binary the wrapper runs,
`/opt/nsls2/opencode2/node_modules/@opencode/cli/bin/opencode.exe`, directly
and adds `--standalone` itself (see below). If that binary is missing it falls
back to `opencode2` from `PATH`. `--exec` runs its command unchanged, so use the
binary path there too, not `opencode2`.

| Host | Sandbox | Mount |
| --- | --- | --- |
| `~/.config/opencode2/opencode` | `~/.config/opencode` | read-only, symlinks resolved |
| `~/.local/share/opencode2/opencode` | `~/.local/share/opencode` | read-write, the whole directory persists |
| `~/.cache/opencode2/opencode` | `~/.cache/opencode` | read-write (provider npm packages install here) |
| (none) | `~/.local/state/opencode` | not persisted (ephemeral), except the next row |
| `~/.local/state/opencode2/opencode/latest/tui` | `~/.local/state/opencode/latest/tui` | read-write (TUI plugin storage: dismissed onboarding boxes, tab layout) |
| `<repo>/.opencode` | `<repo>/.opencode` | persistent copy under the host data dir `project-dotfiles/<hash>`, so repository content cannot inject config or plugins |
| `/etc/opencode/opencode.json{,c}`, `skills`, `agents`, `commands`, `plugins` | same | read-only, when present |

The whole data directory is bound because the OpenCode 2 layout (database with
`-shm`/`-wal`, `log`, `repos`, `shell`, ...) is not documented. Credentials are
stored in the `credential` table of its database, so `opencode2 auth login`
persists across sessions without anything like `--init-auth` (OpenCode 2's
legacy `auth.json` is only an import source). State is not persisted, except
the TUI plugin storage directory (`latest/tui`), so a dismissed "Getting
started" box and the tab layout survive restarts. Locks and background-service
files stay ephemeral (avoids lock clashes on NFS homes and sharing service
files with a host `opencode2`), so the last-used model and prompt history are
not remembered between sessions.

### Config and authoring directories

A system-wide `/etc/opencode` config is mounted when present, and the user
config in `~/.config/opencode2/opencode` is layered on it, so personal tuning
still works on managed hosts. The `skills`, `agents` and `commands` read-write
authoring directories (see above) live under the host config directory and are
mounted under `~/.config/opencode`; because the host and sandbox paths differ, a
relative symlink inside them cannot resolve and is skipped with a warning
(absolute symlinks work).

### Isolation from OpenCode 1

OpenCode 2 migrates the OpenCode 1 session database one way and cannot load
OpenCode 1 plugins, so on the host it uses its own `opencode2` config, data and
cache directories, and the OpenCode 1 ones are never mounted, even when an
`opencode2` directory does not exist yet (data and cache are created on first
run).

### What is kept out of the sandbox

- **`service.json`**: OpenCode 2 keeps background-service settings (including
  values set with `service set env KEY VALUE`, and the port) in
  `~/.config/opencode2/opencode/service.json` (other release channels may use
  `service-<hash>.json`). Files matching `service*.json` are not mounted; the
  rest of the config directory is.
- **`OPENCODE_*` environment variables**: only this allowlist is passed
  through; every other `OPENCODE_*` variable is dropped:
  `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_FILEWATCHER`,
  `OPENCODE_FILEWATCHER_DISABLE`, `OPENCODE_DISABLE_MODELS_FETCH`,
  `OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`,
  `OPENCODE_DISABLE_FFF`, `OPENCODE_DISABLE_PROJECT_CONFIG`,
  `OPENCODE_LOG_LEVEL`, `OPENCODE_PRINT_LOGS`. The
  variables that matter most are the server passwords (`OPENCODE_PASSWORD`,
  `OPENCODE_SERVER_PASSWORD`): the sandbox shares the host network, so an agent
  holding one could connect to an unsandboxed server on port 49374 and run
  tools outside the sandbox. Others dropped include `OPENCODE_SSH_ASKPASS_*`,
  `OPENCODE_EDITOR_SSE_PORT`, `OPENCODE_PTY_HANDOFF`, `OPENCODE_DB`,
  `OPENCODE_TEST_HOME`, `OPENCODE_CONFIG*`, `OPENCODE_MODELS_PATH`/`_URL`, and
  `OPENCODE_API_KEY`. With `--dry-run`, the names (never the values) of the
  dropped host variables are printed to stderr.

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
by design: it runs an arbitrary command, whose arguments are not `opencode2`'s,
so `bwopencode2 --exec 'opencode2 --server ...'` is not stopped (the host
server password is no longer in the sandbox environment, see above). The config directory is
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

The Claude home is `~/.claude`, or `$CLAUDE_CONFIG_DIR` when that is set on the
host (it is then also set inside the sandbox, pointing at the same directory).
`bwclaude` persists `logs`, `projects`, `todos`, `statsig`, `file-history`,
`plans` (plan-mode plan files) and `sessions` there, plus `history.jsonl` and
the state file (`~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`), which
is shared with unsandboxed `claude`. Other new files under the Claude home are
discarded on exit. The state file is not only UI state: it also holds the OAuth
session (if any), per-project trust decisions and personal MCP server
definitions, so a sandboxed session can change what unsandboxed `claude` trusts
or starts. This is a known gap.

`settings.json` can define hooks, `apiKeyHelper` and `env` that run outside
the sandbox the next time `claude` is used on the host, so by default the
sandbox only gets a throwaway copy of it. `--init-auth` bind-mounts it
read-write (creating it if needed) along with the credentials.

On shared accounts, auth is ephemeral. On a personal machine, run
`bwclaude --init-auth` once to persist credentials.

## `bwcopilot`

Launches the [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli/about-github-copilot-in-the-cli)
inside a bubblewrap sandbox.

```text
bwcopilot [bwcopilot-options] [copilot arguments...]
```

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

The wrapper keeps `~/.codex/packages` in its ephemeral Codex home. When the
daemon starts, Codex copies its package from the system CLI, which the wrapper
mounts read-only with its metadata and resources. An ephemeral
`app-server-daemon/settings.json` disables automatic daemon package updates.
The package copy is discarded when the sandbox exits.

Additional options:

| Option | Effect |
| --- | --- |
| `--debug` | Enable verbose Codex logging (sets `RUST_LOG=debug`) |
| `--persist-config` | Bind-mount `~/.codex/config.toml` read-write into the sandbox so changes (e.g. project-trust grants) persist across sessions. Without this flag, `config.toml` is staged read-write into a per-session copy that is discarded on exit. Concurrent `--persist-config` sessions may race on writes |

Note: Codex CLI also enforces its own inner Landlock-based sandbox for
agent tool calls. The outer `bwrap` here is complementary — it scopes
the entire Codex process tree, not just agent-issued commands.

## `lib/bwrap_sandbox_lib.sh`

Shared sandbox-building primitives sourced by all `bw*` wrappers. Not
intended to be executed directly. The library header documents the
public function surface (sandbox construction, dynamic mount discovery,
binary masking, environment scrubbing).
