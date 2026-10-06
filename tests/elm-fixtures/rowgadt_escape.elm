module RowgadtEscape exposing (..)

-- NEGATIVE: the refined equation must ESCAPE its branch to type the result.
-- Here refines rho ~ { l : t | rho' }; the branch builds a record whose row is
-- the REFINED shape, so matching the result { rho | l : t } needs rho to BE
-- { l : t | rho' } globally. Branch-local equations may not escape: expect
-- the explicit 'escaping row equation' error.

type Has l t rho
    = Here : Has l t { l : t | rho }


cast : type rho l t. { rho | m : t } -> Has l t rho -> t -> { rho | l : t }
cast r h v =
    case h of
        Here ->
            { r | l = v }


main : Int
main =
    0
