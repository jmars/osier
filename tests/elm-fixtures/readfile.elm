module Readfile exposing (main)

-- 3B-3 gate: read-file-as-string's observable arms, the last prim that still
-- routed through rt_prim.  Four reads chained with andThen:
--   * hello.txt  — an existing non-empty file (the one-shot read);
--   * no-such-file.txt — a MISSING file: open failure completes "" AND the
--     runtime's stderr note ("runtime: cannot open file for
--     read-file-as-string") — the gate's 2>&1 capture puts the note in the
--     golden, so BOTH halves of the contract are pinned;
--   * empty.txt  — an EMPTY file: "" with no note (open succeeds, EOF on the
--     first read);
--   * big.txt    — 70000 bytes > the 65536 read chunk: the second read plus
--     the growing accumulator, asserted by byte-length and the last 3 bytes.

type Msg
    = Done String


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "working"
    , Task.perform Done chain
    )


chain =
    Task.andThen (\hello -> afterHello hello) (Io.readFile "tests/elm-fixtures/input/hello.txt")


afterHello hello =
    Task.andThen (\missing -> afterMissing hello missing) (Io.readFile "tests/elm-fixtures/input/no-such-file.txt")


afterMissing hello missing =
    Task.andThen (\empty -> afterEmpty hello missing empty) (Io.readFile "tests/elm-fixtures/input/empty.txt")


afterEmpty hello missing empty =
    Task.map (\big -> report hello missing empty big) (Io.readFile "tests/elm-fixtures/input/big.txt")


report hello missing empty big =
    "hello=[" ++ hello ++ "] missing=[" ++ missing ++ "] empty=[" ++ empty
        ++ "] big=" ++ String.fromInt (String.length big)
        ++ (if String.endsWith "789" big then "/tail-ok" else "/tail-BAD")


update msg model =
    case msg of
        Done rep ->
            ( rep, Cmd.none )
