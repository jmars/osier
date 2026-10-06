module RowgadtSetx exposing (..)

-- The update side of the crux: record update is row-SHAPE-PRESERVING (Leijen
-- scoped-label replace), so under the Here refinement rho ~ { l : t | rho' }
-- the branch updates l in place and returns the SAME open row — no equation
-- escapes (key question 5).

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


setx : type rho l t. { rho | l : t } -> Has l t rho -> t -> { rho | l : t }
setx r h v =
    case h of
        Here ->
            { r | l = v }

        There rest ->
            setx r rest v


main : { r | l : Int } -> Has l Int r -> Int -> { r | l : Int }
main r h v =
    setx r h v
