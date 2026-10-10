# Case 05 — A post-merge CI failure was a Turbo test synchronization race

**Evidence:** [PR #70 — Fix system-test synchronization races](https://github.com/XKeviNguyen/three_heavens/pull/70) (merged 2026-10-03). Reported failing CI run: `37000764625` on `develop` commit `286ba85`.

**Classification:** Real CI failure with reproducible flaky system tests, **not** a confirmed application regression.

## Symptom

A system test intermittently failed with `Capybara::ElementNotFound: Unable to find field "Project name"`. The failing screenshot still showed the Projects page, not the expected translation workspace. During correction, two other pre-existing timing problems were uncovered around discard/navigation and appearance persistence.

## Root cause

A Turbo link click returned before the target page finished rendering. The test immediately interacted with a locale sidebar present on *both* pages. Submitting its form from the old Projects page canceled the pending Turbo navigation and returned to Projects. Assertions on shared layout/appearance elements could still pass, hiding the race until the workspace-only field was requested.

Other races had the same pattern: `assert_current_path` did not prove a page had re-rendered, and a background appearance-saving fetch had not completed before navigation.

## Correction

- Wait for **page-specific rendered state**, not merely link clicks or common layout elements: e.g., wait for the Projects heading and then the workspace-only `Project name` field.
- Wait for the reset form after discard.
- Wait for the existing `appearance:saved` event before navigating with scripts disabled.
- No sleeps, retry loops or global wait-time increases were introduced.

## Verification

PR #70 provides same-process reproduction and Turbo event logs; unfixed: 6/20 failures in two runs and 3/20 in another, fixed: 0/40 for the main race. The other races were also reproduced and passed repeated fixed-version runs. Multiple complete system suites passed under 2 and 4 workers. The PR changed only test files.

## Lesson

**Test synchronization must track a meaningful observable state transition.** A URL, shared sidebar, or click completion does not necessarily prove the destination component is ready. First reproduce and distinguish a flaky test from a real product failure before modifying production code.

**Interview angle:** Contrast event/state-based waits with arbitrary `sleep` calls.
