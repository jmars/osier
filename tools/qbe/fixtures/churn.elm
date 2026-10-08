module Churn exposing (build)

build n acc =
    if n == 0 then
        0
    else
        build (n - 1) (n :: acc)
