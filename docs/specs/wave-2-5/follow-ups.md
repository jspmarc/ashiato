# Wave 2.5 — follow-ups

Deferred during implementation and review. None block the shared transport.

## Error presentation

`Ashiato.HTTP` and the outbound clients return structured reasons:
`{:http, status}`, `{:transport, atom}`, `:invalid_url`, `:invalid_json`, `:request_failed`.

Do not turn these into user-facing strings in the transport or service adapters. Map them at
`AshiatoWeb` (or a dedicated presenter) when a UI/API consumer exists. Keep provider bodies,
headers, URLs, and exception messages out of the mapped output.

Redirect errors specifically are `{:http, 301 | 302 | 307 | 308}`. `Location` is intentionally
not returned, so the message must stay generic ("configure the final HTTPS URL").

## Redirect policy

The transport sets `redirect: false` for every request. A same-host-only redirect policy
(notably HTTP → HTTPS) could be added deliberately later. Req's built-in redirect follows every
host, including credential-bearing requests, so it is not suitable as-is.

## 2xx handling

`Ashiato.HTTP` accepts only 200. Every current service returns 200. If a service needs 201 or 204,
widen deliberately and add an empty-body rule for callers at the same time.

## Timeout verification

ERTS call tracing is disabled on the development host. AC-6 verifies the 10 s timeout defaults by
code inspection; retry and redirect are behaviorally tested.
