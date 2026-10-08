module Overapp exposing (main, once)

-- Runtime probe for Arity's OVER-APPLICATION SPLIT: `makeAdder n (n + 1)` is
-- a flat n-ary application (Elm application is n-ary) of an arity-1 function
-- whose body returns a closure, so the VM's N>A path runs `peelOverArgs` — a
-- nested vmExecEnv with a fresh ~3 MB frame stack per call.  The split
-- rewrites it to `(makeAdder n) (n + 1)`, two clean N==A fast-path applies.


makeAdder : Int -> (Int -> Int)
makeAdder x =
    \y -> x + y


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) (acc + makeAdder n (n + 1))


once : Int -> Int
once n =
    makeAdder n (n + 1)


main =
    loop 300000 0
