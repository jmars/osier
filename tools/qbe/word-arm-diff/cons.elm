module M exposing (main)

-- THE FIRST DATA STRUCTURE THIS ARM BUILDS (perf word-arm-surface).
--
-- Until this fixture every word-arm program was a LITERAL: the surface lane
-- refused `ListLit`/`Con`/`Tup`/`PrimApp` at its classifier, so no program
-- could allocate anything the printer then had to walk.  A right-nested cons
-- chain is the smallest thing that can: `1 :: 2 :: []` desugars to
-- `cons 1 (cons 2 (emptylist 0))`, which lowers through `rtPrimSlots` into the
-- runtime's own `Rt.cons`/`Rt.emptylist` — the defuns AREA 3 twinned — so the
-- heap cells, the element stores and the printer's tag-4 walk are all
-- EXECUTED here, on both arms, and their output compared byte for byte.
--
-- The tail is deliberately `[]` and not `3 :: 4 :: []`: this fixture exists to
-- exercise the CONS cell, so it carries no arithmetic.  (The sentence that
-- stood here — "an arithmetic prim is still refused by name (AREA 4)" — was
-- true until perf word-arm-arith ported the arithmetic class; `arith.elm` is
-- that fixture now, and it is the one to extend for arithmetic.)
main =
    1 :: 2 :: []
