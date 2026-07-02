# Registry Contract

Status: active-partial
Last updated: 2026-07-02

Related: [README](../README.md), [Usage](usage.md),
[Contributing](contributing.md), [Manager Boundary](manager-boundary.md),
[registry manifest](../skills.registry.yaml), [lock file](../skills.lock.yaml),
[example machine profile](../profiles/machine/example-local-skills.yaml)

## Objective

`fiveonecode/agent-skills` is the public source and policy registry for
reusable 51Code agent skills. The registry exists so one reviewed skill source
can be exposed into multiple agent surfaces without copied-source drift.

The non-negotiable contract is:

- registry-covered reusable skills have one source owner
- registry-covered reusable skills have lock/version metadata
- registry-covered reusable skills have generated adapter views for Codex,
  Claude Code, and repo-local consumers

## Coverage State

The registry is active as the source and policy layer, but coverage is
currently partial.

- Skills listed in `skills.registry.yaml` and `skills.lock.yaml` are the
  current registry-covered set.
- Other top-level `SKILL.md` folders are unclassified backlog until a follow-up
  PR assigns source ownership, update policy, supported clients, scopes, and
  lock/version metadata.
- Public docs and verification must not imply that unregistered folders already
  satisfy the reusable-skill contract.

## Scope

In scope:

- public reusable skill source folders in this repository
- `skills.registry.yaml` source ownership and update policy
- `skills.lock.yaml` reviewed resolved pins and digests
- machine and repo profile examples that describe intended exposure
- doctor checks for source, lock, profile, upstream, manager, and adapter drift
- sync-plan output that generates reviewable adapter actions and pinned manager
  commands where the upstream manager can own the write
- public docs that let external users install skills without private 51Code
  context

Out of scope:

- private 51Code client context
- secrets, browser profiles, transcripts, runtime state, or machine-local paths
- a custom package manager
- local install/update/remove fallback code in `scripts/skills_sync.rb`
- unattended cleanup of stale adapter folders
- broad bootstrap automation before the contract, catalog, and update workflow
  are validated

## Source Ownership

Each registry-covered reusable skill must have exactly one active source owner.

| Source type | Meaning | Required metadata |
| --- | --- | --- |
| `registry-local` | 51Code owns and edits the skill in this repository, including maintained local forks of upstream skills. | `source.path`, exported names, supported clients, scopes, update policy, lock digest. Preserve upstream provenance and fork reason in `notes` or adjacent docs when relevant. |
| `external-git` | A third-party upstream remains authoritative. | Upstream URL, path, exact pinned tag, observed commit, observed date, update policy, lock digest. Record current license review status in `notes` or the PR body until the registry schema grows a dedicated field. |

Do not edit consumer copies as source. Consumer roots such as
`~/.codex/skills`, `~/.agents/skills`, `~/.claude/skills`, `.agents/skills`,
and `.claude/skills` are adapter views.

If a PR modifies a third-party skill's content, it must either reclassify that
maintained copy as `registry-local` and preserve upstream provenance in
`notes` or adjacent docs, or move the customization into a separate
registry-owned wrapper skill.

## Version And Lock Policy

`skills.registry.yaml` records the intended source and update policy.
`skills.lock.yaml` records the reviewed resolved state used by doctor and sync
planning.

Every registry-covered reusable skill must be backed by lock/version metadata:

- registry-local skills require a digest of the source folder
- external-git skills require an exact pinned tag plus observed commit
- external-git update PRs must keep `source.observed_commit` aligned with the
  reviewed tag
- `source.observed_at` is review evidence for that tag and should stay aligned
  in the registry entry or PR body until doctor/sync/lock enforcement supports
  it end-to-end
- lock regeneration must be explicit and reviewed
- update PRs must show registry diff, lock diff, catalog-facing description
  impact, and verification output

Commit-only external pins are not yet part of the supported public contract.
`scripts/skills_doctor.rb` and `scripts/skills_sync.rb` still require
`source.pinned_tag`, so contract docs must stay tag-based until that tooling
support exists end-to-end.

"Latest" means latest approved on `main` or a tagged release of this registry,
not unreviewed latest from an arbitrary upstream source.

## Adapter Views

Adapter views are generated from registry, lock, and profile data. The normal
write engine is the upstream `skills` CLI where it can safely target the
requested agent and scope.

Generated adapter views must cover these consumer classes:

| Consumer class | Typical roots | Current policy |
| --- | --- | --- |
| Codex | `.agents/skills`, `~/.agents/skills`, `~/.codex/skills` | Use pinned upstream manager commands where proven; verify manager-owned copies by digest. |
| Claude Code | `.claude/skills`, `~/.claude/skills` | Use pinned upstream manager commands where supported; keep unsupported adapter shapes in manual review. |
| Repo-local consumers | repo `.agents/skills`, repo `.claude/skills` | Generate from repo profiles; do not commit copied reusable skills as hidden forks. |

`scripts/skills_sync.rb --plan --json` is the local generator for reviewable
adapter plans. It never writes files. Actions include `management.owner`:

- `upstream-manager`: run the emitted pinned `npx skills@1.5.14` command
- `manual-review`: no safe manager command can be emitted yet
- `none`: no manager write is needed

`manager-copy` means this registry verifies a copied directory owned by the
upstream manager. It does not authorize local copy/install code.

## Manager Boundary

Use the upstream `skills` CLI for normal install/update/remove behavior,
supported agent path mapping, and upstream lock writes. Use this repository for
source folders, registry policy, reviewed pins, doctor checks, sync planning,
and public catalog metadata.

Do not add local install/update/remove behavior to `scripts/skills_sync.rb`.
Unsupported writes stay in manual review until the upstream manager supports
the target or a narrow, reviewed exception is approved.

## Public-Safety Requirements

This is a public repository. Public docs, generated artifacts, and examples
must not include:

- private 51Code client data
- personal tokens, passwords, API keys, or bearer secrets
- browser profiles, transcripts, or runtime artifacts
- absolute user-specific filesystem paths
- machine names or account names presented as required state
- private repo URLs unless explicitly intended as public examples

Use placeholders such as `path/to/product-repo` for examples. Local diagnostic
tools must keep paths redacted by default.

## Completion Criteria For Registry Changes

A registry-contract PR is ready only when:

- source ownership remains unique for every registry-covered reusable skill
- registry and lock/version metadata are consistent
- public docs use pinned manager commands for reproducible workflows
- adapter plans cover Codex, Claude Code, and repo-local consumers without
  hand-editing consumer copies
- historical proof artifacts are not the primary onboarding path
- `scripts/skills_sync.rb` remains plan-only
- public-safety scans show no local path, secret, or private-context leaks
- repository verification commands pass

## Verification

Run these checks before opening or updating a PR:

```bash
for file in scripts/skills_drift_report.sh scripts/test_skills_doctor.sh scripts/test_skills_registry_verify.sh scripts/test_skills_sync.sh; do
  bash -n "$file"
done
ruby -c scripts/skills_doctor.rb
ruby -c scripts/skills_sync.rb
scripts/test_skills_doctor.sh
scripts/test_skills_registry_verify.sh
scripts/test_skills_sync.sh
scripts/skills_sync.rb --plan --json
scripts/skills_doctor.rb --check-upstream
scripts/skills_doctor.rb --check-manager
git diff --check
```

Use the Autopilot `skills-registry` verify profile when available.

## History

Historical proof profiles and drift reports are retained in `docs/history/` for
auditability. They are not the active workflow for installing or updating
skills.
