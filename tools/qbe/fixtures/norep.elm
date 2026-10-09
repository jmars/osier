module NoRep exposing
    ( main, chain, boxed, polyLocal, capture, intCase, cmp, eqInt, floatLocal, floatParam
    , floatCapture, slotCount
    )

-- UNBOXED Int LOCALS — the differential matrix for monomorphisation step S4/M1
-- (Mid/Qbe/Lower.elm's "S4: UNBOXED Int LOCALS" section; switch QBE_NOREP=1).
--
-- WHY THIS FIXTURE EXISTS.  S4 changes the REPRESENTATION of an Int local from
-- a tagged 40-byte frame slot to a raw QBE `l` operand, and reboxes it at every
-- boundary.  The failure mode is not a crash and not a build error: a
-- representation mismatch produces a binary that BUILDS, RUNS, EXITS 0 and
-- prints a DIFFERENT NUMBER (the same silent-wrong class the float unit found).
-- A single happy path therefore proves nothing here — every entry below is a
-- separate build, and each one's stdout must match elmvm's byte-for-byte
-- (tools/qbe/qbe-check.sh `run`, plus its gc-churn rerun).
--
-- WHAT EACH ENTRY PINS:
--   * `chain`      — the raw chain itself: five Int locals, arithmetic between
--                    them, and an Int PARAMETER (the checker's half of the
--                    type source: `NoRep.chain : Int -> Int` is a closed
--                    monotype, so the peel hands param 0 to the pass).
--   * `boxed`      — the FIVE boundaries a raw local can cross: a saturated
--                    call argument, a record field, a tuple element, a list
--                    element, and the `:val` return.  Each one must rebox, and
--                    `boxed`'s own list is compared to elmvm's.
--   * `polyLocal`  — the IR half of the type source, and the ONLY shape that
--                    proves it exists: `polyTwice : (a -> a) -> a -> a` is
--                    POLYMORPHIC, so the checker's monotype gate yields nothing
--                    inside it, yet `step = 1 + 1` is provably an Int from the
--                    tree alone.  The `\y -> y + 3` lambda's parameter is NOT
--                    provable (its type is `a`) and must stay boxed.
--   * `capture`    — a raw local ESCAPING into a closure.  The capture blit is
--                    the one boundary that does not go through `lowerVal`, so
--                    it has its own rebox; if that rebox is missing the closure
--                    reads a raw word as a tagged Value.
--   * `intCase`    — a raw local as a `case` SCRUTINEE (rebox into the
--                    scrutinee slot) and an Int literal pattern (MLitEq).
--   * `cmp`/`eqInt`— the `<` and `==` fast paths (one i64 compare each, no tag
--                    test, no rt_prim) with a raw local on either side.
--   * `floatLocal` — the FLOAT half (S4f): Float locals seeded by float
--                    literals ARE unboxed, and `v + x` reboxes one of them at
--                    the call boundary.  Its .ssa must DIFFER on/off.
--   * `floatParam` — the DENY control for that half, and the measured reason
--                    it exists: a Float PARAMETER is not a raw source (the
--                    front end tags an integer token typed Float as
--                    `tagNumber`, and the VM promotes it, so a raw read of
--                    the parameter's payload is a silent wrong answer).  Its
--                    .ssa must be BYTE-IDENTICAL on/off.
--   * `floatCapture`— a raw float escaping into a closure (the capture-blit
--                    rebox, the one boundary that bypasses `lowerVal`).
--   * `slotCount`  — the STRUCTURAL counter, in-band: 16 Int locals in one
--                    defun.  With the pass on, none of them takes a frame slot;
--                    qbe-check.sh greps the two builds so the counter, not only
--                    the clock, has to move.

-- 1. the raw chain.
chain : Int -> Int
chain n =
    let
        a =
            2 + 3

        b =
            a * 4

        c =
            b - n

        d =
            c * c + a

        e =
            d - c
    in
    e


addInt : Int -> Int -> Int
addInt a b =
    a + b


fib : Int -> Int
fib n =
    if n < 2 then
        n

    else
        fib (n - 1) + fib (n - 2)


-- 2. every boundary.
boxed : Int -> List Int
boxed n =
    let
        k =
            n * 3 + 1

        rec =
            { v = k, w = k + 1 }

        pair =
            ( k, rec.v )

        first =
            Tuple.first pair
    in
    [ k, rec.w, first, addInt k 10, fib k ]


-- 3. the IR half of the type source, inside a POLYMORPHIC defun.
polyTwice : (a -> a) -> a -> a
polyTwice f x =
    let
        step =
            1 + 1
    in
    if step > 0 then
        f (f x)

    else
        x


polyLocal : Int
polyLocal =
    polyTwice (\y -> y + 3) 4


-- 4. a raw local escaping into a closure.
capture : Int -> Int
capture n =
    let
        base =
            n * 2 + 1

        addBase =
            \x -> x + base
    in
    addBase 5 + addBase 100


-- 5. a raw local as a case scrutinee (rebox into the scrutinee slot).
intCase : Int -> Int
intCase n =
    let
        m =
            n - 3
    in
    case m of
        0 ->
            100

        1 ->
            200

        _ ->
            300


-- 6. the compare and equality fast paths.
cmp : Int -> Int
cmp n =
    let
        a =
            n + 1

        b =
            n * 2
    in
    if a < b then
        1

    else
        0


eqInt : Int -> Int
eqInt n =
    let
        a =
            n + 7
    in
    if a == n + 7 then
        1

    else
        0


-- 7. FLOAT LOCALS (S4f): the three locals are seeded by float LITERALS, so
-- their Float-ness is proven from the tree, and `v + x` then mixes a RAW float
-- with the unproven parameter — the rebox boundary.  This entry is the one
-- whose .ssa MUST differ with the pass on and off.
floatLocal : Float -> Float
floatLocal x =
    let
        y =
            1.5

        z =
            y + 2.25

        w =
            z * 2.0

        v =
            w - 0.5
    in
    v + x


-- 8. the DENY control for the FLOAT half, and the MEASURED reason it exists:
-- `x + 1.5` here is the same shape as `floatLocal`'s chain, but the chain is
-- seeded by the PARAMETER.  A Float parameter is not a raw source
-- (Mid/Qbe/Lower.elm's S4f section): this front end materializes an integer
-- token the checker typed Float as `tagNumber` (Mid/FromAst.elm), and the VM's
-- `+` PROMOTES it, so `floatParam 3` is 4.5 in the VM while a raw `loadd` of
-- that parameter's payload is 1.0 — measured.  So this entry's .ssa must be
-- BYTE-IDENTICAL on and off, and qbe-check.sh runs it with an INT argument.
floatParam : Float -> Float
floatParam x =
    let
        y =
            x + 1.5

        z =
            y * 2.0
    in
    z - 0.5


-- 9. a RAW float ESCAPING into a closure.  The capture blit is the one
-- boundary that does not go through `lowerVal`, so it has its own rebox
-- (`captureBlits`); if that rebox is missing the closure reads a raw double as
-- a tagged Value.
floatCapture : Float -> Float
floatCapture n =
    let
        w =
            1.5 + 2.25

        g =
            \u -> u + w
    in
    g n


-- 10. the structural counter: 16 Int locals in one defun.
slotCount : Int -> Int
slotCount n =
    let
        a1 =
            n + 1

        a2 =
            a1 + 1

        a3 =
            a2 + 1

        a4 =
            a3 + 1

        a5 =
            a4 + 1

        a6 =
            a5 + 1

        a7 =
            a6 + 1

        a8 =
            a7 + 1

        a9 =
            a8 + 1

        a10 =
            a9 + 1

        a11 =
            a10 + 1

        a12 =
            a11 + 1

        a13 =
            a12 + 1

        a14 =
            a13 + 1

        a15 =
            a14 + 1

        a16 =
            a15 + 1
    in
    a16


-- the aggregate entry the differential builds in ONE binary: every shape
-- above except the Float entries `floatLocal`/`floatParam`/`floatCapture`
-- (each has its own entry, and they print Floats rather than Ints).
sumInts : List Int -> Int
sumInts xs =
    case xs of
        x :: rest ->
            x + sumInts rest

        [] ->
            0


main : Int
main =
    chain 5 + polyLocal + capture 3 + intCase 4 + cmp 6 + eqInt 9 + slotCount 2 + sumInts (boxed 7)
