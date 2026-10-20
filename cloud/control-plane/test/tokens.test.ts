import { describe, expect, it } from "vitest";
import { takeOne } from "../src/limits";
import { env } from "cloudflare:test";
import { addressBucket, networkBucket, OPAQUE_ALPHABET, opaqueLabel, registrableDomain, tunnelSecret } from "../src/tokens";

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

  it("counts an IPv6 address by its /64, an IPv4 one as it is", () => {
    expect(addressBucket("203.0.113.7")).toBe("203.0.113.7");
    expect(addressBucket("2001:db8:1:2::1")).toBe("2001:db8:1:2::/64");
    expect(addressBucket("2001:0DB8:0001:0002:ffff:ffff:ffff:ffff")).toBe("2001:db8:1:2::/64");
    expect(addressBucket("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(addressBucket("::1")).toBe("0:0:0:0::/64");
    expect(addressBucket("2001:db8:1:3::1")).not.toBe(addressBucket("2001:db8:1:2::1"));
  });

  it("counts a wider network: an IPv4 /24, an IPv6 /48", () => {
    expect(networkBucket("203.0.113.7")).toBe("203.0.113.0/24");
    expect(networkBucket("2001:db8:1:2::1")).toBe("2001:db8:1::/48");
    expect(networkBucket("2001:db8:1:ffff::9")).toBe(networkBucket("2001:db8:1:2::1"));
    expect(networkBucket("2001:db8:2::1")).not.toBe(networkBucket("2001:db8:1::1"));
  });

  it("finds a domain's registrable domain", () => {
    expect(registrableDomain("tetrix.pro")).toBe("tetrix.pro");
    expect(registrableDomain("devices.tetrix.pro")).toBe("tetrix.pro");
    expect(registrableDomain("a.b.example.co.uk")).toBe("example.co.uk");
    expect(registrableDomain("co.uk")).toBeNull();
    expect(registrableDomain("pro")).toBeNull();
    expect(registrableDomain("")).toBeNull();
    expect(registrableDomain("bad_label.example.com")).toBeNull();
  });

  it("finds registrable domains by the Public Suffix List's ICANN section, not a short list", () => {
    // Two-level suffixes a short list missed: each university or company is its own domain.
    expect(registrableDomain("x.ac.in")).toBe("x.ac.in");
    expect(registrableDomain("mail.y.ac.in")).toBe("y.ac.in");
    expect(registrableDomain("ac.in")).toBeNull();
    for (const suffix of ["ac.nz", "ac.za", "ac.il", "ac.kr", "edu.cn", "co.at", "com.pl", "org.nz", "net.nz", "ltd.uk", "com.pe"]) {
      expect(registrableDomain(`a.b.${suffix}`), suffix).toBe(`b.${suffix}`);
    }
    // A wildcard (`*.ck`) and its exception (`!www.ck`).
    expect(registrableDomain("a.b.ck")).toBe("a.b.ck");
    expect(registrableDomain("b.ck")).toBeNull();
    expect(registrableDomain("a.www.ck")).toBe("www.ck");
    // Names a guess by shape would split are one domain: co.de and web.de are domains, not suffixes.
    expect(registrableDomain("a.co.de")).toBe("co.de");
    expect(registrableDomain("x.web.de")).toBe("web.de");
    // The private section isn't used: github.io's users are one domain to the limits.
    expect(registrableDomain("someone.github.io")).toBe("github.io");
    // No rule: the last label is the suffix.
    expect(registrableDomain("a.example.unlisted-tld")).toBe("example.unlisted-tld");
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
