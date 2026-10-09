module MonoInt exposing (main, once)

-- SHAPE: mono_int -- THE MONOMORPHISATION AXIS, Int instantiation.
--
-- The one generic function below is instantiated at TWO types in this one
-- compilation unit: Int (the axis, and what `main` hammers) and the record
-- type `Rec`.  A monomorphising/specialising pass has one callee with two
-- distinct call-site representations to clone; a representation change
-- (unboxed Int, flattened record) has somewhere to show up.  mono_record is
-- the same program with the weight moved onto the record instantiation, and
-- mono_float carries the Float instantiation.
--
-- WHY Float IS ABSENT HERE: any float literal in the unit makes the whole
-- unit unbuildable on the vendored QBE (its data lexer has no decimal -- see
-- mono_float.elm for the measurement), which would take the entire
-- monomorphisation axis off the NATIVE backend -- the backend the axis
-- exists to inform.  The Float instantiation therefore lives only in
-- mono_float.elm, which is the one mono program declared not-expressible
-- natively.
--
-- WHY ONE FUNCTION, SEVERAL TYPES, IN ONE FILE: the compile unit here is the
-- file.  `node elm-compiler/run.js <one.elm> <out.csexp>` does NOT resolve
-- cross-module imports -- MEASURED: a two-module App.elm/Lib.elm compiles to
-- `err type error ... unknown name: Lib.twice` (run.js exits 0 and writes the
-- error into the bundle, so the bundle text is the oracle).  A shared
-- `Mono.elm` module is therefore not expressible in a single-file program;
-- "one generic function, not three" is honoured by defining it exactly ONCE
-- per program and instantiating it three ways.  The three mono programs carry
-- BYTE-IDENTICAL text between the two generic-fold markers below, and
-- tools/osier-bench.sh asserts that with a checksum -- a copy that drifted
-- apart fails the run.


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


recs : List Rec
recs =
    [ { a = 1, b = 2 }, { a = 3, b = 4 } ]


-- the axis: the generic at Int
axisInt : Int
axisInt =
    fold (\x acc -> x + acc) 0 (rangeI 400000 [])


-- the generic at the record type, kept live (small: the axis is what is timed)
probeRec : Int
probeRec =
    fold (\x acc -> acc + x.a + x.b) 0 recs


once : Int -> Int
once n =
    fold (\x acc -> x + acc) 0 [ n, 1, 2 ]


main : Int
main =
    axisInt + probeRec
