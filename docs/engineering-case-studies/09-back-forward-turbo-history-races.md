# Case 09 — Back/Forward races with pending saves and Turbo navigation

**Evidence:** [PR #64](https://github.com/XKeviNguyen/three_heavens/pull/64); [PR #72 — Replay, history and recovery corrective](https://github.com/XKeviNguyen/three_heavens/pull/72) (merged 2026-10-07).

**Classification:** Browser history/autosave failures reproduced in release and system testing, not a documented customer production incident.

## Problem and impact

During a pending autosave, a user could navigate **Back**, immediately **Forward**, choose **Stay**, or discard and navigate to a fragment on the same page. Previous behavior could restore a stale Turbo snapshot/editor identity, display the wrong draft state, or produce false conflicts even though the server retained newer data. These paths were important because users navigate before background requests finish.

## Root cause / failure boundary

Browser History API traversal, Turbo rendering, the workspace's asynchronous navigation guard, and autosave acknowledgements each advance on different timelines. A URL change or cached DOM does not prove that a newer editor identity/source is safe to render. For same-document fragment destinations, replacing the page without respecting the requested fragment/history entry can likewise produce an incorrect landing position.

## Solution

- Exclude the workspace from the Turbo snapshot cache when cached editor identity would be stale.
- Preserve current draft/editor ownership while a guarded navigation is unresolved; refuse superseded history renders.
- Keep the user's response-loss and pending-save state until the source-of-truth action settles.
- Route successful discard resets through the existing forced document-load helper; preserve the same-document history state and requested URL fragment before reloading. Use normal navigation for different destinations.
- Prefer explicit state transitions and event-driven verification over arbitrary sleeps and broad timing retries.

## Verification

The system test `translation_workspace_draft_test.rb` includes **Back → Forward** with a draft retained, plus `history.back()` immediately followed by `history.forward()` while a save has not been acknowledged (including deliberately lost responses). PR #72 reports a focused history suite of **60 tests / 489 assertions** and additional fragment/discard/guarded-navigation regressions.

The test matrix covers named transitions; it is **not** evidence that every possible number or ordering of rapid Back/Forward clicks has been exhaustively explored.

## Lesson

**Browser navigation is concurrent state, not just routing.** Every asynchronous save and render needs ownership/version checks. Never let a cached page, late response, or transient URL state silently replace newer canonical data.

**Interview angle:** Walk through a fast Back → Forward while a save is in flight and identify which state is authoritative.
