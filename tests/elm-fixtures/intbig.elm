module Intbig exposing (above53, bigdiff, bigmul, hexmax, maxi64, mini64, patmatch)

-- L3-U1 — THE i64 LITERAL RANGE, end to end (design §7 U1).
--
-- Every literal in this file is above the OLD frontend bound (|n| <= 2^53),
-- so before the exact (limb) parser not one of them could be written: a
-- 19-digit literal was `err parse failed` (the message was even thrown away by
-- `Mid.Module.parseOne`) and a small-but-inexact one was silently rounded.
-- Each value below is pinned EXACTLY by its gate row, so a rounding anywhere
-- on the path — parser, `Lit.LNumberBig`, the emitter's limb split — prints a
-- different number.
--
-- Nothing here is above INT64_MAX, and no row needs the runtime to be clever:
-- these are literals in, literals out.


{-| INT64_MAX, digit for digit. A host whose Int is a double cannot hold this
(2^63-1 rounds UP to 2^63), so printing it as itself proves the literal never
touched a host number.
-}
maxi64 : Int
maxi64 =
    9223372036854775807


{-| INT64_MIN, the ONE value that is legal only under a unary minus: the parser
accepts the magnitude 2^63 and the negation (`FromAst.negatedNumber`) turns it
into the canonical `-9223372036854775808` digits. The bare magnitude is a
compile error — see inttoobig.elm.
-}
mini64 : Int
mini64 =
    -9223372036854775808


{-| 2^53 + 1 — the first integer a double CANNOT hold, and the value the old
parser rounded to 2^53. It is only 16 digits, so this is the "small but
inexact" half of the defect, not the 19-digit half.
-}
above53 : Int
above53 =
    9007199254740993


{-| 2^60-1, spelled as a plain literal: the VR3b2 trap value. Under a double
host this and 2^60 are the SAME number, which is why the old word-arm bound
could not reject the first out-of-range fixnum.
-}
bigmul : Int
bigmul =
    1152921504606846975


{-| The same value reached by ARITHMETIC on the literal above (i64 add, no
runtime help): 2^60-1 + 1 = 2^60. Pinned so that a literal's exactness and the
runtime's own arithmetic are seen in one row.
-}
bigdiff : Int
bigdiff =
    1152921504606846975 + 1


{-| A big HEX literal: the same bound as decimal, and it arrives as canonical
DECIMAL digits (one form for every consumer). 0x7fffffffffffffff = INT64_MAX.
-}
hexmax : Int
hexmax =
    0x7fffffffffffffff


{-| A big literal in PATTERN position: `MLitEq` carries the digits and the
runtime compare is an i64 compare, so the test is exact over the whole range
(the path the design calls out as `MLitEq`/`AltLit`).
-}
patmatch : Int -> Int
patmatch x =
    case x of
        9223372036854775807 ->
            1

        _ ->
            0
