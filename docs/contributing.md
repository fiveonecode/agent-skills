# Contributing

Status: active
Last updated: 2026-07-02

Related: [README](../README.md), [Registry Contract](registry-contract.md),
[Usage](usage.md), [Manager Boundary](manager-boundary.md)

## Contribution Rules

- Keep the repository public-safe.
- Edit the owning source, not imported consumer copies.
- Keep one source owner per reusable skill.
- Keep lock/version metadata current when source identity or resolved content
  changes.
- Keep adapter views generated from registry, lock, and profile data.
- Keep `scripts/skills_sync.rb` plan-only; do not add local write fallbacks.
- Keep changes small enough for focused review.

## Add A New 51Code-Owned Skill

1. Create one top-level directory:

   ```bash
   mkdir new-skill-id
   ```

2. Add `new-skill-id/SKILL.md` with YAML front matter:

   ```md
   ---
   name: new-skill-id
   description: One sentence describing when to use this skill.
   ---

   # New Skill
   ```

3. Add optional `references/`, `scripts/`, `assets/`, `templates/`, or
   `examples/` only when the skill needs them.
4. Add the skill to `skills.registry.yaml` as `registry-local`.
5. Regenerate or update `skills.lock.yaml` when the source set changes.
6. Update the README skills table or future generated catalog.
7. Run validation.

## Edit A 51Code-Owned Skill

1. Open the skill's `SKILL.md` and any referenced files.
2. Keep edits inside the owning skill folder unless registry metadata also
   changes.
3. Update `skills.registry.yaml` if exported names, supported clients, scopes,
   source type, or update policy changed.
4. Regenerate `skills.lock.yaml` if source digest or external pin state changed.
5. Run validation and include the commands in the PR body.

## Import A Third-Party Skill Update

Use this when the upstream author remains authoritative.

1. Confirm the upstream tag or commit and license.
2. Update `skills.registry.yaml` with the pinned upstream metadata.
3. Regenerate `skills.lock.yaml` with upstream checking:

   ```bash
   tmp_lock="$(mktemp "${TMPDIR:-/tmp}/skills.lock.yaml.XXXXXX")"
   scripts/skills_doctor.rb --check-upstream --print-lock >"$tmp_lock"
   mv "$tmp_lock" skills.lock.yaml
   ```

4. Review the upstream diff for instruction changes, unexpected scripts, binary
   assets, secret-like strings, and private data.
5. Run doctor and sync-plan checks.
6. Open a PR that states the old pin, new pin, upstream diff source, license
   status, and validation results.

Do not silently auto-update third-party skills on `main`.

## Fork Or Customize A Third-Party Skill

If we modify a third-party skill's content, it is no longer a pure
`external-git` source.

Choose one path:

- Reclassify the maintained copy as `registry-local` in
  `skills.registry.yaml` and record the upstream provenance and fork reason in
  `notes` or the PR body.
- Keep the external skill pinned and create a separate registry-local wrapper
  skill for 51Code-specific behavior.

The PR must record upstream origin, license/history, fork reason, exported
names, supported clients, scopes, and lock metadata.

## Adapter/Profile Changes

Adapter changes must be generated from registry, lock, and profile data.

Allowed in normal PRs:

- profile metadata changes
- new selected skills in a profile
- reviewed `consumer_overrides` for one proven target
- sync-plan output showing exact intended actions

Not allowed without a separate reviewed exception:

- hand-edited consumer copies
- broad stale adapter deletion
- local install/update/remove code in `scripts/skills_sync.rb`
- unpinned `npx skills` commands in managed workflows
- profile changes that expose private 51Code state in this public repo

## Public-Safety Checklist

Before opening a PR, confirm the diff does not include:

- tokens, API keys, passwords, or bearer secrets
- private customer/client details
- browser profiles, transcripts, runtime folders, caches, or editor junk
- absolute user-specific paths
- private repository URLs unless intentionally documented as private examples
- machine account names used as required state

Use generic examples such as `path/to/product-repo`.

## Required Validation

Run the checks that match the change:

```bash
bash -n scripts/skills_drift_report.sh scripts/test_skills_doctor.sh scripts/test_skills_sync.sh
ruby -c scripts/skills_doctor.rb
ruby -c scripts/skills_sync.rb
scripts/test_skills_doctor.sh
scripts/test_skills_sync.sh
scripts/skills_sync.rb --plan --json
scripts/skills_doctor.rb --check-upstream
scripts/skills_doctor.rb --check-manager
git diff --check
```

For docs-only changes, the full suite is still preferred when registry,
profile, manager-boundary, or public workflow behavior is described.

## PR Body

Include:

- what changed
- why it changed
- source ownership impact
- lock/version metadata impact
- Codex, Claude Code, and repo-local adapter impact
- public-safety review result
- validation commands and outcomes
