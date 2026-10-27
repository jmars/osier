module M exposing (main)

-- THE ARITHMETIC PRIM CLASS ON THE WORD ARM (perf word-arm-arith).
--
-- Until this fixture NO arithmetic prim could be lowered under
-- `QBE_VALREP=word`: `lowerArith`/`lowerCompare`/`lowerNumEq` end in a generic
-- tail that emits the 40-byte Value (the tag word at `slot + 0`, the payload at
-- `slot + 8`), and under the word arm those two addresses are the value word
-- and THE NEXT FRAME SLOT.  The port is a fork in each of the three: the word
-- arm skips the tail and calls the runtime (`Rt.+`/`-`/`*`/`/`/`<`/`=`) through
-- `rtPrimSlots`, which is arm-clean because those defuns read their operands
-- with `payload`/`payload32`/`tagis` and write with `mknum`.
--
-- WHAT THIS FIXTURE IS FOR: it is the only oracle that RUNS that arithmetic on
-- BOTH representations and compares the BYTES.  A wrong untag, a wrong tag
-- shift or a wrong `mknum` shows up here as a different number; a wrong stride
-- shows up as a crash or as another binder's value.  It is a differential, not
-- a golden, so it also proves the two arms AGREE — which is the property the
-- whole arm exists to preserve.
--
-- SEMANTICS PINNED HERE, all of them L3's and none re-litigated:
--   * `+ - *` wrap at i64 (every value here is inside i61, so no boxing);
--   * `//` TRUNCATES TOWARD ZERO — `(0 - 7) // 2` is `-3`, not the floor `-4`,
--     and `7 // (0 - 2)` is `-3` from the other side.  The word arm gets this
--     from `Rt./`, which is the SAME defun the val arm calls, so the two
--     answers cannot drift;
--   * `// 0` is a NAMED HALT through `Rt.die` (exit 1) on BOTH arms — not a
--     SIGFPE — which is L3-U2's pre-check, NOT duplicated here;
--   * `-x` is `0 - x` (Mid/FromAst's Negate desugar), so `negate` needs no
--     prim of its own and is covered by `-`;
--   * there is NO `%` OPERATOR in this language at all (`binaryPrims` maps `//`
--     to the prim `/` and defines no modulo), so nothing was ported for one.
--
-- THE OPERAND SHAPES ARE DELIBERATELY MIXED.  The literal pairs (`7 - 10`,
-- `5 == 5`) take the val arm's PROVEN-INT fast path — a raw i64 op with no call
-- — while the `App`-produced operands (`f 1`, `f (f 1)`, `f 1 < f 2`) are not
-- provable and take the runtime route on BOTH arms.  So the row compares the
-- two arms on the RUNTIME path as well as on the fast path, instead of only
-- where they happen to share one.

f x =
    x + 1


g x y =
    x * y


main =
    ( ( ( f 1, 7 - 10, 3 * 4 )
      , ( 7 // 2, (0 - 7) // 2, 7 // (0 - 2) )
      , ( 5 < 3, 3 < 5, (0 - 3) < 2 )
      )
    , ( ( 5 <= 5, 5 > 3, 5 >= 6 )
      , ( 5 == 5, 5 == 3, 5 /= 3 )
      , ( 5 /= 5, -5, -(3 * 4) )
      )
    , ( ( f (f 1), g 1000 1000000, 1000000 * 1000 )
      , ( f 1 == 2, f 1 /= 2, f 1 < f 2 )
      )
    )
