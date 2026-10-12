module MidgcLive exposing (main)

-- zigretire stage 4 — THE USE-AFTER-FREE PROBE (registered qbe-check row).
--
-- A value reachable ONLY from the root set (the frame slot holding `keep`)
-- must survive a collection that runs while the churn below allocates.  If
-- the Mid collector's mark walk misses a root, `keep`'s cons cells (a
-- value_array pair chain, tag 4) are swept while still live and `sum keep`
-- reads freed memory — a wrong number or a crash, never 1275.
--
-- The churn is sized so a collection fires (total allocation > heap/4) but
-- the LIVE set stays tiny (one 500-cons batch at a time), so the run never
-- OOMs and the only thing the probe observes is whether `keep` survived.

main =
    let
        keep =
            build 50

        n =
            churnDrop 300
    in
    sum keep + n


build n =
    if n == 0 then
        []

    else
        n :: build (n - 1)


-- Allocate 500 conses, drop them, recurse.  300 x 500 = 150k conses (14.4 MB
-- total) — over the QBE_HEAP_MB=16 quarter-heap threshold, so collections run
-- while `keep` (in the caller's frame) is the only live heap data.
churnDrop n =
    if n == 0 then
        0

    else
        let
            dropped =
                build 500
        in
        churnDrop (n - 1)


sum xs =
    case xs of
        [] ->
            0

        h :: t ->
            h + sum t
