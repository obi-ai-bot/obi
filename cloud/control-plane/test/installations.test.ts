import { describe, expect, it } from "vitest";
import { HOUR, testApp } from "./helpers";

describe("installations", () => {
  it("registers a Mac with a credential of its own", async () => {
    const app = testApp();
    const session = await app.signIn();
    const registered = await app.register(session);
    expect(registered.status).toBe(201);
    expect(registered.headers.get("Cache-Control")).toBe("no-store");
    expect(registered.body.credential).toMatch(/^oby_install_[A-Za-z0-9_-]{43}$/);
    expect(registered.body.installation).toMatchObject({ clientId: "mac-client-0001", name: "Wellington's MacBook Pro", platform: "macos", endpoint: null });

    const listed = await app.call("GET", "/v1/installations", undefined, session);
    expect(listed.status).toBe(200);
    expect(listed.body.installations).toHaveLength(1);
    expect(listed.body.installations[0].id).toBe(registered.body.installation.id);

    const self = await app.call("GET", "/v1/installations/self", undefined, registered.body.credential);
    expect(self.status).toBe(200);
    expect(self.body.installation.id).toBe(registered.body.installation.id);
    // A session token isn't an installation's credential.
    expect((await app.call("GET", "/v1/installations/self", undefined, session)).status).toBe(401);
  });

  it("the same Mac again keeps its installation and gets a fresh credential", async () => {
    const app = testApp();
    const session = await app.signIn();
    const first = await app.register(session);
    const again = await app.register(session, "mac-client-0001", "Renamed MacBook");
    expect(again.status).toBe(200);
    expect(again.body.installation.id).toBe(first.body.installation.id);
    expect(again.body.installation.name).toBe("Renamed MacBook");
    expect(again.body.credential).not.toBe(first.body.credential);
    expect((await app.call("GET", "/v1/installations/self", undefined, first.body.credential)).status).toBe(401);
    expect((await app.call("GET", "/v1/installations/self", undefined, again.body.credential)).status).toBe(200);
    expect((await app.call("GET", "/v1/installations", undefined, session)).body.installations).toHaveLength(1);
  });

  it("rotating the credential revokes the last", async () => {
    const app = testApp();
    const session = await app.signIn();
    const registered = await app.register(session);
    const rotated = await app.call("POST", `/v1/installations/${registered.body.installation.id}/credential`, undefined, session);
    expect(rotated.status).toBe(200);
    expect(rotated.body.credential).toMatch(/^oby_install_/);
    expect(rotated.body.credential).not.toBe(registered.body.credential);
    const old = await app.call("GET", "/v1/installations/self", undefined, registered.body.credential);
    expect(old.status).toBe(401);
    expect(old.body.error).toBe("This credential was revoked. Turn remote access on again.");
    expect((await app.call("GET", "/v1/installations/self", undefined, rotated.body.credential)).status).toBe(200);
  });

  it("another user's installation is as good as none", async () => {
    const app = testApp();
    const owner = await app.signIn("owner@example.com");
    const other = await app.signIn("other@example.com");
    const registered = await app.register(owner);
    const id = registered.body.installation.id;
    expect((await app.call("GET", "/v1/installations", undefined, other)).body.installations).toEqual([]);
    expect((await app.call("POST", `/v1/installations/${id}/credential`, undefined, other)).status).toBe(404);
    expect((await app.call("DELETE", `/v1/installations/${id}`, undefined, other)).status).toBe(404);
    // Still the owner's, with its credential intact.
    expect((await app.call("GET", "/v1/installations/self", undefined, registered.body.credential)).status).toBe(200);
    expect((await app.call("GET", "/v1/installations", undefined, owner)).body.installations).toHaveLength(1);
  });

  it("removing an installation revokes its credential and signs that Mac out", async () => {
    const app = testApp();
    const onTheMac = await app.signIn();
    const onThePhone = await app.signIn();
    const registered = await app.register(onTheMac);
    const removed = await app.call("DELETE", `/v1/installations/${registered.body.installation.id}`, undefined, onThePhone);
    expect(removed.status).toBe(204);
    expect((await app.call("GET", "/v1/installations/self", undefined, registered.body.credential)).status).toBe(401);
    expect((await app.call("GET", "/v1/installations", undefined, onThePhone)).body.installations).toEqual([]);
    // The session the Mac registered with is gone; the phone's stays.
    expect((await app.call("GET", "/v1/me", undefined, onTheMac)).status).toBe(401);
    expect((await app.call("GET", "/v1/me", undefined, onThePhone)).status).toBe(200);
    // Set up anew, the same Mac is registered again.
    const fresh = await app.signIn();
    expect((await app.register(fresh)).status).toBe(200);
    expect((await app.call("GET", "/v1/installations", undefined, onThePhone)).body.installations).toHaveLength(1);
  });

  it("checks the fields", async () => {
    const app = testApp();
    const session = await app.signIn();
    const short = await app.call("POST", "/v1/installations", { clientId: "short", name: "Mac", platform: "macos" }, session);
    expect(short.status).toBe(422);
    expect(short.body.error).toBe("clientId is 8 to 128 letters, digits, dashes or underscores.");
    expect((await app.call("POST", "/v1/installations", { clientId: "mac-client-0001", name: "   ", platform: "macos" }, session)).status).toBe(422);
    expect((await app.call("POST", "/v1/installations", { clientId: "mac-client-0001", name: "Mac", platform: "macOS" }, session)).status).toBe(422);
    expect((await app.call("POST", "/v1/installations", { clientId: "mac-client-0001", name: "Mac" }, session)).status).toBe(422);
  });

  it("limits registrations to ten an hour, and installations to twenty", async () => {
    const app = testApp();
    const session = await app.signIn();
    for (let i = 0; i < 20; i++) {
      if (i > 0 && i % 10 === 0) app.time.advance(HOUR);
      expect((await app.register(session, `mac-client-${String(i).padStart(4, "0")}`)).status).toBe(201);
    }
    const eleventh = await app.register(session, "mac-client-0020");
    expect(eleventh.status).toBe(429);
    expect(eleventh.body.error).toMatch(/^Too many installations were registered lately\./);
    app.time.advance(HOUR);
    const twentyFirst = await app.register(session, "mac-client-0020");
    expect(twentyFirst.status).toBe(409);
    expect(twentyFirst.body.error).toBe("This account has 20 installations already. Remove one first.");
    // Registering a Mac again isn't a new installation.
    expect((await app.register(session, "mac-client-0003")).status).toBe(200);
  });
});
