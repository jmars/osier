module MidgcIo exposing (main)

-- zigretire stage 5 PART 5 — THE HOST-IO CROSS-HEAP HOLE (reproduced by the
-- PART 4 review), and the fixture that pins the CENSUS REFUSAL that closes it.
--
-- The corrected criterion (plan.md §2.2): no Mid object may reference anything
-- the ZIG collector can reclaim.  The Zig host effect loop builds read-file /
-- getenv / getcwd / glob / exec results with values.valString/valCons in the
-- ZIG nursery (src/effectloop.zig:509, :662-671) and passes them into compiled
-- code through host_apply -> rt_apply; a `keeper s = [s]` then stores that
-- Value in a MID cons.  The Zig scavenge re-claims the whole nursery
-- (collect.zig:713-720), so the kept string's DATA bytes are overwritten while
-- the Value (and its length field) survives.
--
-- THE TRIGGER IS THE TRANSIENT TAIL ARRAY: a SELF-tail call lowers to an
-- in-frame loop and allocates nothing (measured tail_gcarray=0), so MUTUAL
-- recursion is REQUIRED — rt_tail_known's nargs>3 fallback allocates a fresh
-- g.allocArray in the Zig nursery per iteration (rt.zig:817), which is what
-- forces the scavenge.  `churnA`/`churnB` are 4-arg mutual tail recursion.
--
-- THE CROSS-HEAP SIGNATURE this fixture prints: `String.length` (the Value's
-- intact length field) is 150 while CONTENT EQUALITY fails (the data bytes are
-- reclaimed).  Default path (no MIDGC): the kept string is reachable from the
-- Zig shadow stack and is evacuated, not reclaimed -> "100|150".  Under
-- QBE_MIDGC=1 WITHOUT the refusal (probe-midgc-io.sh --before): "0|150".
--
-- WITH the refusal (this tree), QBE_MIDGC=1 refuses this program at COMPILE
-- time — the program is effect-loop-driven (Platform.program -> Runtime.program),
-- and the census/effect-loop refusal (Lower.elm) names it.  The default path
-- is untouched and prints the golden.  The asymmetry is scripted in
-- tools/qbe/probe-midgc-io.sh.


type Msg
    = Done String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "unset"
    , Task.perform Done (Task.andThen Io.readFile (Io.getenv "MIDGC_IO_IN"))
    )


keeper : String -> List String
keeper s =
    [ s ]


churnA : Int -> Int -> Int -> Int -> Int
churnA n a b c =
    if n == 0 then
        a + b + c

    else
        churnB (n - 1) (a + 1) b c


churnB : Int -> Int -> Int -> Int -> Int
churnB n a b c =
    if n == 0 then
        a + b + c

    else
        churnA (n - 1) a (b + 1) c


update msg model =
    case msg of
        Done s ->
            let
                kept =
                    keeper s

                _ =
                    churnA 3000000 0 0 0

                eq =
                    case kept of
                        x :: _ ->
                            if x == "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij" then
                                100

                            else
                                0

                        [] ->
                            0

                ln =
                    case kept of
                        x :: _ ->
                            String.length x

                        [] ->
                            -1
            in
            ( String.fromInt eq ++ "|" ++ String.fromInt ln, Cmd.none )
