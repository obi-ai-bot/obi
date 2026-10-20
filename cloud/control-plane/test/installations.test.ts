import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { reclaimable, STATUS_BATCH, sweep } from "../src/app";
import { checks, DAY, HOUR, Mac, testApp, work } from "./helpers";

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
    const blank = await app.call(mac, "POST", "/v1/installations", { name: "   ", platform: "macos", proofAt: "1", proof: "1" });
    expect(blank.status).toBe(422);
    expect(blank.body.error).toBe("name is 1 to 64 characters.");
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macOS" })).status).toBe(422);
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac" })).status).toBe(422);
    expect((await app.call(mac, "POST", "/v1/installations", "not json")).status).toBe(400);
    expect((await app.call(mac, "GET", "/v1/nothing")).status).toBe(404);
    expect((await app.raw("GET", "/v1/health")).body).toEqual({ ok: true });
  });

  it("a new Mac pays a proof of work; the same key again doesn't", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const at = Math.floor(app.time.now().getTime() / 1000);
    const none = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos" });
    expect(none.status).toBe(403);
    expect(none.body.error).toBe("A new Mac needs a proof of work. Update Oby.");
    // An answer that doesn't make the zero bits, and this key's answer sent by another key.
    const right = await work(mac.publicKey, at);
    const bad = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(at), proof: await work(mac.publicKey, at, false) });
    expect(bad.status).toBe(403);
    expect(bad.body.error).toBe("That proof of work doesn't check out.");
    const other = await Mac.make();
    if (!(await checks(other.publicKey, at, right))) {
      expect((await app.call(other, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(at), proof: right })).status).toBe(403);
    }
    // A proof made long ago is refused.
    const old = at - 10 * 60;
    const stale = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(old), proof: await work(mac.publicKey, old) });
    expect(stale.status).toBe(403);
    expect(stale.body.error).toBe("That proof of work is too old.");
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(at), proof: right })).status).toBe(201);
    // Registered, the key needs no proof again.
    expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos" })).status).toBe(200);
  });

  it("limits new Macs per network, an IPv6 /64 as one network; a key again isn't counted", async () => {
    const app = testApp();
    const macs: Mac[] = [];
    for (let i = 0; i < 5; i++) {
      macs.push(await Mac.make());
      expect((await app.register(macs[i]!, "Mac", { "CF-Connecting-IP": `2001:db8:1:2::${i + 1}` })).status).toBe(201);
    }
    const sixth = await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:1:2:ffff:ffff:ffff:ffff" });
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toMatch(/^Too many Macs were set up from this network lately\. Try again in \d+ minutes?\.$/);
    expect(sixth.headers.get("Retry-After")).not.toBeNull();
    expect((await app.register(macs[0]!, "Mac", { "CF-Connecting-IP": "2001:db8:1:2::1" })).status).toBe(200);
    // The next /64 is another network.
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:1:3::1" })).status).toBe(201);
  });

  it("over everyone, past the breaker, asks for more work instead of refusing", async () => {
    const app = testApp();
    const window = Math.floor(app.time.now().getTime() / 1000);
    await env.DB.prepare("INSERT INTO rate_limits (key, window_start, count) VALUES ('registrations:everywhere', ?1, 1000)").bind(window).run();
    const mac = await Mac.make();
    const at = Math.floor(app.time.now().getTime() / 1000);
    const harder = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(at), proof: await work(mac.publicKey, at, true, 8) });
    expect(harder.status).toBe(403);
    expect(harder.body.workBits).toBe(12);
    // With the bits asked for, it's in.
    expect((await app.register(mac, "Mac", { "CF-Connecting-IP": "192.0.2.1" })).status).toBe(201);
  });

  it("limits new Macs per network too: an IPv6 /48 or an IPv4 /24", async () => {
    const app = testApp();
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 5; j++) expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": `2001:db8:7:${i}::${j + 1}` })).status).toBe(201);
    }
    const another64 = await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:7:ff::1" });
    expect(another64.status).toBe(429);
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "2001:db8:8::1" })).status).toBe(201);
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 5; j++) expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": `198.51.100.${i * 10 + j}` })).status).toBe(201);
    }
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "198.51.100.200" })).status).toBe(429);
  });

  it("asks for more work as endpoints near the cap", async () => {
    const app = testApp({}, { MAX_ENDPOINTS: "10" });
    const bitsNow = async () => {
      const mac = await Mac.make();
      const at = Math.floor(app.time.now().getTime() / 1000);
      // An answer that misses even the base bits, so every level refuses it and says what it needs.
      const proof = await work(mac.publicKey, at, false);
      const answer = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", proofAt: String(at), proof });
      return answer.body.workBits as number;
    };
    await app.fill(4);
    expect(await bitsNow()).toBe(8);
    await app.fill(1);
    expect(await bitsNow()).toBe(10);
    await app.fill(3);
    expect(await bitsNow()).toBe(12);
  });

  it("fails closed on a work-bits setting that isn't a number", async () => {
    for (const bits of ["", "x", "8x", "40"]) {
      const app = testApp({}, { REGISTRATION_WORK_BITS: bits });
      const answer = await app.register(await Mac.make());
      expect(answer.status, bits).toBe(503);
      expect(answer.body.error).toMatch(/^REGISTRATION_WORK_BITS in wrangler\.jsonc isn't a whole number/);
    }
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
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 0 });

    app.time.advance(2 * DAY);
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 1, reclaimed: 0, failed: 0, unused: 0 });
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
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, reclaimed: 0, failed: 1, unused: 0 });
    app.tunnels.refuse = {};
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 1, reclaimed: 0, failed: 0, unused: 0 });
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
    expect((await sweep(env, { tunnels: app.tunnels, now: app.time.now })).unused).toBe(0);
    const windows = async () => (await env.DB.prepare("SELECT count(*) AS n FROM rate_limits").first<{ n: number }>())?.n;
    expect(await windows()).toBeGreaterThan(0);
    app.time.advance(2 * HOUR);
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 3 });
    for (const mac of unused) expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(410);
    expect((await app.call(used, "GET", "/v1/installations/self")).status).toBe(200);
    // The registrations' and the endpoint's windows, an hour each, are over a day old: gone.
    expect(await windows()).toBe(0);
  });

  it("reclaims tunnels never connected in a day, or down for three days; a connected one stays", async () => {
    const app = testApp();
    const never = await Mac.make();
    const down = await Mac.make();
    const up = await Mac.make();
    const ids: Record<string, string> = {};
    for (const [name, mac] of [["never", never], ["down", down], ["up", up]] as const) {
      await app.register(mac, "Mac", { "CF-Connecting-IP": `192.0.2.${Object.keys(ids).length + 1}` });
      ids[name] = (await app.call(mac, "POST", "/v1/installations/self/endpoint")).body.endpoint.tunnelId;
    }
    app.tunnels.status.set(ids.up!, { connected: true, activeAt: app.time.now().toISOString(), inactiveAt: null });
    app.time.advance(23 * HOUR);
    app.tunnels.status.set(ids.down!, { connected: false, activeAt: "2026-10-12T12:30:00.000Z", inactiveAt: app.time.now().toISOString() });
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, reclaimed: 0, failed: 0, unused: 0 });
    app.time.advance(2 * HOUR);
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, reclaimed: 1, failed: 0, unused: 0 });
    expect(app.tunnels.tunnels.has(ids.never!)).toBe(false);
    // Its installation stays; turning on again makes a new hostname.
    expect((await app.call(never, "GET", "/v1/installations/self")).body.installation.endpoint).toBeNull();
    app.time.advance(3 * DAY);
    expect((await sweep(env, { tunnels: app.tunnels, now: app.time.now })).reclaimed).toBe(1);
    expect(app.tunnels.tunnels.has(ids.down!)).toBe(false);
    expect(app.tunnels.tunnels.has(ids.up!)).toBe(true);
    expect((await app.call(up, "GET", "/v1/installations/self")).body.installation.endpoint).not.toBeNull();
  });

  it("asks about the endpoints checked longest ago, a batch at a time", async () => {
    const app = testApp();
    await app.fill(STATUS_BATCH + 3);
    const asked = () => app.tunnels.reads.filter((read) => read.op === "tunnelStatus").map((read) => read.args[0]);
    const first = { ...(await sweep(env, { tunnels: app.tunnels, now: app.time.now })) };
    expect(first.reclaimed).toBe(0);
    expect(asked()).toHaveLength(STATUS_BATCH);
    app.time.advance(5 * 60_000);
    await sweep(env, { tunnels: app.tunnels, now: app.time.now });
    // The next run starts with the three never asked about.
    const second = asked().slice(STATUS_BATCH);
    expect(new Set(second.slice(0, 3)).size).toBe(3);
    for (const id of second.slice(0, 3)) expect(asked().slice(0, STATUS_BATCH)).not.toContain(id);
  });
});

describe("reclaimable", () => {
  const made = { created_at: "2026-10-12T00:00:00.000Z" };
  const at = (hours: number) => new Date(Date.parse(made.created_at) + hours * HOUR);
  it("keeps a connected tunnel whatever its times", () => {
    expect(reclaimable(made, { connected: true, activeAt: null, inactiveAt: "2026-01-01T00:00:00.000Z" }, at(1000))).toBe(false);
  });
  it("reclaims one never connected after a day", () => {
    const never = { connected: false, activeAt: null, inactiveAt: null };
    expect(reclaimable(made, never, at(23.9))).toBe(false);
    expect(reclaimable(made, never, at(24))).toBe(true);
  });
  it("reclaims one down for three days, counted from when it went down", () => {
    const down = { connected: false, activeAt: "2026-10-12T01:00:00.000Z", inactiveAt: "2026-10-13T00:00:00.000Z" };
    expect(reclaimable(made, down, at(24 + 71))).toBe(false);
    expect(reclaimable(made, down, at(24 + 72))).toBe(true);
  });
});
