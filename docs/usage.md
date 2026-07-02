# Usage

Status: active-partial
Last updated: 2026-07-02

Related: [README](../README.md), [Registry Contract](registry-contract.md),
[Contributing](contributing.md), [Manager Boundary](manager-boundary.md)

## Prerequisites

- Node.js `>=18`
- Ruby with the standard `yaml` library available via `ruby -ryaml`
- Git
- `npx` available on `PATH`
- A clone of this repo for doctor/sync validation:

```bash
git clone https://github.com/fiveonecode/agent-skills.git
cd agent-skills
```

## Public Install Commands

Registry coverage is currently active-partial. Only skills listed in
`skills.registry.yaml` are registry-covered; other top-level skill folders stay
in backlog until a follow-up coverage PR registers them.

Install one skill globally for Codex:

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --global \
  --yes
```

Install one skill into a consumer repo for Codex. Run this from the product
repo, not from the `agent-skills` clone:

```bash
cd path/to/product-repo
npx --yes skills@1.5.14 add fiveonecode/agent-skills \
  --skill code-review \
  --agent codex \
  --yes
```

Claude Code remains manual-review for this registry until the relevant skills
move from `clients.claude: planned` to reviewed support in the registry and
profile examples.

List installable registry-covered Codex skill ids from this clone:

```bash
ruby -ryaml -e '
  registry = YAML.safe_load(File.read("skills.registry.yaml"), aliases: false)
  registry.fetch("skills")
    .select { |skill| skill["status"] == "active" }
    .select { |skill| skill.dig("clients", "codex") == "supported" }
    .select do |skill|
      path = skill.dig("source", "path")
      path.is_a?(String) && File.file?(File.join(path, "SKILL.md"))
    end
    .sort_by { |skill| skill.fetch("id") }
    .each { |skill| puts skill.fetch("id") }
'
```

This filtered list matches the documented `--agent codex` install flow.
Registry-covered entries that are still planned or do not have a checked-in
top-level skill folder stay out of this list until a follow-up coverage/import
PR makes them installable.

Do not use `npx --yes skills@1.5.14 add fiveonecode/agent-skills --list` as a
registry coverage list. It enumerates every top-level skill folder in the
repository, including backlog entries outside the active-partial contract.

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

Project-installed skills stay manual-review for this registry while upstream
issues #1519 and #1530 remain open for update failure signaling and project
source handling. Inspect current project state first instead of treating
`update --project` as a default workflow:

```bash
npx --yes skills@1.5.14 ls --json
scripts/skills_doctor.rb --check-manager
scripts/skills_sync.rb --plan --json
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

1. Update `skills.registry.yaml` with the new upstream tag,
   `source.observed_commit`, and `source.observed_at`.
2. Regenerate `skills.lock.yaml`:

   ```bash
   tmp_lock="$(mktemp "${TMPDIR:-/tmp}/skills.lock.yaml.XXXXXX")"
   scripts/skills_doctor.rb --check-upstream --print-lock >"$tmp_lock" &&
     mv "$tmp_lock" skills.lock.yaml
   ```

3. Review the upstream diff, license, skill instructions, and generated adapter
   impact.
4. Run doctor and sync-plan checks.
5. Open a PR that includes registry diff, lock diff, observed commit/date,
   license review result, and validation output.

If the third-party skill is modified locally, convert the maintained copy to
`registry-local` and keep the upstream provenance in `notes` or the PR
description, or create a separate registry-owned wrapper skill.

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
