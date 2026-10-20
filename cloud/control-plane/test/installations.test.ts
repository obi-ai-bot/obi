import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { sweep } from "../src/app";
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
    expect(refused.status).toBe(404);
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

  it("limits new Macs per network and over everyone; a key again isn't counted", async () => {
    const app = testApp();
    const home = { "CF-Connecting-IP": "198.51.100.7" };
    const macs: Mac[] = [];
    for (let i = 0; i < 5; i++) {
      macs.push(await Mac.make());
      expect((await app.register(macs[i]!, "Mac", home)).status).toBe(201);
    }
    const sixth = await app.register(await Mac.make(), "Mac", home);
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toMatch(/^Too many Macs were set up from this network lately\. Try again in \d+ minutes?\.$/);
    expect(sixth.headers.get("Retry-After")).not.toBeNull();
    expect((await app.register(macs[0]!, "Mac", home)).status).toBe(200);

    // Over everyone: 60 an hour, whatever the network.
    for (let i = 0; i < 55; i++) expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": `203.0.113.${i}` })).status).toBe(201);
    const busy = await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "192.0.2.1" });
    expect(busy.status).toBe(429);
    expect(busy.body.error).toMatch(/^Too many Macs are being set up right now\./);
    app.time.advance(HOUR);
    expect((await app.register(await Mac.make(), "Mac", { "CF-Connecting-IP": "192.0.2.1" })).status).toBe(201);
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
    expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(404);
    // Only the Mac's own key can forget it: another key's call is about another installation.
    const other = await Mac.make();
    expect((await app.call(other, "DELETE", "/v1/installations/self")).status).toBe(404);
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

describe("the hourly sweep", () => {
  it("removes installations idle for thirty days, with their tunnels; a call keeps one alive", async () => {
    const app = testApp();
    const idle = await Mac.make();
    const alive = await Mac.make();
    await app.register(idle);
    await app.call(idle, "POST", "/v1/installations/self/endpoint");
    await app.register(alive);
    await app.call(alive, "POST", "/v1/installations/self/endpoint");
    app.time.advance(29 * DAY);
    await app.call(alive, "GET", "/v1/installations/self");
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, failed: 0 });

    app.time.advance(2 * DAY);
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 1, failed: 0 });
    expect((await app.call(idle, "GET", "/v1/installations/self")).status).toBe(404);
    expect((await app.call(alive, "GET", "/v1/installations/self")).status).toBe(200);
    expect(app.tunnels.tunnels.size).toBe(1);
    expect(app.tunnels.records.size).toBe(1);
    // Spent nonces went too, all but the ones still fresh.
    const nonces = await env.DB.prepare("SELECT count(*) AS n FROM nonces").first<{ n: number }>();
    expect(nonces?.n).toBe(2);

    // The idle Mac comes back: registered anew, with a new hostname.
    expect((await app.register(idle)).status).toBe(201);
  });

  it("when Cloudflare refuses, the installation stays for the next sweep", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    await app.call(mac, "POST", "/v1/installations/self/endpoint");
    app.time.advance(31 * DAY);
    app.tunnels.refuse.deleteDNSRecord = "rate limited";
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 0, failed: 1 });
    app.tunnels.refuse = {};
    expect(await sweep(env, { tunnels: app.tunnels, now: app.time.now })).toEqual({ removed: 1, failed: 0 });
    expect(await env.DB.prepare("SELECT * FROM installations").first()).toBeNull();
  });
});
