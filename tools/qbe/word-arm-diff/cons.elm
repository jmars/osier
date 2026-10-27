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
-- The tail is deliberately `[]` and not `3 :: 4 :: []`: nothing here needs
-- arithmetic, and an arithmetic prim is still refused by name (AREA 4), so a
-- longer chain would only make the fixture's refusal less specific.
main =
    1 :: 2 :: []
