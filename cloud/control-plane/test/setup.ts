import { applyD1Migrations, env } from "cloudflare:test";
import { beforeEach } from "vitest";

// Every test file starts from a migrated database, and every test from an empty one.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

beforeEach(async () => {
  await env.DB.batch(
    ["rate_limits", "endpoints", "installation_credentials", "installations", "sessions", "otp_codes", "users"].map((table) =>
      env.DB.prepare(`DELETE FROM ${table}`),
    ),
  );
});
