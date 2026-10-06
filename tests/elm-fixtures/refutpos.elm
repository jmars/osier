module RefutPos exposing (main)

-- Part B pin (refutation POSITIVE): an arm that is IMPOSSIBLE under the
-- branch equations is REFUTED, so its absence is NOT a coverage gap. Here the
-- scrutinee index is the concrete type `Expr Int`; the constructor
-- `BoolLit : Bool -> Expr Bool` is impossible at `Expr Int` (the index
-- equation `Int ~ Bool` cannot hold), so the case below matches ONLY `IntLit`
-- and must COMPILE CLEAN. This is OCaml's `-> .` mechanism — the thing the
-- discuss.ocaml.org t/13718 thread's author could not get working there. Its
-- negative counterpart is `refutneg` (an arm that IS possible — HNil at an
-- open HList rho — must NOT be refuted, and omitting it still errors).

type Expr a
    = IntLit : Int -> Expr Int
    | BoolLit : Bool -> Expr Bool


eval : Expr Int -> Int
eval e =
    case e of
        IntLit n ->
            n


main : Int
main =
    eval (IntLit 5)
