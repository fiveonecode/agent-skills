# Spec must-have checklist

Use this checklist as a hard gate before marking a spec as ready.

## MUST items (blocking if missing)

| ID | Requirement | Why it is mandatory |
|---|---|---|
| M01 | Document metadata (`ID`, `version`, `status`, `last updated`, optional parent/owner). | Prevent stale, ownerless specs. |
| M02 | Clear objective and problem statement. | Anchor decisions to outcomes, not implementation guesses. |
| M03 | Explicit scope and explicit non-goals. | Prevent scope creep and hidden assumptions. |
| M04 | Functional requirements written as testable statements. | Make implementation and QA unambiguous. |
| M05 | Behavior for success path, edge cases, and failures. | Avoid undefined runtime behavior. |
| M06 | Interfaces/contracts (API shapes, events, I/O, schemas, protocol rules) where applicable. | Keep integrations deterministic. |
| M07 | Data model and state transitions where applicable. | Define lifecycle and consistency expectations. |
| M08 | Non-functional requirements (performance, reliability, scalability, observability). | Make quality attributes explicit and enforceable. |
| M09 | Security/privacy/compliance requirements or an explicit `N/A` with rationale. | Prevent silent high-risk omissions. |
| M10 | Dependencies, assumptions, constraints, and external prerequisites. | Surface risks and planning constraints early. |
| M11 | Verification plan mapped to requirements. | Ensure each requirement is actually verifiable. |
| M12 | Completion criteria with pass/fail outcomes. | Define "done" objectively. |
| M13 | Traceability links to related docs/specs/ADRs/tickets. | Preserve context and decision lineage. |
| M14 | Document history (change log by version/date/summary). | Keep updates auditable. |

## SHOULD items (strongly recommended)

| ID | Recommendation | Benefit |
|---|---|---|
| S01 | Glossary for domain-specific terms. | Reduce interpretation drift across teams. |
| S02 | Migration/backward-compatibility strategy when changing contracts. | Lower rollout risk and regression risk. |
| S03 | Rollout and rollback plan. | Improve operational safety in production. |
| S04 | Monitoring and alerting expectations. | Enable quick issue detection after release. |
| S05 | Risk register with severity and mitigation. | Make tradeoffs explicit and reviewable. |
| S06 | Ownership mapping (who approves, who implements, who operates). | Improve execution accountability. |
| S07 | Timeline or phase plan for multi-stage delivery. | Align delivery sequencing across teams. |

## Readiness decision

- Mark `Ready` only if all MUST items are present.
- Mark `Conditionally Ready` only if all MUST items are present and open questions are low-risk.
- Mark `Not Ready` if any MUST item is missing or ambiguous.
