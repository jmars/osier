module ExecNofile exposing (main)

-- 3B-2b gate: the redirect-OPEN-FAILURE path — a VALID plan whose `in`
-- redirect names a file that does not exist.  applyRedirects' .in arm must
-- write "Input redirect file not found: <path>" to the captured stderr and
-- the child _exits 1, so the delivered result is code 1 with that message
-- as err.  This is the only fixture that exercises childW2's error strings
-- and applyOneRedir's open-failure arm.

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


cmdOf argv redirs sub =
    Plan.cons argv (Plan.cons redirs (Plan.cons sub Plan.nil))


chainOf op pipeline =
    Plan.cons (Plan.sym op) (Plan.cons pipeline Plan.nil)


catArgv =
    Plan.cons (Plan.str "cat") Plan.nil


redirIn p =
    Plan.cons (Plan.sym "in") (Plan.cons (Plan.num 0) (Plan.cons (Plan.str p) Plan.nil))


plan =
    Plan.cons
        (chainOf "seq"
            (Plan.cons (cmdOf catArgv (Plan.cons (redirIn "no-such-file.txt") Plan.nil) Plan.nil) Plan.nil)
        )
        Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
