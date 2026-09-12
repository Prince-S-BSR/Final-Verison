// apps/api/src/routes/test-only.ts
//
// THROWAWAY, TEST-ONLY ROUTES — Phase 0 gate work (Beads issue
// Final-Verison-x9u). Everything in this file is prefixed `/_test/` so it
// cannot be mistaken for a real product route later. It exists purely so a
// later integration-test task (Final-Verison-ikv) can prove R1 (tenant
// isolation), R2 (dynamic RBAC) and R3 (entitlements) actually hold over
// real HTTP requests, not just that the database tables are shaped
// correctly.
//
// Scope boundary: `lead_stages` is used here for R1 exercise because it is
// R4 master/config data (a lookup table), not a business record — see
// docs/ENGINEERING_RULES.md R4 and the issue's CRITICAL SCOPE BOUNDARY.
// Nothing here touches leads, deals, contacts, or any other business-feature
// table, and nothing here is a real product route.

import type { FastifyInstance } from "fastify";
import { sql, type SQL } from "drizzle-orm";
import { withTenantContext } from "@crm/db";
import { sessionContextPreHandler } from "../middleware/session-context.js";
import { requirePermission } from "../middleware/require-permission.js";
import { requireFeature } from "../middleware/require-feature.js";

function extractRows(result: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(result)) return result as Array<Record<string, unknown>>;
  if (result && typeof result === "object" && Array.isArray((result as { rows?: unknown }).rows)) {
    return (result as { rows: Array<Record<string, unknown>> }).rows;
  }
  return [];
}

interface LeadStageCreateBody {
  code: string;
  label: string;
  description?: string;
  sortOrder?: number;
  stageType?: "open" | "won" | "lost";
  probabilityPct?: number;
}

interface LeadStageUpdateBody {
  label?: string;
  description?: string;
  sortOrder?: number;
  isActive?: boolean;
  stageType?: "open" | "won" | "lost";
  probabilityPct?: number | null;
}

export default async function testOnlyRoutes(app: FastifyInstance): Promise<void> {
  // Every _test/ route requires a resolved session. Session resolution is a
  // real DB lookup every time (see middleware/session-context.ts) — no
  // hardcoded users or tokens.
  app.addHook("preHandler", sessionContextPreHandler);

  // ---------------------------------------------------------------------
  // R1 — tenant isolation, exercised against lead_stages (R4 master data).
  // ---------------------------------------------------------------------

  app.get("/_test/tenant-data/lead-stages", async (request) => {
    const { tenantId } = request.sessionContext!;
    const result = await withTenantContext(tenantId, (tx) =>
      tx.execute(sql`
        SELECT id, tenant_id, code, label, description, sort_order,
               is_active, is_system, stage_type, probability_pct
        FROM lead_stages
        WHERE tenant_id = ${tenantId}
        ORDER BY sort_order, label
      `),
    );
    return { leadStages: extractRows(result) };
  });

  app.post<{ Body: LeadStageCreateBody }>(
    "/_test/tenant-data/lead-stages",
    async (request, reply) => {
      const { tenantId } = request.sessionContext!;
      const { code, label, description, sortOrder, stageType, probabilityPct } = request.body ?? {};

      if (!code || !label) {
        await reply.code(400).send({ error: "code_and_label_required" });
        return;
      }

      try {
        const result = await withTenantContext(tenantId, (tx) =>
          tx.execute(sql`
            INSERT INTO lead_stages (tenant_id, code, label, description, sort_order, stage_type, probability_pct)
            VALUES (
              ${tenantId},
              ${code},
              ${label},
              ${description ?? null},
              ${sortOrder ?? 0},
              ${stageType ?? "open"},
              ${probabilityPct ?? null}
            )
            RETURNING id, tenant_id, code, label, description, sort_order,
                      is_active, is_system, stage_type, probability_pct
          `),
        );
        const [row] = extractRows(result);
        await reply.code(201).send({ leadStage: row });
      } catch (err) {
        request.log.error(err, "failed to insert lead_stage");
        await reply.code(400).send({ error: "insert_failed", detail: (err as Error).message });
      }
    },
  );

  app.patch<{ Params: { id: string }; Body: LeadStageUpdateBody }>(
    "/_test/tenant-data/lead-stages/:id",
    async (request, reply) => {
      const { tenantId } = request.sessionContext!;
      const { id } = request.params;
      const body = request.body ?? {};

      // Build the SET clause from only the fields actually present in the
      // request body, so an omitted field is left untouched rather than
      // overwritten with NULL.
      const assignments: SQL[] = [];
      if (body.label !== undefined) assignments.push(sql`label = ${body.label}`);
      if (body.description !== undefined) assignments.push(sql`description = ${body.description}`);
      if (body.sortOrder !== undefined) assignments.push(sql`sort_order = ${body.sortOrder}`);
      if (body.isActive !== undefined) assignments.push(sql`is_active = ${body.isActive}`);
      if (body.stageType !== undefined) assignments.push(sql`stage_type = ${body.stageType}`);
      if (body.probabilityPct !== undefined) {
        assignments.push(sql`probability_pct = ${body.probabilityPct}`);
      }

      if (assignments.length === 0) {
        await reply.code(400).send({ error: "no_fields_to_update" });
        return;
      }

      try {
        const result = await withTenantContext(tenantId, (tx) =>
          tx.execute(sql`
            UPDATE lead_stages
            SET ${sql.join(assignments, sql`, `)}
            WHERE tenant_id = ${tenantId} AND id = ${id}
            RETURNING id, tenant_id, code, label, description, sort_order,
                      is_active, is_system, stage_type, probability_pct
          `),
        );
        const [row] = extractRows(result);
        if (!row) {
          // Either the row doesn't exist, or it belongs to another tenant —
          // RLS makes those indistinguishable from here, which is R1 working
          // as designed: a cross-tenant write reports "not found", never
          // "forbidden" (which would confirm the row's existence).
          await reply.code(404).send({ error: "lead_stage_not_found" });
          return;
        }
        await reply.send({ leadStage: row });
      } catch (err) {
        request.log.error(err, "failed to update lead_stage");
        await reply.code(400).send({ error: "update_failed", detail: (err as Error).message });
      }
    },
  );

  // ---------------------------------------------------------------------
  // R2 — dynamic RBAC.
  // ---------------------------------------------------------------------

  app.get<{ Params: { key: string } }>(
    "/_test/protected/permission/:key",
    { preHandler: (request, reply) => requirePermission(request.params.key)(request, reply) },
    async () => {
      return { ok: true };
    },
  );

  // ---------------------------------------------------------------------
  // R3 — entitlements (is_enabled gate only; see middleware/require-feature.ts
  // for why the full 150%-ceiling soft-stop accounting is out of scope here).
  // ---------------------------------------------------------------------

  app.get<{ Params: { key: string } }>(
    "/_test/protected/feature/:key",
    { preHandler: (request, reply) => requireFeature(request.params.key)(request, reply) },
    async () => {
      return { ok: true };
    },
  );
}
