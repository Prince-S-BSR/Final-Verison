# apps/mobile — DORMANT / FROZEN

**Status: DORMANT/FROZEN as of 2026-09-12, per explicit project-owner decision.**

## Why this exists

This workspace originated as "Phase 8 mobile prep" under the now-superseded
[`docs/ROADMAP.md`](../../docs/ROADMAP.md) — a generic 9-phase SaaS roadmap in which Phase 8
was misnamed/miscommunicated as "mobile." See
[`docs/architecture/02-repository-governance-agent-rules-report.md`](../../docs/architecture/02-repository-governance-agent-rules-report.md)
§H.2 for the full history of that conflict.

## Current status

It is retained for **historical/technical reference only**. It is **not** part of BMexa MVP
scope: [`docs/BMEXA_MASTER_SPEC.md`](../../docs/BMEXA_MASTER_SPEC.md) §65 and §86 explicitly
place native mobile apps on the MVP do-not-build list.

**Do not:**
- build features in this workspace
- expand it
- treat it as "the BMexa mobile app"
- migrate BMexa work into it

**Do not delete it either** — it stays as-is, frozen, per explicit instruction.

## Where BMexa's actual mobile-adjacent work lives

BMexa's actual mobile-adjacent direction for MVP is the **responsive/PWA approach** described
in the Master Spec — §14 (Sales Rep mobile experience) and §46–48 (Offline PWA) — which lives
in `apps/web`, not here.
