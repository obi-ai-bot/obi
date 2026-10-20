# Remote access: reach your Mac from anywhere (#285)

Outside the home network, the iPhone reaches the Mac with no port forwarding, no VPN app and no Tailscale account: an Oby control plane on Cloudflare gives each installation its own Cloudflare Tunnel, the Mac runs `cloudflared` outbound as a child of Oby, and the iPhone talks HTTPS to an opaque hostname. The pattern is OpenMausBot's `cloudflare/control-plane`.

- **The control plane** is a Worker with a D1 database, `cloud/control-plane/`, at `oby-control.tetrix.pro`. Turning remote access on the first time signs in with Apple, the gate against abuse (the owner's decision of 2026-10-20): no name and no email are asked for, and the control plane keeps only Apple's `sub` for the account. Each Mac makes a P-256 key, registers an installation by its public key with that sign-in, and signs every call with it. The iPhone only scans the Mac's QR code.
- **Sign in with Apple is on the web, not native:** Apple's [supported capabilities for macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos) lists Sign in with Apple for App Store apps only, not Developer ID, and a Developer ID profile never carries `com.apple.developer.applesignin`. So the Mac app has no entitlement for it: it opens Apple's sign-in page in the system's web sheet (`ASWebAuthenticationSession`, sharing Safari's cookies, so an Apple Account already signed in, or a passkey, makes it quick), Apple posts the identity token to the control plane, and the control plane checks it (Apple's keys, `iss`, `aud` = the Services ID, `exp`, `iat`, the single-use nonce it handed out for that Mac's key, `sub`). The token never passes through the Mac. The control plane sends the browser back to `oby-signin://done` with the state and a one-time code (kept only as a hash), and the Mac registers with both: someone who starts a sign-in on their own Mac and gets another person to finish it at Apple has the state, never the code, so they can't take that person's account.
- **Abuse control.** The gate is the Apple Account; the rest bounds what one account, one network, or everyone can cost:
  - **per Apple Account:** at most 5 Macs, 5 live endpoints, 10 Macs set up a day, and 10 endpoints made a day. An account with 5 Macs that signs in on a sixth loses the one it used longest ago (its tunnel too), and the new Mac's Settings says which: a fresh sign-in is the account's owner, so the owner of a stolen account takes its places back without the other Macs' keys. Counting, then inserting, isn't atomic, so two registrations at once can leave an account one Mac over; the daily limits bound it. An installation without an account is refused, never spared the limits;
  - the hostnames live on **a domain of their own** (`DEVICE_DOMAIN`), never under the product's `tetrix.pro`, so a phishing page on one can't get `tetrix.pro` flagged by Safe Browsing or set cookies on it;
  - **a backstop per network,** generous so offices, carrier-grade NAT and mobile networks aren't held back: 30 sign-ins started and 20 Macs set up an hour per client (an IPv6 /64 is one), 100 Macs set up an hour per network (an IPv4 /24 or IPv6 /48), 30 endpoints made an hour and 100 a day per network, and at most 20 endpoints not yet connected per network (connected ones don't count);
  - **live endpoints:** at most `MAX_ENDPOINTS` (500, under the account's tunnel limit). The cap is read before the Cloudflare calls and the row written after them, so calls in flight at once can overshoot it by a few. Past 80% of the cap, every new endpoint logs `endpoints: N of M alive, past 80% of MAX_ENDPOINTS` (Workers Logs): set an alert on that line;
  - **a hostname is kept by keeping the tunnel connected:** an endpoint whose tunnel never connected within an hour is reclaimed, and so is one whose tunnel has been down for 72 hours; the installation stays either way, so a Mac behind a firewall that stops cloudflared keeps its sign-in (its check-in makes a new endpoint, up to 3 a day). Cloudflare sets `conns_inactive_at` even for a tunnel that never connected, so "never connected" means no `conns_active_at`. So a Mac that's off, asleep, or has remote access off for three days gives its hostname up; when it turns on again it gets a new one, and the iPhone pairs again;
  - **Cloudflare calls,** which share the account's one API token: each installation makes or removes its tunnel at most 5 times an hour, makes one at most 3 times a day, and reads its token at most 4 times an hour; over everyone, 300 new tunnels and 120 removals an hour, and 300 token reads every 5 minutes. Draining the 300 an hour takes 30 Apple Accounts;
  - **the sweep,** every minute: spent nonces, sign-ins and day-old rate-limit windows go; installations that made no tunnel in a day go, all at once; installations no Mac signed a call for in 30 days go with their tunnels, 8 a run; and 8 endpoints, never-checked first (oldest made first), then the longest ago checked, are asked about at Cloudflare (480 an hour, more than the 300 new tunnels an hour, and all 500 checked about once an hour). That's at most 40 Cloudflare calls a run, under the free plan's 50.
  
  **No proof of work any more.** With an Apple Account as the gate, a proof of work added a second or two to every new Mac and stopped little: it costs a GPU almost nothing, while each account is limited above and new Apple Accounts need a phone number. **What's left:** someone with many Apple Accounts and networks could still fill the endpoint cap, by keeping 500 tunnels connected. Apple's server-to-server notifications (an account deleted, or consent revoked for Oby) aren't handled yet: such an account's Macs stay until they're forgotten, idle for 30 days, or their tunnel is down for 3 days. They'd need the notification endpoint registered for the App ID in Certificates, Identifiers & Profiles, and a route that checks Apple's signed payload with the same keys.
- **Hostnames** are first-level names under the device domain, `oby-<20 opaque characters>.<DEVICE_DOMAIN>`, so Cloudflare's free Universal SSL covers them. Never a second-level name: that would need Advanced Certificate Manager. The device domain is a registrable domain of its own: the Worker compares registrable domains (eTLD+1, from a short list of two-level suffixes such as `co.uk`, not the whole Public Suffix List) and refuses one that shares `PRODUCT_DOMAIN`'s, fails closed when `PRODUCT_DOMAIN` is empty, and checks once that `CF_ZONE_ID`'s zone is `DEVICE_DOMAIN`. `MAX_ENDPOINTS` must be a whole number, or the Worker refuses to make endpoints until it is; add it to the [Public Suffix List](https://publicsuffix.org/submit/) so browsers treat each hostname as its own site. The Worker never touches records it didn't make.
- **The tunnel** routes one hostname to the gateway on the Mac (`http://127.0.0.1:8810`, #284) and nothing else: the last ingress rule is `http_status:404`.
- **Apple's keys** are kept for a day and fetched again for an unknown `kid` at most once a minute. A fetch that fails or answers something other than a list of RSA keys changes nothing: the kept keys stay, and the next try waits 1, 2, 4… minutes, up to an hour, while Apple is down.
- **Secrets** live only in the Worker's secrets (the Cloudflare API token, the account and zone ids) and in the Mac's keychain (the installation's key, the tunnel's token). Sign in with Apple needs no secret: the control plane only checks Apple's identity token with Apple's public keys, and never exchanges the authorization code. D1 keeps public keys, Apple's `sub` for each account, the hash of each sign-in's nonce, and spent nonces; nothing secret is logged.

## One-time setup on Cloudflare (the user's step)

Everything below runs on your Mac, in `cloud/control-plane/`. Deploying is never an agent's job.

0. **Set up Sign in with Apple** (Certificates, Identifiers & Profiles, on Deskree's team `3UV9W5SV7W`):
   - **Identifiers › the App ID `com.deskree.oby`:** tick **Sign in with Apple** and save (as a primary App ID). Nothing else changes for the Mac app: it has no entitlement for it, so its Developer ID signing and profile stay as they are.
   - **Identifiers › + › Services IDs:** a Services ID `com.deskree.oby.signin` ("Oby remote access"); tick **Sign in with Apple** › Configure: primary App ID `com.deskree.oby`; Domains `oby-control.tetrix.pro`; Return URLs `https://oby-control.tetrix.pro/v1/auth/apple/callback`. Save. No file goes on the server and no key is needed (the control plane never exchanges the authorization code).
   - `APPLE_CLIENT_ID` and `APPLE_REDIRECT_URI` in `wrangler.jsonc` are that Services ID and that return URL; they aren't secrets.
1. **Register the device domain:** a new domain for the Macs' hostnames alone (not `tetrix.pro` or a name under it), added to Cloudflare as its own zone. Set `DEVICE_DOMAIN` in `wrangler.jsonc` to it; until then the Worker makes no endpoint. Then submit it to the [Public Suffix List](https://publicsuffix.org/submit/) (its private section), so each `oby-…` hostname is its own site to browsers.
2. **Install the tools:** `pnpm install` (npm works too). `pnpm exec vitest run --config worker.vitest.ts` runs the Worker's tests in Miniflare, `pnpm check` type-checks.
3. **Sign wrangler in:** `pnpm exec wrangler login`. This OAuth login is what deploys the Worker and its D1 database; it covers Workers Scripts and D1 on your account.
4. **Create the API token the Worker uses at run time**, in the Cloudflare dashboard, My Profile › API Tokens › Create Token › Custom token, with exactly:
   - Account › **Cloudflare Tunnel › Edit**, on your account;
   - Zone › **DNS › Edit**, on the device domain's zone only.
   
   Nothing else: the token makes tunnels and CNAME records and reads tunnel tokens. (If you deploy from a CI machine instead of `wrangler login`, that machine's token needs Workers Scripts › Edit and D1 › Edit as well; keep it apart from this one.)
5. **Find the ids:** the account id and the device domain's zone id are on that zone's Overview page in the dashboard, right column. `CF_ZONE_ID` is that zone, never `tetrix.pro`'s.
6. **Create the database:** `pnpm exec wrangler d1 create oby-control`, then paste the `database_id` it prints into `wrangler.jsonc`.
7. **Run the migrations:** `pnpm migrate:remote` (`wrangler d1 migrations apply oby-control --remote`).
8. **Set the secrets**, one at a time; each asks for the value on stdin, so nothing lands in your shell history:
   ```sh
   pnpm exec wrangler secret put CF_API_TOKEN
   pnpm exec wrangler secret put CF_ACCOUNT_ID
   pnpm exec wrangler secret put CF_ZONE_ID
   ```
9. **Deploy:** `pnpm deploy`. The route in `wrangler.jsonc` is a custom domain, so Cloudflare adds the `oby-control.tetrix.pro` record and certificate itself, and the cron (`triggers` in `wrangler.jsonc`, every minute) starts sweeping. Then, in Workers Logs, alert on the line `past 80% of MAX_ENDPOINTS`.
10. **Check it:** `curl https://oby-control.tetrix.pro/v1/health` answers `{"ok":true}`.

To rotate the API token later, make a new one with the same scopes, `wrangler secret put CF_API_TOKEN` again, and delete the old one in the dashboard. Nothing on the Macs changes.

## Working on the Worker locally

```sh
cd cloud/control-plane
cp .dev.vars.example .dev.vars    # placeholders; fill in what you have
pnpm migrate:local                # the D1 database in .wrangler/
pnpm dev                          # http://localhost:8787
pnpm exec vitest run --config worker.vitest.ts   # inside workerd (Miniflare), with the Cloudflare API mocked
```

Without the three `CF_*` secrets, registering still works; asking for an endpoint answers 503 saying what's missing. Signing in needs Apple, so locally a sign-in can't finish; the tests use a fake Apple (`test/helpers.ts`, `FakeApple`) that signs tokens with its own key. `wrangler dev --test-scheduled` runs the sweep at `/__scheduled`.

### The API

Every answer is JSON; an error is `{"error": "one line to show"}` with its status. There are no bearer tokens: every call but `/v1/health` is signed by the Mac's key, with these headers:

- `Oby-Key`: the public key, an uncompressed P-256 point (X9.63, 65 bytes), base64url with no padding. One spelling per key.
- `Oby-Timestamp`: Unix seconds; refused when more than 5 minutes from the Worker's clock (401, "This Mac's clock is off…").
- `Oby-Nonce`: 16 to 64 letters, digits, `-` or `_`; each one works once per key (401, "That call was made already").
- `Oby-Signature`: ECDSA P-256 with SHA-256, r‖s (64 bytes), base64url, over `oby-control-v1`, the method, the path, the timestamp and the nonce, each followed by a newline, then the body's bytes.

A bad or missing signature is 401; a good signature from a key with no installation is 410 ("This Mac isn't registered"), apart from a 404 for no such route, and tells the Mac to register again. A nonce is spent only once the call's installation is found (or its sign-in, or the sign-in it starts), so keys with no installation leave nothing in D1 when they call anything else.

| Call | What |
| --- | --- |
| `POST /v1/auth/apple/start` | Signed. Starts a sign-in for the signing key: `{url, state}` (201), `url` being Apple's authorization page with `client_id` (the Services ID), `redirect_uri`, `response_type=code id_token`, `response_mode=form_post`, the `state` and a fresh `nonce`, and no `scope`, so Apple sends no name or email. The state works for 10 minutes; D1 keeps the nonce's SHA-256 only. 30 an hour per client. |
| `POST /v1/auth/apple/callback` | Apple's form post (not signed: Apple sends it). Checks the identity token against the sign-in its `state` names, binds the account's `sub` to it with a one-time code, and sends the browser to `oby-signin://done?state=…&code=…`, or `oby-signin://failed?state=…` when the token doesn't check out, the user cancelled, the sign-in expired or was used. 60 an hour per client. |
| `POST /v1/installations` `{name, platform, signIn, signInCode}` | Registers the signing key (201) or, the same key again, keeps its installation and hostname (200, no sign-in needed); `{installation, evicted?}`. A new key needs `signIn` and `signInCode`: the state of a sign-in that key started and the code its sheet came back with, used once (403 otherwise, "Sign in with Apple first."). The installation belongs to that account: 5 Macs an account (a sixth takes the place of the one used longest ago, named in `evicted`), 10 set up a day; 20 an hour per client and 100 per network. |
| `GET /v1/installations/self` | This installation, with its endpoint. Like every signed call, it keeps the installation from being swept as idle. |
| `DELETE /v1/installations/self` | Forget This Mac: tears the tunnel and record down at Cloudflare, then removes the installation. If Cloudflare refuses, nothing is removed and the call fails. |
| `POST /v1/installations/self/endpoint` | Refuses (503) without a proper `DEVICE_DOMAIN` or at `MAX_ENDPOINTS`, (409) when the account has 5 live endpoints, and (429) with 20 unconnected endpoints from this network already; 5 tunnel changes an hour and 3 creations a day per installation, 10 a day per account, 30 an hour and 100 a day per network, 300 new tunnels an hour over everyone. Makes the tunnel (`config_src: cloudflare`), its ingress (the hostname to the gateway, then `http_status:404`) and the proxied CNAME to `<tunnel>.cfargotunnel.com`; `{endpoint: {hostname, tunnelId, createdAt}}`. Again later: the same one. If the record fails, the tunnel is removed and the call fails. |
| `GET /v1/installations/self/endpoint/token` | `{token, hostname}`: the tunnel's run token, read from Cloudflare each time, never stored. 4 an hour per installation, 300 every 5 minutes over everyone. |
| `DELETE /v1/installations/self/endpoint` | Removes the record and the tunnel. Counted with the installation's tunnel changes, and 120 removals an hour over everyone (Forget This Mac too). |

The cron (`sweep` in `src/app.ts`, every minute) deletes spent nonces and day-old rate-limit windows, removes installations that made no tunnel in 24 hours in one statement, removes up to 8 installations idle for 30 days, tunnels and records first, and asks about 8 endpoints (never-checked first): one whose tunnel never connected within an hour, or has been down for 72 hours, is reclaimed (the installation stays, and isn't swept as never used: it made an endpoint once); one that Cloudflare refuses is tried again next time.

## On the Mac

- **`cloudflared` ships inside Oby.app** (`Contents/MacOS/cloudflared`): the "Bundle cloudflared" build phase runs `apps/mac/app/Tools/bundle-cloudflared.sh`, which downloads the pinned release once into `~/Library/Caches/com.deskree.oby/cloudflared/`, checks its SHA-256, makes a universal binary and signs it with the app's identity and the hardened runtime, so it's notarized with the app. `apps/mac/tests/RemoteAccessTests.swift` checks the bundled binary is there, signed, universal, and the pinned version. To move to a newer cloudflared, change `VERSION` and the two checksums in the script.
- **Settings › Remote access** (`apps/mac/app/RemoteAccess.swift`, `apps/mac/app/Settings.swift`): "Reach this Mac from anywhere". The first time, it signs in with Apple in the system's web sheet (no name, no email), then registers. Oby makes this Mac's key: in the Secure Enclave when the Mac has one (the keychain keeps only the enclave's wrapped key, which no other Mac can use; if the enclave can't make one, that's an error, never a quiet step down), else a software P-256 key in the keychain, on Macs with no Secure Enclave. If the control plane doesn't know the key (410), it starts a sign-in, shows Apple's page (`AppleWebSignIn`), checks the sheet came back to `oby-signin://done` with the same state and a code, and registers this Mac by that key with it (the name from Sharing settings); a key it knows skips all that. Then it asks for its endpoint, puts the tunnel token in the keychain, and runs `cloudflared tunnel run` as its child with the token in `TUNNEL_TOKEN`, never in the arguments, so the process list doesn't show it. The hostname and status show there. The tunnel restarts by itself when it drops, waiting a little longer each time, and ends when Oby quits; with Oby opening at login, it's up whenever the Mac is.
- **Off** stops the tunnel and keeps the hostname for 3 days (Settings says so: after 3 days off, asleep or offline, the Mac gets a new hostname when it's back, and the iPhone pairs again); **Forget This Mac** removes the installation with a call signed by the key (its tunnel and hostname go, and the hostname never answers again), then deletes the key and the token here.
- **Checking in:** with a hostname, on or off, Oby makes a signed call at launch and once a day, so the installation isn't swept. When the tunnel was reclaimed (the check-in sees no endpoint, or another hostname), Oby makes a new endpoint at once if remote access is on, with no sign-in: the installation is still there; the iPhone pairs again for the new hostname. A Mac Oby hasn't run on for 30 days loses its installation: at its next check-in (410) remote access turns off and Settings says to turn it on again, which signs in with Apple. A check-in never opens a sign-in sheet by itself.
- **What's kept where:** the keychain, service `com.deskree.oby.remote`: `installation-key` (`se:` and the enclave's wrapped key, or `sw:` and a software key), `tunnel-token`. The defaults: `remote.hostname`, `remote.enabled`. The user's vault (Settings › Vault) isn't involved. At launch Oby deletes what the email sign-in left (the keychain's `control-plane-session` and `installation-credential`, the defaults `remote.email`, `remote.installation`, `remote.clientID`).

## On the iPhone

Settings › Your Mac (`apps/ios/app/ConnectScreen.swift`) links the Mac: its name (as Sharing settings call it) and its hostname. Pairing by QR code comes with the gateway (#284) and carries the same two fields (`MacLink`'s JSON, `{"name", "hostname"}`); until then they're typed. Linked, the iPhone talks to the Mac instead of the runner's address:

- **At home,** it looks for the Mac's gateway with Bonjour (`_oby._tcp`, the service named after the Mac), resolves its address and talks to it on the local network. `apps/ios/app/Info.plist` declares the service and the local-network use.
- **Away,** it goes through the tunnel, `https://<hostname>`.

The switch between the two keeps the conversation: only the connection is made anew (`apps/shared/RemoteRoute.swift` picks the route; `Phone.base` is where the calls go). Unlink, and the iPhone is back on the runner.

## Limits and what's next

- The gateway on `127.0.0.1:8810` is #284: until it exists, the tunnel is up and routes to nothing (Cloudflare answers 502). Device tokens and the route allowlist are its job; the control plane only makes the tunnel.
- The Mac staying awake is #286. Pushes still use the runner's direct APNs path; a control-plane relay remains deferred until its Worker API, D1 token storage, and APNs secret configuration are designed and deployed. End-to-end encryption between the devices and the Mac is #287; the runner on the Mac is #283 and #288.
- Sign in with Apple (#282), later and optional, would tie installations to a person so they can manage several Macs; remote access doesn't need it.
- App Attest, or another check that a key belongs to a real Oby, would sit on top of the key (see "Abuse control" above).
