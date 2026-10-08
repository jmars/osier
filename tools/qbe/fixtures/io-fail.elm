module IoFail exposing (main)

-- QBE stage-4 error-path fixture.  Two parity facts, one deterministic model:
--   * Io.readFile of a MISSING file completes SUCCESSFULLY with the empty
--     string (effectloop.zig leafReadFile's "M6 open-failure parity"), so the
--     model records the observed length (0).
--   * Task.fail -> Task.onError IS the error path: the handler replaces the
--     failure with a sentinel string.  The only failing effect in the host is
--     an explicit Task.fail; every leaf effect (read/write/exec) swallows its
--     own failure to a success value by design.


type Msg
    = Done String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "unset"
    , Task.perform Done
        (Task.andThen
            (\missing ->
                Task.onError
                    (\_ ->
                        Task.succeed
                            (String.append "err-ok missing-len="
                                (String.fromInt (String.length missing))
                            )
                    )
                    (Task.fail "boom")
            )
            (Io.readFile "no-such-file-xyzzy.txt")
        )
    )


update msg model =
    case msg of
        Done s ->
            ( s, Cmd.none )
