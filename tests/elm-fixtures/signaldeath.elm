module SignalDeath exposing (main)

-- M8 gate (osier-rtsplit follow-up): a child that dies BY SIGNAL must be
-- reported as 128+signum, not as a truncated exit status.  This is the only
-- gate assertion of the SIGNAL ARM of waitStatusCode
-- (vendor/osier-rt/src/rt/execplan.zig), the arm that was left with a single
-- vm_test — the deleted `wait/kill` prim test — after the prim prune.
--
-- The plan's single command is `sh -c 'kill -9 $$'`.  `sh` is not a child
-- builtin (execplan.zig isChildBuiltin), so runPipeline FORKS it and the
-- parent's waitpid sees WIFSIGNALED with SIGKILL: raw status word 9, whose
-- low 7 bits are the signal.  The signal arm therefore yields 128+9 = 137.
--
-- This expected value cannot be produced by a decoder that ignores the
-- signal arm: EXITSTATUS(9) is (9 >> 8) & 0xff = 0, so a broken translation
-- answers "0||" and the diff fails.  (Proven by asymmetry, see the gate
-- comment at the registration site.)
--
-- Platform.worker: this drives the SYNCHRONOUS runner (TaskExec ->
-- execPlanPrim -> runProgram -> runPipeline -> waitStatusCode).  Its twin
-- signaldeathasync.elm drives the M9 effect-loop reap path, which calls the
-- same arm from effectloop.zig.
--
-- NOTE: the fixture spawns a shell, so the death is the SHELL's, and the
-- exit code is 137 regardless of /bin/sh's identity (dash and bash both
-- SIGKILL themselves here).

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


argv =
    Plan.cons (Plan.str "sh")
        (Plan.cons (Plan.str "-c") (Plan.cons (Plan.str "kill -9 $$") Plan.nil))


-- Cmd = [Argv Redirs Sub]: no redirects (Plan.nil), plain command (Plan.nil).
cmd =
    Plan.cons argv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


pipeline =
    Plan.cons cmd Plan.nil


-- Chain = [(sym "seq") pipeline]; Program = [chain].
chain =
    Plan.cons (Plan.sym "seq") (Plan.cons pipeline Plan.nil)


plan =
    Plan.cons chain Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
