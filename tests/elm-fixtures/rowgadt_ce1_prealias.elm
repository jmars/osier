module RowgadtCe1Prealias exposing (main)

-- NEGATIVE (CE-1, dropIntroduced scoping bypass): the branch body aliases the
-- refined tail to the head GLOBALLY (via `choose True xs rest`) BEFORE the
-- result unify, so a check that fires only on what the result unify itself
-- introduced has a window that misses it. The tail `rest : HList rho'` is
-- returned where the full row is expected; the escape must fire regardless of
-- WHERE in the branch the identification happened.

type Has l t rho
    = Here : Has l t { l : t | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


escapeBad : type l t rho. Has l t rho -> HList rho -> HList rho
escapeBad h xs =
    case ( h, xs ) of
        ( Here, HCons _ rest ) ->
            let
                choose c a b =
                    if c then a else b

                forced =
                    choose True xs rest
            in
            rest

        _ ->
            xs


main : Int
main =
    0
