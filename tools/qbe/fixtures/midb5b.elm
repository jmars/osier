-- B5 (handoff-midlang-b5) — THE RECURSIVE STRUCTURE's driver: a struct whose
-- union block holds a `*Node` next-pointer beside a word leaf, built with
-- `rawcall malloc`, linked, walked, summed and freed.  `import Wnods`
-- resolves to Wnods.mid next to this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb5b.elm MidB5b.main <outdir>
--   <outdir>/midb5b MidB5b.main
--
-- Expected stdout: 60307073  (sum 60 | count 3 | leaf 7 | overlap 7 | seeded
-- 3) — Wnods.mid's header is the fact-per-digit ledger.  Run it under
-- `QBE_MIDGC=1` too: the fixture is pure and allocates through `rawcall
-- malloc`/`free`, so the collector changes nothing about this number.
module MidB5b exposing (main)

import Wnods

main =
    Wnods.run 3
