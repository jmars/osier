module Mono exposing (main, fib, fibAt, foldPair, foldAt)

-- MONOMORPHISATION — the POSITIVE direction (S5/M2, Mid/Qbe/Monomorphise.elm;
-- switch QBE_NOMONO=1).
--
-- WHAT THIS FIXTURE IS FOR.  A defun the checker typed POLYMORPHICALLY is
-- compiled once, generically: every arithmetic, comparison and primitive
-- inside it keeps the VM's tagged shape (an inline fast path plus a `q_Rt_*`
-- fallback), because no pass can know what its type variables will be.  The
-- specialiser clones such a defun at the instantiations its SATURATED DIRECT
-- call sites use, so the clone lands in the type table as a CLOSED MONOTYPE and
-- S4/M1's `intParamsOf` can hand its parameters a representation.
--
-- THE FIXTURE IS SHAPED LIKE THE PLAN'S OWN EXAMPLE, and that is deliberate:
-- `fib n` has NO annotation, so it generalises to `number -> number`, and its
-- `+ - <` route through real `q_Rt_*` calls (plan.md Phase 2).  Cloning it at
-- Int is what makes those disappear.  Note WHERE the instantiation comes from:
-- `fibAt : Int -> Int`'s parameter is the only thing in this file that can
-- close `number`, because the settled sigma rule types an argument from the S2
-- BINDER MAP (a `Var`) or from a lambda's parameters — and `fib` is called
-- from `fibAt` with a parameter, not with a literal.
--
-- WHAT THE ROW ASSERTS (tools/qbe/qbe-check.sh, the `mono-*` rows):
--   * OFF: no clone function exists at all;
--   * ON:  exactly the firing clones exist, and the clone's OWN body has NO
--     `q_Rt_*` / `rt_prim` call site left — the mechanism, not just the clock;
--   * the ORIGINAL `fib` still exists with its fallbacks INTACT, because its
--     own recursive calls are instantiated at its OWN type variables and are
--     therefore refused (the `untyped` count in the note line) — clone-do-not-
--     replace, visible in one .ssa;
--   * stdout matches the golden, and again under QBE_HEAP_MB=16.
--
-- The note line the pass prepends to the .ssa carries its own counts, so a
-- refusal can never be confused with "the pass did not run".


-- 1. the polymorphic callee.  No signature: `number -> number`, so its own
--    body is generic and its own recursive calls cannot be instantiated.
fib n =
    if n < 2 then
        n

    else
        fib (n - 1) + fib (n - 2)


-- 2. the closer: an Int PARAMETER is what closes `number`, and this defun is a
--    MONOTYPE, so the S2 binder map has a ground type for `n`.
fibAt : Int -> Int
fibAt n =
    fib n


-- 3. a second, differently-shaped instantiation of the SAME generic idea: a
--    two-parameter defun where one argument is a LAMBDA and one is an Int
--    parameter.  `(a -> b -> b) -> b -> List a -> b` closes at
--    `(Int -> Int -> Int) -> Int -> List Int -> Int`.
foldPair : (a -> b -> b) -> b -> List a -> b
foldPair f acc xs =
    case xs of
        [] ->
            acc

        y :: ys ->
            foldPair f (f y acc) ys


foldAt : Int -> List Int -> Int
foldAt acc xs =
    foldPair (\a b -> a + b) acc xs


-- 4. the entry.  `main` keeps both firing instances live so one compile is
--    enough, and returns an Int, so a miscompile is a WRONG NUMBER.
main : Int
main =
    fibAt 12 + foldAt 0 [ 1, 2, 3, 4, 5 ]
