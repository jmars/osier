module FlatNest exposing (main, nestedTupleAlt, deepListAlt, patternArgs, exactTupleAlt, exactListAlt, zipPair)

-- FLATNEST: the shapes where the flattening pass walks PAST a component.
--
-- A `Step` path that lands on an opaque COMPONENT (`SubVal`) carries no
-- structural information, so a tag test there is UNDECIDABLE and the pass must
-- deny.  This fixture exists because a version of the pass answered `False`
-- for those tests instead — claiming a decided verdict about a value it did
-- not know — which SKIPPED an alt that should have matched and selected a
-- LATER one.  That is a silent wrong answer, and the ordinary elmvm
-- differential is what catches it: `nestedTupleAlt` and `deepListAlt` are
-- written so the wrong alt gives a different NUMBER (222 instead of 111, 444
-- instead of 333).
--
-- The last two entries are the shapes the pass CAN decide, and they pin the
-- other half of the same bug: a tuple is `buildTuple [ a, b ] = cons(a, b)`,
-- whose TAIL IS THE RAW SECOND ELEMENT — not a one-element chain as a list's
-- would be.  Conflating the two resolved `SndStep` off the end of the chain.

-- a nested TUPLE pattern: `MCons [FstStep]` lands on the component `( 1, 2 )`,
-- whose consness the shape does not know.
nestedTupleAlt : Int
nestedTupleAlt =
    let
        p =
            ( ( 1, 2 ), 3 )
    in
    case p of
        ( ( 1, 2 ), 3 ) ->
            111

        _ ->
            222


-- the same shape one level down a LIST: `MCons [HdStep]` lands on the
-- component `[ 1, 2 ]`.
deepListAlt : Int
deepListAlt =
    let
        l =
            [ [ 1, 2 ], [ 3 ] ]
    in
    case l of
        [ [ 1, 2 ], [ 3 ] ] ->
            333

        _ ->
            444


-- TWO PATTERN ARGUMENTS.  This compiler desugars it (Mid.Module.clauseCase)
-- into `Tup [ Var arg0, Var arg1 ]` plus a nested tuple pattern, i.e. exactly
-- the `MCons [FstStep]`-onto-a-component shape above — reached from ordinary
-- source, which is why the bug was live on the compiler's own code.
patternArgs : ( Int, Int ) -> ( Int, Int ) -> Int
patternArgs ( a, b ) ( c, d ) =
    a + 10 * b + 100 * c + 1000 * d


-- a FLAT tuple pattern over a local pair: decidable, and it flattens.
exactTupleAlt : Int
exactTupleAlt =
    let
        p =
            ( 5, 6 )
    in
    case p of
        ( a, b ) ->
            a + 10 * b


-- a FLAT list pattern over a local literal list: decidable, and it flattens.
exactListAlt : Int
exactListAlt =
    let
        l =
            [ 7, 8 ]
    in
    case l of
        [ a, b ] ->
            a + 10 * b

        _ ->
            0


-- THE SHAPE THAT ACTUALLY MISCOMPILED THE COMPILER, copied from
-- Type/Exhaustive.unifyList: a case over a literal TUPLE of two list
-- parameters, whose FIRST two alts test `[]` / `::` at a path that lands on a
-- COMPONENT (`Var a`, `Var b`).  The bug answered those tag tests FALSE, so
-- BOTH alts were skipped and the catch-all was selected — the whole case body
-- became 999 (in the compiler it became `Nothing`, and the self-hosted
-- compiler then rejected its own Prelude with "arity mismatch").  The
-- nestedTupleAlt entry above did NOT catch it, because its alts also carry an
-- undecidable MLitEq that masks the false verdict as undecidable.
zipPair : List Int -> List Int -> Int
zipPair a b =
    case ( a, b ) of
        ( [], [] ) ->
            1

        ( x :: _, y :: _ ) ->
            x + 10 * y

        _ ->
            999


main : Int
main =
    zipPair [ 1, 2 ] [ 3, 4 ]
        + zipPair [] []
        + nestedTupleAlt
        + deepListAlt
        + patternArgs ( 1, 2 ) ( 3, 4 )
        + exactTupleAlt
        + exactListAlt


