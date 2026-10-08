module ArgvRepro exposing (main, count)

-- argv pseudo-global regression: `Runtime.argv ()` lowers to the argvPrim
-- rewrite (a 1-arg thunk reading *argv*).  Its QBE closure had static arity 0
-- while applied with 1 arg, so rt_apply re-applied the argv LIST (nil) as a
-- function: "apply of a non-function value".  `main` distinguishes empty vs
-- non-empty argv; `count` returns the argv LENGTH so the string list (not just
-- its emptiness) is compared native-vs-elmvm.

count : Int
count =
    countList (Runtime.argv ())


countList : List String -> Int
countList l =
    case l of
        _ :: rest ->
            1 + countList rest

        [] ->
            0


main =
    case Runtime.argv () of
        [] ->
            0

        _ ->
            1
