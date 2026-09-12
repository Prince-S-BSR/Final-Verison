import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// The monorepo has one root .env (see /.env.example) that packages/db reads
// DATABASE_URL from; nothing in the stack currently auto-loads it (dev/start
// scripts assume it's already exported), so the test runner loads it itself
// rather than requiring every contributor to export it by hand before
// `npm test`. Node's built-in loader (stable since Node 21.7) avoids adding
// a dotenv dependency just for this. A pre-existing DATABASE_URL in the
// environment (e.g. CI secrets) is left untouched.
const rootEnvPath = fileURLToPath(new URL("../../.env", import.meta.url));
if (!process.env.DATABASE_URL && existsSync(rootEnvPath)) {
  process.loadEnvFile(rootEnvPath);
}

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // Integration suite against real Postgres (see test/support/*) — no DB
    // mocking, so timeouts are generous relative to a pure unit suite.
    testTimeout: 20_000,
    hookTimeout: 20_000,
    // Test files provision/tear down their own tenants (see test/support/
    // provision.ts) so they are safe to run in parallel, but each file also
    // closes the DB connection pool it opened in afterAll — keep files
    // sequential within a single worker to avoid one file closing a pool the
    // next file in the same worker still needs.
    fileParallelism: false,
    // @crm/db resolves via a workspace symlink straight to TypeScript source
    // (packages/db/client.ts, no build step) — it must be transformed by
    // Vitest rather than externalized and loaded by Node's native resolver,
    // which cannot execute .ts files.
    server: {
      deps: {
        inline: [/@crm\/db/],
      },
    },
  },
});
