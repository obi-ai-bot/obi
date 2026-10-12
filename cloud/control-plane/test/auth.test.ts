import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MailSetupError } from "../src/email";
import { DAY, MINUTE, testApp } from "./helpers";

describe("sign-in by email code", () => {
  it("emails a six-digit code and signs in with it", async () => {
    const app = testApp();
    const asked = await app.call("POST", "/v1/auth/otp/request", { email: "Well@Example.com " });
    expect(asked.status).toBe(202);
    expect(asked.body).toEqual({ sent: true });
    expect(app.mail.sent).toHaveLength(1);
    expect(app.mail.sent[0]?.to).toBe("well@example.com");
    expect(app.mail.sent[0]?.subject).toBe("Your Oby sign-in code");
    const code = app.mail.lastCode();

    const verified = await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code });
    expect(verified.status).toBe(201);
    expect(verified.headers.get("Cache-Control")).toBe("no-store");
    expect(verified.body.token).toMatch(/^oby_session_[A-Za-z0-9_-]{43}$/);
    expect(verified.body.user.email).toBe("well@example.com");

    const me = await app.call("GET", "/v1/me", undefined, verified.body.token);
    expect(me.status).toBe(200);
    expect(me.body.user).toEqual(verified.body.user);

    // Nothing in the database holds the token or the code: only their hashes.
    const sessions = await env.DB.prepare("SELECT token_hash FROM sessions").all<{ token_hash: string }>();
    expect(sessions.results.map((row) => row.token_hash)).not.toContain(verified.body.token);
    const codes = await env.DB.prepare("SELECT code_hash, used_at FROM otp_codes").all<{ code_hash: string; used_at: string | null }>();
    expect(codes.results[0]?.code_hash).not.toContain(code);
    expect(codes.results[0]?.used_at).not.toBeNull();
  });

  it("a code works once", async () => {
    const app = testApp();
    await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    const code = app.mail.lastCode();
    expect((await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code })).status).toBe(201);
    const again = await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code });
    expect(again.status).toBe(401);
    expect(again.body.error).toBe("That code has expired. Ask for a new one.");
  });

  it("a wrong code counts a try, and five tries use the code up", async () => {
    const app = testApp();
    await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    const code = app.mail.lastCode();
    const wrong = code === "000000" ? "000001" : "000000";
    for (let i = 0; i < 5; i++) {
      const answer = await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code: wrong });
      expect(answer.status).toBe(401);
      expect(answer.body.error).toBe("That code isn't right.");
    }
    const spent = await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code });
    expect(spent.status).toBe(401);
    expect(spent.body.error).toBe("Too many tries with that code. Ask for a new one.");
  });

  it("a code expires after ten minutes", async () => {
    const app = testApp();
    await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    const code = app.mail.lastCode();
    app.time.advance(11 * MINUTE);
    const late = await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code });
    expect(late.status).toBe(401);
    expect(late.body.error).toBe("That code has expired. Ask for a new one.");
  });

  it("a newer code replaces the one before", async () => {
    const app = testApp();
    await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    const first = app.mail.lastCode();
    await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    const second = app.mail.lastCode();
    if (first !== second) {
      expect((await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code: first })).status).toBe(401);
    }
    expect((await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code: second })).status).toBe(201);
  });

  it("allows five codes per email in fifteen minutes", async () => {
    const app = testApp();
    for (let i = 0; i < 5; i++) {
      expect((await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" })).status).toBe(202);
    }
    const sixth = await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    expect(sixth.status).toBe(429);
    expect(sixth.body.error).toMatch(/^Too many codes were asked for that email\. Try again in \d+ minutes?\.$/);
    expect(Number(sixth.headers.get("Retry-After"))).toBeGreaterThan(0);
    // Another email from the same place is fine.
    expect((await app.call("POST", "/v1/auth/otp/request", { email: "other@example.com" })).status).toBe(202);
    app.time.advance(15 * MINUTE);
    expect((await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" })).status).toBe(202);
  });

  it("allows twenty codes per address in an hour", async () => {
    const app = testApp();
    const from = { "CF-Connecting-IP": "203.0.113.7" };
    for (let i = 0; i < 20; i++) {
      expect((await app.call("POST", "/v1/auth/otp/request", { email: `person${i}@example.com` }, undefined, from)).status).toBe(202);
    }
    const more = await app.call("POST", "/v1/auth/otp/request", { email: "person21@example.com" }, undefined, from);
    expect(more.status).toBe(429);
    expect(more.body.error).toMatch(/^Too many codes were asked for from this network\./);
    const elsewhere = await app.call("POST", "/v1/auth/otp/request", { email: "person21@example.com" }, undefined, { "CF-Connecting-IP": "203.0.113.8" });
    expect(elsewhere.status).toBe(202);
  });

  it("in development, the code comes back instead of an email", async () => {
    const app = testApp({}, { DEV_ECHO_OTP: "true" });
    const asked = await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    expect(asked.status).toBe(202);
    expect(asked.body.devCode).toMatch(/^\d{6}$/);
    expect(asked.headers.get("Cache-Control")).toBe("no-store");
    expect(app.mail.sent).toHaveLength(0);
    expect((await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code: asked.body.devCode })).status).toBe(201);
  });

  it("without an email sender, it says what to set", async () => {
    const app = testApp();
    app.mail.failure = new MailSetupError("No email sender is set up: wrangler secret put RESEND_API_KEY, or DEV_ECHO_OTP=true in .dev.vars.");
    const asked = await app.call("POST", "/v1/auth/otp/request", { email: "well@example.com" });
    expect(asked.status).toBe(503);
    expect(asked.body.error).toContain("RESEND_API_KEY");
  });

  it("signing out ends the session", async () => {
    const app = testApp();
    const session = await app.signIn();
    expect((await app.call("POST", "/v1/auth/signout", undefined, session)).status).toBe(204);
    const me = await app.call("GET", "/v1/me", undefined, session);
    expect(me.status).toBe(401);
    expect(me.body.error).toBe("Sign in again.");
  });

  it("a session lasts ninety days", async () => {
    const app = testApp();
    const session = await app.signIn();
    app.time.advance(89 * DAY);
    expect((await app.call("GET", "/v1/me", undefined, session)).status).toBe(200);
    app.time.advance(2 * DAY);
    expect((await app.call("GET", "/v1/me", undefined, session)).status).toBe(401);
  });

  it("refuses what isn't a session", async () => {
    const app = testApp();
    expect((await app.call("GET", "/v1/me")).status).toBe(401);
    expect((await app.call("GET", "/v1/me", undefined, "oby_session_nope")).status).toBe(401);
    const session = await app.signIn();
    const registered = await app.register(session);
    // An installation's credential opens the installation's calls, not the user's.
    expect((await app.call("GET", "/v1/me", undefined, registered.body.credential)).status).toBe(401);
    expect((await app.call("GET", "/v1/installations", undefined, registered.body.credential)).status).toBe(401);
  });

  it("checks the email, the code and the body", async () => {
    const app = testApp();
    expect((await app.call("POST", "/v1/auth/otp/request", { email: "nope" })).status).toBe(422);
    expect((await app.call("POST", "/v1/auth/otp/request", "not json")).status).toBe(400);
    expect((await app.call("POST", "/v1/auth/otp/verify", { email: "well@example.com", code: "12" })).status).toBe(422);
    expect((await app.call("GET", "/v1/nothing")).status).toBe(404);
    expect((await app.call("GET", "/v1/health")).body).toEqual({ ok: true });
  });
});
