module PartyApply exposing (chain)

-- stage-6 U0 ABI fixture — the PARTIAL -> OVER-APPLICATION chain.
--
-- arity9apply (Arity9.main9) is the only other over-application row and it is
-- a SINGLE saturated call (9 args exactly filling rt_apply's saturation
-- buffer).  This fixture is the CHAIN the apply-family ABI swap has to
-- survive: a 3-ary defun applied with fewer args yields a PARTIAL closure
-- (applyGo's `rem > nargs` arm, the saturation buffer holding staged args),
-- and that closure is then applied with MORE args than it still needs, so the
-- OVER arm fires: it saturates with the first remaining arg, calls the defun
-- body — which returns a FURTHER function — and the caller applies that
-- result to the leftover arg.  Every rt_apply arm (partial, over, saturated)
-- runs in one entry, and the final answer is arg-order-sensitive:
--   chain = rest (part add3)
--         = ((add3 1 2) 3) 4
--         = (\d -> 1*1000 + 2*100 + 3*10 + d) 4
--         = 1234

add3 a b c =
    \d -> a * 1000 + b * 100 + c * 10 + d


part f =
    f 1 2


rest g =
    g 3 4


chain =
    rest (part add3)
