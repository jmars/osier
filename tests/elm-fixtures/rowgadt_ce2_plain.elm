module RowgadtCe2Plain exposing (main)

-- NEGATIVE (CE-2, plain-ADT form — the bug is NOT GADT-specific): the same
-- bare-variable scrutinee over-generalisation on a PLAIN ADT. `eval` must bind
-- to `Expr -> Int` (not `forall a. a -> Int`), so applying it to a String is a
-- COMPILE-TIME type error instead of a runtime `non-exhaustive case`.

type Expr
    = Num Int
    | Add Expr Expr


eval e =
    case e of
        Num n ->
            n

        Add a b ->
            eval a + eval b


main : Int
main =
    eval "hello"
