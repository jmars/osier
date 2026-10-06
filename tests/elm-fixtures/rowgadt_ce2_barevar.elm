module RowgadtCe2Barevar exposing (main)

-- NEGATIVE (CE-2, the dangerous direction): a BARE-variable scrutinee with a
-- GADT index over-generalises and the exhaustiveness check over-refutes. With
-- NO signature, `x` is a fresh variable; lifting it and dropping `x ~ Tag Int`
-- at branch end would generalise `f : forall a. a -> Int` (so `f B` type-checks
-- and crashes). The lift must be skipped for a bare scrutinee: the pattern then
-- binds `x` to `Tag Int` globally, and `f B` is a COMPILE-TIME type error.

type Tag a
    = A : Tag Int
    | B : Tag String


f x =
    case x of
        A ->
            1


main : Int
main =
    f B
