// The sealed push relay (#398), contract v2: an iPhone registers its APNs token (checked with Apple
// first) for a pushId and pushSecret, gives its obid the pushId and the pushKey made from the
// secret, and obid posts sealed alerts signed with the pushKey and stamped with `at`; the relay
// sends Apple the fixed alert with the blob. APNs is a fake here: local workerd has no HTTP/2
// (#27's spike).

import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { forgetToken, sealToken } from "../src/apns";
import { PUSH, PUSH_ALERT, sweep } from "../src/app";
import { sha256Hex } from "../src/signin";
import { fromBase64url } from "../src/tokens";
import { base64url, DAY, MINUTE, testApp } from "./helpers";

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

type Sent = { url: string; headers: Headers; body: string };

/// APNs: what it was sent, and what it answers (200 by default); alerts and token checks apart.
function fakeAPNs() {
  const sent: Sent[] = [];
  let answer: (push: Sent) => Response = () => new Response(null, { status: 200, headers: { "apns-id": "A1" } });
  const send = async (url: string, init: RequestInit) => {
    const push = { url, headers: new Headers(init.headers), body: String(init.body) };
    sent.push(push);
    return answer(push);
  };
  const ofType = (type: string) => sent.filter((push) => push.headers.get("apns-push-type") === type);
  return {
    sent,
    send,
    alerts: () => ofType("alert"),
    checks: () => ofType("background"),
    answers: (next: () => Response) => (answer = next),
    /// `next` for alerts only; token checks still pass.
    answersAlerts: (next: () => Response) => (answer = (push) => (push.headers.get("apns-push-type") === "alert" ? next() : new Response(null, { status: 200 }))),
  };
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
  expect(answer.status, JSON.stringify(answer.body)).toBe(200);
  return answer.body;
}

/// HMAC-SHA-256 under `key`'s raw bytes (its base64url decoded, never its text), base64url: as the
/// phone and obid make them.
async function hmac(key: string, message: string): Promise<string> {
  const imported = await crypto.subtle.importKey("raw", fromBase64url(key)!, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", imported, new TextEncoder().encode(message))));
}

/// What the phone gives obid.
const pushKeyOf = (to: Phone) => hmac(to.pushSecret, "oby push key v1");

const seconds = (app: App) => Math.floor(app.time.now().getTime() / 1000);

/// obid's push: signed with the pushKey, `at` now unless given.
async function pushTo(app: App, to: Phone, fields: Record<string, unknown> = {}, signature?: string) {
  const body = JSON.stringify({ pushId: to.pushId, sealed: SEALED, at: seconds(app), ...fields });
  return app.raw("POST", "/v1/push", body, { "Oby-Push-Mac": signature ?? (await hmac(await pushKeyOf(to), body)) });
}

async function rows() {
  return (await env.DB.prepare("SELECT * FROM push_devices ORDER BY id").all()).results;
}

async function counted() {
  return (await env.DB.prepare("SELECT n FROM push_device_count WHERE id = 1").first<{ n: number }>())?.n;
}

afterEach(() => vi.restoreAllMocks());

describe("registering a phone", () => {
  it("checks the token with Apple, then gives a pushId and a pushSecret; D1 keeps only the id, the token, the topic and sandbox", async () => {
    const { app, apns } = relay();
    const answer = await register(app, { apns: "AB".repeat(32) });
    expect(answer.status).toBe(200);
    expect(answer.headers.get("Cache-Control")).toBe("no-store");
    expect(Object.keys(answer.body).sort()).toEqual(["pushId", "pushSecret"]);
    expect(answer.body.pushId).toMatch(/^[A-Za-z0-9_-]{24}$/);
    expect(answer.body.pushSecret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(await rows()).toEqual([{ id: answer.body.pushId, apns_token: TOKEN, topic: TOPIC, sandbox: 1 }]);
    // The check: a background push with nothing to show, to the phone's own environment.
    expect(apns.sent).toHaveLength(1);
    const [check] = apns.checks();
    expect(check?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(check?.headers.get("apns-topic")).toBe(TOPIC);
    expect(check?.headers.get("apns-priority")).toBe("5");
    expect(check?.headers.has("apns-collapse-id")).toBe(false);
    expect(JSON.parse(check?.body ?? "")).toEqual({ aps: { "content-available": 1 } });
    // Each phone its own.
    const other = await phone(app, { apns: "cd".repeat(32), sandbox: false });
    expect(other.pushId).not.toBe(answer.body.pushId);
    expect(other.pushSecret).not.toBe(answer.body.pushSecret);
    expect(apns.checks()[1]?.url).toBe(`https://api.push.apple.com/3/device/${"cd".repeat(32)}`);
  });

  it("keeps nothing Apple doesn't know, for this app or this environment", async () => {
    for (const unknown of [reason(400, "BadDeviceToken"), reason(410, "Unregistered"), reason(400, "DeviceTokenNotForTopic")]) {
      const { app, apns } = relay();
      apns.answers(unknown);
      expect((await register(app)).status).toBe(422);
      expect(await rows()).toEqual([]);
    }
    const { app, apns } = relay();
    apns.answers(() => {
      throw new TypeError("Network connection lost.");
    });
    expect((await register(app)).status).toBe(502);
    apns.answers(reason(429, "TooManyProviderTokenUpdates"));
    expect((await register(app)).status).toBe(503);
    expect(await rows()).toEqual([]);
    expect(await counted()).toBe(0);
  });

  it("takes JSON only, so a web page can't register for its visitors", async () => {
    const { app, apns } = relay();
    const body = JSON.stringify({ apns: TOKEN, topic: TOPIC, sandbox: true });
    for (const type of ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""]) {
      expect((await app.raw("POST", "/v1/push/devices", body, { "Content-Type": type })).status, type).toBe(415);
    }
    expect((await app.raw("POST", "/v1/push/devices", body, { "Content-Type": "application/json; charset=utf-8" })).status).toBe(200);
    // A browser's preflight gets no CORS answer.
    const preflight = await app.raw("OPTIONS", "/v1/push/devices", undefined, { Origin: "https://example.com", "Access-Control-Request-Method": "POST" });
    expect(preflight.status).toBe(404);
    expect(preflight.headers.get("Access-Control-Allow-Origin")).toBeNull();
    expect(apns.sent).toHaveLength(1);
  });

  it("registers a changed token for the same id and secret, and brings a forgotten one back", async () => {
    const { app, apns } = relay();
    const first = await phone(app);
    const again = await register(app, { ...first, apns: "ef".repeat(40), sandbox: false });
    expect(again.status).toBe(200);
    expect(again.body).toEqual(first);
    expect(await rows()).toEqual([{ id: first.pushId, apns_token: "ef".repeat(40), topic: TOPIC, sandbox: 0 }]);
    expect(apns.checks()).toHaveLength(2);
    // The same token again for the same id: no check.
    expect((await register(app, { ...first, apns: "ef".repeat(40), sandbox: false })).status).toBe(200);
    expect(apns.checks()).toHaveLength(2);
    await env.DB.prepare("DELETE FROM push_devices").run();
    expect((await register(app, first)).body).toEqual(first);
    expect(await rows()).toHaveLength(1);
    expect(await counted()).toBe(1);
  });

  it("refuses a wrong secret, the pushKey and an id it never made with the same answer", async () => {
    const { app } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const answers = [
      await register(app, { pushId: mine.pushId, pushSecret: theirs.pushSecret }),
      await register(app, { pushId: mine.pushId, pushSecret: await pushKeyOf(mine) }),
      await register(app, { pushId: base64url(crypto.getRandomValues(new Uint8Array(18))), pushSecret: mine.pushSecret }),
      await register(app, { pushId: mine.pushId }),
    ];
    for (const answer of answers) {
      expect(answer.status).toBe(401);
      expect(answer.body).toEqual(answers[0]?.body);
    }
    expect((await rows()).map((row) => row.apns_token).sort()).toEqual(["ab".repeat(32), "cd".repeat(32)]);
  });

  it("moves a token another pushId has to the new one", async () => {
    const { app, apns } = relay();
    const old = await phone(app);
    const fresh = await phone(app);
    expect((await rows()).map((row) => row.id)).toEqual([fresh.pushId]);
    expect(await counted()).toBe(1);
    expect((await pushTo(app, old)).status).toBe(410);
    expect((await pushTo(app, fresh)).status).toBe(200);
    expect(apns.alerts()).toHaveLength(1);
  });

  it("refuses what isn't a registration", async () => {
    const { app, apns } = relay();
    for (const fields of [{ apns: "xyz" }, { apns: "ab".repeat(31) }, { apns: "a".repeat(65) }, { apns: "ab".repeat(101) }, { apns: 42 }, { topic: "com.example.other" }, { sandbox: "yes" }, { name: "extra" }]) {
      expect((await register(app, fields)).status, JSON.stringify(fields)).toBe(422);
    }
    expect((await app.raw("POST", "/v1/push/devices", "not json")).status).toBe(400);
    expect((await register(app, { padding: "x".repeat(PUSH.registrationMax) })).status).toBe(413);
    expect(await rows()).toEqual([]);
    expect(apns.sent).toEqual([]);
  });

  it("limits new phones per client, re-registrations per phone and checks per token", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    await app.counted("push:3600:address:198.51.100.7", 30);
    expect((await register(app, { apns: "cd".repeat(32) })).status).toBe(429);
    expect((await register(app, { apns: "cd".repeat(32) }, "203.0.113.9")).status).toBe(200);
    await app.counted(`push:3600:again:${mine.pushId}`, 20);
    expect((await register(app, mine)).status).toBe(429);
    await app.counted(`push:3600:check:${await sha256Hex("ef".repeat(32))}`, 10);
    expect((await register(app, { apns: "ef".repeat(32) }, "203.0.113.10")).status).toBe(429);
    expect(apns.checks()).toHaveLength(2);
  });

  it("keeps the count in one row, and takes no more than MAX_PUSH_DEVICES phones", async () => {
    const { app } = relay({ MAX_PUSH_DEVICES: "2" });
    const mine = await phone(app);
    await phone(app, { apns: "cd".repeat(32) });
    expect(await counted()).toBe(2);
    expect((await register(app, { apns: "ef".repeat(32) })).status).toBe(503);
    // A re-registration isn't a new phone.
    expect((await register(app, { ...mine, apns: "ef".repeat(32) })).status).toBe(200);
    expect(await counted()).toBe(2);
    await app.raw("DELETE", `/v1/push/devices/${mine.pushId}`, undefined, { Authorization: `Bearer ${mine.pushSecret}` });
    expect(await counted()).toBe(1);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM push_devices").first<{ n: number }>())?.n).toBe(1);
  });

  it("forgets a phone that asks with its secret, and only then", async () => {
    const { app } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const forget = (secret: string) => app.raw("DELETE", `/v1/push/devices/${mine.pushId}`, undefined, { Authorization: `Bearer ${secret}` });
    expect((await forget(theirs.pushSecret)).status).toBe(401);
    // obid holds the pushKey only: it can't.
    expect((await forget(await pushKeyOf(mine))).status).toBe(401);
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
    forgetToken();
    const fresh = await apnsKey();
    const apns = fakeAPNs();
    const app = testApp({ apns: apns.send }, secrets(fresh.pem));
    const sandboxed = await phone(app);
    const answer = await pushTo(app, sandboxed, { collapse: "job-7f3a", urgent: true });
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({ ok: true });
    expect(apns.alerts()).toHaveLength(1);
    const [sent] = apns.alerts();
    expect(sent?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(sent?.headers.get("apns-topic")).toBe(TOPIC);
    expect(sent?.headers.get("apns-priority")).toBe("10");
    expect(sent?.headers.get("apns-collapse-id")).toBe("job-7f3a");
    expect(JSON.parse(sent?.body ?? "")).toEqual({ aps: { alert: { title: "Oby", body: "Open Oby to see it." }, "mutable-content": 1, sound: "default" }, sealed: SEALED });
    expect(PUSH_ALERT).toEqual({ title: "Oby", body: "Open Oby to see it." });

    // An ES256 JWT: the key's id, the team, now, signed by the key.
    const [head, claims, signature] = (sent?.headers.get("authorization") ?? "").replace(/^bearer /, "").split(".");
    const decode = (part = "") => JSON.parse(new TextDecoder().decode(fromBase64url(part)!));
    expect(decode(head)).toEqual({ alg: "ES256", kid: "KEY0000001" });
    expect(decode(claims)).toEqual({ iss: "TEAM000001", iat: seconds(app) });
    const signed = new TextEncoder().encode(`${head}.${claims}`);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, fresh.publicKey, fromBase64url(signature ?? "")!, signed)).toBe(true);

    // Not urgent, no collapse id, a phone on production APNs: the same provider token, reused.
    const production = await phone(app, { apns: "cd".repeat(32), sandbox: false });
    expect((await pushTo(app, production)).status).toBe(200);
    const second = apns.alerts()[1];
    expect(second?.url).toBe(`https://api.push.apple.com/3/device/${"cd".repeat(32)}`);
    expect(second?.headers.get("apns-priority")).toBe("5");
    expect(second?.headers.has("apns-collapse-id")).toBe(false);
    expect(apns.sent.every((push) => push.headers.get("authorization") === sent?.headers.get("authorization"))).toBe(true);
    // A new one after 40 minutes.
    app.time.advance(41 * MINUTE);
    await pushTo(app, production);
    expect(apns.alerts()[2]?.headers.get("authorization")).not.toBe(sent?.headers.get("authorization"));
  });

  it("is signed with the pushKey, not the pushSecret, and a wrong MAC or an id never made is 401, sending and counting nothing", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    const theirs = await phone(app, { apns: "cd".repeat(32) });
    const body = JSON.stringify({ pushId: mine.pushId, sealed: SEALED, at: seconds(app) });
    const stranger = { pushId: base64url(crypto.getRandomValues(new Uint8Array(18))), pushSecret: mine.pushSecret };
    const answers = [
      await pushTo(app, mine, {}, await hmac(mine.pushSecret, body)),
      await pushTo(app, mine, {}, await hmac(await pushKeyOf(theirs), body)),
      await pushTo(app, mine, {}, ""),
      await pushTo(app, mine, {}, (await hmac(await pushKeyOf(mine), body)).slice(0, 40)),
      await pushTo(app, mine, {}, `${await hmac(await pushKeyOf(mine), body)}=`),
      await pushTo(app, mine, {}, `${await hmac(await pushKeyOf(mine), body)}AA`),
      await pushTo(app, mine, { urgent: true }, await hmac(await pushKeyOf(mine), body)),
      await pushTo(app, stranger),
    ];
    for (const answer of answers) {
      expect(answer.status).toBe(401);
      expect(answer.body).toEqual(answers[0]?.body);
    }
    expect(apns.alerts()).toEqual([]);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM rate_limits WHERE key LIKE 'push:%:id:%' OR key LIKE 'push:%:token:%'").first<{ n: number }>())?.n).toBe(0);
  });

  it("carries `at`, and is refused more than five minutes from the relay's clock", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    expect((await pushTo(app, mine, { at: seconds(app) - 299 })).status).toBe(200);
    expect((await pushTo(app, mine, { at: seconds(app) + 299 })).status).toBe(200);
    expect((await pushTo(app, mine, { at: seconds(app) - 301 })).status).toBe(401);
    expect((await pushTo(app, mine, { at: seconds(app) + 301 })).status).toBe(401);
    for (const at of [undefined, "now", 1.5]) expect((await pushTo(app, mine, { at })).status, String(at)).toBe(422);
    expect(apns.alerts()).toHaveLength(2);
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
    expect(apns.alerts()).toHaveLength(1);
  });

  it("forgets the phone when Apple says its token is gone", async () => {
    for (const gone of [reason(410, "Unregistered"), reason(400, "BadDeviceToken"), reason(400, "DeviceTokenNotForTopic")]) {
      const { app, apns } = relay();
      const mine = await phone(app);
      apns.answers(gone);
      expect((await pushTo(app, mine)).status).toBe(410);
      expect(await rows()).toEqual([]);
      expect(await counted()).toBe(0);
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
    // The relay's own problem, not the phone's.
    apns.answers(reason(429, "TooManyProviderTokenUpdates"));
    const renewed = await pushTo(app, mine);
    expect(renewed.status).toBe(503);
    expect(renewed.body.error).not.toContain("this phone");
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

  it("limits the pushes to one phone, by pushId and by token", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    await app.counted(`push:60:id:${mine.pushId}`, 30);
    expect((await pushTo(app, mine)).status).toBe(429);
    await app.counted(`push:60:id:${mine.pushId}`, 0);
    await app.counted(`push:86400:id:${mine.pushId}`, 1000);
    expect((await pushTo(app, mine)).status).toBe(429);
    // The same token under a new pushId shares the token's allowance.
    const again = await phone(app);
    await app.counted(`push:60:token:${await sha256Hex(TOKEN)}`, 30);
    expect((await pushTo(app, again)).status).toBe(429);
    expect(apns.alerts()).toEqual([]);
  });

  it("keeps a rate limit's window only as a whole minute or day, and the sweep removes it when it ends", async () => {
    const { app } = relay();
    const mine = await phone(app);
    app.time.advance(17_000);
    expect((await pushTo(app, mine)).status).toBe(200);
    const windows = async () =>
      Object.fromEntries((await env.DB.prepare("SELECT key, window_start FROM rate_limits WHERE key LIKE 'push:%'").all<{ key: string; window_start: number }>()).results.map((row) => [row.key, row.window_start]));
    const kept = await windows();
    const minute = kept[`push:60:id:${mine.pushId}`];
    const day = kept[`push:86400:id:${mine.pushId}`];
    expect(minute).toBe(seconds(app) - (seconds(app) % 60));
    expect(day).toBe(seconds(app) - (seconds(app) % 86_400));
    app.time.advance(MINUTE);
    await sweep(env, app.deps);
    const later = await windows();
    expect(later[`push:60:id:${mine.pushId}`]).toBeUndefined();
    expect(later[`push:60:token:${await sha256Hex(TOKEN)}`]).toBeUndefined();
    expect(later[`push:86400:id:${mine.pushId}`]).toBe(day);
    app.time.advance(DAY);
    await sweep(env, app.deps);
    expect(await windows()).toEqual({});
  });

  it("makes a new provider token after Apple refuses one", async () => {
    const { app, apns } = relay();
    const mine = await phone(app);
    await pushTo(app, mine);
    apns.answers(reason(403, "ExpiredProviderToken"));
    expect((await pushTo(app, mine)).status).toBe(502);
    expect(await env.DB.prepare("SELECT 1 FROM apns_provider_token").first()).toBeNull();
    apns.answers(() => new Response(null, { status: 200 }));
    // A second later: a token made now has another iat.
    app.time.advance(1000);
    await pushTo(app, mine);
    const tokens = apns.alerts().map((sent) => sent.headers.get("authorization"));
    expect(tokens[1]).toBe(tokens[0]);
    expect(tokens[2]).not.toBe(tokens[1]);
  });
});

describe("the keys", () => {
  // A fixed vector for obid and the iPhone to copy, worked out apart from the relay (Python's hmac).
  // Every HMAC key is raw bytes: a pushSecret's or a pushKey's base64url, decoded (32 bytes).
  const VECTOR = {
    pushId: "b2J5LXRlc3QtdmVjdG9yLTAx",
    pushSecret: "7x-XJBtltDkgComjTzh2aougWSW5C4fOPr7MutSocH4",
    pushKey: "vx_9SyYw9p7qPCxR8xHlDF8WlTOsR_LRA67SHhzpTHM",
    body: '{"pushId":"b2J5LXRlc3QtdmVjdG9yLTAx","sealed":"c2VhbGVkLWZvci10aGUtcGhvbmU","collapse":"9f08fd10","urgent":true,"at":1791806400}',
    mac: "EK3ocbR_NCA7i3gJQAGEnXJe2mGFd74zqt190mk1a7s",
  };

  it("match the fixed vector: pushSecret to pushKey, and pushKey and body to Oby-Push-Mac", async () => {
    expect(await hmac(VECTOR.pushSecret, "oby push key v1")).toBe(VECTOR.pushKey);
    expect(await hmac(VECTOR.pushKey, VECTOR.body)).toBe(VECTOR.mac);
    // The relay makes the same: the vector's pushSecret is what it answers for that pushId with
    // this PUSH_SECRET_KEY, and it takes the vector's push at the vector's time.
    const apns = fakeAPNs();
    const app = testApp({ apns: apns.send }, { ...secrets(), PUSH_SECRET_KEY: "oby-test-vector-only-never-a-real-key-00000" });
    expect(seconds(app)).toBe(1791806400);
    const again = await register(app, { pushId: VECTOR.pushId, pushSecret: VECTOR.pushSecret });
    expect(again.status).toBe(200);
    expect(again.body).toEqual({ pushId: VECTOR.pushId, pushSecret: VECTOR.pushSecret });
    const pushed = await app.raw("POST", "/v1/push", VECTOR.body, { "Oby-Push-Mac": VECTOR.mac });
    expect(pushed.status).toBe(200);
    expect(apns.alerts()).toHaveLength(1);
    // The pushKey's text as the HMAC key is refused.
    const imported = await crypto.subtle.importKey("raw", new TextEncoder().encode(VECTOR.pushKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const byText = base64url(new Uint8Array(await crypto.subtle.sign("HMAC", imported, new TextEncoder().encode(VECTOR.body))));
    expect((await app.raw("POST", "/v1/push", VECTOR.body, { "Oby-Push-Mac": byText })).status).toBe(401);
  });
});

describe("the provider token", () => {
  it("is shared through D1, sealed, so every isolate uses the same one", async () => {
    forgetToken();
    const { app, apns } = relay();
    await phone(app);
    const used = apns.sent[0]?.headers.get("authorization")?.replace(/^bearer /, "") ?? "";
    const kept = await env.DB.prepare("SELECT made_at, sealed FROM apns_provider_token").first<{ made_at: number; sealed: string }>();
    expect(kept?.made_at).toBe(seconds(app));
    expect(kept?.sealed).not.toContain(used.split(".")[0]);
    expect(kept?.sealed).not.toContain(used.split(".")[2]);
    // Another isolate, a minute later: D1's token, not a new one.
    forgetToken();
    app.time.advance(MINUTE);
    await phone(app, { apns: "cd".repeat(32) });
    expect(apns.sent[1]?.headers.get("authorization")).toBe(`bearer ${used}`);
  });

  it("is made anew when D1's was made with another key", async () => {
    forgetToken();
    const { app, apns } = relay();
    const other = { keyId: "KEY0000002", teamId: "TEAM000001", pem: key.pem };
    await env.DB.prepare("INSERT INTO apns_provider_token (id, made_at, sealed) VALUES (1, ?1, ?2)")
      .bind(seconds(app), await sealToken("another-push-secret-key-0000000000000000", other, "old.token.here"))
      .run();
    await phone(app);
    expect(apns.sent[0]?.headers.get("authorization")).not.toBe("bearer old.token.here");
    expect(apns.sent[0]?.headers.get("authorization")).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  });
});

describe("the relay", () => {
  it("answers 503 until it has the APNs key and PUSH_SECRET_KEY", async () => {
    for (const missing of [{ APNS_KEY: undefined }, { APNS_KEY_ID: "" }, { APNS_TEAM_ID: undefined }, { PUSH_SECRET_KEY: "too short" }, { APNS_TOPICS: "" }]) {
      const { app, apns } = relay(missing);
      expect((await register(app)).status, JSON.stringify(missing)).toBe(503);
      const made = { pushId: "a".repeat(24), pushSecret: "b".repeat(43) };
      if (!("APNS_TOPICS" in missing)) expect((await pushTo(app, made)).status).toBe(503);
      expect(apns.sent).toEqual([]);
    }
    expect((await relay({ PUSH_SECRET_KEY: "" }).app.raw("DELETE", `/v1/push/devices/${"a".repeat(24)}`)).status).toBe(503);
    expect(await rows()).toEqual([]);
  });

  it("logs no token, secret, key, pushId or sealed blob", async () => {
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
    apns.answers(reason(400, "BadDeviceToken"));
    await register(app);
    apns.answers(() => new Response(null, { status: 200 }));
    await phone(app);
    expect(lines.length).toBeGreaterThan(0);
    const hidden = [TOKEN, mine.pushSecret, await pushKeyOf(mine), mine.pushId, SEALED, "job-7f3a", await sha256Hex(TOKEN)];
    for (const line of lines) for (const secret of hidden) expect(line).not.toContain(secret);
  });
});
