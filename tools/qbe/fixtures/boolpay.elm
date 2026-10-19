module BoolPayMain exposing (main)

-- The DRIVER for boolpay.mid: the boolean payload's WIDTH pin.  Every
-- load-bearing line is in the .mid; this module only feeds it a value and hands
-- the answers to the runtime's printer, so the golden is one list of numbers
-- and each slot is a specific claim:
--
--   slot 0   read32 (garb)      0            the payload WORD is FALSE
--   slot 1   read64 (garb)      4294967296   the 64-bit read sees the stale half
--   slot 2   routeFixed (garb)  0            the route's post-fix answer
--   slot 3   routeOld (garb)    1            the route's pre-fix answer
--   slot 4   read32 (mkbool 1)  1            the everyday path still reads true
--   slot 5   read32 (mkbool 0)  0            ... and false
--
-- Slots 0/1 and 2/3 are the pair that can fail in BOTH directions: narrowing
-- `payload32` moves slot 1 to 0, widening `payload` moves slot 0 (and slot 3)
-- the other way.  qbe-check.sh's `boolpay` row compares this list to the
-- golden; its `BOOLPAY-SHAPE` row pins the EMITTED widths (loadl in
-- `$q_Bpay_x2eread64`, loadw+extsw in `$q_Bpay_x2eread32`).
main =
    [ Bpay.read32 (Bpay.garb 0)
    , Bpay.read64 (Bpay.garb 0)
    , Bpay.routeFixed (Bpay.garb 0)
    , Bpay.routeOld (Bpay.garb 0)
    , Bpay.read32 (Bpay.mktrue 0)
    , Bpay.read32 (Bpay.mkfalse 0)
    ]
