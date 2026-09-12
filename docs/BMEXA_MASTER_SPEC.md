# BMexa REAL ESTATE CRM — MASTER DEVELOPER HANDOFF v1.0

> Received from the project owner on 2026-09-12 as the controlled handoff from product/requirements/architecture/finance/security/data/UX reviews to the development team. This document is the source of truth for the current MVP unless a requirement is explicitly marked VALIDATE, ASSUMPTION, FUTURE, or DO NOT BUILD. Do not silently convert assumptions into requirements. Do not invent business rules. Do not add features simply because they appear useful.

## 00. FIRST INSTRUCTION TO CLAUDE CODE

DO NOT START CODING IMMEDIATELY.

Before modifying anything:
1. Inspect the existing repository.
2. Identify the current framework and runtime.
3. Identify the existing application structure.
4. Identify the existing landing page.
5. Identify current routes.
6. Identify current authentication.
7. Identify current database configuration.
8. Identify environment variables and secrets configuration.
9. Identify installed dependencies.
10. Identify existing Supabase/database code if present.
11. Identify existing UI/component libraries.
12. Identify existing tests.
13. Identify existing deployment configuration.
14. Identify existing Git branches and working tree state.
15. Identify anything that may be affected by this specification.

DO NOT modify the existing landing page unless explicitly instructed.
DO NOT replace the existing application architecture simply because a different architecture would be preferable.
DO NOT initialize a new project if an existing project already exists.

After inspection, produce a concise REPOSITORY DISCOVERY REPORT including: current stack, current architecture, existing routes, existing database, existing authentication, existing landing page, existing reusable components, existing tests, existing integrations, conflicts with this specification, missing information, recommended next step.

Then STOP and wait for approval if there is a material architectural conflict.

> **Status: this step is complete.** See `docs/architecture/` for the Repository Discovery Report (delivered 2026-09-12) and the Architecture Reconciliation Report that followed it.

## 01. DEVELOPER OPERATING RULES

Claude Code must follow these rules throughout development.

**Rule 1 — Do not invent requirements.** If a business rule is unclear, do not guess. Ask for clarification.

**Rule 2 — Do not weaken security.** Never bypass authentication, authorization, tenant isolation, RLS, audit requirements, or approval controls to make development easier.

**Rule 3 — Do not modify financial history.** Financial records must not be silently overwritten. Corrections must use the appropriate reversal/adjustment mechanism.

**Rule 4 — Do not expose tenant data.** Never trust client-supplied tenant IDs, client-supplied ownership, client-supplied permissions, or client-supplied financial authority. Authorization must be enforced server-side.

**Rule 5 — Do not use privileged database access casually.** A privileged/service-role database connection must NEVER be used as a shortcut for ordinary user operations. If privileged access is genuinely required for a system operation, isolate it, authorize it explicitly, and audit it.

**Rule 6 — Do not silently change architecture.** Claude may refactor implementation details. Claude must ask before changing: core entities, financial rules, booking lifecycle, tenant model, permission model, source-of-truth rules, security boundaries, core workflows.

**Rule 7 — Do not build future features early.** A feature appearing in the Phase 8–11 roadmap is NOT permission to implement it during MVP.

**Rule 8 — Tests are part of development.** Every critical business rule must have automated tests.

**Rule 9 — Never hide failures.** If an operation fails, show the user an actionable state and preserve data integrity.

**Rule 10 — Prefer simple architecture.** Do not introduce microservices, Kubernetes, dedicated search infrastructure, event buses, or other infrastructure merely because the product is described as "enterprise." Use the simplest architecture that safely satisfies the requirement.

## 02. PRODUCT DEFINITION

BMexa is a vertical SaaS platform for real-estate builders/developers and their sales ecosystem. The primary product is a REAL ESTATE SALES EXECUTION ENGINE.

It is NOT intended to be: construction ERP, HR system, payroll system, full accounting ERP, general-purpose CRM for every industry, payment gateway, escrow system, AI voicebot platform.

The product focuses on: leads, sales execution, inventory, pricing, booking, approvals, payments/receipts, brokerage/CP workflows, customer support, selected customer portal functionality, operational reporting.

## 03. PRIMARY USERS

**Builder-side users:** Super Admin, Builder Admin, CEO / Promoter, VP / Sales leadership, Sales Head, Project Head / Site Head, Sales Rep, Helpdesk, Sales Support, Accounts, Customer Support.

**External users:** Channel Partner firm principal, CP sub-agent, Customer / Buyer.

Different roles must see different information and actions. Never solve permissions by simply hiding buttons in the frontend.

## 04. MULTI-TENANCY

Tenant isolation is a foundational requirement. A tenant represents an isolated business environment. The system must prevent Tenant A from accessing Tenant B data.

This applies to: normal application requests, server actions, APIs, database queries, search, files, exports, background jobs, notifications, analytics, administrative tools.

Do not trust a `tenant_id` supplied by the browser. The authenticated identity and authorization context must determine tenant access. Database-level RLS is a required security layer where applicable. Application authorization must complement—not replace—database security.

## 05. IMPORTANT TENANT MODEL

There are two different CP business models.

**Phase 1 CP model:** A Channel Partner is empanelled with a Builder. The CP operates within the Builder's ecosystem with restricted access to Builder-controlled information. The CP must NOT receive unrestricted Builder-tenant access.

**Future Paid Broker SaaS:** A Broker Firm can later become its own paying SaaS tenant. That is a separate product model.

Do not confuse Builder-empanelled CP with Paid Broker SaaS Tenant. This distinction must be preserved architecturally.

## 06. CANONICAL DATA MODEL

The system must avoid duplicating the same real person unnecessarily. Core conceptual entities include:

- **Tenant** — Top-level isolated business environment.
- **User** — Authenticated system identity.
- **Employee** — Builder-side organizational identity and employment record. Employee history must survive role changes.
- **Person** — Canonical human identity within the appropriate tenant/business boundary. A Person may participate in different contexts. Do not create separate copies of the same individual simply because their context changes.
- **Sales Lead** — A relationship between a Person, Project, and sales process. A Lead is NOT merely a status value on Person. The Sales Lead relationship must exist as its own business record.
- **Customer** — Customer is primarily a business context. A Person associated with a confirmed booking can be presented as a Customer. Do not create unnecessary duplicate Person and Customer identities unless a genuine business requirement requires it.
- **CP Firm** — Channel Partner organization.
- **CP Profile / Relationship** — Relationship between a CP Person and/or CP Firm and the Builder ecosystem.
- **Project** — Real-estate development/project.
- **Tower** — Project structure.
- **Floor** — Tower structure.
- **Inventory Unit** — Sellable inventory such as apartment, villa, parking, or other explicitly configured sellable stock.
- **Booking Group** — Transaction envelope connecting applicants/co-applicants with inventory. A booking may involve multiple Persons.
- **Price List Version** — Immutable/versioned pricing configuration.
- **Booking Adjustment** — Controlled post-booking modification.
- **Payment Receipt** — Record of money received.
- **Receipt Allocation** — Explicit mapping of received money to a demand/obligation.
- **Demand Letter** — Amount demanded from customer based on defined milestones/obligations.
- **CP Ledger** — Brokerage/commission accounting record for the CP relationship.
- **Audit Event** — Immutable security/business audit record.
- **Assignment Log** — History of lead/CP ownership or assignment changes.
- **Lead Attribution Claim** — Records competing attribution claims for a lead.

## 07. PERSON / LEAD / CUSTOMER RULE

Do NOT implement Person = Lead = Customer as one database record.

Correct conceptual model: Person = identity. Sales Lead = sales relationship/process. Customer = contextual role associated with a transaction.

This distinction is critical. A Person can have multiple leads, interact with multiple projects, become a customer, be an applicant/co-applicant, have historical relationships. Do not destroy historical identity when status changes.

## 08. ORGANIZATIONAL ACCESS

Roles and permissions must support scoped access. Potential scopes include: Global, Region, Project, other explicitly configured organizational scopes.

Do not hardcode access using a giant collection of unrelated boolean fields. Access should be based on: user, role, scope, project/organizational assignment.

Role changes must not destroy historical ownership information.

## 09. LEAD MANAGEMENT

The CRM must support: lead capture, lead assignment, ownership, active handler, follow-ups, site visits, disposition, duplicate detection, CP attribution, clash detection, reassignment, assignment history.

Lead states discussed include: New, Today, Future, Pending, Success, Dump. The exact state machine must be implemented consistently. Do not invent additional statuses unless required.

## 10. LEAD OWNER VS HANDLER

Separate: **Lead Owner** (person responsible for the lead/account relationship) and **Lead Handler** (person currently working the lead). A lead can change handlers without destroying ownership history. All meaningful handovers must be recorded.

## 11. CLASH DETECTION

Clash detection is a core business control. If multiple sources/CPs claim the same prospective customer: record each attribution claim, preserve history, do not expose sensitive competing claims unnecessarily.

Builder-side authorized leadership resolves attribution. Sales Reps should not automatically see sensitive clash information that could influence or manipulate attribution. The UI visibility rule must be enforced by authorization—not merely by hiding a badge.

## 12. OFFLINE LEAD CREATION

A field user may create certain low-risk records while offline. However: a device cannot perform a reliable server-wide duplicate/clash check while disconnected.

Therefore offline lead creation must be treated as PENDING SYNCHRONIZATION. After connectivity returns: synchronize safely, perform duplicate/clash detection, update the lead state, notify the appropriate authorized person if a conflict is found.

Never pretend an offline lead has passed the server-side clash gate.

## 13. LEAD DISPOSITION UX

The primary Sales Rep experience should be action-oriented. Use a simple disposition structure: **Follow-up** (requires next action/date), **Success** (converted), **Dump** (closed without needing follow-up).

The system should avoid unnecessary typing. Where safe, use prefilled values, quick actions, one-tap dispositions, contextual actions. But do not remove confirmations that are necessary for data integrity.

## 14. SALES REP MOBILE EXPERIENCE

The Sales Rep is a high-frequency field user. Optimize for speed, minimal typing, minimal navigation, clear next action, poor connectivity, small-screen use.

Primary home experience: **Action Feed**, prioritizing: (1) Active inventory holds, (2) New leads, (3) Today's follow-ups, (4) Scheduled visits, (5) Overdue actions. Avoid turning the homepage into a giant analytics dashboard.

## 15. INVENTORY UX

Provide two conceptual views: **Grid View** (select tower → localized inventory grid → fast unit selection → unit details/pricing in contextual panel) and **List View** (filter across inventory by budget, configuration, availability, tower, other approved filters). Avoid requiring pinch-and-zoom for core inventory work.

## 16. INVENTORY HOLD

A Sales Rep may temporarily hold one unit for a defined period. Current business requirement: **20 MINUTE HOLD**.

The system must guarantee that concurrent users cannot successfully hold the same unit. This is a database/concurrency requirement. Do NOT implement this merely as a frontend timer. The authoritative hold state must live on the server/database.

The system must correctly handle: simultaneous hold attempts, duplicate requests, expired holds, browser refresh, multiple devices, network failures, stale UI, retry requests, hold extension, booking while hold exists, server/client disagreement.

The UI timer is only a representation of authoritative server state.

## 17. HOLD VS BOOKING

Never confuse VIEWING with HOLD with BOOKING INITIATED with PENDING VERIFICATION with BOOKED. The UI must make these states unmistakably different. A temporary hold does NOT equal a confirmed booking.

## 18. HOLD EXPIRATION

Hold expiry must be determined by authoritative server time. Do not rely on the device clock. When a hold expires: it becomes unavailable to the original holder, inventory becomes available per defined business rules, stale clients must be informed, the user must receive an actionable message.

## 19. HOLD + NETWORK FAILURE

If the network is unavailable: DO NOT allow a new high-risk inventory hold. The UI must clearly show the offline state. The system may allow safe offline work (notes, activity capture, eligible lead creation) but inventory reservation/hold must require reliable server communication.

## 20. BOOKING WORKFLOW

Conceptual lifecycle: **Stage 1 — Booking Initiated** (Sales Rep begins booking process). **Stage 2 — Pending Verification** (required approval/verification outstanding). **Stage 3 — Booked** (required Builder-side verification has completed). Do not mark a booking "Booked" simply because a form was submitted.

## 21. BOOKING FINANCIAL SNAPSHOT

At booking confirmation, preserve the applicable commercial state. The booking must retain an immutable snapshot of relevant information such as applicable price, applicable charges, discounts, PLCs, relevant applicant information, other legally/business-critical booking information. Future price-list changes must not rewrite historical booking economics.

## 22. PRICE LISTS

Price lists are versioned (V1, V2, V3...). A booking references the applicable version/snapshot. Never retroactively change the financial meaning of an existing confirmed booking because a new price list was published.

## 23. DISCOUNTS

Sales Reps must use system-controlled discount mechanisms rather than manually uploading external cost sheets. Possible controls: BSP discount, PLC waiver, parking-related adjustment, other approved commercial adjustments. Discount authority is governed by role/approval rules. Never rely solely on frontend validation — server-side validation must verify the user's authority.

## 24. PARKING / RELATIONAL INVENTORY

Parking is inventory when modeled as a separate sellable inventory unit. Therefore a parking waiver is NOT simply a meaningless boolean if the parking itself is a relational inventory record. The commercial adjustment must correctly represent what happened to the parking/inventory relationship. Do not create fake financial states merely to satisfy a checkbox.

## 25. BOOKING AMENDMENTS

Original booking history must remain preserved. Post-booking changes are represented as controlled adjustments/amendments. Never overwrite the original approved booking state in a way that destroys auditability. Every amendment must have: actor, reason, time, affected information, approval where required, resulting state.

## 26. UNIT TRANSFERS

A unit transfer requires special treatment. The previous design concept was: old booking → new booking → financial transfer/reconciliation. However: UNIT TRANSFER MUST NOT AUTOMATICALLY BE TREATED AS A NORMAL CANCELLATION FOR CP CLAWBACK.

If a customer changes from one unit to another, the financial and brokerage consequences must be explicitly determined. The system must distinguish genuine cancellation from approved unit transfer/upgrade/downgrade. Do not create an automatic CP clawback merely because an old unit record is technically closed. This is a CFO validation requirement before production financial logic is finalized.

## 27. PAYMENTS

The CRM is NOT a full accounting ERP. The MVP should track operational payment information necessary for the defined sales/collection workflow. It must distinguish money received from money allocated to a specific demand/obligation.

## 28. UNALLOCATED CASH

A received payment may initially be recorded as UNALLOCATED / UNAPPLIED FUNDS. It must not automatically be assigned to an invoice/demand without the necessary information. Later: Payment Receipt → Receipt Allocation → Demand. This preserves reconciliation integrity.

## 29. RECEIPTS

Receipt records are financially important. Do not silently delete or overwrite a receipt. If a correction is needed, use an appropriate reversal/adjustment process. Do not build a full double-entry accounting ERP.

## 30. DEMANDS

The system may generate demand information based on configured milestones. Bulk demand generation is a valid requirement. Do not confuse demand tracking with a complete accounting system.

## 31. CUSTOMER LEDGER

For MVP: the CRM may track operational receipt/demand relationships. It is NOT required to become the Builder's complete accounting system. External accounting/ERP systems such as Tally may remain the final accounting system of record where appropriate. Do not duplicate an entire accounting ERP.

## 32. CP COMMISSION

The CP workflow must support: commission/brokerage entitlement, milestone-based eligibility, invoice submission when eligible, Accounts review, payout, TDS information, reversal/clawback where legitimately applicable. The exact legal/tax treatment must be validated separately. Do not make unsupported legal claims.

## 33. CP CLAWBACK

If a legitimate cancellation creates a recoverable CP overpayment: the CP ledger may become negative. Future eligible payouts may be reduced to recover the amount. However: UNIT TRANSFERS MUST BE DISTINGUISHED FROM TRUE CANCELLATIONS. Do not blindly apply clawback logic to every closed booking.

## 34. TDS

The system must support recording the TDS amount applicable to a CP payout. If manual TDS entry is permitted, the system must make the financial relationship explicit: Gross Commission − TDS = Net Payable. Do not allow the displayed net payable to silently disagree with the ledger. Tax/legal rules must be validated before production.

## 35. CANCELLATIONS / REFUNDS

MVP does NOT implement automated payment-gateway refunds or escrow. Refund/forfeiture processes may remain controlled manually/offline. However: the CRM must still preserve the appropriate business state and inventory consequences. "Handled offline" does NOT mean destroy history or ignore the transaction.

## 36. CUSTOMER PORTAL

Customer portal is not the MVP accounting ERP. For the initial customer portal: customer access, read-only sensitive profile where required, support requests, approved project/construction updates. Customer financial ledger visibility should NOT be introduced unless explicitly approved.

## 37. CUSTOMER PROFILE CHANGES

The customer should not freely modify legally sensitive identity information if doing so could compromise document integrity. Where required: Customer → Support Request → Authorized staff update. Do not unnecessarily make the customer experience bureaucratic for harmless profile information.

## 38. CONSTRUCTION FEED

Future/approved post-sale experience may include tower-specific updates, photographs, construction milestones, broadcast updates to relevant buyers. This must be scoped carefully. Do not turn it into a social network.

## 39. CHANNEL PARTNER PORTAL

The CP should be able to see relevant lead information, attribution information, pipeline status, commission status, eligibility, invoice status. Do not expose Builder-internal sensitive information.

## 40. CP INVOICE ELIGIBILITY

The UI may clearly indicate that an invoice cannot yet be submitted (e.g. "Waiting for required payment milestone"). Once the business condition is satisfied, invoice submission becomes available. The UI lock must correspond to server-side authorization. Never rely on a greyed-out button as the actual security control.

## 41. CP SUB-AGENTS

A CP firm principal may invite/manage sub-agents within the approved CP relationship. The system must preserve: Parent CP Firm → Principal → Sub-Agent relationships. Do not accidentally give a sub-agent principal-level permissions.

## 42. HELPDESK EXPERIENCE

Helpdesk needs fast capture during busy launch periods. Target workflow: name, limited phone identifier where appropriate, CP/source, quick registration, summon/assign appropriate Sales Rep. Do not make the helpdesk complete the entire CRM profile before the lead can enter the queue.

## 43. HELP DESK PENDING ENRICHMENT

If a field Sales Rep is responsible for enriching a lead later, the system can maintain a pending enrichment queue. This should create accountability without blocking urgent sales activity.

## 44. CP WALK-IN EDGE CASE

If an unknown CP sub-agent arrives and cannot immediately be matched to an existing profile: provide a temporary/manual capture mechanism. Do not block the Helpdesk workflow. The temporary information must be clearly marked as unverified and later reconciled.

## 45. OMNI-SEARCH

Desktop users should have persistent search. Search can locate relevant entities: Person, Lead, Booking, CP, Ticket, other authorized records. Search must be tenant-safe, permission-aware, role-aware, sensitive-data aware. Search must NEVER become a side door around authorization — a user who cannot access a booking directly must not discover it through search. Start with the simplest search architecture capable of meeting requirements. Do not introduce a dedicated search engine unless actual scale/performance requirements justify it.

## 46. OFFLINE PWA

Offline capability is selective. Safe/eligible offline actions: notes, low-risk activity, selected lead capture. High-risk actions requiring connectivity: inventory hold, booking confirmation, high-risk discount approval, financial confirmation, other actions requiring authoritative current state. Offline data must be minimized. Do not store sensitive information locally unless there is a clear requirement and security design.

## 47. OFFLINE SYNC

Every queued offline operation needs a safe identity. The synchronization system must handle duplicate requests, retry, server rejection, conflicts, stale data, authentication expiry, revoked permissions, partial failure, user feedback. An operation must not execute three times merely because the client retried three times. Use idempotent operation design where required.

## 48. OFFLINE UI

Use a clear network status indicator. When offline: explain what is still available, disable actions that require authoritative server state, explain why they are unavailable, show pending synchronization state. Do not merely display a generic "offline" icon.

## 49. MISSED-CALL AUTO LOGGING

Desired UX: Call → return to application → suggest Not Connected / No Answer / Follow-up Tomorrow. This is a usability optimization. Exact phone/call-state detection depends on browser/device capabilities. VALIDATE TECHNICALLY BEFORE PROMISING EXACT BEHAVIOR. Do not build fragile device-specific behavior merely to satisfy a two-tap target.

## 50. APPROVAL UX

Approvals should be fast and contextual. Sales leadership may receive approval cards: approve, reject, counter/request modification where appropriate. But server-side authorization must verify that the approver actually has authority.

## 51. EXECUTIVE EMAIL APPROVAL

Email approval for high-risk operations such as data exports is NOT yet an unconditional implementation rule. Convenience must not override security. If implemented, the mechanism must address: authenticated identity, short-lived authorization, replay prevention, approval context, exact scope, expiry, revocation, audit, compromised/forwarded email. A link must not function as an unrestricted bearer token that can approve sensitive operations for anyone who obtains it. VALIDATE WITH CISO / SOFTWARE ARCHITECT BEFORE PRODUCTION.

## 52. EXPORT CONTROL

Bulk exports are sensitive. The system must control who can request exports, control who can approve exports, log the request, log the approval/rejection, preserve scope, ensure exported data respects permissions, audit the resulting export. Do not assume "two-man rule" is enough without authorization checks.

## 53. SUPPORT ACCESS

Support engineers should not automatically have unrestricted access to customer PII. Where support access is necessary: Builder-authorized access, limited scope, time limitation, audit, visible support/access mode. The exact PIN mechanism remains subject to security architecture validation. Never treat a PIN as a substitute for authorization.

## 54. AUDIT

Important business/security actions must be auditable. Audit should capture: actor, action, time, target, relevant before/after values, system/human origin, authorization context where appropriate. Do NOT blindly "log everything." Audit must remain useful, queryable, secure, cost-conscious, tamper-resistant.

## 55. AUDIT PARTITIONING

Do NOT force 12 months of PostgreSQL partitions into Phase 0 merely because it appeared in an earlier proposal. Start with a correctly indexed audit architecture. Introduce partitioning when actual volume and operational requirements justify it. If partitioning becomes necessary, implement it deliberately with tested migration/retention procedures.

## 56. SOFT DELETE / RETENTION

Business records should not be casually destroyed. However, "Never execute DELETE anywhere" is NOT itself a sufficient data-retention policy. The implementation must distinguish: business deletion, archival, PII removal, legal retention, user deactivation, tenant closure, test data, system maintenance. The correct retention/deletion policy must be validated with Legal/Compliance.

## 57. USER DEACTIVATION

When an employee leaves: do not destroy historical records, preserve historical actor identity, deactivate access, identify owned/unassigned records, create appropriate assignment history, allow authorized management to reassign work. Never rewrite history as if the employee never existed.

## 58. NOTIFICATIONS

The product should avoid notification spam. Prefer action feeds, grouped reminders, relevant approval queues, scheduled reminders rather than dozens of independent notifications. The escalation concept (reminder before scheduled call, escalation for missed follow-ups, manager visibility when appropriate) must be implemented only where it genuinely improves execution. Do not create notification noise.

## 59. BRAND / UI

Existing BMexa brand identity: Deep Emerald `#0A3121`, Golden Amber `#E2981F`, White `#FFFFFF`. Use the existing design system/landing page as the visual source of truth where applicable. Do not redesign the existing landing page. For the CRM: mobile-first, clean, fast, action-oriented, enterprise-grade, minimal unnecessary complexity.

## 60. UX PRINCIPLE

The internal system may be complex. The user experience should not expose unnecessary complexity. Principle: SOPHISTICATED BACKEND + SIMPLE FRONTEND, NOT sophisticated backend + complicated frontend.

## 61. ERROR UX

Never show meaningless errors such as "Error 500." Prefer e.g. "Hold failed. Unit 402 was just booked by another user. Return to inventory." Every important failure should tell the user: (1) what happened, (2) what did NOT happen, (3) what they can do next.

## 62. SECURITY / UX PRINCIPLE

Security restrictions must be understandable. If an action is unavailable, explain why (e.g. "Inventory hold requires an internet connection because availability must be confirmed in real time."). Do not simply disable a button with no explanation.

## 63. DASHBOARDS

Do not build dashboards merely because dashboards are expected in enterprise software. Every dashboard element should answer: "What decision or action does this enable?" Prioritize action queues, exceptions, approvals, operational bottlenecks, inventory, sales execution.

## 64. MVP BOUNDARY

The first working product should focus on the core Builder sales engine. Core MVP areas: (1) Authentication, (2) Tenant isolation, (3) Users/roles, (4) Projects, (5) Inventory, (6) Pricing, (7) Leads, (8) Lead assignment, (9) Clash detection, (10) Sales activity/follow-up, (11) Inventory hold, (12) Booking, (13) Booking approval/verification, (14) Booking financial snapshot, (15) Basic receipt/payment tracking required for the workflow, (16) CP relationship/workflow, (17) Basic commission/eligibility workflow where validated, (18) Audit, (19) Basic reporting, (20) Mobile-first Sales Rep experience, (21) Desktop Helpdesk/Sales management experience. Exact scope must be validated against dependencies during implementation.

## 65. FUTURE FEATURES — DO NOT BUILD DURING MVP

Unless explicitly promoted into the active phase, do NOT build: construction ERP, BOQ, HR, payroll, full double-entry accounting, payment gateway refund automation, escrow, AI outbound voicebot, 2 AM AI calling, 5-digit IVR system, resale marketplace, rental marketplace, full broker SaaS, AI call transcription, LLM form filling, prepaid API/telephony wallet, native mobile wrapper, advanced telephony routing, advanced analytics infrastructure. Future architecture should not prevent these possibilities, but future features must not contaminate MVP unnecessarily.

## 66. FUTURE PAID BROKER PRODUCT

A later phase may support: Broker Firm as its own SaaS tenant, multi-builder project catalogue, broker CRM, resale, rental, matching. Do not build this merely because the architecture can support it.

## 67. ARCHITECTURAL DIRECTION

The system should initially prefer a simple, coherent architecture. A modular monolith is acceptable/preferred unless actual requirements prove otherwise. Keep business domains clearly separated. Do not introduce microservices merely for appearance. Potential future separation should be possible if justified by scale.

## 68. TRANSACTION BOUNDARIES

Strong consistency is particularly important for: inventory holds, booking confirmation, financial snapshots, receipt creation, receipt allocation where appropriate, critical commission state transitions, authorization-sensitive mutations. Do not use asynchronous/eventual consistency where it could create double bookings or financial corruption. Asynchronous processing is appropriate for non-critical activities: notifications, emails, WhatsApp, report generation, large exports, document processing.

## 69. API PRINCIPLES

Business APIs must be designed for: authentication, authorization, validation, idempotency, safe retries, pagination, clear errors, rate limiting where required, auditing where appropriate. A repeated request must not accidentally create repeated financial/business transactions.

## 70. DATABASE PRINCIPLES

Database design must prioritize: referential integrity, appropriate constraints, transaction integrity, tenant isolation, indexing, historical integrity, safe migrations. Do not put business-critical rules exclusively in frontend code. Do not use JSON fields simply to avoid proper relational modeling when relationships matter.

## 71. FILE STORAGE

Sensitive documents must be treated as protected assets (KYC, booking documents, agreements, receipts, invoices). Access must be authorized. Do not expose permanent public URLs for sensitive documents. The exact storage/security architecture should be chosen during technical architecture review.

## 72. INTEGRATIONS

External integrations (WhatsApp, email, telephony, accounting exports) must never become a single point of failure for core CRM integrity. If an external provider fails, the core CRM should remain internally consistent. Retries must not duplicate business transactions.

## 73. OBSERVABILITY

The development system must make it possible to diagnose: failed booking, failed hold, failed synchronization, failed notification, failed background job, authorization failure, database failure. Use appropriate logs, metrics, error tracking, audit records. Do not expose sensitive customer information unnecessarily in logs.

## 74. BACKUPS / RECOVERY

Production architecture must include a practical backup and recovery strategy: backup frequency, point-in-time recovery where needed, recovery objectives, restore testing. Do not claim enterprise reliability without proving restore capability.

## 75. PERFORMANCE

Do not optimize for imaginary scale. Identify real scaling dimensions: tenants, users, leads, inventory, bookings, receipts, audit records, documents, concurrent users. Build sensible indexes and architecture first. Scale infrastructure when evidence requires it.

## 76. COST CONTROL

Prefer managed infrastructure where it reduces operational burden. But do not buy enterprise infrastructure that has no current purpose. Avoid premature Kubernetes, microservices, dedicated search clusters, data warehouses, event streaming infrastructure unless requirements justify them.

## 77. PHASE 0 — FOUNDATION

Expected areas: existing-project integration, authentication, tenant model, authorization, database foundation, RLS, roles/permissions, basic audit, migrations, testing framework, environment configuration, error handling, basic observability.

**PHASE 0 GATE.** Do NOT move into business-critical development until automated tests demonstrate: (1) Tenant A cannot access Tenant B data. (2) Unauthorized users cannot perform restricted actions. (3) Server-side authorization cannot be bypassed through manipulated request payloads. (4) Authentication/session behavior works as intended. (5) Database migrations are reproducible. (6) Critical security assumptions are tested.

## 78. PHASE 1 — ORGANIZATION / USERS

Build: Builder/company setup, organization profile, users, employees, roles, permissions, organizational scope. Do not hardcode the entire permission model into individual UI components.

## 79. PHASE 2 — PROJECT / INVENTORY / PRICING

Build: projects, towers, floors, inventory, inventory status, bulk inventory import, price-list versions, charge heads, applicable commercial adjustments. The inventory model must support future booking concurrency requirements.

## 80. PHASE 3 — LEADS / SALES

Build: lead capture, Person relationship, Sales Lead, assignment, ownership, handler, follow-ups, site visits, disposition, duplicate detection, clash engine, assignment history, Helpdesk workflow. Offline lead capture may be introduced with explicit pending-sync behavior.

## 81. PHASE 4 — CP PROGRAMME

Build the Builder-empanelled CP experience: CP firms, CP users, sub-agents, lead/source relationships, approved portal access, relevant pipeline visibility, marketing collateral where required. Do not turn CPs into independent SaaS tenants at this stage.

## 82. PHASE 5 — BOOKING / HOLD / COMMERCIALS

Build: real-time inventory hold, 20-minute hold, server-authoritative expiry, booking initiation, pricing snapshot, discount approval, booking verification, KYC/document workflow, booking adjustments. Payment/receipt primitives required by the booking workflow must be introduced at the correct dependency point. Do not artificially delay required foundational entities simply because their broader module is later.

## 83. PHASE 6 — COLLECTIONS / CP PAYABLE

Build: demands, receipts, unallocated cash, receipt allocation, CP commission eligibility, CP invoice workflow, TDS recording, payout status, validated clawback logic. All financial behavior must be tested against edge cases.

## 84. PHASE 7+ — POST-SALE / CUSTOMER

Later: customer portal, support tickets, construction updates, tower feeds, customer communications. Do not expose financial information that has not been explicitly approved.

## 85. LATER PRODUCT EXPANSION

Future phases may include: Broker SaaS, Resale, Rental, Matching, Advanced analytics, WhatsApp Business API, Telephony, AI transcription, AI form assistance, Native application. These are future scope.

## 86. ABSOLUTE DO-NOT-BUILD LIST FOR MVP

Claude Code must NOT build these unless explicitly authorized: full accounting ERP, double-entry accounting, automated refund system, escrow, construction ERP, BOQ, HR, payroll, AI voicebot, IVR PIN system, resale marketplace, rental marketplace, paid Broker SaaS, AI transcription, LLM auto-form filling, prepaid telephony wallet, native app, unnecessary microservices, unnecessary search infrastructure, unnecessary event infrastructure.

## 87. KNOWN VALIDATION ITEMS

Not automatically rejected; require validation before being treated as final architecture: (1) Executive email approvals — validate security architecture. (2) Missed-call auto logging — validate actual browser/device capabilities. (3) Offline PWA depth — validate which data/actions can safely operate offline. (4) Exact support PIN mechanism — validate against CISO requirements. (5) CP clawback treatment — validate cancellation vs transfer semantics with finance/legal stakeholders. (6) TDS behavior — validate applicable tax/business rules. (7) Customer portal financial visibility — keep restricted until explicitly approved. (8) Search infrastructure — start simple and scale based on evidence. (9) Audit partitioning — do not implement premature partitioning.

## 88. CLAUDE AUTONOMY MATRIX

**CLAUDE MAY DECIDE** without asking, provided the decision does not change product behavior: component names, folder structure, internal helper functions, test organization, code formatting, minor refactoring, accessibility implementation details, non-functional UI polish, sensible indexing where it does not alter semantics, ordinary developer tooling.

**CLAUDE MUST ASK BEFORE DECIDING:** changing canonical entities, changing relationships, changing booking lifecycle, changing financial logic, changing CP commission logic, changing tenant architecture, changing RLS model, changing authorization rules, changing authentication architecture, adding major external dependencies, introducing a major infrastructure component, changing offline business behavior, changing source-of-truth rules, changing audit requirements.

**CLAUDE MUST NEVER DO WITHOUT EXPLICIT AUTHORIZATION:** disable RLS, bypass authorization, expose another tenant's data, use privileged database access as a normal CRUD shortcut, modify financial history silently, remove audit controls to make code easier, weaken authentication, expose sensitive documents publicly, invent business rules, add major future features, silently change the MVP boundary, delete the existing landing page, replace the existing application without approval.

## 89. DEVELOPMENT WORKFLOW

Use Git properly. Before development: inspect current branch, inspect working tree, identify existing changes, do not destroy unrelated work. Use focused branches for meaningful phases/features. After completing a meaningful unit: (1) run tests, (2) inspect changes, (3) verify security, (4) verify previous functionality, (5) commit, (6) push when appropriate. Do not create enormous undocumented commits.

## 90. PHASE GATES

Each phase must have: requirements checklist, implementation checklist, automated tests, security tests, regression tests, UX verification, data-integrity verification, acceptance criteria. Do not proceed merely because the code "works on the happy path."

## 91. CRITICAL TEST AREAS

The test suite must eventually cover: Multi-tenancy (tenant isolation), Authorization (role/scope enforcement), Inventory (concurrent holds), Hold expiration (correct release), Booking (correct lifecycle), Pricing (correct version/snapshot), Discounts (unauthorized discount prevention), Financials (receipt/allocations), Commission (correct eligibility and reversal), Offline (retry/conflict behavior), Search (permission-filtered results), Audit (correct actor/action/history), Files (unauthorized access prevention).

## 92. INVENTORY CONCURRENCY TEST

At minimum, test: two users attempt to hold the same unit concurrently. Expected result: ONLY ONE SUCCESSFUL HOLD, the other receives a clear failure. This must be guaranteed by authoritative server/database behavior, not frontend timing.

## 93. IDEMPOTENCY TEST

Repeat the same request multiple times. Expected: the system does not accidentally create multiple bookings/receipts/leads/commission transactions where the business operation is intended to be singular.

## 94. TENANT SECURITY TEST

Create Tenant A and Tenant B. Attempt to access Tenant B information using altered IDs, altered URLs, altered request payloads, direct API calls, search, files, background operations. Expected: ACCESS DENIED. This must be automated.

## 95. UX ACCEPTANCE PRINCIPLE

Do not optimize only for the number of taps. The correct objective is MINIMUM NECESSARY FRICTION, not minimum possible taps. A one-tap action that creates financial corruption is worse than a three-tap action that prevents it.

## 96. DEFINITION OF DONE

A feature is complete only when: business logic works, authorization works, tenant isolation works, database integrity works, errors are handled, important audit events exist, tests exist, regression tests pass, mobile/desktop UX is appropriate, offline behavior is correct where applicable, no future scope has leaked into the implementation.

## 97. FINAL ENGINEERING PRINCIPLE

When in doubt: STOP AND ASK. Do not make an irreversible business, financial, security, or data-model decision merely to keep coding. The goal is not to produce the maximum amount of code. The goal is to produce a SIMPLE, SECURE, CORRECT, MAINTAINABLE REAL-ESTATE SALES SYSTEM. Build only what is required. Build foundations correctly. Protect historical data. Protect tenant boundaries. Protect financial integrity. Protect the user's workflow. Never sacrifice correctness for development speed.
