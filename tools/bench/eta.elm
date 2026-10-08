module Eta exposing (main, once)

-- Runtime probe for Arity's PARTIAL-APPLICATION ETA-EXPANSION: `add x` is a
-- partial application built per call via buildPartialClosure (an O(code_len)
-- instruction-array copy + env concat + closure, three allocations).  The
-- repair turns it into `\y -> add x y` (one `Cur` allocation), and the
-- eventual call becomes a full-arity N==A fast path.


add : Int -> Int -> Int
add a b =
    a + b


apply : (Int -> Int) -> Int -> Int
apply f x =
    f x


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (acc + apply (add n) (n + 1))


once : Int -> Int
once n =
    apply (add n) (n + 1)


main =
    loop 300000 0
