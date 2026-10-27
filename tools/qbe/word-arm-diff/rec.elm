module M exposing (main)

-- THE RECORD FAMILY, CLASS 1: BUILD (perf word-arm-records R2).
--
-- A word-arm record is ONE code-14 heap block whose body is
-- `[data_0 .. data_{n-1} | namesBase]` with header count n+1.  The print is
-- what a wrong layout cannot fake: the printer walks `i < veclen - 1` and
-- renders each DATA word, so
--   * a bare `veclen` bound prints the names word as a third element (a
--     pointer-shaped fixnum),
--   * a names-FIRST body prints the pointer as element 0 and shifts the data,
--   * a wrong element base reads the block header.
-- Two fields, and the second is a HEAP object (a string cell) while the first
-- is an immediate — the tup-fixture trick: a stride error shows up as the WRONG
-- element rather than as the right one by luck.
main =
    { x = 1, y = "hi" }
