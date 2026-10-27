module M exposing (main)

-- THE i61 BOUNDARY, OUTSIDE EDGE (perf word-arm-arith, review finding 1).
--
-- THE ARMS ARE SUPPOSED TO DIVERGE HERE, which is why this program is NOT in
-- `tools/qbe/word-arm-diff/` — that row asserts the two arms AGREE, and this is
-- the one arithmetic result where they must not:
--
--   val arm   prints `2305843009213693952` (2^61, the exact i64 product);
--   word arm  EXITS 1 with `qbe-rt: word arm: mknum overflow - the value does
--             not fit the i61 fixnum ... Refusing instead of truncating.`
--
-- WHY THE DIVERGENCE IS THE RIGHT ANSWER AND NOT A BUG: a word-arm fixnum is an
-- i61 (three of the word's bits are the tag), so 2^61 has no fixnum encoding at
-- all.  The alternatives are (a) shift and silently drop the top three bits —
-- the silent-wrong class this whole arm exists to prevent, and exactly what
-- `storeWordCell`'s round-trip check refuses, (b) box it onto the heap — the
-- i61 OVERFLOW/BOXING path, which is valrep2 area 4 and DOES NOT EXIST, or
-- (c) halt with a name.  (c) is what ships, and this fixture is the only place
-- that ever EXECUTES it: the emission-level TestMain row asserts the `.ssa`
-- carries the `Rt.die` call and the message, which is a statement about text,
-- not about a refusal anyone has seen fire.
--
-- WHY 2^61 AND NOT 2^60: the bound is EXCLUSIVE IN MAGNITUDE (`-2^60 <= n <
-- 2^60`, stated once at `RtLayout.wordFixnumLimit`), so `2^60` is already out of
-- range and `2^60 - 1` cannot be SPELLED in this compiler's Int (a double: it
-- rounds up to 2^60, the trap that constant's comment records).  `2^61` is
-- unambiguously outside on every reading of the bound, so this fixture cannot
-- pass because of a rounding accident.
--
-- BOTH OPERANDS ARE LEGAL LITERALS: 2^29 and 2^32, well under the 2^53 past
-- which `lowerLitWord` refuses a literal (`LNumberBig`).  The value that does
-- not fit is therefore COMPUTED, which is the only way to reach the boundary.
--
-- WHAT IS *NOT* TESTED, and why it cannot be: `INT64_MIN // -1`, `Rt./`'s second
-- named halt, is UNREACHABLE on this arm — a word-arm fixnum's magnitude is at
-- most 2^60, so no operand pair can carry INT64_MIN.  The shared check in
-- `Rt./` is inert here; it is not dead code, it is the val arm's.
main =
    536870912 * 4294967296
