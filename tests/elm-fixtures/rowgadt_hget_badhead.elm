module RowgadtHgetBadhead exposing (main)

-- NEGATIVE (n3): the branch's body returns a String where the result index t
-- is expected. The (now-working) recursive tail unification must not let a
-- value of the wrong type out through the composed equations. Must ERR
-- ('is rigid ... String').

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


hgetBad : type l t rho. Has l t rho -> HList rho -> t
hgetBad h xs =
    case ( h, xs ) of
        ( Here, HCons _ _ ) ->
            "hello"

        ( There h2, HCons _ rest ) ->
            hgetBad h2 rest


main : Int
main =
    0
