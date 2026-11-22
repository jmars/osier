module Boxfloat exposing (boxadd, boxaddint, boxaddrev, boxbigsum, boxnegbox, boxnegint)

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
-- THE SECOND READER PAIR — boxed + boxed INTEGER addition whose SUM RE-BOXES
-- (`boxaddint`).  The float rows above pin the unbox; they say nothing about
-- the OTHER end of the round trip.  Here both operands arrive as code-13
-- cells, `Rt.+`'s INT arm unboxes both, and the sum is itself outside the i61
-- fixnum range, so `mknum`'s one overflow check must take its failure branch
-- and box the result a SECOND time.  Nothing else in the tree exercises the
-- double round trip: the three float rows return a float (never re-boxed), and
-- every `intbig` row's result is inside the fixnum range.
--
-- WHY EACH OPERAND BOXES, and why the SUM does too (arithmetic, not intent).
-- The bound is EXCLUSIVE in magnitude: a fixnum is `-2^60 <= n < 2^60`.  So
-- 1152921504606846976 (2^60) and 1152921504606846977 (2^60 + 1) are both the
-- FIRST magnitude that does not fit — each is materialised through
-- `Rt.boxInt`.  Their sum is 2305843009213693953 = 2^61 + 1: greater than
-- 2^60, so it cannot be a fixnum either, and far below INT64_MAX
-- (9223372036854775807), so it IS representable as an i64 and the boxed body
-- holds the exact sum.  The +1 in the second operand is deliberate: it is the
-- only bit below 2^60 in the answer, so a lost low limb, a truncated unbox or
-- a one-operand unbox prints a different number instead of the same one.
--
-- The VAL arm is the oracle, as for every row in this gate: it never boxes, so
-- it reaches the same i64 by a different route.

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


{-| 2^60 + 1 — the SECOND boxed operand. Outside the exclusive bound, so it
boxes like `big`; the odd low bit is what makes the sum below discriminate a
lost or truncated low limb.
-}
bigodd : Int
bigodd =
    1152921504606846977


{-| (d) THE DOUBLE ROUND TRIP: boxed + boxed INTEGER addition whose sum
(2^61 + 1) is itself outside the fixnum range, so `Rt.+`'s int arm unboxes
BOTH operands through `payload(x, 0)` and `mknum` boxes the RESULT again.
-}
boxaddint : Int
boxaddint =
    big + bigodd


{-| -2^60 — the NEGATIVE end of the same bound.  The bound is EXCLUSIVE IN
MAGNITUDE (`-limit <= n < limit`, `Mid/RtLayout.wordFixnumLimit`), so unlike
its positive twin `big` this value IS a fixnum: `-2^60 << 3` is exactly
INT64_MIN and sar-round-trips.  MEASURED in the emit: `q_Boxfloat_x2ebigneg`
stores `n * 8` built from limbs and shifted at runtime, with NO
`call $q_Rt_x2eboxInt`.
-}
bigneg : Int
bigneg =
    -1152921504606846976


{-| (e) THE NEGATIVE RE-BOX: fixnum + fixnum whose sum (-2^61) is outside the
i61 range on the NEGATIVE side, so `Rt.+`'s int arm adds two tagged immediates,
the `shl`/`sar`/`ceql` round trip fails in the other direction, and `mknum`
boxes the result a second time with a NEGATIVE body.
-}
boxnegint : Int
boxnegint =
    bigneg + bigneg


{-| -(2^60 + 1) — the NEGATIVE operand that BOXES.  The bound is
`-2^60 <= n < 2^60`, so `-2^60` (bigneg, above) is still a fixnum while one
more in magnitude is not: this literal goes through `Rt.boxInt` exactly as its
positive twin `bigodd` does, unlike `bigneg`.  MEASURED in the emit:
`q_Boxfloat_x2ebignegodd` ends `call $q_Rt_x2eboxInt`.
-}
bignegodd : Int
bignegodd =
    -1152921504606846977


{-| (f) THE OPERAND-END SEAT WITH A NEGATIVE BODY: boxed + boxed, where each
operand is the NEGATIVE out-of-range literal -(2^60 + 1) and the sum
(-2305843009213693954 = -(2^61 + 2)) re-boxes again.  `boxnegint` next door
feeds the same result-end seat from FIXNUM operands, so the two rows pin the
two operand shapes separately; only this one has `Rt.boxInt` on the operand
side with a negative body.
-}
boxnegbox : Int
boxnegbox =
    bignegodd + bignegodd
