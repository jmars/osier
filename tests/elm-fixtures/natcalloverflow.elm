module NatCallOverflow exposing (deep, main)

-- NATIVE-path twin of calloverflow.elm: the same non-tail recursion, pinned
-- against the QBE backend's OWN resource boundary -- the C stack -- instead of
-- the VM's CALL_STACK_DEPTH frame cap.
--
-- WHY A SEPARATE FIXTURE.  The interpreter arm (calloverflow) asserts the
-- VM's out-of-frames failure; that semantic dies with the interpreter (the
-- plan retires ZINC).  The native path has NO frame cap and NO interpreter to
-- fall back to: `n + deep (n - 1)` grows the real C stack one native frame
-- chain per level until the kernel refuses to grow it (RLIMIT_STACK), which
-- used to surface as a BARE SIGSEGV -- non-zero, but unnamed: nothing a gate
-- can assert on and nothing a user can act on.  tools/qbe/rt.zig installs a
-- SIGSEGV-on-altstack guard that recognises a stack-exhaustion fault and
-- fails with the named diagnostic NAT_STACK_MSG (run-elm-gate.sh, check kind
-- `natdepth`); this fixture is what it runs.
--
-- SHAPE (identical to calloverflow.elm on purpose): the addition happens
-- AFTER the recursive call, so every frame stays live all the way down and no
-- accumulator can be introduced without changing what is under test.  `main`
-- takes the depth from argv so the CHECK owns the number: the native boundary
-- is a byte budget (stack limit / per-level stride), not a frame count, so
-- the gate fixes the budget itself (its own `ulimit -s` under
-- QBE_NO_RLIMIT=1) rather than baking in a depth that would silently stop
-- exercising the boundary if the per-level stride ever changes.
--
-- `main` at a legal depth is the control: deep 1000 == 500500 on every
-- backend (the same control value calloverflow uses).


deep : Int -> Int
deep n =
    if n <= 0 then
        0

    else
        n + deep (n - 1)


main : Int -> Int
main n =
    deep n
