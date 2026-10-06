module RowgadtEscapeLaunder exposing (main)

-- NEGATIVE (escape shape: let-laundering, found by the adversarial escape
-- hunt 2026-10-05). The Here branch refines rho ~ { l : t | rho' } and
-- returns the TAIL (rest : HList rho'), but laundered through a `let`-bound
-- intermediate. Before the fix, let-generalization quantified the refined
-- tail rho', so the returned row was a FRESH variable escapeViaTail never saw;
-- the branch returned `rest` (missing field l) at the full HList rho type.
-- Must ERR 'escaping row equation'.

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
            let
                ys = rest
            in
            ys

        ( There h2, HCons _ rest ) ->
            escapeBad h2 rest


main : Int
main =
    0
