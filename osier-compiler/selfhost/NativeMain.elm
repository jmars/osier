module NativeMain exposing (main)

{-| M15 → P8: the node-free compiler driver — a pure `Runtime.program` Task
app that replaces `osier-compiler/run.js` for the QBE batch shape.

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
$ELMC_ROOT/osier-compiler/.  When unset or empty the corpus root is the plain
relative path `osier-compiler` (paths resolve against the process CWD
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
            --
            -- A MANIFEST PATH THAT IS NOT THERE IS A REFUSAL BY NAME, NOT A
            -- VERDICT ABOUT THE MANIFEST'S CONTENTS.  `Io.readFile` maps a
            -- failed open to "" (Rt.hostLeafReadFile's documented M6 arm), and
            -- an absent manifest is then indistinguishable from an empty one:
            -- MEASURED before this check, `--ssa M.main /tmp/d2a/nosuch-manifest.txt`
            -- -> exit 0 in 0.004 s, stdout `"elmc: manifest has no groups"`,
            -- elmc.err `err manifest has no groups` — a complaint about the
            -- file's contents for a file that does not exist.  run.js throws
            -- ENOENT at this same read, so the two lanes disagreed about
            -- whether the run was even valid.  One STAT, before the read, and
            -- the refusal names the path the caller typed.
            Task.andThen
                (\st ->
                    if st.isFile then
                        Task.andThen (runSsa entry) (Io.readFile path)

                    else
                        errLine ("manifest not found: " ++ path)
                )
                (Io.stat path)

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
            -- A MANIFEST NAMES FILES, AND A FILE THAT IS NOT THERE IS A
            -- REFUSAL BY NAME, NOT AN EMPTY COMPILE.  `Io.readFile` maps a
            -- failed open to "" (the host lane's documented M6 arm,
            -- Rt.hostLeafReadFile), so without this check the group compiles
            -- empty text and the output is the CORE's complaint about it:
            -- MEASURED, `nosuchfile.elm` -> exit 0, "elmc: wrote 1 outputs",
            -- and a 60-byte output reading `err parse error at row 1 column 1:
            -- expected keyword `module``.  run.js (the twin this driver must
            -- match) instead throws ENOENT and exits 1, so the two lanes
            -- disagreed about whether the manifest was even valid.  The
            -- existence probe is a STAT, not a read: it costs one syscall per
            -- named source and it names the FIRST missing path, which is what
            -- a reader of a 78-file selfhost manifest needs.
            --
            -- Explicit `.mid` paths are manifest sources too and are checked
            -- the same way; an `import X` whose `<dir>/X.mid` does not exist is
            -- NOT checked, because that is an Elm import, not a manifest entry
            -- (run.js's rule, mirrored in `resolveExisting`).
            --
            -- THE CORPUS ROOT IS A PREMISE OF EVERY COMPILE, SO AN ABSENT ONE
            -- IS A REFUSAL BY NAME RATHER THAN A SILENT COMPILE OF NOTHING.
            -- `corpusPaths` resolves the fixed corpus against `corpusRoot`
            -- ("osier-compiler", CWD-relative — the same convention the
            -- selfhost manifest's own source paths use, and the mirror of
            -- run.js's process-CWD resolution), and each of those reads maps a
            -- failed open to "" like every other read in this driver.  From a
            -- CWD with no sibling `osier-compiler/` the WHOLE corpus therefore
            -- compiled as empty text and the driver reported SUCCESS:
            -- MEASURED, /tmp/d2b (a real source, a real manifest, no corpus)
            -- -> exit 0 in 0.145 s, stdout `"elmc: wrote 1 outputs"`, no
            -- elmc.err, and a 60-byte output reading `err parse error at row 1
            -- column 1: expected keyword `module``.  Not one bad path but the
            -- entire corpus missing, reported as a successful run — the worst
            -- shape in this family.  The probe is a STAT of the corpus ROOT
            -- (isDir) — the path the emitter already resolves — so a present
            -- corpus refuses nothing and pays one syscall.  Checked BEFORE the
            -- manifest's sources: when the corpus is gone those relative paths
            -- are usually gone too, and the corpus is the cause, not a symptom.
            Task.andThen
                (\corpusStat ->
                    if corpusStat.isDir then
                        Task.andThen
                            (\missing ->
                                case missing of
                                    Just path ->
                                        errLine ("source not found: " ++ path)

                                    Nothing ->
                                        runSsaJobs entryKey jobs
                            )
                            (firstMissing (allSourcePaths jobs))

                    else
                        errLine ("corpus not found: " ++ corpusRoot)
                )
                (Io.stat corpusRoot)


runSsaJobs : String -> List Job -> Runtime.Task x String
runSsaJobs entryKey jobs =
    Task.andThen (ssaJobs entryKey jobs) (readAll (allElmPaths jobs))


-- Every path the manifest NAMES, Elm and .mid alike, in manifest order.
allSourcePaths : List Job -> List String
allSourcePaths jobs =
    concatMap2 (\j -> append2 j.sources j.mids) jobs


firstMissing : List String -> Runtime.Task x (Maybe String)
firstMissing paths =
    case paths of
        [] ->
            Task.succeed Nothing

        p :: rest ->
            Task.andThen
                (\st ->
                    if st.isFile then
                        firstMissing rest

                    else
                        Task.succeed (Just p)
                )
                (Io.stat p)


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


-- The runtime surface file, resolved against the SAME anchor as the corpus
-- paths; `ssaJobs` STATs it before reading it (see the guard there).
rtMidPath : String
rtMidPath =
    corpusRoot ++ "/runtime.mid"


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
    "osier-compiler"


-- A job's Elm source texts, in `allElmPaths` order (mids are NOT here — they
-- are read AFTER the import scan resolves them).
regroupElm : List Job -> List String -> List (List String)
regroupElm jobs elmTexts =
    splitAt (List.map (\j -> count j.sources) jobs) elmTexts


ssaJobs : String -> List Job -> List String -> Runtime.Task x String
ssaJobs entryKey jobs elmTexts =
    -- AN ABSENT runtime.mid IS A REFUSAL BY NAME, NOT AN EMPTY RUNTIME.
    -- `Io.readFile` maps a failed open to "" (Rt.hostLeafReadFile's documented
    -- M6 arm), and "" is a VALID runtime.mid with no defuns: `Rt.loadArm`
    -- parses it to an empty module and answers Ok.  So with the file absent the
    -- driver compiled every group against a runtime that has no seats at all
    -- and then reported SUCCESS.  MEASURED before this check, from a CWD whose
    -- `osier-compiler/` holds src/ and core-libs/ (a real, readable corpus)
    -- but no runtime.mid: exit 0 in 31.8 s, stdout `"elmc: wrote 1 outputs"`,
    -- stderr empty, NO elmc.err, and a 106-byte output reading `err qbe:
    -- rawCall to Rt.@p.surface-seat — not a defun of this program` — the
    -- CORE's complaint about the missing runtime, never the missing FILE, with
    -- `wrote 1 outputs` on top of it.  run.js (the twin this driver must
    -- match) throws ENOENT at this same read, so the two lanes disagreed about
    -- whether the run was even valid.  The probe is a STAT of the very path
    -- the read uses (`rtMidPath`), so a present runtime.mid refuses nothing
    -- and pays one syscall.
    --
    -- THE GUARD WRAPS THE WHOLE TASK, AND THAT IS NOT COSMETIC: `errLine`
    -- returns the model STRING (`"elmc: ..."`), and every stage below consumes
    -- a String as TEXT — the runtime source, the corpus, a group's Elm.  A
    -- refusal returned from INSIDE the pipeline is therefore handed to the next
    -- consumer as input: MEASURED with this guard placed on the runtime READ
    -- instead, the refusal text became the runtime source and the run ended
    -- `-- SYNTAX PROBLEM ... runtime.mid:1:1 ... 1| elmc: runtime.mid not
    -- found: ...` — the refusal still written to elmc.err, but the group
    -- compiled anyway.  At the head of `ssaJobs` the String is `runSsa`'s
    -- return value, i.e. the final model, which is what `errLine` is for.
    Task.andThen
        (\st ->
            if st.isFile then
                ssaJobsCorpus entryKey jobs elmTexts

            else
                errLine ("runtime.mid not found: " ++ rtMidPath)
        )
        (Io.stat rtMidPath)


ssaJobsCorpus : String -> List Job -> List String -> Runtime.Task x String
ssaJobsCorpus entryKey jobs elmTexts =
    readCorpus
        |> Task.andThen
            (\corpus ->
                -- M1: read the runtime surface file ONCE (the SAME anchor the
                -- corpus paths use, `rtMidPath`), load it
                -- once, and thread the record to every group — the
                -- once-per-process hoist, so the surface parse never becomes
                -- per-compileEntry-call.
                Task.andThen
                    (\rtText ->
                        -- THE ARM MUST MATCH THE FLAGS (perf word-arm-host-evals).
                        -- This driver emits the WORD arm (`wordVal = True`
                        -- below, matching run.js's default) but used to load the
                        -- runtime through `Rt.load`, which IS `loadArm False` —
                        -- the VAL splice.  So the native compiler spliced a
                        -- val-laid-out runtime into word-arm code: `Rt.recUpd`'s
                        -- val body (a 3-payload-word `mkval(14, ..)`) reached the
                        -- word-arm emitter, which correctly REFUSED it by name,
                        -- and the host lane's evals blob was val-laid-out so
                        -- `Rt.apply-at` was handed a non-closure and died with
                        -- "host: apply of a non-function value".  MEASURED: the
                        -- whole-compiler emit under this driver failed at 48 min
                        -- with exactly those two messages; the STOCK compiler
                        -- (run.js -> Main.elm -> `MidRt.loadArm flags.qbeWordVal`)
                        -- was always right, which is why every fixture and the
                        -- corpus passed while the self-hosted emit could not.
                        -- ONE ARM, ONE SOURCE OF TRUTH: this call now derives it
                        -- from the SAME `wordVal` the flag record carries, so the
                        -- two cannot drift apart again.
                        case Rt.loadArm True rtText of
                            Err msg ->
                                errLine ("runtime.mid: " ++ msg)

                            Ok rt ->
                                -- A runtime.mid THAT IS THERE BUT LOADS WITH NO
                                -- DEFUNS IS A REFUSAL TOO — the stat guard above
                                -- cannot see it, because the FILE exists.  The
                                -- empty text and a comments-only file both parse
                                -- to a module with no surface defuns, `loadArm`
                                -- answers Ok, and every group then compiles
                                -- against a runtime with no seats and reports
                                -- SUCCESS: MEASURED with the pre-guard tree
                                -- binary, BOTH variants from a complete corpus ->
                                -- exit 0 in 31.0 s / 32.0 s, stdout `"elmc: wrote
                                -- 1 outputs"`, stderr empty, NO elmc.err, and a
                                -- 115-byte output reading `err qbe: rawCall to
                                -- Rt.allocVector.surface-seat — not a defun of this
                                -- program (word-level C seats are rawCallRaw)` —
                                -- the CORE's complaint about one seat, never the
                                -- fact that the runtime has none at all.
                                --
                                -- PLACED HERE, IN THE LOAD'S `Ok` ARM, BECAUSE THIS
                                -- IS THE FINAL-MODEL SEAT (the same reason the
                                -- absent-runtime guard heads `ssaJobs`): `errLine`
                                -- returns the model STRING, and any stage that
                                -- PRODUCES text for a later stage would hand the
                                -- refusal to that consumer as input — the
                                -- measured failure mode of the first placement of
                                -- the guard above, where the refusal became the
                                -- runtime SOURCE and the group compiled anyway.
                                -- `parsedSource` is `Ok ast` on every loaded
                                -- runtime (`loadText` builds it that way) and `ast`
                                -- is exactly the surface defun list, so `Ok []` is
                                -- "loaded, zero defuns" and not a guess.
                                case rt.parsedSource of
                                    Ok [] ->
                                        errLine ("runtime.mid has no defuns: " ++ rtMidPath)

                                    _ ->
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
                    (Io.readFile rtMidPath)
            )


renderJob : Rt.Runtime -> List String -> String -> ( Job, List String ) -> Result String (List String) -> String
renderJob rt corpus entryKey ( job, elmGroup ) midResult =
    case midResult of
        Err msg ->
            "err " ++ msg

        Ok midTexts ->
            -- run.js's DEFAULT flag vector, field for field — the NATIVE twin
            -- of `run.js`'s `qbe*` flags and of `Main.toQbeFlags`, HAND-COPIED
            -- because this file is in the self-host manifest but NOT in Elm's
            -- build graph: `elm make` never type-checks it, so a shape drift
            -- here is invisible to every Elm-side gate and shows up ONLY when
            -- the compiler compiles itself (the VR3b1 lesson: a missing
            -- positional `Bool` here read the nested tuple as a Bool, and one
            -- extra parameter upstream tripped `arity > 16`).
            --
            -- THAT IS WHY THE VECTOR IS ONE RECORD NOW (`Mid.QbeModule.Flags`):
            -- a new switch is a FIELD, and a field this file forgets is a
            -- MISSING FIELD — a type error in whichever compiler builds it,
            -- never a silently shifted positional slot.
            --
            -- midGc is RETIRED at zighost Z0 (the Mid collector is the only
            -- collector): INERT, spelled True only because the field exists and
            -- the two drivers must agree on every field.  midGcYoung is the
            -- live nursery hatch.  These defaults must keep matching run.js's,
            -- or the seed the bootstrap builds stops re-emitting itself (the
            -- U2-fix-4 twin TestMain pins the collector slot's value).
            renderSsa
                (QbeModule.compileEntry rt corpus elmGroup midTexts entryKey
                    { flatten = True
                    , rep = True
                    , primDirect = True
                    , midRt = True
                    , midCons = True
                    , rtLean = True
                    , mono = True
                    -- (VR3d) THE FLIP: run.js's default is the WORD arm now
                    -- (`QBE_VALREP !== 'val'`), so this twin says True.  It is
                    -- not cosmetic — the seed is this file's own emit, and a
                    -- twin left at False would make the native compiler emit
                    -- the val arm while the stock one emits the word arm, i.e.
                    -- the .ssa fixed point would stop closing on its first run.
                    , wordVal = True
                    , consArr = True
                    , rec = True
                    , typeSpec = True
                    , midGc = True
                    , midGcYoung = True
                    , leafFree = True
                    , eqPtrFast = True
                    }
                )


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
    keywordName "import" 6 line


-- M4NICE: THE TOKEN RULE IS MIRRORED EXACTLY in run.js (`importNames` /
-- `midModuleName`): the keyword, then ONE OR MORE of the CORE's whitespace,
-- then an UPPERCASE-first name over the charset [A-Za-z0-9_.].  The separator
-- is space/`\r` only — that is the core's own whitespace (ParserFast.elm:2852
-- takes exactly space, `\n`, `\r`), and a `\n` cannot occur inside a
-- `Str.lines` line.  A TAB is therefore NOT a separator in either lane:
-- `import\tX` is not the language (the core refuses it "parse failed"), and
-- the old `startsWith "import "` + not-space/tab charset disagreed with
-- run.js's regex on exactly that class of line — inside a comment or a string
-- literal at column 0, where the file IS legal and the two lanes resolved
-- DIFFERENT `.mid` sets (MEASURED: run.js refused a legal program the native
-- lane compiled).
keywordName : String -> Int -> String -> Maybe String
keywordName kwd kwdLen s =
    if String.startsWith kwd s then
        case String.toList (String.dropLeft kwdLen s) of
            c :: rest ->
                if isSepWs c then
                    upperName (dropSepWs rest)

                else
                    Nothing

            [] ->
                Nothing

    else
        Nothing


-- run.js's `[ \r]+` VERBATIM: the separator class is space/CR and NOTHING
-- else, repeated.  A wider skip here (e.g. dropping a tab after the first
-- space) would make this lane resolve `import <SPACE><TAB>X` where run.js
-- resolves nothing — a divergence in the OTHER direction, the mirror hazard
-- this unit exists to close.
isSepWs : Char -> Bool
isSepWs c =
    c == ' ' || c == '\r'


dropSepWs : List Char -> List Char
dropSepWs chars =
    case chars of
        c :: rest ->
            if isSepWs c then
                dropSepWs rest

            else
                chars

        [] ->
            []


upperName : List Char -> Maybe String
upperName chars =
    case chars of
        c :: rest ->
            if isNameStart c then
                Just (String.fromList (c :: takeWhileName isNameChar rest))

            else
                Nothing

        [] ->
            Nothing


-- ASCII `[A-Z]` / `[A-Za-z0-9_.]` via the Prelude's `Char.isUpper` /
-- `Char.isAlphaNum` (which are `65 <= charToCode c <= 90` etc.), NOT
-- `c >= 'A'` — MEASURED: char ORDERING mislowers in the QBE core (`'A' >= 'A'`
-- evaluates FALSE), which is why every other selfhost module reaches for
-- Char.isUpper/toCode.  `Char.isUpper c` is exactly ASCII A-Z and
-- `Char.isAlphaNum c || c == '_' || c == '.'` is exactly run.js's
-- `[A-Za-z0-9_.]`.
isNameStart : Char -> Bool
isNameStart c =
    Char.isUpper c


isNameChar : Char -> Bool
isNameChar c =
    Char.isAlphaNum c || c == '_' || c == '.'


-- ASCII whitespace, the set run.js's `midTrim` strips — MIRRORED, and
-- deliberately restricted to ASCII: the exotic members of JS `\s` are not
-- stripped in either lane (such a `.mid` is refused loudly by the core).
isMidWs : Char -> Bool
isMidWs c =
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{000B}' || c == '\u{000C}'


dropMidWs : List Char -> List Char
dropMidWs chars =
    case chars of
        c :: rest ->
            if isMidWs c then
                dropMidWs rest

            else
                chars

        [] ->
            []


midTrim : String -> String
midTrim s =
    String.fromList (reverse (dropMidWs (reverse (dropMidWs (String.toList s)))))


midModuleName : String -> Maybe String
midModuleName text =
    firstModuleName (Str.lines text)


-- M4NICE: the SKIP predicate is the mirror of run.js's `midModuleName` — a
-- line is skipped after TRIMMING, so a CRLF's `\r`, a blank FIRST line and an
-- indented comment are all skipped.  It used to skip only `l == ""`, which
-- made a `\r\n`-plus-blank-line `.mid` read as headerless while run.js saw
-- `module Othername` — a reader-side DIVERGENCE (MEASURED: run.js refused
-- "declares module Othername" while this lane deferred to the core's
-- "unknown name: Mismatch.answer").  `''`/`Just` here both mean "no header"
-- exactly as run.js's `''` does; the core's own header parser skips
-- whitespace and comments the same way (RtLang/Parse.elm:1217).
firstModuleName : List String -> Maybe String
firstModuleName lines =
    case lines of
        [] ->
            Nothing

        l :: rest ->
            let
                t =
                    midTrim l
            in
            if t == "" || String.startsWith "//" t then
                firstModuleName rest

            else
                keywordName "module" 6 t


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
