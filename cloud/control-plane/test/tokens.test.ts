import { describe, expect, it } from "vitest";
import { takeOne } from "../src/limits";
import { env } from "cloudflare:test";
import { OPAQUE_ALPHABET, opaqueLabel, randomToken, sha256, sixDigits, tunnelSecret } from "../src/tokens";

describe("tokens", () => {
  it("makes opaque labels of lowercase letters and digits", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 50; i++) {
      const label = opaqueLabel();
      expect(label).toMatch(/^[a-z0-9]{20}$/);
      for (const character of label) expect(OPAQUE_ALPHABET).toContain(character);
      seen.add(label);
    }
    expect(seen.size).toBe(50);
    expect(opaqueLabel(16)).toHaveLength(16);
  });

  it("makes six-digit codes and prefixed tokens", () => {
    for (let i = 0; i < 20; i++) expect(sixDigits()).toMatch(/^\d{6}$/);
    expect(randomToken("oby_session_")).toMatch(/^oby_session_[A-Za-z0-9_-]{43}$/);
    expect(randomToken("oby_install_")).toMatch(/^oby_install_[A-Za-z0-9_-]{43}$/);
    expect(randomToken("oby_install_")).not.toBe(randomToken("oby_install_"));
    expect(atob(tunnelSecret())).toHaveLength(32);
  });

  it("hashes as SHA-256 hex", async () => {
    expect(await sha256("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
});

describe("rate limits", () => {
  it("count a fixed window per key", async () => {
    const limit = { max: 2, windowSeconds: 60 };
    let now = new Date("2026-10-12T12:00:00Z");
    expect(await takeOne(env.DB, "k", limit, now)).toEqual({ allowed: true, retryAfterSeconds: 0 });
    expect(await takeOne(env.DB, "k", limit, now)).toEqual({ allowed: true, retryAfterSeconds: 0 });
    now = new Date("2026-10-12T12:00:30Z");
    expect(await takeOne(env.DB, "k", limit, now)).toEqual({ allowed: false, retryAfterSeconds: 30 });
    expect(await takeOne(env.DB, "other", limit, now)).toEqual({ allowed: true, retryAfterSeconds: 0 });
    now = new Date("2026-10-12T12:01:00Z");
    expect(await takeOne(env.DB, "k", limit, now)).toEqual({ allowed: true, retryAfterSeconds: 0 });
  });
});
