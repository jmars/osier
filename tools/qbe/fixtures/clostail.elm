module ClosTail exposing (main)

main n =
    let
        f = \x -> main (x - 1)
    in
    if n == 0 then
        0
    else
        f n
