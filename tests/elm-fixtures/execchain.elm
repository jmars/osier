module ExecChain exposing (main)

-- 3B-2b gate: the CHAIN-level short-circuit (&& / ||), which no earlier
-- fixture reaches — execpipe is one chain, and the 3B-2a probes' and/or
-- rows are single-chain plans where the op never fires.  The program:
--   echo start ; sh -c "exit 3" && echo skipped-and || echo or-ran ; echo end
-- && must SKIP its chain when the previous code is nonzero (so
-- "skipped-and" must NOT appear), ; must always run, and the final code is
-- the LAST chain's (0).

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


cmdOf argv redirs sub =
    Plan.cons argv (Plan.cons redirs (Plan.cons sub Plan.nil))


chainOf op pipeline =
    Plan.cons (Plan.sym op) (Plan.cons pipeline Plan.nil)


shArgv s =
    Plan.cons (Plan.str "sh") (Plan.cons (Plan.str "-c") (Plan.cons (Plan.str s) Plan.nil))


echoArgv s =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str s) Plan.nil)


plan =
    Plan.cons
        (chainOf "seq" (Plan.cons (cmdOf (echoArgv "start") Plan.nil Plan.nil) Plan.nil))
        (Plan.cons
            (chainOf "and"
                (Plan.cons (cmdOf (shArgv "exit 3") Plan.nil Plan.nil) Plan.nil)
            )
            (Plan.cons
                (chainOf "or"
                    (Plan.cons (cmdOf (echoArgv "or-ran") Plan.nil Plan.nil) Plan.nil)
                )
                (Plan.cons
                    (chainOf "seq"
                        (Plan.cons (cmdOf (echoArgv "end") Plan.nil Plan.nil) Plan.nil)
                    )
                    Plan.nil
                )
            )
        )


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
