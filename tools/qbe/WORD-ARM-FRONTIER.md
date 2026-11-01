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

**SUPERSEDED — AND THE BLOCK ABOVE IS THE TREE IT WAS TAKEN ON, NOT TODAY'S
CENSUS.** MEASURED at HEAD `1aa7a4c`, `tools/qbe/word-arm-refusals.sh
--groups`, from the repo root:

```
BOTH           125  (emit IL on both arms)
SAME-ERROR      34  (both arms refuse identically: not a word-arm blocker)
WORD-BLOCKED     0

nothing refuses: every corpus group compiles on the word arm
```

The one class this section names — the host program path — is CLOSED, and it
closed as the paragraph above predicts it would have to: the stride was
TWINNED, not refused. `struct Host`'s one `val[33031]` field became
`word[33031]`, and the blob, the five scratch cells, the eval `base` slots,
`Rt.apply-at`'s argument slice and `Rt.callArity`'s `rt_callN` pitch all moved
with it (54 stride lines in three defun families — STEP 0 below enumerates
them). `wordArmDefunRefusals` is therefore EMPTY
(`osier-compiler/src/Mid/Qbe/Lower.elm:1513`), which is why the 7 groups moved
from WORD-BLOCKED to BOTH instead of leaving the census. 118 / 34 / 7 stays
here because it was true of the float port's tree; a reader who takes it as the
current frontier is reading a census SEVEN groups old.

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
   groups and WORD-BLOCKED 18 -> 7 **at that point** (both have moved since —
   see item 6).
6. **The one class left WAS the host program path** (7 groups, 7 alone,
   `Runtime.program`), and it was the first frontier in this arc that was NOT a
   classifier admission: the event loop's state is one malloc'd blob laid out
   with the val arm's 40-byte stride while the collector scans it at the
   layout's, so the blob size, the slot array stride and every `* 40` move
   together. **IT IS TWINNED NOW** — MEASURED at `1aa7a4c`: WORD-BLOCKED 0,
   BOTH 125, and `wordArmDefunRefusals` empty. `StreamRef` is the classifier's
   remaining CONTROL (not a plan), and the `App`-argument walk that would name
   it in a census owes 14 runs first.

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
| crashed or hung (a timeout, or a common rc >= 128 signal death on both arms, is a FAILURE — never agreement) | **0** |
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
  **AND THE DETERMINISM HERE IS THE ALLOCATOR'S, NOT THE ABI'S.**  These
  entries declare `arity >= 1`, so `Rt.main` reads `a1 …` out of `abuf`
  cells that NOTHING EVER WROTE (no argument was parsed): `abuf =
  malloc(648)` (`runtime.mid:8525`) is never `memset`, and the count cell
  makes the registered region `nargs` Values, so the cells the entry reads
  are the region's own unwritten bytes on both arms.  Both arms agree today
  only because a fresh `malloc` hands back ZEROED pages, which both
  representations read as the number 0.  That is a property of THIS libc's
  fresh-block behaviour, not a guarantee of the ABI: a recycled block, a
  different allocator or a future arena could hand the two arms different
  bytes, and this row would then differ for a reason that says nothing about
  either representation.  So the six `no-vector` rows' agreement is NOT
  evidence about the entry-argument path — the 120 driven vectors are —
  and a flip-time change here should be read as an allocator observation
  first.
* **CWD IS THE REPO ROOT**, which is the gate's own convention and a hard
  requirement: eight fixtures resolve repo-root-relative paths (`iofile` writes
  `tests/elm-fixtures/out/hello.out`), and the gate refuses to run anywhere else
  for exactly that reason.
* **STDIN** is the registered file for a `run_io` row and `/dev/null` otherwise
  (the gate lets a `natrun` row inherit stdin; that is not a property of the
  program).  **TIMEOUT 20 s, and a timeout is a FAILURE** — a wrong count or
  stride LOOPS instead of crashing, and a gate that hangs reports nothing.
  **AND SO IS A SHARED SIGNAL DEATH.**  A row whose two arms return the SAME
  rc >= 128 (134 SIGABRT, 136 SIGFPE, 139 SIGSEGV) is not a comparison: both
  arms produced no answer, so it cannot be credited as identical.  The script
  carries the rc in the result field (`… CRASH=N`), counts it on its own
  line (`CRASHED on BOTH arms`), says `CRASHED on BOTH arms (N) — NOT
  identical` in the table, and fails.  MEASURED FAIL-ABLE on a scratch tree
  with ONE shared store rewritten to address 0 in `Rt.main`
  (`wstore(0, 1, entry)`), so that EVERY run dies 139 on BOTH arms:

      without the flag   IDENTICAL 125 / DIFFERING 0, rc 0  — all 126 run(s)
                         read as agreement, under a `crashed or hung 0`
                         headline
      with the flag      IDENTICAL 0 / DIFFERING 0 / CRASHED on BOTH arms 125
                         group(s) (126 run(s)), table rows
                         `CRASHED on BOTH arms (139) — NOT identical`, rc 1
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

5. **IT DOES NOT REACH THE GATE'S `intproc` ROWS AT ALL** — `intcorner`,
   `intbig` and `intpow` register no `run`/`run2`/`run_io` check, so no corpus
   vector touches them.  Those rows are the word arm's 11 RED gate rows and
   they are measured separately (see THE WORD-ARM GATE PASS below); the
   corpus is not their oracle and `BOTH 125` must not be read as covering
   them.

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

## THE WORD-ARM GATE PASS (flip-prep): 11 ROWS THE CORPUS CANNOT SEE, AND ALL 11 ARE RED

> **SUPERSEDED — READ THE FLIP SECTION BELOW FIRST (~line 1120).** The eleven
> rows in this section are **GREEN** at HEAD: AREA 4 landed, and the flip did
> NOT need the "pin those 11 rows val-only" decision.  The table below is the
> state at flip PREP, kept because it is the only enumeration of WHICH rows the
> corpus cannot see; it is not the current gate result.

`QBE_VALREP=word tests/elm-fixtures/run-elm-gate.sh`, from the REPO ROOT, is the
ONE instrument that runs the gate's non-corpus executable rows on the word arm.
The corpus run above cannot see any of this BY CONSTRUCTION: `intproc`'s rows
register no `run`/`run2`/`run_io` check, so no vector in the corpus manifest
reaches them — `BOTH 125 / IDENTICAL 125` is silent about every row below.

| the same gate, both arms, same tree | result |
| --- | --- |
| default (val) arm | **PASS=190 FAIL=0**, rc 0 (149 s) |
| `QBE_VALREP=word` | **PASS=179 FAIL=11**, rc 1 |

190 − 11 = 179, so the eleven are the WHOLE of the word arm's gate gap today.
Every one is a LOUD refusal by design (VR3b2: the arm must fail, never
half-work). **No silent wrong answer is in this list** — that is the finding
this table exists to carry, and it is why the gap is a decision rather than a
defect hunt.

### Class 1 — EIGHT `intbig` ROWS, REFUSED AT **EMIT** (AREA 4, the i61 overflow/boxing path)

All eight entry functions of `tests/elm-fixtures/intbig.elm` stop in the
emitter, so the gate fails them at BUILD (`qbe-mk: compile failed`) before any
run. The text is ONE message per row, differing only in the literal it names:

```
err qbe: QBE_VALREP=word is NOT IMPLEMENTED (perf VR3b2): the emitter cannot
lower AREA 4 (ARITHMETIC — THE i61 OVERFLOW/BOXING PATH) — the literal
<LITERAL> — it is above 2^53, so its i61 range check and its `n * 8` fixnum
shift have to be done in the exact domain (AREA 4); emitting them from a host
number would silently round it — the word arm stops at its un-ported constructs
instead of emitting half-word code (nothing was emitted).
```

| row (entry, args) | word arm | val arm (measured, the gate's own expectation) |
| --- | --- | --- |
| `Intbig.maxi64` | EMIT refusal, literal `9223372036854775807` | rc 0 `9223372036854775807` |
| `Intbig.mini64` | EMIT refusal, literal `-9223372036854775808` | rc 0 `-9223372036854775808` |
| `Intbig.above53` | EMIT refusal, literal `9007199254740993` | rc 0 `9007199254740993` |
| `Intbig.bigmul` | EMIT refusal, literal `1152921504606846975` | rc 0 `1152921504606846975` |
| `Intbig.bigdiff` | EMIT refusal, literal `1152921504606846975` | rc 0 `1152921504606846976` |
| `Intbig.hexmax` | EMIT refusal, literal `9223372036854775807` | rc 0 `9223372036854775807` |
| `Intbig.patmatch 9223372036854775807` | EMIT refusal, literal `9223372036854775807` | rc 0 `1` |
| `Intbig.patmatch 5` | EMIT refusal, literal `9223372036854775807` | rc 0 `0` |

WHY THEY REFUSE: a word-arm fixnum IS an i61 (`wordTagShape`/`wordFixnumLimit`),
so an Int literal above 2^53 needs the i61 range check AND the `n * 8` shift
done in the exact domain; a value that does not fit has to be BOXED, and that
heap cell is AREA 4's overflow path, which does not exist. The `patmatch` rows
refuse for the same reason in a different seat (the pattern literal is in the
same defun).

### Class 2 — TWO `intcorner` ROWS AND ONE `intpow` ROW, REFUSED AT **RUNTIME**

These three EMIT on both arms and then die at `mknum`'s round-trip check: a
result inside i64 but outside i61 has no fixnum encoding.

| row | word arm | val arm |
| --- | --- | --- |
| `Intcorner.wrapmul 1` | runtime refusal, rc 1: `qbe-rt: word arm: mknum overflow - the value does not fit the i61 fixnum (its top three bits would be dropped by the tag shift) and boxing onto the heap is AREA 4's overflow path, which does not exist yet. Refusing instead of truncating.` | rc 0 `0` — i64 two's complement: `1024^6 * 16` = 2^64, wrapping to 0 |
| `Intcorner.minbyneg 1` | runtime refusal, rc 1: the SAME `mknum overflow` text (the 2^63 intermediate has no fixnum) | rc 1 `qbe-rt: division overflow: 'INT64_MIN // -1' is 2^63, which is not an i64` — the arms HALT FOR DIFFERENT NAMED REASONS, which is a representation difference, not a behaviour one: both refuse, the messages differ |
| `Intpow.powbig` | runtime refusal, rc 1: the SAME `mknum overflow` text | rc 0 `4052555153018976267` (3^39 — below INT64_MAX, above 2^61) |

Note the shape `minbyneg` exposes: the word arm's failure PRECEDES the val arm's
own named halt. A pin that merely matched rc would call the row identical; the
gate compares the diagnostic, which is why it does not.

### What this table is FOR — and what this unit did NOT do

The flip checklist says the gate's default arm flips with `run.js:363`, so on
flip day this row is 11 red unless (a) AREA 4 (i61 boxing) is implemented or
(b) these 11 rows are explicitly pinned `QBE_VALREP=val`. **Both are the
OWNER's call.** This unit did neither: it did not port AREA 4, it did not pin a
row, and it did not change the gate. The pin was not taken partly because it
would HIDE the decision inside the instrument that should carry it, and partly
because the list is small enough to decide on directly: one root (the i61 fixnum
domain), two classes (8 rows can never emit until boxing exists; 3 rows emit and
refuse at the fixnum boundary).

ONE COUNT CORRECTION, because the arithmetic has to close: the corpusrun review
recorded "intbig's nine rows". MEASURED, `intbig` registers EIGHT `intproc` rows
(`maxi64 mini64 above53 bigmul bigdiff hexmax patmatch[9223372036854775807]
patmatch[5]`, run-elm-gate.sh:868-878) and all eight are red; 8 + 2 `intcorner`
+ 1 `intpow` = 11 = `FAIL=11`, and `PASS=179` is `190 - 11`. The review's named
list was right about WHICH rows; only its row count was one high.

Reproduce (either line; the second is the one that decides the flip):

```
QBE_VALREP=word tests/elm-fixtures/run-elm-gate.sh | grep -E '^FAIL|^PASS='   # PASS=179 FAIL=11
tests/elm-fixtures/run-elm-gate.sh               | grep -E '^PASS=|^FAIL'    # PASS=190 FAIL=0
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
the cells the writer filled, pinned per arm) and not by a collection.

THE INVARIANT THAT ACTUALLY HOLDS: the window `[rootPush, rt_callN]` contains
**ZERO Mid-heap allocations** whenever the root is non-empty. Read from the code,
per conjunct:

* `entry_nargs > 0` REQUIRES `argvMode == 0` — `entry_nargs` is
  `mkbool(argvMode != 0) ? 0 : nargs` (`runtime.mid:8526`), so a non-empty root
  means argv mode is OFF.
* At mode 0 `Rt.argvInstall` returns at its FIRST branch (`runtime.mid:3352-3354`):
  `vecstore(ent, 0, mknil); return mknil;` — one store into the ALREADY-EXISTING
  `*argv*` entry vector, allocating nothing. The per-argv string + cons path
  (`Rt.argvGo`) runs only when `entry_nargs == 0`, i.e. when the root is EMPTY
  and there is nothing for it to cover.
* Nothing else in the window reaches the collector: GC triggers fire ONLY inside
  `gcAlloc` — the young-fill scavenge (`runtime.mid:5891`) and the full-collect
  threshold (`runtime.mid:5877`). The window's two remaining allocations
  (`fslot`, `modelslot`) are `rawcall malloc`, i.e. LIBC, and cannot trigger a
  Mid collection.

So the argument does not depend on the nursery's size at all: no
`QBE_MIDGC_YOUNG_MB` value and no allocation volume can change it. (This
paragraph previously reasoned "O(1) KB of argvInstall allocations vs a nursery of
at least 1 MB" — that is the WRONG MODE'S path, the one taken when the root is
empty. The conclusion was right and the mechanism was not; the zero-allocation
invariant is strictly stronger and survives a future nursery knob.)

A fixture that churns AFTER the entry is called proves nothing here: the args are
in the callee's rooted frame by then, so such a row would be a TEST THAT CANNOT
FAIL, which is why it was not written. What would observe it: a forced-collection
stress knob that fires at a chosen point (`gcAlloc` is the only trigger, and at
`argvMode == 0` the window never enters it) — none exists.

Also recorded, because it is adjacent and NOT this class: the window
`[Rt.parseArgsGo, rootPushValueArray]` is unrooted on BOTH arms (the float cells
exist before the registration). It is pre-existing, it is not made worse by the
flip, and closing it is its own unit.

## THE FLIP (perf word-arm-flip, VR3d): THE WORD ARM IS THE DEFAULT — and it is NOT yet verifiable green

**This section SUPERSEDES every "the word arm is not the default" reading above,
including the `PASS=179 FAIL=11` gate table.** Records here are append-only; the
measurements they record were true of the trees they were taken on.

### What moved

`osier-compiler/run.js`: `QBE_WORDVAL = process.env.QBE_VALREP !== 'val'` — an
unset `QBE_VALREP` is the 8-byte arm and the 40-byte arm must be asked for by
name. An unknown value is REFUSED (exit 2), the same polarity the five
word-arm instruments took at flip prep: `QBE_VALREP=Word` must not quietly
measure the other arm. `selfhost/NativeMain.elm`'s hand-copied default vector
moves with it (`wordVal = True`) — the seed IS that file's own emit, so a twin
left at `False` makes the native lane emit one arm and the stock lane the
other, and the `.ssa` fixed point stops closing on its first run.

MEASURED (fib.elm): unset == word byte-identical, val differs, val stable,
`QBE_VALREP=Word` exits 2. Before the flip, unset == val.

### The gate, on all three arms (MEASURED, repo root)

| arm | result |
| --- | --- |
| `QBE_VALREP=word` | **PASS=190 FAIL=0**, rc 0 |
| unset (the default — the same arm) | **PASS=190 FAIL=0**, rc 0 |
| `QBE_VALREP=val` | **PASS=190 FAIL=0**, rc 0 |

The eleven rows that were red at flip prep (`PASS=179 FAIL=11`, the AREA 4
table above) are GREEN: AREA 4 landed, so the flip did NOT need the
"pin those 11 rows val-only" decision. The val arm stays a full participant
because it is the DIFFERENTIAL ORACLE for every word-arm row — a val arm that
dies at the flip makes every comparison vacuous.

### The corpus re-freeze, and why the moved set is the right shape

`tools/osier-corpus-ssa.sh --freeze`: 159 artifacts, **125 hash lines moved**
(git's own 125 ins / 125 del). Enumerated by NAME (order-preserving), never by a
content→index map — two groups can emit identical bytes and a content map
collapses them:

```
old names 159 = new names 159          (name sets EQUAL)
moved 125   unmoved 34
defines 125 (the emit is real IL)      err 34 (first 4 bytes "err ")
SET EQUALITY  moved == defines   TRUE
SET EQUALITY  unmoved == err     TRUE
partition: 125 + 34 = 159, disjoint, covering
```

The flip changes the REPRESENTATION, which is text in every emitting group's
`.ssa`, so every group that emits MUST move; the 34 refusals are front-end/type
errors decided before any arm exists, so they must NOT move. `moved == defines`
is the claim that the flip moved the emit and nothing else — no group changed
class, none started or stopped refusing.

**The goldens did NOT re-freeze.** A moved golden is a DEFECT, and on this tree
none moved: every golden row runs on the (now word) default arm and still prints
the frozen bytes.

### The seed re-freeze, with the deferred `wordFixnumLimit` re-spelling

`tools/qbe-bootstrap.sh --freeze` at the flipped tree: **25,259,694 →
38,148,638 B** (the word arm's IL is ~51% larger — one tagged word per value
costs more instructions than a payload struct; the RUNTIME is what this arm
makes cheaper, not the emit). `--status`: abi FRESH + exact FRESH. `--check`:
rc 0.

The re-spelling rides it because `gc:layout` digests the census block:
`wordFixnumLimit` is now `1152921504606846976` (was a six-factor product), it
JOINED the census's seat list (it had been invisible: the parser wants `name =`
followed immediately by `    <digits>`, and the old spelling put a comment
between them), and `mid_values` now prints `$1` instead of `($0 + 0)` because
awk's CONVFMT (`%.6g`) would have printed `1.15292e+18`. Marker
`8217660e… → e03c508c… → bb739cd1…`. Also fixed on the way: `layout-census.sh
--check` was RED at HEAD because AREA 4 added `tagBigInt` without a seat.

### Rows that only ever measured the VAL arm, and now say so

A full `qbe-check` on the flipped tree was 19 FAIL / 345 PASS. Eighteen were
rows whose SUBJECT is a 40-byte-arm shape; each now NAMES its arm instead of
inheriting "the default", because an inherited default silently changes a row's
subject at the flip while the row keeps printing its headline:

| row | why it is val-arm-shaped (measured) |
| --- | --- |
| `hostapply` | `Whost.mid` hand-computes 40-byte strides; on the word arm it printed `[cons 7 …]` for a golden `[cons 417 …]`. The word arm's applier oracle is `word-arm-diff`'s `hostprog.elm` (stride-twin, runs on BOTH arms). |
| `boolpay`, `BOOLPAY-SHAPE` | the fixture's subject IS the 40-byte boolean payload word (`mkval(5, 2^32)`); the word arm refuses that cell by name — the arm's correct answer. |
| `flatten-structural`, `noflatten-structural` | the probe constant is `storew 14`, the 40-byte arm's tag-14 `RawMkValue`. A word-arm record is a heap cell whose kind code is in the header. |
| `norep-*` (5 rows) | S4's unboxed Int locals are a change to the 40-byte representation: on the word arm `NoRep.chain`/`NoRep.floatLocal` are **cmp-identical** ON vs OFF. An A/B whose arms cannot differ is not a test. |
| `mono-fired` | the pass is NOT inert (the emits differ) but the row's discriminator is the clone's `prim=`/`sym=` fallback COUNT, which the word arm routes differently (6 vs 6 while the pass fired). |
| `ffid-f64`, `ffis-vararg` | the expected call SHAPE is the 40-byte arm's FFI boundary. |
| `tsbuf-apply` | its structural half needs the emit to call BOTH staging seats; the word-arm emit never reaches `Rt.stage-tail`, so the row's own "no test" guard fired. **The tsbuf aliasing hazard has NO oracle on the word arm** — a recorded gap. |

Two more were REBASED rather than pinned, because their claim is real on both
arms: `frame-wordcond` now runs both (val 67 instructions / bound 80 + the
boxed-cond grep; word 143 / bound 160 + the memset — `storew 3,` is a val-arm
spelling and asserting it on the word arm would be vacuous), and `root-stores`'
floor is 10 (MEASURED: val 66 frame-pointer ops, word 19, promoted 0).

### The three ratio gates, per arm

| gate | val arm | word arm (THE DEFAULT) | bound |
| --- | --- | --- | --- |
| frame, fib 28 | 0.83x (38/46 ms) | **2.34x** (110/47 ms) | 2.5x |
| apply, n=5e6 | 1.51x (496/328) | **3.01x** (987/328) | 12x |
| tail, 1e6 | 0.82x (47/57) | **1.44x** (82/57) | 6x |

**The word arm is 2-3x SLOWER than the val arm on every call-family path**, and
its frame gate sits 7% under the bound — i.e. nearly binding on the new default.
That is a fact about this point in the arc (its win is the value stride; its
frame path still carries the 40-byte shape — `frame-wordcond` prints both), and
VR4/VR5/VR6 are the units that pay it back. The bound is NOT retuned here. The
B4 asymmetry probe (`QBE_NORTLEAN=1`) no longer exists — the Mid collector
refuses the fat ABI — and `QBE_NOREP=1` is inert on the word arm (2.39x vs
2.34x), so **that bound's "fails before" direction is currently unproven on the
word arm**.

### THE FLIP IS NOT VERIFIABLE GREEN: three measured word-arm defects

**HISTORICAL — ALL THREE ARE CLOSED.** Defect 1 is superseded by AREA 6
immediately below; defects 2 and 3 are superseded by the section appended at the
end of this file ("THE WHOLE-COMPILER CHAIN AND THE FIXED POINT, CLOSED"), which
carries the measurements. The bullets keep the text they were measured on, which
is why this marker sits above them rather than editing them.

1. **`clostail-big` is RED on the default arm.** The generic-apply tail chain is
   NOT constant-stack: n=8000 rc 0, **n=9000 SIGSEGV** under an owned 8 MiB
   stack (val flat at n=1e6, 16276 kB). Cause: `Lower.elm`'s `rtCallTwoRange`
   has `canTail = not (wordArmLayout layout) && …`, so every word-arm arity
   block CALLS the callee and each hop of a RE-ENTERED chain stacks one frame.
   The naive fix is REFUTED, measured: enabling the tcall emits
   `tcall :val %code(env %e, l %pv0)` in a block that LOADED `%pv0` first and
   the vendored QBE rejects it ("tcall must be the last instruction of its
   block") — reproduced by a one-line mutation of the val arm's own `.ssa` (an
   `add` in the same position does not reproduce it). **AREA 6 work.**
2. **The word-arm seed cannot run the whole-compiler emit.** At a 16 GB ceiling:
   `midgc: scavenge read a POISONED (forwarded young) body … (collect 22)`; at
   32 GB: `this ceiling needs more than 2^20 size classes; the word arm's class
   field is bits 2..21`. A rooting/scan gap of the class this arc has fixed
   twice, plus an allocator ceiling limit.
3. **Consequence: the `.ssa` fixed point does not close on the word arm** — the
   seed-built compiler cannot re-emit the seed, so the tree's strongest single
   oracle is unverified until (2) is fixed. The committed seed is still the
   honest freeze (it IS the default arm's emit); the defect is in the runtime.

`WORD-BLOCKED = 0` was never evidence that the arm is CORRECT, and this is the
sharpest instance yet: the census is unchanged by the flip (125 / 34 / 0) while
a 1e6-hop tail chain and the whole-compiler emit both fail.

---

# AREA 6: THE GENERIC-APPLY HOP TAIL-CALLS (perf word-arm-area6)

**APPEND-ONLY, AND IT SUPERSEDES DEFECT 1 ABOVE.** The section above says the
word arm's `clostail-big` is red because `rtCallTwoRange` cannot tcall, and that
the naive fix is refuted by QBE. The FIRST half of that is now fixed; the SECOND
half was measured FALSE last unit, and the real refusal was somewhere else.

## What was actually wrong, in the order it was found

1. **The recorded refutation was wrong.** "Enabling the tcall emits
   `tcall :val %code(env %e, l %pv0)` in a block that LOADED `%pv0` first and
   QBE rejects exactly that" — MEASURED, four shapes: that exact shape
   ASSEMBLES (rc 0). The reproduction that had seemed to red it was malformed
   twice over: its `export function` omitted the return type (QBE: "newline
   expected, got ??") and its mutation put the load AFTER the tcall (which
   trips the bare-`ret` rule). The one shape QBE refuses is a **CLASS
   MISMATCH**, refused by name in both directions.
2. **But the first cut still would not assemble, for a real reason.** `gcm`'s
   `sink()` appends instructions AFTER a `tcall`: `gvn` CSEs the arity blocks'
   shared address chains into a dominator, so a load has no local chain;
   `sink()` re-materialises that chain in the load's block; `sinkref` emits the
   instruction BEFORE rewriting its args, so the copies it recurses into are
   DEAD; `addins` appends, so they land after the tcall; `schedblk` has no use
   edge to order the dead ones by. abi1 refuses the emit. (Found with a debug
   build of qbe in scratch — vendor/qbe untouched.) The val arm never sees it:
   it passes arg POINTERS, so its tcall blocks hold no load at all.
3. **The class was never the word arm's problem.** MEASURED at HEAD:
   `rt_call2r` already declared `ret = Agg "val"` and annotated both call forms
   `Agg "val"`, and `lowerFunBody` gives every RtGeneric body — what `%code`,
   the DYNAMIC callee here, points at — `retTy = closureRetClass sOuter`. U3b
   had already made both ends `:val` on BOTH arms.

## The fix

* `rtCallTwoRange` takes `S`; `tailClass = closureRetClass s` is ONE binding
  used by the tcall, by the ordinary call's result class, and by the function's
  own `ret`. A mismatch is unrepresentable there; the check that can still fail
  is abi1's C4, which refuses by name.
* `canTail = n <= maxTailCallArgs`. `not (wordArmLayout layout)` is GONE.
* `argLoad` moves each argument's load ONE BLOCK EARLIER, into the dispatch
  block that proves the argument exists (`@c{k}` is reached only when
  `arity >= k`, so argument k-1 is always present). Every tcall block is now
  `tcall :val %code(env %e, l %pv<n>…)` + a bare `ret` — byte for byte the val
  arm's tcall shape. The last arity loads its final argument itself (no
  `@c{maxArity}`, and it takes an ordinary call). Each argument is still loaded
  exactly once, so the cost is unchanged. The VAL arm's emit is untouched — the
  fork is `wordArmLayout layout`.

## MEASURED

| instrument | before | after |
| --- | --- | --- |
| `clostail-big` (OWNED 8 MiB stack, `QBE_NO_RLIMIT=1`) | n=8000 rc 0, **n=9000 SIGSEGV** | **n=1e6 rc 0, out "0"** (flat; n=5/3000/9000/1e5 all rc 0) |
| the word `.ssa` through vendor/qbe | rc 1, "tcall must be the last instruction of its block" | **rc 0** |
| tcalls in `rt_call2r` (word arm) | 0 | 5 (arity 0-4), every one followed by a bare `ret` |

`tools/qbe/tcall-class-probe.sh` is the standing instrument (wired into
qbe-check): the legal shape assembles; a class mismatch is refused BY NAME in
both directions; no tcall block in the real emit loads; the first cut's shape,
DERIVED from the real emit, is refused. A bare re-load would not do — it is the
address `@c1` already loaded and `loadopt` forwards it away, MEASURED, which is
why the derived row duplicates the chain.

**STILL OPEN (unchanged by this unit):** defects 2 and 3 above — the word-arm
seed cannot run the whole-compiler emit (16 GB poisoned-body, 32 GB class
field), so the `.ssa` fixed point does not close. The flip is NOT gated on that
here; it is gated on `clostail-big`, which is now green.

**SUPERSEDED — BOTH ARE CLOSED; the measurements are in the section appended at
the end of this file.**

---

# THE WHOLE-COMPILER CHAIN AND THE FIXED POINT, CLOSED (perf docs-true-up)

**APPEND-ONLY, AND IT SUPERSEDES DEFECTS 2 AND 3 ABOVE, AND THE `STILL OPEN`
PARAGRAPH THAT ENDS AREA 6.** Records here are append-only; the text those
defects carry was true of the trees it was measured on. What follows is the
measurement that overtook it.

PROVENANCE OF THE NUMBERS HERE, stated once because this file's rule is that a
measurement names the tree it was taken on. RE-MEASURED BY THIS UNIT at
`1aa7a4c`: the census, the tree state of both fixes (`runtime.mid`'s four masks,
the clamp and the root move; `wordArmDefunRefusals` empty), the layout census
and `--status`. QUOTED, NOT RE-RUN: the 50-minute whole-compiler chain in both
polarities and the 52-minute `--verify` — they were measured by perf
word-arm-teardown (`handoff-teardown-kind0-result` in the project record),
neither fits a docs unit's budget, and the chain already carries a fail-before
beside its pass.

## Defect 2, first half: the 2^20 class field is WIDENED (commit `7815c5b`)

The class field was DOCUMENTED as header bits 2..23 and MASKED as bits 2..21 in
every reader, while the ceiling guard fired at 2^20 classes. At the selfhost's
default heap (`QBE_HEAP_MB=32768`) that is 8,389,120 classes and `gcInit` DIED
before the emit could start, which is why the 32 GB rung printed
`this ceiling needs more than 2^20 size classes`.

MEASURED IN THE TREE at `1aa7a4c` (read, not inferred): all four class readers
mask `4194303` (`runtime.mid:6634` `gcScavPtr`, `:7074` `gcSweep`, `:7314`
`gcVerify`, `:7391` `gcVerifyList`), `gcInit` CLAMPS `capBytes` to
`137438953472` (`runtime.mid:5486`) and REFUSES a budget above the clamp BY NAME
(`:5482` — "a bigger heap needs the KIND CODE re-bitted out of bits 24..27"), and
`Mid/RtLayout.elm:251-259` states the same 22-bit field and the 128 GiB ceiling
as the contract. `7815c5b`'s own message records the polarity both ways: at
`QBE_HEAP_MB=32768` the ceiling die is gone and at `200000` it refuses by name.
The KIND CONTRACT did not move (shift 24, mask 15), which is the mixed-
representation read that widening a neighbouring field could have caused.

## Defect 2, second half: the poisoned body was the HOST LANE RUNNING UNROOTED (commit `c9a9490`)

`midgc: scavenge read a POISONED (forwarded young) body` at 16 GB was not a
scavenger bug and not a heap-corruption class of its own. `Rt.hostInit`
registered the host blob's 33031-slot array — the ONLY root for every host-lane
Value — but that defun is classified ALLOCATING on the word arm (its closing
`mknum(blob)` is a boxing seat), so it HAS a frame there, and `Rt.frame-leave`
does `rootPopTo(wm)` with `wm` snapshotted at enter, BEFORE the frame's own
push. The registration was therefore truncated by hostInit's OWN leave and the
whole host lane ran unrooted from the first instruction. The fix moved the root
to `Rt.hostRun`, whose frame spans the whole run (`runtime.mid:12496`), and left
hostInit allocating only — with the ORDERING that matters: the `mknum` must run
over an array nothing has been written into yet.

MEASURED BOTH WAYS, same chain, same container, one variable (the runtime the
binary EXECUTES — `runtime.mid` is read at run time, so the emitted bytes are
identical on both sides):

| the whole-compiler chain, `AOTRUN_ARGV=1 QBE_HEAP_MB=32768` | result |
| --- | --- |
| the fix in the runtime (HEAD at the time, `c9a9490`) | 38,136,379 B written, stdout `elmc: wrote 1 outputs`, EMPTY stderr, **EXIT 0** |
| ONLY the root move reverted | the same 38,136,379 B written (`cmp` clean), stdout EMPTY, stderr the KIND-0 sentence verbatim, **EXIT 1** |

So the exit code flips 1 -> 0 with byte-identical emit, and the 50-minute run
demonstrably COLLECTED (a 60 s slice at the same knob prints 44 scavenges + 2
full collects), which is the part that matters for a defect whose read was
collect-dependent. The 16 GB rung itself was NOT re-run in this unit; the
failure it printed was the same unrooted host lane, which was measured at the
32 GB default both ways.

## Defect 3: the `.ssa` fixed point DOES close

`tools/qbe-bootstrap.sh --verify` at `1aa7a4c` builds the compiler from the
COMMITTED seed and that compiler re-emits the seed byte-for-byte — 38,136,379 B,
`FIXED POINT`, exit 0 (3132.5 s, node and elm not invoked). The seed was
re-frozen to exactly that emit in the same commit (`--freeze` 34.0 s, ABI marker
`bb739cd1…`), so the seed is the WORD ARM's emit and the tree's strongest single
oracle is green at word scale.

RE-MEASURED HERE, the cheap half (`tools/qbe-bootstrap.sh --status`, 40 s):

```
seed 38136379 bytes, 4f5ec19e81da015e…
abi-marker bb739cd1e058dc05d6fe40c37ecfa84cd9c74c2a90022a377fec22fd849a443a
abi  DRIFTED — the emit inputs moved since the seed was frozen (expected; still bootstraps)
exact FRESH — the selfhost emit reproduces the committed seed byte-for-byte
```

`DRIFTED` is the emit-INPUTS digest and not the marker: the marker above is the
one `abi-fingerprint.sh` computes from THIS tree, so the ABI half is fresh and
`--check` would pass. `--status` prints `DRIFTED` on any tree whose compiler
sources have uncommitted edits, which is the ordinary state during a unit.

## What this does NOT say

`WORD-BLOCKED = 0` is still not evidence that the arm is correct, and the
sentence that closed the old section still stands: a census reads EMITS. What
changed is narrower and worth stating exactly — the arm compiles every corpus
group, the whole-compiler emit runs to completion and exits honestly, and the
`.ssa` fixed point closes. The correctness evidence remains the behavioural
gates (the `word-arm-gcchurn` ladders under real collections, `word-arm-diff`
both arms, the 190-row elm gate on all three arms), and the perf gap the flip
section records (the word arm 2-3x slower on the call family, its frame gate 7%
under the bound) is untouched by any of this.
