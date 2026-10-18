module MidB4bProbe exposing (main)

-- B4b (handoff-midlang-b4b): THE RETENTION PROBE — the documented half of the
-- escape rule, made visible.  `import Wesc` resolves to Wesc.mid next to this
-- file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/wescprobe.elm MidB4bProbe.main <outdir>
--   <outdir>/wescprobe MidB4bProbe.main
--
-- Expected stdout: 70
--   = alive(7) * 10 + (dead != 7 ? 0 : 1)
--
-- The two arms differ in ONE thing — whether the owner's frame is still live
-- when the retained address is read.  `alive` reads it inside the owner's own
-- frame (7, correct); `probe` reads it after `steal` returned, from a SIBLING
-- frame that has reused those exact bytes (`word[64] z;` zeroes 512 of them).
-- MEASURED: the dead read yields 0 there, so the low digit is 0.
--
-- The checker ACCEPTS both programs: it cannot see that a callee retained the
-- address, so retention is a documented obligation, not a rule — this fixture
-- is what makes its consequence visible.  71 would mean the dead block
-- survived intact in that build (the read answered the 7 that was written)
-- and the probe had gone INCONCLUSIVE; the number is pinned so that cannot
-- pass silently.
import Wesc

main =
    Wesc.probe 0
