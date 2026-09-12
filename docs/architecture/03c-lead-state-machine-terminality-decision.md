# Architecture Decision 01C — Lead State Machine: Terminality (Q5 · Q6)

**STATUS: PROPOSED — NOT APPROVED**

> Nothing in this document is decided, approved, implementable, seedable or migratable. It contains
> no SQL, no schema, no migration, no column, table or type name, and no implementation of any kind.
> Under Master Spec **§88** every recommendation below sits in the **MUST ASK BEFORE DECIDING**
> column. Per AD-01A §7 and §97: **delegation to an architect is not authorization.** This document
> is the asking.

| | |
|---|---|
| **Decision ID** | AD-01C |
| **Amends** | [AD-01 — Lead State Machine](./03-lead-state-machine-decision.md) and [AD-01A — Amendment](./03a-lead-state-machine-decision-amendment.md). This document **amends**; it does not replace, supersede or restate either. Both remain **NOT APPROVED FOR IMPLEMENTATION**. |
| **Companion to** | [AD-01B — Dependency & Ordering Analysis](./03b-lead-state-machine-dependency-order.md), which identified Q5 and Q6 as the two roots of the terminality cluster and recommended taking them together, in that order (AD-01B §4). This document follows that sequence. |
| **Scope** | Exactly three items: (1) recording a product-owner **clarification** of the contradiction AD-01B §7.1 flagged; (2) **Q5** — Dump re-engagement; (3) **Q6** — Success reversibility. **Nothing else.** |
| **Explicitly out of scope** | AD-01's **Q2, Q3, Q8–Q16** — referenced only where this analysis directly changes their *scope*, never resolved. AD-01A's **N-1, N-2, N-3, N-4** — referenced only as far ends of dependencies; **N-2 is explicitly left open**. **Q1, Q4, Q7** — decided by AD-01A §8 and treated as fixed; not reopened, re-argued or reinterpreted. Every other blocker (M-2 … M-20). The authorization model. The schema. |
| **Authority** | Master Spec **§88** places *canonical entities*, *relationships*, *booking lifecycle*, *financial logic*, *CP commission logic*, *source-of-truth rules* and *audit requirements* in the **MUST ASK BEFORE DECIDING** column. Q5 touches canonical entities and relationships; Q6 touches booking lifecycle, financial logic and audit requirements. Both are therefore owner decisions in full. |
| **Contains SQL / schema / migration** | **No.** Deliberately — same posture as AD-01 and AD-01A. |
| **Constraints honoured** | `ENGINEERING_RULES.md` **R1** (tenant isolation), **R4** (masters not enums; semantics in columns, never codes), **R6** (event-based append-only audit; never edit history), **R12** (every claim traceable to this repository's own documents), and Spec **Rule 1** (do not invent requirements — spec silence is flagged explicitly in [§5](#5-where-the-spec-is-silent-rule-1-register)). |
| **Sources re-read for this document** | `docs/BMEXA_MASTER_SPEC.md` §06, §07, §08, §09, §10, §11, §12, §13, §14, §17, §20, §21, §26, §32, §33, §35, §39, §40, §42, §43, §44, §45, §54, §56, §57, §58, §63, §64, §65, §68, §86, §87, §88, §95, §96, §97; `docs/ENGINEERING_RULES.md` R1, R4, R6, R12; AD-01 in full (esp. §6.1, §7 E-01/E-02/E-03/E-09/E-13/E-14/E-15/E-16, §8.3, §8.4, §9, §10); AD-01A in full (esp. §1.7, §2.2, §3, §6.2, §8); AD-01B in full; `docs/architecture/01-bmexa-architecture-reconciliation.md` M-5, M-9. |

---

## How to read this document

Three things are kept visually distinct **throughout**, not only in a summary section. Every
substantive claim below carries one of these three markers:

| Marker | Meaning |
|---|---|
| > **⟦ARCHITECT RECOMMENDATION⟧** | My independent conclusion, reached from the spec and from AD-01/AD-01A. Mine to defend; the owner's to accept or reject. |
| > **⟦PRODUCT-OWNER PROVISIONAL PREFERENCE⟧** | What the owner has stated as a leaning. **A provisional preference is not an approval and is not evidence.** It is recorded so it is visible that it was known and weighed, and so that agreement is never mistaken for deference. |
| > **⟦OPEN — NOT RESOLVED HERE⟧** | An edge case or question this analysis surfaced and deliberately does not answer. Per Rule 1, none is guessed. |

Where my recommendation **agrees** with the owner's preference, the section says so explicitly and
states the independent grounds that produced the agreement. Where it **diverges, refines or
qualifies**, the section says that explicitly too. Both appear below.

---

## 1. Part 1 — Clarification recorded: the AD-01B §7.1 contradiction

### 1.1 What AD-01B flagged

[AD-01B §7.1](./03b-lead-state-machine-dependency-order.md#71-contradiction--blocked-cannot-be-derived-from-next-action-timing)
recorded a contradiction **internal to AD-01A §8**:

- **AD-01A §8.1 / §8.6** list *Blocked* among conditions *"computed from next-action timing, not
  stored."*
- **AD-01A §1.7** — the recommendation §8 approved — represents the same distinction as a
  **qualifier carried on the next-action commitment** ("who owes the next move"), i.e. a persisted,
  non-lifecycle input under **R4**.
- **AD-01A N-2**, which §8.7 confirms remains open, asks which values of that qualifier suppress §58
  escalation — a question that presupposes the qualifier exists.

Two leads with identical next-action timestamps — one awaiting a lender's sanction letter, one
simply scheduled for Thursday — are indistinguishable by any function of timing. AD-01B resolved
nothing and asked.

### 1.2 The product owner's clarification, recorded verbatim

> **⟦PRODUCT-OWNER CLARIFICATION — recorded verbatim, not re-derived and not re-argued here⟧**
>
> - Today / Future / Overdue remain derived from next-action timing.
> - "Blocked" is NOT purely timing-derived if it represents who owes the next move.
> - Treat Blocked as an orthogonal operational qualifier whose exact persistence/derivation
>   mechanism remains unresolved under N-2.
> - Do NOT reopen Q1. The rejection of Pending as a Lead Lifecycle state remains approved.
> - Do NOT resolve N-2 in this task — N-2 stays open.

### 1.3 What this clarification does and does not settle

Recorded as bookkeeping so that later readers do not over-read it.

**It settles:**

- The *diagnostic* half of AD-01B §7.1. Branch **(a)** — "Blocked really is derived from timing
  alone" — is eliminated. AD-01A §8.6's parenthetical *"computed from next-action timing, not
  stored"* is now known to be **inaccurate as written for Blocked**, while remaining correct for
  Today / Future / Overdue.
- That N-2 has a subject. AD-01B §7.1 noted that under branch (a) N-2 would have had none; it does.
- That **Q1 is untouched.** The four-value Lead Lifecycle (New · Follow-up · Success · Dump) stands
  exactly as AD-01A §8.1 decided it. Neither branch of §7.1 ever required a fifth lifecycle value,
  and this clarification creates none.

**It does not settle, and this document does not settle:**

- **N-2 in any part.** The mechanism (persisted qualifier vs. derived from some input other than
  timing — for example from activity or task records), the values, and which values suppress §58
  escalation all remain open exactly as AD-01A §6.2 states them.
- **X-6 (Q14 ← N-2).** AD-01B recorded Q14's escalation thresholds as obstructed by this
  contradiction. Eliminating branch (a) narrows the obstruction but does not clear it: Q14 still
  cannot state what is exempt from escalation until N-2 supplies the values.

> **⟦ARCHITECT OBSERVATION — labelled as observation, not as a decision⟧**
> The clarification stops deliberately short of AD-01B's branch **(b)**. Branch (b) asserted that
> the §1.7 qualifier *is persisted*; the clarification says only that Blocked is **not derivable
> from timing**, and expressly leaves persistence-versus-derivation to N-2. That gap is real and
> worth preserving rather than closing by inference: "not derived from timing" and "therefore
> stored" are different claims, and a third possibility — derived from a non-timing input the system
> already holds — is neither chosen nor excluded. Under **R4** the eventual answer also determines
> whether this is a master-backed vocabulary at all. Per **Rule 1**, nothing here narrows it.

> **⟦OPEN — NOT RESOLVED HERE⟧ T-12.** AD-01A §8.6's enumeration of the Orthogonal Lead Model still
> reads *"Today / Future / Overdue / Blocked, computed from next-action timing, not stored."* Per
> §1.3 above that phrasing is inaccurate for Blocked. It needs a corrective note **when N-2 is
> resolved**, written by whoever resolves N-2 — not by this document, which has no authority to
> edit a recorded product-owner decision. Recorded so the inconsistency is tracked rather than
> rediscovered.

### 1.4 Why this does not affect Q5 or Q6

AD-01B §7.1 stated that the contradiction obstructs **Q14** and **Q2**, and *"does not obstruct Q5,
Q6, Q10, Q15 or Q16."* Re-checked independently here and confirmed: Blocked is a statement about who
owes the *next* move on a **live** lead. Q5 concerns a lead that has already reached a terminal
non-conversion disposition, and Q6 a lead that has already reached a terminal conversion. Neither
has a next move to owe. **Parts 2 and 3 below proceed unaffected.**

---

## 2. Part 2 — Q5: can a Dumped lead be re-engaged, or does re-contact create a new lead?

**The question, as AD-01 §10 poses it:** *"Can a Dumped lead be re-engaged, or does re-contact create
a new lead? E-01. If re-engagement is allowed, who may authorize it, and how is the funnel
restated?"*

### 2.0 The owner's stated position, recorded before the analysis

> **⟦PRODUCT-OWNER PROVISIONAL PREFERENCE⟧**
> **Alternative B** — create a new Sales Lead for the same Person, while retaining a controlled
> relationship/reference to the prior Lead.
>
> **This is recorded here, before the analysis, so that it is visible the preference was known
> throughout and is not being ratified after the fact.** It is not an approval, and it is not
> treated as evidence. AD-01A §7 established the standard applied: *"A provisional preference is not
> an approval. It was weighed as evidence, and the recommendation is reached on independent spec
> grounds."* The same standard is applied below, including the obligation to say so plainly if the
> independent analysis had disagreed.

### 2.1 The two alternatives, stated precisely

**Alternative A — reopen the existing Dumped Lead.** A legal ordinary transition **Dump →
Follow-up** is added to the lifecycle machine (AD-01 §6.1 already carries this row, marked
*"permitted only if Q5 says so"*). The lead resumes work on the same record. Dump becomes
*semi*-terminal: terminal until it isn't.

**Alternative B — new Sales Lead for the same Person, with a controlled reference to the prior
Lead.** The Dumped lead is never touched again. A new Sales Lead is created against the same Person
(and the relevant Project), carrying an explicit reference to the lead it succeeds. Dump remains
strictly terminal to ordinary transitions.

**One scoping finding, stated first because it narrows the question and neither AD-01 E-01 nor
AD-01B states it.** Under §06 a Sales Lead is a relationship between **Person, Project and sales
process**. Q5 is therefore only live for the **same Person × same Project** case:

- A prospect who returns interested in a **different project** is already a new Lead under §06, and
  AD-01 E-09 confirms it ("*§06 makes a lead a Person × Project × process relationship, so this is
  two leads*"). Alternative A cannot serve this case at all without rewriting the lead's project,
  which would move the record across the project-scoped access boundaries §08 defines and falsify
  every project-level report that ever included it.
- A prospect who returns interested in the **same project** is the only case where A and B are both
  available.

**Consequence: Alternative A can serve at most one half of the re-engagement problem, and
Alternative B serves both halves with one idiom.** That asymmetry is recorded here and carried into
the recommendation.

### 2.2 Consequence analysis — twelve dimensions

Each dimension states what happens under A, what happens under B, and which is stronger **on that
dimension alone**. Dimensions where A wins are marked as such; a recommendation that never concedes
a point is not an analysis.

---

#### D1 — Lead lifecycle history

**Under A.** The four-value machine gains a backward edge out of a terminal state. The immediate
casualty is the **R4 semantic column**: `is_terminal` (R4 names it explicitly as the reason
semantics live in columns) can no longer be trusted by any consumer, because terminal now means
*terminal-unless-reopened*. Every report, guard and queue that keys on terminality inherits that
ambiguity permanently. A single lead's state history may then contain two or more terminal
transitions, so every query that assumes at most one closure per lead is wrong.

**Under B.** The lifecycle axis stays strictly monotone toward a terminal state. AD-01 §6.1's
transition table **shrinks** by one row rather than growing. Terminality is absolute and `is_terminal`
means what it says.

**Honest cost to B.** A single lead's history is complete, but a *Person's engagement* history is
distributed across a chain of leads. Anyone who reports on one lead and forgets to traverse the
chain sees one episode and believes it is the whole story. That risk is real and is the reason the
prior-lead reference cannot be optional (see D12).

**Stronger: B.**

---

#### D2 — Person vs. Lead identity (§06, §07)

**Under A.** No identity is destroyed, so §07 is not violated on its face. But §06's *process*
component is blurred: one record now spans two sales processes separated by a closure. The entity's
own definition stops describing the entity.

**Under B.** This is the literal instantiation of §07: *"A Person can have multiple leads … Do not
destroy historical identity when status changes."* Each process is one record.

**A precision correction to AD-01 E-01, made here deliberately.** E-01 says *"§06/§07 explicitly
allow a Person to hold multiple leads"* and treats that as licensing B. That is true but **less
specific than E-01 implies**: §07's blessing is general, and is illustrated by *different* contexts
("interact with multiple projects, become a customer, be an applicant/co-applicant"). **The spec
nowhere addresses two sequential leads on the identical Person × Project pair.** Per **Rule 1** that
silence is flagged and not converted into permission by resemblance. B is *consistent* with §07; it
is not *mandated* by it.

**Honest cost to B.** A serially returning prospect accumulates N leads on one Person × Project.
Whether that is a faithful record of N episodes or avoidable proliferation is a business judgement
the spec does not make (see T-11).

**Stronger: B, on consistency — but the supporting citation is weaker than AD-01 E-01 claims.**

---

#### D3 — Project / sales context

Covered in §2.1. Under A the different-project case is unserviceable without corrupting project
scope (§08) and project-level reporting; under B both cases use one idiom. There is a second-order
consequence worth stating: **project-scoped authorization** (§08: "Global, Region, Project, other
explicitly configured organizational scopes") is evaluated against the lead's project. A record that
changes project mid-life changes who may see it, retroactively, for its whole history. Under B a new
lead is created in its correct scope from the start and no past visibility is disturbed.

**Stronger: B, decisively.**

---

#### D4 — Conversion reporting (AD-01 §9.1)

AD-01 §9.1 defines the funnel as **Captured → Worked → Converted**, where *Captured* is
period-of-creation, *Worked* is history-derived, and **Converted keys on the lead's current state's
semantic type**.

**Under A.** A lead captured and Dumped in Q1, reopened in Q3 and converted in Q4 **retroactively
stops being a loss in the Q1 cohort**, because Converted reads current state. Q1's already-published
loss count changes. This is exactly the silent restatement AD-01 §10 Q6 warns about for Success
(*"the alternative … is what many CRMs do and it silently restates prior quarters"*), arriving
through the Dump door instead. Under **R6**'s posture — history is appended, never rewritten — a
reporting model whose past outputs move is the same defect expressed in analytics rather than in
storage.

**Under B.** Q1's cohort keeps its loss permanently. The successor lead is a new capture in a later
period and converts there. **Both periods are stable and neither is ever restated.**

**Honest cost to B, and it is not small.** The later period's *Captured* denominator now contains a
returning prospect, which is not a fresh market-sourced enquiry. Returning prospects convert better
than cold ones, so B **flatters the later period's conversion rate** unless reactivations are
segmented out. Under A that distortion does not arise because no new capture is recorded.

**This cost is the single strongest argument available to A on reporting, and it is answerable —
but only conditionally.** It is answerable *if and only if* the successor reference is mandatory and
typed, because that is what makes a reactivation separable in the denominator. If the reference is
optional, B's funnel is quietly wrong in the opposite direction from A's, and A's defect (visible
restatement) is arguably the less dangerous of the two, because a number that moves is noticed and a
number that is quietly inflated is not. **This is the analytical basis for treating the reference as
mandatory rather than "controlled", which is where this document's recommendation is more
prescriptive than the owner's preference as stated.**

**Stronger: B, conditionally — conditional on the reference being mandatory.**

---

#### D5 — Source attribution

**Under A.** The lead carries one source. A prospect who originally arrived through one channel and
returns through another leaves the system with two bad options: keep the original source (so the
episode that actually converted is credited to a channel that did not produce it) or overwrite it
(which rewrites business history and retroactively corrupts the earlier period's source-quality
report). **There is no honest place under A to record the second source.** AD-01 §9.1 has already
established that source-quality reporting is the reason Dump must be decomposed at all; A introduces
an unrecordable fact directly into that reporting line.

**Under B.** Each lead carries the source of its own episode. Per-episode source quality stays
coherent.

**Honest cost to B.** Source performance now double-counts the Person: the first source books a
loss, the second books a win, and neither is solely responsible for the outcome. B does not
eliminate attribution distortion; it **relocates it from unrecordable into separable**. That is a
genuine improvement rather than a solution, and it should be accepted as such rather than oversold.

**Stronger: B.**

---

#### D6 — CP attribution and clash (§11, §32, §33, §40)

This is the dimension with money attached, and it is where A fails hardest.

§11 makes clash detection a **core business control**: multiple claims coexist, history is
preserved, *builder-side authorized leadership* resolves attribution, and reps must not see
competing claims.

**Under A.** One lead spans two episodes, so it holds one claim set spanning two episodes. If a
different CP brings the prospect back and that episode converts, the system faces two outcomes,
both wrong:

1. The new CP files against the same lead, producing a **clash that is not a clash** — two CPs, two
   genuinely distinct episodes, both legitimately claiming their own. Authorized leadership is
   forced to adjudicate a false conflict under §11, which is precisely the control §11 exists to
   apply to real conflicts.
2. The original claim silently prevails, and §32/§40 commission flows to a CP who did not produce
   the converting engagement.

**Alternative A structurally cannot distinguish "two CPs claiming one episode" (a genuine §11 clash)
from "two CPs, two episodes" (not a clash at all).** Since clash resolution is the input to
commission eligibility (§32 milestone-based eligibility, §40 server-side authorization), that
failure is financial, not cosmetic. **This is, in my assessment, the decisive argument against A.**

**Under B.** One lead is one episode. Each episode carries its own claim set. §11's clash semantics
stay literally true, and §32/§40 key on the resolved claim of the lead that actually converted —
consistent with AD-01 E-13, which already establishes that commission must key on the resolved claim
rather than on the lead's state.

**Honest cost to B, and it is a real commercial exposure.** If a CP registers a prospect, the lead is
Dumped, and the same prospect returns direct three months later, B creates a successor lead with no
CP claim — and the CP will argue their introduction produced the sale. That dispute is genuine.

**But A's apparent advantage here is a trap, and this is worth stating plainly.** Under A the
original claim persisting is not a *decision* the business made — it is a policy **silently created
by the data model**: "a CP claim reaches forward indefinitely across a closure." Nothing in §11,
§32, §40 or §33 says that, and inventing it would breach **Rule 1** and §88's prohibition on
inventing business rules. A's advantage is therefore that it answers an unasked question by accident.
B leaves the question visibly open, which is the correct posture for a question the owner has never
been asked (see T-4).

**Stronger: B, decisively — and B's cost is a question A answers only by inventing a rule.**

---

#### D7 — Sales-cycle measurement (AD-01 §9.2)

**Under A.** AD-01 E-01 already concedes this: *"time-in-pipeline becomes meaningless."* A lead
created in January, Dumped in February, reopened in August and converted in September shows an
eight-month cycle of which six are dormancy. Every average is corrupted unless dormancy is subtracted
by special-casing reopen gaps in the state history. §9.2's named responsiveness metric — *days New →
first Follow-up* — also becomes ambiguous: does a reopen restart that clock, and if not, what does
the second episode's responsiveness mean?

**Under B.** Each lead's cycle is self-contained and correct. The cross-episode elapsed time (true
first contact → sale) is derivable by traversing the chain when someone actually wants it.

**Honest cost to B.** The *commercial* cycle is longer than any single lead shows, so a naive report
understates it. Once again the mitigation is the chain, and once again it only exists if the
reference was captured at creation.

**Stronger: B.**

---

#### D8 — Reactivation reporting

**Under A.** Reactivation is a count of Dump → Follow-up transitions in the business-level state
history (AD-01 §8.3). Simple and immediately available. **This is A's cleanest dimension and it
deserves to be stated without hedging.**

**Under B.** Reactivation is a count of leads carrying a successor reference — equally available,
and strictly richer, because the *outcome* of each reactivation is its own episode. Under A, a
reactivated lead that is Dumped again either overwrites its earlier disposition and reason (which
**AD-01A §8.3 forbids**: *"Preserve the historical reason on a lead rather than silently rewriting
business history"*) or forces reasons to be historised per transition — a new requirement A creates
and B does not.

**Stronger: B, narrowly — and only because AD-01A §8.3's preserved-reason rule already exists. Had
that rule not been approved, this dimension would favour A.**

---

#### D9 — Audit and history (§54, §56, §07, R6)

**Under A.** The reopen is an auditable `lead.state_changed` event and lands in the business-level
state history AD-01 §8.3 specifies, so it survives R6's twelve-month hot window. That much is fine.
The defect is elsewhere: the live record now carries a Dump reason describing a *past* episode, so
the field's meaning becomes ambiguous ("why this lead was closed" vs. "why this lead is currently
closed"), and a second closure must either overwrite it — violating AD-01A §8.3 — or force reason
historisation.

**Under B.** Each lead carries exactly one terminal disposition with exactly one preserved reason.
§8.3 is satisfied without a new mechanism. The reactivation fact lives **on the entity** (the
successor reference), not only in a history table, so any query can see it without traversing state
history — which matters under R6's own argument that the audit log is a security artefact and not
the analytics source.

**Under both.** §56 is satisfied: nothing is deleted under either alternative. §07's prohibition on
destroying historical identity is satisfied by B directly and by A only so long as reasons are
historised.

**Stronger: B.**

---

#### D10 — Duplicate detection (§09, §12, blocker M-5)

**This is Alternative B's weakest dimension, and the analysis would be dishonest to soften it.**

**Under A.** No new record is created, so no duplicate candidate appears. Clean.

**Under B.** A returning prospect produces a second Lead against the same Person and, in the live
case, the same Project. **Under whatever uniqueness key M-5 selects, that successor is a strong
duplicate candidate by construction.** If §09's detection flags it, every re-engagement generates a
false duplicate alert; alert fatigue then makes the control decorative — the precise failure mode
AD-01 E-06 warns about for the sync gate (*"the rep must not be able to clear the conflict
themselves — otherwise the gate is decorative"*).

**The mitigation is architectural and is a requirement B imposes on another blocker.** A declared
successor must be a **first-class input to duplicate detection**, so that a deliberately created
successor is recognised as a successor and not surfaced as an unresolved duplicate. That requirement
belongs to **M-5** (*"what is a lead's uniqueness boundary, and at what level does clash detection
operate?"*), which is unanswered.

**A refinement of AD-01B, not a contradiction of it.** AD-01B §3 lists Q5 as a root with nothing
blocking it, and that remains correct: **Q5 can be decided without M-5.** What this analysis adds is
a dependency in the *opposite* direction — if Q5 is answered B, then **M-5's answer must
accommodate successors**, or the §09 control degrades. That is an edge pointing out of Q5 into M-5,
which AD-01B's graph does not carry because AD-01B analysed prerequisites rather than imposed
requirements. Recorded as **T-1**.

**Stronger: A.**

---

#### D11 — Future reporting and extensibility (§63, §65, §86)

**Under A.** Semi-terminality is permanent. Any future axis, queue or report keying on terminality
inherits the ambiguity for the life of the product, and the Orthogonal Lead Model's central property
— that axes can be added without reinterpreting existing ones (AD-01B §2.3) — is weakened on the one
axis the model holds fixed.

**Under B.** Reporting composes at two clean levels: **episode level** (one lead) and **relationship
level** (one Person, traversing the chain). §63's test — *"what decision or action does this
enable"* — is met by a returning-prospect exception queue with an obvious action.

**A constraint that binds both alternatives equally and must be stated.** Neither A nor B authorises
remarketing, nurture or re-engagement campaigns. AD-01 §1.3 records that re-engagement is *"never
addressed"* by the spec, and **§65 and §86 remain in force**. AD-01A §3.5 makes the same reservation
for Dimension C. **Answering Q5 decides what the system does when a prospect returns; it does not
authorise going out to get them.** Anything beyond the inbound case is a new product requirement.

**Stronger: B.**

---

#### D12 — Must the relationship be reconstructible historically?

**Yes — and this is the dimension that converts the recommendation from a preference into a
condition.**

§07 forbids destroying historical identity; §54 requires business actions to be auditable; R6 makes
history append-only. The relationship between a closed episode and its successor is a business fact
about the Person's engagement, and it must survive.

**Under A.** Reconstructibility is automatic — it is one record — but the *content* is degraded: one
source field, one reason field and one claim set covering two episodes (D5, D6, D9).

**Under B.** Reconstructibility is **complete in fidelity but entirely dependent on the reference
being captured at the moment the successor is created**. AD-01B §4 already identified this as the
asymmetry that makes Q5 urgent: *"a lead-to-prior-lead link cannot be reconstructed retroactively
for leads that never recorded one."* A successor created without a reference is indistinguishable
after the fact from an ordinary new lead, and no later process can recover the link.

**Therefore: under B the reference is not decoration and not a convenience. It is the mechanism that
discharges §07 and makes D4, D5, D7 and D8 answerable at all. An optional reference makes B worse
than A on history.**

**Stronger: A on mechanism, B on fidelity — conditional on the reference being mandatory.**

---

### 2.3 Scorecard

| # | Dimension | A (reopen) | B (new lead + reference) |
|---|---|---|---|
| D1 | Lead lifecycle history | Terminality becomes ambiguous | **Stronger** |
| D2 | Person vs. Lead identity | Blurs §06's *process* | **Stronger** (citation weaker than E-01 claims) |
| D3 | Project / sales context | Cannot serve the cross-project case | **Stronger, decisively** |
| D4 | Conversion reporting | Retroactive restatement of closed periods | **Stronger, conditional on a mandatory reference** |
| D5 | Source attribution | Second source is unrecordable | **Stronger** |
| D6 | CP attribution / clash | Cannot distinguish a real clash from two episodes | **Stronger, decisively** |
| D7 | Sales-cycle measurement | Time-in-pipeline meaningless (AD-01 E-01) | **Stronger** |
| D8 | Reactivation reporting | Simple and available | **Stronger, narrowly** |
| D9 | Audit / history | Reason field becomes ambiguous | **Stronger** |
| D10 | Duplicate detection | **Stronger** | Successor is a duplicate candidate by construction |
| D11 | Future reporting | Semi-terminality is permanent | **Stronger** |
| D12 | Historical reconstructibility | Automatic but degraded | **Stronger, conditional on a mandatory reference** |

### 2.4 The strongest case for A, stated fairly before it is rejected

A deserves its best statement, because two of its arguments are good:

1. **It creates no duplicate.** D10 is a genuine cost of B and it lands on §09's clash control, which
   §11 calls a core business control. Making the control noisy is a real harm.
2. **The relationship is inherently reconstructible.** One record cannot lose its own history. B's
   reconstructibility rests on a discipline that must be enforced at creation time and cannot be
   repaired later.
3. **It preserves a natural authorization chokepoint.** Reopening a terminal record is obviously an
   act deserving a permission gate. Creating a new lead is ordinary capture. **A's control surface is
   better by default** — see T-2.

**Why they do not carry.** Argument 1 is a requirement on M-5, not a defect without a remedy;
argument 2 is answered by making the reference mandatory, which this recommendation requires;
argument 3 is answered by relocating the control rather than removing it, which is a design task the
owner can still direct. Against them stand D3 (A cannot serve half the cases at all) and D6 (A
cannot distinguish a genuine §11 clash from two episodes, with commission consequences) — and
neither of those has a remedy inside A.

### 2.5 Architect recommendation — Q5

> **⟦ARCHITECT RECOMMENDATION — Q5⟧** *(RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT
> APPROVAL — nothing here is approved or implementable)*
>
> **Adopt Alternative B.** Re-contact of a prospect whose lead reached Dump creates a **new Sales
> Lead** against the same Person; the Dumped lead is never reopened. **Dump remains strictly
> terminal to ordinary lifecycle transitions**, and AD-01 §6.1's *Dump → Follow-up* row is
> **removed** from the legal transition set rather than enabled.
>
> **Four conditions, all of which are part of the recommendation and none of which is optional.**
> The recommendation is not "B"; it is "B with these four properties", and B without them is worse
> than A on history (D12) and on reporting honesty (D4).
>
> 1. **The successor reference is mandatory and typed** on any lead created as a re-engagement of a
>    prior lead — captured at creation, never bolted on later, and non-destructive to the prior lead
>    (its Dump, its preserved reason per AD-01A §8.3, its claims and its source are untouched).
> 2. **The successor reference is semantically distinct from the merge linkage Q10 will require.**
>    Two leads linked because one succeeds the other, and two leads linked because one was merged
>    away as a duplicate of the other, are opposite claims about identity — a successor asserts
>    *"these are two real episodes"*, a merge asserts *"these were never two things"*. Collapsing
>    them would make both unreadable. **This is a scope note on Q10, not a resolution of Q10.**
> 3. **Duplicate and clash detection must recognise a declared successor as a successor, not as an
>    unresolved duplicate** (D10). This is a requirement Q5's answer places on **M-5**, and it is
>    recorded as T-1 rather than resolved here.
> 4. **Reactivations must be separable in reporting** — the later period's *Captured* denominator
>    must be able to distinguish a returning prospect from a fresh enquiry (D4), which condition 1
>    makes possible.
>
> **Relationship to the owner's preference: AGREEMENT, reached independently, with the conditions
> above added.** The direction (B) matches the stated preference. The grounds are independent —
> §06's *process* component and the cross-project case (D3), §11's clash semantics and their §32/§40
> commission consequence (D6), AD-01 §9.1's current-state-keyed funnel (D4), and AD-01A §8.3's
> already-approved preserved-reason rule (D8/D9) — and the same conclusion would have been reached
> had no preference been expressed. **The one substantive departure is prescriptiveness:** the owner's
> phrasing is *"a controlled relationship/reference"*; this recommendation holds that the reference
> must be **mandatory**, because an optional reference produces a system that is quietly worse than A
> on exactly the dimensions B is chosen for.
>
> **What this recommendation does NOT do:** it does not authorise remarketing, nurture, drip or any
> outbound re-engagement capability (§65, §86, AD-01 §1.3, AD-01A §3.5). It does not decide who may
> create a successor (T-2). It does not define successor-chain depth or transitive reporting (T-11).
> It does not touch Q10, Q15 or Q16 beyond the scope notes in §4.

### 2.6 A cost of this recommendation the owner should accept knowingly

**Alternative B partially strands Dimension C of the approved Dump-reason framework.**

AD-01A §3.5 introduced **recoverability posture** (permanent vs. potentially revisitable) expressly
to enable Q5: *"Without C, Q5 has to be answered uniformly for all Dumps, which is plainly wrong."*
AD-01B §4 went further, calling Q5 *"the question that makes an already-approved decision usable."*

Under **A**, posture would have been a hard gate: permanent closures cannot reopen; revisitable ones
can. Under **B**, there is no such gate to hold, because §06/§07 already permit a Person to hold
another lead without any Q5 answer at all. Posture's remaining operational roles under B are:

- an input to **duplicate-detection triage** (a returning contact matching a Person whose prior lead
  was closed as invalid or non-opportunity is more likely a junk or duplicate record than a genuine
  new opportunity); and
- a **reporting classification** that keeps the loss denominator honest.

Both are useful. Neither is a gate. **AD-01B §4's claim is therefore only partially satisfied by this
recommendation, and saying so is part of the recommendation.** This does **not** reopen AD-01A §8.3 —
the three dimensions remain approved, and posture's value in Dimension A's reporting role is
untouched. It raises a question about posture's *use*, recorded as **T-10**.

---

## 3. Part 3 — Q6: is Success reversible, and does a cancelled booking change the lead's state?

**The question, as AD-01 §10 poses it:** *"Is Success reversible, and does a cancelled booking change
the lead's state? E-14 and E-15."*

**What AD-01A §8.2 has already decided, and which this document treats as fixed:** Success = §20
Stage 3 (Booked), after required builder-side verification; **Booking has its own separate
lifecycle** which the Lead Lifecycle must not absorb; and **a cancelled booking must not rewrite the
Lead Lifecycle from Success back to Dump.** Per AD-01A §2.2, E-14 becomes unreachable once Success is
Stage 3, so Q6's surviving residue is: *is there any other legal exit from Success?*

### 3.0 The owner's stated position, recorded before the analysis

> **⟦PRODUCT-OWNER PROVISIONAL PREFERENCE⟧**
> - A valid Success should remain historically Success even if the downstream Booking is later
>   cancelled.
> - An incorrectly recorded Success should be handled as an auditable correction/reconciliation
>   event, not an ordinary lifecycle reversal.
> - A genuinely new opportunity should create a new Sales Lead.
>
> **Recorded before the analysis, and not treated as evidence**, on the same standard as §2.0.

### 3.1 The four scenarios, held strictly apart

The whole of Q6 turns on refusing to let these four share a mechanism.

| | Scenario | Was the Success ever true? | Is the lead's *current* value still correct? |
|---|---|---|---|
| **S1** | Legitimate downstream Booking cancellation after a valid conversion (§35) | **Yes** | **Yes** — a true past event and a true present value |
| **S2** | A booking that never satisfied the §20 Stage 3 milestone but was recorded as successful | **No** | **No** |
| **S3** | Administrative correction of an incorrectly recorded Lead state (any value, not only Success) | **No** | **No** |
| **S4** | A genuinely new sales opportunity after a prior successful transaction | **Yes** | **Yes** — and unaffected |

**The organising principle this table produces, and the core of the Q6 recommendation:**

> **Restate what was never true. Never restate what was true at the time.**

S1 and S4 describe facts that were true when recorded and remain true; touching them would *create*
a falsehood. S2 and S3 describe records that were never true; leaving them would *preserve* one.
Those are opposite obligations and they cannot be served by one mechanism.

---

### 3.2 S1 — Legitimate booking cancellation after a valid conversion

**Already decided by AD-01A §8.2. Restated and independently tested here; not reopened.** Tested
against the spec because a decision that cannot survive re-derivation is not safe to build on.

- **§35** — *"the CRM must still preserve the appropriate business state and inventory consequences.
  'Handled offline' does NOT mean destroy history or ignore the transaction."* Reverting the lead
  destroys the record of a conversion that genuinely occurred.
- **§21** — a confirmed booking retains an **immutable commercial snapshot**. The lead's Success is
  that snapshot's counterpart on the sales side. A model that preserves the booking's snapshot while
  erasing the lead's conversion is internally inconsistent about which facts are immutable.
- **§8.2's own construction** — Booking has its own lifecycle. A cancellation is therefore **fully
  expressible where it belongs**. Reflecting it onto the lead adds no information and destroys some.
- **An independent proof from AD-01A §8.3, which is already approved.** A Success→Dump reversion
  would require a Dump reason, and §8.3 makes a reason mandatory on a terminal non-conversion
  disposition. But a cancelled booking is **not a non-conversion** — the conversion happened. It fits
  none of Dimension A's five validity classes: it is not invalid, not redundant, not a commercial
  loss, not disqualified, and not administrative. Forcing it into that taxonomy would corrupt the
  single dimension that AD-01 §9.1 identifies as the precondition for any defensible source-quality
  report. **The approved Dump framework cannot represent a cancelled conversion, which is independent
  evidence that a cancelled conversion must not become a Dump.** (AD-01B §7.3 observed the
  compatibility; this extends it into an argument.)
- **A safety property, not merely a reporting one (§26, §33).** §26 states in capitals that a unit
  transfer must **not** automatically be treated as a cancellation for CP clawback, and §26 records
  that the previous design concept for a transfer was *old booking → new booking*. If a lead's state
  flapped on booking closure, a transfer would present to the commission engine exactly as a
  cancellation — **the precise failure §26 forbids**, and the failure AD-01 E-16 describes. Holding
  Success steady is therefore a **CP-financial safety property**, not just reporting hygiene.
- **Information loss.** If the lead reverted, *"how many leads did we convert in Q1"* would no longer
  be answerable without time-travel. Reversion is a strict loss of an answerable question.

**One constraint S1's answer imposes downstream, stated because the answer is only safe if it
holds.** **CP commission eligibility must key on the Booking and its milestones (§32, §40) — never on
the Lead's lifecycle value.** If it keyed on the lead, S1 would leave a CP eligible against a
cancelled booking; and any reverted lead would revoke eligibility against a still-live booking. AD-01
E-13 already establishes that commission keys on the *resolved claim*, not on lead state; this adds
the booking side of the same rule. **The commission model itself is M-9's and is not decided here.**

> **⟦ARCHITECT RECOMMENDATION — S1⟧** Confirms AD-01A §8.2 on independent grounds. A validly
> converted lead **remains Success permanently**, regardless of what the Booking does afterwards.
> The cancellation lives on the Booking (§35, §8.2). **Agrees with the owner's stated preference.**

---

### 3.3 S2 — A booking that never satisfied the Success milestone but was recorded as successful

This is Q6's live residue. It must be split, because the two halves are not equally real.

**S2a — the booking was wrong.** A booking was recorded at §20 Stage 3 without the required
builder-side verification actually having completed, or was recorded against the wrong lead or the
wrong unit. The lead's Success was correctly derived from an incorrect booking. **The defect is on
the booking**, and the lead's correction is consequential to correcting the booking.

**S2b — the lead was wrong, with no qualifying booking behind it at all.** For example, a handler
dispositioned Success directly.

> **⟦OPEN — NOT RESOLVED HERE⟧ T-6. Does S2b even exist?**
> AD-01A §8.2 decided **when** a lead becomes Success (§20 Stage 3). **It did not decide who or what
> sets it.** AD-01 §6.1's transition table names the **Handler** as the actor on *Follow-up →
> Success* (with the parenthetical *"+ (if Q4 says so) the booking verification step"*), so the
> model as currently drafted permits a handler-asserted Success that no booking backs. If Success is
> **system-derived** from a booking reaching Stage 3, S2b is structurally impossible and only S2a
> exists. If Success is **handler-asserted**, S2b exists and the error surface is materially larger.
> This changes Q6's answer surface, so it is flagged rather than assumed. Per **Rule 1** it is not
> guessed here. §95 is relevant when it is answered — *minimum necessary friction* — because
> handler-asserted Success is exactly the one-tap action whose cost is a corrupted funnel.

**Consequences of treating S2 as an ordinary lifecycle reversal — why it must not be.**

- **Funnel history and conversion metrics.** If S2 shared a mechanism with S1, the funnel could not
  distinguish *"we never converted this"* from *"we converted and it later unwound."* Those have
  opposite meanings for conversion rate and for source quality (AD-01 §9.1).
- **CP commission (§32, §33, §40).** They are also **different financial events**: a genuine
  cancellation may create a recoverable overpayment and a §33 clawback against an entitlement that
  legitimately existed; an erroneous booking means the entitlement **never existed at all**. Treating
  the second as the first would push a CP ledger negative on grounds the business never had (§33's
  *"do not blindly apply clawback logic to every closed booking"* is the same instinct applied to a
  neighbouring case).
- **Audit (§54, R6).** R6 forbids editing history; AD-01 §8.3 states the discipline directly: *"a
  correction is a new row, never an edit."* A correction must therefore be an **appended, explicitly
  authorized, explicitly reasoned event** that records *that the prior assertion was erroneous* —
  not a silent state change that leaves the record looking as though it had always been correct.
- **Historical integrity.** Correcting an error **does legitimately restate prior periods**, and this
  is where the recommendation refines the owner's phrasing rather than merely agreeing with it (see
  §3.5). A report that counted an erroneous Success was wrong when published. Refusing to restate it
  preserves a known falsehood; restating it corrects one. This is the exact inverse of S1, where
  restatement would create one.
- **§68 strong consistency.** A correction unwinding a Success may unwind authorization-sensitive and
  financial consequences (a §40 invoice eligibility opened by the erroneous conversion). §68 names
  *"critical commission state transitions"* and *"authorization-sensitive mutations"* as
  strong-consistency cases. **Noted as a property the correction mechanism must satisfy; the
  mechanism is not designed here.**

---

### 3.4 S3 — Administrative correction of an incorrectly recorded Lead state

Broader than S2b: any lifecycle value recorded in error — a lead Dumped by mistake, a Success clicked
on the wrong record, a disposition applied to the wrong lead during a busy launch (§42's stated
conditions make this a realistic operational case, not a hypothetical).

**Why one general correction mechanism rather than per-pair reverse transitions.** If corrections are
modelled as ordinary transitions, the transition machine must legalise every reverse edge — which
destroys terminality for **both** terminal states, makes AD-01 §6.1's forbidden-transition list
unenforceable, and leaves `is_terminal` meaningless (the same D1 defect, arriving through a different
door). If corrections are a **separate, authorized, audited event type sitting outside the ordinary
transition machine**, the machine keeps exactly the edges the business actually performs, and
corrections become *countable* — a corrected-state rate is itself a data-quality signal and passes
§63's test (*"what decision or action does this enable"*).

**A precision that reconciles S3 with the Q5 recommendation, and which must not be lost.**
§2.5 recommends that **no Dump → anything edge exists in the lifecycle machine**. S3 permits a
wrongly-Dumped lead to be restored. These are consistent because **terminality is a property of the
ordinary transition machine, not an absolute immutability claim about the record.** A correction is
not an edge in that machine; it is an assertion that the machine was fed a false input.

**A cross-check between Parts 2 and 3 that both answers must survive.** **A correction is not a
re-engagement, and a re-engagement is not a correction.**

- A lead **wrongly** Dumped is corrected — the Dump never happened as a business fact.
- A lead **rightly** Dumped whose prospect later returns gets a **successor lead** (§2.5) — the Dump
  happened and remains true.

Conflating them would let a re-engagement be laundered as a correction (erasing a true loss from a
closed period, undoing D4's whole benefit) or a correction be laundered as a re-engagement
(preserving a false loss and inflating the later period's captures). **The two answers are internally
consistent, and each depends on the other being enforced.**

> **⟦OPEN — NOT RESOLVED HERE⟧ T-7.** A correction needs its own reason, and it is **not** a Dump
> reason: AD-01A §8.3's framework classifies *why an opportunity ended*, and a correction is a
> statement about the *record*, not about the opportunity. **No correction-reason vocabulary exists
> anywhere in the spec and none is invented here** (Rule 1, R4 — values are the owner's and are
> tenant-scoped rows). N-4 owns Dump reason values; it does not own these.

---

### 3.5 S4 — A genuinely new sales opportunity after a prior successful transaction

A Person who bought a unit later wants a second — investor, upgrade, family member, second project.

- **§07**: a Person can have multiple leads and *"become a customer, be an applicant/co-applicant,
  have historical relationships"*. **§06**: Customer is a **context**, not a record. **AD-01 E-09**
  already settles the multi-project shape.
- Therefore a new opportunity is a **new Sales Lead**, and the prior lead's Success is **not touched
  at all**.

**S4 is not actually a reversibility question, and including it in Q6 functions as a framing check
rather than a decision.** Its value is the consistency test it applies to Part 2:

> **Q5-B and Q6-S4 are the same architectural pattern: a new episode is a new Lead.**
>
> If Q5 were answered **A** (reopen), the product would carry two contradictory idioms — *returning
> after a loss reopens the old record*, but *returning after a win creates a new one*. There is no
> business principle that distinguishes those two cases in a way that justifies opposite mechanisms,
> and a rep would have to learn which door to use based on how the last episode ended. **This is an
> independent argument for Q5-B that arises entirely from Q6**, and it is the strongest
> cross-validation available between the two answers.

> **⟦OPEN — NOT RESOLVED HERE⟧ T-5.** Does a CP who introduced the original, *successful* purchase
> have any claim on the same Person's later, separately-sourced purchase? §11, §32, §40 and §41 say
> nothing about the temporal reach of a claim. **Spec silence, flagged not filled** — the exact
> counterpart of T-4 on the Q5 side, and the two should be answered together.

---

### 3.6 Consequences across the ten required dimensions

Read down the columns for a single scenario; read across a row to see why the four must not share a
mechanism.

| Dimension | S1 — valid conversion, booking cancelled | S2 — never met the milestone | S3 — wrong state recorded | S4 — new opportunity |
|---|---|---|---|---|
| **Lead funnel history** | Unchanged; Success is a permanent historical fact | Corrected: the lead was never converted | Corrected to the value that was true | Unchanged; a new lead enters the funnel |
| **Conversion metrics** | Prior periods **stand** | Prior periods **restated** — they were wrong | Restated if a conversion was involved | New period gains a capture |
| **Booking lifecycle** | Owns the cancellation entirely (§8.2, §35) | Owns the primary defect in S2a | Not involved unless a booking exists | A new booking, if it reaches Stage 3 |
| **Cancellation (§35)** | The governing case; history preserved | **Not a cancellation** — an entitlement that never existed | Not applicable | Not applicable |
| **Transfer (§26, §33)** | Must never read as a cancellation; lead state must not flap | Unaffected | Unaffected | Unaffected |
| **CP commission (§32, §40)** | Keys on the Booking; §33 clawback may apply to a real entitlement | Reverses an entitlement that never existed — **not** a §33 clawback | Depends on what was corrected | Attribution for the new episode only — **T-5 open** |
| **Attribution (§11)** | Claims survive; AD-01 E-13 unaffected | Claims attached to an erroneous conversion need explicit disposition — **T-8** | Same | New episode, new claim set |
| **Audit (§54, R6)** | The cancellation is a booking event | An appended, authorized correction event — never an edit | Same mechanism | Ordinary lead creation |
| **Reporting (§63, §9.1)** | Booking-live and lead-converted are **different questions**, served by different axes | Correction rate is itself a data-quality signal | Same | Returning-customer opportunities are their own segment |
| **Historical integrity (§07, R6)** | Preserved by **not** moving | Preserved by **appending** the correction, not editing | Same | Preserved; the prior lead is untouched |

**The row that carries the most weight is *Reporting*.** *"How many bookings are live right now"* and
*"how many leads did we convert in Q1"* are different questions about different entities. A design
that reverts the lead tries to serve both from one field and answers neither reliably afterwards.

---

### 3.7 Architect recommendation — Q6

> **⟦ARCHITECT RECOMMENDATION — Q6⟧** *(RECOMMENDED, SUBJECT TO THE PRODUCT OWNER'S EXPLICIT
> APPROVAL — nothing here is approved or implementable)*
>
> **The ordinary Lead Lifecycle machine gains no backward edge out of Success.** AD-01 §6.1's
> *Success → Follow-up* row is **removed** from the legal transition set rather than enabled. With
> §2.5, **both terminal states are terminal to ordinary transitions**, and the four-value machine is
> closed.
>
> - **S1 — valid conversion, booking later cancelled.** Success is **permanent**. The cancellation
>   lives on the Booking (§35, §8.2). Confirms AD-01A §8.2 on independent grounds (§3.2), and holds
>   as a **CP-financial safety property** via §26/§33, not merely as reporting hygiene.
> - **S2 and S3 — a Success or any other lifecycle value that was never true.** Handled by a
>   **single, general, explicitly authorized, explicitly reasoned, appended correction/reconciliation
>   mechanism that sits outside the ordinary transition machine** — not by per-pair reverse
>   transitions, and not by the mechanism that serves S1. Consistent with R6 and AD-01 §8.3 (*"a
>   correction is a new row, never an edit"*).
> - **S4 — a genuinely new opportunity after a success.** A **new Sales Lead**. The prior lead's
>   Success is not touched. Structurally identical to the Q5-B pattern (§3.5).
>
> **The organising principle, and the sentence the recommendation reduces to:**
> **restate what was never true; never restate what was true at the time.**
>
> **Relationship to the owner's preference: AGREEMENT on all three stated points, with one
> refinement and one gap identified.**
>
> - **Agreement, independently reached.** Points one (valid Success stays Success), two (an incorrect
>   Success is an auditable correction, not an ordinary reversal) and three (a genuinely new
>   opportunity creates a new lead) are all endorsed, on grounds derived from §35, §21, §26/§33, §11,
>   §32/§40, §68, R6, AD-01 E-13/E-16 and AD-01A §8.3 — reached the same way had no preference been
>   expressed.
> - **Refinement (a partial divergence, stated so it is not mistaken for agreement).** The phrase
>   *"not an ordinary lifecycle reversal"* is correct about *ordinary*, and should not be read as
>   *"the lead's state does not change."* **A corrected lead's current value does change**, under
>   authorization and audit — and **prior periods are deliberately and visibly restated**, because
>   they were wrong. Restatement is the *point* of a correction, and it is exactly what must never
>   happen in S1. If the owner intends corrections to leave prior reports untouched, that is a
>   different decision with a different consequence and it should be stated explicitly, because the
>   two cases are being held apart by this distinction alone.
> - **Gap in the framing, not a disagreement with its direction.** The preference treats "incorrectly
>   recorded Success" as one case. It is two (§3.3): **S2a** (the booking was wrong) and **S2b** (the
>   lead was wrong with no qualifying booking). **Whether S2b exists at all depends on an unanswered
>   question — who or what sets Success (T-6)** — which AD-01A §8.2 did not decide. The
>   recommendation above is complete for S2a and **conditional for S2b**.
>
> **What this recommendation does NOT do:** it does not design the correction mechanism, its
> authorization, or its reason vocabulary (T-7, and M-3 owns roles). It does not decide what happens
> to downstream consequences already triggered by an erroneous Success (T-8). It does not touch the
> CP commission model (M-9) or the cancellation/clawback taxonomy (§87 item 5 requires
> finance/legal validation regardless). It does not resolve Q10, Q11, Q15 or Q16.

---

## 4. Direct effects on other open questions — scope notes only, nothing resolved

Recorded because a Q5/Q6 answer changes what these questions are *about*. **None is answered,
narrowed in substance, or given a preferred branch here.** They remain open exactly as AD-01 §10
states them.

| Question | Effect of this document's recommendations, **if approved** |
|---|---|
| **Q10** — merge state precedence | **Simplified in one half, enlarged in the other.** Simplified: precedence never has to rule on whether a Dumped record can be revived by live activity (AD-01B D-1) or whether Success is reversible (D-5) — both terminal states are stable. Enlarged: Q10 must now also decide what happens to **successor links** when leads merge, and must keep successor linkage semantically distinct from merge linkage (§2.5 condition 2). **Q10 remains blocked by X-1 on M-5 regardless.** |
| **Q15** — concurrent disposition | **Risk profile changes, mechanism question unchanged.** Under Q5-B a lost race into Dump is recoverable by creating a successor, so the *consequence* of last-writer-wins softens; the losing side's next-action date is still discarded, which is the part Q15 owns. AD-01B D-3/D-7 anticipated exactly this. |
| **Q16** — who may move a lead to a terminal state | **The cost-of-mistake calculus shifts in two opposite directions, which is why Q16 must still be answered on its merits.** Dump becomes cheaper to get wrong (a successor is available), which weakens the case for a heavy gate. Success becomes *more* expensive to get wrong (undoing it requires the §3.7 correction mechanism, not an ordinary transition), which strengthens it. Additionally, under Q5-B the natural chokepoint on re-engagement disappears — creating a new lead is ordinary capture — so any control the business wants on re-engagement must be placed on successor declaration rather than on a state transition (**T-2**). AD-01B D-2/D-6 anticipated the dependency; the two-directional split is new. |
| **Q2** — long-dated leads | AD-01B D-4 noted that parking-as-Dump becomes **lossy** if Q5 answers "new lead". Under this recommendation it does. Q2 narrows toward a date rule, as AD-01B predicted. **Not resolved; answer jointly with Q14 per D-11.** |
| **M-5** — uniqueness boundary | Acquires a **new requirement** it does not currently carry: successor leads must not present as unresolved duplicates (**T-1**, D10). Direction of dependency is Q5 → M-5, i.e. a requirement imposed, not a prerequisite. |
| **N-4** — Dump reason values | Recoverability posture's operational role under Q5-B is triage and reporting rather than a gate (§2.6, **T-10**). Values remain N-4's and are not proposed here. |

---

## 5. Where the spec is silent — Rule 1 register

Stated explicitly so no reader mistakes inference for requirement. **R12** requires every claim to be
traceable to this repository's own documents; where there is nothing to trace to, that is recorded
here rather than filled in.

| Topic | Spec status | How this document handles it |
|---|---|---|
| Re-engagement of a Dumped lead | **Never addressed** — AD-01 §1.3 confirms *"the spec neither permits nor forbids it."* | Q5 is answered as a product recommendation, not as a reading of a requirement. Flagged as such. |
| Two sequential leads on the **same** Person × Project | **Not addressed.** §07 blesses multiple leads generally, illustrated by different contexts. | §2.2 D2 corrects AD-01 E-01's overstatement: B is *consistent* with §07, not *mandated* by it. |
| Temporal reach of a CP attribution claim across a closure (T-4) or across a completed purchase (T-5) | **Never addressed** — §11, §32, §40, §41 are silent. | Left open. §2.2 D6 notes that Alternative A would have answered it **by accident**, which is itself a reason to reject A. |
| Who or what **sets** Success (T-6) | AD-01A §8.2 decided *when*; **not addressed** who. AD-01 §6.1 names the Handler, with a conditional. | Flagged; the Q6-S2b recommendation is explicitly conditional on it. |
| Correction / reconciliation reason vocabulary (T-7) | **Never addressed anywhere.** | No values proposed (Rule 1, R4). |
| Remarketing, nurture, drip, re-engagement campaigns | **Never addressed**; §65 and §86 forbid building adjacent capability without authorization. | Explicitly **not** authorised by anything here (§2.2 D11). |
| Successor-chain depth and transitive reporting (T-11) | **Not addressed.** | Left open. |
| Response-time or dormancy thresholds relevant to re-engagement | **Never defined** (AD-01 §1.3; §58 sets no numbers). | Not used; no threshold is assumed anywhere above. |

---

## 6. Open questions and edge cases this analysis surfaces

**None is resolved here. Per Rule 1 and §97, none is guessed.** Numbered **T-n** to avoid collision
with the existing Q / N / M / E / D / X namespaces.

| # | Open item | Arises from | Likely owner |
|---|---|---|---|
| **T-1** | Must duplicate/clash detection (§09, §11) recognise a **declared successor** as a successor rather than an unresolved duplicate? Without it, every re-engagement generates a false duplicate alert and the §09 control degrades toward decorative. | Q5-B, D10 | **M-5** — a requirement Q5 imposes on it |
| **T-2** | Under Q5-B the natural authorization chokepoint on re-engagement disappears: creating a lead is ordinary capture. **Who may declare a lead a successor, and where does the control live?** AD-01 §10 Q5's second clause (*"who may authorize it"*) survives in this relocated form. | Q5-B, §2.4 arg. 3 | Q16 / M-3 |
| **T-3** | Successor linkage vs. **merge linkage** (Q10): two lead-to-lead relationships making opposite claims about identity. How are they kept distinct, and what happens to successor links when leads merge? | Q5-B condition 2 | **Q10** |
| **T-4** | **CP registration reach after a lost episode.** Does a CP's claim on a Dumped lead reach a later, separately-sourced episode for the same Person? Spec silent (§11, §32, §40). | Q5-B, D6 | M-5 + CP commission model (M-9) |
| **T-5** | **Repeat-purchase attribution.** Does the CP behind a completed purchase have any claim on the same Person's later purchase? Spec silent. Counterpart of T-4; answer them together. | Q6-S4 | Same as T-4 |
| **T-6** | **Who or what sets Success** — handler assertion, or system derivation from the Booking reaching §20 Stage 3? Determines whether Q6-S2b exists at all. AD-01A §8.2 decided *when*, not *by whom*. | Q6-S2 | M-1 residue; owner |
| **T-7** | **Correction-reason vocabulary.** A correction is a statement about the record, not about the opportunity, so N-4's Dump reasons cannot serve it. No vocabulary exists; none invented. | Q6-S2/S3 | New; adjacent to N-4 |
| **T-8** | What happens to **downstream consequences already triggered by an erroneous Success** — a §40 CP invoice eligibility opened by it, an inventory hold, a booking recorded against it? Reversal semantics belong to §35/§33/M-9. §68 makes this an authorization-sensitive, strongly-consistent operation. | Q6-S2 | M-9 / §87 item 5 |
| **T-9** | **Offline re-engagement (§12, §46, §47).** A device cannot reliably identify the prior lead while disconnected, so a successor link may have to be established server-side after sync — meaning a lead may exist briefly as an unlinked probable duplicate. Interacts with **N-1** (when the gate runs). | Q5-B | N-1 + M-14 |
| **T-10** | **Recoverability posture's operational role** (AD-01A §3.5, Dimension C) under Q5-B: triage and reporting input rather than a gate. Does the owner still want it mandatory on every Dump reason? **This questions its *use*, and does not reopen §8.3's approval of the three dimensions.** | Q5-B, §2.6 | Owner; informs N-4 |
| **T-11** | **Successor chains.** Is there a depth limit, and does relationship-level reporting traverse transitively? A Person with five sequential episodes is not obviously an error, and is not obviously acceptable either. Spec silent. | Q5-B, D2 | Owner |
| **T-12** | AD-01A §8.6's phrasing *"Blocked … computed from next-action timing, not stored"* is inaccurate as written per §1.3. It needs a corrective note **when N-2 is resolved**, written by whoever resolves N-2. Recorded so it is tracked, not rediscovered. | Part 1 | **N-2** |

**Explicitly NOT reopened by this document:** **Q1** (Pending rejected; four-value lifecycle),
**Q4** (Success = §20 Stage 3), **Q7** (three-dimension Dump framework), the sync/verification split,
and the elimination of the assignment axis — all decided at AD-01A §8 and treated here as fixed
ground truth. **N-2 remains open in every part.**

---

## 7. Consolidated effect on AD-01 and AD-01A, if approved

| Item | Current position | Effect of AD-01C, **if approved** |
|---|---|---|
| AD-01 §6.1 — transition row *Dump → Follow-up* (*"permitted only if Q5 says so"*) | Conditional | **Removed** from the legal ordinary transition set. Dump is terminal. |
| AD-01 §6.1 — transition row *Success → Follow-up* (*"permitted only if Q6 says so"*) | Conditional | **Removed** from the legal ordinary transition set. Success is terminal. Backward movement exists only via the §3.7 correction mechanism, which is not an edge in this machine. |
| AD-01 §6.1 — forbidden transitions list | *Anything → New*; *Dump → Success directly* | **Strengthened and simplified.** *Dump → Success directly* is no longer a special prohibition — no edge leaves Dump at all. |
| AD-01 §7 **E-01** | Open; inclination toward (ii) | **Answered as a recommendation** — (ii), with four conditions (§2.5). |
| AD-01 §7 **E-15** | Recommended position, pending Q6 | **Confirmed** on independent grounds (§3.2). |
| AD-01 §7 **E-14** | Unreachable once Q4 = Stage 3 (AD-01A §6.1) | Unchanged. Its residue re-surfaces only as **T-6**. |
| AD-01 §7 **E-16** (unit transfer) | A transfer must not touch lead state | **Reinforced** — §3.2 shows a flapping lead state would present to the commission engine as the §26-forbidden cancellation. |
| AD-01 §10 **Q5**, **Q6** | Open | **Answered as recommendations.** They remain owner decisions. |
| AD-01A §8.2 | Decided | **Unchanged and confirmed.** Not reopened. |
| AD-01A §8.3 Dimension C | Approved as a dimension | **Unchanged.** Its operational *use* is questioned as **T-10**; its approval is not. |
| AD-01A §8.6 (Blocked wording) | As written | **Flagged inaccurate for Blocked** (§1.3); correction deferred to whoever resolves **N-2** (**T-12**). |
| Everything else in AD-01 and AD-01A | Unchanged | **Unchanged, and still NOT APPROVED FOR IMPLEMENTATION.** |

---

## 8. Approval

**STATUS: PROPOSED — NOT APPROVED**

Both recommendations sit squarely in §88's **MUST ASK BEFORE DECIDING** column:

- **Q5** changes a **canonical entity relationship** — whether a re-engagement is a new Sales Lead
  bearing a durable reference to a prior one. It also carries **CP commission** consequences through
  D6, and **source-of-truth** consequences through D4 and D5.
- **Q6** touches the **booking lifecycle** boundary, **financial logic**, **CP commission logic** and
  **audit requirements** — the correction mechanism in §3.7 is an audit-bearing, authorization-
  sensitive control, and §68 classes it as strongly consistent.
- **Both recommendations agree in direction with the product owner's stated provisional preferences.
  A provisional preference is not an approval, and agreement is not ratification.** The grounds above
  are independent and are stated so they can be attacked on their merits. Two places where this
  document is *more* prescriptive or *less* complete than the owner's framing are called out
  explicitly — the **mandatory** (not merely "controlled") successor reference in §2.5, and the
  **S2a/S2b split with its dependency on T-6** in §3.7 — and both deserve the owner's specific
  attention rather than a blanket approval.

**Nothing in this document may be implemented, seeded, migrated to, scaffolded, prototyped or treated
as settled until the project owner approves it in writing.** No schema, SQL, migration, master value,
column, table or type is authorized by anything above, and none may be derived from it. **Delegation
to an architect is not authorization** (AD-01A §7). Per **§97**: *when in doubt, STOP AND ASK.* This
document is the asking.

**The Lead State Machine decision as a whole remains unresolved and unapproved.** AD-01 and AD-01A
remain **NOT APPROVED FOR IMPLEMENTATION**. Even with Q1, Q4, Q7, Q5 and Q6 settled, **Q2, Q3,
Q8–Q16** and **N-1 – N-4** (plus **T-1 – T-12** raised here) remain open, and implementation approval
requires the complete model plus the project owner's explicit written approval.

**STATUS: PROPOSED — NOT APPROVED**
