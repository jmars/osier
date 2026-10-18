-- B5 (handoff-midlang-b5) — THE WORKED EXAMPLE: an anonymous union block
-- inside a struct, dispatch by an if-chain, through the real pipeline.
-- `import Wunio` resolves to Wunio.mid next to this file.
--
--   tools/qbe/qbe-mk.sh tools/qbe/fixtures/midb5a.elm MidB5a.main <outdir>
--   <outdir>/midb5a MidB5a.main
--
-- Expected stdout: 47079720  (ra 47 | rb 7 | rc 97 | pads 20) — Wunio.mid's
-- header is the fact-per-digit ledger.
--
module MidB5a exposing (main)

-- A tagged union here is a `word` tag field plus the anonymous union block
-- plus an if-chain: this language has NO `match`/`switch` and this unit adds
-- none (plan Q2/Q4).  The layout overlap is the whole feature.
import Wunio

main =
    Wunio.run 5
