# `bl-agent`

Starts a beamline coding agent as the agent service account. Beamline staff do
not run the `bw*` wrappers as that account themselves:

```bash
sudo -u xfagent /opt/nsls2/scripts/bin/bl-agent opencode2
```

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
- **The working directory.** `~<calling user>/agent`, which must exist and be
  writable by the agent account. The host setup role creates it and gives the
  agent account traverse-only access to the home above it.
- **`HOME`.** `/home/xfagent`, a tmpfs the host setup role mounts. The wrappers
  create their authoring directories (`~/.config/opencode/{skills,agents,commands}`)
  there on the host before bind-mounting them into the sandbox, so it has to
  exist and be writable. On a tmpfs nothing the agent writes outside the
  caller's agent directory survives a reboot. It cannot be the working
  directory itself: a wrapper refuses to run where the working directory is
  `$HOME` or above it, because that would mount the whole home tree.
- **`PATH`.** `sudo` replaces it with its `secure_path`, which does not hold
  `/usr/local/bin`, where the agents are installed, so the wrappers would not
  find them.

Both the key and the tokens come from the `n2c_agent` role in NSLS2/ansible.

## Audit

Before anything starts:

```text
bl-agent: agent start: user=<caller> host=<host> agent=<name> dir=<dir>
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
