# THE WORD ARM'S FRONTIER, MEASURED

perf word-arm-frontier: measured on HEAD 46b54d8 (the instrument), then on 4c3d038
+ the port, which is where the AFTER column comes from.
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

**The refusal text names EVERY blocker, not the first.** `wordSurfaceUnported`
and `wordRtUnported` return lists (this unit's first change). The first-only
form reports whichever blocker comes first in `surfaceKeys` order, and the
measurement is what shows how misleading that is: 26 groups reported a
constructor-tag pattern as their blocker while *every one* of them also applies
`Ok`/`Err`/`Just`, so porting that pattern alone would have moved **none** of
them. A ranking cannot be built from a first element. Nothing is relaxed — a
non-empty list still refuses before any IL is produced.

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

Every remaining group is blocked by **exactly one** class — the first time that
has been true — so `GROUPS == ALONE` and the ranking is unambiguous.

### let-destructuring — 26 groups, 26 alone. **The next class.**

`arraybasic arraystress asyncorder asyncpure dictbasic dirunit execbig
execchain execenv execglob execmal execnofile execpipe execsubchain fastexec
fdstream ioecho iofile nowunit readfile setops statplus statunit taskattempt
taskpure taskseq`

defuns: `Array.compressNodes`, `Array.fromListHelp`, `Dict.merge`,
`DictBasic.main`, `Fdstream.fileInProbe`, `Fdstream.stringStreamProbe`,
`Runtime.program`, `Runtime.runOne`, `Runtime.worker`, `Set.partition`,
`SetOps.main`.

The refusal text says *"a tag test plus payload reads"* — and **both of those
exist now**: `wordTagIs` is the tag test (nil is an immediate, cons/vector are
GC-header kinds) and `fieldBase n` is the payload chase, with `n` a payload WORD
index. The one thing to check before believing it is cheap: a `let`
destructuring binds into **existing** binders rather than fresh slots, so the
question is whether the binding path has a word-arm fork at all, or whether it
is the same `lowerBind`/`lowerPath` the `Case` matcher already uses. Also note
`Runtime.*` — a core-lib defun reached by the effect host, so this class is not
only "programs that destructure in a `let`".

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

`strunit` is blocked by an **emit site**, not the classifier: its refusal line
carries no defun name (`a float literal — the word arm heap-boxes a float as a
[hdr | f64] cell`). That is the already-recorded gap that `wordArmUnported`
admits `App` WITHOUT recursing into its arguments — a raw node reached only as a
call argument is invisible to the belt. Worth fixing while in there.

### prim `f/` — 2 groups, 2 alone (AREA 5)

`floatdiv floatpartial`, defuns `Floatdiv.main` and `/.curried`. Same area; it
cannot be ported before the float cell exists.

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
emit.

## The shape of the answer, in one line each

1. The runtime surface (`runtime.mid`) refuses **nothing** any more; every
   remaining blocker is the compiler's surface classifier.
2. 34 of 159 corpus groups cannot compile on **either** arm — they are not the
   word arm's problem, and a table that omits this control is wrong by 2/3.
3. The top of the first-refusal ranking (`Con`/`MTagEq`, 41 and 39 groups) was
   **two stale refusals**; porting them cost one fork and moved the arm from 74
   to 88 compiling groups.
4. The next class is **`let` destructuring, 26 groups, 26 of them alone** — the
   first time the ranking has been unambiguous.
5. The class after that is **floats** (11 groups, 2 of them `f/`), and it carries
   the `mk*`-as-safepoint obligation from WORKLIST item 5 in the same unit.
