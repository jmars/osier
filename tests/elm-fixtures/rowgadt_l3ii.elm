module RowgadtL3ii exposing (main)

-- L3 principality boundary (ii): the NATIVE-ROW witness-style access with NO
-- signature. The Here/There refinements fix `rho` to `{l:t|rho'}` vs `{k:s|rho}`
-- in SIBLING branches; without the `type rho l t.` binder `rho` is flexible and
-- the two equations CONFLICT (the recursive There call produces an infinite
-- row). MEASURED: REJECTED ("infinite type").

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


select r h =
    case h of
        Here ->
            r.l

        There rest ->
            select r rest


main : Int
main =
    0
