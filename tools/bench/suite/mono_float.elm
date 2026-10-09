module MonoFloat exposing (main, once)

-- SHAPE: mono_float -- THE MONOMORPHISATION AXIS, Float instantiation.
--
-- Same one generic `fold`, used here at THREE types with the weight on the
-- Float one (this is the only mono program that carries the Float
-- instantiation -- see mono_int.elm for why).  See mono_int.elm for the full
-- rationale, including why the generic is defined once per program rather
-- than shared by import.
--
-- NATIVE PATH -- WAS NOT EXPRESSIBLE ON QBE; RESOLVED 2026-10-09 (diagnosis
-- kept below; it is correct about what the vendored lexer does).
-- Measured then: every Float value in this front end originates from a float
-- LITERAL (Mid/Qbe/Lower.elm `LFloat` -> `freshData ("flt:" ++ ...)`), and
-- Mid/Qbe/Print.elm emitted that static as `data $dN = align 8 { d 0.0 }`.
-- The vendored QBE's data lexer has no decimal (vendor/qbe/parse.c getint()
-- reads digits only), so it answered `qbe: <file>.ssa:5: unknown keyword .0`
-- and the build died before linking.  And the failure had a SILENT-WRONG
-- half too: with the data form hand-patched, the LFloat arm loaded the
-- double INTO the payload-address temp instead of storing through it, so the
-- payload was never written -- the native binary built, exited 0 and
-- printed 0.0 where the VM prints 600000.0.
-- RESOLVED: Mid/Qbe/Il.elm gained `StoreD`; Mid/Qbe/Print.elm emits a double
-- data item as `{ d d_0.0 }` and spells a non-finite static as an FP token
-- (`d_Infinity`); Mid/Qbe/Lower.elm's LFloat stores the double through the
-- payload address; tools/qbe/rt.zig takes float entry args.  The QBE column
-- for this program is now a MEASURED row and the runner's DECLARED
-- not-expressible array is empty by design -- see tools/osier-bench.sh and
-- the README (finding 1, RESOLVED).  The VM runs it fine (it always did).


type alias Rec =
    { a : Int, b : Int }


-- >>> generic fold (byte-identical in mono_int/mono_float/mono_record) >>>
fold : (a -> b -> b) -> b -> List a -> b
fold f acc xs =
    case xs of
        [] ->
            acc

        y :: ys ->
            fold f (f y acc) ys


-- <<< generic fold <<<

rangeI : Int -> List Int -> List Int
rangeI n acc =
    if n <= 0 then
        acc

    else
        rangeI (n - 1) (n :: acc)


rangeF : Int -> List Float -> List Float
rangeF n acc =
    if n <= 0 then
        acc

    else
        rangeF (n - 1) (1.5 :: acc)


recs : List Rec
recs =
    [ { a = 1, b = 2 }, { a = 3, b = 4 } ]


-- the axis: the generic at Float
axisFloat : Float
axisFloat =
    fold (\x acc -> x + acc) 0.0 (rangeF 400000 [])


-- the generic at Int, kept live (small: the axis is what is timed)
probeInt : Float
probeInt =
    if fold (\x acc -> x + acc) 0 (rangeI 8 []) == 36 then
        0.0

    else
        1.0


-- the generic at the record type, kept live
probeRec : Float
probeRec =
    if fold (\x acc -> acc + x.a + x.b) 0 recs == 10 then
        0.0

    else
        1.0


once : Float -> Float
once n =
    fold (\x acc -> x + acc) 0.0 [ n, 1.5, 2.5 ]


main : Float
main =
    axisFloat + probeInt + probeRec
