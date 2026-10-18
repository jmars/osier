module ExecFallback exposing (main)

-- STAGE 7D gate: TaskExec's SYNCHRONOUS FALLBACK through the effect host —
-- the plan-shape predicate's NEGATIVE arm.  `singleCommandArgv` classifies the
-- decoded tree, and anything that is NOT a single plain command must run
-- through the synchronous plan runner instead of being forked.  The host sees
-- this plan because the fixture is a `Platform.program`:
--
--   * arm A: the Zig host classifies with execplan.singleCommandArgv, gets
--     null, and runs its `exec-plan` prim synchronously;
--   * arm B: the Mid host classifies with Rt.hostSingleCommandArgv, gets 0,
--     and calls Rt.exec-plan (which also frees the tree it decoded first —
--     the fallback's second decode is the price of Rt.exec-plan being
--     decode-and-run in one body).
--
-- WHY THE MODEL IGNORES THE RESULT VALUE.  MEASURED, in both arms: the
-- fallback hands back the PRIM's raw tagged list (`[cons, [number, 3], ...]`)
-- where the async arm hand-builds the bare `cons(code, cons(out, err))` the
-- host's continuation destructures, so a program-mode exec of a COMPLEX plan
-- prints `"cons|[?]|[?]"` on BOTH hosts today.  That is a PRE-EXISTING
-- Zig-host defect (the same class 7B measured for program-mode glob,
-- progio.elm's header) and 7D's faithful port inherits it; pinning the shape
-- in a golden would pin an accident.  So the payload is IGNORED and the
-- OBSERVABLE is the plan's own SIDE EFFECT: the command carries an `out`
-- redirect, which only the SYNCHRONOUS runner applies (the async leaf only
-- ever forks REDIRECT-FREE single commands).
--
-- That is what makes the row discriminate rather than merely complete: a host
-- that mis-classified and FORKED this plan would never apply the redirect, so
-- tests/elm-fixtures/out/execfallback.out would not exist and the out_cmp row
-- beside this one would be RED — while a host that correctly took the fallback
-- leaves "ho" in it.

type Msg
    = Got ( Int, String, String )


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


argv =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str "-n") (Plan.cons (Plan.str "ho") Plan.nil))


redir =
    Plan.cons (Plan.sym "out")
        (Plan.cons (Plan.num 1) (Plan.cons (Plan.str "tests/elm-fixtures/out/execfallback.out") Plan.nil))


cmd =
    Plan.cons argv (Plan.cons (Plan.cons redir Plan.nil) (Plan.cons Plan.nil Plan.nil))


pipeline =
    Plan.cons cmd Plan.nil


chain =
    Plan.cons (Plan.sym "seq") (Plan.cons pipeline Plan.nil)


plan =
    Plan.cons chain Plan.nil


init () =
    ( "", Task.perform Got (Io.exec plan) )


update msg model =
    case msg of
        Got _ ->
            ( "ok", Cmd.none )
