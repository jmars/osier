module M exposing (main)

-- THE RECORD FAMILY, CLASS 4: THE CHAIN (perf word-arm-records R4, added by the
-- R3/R4 review's SHOULD-FIX 2 — word-arm-diff had NO chain row, which is part of
-- why two names-side defects passed 15/15).
--
-- `Record.remove` is the ONLY surface route to `Rt.recToChain` (Prelude's
-- `removeFieldImpl` calls it first), and it is the one place the record's names
-- array is materialized as SYMBOL VALUES: each car of the produced chain is a
-- code-2 cell built at runtime, which is a different producer from a literal
-- symbol (a static name pointer) and from `Rt.intern` (a malloc'd copy).
--
-- The print is the oracle: `[cons [cons z . 7] . [cons [cons x . 1] . []]]` — a
-- wrong name pointer prints garbage bytes or dies, and a two-word symbol cell
-- (the shape this twin had before the review's SHOULD-FIX 1) reads its "bytes"
-- from a length word.
--
-- BOTH records are INSERTED ones: a literal record's names array is a static
-- blob, so a chain over a literal passes even when the runtime-built case is
-- broken (that control is the review's chain-lit.elm).
ins r =
    { r | z <- 7 }


main =
    Record.remove "y" (ins { x = 1, y = 2 })
