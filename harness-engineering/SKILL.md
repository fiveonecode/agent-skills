---
name: harness-engineering
description: Build and improve agent-first engineering harnesses where AI agents perform most implementation work and humans steer architecture, constraints, and review. Use when defining or upgrading AGENTS.md rules, repository conventions, task decomposition, CI guardrails, merge strategy, quality gates, or cleanup loops to increase autonomous coding throughput and reliability.
---

# Harness Engineering

## Overview

Use this skill to translate harness engineering principles into concrete repository changes that improve agent speed, correctness, and maintainability.

## Workflow

### 1) Assess the current harness

- Inspect `AGENTS.md`, contributor docs, CI workflows, and repo scripts.
- Map the actual path from prompt to merged change.
- List concrete failure modes: ambiguous instructions, repeated mistakes, slow reviews, merge conflicts, stale docs, or noisy CI.

### 2) Define operating boundaries

- Separate decisions by layer:
  - Human layer: architecture, taste, policy, and final risk acceptance.
  - Agent layer: implementation, refactors, test updates, and routine maintenance.
- Define non-negotiable constraints before coding starts:
  - Required tests and linters.
  - Directory ownership and file-scoping rules.
  - Branch, PR, and commit conventions.

### 3) Make the repository the system of record

- Encode process in files, not tribal knowledge.
- Prefer deterministic entry points:
  - Single source for setup.
  - Canonical command wrappers (`make`, `just`, or scripts).
  - Stable templates for PRs, issues, and specs.
- Remove conflicting guidance and duplicate docs.

### 4) Increase agent legibility

- Prefer one clear pattern over many equivalent ones.
- Standardize naming, folder layouts, and module boundaries.
- Add concise examples for fragile tasks.
- Eliminate hidden behavior and implicit coupling.

### 5) Add mechanical guardrails

- Enforce checks automatically:
  - Fast local checks for iteration.
  - CI gates for merge readiness.
  - Static analysis for known failure classes.
- Fail with actionable messages that point to exact fixes.
- Keep checks strict enough to prevent regressions, but fast enough for daily use.

### 6) Optimize merge throughput

- Encourage smaller, composable changes instead of large batches.
- Isolate independent work streams to reduce collisions.
- Define explicit integration rules for overlapping files.
- Prefer rapid merge and follow-up fixes over long-lived divergence.

### 7) Build entropy-control loops

- Schedule regular cleanup work: dead code removal, doc pruning, flaky test fixes.
- Track recurring failure patterns and encode permanent safeguards.
- Retire obsolete scripts, prompts, and templates quickly.

## Deliverable format

- `Harness snapshot`: current bottlenecks with evidence.
- `Proposed harness changes`: files to add or edit and why.
- `Guardrail plan`: checks to enforce and where they run.
- `Rollout plan`: phased adoption with fallback strategy.
- `Entropy plan`: recurring cleanup cadence and ownership.

## References

- For detailed principles, anti-patterns, and direct implementation checklists, read [references/harness-engineering-principles.md](references/harness-engineering-principles.md).
