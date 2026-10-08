module IoWrite exposing (main)

-- QBE stage-4 I/O fixture: write a file to QBE_IO_OUT (via Io.getenv), then
-- read it back and return the content as the model.  The check script ALSO
-- compares the on-disk bytes after native vs elmvm (the write path itself is
-- the thing under test, not just the round-trip read).


type Msg
    = Done String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "unset"
    , Task.perform Done
        (Task.andThen
            (\out ->
                Task.andThen
                    (\_ ->
                        Task.andThen
                            (\readback ->
                                Task.succeed readback
                            )
                            (Io.readFile out)
                    )
                    (Io.writeFile out "hello native\nline2\n")
            )
            (Io.getenv "QBE_IO_OUT")
        )
    )


update msg model =
    case msg of
        Done s ->
            ( s, Cmd.none )
