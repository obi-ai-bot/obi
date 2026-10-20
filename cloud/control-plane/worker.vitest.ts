import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The tests run inside workerd (Miniflare) with a real, empty D1 that test/setup.ts migrates;
// the Cloudflare API and the email sender are fakes the tests pass in (src/app.ts, `handle`).
export default defineConfig(async () => {
  const migrations = await readD1Migrations(fileURLToPath(new URL("migrations", import.meta.url)));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        // The tests' own device domain and an easy proof of work.
        miniflare: { bindings: { TEST_MIGRATIONS: migrations, DEVICE_DOMAIN: "oby-devices.test", REGISTRATION_WORK_BITS: "8" } },
      }),
    ],
    test: { setupFiles: ["./test/setup.ts"] },
  };
});
