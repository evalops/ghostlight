# Security policy

## Alpha deployment boundary

Ghostlight alpha services are intended for a private LAN. Workspace and session routes require an operator bearer token; lease-protected mutations require an additional short-lived controller token; Chromium bridge routes use a separate bearer token. The alpha does not provide user accounts, TLS termination, public internet support, rate limiting, or protection against a compromised host kernel.

The control service listens on TCP port `8080`. The viewer listens on TCP port `8081`. Legacy health, readiness, and viewer discovery are unauthenticated. Treat the API token, bridge token, lease tokens, Neko passwords, and any returned `viewer_url` as bearer capabilities.

Do not expose either port to the public internet. Do not place cookies, profile archives, viewer URLs, or request bodies in issue reports or pull requests.

## Reporting a vulnerability

Report suspected vulnerabilities privately to the repository maintainers before opening a public issue. Include:

- the affected commit, release, or deployment image;
- the control or viewer endpoint involved;
- a reproducible request or a minimal proof of impact;
- the affected asset, such as profile data, session state, or service availability; and
- logs or screenshots with credentials, cookies, viewer URLs, and private network addresses removed.

Do not test against systems you do not own or have permission to assess.

Maintainers should acknowledge a report within five business days, confirm the affected version, and coordinate disclosure after a fix is available. The repository does not promise a specific remediation timeline for alpha software.

## Security changes

Security changes must include a regression test when the affected behavior is testable. Update `docs/architecture.md` when the change alters a trust boundary, threat assumption, persistence rule, or shared API/port contract.
