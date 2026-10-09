module NoFlatten exposing (main, retRec, capRec, passRec, passList, storeRec, retCon, aliasRec, tailPattern)

-- NO-FLATTEN: the NEGATIVE direction of Mid.Qbe.Flatten (handoff-qbe-flatten).
--
-- Every aggregate here is structurally similar to one in `flatten.elm` but
-- ESCAPES the defun that built it, so the pass MUST NOT flatten it: flattening
-- an escaping aggregate produces a wrong program with no diagnostic.  The
-- behavioural half of this fixture is the ordinary qbe-check comparison with
-- elmvm; the STRUCTURAL half is qbe-check's assertion that the aggregate
-- prims (`assoc`/`snd`/`@p`/`rt_con`) are STILL PRESENT in the emitted code —
-- a pass that regressed to "flatten everything" would keep the same numbers
-- here only by accident, and would lose the structure immediately.
--
-- One case per escape route:
--   retRec   - RETURNED (an ordinary `Var` in tail position)
--   capRec   - CAPTURED by a closure (`Lam`)
--   passRec  - PASSED AS A CALL ARGUMENT (`App`)
--   passList - a LIST passed as a call argument
--   storeRec - STORED INTO another aggregate (a tuple) that itself escapes
--   retCon   - a CONSTRUCTOR returned, matched by the CALLER
--   aliasRec - reached through an ALIAS (`let a = r in a.a`)
--   tailPattern - a LIST pattern whose bind lands on the TAIL sub-list
--                 (`y :: ys`): the tail is not a single value, so the pass
--                 denies rather than rebuilding the cons chain

type Wrap
    = Wrap Int


retRec : { a : Int, b : Int }
retRec =
    let
        r =
            { a = 1, b = 2 }
    in
    r


capRec : Int
capRec =
    let
        r =
            { a = 5, b = 6 }
    in
    (\n -> r.a + n) 10


sumRec : { a : Int, b : Int } -> Int
sumRec r =
    r.a + 10 * r.b


passRec : Int
passRec =
    let
        r =
            { a = 7, b = 8 }
    in
    sumRec r


lenList : List Int -> Int
lenList l =
    case l of
        _ :: t ->
            1 + lenList t

        [] ->
            0


passList : Int
passList =
    let
        l =
            [ 1, 2, 3 ]
    in
    lenList l


tsum : ( { a : Int, b : Int }, Int ) -> Int
tsum p =
    case p of
        ( s, _ ) ->
            s.a + 10 * s.b


storeRec : Int
storeRec =
    let
        r =
            { a = 9, b = 10 }

        p =
            ( r, 0 )
    in
    tsum p


unwrap : Wrap -> Int
unwrap w =
    case w of
        Wrap n ->
            n + 1000


retCon : Int
retCon =
    let
        w =
            Wrap 4
    in
    unwrap w


aliasRec : Int
aliasRec =
    let
        r =
            { a = 33, b = 44 }

        a =
            r
    in
    a.a + 10 * a.b


tailPattern : Int
tailPattern =
    let
        l =
            [ 1, 2, 3 ]
    in
    case l of
        y :: ys ->
            y + lenList ys

        [] ->
            0


main : Int
main =
    retRec.a
        + 10 * retRec.b
        + capRec
        + passRec
        + passList
        + storeRec
        + retCon
        + aliasRec
        + tailPattern
