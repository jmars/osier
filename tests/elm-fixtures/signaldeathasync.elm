module SignalDeathAsync exposing (main)

-- M9 gate (osier-rtsplit follow-up): the SAME signal-death claim as
-- signaldeath.elm, but driven through the effect-loop reap path instead of the
-- synchronous runner.  Platform.program hands the TaskExec plan to
-- src/effectloop.zig's leafExec (single plain command -> fork + piped capture),
-- whose reapChildren / reapBlocking call the very same waitStatusCode arm
-- (effectloop.zig reapChildren + reapBlocking).  Two call sites of one arm:
-- signaldeath.elm pins execplan.zig's runPipeline, this pins the event loop's.
--
-- `sh -c 'kill -9 $$'` dies by SIGKILL, so the status word is 9 and the arm
-- must report 128+9 = 137.  A decoder that dropped the signal arm returns
-- EXITSTATUS(9) = 0 -> "0||" -> the diff fails.  (See the registration site
-- for the asymmetry proof.)
--
-- Determinism note: the child dies instantly, so the reap races nothing —
-- the pipe EOF and the zombie are both resolved inside the loop's fixpoint
-- drain (the fastexec.elm regression, same shape) — and the check is run
-- repeatedly by the failure proof below.

type Msg
    = Got ( Int, String, String )


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


argv =
    Plan.cons (Plan.str "sh")
        (Plan.cons (Plan.str "-c") (Plan.cons (Plan.str "kill -9 $$") Plan.nil))


cmd =
    Plan.cons argv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


pipeline =
    Plan.cons cmd Plan.nil


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
