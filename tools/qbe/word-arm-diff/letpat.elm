module M exposing (main)

-- THE S4/S4f GATE, EXECUTED (perf word-arm-surface).
--
-- `let ( a, b ) = ( 1, "hi" )` is the smallest program that reaches the
-- UNBOXED-LOCAL passes on the word arm.  Flatten eliminates the destructuring
-- and substitutes the literals, so `a` binds the literal 1 — and S4 proved it an
-- Int from that literal, held it as a RAW `l` operand with NO FRAME SLOT, and
-- reboxed it at the boundary.  `reboxArg` writes `tagNumber` at the slot and the
-- payload at `slot + 8`: SIXTEEN bytes into an EIGHT-byte word-arm slot, which
-- is the next slot.  MEASURED before the gate: this printed `[cons "hi" . 0]`
-- on the word arm against `[cons "hi" . 1]` on the val arm — a silent
-- mixed-representation write, on a program with no arithmetic anywhere.
--
-- `b` is used through a THIRD binder (`c`) so the substituted string is read
-- back rather than merely re-stored, and the result is a tuple so the printer
-- walks the string cell too.  Both arms must print `[cons "hi" . 1]`.
main =
    let
        ( a, b ) =
            ( 1, "hi" )

        c =
            b
    in
    ( c, a )
