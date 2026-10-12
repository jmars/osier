module MidgcReclaim exposing (main)

-- zigretire stage 4 — THE LEAK PROBE (registered qbe-check row).
--
-- Total allocation is ~192 MB (4000 x 500 conses) against a 16 MB heap, but
-- every batch is garbage the moment the next recursion step starts.  The run
-- COMPLETES (exit 0, prints 0) ONLY IF the collector observably reclaims
-- dead cells into its free list and reuses them: a collector that leaks (or
-- sweeps without reusing) dies with "midgc: out of memory" long before the
-- loop ends.  So the pass/fail signal is the exit code, not a printed value.

main =
    churnDrop 4000


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
