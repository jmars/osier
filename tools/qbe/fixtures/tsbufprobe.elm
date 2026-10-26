module TsbufProbe exposing (main)

-- THE TSBUF-ALIASING PROBE (handoff-apply-chain-u3b stage 0(a); the row is
-- qbe-check.sh's `tsbuf-apply`).  It pins the ONE silent-wrong-answer class the
-- F-site staging seat can introduce, and the hazard is a COINCIDENCE OF
-- STORAGE CLASSES rather than a bug you can see in one defun.
--
-- THE SHAPE.  `main` applies `k` (arity 1) to TWO args in tail position, so the
-- site is lowerApp's over-applied GRef arm -> rtApply isTail -> Rt.stage-apply
-- + `tcall Rt.apply-tail` — the outer chain's staged block is live from here
-- until hop 2 reads its SECOND arg.  INSIDE that window the hop runs user code
-- that reaches BOTH remaining staging seats:
--
--   k's body `go (\p q -> g p q)` is a STATIC tail call with 1 arg  -> stage-tail
--   go's body `f 1 2` (f is a PARAM, so the call is GENERIC)         -> stage-apply
--   the lambda's body `g p q` is a STATIC tail call with 2 args      -> stage-tail
--
-- so TWO staged blocks are in flight at once, one of them nested inside the
-- other's hop, and the SHARED static buffer (globals word 12, `tsbuf`) is
-- written twice while the outer block is live.  Rt.stage-apply must malloc: a
-- tsbuf arm there would make the outer chain's staged args ALIAS the static
-- buffer, the nested hops would overwrite them, and hop 2 would read the
-- nested staging's first arg instead of `42` — 1127 instead of 42127, with
-- every pointer still valid and no crash.  That is the silent-wrong class;
-- the row asserts the VALUE, not just the exit code.
--
-- MEASURED: 42127 = 42*1000 + 1*100 + 2*10 + 7.
--
-- The hazard is closed BY CONSTRUCTION today (Rt.stage-apply's only allocation
-- is `malloc`; tsbuf is loaded only by Rt.stage-tail) and NOTHING ELSE WATCHES
-- IT: this row is the only witness, which is why it exists before U3b's
-- deletions touch the staging family (u3a-review SHOULD-FIX 1).

g p q =
    \y -> y * 1000 + p * 100 + q * 10 + 7


go f =
    f 1 2


k x =
    go (\p q -> g p q)


main =
    k 7 42
