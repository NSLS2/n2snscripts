# beamline-agent

Starts a beamline coding agent as the agent service account, so beamline staff
do not run the `bw*` wrappers as that account themselves. The command is `bla`:

```bash
bla            # the default agent, opencode
bla opencode2  # a named one
```

Staff run it as themselves; it re-runs itself through `sudo` as the agent
account.

beamline-agent, not the caller, decides what the agent can reach. Only the
agent name is taken from the command line, from a fixed list, and no option is
passed through — so a caller cannot widen the sandbox with `--exec`,
`--rw-path`, `--ro-path` or `--n2c-token`.

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
- **The GitHub push token.** One of those tokens,
  `/run/nsls2/agent/creds/github-push/token`: a GitHub App installation token
  for this beamline's profile collection repository only, with `contents:
  write`, valid for an hour and renewed every 15 minutes. The launcher says at
  startup whether it is there and fresh. Without it the agent still edits and
  commits, and a person pushes.
- **The working directory.** `~<calling user>/agent`, created on first use
  along with the ACLs that share it: traverse-only for the agent account on
  the home, read-write on the agent directory, with default entries for both
  accounts so each can read what the other writes. This runs as the caller,
  who owns their home, so it needs no root and no prior ansible run.
- **The profile collection.** `~<caller>/.ipython/profile_collection`, resolved
  first because on some hosts it is a symlink to shared storage and the
  sandbox mounts the target. The agent does not change it there. It clones
  the repository over HTTPS into the agent directory, commits in the clone
  and pushes to `main`; the caller then runs `git pull --ff-only` in the live
  profile collection, and the change is live when IPython next loads the
  profile. The launcher prints that command at startup. The workflow itself
  is the `profile-collection-change` skill in NSLS2/n2snskills.

  A clone and not a worktree, because the agent account often cannot write
  the live repository. At SMI it is on NFSv4 owned by the operator account
  and the beamline staff group, the agent account is in no group, and POSIX
  ACLs cannot be set there, so `git worktree add` fails while a clone works.
  The mount follows what the account can do: read-write where it can write
  the directory (local storage, where the ACLs below apply), read-only where
  it cannot.

  On a filesystem that takes POSIX ACLs the launcher still applies the same
  ACLs as on the agent directory. Not fatal if the filesystem refuses them.

  A caller cannot aim that symlink at another beamline: the launcher resolves
  it as them and refuses a target they cannot write. That catches a mistake
  rather than a determined caller, who owns the link and can repoint it after
  the check; scoping the agent account per beamline is what would make it
  pointless. The push token is for this host's beamline repository whatever
  the link points at.
- **A git config.** The launcher writes a `.gitconfig` in `$HOME`, which is
  the one file of `$HOME` that git reads and the wrappers mount (read-only).
  It holds:

  - `safe.directory` for the agent directory and the profile collection. git
    refuses every command in a repository someone else owns, so without it
    the agent cannot even run `git status`.
  - A commit identity, `xfagent (bla for <caller>) <xfagent@<host>>`, so a
    pushed commit can be traced to the person who started the session.
    Pushes show on GitHub as the `nsls2-profile-push` app.
  - A credential helper for `https://github.com` only. It reads the push
    token file each time git asks and answers with the user name
    `x-access-token`. The file path is in the config, never the token, so a
    token renewed during a session is picked up, and with no token git fails
    rather than asks. It is inline in the config because a helper script in
    `$HOME` would not be in the sandbox. There is still no SSH and no `gh`
    login.
  - `bla.caller`, `bla.agentDir` and `bla.profileCollection`: whose session
    this is, the agent directory and the mounted profile collection. `$HOME`
    in the sandbox is the session directory, so `~/agent` is not the agent
    directory there; the agent reads these with `git config --get`.

  The model can read the push token, as it can the other tokens. It is good
  for at most an hour and for one repository, but it is renewed while the
  session runs.
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
