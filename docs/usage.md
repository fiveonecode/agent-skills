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

List the current reviewed global Codex install ids from this clone:

```bash
ruby -ryaml -e '
  registry = YAML.safe_load(File.read("skills.registry.yaml"), aliases: false)
  profile = YAML.safe_load(File.read("profiles/machine/example-local-skills.yaml"), aliases: false)
  selected = profile.fetch("selected_skills").each_with_object({}) do |entry, memo|
    memo[entry.fetch("skill_id")] = entry
  end
  registry.fetch("skills")
    .select { |skill| skill["status"] == "active" }
    .select { |skill| skill.dig("clients", "codex") == "supported" }
    .select do |skill|
      path = skill.dig("source", "path")
      path.is_a?(String) && File.file?(File.join(path, "SKILL.md"))
    end
    .select do |skill|
      override = selected[skill.fetch("id")]&.dig("consumer_overrides", "agents_user")
      override.is_a?(Hash) &&
        override["adapter"] == "manager-copy" &&
        override["status"] == "proven-manager-copy"
    end
    .sort_by { |skill| skill.fetch("id") }
    .each { |skill| puts skill.fetch("id") }
'
```

This filtered list matches the documented `--agent codex --global` install
flow for the current reviewed `agents_user` baseline. Registry-covered entries
that still rely on planned/manual-review profile state or do not have a
checked-in top-level skill folder stay out of this list until a follow-up
coverage/profile PR promotes them.

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

Do not run an unscoped global update command from this workflow. If a reviewed
task needs a full global sweep, first confirm the installed global set:

```bash
npx --yes skills@1.5.14 ls --global --json
```

Then update only the reviewed `fiveonecode/agent-skills` skill ids one at a
time with the scoped command above.

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

1. Update `skills.registry.yaml` with the new upstream tag and
   `source.observed_commit`. Record the reviewed date in `source.observed_at`
   or in the PR body until doctor/sync/lock enforcement supports it
   end-to-end.
2. Regenerate `skills.lock.yaml`:

   ```bash
   tmp_lock="$(mktemp "${TMPDIR:-/tmp}/skills.lock.yaml.XXXXXX")"
   scripts/skills_doctor.rb --check-upstream --print-lock >"$tmp_lock" &&
     mv "$tmp_lock" skills.lock.yaml
   ```

3. Review the upstream diff, license, skill instructions, and generated adapter
   impact.
4. Run doctor and sync-plan checks.
5. Open a PR that includes registry diff, lock diff, observed commit, reviewed
   date evidence, license review result, and validation output.

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
