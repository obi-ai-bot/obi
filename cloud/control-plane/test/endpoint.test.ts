import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { tunnelsFromEnv } from "../src/cloudflare";
import type { Env } from "../src/env";
import { HOUR, Mac, testApp } from "./helpers";

async function registered(app: ReturnType<typeof testApp>) {
  const mac = await Mac.make();
  const answer = await app.register(mac);
  return { mac, id: answer.body.installation.id as string };
}

describe("the installation's tunnel", () => {
  it("creates a tunnel, routes only the gateway through it, and names the hostname", async () => {
    const app = testApp();
    const mac = await registered(app);
    const created = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(created.status).toBe(201);
    const hostname = created.body.endpoint.hostname as string;
    expect(hostname).toMatch(/^oby-[a-z0-9]{20}\.oby-devices\.test$/);
    expect(created.body.endpoint.tunnelId).toBe("tunnel-1");

    expect(app.tunnels.ops()).toEqual(["createTunnel", "configureTunnel", "createCNAME"]);
    const [name, secret] = app.tunnels.calls[0]?.args as [string, string];
    expect(name).toBe(`oby-${mac.id}`);
    expect(atob(secret).length).toBeGreaterThanOrEqual(32);
    expect(app.tunnels.tunnels.get("tunnel-1")?.ingress).toEqual([{ hostname, service: "http://127.0.0.1:8810" }, { service: "http_status:404" }]);
    expect([...app.tunnels.records.values()]).toEqual([{ name: hostname, target: "tunnel-1.cfargotunnel.com" }]);

    const self = await app.call(mac.mac, "GET", "/v1/installations/self");
    expect(self.body.installation.endpoint.hostname).toBe(hostname);
    // The secret went to Cloudflare once and is nowhere in the database.
    const rows = await env.DB.prepare("SELECT * FROM endpoints").all();
    expect(JSON.stringify(rows.results)).not.toContain(secret);
  });

  it("asking again gives the same endpoint, with no new tunnel", async () => {
    const app = testApp();
    const mac = await registered(app);
    const first = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    const again = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(again.status).toBe(200);
    expect(again.body).toEqual(first.body);
    expect(app.tunnels.ops()).toEqual(["createTunnel", "configureTunnel", "createCNAME"]);
  });

  it("hands the Mac its tunnel token, never kept", async () => {
    const app = testApp();
    const mac = await registered(app);
    const before = await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token");
    expect(before.status).toBe(404);
    const created = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    const token = await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token");
    expect(token.status).toBe(200);
    expect(token.headers.get("Cache-Control")).toBe("no-store");
    expect(token.body).toEqual({ token: "token-for-tunnel-1", hostname: created.body.endpoint.hostname });
    for (const table of ["endpoints", "installations", "nonces"]) {
      const rows = await env.DB.prepare(`SELECT * FROM ${table}`).all();
      expect(JSON.stringify(rows.results)).not.toContain("token-for-");
    }
  });

  it("removing the endpoint deletes the record and the tunnel", async () => {
    const app = testApp();
    const mac = await registered(app);
    await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    const removed = await app.call(mac.mac, "DELETE", "/v1/installations/self/endpoint");
    expect(removed.status).toBe(204);
    expect(app.tunnels.calls.slice(3)).toEqual([
      { op: "deleteDNSRecord", args: ["record-2"] },
      { op: "deleteTunnel", args: ["tunnel-1"] },
    ]);
    expect((await app.call(mac.mac, "GET", "/v1/installations/self")).body.installation.endpoint).toBeNull();
    expect((await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token")).status).toBe(404);
    // Removing it again is nothing.
    expect((await app.call(mac.mac, "DELETE", "/v1/installations/self/endpoint")).status).toBe(204);
    // And turning it on again makes a new one.
    const again = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(again.status).toBe(201);
    expect(again.body.endpoint.tunnelId).toBe("tunnel-3");
  });

  it("when the DNS record fails, the tunnel goes too and the call fails", async () => {
    const app = testApp();
    const mac = await registered(app);
    app.tunnels.refuse.createCNAME = "record already exists";
    const failed = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(failed.status).toBe(502);
    expect(failed.body.error).toBe("Couldn't createCNAME: record already exists");
    expect(app.tunnels.ops()).toEqual(["createTunnel", "configureTunnel", "createCNAME", "deleteTunnel"]);
    expect(app.tunnels.tunnels.size).toBe(0);
    expect((await app.call(mac.mac, "GET", "/v1/installations/self")).body.installation.endpoint).toBeNull();
  });

  it("without Cloudflare's secrets, says what to set", async () => {
    const app = testApp({ tunnels: tunnelsFromEnv({} as Env) });
    const mac = await registered(app);
    const failed = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(failed.status).toBe(503);
    expect(failed.body.error).toContain("CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID");
  });
});

describe("what a tunnel may cost", () => {
  it("makes no hostname until the devices have a domain of their own", async () => {
    for (const domain of ["", "tetrix.pro", "devices.tetrix.pro", "pro"]) {
      const app = testApp({}, { DEVICE_DOMAIN: domain });
      const mac = await registered(app);
      const refused = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
      expect(refused.status, domain).toBe(503);
      expect(refused.body.error).toMatch(/DEVICE_DOMAIN|device domain/);
      expect(app.tunnels.calls).toEqual([]);
    }
  });

  it("caps the endpoints alive at once", async () => {
    const app = testApp({}, { MAX_ENDPOINTS: "1" });
    const first = await registered(app);
    expect((await app.call(first.mac, "POST", "/v1/installations/self/endpoint")).status).toBe(201);
    const second = await registered(app);
    const full = await app.call(second.mac, "POST", "/v1/installations/self/endpoint");
    expect(full.status).toBe(503);
    expect(full.body.error).toBe("Remote access is full right now. Try again later.");
    expect(app.tunnels.tunnels.size).toBe(1);
    // The first one asking again still gets its own.
    expect((await app.call(first.mac, "POST", "/v1/installations/self/endpoint")).status).toBe(200);
  });

  it("limits each installation's tunnel changes and token reads", async () => {
    const app = testApp();
    const mac = await registered(app);
    for (let i = 0; i < 5; i++) {
      const path = "/v1/installations/self/endpoint";
      expect((await app.call(mac.mac, i % 2 ? "DELETE" : "POST", path)).status).toBe(i % 2 ? 204 : 201);
    }
    const sixth = await app.call(mac.mac, "DELETE", "/v1/installations/self/endpoint");
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toMatch(/^This Mac changed its tunnel too often\./);
    // Asking for the endpoint it has costs Cloudflare nothing, so it isn't counted.
    expect((await app.call(mac.mac, "POST", "/v1/installations/self/endpoint")).status).toBe(200);
    for (let i = 0; i < 30; i++) expect((await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token")).status).toBe(200);
    const greedy = await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token");
    expect(greedy.status).toBe(429);
    expect(greedy.body.error).toMatch(/^This Mac asked for its tunnel's token too often\./);
    app.time.advance(HOUR);
    expect((await app.call(mac.mac, "GET", "/v1/installations/self/endpoint/token")).status).toBe(200);
    // Another Mac isn't held back by this one.
    const other = await registered(app);
    expect((await app.call(other.mac, "POST", "/v1/installations/self/endpoint")).status).toBe(201);
  });

  it("limits new endpoints over everyone", async () => {
    const app = testApp();
    const window = Math.floor(app.time.now().getTime() / 1000);
    await env.DB.prepare("INSERT INTO rate_limits (key, window_start, count) VALUES ('endpoints:everywhere', ?1, 60)").bind(window).run();
    const mac = await registered(app);
    const busy = await app.call(mac.mac, "POST", "/v1/installations/self/endpoint");
    expect(busy.status).toBe(429);
    expect(busy.body.error).toMatch(/^Too many Macs are turning remote access on right now\./);
    expect(app.tunnels.calls).toEqual([]);
  });
});
