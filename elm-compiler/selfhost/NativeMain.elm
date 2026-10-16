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
import Mid.Rt as Rt


type Msg
    = Done String


type alias Job =
    { sources : List String
    , mids : List String
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
                        manifestGo rest [] (splitJob (reverse accSrcs) (markerPath line) :: accJobs)

            else
                manifestGo rest (line :: accSrcs) accJobs


-- M3: extension classification at the READER — a source path ending `.mid`
-- is a mid-c module (per-group input, compiled by Mid.RtLang), everything
-- else an Elm source.  Mirrors run.js's `isMidPath` exactly: the two drivers
-- must split the same group the same way, or their emits diverge.
splitJob : List String -> String -> Job
splitJob paths output =
    { sources = filter (\p -> not (String.endsWith ".mid" p)) paths
    , mids = filter (String.endsWith ".mid") paths
    , output = output
    }


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
-- True, matching run.js's QBE defaults (QBE_NOFLATTEN / QBE_NOREP /
-- QBE_NOPRIMDIRECT are all UNSET on the stock emit this must reproduce
-- byte-for-byte).


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
    Task.andThen (ssaJobs entryKey jobs) (readAll (allElmPaths jobs))


-- M4: read each job's ELM sources first (their texts are needed for the
-- import scan AND for the compile); the .mid files are resolved and read
-- AFTER (see `resolveJobs`), because which .mids exist depends on the
-- imports the Elm sources declare.
allElmPaths : List Job -> List String
allElmPaths jobs =
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


-- A job's Elm source texts, in `allElmPaths` order (mids are NOT here — they
-- are read AFTER the import scan resolves them).
regroupElm : List Job -> List String -> List (List String)
regroupElm jobs elmTexts =
    splitAt (List.map (\j -> count j.sources) jobs) elmTexts


ssaJobs : String -> List Job -> List String -> Runtime.Task x String
ssaJobs entryKey jobs elmTexts =
    readCorpus
        |> Task.andThen
            (\corpus ->
                -- M1: read the runtime surface file ONCE (the SAME anchor the
                -- corpus paths use, `corpusRoot ++ "/runtime.mid"`), load it
                -- once, and thread the record to every group — the
                -- once-per-process hoist, so the surface parse never becomes
                -- per-compileEntry-call.
                Task.andThen
                    (\rtText ->
                        case Rt.load rtText of
                            Err msg ->
                                errLine ("runtime.mid: " ++ msg)

                            Ok rt ->
                                let
                                    elmGroups =
                                        regroupElm jobs elmTexts
                                in
                                -- M4: resolve each job's `.mid` IMPORTS (reader-side,
                                -- relative to the importing file), then read them plus
                                -- the explicit mids, then compile each job.
                                resolveJobs jobs elmGroups
                                    |> Task.andThen
                                        (\midResults ->
                                            writeBundles
                                                (zipJobs jobs
                                                    (zipWith (renderJob rt corpus entryKey)
                                                        (zipWith (\job elmGroup -> ( job, elmGroup )) jobs elmGroups)
                                                        midResults
                                                    )
                                                )
                                                []
                                        )
                    )
                    (Io.readFile (corpusRoot ++ "/runtime.mid"))
            )


renderJob : Rt.Runtime -> List String -> String -> ( Job, List String ) -> Result String (List String) -> String
renderJob rt corpus entryKey ( job, elmGroup ) midResult =
    case midResult of
        Err msg ->
            "err " ++ msg

        Ok midTexts ->
            -- run.js's DEFAULT flag vector, ALL ELEVEN ON (flatten, rep,
            -- primDirect, midRt inject, midCons route, rtLean lean ABI, mono
            -- specialiser, consArr, rec, typeSpec, eqPtrFast), the trailing
            -- ( midGc, midDriver ) pair = ( False, True ) (run.js's post-A5
            -- defaults).  See the pre-M4 comment for the flip's midCons note.
            renderSsa (QbeModule.compileEntry rt corpus elmGroup midTexts entryKey True True True True True True True ( ( True, ( True, True, ( False, True ) ) ), True ))


-- ======================= M4: reader-side .mid import resolution =======================
-- Mirrors run.js's resolveMidImports exactly (see run.js for the resolution
-- rule and the honest floor).  The two drivers must resolve the same group the
-- same way, or their emits diverge (the node-vs-native byte-compare is the
-- proof).  `import X` -> `<dir-of-importing-file>/X.mid`, by EXISTENCE; a
-- resolved .mid whose `module` header disagrees with the import name is LOUD.


resolveJobs : List Job -> List (List String) -> Runtime.Task x (List (Result String (List String)))
resolveJobs jobs elmGroups =
    seqMap (zipWith resolveJob jobs elmGroups)


resolveJob : Job -> List String -> Runtime.Task x (Result String (List String))
resolveJob job elmTexts =
    let
        -- (import name, resolved path) for each import whose .mid EXISTS — the
        -- existence is stat-checked below, so a missing file is never read (it
        -- is an Elm import, untouched).
        candidates =
            importedMids (zipWith (\p t -> ( p, t )) job.sources elmTexts)
    in
    resolveExisting candidates
        |> Task.andThen
            (\existing ->
                readAll (List.map (\( _, p ) -> p) existing ++ job.mids)
                    |> Task.map
                        (\texts ->
                            let
                                nImported =
                                    count existing

                                importedTexts =
                                    take nImported texts

                                explicitTexts =
                                    drop nImported texts
                            in
                            case firstHeaderMismatch existing importedTexts of
                                Just ( name, path, header ) ->
                                    Err ("import " ++ name ++ ": " ++ path ++ " declares module " ++ header ++ " (a .mid's module header must match the import name)")

                                Nothing ->
                                    Ok (importedTexts ++ explicitTexts)
                        )
            )


resolveExisting : List ( String, String ) -> Runtime.Task x (List ( String, String ))
resolveExisting candidates =
    case candidates of
        [] ->
            Task.succeed []

        ( name, path ) :: rest ->
            Task.andThen
                (\exists ->
                    Task.andThen
                        (\kept ->
                            Task.succeed
                                (if exists then
                                    ( name, path ) :: kept

                                 else
                                    kept
                                )
                        )
                        (resolveExisting rest)
                )
                (Task.map (\s -> s.isFile) (Io.stat path))


importedMids : List ( String, String ) -> List ( String, String )
importedMids pairs =
    importedMidsHelp [] pairs []


importedMidsHelp : List String -> List ( String, String ) -> List ( String, String ) -> List ( String, String )
importedMidsHelp seen pairs acc =
    case pairs of
        [] ->
            -- `acc` is built by APPEND in importNamesOf (acc ++ [ (n,p) ]), so
            -- it is ALREADY in first-import order — the old `reverse acc` here
            -- flipped it against run.js's order (masked today because
            -- userSurface key-sorts, but the first-mismatch error selection
            -- differed between the two lanes: the exact mirror hazard).
            acc

        ( path, text ) :: rest ->
            let
                ( acc1, seen1 ) =
                    importNamesOf (dirOf path) seen acc (importNames text)
            in
            importedMidsHelp seen1 rest acc1


importNamesOf : String -> List String -> List ( String, String ) -> List String -> ( List ( String, String ), List String )
importNamesOf dir seen acc names =
    case names of
        [] ->
            ( acc, seen )

        n :: rest ->
            let
                p =
                    resolveMidPath dir n
            in
            if memberPath p seen then
                importNamesOf dir seen acc rest

            else
                importNamesOf dir (p :: seen) (acc ++ [ ( n, p ) ]) rest


memberPath : String -> List String -> Bool
memberPath p seen =
    List.any (\q -> q == p) seen


importNames : String -> List String
importNames text =
    List.filterMap importNameOf (Str.lines text)


importNameOf : String -> Maybe String
importNameOf line =
    if String.startsWith "import " line then
        Just (moduleNameToken (String.dropLeft 7 line))

    else
        Nothing


midModuleName : String -> Maybe String
midModuleName text =
    firstModuleName (Str.lines text)


firstModuleName : List String -> Maybe String
firstModuleName lines =
    case lines of
        [] ->
            Nothing

        l :: rest ->
            if String.startsWith "//" l || l == "" then
                firstModuleName rest

            else if String.startsWith "module " l then
                Just (moduleNameToken (String.dropLeft 7 l))

            else
                Nothing


firstHeaderMismatch : List ( String, String ) -> List String -> Maybe ( String, String, String )
firstHeaderMismatch imported texts =
    case ( imported, texts ) of
        ( ( name, path ) :: restImported, text :: restTexts ) ->
            case midModuleName text of
                Just header ->
                    if header == name then
                        firstHeaderMismatch restImported restTexts

                    else
                        Just ( name, path, header )

                Nothing ->
                    firstHeaderMismatch restImported restTexts

        _ ->
            Nothing


dirOf : String -> String
dirOf path =
    case reverse (Str.split "/" path) of
        _ :: rest ->
            String.join "/" (reverse rest)

        [] ->
            path


resolveMidPath : String -> String -> String
resolveMidPath dir name =
    if dir == "" then
        name ++ ".mid"

    else
        dir ++ "/" ++ name ++ ".mid"


moduleNameToken : String -> String
moduleNameToken s =
    String.fromList (takeWhileName nameChar (String.toList s))


nameChar : Char -> Bool
nameChar c =
    not (c == ' ' || c == '\t' || c == '(' || c == '\n' || c == '\r')


takeWhileName : (Char -> Bool) -> List Char -> List Char
takeWhileName pred chars =
    case chars of
        c :: rest ->
            if pred c then
                c :: takeWhileName pred rest

            else
                []

        [] ->
            []


zipWith : (a -> b -> c) -> List a -> List b -> List c
zipWith f xs ys =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            f x y :: zipWith f xr yr

        _ ->
            []


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
