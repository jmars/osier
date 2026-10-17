module ApplyPerf exposing (main)

-- stage 6 B1 — the apply-family perf probe (the frame_perf_gate's fib does
-- NOT cover this: fib is direct defun calls + frames, zero closure VALUE
-- calls).  Every iteration calls through a let-bound closure VALUE (`f x`),
-- which routes through the apply family (rt_apply -> applyGo's SATURATED
-- arm -> Rt.copyWords -> Rt.callArity -> rt_call1), plus a self-tail `go`
-- loop.  MEASURED (median of 7 alternating pairs): hatch-ON ~3.16s /
-- hatch-OFF ~0.33s = ~9.5x at n=5e6 after the B1fix copyWords word loop
-- (pre-fix, the :val copyWords loop, was ~11.6x).  The remaining ~9.5x is
-- the apply family's per-call framing + :val blit overhead, NOT copyWords
-- (which copies only 5 words here) — a separate B1perf unit's scope.

main n =
    let
        f =
            \x -> x + 1

        go i acc =
            if i == 0 then
                acc

            else
                go (i - 1) (f (acc + 1))
    in
    go n 0
