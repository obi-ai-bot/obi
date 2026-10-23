// Kept deliveries (#1315): while a Mac is away, a hook's delivery is kept sealed to its obid's queue
// key, which only that obid can open; handed over only to the Mac's own signed calls; bounded; and
// swept after 72 hours, or with its hook or installation.

import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { QUEUE, QUEUE_INFO, sweep } from "../src/app";
import { base64url, HOUR, Mac, testApp } from "./helpers";

const curve = { name: "ECDH", namedCurve: "P-256" };

/// obid's queue key, as obid makes it: a P-256 key-agreement key; the public half X9.63, base64url.
async function queueKey() {
  const keys = (await crypto.subtle.generateKey(curve, false, ["deriveBits"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  return { keys, raw, text: base64url(raw) };
}

function bytes(text: string): Uint8Array {
  return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
}

/// Opens a box as obid does, with `privateKey`; throws when it doesn't open.
async function open(box: Uint8Array, privateKey: CryptoKey, queue: Uint8Array, hook: string) {
  const ephemeral = box.slice(0, 65);
  const peer = await crypto.subtle.importKey("raw", ephemeral, curve, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: peer } as SubtleCryptoDeriveKeyAlgorithm, privateKey, 256);
  const base = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const salt = new Uint8Array([...ephemeral, ...queue]);
  const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt, info: new TextEncoder().encode(QUEUE_INFO) }, base, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: box.slice(65, 77), additionalData: new TextEncoder().encode(hook) }, key, box.slice(77));
  return JSON.parse(new TextDecoder().decode(plain));
}

/// A Mac with an endpoint, a hook and its obid's queue key registered; its gateway doesn't answer.
async function away() {
  let answer: number | "unreachable" = "unreachable";
  const forward = async () => {
    if (answer === "unreachable") throw new TypeError("network connection lost");
    return new Response("obid's own words", { status: answer });
  };
  const app = testApp({ forward });
  const mac = await Mac.make();
  await app.register(mac);
  await app.call(mac, "POST", "/v1/installations/self/endpoint");
  const hook = (await app.call(mac, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
  const queue = await queueKey();
  expect((await app.call(mac, "PUT", "/v1/installations/self/queue-key", { key: queue.text })).status).toBe(204);
  return { app, mac, hook, queue, answers: (next: number | "unreachable") => (answer = next) };
}

const kept = async () => (await env.DB.prepare("SELECT * FROM hook_queue ORDER BY received_at").all<Record<string, unknown>>()).results;

/// `count` items kept for `installation`'s `hook`, straight in D1, `size` bytes each.
async function fill(hook: string, count: number, size: number) {
  const row = await env.DB.prepare("SELECT installation_id FROM hooks WHERE id = ?1").bind(hook).first<{ installation_id: string }>();
  for (let i = 0; i < count; i++) {
    await env.DB.prepare("INSERT INTO hook_queue (id, hook_id, installation_id, received_at, size, sealed) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
      .bind(crypto.randomUUID(), hook, row?.installation_id, new Date().toISOString(), size, new Uint8Array(1))
      .run();
  }
}

describe("the hook queue", () => {
  it("keeps a delivery sealed when the Mac can't be reached", async () => {
    const { app, mac, hook, answers } = await away();
    const sent = await app.raw("POST", `/h/${hook}`, '{"status": "firing"}', { "X-Oby-Token": "t" });
    expect(sent.status).toBe(202);
    expect(sent.body).toEqual({ ok: true, message: "Kept for that Oby." });
    // Cloudflare's own answer for a tunnel that's down, and no endpoint at all, keep too.
    answers(530);
    expect((await app.raw("POST", `/h/${hook}`, "{}")).status).toBe(202);
    await app.call(mac, "DELETE", "/v1/installations/self/endpoint");
    expect((await app.raw("POST", `/h/${hook}`, "[]")).status).toBe(202);
    const rows = await kept();
    expect(rows).toHaveLength(3);
    expect(Object.keys(rows[0] ?? {}).sort()).toEqual(["hook_id", "id", "installation_id", "received_at", "sealed", "size"]);
    expect(rows[0]?.hook_id).toBe(hook);
    expect(rows[0]?.received_at).toBe("2026-10-12T12:00:00.000Z");
  });

  it("can't open what it keeps", async () => {
    const { app, hook, queue } = await away();
    await app.raw("POST", `/h/${hook}`, JSON.stringify({ marker: "DELIVERY-MARKER" }), { "X-Oby-Signature-256": "sha256=SIGNATURE-MARKER", Cookie: "c=1" });
    const tables = (await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all<{ name: string }>()).results;
    for (const { name } of tables) {
      if (name.startsWith("_cf") || name.startsWith("sqlite") || name === "d1_migrations") continue;
      const rows = await env.DB.prepare(`SELECT * FROM ${name}`).all();
      const text = JSON.stringify(rows.results, (_, value) => (value instanceof ArrayBuffer ? new TextDecoder().decode(value) : value));
      expect(text).not.toContain("MARKER");
    }
    const box = new Uint8Array((await kept())[0]?.sealed as ArrayBuffer);
    // Another key, or the right key for another hook, opens nothing.
    const other = await queueKey();
    await expect(open(box, other.keys.privateKey, queue.raw, hook)).rejects.toThrow();
    await expect(open(box, queue.keys.privateKey, queue.raw, "b".repeat(32))).rejects.toThrow();
    const opened = await open(box, queue.keys.privateKey, queue.raw, hook);
    expect(opened.receivedAt).toBe("2026-10-12T12:00:00.000Z");
    expect(opened.headers).toEqual({ "content-type": "application/json", "x-oby-signature-256": "sha256=SIGNATURE-MARKER" });
    expect(atob(opened.body)).toBe(JSON.stringify({ marker: "DELIVERY-MARKER" }));
  });

  it("answers 503 past each bound", async () => {
    const { app, mac, hook } = await away();
    expect((await app.raw("POST", `/h/${hook}`, "x".repeat(QUEUE.bodyMax + 1))).status).toBe(503);
    expect(await kept()).toHaveLength(0);
    await fill(hook, QUEUE.perInstallation, 10);
    expect((await app.raw("POST", `/h/${hook}`, "{}")).status).toBe(503);
    await env.DB.prepare("DELETE FROM hook_queue").run();
    await fill(hook, 1, QUEUE.bytesPerInstallation - 10);
    expect((await app.raw("POST", `/h/${hook}`, "{}")).status).toBe(503);
    expect(await kept()).toHaveLength(1);
    // Everyone's together: QUEUE_TOTAL_MIB.
    await env.DB.prepare("DELETE FROM hook_queue").run();
    const small = testApp({ forward: async () => new Response("", { status: 502 }) }, { QUEUE_TOTAL_MIB: "1" });
    const other = await Mac.make();
    await small.register(other, "Other", {}, "001234.apple-account.0002");
    const theirs = (await small.call(other, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await small.call(other, "PUT", "/v1/installations/self/queue-key", { key: (await queueKey()).text });
    await fill(hook, 1, 1024 * 1024 - 10);
    expect((await small.raw("POST", `/h/${theirs}`, "{}")).status).toBe(503);
    // With no queue key, nothing is kept, as before #1315; a key that isn't a point is refused.
    expect((await app.call(mac, "PUT", "/v1/installations/self/queue-key", { key: "not-a-key" })).status).toBe(422);
    await env.DB.prepare("UPDATE installations SET queue_key = NULL").run();
    await env.DB.prepare("DELETE FROM hook_queue").run();
    expect((await app.raw("POST", `/h/${hook}`, "{}")).status).toBe(503);
    expect(await kept()).toHaveLength(0);
  });

  it("hands kept items only to their Mac's signed call", async () => {
    const { app, mac, hook } = await away();
    for (let i = 0; i < QUEUE.batch + 2; i++) {
      app.time.advance(1000);
      expect((await app.raw("POST", `/h/${hook}`, JSON.stringify({ i }))).status).toBe(202);
    }
    expect((await app.raw("GET", "/v1/installations/self/hooks/queue")).status).toBe(401);
    const other = await Mac.make();
    await app.register(other, "Other", {}, "001234.apple-account.0002");
    expect((await app.call(other, "GET", "/v1/installations/self/hooks/queue")).body).toEqual({ items: [], left: 0 });
    const listed = await app.call(mac, "GET", "/v1/installations/self/hooks/queue");
    expect(listed.status).toBe(200);
    expect(listed.headers.get("Cache-Control")).toBe("no-store");
    expect(listed.body.items).toHaveLength(QUEUE.batch);
    expect(listed.body.left).toBe(2);
    const first = listed.body.items[0];
    expect(first.hook).toBe(hook);
    expect(first.receivedAt).toBe("2026-10-12T12:00:01.000Z");
    expect(bytes(first.sealed).length).toBeGreaterThan(77);
    expect((await app.call(other, "DELETE", `/v1/installations/self/hooks/queue/${first.id}`)).status).toBe(404);
    expect((await app.call(mac, "DELETE", `/v1/installations/self/hooks/queue/${first.id}`)).status).toBe(204);
    expect((await app.call(mac, "DELETE", `/v1/installations/self/hooks/queue/${first.id}`)).status).toBe(404);
    expect((await app.call(mac, "GET", "/v1/installations/self/hooks/queue")).body.left).toBe(1);
  });

  it("sweeps items past 72 hours and those of a removed hook", async () => {
    const { app, mac, hook } = await away();
    await app.raw("POST", `/h/${hook}`, "{}");
    app.time.advance(QUEUE.hours * HOUR - 1000);
    await app.raw("POST", `/h/${hook}`, "[]");
    app.time.advance(2000);
    await sweep(env, app.deps);
    expect(await kept()).toHaveLength(1);
    expect((await app.call(mac, "DELETE", `/v1/installations/self/hooks/${hook}`)).status).toBe(204);
    expect(await kept()).toHaveLength(0);
    const again = (await app.call(mac, "POST", "/v1/installations/self/hooks")).body.hook.id as string;
    await app.raw("POST", `/h/${again}`, "{}");
    expect(await kept()).toHaveLength(1);
    expect((await app.call(mac, "DELETE", "/v1/installations/self")).status).toBe(204);
    expect(await kept()).toHaveLength(0);
  });
});
