# Architecture Decision 01 — Lead State Machine

**STATUS: PROPOSED — NOT APPROVED FOR IMPLEMENTATION**

> **Product-Owner decision recorded, 2026-09-12.** The project owner has reviewed this document and
> its amendment ([AD-01A](./03a-lead-state-machine-decision-amendment.md)) and issued explicit
> decisions on **Q1** (reject a fifth "Pending" lifecycle state), **Q4** (Success = §20 Stage 3
> Booked, after builder-side verification), **Q7** (approve the three-dimension Dump-reason
> framework, no values yet), the **sync/verification axis** (split into two concepts, not one), and
> the **assignment-state axis** (eliminated; zero persisted values). These decisions are recorded in
> full in **[AD-01A §8](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12)**
> and govern over the corresponding sections below. **The refined design is now referred to as the
> "Orthogonal Lead Model," not "Alternative C"** — see AD-01A §8.4 for the naming and its components.
> Q2, Q3, Q5, Q6, Q8–Q16 below remain open. **This document is still NOT APPROVED FOR
> IMPLEMENTATION** — no schema, SQL, migration or code may be built against it until every remaining
> question is resolved and the project owner approves the complete model in writing.

| | |
|---|---|
| **Decision ID** | AD-01 |
| **Resolves blocker** | [M-1](./01-bmexa-architecture-reconciliation.md#m-blockers) — "What is the lead state machine, exactly?" |
| **Scope** | The lead state machine **only**. No other blocker is resolved, narrowed or implied by this document. |
| **Authority** | BMexa Master Spec §88 places *canonical entities* and *relationships* in the **MUST ASK BEFORE DECIDING** column. Everything below is a recommendation to the project owner. Nothing here is decided. |
| **Constraints honoured** | `ENGINEERING_RULES.md` R1 (tenant isolation), R4 (masters, not enums), R5 (custom attributes), R6 (append-only event audit), R12 (project isolation — every claim below cites this repository's own documents). |
| **Contains SQL** | No. Deliberately. §8 describes data-model *consequences* conceptually; the DDL is a separate, later, separately-approved act. |
| **Sources read** | `docs/BMEXA_MASTER_SPEC.md` (all 97 sections), `docs/architecture/01-bmexa-architecture-reconciliation.md` (§B.3, §C.1, §D.3, §D.4, §D.9, §M), `docs/ENGINEERING_RULES.md`, `docs/architecture/schema-phase-0.sql` (§5.2, §5.3 — read for existing shape only; not modified). |

> **Read this first.** This document deliberately does *not* pick the reading of §09 that is
> easiest to implement. It shows that §09 and §13 cannot both be literally true, lays out what
> each reading costs, and recommends one. The recommendation is worthless without the project
> owner's answer to §10 below — particularly Q1, Q4 and Q7, which change the shape of the
> machine rather than its labels.

---

## 1. Existing Definitions

Every place in `docs/BMEXA_MASTER_SPEC.md` that defines, names, or implies a lead state,
stage, status, disposition, lifecycle position, or state-like condition. Quoted or closely
paraphrased, with section numbers. Nothing is added.

### 1.1 The primary definitions

**§09 — Lead Management (the only place a state *list* is given).**

> "The CRM must support: lead capture, lead assignment, ownership, active handler, follow-ups,
> site visits, disposition, duplicate detection, CP attribution, clash detection, reassignment,
> assignment history.
>
> Lead states discussed include: **New, Today, Future, Pending, Success, Dump**. The exact state
> machine must be implemented consistently. **Do not invent additional statuses unless required.**"

Two things are load-bearing in that quotation beyond the six words. First, "**states discussed
include**" — the spec describes this list as *discussed*, not as *decided*, and "include" leaves
it open-ended. Second, the two sentences after the list pull in opposite directions: *be
consistent* and *do not invent* constrain any resolution of the ambiguity that the list itself
creates.

**§13 — Lead Disposition UX (the only place a state list is given *with semantics*).**

> "The primary Sales Rep experience should be action-oriented. Use a simple disposition
> structure: **Follow-up** (requires next action/date), **Success** (converted), **Dump**
> (closed without needing follow-up)."

This is a three-value list, and unlike §09 each value carries a definition. "Follow-up"
*requires a next action and a date* — i.e. the value is not valid without an accompanying
timestamp. "Success" means *converted*. "Dump" means *closed without needing follow-up* — note
carefully that it does **not** say "lost".

**§12 — Offline Lead Creation (a state that is unambiguously persisted).**

> "A field user may create certain low-risk records while offline. However: a device cannot
> perform a reliable server-wide duplicate/clash check while disconnected. Therefore offline
> lead creation must be treated as **PENDING SYNCHRONIZATION**. After connectivity returns:
> synchronize safely, perform duplicate/clash detection, update the lead state, notify the
> appropriate authorized person if a conflict is found. **Never pretend an offline lead has
> passed the server-side clash gate.**"

This is the single clearest state definition in the entire spec: a named condition, a defined
entry trigger (offline creation), a defined exit trigger (successful server-side
duplicate/clash check), a defined consequence of failure (notify authorized person), and an
explicit prohibition on faking it. It also contains the phrase "**update the lead state**",
which confirms that a lead *has* a state the system writes to.

### 1.2 Definitions that constrain the machine without naming states

**§06 — Canonical Data Model.**

> "**Sales Lead** — A relationship between a Person, Project, and sales process. A Lead is NOT
> merely a status value on Person. The Sales Lead relationship must exist as its own business
> record."

Also from §06, three further canonical entities that carry state-like information and are
listed *separately from* Sales Lead:

> "**Assignment Log** — History of lead/CP ownership or assignment changes."
> "**Lead Attribution Claim** — Records competing attribution claims for a lead."
> "**Audit Event** — Immutable security/business audit record."

That Assignment Log and Lead Attribution Claim are canonical entities in their own right — not
columns, not statuses — is a spec-level instruction that assignment and attribution are **not**
values on the lead's state axis.

**§07 — Person / Lead / Customer Rule.**

> "Do NOT implement Person = Lead = Customer as one database record. Correct conceptual model:
> Person = identity. Sales Lead = sales relationship/process. Customer = contextual role
> associated with a transaction. […] A Person can have multiple leads, interact with multiple
> projects, become a customer, be an applicant/co-applicant, have historical relationships.
> **Do not destroy historical identity when status changes.**"

The last sentence is a direct constraint on the state machine: a transition must not be
destructive.

**§10 — Lead Owner vs Handler.**

> "Separate: **Lead Owner** (person responsible for the lead/account relationship) and **Lead
> Handler** (person currently working the lead). A lead can change handlers without destroying
> ownership history. All meaningful handovers must be recorded."

Two references, two lifetimes, and a mandatory history. Not a state value.

**§11 — Clash Detection.**

> "Clash detection is a core business control. If multiple sources/CPs claim the same
> prospective customer: record each attribution claim, preserve history, do not expose sensitive
> competing claims unnecessarily. Builder-side authorized leadership resolves attribution. Sales
> Reps should not automatically see sensitive clash information […] The UI visibility rule must
> be enforced by authorization—not merely by hiding a badge."

"Resolves attribution" implies attribution has a resolution state. That state is a property of
the *claim contest*, and §06 already gives it its own entity.

**§14 — Sales Rep Mobile Experience.**

> "Primary home experience: **Action Feed**, prioritizing: (1) Active inventory holds, (2) New
> leads, (3) Today's follow-ups, (4) Scheduled visits, (5) Overdue actions."

This is the decisive passage for interpreting §09. Three of §09's six "states" appear here as
**Action Feed bucket names**: *New leads*, *Today's follow-ups*, and (as the complement of
Today) *Overdue actions*. §14 calls them a prioritised list on a home screen — a **view**, not a
data model.

**§42 / §43 — Helpdesk capture and pending enrichment.**

> §42: "Target workflow: name, limited phone identifier where appropriate, CP/source, quick
> registration, summon/assign appropriate Sales Rep. **Do not make the helpdesk complete the
> entire CRM profile before the lead can enter the queue.**"
> §43: "If a field Sales Rep is responsible for enriching a lead later, the system can maintain
> a **pending enrichment queue**. This should create accountability without blocking urgent
> sales activity."

A lead that exists, is real, is in a queue, and is *incomplete*. §43 says "can maintain", which
is permissive, not mandatory.

**§44 — CP walk-in edge case.**

> "If an unknown CP sub-agent arrives and cannot immediately be matched to an existing profile:
> provide a temporary/manual capture mechanism. Do not block the Helpdesk workflow. The
> temporary information must be clearly marked as **unverified** and later reconciled."

An unverified-and-later-reconciled condition, on the CP identity attached to a lead — not on the
lead's own progress.

**§49 — Missed-call auto logging.**

> "Desired UX: Call → return to application → suggest **Not Connected / No Answer / Follow-up
> Tomorrow**. This is a usability optimization. […] **VALIDATE TECHNICALLY BEFORE PROMISING
> EXACT BEHAVIOR.**"

Three more state-sounding words. In context these are *outcomes of a single call attempt* plus a
scheduling shortcut, not lead states — but they are the fourth distinct vocabulary in the
document that could plausibly be read onto the lead record, which is precisely the problem.

**§58 — Notifications.**

> "The escalation concept (reminder before scheduled call, **escalation for missed follow-ups**,
> manager visibility when appropriate) must be implemented only where it genuinely improves
> execution."

"Missed follow-up" is a computable condition (a next-action date in the past with no activity),
and the spec treats it as a trigger for escalation, not as a status.

**§57 — User deactivation.**

> "When an employee leaves: do not destroy historical records, preserve historical actor
> identity, deactivate access, **identify owned/unassigned records**, create appropriate
> assignment history, allow authorized management to reassign work."

"Unassigned records" is named as a real, queryable condition.

**§17 / §20 — Booking lifecycle (adjacent, and frequently confused with lead state).**

> §17: "Never confuse VIEWING with HOLD with BOOKING INITIATED with PENDING VERIFICATION with
> BOOKED."
> §20: "Stage 1 — **Booking Initiated** […] Stage 2 — **Pending Verification** […] Stage 3 —
> **Booked** (required Builder-side verification has completed). Do not mark a booking 'Booked'
> simply because a form was submitted."

These are states of the **Booking Group**, not of the Lead. They matter here for exactly one
reason: §13 defines lead "Success" as *converted*, and §20 gives three candidate moments at
which a conversion could be said to have occurred. See §2.4 and Q4.

**§80 — Phase 3 scope.**

> "Build: lead capture, Person relationship, Sales Lead, assignment, ownership, handler,
> follow-ups, site visits, disposition, duplicate detection, clash engine, assignment history,
> Helpdesk workflow. **Offline lead capture may be introduced with explicit pending-sync
> behavior.**"

Confirms pending-sync is a delivered behaviour, not a footnote, and re-lists disposition and
assignment as separate deliverables.

### 1.3 What the spec does *not* define anywhere

Established by reading all 97 sections. This list is as important as the list above, because
under Rule 1 ("Do not invent requirements") and R12, absence is a finding, not a gap to fill.

| Concept | Status in spec |
|---|---|
| **Lead temperature** (hot / warm / cold) | **Never mentioned.** No section uses the words hot, warm, cold, temperature or priority-of-lead in this sense. |
| **Lead score / rating** | **Never mentioned.** |
| **Lead loss reasons** | **Never defined.** §13's "Dump" is *"closed without needing follow-up"* — which is not a synonym for lost. No loss-reason vocabulary appears anywhere in the spec. (A `lead_loss_reasons` master exists in the Phase 0 schema from the generic-SaaS seed; §B.3 of the reconciliation calls its values "plausible shape; values need review".) |
| **A weighted pre-booking sales pipeline / probability forecast** | **Never defined.** This is blocker M-8 and is explicitly *out of scope for this document*. |
| **Portal / listing-site lead ingestion (99acres-style) and its sync state** | **Never mentioned.** §72 lists external integrations as "WhatsApp, email, telephony, accounting exports" — no lead portals. The only sync state BMexa defines is §12's offline-device sync. |
| **Lead qualification stages** (MQL/SQL-style) | **Never mentioned.** |
| **Lead nurture / drip state** | **Never mentioned.** §58 warns against notification volume. |
| **Re-engagement of a dumped lead** | **Never addressed.** The spec neither permits nor forbids it. See Q5 and Edge Case E-01. |
| **SLA / response-time targets on a new lead** | **Never defined.** §58 mentions escalation for missed follow-ups but sets no threshold. |

---

## 2. Contradictions / Ambiguities

Seven, ordered by how expensive each is to get wrong.

### 2.1 §09 and §13 are different lists and cannot both be the persisted state vocabulary

§09 gives six values; §13 gives three. Two of the three (**Success**, **Dump**) appear in both.
The §13 value **Follow-up** does not appear in §09 at all. The §09 values **New**, **Today**,
**Future** and **Pending** do not appear in §13 at all.

If §09 is the persisted vocabulary, then §13's "disposition structure" is a UI affordance that
writes values not in the §09 list — which contradicts §09's "the exact state machine must be
implemented consistently". If §13 is the persisted vocabulary, then four of §09's six named
states are not persisted states — which contradicts the plain reading of §09's sentence.

Both readings are defensible from the text. **This is the core of M-1 and it cannot be resolved
by an engineer.**

### 2.2 Today / Future / Overdue are time-relative descriptions, not record states

"Today" and "Future" are not conditions a record is *put into* by an actor. They are the result
of comparing a scheduled date against the current server time. A lead whose next action is
scheduled for tomorrow is "Future" now and "Today" in a few hours, with nobody touching the
record and no business event occurring.

The consequence of persisting them is concrete and unpleasant: every such record is wrong at
midnight, and a scheduled job must exist whose only purpose is to relabel rows because the clock
moved. That job then becomes a correctness dependency for the Sales Rep home screen, and — under
R6 — either floods the audit log with machine-authored state changes or writes state changes
that are deliberately *not* audited, which is worse.

The competing reading is that §14's Action Feed buckets (*New leads*, *Today's follow-ups*,
*Overdue actions*) **are** §09's Today/Future/Pending, described from the screen rather than the
database. That reading makes §09 and §13 consistent, makes §14 fall out with no job, and costs
nothing. It is still **a reading, not a requirement.**

### 2.3 "Pending" is ambiguous across at least three unrelated conditions

The word appears in the spec attached to three genuinely different things:

1. **§09 "Pending"** — undefined in context. In most sales vocabularies this means *awaiting a
   response from the prospect or a third party* (loan sanction, family decision, spouse visit).
2. **§12 "PENDING SYNCHRONIZATION"** — the offline-capture gate. Awaiting the *server*, not the
   customer. Has nothing to do with sales progress.
3. **§20 "Pending Verification"** — a **Booking** state (§17 explicitly forbids confusing it
   with other states), awaiting *builder-side* verification.

A single persisted value called "Pending" on the lead record would be read by three different
audiences as three different facts. §43's "pending enrichment queue" is arguably a fourth.

### 2.4 "Success (converted)" does not say *converted to what*

§13 defines Success as "converted". §20 gives three distinct booking milestones — **Booking
Initiated**, **Pending Verification**, **Booked** — and §17 states in capitals that these must
never be confused with one another. So "Success" could legitimately mean any of:

- a booking record has been *initiated* (rep filled the form),
- a booking is *pending verification*,
- a booking is *Booked* (builder-side verification completed).

The choice materially changes every conversion-rate report in the product, and it changes
whether a lead can leave Success (a booking initiated can fail verification; a Booked booking
can later be cancelled under §35). §20's warning — *"Do not mark a booking 'Booked' simply
because a form was submitted"* — is about bookings, but the same hazard applies verbatim to
marking a lead Success.

### 2.5 "Dump" is defined by *follow-up necessity*, not by *outcome*

§13: Dump = "closed without needing follow-up". That is an operational statement about the rep's
queue, not a commercial statement about the outcome. It covers at least: genuinely lost to a
competitor, wrong number, not a real prospect, budget mismatch, duplicate of an existing lead,
test data, and "bought elsewhere".

Two consequences. First, *Dump* and *Lost* are not synonyms, so a conversion funnel that treats
Dump as the denominator's loss bucket will understate lead quality (a wrong number is not a lost
sale). Second, since the spec defines no loss-reason vocabulary at all (§1.3), the system
currently has no way to tell those apart — and inventing the vocabulary is forbidden by Rule 1.

### 2.6 §09 mixes concepts that §06 has already separated into their own entities

§09's single sentence lists "lead assignment, ownership, active handler, follow-ups, site
visits, disposition, duplicate detection, CP attribution, clash detection, reassignment,
assignment history" and then, in the next sentence, presents six "lead states". But §06 already
gives **Assignment Log** and **Lead Attribution Claim** their own canonical entities, and §10
separates Owner from Handler. So the spec itself has already decided that assignment and
attribution are *not* values on the lead's state axis — while §09's phrasing invites exactly
that collapse.

### 2.7 "Do not invent additional statuses unless required" cuts both ways

Read strictly, this forbids adding any value beyond §09's six — which would forbid §13's
"Follow-up" and §12's "Pending Synchronization" as persisted values, both of which the spec
itself requires elsewhere. Read as intended (a warning against vocabulary sprawl), it is a
constraint on *taste*, not a closed list. The clause "unless required" concedes that additions
can be required. Any resolution of M-1 must state which reading the project owner intends,
because under the strict reading **Alternative A below is the only legal answer.**

---

## 3. Concept Separation

Real-estate CRMs routinely collapse eight distinct concepts onto one column. Below, each is
defined, checked against the BMexa spec, and distinguished from its neighbours.

The test applied throughout: **what changes it, how often, who is accountable for it, and can it
be true at the same time as its neighbour?** Two concepts belong on one axis only if a record
can never legitimately be in both at once.

### 3.1 Lifecycle state — *where is this lead in its life?*

**Defined by BMexa?** Yes, but ambiguously — §09 and §13 give conflicting vocabularies (see
§2.1). The *existence* of the concept is unambiguous: §12 says "update the lead state".

**Changed by:** a human actor performing a disposition, or the system on conversion.
**Frequency:** a handful of times over the lead's life.
**Mutually exclusive with itself:** yes — a lead is in exactly one lifecycle state.

**Distinguished from:** everything else below. This is the only axis on which "how far has this
gone" is expressed, and the only axis that should carry terminality.

### 3.2 Sales stage (weighted pipeline position) — *how close to closing?*

**Defined by BMexa?** **No.** The spec contains no probability-weighted pre-booking pipeline;
§20's booking lifecycle is an *approval workflow*, not a forecast (a booking awaiting document
verification is not "90% likely to close"). Whether such a pipeline is needed at all is **blocker
M-8**, which this document does not resolve.

**Why it must stay separate if it ever arrives:** a stage answers *how close*, a lifecycle state
answers *what is happening*. Merging them forces "Contacted" and "Negotiation" onto one axis, at
which point a lead cannot be both — the mistake the Phase 0 schema comment at §5.2 already names.

**Consequence for this decision:** the recommended machine below must not *become* a pipeline by
accretion. If M-8 comes back "yes, leadership needs a weighted forecast", that is a **second
axis**, decided separately.

### 3.3 Follow-up status — *is the next action due, overdue, or scheduled ahead?*

**Defined by BMexa?** Yes, but as a **view**, not a state: §14's Action Feed buckets (New leads /
Today's follow-ups / Overdue actions) and §58's "escalation for missed follow-ups". §13 makes the
underlying datum mandatory — Follow-up *"requires next action/date"*.

**Changed by:** the passage of time, with no actor and no business event.
**Frequency:** continuously.
**Mutually exclusive with lifecycle state:** no — a lead is simultaneously *in follow-up* (a
lifecycle fact) and *overdue* (a time fact).

**This is the concept most often collapsed into lifecycle state, and it is the collapse that
produces §09's Today/Future.** It is derived data: a scheduled timestamp compared to server time.
Derived data belongs in a query, not a column.

### 3.4 Temperature (hot / warm / cold) — *how motivated is this prospect?*

**Defined by BMexa?** **No. Not once, in any of the 97 sections.**

This is called out explicitly because it is the single most common thing a real-estate CRM adds
to the lead state column, and because its absence here is a *decision surface*, not an oversight
to correct. Under Rule 1 ("Do not invent requirements") and §88 (canonical entities require the
owner's sign-off), **temperature must not be built.** If the business wants it, that is a product
request the owner raises — see Q9.

**If it is ever added,** it is a separate axis: temperature is a *subjective assessment by the
handler*, revised often, never terminal, and orthogonal to lifecycle (a lead in follow-up can be
hot or cold; so, arguably, can a dumped one). It is also the axis most likely to be wanted as a
tenant-configurable master under R4.

### 3.5 Assignment status — *who is accountable, and does anyone own this yet?*

**Defined by BMexa?** Yes, and explicitly as **not** part of the lead's state: §06 makes
**Assignment Log** a canonical entity, §10 separates **Owner** from **Handler** and requires that
"all meaningful handovers must be recorded", §57 names "unassigned records" as a real condition,
and §42 describes helpdesk capture that "summons/assigns" a rep afterwards.

**Changed by:** a manager, a helpdesk operator, an escalation, or an employee leaving (§57).
**Frequency:** often; more often than lifecycle.
**Mutually exclusive with lifecycle state:** no — an *unassigned* lead is also *new*, and a
*reassigned* lead keeps whatever lifecycle state it had.

**The trap:** modelling "Unassigned" as a lifecycle state. It fails immediately because a lead
can become unassigned again at any point (§57 employee departure) without moving backwards in its
life, and because two leads both "New" are operationally different if one is assigned and one is
not. A related and subtler trap is modelling §43's *pending enrichment* as a lifecycle state; it
is a **data-completeness** condition attached to an assignment obligation, not a sales position.

### 3.6 Attribution / clash status — *whose lead is it, commercially?*

**Defined by BMexa?** Yes, explicitly and as its own entity: §06 **Lead Attribution Claim**, §11
clash detection with authorized resolution, §39 CP visibility of attribution, §44 unverified CP
identity.

**Changed by:** a claim being filed (by capture, by a CP, by a rep), or by authorized leadership
resolving a contest.
**Frequency:** rarely, but contested cases are commercially decisive (CP commission, §32).
**Mutually exclusive with lifecycle state:** no — a lead can be *contested* while in follow-up,
while Success, or after conversion.

**Three architecture-level constraints from §11 that forbid collapsing this into lead state:**
(1) multiple claims must **coexist**, which a single-valued column cannot represent; (2) reps must
not see competing claims, which means the field has a *different visibility rule* from the rest of
the lead record and therefore cannot live in the same authorisation envelope; (3) resolution is a
permission-gated action, not an edit. A single `source_id` on the lead represents one *resolved*
fact and is structurally incapable of representing a contested one.

### 3.7 Loss reason — *why did this end?*

**Defined by BMexa?** **The concept is implied; the vocabulary is not defined anywhere.** §13's
Dump is *"closed without needing follow-up"* and the spec never enumerates reasons.

**Changed by:** the actor performing the terminal disposition, once.
**Mutually exclusive with lifecycle state:** it is *dependent* on it — a loss reason is only
meaningful on a terminal state, which is a different relationship from orthogonality.

**Why it is separate rather than being extra terminal states:** if reasons are folded into the
state vocabulary ("Dumped — Wrong Number", "Dumped — Budget"), the state list grows without
bound, every report has to enumerate the terminal variants, and adding a reason becomes a change
to the state machine. Keeping the reason as a dependent attribute of a single terminal state
keeps the machine fixed while the reason list stays tenant-editable under R4 — which is also the
argument the Phase 0 schema already records at §5.4 for keeping loss reasons out of stages.

### 3.8 Sync state — *has this record passed the server-side gate?*

**Defined by BMexa?** Yes, for exactly one case and unusually precisely: **§12 offline capture**.
It is the one state in the spec with a named entry condition, exit condition, failure behaviour,
and an explicit prohibition on faking it.

**Explicitly NOT defined:** portal/listing-site ingestion sync (§1.3). BMexa names no lead portal
integration. If lead portals are in scope, that is a *new* requirement and a *second* sync
concept, and it must not be silently merged into §12's — see Q12.

**Changed by:** the device reconnecting and the server running duplicate/clash detection.
**Mutually exclusive with lifecycle state:** no, and this is the critical point — an
offline-created lead has a real disposition *and* an unpassed gate at the same time. A rep who
meets a prospect offline, talks to them, and schedules a callback has produced a lead that is
simultaneously *in follow-up* and *not yet duplicate-checked*. One column cannot say both, and
§12 forbids the system from pretending the gate has passed.

### 3.9 Summary table

| Concept | Defined in BMexa? | Where | Changed by | Same axis as lifecycle? |
|---|---|---|---|---|
| Lifecycle state | Yes, ambiguously | §09, §13, §12 | Human disposition / conversion | — |
| Sales stage (weighted) | **No** | — (M-8) | n/a | No — would be a second axis |
| Follow-up status | Yes, as a **view** | §14, §58, §13 | The clock | No — derived, never stored |
| Temperature | **No — absent entirely** | — | n/a | No — do not build (Q9) |
| Assignment status | Yes, as an **entity** | §06, §10, §42, §57 | Manager / helpdesk / departure | No |
| Attribution / clash | Yes, as an **entity** | §06, §11, §39, §44 | Claimant / authorized resolver | No — multi-valued |
| Loss reason | Concept implied, vocabulary **undefined** | §13 | Terminal disposition | No — dependent attribute |
| Sync state (offline) | Yes, precisely | §12, §80 | Reconnect + server gate | No |
| Sync state (portal) | **No — not in spec** | — (Q12) | n/a | n/a |

---

## 4. Alternatives

Three designs. Each is evaluated against: fidelity to the spec's literal text, how it handles
the eight concepts above, operational complexity, reporting consequences, and reversibility.

### Alternative A — "Literal Six": persist §09's list exactly as written

**Shape.** One persisted lifecycle axis, six values: New, Today, Future, Pending, Success, Dump.
§13's Follow-up/Success/Dump disposition UI writes into this same axis, mapping "Follow-up" onto
Today or Future depending on the chosen date. §12's pending-sync is either a seventh value or a
flag.

**How it handles the concepts.** Lifecycle, follow-up status and (partly) sync state are all
collapsed onto one axis. Assignment and attribution remain separate (§06 forces that). Temperature
and stage are absent. Loss reason is undefined.

**Pros.**
- Maximum literal fidelity to §09, and the only alternative that survives the *strict* reading of
  "do not invent additional statuses" (§2.7).
- Requires no interpretation: an engineer implements what is written and the owner is not asked to
  adjudicate.
- The rep-facing vocabulary and the stored vocabulary are identical, so a screenshot of the app
  and a database row use the same words — genuinely valuable for training and support.

**Cons.**
- **Requires a clock-driven relabelling job.** Every Future lead whose date arrives must become
  Today; every Today lead that lapses must become something else. That job is a correctness
  dependency of §14's home screen. If it fails or lags, reps see the wrong queue.
- **Corrupts the audit trail under R6.** Either the machine writes thousands of
  `lead.state_changed` events per night for transitions no human caused, or those transitions are
  excluded from audit — at which point the audit log no longer explains the record's state history.
  Neither outcome is acceptable; the first drowns the log (§54: "Do NOT blindly log everything"),
  the second breaks it.
- **Destroys time-in-state analytics.** "Days spent in Today" is meaningless. Lead velocity,
  the most basic pipeline metric, cannot be computed from a state history where the clock is an
  actor.
- **"Pending" stays ambiguous** across §2.3's three meanings, and the ambiguity is now baked into
  the stored data and every report keyed on it.
- **Cannot represent §12 honestly.** An offline lead in follow-up is both "Future" and "pending
  sync"; one column must pick one, and either choice violates §12's prohibition on pretending the
  gate passed or loses the rep's actual disposition.
- **Timezone-fragile.** "Today" for a rep in one city is not "Today" for a stored row, and §18
  already establishes the principle that server time is authoritative. A stored "Today" has no
  timezone.

**Complexity:** deceptively low at build time, high in operations (a scheduled job with
correctness responsibility, plus timezone handling, plus audit-volume management).

**Reporting:** poor. Funnels built on this axis mix "what happened" with "what time it is".

**Reversibility:** low. Once leads carry these values and reports key on them, migrating to a
derived model requires reconstructing history that was never recorded.

### Alternative B — "Disposition + Derived Feed": persist §13, derive §14

**Shape.** One persisted lifecycle axis with a small vocabulary derived from §13 — conceptually
**New → Follow-up → Success | Dump** — plus a mandatory next-action timestamp whenever the state
is Follow-up (§13 requires it). §09's *Today*, *Future* and the Action Feed's *Overdue* are
**computed** from that timestamp against server time and never stored. §12's pending-sync is a
separate boolean-shaped condition on the lead. Assignment and attribution stay as their §06
entities. Loss reason attaches to Dump. No temperature, no stage.

**How it handles the concepts.** Lifecycle is persisted and small. Follow-up status is derived —
correct by construction. Sync state is separated but *minimally* (a flag rather than a modelled
axis). Assignment and attribution are separate entities per §06. Stage and temperature are absent.

**Pros.**
- **No clock-driven job, ever.** The Action Feed is a query. Midnight is not an event.
- **Reconciles §09 and §13** without discarding either: §13 is the stored vocabulary, §09's
  Today/Future/Pending are the §14 buckets that §09 was describing.
- **Time-in-state is meaningful**, because every transition has a human actor and a business
  reason, which is exactly what R6's event-based audit is good at recording.
- Smallest vocabulary, which directly serves §60 ("sophisticated backend + simple frontend") and
  §95 (minimum *necessary* friction).
- Timezone handling lives in one query, not in stored data.

**Cons.**
- **It is an interpretation.** §09 names six states and this stores three or four. The project
  owner may reasonably say that "New, Today, Future, Pending, Success, Dump" was a decision, not a
  discussion, in which case this alternative is non-compliant.
- **"Pending" is dropped or reinterpreted.** If the business genuinely tracks *awaiting customer
  response* as distinct from *scheduled follow-up* — a real distinction when a loan sanction or a
  family decision is outstanding — B either loses it or quietly folds it into Follow-up.
- **Sync state as a flag under-models it.** §12 requires that a failed gate notify an authorized
  person and that conflicts be resolvable; a boolean has no room for "synced but flagged as a
  probable duplicate, awaiting review". This works until the first real conflict.
- **Assignment gaps are invisible on the state axis.** §42's helpdesk-captured, not-yet-assigned
  lead and §43's pending-enrichment lead both look identical to any other New lead unless the
  Action Feed queries the assignment side separately — which is correct, but is extra query
  surface that must actually get built.

**Complexity:** low to build, low to operate. Highest risk is under-modelling, not over-modelling.

**Reporting:** good. Clean funnel (New → Follow-up → Success/Dump), meaningful velocity, and the
Action Feed falls out of one indexed range query.

**Reversibility:** high. Adding an axis later (a fifth lifecycle value, a real sync-state axis, a
stage axis if M-8 says yes) is additive. This is the cheapest alternative to be wrong about.

### Alternative C — "Orthogonal Axes": persist a minimal lifecycle, model each other concept explicitly

**Shape.** Alternative B's lifecycle axis, unchanged and equally small — plus each remaining
concept given an **explicit, named, separately-valued axis** instead of a flag or an implicit
condition:

| Axis | Values (conceptual; all tenant-configurable masters under R4) | Who moves it |
|---|---|---|
| **Lifecycle state** | New · Follow-up · *(optionally Awaiting Response)* · Success · Dump | Human disposition / conversion |
| **Sync / verification gate** | Verified · Pending Sync · Sync Conflict (duplicate or clash flagged) | Device reconnect + server gate |
| **Assignment state** | Unassigned · Assigned · Pending Enrichment · Reassignment Pending | Manager / helpdesk / §57 departure |
| **Attribution state** *(on the claim contest, not the lead)* | Uncontested · Contested · Resolved | Claimant / authorized resolver |
| **Follow-up status** | *derived, never stored* — New · Today · Overdue · Scheduled | The clock |
| **Loss reason** | dependent attribute of the Dump state; vocabulary undefined (Q7) | Terminal disposition |
| **Temperature, weighted stage** | **not built** (§1.3, Q9, M-8) | — |

**How it handles the concepts.** Each of the eight concepts in §3 has exactly one home, and no
two share one. The critical case §12 describes — a lead in follow-up that has not passed the
server gate — is representable without contradiction, because the two facts sit on two axes.

**Pros.**
- **The only alternative that can represent §12 honestly under load.** "In follow-up, pending
  sync, and flagged as a probable clash" is three values on three axes, and §12 requires the
  system to be able to say exactly that.
- **Each axis has its own visibility rule**, which §11 requires: reps see lifecycle and
  assignment; attribution contest visibility is restricted to authorized leadership. Axes that are
  authorised differently must be modelled separately — collapsing them makes the §11 requirement
  unimplementable without field-level masking on a shared column.
- **Each axis has its own history**, so "who reassigned this and when" (§10, constantly asked by
  sales ops) is answerable independently of "who dispositioned this".
- **Reporting is unambiguous**: funnel keys on lifecycle only; data-quality dashboards key on sync
  and assignment; commission attribution keys on the claim contest. No report has to exclude
  values that belong to a different concept.
- **Growth is contained.** A new assignment condition adds a row to one axis instead of a value to
  the lifecycle vocabulary — which is the mechanism that stops §09's list from growing to fifteen.

**Cons.**
- **More moving parts.** Four persisted axes instead of one, each with an R4 master, each with
  seeded defaults, each needing a UI representation that does not confuse a rep. §10 of the spec
  warns against complexity leaking to the frontend (§60), and this design puts the burden of *not*
  leaking squarely on the UI.
- **Invites over-modelling.** The same reasoning that justifies four axes can be used to justify
  nine. The discipline — "an axis exists only where a record can legitimately be in two of these
  conditions at once" — has to be written down and enforced in review, or this becomes a swamp.
- **Furthest from §09's literal text.** It stores none of Today/Future/Pending, and it adds named
  concepts (sync gate, assignment state) that §09 did not list as states — defensible under "unless
  required", but it is a longer argument to make to the owner than B's.
- **More seeding and provisioning surface** per tenant, and more R4 masters whose defaults must be
  right before any real tenant exists (the same argument §C.3 of the reconciliation makes about
  roles).

**Complexity:** moderate to build, low to operate. The cost is up-front modelling, not runtime.

**Reporting:** best of the three. Every question has exactly one axis to ask it of.

**Reversibility:** high, and asymmetric in a useful way — C can be *simplified* into B by dropping
axes, whereas B must be *extended* into C by retrofitting axes onto existing lead rows. Adding an
axis later means backfilling values for every historical lead, and the historical truth is usually
unrecoverable (nobody recorded whether a 2026 lead was pending sync).

### 4.4 Comparison

| | **A — Literal Six** | **B — Disposition + Derived** | **C — Orthogonal Axes** |
|---|---|---|---|
| Fidelity to §09 literal text | Highest | Medium | Lowest |
| Fidelity to §13 | Low (remaps disposition) | Highest | Highest |
| Satisfies §12 honestly | **No** | Partially | **Yes** |
| Satisfies §11 visibility rule | No (if collapsed) | Yes (via §06 entity) | Yes, structurally |
| Needs a clock-driven job | **Yes** | No | No |
| Audit (R6) stays legible | **No** | Yes | Yes |
| Time-in-state analytics | Broken | Good | Good |
| Persisted vocabulary size | 6–7 | 3–4 | 4 axes × small |
| Build complexity | Low | Low | Moderate |
| Operational complexity | **High** | Low | Low |
| Cost of being wrong | High (history unrecoverable) | Low (additive fix) | Low (subtractive fix) |

---

## 5. Recommended State Machine

> ### RECOMMENDATION — requires the project owner's explicit approval
>
> **This is not a decision. It is a proposal.** BMexa §88 places canonical entities and
> relationships in the "MUST ASK BEFORE DECIDING" column, and §09 is exactly such a case.
> Nothing below may be implemented, seeded, migrated to, or treated as settled until the owner
> approves it in writing, and until the Open Product Decisions in §10 — especially **Q1, Q4 and
> Q7** — are answered. Delegation to an architect is not authorization.

**Recommended: Alternative C — "Orthogonal Axes", with the lifecycle axis held to four values.**

### 5.1 The recommendation stated

**Persisted lifecycle states — four:**

| State | Meaning | Terminal? |
|---|---|---|
| **New** | The lead exists and has not yet been worked. No disposition has been recorded. | No |
| **Follow-up** | Actively being worked. **Requires a next action and a next-action date** (§13). | No |
| **Success** | Converted. The exact conversion moment is **Q4** and is not decided here. | Yes (subject to Q5/Q6) |
| **Dump** | Closed without needing follow-up (§13). Carries a reason (vocabulary undefined — **Q7**). | Yes (subject to Q5) |

A possible fifth, **Awaiting Response** (the §09 "Pending" reading — awaiting the customer or a
third party, distinct from a scheduled callback), is **deliberately left undecided**: see **Q1**.
It is cheap to add later under this design and is the one place where I would rather ask than
guess.

**Three further persisted axes, each independent of lifecycle and of each other:**

- **Sync / verification gate** — Verified · Pending Sync · Sync Conflict. Every lead created
  online is Verified at creation. §12's offline leads enter Pending Sync and leave it only when the
  server-side duplicate/clash check has actually run. A failed check lands in Sync Conflict and
  notifies an authorized person (§12), and Sync Conflict is not silently resolvable by the
  creating rep.
- **Assignment state** — Unassigned · Assigned · Pending Enrichment (§43) · Reassignment Pending.
  Owner and Handler remain two separate references per §10; this axis describes the *condition*,
  the references describe *who*, and the Assignment Log (§06) records *the history*.
- **Attribution state** — a property of the **claim contest**, not of the lead: Uncontested ·
  Contested · Resolved. Claims coexist (§11); the lead never carries a single winning claimant as
  its only attribution fact.

**Derived, never stored:** New-in-feed, Today, Overdue, Scheduled/Future. All computed from the
next-action timestamp against authoritative server time (§18's principle, applied here). These
are §14's Action Feed buckets and §09's Today/Future — which under this recommendation are the
*same thing seen from the screen*.

**Not built:** temperature (§1.3 — absent from the spec, Q9), weighted sales stage (M-8, out of
scope here), lead score, portal sync state (Q12).

### 5.2 Why C over B

The two are close, and B is genuinely defensible. Three reasons decide it:

1. **§12 is not satisfiable by B under load.** The spec's most precisely-specified state —
   with a named failure path and a capitalised prohibition — needs three values, not two, the
   moment a real conflict occurs. B's flag has nowhere to put "synced, but flagged as a probable
   duplicate, awaiting authorized review".
2. **§11 requires different visibility for different facts about the same lead.** Facts that are
   authorised differently cannot share a column without field-level masking, which is a harder
   thing to get right than a separate axis and a separate policy.
3. **The asymmetry of being wrong.** C can be collapsed to B by dropping an axis, losing nothing
   but tidiness. B can only become C by retrofitting axes onto historical rows whose true values
   were never recorded. §L.5 of the reconciliation report makes precisely this argument about
   scope anchors: adding the dimension now is free, retrofitting it is expensive. The same logic
   applies here.

### 5.3 Why not A

A is the only alternative that survives a strict reading of "do not invent additional statuses",
and that is a real argument that only the project owner can overrule. But it requires a
clock-driven job that rewrites business state with no business event, which under R6 either
floods or breaks the audit log, and it makes lead velocity — the most basic pipeline metric —
uncomputable. **If the owner's answer to Q1 is "the six states in §09 are decided, implement them
as written", then A is what gets built, and §8's data-model consequences change substantially.**
That outcome is why this document is a recommendation and not a decision.

---

## 6. Transition Matrix

Conceptual only. No SQL, no code, no column names presented as decisions. "Trigger" names the
business event; "Actor" names who is permitted to cause it, subject to the authorization model
(which is a **separate blocker** and is not decided here).

### 6.1 Lifecycle axis

| From | To | Trigger | Actor | Notes |
|---|---|---|---|---|
| *(none)* | **New** | Lead capture — walk-in, helpdesk (§42), rep entry, bulk import, offline capture (§12) | Any capture-permitted user or an import | The default state. Offline captures enter New *and* Pending Sync simultaneously. |
| **New** | **Follow-up** | First disposition recorded with a next action and date (§13) | Handler | The date is **mandatory** — §13 makes it part of the value's definition. |
| **New** | **Dump** | Immediate disqualification (wrong number, not a prospect, obvious duplicate) | Handler, or a permitted reviewer | Requires a reason (Q7). Common from helpdesk-captured leads. |
| **New** | **Success** | Direct conversion without an intervening follow-up (walk-in who books on the spot) | Handler | Rare but real at launch events (§42). Must not be forbidden. |
| **Follow-up** | **Follow-up** | A new activity is logged and the next action date is moved | Handler | A **self-transition**, and the most frequent event in the system. It must be recorded as an activity, not as a state change, or the state history becomes noise. |
| **Follow-up** | **Success** | Conversion event — exact definition is **Q4** | Handler + (if Q4 says so) the booking verification step | See §6.4. |
| **Follow-up** | **Dump** | Disposition: closed, no follow-up needed (§13) | Handler | Requires a reason (Q7). |
| **Follow-up** | **Awaiting Response** | *Only if Q1 adds this state.* Customer/third party owes the next move | Handler | Distinguished from Follow-up by who owes the action. |
| **Awaiting Response** | **Follow-up** | Response received, or a chase is scheduled | Handler | *Conditional on Q1.* |
| **Dump** | **Follow-up** | **Re-engagement — permitted only if Q5 says so** | Permission-gated; see E-01 | If forbidden, the path is a *new lead* on the same Person instead. |
| **Success** | **Follow-up** | **Reversal — permitted only if Q6 says so** | Permission-gated | Arises when a booking fails verification (§20) or is cancelled (§35). |
| **Dump** / **Success** | *(merged away)* | Duplicate merge (§09) | Permitted merger | The surviving lead's state is decided by the merge rule — **Q10**. Neither record is deleted (§56, §07). |

**Forbidden transitions, and why:**

- **Anything → New.** New means *never worked*. Once a disposition exists, that fact is historical
  and §07 forbids destroying history by rewriting state.
- **Dump → Success directly.** A dumped lead that converts must pass through an explicit
  re-engagement (Q5) so the reversal is visible in history and in the funnel, rather than
  appearing as a lead that was closed and then silently won.
- **Any lifecycle transition performed by a scheduled job.** Under this recommendation, every
  lifecycle transition has a human actor and a business event. The clock changes *derived*
  buckets only. (Under Alternative A this rule cannot hold — which is §4's central objection to A.)

### 6.2 Sync / verification gate axis

| From | To | Trigger | Actor |
|---|---|---|---|
| *(none)* | **Verified** | Created while online | System, at creation |
| *(none)* | **Pending Sync** | Created offline (§12) | System, at creation on device |
| **Pending Sync** | **Verified** | Reconnect; server-side duplicate and clash detection runs and finds nothing | System |
| **Pending Sync** | **Sync Conflict** | Reconnect; detection finds a duplicate or a competing claim (§12) | System; **notifies an authorized person** |
| **Sync Conflict** | **Verified** | Authorized human resolves the conflict (merge, dismiss, or resolve attribution) | Authorized resolver — **not** the creating rep |

The lifecycle axis moves independently throughout. A lead can be dispositioned to Follow-up while
Pending Sync; §12 only forbids *pretending the gate has passed*, not working the lead.

### 6.3 Assignment axis

| From | To | Trigger | Actor |
|---|---|---|---|
| *(none)* | **Unassigned** | Helpdesk or import capture with no handler (§42, §57) | System |
| *(none)* | **Assigned** | Capture by the person who will work it | System |
| **Unassigned** | **Assigned** | Assignment / "summon a rep" (§42) | Manager, helpdesk, or routing rule |
| **Assigned** | **Assigned** | Reassignment — **new handler, Owner unchanged** (§10) | Manager; logged to the Assignment Log |
| **Assigned** | **Unassigned** | Handler deactivated or leaves (§57) | System, on deactivation |
| **Assigned** | **Pending Enrichment** | Helpdesk capture handed to a field rep to complete (§43) | Helpdesk |
| **Pending Enrichment** | **Assigned** | Required information supplied | Handler |

### 6.4 The one transition that is not mine to define

**Follow-up → Success.** §13 says "converted". §20 gives three booking milestones and §17
forbids confusing them. Three candidate definitions, each self-consistent:

| Reading | Success means | Consequence |
|---|---|---|
| **(a) Booking Initiated** | The rep submitted a booking | Reps hit Success early; the funnel overstates conversion; reversals are common when verification fails |
| **(b) Pending Verification** | Booking submitted and accepted into verification | Middle ground; still reversible |
| **(c) Booked** | Builder-side verification completed (§20 Stage 3) | Funnel matches revenue; reps' Success is delayed and outside their control, which has real behavioural effects on a commission-motivated field team |

**This is Q4.** It is a business decision with reporting, commission and rep-behaviour
consequences, and it is not an engineering call.

---

## 7. Edge Cases

Twenty-four. Each states the situation, what the recommended design does, and — where the spec
does not settle it — which open question owns it. Where the answer is "ask", that is the finding.

**E-01 — A dumped lead re-engages six months later.**
The prospect calls back. Two legitimate models: (i) reopen the existing lead (history is
continuous, but the funnel gains a lead that was counted as closed, and time-in-pipeline becomes
meaningless), or (ii) create a *new* lead against the same Person (§06/§07 explicitly allow a
Person to hold multiple leads; the funnel stays clean; the link between attempts must be
explicit or the history fragments). The spec is silent. **Q5.** My inclination is (ii) with an
explicit "previous lead" reference, because it keeps the funnel honest and §07 already blesses
multiple leads per Person — but this is a product call, not mine.

**E-02 — Duplicate merge where the two leads are in different states.**
Rep A's lead is in Follow-up; a helpdesk-captured duplicate is New; a third is Dumped. Merging
must decide the surviving state, the surviving handler, the surviving owner, the surviving
next-action date, and what happens to the losers. §56 forbids casual destruction and §07 forbids
destroying historical identity, so the losers are closed-and-linked, never deleted. The
state-precedence rule (does Success beat Follow-up? does Follow-up beat Dump?) is **Q10**.

**E-03 — Duplicate merge where one lead is already Success.**
The strongest case for a precedence rule: if one of the merged records converted, the survivor is
Success and the merge must not orphan the booking's link to a lead that has just been closed.
Merging into a converted lead also has commission consequences (§32) if the two leads carried
different attribution claims — the claims must survive the merge and remain individually
resolvable (§11). **Q10 + Q11.**

**E-04 — Reassignment mid-pipeline.**
Manager moves a Follow-up lead from rep A to rep B. **The lifecycle state does not change** —
that is the entire point of separating assignment from lifecycle (§3.5). Handler changes, Owner
does not (§10), the Assignment Log gains a row (§06), and the next-action date survives the move.
Under a single-axis design this is the case where "Unassigned" as a lifecycle value starts
corrupting funnel reports.

**E-05 — A lead goes cold, then hot again.**
**BMexa defines no temperature concept at all** (§1.3, §3.4). Under this recommendation, "going
cold" is not a state change — it is a next-action date receding, repeated no-contact activity
outcomes (§49's Not Connected / No Answer), or a long gap since last activity. All three are
*derivable*. "Going hot again" is likewise an activity, not a transition. **Nothing changes on the
lifecycle axis.** If the business needs an explicit temperature, that is **Q9**, and it is a new
axis, not new lifecycle values.

**E-06 — Offline-created lead that turns out to be a duplicate on sync.**
§12 is explicit: the gate runs on reconnect and a conflict notifies an authorized person. The lead
sits in **Sync Conflict** while its lifecycle state remains whatever the rep recorded. The rep
must not be able to clear the conflict themselves — otherwise the gate is decorative. This is the
case Alternative B cannot represent, and the reason C is recommended.

**E-07 — Offline-created lead that syncs into an attribution clash.**
Same mechanics as E-06, different resolver: §11 requires *authorized leadership* to resolve
attribution, and requires that the rep **not see** the competing claim. So Sync Conflict must be
able to say "there is a conflict" to the rep without saying "a CP claimed this prospect three days
ago". That is a field-level visibility requirement, and it is why attribution is its own axis with
its own authorization.

**E-08 — Offline lead whose creator is deactivated before the device ever reconnects.**
The queued operation belongs to a user who no longer has access (§57 deactivation; §47's sync
must handle "authentication expiry, revoked permissions"). The record must still arrive, must
still pass the gate, and must land **Unassigned** with the historical actor preserved (§57:
"preserve historical actor identity"). It must not be silently dropped, and it must not be
attributed to whoever happens to be logged in next. **Q13** covers whether a deactivated user's
queued captures are accepted at all.

**E-09 — Same Person, two projects, divergent outcomes.**
§06 makes a lead a Person × Project × process relationship, so this is two leads. One reaches
Success, the other is Dumped. Both are correct simultaneously, and the Person is now a Customer
in one context and a closed prospect in another (§07: Customer is a *context*, not a record).
Reporting must never aggregate these into one per-Person outcome. Note this interacts with
**M-5** (lead uniqueness boundary) — which is a *different* blocker and is not resolved here.

**E-10 — Helpdesk capture with no assignment (§42).**
Name, phone, CP/source, nothing else. Lifecycle **New**, assignment **Unassigned**, sync
**Verified**. §42 forbids blocking the queue on a complete profile, so incompleteness must not
prevent the record existing. The Action Feed's "New leads" bucket (§14) must surface these, and
"unassigned for N hours" is an escalation condition (§58) — though **no SLA threshold is defined
anywhere in the spec** (Q14).

**E-11 — Pending enrichment (§43).**
A lead that is real, assigned, being worked, and missing required fields. This is an
**assignment-axis** condition, not a lifecycle one: it describes an obligation on the handler, not
a position in the sale. Folding it into lifecycle would mean a lead cannot be both "in follow-up"
and "missing its budget field", which it plainly can be. §43's "can maintain" is permissive —
whether the queue is built in MVP is **Q8**.

**E-12 — CP walk-in with an unverified CP identity (§44).**
The lead is real and workable; the *claimant* is provisional. Under this design the unverified
condition attaches to the CP profile and to the attribution claim, **not** to the lead's
lifecycle. The lead proceeds normally; the claim is marked unverified and reconciled later. If
that lead converts before reconciliation, commission eligibility (§32/§40) is gated on the
unresolved claim — which is correct, and is the reason attribution must not be a single resolved
value on the lead.

**E-13 — Attribution contested *after* conversion.**
A CP files a claim on a prospect who has already booked. §11 requires claims to coexist and be
preserved; nothing in §11 limits claims to open leads. So a Success lead can acquire a Contested
attribution state without its lifecycle state changing. Commission (§32) must key on the
*resolved* claim, not on the lead's state, and the resolution can postdate the booking. **Q11**
asks whether there is a cut-off after which claims are refused.

**E-14 — Lead converts, then the booking fails verification (§20 Stage 2 → rejected).**
If Q4 answers (a) or (b), the lead is already Success and must come back. That is a
**Success → Follow-up** reversal, which is only legal if Q6 permits it, and it must be visible in
the funnel rather than silently rewritten (§07, R6). If Q4 answers (c), this case cannot arise —
which is a genuine argument for (c).

**E-15 — Lead converts, booking is later cancelled (§35).**
Different from E-14: verification succeeded and the transaction later unwound. §35 requires the
business state and inventory consequences to be preserved — "handled offline does not mean destroy
history". The lead's Success is a *historical fact* and rewriting it would falsify every past
report. Recommended: the lead stays Success; the cancellation lives on the booking. **Q6** must
confirm, because the alternative (reverting the lead) is what many CRMs do and it silently
restates prior quarters.

**E-16 — Unit transfer (§26).**
§26 states in capitals that a transfer must **not** be treated as a cancellation for CP clawback.
Under the recommended design the lead's state is *untouched* by a unit transfer — the lead
converted once and remains converted. Any design where the lead state flaps on a transfer will
eventually be read by the commission engine as a cancellation, which is the exact failure §26
forbids. (The adjustment taxonomy itself is **M-9** — a different blocker, not resolved here.)

**E-17 — Bulk import of a legacy lead list.**
Several questions the spec does not answer: do imported leads land in New or in their historical
state; does duplicate/clash detection (§09, §11) run over the import; are follow-up SLAs and
escalations (§58) triggered for a thousand records at once; is the importing user the handler;
and are imports subject to the §12 gate. §93's idempotency test applies directly — a retried
import must not create a second copy of every lead. **Q3** and **Q14**.

**E-18 — A follow-up date passes with no activity.**
**Nothing happens to the lifecycle state.** The lead appears in the Overdue bucket (§14) and is
eligible for escalation (§58). Under Alternative A this is a state change written by a job at
midnight; under the recommendation it is a comparison in a query. This edge case, more than any
other, is what separates the two designs in daily operation.

**E-19 — A follow-up scheduled far in the future.**
"Call me after possession in 18 months." Legitimate and common. The lead is in Follow-up with a
distant date, is invisible in every daily feed, and is indistinguishable from an abandoned lead by
any "last touched" metric. Whether there is a maximum permitted next-action horizon, and whether
long-dated leads should be parked differently, is **Q2**. Note the temptation: adding a "Nurture"
or "Long-term" lifecycle value here is exactly the vocabulary sprawl §09 warns against, and the
same need is met by a date threshold in a query.

**E-20 — The handler leaves the company (§57).**
Leads become **Unassigned** on the assignment axis; lifecycle untouched; Owner history preserved;
the Assignment Log records the system-initiated change with the departing employee as the
historical actor. §57 is explicit that history must not be rewritten "as if the employee never
existed". Bulk reassignment by authorized management is then an ordinary assignment transition per
lead, each logged.

**E-21 — A tenant deactivates or renames a lifecycle master value that live leads reference.**
R4's whole argument: values are rows, retirement is a deactivation flag, and a retired value stays
resolvable for historical records while disappearing from pickers for new ones. Deletion of a
referenced value must fail loudly rather than cascade (R4's restrict-on-delete reasoning). The consequence for this decision is that **no
application logic and no report may branch on a lifecycle value's code** — they branch on the
semantic column (terminal / converted / open), exactly as R4 requires for `lead_stages.stage_type`
and R2 requires for role names. Leads stranded on a deactivated state are a real operational
condition needing a reporting answer.

**E-22 — Two users disposition the same lead simultaneously.**
Rep and manager both act within the same second: one dumps, one schedules a follow-up. §68 does
not list lead disposition among its strong-consistency cases (holds, bookings, receipts,
commission), so a last-writer-wins outcome is arguably acceptable — but §61 requires the loser to
be told what happened and what did not. The dangerous variant is a concurrent transition into a
*terminal* state, where the loser's follow-up date is silently discarded. **Q15.**

**E-23 — Backdated disposition after a multi-day offline stretch.**
A rep works three days without connectivity and syncs a week's activity at once. The activity
timestamps are historical; the lead's *current* state is the net result. §47 requires the sync
system to handle duplicates, retries, conflicts and stale data, and §93 requires that a retried
request not create duplicate business transactions. The state history must therefore record when
the event *happened*, not only when it *arrived* — two different timestamps, and conflating them
corrupts every velocity metric. This is a consequence for §8's data model.

**E-24 — A CP views their own lead's state through the CP portal (§39).**
§39 permits a CP to see "relevant lead information, attribution information, pipeline status,
commission status". §11 forbids exposing competing claims. So the same lead renders differently
for a CP than for a rep than for leadership — and it is the *axes* that differ, not just the
fields: the CP sees lifecycle and (their own) attribution, never the contest. A single collapsed
status column makes this filtering a per-value exercise; separate axes make it a per-axis policy.
(Whether CPs are users of the builder's tenant at all is **M-2** — a different blocker.)

---

## 8. Data Model Consequences

**Conceptual only. No SQL. No DDL. No migration.** Everything below describes *what the design
implies*, for a schema that will be written and approved separately. Names are descriptive, not
proposed identifiers.

### 8.1 Masters, not enums (R4)

Each persisted axis needs its own tenant-scoped master table of rows — never a Postgres `ENUM`,
never a `CHECK`-constrained text column standing in for one. That is R4 without exception, and R4
explicitly refuses the "it's just a list of statuses" exemption.

Each such master carries R4's standard shape: a machine `code`, a tenant-editable `label`,
`sort_order`, `is_active` for retirement without orphaning history, `is_system` protection for
values the product's own logic depends on, R1's `tenant_id` with RLS enabled and forced, and R5's
`custom_attributes`.

**The critical addition — semantics in a column, not in the code.** R4 states the rule directly:
`lead_stages.stage_type` exists "because forecasting must know what a value *means* without
reading its code", and "reports filter on `stage_type`, never on `code`". The lifecycle master
therefore needs at least:

- a **state-type** semantic column distinguishing *open* / *converted* / *closed-without-
  conversion* — so that a tenant renaming "Dump" to "Archived", or adding their own terminal
  value, does not silently break the funnel;
- a **terminal** flag, which the existing `lead_statuses` shape already has, to stop follow-up
  automation and exclude from open-work counts;
- a **default** marker for the state a newly captured lead receives (the existing shape has this,
  with a one-default-per-tenant guarantee);
- a **requires-next-action** property, because §13 defines Follow-up as *"requires next
  action/date"* — that requirement is a property of the value, and encoding it as "the value whose
  code is `follow_up`" is precisely the hardcoded-name failure R2 and R4 both forbid.

The existing `lead_statuses` table in the Phase 0 schema is shaped close to this and is **missing
the state-type and requires-next-action semantics**. Whether it is extended or replaced is an
implementation decision that follows approval — not part of this recommendation, and explicitly
not performed here.

### 8.2 The lead record

References, not values: the lead points at its lifecycle state, its sync state, its assignment
state; it carries the **next-action timestamp** as a real typed column (not in
`custom_attributes` — R5's governance line is explicit that anything the *product* reasons about
gets a real column, and the Action Feed, escalation and every overdue query reason about this
value); and it carries separate **Owner** and **Handler** references per §10.

It carries `custom_attributes` per R5 (mandatory for every new CRM record type), and under the
same governance line **nothing that decides what a user may do or how a lead is reported may be
read from it** — so no lifecycle state, no temperature, no assignment condition hidden in jsonb.

It does **not** carry: a single resolved attribution claimant (§11 — claims are multi-valued and
live in their own entity), a temperature (not in the spec), a pipeline stage (M-8, undecided), or
any derived bucket (Today/Future/Overdue are queries).

### 8.3 State transition history — and why the audit log is not enough (R6)

R6 requires an event-based, append-only audit written in business language at the point of the
business action: `lead.state_changed` with actor, time, from, to, reason, authorization context
(§54). That is mandatory and not in question.

**But the audit log cannot be the source of pipeline analytics**, for the reason the reconciliation
report already gives for the Assignment Log (§D.3): R6 keeps 12 months hot and then exports aging
partitions to cold storage. "How long did leads spend in Follow-up in 2026?" must still be
answerable in 2028. It must also be answerable by an ordinary tenant-scoped query, whereas the
audit log is a security artefact with its own access rules.

So the design implies a **business-level state history**, one row per lifecycle transition,
distinct from and in addition to the audit event — exactly as §06 makes **Assignment Log** a
business entity distinct from **Audit Event**. Each row needs both the **effective time** (when
the business event happened) and the **recorded time** (when the server learned of it), because
E-23's offline backdating makes those genuinely different and conflating them corrupts velocity
metrics.

Under R6 this history is append-only in practice as well as in principle: a correction is a new
row, never an edit.

### 8.4 Separate entities, per §06

- **Assignment Log** — canonical entity (§06). Who, to whom, when, why, by whose authority (§10).
  Survives the audit log's hot window. Records system-initiated changes too (§57 departures).
- **Lead Attribution Claim** — canonical entity (§06). Multiple coexisting claims per prospect,
  each with claimant, basis, time, and resolution state. Never overwritten by a later claim (§11).
  Its own visibility rule, restricted from reps (§11) and partially visible to the claiming CP
  (§39).
- **Activity / follow-up records** — each contact attempt with its own outcome (§49's Not Connected
  / No Answer / Connected). These are *per-activity outcomes*, not lead states, and keeping them
  separate is what makes E-05 ("cold then hot") derivable without inventing a temperature axis.

### 8.5 What the design deliberately does not create

No temperature master, no lead-score column, no weighted-stage reference, no portal-sync axis, no
"nurture" state, no loss-reason values invented to fill the gap at §1.3. Each is absent from the
spec, and Rule 1 plus R12 make absence a question to raise, not a blank to fill.

### 8.6 Constraints that follow from the design

- **R1** applies to every new table and every master without exception, including the masters —
  R4 is explicit that "it's just a list of statuses" is not an exemption.
- **The next-action timestamp is mandatory when the lifecycle state's requires-next-action
  property is true** (§13). Enforced at the data layer, not only in the form.
- **A terminal state's reason** (Q7's vocabulary, once defined) is required when the state's
  semantic type is closed-without-conversion.
- **Foreign keys into masters are composite and restrict deletion** (R4), so a mistaken deletion
  fails loudly instead of taking leads with it.
- **No application logic branches on a state's `code`** (R2's general form, restated by R4):
  branch on the semantic column.

---

## 9. Reporting Consequences

### 9.1 The funnel

Under the recommendation there is exactly **one** axis a conversion funnel may key on — lifecycle
— and it keys on the *semantic type*, never on codes (R4). The basic funnel is
**Captured → Worked → Converted**, with the closed-without-conversion bucket beside it:

- *Captured* = all leads created in the period, regardless of current state.
- *Worked* = leads that have ever left New (answerable from the state history in §8.3, not from
  the current state — a lead that went New → Follow-up → Dump must count as worked).
- *Converted* = leads whose current state has the converted semantic type.

**The denominator is contaminated unless Dump is decomposed.** §2.5 established that Dump covers
wrong numbers, test data, duplicates and genuine losses alike. A conversion rate computed against
all Dumps understates lead quality and, worse, understates it *unevenly* across sources — helpdesk
capture (§42) produces far more junk than a CP referral. Until Q7 defines the reason vocabulary,
**no defensible source-quality or CP-quality report can be produced**, and that should be said
out loud rather than shipped as a chart.

### 9.2 Velocity and time-in-state

Available under B and C, **not available under A** (§4). Time-in-state requires transitions with
business meaning; if the clock is an actor, "days in Today" is noise. With §8.3's effective-time
column, average days New → first Follow-up (the responsiveness metric sales leadership actually
manages) and Follow-up → Success are both computable, and both survive the audit log's retention
window.

### 9.3 The Action Feed (§14) is a report, not a state

Under the recommendation §14's five priorities are five queries: active holds (inventory, not
lead), New leads (lifecycle = default state), Today's follow-ups (next-action date within the
viewer's day, in server-authoritative time per §18's principle), scheduled visits (activity
records), overdue actions (next-action date in the past, non-terminal lifecycle).

Two consequences. First, the next-action timestamp is on the hot path of the most-used screen in
the product, which makes it an indexing concern (and under §88 ordinary indexing is Claude's to
decide, so it need not be escalated). Second, "the viewer's day" needs a timezone answer — a
single-city builder can use one tenant-level timezone; a multi-region one cannot. That is a live
question the moment M-6 (Region) is answered, and is noted here only because the Action Feed is
where it first bites.

### 9.4 Escalation and exception reporting (§58, §63)

§63 demands every dashboard element answer "what decision or action does this enable". The
separated axes make the exception queues fall out naturally, each keyed on one axis:

| Queue | Axis | Section |
|---|---|---|
| Overdue follow-ups | derived from next-action date | §58 |
| Unassigned leads | assignment | §42, §57 |
| Pending enrichment | assignment | §43 |
| Pending sync / sync conflicts | sync gate | §12 |
| Contested attribution awaiting resolution | attribution (restricted visibility) | §11 |

Under a single collapsed status column, each of these becomes "the status is one of *this* subset
of values", the subsets overlap, and every new condition edits every query. That is the reporting argument for §3's
separation, stated in operational terms.

### 9.5 CP-facing reporting (§39)

A CP sees pipeline status for their own leads, and must not see competing claims (§11). With
separate axes this is one authorization rule per axis. With a collapsed column it is a per-value
filter — the kind of rule that is correct on the day it is written and wrong after the next value
is added. §45's warning applies directly: search must never become a side door around
authorization, and a lead-state filter in a CP-facing list is exactly such a door if the axis
carries mixed-sensitivity values.

### 9.6 What cannot be reported, and should not be promised

- **Weighted forecast / expected-value pipeline.** No weighted stage exists (M-8). Do not build a
  forecast chart from lifecycle states by assigning probabilities to them; that reintroduces
  `deal_stages` by the back door.
- **Lead quality by temperature.** No temperature exists (§1.3).
- **Reason-coded loss analysis.** No vocabulary exists (Q7).
- **Source-quality comparison.** Blocked by §9.1's denominator problem *and* by the fact that
  channel source and CP attribution are two different facts (§B.3(c) of the reconciliation) — one
  field cannot carry both, so a "leads by source" chart built on a single column will
  systematically misreport CP-originated leads.

### 9.7 Reports must key on semantics, not codes

Restating R4 because it is the rule most likely to be broken quietly in a reporting layer: a
tenant may rename any state and add their own. Every report filters on the semantic column
(open / converted / closed) and the terminal flag. A report containing a literal state code is a
defect, and it is the kind that surfaces months later as "the funnel stopped counting" after a
cosmetic rename nobody reviewed as a breaking change.

---

## 10. Open Product Decisions

Only the project owner can answer these. Per BMexa Rule 1 and R12, none is guessed, and none of
the recommendations above should be implemented while Q1, Q4 or Q7 is outstanding — those three
change the machine's shape, not merely its labels.

**Q1 — (blocks everything) Is §09's six-state list a decision or a discussion?**
Specifically: are *Today* and *Future* persisted states or Action Feed buckets, and is *Pending* a
real persisted state meaning "awaiting customer/third-party response"? If the six are decided as
written, **Alternative A is what gets built** and most of §8 changes.

> **DECIDED by Product Owner, 2026-09-12 (see [AD-01A §8](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12)).**
> §09's list was a discussion, not a decision. **Pending is rejected** as a fifth lifecycle state.
> The lifecycle stays four values: **New / Follow-up / Success / Dump**. "Awaiting Response,"
> "Blocked," *Today*, *Future*, and *Overdue* are operational/Action-Feed conditions, derived from
> next-action timing — never persisted lifecycle state. No "Blocked" lifecycle state is created.

**Q2 — Is there a maximum next-action horizon, and how are long-dated leads handled?**
E-19: a follow-up 18 months out is invisible in every feed and indistinguishable from abandonment.
Is there a cap, a parked treatment, or nothing?

**Q3 — What is the initial state of an imported lead, and does import run the duplicate/clash gate?**
E-17. Also: does an import trigger follow-up SLAs and escalations, and who is the handler?

**Q4 — (blocks the funnel) At exactly which booking milestone does a lead become Success?**
§20's Booking Initiated, Pending Verification, or Booked (§6.4). Affects every conversion report,
rep behaviour, and whether Success is reversible at all.

> **DECIDED by Product Owner, 2026-09-12 (see [AD-01A §8](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12)).**
> **Success = §20 Stage 3, Booked, after the required builder-side verification milestone.** Booking
> has its own, separate lifecycle/state machine; the Lead Lifecycle must **not** absorb Booking
> states such as Initiated or Pending Verification. A subsequently cancelled booking must **not**
> rewrite the historical Lead Lifecycle from Success back to Dump — the cancellation lives on the
> booking, consistent with §35 and R6. Q6 (immediately below) narrows accordingly but is **not**
> itself decided by this.

**Q5 — Can a Dumped lead be re-engaged, or does re-contact create a new lead?**
E-01. If re-engagement is allowed, who may authorize it, and how is the funnel restated?

**Q6 — Is Success reversible, and does a cancelled booking change the lead's state?**
E-14 and E-15. Recommended position: a converted lead stays converted and the cancellation lives on
the booking (§35) — but this restates or preserves past reports depending on the answer, so it is
the owner's call.

**Q7 — (blocks terminal states) What is the Dump reason vocabulary?**
The spec defines none (§1.3, §2.5). Until it exists, Dump conflates wrong numbers with genuine
losses and no source-quality reporting is defensible. Also: is a reason **mandatory** on Dump?

> **DECIDED by Product Owner, 2026-09-12 (see [AD-01A §8](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12)).**
> The **three-dimensional semantic framework** proposed in AD-01A is approved: (a) opportunity
> validity class, (b) responsibility locus, (c) recoverability posture. **No reason values are
> approved or finalized yet** — that remains open (see N-4). A terminal non-conversion disposition
> **must** carry a reason, and the historical reason on a lead must be preserved, never silently
> rewritten.

**Q8 — Is §43's pending-enrichment queue in MVP scope?**
§43 says the system "can maintain" it — permissive, not mandatory. §64's MVP list does not name
it.

**Q9 — Does the business need lead temperature (hot/warm/cold) or a lead score?**
Absent from all 97 sections. **Not built under this recommendation.** If wanted, it is a new axis
and a new requirement, not a reinterpretation of §09.

**Q10 — What is the state-precedence rule when duplicate leads are merged?**
E-02, E-03. Which state, handler, owner and next-action date survive; what happens to the merged-away
records (closed-and-linked is assumed under §56/§07, not decided); and how their attribution claims
carry over.

**Q11 — Can an attribution claim be filed against an already-converted lead, and is there a cut-off?**
E-13. Directly affects CP commission eligibility (§32, §40).

**Q12 — Are lead-portal integrations (listing sites) in scope?**
§72 names WhatsApp, email, telephony and accounting exports only. If lead portals are coming, that
is a **second** sync concept distinct from §12's offline gate, and it must be scoped before either
is designed — not merged into it afterwards.

**Q13 — How are offline captures from a since-deactivated user handled on sync?**
E-08. Accept and leave unassigned with the historical actor preserved, or reject? §47 requires the
sync system to handle revoked permissions; it does not say which way.

**Q14 — Are there response-time SLAs on New and Unassigned leads, and what are the escalation thresholds?**
§58 endorses escalation for missed follow-ups but names no numbers; §42's helpdesk queue implies
urgency without quantifying it.

**Q15 — What happens when two users disposition the same lead concurrently?**
E-22. §68 does not list lead disposition among the strong-consistency cases; is last-writer-wins
acceptable, and what must the loser be told (§61)?

**Q16 — Who may move a lead into a terminal state, and is Dump permission-gated or free to the handler?**
§13's UX aims at one-tap dispositions; §95 warns that minimum taps is the wrong objective.
Terminal transitions are the ones that remove work from a queue, which is exactly where a
low-friction control has an incentive problem.

---

## 11. Architect Recommendation

> **Superseded in part by Product-Owner decision, 2026-09-12 — see
> [AD-01A §8](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12).**
> The paragraph below is the *original* recommendation as first proposed. It is retained verbatim as
> the historical record. The **current, decided** shape is: lifecycle held at **four** values (no
> *Awaiting Response* / "Pending" — Q1 decided against it); **Success = Booked, §20 Stage 3** (Q4
> decided); the **sync/verification gate is split into two concepts**, not one axis (decided); the
> **assignment-condition axis is eliminated** — zero persisted values, derived from Owner/Handler/
> Assignment Log instead (decided); and the design is now named the **Orthogonal Lead Model**, not
> "Alternative C." Q2, Q3, Q5, Q6, Q8–Q16 remain open and this document remains **NOT APPROVED FOR
> IMPLEMENTATION**.

**Recommended (original, historical): Alternative C — "Orthogonal Axes", with a four-value lifecycle.** Persist a small
lifecycle vocabulary (**New · Follow-up · Success · Dump**, possibly plus *Awaiting Response*
pending Q1); give the **sync/verification gate** (§12), **assignment condition** (§10, §42, §43,
§57) and **attribution contest** (§11) each their own axis; and **derive** §09's *Today* / *Future*
and §14's *Overdue* from a next-action timestamp against server time rather than storing them.

**Why, in three sentences.** §09 and §13 cannot both be the persisted vocabulary, and §14's Action
Feed shows that *Today* and *Future* are buckets on a screen rather than conditions of a record —
storing them requires a nightly job that rewrites business state with no business event, which
under R6 either floods the audit log or breaks it, and which makes lead velocity uncomputable.
Once that is accepted, the remaining choice is whether the non-lifecycle concepts get explicit
axes (C) or flags (B), and §12 settles it: the spec's most precisely-specified state has a defined
failure path — "synced, but flagged as a probable duplicate, awaiting authorized review" — that a
flag cannot express and that §12 forbids the system from faking. §11 adds an independent reason:
facts about the same lead that are *authorised differently* cannot share a column.

**Why the cost of being wrong favours C.** C collapses into B by dropping an axis and losing only
tidiness. B becomes C only by retrofitting axes onto historical leads whose true values were never
recorded — and nobody can reconstruct, two years later, whether a given lead was pending sync. That
is the same asymmetry §L.5 of the reconciliation report uses to argue for adding a scope anchor
now: the dimension is free today and expensive later.

**What this does not decide.** Nothing about M-2 through M-12. Not the authorization model, not
Person's boundary against Employee (M-4), not the lead uniqueness/clash scope (M-5), not whether a
weighted pipeline exists (M-8), not the booking adjustment taxonomy (M-9). Not the schema: no SQL
appears above and none should be written from it yet. Not the seeded values: `lead_statuses`,
`lead_stages` and `lead_loss_reasons` are untouched by this document.

**PROPOSED — NOT APPROVED.** This is a recommendation under BMexa §88's "MUST ASK BEFORE DECIDING"
column. It requires the project owner's explicit written approval before any implementation,
seeding, migration or schema work begins, and **Q1, Q4 and Q7 must be answered first** — Q1 because
"the six states are decided as written" would make Alternative A the answer instead, Q4 because it
defines the funnel, and Q7 because the terminal state is unusable for reporting without it. Under
§97: when in doubt, stop and ask. This document is the asking.
