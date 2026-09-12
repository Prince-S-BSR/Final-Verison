STATUS: PROPOSED — NOT APPROVED

# Architecture Decision 01E — Lead State Machine: Dump Re-engagement, Revival, and Controlled Historical Visibility (Q5, re-opened)

> Nothing in this document is decided, approved, implementable, seedable or migratable. It contains
> no SQL, no schema, no migration, no column, table or type name, and no implementation of any kind.
> Under Master Spec **§88** every question below sits in the **MUST ASK BEFORE DECIDING** column —
> canonical entities, relationships, authorization rules, source-of-truth rules and audit
> requirements are all engaged. Per AD-01A §7: **delegation to an architect is not authorization.**
> This document is the asking.

| | |
|---|---|
| **Decision ID** | AD-01E |
| **Supersedes** | The **Q5 recommendation only** of [AD-01C §2.5](./03c-lead-state-machine-terminality-decision.md#25-architect-recommendation--q5). AD-01C's Q6 recommendation (§3.7) is **untouched and not reopened**. AD-01C's Part 1 (the Blocked clarification) is untouched. |
| **Amends** | [AD-01](./03-lead-state-machine-decision.md), [AD-01A](./03a-lead-state-machine-decision-amendment.md), [AD-01C](./03c-lead-state-machine-terminality-decision.md). All remain **NOT APPROVED FOR IMPLEMENTATION**. |
| **Companion to** | [AD-01B](./03b-lead-state-machine-dependency-order.md) — dependency analysis. Its §7.1 contradiction (**N-2**) is **not** resolved here and is **not** touched. |
| **Scope** | Exactly one question, in seven parts: **Q5** re-analysed under new product-owner direction — Q5-A (lead identity), Q5-B (revival lifecycle), Q5-C (historical visibility), Q5-D (assignment provenance), Q5-E (history boundaries), Q5-F (security), plus the revive-vs-new-lead discriminator. **Nothing else.** |
| **Explicitly out of scope** | **Q6** — approved per AD-01C §3.7; §5.6 below flags one tension and explicitly declines to reopen it. **N-2** (Blocked persistence). **M-5** (uniqueness boundary), **M-7** (record-visibility vocabulary), **M-3** (role set), **M-9** (commission model) — referenced only as far ends of dependencies. **Q1, Q4, Q7**, the sync/verification split and the elimination of the assignment axis — decided at AD-01A §8, treated as fixed. **T-1 … T-12** — raised by AD-01C, none resolved here. Every other blocker (M-2 … M-20). The schema. The RBAC permission set. |
| **Contains SQL / schema / migration** | **No.** Deliberately. |
| **Constraints honoured** | `ENGINEERING_RULES.md` **R1** (tenant isolation), **R2** (no branching on role names), **R4** (masters not enums; semantics in columns), **R5** (nothing authorization-relevant read from `custom_attributes`), **R6** (append-only audit; never edit history), **R12** (every claim traceable to this repository's documents), and Spec **Rule 1** (do not invent requirements — spec silence is recorded in [§12](#12-explicit-unresolved-business-decisions), not filled). |
| **Sources re-read** | `docs/BMEXA_MASTER_SPEC.md` §03, §05, §06, §07, §08, §09, §10, §11, §12, §13, §14, §20, §26, §32, §33, §35, §39, §40, §41, §42, §43, §44, §45, §46, §47, §50, §52, §53, §54, §56, §57, §58, §61, §63, §64, §68, §71, §72, §86, §87, §88, §95, §96, §97; `docs/ENGINEERING_RULES.md` R1, R2, R4, R5, R6, R12; AD-01 §1.2, §1.3, §3.5, §6.1, §7 (E-01 … E-24), §8.2–§8.6, §9.1–§9.7, §10; AD-01A §1.7, §3.5, §8.1–§8.7; AD-01B in full; AD-01C in full; `01-bmexa-architecture-reconciliation.md` §E.5, M-3, M-5, M-6, M-7, M-9. |

---

## How to read this document

Four labels are used **throughout**, not only in a summary section. Every substantive claim below
carries exactly one of them.

| Label | Meaning |
|---|---|
| **⟦PRODUCT-OWNER DIRECTION⟧** | What the project owner has stated. Recorded verbatim or faithfully paraphrased. **A direction recorded here is not thereby an approved architecture** — it is the input this analysis was asked to evaluate. |
| **⟦ARCHITECT ANALYSIS⟧** | A consequence, tension or finding derived from the spec and the prior AD-01 documents. Factual claim about what follows from what. Mine to defend. |
| **⟦ARCHITECT RECOMMENDATION⟧** | A proposed course of action. **Recommended, subject to the project owner's explicit written approval. Not approved.** |
| **⟦BUSINESS DECISION REQUIRED⟧** | The spec is silent and nothing here fills the gap. Numbered **U-n** to avoid collision with the existing Q / N / M / E / D / X / T namespaces. Consolidated in [§12](#12-explicit-unresolved-business-decisions). |

**The seven concerns this document keeps strictly apart, and never conflates:**

| # | Concern | The question it answers |
|---|---|---|
| **C1** | Lead identity / continuity | Is this the same business record? |
| **C2** | Lead lifecycle revival | What does the lifecycle axis do when work resumes? |
| **C3** | Lead assignment | Who holds this lead now, and how did they come to hold it? |
| **C4** | Historical business record | What happened before, as a durable, unalterable fact? |
| **C5** | Historical visibility / authorization | Who is *entitled to read* what happened before? |
| **C6** | Current handler's permitted view | What does the person working it today actually see? |
| **C7** | Sales Head / Reporting Manager visibility | What does management see, and on what authority? |

**The single most important structural claim in this document** is that C1 and C5 are independent,
and that the product-owner direction is the first requirement in the whole Lead State Machine to
separate them. Everything in §6 follows from that.

---

## 1. Product Owner's new Q5 direction (recorded)

### 1.1 The direction, recorded before any analysis

> **⟦PRODUCT-OWNER DIRECTION — recorded as given, not re-derived and not re-argued in this section⟧**
>
> When a Lead is in **Dump** and the same client/prospect re-engages, the **preferred business
> behavior is to REVIVE THE EXISTING LEAD**, not automatically create a new Sales Lead. The existing
> Lead record and its history remain the same Lead.
>
> But **historical visibility after revival depends on how the revived lead is assigned**:
>
> - **Case 1 — the original handler regains it.** The handler sees previous history. One continuous
>   historical record.
> - **Case 2 — the Sales Head explicitly reassigns it back to the original handler.** The handler
>   sees previous history; the Sales Head retains appropriate management visibility.
> - **Case 3 — automatic reassignment to a new/different handler.** The new handler must **NOT**
>   automatically see the historical record from the previous handling episode. The Sales Head and
>   authorized Reporting Managers **must** see full history. The historical record must remain
>   intact — **never** deleted, reset, copied into a new lead, or rewritten merely because
>   visibility differs.
>
> **Explicitly rejected as insufficient:** `original_handler_id = current_handler_id`. The Sales-Head
> reassignment scenario (Case 2) demonstrates that a simple identity check does not capture the rule —
> a *different current handler* than the original can still be authorized to see history if a Sales
> Head explicitly put them there.

### 1.2 What this direction does and does not state

> **⟦ARCHITECT ANALYSIS⟧** Recorded as bookkeeping so that later readers do not over-read the
> direction, and so that the gap between what it says and what an architecture needs is visible.

**The direction states, unambiguously:**

1. Revival of the existing Lead is the **preferred** behaviour on re-engagement of a Dumped lead.
2. The historical record is **inviolable** — never deleted, reset, copied, or rewritten. This is a
   restatement of §07 ("do not destroy historical identity"), §56, and **R6** in the specific context
   of revival, and it is the single strongest constraint the direction imposes.
3. Historical **visibility** is conditional on assignment circumstances, and is therefore **not** a
   property of the record.
4. Sales Head and authorized Reporting Managers have an unconditional full-history entitlement.
5. Custody identity (`original_handler_id = current_handler_id`) is **not** the discriminator.

**The direction does not state, and this document does not supply:**

- **What "re-engages" means as a business condition** — whether any inbound contact qualifies, or
  whether the contact must concern the same opportunity. (§3, **U-1**.)
- **When revival is *not* the right answer** — the word "preferred" implies a non-preferred branch
  exists, but the direction does not say what triggers it. (§5, **U-1**, **U-2**, **U-3**, **U-4**.)
- **Whether an explicit Sales Head assignment to a handler who never worked the prior episode confers
  history.** Case 2 as written covers only reassignment *back to the original handler*, who would be
  entitled by participation alone. The generalisation — that explicitness itself confers — is a
  plausible reading and is the reading this task was framed around, **but it is not what the
  direction literally says.** This gap is load-bearing: it determines whether assignment provenance
  is architecturally necessary at all. (§6.4, §7, **U-7**.)
- **Which principals count as "authorized Reporting Managers."** §03 names eleven builder-side roles;
  "Reporting Manager" is not among them, and **M-7** (record-visibility breadth vocabulary, and
  whether "team" is a real concept) is unresolved. (§6.6, **U-10**.)
- **What "previous history" is made of.** (§6.7, **U-11**, **U-12**.)

> **⟦ARCHITECT ANALYSIS⟧** Point 2 and point 3 together are the direction's most consequential
> content, and they are in productive tension: the record must be **one continuous thing**, and its
> contents must be **differentially readable**. Every difficulty in this document descends from
> holding both at once.

---

## 2. Conflict with the previous Q5 recommendation (explicit confrontation with AD-01C)

> **⟦PRODUCT-OWNER DIRECTION⟧** The direction recorded in §1 — *revive the existing Lead rather than
> automatically create a new Sales Lead* — **supersedes AD-01C's Q5 recommendation**. AD-01C's Q6
> recommendation, its Part 1 clarification, and every AD-01A §8 decision are untouched by it. This
> section confronts the supersession directly rather than quietly replacing one recommendation with
> another.

### 2.1 What AD-01C recommended, stated exactly

> **⟦ARCHITECT ANALYSIS⟧** [AD-01C §2.5](./03c-lead-state-machine-terminality-decision.md#25-architect-recommendation--q5)
> recommended **Alternative B**: re-contact of a prospect whose lead reached Dump creates a **new
> Sales Lead**; the Dumped lead is never reopened; **Dump remains strictly terminal to ordinary
> lifecycle transitions**; AD-01 §6.1's *Dump → Follow-up* row is **removed** rather than enabled.
> The recommendation carried four non-optional conditions: a **mandatory, typed** successor
> reference; successor linkage kept semantically distinct from merge linkage; duplicate/clash
> detection recognising a declared successor; and reactivations separable in reporting.
>
> AD-01C reached that recommendation **independently** and recorded that it happened to agree with
> the owner's then-stated provisional preference for B, while being *more* prescriptive than the
> preference (mandatory rather than "controlled" reference).

**The conflict is direct and total on the mechanism.** AD-01C says *never reopen the Dumped lead*;
the new direction says *revive the existing lead*. There is no reading on which both stand.

### 2.2 Which of AD-01C's twelve arguments survive the new direction, and which do not

> **⟦ARCHITECT ANALYSIS⟧** The new direction is not evidence that AD-01C's analysis was wrong. It is
> a different business preference, and the costs AD-01C identified do not disappear because the
> preference changed. Each is re-tested below against revival **as the direction states it** — the
> same Lead record, one continuous history.

| AD-01C dim. | The argument against reopening | Does it still bite under the new direction? |
|---|---|---|
| **D1** — lifecycle history | Terminality becomes "terminal-unless-reopened"; `is_terminal` stops meaning what it says; a lead may hold two or more terminal transitions. | **Yes, fully.** This is an unavoidable cost of revival and cannot be argued away. Every consumer keyed on terminality inherits the ambiguity permanently. |
| **D2** — Person vs. Lead identity (§06/§07) | One record spanning two sales *processes* blurs §06's *process* component. | **Yes**, unless the episode becomes a first-class bounded unit inside the lead (§3.3). With episodes, the §06 *process* component is preserved at the episode level and D2 is answered. |
| **D3** — project / sales context | Revival cannot serve the **different-project** case at all without rewriting the lead's project and corrupting §08 project scope retroactively. | **Yes, fully and without remedy.** Revival is structurally available **only** for same Person × same Project. Cross-project re-engagement remains a new Lead under §06 / AD-01 E-09. **The direction therefore cannot be a universal rule** — it is a rule for one case, and the other case already has a settled answer. |
| **D4** — conversion reporting | Converted keys on the lead's *current* state (AD-01 §9.1), so a revived-and-converted lead retroactively stops being a loss in the closed period. | **Yes**, unless the funnel is re-keyed from lead to episode (§9, **U-6**). Re-keying the funnel is a change to a **source-of-truth rule** and is §88 MUST-ASK. |
| **D5** — source attribution | One lead carries one source; the second episode's source is unrecordable without rewriting history. | **Yes**, unless source is episode-scoped. With episodes, answered. |
| **D6** — CP attribution and clash (§11, §32, §33, §40) | One lead holds one claim set spanning two episodes, so the system cannot distinguish a genuine §11 clash from two CPs legitimately claiming two episodes — with §32/§40 **commission** consequences. AD-01C called this "the decisive argument against A." | **Yes — and this remains the single most dangerous unresolved consequence.** It is answerable **only** if attribution claims are episode-scoped. That turns **M-5**'s open question ("does the claim attach to the Lead or the Person?") into a three-way question by adding **Episode** as a candidate (**U-15**). Approving revival without resolving this leaves a live financial defect. |
| **D7** — sales-cycle measurement | Time-in-pipeline spans dormancy and every velocity average is corrupted. | **Yes**, unless cycle metrics are episode-scoped. With episodes, answered; the lead's total age is then explicitly *not* a sales cycle. |
| **D8** — reactivation reporting | Under reopening, a re-Dumped lead either overwrites its earlier disposition and reason — which **AD-01A §8.3 forbids** — or forces reasons to be historised. | **Yes**, and this is decisive in a way AD-01C only noted in passing: **the direction's own intactness requirement forbids the overwrite.** Reason historisation is therefore not optional under revival; it is mandatory (§4.4). |
| **D9** — audit and history | The live record carries a Dump reason describing a *past* episode, so the field's meaning becomes ambiguous. | **Yes**, resolved by the same episode-scoping that resolves D8. |
| **D10** — duplicate detection (§09, M-5) | **AD-01C conceded this to reopening.** A successor lead is a strong duplicate candidate by construction; every re-engagement risks a false duplicate alert. | **No — and revival is genuinely stronger here.** No new record is created, so no false duplicate arises, and AD-01C's **T-1** requirement on M-5 is discharged. A different requirement replaces it: the detection engine must recognise an inbound re-contact matching a *Dumped* lead and route it toward revival rather than creation. |
| **D11** — future extensibility | Semi-terminality is permanent and weakens the one axis the Orthogonal Lead Model holds fixed. | **Yes, partly.** Mitigated if the lifecycle value is carried by the episode rather than by the lead (§4.3), which restores strict monotonicity *within* an episode. |
| **D12** — historical reconstructibility | Under a successor lead, reconstructibility depends entirely on a reference captured at creation and unrecoverable later; an optional reference makes B worse than reopening. | **No — revival is decisively stronger.** One record cannot lose its own history. The mandatory-reference discipline AD-01C called non-optional simply disappears. This is revival's strongest architectural advantage and it should be stated plainly. |

### 2.3 The honest summary of the conflict

> **⟦ARCHITECT ANALYSIS⟧** Of AD-01C's twelve dimensions, **two now favour revival** (D10, D12),
> **one is fatal to revival as a universal rule but not as a scoped one** (D3 — cross-project
> re-engagement must still create a new lead), **seven are answerable if and only if the commercial
> episode becomes a first-class bounded unit** (D2, D4, D5, D6, D7, D8, D9), and **two remain
> genuine, unmitigated costs of revival** (D1 — permanent terminality ambiguity; D11 — partially
> mitigated only).
>
> **AD-01C's Q5 recommendation is therefore not refuted by the new direction — it is outbid on two
> dimensions it lost, and conditionally answerable on seven it won.** The conditionality is the whole
> finding, and it is not a formality: seven of AD-01C's arguments are answered by one structural
> commitment, and none of them is answered without it.

> **⟦ARCHITECT ANALYSIS⟧ One asymmetry runs the other way, and it is the reason this document's
> recommendation is conditional rather than enthusiastic.** AD-01C's Alternative B delivers the
> direction's *visibility* requirement for free. Under B, the prior episode is a **different record**;
> "the new handler must not see it" is enforced by the record-level authorization the product already
> needs for every other purpose (§E.5 of the reconciliation report: breadth on the grant —
> own / team / scope / all, pending **M-7**). Under revival, the prior episode's contents live inside
> a record the new handler legitimately holds, so the boundary becomes **intra-record** and must be
> re-enforced independently at every surface that can read a lead: API, search, export, reports,
> background jobs, notifications, attachments and audit. **The direction's own Case 3 is cheap under
> the recommendation it supersedes and expensive under the one it prefers.** That is a real cost, it
> is not an argument against the direction, and the owner should approve it knowingly (§8).

---

## 3. Lead continuity analysis (Q5-A)

**The question:** is reviving the existing lead architecturally sound, and what business condition
distinguishes genuine re-engagement of the same lead from a genuinely new opportunity?

### 3.1 The scoping finding that must come first

> **⟦ARCHITECT ANALYSIS⟧** §06 defines a Sales Lead as a relationship between **Person, Project and
> sales process**. AD-01 **E-09** confirms that the same Person enquiring about a different project
> is two leads, and AD-01C §2.1 established that reopening cannot serve that case without moving the
> record across the project-scoped access boundaries §08 defines and falsifying every project-level
> report that ever included it.
>
> **Therefore the direction is necessarily scoped to same Person × same Project.** Re-engagement on a
> different project is already a new Lead, settled by §06 and E-09, and is not a Q5 question at all.
> This is not a limitation the architect is imposing; it is the existing model. **The direction should
> be read as: "when the same prospect re-engages on the same project, revive rather than create."**

### 3.2 Same Person + same Project does not, by itself, mean the same commercial episode

> **⟦ARCHITECT ANALYSIS⟧** This is the core of Q5-A and the task directs it be tested rather than
> assumed. Three facts from this repository's own documents establish it:
>
> 1. **§06 makes *process* a component of the Lead's identity, coequal with Person and Project.** Two
>    engagements separated by a terminal disposition are two processes by the plain meaning of the
>    definition. Person and Project matching is two-thirds of an identity test, not the whole of it.
> 2. **AD-01C §2.2 D2 established that the spec is silent on this exact pair.** §07's blessing of
>    multiple leads per Person is general and is illustrated by *different* contexts ("multiple
>    projects, become a customer, be an applicant/co-applicant"). **Nothing in the spec addresses two
>    sequential engagements on the identical Person × Project pair.** Silence is a finding, not a
>    permission.
> 3. **§11, §32 and §40 make the commercial episode the unit that carries money.** A CP's attribution
>    claim, its resolution, and the §32/§40 commission that follows are claims about *who produced
>    this engagement* — not about *who introduced this person once*. If two engagements can have
>    different producers, they are commercially two things regardless of what the Lead record is.

> **⟦ARCHITECT ANALYSIS⟧ What does bound an episode, then?** Not time, and not activity volume.
> AD-01 §8.4 already establishes that repeated inquiries and repeated site visits are **activity
> records**, and AD-01 **E-05** establishes that a lead going cold and hot again is *derivable from
> activity* and is **not** a state change. So:
>
> > **An episode is bounded by a terminal disposition, not by a gap in contact and not by a count of
> > interactions.** A prospect who goes quiet for four months inside an open Follow-up lead has had
> > **one** episode. A prospect whose lead was Dumped and who returns has had **two** — that is what
> > the Dump asserted.
>
> This is a clean, spec-derived boundary, and it is the definition on which the rest of this document
> depends. It also answers "repeated inquiries" and "repeated site visits" directly: neither creates
> an episode.

### 3.3 The structural consequence: revival requires the episode to become first-class

> **⟦ARCHITECT ANALYSIS⟧ This is the central architectural finding of this document.**
>
> The direction's visibility requirement is self-proving on this point. Case 3 requires that a new
> handler not see "the historical record from **the previous handling episode**." **A visibility rule
> cannot be scoped to a unit that does not exist.** To say "the previous episode is restricted and the
> current one is not," the system must be able to say which facts belong to which episode — for
> activities, notes, site visits, attachments, dispositions, reasons, sources, attribution claims,
> assignment entries and derived aggregates alike.
>
> Under AD-01C's Alternative B, the episode boundary **was** the Lead record, and no new concept was
> needed. Under revival, the Lead record spans episodes, so the boundary must exist as a structure
> *within* the lead. **The direction therefore does not eliminate the episode; it relocates it.**
>
> Two independent confirmations that this is forced, not chosen:
>
> - **The intactness requirement forces it.** The direction says the historical record must never be
>   "rewritten." A lead carries one lifecycle value, one terminal disposition and — per AD-01A §8.3 —
>   one preserved Dump reason. Reviving without episodes **rewrites all three**: the lifecycle value
>   moves off Dump, and a second closure either overwrites the preserved reason (which AD-01A §8.3
>   forbids outright) or has nowhere to go. **Naive revival violates the direction's own core
>   requirement.**
> - **§11's clash control forces it.** Without an episode boundary, two CPs claiming two different
>   engagements of one lead are indistinguishable from two CPs claiming one engagement. AD-01C D6
>   showed this is a **financial** failure through §32/§40, not a cosmetic one.

> **⟦ARCHITECT ANALYSIS⟧** Once episodes are first class, revival and the successor-lead model become
> **informationally near-equivalent**. Both preserve one bounded record per engagement; they differ
> only in *where the boundary is drawn* — inside one record, or between two. The remaining differences
> are therefore not about information fidelity at all. They are:
> (a) the identity story presented to users and to reports;
> (b) duplicate-detection behaviour (revival wins — D10);
> (c) reconstructibility discipline (revival wins — D12);
> (d) **the authorization surface** (the successor model wins, decisively — §2.3, §8).
> Stating this plainly matters, because it shows the choice is a **security and product** trade, not a
> data-modelling one, and should be decided on those grounds.

### 3.4 Test against the dimensions Q5-A names

| Dimension | Revival with first-class episodes | Verdict |
|---|---|---|
| **Person × Project scoping (§06)** | Preserved: one lead per Person × Project; *process* carried by the episode. | **Sound**, conditional on episodes. |
| **Repeated inquiries** | Activities within an episode (AD-01 §8.4, E-05). No episode created. | **Sound**; no decision needed. |
| **Repeated site visits** | Same — activity records (§09, §80). | **Sound**; no decision needed. |
| **Multiple sales episodes** | Exactly what the episode boundary represents. | **Sound**, conditional on episodes. |
| **CP attribution (§11)** | Requires claims to be **episode-scoped**. **M-5** currently asks Lead-or-Person; revival adds Episode. | **Conditional — unresolved. U-15.** |
| **Duplicate / clash detection (§09, §12, M-5)** | Stronger than the successor model: no new record, no false duplicate, AD-01C **T-1** discharged. New requirement: detection must route an inbound match against a Dumped lead toward revival. | **Sound and improved.** |
| **Commission (§32, §40)** | Must key on the **resolved claim of the converting episode**, consistent with AD-01 **E-13** (commission keys on the resolved claim, not on lead state) and AD-01C §3.2 (keys on the Booking, never on lifecycle). | **Conditional on U-15.** |
| **Reporting (§9.1)** | Funnel must be re-keyed from lead to episode or closed periods restate (D4). | **Conditional — U-5, U-6.** |
| **Sales-cycle measurement (§9.2)** | Episode-scoped cycles are correct; the lead's total age is explicitly not a cycle. | **Sound**, conditional on episodes. |
| **Historical auditability (§54, §56, §07, R6)** | Strongest case for revival: one record cannot lose its own history; no creation-time discipline to fail (D12). | **Sound and improved.** |

### 3.5 The discriminator the spec cannot supply

> **⟦BUSINESS DECISION REQUIRED — U-1⟧** **What business condition distinguishes genuine
> re-engagement of a closed opportunity from a genuinely new opportunity, for the same Person on the
> same Project?**
>
> The spec answers this **nowhere**. AD-01 §1.3 records re-engagement as "never addressed — the spec
> neither permits nor forbids it." AD-01C §5 re-confirmed it after an independent pass. There is no
> definition of an opportunity's boundary, no dormancy threshold (AD-01 §1.3: no SLA or response-time
> thresholds are defined anywhere; §58 sets no numbers), and no rule connecting a prospect's changed
> requirement to a new sales process. **Per Rule 1 and R12, no rule is invented here.**
>
> What the owner must decide is which of the following — alone or in combination — creates a new
> opportunity rather than reviving the closed one. Each is listed because it is *plausible*, **not**
> because the spec supports it:
> - elapsed time since the Dump (**U-4**);
> - the recoverability posture recorded on the Dump (**U-3**);
> - arrival through a different source or a different CP (**U-2**);
> - a materially different requirement — different configuration, budget band, or unit type;
> - nothing at all: revival is always correct for same Person × same Project.
>
> **Every one of these is a product rule with commission and reporting consequences. None may be
> chosen by an architect.**

> **⟦ARCHITECT ANALYSIS⟧ One dependency makes U-1 unanswerable in isolation, and it must be stated.**
> AD-01C raised **T-4**: *does a CP's claim on a Dumped lead reach a later, separately-sourced episode
> for the same Person?* — spec silent (§11, §32, §40, §41). If a returning prospect arriving through a
> **different CP** must be a new opportunity, then U-1's answer is partly determined by T-4's. If T-4
> says a prior claim reaches forward, revival with episode-scoped claims can hold both claims and let
> §11's authorized leadership adjudicate. **U-1 and T-4 should be answered in the same sitting, and
> answering U-1 alone is the most likely source of a silent commission defect.** (**U-2**.)

> **⟦ARCHITECT ANALYSIS — a reversal of AD-01C §2.6 that the owner should notice⟧** AD-01C §2.6
> recorded that Alternative B **stranded Dimension C** of the approved Dump-reason framework
> (recoverability posture, AD-01A §3.5/§8.3): under B "there is no such gate to hold," and posture was
> reduced to a triage and reporting input — recorded as **T-10**. **The revival direction un-strands
> it.** Under revival, posture is the natural gate: a Dump recorded as permanently closed does not
> revive; one recorded as revisitable does. AD-01B §4's claim that "Q5 is the question that makes an
> already-approved decision usable" is satisfied more completely by revival than by the successor
> model. **This does not reopen AD-01A §8.3** — the three dimensions remain approved and unchanged;
> only posture's *use* changes, which is exactly what T-10 left open. **But the gate cannot be
> specified**, because the posture *values* are **N-4** and remain unresolved. (**U-3**.)

### 3.6 Is revival architecturally sound? — the answer

> **⟦ARCHITECT ANALYSIS⟧** **Yes, conditionally — and the conditions are not decoration.**
>
> Revival of the existing Lead is architecturally sound **if and only if**:
> 1. it is scoped to **same Person × same Project** (cross-project re-engagement remains a new Lead
>    under §06 / E-09 — not a choice, an existing rule);
> 2. the **commercial episode becomes a first-class bounded unit** within the Lead, carrying its own
>    lifecycle value, source, terminal disposition, preserved reason, attribution claim set, handler
>    and activity association; and
> 3. **attribution and commission key on the episode**, not on the Lead (**U-15**).
>
> **Without (2) it is unsound**, because it violates the direction's own intactness requirement and
> reproduces AD-01C's D4, D5, D8 and D9 defects exactly. **Without (3) it is financially unsafe**,
> because AD-01C's D6 failure — a genuine §11 clash indistinguishable from two legitimate episode
> claims, feeding §32/§40 commission — is live and unmitigated.

---

## 4. Revival lifecycle analysis (Q5-B)

**The question:** what does the lifecycle transition mean — `Dump → Follow-up`, `Dump → New`, or
another model? **No implementation. Conceptual only.**

Lifecycle vocabulary is fixed by AD-01A §8.1 at four values (New · Follow-up · Success · Dump) and
**no new lifecycle value is proposed, contemplated or implied anywhere below.**

### 4.1 Option (i) — `Dump → Follow-up`

> **⟦ARCHITECT ANALYSIS⟧**
>
> **What it means.** AD-01 §6.1 already carries this row, marked *"permitted only if Q5 says so."*
> Enabling it makes Dump semi-terminal. §13 defines Follow-up as *"requires next action/date"*, and
> AD-01A §1.7 preserves that requirement unconditionally — so revival would have to commit a next
> action at the moment of revival. That is arguably correct (someone re-engaged; someone owes a
> response) and is the option's one genuine merit.
>
> **Reporting consequences.**
> - **Conversion funnel (AD-01 §9.1).** *Converted* keys on the lead's **current** state. A lead
>   captured and Dumped in Q1, revived in Q3 and converted in Q4 **retroactively stops being a loss in
>   the Q1 cohort**. A published loss count moves. Under **R6**'s posture — history is appended, never
>   rewritten — a reporting model whose past outputs move is the same defect expressed in analytics.
> - **Closed-without-conversion bucket.** The lead leaves it, so "how many leads did we lose in Q1"
>   becomes unanswerable without time-travel.
> - **Velocity (§9.2).** Time-in-pipeline spans the dormancy. *Days New → first Follow-up* becomes
>   ambiguous: does revival restart the responsiveness clock, and if not, what does the second
>   engagement's responsiveness mean?
> - **Terminality (R4).** `is_terminal` and the state-type semantic column stop being trustworthy for
>   every consumer (AD-01C D1).
>
> **The disqualifying defect.** A lead carries **one** lifecycle value and **one** preserved terminal
> reason (AD-01A §8.3). Moving the value off Dump rewrites the first; a second closure overwrites the
> second, which **AD-01A §8.3 explicitly forbids**. **Option (i) as stated therefore conflicts with
> the product owner's own intactness requirement** and with an already-approved decision.

### 4.2 Option (ii) — `Dump → New`

> **⟦ARCHITECT ANALYSIS⟧**
>
> **It is already forbidden.** AD-01 §6.1's forbidden-transition list names ***Anything → New***. This
> option does not merely have costs; it contradicts an existing constraint of the state machine that
> nothing in AD-01A §8 relaxed.
>
> **And it is semantically false.** "New" means never worked. AD-01 §9.1 defines *Worked* as "leads
> that have ever left New," derived from state history. A revived lead would then be simultaneously
> **New** and **Worked** — an internally contradictory funnel row that no report can render honestly.
> The responsiveness metric (§9.2) would restart on an already-worked lead, and the §14 Action Feed's
> "New leads" bucket would surface a lead with months of prior contact as a fresh capture.
>
> **Reject.** Option (ii) is the weakest of the three on every dimension examined.

### 4.3 Option (iii) — revival opens a **new episode**; the episode carries the lifecycle value

> **⟦ARCHITECT ANALYSIS⟧**
>
> **What it means.** The Lead's lifecycle is not moved backward at all. The closed episode retains its
> terminal Dump, its preserved reason and its recorded facts **permanently and unaltered**. Revival
> **opens a successor episode on the same Lead**, and the new episode carries its own lifecycle value
> from the start. The Lead's "current state," where anything needs one, is the current episode's
> state.
>
> **Why this is the only option consistent with the direction.** It is the only one under which the
> historical record is literally never "deleted, reset, copied, or rewritten" — because nothing about
> the prior episode changes. The lifecycle axis stays **strictly monotone toward a terminal state
> within each episode**, so AD-01C's D1 objection is largely answered: terminality means what it says
> *for an episode*, and AD-01 §6.1's transition table needs no backward edge at all. The Lead gains a
> property it did not have — it can hold more than one terminal disposition over its life — but no
> single state machine gains an illegal edge.
>
> **Reporting consequences.**
> - **Funnel.** Must be re-keyed from lead to episode for *Converted* and for the
>   closed-without-conversion bucket, or D4's retroactive restatement returns. This is a change to
>   **AD-01 §9.1**, which is a **source-of-truth rule** and therefore §88 MUST-ASK. (**U-6**.)
> - **Capture denominator.** Whether a revived episode counts as a *Capture* in the period it opens is
>   not derivable. Counting it reproduces exactly the distortion AD-01C D4 identified for the successor
>   model (returning prospects convert better than cold ones, flattering the later period). **Not**
>   counting it produces a numerator with no denominator entry, which is worse. Either way,
>   reactivations must be separable. (**U-5**.)
> - **Velocity.** Episode-scoped and correct. Cross-episode elapsed time (true first contact → sale)
>   remains derivable on demand.
> - **Source quality (§9.1).** Each episode carries the source of its own engagement, so the
>   denominator decomposition Q7's framework was approved to enable survives intact.
> - **Terminality.** Preserved per episode; `is_terminal` remains meaningful at the level it is read.

> **⟦ARCHITECT ANALYSIS⟧ The entry value of a revived episode is itself undecided.** Beginning at
> *New* is defensible (it is a fresh engagement) and is not the forbidden *Anything → New* transition,
> because no lead-level backward edge occurs — but it would place the lead in the §14 Action Feed's
> "New leads" bucket alongside genuinely fresh captures, which is a product judgement with an
> operational cost. Beginning at *Follow-up* is also defensible and forces §13's mandatory next-action
> date immediately. **The spec does not choose.** (**U-5** covers the reporting half; the feed half is
> recorded with it.)

### 4.4 Consequences that hold under any option

> **⟦ARCHITECT ANALYSIS⟧**
> - **Reason historisation is mandatory, not optional.** AD-01A §8.3 forbids rewriting a preserved
>   reason. Any model in which a Lead can reach a terminal non-conversion disposition twice **must**
>   hold two reasons. Under option (iii) this falls out of the episode structure; under (i) it is a new
>   mechanism the option itself creates.
> - **The business-level state history (AD-01 §8.3) already survives R6's twelve-month hot window and
>   must record which episode each transition belongs to**, or the history becomes an
>   uninterpretable interleaving of two engagements.
> - **Revival is an auditable business event** under §54 and R6 — actor, time, target, authorization
>   context — and it is **not** the same event as a correction (§5.6).

### 4.5 Recommendation — Q5-B

> **⟦ARCHITECT RECOMMENDATION — Q5-B⟧** *(RECOMMENDED, SUBJECT TO THE PROJECT OWNER'S EXPLICIT WRITTEN
> APPROVAL — nothing here is approved or implementable)*
>
> **Adopt option (iii).** Revival opens a **new commercial episode on the same Lead**. The Lead's
> lifecycle value is **not** moved backward out of Dump; the closed episode keeps its terminal
> disposition and preserved reason permanently. AD-01 §6.1's *Dump → Follow-up* row stays **removed**
> from the legal ordinary transition set, and *Anything → New* stays forbidden.
>
> **Reject option (i)** — it rewrites the historical record the direction requires be inviolable, and
> conflicts with AD-01A §8.3. **Reject option (ii)** — it is already forbidden by AD-01 §6.1 and
> produces a lead that is simultaneously New and Worked.
>
> **This recommendation is conditional on the owner approving the episode as a first-class concept
> (§3.6), which is a canonical-entity and relationship change and therefore §88 MUST-ASK.** Without
> that approval, this recommendation does not stand and Q5-B has no safe answer.

---

## 5. Re-engagement vs. genuinely new opportunity — the central challenge

**The question this document was asked not to hide:** under what circumstances should BMexa revive
the existing lead, and under what circumstances should it create a new lead?

### 5.1 What is already settled and requires no decision

> **⟦ARCHITECT ANALYSIS⟧**
>
> | Situation | Answer | Authority |
> |---|---|---|
> | Same Person, **different Project** | **New Lead.** Always. | §06 (Lead = Person × Project × process); AD-01 **E-09**; AD-01C §2.1 |
> | Same Person, same Project, **after a Success** | **New Lead.** The prior lead's Success is untouched. | AD-01C §3.7 **S4 — approved.** Not reopened here. |
> | Same Person, same Project, **prior Dump was recorded in error** | **Not a re-engagement at all.** An audited correction. | AD-01C §3.4 **S3 — approved.** See §5.6. |
> | Repeated inquiry or repeated site visit inside an open lead | **Neither.** Activity records. | AD-01 §8.4, **E-05** |
>
> **The live question is exactly one case:** same Person, same Project, prior engagement **rightly**
> Dumped, prospect returns.

### 5.2 The decision cannot be derived

> **⟦BUSINESS DECISION REQUIRED — U-1 (restated as the central item)⟧**
>
> **For a same-Person, same-Project re-contact after a rightful Dump, the spec provides no rule, no
> threshold, and no discriminating concept. This document does not supply one.**
>
> Three independent confirmations that the silence is total, not an oversight in this reading:
> - **AD-01 §1.3** — "Re-engagement of a dumped lead: **Never addressed.** The spec neither permits
>   nor forbids it."
> - **AD-01C §5** — an independent Rule 1 register reached the same conclusion and additionally
>   recorded that "two sequential leads on the **same** Person × Project" is **not addressed**, and
>   that §07's blessing of multiple leads is general and illustrated by *different* contexts.
> - **This pass** — §09, §11, §13, §32, §39, §40, §41, §57 were re-read specifically for an
>   opportunity-boundary rule. None exists. §13 defines Dump as *"closed without needing follow-up"* —
>   a statement about follow-up necessity, not about whether the opportunity is over (AD-01 §2.5
>   already established exactly this).
>
> **Per Rule 1, §88 ("do not invent business rules") and §97, no formula is proposed to paper over
> this gap.**

### 5.3 What the owner is actually being asked

> **⟦ARCHITECT ANALYSIS⟧** The decision decomposes into four separable questions, and answering them
> separately is easier than answering U-1 as one thing. Each is recorded in §12.
>
> 1. **Is revival ever refused?** (**U-3**) — does the Dump's recoverability posture gate it? This is
>    the cheapest discriminator available, because AD-01A §8.3 already approved posture as a
>    **mandatory** dimension of every Dump reason. It needs only values (**N-4**), not a new concept.
> 2. **Does dormancy expire a lead?** (**U-4**) — is there an elapsed-time horizon past which
>    re-contact is a new opportunity? No threshold exists anywhere in the spec.
> 3. **Does a different commercial producer make it a new opportunity?** (**U-2**, coupled to AD-01C
>    **T-4**) — this is the question with money attached, and it cannot be deferred without leaving a
>    §32/§40 exposure open.
> 4. **Does a materially changed requirement make it a new opportunity?** — different configuration,
>    budget band or unit type. Recorded as part of **U-1**; the spec defines no requirement model
>    against which "materially changed" could be evaluated, so this may be undecidable in MVP and the
>    owner should be told so rather than asked to specify it.

### 5.4 The default in the absence of a decision, and why it is not a safe default

> **⟦ARCHITECT ANALYSIS⟧** If the owner approves "revive whenever the Person and Project match" and
> answers nothing else, the system acquires a **silently invented business rule** — that a re-contact
> is always the same opportunity regardless of source, elapsed time or prior posture. AD-01C §2.2 D6
> made exactly this criticism of reopening: its apparent advantage is that *it answers an unasked
> question by accident*, and the accident lands on CP commission. **That criticism survives the change
> of direction unchanged.** A rule created by a data-model default is still a rule, and §88 places it
> in the MUST-ASK column.

### 5.5 Recommendation — the discriminator

> **⟦ARCHITECT RECOMMENDATION — the revive-vs-new-lead rule⟧** *(RECOMMENDED, SUBJECT TO THE PROJECT
> OWNER'S EXPLICIT WRITTEN APPROVAL)*
>
> **Do not attempt to state the rule as a formula. State it as a small number of explicit owner
> answers, and make the system's behaviour legible when it applies them.** Specifically:
>
> 1. **Adopt revival as the default** for same Person × same Project after a rightful Dump, per the
>    direction — **and record it explicitly as a product decision, never as a data-model consequence.**
> 2. **Resolve U-2 / T-4 before, not after, approving revival**, because a different-CP re-contact is
>    the one case where the default silently decides a commission question.
> 3. **Treat recoverability posture (U-3) as the intended gate**, since AD-01A §8.3 already makes it
>    mandatory on every Dump — and note that its values (N-4) must land first.
> 4. **Do not adopt a dormancy horizon (U-4) unless the owner states one.** No threshold exists in the
>    spec, and inventing one would breach Rule 1.
>
> **Where this recommendation departs from the direction:** the direction says revival is "preferred."
> This recommendation holds that **a preference is not a rule**, and that shipping the preference
> without answering U-2/T-4 creates a financial exposure the direction does not address.

### 5.6 Interaction with Q6 — flagged, and deliberately not reopened

> **⟦ARCHITECT ANALYSIS⟧ A genuine tension exists with AD-01C §3.5, and the task requires it be
> surfaced rather than buried.**
>
> AD-01C §3.5 used Q6-S4 as an **independent cross-validation** of its Q5 answer: *"If Q5 were
> answered A (reopen), the product would carry two contradictory idioms — returning after a loss
> reopens the old record, but returning after a win creates a new one. There is no business principle
> that distinguishes those two cases in a way that justifies opposite mechanisms."*
>
> **The new direction creates exactly those two idioms.** So AD-01C's argument must be met, not
> ignored.
>
> **It is answerable, and the answer is a real principle:** *a Success **consumes** the opportunity; a
> Dump **abandons** it.* After a booking reaches §20 Stage 3 the unit is sold and that engagement is
> complete in the strongest possible sense — the Person is now a Customer **in that context** (§07,
> §06, AD-01 E-09), and any further interest is definitionally a second opportunity. After a Dump
> nothing was consumed; the engagement was abandoned and can be resumed. On that principle the two
> idioms are not arbitrary, and AD-01C's cross-validation argument is **weakened but not refuted** —
> it correctly demanded a distinguishing principle, and one exists.
>
> **But the principle is not stated anywhere in the spec.** It is a reading, and per Rule 1 the owner
> must affirm it rather than inherit it. (**U-19**.)
>
> **Q6 is NOT reopened.** Its three approved answers are unaffected by anything here: S1 (a valid
> Success stays Success permanently) is untouched; S2/S3 (an incorrectly recorded value is an
> authorized, reasoned, appended correction outside the ordinary transition machine) is untouched; S4
> (a genuinely new opportunity after a success creates a new Lead) is untouched — and §5.1 above
> treats it as settled. **No Q6 decision requires revision.**
>
> **One requirement revival does place on the approved Q6 correction mechanism**, recorded because it
> is new and would otherwise be discovered late: AD-01C §3.4 established that *"a correction is not a
> re-engagement, and a re-engagement is not a correction"* — a wrongly-Dumped lead is corrected (the
> Dump never happened as a business fact), while a rightly-Dumped lead whose prospect returns gets a
> new engagement (the Dump happened and remains true). Under the successor-lead model those were
> structurally different acts: *create a new record* versus *correct an existing one*. **Under revival
> both act on the same record and both cause work to resume on it**, so the boundary is no longer
> enforced by structure and must be enforced deliberately: two distinct operations, with different
> authorization, different audit events, and **opposite reporting effects** — a correction deliberately
> restates the prior period, and a revival must never restate it. If they are conflated, a revival can
> be laundered as a correction (erasing a true loss from a closed period) or a correction laundered as
> a revival (preserving a false loss). (**U-18**.)

---

## 6. Historical visibility architecture (Q5-C, Q5-E)

### 6.1 The two questions that must not be one question

> **⟦ARCHITECT ANALYSIS⟧ The direction's rejection of `original_handler_id = current_handler_id` is
> correct, and for a deeper reason than the Case-2 counterexample gives.**
>
> That predicate is not merely the wrong *pair of identifiers*; it is the wrong **kind of fact**. It
> answers *"is the person holding this lead the person who held it before?"* — a question about
> **custody**. The question actually being asked is *"is this viewer entitled to read what happened in
> a past engagement?"* — a question about **entitlement**. Custody is a present operational assignment
> that changes routinely; entitlement is a durable authorization property. Conflating them produces a
> rule that is wrong in both directions: it denies history to a legitimately entitled viewer who is not
> the current handler (every manager, and every past handler who has since handed the lead on), and it
> would grant history to whoever happens to hold the record next if the identifiers ever coincide by
> reassignment.
>
> > **"Who currently owns the lead" and "who is entitled to see historical episodes of the lead" are
> > different questions with different inputs and different answers. They are not two readings of one
> > field.**
>
> §10 has already drawn the adjacent distinction the product needs — **Lead Owner** (responsible for
> the relationship) versus **Lead Handler** (currently working it) — and required that "all meaningful
> handovers must be recorded." Entitlement is a **third** thing, and neither Owner nor Handler is it.

### 6.2 Why this is an authorization boundary, not a display rule

> **⟦ARCHITECT ANALYSIS⟧** §11 states the governing principle in the product's own words:
> *"The UI visibility rule must be enforced by authorization — not merely by hiding a badge."* §45
> states the corollary: *"Search must NEVER become a side door around authorization — a user who
> cannot access a booking directly must not discover it through search."* Spec **Rule 4** requires
> server-side enforcement, and §03 says *"Never solve permissions by simply hiding buttons in the
> frontend."*
>
> **Restricted historical visibility is therefore a security boundary in the same class as tenant
> isolation and clash-information restriction — not a presentation preference.** §8 treats it as such.

### 6.3 The conceptual model — entitlement derived from three independent inputs

> **⟦ARCHITECT RECOMMENDATION — Q5-C, conceptual model⟧** *(RECOMMENDED, SUBJECT TO THE PROJECT
> OWNER'S EXPLICIT WRITTEN APPROVAL. This is a conceptual authorization model, not an RBAC permission
> set — the permission vocabulary is **M-3**/**M-7** and is not proposed here.)*
>
> **Entitlement to a historical episode is evaluated per (viewer, lead, episode) — never per lead —
> and is granted by any one of three independent inputs. The default is closed.**
>
> | Input | What it is | Which case it serves |
> |---|---|---|
> | **I1 — Participation** | The viewer personally worked that episode: they were its Handler or Owner, or they are the recorded actor on its activities. A **historical fact**, already required to exist by §10 ("all meaningful handovers must be recorded"), §06 (Assignment Log is a canonical entity), and §57 ("preserve historical actor identity"). | **Case 1**, and **Case 2 as literally written** (the original handler is reassigned back — they participated). |
> | **I2 — Management breadth** | The viewer holds a grant whose record-visibility breadth covers the lead — §E.5 of the reconciliation report's *own / team / scope / all* attribute on the grant. Requires no new concept. | **Sales Head and authorized Reporting Managers**, unconditionally, per the direction. |
> | **I3 — Conferral** | An explicit, recorded act by an authorized principal grants an incoming handler access to prior episodes. | **Only** the *generalised* Case 2 — an explicit Sales Head assignment to someone who did **not** work the prior episode. |
>
> **Custody is not an input.** Being the current Handler grants nothing about prior episodes. A
> handler always sees the **current** episode in full — that is their work.
>
> **Fail closed.** A handler who holds the lead by automatic assignment, has no participation, no
> covering breadth and no conferral, sees the current episode only. This matches R1's fail-closed
> posture (an unset context matches zero rows, never everything) and §11's default-restrictive stance
> on sensitive lead facets.

> **⟦ARCHITECT ANALYSIS — why each input, and why not the alternatives the task asked me to weigh⟧**
>
> - **Keying on the current handler** — rejected, §6.1. Wrong kind of fact.
> - **Keying on prior-handler relationship alone (I1 only)** — **sufficient for all three PO cases as
>   literally written**, and this is a significant finding (see §7). It fails only the generalised
>   Case 2.
> - **Keying on assignment history** — assignment history is the *carrier* of I1 and the potential
>   carrier of I3; it is not itself a rule. Listing it as a key confuses a record with a policy.
> - **Keying on assignment method (automatic vs. explicit) alone** — insufficient: it says nothing
>   about managers (I2) and nothing about a handler who worked the prior episode and simply still
>   holds the lead (I1, no reassignment at all).
> - **Keying on the explicit Sales Head reassignment action** — this is I3, and it is necessary only
>   under the generalised reading (**U-7**).
> - **A combination** — yes; the recommendation is the **union** of three independent grants, which is
>   consistent with R2's union-without-deny-rows semantics for effective permissions.
> - **Another mechanism entirely** — one was considered and is recorded in §10 (Alt-6): making
>   conferral the *only* input. Rejected: it fails Case 1 without an additional administrative act on
>   every revival, which is friction the direction does not ask for.

> **⟦ARCHITECT ANALYSIS — the I1 rationale, stated because it is not obvious⟧** Why should a past
> handler retain entitlement after the lead moves on? Because **they already saw it**, and because
> §57 requires historical actor identity to be preserved rather than erased. Denying a person access
> to work they personally performed does not protect information that has already reached them; it
> makes their own accountability unauditable to themselves and produces a system in which a rep cannot
> see what they are being measured on. **The restriction the direction asks for is about a handler who
> was never there — not about un-showing what was already shown.**

### 6.4 The gap in Case 2, and why it is the decisive unresolved question

> **⟦BUSINESS DECISION REQUIRED — U-7⟧** **Does an explicit Sales Head assignment confer historical
> visibility on a handler who did NOT work the prior episode?**
>
> The direction's Case 2 says: *"Sales Head explicitly reassigns it **back to the original handler**:
> handler sees previous history."* That handler is entitled by **I1 (participation)** alone. **The
> direction's own three cases are therefore fully satisfied by I1 + I2, with no conferral mechanism and
> no assignment provenance at all.**
>
> The generalised claim — that explicitness *itself* confers, so a Sales Head may deliberately place a
> third person on the lead knowing they will see the history — is a coherent and probably intended
> reading, and it is the reading that makes assignment *method* load-bearing. **But it is not what the
> direction states, and it cannot be inferred: "the Sales Head reassigned it back to the person who
> already knew" and "the Sales Head conferred knowledge on someone new" are different acts with
> different security consequences.**
>
> **This is the single highest-leverage unresolved item in this document.** Its answer determines
> whether Q5-D's answer is "necessary" or "not necessary" (§7), and whether the visibility model needs
> one new concept or none.

### 6.5 Management entitlement — what the direction leaves open

> **⟦BUSINESS DECISION REQUIRED — U-9⟧** **Is management entitlement evaluated against the viewer's
> grant *now*, or their grant *at the time of the episode*?** A Sales Head who has since moved to
> another project; a newly appointed Sales Head asked about an engagement that predates them; a
> Reporting Manager whose team composition changed. §08 requires scoped access and §57 requires that
> role changes not destroy historical ownership information, but **neither states which point in time
> an authorization decision reads.** Both answers are defensible and they differ materially.

> **⟦BUSINESS DECISION REQUIRED — U-10⟧** **Which principals are "authorized Reporting Managers"?**
> §03 names Super Admin, Builder Admin, CEO/Promoter, VP/Sales leadership, Sales Head, Project
> Head/Site Head, Sales Rep, Helpdesk, Sales Support, Accounts and Customer Support. **"Reporting
> Manager" is not among them**, and **M-7** (is "team" a real concept; does a Sales Head see their
> team's leads across projects or their project's leads across teams?) and **M-3** (the default role
> set) are both unresolved. Per **R2** no logic may branch on a role name, so this must resolve into
> breadth on a grant, not into a named role.

### 6.6 Q5-E — what "previous history" means

> **⟦ARCHITECT ANALYSIS⟧** "Previous history" is the set of facts **associated with a closed episode**
> (§3.2's boundary: an episode is bounded by a terminal disposition). Categories, with what the spec
> already settles and what it does not:

| # | Category | Status |
|---|---|---|
| **H1** | Previous calls and call outcomes (§49's Not Connected / No Answer / Connected) | **Architect's to scope, not to decide:** episode-associated activity. Restrictable. |
| **H2** | Previous WhatsApp / email activities (§72) | Same as H1. Note §72 requires integrations never compromise core CRM integrity — the restriction must not depend on an external provider's behaviour. |
| **H3** | Previous site visits (§09, §80) | Same as H1. |
| **H4** | Previous notes | Same as H1, with the highest free-text leakage risk (§6.8). |
| **H5** | **Old attribution / clash information (§11)** | **Not a Q5 question.** §11 **already** restricts competing claims from Sales Reps *in the current episode too* — "Sales Reps should not automatically see sensitive clash information that could influence or manipulate attribution." Revival changes nothing here. **No new decision required**; the existing §11 rule applies per episode. |
| **H6** | Old assignment history (§06 Assignment Log, §10, §57) | **Restrictable from a handler; must remain intact and fully visible to management.** §57 forbids rewriting history "as if the employee never existed" — restricting a *reader* is not rewriting. |
| **H7** | **Old Dump reason (AD-01A §8.3)** | **⟦BUSINESS DECISION REQUIRED — U-12⟧.** Genuinely two-sided: knowing the lead was previously closed as "not a genuine prospect" materially changes how a handler works it (an execution benefit, §14/§95), while disclosing it reveals the prior episode's commercial assessment of the prospect. **Not the architect's to choose.** |
| **H8** | **Old commercial information** — budget discussed, configuration, quotes, negotiation position | **⟦BUSINESS DECISION REQUIRED — U-12⟧.** The most commercially sensitive and the most operationally useful category simultaneously. Note §21/§22 already make *booking* commercials immutable and snapshot-bound; pre-booking discussion has no such treatment. |
| **H9** | **Previous booking-related information** | **Two different things, and they must be separated.** (a) A prior episode that reached Success has its own **Booking**, which has its own lifecycle (AD-01A §8.2) and its own authorization — it is **not** lead history and is out of scope here; but note that a prior *Success* episode means §5.1's Q6-S4 rule applies and the case is a new Lead anyway. (b) A prior **Dumped** episode may still carry an abandoned booking *attempt* (§20 Stage 1/2) or an expired inventory hold (§16). Whether those are lead history is **⟦BUSINESS DECISION REQUIRED — U-12⟧**. |
| **H10** | **The *existence* of a prior episode** | **⟦BUSINESS DECISION REQUIRED — U-11⟧.** See below. |
| **H11** | **Derived and aggregate facts** — lead age, activity counts, "last contacted", engagement-depth derivations (AD-01A §3.6), episode count | **Must be in scope of the boundary, and this is easy to miss.** Restricting content while leaking "created 14 months ago · 27 activities" is precisely the *"hiding a badge"* failure §11 forbids. See §6.8. |
| **H12** | Person-level history on other projects | **Out of scope.** Governed by §06/E-09 and by ordinary record visibility; revival does not change it. Recorded so a Person-centric screen is not assumed safe by default. |

> **⟦ARCHITECT RECOMMENDATION — H10 / U-11, offered as a default for the owner to accept or reject⟧**
> **Disclose the *existence* of a prior closed episode to a restricted handler; withhold its
> contents.** A prior episode that is entirely invisible creates operational hazards the direction does
> not intend: duplicate outreach to a prospect who previously asked not to be contacted; a handler
> unable to explain why §09/§11 flagged the record; and a handler who cannot know to escalate. A
> visible-but-locked episode also makes the boundary honest rather than deceptive, which matters under
> §62 ("if an action is unavailable, explain why"). **This is a recommendation, not a decision — the
> owner may reasonably prefer total invisibility, and that preference has its own coherent logic.**

### 6.7 Duration of the restriction

> **⟦BUSINESS DECISION REQUIRED — U-13⟧** **Does a restricted handler's restriction persist for the
> life of the lead, expire, or end on an event?** Plausible triggers exist (the prospect substantively
> re-engages; the new episode reaches a milestone; the Sales Head later confers). The spec addresses
> none of them. A permanent restriction is the simplest and is the assumption §8 is written against.

> **⟦BUSINESS DECISION REQUIRED — U-14⟧** **Does a past handler's participation entitlement (I1)
> survive their reassignment away, role change, or move to another project?** §57 preserves historical
> *actor identity*; it says nothing about a departed or reassigned handler's continuing **read**
> entitlement. §08 requires role changes not to destroy historical ownership information — which is
> about the record, not about access.

### 6.8 The inference channel, stated separately because it is the most likely failure

> **⟦ARCHITECT ANALYSIS⟧** A boundary that hides records but exposes their shadow is not a boundary.
> Under revival the restricted content sits inside a record the viewer holds, so **every aggregate the
> product already computes over a lead is a potential inference channel**: total activity count, first
> contact date, lead age, "last touched", engagement depth, the number of prior handlers, the presence
> of attachments, the lead's position in any list ordered by a history-derived value.
>
> This is the direct application of §11's own sentence to the case the direction creates: authorization
> must govern the **derived** facts as well as the stored ones, or the restriction is decorative.
> Under AD-01C's successor-lead model this channel largely does not exist, because the aggregates are
> computed over a record the viewer cannot read at all. **This is the clearest single illustration of
> §2.3's asymmetry.**

---

## 7. Assignment provenance implications (Q5-D)

**The question:** must assignment provenance — *how* a handler came to hold the lead, automatic rule
versus explicit Sales Head action — be preserved as a first-class business fact for §6's visibility
model to work? **Necessity only; no mechanism is proposed.**

### 7.1 The conditional answer

> **⟦ARCHITECT ANALYSIS⟧ Necessity is entirely determined by U-7, and this is the honest answer rather
> than a hedge.**
>
> - **If Case 2 is read literally** (a Sales Head reassigns *back to the original handler*):
>   **provenance is NOT architecturally necessary.** That handler is entitled by **I1 —
>   participation** — a fact the product must record anyway under §10 ("all meaningful handovers must
>   be recorded"), §06 (Assignment Log as a canonical entity) and §57. **I1 + I2 satisfy all three of
>   the direction's cases with no new concept.** Introducing provenance to serve this reading would be
>   inventing a requirement the stated cases do not generate — precisely what Rule 1 forbids.
> - **If Case 2 is read generally** (an explicit Sales Head assignment confers history on someone who
>   never worked the prior episode): **provenance is architecturally necessary and unavoidable.** The
>   entitlement is then a function of *how* the assignment was made, and nothing else in the model
>   carries that fact. No amount of participation data, breadth data or lead data can reconstruct it
>   after the fact — **and, like AD-01C's successor reference, it cannot be backfilled.** An assignment
>   whose method was never recorded is indistinguishable later from one that was automatic.
>
> **The rework asymmetry is therefore the same one AD-01B §4 used to prioritise Q5 in the first
> place: cheap before history accumulates, unrecoverable after.** That asymmetry is a reason to answer
> U-7 early, not a reason to assume its answer.

### 7.2 How much of provenance already exists

> **⟦ARCHITECT ANALYSIS⟧** The Assignment Log is already a canonical entity under §06 and already
> records, per AD-01 §8.4, *"who, to whom, when, why, by whose authority"* and *"records
> system-initiated changes too (§57 departures)."* So a **system-actor versus human-actor**
> distinction is plausibly already derivable.
>
> **But that is probably the wrong granularity for the generalised Case 2.** The direction contrasts
> *automatic reassignment* with *an explicit Sales Head act*. A bulk reassignment performed by Sales
> Support after a departure (§57), a helpdesk summon (§42), and a deliberate Sales Head placement are
> all human-actor events with very different intents. **Whether the distinction the direction needs is
> "system vs. human", "routine vs. deliberate", or "by a principal holding a specific authority" is
> not stated.** (**U-8**.)

### 7.3 The two shapes conferral could take, and their costs

> **⟦ARCHITECT ANALYSIS⟧**
>
> **(a) Conferral derived from assignment provenance.** Entitlement is computed from the recorded
> method and actor of the assignment. No new user-facing act. **Cost:** it couples an authorization
> outcome to an operational act, so a Sales Head performing a routine manual reassignment **silently
> confers historical access they may not have intended**. An authorization grant that nobody
> consciously made is the failure mode §88 and Spec Rule 4 are written against.
>
> **(b) Conferral as an explicit, separate grant.** The Sales Head deliberately grants history access,
> distinct from the assignment. **Cost:** friction, and a real risk of drifting into exactly the
> reassignment-approval workflow **AD-01A §8.5 forbids inventing** ("Do not invent a
> reassignment-approval workflow"). It is also a second act at a moment §14/§95 want to be fast.
>
> **Neither is obviously right, and the choice is an authorization-rule change — §88 MUST-ASK.**
> (**U-8**.)

### 7.4 Recommendation — Q5-D

> **⟦ARCHITECT RECOMMENDATION — Q5-D⟧** *(RECOMMENDED, SUBJECT TO THE PROJECT OWNER'S EXPLICIT WRITTEN
> APPROVAL)*
>
> 1. **Answer U-7 first.** It is cheap now and unrecoverable later, and it is the only thing that
>    determines whether provenance is necessary.
> 2. **If U-7 is answered "yes" (the generalised reading): preserve assignment provenance as a
>    first-class business fact on the assignment record** — an attribute of the Assignment Log entry,
>    **not** a new axis on the Lead. This is explicitly **not** a reintroduction of the persisted
>    Assignment State axis that AD-01A §8.5 eliminated; that decision stands untouched, and §8.5 itself
>    directs that "Owner, Handler, Assignment History … should carry this information."
> 3. **Under R4, any provenance vocabulary is tenant-scoped master rows with a system-owned semantic
>    column, never an enum and never a code branched on in logic (R2, R4). No values are proposed
>    here** (Rule 1).
> 4. **Record provenance regardless of U-7's answer if it is cheap to do so** — §54 already wants
>    actor, action, authorization context on meaningful business actions, and §57 already wants
>    "appropriate assignment history." **But do not let that recording be mistaken for an approved
>    authorization rule:** a fact recorded is not a grant conferred, and nothing may read provenance as
>    an entitlement until U-7 and U-8 are answered.

---

## 8. Security implications (Q5-F)

> **⟦ARCHITECT ANALYSIS⟧ The governing shift, stated once and applied throughout this section.**
> Every authorization mechanism the product currently plans is **record-level**: tenant isolation via
> R1/RLS, project scope via §08, record-visibility breadth on the grant (§E.5, pending **M-7**).
> Restricted historical visibility under revival is the product's **first intra-record authorization
> boundary** — a boundary inside a record the user legitimately holds. Two consequences follow
> immediately: (1) "may this user read this lead?" **stops being the whole question**, and every
> lead-reading path must additionally answer "which episodes?"; (2) the standard safety net —
> *if the row is not returned, nothing leaks* — **no longer applies**, because the row is returned.
> §11's clash-information restriction is the only comparable existing case, and §E.5 of the
> reconciliation report already concluded it "needs a dedicated capability plus enforcement at the
> data-access layer so the field never leaves the server for an unauthorized caller."

| Surface | Architectural consequence (no implementation) | Spec authority |
|---|---|---|
| **API** | Record-level authorization no longer suffices. Every lead read — detail, list, nested child collections, aggregates, and any endpoint that returns activities, notes, attachments, assignment entries or dispositions — must project an **episode-scoped** subset server-side. The single most dangerous shape is an endpoint that authorizes the lead once and then returns its children unfiltered. | §04, §69, Rule 4, §E.5 |
| **UI** | Presentation only. A collapsed section, a greyed panel or an absent tab is **not** the control. | §11 ("not merely hiding a badge"), §03, §62 |
| **Exports (§52)** | Export scope must be episode-filtered, the export **request and approval must state which episodes are in scope**, and the resulting file must be audited against that scope. An "export my leads" path that emits full history is a silent breach that leaves the building. | §52, §51 |
| **Search (§45)** | The hardest surface. Indexed free-text from a restricted episode (notes, call summaries) can be retrieved by a query even when the record is never rendered — the exact "side door around authorization" §45 forbids. Search must be **episode-aware**, not merely lead-aware, and result snippets are themselves a leak. | §45, §91 |
| **Reports and analytics (§63)** | Any rep-facing figure computed over the whole lead leaks by inference (§6.8). Rep-facing reports must be episode-scoped; management reports full. Two report populations over one record, keyed on entitlement. | §63, §9.1–§9.7 |
| **Background jobs** | Jobs run without an interactive user context. Under the reconciliation report's recommended Option 2 (RLS extended with a per-request user context), a job either carries a context or runs privileged — and **Spec Rule 5 forbids privileged access as an ordinary shortcut**. Any job that computes over lead history and emits something a restricted handler will read must apply the same projection. | §04, Rule 5, §73 |
| **Notifications (§58)** | A reminder, escalation or digest that references a prior-episode commitment, actor or fact leaks through a channel that leaves the application entirely (push, email, WhatsApp). Notification payloads need the same projection as API responses, and §58's grouping/digest patterns make accidental aggregation easy. | §58, §72 |
| **Attachments / documents (§71)** | Documents uploaded during a restricted episode are protected assets. Access checks must key on the **episode**, not the lead, and §71 already forbids permanent public URLs for sensitive documents — a signed URL minted under lead-level authorization would bypass the episode boundary entirely. | §71, §91 |
| **Audit log (§54, R6)** | The audit log necessarily contains the restricted episode's events, and AD-01 §8.3 records that it "is a security artefact with its own access rules." **Audit access must not become the side door.** Two further points: **R6 forbids deletion**, which is consistent with — and the enforcement of — the direction's intactness requirement; and **the conferral or restriction of historical visibility is itself an auditable authorization event** (§54: actor, action, time, target, authorization context). | §54, R6, §45 |
| **Offline / PWA (§46, §47)** | A device caching a revived lead must not cache restricted-episode content. §46 already directs that offline data be minimised and sensitive data not stored locally without a clear security design. A cache populated before a restriction takes effect is a real scenario. | §46, §47, §12 |
| **CP portal (§39, §05)** | External principals make the same boundary question sharper: a CP must see pipeline status for **their own** episode, never the lead's other engagements, and never competing claims (§11). §05 forbids unrestricted builder-tenant access for an empanelled CP. | §39, §05, §11, §41 |
| **Consistency (§68)** | Conferral and restriction are **authorization-sensitive mutations**, which §68 names among its strong-consistency cases. A window in which a handler holds the lead while their entitlement is still settling is a real exposure. | §68, §61 |

> **⟦ARCHITECT ANALYSIS — the cost the owner is accepting⟧** Under AD-01C's successor-lead model,
> **nine of the twelve rows above require no new work**: the prior episode is a separate record, and
> every listed surface already has to answer "may this user read this record?" for other reasons.
> Under revival, each becomes an independent opportunity for a **silent** authorization widening — the
> failure class §45 and §52 are explicitly written to prevent, and the class the reconciliation report
> §L.3 calls "the change most likely to introduce a silent authorization widening."
>
> **This is not an argument that the direction is wrong.** It is the price of the direction, it is
> payable, and the owner should approve it knowing the figure. **§96's definition of done and §91's
> critical test areas both apply**: a revival feature is not complete until automated tests prove a
> restricted handler cannot reach prior-episode content through the API, search, export, reports or
> attachments.

---

## 9. Reporting and analytics implications

> **⟦ARCHITECT ANALYSIS⟧** Revival changes the unit that reports key on. Each item below is a
> consequence, not a decision; the decisions are in §12.

1. **The funnel's key must move from Lead to Episode.** AD-01 §9.1 defines *Converted* as "leads whose
   **current** state has the converted semantic type." Under revival that definition retroactively
   restates closed periods (§4.1). Re-keying *Converted* and the closed-without-conversion bucket to
   the **episode** stabilises every past period. **This is a change to a source-of-truth rule and is
   §88 MUST-ASK.** (**U-6**.)
2. **The *Captured* denominator needs an explicit rule.** Whether a revived episode is a capture
   determines whether conversion rates are flattered, deflated, or honest. Either answer is workable;
   no answer is not. Reactivations must be separable either way — the same condition AD-01C §2.5 made
   non-optional for the successor model applies unchanged here. (**U-5**.)
3. **Velocity metrics become episode-scoped, and the lead's age stops being a sales cycle.** AD-01 §9.2's
   *days New → first Follow-up* is meaningful per episode and meaningless across the lead. Reports must
   be explicit about which they show, or leadership will read dormancy as slowness.
4. **Source-quality reporting survives** — each episode carries the source of its own engagement, so
   the denominator decomposition that AD-01 §9.1 says Q7's framework exists to enable is preserved.
   Under naive revival (option (i)) it is not: the second source would be unrecordable.
5. **Reactivation reporting is available and richer than under the successor model** — an episode count
   greater than one, with each episode's own outcome. §63's test ("what decision or action does this
   enable") is met by a returning-prospect queue with an obvious action.
6. **Two report populations now exist over one record.** Rep-facing figures must be episode-scoped to
   avoid §6.8's inference channel; management figures are full-history. This is a reporting *and* an
   authorization requirement, and it is the surface where the two are most easily forgotten together.
7. **CP-facing reporting (§39) must be episode-scoped**, or a CP sees engagements they had no part in.
   (**U-16**.)
8. **Nothing here authorises remarketing, nurture, drip or outbound re-engagement campaigns.** AD-01
   §1.3 records that re-engagement is never addressed by the spec; AD-01A §3.5 and AD-01C §2.2 D11 both
   made the same reservation; **§65 and §86 remain in force.** Deciding what the system does when a
   prospect returns does **not** authorise going out to get them.
9. **No weighted forecast, no temperature, no reason-coded loss analysis** is enabled by anything here
   (AD-01 §9.6, §1.3, M-8). Unchanged.

---

## 10. Alternatives considered

> **⟦ARCHITECT ANALYSIS⟧** Six were examined. Each is stated at its strongest before it is judged.

**Alt-1 — Strict AD-01C Alternative B: new successor Lead, mandatory typed reference.**
*Strengths:* delivers the direction's Case 3 visibility **for free** via existing record-level
authorization (§2.3); serves the cross-project case with the same idiom; keeps terminality absolute;
no intra-record boundary anywhere.
*Weaknesses:* loses on D10 (successor is a duplicate candidate by construction) and decisively on D12
(reconstructibility depends on a reference that cannot be backfilled); and it does not deliver the
continuity the direction asks for.
*Judgement:* **superseded by the product-owner direction, and retained here as the comparison
baseline.** Its security advantage is real and is the reason §11's recommendation is conditional.

**Alt-2 — Naive revival: `Dump → Follow-up` on the same record, no episode structure.**
*Strengths:* the simplest possible reading of the direction; one row added to AD-01 §6.1; immediately
intelligible to users.
*Weaknesses:* **violates the direction's own intactness requirement** (rewrites the lifecycle value,
overwrites or strands the preserved Dump reason — AD-01A §8.3); reproduces AD-01C's D4, D5, D6, D8, D9
defects intact; and makes Q5-C literally unanswerable because "the previous episode" has no boundary.
*Judgement:* **Reject.** It fails on the direction's own terms before any architect objection is
reached.

**Alt-3 — Revival with the commercial episode as a first-class bounded unit inside the Lead.**
*Strengths:* satisfies the direction fully; preserves §06's *process* component; answers seven of
AD-01C's twelve dimensions; keeps D10's and D12's advantages; re-arms Dimension C as a gate.
*Weaknesses:* introduces a canonical entity/relationship (§88 MUST-ASK); creates the intra-record
authorization boundary and all of §8's cost; and requires the funnel to be re-keyed (§9.1).
*Judgement:* **the recommended shape, conditionally** — see §11.

**Alt-4 — Successor Lead (Alt-1) plus a continuity presentation over the Person.**
Records stay separate; the *user experience* presents one continuous relationship, and reporting keys
on the individual leads.
*Strengths:* delivers much of what the direction appears to want — "one continuous historical record"
as the user perceives it — at **a fraction of the security cost**, because every restriction remains
record-level. It is the cheapest way to satisfy Case 3 while giving Case 1 continuity.
*Weaknesses:* it does **not** deliver what the direction literally states ("the existing Lead record
and its history remain the same Lead"); it retains Alt-1's D10 duplicate-candidate problem and its
unbackfillable-reference exposure; and a presentation-layer continuity that is not an authorization
boundary can itself leak (a continuity view is a read path like any other).
*Judgement:* **Not recommended, but it should be put to the owner**, because if the underlying
requirement is *"a handler who returns to a prospect should see one story"* rather than *"the database
row must be the same row,"* this satisfies the requirement at materially lower risk. **Determining
which of those the owner actually means is itself a question worth asking.**

**Alt-5 — Revival gated by Dump recoverability posture (AD-01A Dimension C).**
Not a standalone alternative: a refinement applicable to Alt-3 and a partial answer to U-1. Permanent
closures do not revive; revisitable ones do.
*Judgement:* **recommended as a component of Alt-3** (§5.5), and blocked on **N-4** for values
(**U-3**).

**Alt-6 — Visibility by conferral only (I3 alone, no participation input).**
*Strengths:* one rule, maximally explicit, no derived entitlement, easiest to audit.
*Weaknesses:* fails Case 1 — the original handler who simply still holds the lead would need an
administrative act to see work they personally did; it makes every revival a two-step operation
against §14/§95; and it risks becoming the reassignment-approval workflow AD-01A §8.5 forbids.
*Judgement:* **Reject.**

---

## 11. Architect recommendation

> **⟦ARCHITECT RECOMMENDATION — Q5, consolidated⟧** *(RECOMMENDED, SUBJECT TO THE PROJECT OWNER'S
> EXPLICIT WRITTEN APPROVAL. **NOT APPROVED. NOT APPROVED FOR IMPLEMENTATION.** Nothing below is
> decided, and no part of it may be built, seeded, migrated to, scaffolded or prototyped.)*

**R1 — Revival is architecturally sound, conditionally.** Adopt revival of the existing Lead on
re-engagement after a rightful Dump, **scoped to same Person × same Project**. Cross-project
re-engagement remains a new Lead under §06 and AD-01 E-09 — that is existing settled model, not a
choice being made here.

**R2 — The condition is not negotiable: the commercial episode must become a first-class bounded unit
within the Lead.** It must carry its own lifecycle value, source, terminal disposition, preserved
reason, attribution claim set, handler association and activity association. **Without it, revival
violates the direction's own intactness requirement and reproduces the defects AD-01C identified.**
This is a canonical-entity and relationship change and is **§88 MUST-ASK** — it is being asked here,
not assumed.

**R3 — Revival lifecycle: option (iii).** The Lead's lifecycle value is never moved backward out of
Dump. Revival **opens a successor episode**, which carries its own lifecycle value. AD-01 §6.1's
*Dump → Follow-up* row stays removed; *Anything → New* stays forbidden. The closed episode's terminal
disposition and preserved reason are permanent and unaltered.

**R4 — Historical visibility keys on entitlement, never on custody.** Adopt the three-input union of
§6.3 — **I1 participation**, **I2 management breadth**, **I3 conferral** — evaluated per (viewer,
lead, episode), **fail-closed**, with the current handler always seeing the current episode in full.
Custody is not an input. This is an **authorization-rule change** and is §88 MUST-ASK.

**R5 — Assignment provenance is necessary if and only if U-7 is answered "yes."** Answer U-7 first; it
is cheap now and unrecoverable later. If yes, provenance is an attribute of the **Assignment Log**
entry — **not** a reintroduction of the persisted assignment axis AD-01A §8.5 eliminated, which stands
untouched.

**R6 — Attribution and commission must key on the episode.** This is the one condition with money
attached. **M-5**'s open question ("does the claim attach to the Lead or the Person?") acquires a third
candidate — **Episode** — and must be answered before revival ships, or AD-01C's D6 failure is live:
a genuine §11 clash indistinguishable from two CPs legitimately claiming two engagements, feeding
§32/§40 commission. **U-15**, coupled to AD-01C **T-4**.

**R7 — Treat restricted historical visibility as a first-class security boundary and test it as one.**
§91's critical test areas and §96's definition of done both apply: a revival feature is not complete
until automated tests prove a restricted handler cannot reach prior-episode content through the API,
search, export, reports, notifications or attachments — including through derived aggregates (§6.8).

**R8 — Put Alt-4 to the owner explicitly.** If the underlying requirement is *"a returning handler
should see one continuous story"* rather than *"the record must literally be the same record,"* Alt-4
satisfies it at materially lower security cost. **Establishing which the owner means costs one
question and could avoid the whole intra-record boundary.**

### 11.1 Relationship to the product-owner direction, stated plainly

> **⟦PRODUCT-OWNER DIRECTION⟧** The direction under evaluation, restated for this comparison: *revive
> the existing Lead; the record and its history remain the same Lead; historical visibility depends on
> how the revived lead is assigned; the historical record is never deleted, reset, copied or
> rewritten; `original_handler_id = current_handler_id` is insufficient.*

> **⟦ARCHITECT ANALYSIS⟧** **This is agreement in direction, with three material additions and one
> open challenge — and it is not ratification.**
>
> - **Agreement.** Revival is sound; the historical record must be inviolable; visibility must not key
>   on custody; the rejection of `original_handler_id = current_handler_id` is correct and for a deeper
>   reason than the Case-2 counterexample supplies (§6.1).
> - **Addition 1 — the episode.** The direction does not mention it; the analysis finds it **forced**
>   by the direction's own two requirements held together (§3.3). The owner is being asked to approve a
>   canonical-entity change they did not propose.
> - **Addition 2 — the scoping.** The direction reads as universal; it can only be scoped to same
>   Person × same Project (§3.1).
> - **Addition 3 — the conditions.** Episode-scoped attribution (R6) and the funnel re-key (R2/§9.1)
>   are not optional refinements; without them the direction ships a commission defect and a reporting
>   defect respectively.
> - **Open challenge — U-7.** The direction's three cases are fully satisfied by participation and
>   management breadth alone, with **no conferral mechanism and no assignment provenance**. The
>   generalised Case 2 that would require them is a reading, not a statement. **This document does not
>   resolve it, and explicitly declines to treat the task framing as the owner's decision.**
>
> **A product-owner preference is not an approved architecture, and agreement is not ratification.**
> The grounds above are stated so they can be attacked on their merits.

---

## 12. Explicit unresolved business decisions

**Every ⟦BUSINESS DECISION REQUIRED⟧ raised above, consolidated. None is answered here. Per Rule 1,
§88 and §97, none is guessed.** Numbered **U-n** to avoid collision with the existing Q / N / M / E /
D / X / T namespaces.

| # | Decision required — stated precisely | Arises from | Spec status | Consequence if left open |
|---|---|---|---|---|
| **U-1** | For a same-Person, same-Project re-contact after a **rightful** Dump, what business condition distinguishes genuine re-engagement of the closed opportunity from a genuinely new opportunity requiring a new Lead? | §3.5, §5.2 | **Never addressed** (AD-01 §1.3; AD-01C §5) | A rule is created by the data-model default — an invented business rule under §88. |
| **U-2** | Does a re-contact arriving through a **different CP or source** than the closed episode constitute a new opportunity? | §3.5, §5.3 | **Silent** (§11, §32, §40, §41); coupled to AD-01C **T-4** | Direct §32/§40 commission exposure. Answer with T-4 in one sitting. |
| **U-3** | Does the Dump's **recoverability posture** (AD-01A §8.3 Dimension C) gate revival, and with which values? | §3.5, §5.3, §10 Alt-5 | Dimensions approved; **values are N-4, open** | The one cheap discriminator available goes unused; posture stays a reporting input only. |
| **U-4** | Is there a **dormancy horizon** past which re-contact is a new opportunity rather than a revival? | §3.5, §5.3 | **No threshold anywhere** (AD-01 §1.3; §58 sets no numbers) | Either an invented number, or none — the owner should choose which. |
| **U-5** | Does a revived episode count as a **Capture** in the period it opens, and does it enter the §14 "New leads" feed? | §4.3, §9.2 | **Silent** | Conversion-rate denominators are flattered or deflated with no stated intent. |
| **U-6** | Does the conversion funnel move from **lead-keyed to episode-keyed** for *Converted* and the closed-without-conversion bucket? | §4.3, §9.1 | Changes **AD-01 §9.1** — a **source-of-truth rule**, §88 MUST-ASK | Closed periods retroactively restate (AD-01C D4). |
| **U-7** | **Does an explicit Sales Head assignment confer historical visibility on a handler who did NOT work the prior episode?** (The direction's Case 2 literally covers only reassignment *back to the original handler*.) | §6.4, §7.1 | **Not stated by the direction; not in the spec** | Determines whether assignment provenance is necessary at all. **Unrecoverable if answered late** — provenance cannot be backfilled. |
| **U-8** | If conferral exists, is it **derived from assignment provenance** or an **explicit separate grant** — and at what granularity (system vs. human actor; routine vs. deliberate; by a principal holding a specific authority)? | §7.2, §7.3 | **Silent**; AD-01A §8.5 forbids inventing a reassignment-approval workflow | Either silent unintended grants, or friction that drifts into a forbidden workflow. |
| **U-9** | Is management entitlement evaluated against the viewer's grant **now** or their grant **at the time of the episode**? | §6.5 | **Silent** (§08, §57 address the record, not the read) | Newly-appointed and since-moved managers get inconsistent access with no stated rule. |
| **U-10** | Which principals are **"authorized Reporting Managers"**? | §6.5 | "Reporting Manager" is **not** among §03's roles; **M-7** and **M-3** open | Cannot be expressed; **R2** forbids branching on a role name. |
| **U-11** | Is the **existence** of a prior closed episode disclosed to a restricted handler, or is the episode wholly invisible? | §6.6 H10 | **Silent** | Either an operational hazard (duplicate outreach, unexplainable flags) or an information leak — the owner must pick. |
| **U-12** | Which **content categories** are withheld from a restricted handler: old Dump reason (H7); old commercial information — budget, configuration, quotes, negotiation position (H8); prior booking-attempt and inventory-hold information (H9b)? | §6.6 | **Silent**; each is genuinely two-sided | Architect would otherwise be choosing a commercial-disclosure policy. |
| **U-13** | Does a restricted handler's restriction **persist for the life of the lead, expire, or end on an event**? | §6.7 | **Silent** | An unstated lifetime is an unstated authorization rule. |
| **U-14** | Does a past handler's **participation entitlement survive** their reassignment away, role change, or move to another project? | §6.7 | **Silent** (§57 preserves actor identity, not read access) | Departed and moved staff retain or lose access with no stated basis. |
| **U-15** | Do **attribution claims and commission entitlement key on the Episode** rather than the Lead — i.e. does **M-5**'s "Lead or Person" question acquire a third candidate? | §2.2 D6, §3.4, §11 R6 | **M-5 open**; §11/§32/§40 silent on episodes | **The live financial defect.** A genuine §11 clash becomes indistinguishable from two legitimate episode claims. |
| **U-16** | Does **CP-facing visibility (§39)** show a CP only their **own** episode of a revived lead? | §8, §9.7 | §39 permits pipeline visibility; **silent on episodes**; §05 restricts CP access | An external principal sees engagements they had no part in. |
| **U-17** | May a lead be revived while the prior episode's **attribution is under an unresolved §11 clash**? | §8, §5.3 | **Silent** | Revival could pre-empt an adjudication §11 reserves to authorized leadership. |
| **U-18** | How is **revival distinguished, in authorization and in reporting, from an audited correction** of a wrongly-recorded Dump (AD-01C Q6-S3)? They now act on the same record and have **opposite** reporting effects. | §5.6 | AD-01C §3.4 states the principle; **revival removes the structural separation that enforced it** | A revival laundered as a correction erases a true loss from a closed period; a correction laundered as a revival preserves a false one. |
| **U-19** | Does the owner **affirm the principle** that reconciles revival-after-loss with new-Lead-after-win — *"a Success consumes the opportunity; a Dump abandons it"*? | §5.6 | **Not stated in the spec**; AD-01C §3.5 demanded such a principle | Without it, the product carries two idioms with no stated basis and AD-01C's cross-validation objection stands unanswered. |
| **U-20** | **Offline (§12, §46, §47):** may revival be performed offline, and what may a device cache for a revived lead whose prior episode is restricted from the holding handler? | §8 | §46 requires offline data minimisation; **silent on this case** | A device-resident copy of restricted history, outside every server-side control. |

**Explicitly NOT resolved, reopened, or narrowed by this document:** **N-2** (Blocked persistence
mechanism — AD-01B §7.1, AD-01C §1); **M-5** (uniqueness boundary — a requirement is *placed on it*
by U-15, not an answer supplied); **M-7** (record-visibility vocabulary); **M-3** (default role set);
**M-9** (commission model); **Q1**, **Q4**, **Q7**, the sync/verification split and the elimination of
the assignment axis (all decided at AD-01A §8, treated as fixed); **Q2**, **Q3**, **Q8–Q16**;
**N-1**, **N-3**, **N-4**; and **T-1 … T-12** raised by AD-01C — of which **T-1** is *discharged as a
requirement* by revival (§2.2 D10) and **T-4**, **T-10** and **T-11** are directly implicated
(§3.5, §5.3) but not answered.

**Q6 is not reopened.** §5.6 flags one genuine tension with AD-01C §3.5's cross-validation argument
and one new requirement (**U-18**) that revival places on Q6's already-approved correction mechanism.
**No Q6 decision requires revision**, and none is proposed.

---

## Approval

**STATUS: PROPOSED — NOT APPROVED**

**NOT APPROVED FOR IMPLEMENTATION.**

Everything in this document sits in Master Spec **§88**'s **MUST ASK BEFORE DECIDING** column:

- **Canonical entities and relationships** — the first-class commercial episode (§3.3, §11 R2) is a
  new canonical concept and a new relationship on the Lead.
- **Authorization rules** — the three-input entitlement model (§6.3), conferral (§7.3), and the
  intra-record boundary (§8) are all authorization-rule changes.
- **Source-of-truth rules** — re-keying the conversion funnel from Lead to Episode (§9.1, **U-6**)
  changes what the funnel is computed from.
- **CP commission logic** — episode-scoped attribution (**U-15**) determines who is paid.
- **Audit requirements** — conferral and restriction are auditable authorization events (§8); the
  intactness requirement is enforced by **R6**.

**Nothing in this document may be implemented, seeded, migrated to, scaffolded, prototyped or treated
as settled until the project owner approves it in writing.** No schema, SQL, migration, master value,
column, table or type is authorized by anything above, and none may be derived from it. **Delegation
to an architect is not authorization** (AD-01A §7). A **product-owner preference recorded in §1 is not
an approved architecture**, and the analysis in §§2–11 is offered so it can be attacked on its merits
rather than deferred to.

**The Lead State Machine decision as a whole remains unresolved and unapproved.** AD-01, AD-01A and
AD-01C remain **NOT APPROVED FOR IMPLEMENTATION**. Per **§97**: *when in doubt, STOP AND ASK.* This
document is the asking.

**STATUS: PROPOSED — NOT APPROVED**
