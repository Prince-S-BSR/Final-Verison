// apps/api/src/middleware/require-permission.ts
//
// requirePermission(key) — Phase 0 gate work (Beads issue Final-Verison-x9u).
//
// Builds the caller's effective permission set LIVE, on every request, by
// walking user_roles -> roles -> role_permissions -> permissions for the
// resolved userId. No caching, no hardcoded role or permission names: the
// only thing this file knows about is the shape of the join, per R2
// ("application logic never branches on a role *name*" —
// docs/ENGINEERING_RULES.md). Changing a role_permissions row changes what
// this middleware allows on the very next request.
//
// All access runs through withTenantContext() (packages/db/client.ts) so the
// query executes under the resolved tenant's RLS context, per architecture
// note §3.3 — this is belt-and-suspenders alongside the explicit tenant_id
// filters below, not a substitute for them.

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

export function requirePermission(permissionKey: string) {
  return async function requirePermissionPreHandler(
    request: FastifyRequest,
    reply: FastifyReply,
  ): Promise<void> {
    const ctx = request.sessionContext;
    if (!ctx) {
      // Should be unreachable if sessionContextPreHandler runs first, but
      // fail closed rather than assume.
      await reply.code(401).send({ error: "no_session_context" });
      return;
    }

    const result = await withTenantContext(ctx.tenantId, async (tx) => {
      return tx.execute(sql`
        SELECT DISTINCT p.key
        FROM user_roles ur
        JOIN roles r
          ON r.tenant_id = ur.tenant_id AND r.id = ur.role_id
        JOIN role_permissions rp
          ON rp.tenant_id = r.tenant_id AND rp.role_id = r.id
        JOIN permissions p
          ON p.tenant_id = rp.tenant_id AND p.id = rp.permission_id
        WHERE ur.tenant_id = ${ctx.tenantId}
          AND ur.user_id = ${ctx.userId}
      `);
    });

    const grantedKeys = new Set(
      extractRows(result).map((row) => row.key as string),
    );

    if (!grantedKeys.has(permissionKey)) {
      await reply.code(403).send({ error: "permission_denied", permission: permissionKey });
      return;
    }
  };
}
