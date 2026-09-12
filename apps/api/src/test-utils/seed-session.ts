// apps/api/src/test-utils/seed-session.ts
//
// Test-only session seeding helper — Phase 0 gate work
// (Beads issue Final-Verison-x9u). Stands in for "authenticate as tenant A"
// given there is no login/signup endpoint yet (that's Phase 1). This is a
// function, not an HTTP route: it inserts directly into the existing
// `sessions` table and hands back the raw bearer token for a test's setup
// step to send as `Authorization: Bearer <token>`.
//
// Deliberately NOT exposed over HTTP — a public "create me a session for any
// tenant/user" endpoint would be an authentication bypass, not a test tool.

import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { withTenantContext } from "@crm/db";
import { generateSessionToken, hashSessionToken } from "../lib/session-token.js";

export interface SeedSessionInput {
  tenantId: string;
  userId: string;
  /** Defaults to 24h, matching the schema's absolute-expiry default. */
  ttlHours?: number;
  /** Defaults to 'full' — the only scope that passes session-context validation. */
  scope?: "full" | "mfa_enrolment" | "mfa_challenge";
}

export interface SeedSessionResult {
  sessionId: string;
  token: string;
  expiresAt: Date;
}

/**
 * Inserts a session row for (tenantId, userId) and returns the raw bearer
 * token. Runs through withTenantContext() like every other write in this
 * codebase, per the architecture note §3.3 — including test seeding, which
 * doubles as a check that the tenant_id passed in actually exists and that
 * RLS's WITH CHECK accepts the insert.
 */
export async function seedSession(input: SeedSessionInput): Promise<SeedSessionResult> {
  const token = generateSessionToken();
  const tokenHash = hashSessionToken(token);
  const scope = input.scope ?? "full";
  const ttlHours = input.ttlHours ?? 24;

  const sessionId = randomUUID();

  const rows = await withTenantContext(input.tenantId, async (tx) => {
    const result = await tx.execute(sql`
      INSERT INTO sessions (id, tenant_id, user_id, token_hash, scope, mfa_satisfied, expires_at)
      VALUES (
        ${sessionId},
        ${input.tenantId},
        ${input.userId},
        ${tokenHash},
        ${scope},
        true,
        now() + (${ttlHours} || ' hours')::interval
      )
      RETURNING id, expires_at
    `);
    return Array.isArray(result) ? result : (result as { rows: unknown[] }).rows;
  });

  const row = rows[0] as { id: string; expires_at: string | Date };

  return {
    sessionId: row.id,
    token,
    expiresAt: new Date(row.expires_at),
  };
}
