# Edge proxy evaluation: kamal-proxy or Traefik

**Recommendation: keep the current stack** (kamal-proxy → Thruster → Puma →
Rails). Traefik showed no material advantage for the planned single-VPS
deployment, and adopting it would replace Kamal's health-gated deploy and
rollback with tooling this project does not have. This is a recommendation;
the architecture decision belongs to a person.

## What was compared

`script/evaluations/edge_proxy.rb` ran both proxies on one machine in front of
the same production-like image (Thruster → Puma → Rails, 768 MiB limit), with
TLS from a throwaway local CA that the client verified (verification was never
disabled):

- **kamal-proxy v0.9.2**, deployed with the options Kamal renders from
  `config/deploy.yml` that affect requests: `--tls`, `--health-check-path=/up`,
  `--buffer-requests`, `--buffer-responses`, `--max-request-body=22020096`.
  Kamal also passes 30-second deploy and drain timeouts (kamal-proxy's
  defaults) and request-header logging, which were left at their defaults,
  and production obtains its certificate from Let's Encrypt rather than a
  file.
- **Traefik v3.5** with a file provider: HTTP→HTTPS redirect, a TLS router for
  the host, the `buffering` middleware with `maxRequestBodyBytes: 22020096`,
  and a `/up` health check on the service. This configuration exists only
  inside the evaluation script; nothing in production configuration changed.

No production host, credential or paid provider was involved. Run it again
with `IMAGE=<local image> bin/rails runner script/evaluations/edge_proxy.rb
tmp/edge_proxy.json`.

## Results

| Check | kamal-proxy | Traefik |
|---|---|---|
| HTTP → HTTPS | 301 | 301 |
| `/up`, `/ready`, `/login` through the proxy (Host `APP_HOST`) | 200, 200, 200 | 200, 200, 200 |
| 11 failed sign-ins, each with a different client-chosen `X-Forwarded-For` | 11th throttled (429): the spoofed header was ignored | throttled from the 1st: the same real client address as the kamal-proxy run, so the spoofed header was ignored |
| `Client-Ip` disagreeing with `X-Forwarded-For` | 200 (the application drops `Client-Ip`) | 200 |
| Chunked 30 MiB body (64 KiB and 1 KiB chunks) | 413 from the proxy | 413 from the proxy |
| Declared `Content-Length` over 21 MiB, no body sent | no answer within 30 s: it waits to read the body | 413 at once |
| Malformed chunk framing | 500 from the proxy ("Error buffering request: invalid byte in chunk length"); never reaches the application | 500 from the proxy |
| Two 10 MiB files in one multipart request | reaches the application | reaches the application |
| 150 clients sending headers one byte per second, `/login` probed meanwhile | 10/10 200, slowest 0.033 s | 10/10 200, slowest 0.046 s |
| Memory idle → peak during 40 simultaneous 30 MiB bodies | about 11.5 MiB idle, peaks of 11.6 to 20.4 MiB (three runs); 1.2 s CPU for the 40 bodies | about 23 MiB idle, peaks of 27.8 to 54.9 MiB (three runs); 1.35 s CPU for the 40 bodies |
| Deploy to a second container and roll back, under ~15 requests/s | 0 failed of 144 requests; each switch waited for `/up` and took 0.17 s | 0 failed of 224 requests, but only because the script waited a fixed 3 s after each change before stopping the old container |

Both proxies terminate TLS, route by host, buffer and limit bodies before they
reach the container, keep the client address trustworthy for Rails'
`remote_ip`, and pass the application's own uploads and health endpoints.
The application uses no WebSockets (no Action Cable channels; Turbo works over
HTTP), and Google's callback is an ordinary cross-site form POST, which both
pass unchanged.

Observations about kamal-proxy, neither a defect in this application:

- It answers malformed chunk framing with 500 rather than 400. Traefik does
  the same. The request never reaches Thruster or Rails.
- It does not reject a declared oversized `Content-Length` before reading;
  it reads up to the limit and then answers 413, so a client that declares a
  large body and sends nothing holds a connection until the client gives up.
  Traefik answers 413 from the header alone.

## Why Traefik is not materially better here

- **Deploy and rollback.** Kamal 2 drives kamal-proxy: a deploy waits for the
  new container's `/up`, switches, and drains the old one; `kamal rollback`
  reverses it. Kamal 2 dropped Traefik support, so Traefik would need its own
  container-switching procedure (the evaluation switched by rewriting the
  file provider and waiting a fixed 3 seconds, which has no health gate or
  drain).
- **Footprint.** kamal-proxy used about half of Traefik's memory, which
  matters on a 2 GB VPS that also runs PostgreSQL and the 768 MiB web
  container.
- **Coexisting with other services on one VPS.** kamal-proxy already routes
  several hosts on one machine: every Kamal app deploys to it with its own
  `proxy.host`, and a container deployed some other way can be put behind it
  with `kamal-proxy deploy <service> --target <container>:<port> --host
  <name>` on the `kamal` network. If another proxy must keep ports 80/443,
  leave kamal-proxy unpublished (or on other ports) and forward to it; the
  client address then needs care: the outer proxy must append the address it
  received the connection from to `X-Forwarded-For` (or replace the header
  with it) and be the only route to kamal-proxy, and kamal-proxy must forward
  the header (`forward_headers: true`), or every client shares the outer
  proxy's sign-in budget. Production does this with a Cloudflare Tunnel; see
  step 11 of `production-deploy.md`.
- **What Traefik adds.** Edge rate limiting (`rateLimit`, `inFlightReq`), IP
  allow-lists, TCP routing and a dashboard. None is needed by the current
  product; overload protection beyond what the application and container
  enforce (see step 10 of `production-deploy.md`) is better placed at the
  hosting provider's network edge. If a future requirement needs one of these
  at the edge, evaluate it as its own change.

Docker Swarm was not considered: nothing here needs multi-node orchestration.
