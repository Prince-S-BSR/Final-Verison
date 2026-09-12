# Product & Engineering Roadmap

> **SUPERSEDED — 2026-09-12.** Per explicit project-owner decision, this roadmap is superseded
> by [`docs/BMEXA_MASTER_SPEC.md`](./BMEXA_MASTER_SPEC.md) §§77–86, which is now the source of
> truth for all future phase planning. This file is **retained as historical/reference
> material** — it documented the roadmap before the BMexa specification arrived, and the phase
> content below is kept as a historical record, not deleted or rewritten. Do not plan new work
> against the phase sequence below; plan against the BMexa Master Spec instead.

**Status:** Living document. Phase 0 is complete; everything after it is plan, not promise.
**Companion documents:** [`ENGINEERING_RULES.md`](./ENGINEERING_RULES.md) ·
[`architecture/00-phase-0-architecture-note.md`](./architecture/00-phase-0-architecture-note.md) ·
[`architecture/schema-phase-0.sql`](./architecture/schema-phase-0.sql)

---

## 0. The Phase Gate rule

> **No work begins on phase N+1 until phase N has passed its written acceptance test.**

This is the single rule that makes the rest of this document mean anything. Without it a
roadmap is a wish list, and phases become labels applied retroactively to whatever got built.

What it requires in practice:

1. **Every phase has a written acceptance test before work on it starts.** Not a summary
   afterwards — a checkable statement of what "done" means, written while the phase is still
   cheap to argue about. Phase 0's is the verification table in
   [§12 of the architecture note](./architecture/00-phase-0-architecture-note.md); it was
   executed against a real PostgreSQL 16 instance, not asserted.
2. **The test is binary.** It passes or it does not. "Mostly working" is a fail. A test that
   cannot fail is not a test.
3. **A failed gate stops the next phase, it does not shrink the test.** The failure mode this
   rule exists to prevent is the one where the acceptance criteria quietly get edited down to
   match what was actually built.
4. **Scope does not leak backwards across a passed gate.** Once a phase passes, its work is
   finished; new requirements against it become the next phase's problem or an explicit,
   tracked exception — not silent rework that makes the gate meaningless in hindsight.

**The corollary, which is why parts of this document are deliberately thin:** if we do not
work ahead, we should not *scope* far ahead either. Detailed scope written for a phase three
gates away is written without the information the intervening phases will produce, and it
ages into a confident guess that later work feels obliged to honour. Phases are scoped in
detail as their gate approaches. See the explicit application of this to
[Phase 3](#phase-3--reserved).

---

## 1. Phase sequence

| Phase | Name | State |
|---|---|---|
| **0** | Platform Foundation | ✅ **Complete** — acceptance test passed |
| **1** | CRM Core Records | Next |
| **2** | Extensibility & Data Operations | Planned |
| **3** | *Reserved* | **Not yet scoped — deliberately** |
| **4** | Automation & Workflow | Outline only |
| **5** | Reporting & Analytics | Outline only |
| **6** | Integrations & Public API | Outline only |
| **7** | Administration & Lifecycle | Outline only |
| **8** | Scale & Hardening | Outline only |

---

## 2. Release checkpoints

Five checkpoints. A checkpoint is a **release decision**, distinct from a phase gate: a phase
gate asks "is this work correct?", a checkpoint asks "who is allowed to depend on it?"

| # | Checkpoint | Reached after | Who uses it | The bar |
|---|---|---|---|---|
| **1** | **Internal Alpha** | Phase 1 | The team only. Seeded data. | The core record model holds up against real workflows we run ourselves. Data loss is acceptable; wrong tenant data is never acceptable. |
| **2** | **Private Beta** | Phase 2 | A handful of design-partner tenants, hand-held. | Real tenants with real records they would be upset to lose. Backups tested by restoring, not by existing. |
| **3** | **Public Beta** | Phase 4 | Self-service signup, capped. | A tenant can onboard without us in the room. Support load is measurable rather than continuous. |
| **4** | **GA** | Phase 6 | General availability, paid, contractual. | Uptime and data-durability commitments we would sign. Entitlements and overage billing correct to the cent, because now they produce invoices. |
| **5** | **Scale** | Phase 8 | Growth without re-architecture. | Load, cost per tenant, and noisy-neighbour behaviour all measured and bounded. The pooled-tenancy escape hatch ([§3.1](./architecture/00-phase-0-architecture-note.md)) is proven, not theoretical. |

Note what this mapping implies: **Phase 3 sits between Private Beta and Public Beta.** That
placement is the reason its scope is being held open rather than guessed at — it is the phase
most likely to be defined by what design partners tell us in Private Beta, which is
information that does not exist yet.

---

## 3. The phases

### Phase 0 — Platform Foundation ✅

**Complete.** Multi-tenancy, isolation, identity and the commercial substrate — the decisions
that are expensive to reverse, settled before any business object exists.

Delivered: pooled multi-tenant PostgreSQL with Row-Level Security (R1); flexible tenant-scoped
RBAC (R2); soft-stop entitlements with a 150% overage ceiling (R3); tenant-scoped master
tables for sources, statuses, stages and loss reasons (R4); `custom_attributes` jsonb on core
entities (R5); event-based append-only audit log, 12 months hot and monthly-partitioned
through 2027-09 (R6). 20 tables, zero R1 exceptions.

**Acceptance test — PASSED.** The verification table in
[§12 of the architecture note](./architecture/00-phase-0-architecture-note.md): full DDL
applies cleanly, the R1/RLS conformance lint returns zero violations across all 20 tables,
tenant A's context returns zero of tenant B's rows on every table, an unset tenant context
returns *nothing* rather than everything, cross-tenant writes are refused by `WITH CHECK`, and
the audit log cannot be rewritten by the application role. Executed against PostgreSQL 16.

### Phase 1 — CRM Core Records

The business objects a CRM exists to hold, built on the foundation rather than beside it.

Scope: `contacts`, `companies`, `leads`, `deals`, `activities`, `notes` — each carrying
`tenant_id` and RLS per R1, `custom_attributes` per R5, and composite `ON DELETE RESTRICT`
foreign keys into the R4 masters. The data-access layer with the `SET LOCAL` tenant-context
choke point. The R1/RLS CI lint, extended to assert zero `ENUM` types. The entitlement guard
implementing the 150%-ceiling enforcement order. Lead and deal pipelines over their respective
stage masters.

**Acceptance test (draft — to be finalised before work starts).** The cross-tenant isolation
integration test passes against every new table; the CI lint fails the build on a table added
without `tenant_id` + RLS + policy; no query in the codebase reaches the database outside the
data-access layer; a tenant at 149% of a soft limit is served and billed, and at 151% is
blocked with an upgrade path.

### Phase 2 — Extensibility & Data Operations

The deferred items from Phase 0, plus the operational machinery that only makes sense once
real records exist. Scheduled here on purpose: each of these needs information Phase 1
produces.

Scope: the per-tenant **custom-field definition registry** that types and validates R5 values
(Q21); **index strategy for `custom_attributes` and `audit_events.payload`**, chosen from
actual slow-query data rather than reflex (Q20); the **audit archive job** — create partitions
ahead, export to S3, verify, then drop (Q19); import, export and deduplication.

**Acceptance test (draft).** A tenant defines a typed custom field and invalid values are
rejected at write time; the archive job round-trips a partition to S3 and back with a verified
checksum before any drop occurs; index decisions are justified by a before/after query plan,
not by preference.

### Phase 3 — *Reserved*

**Intentionally not scoped.**

This phase is listed by name in the sequence and nothing more. It has no scope, no acceptance
test, and no deliverables in this document — by explicit instruction, and consistent with the
Phase Gate rule in [§0](#0-the-phase-gate-rule).

The reasoning is the rule applied to itself. Phase 3 begins after Private Beta, and its right
contents are whatever design-partner tenants show us during Phase 2 that we do not currently
know. Writing detailed scope for it now would produce exactly the artefact the gate rule
exists to prevent: a plan made without the information the preceding phases were supposed to
generate, carrying enough apparent authority that later work feels obliged to honour it.

**An empty slot is a more honest planning artefact than a confident guess.** This section
will be filled in when Phase 2's gate is in sight — not before.

### Phase 4 — Automation & Workflow

*Outline only; scoped in detail when Phase 2's gate is in sight.*

Assignment rules, task automation, notification and follow-up sequencing driven by the R4
semantic columns (`stage_type`, `is_terminal`) rather than hardcoded codes.

### Phase 5 — Reporting & Analytics

*Outline only.*

Pipeline, forecast and activity reporting. Read-path scaling decisions — the first place a
read replica is likely to earn its cost.

### Phase 6 — Integrations & Public API

*Outline only.*

Public API, webhooks, API-key authentication as a first-class actor type (already anticipated
in `audit_events.actor_type`), and third-party connectors. GA checkpoint sits here because
this is where external parties begin depending on our contracts.

### Phase 7 — Administration & Lifecycle

*Outline only.*

Tenant offboarding and the ordered multi-table teardown (Q15), per-tenant S3 isolation (Q11),
vanity domains (Q14), and the administrative surfaces that have been accumulating as "not
Phase 0".

### Phase 8 — Scale & Hardening

*Outline only.*

Load and cost characterisation per tenant, noisy-neighbour mitigation, and proving the
single-tenant extraction path that pooled tenancy was chosen on the assumption of.

---

## 4. What we are not building

Scope discipline is a roadmap feature. The out-of-scope list is maintained in
[`ENGINEERING_RULES.md` § Guardrails](./ENGINEERING_RULES.md) — construction ERP, TDS filing,
payroll and public-facing portals are explicitly **not** on this roadmap at any phase. A
request that requires one of them is a scope change to be decided deliberately, not a story to
be absorbed into whatever phase is currently open.
