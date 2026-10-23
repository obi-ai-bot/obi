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
        // The tests' own instance: wrangler.jsonc's top level is a template with nothing set.
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            PRODUCT_DOMAIN: "oby.test",
            DEVICE_DOMAIN: "oby-devices.test",
            APPLE_CLIENT_ID: "com.deskree.oby.signin.test",
            APPLE_REDIRECT_URI: "https://oby-control.oby.test/v1/auth/apple/callback",
            GOOGLE_CLIENT_ID: "1234-oby.apps.googleusercontent.com",
            GOOGLE_REDIRECT_URI: "https://oby-control.oby.test/v1/auth/google/callback",
            APNS_TOPICS: "com.deskree.oby.ios",
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/setup.ts"] },
  };
});
