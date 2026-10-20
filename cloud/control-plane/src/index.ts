// The Worker's entry: `handle` (src/app.ts) with the real Cloudflare API and Apple's keys, and the
// sweep every minute.

import { handle, sweep } from "./app";
import { AppleKeyCache, appleKeysOverHTTPS } from "./apple";
import { tunnelsFromEnv } from "./cloudflare";
import type { Env } from "./env";

/// Apple's keys, kept across requests while this isolate lives.
const apple = new AppleKeyCache(appleKeysOverHTTPS, () => new Date());

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, { tunnels: tunnelsFromEnv(env), apple });
  },
  scheduled(_controller: ScheduledController, env: Env, context: ExecutionContext): void {
    context.waitUntil(sweep(env, { tunnels: tunnelsFromEnv(env), apple }));
  },
} satisfies ExportedHandler<Env>;
