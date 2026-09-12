# BMexa Architecture Reconciliation Report

**Status:** Analysis and planning deliverable. **No code, schema, migration or existing document was changed to produce it.**
**Date:** 2026-09-12
**Beads issue:** `Final-Verison-80b`
**Inputs reconciled:** [`docs/BMEXA_MASTER_SPEC.md`](../BMEXA_MASTER_SPEC.md) ·
[`00-phase-0-architecture-note.md`](./00-phase-0-architecture-note.md) ·
[`schema-phase-0.sql`](./schema-phase-0.sql) (byte-identical to `packages/db/drizzle/0000_phase0_foundation.sql`) ·
`packages/db/drizzle/0001_session_lookup_function.sql` · `packages/db/schema.ts` ·
`apps/api/src/middleware/*` · `apps/api/test/*` ·
[`docs/ROADMAP.md`](../ROADMAP.md) · [`docs/ENGINEERING_RULES.md`](../ENGINEERING_RULES.md)

---

## 0. How to read this document

### 0.1 The governing principle

This report was written under an explicit instruction from the project owner, quoted here in
full because every judgment below is made against it:

> "The existing repository is not automatically wrong because it differs from the earlier
> Master Specification. Likewise, the earlier Master Specification is not automatically correct
> because multiple executives agreed on it. We are reconciling ACTUAL CODEBASE + BUSINESS
> REQUIREMENTS + SECURITY REQUIREMENTS + DATA ARCHITECTURE + FINANCIAL RULES + UX REQUIREMENTS
> into one coherent engineering architecture. Do not force one to match the other blindly."

Applied literally, that means three things this report tries to do consistently:

1. Where the existing code is right, it stays — and the reason it is right is stated, not
   assumed. The spec does not override a correct implementation just by being newer.
2. Where the spec states a business requirement the code cannot satisfy, the code changes —
   and the change is scoped to the smallest thing that actually satisfies the requirement, not
   a rewrite that happens to be nearby.
3. Where **neither** document answers a question that has to be answered before the data model
   can be drawn, the question is listed as a blocker in [§M](#m-blockers) rather than resolved
   by invention. BMexa Rule 1 ("Do not invent requirements") and this repo's R12 ("a gap is
   reported, not filled from memory") say the same thing from two directions.

### 0.2 Skill routing

Per this repository's `CLAUDE.md` Skill Routing Protocol: **no listed skill category covers
cross-cutting architecture reconciliation analysis.** The table routes memory, task tracking,
UI/visual design, motion, creative layout, and testing/QA. This deliverable is none of those —
it produces no interface, no animation, no test execution and no code. The one applicable
entry is `bd` (beads) for task tracking, which is already in use (`Final-Verison-80b`). Stated
explicitly here rather than skipped silently, as the protocol requires.

### 0.3 Conventions

Carried forward from the Phase 0 note so the two documents read as one body of work:

- **DECIDED** — settled; downstream work should not relitigate it.
- **RECOMMENDED** — this report's engineering judgment, offered for the project owner to
  accept or reject. Not settled. Per BMexa §88, anything touching canonical entities,
  relationships, tenant architecture, RLS, authorization, authentication or audit requirements
  is in the "CLAUDE MUST ASK BEFORE DECIDING" column — so most of this report is
  RECOMMENDED, not DECIDED, by construction.
- **BLOCKER** — cannot be designed correctly without an answer. Collected in [§M](#m-blockers).
- **KEEP / CHANGE / RETIRE-CANDIDATE** — the disposition of an existing artifact.

**Nothing in this report is a retirement, a deletion, or an instruction to delete.** The
project owner's standing instruction is that nothing is removed yet.

### 0.4 The one-sentence conclusion

**The Phase 0 foundation is substantially correct for BMexa and should be kept — the isolation
mechanism, the session model, the audit shape and the stack all survive contact with the spec
unchanged — but it is a *generic B2B SaaS CRM* foundation sitting under a *real-estate sales
execution engine*, and the reconciliation cost is concentrated in exactly three places:
authorization needs a scope dimension it does not have, the seeded lead/deal vocabularies
describe the wrong business, and Phase 0 is not actually closed under BMexa's own §77 gate
because gate criterion 3 has no test.**

---

## A. Existing Foundation (Keep)

Everything in this section is **KEEP — unchanged**. Not "keep for now"; keep because it is
right, and because BMexa's own requirements independently arrive at it.

### A.1 Pooled multi-tenancy with Postgres RLS, fail-closed

**KEEP.** This is the single most valuable thing in the repository and BMexa §04 asks for it
almost verbatim: *"Database-level RLS is a required security layer where applicable.
Application authorization must complement—not replace—database security."*

The existing implementation satisfies that sentence precisely, and in the right order:

- Every one of the 20 tables carries `tenant_id uuid NOT NULL REFERENCES tenants(id)`, with
  RLS `ENABLE`d **and** `FORCE`d, and a `tenant_isolation` policy keyed on
  `app_current_tenant_id()` (R1, `0000_phase0_foundation.sql` §7).
- `app_current_tenant_id()` reads `current_setting('app.current_tenant_id', true)`, which
  returns NULL when unset. A NULL comparison is not TRUE, so **a query that forgets its tenant
  context returns zero rows rather than every row**. This is the property that matters and it
  is not a convention — it is arithmetic.
- `FORCE ROW LEVEL SECURITY` plus a non-owner, non-`BYPASSRLS` application role (`crm_app`)
  closes the bypass path the policies would otherwise have.

BMexa §04's list of surfaces the requirement applies to — "normal application requests, server
actions, APIs, database queries, search, files, exports, background jobs, notifications,
analytics, administrative tools" — is exactly the argument for enforcing at the engine rather
than in each surface. An application-layer `WHERE tenant_id = ?` convention has to be
re-applied correctly in eleven places; an RLS policy is applied once and cannot be forgotten by
a background job.

**One nuance carried into [§E](#e-authorization-model):** RLS as built is *necessary* and, for
BMexa, *no longer sufficient on its own*. It separates Builder A from Builder B. It does not
separate a Channel Partner from Builder A's internal pipeline, because BMexa §05 places the CP
*inside* the Builder's tenant. That is not a defect in what exists; it is a second boundary the
existing one was never asked to draw.

### A.2 `withTenantContext()` — the single choke point

**KEEP.** `packages/db/client.ts` implements the architecture note §3.3 mechanism exactly:
open a transaction, `SET LOCAL app.current_tenant_id`, run everything inside it. `SET LOCAL`
(not `SET`) is the load-bearing detail under transaction-mode connection pooling, and the file
knows why.

The UUID-validation-then-`sql.raw` construction is correct and its comment explains the real
constraint (Postgres `SET`/`SET LOCAL` are utility statements that do not accept bind
parameters). The strict `^[0-9a-f]{8}-...$` pattern makes the inlining safe. This is the kind
of code that gets "fixed" by someone who reads the `sql.raw` and not the comment — flagging it
here so a future session does not.

### A.3 The `resolve_session_context()` SECURITY DEFINER function

**KEEP.** This solves a genuine chicken-and-egg problem — you cannot set a tenant context
before you know the tenant, and the token lookup is how you learn it — using the mitigation the
architecture note §4.2 had already prescribed for the structurally identical subdomain lookup.

It is correctly narrow, and the narrowness is the security property:

- takes a token **hash** only, never a raw token and never a caller-supplied `tenant_id`;
- returns six columns, none of them `token_hash`, `ip_address` or `user_agent`;
- `SECURITY DEFINER` owned by the table owner, `REVOKE ALL ... FROM PUBLIC`, `EXECUTE` granted
  only to `crm_app`;
- no dynamic SQL, so it cannot be widened at call time.

This satisfies BMexa Rule 5 ("Do not use privileged database access casually... If privileged
access is genuinely required for a system operation, isolate it, authorize it explicitly, and
audit it") on the first two counts. The third — *audit it* — is not currently done and is
picked up in [§G.4](#g4-what-bmexa-adds-to-the-audit-requirement).

### A.4 Session-based opaque Bearer tokens

**KEEP — and the existing rejection of JWT stands.** Full evaluation against BMexa's actual
requirements is in [§F](#f-authentication-model). The short version: revocation is the
guarantee BMexa needs most (§57 user deactivation, §53 support access, §41 CP sub-agent
management, §47 "revoked permissions" during offline sync), and it is the guarantee a
stateless JWT cannot provide without becoming a session table with extra infrastructure.

### A.5 The live, uncached RBAC resolution mechanism

**KEEP the mechanism.** `require-permission.ts` walks
`user_roles → roles → role_permissions → permissions` on **every request**, with no cache and
no role-name branching. Two properties come out of that, both of which BMexa needs:

- A permission revoked in the database blocks the very next request on an
  already-authenticated session — asserted by name in `r2-dynamic-rbac.test.ts`. BMexa §47
  lists "revoked permissions" as a case the offline sync system must handle; this is the
  server half of that.
- No logic branches on a role *name*, so §03's eleven builder-side roles plus external CP and
  customer roles can all be expressed as data.

[§B.1](#b1-rbac-needs-a-scope-dimension) adds a dimension to this. It does not replace it.

### A.6 Masters-not-enums (R4) as a pattern

**KEEP the pattern; the specific vocabularies are a separate question ([§B.3](#b3-the-lead-and-deal-master-vocabularies-describe-the-wrong-business)).**

R4 is more valuable under BMexa than it was under a generic CRM, because BMexa is a vertical
product sold to multiple builders (§02) who will each have their own words for the same
things — one builder's "Site Visit Done" is another's "Visit Completed". The three arguments in
`ENGINEERING_RULES.md` R4 all hold unchanged.

The R4 corollary that matters most for BMexa is the one about **semantics living in columns,
not codes**: `lead_stages.stage_type`, `lead_statuses.is_terminal`. BMexa §09's lead states and
§20's booking lifecycle both have terminal/non-terminal semantics the product must reason
about, and both will be renamed by tenants. Branch on the semantic column, never the code.

### A.7 `custom_attributes jsonb` (R5) and its governance line

**KEEP, including the governance rule**, which BMexa independently demands. R5's line is:

> Anything the **product** reasons about gets a real column. `custom_attributes` is for what
> the **tenant** reasons about. Nothing that decides what a user may do, or what they are
> charged, may be read from `custom_attributes`.

BMexa §70 says the same thing about a different failure: *"Do not use JSON fields simply to
avoid proper relational modeling when relationships matter."* Under BMexa the temptation is
much stronger than under a generic CRM — a booking has dozens of commercial attributes and it
is genuinely tempting to blob them. The governance line forbids exactly that, and BMexa §21's
immutable financial snapshot and §24's "do not create fake financial states merely to satisfy
a checkbox" are the same instruction applied to money.

### A.8 Event-based, append-only audit (R6) — the structure

**KEEP the structure.** Detailed analysis in [§G](#g-audit-architecture). The columns
BMexa §54 asks for ("actor, action, time, target, relevant before/after values, system/human
origin, authorization context") map onto the existing table without a redesign, and
`actor_type` already includes `'support'`, which §53 will need.

### A.9 The stack

**KEEP.** Node/TypeScript, PostgreSQL, Fastify API, Next.js web, Drizzle with SQL-first
migrations, Turborepo monorepo, Expo mobile shell.

BMexa §00 is explicit that this is not to be second-guessed: *"DO NOT replace the existing
application architecture simply because a different architecture would be preferable. DO NOT
initialize a new project if an existing project already exists."* §67 asks for a modular
monolith and §10/§76 forbid microservices, Kubernetes, dedicated search and event buses
"merely because the product is described as enterprise." The current shape is already that.

One reconciliation note, not a change: the architecture note's assumption `A1` (single Next.js
deployable, no separate API service) is already superseded in fact — `apps/api` exists as a
separate Fastify service and `apps/web` as a Next.js app. The note flags this as still-open.
BMexa does not care which of the two shapes wins, so the open item survives unchanged; it is
listed in [§J](#j-repository-documentation-changes) as a documentation correction, not an
architecture decision.

### A.10 The testing methodology

**KEEP, emphatically.** The existing 27 tests in `apps/api/test/` are integration tests against
a **real PostgreSQL instance with two really-provisioned tenants**, driven over **real HTTP**
via Supertest. Nothing is mocked. `r2-dynamic-rbac.test.ts` changes a `role_permissions` row
mid-test and asserts the next request's behavior changes.

This is the methodology BMexa §91-§94 requires and it already exists. In particular §92's
concurrent-hold test and §93's idempotency test are only meaningful against a real database —
a mocked test of a concurrency guarantee tests the mock. The support helpers
(`test/support/provision.ts`, `src/test-utils/seed-session.ts`) are the reusable substrate for
every security test [§K](#k-security-gaps) asks for.

**The one thing to watch:** the `/_test/` routes in `apps/api/src/routes/test-only.ts` are
registered unconditionally in `buildApp()`. They are harmless today (they only touch
`lead_stages` and they enforce the full session/permission/feature chain), but they must never
reach a production build. A guard on `NODE_ENV` — or moving registration into the test harness
— is a small item worth doing before anything is deployed. Noted here rather than in
[§K](#k-security-gaps) because it is a deployment hygiene item, not a design gap.

---

## B. Existing Foundation That Must Change

Everything here is **modification, not replacement.** In each case the existing mechanism is
kept and extended; none of these is an argument to start over.

### B.1 RBAC needs a scope dimension

**CHANGE — additive.** This is the largest genuine gap between what exists and what BMexa
requires, and it is the subject of [§E](#e-authorization-model) in full. Stated here as the
disposition:

The existing model answers *"may this user do X?"* It cannot answer *"may this user do X
**here**?"* BMexa §08 requires the second:

> Roles and permissions must support scoped access. Potential scopes include: Global, Region,
> Project, other explicitly configured organizational scopes. Do not hardcode access using a
> giant collection of unrelated boolean fields. Access should be based on: user, role, scope,
> project/organizational assignment.

A Project Head at Project A and a Project Head at Project B hold identical permissions and must
see different data. Today they would see the same data, because `user_roles` records
`(tenant_id, user_id, role_id)` and nothing else.

**What is kept:** `permissions` as the fixed vocabulary, `roles` as the tenant-composed
bundle, `role_permissions` as the grant join, union semantics, no deny rows, `requires_2fa` as
a capability column, `is_system` protection, and the live per-request resolution.

**What changes:** the *grant* becomes scoped. A role is held **at a scope**, not globally. See
[§E.3](#e3-the-recommended-model) for the shape and [§L.3](#l3-the-single-most-dangerous-migration-in-this-report)
for why the migration window is dangerous.

### B.2 `user_roles` destroys history when a role is revoked

**CHANGE — small, and it should happen before any real user data exists.**

BMexa §08 and §57 both require it:

> §08: "Role changes must not destroy historical ownership information."
> §57: "When an employee leaves: do not destroy historical records, preserve historical actor
> identity... Never rewrite history as if the employee never existed."

The current `user_roles` table has `granted_by` and `granted_at` — a good start — but no
`revoked_at` and no `revoked_by`. Revoking a role is a `DELETE`, and the row's history goes
with it. Worse, the composite FKs are `ON DELETE CASCADE` from both `users` and `roles`, so
deleting a role deletes every record that it was ever held.

The audit log partially compensates (a `user.role_granted` event survives), but audit is a
12-month hot window that then leaves Postgres ([§G](#g-audit-architecture)), and §08's
requirement is about *current queryable state*, not forensics. "Who owned this lead in March"
must be answerable from the business tables.

**RECOMMENDED:** soft-revoke on `user_roles` (`revoked_at`, `revoked_by`, `revoked_reason`),
with the effective-permission query filtering `revoked_at IS NULL`. This is one predicate added
to `require-permission.ts` and one migration, and it is essentially free today because no
production `user_roles` rows exist.

**A related, larger question is a blocker:** BMexa §06 separates **User** (auth identity) from
**Employee** (organizational identity, "Employee history must survive role changes"). The
existing `users` table conflates them — it carries `full_name` and `status` alongside
`password_hash` and MFA state. Whether Employee becomes its own entity is [§D](#d-bmexa-domain-model)'s
problem and [M-4](#m-blockers) is the blocker.

### B.3 The lead and deal master vocabularies describe the wrong business

**CHANGE — the seeded values and, for two tables, possibly the tables themselves.**

The six R4 master tables were seeded (`provision_tenant_master_data()`, 46 rows per tenant)
for a generic B2B SaaS CRM. Compare what is seeded against what BMexa describes:

| Existing seed | BMexa's actual requirement |
|---|---|
| `lead_statuses`: new, contacted, working, nurturing, qualified, unqualified, converted | §09: New, Today, Future, Pending, Success, Dump |
| `lead_stages`: new_lead, qualification, proposal, negotiation, closed_won, closed_lost | BMexa has no pre-sales qualification pipeline distinct from lead state; §13 gives a **disposition** structure: Follow-up / Success / Dump |
| `lead_sources`: web_form, referral, phone_inbound, email_campaign, paid_ads, social, event, partner, cold_outreach, other | Plausible, but BMexa's source model is entangled with **CP attribution** (§09, §11, §39) — "which CP brought this lead" is not the same fact as "web form vs walk-in", and one field cannot carry both |
| `lead_loss_reasons`: price, timing, lost_to_competitor, no_budget, no_response, not_a_fit, duplicate, other | Plausible shape; values need review against real-estate reality (budget/location/possession-date/loan-rejection) |
| `deal_stages`: qualification → contract_sent → closed_won/lost, with `probability_pct` | **BMexa has no Deal.** It has **Booking**, whose lifecycle (§20) is Initiated → Pending Verification → Booked — an *approval workflow*, not a weighted sales pipeline. A booking does not have a 50% probability. |
| `deal_loss_reasons`: price, lost_to_competitor, missing_capability, no_decision, budget_withdrawn, timing, built_internally, other | "Chose to Build Internally" and "Missing Capability" are B2B software loss reasons. They are meaningless for an apartment sale. |

Three separate findings here, and they need different treatments.

**(a) The `lead_statuses` list is wrong, and BMexa's replacement list is itself ambiguous.**
Look at §09's six states closely: **New, Today, Future, Pending, Success, Dump.** Three of
those — Today, Future, Pending — are not states a record is *put into*; they are descriptions
of *when the next action is due* relative to now. A lead whose follow-up is scheduled for
tomorrow is "Future" today and "Today" tomorrow, with nobody touching the record. If those are
stored as status rows, the data is wrong at midnight every night and someone has to write a job
whose only purpose is to relabel rows because the clock moved.

The alternative reading is that the persisted disposition is §13's three values —
**Follow-up** (with a mandatory next-action date), **Success**, **Dump** — and that New / Today
/ Future / Pending are **derived buckets of the Action Feed** (§14), computed from
`next_action_at` against server time. That reading makes §09 and §13 consistent with each
other, makes §14's Action Feed fall out for free, and makes the Sales Rep home screen correct
without a nightly job.

It is also **a reading, not a requirement**, and §09 explicitly says *"The exact state machine
must be implemented consistently. Do not invent additional statuses unless required."* Getting
this wrong is expensive: it is the axis every lead report, every rep's home screen and every
escalation rule keys on. **[M-1](#m-blockers) — blocker.** Do not seed a replacement
vocabulary until it is answered.

**(b) `deal_stages` / `deal_loss_reasons` are RETIRE-CANDIDATES, not obviously retirements.**
See [§C.1](#c1-deal_stages-and-deal_loss_reasons). They are not merely mis-seeded; the object
they exist to serve does not exist in BMexa.

**(c) Lead source and CP attribution must not be collapsed into one column.** This is a
modelling point, not a seeding point, and it is the most likely place for a quiet bug. §11's
clash detection requires that **competing claims coexist** — multiple parties asserting they
sourced the same prospect, all preserved, resolved later by authorized leadership. A single
`source_id` foreign key on a lead cannot represent a contested fact; it represents one
resolved fact. That is why §06 lists **Lead Attribution Claim** as its own entity. `lead_sources`
stays as the channel vocabulary (walk-in, hoarding, portal, CP, referral); the *identity* of
the claiming CP and the contest between claimants lives in the attribution-claim entity. See
[§D.4](#d4-lead-attribution-clash-detection-and-assignment).

### B.4 Audit partitioning: change the *policy*, keep the *mechanism*

**CHANGE — and this is the section where "change" most needs to be precise about what changes.**
Full analysis in [§G](#g-audit-architecture). The one-line disposition: the monthly-partition
*mechanism* is cheap, already built and already tested, and should stay; the *policy* of
declaring thirteen months of partitions inside a schema migration should not, because it makes
an unbuilt operational job a production dependency with a silent fuse. That is the actual
premature thing §55/§87.9 are pointing at.

### B.5 The session/subdomain tenant-agreement check does not exist in code

**CHANGE — it is a gap, not a wrong design.**

The architecture note §3.3 step 3 and the `sessions` table comment both state the rule:

> "The session's `tenant_id` MUST be compared against the tenant resolved from the request
> subdomain, and the request rejected on mismatch. That check is what stops a valid cookie from
> tenant A being replayed against tenant B's subdomain."

`apps/api` implements no part of it. There is no subdomain resolution anywhere in the service
(`grep` for `subdomain`/`Host` in `apps/api/src/` returns only comments), and
`session-context.ts` derives the tenant purely from the token.

**This is currently safe** — with no second source of tenant identity, there is nothing to
disagree with, and the token resolves to exactly one tenant. It becomes load-bearing the moment
subdomain routing, a tenant-selector, or any client-supplied tenant hint enters the request
path. The right time to write the check is the same commit that introduces the second source,
and the right time to write the *test* is now ([§K](#k-security-gaps)).

### B.6 `require-feature.ts` is in a fail-closed state that will deny everything

**CHANGE — or consciously leave dormant, but know which.**

`require-feature.ts` 403s when the `feature_entitlements` row is absent **or** `is_enabled` is
false. That is correct fail-closed behavior, and it means that if a BMexa route is ever wrapped
in `requireFeature('...')` before the entitlement rows are seeded, it denies every request from
every tenant. Since BMexa's spec never asks for plan-based feature gating
([§H](#h-entitlementbilling-model)), the realistic failure is someone adding the middleware by
pattern-matching on the existing test routes. Decide deliberately: dormant means **no product
route uses it**.

---

## C. Existing Foundation That Should Be Retired

**Nothing in this section is retired by this report.** The project owner's instruction is that
nothing is deleted yet; this is a candidate list with reasoning, to be confirmed or rejected.
Every item here also appears in [§L](#l-migration-risk) with what breaks if it goes.

### C.1 `deal_stages` and `deal_loss_reasons`

**RETIRE-CANDIDATE — highest confidence in this section, and still not certain.**

BMexa's canonical entity list (§06) contains no Deal. The commercial object is the **Booking
Group**, and §20's lifecycle is Initiated → Pending Verification → Booked: a verification
workflow with an approval gate, not a probability-weighted pipeline. `deal_stages` carries
`probability_pct` with a CHECK tying won to 100 and lost to 0; a confirmed apartment booking
awaiting document verification is not "90% likely to close", it is either verified or it is not.

The architecture note's Q17 reasoning for splitting lead and deal masters was **correct for the
product it was written for** and is worth preserving as reasoning even if the tables go — the
general principle ("two lifecycles with different owners and different reporting do not share
a vocabulary") applies directly to BMexa's lead-vs-booking split.

**Why it is only a candidate:** §64 MVP item 19 is "Basic reporting" and §63 asks what decision
each dashboard element enables. If sales leadership needs a weighted forecast across
pre-booking opportunities, something shaped like `deal_stages` earns its place — just renamed
and re-seeded for real estate. That is a product question, not an engineering one.
**[M-8](#m-blockers).**

### C.2 The generic permission catalogue's CRM-object permissions

**RETIRE-CANDIDATE — partial.** `provision_tenant_rbac_defaults()` seeds 29 permissions. The
infrastructure half maps onto BMexa cleanly and should stay: `users.*`, `roles.*`,
`settings.*`, `audit.read`, `integrations.*`, `api.access`, `reports.*`, and — importantly —
`contacts.export` / `reports.export`, because §52 requires export to be a separately-granted,
separately-approved, audited capability and the existing catalogue already treats export as a
deliberate grant rather than an implication of read.

The object half — `contacts.*`, `deals.*`, `activities.*` — names objects BMexa does not have.
BMexa's vocabulary is leads, bookings, inventory, price lists, receipts, demands, CP
commissions, attribution claims.

**Do not rename these in place.** Two reasons. First, `r2-dynamic-rbac.test.ts` depends on
`contacts.read` and `billing.manage` existing with exactly those keys and on `read_only`
holding the first but not the second ([§L.1](#l1-changing-the-seeded-rbac-defaults-breaks-a-passing-test-suite)).
Second, the permission catalogue is seeded **per tenant** at provisioning, so a rename is a
backfill across all tenants, not a one-line edit — a cost the schema comment already
acknowledges. The right sequencing is: add BMexa permissions alongside, migrate the tests to
the new keys, then retire the old keys as a separate, deliberate step.

### C.3 The five default role names

**RETIRE-CANDIDATE.** `owner / admin / manager / member / read_only` is a SaaS-workspace role
set. BMexa §03 names eleven builder-side roles (Super Admin, Builder Admin, CEO/Promoter,
VP/Sales leadership, Sales Head, Project Head/Site Head, Sales Rep, Helpdesk, Sales Support,
Accounts, Customer Support) plus three external ones (CP firm principal, CP sub-agent,
Customer).

The *mechanism* is unaffected — these are rows, which is the whole point of R2. But note what
`is_system = true` buys and costs: system roles cannot be deleted or re-keyed, which is
correct protection and also means a wrong default is permanent-ish per tenant. Since no
production tenants exist, fixing the defaults is free **now** and a migration later. This is
the argument for answering [M-3](#m-blockers) before Phase 1 provisions anything real.

Also note that BMexa's role list is not a flat list — Sales Rep, Project Head and VP differ
primarily in *scope breadth*, not in permission verbs. That is the same observation driving
[§E](#e-authorization-model), and it means the role count is probably smaller than eleven once
scope does its job.

### C.4 Subdomain-based tenant routing — **NOT a retirement candidate, but reconsider the assumption**

Listed here only to close it. `company.yourcrm.com` (architecture note §4) is DECIDED and
unimplemented. BMexa says nothing about routing, and nothing in BMexa contradicts it. It
should stay decided.

Two BMexa-specific consequences worth recording now rather than discovering later:

- §46's **offline PWA** and §14's mobile Sales Rep experience are served from a subdomain like
  anything else, and the Bearer-token auth already works without cookies — so the note §4.3
  per-subdomain-cookie reasoning is moot for the API and applies only to `apps/web`.
- §39's **CP portal** and §36's **customer portal** are accessed by users who belong to the
  builder's tenant but are not the builder's staff. Under the current design they would arrive
  at the builder's subdomain. Whether that is acceptable branding-wise, and whether a CP working
  with three builders is expected to hold three separate logins on three subdomains, is
  [M-2](#m-blockers).

### C.5 Nothing else

Explicitly: `subscriptions`, `feature_entitlements`, `usage_counters` and `overage_line_items`
are **not** retirement candidates. See [§H](#h-entitlementbilling-model) — they are dormant
infrastructure whose MVP scope is unconfirmed, which is a different disposition from "should
disappear."

---

## D. BMexa Domain Model

Conceptual only. **No SQL, no column lists, no table names presented as decisions.** Per BMexa
§88 every entity and relationship below is in the "MUST ASK BEFORE DECIDING" column, so this is
a proposal for the project owner to ratify, amend or reject.

### D.1 The three layers

The cleanest way to hold BMexa's model is as three layers with a hard rule about what may
reference what:

```
  ┌─ PLATFORM ────────────────────────────────────────────────────────┐
  │  Tenant · User · Session · Role · Permission · Audit Event        │
  │  (exists today, Phase 0)                                          │
  └───────────────────────────────────────────────────────────────────┘
                    ▲ everything below carries tenant_id (R1)
  ┌─ ORGANIZATION ───────────────────────────────────────────────────┐
  │  Employee · Region? · Project · Tower · Floor · Inventory Unit    │
  │  CP Firm · CP Profile/Relationship                               │
  │  ── the SCOPE SPINE: what authorization is scoped *to* ──         │
  └───────────────────────────────────────────────────────────────────┘
                    ▲ scoped records anchor to a Project
  ┌─ TRANSACTION ────────────────────────────────────────────────────┐
  │  Person · Sales Lead · Assignment Log · Lead Attribution Claim    │
  │  Booking Group · Price List Version · Booking Adjustment          │
  │  Demand Letter · Payment Receipt · Receipt Allocation · CP Ledger │
  └───────────────────────────────────────────────────────────────────┘
```

The rule that makes this useful: **every entity in the Transaction layer resolves to exactly
one Project**, directly or through a short, non-optional chain. That is what makes project-scoped
authorization enforceable rather than aspirational, and it is the same structural bet R1 made
with `tenant_id`. Where an entity genuinely does not resolve to a project, that is an exception
to be named and justified, not discovered later — see [§D.6](#d6-where-the-scope-spine-does-not-reach)
and [M-6](#m-blockers).

### D.2 Identity: Tenant, User, Employee, Person

The subtlest part of the model, and the part §06/§07 are most emphatic about.

**Tenant** — one Builder. Unchanged from Phase 0. §05's Phase 1 CP is **not** a tenant; a CP
firm is an organization *inside* a builder's tenant. §66's future Paid Broker SaaS tenant is a
different product and must not be conflated — the architectural preservation §05 demands is
that nothing in the Phase 1 CP model assumes "CP" and "tenant" are the same concept, so that a
CP firm can later *also* be a tenant without a rewrite.

**User** — an authenticated identity that can log in. Exists today. BMexa requires three kinds
of user to coexist within one builder tenant: builder staff (§03), CP firm principals and
sub-agents (§39, §41), and customers (§36). They differ enormously in what they may see. The
cleanest representation is a **principal type** on the user — a small, product-defined,
security-relevant vocabulary, so per R5 §9.3's fourth row it is a real typed column, not
`custom_attributes` and not a master table.

**Employee** — the builder-side organizational record: reporting line, designation, joining and
leaving dates, which Projects/Regions they are posted to. §06: *"Employee history must survive
role changes."* §57: an employee who leaves keeps their historical actor identity while losing
access.

> **RECOMMENDED:** Employee is its own entity, not columns on User. The reason is lifecycle
> mismatch: a User is created when someone gets a login and destroyed conceptually when access
> is revoked; an Employee record must outlive that, and may exist before it (a rep hired but not
> yet provisioned). Collapsing them means "deactivate the login" and "record the departure" are
> the same operation, which §57 says they are not. The existing `users` table already leans the
> wrong way here by carrying `full_name` and `status` — that is a small, cheap correction now
> and an expensive one later.

**Person** — canonical human identity for the people the business *sells to and through*.
§06/§07 are unambiguous that Person, Sales Lead and Customer are three things, and that a
Person's identity must survive their status changing.

> **AMBIGUOUS — [M-4](#m-blockers).** §06 defines Person as "canonical human identity within
> the appropriate tenant/business boundary" without saying whether an Employee is also a
> Person, or whether a CP sub-agent is a Person, a User, both, or an entity of its own. Three
> readings are all defensible and they produce materially different schemas. The report does
> not pick one. What it can say is that the *failure mode* to avoid is the one §07 names: the
> same human existing as four unrelated rows because they were entered through four different
> screens.

**Customer** — per §06/§07, **a context, not a record.** A Person associated with a confirmed
Booking Group is presented as a Customer. There should be no `customers` table holding a
duplicate copy of the person's name and phone.

### D.3 Sales Lead, ownership and handling

**Sales Lead** — a first-class business record relating a **Person**, a **Project**, and a sales
process. Not a status column on Person (§07). A Person can hold several leads simultaneously —
different projects, or a re-enquiry after a previous lead was dumped — and historical leads
must survive.

**Lead Owner vs Lead Handler (§10)** — two distinct references on the lead, deliberately:

- **Owner** — accountable for the relationship. Changes rarely.
- **Handler** — currently working it. Changes often (reassignment, absence, escalation,
  helpdesk → field rep handover per §42/§43).

**Assignment Log (§06, §09, §10)** — every handover is a row: who, to whom, when, why, by whose
authority. §10: *"A lead can change handlers without destroying ownership history. All
meaningful handovers must be recorded."* This is a business table, not the audit log. The audit
log answers "what happened in the system"; the assignment log answers "who was responsible on
the 14th", which is a question sales operations asks constantly and which must survive the
audit log's 12-month hot window.

**Disposition (§13)** — Follow-up (requires a next action and a date) / Success / Dump. The
relationship between this and §09's six states is [M-1](#m-blockers), discussed in
[§B.3(a)](#b3-the-lead-and-deal-master-vocabularies-describe-the-wrong-business).

**Open, and material: what is a lead's uniqueness boundary?** §06 says a lead relates Person +
Project + process. So one Person enquiring about three projects is three leads. But clash
detection (§11) and duplicate detection (§09) operate on the *Person* — "is this prospect
already known to us?" — and plausibly across the whole tenant, not per project. If a rep at
Project A and a CP at Project B both claim the same phone number, is that a clash? The answer
determines whether the attribution claim attaches to the Lead or to the Person. **[M-5](#m-blockers).**

### D.4 Lead attribution, clash detection and assignment

**Lead Attribution Claim** — the entity that makes §11 possible. Multiple claims may exist
against the same prospect simultaneously; each records the claimant (CP firm, CP sub-agent,
internal rep, campaign), the basis, the time, and the resolution state. Claims are **never
overwritten by a later claim** — the whole point is that the contest is preserved and resolved
by an authorized human.

Three constraints from §11 that are architecture, not UI:

1. *"Do not expose sensitive competing claims unnecessarily."* Sales Reps must not see who else
   claimed a lead, because visibility changes behavior — a rep who can see a competing CP claim
   can act to pre-empt it.
2. *"Builder-side authorized leadership resolves attribution."* Resolution is a
   permission-gated action, not an edit.
3. *"The UI visibility rule must be enforced by authorization—not merely by hiding a badge."*

This is the clearest case in the whole spec of a requirement that **cannot be satisfied by
permissions alone and needs row- or field-level enforcement**. See [§E.5](#e5-the-third-axis-record-visibility).

**Offline-created leads (§12)** carry a **pending-synchronization** state that is genuinely
distinct from any disposition: the server-side duplicate/clash gate has not run. §12: *"Never
pretend an offline lead has passed the server-side clash gate."* That is a real state on the
lead record, not a client-side flag, and it is one more argument that §09's state list needs
disambiguating before it is seeded.

### D.5 Inventory, pricing, hold and booking

**Project → Tower → Floor → Inventory Unit** is a straightforward containment hierarchy, with
one important caveat from §24: **parking is inventory when modeled as a separate sellable
unit.** That has a direct consequence — a "parking waiver" discount is not a boolean on the
booking; it is a change in the relationship between the booking and a parking inventory record.
§24: *"Do not create fake financial states merely to satisfy a checkbox."* So Inventory Unit
needs a unit-kind concept (apartment / villa / parking / other configured sellable stock) that
the pricing and booking logic reasons about.

**Inventory Hold (§16-§19)** — conceptually, a hold is **a record with a server-computed
expiry, and a database-level guarantee that at most one is active per unit.** The requirements
are unusually specific and they are all concurrency requirements:

- 20 minutes, **server-authoritative expiry** (§18: "Do not rely on the device clock").
- §16: *"The system must guarantee that concurrent users cannot successfully hold the same
  unit. This is a database/concurrency requirement. Do NOT implement this merely as a frontend
  timer."*
- §92's test: two concurrent attempts, exactly one success, the other gets a clear failure.
- §19: holds require connectivity. Never offline.
- §17: VIEWING ≠ HOLD ≠ BOOKING INITIATED ≠ PENDING VERIFICATION ≠ BOOKED.

The design consequence, stated conceptually: the uniqueness of an active hold must be enforced
by a **database constraint or an explicit row lock inside the transaction that creates it** —
not by a read-then-write check, which is exactly the pattern that passes tests and fails under
load. §68 puts holds first in its strong-consistency list.

**Booking Group (§06)** — the transaction envelope. Multiple Persons (applicant, co-applicants)
against inventory. §21 requires an **immutable financial snapshot** at confirmation: applicable
price, charges, discounts, PLCs, applicant details. §22: a booking references a **Price List
Version**, and republishing a price list must never rewrite a confirmed booking's economics.

Two entities exist specifically to protect history:

- **Price List Version** — versioned, immutable once published. Bookings reference the version
  that applied.
- **Booking Adjustment (§25)** — post-booking changes are *adjustments*, never edits. Each
  carries actor, reason, time, what changed, approval where required, and resulting state.

**Unit transfer (§26) is the one place where the obvious model is explicitly declared wrong.**
The natural implementation — close the old booking, open a new one — would make the old booking
look like a cancellation, which would trigger CP clawback (§33). §26 says in capitals that a
unit transfer must **not** automatically be treated as a cancellation for clawback purposes, and
that this requires CFO validation before production financial logic is finalized. So Booking
Adjustment needs a **type** that the commission engine reads, and the semantics of each type are
a finance decision. **[M-9](#m-blockers)**, and already flagged by the spec itself at §87.5.

### D.6 Money: receipts, demands, allocations, CP ledger

§27/§31 draw the boundary hard: BMexa tracks the operational payment information the sales
workflow needs. It is **not** a double-entry accounting ERP (§86), and Tally or equivalent may
remain the system of record.

Four entities, and the relationships between them are the requirement:

- **Demand Letter (§30)** — an amount demanded, tied to a configured milestone.
- **Payment Receipt (§29)** — money received. **Never silently deleted or overwritten**;
  corrections use a reversal/adjustment mechanism (Rule 3, §29).
- **Receipt Allocation (§28)** — the explicit mapping of received money to a specific demand.
  Critically, a receipt may be **unallocated** on arrival: §28 requires that unapplied funds are
  a legitimate, representable state and are *not* auto-assigned to a demand. The chain is
  Receipt → Allocation → Demand, and the middle step is a deliberate human act.
- **CP Ledger (§32-§34)** — brokerage accounting for the CP relationship. Supports
  milestone-based eligibility, invoice submission when eligible (§40), Accounts review, payout,
  TDS recording (§34: Gross − TDS = Net Payable must be explicit and must not silently disagree
  with the ledger), and clawback where legitimate (§33) — **but not for unit transfers** (§26).

> **The structural rule under all four:** these are append-with-reversal, never
> update-in-place. Rule 3 is absolute and §29 repeats it. A correction produces a new record
> that references what it corrects. This is a different guarantee from the audit log and does
> not depend on it.

### D.7 CP Firm, CP Profile and sub-agents

**CP Firm** is an organization within the builder's tenant. **CP Profile / Relationship** is the
empanelment — the relationship between a CP person and/or firm and this builder, with its own
status, validity and terms.

§41 requires the hierarchy **Parent CP Firm → Principal → Sub-Agent** to be preserved, and warns
explicitly: *"Do not accidentally give a sub-agent principal-level permissions."* That is an
authorization requirement about an organizational boundary that is **not** a Project — which is
exactly why [§E](#e-authorization-model) treats "organizational boundary" as its own concept and
not a synonym for scope.

§44's walk-in edge case adds a state: an unverified, temporarily-captured CP identity that must
not block the Helpdesk and must be reconciled later. Like §12's pending-sync lead, this is a
real state, not a UI flag.

### D.8 How this maps onto the existing foundation

| BMexa entity | Existing foundation | Relationship |
|---|---|---|
| Tenant | `tenants` | **Unchanged.** One row per Builder. |
| User | `users` | Kept; needs a principal-type concept and probably loses its organizational columns to Employee. |
| Session | `sessions` | Kept; needs a support scope ([§F.4](#f4-support-access-53)). |
| Role / Permission | `roles`, `permissions`, `role_permissions` | Mechanism kept; the **grant** gains scope ([§E](#e-authorization-model)); vocabularies re-seeded. |
| Audit Event | `audit_events` | Structure kept; partition policy changed ([§G](#g-audit-architecture)). |
| Employee | — | New. Explicitly separate from User. |
| Region | — | New **if** regions are real — [M-6](#m-blockers). |
| Project / Tower / Floor / Inventory Unit | — | New. The scope spine. |
| Person | — | New. Explicitly not the same as Lead or Customer. |
| Sales Lead / Assignment Log / Attribution Claim | Vaguely gestured at by `lead_*` masters | New entities; masters re-seeded against them. |
| Booking Group / Price List Version / Booking Adjustment | — | New. |
| Demand / Receipt / Allocation / CP Ledger | — | New. |
| CP Firm / CP Profile | — | New. |
| Customer | — | **Deliberately not an entity.** A context on Person. |

Every new entity inherits R1 (`tenant_id`, RLS enabled and forced, isolation policy) and R5
(`custom_attributes` where it is an entity rather than a join), with the R5 governance
exclusions applying to the financial tables — money-relevant values stay typed, per both R5's
own rule and BMexa §70.

### D.9 Where the spec is ambiguous

Flagged rather than invented, per Rule 1. All are carried to [§M](#m-blockers): the lead state
machine (M-1), Person's boundary against Employee and CP agents (M-4), lead uniqueness and
clash scope (M-5), whether Region is a real organizational level (M-6), booking adjustment
types and their commission semantics (M-9), and whether a booking group can span multiple
inventory units (M-10).

---

## E. Authorization Model

This is the section where the existing foundation needs real design work rather than extension,
and it is the decision most expensive to reverse — every business table built after it either
carries a scope anchor or does not.

### E.1 What BMexa actually requires

Pulled from the spec rather than paraphrased:

- **§08** — access based on *user, role, scope, project/organizational assignment*; scopes
  include Global, Region, Project, "other explicitly configured organizational scopes"; no
  giant collections of unrelated booleans; role changes must not destroy history.
- **§03** — *"Different roles must see different information and actions. Never solve
  permissions by simply hiding buttons in the frontend."*
- **§11** — clash information must be hidden from Sales Reps **by authorization**, not by UI.
- **§23** — discount authority is governed by role/approval rules; *"server-side validation must
  verify the user's authority."*
- **§40** — CP invoice eligibility locks must correspond to server-side authorization;
  *"Never rely on a greyed-out button as the actual security control."*
- **§41** — a CP sub-agent must not get principal-level permissions.
- **§45** — search must be permission-aware; *"a user who cannot access a booking directly must
  not discover it through search."*
- **§52** — export is separately requested, separately approved, scoped and audited.
- **Rule 4** — never trust client-supplied ownership or permissions.

Read together, these describe **three independent axes**, and most authorization bugs in
systems like this come from collapsing them into one.

### E.2 The three axes

| Axis | Question | Example |
|---|---|---|
| **Capability** | What *kind* of action may this user perform at all? | `booking.approve`, `discount.approve`, `lead_attribution.resolve` |
| **Scope** | *Where* may they perform it? | Globally / in Region North / at Project Aurora only |
| **Record visibility** | *Which rows* within that scope may they see or act on? | Only leads they handle; only their own CP firm's leads |

The existing system implements **Capability only**. §45's search requirement is the cleanest
proof that all three must be enforced in one place: search cannot ask the UI what to hide.

### E.3 The recommended model

> **RECOMMENDED.** Per BMexa §88 this is an "ask before deciding" item; it is offered for
> ratification, not treated as settled.

**Keep unchanged:** `permissions` as the fixed vocabulary we define; `roles` as the
tenant-composed bundle of permissions; `role_permissions` as the grant join; union semantics
with no deny rows; `is_system` protection; `requires_2fa` as a capability column; live
per-request resolution with no cache.

**Change exactly one thing: the role grant becomes scoped.** A user holds a role *at a scope*,
where a scope is either Global or a reference to a node in the organizational spine
(Project, and Region if regions are real — [M-6](#m-blockers)).

Conceptually:

```
  user ──< role grant >── role ──< role_permissions >── permission
             │
             └── scope: GLOBAL | REGION:<id> | PROJECT:<id>
```

The **effective authorization question** then becomes two questions, evaluated in order:

1. **Capability gate** — does any live grant held by this user confer permission `P`?
   *This is the existing `require-permission.ts` query, essentially unchanged.* It is a cheap,
   route-level pre-filter that rejects the clearly-unauthorized before any record is loaded.
2. **Scope gate** — for the specific target record, does the user hold `P` **at a scope that
   contains that record's project**? A Global grant contains everything; a Region grant contains
   its projects; a Project grant contains itself.

Step 1 alone is not authorization — it deliberately over-approves, and any route that performs
a record-level action **must** perform step 2. That is a review rule with teeth only if it is
mechanically enforced; see [§E.6](#e6-where-enforcement-lives).

**Why scope goes on the grant rather than on the role:** because a Project Head at Aurora and a
Project Head at Riverside must be the *same role* with different assignments. Putting scope on
the role produces one role per project — the giant-collection-of-unrelated-things failure §08
forbids, wearing a different hat. It also makes §57's reassignment-on-departure a change of
grants, not a rebuild of roles.

**Why not permission keys like `leads.read.own` vs `leads.read.all`:** that encodes the
*record-visibility* axis into the *capability* vocabulary, multiplying the catalogue by the
number of breadth variants and making "what can this role do" unreadable. It also makes the
breadth un-auditable — you cannot ask "which users can see all leads at Aurora" without string
parsing. See [§E.5](#e5-the-third-axis-record-visibility).

### E.4 Organizational boundary is not the same as scope

§41's CP hierarchy (Firm → Principal → Sub-Agent) is a containment boundary that is **not** a
project. A CP principal sees their firm's leads across every project they are empanelled on; a
sub-agent sees their own. Modelling that as a "scope" would force CP firms into the project
hierarchy, where they do not belong.

> **RECOMMENDED:** treat **organizational boundary** as a separate predicate derived from the
> user's principal type and their organizational attachment — a CP user's visibility is
> constrained by their CP Firm and their position within it, in addition to any project scope.
> Two independent containments, both narrowing; neither widening the other.

This is also what preserves §05's architectural distinction between a Builder-empanelled CP and
a future Paid Broker SaaS tenant: the CP's boundary is a *within-tenant* construct today, and
promoting a CP firm to its own tenant later changes which layer the boundary lives at without
changing what it means.

### E.5 The third axis: record visibility

Some rules in BMexa are not about capability or scope at all:

- A Sales Rep sees leads they handle, not every lead at their project (§14's Action Feed is
  personal).
- A Sales Rep must **not** see competing attribution claims, even for leads they handle (§11).
- A CP sub-agent sees their own leads, not the firm's (§41).
- Customers see their own booking and nothing else (§36), and specifically **not** financial
  ledger data unless approved (§36, §87.7).

> **RECOMMENDED:** represent record-visibility breadth as an attribute **of the grant** — one
> small, product-defined vocabulary (something like *own / team / scope / all*) attached to the
> role assignment — rather than as duplicated permission keys or as per-user boolean columns.
> One field, on the grant, next to the scope it modifies. This satisfies §08's "do not hardcode
> access using a giant collection of unrelated boolean fields" while keeping the breadth
> queryable and auditable.
>
> **The clash-detection case is different and needs its own treatment.** Attribution claims are
> not "leads a rep may not see"; they are a *sensitive facet of a lead the rep is actively
> working*. Breadth does not express that. It needs a dedicated capability
> (a `lead_attribution.read_sensitive`-shaped permission) plus enforcement at the data-access
> layer so the field never leaves the server for an unauthorized caller — §11's "enforced by
> authorization, not merely by hiding a badge," taken literally.

**[M-7](#m-blockers)** — the exact breadth vocabulary and whether "team" is a real concept
(does BMexa have sales teams under a Sales Head, or only projects?) needs an answer.

### E.6 Where enforcement lives

The existing design's great strength is that tenant isolation is enforced by the *engine*, so
it cannot be forgotten. The question is whether project scope gets the same treatment.

**Option 1 — application-layer only.** Scope predicates in the data-access layer. Simple, no
new database machinery, easy to test. Fails the same way every application-layer isolation
scheme fails: a background job, an export path (§52) or a search query (§45) forgets, and the
failure is silent. Given §45 explicitly says search must not become a side door, this alone is
not enough.

**Option 2 — extend RLS with a per-request user context.** Extend the choke point so that
alongside `SET LOCAL app.current_tenant_id` it sets `SET LOCAL app.current_user_id`, and write
scope policies on business tables as an `EXISTS` against the user's live grants. The policy is
then enforced by the engine, for every caller, including background jobs.

**Option 3 — a list-valued GUC of permitted project ids.** Compute the accessible project list
once per request and set it as a session variable the policies read. Avoids the per-row
subquery. Costs: a list GUC has a practical size limit, it must be recomputed rather than
cached (R2's live-resolution guarantee forbids caching authorization state), and it introduces
a second, parallel source of truth about access that can disagree with the tables.

> **RECOMMENDED: Option 2, with Option 1's predicates retained as belt-and-braces** — which is
> exactly the posture `require-permission.ts` already takes today, running inside
> `withTenantContext()` *and* filtering on `tenant_id` explicitly.
>
> The honest cost: an `EXISTS` subquery in an RLS policy is evaluated per candidate row.
> Postgres can usually turn it into a semi-join, and the grant tables are tiny and well-indexed,
> but this is a genuine performance question and it deserves measurement, not assertion, before
> it ships. Per §75 ("Do not optimize for imaginary scale... Build sensible indexes and
> architecture first"), measure on real inventory and lead volumes before reaching for Option 3.
>
> The reason to prefer engine enforcement despite that cost is §45 and §52: search and export
> are precisely the paths where an application-layer predicate gets forgotten, and they are
> precisely the paths BMexa singles out as the ones that must not become side doors.

**One thing Option 2 changes that must be handled deliberately:** `withTenantContext(tenantId)`
becomes something closer to `withRequestContext(tenantId, userId)`, and the `userId` must come
from the resolved session and **never** from a request parameter. That is Rule 4 applied to a
new surface, and it is the exact place a future contributor could introduce a
caller-supplied-identity bug that looks like a convenience. It needs its own adversarial test
([§K](#k-security-gaps)).

### E.7 Approval authority is authorization, not workflow

§23 (discount authority), §50 (approval cards), §52 (export approval) and §40 (CP invoice
eligibility) all describe approvals. It is tempting to build these as a workflow engine with its
own notion of who may approve what.

> **RECOMMENDED: approval authority is a permission checked server-side at the moment of
> approval, at the approver's scope.** §50 says it directly: *"server-side authorization must
> verify that the approver actually has authority."* A workflow engine that stores "the approver
> for this request is user X" and then trusts that at approval time has moved the authorization
> decision to request-creation time, where it goes stale — the same staleness R2's dynamic-RBAC
> tests exist to rule out.
>
> Discount authority additionally has a **magnitude** dimension (a Sales Head may approve 2%, a
> VP 5%). That is not expressible as a boolean permission. Whether magnitude limits attach to
> the role, the grant, or a separate approval-matrix is [M-11](#m-blockers) — and §23 is
> deliberately vague ("Possible controls: ... Discount authority is governed by role/approval
> rules"), so this must not be guessed.

---

## F. Authentication Model

### F.1 The conclusion first

**KEEP the existing design. The opaque server-side session with Bearer-token transport is the
correct model for BMexa, and nothing in the spec requires changing it.** The prior rejection of
JWT stands and is, if anything, better justified under BMexa than it was under the generic CRM
it was decided for.

Three additive extensions are needed — a support-access session scope, external principal
types, and an answer to how offline queues survive session expiry. None is a redesign.

### F.2 Evaluation against each requirement

Working through the list the CTO's instruction names:

| Requirement | Current design | Verdict |
|---|---|---|
| **Revocation** | `sessions.revoked_at` + `revoked_reason`, checked live on every request by `session-context.ts`. | **Satisfied, and this is the decisive one.** §57 (deactivate a departing employee's access immediately), §41 (a CP principal removing a sub-agent), §53 (ending a support session), §47 (offline sync must handle revoked permissions), and the existing `user_roles` rule that granting a 2FA-requiring role revokes live sessions — all require cutting a session *before* its stated expiry. A stateless JWT cannot do this without a denylist, which is this table plus a second store to keep in sync. |
| **Expiry** | 24h absolute from issuance, trigger-enforced against extension. | **Satisfied for builder staff.** Two BMexa-specific questions in [§F.5](#f5-expiry-vs-the-field-and-offline). |
| **Authentication** | Password hash on `users` + `user_mfa_methods` (TOTP) + `user_recovery_codes`, with `sessions.scope = 'mfa_enrolment'` solving the newly-promoted-executive deadlock. | **Satisfied.** §03's executive roles map onto `roles.requires_2fa` without a role-name check. |
| **Tenant identification** | Derived from the session row via `resolve_session_context()`. Never from the client. | **Satisfied, and it is exactly BMexa §04 and Rule 4.** No route in `apps/api` reads a tenant from body, query, path or header — verified by reading `test-only.ts`, the only route file. That property is currently untested, which is [§K](#k-security-gaps)'s main finding. |
| **Authorization** | Live per-request permission resolution. | Mechanism satisfied; scope dimension missing ([§E](#e-authorization-model)). Not an authentication problem. |
| **Session security** | Only the token **hash** is stored (a database dump yields no usable tokens); unique index on the hash; `ip_address` and `user_agent` recorded but never returned by the lookup function. | **Satisfied.** |
| **API security** | Bearer over the `Authorization` header; fail-closed on every branch (missing header, unknown token, revoked, expired, non-`full` scope). | Satisfied at the session layer. §69's idempotency requirement is a separate concern and is **not** addressed anywhere yet — see [§F.6](#f6-what-authentication-does-not-solve-69). |
| **Future mobile / PWA (§14, §46)** | Already header-based, zero cookie dependency anywhere in `apps/api`. | **Satisfied as-is.** This was verified in the Phase 8 prep already recorded in the architecture note, and it remains true. |
| **Support access (§53)** | No mechanism. `audit_events.actor_type` anticipates `'support'`; `sessions.scope` does not. | **Gap — [§F.4](#f4-support-access-53).** |
| **Customer / CP access (§36, §39)** | No principal-type concept on `users`. | **Gap — [§F.3](#f3-external-principals-36-39-41).** |

### F.3 External principals (§36, §39, §41)

CP users and customers authenticate against the same builder tenant as staff. The session
mechanism works for them unchanged. What is missing is the **principal type** on the user, which
matters for authentication in three specific ways:

1. **MFA policy differs.** Mandatory 2FA is currently a property of the role
   (`roles.requires_2fa`, strictest-wins). A customer portal user should almost certainly not be
   forced into TOTP enrolment to view their booking; a CP firm principal who can submit
   commission invoices (§40) probably should. The mechanism supports both — it is a policy
   decision per role, not a code change. **[M-12](#m-blockers).**
2. **Session lifetime may differ.** 24 hours absolute is tuned for staff. A customer portal
   session and a CP portal session are different risk profiles. The `sessions` table can carry
   different lifetimes today — `expires_at` is a column with a default, not a hardcoded
   constant — so this is configuration, not schema.
3. **Account lifecycle differs.** §37 constrains what a customer may change about their own
   identity data; §41 makes sub-agent accounts the CP principal's to manage within limits.

None of these requires a second authentication system, and building one would be the wrong
answer — two auth paths is two places to get revocation wrong.

### F.4 Support access (§53)

> §53: "Support engineers should not automatically have unrestricted access to customer PII.
> Where support access is necessary: Builder-authorized access, limited scope, time limitation,
> audit, visible support/access mode. The exact PIN mechanism remains subject to security
> architecture validation. Never treat a PIN as a substitute for authorization."

This is the one authentication requirement the current design genuinely cannot express — and it
is an **extension of the session model, not a replacement of it**. The existing design is
unusually well-suited to carrying it, because everything §53 asks for is a property of a
session:

- *limited scope* → `sessions.scope` already exists as the mechanism, currently constrained to
  `('full','mfa_enrolment','mfa_challenge')`;
- *time limitation* → `expires_at` already exists, already absolute, already trigger-protected
  against extension — which is exactly the guarantee a time-boxed support session needs;
- *revocable* → `revoked_at` already exists;
- *audited* → `audit_events.actor_type` already includes `'support'`;
- *visible support mode* → derivable from the session's scope, so the UI banner is a
  consequence of the security state rather than a separate flag someone can forget to set.

What must be added: a support scope value, a record of **who authorized the access and for what
subject**, and an explicit expiry shorter than 24 hours. And — the part §53 is most insistent
about — a support session must be **narrower** than the supported user's own access, not equal
to it, and must never be implemented as "log in as them."

> **A useful property of the current code, worth not breaking:** `session-context.ts` rejects
> any scope that is not exactly `'full'`. So adding a `'support'` value to the CHECK constraint
> without updating the middleware produces a session that cannot do anything — fail-closed. That
> is the right failure direction and it means the schema change and the middleware change can
> ship in either order safely.

**[M-13](#m-blockers)** — §53 and §87.4 both defer the PIN mechanism to CISO validation. The
report does not design it. Note only that §53's own warning ("Never treat a PIN as a substitute
for authorization") means the PIN, whatever it becomes, is a *consent signal from the customer*,
not an authentication factor and not an authorization grant.

### F.5 Expiry vs the field, and offline

Two BMexa-specific pressures on the 24-hour absolute expiry, both worth surfacing before
Phase 3:

**(a) The field rep's day.** §14 describes a high-frequency field user optimizing for speed and
poor connectivity. Absolute expiry means a rep who logged in at 8am re-authenticates at 8am the
next day — in the field, possibly with no connectivity. The rule is defensible and was chosen
deliberately (a sliding window is not a bound); flagging it as a **UX consequence to
acknowledge**, not a design flaw to fix reflexively. §62 applies: if the session ends mid-shift,
the app must say why and what to do, not show a login screen with no explanation.

**(b) Offline sync and expired sessions.** §47 lists "authentication expiry" as one of the
conditions the sync system must handle, and §12/§46 allow offline lead capture and note-taking.
A rep can therefore accumulate a queue of unsynced operations under a session that expires
before connectivity returns.

> **This needs a decision and the spec does not make it.** The queued operations must not be
> discarded (data loss, and §09's "never hide failures"), must not be replayed under a new
> session without the user's knowledge (they are attributed actions), and must not be replayed
> twice (§47, §93 idempotency). **[M-14](#m-blockers).**
>
> What this is **not** an argument for: longer-lived or self-contained tokens. A JWT with a
> longer expiry would let the queue drain silently under stale claims — strictly worse, and
> precisely the staleness the session model exists to prevent. The likely answer is
> re-authenticate then drain the queue with idempotency keys, which the session model supports
> unchanged.

### F.6 What authentication does not solve (§69)

For completeness, because it is adjacent enough to get assigned to the wrong section: §69 and
§93 require **idempotent business operations** — *"A repeated request must not accidentally
create repeated financial/business transactions."* §47 requires the same for offline replay.

That is an API-design and data-model requirement (an idempotency key persisted per operation,
with the stored result returned on replay), not an authentication requirement. Nothing exists
for it today. Recording it here so it is not lost between sections; it belongs with the booking
and receipt work in BMexa Phases 5-6.

---

## G. Audit Architecture

### G.1 The question, stated precisely

§55 and §87.9 say:

> §55: "Do NOT force 12 months of PostgreSQL partitions into Phase 0 merely because it appeared
> in an earlier proposal. Start with a correctly indexed audit architecture. Introduce
> partitioning when actual volume and operational requirements justify it. If partitioning
> becomes necessary, implement it deliberately with tested migration/retention procedures."
>
> §87.9: "Audit partitioning — do not implement premature partitioning."

The schema has `audit_events PARTITION BY RANGE (occurred_at)` with thirteen monthly partitions
pre-created from 2026-09 through 2027-09.

The naive reconciliation is "the spec says no premature partitioning, the schema has premature
partitioning, therefore delete the partitions." That would be applying the governing principle
backwards — forcing the code to match the spec without asking what the spec is protecting
against. So: **what is the actual harm, and is it the partitions?**

### G.2 Is keeping the existing partitions harmful?

Taking the costs one at a time, honestly.

**Storage and planning cost: negligible.** Thirteen empty tables with four inherited indexes
each — a few kilobytes. Partition pruning across thirteen children is not a measurable planner
cost. Anyone arguing the partitions should go on resource grounds is wrong.

**Migration surface cost: small but real.** Every future `ALTER TABLE audit_events` — adding a
column, changing the `event_category` CHECK, adding an index — propagates across thirteen
children. Adding an index to a partitioned parent takes locks on every partition. This is a
real, recurring tax on a table whose shape will keep changing as new BMexa event types arrive.
Small, but it is not zero and it is paid repeatedly.

**Operational cost: this is the actual problem, and it is not about the partitions.** The schema
declares **no DEFAULT partition**, deliberately (the comment argues a DEFAULT partition silently
absorbs out-of-range rows and becomes unsplittable). The consequence is stated in the migration
itself, correctly and alarmingly:

> "an INSERT past the last declared bound FAILS — loudly, which is the behaviour we want, but it
> fails on the AUDIT WRITE PATH. Since emitting an audit event is part of the definition of done
> for every state-changing operation, a missing partition does not degrade logging; it takes
> down every write in the product that emits an event."

So: on 2027-10-01, **if the partition-extension job has not been built, every booking, every
receipt and every lead disposition in the product starts failing.** The job does not exist. It
is documented as `[OPEN — Phase 1 follow-up]` in the migration, `Q19` in the architecture note,
and Phase 2 scope in the roadmap.

**That is the premature thing.** Not thirteen empty tables — a **thirteen-month fuse on an
unbuilt operational dependency, lit by a schema migration**, whose expiry is far enough away
that nothing will complain until it is close. §55's phrase is *"implement it deliberately with
tested migration/retention procedures"*; the retention procedure is neither implemented nor
tested. The partitions are the visible artifact; the missing, untested job is the risk.

**Verdict: keeping the partitions is not harmful. Keeping the *policy* that produced them — a
fixed runway baked into a migration, with no job and no DEFAULT — is.**

### G.3 Recommended migration

> **RECOMMENDED — four parts. Per §88 ("changing audit requirements" is ask-before-deciding),
> this requires the project owner's sign-off, and part (c) in particular reverses a decision the
> existing schema made deliberately.**

**(a) Keep the partition-per-month mechanism. Do not drop the existing partitions.**
It is built, it is tested (`audit_events` routing to `audit_events_2026_10` is an asserted check
in the architecture note §12), it costs almost nothing, and BMexa will produce meaningful audit
volume — §54's non-negotiable emitter categories over bookings, receipts, holds, approvals,
attribution resolutions and exports across multiple builders. Un-partitioning now and
re-partitioning later is strictly more work than keeping it, and §55 does not ask for
un-partitioning; it asks for partitioning to be deliberate. Retrofitting partitioning onto a
year of production audit data is the expensive direction, and it is the direction the existing
decision correctly avoided.

**(b) Stop pre-creating a fixed runway in migrations; replace it with a rolling job.**
This is the policy change that answers §55. The job — which is the thing §55 actually asks for —
must: run on a schedule; ensure at least N months of partitions exist ahead of `now()`
(N = 3 is sufficient once the job is real and monitored; the thirteen-month runway existed
specifically to compensate for the job's absence); be idempotent (`CREATE TABLE IF NOT EXISTS`,
as the migration comment already warns); run as a privileged role, never `crm_app`; and **alarm
on partition coverage, not on job exit status**. "The job ran" and "there is a partition for
next month" are different assertions and only the second one matters.

The existing thirteen partitions then stop being a fuse and become what they should have been:
headroom while the job is written.

**(c) Reconsider the no-DEFAULT-partition decision — for BMexa specifically.**
The existing reasoning is sound in general: a DEFAULT partition hides coverage failures until it
is enormous and cannot be split without an exclusive lock. But the decision was made in a
generic CRM where the worst case of a failed audit insert is a lost log line.

Under BMexa the worst case is different in kind. §68 requires strong consistency for bookings,
receipts and holds; audit emission is part of the definition of done for those operations; so an
audit insert failing inside a booking transaction **rolls back the booking**. A customer at a
sales counter is told their booking failed because a maintenance job did not run. That is a
§61/§09 failure ("never hide failures", "show the user an actionable state") caused by a
housekeeping gap.

> The tradeoff, stated plainly so the project owner can weigh it: **no DEFAULT partition = audit
> integrity is protected by refusing to lose a row, at the cost that a coverage lapse takes down
> the sales floor. A DEFAULT partition = the sales floor keeps working, at the cost of rows
> landing in a catch-all that must be monitored and drained.**
>
> **RECOMMENDED: add a DEFAULT partition, paired with two non-optional controls** — an alarm
> that fires on the *first* row landing in it (not on a size threshold), and a documented,
> rehearsed drain procedure that moves those rows into their proper partitions once coverage is
> restored. With those controls, the DEFAULT partition is a shock absorber rather than a hiding
> place, and the "it grows until it cannot be split" failure mode the original decision feared
> requires *both* the job to fail *and* the alarm to be ignored for months.
>
> This is genuinely arguable, it reverses a documented decision, and it is the kind of change
> §88 reserves for the owner. It is presented as a recommendation with its cost named, not as a
> correction.

**(d) Keep the 12-month hot window and the archive-then-drop retention policy as decided — and
treat the archive job's absence as a scheduled item, not a risk.**
Unlike the partition-creation job, the archive job has no fuse: nothing breaks if it is late.
Its first due date is roughly twelve months after first production write. §56 adds a real
constraint the current policy does not yet satisfy: *"The correct retention/deletion policy must
be validated with Legal/Compliance."* The existing policy ("nothing is hard-deleted; history
moves to S3") is conservative and almost certainly compatible with whatever Legal says, but the
**retention floor** — how long the archive must be kept, and whether any PII in payloads must be
removable on request — is a legal answer, not an engineering one. **[M-15](#m-blockers)**, and
§87 does not currently list it.

### G.4 What BMexa adds to the audit requirement

The table's *structure* — event-based, append-only, JSONB payload, denormalised actor label,
subject as a loose type+id pair rather than an FK — is **correct for BMexa §54** and needs no
redesign. Point by point against §54's list:

| §54 requires | Existing column | Assessment |
|---|---|---|
| actor | `actor_type`, `actor_user_id`, `actor_label` | Correct. `actor_label` frozen at write time is exactly right for §57 (an employee who leaves must still be nameable in history). `actor_type` already includes `'support'` for §53 and `'api_key'`/`'integration'` for §72. |
| action | `event_type` (dotted domain event) | Correct. |
| time | `occurred_at` vs `recorded_at`, separated | Correct, and the separation matters more under BMexa than a generic CRM: §12/§47's offline-then-sync operations *are* the case where the two differ, and conflating them would make an incident timeline lie about when a rep actually did something. |
| target | `subject_type`, `subject_id`, deliberately not FKs | Correct, and load-bearing: "who cancelled this booking" must survive the booking's state change. |
| relevant before/after values | `payload jsonb` | **Satisfied, but by convention.** The event-based design deliberately does not auto-diff. §25 requires every booking amendment to record "actor, reason, time, affected information, approval where required, resulting state." Putting before/after in the payload satisfies that — *provided the emitter does it*. This is a definition-of-done discipline, not a mechanism, and it should be said out loud in the rules rather than assumed. |
| system/human origin | `actor_type` | Correct. |
| authorization context | — | **Genuine gap.** §54 says "authorization context where appropriate." Under the scoped model in [§E](#e-authorization-model), "who approved this 4% discount, under which role, at which scope" is the question an auditor will ask about §23 and §50 approvals. The payload can carry it, but a first-class place for it is worth considering while the table is still empty. **[M-16](#m-blockers).** |
| *(not in §54, but required)* tamper-resistance | Append-only via grants: `crm_app` holds INSERT and SELECT only | Correct and verified (architecture note §12: "`crm_app` cannot UPDATE/DELETE audit rows — Pass — permission denied"). §54 asks for "tamper-resistant"; grant-based append-only is the right first answer. Cryptographic chaining is a much larger commitment and §10 ("prefer simple architecture") argues against it absent a stated requirement. |

**Three BMexa-specific additions to record now:**

1. **§54 says do not blindly log everything.** The existing `event_category` CHECK
   (`general/auth/rbac/billing/data/integration/admin`) is a generic-SaaS vocabulary. BMexa's
   high-risk categories are booking, inventory/hold, pricing/discount, receipt/allocation,
   commission, attribution, export and support-access. The category axis exists precisely so
   retention and filtering can key on it — re-seeding it for BMexa is cheap now and a
   partitioned-table constraint change later.
2. **Audit is not the financial record.** Rule 3 and §29 require financial corrections to happen
   as reversals **in the business tables**. The audit log records that a reversal occurred; it is
   not where the money history lives. A design that leans on audit for financial history will
   discover in month 13 that the evidence moved to S3.
3. **The privileged-lookup path should emit events.** Rule 5 requires that genuinely-necessary
   privileged access be "isolated, authorized explicitly, and audited."
   `resolve_session_context()` is isolated and authorized; it is not audited. Auditing every
   session resolution would be a per-request write and §54 explicitly warns against logging
   everything — so the right emitter is probably the login/session-issue event rather than each
   token resolution. Worth deciding deliberately rather than by omission.

### G.5 One concrete hazard, unrelated to partitioning

`audit_events.tenant_id` is `REFERENCES tenants(id) ON DELETE CASCADE` — as is every other table
in the schema. **Deleting a tenant row therefore destroys that tenant's entire audit history**,
along with everything else. The architecture note flags tenant offboarding as an undesigned,
ordered teardown (Q15); this makes the point sharper: under §56 and §74, the audit trail of *how
a tenant was offboarded* is precisely the record most likely to be needed afterwards, and it is
currently the one the offboarding would delete. Carried to [§L](#l-migration-risk).

---

## H. Entitlement/Billing Model

**EXISTING FOUNDATION — MVP SCOPE TO BE CONFIRMED.**

### H.1 What exists

Four tables — `subscriptions`, `feature_entitlements`, `usage_counters`, `overage_line_items` —
implementing R3: soft-stop limits with overage billing to a 150% ceiling, then a hard block.
`feature_entitlements.overage_ceiling_pct NOT NULL DEFAULT 150` with a generated
`overage_ceiling_value`; `usage_counters` freezes `limit_snapshot` and `ceiling_snapshot` at
period open so a past bill is explicable from what was true at the time. `require-feature.ts`
implements step 2 of the enforcement order (the `is_enabled` gate) and is covered by
`r3-entitlements.test.ts`.

The design is careful and internally coherent. The reasoning behind the percentage-not-absolute
ceiling, and the recorded bug where the original `CHECK` rejected its own column's default, are
both worth keeping as reasoning regardless of what happens to the tables.

### H.2 What BMexa says about it

Nothing. Across 97 sections, BMexa never mentions plans, tiers, subscriptions, overage, metered
limits, seat counts, or self-serve billing. §02 describes "a vertical SaaS platform for
real-estate builders/developers and their sales ecosystem" — so it is a multi-tenant product
sold to multiple builders — but the commercial model by which builders pay for it is entirely
outside the spec. The only billing-adjacent content is §32-§34, which is **CP commission
payable to channel partners** — a completely different thing: money the builder owes brokers,
not money a builder owes us.

§07's engineering rule applies directly: *"Do not build future features early. A feature
appearing in the Phase 8-11 roadmap is NOT permission to implement it during MVP."* And §65/§86
list what must not be built. Plan billing is on neither list, because it was never discussed.

### H.3 Disposition

> **Mark as dormant infrastructure. Do not expand it. Do not delete it. Do not wire it into any
> BMexa product route until the questions below are answered.**

Three reasons not to expand: BMexa does not ask for it; §07 forbids building ahead; and every
route wrapped in `requireFeature()` before entitlement rows exist will 403 every request
([§B.6](#b6-require-featurets-is-in-a-fail-closed-state-that-will-deny-everything)).

Two reasons not to delete: the tables are inert (no product code reads them except the `/_test/`
route), so they cost nothing but four table definitions; and the commercial model genuinely is
undecided, so deleting them is a bet that a per-tenant entitlement concept will never be needed
by a multi-builder vertical SaaS — which is a strange bet to make.

### H.4 What must be decided before it is used for anything

**[M-17](#m-blockers)** in full:

1. **Does BMexa MVP need feature gating at all?** If every builder tenant gets the same
   product, the answer is no and these tables stay dormant through MVP.
2. **If yes, is the gating axis tenant or project?** A builder with twelve projects might buy
   the CP module for three of them. `feature_entitlements` is keyed per tenant; per-project
   entitlement is a different shape, and retrofitting it is a schema change plus a rewrite of
   the enforcement guard. Worth answering before anything is wired up, cheap to answer now.
3. **Do any BMexa resources have soft-stop semantics?** R3's soft-stop-and-bill model is right
   for contacts and API calls. It is questionable for inventory units and dangerous for anything
   touching bookings — "allow the action and bill the overage" is not a sentence anyone wants
   applied to a property sale. If entitlements are ever used here, the relevant limits are
   probably hard caps (`soft_stop = false`), which R3 already supports as a first-class option.
4. **Does the future Paid Broker SaaS (§66) change the answer?** A broker firm paying for its
   own tenant is the first genuinely plan-shaped customer in the spec. That is explicitly future
   scope (§66, §86) and must not pull billing into MVP — but it is the reason not to delete the
   tables.

One structural coupling to note while deciding: `permissions.requires_feature_key` already links
RBAC to entitlements, so that a tenant can be denied a permission for a feature they have not
bought. The seeding function currently leaves it NULL for all 29 permissions, so it is inert.
It is a good design and a live trap: once populated, an entitlement change silently changes what
users can do. If entitlements stay dormant, this column stays NULL.

---

## I. Roadmap Reconciliation

### I.1 Which roadmap is authoritative

> **`docs/BMEXA_MASTER_SPEC.md` §77-§86 is the authoritative phase structure going forward, by
> the project owner's explicit instruction. `docs/ROADMAP.md`'s generic nine-phase structure
> (Phase 0 Platform Foundation through Phase 8 Scale & Hardening) is superseded.**

Superseded, not deleted. See [§J](#j-repository-documentation-changes).

### I.2 What survives

Most of the Phase 0 work maps onto BMexa §77 almost exactly. §77 lists: *"existing-project
integration, authentication, tenant model, authorization, database foundation, RLS,
roles/permissions, basic audit, migrations, testing framework, environment configuration, error
handling, basic observability."*

| BMexa §77 area | Status in this repo |
|---|---|
| Existing-project integration | Done — monorepo with `apps/api`, `apps/web`, `apps/mobile`, `packages/db`. |
| Authentication | Done — sessions, MFA schema, Bearer middleware. |
| Tenant model | Done — pooled + RLS, fail-closed. |
| Authorization | **Partial** — mechanism done, scope dimension missing ([§E](#e-authorization-model)). |
| Database foundation | Done — 20 tables, constraints, triggers, composite FKs. |
| RLS | Done, and verified against a real instance. |
| Roles / permissions | Mechanism done; vocabularies wrong for BMexa ([§B.3](#b3-the-lead-and-deal-master-vocabularies-describe-the-wrong-business), [§C.2](#c2-the-generic-permission-catalogues-crm-object-permissions), [§C.3](#c3-the-five-default-role-names)). |
| Basic audit | Table done; partition policy to change ([§G](#g-audit-architecture)); no emitters exist yet. |
| Migrations | Done — SQL-first, two applied migrations, Drizzle journal. |
| Testing framework | Done — Vitest + Supertest + real Postgres, 27 integration tests. |
| Environment configuration | **Partial** — `.env.example` exists; no documented per-environment story. |
| Error handling | **Not done** — §61 demands specific, actionable errors; `apps/api` currently returns bare error codes. No product routes exist yet, so this is not yet a defect, but it is §77 scope. |
| Basic observability | **Not done** — Fastify's default logger only. §73 requires diagnosing failed bookings, holds, syncs, jobs and authorization failures. |

### I.3 What does not survive

`docs/ROADMAP.md`'s Phases 1-8 are now moot as *content*:

- **Phase 1 "CRM Core Records"** — scoped as `contacts`, `companies`, `leads`, `deals`,
  `activities`, `notes`. BMexa's Phase 1 (§78) is Organization/Users/Employees/Roles/Scope, and
  its objects are Person, Sales Lead, Project, Inventory, Booking. Only "leads" survives the
  translation, and it means something different.
- **Phases 2-8** — the shape is generic-SaaS (extensibility, automation, reporting, public API,
  administration, scale). BMexa's §79-§84 sequence is domain-driven: Project/Inventory/Pricing →
  Leads/Sales → CP Programme → Booking/Hold/Commercials → Collections/CP Payable → Post-sale.
- **The release checkpoints** (Internal Alpha → Private Beta → Public Beta → GA → Scale) assume
  self-service signup and contractual SaaS GA. BMexa says nothing about them. They are not
  wrong; they are unsourced under the new authority.

Three things in `ROADMAP.md` **do** survive and should be carried forward explicitly, because
they are process, not content:

1. **The Phase Gate rule (§0).** *"No work begins on phase N+1 until phase N has passed its
   written acceptance test."* BMexa §90 says the same thing with more required artifacts
   (requirements checklist, implementation checklist, automated tests, security tests,
   regression tests, UX verification, data-integrity verification, acceptance criteria). They
   compose; BMexa's is stricter.
2. **"A failed gate stops the next phase, it does not shrink the test."** Directly relevant to
   [§I.4](#i4-phase-0-is-not-closed-under-77).
3. **The deliberate-empty-slot discipline** (Phase 3 unscoped, R7-R11 reserved). BMexa Rule 1
   and this repo's R12 are the same instinct. This is the discipline that should govern how the
   blockers in [§M](#m-blockers) are handled — left empty until answered, not filled plausibly.

### I.4 Phase 0 is not closed under §77

`ROADMAP.md` records Phase 0 as complete with its acceptance test passed. **That was true against
the acceptance test that existed.** BMexa §77's gate is stricter, and one criterion has no test
at all:

> §77 PHASE 0 GATE: (1) Tenant A cannot access Tenant B data. (2) Unauthorized users cannot
> perform restricted actions. (3) **Server-side authorization cannot be bypassed through
> manipulated request payloads.** (4) Authentication/session behavior works as intended.
> (5) Database migrations are reproducible. (6) Critical security assumptions are tested.

| Criterion | Evidence |
|---|---|
| (1) Tenant isolation | **Passes.** `r1-tenant-isolation.test.ts`, twelve tests over real HTTP with two real tenants, plus the architecture note §12 cross-tenant sweep. |
| (2) Unauthorized users blocked | **Passes.** `r2-dynamic-rbac.test.ts` — including an unrecognized permission key denying rather than defaulting to allow. |
| (3) **No bypass via manipulated payloads** | **NO TEST EXISTS.** See [§K](#k-security-gaps). The code appears correct; nothing proves it, and nothing stops a future contributor regressing it. |
| (4) Auth/session behavior | **Passes.** `session-context.test.ts` — valid, revoked, restricted-scope, malformed header. |
| (5) Migrations reproducible | **Partial.** The DDL was executed against a real PostgreSQL 16 instance with `ON_ERROR_STOP=1` and asserted (architecture note §12), which is strong evidence. But there is no CI job that applies migrations from scratch on every build, and the R1/RLS conformance lint — described in architecture note §10 as "the single highest-leverage piece of tooling this project can build early" and "the first item of Phase 1" — **does not exist as code**. |
| (6) Critical security assumptions tested | **Partial.** The boot-time assertion that the app role is not superuser and lacks `BYPASSRLS` (architecture note §10 item 3, `ENGINEERING_RULES.md` R1 "Boot assertion") **is not implemented**. R1's own text says three independent checks exist; two of the three are unbuilt. |

> **Conclusion: Phase 0 passed the acceptance test it was given and does not yet pass BMexa
> §77's gate.** The remaining work is small and well-defined — one adversarial test suite, one
> CI lint, one boot assertion — and it is a hard prerequisite, because §77 says *"Do NOT move
> into business-critical development until automated tests demonstrate..."*
>
> Note the interaction with `ROADMAP.md` §0.4 ("scope does not leak backwards across a passed
> gate"): re-opening Phase 0 is exactly what that clause exists to prevent from happening
> *silently*. This is not silent. It is a tracked, explicit exception caused by a change in
> governing authority, which is the case §0.4 contemplates.

### I.5 Sequencing note on §82

§82 contains an instruction worth quoting, because it contradicts a naive reading of the phase
list and prevents a real problem:

> "Payment/receipt primitives required by the booking workflow must be introduced at the correct
> dependency point. Do not artificially delay required foundational entities simply because
> their broader module is later."

So Payment Receipt exists as an entity in Phase 5 if booking needs it, even though Collections
is Phase 6. The phase boundary governs *modules*, not *entities*. Worth recording because the
Phase Gate rule, read strictly, would otherwise forbid it.

---

## J. Repository Documentation Changes

**None of these are made by this report.** This is the list of follow-up documentation work,
to be done once this report is approved. Each is a separate task.

| # | File | Change | Notes |
|---|---|---|---|
| **J1** | `docs/ROADMAP.md` | Add a prominent **superseding note** at the top: the BMexa §77-§86 phase structure is authoritative; this document's nine-phase structure is superseded and retained for its history. | **Do not delete it and do not rewrite the phases.** The Phase 0 record, its acceptance test and the reasoning for the deliberately-unscoped Phase 3 are worth keeping. Explicitly carry forward the Phase Gate rule (§0) as still-binding, and note that BMexa §90 supersedes it with stricter requirements. |
| **J2** | `docs/ROADMAP.md` | Correct the Phase 0 status from "Complete" to "Complete against its own acceptance test; **not yet passing BMexa §77's gate** — criterion 3 has no test." | Per [§I.4](#i4-phase-0-is-not-closed-under-77). This is the change most likely to be contested and most important to make. |
| **J3** | `docs/ENGINEERING_RULES.md` | Add BMexa-derived rules. **Not in R7-R11.** | The document states R7-R11 are reserved and that content there must be "added here by the project owner" and not invented — including by an agent "filling in a gap that looks like an oversight." Adding BMexa rules there would violate the rule being followed. **RECOMMENDED:** a new numbered block from R13 upward, or a separate clearly-headed BMexa section. **Which, is the project owner's call — [M-18](#m-blockers).** |
| **J4** | `docs/ENGINEERING_RULES.md` | **Resolve the Guardrails conflict. This is the highest-priority documentation item and it is a genuine contradiction, not a wording problem.** | The Guardrails table lists **"Public-facing portals"** as out of scope "at every phase," with the reasoning: *"every isolation mechanism in Phase 0 assumes an authenticated user resolved to exactly one tenant."* BMexa §36 (customer portal) and §39 (CP portal) **require** them. Note the reasoning is only half right — CP and customer users *are* resolved to exactly one tenant (the builder's); what they are not is builder staff, which is a **within-tenant** boundary problem ([§E](#e-authorization-model)), not a tenancy problem. The guardrail as written would forbid two MVP features. **Only the project owner can resolve this.** |
| **J5** | `docs/ENGINEERING_RULES.md` | Clarify the **TDS** guardrail. | Guardrails exclude "TDS filing — tax deduction/withholding filing and statutory tax returns." BMexa §34 requires TDS **recording** on a CP payout (Gross − TDS = Net Payable). These are compatible — record, do not file — but a reader will hit the word "TDS" in both documents and reach opposite conclusions. One clarifying sentence. |
| **J6** | `docs/ENGINEERING_RULES.md` | Confirm the **Construction ERP** guardrail against BMexa §38. | Guardrails exclude construction ERP; BMexa §65/§86 agree. But §38 allows a future construction *feed* (photos, milestones, broadcast updates to buyers) — consumption, not project management. Worth one sentence so §38 is not later read as a breach. |
| **J7** | `docs/architecture/00-phase-0-architecture-note.md` | Add a **new revision section** recording that BMexa is now the governing product spec and pointing to this report. **Do not overwrite existing content.** | The note's established convention is to add revision subsections and keep resolved questions with their reasoning rather than deleting them. Follow it. The RESOLVED register entries (Q1, Q3, Q4, Q5, Q16) stay exactly as they are even where BMexa revisits the same ground. |
| **J8** | `docs/architecture/00-phase-0-architecture-note.md` §12 | Correct the stale table count. | The verification table says "18 tables" and "18/18"; the schema has **20** (`deal_stages` and `deal_loss_reasons` were added in the Q17 round without the count being updated). `ROADMAP.md` already says 20. Minor, but it is the acceptance-test record for a gate, so it should be accurate. |
| **J9** | `docs/architecture/00-phase-0-architecture-note.md` §11.5 | Record that assumption `A1` (single Next.js deployable, no separate API service) is **superseded by fact**, not merely open. | `apps/api` exists as a separate Fastify service and `apps/web` as a Next.js app. BMexa §67 is satisfied by either shape, so this is a documentation correction, not an architecture decision. |
| **J10** | `docs/BMEXA_MASTER_SPEC.md` §00 | Fix the status note's dangling reference. | It says *"See `docs/architecture/` for the Repository Discovery Report (delivered 2026-09-12)"*. That directory contains only `00-phase-0-architecture-note.md` and `schema-phase-0.sql`. Either the report is filed under a different name, or it was never committed. **Do not silently edit the spec** — flag it to the project owner. |
| **J11** | `docs/architecture/` | New: **`02-bmexa-domain-model.md`**, once the blockers in [§M](#m-blockers) are answered. | [§D](#d-bmexa-domain-model) is deliberately conceptual. The entity-by-entity design with relationships and constraints is the next architecture deliverable and should not be written before M-1, M-4, M-5 and M-6 are resolved. |
| **J12** | `docs/architecture/` | New: **`03-bmexa-authorization-model.md`**, once [M-6](#m-blockers), [M-7](#m-blockers) and [M-11](#m-blockers) are answered. | [§E](#e-authorization-model) gives the shape. The enforcement design — RLS policy form, the choke-point signature change, the migration ordering from [§L.3](#l3-the-single-most-dangerous-migration-in-this-report) — needs its own document, because it is the change most likely to introduce a silent authorization widening. |
| **J13** | `packages/db/README.md`, `packages/db/schema.ts` header | Update the scope comments. | Both describe Phase 1 as "contacts, companies, leads, deals, activities, notes" per the superseded roadmap. |
| **J14** | `CLAUDE.md` / `AGENTS.md` | Consider recording that BMexa is the governing product spec. | Agents currently discover the roadmap and rules but have no pointer to `BMEXA_MASTER_SPEC.md`, which now outranks both. |

---

## K. Security Gaps

### K.1 The headline gap: no adversarial payload-manipulation test

**This is BMexa §77 Phase 0 Gate criterion 3, §94's explicit test requirement, and Rule 4's
enforcement — and there is no test for it.**

> §94 TENANT SECURITY TEST: "Create Tenant A and Tenant B. Attempt to access Tenant B
> information using altered IDs, altered URLs, altered request payloads, direct API calls,
> search, files, background operations. Expected: ACCESS DENIED. This must be automated."

The existing 27 tests cover tenant isolation *between legitimate sessions* thoroughly — tenant A
reads tenant A's rows, tenant A's PATCH against tenant B's row 404s rather than silently
no-op-ing, an unauthenticated request is rejected before touching data. What they do **not**
cover is an authenticated caller **actively attempting to redirect the server's tenant
resolution**.

**The code is currently correct.** `session-context.ts` takes the tenant from the session row
and nothing else; `test-only.ts` destructures `tenantId` from `request.sessionContext` on every
route and never reads it from `body`, `query`, `params` or headers; `withTenantContext()`
rejects anything that is not a canonical UUID. The gap is not a live vulnerability — it is that
**nothing proves the property holds, and nothing will fail when someone breaks it.** That is
precisely the class of regression a Sonnet-tier implementer adding a "convenient" tenant
override would introduce, in a commit no reviewer would flag.

### K.2 What the missing tests must cover

Described for a future `test-writer` task. **Not written here.**

**(a) Client-supplied tenant identity is ignored, on every channel.** For each of: request body
field (`tenant_id`, `tenantId`), query string (`?tenant_id=`), path segment, and headers
(`X-Tenant-Id`, `X-Tenant`) — send tenant B's real UUID on a request authenticated as tenant A,
and assert the response contains only tenant A's data. Repeat for GET, POST and PATCH. The POST
case is the important one: assert that a `tenant_id` in the create body does **not** end up on
the created row (a mass-assignment test).

**(b) Cross-tenant record identifiers are rejected, not leaked.** Partly covered
(`r1-tenant-isolation.test.ts` asserts a PATCH against tenant B's id returns 404 with no partial
write) — extend to every verb and every future business object, and assert the **response shape
is identical** for "belongs to another tenant" and "does not exist." Distinguishable responses
are an existence oracle: a 403 for one and a 404 for the other confirms which UUIDs are real.

**(c) Ownership and actor identity cannot be supplied by the client.** Rule 4 covers
"client-supplied ownership" as well as tenant. Assert that `owner_user_id`, `created_by`,
`assigned_to` and equivalents in a request body are ignored in favour of the session's user.
Today there are no such fields; the test should be written alongside the first record type that
has one, and the pattern established now.

**(d) Client-supplied permissions and scope are ignored.** Assert a request carrying
`permissions: [...]`, `role: "admin"`, or (once [§E](#e-authorization-model) lands)
`scope`/`project_id` overrides in body or headers changes nothing about what the caller may do.
**The scope case is the one to write first once scoped grants exist**, because a project-scoped
model introduces a *second* client-manipulable identifier and it will be far less obviously
wrong than a tenant override.

**(e) Token replay across boundaries.** Partly covered by `session-context.test.ts`. Extend
once subdomain routing exists ([§B.5](#b5-the-sessionsubdomain-tenant-agreement-check-does-not-exist-in-code)):
a valid tenant-A token presented against tenant B's host must be rejected.

**(f) A structural test, not a request test.** A repository-level assertion that **no route
handler reads a tenant identifier from `request.body`, `request.query`, `request.params` or
`request.headers`**, and that `withTenantContext()` (and its successor) is never called with a
value derived from client input. Implementable as a source scan or an ESLint rule. This is the
one that keeps holding as the codebase grows, because per-route tests only cover the routes
someone remembered to test. **RECOMMENDED as the highest-value item in this section.**

### K.3 Where these fit

`apps/api/test/` alongside the existing four suites, in a new file — `tenant-spoofing.test.ts`
or `security-adversarial.test.ts`. The substrate already exists and needs no new machinery:
`test/support/provision.ts` (`provisionTenant`, `createUser`, `assignRole`, `deleteTenant`),
`src/test-utils/seed-session.ts`, `test/support/app.ts`, and Supertest against a real Fastify
instance.

The suite can run against the existing `/_test/tenant-data/lead-stages` routes today — they are
representative, since they take a tenant-scoped id in the path, a body on create, and enforce
the same session chain a product route will. **Do not add a test-only route that deliberately
accepts a client-supplied tenant id "so it can be tested."** That creates the exact
vulnerability the suite exists to rule out, guarded only by the route prefix.

**Note the sequencing dependency:** if `lead_stages` is later retired ([§B.3](#b3-the-lead-and-deal-master-vocabularies-describe-the-wrong-business)),
these routes and every suite that uses them move with it. Writing the adversarial tests first
is still correct — they are cheap to re-point and they protect the property during exactly the
migration window when it is most at risk.

### K.4 Other gaps in the same bucket

| Gap | Requirement | Status |
|---|---|---|
| **R1/RLS CI lint** | Architecture note §10 item 1, `ENGINEERING_RULES.md` R1, BMexa §77 gate (5)/(6). Described as "the single highest-leverage piece of tooling this project can build early" and "the first item of Phase 1." | **Does not exist as code.** ~50 lines against `pg_catalog`. Should also assert zero `ENUM` types (R4) and — once [§E](#e-authorization-model) lands — that every business table carries its scope anchor. |
| **Boot-time role assertion** | Architecture note §3.5 and §10 item 3; `ENGINEERING_RULES.md` R1 ("Boot assertion"). | **Does not exist.** R1's text claims three independent checks against the silent-inert-RLS failure; only `FORCE ROW LEVEL SECURITY` is actually in place. If the app is ever misconfigured to connect as the table owner or a superuser, **every policy in the schema becomes inert with no error** — the failure mode R1 itself names as "the single most likely way the whole design fails." |
| **Migration reproducibility in CI** | BMexa §77 gate (5). | The DDL was verified manually against real PostgreSQL 16. No CI job re-applies migrations from scratch per build. |
| **`/_test/` routes in production builds** | Deployment hygiene. | `buildApp()` registers them unconditionally. Guard on environment, or move registration into the test harness. |
| **Concurrency and idempotency tests** | §92, §93. | Nothing exists to test yet (no holds, no bookings). Listed so they are scheduled with the features rather than after them — §92's two-concurrent-holds test in particular must be written *with* the hold implementation, because it is the test that decides whether the implementation is correct. |
| **Search authorization** | §45 — search must never become a side door. | No search exists. The requirement is architectural ([§E.6](#e6-where-enforcement-lives)) and is the strongest argument for engine-level scope enforcement. |
| **Export control** | §52 — request, approve, scope, log, audit. | No export exists. The permission catalogue already separates `*.export` from `*.read`, which is the right foundation. |

---

## L. Migration Risk

Specific and concrete. Generic risks are omitted.

### L.1 Changing the seeded RBAC defaults breaks a passing test suite

`r2-dynamic-rbac.test.ts` depends on `provision_tenant_rbac_defaults()` seeding:

- a role keyed exactly `read_only`, and a role keyed exactly `owner` (used by
  `r1-tenant-isolation.test.ts`);
- permissions keyed exactly `contacts.read` and `billing.manage`;
- `read_only` holding `contacts.read` and **not** holding `billing.manage`.

The test's own comment says this is deliberate — it uses real seed data rather than a fixture
role, which is the right call and creates the coupling. **Renaming or removing any of those four
keys breaks the suite immediately.**

Mitigation: add BMexa roles and permissions **alongside** the existing ones, migrate the test to
the new keys in a separate commit, then retire the old keys. Three commits, no window where the
gate is red.

### L.2 Retiring `lead_stages` breaks two more suites and the only route file

`apps/api/src/routes/test-only.ts` implements all its R1 routes against `lead_stages`. Those
routes are the only HTTP surface in the service besides `/health`, and they are used by:

- `r1-tenant-isolation.test.ts` (all twelve tests),
- `session-context.test.ts` (all four tests, which hit `/_test/tenant-data/lead-stages` purely
  as a representative authenticated route).

So `lead_stages` is currently load-bearing for **sixteen of the twenty-seven tests**, in a way
that has nothing to do with leads. **Re-point the test routes at a surviving tenant-scoped table
before touching `lead_stages`.** If the adversarial suite from [§K](#k-security-gaps) is written
first, it inherits the same dependency and must move with it.

### L.3 The single most dangerous migration in this report

**Adding scope to `user_roles`.**

The current primary key is `(user_id, role_id)`. That means **a user cannot hold the same role
twice at two different scopes** — which is precisely what a Project Head at two projects needs.
Adding scope therefore requires changing the primary key, which means dropping and recreating a
constraint that two composite foreign keys depend on.

That is mechanically routine. The dangerous part is different and is easy to miss:

> **During the window where scoped grants exist in the table but `require-permission.ts` has not
> been updated, the middleware silently over-approves.** Its query is
> `SELECT DISTINCT p.key FROM user_roles ur JOIN roles ... WHERE ur.user_id = $1` — it asks only
> *"does this user hold this permission anywhere?"* A user granted `booking.approve` at one
> project would pass that check for **every** project. The tests would still pass, because no
> test asserts a negative about scope. Nothing would look wrong.

This is a silent authorization widening introduced by a schema migration, and it is exactly the
class of change BMexa Rule 2 ("Do not weaken security") and §88 ("MUST ASK BEFORE DECIDING:
changing authorization rules") exist to catch.

**RECOMMENDED ordering, as three separate, individually-safe steps:**

1. Add the scope column **nullable, defaulting to Global**, and change the primary key. Every
   existing grant becomes an explicit Global grant — behaviour is unchanged, because that is
   what it already was.
2. Update `require-permission.ts` and add the record-level scope check **before any grant is
   narrowed**, with tests asserting the negative case (a project-scoped grant does **not**
   authorize an action at another project). The scope check must be live before there is
   anything for it to enforce.
3. Only then start issuing narrower grants.

Never steps 1 and 3 without 2.

### L.4 `ON DELETE CASCADE` from `tenants` destroys audit history

Every table references `tenants(id) ON DELETE CASCADE`, including `audit_events`. A single
`DELETE FROM tenants WHERE id = ...` removes the tenant's entire history — users, bookings,
receipts, **and the audit trail of how any of it happened**.

BMexa §56 explicitly requires distinguishing business deletion, archival, PII removal, legal
retention, user deactivation and tenant closure, validated with Legal/Compliance. §74 requires a
proven backup and recovery strategy. The cascade as it stands makes tenant offboarding a
one-statement irreversible operation with no archival step.

The architecture note already flags tenant offboarding as an undesigned ordered teardown (Q15).
This sharpens it: **the teardown must export before it deletes, and the audit trail is the thing
most likely to be needed afterwards and the thing most certain to be destroyed.**

### L.5 Retrofitting a scope anchor onto business tables is expensive; adding it now is free

Every scoped business entity needs to resolve to a Project ([§D.1](#d1-the-three-layers)). Adding
a `NOT NULL` anchor column to a table that already holds millions of leads means a backfill, a
rewrite, and a period where the constraint cannot be enforced.

**Right now, zero business tables exist.** Deciding the scope-anchor convention before BMexa
Phase 2 (§79, Project/Inventory/Pricing) makes it free forever. This is the same asymmetry that
justified R5's `custom_attributes` on day one, and it is the single strongest argument for
resolving [M-6](#m-blockers) early.

### L.6 Audit partition changes

- **Dropping a pre-created partition that contains rows destroys those rows.** Today they are
  all empty, so acting now is free. After first production write it is not.
- **Adding a DEFAULT partition** ([§G.3(c)](#g3-recommended-migration)) takes a lock on the
  parent and requires a scan to prove no existing rows would have belonged to it. Cheap on an
  empty table, expensive on a large one.
- **Changing the `event_category` CHECK** to BMexa's vocabulary propagates across all thirteen
  partitions and must be done before rows carry the old values, or the migration needs a
  translation step.

All three argue the same way: **the audit changes in [§G](#g-audit-architecture) are cheapest
right now and get monotonically more expensive.**

### L.7 Smaller, specific items

- **Adding `'support'` to the `sessions.scope` CHECK is safe in any order.**
  `session-context.ts` rejects any scope that is not exactly `'full'`, so a support session is
  inert until the middleware is taught about it. Fail-closed, as designed.
- **Changing `provision_tenant_master_data()` or `provision_tenant_rbac_defaults()` does not
  migrate existing tenants.** Both are `CREATE OR REPLACE` with `ON CONFLICT DO NOTHING`, so they
  seed *new* tenants only. Every seed change needs a companion backfill for tenants already
  provisioned — including the ones the test suites create and tear down.
- **`packages/db/schema.ts` types only `tenants` and `users`.** Adding tables does not break it;
  it also means new tables get no compile-time type safety until deliberately added. The file's
  own header explains the drift-avoidance reasoning, which stays valid.
- **`users.email` is unique per tenant (functional index on `lower(email)`).** A CP sub-agent
  working with three builders will hold three separate user records with the same email in three
  tenants. That is a consequence of the DECIDED single-tenant-user model (Q16) and is probably
  acceptable, but it should be a conscious product decision for the CP portal, not a discovery.
  **[M-2](#m-blockers).**
- **Removing the `deals.*` permissions requires editing the seeding function's permission array**
  — a `text[]` literal, so a mechanical edit, but the `role_permissions` grants are computed from
  `p.resource IN (...)` lists in four places that must stay consistent with it.

---

## M. Blockers

**These are what the project owner needs to act on.** Each one blocks a specific piece of design
that cannot be done correctly by guessing. Per BMexa Rule 1 and this repository's R12, the
report leaves them empty rather than filling them plausibly.

Marked ⚑ where BMexa §87 already flags the item as a Known Validation Item.

### Highest priority — block the domain model

**M-1. What is the lead state machine, exactly?**
§09 lists New / Today / Future / Pending / Success / Dump. §13 gives the disposition structure
Follow-up / Success / Dump. These are not the same list. As analysed in
[§B.3(a)](#b3-the-lead-and-deal-master-vocabularies-describe-the-wrong-business), *Today* and
*Future* look like **time-derived buckets of the Action Feed** computed from a next-action date,
not persisted states — if they are persisted, every record is wrong at midnight. *Pending* is
ambiguous between "awaiting a customer response" and §12's "awaiting server-side clash/duplicate
verification after offline capture," which are unrelated conditions.
*Needed:* the exact persisted states, the legal transitions between them, which are terminal,
and confirmation of whether Today/Future/Pending are stored or derived.
*Blocks:* the lead entity, the disposition workflow, the Action Feed (§14), follow-up
escalation (§58), and re-seeding `lead_statuses`/`lead_stages`.

**M-2. Do CP and Customer users log in as users of the Builder's tenant?**
§05 places the Phase 1 CP inside the Builder's ecosystem with restricted access; §36/§39 require
customer and CP portals. The existing model is one user = exactly one tenant (DECIDED, Q16), so
a CP working with three builders holds three logins. **And `ENGINEERING_RULES.md` Guardrails
currently forbid public-facing portals at every phase** ([§J4](#j-repository-documentation-changes)).
*Needed:* confirmation that external principals are users within the builder's tenant;
acceptance (or not) of one-login-per-builder for CPs; and an amendment to the Guardrails entry.
*Blocks:* the authentication model for external users, the CP portal, the customer portal, and
whether [§E.4](#e4-organizational-boundary-is-not-the-same-as-scope)'s organizational-boundary
axis is needed in MVP.

**M-3. What is the BMexa default role set?**
§03 names eleven builder-side and three external roles. The schema seeds five generic ones. Roles
are seeded per tenant and system roles cannot be deleted or re-keyed, so a wrong default is a
migration later and free now. Note that several §03 roles differ only in scope breadth, so the
real role count may be materially smaller once [§E](#e-authorization-model) lands.
*Needed:* the role list, which roles carry `requires_2fa`, and the permission grants per role.
*Blocks:* re-seeding `provision_tenant_rbac_defaults()`, and the shape of the permission
catalogue.

**M-4. What exactly is a Person, and what is an Employee?**
§06 defines Person as "canonical human identity within the appropriate tenant/business boundary"
without saying whether builder employees are Persons, whether CP sub-agents are Persons, or
whether an Employee is a User with extra columns or its own entity. Three defensible readings,
three materially different schemas.
*Needed:* the boundary between Person, Employee and User, and which humans are represented by
which.
*Blocks:* essentially the whole Transaction layer, because everything hangs off Person.

**M-5. What is a lead's uniqueness boundary, and at what level does clash detection operate?**
§06 says a Sales Lead relates Person + Project + process, so one person enquiring about three
projects is three leads. But §09's duplicate detection and §11's clash detection operate on the
prospect — plausibly tenant-wide. If a rep at Project A and a CP at Project B both claim the same
phone number, is that a clash?
*Needed:* the duplicate-detection key (phone? phone + project? person identity?) and the scope
of a clash.
*Blocks:* whether Lead Attribution Claim attaches to the Lead or the Person, the clash engine,
and §12's offline pending-sync gate.

**M-6. Is Region a real organizational level, and is the scope hierarchy exactly Global → Region → Project?**
§08 says *"Potential scopes include: Global, Region, Project, other explicitly configured
organizational scopes."* "Potential" and "other explicitly configured" are doing a lot of work.
Does this builder have regions? Is a project in exactly one region? Can scopes nest arbitrarily,
or is the hierarchy fixed at three levels? Are there scopes that are not geographic — a business
vertical, a sales channel?
*Needed:* the exact scope hierarchy and whether it is fixed or configurable.
*Blocks:* [§E](#e-authorization-model) in full, the scope-anchor convention on every business
table ([§L.5](#l5-retrofitting-a-scope-anchor-onto-business-tables-is-expensive-adding-it-now-is-free)),
and therefore all of BMexa Phase 2.

### High priority — block the authorization model

**M-7. What is the record-visibility vocabulary, and is "team" a real concept?**
[§E.5](#e5-the-third-axis-record-visibility) recommends breadth as an attribute of the grant
(own / team / scope / all). Does BMexa have sales *teams* under a Sales Head, distinct from
projects? Does a Sales Head see their team's leads across projects, or their project's leads
across teams?
*Needed:* the breadth values and confirmation of whether a team construct exists.
*Blocks:* the grant shape, and the Action Feed's "my work" definition.

**M-8. Does BMexa need a weighted pre-booking pipeline?**
Determines whether `deal_stages` / `deal_loss_reasons` are retired or re-seeded for real estate
([§C.1](#c1-deal_stages-and-deal_loss_reasons)). §63 asks what decision each dashboard element
enables; this is that question applied to forecasting.
*Blocks:* the retirement decision, and any pipeline reporting in §64 item 19.

**M-11. How is discount authority expressed?**
§23 says discount authority is governed by role/approval rules and that server-side validation
must verify the user's authority. Real-estate discount authority is almost always *magnitude*
based — Sales Head 2%, VP 5%, CEO unlimited — which a boolean permission cannot express.
*Needed:* whether authority limits are per role, per grant, per project, or an explicit approval
matrix; and whether limits are percentage, absolute, or per charge head.
*Blocks:* the discount approval workflow (§23, §50) and part of the booking financial model.

**M-12. What is the MFA policy for external users?**
Mandatory 2FA is a property of the role (strictest-wins). Should a customer portal user be forced
into TOTP enrolment? A CP principal who can submit commission invoices (§40)? A CP sub-agent?
*Needed:* per-role 2FA policy for external principals.
*Blocks:* external user onboarding; not blocking for staff.

### Medium priority — block specific features

**M-9. ⚑ What are the booking adjustment types and their commission consequences?**
§26 states in capitals that a unit transfer must **not** automatically be treated as a
cancellation for CP clawback, and calls this a CFO validation requirement before production
financial logic is finalized. §87.5 already flags it.
*Needed:* the adjustment taxonomy (cancellation, transfer, upgrade, downgrade, amendment) and
each type's effect on the CP ledger, the customer ledger and inventory state.
*Blocks:* Booking Adjustment, the CP commission engine, and clawback (§33).

**M-10. Can a Booking Group span multiple inventory units?**
§06 describes it as "a transaction envelope connecting applicants/co-applicants with inventory."
§24 makes parking a separate sellable inventory unit. So an apartment + two parking slots is
either one booking group with three units, or a primary booking with linked parking bookings.
The answer determines how §21's financial snapshot and §26's transfer semantics work.
*Blocks:* the booking model and the parking-waiver representation (§24).

**M-13. ⚑ What is the support access mechanism?**
§53 requires builder-authorized, scope-limited, time-limited, audited, visibly-flagged support
access, and defers the PIN mechanism to CISO validation (§87.4). §53's own warning stands: a PIN
is not a substitute for authorization — at most a customer consent signal.
*Needed:* CISO sign-off on the mechanism.
*Blocks:* the support session scope ([§F.4](#f4-support-access-53)). Not blocking for MVP staff
features.

**M-14. What happens to a queued offline operation when the session expires before it syncs?**
§47 lists authentication expiry among the conditions offline sync must handle; §12 and §46 permit
offline capture. The queue must not be discarded, must not replay silently under a new session,
and must not replay twice (§93).
*Needed:* the intended behaviour.
*Blocks:* offline sync design (BMexa Phase 3+). **Explicitly not a reason to change the
authentication model** — see [§F.5](#f5-expiry-vs-the-field-and-offline).

**M-15. What is the legal retention floor for audit and business records?**
§56 requires the retention/deletion policy to be validated with Legal/Compliance and to
distinguish business deletion, archival, PII removal, legal retention, user deactivation, tenant
closure, test data and system maintenance. The current policy (12 months hot, then S3 forever) is
conservative but unvalidated, and §87 does not currently list this.
*Needed:* the retention floor, whether PII in audit payloads must be removable on request, and
what tenant closure means legally.
*Blocks:* the archive job's retention configuration and the tenant offboarding teardown
([§L.4](#l4-on-delete-cascade-from-tenants-destroys-audit-history)).

**M-16. Should the audit log carry authorization context as a first-class field?**
§54 asks for "authorization context where appropriate." Under scoped authorization, "who
approved this, under which role, at which scope" is the question an auditor will ask about §23
and §50 approvals. The payload can carry it; a dedicated place is cheaper to decide while the
table is empty ([§L.6](#l6-audit-partition-changes)).

**M-17. Does BMexa MVP need feature entitlements at all?**
Four questions in [§H.4](#h4-what-must-be-decided-before-it-is-used-for-anything): is gating
needed; tenant-level or project-level; do any resources have soft-stop semantics; does the
future Broker SaaS change the answer. Until answered, the tables stay dormant and **no product
route uses `requireFeature()`**.

**M-18. Where do BMexa engineering rules go?**
`ENGINEERING_RULES.md` reserves R7-R11 and explicitly forbids anyone — person or agent — from
inventing content there. New BMexa rules therefore need either R13+ or a separate section. The
project owner's call, and it needs making before [§J3](#j-repository-documentation-changes) can
be done.

### Governance decisions this report cannot make

**M-19. Approve or amend the audit recommendation in [§G.3](#g3-recommended-migration).**
Specifically part (c) — adding a DEFAULT partition — which **reverses a deliberate decision**
recorded in the schema, in exchange for not taking down the sales floor when a maintenance job
lapses. §88 puts "changing audit requirements" in the ask-before-deciding column. The tradeoff
is stated in full at [§G.3](#g3-recommended-migration); this is a judgment call about which
failure mode is worse for this business.

**M-20. Approve the Phase 0 re-opening in [§I.4](#i4-phase-0-is-not-closed-under-77).**
Phase 0 is recorded as complete and passed its own acceptance test. Under BMexa §77's stricter
gate it does not pass criterion 3 (no adversarial payload test), and criteria 5 and 6 are only
partial (no CI lint, no boot assertion). The remaining work is small and well-defined. But
`ROADMAP.md` §0.4 says scope does not leak backwards across a passed gate, so re-opening must be
an explicit, owner-approved exception rather than something this report does on its own
authority.

---

## N. What happens next

Not a section of the required structure — a handoff note, so the sequencing is not re-derived.

1. **Project owner reviews this report** and answers, at minimum, M-1, M-4, M-5 and M-6. Those
   four block the domain model, and the domain model blocks everything else.
2. **The security gap in [§K](#k-security-gaps) can be closed in parallel and should be** — it
   depends on none of the blockers, it closes BMexa §77 gate criterion 3, and it is a
   well-specified `test-writer` task against an existing test substrate.
3. **The R1/RLS CI lint and the boot assertion** ([§K.4](#k4-other-gaps-in-the-same-bucket)) are
   likewise unblocked, small, and named in `ENGINEERING_RULES.md` R1 as controls that are
   supposed to already exist.
4. **The audit migration** ([§G.3](#g3-recommended-migration)) is unblocked once M-19 is
   answered, and gets more expensive every month it waits.
5. **The domain model and authorization documents** (`02-`, `03-` in
   [§J](#j-repository-documentation-changes)) come after the blockers, not before.
6. **No schema work on BMexa business objects** until [§E](#e-authorization-model)'s scope anchor
   is decided (M-6), because every table created before that decision either carries the anchor
   or has to be migrated to carry it ([§L.5](#l5-retrofitting-a-scope-anchor-onto-business-tables-is-expensive-adding-it-now-is-free)).

Per BMexa §97: *"When in doubt: STOP AND ASK. Do not make an irreversible business, financial,
security, or data-model decision merely to keep coding."* This report stops here.
