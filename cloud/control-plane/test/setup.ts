import { applyD1Migrations, env } from "cloudflare:test";
import { beforeEach } from "vitest";

// Every test file starts from a migrated database, and every test from an empty one.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

beforeEach(async () => {
  await env.DB.batch(
    ["push_devices", "apns_provider_token", "rate_limits", "nonces", "hook_queue", "hooks", "endpoints", "installations", "sign_ins", "users"].map((table) =>
      env.DB.prepare(`DELETE FROM ${table}`),
    ),
  );
});
