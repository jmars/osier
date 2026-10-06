module RowgadtHgetBare exposing (main)

-- POSITION-DIRECTED RIGIDITY (the systematic answer to the flexible-vs-rigid
-- axis): this signature binds NOTHING with `type ... .`, yet `l`, `t`, and
-- `rho` are parameters of the GADTs `Has` / `HList`, so the checker makes them
-- RIGID at the body check on that ground alone. Before this change the bare
-- form failed at the recursive There call ("cannot unify a with {l:a| b}") and
-- required the `type l t rho.` binder (see rowgadt_hget); the two forms now
-- behave identically. Must compile CLEAN.

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


hget : Has l t rho -> HList rho -> t
hget h xs =
    case ( h, xs ) of
        ( Here, HCons x _ ) ->
            x

        ( There h2, HCons _ rest ) ->
            hget h2 rest


main : Int
main =
    0
