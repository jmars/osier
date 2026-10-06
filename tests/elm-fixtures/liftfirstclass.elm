module LiftFirstClass exposing (main)

-- A RECURSIVE local helper used FIRST-CLASS: `addM` is passed to Prelude.map,
-- not applied at the call site.  The lifted helper must be a VALUE (a partial
-- application of the lifted name to its capture), not a callee.

mapPlus m xs =
    let
        addM n =
            if n == 0 then
                0
            else
                m + addM (n - 1)
    in
    Prelude.map addM xs


main =
    Prelude.sum (mapPlus 10 [ 1, 2, 3, 4 ])
