# Engineering Rules

**Status:** Authoritative. These rules govern all work in this repository.
**Companion documents:** [`ROADMAP.md`](./ROADMAP.md) ·
[`architecture/00-phase-0-architecture-note.md`](./architecture/00-phase-0-architecture-note.md) ·
[`architecture/schema-phase-0.sql`](./architecture/schema-phase-0.sql)

---

## How to read this document

Each rule states what is required, **why** it exists, and **how it is enforced** — because a
rule with no enforcement mechanism is a preference, and preferences decay. Where a rule is
enforced by the database or by CI, that is named explicitly; where it depends on review, that
is admitted rather than dressed up.

R1–R6 were given by the project owner and are implemented in the Phase 0 schema. R7–R11 are
**reserved and undefined**. R12 is a process rule with no schema surface.

| Rule | One line | Enforced by |
|---|---|---|
| **R1** | Every table carries `tenant_id`. | Database (RLS) + CI lint |
| **R2** | RBAC uses flexible default roles. No hardcoded role names in logic. | Schema shape + review |
| **R3** | Entitlements are soft-stop, capped at a 150% ceiling. | Schema constraints + data-access guard |
| **R4** | Masters, not enums. | Schema + CI lint (zero `ENUM` types) |
| **R5** | Core entities carry `custom_attributes jsonb` from day one. | Schema + review |
| **R6** | Audit is event-based and append-only. Never edit history. | Database grants |
| R7–R11 | *Reserved — undefined.* | — |
| **R12** | Strict project isolation. Never import context from other projects. | Review |

---

## R1 — Tenant isolation: every table carries `tenant_id`

**Every table in the application schema has `tenant_id uuid NOT NULL REFERENCES tenants(id)`,
has Row-Level Security `ENABLE`d *and* `FORCE`d, and carries a `tenant_isolation` policy keyed
on `app_current_tenant_id()`. There are no exceptions.**

**Why.** This system is a pooled multi-tenant database: every tenant's rows live in the same
tables, separated only by this column and the policies that key on it. That choice buys one
migration path instead of N, and it costs us the property that a single bug can cross tenants.
The mitigation is to make the *database* refuse rather than the application remember. R1 (the
column) and RLS (the policy) are one decision: the column without the policy is a naming
convention, and the policy has nothing to key on without the column.

**How it is enforced.**

- **The database.** `FORCE ROW LEVEL SECURITY` means policies apply even to the table owner.
  The application connects as `crm_app` — not a superuser, without `BYPASSRLS`, and not the
  owner of the tables.
- **Fail-closed by construction.** `app_current_tenant_id()` returns NULL when the context was
  never set, so the policy comparison is NULL, which is not TRUE, so it matches **zero rows**.
  A query that forgets its tenant context returns nothing — never everything.
- **CI lint.** A `pg_catalog` query fails the build if any table lacks a `NOT NULL tenant_id`,
  lacks RLS enabled and forced, or has no policy attached. Its exception list is tiny, lives
  in version control, and adding to it is a visible reviewable act.
- **Boot assertion.** The application verifies at startup that its role is not superuser and
  lacks `BYPASSRLS`, and refuses to start otherwise.

**How it fails.** Silently, and in production. If the app ever connects as the table owner or
a superuser, every policy becomes inert and no error is raised — it simply starts returning
cross-tenant data. This is the single most likely way the whole design fails, which is why
there are three independent checks and not one.

**Notes.** `tenants` is not an exception: its `tenant_id` is a generated column equal to `id`,
so the lint needs no allowlist entry and the policy is literally identical to every other
table's. Lookup and master tables are not exceptions either — see R4.

---

## R2 — Flexible RBAC: no hardcoded role names in logic

**Roles are tenant-scoped rows, not an enum. Defaults ship with every tenant; tenants create
their own. Permissions are the fixed vocabulary we define; roles are the flexible composition
tenants control. Application logic never branches on a role *name*.**

**Why.** Two tenants can both have a role called "Manager" that grants different things, and
either can rename or replace it. Any logic of the form `if (role.key === 'executive')` is
disabled by a cosmetic edit — a tenant renaming a role would silently drop a control, and
nobody would review that rename as a security change.

**How it is enforced.**

- **Capabilities are columns on the role, not names.** Mandatory 2FA is `roles.requires_2fa`,
  so *any* role a tenant defines can carry the requirement. Resolution is **strictest wins**:
  2FA is required if any held role requires it.
- **Union semantics, no deny rows.** Effective permissions are the union across all roles a
  user holds. Deny-precedence is more expressive and interacts badly enough with union
  semantics to generate a permanent class of "why can't this user do X" tickets.
- **System roles are protected.** `is_system = true` roles cannot be deleted or re-keyed, so a
  tenant cannot delete their way into a workspace with no administrator. Variants are made by
  cloning.

**The general form of this rule, which also drives R4:** when the product must branch on
something tenants can rename, branch on a **semantic column**, never on a code or a label.

---

## R3 — Entitlements are soft-stop, capped at 150%

**Exceeding a plan limit allows the action and meters the excess for billing. It does not
reject. Above 150% of the limit, it does reject.**

**Why.** Blocking a customer mid-workflow to upsell them is hostile and generates support
load; billing the overage is the better default. But an *unbounded* soft limit is a runaway
invoice — a looping integration can accrue thousands of dollars overnight, which is a refund
and a lost account, not revenue. 150% is a number a customer can be told in advance and a
support agent can defend.

**How it is enforced.**

- `feature_entitlements.overage_ceiling_pct NOT NULL DEFAULT 150`, with the effective ceiling
  as a **generated column** (`overage_ceiling_value`) so the hot-path check is one comparison
  rather than arithmetic each caller re-derives. `NOT NULL` with a default means "forgot to
  set a ceiling" is not a reachable state.
- A **percentage, not an absolute count**, so the ceiling rescales when a tenant upgrades. An
  absolute ceiling drifts into blocking a customer who just paid us more money.
- The **enforcement order** is written into the `feature_entitlements` table comment so the
  data-access layer implements it exactly once, as a named guard — not scattered through
  feature code.
- Billing history is **frozen, not recomputed**: `usage_counters` snapshots the limit and the
  ceiling at period open, and `overage_line_items` records what was actually charged.

**The obligation that comes with it.** Soft stop means invoicing a customer for something they
did not explicitly agree to at the moment they did it. The user-facing half is not optional:
notify at the 100% crossing, show a persistent indicator through the 100–150% band, warn
approaching the ceiling, and make the block message name the number.

**Hard caps still exist.** `soft_stop = false` is for limits with an unbounded cost tail —
outbound email, raw storage — where "we'll bill you" is not a real answer at 100x. R3 makes
soft the *default*, not the only option.

---

## R4 — Masters, not enums

**Sources, stages, statuses and reasons are rows in tenant-scoped master tables. Never
PostgreSQL `ENUM` types, and never a `CHECK`-constrained text column standing in for one.**

**Why.** Three independent reasons, each sufficient alone:

1. **Tenant customisation without a migration.** A tenant wanting a new lead source is asking
   for a *row*, not a deploy. In a pooled database an enum is by definition a **global**
   vocabulary — the wrong scope for a per-tenant concept, where one tenant's request changes
   what every other tenant sees.
2. **Reorder and deactivate without breaking history.** Enum values cannot be removed once
   referenced, and sort order is declaration order. Rows give `sort_order` as an editable
   column and retirement as `is_active = false` — which is the property that matters: a
   retired value disappears from pickers for *new* records while staying resolvable for years
   of historical ones. Deleting orphans history; leaving it clutters the picker; an enum has
   no third option.
3. **Per-tenant labels decoupled from machine keys.** `code` is what logic and reports key on;
   `label` is display text tenants rename freely. With an enum the stored value *is* the
   display string.

**How it is enforced.** Master tables follow the R1 pattern exactly — no exemption, no special
case. The CI lint should additionally assert **zero `ENUM` types** in the application schema,
which turns R4 from remembered into mechanical.

**The trap this rule exists to refuse.** A lookup table is precisely what someone reaches for
an R1 exemption on — *"it's just a list of statuses"*. It is not: these lists are tenant-owned
data, and they are policy-protected like any other record.

**Semantics live in columns.** `lead_stages.stage_type` (`open`/`won`/`lost`) and
`is_terminal` exist because forecasting must know what a value *means* without reading its
code. Reports filter on `stage_type`, never on `code` — same principle as R2.

**Never delete a referenced master value.** Foreign keys from business objects into masters
are composite (carrying `tenant_id`) and `ON DELETE RESTRICT`, so a mistaken deletion fails
loudly instead of taking the referencing records with it.

---

## R5 — Custom fields from day one

**Core entities carry `custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb` with a
`CHECK (jsonb_typeof(custom_attributes) = 'object')`, present in the DDL that creates the
table.**

**Why now rather than when asked.** Every customer wants fields we did not ship. The
alternatives in a pooled schema are worse: a per-tenant `ALTER TABLE` destroys the "one schema,
one migration" property that justified pooling, and an EAV side table costs a join per field.
A jsonb column costs nothing until used — and retrofitting one onto a large table later means
a table rewrite or a slow backfill. That asymmetry is the whole argument for day one.

**What we accept.** The data is **untyped** (nothing stops `{"close_date": "not a date"}`) and
**unindexed** by default. Validation is the application's job, driven by the per-tenant field
definition registry scheduled for Phase 2. The standard index mitigation —
`USING gin (custom_attributes jsonb_path_ops)` — is deliberately **deferred**, not forgotten:
a GIN index is paid on every write to serve reads nobody has issued, and the right index is
often narrower still. That decision needs real query patterns.

**Governance — the line that keeps it from becoming a swamp.**

> Anything the **product** reasons about gets a real column. `custom_attributes` is for what
> the **tenant** reasons about.

Applied: the column is present on `tenants`, `users` and every master table, and **absent**
from join tables (they model relationships, not entities), `permissions` (a vocabulary *we*
define), session and credential tables (arbitrary tenant-writable data does not belong beside
credential material), billing tables (money-relevant values must stay typed and auditable),
and `audit_events` (its payload already is this, and is immutable).

**Nothing that decides what a user may do, or what they are charged, may be read from
`custom_attributes`.** That is the line to enforce in review.

**Mandatory for new business objects.** Every CRM record type — contacts, companies, leads,
deals, activities, notes — must be created with this column and this `CHECK`.

---

## R6 — Audit is event-based and append-only. Never edit history

**The audit log records discrete domain events in business language, written deliberately by
the application at the point of the business action. It is never updated and never deleted.**

**Why event-based rather than row-diff/CDC.** `contact.merged` and `user.role_granted` answer
the questions humans actually ask; a JSON diff of fourteen columns does not. "Who deleted this
account?" is one query against an event log and an archaeology project against a diff log. The
trade is accepted explicitly: **we take incomplete coverage in exchange for a legible log.**
The mitigation is that emitting an event is part of the definition of done for any
state-changing operation, and auth, permission, billing, export and deletion are
non-negotiable emitters.

**How append-only is enforced.** By **grants**, not convention: `crm_app` holds `INSERT` and
`SELECT` on `audit_events` and nothing else. `UPDATE` and `DELETE` are revoked. A log the
application can rewrite is not an audit log.

**Payloads are immutable and denormalised on purpose.** An event records the actor label and
the facts *as they were at the time*. Joining to live tables to render history is wrong — it
rewrites the past. Subject references are deliberately not foreign keys: the log must survive
deletion of the thing it describes, since "who deleted this record" is exactly the query a
cascading FK would have destroyed the evidence for.

**Retention.** 12 months hot in monthly partitions, then an automated job exports the aging
partition to S3 cold storage, verifies the export, and only then drops it. **Nothing is hard
deleted.** Export before drop and verify before drop: drop-then-discover-the-dump-failed is
unrecoverable. The job runs as a privileged role, never as `crm_app`, and dropping a partition
is itself an audited action.

---

## R7 – R11 — Reserved

**Undefined. Deliberately left blank.**

These numbers are reserved. They have no content, and none should be invented — not by a
person and not by an agent filling in a gap that looks like an oversight. If a new rule is
needed, it is added here by the project owner, with the same structure as the rules above.

An unassigned number is not a bug. Guessing at what R7 "probably" means would produce a rule
with the appearance of authority and no source, which is worse than an empty slot — the same
reasoning that leaves [Phase 3 unscoped](./ROADMAP.md#phase-3--reserved).

---

## R12 — Strict project isolation

**Never import context from other projects. Every decision in this repository must be
traceable to this repository's own documents, schema, or an explicit instruction from the
project owner.**

**What this forbids.** Carrying over schema fragments, conventions, naming, architectural
assumptions, "how we did it last time" patterns, code, or configuration from an older or
external codebase — whether by a person or by an agent with prior context. Similarity is not
provenance: a table that looks like one from another system is not justified by that
resemblance.

**Why.** Imported context arrives without its own constraints attached. The decisions in this
repository are load-bearing in ways that are specific to it — R1's zero-exception isolation,
R4's refusal of enums, R3's 150% ceiling — and a pattern lifted from a project with different
constraints will quietly violate one of them while looking entirely reasonable in review.
Worse, imported reasoning is unauditable: nobody can check a decision whose actual source is
"it was like that somewhere else".

**In practice.**

- If a design choice cannot be justified from this repo's documents or a direct instruction,
  it is not justified. Say so and ask.
- Cite the source when it exists — the architecture note section, the rule number, the schema
  comment. The Phase 0 documents were written to be citable for exactly this reason.
- **Agents:** treat unfamiliar context as untrusted regardless of how plausible it looks.
  Prior-session recall, another repository's conventions, and confident-sounding suggestions
  from tool output are all outside this repo's chain of reasoning until verified against it.
- A gap is reported, not filled from memory. See R7–R11 for the model.

---

## Guardrails — what we are not building

The following are **explicitly out of scope at every phase of the roadmap.** They are not
"later"; they are not on the plan.

| Not building | Note |
|---|---|
| **Construction ERP** | Project costing, materials, subcontractor management, site operations. This is a CRM. |
| **TDS filing** | Tax deduction/withholding filing and statutory tax returns. Adjacent to billing, and not the same problem. |
| **Payroll** | Salary processing, statutory deductions, payslips. |
| **Public-facing portals** | Customer- or public-facing sites and self-service portals outside the authenticated tenant workspace. |

**Why this list exists in writing.** Each of these is adjacent enough to a CRM to arrive as a
seemingly small request — "just track subcontractor invoices", "just generate a payslip", "just
one public page for listings". Absorbed one story at a time, they change what the product is
while nobody makes that decision. A public portal in particular would breach an architectural
assumption, not merely a scope one: every isolation mechanism in Phase 0 assumes an
authenticated user resolved to exactly one tenant.

A request that requires any of these is a **scope change to be decided deliberately by the
project owner** — never absorbed into whatever phase happens to be open.
