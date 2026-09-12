// apps/api/test/support/app.ts
//
// Shared "start a real Fastify instance for Supertest" helper. `app.ready()`
// is required before handing `app.server` to Supertest — Fastify defers
// plugin/route registration until ready() resolves, and without it requests
// race the registration of testOnlyRoutes.

import type { FastifyInstance } from "fastify";
import { buildApp } from "../../src/app.js";

export async function startTestApp(): Promise<FastifyInstance> {
  const app = await buildApp({ logger: false });
  await app.ready();
  return app;
}
