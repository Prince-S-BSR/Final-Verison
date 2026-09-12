# Phase 0 — Platform Foundation Architecture Note

**Status:** Draft / foundation. Not a final spec.
**Date:** 2026-09-03
**Beads issue:** `Final-Verison-c86`
**Companion artifact:** [`schema-phase-0.sql`](./schema-phase-0.sql)

---

## 0. How to read this document

This is the first piece of product design work in the repo. It exists to lock down the
handful of decisions that are **expensive to reverse later** — tenancy model, tenant
isolation mechanism, identity/session model, the shape of RBAC, the shape of
entitlements, and the shape of the audit log — so that downstream implementation work
does not have to re-derive them.

Two conventions are used throughout:

- **DECIDED** — a constraint handed down by the project owner, or a decision made here
  that downstream work should treat as settled.
- **ASSUMPTION** — a reasonable default chosen to make the note concrete. It is *not*
  settled. Each one is repeated in [§11 Open questions](#11-open-questions--resolutions-register)
  so they can be confirmed or overturned cheaply.
- **RESOLVED** — an item that was an open question or an assumption in the first pass of
  this note and has since been answered by the project owner. The answer is integrated into
  the relevant section, and [§11](#11-open-questions--resolutions-register) records how it
  was resolved rather than silently deleting the question.

The rules referenced (R1–R6) were given directly by the project owner: R1, R2, R3 and R6 in
the original Phase 0 brief, R4 and R5 in a follow-up round that also answered five open
questions. There is no pre-existing engineering-rules document in this repo; this note is
the first written record of them.

---

## 1. The rules this phase must satisfy

| Rule | Statement | Where it lands |
|---|---|---|
| **R1** | Every single table carries a `tenant_id` column. Non-negotiable. | [§3](#3-tenancy), [§10](#10-r1-enforcement), schema file |
| **R2** | RBAC uses *flexible* default roles — defaults ship, tenants can define their own. | [§5](#5-rbac-r2) |
| **R3** | Entitlements are *soft-stop* — overage billing to a **150% ceiling**, then a hard block. | [§7](#7-entitlements--soft-stop-limits-r3) |
| **R4** | Sources, stages, statuses and reasons are **rows in master tables**, never database ENUMs. | [§9.1](#91-r4--master-tables-not-enums) |
| **R5** | Core entities carry **`custom_attributes jsonb`** from day one. | [§9.2](#92-r5--custom-fields-from-day-one) |
| **R6** | Audit logs are *event-based*, 12-month hot, then archived to S3 and dropped. | [§8](#8-audit-logs-r6) |

R4 and R5 were supplied by the project owner after the first pass of this note and are now
integrated above rather than carried as a gap. The same round of confirmations resolved five
of the open questions from the first pass — see
[§11](#11-open-questions--resolutions-register), where each is recorded as **resolved** with
the answer, not merely closed.

---

## 2. Stack

**DECIDED (by the owner):** Node.js / TypeScript, Next.js, PostgreSQL, AWS.

Everything below that is *shape* rather than *stack name* is an assumption, flagged as such.

### 2.1 Application shape

**ASSUMPTION — Next.js App Router, single deployable.** One Next.js application using the
App Router, serving both the rendered UI (React Server Components) and the HTTP API. No
separate standalone API service in Phase 0.

Rationale: a separate service layer buys independent scaling and a hard language boundary,
but costs a second deployment, a second auth path, and cross-service tracing — all of which
are real work with no Phase 0 payoff. A single deployable is cheaper to run now and is not
a one-way door: extracting a service later is mechanical if the constraint below holds.

**DECIDED — the "no ORM call from a component" constraint.** Even inside a single
deployable, all database access goes through a **server-side data-access layer** (a
`src/server/db/` module tree), never directly from a route handler, a Server Component, or
a Server Action. This is the seam that makes a future service extraction cheap, and — much
more importantly — it is the single choke point where the per-request tenant context gets
set (see [§3.3](#33-how-rls-is-actually-enforced-per-request)). Tenant isolation that
depends on every caller remembering to do the right thing is not isolation. One choke point
that cannot be bypassed is.

Layering:

```
  Browser
    │
    ▼
  Next.js middleware (edge)  ── resolves subdomain → tenant_id, attaches to request
    │
    ▼
  Route handler / Server Component / Server Action
    │                                (never touches the pool directly)
    ▼
  Data-access layer  ── opens txn, SET LOCAL app.current_tenant_id, runs query
    │
    ▼
  PostgreSQL (RLS enforced)
```

### 2.2 Persistence

**ASSUMPTION — Amazon RDS for PostgreSQL 16+**, single primary, Multi-AZ, with a read
replica added only when read load justifies it (not in Phase 0). Aurora PostgreSQL is the
obvious alternative and is worth revisiting before GA; the reason to *not* start there is
cost and the fact that nothing in this design depends on Aurora-specific behaviour, so the
migration path stays open.

Postgres is chosen deliberately over a document store because the two hardest constraints in
this design — R1 (`tenant_id` everywhere) and RLS-based isolation — are enforced *by the
database engine* in Postgres. That is the whole point: isolation that the application
cannot forget to apply.

**ASSUMPTION — connection pooling via PgBouncer (or RDS Proxy) in `transaction` pooling
mode.** This interacts directly with the RLS design and is not a free choice — see the
warning in [§3.4](#34-connection-pooling-caveat-important).

**ASSUMPTION — migration tooling.** A SQL-first migration tool (Drizzle Kit, or
node-pg-migrate) rather than an ORM-owned schema. Reason: R1 and the RLS policies are
expressed most clearly as raw DDL, and we will want to lint the DDL in CI ([§10](#10-r1-enforcement)).
Not yet decided; see [§11](#11-open-questions--resolutions-register).

### 2.3 Where AWS fits

**ASSUMPTION for all of the following.** None of these were dictated beyond "AWS".

| Concern | Proposed | Note |
|---|---|---|
| Compute | ECS Fargate behind an ALB, or AWS Amplify Hosting | Fargate if we want control over the runtime; Amplify if we want the managed Next.js path. Open. |
| Database | RDS PostgreSQL, Multi-AZ | See §2.2 |
| Secrets | AWS Secrets Manager | DB creds, 2FA encryption key, third-party API keys |
| File/object storage | S3, per-tenant key prefix `tenant/<tenant_id>/...` | Object storage has no RLS. Isolation there is an *application* responsibility and must be designed separately — flagged as an open item. |
| Audit archive (post-12mo) | **DECIDED — S3 cold storage** (Glacier Instant/Flexible class), written by a scheduled job that then drops the Postgres partition | See [§8.3](#83-retention--decided-12-months-hot-then-s3) |
| Async / metering jobs | EventBridge Scheduler → Lambda, or an in-app queue | Needed by [§7](#7-entitlements--soft-stop-limits-r3) for usage rollups |
| TLS / DNS | Route 53 + ACM wildcard cert `*.yourcrm.com` | The wildcard cert is what makes subdomain routing ([§4](#4-subdomain-based-tenant-routing)) practical |
| Observability | CloudWatch initially | Structured logs must carry `tenant_id` on every line |

---

## 3. Tenancy

**DECIDED — pooled (shared) database, shared schema, isolated by Postgres Row-Level
Security.** One database, one schema, every tenant's rows in the same tables, separated by
`tenant_id` and enforced by RLS policies in the engine.

### 3.1 Why pooled, and what we are accepting

The three realistic options and their tradeoffs:

| Model | Isolation strength | Ops cost per tenant | Cross-tenant queries | Noisy-neighbour risk |
|---|---|---|---|---|
| Database-per-tenant | Strongest | High (N migrations, N connections, N backups) | Painful | Low |
| Schema-per-tenant | Strong | Medium (N schemas to migrate; Postgres degrades in the thousands) | Awkward | Medium |
| **Pooled + RLS (chosen)** | Good, but *engine-enforced* rather than physical | Lowest — one migration, one backup | Trivial | Highest |

We are choosing pooled because a CRM's cost structure lives or dies on per-tenant
operational overhead, and because one migration path beats N. What we are **accepting** in
exchange, explicitly:

1. **A single bug or misconfiguration can cross tenants.** This is the real risk. It is
   mitigated by making RLS the enforcement mechanism (the database refuses, rather than the
   application remembering), and by never letting the application connect as a role that can
   bypass RLS ([§3.5](#35-the-bypassrls-trap)).
2. **Noisy neighbours are real.** A tenant with 5M contacts shares I/O with a tenant with
   500. Phase 0 does not solve this; the escape hatch is to move an outlier tenant to its own
   database later, which the design keeps possible because `tenant_id` is on every row.
3. **"Delete a tenant" is a large multi-table delete**, not a `DROP DATABASE`. Needs a
   deliberate, ordered teardown routine. Not designed in Phase 0.

### 3.2 The isolation invariant

> Every tenant-scoped table has `tenant_id UUID NOT NULL REFERENCES tenants(id)`,
> has RLS **enabled and forced**, and carries a policy keyed on
> `current_setting('app.current_tenant_id')`.

This is R1 plus its enforcement. R1 (the column) without RLS (the policy) is just a
convention; RLS without R1 has nothing to key on. They are one decision.

### 3.3 How RLS is actually enforced per request

The mechanism, precisely:

1. Middleware resolves the subdomain to a `tenant_id` ([§4](#4-subdomain-based-tenant-routing)).
2. The session cookie is validated, yielding a `user_id` **and the `tenant_id` that user
   belongs to**.
3. **These two must match.** If the session's tenant and the subdomain's tenant disagree,
   the request is rejected — this is the check that stops a user of tenant A from replaying
   a valid cookie against tenant B's subdomain.
4. The data-access layer opens a transaction and, as the first statement, runs:

   ```sql
   SET LOCAL app.current_tenant_id = $1;
   ```

5. Every query in that transaction now sees only that tenant's rows, because the engine
   filters them.

`SET LOCAL` (not `SET`) is load-bearing: it scopes the setting to the enclosing transaction
and it is reverted on commit or rollback, so the value cannot leak to the next request that
borrows the same pooled connection.

**DECIDED — the tenant context comes from the server-side session and the subdomain, never
from a client-supplied header, body field, or query parameter.** A `tenant_id` that the
client can set is not a security boundary.

### 3.4 Connection pooling caveat (important)

With an external pooler in **transaction** mode, a connection is handed back to the pool at
the end of each transaction. That is compatible with `SET LOCAL` — and *only* with
`SET LOCAL`. Two failure modes to design against, both of which are silent cross-tenant
data leaks rather than loud errors:

- Using `SET` instead of `SET LOCAL` — the value survives on the physical connection and the
  next borrower inherits another tenant's context.
- Running a query **outside** a transaction — there is no `SET LOCAL` in effect, so
  `current_setting('app.current_tenant_id')` is unset.

Mitigation, and this should be treated as a requirement on the data-access layer, not a
style preference: `current_setting('app.current_tenant_id', true)` returns NULL rather than
erroring when unset, and the policies in the schema file are written so that **a NULL
tenant context matches zero rows**. Combined with `FORCE ROW LEVEL SECURITY`, a query that
forgets its context returns nothing instead of returning everything. Failing closed is the
entire design goal here.

### 3.5 The `BYPASSRLS` trap

Table owners and superusers bypass RLS by default. Therefore:

- The application connects as a **dedicated non-superuser role** (`crm_app`) that does
  **not** own the tables and does **not** have `BYPASSRLS`.
- Tables are additionally marked `FORCE ROW LEVEL SECURITY` so policies apply even to the
  owner.
- Migrations run as a separate, more privileged role, out-of-band from request traffic.

If the app ever connects as the owner or as a superuser, every policy in the schema file is
silently inert. This is the single most likely way this design fails in practice, so it is
worth a startup assertion: on boot, verify the connected role is not superuser and lacks
`BYPASSRLS`, and refuse to start otherwise.

---

## 4. Subdomain-based tenant routing

**DECIDED — tenants are addressed as `company.yourcrm.com`.**

### 4.1 Resolution order

Resolution happens in **Next.js middleware**, before any route handler and therefore before
any query executes:

1. Read the `Host` header; strip the apex domain to get the label (`company`).
2. Reject reserved labels (`www`, `api`, `app`, `admin`, `static`, `assets`, `mail`, plus
   whatever else we hold back). These must also be blocked at tenant-signup time so a tenant
   can never claim one.
3. Look up the label in `tenants.subdomain` (unique, lowercase, indexed).
4. Not found, or tenant not `active` → render a "workspace not found / suspended" page. Do
   not fall through to the app.
5. Found → attach the resolved `tenant_id` to the request for the data-access layer to
   consume.

Only after this does anything touch the database on the tenant's behalf.

### 4.2 The lookup cost

Every single request needs subdomain → `tenant_id`. A database round-trip in middleware on
every request is a poor trade.

**ASSUMPTION — cache the mapping** (subdomain → `tenant_id` + status) in an edge-appropriate
cache with a short TTL, invalidated on tenant rename or status change. The exact cache
(Next.js data cache, a small KV, or an in-process LRU per instance) is undecided.

Note the sequencing problem this creates: the resolution lookup happens *before* any tenant
context exists, so it cannot itself run under RLS as `crm_app`. This is the one legitimate
cross-tenant read in the system. It should be served by a narrowly-scoped path — a dedicated
read of `tenants` only, ideally through a separate role or a `SECURITY DEFINER` function
that returns nothing but `(id, status)`. Flagged as an open item; do not let it become a
general-purpose god-mode connection.

### 4.3 Cookies

**ASSUMPTION — session cookies are scoped to the specific subdomain**, not to `.yourcrm.com`.
A cookie set on the parent domain is sent to *every* tenant's subdomain, which is precisely
the thing we are trying to prevent. Per-subdomain cookies mean a user belonging to two
tenants authenticates twice; that is the correct trade. This also means custom vanity
domains (`crm.company.com`) are a later, separate design problem — not Phase 0.

---

## 5. RBAC (R2)

**DECIDED — flexible default roles.**

"Flexible" specifically means:

1. **Defaults ship.** Every new tenant is seeded with a sensible set of roles so they are
   productive on day one without configuring anything.
2. **Roles are tenant-scoped rows, not an enum.** The `roles` table carries `tenant_id`
   (R1 applies here too). Two tenants can both have a role named "Manager" that grants
   different things, and neither can see the other's.
3. **Tenants can create their own roles** and compose them from the permission catalogue.
   They are not locked to the defaults.
4. **Permissions are the fixed vocabulary; roles are the flexible composition.** Tenants
   compose roles out of permissions we define; they do not invent new permissions. This is
   the important line: an open-ended permission vocabulary is unenforceable, because the
   application has to `if`-check against *something* known at build time.
5. **Default roles are `is_system = true`** and protected from deletion/renaming, so a
   tenant cannot delete their way into a workspace with no administrator. Tenants may
   *clone* a system role and edit the clone.
6. **Users can hold multiple roles**, via a `user_roles` join. Effective permissions are the
   **union** of the permissions of all held roles. Union (rather than a deny-precedence
   model) is chosen for predictability — deny rules interacting with union semantics is a
   well-known source of "why can't this user do X" support tickets. If explicit denies are
   ever needed, that is a deliberate later change, not something to leave ambiguous now.

**ASSUMPTION — the default role set** is `owner`, `admin`, `manager`, `member`,
`read_only`. The `executive` role referenced by the 2FA rule ([§6.2](#62-two-factor-authentication))
needs to map onto this list; the schema models "executive" as a **flag on the role**
(`requires_2fa`) rather than a magic role name, so the rule survives tenants renaming or
redefining their roles. The exact default list is an open question.

**ASSUMPTION — permission naming** follows `resource.action` (`contacts.read`,
`contacts.delete`, `billing.manage`). The Phase 0 catalogue is a starting point; it will
grow with every feature and that is expected.

---

## 6. Security: sessions and 2FA

### 6.1 Sessions

**DECIDED — sessions expire 24 hours after issuance, absolutely.**

**RESOLVED (was Q3) — absolute, not sliding or rolling.** `expires_at` is computed once, at
session creation, and is never extended by activity. A user active at hour 23 is asked to
re-authenticate at hour 24.

Why absolute is the right answer and not just the simpler one: a sliding window means an
active session never expires, which removes the bound for exactly the population where it
matters — a stolen token on a machine someone is still using. A 24-hour limit that can be
pushed forward indefinitely is not a 24-hour limit. The cost, accepted openly, is that a
user working a long shift is interrupted once a day.

**This is enforced in the database, not by convention.** The schema carries a
`sessions_absolute_expiry` trigger that raises if an `UPDATE` changes `expires_at` or
`issued_at`. The reason is specific: "absolute expiry" is one well-meaning line of code away
from becoming a sliding window — an update that touches `last_seen_at` and helpfully bumps
`expires_at` alongside it. No reviewer would flag that as a security change. The trigger
makes it fail loudly instead. `last_seen_at` is telemetry only and must never feed
`expires_at`; ending a session early is `revoked_at`, and giving a user longer means issuing
a new session.

Mechanics:

- Server-side session records (a `sessions` table), not self-contained JWTs. Reason: we need
  **revocation** — "log out all devices", forced logout on role change, and forced logout on
  2FA enrolment. A stateless JWT cannot be revoked before its expiry without a
  denylist, which is a session table with extra steps.
- Token is an opaque bearer credential sent via `Authorization: Bearer <token>` — never a
  cookie. Looked up against the `sessions` table on every request (see
  [Why opaque Bearer tokens over JWT](#why-opaque-bearer-tokens-over-jwt-mobile-prep-phase-8)
  below for why this is a deliberate choice, not an omission).
- `sessions` is tenant-scoped and carries `tenant_id` (R1).
- Session validation checks both `expires_at` and a `revoked_at` null-check.

The `sessions` table was not in the Phase 0 brief's table list, but it is required by this
decision and is now a settled part of the design.

#### Why opaque Bearer tokens over JWT (mobile prep, Phase 8)

**DECIDED — the token stays an opaque, server-side session reference, looked up per request
against the `sessions` table. Stateless, self-contained JWTs were considered for Phase 8
mobile prep and explicitly rejected.** This is a documented, deliberate decision — a future
session should not relitigate it or "fix" it into JWT without reading the tradeoff below.

Phase 8's mobile-app prep only asked one real question of this design: does the existing auth
model work for a native client that cannot rely on a cookie jar? The answer is yes, without a
redesign — `apps/api`'s auth already runs on an `Authorization: Bearer <token>` header (see
`apps/api/src/middleware/session-context.ts`), never a cookie, so it already satisfies the
actual mobile requirement as-is. Verified directly as part of this prep work: grepping
`apps/api` for `cookie`, `set-cookie`, `setCookie`, and `fastify-cookie`/`@fastify/cookie`
returns zero matches, and the package has no cookie-plugin dependency. There was nothing to
fix here.

The natural follow-on question — "since we're touching auth for mobile, should we also switch
to stateless JWTs?" — was asked directly of the project owner and answered no, for one reason:
it would break a guarantee that is already built and already tested, in exchange for nothing
the mobile requirement actually needs.

- **Revocation is the load-bearing guarantee, and JWTs don't have it for free.** "Log out all
  devices," forced logout on role change, and forced logout on 2FA enrollment (this section
  and [§6.2](#62-two-factor-authentication)) all depend on the server being able to invalidate
  a session before its stated expiry. A self-contained JWT cannot be revoked once issued — the
  only way to add revocation to a stateless JWT is a denylist, which is a `sessions` table with
  extra steps and an extra piece of infrastructure (typically a Redis-backed blocklist) kept in
  sync with it. Migrating to JWT would not remove the per-request database check this design
  already does; it would keep an equivalent check and add a second store on top of it. That is
  strictly more moving parts for the same guarantee, not a simpler design.
- **The guarantee is not hypothetical — it is asserted by name in the existing test suite.**
  `apps/api/test/session-context.test.ts` asserts "a revoked session is rejected with 401, even
  though the token itself is well-formed." `apps/api/test/r2-dynamic-rbac.test.ts` goes
  further, asserting that revoking a permission mid-test blocks the very next request on the
  *same already-authenticated session* — no relogin, no restart — which only works because
  every request re-reads role/permission state from the database rather than trusting claims
  embedded at issuance. A JWT signs its claims once, at issuance; those claims go stale the
  instant a role is edited or a permission is revoked, which is precisely the behavior R2's
  dynamic-RBAC tests exist to rule out. Switching to JWT would either reintroduce a database
  check on every request to cover this gap — at which point the JWT carries no benefit over the
  opaque token, only its added complexity — or silently regress an already-tested guarantee.
- **Mobile does not, on its own, need JWT.** It needs an `Authorization` header and no
  dependency on cookies, both of which this design already provides. No requirement in Phase
  8's scope (offline token validation, cross-service trust without a shared database, etc.)
  would justify paying the revocation cost above to get there.

**What this changes in the running system: nothing.** No code in `apps/api` changed as part of
this decision — this subsection documents a decision *not* to change
`session-context.ts`, the `sessions` table, or `resolve_session_context()`. If a genuinely
JWT-shaped requirement appears later (for example, a third-party service needing to verify a
token without calling back into this API), that is a new, deliberate architecture decision for
the project owner to make explicitly — not a refactor to fold into unrelated work.

**A pre-existing discrepancy this check surfaced has now been corrected, not just flagged:**
the Mechanics list above used to describe a session cookie (`HttpOnly`, `Secure`,
`SameSite=Lax`, scoped per subdomain) inherited from this note's original §2.1
single-Next.js-deployable shape (`A1`). `apps/api` was built as a separate Fastify service and
never used that cookie at all — it authenticates against the same `sessions` table via the
Bearer token described above instead. The Mechanics list has been rewritten to describe that
Bearer-token transport directly, so it no longer conflicts with this subsection. This was a
wording fix only, not a session-model change: the revocation and absolute-expiry guarantees
apply identically regardless of how the token reaches the server. The broader question of
reconciling `A1`'s single-deployable assumption against the now-real, separate `apps/api`
service remains open and is unaffected by this fix — that is still a separate architecture
question left for the project owner, outside this task's scope.

*(No corresponding line was added to `ENGINEERING_RULES.md`: that document is structured
strictly around R1–R6 plus the reserved, explicitly-not-to-be-filled R7–R11 and the process
rule R12, and this decision is a token-transport tradeoff rather than a new rule of that shape.
There is no existing rule about session/token transport to append a one-line note to without
either overloading an unrelated rule or inventing content in a reserved slot, which R7–R11
explicitly forbids. Flagged here rather than force-fit.)*

### 6.2 Two-factor authentication

**DECIDED — 2FA is mandatory for executive-role users, optional for frontline staff roles.**

The important part is *how it is enforced*. A UI toggle is not enforcement; it is a
suggestion. The requirement is evaluated **server-side at two moments**:

**(a) At login.** After password verification, the server computes whether any role held by
the user has `requires_2fa = true`. Then:

- Requires 2FA **and enrolled** → challenge for the TOTP code. No code, no session.
- Requires 2FA and **not enrolled** → issue a restricted, short-lived
  *enrolment-only* session that can reach exactly one route: 2FA setup. It cannot read CRM
  data. This avoids the deadlock where a newly-promoted executive cannot log in at all, while
  still refusing them access to data before they enrol.
- Does not require 2FA but has enrolled voluntarily → challenge anyway. Opting in is binding.

**(b) At role assignment.** When a user is granted a role with `requires_2fa = true`, the
grant is recorded and **all of that user's existing sessions are revoked**. Otherwise a user
promoted to executive keeps browsing on a session that was issued under the weaker
requirement, for up to 24 hours. The next login runs path (a) and forces enrolment.

Design consequences:

- The requirement is a property of the **role** (`roles.requires_2fa`), not a hardcoded
  check against a role named "executive". Tenants define custom roles (R2), so any role can
  be marked as requiring 2FA. This is what makes R2 and the 2FA rule compose instead of
  fighting.
- Because a user can hold several roles ([§5](#5-rbac-r2)), the rule is: **2FA is required if
  *any* held role requires it.** Strictest-wins.

**ASSUMPTION — TOTP (RFC 6238) via authenticator app** as the Phase 0 second factor. SMS is
deliberately excluded (SIM-swap). WebAuthn/passkeys are the better long-term answer and the
schema should not preclude adding them — hence a `user_mfa_methods`-shaped design rather
than a single `totp_secret` column on `users`, noted in the schema file.

**DECIDED — the TOTP secret is never stored in plaintext.** The schema stores a *reference*
to a secret held in AWS Secrets Manager / KMS-encrypted, not the secret itself. Recovery
codes are stored hashed, exactly like passwords.

---

## 7. Entitlements — soft-stop limits (R3)

**DECIDED — soft stop, bounded at 150%. When a tenant exceeds a plan limit, the action is
allowed and the excess is metered for billing. Above 150% of the limit, it is rejected.**

### 7.1 The mechanic

For a limited resource (seats, contacts, API calls):

1. **Resolve the limit.** Look up the entitlement for the tenant: the plan-tier default,
   overridden by any per-tenant override row. (Per-tenant overrides matter — sales will
   promise a customer a custom limit, and the alternative is inventing a bespoke plan tier
   per negotiation.)
2. **Read current usage** for the current billing period.
3. **Decide** based on `soft_stop`:
   - `soft_stop = true` → **allow the action.** If usage now exceeds `limit_value`, record
     the excess as billable overage at `overage_unit_price`. Surface an in-app warning; do
     not block — until the ceiling in [§7.2](#72-the-150-ceiling).
   - `soft_stop = false` → hard cap. Reject with a clear upgrade path. This exists because a
     few limits genuinely must be hard (anything with an unbounded cost tail — outbound
     email volume, storage — where "we'll bill you" is not a real answer at 100x). R3 makes
     soft the *default*, not the only option.
4. **Meter.** Overage is computed from usage counters at the close of the billing period and
   handed to billing.

### 7.2 The 150% ceiling

**RESOLVED (was Q4) — soft stop is capped at 150% of the plan limit.** Three bands:

| Usage | Behaviour |
|---|---|
| 0–100% of `limit_value` | Normal. No charge beyond the plan. |
| 100–150% | **Allowed and billed** as overage. In-app indicator on; notification sent at the crossing. |
| Above 150% | **Hard block**, with an upgrade path. |

The billing-facing consequence this bounds: **soft stop means we can invoice a customer for
something they never explicitly agreed to at the moment they did it.** That is a product and
legal exposure, not just a technical one, and an *unbounded* soft limit turns it into a
runaway invoice — a looping integration can accrue thousands of dollars overnight, which is
a refund and a lost account, not revenue. 150% is a number a customer can be told in advance
and a support agent can defend.

Two implementation decisions that follow from it, both now in the schema:

- **The ceiling is a percentage (`overage_ceiling_pct`, `NOT NULL DEFAULT 150`), not an
  absolute unit count.** An absolute ceiling develops skew: 15,000 contacts set against a
  10,000-contact plan silently becomes a hard block *below* the plan limit the moment the
  tenant upgrades to a 25,000 plan — blocking a customer who just paid us more money. A
  ratio rescales with the limit and cannot drift that way. `NOT NULL` with a default also
  means there is no "forgot to set a ceiling" state; an uncapped soft limit is
  unrepresentable.
- **The effective ceiling is a generated column (`overage_ceiling_value`)**, so the hot-path
  check is one comparison rather than arithmetic each caller re-derives. It is NULL — no
  ceiling applies — in exactly two correct cases: unlimited/flag-only features (nothing to
  take a percentage of), and hard-capped features (`soft_stop = false` already blocks at the
  limit).

The full enforcement order is written into the `feature_entitlements` table comment in the
schema file so the data-access layer implements it exactly once. The user-facing half is not
optional: notify at the 100% crossing, show a persistent indicator through the 100–150%
band, warn again approaching the ceiling, and make the block message name the number
("you have used 150% of your plan limit") rather than saying "limit exceeded".

### 7.3 Usage accounting

Two shapes of limit, and they need different accounting — conflating them is a common and
painful mistake:

- **Point-in-time ("stock") limits** — seats, contacts. "How many exist *right now*." Best
  served by a maintained counter, reconciled periodically against a `COUNT(*)`.
- **Period-accumulating ("flow") limits** — API calls. "How many happened *this period*."
  Reset each billing period; must not be served by a live `COUNT(*)` over an events table at
  request time.

**ASSUMPTION** — both are represented in a single `usage_counters` table keyed by
`(tenant_id, metric_key, period_start)`, with stock metrics using the current open period
row as a running value. Each counter row freezes both `limit_snapshot` and
`ceiling_snapshot` at period open, so "why was I billed / blocked on the 14th" is answerable
from what was true on the 14th rather than from the entitlement row as it stands today. The alternative — deriving everything from a raw usage-events stream
— is more accurate and more auditable but needs a rollup job before it is queryable at
request latency. Starting with counters and adding an events stream later is the cheaper
order. Flagged.

**ASSUMPTION** — the enforcement check lives in the data-access layer as an explicit,
named guard, not scattered through feature code.

---

## 8. Audit logs (R6)

**DECIDED — event-based, 12-month hot storage.**

### 8.1 What "event-based" means here

An **append-only log of discrete domain events** — "what happened, described in the language
of the business" — *not* row-level before/after snapshots of every `UPDATE`.

The distinction, concretely:

| | Event-based (chosen) | Row-snapshot / CDC (not chosen) |
|---|---|---|
| Unit | `contact.merged`, `user.role_granted`, `subscription.upgraded` | `UPDATE contacts SET ... WHERE id=...` before/after |
| Written by | Application, deliberately, at the point of the business action | A trigger or logical-decoding stream, automatically |
| Reads like | "Priya merged contact A into B on the 3rd" | A JSON diff of 14 columns |
| Coverage | Only what we remember to emit | Everything, including things we did not think about |
| Volume | Low — one row per meaningful action | High — one row per statement |

The trade is explicit: **we accept incomplete coverage in exchange for a log that answers
questions humans actually ask.** "Who deleted this account?" is answerable from an event
log in one query, and requires reconstruction from a diff log. The mitigation for the
coverage gap is that emitting an event is part of the definition of done for any
state-changing operation, and the high-risk categories (auth, permission changes, billing,
data export, deletion) are non-negotiable emitters.

Design properties:

- **Append-only.** No `UPDATE`, no `DELETE` (outside the retention job). Enforce with grants
  — `crm_app` gets `INSERT` and `SELECT` on `audit_events`, and nothing else. A log the
  application can rewrite is not an audit log.
- **Immutable payload.** `JSONB` capturing the event's own facts, denormalised on purpose. If
  a contact is later renamed, the audit event must still say what the name was *at the time*.
  Joining to live tables to render history is wrong; it rewrites the past.
- **Actor is nullable.** System- and integration-originated events have no human actor. An
  `actor_type` discriminates user / system / api_key / integration.
- **Tenant-scoped and RLS-protected** like everything else (R1).

### 8.2 Indexing for the access pattern

Essentially every read is *"events for this tenant, in this time range, optionally filtered
by type or actor, newest first."* So the primary index is a composite on
`(tenant_id, occurred_at DESC)`, with supporting indexes for type and actor filters. A
GIN index on the JSONB payload is deliberately **not** added in Phase 0 — it is expensive to
maintain on a write-heavy append-only table, and should be added only when a real query
demands it. The same reasoning applies to the R5 `custom_attributes` columns
([§9.2](#92-r5--custom-fields-from-day-one)), and both are tracked as one decision (Q20)
rather than two independent guesses. **Q20 is now scheduled, not open: it is deferred to
Phase 2** ([§11.4](#114-deferred-to-phase-2)), which is the first point at which live Phase 1
business objects will have produced the slow-query data the decision needs.

### 8.3 Retention — decided: 12 months hot, then S3

**RESOLVED (was Q1, previously the highest-priority open question in this note).** The
policy in full:

1. A **rolling 12-month window of monthly partitions** stays queryable in PostgreSQL. This
   is what the audit UI, investigations and exports read.
2. A **scheduled job dumps the aging (13th-oldest) partition to S3 cold storage**, verifies
   the dump, and only then **drops the partition** from Postgres.
3. **Nothing is hard-deleted.** History leaves the primary database; it does not cease to
   exist. Retrieval beyond 12 months is an out-of-band request against the archive, and is
   deliberately *not* a product feature — building a UI over cold storage invites the
   expectation that it is fast.

Why this beats the two alternatives that were on the table. **Hard delete** is cheaper and
irreversible, and a CRM holds exactly the records that get asked about years later — who
exported the customer list, who changed whose permissions. **Tiering by event category**
keeps the compliance-relevant subset hot but produces two retention regimes and two query
paths, for a saving that S3 pricing makes irrelevant at this data volume. Archiving
everything uniformly is the simplest thing that keeps the history.

`audit_events` is **partitioned by month** (`PARTITION BY RANGE (occurred_at)`), which this
decision now doubly justifies: the retention action *is* a `DROP TABLE` on a partition —
instant, and it reclaims the space immediately — where deleting a year-old slice of a large
unpartitioned append-only table is a long, bloat-generating operation competing with live
traffic. The partition boundary is also the natural archive unit: one partition, one set of
S3 objects, one atomic hand-off.

**The job itself is an implementation task for a later phase. It does not exist and is not a
Phase 0 deliverable.** What must be true of it is recorded now so the requirements are not
re-derived later:

- It keeps **at least twelve months of partitions declared ahead of `now()`**. If coverage
  runs out, inserts beyond the last declared partition fail — which is intentional. A
  `DEFAULT` partition is deliberately not used: it would silently absorb those rows and hide
  the failure until the default partition is enormous and cannot be split without an
  exclusive lock. Monitor partition *coverage*, not just job success — "the job ran" and
  "there is a partition for next month" are different assertions and only the second one
  matters.

  **The schema now pre-creates thirteen monthly partitions (2026-09 through 2027-09),** so
  the runway matches the twelve-month hot window rather than expiring a month after the file
  was written. That removes the job's status as a near-term production dependency, but it
  does not remove the job: see [§13](#13-what-phase-1-should-pick-up-first).
- It **exports before it drops, and verifies the export before it drops.** Drop-then-
  discover-the-dump-failed is unrecoverable.
- It is **idempotent and safely re-runnable**.
- It runs as a **privileged role, never as `crm_app`** — the application role has `INSERT`
  and `SELECT` on `audit_events` and nothing else, and must never be able to drop a
  partition.
- **Dropping a partition is itself an audited administrative action.**

One deliberate non-decision: the archive **manifest** (which partition went where, when,
with what checksum) lives outside this schema, in S3 inventory or the job's own metadata
store. A manifest of cross-tenant partitions has no meaningful `tenant_id`, and inventing
one would mean carving the first exception into R1 for the sake of bookkeeping. That is a
bad trade, and it is the kind of exception that, once made, gets reused.

Still to settle before this ships — flagged rather than assumed: the exact S3 storage class
and lifecycle transitions, the archive file format (Parquet for Athena queryability versus
JSONL for simplicity), the legally required retention *floor* in the archive, and where the
job runs (EventBridge → Lambda, or a scheduled ECS task). See
[§11](#11-open-questions--resolutions-register).

---

## 9. Extensibility: master data (R4) and custom fields (R5)

R4 and R5 are the two rules that decide how much of a tenant's own vocabulary the product
can absorb **without a deploy**. They pull in opposite directions and are meant to: R4 makes
*controlled* vocabularies editable, R5 makes *uncontrolled* extension possible. §9.3 draws
the line between them, because the failure mode of these two rules is using the wrong one.

### 9.1 R4 — master tables, not enums

**DECIDED — sources, stages, statuses and reasons are rows in tenant-scoped master
tables. Never PostgreSQL `ENUM` types, and never a `CHECK`-constrained text column either.**

Phase 0 has **six**, following the R1 pattern exactly (`tenant_id NOT NULL REFERENCES
tenants(id)`, RLS enabled *and* forced, `UNIQUE (tenant_id, id)` so referencing tables can
use composite foreign keys):

| Table | Answers | Added |
|---|---|---|
| `lead_sources` | Where did this lead come from? | R4 round |
| `lead_statuses` | What state is this lead *record* in — has anyone worked it? | R4 round |
| `lead_stages` | Where is it in the **pre-sales qualification** pipeline? | R4 round |
| `lead_loss_reasons` | Why did this enquiry never become an opportunity? | R4 round |
| `deal_stages` | Where is this deal in the **sales pipeline** — how close is it to money? | Q17 round |
| `deal_loss_reasons` | Why was this qualified deal lost? | Q17 round |

Each carries the same shape: `id`, `tenant_id`, `code` (stable machine key), `label`
(renameable display text), `description`, `sort_order`, `is_active`, `is_system`,
`custom_attributes`, timestamps. All six are seeded per tenant at provisioning by
`provision_tenant_master_data()` — 46 rows per tenant.

#### Why leads and deals do not share a stage vocabulary (Q17, resolved)

`lead_stages` and `deal_stages` are **structurally identical and semantically different**,
and that difference is the whole reason they are two tables.

A **lead's** stages are *pre-sales qualification*. They answer "is there a real opportunity
here at all?" — an unqualified enquiry being worked toward the moment it becomes, or fails
to become, a deal. The terminal state is a judgment about the lead's validity: converted, or
discarded. A **deal's** stages are *the sales pipeline itself*. They answer "how close is
this known-real opportunity to money?" — proposal, negotiation, contract, closed. The
terminal state is a commercial outcome: revenue booked, or revenue lost.

Different lifecycles, different owners (SDR versus AE), different reporting, different rates
of change. Forcing them onto one list reproduces exactly the defect §5.2 of the schema warns
about when `lead_statuses` and `lead_stages` are merged: a single axis that cannot represent
two independent facts. Three concrete symptoms of the merged version:

- One picker containing both an SDR's "Qualification" and an AE's "Negotiation", where every
  lead report must exclude the deal-only values and every deal report the lead-only ones.
- A tenant reordering their sales pipeline silently reorders their lead pipeline.
- **Lead→deal conversion rate becomes uncomputable.** It is a rate *between* two pipelines;
  if they are one pipeline there is nothing to measure across.

The same split applies to loss reasons, and bites harder there because these are the two
most-reported-on vocabularies in a CRM and they feed different decisions. Lead loss reasons
("went unresponsive", "duplicate record", "not a fit") tune marketing spend and lead
qualification. Deal loss reasons ("lost to competitor", "missing capability", "budget
withdrawn") tune pricing, product and competitive positioning. Merged, they produce one "why
we lose" report that answers neither question — with "Duplicate Record" appearing in a
competitive win/loss review as the visible symptom.

Cost accepted: two lists to configure instead of one, and two more seeding blocks. That is
the correct trade against a vocabulary that is wrong for both objects. The seeded defaults
are deliberately *different* between the two — if they had come out identical, that would
have been evidence they did not need to be two tables.

**Deliberately NOT added: `deal_sources` and `deal_statuses`.** Q17 asked only about stages
and loss reasons; the symmetric question was considered and answered no, rather than either
silently adding two tables or silently not thinking about it.

- **No `deal_sources`.** `lead_sources` is an *acquisition-attribution* vocabulary — where
  the business came from. That question is asked once, at first contact, and its answer does
  not change when a lead becomes a deal. A second list would be the same vocabulary
  maintained twice, guaranteed to drift, and attribution reporting would then have to
  reconcile "Referral" against "Referral" across two tables. Phase 1 `deals` should carry the
  source through from the originating lead. Two consequences are left to Phase 1, recorded as
  **Q23**: whether `lead_sources` wants an object-neutral name once a second object
  references it, and how a deal created with no originating lead gets a source.
- **No `deal_statuses`.** A lead needs both a status and a stage because they are genuinely
  independent axes — "has anyone worked this record" is not "how close is it to closing", and
  a lead can be Contacted *and* in Qualification. A deal has no such second axis: its record
  state *is* its pipeline position, and the terminal semantics a status would carry
  (`lead_statuses.is_terminal`) are already carried by `deal_stages.stage_type IN
  ('won','lost')`. Adding one would recreate the one-concept-two-lists confusion, whose first
  symptom is a deal whose status says Open and whose stage says Closed Won. What *would*
  change this: a deal lifecycle genuinely orthogonal to the pipeline — an approval workflow,
  or contract execution state. If Phase 1 needs one, it should be a new master named after
  the question (`deal_approval_states`), not a `deal_statuses` table named after the symmetry
  with leads.

Both of those are **judgment calls made here, not instructions received** — flagged for the
project owner rather than buried.

#### Why this beats an enum

Three independent reasons, each sufficient on its own.

**1. Tenant customisability without a schema migration.** This is the big one. A brokerage
that wants a "Zillow" lead source and an agency that wants "Trade Show" are asking for a
*row*, not a deploy. With an enum, every customer request becomes `ALTER TYPE ... ADD VALUE`
— a migration, a release, and a change to a global vocabulary that only one tenant asked
for. In a pooled multi-tenant database an enum is **by definition global**, which is the
wrong scope for a per-tenant concept: tenant B pays the cost of tenant A's request and can
see it in their own picker. Rows are tenant-scoped by construction (R1), so tenant A's
sources are invisible to tenant B and cost them nothing.

**2. Reorder and deactivate without breaking historical data.** Enum values cannot be
removed once anything references them, and their sort order is the order they were declared
in — so a value added later sorts last forever unless the type is rebuilt. With rows,
`sort_order` is a column anyone can edit, and retiring a value is `is_active = false`.
**Deactivation is the important half.** A source that stops being used must vanish from the
picker for *new* records while remaining perfectly resolvable for the three years of
historical leads that reference it. Deleting orphans history; leaving it in the picker
clutters it; an enum offers no third option. `is_active` is that third option, and the
composite foreign keys from business objects are `ON DELETE RESTRICT` precisely so that a
mistaken deletion fails loudly instead of taking the referencing records with it.

**3. Per-tenant labels, decoupled from the machine key.** `code` is the stable identifier
application logic and reports key on; `label` is display text the tenant renames freely. One
tenant's "Qualified" is another's "Under Contract". With an enum the stored value *is* the
display string, so renaming it either breaks every query that matched on it or forces a
translation layer — which is this table, with extra steps.

**What we pay:** a join (or a cached lookup) to render a label, and referential integrity
that is FK-enforced rather than type-enforced. Both are ordinary. The enum saves one join
and costs a migration per customer request.

#### Two design calls worth stating

**Four typed tables, not one generic `master_list_items` table with a `list_type` column.**
The generic version is tempting — one table, one seeding routine, one admin screen — but it
cannot express a typed foreign key: nothing would stop a lead's `source_id` from pointing at
a loss reason, since both are rows in the same table. Recovering that guarantee needs a
redundant discriminator column in every referencing table plus a composite FK carrying it,
which is more machinery than four small tables. Typed tables also let each master carry what
it actually needs — `lead_stages` has `stage_type` and `probability_pct`, the others do not
— instead of a shared nullable grab-bag.

**Semantics live in columns, not in codes.** `lead_stages.stage_type` (`open`/`won`/`lost`)
and `lead_statuses.is_terminal` exist because forecasting and "open work" counts need to know
what a value *means*. Deriving that from the code (`WHERE code = 'closed_won'`) would break
the moment a tenant renames or adds a stage — the same failure mode as hardcoding a role
named `executive`, and the same fix as `roles.requires_2fa`. Reports must filter on
`stage_type`, never on `code`.

Seeded rows are `is_system = true`, mirroring `roles.is_system`: renameable, reorderable and
deactivatable by the tenant, but **not deletable and not re-codable**, because saved reports
and automations key on those codes. A tenant who deletes a seeded value would break their
own dashboards, and the breakage would surface weeks later.

### 9.2 R5 — custom fields from day one

**DECIDED — core entities carry `custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb`,
with a `CHECK (jsonb_typeof(custom_attributes) = 'object')`.**

**Phase 0 has no CRM business-object tables.** Contacts, companies, leads, deals, activities
and notes all arrive in the next phase. So Phase 0 does two things: it applies the column
where it is already meaningful, and it fixes the pattern so the next phase does not
re-derive it.

Applied now to `tenants` (tenant-level settings and configuration: branding, locale
defaults, integration identifiers, toggles a CSM flips), `users` (per-user profile
extensions: licence number, desk, region, employee id), and all four R4 master tables
(per-tenant metadata on a lookup value — a UI colour, the external code it maps to in an ad
platform).

> **This is mandatory for the next phase.** Every CRM business object created in Phase 1 —
> `contacts`, `companies`, `leads`, `deals`, `activities`, `notes` — **must** be created with
> this column and this `CHECK`, in the same DDL that creates the table. That is where the
> rule earns its keep. The Phase 0 applications above exist so the pattern is copied rather
> than reinvented, and the commented `leads` example in §5.5 of the schema file shows the
> exact shape.

**The tradeoff, stated plainly.** In exchange for never needing a migration to add a
tenant-specific field, we accept data that is **untyped and unindexed by default**. Nothing
stops `{"close_date": "not a date"}`; validation is the application's job, driven by a
per-tenant field-definition registry (a Phase 1 table: which keys exist, their types, whether
they are required). And a filter on a custom attribute is a sequential scan until an index
exists.

The alternatives are worse in a pooled schema. A per-tenant `ALTER TABLE` destroys the "one
schema, one migration" property that justified pooling in the first place ([§3.1](#31-why-pooled-and-what-we-are-accepting)).
An Entity-Attribute-Value side table costs a join per field and turns every query into a
pivot. A jsonb column costs nothing until used — and retrofitting one onto a large table
later means a table rewrite or a slow backfill, which is the whole argument for doing it on
day one.

**The standard mitigation, deliberately deferred.** The usual answer for query performance
is a GIN index on the jsonb column:

```sql
CREATE INDEX <t>_custom_attributes_gin
    ON <t> USING gin (custom_attributes jsonb_path_ops);
```

`jsonb_path_ops` is smaller and faster than the default operator class for the containment
(`@>`) queries this actually serves, at the cost of not supporting key-existence (`?`)
operators. **It is not created in Phase 0**, for the same reason the GIN index on
`audit_events.payload` is not ([§8.2](#82-indexing-for-the-access-pattern)): it is paid on
every write to serve reads nobody has issued yet. The right target is often narrower still —
an expression index on the two or three keys a tenant actually filters by — and that cannot
be known before real query patterns exist. **This is a future-phase decision, to be revisited
once the CRM business objects are live and there is slow-query data to point at.** It is
listed as an open follow-up in [§11](#11-open-questions--resolutions-register) rather than
being quietly decided here.

**Governance is what keeps it from becoming a swamp.** The rule: *anything the product
reasons about gets a real column; `custom_attributes` is for what the tenant reasons about.*
Applied to Phase 0, that is why the column is **absent** from join tables (they model a
relationship, not an entity), `permissions` (a fixed vocabulary *we* define), `sessions` /
`user_mfa_methods` / `user_recovery_codes` (a security surface — arbitrary tenant-writable
data does not belong beside credential material), `feature_entitlements` / `usage_counters`
/ `overage_line_items` (billing artifacts must stay typed and auditable; a money-relevant
value in an untyped blob is a revenue incident waiting to happen), and `audit_events` (its
`payload` already is this, and it is immutable by design).

### 9.3 Which rule applies to a new field

The failure mode of having both is reaching for the wrong one. The test:

| Situation | Use |
|---|---|
| A closed list of values the product must *reason* about (route on, report on, drive automation from) | **R4** — a master table |
| The tenant needs to store a value the product only stores and displays | **R5** — `custom_attributes` |
| The product must branch on it *and* tenants must be able to add values | **R4**, with the branching keyed on a semantic column (`stage_type`), never on `code` |
| It affects auth, authorisation, billing, or isolation | **Neither** — a real, typed column with constraints |

That last row is the one to enforce in review. `custom_attributes` is tenant-writable data;
nothing that decides what a user may do, or what they are charged, may be read from it.

---

## 10. R1 enforcement

R1 — *every table carries `tenant_id`* — is a constraint that decays silently. It holds
perfectly on day one and is violated by the third developer who adds a lookup table in a
hurry. A constraint that depends on remembering is not a constraint.

What Phase 0 can state now, even though none of it is built yet:

1. **A CI migration lint.** A check that runs against the migrated schema and fails the build
   if any table in the application schema lacks a `tenant_id UUID NOT NULL` column, lacks
   `ENABLE ROW LEVEL SECURITY`, or has no policy attached. This is a ~50-line query against
   `pg_catalog` / `information_schema`, and it is the single highest-leverage piece of
   tooling this project can build early. **It should be the first item of Phase 1.**
2. **An explicit allowlist for genuine exceptions.** In practice this is only the migration
   bookkeeping table — `tenants` carries a generated `tenant_id` precisely so it needs no
   exemption. Exceptions live in a checked-in list, so adding one is a visible, reviewable
   act rather than an omission.

   The R4 master tables are the live test of this. A lookup table is exactly what someone
   reaches for an exemption on — *"it's just a list of statuses"* — and that instinct is what
   R4 refuses: these lists are **tenant-owned data**, so they are tenant-scoped and
   policy-protected like a lead or a user. Adding the four master tables required no change
   to the lint and no new exception, which is the test of whether a pattern is actually
   uniform.
3. **A boot-time assertion** that the application's DB role is not superuser and lacks
   `BYPASSRLS` ([§3.5](#35-the-bypassrls-trap)).
4. **A cross-tenant integration test** — seed two tenants, set the context to A, assert that
   every table returns zero rows belonging to B. Cheap to write, and it fails loudly the day
   someone adds a table without a policy.

Note the ordering: (1) and (2) catch the *column* being missing; (3) and (4) catch the
*policy* being missing or inert. Both failure modes are silent in production and both are
trivially detectable in CI.

---

## 11. Open questions / resolutions register

This register has two halves. The first records questions that **have been answered** and
how — kept rather than deleted, because the reasoning behind a settled decision is the thing
future work needs most and is the first thing lost. The second is what remains genuinely
open.

### 11.1 Resolved

All five were confirmed by the project owner and are **integrated into this note and the
schema file**, not merely noted here.

| # | Question | Resolution | Where it landed |
|---|---|---|---|
| **Q1** | What happens to audit events after 12 months? | **RESOLVED — 12-month hot partitioned window, then an automated job dumps the aging partition to S3 cold storage and drops it from Postgres. Nothing is hard-deleted; retrieval past 12 months is out-of-band, not a product feature.** The job is an implementation task for a later phase and does not exist yet. | [§8.3](#83-retention--decided-12-months-hot-then-s3) rewritten as decided; §2.3 archive row now decided; schema file §6 header comments and the `audit_events` table comment updated. |
| **Q3** | Is the 24h session expiry absolute or sliding? | **RESOLVED — absolute.** `expires_at` is set once at creation and never extended by activity. Confirms what the schema already assumed, and adds enforcement: a `sessions_absolute_expiry` trigger rejects any `UPDATE` that changes `expires_at` or `issued_at`, so the rule cannot be eroded by a well-meaning "bump the expiry while we touch `last_seen_at`" commit. | [§6.1](#61-sessions) upgraded from ASSUMPTION to DECIDED; schema `sessions` table, new trigger, `CHECK (expires_at > issued_at)`, table comment. |
| **Q4** | Is there a per-tenant overage ceiling, and what is it? | **RESOLVED — soft-stop with overage billing up to a 150% ceiling, hard block above it.** Represented explicitly as `feature_entitlements.overage_ceiling_pct NOT NULL DEFAULT 150` plus a generated `overage_ceiling_value`; the previous nullable, unbounded `overage_hard_ceiling` is gone, so "no ceiling" is no longer a state anyone can leave a row in by omission. | New [§7.2](#72-the-150-ceiling); schema `feature_entitlements` columns and enforcement-contract comment, `usage_counters.ceiling_snapshot`, `overage_line_items.ceiling_value`. |
| **Q5** | What are R4 and R5? | **RESOLVED — R4: masters, not enums. R5: `custom_attributes jsonb` on core entities from day one.** Both are now first-class rules rather than a noted gap. | [§1](#1-the-rules-this-phase-must-satisfy) rules table; new [§9](#9-extensibility-master-data-r4-and-custom-fields-r5); schema §0.3 (the R5 convention) and §5 (four master tables, seeding function, RLS policies). |
| **Q16** | Does a user ever belong to more than one tenant? | **RESOLVED — no. Users are strictly single-tenant.** There are no cross-tenant user records; each subdomain maps to exactly one tenant's identity space. This confirms the assumption already baked into the schema, so nothing was restructured — `users.tenant_id` stays a hard scope, the session/subdomain equality check stays a simple comparison, and no `tenant_memberships` join is coming. | Schema `users` comment upgraded from `[OPEN]` to `[DECIDED]` with the consequences spelled out; assumption A14 promoted to a decision. |

### 11.2 Still open — worth answering before Phase 1 ships

| # | Question | Why it matters |
|---|---|---|
| Q2 | **Exact default RBAC role list.** Proposed: `owner`, `admin`, `manager`, `member`, `read_only`. Which map to "executive" (`requires_2fa = true`)? Currently `owner` and `admin`; is `manager` in or out? | Seeded into every new tenant; changing it later means migrating existing tenants. |
| Q6 | **Which permissions exist in the Phase 0 catalogue?** The schema seeds a starting set. | Tenants compose roles from this vocabulary; gaps block real workflows. |

### 11.3 Follow-ups raised by the resolutions above

These did not exist before the R4/R5 round — they are **consequences of the answers**, not
leftovers from them. Four have since been actioned; one remains open and one is scheduled.

| # | Question | Status |
|---|---|---|
| Q17 | Do deals reuse `lead_stages` / `lead_loss_reasons`, or get their own masters? | **RESOLVED — separate masters.** `deal_stages` and `deal_loss_reasons` now exist alongside the lead masters ([§9.1](#91-r4--master-tables-not-enums), schema §5.5–5.6). A lead stage and a deal stage are structurally identical and semantically different: sharing one list would force one team's pipeline edits onto the other's reporting, and the two lists diverge the first time anyone customises either. Separate tables cost four near-identical DDL blocks and buy independent vocabularies. |
| Q18 | Confirm the seeded default master values, and whether any should differ by industry vertical. | **Still open.** Deliberately low-stakes: unlike the RBAC defaults, a wrong default here is a tenant-editable row, so correcting it is a rename rather than a migration. That asymmetry is most of the point of R4. |
| Q19 | The S3 audit-archive job: storage class, lifecycle transitions, archive format, retention floor, and where the job runs. | **Partly resolved; the urgent half is done.** Twelve months of `audit_events` partitions are now pre-created through 2027-09 ([§8.3](#83-retention--decided-12-months-hot-then-s3)), which removes the one-month failure cliff — inserts can no longer fall off the end of the declared range while the job is unwritten. The *archive* half (dump to S3, verify, drop) remains a Phase 2 build, and the format/storage-class/retention-floor questions stay open with it. |
| Q20 | When to add a GIN index on `custom_attributes` (and `audit_events.payload`), and on which tables. | **DEFERRED TO PHASE 2 — scheduled, not open.** It is not a question anyone can answer today: a GIN index is paid on every write to serve reads nobody has issued, and the right index is often a narrower expression index on the two or three keys actually filtered on. Phase 2 is where the business objects have been live long enough to produce slow-query data. Documented as deferred in the schema (§0.3, §6) rather than left as a lingering "maybe". |
| Q21 | The per-tenant custom-field definition registry — which keys exist, their types, whether they are required, how the UI renders them. | **DEFERRED TO PHASE 2 — scheduled, not open.** R5 stores the values; this registry is what types and validates them. Designing it before Phase 1's business objects exist would mean guessing at its own shape. Documented as deferred in the schema (§0.3). |

The distinction between **open** and **deferred** in that table is load-bearing and worth
keeping: an open item is waiting on a decision someone could make today, and a deferred item
is waiting on *information that does not exist yet*. Chasing the second kind early produces
confident guesses, which are worse than an empty slot because they get built on.

### 11.4 Deferred — decide before GA

| # | Question |
|---|---|
| Q7 | Exact AWS compute target: ECS Fargate vs. Amplify Hosting vs. something else. |
| Q8 | RDS PostgreSQL vs. Aurora PostgreSQL. |
| Q9 | Migration tooling choice (Drizzle Kit / node-pg-migrate / other), and how RLS policies are represented in it. |
| Q10 | Subdomain→tenant cache: which cache, what TTL, and how the pre-tenant-context lookup is scoped so it does not become a general-purpose god-mode connection ([§4.2](#42-the-lookup-cost)). |
| Q11 | S3 per-tenant isolation strategy — object storage has no RLS, so this is application-enforced and needs its own design. |
| Q12 | Usage accounting: counters-only (assumed) vs. a raw usage-events stream with rollups ([§7.3](#73-usage-accounting)). |
| Q13 | Billing provider integration (Stripe assumed but not decided) and how overage line items are pushed to it. |
| Q14 | Custom vanity domains (`crm.company.com`) — out of scope for Phase 0, but affects cookie and cert strategy ([§4.3](#43-cookies)). |
| Q15 | Tenant offboarding/deletion routine — ordered multi-table teardown ([§3.1](#31-why-pooled-and-what-we-are-accepting)). |

*(Q1, Q3, Q4, Q5 and Q16 are resolved — see [§11.1](#111-resolved). Numbers are not reused.)*

### 11.5 Assumptions made in this note

Still assumptions:

`A1` Next.js App Router, single deployable, no separate API service ([§2.1](#21-application-shape)) ·
`A2` RDS PostgreSQL 16+, Multi-AZ ([§2.2](#22-persistence)) ·
`A3` PgBouncer/RDS Proxy in transaction pooling mode ([§2.2](#22-persistence)) ·
`A4` All AWS service selections in [§2.3](#23-where-aws-fits) *(except the audit archive target, now decided)* ·
`A5` Session cookies scoped per-subdomain, not parent-domain ([§4.3](#43-cookies)) ·
`A7` Server-side session records rather than stateless JWTs ([§6.1](#61-sessions)) ·
`A8` TOTP as the Phase 0 second factor; SMS excluded; WebAuthn not precluded ([§6.2](#62-two-factor-authentication)) ·
`A9` Default role list ([§5](#5-rbac-r2)) ·
`A10` `resource.action` permission naming ([§5](#5-rbac-r2)) ·
`A11` Union (not deny-precedence) semantics for multi-role permissions ([§5](#5-rbac-r2)) ·
`A12` Counter-based usage accounting ([§7.3](#73-usage-accounting)) ·
`A16` Four separate typed master tables rather than one generic list table ([§9.1](#91-r4--master-tables-not-enums)) ·
`A17` The set of Phase 0 tables that carry `custom_attributes`, and the exclusions ([§9.2](#92-r5--custom-fields-from-day-one))

Promoted to decisions this round:

`A6` → **DECIDED.** Absolute 24h session expiry, now trigger-enforced (Q3) ·
`A13` → **DECIDED.** Monthly partitioning of `audit_events`; it is now the mechanism the
retention policy runs on, not just a structural hedge (Q1) ·
`A14` → **DECIDED.** One user belongs to exactly one tenant (Q16) ·
`A15` → **DECIDED.** The `sessions` table is part of the design, required by the 24-hour
session rule.

---

## 12. Verification status of the companion schema

`schema-phase-0.sql` was not just written — it was executed against a real PostgreSQL 16
instance and its properties were asserted, not assumed. **Re-run in full after this round of
changes**, as the app role (`crm_app`: not superuser, no `BYPASSRLS`, not the table owner),
with two tenants provisioned end to end. What was confirmed:

| Check | Result |
|---|---|
| Full DDL applies cleanly (`ON_ERROR_STOP=1`) | Pass — 18 tables |
| R1 conformance lint ([§10](#10-r1-enforcement)) returns zero violations | Pass — 18/18 have `NOT NULL tenant_id` + RLS enabled + forced + policy, no new exceptions |
| **R4** — zero `ENUM` types exist in the schema | Pass — 0 |
| **R4** — master data seeds per tenant at provisioning | Pass — 10 sources / 7 statuses / 6 stages / 8 loss reasons, per tenant |
| **R4** — master tables are tenant-isolated | Pass — tenant A sees 6 stage rows, all its own |
| **R4** — tenant A renames a status and deactivates a source; tenant B is unaffected | Pass — B still reads its own label and its own `is_active` |
| **R4** — cross-tenant `INSERT` into a master table rejected | Pass — RLS policy violation raised |
| **R5** — `custom_attributes` present and `NOT NULL` on the 6 intended tables | Pass — `tenants`, `users`, 4 masters |
| **R5** — object accepted, non-object rejected | Pass — scalar jsonb rejected by the `CHECK` |
| **150% ceiling** — generated correctly | Pass — 10,000 → 15,000; 1,000,000 → 1,500,000 |
| **150% ceiling** — NULL (no ceiling) for unlimited and for hard-capped features | Pass |
| **Sessions** — lifetime is exactly 24h, `last_seen_at` update succeeds | Pass — `1 day` |
| **Sessions** — extending `expires_at` is refused | Pass — trigger raises; revocation still succeeds |
| `audit_events` routes to the correct monthly partition | Pass — Oct event → `audit_events_2026_10` |
| `crm_app` cannot `UPDATE`/`DELETE` audit rows (append-only via grants) | Pass — permission denied |
| **No** tenant context set → zero rows, not all rows (fail-closed) | Pass |
| Full cross-tenant sweep: context A returns zero B rows on every table | Pass |
| Tenant signup + full provisioning works without any RLS bypass | Pass |

Findings that came out of running it rather than reading it, all now fixed in the schema:

1. **The lint caught a real defect on its first run** (first pass). `tenants.tenant_id` is a
   generated column (`GENERATED ALWAYS AS (id) STORED`), and PostgreSQL does **not** infer
   `NOT NULL` for a generated column even when the expression can never be null. The table
   therefore failed R1's own conformance check until `NOT NULL` was stated explicitly. A good
   sign for the lint: it found something a schema review would plausibly have waved through.
2. **Tenant creation needs no privileged bypass** (first pass). Generating the UUID
   application-side and setting the context to it before the insert satisfies the policy's
   `WITH CHECK`. Worth protecting deliberately — a bypass added "just for provisioning" is
   the usual first leak in a design like this.
3. **The first version of the 150% ceiling was a trap for the caller** (this pass). It
   carried a `CHECK (soft_stop OR overage_ceiling_pct = 100)` to express "a hard cap has no
   headroom above the limit". That constraint is correct in spirit and wrong in practice: the
   column defaults to 150, so **every hard-capped entitlement failed to insert** unless the
   caller redundantly restated `overage_ceiling_pct = 100`. A constraint that rejects its own
   column's default is a bug generator. Fixed by moving the semantics into the generated
   column instead — `overage_ceiling_value` is NULL when `soft_stop` is false, which reads
   correctly as "no ceiling applies; this blocks at the limit" — and dropping the `CHECK`.
   Worth recording because it is the general lesson: express a rule where it costs the caller
   nothing to obey.

---

## 13. What Phase 1 should pick up first

1. The **R1/RLS CI lint** ([§10](#10-r1-enforcement)) — before there are many tables to
   retrofit. It should also assert **zero `ENUM` types** in the application schema, which is
   R4 made mechanical rather than remembered.
2. The **data-access layer** with the `SET LOCAL` choke point ([§3.3](#33-how-rls-is-actually-enforced-per-request))
   — before any feature code establishes a habit of bypassing it.
3. The **cross-tenant isolation integration test** ([§10](#10-r1-enforcement)).
4. The **CRM business objects** (`contacts`, `companies`, `leads`, `deals`, `activities`),
   each created with `custom_attributes` per R5 ([§9.2](#92-r5--custom-fields-from-day-one))
   and referencing the R4 masters through composite, `ON DELETE RESTRICT` foreign keys
   ([§9.1](#91-r4--master-tables-not-enums)). Getting this right in the DDL that creates the
   tables is far cheaper than retrofitting it afterwards — which is the entire reason both
   patterns were fixed in Phase 0.
5. The **entitlement guard** implementing the enforcement order in the `feature_entitlements`
   table comment, including the 150% hard block and the notifications that make it defensible
   ([§7.2](#72-the-150-ceiling)).
6. An answer to **Q2** (default roles) and **Q6** (permission catalogue) — the two remaining
   items that are expensive to change once tenants exist, because both are seeded per tenant.

Not Phase 1, but do not lose it: the **audit archive job** ([§8.3](#83-retention--decided-12-months-hot-then-s3)).
The retention policy is decided, and thirteen monthly partitions are now pre-created through
**2027-09**, which buys the runway — the original one-month cliff, where inserts would start
failing the moment `occurred_at` ran past the last declared partition, is gone. What does not
exist is the job that creates *further* partitions ahead of time and exports-then-drops the
aging ones. Two dates to hold: the export half is not needed until roughly twelve months
after first production write, but **the partition-creation half must be running well before
2027-09**, and a pre-created runway is exactly the kind of cushion that gets silently consumed
because nothing complains until it is empty. Monitor partition coverage as a metric, not the
job's exit code.

---

## 14. Phase 0 status (2026-09-12): reopened for BMexa security gate

**This is a revision record, not a rewrite of §12.** The verification table in
[§12](#12-verification-status-of-the-companion-schema) is preserved exactly as it was executed
and remains a true historical record: Phase 0's original acceptance test — the R1/R2/R3 suite
plus the session-context tests, 27 tests in total — **passed**, against a real PostgreSQL 16
instance, with two really-provisioned tenants. That fact is not erased or qualified away by
this section.

However, [`docs/BMEXA_MASTER_SPEC.md`](../BMEXA_MASTER_SPEC.md) §77's Phase 0 Gate imposes an
additional, stricter criterion that the original 27-test suite did not specifically exercise:

> "(3) Server-side authorization cannot be bypassed through manipulated request payloads."

The original suite proves tenant isolation holds under *normal* request shapes — correct
tokens, correct tenant context, no adversary in the loop. It does not include tests that
actively attempt to defeat that isolation with a manipulated payload: a spoofed `tenant_id` in
the body, query string, or path; a cross-tenant record ID substituted into an otherwise valid
request; an altered ownership/user ID field; or a scope-widening attempt against either a read
or a mutation. This is a real gap between "passed the test it was given" and "passed the gate
BMexa now requires," not a defect discovered in the passing suite itself.

**Per explicit project-owner decision, Phase 0 is therefore REOPENED — BMEXA SECURITY GATE
PENDING.** Phase 0 is not, and must not be described as, BMexa-complete at this time. It closes
again only once adversarial tenant-boundary tests covering BMexa §77 criterion 3 — tracked
separately as Beads issue `Final-Verison-j75` — are written and passing, alongside the
existing 27 tests, unweakened.
