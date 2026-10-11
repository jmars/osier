module MonoArith exposing (main, fibAt)

-- SHAPE: monoarith -- THE MONOMORPHISATION TARGET SHAPE, which the suite's
-- mono axis does NOT contain.
--
-- WHY THIS FILE EXISTS.  mono_int/mono_float's axis is
-- `fold (\x acc -> x + acc) 0 (rangeI n [])`: the arithmetic lives in a
-- CLOSURE body, so cloning `fold` at Int does not unbox anything the hot loop
-- executes.  MEASURED (2026-10-11, orchestrator): all SEVEN clones the suite
-- produces across mono_int/mono_float/mono_record are 90-line bodies differing
-- from their originals by exactly ONE line -- the shared "non-exhaustive case"
-- data label -- and 9 of the 12 suite programs engage the pass not at all (no
-- candidate).  The suite therefore cannot see this pass in either direction,
-- and the S5 verdict of REFUTE is a statement about that INSTRUMENT, not about
-- monomorphisation.  This file is the instrument the verdict lacked.
--
-- THE SHAPE THAT DOES BITE puts the arithmetic ON THE POLYMORPHIC PARAMETER,
-- so the clone's parameter is in the type table and `Lower.intParamsOf` can
-- hand it the RAW representation: `n < 2` and `n - 1` lose both the tag test
-- and the `q_Rt_*` fallback call, and the `+` on their results follows.  The
-- wrapper `fibAt` exists because the instantiation must be DERIVED from an
-- argument whose recorded type is ground (`Int`) -- a literal argument
-- constrains nothing.
--
-- THIS IS A MECHANISM-TARGETED PROBE, not a representative workload: it is
-- deliberately the shape the pass is built for, and it must be reported
-- separately from the suite.  A win here says monomorphisation pays on
-- polymorphic arithmetic; it says nothing about general code, and the suite
-- result says nothing about this shape.


fibPoly : number -> number
fibPoly n =
    if n < 2 then
        n

    else
        fibPoly (n - 1) + fibPoly (n - 2)


fibAt : Int -> Int
fibAt n =
    fibPoly n


main : Int
main =
    fibAt 28
