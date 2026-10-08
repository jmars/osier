module Letfallback exposing (main, once)

-- Runtime probe for Inline's LET-BINDING FALLBACK: `add3 a b c` is a
-- full-arity call whose args are COMPUTED (PrimApps), so direct substitution
-- cannot inline it (that would duplicate/re-order the arg computations); the
-- fallback binds each arg to a Let slot and inlines the body.  It trades a
-- Let_/Endlet pair per parameter for the callee's per-call frame+env
-- allocation — an instructions-up / runtime-down trade.


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (add3 (acc + 1) (acc + 2) (acc + 3))


once : Int -> Int
once x =
    add3 (x + 1) (x + 2) (x + 3)


main =
    loop 300000 0
