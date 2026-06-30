# Manager Boundary

Status: accepted
Last verified: 2026-06-30

Related: [README](../README.md), [registry manifest](../skills.registry.yaml),
[example local profile](../profiles/machine/example-local-skills.yaml)

## Decision

Use the upstream `skills` CLI as the normal write engine for skill
install/update/remove operations. Keep this repository focused on public skill
sources, registry policy, reviewable pins, doctor checks, and planning output.

This repository must not become a competing package manager.

## Source Of Truth Split

`fiveonecode/agent-skills` owns:

- reusable public skill source folders
- `skills.registry.yaml` source ownership and update policy
- `skills.lock.yaml` reviewed resolved pins and digests
- profile examples that describe intended consumer exposure
- `scripts/skills_doctor.rb` policy, source-health, and drift checks
- `scripts/skills_sync.rb --plan` reviewable adapter planning output
- narrow fallback apply behavior only when an upstream manager gap is proven

The upstream `skills` CLI owns:

- fetching skill sources from GitHub, GitLab, git URLs, HTTP(S) endpoints, or
  local paths
- normal `add`, `remove`, `list`, `find`, and `update` behavior
- agent path mapping for supported agents
- symlink versus copy installation mechanics
- project `skills-lock.json` writes
- global skill lock state under `$XDG_STATE_HOME/skills/.skill-lock.json` or
  `~/.agents/.skill-lock.json`

Consumer folders such as `.agents/skills`, `.claude/skills`, `~/.codex/skills`,
`~/.claude/skills`, and shared agent roots are adapter outputs. Do not hand-edit
imported copies there when the source belongs to this registry or to an external
upstream.

## Reviewed Commands

Pin the CLI version in documented and automated commands so local package cache
state does not silently change behavior:

```bash
npx --yes skills@1.5.14 --version
```

Install one skill for Codex in the current project:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --yes
```

Install one skill for Claude Code in the current project:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent claude-code \
  --yes
```

Install one skill globally for Codex:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --global \
  --yes
```

List observed global state in machine-readable form:

```bash
npx --yes skills@1.5.14 ls --global --json
```

Run this repository's policy checks after any manager write:

```bash
scripts/skills_doctor.rb
scripts/skills_doctor.rb --check-upstream
scripts/skills_doctor.rb --check-manager
scripts/skills_sync.rb --plan --json
```

`--check-manager` is explicitly read-only. It reads the pinned manager list,
global manager lock state, and project `skills-lock.json` files as evidence; it
does not run `skills add`, `skills update`, `skills remove`, or any adapter
rewrite.

Use `scripts/skills_sync.rb --apply` only for a reviewed fallback profile and
only for one skill and one consumer:

```bash
scripts/skills_sync.rb --apply \
  --profile /path/to/reviewed-apply-profile.yaml \
  --skill code-review \
  --consumer agents_user
```

## Non-Goals

Do not add custom code here for:

- broad multi-skill install/update/remove workflows
- lock restore that duplicates upstream `skills-lock.json` behavior
- automatic stale adapter deletion
- unattended bootstrap across every consumer root
- hidden unpinned `npx skills` usage
- direct mutation of consumer folders before a plan has been reviewed

Those features belong upstream unless a concrete upstream gap is documented with
a primary source or reproducible failure.

## Current Upstream Limits To Respect

As of `2026-06-30`, do not treat upstream lock restore as a stable bootstrap
contract. The `skills` CLI exposes `experimental_install` for restoring from
`skills-lock.json`, and open upstream issues track restore/update edge cases.

Known limits that should keep local automation conservative:

- stable lock restore is still requested in upstream issues
  [#283](https://github.com/vercel-labs/skills/issues/283) and
  [#549](https://github.com/vercel-labs/skills/issues/549)
- update failure handling is tracked in
  [#1519](https://github.com/vercel-labs/skills/issues/1519)
- project update source handling is tracked in
  [#1530](https://github.com/vercel-labs/skills/issues/1530)
- root-level `SKILL.md` sibling-file handling is tracked in
  [#1517](https://github.com/vercel-labs/skills/issues/1517)
- stale project lock entries after remove are tracked in
  [#977](https://github.com/vercel-labs/skills/issues/977)

## Primary Sources

- Vercel Agent Skills documentation:
  <https://vercel.com/docs/agent-resources/skills>
- `skills` package:
  <https://www.npmjs.com/package/skills>
- `skills` upstream README and source:
  <https://github.com/vercel-labs/skills>
- Pinned upstream source audited for this decision:
  <https://github.com/vercel-labs/skills/tree/2adcfe5a4cce0ce5f4d5547a997b2a161ec5d127>
- Codex Skills documentation:
  <https://developers.openai.com/codex/skills>
- Claude Code Skills documentation:
  <https://code.claude.com/docs/en/skills>

## Next Local Slices

1. Extend `scripts/skills_sync.rb --plan --json` so planned actions can include
   recommended `npx skills` commands where upstream can safely own the write.
2. Re-evaluate whether the narrow fallback `--apply` path is still needed after
   those checks prove which targets the upstream manager covers.
