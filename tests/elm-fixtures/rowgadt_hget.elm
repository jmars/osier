module RowgadtHget exposing (main)

-- The witness-encoded HList (handoff-rowgadt L2(b)): a record encoded as a
-- cons-list indexed by the ROW, with {} as the closed base case. `hget` reads
-- the element the witness `Has l t rho` points at, recursing over the nested
-- existential row index. The recursive There arm unifies the two tails of the
-- SAME rigid rho (the last L2(b) blocker) and must compile CLEAN.

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


hget : type l t rho. Has l t rho -> HList rho -> t
hget h xs =
    case ( h, xs ) of
        ( Here, HCons x _ ) ->
            x

        ( There h2, HCons _ rest ) ->
            hget h2 rest


main : Int
main =
    0
