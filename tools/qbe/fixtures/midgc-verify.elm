module MidgcVerify exposing (main)

-- GC ARC unit 2 — the driver of the VERIFIER's negative controls
-- (tools/qbe/fixtures/Wmidverify.mid carries the story and the arms).
--
--   main mode nodes churn
--     0 = OK       a correct program (rooted graph + churn) — the golden
--     1 = INTERIOR a live value's pointer payload made interior
--     2 = FREED    a live value's pointer payload made stale
--     3 = HEADER   a live block's stored class corrupted
--
-- tools/qbe/probe-midgc-verify.sh owns the invocations, the named messages and
-- the VERIFY-off fail-before arm.
import Wmidwalk
import Wmidverify


main mode nodes churn =
    if mode == 0 then
        Wmidwalk.nat nodes churn

    else if mode == 1 then
        Wmidverify.interior nodes churn

    else if mode == 2 then
        Wmidverify.freed nodes churn

    else
        Wmidverify.header nodes churn
