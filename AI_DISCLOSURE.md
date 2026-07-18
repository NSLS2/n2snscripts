---
tools-used:
  - OpenCode
models-used:
  - claude-opus-4-8
  - claude-sonnet-4-6
  - claude-sonnet-5
  - gpt-5.6-sol
providers:
  - Anthropic
  - OpenAI
scope:
  human-authored: >
    Repository policy and governance text, and final human review of
    all merged changes.
  ai-generated: >
    Shell wrapper scripts (bin/, lib/), the `azoidcapp` Python helper,
    documentation (docs/), and CI/lint configuration — all with human
    review and validation.
last-updated: 2026-07-18
---

# AI Disclosure

This file describes how AI tools are used in this repository.

## Disclosure levels

This repository uses the vocabulary defined by the
[W3C AI Content Disclosure Community Group](https://www.w3.org/community/ai-content-disclosure/)
(a community-group effort, not a ratified W3C standard).
Four levels are defined:

| Level | Meaning |
| --- | --- |
| `none` | No AI tools were used. |
| `ai-assisted` | AI contributed, but a human authored and reviewed. |
| `ai-generated` | AI generated the content; a human reviewed it. |
| `autonomous` | AI produced the content without human review. |

Per the community group's "absence = unknown" principle, files
without an explicit disclosure tag do not imply a specific level.

## Scope of AI use in this repository

**Repository policy and governance text** — including this disclosure
file — is human-authored. The final text is authored and validated by
human contributors.

**Source code in this repository is largely AI-generated:** AI tools
produce the initial implementation of the sandboxed AI CLI wrapper
scripts (`bin/bwopencode`, `bin/bwcodex`, `bin/bwclaude`,
`bin/bwcopilot`) and the shared `lib/bwrap_sandbox_lib.sh` sandbox
library, as well as `bin/gh-protect-branch`, `bin/azoidcapp`,
`bin/pemdecompose`, `lib/gpg-passwd.sh`, associated documentation, and
CI/lint configuration. A human contributor reviews, tests, and
validates all content before merging; the human remains accountable
for every merged change.

## Tools and models

AI assistance in this repository is provided via
**OpenCode** using Anthropic models for implementation and OpenAI GPT-5.6-sol
for critical code review. See the metadata block at the top of this file for
the current list of models.

Per-commit attribution uses the `Assisted-by: AGENT:MODEL` trailer
format. Those per-commit trailers are the authoritative record of
which model contributed to a specific change.

## Purpose of use

AI tools are used to:

- Draft and refactor the bubblewrap-sandboxed AI CLI wrapper scripts
  (`bwopencode`, `bwcodex`, `bwclaude`, `bwcopilot`) and the shared
  `bwrap_sandbox_lib.sh` library.
- Draft and refactor `gh-protect-branch`, `azoidcapp`, `pemdecompose`,
  and `gpg-passwd.sh`.
- Perform critical code review (GPT-5.6-sol).
- Generate commit messages, code review responses, and documentation.

## Input data / datasets

Only repository source files, public documentation, and
non-sensitive prompts are provided as input to AI models.

## Limitations and known biases

- LLM output may contain errors, hallucinations, or bias
  inherited from training data.
- All AI-generated content is independently reviewed and validated
  by a human contributor before it is merged.
- The models listed above do not have access to internal BNL
  systems, live data, or non-public information unless explicitly
  provided in a prompt.

## Reviewer disclaimer

AI-generated content in this repository has been reviewed.
Inclusion of AI-generated material does not substitute for human
accountability: the contributing staff member is responsible for the
correctness and appropriateness of every merged change.
