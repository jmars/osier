module PrimStruct exposing (a)

-- The STEP-5 structure-printing fixture (osier-midprims): the cons spike's
-- conslist lesson — the churn/flatten goldens CANNOT see corruption whose
-- printed results never traverse the built structure — extended to the prims
-- this step ported.  Every entry below TRAVERSES what a Mid-implemented prim
-- built: the byte list of a string the Mid cn/repeat/substring constructed
-- (strToBytes walks every byte of the Mid-built buffer), a fully-written
-- vector read back element by element (the Mid absvector/address-> array),
-- and a bytes->string roundtrip re-expanded.  Run twice by the gate: the
-- DEFAULT build (Zig rt_prim) freezes the golden; QBE_MIDCONS=1 must print
-- the SAME bytes with every prim under it routed to its Mid implementation.


built =
    String.append "mid=" (String.append (Str.repeat 2 "ab") (String.append "|" (String.sliceLen 2 5 "xxwildxx")))


bytes =
    strToBytes built


back =
    bytesToString bytes


vecReads v =
    vectorGet v 0 :: vectorGet v 1 :: vectorGet v 2 :: []


a =
    { b = bytes
    , r = strToBytes back
    , v = vecReads (vectorSet (vectorSet (vectorSet (vectorMake 3) 0 7) 1 8) 2 9)
    }
