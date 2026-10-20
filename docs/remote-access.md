# Remote access: reach your Mac from anywhere (#285)

Outside the home network, the iPhone reaches the Mac with no port forwarding, no VPN app and no Tailscale account: an Oby control plane on Cloudflare gives each installation its own Cloudflare Tunnel, the Mac runs `cloudflared` outbound as a child of Oby, and the iPhone talks HTTPS to an opaque hostname. The pattern is OpenMausBot's `cloudflare/control-plane`.

- **The control plane** is a Worker with a D1 database, `cloud/control-plane/`, at `oby-control.tetrix.pro`. There's no account and no sign-in (the owner's decision of 2026-10-20): each Mac makes a P-256 key, registers an installation by its public key, and signs every call with it, so the iPhone only scans the Mac's QR code. Sign in with Apple (#282) may come later as an optional way to manage several Macs.
- **Abuse control.** Anyone can run Oby, so anyone can get a hostname that serves their own machine; what that can cost is bounded, not prevented:
  - the hostnames live on **a domain of their own** (`DEVICE_DOMAIN`), never under the product's `tetrix.pro`, so a phishing page on one can't get `tetrix.pro` flagged by Safe Browsing or set cookies on it;
  - a new Mac pays a **proof of work** bound to its key and the time: 22 leading zero bits of SHA-256 (a second or two on a Mac), 2 more past half of `MAX_ENDPOINTS`, 4 more past 80%, and 4 more while new Macs are past 1000 an hour over everyone; a refusal says how many bits it needs (`workBits`), and the Mac works it out once more. The total never goes past 30 bits (`MAX_WORK_BITS`, the Mac's `mostWorkBits`: a few minutes of work), so 22 plus every extra is exactly what a Mac does;
  - **new Macs:** 5 an hour per client (an IPv6 /64 is one) and 20 an hour per network (an IPv4 /24 or an IPv6 /48); one installation per key; over everyone, past 1000 an hour the work gets harder instead of anyone being refused;
  - **live endpoints:** at most `MAX_ENDPOINTS` (500, under the account's tunnel limit), and at most 3 not yet connected from one network (/24 or /48); connected ones don't count, so offices, carrier-grade NAT and mobile networks can have many. The cap is read before the Cloudflare calls and the row written after them, so calls in flight at once can overshoot it by a few. Past 80% of the cap, every new endpoint logs `endpoints: N of M alive, past 80% of MAX_ENDPOINTS` (Workers Logs): set an alert on that line;
  - **a hostname is kept by keeping the tunnel connected:** an endpoint whose tunnel never connected within an hour goes with its installation (so trying again pays the work again), and one whose tunnel has been down for 72 hours is reclaimed (the installation stays). Cloudflare sets `conns_inactive_at` even for a tunnel that never connected, so "never connected" means no `conns_active_at`. So a Mac that's off, asleep, or has remote access off for three days gives its hostname up; when it turns on again it gets a new one, and the iPhone pairs again;
  - **Cloudflare calls,** which share the account's one API token: each installation makes or removes its tunnel at most 5 times an hour, makes one at most 3 times a day, and reads its token at most 4 times an hour; each network (/24 or /48) makes at most 5 tunnels an hour and 10 a day, so draining the 300 new tunnels an hour over everyone takes 60 networks; over everyone, also 120 removals an hour and 300 token reads every 5 minutes;
  - **the sweep,** every minute: installations that made no tunnel in a day go, all at once; installations no Mac signed a call for in 30 days go with their tunnels, 8 a run; and 8 endpoints, never-checked first (oldest made first), then the longest ago checked, are asked about at Cloudflare (480 an hour, more than the 300 new tunnels an hour, and all 500 checked about once an hour). That's at most 40 Cloudflare calls a run, under the free plan's 50.
  
  **The real fix is App Attest, and until it's there one determined attacker can lock real Macs out.** Proof of work costs a GPU little; keeping endpoints means keeping cloudflared connected, and each network makes at most 10 tunnels a day, so filling 500 takes about 50 networks and 500 running tunnels, or draining the 300-an-hour limit takes 60 networks, but it can be done. App Attest (or DeviceCheck) would let only a real Oby on a real Apple device register. It's deferred because checking an App Attest attestation in the Worker means parsing CBOR and Apple's certificate chain, and the Developer ID build needs the App Attest entitlement and a provisioning profile; DeviceCheck needs a DeviceCheck key from the Apple Developer account in the Worker's secrets and a call to Apple per registration. Either sits on top of the key and replaces the proof of work when the owner sets it up.
- **Hostnames** are first-level names under the device domain, `oby-<20 opaque characters>.<DEVICE_DOMAIN>`, so Cloudflare's free Universal SSL covers them. Never a second-level name: that would need Advanced Certificate Manager. The device domain is a registrable domain of its own: the Worker compares registrable domains (eTLD+1, from a short list of two-level suffixes such as `co.uk`, not the whole Public Suffix List) and refuses one that shares `PRODUCT_DOMAIN`'s, fails closed when `PRODUCT_DOMAIN` is empty, and checks once that `CF_ZONE_ID`'s zone is `DEVICE_DOMAIN`. `MAX_ENDPOINTS` and `REGISTRATION_WORK_BITS` must be whole numbers, or the Worker refuses to make anything until they are; add it to the [Public Suffix List](https://publicsuffix.org/submit/) so browsers treat each hostname as its own site. The Worker never touches records it didn't make.
- **The tunnel** routes one hostname to the gateway on the Mac (`http://127.0.0.1:8810`, #284) and nothing else: the last ingress rule is `http_status:404`.
- **Secrets** live only in the Worker's secrets (the Cloudflare API token, the account and zone ids) and in the Mac's keychain (the installation's key, the tunnel's token). D1 keeps public keys and spent nonces; nothing secret is logged.

## One-time setup on Cloudflare (the user's step)

Everything below runs on your Mac, in `cloud/control-plane/`. Deploying is never an agent's job.

0. **Register the device domain:** a new domain for the Macs' hostnames alone (not `tetrix.pro` or a name under it), added to Cloudflare as its own zone. Set `DEVICE_DOMAIN` in `wrangler.jsonc` to it; until then the Worker makes no endpoint. Then submit it to the [Public Suffix List](https://publicsuffix.org/submit/) (its private section), so each `oby-…` hostname is its own site to browsers.
1. **Install the tools:** `pnpm install` (npm works too). `pnpm exec vitest run --config worker.vitest.ts` runs the Worker's tests in Miniflare, `pnpm check` type-checks.
2. **Sign wrangler in:** `pnpm exec wrangler login`. This OAuth login is what deploys the Worker and its D1 database; it covers Workers Scripts and D1 on your account.
3. **Create the API token the Worker uses at run time**, in the Cloudflare dashboard, My Profile › API Tokens › Create Token › Custom token, with exactly:
   - Account › **Cloudflare Tunnel › Edit**, on your account;
   - Zone › **DNS › Edit**, on the device domain's zone only.
   
   Nothing else: the token makes tunnels and CNAME records and reads tunnel tokens. (If you deploy from a CI machine instead of `wrangler login`, that machine's token needs Workers Scripts › Edit and D1 › Edit as well; keep it apart from this one.)
4. **Find the ids:** the account id and the device domain's zone id are on that zone's Overview page in the dashboard, right column. `CF_ZONE_ID` is that zone, never `tetrix.pro`'s.
5. **Create the database:** `pnpm exec wrangler d1 create oby-control`, then paste the `database_id` it prints into `wrangler.jsonc`.
6. **Run the migrations:** `pnpm migrate:remote` (`wrangler d1 migrations apply oby-control --remote`).
7. **Set the secrets**, one at a time; each asks for the value on stdin, so nothing lands in your shell history:
   ```sh
   pnpm exec wrangler secret put CF_API_TOKEN
   pnpm exec wrangler secret put CF_ACCOUNT_ID
   pnpm exec wrangler secret put CF_ZONE_ID
   ```
8. **Deploy:** `pnpm deploy`. The route in `wrangler.jsonc` is a custom domain, so Cloudflare adds the `oby-control.tetrix.pro` record and certificate itself, and the cron (`triggers` in `wrangler.jsonc`, every minute) starts sweeping. Then, in Workers Logs, alert on the line `past 80% of MAX_ENDPOINTS`.
9. **Check it:** `curl https://oby-control.tetrix.pro/v1/health` answers `{"ok":true}`.

To rotate the API token later, make a new one with the same scopes, `wrangler secret put CF_API_TOKEN` again, and delete the old one in the dashboard. Nothing on the Macs changes.

## Working on the Worker locally

```sh
cd cloud/control-plane
cp .dev.vars.example .dev.vars    # placeholders; fill in what you have
pnpm migrate:local                # the D1 database in .wrangler/
pnpm dev                          # http://localhost:8787
pnpm exec vitest run --config worker.vitest.ts   # inside workerd (Miniflare), with the Cloudflare API mocked
```

Without the three `CF_*` secrets, registering still works; asking for an endpoint answers 503 saying what's missing. `wrangler dev --test-scheduled` runs the sweep at `/__scheduled`.

### The API

Every answer is JSON; an error is `{"error": "one line to show"}` with its status. There are no bearer tokens: every call but `/v1/health` is signed by the Mac's key, with these headers:

- `Oby-Key`: the public key, an uncompressed P-256 point (X9.63, 65 bytes), base64url with no padding. One spelling per key.
- `Oby-Timestamp`: Unix seconds; refused when more than 5 minutes from the Worker's clock (401, "This Mac's clock is off…").
- `Oby-Nonce`: 16 to 64 letters, digits, `-` or `_`; each one works once per key (401, "That call was made already").
- `Oby-Signature`: ECDSA P-256 with SHA-256, r‖s (64 bytes), base64url, over `oby-control-v1`, the method, the path, the timestamp and the nonce, each followed by a newline, then the body's bytes.

A bad or missing signature is 401; a good signature from a key with no installation is 410 ("This Mac isn't registered"), apart from a 404 for no such route, and tells the Mac to register again. A nonce is spent only once the call's installation is found (or the new Mac's proof of work checks out), so keys with no installation leave nothing in D1.

| Call | What |
| --- | --- |
| `POST /v1/installations` `{name, platform, proofAt, proof}` | Registers the signing key (201) or, the same key again, keeps its installation and hostname (200); `{installation}`. A new key needs `proof`: a decimal answer such that SHA-256 of `oby-register-v1`, the key (as in `Oby-Key`), `proofAt` (Unix seconds, within 5 minutes) and the answer, each followed by a newline but the last, starts with the bits asked for now (403 otherwise, with `workBits`: `REGISTRATION_WORK_BITS`, more near the endpoint cap or past the breaker). New keys only: 5 an hour per client, 20 per network. |
| `GET /v1/installations/self` | This installation, with its endpoint. Like every signed call, it keeps the installation from being swept as idle. |
| `DELETE /v1/installations/self` | Forget This Mac: tears the tunnel and record down at Cloudflare, then removes the installation. If Cloudflare refuses, nothing is removed and the call fails. |
| `POST /v1/installations/self/endpoint` | Refuses (503) without a proper `DEVICE_DOMAIN` or at `MAX_ENDPOINTS`, and (429) with 3 unconnected endpoints from this network already; 5 tunnel changes an hour and 3 creations a day per installation, 5 creations an hour and 10 a day per network, 300 new tunnels an hour over everyone. Makes the tunnel (`config_src: cloudflare`), its ingress (the hostname to the gateway, then `http_status:404`) and the proxied CNAME to `<tunnel>.cfargotunnel.com`; `{endpoint: {hostname, tunnelId, createdAt}}`. Again later: the same one. If the record fails, the tunnel is removed and the call fails. |
| `GET /v1/installations/self/endpoint/token` | `{token, hostname}`: the tunnel's run token, read from Cloudflare each time, never stored. 4 an hour per installation, 300 every 5 minutes over everyone. |
| `DELETE /v1/installations/self/endpoint` | Removes the record and the tunnel. Counted with the installation's tunnel changes, and 120 removals an hour over everyone (Forget This Mac too). |

The cron (`sweep` in `src/app.ts`, every minute) deletes spent nonces and day-old rate-limit windows, removes installations that made no tunnel in 24 hours in one statement, removes up to 8 installations idle for 30 days, tunnels and records first, and asks about 8 endpoints (never-checked first): one whose tunnel never connected within an hour goes with its installation, one down for 72 hours is reclaimed; one that Cloudflare refuses is tried again next time.

## On the Mac

- **`cloudflared` ships inside Oby.app** (`Contents/MacOS/cloudflared`): the "Bundle cloudflared" build phase runs `apps/mac/app/Tools/bundle-cloudflared.sh`, which downloads the pinned release once into `~/Library/Caches/com.deskree.oby/cloudflared/`, checks its SHA-256, makes a universal binary and signs it with the app's identity and the hardened runtime, so it's notarized with the app. `apps/mac/tests/RemoteAccessTests.swift` checks the bundled binary is there, signed, universal, and the pinned version. To move to a newer cloudflared, change `VERSION` and the two checksums in the script.
- **Settings › Remote access** (`apps/mac/app/RemoteAccess.swift`, `apps/mac/app/Settings.swift`): "Reach this Mac from anywhere", with no email and no sign-in. The first time, Oby makes this Mac's key: in the Secure Enclave when the Mac has one (the keychain keeps only the enclave's wrapped key, which no other Mac can use; if the enclave can't make one, that's an error, never a quiet step down), else a software P-256 key in the keychain, on Macs with no Secure Enclave. It works out the proof of work off the main thread (`MacKey.work`), registers this Mac by that key (the name from Sharing settings), asks for its endpoint, puts the tunnel token in the keychain, and runs `cloudflared tunnel run` as its child with the token in `TUNNEL_TOKEN`, never in the arguments, so the process list doesn't show it. The hostname and status show there. The tunnel restarts by itself when it drops, waiting a little longer each time, and ends when Oby quits; with Oby opening at login, it's up whenever the Mac is.
- **Off** stops the tunnel and keeps the hostname for 3 days (Settings says so: after 3 days off, asleep or offline, the Mac gets a new hostname when it's back, and the iPhone pairs again); **Forget This Mac** removes the installation with a call signed by the key (its tunnel and hostname go, and the hostname never answers again), then deletes the key and the token here.
- **Checking in:** with a hostname, on or off, Oby makes a signed call at launch and once a day, so the installation isn't swept. A Mac Oby hasn't run on for 30 days loses its installation; at its next check-in (410) it registers again, gets a new hostname, and, if remote access was on, runs the tunnel again; the iPhone pairs again for the new hostname. The same when its tunnel was reclaimed (the check-in sees no endpoint, or another hostname).
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
