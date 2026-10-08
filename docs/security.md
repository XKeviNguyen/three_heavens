# Security

This page lists the controls that exist in the code today, and the known residual risks. It contains no secrets or deployment addresses.

## Authentication and sessions

- **Email and password.** Passwords are stored with bcrypt (minimum 12 characters). An account must confirm its email before signing in; confirmation links use the configured `APP_HOST`, never the request's Host header.
- **Database-backed sessions.** The encrypted session cookie carries only a session row ID. Signing out deletes that row, so a copied cookie stops working. Disabling an account deletes all its sessions in the same transaction. Sessions expire after 30 days and are purged hourly.
- **Sign in with Google.** Google Identity Services (redirect mode) posts an ID token that is verified for signature (rotating Google keys), issuer, audience (our client ID), expiry, and a nonce that can be used only once (`ConsumedNonce`). Only a public client ID is configured; there is no client secret. New accounts are created from Google only when Google is authoritative for the email; otherwise the user must create a password account first and link Google from Account.
- **Rate limits.** Sign-in, registration, confirmation resend, and file uploads are rate limited. Uploads are counted per fixed 5-minute window; further uploads get HTTP 429 with `Retry-After`.

See [Google sign-in](identity/google-sign-in.md) for the identity flow.

## Authorization

- Every owned record is loaded through the signed-in user's associations. Another user's project, translation, draft, or file returns the same "page unavailable" response as a missing record, without revealing that it exists.
- AI work requires a separate per-account **AI access** flag that only administrators can turn on. Without it users can prepare documents and guidance, but no AI request runs; already-running automatic workflows block with a plain reason.
- Admin pages (users, models, operations) require the admin role.
- Original uploads are downloaded only through an ownership-checked controller with attachment disposition; there are no public or permanent blob URLs (`active_storage.draw_routes = false`).

## Browser protections

- Rails CSRF protection on every form and JSON endpoint.
- A strict Content Security Policy: `default-src 'self'`, per-request nonces for scripts and styles, `object-src 'none'`, `base-uri 'self'`, `form-action 'self'`, `frame-ancestors 'none'`. Google's script origins are allowed only when Google sign-in is configured.
- Production forces HTTPS with secure cookies and HSTS, and authorizes only `APP_HOST` (Host Authorization).
- Server-rendered ERB escapes all user and model text. Markdown sources are kept as plain text and never rendered as HTML. Model output is displayed as text.
- Draft autosave responses send `Cache-Control: no-store`.

## Request and input limits

- Each route has a request-body limit enforced from `Content-Length` before parsing and while reading bodies without one: 64 KiB by default, 8 KiB for signed-out identity forms, 2 MiB for long-text forms, 21 MiB for the two upload forms (POST/PATCH/PUT only). Puma also stops chunked bodies above 21 MiB, and kamal-proxy enforces the same 21 MiB cap.
- Source-import deliveries and multipart reference requests require an active, verified account with an unexpired server-side session before Rack parses the body. PostgreSQL admits at most 30 deliveries per account per fixed 5-minute window, including malformed uploads and retries. Denied requests return 401 or 429 without reading `rack.input`; 429 includes `Retry-After: 300`. The separate 10-request extraction budget still allows exact upload replay at exhaustion and retains receipt-based Busy refunds. Both counters use one row per account. Proxy/Puma buffering happens before this gate; their existing byte limits still apply. This account limit does not provide network flood protection.
- JSON bodies are limited to 512 KiB for draft autosave and 8 KiB elsewhere, and are parsed only if they contain at most 1,000 strings, containers, and separators.
- Requests with null bytes, unknown parameter keys on sensitive endpoints, or malformed identities are rejected with 400.

## Untrusted files

Uploads accept `.txt`, `.md`, `.docx`, and text `.pdf` up to 10 MiB. Details are in [documents](architecture/documents.md); in short:

- **DOCX:** macro-free WordprocessingML only. Package structure, content types, relationships, and extension/MIME/magic bytes must agree. A bounded in-memory ZIP reader caps entries (500), declared expansion (50 MiB), and XML sizes, and rejects encrypted entries, macros, embedded objects, path traversal, ambiguous names, and suspicious compression. XML parsing is strict, DTD-free, and network-disabled.
- **PDF:** text is extracted by `pdf-reader` in a separate, resource-limited child process that inherits no application environment, credentials, or open files (only `MALLOC_ARENA_MAX=2` is passed), with its own process group, 256 MiB address space, a 5-second CPU and wall-clock limit, at most 100 pages, and no file writes or core dumps. Where Linux allows it, the worker sets `oom_score_adj=1000` on a best-effort basis. One PDF worker runs per container, coordinated by an in-process slot limit.

## AI provider boundary

- Only `Ai::OpenRouterClient` and `OpenRouter::Catalog` talk to OpenRouter. The API key comes from the environment and is never shown or stored in the database.
- Requests send explicit completion limits; responses are streamed through a 1 MiB cap before JSON parsing.
- Structured responses (reviews, judgments, suggestions) are validated against JSON schemas and expected candidate labels before they are stored.
- Provider errors are stored as sanitized codes. Raw provider bodies, prompts, and remote error text are not displayed; historical rows with older error text render a generic message.
- No hidden reasoning text from providers is stored.
- Automated tests replace provider clients with fakes, and a guard limits Ruby `Net::HTTP` connections (which every provider client uses) to loopback; browser tests block Google.

## Secrets and data in logs

- Secrets come from environment variables or the operator's secret manager; `config/deploy.yml` lists only variable names.
- Rails parameter filtering covers passwords, tokens, keys, emails, editor identities, source text, translations, glossary terms, methodology text, final translation content, and draft payloads, and truncates any long string.
- Drafts and failed reference-creation outcomes are encrypted at rest with Active Record encryption.
- Operational events are fixed-schema JSON lines with allow-listed, bounded fields. The admin Operations page shows aggregates only — no source text, translations, prompts, storage paths, or credentials.

## Supply chain and scanning

- CI runs Brakeman (`--ensure-latest`), bundler-audit, and importmap audit on every pull request and on pushes to `main` and `develop`.
- GitHub Actions are pinned to release commit SHAs; Docker base images and CI PostgreSQL services are pinned to multi-architecture digests. CI runs with `contents: read` and does not persist checkout credentials; there is no `pull_request_target` execution of pull-request code.
- The production image runs as a non-root user (uid 1000).

## Known residual risks

- The PDF worker runs as the application user. Its limits stop resource exhaustion, but a code-execution flaw in `pdf-reader` could still affect files that user can write (for example the storage volume). Further isolation would need a separate user or kernel sandbox.
- Token-budget estimates are conservative approximations, not provider tokenizers.
- Security controls are verified by automated tests and review, not by an external penetration test.
