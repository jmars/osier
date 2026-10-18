module MidB4b exposing (main)

-- B4b (handoff-midlang-b4b): THE WORKED EXAMPLE — plan Q4/Q5's "struct and
-- array locals live on QBE stack memory" through the real pipeline.
-- `import Wesc` resolves to Wesc.mid next to this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/wesc.elm MidB4b.main <outdir>
--   <outdir>/wesc MidB4b.main
--
-- Expected stdout: 14100095  (acc.x 14 | acc.y 100 | a[5] 9 | top 5)
--
-- This pair is a SIBLING of midb2.elm/Wext.mid (1510150899), midb3.elm/
-- Warr.mid (903091133) and midb4.elm/Wloop.mid (15042106), not an extension
-- of any: those goldens stay the earlier units' acceptance numbers.
--
-- The .ssa rows pin `alloc8`/no `malloc`; THIS is the run, because a
-- structure pin cannot see a wrong value.
import Wesc

main =
    Wesc.run 5
