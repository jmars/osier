module CensusSeats exposing (a)

-- THE USED-PRIM CENSUS' SIX SEATS, in one small committed program
-- (handoff osier-midrt-fix, from the step-5 pre-flip review).  The census
-- (`Mid.Qbe.Lower.calledPrims`) decides which `Rt.*` defuns a compile SEEDS —
-- and therefore emits — from the constructs the surface program contains.
-- MEASURED while fixing it: the census was wrong in six of its seats, and
-- each wrong seat built a binary that failed to LINK on an undefined
-- `q_Rt_*` the moment `QBE_MIDCONS=1` routed a prim to its Mid
-- implementation:
--
--   1. a non-inlinable RECORD GET          -> Rt.assoc + Rt.snd
--   2. a record-field pattern in a `let`   -> Rt.assoc + Rt.snd  (VField)
--   3. a record-field pattern in a `case`  -> Rt.assoc + Rt.snd  (VField)
--   4. a LITERAL pattern (`0 ->`, `"a" ->`) -> Rt.=   (MTagEq/MLitEq run
--                                              lowerEqMatch, the REAL `=`)
--   5. a tuple of 2+ elements              -> Rt.cons  (buildTuple is a CONS
--                                              chain; the old arm seeded the
--                                              never-called @p instead)
--   6. a record literal / list literal      -> Rt.emptylist + Rt.cons + Rt.@p
--
-- Every entry below is PRINTED AS A STRUCTURE, so the row's golden renders
-- what the Mid prims built: a wrong tag, a stale interior pointer or a
-- mis-sized payload in any of them changes the printed bytes.  Run twice by
-- qbe-check — the golden is frozen from the DEFAULT (Zig rt_prim) build and
-- the QBE_MIDCONS=1 twin must match it byte-for-byte; the differential
-- (tools/qbe/primsdiff) drives the same prims over generated vectors, this
-- row is the committed, readable end-to-end twin.
--
-- NOT reachable here, deliberately: the record access must survive the
-- pipeline's shape folding, so it goes through TOP-LEVEL functions (the
-- argument's shape is not known at the access) — the same discipline the
-- differential's assoc batches needed.


mkrec : Int -> Int -> { f : Int, g : Int }
mkrec x y =
    { f = x, g = y }


getf : { f : Int, g : Int } -> Int
getf r =
    r.f


getg : { f : Int, g : Int } -> Int
getg r =
    r.g


-- seat 2: a record-field PATTERN on the let-destructure path
letpat : { f : Int, g : Int } -> Int
letpat r =
    let
        { g } =
            r
    in
    g


-- seat 3: a record-field PATTERN on the case-alt path
casepat : List { f : Int, g : Int } -> Int
casepat rs =
    case rs of
        { f } :: _ ->
            f

        [] ->
            0


-- seat 4: LITERAL patterns (the `=` prim through lowerEqMatch)
litpat : Int -> String
litpat n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"

        _ ->
            "many"


strpat : String -> Int
strpat s =
    case s of
        "a" ->
            1

        "b" ->
            2

        _ ->
            0


-- seat 5: a 2- and a 3-element TUPLE (the cons chain, not @p)
tup2 : Int -> ( Int, String )
tup2 n =
    ( n, litpat n )


tup3 : Int -> ( Int, Int, Int )
tup3 n =
    ( n, n + 1, n + 2 )


a =
    { rec =
        [ getf (mkrec 1 2)
        , getg (mkrec 3 4)
        , letpat (mkrec 5 6)
        , casepat [ mkrec 7 8, mkrec 9 10 ]
        ]
    , lits =
        [ litpat 0, litpat 1, litpat 5 ]
    , strs =
        [ strpat "a", strpat "b", strpat "z" ]
    , -- seat 6: record + list literals
      nestedRec =
        { inner = { f = 11, g = 12 }, list = [ 1, 2, 3 ] }
    , tups =
        [ tup2 13, tup2 14 ]
    , tup3s =
        [ tup3 15, tup3 16 ]
    }
