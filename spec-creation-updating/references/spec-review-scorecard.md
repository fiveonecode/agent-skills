# Spec review scorecard

Use this scorecard when auditing an existing spec.

## Scoring rubric

- `0` = Missing or unusable.
- `1` = Present but ambiguous/incomplete.
- `2` = Clear, actionable, and verifiable.

## Score table

| Category | Score (0-2) | Notes |
|---|---:|---|
| Document metadata and status |  |  |
| Objective and scope clarity |  |  |
| Functional requirements quality |  |  |
| Edge cases and failure behavior |  |  |
| Interface/contract completeness |  |  |
| Data model and state definitions |  |  |
| Non-functional requirements |  |  |
| Security/privacy/compliance coverage |  |  |
| Dependencies/assumptions/constraints |  |  |
| Verification mapping to requirements |  |  |
| Completion criteria clarity |  |  |
| Traceability and related-doc links |  |  |
| Document history hygiene |  |  |

## Verdict rules

- `Ready`: no category scored `0`, total score >= 22.
- `Needs revision`: no category scored `0`, total score 16-21.
- `Not ready`: any category scored `0` or total score < 16.

## Required findings format

Report findings in this order:

1. Blocking issues (missing MUST-level content).
2. High-risk ambiguities (could cause rework/outage/security risk).
3. Quality improvements (readability, structure, maintainability).
