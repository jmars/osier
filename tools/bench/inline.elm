module Inline exposing (main, once)

-- Runtime probe for Inline's FULL-ARITY inlining: `inc x` is a full-arity call
-- to a small non-recursive defun, which the VM executes as a frame push + a
-- fresh env array + a copy per call.  Inlining moves the body into the caller,
-- removing that per-call allocation — the trade the instruction-count metric
-- cannot see (the raw count can go up).


inc : Int -> Int
inc x =
    x + 1


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (inc acc)


once : Int -> Int
once x =
    inc x


main =
    loop 300000 0
