# `gh-protect-branch`

Admin helper (not a sandbox wrapper) that applies NSLS-II standard
branch protection rules to a GitHub repository via the GitHub API
through `gh(1)`. Enforces the full NSLS-II branch protection policy
across two layers.

Because the script is named `gh-*`, it is also auto-discovered by `gh`
as an extension, so `gh protect-branch <options> <owner/repo> [branch]`
works equivalently.

## Protections applied

### Repository ruleset (all branches)

A ruleset named `nsls2-branch-protection` targeting `~ALL` branches
enforces:

- PRs required (no direct push)
- >= 1 approving review, with stale-review dismissal on new commits
- The last pusher's commit must be approved by a different reviewer
- Code owner review (CODEOWNERS entries, when present)
- All PR conversations resolved before merge
- Branch deletion blocked
- Force pushes (non-fast-forward) blocked
- Required signed commits (default on; suppress with `--no-sign-commits`)

The script is idempotent: re-running it updates the existing ruleset
rather than creating a duplicate.

### Classic branch protection (named branch only, default `main`)

- All rules enforced on admins
- Optionally restricts stale-review dismissal to a named GitHub team
  (`--approvers <team-slug>`) — only members of that team can dismiss a
  stale review, so a team member must re-approve after new commits are
  pushed; the team slug is validated against the GitHub API before
  protection is applied (a nonexistent team is a hard error)
- Belt-and-suspenders signed commits on the named branch (in addition to
  the ruleset enforcement above)

### Repository settings

- Secret scanning and push protection enabled

### Branch creation restriction (optional)

A second ruleset named `nsls2-restrict-branch-creation` targeting
`~ALL` branches can be applied in addition to, or instead of, full
branch protection. It blocks creation of any branch whose name does not
match one of the excluded (allowed) patterns.

Allowed patterns are supplied via `--exclude-branches` as a
comma-separated list of fnmatch branch-name strings. Each entry is
automatically prefixed with `refs/heads/` so a bare name such as `main`
matches correctly. fnmatch wildcards (`*`, `**`, `?`) are supported, so
`release/**` allows nested names like `release/2025/q1`.

The default excluded patterns (when `--exclude-branches` is omitted)
are `main,preview`.

## Usage

```text
gh-protect-branch [--approvers <team-slug>] [--no-sign-commits]
                  [--restrict-branch-creation [--exclude-branches <csv>]]
                  <owner/repo> [branch]
gh-protect-branch --only-restrict-creation [--exclude-branches <csv>]
                  <owner/repo>
gh-protect-branch --help
```

| Option / Argument | Description |
| --- | --- |
| `--approvers <team-slug>` | GitHub team slug whose members are the only ones allowed to dismiss stale reviews. The team is validated via the GitHub API before protection is applied (requires `read:org` scope in addition to `admin:repo`). |
| `--no-sign-commits` | Skip enforcing signed commits. Incompatible with `--only-restrict-creation`. |
| `--restrict-branch-creation` | Apply the creation-restriction ruleset in addition to full branch protection. Mutually exclusive with `--only-restrict-creation`. |
| `--only-restrict-creation` | Apply only the creation-restriction ruleset; skip full branch protection, classic rules, and secret-scanning changes. Mutually exclusive with `--restrict-branch-creation`, `--approvers`, and `--no-sign-commits`. |
| `--exclude-branches <csv>` | Comma-separated fnmatch patterns for branches whose creation is allowed. Default: `main,preview`. At least one non-empty pattern is required. Requires `--restrict-branch-creation` or `--only-restrict-creation`. |
| `<owner/repo>` | Repository in `owner/repo` format (required). |
| `[branch]` | Primary branch to protect via the classic API (default: `main`). The ruleset always targets all branches regardless of this argument. Not used with `--only-restrict-creation`. |

## Examples

```bash
# Standard full protection
gh-protect-branch NSLS2/n2snscripts

# Standard protection on a non-default branch
gh-protect-branch NSLS2/n2sndocs develop

# With approver team restriction (team validated before applying)
gh-protect-branch --approvers n2sn-admins NSLS2/n2snscripts
gh-protect-branch --approvers n2sn-admins NSLS2/n2sndocs main

# Skip the signed-commit requirement
gh-protect-branch --no-sign-commits NSLS2/n2snscripts

# Full protection plus branch creation restriction (default: allow main,preview)
gh-protect-branch --restrict-branch-creation NSLS2/n2sndocs

# Full protection plus creation restriction with custom allowed patterns
gh-protect-branch --restrict-branch-creation \
    --exclude-branches main,preview,release/** NSLS2/n2sndocs

# Creation restriction only (no PR/signing changes)
gh-protect-branch --only-restrict-creation NSLS2/n2sndocs

# Creation restriction only with custom allowed patterns
gh-protect-branch --only-restrict-creation \
    --exclude-branches main,preview NSLS2/n2sndocs
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Usage error or missing dependency (includes team-not-found / `read:org` missing) |
| `2` | `gh` not authenticated |
| non-zero | `gh` API call failed; exit code is from `gh` (typically `1`) |

## Caveats

- Requires `gh(1)` authenticated with `admin:repo` scope on the target
  repository. The `--approvers` preflight check also requires `read:org`
  scope (GitHub team API requirement); a 404 may mean the team does not
  exist **or** that the token lacks `read:org`.
- Secret scanning requires the repository to belong to an organization on
  GitHub Team or Enterprise Cloud, or to be a public repository.
- Repository rulesets (both `nsls2-branch-protection` and
  `nsls2-restrict-branch-creation`) require GitHub Team or Enterprise on
  private repositories.
- The `--approvers` team slug is validated via the GitHub API before any
  protection is applied. GitHub's branch-protection API silently ignores
  unknown teams in `dismissal_restrictions`; the pre-flight check catches
  this and exits with an error rather than applying a misconfigured rule.
- The `require_code_owner_review` rule is a no-op if no `CODEOWNERS` file
  exists or no entry matches the changed files.
- Re-runs are idempotent: both rulesets are updated in place rather than
  duplicated.
- Signed-commit enforcement is applied to all branches via the ruleset
  and additionally as a belt-and-suspenders rule on the named branch via
  the classic `required_signatures` endpoint.
- fnmatch patterns in `--exclude-branches` are automatically prefixed
  with `refs/heads/`. Do not include `refs/heads/` yourself; it would
  produce a doubled prefix.
