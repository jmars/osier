-- NON-CASE-BODY probe: the case is a let-bound helper, not the body itself.
-- The retry does not apply (body is not directly a case) -> historical error.
module T exposing (main)
import Prelude exposing (..)

type Expr a
    = IntLit : Int -> Expr Int
    | BoolLit : Bool -> Expr Bool

evalLet : Expr a -> a
evalLet e =
    let
        go x =
            case x of
                IntLit n ->
                    n

                BoolLit b ->
                    b
    in
    go e

main : Int
main =
    evalLet (IntLit 3)
