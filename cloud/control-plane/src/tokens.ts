// Random things and signatures, on Web Crypto: tunnel secrets, hostnames' opaque part, and the
// check of a Mac's signature.

export function randomBytes(count: number): Uint8Array {
  const bytes = new Uint8Array(count);
  crypto.getRandomValues(bytes);
  return bytes;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64url(bytes: Uint8Array): string {
  return base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  try {
    return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

/// A Mac's public key as it's kept: an uncompressed P-256 point (X9.63, 65 bytes, 0x04 first),
/// base64url with no padding, spelled one way only so one key is one installation; or null.
export function canonicalKey(text: string): string | null {
  const bytes = fromBase64url(text);
  if (bytes?.length !== 65 || bytes[0] !== 4) return null;
  return base64url(bytes) === text ? text : null;
}

/// Whether `signature` (r‖s, 64 bytes, base64url) is `key`'s ECDSA P-256 SHA-256 signature of
/// `message`. A key that isn't a point on the curve is a no.
export async function verifyP256(key: string, signature: string, message: Uint8Array): Promise<boolean> {
  const point = fromBase64url(key);
  const raw = fromBase64url(signature);
  if (!point || raw?.length !== 64) return false;
  try {
    const publicKey = await crypto.subtle.importKey("raw", point, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw, message);
  } catch {
    return false;
  }
}

/// A tunnel's secret as Cloudflare takes it: at least 32 bytes, base64. It goes to Cloudflare once
/// and is never kept.
export function tunnelSecret(): string {
  return base64(randomBytes(32));
}

export const OPAQUE_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

/// The opaque part of a device's hostname: `length` lowercase letters and digits, each equally
/// likely (20 of them are about 103 bits), so a hostname can't be guessed.
export function opaqueLabel(length = 20): string {
  let label = "";
  while (label.length < length) {
    for (const byte of randomBytes(length)) {
      // 252 is the largest multiple of 36 under 256: bytes above it would favour the first letters.
      if (byte < 252 && label.length < length) label += OPAQUE_ALPHABET[byte % OPAQUE_ALPHABET.length];
    }
  }
  return label;
}

/// How many zero bits `bytes` starts with.
export function leadingZeroBits(bytes: Uint8Array): number {
  let bits = 0;
  for (const byte of bytes) {
    if (byte === 0) {
      bits += 8;
      continue;
    }
    return bits + Math.clz32(byte) - 24;
  }
  return bits;
}

/// An IPv6 address's eight groups, `::` filled in, leading zeros dropped; null for IPv4.
function ipv6Groups(address: string): string[] | null {
  if (!address.includes(":")) return null;
  const lower = address.toLowerCase();
  const [head = "", tail = ""] = lower.split("::", 2);
  const left = head ? head.split(":") : [];
  const right = lower.includes("::") && tail ? tail.split(":") : [];
  const groups = lower.includes("::") ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right] : left;
  return groups.map((group) => group.replace(/^0+(?=.)/, ""));
}

/// What one client counts as for rate limits: an IPv4 address as it is, an IPv6 one by its /64
/// (one home or one server gets a whole /64, so each of its addresses isn't a client).
export function addressBucket(address: string): string {
  const groups = ipv6Groups(address);
  return groups ? `${groups.slice(0, 4).join(":")}::/64` : address;
}

/// The wider network a client is in: an IPv4 /24, or an IPv6 /48 (what one site is usually
/// given, so its /64s count together).
export function networkBucket(address: string): string {
  const groups = ipv6Groups(address);
  if (groups) return `${groups.slice(0, 3).join(":")}::/48`;
  const octets = address.split(".");
  return octets.length === 4 ? `${octets.slice(0, 3).join(".")}.0/24` : address;
}

// ponytail: a handful of two-level public suffixes, not the Public Suffix List; load the list if
// a device or product domain ever sits under one not here.
const TWO_LEVEL_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
  "com.br", "net.br", "com.cn", "com.hk", "com.sg", "co.in", "co.za", "com.mx", "com.tr", "co.kr", "com.tw", "com.ar",
]);

/// The registrable domain `domain` is under (eTLD+1): `devices.example.co.uk` is `example.co.uk`.
/// Null for a bare public suffix or something that isn't a domain.
export function registrableDomain(domain: string): string | null {
  const labels = domain.trim().toLowerCase().split(".");
  if (labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return null;
  const take = TWO_LEVEL_SUFFIXES.has(labels.slice(-2).join(".")) ? 3 : 2;
  return labels.length >= take ? labels.slice(-take).join(".") : null;
}

export function newId(): string {
  return crypto.randomUUID();
}
