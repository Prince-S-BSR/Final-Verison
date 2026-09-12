// packages/db/schema.ts
//
// Phase 0 scope note: this file does NOT attempt to type the full 20-table
// schema in docs/architecture/schema-phase-0.sql. The canonical source of
// truth for the schema is that SQL file (copied verbatim as the initial
// migration at ./drizzle/0000_phase0_foundation.sql) — hand-translating 20
// tables' worth of RLS policies, generated columns, triggers and check
// constraints into Drizzle's schema DSL here would risk drift between "what
// Drizzle thinks the schema is" and "what is actually running."
//
// What follows is just enough TypeScript table typing (`tenants`, `users`)
// to prove the wiring works end-to-end — a type-safe query against a real
// table. Typing the remaining ~18 tables (roles, permissions, the R4 master
// tables, sessions, audit_events, entitlements, etc.) is Phase 1 work, done
// incrementally as each business object that needs it is built, per
// docs/ROADMAP.md Phase 1 scope.

import {
  pgTable,
  uuid,
  text,
  jsonb,
  boolean,
  integer,
  timestamp,
} from "drizzle-orm/pg-core";

export const tenants = pgTable("tenants", {
  id: uuid("id").primaryKey().defaultRandom(),
  // Generated column (`GENERATED ALWAYS AS (id) STORED`) in the SQL migration —
  // see schema-phase-0.sql §1 for why. Drizzle just needs to know the column
  // exists and is not null; it never writes to it.
  tenantId: uuid("tenant_id").notNull(),
  subdomain: text("subdomain").notNull(),
  name: text("name").notNull(),
  status: text("status").notNull().default("provisioning"),
  customAttributes: jsonb("custom_attributes").notNull().default({}),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  tenantId: uuid("tenant_id").notNull(),
  email: text("email").notNull(),
  passwordHash: text("password_hash"),
  fullName: text("full_name"),
  status: text("status").notNull().default("invited"),
  mfaEnrolledAt: timestamp("mfa_enrolled_at", { withTimezone: true }),
  mfaEnabled: boolean("mfa_enabled").notNull().default(false),
  lastLoginAt: timestamp("last_login_at", { withTimezone: true }),
  failedLoginCount: integer("failed_login_count").notNull().default(0),
  lockedUntil: timestamp("locked_until", { withTimezone: true }),
  customAttributes: jsonb("custom_attributes").notNull().default({}),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

export type Tenant = typeof tenants.$inferSelect;
export type NewTenant = typeof tenants.$inferInsert;
export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
