module RowgadtAbsentfield exposing (..)

-- NEGATIVE: a GADT refinement licenses reading only the refined field. Here
-- refines rho ~ { l : t | rho' }; zz is NOT in the refined shape (and not in
-- the signature's known fields), so the selection must STILL ERR even inside
-- the refined branch.

type Has l t rho
    = Here : Has l t { l : t | rho }


selAbsent : type rho l t. { rho | m : t } -> Has l t rho -> t
selAbsent r h =
    case h of
        Here ->
            r.zz


main : Int
main =
    0
