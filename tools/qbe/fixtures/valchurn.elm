-- B7 (handoff-midlang-b7) — THE CHURN PROBE's driver (sibling of B3's
-- achurn.elm; `import Wval` resolves to Wval.mid next to this file).
--
--   QBE_MIDGC=1 QBE_HEAP_MB=16 tools/qbe/qbe-mk.sh \
--       tools/qbe/fixtures/valchurn.elm Valchurn.main <outdir>
--   QBE_MIDGC=1 QBE_HEAP_MB=16 <outdir>/valchurn Valchurn.main   # -> 10011
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/valchurn.elm Valchurn.main <outdir>
--   <outdir>/valchurn Valchurn.main                              # -> 10001
--
-- 10011 = win(1) * 10000 | stale(0) * 100 | rooted(11)   (QBE_MIDGC=1 build)
-- 10001 = win(1) * 10000 | stale(0) * 100 | rooted(1)    (default build)
--   win:    unrooted, read INSIDE the no-safepoint window -> the copy is
--           still valid (the rule PERMITS this).
--   stale:  unrooted, read ACROSS an allocating call -> the referent was
--           reclaimed and element 0's tag is gone (under EITHER collector).
--   rooted: the referent is held in a `val` binder, so the same churn leaves
--           the SLOT readable; the RAW COPY reads 1 only under the
--           non-moving `QBE_MIDGC=1` collector, and is STALE (0) under the
--           default MOVING one — plan §Q11's obligation (b), measured.
--
-- `QBE_MIDGC` is a BUILD-time switch; setting it at RUN time changes nothing.
-- Wval.mid's header carries the full table and the dose control.
--
-- The DOCUMENTED OBLIGATIONS made visible by failure, not a compiler bug:
-- the checker cannot see rootedness (plan §Q11).  Re-run after any change to
-- val-field lowering or to the collector; on the QBE_MIDGC=1 build, 11011
-- means the missing root stopped mattering (the probe no longer proves
-- anything) and 10001 means the compliant arm broke.  On the default build
-- the reading is 10001, and 10011 there would mean the collector stopped
-- moving (obligation (b) would no longer be observable).
module Valchurn exposing (main)

import Wval

main =
    (Wval.win 0) * 10000 + (Wval.stale 0) * 100 + (Wval.rooted 0)
