// What the tests call the Worker with: `handle` on the test's own D1, a fake Cloudflare API that
// records its calls, a fake email sender that keeps what it sent, and a clock the test moves.

import { env } from "cloudflare:test";
import { type Deps, handle } from "../src/app";
import { CloudflareError, type Ingress, type TunnelAPI } from "../src/cloudflare";
import type { Mailer } from "../src/email";
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

export class FakeMail implements Mailer {
  sent: { to: string; subject: string; text: string }[] = [];
  /// Thrown by the next send, when set.
  failure?: Error;

  async send(to: string, subject: string, text: string): Promise<void> {
    if (this.failure) throw this.failure;
    this.sent.push({ to, subject, text });
  }

  /// The code in the last email.
  lastCode(): string {
    const text = this.sent.at(-1)?.text ?? "";
    const code = text.match(/\b\d{6}\b/)?.[0];
    if (!code) throw new Error(`no code in the last email: ${text}`);
    return code;
  }
}

export interface Answer {
  status: number;
  headers: Headers;
  // biome-ignore lint/suspicious/noExplicitAny: the tests read what they expect.
  body: any;
}

export function testApp(overrides: Partial<Deps> = {}, envOverrides: Partial<Env> = {}) {
  const tunnels = new FakeTunnels();
  const mail = new FakeMail();
  let at = new Date("2026-10-12T12:00:00.000Z");
  const time = {
    now: () => at,
    advance(ms: number) {
      at = new Date(at.getTime() + ms);
    },
  };
  const deps: Deps = { tunnels, mail, now: time.now, ...overrides };

  async function call(method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}): Promise<Answer> {
    const request = new Request(`https://oby-control.tetrix.pro${path}`, {
      method,
      headers: {
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
    const response = await handle(request, { ...env, ...envOverrides }, deps);
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
  }

  /// Signs `email` in through the emailed code and returns the session token.
  async function signIn(email = "well@example.com"): Promise<string> {
    const asked = await call("POST", "/v1/auth/otp/request", { email });
    if (asked.status !== 202) throw new Error(`asking for a code: ${asked.status} ${JSON.stringify(asked.body)}`);
    const verified = await call("POST", "/v1/auth/otp/verify", { email, code: mail.lastCode() });
    if (verified.status !== 201) throw new Error(`verifying the code: ${verified.status} ${JSON.stringify(verified.body)}`);
    return verified.body.token as string;
  }

  /// Registers a Mac under `session` and returns the answer's body: `installation` and `credential`.
  async function register(session: string, clientId = "mac-client-0001", name = "Wellington's MacBook Pro"): Promise<Answer> {
    return call("POST", "/v1/installations", { clientId, name, platform: "macos" }, session);
  }

  return { call, signIn, register, tunnels, mail, time };
}

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
