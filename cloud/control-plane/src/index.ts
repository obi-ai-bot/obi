// The Worker's entry: `handle` (src/app.ts) with the real Cloudflare API and email sender.

import { handle } from "./app";
import { tunnelsFromEnv } from "./cloudflare";
import { mailerFromEnv } from "./email";
import type { Env } from "./env";

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, { tunnels: tunnelsFromEnv(env), mail: mailerFromEnv(env) });
  },
} satisfies ExportedHandler<Env>;
