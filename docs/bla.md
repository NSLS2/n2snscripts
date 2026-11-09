# `bla`

Starts a beamline coding agent as the agent service account. Beamline staff do
not run the `bw*` wrappers as that account themselves:

```bash
bla            # the default agent, opencode
bla opencode2  # a named one
```

Staff run it as themselves; it re-runs itself through `sudo` as the agent
account.

The launcher, not the caller, decides what the agent can reach. Only the agent
name is taken from the command line, from a fixed list, and no option is passed
through — so a caller cannot widen the sandbox with `--exec`, `--rw-path`,
`--ro-path` or `--n2c-token`.

## Agents

| Name | Wrapper |
| --- | --- |
| `opencode` | `bwopencode` |
| `opencode2` | `bwopencode2` |
| `claude` | `bwclaude` |

The wrapper is run by absolute path, from the directory this script is in.
`sudo` replaces `PATH` with its `secure_path`, which holds neither
`/opt/nsls2/scripts/bin` nor `/usr/local/bin`, and the `profile.d` snippet that
adds them is only read by a login shell.

## What the launcher sets

- **The AI gateway key.** Read from `/etc/nsls2/agent/aifapim/key` and passed
  as `AIFAPIM_API_KEY`, with `AIFAPIM_HOST`. Every `bw*` wrapper understands
  those two; `bwclaude` turns them into `ANTHROPIC_FOUNDRY_*` itself. The file
  is never mounted into the sandbox.
- **The NSLS-II API tokens.** `N2SN_CREDS_DIR=/run/nsls2/agent/creds` and
  `--n2c-token all`, so the wrapper mounts every token the root minter keeps,
  read-only, one file each. `all` rather than a list of names because the
  minter decides which tokens the account gets; the launcher does not need
  changing when that set does.
- **The working directory.** `~<calling user>/agent`, created on first use
  along with the ACLs that share it: traverse-only for the agent account on
  the home, read-write on the agent directory, with default entries for both
  accounts so each can read what the other writes. This runs as the caller,
  who owns their home, so it needs no root and no prior ansible run.
- **The profile collection.** `~<caller>/.ipython/profile_collection`, mounted
  read-write so the agent can edit and commit in the real repository, and
  resolved first because on some hosts it is a symlink to shared storage and
  the sandbox mounts the target. The same ACLs are applied to it: without
  default entries, the git objects the agent writes are unwritable by the
  caller, who is then locked out of committing after the agent has — which is
  the whole hand-off. Not fatal if the filesystem refuses them, since the
  agent is still useful read-only.

  A caller cannot aim that symlink at another beamline: the launcher resolves
  it as them and refuses a target they cannot write. That catches a mistake
  rather than a determined caller, who owns the link and can repoint it after
  the check; scoping the agent account per beamline is what would make it
  pointless.
- **A git identity.** The agent account has no git config, and git refuses to
  work in a repository someone else owns, so the launcher writes a
  `.gitconfig` in `$HOME` with `user.name` naming the caller
  (`<caller> (beamline agent)`) and `safe.directory` for the agent directory
  and the profile collection. There are no GitHub credentials in the sandbox,
  so the agent commits and a person pushes; the launcher says so at startup
  and gives the command.
- **`HOME`.** A directory per session, `mktemp -d` under
  `/run/nsls2/agent/home/<caller>/`, which the `n2c_agent` role makes on the
  tmpfs next to the tokens. The wrappers create their authoring directories
  (`~/.config/opencode/{skills,agents,commands}`) there on the host before
  bind-mounting them into the sandbox, so it has to exist and be writable.

  Per session, not per caller: two agents started at once would otherwise
  race to create the same database, and one dies with a `CREATE TABLE`
  error. It also keeps two people sharing an operator account from reading
  each other's conversations.

  It cannot be the caller's agent directory: a wrapper refuses to run where
  the working directory is `$HOME` or above it, because that would mount the
  whole home tree.
- **`XDG_CACHE_HOME`.** `/run/nsls2/agent/home/<caller>/cache`, shared across
  that caller's sessions, so the ~11 MB the agent downloads on a cold start is
  not fetched again each time. It holds nothing personal, unlike the session
  database. `npm` reads `~/.npm` rather than this, and `npm_config_cache` does
  not survive the sandbox's fixed variable list, so the launcher writes an
  `.npmrc` in `$HOME` pointing at the same place.
- **`PATH`.** `sudo` replaces it with its `secure_path`, which does not hold
  `/usr/local/bin`, where the agents are installed, so the wrappers would not
  find them.

Both the key and the tokens come from the `n2c_agent` role in NSLS2/ansible.

## Audit

Before anything starts:

```text
bla: agent start: user=<caller> host=<host> agent=<name> dir=<dir>
```

to syslog at `auth.notice`, so an action is traceable to a person even though
the agent runs as a shared account. If the log line cannot be written the run
stops: no log line, no agent.

`SUDO_USER` names the caller, so the launcher refuses to run without it, and
refuses when the caller is root.

## Account check

`/opt/nsls2/libexec/agent-account-check` (ansible `base` role) runs first, as
it does in the `bw*` wrappers, so a refused account never reaches the audit
line or the gateway key. When the script is not installed this is a no-op.
