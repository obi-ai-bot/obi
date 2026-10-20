# Oby's control plane

A Cloudflare Worker with a D1 database (#285): no accounts: one installation per Mac, known by the P-256 key the Mac made and signing every call with it, and one Cloudflare Tunnel per installation behind an opaque hostname, `oby-<opaque>.tetrix.pro`, routed only to the gateway on the Mac.

- How it's deployed, its API, and how the Mac and the iPhone use it: [docs/remote-access.md](../../docs/remote-access.md).
- `pnpm install`, then `pnpm test` (inside workerd, with the Cloudflare API mocked), `pnpm check` (TypeScript), `pnpm dev` (`wrangler dev` with `.dev.vars`).
- Secrets are never in git, D1 or logs: `wrangler secret put` in production, `.dev.vars` locally (`.dev.vars.example` has the placeholders).

The Worker currently provisions tunnels only. It does not relay APNs pushes; the runner sends APNs directly while awake until a separately specified relay adds token storage, APNs secrets, and an event API.
