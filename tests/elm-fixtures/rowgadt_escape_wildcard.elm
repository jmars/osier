module RowgadtEscapeWildcard exposing (main)

-- NEGATIVE (escape shape: wildcard sibling leak, found by the adversarial
-- escape hunt 2026-10-05). The Here branch returns the TAIL (rest : HList
-- rho') while the wildcard branch returns the FULL row (xs). The shared case
-- result variable let the wildcard's full-row result alias the refined tail to
-- the rigid head (flex tail := rigid head is legal globally), zonking the tail
-- away before the clause-level escape check could see it. Must ERR 'escaping
-- row equation'.

type Has l t rho
    = Here : Has l t { l : t | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


escapeBad : type l t rho. Has l t rho -> HList rho -> HList rho
escapeBad h xs =
    case ( h, xs ) of
        ( Here, HCons _ rest ) ->
            rest

        _ ->
            xs


main : Int
main =
    0
