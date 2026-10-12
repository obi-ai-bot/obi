// Random things and hashes, on Web Crypto: tokens, the sign-in code, hostnames' opaque part.

const encoder = new TextEncoder();

/// SHA-256 of `text`, hex. What D1 keeps in place of a token or a code.
export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

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

/// A bearer token: its prefix says what it opens, then 32 random bytes, base64url.
export function randomToken(prefix: "oby_session_" | "oby_install_"): string {
  return prefix + base64(randomBytes(32)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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

/// A six-digit sign-in code, every code equally likely.
export function sixDigits(): string {
  const codes = 1_000_000;
  const limit = Math.floor(0x1_0000_0000 / codes) * codes;
  for (;;) {
    const word = new Uint32Array(1);
    crypto.getRandomValues(word);
    const value = word[0]!;
    if (value < limit) return String(value % codes).padStart(6, "0");
  }
}

export function newId(): string {
  return crypto.randomUUID();
}
