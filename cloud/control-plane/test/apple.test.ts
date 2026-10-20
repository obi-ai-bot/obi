import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { AppleKeyCache, AppleTokenError, sha256Hex, verifyAppleToken } from "../src/apple";
import { FakeApple, MINUTE, Mac, testApp } from "./helpers";

describe("Sign in with Apple", () => {
  it("starts with Apple's authorization URL: no scope, form_post, a state and a nonce kept only as a hash", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { started, state, nonce } = await app.startSignIn(mac);
    expect(started.status).toBe(201);
    const url = new URL(started.body.url);
    expect(`${url.origin}${url.pathname}`).toBe("https://appleid.apple.com/auth/authorize");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: "com.deskree.oby.signin.test",
      redirect_uri: "https://oby-control.tetrix.pro/v1/auth/apple/callback",
      response_type: "code id_token",
      response_mode: "form_post",
      state,
      nonce,
    });
    expect(started.body.state).toBe(state);
    const row = await env.DB.prepare("SELECT * FROM sign_ins").first<{ public_key: string; nonce_hash: string }>();
    expect(row?.public_key).toBe(mac.publicKey);
    expect(row?.nonce_hash).toBe(await sha256Hex(nonce));
    expect(JSON.stringify(row)).not.toContain(nonce);
  });

  it("sends the browser back to the Mac, and binds the account to that sign-in", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { state, nonce } = await app.startSignIn(mac);
    const back = await app.callback({ state, code: "c", id_token: await app.apple.token(app.claims(nonce, "000777.me")) });
    expect(back.status).toBe(303);
    expect(back.headers.get("Location")).toMatch(new RegExp(`^oby-signin://done\\?state=${state}&code=[A-Za-z0-9_-]{43}$`));
    expect((await env.DB.prepare("SELECT sub FROM sign_ins WHERE state = ?1").bind(state).first<{ sub: string }>())?.sub).toBe("000777.me");
  });

  it("refuses a token that doesn't check out, and the sign-in stays unusable", async () => {
    const app = testApp();
    const other = await FakeApple.make();
    const cases: [string, (nonce: string) => Promise<string>][] = [
      ["bad signature", async (nonce) => app.apple.token(app.claims(nonce, "000777.me"), app.apple.kid, other.pair.privateKey)],
      ["wrong aud", async (nonce) => app.apple.token({ ...app.claims(nonce, "000777.me"), aud: "com.someone.else" })],
      ["wrong iss", async (nonce) => app.apple.token({ ...app.claims(nonce, "000777.me"), iss: "https://evil.example" })],
      ["expired", async (nonce) => app.apple.token({ ...app.claims(nonce, "000777.me"), exp: Math.floor(app.time.now().getTime() / 1000) - 1 })],
      ["issued in the future", async (nonce) => app.apple.token({ ...app.claims(nonce, "000777.me"), iat: Math.floor(app.time.now().getTime() / 1000) + 600 })],
      ["issued long ago", async (nonce) => app.apple.token({ ...app.claims(nonce, "000777.me"), iat: Math.floor(app.time.now().getTime() / 1000) - 3600 })],
      ["another nonce", async () => app.apple.token(app.claims("not-the-nonce", "000777.me"))],
      ["no sub", async (nonce) => app.apple.token({ ...app.claims(nonce, "x"), sub: undefined })],
      ["unknown kid", async (nonce) => app.apple.token(app.claims(nonce, "000777.me"), "not-apples-kid")],
      ["not a JWT", async () => "abc.def"],
    ];
    for (const [what, token] of cases) {
      const mac = await Mac.make();
      const { state, nonce } = await app.startSignIn(mac, { "CF-Connecting-IP": `10.${cases.findIndex((c) => c[0] === what)}.0.1` });
      const back = await app.callback({ state, id_token: await token(nonce) });
      expect(back.headers.get("Location"), what).toBe(`oby-signin://failed?state=${state}`);
      expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state })).status, what).toBe(403);
    }
  });

  it("takes a sign-in's result once: a replayed callback, or one cancelled at Apple, fails", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { state, nonce } = await app.startSignIn(mac);
    const fields = { state, id_token: await app.apple.token(app.claims(nonce, "000777.me")) };
    expect((await app.callback(fields)).headers.get("Location")).toMatch(new RegExp(`^oby-signin://done\\?state=${state}&code=`));
    // The same token again, even for another account's sub, changes nothing.
    expect((await app.callback(fields)).headers.get("Location")).toBe(`oby-signin://failed?state=${state}`);
    const replayed = { state, id_token: await app.apple.token(app.claims(nonce, "000888.attacker")) };
    expect((await app.callback(replayed)).headers.get("Location")).toBe(`oby-signin://failed?state=${state}`);
    expect((await env.DB.prepare("SELECT sub FROM sign_ins WHERE state = ?1").bind(state).first<{ sub: string }>())?.sub).toBe("000777.me");
    // The user cancelled: Apple sends an error and no token.
    const cancelled = await app.startSignIn(mac);
    expect((await app.callback({ state: cancelled.state, error: "user_cancelled_authorize" })).headers.get("Location")).toBe(`oby-signin://failed?state=${cancelled.state}`);
    // A state that isn't Oby's is refused outright.
    expect((await app.callback({ state: "made-up", id_token: "x" })).status).toBe(400);
    // Too late: a sign-in lasts ten minutes.
    const late = await app.startSignIn(mac);
    app.time.advance(11 * MINUTE);
    const lateToken = await app.apple.token(app.claims(late.nonce, "000777.me"));
    expect((await app.callback({ state: late.state, id_token: lateToken })).headers.get("Location")).toBe(`oby-signin://failed?state=${late.state}`);
  });

  it("says when Sign in with Apple isn't set up", async () => {
    const app = testApp({}, { APPLE_CLIENT_ID: "" });
    const started = await app.call(await Mac.make(), "POST", "/v1/auth/apple/start");
    expect(started.status).toBe(503);
    expect(started.body.error).toBe("Sign in with Apple isn't set up: set APPLE_CLIENT_ID in wrangler.jsonc.");
  });

  it("limits sign-ins started per network", async () => {
    const app = testApp();
    await app.counted("sign-ins:address:203.0.113.9", 30);
    const busy = await app.call(await Mac.make(), "POST", "/v1/auth/apple/start", undefined, { "CF-Connecting-IP": "203.0.113.9" });
    expect(busy.status).toBe(429);
  });
});

describe("Apple's keys", () => {
  it("are kept, and fetched again for an unknown kid at most once a minute", async () => {
    const apple = await FakeApple.make("k1");
    let now = new Date("2026-10-12T12:00:00.000Z");
    const cache = new AppleKeyCache(apple, () => now);
    expect((await cache.key("k1"))?.kid).toBe("k1");
    expect(await cache.key("k1")).toBeDefined();
    expect(apple.fetches).toBe(1);
    expect(await cache.key("rotated")).toBeUndefined();
    expect(await cache.key("rotated")).toBeUndefined();
    expect(apple.fetches).toBe(1);
    now = new Date(now.getTime() + 61_000);
    expect(await cache.key("rotated")).toBeUndefined();
    expect(apple.fetches).toBe(2);
    // A day later they're fetched again whatever the kid.
    now = new Date(now.getTime() + 25 * 3_600_000);
    await cache.key("k1");
    expect(apple.fetches).toBe(3);
  });

  it("aren't lost to a bad answer, and back off while Apple is down", async () => {
    const apple = await FakeApple.make("k1");
    const good = await apple.keys();
    const answers: (() => Promise<JsonWebKey[]>)[] = [
      async () => good,
      async () => ({ error: "maintenance" }) as unknown as JsonWebKey[],
      async () => [{ kid: "k2", kty: "RSA" }],
      async () => {
        throw new TypeError("network down");
      },
      async () => good,
    ];
    let asked = 0;
    let now = new Date("2026-10-12T12:00:00.000Z");
    const cache = new AppleKeyCache({ keys: () => answers[asked++]!() }, () => now);
    const later = (seconds: number) => {
      now = new Date(now.getTime() + seconds * 1000);
    };
    expect((await cache.key("k1"))?.kid).toBe("k1");
    // A day on, a 200 with no keys: the kept keys stay, and the next try waits.
    later(25 * 3600);
    expect((await cache.key("k1"))?.kid).toBe("k1");
    expect(asked).toBe(2);
    later(30);
    await cache.key("k1");
    expect(asked).toBe(2);
    // A minute on, keys with no modulus: still the kept ones; then two minutes of waiting.
    later(31);
    expect((await cache.key("k1"))?.kid).toBe("k1");
    expect(asked).toBe(3);
    later(90);
    await cache.key("k1");
    expect(asked).toBe(3);
    // The network fails: four minutes of waiting next.
    later(31);
    expect((await cache.key("k1"))?.kid).toBe("k1");
    expect(asked).toBe(4);
    later(200);
    await cache.key("k1");
    expect(asked).toBe(4);
    later(41);
    expect((await cache.key("k1"))?.kid).toBe("k1");
    expect(asked).toBe(5);
  });

  it("with none kept and Apple down, refuse the token", async () => {
    const cache = new AppleKeyCache({ keys: async () => { throw new TypeError("network down"); } }, () => new Date());
    expect(await cache.key("k1")).toBeUndefined();
  });

  it("refuse a token that isn't RS256", async () => {
    const apple = await FakeApple.make("k1");
    const cache = new AppleKeyCache(apple, () => new Date());
    const encode = (value: unknown) => btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const unsigned = `${encode({ alg: "none", kid: "k1" })}.${encode({ sub: "x" })}.`;
    await expect(verifyAppleToken(unsigned, cache, "aud", "hash", new Date())).rejects.toThrow(AppleTokenError);
  });
});
