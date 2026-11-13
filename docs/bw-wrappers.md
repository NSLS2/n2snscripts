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
  - binary masking is verified on RHEL 8.10 (`bubblewrap-0.4.0-3.el8_10`) and EL9 (0.6.3)
- For the private network namespace, one of: `pasta` (package `passt`,
  RHEL 9 and later) **with bwrap >= 0.4.1** (see
  [Implementation notes: pasta](#implementation-notes-pasta)), or
  `slirp4netns` >= 0.4.0 with libslirp >= 4.3.0 (package `slirp4netns`,
  RHEL 8 AppStream) and `python3` (or RHEL 8's
  `/usr/libexec/platform-python`); plus `/dev/net/tun` and unprivileged user
  namespaces on the host. Without them the wrappers stop (exit status 3)
  unless run with `--share-net` (see [Network](#network)). `ss` (iproute) is
  used to find busy ports for `--publish`.
- For the [network log](#network-log): `systemd-cat` (systemd) with a running
  journal, or `logger` (util-linux) with `/dev/log`. Without either the
  wrappers warn and run without the log. Python 3.6+ (standard library) to
  condense it and to name destinations (DNS relay).

## Managed system paths

When present, the wrappers expose administrator-managed paths as optional,
read-only mounts. They do not expose the rest of the corresponding `/etc`
configuration directories.

- OpenCode: `/etc/opencode/skills` and `/etc/opencode/AGENTS.md`
- OpenCode 2 (`bwopencode2`): `/etc/opencode/skills`, `/etc/opencode/agents`,
  `/etc/opencode/commands`, `/etc/opencode/plugins`, and
  `/etc/opencode/AGENTS.md`
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
| `--dry-run` | Print the command (the network backend, the descriptor relay and `bwrap`) without executing it |
| `--exec CMD [ARGS...]` | Run `CMD` inside the sandbox instead of the tool. `CMD` is split on whitespace; following arguments are passed unchanged, e.g. `--exec bash -c 'env \| sort'` |
| `--init-auth` | Persist auth credentials to the host (first-time setup; not available in `bwopencode2`) |
| `--new-session` | Force `bwrap --new-session` (stricter isolation; breaks SIGWINCH) |
| `--ro-path PATH` | Read-only mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--rw-path PATH` | Read-write mount an existing path; its canonical target is mounted at the same canonical destination. Use only narrow paths. |
| `--n2c-token NAME` | Mount the N2C access token `NAME` read-only so skills in the sandbox can call NSLS-II APIs. May be repeated; `--n2c-token all` mounts every token present. Off by default. See [N2C access tokens](#n2c-access-tokens) |
| `--github-tokens` | Forward every `GH_TOKEN_*` environment variable into the sandbox so the agent can authenticate `gh`. Off by default. In `--dry-run` mode, token values are printed as `REDACTED`. Use per-command token selection inside the sandbox: `GH_TOKEN="$GH_TOKEN_NSLS2" gh pr list -R NSLS2/repo` |
| `--no-sandbox-context` | Do not generate the [sandbox context file](#sandbox-context) that tells the agent what is mounted |
| `--publish PORT[:SANDBOXPORT]` | Make a server in the sandbox reachable on the host at a per-user, per-session loopback address. May be repeated. See [Network](#network) |
| `--publish-addr ADDR` | Use `ADDR` (in `127.0.0.0/8`) for `--publish` instead of the derived address, for example `127.0.0.1` for OAuth redirects |
| `--host-port PORT[:SANDBOXPORT]` | Make the host's `127.0.0.1:PORT` reachable in the sandbox at `127.0.0.1:SANDBOXPORT`, which it then takes. May be repeated (pasta only) |
| `--share-net` | Share the host network instead of a private namespace (the behaviour before private namespaces); not with the forwarding options |
| `--net-backend pasta\|slirp4netns` | Use only this backend for the private namespace (normally pasta, else slirp4netns) |

`--ro-path` and `--rw-path` may be nested: a path nested under another
overrides it, so `--rw-path DIR --ro-path DIR/sub` mounts `DIR` read-write but
keeps `DIR/sub` read-only (the reverse, a read-only tree with one writable
subdirectory, works too). A path given as both `--ro-path` and `--rw-path` is
rejected. The masks on privileged binaries are the very last step, applied after all
other mounts and the environment setup, so a path that covers their directory
(for example `--ro-path /usr`) does not undo them.

Tool-specific options are listed in each wrapper's section below.

## N2C access tokens

`n2c-token` (installed by the NSLS2/ansible `base` role) signs a user in to the
NSLS2 N2C Entra app on the host and keeps a short-lived access token per
NSLS-II API in `/run/user/<uid>/nsls2/creds/<name>/token`, for example
`observability`, `docs` and `epics`. Skills read those files.

- **Nothing is mounted by default.** `--n2c-token NAME` mounts
  `creds/NAME/token` read-only at the same path; repeat it for several tokens.
  `--n2c-token all` mounts every token in the directory that you can enter.
  `all` together with names means all.
- **Only token files are mounted**, one file each. `n2c-token` rewrites a token
  in place, so a mounted file sees every refresh while the timer runs.
- **The refresh token is never mounted.** The MSAL cache (`cache.json`) lives
  in `/run/user/<uid>/nsls2/n2c` and is on the blocked list, so `--ro-path` and
  `--rw-path` refuse it and refuse a directory that contains it. The creds
  directory itself is allowed.
- **Automatic mounts cannot expose it either.** Directories the launcher mounts
  whole (the npm, pixi and prek caches, ccache, the tool data and cache directories)
  are only checked for being blocked themselves. So, after all mounts are built,
  the launch stops with an error if any bind mount's source (as written or with
  symlinks resolved) is, contains or lies inside the N2C session directory, for
  example with `N2C_STATE_DIR` set inside `~/.npm`, or `~/.npm` being a symlink to
  a directory that holds it. The default
  location, under `/run/user/<uid>`, is never inside such a directory.
- **The tokens are checked like an ssh private key** (see
  [Checks](#checks-on-the-credentials) below): a directory or token that
  someone else could read or replace stops the launch.
- **A missing token only warns**; run `n2c-token login` on the host. An empty
  token is mounted, with a warning: it is filled in place, so a mounted file
  shows the token as soon as it is written and every refresh after that,
  while the `n2c-token` timer runs (`n2c-token install` on the host).
- **Locations.** `N2SN_CREDS_DIR` and `N2C_STATE_DIR` override the two
  directories, as they do for `n2c-token`.
- **The sandbox is told where the tokens are.** The sandbox environment is
  scrubbed, so when at least one token is mounted the launcher sets
  `N2SN_CREDS_DIR` inside the sandbox to the credentials directory, even when
  the host uses a non-default location. Nothing is set when no token is mounted.

Example: `bwopencode2 --n2c-token observability --n2c-token epics`.

### Checks on the credentials

The launcher refuses to mount tokens that someone else could read or replace,
the way `ssh` refuses a private key that others can read. Each of these stops
the launch with an error:

- `N2SN_CREDS_DIR` is an absolute path with no symlink, `.`, `..` or doubled
  `/` in it, so use the real path (`/run/...`, not `/var/run/...`): a symlink
  could be changed between the check and the mount.
- Every directory above it, up to `/`, is owned by you or by root and is not
  writable by its group or others. Otherwise someone could rename a parent and
  put their own tree, with a token you did not check, in its place. A
  directory such as `/tmp`, which others can write to, is refused.
- The creds directory is **owned by you or by root**. Each token directory and
  each token has **the same owner**, so a tree is yours throughout (n2c-token)
  or root's throughout (a service account's tokens).
- The creds directory, each token directory and each token are **not writable
  by their group** and have **no permission at all for others** (mode `0750`,
  `0700`, `0640`, `0600` or `0440` pass; `0755`, `0775` or `0644` do not).
  Group read, and group enter for a directory, are allowed.
- The directories are real directories, you can enter a token directory and
  read its token, and a token is a regular file, not a symlink.

`--n2c-token all` skips token directories you cannot enter.

### Service accounts

A service account has no `n2c-token` session. A root service on the host (for
example a timer that gets app-only tokens with a certificate) keeps the same
`creds/NAME/token` files up to date, and the account only reads them. Nothing
extra is needed: the creds directory is owned by root, and the launcher uses
the same checks.

```bash
N2SN_CREDS_DIR=/run/nsls2/agent/creds bwopencode2 --n2c-token all
```

The warnings then say the tokens are kept by a root service instead of "Run:
n2c-token login". A service that keeps tokens this way should create the
creds directory and each token directory as `root:GROUP` with mode `0750`, and
each token as `root:GROUP` with mode `0440`, where `GROUP` is the group of the
account that runs the sandbox, and rewrite a token in place (the same file)
rather than replace it, because the sandbox mounts the file itself.

#### The AI gateway token

A service account that sends its requests to the AIFAPIM gateway through an
agents product needs a second credential next to its subscription key
(`AIFAPIM_API_KEY`, sent as `x-api-key`): an Entra ID token, sent as
`Authorization: Bearer`. The root service keeps that token in the same layout,
as the token named `aifapim`, so it is mounted like any other:

```bash
export N2SN_CREDS_DIR=/run/nsls2/agent/creds
export AIFAPIM_HOST=aifapim.nsls2.bnl.gov  # gitleaks:allow (a public host name)
export AIFAPIM_TOKEN_FILE=/run/nsls2/agent/creds/aifapim/token
bwopencode2 --n2c-token aifapim --n2c-token observability
```

`bwopencode2` passes `AIFAPIM_TOKEN_FILE` into the sandbox, which is a path and
not the token. The `aifapim-entra` OpenCode 2 plugin (NSLS2/n2snskills,
`plugins/`) reads the file on every request, because the token changes every 15
minutes, and does nothing unless both `AIFAPIM_HOST` and `AIFAPIM_TOKEN_FILE`
are set. `bwopencode` does not forward the variable: OpenCode 1 does not load
the plugin.

## Sandbox context

An agent that does not know it runs in a sandbox guesses: it takes a read-only
bind mount of a resolved symlink for a hard link, or expects `~/.ssh` to exist.
Every launcher therefore writes a short markdown description of the session
and makes the tool load it.

- **Built from the real mounts.** `build_sandbox_context` walks the final
  `bwrap` arguments, so the text always matches the session, including
  `--ro-path` / `--rw-path` mounts and a working directory outside `$HOME`.
- **Mounted at `~/.sandbox/AGENTS.md`**, read-only, with `--ro-bind-data` on a
  file descriptor (see [Descriptor relay](#descriptor-relay)). Nothing is
  written to the host, and no user file is
  overwritten. `BWRAP_SANDBOX` (launcher name) and `BWRAP_SANDBOX_CONTEXT`
  (the path) are set in the sandbox for scripts and skills.
- **Contents** (about 50 lines): `$HOME` is a tmpfs; same-inode files are bind
  mounts, not hard links, and are edited at their source; the working directory
  (its access taken from the effective mounts) and whether it is a git root; a
  Network section (private namespace, DNS, the published ports with their host
  URLs and the "bind `0.0.0.0`" rule, the host services and the sandbox ports
  they take); a
  table of every mount under `$HOME` marked `rw` / `ro` / `copy` (a writable
  copy of a host file, lost at exit) / `tmpfs`; the system mounts collapsed
  into one line each, with writable exceptions such as `--rw-path /usr/local`
  (and read-only exceptions below them) listed on their own, and `/tmp`
  described from its effective mount (`--rw-path /tmp` makes it the host's); what is not mounted (credential and rc files are named
  only when no mount exposes them); the disabled binaries; the *names* of
  passed-in variables (never values); and tool-specific notes (`bwopencode2`:
  use `--standalone`, plans in `~/.opencode/plan` are lost). A mount hidden by
  a later mount over its parent (for example `--ro-path` on the working
  directory) is left out. Control characters, `|` and backticks in paths are
  shown as `?`.
- **Snapshot.** The file is written at launch; the mounts of a running sandbox
  cannot change, so it stays correct for the whole session.

How each tool loads the file, always in addition to the user's own instruction
files:

| Launcher | Mechanism | If the user already sets the same thing |
| --- | --- | --- |
| `bwopencode`, `bwopencode2` | `OPENCODE_CONFIG_CONTENT='{"instructions":["<file>"]}'`; the list is added to the user's `instructions` (tested with 1.19.4 and 2.1.4, including a project `opencode.json`). A host value of this variable is dropped, as before. | Not applicable: lists are combined |
| `bwclaude` | `--append-system-prompt-file <file>`; adds to the default system prompt and leaves `CLAUDE.md` alone | A user `--append-system-prompt[-file]` wins; warning, file only mounted |
| `bwcodex` | `-c developer_instructions=<text>`; a separate message that leaves `AGENTS.md` alone | `developer_instructions` in any form (also a quoted, dotted or profile key, or an inline table) in the system, user or any project `config.toml` from the repository root down, or anywhere in the arguments, wins; warning, file only mounted |
| `bwcopilot` | `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=~/.sandbox`; Copilot reads that directory's `AGENTS.md` in addition to its usual files | A host value is not forwarded (it never was), so nothing is replaced |

`--exec` mounts the file and sets the two variables but adds no loader, since
the command is not the agent.

`--dry-run` prints the generated file after the command, with the other
generated files (`/etc/resolv.conf`, `/etc/hosts`).
`--no-sandbox-context` removes the file, the variables and the loader.

To check by hand, ask the agent a question only the file can answer ("is a
read-only file under `$HOME` with the same inode as a dotfiles file a hard
link?"), or for Copilot run `bwcopilot instruction list`.

## Network

Every sandbox runs in its own network namespace, provided by the first usable
backend:

1. [pasta](https://passt.top) (package `passt`, RHEL 9 and later, Fedora);
2. else [slirp4netns](https://github.com/rootless-containers/slirp4netns)
   (package `slirp4netns`, RHEL 8 AppStream);
3. else the launch **stops** (exit status 3), naming what is missing for each
   backend, unless `--share-net` is given.

So sandboxes are isolated by default, with one explicit escape hatch.

- **Outbound connections work** (model gateway, package installs, docs). Egress
  is not filtered.
- **The host's loopback is unreachable.** Services bound to `127.0.0.1` on the
  host (OpenCode's own server, language servers, CUPS, local databases, Tiled
  or queueserver dev instances, other users' sessions) cannot be reached from
  the sandbox, and `ss -ltn` inside shows only the sandbox's own sockets.
  `127.0.0.1` inside is the sandbox's private loopback.
- **Nothing the agent listens on is reachable from the host**, unless
  published (below).
- **Not hidden:** host services bound to a non-loopback address (sshd on
  `0.0.0.0:22`, the Tailscale address) stay reachable, as from any other
  machine.
- **`--share-net`** shares the host network instead: the behaviour before
  private namespaces, for workflows that need the host's loopback services or
  ports, or hosts where neither backend works. The host's `/etc/resolv.conf`
  and `/etc/hosts` are mounted, host loopback services are reachable, sandbox
  listeners are visible on the host, and the
  [sandbox context file](#sandbox-context) says so. It cannot be combined with
  the forwarding options or `--net-backend` (exit status 1). Prefer
  `--host-port` / `--publish` for single ports.
- **`--net-backend pasta|slirp4netns`** uses only that backend (no
  fallthrough), for testing the slirp4netns path on a host with pasta, or for
  diagnosis.

`BWRAP_NET_BACKEND` in the sandbox is `pasta`, `slirp4netns` or `none`
(`--share-net`).

| | pasta | slirp4netns | `--share-net` |
| --- | --- | --- | --- |
| Address in the sandbox | the host's | `192.168.254.100` (IPv4 only) | the host's |
| Outbound traffic leaves from | the host's address | the host's address | the host |
| DNS | `169.254.1.1`, forwarded to the host's resolver | `192.168.254.3`, forwarded to the host's resolver | the host's `resolv.conf` |
| `--publish`, `--publish-addr` | yes | yes (at most 64 ports) | no |
| `--host-port` | yes | no: the launch stops (exit 3) rather than drop it | no |
| Speed | close to native | slower (user-mode TCP/IP); fine for API calls | native |

With `--host-port`, a host without a working pasta stops even if slirp4netns
would work.

DNS: the host's resolver is usually on loopback (`127.0.0.53`), so the sandbox
gets a generated `/etc/resolv.conf` naming the backend's DNS address, which the
backend forwards to the first nameserver in the host's `/etc/resolv.conf`
(port 53 only), so split DNS (VPN, tailnet) keeps working. Only IPv4
nameservers are supported; the wrapper warns when the host has none. The host's
search domains are not passed on, so use fully qualified names. `/etc/hosts` is
the host's file.

### Opening ports

Both directions are off by default, opt-in per port and per launch, and
limited to loopback on both ends. Ports are `1024-65535`; a `LOW-HIGH` range
is accepted, and a mapped range must have the same length.

| Option | Direction | Host side | Sandbox side |
| --- | --- | --- | --- |
| `--publish PORT[:SANDBOXPORT]` | sandbox server → host | `127.H1.H2.S:PORT` (or `--publish-addr`) | the server on `SANDBOXPORT` (default `PORT`), which must listen on `0.0.0.0` |
| `--host-port PORT[:SANDBOXPORT]` | host service → sandbox | `127.0.0.1:PORT` | `127.0.0.1:SANDBOXPORT` (default `PORT`), held by pasta; pasta only |

Forwards are printed to stderr at launch, so they stay in the scrollback above
the TUI, and listed in the [sandbox context file](#sandbox-context). Inside the
sandbox `BWRAP_NET_PUBLISH`, `BWRAP_NET_PUBLISH_ADDR` and
`BWRAP_NET_HOST_PORTS` hold the same information.

```text
bwopencode2: network: private namespace (pasta); publish address 127.65.81.1
bwopencode2: publish    http://127.65.81.1:8000/  ->  sandbox :8000  (bind 0.0.0.0 inside)
bwopencode2: host-port  host 127.0.0.1:5432  ->  sandbox 127.0.0.1:5432  (host service sees a loopback client)
```

**`--publish`.** The host address is `127.H1.H2.S`: `H1.H2` comes from a hash
of your uid (`H1` is 1-254, so `127.0.0.1`, `127.0.0.53` and `127.0.1.1` are
never used), and `S` is the lowest session index (1-254) whose address has
none of the requested ports in use. Two users publishing port 8000 get
different addresses, a second sandbox of the same user gets the next index,
and your own dev server on `127.0.0.1:8000` does not collide. The address is
printed as a URL; there is no host name for it. Every `127/8` address is a
secure context in browsers. The host port is bound for the whole session,
whether or not a server runs. The server inside must bind `0.0.0.0` (or the
interface address): both backends deliver forwarded connections to the namespace's
interface, not its loopback; the context file tells the agent so. A port that
something on the host already holds on every address (`0.0.0.0:PORT`) is
refused at launch.

The backend binds the address only after the launcher has started it, so the
choice is made under a lock (`flock` on `claims.lock` in the
[runtime directory](#runtime-directory)), and each launch leaves a claim
(`claims/ADDR.PID`: launcher pid and its start time, host ports, launcher,
directory). Sandboxes of one user started at the same moment therefore get
different addresses. A claim whose process is gone (checked with the start
time, so a reused pid does not count) is removed by the next launch. A program
outside the launchers can still take a port first; pasta and slirp4netns then
fail to bind it and the launch stops.

**`--publish-addr ADDR`** replaces the derived address with `ADDR` (in
`127.0.0.0/8`). Use `127.0.0.1` for OAuth flows whose registered redirect URI
names it (some agent logins and MCP servers open a browser on the host that
calls back into the sandbox). The launch then fails if a requested port is
already in use or claimed by another of your sandboxes on `ADDR`.

**`--host-port`** makes one host loopback service visible in the sandbox at
`127.0.0.1:SANDBOXPORT` (and `localhost`), as pasta's `-T` does: pasta listens
on the sandbox's loopback and connects to the host's `127.0.0.1:PORT`. pasta
takes no other listening address for `-T`, so there is no separate name for
the host. That sandbox port is then taken: the agent cannot run its own server
on it, and a `--publish` to the same sandbox port is refused. To keep `PORT`
free in the sandbox (to run its own Postgres on 5432 next to the host's),
map it elsewhere: `--host-port 5432:15432`. The host side is always
`127.0.0.1`. Nothing checks that the host port is open or who owns it.
**The host service sees a loopback client and may trust it** (no password for
local connections, admin APIs): only forward services you would let the agent
use. These host ports are refused outright: `631` (CUPS), `2375`-`2376`
(Docker), `6000`-`6063` (X11), `41112` (Tailscale local API) and `49374`
(OpenCode 2 service, which runs tools outside any sandbox); the list is
`_NET_HOST_PORT_DENY` in the library.

**Not access control.** Any local user can connect to any `127/8` address, so
another user can reach your published ports; the per-user addresses prevent
accidental collisions, not access. Restricting that by uid would need
root-managed `nftables` rules.

To list the sandbox publications on a host:
`ss -ltn 'src 127.0.0.0/8' | grep -v ' 127\.0\.'`.

### Network log

Every launch records its network session in the host's system log, and with
pasta every connection as well. It is **always on**: there is no option to turn
it off. The records are written outside the sandbox, which can neither read nor
change them, and they are the data needed for a later egress allowlist.

| Record | Content |
| --- | --- |
| start | `event=start session=ID launcher=... user=... uid=... pid=... backend=... flows=logged\|unavailable pasta=VERSION publish=ADDR:PORTS host_ports=... dir=...` |
| dns | `session=ID dns domain=github.com type=A proto=udp rcode=NOERROR answers=140.82.112.21`, plus `cname=...` when the answer went through aliases |
| open | `session=ID flow=7 open proto=tcp dir=out src=ADDR:PORT dst=140.82.112.21:443 domain=github.com t=21.359` |
| close | `session=ID flow=7 close proto=tcp dir=out dst=140.82.112.21:443 domain=github.com t=33.770 secs=12.411` |
| fail | `session=ID flow=9 fail ...`: a connection that never became active (refused, unreachable) |
| end | `event=end session=ID ...`, when the sandbox has exited |

Every line is `key=value` (logfmt), so Loki's `| logfmt` can filter on any
field, for example the domains an agent reached:
`{syslog_identifier="bwrap-net"} | logfmt | dir="out"` grouped by `domain`.

- `dir` is `out` (the sandbox to the network), `publish` (a host client to a
  `--publish` port) or `host-port` (the sandbox to a `--host-port` service).
  `via=` is the address on the other side when it differs (the sandbox port
  for `publish`). `t` is seconds since pasta started; `secs` is the
  connection's duration. Flows still open when the session ends get a close
  with `reason=session-end`.
- `flow` is pasta's flow slot, which it reuses: it identifies a connection
  only between its open and its close.
- pasta logs no byte counts.
- `domain` is the domain of the last lookup, through the DNS relay, that
  returned the destination address. It is a record, not proof: several
  domains can share one address (CDNs), and a lookup that bypasses the relay
  (a query sent to `169.254.1.1` directly, DNS over HTTPS) leaves none.

- **Tag** (`SYSLOG_IDENTIFIER`): `bwrap-net`. `journalctl -t bwrap-net` shows
  all sessions; `journalctl -t bwrap-net -g ID` one. Inside the sandbox
  `BWRAP_SESSION` is the same ID, and the context file names it.
- **Tool:** `systemd-cat` when the journal's stream socket exists and accepts a
  connection, else `logger` (util-linux) on `/dev/log` (journald or rsyslog).
  Both are tried at launch without logging anything; the launcher then writes
  the start record itself. With neither, the launch warns and continues
  without the log.
- **Flows only with pasta; DNS with either.** slirp4netns has no flow log, so
  with it the records are the start, the end and the DNS relay's lookups —
  which are then the only account of what the sandbox reached for. With
  `--share-net` (recorded as `backend=none`) there is no namespace to relay
  in, so only the start and end records are written. The start record says
  which is which: `flows=logged|unavailable dns=logged|unavailable`.
- When the launcher runs on a terminal it prints the tool and the session ID.
- **How (pasta).** pasta logs flows only at debug level, and at debug level it
  never uses syslog: without `--log-file` it writes every line, timestamped,
  to its stderr. So pasta gets `--debug` (and not `--quiet`), with its stderr
  on a FIFO in the launch's [session directory](#runtime-directory), and a
  reader started by the launcher (outside the sandbox) turns the lines into
  log records:
  - **Why stderr and not `--log-file`.** pasta opens its log file read-write
    (to rotate it). On SELinux hosts (Fedora, RHEL) pasta runs in its own
    domain, `pasta_t`, which passt's policy lets only *append* to FIFOs
    labelled `user_tmp_t`; the open is denied and pasta exits before the
    sandbox starts. An inherited append-only descriptor is allowed. (A
    read-write one, or any other descriptor on the FIFO that pasta is not
    allowed, is silently replaced with `/dev/null` at the exec into
    `pasta_t`, so the launcher opens its stderr with `>>` and keeps no other
    descriptor on the FIFO across the exec.)
  - The reader (`lib/bwrap_netlog.py condense`) opens the FIFO first; the
    launcher waits for its "ready" before it opens its stderr on it, so the
    open does not block and nothing is lost. The reader ignores end-of-file
    and stops only when the launcher process, which is pasta by then, is
    gone (it is no longer the reader's parent), after draining the pipe. Then
    it writes the end record and removes the session directory.
  - If the tool dies, it goes on reading and drops the lines, so pasta never
    blocks on it.
  - pasta prints its setup first, and if it fails to start, its error. The
    descriptor relay (pasta's command) prints a marker on the FIFO and reopens
    your stderr: by path when it is a terminal or a file, else (a pipe)
    through a second FIFO that the reader copies. If pasta stops before the
    marker, the reader prints pasta's lines on your terminal, prefixed
    `pasta:`, just after the launcher has exited. (With slirp4netns the same
    FIFO, marker and reader are used for the DNS relay's lines, and a failed
    start shows the identity mapper's message prefixed `slirp4netns:`.)
  - **Condensed.** pasta's debug log has about 34 lines per connection (state
    changes, timers, ACK and buffer bookkeeping) and its setup dump. The reader
    keeps one line when a connection opens and one when it closes and drops
    the rest (in a real session, 5000 lines became 280). It writes to
    `systemd-cat` / `logger` itself. pasta's version is in the start record
    (`pasta=`), from `pasta --version`.
  - Without Python a bash supervisor copies pasta's lines to the log as they
    are.
- **DNS relay (both backends).** To name destinations, `lib/bwrap_netlog.py dns`
  listens on `127.53.0.1:53` (UDP and TCP) in the sandbox's network namespace,
  forwards each lookup to the backend's DNS (`169.254.1.1`, pasta's DNS
  forward, or `192.168.254.3`, slirp4netns's built-in one; the addresses
  below are pasta's) and writes one `dns` line per lookup to the log, before
  it answers, so the name is known when the connection that follows is
  logged. With slirp4netns the relay cannot bind port 53 itself; see
  [Implementation notes: slirp4netns](#implementation-notes-slirp4netns). The condenser keeps a map from the answers'
  addresses to domains. The sandbox's `/etc/resolv.conf` lists the relay first
  and `169.254.1.1` second, so lookups go on working, at once, if the relay is
  down (its port is then closed); pasta's own leg of a relayed lookup (UDP to
  `169.254.1.1:53`) is not logged as a connection.
  - The relay limits itself to 16 workers and 32 queued requests. On overload,
    a UDP query gets a logged `SERVFAIL` (allowing the client's next resolver
    to answer); a new TCP connection is closed. Each TCP query uses its own
    upstream connection, even if the client keeps its connection open.
  - The descriptor relay starts it before bwrap, as root of pasta's user
    namespace, which may bind port 53 there; it then drops every capability.
    It runs outside bwrap: the agent cannot see it (separate process
    namespace), and cannot take its port (it has no capabilities).
  - The descriptor relay waits until it listens (it says so on a pipe) before
    starting bwrap, at most 0.25 s, so the first lookups are logged too. In
    practice that is a Python start, some tens of milliseconds.
  - It exits when bwrap does.
- Both need Python 3.6 or later, standard library only (RHEL 8's
  `/usr/libexec/platform-python`, else `python3`). Without it pasta's lines go
  to the log unfiltered, and DNS goes straight to `169.254.1.1`.

### Implementation notes: pasta

- pasta runs outside bwrap, as you, and starts the sandbox. Default pasta
  behaviour is overridden where it would re-expose the host's loopback:
  `--no-map-gw` (the gateway address would otherwise map to the host's
  loopback) and `-T none` / `-U none` (`auto` would forward every port bound
  on the host's loopback into the namespace). `-t none` / `-u none` keep
  inbound ports closed unless `--publish` is given.
- pasta maps you to uid 0 in its user namespace, so bwrap runs the agent in a
  nested user namespace as your real uid and gid (`--unshare-user --uid
  --gid`); file ownership looks as before and the agent has no capabilities.
- **pasta needs bwrap 0.4.1 or later** and the launcher checks before using
  it. In 0.4.0 `drop_privs()` tests `geteuid() == 0` instead of "installed
  setuid root", so inside pasta's namespace — where uid 0 is the only mapped
  id — it calls `setuid(<your uid>)` on an unmapped id and dies with
  `unable to drop root uid: Invalid argument`. 0.4.1 changed the guard to
  `is_privileged`. RHEL 8 ships 0.4.0, but also has no pasta, so in practice
  this only bites a hand-built pasta or a backported one.
- pasta renames the host to `pasta-<name>`; bwrap's `--unshare-uts
  --hostname` restores the real name.
- `--no-pidns` is passed when the installed pasta supports it (2026-09 and
  later); older pasta adds a PID namespace, inside which bwrap nests its own.
- `ping` may not work (ICMP depends on the host's `ping_group_range`).
- Nested namespaces in the sandbox (rootless podman) still do not work.

### Implementation notes: slirp4netns

slirp4netns cannot start the sandbox; it attaches to an existing network
namespace. The launch has two steps, and the launcher still `exec`s in the
foreground, so the terminal, job control, the exit status and
`--die-with-parent` behave as before:

```text
launcher ─┬─ helper (background): waits for the namespace, starts slirp4netns,
          │    adds the --publish forwards, then releases the sandbox
          └─ exec env -i ... python -I -c <_NET_NS_IDENTITY> [--dns ...] --
               bash <descriptor relay> -- bwrap --unshare-user --uid --gid
               --info-fd --block-fd --sync-fd ... -- <tool>
```

- **The tool does not start before the network is ready**: bwrap waits on
  `--block-fd` until the helper writes to it.
- **The launcher, not bwrap's `--unshare-net`, creates the namespaces.**
  Because bwrap mounts `/dev`, it nests the sandbox in a second user namespace
  inside the one that owns the network namespace. slirp4netns joins the user
  namespace of the process it is given, so it would have no rights over the
  network. Unsharing in the launcher leaves its own process holding a single
  user namespace that owns the network namespace, and slirp4netns attaches to
  it.
- **The ids are mapped to themselves, not to root.** The launcher unshares and
  writes the maps itself, in about fifteen lines of Python
  (`_NET_NS_IDENTITY`), rather than calling `unshare --user --map-root-user
  --net`, for two reasons:
  - RHEL 8 is the only platform this backend exists for, and its bwrap is
    0.4.0, which cannot start under a root-only map at all (see the pasta
    notes above). An identity map leaves your uid mapped, so bwrap's
    `--uid`/`--gid` name an id that exists.
  - Nothing in the sandbox runs as uid 0, not even for the moment before bwrap
    switches back.

  util-linux grew `--map-user`/`--map-current-user` in 2.38 and could do this
  directly, but RHEL 8 has 2.32, whose `unshare` offers only
  `--map-root-user`. Writing a single-line map of your own id needs no
  privilege, so this needs neither `newuidmap`/`newgidmap` nor `/etc/subuid`
  entries — unlike rootless podman, which uses both to build a much wider map
  and then runs the payload as uid 0 inside it. slirp4netns still gets full
  capabilities when it joins, because the namespace is owned by your uid,
  which is the uid it runs as.
- Python (`python3`, or RHEL 8's `/usr/libexec/platform-python`) is therefore
  required for this backend, not only for `--publish`. Standard library only,
  3.6 or later.
- slirp4netns options: `--disable-host-loopback` (otherwise the gateway
  address `192.168.254.2` reaches the host's `127.0.0.1` on every port),
  `--cidr=192.168.254.0/24` (slirp's default, `10.0.2.0/24`, lies inside
  BNL's 10/8), the built-in DNS at `.3` (forwards port 53 only, with libslirp
  4.3.0 and later, which the launcher checks), `--mtu=65520`, and
  `--enable-seccomp` when `/etc/resolv.conf` resolves inside `/etc` or
  `/run`.
- **DNS lookups are logged**, and with no flow log they are the only account
  of what the sandbox reached for. The relay runs inside the network
  namespace and forwards to the backend's own DNS, so it is not pasta-only —
  but it cannot bind port 53 for itself here. Capabilities survive `execve`
  only for uid 0, and this namespace maps your uid, so by the time the relay
  starts (after the mapper's exec and the descriptor relay's) it holds none.
  The mapper therefore raises loopback and binds the relay's UDP and TCP
  sockets while it still can, between the unshare and the exec, and leaves
  them on descriptors 88 and 89 for `DnsRelay.adopt`. A fresh namespace also
  has `lo` down, and slirp4netns only raises it later in `configure_network`,
  so binding early removes that race too.
- **`--enable-sandbox` is not passed**, and this is the cost of the identity
  map. After joining the launcher's namespace, slirp4netns does
  `setegid(0)`/`seteuid(0)` (`main.c`); with no uid 0 mapped that fails and
  the launch stops with `setegid(0)` / `parent failed`. An unprivileged
  process may write only one line into `uid_map` — the line mapping its own
  id — so the namespace can map uid 0 *or* your uid, not both:

  | map | slirp4netns `--enable-sandbox` | bwrap 0.4.0 |
  | --- | --- | --- |
  | uid 0 only | works | dies, unless the agent runs as uid 0 |
  | your uid (what we do) | cannot `setegid(0)` | works, agent keeps its uid |

  Your uid wins: it is what the agent runs as and what every file it writes
  is owned by, whereas `--enable-sandbox` only hardens slirp4netns itself (a
  mount namespace pivot-rooted into an empty directory, plus dropping
  capabilities). `--enable-seccomp`, which bounds what a compromised libslirp
  can call, is a separate flag with no id requirement and is still passed.
  Mapping both ids needs a multi-line map, which takes `newuidmap`/`newgidmap`
  and an `/etc/subuid` entry — the way rootless podman does it, and the way to
  restore `--enable-sandbox` if it is wanted.
- slirp4netns runs in its own session (Ctrl-C does not reach it) with a
  scrubbed environment (no API keys). It exits when bwrap does: its
  `--exit-fd` is the other end of bwrap's `--sync-fd`.
- `--publish` uses slirp4netns's API socket (`add_hostfwd`, one request per
  port). The socket is in the launch's session directory (see
  [Runtime directory](#runtime-directory)), removed once the forwards are
  added, so nothing else can add forwards later.
- **On a setup failure** (slirp4netns does not start, a port cannot be
  published) the helper prints the reason and slirp4netns's last messages,
  kills the still-waiting sandbox (its pid comes from bwrap's `--info-fd`), so
  the tool never runs, and then bwrap. The exit status is then 137, not 3.
  The helper signals a process only after checking that it is the launcher
  (the helper's own parent) or a child of the launcher. If the launcher is
  already gone (the unshare or the descriptor relay failed and printed why),
  the helper notices within a poll interval, signals nothing, and exits.

### Runtime directory

The launcher keeps its network files (the slirp4netns pipes and API socket,
and the claims and logs described elsewhere in this section) in a directory of
its own, outside every sandbox:

- `$XDG_RUNTIME_DIR/bwrap-net`, else `/tmp/bwrap-net-<uid>`, mode 0700. A
  candidate is used only if its parent cannot be changed by other users (owned
  by you or root, and not writable by group or others, or sticky like `/tmp`)
  and it is then a real directory of yours with mode 0700; otherwise the next
  one is tried, and with none the launch stops (exit status 3). `TMPDIR` is
  never used: in a directory other users can write, they could swap the
  directory during the launch.
- Each launch works in its own `session.XXXXXXXX` subdirectory (`mktemp -d`), so
  several sandboxes of one user never share files there, and removes it when
  it no longer needs it.
- Both candidates are blocked paths: no sandbox can mount them, or a directory
  that contains them, as its working directory or with `--ro-path` /
  `--rw-path`. One sandbox therefore cannot reach the files of another, such as
  the slirp4netns API socket during its setup.

### Descriptor relay

bwrap reads some files from descriptors: `--file` for writable copies of
credentials and config (`bwclaude`, `bwcopilot`, `bwcodex`), `--ro-bind-data`
for generated files (the context file, `/etc/resolv.conf`, `/etc/hosts`).
pasta closes every inherited descriptor above 2, so the launcher does not open
them itself. It reserves their numbers; a short fixed bash script (the relay,
`_BWRAP_FD_RELAY_SHIM`) runs as the command of pasta or of the unshare step, opens each descriptor at its
number, from the host file or from generated text carried in an environment
variable that it then unsets, and execs bwrap. Nothing is staged on the host.

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
`OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` (an agent holding the
password and a route to an unsandboxed opencode server could drive it; the
private network namespace normally gives no such route), `OPENCODE_API_KEY`, `OPENCODE_CONSOLE_TOKEN`,
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

Accepts the common options above except `--init-auth`. Of the host's
environment it forwards `AIFAPIM_HOST`, `AIFAPIM_API_KEY` and
`AIFAPIM_TOKEN_FILE` (see "The AI gateway token" above), and only the
`OPENCODE_*` variables on the allowlist below.

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

### Database guard

The OpenCode 2 database (`opencode.db` in the data directory) is on NFS and is
always opened in WAL mode, which SQLite does not support from more than one
host. Before the sandbox starts, `bwopencode2` calls `oc2db_guard`
(`lib/opencode2-db-lock.sh`):

- it refuses to start while another host, or another OpenCode 2 build on this
  host, is using the same data directory, or after the last daily check found
  damage;
- it holds a shared lock for the life of the sandbox (a file descriptor that
  the final `exec` passes on to `bwrap`), so sessions on this host and version
  can run together;
- it starts a daily background backup (`opencode2-db backup --if-due`) and keeps
  the newest 3 compressed copies.

`OPENCODE2_DB_GUARD=off bwopencode2 ...` skips the checks once; `--exec`,
`--dry-run`, `--help` and `--version` never run them. The lock, backup and flag
files are in `~/.local/share/opencode2/opencode-db-guard`, which is not mounted
in the sandbox. The rules, the recovery steps (`opencode2-db restore` and
`rebuild`) and the limits are in [opencode2-db.md](opencode2-db.md).

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
  `OPENCODE_SERVER_PASSWORD`): an agent holding one, with a route to an
  unsandboxed server on port 49374, could run tools outside the sandbox. The
  private network namespace normally gives no such route, and `--host-port`
  refuses 49374. Others dropped include `OPENCODE_SSH_ASKPASS_*`,
  `OPENCODE_EDITOR_SSE_PORT`, `OPENCODE_PTY_HANDOFF`, `OPENCODE_DB`,
  `OPENCODE_TEST_HOME`, `OPENCODE_CONFIG*`, `OPENCODE_MODELS_PATH`/`_URL`, and
  `OPENCODE_API_KEY`. With `--dry-run`, the names (never the values) of the
  dropped host variables are printed to stderr.

### `--standalone` is enforced

By default OpenCode 2 connects to a shared background service (fixed port
49374) that survives the CLI and runs tools **outside** any sandbox. A CLI
started normally would hand tool execution to that unsandboxed server. The
sandbox's private network namespace already keeps the host's loopback, and so
the service, out of reach; as a second line of defence `bwopencode2`:

- adds `--standalone` (a private in-process server inside the sandbox) when
  `opencode2` is started with no subcommand or a directory argument, or with
  `run`, `mini`, `models`, or `stats`;
- refuses (exit status 1) `--server`, `--standalone=...`, `--no-standalone`,
  and the `service`, `serve`, `api`, `pair`, and `reload` subcommands (to run
  a server, use [`--serve`](#--serve-the-web-ui-from-a-browser), which runs it
  inside the sandbox);
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

### `--serve`: the web UI from a browser

`bwopencode2 --serve` is the one supported way to run `serve`. It runs
`opencode2 serve` **inside** the sandbox, so tools stay sandboxed (the refusal
above is about servers that run outside it), and the OpenCode web UI is then
reachable from a browser.

```text
bwopencode2 --serve [--serve-port N]
bwopencode2 --serve-ssh-config
```

- **One server per invocation.** Each `--serve` is its own sandbox with its own
  server; stop it with Ctrl-C in its terminal.
- **Published like `--publish`.** The server's port is added to
  [`--publish`](#opening-ports), so it is reachable on
  the host only at your first publish address `127.H1.H2.1:PORT` (the
  launcher prints it), **always**: the session's publish address is fixed to
  `.1` and never moves to another index, so the `--serve-ssh-config` alias
  always reaches it. If one of the session's ports is taken there (another
  of your `--publish` ports), the launch stops and says so instead.
  `--publish-addr` is refused with `--serve`. Inside the private network
  namespace the server listens on `0.0.0.0`, because forwarded connections
  arrive at the namespace's interface; nothing else reaches it. With
  `--share-net` the server listens on `127.H1.H2.1` itself. Reach it from
  another machine through an ssh tunnel. Works with both network backends.
- **Free port from a fixed range**, `24700-24709` by default (ten sessions at
  once). The range sits below the kernel's ephemeral range (32768-60999 on
  Linux), so no outgoing connection takes a server port, and clear of 49374
  (the shared OpenCode service). `BWOPENCODE2_SERVE_PORTS=LO-HI` changes it
  (at most 100 ports, 1024-65535, never including 49374; a warning is printed
  if it overlaps the ephemeral range). `--serve-port N` asks for one port in
  the range and fails if it is taken, so a saved tunnel always matches.
- **The ssh tunnel.** At start the launcher prints
  `ssh -L P:127.H1.H2.1:P <host>` with the host from `hostname -f`; then open
  `http://127.0.0.1:P/` on the machine with the browser. For all ports at
  once, `bwopencode2 --serve-ssh-config` (run on the host, as the user who runs
  the sessions: the address depends on the uid) prints a block for
  `~/.ssh/config` on the machine with the browser (alias `<host>-oc`, one
  `LocalForward` per port of the range to `127.H1.H2.1`,
  `ExitOnForwardFailure no` so a busy local port does not stop the others).
  The port is chosen free on `127.H1.H2.1`, and not claimed there by another
  of your sandboxes. Keep the same port number
  at both ends: the browser cookie is named by it (see below). Add `User` and
  `ProxyJump` to the alias as needed. Each user has their own address, so
  sessions of different users on one host no longer compete for
  `127.0.0.1:24700-24709`.
- **Signing in.** The web UI opens on a "Connect to a server" page that asks
  for a pairing link and offers **Use password**. Do not run `opencode pair`
  (the wrapper refuses it, and outside the sandbox it points at the shared
  service). Instead the sandbox runs a small wrapper, not `opencode2 serve`
  directly: it starts the server, waits until it answers, asks it for a
  one-time pairing code and prints the link twice, for the tunnel
  (`http://127.0.0.1:<port>/auth/connect/<code>`) and for this host
  (`http://127.H1.H2.1:<port>/...`). Open one to be signed in, with the 30-day cookie, without typing the password.
  The link works once and expires after 5 minutes; after that, or if the
  printed link failed, click **Use password** and enter the password. The
  password reaches `curl` on its standard input (`-K -`), never on a command
  line, because a process in the sandbox is visible to `ps` on the host. The
  wrapper stays in the foreground and stops the server on Ctrl-C or when the
  sandbox ends.
- **Password.** The server needs one (Basic auth, user `opencode`). The launcher uses a **random password for each
  session** and prints it at start. To use a fixed one, export
  `BWOPENCODE2_SERVE_PASSWORD` (at least 12 characters, for example from
  `load-env`); the launcher prints nothing about it. Either way it reaches the
  server only as `OPENCODE_PASSWORD` in the sandbox environment (the host's
  own `OPENCODE_PASSWORD` is still dropped) and is never written to a file.
  Trade-off: a sandboxed agent can read its own environment, so it can read its
  password. With a random password that only reaches its own session. With a
  fixed one it reaches every session that shares it, and any sandboxed agent on
  the host could drive them all. Prefer the random default.
- **Port claims.** A file `~/.local/state/bwopencode2/serve/<port>.session` (host
  side, not mounted in the sandbox; the port, launcher pid and its process
  start time, host, directory and start date, no secret) stops two launchers
  picking the same port; the port must also be free on the address checked
  (`127.H1.H2.1`, or `--publish-addr`), and the address is claimed as for any
  `--publish`.
  A claim
  whose process is gone is stale and is removed on the next `--serve`. The
  launcher ends in `exec`, so it cannot retry or clean up afterwards; the
  remaining race is another program taking the port in the moment before the
  server binds it, and then the server fails to start with an error: run it
  again.
- **Limits.** `--serve` takes no opencode2 arguments and cannot be combined with
  `--exec`; `serve`, `--server`, `pair` and the other refused arguments stay
  refused. `--dry-run` shows the command (password redacted) and claims
  nothing.
- **Cookie.** The server names its login cookie `opencode_session_<port>` from
  the port in the address the browser used (checked with 2.2.6 using curl), so
  sessions on different ports do not log each other out. The cookie holds an
  expiry (30 days) and a hash made with the server password: with a fixed
  password a cookie is accepted by any session that shares it, with a random
  one it stops working when the session ends.

Checked against OpenCode 2.2.6 with curl and an isolated data directory: the
server answers 401 without the password and 200 with it, serves the web UI page
without a password, and `POST /api/pair` with the password gives a one-time link
that sets the cookie. The pairing wrapper was run in a sandbox against a
throwaway server (isolated data directories): it printed a link that signed in
with `Set-Cookie: opencode_session_<port>` and worked only once, the password
appeared in no process command line that was sampled, and TERM stopped the
server. The web UI's "Use password" page was seen in a screenshot. Not checked,
because it needs a browser or the real launcher: signing in with the link in a
browser, entering the password, a Ctrl-C from the terminal, and two sessions
open in one browser. Whether the agent can read `OPENCODE_PASSWORD` in tool
output (`printenv`) is also unchecked.

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
| `--persist-config` | Bind-mount `~/.codex/config.toml` read-write into the sandbox so changes (e.g. project-trust grants) persist across sessions. Without this flag, `config.toml` is copied read-write into the sandbox's tmpfs for the session and the copy is discarded on exit. Concurrent `--persist-config` sessions may race on writes |

Note: Codex CLI also enforces its own inner Landlock-based sandbox for
agent tool calls. The outer `bwrap` here is complementary — it scopes
the entire Codex process tree, not just agent-issued commands.

## `lib/bwrap_sandbox_lib.sh`

Shared sandbox-building primitives sourced by all `bw*` wrappers. Not
intended to be executed directly. The library header documents the
public function surface (sandbox construction, dynamic mount discovery,
binary masking, environment scrubbing, `build_sandbox_context` with its
`SANDBOX_CONTEXT_*` variables (see [Sandbox context](#sandbox-context)), and
the network functions `detect_net_capabilities`, `net_add_publish`,
`net_add_host_port`, `net_set_publish_addr`, `net_set_share`, `net_set_backend`,
`net_print_help` and `build_net_isolation` (see [Network](#network)).
