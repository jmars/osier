module MidgcStr exposing (main)

-- zigretire stage 5 PART 5 FIX 1+2 — THE `str` CENSUS-ARM PIN + THE NARROWED
-- str HOLE (the PART-5 review's should-fix 1 and 2).  This fixture trips the
-- CENSUS arm (not the seam arm): it is a PURE program whose census contains
-- `str` — the only one of the seven nursery-building host prims a pure program
-- can reach without a Platform.program/worker seam (via the seeded
-- Prelude.stringFromFloat).  Deleting (or emptying) the `nurseryHostPrims`
-- list makes THIS row go red while every other gate stays green — which is
-- exactly why the list's DELETION needed a pin, and why this fixture exists.
--
-- THE HOLE, NARROWED (corrected shape): `String.fromFloat` is `jsFloatText
-- (strPrim f)` (Prelude.elm:898).  `strPrim f` renders the float via the Zig
-- `str` prim (primStr -> values.valString -> a Zig-NURSERY string).  For a
-- CANONICAL decimal, jsFloatText REBUILDS the text through the Mid `cn` prim
-- (jsFloatDigits -> jsSigOfDigits -> String.append, Prelude.elm:985-1002), so
-- the nursery string is only READ (length/charCode) and never kept — SAFE.
-- Only the NaN / ±Infinity PASS-THROUGH arms (jsFloatText's else and the
-- "-Infinity" arm, Prelude.elm:911-927) return the raw nursery string as the
-- final value.  So the hole is EXACTLY: `String.fromFloat` of NaN / ±Infinity
-- kept alive across a scavenge — narrower than "String.fromFloat generally",
-- but real: the nursery string is reclaimed while a Mid object references it.
--
-- THIS FIXTURE CONSTRUCTS it: `String.fromFloat (0.0/0.0)` is NaN, kept
-- through a function boundary (`keeper s = [s]`, a Mid cons), then a 4-arg
-- MUTUAL tail churn (self-tail lowers to an in-frame loop; mutual recursion is
-- REQUIRED to reach rt_tail_known's nargs>3 g.allocArray fallback) fires the
-- Zig scavenge.  WITHOUT the refusal (the probe's --before arm deletes the
-- `str` entry): the kept "NaN" data bytes are reclaimed -> content equality
-- fails -> "0" (correct "100").  WITH the refusal: the program is REFUSED at
-- compile time, naming `str`.


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


main =
    let
        keep =
            keeper (String.fromFloat (0.0 / 0.0))

        _ =
            churnA 3000000 0 0 0

        eq =
            case keep of
                x :: _ ->
                    if x == "NaN" then
                        100

                    else
                        0

                [] ->
                    0
    in
    String.fromInt eq
