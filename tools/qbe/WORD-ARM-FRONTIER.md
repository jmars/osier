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
backend twice — once on the val arm (`QBE_VALREP=val`), once with
`QBE_VALREP=word` — and classify:

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

### STEP 0 — the float-literal refusal is STALE, and that is MEASURED, not read

BEFORE ANY EMITTER CODE, the question this arc asks first: does the refusal
describe a path the emitter takes? The float literal had TWO texts:

* emit site (`Lower.elm:7586`) — `a float literal — the word arm heap-boxes a
  float as a [hdr | f64] cell, WHICH DOES NOT EXIST YET`;
* classifier (`Lower.elm:784`) — `a float literal — under the word arm it is a
  HEAP object behind one tagged pointer, not a tag word plus payload words`.

The first half of both is a correct DESCRIPTION. The claim is the last three
words of the first — and it is FALSE: `storeWordFloatCell` (`Lower.elm:4890`)
has built exactly that cell since perf word-arm-area3rt, for the runtime's
`mkflt` lane, allocating through `Rt.allocFloat` (`runtime.mid:2718`) and storing
the f64 at body unit 0. The second text is not a claim at all, which is the same
shape `Con`'s refusal had.

`f/` is stale the same way, and it names the same cell: `wordArmPrimUnported`'s
entry says "`Rt.f/` is float-only, so routing it to the runtime would build the
same cell" — and `Rt.f/` IS `mkflt(fload(asF a) f/ fload(asF b))`, i.e. exactly
the two writers that exist. So the class is **two classifier admissions**, and
the unit's real work is finding the FRESH defect an admission exposes — which is
what every previous class in this arc turned out to be.

THE FRESH DEFECT, AND HOW IT WAS FOUND. Admitting the literal in a scratch build
emitted the cell correctly and then CRASHED at run time: `RawLoadFlt` (`fload`)
read `slot + 8` unconditionally — the val arm's 40-byte payload word, which on
this arm is THE NEXT FRAME SLOT — and it carried its own standing instruction
("WHEN AREA 5 LANDS, THIS SITE MUST BE FORKED IN THE SAME UNIT"). It is the site
EVERY float reader goes through: `Rt.asF`, `Rt.toI32`, `Rt.fRender` (hence
`Rt.floatText` and the whole printer) and the float arms of
`Rt.+ - * f/ < <= > >= =`. So the port is the cell's admission PLUS the read's
fork, and the read is where the defect was.

MEASURED, with the fork switched off (`if False && wordArm s2`) and
`compiler.js` rebuilt: `floatlit`, `floatarith` and `strunit` died **SIGABRT
(134) with empty stdout AND empty stderr**, while `floatcmp` still PASSED — it
compares a float and never prints one. That asymmetry is why the unit carries a
TEXT pin as well as a behavioural row.

### float literal + `f/` — PORTED: all 11 groups run byte-identically on both arms

`cmporder floatarith floatcmp floatdiv floatfun floatineq floatlit floatmix
mxint strunit` (float literal) and `floatdiv floatpartial` (`f/`), defuns
`Floatarith.main Floatcmp.main Floatdiv.main Floatfun.area Floatineq.main
Floatlit.main Floatmix.main MxInt.circleArea MxInt.main`, `/.curried`,
`Runtime.*` none.

**WHAT IT EXPOSED: THE READ, NOT THE CELL — `RawLoadFlt` (`fload`).** The site
read `slot + 8` unconditionally: the val arm's 40-byte payload word, which on
this arm is THE NEXT FRAME SLOT. It carried its own standing instruction ("WHEN
AREA 5 LANDS, THIS SITE MUST BE FORKED IN THE SAME UNIT") and every float reader
in the runtime goes through it — `Rt.asF`, `Rt.toI32`, `Rt.fRender` (hence
`Rt.floatText` and the whole printer) and the float arms of
`Rt.+ - * f/ < <= > >= =`. It is forked to `wordFloatPayload`: untag, body unit
0, `loadd`, plus a NAMED `Rt.die` for a word that is not a heap object.

**PROVEN BY ASYMMETRY, not asserted.** With the fork switched off
(`if False && wordArm s2`) and `compiler.js` rebuilt: `floatlit`, `floatarith`
and `strunit` died **SIGABRT (134) with empty stdout AND empty stderr** — and
`floatcmp` still PASSED, because it compares a float and never prints one. That
last row is why the text pin exists beside the behavioural one.

**THE `mk*` SAFEPOINT OBLIGATION, DISCHARGED IN THE SAME UNIT.** WORKLIST item 5
recorded that `Mid.Rt.unsafeSafepoint` treats a `RawMkValue` as a non-safepoint,
which is true on the val arm and false for a word-arm cell whose writer
allocates. The arm is now threaded into the walker (`loadArm` -> `loadText` ->
`directArm`/`safepoint`/`unsafeSafepoint`) and the answer is ONE statement,
`RtLayout.wordMkAllocSeat`, which names `Rt.allocFloat` for `tagFloat` and
NOTHING for every other code. **THE OLD WORDING WAS HALF STALE TOO**: `mkstr`
allocates nothing since perf word-arm-rawroot put a string's bytes inline in the
block `Rt.allocRaw` already made, so a blanket "heap codes allocate" rule would
have rooted the collector's own defuns — the negative control the row asserts.
MEASURED per arm: `Rt.asF` (whose only allocation is its `mkflt`) opens
`call $q_Rt_x2eframe_x2denter` on the word arm and a bare `alloc8 120` on the val
arm.

**AND THE CHURN LADDER IS COVERAGE, NOT THE PROOF — MEASURED, NOT ASSUMED.**
With `unsafeSafepoint`'s arm reverted to non-safepoint, all four
`tools/qbe/word-arm-gcchurn/flt.elm` rungs stay GREEN (h1 136/182, h2 126/170,
h4 62/84, default 4/7 collections; `6000/6000/0` both arms), because every
current `.mid` `mkflt` site consumes its live value BEFORE the allocation — safe
by order, the shape the worklist predicted. So the rule's pin is the
CLASSIFICATION row (per arm, both directions, on synthetic `mkflt`/`mkstr` probes
AND on the real defun), and the ladder is what keeps the new allocation window
running under collection.

**THE APP-ARGUMENT WALK: MEASURED, AND NOT ENABLED.** `wordArmUnportedList`
admits `App` without recursing into its arguments, which is why `strunit` and
`cmporder` used to refuse with an UNNAMED line. Walking them was tried here and
REVERTED, with the reason measured: it turns 5 corpus groups out of BOTH into
WORD-BLOCKED, because `StreamRef` reaches the walk and the classifier has no arm
for it — it falls through to the catch-all, whose text is a SEVENTH stale blanket
refusal (the site is `lowerLit (LSymbol v)` + `rtPrimSlots "value"`, both ported).
Admitting it on emit-only evidence would repeat the let-destructuring mistake, so
the walk stays off and the finding is recorded: **enabling it owes a `StreamRef`
decision plus runs of the 14 groups it blocks** (`execbig execchain execenv
execglob execmal execnofile execpipe execsubchain ioecho iofile readfile
taskattempt taskpure taskseq`, defuns `Runtime.readLineGo`/`Runtime.writeString`).

**THE RESULT.** All 11 groups emit, link and print BYTE-IDENTICALLY on both arms
(`2.0`, `4.0`, `true`, `3.5`, `true`, `3.5`, `12.0` for `area 2.0`, `3.5`,
`175`, the `strunit` digit string ending `|42.5|2.0`, and `cmporder`'s
`LT GT EQ …`). The two oracles are `tools/qbe/word-arm-diff/floatlit.elm` (a
DIFFERENTIAL over the literal, `+ - * f/`, `<`, `==` against an Int, the
shortest-round-trip printer path `0.1 + 0.2`, `1e300`'s 64-byte truncation, and
float cells inside cons cells) and `tools/qbe/word-arm-gcchurn/flt.elm` (the
collecting ladder above). Both fixtures route every float through a DEFUN, so
Flatten cannot substitute the literal away — the mistake the previous unit's
review caught in its own fixtures.

### The census after the float port

```
BOTH           118
SAME-ERROR      34
WORD-BLOCKED     7

GROUPS  ALONE  CLASS
     7      7  host program path (`Runtime.program`)
```

The float-literal and `f/` classes are GONE (0 groups). 107 -> 118 compiling
groups; WORD-BLOCKED 18 -> 7. The only class left is the host blob, which is a
`runtime.mid` STRIDE job (the event loop's state is one malloc'd blob laid out
with the val arm's 40-byte stride and registered with a collector whose scan
stride is the layout's), not a construct the classifier refuses.

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
5. **Floats (10 groups) and `f/` (2)** were the class after that, and they are
   **PORTED**: all 11 groups run byte-identically on both arms, the `mk*`
   safepoint obligation from WORKLIST item 5 is discharged in the same unit, and
   the fresh defect was the READ (`fload`), not the cell — which already existed
   under a refusal that said it did not. The word arm went 107 -> 118 compiling
   groups; WORD-BLOCKED 18 -> 7.
6. **The one class left is the host program path** (7 groups, 7 alone,
   `Runtime.program`), and it is the first frontier in this arc that is NOT a
   classifier admission: the event loop's state is one malloc'd blob laid out
   with the val arm's 40-byte stride while the collector scans it at the
   layout's, so the blob size, the slot array stride and every `* 40` move
   together. `StreamRef` is the classifier's remaining CONTROL (not a plan), and
   the `App`-argument walk that would name it in a census owes 14 runs first.

## STEP 0 (perf word-arm-hostpath): THE HOST PATH'S SITE COUNT, ENUMERATED

The count was never established, and this section exists because three different
numbers were in circulation and **all three were undercounts of the same
family**. The brief said 32, an implementer's record said 29, and a raw
word-boundary `\b40\b` scan over the `Rt.host*` defuns numbers about 30. What
none of them did was decide **region membership** — which is what actually
separates a site that must be twinned from a `40` that must not.

### The enumeration, and what decides membership

THE UNIVERSE, COUNTED (this paragraph was WRONG and is corrected here, per the
hostpath review's NICE 3 — the thesis stood, the arithmetic did not). A raw
word-boundary `\b40\b` scan over non-comment lines of
`osier-compiler/runtime.mid` at `5ec1e95` finds **87 lines / 95 occurrences**.
The table below classifies **84** of those lines. The other **3** are the frame
SIZING expressions — `Rt.frameBlock`'s two `40 + … * nslots` byte-size lines and
`Rt.frame-enter`'s `memset(base, 0, 40 * nslots)` — which are a different shape
(the header is 40 bytes on BOTH arms; only the slot term moves) and are covered
by their own rows, so they are not in a class here. An earlier revision said
"every code line carrying a word-boundary 40" over a table that summed to 84;
that statement is what is fixed, not the classification.

Each line is classified by (i) the defun that owns it and (ii) whether it is a
**Value stride** — an address into an array of `val`s, whose element width IS
the layout's — or one of the four things that merely look like one.

| class | lines | unit, stated | twin? |
|---|---|---|---|
| **T — Value stride, host family** (`Rt.host*`) | 38 | lines carrying a literal `40` (44 occurrences) | **YES** |
| **T — Value stride, `Rt.apply-at`** | 1 | lines carrying a literal `40` | **YES** |
| **T — Value stride, `Rt.callArity`** | 15 | lines carrying a literal `40` (+105 more `buf + 80…600` on the same lines) | **YES** |
| **B — byte offset / buffer length** | 3 | lines carrying a literal `40` | no |
| **C — C-struct stride** | 7 | lines carrying a literal `40` | **must NOT** |
| **S — a struct that is genuinely 40 bytes of words** | 2 | lines carrying a literal `40` | no |
| **P — the entry-argument family** (a pitch plus its readers) | 17 | **NOT** lines carrying a literal `40`: the lines of `Rt.main`/`Rt.parseArgsGo`/`Rt.parseArg` that carry `40`..`600`, of which only **2** carry the literal `40` (`a1 = abuf + 40`, `bufW + j * 40`) | **YES — perf word-arm-corpusrun** (see below; the old "no" was the defect) |
| **D — dead / over-allocated single cell** | 1 | lines carrying a literal `40` | no |

**54 stride lines must be twinned**, in three defun families. That is the
number this file carried at `5ec1e95`, and it is a count of LINES because a line
is the unit the arm splice works in (one line may carry two strides —
`Rt.hostCompleteOk`'s
`vecstore(h + 8 + (33027 * 40), 0, vecload(h + 8 + ((lp->evals[i].base + 1) * 40), 0))`
carries two, and both move). **The P row's `no` was the one wrong answer in this
table**, and it was wrong in the direction that DROPS LIVE VALUES: the pitch is
read by a KIND-2 GC ROOT, not only by its own writer — see "THE ENTRY-ARGS ROOT
GAP" below.

**THE LAYOUT SOURCE IS NOT A `40` AT ALL**, and a text scan cannot see it: the
stride's origin is `struct Host`'s `slots : val[33031]` (`runtime.mid:741`).
`Mid.RtLang.Check` sizes a `val` field at 40 bytes under ANY knob
(`fieldTySize`'s `TVal -> Ok ( 40, 8 )`, no layout parameter — `Check.elm:1757`),
so `lp->evals`, `lp->npoll` and `lp->poll` land at 1321296 / 1861968 / 1861976
because of that ONE field. Twinning the malloc literal while leaving the field
`val[33031]` is the silent overrun the file's own note (`runtime.mid:5743-5756`)
names: the blob would be 804992 bytes with the checker still writing `evals` at
1321296. **The port's first move is therefore not a `40` — it is that field**,
and the word arm's `struct Host` carries no `val` field at all, which is what
makes the checker's hardcoded 40 harmless here rather than fixed.

### T — the 54 stride lines, by defun

`Rt.hostInit` 2 (the malloc literal `8 + (33031 * 40) + (6 * 8) + (128 * 4224) + 16`,
and `blob + 8 + 40` — the update-fn slot); `Rt.hostReadFileComplete`,
`Rt.hostLeafReadFile`, `Rt.hostSleepComplete`, `Rt.hostExecComplete`,
`Rt.hostLeafListDir`, `Rt.hostListDirChunk`, `Rt.hostStatRecord`,
`Rt.hostLeafExec` (2) 1 each — all `h + 8 + ((lp->evals[i].base [+ 1]) * 40)`;
`Rt.hostCall` 2 (33027, 33029); `Rt.hostClearGo` 1; `Rt.hostSpawnAt` 1;
`Rt.hostSpawnFromCmd` 2 (33030 ×2); `Rt.hostPushFrame` 1 line / 2 strides;
`Rt.hostDispatch` 4 lines (base, `taskAddr + 40`, 33030 ×2);
`Rt.hostCompleteOk` 4 lines / 6 strides; `Rt.hostCompleteErr` 4 / 6;
`Rt.hostDeliver` 6 (33027, 33028, `h + 8 + 40`, 33029, 33026 ×2);
`Rt.hostRun` 2 (33026 ×2); `Rt.apply-at` 1 (`buf + rem * 40`);
`Rt.callArity` 15 (`buf + 40` … `buf + 600`, the `rt_callN` dispatch chain).

**`Rt.callArity` is the site the three circulating counts all missed**, and it
is not a rounding error: it is 15 of the 54 lines and 120 individual offsets.
It is also the one that makes the class a SILENT-WRONG rather than a crash:
`Rt.apply-at`'s `napp == 0` arm — the arm every global closure of arity ≥ 2
takes — hands `Rt.callArity` a slice of the ROOTED SLOT ARRAY as `buf`, and
`rt_callN` loads each argument through the pointer it is given. At a 40-byte
pitch against an 8-byte slot array, argument *k* is read from slot *5k*.

### B, C, S, P, D — the `40`s that must NOT be twinned

* **B (3).** `Rt.fRender`'s `strfromd(s + 72, 40, fmt, …)` — a buffer LENGTH.
  `Rt.epChain`'s `cbufW + 40` and `Rt.hostEpCbuf`'s `c + 40` — BYTE offsets into
  the 336-byte interned-symbol cbuf (`"cons"`@0, `"string"`@8, … `"and"`@40).
* **C (7).** `Rt.epPipeline`'s `malloc(cnt * 40)`, `Rt.epPipeGo`'s `iW * 40`,
  `Rt.epFreeCmds`, `Rt.wirePipeGo`, `Rt.closePipeTmpfds`, `Rt.closeOthersGo`,
  `Rt.execGo`'s `*CmdState cmdN = [word](cmdsArr) + (iW * 40)` — the exec-plan
  DECODE records. `struct CmdState` is five `word` fields = 40 bytes, `struct
  Redir` six = 48: plain C records with **no `val` field**, so their 40 and 48
  are STRUCT sizes and twin to nothing. (`runtime.mid:5752` already said so; this
  table is the measurement that keeps it true.)
* **S (2).** `Rt.frame-enter`'s `base = [word](hdr) + 40` — `struct FrameHdr` is
  `live/wm/next/freeNext/_pad`, five words = 40 bytes **on both arms**, which is
  why `Rt.frameBlock` keeps `40 + 8 * nslots` on the word arm and only the slot
  term moves. `Rt.main`'s `mblk = malloc(40)` — a five-word `{base, entry,
  metaN, code, arity}` block, not a Value.
* **P (17) — TWINNED, AND THIS BULLET WAS THE FILE'S ONE WRONG ANSWER.** What it
  said: the entry-argument buffer (`Rt.main`'s `malloc(648)`,
  `wstore(abuf, 80, entry_nargs)`, `rootPushValueArray(abuf, abuf + 640)`,
  `a1 … a15 = abuf + 40 … + 600`, `Rt.parseArgsGo`'s
  `bufW + (payload(j, 0) * 40)`) is "correct on both arms", because "the writer
  and the reader use the SAME pitch" and "the collector's registration
  over-scans harmlessly (80 cells at the word arm's 8-byte stride over a
  640-byte region whose unwritten cells are `memset` zeros)". **BOTH HALVES ARE
  FALSE FROM THE CODE**, and the direction of the error is the one that DROPS
  LIVE VALUES:
  - A kind-2 root's COUNT is the i32 at its `np` (`Rt.gcScavRoots` /
    `Rt.gcMarkRoots`), and `np` is `abuf + 640` — the cell
    `wstore(abuf, 80, entry_nargs)` writes, so the count is `entry_nargs`, NOT
    80. `malloc(648)` is never `memset`, so the region's unwritten cells are not
    "memset zeros" either.
  - With the scan stride being the LAYOUT's (8 on the word arm), a count of
    `nargs` covers `8 * nargs` bytes of a region whose args sit at `40 * j`:
    **arg 1 is outside the root for any `nargs <= 5`**, arg 2 for `nargs <= 10`.
    A float entry argument is a HEAP cell (`Rt.parseArg` -> `mkflt`), so a
    scavenge in the window `[rootPushValueArray, rt_callN]` — the window
    `Rt.argvInstall` allocates in — would have handed the entry a STALE Value.
  - The `M.go 1 2 3` probe could not see it: fixnum arguments are immediates and
    nothing forced a collection in that window.
  THE FIX (perf word-arm-corpusrun): the pitch is the layout's on both arms —
  `Rt.parseArgsGo` writes at `8 * j` and `Rt.main`'s readers are
  `a1 … a15 = abuf + 8 … + 120` under `QBE_WORDVAL-ONLY`, with the val arm's
  `40 * j` / `+ 40 … + 600` untouched. The registration then says exactly what
  the region is: `nargs` Values at the arm's stride, and the count cell at byte
  640 is outside both regions (8\*16 = 128 on the word arm, 40\*16 = 640 on the
  val arm — the cell starts AT 640). See "THE ENTRY-ARGS ROOT GAP" below for the
  measurement, the pins and the part that cannot be exercised by a collection
  today.
  **AND THE ROW IS STILL WHY A TEXT SCAN IS NOT A CLASSIFICATION**: P and T are
  the same characters — `base + k * 40` — and only the question "whose stride is
  this?" tells them apart. The text scan answered it wrong; the CODE answered it
  right.
* **D (1).** `Rt.main`'s `modelslot = malloc(40)` — ONE Value cell. The word arm
  reads it through `vecload`, which is layout-derived, so it reads correctly at
  offset 0 out of an over-allocated 40-byte block. Over-allocation is not a
  defect.

### What the count does NOT include, and must not be read as including

`struct HostEv`'s 4224-byte stride (`128 * 4224` in the malloc, `sizeof(HostEv)
== 528 words`) does **not** move: it is four header words + 256 two-word
`HostFrame`s + `etag` + an 11-word effect union, and `HostFrame` is
`{kind, cont}`, two WORDS. `HostEv` holds no `val`, so the eval table's stride is
arm-independent and the malloc literal's only moving term is the slot array.
`sizeof(HostPoll) * 8` is likewise arm-independent.

## THE CORPUS RUN (perf word-arm-corpusrun): ALL 125 BOTH GROUPS, RUN ON BOTH ARMS

`tools/qbe/word-arm-corpusrun.sh`.  This is the first corpus-wide BEHAVIOURAL
test the word arm has ever had, and it exists because **`WORD-BLOCKED=0` proves
nothing refuses, not that anything is correct**.  The census counts EMITS; the
running coverage before this row was 21 `word-arm-diff` fixtures + 12 gcchurn
rows + two hand-run subsets (26 `let`-destructuring, 7 host) — not the corpus.
This arc's own evidence that the difference is real is the host path: 7 groups
printed `[vector 4]` with **rc 0 and no stderr** and the census was green over
them.  So: every group the census calls `BOTH` is built **both ways** (val:
`QBE_VALREP=val` EXPLICITLY; word: `QBE_VALREP=word`), assembled through the same
vendored qbe, linked with cc, and RUN on both ways.

### What the number is now

| | |
| --- | --- |
| groups the census calls `BOTH` | **125** |
| RUN on both arms | **125** (126 runs: `sub` is registered twice) |
| **IDENTICAL** — same exit code AND byte-identical stdout | **125** |
| DIFFERING | **0** |
| crashed or hung (a timeout is a FAILURE, not a skip) | **0** |
| stderr also byte-identical | **126 / 126 runs** |
| `SAME-ERROR` groups (not runnable on either arm) | 34 |

So the sentence the flip turns on is: **125 of the 125 BOTH groups are PROVEN to
behave identically on the two arms**, not "125 groups emit IL".  122 of the 125
exit 0; 3 exit 1 identically (`execmal` — the malformed-exec-plan halt fixture,
whose only observable is its diagnostic; and `rowgadt_select`/`rowgadt_setx`,
which are `compile_clean` groups run with no argument — see the convention note).

### The conventions, stated because a corpus run's numbers are only as good as them

* **ARGUMENT VECTORS COME FROM THE GATE'S OWN REGISTRY.**  A group is a fixture
  + an entry, and the values the entry is called with are declared per CHECK, not
  per group, so the vectors are read from `ELM_GATE_MATRIX=1`: every distinct
  `(args, stdin)` registered for the group's `(fixture, entry)` by a RUNNING
  helper (`run`/`run2`/`run_io`) is run on both arms — 120 vectors.  That is
  strictly more than one run per group, and it is the part that matters for the
  entry-argument path (`sub` is registered twice with the arguments SWAPPED).
* **THE SIX `compile_clean` GROUPS ARE RUN WITH NO ARGUMENT AND LABELLED.**  The
  gate never runs them by design (their value cannot be driven from argv), so
  their entry is called with an argument it was never given.  That is undefined
  INPUT, not a representation difference: both arms get the same bytes and both
  behave the same way (`rowgadt_select`/`rowgadt_setx` die with the same
  `non-exhaustive case` and rc 1), but the row is marked `no-vector` in the table
  so nobody reads it as a driven run.
* **CWD IS THE REPO ROOT**, which is the gate's own convention and a hard
  requirement: eight fixtures resolve repo-root-relative paths (`iofile` writes
  `tests/elm-fixtures/out/hello.out`), and the gate refuses to run anywhere else
  for exactly that reason.
* **STDIN** is the registered file for a `run_io` row and `/dev/null` otherwise
  (the gate lets a `natrun` row inherit stdin; that is not a property of the
  program).  **TIMEOUT 20 s, and a timeout is a FAILURE** — a wrong count or
  stride LOOPS instead of crashing, and a gate that hangs reports nothing.
* **STDERR IS COMPARED, INFORMATIONALLY, NOT FATALLY.**  The arms are allowed
  different diagnostics; what is asserted is exit code + stdout.  It is measured
  because a row whose only observable is its diagnostic (`execmal`) would
  otherwise be credited as identical on rc alone.  MEASURED: it is byte-identical
  on all 126 runs, so no row needed the weaker reading.

### A TEST THAT CANNOT FAIL IS NOT A TEST — the asymmetry, measured

The row was PROVEN fail-able in both directions before it was believed.  With ONE
TOKEN of the word arm mutated — `Rt.callArity`'s arity-2 word twin,
`buf + 8` -> `buf + 40` (`runtime.mid`, the stride the whole 54-line family
exists to get right) — and `compiler.js` rebuilt:

```
  ... IDENTICAL                123
  ... DIFFERING                  2
  asyncorder  [no args] EXIT val=0 word=139   (SIGSEGV)
  asyncpure   [no args] EXIT val=0 word=139
```

exit 1.  Reverted, the row is `125 / 125 identical`, exit 0.  So the green is a
measurement, not a tautology — and note how FEW groups that mutation moved: a
representation defect can be invisible to 123 of 125 groups, which is exactly why
this row is a floor over the corpus and not a proof that every site is right.

### What this number does NOT mean

1. **One vector per group, mostly.**  The 125 groups carry 120 registered
   vectors, so a group registered once is proven for THAT argument vector, not
   for every input it can take.  The word arm's own diff/gcchurn fixtures
   (`tools/qbe/word-arm-diff/`, `word-arm-gcchurn/`) stay the instruments for the
   shapes the corpus does not build.
2. **It does not cover the 34 `SAME-ERROR` groups** (they refuse on both arms —
   a language behaviour, not an arm gap) and it cannot: there is no binary.
3. **It says nothing about collections.**  These fixtures allocate far below one
   GC trigger, so a ROOTING defect is invisible here — that is
   `word-arm-gcchurn.sh`'s axis, and the corpus run does not replace it.
4. **STREAMS ARE NOW RUN, AND THAT CLOSES THE CENSUS'S BOTH-COLUMN CAVEAT.**
   The floats unit recorded that 14 groups (`execbig execchain execenv execglob
   execmal execnofile execpipe execsubchain ioecho iofile readfile taskattempt
   taskpure taskseq`) contain a `StreamRef` and sat in `BOTH` on EMIT-ONLY
   evidence, and that `fdstream` was val-only in the gate.  All 14 now RUN on
   both arms here and are identical, `fdstream` included.  What remains true is
   narrower and should still be carried into VR3d's record: the `App`-argument
   walk that would make `StreamRef` a CENSUS class is still OFF — the floats
   unit MEASURED that turning it on moves 14 groups under a new class and takes
   BOTH from 118 to 102 — so streams are covered by THIS row, not by the
   classifier, and this row is the only place they are RUN.

### The table

`VECS` is the number of argument vectors run for the group; `RC` is the exit code
both arms returned; `B` is the byte length of the byte-identical stdout.

```
  adtcase                  1    0        identical, 3 B
  adteval                  1    0        identical, 3 B
  appendres                1    0        identical, 2 B
  applytwice               1    0        identical, 3 B
  arraybasic               1    0        identical, 6 B
  arraystress              1    0        identical, 8 B
  asyncorder               1    0        identical, 11 B
  asyncpure                1    0        identical, 6 B
  biglist                  1    0        identical, 8 B
  bitwise                  1    0        identical, 4 B
  boolcase                 1    0        identical, 2 B
  closure                  1    0        identical, 2 B
  cmporder                 1    0        identical, 56 B
  const                    1    0        identical, 3 B
  countcase                1    0        identical, 2 B
  countdown                1    0        identical, 2 B
  crossref                 1    0        identical, 3 B
  curry                    1    0        identical, 2 B
  dictbasic                1    0        identical, 6 B
  dictstress               1    0        identical, 8 B
  dirunit                  1    0        identical, 28 B
  div                      1    0        identical, 3 B
  eqlist                   1    0        identical, 5 B
  execbig                  1    0        identical, 13 B
  execchain                1    0        identical, 23 B
  execenv                  1    0        identical, 15 B
  execglob                 1    0        identical, 267 B
  execmal                  1    1        identical, 0 B
  execnofile               1    0        identical, 54 B
  execpipe                 1    0        identical, 8 B
  execsubchain             1    0        identical, 10 B
  extrec                   1    0        identical, 3 B
  fastexec                 1    0        identical, 9 B
  fdstream                 1    0        identical, 2 B
  fib                      1    0        identical, 3 B
  floatarith               1    0        identical, 4 B
  floatcmp                 1    0        identical, 5 B
  floatdiv                 1    0        identical, 4 B
  floatfun                 1    0        identical, 5 B
  floatineq                1    0        identical, 5 B
  floatlit                 1    0        identical, 4 B
  floatmix                 1    0        identical, 4 B
  floatpartial             1    0        identical, 4 B
  insrec                   1    0        identical, 4 B
  ioecho                   1    0        identical, 14 B
  iofile                   1    0        identical, 14 B
  letcase                  1    0        identical, 2 B
  letclosure               1    0        identical, 3 B
  letdeeprec               1    0        identical, 6 B
  letread                  1    0        identical, 3 B
  lexselftail              1    0        identical, 7 B
  liftcapconfl             1    0        identical, 3 B
  liftcapconfl2            1    0        identical, 3 B
  liftcycshadows           1    0        identical, 2 B
  liftdelegate             1    0        identical, 2 B
  liftdelegmut             1    0        identical, 2 B
  liftdisjoint             1    0        identical, 3 B
  liftdisjointshadow       1    0        identical, 2 B
  liftenclosing            1    0        identical, 4 B
  liftfirstclass           1    0        identical, 4 B
  liftfwd                  1    0        identical, 2 B
  liftfwdback              1    0        identical, 2 B
  liftfwdmix               1    0        identical, 3 B
  liftmodfwd               1    0        identical, 4 B
  liftmutual               1    0        identical, 3 B
  liftnested               1    0        identical, 5 B
  liftnestedfinal          1    0        identical, 5 B
  liftnestedrec            1    0        identical, 4 B
  liftnestedtuple          1    0        identical, 5 B
  liftprelfwdfn            1    0        identical, 5 B
  liftprelude              1    0        identical, 2 B
  liftpreludefwd           1    0        identical, 2 B
  liftrelaxleak            1    0        identical, 4 B
  liftself                 1    0        identical, 4 B
  liftseqcap               1    0        identical, 2 B
  liftshadow               1    0        identical, 3 B
  liftstaycall             1    0        identical, 4 B
  liftstayfwd              1    0        identical, 4 B
  listcase                 1    0        identical, 3 B
  multimod                 1    0        identical, 3 B
  mxint                    1    0        identical, 4 B
  mxstring                 1    0        identical, 20 B
  nested                   1    0        identical, 2 B
  nowunit                  1    0        identical, 18 B
  opvalue                  1    0        identical, 2 B
  overapply                1    0        identical, 3 B
  p2pad                    1    0        identical, 72 B
  partial                  1    0        identical, 2 B
  patterns                 1    0        identical, 5 B
  readfile                 1    0        identical, 55 B
  recalias                 1    0        identical, 3 B
  records                  1    0        identical, 3 B
  refutpos                 1    0        identical, 2 B
  remrec                   1    0        identical, 2 B
  resultmaybe              1    0        identical, 60 B
  rmprobe                  1    0        identical, 2 B
  rowgadt_dup_rebuild      1    0        identical, 2 B  (no-vector)
  rowgadt_eval             1    0        identical, 16 B
  rowgadt_fsm              1    0        identical, 10 B
  rowgadt_fsm_nested       1    0        identical, 10 B
  rowgadt_het              1    0        identical, 6 B
  rowgadt_hget             1    0        identical, 2 B  (no-vector)
  rowgadt_hget_bare        1    0        identical, 2 B  (no-vector)
  rowgadt_l3i              1    0        identical, 4 B
  rowgadt_l3iii            1    0        identical, 2 B
  rowgadt_select           1    1        identical, 0 B  (no-vector)
  rowgadt_setx             1    1        identical, 0 B  (no-vector)
  rowgadt_shape_rebuild    1    0        identical, 2 B  (no-vector)
  rowpoly                  1    0        identical, 3 B
  rtl1                     1    0        identical, 2 B
  rtl2                     1    0        identical, 3 B
  scopedup                 1    0        identical, 3 B
  selfqual                 1    0        identical, 3 B
  setops                   1    0        identical, 4 B
  shortcircuit             1    0        identical, 2 B
  statplus                 1    0        identical, 14 B
  statunit                 1    0        identical, 77 B
  strings                  1    0        identical, 14 B
  strunit                  1    0        identical, 69 B
  sub                      2    0        identical on every vector
  subpartial               1    0        identical, 2 B
  symeq                    1    0        identical, 2 B
  taskattempt              1    0        identical, 7 B
  taskpure                 1    0        identical, 3 B
  taskseq                  1    0        identical, 2 B
```

## THE ENTRY-ARGS ROOT GAP (perf word-arm-corpusrun): THE DOC WAS WRONG, AND IN THE DIRECTION THAT DROPS LIVE VALUES

This section replaces the P bullet's old verdict. The hostpath review called it
FLIP-GATING and it was right: the flip makes the word arm the DEFAULT for exactly
the arg-heavy invocations (selfhost binaries take several entry args), so a root
that under-covers is the worst thing to turn on.

### What the code says (read, not inferred)

| claim | verdict |
| --- | --- |
| "the registration over-scans harmlessly (80 cells …)" | **FALSE.** A kind-2 root reads its COUNT from the 4 bytes at `np` (`Rt.gcScavRoots` ~:6669, `gcMarkRoots` ~:6837). `np` is `abuf + 640`; `wstore(abuf, 80, entry_nargs)` writes word 80 = byte 640, and `wstore`'s index IS a word index, so the count is **`entry_nargs`**, not 80. |
| "over a 640-byte region whose unwritten cells are `memset` zeros" | **FALSE.** `abuf = malloc(648)` and nothing memsets it. The "80 cells at the word arm's 8-byte stride" is the count 80, which never happens. |
| the scan covers the args | **FALSE ON THE WORD ARM.** The scan stride is the layout's (8) and the count is `nargs`, so it covers `[abuf, abuf + 8*nargs)` while `Rt.parseArgsGo` wrote the args at `40 * j`. Arg 1 is outside for `nargs <= 5`; arg 2 for `nargs <= 10`. |
| "agreed by writer and reader, so correct" | **TRUE AND INSUFFICIENT.** It is true of the ENTRY CALL (`a_j = abuf + 40j` reads what the writer wrote), which is why `M.go 1 2 3` answered `123` on both arms. It says nothing about the COLLECTOR, which reads the region at a different stride. A third reader with its own convention is what the "agreed" argument missed. |

The live values at risk are FLOAT entry arguments — the only heap-boxed entry
args (`Rt.parseArg` -> `mkflt`); ints are immediates. The exposing window is
`[rootPushValueArray(abuf, abuf+640), rt_callN]`, i.e. `Rt.argvInstall`'s
allocations: a scavenge there moves a float cell and leaves `abuf`'s slot naming
the old block — a stale Value, rc 0, silent.

### The fix, and why this shape rather than the cheaper one

The pitch is now the layout's on both arms: `Rt.parseArgsGo` writes at `8 * j`,
`Rt.main`'s readers are `a1 … a15 = abuf + 8 … + 120` under
`QBE_WORDVAL-ONLY`; the val arm's `40 * j` / `+ 40 … + 600` are untouched (the
corpus is still **159/159 BYTE-IDENTICAL**, no re-freeze). The abuf `malloc(648)`
and the count cell at byte 640 do NOT move: the region is now `nargs` Values at
the arm's stride (128 B at the 16-arg bound on the word arm, 640 B on the val
arm) and the count cell starts exactly where the val arm's region ends — outside
both, which it must be, since it holds a raw i64 count rather than a Value.

THE CHEAPER SHAPE, CONSIDERED AND REJECTED: keep the 40 pitch and register
`count = 5 * nargs` on the word arm (a stride-8 scan over `40 * nargs` bytes hits
each arg at slot `5j`, and the zeros between are the fixnum 0). It is correct and
it is ONE line — but it keeps a private pitch whose count must be re-derived on
every future layout change, i.e. exactly the second convention that produced this
defect, and it makes the region un-walkable by anything else. The twin matches
the runtime's other arg arrays (`Rt.apply`/`Rt.stage-apply` register `nargs`
Values at the layout's stride).

### The oracles (two, and both are proven fail-able)

1. **TEXT, both sides, per arm** — TestMain's two new `ENTRY-ARG PIN` rows: the
   word splice carries `* 8` and `+ 8 … + 120` and NEITHER splice carries the
   other's pitch, and the ARITHMETIC row pins that the count and the region agree
   per arm and that the count cell lies outside both. MEASURED FAIL-ABLE: with
   the word reader block reverted to `+ 40` (writer left at `8 * j`), the suite
   is `1 FAIL` and it is exactly `ENTRY-ARG PIN`; restored, `1147/1147`.
2. **RUN** — `word-arm-corpusrun.sh`'s 120 registered argument vectors, which
   execute the writer/reader pair on both arms. MEASURED FAIL-ABLE: the same
   one-sided revert turns `sub [10 3]` and `sub [3 10]` RED (stdout differs,
   rc equal), and the full revert is `125/125`. NOTE the sensitivity is ONE
   group — most corpus entries are arity 0 or 1, so their argument path never
   reads `a1` — which is why the text pin exists as well as the run.

### THE GAP, STATED RATHER THAN PAPERED OVER

**No fixture can force a scavenge inside `[rootPush, rt_callN]` with today's
knobs**, so the root-coverage half is closed BY CONSTRUCTION (count == region ==
the cells the writer filled, pinned per arm) and not by a collection. Measured
reasoning, not a guess: the window's Mid-heap allocations are `Rt.argvInstall`'s
per-argv-entry string + cons cells — O(1) KB for the 16-arg maximum — while the
nursery is at least 1 MB (`QBE_MIDGC_YOUNG_MB`'s smallest non-zero value is 1;
the default is `clamp(heapBytes/8, 4 MB, 512 MB)`, and it is clamped to the old
ceiling). A fixture that churns AFTER the entry is called proves nothing here:
the args are in the callee's rooted frame by then, so such a row would be a TEST
THAT CANNOT FAIL, which is why it was not written. What would observe it: a
collect-at-next-allocation stress knob (none exists) or an `argvInstall` that
allocated megabytes (it does not).

Also recorded, because it is adjacent and NOT this class: the window
`[Rt.parseArgsGo, rootPushValueArray]` is unrooted on BOTH arms (the float cells
exist before the registration). It is pre-existing, it is not made worse by the
flip, and closing it is its own unit.
