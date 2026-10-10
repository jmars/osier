# Osier — research TODO

The research project's live tracker. This is the *Osier* workstream (rows × GADTs × locally
abstract types); the compiler's own deferred-work list is the separate `todo.md` and is not
duplicated here.

**Authoritative sources, in order:** `docs/research/paper-plan.md` §10 (the ordered gap list —
G-numbers below are its) · `docs/research/row-gadt.md` (paper seed, incl. §9 do-not-publish) ·
`docs/research/row-gadt-calculus.md` (λρG) · `docs/research/osier-related-work.md` (survey) ·
`lean/` (the mechanization) · the memory chain `handoff-rowgadt-{ctx,lit,lit2,lit3,plan,meta,
impl-result,result,paper-plan}`.

---

## Current state — [M] verified

| | |
|---|---|
| commit | `8af7fb0` "P8 part 2: the remaining ZINC residue, and two record corrections" — the tree at the time of writing. The language change itself is `0207dd2` "type: branch-local row refinement for extensible records × GADTs (Withe / λρG)", 51 files, +6416/−287 — subject quoted verbatim from fx-ui, where the language was still named Withe |
| gate | `tests/elm-fixtures/run-elm-gate.sh` → **PASS=154 FAIL=0** (re-run on the committed state). Since P8 every executable row runs a natively compiled binary (elm → `.ssa` → vendored qbe → cc + `rt.o`); there is no interpreter |
| corpus | 149 gate groups; the compiler's QBE emit is **byte-identical** against the committed manifest `tools/osier-corpus-baseline.ssa.sha256` (check with `tools/osier-corpus-ssa.sh`; `tools/osier-numbers.sh` reports it) |
| tests | TestMain **95 assertions passed** (the 19 that went with P8 were all ZINC unit tests) |
| Lean | `lean/` is a **Lake project** (build with `lake build` from `lean/`); **90 theorem declarations, 3 axiom parameters, zero `sorry`** (per-file counts in `ARTIFACT.md` §4) |
| tree | dirty only with `elm-compiler/.elm-cache/0.19.2/packages/registry.dat` — the elm 0.19.2 cache rewrite `ARTIFACT.md` §2 documents |

**Venue call (plane §1): ICFP 2027 research track** — *not* POPL, because T1/T2 are argued, not
proved, and the Lean development mechanizes the **row algebra, not the typing judgment**.
Fallbacks: OOPSLA 2027 R2, then ML Family / Haskell Symposium.

**Language/calculus naming:** the language is **Osier**; its core calculus is **λρG**.

---

## 0. Do this first — the record is stale (G6)

- [x] **G6 — correct the stale metatheory wording** — **DONE** (`row-gadt-calculus.md` §5.3 now
      states H1 as **mechanized incl. duplicates**, with `h1_head_only_vs_full` recorded as a
      correction to the doc's own "for every `m`" claim; §5.4/§8.2 now describe the **domain rule**
      (`dropIntroduced`/`rebuildMatches`) replacing the syntactic check, with both counterexamples
      mechanized and a new §8.2 item 4 for the duplicate-case coarseness; `row-gadt.md` §7.3 the
      same). Every Lean theorem name cited in the docs was verified to exist in `lean/`.

---

## 1. Evidence hygiene — three load-bearing numbers live only in `/tmp`

- [x] **G2 — durable re-measurement** — **DONE** (`tools/osier-numbers.sh` +
      `tools/osier-corpus-baseline.sha256`, 139 sha256 sums). The script runs, from a clean
      checkout, gate + corpus batch (byte-identity vs the committed manifest) + TestMain +
      `lake build` (theorem count + axiom list) and PRINTS every number. Run on `0e5a564`:
      gate PASS=151 FAIL=0 · corpus BYTE-IDENTICAL (149=149) · TestMain 114/114 ·
      lake build exit 0/0 bytes · **90 theorems** (RowGadt 28, RowGadtEscape 4, Update 11,
      TypingStore 29, Preserve 18) · 3 axioms (Unifies/Captures/unifies_field_projection) ·
      0 sorry/admit. **Note: paper-plan C27's "43 theorems" is stale** — it counted only the
      row-algebra trio (28+4+11) before the typing-judgment arc added TypingStore/Preserve.
- [x] **G5 — independently recount the interpreter branches** — **DONE, and the "29 of 30" claim
      does NOT survive recounting.** `runTask` has 30 branches. Removing `Runtime.runTask` from
      `trustedBodies` reports exactly ONE error (TaskExec, Runtime.elm:222:29, `a is rigid …
      cannot be unified with List a`), but that is a fail-fast artifact: masking TaskExec reveals
      **further failures**. Full bisection (with the `type x a.` binder the discharge mechanism
      needs; the committed signature has none) → **5 branches fail**: TaskExec (existential
      `a ~ List a` cast), TaskNow (`Ok 0` number literal hits FlexConflict before the RigidVar
      discharge), TaskQuit + TaskGuiPoll (un-annotated nullary ctors, body `Ok ()` vs the abstract
      index), TaskStat (closed-record result; `dischargeType` refuses any `TRecord` body as a "row
      equation"). So at most **25 of 30** check honestly, and only under a binder the committed
      tree does not have. **Weaken the paper's wording accordingly** (drop the number, or state
      "all but TaskExec, TaskNow, TaskQuit, TaskGuiPoll, TaskStat").
- [x] **G3 — re-home the volatile probes** — **DONE** → `examples/research/` (not the gate, so the
      gate count stays 141): `probeA/probeA2/probeA_neg` (C18 typed-representation experiment),
      `hlist2` (C19 plain-signature rejection), `gNeg_letcase` (C24 retry completeness), and the
      duplicate battery `e1–e7` in `dup-hunt/` (C12), each documented in `examples/research/README.md`.
      **Two drifted** (rejections unchanged, message/location shifted — recorded in the README):
      `hlist2` now `cannot unify a with {l:a| b}` (was `{l:a|b} with {k:a|b}`); `gNeg_letcase`
      now at 19:21 (was 18:17). No existing fixture was touched.
- [ ] **G4 — build the external program** (the discuss.ocaml.org t/13718 FSM/reducer pattern) in
      Osier: row-typed state + a witness GADT for the transition relation. Probe-first in `/tmp`,
      then register as an example. This is the **strongest answer to referee objection O3 ("narrow
      program class, self-referential evidence")** — all current evidence is self-referential.
      *Cost: 1–2 days.*

---

## 2. Lean — the typing-judgment arc

The existing proofs cover the **row algebra + store + escape + update**. Extending to the typing
judgment is what would move the venue call (POPL needs T1/T2). **Architectural decision first:**
present the judgment **constraint-based** — rules emit constraints, unification is a *separate*
relation. Then soundness needs the unifier to be **sound, not complete** — which sidesteps the
hardest part (incompleteness is where GADT inference bites).

- [x] **Stage 1 — terms + judgment skeleton — DONE** (`lean/Typing.lean`, 656 lines; `lake build`
      clean; 0 `sorry`; the 43 existing theorems unchanged). **The architecture decision is
      VALIDATED: the constraint-based presentation works cleanly.** Unification is abstracted to two
      axiom-declared *parameters* — `Unifies : Rigid → Ty → Ty → Prop` (the global wanted) and
      `Captures : Rigid → Ty → Ty → Store → Prop` (branch capture) — with no substitution threaded
      through the rules. The two-tier rule is **verdict-indexed** (`Result … v` with
      `Verdict.ok | escape`), so the coercing-vs-rejecting asymmetry is in the relation's *type*;
      the store discipline is in the rule *shape* (`caseR` + a mutually-recursive
      `HasTypeBranches`, branch bodies under `Δᵢ ++ Δ`, conclusion under bare `Δ`). Divergences from
      the calculus doc are enumerated per rule in the file header. **Outlook changed:** stage 2 is
      now threading lemmas, and **stage 3 is a substitution + store-invariance argument, not a
      unifier-completeness proof** — so G9's venue calibration should be revisited once stage 3
      lands.
- [x] **Stage 2 — the store discipline at the judgment level — DONE** (`lean/TypingStore.lean`,
      443 lines; 15 theorems + 2 predicate defs, all closed; clean `lake build`, 0 `sorry`; the
      protected files' 43 theorems unchanged). Three findings:
      **(i) the mechanization independently rediscovered the implementation's soundness bug** —
      R-LET's `Generalizes` is unsound as skeletonized (`generalizes_quantifies_free_var` proves it
      quantifies refined tails), i.e. exactly the **let-laundering** hole the adversarial hunt found
      in the checker; the fix is the predicate `GeneralizesRespectsRefined`.
      **(ii) my proposed weakening was WRONG and was refuted** — the store is **anti-monotone for
      insertion**: `{ x | ℓ ← y }` is typable under the empty store but not under
      `Δ′ = [ρ ≐ {ℓ:τ|ρ″}]`, because the pushed equation refines the tail and trips
      `InsertionRejected` (the `ins` rule working as designed). The true statement is **right**-append
      with a side condition: `weakening_right_ty (hΔ′ : ∀ r, ¬ InsertionRejected Δ′ r)`.
      **(iii) the no-escape obligation is VACUOUS BY CONSTRUCTION** in this skeleton (conclusion and
      recursion are indexed by bare `Δ`) — labelled as such, with the precise change that would make
      it content-ful.
- [ ] **Stage 3 — the two-tier rule + preservation for the RECORD operations** (select, update).
      *This is probably where a paper deadline lands*, and it is already a strong result: "the
      record operations are type-preserving under branch-local refinement." *Days.*
      **Carry two corrections from stage 2:** R-LET must adopt `GeneralizesRespectsRefined`, and
      "no escape" is a rule *shape* to preserve, not a theorem to prove. Instantiate
      `weakening_right_ty` (with its `hΔ′` side condition) and the unconditional
      `result_weakening_right`.
- [x] **Stage 3b — the R-LET soundness fix, and the review that caught it — DONE.** The skeleton's
      `letR` quantified every free non-Γ variable, **including refined tails** — proved by stage 2 and
      exactly the implementation's let-laundering hole. Wired a respects-refined premise
      (`RefinedTailVar` + `GeneralizesRespectsRefined` moved down into `Typing.lean`; `def Generalizes`
      left **unchanged** so the "unsound rule / fixing premise" pairing survives). **A review then
      found the fix excluded the WRONG HALF** — `RefinedTailVar` holds for the equation's *subject*
      (the head), while the implementation's comment calls the *body tail* "the crucial one" — plus a
      **second, independent channel** (R-VAR's unconstrained θ in `instantiates`). Both review fixes
      are applied and verified: the predicate now has three conjuncts (Generalizes, head, **body
      tail**) and `instantiates` requires θ to be the identity outside the quantifiers.
      **Remaining small gap:** both channels are *enforced* (the tail by `letR`'s premise, θ by the
      definition) but **not individually established** — the exclusion theorems cover only the head
      half. Mirror `generalizes_respects_refined_excludes` for the body-tail conjunct.
      **Fidelity gap recorded, not fixed:** `tier_R` fires on the refined head occurring in either
      type, so the *legitimate* rebuild the implementation accepts via `rebuildMatches` is untypeable
      in the skeleton (strictness — safe, but not faithful).
- [ ] **Stage 4 — unification as a relation** + its **soundness** lemma + the substitution lemma.
      *Weeks.*
- [ ] **Stage 5 — full progress + preservation** for a core fragment. The POPL-grade endpoint.
      *Weeks.*

Note: **H1 and H2 are precisely the lemmas judgment-level soundness will consume** — the arc is
cumulative, not a restart. And `T1/T2` are currently **argued, not mechanized** (G9 is the
presentation decision: (a) argued + the reduction note for the ICFP frame — recommended; (b) 2–4
weeks for a pencil T2 sketch at OOPSLA-R2 scale).

---

## 3. Literature follow-ups

- [ ] **G7 — retry Chen & Erwig POPL'16** (choice types) via a non-ACM route; cite only if read,
      else leave uncited. *1 h.*
- [ ] **G8 — check whether OCaml's 2012 objects/poly-variants + GADT restriction is still current.**
      If unverifiable, keep the defensible wording "restricted in its first implementation". One
      sentence in §1/§7 depends on it. *2–4 h.*
- [ ] **G1 — verify the ICFP 2027 CfP when it posts** (page limit, deadline, double-blind, artifact
      track). The 2027 numbers are **not yet posted**; do not invent them. *1 h at write time.*

---

## 4. The paper itself

- [ ] **G9 — decide the T1/T2 presentation** (see §2). *1 h decision.*
- [ ] **G10 — drafting, in this order:** §1+§2 → §6 → §3+§4 → §5 → §7 → §8 → **abstract last**.
      Then run the `reviewer` preset on the full draft, then a `strategist` pass on the contribution
      list and abstract. *2–3 weeks of units.*
- [ ] **G12 — figures:** F1 (verbatim from fixtures), F2/F3 (from the calculus doc), F4 (from code
      comments), F5 (the counterexample pair), F6 (the L3 principality table), T1 (fixture matrix).
      Required: F1–F6 + T1. *1–2 days.*
- [ ] **G11 — artifact packaging:** repo + the G2 script + fixture matrix + `lean/` build
      instructions (**note the bare-`lean` gotcha: use `lake build` from `lean/`**) + the artifact
      note (the Lean files are one Lake project with one definition of the row algebra). *1 day.*
- [ ] **G13 — *(optional)* a fresh adversarial battery against the DOMAIN-BASED escape rule**
      (two-step tail-to-head chains through zonk; `dropIntroduced`'s pre/post scoping). The hunt
      found two unsound accepts in the *previous* rule, so this one deserves its own pass.
      *0.5 day.*
- [ ] **G14 — line-number refresh:** re-verify every `file:line` in the draft against the
      paper-frozen commit hash (cite the hash in the artifact note). Line drift is a documented
      failure mode on this project. *0.5 day, fold into G10.*

**Execution order (plan §10):** G6 → G2 → G5 → G3 → G4 → G7/G8 in parallel → G10 → G11/G12 → G13.

---

## 5. Housekeeping in the tree

- [ ] Add `tools/selfhost-audit.txt` to `.gitignore` — it is **regenerated**, and its only diff is a
      `Date:` line (timestamp churn).
- [ ] Delete `elmc.err` (stray 27-byte file: `err manifest has no groups`).
- [ ] Decide on `elm-compiler/.elm-cache/0.19.1/` (untracked; a cache dir for a *different* elm
      version) — gitignore or remove.

---

## 6. Standing rules learned the hard way (enforced in every brief)

- **Gates are the exit code, not the tail of stdout.** And *never* take `$?` after a pipeline — that
  is `tail`'s status. (This bit the orchestrator, not just the subagents.)
- **Relay nothing unprobed.** Four of my diagnoses on this project were refuted on contact with the
  code ("one missing combinator", "a wiring job", "derivable only by composition", the empty-row
  surface gap). Verify a specific before it enters a brief or a doc.
- **A record carrying a refuted claim is worse than no record** — see G6.
- **After a mechanism changes, correct the documents describing it in the same arc.**
- **Invariants outrank cosmetics:** a comment edit that shifts a fixture's error line breaks
  byte-identity, so don't add framing comments to registered fixtures.
- **`glm-coder` is NOT banned on this project — the ban was lifted by the user on 2026-10-07.** The
  history it rested on stands as history rather than as a rule: three failures, two runs publishing
  nothing and one leaving the tree broken. The same *model* backs `planner`, which has a good record
  here. Weight that history when choosing a tier, but it is no longer a prohibition.
