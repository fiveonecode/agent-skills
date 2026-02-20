---
name: code-review
description: Review pull requests, commits, or diffs for high-signal engineering issues and merge risk. Use when asked to review code, audit a patch, find bugs, or provide merge readiness feedback. Focus on defects introduced by the proposed changes (correctness, security, performance, reliability, and maintainability) and report actionable findings with severity, confidence, and precise code locations.
---

# Code Review

## Overview

Run a high-signal review with a low false-positive rate.
Prioritize issues the author would likely fix immediately if they knew.

## Required Inputs

- Changed code scope (PR, commit range, patch, or diff).
- Author intent (PR title/description, ticket, or summary).
- Project-specific rules if provided. Treat explicit local rules as higher priority than generic guidance.

If intent or scope is missing, infer conservatively and state assumptions.

## Workflow

### 1. Triage Scope

- Confirm what changed and where.
- Focus on changed code first; use nearby context only when needed to validate impact.
- Ignore mechanical noise unless it introduces risk.

### 2. Run Multi-Pass Analysis

- Pass A: Compile/runtime correctness (syntax, type use, imports, control flow).
- Pass B: Security and data integrity (auth, validation, secret handling, unsafe defaults).
- Pass C: Reliability and performance (resource leaks, blocking calls, hot-path regressions).
- Pass D: API and compatibility impact (breaking behavior, migrations, version assumptions).
- Pass E: Test and observability coverage for changed behavior.

Use independent perspectives when possible, then merge only validated findings.

### 3. Qualify Each Candidate Issue

Keep a finding only if all checks pass:

- Introduced by this change (not pre-existing debt).
- Evidence-backed and reproducible from available context.
- Meaningful impact on correctness, security, performance, reliability, or maintainability.
- Discrete and actionable with a clear fix direction.
- Not an intentional behavior change by the author.
- Likely something the author would want to fix now.

If confidence is low, drop the finding or convert it into an explicit question.

### 4. Assign Severity and Confidence

Use priority tags:

- P0: Release-blocking or universally critical failure.
- P1: Urgent and should be fixed in the next cycle.
- P2: Important but not immediately blocking.
- P3: Low urgency but valid and actionable.

Add a confidence score from `0.0` to `1.0`.
Default to reporting only high-confidence findings (for example, `>= 0.80`) unless the user asks for exhaustive mode.

### 5. Write Findings

Write one finding per distinct issue:

- Title: `[Px]` plus a short imperative summary (`<= 80` chars).
- Body: one paragraph explaining why this is a problem and when it occurs.
- Evidence: exact file path with a minimal line range.
- Fix direction: concise, concrete guidance (avoid large rewrites unless requested).
- Confidence: numeric score.

Keep tone factual and neutral. Avoid praise, blame, and style-only commentary.

### 6. Provide Overall Verdict

Always include:

- `overall_correctness`: `patch is correct` or `patch is incorrect`.
- `overall_explanation`: 1-3 sentences.
- Residual risks or unreviewed areas, if any.

If no qualified findings remain, explicitly state that no issues were found after high-signal filtering.

## High-Signal Filter (Do Not Report)

- Style-only nits or formatting-only concerns.
- Speculative risks without clear evidence.
- Issues outside changed scope unless the change clearly triggers them.
- Broad "could be better" suggestions without defect impact.
- Duplicate findings for the same root cause.
- Company-specific process/policy violations unless those policies were explicitly provided for this review.

## Output Template (Markdown)

```markdown
## Findings

1. [P1] <title>
<one-paragraph explanation>

File: `path/to/file.ext:line`
Confidence: 0.92
Fix direction: <one short actionable suggestion>

## Overall correctness
patch is incorrect

<1-3 sentence explanation>

## Residual risks
- <optional>
```

For detailed checklists and calibration rules, use:

- `references/review-checklists.md`
