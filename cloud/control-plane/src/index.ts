// The Worker's entry: `handle` (src/app.ts) with the real Cloudflare API and Apple's and Google's
// keys, and the sweep every minute.

import { handle, sweep } from "./app";
import { tunnelsFromEnv } from "./cloudflare";
import type { Env } from "./env";
import { appleKeysOverHTTPS, googleKeysOverHTTPS, KeyCache } from "./signin";

/// Apple's and Google's keys, kept across requests while this isolate lives.
const apple = new KeyCache(appleKeysOverHTTPS, () => new Date(), "Apple");
const google = new KeyCache(googleKeysOverHTTPS, () => new Date(), "Google");

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, { tunnels: tunnelsFromEnv(env), apple, google });
  },
  scheduled(_controller: ScheduledController, env: Env, context: ExecutionContext): void {
    context.waitUntil(sweep(env, { tunnels: tunnelsFromEnv(env), apple, google }));
  },
} satisfies ExportedHandler<Env>;
