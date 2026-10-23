// The sealed push relay (#398): an iPhone registers its APNs token for a pushId and pushSecret,
// obid posts sealed alerts signed with that secret, and the relay sends Apple the fixed alert with
// the blob. APNs is a fake here: local workerd has no HTTP/2 (#27's spike).

import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PUSH, PUSH_ALERT } from "../src/app";
import { fromBase64url } from "../src/tokens";
import { base64url, MINUTE, testApp } from "./helpers";

const TOPIC = "com.deskree.oby.ios";
const TOKEN = "ab".repeat(32);
const SEALED = "c2VhbGVkLWZvci10aGUtcGhvbmU";

/// An APNs key as Apple gives one: a P-256 key in a PKCS#8 PEM, with its public half to check
/// the provider token against.
async function apnsKey() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const lines = btoa(String.fromCharCode(...der)).match(/.{1,64}/g)?.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

const key = await apnsKey();

/// The Worker's push secrets, made for this run: none is in git.
function secrets(pem = key.pem) {
  return { APNS_KEY: pem, APNS_KEY_ID: "KEY0000001", APNS_TEAM_ID: "TEAM000001", PUSH_SECRET_KEY: base64url(crypto.getRandomValues(new Uint8Array(32))) };
}

/// APNs: what it was sent, and what it answers (200 by default).
function fakeAPNs() {
  const sent: { url: string; headers: Headers; body: string }[] = [];
  let answer: () => Response = () => new Response(null, { status: 200, headers: { "apns-id": "A1" } });
  const send = async (url: string, init: RequestInit) => {
    sent.push({ url, headers: new Headers(init.headers), body: String(init.body) });
    return answer();
  };
  return { sent, send, answers: (next: () => Response) => (answer = next) };
}

const reason = (status: number, why: string, headers: Record<string, string> = {}) => () => Response.json({ reason: why }, { status, headers });

function relay(envOverrides = {}) {
  const apns = fakeAPNs();
  const app = testApp({ apns: apns.send }, { ...secrets(), ...envOverrides });
  return { app, apns };
}

type App = ReturnType<typeof testApp>;
type Phone = { pushId: string; pushSecret: string };

async function register(app: App, fields: Record<string, unknown> = {}, ip = "198.51.100.7") {
  return app.raw("POST", "/v1/push/devices", JSON.stringify({ apns: TOKEN, topic: TOPIC, sandbox: true, ...fields }), { "CF-Connecting-IP": ip });
}

async function phone(app: App, fields: Record<string, unknown> = {}): Promise<Phone> {
  const answer = await register(app, fields);
  expect(answer.status).toBe(200);
  return answer.body;
}

/// What obid sends: the HMAC-SHA-256 of the body under the secret's 32 bytes.
async function mac(secret: string, body: string): Promise<string> {
  const hmac = await crypto.subtle.importKey("raw", fromBase64url(secret)!, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(body))));
}

async function pushTo(app: App, to: Phone, fields: Record<string, unknown> = {}, signature?: string) {
  const body = JSON.stringify({ pushId: to.pushId, sealed: SEALED, ...fields });
  return app.raw("POST", "/v1/push", body, { "Oby-Push-Mac": signature ?? (await mac(to.pushSecret, body)) });
}

async function rows() {
  return (await env.DB.prepare("SELECT * FROM push_devices ORDER BY id").all()).results;
}

afterEach(() => vi.restoreAllMocks());

describe("registering a phone", () => {
  it("gives a pushId and a pushSecret, and D1 keeps only the id, the token, the topic and sandbox", async () => {
    const { app } = relay();
    const answer = await register(app, { apns: "AB".repeat(32) });
    expect(answer.status).toBe(200);
    expect(answer.headers.get("Cache-Control")).toBe("no-store");
    expect(Object.keys(answer.body).sort()).toEqual(["pushId", "pushSecret"]);
    expect(answer.body.pushId).toMatch(/^[A-Za-z0-9_-]{24}$/);
    expect(fromBase64url(answer.body.pushSecret)).toHaveLength(32);
    expect(await rows()).toEqual([{ id: answer.body.pushId, apns_token: TOKEN, topic: TOPIC, sandbox: 1 }]);
    // Each phone its own.
    const other = await phone(app, { apns: "cd".repeat(32), sandbox: false });
    expect(other.pushId).not.toBe(answer.body.pushId);
    expect(other.pushSecret).not.toBe(answer.body.pushSecret);
  });

  it("registers a changed token for the same id and secret, and brings a forgotten one back", async () => {
    const { app } = relay();
    const first = await phone(app);
    const again = await register(app, { ...first, apns: "ef".repeat(40), sandbox: false });
    expect(again.status).toBe(200);
    expect(again.body).toEqual(first);
    expect(await rows()).toEqual([{ id: first.pushId, apns_token: "ef".repeat(40), topic: TOPIC, sandbox: 0 }]);
    await env.DB.prepare("DELETE FROM push_devices").run();
    expect((await register(app, first)).body).toEqual(first);
    expect(await rows()).toHaveLength(1);
  });

  it("refuses a wrong secret and an id it never made with the same answer", async () => {
    const { app } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const wrong = await register(app, { pushId: mine.pushId, pushSecret: theirs.pushSecret });
    const unknown = await register(app, { pushId: base64url(crypto.getRandomValues(new Uint8Array(18))), pushSecret: mine.pushSecret });
    const half = await register(app, { pushId: mine.pushId });
    for (const answer of [wrong, unknown, half]) {
      expect(answer.status).toBe(401);
      expect(answer.body).toEqual(wrong.body);
    }
    expect((await rows()).map((row) => row.apns_token).sort()).toEqual(["ab".repeat(32), "cd".repeat(32)]);
  });

  it("moves a token another pushId has to the new one", async () => {
    const { app, apns } = relay();
    const old = await phone(app);
    const fresh = await phone(app);
    expect((await rows()).map((row) => row.id)).toEqual([fresh.pushId]);
    expect((await pushTo(app, old)).status).toBe(410);
    expect((await pushTo(app, fresh)).status).toBe(200);
    expect(apns.sent).toHaveLength(1);
  });

  it("refuses what isn't a registration", async () => {
    const { app } = relay();
    for (const fields of [{ apns: "xyz" }, { apns: "ab".repeat(31) }, { apns: "a".repeat(65) }, { apns: "ab".repeat(101) }, { apns: 42 }, { topic: "com.example.other" }, { sandbox: "yes" }, { name: "extra" }]) {
      expect((await register(app, fields)).status, JSON.stringify(fields)).toBe(422);
    }
    expect((await app.raw("POST", "/v1/push/devices", "not json")).status).toBe(400);
    expect((await register(app, { padding: "x".repeat(PUSH.registrationMax) })).status).toBe(413);
    expect(await rows()).toEqual([]);
  });

  it("limits new phones per client and re-registrations per phone", async () => {
    const { app } = relay();
    const mine = await phone(app);
    await app.counted("phones:address:198.51.100.7", 30);
    expect((await register(app, { apns: "cd".repeat(32) })).status).toBe(429);
    expect((await register(app, { apns: "cd".repeat(32) }, "203.0.113.9")).status).toBe(200);
    await app.counted(`phones:again:${mine.pushId}`, 20);
    expect((await register(app, mine)).status).toBe(429);
  });

  it("takes no more than MAX_PUSH_DEVICES phones", async () => {
    const { app } = relay({ MAX_PUSH_DEVICES: "1" });
    await phone(app);
    expect((await register(app, { apns: "cd".repeat(32) })).status).toBe(503);
  });

  it("forgets a phone that asks with its secret, and only then", async () => {
    const { app } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const forget = (secret: string) => app.raw("DELETE", `/v1/push/devices/${mine.pushId}`, undefined, { Authorization: `Bearer ${secret}` });
    expect((await forget(theirs.pushSecret)).status).toBe(401);
    expect((await app.raw("DELETE", `/v1/push/devices/${mine.pushId}`)).status).toBe(401);
    expect(await rows()).toHaveLength(2);
    expect((await forget(mine.pushSecret)).status).toBe(204);
    expect((await forget(mine.pushSecret)).status).toBe(204);
    expect((await rows()).map((row) => row.id)).toEqual([theirs.pushId]);
    expect((await pushTo(app, mine)).status).toBe(410);
  });
});

describe("a push", () => {
  it("goes to APNs as the contract says, with a provider token from the .p8 key", async () => {
    const fresh = await apnsKey();
    const apns = fakeAPNs();
    const app = testApp({ apns: apns.send }, secrets(fresh.pem));
    const sandboxed = await phone(app);
    const answer = await pushTo(app, sandboxed, { collapse: "job-7f3a", urgent: true });
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({ ok: true });
    expect(apns.sent).toHaveLength(1);
    const [sent] = apns.sent;
    expect(sent?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(sent?.headers.get("apns-topic")).toBe(TOPIC);
    expect(sent?.headers.get("apns-push-type")).toBe("alert");
    expect(sent?.headers.get("apns-priority")).toBe("10");
    expect(sent?.headers.get("apns-collapse-id")).toBe("job-7f3a");
    expect(JSON.parse(sent?.body ?? "")).toEqual({ aps: { alert: { title: "Oby", body: "Open Oby to see it." }, "mutable-content": 1, sound: "default" }, sealed: SEALED });
    expect(PUSH_ALERT).toEqual({ title: "Oby", body: "Open Oby to see it." });

    // An ES256 JWT: the key's id, the team, now, signed by the key.
    const [head, claims, signature] = (sent?.headers.get("authorization") ?? "").replace(/^bearer /, "").split(".");
    const decode = (part = "") => JSON.parse(new TextDecoder().decode(fromBase64url(part)!));
    expect(decode(head)).toEqual({ alg: "ES256", kid: "KEY0000001" });
    expect(decode(claims)).toEqual({ iss: "TEAM000001", iat: Math.floor(app.time.now().getTime() / 1000) });
    const signed = new TextEncoder().encode(`${head}.${claims}`);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, fresh.publicKey, fromBase64url(signature ?? "")!, signed)).toBe(true);

    // Not urgent, no collapse id, a phone on production APNs: the same provider token, reused.
    const production = await phone(app, { apns: "cd".repeat(32), sandbox: false });
    expect((await pushTo(app, production)).status).toBe(200);
    const second = apns.sent[1];
    expect(second?.url).toBe(`https://api.push.apple.com/3/device/${"cd".repeat(32)}`);
    expect(second?.headers.get("apns-priority")).toBe("5");
    expect(second?.headers.has("apns-collapse-id")).toBe(false);
    expect(second?.headers.get("authorization")).toBe(sent?.headers.get("authorization"));
    // A new one after 40 minutes.
    app.time.advance(41 * MINUTE);
    await pushTo(app, production);
    expect(apns.sent[2]?.headers.get("authorization")).not.toBe(sent?.headers.get("authorization"));
  });

  it("with a wrong MAC, another phone's secret or an id never made is 401, sends nothing and counts nothing", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const body = JSON.stringify({ pushId: mine.pushId, sealed: SEALED });
    const stranger = { pushId: base64url(crypto.getRandomValues(new Uint8Array(18))), pushSecret: mine.pushSecret };
    const answers = [
      await pushTo(app, mine, {}, await mac(theirs.pushSecret, body)),
      await pushTo(app, mine, {}, ""),
      await pushTo(app, mine, {}, (await mac(mine.pushSecret, body)).slice(0, 40)),
      await pushTo(app, mine, { urgent: true }, await mac(mine.pushSecret, body)),
      await pushTo(app, stranger),
    ];
    for (const answer of answers) {
      expect(answer.status).toBe(401);
      expect(answer.body).toEqual(answers[0]?.body);
    }
    expect(apns.sent).toEqual([]);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM rate_limits WHERE key LIKE 'pushes:%'").first<{ n: number }>())?.n).toBe(0);
  });

  it("refuses a body that isn't the contract's, before Apple sees it", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    expect((await pushTo(app, mine, { sealed: "x".repeat(PUSH.sealedMax) })).status).toBe(200);
    expect((await pushTo(app, mine, { sealed: "x".repeat(PUSH.sealedMax + 1) })).status).toBe(413);
    expect((await pushTo(app, mine, { sealed: "x".repeat(PUSH.sealedMax), collapse: "y".repeat(1000) })).status).toBe(413);
    for (const fields of [{ sealed: "not base64url!" }, { sealed: "" }, { collapse: "z".repeat(65) }, { collapse: "has space" }, { urgent: "yes" }, { title: "extra" }, { pushId: "short" }]) {
      expect((await pushTo(app, mine, fields)).status, JSON.stringify(fields)).toBe(422);
    }
    expect((await app.raw("POST", "/v1/push", "not json")).status).toBe(400);
    expect(apns.sent).toHaveLength(1);
  });

  it("forgets the phone when Apple says its token is gone", async () => {
    for (const gone of [reason(410, "Unregistered"), reason(400, "BadDeviceToken"), reason(400, "DeviceTokenNotForTopic")]) {
      const { app, apns } = relay();
      const mine = await phone(app);
      apns.answers(gone);
      expect((await pushTo(app, mine)).status).toBe(410);
      expect(await rows()).toEqual([]);
      await env.DB.prepare("DELETE FROM rate_limits").run();
    }
  });

  it("keeps the phone when Apple is busy, down or refuses the push itself", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    apns.answers(reason(429, "TooManyRequests", { "Retry-After": "120" }));
    const busy = await pushTo(app, mine);
    expect(busy.status).toBe(429);
    expect(busy.headers.get("Retry-After")).toBe("120");
    apns.answers(() => new Response("", { status: 503 }));
    expect((await pushTo(app, mine)).status).toBe(502);
    apns.answers(() => {
      throw new TypeError("Network connection lost.");
    });
    expect((await pushTo(app, mine)).status).toBe(502);
    apns.answers(reason(400, "BadCollapseId"));
    const refused = await pushTo(app, mine);
    expect(refused.status).toBe(502);
    expect(refused.body.error).toBe("Apple refused the push: BadCollapseId.");
    expect(await rows()).toHaveLength(1);
  });

  it("makes a new provider token after Apple refuses one", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    await pushTo(app, mine);
    apns.answers(reason(403, "ExpiredProviderToken"));
    expect((await pushTo(app, mine)).status).toBe(502);
    apns.answers(() => new Response(null, { status: 200 }));
    // A second later: a token made now has another iat.
    app.time.advance(1000);
    await pushTo(app, mine);
    const tokens = apns.sent.map((sent) => sent.headers.get("authorization"));
    expect(tokens[1]).toBe(tokens[0]);
    expect(tokens[2]).not.toBe(tokens[1]);
  });

  it("limits the pushes to one phone", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    await app.counted(`pushes:minute:${mine.pushId}`, 30);
    expect((await pushTo(app, mine)).status).toBe(429);
    await app.counted(`pushes:minute:${mine.pushId}`, 0);
    await app.counted(`pushes:day:${mine.pushId}`, 1000);
    expect((await pushTo(app, mine)).status).toBe(429);
    expect(apns.sent).toEqual([]);
  });
});

describe("the relay", () => {
  it("answers 503 until it has the APNs key and PUSH_SECRET_KEY", async () => {
    for (const missing of [{ APNS_KEY: undefined }, { APNS_KEY_ID: "" }, { APNS_TEAM_ID: undefined }]) {
      const { app, apns } = relay(missing);
      const mine = await phone(app);
      expect((await pushTo(app, mine)).status).toBe(503);
      expect(apns.sent).toEqual([]);
    }
    const { app } = relay({ PUSH_SECRET_KEY: "too short" });
    expect((await register(app)).status).toBe(503);
    expect((await app.raw("DELETE", `/v1/push/devices/${"a".repeat(24)}`)).status).toBe(503);
    await env.DB.prepare("DELETE FROM push_devices").run();
    const off = relay({ APNS_TOPICS: "" });
    expect((await register(off.app)).status).toBe(503);
    expect(await rows()).toEqual([]);
  });

  it("logs no token, secret, pushId or sealed blob", async () => {
    const lines: string[] = [];
    for (const method of ["log", "warn", "error", "info", "debug"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => void lines.push(args.map(String).join(" ")));
    }
    const { app, apns } = relay({ MAX_PUSH_DEVICES: "1" });
    const mine = await phone(app);
    await pushTo(app, mine, { collapse: "job-7f3a" });
    await pushTo(app, mine, {}, "wrong");
    apns.answers(reason(400, "BadCollapseId"));
    await pushTo(app, mine);
    apns.answers(reason(410, "Unregistered"));
    await pushTo(app, mine);
    await phone(app);
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      for (const secret of [TOKEN, mine.pushSecret, mine.pushId, SEALED, "job-7f3a"]) expect(line).not.toContain(secret);
    }
  });
});
