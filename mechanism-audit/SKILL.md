---
name: mechanism-audit
description: Audit whether a spec, task, harness, agent workflow, safety boundary, or operational contract is actually enforced by concrete mechanisms. Use when reviewing or changing AGENTS.md, CLAUDE.md, .agents/manifests, .agents/verify, .agents/evals, spec/agents, build/test specs, task plans, risk/execution contracts, source-of-truth boundaries, session closeout rules, verifier classifications, or any explicit request to check whether a promised guarantee is real.
---

# Mechanism Audit

## Purpose

Use this skill to test whether a stated promise is enforced by code, config,
verification, or operational process. Keep the audit short and evidence-led.
Do not run a broad multi-expert swarm. This skill is safe to use from high or
xhigh reasoning contexts because it is a bounded checklist, not a creativity
prompt.

## Inputs

Gather only the evidence needed to test the promise:

- the promise or contract being audited
- the files that define the rule
- the code, config, or process that enforces it
- the verification profile, test, artifact, or manual proof that checks it
- the task/session context when the harness requires a durable audit artifact

If the promise is unclear, rewrite it as one testable sentence before auditing.

## Audit Workflow

1. **Name the promise.** State what the doc, task, or harness appears to
   guarantee. Use one sentence.
2. **Map the enforcement chain.** List the concrete files, commands, checks,
   code paths, review gates, or artifacts that make the promise true.
3. **Find bypass paths.** Look for ways the promise can be skipped, narrowed,
   stale, manually overridden, or satisfied by prose instead of proof.
4. **Check verification.** Decide whether the current tests, verifier profiles,
   required evidence, or closeout gates would catch the bypass paths.
5. **Give a verdict.** Use exactly one of:
   - `holds`
   - `partially holds`
   - `does not hold`
   - `not enough evidence`
6. **List fixes.** Use:
   - `P0` for fixes required before the guarantee should stand
   - `P1` for robustness improvements that strengthen an already plausible
     guarantee

## Output Shape

Use this format:

```text
Promise:
- <one testable sentence>

Enforcement chain:
- <file/code/config/process evidence>

Bypass paths:
- <specific bypass or "none found">

Verification coverage:
- <what is checked and what is not checked>

Verdict:
- <holds | partially holds | does not hold | not enough evidence>

Fixes:
- P0: <required fix, or "none">
- P1: <strengthening fix, or "none">
```

## Harness Artifact

When a repo harness requires mechanism-audit evidence for the current session,
write the same output to:

```text
<session-dir>/mechanism-audit.md
```

Do not create a durable artifact for small ad hoc answers unless the user or
harness asks for it.

## Quality Bar

- Prefer exact file references and command names over general claims.
- Separate policy from enforcement. A sentence in `AGENTS.md` is policy; it is
  not enforcement unless another gate checks it.
- Treat stale state, narrowed path sets, manual override paths, and missing
  artifact checks as potential bypasses.
- Do not call a promise enforced just because a human is expected to notice it.
- Do not use text keyword matching as evidence that an audit is required.
  Audit requirements should come from manifests, task metadata, changed
  contract fields, or explicit user direction.
