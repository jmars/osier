-- B7 (handoff-midlang-b7) — THE BRIDGE FIXTURE's driver: an Osier program
-- hands a value to a Mid defun and uses what comes back.  Sibling of B5's
-- midb5a/midb5b pairs (nothing here moves an earlier golden).
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb7.elm MidB7.main <outdir>
--   <outdir>/midb7 MidB7.main          -> 125105
--
-- 125105 = path(125) * 1000 + ring(105).  Wbridge.mid's header is the
-- fact-per-field ledger; this file only crosses the boundary twice.
module MidB7 exposing (main)

import Wbridge

main =
    (Wbridge.path 5) * 1000 + (Wbridge.ring 5)
