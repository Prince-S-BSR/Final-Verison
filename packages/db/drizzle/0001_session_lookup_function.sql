-- =============================================================================
-- Phase 0 gate — session lookup function
-- Beads issue: Final-Verison-x9u
--
-- WHY THIS EXISTS
--   Session validation has the exact same chicken-and-egg problem the
--   architecture note already identifies for subdomain -> tenant_id
--   resolution (00-phase-0-architecture-note.md §4.2, and the schema comment
--   directly above the `tenants` RLS policy in 0000_phase0_foundation.sql):
--   `sessions` is a tenant-scoped table protected by
--   `tenant_id = app_current_tenant_id()`, but the whole point of looking up
--   a session by its token hash is to DISCOVER the tenant_id — no tenant
--   context can be SET LOCAL before that lookup runs, so a plain SELECT as
--   `crm_app` would match zero rows every time (fail-closed, but unusably
--   so).
--
--   The architecture note's own prescription for this shape of problem is:
--   "a narrowly-scoped read ... through a separate role or a SECURITY
--   DEFINER function that returns nothing but (id, status)" — and flags it
--   as "not written here — it belongs with the routing work" (schema comment
--   above the `tenants` policy). This IS that routing work, applied to
--   sessions instead of the subdomain lookup it was written for. Same shape,
--   same mitigation, not a new architectural decision.
--
-- SCOPE, kept deliberately narrow so this cannot become a general-purpose
-- bypass:
--   * Takes only a token hash (never a raw token, never a tenant_id).
--   * Returns only the columns needed to establish or reject a request's
--     session context (tenant_id, user_id, expiry/revocation/scope) — never
--     ip_address, user_agent, or the token_hash itself.
--   * SECURITY DEFINER, owned by the table owner (not crm_app), with EXECUTE
--     revoked from PUBLIC and granted only to crm_app. It does not accept
--     dynamic SQL of any kind, so it cannot be used for anything beyond this
--     one lookup shape.
CREATE OR REPLACE FUNCTION resolve_session_context(p_token_hash text)
RETURNS TABLE (
    session_id  uuid,
    tenant_id   uuid,
    user_id     uuid,
    expires_at  timestamptz,
    revoked_at  timestamptz,
    scope       text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT id, tenant_id, user_id, expires_at, revoked_at, scope
    FROM sessions
    WHERE token_hash = p_token_hash;
$$;

COMMENT ON FUNCTION resolve_session_context(text) IS
'Narrowly-scoped SECURITY DEFINER lookup used ONLY by the session-context
 middleware to resolve a bearer token to {tenant_id, user_id} before any
 tenant context exists. Mirrors the subdomain -> tenant_id lookup pattern
 already prescribed in the architecture note (§4.2) and the schema comment
 above the tenants RLS policy. Must never be widened to accept arbitrary
 filters or return additional columns — that would turn it into the
 general-purpose bypass both of those notes warn against.';

REVOKE ALL ON FUNCTION resolve_session_context(text) FROM PUBLIC;

-- `crm_app` is provisioned out-of-band, not by this migration (see
-- 0000_phase0_foundation.sql §7.1 — the CREATE ROLE / GRANT block there is
-- commented out for the same reason: role creation is an environment/infra
-- concern, not schema DDL). Grant EXECUTE only if the role already exists,
-- so this migration stays applicable regardless of provisioning order; run
-- the GRANT explicitly as part of the same out-of-band step that creates
-- crm_app if it does not exist yet at migration time.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crm_app') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION resolve_session_context(text) TO crm_app';
    END IF;
END
$$;
