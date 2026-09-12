-- =============================================================================
-- Phase 0 — Platform Foundation Schema
-- CRM platform: pooled multi-tenant PostgreSQL with Row-Level Security
--
-- Companion document: ./00-phase-0-architecture-note.md
-- Beads issue:        Final-Verison-c86
-- Target:             PostgreSQL 14+ (16 assumed; see architecture note §2.2)
--
-- -----------------------------------------------------------------------------
-- RULES THIS FILE IMPLEMENTS
--   R1  Every single table carries a tenant_id column.  NON-NEGOTIABLE.
--   R2  RBAC uses flexible default roles — defaults ship, tenants define more.
--   R3  Entitlements are soft-stop — overage billing to a 150% ceiling, then a
--       hard block.
--   R4  Sources, stages, statuses and reasons are ROWS IN MASTER TABLES, never
--       database ENUM types.
--   R5  Core entities carry custom_attributes jsonb from day one.
--   R6  Audit log is event-based, append-only, 12 months hot, then archived to
--       S3 cold storage and the partition dropped.
--
-- -----------------------------------------------------------------------------
-- HOW TO READ THE COMMENTS
--   [DECIDED]     Settled. Downstream work should not relitigate.
--   [JUDGMENT]    A call made here beyond what the brief specified. Reviewable.
--   [RESOLVED]    Was open in the first pass; answered by the project owner and
--                 integrated here. See the architecture note §11.1.
--   [OPEN]        Explicitly unresolved. See the architecture note §11.
-- =============================================================================


-- =============================================================================
-- 0. EXTENSIONS AND HELPERS
-- =============================================================================

-- gen_random_uuid() is built into PostgreSQL 13+ core. On 12 and below it comes
-- from pgcrypto. We create the extension unconditionally so the file is portable;
-- on 13+ it is harmless. The alternative, uuid_generate_v4(), requires
-- "uuid-ossp" and is not preferred — it is a third-party extension providing a
-- function core now ships natively.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- [JUDGMENT] UUID v4 primary keys everywhere rather than bigserial.
--   Why: tenant-scoped data eventually gets exported, merged, and referenced
--   across systems (a CRM integrates with everything). Sequential integers leak
--   volume ("we are customer #47") and make cross-tenant ID collisions during
--   imports/merges a live hazard.
--   Cost accepted: v4 UUIDs are random, so index locality on inserts is poor.
--   If insert throughput on the hot tables becomes a problem, the migration is
--   to UUIDv7 (time-ordered) — same type, same width, no schema change.
--   [OPEN] Revisit UUIDv7 before GA.


-- -----------------------------------------------------------------------------
-- 0.1 The tenant-context accessor — the heart of tenant isolation
-- -----------------------------------------------------------------------------
-- Every RLS policy in this file is expressed in terms of this one function.
--
-- [DECIDED] It MUST fail closed. Three properties make that true:
--   1. current_setting(..., true) — the second argument `missing_ok` makes it
--      return NULL instead of raising when the GUC has never been set in this
--      session. Without it, any query that forgot to establish tenant context
--      would raise a confusing error; with it, we get a clean NULL we can turn
--      into "matches nothing".
--   2. NULLIF(..., '') — a GUC reset to the empty string would otherwise blow up
--      on the ::uuid cast. Empty is treated as "no context".
--   3. The policies compare `tenant_id = app_current_tenant_id()`. When the
--      function returns NULL, that comparison is NULL, which is not TRUE, so the
--      policy matches ZERO rows.
--
-- The failure mode of a forgotten SET LOCAL is therefore "no data" — never
-- "everyone's data". That asymmetry is the entire point of this design.
CREATE OR REPLACE FUNCTION app_current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
$$;

COMMENT ON FUNCTION app_current_tenant_id() IS
'Returns the tenant_id for the current request, set by the data-access layer as
 SET LOCAL app.current_tenant_id = ''<uuid>'' at the start of every transaction.
 Returns NULL when unset, which causes every RLS policy to match zero rows.
 SET LOCAL (not SET) is required: it is scoped to the transaction and reverted on
 commit/rollback, so the value cannot leak to the next request that borrows the
 same pooled connection under transaction-mode pooling.';


-- -----------------------------------------------------------------------------
-- 0.2 updated_at maintenance
-- -----------------------------------------------------------------------------
-- [JUDGMENT] Maintain updated_at in a trigger rather than in application code.
-- Application-maintained timestamps are wrong the first time anyone writes a
-- backfill script or a manual correction.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


-- -----------------------------------------------------------------------------
-- 0.3 The custom_attributes convention  (Rule R5 — custom fields from day one)
-- -----------------------------------------------------------------------------
-- [DECIDED, R5] Every CORE ENTITY carries:
--
--     custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb
--         CHECK (jsonb_typeof(custom_attributes) = 'object')
--
-- WHY IT IS HERE ON DAY ONE, not added when someone asks:
--   Every CRM customer wants fields we did not ship. In a pooled multi-tenant
--   schema the alternatives are all worse: a per-tenant ALTER TABLE (breaks the
--   "one schema, one migration" property that justified pooling in the first
--   place — see architecture note §3.1), or an Entity-Attribute-Value side table
--   (a join per field, and every query becomes a pivot). A jsonb column costs
--   nothing until used, and retrofitting one onto a large table later means a
--   table rewrite or a slow backfill.
--
-- WHAT WE ARE PAYING FOR IT, stated plainly:
--   * The data is UNTYPED. Nothing stops '{"close_date": "not a date"}'.
--     Validation is the application's job, driven by a per-tenant field-
--     definition registry — a custom_field_definitions table describing which
--     keys exist, their types, and whether they are required.
--     [DEFERRED TO PHASE 2 — Q21] That registry is NOT created here and is NOT a
--     Phase 1 deliverable. It describes and validates values attached to CRM
--     business objects, and those objects do not exist until Phase 1 ships;
--     designing the registry before there is anything to attach fields to is
--     guessing at its own shape. Phase 2 is the scheduled build. Until then,
--     custom_attributes is validated by the application against nothing, which
--     is a known and accepted Phase 1 gap — not an oversight. See architecture
--     note §11.4.
--   * The data is UNINDEXED by default. A filter on a custom attribute is a
--     sequential scan until an index exists.
--   * It is a dumping ground unless governed. The rule that keeps it honest:
--     anything the PRODUCT reasons about gets a real column; custom_attributes
--     is for what the TENANT reasons about.
--
-- THE STANDARD MITIGATION, deliberately not applied yet:
--   CREATE INDEX <t>_custom_attributes_gin
--       ON <t> USING gin (custom_attributes jsonb_path_ops);
--   jsonb_path_ops is smaller and faster than the default operator class for
--   the containment (@>) queries this actually serves; it does not support key-
--   existence (?) operators, which is the trade.
--   [DEFERRED TO PHASE 2 — Q20] NOT created in Phase 0. A GIN index is paid on
--   every write to serve reads nobody has issued yet, and the right target is
--   usually a narrow expression index on the two or three keys a tenant actually
--   filters by — which cannot be known before real query patterns exist. Phase 2
--   is the scheduled revisit, because by then the Phase 1 business objects have
--   produced slow-query data to point at. See architecture note §11.4.
--
-- WHICH TABLES GET IT, and why the others do not:
--   YES — tenants (tenant-level settings/config), users (per-user profile
--         extensions), and every R4 master table (per-tenant metadata on a
--         lookup value: a UI colour, an external system's code).
--   NO  — join tables (role_permissions, user_roles: they model a relationship,
--         not an entity), permissions (a fixed vocabulary WE define, not the
--         tenant), sessions / user_mfa_methods / user_recovery_codes (a security
--         surface; arbitrary tenant-writable data does not belong beside
--         credential material), feature_entitlements / usage_counters /
--         overage_line_items (billing artifacts must stay typed and auditable —
--         a money value in a jsonb blob is a revenue incident waiting to
--         happen), and audit_events (its payload column is already this, and it
--         is immutable by design).
--
-- [DECIDED] MANDATORY FOR THE NEXT PHASE. Phase 0 contains NO CRM business
--   objects — contacts, companies, leads, deals, activities and notes all
--   arrive in Phase 1. Every one of them MUST be created with this column and
--   this CHECK. That is where the rule actually earns its keep; the Phase 0
--   applications below exist to establish the pattern so it is copied rather
--   than re-derived.


-- =============================================================================
-- 1. TENANTS
-- =============================================================================
-- The root of every ownership chain. One row per customer workspace.

CREATE TABLE tenants (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- [JUDGMENT] R1 says *every* table carries tenant_id. The obvious reading is
    -- that `tenants` is exempt because it cannot reference itself. Instead of
    -- carving out an exception, tenant_id here is a STORED generated column that
    -- always equals id.
    --   Why bother: it means R1 has ZERO exceptions, so the CI lint described in
    --   the architecture note §10 is a flat "every table in this schema has a
    --   non-null tenant_id column with an RLS policy on it" — no allowlist to
    --   maintain, and therefore no allowlist for someone to quietly add to. It
    --   also lets the isolation policy below be *literally identical* to every
    --   other table's, which matters because a policy that is copy-pasted
    --   identically 15 times is easier to audit than 14 identical ones plus a
    --   special case.
    --   Cost: one redundant 16-byte column per tenant row. Negligible.
    --
    --   The explicit NOT NULL is load-bearing and easy to omit: PostgreSQL does
    --   NOT infer NOT NULL for a generated column, even when the expression can
    --   never produce NULL (id is the primary key). Without it this table fails
    --   the R1 conformance lint in §7 — which is how this was caught.
    tenant_id      uuid GENERATED ALWAYS AS (id) STORED NOT NULL,

    -- Routing key. `company` in company.yourcrm.com.
    -- Stored lowercase and constrained to a DNS-label-safe charset because it
    -- becomes part of a hostname. Length capped at 63 (the DNS label limit) and
    -- floored at 3 to keep the short, valuable labels available.
    subdomain      text NOT NULL,

    name           text NOT NULL,

    -- [JUDGMENT] status as a CHECK-constrained text column rather than a native
    -- ENUM type. Adding a value to a Postgres ENUM is easy; removing or
    -- reordering one is not, and ENUM changes historically could not run inside
    -- a transaction with other DDL. CHECK constraints are trivially altered in a
    -- migration. Same choice is made for every status-like column in this file.
    --   provisioning — created, not yet usable
    --   active       — normal operation
    --   suspended    — non-payment or policy; routing rejects, data retained
    --   deactivated  — customer left; retained pending the deletion routine
    status         text NOT NULL DEFAULT 'provisioning'
                     CHECK (status IN ('provisioning','active','suspended','deactivated')),

    -- [R5] Tenant-level settings and per-tenant configuration that does not
    -- warrant a column: branding preferences, feature toggles a CSM flips,
    -- locale/formatting defaults, integration-specific identifiers. See §0.3 for
    -- the convention and its costs.
    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    -- Soft-delete marker. Hard deletion of a tenant is an ordered multi-table
    -- teardown, not a single DELETE. [OPEN] That routine is not designed yet
    -- (architecture note Q15).
    deleted_at     timestamptz,

    CONSTRAINT tenants_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object'),

    CONSTRAINT tenants_subdomain_format CHECK (
        subdomain ~ '^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$'
    )
);

-- Unique and case-insensitive by construction (the CHECK forbids uppercase), so
-- a plain unique index is sufficient and is directly usable by the routing
-- lookup in middleware.
CREATE UNIQUE INDEX tenants_subdomain_key ON tenants (subdomain);

-- Routing middleware reads (subdomain -> id, status) on every request.
-- Covering index so the lookup is index-only.
CREATE INDEX tenants_routing_idx ON tenants (subdomain) INCLUDE (id, status)
    WHERE deleted_at IS NULL;

CREATE TRIGGER tenants_set_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Tenant CREATION under RLS, verified against PostgreSQL 16:
--   Because tenant_id is generated from id, the WITH CHECK on the isolation
--   policy is satisfiable by generating the UUID in the application and setting
--   the context to it before inserting:
--       BEGIN;
--       SET LOCAL app.current_tenant_id = '<new uuid>';
--       INSERT INTO tenants (id, subdomain, name) VALUES ('<same uuid>', ...);
--       SELECT provision_tenant_rbac_defaults('<same uuid>');   -- R2, §9.1
--       SELECT provision_tenant_master_data('<same uuid>');     -- R4, §9.2
--       COMMIT;
--   This means signup needs NO RLS bypass and no privileged escape hatch — which
--   is worth protecting, since a bypass added "just for provisioning" is how
--   these designs usually spring their first leak.
COMMENT ON TABLE tenants IS
'Root tenancy table. Reserved subdomains (www, api, app, admin, static, assets,
 mail, ...) must be rejected at signup by the application — this schema does not
 encode that list because it will change more often than the schema does.
 [OPEN] Where the reserved list lives is undecided.';


-- =============================================================================
-- 2. SUBSCRIPTIONS, ENTITLEMENTS AND USAGE  (Rule R3 — soft-stop limits)
-- =============================================================================
--
-- [JUDGMENT] There is deliberately NO global `plans` catalogue table.
--   R1 requires tenant_id on every table, and a shared plan catalogue is by
--   definition not tenant-scoped. The two ways to keep a global catalogue would
--   be (a) exempt it from R1, or (b) invent a sentinel "system tenant" whose
--   rows every tenant can also read — which forces every RLS policy to become
--   "my tenant OR the system tenant", weakening the single most important
--   invariant in the design for the sake of a lookup table.
--   Neither is worth it. Instead: plan *templates* live in application code /
--   seed data, and provisioning MATERIALISES them into per-tenant entitlement
--   rows. Per-tenant rows are needed anyway, because sales will negotiate
--   custom limits and the alternative is a bespoke plan tier per customer.
--   Cost accepted: changing a plan template does not retroactively change
--   existing tenants — a backfill migration is required. That is arguably the
--   correct behaviour for a billing-relevant value.

CREATE TABLE subscriptions (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    plan_tier                text NOT NULL
                               CHECK (plan_tier IN ('free','starter','professional','enterprise')),

    status                   text NOT NULL DEFAULT 'trialing'
                               CHECK (status IN ('trialing','active','past_due','canceled')),

    -- Billing period. Overage is computed and invoiced per period, so these
    -- bounds are the join key for usage_counters.
    current_period_start     timestamptz NOT NULL,
    current_period_end       timestamptz NOT NULL,

    -- [DECIDED, R3] Master switch for soft-stop behaviour. Per-feature soft_stop
    -- in feature_entitlements decides *whether a given limit* is soft; this flag
    -- decides whether this tenant is permitted to accrue billable overage at all.
    -- A tenant on a prepaid/PO arrangement with no payment method on file must
    -- not silently accrue charges, so for them this is false and every limit
    -- behaves as a hard cap regardless of its own soft_stop value.
    overage_billing_enabled  boolean NOT NULL DEFAULT true,

    -- References into the billing provider. [OPEN] Stripe is assumed but not
    -- decided (architecture note Q13). Deliberately untyped text so swapping the
    -- provider is a data migration, not a schema migration.
    external_customer_id     text,
    external_subscription_id text,

    trial_ends_at            timestamptz,
    canceled_at              timestamptz,

    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT subscriptions_period_valid CHECK (current_period_end > current_period_start)
);

-- [JUDGMENT] One active subscription per tenant, enforced as a partial unique
-- index rather than a plain unique on tenant_id. Cancelled/superseded rows are
-- retained for billing history, so tenant_id is not globally unique here — but
-- "two simultaneously active subscriptions" is a state that would make
-- entitlement resolution ambiguous, and ambiguity in entitlement resolution
-- becomes a revenue bug.
CREATE UNIQUE INDEX subscriptions_one_active_per_tenant
    ON subscriptions (tenant_id)
    WHERE status IN ('trialing','active','past_due');

CREATE INDEX subscriptions_tenant_idx ON subscriptions (tenant_id);

-- Composite unique key enabling tenant-safe composite foreign keys from child
-- tables. See the note on feature_entitlements below.
ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_tenant_id_id_key
    UNIQUE (tenant_id, id);

CREATE TRIGGER subscriptions_set_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 2.1 Feature entitlements — the soft-stop limit definitions (R3)
-- -----------------------------------------------------------------------------
-- One row per (tenant, feature). Handles three shapes of entitlement with one
-- table:
--   * boolean feature flag       -> is_enabled, limit_value NULL
--   * unlimited metered feature  -> is_enabled, is_unlimited = true
--   * limited metered feature    -> is_enabled, limit_value set, soft_stop set
--
-- [JUDGMENT] One table for flags and limits rather than two. A "feature" and a
-- "limit" are the same question asked twice ("may they, and how much"), and
-- splitting them means every entitlement check has to consult two tables and
-- reconcile disagreements between them.

CREATE TABLE feature_entitlements (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    subscription_id       uuid NOT NULL,

    -- Stable machine key, e.g. 'seats', 'contacts', 'api_calls_per_month',
    -- 'custom_roles', 'api_access'. Application-owned vocabulary; not enumerated
    -- in the schema because it grows with every feature shipped.
    feature_key           text NOT NULL,

    is_enabled            boolean NOT NULL DEFAULT true,

    -- NULL means "not a metered feature" (a pure on/off flag).
    -- is_unlimited = true means metered-but-uncapped; limit_value must be NULL.
    limit_value           bigint,
    is_unlimited          boolean NOT NULL DEFAULT false,

    -- How limit_value is counted. Drives which accounting model applies:
    --   'stock' -> point-in-time count (seats, contacts). "How many exist now."
    --   'flow'  -> accumulates within the billing period (api_calls). Resets.
    -- [JUDGMENT] Making this explicit in the schema, rather than implied by the
    -- feature_key, is what stops someone from serving a flow limit with a live
    -- COUNT(*) or resetting a stock limit at period rollover. Conflating the two
    -- is the classic metering bug.
    metering_model        text NOT NULL DEFAULT 'stock'
                            CHECK (metering_model IN ('stock','flow')),

    -- [DECIDED, R3] THE SOFT-STOP SWITCH.
    --   true  -> exceed the limit: ALLOW the action, meter the excess, bill it.
    --   false -> exceed the limit: REJECT with an upgrade path.
    -- R3 makes true the default. false exists for limits with an unbounded cost
    -- tail (outbound email volume, raw storage) where "we'll invoice you" is not
    -- a real answer at 100x the plan.
    soft_stop             boolean NOT NULL DEFAULT true,

    -- Price per overage unit, in minor units (cents) to avoid float money.
    -- numeric(12,4) rather than integer because per-unit prices are frequently
    -- fractional cents (e.g. $0.0004 per API call) and rounding at the unit level
    -- rather than the invoice level produces visibly wrong totals at volume.
    overage_unit_price    numeric(12,4),
    overage_unit_currency char(3) NOT NULL DEFAULT 'USD',

    -- How many units of usage constitute one billable overage unit. Lets us bill
    -- API calls per 1,000 without storing a fractional price per call.
    overage_unit_size     bigint NOT NULL DEFAULT 1 CHECK (overage_unit_size > 0),

    -- ---- THE OVERAGE CEILING (R3) -------------------------------------------
    -- [DECIDED] Soft stop is bounded at 150% of the plan limit.
    --   0%   .. 100% of limit_value -> normal usage, no charge beyond the plan.
    --   100% .. 150% of limit_value -> ALLOWED, metered, billed as overage.
    --   above 150% of limit_value   -> HARD BLOCK, with an upgrade path.
    --
    -- Why a ceiling exists at all: an unbounded soft limit is a runaway invoice.
    -- A looping integration can bill a customer thousands of dollars overnight,
    -- and that outcome is a refund and a lost account, not revenue. "We told
    -- them in the banner" is not a defence anyone wants to make.
    --
    -- Why a PERCENTAGE rather than an absolute unit count: the ceiling has to
    -- stay correct when the tenant upgrades. An absolute ceiling of 15,000
    -- contacts set against a 10,000-contact plan becomes a hard block BELOW the
    -- plan limit the moment the tenant moves to a 25,000 plan — the failure mode
    -- being that a customer who just paid us more money gets blocked. A ratio
    -- rescales with limit_value automatically and cannot develop that skew.
    --
    -- NOT NULL with a default: there is no "no ceiling" state to forget to fill
    -- in. An uncapped soft limit is unrepresentable. Unlimited features are
    -- expressed as is_unlimited/limit_value IS NULL, which makes the generated
    -- ceiling below NULL — genuinely uncapped, but only via an explicit,
    -- deliberate configuration rather than an omission.
    overage_ceiling_pct   integer NOT NULL DEFAULT 150
                            CHECK (overage_ceiling_pct >= 100),

    -- The effective ceiling in usage units, derived rather than stored by hand.
    -- [JUDGMENT] A generated column, so the hot-path entitlement check is one
    -- plain comparison (used_value >= overage_ceiling_value) instead of
    -- arithmetic the caller could get wrong or forget. Two callers computing
    -- limit * pct / 100 slightly differently is exactly how a billing bug is
    -- born.
    -- NULL means "no ceiling applies", which happens in exactly two cases, both
    -- correct:
    --   * limit_value IS NULL — unlimited or flag-only features have nothing to
    --     be a percentage of.
    --   * soft_stop = false — a hard cap already blocks at limit_value, so
    --     headroom above it is meaningless. Encoding that here rather than as a
    --     CHECK on overage_ceiling_pct is deliberate: a CHECK would force every
    --     hard-capped row to redundantly restate pct = 100 and would reject the
    --     column's own default, which is a trap for the caller rather than a
    --     safeguard. (Found by executing this file — see architecture note §12.)
    overage_ceiling_value bigint
                            GENERATED ALWAYS AS (
                                CASE WHEN soft_stop
                                     THEN (limit_value * overage_ceiling_pct) / 100
                                END
                            ) STORED,

    -- Provenance: did this come from the plan template or from a negotiated
    -- override? Overrides must survive plan-template backfills.
    source                text NOT NULL DEFAULT 'plan_template'
                            CHECK (source IN ('plan_template','tenant_override')),

    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),

    -- Tenant-safe composite FK: a tenant's entitlement can only ever point at
    -- that same tenant's subscription. A plain FK to subscriptions(id) would
    -- permit a cross-tenant reference if application code ever passed the wrong
    -- id; this makes that state unrepresentable in the database.
    -- [JUDGMENT] This pattern is applied to every child relation in the file.
    -- It costs an extra unique index per parent and removes an entire class of
    -- cross-tenant data leak that RLS alone does not catch (RLS filters what you
    -- can SEE; it does not stop you writing a row that points somewhere else).
    CONSTRAINT feature_entitlements_subscription_fk
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES subscriptions (tenant_id, id) ON DELETE CASCADE,

    CONSTRAINT feature_entitlements_unlimited_has_no_limit
        CHECK (NOT (is_unlimited AND limit_value IS NOT NULL)),

    -- If a limit is soft, we must know what to charge for exceeding it.
    -- Without this constraint, a misconfigured row silently gives away unlimited
    -- usage for free — the failure is invisible until the revenue report.
    CONSTRAINT feature_entitlements_soft_stop_needs_price
        CHECK (
            NOT (soft_stop AND limit_value IS NOT NULL)
            OR overage_unit_price IS NOT NULL
        ),

    -- Fat-finger guard. 150 is the policy; 15000 is a typo that would bill a
    -- customer 100x their plan before anything stopped it.
    CONSTRAINT feature_entitlements_ceiling_sane
        CHECK (overage_ceiling_pct <= 1000)
);

-- [R5] Note the absence of custom_attributes on this table. It is a billing
-- artifact: every value it holds must be typed, constrained and auditable, and
-- a money-relevant value living in an untyped jsonb blob is a revenue incident
-- waiting to happen. See §0.3 for the full inclusion/exclusion list.

CREATE UNIQUE INDEX feature_entitlements_tenant_feature_key
    ON feature_entitlements (tenant_id, feature_key);

CREATE TRIGGER feature_entitlements_set_updated_at
    BEFORE UPDATE ON feature_entitlements
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE feature_entitlements IS
'R3 soft-stop limits, bounded at a 150% ceiling. Enforcement contract for the
 data-access layer — this is the ONLY correct order:
   1. resolve the entitlement row for (tenant, feature_key)
   2. if NOT is_enabled                 -> reject (feature not entitled)
   3. if is_unlimited OR limit_value IS NULL -> allow
   4. read current usage from usage_counters
   5. if usage < limit_value            -> ALLOW, no overage
   6. else if NOT soft_stop             -> reject, surface upgrade path
   7. else if NOT subscription.overage_billing_enabled -> reject
   8. else if usage >= overage_ceiling_value -> REJECT (150% hard block)
   9. else                              -> ALLOW, and meter the excess
 Steps 6-8 are the guardrails that keep "soft" from meaning "unbounded". Step 8
 is the decided ceiling: a tenant may consume up to 150% of their plan limit,
 paying overage for the band between 100% and 150%, and is hard-blocked above
 it. The block must name the number in the error surfaced to the user — "you
 have used 150% of your plan limit" is actionable; "limit exceeded" is not.
 The user-facing sequence that makes this defensible is a notification when the
 tenant first crosses 100% (usage_counters.overage_started_at), a persistent
 in-app indicator while in the 100-150% band, and a second warning approaching
 the ceiling. Billing a customer for something they were never told about is a
 refund, not revenue.';


-- -----------------------------------------------------------------------------
-- 2.2 Usage counters — what is actually consumed
-- -----------------------------------------------------------------------------
-- [JUDGMENT] Counters, not a raw usage-event stream, for Phase 0.
--   A raw event stream (one row per API call) is more accurate and more
--   auditable, but it cannot answer "how many this period" at request latency
--   without a rollup job — and the entitlement check is on the hot path of every
--   metered action. Counters answer in one indexed read.
--   Cost accepted: counters can drift (a crashed transaction, a double-decrement
--   on delete). Mitigated by last_reconciled_at plus a periodic job that
--   recomputes stock metrics from COUNT(*) and corrects the counter.
--   [OPEN] Whether to add an event stream underneath for audit is unresolved
--   (architecture note Q12). The shape here does not preclude it.

CREATE TABLE usage_counters (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    subscription_id     uuid NOT NULL,

    -- Matches feature_entitlements.feature_key.
    metric_key          text NOT NULL,

    -- The billing period this counter covers. For 'stock' metrics the counter is
    -- carried forward into each new period (seats do not reset); for 'flow'
    -- metrics a new period starts at zero. The rollover job owns that
    -- distinction and reads metering_model to decide.
    period_start        timestamptz NOT NULL,
    period_end          timestamptz NOT NULL,

    used_value          bigint NOT NULL DEFAULT 0 CHECK (used_value >= 0),

    -- Snapshot of the limit in force when this period opened. Kept so that an
    -- invoice can be reconstructed exactly as it was billed, even after the
    -- tenant upgrades mid-period and the live entitlement row changes.
    -- Denormalisation here is deliberate: billing history must not move.
    limit_snapshot      bigint,

    -- Snapshot of the 150% hard-block ceiling in force when this period opened,
    -- for the same reason as limit_snapshot: a dispute about "why was I blocked
    -- on the 14th" must be answerable from what was true on the 14th, not from
    -- the entitlement row as it stands today.
    ceiling_snapshot    bigint,

    -- Set the first time used_value crosses limit_snapshot — i.e. entry into the
    -- 100-150% billable overage band. Drives the in-app "you are in overage"
    -- banner and the crossing notification, which are the mitigation for billing
    -- a customer for something they did not explicitly opt into at the moment
    -- they did it.
    overage_started_at  timestamptz,

    last_reconciled_at  timestamptz,

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT usage_counters_subscription_fk
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES subscriptions (tenant_id, id) ON DELETE CASCADE,

    CONSTRAINT usage_counters_period_valid CHECK (period_end > period_start)
);

-- The entitlement check's hot-path lookup, and the guard against duplicate
-- counter rows for the same metric and period.
CREATE UNIQUE INDEX usage_counters_tenant_metric_period_key
    ON usage_counters (tenant_id, metric_key, period_start);

-- Finds tenants currently in overage, for billing runs and for the ops dashboard.
CREATE INDEX usage_counters_in_overage_idx
    ON usage_counters (tenant_id, period_start)
    WHERE overage_started_at IS NOT NULL;

CREATE TRIGGER usage_counters_set_updated_at
    BEFORE UPDATE ON usage_counters
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 2.3 Metered overage — the billable output of R3
-- -----------------------------------------------------------------------------
-- One row per (tenant, metric, closed period) once the period is closed and
-- overage computed. This is the handoff artifact to the billing provider.
--
-- [JUDGMENT] A separate table rather than deriving the invoice line directly
-- from usage_counters at billing time. Reason: what we CHARGED must be a
-- recorded fact, not a recomputation. If the entitlement or the price changes
-- later, recomputing would produce a different number than the invoice the
-- customer already received — and reconciling that is a support nightmare.

CREATE TABLE overage_line_items (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    subscription_id     uuid NOT NULL,

    metric_key          text NOT NULL,
    period_start        timestamptz NOT NULL,
    period_end          timestamptz NOT NULL,

    -- All frozen at computation time; see the note above.
    limit_value         bigint  NOT NULL,

    -- The 150% ceiling as it stood when this line was computed. Recording it
    -- makes the invoice self-explanatory ("billed 100-150%, blocked above") and
    -- gives support a defensible answer without re-deriving anything.
    ceiling_value       bigint,

    used_value          bigint  NOT NULL,
    overage_units       bigint  NOT NULL CHECK (overage_units > 0),
    unit_price          numeric(12,4) NOT NULL,
    currency            char(3) NOT NULL DEFAULT 'USD',
    amount_minor        bigint  NOT NULL,

    status              text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','pushed','invoiced','waived','failed')),

    -- Set when the line item has been accepted by the billing provider.
    external_line_item_id text,
    pushed_at             timestamptz,

    -- Support waives overage; we record why rather than deleting the row, so the
    -- audit trail of "we charged, then we didn't" survives.
    waived_reason       text,

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT overage_line_items_subscription_fk
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES subscriptions (tenant_id, id) ON DELETE CASCADE
);

-- Idempotency guard: the billing job must be safely re-runnable. Without this, a
-- retried billing run double-charges.
CREATE UNIQUE INDEX overage_line_items_unique_period
    ON overage_line_items (tenant_id, metric_key, period_start);

CREATE INDEX overage_line_items_pending_idx
    ON overage_line_items (status, period_end)
    WHERE status = 'pending';

CREATE TRIGGER overage_line_items_set_updated_at
    BEFORE UPDATE ON overage_line_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- 3. RBAC  (Rule R2 — flexible default roles)
-- =============================================================================
--
-- The R2 model in one line: PERMISSIONS are a fixed vocabulary we define; ROLES
-- are a flexible composition tenants control.
--
-- [JUDGMENT] The permissions catalogue is tenant-scoped (R1) and therefore
-- SEEDED PER TENANT at provisioning, rather than being one global table.
--   Rejected alternative: a global catalogue exempt from R1, or one owned by a
--   sentinel "system tenant" that every policy must additionally allow. Both
--   weaken the one invariant the whole design rests on, to save ~60 duplicated
--   rows per tenant (a few kilobytes).
--   Unexpected benefit: per-tenant catalogues let us withhold a permission from
--   tenants who have not bought the feature it guards, so entitlements and RBAC
--   compose instead of contradicting each other.
--   Cost accepted: adding a new permission to the product means a backfill
--   across all tenants. That is a well-understood migration, and it is the same
--   cost already accepted for plan templates in §2.

CREATE TABLE roles (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Stable machine key ('admin'), distinct from the display name ('Admin'),
    -- which tenants may rename freely. Application logic keys on `key` only for
    -- system roles; custom roles are always resolved through permissions.
    key           text NOT NULL,
    name          text NOT NULL,
    description   text,

    -- [DECIDED, R2] System roles ship with every tenant and cannot be deleted or
    -- have their key changed. This is what stops a tenant from deleting their
    -- way into a workspace with no administrator — a support incident that is
    -- unrecoverable without manual database surgery.
    -- Tenants who want a variant CLONE a system role and edit the clone.
    is_system     boolean NOT NULL DEFAULT false,

    -- [DECIDED] The 2FA rule is a property of the ROLE, not a hardcoded check
    -- against a role literally named 'executive'.
    --   Why this matters: R2 lets tenants define and rename roles. If the 2FA
    --   requirement were `IF role.key = 'executive'`, a tenant renaming their
    --   executive role, or creating a second executive-equivalent role, would
    --   silently drop the mandatory-2FA requirement — a security control
    --   disabled by a cosmetic edit.
    --   With this flag, "executive" is a capability of a role, and any role a
    --   tenant defines can carry it.
    -- Resolution rule for users holding several roles: STRICTEST WINS — 2FA is
    -- required if ANY held role requires it.
    requires_2fa  boolean NOT NULL DEFAULT false,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX roles_tenant_key_key ON roles (tenant_id, key);
ALTER TABLE roles ADD CONSTRAINT roles_tenant_id_id_key UNIQUE (tenant_id, id);

CREATE TRIGGER roles_set_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE permissions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- [JUDGMENT] Naming convention: resource.action ('contacts.read',
    -- 'billing.manage'). resource and action are stored as separate columns as
    -- well as in `key` so the permission-picker UI can group by resource without
    -- string-splitting, and so a future "grant all actions on this resource"
    -- feature is a simple WHERE rather than a LIKE.
    key          text NOT NULL,
    resource     text NOT NULL,
    action       text NOT NULL,
    description  text,

    -- Permissions that only make sense when a paid feature is entitled. Lets the
    -- provisioning routine seed a catalogue matching what the tenant bought.
    -- NULL = always available.
    requires_feature_key text,

    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT permissions_key_matches_parts CHECK (key = resource || '.' || action)
);

CREATE UNIQUE INDEX permissions_tenant_key_key ON permissions (tenant_id, key);
ALTER TABLE permissions ADD CONSTRAINT permissions_tenant_id_id_key UNIQUE (tenant_id, id);


-- Join: which permissions a role grants.
CREATE TABLE role_permissions (
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    role_id        uuid NOT NULL,
    permission_id  uuid NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (role_id, permission_id),

    -- Composite FKs keep both sides inside the same tenant. Without these, a
    -- bug could grant tenant A's role a reference to tenant B's permission row.
    CONSTRAINT role_permissions_role_fk
        FOREIGN KEY (tenant_id, role_id)
        REFERENCES roles (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT role_permissions_permission_fk
        FOREIGN KEY (tenant_id, permission_id)
        REFERENCES permissions (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX role_permissions_tenant_role_idx ON role_permissions (tenant_id, role_id);

COMMENT ON TABLE role_permissions IS
'Grant-only. There are no deny rows.
 [JUDGMENT] Effective permissions for a user are the UNION of the permissions of
 every role they hold. Deny-precedence models are more expressive but interact
 badly with union semantics and reliably produce "why can''t this user do X"
 support tickets that take an engineer to answer. If explicit denies are ever
 needed, adding them is a deliberate future decision — not an ambiguity to leave
 open now.';


-- =============================================================================
-- 4. USERS, MFA AND SESSIONS
-- =============================================================================

-- [JUDGMENT] Email case-insensitivity is handled with a functional unique index
-- on lower(email) rather than the citext extension. citext works, but it is an
-- extension dependency that must exist in every environment (including RDS
-- parameter-group-restricted ones and local test containers), and a functional
-- index achieves the same guarantee with zero dependencies.
CREATE TABLE users (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    email              text NOT NULL,

    -- Argon2id or bcrypt output, algorithm+params encoded in the string itself
    -- so we can rotate algorithms without a schema change.
    -- Nullable: SSO-provisioned users have no local password. [OPEN] SSO/SAML is
    -- not designed in Phase 0.
    password_hash      text,

    full_name          text,

    status             text NOT NULL DEFAULT 'invited'
                         CHECK (status IN ('invited','active','suspended','deactivated')),

    -- ---- 2FA enrolment state -------------------------------------------------
    -- [DECIDED] This is enrolment STATE only. It is NOT the enforcement point.
    -- Whether 2FA is REQUIRED is computed at login from the roles the user holds
    -- (roles.requires_2fa), never stored here. Storing "this user must use 2FA"
    -- as a user column would go stale the moment their roles changed — exactly
    -- the bug that lets a newly-promoted executive keep logging in without it.
    mfa_enrolled_at    timestamptz,

    -- Denormalised convenience flag, maintained alongside user_mfa_methods.
    -- Reading it saves a join on the login path. It is a cache, not the truth.
    mfa_enabled        boolean NOT NULL DEFAULT false,

    last_login_at      timestamptz,
    failed_login_count integer NOT NULL DEFAULT 0,
    locked_until       timestamptz,

    -- [R5] Per-user extensions the tenant needs and we did not ship: licence
    -- number, desk/team, region, employee id, calendar handle. See §0.3.
    -- Nothing the AUTH path reads may live here — authentication and
    -- authorisation state must be typed columns and real rows (status,
    -- mfa_enabled, user_roles), never tenant-writable jsonb.
    custom_attributes  jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,

    CONSTRAINT users_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object')
);

-- Email is unique WITHIN a tenant, not globally.
-- [DECIDED] USERS ARE STRICTLY SINGLE-TENANT. There are no cross-tenant user
-- records: each subdomain maps to exactly one tenant's identity space, and a
-- users row belongs to exactly one tenant for its entire life. Confirmed by the
-- project owner; this was previously carried as an assumption (architecture
-- note Q16, now resolved).
--   What that buys: users.tenant_id is a hard scope like every other table, the
--   session/subdomain tenant equality check in the middleware is a simple
--   comparison rather than a membership lookup, and RLS on users needs no
--   special case.
--   What it means in practice: the same human working with two tenants holds
--   two separate accounts and authenticates separately in each — which is also
--   why session cookies are scoped per-subdomain rather than to the parent
--   domain (architecture note §4.3). For a B2B CRM this is the expected
--   behaviour, not a limitation.
--   The door this closes: supporting one identity across tenants later would
--   mean a `tenant_memberships` join, users losing its tenant_id, and a rewrite
--   of the auth path. That is an invasive change and it is deliberately not on
--   the table.
CREATE UNIQUE INDEX users_tenant_email_key
    ON users (tenant_id, lower(email))
    WHERE deleted_at IS NULL;

ALTER TABLE users ADD CONSTRAINT users_tenant_id_id_key UNIQUE (tenant_id, id);

CREATE INDEX users_tenant_status_idx ON users (tenant_id, status) WHERE deleted_at IS NULL;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- Join: which roles a user holds. A user may hold several.
CREATE TABLE user_roles (
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL,
    role_id     uuid NOT NULL,

    -- Who granted this, for the audit trail. Nullable because provisioning and
    -- automated grants have no human actor.
    granted_by  uuid,
    granted_at  timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, role_id),

    CONSTRAINT user_roles_user_fk
        FOREIGN KEY (tenant_id, user_id)
        REFERENCES users (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT user_roles_role_fk
        FOREIGN KEY (tenant_id, role_id)
        REFERENCES roles (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT user_roles_granted_by_fk
        FOREIGN KEY (tenant_id, granted_by)
        REFERENCES users (tenant_id, id) ON DELETE SET NULL
);

CREATE INDEX user_roles_tenant_role_idx ON user_roles (tenant_id, role_id);

COMMENT ON TABLE user_roles IS
'[DECIDED] Granting a role with requires_2fa = true MUST, in the same
 transaction, revoke all of that user''s active sessions (see sessions.revoked_at
 and revoked_reason = ''mfa_requirement_changed''). Otherwise a user promoted to
 an executive role keeps browsing for up to 24 hours on a session issued under
 the weaker requirement. Enforcing 2FA only at the next login is not enough; the
 current session has to be cut.';


-- -----------------------------------------------------------------------------
-- 4.1 MFA methods
-- -----------------------------------------------------------------------------
-- [JUDGMENT] A methods TABLE rather than a totp_secret column on users.
--   TOTP is the Phase 0 factor, but WebAuthn/passkeys are the better long-term
--   answer and adding them should not require reshaping the users table or
--   rewriting the login path's storage assumptions. A per-method row also lets a
--   user register two authenticators, which is the difference between losing a
--   phone and losing an account.

CREATE TABLE user_mfa_methods (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id       uuid NOT NULL,

    -- 'totp' is the only Phase 0 value. 'webauthn' reserved.
    -- [DECIDED] SMS is deliberately absent: SIM-swap makes it a downgrade, and
    -- offering it invites executives to choose it.
    method_type   text NOT NULL CHECK (method_type IN ('totp','webauthn')),

    label         text,

    -- [DECIDED] THE SECRET IS NOT STORED HERE.
    -- This is a REFERENCE (an AWS Secrets Manager ARN / KMS-encrypted key id) to
    -- the shared secret, held outside the database. A TOTP seed in a table is a
    -- password-equivalent sitting in every backup, every read replica, and every
    -- database dump a developer takes to debug something.
    secret_ref    text NOT NULL,

    -- Enrolment is a two-step handshake: create the method, then confirm it by
    -- entering a code. An unconfirmed method must NOT satisfy the 2FA
    -- requirement — otherwise starting enrolment and abandoning it would be
    -- enough to bypass a mandatory control.
    confirmed_at  timestamptz,

    last_used_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_mfa_methods_user_fk
        FOREIGN KEY (tenant_id, user_id)
        REFERENCES users (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX user_mfa_methods_user_idx ON user_mfa_methods (tenant_id, user_id);

-- One confirmed TOTP method per user. Multiple WebAuthn keys are allowed and
-- desirable, hence the method_type predicate rather than a blanket constraint.
CREATE UNIQUE INDEX user_mfa_methods_one_totp
    ON user_mfa_methods (tenant_id, user_id)
    WHERE method_type = 'totp' AND confirmed_at IS NOT NULL;


CREATE TABLE user_recovery_codes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL,

    -- Hashed exactly like a password. A recovery code is a password that bypasses
    -- 2FA; storing it in plaintext would make the audit finding write itself.
    code_hash   text NOT NULL,
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_recovery_codes_user_fk
        FOREIGN KEY (tenant_id, user_id)
        REFERENCES users (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX user_recovery_codes_user_idx
    ON user_recovery_codes (tenant_id, user_id) WHERE used_at IS NULL;


-- -----------------------------------------------------------------------------
-- 4.2 Sessions — absolute 24-hour expiry
-- -----------------------------------------------------------------------------
-- [JUDGMENT] Server-side session rows rather than self-contained JWTs.
--   The decisions in this design require REVOCATION: forced logout on role
--   change (see user_roles), forced logout on 2FA enrolment, "sign out all
--   devices", and immediate cutoff on suspension. A stateless JWT cannot be
--   revoked before its expiry without a denylist — which is this table, with
--   extra steps and worse ergonomics.
-- [DECIDED] Not in the original Phase 0 table list, but required by the 24-hour
--   session rule and now confirmed as part of the design.

CREATE TABLE sessions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id           uuid NOT NULL,

    -- Only the hash of the session token is stored. A stolen database dump must
    -- not yield usable session tokens.
    token_hash        text NOT NULL,

    -- [DECIDED] 24 hours, ABSOLUTE FROM ISSUANCE. Not sliding, not rolling.
    --   Confirmed by the project owner (architecture note Q3, now resolved).
    --   expires_at is set ONCE, at creation, and is never extended by activity.
    --   A user active at hour 23 re-authenticates at hour 24.
    --   Why absolute: a sliding window means an active session never expires,
    --   which is the same as having no expiry for exactly the population that
    --   matters — a stolen token on a machine someone is still using. The
    --   24-hour bound is only a real bound if it cannot be pushed forward.
    --   The cost, accepted: a user working a long shift is interrupted once a
    --   day. That is the trade the rule is buying.
    issued_at         timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),

    -- [DECIDED] The 2FA gate, represented in the session itself.
    --   false + scope 'mfa_enrolment' -> the restricted session issued to a user
    --   who must use 2FA but has not enrolled. It can reach the enrolment route
    --   and nothing else. This resolves the deadlock where a newly-promoted
    --   executive could otherwise not log in at all, without granting them
    --   access to data before they enrol.
    mfa_satisfied     boolean NOT NULL DEFAULT false,
    scope             text NOT NULL DEFAULT 'full'
                        CHECK (scope IN ('full','mfa_enrolment','mfa_challenge')),

    ip_address        inet,
    user_agent        text,

    revoked_at        timestamptz,
    revoked_reason    text CHECK (revoked_reason IN (
                          'logout','logout_all','password_changed',
                          'mfa_requirement_changed','mfa_enrolled',
                          'user_suspended','admin_revoked','expired'
                      )),

    -- Telemetry ONLY — "when did we last see this session". Updating it is
    -- explicitly NOT the same as extending the session, and it must never be
    -- used to recompute expires_at. Naming it last_seen_at rather than
    -- last_active_at is deliberate: the second name invites someone to slide the
    -- expiry off it.
    last_seen_at      timestamptz,

    CONSTRAINT sessions_user_fk
        FOREIGN KEY (tenant_id, user_id)
        REFERENCES users (tenant_id, id) ON DELETE CASCADE,

    CONSTRAINT sessions_expiry_after_issue CHECK (expires_at > issued_at)
);

CREATE UNIQUE INDEX sessions_token_hash_key ON sessions (token_hash);

-- Validation path: look up by token hash, then check live-ness.
CREATE INDEX sessions_active_idx
    ON sessions (tenant_id, user_id)
    WHERE revoked_at IS NULL;

-- Cleanup job: delete expired rows. Not tenant-prefixed on purpose — this index
-- serves a cross-tenant maintenance job that runs as the owner, not as crm_app.
CREATE INDEX sessions_expires_at_idx ON sessions (expires_at);

-- [DECIDED] Absolute expiry, ENFORCED — not merely documented.
--   The decision "24h absolute, never extended" is one line of application code
--   away from becoming a sliding window: an UPDATE that touches last_seen_at and
--   helpfully bumps expires_at at the same time. Nobody would review that as a
--   security change. This trigger makes it impossible, so the rule survives
--   contact with a future contributor who never read this file.
--   issued_at is frozen for the same reason: shifting it forward is the other
--   way to manufacture a longer session.
CREATE OR REPLACE FUNCTION sessions_forbid_expiry_extension()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
        RAISE EXCEPTION
            'sessions.expires_at is absolute and set once at issuance; it may '
            'not be modified (attempted % -> %). To end a session early set '
            'revoked_at; to give a user longer, issue a new session.',
            OLD.expires_at, NEW.expires_at
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.issued_at IS DISTINCT FROM OLD.issued_at THEN
        RAISE EXCEPTION
            'sessions.issued_at is immutable (attempted % -> %).',
            OLD.issued_at, NEW.issued_at
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER sessions_absolute_expiry
    BEFORE UPDATE ON sessions
    FOR EACH ROW EXECUTE FUNCTION sessions_forbid_expiry_extension();

COMMENT ON TABLE sessions IS
'A session is valid only when: revoked_at IS NULL AND expires_at > now() AND
 scope = ''full''. The scope check is what makes the restricted enrolment session
 safe — validating only revocation and expiry would let an mfa_enrolment session
 reach the whole application.
 [DECIDED] Expiry is ABSOLUTE: 24 hours from issued_at, fixed at creation and
 never extended by activity. The sessions_absolute_expiry trigger enforces this
 in the database rather than trusting every future write path to honour it.
 last_seen_at is telemetry and must not feed expires_at.
 [DECIDED] The session''s tenant_id MUST be compared against the tenant resolved
 from the request subdomain, and the request rejected on mismatch. That check is
 what stops a valid cookie from tenant A being replayed against tenant B''s
 subdomain.';


-- =============================================================================
-- 5. MASTER / LOOKUP DATA  (Rule R4 — masters, not enums)
-- =============================================================================
--
-- [DECIDED, R4] Lead sources, stages, statuses and reasons are ROWS IN TENANT-
-- SCOPED TABLES. They are never PostgreSQL ENUM types, and never a CHECK-
-- constrained text column either.
--
-- WHY NOT AN ENUM — three distinct reasons, each sufficient on its own:
--
--   1. TENANT CUSTOMISABILITY WITHOUT A SCHEMA MIGRATION. This is the big one.
--      A brokerage that wants a "Zillow" lead source and an agency that wants
--      "Trade Show" are asking for a row, not a deploy. With an enum, every
--      customer request becomes ALTER TYPE ... ADD VALUE — a migration, a
--      release, and a global change to a value only one tenant asked for. In a
--      pooled multi-tenant database an enum is by definition a GLOBAL
--      vocabulary, which is the wrong scope for a per-tenant concept. Rows are
--      tenant-scoped by construction (R1), so tenant A's sources are invisible
--      to tenant B and cost tenant B nothing.
--
--   2. REORDER AND DEACTIVATE WITHOUT BREAKING HISTORY. Enum values cannot be
--      removed once data references them, and their sort order is the order they
--      were declared in — so the enum you add "Zillow" to sorts it last forever
--      unless you rebuild the type. With rows: sort_order is a column anyone can
--      edit, and retiring a value is is_active = false. Deactivating is the
--      important half. A source that stops being used must disappear from the
--      picker for NEW records while staying perfectly resolvable for the three
--      years of historical leads that reference it. Deleting the value would
--      orphan history; keeping it in the picker clutters it; an enum offers no
--      third option. is_active is that third option.
--
--   3. PER-TENANT LABELS, DECOUPLED FROM THE MACHINE KEY. `code` is the stable
--      identifier application logic and reports key on; `label` is display text
--      the tenant renames freely. One tenant's "Qualified" is another's "Under
--      Contract". With an enum the stored value IS the display string, so
--      renaming it either breaks every query that matched on it or forces a
--      translation layer that is really just this table with extra steps.
--
-- The cost we accept: a join (or a cached lookup) to render a label, and
-- referential integrity that is FK-enforced rather than type-enforced. Both are
-- ordinary. The enum saves one join and costs a migration per customer request.
--
-- [JUDGMENT] SIX TYPED TABLES, not one generic `master_list_items` table with a
--   list_type discriminator. A single generic table is tempting — one table, one
--   seeding routine, one admin screen — but it cannot express a typed foreign
--   key: nothing would stop a lead's source_id from pointing at a loss reason,
--   because both are rows in the same table. Recovering that guarantee needs a
--   redundant discriminator column in every referencing table plus a composite
--   FK carrying it, which is more machinery than six small tables. Typed tables
--   also let each master carry the columns it actually needs (the stage tables
--   have stage_type and probability_pct; the others do not), instead of a shared
--   nullable grab-bag. The duplication here is six near-identical DDL blocks,
--   which is cheap and greppable.
--
-- THE SIX:
--   lead_sources       §5.1   Where did this lead come from?
--   lead_statuses      §5.2   What state is the lead RECORD in?
--   lead_stages        §5.3   Where is the lead in the pre-sales pipeline?
--   lead_loss_reasons  §5.4   Why was the lead lost?
--   deal_stages        §5.5   Where is the deal in the SALES pipeline?
--   deal_loss_reasons  §5.6   Why was the deal lost?
--
-- ---- WHY LEADS AND DEALS DO NOT SHARE A STAGE VOCABULARY (Q17, resolved) -----
--
-- [DECIDED] Deals get their OWN stage and loss-reason masters. lead_stages and
--   deal_stages are structurally identical and semantically different, and the
--   difference is the whole reason they are two tables rather than one.
--
--   A LEAD's stages are PRE-SALES QUALIFICATION. They answer "is there a real
--   opportunity here at all?" — an unqualified enquiry being worked toward the
--   moment it becomes (or fails to become) a deal. The lead pipeline's terminal
--   state is a decision about the LEAD's validity: converted, or discarded.
--
--   A DEAL's stages are THE SALES PIPELINE ITSELF. They answer "how close is
--   this known-real opportunity to money?" — proposal, negotiation, contract,
--   closed. The deal pipeline's terminal state is a commercial outcome: revenue
--   booked, or revenue lost to a competitor or a budget.
--
--   Those are different lifecycles with different owners, different reporting,
--   and different cardinality of change. Forcing them onto one list produces the
--   same defect as merging lead_statuses into lead_stages (see §5.2): a single
--   axis that cannot represent two independent facts. Concretely, a shared list
--   would mean an SDR's "Qualification" and an AE's "Negotiation" live in one
--   picker, every lead report has to exclude the deal-only values and vice
--   versa, and a tenant reordering their sales pipeline silently reorders their
--   lead pipeline. Conversion-rate reporting is the sharpest case: lead→deal
--   conversion is a rate BETWEEN the two pipelines, and it is not computable if
--   they are the same pipeline.
--
--   The cost accepted: two lists to configure instead of one, and two seeding
--   blocks in provision_tenant_master_data(). That is the correct trade — the
--   alternative is a vocabulary that is wrong for both objects.
--
--   NOT ADDED, deliberately: there is no `deal_sources` and no `deal_statuses`.
--   See the note at the end of §5.6 for the reasoning and for what would make
--   either one necessary.
--
-- THE SHARED SHAPE, identical across all six:
--   id, tenant_id, code (stable machine key), label (renameable display text),
--   description, sort_order, is_active, is_system, custom_attributes (R5),
--   timestamps — plus UNIQUE (tenant_id, code) and the UNIQUE (tenant_id, id)
--   that makes tenant-safe composite FKs possible.
--
-- is_system mirrors roles.is_system: seeded defaults may be renamed, reordered
-- and deactivated by the tenant, but not deleted and not re-coded, because
-- application logic and canned reports key on those codes.


-- -----------------------------------------------------------------------------
-- 5.1 Lead sources — where a lead came from
-- -----------------------------------------------------------------------------
CREATE TABLE lead_sources (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- Stable machine key. Lowercase snake_case so it is safe in URLs, report
    -- definitions and export headers. Never shown to a user; `label` is.
    code              text NOT NULL,
    label             text NOT NULL,
    description       text,

    -- Picker order. Not unique: ties are broken by label, and forcing uniqueness
    -- would make "drag this one to the top" a multi-row renumber under a unique
    -- constraint, which is a deadlock generator for no benefit.
    sort_order        integer NOT NULL DEFAULT 0,

    -- [DECIDED] Retirement is deactivation, never deletion. false = hidden from
    -- pickers for NEW records, still resolvable for every historical row that
    -- references it. This is the property an enum cannot provide.
    is_active         boolean NOT NULL DEFAULT true,

    -- Seeded default: renameable and deactivatable, not deletable or re-codable.
    is_system         boolean NOT NULL DEFAULT false,

    -- [R5] e.g. a UI colour, an attribution channel grouping, the external id
    -- this source maps to in the tenant's ad platform. See §0.3.
    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lead_sources_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT lead_sources_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object')
);

CREATE UNIQUE INDEX lead_sources_tenant_code_key ON lead_sources (tenant_id, code);
ALTER TABLE lead_sources ADD CONSTRAINT lead_sources_tenant_id_id_key
    UNIQUE (tenant_id, id);

-- The picker query: active values for this tenant, in display order.
CREATE INDEX lead_sources_tenant_active_idx
    ON lead_sources (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER lead_sources_set_updated_at
    BEFORE UPDATE ON lead_sources
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 5.2 Lead statuses — the lifecycle state of a lead record
-- -----------------------------------------------------------------------------
-- [JUDGMENT] STATUS and STAGE are separate tables because they answer different
--   questions and change independently. Status is the state of the RECORD ("has
--   anyone called this person yet"); stage is the position in the SALES PIPELINE
--   ("how close is this to closing"). Modelling them as one list is a classic
--   CRM data-model mistake: it forces "Contacted" and "Negotiation" onto one
--   axis, and then a lead cannot be both contacted and in negotiation.
CREATE TABLE lead_statuses (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    code              text NOT NULL,
    label             text NOT NULL,
    description       text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_system         boolean NOT NULL DEFAULT false,

    -- Marks the status a newly created lead receives when the caller does not
    -- specify one. A partial unique index below allows at most one per tenant.
    is_default        boolean NOT NULL DEFAULT false,

    -- Terminal statuses stop follow-up automation and are excluded from "open
    -- work" counts. Flagging it here rather than hardcoding a list of codes in
    -- application logic is the same reasoning as roles.requires_2fa: a tenant
    -- renaming or adding a status must not silently disable the behaviour.
    is_terminal       boolean NOT NULL DEFAULT false,

    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lead_statuses_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT lead_statuses_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object')
);

CREATE UNIQUE INDEX lead_statuses_tenant_code_key ON lead_statuses (tenant_id, code);
ALTER TABLE lead_statuses ADD CONSTRAINT lead_statuses_tenant_id_id_key
    UNIQUE (tenant_id, id);

-- At most one default status per tenant. Enforced here rather than in the
-- application because "two defaults" makes lead creation non-deterministic.
CREATE UNIQUE INDEX lead_statuses_one_default_per_tenant
    ON lead_statuses (tenant_id) WHERE is_default;

CREATE INDEX lead_statuses_tenant_active_idx
    ON lead_statuses (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER lead_statuses_set_updated_at
    BEFORE UPDATE ON lead_statuses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 5.3 Lead stages — position in the sales pipeline
-- -----------------------------------------------------------------------------
CREATE TABLE lead_stages (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    code              text NOT NULL,
    label             text NOT NULL,
    description       text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_system         boolean NOT NULL DEFAULT false,

    -- [JUDGMENT] The one piece of SEMANTICS the product must know about a stage.
    --   Forecasting, conversion rate and "deals won this quarter" all need to
    --   know which stages mean won and which mean lost. Deriving that from the
    --   code ('closed_won') would break the moment a tenant renames or adds a
    --   stage — the same failure mode as hardcoding a role named 'executive'.
    --   So the meaning is a column, and the tenant's naming is free.
    stage_type        text NOT NULL DEFAULT 'open'
                        CHECK (stage_type IN ('open','won','lost')),

    -- Default win probability for forecasting, 0-100. Nullable: a tenant that
    -- does not do weighted-pipeline forecasting leaves it empty rather than
    -- being made to invent numbers.
    probability_pct   smallint CHECK (probability_pct BETWEEN 0 AND 100),

    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lead_stages_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT lead_stages_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object'),

    -- A won stage at 30% or a lost stage at 90% is a data-entry error that
    -- silently corrupts every forecast built on it.
    CONSTRAINT lead_stages_terminal_probability CHECK (
        (stage_type = 'won'  AND coalesce(probability_pct, 100) = 100) OR
        (stage_type = 'lost' AND coalesce(probability_pct, 0)   = 0)   OR
        (stage_type = 'open')
    )
);

CREATE UNIQUE INDEX lead_stages_tenant_code_key ON lead_stages (tenant_id, code);
ALTER TABLE lead_stages ADD CONSTRAINT lead_stages_tenant_id_id_key
    UNIQUE (tenant_id, id);

CREATE INDEX lead_stages_tenant_active_idx
    ON lead_stages (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER lead_stages_set_updated_at
    BEFORE UPDATE ON lead_stages
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE lead_stages IS
'R4 master table. stage_type (open/won/lost) is the only semantics the product
 reads; everything else about a stage — its name, order, probability, whether it
 is offered at all — belongs to the tenant. Reporting MUST filter on stage_type,
 never on code, or a tenant renaming a stage breaks their own dashboards.
 [DECIDED] These are the PRE-SALES QUALIFICATION stages of a lead, and they are
 NOT shared with deals. Deals have their own deal_stages master (§5.5), because a
 deal''s stages are the sales pipeline itself rather than the question of whether
 an opportunity exists at all. Phase 1 `leads` reference this table; Phase 1
 `deals` reference deal_stages. (Architecture note Q17, now resolved.)';


-- -----------------------------------------------------------------------------
-- 5.4 Lead loss reasons — why a lead was lost
-- -----------------------------------------------------------------------------
-- Kept separate from lead_stages rather than being an attribute of the 'lost'
-- stage: there is one lost stage and many reasons for reaching it, and the
-- reason list is the single most frequently customised vocabulary in a CRM
-- because it is what sales leadership actually reports on.
CREATE TABLE lead_loss_reasons (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    code              text NOT NULL,
    label             text NOT NULL,
    description       text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_system         boolean NOT NULL DEFAULT false,

    -- When true the UI must collect free-text detail alongside the reason.
    -- "Other" without a note is a reason that teaches nobody anything.
    requires_note     boolean NOT NULL DEFAULT false,

    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lead_loss_reasons_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT lead_loss_reasons_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object')
);

CREATE UNIQUE INDEX lead_loss_reasons_tenant_code_key
    ON lead_loss_reasons (tenant_id, code);
ALTER TABLE lead_loss_reasons ADD CONSTRAINT lead_loss_reasons_tenant_id_id_key
    UNIQUE (tenant_id, id);

CREATE INDEX lead_loss_reasons_tenant_active_idx
    ON lead_loss_reasons (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER lead_loss_reasons_set_updated_at
    BEFORE UPDATE ON lead_loss_reasons
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 5.5 Deal stages — position in the SALES pipeline
-- -----------------------------------------------------------------------------
-- [DECIDED, R4 / Q17] Structurally identical to lead_stages, deliberately.
--   The column list is copied rather than shared because the two tables hold
--   different vocabularies for different lifecycles (see the §5 header): a lead
--   stage is pre-sales qualification, a deal stage is the sales pipeline itself.
--   Identical structure is what makes the duplication cheap — the admin UI, the
--   picker query and the seeding block are the same code shape twice — and the
--   separate table is what keeps the two vocabularies from colliding.
--
--   The alternative considered and rejected: one `stages` table with an
--   `object_type` discriminator ('lead' | 'deal'). That is the generic
--   master_list_items idea at smaller scale, and it fails the same way — a
--   deal's stage_id could point at a lead stage, and preventing it needs a
--   redundant discriminator column plus a composite FK carrying it in every
--   referencing table. Two tables cost two DDL blocks; the discriminator costs a
--   constraint in every table that will ever reference a stage.
CREATE TABLE deal_stages (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    code              text NOT NULL,
    label             text NOT NULL,
    description       text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_system         boolean NOT NULL DEFAULT false,

    -- [JUDGMENT] Same semantics-as-a-column rule as lead_stages.stage_type, and
    --   it matters more here: revenue reporting is built on it. "Bookings this
    --   quarter" is WHERE stage_type = 'won', not WHERE code = 'closed_won'. A
    --   tenant who renames or adds a closing stage must not silently break their
    --   own revenue number, which is exactly what code-matching would do.
    stage_type        text NOT NULL DEFAULT 'open'
                        CHECK (stage_type IN ('open','won','lost')),

    -- Weighted-pipeline forecasting. Nullable for tenants who do not forecast.
    probability_pct   smallint CHECK (probability_pct BETWEEN 0 AND 100),

    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT deal_stages_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT deal_stages_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object'),

    -- A won stage at 30% or a lost stage at 90% silently corrupts every forecast
    -- built on it. Same guard as lead_stages.
    CONSTRAINT deal_stages_terminal_probability CHECK (
        (stage_type = 'won'  AND coalesce(probability_pct, 100) = 100) OR
        (stage_type = 'lost' AND coalesce(probability_pct, 0)   = 0)   OR
        (stage_type = 'open')
    )
);

CREATE UNIQUE INDEX deal_stages_tenant_code_key ON deal_stages (tenant_id, code);
ALTER TABLE deal_stages ADD CONSTRAINT deal_stages_tenant_id_id_key
    UNIQUE (tenant_id, id);

CREATE INDEX deal_stages_tenant_active_idx
    ON deal_stages (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER deal_stages_set_updated_at
    BEFORE UPDATE ON deal_stages
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE deal_stages IS
'R4 master table. THE SALES PIPELINE — where a known-real opportunity sits on the
 way to money (proposal, negotiation, contract, closed). Distinct from
 lead_stages, which is the PRE-SALES QUALIFICATION pipeline answering whether an
 opportunity exists at all. The two are structurally identical and semantically
 different; merging them would put an SDR''s qualification steps and an AE''s
 closing steps on one axis, and would make lead-to-deal conversion rate — a rate
 BETWEEN the two pipelines — uncomputable. (Architecture note Q17, resolved.)
 stage_type (open/won/lost) is the only semantics the product reads. Revenue and
 forecast reporting MUST filter on stage_type, never on code.
 [OPEN] Multiple named pipelines per tenant (a "New Business" pipeline and a
 "Renewals" pipeline, each with its own stage list) is a real CRM requirement and
 is NOT modelled here — it would need a `pipelines` table and a pipeline_id on
 this one. Deliberately not built in Phase 0: it is a Phase 1 question that
 depends on how `deals` is shaped. Architecture note Q22.';


-- -----------------------------------------------------------------------------
-- 5.6 Deal loss reasons — why a deal was lost
-- -----------------------------------------------------------------------------
-- [DECIDED, R4 / Q17] Separate from lead_loss_reasons, for the same reason the
--   stage lists are separate, and the separation bites harder here.
--   A LEAD is lost for reasons about whether an opportunity was ever real:
--   unresponsive, not a fit, duplicate record, no budget at all.
--   A DEAL is lost for commercial reasons against a real, qualified buyer: we
--   were outsold, we were outpriced, we lacked a capability, the budget was
--   withdrawn late.
--   These are the two most-reported-on vocabularies in a CRM and they feed
--   different decisions — lead loss reasons tune marketing spend and lead
--   qualification, deal loss reasons tune pricing, product and competitive
--   positioning. Mixing them produces a single "why we lose" report that answers
--   neither question, and "Duplicate Record" sitting in a competitive win/loss
--   review is the visible symptom.
CREATE TABLE deal_loss_reasons (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    code              text NOT NULL,
    label             text NOT NULL,
    description       text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_system         boolean NOT NULL DEFAULT false,

    -- When true the UI must collect free-text detail alongside the reason.
    -- "Lost to Competitor" without naming the competitor is a data point that
    -- cannot be acted on.
    requires_note     boolean NOT NULL DEFAULT false,

    custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT deal_loss_reasons_code_format
        CHECK (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT deal_loss_reasons_custom_attributes_is_object
        CHECK (jsonb_typeof(custom_attributes) = 'object')
);

CREATE UNIQUE INDEX deal_loss_reasons_tenant_code_key
    ON deal_loss_reasons (tenant_id, code);
ALTER TABLE deal_loss_reasons ADD CONSTRAINT deal_loss_reasons_tenant_id_id_key
    UNIQUE (tenant_id, id);

CREATE INDEX deal_loss_reasons_tenant_active_idx
    ON deal_loss_reasons (tenant_id, sort_order, label) WHERE is_active;

CREATE TRIGGER deal_loss_reasons_set_updated_at
    BEFORE UPDATE ON deal_loss_reasons
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE deal_loss_reasons IS
'R4 master table. Why a qualified DEAL was lost — a commercial post-mortem that
 feeds pricing, product and competitive positioning. Distinct from
 lead_loss_reasons, which records why an enquiry never became an opportunity and
 feeds marketing spend and lead qualification instead. (Architecture note Q17,
 resolved.)';


-- -----------------------------------------------------------------------------
-- 5.6a WHY THERE IS NO deal_sources AND NO deal_statuses
-- -----------------------------------------------------------------------------
-- [JUDGMENT] Q17 asked for deal stages and deal loss reasons. The symmetric
-- question — should deals also get their own `sources` and `statuses` masters? —
-- is answered NO here, deliberately and with the reasoning recorded, rather than
-- either silently adding two more tables or silently not considering it.
--
--   NO deal_sources. `lead_sources` answers "where did this business come
--   from" — an ACQUISITION-ATTRIBUTION vocabulary (web form, referral, paid
--   ads, partner). That question is asked once per opportunity, at the point of
--   first contact, and its answer does not change when a lead becomes a deal.
--   A separate deal_sources list would be the same vocabulary maintained twice,
--   which guarantees the two drift apart, and attribution reporting — the entire
--   purpose of the list — would then have to reconcile "Referral" against
--   "Referral" across two tables. Phase 1 `deals` should carry the source
--   through from the originating lead, referencing lead_sources.
--     [OPEN] Two consequences that Phase 1 must decide, not Phase 0: (a) whether
--     `lead_sources` should be renamed to something object-neutral once a second
--     object references it — the name will read wrong on a deal — and (b) how a
--     deal created directly, with no originating lead, gets a source. Both are
--     naming/flow questions on a live table, and both are cheap to settle then
--     and expensive to guess at now. Architecture note Q23.
--
--   NO deal_statuses. A lead needs BOTH a status and a stage because they are
--   genuinely independent axes: "has anyone worked this record" is not the same
--   question as "how close is it to closing", and a lead can be Contacted and in
--   Qualification simultaneously (§5.2). A deal does not have that second axis —
--   a deal's record state IS its pipeline position, and the terminal semantics a
--   status would carry (lead_statuses.is_terminal) are already carried by
--   deal_stages.stage_type in ('won','lost'). Adding deal_statuses would
--   recreate exactly the one-concept-two-lists confusion that §5.2 warns
--   against, and the first symptom would be a deal whose status says Open and
--   whose stage says Closed Won.
--     What would change this answer: a deal-level lifecycle that is genuinely
--     orthogonal to the pipeline — approval workflow (draft / pending approval /
--     approved), or contract state (signed / countersigned / executed) running
--     alongside the sales stage. If Phase 1 needs one of those, it is a NEW
--     master with its own name (`deal_approval_states`), not a `deal_statuses`
--     table shaped by symmetry with leads. Naming a table after the symmetry
--     rather than after the question is how the confusion gets in.
--
-- FLAGGED FOR THE PROJECT OWNER: both of these are judgment calls made here, not
-- instructions received. If deals in this business genuinely have their own
-- acquisition channels, or their own approval lifecycle, say so and they become
-- ordinary additions following this same pattern.


-- -----------------------------------------------------------------------------
-- 5.7 How Phase 1 business objects must reference these masters
-- -----------------------------------------------------------------------------
-- [DECIDED] Phase 0 has no CRM business objects, so there is nothing here to
-- point at these tables yet. The referencing pattern is fixed now so that the
-- Phase 1 `leads` table is written correctly the first time rather than being
-- retrofitted after data exists. It is the SAME composite-FK pattern used
-- everywhere else in this file (see feature_entitlements), with one difference
-- called out below.
--
--   CREATE TABLE leads (
--       id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--       tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
--       ...
--       source_id         uuid,            -- nullable: source is often unknown
--       status_id         uuid NOT NULL,
--       stage_id          uuid NOT NULL,
--       loss_reason_id    uuid,            -- only set once lost
--
--       custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,   -- R5, MANDATORY
--
--       CONSTRAINT leads_source_fk
--           FOREIGN KEY (tenant_id, source_id)
--           REFERENCES lead_sources (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT leads_status_fk
--           FOREIGN KEY (tenant_id, status_id)
--           REFERENCES lead_statuses (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT leads_stage_fk
--           FOREIGN KEY (tenant_id, stage_id)
--           REFERENCES lead_stages (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT leads_loss_reason_fk
--           FOREIGN KEY (tenant_id, loss_reason_id)
--           REFERENCES lead_loss_reasons (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT leads_custom_attributes_is_object
--           CHECK (jsonb_typeof(custom_attributes) = 'object')
--   );
--
-- And the deal side, which references the DEAL masters (§5.5, §5.6) — not the
-- lead ones. This is the referencing consequence of Q17:
--
--   CREATE TABLE deals (
--       id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
--       tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
--       ...
--       stage_id          uuid NOT NULL,   -- -> deal_stages, NOT lead_stages
--       loss_reason_id    uuid,            -- -> deal_loss_reasons, only once lost
--       source_id         uuid,            -- -> lead_sources; see §5.6a and Q23
--
--       custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,   -- R5, MANDATORY
--
--       CONSTRAINT deals_stage_fk
--           FOREIGN KEY (tenant_id, stage_id)
--           REFERENCES deal_stages (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT deals_loss_reason_fk
--           FOREIGN KEY (tenant_id, loss_reason_id)
--           REFERENCES deal_loss_reasons (tenant_id, id) ON DELETE RESTRICT,
--       CONSTRAINT deals_custom_attributes_is_object
--           CHECK (jsonb_typeof(custom_attributes) = 'object')
--   );
--
-- TWO THINGS THAT ARE NOT NEGOTIABLE IN THOSE BLOCKS:
--
--   * COMPOSITE FKs carrying tenant_id, exactly as elsewhere in this file. A
--     plain FK to lead_sources(id) would let tenant A's lead reference tenant
--     B's source row. RLS does not catch this: RLS filters what you can SEE, it
--     does not stop you WRITING a row that points somewhere else. The composite
--     key makes the cross-tenant reference unrepresentable.
--
--   * ON DELETE RESTRICT, not CASCADE. This is the one place the master tables
--     differ from the child relations above. Deleting a lead source must NEVER
--     delete the leads that came from it — that is a data-loss bug wearing a
--     referential-integrity costume. RESTRICT makes the attempt fail loudly,
--     which is correct, because the intended operation was is_active = false.
--     The application should not offer deletion of a referenced master at all.


-- =============================================================================
-- 6. AUDIT LOG  (Rule R6 — event-based, 12 months hot)
-- =============================================================================
--
-- [DECIDED] EVENT-BASED, not row-snapshot / CDC.
--   Each row is a discrete DOMAIN event described in business language
--   ('contact.merged', 'user.role_granted'), written deliberately by the
--   application at the point of the business action — NOT an automatic
--   before/after diff of every UPDATE emitted by a trigger.
--   The trade: we accept incomplete coverage (only what we remember to emit) in
--   exchange for a log that answers the questions humans actually ask. "Who
--   deleted this account?" is one query against an event log and an archaeology
--   project against a column-diff log. Emitting an event is part of the
--   definition of done for any state-changing operation, and auth, permission,
--   billing, export and deletion events are non-negotiable emitters.
--
-- [DECIDED] APPEND-ONLY. The application role receives INSERT and SELECT on this
--   table and nothing else (see §7.1). A log the application can rewrite is not
--   an audit log.
--
-- [DECIDED] RETENTION: 12 MONTHS HOT, THEN ARCHIVE TO S3 AND DROP.
--   Confirmed by the project owner (architecture note Q1, now resolved). The
--   policy in full:
--     * A rolling 12-month window of monthly partitions stays queryable in
--       PostgreSQL. This is what the audit UI, investigations and exports read.
--     * A scheduled job dumps the aging (13th-oldest) partition to S3 cold
--       storage, verifies the dump, and only then DROPs the partition.
--     * Nothing is hard-deleted. History leaves PostgreSQL; it does not cease to
--       exist. Retrieval past 12 months is an out-of-band request against the
--       archive, deliberately not a product feature.
--   Why this beats the two alternatives considered: hard delete is cheaper but
--   irreversible, and a CRM holds exactly the kind of record — who exported the
--   customer list, who changed permissions — that gets asked about years later.
--   Tiering by event_category keeps the compliance-relevant subset hot but
--   splits the log into two retention regimes and two query paths for a saving
--   that S3 storage pricing makes irrelevant.
--
-- [DECIDED] PARTITIONED BY MONTH — and now doubly justified, because the
--   retention policy above is *implemented* by DROP TABLE on a partition.
--   Dropping a partition is instant and reclaims the space immediately, while
--   DELETE-ing a year-old slice of a large unpartitioned append-only table is a
--   long, bloat-generating operation that competes with live traffic. The
--   partition boundary is also the natural archive unit: one partition, one S3
--   object set, one atomic hand-off.
--   Retrofitting partitioning after a year of production data is significantly
--   harder than adopting it now.
--
-- [OPEN] The archive job itself is NOT BUILT and is NOT a Phase 0 deliverable.
--   It is an implementation task for a later phase (architecture note §8.3 and
--   the follow-ups register). What must be true of it, recorded now so the
--   requirements are not re-derived: it creates next month's partition ahead of
--   time; it exports before it drops and verifies the export first (drop-then-
--   discover-the-dump-failed is unrecoverable); it is idempotent and safely
--   re-runnable; it runs as a privileged role, never as crm_app; and dropping a
--   partition is itself an audited administrative action.

CREATE TABLE audit_events (
    -- The partition key must be part of every unique constraint on a partitioned
    -- table, hence the composite primary key rather than a bare id.
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,

    -- When the business event happened (supplied by the emitter), which is not
    -- necessarily when the row was written (recorded_at). They differ for queued
    -- or replayed events, and conflating them makes an incident timeline lie.
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    recorded_at    timestamptz NOT NULL DEFAULT now(),

    -- Dotted domain event name: 'contact.merged', 'user.role_granted',
    -- 'subscription.upgraded', 'auth.login_failed', 'export.generated'.
    event_type     text NOT NULL,

    -- Coarse grouping for retention tiering and for filtering the activity feed.
    -- Named here because a future tiered-retention policy (Q1) needs a column to
    -- tier ON, and adding one to a year-old partitioned table is expensive.
    event_category text NOT NULL DEFAULT 'general'
                     CHECK (event_category IN
                       ('general','auth','rbac','billing','data','integration','admin')),

    -- ---- Actor ---------------------------------------------------------------
    -- Nullable user reference: system jobs, integrations and API keys have no
    -- human actor, and forcing one would mean inventing fake users.
    actor_type     text NOT NULL DEFAULT 'user'
                     CHECK (actor_type IN ('user','system','api_key','integration','support')),
    actor_user_id  uuid,

    -- Denormalised actor label, frozen at write time. If the user is later
    -- renamed or deleted, the log must still say who it was AT THE TIME.
    -- Joining to live users to render history is wrong: it rewrites the past.
    actor_label    text,

    -- ---- Subject -------------------------------------------------------------
    -- What the event was about, as a loose type+id pair rather than a real FK.
    -- Deliberately NOT a foreign key: the log must survive deletion of the thing
    -- it describes, and "who deleted this record" is precisely the query where a
    -- cascading FK would have destroyed the evidence.
    subject_type   text,
    subject_id     uuid,

    -- ---- Payload -------------------------------------------------------------
    -- The event's own immutable facts. JSONB because event shapes differ per
    -- event_type and will keep changing; a wide typed table would be mostly
    -- NULLs and a migration for every new event.
    -- Payloads are self-contained and denormalised ON PURPOSE, for the same
    -- reason as actor_label.
    payload        jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Request correlation, for tying an event to a trace / support ticket.
    request_id     text,
    ip_address     inet,

    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

-- Indexes declared on the parent are created on every partition automatically.
--
-- The dominant access pattern is: "events for THIS tenant, in THIS time range,
-- newest first" — every audit UI, export and investigation is that query with
-- optional extra filters. So (tenant_id, occurred_at DESC) is the primary index.
CREATE INDEX audit_events_tenant_time_idx
    ON audit_events (tenant_id, occurred_at DESC);

CREATE INDEX audit_events_tenant_type_time_idx
    ON audit_events (tenant_id, event_type, occurred_at DESC);

CREATE INDEX audit_events_tenant_actor_time_idx
    ON audit_events (tenant_id, actor_user_id, occurred_at DESC)
    WHERE actor_user_id IS NOT NULL;

CREATE INDEX audit_events_tenant_subject_idx
    ON audit_events (tenant_id, subject_type, subject_id, occurred_at DESC)
    WHERE subject_id IS NOT NULL;

-- [JUDGMENT] NO GIN index on payload in Phase 0.
--   A GIN index is the obvious reflex for a JSONB column, but it is expensive to
--   maintain on a write-heavy append-only table and it would be paid on every
--   single event insert to serve queries nobody has asked for yet. Add one
--   (ideally a jsonb_path_ops GIN, scoped to specific partitions) when a real
--   query demands it.
--   [DEFERRED TO PHASE 2 — Q20] This is not "open" and it is not "resolved": it
--   is scheduled. Phase 2 is where the CRM business objects have been live long
--   enough to produce slow-query data, which is the only input that can decide
--   which columns and which keys are worth indexing. Do not relitigate it in
--   Phase 1; do not skip it in Phase 2. See architecture note §11.4.

-- ---- PARTITION RUNWAY -------------------------------------------------------
-- [DECIDED] TWELVE MONTHS OF PARTITIONS ARE PRE-CREATED, not three.
--
--   Why this is a correctness property and not housekeeping: there is no
--   DEFAULT partition, deliberately. A DEFAULT partition would silently absorb
--   rows that fall outside every declared range and hide the failure until it is
--   enormous and cannot be split without an exclusive lock. Without one, an
--   INSERT past the last declared bound FAILS — loudly, which is the behaviour
--   we want, but it fails on the AUDIT WRITE PATH. Since emitting an audit event
--   is part of the definition of done for every state-changing operation (§6
--   header), a missing partition does not degrade logging; it takes down every
--   write in the product that emits an event.
--
--   The previous version of this file declared three partitions (2026-09 through
--   2026-11), which is roughly one month of runway past the date it was written.
--   That made the not-yet-built partition-creation job an implicit production
--   dependency with a one-month fuse. Twelve months of pre-created partitions
--   removes that fuse: the runway now matches the R6 hot-window length, so the
--   partition-creation job and the archive job come due at the same time rather
--   than the former arriving nearly a year early.
--
--   Range below: 2026-09-01 .. 2027-10-01, i.e. the current month plus twelve
--   full months. Empty partitions cost essentially nothing — an empty table and
--   its inherited indexes, a few kilobytes each — so buying a year of runway is
--   free. Partition creation is also not idempotent (CREATE TABLE ... PARTITION
--   OF raises on an existing bound), so the job that extends this must use
--   CREATE TABLE IF NOT EXISTS or check pg_class first.
--
--   [OPEN — Phase 1 follow-up] A RECURRING JOB TO KEEP EXTENDING THIS STILL HAS
--   TO BE BUILT. It is not built here and it is not a Phase 0 deliverable. What
--   it must do: run monthly, ensure at least twelve months of partitions exist
--   ahead of now(), run as a privileged role (never crm_app), be idempotent, and
--   alert on partition COVERAGE rather than on job success — "the job ran" and
--   "there is a partition for next month" are different assertions, and only the
--   second one matters. See architecture note §13. Without that job, this file
--   has bought twelve months, not forever.
CREATE TABLE audit_events_2026_09 PARTITION OF audit_events
    FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');
CREATE TABLE audit_events_2026_10 PARTITION OF audit_events
    FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');
CREATE TABLE audit_events_2026_11 PARTITION OF audit_events
    FOR VALUES FROM ('2026-11-01 00:00:00+00') TO ('2026-12-01 00:00:00+00');
CREATE TABLE audit_events_2026_12 PARTITION OF audit_events
    FOR VALUES FROM ('2026-12-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
CREATE TABLE audit_events_2027_01 PARTITION OF audit_events
    FOR VALUES FROM ('2027-01-01 00:00:00+00') TO ('2027-02-01 00:00:00+00');
CREATE TABLE audit_events_2027_02 PARTITION OF audit_events
    FOR VALUES FROM ('2027-02-01 00:00:00+00') TO ('2027-03-01 00:00:00+00');
CREATE TABLE audit_events_2027_03 PARTITION OF audit_events
    FOR VALUES FROM ('2027-03-01 00:00:00+00') TO ('2027-04-01 00:00:00+00');
CREATE TABLE audit_events_2027_04 PARTITION OF audit_events
    FOR VALUES FROM ('2027-04-01 00:00:00+00') TO ('2027-05-01 00:00:00+00');
CREATE TABLE audit_events_2027_05 PARTITION OF audit_events
    FOR VALUES FROM ('2027-05-01 00:00:00+00') TO ('2027-06-01 00:00:00+00');
CREATE TABLE audit_events_2027_06 PARTITION OF audit_events
    FOR VALUES FROM ('2027-06-01 00:00:00+00') TO ('2027-07-01 00:00:00+00');
CREATE TABLE audit_events_2027_07 PARTITION OF audit_events
    FOR VALUES FROM ('2027-07-01 00:00:00+00') TO ('2027-08-01 00:00:00+00');
CREATE TABLE audit_events_2027_08 PARTITION OF audit_events
    FOR VALUES FROM ('2027-08-01 00:00:00+00') TO ('2027-09-01 00:00:00+00');
CREATE TABLE audit_events_2027_09 PARTITION OF audit_events
    FOR VALUES FROM ('2027-09-01 00:00:00+00') TO ('2027-10-01 00:00:00+00');

-- Partition-coverage check. Should report at least 12 months of headroom; this
-- is the assertion the monitoring described above must make, and the one the
-- Phase 0 acceptance test checks (see docs/ROADMAP.md).
--
-- SELECT max(upper_bound) AS covered_through,
--        max(upper_bound) - now() AS runway
-- FROM (
--   SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid),
--                        'TO \(''([^'']+)''\)'))[1]::timestamptz AS upper_bound
--   FROM pg_class c
--   JOIN pg_inherits i ON i.inhrelid = c.oid
--   JOIN pg_class p ON p.oid = i.inhparent
--   WHERE p.relname = 'audit_events'
-- ) b;

COMMENT ON TABLE audit_events IS
'R6 event-based audit log. Append-only; a rolling 12-month hot window of monthly
 partitions is queryable here.
 [DECIDED] Retention beyond 12 months: a scheduled job exports the aging
 partition to S3 cold storage, verifies the export, and then DROPs the partition.
 Nothing is hard-deleted — history leaves PostgreSQL, it does not cease to exist.
 Retrieval older than 12 months is an out-of-band request against the S3 archive
 and is deliberately not a product feature.
 [OPEN] That job is an implementation task for a later phase; it does not exist
 yet. Export before drop, verify before drop, idempotent, privileged role only,
 and the drop is itself an audited action.
 Archive manifests live OUTSIDE this schema (S3 inventory / job metadata), not in
 a table here: a manifest of cross-tenant partitions has no meaningful tenant_id,
 and inventing one would mean carving the first exception into R1.';


-- =============================================================================
-- 7. ROW-LEVEL SECURITY  (Rule R1 enforcement)
-- =============================================================================
--
-- R1 (the tenant_id column) and RLS (the policy) are ONE decision. R1 without
-- RLS is just a naming convention; RLS has nothing to key on without R1.
--
-- Every policy below is IDENTICAL in shape:
--
--     ALTER TABLE <t> ENABLE ROW LEVEL SECURITY;
--     ALTER TABLE <t> FORCE  ROW LEVEL SECURITY;
--     CREATE POLICY tenant_isolation ON <t>
--         USING       (tenant_id = app_current_tenant_id())
--         WITH CHECK  (tenant_id = app_current_tenant_id());
--
-- Three things to understand about that shape:
--
--   * ENABLE alone is not enough. Policies do NOT apply to the table's OWNER
--     unless FORCE is also set. Without FORCE, running migrations or an admin
--     script as the owner silently sees and writes everything — and so does the
--     application if it is ever misconfigured to connect as the owner.
--
--   * USING governs what rows are VISIBLE (SELECT/UPDATE/DELETE).
--     WITH CHECK governs what rows may be WRITTEN (INSERT/UPDATE).
--     Both are required. USING alone would let a request insert a row stamped
--     with somebody else's tenant_id — invisible to the writer afterwards, but
--     very much present in the victim's tenant.
--
--   * When app_current_tenant_id() returns NULL (context never set), the
--     comparison is NULL, which is not TRUE, so the policy matches ZERO rows.
--     Fail closed, by construction.
--
-- These are written out explicitly per table rather than generated by a DO loop.
-- A loop is less code but it makes "which tables are protected" a runtime
-- question; explicit statements make it greppable, reviewable in a diff, and
-- directly checkable by the CI lint in §8.
--
-- The R4 master tables (§5) are NOT special-cased here. A lookup table is
-- precisely the kind of table someone reaches for an R1 exemption on — "it's
-- just a list of statuses" — and that instinct is what R4 exists to refuse:
-- these lists are tenant-owned data, so they are tenant-scoped and policy-
-- protected exactly like a lead or a user.
--
-- THE SAME PATTERN MUST BE APPLIED TO EVERY TENANT-SCOPED TABLE ADDED LATER.
-- There are no exceptions in this schema, including `tenants` itself.

-- tenants ---------------------------------------------------------------------
-- Works because tenants.tenant_id is a generated column equal to id, so a tenant
-- can read exactly its own row and no other.
-- NOTE: the subdomain -> tenant_id lookup in routing middleware necessarily runs
-- BEFORE any tenant context exists, so it cannot be served under this policy as
-- crm_app. That one legitimate cross-tenant read must go through a narrowly
-- scoped SECURITY DEFINER function returning nothing but (id, status).
-- [OPEN] That function is not written here — it belongs with the routing work,
-- and it must not be allowed to become a general-purpose god-mode accessor
-- (architecture note Q10).
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON tenants
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- subscriptions ---------------------------------------------------------------
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON subscriptions
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- feature_entitlements --------------------------------------------------------
ALTER TABLE feature_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_entitlements FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON feature_entitlements
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- usage_counters --------------------------------------------------------------
ALTER TABLE usage_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_counters FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON usage_counters
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- overage_line_items ----------------------------------------------------------
ALTER TABLE overage_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE overage_line_items FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON overage_line_items
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- roles -----------------------------------------------------------------------
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON roles
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- permissions -----------------------------------------------------------------
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON permissions
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- role_permissions ------------------------------------------------------------
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON role_permissions
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- users -----------------------------------------------------------------------
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON users
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- user_roles ------------------------------------------------------------------
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON user_roles
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- user_mfa_methods ------------------------------------------------------------
ALTER TABLE user_mfa_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_mfa_methods FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON user_mfa_methods
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- user_recovery_codes ---------------------------------------------------------
ALTER TABLE user_recovery_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_recovery_codes FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON user_recovery_codes
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- sessions --------------------------------------------------------------------
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON sessions
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- lead_sources (R4 master) -----------------------------------------------------
ALTER TABLE lead_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_sources FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON lead_sources
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- lead_statuses (R4 master) ----------------------------------------------------
ALTER TABLE lead_statuses ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_statuses FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON lead_statuses
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- lead_stages (R4 master) ------------------------------------------------------
ALTER TABLE lead_stages ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_stages FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON lead_stages
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- lead_loss_reasons (R4 master) ------------------------------------------------
ALTER TABLE lead_loss_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_loss_reasons FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON lead_loss_reasons
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- deal_stages (R4 master) ------------------------------------------------------
ALTER TABLE deal_stages ENABLE ROW LEVEL SECURITY;
ALTER TABLE deal_stages FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON deal_stages
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- deal_loss_reasons (R4 master) ------------------------------------------------
ALTER TABLE deal_loss_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE deal_loss_reasons FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON deal_loss_reasons
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- audit_events ----------------------------------------------------------------
-- Declared on the partitioned parent; inherited by every partition, including
-- ones created in the future by the partition-management job.
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events FORCE  ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit_events
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());


-- -----------------------------------------------------------------------------
-- 7.1 The application database role
-- -----------------------------------------------------------------------------
-- [DECIDED] This is the most likely way the whole design silently fails.
--   Table owners and superusers bypass RLS. If the application ever connects as
--   the owner or as a superuser, EVERY policy above becomes inert and no error
--   is raised — the app just quietly returns cross-tenant data.
--
--   Therefore: the application connects as crm_app, which
--     * is NOT a superuser
--     * does NOT have BYPASSRLS
--     * does NOT own these tables (migrations run as a separate, higher-
--       privileged role, out of band from request traffic)
--
--   The application MUST additionally assert this at boot and refuse to start if
--   it is false:
--     SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user;
--   Both must be false. This is cheap and it catches the misconfiguration on the
--   first deploy rather than in an incident.
--
-- Uncomment and adapt for the target environment:
--
-- CREATE ROLE crm_app LOGIN PASSWORD '<from AWS Secrets Manager>'
--     NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
-- GRANT USAGE ON SCHEMA public TO crm_app;
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crm_app;
--
-- [DECIDED, R6] The audit log is append-only, enforced by GRANTS, not by
-- convention. Revoke the ability to rewrite history:
-- REVOKE UPDATE, DELETE ON audit_events FROM crm_app;
-- GRANT  SELECT, INSERT ON audit_events TO crm_app;
--   (The archive/partition job runs as a different, privileged role — it is the
--    only thing permitted to DROP a partition, and it must never share a role or
--    a connection with request traffic.)


-- =============================================================================
-- 8. R1 / RLS CONFORMANCE CHECK
-- =============================================================================
-- R1 is a constraint that decays silently: it holds perfectly today and is
-- violated by the third developer who adds a lookup table in a hurry. A
-- constraint that depends on remembering is not a constraint.
--
-- This query is the seed of the CI lint described in the architecture note §10.
-- It returns one row per violation and should return ZERO rows. Wiring it into
-- CI so a non-empty result fails the build should be the first task of Phase 1 —
-- it is far cheaper to add now, with 20 tables, than after 180. Note that the
-- six R4 master tables in §5 needed no change to this query and no new
-- exception — including deal_stages and deal_loss_reasons, added a round later
-- by someone who only had the pattern to copy. That is the test of whether a
-- pattern is actually uniform: the second person to use it changes nothing.
--
-- Note it catches BOTH silent failure modes: a missing tenant_id column, and a
-- tenant_id column with no policy protecting it. The second is the more
-- dangerous of the two, because it looks correct in a schema diagram.
--
-- SELECT c.relname AS table_name,
--        CASE
--          WHEN a.attname IS NULL           THEN 'MISSING tenant_id column (R1)'
--          WHEN a.attnotnull IS NOT TRUE    THEN 'tenant_id is nullable (R1)'
--          WHEN c.relrowsecurity IS FALSE   THEN 'RLS not ENABLEd'
--          WHEN c.relforcerowsecurity IS FALSE THEN 'RLS not FORCEd (owner bypasses)'
--          WHEN p.polname IS NULL           THEN 'no RLS policy attached'
--        END AS violation
-- FROM pg_class c
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- LEFT JOIN pg_attribute a
--        ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnum > 0
--       AND NOT a.attisdropped
-- LEFT JOIN pg_policy p ON p.polrelid = c.oid
-- WHERE n.nspname = 'public'
--   AND c.relkind IN ('r','p')          -- ordinary and partitioned tables
--   AND c.relname NOT LIKE 'audit_events_%'   -- partitions inherit from parent
--   AND c.relname <> 'schema_migrations'      -- migration bookkeeping
--   AND (a.attname IS NULL
--        OR a.attnotnull IS NOT TRUE
--        OR c.relrowsecurity IS FALSE
--        OR c.relforcerowsecurity IS FALSE
--        OR p.polname IS NULL);
--
-- The exception list in that WHERE clause is deliberately TINY and lives in
-- version control, so adding an exception is a visible, reviewable act rather
-- than a silent omission. Note that `tenants` is NOT an exception — the
-- generated tenant_id column in §1 exists precisely so that it does not need to
-- be one.


-- =============================================================================
-- 9. TENANT PROVISIONING SEED  (Rules R2 and R4)
-- =============================================================================
-- Two functions, both called inside the tenant-creation transaction (see §1):
--   9.1  provision_tenant_rbac_defaults  — R2 roles and permission catalogue
--   9.2  provision_tenant_master_data    — R4 sources, statuses, stages, reasons
-- They are separate because they fail, change and get re-run for different
-- reasons: the permission catalogue grows when we ship a feature, the master
-- lists are the tenant's to edit the moment provisioning finishes.


-- -----------------------------------------------------------------------------
-- 9.1 Default roles and permissions (R2)
-- -----------------------------------------------------------------------------
-- [DECIDED, R2] "Flexible default roles" means: sensible defaults ship with every
-- tenant, AND tenants can define their own roles composed from the permission
-- vocabulary. They are not locked to this list.
--
-- USAGE: the caller MUST establish tenant context first, because this function
-- writes through the RLS policies like any other code path:
--     BEGIN;
--     SET LOCAL app.current_tenant_id = '<new tenant uuid>';
--     SELECT provision_tenant_rbac_defaults('<new tenant uuid>');
--     COMMIT;
-- Deliberately NOT written as SECURITY DEFINER — a provisioning function that
-- bypasses RLS is exactly the kind of privileged back door that later gets
-- reused for something it should not be.
--
-- [OPEN] Both lists below are STARTING POINTS, not settled.
--   * The default role set (architecture note Q2) — which roles, and which of
--     them count as "executive" for mandatory 2FA.
--   * The permission catalogue (architecture note Q6) — it will grow with every
--     feature shipped.
--   Changing either after tenants exist requires a backfill, so they are worth
--   settling before Phase 1 ships.

CREATE OR REPLACE FUNCTION provision_tenant_rbac_defaults(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_perm  text;
    v_role  record;
BEGIN
    -- ---- Permission catalogue (the fixed vocabulary) -------------------------
    -- Tenants compose roles OUT OF these; they do not invent new ones. An
    -- open-ended permission vocabulary is unenforceable, because application
    -- code has to check against something known at build time.
    FOREACH v_perm IN ARRAY ARRAY[
        'contacts.read','contacts.create','contacts.update','contacts.delete','contacts.export',
        'deals.read','deals.create','deals.update','deals.delete',
        'activities.read','activities.create','activities.update','activities.delete',
        'reports.read','reports.export',
        'users.read','users.invite','users.update','users.deactivate',
        'roles.read','roles.manage',
        'billing.read','billing.manage',
        'settings.read','settings.manage',
        'audit.read',
        'integrations.read','integrations.manage',
        'api.access'
    ] LOOP
        INSERT INTO permissions (tenant_id, key, resource, action)
        VALUES (
            p_tenant_id,
            v_perm,
            split_part(v_perm, '.', 1),
            split_part(v_perm, '.', 2)
        )
        ON CONFLICT (tenant_id, key) DO NOTHING;
    END LOOP;

    -- ---- Default roles -------------------------------------------------------
    -- requires_2fa = true marks the "executive" tier: 2FA is MANDATORY for these
    -- roles and optional for the rest. owner/admin qualify because they can
    -- change billing, grant roles, and export data — the three things an account
    -- takeover is actually after.
    -- [OPEN] Whether `manager` should also require 2FA is a policy call for the
    -- owner (architecture note Q2).
    FOR v_role IN
        SELECT * FROM (VALUES
            ('owner',     'Owner',      'Full control including billing and tenant deletion.', true),
            ('admin',     'Admin',      'Full control except tenant deletion.',                 true),
            ('manager',   'Manager',    'Manages team members and sees all CRM data.',          false),
            ('member',    'Member',     'Standard frontline user. Full CRM data access.',       false),
            ('read_only', 'Read Only',  'View-only access to CRM data.',                        false)
        ) AS t(key, name, description, requires_2fa)
    LOOP
        INSERT INTO roles (tenant_id, key, name, description, is_system, requires_2fa)
        VALUES (p_tenant_id, v_role.key, v_role.name, v_role.description, true, v_role.requires_2fa)
        ON CONFLICT (tenant_id, key) DO NOTHING;
    END LOOP;

    -- ---- Role -> permission grants -------------------------------------------
    -- owner and admin: everything in the catalogue.
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT p_tenant_id, r.id, p.id
    FROM roles r
    CROSS JOIN permissions p
    WHERE r.tenant_id = p_tenant_id
      AND p.tenant_id = p_tenant_id
      AND r.key IN ('owner','admin')
    ON CONFLICT DO NOTHING;

    -- manager: all CRM data plus user management, but NOT billing or roles.
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT p_tenant_id, r.id, p.id
    FROM roles r
    JOIN permissions p ON p.tenant_id = p_tenant_id
    WHERE r.tenant_id = p_tenant_id
      AND r.key = 'manager'
      AND p.resource IN ('contacts','deals','activities','reports','users')
    ON CONFLICT DO NOTHING;

    -- member: CRM data only. No export — deliberately, because bulk export is
    -- the main exfiltration path and it belongs behind a deliberate grant.
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT p_tenant_id, r.id, p.id
    FROM roles r
    JOIN permissions p ON p.tenant_id = p_tenant_id
    WHERE r.tenant_id = p_tenant_id
      AND r.key = 'member'
      AND p.resource IN ('contacts','deals','activities','reports')
      AND p.action <> 'export'
    ON CONFLICT DO NOTHING;

    -- read_only: read actions on CRM data.
    INSERT INTO role_permissions (tenant_id, role_id, permission_id)
    SELECT p_tenant_id, r.id, p.id
    FROM roles r
    JOIN permissions p ON p.tenant_id = p_tenant_id
    WHERE r.tenant_id = p_tenant_id
      AND r.key = 'read_only'
      AND p.resource IN ('contacts','deals','activities','reports')
      AND p.action = 'read'
    ON CONFLICT DO NOTHING;
END;
$$;

COMMENT ON FUNCTION provision_tenant_rbac_defaults(uuid) IS
'Seeds the R2 default roles and permission catalogue for a newly provisioned
 tenant. System roles (is_system = true) cannot be deleted or re-keyed; tenants
 who want a variant clone one and edit the clone. Custom roles are ordinary rows
 in the same tables with is_system = false.';


-- -----------------------------------------------------------------------------
-- 9.2 Default master data (R4)
-- -----------------------------------------------------------------------------
-- [DECIDED, R4] Every tenant is seeded with a working set of lead sources, lead
-- statuses, lead stages, lead loss reasons, deal stages and deal loss reasons at
-- provisioning, so a new workspace can capture its first lead and work its first
-- deal without configuring anything — the same "defaults ship, tenants
-- customise" shape as R2 roles.
--
-- All seeded rows are is_system = true, which means: renameable, reorderable and
-- deactivatable by the tenant, but NOT deletable and NOT re-codable. Reports and
-- automations key on `code`; letting a tenant delete or repoint a seeded code
-- would break their own saved views, and the failure would surface weeks later
-- as "the dashboard is wrong".
--
-- USAGE — same contract as 9.1, tenant context must be set first, and this is
-- deliberately NOT SECURITY DEFINER:
--     BEGIN;
--     SET LOCAL app.current_tenant_id = '<new tenant uuid>';
--     SELECT provision_tenant_master_data('<same uuid>');
--     COMMIT;
--
-- [OPEN] The exact default lists below are a STARTING POINT (architecture note
--   Q18). Unlike the RBAC defaults, getting these wrong is cheap to correct:
--   they are tenant-editable rows, so a bad default is a rename, not a
--   migration. That asymmetry is most of the point of R4.

CREATE OR REPLACE FUNCTION provision_tenant_master_data(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- ---- Lead sources --------------------------------------------------------
    INSERT INTO lead_sources (tenant_id, code, label, sort_order, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order, true
    FROM (VALUES
        ('web_form',       'Web Form',        10),
        ('referral',       'Referral',        20),
        ('phone_inbound',  'Inbound Call',    30),
        ('email_campaign', 'Email Campaign',  40),
        ('paid_ads',       'Paid Advertising',50),
        ('social',         'Social Media',    60),
        ('event',          'Event',           70),
        ('partner',        'Partner',         80),
        ('cold_outreach',  'Cold Outreach',   90),
        ('other',          'Other',          100)
    ) AS v(code, label, sort_order)
    ON CONFLICT (tenant_id, code) DO NOTHING;

    -- ---- Lead statuses -------------------------------------------------------
    -- Exactly one is_default row, enforced by a partial unique index. Terminal
    -- statuses stop follow-up automation and drop out of "open work" counts.
    INSERT INTO lead_statuses (tenant_id, code, label, sort_order,
                               is_default, is_terminal, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order,
           v.is_default, v.is_terminal, true
    FROM (VALUES
        ('new',         'New',          10, true,  false),
        ('contacted',   'Contacted',    20, false, false),
        ('working',     'Working',      30, false, false),
        ('nurturing',   'Nurturing',    40, false, false),
        ('qualified',   'Qualified',    50, false, false),
        ('unqualified', 'Unqualified',  60, false, true),
        ('converted',   'Converted',    70, false, true)
    ) AS v(code, label, sort_order, is_default, is_terminal)
    ON CONFLICT (tenant_id, code) DO NOTHING;

    -- ---- Lead stages ---------------------------------------------------------
    -- stage_type is the only part the product reads. Note won = 100% and
    -- lost = 0% probability, which the lead_stages_terminal_probability CHECK
    -- also enforces.
    INSERT INTO lead_stages (tenant_id, code, label, sort_order,
                             stage_type, probability_pct, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order,
           v.stage_type, v.probability_pct, true
    FROM (VALUES
        ('new_lead',      'New Lead',      10, 'open', 10),
        ('qualification', 'Qualification', 20, 'open', 25),
        ('proposal',      'Proposal',      30, 'open', 50),
        ('negotiation',   'Negotiation',   40, 'open', 75),
        ('closed_won',    'Closed Won',    50, 'won',  100),
        ('closed_lost',   'Closed Lost',   60, 'lost', 0)
    ) AS v(code, label, sort_order, stage_type, probability_pct)
    ON CONFLICT (tenant_id, code) DO NOTHING;

    -- ---- Lead loss reasons ---------------------------------------------------
    -- 'other' requires a note: an "Other" bucket with no detail is a reason that
    -- teaches nobody anything, and it reliably becomes the largest category.
    INSERT INTO lead_loss_reasons (tenant_id, code, label, sort_order,
                                   requires_note, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order, v.requires_note, true
    FROM (VALUES
        ('price',              'Price',                10, false),
        ('timing',             'Bad Timing',           20, false),
        ('lost_to_competitor', 'Lost to Competitor',   30, true),
        ('no_budget',          'No Budget',            40, false),
        ('no_response',        'Went Unresponsive',    50, false),
        ('not_a_fit',          'Not a Fit',            60, false),
        ('duplicate',          'Duplicate Record',     70, false),
        ('other',              'Other',                80, true)
    ) AS v(code, label, sort_order, requires_note)
    ON CONFLICT (tenant_id, code) DO NOTHING;

    -- ---- Deal stages ---------------------------------------------------------
    -- [Q17] The SALES pipeline, seeded separately from the lead pipeline above
    -- and deliberately DIFFERENT from it — a deal starts where a lead ends. If
    -- these two lists were seeded identically it would be a signal that they did
    -- not need to be two tables; they are not identical, which is the point.
    -- stage_type is the only part the product reads: won = 100%, lost = 0%, as
    -- the deal_stages_terminal_probability CHECK also enforces.
    INSERT INTO deal_stages (tenant_id, code, label, sort_order,
                             stage_type, probability_pct, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order,
           v.stage_type, v.probability_pct, true
    FROM (VALUES
        ('qualification',  'Qualification',  10, 'open', 20),
        ('needs_analysis', 'Needs Analysis', 20, 'open', 30),
        ('proposal_sent',  'Proposal Sent',  30, 'open', 50),
        ('negotiation',    'Negotiation',    40, 'open', 75),
        ('contract_sent',  'Contract Sent',  50, 'open', 90),
        ('closed_won',     'Closed Won',     60, 'won',  100),
        ('closed_lost',    'Closed Lost',    70, 'lost', 0)
    ) AS v(code, label, sort_order, stage_type, probability_pct)
    ON CONFLICT (tenant_id, code) DO NOTHING;

    -- ---- Deal loss reasons ---------------------------------------------------
    -- [Q17] Commercial post-mortem reasons for a QUALIFIED deal, distinct from
    -- the lead loss reasons above (which are about whether an opportunity was
    -- ever real). 'lost_to_competitor' and 'missing_capability' require a note:
    -- "we lost to a competitor" without naming which one, and "we were missing a
    -- capability" without naming which, are the two data points that most often
    -- get collected and then cannot be acted on.
    INSERT INTO deal_loss_reasons (tenant_id, code, label, sort_order,
                                   requires_note, is_system)
    SELECT p_tenant_id, v.code, v.label, v.sort_order, v.requires_note, true
    FROM (VALUES
        ('price',               'Price',                     10, false),
        ('lost_to_competitor',  'Lost to Competitor',        20, true),
        ('missing_capability',  'Missing Capability',        30, true),
        ('no_decision',         'No Decision / Stalled',     40, false),
        ('budget_withdrawn',    'Budget Withdrawn',          50, false),
        ('timing',              'Timing',                    60, false),
        ('built_internally',    'Chose to Build Internally', 70, false),
        ('other',               'Other',                     80, true)
    ) AS v(code, label, sort_order, requires_note)
    ON CONFLICT (tenant_id, code) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION provision_tenant_master_data(uuid) IS
'Seeds the R4 master/lookup data for a newly provisioned tenant: lead sources,
 lead statuses, lead stages, lead loss reasons, deal stages and deal loss reasons
 — six tables, 46 rows per tenant. The deal masters are separate from the lead
 masters on purpose (architecture note Q17): a lead''s stages are pre-sales
 qualification, a deal''s stages are the sales pipeline itself.
 All seeded rows are is_system = true —
 renameable, reorderable and deactivatable by the tenant, but not deletable and
 not re-codable, because application logic and saved reports key on `code`.
 Retiring a value is is_active = false, never DELETE: historical records keep
 referencing it, and the composite FKs from Phase 1 business objects are
 ON DELETE RESTRICT precisely so that a mistaken deletion fails loudly instead of
 taking the referencing rows with it.';


-- =============================================================================
-- END — Phase 0 schema
--
-- Tables: 20 (tenants, subscriptions, feature_entitlements, usage_counters,
--             overage_line_items, roles, permissions, role_permissions, users,
--             user_roles, user_mfa_methods, user_recovery_codes, sessions,
--             lead_sources, lead_statuses, lead_stages, lead_loss_reasons,
--             deal_stages, deal_loss_reasons, audit_events)
--             + 13 audit_events monthly partitions (2026-09 .. 2027-09), which
--               inherit the parent's tenant_id, RLS and policy and are therefore
--               excluded from the R1 lint's table set rather than exempted.
-- R1 conformance: 20 / 20 carry a NOT NULL tenant_id; 20 / 20 have RLS ENABLEd,
--                 FORCEd, and a tenant_isolation policy attached. No exceptions.
-- R4: 6 master tables (4 lead + 2 deal), zero ENUM types in this schema.
-- R5: custom_attributes jsonb on tenants, users and all 6 master tables;
--     MANDATORY on every CRM business object created in Phase 1.
-- R6: 12 months of audit partition runway pre-created past the current month.
--     The recurring job that extends it is a Phase 1 deliverable and does not
--     exist yet — see the partition-runway note in §6.
--
-- DEFERRED TO PHASE 2, deliberately absent from this file:
--   Q20 — GIN indexes on custom_attributes / audit_events.payload.
--   Q21 — the custom_field_definitions registry that types and validates R5.
-- =============================================================================
