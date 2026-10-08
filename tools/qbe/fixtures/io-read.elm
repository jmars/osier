module IoRead exposing (main)

-- QBE stage-4 I/O fixture: read a file (the path comes from QBE_IO_IN via
-- Io.getenv, so the fixture is CWD-independent) and write a stdout sentinel
-- through the StreamRef (*stoutput*) path.  The effect loop is shared with
-- elmvm, so native output must be byte-identical: the sentinel first (fd-1
-- write inside the loop), then the final model "read:<len>:<contents>".


type Msg
    = Done String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "unset"
    , Task.perform Done
        (Task.andThen
            (\path ->
                Task.andThen
                    (\contents ->
                        Task.andThen
                            (\_ ->
                                Task.succeed
                                    (String.append "read:"
                                        (String.append (String.fromInt (String.length contents))
                                            (String.append ":" contents)
                                        )
                                    )
                            )
                            (Io.writeString "STREAM-OK\n")
                    )
                    (Io.readFile path)
            )
            (Io.getenv "QBE_IO_IN")
        )
    )


update msg model =
    case msg of
        Done s ->
            ( s, Cmd.none )
