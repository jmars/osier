module RowgadtSelect exposing (..)

-- The paper's crux example (reference implementation, handoff-rowgadt-plan D):
-- a row-membership witness GADT. Here refines rho to { l : t | rho' }, There
-- refines it to { k : s | rho } -- conflicting GLOBAL substitutions, so only
-- branch-local refinement (with rho RIGID from the signature) can type select.

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


select : type rho l t. { rho | l : t } -> Has l t rho -> t
select r h =
    case h of
        Here ->
            r.l

        There rest ->
            select r rest


-- A rigid-row use site: main's own signature keeps rho abstract, exactly the
-- discipline select's body was checked under.
main : { r | l : Int } -> Has l Int r -> Int
main r h =
    select r h
