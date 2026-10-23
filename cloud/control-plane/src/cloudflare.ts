// Cloudflare's API, for the tunnels and DNS records the Worker manages: what `handle` calls
// through `TunnelAPI`, so the tests pass a fake in. The API token, the account id and the zone
// id come from the Worker's secrets, are used only here, and never appear in an error or a log.

import type { Env } from "./env";

export interface Ingress {
  hostname?: string;
  service: string;
}

/// Whether a tunnel has cloudflared connected, and when it last came up or went down (ISO
/// times, null when it never did).
export interface TunnelStatus {
  connected: boolean;
  activeAt: string | null;
  inactiveAt: string | null;
}

export interface TunnelAPI {
  /// A remotely managed tunnel (its configuration lives at Cloudflare); returns its id.
  createTunnel(name: string, secret: string): Promise<{ id: string }>;
  /// The tunnel's ingress rules, in order; the last must be a catch-all.
  configureTunnel(id: string, ingress: Ingress[]): Promise<void>;
  deleteTunnel(id: string): Promise<void>;
  /// The token `cloudflared tunnel run` connects with.
  tunnelToken(id: string): Promise<string>;
  tunnelStatus(id: string): Promise<TunnelStatus>;
  /// The zone's own name: the device domain, when CF_ZONE_ID is the right zone.
  zoneName(): Promise<string>;
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
  errors?: { code?: number; message?: string; error_chain?: { code?: number; message?: string }[] }[];
}

export class CloudflareAPI implements TunnelAPI {
  constructor(
    private readonly token: string,
    private readonly account: string,
    private readonly zone: string,
    // Bound: workerd refuses `fetch` called as another object's method ("Illegal invocation").
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
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

  async tunnelStatus(id: string): Promise<TunnelStatus> {
    const tunnel = await this.call<{ status?: string; conns_active_at?: string | null; conns_inactive_at?: string | null }>(
      "read the tunnel's status",
      "GET",
      `/accounts/${this.account}/cfd_tunnel/${id}`,
    );
    return {
      connected: tunnel.status === "healthy" || tunnel.status === "degraded",
      activeAt: tunnel.conns_active_at ?? null,
      inactiveAt: tunnel.conns_inactive_at ?? null,
    };
  }

  async zoneName(): Promise<string> {
    return (await this.call<{ name: string }>("read the zone", "GET", `/zones/${this.zone}`)).name;
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
      // Cloudflare's own codes too (6003 and its chain say which header it refused); never the request.
      const said =
        envelope.errors
          ?.map((error) => [error.code, error.message, ...(error.error_chain ?? []).map((link) => `${link.code} ${link.message}`)].filter(Boolean).join(" "))
          .join("; ") || `HTTP ${response.status}`;
      throw new CloudflareError(`Couldn't ${step}: ${said}`);
    }
    return envelope.result as T;
  }
}

/// The API from the Worker's secrets; without them, one that says so when first used, so
/// installations still work in `wrangler dev`.
export function tunnelsFromEnv(env: Env): TunnelAPI {
  // A pasted secret can carry a newline, spaces or a "Bearer " of its own: Cloudflare refuses that
  // header ("Invalid request headers").
  const clean = (value?: string) => (value ?? "").trim().replace(/^Bearer\s+/i, "");
  const [token, account, zone] = [clean(env.CF_API_TOKEN), clean(env.CF_ACCOUNT_ID), clean(env.CF_ZONE_ID)];
  if (token && account && zone) {
    return new CloudflareAPI(token, account, zone);
  }
  const missing = (): never => {
    throw new CloudflareSetupError("CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID aren't all set: wrangler secret put each, or put them in .dev.vars.");
  };
  return {
    createTunnel: async () => missing(),
    configureTunnel: async () => missing(),
    deleteTunnel: async () => missing(),
    tunnelToken: async () => missing(),
    tunnelStatus: async () => missing(),
    zoneName: async () => missing(),
    createCNAME: async () => missing(),
    deleteDNSRecord: async () => missing(),
  };
}
