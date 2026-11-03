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

Four roles run in order. The parent, bug hunter, and structured reviewer return notes only. The judge is the only publisher.

### 1. Parent inventory

- List changed files, author intent, and any repo-local review rules.
- Follow the evidence reading rule in `references/review-checklists.md`.
- Ignore mechanical noise unless it creates a defect.
- Do not publish findings in this step.

### 2. Bug hunter

Run this as a separate pass. Do not publish.

Return only defects the author would fix immediately if they knew: crashes, security issues, data corruption, broken tests, and regressions. Also return a candidate for each extra class in `references/review-checklists.md`. Return an empty list when none apply.

### 3. Structured reviewer

Run this as a separate pass. Do not publish.

- Pass A: Compile/runtime correctness (syntax, type use, imports, control flow).
- Pass B: Security and data integrity (auth, validation, secret handling, unsafe defaults).
- Pass C: Reliability and performance (resource leaks, blocking calls, hot-path regressions).
- Pass D: API and compatibility impact (breaking behavior, migrations, version assumptions).
- Pass E: Tests and observability for changed behavior.

Also return candidates for each extra class in `references/review-checklists.md`.

When Swift or SwiftUI is in the diff, apply the Swift/SwiftUI defect sweep in `references/review-checklists.md`. Verify a non-local claim by reading the caller, the cited spec section, and the lifecycle.

### 4. Judge

Start the judge only after the bug hunter and the structured reviewer have returned their lists. The judge qualifies every candidate from those lists. Publish only candidates that pass the candidate-to-finding gate in `references/review-checklists.md`, including its both-quotes evidence rule.

### 5. Failed role

If the bug hunter, the structured reviewer, or the judge fails, retry that role once. If it still fails, the parent performs that role. A judge qualification still runs on every candidate before anything is published. When the failed role is the judge, the parent's performance of that role is the qualification.

### 6. Assign Severity and Confidence

Use priority tags:

- P0: Release-blocking or universally critical failure.
- P1: Urgent and should be fixed in the next cycle.
- P2: Important but not immediately blocking.
- P3: Low urgency but valid and actionable.

Add a confidence score from `0.0` to `1.0` on every kept finding.
Report every kept finding, including P0, P1, P2, and P3.
The checklist gate is the only keep rule: confidence at least `0.80`, or the both-quotes evidence rule.
Otherwise drop the candidate or convert it into an explicit question.

### 7. Write Findings

Write one finding per distinct kept issue:

- Title: `[Px]` plus a short imperative summary (`<= 80` chars).
- Body: one paragraph explaining why this is a problem and when it occurs.
- Evidence: exact file path with a minimal line range.
- Fix direction: concise, concrete guidance (avoid large rewrites unless requested).
- Confidence: numeric score.

Keep tone factual and neutral. Avoid praise, blame, and style-only commentary.

### 8. Provide Overall Verdict

Always include:

- `overall_correctness`: `patch is incorrect` when any kept finding remains, otherwise `patch is correct`.
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
