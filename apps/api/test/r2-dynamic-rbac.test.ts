// apps/api/test/r2-dynamic-rbac.test.ts
//
// R2 — dynamic RBAC, exercised over real HTTP requests against
// /_test/protected/permission/:key. The point of this suite is proving the
// permission check is LIVE on every request (docs/ENGINEERING_RULES.md R2 /
// middleware/require-permission.ts's own header comment): the same
// already-authenticated session, no new login, must see its access change
// the instant a role_permissions row changes underneath it.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import request from "supertest";
import type { FastifyInstance } from "fastify";
import { seedSession } from "../src/test-utils/seed-session.js";
import { startTestApp } from "./support/app.js";
import {
  assignRole,
  closeDbConnection,
  createUser,
  deleteTenant,
  getPermissionIdByKey,
  getRoleIdByKey,
  grantPermission,
  provisionTenant,
  revokePermission,
  type TestTenant,
} from "./support/provision.js";

describe("R2 — dynamic RBAC (/_test/protected/permission/:key)", () => {
  let app: FastifyInstance;
  let tenant: TestTenant;
  let token: string;
  let readOnlyRoleId: string;
  let contactsReadPermissionId: string;
  let billingManagePermissionId: string;

  beforeAll(async () => {
    app = await startTestApp();

    tenant = await provisionTenant("r2");
    const userId = await createUser(tenant.tenantId, "user-r2");

    // read_only is seeded (provision_tenant_rbac_defaults) with read actions
    // on contacts/deals/activities/reports, and explicitly NOT with
    // billing.manage — see 0000_phase0_foundation.sql §9.1. That gives us one
    // permission the user starts WITH and one they start WITHOUT, from the
    // same real seed data rather than a hand-built fixture role.
    readOnlyRoleId = await getRoleIdByKey(tenant.tenantId, "read_only");
    await assignRole(tenant.tenantId, userId, readOnlyRoleId);

    contactsReadPermissionId = await getPermissionIdByKey(tenant.tenantId, "contacts.read");
    billingManagePermissionId = await getPermissionIdByKey(tenant.tenantId, "billing.manage");

    token = (await seedSession({ tenantId: tenant.tenantId, userId })).token;
  });

  afterAll(async () => {
    await app.close();
    await deleteTenant(tenant.tenantId);
    await closeDbConnection();
  });

  it("a permission the role was seeded with returns 200", async () => {
    const res = await request(app.server)
      .get("/_test/protected/permission/contacts.read")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it("a permission the role was never granted returns 403", async () => {
    const res = await request(app.server)
      .get("/_test/protected/permission/billing.manage")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("permission_denied");
  });

  it(
    "revoking role_permissions mid-test, directly via the DB, blocks the very next " +
      "request on the SAME already-authenticated session — no relogin, no restart",
    async () => {
      // Confirm it's granted first so the revoke below is a real transition.
      const before = await request(app.server)
        .get("/_test/protected/permission/contacts.read")
        .set("Authorization", `Bearer ${token}`);
      expect(before.status).toBe(200);

      await revokePermission(tenant.tenantId, readOnlyRoleId, contactsReadPermissionId);

      const after = await request(app.server)
        .get("/_test/protected/permission/contacts.read")
        .set("Authorization", `Bearer ${token}`);
      expect(after.status).toBe(403);
      expect(after.body.error).toBe("permission_denied");
    },
  );

  it(
    "granting a permission the user never had mid-test allows it on the next request, " +
      "proving this isn't read once at session creation or cached",
    async () => {
      const before = await request(app.server)
        .get("/_test/protected/permission/billing.manage")
        .set("Authorization", `Bearer ${token}`);
      expect(before.status).toBe(403);

      await grantPermission(tenant.tenantId, readOnlyRoleId, billingManagePermissionId);

      const after = await request(app.server)
        .get("/_test/protected/permission/billing.manage")
        .set("Authorization", `Bearer ${token}`);
      expect(after.status).toBe(200);
      expect(after.body).toEqual({ ok: true });
    },
  );

  it("an unrecognized permission key is denied rather than defaulting to allow", async () => {
    const res = await request(app.server)
      .get("/_test/protected/permission/not.a.real.permission")
      .set("Authorization", `Bearer ${token}`);
    expect(res.status).toBe(403);
  });

  it("requests with no Authorization header are rejected with 401", async () => {
    const res = await request(app.server).get("/_test/protected/permission/contacts.read");
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("missing_bearer_token");
  });
});
