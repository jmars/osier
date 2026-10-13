module MidgcRawstr exposing (main)

-- zigretire stage 5 PART 5 nice-to-have 4 — THE MID-RAW STRING MARKING PROBE
-- (the p3 kind-0 blind spot the PART 4 review named).  Every prior MIDGC
-- string fixture keeps STATIC string literals (whose mark is a no-op either
-- way — the data pointer is outside the Mid region, so gcMarkPtr deliberately
-- declines), so the Mid collector's tag-1 (string) marking of a MID-allocated
-- data pointer had been verified BY READING ONLY (RtGc.elm gcMarkValue marks
-- payload word 0; gcMarkPtr bounds-checks the Mid region).  This fixture makes
-- it falsifiable: `keep` holds a string built by the `++` chain, which lowers
-- to the `cn` prim -> Rt.cn -> RawAllocRaw -> Rt.allocRaw, i.e. its DATA bytes
-- live in the MID region (verified by emission: q_Rt_x2ecn + q_Rt_x2eallocRaw
-- present).  `keep` is a MAIN-LOCAL let-binding, so the Mid lowering builds it
-- EAGERLY into a frame slot BEFORE the churn (let-bindings lower in order;
-- a top-level value would be a lazily-forced GRef and the string would be
-- built AFTER the churn, vacating the probe).  The churn below builds and
-- drops 150k conses so the MID collector RUNS while `keep` is the only live
-- data; if the tag-1 mark did not chase the Mid data pointer, the sweep would
-- reclaim `keep`'s data bytes and the content equality would fail -> 0, never
-- 100.


churnDrop n =
    if n == 0 then
        0

    else
        let
            dropped =
                build 500
        in
        churnDrop (n - 1)


build n =
    if n == 0 then
        []

    else
        n :: build (n - 1)


main =
    let
        keep =
            [ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ++ "abcdefghij" ]

        _ =
            churnDrop 300

        eq =
            case keep of
                x :: _ ->
                    if x == "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij" then
                        100

                    else
                        0

                [] ->
                    0

        ln =
            case keep of
                x :: _ ->
                    String.length x

                [] ->
                    -1
    in
    String.fromInt eq ++ "|" ++ String.fromInt ln
