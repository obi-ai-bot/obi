// Hook addresses (#1128): made, listed and removed by their Mac's signed calls; a delivery passed
// to the Mac's gateway with its body and only the listed headers, after the checks that need no
// secret; nothing of a delivery kept.

import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { HOOK_BODY_MAX, sweep } from "../src/app";
import { DAY, HOUR, Mac, testApp } from "./helpers";

/// What the Worker would send the Mac, and what the Mac answers (202 by default).
function gateway(status = 202) {
  const sent: { url: string; headers: Headers; body: string }[] = [];
  let answer: number | "unreachable" = status;
  const forward = async (url: string, init: RequestInit) => {
    sent.push({ url, headers: new Headers(init.headers), body: new TextDecoder().decode(init.body as Uint8Array) });
    if (answer === "unreachable") throw new TypeError("network connection lost");
    return new Response("obid's own words", { status: answer });
  };
  return { sent, forward, answers: (next: number | "unreachable") => (answer = next) };
}

async function withEndpoint(app: ReturnType<typeof testApp>) {
  const mac = await Mac.make();
  await app.register(mac);
  const endpoint = await app.call(mac, "POST", "/v1/installations/self/endpoint");
  return { mac, hostname: endpoint.body.endpoint.hostname as string };
}

describe("hooks", () => {
  it("makes, lists and removes a hook, signed by its Mac", async () => {
    const app = testApp();
    const { mac } = await withEndpoint(app);
    const made = await app.call(mac, "POST", "/v1/installations/self/hooks");
    expect(made.status).toBe(201);
    const id = made.body.hook.id as string;
    expect(id).toMatch(/^[a-z0-9]{32}$/);
    expect(made.body.hook.url).toBe(`https://oby-control.oby.test/h/${id}`);
    const listed = await app.call(mac, "GET", "/v1/installations/self/hooks");
    expect(listed.body.hooks.map((h: { id: string }) => h.id)).toEqual([id]);
    expect((await app.call(mac, "DELETE", `/v1/installations/self/hooks/${id}`)).status).toBe(204);
    expect((await app.call(mac, "GET", "/v1/installations/self/hooks")).body.hooks).toEqual([]);
    expect((await app.raw("GET", "/v1/installations/self/hooks")).status).toBe(401);
  });

  it("another Mac's key can't see or remove it", async () => {
    const app = testApp();
    const { mac } = await withEndpoint(app);
    const id = (await app.call(mac, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    const other = await Mac.make();
    await app.register(other, "Other", {}, "001234.apple-account.0002");
    expect((await app.call(other, "GET", "/v1/installations/self/hooks")).body.hooks).toEqual([]);
    expect((await app.call(other, "DELETE", `/v1/installations/self/hooks/${id}`)).status).toBe(404);
    expect((await app.call(mac, "GET", "/v1/installations/self/hooks")).body.hooks).toHaveLength(1);
  });

  it("forwards a delivery to the Mac's hostname with only the listed headers", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key, hostname } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    const body = JSON.stringify({ alerts: [{ status: "firing" }] });
    const sent = await app.raw("POST", `/h/${id}`, body, {
      "X-Hub-Signature-256": "sha256=abc",
      "X-GitHub-Event": "ping",
      "X-Grafana-Alerting-Signature": "def",
      Authorization: "Bearer someone's",
      Cookie: "session=1",
      "CF-Connecting-IP": "203.0.113.9",
    });
    expect(sent.status).toBe(202);
    expect(sent.body).toEqual({ ok: true });
    expect(mac.sent).toHaveLength(1);
    expect(mac.sent[0]?.url).toBe(`https://${hostname}/v1/hooks/${id}/deliver`);
    expect(mac.sent[0]?.body).toBe(body);
    const names = [...(mac.sent[0]?.headers.keys() ?? [])].sort();
    expect(names).toEqual(["content-type", "x-github-event", "x-grafana-alerting-signature", "x-hub-signature-256"]);
    // obid's status, never its words.
    mac.answers(401);
    const refused = await app.raw("POST", `/h/${id}`, body);
    expect(refused.status).toBe(401);
    expect(refused.body).toEqual({ ok: false });
  });

  it("follows the Mac to its new hostname", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key, hostname } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await app.call(key, "DELETE", "/v1/installations/self/endpoint");
    const again = (await app.call(key, "POST", "/v1/installations/self/endpoint")).body.endpoint.hostname as string;
    expect(again).not.toBe(hostname);
    await app.raw("POST", `/h/${id}`, "{}");
    expect(mac.sent.at(-1)?.url).toBe(`https://${again}/v1/hooks/${id}/deliver`);
  });

  it("refuses a body over 1 MiB and forwards nothing", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    const big = "x".repeat(HOOK_BODY_MAX + 1);
    expect((await app.raw("POST", `/h/${id}`, big)).status).toBe(413);
    expect(mac.sent).toHaveLength(0);
    expect((await app.raw("POST", `/h/${id}`, "x".repeat(HOOK_BODY_MAX))).status).toBe(202);
  });

  it("answers 404 for an unknown hook, 405 for another method and 503 for a Mac it can't reach", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    expect((await app.raw("POST", `/h/${"a".repeat(32)}`, "{}")).status).toBe(404);
    expect((await app.raw("POST", "/h/not-an-id", "{}")).status).toBe(404);
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    expect((await app.raw("GET", `/h/${id}`)).status).toBe(405);
    mac.answers("unreachable");
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(503);
    mac.answers(530);
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(503);
    await app.call(key, "DELETE", "/v1/installations/self/endpoint");
    mac.answers(202);
    const away = await app.raw("POST", `/h/${id}`, "{}");
    expect(away.status).toBe(503);
    expect(away.body.error).toBe("That Oby isn't reachable now.");
  });

  it("counts only what obid doesn't refuse as unsigned against a hook's day", async () => {
    const mac = gateway(401);
    const app = testApp({ forward: mac.forward });
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await app.counted(`deliveries:day:${id}`, 1999);
    for (let i = 0; i < 3; i++) expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(401);
    mac.answers(202);
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(202);
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(429);
  });

  it("the sweep takes the hooks of an installation that never made an endpoint", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    expect((await app.call(mac, "POST", "/v1/installations/self/hooks")).status).toBe(201);
    app.time.advance(25 * HOUR);
    await sweep(env, app.deps);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM hooks").first<{ n: number }>())?.n).toBe(0);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM installations").first<{ n: number }>())?.n).toBe(0);
  });

  it("limits each hook to 60 deliveries a minute, and an installation to 20 hooks", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await app.counted(`deliveries:minute:${id}`, 60);
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(429);
    for (let i = 1; i < 20; i++) expect((await app.call(key, "POST", "/v1/installations/self/hooks")).status).toBe(201);
    expect((await app.call(key, "POST", "/v1/installations/self/hooks")).status).toBe(409);
  });

  it("forgetting the Mac removes its hooks", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    expect((await app.call(key, "DELETE", "/v1/installations/self")).status).toBe(204);
    expect((await app.raw("POST", `/h/${id}`, "{}")).status).toBe(404);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM hooks").first<{ n: number }>())?.n).toBe(0);
    // An idle installation the sweep removes takes its hooks too.
    const { mac: idle } = await withEndpoint(app);
    await app.call(idle, "POST", "/v1/installations/self/hooks");
    app.time.advance(31 * DAY);
    await sweep(env, app.deps);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM hooks").first<{ n: number }>())?.n).toBe(0);
  });

  it("keeps nothing of a delivery", async () => {
    const mac = gateway();
    const app = testApp({ forward: mac.forward });
    const { mac: key } = await withEndpoint(app);
    const id = (await app.call(key, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await app.raw("POST", `/h/${id}`, JSON.stringify({ marker: "DELIVERY-MARKER" }), { "X-Oby-Signature-256": "sha256=SIGNATURE-MARKER" });
    const tables = (await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all<{ name: string }>()).results;
    for (const { name } of tables) {
      if (name.startsWith("_cf") || name.startsWith("sqlite") || name === "d1_migrations") continue;
      const rows = await env.DB.prepare(`SELECT * FROM ${name}`).all();
      expect(JSON.stringify(rows.results)).not.toContain("MARKER");
    }
  });
});
