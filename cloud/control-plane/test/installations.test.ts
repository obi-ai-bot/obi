import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { reclaimable, STATUS_BATCH, sweep } from "../src/app";
import { DAY, HOUR, Mac, testApp } from "./helpers";

describe("installations", () => {
  it("registers a Mac by its key, with no account", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const registered = await app.register(mac);
    expect(registered.status).toBe(201);
    expect(registered.body.installation).toMatchObject({ name: "Wellington's MacBook Pro", platform: "macos", endpoint: null });
    // Nothing comes back that would open anything: the key is the Mac's, and only it signs.
    expect(Object.keys(registered.body)).toEqual(["installation"]);

    const self = await app.call(mac, "GET", "/v1/installations/self");
    expect(self.status).toBe(200);
    expect(self.body.installation.id).toBe(registered.body.installation.id);
    // Another Mac's key isn't this installation.
    const other = await Mac.make();
    const refused = await app.call(other, "GET", "/v1/installations/self");
    expect(refused.status).toBe(410);
    expect(refused.body.error).toBe("This Mac isn't registered. Turn remote access on again.");
  });

  it("the same key again keeps its installation", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const first = await app.register(mac);
    const again = await app.register(mac, "Renamed MacBook");
    expect(again.status).toBe(200);
    expect(again.body.installation.id).toBe(first.body.installation.id);
    expect(again.body.installation.name).toBe("Renamed MacBook");
    expect((await env.DB.prepare("SELECT count(*) AS n FROM installations").first<{ n: number }>())?.n).toBe(1);
  });

  it("checks the fields", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const blank = await app.call(mac, "POST", "/v1/installations", { name: "   ", platform: "macos" });
    expect(blank.status).toBe(422);
    expect(blank.body.error).toBe("name is 1 to 64 characters.");
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macOS" })).status).toBe(422);
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac" })).status).toBe(422);
    expect((await app.call(mac, "POST", "/v1/installations", "not json")).status).toBe(400);
    expect((await app.call(mac, "GET", "/v1/nothing")).status).toBe(404);
    expect((await app.raw("GET", "/v1/health")).body).toEqual({ ok: true });
  });

  it("a new Mac signs in with Apple first, with the code its sheet came back with; the same key again doesn't", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const register = (body: Record<string, unknown>, key = mac) => app.call(key, "POST", "/v1/installations", { name: "Mac", platform: "macos", ...body });
    const none = await register({});
    expect(none.status).toBe(403);
    expect(none.body.error).toBe("Sign in with Apple or Google first.");
    // Started but not finished at Apple: no account yet.
    const { state } = await app.startSignIn(mac);
    expect((await register({ signIn: state })).status).toBe(403);
    const signedIn = await app.signIn(mac, "000111.owner");
    expect(signedIn.signInCode).toMatch(/^[A-Za-z0-9_-]{43}$/);
    // Another key can't use this Mac's sign-in, and the state alone, or with another code, isn't enough.
    expect((await register(signedIn, await Mac.make())).status).toBe(403);
    expect((await register({ signIn: signedIn.signIn })).status).toBe(403);
    expect((await register({ signIn: signedIn.signIn, signInCode: "A".repeat(43) })).status).toBe(403);
    const made = await register(signedIn);
    expect(made.status).toBe(201);
    const row = await env.DB.prepare("SELECT user_sub FROM installations").first<{ user_sub: string }>();
    expect(row?.user_sub).toBe("000111.owner");
    // An Apple account is kept by `sub` alone (no domain: Apple gives no email), and the code only as a hash.
    expect((await env.DB.prepare("SELECT * FROM users").all()).results).toEqual([{ sub: "000111.owner", provider: "apple", workspace_domain: null, email_domain: null, limit_domain: null, created_at: "2026-10-12T12:00:00.000Z" }]);
    expect(JSON.stringify((await env.DB.prepare("SELECT * FROM sign_ins").all()).results)).not.toContain(signedIn.signInCode);
    // Registered, the key needs no sign-in again.
    expect((await register({})).status).toBe(200);
  });

  it("someone who gets another person to finish their sign-in can't take that person's account", async () => {
    const app = testApp();
    const attackers = await Mac.make();
    // The attacker's Mac starts a sign-in and sends the victim Apple's real URL.
    const { state, nonce } = await app.startSignIn(attackers);
    // The victim signs in at Apple; Apple posts to the control plane, and the victim's browser gets the code.
    const back = await app.callback({ state, id_token: await app.apple.token(app.claims(nonce, "000999.victim")) });
    const code = new URL(back.headers.get("Location")!).searchParams.get("code");
    expect(code).toBeTruthy();
    // The attacker has the key and the state, never the code.
    const taken = await app.call(attackers, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state });
    expect(taken.status).toBe(403);
    const guessed = await app.call(attackers, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state, signInCode: "x".repeat(43) });
    expect(guessed.status).toBe(403);
    expect(await env.DB.prepare("SELECT * FROM installations").first()).toBeNull();
  });

  it("a sign-in is used once, and only within ten minutes", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const register = (body: Record<string, unknown>) => app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", ...body });
    const stale = await app.signIn(mac);
    app.time.advance(11 * 60_000);
    expect((await register(stale)).status).toBe(403);
    const fresh = await app.signIn(mac);
    expect((await register(fresh)).status).toBe(201);
    await app.call(mac, "DELETE", "/v1/installations/self");
    expect((await register(fresh)).status).toBe(403);
  });
  it("one Apple Account has at most 5 Macs: a new sign-in takes the place of the one used longest ago", async () => {
    const app = testApp();
    const macs: Mac[] = [];
    for (let i = 0; i < 5; i++) {
      macs.push(await Mac.make());
      expect((await app.register(macs[i]!, `Mac ${i}`, { "CF-Connecting-IP": `10.${i}.0.1` }, "000222.busy")).status).toBe(201);
      app.time.advance(60_000);
    }
    await app.call(macs[0]!, "POST", "/v1/installations/self/endpoint", undefined, { "CF-Connecting-IP": "10.0.0.1" });
    // Mac 0 is used again; Mac 1 is now the one used longest ago.
    await app.call(macs[0]!, "GET", "/v1/installations/self");
    // The owner of a stolen account signs in on their own Mac: it takes a place, with no other Mac's key.
    const sixth = await app.register(await Mac.make(), "Mine", { "CF-Connecting-IP": "10.9.0.1" }, "000222.busy");
    expect(sixth.status).toBe(201);
    expect(sixth.body.evicted).toEqual({ name: "Mac 1" });
    expect((await app.call(macs[1]!, "GET", "/v1/installations/self")).status).toBe(410);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM installations WHERE user_sub = '000222.busy'").first<{ n: number }>())?.n).toBe(5);
    // Mac 0's tunnel stays; an evicted Mac's tunnel would go with it.
    expect((await app.call(macs[0]!, "GET", "/v1/installations/self")).body.installation.endpoint).not.toBeNull();
    // Another account isn't touched, and ten a day is the most one account sets up.
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "10.9.0.2" }, "000333.other")).status).toBe(201);
    await app.counted("registrations:account:000333.other", 10);
    const tenth = await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "10.9.0.3" }, "000333.other");
    expect(tenth.status).toBe(429);
    expect(tenth.body.error).toMatch(/^This account set up too many Macs today\./);
  });

  it("when the evicted Mac's teardown fails, nothing changes: not counted, and the sign-in works again", async () => {
    const app = testApp();
    const first = await Mac.make();
    await app.register(first, "First", { "CF-Connecting-IP": "10.0.0.1" }, "000555.full");
    await app.call(first, "POST", "/v1/installations/self/endpoint", undefined, { "CF-Connecting-IP": "10.0.0.1" });
    app.time.advance(60_000);
    for (let i = 1; i < 5; i++) await app.register(await Mac.make(), `Mac ${i}`, { "CF-Connecting-IP": `10.${i}.0.1` }, "000555.full");
    const count = async () => (await env.DB.prepare("SELECT count FROM rate_limits WHERE key = 'registrations:account:000555.full'").first<{ count: number }>())?.count;
    expect(await count()).toBe(5);
    const mac = await Mac.make();
    const from = { "CF-Connecting-IP": "10.9.0.1" };
    const signedIn = await app.signIn(mac, "000555.full", from);
    app.tunnels.refuse.deleteTunnel = "rate limited";
    const failed = await app.call(mac, "POST", "/v1/installations", { name: "New", platform: "macos", ...signedIn }, from);
    expect(failed.status).toBe(502);
    expect(await count()).toBe(5);
    expect((await app.call(first, "GET", "/v1/installations/self")).status).toBe(200);
    app.tunnels.refuse = {};
    const again = await app.call(mac, "POST", "/v1/installations", { name: "New", platform: "macos", ...signedIn }, from);
    expect(again.status).toBe(201);
    expect(again.body.evicted).toEqual({ name: "First" });
    expect(await count()).toBe(6);
  });

  it("evicting a Mac with a tunnel tears the tunnel down", async () => {
    const app = testApp();
    const first = await Mac.make();
    await app.register(first, "First", { "CF-Connecting-IP": "10.0.0.1" }, "000444.full");
    await app.call(first, "POST", "/v1/installations/self/endpoint", undefined, { "CF-Connecting-IP": "10.0.0.1" });
    app.time.advance(60_000);
    for (let i = 1; i < 5; i++) await app.register(await Mac.make(), `Mac ${i}`, { "CF-Connecting-IP": `10.${i}.0.1` }, "000444.full");
    const made = await app.register(await Mac.make(), "New", { "CF-Connecting-IP": "10.9.0.1" }, "000444.full");
    expect(made.body.evicted).toEqual({ name: "First" });
    expect(app.tunnels.tunnels.size).toBe(0);
    expect(app.tunnels.records.size).toBe(0);
  });
  it("limits new Macs per network as a backstop, an IPv6 /64 as one client and a /48 as one network", async () => {
    const app = testApp();
    await app.counted("registrations:address:2001:db8:1:2::/64", 20);
    const sixth = await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:1:2:ffff:ffff:ffff:ffff" });
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toMatch(/^Too many Macs were set up from this network lately\. Try again in \d+ minutes?\.$/);
    expect(sixth.headers.get("Retry-After")).not.toBeNull();
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:1:3::1" })).status).toBe(201);
    await app.counted("registrations:network:2001:db8:1::/48", 100);
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:1:4::1" })).status).toBe(429);
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:2::1" })).status).toBe(201);
  });

  it("Forget This Mac removes the installation, its tunnel and its hostname", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    await app.call(mac, "POST", "/v1/installations/self/endpoint");
    const forgotten = await app.call(mac, "DELETE", "/v1/installations/self");
    expect(forgotten.status).toBe(204);
    expect(app.tunnels.ops().slice(3)).toEqual(["deleteDNSRecord", "deleteTunnel"]);
    expect(app.tunnels.tunnels.size).toBe(0);
    expect(app.tunnels.records.size).toBe(0);
    expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(410);
    // Only the Mac's own key can forget it: another key's call is about another installation.
    const other = await Mac.make();
    expect((await app.call(other, "DELETE", "/v1/installations/self")).status).toBe(410);
  });

  it("when Cloudflare refuses the teardown, the installation stays", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    await app.call(mac, "POST", "/v1/installations/self/endpoint");
    app.tunnels.refuse.deleteTunnel = "tunnel has active connections";
    const failed = await app.call(mac, "DELETE", "/v1/installations/self");
    expect(failed.status).toBe(502);
    expect(failed.body.error).toBe("Couldn't deleteTunnel: tunnel has active connections");
    expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(200);
    expect(await env.DB.prepare("SELECT * FROM endpoints").first()).not.toBeNull();
  });
});

describe("the sweep", () => {
  it("removes installations idle for thirty days, with their tunnels; a call keeps one alive", async () => {
    const app = testApp();
    const idle = await Mac.make();
    const alive = await Mac.make();
    await app.register(idle);
    await app.call(idle, "POST", "/v1/installations/self/endpoint");
    await app.register(alive);
    await app.call(alive, "POST", "/v1/installations/self/endpoint");
    // Both tunnels kept connected: only the idle installation goes.
    app.tunnels.connectAll();
    app.time.advance(29 * DAY);
    await app.call(alive, "GET", "/v1/installations/self");
    expect(await sweep(env, app.deps)).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 0 });

    app.time.advance(2 * DAY);
    expect(await sweep(env, app.deps)).toEqual({ removed: 1, reclaimed: 0, failed: 0, unused: 0 });
    expect((await app.call(idle, "GET", "/v1/installations/self")).status).toBe(410);
    expect((await app.call(alive, "GET", "/v1/installations/self")).status).toBe(200);
    expect(app.tunnels.tunnels.size).toBe(1);
    expect(app.tunnels.records.size).toBe(1);
    // Spent nonces went too, all but the alive Mac's last; the idle one's refused call kept none.
    const nonces = await env.DB.prepare("SELECT count(*) AS n FROM nonces").first<{ n: number }>();
    expect(nonces?.n).toBe(1);

    // The idle Mac comes back: registered anew, with a new hostname.
    expect((await app.register(idle)).status).toBe(201);
  });

  it("when Cloudflare refuses, the installation stays for the next sweep", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    await app.call(mac, "POST", "/v1/installations/self/endpoint");
    app.tunnels.connectAll();
    app.time.advance(31 * DAY);
    app.tunnels.refuse.deleteDNSRecord = "rate limited";
    expect(await sweep(env, app.deps)).toEqual({ removed: 0, reclaimed: 0, failed: 1, unused: 0 });
    app.tunnels.refuse = {};
    expect(await sweep(env, app.deps)).toEqual({ removed: 1, reclaimed: 0, failed: 0, unused: 0 });
    expect(await env.DB.prepare("SELECT * FROM installations").first()).toBeNull();
  });

  it("removes installations that made no endpoint in a day, all at once, and old rate-limit windows", async () => {
    const app = testApp();
    const unused = [await Mac.make(), await Mac.make(), await Mac.make()];
    for (const mac of unused) await app.register(mac, "Mac", { "CF-Connecting-IP": "198.51.100.1" });
    const used = await Mac.make();
    await app.register(used);
    await app.call(used, "POST", "/v1/installations/self/endpoint");
    app.tunnels.connectAll();
    app.time.advance(23 * HOUR);
    expect((await sweep(env, app.deps)).unused).toBe(0);
    const windows = async () => (await env.DB.prepare("SELECT count(*) AS n FROM rate_limits").first<{ n: number }>())?.n;
    expect(await windows()).toBeGreaterThan(0);
    app.time.advance(2 * HOUR);
    expect(await sweep(env, app.deps)).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 3 });
    for (const mac of unused) expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(410);
    expect((await app.call(used, "GET", "/v1/installations/self")).status).toBe(200);
    // The registrations' and the endpoint's windows, an hour each, are over a day old: gone.
    expect(await windows()).toBe(0);
  });

  it("reclaims a tunnel never connected in an hour, or down for three days, keeping the installation; keeps a connected one", async () => {
    const app = testApp();
    const never = await Mac.make();
    const down = await Mac.make();
    const up = await Mac.make();
    const ids: Record<string, string> = {};
    for (const [name, mac] of [["never", never], ["down", down], ["up", up]] as const) {
      await app.register(mac, "Mac", { "CF-Connecting-IP": `192.0.2.${Object.keys(ids).length + 1}` });
      ids[name] = (await app.call(mac, "POST", "/v1/installations/self/endpoint")).body.endpoint.tunnelId;
    }
    // As Cloudflare answers: a tunnel that never connected has conns_inactive_at, and no conns_active_at.
    expect(await app.tunnels.tunnelStatus(ids.never!)).toEqual({ connected: false, activeAt: null, inactiveAt: "2026-10-12T12:00:00.000Z" });
    app.tunnels.status.set(ids.up!, { connected: true, activeAt: app.time.now().toISOString(), inactiveAt: null });
    app.tunnels.status.set(ids.down!, { connected: true, activeAt: app.time.now().toISOString(), inactiveAt: null });
    app.time.advance(59 * 60_000);
    expect(await sweep(env, app.deps)).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 0 });
    app.time.advance(2 * 60_000);
    app.tunnels.status.set(ids.down!, { connected: false, activeAt: "2026-10-12T12:01:00.000Z", inactiveAt: app.time.now().toISOString() });
    expect(await sweep(env, app.deps)).toEqual({ removed: 0, reclaimed: 1, failed: 0, unused: 0 });
    expect(app.tunnels.tunnels.has(ids.never!)).toBe(false);
    // A firewall that stops cloudflared costs the Mac its tunnel, not its sign-in: the installation stays.
    expect((await app.call(never, "GET", "/v1/installations/self")).body.installation.endpoint).toBeNull();
    app.time.advance(3 * DAY);
    expect((await sweep(env, app.deps)).reclaimed).toBe(1);
    expect(app.tunnels.tunnels.has(ids.down!)).toBe(false);
    // Down for days: the installation stays, with no endpoint; turning on again makes a new hostname.
    expect((await app.call(down, "GET", "/v1/installations/self")).body.installation.endpoint).toBeNull();
    // Days later, neither is swept as never used: they made endpoints once.
    expect((await sweep(env, app.deps)).unused).toBe(0);
    expect((await app.call(never, "GET", "/v1/installations/self")).status).toBe(200);
    expect(app.tunnels.tunnels.has(ids.up!)).toBe(true);
    expect((await app.call(up, "GET", "/v1/installations/self")).body.installation.endpoint).not.toBeNull();
  });
  it("asks about never-checked endpoints first, oldest first, then the longest ago checked", async () => {
    const app = testApp();
    await app.fill(STATUS_BATCH + 3);
    // Connected, so the sweep keeps them all and only marks them checked.
    for (const row of (await env.DB.prepare("SELECT tunnel_id FROM endpoints").all<{ tunnel_id: string }>()).results) {
      app.tunnels.status.set(row.tunnel_id, { connected: true, activeAt: "2026-10-12T12:00:00.000Z", inactiveAt: null });
    }
    const asked = () => app.tunnels.reads.filter((read) => read.op === "tunnelStatus").map((read) => read.args[0]);
    app.time.advance(60_000);
    await app.fill(1, "late");
    const late = (await env.DB.prepare("SELECT tunnel_id FROM endpoints WHERE network = 'late'").first<{ tunnel_id: string }>())!.tunnel_id;
    await sweep(env, app.deps);
    expect(asked()).toHaveLength(STATUS_BATCH);
    expect(asked()).not.toContain(late);
    app.time.advance(60_000);
    await sweep(env, app.deps);
    // The next run starts with the four never asked about, the late one last of them.
    const second = asked().slice(STATUS_BATCH, STATUS_BATCH + 4);
    for (const id of second) expect(asked().slice(0, STATUS_BATCH)).not.toContain(id);
    expect(second[3]).toBe(late);
  });
});

describe("reclaimable", () => {
  const made = { created_at: "2026-10-12T00:00:00.000Z" };
  const at = (hours: number) => new Date(Date.parse(made.created_at) + hours * HOUR);
  it("keeps a connected tunnel whatever its times", () => {
    expect(reclaimable(made, { connected: true, activeAt: null, inactiveAt: "2026-01-01T00:00:00.000Z" }, at(1000))).toBeNull();
  });
  it("calls one with no conns_active_at never connected, even with conns_inactive_at set, after an hour", () => {
    const never = { connected: false, activeAt: null, inactiveAt: "2026-10-12T00:00:00.000Z" };
    expect(reclaimable(made, never, at(0.9))).toBeNull();
    expect(reclaimable(made, never, at(1))).toBe("never");
  });
  it("reclaims one down for three days, counted from when it went down", () => {
    const down = { connected: false, activeAt: "2026-10-12T01:00:00.000Z", inactiveAt: "2026-10-13T00:00:00.000Z" };
    expect(reclaimable(made, down, at(24 + 71))).toBeNull();
    expect(reclaimable(made, down, at(24 + 72))).toBe("down");
  });
});
