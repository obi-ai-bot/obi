# Remote access: reach your Mac from anywhere (#285)

Outside the home network, the iPhone reaches the Mac with no port forwarding, no VPN app and no Tailscale account: an Oby control plane on Cloudflare gives each installation its own Cloudflare Tunnel, the Mac runs `cloudflared` outbound as a child of Oby, and the iPhone talks HTTPS to an opaque hostname. The pattern is OpenMausBot's `cloudflare/control-plane`.

- **The control plane** is a Worker with a D1 database, `cloud/control-plane/`, at `oby-control.tetrix.pro`. Sign-in is a six-digit code by email (Sign in with Apple comes with #282). Each Mac registers an installation with its own revocable credential, asks for its endpoint, and gets its tunnel's run token.
- **Hostnames** are first-level names under `tetrix.pro`, `oby-<20 opaque characters>.tetrix.pro`, so Cloudflare's free Universal SSL covers them. Never `<id>.oby.tetrix.pro`: a second-level name would need Advanced Certificate Manager. The zone is the user's own; the Watch API's tunnel lives there too, and the Worker never touches records it didn't make.
- **The tunnel** routes one hostname to the gateway on the Mac (`http://127.0.0.1:8810`, #284) and nothing else: the last ingress rule is `http_status:404`.
- **Secrets** live only in the Worker's secrets (the Cloudflare API token, the account and zone ids, the email sender's key) and in the Mac's keychain (the session token, the installation's credential, the tunnel's token). D1 keeps hashes; nothing secret is logged.

## One-time setup on Cloudflare (the user's step)

Everything below runs on your Mac, in `cloud/control-plane/`. Deploying is never an agent's job.

1. **Install the tools:** `pnpm install` (npm works too). `pnpm test` runs the Worker's tests in Miniflare, `pnpm check` type-checks.
2. **Sign wrangler in:** `pnpm exec wrangler login`. This OAuth login is what deploys the Worker and its D1 database; it covers Workers Scripts and D1 on your account.
3. **Create the API token the Worker uses at run time**, in the Cloudflare dashboard, My Profile › API Tokens › Create Token › Custom token, with exactly:
   - Account › **Cloudflare Tunnel › Edit**, on your account;
   - Zone › **DNS › Edit**, on the `tetrix.pro` zone only.
   
   Nothing else: the token makes tunnels and CNAME records and reads tunnel tokens. (If you deploy from a CI machine instead of `wrangler login`, that machine's token needs Workers Scripts › Edit and D1 › Edit as well; keep it apart from this one.)
4. **Find the ids:** the account id and the zone id are on the zone's Overview page in the dashboard, right column.
5. **Create the database:** `pnpm exec wrangler d1 create oby-control`, then paste the `database_id` it prints into `wrangler.jsonc`.
6. **Run the migrations:** `pnpm migrate:remote` (`wrangler d1 migrations apply oby-control --remote`).
7. **Set the secrets**, one at a time; each asks for the value on stdin, so nothing lands in your shell history:
   ```sh
   pnpm exec wrangler secret put CF_API_TOKEN
   pnpm exec wrangler secret put CF_ACCOUNT_ID
   pnpm exec wrangler secret put CF_ZONE_ID
   pnpm exec wrangler secret put RESEND_API_KEY
   ```
   The sign-in emails go through [Resend](https://resend.com): add and verify `tetrix.pro` there (its DNS records go in the same zone), make an API key, and check `EMAIL_FROM` in `wrangler.jsonc` is an address on that domain.
8. **Deploy:** `pnpm deploy`. The route in `wrangler.jsonc` is a custom domain, so Cloudflare adds the `oby-control.tetrix.pro` record and certificate itself.
9. **Check it:** `curl https://oby-control.tetrix.pro/v1/health` answers `{"ok":true}`.

To rotate the API token later, make a new one with the same scopes, `wrangler secret put CF_API_TOKEN` again, and delete the old one in the dashboard. Nothing on the Macs changes.

## Working on the Worker locally

```sh
cd cloud/control-plane
cp .dev.vars.example .dev.vars    # placeholders; fill in what you have
pnpm migrate:local                # the D1 database in .wrangler/
pnpm dev                          # http://localhost:8787
pnpm test                         # vitest, inside workerd (Miniflare), with the Cloudflare API mocked
```

With `DEV_ECHO_OTP=true` in `.dev.vars`, asking for a code answers with the code (`devCode`), so sign-in works with no email sender. Never set it on the deployed Worker. Without the three `CF_*` secrets, sign-in and installations still work; asking for an endpoint answers 503 saying what's missing.

### The API

Every answer is JSON; an error is `{"error": "one line to show"}` with its status. Bearer tokens: `oby_session_…` is a user's session (90 days), `oby_install_…` an installation's credential.

| Call | Who | What |
| --- | --- | --- |
| `POST /v1/auth/otp/request` `{email}` | anyone | Emails a six-digit code (ten minutes, five tries). 5 per email per 15 minutes, 20 per address per hour. |
| `POST /v1/auth/otp/verify` `{email, code}` | anyone | `{token, user, expiresAt}`: the session, shown once. |
| `GET /v1/me`, `POST /v1/auth/signout` | session | Who's signed in; ends the session. |
| `GET /v1/installations` | session | The user's installations, each with its `endpoint` (hostname) or null. |
| `POST /v1/installations` `{clientId, name, platform}` | session | Registers a Mac (201) or, the same `clientId` again, keeps its installation (200); either way `{installation, credential}` with a fresh credential, the one before revoked. 10 an hour, 20 per account. |
| `POST /v1/installations/{id}/credential` | session | A fresh credential; the one before stops working. |
| `DELETE /v1/installations/{id}` | session | Tears the tunnel and record down at Cloudflare, revokes the credential and the session the Mac registered with. Another user's installation is a 404. |
| `GET /v1/installations/self` | credential | This installation, with its endpoint. |
| `POST /v1/installations/self/endpoint` | credential | Makes the tunnel (`config_src: cloudflare`), its ingress (the hostname to the gateway, then `http_status:404`) and the proxied CNAME to `<tunnel>.cfargotunnel.com`; `{endpoint: {hostname, tunnelId, createdAt}}`. Again later: the same one. If the record fails, the tunnel is removed and the call fails. |
| `GET /v1/installations/self/endpoint/token` | credential | `{token, hostname}`: the tunnel's run token, read from Cloudflare each time, never stored. |
| `DELETE /v1/installations/self/endpoint` | credential | Removes the record and the tunnel. |

## On the Mac

- **`cloudflared` ships inside Oby.app** (`Contents/MacOS/cloudflared`): the "Bundle cloudflared" build phase runs `apps/mac/app/Tools/bundle-cloudflared.sh`, which downloads the pinned release once into `~/Library/Caches/com.deskree.oby/cloudflared/`, checks its SHA-256, makes a universal binary and signs it with the app's identity and the hardened runtime, so it's notarized with the app. `apps/mac/tests/RemoteAccessTests.swift` checks the bundled binary is there, signed, universal, and the pinned version. To move to a newer cloudflared, change `VERSION` and the two checksums in the script.
- **Settings › Remote access** (`apps/mac/app/RemoteAccess.swift`, `apps/mac/app/Settings.swift`): type your email, then the code; then "Reach this Mac from anywhere". Oby registers this Mac (a stable client id it makes once; the name from Sharing settings), asks for its endpoint, puts the tunnel token in the keychain, and runs `cloudflared tunnel run` as its child with the token in `TUNNEL_TOKEN`, never in the arguments, so the process list doesn't show it. The hostname and status show there. The tunnel restarts by itself when it drops, waiting a little longer each time, and ends when Oby quits; with Oby opening at login, it's up whenever the Mac is.
- **Off** stops the tunnel and keeps the hostname; **Forget This Mac** removes the installation (its tunnel and hostname go, and the hostname never answers again) and signs out. A session lasts 90 days; after that, "Sign in again" shows and the email field is back.
- **What's kept where:** the keychain, service `com.deskree.oby.remote`: `control-plane-session`, `installation-credential`, `tunnel-token`. The defaults: `remote.email`, `remote.hostname`, `remote.installation`, `remote.clientID`, `remote.enabled`. The user's vault (Settings › Vault) isn't involved.

## On the iPhone

Settings › Your Mac (`apps/ios/app/ConnectScreen.swift`) links the Mac: its name (as Sharing settings call it) and its hostname. Pairing by QR code comes with the gateway (#284) and carries the same two fields (`MacLink`'s JSON, `{"name", "hostname"}`); until then they're typed. Linked, the iPhone talks to the Mac instead of the runner's address:

- **At home,** it looks for the Mac's gateway with Bonjour (`_oby._tcp`, the service named after the Mac), resolves its address and talks to it on the local network. `apps/ios/app/Info.plist` declares the service and the local-network use.
- **Away,** it goes through the tunnel, `https://<hostname>`.

The switch between the two keeps the conversation: only the connection is made anew (`apps/shared/RemoteRoute.swift` picks the route; `Phone.base` is where the calls go). Unlink, and the iPhone is back on the runner.

## Limits and what's next

- The gateway on `127.0.0.1:8810` is #284: until it exists, the tunnel is up and routes to nothing (Cloudflare answers 502). Device tokens and the route allowlist are its job; the control plane only makes the tunnel.
- The Mac staying awake is #286. Pushes still use the runner's direct APNs path; a control-plane relay remains deferred until its Worker API, D1 token storage, and APNs secret configuration are designed and deployed. End-to-end encryption between the devices and the Mac is #287; the runner on the Mac is #283 and #288.
- Sign in with Apple waits for the Deskree team (#282).
