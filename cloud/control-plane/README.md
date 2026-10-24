# Oby's control plane

A Cloudflare Worker with a D1 database (#285): one installation per Mac, known by the P-256 key the Mac made and signing every call with it, and one Cloudflare Tunnel per installation behind an opaque hostname, `oby-<opaque>.<DEVICE_DOMAIN>`, routed only to the gateway on the Mac.

- **Anyone can run one.** Each instance is a named environment in `wrangler.jsonc` (`env.<name>`), deployed with `--env <name>`; the top level is a template with nothing instance-specific. Deskree's own is `env.deskree`, at `oby-control.deskree.com`, for Deskree's Google Workspace accounts only (`MEMBER_WORKSPACES`). To run yours: [docs/remote-access.md, Run your own control plane](../../docs/remote-access.md#run-your-own-control-plane).
- Every setting is documented in `src/env.ts`. Only public values go in `wrangler.jsonc`; secrets are never in git, D1 or logs (the APNs provider token made from one is kept in D1 only sealed): `wrangler secret put --env <name>` in production, `.dev.vars` locally (`.dev.vars.example` has the placeholders).
- `pnpm install`, then `pnpm test` (inside workerd, with the Cloudflare API and the sign-in providers faked), `pnpm check` (TypeScript), `pnpm dev --env <name>` (`wrangler dev`).
- Its API, and how the Mac and the iPhone use it: [docs/remote-access.md](../../docs/remote-access.md).

It also relays pushes to iPhones (#398): a phone registers its APNs token (checked with Apple) for a `pushId` and `pushSecret`, gives obid the `pushKey` made from the secret, obid posts alerts sealed to the phone's key, and the Worker sends Apple a fixed alert with the sealed blob, which it can't read. The APNs key and `PUSH_SECRET_KEY` are Worker secrets: [docs/remote-access.md, Pushes](../../docs/remote-access.md#pushes).
