# THE WORD ARM'S FRONTIER, MEASURED

perf word-arm-frontier: measured on HEAD 46b54d8 (the instrument), then on 4c3d038
+ the port, which is where the AFTER column comes from.  RE-MEASURED at perf
word-arm-letdestr after the review's item 1 — the per-defun walk now returns
EVERY blocker instead of the first (see "Re-measured" below): the BEFORE column
stands as measured with the first-only instrument, and the two rows the fix moved
are corrected in place.
Reproduce with `tools/qbe/word-arm-refusals.sh` (`--groups`, `--raw`).

The question this file answers is **"what is the next class?"** — and it answers
it with a census rather than with the WORKLIST, because the WORKLIST is a claim
about the arm written at some earlier time and nothing re-tests it. That is not
a hypothetical: the census's own top two entries turned out to be **stale
refusals**, and porting them moved the arm more than any unit since the surface
lane.

## Method

For every group the LANGUAGE GATE registers (159 unique groups; the plan carries
160 emissions because the gate registers one twice), compile through the QBE
backend twice — once on the val arm, once with `QBE_VALREP=word` — and classify:

| verdict | meaning |
| --- | --- |
| `BOTH` | both arms emitted IL |
| `SAME-ERROR` | both arms refused with **byte-identical** text — the group is a `compile_error` row or invalid; **not** a word-arm blocker |
| `WORD-BLOCKED` | the val arm emitted, the word arm refused — a real blocker |

**`SAME-ERROR` is a control, not a rounding.** 34 of the 159 groups fail on
*both* arms with the same bytes (type errors, duplicate definitions, ambiguous
imports). Counting them as word-arm blockers would have inflated every number
below by two thirds.

**The refusal text names EVERY blocker, not the first — at DEFUN granularity as
well as at group granularity.** `wordSurfaceUnported` and `wordRtUnported` return
lists (this unit's first change), and the per-defun walk behind them was made
list-valued by the frontier review's item 1: until then it short-circuited on its
FIRST refusal, so a defun carrying two blockers reported one of them and the
group set was the union of per-defun *first* blockers. The first-only form
reports whichever blocker comes first in `surfaceKeys` order, and the
measurement is what shows how misleading that is: 26 groups reported a
constructor-tag pattern as their blocker while *every one* of them also applies
`Ok`/`Err`/`Just`, so porting that pattern alone would have moved **none** of
them. A ranking cannot be built from a first element.

**And the per-defun half was measured to matter, inside this very census.** The
BEFORE table below promised 15 movable groups for `Con`+`MTagEq`; 14 moved, and
the 15th reappeared as float-blocked once the first class stopped refusing — a
second blocker hidden behind the first. The list-valued walk is what makes that
visible up front; the two rows it changes are corrected under "Re-measured".

Nothing is relaxed — a non-empty list still refuses before any IL is produced.

**Runtime or surface.** Every refusal line is prefixed with the defun
(`Rt.foo: AREA ..`, `Array.compressNodes: AREA ..`), so the table says which.
In this census **every** blocker is a SURFACE defun — no `Rt.` defun refuses any
more, which is itself a result: the runtime surface is closed, and the frontier
is entirely in the compiler's surface classifier. (One class is caught at an
emit site rather than by the classifier — see the note under the float row.)

## The census, BEFORE this unit's port

```
BOTH            74
SAME-ERROR      34   (not word-arm blockers)
WORD-BLOCKED    51
```

```
GROUPS  ALONE  CLASS
    41      2  MTagEq (constructor-tag pattern)
    39      0  Con (constructor application)
    26      1  let-destructuring
     8      7  float literal (area 5)
     2      2  prim `f/` (area 5)
```

`GROUPS` = how many blocked groups carry the class among their blockers.
`ALONE` = how many groups this class blocks **on its own**, i.e. how many a port
of this class alone would unblock. **These are different questions and they give
opposite answers**, which is the whole point of the column:

```
BLOCKER SETS
   25  Con + MTagEq + let-destructuring
   13  Con + MTagEq
    7  float literal
    2  prim f/
    2  MTagEq
    1  let-destructuring
    1  Con + MTagEq + float literal
```

The top of the table is a **cluster**, not a class: 39 groups need
`Con` + `MTagEq` (38 of them with `let-destructuring` as well), and no single
member of that cluster moves more than 2 groups. `Con` alone moves **zero**.
The only self-contained classes are the floats (10 groups, blocked by nothing
else) — which is why a first-refusal ranking and a port decision are not the
same ranking.

## What the measurement found: two stale refusals

`Con` and `MTagEq` were blanket refusals in `Mid.Qbe.Lower.wordArmUnported`, and
**both stated reasons had gone stale under them**:

* `Con` — *"its vector is written through `storeValueCell`"*. True of that
  writer's **heap** arm only, and `lowerCon` calls it with `tagNumber`, an
  IMMEDIATE whose word-arm arm is the `shl 3` `mknum` wrap the closure ABI
  already uses for `desc`/`capBase`. The tag is an `LSymbol` (ported in R1), the
  arguments are rooted slots staged contiguous, and the allocation is `Rt.con`'s
  word splice (written in perf word-arm-area3rt). **`Con` needed no emitter
  change at all.**
* `MTagEq` — *"the tag is materialised as a `symbol` literal"*. R1 had already
  ported exactly that. What remained was the tag-**equality** half, and it was
  one accessor-sized decision: the val arm's inline compares payload pointers at
  `slot + 8`, which on the word arm is **the next frame slot** (the `fieldBase`
  defect this arc already paid for once), so this arm runs the runtime's `=`
  instead — byte equality, correct without the `sym:` pointer-identity licence
  the inline rests on.

This is the **third** class to leave a stale refusal behind it (the arithmetic
family was the first). The rule that follows: **a construct at the top of the
refusal ranking must be RE-MEASURED, not re-read.**

## The census, AFTER the port

```
BOTH            88      (+14 groups: 74 -> 88 of 159)
SAME-ERROR      34
WORD-BLOCKED    37
```

```
GROUPS  ALONE  CLASS
    26     26  let-destructuring
     9      9  float literal (area 5)
     2      2  prim `f/` (area 5)
```

(Those two float rows are the FIRST-ONLY numbers. Re-measured with the
per-defun list-valued walk they are `10 / 9` and `2 / 1` — see "Re-measured"
below, which is the same tree and the same census with the fixed instrument.)

`let`-destructuring is the first class in this table to be blocked **alone** in
every group that carries it (26 of 26), which is what makes it the one class a
single port can move whole. The rest of the table is NOT that clean, and the
first version of this paragraph said it was ("every remaining group is blocked by
exactly one class … `GROUPS == ALONE`") — the per-defun list-valued walk falsified
it on the next run: `floatdiv` carries BOTH a float literal and `f/`. See
"Re-measured".

## Re-measured with the per-defun instrument (perf word-arm-letdestr)

The frontier REVIEW's item 1, measured. `wordArmUnported` returned `Maybe String`
— ONE construct per defun, the first in walk order — so every number above is a
union of per-defun *first* blockers. It now returns a `List String` and the
census reads all of it (`wordArmUnported` survives as the first-element view the
classifier's own unit rows compare against, so no row changed meaning). Same
tree state as the AFTER table (the `Con`/`MTagEq` port, before the destructuring
port), same command:

```
BOTH            88
SAME-ERROR      34
WORD-BLOCKED    37

GROUPS  ALONE  CLASS
    26     26  let-destructuring
    10      9  float literal (area 5)
     2      1  prim `f/` (area 5)

BLOCKER SETS
   26  let-destructuring
    9  float literal (area 5)
    1  float literal (area 5) + prim `f/` (area 5)
    1  prim `f/` (area 5)
```

WHAT MOVED, AND WHY IT IS THE REVIEW'S ITEM 2 IN MEASURED FORM:

* `float literal` gained a group and lost an `ALONE` (`9/9` -> `10/9`) because
  **`floatdiv` carries a hidden second blocker**: `Floatdiv.main` applies `f/`
  AND heap-boxes a float literal, and the first-only walk reported only the
  `f/`. So the float unit will NOT move all ten groups by porting the float
  cell alone — one of them also needs `f/`, which is the same area and the same
  unit's problem, but it is a second refusal text in the same defun.
* `prim f/` correspondingly went `2/2` -> `2/1`.
* `let-destructuring` did NOT move: 26 groups, 26 alone, with no hidden second
  blocker in any of the 11 defuns. That is the measurement that makes the
  destructuring port's claim — "26 groups, all 26 alone" — checkable rather
  than hopeful.
* The claim this file made in the previous revision, "every remaining group is
  blocked by exactly one class, so `GROUPS == ALONE`", is FALSE and is corrected
  above: `floatdiv` is the counterexample.

### let-destructuring — 26 groups, 26 alone. **PORTED: it moved 19, and 7 refuse by name.**

`arraybasic arraystress asyncorder asyncpure dictbasic dirunit execbig
execchain execenv execglob execmal execnofile execpipe execsubchain fastexec
fdstream ioecho iofile nowunit readfile setops statplus statunit taskattempt
taskpure taskseq`

defuns: `Array.compressNodes`, `Array.fromListHelp`, `Dict.merge`,
`DictBasic.main`, `Fdstream.fileInProbe`, `Fdstream.stringStreamProbe`,
`Runtime.program`, `Runtime.runOne`, `Runtime.worker`, `Set.partition`,
`SetOps.main`.

The refusal text said *"a tag test plus payload reads"* — and **both of those
existed already**: `wordTagIs` is the tag test (nil is an immediate,
cons/vector are GC-header kinds) and `fieldBase n` is the payload chase, with
`n` a payload WORD index.

**THE CRUX THE CENSUS NAMED, ANSWERED: the existing-binder path has NO word-arm
fork of its own — it IS the `Case` matcher's `lowerBind`/`lowerPath`.** A `let`
destructuring binds into existing binders rather than fresh slots, so the
question was whether that binding path differed; it does not:

* `lowerLetDestruct` lowers the scrutinee with `lowerVal` (forked at every
  site), then runs `lowerMatchTests` — the SAME `lowerMatch` a `Case` alt runs,
  i.e. `lowerTagMatch` -> `wordTagIs` for MCons/MEmpty/MVector and the forked
  tag-equality (`Rt.=`) for MTagEq — then `lowerBinds` -> `lowerBind` ->
  `lowerPath` -> `readSteps` -> `fieldBase`/`chaseField`/`chaseCdr`/`lowerHdTl`,
  the one chase family `fieldBase`'s doc calls "the ONE statement of the
  difference between the arms";
* the non-exhaustive arm is `Rt.die` through the raw-word ABI, arm-independent.

So the port is **an admission in the classifier, not an emitter change** — the
FIFTH class in this file whose refusal was a DESCRIPTION rather than a gap
(after the arithmetic family, `Con`, `MTagEq` and the record family). The
classifier's `LetDestruct` arm now runs the same three walks (scrutinee, match
literals, bind paths), so an un-ported construct anywhere inside a
destructuring still refuses by name.

**IT MOVED 19 OF THE 26, NOT 26 — AND THE RUN ORACLE IS WHY THE NUMBER MOVED.**
The census counts groups whose EMIT is unblocked; a group that emits can still
be wrong at RUN time, and seven of the 26 turned out to be exactly that. Running
all 26 on both arms (same entry, same cwd, stdout+exit compared) found:

* **7 groups print `[vector 4]` instead of their answer** — `asyncorder
  asyncpure dirunit fastexec nowunit statplus statunit`, i.e. every group that
  reaches `Platform.program`. The HOST EVENT LOOP's state is a 1.3 MB malloc'd
  blob laid out with the val arm's 40-byte Value stride (`Rt.hostInit` sizes it
  `8 + 33031 * 40 + ...` and writes the model/update slots at `blob + 8` and
  `blob + 8 + 40`, `Rt.hostRun`/`hostDispatch`/`hostRunLoop` read the same
  hardcoded 40s) while `rootPushValueArray(blob + 8, blob)` registers it for the
  collector, whose scan stride IS the layout's. MEASURED minimally: a
  `Platform.program` whose model is the Int 7 prints `7` on the val arm and
  `[vector 4]` on the word arm, rc 0, no stderr. Twinning that blob is a unit of
  its own, so `Runtime.program` is now refused BY NAME
  (`wordArmDefunRefusals`, the first SURFACE entry in that list) and those 7
  groups refuse loudly instead of running wrong.
* **2 groups failed to LINK**: `taskpure taskseq`, `undefined reference to
  q_Rt_x2esymToStr`. `Rt.value`'s word splice calls `Rt.symToStr` and the seed
  walk never emitted it; fixed by seeding it in `MidRt.wordArmSeeds` (NOT via
  `Rt.value`'s `rtDeps` row, which would emit a dead defun on the val arm and
  move 8 `exec*` corpus hashes).
* **1 group read the wrong BYTE**: `fdstream` printed `""` (a stream read as an
  fd). `Rt.open`'s word twin passed the RAW flags to `Rt.mkStream`, while
  `Rt.read-byte`/`Rt.close` test `payload(stream, 1) > 1` — the val arm packs
  `1 + 2^32 * isString` there, so a STRING stream's twin said "not a string" and
  `read-byte` read fd 0 (stdin) and answered -1. One constant, in the splice.

So the honest post-port census is **WORD-BLOCKED 18** (37 - 19), and the
`let`-destructuring row is GONE from it: the class now blocks **zero** groups.
The remaining 18 are the float class (10 groups, 9 alone), `f/` (2, 1 alone) and
the host program path (7, 7 alone — the class this port uncovered).

**MEASURED, both oracles.** Behavioural: `tools/qbe/word-arm-diff/letdestr.elm`
compiles, links and prints BYTE-IDENTICAL stdout on both arms (tuple, ADT, list,
nested and record-field patterns, every scrutinee a CALL result so Flatten cannot
substitute it away) — and it REFUSES on the word arm before the port, which is
the asymmetry. Collecting: `tools/qbe/word-arm-gcchurn/letd.elm` at four rungs,
`6000/6000/0` on both arms with 80/174, 72/164, 62/82 and 4/7 collections
(scavenges + full collects) — the binds live in rooted slots across the body's
allocations. Source: a TestMain row lowers the same pattern twice, as a `let`
and as a one-alt `case`, and asserts the two functions carry the same
layout-derived chase (slot-load-then-untag on the word arm, neither on the val
arm); MEASURED fail-able — deleting `fieldBase`'s untag turns it red, while a
weaker "an untag exists somewhere" predicate stayed green because the TAG TEST
emits its own.

Note `Runtime.*` — a core-lib defun reached by the effect host, so this class was
never only "programs that destructure in a `let`".

### float literal — 9 groups, 9 alone (AREA 5)

`cmporder floatarith floatcmp floatfun floatineq floatlit floatmix mxint strunit`

The **`mk*` SAFEPOINT TRAP IS INHERITED BY THIS UNIT** — WORKLIST item 5, and it
is a correctness precondition, not a note: `Mid.Rt.unsafeSafepoint` classifies a
`RawMkValue` as a non-safepoint (it scans `m.words`), which is true on the val
arm and **false** for the word arm's HEAP codes, because
`storeWordStringCell`/`storeWordFloatCell` inject `midGcAllocSeat` calls
(`Rt.allocRaw`, `Rt.allocFloat`) that the surface tree never shows. So a defun
whose only allocation is a `mkstr`/`mkflt` cell classifies FRAME-FREE and drops
its roots. The float unit inherits the obligation to count a word-arm heap-code
`mk*` as a DIRECT safepoint **in the same unit**.

**TWO groups are blocked by an EMIT SITE, not the classifier** — `strunit` AND
`cmporder`: both refusal lines carry no defun name (`a float literal — the word
arm heap-boxes a float as a [hdr | f64] cell`). This section named only `strunit`
until the frontier review's item 2; the census has carried the identical unnamed
line for `cmporder` since the first run, so the App-without-arg-recursion gap is
wider than the note said. That is the already-recorded gap that `wordArmUnported`
admits `App` WITHOUT recursing into its arguments — a raw node reached only as a
call argument is invisible to the belt. Worth fixing while in there.

### prim `f/` — 2 groups, 1 alone (AREA 5)

`floatdiv floatpartial`, defuns `Floatdiv.main` and `/.curried`. Same area; it
cannot be ported before the float cell exists. (First-only this read `2 alone`;
the per-defun walk shows `floatdiv` also carries a float literal, so `f/` on its
own moves ONE group — `floatpartial`.)

## The word-arm DIFF fixtures' neighbourhood

The 17 (now 18) `tools/qbe/word-arm-diff/*.elm` fixtures are green on both
arms, so their own refusal set is empty — the useful question is what a
*realistic* program needs that they avoid. Measured with a 12-program
differential sweep (both arms, both binaries, stdout byte-compared) over the
shapes the fixtures do not have:

| shape | before this unit | after |
| --- | --- | --- |
| a user ADT printed (`Circle 7`) | REFUSED (`Con`) | PASS |
| a nested constructor (`Wrap (Square 3 4)`) | REFUSED | PASS |
| a `String` payload in a constructor | REFUSED | PASS |
| a tag test on a PARAMETER (no `Con` in the defun) | REFUSED (`MTagEq`) | PASS |
| a two-argument constructor, both binds used | REFUSED | PASS |
| a nested tag test (`Wrap inner` -> `inner`) | REFUSED | PASS |
| a list of ADTs, folded | REFUSED | PASS |
| `==` on ADTs (deep equality over the vector body) | REFUSED | PASS |
| a recursive tree built by 6000 inserts | REFUSED | PASS |
| zero-argument constructors | REFUSED | PASS |
| a tag test inside a bind (nested `case`) | REFUSED | PASS |
| `let ( a, b ) = ...` | REFUSED | **still REFUSED — loudly, and correctly: it is the next class** |

That last row is the polarity working: the sweep found the next class rather
than a defect, and it stayed a loud named refusal instead of a half-working
emit. (The class has since been PORTED — see the let-destructuring section; note
that the sweep's `let ( a, b ) = ( 1, "hi" )` shape is NOT the one that proves
it, because Flatten substitutes a literal scrutinee and the destructuring never
reaches the emitter. `tools/qbe/word-arm-diff/letdestr.elm` is the fixture that
does, and `letpat.elm` is the one that does not.)

## The shape of the answer, in one line each

1. The runtime surface (`runtime.mid`) refuses **nothing** any more; every
   remaining blocker is the compiler's surface classifier.
2. 34 of 159 corpus groups cannot compile on **either** arm — they are not the
   word arm's problem, and a table that omits this control is wrong by 2/3.
3. The top of the first-refusal ranking (`Con`/`MTagEq`, 41 and 39 groups) was
   **two stale refusals**; porting them cost one fork and moved the arm from 74
   to 88 compiling groups.
4. **`let` destructuring — 26 groups, 26 of them alone** — was the next class,
   and it moved **19** of the 26: the binding path is the `Case` matcher's, so
   the port itself was one classifier admission, but the seven `Platform.program`
   groups it unblocked are wrong at RUN time (the host loop's 40-byte-stride
   blob) and now refuse by name. The word arm went from 88 to 107 compiling
   groups; WORD-BLOCKED 37 -> 18.
5. The class after that is **floats** (10 groups carry a float literal, 9 of them
   blocked by nothing else, plus 2 `f/` groups of which one is the same group),
   and it carries the `mk*`-as-safepoint obligation from WORKLIST item 5 in the
   same unit.
