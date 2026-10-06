module RowgadtEval exposing (..)

-- The CLASSIC GADT evaluator (handoff-rowgadt-4): per-ctor result refinements
-- (IntLit : Expr Int, BoolLit : Expr Bool, Pair : Expr (a,b)) with the
-- signature-directed result at the abstract index `a`. R-RESULT-DISCHARGE:
-- each branch's TYPE equation (a ~ Int, a ~ Bool, a ~ (a',b')) is discharged
-- at the branch result, in branch scope only — the equation dies at branch
-- end and nothing global binds, so the exported scheme stays forall a.
-- Expr a -> a and call sites keep their own instantiation.
--
-- This program is the canonical GADT acceptance test; it MUST compile clean.

type Expr a
    = IntLit : Int -> Expr Int
    | BoolLit : Bool -> Expr Bool
    | Pair : Expr a -> Expr b -> Expr ( a, b )


eval : type a. Expr a -> a
eval e =
    case e of
        IntLit n ->
            n

        BoolLit b ->
            b

        Pair l r ->
            ( eval l, eval r )


main : ( Int, Bool )
main =
    eval (Pair (IntLit 1) (BoolLit True))
