module Boxfloat exposing (boxadd, boxaddrev, boxbigsum)

-- AREA 4 FOLLOW-UP — THE BOXED-INT x FLOAT READER PAIR (design doc
-- AREA4-BOXING.md §4 recommendation 2 and the §6 "unpinned" risk).
--
-- A word-arm Int outside the i61 fixnum range is BOXED: `Rt.boxInt`
-- (runtime.mid) allocates a code-13 heap cell whose body word 0 is the raw
-- i64, and `payload(x, 0)` is the unbox (design §2).  Every other reader of a
-- boxed value is pinned by a gate row; `Rt.+`'s FLOAT arm was not — it is the
-- one reader that has to unbox a boxed int on a path whose other operand is a
-- float.  Nothing in the tree exercised it, so a regression there is a SILENT
-- wrong double, rc 0.
--
-- WHY THIS VALUE BOXES (MEASURED, not assumed).  `Mid/RtLayout.wordFixnumLimit`
-- is 1152921504606846976 (2^60) at this HEAD and the bound is EXCLUSIVE in
-- magnitude: a fixnum is `-limit <= n < limit`.  So 2^60 itself is the first
-- value that does NOT fit, and the emitter materialises it through the boxing
-- seat instead of the `n * 8` fixnum shift: the emitted `q_Boxfloat_x2ebig`
-- contains `call $q_Rt_x2eboxInt` (checked in the .ssa behind every row here).
-- The value is also above 2^53, so no host double can spell it — the literal
-- travels as digits and is rebuilt from base-2^26 limbs (design §3) — and it
-- is inside i64, so the boxed body holds the number itself.
--
-- WHY `Basics.toFloat` DOES NOT CONVERT BEFORE `Rt.+` SEES IT.  The tempting
-- reading is "toFloat unboxes first, so this only pins `Rt.asF`".  It is not
-- what the emitter does: `Prelude.basicsToFloat` lowers to a 2-word aggregate
-- carrying the SAME word (on the word arm an Int and a Float are both one
-- word), so the value handed to `Rt.+` is still the boxed cell, and the
-- conversion happens INSIDE `Rt.+`'s float arm —
-- `mkflt(fload(asF(a)) f+ fload(asF(bb)))`, where `asF` is
-- `mkflt(itof(payload(x, 0)))`.  MEASURED in the emitted .ssa: the entry's
-- `Rt.+` call receives the boxed cell's word, and the code-13 body read is the
-- `payload` inside `Rt.asF`.  That pair is what these rows pin.
--
-- MEASURED CONSEQUENCE, and why row (c) carries a float LITERAL: with no
-- genuine float operand the same expression falls to `Rt.+`'s INT arm —
-- `toFloat big + toFloat big` prints `2305843009213693952` (the exact i64),
-- not the float rendering — so a row written that way would pin boxed+boxed
-- INTEGER addition and never enter the float arm.  Every entry below keeps a
-- real float operand so the float arm is the arm that runs.
--
-- The VAL arm is the oracle, as for every row in this gate: it never boxes, so
-- it reaches the same doubles by a different route.

{-| 2^60 — the first value outside the i61 fixnum range, i.e. the smallest
magnitude that BOXES.  Everything below is built on it.
-}
big : Int
big =
    1152921504606846976


{-| (a) the boxed int on the LEFT of a float add: `Rt.+` sees a code-13 cell
and a float, takes its float arm, and unboxes the cell through `Rt.asF`.
-}
boxadd : Float
boxadd =
    Basics.toFloat big + 0.5


{-| (b) the same sum the other way round, so the boxed operand arrives as the
SECOND argument: the arm tests `tagis(a, 12) || tagis(bb, 12)` and the two
`asF` calls are separate sites, so one order working says nothing about the
other.
-}
boxaddrev : Float
boxaddrev =
    0.5 + Basics.toFloat big


{-| (c) the RESULT path at scale: the float operand is 1.0e19, so the sum
(1.1152921504606847e19) is past INT64_MAX — it cannot be an i64 at all.  A
float result is never re-boxed as an int (`mkflt`, not `mknum`), and this row
says so with a value that would be garbage if anything on the result path
treated it as one.  It also keeps the unbox honest at the top of the range:
the double it prints is the exact conversion of the boxed i64 plus 10^19.
-}
boxbigsum : Float
boxbigsum =
    Basics.toFloat big + 1.0e19
