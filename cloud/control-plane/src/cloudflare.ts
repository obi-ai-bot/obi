// Cloudflare's API, for the tunnels and DNS records the Worker manages: what `handle` calls
// through `TunnelAPI`, so the tests pass a fake in. The API token, the account id and the zone
// id come from the Worker's secrets, are used only here, and never appear in an error or a log.

import type { Env } from "./env";

export interface Ingress {
  hostname?: string;
  service: string;
}

export interface TunnelAPI {
  /// A remotely managed tunnel (its configuration lives at Cloudflare); returns its id.
  createTunnel(name: string, secret: string): Promise<{ id: string }>;
  /// The tunnel's ingress rules, in order; the last must be a catch-all.
  configureTunnel(id: string, ingress: Ingress[]): Promise<void>;
  deleteTunnel(id: string): Promise<void>;
  /// The token `cloudflared tunnel run` connects with.
  tunnelToken(id: string): Promise<string>;
  /// A proxied CNAME in the zone: `name` → `target`. Returns the record's id.
  createCNAME(name: string, target: string): Promise<{ id: string }>;
  deleteDNSRecord(id: string): Promise<void>;
}

/// What Cloudflare answered when it refused: its own message, with the step it was for.
export class CloudflareError extends Error {}

/// The secrets the tunnels need aren't set.
export class CloudflareSetupError extends Error {}

interface Envelope<T> {
  success?: boolean;
  result?: T;
  errors?: { code?: number; message?: string }[];
}

export class CloudflareAPI implements TunnelAPI {
  constructor(
    private readonly token: string,
    private readonly account: string,
    private readonly zone: string,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  async createTunnel(name: string, secret: string): Promise<{ id: string }> {
    const tunnel = await this.call<{ id: string }>("create the tunnel", "POST", `/accounts/${this.account}/cfd_tunnel`, {
      name,
      config_src: "cloudflare",
      tunnel_secret: secret,
    });
    return { id: tunnel.id };
  }

  async configureTunnel(id: string, ingress: Ingress[]): Promise<void> {
    await this.call("configure the tunnel", "PUT", `/accounts/${this.account}/cfd_tunnel/${id}/configurations`, { config: { ingress } });
  }

  async deleteTunnel(id: string): Promise<void> {
    await this.call("delete the tunnel", "DELETE", `/accounts/${this.account}/cfd_tunnel/${id}?cascade=true`);
  }

  async tunnelToken(id: string): Promise<string> {
    return this.call<string>("read the tunnel's token", "GET", `/accounts/${this.account}/cfd_tunnel/${id}/token`);
  }

  async createCNAME(name: string, target: string): Promise<{ id: string }> {
    const record = await this.call<{ id: string }>("add the DNS record", "POST", `/zones/${this.zone}/dns_records`, {
      type: "CNAME",
      name,
      content: target,
      proxied: true,
      ttl: 1,
      comment: "Oby remote access",
    });
    return { id: record.id };
  }

  async deleteDNSRecord(id: string): Promise<void> {
    await this.call("delete the DNS record", "DELETE", `/zones/${this.zone}/dns_records/${id}`);
  }

  /// One call; `step` names it in an error, never the path (it holds the account and zone ids).
  private async call<T>(step: string, method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.fetcher(`https://api.cloudflare.com/client/v4${path}`, {
      method,
      headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let envelope: Envelope<T> = {};
    try {
      envelope = (await response.json()) as Envelope<T>;
    } catch {
      // Not JSON: the status says enough.
    }
    if (!response.ok || envelope.success === false) {
      const said = envelope.errors?.map((error) => error.message).filter(Boolean).join("; ") || `HTTP ${response.status}`;
      throw new CloudflareError(`Couldn't ${step}: ${said}`);
    }
    return envelope.result as T;
  }
}

/// The API from the Worker's secrets; without them, one that says so when first used, so sign-in
/// and installations still work in `wrangler dev` with only the email sender set.
export function tunnelsFromEnv(env: Env): TunnelAPI {
  if (env.CF_API_TOKEN && env.CF_ACCOUNT_ID && env.CF_ZONE_ID) {
    return new CloudflareAPI(env.CF_API_TOKEN, env.CF_ACCOUNT_ID, env.CF_ZONE_ID);
  }
  const missing = (): never => {
    throw new CloudflareSetupError("CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID aren't all set: wrangler secret put each, or put them in .dev.vars.");
  };
  return {
    createTunnel: async () => missing(),
    configureTunnel: async () => missing(),
    deleteTunnel: async () => missing(),
    tunnelToken: async () => missing(),
    createCNAME: async () => missing(),
    deleteDNSRecord: async () => missing(),
  };
}
