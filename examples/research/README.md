# Withe / λρG — re-homed research probes

These are the probes the paper cites that previously lived only in `/tmp`
(handoff `rowgadt`, gap G3). Each file is a small, self-contained program
compiled by the same checker the gate exercises. They are **not** registered
in `tests/elm-fixtures/run-elm-gate.sh`; they are reproducible here, from a
clean checkout, with the one-liner below. (This includes the external FSM
example of gap G4, `fsm/door.elm`: it is **not** gate-registered either — it is
verified by hand, compiling clean with `main` printing `"open:42"`, and its
behaviour is pinned separately by the `rowgadt_fsm*` gate fixtures, which are a
condensed copy of the same program — see its section.)

Compile any probe and read the artifact (the oracle is the OUTPUT FILE, never
the exit code — `node elm-compiler/run.js` always exits 0 and writes `err <msg>`
for a rejection):

```sh
node elm-compiler/run.js examples/research/<probe>.elm /tmp/out.csexp
cat /tmp/out.csexp      # a bundle = compiles clean; "err <msg>" = rejected
```

Results below were re-measured on the artifact tagged `withe-paper-artifact-1`
in this repository (the withe tree, after the language left fx-ui). Expected
results are the CURRENT checker output; where a probe's
error string or location has drifted from an earlier `/tmp` snapshot, that is
called out (the rejection itself is unchanged).

## The external FSM example (gap G4)

`fsm/door.elm` is the one program in this directory written by someone else and
translated into Withe: the state machine from the discuss.ocaml.org thread
[t/13718](https://discuss.ocaml.org/t/unable-to-refute-impossible-gadt-pattern-with-polymorphic-variants/13718)
("Unable to refute impossible GADT pattern with polymorphic variants"). There,
a practitioner models an FSM as a GADT-witnessed transition relation over
type-level states, and hits the wall octachron states plainly: *"the
interaction of row variables and GADTs is not well specified … GADT equations
cannot narrow a polymorphic variant constraint."* The recommended workaround is
object types — type-level records, one row variable per field.

`door.elm` gives a 4-state door machine (`Locked`, `Closed`, `Open`, `Broken`),
a `Event from to` witness GADT for the transition relation, a `Step s` chain,
and two working reducers: `readFrom`, which reads a state's marker field under
branch-local row refinement, and `readCurrent`, which does the same narrowing
over the *nested* chain match (the source's own shape). It **compiles clean**
and its `main` prints `"open:42"`.

*What is honestly claimed.* The precise claim is: **an external FSM translated
to rows, where the per-state field *reads* use branch-local row refinement** —
not "the FSM expressed directly" (the transition GADT is row-inert, below).
The two things the earlier review scoped *out* — the nested-chain match and
the impossible-arm refutation — are now answered in Withe (see below).

- **The transition GADT is row-inert.** `Event`'s indices `from`/`to` are
  `KType`; the narrowing `readFrom` performs refines the *record argument's*
  row variable (`from` in `{ from | n : Int }`), which each branch equates to
  the constructor's index. The per-branch row equation is genuinely enforced —
  a wrong-field read in any branch is rejected, independently of the `type`
  binder — but the transition relation itself contributes nothing row-specific
  that an ordinary `KType`-indexed GADT would not.
- **The source's own match shape now typechecks — the nested-pattern fix.** The
  OCaml wall is pattern-matching over the *chain*, with nested patterns like
  `Then (Then (Then Start Unlock) Open) Close` binding per-arm event
  witnesses. Withe used to reject any pattern with an `Event` constructor
  nested inside another constructor pattern (`type variable a is rigid ...
  cannot be unified with {}`): sub-pattern types were unified in *global* mode
  (`unifyM` inside `peelCtor`), and only the top-level pattern-vs-scrutinee
  unify (`unifyBranchM`) was branch-mode. The fix routes the sub-pattern
  unification through *branch* mode and snapshots the equation store *before*
  pattern inference, so a nested ctor's equations are captured branch-locally
  and dropped at branch end. `door.elm`'s `readCurrent` now does the source's
  chain match directly — the `Event` matched nested inside `Then`, narrowed at
  the nested level — while `readFrom` still matches the `Event` at top level
  (reading the *departure* state) and `count` binds the event via `Then prev
  ev`. The wrong-field negative is pinned as `rowgadt_fsm_nested_bad`: a nested
  branch reading a field its refinement does not expose still errs.

The illegal transition is the negative: `Then Start Open` departs `Open` from
the `Closed` state but is applied to `Start` (the `Locked` state), so it is
rejected at construction:

```
err type error at 25:5: missing field closed
```

OCaml rejects this illegal construction too (it is the source's own first
error, "These two variant types have no intersection"); Withe rejects the same
thing with a row-typed message. That direction is **not** a Withe-vs-OCaml
difference.

*The refutation wall — answered (the thread's headline question).* The source's
actual wall is **refutation**: the compiler "refuses to refute such impossible
cases", i.e. it will not type the `-> .` arm. Withe now does both halves of
that capability, and each is pinned in the gate:

- **Exhaustiveness.** A `case` that omits a *possible* arm now errors at
  COMPILE time — `err ... non-exhaustive case: missing <ctor>`. Before, it
  compiled clean and raised `non-exhaustive case` only at *runtime*
  (`Lower/Expr.elm:1045`). Pinned by `adtgaps`.
- **Refutation.** An arm that is IMPOSSIBLE under the branch equations is
  refuted and not required. `eval : Expr Int -> Int` matching only `IntLit`
  compiles clean — `BoolLit : Bool -> Expr Bool` is impossible at `Expr Int`
  (`Int ~ Bool` cannot hold), so its absence is not a gap. Pinned by
  `refutpos`; its negative `refutneg` pins that an arm which *is* possible
  (`HNil` at an open `HList rho`) is NOT refuted and must still be matched.

That is exactly the `-> .` mechanism the thread's author could not get working
in OCaml, so on the source's own headline question the comparison is now
**inverted**: Withe refutes the impossible arm that OCaml-with-the-workaround
could not be made to refute. The earlier scoping ("Withe has no exhaustiveness
checking; OCaml is strictly stronger") is superseded — the refutation wall is
answered, and the narrowing claim above is scoped to *field reads* only because
the transition GADT is row-inert, not because refutation is missing.

*Boundaries this example exposes.* (1) **Result-side refinement is rejected.**
Any reducer whose *result* is a record at the refined row is rejected by the
escape rule (`escaping row equation ... to {| a}`) — not just a
state-*changing* reducer that threads a runtime record. Even the
state-*preserving* `Jiggle` update (`{ rec | n = rec.n + 1 }`, `from = to =
Closed`) is rejected, because the refined variable is the *result* index `to`,
not the argument row: this is the paper's own `tier_R` rule. The FSM therefore
keeps its state type-level (as OCaml does) and threads no record. (2) The
membership-witness `read` is **definable but not callable** at any concrete
witness: `read Here { n = 1, closed = 2 }` errs
`cannot unify a with {l:a| b}` — the global bare-`KRow`-variable vs concrete
`TRecord` gap (`Type/Unify.elm:266-270`); its row index is constructible only
inside branch refinement or at an abstract row. It is kept as the crux shape
`readFrom` reduces to, not as a working reducer. (3) The argument order
matters as a *kinding + global-mode* artifact of argument-unification order:
`readFrom` (record *first*) compiles; the symmetric `readTo` (event first) is
rejected at its call site. This is an inference-order artifact of Withe's
implementation, not gasche's left-to-right typing-rule bias, so it is not
cited to gasche. (4) The `type` binder is used throughout but is only
*strictly* required where the refinement conflict is forced — the recursive
`There` arm of the canonical witness reader (`hlist2.elm`, `rowgadt_l3ii`);
`readFrom`'s branches are terminal, so its plain-signature form also
type-checks. (5) A chain that *carries* the state record
(`Step { s | n : Int }`) kinds its row parameters and forces the binder, but
its construction then fails in global mode (`cannot unify a with {closed:Int}`)
— a `KRow` variable cannot be unified with a concrete record outside branch
mode. (6) **Refutation is decided only at a concrete or binder-rigid index; a
bare, unbindered index variable never licenses refutation.** An arm is refuted
only when its constructor's result index provably cannot unify with the
scrutinee's index, and that verdict is authoritative only when the index is a
CONCRETE type (`Expr Int`) or a binder-RIGID variable (`type a.`). A *bare*
index variable is flexible — unification may bind it to make any constructor
possible — so it is never concretized to refute a sibling constructor. Thus
`f : Tag a -> Int` (bare `a`) matching only `A` correctly reports
`non-exhaustive case: missing B`, exactly as the `type a.` binder form does,
instead of being silently accepted by refuting `B : Tag String` against the
clause's `Tag Int`. Pinned by `refutbare`. (Before the check, every `case`
compiled clean and failed only at runtime; this is the completeness boundary
of the check, not a regression.)

The example is not itself a gate fixture: `tests/elm-fixtures/rowgadt_fsm.elm`
(module `RowgadtFsm`) is a separate, condensed copy of the same program, and
five gate fixtures pin the capabilities it demonstrates: `rowgadt_fsm` (clean),
`rowgadt_fsm_bad` (illegal construction errs), `rowgadt_fsm_narrow` (a
wrong-field read in one branch errs — the per-branch field narrowing that
OCaml's per-field workaround cannot do, pinned as a negative rather than
asserted), `rowgadt_fsm_nested` (the nested chain match, runs clean), and
`rowgadt_fsm_nested_bad` (a nested wrong-field read errs). The
refutation/exhaustiveness capability is pinned separately by
`adtgaps` (missing possible arm errors), `refutpos` (impossible arm refuted),
`refutneg` (possible arm NOT refuted), and `refutbare` (a bare flexible index
never refutes — `Tag a` matching only `A` still errors `missing B`).

## The typed-representation experiment (paper claim C18)

The VM-boundary trusted bodies (`Prelude.compare`, the `decode*`/`t*` helpers
in `Runtime`) are skipped because they introspect a uniformly-typed VM value
that HM cannot express. These probes ask: **if the VM value were given honest
constructors, would the trusted bodies type-check honestly — and would a WRONG
body be rejected?**

- `probeA.elm` — honest `Value = VStr | VNum | VNil | VCons` plus an honest
  structural `compare`. **Compiles clean** (a real bundle).
- `probeA2.elm` — honest `Value` with a distinct `VSym` leaf (so the
  `intern`/`tSym` trusted lie disappears) plus `decodeNumber` / `decodeString` /
  `decodeStringList` / `decodeExec` as plain case-matches on the honest
  constructors. **Compiles clean**.
- `probeA_neg.elm` — honest `compare` whose number branch returns a `String`
  body. **Rejected**: `err type error at 15:13: cannot unify number with String`.

Together: the trusted residue is *representation-bound*, not refinement-bound —
the bodies could be typed honestly, and the checker still rejects a dishonest
body. (C18's "compare retirement error" half.)

## Plain-signature rejection (paper claim C19)

- `hlist2.elm` — the HList-of-witness `hget` with a **plain** signature
  (`hget : Has l t rho -> HList rho -> t`, no `type l t rho.` binder). The two
  branches refine `rho` to different heads; with a flexible `rho` they conflict.
  **Rejected**: `err type error at 23:13: cannot unify a with {l:a| b}`.

  *Drift:* an earlier `/tmp` snapshot read `cannot unify {l:a| b} with {k:a| b}`
  (the row-vs-row form). The current tree reports the type-variable-vs-row form
  above, at the same 23:13. The rejection is unchanged; only the message drifted.

## Retry completeness (paper claim C24)

- `gNeg_letcase.elm` — the canonical 3-branch evaluator, but the `case` is a
  `let`-bound helper rather than the function body itself. The
  declaration-directed result-discharge retry fires only when the body is
  *directly* a case, so the let-wrapped evaluator takes the historical path and
  is (spuriously) rejected. **Rejected**:
  `err type error at 19:21: cannot unify Bool with Int`.

  *Drift:* an earlier snapshot located this at `18:17`; the current tree reports
  `19:21` (same message). This is the retry's completeness boundary — not a
  soundness hole — and it is why the paper's `rowgadt_eval` fixture writes the
  case directly as the body.

## Duplicate-label battery (paper claim C12)

The domain-based escape rule (`dropIntroduced` / `tailReachesHead` /
`rebuildMatches`) is exact for fresh labels and coarse for duplicates. The two
headline cases are already gate fixtures (`rowgadt_dup_rebuild` clean,
`rowgadt_dup_fewer` err — the pinned false reject). This battery sweeps the
duplicate-label corners; the domain rule must reject every domain *change* and
accept only the exact full rebuild.

`dup-hunt/` (each uses `type rho.` and a duplicate `x : Int, x : String` head):

| file | body under `HDupCons i s rest ->` | expected |
|---|---|---|
| `e1_tail.elm` | returns `rest` (the tail) | err `escaping row equation: a branch refined the row and returned only its tail where the full row is expected` (7:14) |
| `e2_wrongtype.elm` | `HOne s rest` (field of the wrong type) | err `cannot unify Int with String` (6:30) |
| `e3_swap.elm` | full duplicate rebuild, swapped order | **clean** (the only accept — exact full rebuild) |
| `e4_let.elm` | `let ys = rest in ys` (let-bound tail) | err `escaping row equation …` (8:14) |
| `e5_wild.elm` | returns `rest` with a `_ ->` fallthrough | err `escaping row equation …` (7:14) |
| `e6_difflabel.elm` | `HOther True rest` (different label) | err `cannot unify a with {y:Bool| a}` (7:14) |
| `e7_fieldtype.elm` | `HOneS s rest` (wrong field type) | err `cannot unify a with {x:String| a}` (7:14) |

The one accept (`e3_swap`) and the two pinned gate fixtures together are the
evidence for "exact for fresh labels, coarse for duplicates".
