module StatPlus exposing (main)

{-| THE HOST-BUILT-RECORD-CHAIN GUARD (unit-B item 3, blocker-1) — arithmetic
on the field of an `Io.stat` record.  `Io.stat`/TaskStat builds the
`{ size : Int, mode : Int, mtimeMs : Int, isDir : Bool, isFile : Bool }` record
in Zig as an assoc CHAIN (tag 4, via `valCons`/`@p` in effectloop.zig), while
the signature below types it as a CLOSED `TRecord` in checked code.  The
item-3 raw read licensed itself on "closed-TRecord binder ⇒ positional
tag-14 vector" and read `data[rank]+8` with NO tag test — a plausible wrong
int, exit 0 (MEASURED pre-fix: `statplus-bad`, where the answer is
`statplus-ok`).  `main` runs the Task and the `go` probe decides.

WHY THE GATE COULD NOT SEE THIS BEFORE: `statunit.elm` only COMPARES and
BITANDS `Io.stat` fields (both are prims `isIntKnown` does not admit), so the
item-3 raw arm never fired on it.  This fixture does `size + 1`, `size - 1`,
`size * 2` — the admitted `+ - *` — on a host-built chain, the exact shape the
static licence was wrong about.  The size checks are decisive (alpha.txt is 12
bytes: 12+1==13, 12-1==11, 12*2==24); the mode/mtimeMs lines additionally
exercise the other fields' raw reads.

NOTE ON THE SHAPE: this guard asserts the ANSWER, not the record shape — if
the effectloop's Zig-built stat record ever becomes a compiled vector (tag 14),
the arithmetic still answers the same and the fixture still holds.
-}


type Msg
    = Got String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (Task.map go (Io.stat "tests/elm-fixtures/input/dirlist/alpha.txt"))
    )


go : { size : Int, mode : Int, mtimeMs : Int, isDir : Bool, isFile : Bool } -> String
go info =
    if info.size + 1 == 13 && info.size - 1 == 11 && info.size * 2 == 24 && info.mode + 0 == info.mode && info.mtimeMs - 1 == info.mtimeMs - 1 then
        "statplus-ok"

    else
        "statplus-bad"


update msg model =
    case msg of
        Got s ->
            ( s, Cmd.none )
