# Skill Registry Drift Report - 2026-06-26

Related: [README](../README.md), [registry manifest](../skills.registry.yaml),
[example local profile](../profiles/machine/example-local-skills.yaml)

## Purpose

This report records a public, sanitized first read-only inventory slice for
turning scattered skill folders into a versioned skill registry. It does not
move, copy, delete, or relink any consumer skills.

## Current Snapshot

- Registry candidate: this repository
- Registry skill folders found here during the maintainer scan: `58`
- User-level consumer skill entrypoints observed across common Codex and Claude
  user skill roots, following symlink adapters: `64`
- Repo-local `.agents/skills/*/SKILL.md` entrypoints found under the
  maintainer's local projects directory: about `221`
- Most repeated repo-local skill names in the sanitized initial scan:
  - `spec-creation-updating`: `11`
  - `harness-engineering`: `6`
  - `apple-hig-designer`: `6`
  - `apple-doc-research`: `6`
  - `swiftui-pro`: `4`

## Concrete Drift

`swiftui-pro` is already stale locally:

- Four repo-local copies were found in maintainer workspaces; all report
  `metadata.version: "1.0"`.
- Upstream `twostraws/SwiftUI-Agent-Skill` has tag `1.1.0` at
  `be297ff80dddec529af1f9b1f1f114aab6c9d11c`.
- Upstream `swiftui-pro/SKILL.md` reports `metadata.version: "1.1"`.
- Because local copies do not record their upstream URL, tag, commit, or lock
  digest, this mismatch was silent until manually checked.

## Good Existing Pattern

One maintainer environment already exposes `code-review` as a symlink from a
Codex user skill root to this registry:

```text
~/.codex/skills/code-review -> <registry-root>/code-review
```

Codex exposed that skill successfully in a live session, so symlinked Codex
consumer folders are a proven local pattern.

## Current Risks

- Consumer skill folders are mixed: some are copies, one known Codex skill is a
  symlink, and repo-local skills are mostly copied folders.
- Repeated repo-local skill names may be legitimate repo-owned forks, stale
  imports, or identical copies; there is no manifest to distinguish them.
- Claude Code skill symlink support still needs a live compatibility check
  before converting `~/.claude/skills` or `.claude/skills` broadly.
- `screenshot-analyze-verification/SKILL.md` in this repo had pre-existing
  uncommitted local changes during this report and was intentionally left
  untouched.

## Recommended Next Slice

Build a report-only `skills doctor` command that:

- reads `skills.registry.yaml` and the machine profile
- enumerates configured consumer roots only
- reports copied imports where symlinks or generated adapters are expected
- reports repo-local skills whose names match registry-owned skills
- verifies the known external `swiftui-pro` pin against upstream when network
  checks are explicitly enabled
- exits non-zero only for malformed registry files at first; drift findings
  should stay warning-only until the operator accepts the policy

Only after this report is reviewed should any sync command rewrite consumer
directories.
