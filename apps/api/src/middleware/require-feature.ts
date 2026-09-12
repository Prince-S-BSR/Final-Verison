// apps/api/src/middleware/require-feature.ts
//
// requireFeature(key) — Phase 0 gate work (Beads issue Final-Verison-x9u).
//
// Checks `feature_entitlements` LIVE, on every request, for the resolved
// tenant + feature key, and 403s if the row is absent or `is_enabled` is
// false. This intentionally implements only step 2 of the enforcement order
// documented on the feature_entitlements table comment in
// packages/db/drizzle/0000_phase0_foundation.sql ("if NOT is_enabled ->
// reject") — the full soft-stop/150%-ceiling usage accounting (steps 3-9) is
// R3's data-access-layer guard, a Phase 1 deliverable once there is a real
// metered feature to guard, and is explicitly out of scope for this Phase 0
// gate per the issue brief. Toggling `is_enabled` on the DB row changes
// behavior on the next request with no restart.

import type { FastifyReply, FastifyRequest } from "fastify";
import { sql } from "drizzle-orm";
import { withTenantContext } from "@crm/db";

function extractRows(result: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(result)) return result as Array<Record<string, unknown>>;
  if (result && typeof result === "object" && Array.isArray((result as { rows?: unknown }).rows)) {
    return (result as { rows: Array<Record<string, unknown>> }).rows;
  }
  return [];
}

export function requireFeature(featureKey: string) {
  return async function requireFeaturePreHandler(
    request: FastifyRequest,
    reply: FastifyReply,
  ): Promise<void> {
    const ctx = request.sessionContext;
    if (!ctx) {
      await reply.code(401).send({ error: "no_session_context" });
      return;
    }

    const result = await withTenantContext(ctx.tenantId, async (tx) => {
      return tx.execute(sql`
        SELECT is_enabled
        FROM feature_entitlements
        WHERE tenant_id = ${ctx.tenantId}
          AND feature_key = ${featureKey}
      `);
    });

    const rows = extractRows(result);
    const entitlement = rows[0] as { is_enabled?: boolean } | undefined;

    if (!entitlement || entitlement.is_enabled !== true) {
      await reply.code(403).send({ error: "feature_not_entitled", feature: featureKey });
      return;
    }
  };
}
