module Intpow exposing (powbig, powneg, powsmall, powwrap, powzero)

-- L1 — THE `^` OPERATOR (design §9): `Int -> Int -> Int`, a runtime prim
-- (`Rt.pow`), exponentiation by squaring.
--
-- The semantics are the ones L3 decides for `*`: an exact product with i64
-- two's-complement WRAP, `0 ^ 0 = 1`, and a NAMED HALT on a negative exponent
-- (the quiet alternative — answering 0 — is priced and rejected in the design:
-- a wrong-quiet value is the class this program is eradicating).
--
-- `^` was ALREADY in the parser (Elm's precedence 8, right-associative); what
-- did not exist was a checker row, a lowering row and a runtime prim, so every
-- `^` in a program was an unknown-operator error. (The compiler's own source
-- records that: `Mid/RtLayout.elm` used to spell 2^60 as a product because
-- `2 ^ tagBits` "broke the self-host emit".)


{-| The ordinary case: 2^10.
-}
powsmall : Int
powsmall =
    2 ^ 10


{-| The convention at the degenerate corner: `0 ^ 0` is 1 (the accumulator's
start), not 0.
-}
powzero : Int
powzero =
    0 ^ 0


{-| WRAP, consistently with `*`: 2^64 is 0 in i64.
-}
powwrap : Int
powwrap =
    2 ^ 64


{-| A big exact product: 3^39 = 4052555153018976267 (below INT64_MAX, and the
literal proves the result exactly).
-}
powbig : Int
powbig =
    3 ^ 39


{-| A NEGATIVE exponent is a named halt (row: exit 1 + the runtime's message).
Takes its operand from argv so the exponent is a runtime value.
-}
powneg : Int -> Int
powneg x =
    2 ^ (0 - x)
