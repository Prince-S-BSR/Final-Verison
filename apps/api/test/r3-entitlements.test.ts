// apps/api/test/r3-entitlements.test.ts
//
// R3 — entitlements, exercised over real HTTP requests against
// /_test/protected/feature/:key. middleware/require-feature.ts only
// implements the is_enabled gate (step 2 of the enforcement order — see that
// file's header comment); this suite covers exactly that gate, live on every
// request, not the 150%-ceiling soft-stop accounting (out of scope, a Phase 1
// data-access-layer deliverable per the issue brief).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import request from "supertest";
import type { FastifyInstance } from "fastify";
import { seedSession } from "../src/test-utils/seed-session.js";
import { startTestApp } from "./support/app.js";
import {
  closeDbConnection,
  createFeatureEntitlement,
  createUser,
  deleteTenant,
  provisionTenant,
  setFeatureEnabled,
  type TestTenant,
} from "./support/provision.js";

const FEATURE_KEY = "custom_reports";

describe("R3 — entitlements (/_test/protected/feature/:key)", () => {
  let app: FastifyInstance;
  let tenant: TestTenant;
  let token: string;
  let entitlementId: string;

  beforeAll(async () => {
    app = await startTestApp();

    tenant = await provisionTenant("r3");
    const userId = await createUser(tenant.tenantId, "user-r3");
    // Permission checks are R2's concern, not R3's — require-feature.ts gates
    // purely on feature_entitlements, independent of role. No role is
    // assigned here on purpose, to keep this suite from silently depending on
    // R2 behaviour.
    token = (await seedSession({ tenantId: tenant.tenantId, userId })).token;

    entitlementId = await createFeatureEntitlement(tenant.tenantId, FEATURE_KEY, true);
  });

  afterAll(async () => {
    await app.close();
    await deleteTenant(tenant.tenantId);
    await closeDbConnection();
  });

  it("an enabled entitlement returns 200", async () => {
    const res = await request(app.server)
      .get(`/_test/protected/feature/${FEATURE_KEY}`)
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it("a feature key with no entitlement row at all is denied, not defaulted to allowed", async () => {
    const res = await request(app.server)
      .get("/_test/protected/feature/never_entitled_feature")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("feature_not_entitled");
  });

  it(
    "toggling is_enabled to false mid-test, directly via the DB, blocks the very next " +
      "request on the SAME session — no relogin, no restart",
    async () => {
      const before = await request(app.server)
        .get(`/_test/protected/feature/${FEATURE_KEY}`)
        .set("Authorization", `Bearer ${token}`);
      expect(before.status).toBe(200);

      await setFeatureEnabled(tenant.tenantId, entitlementId, false);

      const after = await request(app.server)
        .get(`/_test/protected/feature/${FEATURE_KEY}`)
        .set("Authorization", `Bearer ${token}`);
      expect(after.status).toBe(403);
      expect(after.body.error).toBe("feature_not_entitled");
    },
  );

  it("toggling is_enabled back to true mid-test allows the request again", async () => {
    await setFeatureEnabled(tenant.tenantId, entitlementId, true);

    const res = await request(app.server)
      .get(`/_test/protected/feature/${FEATURE_KEY}`)
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it("requests with no Authorization header are rejected with 401", async () => {
    const res = await request(app.server).get(`/_test/protected/feature/${FEATURE_KEY}`);
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("missing_bearer_token");
  });
});
