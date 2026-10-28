# THE WORD ARM'S FRONTIER, MEASURED

perf word-arm-frontier, measured on HEAD 46b54d8.
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

`Con` and `MTagEq` are blanket refusals in `Mid.Qbe.Lower.wordArmUnported`, and
**both stated reasons have gone stale under them** — MEASURED by admitting each
in a scratch build and compiling, not by reading the code:

* `Con` — *"its vector is written through `storeValueCell`"*. True of that
  writer's **heap** arm only, and `lowerCon` calls it with `tagNumber`, an
  IMMEDIATE whose word-arm arm is the `shl 3` `mknum` wrap the closure ABI
  already uses for `desc`/`capBase`. The tag is an `LSymbol` (ported in R1), the
  arguments are rooted slots staged contiguous, and the allocation is `Rt.con`'s
  word splice (written in perf word-arm-area3rt). **`Con` needs no emitter
  change at all** — admitting it in the scratch build compiled, assembled,
  linked and RAN `area (Circle 7) + area (Square 3 4)` on both arms, 61 both
  ways.
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

## What this table says the next class is — and what it does not

By `GROUPS`, the top of the table is `MTagEq` (41) then `Con` (39). By `ALONE`
— the number of groups a port of that class alone would unblock — the order is
`float literal` (7), `MTagEq` (2), `prim f/` (2), `let-destructuring` (1),
`Con` (**0**).

**Both readings are right and they answer different questions**, which is why
both are in the table. The `GROUPS` column is a claim about how much of the
frontier is *shaped by* a class; the `ALONE` column is a claim about what one
unit of work can move. The cluster at the top (25 groups need three classes
together, 13 need two) means that no single unit can take the `Con`/`MTagEq`
cluster apart — but it does NOT mean the cluster is expensive, and that is
exactly the thing this census refuses to assume.

So the port that follows this commit is the top of the `GROUPS` ranking —
`Con` + `MTagEq`, which the blocker-set table shows are one unit of work
(neither alone moves more than 2 groups, and a constructor-tag pattern cannot be
validated behaviourally without a constructor to test). Their stated reasons
are measured above, in a scratch build, because reading them is what produced
the stale refusals in the first place.

The word-arm DIFF fixtures' own refusal set is empty — the 17 fixtures are green
on both arms — so the useful question is what a *realistic* program needs that
they avoid. Measured with a 12-program differential sweep (both arms, both
binaries, stdout byte-compared) over the shapes the fixtures do not have, on
THIS tree:

| shape | on this tree |
| --- | --- |
| a user ADT printed (`Circle 7`) | REFUSED (`Con`) |
| a nested constructor (`Wrap (Square 3 4)`) | REFUSED |
| a `String` payload in a constructor | REFUSED |
| a tag test on a PARAMETER (no `Con` in the defun) | REFUSED (`MTagEq`) |
| a two-argument constructor, both binds used | REFUSED |
| a nested tag test (`Wrap inner` -> `inner`) | REFUSED |
| a list of ADTs, folded | REFUSED |
| `==` on ADTs (deep equality over the vector body) | REFUSED |
| a recursive tree built by 6000 inserts | REFUSED |
| zero-argument constructors | REFUSED |
| a tag test inside a bind (nested `case`) | REFUSED |
| `let ( a, b ) = ...` | REFUSED (the next class) |

Eleven of twelve realistic ADT shapes are refused, and they are refused by the
top two rows of the table above — which is the strongest argument that the
cluster is where the arm's usability actually is, and the reason to measure the
cluster's cost before planning anything else.

## The shape of the answer, in one line each

1. The runtime surface (`runtime.mid`) refuses **nothing** any more; every
   remaining blocker is the compiler's surface classifier.
2. 34 of 159 corpus groups cannot compile on **either** arm — they are not the
   word arm's problem, and a table that omits this control is wrong by 2/3.
3. The top of the `GROUPS` ranking is a **cluster** (`Con` + `MTagEq` + `let`
   destructuring) covering 39 of the 51 blocked groups; the top of the `ALONE`
   ranking is floats (9 groups, self-contained).
4. `let` destructuring is the one class that is both large (26 groups) and
   already unblocked by machinery that exists (`wordTagIs`, `fieldBase`).
5. The next commit takes the `GROUPS` top — and its first step is to MEASURE
   whether those two refusals are still true, not to trust their text.
