# @crm/db

Drizzle ORM + Postgres wiring for the CRM monorepo.

## Layout

- `drizzle/0000_phase0_foundation.sql` — copied verbatim from
  `docs/architecture/schema-phase-0.sql` (the canonical, already-verified
  source; see that file and `docs/architecture/00-phase-0-architecture-note.md`).
  This is **not** hand-translated into Drizzle's schema DSL because the file
  has hand-written RLS policies, generated columns, and triggers that the DSL
  cannot express faithfully — copying avoids introducing drift.
- `drizzle/meta/_journal.json` — hand-written (not `drizzle-kit generate`-d)
  so `drizzle-kit` tooling recognizes the copied file as migration `0000`.
  `breakpoints` is `false` because the copied SQL has no
  `--> statement-breakpoint` markers inserted (deliberately, to keep it
  byte-for-byte identical to the canonical file).
- `schema.ts` — hand-written TypeScript table definitions for `tenants` and
  `users` only, enough for a type-safe smoke-test query. The other ~18 tables
  are typed incrementally in Phase 1 as each business object needs them — see
  the comment at the top of `schema.ts`.
- `client.ts` — the Drizzle client and the `withTenantContext()` helper that
  implements the `SET LOCAL app.current_tenant_id` pattern from the
  architecture note §3.3. Not called from any route yet (Phase 0 has none).

## Verifying the migration applies

In this sandbox, the migration was verified directly with `psql` against a
throwaway local database (see the Phase 0 scaffolding task notes / PR
description for the exact commands and output), per the schema file's own
verification table (`00-phase-0-architecture-note.md` §12). `drizzle-kit`
config (`drizzle.config.ts`) is wired for future incremental migrations via
`npm run db:generate` / `db:migrate`, but the initial migration's correctness
was checked against raw Postgres rather than through the drizzle-kit runner,
since it is a straight copy of an already-verified file rather than
drizzle-kit-generated output.

## Environment

Requires `DATABASE_URL` (see `.env.example` at the repo root).
