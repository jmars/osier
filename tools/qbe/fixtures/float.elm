module Flt exposing
    ( main, lit, neg, add, sub, mul, div, ltc, lec, gtc, gec, eqc, neq
    , tiny, big, bigNeg, infLit, negInfLit, denorm
    , fromIntF, recField, tupleF, listSum, viaFn, idF
    , strF, strI, nan, loop
    , negZeroEq, negZeroInv, infArith, infCmp, nanEq, nanLt, nanGe
    , maxF, denormSum, recFieldRaw, listRaw, intAtFloat, floatCmpChain
    , fdivIntTokens, fdivZero, fdivMixed
    )

-- FLOAT — the differential matrix for the native backend's Float support.
--
-- WHY THIS FIXTURE EXISTS: a float literal used to lower to a TAG-ONLY cell
-- (Mid/Qbe/Lower.elm's LFloat arm loaded the double INTO the payload-address
-- temporary instead of storing it through it, so the payload was never
-- written and Peephole's dead-pure-def rule deleted the load), and the static
-- data item was printed in a form the vendored QBE's lexer rejects
-- (`d 0.0` — `unknown keyword .0`).  Both were SILENT: the IL parsed (after
-- the data form was hand-patched) and the binary exited 0 printing 0.0.
-- The matrix then found a THIRD member of the same class that no literal in
-- the suite reached: a non-finite literal (`1.0e400`) is rendered by
-- String.fromFloat as "Infinity", and printFloat appended its ".0" suffix to
-- that spelling too, so the data item read `d_Infinity.0` and C's strtod
-- stopped at the '.' — `unknown keyword .0` again.
--
-- So a single happy path is not evidence here.  Every entry below is run on
-- elmvm AND on the native binary with IDENTICAL stdout required (see
-- tools/qbe/qbe-check.sh): the literal alone, everything the inline fast path
-- handles (+ - * and the < <= == branches), the operands where the fast path
-- must DECLINE to rt_prim (a float on either side, and `/`), negatives,
-- magnitudes at both ends of `printFloat`'s text (1e-7 / 1e22, where JS's
-- Number::toString switches to exponential notation), a float crossing a
-- record field and a list, floats returned from and passed to functions, the
-- `Float`/`Int` ends of the String.fromFloat conversion, and a
-- float-accumulating loop.

sumF : List Float -> Float
sumF xs =
    case xs of
        x :: rest ->
            x + sumF rest

        [] ->
            0.0


addF : Float -> Float -> Float
addF a b =
    a + b


-- the generic-at-Float shape of tools/bench/suite/mono_float.elm, small.
iter : Int -> Float -> Float
iter n acc =
    if n <= 0 then
        acc

    else
        iter (n - 1) (acc + 1.5)


-- a bare float literal: the payload must actually be written.
lit : Float
lit =
    1.5


-- a negative literal (either a negated literal or one carrying the sign —
-- both must reach the payload as -1.5).
neg : Float
neg =
    -1.5


-- the three inlined arith ops, over operands that are BOTH floats (the
-- operand is tagged 12, so the inline integer `add` on the payload must not
-- be taken).
add : Float
add =
    1.5 + 2.25


sub : Float
sub =
    5.5 - 1.25


mul : Float
mul =
    3.0 * 2.5


-- `/` is not in the inline table at all: it always goes to rt_prim, whose
-- float path is the VM's own primitive.
div : Float
div =
    7.0 / 2.0


-- the comparison fast path inlines ONLY when both sides are Number and
-- neither is Float; a float operand must fall to rt_prim.
ltc : Bool
ltc =
    1.5 < 2.5


lec : Bool
lec =
    2.5 <= 2.5


gtc : Bool
gtc =
    2.5 > 1.5


gec : Bool
gec =
    2.5 >= 2.5


eqc : Bool
eqc =
    1.5 == 1.5


neq : Bool
neq =
    1.5 == 2.5


-- printFloat's edges: below 1e-6 and above 1e21 JS Number::toString switches
-- to exponential ("1e-7" / "1e+22"), so the data-item text stops looking like
-- a plain decimal — and C's %lf (what QBE's data lexer runs) must read it.
tiny : Float
tiny =
    1.0e-7


big : Float
big =
    1.0e22


bigNeg : Float
bigNeg =
    -1.0e22


-- NON-FINITE LITERALS: Elm's parser has no "Infinity" spelling, but an
-- overflowed literal produces one (`String.fromFloat 1.0e400 == "Infinity"`),
-- and the DATA ITEM is what has to survive the vendored lexer.  `printFloat`
-- used to append its ".0" suffix to that spelling too, emitting
-- `d_Infinity.0`; C's strtod reads the INFINITY prefix and stops at the '.',
-- so qbe answered `unknown keyword .0` and the build died.  The other end of
-- the magnitude range rides the same path (`5.0e-324` -> `d_5e-324`).
infLit : Float
infLit =
    1.0e400


negInfLit : Float
negInfLit =
    -1.0e400


denorm : Float
denorm =
    5.0e-324


-- the Float end of the Int -> Float conversion.
fromIntF : Float
fromIntF =
    Basics.toFloat 3


-- a float stored in and read back from a record field.
recField : Float
recField =
    { a = 1.5, b = 2.25 }.b


-- a float crossing a TUPLE (a destructuring let, so the value is carried
-- through the aggregate representation, not just read once).
tupleF : Float
tupleF =
    let
        ( a, b ) =
            ( 1.5, 2.25 )
    in
    a + b


-- floats stored in and read back from a list.
listSum : Float
listSum =
    sumF [ 1.5, 2.25, 3.0 ]


-- a float RETURNED from a function and PASSED as an argument to another.
viaFn : Float
viaFn =
    addF (addF 1.0 2.0) (addF 4.0 8.0)


-- the CLI-argument entry: `Flt.idF 2.5` exercises the driver's float
-- argument path (tools/qbe/rt.zig) against elmvm's.
idF : Float -> Float
idF x =
    x + 1.0


-- the two ends of the conversion path, as STRINGS (rendered by the VM's own
-- printValue, so the text is compared byte-for-byte).
strF : String
strF =
    String.fromFloat 3.0


strI : String
strI =
    String.fromFloat (Basics.toFloat 3)


-- non-finite: produced (not literal), so it exercises the arith/compare
-- paths and printValue, not the data-item lexer.
nan : Float
nan =
    0.0 / 0.0


-- a float-accumulating loop of 100000 iterations.
loop : Float
loop =
    iter 100000 0.0


main =
    add + sub + mul + div + lit + neg + tiny + big + bigNeg + fromIntF + recField + tupleF + listSum + viaFn + loop


-- ================== S4f: the HOSTILE float cases ==================
-- Unboxing a Float local deletes the tag test, so every case below is one
-- where the tag or the IEEE edge case is the whole answer.  Each entry is its
-- own build and its stdout must match elmvm's byte-for-byte (qbe-check.sh).
--
-- `a f/ b` and `a + b` on two raw floats are now ONE QBE `d` op; a comparison
-- on two raw floats is ONE `ceqd`/`cltd`/`cled`/`cgtd`/`cged`.  NaN and the
-- signed zero are where a "close enough" implementation diverges, so they are
-- pinned separately rather than folded into one happy path.


-- NaN: `==` is FALSE and every ordered compare is FALSE (the VM's primEq on
-- two floats is `asFloat a1 == asFloat a2`, i.e. IEEE — not a tag or a bit
-- compare, which would say true).
nanEq : Bool
nanEq =
    (0.0 / 0.0) == (0.0 / 0.0)


nanLt : Bool
nanLt =
    (0.0 / 0.0) < 1.0


nanGe : Bool
nanGe =
    (0.0 / 0.0) >= 1.0


-- SIGNED ZERO: `-0.0 == 0.0` is TRUE (IEEE), and the sign still reaches a
-- division (`1.0 / -0.0` is -Infinity).  The literal `-0.0` is unspellable in
-- both backends (String.fromFloat -0.0 is "0"), so the zero is PRODUCED
-- arithmetically — which is also what the arith fast path must get right.
negZeroEq : Bool
negZeroEq =
    (-1.0 * 0.0) == 0.0


negZeroInv : Float
negZeroInv =
    1.0 / (-1.0 * 0.0)


-- INFINITY, produced (not a literal): 1.0e308 * 10.0 overflows to Infinity,
-- and it stays Infinity through a comparison.  NOTE `2.0e308` is NOT a finite
-- literal on either side — it overflows at parse — so magnitudes here stay
-- inside the f64 range or are meant to be Infinity.
infArith : Float
infArith =
    1.0e308 * 10.0


infCmp : Bool
infCmp =
    1.0e400 > 1.0e308


-- the largest finite double, and an accumulation at the BOTTOM of the range
-- (5e-324 is the smallest subnormal; two of them are exactly 1e-323).
maxF : Float
maxF =
    1.7976931348623157e308


denormSum : Float
denormSum =
    5.0e-324 + 5.0e-324


-- a RAW float stored into a record field and a list, then read back: the
-- store is a rebox boundary (`lowerVal`), and the read is a field/element
-- load the pass cannot prove, so those stay boxed and on rt_prim.
recFieldRaw : Float
recFieldRaw =
    let
        w =
            1.5 + 2.25

        r =
            { f = w }
    in
    r.f * 2.0


listRaw : Float
listRaw =
    let
        w =
            1.0 + 0.5
    in
    sumF [ w, 2.0 ]


-- THE CASE THAT DENIES THE FLOAT-PARAMETER HALF OF THE PASS, kept in the
-- differential so it cannot come back: `3` is an integer TOKEN that the
-- checker types Float, and this front end materializes it as `tagNumber`
-- (Mid/FromAst.elm).  The VM's `+` PROMOTES it, so `addF 3 1.0` is 4.0 — while
-- reading that parameter's payload as a raw double would answer 1.0
-- (MEASURED).  A Float parameter is therefore not a raw source.
intAtFloat : Float
intAtFloat =
    addF 3 1.0


-- `f/` ROUTING, the three shapes that decide whether `/` is Elm's float
-- division or an i64 divide.  `7 / 2` is well-typed Elm (integer tokens unify
-- with Float) and primFdiv PROMOTES, so it is 3.5 — a path that decides "not a
-- float, use the integer op" answers 3.  These two entries caught exactly that
-- in this pass's first cut: `7 / 2` printed 3, and `1 / 0` — Infinity in the
-- VM — took an i64 `div` and died with SIGFPE (empty output, nonzero exit).
fdivIntTokens : Float
fdivIntTokens =
    7 / 2


fdivZero : Float
fdivZero =
    1 / 0


-- a RAW float over an integer token: the `divd` fast path must DECLINE (one
-- operand is not proven Float) and leave the promotion to rt_prim.
fdivMixed : Float
fdivMixed =
    let
        w =
            3.0 + 4.0
    in
    w / 2


-- every float compare on two RAW operands in one conjunction (a >= b, a == b,
-- a > c, c < a, c <= a, not (a < b)) — six compares and no rt_prim call.
floatCmpChain : Bool
floatCmpChain =
    let
        a =
            1.5 + 1.0

        b =
            3.0 - 0.5

        c =
            1.0
    in
    (a >= b) && (a == b) && (a > c) && (c < a) && (c <= a) && not (a < b)
