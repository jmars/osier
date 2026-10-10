module NativeMain exposing (main)

{-| M15 → P8: the node-free compiler driver — a pure `Runtime.program` Task
app that replaces `elm-compiler/run.js` for the QBE batch shape.

CLI:

    elmc --ssa <entryKey> <manifest>

The QBE backend batch mode: each group's output file receives QBE IL text
(.ssa) lowered from `<entryKey>`'s defun (run.js's QBE_ENTRY=<key>), or
`err <msg>`.  (The csexp shapes this driver once had — the bare manifest
compile and the single-group CLI — died with the ZINC-csexp output path at
P8, osier-delete-zinc; this is now the driver's only mode.)

The manifest is LINE-ORIENTED (no Json.Decode in the selfhost corpus): one
source path per line; each group terminated by an output marker line.
tools/qbe/qbe-selfhost.sh generates it from the gate's JSON manifest with

    jq -r '.groups[] | (.sources[] | .), "-> " + .output'

    <src1.elm>
    <src2.elm>
    -> <out1.ssa>
    <src3.elm>
    -> <out2.ssa>

(`--batch` is accepted as a no-op prefix for run.js symmetry; the manifest
argument follows it.)

The fixed corpus (Prelude, Runtime, the eight core-libs — run.js's exact
order, see corpusPaths) is compiled ONCE per process and every group compiles
against it, matching run.js's batch behavior byte for byte:
Mid.QbeModule.compileEntry is called with the same corpus texts in the same
order and the same per-group source texts in the same order, and its output
is a pure function of those inputs.

I/O discipline: stdout stays CLEAN — the driver prints the final model (a
status line) after the effect loop drains.  Per-group compile failures land
in that group's OWN output file as "err <msg>" (run.js parity, so `head -c4
| grep '^err '` checks keep working).  Usage/manifest-level failures write
`err <msg>` to `elmc.err` in the CWD.

Env contract: ELMC_ROOT = repo root; the corpus is read from
$ELMC_ROOT/elm-compiler/.  When unset or empty the corpus root is the plain
relative path `elm-compiler` (paths resolve against the process CWD
everywhere else, matching run.js).  The process arguments arrive via
Runtime.argv () (the *argv* pseudo-global the driver installs — run.js
argv[2:] shape: the binary path is NOT an element).
-}

import Mid.QbeModule as QbeModule


type Msg
    = Done String


type alias Job =
    { sources : List String
    , output : String
    }


main =
    Runtime.program
        { init = init
        , update = update
        , subscriptions = \_ -> ()
        }


init () =
    ( "elmc: starting"
    , Task.perform Done (Task.andThen start (Task.succeed ()))
    )


update msg model =
    case msg of
        Done status ->
            ( status, Cmd.none )


-- ============================ entry ============================


start () =
    case parseArgs (stripFlags (Runtime.argv ())) of
        Err msg ->
            errLine msg

        Ok [] ->
            errLine "usage: elmc --ssa <entry> <manifest>"

        Ok ("--ssa" :: entry :: path :: []) ->
            -- .ssa batch mode: drive the QBE backend (Mid.QbeModule.compileEntry)
            -- and write QBE IL per group.  `entry` is the defun key the
            -- lowering roots reachability from (run.js's QBE_ENTRY).
            Task.andThen (runSsa entry) (Io.readFile path)

        Ok _ ->
            errLine "usage: elmc --ssa <entry> <manifest>"


-- run.js accepts `--batch <manifest>`; keep the spelling working.
stripFlags : List String -> List String
stripFlags argv_ =
    case argv_ of
        "--batch" :: rest ->
            stripFlags rest

        arg :: rest ->
            arg :: stripFlags rest

        [] ->
            []


parseArgs : List String -> Result String (List String)
parseArgs argv_ =
    Ok argv_


-- ======================= manifest -> jobs =======================
-- One job per "-> <out>" line; the lines above it (since the previous marker
-- or the start) are that job's sources, in file order.  Blank lines and
-- lines between a marker and the next source are skipped.


manifestJobs : List String -> Result String (List Job)
manifestJobs lines =
    manifestGo lines [] []


manifestGo : List String -> List String -> List Job -> Result String (List Job)
manifestGo lines accSrcs accJobs =
    case lines of
        [] ->
            case accSrcs of
                [] ->
                    Ok (reverse accJobs)

                _ ->
                    Err "manifest ends with sources but no '-> output' line"

        line :: rest ->
            if line == "" then
                manifestGo rest accSrcs accJobs

            else if isMarker line then
                case accSrcs of
                    [] ->
                        Err ("manifest output marker with no sources: " ++ line)

                    _ ->
                        manifestGo rest [] ({ sources = reverse accSrcs, output = markerPath line } :: accJobs)

            else
                manifestGo rest (line :: accSrcs) accJobs


isMarker : String -> Bool
isMarker line =
    String.startsWith "-> " line


markerPath : String -> String
markerPath line =
    String.dropLeft 3 line


reverse : List a -> List a
reverse xs =
    revGo xs []


revGo : List a -> List a -> List a
revGo xs acc =
    case xs of
        x :: rest ->
            revGo rest (x :: acc)

        [] ->
            acc


-- ======================= the .ssa pipeline =======================
-- `elmc --ssa <entry> <manifest>` drives the QBE backend (Mid.QbeModule):
-- read the corpus ONCE, then compile each group against it and write QBE IL
-- (.ssa) — or "err <msg>" — to that group's output path.  flatten/rep are
-- True, matching run.js's QBE defaults (QBE_NOFLATTEN / QBE_NOREP are both
-- UNSET on the stock emit this must reproduce byte-for-byte).


runSsa : String -> String -> Runtime.Task x String
runSsa entryKey text =
    case manifestJobs (Str.lines text) of
        Err msg ->
            errLine msg

        Ok [] ->
            errLine "manifest has no groups"

        Ok jobs ->
            runSsaJobs entryKey jobs


runSsaJobs : String -> List Job -> Runtime.Task x String
runSsaJobs entryKey jobs =
    Task.andThen (ssaJobs entryKey jobs) (readAll (allSources jobs))


allSources : List Job -> List String
allSources jobs =
    concatMap2 .sources jobs


readAll paths =
    seqMap (List.map Io.readFile paths)


readCorpus =
    seqMap (List.map Io.readFile corpusPaths)


corpusPaths : List String
corpusPaths =
    List.map (\p -> corpusRoot ++ "/" ++ p)
        ([ "src/Prelude.elm", "src/Runtime.elm" ]
            ++ List.map (\f -> "core-libs/" ++ f) coreLibs
        )


coreLibs : List String
coreLibs =
    [ "Dict.elm", "Set.elm", "Maybe.elm", "Result.elm"
    , "Tuple.elm", "JsArray.elm", "Array.elm", "Str.elm"
    ]


corpusRoot : String
corpusRoot =
    "elm-compiler"


regroup : List Job -> List String -> List (List String)
regroup jobs texts =
    splitAt (List.map (\j -> count (j.sources)) jobs) texts


ssaJobs : String -> List Job -> List String -> Runtime.Task x String
ssaJobs entryKey jobs texts =
    readCorpus
        |> Task.andThen
            (\corpus ->
                writeBundles
                    (zipJobs jobs
                        (List.map2
                            (\job srcs -> renderSsa (QbeModule.compileEntry corpus srcs entryKey True True))
                            jobs
                            (regroup jobs texts)
                        )
                    )
                    []
            )


renderSsa : Result String String -> String
renderSsa result =
    case result of
        Ok ssa ->
            ssa

        Err msg ->
            "err " ++ msg


writeBundles : List ( Job, String ) -> List String -> Runtime.Task x String
writeBundles pairs done =
    case pairs of
        [] ->
            Task.succeed ("elmc: wrote " ++ String.fromInt (count done) ++ " outputs")

        ( job, bundle ) :: rest ->
            Task.andThen
                (\_ -> writeBundles rest (job.output :: done))
                (Io.writeFile job.output bundle)


zipJobs : List Job -> List String -> List ( Job, String )
zipJobs jobs bundles =
    case jobs of
        [] ->
            []

        j :: jrest ->
            case bundles of
                b :: brest ->
                    ( j, b ) :: zipJobs jrest brest

                [] ->
                    []


-- ======================= tiny List helpers =======================
-- (Prelude's map/filter/... are in scope unqualified, but `length`/`concat`
-- spellings differ from elm/core; local helpers keep this self-contained.)


seqMap tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            Task.andThen (\v -> Task.andThen (\vs -> Task.succeed (v :: vs)) (seqMap rest)) t


concatMap2 : (a -> List b) -> List a -> List b
concatMap2 f xs =
    case xs of
        [] ->
            []

        x :: rest ->
            append2 (f x) (concatMap2 f rest)


append2 : List a -> List a -> List a
append2 xs ys =
    case xs of
        x :: rest ->
            x :: append2 rest ys

        [] ->
            ys


splitAt : List Int -> List a -> List (List a)
splitAt ns xs =
    case ns of
        [] ->
            []

        n :: rest ->
            take n xs :: splitAt rest (drop n xs)


count : List a -> Int
count xs =
    case xs of
        _ :: rest ->
            1 + count rest

        [] ->
            0


take : Int -> List a -> List a
take n xs =
    if n <= 0 then
        []

    else
        case xs of
            x :: rest ->
                x :: take (n - 1) rest

            [] ->
                []


drop : Int -> List a -> List a
drop n xs =
    if n <= 0 then
        xs

    else
        case xs of
            _ :: rest ->
                drop (n - 1) rest

            [] ->
                []


errLine : String -> Runtime.Task x String
errLine msg =
    Task.andThen (\_ -> Task.succeed ("elmc: " ++ msg)) (Io.writeFile "elmc.err" ("err " ++ msg ++ "\n"))
