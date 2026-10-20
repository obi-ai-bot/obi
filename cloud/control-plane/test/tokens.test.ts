import { describe, expect, it } from "vitest";
import { takeOne } from "../src/limits";
import { env } from "cloudflare:test";
import { OPAQUE_ALPHABET, opaqueLabel, tunnelSecret } from "../src/tokens";

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

  it("makes tunnel secrets of 32 random bytes", () => {
    expect(atob(tunnelSecret())).toHaveLength(32);
    expect(tunnelSecret()).not.toBe(tunnelSecret());
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
