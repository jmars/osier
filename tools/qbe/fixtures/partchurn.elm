module PartChurn exposing (main)

-- stage 6 B1 — the partial arm's CAPTURE COPY under churn: a closure WITH A
-- CAPTURE is PARTIALLY re-applied in a loop, so applyGo's PARTIAL arm runs
-- with `env != null` (the capture array) while the Zig scavenger collects.
-- The result is the deterministic sum over n=1..N of (n + n + 1) = N^2 + 2N.
-- (The root-order mutation probe mutates the env_root push in THIS fixture's
-- partial arm — see handoff-osier-stage6-b1-result.)

make x =
    \y z -> x + y + z


loop n acc =
    if n == 0 then
        acc

    else
        let
            g =
                make n

            p =
                g n
        in
        loop (n - 1) (acc + p 1)


main =
    loop 300000 0
