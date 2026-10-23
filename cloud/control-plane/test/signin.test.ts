import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { KeyCache, TokenError, sha256Hex, verifyAppleToken } from "../src/signin";
import { FakeIdP, MINUTE, Mac, testApp } from "./helpers";

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
      redirect_uri: "https://oby-control.oby.test/v1/auth/apple/callback",
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
    const other = await FakeIdP.make();
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

describe("Sign in with Google", () => {
  /// Signs `mac` in with Google with `token(nonce)`; the callback's Location and the state.
  async function google(app: ReturnType<typeof testApp>, mac: Mac, token: (nonce: string) => Promise<string>, ip = "198.51.100.1") {
    const { started, state, nonce } = await app.startSignIn(mac, { "CF-Connecting-IP": ip }, "google");
    expect(started.status).toBe(201);
    const back = await app.callback({ state, id_token: await token(nonce) }, { "CF-Connecting-IP": ip }, "google");
    return { state, location: back.headers.get("Location") ?? "" };
  }

  it("starts with Google's authorization URL: the ID token by form_post, openid and email, a state and a nonce kept only as a hash", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { started, state, nonce } = await app.startSignIn(mac, {}, "google");
    expect(started.status).toBe(201);
    const url = new URL(started.body.url);
    expect(`${url.origin}${url.pathname}`).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: "1234-oby.apps.googleusercontent.com",
      redirect_uri: "https://oby-control.oby.test/v1/auth/google/callback",
      response_type: "id_token",
      scope: "openid email",
      prompt: "select_account",
      response_mode: "form_post",
      state,
      nonce,
    });
    const row = await env.DB.prepare("SELECT * FROM sign_ins").first<{ public_key: string; nonce_hash: string; provider: string }>();
    expect(row).toMatchObject({ public_key: mac.publicKey, nonce_hash: await sha256Hex(nonce), provider: "google" });
  });

  it("binds a Google account, apart from an Apple account with the same sub, keeping its Workspace domain and never its email", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { state, location } = await google(app, mac, (nonce) => app.google.token(app.googleClaims(nonce, "000777.me")));
    expect(location).toMatch(new RegExp(`^oby-signin://done\\?state=${state}&code=[A-Za-z0-9_-]{43}$`));
    const code = new URL(location).searchParams.get("code") ?? "";
    const registered = await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state, signInCode: code });
    expect(registered.status).toBe(201);
    // The same sub at Apple is another account, with Macs of its own.
    await app.register(await Mac.make(), "Apple Mac", {}, "000777.me");
    const users = await env.DB.prepare("SELECT * FROM users ORDER BY provider").all<Record<string, unknown>>();
    expect(users.results.map(({ created_at, ...user }) => user)).toEqual([
      { sub: "000777.me", provider: "apple", workspace_domain: null, email_domain: null, limit_domain: null },
      { sub: "google:000777.me", provider: "google", workspace_domain: "deskree.com", email_domain: "deskree.com", limit_domain: "deskree.com" },
    ]);
    expect(JSON.stringify(users.results)).not.toContain("someone@");
    const owners = await env.DB.prepare("SELECT user_sub FROM installations ORDER BY name").all<{ user_sub: string }>();
    expect(owners.results.map((row) => row.user_sub)).toEqual(["000777.me", "google:000777.me"]);
  });

  it("keeps the Workspace's domain apart from the email's: no hd, no Workspace domain; takes Google's other issuer spelling", async () => {
    const app = testApp();
    const { location } = await google(app, await Mac.make(), (nonce) => app.google.token({ ...app.googleClaims(nonce, "123456789", "Alice@Deskree.com", null), iss: "accounts.google.com" }));
    expect(location).toMatch(/^oby-signin:\/\/done\?/);
    // A personal Google account on a company address: its email's domain, never the Workspace's.
    expect(await env.DB.prepare("SELECT workspace_domain, email_domain, limit_domain FROM users WHERE sub = 'google:123456789'").first()).toEqual({ workspace_domain: null, email_domain: "deskree.com", limit_domain: "deskree.com" });
    // A Workspace account whose address is on another of its domains: both, as they are.
    // A Workspace on a subdomain, with an address on another domain: its limits go by its registrable domain.
    const { location: other } = await google(app, await Mac.make(), (nonce) => app.google.token(app.googleClaims(nonce, "987654321", "bob@deskree.dev", "eng.deskree.co.uk")));
    expect(other).toMatch(/^oby-signin:\/\/done\?/);
    expect(await env.DB.prepare("SELECT workspace_domain, email_domain, limit_domain FROM users WHERE sub = 'google:987654321'").first()).toEqual({
      workspace_domain: "eng.deskree.co.uk",
      email_domain: "deskree.dev",
      limit_domain: "deskree.co.uk",
    });
  });

  it("refuses a token that doesn't check out, and the sign-in stays unusable", async () => {
    const app = testApp();
    const other = await FakeIdP.make("google-test-1");
    const claims = (nonce: string) => app.googleClaims(nonce, "000777.me");
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const cases: [string, (nonce: string) => Promise<string>][] = [
      ["bad signature", async (nonce) => app.google.token(claims(nonce), app.google.kid, other.pair.privateKey)],
      ["Apple's key", async (nonce) => app.apple.token(claims(nonce), app.google.kid)],
      ["wrong aud", async (nonce) => app.google.token({ ...claims(nonce), aud: "someone-else.apps.googleusercontent.com" })],
      ["Apple's aud", async (nonce) => app.google.token({ ...claims(nonce), aud: env.APPLE_CLIENT_ID })],
      ["wrong iss", async (nonce) => app.google.token({ ...claims(nonce), iss: "https://appleid.apple.com" })],
      ["expired", async (nonce) => app.google.token({ ...claims(nonce), exp: seconds - 1 })],
      ["issued long ago", async (nonce) => app.google.token({ ...claims(nonce), iat: seconds - 3600 })],
      ["another nonce", async () => app.google.token(claims("not-the-nonce"))],
      ["unverified email", async (nonce) => app.google.token({ ...claims(nonce), email_verified: false })],
      ["email_verified as text", async (nonce) => app.google.token({ ...claims(nonce), email_verified: "true" })],
      ["no email", async (nonce) => app.google.token({ ...claims(nonce), email: undefined })],
      ["an email with no domain", async (nonce) => app.google.token({ ...claims(nonce), email: "someone" })],
      ["an hd that isn't a domain", async (nonce) => app.google.token({ ...claims(nonce), hd: "not a domain" })],
      ["no sub", async (nonce) => app.google.token({ ...claims(nonce), sub: undefined })],
      ["a colon in sub", async (nonce) => app.google.token({ ...claims(nonce), sub: "google:1" })],
      ["unknown kid", async (nonce) => app.google.token(claims(nonce), "not-googles-kid")],
    ];
    for (const [i, [what, token]] of cases.entries()) {
      const mac = await Mac.make();
      const { state, location } = await google(app, mac, token, `10.${i}.0.1`);
      expect(location, what).toBe(`oby-signin://failed?state=${state}`);
      expect((await app.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state })).status, what).toBe(403);
    }
    expect(await env.DB.prepare("SELECT count(*) AS n FROM users").first("n")).toBe(0);
  });

  it("takes a sign-in's result once: a replayed callback fails", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const { state, nonce } = await app.startSignIn(mac, {}, "google");
    const fields = { state, id_token: await app.google.token(app.googleClaims(nonce, "000777.me")) };
    expect((await app.callback(fields, {}, "google")).headers.get("Location")).toMatch(new RegExp(`^oby-signin://done\\?state=${state}&code=`));
    expect((await app.callback(fields, {}, "google")).headers.get("Location")).toBe(`oby-signin://failed?state=${state}`);
    const replayed = { state, id_token: await app.google.token(app.googleClaims(nonce, "000888.attacker")) };
    expect((await app.callback(replayed, {}, "google")).headers.get("Location")).toBe(`oby-signin://failed?state=${state}`);
    expect(await env.DB.prepare("SELECT sub FROM sign_ins WHERE state = ?1").bind(state).first("sub")).toBe("google:000777.me");
  });

  it("finishes a sign-in only at the provider it was started for", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const atApple = await app.startSignIn(mac);
    const googleToken = await app.google.token(app.googleClaims(atApple.nonce, "000777.me"));
    expect((await app.callback({ state: atApple.state, id_token: googleToken }, {}, "google")).headers.get("Location")).toBe(`oby-signin://failed?state=${atApple.state}`);
    const atGoogle = await app.startSignIn(mac, {}, "google");
    const appleToken = await app.apple.token(app.claims(atGoogle.nonce, "000777.me"));
    expect((await app.callback({ state: atGoogle.state, id_token: appleToken })).headers.get("Location")).toBe(`oby-signin://failed?state=${atGoogle.state}`);
  });

  it("says when Sign in with Google isn't set up", async () => {
    const app = testApp({}, { GOOGLE_CLIENT_ID: "" });
    const started = await app.call(await Mac.make(), "POST", "/v1/auth/google/start");
    expect(started.status).toBe(503);
    expect(started.body.error).toBe("Sign in with Google isn't set up: set GOOGLE_CLIENT_ID in wrangler.jsonc.");
  });
});

describe("Apple's keys", () => {
  it("are kept, and fetched again for an unknown kid at most once a minute", async () => {
    const apple = await FakeIdP.make("k1");
    let now = new Date("2026-10-12T12:00:00.000Z");
    const cache = new KeyCache(apple, () => now);
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
    const apple = await FakeIdP.make("k1");
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
    const cache = new KeyCache({ keys: () => answers[asked++]!() }, () => now);
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
    const cache = new KeyCache({ keys: async () => { throw new TypeError("network down"); } }, () => new Date());
    expect(await cache.key("k1")).toBeUndefined();
  });

  it("refuse a token that isn't RS256", async () => {
    const apple = await FakeIdP.make("k1");
    const cache = new KeyCache(apple, () => new Date());
    const encode = (value: unknown) => btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const unsigned = `${encode({ alg: "none", kid: "k1" })}.${encode({ sub: "x" })}.`;
    await expect(verifyAppleToken(unsigned, cache, "aud", "hash", new Date())).rejects.toThrow(TokenError);
  });
});
