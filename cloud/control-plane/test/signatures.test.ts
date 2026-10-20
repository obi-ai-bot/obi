import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MINUTE, Mac, testApp } from "./helpers";

describe("signed calls", () => {
  it("refuses a call with no signature", async () => {
    const app = testApp();
    const answer = await app.raw("POST", "/v1/installations", JSON.stringify({ name: "Mac", platform: "macos" }));
    expect(answer.status).toBe(401);
    expect(answer.body.error).toBe("This call needs this Mac's signature.");
    expect((await app.raw("GET", "/v1/installations/self", undefined, { Authorization: "Bearer oby_install_anything" })).status).toBe(401);
  });

  it("refuses a call changed on the way: its body, its path, its method", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const body = JSON.stringify({ name: "Mac", platform: "macos" });
    const signed = await mac.headers("POST", "/v1/installations", body, seconds);
    const changed = await app.raw("POST", "/v1/installations", JSON.stringify({ name: "Not the Mac", platform: "macos" }), signed);
    expect(changed.status).toBe(401);
    expect(changed.body.error).toBe("The signature doesn't match this Mac's key.");
    await app.register(mac);
    const forSelf = await mac.headers("GET", "/v1/installations/self", "", seconds);
    expect((await app.raw("DELETE", "/v1/installations/self", undefined, forSelf)).status).toBe(401);
    expect((await app.raw("GET", "/v1/installations/self/endpoint/token", undefined, forSelf)).status).toBe(401);
  });

  it("refuses another key's signature", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const thief = await Mac.make();
    await app.register(mac);
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const theirs = await thief.headers("DELETE", "/v1/installations/self", "", seconds);
    const answer = await app.raw("DELETE", "/v1/installations/self", undefined, { ...theirs, "Oby-Key": mac.publicKey });
    expect(answer.status).toBe(401);
    expect((await app.call(mac, "GET", "/v1/installations/self")).status).toBe(200);
  });

  it("takes each nonce once", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const signed = await mac.headers("GET", "/v1/installations/self", "", seconds, "the-same-nonce-0001");
    expect((await app.raw("GET", "/v1/installations/self", undefined, signed)).status).toBe(200);
    const replayed = await app.raw("GET", "/v1/installations/self", undefined, signed);
    expect(replayed.status).toBe(401);
    expect(replayed.body.error).toBe("That call was made already.");
    // Another key may use the same nonce.
    const other = await Mac.make();
    const body = JSON.stringify({ name: "Mac", platform: "macos", ...(await app.signIn(other)) });
    expect((await app.raw("POST", "/v1/installations", body, await other.headers("POST", "/v1/installations", body, seconds, "the-same-nonce-0001"))).status).toBe(201);
    expect((await app.raw("GET", "/v1/installations/self", undefined, { ...signed, "Oby-Nonce": "short" })).status).toBe(401);
  });

  it("keeps no nonce for a key with no installation", async () => {
    const app = testApp();
    const stranger = await Mac.make();
    for (let i = 0; i < 3; i++) expect((await app.call(stranger, "GET", "/v1/installations/self")).status).toBe(410);
    expect((await app.call(stranger, "POST", "/v1/installations", { name: "Mac", platform: "macos" })).status).toBe(403);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM nonces").first<{ n: number }>())?.n).toBe(0);
  });

  it("takes a timestamp within five minutes of the Worker's clock", async () => {
    const app = testApp();
    const mac = await Mac.make();
    await app.register(mac);
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const late = await mac.headers("GET", "/v1/installations/self", "", seconds - 6 * 60);
    const answer = await app.raw("GET", "/v1/installations/self", undefined, late);
    expect(answer.status).toBe(401);
    expect(answer.body.error).toBe("This Mac's clock is off by more than five minutes.");
    expect((await app.raw("GET", "/v1/installations/self", undefined, await mac.headers("GET", "/v1/installations/self", "", seconds + 6 * 60))).status).toBe(401);
    expect((await app.raw("GET", "/v1/installations/self", undefined, await mac.headers("GET", "/v1/installations/self", "", seconds - 4 * 60))).status).toBe(200);
    // A call signed just now, sent when its time is up, is refused too.
    const signed = await mac.headers("GET", "/v1/installations/self", "", seconds);
    app.time.advance(6 * MINUTE);
    expect((await app.raw("GET", "/v1/installations/self", undefined, signed)).status).toBe(401);
  });

  it("takes a key only as an uncompressed P-256 point, spelled one way", async () => {
    const app = testApp();
    const mac = await Mac.make();
    const seconds = Math.floor(app.time.now().getTime() / 1000);
    const body = JSON.stringify({ name: "Mac", platform: "macos", ...(await app.signIn(mac)) });
    const signed = await mac.headers("POST", "/v1/installations", body, seconds);
    for (const key of [`${mac.publicKey}=`, mac.publicKey.slice(0, -2), `A${mac.publicKey.slice(1)}`, "not a key"]) {
      expect((await app.raw("POST", "/v1/installations", body, { ...signed, "Oby-Key": key })).status).toBe(401);
    }
    expect((await app.raw("POST", "/v1/installations", body, signed)).status).toBe(201);
  });
});
