# Case 06 — Signing out did not revoke a copied session cookie

**Evidence:** [PR #69 — V1.1 security/auth stabilization](https://github.com/XKeviNguyen/three_heavens/pull/69) (merged 2026-10-02).

**Classification:** Confirmed security flaw addressed in the authentication stabilization work; no confirmed exploitation is claimed.

## Symptom and risk

A session cookie copied *before* sign-out remained usable after the original browser signed out. The normal logout appeared to succeed, but it invalidated only the browser's current cookie state, not copies of the earlier credential.

## Root cause

Cookie-store authentication encoded `session[:user_id]` in an encrypted browser cookie. `reset_session` issued a new cookie to the signing-out browser but could not revoke an already-copied old cookie. There was no authoritative server-side session record to check.

## Correction

- Add a `sessions` database table with user foreign key (cascade on deletion) and appropriate indexes.
- Each login creates a server-side session row; the encrypted cookie holds that row identifier instead of granting authorization solely from `user_id`.
- Signing out deletes *that* session row. Signing in again in the same browser rotates/replaces its row; other devices' sessions are preserved.
- Authentication checks reject expired, missing or disabled-account sessions; expired sessions are cleaned periodically, with a 30-day maximum lifetime.
- Google sign-in was adjusted for the cross-site POST/SameSite=Lax flow using a short-lived, single-use pending sign-in and a same-site completion redirect.

## Verification

PR #69 documents regression tests covering copied cookies after sign-out, independent devices, same-browser rotation, expiry boundaries, disabled accounts, legacy cookies, and the Google completion flow, alongside Rails and system tests and security scanners.

## Lesson

**Encryption proves a cookie has not been modified; it does not revoke a copied credential.** When immediate logout or disabling an account must revoke access, authorization needs a server-side state boundary or another revocation mechanism.

**Interview angle:** Explain the trade-off between purely stateless cookies and server-side sessions, and why logout must invalidate authority rather than only update a client.
