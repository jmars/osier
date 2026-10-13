module MidgcStr exposing (main)

-- zigretire stage 3 GROUP 2 — THE `str` CENSUS-ARM CLOSED (this fixture's
-- meaning FLIPPED from the stage-5 PART 5 refusal pin).  `str` now has a Mid
-- body (Rt.str) that renders String.fromFloat's float through rt_float_text
-- into a GC string, so `str` LEFT Lower.elm's nurseryHostPrims — the last
-- census-arm entry of the host-IO soundness hole is closed.
--
-- THE HOLE THAT WAS CLOSED.  `String.fromFloat` is `jsFloatText (strPrim f)`
-- (Prelude.elm:898).  Pre-GROUP-2, `str` was the Zig prim (primStr ->
-- values.valString -> a Zig-NURSERY string); for NaN/±Infinity the
-- jsFloatText pass-through arms (Prelude.elm:911-927) returned that raw
-- nursery string as the final value, so a kept NaN text was reclaimed by the
-- Zig scavenge while a Mid object still referenced it.  Rt.str instead
-- renders the float into a GC string (RawAllocRaw + a copy from a static
-- BSS buffer), so the kept "NaN" survives.
--
-- THIS FIXTURE CONSTRUCTS the old hole's shape: `String.fromFloat (0.0/0.0)`
-- is NaN, kept through a function boundary (`keeper s = [s]`, a Mid cons),
-- then a 4-arg MUTUAL tail churn (self-tail lowers to an in-frame loop;
-- mutual recursion is REQUIRED to reach rt_tail_known's nargs>3 g.allocArray
-- fallback) fires the Zig scavenge.  BEFORE the fix the program was REFUSED
-- at compile time under QBE_MIDGC=1 (naming `str`); AFTER, it compiles and
-- prints "100" (the Mid-allocated "NaN" survives).  The default path also
-- prints "100" — the GC string is rooted, so it is evacuated, not reclaimed.


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
