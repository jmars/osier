module M exposing (main)

-- `// 0` IS A NAMED HALT ON BOTH ARMS (perf word-arm-arith; L3-U2's decision,
-- NOT duplicated by this unit).
--
-- `//` is an i64 divide, so its two defined traps are a zero divisor and the
-- one quotient that is not representable (INT64_MIN // -1 = 2^63).  Before
-- L3-U2 both were a BARE SIGFPE — exit 136, no diagnostic, nothing to assert
-- on — which is an accident of the lowering rather than a language decision.
-- `Rt./` now pre-checks both and halts through `Rt.die` (write to fd 2, exit
-- 1), and this fixture is the WORD arm's half of that claim: the word arm
-- reaches the SAME defun through `rtPrimSlots`, so it must halt the SAME way.
--
-- WHAT THIS ROW CAN AND CANNOT SEE, stated: `word-arm-diff` compares the EXIT
-- CODE and STDOUT, not stderr, so this pins "both arms halt, with the same
-- code" — 1, the named channel — and NOT the message text.  A SIGFPE (136), a
-- SIGSEGV (139) or a quiet `0` would all be a different exit code or different
-- output, so the two failure modes that matter are visible.  The message text
-- is pinned on the val arm by the language gate's own error rows.
--
-- THE PROGRAM DELIBERATELY PRINTS NOTHING: a halt is the whole observable, and
-- adding anything else to this module would only hide it.
main =
    7 // 0
