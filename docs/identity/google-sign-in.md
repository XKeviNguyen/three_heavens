# Sign in with Google

Three Heavens offers Sign in with Google as an additional way to sign in. It
authenticates identity only: it uses Google Identity Services (GIS) ID-token
sign-in, requests no Google API scopes, never uses an OAuth client secret, and
never stores Google tokens. Email/password sign-in, registration, and email
confirmation are unchanged.

## How it works

1. `/login`, `/registration/new`, and the account page render Google's official
   button through the GIS JavaScript API in **redirect mode**. One Tap and
   automatic sign-in are never enabled.
2. Just before showing the button, the page fetches a server-signed, 10-minute,
   single-use *ceremony* (`POST /auth/google/ceremony`: CSRF-protected, rate
   limited, `no-store`) and gives it to GIS as the ID-token `nonce`. It records
   the intent (sign in or link), the linking user, interface language and
   appearance, and a same-origin return path, all taken from the server. No
   ceremony is embedded in the page. The button is withdrawn a minute before
   its ceremony expires and renewed while the page is visible (at most 12 times
   per page view); Turbo snapshots never keep a live button.
3. Google posts the credential to `POST /auth/google/callback`
   (`application/x-www-form-urlencoded`; bodies over 8 KB are refused before
   Rails parses them; rate limited to 10 per 3 minutes per client address).
4. The callback requires Google's `g_csrf_token` cookie and form field to be
   present and equal (constant-time comparison). Only this action skips the
   Rails authenticity token; the double-submit check replaces it.
5. `googleauth` verifies the ID token: signature against Google's rotating
   keys, issuer `accounts.google.com`, audience equal to `GOOGLE_CLIENT_ID`,
   and expiry. Google's public keys are fetched with 3 s/5 s timeouts,
   refreshed at most once a minute, and trusted for at most an hour.
6. The claims must contain a bounded `sub`, a valid email, and a nonce that is
   an unexpired ceremony issued by this server and not used before.

Google's cross-site POST does not carry the SameSite=Lax session cookie; that
is why the ceremony, not the session, carries the sign-in context. For the same
reason the callback never writes a session cookie unless it completes a sign-in
(a new cookie would replace, and so sign out, the browser's real session).
Outcomes travel in a one-minute signed cookie holding an allowlisted code: a
failed link returns the signed-in user to **Account**; other failures show on
the sign-in page.

## Account rules

- **Identity** is `(provider = "google", provider_uid = sub)` in
  `federated_identities` (unique on both columns; one Google identity per
  user). Email is never used as the identity key.
- **Known identity:** signs in its user through a fresh session (the same
  rotation as password sign-in). Disabled accounts and unconfirmed emails are
  refused; Google never overrides local account status.
- **New identity, new email:** creates an ordinary, verified user with role
  `user`, status `active`, `managed_ai_access = false`, and the current
  language and appearance, but only when Google is authoritative for the
  address: a verified `@gmail.com` address, or a verified Google Workspace
  address (`hd` present). The account has no password.
- **Other addresses:** a Google Account can carry a third-party address that
  its owner no longer controls, so no account is created for it (creating one
  would let that Google Account squat on, or later take over, the address).
  The person creates an account with email and password, which confirms the
  address, and then connects Google.
- **New identity, existing email:** nothing is linked or created. The person is
  told to sign in to the existing account and connect Google there.
- **Linking:** from **Account** (`/settings/account`), a signed-in user
  continues with Google. The callback only stores the verified identity in a
  5-minute encrypted cookie; the user then confirms with a same-origin,
  CSRF-protected request that attaches it to `current_user`. An identity owned
  by another account is refused without revealing that account. Signing out
  discards a pending link.
- **Disconnect:** refused when Google is the account's only sign-in method.
- Paid AI access is unaffected by how a person signs in.
- Password sign-in to an account without a password still performs a bcrypt
  comparison, so response timing does not reveal Google-only accounts.

Logs record only a failure category, never the credential, claims, or CSRF
token; `credential` and `g_csrf_token` are filtered from request logs.

## Content Security Policy

When `GOOGLE_CLIENT_ID` is set, the policy adds only these path-scoped GIS
sources (none are added when it is absent):

| Directive     | Added source                           | Why                          |
| ------------- | -------------------------------------- | ---------------------------- |
| `script-src`  | `https://accounts.google.com/gsi/client` | the GIS library             |
| `frame-src`   | `https://accounts.google.com/gsi/`     | Google's button iframe       |
| `connect-src` | `https://accounts.google.com/gsi/`     | GIS status requests          |
| `style-src`   | `https://accounts.google.com/gsi/style` | GIS stylesheet              |

`style-src` also carries the per-request nonce. GIS copies its script element's
nonce onto the `<style>` it injects, and Turbo does the same for its progress
bar; neither works under `style-src 'self'` alone. No `unsafe-inline` or
wildcard is used, and the Cross-Origin-Opener-Policy is unchanged (redirect
mode opens no popup). GIS also writes a few inline `style` attributes, which
this policy blocks; the button still renders, at Google's compact width.

## Local development

1. In Google Cloud **Google Auth Platform**, use an OAuth client of type
   **Web application**. The development client for this project is
   `444079753360-rb87if1mte8djjtfbjf5763br9anchcj.apps.googleusercontent.com`
   (a public identifier).
2. **Authorized JavaScript origins:** `http://localhost:3000`
3. **Authorized redirect URIs:** `http://localhost:3000/auth/google/callback`
4. While the project's publishing status is **Testing**, only accounts listed
   under **Audience → Test users** can sign in. Add your development Google
   account there.
5. Start the app with `GOOGLE_CLIENT_ID=<development OAuth client ID>` in the
   environment and open it at `http://localhost:3000`. Other hosts or ports,
   including `127.0.0.1:3000`, are different origins and Google rejects them.

No client secret is needed. Do not add one to the environment or `.env.example`.

## Production domain (later)

Do not perform these steps until the production domain is ready.

1. Create a **separate** production OAuth client (Web application); do not
   reuse the localhost development client.
2. For a production domain `example.com`, configure
   - Authorized JavaScript origin: `https://example.com`
   - Authorized redirect URI: `https://example.com/auth/google/callback`

   Add `https://www.example.com` and `https://www.example.com/auth/google/callback`
   only if `www` is actually served as its own application origin.
3. Production must be served over HTTPS (it already forces SSL).
4. Set `GOOGLE_CLIENT_ID=<production client ID>` in the production environment
   (for Kamal, add it to the `env` section of `config/deploy.yml`). Do not set
   a client secret.
5. Keep `APP_HOST` set to the canonical production host so the callback URL
   the page sends to Google matches the configured redirect URI.
6. Add the production domain to the Google Auth Platform branding / authorized
   domains configuration.
7. While the Google Auth project is in Testing, only its test users can sign
   in. Before public use, complete the consent-screen branding and publish the
   app as Google requires.
8. After configuring the domain, re-test the landing page, sign in, sign up,
   the Google callback, the CSP (browser console), HTTPS, the session cookie,
   and return-to redirects.
