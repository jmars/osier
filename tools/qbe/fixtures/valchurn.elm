-- B7 (handoff-midlang-b7) — THE CHURN PROBE's driver (sibling of B3's
-- achurn.elm; `import Wval` resolves to Wval.mid next to this file).
--
--   QBE_HEAP_MB=16 tools/qbe/qbe-mk.sh \
--       tools/qbe/fixtures/valchurn.elm Valchurn.main <outdir>
--   QBE_HEAP_MB=16 <outdir>/valchurn Valchurn.main               # -> 10001
--   QBE_MIDGC_YOUNG=0 QBE_HEAP_MB=16 <outdir>/valchurn Valchurn.main
--                                                                # -> 10011
--
-- 10001 = win(1) * 10000 | stale(0) * 100 | rooted(1)    (nursery ON = the
--        DEFAULT since the flip)
-- 10011 = win(1) * 10000 | stale(0) * 100 | rooted(11)   (QBE_MIDGC_YOUNG=0)
--   win:    unrooted, read INSIDE the no-safepoint window -> the copy is
--           still valid (the rule PERMITS this).
--   stale:  unrooted, read ACROSS an allocating call -> the referent was
--           reclaimed and element 0's tag is gone (nursery ON or OFF).
--   rooted: the referent is held in a `val` binder, so the same churn leaves
--           the SLOT readable; the RAW COPY reads 1 only when the collector
--           does not move — `QBE_MIDGC_YOUNG=0`, where the full collect is a
--           mark-sweep — and is STALE (0) under the DEFAULT nursery
--           scavenge, which PROMOTES the body and poisons the young original
--           (Rt.gcScavPtr): plan §Q11's obligation (b), measured.
--
-- THE COLLECTOR IS THE MID ONE (runtime.mid), and it is the ONLY one:
-- QBE_MIDGC is RETIRED (zighost Z0 — `QBE_MIDGC=0` makes run.js REFUSE, there
-- is no Zig collector to select), so what this probe varies is the NURSERY
-- (QBE_MIDGC_YOUNG), which is a RUN-time knob read in Rt.gcInit, not a build
-- switch.  Wval.mid's header carries the full table and the dose control.
--
-- The DOCUMENTED OBLIGATIONS made visible by failure, not a compiler bug:
-- the checker cannot see rootedness (plan §Q11).  Re-run after any change to
-- val-field lowering or to the collector.  Under `QBE_MIDGC_YOUNG=0`, 11011
-- means the missing root stopped mattering (the probe no longer proves
-- anything) and 10001 means the compliant arm broke; under the default
-- nursery the reading is 10001, and 10011 there would mean the nursery
-- stopped moving (obligation (b) would no longer be observable).
module Valchurn exposing (main)

import Wval

main =
    (Wval.win 0) * 10000 + (Wval.stale 0) * 100 + (Wval.rooted 0)
