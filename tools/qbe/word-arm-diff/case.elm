module M exposing (main)

-- CLASS 3: A `case` — the construct that CONSUMES what classes 1 and 2 build
-- (perf word-arm-surface).
--
-- Three pattern shapes are exercised in one program because each reads the
-- scrutinee differently:
--   * `f` matches a TUPLE with a single irrefutable pattern, so both binds are
--     payload chases (`FstStep` = payload word 0, `SndStep` = payload word 1)
--     and the body REBUILDS a tuple from them;
--   * `g` matches a LIST against nil, a one-element cons and a general cons, so
--     the alternatives are the nil IMMEDIATE test and the cons KIND test, and
--     the `y :: []` alternative nests an `MEmpty` behind a `TlStep` chase;
--   * `main` calls both and puts the results in a tuple with a heap string, so
--     the printer walks a mixed structure.
--
-- The nil arm is FIRST on purpose: a tag test that wrongly accepted a cons as
-- nil would take it, and a kind test that wrongly accepted anything heap-shaped
-- would turn `g []` into "many" instead of "empty".  Both arms must print
--   [cons [cons [cons 1 . []] . "x"] . [cons "many" . "empty"]]
f p =
    case p of
        ( a, b ) ->
            ( b, a )


g xs =
    case xs of
        [] ->
            "empty"

        y :: [] ->
            "one"

        y :: ys ->
            "many"


main =
    ( f ( "x", 1 :: [] ), g ( 1 :: 2 :: [] ), g [] )
