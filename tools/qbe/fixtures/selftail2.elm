module SelfTail2 exposing (build)

-- Arity-2 self-tail with an OBSERVABLE accumulator: the committed churn
-- fixture has the same shape but returns 0, so its (n-1)::acc miscompile was
-- invisible.  Here the accumulated cons list IS the result.
build n acc =
    if n == 0 then
        acc
    else
        build (n - 1) (n :: acc)
