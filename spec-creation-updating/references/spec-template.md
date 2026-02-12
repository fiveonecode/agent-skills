# Generic specification template

Use this as a starting structure. Keep sections that apply, and mark non-applicable ones as `N/A` with a short rationale.

## Document header

```md
# <Spec title>

> **Document ID:** <SPEC-XXX or equivalent>
> **Version:** <major.minor.patch>
> **Last Updated:** <YYYY-MM-DD>
> **Status:** <Planned | Active | In Progress | Deprecated>
> **Parent/Owner:** <optional>
```

## 1. Objective and context

- Problem statement.
- User/business outcome.
- Success criteria.

## 2. Scope

- In scope.
- Out of scope / non-goals.
- Assumptions and constraints.

## 3. Requirements

- Functional requirements with IDs (`REQ-001`, etc.).
- Edge cases and failure behavior.
- Acceptance criteria per requirement.

## 4. Interfaces and contracts

- API/interface definitions.
- Request/response/event schemas.
- Error contract and retry behavior.
- Versioning and backward compatibility.

## 5. Data and state

- Data entities and relationships.
- State machine or lifecycle transitions.
- Retention, consistency, and deletion rules.

## 6. Non-functional requirements

- Performance targets.
- Reliability/SLA/SLO expectations.
- Scalability limits.
- Observability (logs, metrics, traces, alerts).

## 7. Security, privacy, and compliance

- AuthN/AuthZ model.
- Secret handling.
- PII/data classification and minimization.
- Regulatory/compliance requirements.

## 8. Implementation status and plan

- Implemented / in progress / planned breakdown.
- Dependencies and sequencing.
- Rollout and rollback strategy.

## 9. Verification and completion

- Verification playbook (commands and manual checks).
- Requirement-to-test mapping table.
- Completion criteria with pass/fail outcomes.

## 10. Risks and open questions

- Known risks with mitigation.
- Open questions with decision owner and due date.

## Document history

| Version | Date | Author | Changes |
|---|---|---|---|
| 0.1.0 | YYYY-MM-DD | <name> | Initial draft |

## Related documents

- Links to upstream specs, ADRs, operational runbooks, and tickets.
