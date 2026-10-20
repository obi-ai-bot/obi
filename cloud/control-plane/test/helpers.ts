// What the tests call the Worker with: `handle` on the test's own D1, a fake Cloudflare API that
// records its calls, a clock the test moves, and Macs: P-256 keys that sign their calls as the
// Mac app does (Engine/ControlPlane.swift).

import { env } from "cloudflare:test";
import { type Deps, handle, SIGNED_PREFIX } from "../src/app";
import { CloudflareError, type Ingress, type TunnelAPI } from "../src/cloudflare";
import type { Env } from "../src/env";

export class FakeTunnels implements TunnelAPI {
  calls: { op: string; args: unknown[] }[] = [];
  tunnels = new Map<string, { name: string; secret: string; ingress?: Ingress[] }>();
  records = new Map<string, { name: string; target: string }>();
  /// What the next call of that kind answers with, as Cloudflare refusing.
  refuse: Partial<Record<keyof TunnelAPI, string>> = {};
  private count = 0;

  private check(op: keyof TunnelAPI, args: unknown[]): void {
    this.calls.push({ op, args });
    const said = this.refuse[op];
    if (said) throw new CloudflareError(`Couldn't ${op}: ${said}`);
  }

  async createTunnel(name: string, secret: string): Promise<{ id: string }> {
    this.check("createTunnel", [name, secret]);
    const id = `tunnel-${++this.count}`;
    this.tunnels.set(id, { name, secret });
    return { id };
  }

  async configureTunnel(id: string, ingress: Ingress[]): Promise<void> {
    this.check("configureTunnel", [id, ingress]);
    const tunnel = this.tunnels.get(id);
    if (!tunnel) throw new CloudflareError("Couldn't configure the tunnel: no such tunnel");
    tunnel.ingress = ingress;
  }

  async deleteTunnel(id: string): Promise<void> {
    this.check("deleteTunnel", [id]);
    this.tunnels.delete(id);
  }

  async tunnelToken(id: string): Promise<string> {
    this.check("tunnelToken", [id]);
    if (!this.tunnels.has(id)) throw new CloudflareError("Couldn't read the tunnel's token: no such tunnel");
    return `token-for-${id}`;
  }

  async createCNAME(name: string, target: string): Promise<{ id: string }> {
    this.check("createCNAME", [name, target]);
    const id = `record-${++this.count}`;
    this.records.set(id, { name, target });
    return { id };
  }

  async deleteDNSRecord(id: string): Promise<void> {
    this.check("deleteDNSRecord", [id]);
    this.records.delete(id);
  }

  ops(): string[] {
    return this.calls.map((call) => call.op);
  }
}

export interface Answer {
  status: number;
  headers: Headers;
  // biome-ignore lint/suspicious/noExplicitAny: the tests read what they expect.
  body: any;
}

/// A Mac's key pair, made with Web Crypto as the Mac makes it with CryptoKit.
export class Mac {
  private constructor(
    readonly keys: CryptoKeyPair,
    /// The public key as the control plane keeps it: X9.63, base64url.
    readonly publicKey: string,
  ) {}

  static async make(): Promise<Mac> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair;
    const raw = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
    return new Mac(keys, base64url(raw));
  }

  /// The headers that sign `method path` with `body` at `seconds` (Unix time).
  async headers(method: string, path: string, body: string, seconds: number, nonce = crypto.randomUUID()): Promise<Record<string, string>> {
    const message = new TextEncoder().encode(`${SIGNED_PREFIX}\n${method}\n${path}\n${seconds}\n${nonce}\n${body}`);
    const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.keys.privateKey, message));
    return { "Oby-Key": this.publicKey, "Oby-Timestamp": String(seconds), "Oby-Nonce": nonce, "Oby-Signature": base64url(signature) };
  }
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function testApp(overrides: Partial<Deps> = {}) {
  const tunnels = new FakeTunnels();
  let at = new Date("2026-10-12T12:00:00.000Z");
  const time = {
    now: () => at,
    advance(ms: number) {
      at = new Date(at.getTime() + ms);
    },
  };
  const deps: Deps = { tunnels, now: time.now, ...overrides };

  /// A request as it reaches the Worker, with `headers` as they are (no signature added).
  async function raw(method: string, path: string, body?: string, headers: Record<string, string> = {}): Promise<Answer> {
    const request = new Request(`https://oby-control.tetrix.pro${path}`, {
      method,
      headers: { ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
      body,
    });
    const response = await handle(request, env, deps);
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
  }

  /// A call signed by `mac`, now.
  async function call(mac: Mac, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Answer> {
    const text = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
    const signed = await mac.headers(method, path, text ?? "", Math.floor(at.getTime() / 1000));
    return raw(method, path, text, { ...signed, ...headers });
  }

  /// Registers `mac` and returns the answer: `installation`.
  async function register(mac: Mac, name = "Wellington's MacBook Pro", headers: Record<string, string> = {}): Promise<Answer> {
    return call(mac, "POST", "/v1/installations", { name, platform: "macos" }, headers);
  }

  return { raw, call, register, tunnels, time };
}

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
