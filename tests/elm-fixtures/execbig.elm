module ExecBig exposing (main)

-- 3B-2c gate: the SLURP GROW arm through exec — output beyond the 64 KiB
-- read chunk (execpipe's whole captured output is 2 bytes; no earlier exec
-- row reaches a second chunk, so nothing pinned the accumulator's grow/copy
-- through the exec route).  The model folds CODE and the two LENGTHS (the
-- golden stays three numbers; the bytes still cross the slurp whole —
-- 168894 of them).  Also the second fd's EMPTY arm: stderr EOFs at 0 after
-- the out slurp's grow (the shared C block's acc/len/cap reset between the
-- two slurps is load-bearing here).

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


cmdOf argv redirs sub =
    Plan.cons argv (Plan.cons redirs (Plan.cons sub Plan.nil))


chainOf op pipeline =
    Plan.cons (Plan.sym op) (Plan.cons pipeline Plan.nil)


seqArgv =
    Plan.cons (Plan.str "seq") (Plan.cons (Plan.str "30000") Plan.nil)


plan =
    Plan.cons
        (chainOf "seq" (Plan.cons (cmdOf seqArgv Plan.nil Plan.nil) Plan.nil))
        Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", String.fromInt (String.length out), "|", String.fromInt (String.length err) ], Cmd.none )
