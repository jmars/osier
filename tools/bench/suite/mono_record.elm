module MonoRecord exposing (main, once)

-- SHAPE: mono_record -- THE MONOMORPHISATION AXIS, record-type instantiation.
--
-- Same one generic `fold`, used here at TWO types with the weight on a
-- RECORD: `a` is the record type `Rec` and the accumulator `b` is itself a
-- record, rebuilt every step (`{ n = ..., s = ... }` is RETURNED into the
-- next `f` call, so it escapes and Flatten must not touch it -- which is the
-- point: this measures the record representation under a real allocation
-- stream, not the flattening of a local literal).
--
-- See mono_int.elm for the full rationale and for why the generic is defined
-- once per program rather than shared by import.  Float is absent here for
-- the same reason as in mono_int: a float literal makes the whole unit
-- unbuildable on the vendored QBE (mono_float.elm has the measurement).


type alias Rec =
    { a : Int, b : Int }


type alias Acc =
    { n : Int, s : Int }


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


-- 100000 records, each one a heap object the generic then walks
recList : Int -> List Rec -> List Rec
recList n acc =
    if n <= 0 then
        acc

    else
        recList (n - 1) ({ a = n, b = 2 } :: acc)


-- the axis: the generic at a record element type AND a record accumulator
axisRec : Acc
axisRec =
    fold (\x acc -> { n = acc.n + 1, s = acc.s + x.a + x.b }) { n = 0, s = 0 } (recList 100000 [])


-- the generic at Int, kept live (small: the axis is what is timed)
probeInt : Int
probeInt =
    fold (\x acc -> x + acc) 0 (rangeI 8 [])


once : Int -> Int
once n =
    (fold (\x acc -> { n = acc.n + 1, s = acc.s + x.a + x.b }) { n = 0, s = 0 } (recList n [])).s


main : Int
main =
    axisRec.n + axisRec.s + probeInt
