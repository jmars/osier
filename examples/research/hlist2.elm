module HList2 exposing (main)
import Prelude exposing (..)

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : Has l t rho -> t -> HList rho -> HList { l : t | rho }


-- the recursive call is at a DIFFERENT row (the tail), which is a
-- constructor-introduced existential.
hget : Has l t rho -> HList rho -> t
hget h xs =
    case ( h, xs ) of
        ( Here, HCons _ x _ ) ->
            x

        ( There h2, HCons _ _ rest ) ->
            hget h2 rest


main : Int
main =
    0
