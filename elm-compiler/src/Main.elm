port module Main exposing (main)

-- M1b -> M3 -> batch: orchestrate the Elm -> ZINC-csexp compiler pipeline.
--
-- Receives ALL sources via flags:
--   {corpusSourcesJson} — a JSON array of the FIXED corpus module sources
--     (Prelude + Runtime + the eight core-libs), parsed+typechecked+lowered
--     ONCE per process.
--   {groupsJson}        — a JSON array of JSON arrays: one source list per
--     fixture group (1-2 user modules each).
--   {midtier}           — the MIDDLE-TIER switch (S1, default false).  false
--     (MIDTIER=0) lowers straight from the AST via Lower.Module — the
--     byte-identity ANCHOR; true (MIDTIER=1) goes through the Mid IR
--     (Mid.FromAst -> Mid.ToZinc), which in stage 1 carries ZERO optimization
--     passes and must emit the SAME BYTES (tools/midtier-diff.sh).
--
-- THE SWITCH LIVES HERE, NOT IN Lower.Module, ON PURPOSE: the only place a
-- shared driver could dispatch from is one of the 58 sources in
-- elm-compiler/selfhost/manifest.json, and those 58 ARE the committed
-- bootstrap seed (tools/bootstrap/selfhost.csexp) — editing any of them
-- changes the seed by construction.  Main.elm is the driver (not a manifest
-- source), so MIDTIER=1 can reproduce the seed's exact bytes.
--
-- Lower.Module.compileBatch / Mid.Module.compileBatch turn the flags into ONE
-- bundle text per group (the corpus bundle entries reused across groups); the
-- corpus is paid for once, so compiling all N fixtures in this single process
-- costs ~1 corpus pass instead of N.  Emits over the `emit` port a single JSON
-- ARRAY of per-group strings (the bundle text, or "err <msg>" for that group
-- alone); run.js writes each element to its group's output .csexp.
--
-- The `modeReport` port exists so the differential can PROVE which path ran
-- (run.js subscribes only when MIDTIER_TRACE=1, and prints it to stderr): a
-- byte-identity check whose subject never engaged would otherwise pass
-- vacuously.

import Json.Decode as JD
import Json.Encode as JE
import Lower.Module as Module
import Mid.Module as MidModule
import Platform


port emit : String -> Cmd msg


port modeReport : String -> Cmd msg


type alias Flags =
    { corpusSourcesJson : String
    , groupsJson : String
    , midtier : Bool
    }


type Msg
    = Noop


main : Program Flags () Msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


init : Flags -> ( (), Cmd Msg )
init flags =
    ( (), Cmd.batch [ modeReport (pathName flags.midtier), emit (compileAll flags) ] )


pathName : Bool -> String
pathName midtier =
    if midtier then
        "mode=mid"

    else
        "mode=lower"


compileAll : Flags -> String
compileAll flags =
    case
        ( JD.decodeString (JD.list JD.string) flags.corpusSourcesJson
        , JD.decodeString (JD.list (JD.list JD.string)) flags.groupsJson
        )
    of
        ( Ok corpusSources, Ok groups ) ->
            let
                result =
                    if flags.midtier then
                        MidModule.compileBatch corpusSources groups

                    else
                        Module.compileBatch corpusSources groups
            in
            case result of
                Ok bundles ->
                    encodeStrings bundles

                Err msg ->
                    -- Corpus-level failure: every group reports the same err.
                    encodeStrings (List.map (\_ -> "err " ++ msg) groups)

        _ ->
            encodeStrings [ "err internal: bad flags" ]


encodeStrings : List String -> String
encodeStrings strings =
    JE.encode 0 (JE.list JE.string strings)
