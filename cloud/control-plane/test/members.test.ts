import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Mac, testApp } from "./helpers";

// A members-only instance (MEMBER_WORKSPACES, docs/remote-access.md, "Run your own control
// plane"): only accounts of the listed Google Workspaces sign in and get a Mac's hostname, and only
// such an instance may put those hostnames under the product's own domain.
const MEMBERS = { MEMBER_WORKSPACES: "deskree.com" };

describe("a members-only instance", () => {
  it("lets a member Workspace's Google account register a Mac", async () => {
    const app = testApp({}, MEMBERS);
    const registered = await app.registerWithGoogle(await Mac.make(), "member-1", "wellington@deskree.com", "deskree.com");
    expect(registered.status).toBe(201);
  });

  it("tells a Mac what it may sign in with, and shows the account it signed in with", async () => {
    const open = await testApp().raw("GET", "/v1/auth");
    expect(open.body).toEqual({ providers: ["apple", "google"], workspaces: [] });
    const app = testApp({}, MEMBERS);
    expect((await app.raw("GET", "/v1/auth")).body).toEqual({ providers: ["google"], workspaces: ["deskree.com"] });
    const registered = await app.registerWithGoogle(await Mac.make(), "member-3", "carol@deskree.com", "deskree.com");
    expect(registered.body.installation.account).toEqual({ provider: "google", domain: "deskree.com" });
  });

  it("refuses Apple, which has no Workspace, before it starts", async () => {
    const app = testApp({}, MEMBERS);
    const { started } = await app.startSignIn(await Mac.make());
    expect(started.status).toBe(403);
    expect(started.body.error).toBe("This Oby is for deskree.com accounts only: sign in with Google.");
  });

  it("sends a personal Google account and another company's back failed, and keeps no account", async () => {
    for (const [sub, email, hd] of [
      ["personal-1", "someone@gmail.com", null],
      ["outsider-1", "someone@evil.example", "evil.example"],
      // An address on the member's domain without its Workspace: `hd` alone shows membership.
      ["lookalike-1", "someone@deskree.com", null],
    ] as const) {
      const app = testApp({}, MEMBERS);
      const mac = await Mac.make();
      const { started, state, nonce } = await app.startSignIn(mac, {}, "google");
      expect(started.status).toBe(201);
      const back = await app.callback({ state, id_token: await app.google.token(app.googleClaims(nonce, sub, email, hd)) }, {}, "google");
      expect(new URL(back.headers.get("Location") ?? "about:blank").host, sub).toBe("failed");
      expect(await env.DB.prepare("SELECT sub FROM users WHERE sub = ?1").bind(`google:${sub}`).first()).toBeNull();
    }
  });

  it("refuses to register an account whose Workspace stopped being a member after it signed in", async () => {
    const open = testApp();
    const mac = await Mac.make();
    const { state, nonce } = await open.startSignIn(mac, {}, "google");
    const back = await open.callback({ state, id_token: await open.google.token(open.googleClaims(nonce, "former-1", "x@other.example", "other.example")) }, {}, "google");
    const code = new URL(back.headers.get("Location") ?? "about:blank").searchParams.get("code") ?? "";
    // The same database, now members-only.
    const members = testApp({}, MEMBERS);
    const refused = await members.call(mac, "POST", "/v1/installations", { name: "Mac", platform: "macos", signIn: state, signInCode: code });
    expect(refused.status).toBe(403);
    expect(refused.body.error).toBe("This Oby is for deskree.com accounts only.");
  });

  it("may share the product's domain; an open instance may not", async () => {
    const sharing = { PRODUCT_DOMAIN: "deskree.com", DEVICE_DOMAIN: "deskree.com" };
    const open = testApp({}, sharing);
    open.tunnels.zone = "deskree.com";
    const openMac = await Mac.make();
    expect((await open.register(openMac)).status).toBe(201);
    const refused = await open.call(openMac, "POST", "/v1/installations/self/endpoint");
    expect(refused.status).toBe(503);
    expect(refused.body.error).toMatch(/unless MEMBER_WORKSPACES makes this instance members-only/);

    const members = testApp({}, { ...sharing, ...MEMBERS });
    members.tunnels.zone = "deskree.com";
    const mac = await Mac.make();
    expect((await members.registerWithGoogle(mac, "member-2", "sangam@deskree.com", "deskree.com")).status).toBe(201);
    const made = await members.call(mac, "POST", "/v1/installations/self/endpoint");
    expect(made.status).toBe(201);
    expect(made.body.endpoint.hostname).toMatch(/^oby-[a-z0-9]{20}\.deskree\.com$/);
  });
});
