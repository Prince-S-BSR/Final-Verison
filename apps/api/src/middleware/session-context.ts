// apps/api/src/middleware/session-context.ts
//
// Resolves a bearer token to { tenantId, userId } via a real, live lookup
// against the existing `sessions` table (packages/db) — no hardcoded users
// or tokens, no JWT, no login flow. This is Phase 0 gate work
// (Beads issue Final-Verison-x9u): it exists so the R1/R2/R3 HTTP test
// suite has something to authenticate against, given there is no signup/
// login endpoint yet (that is Phase 1 scope).
//
// WHY THIS DOESN'T GO THROUGH withTenantContext() LIKE EVERYTHING ELSE:
// `sessions` is a tenant-scoped, RLS-protected table (tenant_id =
// app_current_tenant_id()), but the entire point of this lookup is to
// DISCOVER the tenant_id from the token — no tenant context can be
// SET LOCAL before that is known. This is the exact chicken-and-egg problem
// the architecture note already identifies for subdomain -> tenant_id
// resolution (00-phase-0-architecture-note.md §4.2) and explicitly
// prescribes a fix for: "a narrowly-scoped read ... through a separate role
// or a SECURITY DEFINER function that returns nothing but (id, status)".
// `resolve_session_context()` (packages/db/drizzle/0001_session_lookup_function.sql)
// is that function, applied to sessions instead of the subdomain lookup it
// was written for — same shape, same mitigation, not a new architectural
// decision. It returns only the columns needed to accept or reject a
// session and nothing else (never token_hash, ip_address, or user_agent).
//
// Once tenantId/userId are resolved here, every subsequent query in this
// request (requirePermission, requireFeature, the _test/ routes) goes
// through withTenantContext() as required.

import type { FastifyReply, FastifyRequest } from "fastify";
import { sql } from "drizzle-orm";
import { db } from "@crm/db";
import { hashSessionToken } from "../lib/session-token.js";

export interface SessionContext {
  sessionId: string;
  tenantId: string;
  userId: string;
}

declare module "fastify" {
  interface FastifyRequest {
    sessionContext?: SessionContext;
  }
}

function extractBearerToken(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header);
  return match ? match[1].trim() : null;
}

/**
 * Fastify preHandler. Populates `request.sessionContext` on success, or
 * replies 401 and short-circuits the request on any failure:
 *   - missing/malformed Authorization header
 *   - token does not resolve to any session row
 *   - session has been revoked (`revoked_at IS NOT NULL`)
 *   - session's absolute expiry has passed (`expires_at <= now()`)
 *   - session is a restricted, non-'full' scope (e.g. an mfa_enrolment
 *     session per schema-phase-0.sql §4.2 — out of scope for Phase 0 but
 *     the check costs nothing and matches the table comment's documented
 *     validity rule)
 */
export async function sessionContextPreHandler(
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<void> {
  const token = extractBearerToken(request);
  if (!token) {
    await reply.code(401).send({ error: "missing_bearer_token" });
    return;
  }

  const tokenHash = hashSessionToken(token);

  const result = await db.execute(
    sql`SELECT session_id, tenant_id, user_id, expires_at, revoked_at, scope
        FROM resolve_session_context(${tokenHash})`,
  );

  const row = result[0] as
    | {
        session_id: string;
        tenant_id: string;
        user_id: string;
        expires_at: string | Date;
        revoked_at: string | Date | null;
        scope: string;
      }
    | undefined;

  if (!row) {
    await reply.code(401).send({ error: "invalid_session" });
    return;
  }

  if (row.revoked_at !== null) {
    await reply.code(401).send({ error: "session_revoked" });
    return;
  }

  if (new Date(row.expires_at).getTime() <= Date.now()) {
    await reply.code(401).send({ error: "session_expired" });
    return;
  }

  if (row.scope !== "full") {
    await reply.code(401).send({ error: "session_scope_restricted" });
    return;
  }

  request.sessionContext = {
    sessionId: row.session_id,
    tenantId: row.tenant_id,
    userId: row.user_id,
  };
}
