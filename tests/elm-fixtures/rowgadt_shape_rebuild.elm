module RowgadtShapeRebuild exposing (main)

-- POSITIVE (domain-preserving REBUILD, the point of the domain-based escape
-- rule): the Here branch refines rho ~ { l : t | rho' } and returns the
-- scrutinee REBUILT — `HCons x rest : HList { l : t | rho' }`, which re-adds
-- the head label `l` on top of the tail `rho'`. Its row DOMAIN equals the
-- head's domain under the equation, so this is NOT an escape, unlike the bare
-- tail return (`id rest : HList rho'`) which drops `l`. Must compile CLEAN.

type Has l t rho
    = Here : Has l t { l : t | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


rebuild : type l t rho. Has l t rho -> HList rho -> HList rho
rebuild h xs =
    case ( h, xs ) of
        ( Here, HCons x rest ) ->
            HCons x rest

        _ ->
            xs


main : Int
main =
    0
