module AchurnMain exposing (main)

-- B3 (handoff-midlang-b3): THE val-ARRAY CHURN PROBE's driver (sibling of
-- Achurn.mid; `import Achurn` resolves next to this file).
--
-- Expected stdout under QBE_MIDGC=1 QBE_HEAP_MB=16: 10
--   = good(1) * 10 + bad(0)
-- good: the handle in a ROOTED `val` slot survives the churn — the element
--       is still a boolean (tag 3) -> 1.
-- bad:  the handle only in a raw `val[1]` element; the array roots nothing,
--       so the referent is swept and the sweep's free-list link lands in the
--       object's first word — the element's TAG -> not a boolean -> 0.
--
-- This is a DOCUMENTED OBLIGATION made visible, not a compiler bug: the
-- checker cannot see rootedness (plan §Q11), so the enforcement is the
-- failure itself.  Run it after any change to val-element lowering or to the
-- array paths; a 11 means the missing root stopped mattering (the probe no
-- longer proves anything) and an 00 means the compliant arm broke.
import Achurn

main =
    (Achurn.good 0) * 10 + (Achurn.bad 0)
