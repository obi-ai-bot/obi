// The Worker's entry: `handle` (src/app.ts) with the real Cloudflare API, and the hourly sweep.

import { handle, sweep } from "./app";
import { tunnelsFromEnv } from "./cloudflare";
import type { Env } from "./env";

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, { tunnels: tunnelsFromEnv(env) });
  },
  scheduled(_controller: ScheduledController, env: Env, context: ExecutionContext): void {
    context.waitUntil(sweep(env, { tunnels: tunnelsFromEnv(env) }));
  },
} satisfies ExportedHandler<Env>;
