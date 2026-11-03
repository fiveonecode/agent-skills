# Review Checklists

Use this file when you need a stricter, repeatable review pass.

## 1) Candidate-to-Finding Gate

A candidate issue becomes a finding only if all are true:

- [ ] Introduced by the proposed change.
- [ ] Confidence is at least 0.80, or the both-quotes evidence rule keeps it.
- [ ] Has meaningful impact (correctness, security, performance, reliability, maintainability).
- [ ] Actionable by the author in a bounded scope.
- [ ] Not obviously intentional based on PR context.
- [ ] Supported by a quote of the changed line or the pull-request sentence, plus a location.

If any box is unchecked, do not report as a finding.

## 2) False-Positive Suppressors

Do not report these as findings:

- Pre-existing defects not touched by the change.
- Pedantic style comments that do not affect behavior.
- "Might break" claims without a concrete failing path.
- Suggestions that are only preference-based.
- Issues likely handled by standard tooling, unless they still create a real shipped risk.
- Duplicate observations of the same root cause.
- A missing test by itself.
- A missing simulator run.
- A TODO with no defect impact.
- A compiler or linter finding with no correctness impact.
- A comment on an unchanged line.
- A spec invented for the review, or a build or simulator result that was not actually run.

## 3) Severity Calibration (P0-P3)

- P0: Critical, broadly harmful, blocks release/operation.
- P1: High impact and urgent; should be fixed in next cycle.
- P2: Real issue with moderate impact; should be scheduled.
- P3: Low impact but valid and worth fixing.

Quick test:

- If failure is universal and severe, prefer P0-P1.
- If failure depends on narrower conditions, prefer P2-P3.
- An immediate crash, security, data-loss, HealthKit, entitlement, persistence, or deep-link defect outranks a spec or event-name mismatch.

## 4) Confidence Calibration (0.0-1.0)

- 0.90-1.00: Verified directly in changed code path.
- 0.80-0.89: Strong evidence with minor assumptions.
- 0.60-0.79: Plausible but missing key proof.
- <0.60: Too uncertain; ask a question instead of filing a finding, unless the both-quotes evidence rule keeps it.

Default reporting threshold: `>= 0.80`. The both-quotes evidence rule is the exception.

## 5) Both-quotes evidence rule

Evidence means quoting the changed line or the pull-request sentence. For a candidate in the extra classes, also quote the contradicted spec sentence or its section id.

- When both quotes are present, keep the finding at P2 or higher even when confidence is under 0.80.
- When either quote is missing, drop it.
- Do not invent a spec. Do not invent a build or simulator result.

## 6) Evidence reading rule

Open a file beyond the diff only when a live candidate depends on it. If the diff names an event and treats omission as zero, or as proof the event did not happen, open the spec that defines that event. Name every path a candidate needed and that was not read under residual risks.

## 7) Extra candidate classes

Return a candidate when the diff or the pull-request body shows one of these:

- Contract drift against a cited spec section.
- An analytics claim that treats independent uniques, an event the spec says is not emitted, or an immature cohort as a funnel.
- A missing verification only when the pull request claims a crash, security, data-loss, HealthKit, entitlement, persistence, or deep-link property, and the diff plus any attached session log do not implement it.
- A missing spec-required artifact or verification row, including a UI-session artifact or a catalog verification row, when the pull request's own verification list or a cited spec says that artifact or row is required.

## 8) Swift/SwiftUI defect sweep

Apply this sweep only when Swift or SwiftUI is in the diff:

- Force unwraps and silent optional failure.
- Retain cycles and lifecycle leaks.
- Swallowed errors.
- Actor isolation and Sendable crossings.
- SwiftUI state and lifecycle races.
- Persistence integrity.
- HealthKit or privacy leaks.
- Purchase and entitlement mistakes.
- Combine and networking defects.
- Unvalidated deep links or JS bridges.
- Unsafe interop.

## 9) Domain Sweep Checklist

Check changed code for:

- Correctness: logic errors, off-by-one, null/optional misuse, unreachable paths.
- Security: authz/authn mistakes, secret leakage, unsafe parsing, injection vectors.
- Data integrity: broken invariants, transaction gaps, partial updates.
- Reliability: retries/timeouts, cancellation handling, cleanup on failure.
- Performance: accidental N^2 paths, redundant I/O, main-thread blocking.
- Concurrency: race conditions, shared mutable state, lock misuse.
- Compatibility: API contract breaks, migration assumptions, backward incompatibilities.
- Tests: a broken test is in scope. A missing test by itself is not a finding.
- Observability: no logs/metrics on critical new failure paths.

## 10) Finding Quality Checklist

Before finalizing each finding:

- [ ] One issue per finding.
- [ ] One short paragraph for explanation.
- [ ] Clear "why this is a bug" statement.
- [ ] Conditions under which it fails.
- [ ] Minimal file/line location needed to act.
- [ ] Tone is neutral and factual.
