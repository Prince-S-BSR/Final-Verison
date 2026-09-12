# Architecture Decision 01A — Lead State Machine (Amendment to AD-01)

**STATUS: DECISIONS RECORDED (2026-09-12) — AD-01 REMAINS NOT APPROVED FOR IMPLEMENTATION**

> The project owner has reviewed this amendment and issued explicit decisions on all five items
> below. Those decisions are recorded in **[§8](#8-product-owner-decision-2026-09-12)** and are now
> the current product-owner position on Q1, Q4, Q7, the sync/verification axis, and the assignment
> axis. **This does not approve AD-01 for implementation.** Q2, Q3, Q5, Q6, Q8–Q16 (AD-01) and
> N-1–N-4 (this amendment) remain open, and no schema, SQL, migration or code may be built until the
> complete model is resolved and approved in writing.

| | |
|---|---|
| **Decision ID** | AD-01A |
| **Amends** | [AD-01 — Lead State Machine](./03-lead-state-machine-decision.md). This document **amends**; it does not replace, supersede or restate AD-01. AD-01 remains the base document and remains **PROPOSED — NOT APPROVED**. |
| **Scope** | Exactly five items: AD-01's **Q1** (the "Pending" question only), **Q4**, **Q7**, and a re-examination of AD-01 §5.1's **sync/verification gate** axis and **assignment state** axis. **Nothing else.** |
| **Explicitly out of scope** | AD-01's Q2, Q3, Q5, Q6, Q8–Q16; every other blocker in [`01-bmexa-architecture-reconciliation.md`](./01-bmexa-architecture-reconciliation.md) (M-2 … M-12 and the rest); the authorization model; the schema. |
| **Authority** | BMexa Master Spec **§88** places *canonical entities*, *relationships*, *offline business behavior* and *source-of-truth rules* in the **MUST ASK BEFORE DECIDING** column. Everything below is a recommendation to the project owner. **Delegation to an architect is not authorization.** |
| **Contains SQL / schema / migration** | **No.** Deliberately — same posture as AD-01. Nothing below names a column, a table, a type or a migration step. |
| **Constraints honoured** | `ENGINEERING_RULES.md` **R4** (masters, not enums; semantics in columns, never in codes), **R6** (event-based append-only audit), **R12** (every claim cites this repository's own documents), and Spec Rule 1 (*do not invent requirements*). |
| **Sources re-read for this amendment** | `docs/BMEXA_MASTER_SPEC.md` §06, §07, §09, §10, §11, §12, §13, §14, §17, §20, §21, §32, §35, §39, §40, §42, §43, §44, §46, §47, §48, §50, §54, §57, §58, §63, §64, §68, §88, §95, §97; `docs/ENGINEERING_RULES.md` R4, R5, R6; `docs/architecture/01-bmexa-architecture-reconciliation.md` §B.3, §D.3, §D.4; `docs/architecture/03-lead-state-machine-decision.md` in full. |

> **How to read this.** The product owner has settled one half of Q1 by direction (Today/Future
> are derived Action Feed buckets, not persisted states) and has expressed a *provisional*
> preference on Q4. This document treats the settled part as settled and the provisional part as
> **an input to be weighed, not a conclusion to be ratified**. Two of the five items below
> ([§4](#4-sync--verification-axis-re-examined-split-or-merged) and
> [§5](#5-assignment-state-axis-re-examined-what-must-actually-be-persisted)) conclude that AD-01
> §5.1 is **wrong** as drafted, and say so.

---

## 0. What this amendment changes, in one table

| AD-01 item | AD-01's position | This amendment's recommendation | Direction |
|---|---|---|---|
| **Q1** — Today / Future | Open | *Settled by the owner:* derived buckets. Not re-argued. | — |
| **Q1** — "Pending" as a 5th lifecycle state | Open; AD-01 §5.1 held it "deliberately undecided" | **Do not add it.** Model "who owes the next move" as a qualifier on the follow-up commitment, not as a lifecycle value. | Narrows AD-01 |
| **Q4** — conversion milestone | Open; three candidates | **Booked (§20 Stage 3).** Confirms the owner's provisional preference, on independent grounds. | Resolves |
| **Q7** — Dump reason vocabulary | Open; "blocks terminal states" | A **three-dimension classification framework** on the reason master. No values proposed. | Resolves the framework; values remain the owner's |
| **Sync / verification gate axis** | One merged axis: Verified · Pending Sync · Sync Conflict | **Split.** AD-01's merged axis contains a correctness defect. | **Corrects AD-01** |
| **Assignment state axis** | Persisted axis: Unassigned · Assigned · Pending Enrichment · Reassignment Pending | **Eliminate the axis.** Minimal persisted footprint is **zero values**. | **Corrects AD-01** |

Net effect on AD-01 §5.1: the recommendation remains **Alternative C — Orthogonal Axes**, but with
**fewer axes and a smaller persisted footprint than AD-01 proposed** — three persisted axes become
two, and the lifecycle axis stays at four values.

---

## 1. Q1 — Is "Pending" a fifth persisted lifecycle state?

### 1.1 What is settled and not re-argued

The product owner has directed that **Today and Future are derived Action Feed buckets, not
persisted lifecycle states**. AD-01 §2.2, §3.3 and §4 argue that position at length and the
reconciliation report reaches it independently at §B.3(a). It is settled. This section does not
revisit it.

### 1.2 Why the settled answer does *not* automatically dispose of "Pending"

This is the load-bearing point, and it is easy to get wrong by inertia.

The argument that dissolves Today and Future is **specific to clock-relative values**: they change
with no actor and no business event, so persisting them requires a nightly job that rewrites
business state (AD-01 §2.2, §4 Alternative A). **That argument does not touch "Pending."** Nothing
about "awaiting a home-loan sanction" is clock-driven; it is a condition entered and left by human
events. So Pending survives the reasoning that kills its list-mates and must be judged on its own
merits. Sweeping it into "derived buckets" alongside Today/Future would be a category error.

### 1.3 What the spec actually says about "Pending"

- **§09** names it, in a list the spec itself describes as *"states discussed include"* — and
  **defines it nowhere.** §09 gives it no entry condition, no exit condition, no semantics, and no
  consequence.
- **Every other occurrence of "Pending" in the spec is a different concept.** §12 *PENDING
  SYNCHRONIZATION* (awaiting the server). §20 Stage 2 *Pending Verification* (a **Booking** state).
  §43 *pending enrichment queue* (a data-completeness obligation). §40 *"Waiting for required
  payment milestone"* (CP invoice eligibility). AD-01 §2.3 already established this collision.
- **§17 is directly relevant and is stated in capitals:** *"Never confuse VIEWING with HOLD with
  BOOKING INITIATED with PENDING VERIFICATION with BOOKED. The UI must make these states
  unmistakably different."* A lead-lifecycle value literally called "Pending", displayed beside a
  booking in Pending Verification and a record in Pending Sync, is the exact confusion §17 forbids
  — not in the letter (§17 is about booking states) but unmistakably in the intent.

**Finding of spec silence, stated explicitly per Rule 1:** the meaning "awaiting
customer/third-party response" is **not in the spec**. It is a plausible and common industry
reading supplied by AD-01 §2.3 as one of three candidate readings, and by this task's framing. The
spec neither supports nor refutes it. Assigning that meaning to §09's word is an *invention of
requirement* unless the owner supplies it.

### 1.4 The test AD-01 itself set, applied

AD-01 §3 states the test for whether two concepts share an axis:

> "Two concepts belong on one axis only if a record can never legitimately be in both at once."

Apply it. Can a lead be simultaneously (i) in Follow-up — actively worked, with a scheduled next
action and date per §13 — and (ii) blocked on a customer or third party?

**Yes, routinely, and this is the normal case rather than the exception.** "Bank has the file;
chase the relationship manager on the 14th" is a lead that has a next action, a date, an
accountable handler *and* an external blocker. The two facts coexist. By AD-01's own test, "who
owes the next move" therefore **fails the mutual-exclusion requirement against Follow-up and is not
a lifecycle value.**

The same conclusion arrives from a second direction. AD-01 §3.7 argues that loss *reasons* must not
become terminal *states*, because folding a reason into the state vocabulary makes the list grow
without bound and turns "add a reason" into "change the state machine". "Why is this lead waiting"
is structurally the same kind of fact: a reason attached to a state, not a state.

### 1.5 The strongest case *for* persisting Pending, stated fairly

Three arguments deserve a real answer, not a dismissal.

1. **§09 names it.** Under a strict reading of *"Do not invent additional statuses unless
   required"* (§09), dropping a named state is a departure from the literal list — though note the
   clause forbids *adding*, not *omitting*, and §09 calls the list "discussed". AD-01 §2.7 shows
   this clause cuts both ways. Still: if the owner's answer is "the six were decided", Pending is
   in, and so is AD-01's Alternative A, and most of this amendment changes.
2. **Management reporting is genuinely different.** "How much of my open pipeline is blocked on
   someone outside my company" is a different question from "how much is being worked", and §63
   demands every dashboard element answer *"what decision or action does this enable"* — chasing a
   bank and chasing a prospect are different actions. **This argument is correct.** What it
   establishes is that the *distinction* must be representable and queryable. It does not establish
   that the distinction must be a lifecycle value.
3. **Rep accountability.** A rep should not be penalised for a lead idling while a bank decides.
   Also correct, and also satisfied by a qualifier: the overdue and productivity queries can
   exclude leads whose blocker is external without the lifecycle axis carrying the fact.

### 1.6 The case *against*, and the failure mode that decides it

- **A "Pending" without a mandatory next action is how leads die silently.** §13 makes the
  next-action date constitutive of Follow-up — the value is not valid without it. If Pending is
  introduced *without* that requirement, it becomes the state reps use to park work: the lead
  leaves every Action Feed bucket (§14), never becomes overdue, and is invisible to §58 escalation.
  That is AD-01 E-19's failure mode promoted from an edge case to a structural feature.
- **A "Pending" *with* a mandatory next action is behaviourally identical to Follow-up** on every
  dimension the system reasons about: non-terminal, appears in the feed, has an overdue condition,
  requires a date, blocks no automation differently. The only difference is *why* — which is a
  qualifier.
- **Vocabulary sprawl.** §09 warns against it, and AD-01 §3.2 warns specifically that the lifecycle
  axis must not *become* a weighted pipeline by accretion. A fifth value justified by "the reason
  for waiting is different" licenses a sixth ("Site Visit Scheduled") and a seventh
  ("Negotiating"), each with the same justification.
- **§17's confusion hazard** (§1.3 above).

### 1.7 Recommendation — Q1 (Pending)

> **RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT APPROVAL**
>
> **Do not add "Pending" as a fifth persisted lifecycle state.** Keep the four-value lifecycle of
> AD-01 §5.1 (**New · Follow-up · Success · Dump**).
>
> **Represent the real distinction as a qualifier on the follow-up commitment — "who owes the next
> move" — not as a lifecycle position.** Conceptually: the scheduled next action carries an
> indication of the party the lead is waiting on (the prospect, a third party such as a lender, an
> internal builder function, or nobody — the handler owes it). Under **R4** the *values* of that
> qualifier are tenant-configurable master rows with a system-owned semantic column; under **R4**
> again, reports and logic branch on the semantic column, never on a code.
>
> **Consequences that follow, and that make this equivalent in power to a fifth state:**
> - The §14 Action Feed gains a *derived* "Blocked / waiting on others" bucket, computed exactly as
>   Today and Overdue are computed — consistent with the owner's settled Q1 direction rather than an
>   exception to it.
> - §58 escalation and rep-productivity queries can exclude externally-blocked leads without the
>   lifecycle axis lying about them.
> - §13's mandatory next-action date is preserved unconditionally, so no lead can be parked out of
>   sight.
> - Adding a fifth lifecycle value later remains cheap under AD-01's Alternative C if the owner
>   decides otherwise; retiring one that has accumulated three years of history is not.

**What the owner is actually being asked to decide:** whether §09's "Pending" was a *decision* (in
which case it is a lifecycle state, and AD-01 §5.3's note applies — Alternative A becomes live) or a
*discussion* of a real operational condition (in which case the above satisfies it without growing
the state machine). **Per Rule 1, the amendment does not guess.**

---

## 2. Q4 — At which booking milestone does a lead become Success?

§13 defines Success as *"converted"* and does not say converted **to what**. §20 gives three
milestones and §17 forbids confusing them.

**Stated up front, per Rule 1:** the spec **never explicitly links** lead Success to a booking
stage. The link is an inference. It is a well-supported inference (§2.2 below) but the owner should
know they are ratifying an inference, not reading back a requirement.

### 2.1 The three candidates evaluated independently

**(a) Booking Initiated — §20 Stage 1, "Sales Rep begins booking process."**

*For:* it is the moment the rep's work ends, which matters on a commission-motivated field team
(§14's whole design premise is that the rep is a high-frequency field user whose flow must not be
obstructed). The lead leaves the follow-up queue at the moment the rep stops working it.

*Against, decisively:* §20 states *"Do not mark a booking 'Booked' simply because a form was
submitted."* That prohibition is written about the booking, but the hazard it names transfers
verbatim — declaring a **lead** converted on form submission is the same fiction relocated one
entity to the left. And the practical consequence is not a tail case: every failed verification
becomes a Success → Follow-up reversal, which under §07 (*"do not destroy historical identity when
status changes"*) and **R6** must be visible in history, and which restates prior conversion
reports. AD-01 E-14 describes this; under (a) it is routine traffic, not an edge case.

**(b) Pending Verification — §20 Stage 2, "required approval/verification outstanding."**

*For:* a middle ground; the booking has been accepted into a process rather than merely typed.

*Against:* this is the weakest of the three and is **dominated**. §20 describes Stage 2 with the
word **outstanding**. Declaring a lead *converted* at the moment the spec calls the deciding step
outstanding is the least defensible available reading of "converted". It carries (a)'s full
reversal exposure — a booking in verification can still be rejected — without (a)'s rep-immediacy
benefit, since the rep has already left the lead behind at Stage 1 either way. And §17's capitalised
instruction that Pending Verification and Booked must be *"unmistakably different"* is undercut if
both mean the same thing about the lead.

**(c) Booked — §20 Stage 3, "required Builder-side verification has completed."**

*For — four independent spec anchors, each doing separate work:*

1. **§06 defines the Customer boundary here, not earlier.** *"Customer — ... A Person associated
   with a **confirmed booking** can be presented as a Customer."* §20 makes "confirmed" mean Stage
   3; §17 forbids treating Initiated as Booked. "Converted" in ordinary sales usage means *the
   prospect became a customer*. **The spec's own prospect→customer boundary therefore sits at Stage
   3**, and aligning lead Success with it is the reading that makes §13 and §06 say the same thing.
   This is the strongest single argument and it is independent of any reporting preference.
2. **§21 anchors commercial reality at confirmation.** *"At booking confirmation, preserve the
   applicable commercial state ... immutable snapshot."* Conversions counted at Stage 3 tie
   one-to-one to financial snapshots; conversions counted earlier do not tie to anything the
   business recognises.
3. **§20's language.** Stage 3 is the only one of the three the spec describes as *completed*.
   Stages 1 and 2 are described as *begun* and *outstanding*.
4. **§68 lists booking confirmation among the strong-consistency operations.** Keying the
   conversion fact on that event lets it inherit that guarantee rather than being a separate,
   weaker, independently-written assertion.

*Against — the honest costs, not minimised:*

1. **The rep's Success is gated on another team's queue.** This is a real behavioural cost on a
   commission-motivated field force and it is the main argument the owner is trading away.
   **Mitigation available entirely within the spec, with no new persisted state:** §14's Action Feed
   and §63's exception-queue posture permit a rep-facing *"my bookings awaiting verification"*
   bucket **derived from the Booking Group's own stage** (§20), which already exists as a canonical
   entity (§06). The rep sees credit-in-flight; the lead's lifecycle axis does not lie. This is
   derivation, exactly consistent with the owner's settled Q1 direction.
2. **Lead velocity now absorbs back-office turnaround.** New → Success time includes verification
   latency the rep does not control. **Mitigation:** AD-01 §8.3's business-level state history with
   *effective time* plus the Booking Group's own stage timestamps make rep-time and
   verification-time separable. This is a reporting design consequence, not a reason to pick a
   different milestone.
3. **The lead's condition between Stage 1 and Stage 3 must be defined.** Under (c) the lead is
   non-terminal but not being "followed up" in the ordinary sense. This is handled by
   [§1.7](#17-recommendation--q1-pending) and is in fact the single most defensible instance of it:
   the lead remains **Follow-up**, with its waiting-on qualifier set to the internal builder
   verification function. The Action Feed must not nag the rep to call a prospect whose file is in
   verification — that is a derivation requirement on the feed, stated here so it is not discovered
   later.
4. **§40 shows commission does *not* depend on this choice.** CP invoice eligibility is keyed on
   *payment milestones* (*"Waiting for required payment milestone"*), not on lead state, and §32
   describes *"milestone-based eligibility"*. So Q4 carries **no CP commission consequence in
   either direction** — which removes what might otherwise have been a decisive constraint, and is
   worth recording so nobody later assumes one exists.

### 2.2 Recommendation — Q4

> **RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT APPROVAL**
>
> **A lead becomes Success at §20 Stage 3 — Booked, after required Builder-side verification has
> completed.**
>
> This **confirms** the owner's provisional preference — but the confirmation is reached from §06's
> Customer boundary, §21's snapshot anchor, §20's completion language and §17's prohibition, and it
> would have been reached the same way had no preference been expressed. The preference was weighed,
> not deferred to.
>
> **The tradeoff the owner is accepting, stated plainly so it is accepted knowingly:** the
> conversion funnel will report *commercially recognised* conversions, and *rep recognition of
> in-flight bookings becomes a separate, derived view*. That is a deliberate choice of reporting
> integrity over rep-facing immediacy, and §95 endorses the posture — *"MINIMUM NECESSARY FRICTION,
> not minimum possible taps"*; a one-tap Success that corrupts the funnel is the reporting analogue
> of the one-tap action §95 refuses.

**Two consequences worth recording, neither of them decided here:**

- **AD-01's Q6 narrows.** Under (c), a lead *cannot* be Success and then fail verification — AD-01
  E-14 becomes unreachable. Q6 (is Success reversible?) therefore survives only for §35
  cancellations of an already-Booked booking, where AD-01 §7 E-15's recommended position (the lead
  stays Success; the cancellation lives on the booking, since §35 requires business state and
  history to be preserved) is unaffected by this amendment. **Q6 remains open and is not resolved
  here.**
- **§26 unit transfers remain unaffected.** AD-01 E-16 already establishes that a transfer must not
  touch the lead's state; §26 and §33 both capitalise the requirement that a transfer is not a
  cancellation. Choosing (c) does not change that and does not weaken it.

---

## 3. Q7 — A semantic framework for Dump / loss reasons

### 3.1 The problem being solved, restated from the sources

- **§13 defines Dump as *"closed without needing follow-up"*** — an operational statement about the
  rep's queue. AD-01 §2.5 establishes that this is **not** a synonym for *lost*.
- **The spec defines no loss-reason vocabulary anywhere** (AD-01 §1.3, confirmed by re-reading).
  The `lead_loss_reasons` rows in the Phase 0 schema arrived from the generic-SaaS seed, and the
  reconciliation report §B.3 already marks them *"Plausible shape; values need review against
  real-estate reality."*
- **AD-01 §9.1 states the reporting consequence:** *"The denominator is contaminated unless Dump is
  decomposed ... Until Q7 defines the reason vocabulary, no defensible source-quality or CP-quality
  report can be produced."*

**This section supplies the framework. It deliberately does not supply the values** — per Rule 1
and per **R4**, the values are tenant-owned rows, and even the seeded defaults are the owner's call.

### 3.2 The design principle: semantics in columns, values in rows

**R4** states the mechanism directly:

> "Semantics live in columns. `lead_stages.stage_type` (`open`/`won`/`lost`) and `is_terminal` exist
> because forecasting must know what a value *means* without reading its code. Reports filter on
> `stage_type`, never on `code`."

Applied here: the **dimensions below are system-owned semantic properties of a Dump reason** —
fixed by the product, the things every report and every piece of logic branches on. The **reason
values themselves are tenant-configurable rows** carrying `code`, tenant-renameable `label`,
`sort_order`, `is_active` (retire without orphaning history), `is_system`, R1's tenant scoping and
R5's `custom_attributes`. A tenant adding a reason chooses its dimension values; a tenant cannot
invent a new dimension, because reports would not know what it meant.

### 3.3 Dimension A — Opportunity validity class *(mandatory)*

The primary dimension, and the one that answers the question the task poses: *was this ever a real
sales opportunity?* Five classes, and **each earns its place by being counted differently in at
least one report** — which is the standard applied, rather than taxonomic neatness:

| Class | Meaning | Conversion denominator | Source / CP quality signal |
|---|---|---|---|
| **Invalid / non-opportunity** | The record does not represent a genuine prospective buyer at all — unusable contact data, not a real person, test data, an enquiry outside the business (jobseeker, vendor, wrong business). | **Excluded** | **Counts against the source.** This is lead-quality failure. |
| **Redundant** | The *prospect* is real; this *record* is not a distinct opportunity — duplicate of an existing lead, merged away, same person re-registered through another channel. | **Excluded** | **Neutral to source volume, but the duplicate rate is itself the signal.** |
| **Commercial loss** | A real prospect who genuinely engaged and did not buy — declined, bought elsewhere, affordability, product/location mismatch, financing failure, timing, went unresponsive after real engagement. | **Included — this is the true loss bucket** | Neutral. Losing real prospects is normal. |
| **Disqualified / ineligible** | Real person, real interest, not transactable *by this builder right now* — nothing in inventory matches the requirement, eligibility or regulatory barrier, outside the served area. | **Included, reported separately** | **Points at product/inventory fit, not at lead quality or rep performance.** |
| **Administrative closure** | Closed for reasons internal to the CRM's operation, not to the prospect — import cleanup, onboarding backfill, record created in error by staff. | **Excluded** | **Excluded from every commercial and source metric.** |

**Why Redundant must not be folded into either neighbour** — this is the subtle one and it is where
money sits. Counting a duplicate as *Invalid* penalises a source that legitimately produced a real
prospect. Counting it as *Commercial loss* depresses the conversion rate for a prospect who may
have converted on the surviving record. Neither is true, so it needs its own class. It also
produces a signal the builder genuinely needs: §11's clash detection exists because *"multiple
sources/CPs claim the same prospective customer"*, and a CP whose registrations are predominantly
duplicates of prospects already in the system is an attribution problem with commission consequences
(§32, §40), not a lead-quality problem. **The framework preserves the ability to see that.** It does
**not** authorise building a CP scorecard — §39 permits a CP to see *"attribution information,
pipeline status, commission status"* and says nothing about scoring CPs. That would be a new
product requirement and is not proposed here.

### 3.4 Dimension B — Responsibility locus *(mandatory)*

*Where does this closure point?* Four values: **source or CP · prospect · builder product or
process · nobody.**

This is what makes AD-01 §9.1's source-quality problem actually solvable rather than merely
diagnosed. Class alone is insufficient because it is coarse *within* a class: inside **Commercial
loss**, "chose a competitor" points at the market, "financing failed" points at the prospect's
circumstances, and "we had nothing in their budget band" points at the builder's inventory. Those
three should not sit in one undifferentiated bucket on a source-performance report.

Correlation with Dimension A is high but not total, which is precisely why it is a second dimension
rather than a derivation of the first.

### 3.5 Dimension C — Recoverability posture *(system-owned)*

*Is this closure permanent, or is this prospect legitimately revisitable later?* At minimum:
**permanent** (unusable contact, not a real person, administrative) versus **potentially
revisitable** (timing/deferred, financing failed, no matching inventory *today*).

Dimension C exists because it is the input to a decision already on the table and **not resolved
here**: AD-01's **Q5** — can a Dumped lead be re-engaged, or does re-contact create a new lead
against the same Person (which §06/§07 explicitly permit)? Without C, Q5 has to be answered
uniformly for all Dumps, which is plainly wrong — "wrong number" and "wants to buy after possession
in 18 months" are not the same closure.

**Rule 1 note:** the spec says nothing about remarketing, nurture or re-engagement campaigns (AD-01
§1.3 confirms: *"Re-engagement of a dumped lead — never addressed"*). Dimension C is proposed to
**enable** the owner's Q5 decision, **not** to authorise a remarketing capability. §65's do-not-build
list and §86 remain in force.

### 3.6 What is deliberately *derived*, not carried on the reason

**Engagement depth at closure** — was this prospect never reached, reached but never engaged, or
engaged through site visits and quotes before being lost?

This is **not** a dimension of the reason and must not become one. It is computable from the
activity and site-visit records that §09 and §14 already require and that AD-01 §8.4 already places
as separate entities. Recording it on the reason would duplicate a fact the system already holds
and would let the two disagree.

Its practical consequence: *"went unresponsive after genuine engagement"* — named in this task's
framing — **does not need to be its own reason value**. It is `commercial_loss` + `prospect` locus +
a derived engagement depth. This is the framework demonstrating that it works: it absorbs a
plausible-sounding value without growing.

### 3.7 Is a reason mandatory on Dump?

**Recommended: yes, whenever the lifecycle state's semantic type is closed-without-conversion** —
AD-01 §8.6 already implies this and this amendment confirms it.

The tension is real and should be named: §13 wants *"one-tap dispositions"* and warns against
unnecessary typing. §95 resolves it — *"MINIMUM NECESSARY FRICTION, not minimum possible taps"* — and
the necessity is established by AD-01 §9.1: without a reason, **no defensible source-quality or
CP-quality report exists at all**. The friction can still be near-zero in practice using the tools
§13 itself endorses (*"prefilled values, quick actions, contextual actions"*): the reasons offered
first can be contextual to how the lead was captured, so the common case remains one tap.

### 3.8 Recommendation — Q7

> **RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT APPROVAL**
>
> Adopt a **three-dimension classification framework** — **Opportunity validity class**,
> **Responsibility locus**, **Recoverability posture** — as system-owned semantic properties of the
> Dump-reason master, with the reason **values** remaining tenant-configurable rows under **R4**.
> Require a reason on any closed-without-conversion terminal disposition. Derive engagement depth
> from activity history rather than recording it on the reason.
>
> **No reason values are proposed by this amendment.** Defining the initial vocabulary — including
> whether the existing seeded `lead_loss_reasons` rows are replaced outright, which
> reconciliation §B.3 already flags — is the owner's, and remains open.
>
> **Until the framework is approved and values exist, AD-01 §9.6 stands as written:** source-quality
> comparison and reason-coded loss analysis must not be shipped as charts.

---

## 4. Sync / verification axis re-examined: split, or merged?

AD-01 §5.1 proposed **one** axis: *Verified · Pending Sync · Sync Conflict*.

**Finding: these are two genuinely independent concepts, and merging them introduced a correctness
defect into AD-01, not merely an inelegance.**

### 4.1 The two concepts, separated

**Transport-level sync** — *did this record reach the server?* Spec: §12, §46, §47, §48. §47
enumerates what the sync system handles: *"duplicate requests, retry, server rejection, conflicts,
stale data, authentication expiry, revoked permissions, partial failure"* — every item is a
transport or queue concern. Changed by connectivity and the device queue. Resolves in seconds. No
human judgement. Applies to **any** offline-eligible operation, not only leads — §46 names *"notes,
low-risk activity, selected lead capture"*.

**Business-level verification / clash gate** — *has this lead passed server-side duplicate and clash
detection, and if flagged, has an authorized human resolved it?* Spec: §09 (duplicate detection),
§11 (clash detection, *"Builder-side authorized leadership resolves attribution"*), §12 (the gate
itself). Resolves in days. Requires a permission-gated human act. Carries restricted visibility.

### 4.2 The defect in the merged axis

**AD-01 §5.1 states: *"Every lead created online is Verified at creation."* That is false against
§09 and §11.**

Duplicate detection (§09) and clash detection (§11) are described as core business controls of the
CRM without qualification. **Nothing in §11 mentions offline at all.** §12's contribution is
narrower than the merged axis assumes: it says a *device* cannot run the gate while disconnected —
it does not say online-created leads bypass it. Merging the two concepts therefore marks every
online lead "Verified" by construction, and the system loses the ability to express the single most
commercially consequential case in §11: **an online-created lead that clashes with a CP's prior
registration of the same prospect.** That case has commission money on it (§32, §40) and is exactly
what the attribution machinery exists for.

This is the defect. It follows directly from letting a *transport* concept ("did it sync?") name a
*business* axis, because the transport concept is trivially true for online records and the merged
axis inherits that triviality.

### 4.3 Three further reasons the merge does not survive

1. **Different resolution authority.** Sync conflicts resolve automatically and idempotently (§47,
   §93). Clash resolution is *"Builder-side authorized leadership"* (§11) — a permission-gated human
   act. **AD-01's own §5.2 argument applies inside its own axis and breaks it:** *"facts about the
   same lead that are authorised differently cannot share a column."*
2. **Directly contradictory visibility requirements.** §48 **requires** the UI to *"show pending
   synchronization state"* to the user. §11 **forbids** exposing competing claims to Sales Reps, and
   insists *"The UI visibility rule must be enforced by authorization—not merely by hiding a
   badge."* One axis cannot be both must-show and must-hide.
3. **Different entity scope.** Transport state belongs to a queued *operation* (§47: *"Every queued
   offline operation needs a safe identity"*), which is per-operation and per-device. The
   duplicate/clash gate belongs to the *lead*. Making transport a lead-level axis misplaces it, and
   then cannot represent a lead with three queued operations in different transport states.

### 4.4 The argument for keeping them merged, and why it is answerable

The genuine case for merging is §60 — *"SOPHISTICATED BACKEND + SIMPLE FRONTEND"* — plus AD-01's own
stated risk that Alternative C *"invites over-modelling"*. From the rep's viewpoint at the moment of
reconnect, §12 does read as one flow, and a rep does not care which kind of "not cleared yet" they
are looking at.

**That is answerable at the presentation layer and only there.** A single combined rep-facing
indicator ("this lead is not yet cleared") satisfies §60 and §48 while the persisted model stays
two. Unifying a *presentation* is cheap and reversible; conflating *persistence* is the expensive,
history-destroying direction — which is AD-01 §5.2's own asymmetry argument, applied consistently.

### 4.5 The simplification the split produces

Splitting does **not** mean two lead axes. It means one lead axis and one thing that is not a lead
axis at all:

- **Transport sync is not a lead axis.** Once a record exists on the server, the transport question
  is answered by construction. What remains at lead level is (i) an immutable **provenance** fact —
  *this lead was captured offline* — which is history, not a state, and never changes; and (ii) the
  gate axis's "not yet run" value, which is the fact §12 actually cares about. Live transport state
  lives on the queued-operation record in the sync subsystem, where §47 already puts it.
- **The verification / clash gate is a lead axis, and it applies to every lead** regardless of
  origin — which is the correction in §4.2. Conceptually: *gate not yet run · cleared · flagged ·
  resolved by authority.* §12's *"notify the appropriate authorized person if a conflict is found"*
  attaches here.
- **A flagged *attribution* conflict belongs on AD-01's existing attribution axis, not here.** AD-01
  already gives the claim contest its own home (§06 Lead Attribution Claim; AD-01 §3.6, §5.1). So
  the gate axis carries the *duplicate* outcome, and a competing-claim outcome raises a claim on the
  attribution entity. This dissolves AD-01's "Sync Conflict" catch-all, which was silently carrying
  three different conflict types with three different resolvers.

### 4.6 Recommendation — sync / verification axis

> **RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT APPROVAL**
>
> **Split.** Replace AD-01 §5.1's single *Verified · Pending Sync · Sync Conflict* axis with:
> **(i)** a **verification / clash gate** axis that applies to **every** lead, online or offline;
> **(ii)** an immutable **offline-capture provenance** fact on the lead, which is history rather
> than state; and **(iii)** transport sync state held on the queued-operation record in the sync
> subsystem (§47), **not** on the lead.
>
> Rep-facing UI may still present one combined "not yet cleared" indicator (§60, §48).
>
> **§88 note:** this touches *"changing offline business behavior"*, which §88 places squarely in
> the MUST ASK column. It is a recommendation only.

**Open question this creates, and does not answer (Rule 1):** the spec does not say **when** the
duplicate/clash gate runs for an *online*-created lead — synchronously at save, or asynchronously
afterwards. §09 requires duplicate detection; §12 addresses only the offline case. If it is
synchronous, "gate not yet run" is momentary for online leads but remains structurally correct. **The
owner should answer this; it is not decided here, and it is adjacent to but distinct from AD-01's
Q12 (lead-portal ingestion), which also remains open.**

---

## 5. Assignment state axis re-examined: what must actually be persisted?

AD-01 §5.1 proposed a persisted axis: *Unassigned · Assigned · Pending Enrichment · Reassignment
Pending*.

**Finding: none of the four requires persistence. The minimal persisted footprint for this axis is
zero values, and the axis should be eliminated.**

### 5.1 The test applied

For each proposed value: can it be **reliably** computed on read from constructs the spec already
mandates — Owner and Handler (§10), the Assignment Log (§06), activity/follow-up records (§09, §13,
§14), the approval construct (§50), or the lead's own data (§42, §43)?

| Proposed value | Derivable from | Verdict |
|---|---|---|
| **Unassigned** | `Handler` is absent (§10), optionally combined with the handler's active flag (§57) | **Derive.** Persisting duplicates the authoritative fact. |
| **Assigned** | `Handler` is present | **Derive.** Same. |
| **Pending Enrichment** | An open enrichment task assigned to the handler, plus completeness against tenant-configured required fields (§42, §43) | **Persist the *task*, derive the *condition*.** Not an assignment value. |
| **Reassignment Pending** | — | **Do not build.** The spec defines no approval step on reassignment. |

### 5.2 Unassigned / Assigned — a shadow copy of the Handler reference

§10 makes Handler the authoritative answer to *"who is currently working this lead."* An axis value
that restates presence-or-absence of that reference is a second source of truth for one fact, and
they can disagree: a row whose Handler is set but whose axis says Unassigned is corrupt in a way
nothing detects. §88 lists *"changing source-of-truth rules"* in the MUST ASK column precisely
because this class of duplication is expensive.

§57's requirement — *"identify owned/unassigned records"* — is a **query** requirement and is
satisfied by an indexed predicate on the Handler reference. §88 places *"sensible indexing where it
does not alter semantics"* in Claude's own column, so nothing about this needs escalation.

**Small consequence worth recording, not a blocker:** §57 leaves open whether deactivating an
employee clears the live Handler reference or whether "effectively unassigned" is computed against
the user's active flag. Either works, and the Assignment Log preserves the history in both cases per
§57's *"preserve historical actor identity"*. The derivation holds either way.

### 5.3 Reassignment Pending — a state for a workflow the spec does not define

§10 requires that *"All meaningful handovers must be recorded"* — **recorded**, not approved. §57
says management may *"reassign work"* directly. §50's approval machinery is described for
approvals generally and names high-risk commercial operations, not reassignment.

**Nowhere does the spec require an approval step on reassignment.** Persisting a state for it is
inventing a requirement, which Rule 1 forbids and §88 places in the MUST ASK column. If such an
approval is ever required, the correct shape is a **request record in the approval subsystem**
(§50), and the lead's condition becomes "an open reassignment request exists" — derived, and
additive when it arrives.

### 5.4 Pending Enrichment — persist the obligation, derive the condition

§43 is permissive, not mandatory: *"the system **can** maintain a pending enrichment queue."* AD-01
Q8 already asks whether it is in MVP scope and that question stays open.

The condition has two halves, and they behave differently:

- **Incompleteness** — derivable at read time from the lead's data against the tenant's configured
  required fields. But **not stable**: a tenant adding a required field would retroactively flip
  thousands of historical leads into "pending enrichment", which is a bad enough behaviour to be
  disqualifying on its own.
- **The obligation** — *who* owes the missing information and *by when*. Not derivable from
  completeness at all, and this is the half §43 actually cares about: *"create accountability
  without blocking urgent sales activity."*

So the durable thing is the **obligation**, and the system already has the construct for a durable
obligation with an owner and a date: the follow-up / task record that §13 and §14 require. Placing
enrichment on the **assignment** axis, as AD-01 did, conflates *who is accountable for the lead*
with *what is currently owed on it* — two different questions with two different lifetimes.

This refines AD-01 E-11, which correctly rejected enrichment as a *lifecycle* state but then placed
it on the assignment axis without applying the same test a second time.

### 5.5 Why AD-01's reversibility argument does *not* rescue this axis

AD-01 §5.2 and §11 argue that adding an axis later is expensive because *"nobody can reconstruct,
two years later, whether a given lead was pending sync."* That argument is sound — **and it is
specific to dimensions no other construct records.**

The assignment dimension has such a construct, mandated independently: **§06 makes the Assignment
Log a canonical entity**, and AD-01 §8.3 already argues it must outlive the audit log's 12-month hot
window (**R6**), echoing reconciliation §D.3: *"the assignment log answers 'who was responsible on
the 14th', which is a question sales operations asks constantly."*

So the assignment dimension's history **is** recoverable, from a record the spec requires anyway.
The reversibility asymmetry that justifies keeping the verification gate as a persisted axis
**does not transfer** to assignment. AD-01 applied the argument uniformly across all three of its
non-lifecycle axes; it holds for one of them and not the others. That is the precise error.

### 5.6 What is lost by eliminating the axis, stated honestly

1. **A single indexed column behind AD-01 §9.4's exception queues.** Each queue becomes its own
   predicate instead. These are ordinary indexed queries and §88 leaves indexing to implementation;
   not a real cost.
2. **"How long was this lead unassigned?"** — under a persisted axis this would come from the axis's
   own history. It comes instead from the Assignment Log, which is **the better source**: it carries
   who, to whom, when, why and by whose authority (§10, §D.3), where an axis history would carry
   only the condition.
3. **No home for a future assignment condition that is neither a reference nor an open task.** If
   the owner names one, it is additive — and per §5.5 the history is already being recorded, so
   adding it later is cheap. This is the one place the asymmetry runs the other way, and it is
   worth stating rather than hiding.

### 5.7 Recommendation — assignment axis

> **RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT APPROVAL**
>
> **Eliminate the persisted assignment-state axis. Minimal persisted footprint: zero axis values.**
>
> What stays persisted is only what the spec already mandates and AD-01 already places elsewhere:
> **Owner** and **Handler** references (§10), and the **Assignment Log** (§06, §10, §57).
> *Unassigned* and *Assigned* are derived from Handler; *Pending Enrichment* becomes a task plus a
> derived completeness check (subject to AD-01 Q8, still open); *Reassignment Pending* is not built,
> because the spec defines no reassignment approval.
>
> AD-01 §5.1's four-axis picture therefore becomes: **lifecycle** (persisted, four values) ·
> **verification / clash gate** (persisted, per [§4](#46-recommendation--sync--verification-axis)) ·
> **attribution contest** (persisted on the claim entity, unchanged from AD-01) — with follow-up
> status, action-feed buckets and now **assignment condition** all derived.

---

## 6. Consolidated effect on AD-01, and what remains open

### 6.1 Sections of AD-01 this amendment modifies

| AD-01 section | Effect |
|---|---|
| §5.1 — the recommendation | **Modified.** Lifecycle stays at four values (no fifth "Pending"); sync/verification axis split per §4; assignment axis eliminated per §5. |
| §6.2 — sync axis transition table | **Superseded** by §4.5's separation. Rewriting it is a follow-on task, not part of this amendment. |
| §6.3 — assignment axis transition table | **Superseded** by §5.7. The transitions become Handler changes recorded in the Assignment Log. |
| §6.4 / Q4 | **Resolved** by §2.2 — recommendation only. |
| §7 E-06, E-07 | **Refined** by §4.5: the duplicate outcome and the competing-claim outcome are separated and have different resolvers. |
| §7 E-11 | **Refined** by §5.4: enrichment is a task plus a derived condition, not an assignment-axis value. |
| §7 E-14 | **Becomes unreachable** if Q4 is approved as recommended. |
| §9.1, §9.6 | **Unblocked in principle** by §3's framework; still blocked in practice until values exist. |
| §10 Q1, Q4, Q7 | **Answered as recommendations.** They remain owner decisions. |
| Everything else in AD-01 | **Unchanged and still PROPOSED — NOT APPROVED.** |

### 6.2 New questions this amendment raises and does not answer

Raised because the analysis surfaced them; **none is decided here**, and per Rule 1 none is guessed.

- **N-1.** When does the duplicate/clash gate run for an **online**-created lead — synchronously at
  save, or asynchronously? (§4.6. §09 requires the control; the spec never states the timing.)
- **N-2.** If Q1 is approved as recommended, what are the values of the "waiting on" qualifier, and
  which of them suppress §58 escalation? (§1.7. R4 masters; the spec defines none.)
- **N-3.** Does deactivating an employee (§57) clear the live Handler reference, or is
  "effectively unassigned" computed against the user's active flag? (§5.2. Either satisfies §57.)
- **N-4.** Which Dump reason values seed each tenant, and are the existing generic-SaaS
  `lead_loss_reasons` rows replaced outright? (§3.8; reconciliation §B.3 already flags them.)

### 6.3 Still open from AD-01, untouched by this amendment

**Q2, Q3, Q5, Q6, Q8, Q9, Q10, Q11, Q12, Q13, Q14, Q15, Q16** — all remain open exactly as AD-01
states them. **Q6 narrows** in scope if Q4 is approved as recommended (§2.2), but is not answered.
No blocker other than M-1 is touched by this document.

---

## 7. Approval

**STATUS (as originally written, prior to §8): PROPOSED — NOT APPROVED**

> **Superseded by [§8](#8-product-owner-decision-2026-09-12).** This section is retained verbatim as
> the historical record of what was being asked. The product owner has since reviewed and decided
> §§1–5 as recorded in §8. Read §8 as authoritative; read this section as the request that produced
> it.

Every recommendation above sits in §88's **MUST ASK BEFORE DECIDING** column — canonical entities,
relationships, offline business behavior, source-of-truth rules. Specifically:

- **§1 (Q1)** and **§5** narrow AD-01's proposed model. Narrowing is still a change to a canonical
  relationship and still requires approval.
- **§2 (Q4)** confirms the owner's provisional preference. **A provisional preference is not an
  approval.** It was weighed as evidence, and the recommendation is reached on independent spec
  grounds; it still requires explicit sign-off before anything keys on it.
- **§3 (Q7)** proposes a framework and deliberately proposes **no values**.
- **§4** asserts that AD-01 §5.1 contains a correctness defect. That assertion is the amendment's
  strongest claim and deserves the owner's scrutiny before it is relied upon.

Nothing here may be implemented, seeded, migrated to, or treated as settled until the project owner
approves it in writing. **Delegation to an architect is not authorization.** Per §97: *when in
doubt, STOP AND ASK.* This document, like AD-01, is the asking.

---

## 8. Product-Owner Decision (2026-09-12)

The project owner has reviewed AD-01 and this amendment (AD-01A) and recorded the following as the
current product-owner decisions. This section is the authoritative record of what has been decided;
§§1–5 above remain in place as the reasoning that supports it.

### 8.1 Q1 — Pending

- **Reject** "Pending" as a fifth persisted Lead Lifecycle state.
- Lead Lifecycle remains **four values: New / Follow-up / Success / Dump.**
- "Awaiting Response," "Blocked," *Today*, *Future*, and *Overdue* are **operational/Action-Feed
  conditions**, not Lead Lifecycle states.
- *Today* / *Future* / *Overdue* must be **derived from next-action timing**, never persisted as
  lifecycle state.
- **Do not create** a new persisted "Blocked" lifecycle state.

### 8.2 Q4 — Success milestone

- **Approve** Success at the **Booked / §20 Stage 3** milestone, after the required builder-side
  booking-verification milestone.
- **Booking has its own lifecycle/state machine.** The Lead Lifecycle must **not** absorb Booking
  states such as *Initiated* or *Pending Verification*.
- A subsequently **cancelled booking must not rewrite** the historical Lead Lifecycle from Success
  back to Dump. (The cancellation lives on the booking, per §35 and R6 — consistent with §4.6.2's
  analysis and AD-01 §7 E-15's recommended position.)

### 8.3 Q7 — Dump reason framework

- **Approve** the three-dimensional semantic framework proposed in [§3](#3-q7--a-semantic-framework-for-dump--loss-reasons):
  (a) opportunity validity class, (b) responsibility locus, (c) recoverability posture.
- **Do not** invent or finalize arbitrary reason values yet — the dimensions are approved; the
  tenant-facing reason vocabulary is not.
- A **terminal non-conversion disposition must carry a reason.**
- **Preserve the historical reason** on a lead rather than silently rewriting business history.

### 8.4 Sync vs. verification

- **Reject** the combined Sync/Verification axis proposed in AD-01 §5.1.
- **Approve** sync and verification as **separate concepts**, per [§4](#4-sync--verification-axis-re-examined-split-or-merged).
- **Successful transport synchronization must never imply successful business verification.**
- **An online lead may be successfully synchronized while simultaneously being subject to
  duplicate/clash review** — this is the case the merged axis in AD-01 could not express, and it is
  now explicitly preserved.
- The distinction between technical transport state and business verification/conflict state must
  be preserved throughout the design.

### 8.5 Assignment

- **Eliminate** the persisted Assignment State axis.
- **Do not create** Unassigned / Assigned / Reassignment Pending as a separate state machine.
- **Owner, Handler, Assignment History, activities, tasks, and derived completeness/work-queue
  conditions** should carry this information, **unless a later explicit requirement proves
  otherwise.**
- **Do not invent** a reassignment-approval workflow.

### 8.6 Architectural framing — the Orthogonal Lead Model

Per the product owner's direction, the refined result is **no longer referred to simply as
"Alternative C" without qualification.** Going forward, the conceptual framing is the **Orthogonal
Lead Model**, comprising:

- **Lead Lifecycle** *(persisted — four values: New / Follow-up / Success / Dump)*
- **Action / Next-Action conditions** *(derived — §8.1: Today / Future / Overdue / Blocked, computed from next-action timing, not stored)*
- **Activity history** *(the underlying record §14/§09 already require; source of derived engagement depth, §3.6)*
- **Assignment data/history** *(derived/log-based — Owner, Handler, Assignment History; §8.5, zero persisted axis values)*
- **Attribution / Clash** *(persisted, on the attribution-claim entity — unchanged from AD-01 §3.6, §5.1)*
- **Sync transport state** *(not a lead axis — provenance fact plus the queued-operation record, §4.5, §8.4)*
- **Verification / Conflict state** *(persisted — the duplicate/clash gate, applying to every lead regardless of origin, §4.5, §8.4)*
- **Independent Booking lifecycle** *(a separate state machine entirely — §8.2; the Lead Lifecycle references it but does not absorb its states)*
- **Dump disposition classification** *(the three-dimensional framework, §8.3, §3)*

Prior and future references to "Alternative C — Orthogonal Axes" (in AD-01 and elsewhere in this
amendment) refer to the same underlying design and should be read as the **Orthogonal Lead Model**
as refined and decided in this §8.

### 8.7 Scope of this decision — what remains unresolved

- **These decisions approve AD-01A's conclusions only** — §§1–5 above, as recorded in §§8.1–8.5.
- **AD-01 remains NOT APPROVED FOR IMPLEMENTATION.** No schema, SQL, migrations, or implementation
  work is authorized by this decision.
- **No other architecture blocker is resolved by this decision** — the reconciliation report's
  remaining blockers (M-2 … M-20) are untouched.
- **AD-01's Q2, Q3, Q5, Q6, Q8–Q16 remain open**, per [§6.3](#63-still-open-from-ad-01-untouched-by-this-amendment).
  Q6 narrows as described in §2.2 but is not itself decided.
- **This amendment's N-1, N-2, N-3, N-4 remain open**, per [§6.2](#62-new-questions-this-amendment-raises-and-does-not-answer).
- No values have been invented or approved beyond what is explicitly stated above (Rule 1, R12).

**The Lead State Machine decision as a whole is not final.** Implementation approval requires the
remaining AD-01 questions (Q2, Q3, Q5, Q6, Q8–Q16) and this amendment's open questions (N-1–N-4) to
be resolved, followed by the project owner's explicit written approval of the complete model.
