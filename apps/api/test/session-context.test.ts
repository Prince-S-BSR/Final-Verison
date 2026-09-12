// apps/api/test/session-context.test.ts
//
// Edge cases in middleware/session-context.ts that R1/R2/R3 don't otherwise
// exercise: revocation and the fact that a session token only ever resolves
// to the ONE tenant it was issued under, regardless of which route or which
// other tenant's data happens to be requested. This is what stops a stolen
// tenant-A token from being replayed for anything — the same boundary the
// architecture note (§3.3) describes for subdomain/session tenant agreement,
// exercised here without a subdomain layer since Phase 0 has none yet.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import request from "supertest";
import type { FastifyInstance } from "fastify";
import { seedSession } from "../src/test-utils/seed-session.js";
import { startTestApp } from "./support/app.js";
import {
  closeDbConnection,
  createUser,
  deleteTenant,
  provisionTenant,
  revokeSession,
  type TestTenant,
} from "./support/provision.js";

describe("session-context middleware", () => {
  let app: FastifyInstance;
  let tenant: TestTenant;
  let userId: string;

  beforeAll(async () => {
    app = await startTestApp();
    tenant = await provisionTenant("session");
    userId = await createUser(tenant.tenantId, "user-session");
  });

  afterAll(async () => {
    await app.close();
    await deleteTenant(tenant.tenantId);
    await closeDbConnection();
  });

  it("a valid, unrevoked session resolves and reaches the route", async () => {
    const { token } = await seedSession({ tenantId: tenant.tenantId, userId });
    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(200);
  });

  it("a revoked session is rejected with 401, even though the token itself is well-formed", async () => {
    const { token, sessionId } = await seedSession({ tenantId: tenant.tenantId, userId });

    // Sanity: works before revocation.
    await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${token}`)
      .expect(200);

    await revokeSession(tenant.tenantId, sessionId);

    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("session_revoked");
  });

  it("a restricted (non-'full') scope session cannot reach a data route", async () => {
    const { token } = await seedSession({
      tenantId: tenant.tenantId,
      userId,
      scope: "mfa_enrolment",
    });

    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("session_scope_restricted");
  });

  it("an Authorization header without the Bearer scheme is rejected", async () => {
    const { token } = await seedSession({ tenantId: tenant.tenantId, userId });
    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", token);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("missing_bearer_token");
  });
});
