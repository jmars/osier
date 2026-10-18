module Readpipe exposing (main)

-- STAGE 7C gate: THE SUSPENDED readFile ARM plus the ACCUMULATOR GROW — the
-- only row that exercises the Mid effect host's fd table end to end (openat
-- O_NONBLOCK -> read -> EAGAIN -> hostRebuildPollfds -> poll(fds, nfds, -1) ->
-- hostDrainReady -> hostReadFileComplete -> close).
--
-- It is a `Platform.program`, so it really is the effect loop: a
-- `Platform.worker` fixture such as `readfile` runs the SYNCHRONOUS driver
-- instead (Runtime.drive -> runTask -> the read-file-as-string prim), never
-- reaches the host, and so cannot see this unit at all.  MEASURED, and the
-- reason this row exists: `readfile`/`iofile` are green on both arms trivially.
--
-- WHY A PIPE AND NOT A FILE: read() on a REGULAR file never returns EAGAIN, so
-- a file-based readFile drains to EOF inside its own dispatch and never touches
-- the poll table (that synchronous drain is what lets a readFile OVERTAKE a
-- suspended exec — `asyncorder`).  The gate feeds this row's stdin from a SLOW
-- PRODUCER (`printf he; sleep 0.05; printf llo`), so /dev/stdin is a pipe that
-- is EMPTY when the leaf first reads it: EAGAIN, suspend, poll, and the second
-- chunk is what wakes the loop.
--
-- THE PRODUCER CANNOT RACE INTO EOF: it writes "he" immediately and holds its
-- write end open for at least 50 ms, so the reader can never see EOF before at
-- least two bytes are in the pipe.  The worst case is ONE read carrying all
-- five bytes instead of two — the same answer.
--
-- THE SECOND READ IS THE GROW ARM (big.txt is 70000 bytes > the 65536 read
-- chunk), so the accumulator's double-and-copy runs under the host as well:
-- two reads, one `hostRfGrow`, one `memGo`, and the length is what proves the
-- copy carried every byte.

type Msg
    = Got ( String, Int )


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got chain
    )


chain =
    Task.andThen afterPipe (Io.readFile "/dev/stdin")


afterPipe pipe =
    Task.map (\big -> ( pipe, String.length big )) (Io.readFile "tests/elm-fixtures/input/big.txt")


update msg model =
    case msg of
        Got ( pipe, bigLen ) ->
            ( "pipe=[" ++ pipe ++ "] big=" ++ String.fromInt bigLen, Cmd.none )
