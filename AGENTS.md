# Agent Guide

This repo is a collection of Codex skills. Each skill lives in its own top-level directory and is defined by a `SKILL.md` file.

## Structure
- One folder per skill at repo root.
- Every skill folder must include `SKILL.md` with YAML front matter (`name`, `description`).
- Optional folders: `assets/`, `scripts/`, `references/`.
- `skills.registry.yaml` is the draft source-ownership and update-policy
  manifest for reusable skills.
- `profiles/` may contain desired machine or repo exposure profiles; these are
  read-only planning artifacts until a sync command is implemented and reviewed.
- `docs/` may contain registry reports and migration notes.
- `scripts/` may contain read-only inventory or verification helpers.

## How to work in this repo
- If a task mentions a specific skill, open that skill's `SKILL.md` and follow its workflow.
- Use the front matter in `SKILL.md` as the source of truth for name/description.
- Use `skills.registry.yaml` as the source of truth for ownership, upstream
  source, update policy, and intended consumer exposure.
- Keep edits scoped to the requested skill(s); avoid cross-skill changes unless asked.
- When adding/removing a skill, update the README skills list.
- Do not edit imported consumer copies in `~/.codex/skills`, `~/.agents/skills`,
  `~/.claude/skills`, or product repo `.agents/skills`; update the owning skill
  source or registry manifest instead.

## Conventions
- Keep docs concise and ASCII-only.
- Prefer small, focused changes and avoid reformatting unrelated files.

## Codex Cloud Environment

Recommended environment description:

```text
Lightweight Codex Cloud review environment for fiveonecode/agent-skills. Used for skill docs/review edits and SKILL.md structure checks; no secrets and agent internet off by default.
```

- Use the `universal` image with container caching on.
- No secrets are required by default.
- Keep agent-phase internet access off by default; enable it only for a task that explicitly needs external source lookup.
- Setup can stay lightweight: generate a sorted `SKILL.md` inventory or run the registry verifier once it is available in the selected branch.
- Do not add a maintenance script unless cached containers repeatedly show stale generated state.

## Review Guidelines

For Codex GitHub code review, flag only high-impact issues:

- missing `SKILL.md` entrypoints for skill directories
- invalid or missing YAML front matter `name` or `description`
- README skills list drift when skills are added, renamed, or removed
- edits to imported consumer copies instead of the owning skill source or registry
- registry ownership, upstream source, update policy, or exposure profile drift
- committed secrets, private credentials, local machine paths that should be templated, or accidental binary/editor junk
- scripts or assets that make skill usage non-reproducible
- missing required registry verification evidence for `.agents`, `skills.registry.yaml`, `profiles`, `scripts`, `AGENTS.md`, or README changes

Do not block on style nits, broad rewrites, or speculative skill packaging ideas.

## New Skills
- `apple-hig-designer`: Design iOS apps following Apple’s HIG, including native components, accessibility validation, and the clarity/deference/depth principles. Open `apple-hig-designer/SKILL.md` for the workflow.
- `ios-xcodegen`: Manage XcodeGen projects—regenerate `project.yml`, wire assets, configure tests, and resolve packaging issues without editing the generated `.xcodeproj`. Read `ios-xcodegen/SKILL.md` before touching builds.
- `swift-concurrency`: Review or build Swift 6+ concurrency code (async/await, Tasks, actors, MainActor, Sendable types) and follow the auditing/refactoring workflows in `swift-concurrency/SKILL.md`.
- `xcode-build`: Run native `xcodebuild`/`xcrun simctl` commands to build, launch, and test iOS/macOS apps; the skill enforces command-line patterns defined in `xcode-build/SKILL.md`.
- `xcode-cloud`: Configure and debug Xcode Cloud workflows, especially around XcodeGen projects and custom `ci_scripts`. Use the templates and guidance stored in `xcode-cloud/SKILL.md`.
