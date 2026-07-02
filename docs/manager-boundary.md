# Manager Boundary

Status: accepted
Last verified: 2026-07-02

Related: [README](../README.md), [Registry Contract](registry-contract.md),
[Usage](usage.md), [Contributing](contributing.md),
[registry manifest](../skills.registry.yaml),
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

`scripts/skills_sync.rb --plan --json` is also read-only. Each action includes
`management.owner`. `upstream-manager` actions include a pinned command to run
for one reviewed skill and agent. `manual-review` actions are not safe
upstream-manager writes without more review. `none` means no manager write is
needed.

Unsupported adapters, shared roots such as `~/.agents/skills`, and stale
adapter cleanup stay `manual-review` until the planner can prove an upstream
manager command will verify clean on the next doctor/sync pass. The only
exception is an explicit reviewed `manager-copy` profile: it models a copied
folder owned by the upstream manager and verifies the copy by digest instead of
expecting a symlink.

There is no local `--apply` fallback in this repository. If the upstream manager
cannot express a safe write, document the concrete upstream gap and keep the
action in manual review instead of adding a competing local installer.

## Non-Goals

Do not add custom code here for:

- broad multi-skill install/update/remove workflows
- local install/update/remove fallbacks that duplicate the upstream manager
- lock restore that duplicates upstream `skills-lock.json` behavior
- automatic stale adapter deletion
- unattended bootstrap across every consumer root
- hidden unpinned `npx skills` usage
- direct mutation of consumer folders before a plan has been reviewed

Those features belong upstream unless a concrete upstream gap is documented with
a primary source or reproducible failure.

## Proven Manager-Owned Targets

Two global Codex manager-copy targets are already proven on the default example
profile:

| Skill | Manager command | Adapter target | Lock key |
| --- | --- | --- | --- |
| `code-review` | `npx --yes skills@1.5.14 add fiveonecode/agent-skills --skill code-review --agent codex --global --yes` | `~/.agents/skills/code-review` | `skills.code-review` |
| `harness-engineering` | `npx --yes skills@1.5.14 add fiveonecode/agent-skills --skill harness-engineering --agent codex --global --yes` | `~/.agents/skills/harness-engineering` | `skills.harness-engineering` |

The proof profiles and initial drift report are historical artifacts under
`docs/history/`:

- `docs/history/manager-pilot-code-review-codex-global.profile.yaml`
- `docs/history/manager-pilot-harness-engineering-codex-global.profile.yaml`
- `docs/history/skill-registry-drift-report-2026-06-26.md`

Do not add another proof target as the next default action. New managed targets
should be introduced only after the public registry contract, usage workflow,
contribution workflow, and catalog/update tasks are in place.

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

1. Add generated public catalog artifacts and catalog drift validation.
2. Add upstream-update workflow checks for stale external pins such as
   `swiftui-pro`.
3. Define new-machine and repo-level setup/update workflows around pinned
   manager commands and doctor/sync verification.
4. Expand managed profiles only after the contract, catalog, and update
   workflows are in place.
