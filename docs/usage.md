# Usage

Status: active
Last updated: 2026-07-02

Related: [README](../README.md), [Registry Contract](registry-contract.md),
[Contributing](contributing.md), [Manager Boundary](manager-boundary.md)

## Prerequisites

- Node.js `>=18`
- Git
- `npx` available on `PATH`
- A clone of this repo for doctor/sync validation:

```bash
git clone https://github.com/fiveonecode/agent-skills.git
cd agent-skills
```

## Public Install Commands

Install one skill globally for Codex:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --global \
  --yes
```

Install one skill into the current repo for Codex:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --yes
```

Install one skill into the current repo for Claude Code:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent claude-code \
  --yes
```

List available skills from this repository without installing:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills --list
```

List installed global skills:

```bash
npx --yes skills@1.5.14 ls --global --json
```

List installed project skills:

```bash
npx --yes skills@1.5.14 ls --json
```

## 51Code Operator Workflow

Start from a clean clone:

```bash
cd path/to/agent-skills
git switch main
git pull --ff-only
git status --short --branch
```

Run source and policy checks:

```bash
scripts/skills_doctor.rb
scripts/skills_doctor.rb --check-upstream
scripts/skills_doctor.rb --check-manager
```

Generate a reviewable adapter plan:

```bash
scripts/skills_sync.rb --plan
scripts/skills_sync.rb --plan --json
```

Read `management.owner` before doing anything:

- `upstream-manager`: run the emitted pinned command when the PR/task has
  reviewed that exact write.
- `manual-review`: do not write; document the missing manager support or profile
  gap.
- `none`: no manager write is needed.

After any reviewed upstream-manager write, rerun:

```bash
npx --yes skills@1.5.14 ls --global --json
scripts/skills_doctor.rb --check-manager
scripts/skills_sync.rb --plan --json
```

Expected outcome: the changed adapter reports `keep | ok` or equivalent JSON
state, and doctor reports the manager-owned copy or symlink as matching the
registry source/lock policy.

## Updating Installed Skills

Use manager updates only for skills already installed by the upstream manager
and only after reviewing registry/lock state.

Update one global skill:

```bash
npx --yes skills@1.5.14 update --global --yes code-review
```

Update one project skill from inside the project repo:

```bash
npx --yes skills@1.5.14 update --project --yes code-review
```

Update all global skills only when that is the reviewed task:

```bash
npx --yes skills@1.5.14 update --global --yes
```

Do not use `update` as a discovery command. Use the top-level help command when
checking CLI syntax:

```bash
npx --yes skills@1.5.14 --help
```

## Editing A 51Code-Owned Skill

```bash
cd path/to/agent-skills
git switch -c codex/edit-skill-name
# Edit skill-name/SKILL.md and any references/scripts/assets.
scripts/skills_doctor.rb
scripts/skills_sync.rb --plan --json
git diff --check
```

Update the README skills table or future generated catalog if the public name,
description, folder, supported clients, or source metadata changed.

## Importing A Third-Party Update

1. Update `skills.registry.yaml` with the new upstream tag or commit.
2. Regenerate `skills.lock.yaml`:

   ```bash
   tmp_lock="$(mktemp "${TMPDIR:-/tmp}/skills.lock.yaml.XXXXXX")"
   scripts/skills_doctor.rb --check-upstream --print-lock >"$tmp_lock"
   mv "$tmp_lock" skills.lock.yaml
   ```

3. Review the upstream diff, license, skill instructions, and generated adapter
   impact.
4. Run doctor and sync-plan checks.
5. Open a PR that includes registry diff, lock diff, and validation output.

If the third-party skill is modified locally, classify it as
`forked-from-external` or create a separate registry-owned wrapper skill.

## Troubleshooting

If a skill does not appear in an agent:

1. Confirm the upstream manager sees it:

   ```bash
   npx --yes skills@1.5.14 ls --global --json
   ```

2. Confirm the registry policy sees it:

   ```bash
   scripts/skills_doctor.rb --check-manager
   scripts/skills_sync.rb --plan --json
   ```

3. Restart the agent app or CLI if the adapter exists but the current session
   has not loaded the new skill.

If sync-plan says `manual-review`, do not hand-edit consumer folders. The
action needs either upstream manager support, profile changes, or a documented
exception.
