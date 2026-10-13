module ExecGlob exposing (main)

-- M8 gate: glob.  Globs tests/elm-fixtures/expected/exec*.txt (the three M8
-- expected files themselves), decodes the tagged result list to [String], and
-- joins them — sorted ascending by the VM.
--
-- GROUP 3B-1 FIX: the DOTFILE GUARD rows.  The exec*.txt base can never
-- match "." / "..", so it CANNOT reach the guard; the globdir/ rows do (a
-- committed directory holding exactly x.txt plus the dot pair every
-- directory has).  `?` admits `.` only (one char), `*` admits the whole
-- pair, `.*` admits both dots but not x.txt — the three shapes the byte
-- equality rewrite got silently wrong (review B1: a wildcard base that
-- matches "." ADMITS the dotfiles, because base is the fnmatch PATTERN).

type Msg
    = Got String


line p t rest =
    Task.andThen (\xs -> Task.andThen (\s -> Task.succeed (p ++ "|" ++ String.join "," xs ++ "\n" ++ s)) rest) t


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (line "tests/elm-fixtures/globdir/?" (Io.glob "tests/elm-fixtures/globdir/?")
          (line "tests/elm-fixtures/globdir/*" (Io.glob "tests/elm-fixtures/globdir/*")
            (line "tests/elm-fixtures/globdir/.*" (Io.glob "tests/elm-fixtures/globdir/.*")
              (Task.map (\xs -> String.join "," xs) (Io.glob "tests/elm-fixtures/expected/exec*.txt")))))
    )


update msg model =
    case msg of
        Got s ->
            ( s, Cmd.none )
