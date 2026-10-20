import { describe, expect, it } from "vitest";
import { takeOne } from "../src/limits";
import { env } from "cloudflare:test";
import { addressBucket, leadingZeroBits, OPAQUE_ALPHABET, opaqueLabel, tunnelSecret } from "../src/tokens";

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

  it("counts leading zero bits", () => {
    expect(leadingZeroBits(new Uint8Array([0xff]))).toBe(0);
    expect(leadingZeroBits(new Uint8Array([0x00, 0x01]))).toBe(15);
    expect(leadingZeroBits(new Uint8Array([0x00, 0x00, 0x80]))).toBe(16);
    expect(leadingZeroBits(new Uint8Array([0x0f]))).toBe(4);
    expect(leadingZeroBits(new Uint8Array([0, 0]))).toBe(16);
  });

  it("counts an IPv6 address by its /64, an IPv4 one as it is", () => {
    expect(addressBucket("203.0.113.7")).toBe("203.0.113.7");
    expect(addressBucket("2001:db8:1:2::1")).toBe("2001:db8:1:2::/64");
    expect(addressBucket("2001:0DB8:0001:0002:ffff:ffff:ffff:ffff")).toBe("2001:db8:1:2::/64");
    expect(addressBucket("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(addressBucket("::1")).toBe("0:0:0:0::/64");
    expect(addressBucket("2001:db8:1:3::1")).not.toBe(addressBucket("2001:db8:1:2::1"));
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
