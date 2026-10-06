module RowgadtHgetEscape exposing (main)

-- NEGATIVE (n2): the branch refines rho ~ { l : t | rho' } and returns the
-- TAIL (rest : HList rho') at the FULL row type HList rho. The tail is a
-- proper sub-row of the head, so the flexible tail would alias the head
-- "successfully" — but that identification is exactly the refinement escaping
-- its branch. Must ERR with 'escaping row equation'.

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : t -> HList rho -> HList { l : t | rho }


escapeBad : type l t rho. Has l t rho -> HList rho -> HList rho
escapeBad h xs =
    case ( h, xs ) of
        ( Here, HCons _ rest ) ->
            rest

        ( There h2, HCons _ rest ) ->
            escapeBad h2 rest


main : Int
main =
    0
