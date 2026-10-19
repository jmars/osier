module MidgcWalk exposing (main)

-- GC ARC unit 1b (a) — the driver of the cheap SHAPE reproducer.  Wmidwalk.mid
-- carries the whole story (the 14-word node graph, the churn, the allocating
-- walk, and the three arms); this module only gives them ONE entry key with
-- the scale knobs the probe drives:
--
--   main mode nodes churn
--     mode 0 = ROOTED construction + rooted hold  (the correct program)
--     mode 1 = the M1 VIOLATION inside the node builder (body allocated before
--              the arg vector, so a collect can sweep a half-built node)
--     mode 2 = the graph built in a frame that dies (the whole graph unrooted)
--
-- tools/qbe/probe-midgc-walk.sh owns the invocations, the golden and the
-- QBE_MIDGC_NOREUSE=1 discriminator.
import Wmidwalk


main mode nodes churn =
    if mode == 0 then
        Wmidwalk.nat nodes churn

    else if mode == 1 then
        Wmidwalk.midbuild nodes churn

    else
        Wmidwalk.stale nodes churn
