// apps/api/test/support/provision.ts
//
// Test-only DB seeding/mutation helpers for the R1/R2/R3 integration suite
// (Beads issue Final-Verison-ikv). These call the SAME provisioning
// functions and the SAME withTenantContext() choke point the application
// itself uses (packages/db/client.ts, docs/architecture note §3.3) — nothing
// here bypasses RLS or uses a privileged connection. This is deliberately
// how the prior task's manual verification provisioned tenants: generate the
// tenant's own uuid, SET LOCAL app.current_tenant_id to it, then insert —
// which satisfies the tenants table's own `WITH CHECK (tenant_id =
// app_current_tenant_id())` policy without any bypass.
//
// The "mid-test, directly via the DB" mutations required by R2 and R3 (revoke
// a permission, toggle a feature flag) also go through withTenantContext(),
// per the issue brief: "directly via the DB — not through any API, since no
// admin API exists yet." withTenantContext() is the data-access layer, not an
// API — it is the same choke point Phase 1 feature code will use.

import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { withTenantContext, closeDbConnection } from "@crm/db";
import { extractRows } from "./rows.js";

export interface TestTenant {
  tenantId: string;
  subdomain: string;
}

let uniqueCounter = 0;

/** Collision-resistant label for subdomains/emails across repeated test runs. */
function uniqueLabel(prefix: string): string {
  uniqueCounter += 1;
  return `${prefix}-${Date.now()}-${uniqueCounter}-${randomUUID().slice(0, 8)}`;
}

/**
 * Provisions a brand-new tenant the same way real tenant signup would:
 * generate the id, set tenant context to it, insert the row, then run the
 * same two provisioning functions the architecture note prescribes
 * (§9.1/§9.2) so the tenant has real default roles/permissions and R4 master
 * data — not a stubbed-down fixture.
 */
export async function provisionTenant(prefix = "t"): Promise<TestTenant> {
  const tenantId = randomUUID();
  const subdomain = uniqueLabel(prefix).toLowerCase().slice(0, 63);

  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      INSERT INTO tenants (id, subdomain, name, status)
      VALUES (${tenantId}, ${subdomain}, ${prefix}, 'active')
    `);
    await tx.execute(sql`SELECT provision_tenant_rbac_defaults(${tenantId}::uuid)`);
    await tx.execute(sql`SELECT provision_tenant_master_data(${tenantId}::uuid)`);
  });

  return { tenantId, subdomain };
}

export async function createUser(tenantId: string, emailPrefix = "user"): Promise<string> {
  const userId = randomUUID();
  const email = `${uniqueLabel(emailPrefix)}@example.test`;

  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      INSERT INTO users (id, tenant_id, email, status)
      VALUES (${userId}, ${tenantId}, ${email}, 'active')
    `);
  });

  return userId;
}

export async function getRoleIdByKey(tenantId: string, roleKey: string): Promise<string> {
  return withTenantContext(tenantId, async (tx) => {
    const result = await tx.execute(sql`
      SELECT id FROM roles WHERE tenant_id = ${tenantId} AND key = ${roleKey}
    `);
    const row = extractRows(result)[0];
    if (!row) throw new Error(`test setup: role not found for key "${roleKey}"`);
    return row.id as string;
  });
}

export async function getPermissionIdByKey(tenantId: string, permissionKey: string): Promise<string> {
  return withTenantContext(tenantId, async (tx) => {
    const result = await tx.execute(sql`
      SELECT id FROM permissions WHERE tenant_id = ${tenantId} AND key = ${permissionKey}
    `);
    const row = extractRows(result)[0];
    if (!row) throw new Error(`test setup: permission not found for key "${permissionKey}"`);
    return row.id as string;
  });
}

export async function assignRole(tenantId: string, userId: string, roleId: string): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      INSERT INTO user_roles (tenant_id, user_id, role_id)
      VALUES (${tenantId}, ${userId}, ${roleId})
      ON CONFLICT DO NOTHING
    `);
  });
}

/** R2 mid-test mutation: grant a role a permission it did not previously have. */
export async function grantPermission(tenantId: string, roleId: string, permissionId: string): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      INSERT INTO role_permissions (tenant_id, role_id, permission_id)
      VALUES (${tenantId}, ${roleId}, ${permissionId})
      ON CONFLICT DO NOTHING
    `);
  });
}

/** R2 mid-test mutation: revoke a permission a role currently has. */
export async function revokePermission(tenantId: string, roleId: string, permissionId: string): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      DELETE FROM role_permissions
      WHERE tenant_id = ${tenantId} AND role_id = ${roleId} AND permission_id = ${permissionId}
    `);
  });
}

/**
 * Creates a subscription + a single feature_entitlements row for R3 tests.
 * subscription_id on feature_entitlements has no FK constraint in the schema,
 * but a real subscription row is inserted anyway so the fixture matches what
 * real provisioning produces rather than relying on that schema looseness.
 */
export async function createFeatureEntitlement(
  tenantId: string,
  featureKey: string,
  isEnabled: boolean,
): Promise<string> {
  const subscriptionId = randomUUID();
  const entitlementId = randomUUID();

  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      INSERT INTO subscriptions (id, tenant_id, plan_tier, status, current_period_start, current_period_end)
      VALUES (${subscriptionId}, ${tenantId}, 'professional', 'active', now(), now() + interval '30 days')
    `);
    await tx.execute(sql`
      INSERT INTO feature_entitlements (id, tenant_id, subscription_id, feature_key, is_enabled)
      VALUES (${entitlementId}, ${tenantId}, ${subscriptionId}, ${featureKey}, ${isEnabled})
    `);
  });

  return entitlementId;
}

/** R3 mid-test mutation: toggle feature_entitlements.is_enabled directly. */
export async function setFeatureEnabled(tenantId: string, entitlementId: string, isEnabled: boolean): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      UPDATE feature_entitlements
      SET is_enabled = ${isEnabled}
      WHERE tenant_id = ${tenantId} AND id = ${entitlementId}
    `);
  });
}

export async function insertLeadStage(tenantId: string, code: string, label: string): Promise<string> {
  return withTenantContext(tenantId, async (tx) => {
    const result = await tx.execute(sql`
      INSERT INTO lead_stages (tenant_id, code, label, sort_order, stage_type)
      VALUES (${tenantId}, ${code}, ${label}, 500, 'open')
      RETURNING id
    `);
    return extractRows(result)[0].id as string;
  });
}

export async function revokeSession(tenantId: string, sessionId: string): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`
      UPDATE sessions SET revoked_at = now(), revoked_reason = 'admin_revoked'
      WHERE tenant_id = ${tenantId} AND id = ${sessionId}
    `);
  });
}

/**
 * Deletes a tenant, relying on the ON DELETE CASCADE from every child table's
 * tenant_id FK (subscriptions, feature_entitlements, users, roles,
 * permissions, role_permissions, user_roles, sessions, lead_stages, etc. —
 * see schema-phase-0.sql) to tear down everything seeded for it. Runs under
 * that tenant's own context, so it satisfies the same tenant_isolation policy
 * as every other write here — no bypass needed to clean up what was created
 * without one.
 */
export async function deleteTenant(tenantId: string): Promise<void> {
  await withTenantContext(tenantId, async (tx) => {
    await tx.execute(sql`DELETE FROM tenants WHERE id = ${tenantId}`);
  });
}

export { closeDbConnection };
