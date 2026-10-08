module Arity9 exposing (add9, apply9, main9)

-- QBE stage-4 arity fixture: the old rt_callN table stopped at rt_call8, so a
-- 9-ary defun (or closure) was a loud "arity > 8" compile error.  Three entry
-- points exercise the three arity-9 shapes:
--   * Arity9.add9 1 2 3 4 5 6 7 8 9  -> direct rt_call9 from the driver.
--   * Arity9.apply9 (a 1-ary fn taking add9) is NOT drivable from int args;
--     Arity9.main9 is the thunk that drives it: apply9 add9 -> f 1..9 where
--     f is a Var, so the 9-ary call goes through rt_apply's saturation buffer
--     (the generic/partial path), which the direct-call shape does not touch.


add9 a b c d e f g h i =
    a + b + c + d + e + f + g + h + i


apply9 f =
    f 1 2 3 4 5 6 7 8 9


main9 =
    apply9 add9
