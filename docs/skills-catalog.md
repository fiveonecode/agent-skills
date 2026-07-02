# Skills Catalog

This file is generated. Edit `skills.registry.yaml`, `skills.lock.yaml`,
or registered `SKILL.md` front matter, then run
`scripts/skills_catalog.rb --write`.

- Registry: Agent Skills (`agent-skills`)
- Status: `active-partial`
- Manager source: `fiveonecode/agent-skills`
- Covered skills: 4

## Registry-Covered Skills

| Skill | Status | Source | Exports | Clients | Scopes | Update Policy | Description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `code-review` | `active` | `registry-local:code-review` | `code-review` | claude=planned, codex=supported | `machine`, `repo` | `internal-reviewed` | Review pull requests, commits, or diffs for high-signal engineering issues and merge risk. Use when asked to review code, audit a patch, find bugs, or provide merge readiness feedback. Focus on defects introduced by the proposed changes (correctness, security, performance, reliability, and maintainability) and report actionable findings with severity, confidence, and precise code locations. |
| `harness-engineering` | `active` | `registry-local:harness-engineering` | `harness-engineering` | claude=planned, codex=supported | `machine`, `repo` | `internal-reviewed` | Build and improve agent-first engineering harnesses where AI agents perform most implementation work and humans steer architecture, constraints, and review. Use when defining or upgrading AGENTS.md rules, repository conventions, task decomposition, CI guardrails, merge strategy, quality gates, or cleanup loops to increase autonomous coding throughput and reliability. |
| `spec-creation-updating` | `active` | `registry-local:spec-creation-updating` | `spec-creation-updating` | claude=planned, codex=supported | `machine`, `repo` | `internal-reviewed` | Create, update, review, and improve technical specification documents so they are complete, testable, and implementation-ready. Use when defining new features/systems/APIs, updating existing specs, restructuring documents, auditing missing requirements, or converting vague plans into concrete, verifiable requirements and acceptance criteria. |
| `swiftui-pro` | `needs-import-review` | `external-git:swiftui-pro@1.1.0` | `swiftui-pro` | claude=planned, codex=planned | `machine`, `repo` | `external-reviewed` | SwiftUI Agent Skill workflows for SwiftUI app development, pinned to a reviewed upstream tag before import or adapter rollout. |

## Installable Active Skills

The commands below use the pinned upstream skills manager package.

```bash
npx --yes skills@1.5.14 add fiveonecode/agent-skills --skill code-review --agent codex --global --yes
npx --yes skills@1.5.14 add fiveonecode/agent-skills --skill harness-engineering --agent codex --global --yes
npx --yes skills@1.5.14 add fiveonecode/agent-skills --skill spec-creation-updating --agent codex --global --yes
```
