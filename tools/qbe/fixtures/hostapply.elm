module HostApply exposing (main)

-- The DRIVER for the APPLIER PIN (stage 7A).  Every load-bearing line is in
-- Whost.mid; this module supplies the two COMPILED closures the pin applies
-- and hands the answers to the runtime's printer, so the golden is one line
-- and a wrong applier shows up as a wrong number (or as a heap address).
--
--   417   `upd` (a GLOBAL closure: arity 2, no captures) applied to
--         (msg 7, model 41) => 41 * 10 + 7.  With the Disp's arity taken as
--         `arity - rem` (= 0 args) or with applyGo's unforced tail this is not
--         417.
--   503   a closure that CAPTURES its multiplier (adderCap 5 => \msg -> 500 +
--         msg) applied to 3 => 503.  This arm is what pins the Disp's `caps`
--         (env) word: with env = 0 the callee reads a garbage capture.
--   111   `(upd 41) 7` driven through the applier as TWO calls: the first is
--         PARTIAL (an arity-2 closure handed 1 arg) and the second is the
--         SATURATED half-applied shape (arity 2, rem 1, napp 1) that blocked
--         the stage-7 O3 bootstrap.  7A died on it by name; a wrong interleave
--         gives a different number (or a crash).
--   123   an arity-2 closure that RETURNS a function, handed THREE args: the
--         OVER-APPLIED arm (saturate 2, then apply the result to the third).
--         7A refused it by name too.
--
-- Both arms churn 20 000 allocations inside the .mid before applying, so the
-- row's churn run (QBE_HEAP_MB = CHURN_MB) also pins that the closure and its
-- arguments survive a MOVING scavenge because they live in a REGISTERED root
-- array.
upd : Int -> Int -> Int
upd msg model =
    model * 10 + msg


addBoth : Int -> Int -> (Int -> Int)
addBoth a b =
    \c -> a * 100 + b * 10 + c


adderCap : Int -> Int -> Int
adderCap k =
    \msg -> k * 100 + msg


main =
    [ Whost.run upd 41 7
    , Whost.runCap (adderCap 5) 3
    , Whost.runPart upd 41 7
    , Whost.runOver addBoth 1 2 3
    ]
