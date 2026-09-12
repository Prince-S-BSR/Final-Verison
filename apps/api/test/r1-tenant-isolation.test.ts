// apps/api/test/r1-tenant-isolation.test.ts
//
// R1 — tenant data isolation, exercised over real HTTP requests against
// /_test/tenant-data/lead-stages (lead_stages is R4 master/config data, the
// one sanctioned exception per docs/ENGINEERING_RULES.md R4 — not a business
// record). Two real tenants are provisioned in Postgres; nothing here reads
// or writes through a mock.

import { randomUUID } from "node:crypto";
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
  getRoleIdByKey,
  insertLeadStage,
  provisionTenant,
  type TestTenant,
} from "./support/provision.js";

describe("R1 — tenant data isolation (/_test/tenant-data/lead-stages)", () => {
  let app: FastifyInstance;
  let tenantA: TestTenant;
  let tenantB: TestTenant;
  let tokenA: string;
  let tokenB: string;
  let tenantBOnlyStageId: string;

  beforeAll(async () => {
    app = await startTestApp();

    tenantA = await provisionTenant("r1-a");
    tenantB = await provisionTenant("r1-b");

    const userA = await createUser(tenantA.tenantId, "user-a");
    const userB = await createUser(tenantB.tenantId, "user-b");

    const ownerRoleA = await getRoleIdByKey(tenantA.tenantId, "owner");
    const ownerRoleB = await getRoleIdByKey(tenantB.tenantId, "owner");
    await assignRole(tenantA.tenantId, userA, ownerRoleA);
    await assignRole(tenantB.tenantId, userB, ownerRoleB);

    tokenA = (await seedSession({ tenantId: tenantA.tenantId, userId: userA })).token;
    tokenB = (await seedSession({ tenantId: tenantB.tenantId, userId: userB })).token;

    tenantBOnlyStageId = await insertLeadStage(tenantB.tenantId, "b_only_stage", "B Only Stage");
  });

  afterAll(async () => {
    await app.close();
    await deleteTenant(tenantA.tenantId);
    await deleteTenant(tenantB.tenantId);
    await closeDbConnection();
  });

  it("GET as tenant A returns only tenant A's rows, never tenant B's", async () => {
    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`);

    expect(res.status).toBe(200);
    expect(res.body.leadStages.length).toBeGreaterThan(0);
    for (const stage of res.body.leadStages as Array<{ tenant_id: string; id: string }>) {
      expect(stage.tenant_id).toBe(tenantA.tenantId);
    }
    const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
    expect(ids).not.toContain(tenantBOnlyStageId);
  });

  it("GET as tenant B sees its own row and nothing from tenant A's default seed", async () => {
    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenB}`);

    expect(res.status).toBe(200);
    const ids = (res.body.leadStages as Array<{ id: string }>).map((s) => s.id);
    expect(ids).toContain(tenantBOnlyStageId);
    for (const stage of res.body.leadStages as Array<{ tenant_id: string }>) {
      expect(stage.tenant_id).toBe(tenantB.tenantId);
    }
  });

  it("POST as tenant A creates a row scoped to tenant A, invisible to tenant B", async () => {
    const createRes = await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ code: "a_created_stage", label: "A Created Stage" });

    expect(createRes.status).toBe(201);
    const created = createRes.body.leadStage;
    expect(created.tenant_id).toBe(tenantA.tenantId);

    const getAsA = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`);
    expect((getAsA.body.leadStages as Array<{ id: string }>).some((s) => s.id === created.id)).toBe(true);

    const getAsB = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenB}`);
    expect((getAsB.body.leadStages as Array<{ id: string }>).some((s) => s.id === created.id)).toBe(false);
  });

  it("PATCH as tenant A against a row that belongs to tenant B 404s, not a silent no-op", async () => {
    const res = await request(app.server)
      .patch(`/_test/tenant-data/lead-stages/${tenantBOnlyStageId}`)
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ label: "Hijacked From Tenant A" });

    expect(res.status).toBe(404);
    expect(res.body.error).toBe("lead_stage_not_found");

    // Confirm it really is a no-op, not a partial write before the 404.
    const asB = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenB}`);
    const stillB = (asB.body.leadStages as Array<{ id: string; label: string }>).find(
      (s) => s.id === tenantBOnlyStageId,
    );
    expect(stillB?.label).toBe("B Only Stage");
  });

  it("PATCH as tenant A against a random non-existent id 404s the same way", async () => {
    const res = await request(app.server)
      .patch(`/_test/tenant-data/lead-stages/${randomUUID()}`)
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ label: "Does Not Exist" });

    expect(res.status).toBe(404);
    expect(res.body.error).toBe("lead_stage_not_found");
  });

  it("PATCH with a malformed (non-UUID) id fails cleanly rather than 500ing", async () => {
    const res = await request(app.server)
      .patch("/_test/tenant-data/lead-stages/not-a-uuid")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ label: "Does Not Matter" });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe("update_failed");
  });

  it("PATCH as tenant A against its own row succeeds", async () => {
    const createRes = await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ code: "a_patchable_stage", label: "Before Patch" });
    const stageId = createRes.body.leadStage.id;

    const patchRes = await request(app.server)
      .patch(`/_test/tenant-data/lead-stages/${stageId}`)
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ label: "After Patch" });

    expect(patchRes.status).toBe(200);
    expect(patchRes.body.leadStage.label).toBe("After Patch");
    expect(patchRes.body.leadStage.tenant_id).toBe(tenantA.tenantId);
  });

  it("POST without required fields is rejected with 400, not a partial insert", async () => {
    const res = await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ description: "missing code and label" });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe("code_and_label_required");
  });

  it("POST with a duplicate code for the same tenant fails rather than silently overwriting", async () => {
    await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ code: "dup_stage", label: "First" })
      .expect(201);

    const dup = await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ code: "dup_stage", label: "Second" });

    expect(dup.status).toBe(400);
    expect(dup.body.error).toBe("insert_failed");
  });

  it("PATCH with no updatable fields is rejected with 400", async () => {
    const createRes = await request(app.server)
      .post("/_test/tenant-data/lead-stages")
      .set("Authorization", `Bearer ${tokenA}`)
      .send({ code: "empty_patch_target", label: "Untouched" });
    const stageId = createRes.body.leadStage.id;

    const res = await request(app.server)
      .patch(`/_test/tenant-data/lead-stages/${stageId}`)
      .set("Authorization", `Bearer ${tokenA}`)
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.error).toBe("no_fields_to_update");
  });

  it("requests with no Authorization header are rejected with 401 before touching tenant data", async () => {
    const res = await request(app.server).get("/_test/tenant-data/lead-stages");
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("missing_bearer_token");
  });

  it("requests with a garbage bearer token are rejected with 401, not treated as any tenant", async () => {
    const res = await request(app.server)
      .get("/_test/tenant-data/lead-stages")
      .set("Authorization", "Bearer not-a-real-token");
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("invalid_session");
  });
});
