module ApplyPerf exposing (main)

-- stage 6 B1 DEBT — the apply-family perf probe (the frame_perf_gate's fib
-- does NOT cover this: fib is direct defun calls + frames, zero closure
-- VALUE calls).  Every iteration calls through a let-bound closure VALUE
-- (`f x`), which routes through the apply family (rt_apply -> applyGo's
-- SATURATED arm -> Rt.copyWords -> Rt.callArity -> rt_call1), plus a
-- self-tail `go` loop.  MEASURED (median of 7 alternating pairs, the
-- frame-gate method): hatch-ON ~3.7s / hatch-OFF ~0.33s = ~11x at n=5e6.
-- The floor is Rt.copyWords' :val loop (a 40-byte blit + number boxing per
-- copied word — the B0perf-1 frameZero shape).  B1perf closes it; the gate
-- below catches a CATASTROPHIC regression, not the known 11x floor.

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
