module Rfpart exposing (main)

-- THE SATURATED CALL ON A HALF-APPLIED CONTINUATION (measured 2026-10-19).
--
-- A `Task.andThen` continuation that is a PARTIAL APPLICATION — here
-- `report "PREFIX:"`, arity 2 with ONE cell already in the closure's env —
-- is applied by the EFFECT HOST to one value. That is a SATURATED call
-- (`args.len == lambda.code_len`, the REMAINING arity) on a closure whose
-- `napp = arity - remaining` applied cells sit in `env`.
--
-- The Zig host's `hostApply` used to pass `desc.arity` params with only
-- `args.len` cells filled and the closure's env unchanged, so the callee's
-- first `napp` params (and its captures) were whatever the native stack held:
-- the continuation ran on garbage and the model came back mangled. The seed's
-- own compiler driver (`selfhost/NativeMain.elm`) has exactly this shape —
-- `Task.andThen (runSsa entry) (Io.readFile path)` — and read its manifest
-- into a garbage String, printing "elmc: manifest has no groups" with no
-- other symptom (`tools/qbe-bootstrap.sh --verify` RED in 42 s).
--
-- The fixture therefore prints BOTH facts the mangled call used to lose: the
-- applied PREFIX (out of the closure's env) and the READ TEXT's length and
-- first line. Golden (QBE_MIDHOST=1 and QBE_MIDHOST=0 alike):
--
--     "PREFIX:34:first line here"
--
-- tools/qbe/probe-hostpart.sh is the two-arm statement of it.

import Str


type Msg
    = Done String


main =
    Runtime.program
        { init = init
        , update = update
        , subscriptions = \_ -> ()
        }


init () =
    ( "unset", Task.perform Done (Task.andThen start (Task.succeed ())) )


update msg model =
    case msg of
        Done s ->
            ( s, Cmd.none )


start () =
    Task.andThen reportGo (Io.getenv "RF_PART_IN")


reportGo : String -> Runtime.Task x String
reportGo path =
    Task.andThen (report "PREFIX:") (Io.readFile path)


report : String -> String -> Runtime.Task x String
report prefix text =
    Task.succeed
        (prefix
            ++ String.fromInt (String.length text)
            ++ ":"
            ++ (case Str.lines text of
                    x :: _ ->
                        x

                    [] ->
                        "<none>"
               )
        )
