module RowgadtEvalbad exposing (..)

-- NEGATIVE (handoff-rowgadt-4 acceptance 3): the branch's equation says
-- a ~ Int (IntLit : Expr Int), but the body is a String. The discharge
-- re-checks the body at the DISCHARGED type (Int), so the re-run unify
-- String ~ Int must fail — the equation may coerce the RESULT's index, never
-- the body's type. Must ERR.

type Expr a
    = IntLit : Int -> Expr Int
    | BoolLit : Bool -> Expr Bool


evalBad : type a. Expr a -> a
evalBad e =
    case e of
        IntLit n ->
            "hello"


main : Int
main =
    evalBad (IntLit 3)
