module M exposing (main)

-- THE POISONED-BODY FIXTURE (word-arm closure counts, 2026-10-29).
--
-- A word-arm closure cell is ONE code-6 SCANNED block whose body is
--   [desc | rem | caps+1 | total]
-- (`Rt.closure` writes [desc | arity | caps+1 | cnt]; `Rt.applyPartGo` writes
-- [desc | rem - nargs | envv+1 | total]).  Before this fixture, body words 1
-- and 3 were RAW COUNTS and the collector's drain walks EVERY word of a
-- scanned body as a Value — so a count of 7 (any count ≡ 7 mod 8) read as tag
-- 7, the RESERVED POISON TAG, and the collect died with `scavenge read a
-- POISONED (forwarded young) body` (or `unknown value tag in mark walk` under
-- QBE_MIDGC_YOUNG=0).  Both writers now store `count * 8` and the five readers
-- divide by 8; the invariant is stated at `Rt.closure`'s KIND-CONTRACT block.
--
-- Two shapes, one per writer:
--   A (Rt.applyPartGo): `f8 i` is a partial application of an 8-arity function
--      to 1 argument -> body word 1 = rem - nargs = 7.
--   B (Rt.closure): `sevensMake i` returns an inner lambda capturing 7
--      variables -> body word 3 = cnt = 7.
--
-- The closures are kept REACHABLE through a cons chain while the rest are
-- built (a collect mid-build must scan them live), then applied and
-- content-compared.  A correct arm answers `6000/0|6000/0` (A then B) — and
-- the comparison is a CONTENT comparison, so a cell whose counts read back at
-- the wrong scale answers a wrong number instead of matching itself.
--
-- MEASURED BEFORE the fix, on this tree: word arm rc 1 with the poison
-- fingerprint at QBE_HEAP_MB=1/2/4/8 and the mark-walk fingerprint at h2 with
-- QBE_MIDGC_YOUNG=0; val arm `6000/0|6000/0` rc 0 everywhere; and the WORD arm
-- at DEFAULT KNOBS also `6000/0|6000/0` rc 0 — no collect ever happens there,
-- which is exactly why every gate in the tree was green while the whole-
-- compiler emit died.  AFTER: identical output on both arms at every rung.
--
-- NOTE THE MODULE IS `M`: this fixture is a `word-arm-gcchurn` row, and that
-- runner's entry key is M.main.

f8 a b c d e g h i =
    a + b + c + d + e + g + h + i


sevensMake v =
    let
        a1 =
            v

        a2 =
            v + 1

        a3 =
            v + 2

        a4 =
            v + 3

        a5 =
            v + 4

        a6 =
            v + 5

        a7 =
            v + 6
    in
    \x -> x + a1 + a2 + a3 + a4 + a5 + a6 + a7


wantA i =
    i + 1 + 2 + 3 + 4 + 5 + 6 + 7


wantB i =
    1000 + i + (i + 1) + (i + 2) + (i + 3) + (i + 4) + (i + 5) + (i + 6)


buildA i acc =
    if i == 0 then
        acc

    else
        buildA (i - 1) (f8 i :: acc)


buildB i acc =
    if i == 0 then
        acc

    else
        buildB (i - 1) (sevensMake i :: acc)


checkA xs i good bad =
    case xs of
        [] ->
            String.append (String.fromInt good) (String.append "/" (String.fromInt bad))

        p :: rest ->
            if p 1 2 3 4 5 6 7 == wantA i then
                checkA rest (i + 1) (good + 1) bad

            else
                checkA rest (i + 1) good (bad + 1)


checkB xs i good bad =
    case xs of
        [] ->
            String.append (String.fromInt good) (String.append "/" (String.fromInt bad))

        lam :: rest ->
            if lam 1000 == wantB i then
                checkB rest (i + 1) (good + 1) bad

            else
                checkB rest (i + 1) good (bad + 1)


main =
    String.append (checkA (buildA 6000 []) 1 0 0) (String.append "|" (checkB (buildB 6000 []) 1 0 0))
