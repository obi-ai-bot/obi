# Oby's control plane

A Cloudflare Worker with a D1 database (#285): sign-in by email code, one installation per Mac with its own revocable credential, and one Cloudflare Tunnel per installation behind an opaque hostname, `oby-<opaque>.tetrix.pro`, routed only to the gateway on the Mac.

- How it's deployed, its API, and how the Mac and the iPhone use it: [docs/remote-access.md](../../docs/remote-access.md).
- `pnpm install`, then `pnpm exec vitest run --config worker.vitest.ts` (inside workerd, with the Cloudflare API and the email sender mocked), `pnpm check` (TypeScript), `pnpm dev` (`wrangler dev` with `.dev.vars`).
- Secrets are never in git, D1 or logs: `wrangler secret put` in production, `.dev.vars` locally (`.dev.vars.example` has the placeholders).
