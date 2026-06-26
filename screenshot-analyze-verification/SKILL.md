---
name: screenshot-analyze-verification
description: Strict screenshot QA and approval gate for simulator captures. Use when validating UI screenshots, hint overlays, spotlight behavior, dark mode, and cross-OS parity. Fails fast on wrong app/page, missing elements, weak contrast, bad padding, overlap, clipping, and hidden-element leaks.
---

# Screenshot Analyze Verification

## Purpose

Use this skill whenever screenshots are presented as proof of UI correctness.
This is a strict, fail-fast workflow.

If any hard gate fails, status is **NOT VERIFIED**.

## Required Inputs (must be explicit)

Do not start validation until all inputs are known:

- Requested app and page/screen.
- Scenario name/state (for example `Training Plan Card`, `Top Toolbar Button`).
- Required simulator/OS coverage.
- Required theme coverage (light and/or dark mode).
- Required visible elements.
- Required hidden or de-emphasized elements.
- Interaction expectation (tap target works, bubble tap ignored, outside tap dismisses).
- Style/reference assets, when approval depends on matching an existing verified composition.
- Allowed transformations on source UI (for example `scale/crop only`, `no redraw`, `no rewritten text`).
- Required composition anchors when using reference-based posters (for example title typography,
  phone placement/scale, elevated card position, background treatment).
- Required export dimensions/format when the artifact is meant for delivery (for example
  `1284x2778 PNG`).

If inputs are incomplete, ask for missing details before approving.

## Hard Gates (non-negotiable)

### Gate 1: Correct App and Correct Page

Fail if capture is from wrong app, wrong screen, wrong route, or wrong scenario.

Required checks:

- Landmark text and hierarchy match expected screen (title, subtitle, scenario label).
- Navigation/chrome match expected route.
- Capture is not from onboarding/other flow when home/lab was requested.
- Scenario-specific label matches requested scenario.

Failure label:

- `NOT VERIFIED: wrong app/page/sim capture`

### Gate 2: Required Elements Present and Complete

Fail if any required element is missing, cropped, or partially outside valid bounds.

Required checks:

- Target element exists and is fully visible.
- Bubble exists, text is complete, arrow/tail is visible.
- Required control(s) for the scenario are present.

### Gate 3: Hidden/De-emphasized Elements Are Actually Suppressed

Fail if non-target UI remains too prominent when spotlight state is active.

Required checks:

- Dimming/blur overlay covers all non-highlight regions uniformly.
- Highlight hole is tightly scoped to the target (does not include unrelated UI).
- Elements required to be hidden/de-emphasized are clearly subdued.
- Persistent chrome elements (for example bottom input bars, tab bars, sticky headers) are also subdued unless they are the target.

### Gate 4: Text Legibility and Contrast

Fail if any critical text is hard to read in required mode(s).

Required checks:

- Primary instructional text is readable at first glance.
- Secondary/supporting text remains readable when meant to be shown.
- Contrast is sufficient over backgrounds/material effects in light and dark mode.
- No text blending into bright highlights or dark blur.

Practical threshold guidance:

- Aim at WCAG-like body-text contrast around 4.5:1 equivalent for critical content.
- If visual inspection is borderline, treat as fail.

### Gate 5: Layout Integrity and Geometry

Fail on any geometry defect that harms clarity.

Required checks:

- No overlapping bubbles or overlap between bubble and critical UI text.
- Long text wraps inside bubble bounds; no text overflow outside shape.
- Bubble padding is adequate and consistent.
- Arrow/tail is attached and not detached/floating.
- Arrow points to actual target location (not centered incorrectly after clamping).
- Bubble and tail are not clipped by safe areas, notch, status bar, or home indicator.

### Gate 6: Reference Fidelity and Composite Cleanliness

Fail when a reference-driven screenshot/poster does not faithfully match the required approved style
or when source/template remnants are visible.

Required checks:

- When a verified reference is provided, typography matches the approved direction closely enough:
  font family feel, weight, line breaks, size hierarchy, and shadow treatment.
- Composition matches the required reference structure closely enough: title block placement,
  device scale/placement, elevated-card footprint, and spacing rhythm.
- No inherited pixels from a source/template remain visible where they should have been removed.
- Screen masking is clean: no old UI peeking around device edges, no halo seams, no clipped chrome,
  no fake dynamic-island/notch overlaps, and no partial underlying layers visible behind cards.
- If real screenshots are required as source truth, the final composite clearly reads as the same
  screenshot content rather than a redraw or hybrid mismatch.
- Output dimensions and file format match the requested deliverable exactly when such a requirement
  was provided.

## Exact Validation Checklist

Mark every row `PASS` or `FAIL`. Any `FAIL` => `NOT VERIFIED`.

1. Context fidelity
- Correct app?
- Correct page/route?
- Correct scenario/state text?
- Correct simulator + OS label for file?

2. Required element presence
- Target element present?
- Bubble present?
- Arrow present?
- All mandatory controls present?

3. Spotlight/hide behavior
- Non-target dimming active and even?
- Highlight aperture constrained to target frame?
- Elements that should be subdued are subdued (including persistent chrome)?
- Tap semantics respected by visual state (bubble informational, target actionable)?

4. Copy and readability
- Text fully visible and not truncated incorrectly?
- Contrast acceptable in all required modes?
- No tiny unreadable labels?

5. Spacing and containment
- Bubble text-to-edge padding adequate (target: ~12-16pt horizontal, ~10-14pt vertical visual equivalent)?
- Long tokens wrap/break without spilling?
- No overlap with neighboring bubbles/components?

6. Arrow correctness
- Tail remains attached at all offsets?
- Tail tip lands on or near intended target anchor?
- Right-side targets use right-biased arrow position when expected?

7. Reference fidelity and artifact cleanliness
- If a verified style reference was provided, does title typography match it closely enough?
- If a verified style reference was provided, does overall composition match it closely enough?
- No inherited template/source artifacts visible at edges, under overlays, or around the device?
- Screen/device masking clean with no halo seams, cut corners, or chrome collisions?
- If source UI was required to remain real, does the composite still read as that same real UI?
- If export dimensions/format were specified, do they match exactly?

8. Cross-mode parity
- All requested OS versions captured?
- At least one dark-mode screenshot per required simulator when dark mode is required?
- No mode-specific regressions in contrast, placement, clipping?

## Common Regression Patterns (Generic)

Treat these as mandatory anti-regression checks. Convert each observed pattern into a finding.

- **INT-01 Wrong capture context**: screenshot is from a different app, route, or scenario than requested.
- **INT-02 Stale build capture**: screenshot was taken from an older binary, not the latest build/reinstall.
- **INT-03 Composition overlap**: hints/bubbles or critical UI overlap and reduce readability.
- **INT-04 Detached pointer/tail**: callout pointer visually disconnects from bubble body.
- **INT-05 Theme readability regression**: light/dark mode causes text contrast or legibility failures.
- **INT-06 Safe-area clipping**: bubble/pointer clips at notch, status bar, or home-indicator regions.
- **INT-07 Pointer mis-targeting after clamping**: bubble is clamped in bounds but pointer no longer points at target.
- **INT-08 Highlight aperture overreach**: spotlight reveals unrelated content outside target scope.
- **INT-09 Suppression leak**: non-target persistent UI remains too prominent during spotlight.
- **INT-10 Visual ambiguity**: arrangement appears broken/accidental rather than intentional hierarchy.
- **INT-11 Template leakage**: pixels from the source/reference/template remain visible after a
  supposed replacement or composite operation.
- **INT-12 Typography mismatch**: headline/body typography materially deviates from the approved
  style reference when a reference match was required.
- **INT-13 Reference-layout mismatch**: device scale, title position, elevated-card placement, or
  spacing rhythm materially diverges from the required reference composition.
- **INT-14 Screen masking defect**: device frame/screen composite shows halo seams, clipped chrome,
  island/notch collisions, or underlying UI peeking around the inserted screen.
- **INT-15 Wrong export spec**: final artifact size or format does not match the requested
  deliverable dimensions/format.

Severity guidance:

- INT-01/02/07/09 are `P1`.
- INT-03/04/06/08/10 are `P1` unless clearly cosmetic and non-blocking.
- INT-05 is at least `P2`, and `P1` when instructional text is difficult to read.
- INT-11/13/14 are `P1` when approval depends on a polished composite or reference match.
- INT-12 is `P1` for marketing/poster assets with approved-series style constraints; otherwise `P2`.
- INT-15 is `P1` for production deliverables.

## Apple UI/UX Practice Layer

Apply Apple-oriented review criteria (from `apple-hig-designer` principles):

- **Clarity**: hierarchy obvious, text instantly legible.
- **Deference**: overlay supports the task and does not visually compete.
- **Depth**: layering and material effects communicate focus, not noise.
- **Accessibility baseline**:
  - sufficient color contrast in light/dark,
  - readable sizes,
  - critical meaning not conveyed by low-contrast decoration alone.

If these principles are violated in a way that affects task completion, fail validation.

## Capture Protocol (before analysis)

When screenshots are newly generated, enforce this protocol:

1. Rebuild and reinstall latest binary on each required simulator.
2. Launch exact scenario/state to be validated.
3. Capture deterministic filenames:
   - `<platform>-<os>-<scenario>-light.png`
   - `<platform>-<os>-<scenario>-dark.png`
4. Verify each file visually matches intended app/page before reporting.

If protocol is not followed, set status to `NOT VERIFIED`.

## Required Output Format

Always respond in this structure:

1. `Verification Status`: `VERIFIED` or `NOT VERIFIED`
2. `Hard Gate Results`:
   - Gate 1: PASS/FAIL
   - Gate 2: PASS/FAIL
   - Gate 3: PASS/FAIL
   - Gate 4: PASS/FAIL
   - Gate 5: PASS/FAIL
   - Gate 6: PASS/FAIL
3. `Findings`:
   - Sorted by severity (`P1`, `P2`, `P3`)
   - Include screenshot path(s)
   - Include exact defect and impact
4. `Required Fixes Before Approval`
5. `Residual Risks` (only if status is VERIFIED with caveats)

Approval rule:

- Never return `VERIFIED` if any hard gate failed.
