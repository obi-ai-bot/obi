// What the tests call the Worker with: `handle` on the test's own D1, a fake Cloudflare API that
// records its calls, a clock the test moves, and Macs: P-256 keys that sign their calls as the
// Mac app does (Engine/ControlPlane.swift).

import { env } from "cloudflare:test";
import { type Deps, handle, SIGNED_PREFIX, WORK_PREFIX } from "../src/app";
import { CloudflareError, type Ingress, type TunnelAPI, type TunnelStatus } from "../src/cloudflare";
import type { Env } from "../src/env";
import { leadingZeroBits } from "../src/tokens";

export class FakeTunnels implements TunnelAPI {
  calls: { op: string; args: unknown[] }[] = [];
  tunnels = new Map<string, { name: string; secret: string; ingress?: Ingress[] }>();
  records = new Map<string, { name: string; target: string }>();
  /// Each tunnel's status; one not here never connected.
  status = new Map<string, TunnelStatus>();
  /// The zone CF_ZONE_ID names.
  zone = "oby-devices.test";
  /// What the next call of that kind answers with, as Cloudflare refusing.
  refuse: Partial<Record<keyof TunnelAPI, string>> = {};
  private count = 0;

  /// Reads of a tunnel's status and the zone, apart from `calls`.
  reads: { op: string; args: unknown[] }[] = [];

  private read(op: keyof TunnelAPI, args: unknown[]): void {
    this.reads.push({ op, args });
    const said = this.refuse[op];
    if (said) throw new CloudflareError(`Couldn't ${op}: ${said}`);
  }

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

  async tunnelStatus(id: string): Promise<TunnelStatus> {
    this.read("tunnelStatus", [id]);
    return this.status.get(id) ?? { connected: false, activeAt: null, inactiveAt: null };
  }

  async zoneName(): Promise<string> {
    this.read("zoneName", []);
    return this.zone;
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

  /// Every tunnel there is now, connected by cloudflared.
  connectAll(at = "2026-10-12T12:00:00.000Z"): void {
    for (const id of this.tunnels.keys()) this.status.set(id, { connected: true, activeAt: at, inactiveAt: null });
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

/// A proof of work for `key` at `at`, as the Mac makes one (apps/mac/app/RemoteAccess.swift,
/// `MacKey.work`): the first answer whose hash starts with `bits` zero bits (the Worker's base
/// by default); with `valid` false, the first answer that doesn't.
export async function work(key: string, at: number, valid = true, bits = Number(env.REGISTRATION_WORK_BITS)): Promise<string> {
  for (let answer = 0; ; answer++) {
    if ((await checks(key, at, String(answer), bits)) === valid) return String(answer);
  }
}

/// Whether `answer` is a proof of work for `key` at `at` with `bits` zero bits.
export async function checks(key: string, at: number, answer: string, bits = Number(env.REGISTRATION_WORK_BITS)): Promise<boolean> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${WORK_PREFIX}\n${key}\n${at}\n${answer}`));
  return leadingZeroBits(new Uint8Array(digest)) >= bits;
}

export function testApp(overrides: Partial<Deps> = {}, envOverrides: Partial<Env> = {}) {
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
    const response = await handle(request, { ...env, ...envOverrides }, deps);
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
  }

  /// A call signed by `mac`, now.
  async function call(mac: Mac, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Answer> {
    const text = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
    const signed = await mac.headers(method, path, text ?? "", Math.floor(at.getTime() / 1000));
    return raw(method, path, text, { ...signed, ...headers });
  }

  /// Registers `mac`, with its proof of work, and returns the answer: `installation`. Asked for
  /// more bits (`workBits` in a 403), it works them out and tries once more, as the Mac does.
  async function register(mac: Mac, name = "Wellington's MacBook Pro", headers: Record<string, string> = {}): Promise<Answer> {
    const at = Math.floor(time.now().getTime() / 1000);
    const send = async (bits: number) =>
      call(mac, "POST", "/v1/installations", { name, platform: "macos", proofAt: String(at), proof: await work(mac.publicKey, at, true, bits) }, headers);
    const first = await send(Number(env.REGISTRATION_WORK_BITS));
    return first.status === 403 && first.body.workBits > Number(env.REGISTRATION_WORK_BITS) ? send(first.body.workBits) : first;
  }

  /// `count` live endpoints made straight in D1 (no Cloudflare), from `network`.
  async function fill(count: number, network = "fill") {
    for (let i = 0; i < count; i++) {
      const id = crypto.randomUUID();
      const at = time.now().toISOString();
      await env.DB.batch([
        env.DB.prepare("INSERT INTO installations (id, public_key, name, platform, created_at, last_seen_at) VALUES (?1, ?1, 'Mac', 'macos', ?2, ?2)").bind(id, at),
        env.DB.prepare("INSERT INTO endpoints (installation_id, tunnel_id, hostname, dns_record_id, created_at, network) VALUES (?1, ?1, ?1, ?1, ?2, ?3)").bind(id, at, network),
      ]);
    }
  }

  return { raw, call, register, fill, tunnels, time };
}

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
