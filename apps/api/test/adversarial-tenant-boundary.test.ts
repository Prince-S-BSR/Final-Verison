// apps/api/test/adversarial-tenant-boundary.test.ts
//
// Adversarial Phase 0 tenant-boundary tests (Beads issue Final-Verison-j75,
// sub-task of Final-Verison-5oe). This is the BMexa-specific gate from
// docs/BMEXA_MASTER_SPEC.md §77 criterion 3 ("Server-side authorization
// cannot be bypassed through manipulated request payloads") and §94
// ("Attempt to access Tenant B information using altered IDs, altered URLs,
// altered request payloads ... Expected: ACCESS DENIED. This must be
// automated"), on top of what r1-tenant-isolation.test.ts / r2-dynamic-rbac
// .test.ts / r3-entitlements.test.ts already prove under normal,
// session-derived context.
//
// The distinction from the existing 27 tests: those prove the app behaves
// correctly when the client sends only the fields the routes actually
// expect. This file deliberately sends fields no honest client would send —
// a spoofed tenant_id in a body, a spoofed tenant_id in a query string, a
// tenant UUID dropped into a record-id path segment, a claimed elevated
// role/scope on a permission check — and asserts the server ignores or
// rejects every one of them, per architecture note §3.3: "the tenant context
// comes from the server-side session ... never from a client-supplied
// header, body field, or query parameter."
//
// ONE FILE, not split by category: every category below exercises the same
// two small route groups (/_test/tenant-data/lead-stages and
// /_test/protected/{permission,feature}/:key) against the same two
// provisioned tenants. Splitting by category would mean re-provisioning two
// tenants + sessions per file for no isolation benefit — these tests do not
// interfere with each other any more than the sub-`it`s within
// r1-tenant-isolation.test.ts do. Grouped `describe` blocks below keep the
// categories visually and reportably distinct without the setup cost of
// separate files.
//
// Route-surface findings that shape what is and is not tested here (see the
// full reasoning in the task's final report, not duplicated in every
// comment):
//   - No route addresses a tenant via a path segment (category 3). The only
//     path parameter anywhere is PATCH .../lead-stages/:id, which addresses a
//     specific record. §3's test therefore checks that dropping a tenant
//     UUID into that record-id slot cannot select or leak anything, rather
//     than fabricating a tenant-in-path route that doesn't exist.
//   - No single-record GET exists (only the list GET). §4's tests therefore
//     cover the list endpoint's resistance to ID-based filtering leaks and
//     ID-collision attempts via POST, instead of a single-record read that
//     the route surface doesn't offer.
//   - No route accepts a client-supplied user/owner identifier at all —
//     session resolution comes only from the opaque bearer token
//     (session-context.ts), and lead_stages (the only mutable table exposed
//     here) has no owner/user_id column in the schema
//     (packages/db/drizzle/0000_phase0_foundation.sql). §5 documents this and
//     includes one light robustness check rather than a test that doesn't
//     exercise anything real.
//   - Both protected routes (/_test/protected/permission/:key,
//     /_test/protected/feature/:key) are GET-only. There is no
//     mutation-capable permission/feature-gated route in the current surface,
//     so §6's "both reads and mutations" requirement is satisfied by covering
//     the only kind of request that exists; this is noted inline rather than
//     silently only covering reads.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import request from "supertest";
import type { FastifyInstance } from "fastify";
import { seedSession } from "../src/test-utils/seed-session.js";
import { startTestApp } from "./support/app.js";
import {
  assignRole,
  closeDbConnection,
  createFeatureEntitlement,
  createUser,
  deleteTenant,
  getRoleIdByKey,
  insertLeadStage,
  provisionTenant,
  type TestTenant,
} from "./support/provision.js";

const FEATURE_KEY = "adversarial_widening_probe";

describe("Adversarial tenant-boundary tests (BMEXA §77 criterion 3 / §94)", () => {
  let app: FastifyInstance;
  let tenantA: TestTenant;
  let tenantB: TestTenant;
  let tokenA: string;
  let tokenB: string;
  let tenantBOnlyStageId: string;

  beforeAll(async () => {
    app = await startTestApp();

    tenantA = await provisionTenant("adv-a");
    tenantB = await provisionTenant("adv-b");

    const userA = await createUser(tenantA.tenantId, "user-adv-a");
    const userB = await createUser(tenantB.tenantId, "user-adv-b");

    // read_only, not owner: category 6 needs a permission (billing.manage)
    // the caller genuinely lacks, so "widening" attempts have something real
    // to fail to bypass — same seeded role R2 already relies on.
    const readOnlyRoleA = await getRoleIdByKey(tenantA.tenantId, "read_only");
    await assignRole(tenantA.tenantId, userA, readOnlyRoleA);
    const ownerRoleB = await getRoleIdByKey(tenantB.tenantId, "owner");
    await assignRole(tenantB.tenantId, userB, ownerRoleB);

    tokenA = (await seedSession({ tenantId: tenantA.tenantId, userId: userA })).token;
    tokenB = (await seedSession({ tenantId: tenantB.tenantId, userId: userB })).token;

    tenantBOnlyStageId = await insertLeadStage(tenantB.tenantId, "b_only_adv_stage", "B Only Adversarial Stage");

    // Entitled+enabled for tenant B only. Tenant A deliberately has NO row for
    // this feature key, so a 200 for tenant A on FEATURE_KEY can only mean
    // tenant B's entitlement was reached through some spoofed field.
    await createFeatureEntitlement(tenantB.tenantId, FEATURE_KEY, true);
  });

  afterAll(async () => {
    await app.close();
    await deleteTenant(tenantA.tenantId);
    await deleteTenant(tenantB.tenantId);
    await closeDbConnection();
  });

  // -----------------------------------------------------------------------
  // 1. Spoofed tenant_id in the request body.
  // -----------------------------------------------------------------------
  describe("1. spoofed tenant_id in request body", () => {
    it("POST with a spoofed tenant_id (snake_case) still creates the row under the caller's own tenant", async () => {
      const res = await request(app.server)
        .post("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ code: "spoof_body_snake", label: "Spoofed Body Snake", tenant_id: tenantB.tenantId });

      expect(res.status).toBe(201);
      expect(res.body.leadStage.tenant_id).toBe(tenantA.tenantId);
      expect(res.body.leadStage.tenant_id).not.toBe(tenantB.tenantId);

      const asB = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenB}`);
      expect((asB.body.leadStages as Array<{ id: string }>).some((s) => s.id === res.body.leadStage.id)).toBe(false);
    });

    it("POST with a spoofed tenantId (camelCase variant) is equally ignored", async () => {
      const res = await request(app.server)
        .post("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ code: "spoof_body_camel", label: "Spoofed Body Camel", tenantId: tenantB.tenantId });

      expect(res.status).toBe(201);
      expect(res.body.leadStage.tenant_id).toBe(tenantA.tenantId);
    });

    it("PATCH on the caller's own row with a spoofed tenant_id in the body updates the row but never reassigns its tenant", async () => {
      const createRes = await request(app.server)
        .post("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ code: "spoof_patch_reassign", label: "Before" });
      const stageId = createRes.body.leadStage.id;

      const patchRes = await request(app.server)
        .patch(`/_test/tenant-data/lead-stages/${stageId}`)
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ label: "After Spoofed Patch", tenant_id: tenantB.tenantId });

      expect(patchRes.status).toBe(200);
      expect(patchRes.body.leadStage.label).toBe("After Spoofed Patch");
      expect(patchRes.body.leadStage.tenant_id).toBe(tenantA.tenantId);

      // Confirm the row genuinely never moved: tenant B still cannot see it.
      const asB = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenB}`);
      expect((asB.body.leadStages as Array<{ id: string }>).some((s) => s.id === stageId)).toBe(false);
    });
  });

  // -----------------------------------------------------------------------
  // 2. Spoofed tenant_id in query parameters.
  // -----------------------------------------------------------------------
  describe("2. spoofed tenant_id in query parameters", () => {
    it("GET with ?tenant_id=<other tenant> returns only the caller's own tenant's rows", async () => {
      const res = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .query({ tenant_id: tenantB.tenantId })
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(200);
      const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
      expect(ids).not.toContain(tenantBOnlyStageId);
      for (const stage of res.body.leadStages as Array<{ tenant_id: string }>) {
        expect(stage.tenant_id).toBe(tenantA.tenantId);
      }
    });

    it("GET with ?tenantId=<other tenant> (camelCase variant) is equally ineffective", async () => {
      const res = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .query({ tenantId: tenantB.tenantId })
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(200);
      const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
      expect(ids).not.toContain(tenantBOnlyStageId);
    });

    it("GET with a spoofed X-Tenant-Id header is equally ineffective (not just query strings)", async () => {
      const res = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .set("X-Tenant-Id", tenantB.tenantId);

      expect(res.status).toBe(200);
      const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
      expect(ids).not.toContain(tenantBOnlyStageId);
    });

    // There is no query-accepting mutation route in the current surface (POST/
    // PATCH take no query parameters at all in test-only.ts), so a mutation
    // counterpart to this category does not exist to test — noted rather than
    // silently skipped.
  });

  // -----------------------------------------------------------------------
  // 3. Spoofed tenant ID in path parameters.
  // -----------------------------------------------------------------------
  //
  // No route in the current surface (test-only.ts, the only routes besides
  // GET /health) addresses a tenant via a path segment — subdomain-based
  // tenant routing (architecture note §4) is not implemented in Phase 0, and
  // /_test/tenant-data/lead-stages/:id addresses a record, not a tenant. This
  // category therefore cannot be tested by "spoof the tenant path segment" in
  // the way §2 spoofs a query parameter, because no such segment exists to
  // spoof. What *can* be tested, per the task brief's instruction to check
  // :id "carefully": whether dropping a tenant UUID into that record-id slot
  // is confused with, or grants access via, a tenant scope.
  describe("3. spoofed tenant ID in path parameters", () => {
    it("PATCH with a real tenant UUID (not a lead_stage id) in the :id slot 404s like any other non-matching id", async () => {
      const res = await request(app.server)
        .patch(`/_test/tenant-data/lead-stages/${tenantB.tenantId}`)
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ label: "Should Not Resolve To Anything" });

      // tenantB.tenantId is a well-formed UUID, so this exercises the "valid
      // UUID, no matching row" path, not the "malformed id" 400 path R1
      // already covers. A tenant id being usable as a record id lookup key
      // would be exactly the path-parameter confusion this category worries
      // about; it must not be.
      expect(res.status).toBe(404);
      expect(res.body.error).toBe("lead_stage_not_found");
    });
  });

  // -----------------------------------------------------------------------
  // 4. Cross-tenant record IDs, beyond the existing R1 PATCH-404 coverage.
  // -----------------------------------------------------------------------
  describe("4. cross-tenant record IDs", () => {
    it("GET (the only read route) ignores an ?id= filter naming another tenant's specific record — no single-record read route exists to leak one", async () => {
      const res = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .query({ id: tenantBOnlyStageId })
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(200);
      const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
      expect(ids).not.toContain(tenantBOnlyStageId);
    });

    it("POST cannot claim another tenant's existing row id — the insert always gets a fresh server-generated id, and the original row is untouched", async () => {
      const res = await request(app.server)
        .post("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ code: "id_collision_attempt", label: "Attempted Collision", id: tenantBOnlyStageId });

      expect(res.status).toBe(201);
      expect(res.body.leadStage.id).not.toBe(tenantBOnlyStageId);
      expect(res.body.leadStage.tenant_id).toBe(tenantA.tenantId);

      const asB = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenB}`);
      const original = (asB.body.leadStages as Array<{ id: string; label: string }>).find(
        (s) => s.id === tenantBOnlyStageId,
      );
      expect(original?.label).toBe("B Only Adversarial Stage");
    });

    it("PATCH against another tenant's row id, combined with a body tenant_id claiming the caller's own tenant, still 404s and leaves the row untouched", async () => {
      const res = await request(app.server)
        .patch(`/_test/tenant-data/lead-stages/${tenantBOnlyStageId}`)
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ label: "Hijack Attempt", tenant_id: tenantA.tenantId });

      expect(res.status).toBe(404);
      expect(res.body.error).toBe("lead_stage_not_found");

      const asB = await request(app.server)
        .get("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenB}`);
      const stillB = (asB.body.leadStages as Array<{ id: string; label: string; tenant_id: string }>).find(
        (s) => s.id === tenantBOnlyStageId,
      );
      expect(stillB?.label).toBe("B Only Adversarial Stage");
      expect(stillB?.tenant_id).toBe(tenantB.tenantId);
    });
  });

  // -----------------------------------------------------------------------
  // 5. Altered ownership/user IDs.
  // -----------------------------------------------------------------------
  //
  // No route in the current surface accepts a client-supplied user/owner
  // identifier. Session resolution comes only from the opaque bearer token,
  // looked up server-side (session-context.ts) — there is no `userId` field
  // on any request body or query string anywhere in test-only.ts.
  // Additionally, lead_stages — the only mutable table exposed here — has no
  // owner/user_id/created_by column at all in the schema
  // (0000_phase0_foundation.sql), so there is structurally nothing for such a
  // field to overwrite even if one were sent. The design forecloses this
  // attack rather than merely happening not to expose it today: adding an
  // owner concept later would require a real, typed column and explicit
  // wiring, not accidentally reading a client-supplied identity claim.
  //
  // The one thing worth actually exercising: that sending fields that *look*
  // like an ownership/identity claim is inert rather than causing an error or
  // being silently absorbed somewhere unexpected.
  describe("5. altered ownership/user IDs (documented as not applicable to the current route surface, with one robustness check)", () => {
    it("POST with extraneous ownership-shaped fields (user_id, userId, owner_id, created_by) is accepted and has no effect beyond the fields the route actually defines", async () => {
      const res = await request(app.server)
        .post("/_test/tenant-data/lead-stages")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({
          code: "ownership_fields_probe",
          label: "Ownership Fields Probe",
          user_id: tenantB.tenantId,
          userId: tenantB.tenantId,
          owner_id: tenantB.tenantId,
          created_by: tenantB.tenantId,
        });

      expect(res.status).toBe(201);
      expect(res.body.leadStage.tenant_id).toBe(tenantA.tenantId);
      // The route's RETURNING clause only ever selects known lead_stages
      // columns, so none of the spoofed fields can appear on the response —
      // asserting their absence here documents that fact rather than
      // depending on it silently.
      expect(res.body.leadStage).not.toHaveProperty("user_id");
      expect(res.body.leadStage).not.toHaveProperty("owner_id");
      expect(res.body.leadStage).not.toHaveProperty("created_by");
    });
  });

  // -----------------------------------------------------------------------
  // 6. Widening authorization via client-supplied scope/tenant fields.
  // -----------------------------------------------------------------------
  //
  // Both requirePermission and requireFeature derive their tenant/user
  // context exclusively from request.sessionContext (set by
  // session-context.ts from the bearer token) and never read
  // request.query/request.body at all. Both gated routes here are GET-only —
  // there is no mutation-capable permission/feature-gated route in the
  // current surface, so there is no mutation case to add; this is a property
  // of the route surface, not a gap in this suite.
  describe("6. widening authorization via client-supplied scope/tenant fields", () => {
    it("a permission the caller's role lacks (billing.manage) stays denied despite a query string claiming an elevated role/scope/tenant", async () => {
      const res = await request(app.server)
        .get("/_test/protected/permission/billing.manage")
        .query({ role: "owner", scope: "admin", tenant_id: tenantB.tenantId, isAdmin: "true" })
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(403);
      expect(res.body.error).toBe("permission_denied");
    });

    it("the same denied permission stays denied despite a request body claiming an elevated role and the missing permission directly", async () => {
      const res = await request(app.server)
        .get("/_test/protected/permission/billing.manage")
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ role: "owner", permissions: ["billing.manage"], isAdmin: true, tenantId: tenantB.tenantId });

      expect(res.status).toBe(403);
      expect(res.body.error).toBe("permission_denied");
    });

    it("an unrecognized/wildcard permission key is denied, not treated as a scope that matches everything", async () => {
      const res = await request(app.server)
        .get("/_test/protected/permission/*")
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(403);
      expect(res.body.error).toBe("permission_denied");
    });

    it("a feature entitled+enabled for another tenant only stays denied for the caller despite a query string naming that tenant", async () => {
      const res = await request(app.server)
        .get(`/_test/protected/feature/${FEATURE_KEY}`)
        .query({ tenant_id: tenantB.tenantId, tenantId: tenantB.tenantId })
        .set("Authorization", `Bearer ${tokenA}`);

      expect(res.status).toBe(403);
      expect(res.body.error).toBe("feature_not_entitled");
    });

    it("the same feature stays denied despite a request body naming the other tenant and asserting is_enabled directly", async () => {
      const res = await request(app.server)
        .get(`/_test/protected/feature/${FEATURE_KEY}`)
        .set("Authorization", `Bearer ${tokenA}`)
        .send({ tenantId: tenantB.tenantId, isEnabled: true, is_enabled: true });

      expect(res.status).toBe(403);
      expect(res.body.error).toBe("feature_not_entitled");
    });
  });
});
