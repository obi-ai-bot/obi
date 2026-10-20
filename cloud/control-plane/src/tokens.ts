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

export function newId(): string {
  return crypto.randomUUID();
}
