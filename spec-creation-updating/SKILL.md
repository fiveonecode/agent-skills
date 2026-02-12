---
name: spec-creation-updating
description: Create, update, review, and improve technical specification documents so they are complete, testable, and implementation-ready. Use when defining new features/systems/APIs, updating existing specs, restructuring documents, auditing missing requirements, or converting vague plans into concrete, verifiable requirements and acceptance criteria.
---

# Spec Creation Updating

## Overview

Produce specs that reduce ambiguity and can be implemented with minimal back-and-forth.
Apply this workflow to any project domain (product, backend, API, data, UI, infrastructure, ops).

## Workflow

### 1. Set boundaries

- Capture the objective and user/business value.
- Define in-scope and out-of-scope behavior.
- Record assumptions, dependencies, and constraints.
- Ask clarifying questions when decisions affect architecture, cost, security, or user-visible behavior.

### 2. Choose depth

- Write a lightweight spec for isolated, low-risk changes.
- Write a full system spec for cross-team, risky, or high-impact work.
- Keep the same quality gates regardless of depth.

### 3. Build structure

- Start from [`references/spec-template.md`](references/spec-template.md).
- Preserve repository naming, section ordering, and style if they already exist.
- Add domain-specific sections as needed, but do not remove mandatory content.

### 4. Fill concrete requirements

- Write requirements as testable statements, not intentions.
- Define success paths, edge cases, and failure behavior.
- Specify interfaces, data contracts, and state transitions when relevant.
- Specify non-functional requirements: performance, reliability, scalability, observability.

### 5. Define verification and completion

- Map each requirement to a verification method.
- Include reproducible commands, tests, and manual checks when automation is unavailable.
- Define completion criteria with pass/fail outcomes.

### 6. Close traceability

- Link related specs, ADRs, designs, and operational docs.
- Update version, last-updated date, and status.
- Record unresolved questions and decision owners.

### 7. Run quality gate

- Validate against [`references/spec-must-have-checklist.md`](references/spec-must-have-checklist.md).
- Use [`references/spec-review-scorecard.md`](references/spec-review-scorecard.md) when auditing an existing spec.
- Treat any missing MUST item as blocking.

## Writing rules

- Prefer precise language over broad terms like "optimize", "support", or "handle".
- Use explicit units, limits, and conditions.
- Mark implemented vs planned behavior with explicit status labels.
- Keep requirements and facts in the spec; keep narrative concise.
- Avoid embedding secrets or private credentials in reusable specs.

## Output expectations

- When creating a spec, deliver:
  - A complete spec document.
  - A list of unresolved questions.
  - A verification plan mapped to requirements.
- When reviewing a spec, deliver:
  - Prioritized gaps and risks.
  - Concrete rewrite suggestions.
  - A readiness verdict based on MUST items.
