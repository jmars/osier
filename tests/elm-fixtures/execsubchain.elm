module ExecSubChain exposing (main)

-- exec-plan fix round: a SUBSHELL whose inner program is TWO chains, chain 0
-- an ECHO BUILTIN — the shape that caught the third slot failure.  The
-- in-process builtin arm (runBuiltinInprocess -> childBuiltin -> echoGo)
-- runs INSIDE the program loop, and echoGo's arg cursor once shared the
-- loop's own rI slot: the echo advanced the CHAIN cursor, mode 0 then saw
-- i >= nchains, and every chain after the echo was silently dropped (this
-- fixture printed "0|a\n|" before the dedicated rEchoI slot).  No earlier
-- fixture covers it: execchain's chains are TOP-LEVEL (the forked child
-- _exits, so its clobber is dead) and EpPSub-style subshells carry a
-- SINGLE-chain inner program.  Expected = the Zig arm's semantics
-- (runProgram's cursor is a local for variable — execplan.zig), measured
-- on the sh -c control variant which shares the loop shape.

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


cmdOf argv redirs sub =
    Plan.cons argv (Plan.cons redirs (Plan.cons sub Plan.nil))


chainOf op pipeline =
    Plan.cons (Plan.sym op) (Plan.cons pipeline Plan.nil)


echoArgv s =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str s) Plan.nil)


inner =
    Plan.cons
        (chainOf "seq" (Plan.cons (cmdOf (echoArgv "a") Plan.nil Plan.nil) Plan.nil))
        (Plan.cons
            (chainOf "seq" (Plan.cons (cmdOf (echoArgv "b") Plan.nil Plan.nil) Plan.nil))
            Plan.nil
        )


plan =
    Plan.cons
        (chainOf "seq" (Plan.cons (cmdOf Plan.nil Plan.nil inner) Plan.nil))
        Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
