# Review Checklists

Use this file when you need a stricter, repeatable review pass.

## 1) Candidate-to-Finding Gate

A candidate issue becomes a finding only if all are true:

- [ ] Introduced by the proposed change.
- [ ] High confidence it is real, not speculative.
- [ ] Has meaningful impact (correctness, security, performance, reliability, maintainability).
- [ ] Actionable by the author in a bounded scope.
- [ ] Not obviously intentional based on PR context.
- [ ] Supported by concrete code evidence and location.

If any box is unchecked, do not report as a finding.

## 2) False-Positive Suppressors

Do not report these as findings:

- Pre-existing defects not touched by the change.
- Pedantic style comments that do not affect behavior.
- "Might break" claims without a concrete failing path.
- Suggestions that are only preference-based.
- Issues likely handled by standard tooling, unless they still create a real shipped risk.
- Duplicate observations of the same root cause.

## 3) Severity Calibration (P0-P3)

- P0: Critical, broadly harmful, blocks release/operation.
- P1: High impact and urgent; should be fixed in next cycle.
- P2: Real issue with moderate impact; should be scheduled.
- P3: Low impact but valid and worth fixing.

Quick test:

- If failure is universal and severe, prefer P0-P1.
- If failure depends on narrower conditions, prefer P2-P3.

## 4) Confidence Calibration (0.0-1.0)

- 0.90-1.00: Verified directly in changed code path.
- 0.80-0.89: Strong evidence with minor assumptions.
- 0.60-0.79: Plausible but missing key proof.
- <0.60: Too uncertain; ask a question instead of filing a finding.

Default reporting threshold: `>= 0.80`.

## 5) Domain Sweep Checklist

Check changed code for:

- Correctness: logic errors, off-by-one, null/optional misuse, unreachable paths.
- Security: authz/authn mistakes, secret leakage, unsafe parsing, injection vectors.
- Data integrity: broken invariants, transaction gaps, partial updates.
- Reliability: retries/timeouts, cancellation handling, cleanup on failure.
- Performance: accidental N^2 paths, redundant I/O, main-thread blocking.
- Concurrency: race conditions, shared mutable state, lock misuse.
- Compatibility: API contract breaks, migration assumptions, backward incompatibilities.
- Test coverage: changed behavior without meaningful verification.
- Observability: no logs/metrics on critical new failure paths.

## 6) Finding Quality Checklist

Before finalizing each finding:

- [ ] One issue per finding.
- [ ] One short paragraph for explanation.
- [ ] Clear "why this is a bug" statement.
- [ ] Conditions under which it fails.
- [ ] Minimal file/line location needed to act.
- [ ] Tone is neutral and factual.
