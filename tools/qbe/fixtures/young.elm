module Young exposing (main)

-- GC NURSERY unit (stage A) — the young-space survival probe's driver.
-- tools/qbe/probe-midgc-young.sh (stage B) will own the arms and goldens;
-- today the entry runs `hold`:
--
--   QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 tools/qbe/qbe-mk.sh \
--       tools/qbe/fixtures/young.elm Young.main <outdir>
--   QBE_MIDGC_YOUNG=1 QBE_MIDGC_YOUNG_MB=1 QBE_HEAP_MB=16 \
--       <outdir>/young Young.main 0 200000        # -> 424242 when the
--                                                  #    scavenge is correct
import Wyoung


main mode n =
    if mode == 0 then
        Wyoung.hold n
    else if mode == 1 then
        Wyoung.two n
    else if mode == 2 then
        Wyoung.stale n
    else if mode == 3 then
        Wyoung.rooted n
    else if mode == 4 then
        Wyoung.rootNoCopy n
    else
        Wyoung.rootNoRead n
