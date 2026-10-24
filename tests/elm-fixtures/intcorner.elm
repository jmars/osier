module Intcorner exposing (divzero, minbyneg, truncdiv, wrapmul)

-- L3-U0 — THE EXTREME-Int CORNERS, PINNED AS THEY BEHAVE TODAY.
--
-- The language's Int is ALREADY an i64 at execution (design §0, MEASURED):
-- `Rt.+ - *` compute on QBE words, `Rt./` is a word div, so wrap and
-- truncation-toward-zero are what compiled programs do right now. What was
-- missing is a row that SAYS so: before this fixture no gate row pinned a
-- value outside [-2^53, 2^53] or a division corner at all.
--
-- Each function takes its operand from argv (the gate's rows pass it) so the
-- arithmetic stays visible as arithmetic — no literal in this file is above
-- 2^53, because the frontend cannot spell one yet (that is L3-U1).
--
-- THE TWO DIVISION ROWS ARE DELIBERATE PINS OF A CRASH. `//` with a zero
-- divisor and INT64_MIN // -1 are SIGFPE core dumps today: QBE lowers `div`
-- to the hardware idiv, whose two defined traps are exactly these. They are
-- pinned HERE so that L3-U2's change of behaviour is an ASYMMETRY PROOF — the
-- row was green on the crash, and it is green on the named error only after
-- the pre-check lands. A row added at the same time as the fix could not
-- distinguish "the fix works" from "the row was written to match it".


{-| 2^64 wraps to 0: `x * 1024^6` is 2^60 at x = 1, and `* 16` takes it past
INT64_MAX, where two's-complement arithmetic answers 0.
-}
wrapmul : Int -> Int
wrapmul x =
    x * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 16


{-| `//` truncates TOWARD ZERO (C/QBE idiv), not toward negative infinity:
(0 - 7) // 2 is -3, where a floor-division language answers -4.
-}
truncdiv : Int -> Int
truncdiv x =
    (0 - x) // 2


{-| Division by zero. TODAY: SIGFPE (exit 136, core dump). U2: a named halt.
-}
divzero : Int -> Int
divzero x =
    100 // x


{-| INT64_MIN // -1 — the quotient is 2^63, which is not an i64, so idiv
traps. The dividend is spelled as a product: `0 - (2^60 * 8)` is INT64_MIN
bit-for-bit (2^63 wraps to INT64_MIN, and `0 - INT64_MIN` is INT64_MIN again,
so the value does not depend on which side of the wrap the product lands).
TODAY: SIGFPE. U2: a named halt.
-}
minbyneg : Int -> Int
minbyneg x =
    (0 - (x * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 * 8)) // (0 - 1)
