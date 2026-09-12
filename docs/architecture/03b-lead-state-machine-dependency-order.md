# Architecture Decision 01B — Lead State Machine: Dependency & Ordering Analysis

STATUS: ANALYSIS ONLY — NO DECISIONS

> **Companion to** [AD-01](./03-lead-state-machine-decision.md) and
> [AD-01A](./03a-lead-state-machine-decision-amendment.md).
> This document resolves **nothing**. It answers only *in what order the remaining questions can be
> answered*, and *which of them are not this blocker's to answer at all*. No question's substance is
> decided, recommended, or narrowed here. No SQL, schema, migration, seeding or implementation
> appears here, and none may be derived from it. Blocker **M-1** only.

---

## 0. Scope and method

**In scope:** the thirteen AD-01 §10 questions still open —
**Q2, Q3, Q5, Q6, Q8, Q9, Q10, Q11, Q12, Q13, Q14, Q15, Q16.**

**Held fixed as authoritative ground truth:** [AD-01A §8, Product-Owner Decision
(2026-09-12)](./03a-lead-state-machine-decision-amendment.md#8-product-owner-decision-2026-09-12).
**Q1, Q4 and Q7 are decided and are not reopened, re-argued or re-interpreted below.** They appear
only as constraints that shrink other questions' answer spaces. The single exception permitted by
this task's scope — flagging a direct logical contradiction between a §8 decision and something an
open question requires — is exercised once, in [§7](#7-contradictions-flagged-not-resolved).

**What "depends on" means here.** An edge **Y ← X** asserts that **answering Y before X either
produces an answer that X can invalidate, or requires assuming an answer to X**. It does *not* mean
"Y and X are related," "Y and X share a spec section," or "Y is harder than X." Shared subject
matter alone was not treated as a dependency; several such pairs are listed in
[§2.3](#23-relationships-examined-and-rejected-as-dependencies) as explicitly **non**-edges so the
absence is recorded rather than assumed.

**Method.** For each question: (a) determine what §8 has already removed from its answer space;
(b) determine whether any *remaining* answer changes the shape of the persisted model versus only
its parameters; (c) determine whether another open question's answer changes (b). Only (c) produces
an edge.

---

## 1. What §8 already did to the thirteen

Recording this first, because several apparent dependencies are already discharged and should not be
re-derived later.

| Q | Answer space **after** §8 | Still shape-changing? |
|---|---|---|
| Q2 | §1.7 (approved via §8.1) preserves §13's mandatory next-action date *unconditionally*, and §8.1 forbids new lifecycle values. A "Nurture"/"Parked" **state** is foreclosed. Remaining options: a cap on the date, a derived long-dated bucket, or nothing. | No — parameters only |
| Q3 | Lifecycle vocabulary fixed at four values (§8.1); a terminal non-conversion disposition **must** carry a reason (§8.3). | Partly — see D-10, X-5 |
| Q5 | Untouched by §8. | **Yes** |
| Q6 | §8.2 decided the cancellation half: a cancelled booking must **not** rewrite Success→Dump. Per AD-01A §6.1, E-14 becomes unreachable once Success = §20 Stage 3. Residue: is there *any* other legal exit from Success (mis-keyed booking, corrected data entry)? | **Yes**, but narrow |
| Q8 | §5.4 / §8.5 already fixed the *shape*: enrichment is a durable obligation (task) plus a derived condition — not an axis, not a lifecycle value. Only "is the queue built in MVP" remains. | No — scope only |
| Q9 | Untouched. Under the Orthogonal Lead Model (§8.6) a temperature/score would be an additional orthogonal axis, not a reinterpretation of any existing one. | No — additive |
| Q10 | Nothing removed. | **Yes** |
| Q11 | §8.6 makes attribution orthogonal to lifecycle, so "a Success lead may hold a Contested claim" needs no further decision. Residue: is there a filing cut-off, and what is its commission consequence? | No — policy |
| Q12 | §8.4 / §8.6 make the verification/conflict gate apply to **every lead regardless of origin**, and separate transport sync from business verification. A portal-ingested lead is therefore a provenance fact plus the same gate — it can no longer force a second axis onto the lead. **AD-01's stated reason for sequencing Q12 before the sync design is discharged.** | No |
| Q13 | §8.5 removed the assignment axis, so E-08's "lands Unassigned" is now a Handler/derived-condition matter owned by N-3. Residue: accept or reject the queued operation. | No |
| Q14 | Untouched. | Structural half yes (see §7) |
| Q15 | Untouched. | **Yes** |
| Q16 | Untouched. | **Yes** |

---

## 2. The dependency graph

### 2.1 Edges within the thirteen

Read **Y ← X** as *"Y should not be answered before X."*

| # | Edge | Strength | Why |
|---|---|---|---|
| **D-1** | Q10 ← Q5 | Hard | Merge precedence (E-02) must rule on Dump vs. an open state. Whether a Dumped record can be revived by live activity *is* Q5. Answering Q10 first fixes a precedence rule on an assumption Q5 may reverse. |
| **D-2** | Q16 ← Q5 | Hard | Q16 weighs §13's one-tap disposition against §95's minimum-necessary-friction. The friction a terminal control deserves is a function of how expensive the mistake is — which is exactly whether Dump can be undone (Q5). |
| **D-3** | Q15 ← Q5 | Hard | E-22's dangerous variant is a concurrent race *into* a terminal state where the loser's follow-up date is discarded. Whether last-writer-wins is tolerable depends on whether the losing side is recoverable — Q5. |
| **D-4** | Q2 ← Q5 | Conditional | Q2's surviving "parked treatment" option is only distinguishable from "Dump with a recoverable posture" once Q5 says what recovery *does*. If Q5 answers "re-contact creates a new lead," parking-as-Dump becomes lossy and Q2 narrows to a date rule. |
| **D-5** | Q10 ← Q6 | Hard | E-03 is the strongest precedence case: one merged record is already Success. Whether Success must always win precedence is inseparable from whether Success is reversible (Q6). |
| **D-6** | Q16 ← Q6 | Hard | Success is a terminal transition too. Q16 cannot state a rule for "terminal transitions" while the reversibility of one of the two terminal states is open. |
| **D-7** | Q15 ← Q6 | Hard | Same as D-3 applied to the Success side of the race. |
| **D-8** | Q11 ← Q6 | Weak — largely discharged | A cut-off keyed to *conversion* presumes conversion is a stable event. §8.2 has already made it stable against the common case (cancellation), so this edge is nearly spent; it survives only for Q6's residue (an erroneous Success being unwound). |
| **D-9** | Q10 ← Q11 | Hard, scoped | Scoped to Q10's attribution half only (E-03). If Q11 sets a filing cut-off, merge-carryover of a pre-cut-off claim into a converted survivor is the exact back door around it. Q10's *state*-precedence half does not depend on Q11. |
| **D-10** | Q3 ← Q14 | Hard, scoped | Scoped to Q3's SLA half. AD-01 §10 Q3 asks whether an import triggers follow-up SLAs and escalations; E-17 warns that a thousand-record import must not detonate §58. There is nothing to exempt imports *from* until Q14 defines the thresholds and the clock's start event. Q3's other halves (initial state, gate, handler) do not depend on Q14. |
| **D-11** | Q2 ↔ Q14 | Coupled — **not** one-way | Both write rules onto the same derived time axis over the same next-action timestamp. A maximum horizon that fires escalation is a Q14 defect; an escalation threshold that pages on legitimately long-dated leads is a Q2 defect. Neither is a prerequisite for the other; **they should be answered in the same sitting**, and answering one alone is the most likely source of silent inconsistency among the thirteen. |
| **D-12** | Q15 ← Q16 | Weak | E-22's canonical scenario is rep-versus-manager. If Q16 gates terminal transitions to a narrower principal set, the race becomes rarer and differently shaped. The concurrency *mechanism* choice is largely independent; the *risk assessment* is not. |

### 2.2 Edges crossing out of the thirteen

These are recorded because they change sequencing even though their far end is not this task's to answer.

| # | Edge | Far end | Why |
|---|---|---|---|
| **X-1** | Q10 ← M-5 | Reconciliation blocker M-5 | Merge precedence presupposes a duplicate key. M-5 owns "what is a lead's uniqueness boundary, and at what level does clash detection operate." Q10 cannot state which records are even candidates for merging until M-5 lands. **This is Q10's hardest prerequisite — harder than D-1 or D-5.** |
| **X-2** | Q11 ← M-5 | M-5 | M-5's stated blocking list already includes "whether Lead Attribution Claim attaches to the Lead or the Person." A post-conversion filing cut-off is a different rule depending on which. |
| **X-3** | Q16 ← M-3, M-7 | M-3 (default role set), M-7 (record-visibility vocabulary) | Q16 can be answered *semantically* ("terminal transitions are/are not permission-gated") without them; the grant cannot be *expressed* without M-3's roles and M-7's breadth values. Sequencing consequence: Q16 is answerable now, implementable later. |
| **X-4** | Q13 ← N-3 | AD-01A N-3 | N-3 asks whether deactivation clears the live Handler reference. §8.5 removed the assignment axis, so E-08's "lands Unassigned" has no axis value to land on; the arriving record's handler disposition is N-3's, leaving Q13 with only the accept/reject decision. |
| **X-5** | Q3 ← N-4 | AD-01A N-4 | §8.3 makes a reason **mandatory** on a terminal non-conversion disposition and forbids rewriting historical reasons; N-4 owns the reason values. A legacy import of historically-dumped leads can satisfy the mandatory-reason rule only if N-4 provides a value that honestly denotes "not recorded in the source system." See [§7.2](#72-tension-not-a-contradiction--mandatory-dump-reason-versus-legacy-import). |
| **X-6** | Q14 ← N-2 | AD-01A N-2 | N-2 owns which "waiting on" values suppress §58 escalation. Q14's thresholds are incomplete without knowing what is exempt from them. **This edge is currently obstructed by the contradiction in [§7.1](#71-contradiction--blocked-cannot-be-derived-from-next-action-timing).** |
| **X-7** | Q3 ← N-1 | AD-01A N-1 | N-1 asks when the duplicate/clash gate runs for an online-created lead. Q3 asks whether import runs the gate at all; the two are the same control observed on two ingestion paths, and answering them apart risks two gates with different timing semantics. |

Edges **discharged** by §8 and deliberately *not* carried forward: Q12 ← (sync design) — AD-01 §10 Q12
asserted that lead portals "must be scoped before either is designed"; §8.4's separation of transport
sync from business verification, plus §8.6's origin-independent verification gate, removes that
sequencing constraint.

### 2.3 Relationships examined and rejected as dependencies

Recorded so the absence is a finding, not an omission.

- **Q9 → anything.** A temperature or score is an *additive* orthogonal axis under §8.6. Adding an
  axis later is the one change the Orthogonal Lead Model is explicitly built to absorb. Q9 has no
  dependents and no prerequisites.
- **Q8 → anything.** §5.4/§8.5 already fixed enrichment's shape independent of the MVP-scope answer.
  Building the queue or not building it changes no other question's answer.
- **Q12 → anything.** See discharge above.
- **Q13 → the other twelve.** Its only live edges (X-4) point outside the thirteen.
- **Q14 ← Q8.** Considered (does an enrichment obligation carry its own SLA?) and rejected: §5.4
  already makes the obligation a task with an owner and a date, so it inherits whatever task-level
  timing exists rather than requiring a Q14 answer first.
- **Q5 ← Q10.** Considered in reverse (does merge behaviour constrain re-engagement?) and rejected:
  merging is a correction of *identity*, re-engagement is a new *episode*. They meet in Q10, not Q5.

### 2.4 Graph shape, in prose

The graph is shallow and has two clusters plus four isolates.

- **Terminality cluster.** **Q5** and **Q6** are the two roots. They feed **Q10**, **Q15** and
  **Q16** directly; **Q16** feeds **Q15** weakly; **Q11** feeds **Q10**'s attribution half. Maximum
  chain depth is three (Q5/Q6 → Q16 → Q15). Everything in this cluster is core state-machine
  semantics.
- **Time-axis cluster.** **Q14** and **Q2** are mutually coupled, and **Q14** feeds **Q3**'s SLA
  half. This cluster writes rules onto derived conditions, not onto persisted state.
- **Isolates.** **Q8**, **Q9**, **Q12**, **Q13** — no edges in either direction within the thirteen.

No cycles exist within the thirteen. The only bidirectional relationship (D-11, Q2 ↔ Q14) is a
coupling to be answered jointly, not a cycle to be broken.

---

## 3. Independently resolvable questions

"Independent" = **no open question among the thirteen must be answered first**. Cross-blocker
prerequisites (§2.2) may still apply and are noted.

| Q | Independent? | Note |
|---|---|---|
| **Q5** | Yes (root) | Nothing blocks it. Five things wait on it. |
| **Q6** | Yes (root) | Nothing blocks it; §8.2 already did most of the work. |
| **Q8** | Yes (isolate) | Pure MVP-scope call. |
| **Q9** | Yes (isolate) | Additive axis; see §6 for reassignment. |
| **Q12** | Yes (isolate) | Freed by §8.4; see §6. |
| **Q13** | Yes (isolate) | Subject to X-4 (N-3) and §6's reassignment. |
| **Q14** | Yes (root) | Subject to X-6 (N-2), currently obstructed — see §7.1. Should be answered with Q2 (D-11). |
| **Q11** | Effectively yes | D-8 is weak and largely discharged; the real prerequisite is X-2 (M-5). |

**Not independent:** Q2 (D-4, D-11), Q3 (D-10, X-5, X-7), Q10 (D-1, D-5, D-9, X-1),
Q15 (D-3, D-7, D-12), Q16 (D-2, D-6, X-3).

---

## 4. Recommended next question

> ### **Q5 — "Can a Dumped lead be re-engaged, or does re-contact create a new lead?"**
>
> **Recommendation is about ordering only. No answer to Q5 is proposed, implied or preferred here.**

**Why Q5 and not another.**

1. **Highest out-degree among the roots.** Q5 has four dependents inside the thirteen (Q10, Q15,
   Q16 hard; Q2 conditional) and one outside (N-4 — the recoverability-posture *values* of the Dump
   framework §8.3 approved as dimensions but left unvalued). No other open question unblocks as much.
2. **It is the last remaining question that can change the model's *shape* rather than its
   parameters.** §8 has reduced Q2, Q8, Q9, Q11, Q12 and Q13 to scope, policy or additive concerns.
   Of the questions that still alter structure, Q5 is the only one whose "create a new lead" branch
   introduces a persisted structural element that does not otherwise exist: an explicit lead-to-prior-lead
   reference, which E-01 identifies as the thing that stops history fragmenting across attempts. That
   is a field on the canonical entity, not a value in a master table.
3. **The rework asymmetry runs one way.** If Q10, Q15 and Q16 are answered first under an assumed-terminal
   Dump and Q5 later permits reopening, all three answers are re-derived: merge precedence, the
   concurrency guard, and the terminal-transition permission gate each rest on "terminal means final."
   Answering Q5 first costs those three nothing. This is the same asymmetry AD-01 §11 invokes for the
   scope anchor and the reconciliation report raises in §L.5: the dimension is cheap before history
   accumulates and expensive after. Under the "new lead" branch it is worse than cheap-versus-expensive
   — a lead-to-prior-lead link cannot be reconstructed retroactively for leads that never recorded one.
4. **It completes a decision already approved.** §8.3 approved recoverability posture as a mandatory
   dimension of the Dump framework while approving no values. "Recoverable" has no operational meaning
   until Q5 states what recovery consists of. Q5 is therefore not merely the next question — it is the
   question that makes an already-approved decision usable.

**Runner-up, and a cheaper pairing.** **Q6** is the other root of the same cluster and, after §8.2,
has the smallest residue of any open question (only: is there a legal exit from Success other than
booking cancellation). Q10, Q15 and Q16 each depend on *both* Q5 and Q6, so answering the two together
in one sitting unblocks the entire terminality cluster in a single pass. If only one question can be
taken, take Q5; if two, take Q5 and Q6 together, in that order.

**Explicitly not recommended next:** Q10. It has the most inbound edges of any question (D-1, D-5,
D-9 and the hard cross-blocker X-1 on M-5) and is the single worst question to attempt early.

---

## 5. Safely deferrable until after the Lead state model is finalized

"Safely deferrable" = the core state machine can be finalized without it, and answering it later
does not force rework of the state model.

| Q | Deferrable | Condition / caveat |
|---|---|---|
| **Q8** | Yes | §5.4/§8.5 fixed the structure; only build-or-not remains. |
| **Q9** | Yes | Additive orthogonal axis. Deferral is *safe specifically because* §8.6 adopted the Orthogonal Lead Model; under a collapsed single-status design it would not have been. |
| **Q12** | Yes | Deferrable **because of** §8.4/§8.6, not independently of them. If the origin-independence of the verification gate were ever revisited, Q12 becomes blocking again. |
| **Q13** | Yes | Residue is queue-admission policy, not lead state. |
| **Q15** | Yes | A concurrency guard is chosen once terminality is known; it does not shape the state model. Defer until **after** Q5/Q6. |
| **Q11** | Yes | For lead-state purposes. The cut-off is commission policy — see §6. |
| **Q2** | Yes, with caveat | §8.1 and §1.7 foreclosed the only answer that would have changed the model (a Nurture/Parked lifecycle value). What remains is a date rule. **Caveat:** answer jointly with Q14 (D-11). |
| **Q14** | **Split** | The numeric **thresholds** are configuration and defer freely. The **structural** half — whether escalation has any suppressible input at all — does **not** defer, because it is entangled with the contradiction in §7.1 and with N-2. |
| **Q3** | **Split** | The SLA half defers with Q14. The **initial-state** half does not fully defer: it collides with §8.3's mandatory-reason rule (§7.2, X-5). |

**Not deferrable — these are the core state machine:** **Q5**, **Q6**, **Q10**, **Q16**, plus the
structural halves of **Q14** and **Q3**.

---

## 6. Questions recommended for reassignment to a different blocker

Reassignment is **recommended, not performed**. No question is resolved here or elsewhere by this
document, and nothing below touches the substance of the receiving blocker.

### 6.1 Q9 → **M-8** (strong)

**Q9 — does the business need lead temperature (hot/warm/cold) or a lead score?**

M-8 asks "Does BMexa need a weighted pre-booking pipeline?" and owns the retire-or-reseed decision
for `deal_stages` / `deal_loss_reasons`. Q9 and M-8 are the same question class — *does a
prioritization/forecasting dimension exist on the pre-booking lead that the spec never defines?* —
with the same consumers (§63 dashboards, §64 item 19 reporting) and the same failure mode if answered
twice inconsistently. AD-01 §3.2 already separates weighted pipeline position from lifecycle and
points at M-8; §3.4 establishes that temperature is absent from all 97 sections. Leaving Q9 inside
M-1 invites re-litigating §09's vocabulary to accommodate an axis that §09 never described.
**Recommendation: move Q9 to M-8. Do not resolve it in M-1.**

### 6.2 Q13 → **M-14** (strong)

**Q13 — how are offline captures from a since-deactivated user handled on sync?**

§47 names "authentication expiry, revoked permissions" in a single list of conditions the sync system
must handle. M-14 already owns the expiry case ("what happens to a queued offline operation when the
session expires before it syncs"). Q13 is the revoked-permission sibling of exactly that decision, and
deciding them in separate blockers risks two inconsistent queue-admission policies for one queue.
Q13's only lead-specific residue — what happens to the arriving record's handler — was removed from
M-1 by §8.5 and now sits with N-3 (X-4).
**Recommendation: move Q13 to M-14, decided jointly with it. Do not resolve it in M-1.**

### 6.3 Q11 → decide jointly with **M-5**; cut-off is commission policy (partial)

**Q11 — can an attribution claim be filed against an already-converted lead, and is there a cut-off?**

The half that belonged to M-1 — *can a Success lead acquire a Contested attribution state without its
lifecycle changing?* — is already answered by §8.6's orthogonality and needs no further decision. The
live half is a filing cut-off with a §32/§40 commission consequence, whose hard prerequisite is M-5
(whether the claim attaches to the Lead or the Person — M-5's own blocking list says so) and whose
consumer is the commission engine that M-9 serves.
**Recommendation: keep the orthogonality finding in M-1; sequence the cut-off decision with M-5 and
the CP commission model rather than inside the Lead State Machine. Partial reassignment only.**

### 6.4 Q12 → **no existing blocker is a good home** (flag, do not force)

**Q12 — are lead-portal integrations in scope?**

Post-§8.4 this is no longer a state-machine question: a portal-ingested lead is a provenance fact
passing the same origin-independent verification gate. It is an **ingestion-channel scope** question
against §72 (which names only WhatsApp, email, telephony and accounting exports) and the §64 MVP
boundary. Reviewing M-2 through M-20: none owns integrations or MVP ingestion scope — M-14 is the
offline queue, M-17 is feature entitlements, and neither fits.
**Recommendation: raise Q12 as a new scope blocker rather than shoehorning it into an existing one or
leaving it in M-1. Naming and filing that blocker is outside this analysis.**

### 6.5 Q8 — considered, keep in M-1

Pure MVP-scope, no M-blocker owns MVP scope generally, and §5.4/§8.5 already settled its structural
consequence. Not worth a move. **Recommendation: keep in M-1 as a scope footnote.**

---

## 7. Contradictions flagged (not resolved)

### 7.1 Contradiction — "Blocked" cannot be derived from next-action timing

**Stated, not resolved, per this task's constraint. This is a flag to the project owner, not a
reopening of Q1.**

**The decisions involved:**

- **AD-01A §8.1** — approves Q1's rejection of "Pending," lists *"Awaiting Response," "Blocked," Today,
  Future, Overdue* as operational/Action-Feed conditions, and states that *Today / Future / Overdue*
  must be **derived from next-action timing**.
- **AD-01A §8.6** — restates the same set as *"Today / Future / Overdue / **Blocked**, computed from
  next-action timing, not stored."*
- **AD-01A §1.7** — the recommendation §8 approved (§8.7: "these decisions approve AD-01A's
  conclusions only — §§1–5") represents the Blocked distinction as a **qualifier carried on the
  next-action commitment** — "who owes the next move" — explicitly as **R4 tenant-configurable master
  rows with a system-owned semantic column**, i.e. a persisted, non-lifecycle input.
- **AD-01A §6.2 / N-2**, which §8.7 confirms remains open, asks *"what are the values of the 'waiting
  on' qualifier, and which of them suppress §58 escalation?"* — a question that presupposes the
  qualifier exists and is persisted.

**The contradiction.** "Blocked" is a statement about *who owes the next move*, not about *when it is
due*. Two leads with identical next-action timestamps — one awaiting a lender's sanction letter, one
simply scheduled for Thursday — are indistinguishable by any function of timing. §8.6 therefore
asserts a derivation that cannot exist from the stated input. Either:

- **(a)** Blocked really is derived from timing alone — in which case §1.7's approved qualifier is
  unnecessary, N-2 has no subject, and §58 escalation has nothing to key suppression on; or
- **(b)** the approved §1.7 qualifier is persisted — in which case §8.6's parenthetical "computed
  from next-action timing, not stored" is inaccurate as written for Blocked, though it remains correct
  for Today / Future / Overdue.

Note that this is a contradiction *between two statements inside §8*, and that **neither branch
requires "Pending" to become a lifecycle state** — §8.1's actual decision is unaffected either way.

**Which open questions it obstructs.** **Q14** (escalation thresholds have no suppressible input under
branch (a) — edge X-6), and **Q2** (a legitimately long-dated lead is precisely the case one would
want excluded from escalation). It does not obstruct Q5, Q6, Q10, Q15 or Q16.

**No resolution is proposed here.** Per BMexa §97 and R12, this is the asking.

### 7.2 Tension (not a contradiction) — mandatory Dump reason versus legacy import

**§8.3** requires that a terminal non-conversion disposition **must carry a reason**, and that the
historical reason be preserved rather than rewritten; **N-4** (open) owns the reason values. **Q3**
asks whether imported leads land in New or in their historical state.

If imports may carry historical Dump, the import either cannot satisfy the mandatory-reason rule
(the source system has no such field) or must synthesize one — which fabricates business history
against §07 and R6. This is **resolvable within N-4** by providing a value that honestly denotes
"not recorded in the source system," and it is therefore recorded as a **tension requiring N-4 to
account for imports**, not as a contradiction. It is the basis of edge **X-5**, and it is the reason
Q3's initial-state half is listed as not fully deferrable in §5.

### 7.3 Nothing else found

No other direct logical contradiction between an AD-01A §8 decision and anything an unresolved
question requires was identified. In particular, §8.2's "a cancelled booking must not rewrite Success"
and §8.3's mandatory reason on terminal *non-conversion* dispositions do not conflict: a Success lead
whose booking later cancels remains Success and acquires no non-conversion disposition.

---

## 8. Explicitly out of scope for this document

- **Any question's substance.** Q2, Q3, Q5, Q6, Q8–Q16 are analysed **only** for ordering and
  dependency. None is answered, narrowed, recommended, or given a preferred branch. Where a §8
  decision has already narrowed a question's answer space, that narrowing is reported as an existing
  fact, not produced here.
- **Q1, Q4, Q7.** Decided per AD-01A §8 and treated as fixed. §7.1 flags an internal inconsistency in
  the *recording* of the Q1 decision and does not reopen the decision itself.
- **N-1, N-2, N-3, N-4.** Referenced only as far ends of cross-boundary edges. Not analysed, not
  answered.
- **Every other blocker's substance.** M-2 … M-20 are referenced only to (i) identify cross-blocker
  prerequisites (§2.2) and (ii) evaluate reassignment homes (§6). Nothing in M-3, M-5, M-7, M-8, M-9
  or M-14 is decided, and the reassignment recommendations carry no answer with them.
- **Schema, SQL, migrations, seeding, masters, implementation.** None appears above, and none may be
  derived from this document. AD-01 and AD-01A both remain **NOT APPROVED FOR IMPLEMENTATION**
  (§8.7), and this analysis changes that in no way.
- **Approval.** This document authorizes nothing. Under §88 every remaining question sits in the
  MUST ASK BEFORE DECIDING column; per AD-01A §7, delegation to an architect is not authorization.

---

**STATUS: ANALYSIS ONLY — NO DECISIONS.** The Lead State Machine remains unresolved and unapproved.
The recommendation in §4 is a recommendation about *sequence*, and nothing more.
