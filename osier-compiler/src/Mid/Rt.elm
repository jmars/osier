module Mid.Rt
    exposing
        ( Impl
        , ParsedUserModule
        , Runtime
        , UserModule
        , checkLowerUserModule
        , load
        , loadArm
        , parseUserModule
        , closureSeeds
        , conSeeds
        , driverSeeds
        , lowerSeatSeeds
        , gcSeeds
        , youngGcSeeds
        , hostSeeds
        , primImpl
        , activeSurf
        , rawAbi
        , rawAbiArity
        , rtDeps
        , seeds
        , spliceArm
        , spliceSurface
        )

-- Mid.Rt — the MID-WRITTEN RUNTIME's program assembly (handoff
-- osier-consspike, TRACK 2 step 4).
--
-- The runtime is COMPILER-INTERNAL defuns under the reserved `Rt.*` key
-- namespace, built here from the bodies in Mid.RtPrims and injected into the
-- compile by Mid.QbeModule AFTER Flatten (whose rewriter rightly rejects raw
-- nodes — Rt code is already final) and BEFORE Mid.Qbe.Lower.  This module
-- is the ONE place that knows which Rt defun implements which surface prim
-- (`primImpl`) and which Rt keys a used prim transitively needs (`seeds`) —
-- the seed list exists because `RawCall` crosses the Mid-level call graph as
-- an opaque symbol, invisible to Lower's GRef reachability walk (Mid.Ir's
-- header records the caveat); the builder that issued the calls is the only
-- side that can close the dependency.
--
-- BACKEND-NEUTRAL BY CONSTRUCTION: this module and Mid.RtPrims import only
-- Mid.Ir — a Lua backend consumes the SAME defuns through its own lowering.
-- (Since T7 this module ALSO imports the Mid.RtLang.* surface front end,
-- which is backend-neutral by the same contract: Ast/Parse/Check read only
-- Ast + the vendored ParserFast (already in the seed — it is the front end's
-- own parser) and LowerToIr reads only Mid.Ir.  Since M1 the surface TEXT
-- arrives as `load`'s argument — read from osier-compiler/runtime.mid by the
-- driver, never from a compiled-in blob.)
-- The seeding contract travels with them: seed exactly the used prims' keys,
-- so a program that never conses never carries the cons machinery (the
-- pruning a committed runtime blob could not offer).
--
-- THE `Rt` MODULE NAME IS RESERVED: a surface module actually named `Rt`
-- would emit keys under this same prefix and slip past Mid.Audit's
-- namespace test — Mid.QbeModule rejects it loudly at collect time (the
-- residual hole osier-rawnodes recorded for this step to close).

import Dict exposing (Dict)
import Mid.Ir exposing (Defun, Exp(..), LetBinder(..), Lit(..), Match, UnsafeNode(..), ValuePath(..))
import Mid.RtGc exposing (gcProgram)
import Mid.RtLang.Ast as RtAst
import Mid.RtLang.Check as RtCheck
import Mid.RtLang.LowerToIr
import Mid.RtLang.Parse
import Mid.RtPrims exposing (helperDefuns, primDefuns)
import Set exposing (Set)


{-| The once-per-process LOAD of the runtime surface text — the record every
compile path threads through `QbeModule.compileEntry` -> `Lower`.  `load` is
the ONLY entry to the surface-derived tables: the old top-level exports
(`program`/`programPair`/`programGc`/`surf`/`externTypes` (M2, was
`externArities`)/`allocating`/`direct`) are now FIELDS of this record, computed over the text handed to
`load`, so a call site that still reaches for one is a compile error, never
a silent stale read.

THE ONCE-PER-PROCESS CONTRACT (plan R1, THE RE-PARSE WALL): the text is
PARSED ONCE, here, and the parse result is closed over by every field.
`surf` (check+lower, flag-dependent) re-runs per `program` call — twice per
compile (QbeModule's injection and `allocating`'s fixed point), exactly as
before the move — but the PARSE never re-runs.  The oracle is the corpus
wall clock: it must stay ~16 s-class (it was 705 s when the parse was
O(n^2)-per-call).

`load` fails (Err) exactly when the text does not parse — every compile
fails loudly on a bad surface text, the same behaviour the old top-level
`parsedSource` Result gave through `program`.
-}
type alias Runtime =
    { parsedSource : Result String RtAst.Program
    , header : RtAst.Header
    , surf : List RtAst.Flag -> Result String (Dict String Defun)
    , program : Bool -> Bool -> Bool -> Result String (List Defun)
    , programGc : Bool -> Bool -> Bool -> Result String (List Defun)
    , programPair : Bool -> Bool -> Bool -> Result String ( List Defun, List Defun )
    , externTypes : Dict String RtAst.ExportSig
    , exportedTypes : Dict String RtAst.ExportSig
    , allocating : Set String
    , direct : Defun -> Bool
    , abi : Dict String (List Int)
    , hosted : Bool
    }


{-| B6 — THE ABI CLASS TABLE (plan Q7): the keys that lower with the WORD ABI,
each mapped to its PER-PARAMETER word widths (1 for a `word`/`int`/`bool`/`*T`
parameter, the struct's word size for a struct VALUE parameter — the width is
what the callee's entry copy spills).  A key ABSENT from this dict takes the
value ABI (`:val`/lean), which is every key that was value-ABI before B6, so
absence is the safe default.

THE RULE IS THE SIGNATURE (`RtAst.allWordSig`), not a hand list — with ONE
merge: `rawAbi` keys are INSERTED even when their signature classifies
value-ABI.  That is not a safety net, it is load-bearing and MEASURED: four of
the thirteen raw-word keys (`Rt.apply`, `Rt.apply-tail`, `Rt.tail-known`,
`Rt.bounce`) RETURN an aggregate `:val`/`:ret` through sret, so the signature
rule alone would move them to the value ABI and move the corpus with them.
The other nine are exactly the all-word signatures runtime.mid has.

The widths come from the CHECKER's ONE layout table (`Check.sizeofStruct`) —
no second size rule exists.
-}
abiTable : List RtAst.Decl -> RtAst.Program -> Dict String (List Int)
abiTable decls defuns =
    let
        bySignature =
            List.foldl
                (\d acc ->
                    if RtAst.allWordSig (List.map .ty d.params) d.ret then
                        Dict.insert d.key (List.map (paramWords decls) d.params) acc

                    else
                        acc
                )
                Dict.empty
                defuns
    in
    Set.foldl
        (\key acc ->
            if Dict.member key acc then
                acc

            else
                -- the OVERRIDE: a declared raw-word key keeps the word ABI
                -- whatever its declared RESULT class says.  The arity record
                -- is the width source here (every rawAbi key has one; a
                -- missing entry would be a compile Err at lowerDefun, never a
                -- silent 0-width).
                Dict.insert key
                    (List.repeat (Maybe.withDefault 0 (Dict.get key rawAbiArity)) 1)
                    acc
        )
        bySignature
        rawAbi


{-| One parameter's width in WORDS: a struct VALUE is its layout size (the
same `sizeof(S)` the checker computes), everything else is one word.
-}
paramWords : List RtAst.Decl -> RtAst.Param -> Int
paramWords decls p =
    case p.ty of
        RtAst.TStruct sname ->
            Maybe.withDefault 1 (RtCheck.sizeofStruct decls sname)

        _ ->
            1


{-| (perf VR3c) The arm splice itself: keep one region kind, drop the other,
drop every marker line, and refuse a malformed file loudly.  See `loadArm`.
-}
spliceArm : Bool -> String -> Result String String
spliceArm wordVal source =
    let
        beginVal =
            "// >>> QBE_VAL-ONLY"

        endVal =
            "// <<< QBE_VAL-ONLY"

        beginWord =
            "// >>> QBE_WORDVAL-ONLY"

        endWord =
            "// <<< QBE_WORDVAL-ONLY"

        -- 0 = outside every region, 1 = inside QBE_VAL-ONLY, 2 = inside
        -- QBE_WORDVAL-ONLY.
        kept : Int -> Bool
        kept region =
            (region == 1 && not wordVal) || (region == 2 && wordVal)

        go : List String -> Int -> Int -> Int -> Int -> Int -> List String -> Result String (List String)
        go lines region beganVal endedVal beganWord endedWord acc =
            case lines of
                [] ->
                    if region /= 0 then
                        Err "runtime.mid: an arm-splice region is UNTERMINATED — refusing to compile a half-spliced runtime"

                    else if beganVal /= endedVal || beganWord /= endedWord then
                        Err "runtime.mid: the arm-splice regions are UNBALANCED (a begin without its end, or the reverse) — refusing to compile a half-spliced runtime"

                    else
                        Ok (List.reverse acc)

                line :: rest ->
                    if startsAt beginVal line then
                        go rest 1 (beganVal + 1) endedVal beganWord endedWord acc

                    else if startsAt beginWord line then
                        go rest 2 beganVal endedVal (beganWord + 1) endedWord acc

                    else if startsAt endVal line then
                        go rest 0 beganVal (endedVal + 1) beganWord endedWord acc

                    else if startsAt endWord line then
                        go rest 0 beganVal endedVal beganWord (endedWord + 1) acc

                    else if region == 0 || kept region then
                        go rest region beganVal endedVal beganWord endedWord (line :: acc)

                    else
                        go rest region beganVal endedVal beganWord endedWord acc

        -- a marker is a line whose FIRST NON-SPACE text is the marker (the
        -- regions sit inside indented blocks, so leading whitespace is
        -- expected; a marker anywhere else in a line is prose and is left
        -- alone).
        startsAt : String -> String -> Bool
        startsAt marker line =
            if String.startsWith " " line then
                startsAt marker (String.dropLeft 1 line)

            else if String.startsWith "\t" line then
                startsAt marker (String.dropLeft 1 line)

            else
                String.startsWith marker line
    in
    Result.map (String.join "\n") (go (splitLines source) 0 0 0 0 0 [])


{-| `String.split` is NOT in this language's String surface (MEASURED: the
self-host front end rejects it — Mid.RtLang.Parse's `firstSegment` note), and
this module IS compiled by that front end, so the line split is spelled here
with the two prims that do exist (`String.slice`, `String.length`).
-}
splitLines : String -> List String
splitLines s =
    let
        go : Int -> Int -> List String -> List String
        go start i acc =
            if i >= String.length s then
                List.reverse (String.slice start i s :: acc)

            else if String.slice i (i + 1) s == "\n" then
                go (i + 1) (i + 1) (String.slice start i s :: acc)

            else
                go start (i + 1) acc
    in
    go 0 0 []


load : String -> Result String Runtime
load =
    loadArm False


{-| (perf VR3c) THE ARM SPLICE — `loadArm wordVal text` selects the runtime
TEXT for the representation arm before it is parsed.

WHY A TEXT SPLICE AND NOT A FLAG THREADED THROUGH EVERY DEFUN.  `runtime.mid`
is the Mid SURFACE source: its strides are written as arithmetic (`40 * nslots`,
`2 + (countW + 4 * countW * kindW)`, `iW * 48`), so the two arms cannot share a
body — the val arm's numbers are 40-byte Values and the word arm's are 8-byte
words, and a body that tried to serve both would need a layout VALUE in the
surface language, which it does not have.  So each stride site carries BOTH
spellings, side by side, in two marker-delimited regions:

    // >>> QBE_VAL-ONLY      ..  // <<< QBE_VAL-ONLY       (kept on the val arm)
    // >>> QBE_WORDVAL-ONLY  ..  // <<< QBE_WORDVAL-ONLY   (kept on the word arm)

and this function keeps one and DROPS the other — the same splice discipline
`run.js` already applies to the nursery's `QBE_MIDGC_YOUNG-ONLY` region (that
one is a BUILD flag and stays in the driver; this one is the per-compile
`QBE_VALREP` knob, which is why it lives here, where `Mid.QbeModule`'s flags
already reach the parse).

THE VAL ARM'S TEXT IS UNCHANGED BY CONSTRUCTION.  The marker lines themselves
are dropped in BOTH arms and a region's body is kept only for its own arm, so
`loadArm False` yields the byte-for-byte text the tree had before the twins
existed — which is what keeps the val arm's emitted IL (and therefore the
corpus baseline) inert.  THE RULE THAT KEEPS IT TRUE (perf VR3c, after review):
a twin's PROSE belongs INSIDE its own region, and a twin never re-indents a
line that the other arm keeps.  Both were violated once and are what the
"byte-for-byte" claim costs: a lead comment sitting between the two regions
survives into the val text, and a line-wise edit that re-indents a live val line
makes the val text merely PARSE-identical (comments are emit-inert, so the
emitted IL was byte-identical even then — but the claim in this comment would
have been false as stated, and a doc that overclaims is the thing this repo
keeps paying for).  Checked by diffing `spliceArm False`'s output against the
pre-VR3c `runtime.mid`; it is byte-identical.

A region that is unterminated or unbalanced is a LOUD refusal: a half-spliced
runtime would link cleanly and read the wrong bytes.  The marker text and the
die messages inside the regions must also be ASCII — the surface language
rejects a non-ASCII byte in a string literal, which is how a twin that would
have compiled on one arm only is caught at the parse instead of at run time.
-}
loadArm : Bool -> String -> Result String Runtime
loadArm wordVal source =
    case spliceArm wordVal source of
        Err msg ->
            Err msg

        Ok text ->
            loadText text


-- the parse half of `loadArm`, unchanged: the hoisted per-process parse.
loadText : String -> Result String Runtime
loadText source =
    case Mid.RtLang.Parse.parseModule source of
        Err msg ->
            Err msg

        Ok module_ ->
            let
                -- the defun list (the header rides beside it, never lowered).
                ast =
                    module_.defuns

                header =
                    module_.header

                -- the surface AST's declared arities: (key, param count) per
                -- defun, guard variants included (they share one key and never
                -- differ in arity — TestMain's T7 flag-stable row pins that).
                surfaceSigs =
                    List.map (\d -> ( d.key, List.length d.params )) ast

                -- the module's key -> arity map (surface defuns UNION DSL
                -- seats) — the key agreement's known set AND the typed table's
                -- arity-only fallback source.  The DSL entries come LAST in the
                -- `fromList` fold, so for a key defined on BOTH sides the DSL
                -- arity wins (a drift is a TestMain FAIL).
                moduleArities =
                    Dict.fromList
                        (surfaceSigs
                            ++ List.map (\d -> ( d.key, lamArity d ))
                                (primDefuns True True True ++ helperDefuns True ++ gcProgram)
                        )

                -- the export block, keyed — the typed extern table's declared
                -- half (M2, plan.md §2.5).  Nothing in M2 CONSUMES a declared
                -- Osier type beyond J2's projection (Check.project) — the table
                -- is emit-inert otherwise.  `exportedTypes` below is this same
                -- dict, exposed as a record field: it is the PRIVACY BOUNDARY
                -- for the USER lane (M3fix) — a user `.mid` may `call` only the
                -- runtime's EXPORTED keys (unexported defuns are module-private,
                -- per the runtime.mid header), never the whole `externTypes`.
                exportedSigs =
                    Dict.fromList (List.map (\e -> ( e.key, e.sig )) header.exports)

                -- THE TYPED EXTERN TABLE (M2): every module key maps to an
                -- `ExportSig`.  An EXPORTED key carries its DECLARED signature
                -- (params + result in Osier type syntax, plus the `!io`/taint
                -- markers); an unexported key carries the arity-only fallback
                -- `val -> .. -> val` (today's all-`:val` extern seat, spelled
                -- as a type).  J2 uses the declared types where they exist and
                -- falls back to arity-only where they do not — exactly the
                -- brief's contract.
                externTypes =
                    Dict.map
                        (\key arity ->
                            case Dict.get key exportedSigs of
                                Just sig ->
                                    sig

                                Nothing ->
                                    { ty = RtAst.valArity arity
                                    , effects = []
                                    , taint = False
                                    }
                        )
                        moduleArities

                -- the ACTIVE surface defuns for one flag combo, keyed for the
                -- splice.  Parse is the per-process `ast` above; check and
                -- lower run here (flag-dependent).  DECL-CARRYING (midlang-u5):
                -- `lowerModule` threads the file's `struct`/`enum` decls into the
                -- lowering state, which the field/index arms read — without them
                -- runtime.mid's `region->f` accesses cannot lower at all.  For a
                -- decl-less module the two entries are the same function
                -- (`lowerAll decls [] defuns`, decls = []).
                surf flags =
                    case RtCheck.checkModule externTypes flags module_ of
                        Err msg ->
                            Err msg

                        Ok () ->
                            case Mid.RtLang.LowerToIr.lowerModule module_ of
                                Err msg ->
                                    Err msg

                                Ok lowered ->
                                    Ok (activeSurf flags (List.map2 Tuple.pair ast lowered))

                -- THE WHOLE SPLICE (T18): ONE `surf` evaluation per call (the
                -- compile path runs this twice per compile — QbeModule's
                -- injection and `allocating`'s fixed point — exactly as before
                -- the move), spliced over the UNION of the three DSL lists and
                -- split back into the two halves the injection consumes.  The
                -- split is `List.partition` by the gc key set — MEASURED STABLE
                -- (elm/core 1.0.5: foldr + cons, original order preserved on
                -- both sides), which keeps the gc half in `gcProgram`'s exact
                -- list order (order is .ssa bytes).  No gc key exists outside
                -- `gcProgram` and no prim/helper key inside it.  T25: an
                -- APPENDED key is never in `gcKeys`, so every appended defun
                -- lands at the END of the prim half and `programGc`'s output is
                -- byte-identical to the pre-T25 gc half.
                programPair consArr rec eqPtrFast =
                    let
                        gcKeys =
                            Set.fromList (List.map .key gcProgram)
                    in
                    surf (activeFlags consArr rec eqPtrFast)
                        |> Result.andThen
                            (\surface ->
                                spliceSurface surface
                                    (primDefuns consArr rec eqPtrFast
                                        ++ helperDefuns rec
                                        ++ gcProgram
                                    )
                            )
                        |> Result.map
                            (\spliced ->
                                let
                                    ( gcHalf, primHalf ) =
                                        List.partition (\d -> Set.member d.key gcKeys) spliced
                                in
                                ( primHalf, gcHalf )
                            )

                -- the PRIM/HELPER half of the splice (the same list `program`
                -- always returned).
                program consArr rec eqPtrFast =
                    Result.map Tuple.first (programPair consArr rec eqPtrFast)

                -- the GC half of the splice (T18): `gcProgram` with any
                -- surface-migrated collector defuns replaced at their list
                -- positions.  Emitted by QbeModule only under QBE_MIDGC=1.
                programGc consArr rec eqPtrFast =
                    Result.map Tuple.second (programPair consArr rec eqPtrFast)

                -- the Rt defuns whose execution can reach a GC SAFEPOINT (the
                -- lean ABI's frame decision; see the walkers below).  Computed
                -- over the default program (consArr/rec/eqPtrFast = True — the
                -- cons representation and the eq fast path do not change which
                -- defuns allocate) and the `direct` walker + the `rtDeps` fixed
                -- point.  T18: the gc half is the SPLICED half (the surface
                -- bodies are the live trees).
                allocating =
                    let
                        rtProgram =
                            case programPair True True True of
                                Ok ( primHalf, gcHalf ) ->
                                    primHalf ++ gcHalf

                                Err _ ->
                                    -- UNREACHABLE on a live compile (T7):
                                    -- `programPair`'s Err aborts the compile in
                                    -- Mid.QbeModule's injection before Lower/
                                    -- classification could read this set.
                                    []

                        -- same hoist as keepRtDependencies': the fold step
                        -- runs 226 defuns x the fixed-point passes, and every
                        -- one of those references would rebuild the Dict.
                        deps1 =
                            rtDeps

                        -- fixed point: k allocates iff k has a DIRECT
                        -- safepoint or any rtDeps edge of k lands in the set.
                        grow : Set String -> Set String
                        grow acc =
                            let
                                new =
                                    List.foldl
                                        (\d set ->
                                            case Dict.get d.key deps1 of
                                                Just deps ->
                                                    if List.any (\dep -> Set.member dep set) deps then
                                                        Set.insert d.key set

                                                    else
                                                        set

                                                Nothing ->
                                                    set
                                        )
                                        acc
                                        rtProgram
                            in
                            if Set.size new == Set.size acc then
                                acc

                            else
                                grow new
                    in
                    grow (Set.fromList (List.filter direct rtProgram |> List.map .key))
            in
            case RtCheck.checkExports header.exports moduleArities of
                Err msg ->
                    Err msg

                Ok () ->
                    Ok
                        { parsedSource = Ok ast
                        , header = header
                        , surf = surf
                        , program = program
                        , programGc = programGc
                        , programPair = programPair
                        , externTypes = externTypes
                        , exportedTypes = exportedSigs
                        , allocating = allocating
                        , direct = direct
                        , abi = abiTable module_.decls ast
                        , hosted = List.any (\d -> d.key == "Rt.hostRun") ast
                        }


-- ============================ USER .mid modules (M3) ============================


{-| One user `.mid` module, checked and lowered (M3).  `name` is the module
header's name — the namespace every key is qualified by; `exports` the
export block (the declared types M4 checks against); `defuns` the
LOWERED Mid.Ir defuns, keyed `<name>.<fn>`, ready to be appended to the
program by the caller (QbeModule) through the SAME splice path the
runtime uses (T25's ADD arm — a user key has no DSL position).  `abi` is the
module's B6 word-ABI table (`abiTable` over the module's own decls + defuns):
the caller unions it into the runtime's, so a user defun with an all-word
signature lowers with the word ABI — which is what makes a `.mid` able to
write the collector's word helpers.
-}
type alias UserModule =
    { name : String
    , exports : List RtAst.Export
    , defuns : List Defun
    , abi : Dict String (List Int)
    }


{-| A PARSED (not yet checked/lowered) user `.mid`: the namespace-qualified
name, the export block, the file-scoped `struct`/`enum` decls, and the defun
AST.  A RECORD rather than a tuple (A2: Elm caps tuples at 3) so the DECLS
ride through — before A2 the parse result was a `(name, exports, ast)`
3-tuple that silently DROPPED `module_.decls`, so a user `.mid` carrying a
`struct` declaration parsed it into nothing before the checker.
-}
type alias ParsedUserModule =
    { name : String
    , exports : List RtAst.Export
    , decls : List RtAst.Decl
    , ast : RtAst.Program
    }


{-| Parse a USER `.mid` module and enforce the NAMESPACE RULE (the module
NAME from the header qualifies every key): a user module must carry a
`module Name` header, and every defun/export key must be spelled
`Name.<fn>`.  The `Rt.*`-only shape check lives in `Check.keyCheck`
(generalized M3); THIS is the ownership half — the prefix must be the
module's OWN name, so two modules can never silently share a key through
a typo'd prefix.  Returns the parsed name/exports/DECLS/ast for the caller to
build the cross-module extern table before the check+lower pass.
-}
parseUserModule : String -> Result String ParsedUserModule
parseUserModule source =
    case Mid.RtLang.Parse.parseModule source of
        Err msg ->
            Err msg

        Ok module_ ->
            case module_.header.name of
                Nothing ->
                    Err "user .mid: no `module Name` header — a user module needs a namespace to qualify its keys"

                Just name ->
                    case firstKeyNotPrefixed name (List.map .key module_.defuns) of
                        Just bad ->
                            Err (namespaceError name bad)

                        Nothing ->
                            case firstKeyNotPrefixed name (List.map .key module_.header.exports) of
                                Just bad ->
                                    Err (namespaceError name bad)

                                Nothing ->
                                    -- A2: the file-scoped `struct`/`enum`
                                    -- decls ride out WITH the name/exports/ast
                                    -- — the user lane used to drop them here, so
                                    -- a user `.mid` that declared a struct
                                    -- parsed it into nothing before the checker.
                                    Ok
                                        { name = name
                                        , exports = module_.header.exports
                                        , decls = module_.decls
                                        , ast = module_.defuns
                                        }


{-| Check + lower a PARSED user module against the given extern table — the
SAME decl-carrying pipeline as `runtime.mid` (`Check.checkExports` ->
`Check.checkModule` -> `LowerToIr.lowerModule`; A2 fixed this — the user lane
used to call the DECL-LESS `checkProgram`/`lowerProgram`, so a user `.mid`
carrying `struct`/`enum` declarations had them dropped), with the runtime's
own `surf` path.  `externs`
is the typed extern table the module's `call` sites resolve against: the
caller (QbeModule) supplies the runtime's EXPORTED keys (`exportedTypes` — the
M3fix privacy boundary) UNION every group user module's exports, so a user
module may `call Rt.<exported>` or another user module's exported defun at the
CHECKER (J2).  Flags are `[]`: user modules carry no `@flag` guards (those are
the runtime's internal switches).
-}
checkLowerUserModule : Dict String RtAst.ExportSig -> ParsedUserModule -> Result String UserModule
checkLowerUserModule externs parsed =
    let
        arities =
            Dict.fromList (List.map (\d -> ( d.key, List.length d.params )) parsed.ast)

        -- A2: a decl-carrying MODULE record — the SAME `Check.checkModule`
        -- the runtime lane uses, so a user `.mid`'s struct/enum decls reach
        -- the checker (J11/J14) and the lowerer (the field/index table).
        module_ =
            { header = { name = Just parsed.name, exports = parsed.exports }
            , decls = parsed.decls
            , defuns = parsed.ast
            }
    in
    RtCheck.checkExports parsed.exports arities
        |> Result.andThen (\_ -> RtCheck.checkModule externs [] module_)
        |> Result.andThen (\_ -> Mid.RtLang.LowerToIr.lowerModule module_)
        |> Result.map
            (\defuns ->
                { name = parsed.name
                , exports = parsed.exports
                , defuns = defuns
                , abi = abiTable parsed.decls parsed.ast
                }
            )


{-| The first key in the list that is NOT qualified by `name` (i.e. does
not start with `name ++ "."`).  `Nothing` = every key is `name.<fn>`.
`String.startsWith (name ++ ".")` rather than `String.startsWith name`:
`Foo` must not silently own `Foobar.baz`.
-}
firstKeyNotPrefixed : String -> List String -> Maybe String
firstKeyNotPrefixed name keys =
    case keys of
        [] ->
            Nothing

        k :: rest ->
            if String.startsWith (name ++ ".") k then
                firstKeyNotPrefixed name rest

            else
                Just k


namespaceError : String -> String -> String
namespaceError name bad =
    "user .mid: module '"
        ++ name
        ++ "' — key '"
        ++ bad
        ++ "' is not qualified by the module name (every defun/export key must be '"
        ++ name
        ++ ".<fn>')"


{-| The three `program` switches as the surface language's ACTIVE flag set
(the `@flag`/`@!flag` guards hold against exactly this list; a False flag
is simply absent).  The measured variation is 4 defuns — cons/atp/eq/
deepEq — plus `helperDefuns`' rec emission.
-}
activeFlags : Bool -> Bool -> Bool -> List RtAst.Flag
activeFlags consArr rec eqPtrFast =
    (if consArr then
        [ RtAst.ConsArr ]

     else
        []
    )
        ++ (if rec then
                [ RtAst.Rec ]

            else
                []
           )
        ++ (if eqPtrFast then
                [ RtAst.EqPtrFast ]

            else
                []
           )


{-| The arity of a DSL-built defun (the Lam param count) — `load`'s
`moduleArities` (the typed extern table's fallback) reads it for the DSL half.
-}
lamArity : Defun -> Int
lamArity d =
    case d.value of
        Lam l ->
            List.length l.params

        _ ->
            0


{-| The ACTIVE surface defuns for one flag combo, keyed for the splice.
`ast` and `lowered` are paired POSITIONALLY, not keyed: guard variants
SHARE one key, so a key-keyed dict of the lowered list would be last-wins
and could fetch an INACTIVE variant's tree under a flag combo whose active
variant is not last in source order.  The pairing relies on
`lowerProgram` preserving the input order and count 1:1 (its `lowerAll`
walks the program defun by defun and reverses its accumulator).  Only
ACTIVE variants enter the dict — the checker has already guaranteed at
most one active defun per key, so a duplicate key cannot fire silently.
-}
activeSurf : List RtAst.Flag -> List ( RtAst.Defun, Defun ) -> Dict String Defun
activeSurf flags pairs =
    List.filter (\( a, _ ) -> RtCheck.guardsHold flags a.flags) pairs
        |> List.map (\( a, d ) -> ( a.key, d ))
        |> Dict.fromList


{-| THE SPLICE (T25: REPLACE an existing position, or ADD a new key).
Every DSL entry whose key is in `surf` is REPLACED by the surface defun at
its old position — list order is .ssa bytes, so order is preserved and
untouched entries pass through unchanged.  A surface defun whose key has NO
DSL position is a legitimate ADD (T25, handoff-osier-tier2-t25): it is
APPENDED after the WHOLE DSL list, the appended group ordered by key
ASCENDING — taken from `Dict.keys`, whose order elm/core documents as
"sorted from lowest to highest" (its Dict is an ordered tree); deterministic
because order is bytes (why the Dict's own order and not `List.sort`: the
selfhost lane's Prelude has NO sort function — see the `appended` binding).
`programPair`'s partition then lands every appended key at
the END of the PRIM half: `gcKeys` is the raw `gcProgram` key set (MEASURED:
exactly the 12 collector seats) and an appended key is by definition not one
of them, so `programGc`'s output is untouched by appends.  A future GC-ONLY
appended defun would need the partition predicate extended — NOT built here
(no such key exists; stage 6's new defuns are the driver/ABI family, emitted
with the prim half under their own hatch).  (Since T18 the caller passes the
UNION `primDefuns ++ helperDefuns ++ gcProgram`, so surface Rt.gc* keys
splice into their `gcProgram` positions too; `programPair` splits the
halves.)

THE LOUD ERROR MOVED (T25) — what is now loud that used to be loud.  The old
ORPHAN check made "a surface key with no DSL position" an Err precisely so a
defun could never vanish while `rtDeps` still routes to it.  That position is
now the ADD above, so keeping the check would make every ADD impossible; the
error moved onto the thing that is actually wrong.  The splice substitutes
the WHOLE defun, so the defun's OWN `.key` — not the dict key — is what lands
in the program; the dict key is only the routing label.  A surface defun
whose own key differs from the key it is spliced under would therefore
COLLIDE with an existing program key (an appended defun keyed like a
pass-through DSL entry => two defuns, one emitted name) or silently RENAME a
replaced key (a replacement keyed differently drops its DSL key from the
program while `rtDeps` still routes to it — the very "vanished defun" class
the orphan check existed to prevent; Lower's rawCall arm fails loudly on it,
but later and cryptically).  That mismatch is the new LOUD Err, naming both
keys, and it is the totality witness: program keys = DSL keys UNION surface
keys, each exactly once.  The real pipeline cannot trip it — `activeSurf`
pairs each AST key with the lowered defun keyed by that same key
(`LowerToIr.lowerDefun`).

NOT CHECKED HERE, and why: REACHABILITY.  The splice cannot know the
used-prim roots (`seeds`' argument), and the remaining stage-6 arc's new
defuns (`Rt.die`/`Rt.halt`, `Rt.main`) are reached from LOWER-GENERATED call
sites rather than from an Rt body, so a static "must appear in `rtDeps`"
guard would reject the driver.  The "never called" weight is borne by the
existing machinery, VERIFIED not assumed: Lower keeps only the SEEDED subset,
so an appended defun nothing reaches is PRUNED and never emitted (dead
source, not silent corruption); a call to a key absent from the program fails
LOUDLY in Lower's rawCall arm; and `externTypes` covers every surface key
via `surfaceSigs` (the parsed AST, guard variants included), so `call` to an
appended key typechecks and the T7 safety-net row holds it to an arity.  The
entry-point defuns get an EXPLICIT seed list when they land (the stage-6
plan's `driverSeeds`/`abiSeeds`, the `conSeeds`/`closureSeeds` precedent) —
an obligation recorded for stage 6, not a check that can exist before it.
-}
spliceSurface : Dict String Defun -> List Defun -> Result String (List Defun)
spliceSurface surface dsl =
    let
        dslKeys =
            Set.fromList (List.map .key dsl)

        -- T25: the key-agreement walk (the new loud error).  `Dict.toList`
        -- visits ASCENDING by key (elm/core's Dict is an ordered tree), so the
        -- mismatch NAMED is always the lowest offending key — deterministic.
        mismatched =
            List.filter (\( k, d ) -> d.key /= k) (Dict.toList surface)

        -- T25: the ADDs — appended after the DSL list, ordered by key
        -- ASCENDING.  `Dict.keys` IS that order: elm/core documents it
        -- ("Get all of the keys in a dictionary, sorted from lowest to
        -- highest") because its Dict is an ordered tree.  This is not a
        -- stylistic choice — the selfhost lane's Prelude carries NO sort
        -- function at all (MEASURED: `qbe-bootstrap.sh --status` died
        -- `unknown name: List.sortBy`), so the Dict's own documented order is
        -- the deterministic rule, and TestMain's T25 append row pins it.
        appended =
            Dict.keys surface
                |> List.filter (\k -> not (Set.member k dslKeys))
                |> List.filterMap (\k -> Dict.get k surface)
    in
    case mismatched of
        ( k, d ) :: _ ->
            Err
                (k
                    ++ ": the surface defun spliced under this key is itself keyed '"
                    ++ d.key
                    ++ "' — the splice substitutes the whole defun, so the two keys must agree: a mismatch would COLLIDE with the existing program key '"
                    ++ d.key
                    ++ "' (an appended defun keyed like a DSL entry, two defuns one emitted name) or drop '"
                    ++ k
                    ++ "' from the program while rtDeps still routes to it (a replacement)"
                )

        [] ->
            Ok
                (List.map
                    (\d ->
                        case Dict.get d.key surface of
                            Just replacement ->
                                replacement

                            Nothing ->
                                d
                    )
                    dsl
                    ++ appended
                )


{-| One Mid prim implementation: the Rt defun key AND its arity — the arity
the route check reads (Lower's midPrimRoute).  Step 5's hand-off #1: a
hardcoded arity silently mis-handles every non-binary prim, so the table
carries it next to the key it belongs to.
-}
type alias Impl =
    { key : String
    , arity : Int
    }


{-| prim name -> the Rt defun implementing it.  A prim absent here has no
Mid implementation (the host-only and unreachable prims — the
classification lives in Mid.RtPrims' header); Lower consults this for the
per-prim call route (the step-6 flip generalizes it).
-}
impls : Dict String Impl
impls =
    Dict.fromList
        [ ( "cons", { key = "Rt.cons", arity = 2 } )
        , ( "@p", { key = "Rt.@p", arity = 2 } )
        , ( "emptylist", { key = "Rt.emptylist", arity = 1 } )
        , ( "=", { key = "Rt.=", arity = 2 } )
        , ( "+", { key = "Rt.+", arity = 2 } )
        , ( "-", { key = "Rt.-", arity = 2 } )
        , ( "*", { key = "Rt.*", arity = 2 } )
        , ( "/", { key = "Rt./", arity = 2 } )
          -- L1: the `^` operator's runtime prim (square-and-multiply).
        , ( "pow", { key = "Rt.pow", arity = 2 } )
        , ( "f/", { key = "Rt.f/", arity = 2 } )
        , ( "<", { key = "Rt.<", arity = 2 } )
        , ( "<=", { key = "Rt.<=", arity = 2 } )
        , ( ">", { key = "Rt.>", arity = 2 } )
        , ( ">=", { key = "Rt.>=", arity = 2 } )
        , ( "bitwise-and", { key = "Rt.bitwise-and", arity = 2 } )
        , ( "bitwise-or", { key = "Rt.bitwise-or", arity = 2 } )
        , ( "bitwise-xor", { key = "Rt.bitwise-xor", arity = 2 } )
        , ( "bitwise-not", { key = "Rt.bitwise-not", arity = 1 } )
        , ( "bitwise-shift-left", { key = "Rt.bitwise-shift-left", arity = 2 } )
        , ( "bitwise-shift-right", { key = "Rt.bitwise-shift-right", arity = 2 } )
        , ( "bitwise-shift-right-zf", { key = "Rt.bitwise-shift-right-zf", arity = 2 } )
        , ( "number?", { key = "Rt.number?", arity = 1 } )
        , ( "string?", { key = "Rt.string?", arity = 1 } )
        , ( "cons?", { key = "Rt.cons?", arity = 1 } )
        , ( "empty?", { key = "Rt.empty?", arity = 1 } )
        , ( "c-strlen", { key = "Rt.c-strlen", arity = 1 } )
        , ( "char-code", { key = "Rt.char-code", arity = 2 } )
        , ( "substring", { key = "Rt.substring", arity = 3 } )
        , ( "cn", { key = "Rt.cn", arity = 2 } )
        , ( "repeat", { key = "Rt.repeat", arity = 2 } )
        , ( "joinPrim", { key = "Rt.join", arity = 2 } )
        , ( "shen.str->bytes", { key = "Rt.shen.str->bytes", arity = 1 } )
        , ( "shen.bytes->string", { key = "Rt.shen.bytes->string", arity = 1 } )
        , ( "absvector", { key = "Rt.absvector", arity = 1 } )
        , ( "address->", { key = "Rt.address->", arity = 3 } )
        , ( "<-address", { key = "Rt.<-address", arity = 2 } )
        , ( "assoc", { key = "Rt.assoc", arity = 2 } )
        , ( "snd", { key = "Rt.snd", arity = 1 } )
        , ( "recGet", { key = "Rt.recGet", arity = 2 } )
        , ( "recUpd", { key = "Rt.recUpd", arity = 3 } )
        , ( "recInsert", { key = "Rt.recInsert", arity = 3 } )
        , ( "recToChain", { key = "Rt.recToChain", arity = 1 } )
        , ( "write-byte", { key = "Rt.write-byte", arity = 2 } )
        , ( "read-byte", { key = "Rt.read-byte", arity = 1 } )
        , ( "open", { key = "Rt.open", arity = 2 } )
        , ( "close", { key = "Rt.close", arity = 1 } )
        , ( "intern", { key = "Rt.intern", arity = 1 } )
        , ( "value", { key = "Rt.value", arity = 1 } )
        , ( "str", { key = "Rt.str", arity = 1 } )
        , ( "getpid", { key = "Rt.getpid", arity = 1 } )
        , ( "getcwd", { key = "Rt.getcwd", arity = 1 } )
        , ( "cd", { key = "Rt.cd", arity = 1 } )
        , ( "getenv", { key = "Rt.getenv", arity = 1 } )
        , ( "setenv", { key = "Rt.setenv", arity = 2 } )
        , ( "glob", { key = "Rt.glob", arity = 1 } )
        , ( "exec-plan", { key = "Rt.exec-plan", arity = 1 } )
        , ( "read-file-as-string", { key = "Rt.read-file-as-string", arity = 1 } )
        ]


{-| The Rt defun implementing a prim, if any.
-}
primImpl : String -> Maybe Impl
primImpl prim =
    Dict.get prim impls


-- THE QBE_MIDHOST GATE (stage 7A) — the host's REACHABILITY switch, and the
-- ONE place the port is allowed to be conditional.
--
-- `run.js` COMPILE-TIME-splices the Mid effect host: `Rt.main`'s host arm
-- (region 1) AND the host's own defuns (region 2) are marked lines the reader
-- keeps BY DEFAULT and drops when QBE_MIDHOST=0 (stage 7 O2's flip; the Zig host
-- is the escape hatch until O4 deletes it).  The witness of that decision here is
-- therefore STRUCTURAL, not textual — the parsed program either defines
-- `Rt.hostRun` or it does not (a `String.contains` on the text would break the
-- selfhost lane, whose Prelude has no such function, and the defuns being absent
-- is the stronger fact anyway: a host-less program carries no host key at all).
--
-- WHY THE GATE IS NEEDED AT ALL: the Rt program's reachability is the hand table
-- `rtDeps` closed from SEED ROOTS, not a walk of the bodies (`reach` never enters
-- an Rt defun that is only seeded — see Lower's `keys`).  `Rt.main` is a seed
-- root UNCONDITIONALLY, so an edge `Rt.main -> Rt.hostRun` in `rtDeps` would drag
-- the whole host into EVERY artifact even when the region was dropped, because
-- `$main` is in every artifact.  The edge therefore lives in NO table: the host's
-- entry points are GATED ROOTS (`hostSeeds`), present only when `hosted` — which
-- is why a host-less emit is still possible with the host present in the file.
--


{-| The host's ENTRY POINTS: the two defuns `Rt.main`'s host arm calls.  Their
bodies' edges are declared in `rtDeps` like every other Rt->Rt edge, so this
list closes over the whole machine (24 defuns).  GATED — see `midHostMarker`.
-}
hostSeeds : List String
hostSeeds =
    keepRtDependencies [ "Rt.hostRun", "Rt.hostIsProgram" ]


{-| The Rt defun keys a USED-PRIM census seeds: for every used prim with a
Mid implementation, its key plus every Rt key it transitively references
(the RawCall edges — GRef reachability cannot see them, so they are
declared in `rtDeps` below and closed to a fixed point here).  `used` is
the set of prim names the REACHED surface defuns will call
(Mid.QbeLower.calledPrims — including the ListLit/RecordLit/RecordGet/
Tup/StreamRef desugars, which lower to cons/@p/emptylist/assoc/snd/value).
-}
seeds : Set String -> List String
seeds used =
    Set.toList used
        |> List.filterMap (\p -> Maybe.map .key (primImpl p))
        |> keepRtDependencies


{-| The transitive Rt->Rt edge list, keyed by the REFERENCING defun —
exactly the RawCall keys each body names (Mid.RtPrims is the only
producer; a key named in a body but absent here makes that defun
unreachable, and Lower's rawCall arm fails LOUDLY on it).
-}
rtDeps : Dict String (List String)
rtDeps =
    Dict.fromList
        [ ( "Rt.=", [ "Rt.deepEq", "Rt.symEq", "Rt.bytesEqGo", "Rt.asF" ] )
        , ( "Rt.+", [ "Rt.asF" ] )
        , ( "Rt.-", [ "Rt.asF" ] )
        , ( "Rt.*", [ "Rt.asF" ] )
          -- L3-U2: `//`'s two corners (zero divisor, INT64_MIN // -1) halt
          -- through Rt.die, so the divide now has an edge the seed closure
          -- must see — a key named in a body but absent here makes that
          -- defun unreachable, and Lower's rawCall arm fails LOUDLY on it.
        , ( "Rt./", [ "Rt.die" ] )
          -- L1: the `^` prim. `Rt.pow` rejects a negative exponent through
          -- Rt.die and hands the loop to `Rt.powGo`, whose square-and-multiply
          -- is a self-tail `recur` (its own edge, like every recur loop here).
        , ( "Rt.pow", [ "Rt.powGo", "Rt.die" ] )
        , ( "Rt.powGo", [ "Rt.powGo" ] )
        , ( "Rt.f/", [ "Rt.asF" ] )
        , ( "Rt.<", [ "Rt.asF" ] )
        , ( "Rt.<=", [ "Rt.asF" ] )
        , ( "Rt.>", [ "Rt.asF" ] )
        , ( "Rt.>=", [ "Rt.asF" ] )
        , ( "Rt.bitwise-and", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-or", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-xor", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-not", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-left", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-right", [ "Rt.toI32" ] )
        , ( "Rt.bitwise-shift-right-zf", [ "Rt.toI32" ] )
        , ( "Rt.deepEq", [ "Rt.deepEq", "Rt.bytesEqGo", "Rt.symEq", "Rt.vecEq" ] )
        , ( "Rt.vecEq", [ "Rt.vecEq", "Rt.deepEq" ] )
        , ( "Rt.bytesEqGo", [ "Rt.bytesEqGo" ] )
        , ( "Rt.symEq", [ "Rt.symEq" ] )
        , ( "Rt.revGo", [ "Rt.revGo", "Rt.cons" ] )
        , ( "Rt.numText", [ "Rt.digitCount", "Rt.numFill" ] )
        , ( "Rt.digitCount", [ "Rt.digitCount" ] )
        , ( "Rt.numFill", [ "Rt.numFill" ] )
        , ( "Rt.bytesToStr", [ "Rt.countL", "Rt.fillGo" ] )
        , ( "Rt.countL", [ "Rt.countGo" ] )
        , ( "Rt.countGo", [ "Rt.countGo" ] )
        , ( "Rt.fillGo", [ "Rt.fillGo" ] )
        , ( "Rt.cn", [ "Rt.cn2", "Rt.strOf" ] )
        , ( "Rt.cn2", [ "Rt.byteCopyGo" ] )
        , ( "Rt.byteCopyGo", [ "Rt.byteCopyGo" ] )
        , ( "Rt.join", [ "Rt.joinLen", "Rt.joinFill" ] )
        , ( "Rt.joinLen", [ "Rt.joinLen" ] )
        , ( "Rt.joinFill", [ "Rt.joinFill", "Rt.byteCopyGo" ] )
        , ( "Rt.strOf", [ "Rt.numText", "Rt.symToStr" ] )
        , ( "Rt.symToStr", [ "Rt.cStrLenGo", "Rt.byteCopyGo" ] )
        , ( "Rt.assoc", [ "Rt.assocGo" ] )
        , ( "Rt.assocGo", [ "Rt.assocGo", "Rt.deepEq" ] )
        , ( "Rt.substring", [ "Rt.byteCopyGo" ] )
        , ( "Rt.repeat", [ "Rt.repGo" ] )
        , ( "Rt.repGo", [ "Rt.repGo", "Rt.cn2" ] )
        , ( "Rt.shen.str->bytes", [ "Rt.bytesBuild" ] )
        , ( "Rt.bytesBuild", [ "Rt.bytesBuild", "Rt.cons" ] )
        , ( "Rt.shen.bytes->string", [ "Rt.bytesToStr" ] )
        , ( "Rt.recGet", [ "Rt.recGetGo" ] )
        , ( "Rt.recGetGo", [ "Rt.recGetGo", "Rt.symEq" ] )
        , ( "Rt.recUpd", [ "Rt.recUpdFind", "Rt.recUpdCopy" ] )
        , ( "Rt.recUpdFind", [ "Rt.recUpdFind", "Rt.symEq" ] )
        , ( "Rt.recUpdCopy", [ "Rt.recUpdCopy" ] )
        , ( "Rt.symLess", [ "Rt.symLess" ] )
        , ( "Rt.recAppendFind", [ "Rt.recAppendFind", "Rt.symLess" ] )
        , ( "Rt.recAppendDataGo", [ "Rt.recAppendDataGo" ] )
        , ( "Rt.recAppendNamesGo", [ "Rt.recAppendNamesGo" ] )
        , ( "Rt.recAppend", [ "Rt.recAppendFind", "Rt.recAppendDataGo", "Rt.recAppendNamesGo" ] )
        , ( "Rt.recInsert", [ "Rt.recUpdFind", "Rt.recUpd", "Rt.recAppend" ] )
        , ( "Rt.recToChain", [ "Rt.recToChainGo" ] )
        , ( "Rt.recToChainGo", [ "Rt.recToChainGo", "Rt.@p", "Rt.cons" ] )
        , -- ===== the mark-sweep collector (zigretire stage 4, Mid.RtGc)
          ( "Rt.allocVector", [ "Rt.gcInit", "Rt.gcAlloc" ] )
        , ( "Rt.allocRaw", [ "Rt.gcInit", "Rt.gcAlloc" ] )
        , ( "Rt.gcAlloc", [ "Rt.gcAllocGo", "Rt.collect", "Rt.die", "Rt.gcNumOut", "Rt.gcGrow" ] )
        , ( "Rt.gcGrow", [ "Rt.gcNumOut" ] )
        , ( "Rt.gcAllocGo", [] )
        , ( "Rt.gcInit", [ "Rt.die", "Rt.gcEnvNum" ] )
        , ( "Rt.gcEnvNum", [ "Rt.gcEnvNum" ] )
        , ( "Rt.collect", [ "Rt.gcMarkRoots", "Rt.gcMarkValuesTab", "Rt.gcDrain", "Rt.gcSweep", "Rt.gcClearClasses", "Rt.gcNumOut", "Rt.die", "Rt.gcVerify" ] )
        , ( "Rt.gcVerify", [ "Rt.gcVerify", "Rt.gcVerifyList", "Rt.gcVD" ] )
        , ( "Rt.gcVerifyList", [ "Rt.gcVerifyList", "Rt.gcVD" ] )
        , ( "Rt.gcVD", [ "Rt.gcNumOut", "Rt.die" ] )
        , ( "Rt.gcNumOut", [ "Rt.gcNum", "Rt.cStrLenGo" ] )
        , ( "Rt.gcNum", [ "Rt.gcNum" ] )
        , ( "Rt.gcMarkRoots", [ "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkPtr", "Rt.gcMarkValue", "Rt.die" ] )
        , ( "Rt.gcMarkValuesTab", [ "Rt.gcMarkValuesTab", "Rt.gcMarkValue" ] )
        , ( "Rt.gcScanValueArray", [ "Rt.gcScanValueArray", "Rt.gcMarkValue" ] )
        , ( "Rt.gcDrain", [ "Rt.gcDrain", "Rt.gcScanValueArray" ] )
        , ( "Rt.gcSweep", [ "Rt.gcSweep" ] )
        , ( "Rt.gcClearClasses", [ "Rt.gcClearClasses" ] )
        , ( "Rt.gcMarkPtr", [ "Rt.die", "Rt.gcVD" ] )
        , ( "Rt.gcMarkValue", [ "Rt.gcMarkPtr", "Rt.die" ] )
        , -- ===== the nursery's scavenge family (GC NURSERY unit).  These keys
          -- exist in the surface ONLY in a QBE_MIDGC_YOUNG=1 build (run.js
          -- splices the region out otherwise), so they are seeded from
          -- `youngGcSeeds` ONLY under that flag — an ALWAYS-PRESENT defun's
          -- row must never name one of them (the closure would drag an absent
          -- key into a plain MIDGC build's seeds and Lower dies "unknown
          -- global"; TestMain pins that rule).
          ( "Rt.gcScavenge", [ "Rt.gcScavRoots", "Rt.gcScavValuesTab", "Rt.gcScavRemembered", "Rt.gcScavDrain", "Rt.gcNumOut" ] )
        , ( "Rt.gcScavRoots", [ "Rt.gcScavRoots", "Rt.gcScavValue", "Rt.gcScavValueArray", "Rt.gcScavPtr", "Rt.die" ] )
        , ( "Rt.gcScavValue", [ "Rt.gcScavPtr", "Rt.gcVD", "Rt.die" ] )
        , ( "Rt.gcScavValuesTab", [ "Rt.gcScavValuesTab", "Rt.gcScavValue" ] )
        , ( "Rt.gcScavValueArray", [ "Rt.gcScavValueArray", "Rt.gcScavValue" ] )
        , ( "Rt.gcScavPtr", [ "Rt.gcPromoteAlloc", "Rt.gcScavCopyWords", "Rt.die" ] )
        , ( "Rt.gcScavCopyWords", [ "Rt.gcScavCopyWords" ] )
        , ( "Rt.gcScavRemembered", [ "Rt.gcScavRemembered", "Rt.gcScavOne", "Rt.gcVD", "Rt.die" ] )
        , ( "Rt.gcScavOne", [ "Rt.gcScavValueArray", "Rt.gcVD" ] )
        , ( "Rt.gcScavDrain", [ "Rt.gcScavDrain", "Rt.gcScavValueArray" ] )
        , ( "Rt.gcPromoteAlloc", [ "Rt.gcGrow", "Rt.gcNumOut", "Rt.die" ] )
        , -- ===== the Mid ADT constructor (zigretire stage 5)
          ( "Rt.con", [ "Rt.conFill" ] )
        , ( "Rt.conFill", [ "Rt.conFill" ] )
        , -- ===== the Mid closure (zigretire stage 5 PART 2)
          ( "Rt.closure", [ "Rt.closureFill" ] )
        , ( "Rt.closureFill", [ "Rt.closureFill" ] )
        , -- ===== THE VEC-STORE SEAM + THE CLOSURE CACHE (zighost Z2/Z3).
          -- Lower names both seats directly (`q_Rt_x2evecStorePlain` from the
          -- RawVecStore arm and the record arms, `q_Rt_x2eglobalClosure` from
          -- lowerGRefValue), so they are seeded from `lowerSeatSeeds`; the
          -- YOUNG writer lives in the QBE_MIDGC_YOUNG-ONLY region and is
          -- seeded from `youngGcSeeds` — this row is the only place that says
          -- so, and the die edge is the only dependency it has.
          ( "Rt.vecStorePlain", [] )
        , ( "Rt.vecStoreYoung", [ "Rt.die" ] )
        , -- ===== the fd prims (zigretire stage 3 GROUP 1)
          ( "Rt.write-byte", [] )
        , ( "Rt.read-byte", [ "Rt.readFull", "Rt.ssReadbyte" ] )
        , ( "Rt.open", [ "Rt.=", "Rt.cStrFill", "Rt.ssIn" ] )
        , ( "Rt.close", [ "Rt.ssClose" ] )
        , -- ===== THE STRING-STREAM REGISTRY (O5): the former rt_ss_* C seats
          -- re-homed into Mid — a lazily-malloc'd 8-cell (data,len,pos) table
          -- off Region slots 38..39, so Rt.open's ENOENT arm and the
          -- read/close string arms need no Zig seat at all.
          ( "Rt.ssTab", [] )
        , ( "Rt.ssIn", [ "Rt.ssTab", "Rt.ssInGo" ] )
        , ( "Rt.ssInGo", [ "Rt.ssInGo" ] )
        , ( "Rt.ssReadbyte", [] )
        , ( "Rt.ssClose", [] )
        , -- ===== THE INTERN TABLE (O5 seat 2): rt_sym_intern's replacement —
          -- a lazily-malloc'd (name,len)-pair array off the GLOBALS BLOCK
          -- words 8208..8210, a LINEAR byte-compare walk (every measured
          -- call site is a rawstr literal; 9 distinct names), find-or-insert.
          ( "Rt.intTab", [] )
        , ( "Rt.intFindGo", [ "Rt.intFindGo", "Rt.intBytesEq" ] )
        , ( "Rt.intBytesEq", [ "Rt.intBytesEq" ] )
        , ( "Rt.intStrCopy", [ "Rt.intStrCopy" ] )
        , ( "Rt.intPairsCopy", [ "Rt.intPairsCopy" ] )
        , ( "Rt.intern", [ "Rt.intTab", "Rt.intFindGo", "Rt.intInsert" ] )
        , ( "Rt.intGrow", [ "Rt.intPairsCopy" ] )
        , ( "Rt.intInsert", [ "Rt.intInsertGo", "Rt.intInsertAt" ] )
        , ( "Rt.intInsertGo", [ "Rt.intGrow", "Rt.intInsertAt" ] )
        , ( "Rt.intInsertAt", [ "Rt.intStrCopy" ] )
        , -- ===== THE VALUES TABLE (O5 seat 3): rt_value_slot's replacement —
          -- the HOST's 256-entry {name,value} table read through the GLOBALS
          -- BLOCK word 3 (rt_boot publishes vm.values_table there), a LINEAR
          -- 256-slot scan reusing the cStrLenGo/intBytesEq self-tails; a miss
          -- falls to the interned symbol.
          ( "Rt.valScanGo", [ "Rt.cStrLenGo", "Rt.intBytesEq" ] )
        , ( "Rt.value", [ "Rt.valScanGo", "Rt.cStrLenGo", "Rt.intern" ] )
        , -- readFull recurses only on the EINTR RETRY (one frame per retry,
          -- bounded by signal frequency, not by data length) — callR is fine.
        ( "Rt.readFull", [ "Rt.readFull" ] )
        , -- ===== the VM-state + str prims (zigretire stage 3 GROUP 2)
          -- ZIGHOST Z4a: the float arm is Rt.floatText's now (the Zig seat is
          -- deleted).  Rt.floatCopy stays as a surface helper — the float path
          -- no longer uses it, and it is pruned from every emit by
          -- reachability; Z6 sweeps it with the rest.
          ( "Rt.str", [ "Rt.floatText", "Rt.numText" ] )
        , ( "Rt.floatCopy", [ "Rt.floatCopy" ] )
        , -- ===== THE FLOAT TEXT (ZIGHOST Z4a).  One entry per defun, exactly
          -- its `call Rt.*` targets: the shortest-round-trip search (render +
          -- strtod round-trip), the exponent reader, and the expansion writer
          -- (byte-at-j + the bounded loop).  Rt.fRender and Rt.fDigit reach no
          -- Rt key at all — their only calls are rawcall (libc) and the
          -- builtins.
          ( "Rt.floatText", [ "Rt.fShortest", "Rt.fExpAt", "Rt.fExpGo", "Rt.fEmit", "Rt.copyWords" ] )
        , ( "Rt.fShortest", [ "Rt.fRender", "Rt.fShortest" ] )
        , ( "Rt.fRender", [] )
        , ( "Rt.fExpAt", [ "Rt.fExpAt" ] )
        , ( "Rt.fExpGo", [ "Rt.fExpGo" ] )
        , ( "Rt.fEmit", [ "Rt.fEmit", "Rt.fEmitByte" ] )
        , ( "Rt.fEmitByte", [ "Rt.fDigit" ] )
        , ( "Rt.fDigit", [] )
        , -- ===== THE BOOT (ZIGHOST Z5).  Rt.boot mallocs the values table and
          -- installs the three standard streams; Rt.valSlot is the one helper
          -- (Rt.valFreeGo's first free slot + the name write).  Both reach
          -- nothing but rawcalls and that helper.
          ( "Rt.boot", [ "Rt.valSlot" ] )
        , ( "Rt.valSlot", [ "Rt.valFreeGo" ] )
        , -- ===== THE PRINTER (ZIGHOST Z4b).  One entry per defun, exactly its
          -- `call Rt.*` targets.  Rt.pvV is the tag walk (recursive, so it
          -- names itself) and reaches the two formatters the walk delegates:
          -- Rt.numText for the number text and Rt.floatText (Z4a) for the
          -- float text — the printer reimplements NEITHER.  Rt.pvRec is the
          -- record element loop; the four appenders reach Rt.copyWords /
          -- Rt.byteCopyGo / Rt.cStrLenGo and nothing else.  Rt.die is already a
          -- driverSeed, so the two refused-by-name arms are closure edges.
          ( "Rt.printValue", [ "Rt.pvV" ] )
        , ( "Rt.pvV", [ "Rt.pvV", "Rt.pvRec", "Rt.pvS", "Rt.pvZ", "Rt.pvByte", "Rt.numText", "Rt.floatText", "Rt.die" ] )
        , ( "Rt.pvRec", [ "Rt.pvRec", "Rt.pvV", "Rt.pvByte" ] )
        , ( "Rt.pvNeed", [ "Rt.pvNeed", "Rt.copyWords" ] )
        , ( "Rt.pvN", [ "Rt.pvNeed", "Rt.byteCopyGo" ] )
        , ( "Rt.pvByte", [ "Rt.pvNeed" ] )
        , ( "Rt.pvZ", [ "Rt.cStrLenGo", "Rt.pvN" ] )
        , ( "Rt.pvS", [ "Rt.pvN" ] )
        , -- ===== the simple process prims (zigretire stage 3 GROUP 3A)
          ( "Rt.getpid", [] )
        , ( "Rt.getcwd", [ "Rt.cStrLenGo" ] )
        , ( "Rt.cd", [ "Rt.cStrFill" ] )
        , ( "Rt.getenv", [ "Rt.cStrFill", "Rt.cStrLenGo", "Rt.cStrCopyGo" ] )
        , ( "Rt.setenv", [ "Rt.cStrFill" ] )
        , -- ===== glob (zigretire stage 3 GROUP 3B)
          -- The match table and dupes live on the C heap (malloc/free via
          -- RawCallRaw — non-moving, so the scan/sort loops hold their raw
          -- pointers across every safepoint by construction).
          ( "Rt.glob"
          , [ "Rt.globLastSlash"
            , "Rt.globIsDot"
            , "Rt.globIsDotDot"
            , "Rt.globScanGo"
            , "Rt.globSortGo"
            , "Rt.globBuildGo"
            , "Rt.cStrFill"
            , "Rt.intern"
            , "Rt.cons"
            ]
          )
        , ( "Rt.globScanGo", [ "Rt.globIsDot", "Rt.globIsDotDot", "Rt.cStrLenGo", "Rt.cStrCopyGo" ] )
        , ( "Rt.globSortGo", [ "Rt.globSortShift" ] )
        , ( "Rt.globSortShift", [ "Rt.globStrLess" ] )
        , ( "Rt.globBuildGo", [ "Rt.cStrLenGo", "Rt.cStrCopyGo", "Rt.cons", "Rt.intern" ] )
        , -- ===== exec-plan DECODE (zigretire stage 3 GROUP 3B-2a).  The
          -- ep* helpers are ALL non-allocating (the whole decode is
          -- safepoint-free — see RtPrims' execPlanDefun doc); the ep* ->
          -- ep* edges below are plain callR closures, and epCmd <-> epProg
          -- is a genuine CYCLE (the subshell recursion) — fine for both the
          -- seeds closure and the allocating fixed point, both of which are
          -- fixed points over this table.  The five loop bodies that INLINE
          -- tagCountState (epProgGo/epPipeGo/epCmd/epArgvGo/epRedirsGo)
          -- carry its epSymIs edge here too — the call sits in THEIR body
          -- after inlining, so the call-graph row reads it there.
          ( "Rt.exec-plan"
          , [ "Rt.epProg"
            , "Rt.epFreeChains"
            , "Rt.mkTmpAt"
            , "Rt.execGo"
            , "Rt.exec-run"
            ]
          )
        , -- ===== exec-plan SLURP+RESULT (zigretire stage 3 GROUP 3B-2c).  The
          -- rt_exec_run Zig seat is DELETED; Rt.exec-run allocates DIRECTLY
          -- (the two result RawAllocRaws, the intern literals, the cons
          -- tree), so it is a natural `allocating` member and Rt.exec-plan
          -- reaches a safepoint through this edge — the fixed point's
          -- load-bearing rule, no manual override.
          ( "Rt.exec-run"
          , [ "Rt.readFileGo"
            , "Rt.memGo"
            , "Rt.cons"
            , "Rt.intern"
            ]
          )
        , -- ===== exec-plan RUN (zigretire stage 3 GROUP 3B-2b).  Like the
          -- ep* decode helpers, every run defun is NON-ALLOCATING (the whole
          -- run is safepoint-free: fork/exec/wait and the blob/cbuf/state
          -- walks are RawCallRaw + raw loads over C-heap memory) — the
          -- allocating half now lives in Rt.exec-run (3B-2c), and Rt.exec-plan
          -- is classified through that edge.
          ( "Rt.execGo"
          , [ "Rt.wirePipeGo"
            , "Rt.closePipeTmpfds"
            , "Rt.applyRedirects"
            , "Rt.runBuiltinInprocess"
            , "Rt.isChildBuiltin"
            , "Rt.waitStatusCode"
            , "Rt.closePipesGo"
            , "Rt.closeOthersGo"
            , "Rt.closeCmdTmpfds"
            , "Rt.childBuiltin"
            , "Rt.wStr"
            ]
          )
        , ( "Rt.mkTmpAt", [ "Rt.cStrCopyGo" ] )
        , ( "Rt.cStrEqLit", [] )
        , ( "Rt.wStr", [ "Rt.cStrLenGo" ] )
        , ( "Rt.wRaw", [] )
        , ( "Rt.waitStatusCode", [] )
        , ( "Rt.envHome", [ "Rt.cStrLenGo" ] )
        , ( "Rt.isChildBuiltin", [ "Rt.cStrEqLit" ] )
        , ( "Rt.echoGo", [ "Rt.wRaw", "Rt.wStr" ] )
        , ( "Rt.childCd", [ "Rt.envHome", "Rt.cStrLenGo", "Rt.cStrCopyGo", "Rt.wStr", "Rt.wRaw" ] )
        , ( "Rt.childPwd", [ "Rt.cStrLenGo", "Rt.wRaw" ] )
        , ( "Rt.childBuiltin", [ "Rt.cStrEqLit", "Rt.echoGo", "Rt.childCd", "Rt.childPwd" ] )
        , ( "Rt.applyOneRedir", [ "Rt.wStr", "Rt.wRaw" ] )
        , ( "Rt.applyRedirects", [ "Rt.applyOneRedir" ] )
        , ( "Rt.bodyWriteGo", [] )
        , ( "Rt.openBodyTmpfile", [ "Rt.cStrCopyGo", "Rt.cStrLenGo", "Rt.bodyWriteGo" ] )
        , ( "Rt.wireCmdGo", [ "Rt.openBodyTmpfile" ] )
        , ( "Rt.wirePipeGo", [ "Rt.wireCmdGo" ] )
        , ( "Rt.closeCmdTmpfds", [] )
        , ( "Rt.closePipeTmpfds", [ "Rt.closeCmdTmpfds" ] )
        , ( "Rt.closePipesGo", [] )
        , ( "Rt.closeOthersGo", [ "Rt.closeCmdTmpfds" ] )
        , ( "Rt.runBuiltinInprocess", [ "Rt.applyRedirects", "Rt.childBuiltin" ] )
        , ( "Rt.epProg", [ "Rt.epCount", "Rt.epProgGo", "Rt.epFreeChains" ] )
        , ( "Rt.epProgGo", [ "Rt.epSymIs", "Rt.epChain" ] )
        , ( "Rt.epChain", [ "Rt.epCount", "Rt.epElem", "Rt.epSymOf", "Rt.epSymIs", "Rt.epPipeline" ] )
        , ( "Rt.epPipeline", [ "Rt.epCount", "Rt.epPipeGo", "Rt.epFreeCmds" ] )
        , ( "Rt.epPipeGo", [ "Rt.epSymIs", "Rt.epCmd" ] )
        , ( "Rt.epCmd"
          , [ "Rt.epSymIs"
            , "Rt.epCount"
            , "Rt.epElem"
            , "Rt.epArgvGo"
            , "Rt.epRedirsGo"
            , "Rt.epProg"
            , "Rt.epFreeArgv"
            , "Rt.epFreeRedirs"
            , "Rt.epFreeChains"
            , "Rt.epCountStdin"
            ]
          )
        , ( "Rt.epArgvGo", [ "Rt.epSymIs", "Rt.epStr", "Rt.cStrFill", "Rt.epFreeArgv" ] )
        , ( "Rt.epRedirsGo", [ "Rt.epSymIs", "Rt.epRedir", "Rt.epFreeRedirs" ] )
        , ( "Rt.epRedir", [ "Rt.epCount", "Rt.epElem", "Rt.epSymOf", "Rt.epSymIs", "Rt.epNum", "Rt.epStr", "Rt.cStrFill" ] )
        , ( "Rt.epCount", [ "Rt.epSymIs" ] )
        , ( "Rt.epSymIs", [] )
        , ( "Rt.epElem", [] )
        , ( "Rt.epNum", [ "Rt.epSymIs" ] )
        , ( "Rt.epStr", [ "Rt.epSymIs" ] )
        , ( "Rt.epSymOf", [ "Rt.epSymIs" ] )
        , ( "Rt.epCountStdin", [] )
        , ( "Rt.epFreeChains", [ "Rt.epFreeCmds" ] )
        , ( "Rt.epFreeCmds", [ "Rt.epFreeCmd" ] )
        , ( "Rt.epFreeCmd", [ "Rt.epFreeArgv", "Rt.epFreeRedirs", "Rt.epFreeChains" ] )
        , ( "Rt.epFreeArgv", [] )
        , ( "Rt.epFreeRedirs", [] )
        -- globLastSlash/globScanGo/globStrLess/globSortShift/globSortGo/
        -- globBuildGo recurse through `App` on their OWN key (the SF2
        -- pattern: the in-frame loop), so they name no self RawCall edge.
        -- cStrFill/cStrLenGo/cStrCopyGo recurse through `App` on their OWN
        -- key (the SF2 fix: App self-tail = the in-frame loop on the
        -- DEFAULT route; the RawCall self-tail is unconditional since Z0), so they
        -- name NO RawCall edge — no entries here.  A future revert to
        -- callR fails TestMain's rt-call-graph check loudly, by design.
        , -- ===== read-file-as-string (zigretire stage 3 GROUP 3B-3).  The
          -- C-heap read loop and the byte memcpy are non-allocating (the
          -- loop state is a malloc'd block; readFull/memGo/malloc/free are
          -- raw), so Rt.readFileGo and Rt.memGo stay frame-free — the
          -- acc/tmp raw pointers are sound across iterations exactly while
          -- no safepoint can intervene, which the partition row pins.  The
          -- prim itself allocates DIRECTLY (cStrOf, the result RawAllocRaw)
          -- — no manual override needed, unlike Rt.exec-plan.
          ( "Rt.read-file-as-string"
          , [ "Rt.cStrFill"
            , "Rt.readFull"
            , "Rt.readFileGo"
            , "Rt.memGo"
            ]
          )
        , ( "Rt.readFileGo", [ "Rt.readFull", "Rt.memGo" ] )
        , ( "Rt.memGo", [] )
        , -- ===== the stage-6 U2 raw-word-ABI die/halt family.  Rt.die is a
          -- rawAbi defun (a WORD param, word result) reached from BOTH the
          -- Mid collector's failure arms (seeded transitively under
          -- QBE_MIDGC=1 via the gc* edges above) and Lower's non-exhaustive
          -- die emission (seeded under QBE_MIDDRIVER=1 via `driverSeeds`
          -- below).  Rt.halt is its 0-arg sibling, reached from Lower's
          -- rt_halt routing under QBE_MIDDRIVER=1.  Both write a static
          -- message via `rawstr` (no allocation) and exit(1); cStrLenGo is
          -- the only RawCall edge.
          ( "Rt.die", [ "Rt.cStrLenGo" ] )
        , ( "Rt.halt", [ "Rt.cStrLenGo" ] )
        , -- ===== the stage-6 A3b meta-walk family.  Rt.cStrEq is a rawAbi
          -- defun (WORD a/b in, WORD 0/1 out) — the meta walk's dynamic
          -- cStr-vs-cStr compare — reached from Rt.metaGo (the 24-B-row
          -- walker); its ONLY RawCall edge is Rt.cStrEqGo (the val-ABI
          -- NUL-terminated byte loop).  Rt.cStrEqGo and Rt.metaGo self-tail
          -- via recur (no RawCall edge) so neither names itself here (the
          -- cStrFill/cStrLenGo rule above).
          ( "Rt.cStrEq", [ "Rt.cStrEqGo" ] )
        , ( "Rt.cStrEqGo", [] )
        , ( "Rt.metaGo", [ "Rt.cStrEq" ] )
        , -- ===== the stage-6 A4a arg loop, and (O5 seat 4b) the arg
          -- PARSER it now calls.  Rt.parseArgsGo was a frame-free val defun
          -- whose only seat call was the rawcall rt_parse_arg (RawCallRaw —
          -- NOT an rtDeps edge), so its edge list was empty; the seat is
          -- gone, so the loop now owns a real Mid edge.  The parser family is
          -- frame-free by construction (malloc + byte/word stores only, no
          -- allocraw/allocvec/LString), which is what lets Rt.parseArg be
          -- called with the unrooted raw abuf pointer in hand.
          ( "Rt.parseArgsGo", [ "Rt.parseArg" ] )
        , ( "Rt.argHasFloatCh", [] )
        , ( "Rt.argIsFloat", [ "Rt.cStrEq", "Rt.argHasFloatCh" ] )
        , ( "Rt.argWs", [] )
        , ( "Rt.argErrGo", [ "Rt.cStrLenGo" ] )
        , ( "Rt.argErrFloat", [ "Rt.argErrGo" ] )
        , ( "Rt.argErrInt", [ "Rt.argErrGo" ] )
        , ( "Rt.parseArg", [ "Rt.argWs", "Rt.argIsFloat", "Rt.argErrFloat", "Rt.argErrInt" ] )
        , -- ===== (O5 seat 4b) the *argv* list + its table entry.
          -- Rt.argvGo ALLOCATES (allocraw for each argument's bytes and
          -- Rt.cons for each cell), so it is in the framed/allocating set;
          -- the accumulator it moves lives in a C-heap slot rooted with
          -- rt_root_push_value, never in a frame slot (a frame slot is not a
          -- root).  Rt.valEntry/valFreeGo are the table's write side: a
          -- linear walk like Rt.valScanGo, no allocation, no safepoint.
          ( "Rt.argvGo", [ "Rt.argvPush" ] )
        , ( "Rt.argvPush", [ "Rt.cStrLenGo", "Rt.cStrCopyGo", "Rt.cons" ] )
        , ( "Rt.valFreeGo", [] )
        , ( "Rt.valEntry", [ "Rt.valScanGo", "Rt.valFreeGo" ] )
        , ( "Rt.argvInstall", [ "Rt.valEntry", "Rt.argvGo", "Rt.rootPushValue", "Rt.rootPop" ] )
        , -- ===== the stage-6 A3a driver entry.  Rt.main is a rawAbi defun
          -- (WORD argc/argv in, WORD exit-code out) reached from
          -- driverSeeds; its RawCall edges are Rt.cStrLenGo (the three
          -- not-in-meta writes' lengths), Rt.metaGo (the meta walk) and
          -- Rt.parseArgsGo (the A4a arg loop).  The usage/toomany error paths
          -- reached cStrLenGo before A3b; A3b adds the meta-walk edge, A4a
          -- the arg loop.  Everything else it reaches is a rawcall
          -- (write/exit/getenv/malloc/rt_boot/
          -- rt_root_push_value_array +
          -- A4b's rt_root_push_value/rt_is_program/rt_run_program/
          -- rt_print_value) or a rawstr/rawsym static def — neither is an
          -- rtDeps edge.
          -- STAGE 7 O3 adds Rt.die: the default build's Rt.main carries the
          -- RUN-time half of the MIDGC x MIDHOST refusal (runtime.mid's
          -- QBE_MIDGC-ONLY region), which is a `call Rt.die(...)` and therefore
          -- a call-graph edge this list has to declare (the row that walks
          -- every program key's call targets would otherwise go red).  The
          -- edge costs the emit NOTHING: Rt.die is already a driverSeed ROOT,
          -- so the closure it pulls (Rt.cStrLenGo) is in every artifact
          -- already — an edge, not a new root, exactly like Rt.frame-leave's.
          ( "Rt.main", [ "Rt.cStrLenGo", "Rt.metaGo", "Rt.parseArgsGo", "Rt.argvInstall", "Rt.die", "Rt.rootPushValueArray", "Rt.rootPushValue", "Rt.printValue", "Rt.boot" ] )
        , -- ===== the stage-6 B0 frame machinery.  Rt.frame-enter's RawCall
          -- edges are its one helper; Rt.frame-leave's only edge is Rt.die
          -- (the no-frame panic — Rt.die is already a driverSeed, so this is
          -- a closure edge, not a new root).  Rt.frameBlock (malloc + the
          -- freelist pop, all rawcall/raw-word) names no Rt target.  The
          -- rt_root_push_value_array/rt_root_watermark/rt_root_pop_to calls
          -- are rawcall (RawCallRaw — NOT rtDeps edges), and P1e's bulk-zero
          -- `memset` is likewise a rawcall (RawCallRaw — NOT an rtDeps edge).
          ( "Rt.frame-enter", [ "Rt.frameBlock", "Rt.rootWatermark", "Rt.rootPushValueArray" ] )
        , ( "Rt.frame-leave", [ "Rt.die", "Rt.rootPopTo" ] )
        , ( "Rt.frameBlock", [] )
        , -- ===== THE MID-OWNED ROOT REGISTRY (ZIGHOST Z1).  The six write
          -- seats the frame machinery, the apply family, argvInstall, Rt.main
          -- and the host used to reach through `rawcall rt_root_*` are Mid
          -- defuns now, so each is a REAL call-graph edge.  Rt.rootPush is the
          -- ONE push body (three kinds share it); Rt.rootGrow mallocs + copies
          -- through Rt.copyWords (libc malloc/free — no safepoint, so the whole
          -- registry stays alloc-free from the collector's view and these
          -- defuns stay out of the framed set).
          ( "Rt.rootPushValue", [ "Rt.rootPush" ] )
        , ( "Rt.rootPushPtr", [ "Rt.rootPush" ] )
        , ( "Rt.rootPushValueArray", [ "Rt.rootPush" ] )
        , ( "Rt.rootPush", [ "Rt.rootGrow" ] )
        , ( "Rt.rootGrow", [ "Rt.copyWords" ] )
        , ( "Rt.rootPop", [ "Rt.die" ] )
        , ( "Rt.rootWatermark", [] )
        , ( "Rt.rootPopTo", [ "Rt.die" ] )
        , -- ===== the stage-6 B1 apply family.  Rt.apply/Rt.apply-tail are
          -- rawAbi WRAPPERS (root the caller's f/args, then hand off); their
          -- one RawCall edge each is the val-ABI LOOP.  The loops reach
          -- Rt.callArity (the 17-arm rt_callN dispatch + rt_bounce) and
          -- Rt.copyWords (the raw-word Value-array copy) and Rt.die (the
          -- non-function/closure-env panics — already a driverSeed, so these
          -- are closure edges, not new roots).  rt_callN/rt_bounce are
          -- aggcall (RawCallAgg — NOT rtDeps edges); malloc/rt_root_* are
          -- rawcall (RawCallRaw — NOT rtDeps edges).
          ( "Rt.apply", [ "Rt.applyGo", "Rt.rootPushValueArray", "Rt.rootPop" ] )
        , ( "Rt.apply-tail", [ "Rt.applyTailGo", "Rt.rootPushValueArray", "Rt.rootPop" ] )
        , -- STAGE 7 O3-fix: both apply LOOPS' partial arms (`rem > nargs`) now
          -- hand off to Rt.applyPartGo instead of spelling the capture/args
          -- interleave inline, so the edge is theirs AND the host applier's:
          -- ONE defun owns the interleave, so the two routes cannot drift.
          ( "Rt.applyGo", [ "Rt.callArity", "Rt.copyWords", "Rt.die", "Rt.applyPartGo" ] )
        , ( "Rt.applyTailGo", [ "Rt.callArity", "Rt.copyWords", "Rt.die", "Rt.applyPartGo", "Rt.rootPushPtr", "Rt.rootPop" ] )
        , ( "Rt.applyPartGo", [ "Rt.copyWords", "Rt.rootPushPtr", "Rt.rootPop" ] )
        , ( "Rt.callArity", [] )
        , -- Rt.copyWords is the raw-word WRAPPER (malloc the counter cell,
          -- hand off, free); Rt.copyWordsGo is the raw-word LOOP (wload/wstore
          -- + a self-tail recur — no RawCall edge, the cStrFill/[] precedent).
          -- Neither reaches a GC safepoint: malloc/free are libc (RawCallRaw),
          -- not allocvec/allocRaw, so both stay frame-free.
          ( "Rt.copyWords", [ "Rt.copyWordsGo" ] )
        , ( "Rt.copyWordsGo", [] )
        , -- ===== the stage-6 B2 mid-tail family.  Rt.tail-known's only RawCall
          -- edge is Rt.copyWords (the raw-word Value-array copy; its other
          -- nodes are rawcall/aggcall/raw-word, NOT rtDeps edges).  Rt.bounce's
          -- only RawCall edge is its :val loop helper Rt.bounceGo (which itself
          -- dispatches via aggcall — RawCallAgg, NOT an rtDeps edge — and
          -- self-tails via recur).
        ( "Rt.tail-known", [ "Rt.copyWords" ] )
        , -- Q1b stage 1: the tcall staging seat's only RawCall edge is the same
          -- raw-word Value-array copy (allocvec is a raw node, not an edge).
          ( "Rt.stage-tail", [ "Rt.copyWords" ] )
        , ( "Rt.bounce", [ "Rt.bounceGo" ] )
        , ( "Rt.bounceGo", [] )
        , -- ===== THE STAGE 7A MID HOST (QBE_MIDHOST).  One entry per host
          -- defun, exactly its RawCall targets — the machine's call graph,
          -- declared by hand like every other Rt->Rt edge (`reach` never walks
          -- an Rt body that is only seeded).  The ROOTS are `hostSeeds`, NOT
          -- an edge from Rt.main: Rt.main is seeded unconditionally ($main is
          -- in every artifact), so an edge here would pull the host into the
          -- default route and move all 159 corpus hashes.  See midHostMarker.
          -- The dispatch's edges are the ctor arms (Succeed/Fail/AndThen/
          -- OnError/Now/Quit land in complete*/pushFrame; 7B-7E's leaves land
          -- in their own seated defuns) plus hostArity/cStrEq for the tag
          -- probe and hostDieErr for the note below.
          --
          -- STAGE 7E DELETED ( "Rt.hostDieUnported", [ "Rt.hostDieErr" ] ).
          -- It was the porting gate: 7A-7D had 18 of twenty ctors, and the
          -- other two had to die loudly.  7E implements ListDir and Stat, so
          -- no ctor routes there any more and the seat was removed from the
          -- rawAbi set, the arity record and this table alike.  The dispatch's
          -- tail is now the ZIG's unhandled-ctor arm, hostDieErr with its own
          -- `unhandled Task effect: ` prefix.
          ( "Rt.hostDieErr", [ "Rt.cStrLenGo" ] )
        , ( "Rt.dieErr", [ "Rt.hostDieErr" ] )
        , ( "Rt.hostNowMs", [] )
        , ( "Rt.hostInit", [ "Rt.rootPushValueArray" ] )
        , ( "Rt.hostIsProgram", [ "Rt.cStrEq" ] )
        , ( "Rt.hostArity", [ "Rt.cStrEq" ] )
        , -- STAGE 7 O3-fix: the applier's rawcall set grew by the two non-call
          -- edges its three nargs/rem arms need — Rt.applyPartGo (the partial
          -- arm; a call edge, because the interleave is a defun) and Rt.die
          -- (the saturated arm's missing-env guard, the SAME message and the
          -- same condition as applyGo's).  Rt.callArity is still the
          -- saturated napp == 0 seat (trap 1) and Rt.apply/Rt.applyGo are
          -- still absent from it by pin.
          -- The SELF edge is real and is the over-applied arm: `nargs > rem`
          -- applies the first `rem` through this same seat (a recursive call,
          -- which lands in one of the other two arms) and `recur`s on the
          -- result with the rest.  keepRtDependencies closes over cycles, so a
          -- key that names itself costs the seed walk nothing.
          ( "Rt.apply-at", [ "Rt.dieErr", "Rt.callArity", "Rt.applyPartGo", "Rt.die", "Rt.apply-at" ] )
        , ( "Rt.hostCall", [ "Rt.apply-at" ] )
        , ( "Rt.hostClearGo", [] )
        , ( "Rt.hostClearFrom", [ "Rt.hostClearGo" ] )
        , ( "Rt.hostDeactivate", [ "Rt.hostClearFrom" ] )
        , ( "Rt.hostSpawnAt", [ "Rt.hostClearFrom" ] )
        , ( "Rt.hostSpawnFind", [ "Rt.dieErr", "Rt.hostSpawnAt" ] )
        , ( "Rt.hostSpawn", [ "Rt.hostSpawnFind" ] )
        , ( "Rt.hostSpawnFromCmd", [ "Rt.hostSpawn" ] )
        , ( "Rt.hostPushFrame", [ "Rt.dieErr" ] )
        , ( "Rt.hostDispatch", [ "Rt.hostDeactivate", "Rt.hostArity", "Rt.cStrEq", "Rt.hostCompleteOk", "Rt.hostCompleteErr", "Rt.hostPushFrame", "Rt.hostNowMs", "Rt.hostDieErr", "Rt.hostWriteStr", "Rt.hostReadLine", "Rt.hostWriteFileLeaf", "Rt.hostLeafReadFile", "Rt.hostLeafExec", "Rt.hostLeafListDir", "Rt.hostLeafStat", "Rt.getenv", "Rt.setenv", "Rt.cd", "Rt.getcwd", "Rt.getpid", "Rt.glob" ] )
        , ( "Rt.hostCompleteOk", [ "Rt.hostDeliver", "Rt.hostCall" ] )
        , ( "Rt.hostCompleteErr", [ "Rt.hostDeactivate", "Rt.hostCall" ] )
        , ( "Rt.hostDeliver", [ "Rt.hostCall", "Rt.hostDeactivate", "Rt.hostSpawnFromCmd" ] )
        , ( "Rt.hostStepGo", [ "Rt.hostDispatch" ] )
        , ( "Rt.hostStep", [ "Rt.hostStepGo" ] )
        , ( "Rt.hostStepAllGo", [ "Rt.hostStep" ] )
        , ( "Rt.hostStepAll", [ "Rt.hostStepAllGo" ] )
        , ( "Rt.hostRunLoop", [ "Rt.hostStepAll", "Rt.hostFlushExpiredSleeps", "Rt.hostRunnableScan", "Rt.hostPollTimeout", "Rt.hostRebuildPollfds", "Rt.hostDrainReady", "Rt.hostReapChildren", "Rt.hostCompleteReady", "Rt.hostReapBlocking", "Rt.dieErr" ] )
        , ( "Rt.hostRun", [ "Rt.hostInit", "Rt.hostSpawnFromCmd", "Rt.hostRunLoop", "Rt.hostCleanupAll", "Rt.rootPop" ] )
        , -- ===== THE STAGE 7B SYNCHRONOUS LEAVES + THE DEADLINE MACHINERY.
          -- Same rule as the 7A block above: one entry per host defun, exactly
          -- its `call Rt.*` targets.  The prim leaves' targets (Rt.getenv/
          -- setenv/cd/getcwd/getpid/glob) are the GROUP 3A/3B defuns, whose
          -- own edges are declared further up — that is why the closure pulls
          -- the whole prim (Rt.glob's cons/intern included) into an arm-B
          -- binary and into nothing on the default route.
          ( "Rt.hostWriteAll", [] )
        , ( "Rt.hostWriteStr", [ "Rt.cStrFill", "Rt.hostWriteAll" ] )
        , ( "Rt.hostWriteFileLeaf", [ "Rt.cStrFill", "Rt.hostWriteStr" ] )
        , ( "Rt.hostLineGrow", [ "Rt.memGo" ] )
        , ( "Rt.hostReadLineLoop", [ "Rt.hostLineGrow" ] )
        , ( "Rt.hostReadLine", [ "Rt.hostReadLineLoop", "Rt.memGo" ] )
        , ( "Rt.hostSleepScan", [] )
        , ( "Rt.hostNearestSleep", [ "Rt.hostSleepScan" ] )
        , ( "Rt.hostPollTimeout", [ "Rt.hostNearestSleep", "Rt.hostNowMs" ] )
        , ( "Rt.hostSleepComplete", [ "Rt.hostCompleteOk" ] )
        , ( "Rt.hostFlushExpiredSleeps", [ "Rt.hostNowMs", "Rt.hostSleepScan", "Rt.hostSleepComplete" ] )
        , ( "Rt.hostRunnableScan", [] )
        , -- ===== THE STAGE 7C fd TABLE + THE POLL.  Same rule again: one entry
          -- per host defun, exactly its `call Rt.*` targets.  `hostSetNonblocking`
          -- has NO Rt target at all — its one call is the DECLARED `fcntl`
          -- (explicitly not a rawcallArity row, so not a RawCall symbol), which
          -- is also why its edge list is empty rather than missing.
          ( "Rt.hostRfGrow", [ "Rt.memGo" ] )
        , ( "Rt.hostReadFileDrain", [ "Rt.hostRfGrow", "Rt.memGo" ] )
        , ( "Rt.hostReadFileComplete", [ "Rt.memGo", "Rt.hostCompleteOk" ] )
        , ( "Rt.hostLeafReadFile", [ "Rt.cStrFill", "Rt.hostReadFileDrain", "Rt.hostReadFileComplete", "Rt.hostCompleteOk" ] )
        , ( "Rt.hostPollFd", [] )
        , ( "Rt.hostAddPoll", [ "Rt.hostPollFd", "Rt.dieErr" ] )
        , ( "Rt.hostRebuildPollGo", [ "Rt.hostAddPoll" ] )
        , ( "Rt.hostRebuildPollfds", [ "Rt.hostRebuildPollGo" ] )
        , ( "Rt.hostPollEntry", [ "Rt.hostReadFileDrain", "Rt.hostReadFileComplete", "Rt.hostExecDrainOut", "Rt.hostExecDrainErr" ] )
        , ( "Rt.hostDrainReadyGo", [ "Rt.hostPollEntry" ] )
        , ( "Rt.hostDrainReady", [ "Rt.hostDrainReadyGo" ] )
        , ( "Rt.hostCleanupGo", [ "Rt.hostEpFreePlan", "Rt.hostCloseFd" ] )
        , ( "Rt.hostCleanupAll", [ "Rt.hostCleanupGo" ] )
        , ( "Rt.hostSetNonblocking", [] )
        , -- ===== THE STAGE 7D EXEC.  Same rule again: one entry per host defun,
          -- exactly its `call Rt.*` targets.  The DECODER (`Rt.epProg` and the
          -- Rt.ep* family) and the SYNCHRONOUS runner (`Rt.exec-plan`) are
          -- pre-existing keys with their own edges further up, which is why
          -- the async leaf pulls the whole plan machinery into an arm-B binary
          -- and into nothing on the default route.
          ( "Rt.hostEpCbuf", [ "Rt.cStrFill" ] )
        , ( "Rt.hostSingleCommandArgv", [] )
        , ( "Rt.hostCloseFd", [] )
        , ( "Rt.hostEpFreePlan", [ "Rt.epFreeChains" ] )
        , ( "Rt.hostExecChild", [ "Rt.hostCloseFd", "Rt.childBuiltin", "Rt.wStr" ] )
        , ( "Rt.hostCStrOf", [ "Rt.memGo" ] )
        , ( "Rt.hostExOutGrow", [ "Rt.memGo" ] )
        , ( "Rt.hostExErrGrow", [ "Rt.memGo" ] )
        , ( "Rt.hostExOutEof", [ "Rt.hostCloseFd" ] )
        , ( "Rt.hostExErrEof", [ "Rt.hostCloseFd" ] )
        , ( "Rt.hostExecDrainOutGo", [ "Rt.hostExOutEof", "Rt.hostExOutGrow", "Rt.memGo" ] )
        , ( "Rt.hostExecDrainErrGo", [ "Rt.hostExErrEof", "Rt.hostExErrGrow", "Rt.memGo" ] )
        , ( "Rt.hostExecDrainOut", [ "Rt.hostExecDrainOutGo", "Rt.hostExOutEof" ] )
        , ( "Rt.hostExecDrainErr", [ "Rt.hostExecDrainErrGo", "Rt.hostExErrEof" ] )
        , ( "Rt.hostRegisterChild", [] )
        , ( "Rt.hostReapGo", [ "Rt.waitStatusCode" ] )
        , ( "Rt.hostReapChildren", [ "Rt.hostReapGo" ] )
        , ( "Rt.hostReapBlockGo", [ "Rt.waitStatusCode" ] )
        , ( "Rt.hostReapBlocking", [ "Rt.hostReapBlockGo" ] )
        , ( "Rt.hostExecComplete", [ "Rt.hostCStrOf", "Rt.cons", "Rt.hostEpFreePlan", "Rt.hostCompleteOk" ] )
        , ( "Rt.hostCompleteReadyGo", [ "Rt.hostExecComplete" ] )
        , ( "Rt.hostCompleteReady", [ "Rt.hostCompleteReadyGo" ] )
        , ( "Rt.hostLeafExec", [ "Rt.hostEpCbuf", "Rt.epProg", "Rt.hostDieErr", "Rt.hostSingleCommandArgv", "Rt.epFreeChains", "Rt.exec-plan", "Rt.hostCompleteOk", "Rt.hostExecChild", "Rt.hostSetNonblocking", "Rt.hostRegisterChild" ] )
        , -- ===== THE STAGE 7E DIR/STAT LEAVES.  Same rule again: one entry per
          -- host defun, exactly its `call Rt.*` targets.  `Rt.revGo` is the
          -- list flip the walk needs (the accumulator is built in reverse
          -- order, since each record is PREPENDED), and `Rt.cons`/`Rt.@p`/
          -- `Rt.intern` are the record builders' primitive forms — the Zig's
          -- values.valCons/values.valSymbol/runPrim("@p"), which is why the
          -- record shape is an ASSOC CHAIN and not a compiled vector.
          ( "Rt.hostLeafListDir", [ "Rt.cStrFill", "Rt.hostListDirDrain", "Rt.revGo", "Rt.hostCompleteOk" ] )
        , ( "Rt.hostListDirDrain", [ "Rt.hostListDirChunk" ] )
        , ( "Rt.hostListDirChunk", [ "Rt.cStrLenGo", "Rt.hostCStrOf", "Rt.hostDirIsDir", "Rt.hostDirRecord" ] )
        , ( "Rt.hostDirIsDir", [] )
        , ( "Rt.hostDirRecord", [ "Rt.@p", "Rt.intern", "Rt.cons" ] )
        , ( "Rt.hostLeafStat", [ "Rt.cStrFill", "Rt.hostStatRecord", "Rt.hostCompleteOk" ] )
        , ( "Rt.hostStatRecord", [ "Rt.cons", "Rt.@p", "Rt.intern" ] )
        ]


keepRtDependencies : List String -> List String
keepRtDependencies roots =
    let
        -- RTDEPS IS BUILT ONCE PER CALL, NOT ONCE PER QUEUE ELEMENT.  It is a
        -- 0-arity TOP-LEVEL value, and this emit has no load-time initialiser:
        -- every REFERENCE to it is a `call` to a defun that rebuilds the whole
        -- 83-entry Dict (no memo guard).  The walk below references it once
        -- per queue element, i.e. once per Rt key it closes over — MEASURED
        -- (2026-10-19, a counter at the seeded defun's entry): 1 289 entries
        -- per compile of the profiler's small workload, 28.45% of that run's
        -- CPU.  Bound here, the emitted closure CAPTURES it, so a call of
        -- keepRtDependencies builds the Dict once however large the closure.
        deps0 =
            rtDeps

        step : List String -> List String -> List String
        step acc queue =
            case queue of
                [] ->
                    List.reverse acc

                key :: rest ->
                    if List.member key acc then
                        step acc rest

                    else
                        case Dict.get key deps0 of
                            Just deps ->
                                step (key :: acc) (deps ++ rest)

                            Nothing ->
                                step (key :: acc) rest
    in
    step [] roots


{-| The Rt defun keys the collector needs, transitively closed over the
`rtDeps` edges above.  Seeded by Mid.Qbe.Lower when QBE_MIDGC=1: the two
allocating seats (`Rt.allocVector`/`Rt.allocRaw`) are the only roots, and
the mark/sweep machinery (`Rt.collect` and its walkers) follows them.
-}
gcSeeds : List String
gcSeeds =
    keepRtDependencies [ "Rt.allocVector", "Rt.allocRaw" ]


{-| THE NURSERY'S SEED ROOT (GC NURSERY unit): the scavenge entry point, whose
rtDeps closure above pulls in the whole young family.  Seeded by Lower ONLY
when the QBE_MIDGC_YOUNG=1 build flag is on (the surface defuns exist only
then); the young dispatch sites in Rt.gcAlloc / Rt.collect are inside the
spliced region, so nothing else needs to name these keys.
-}
youngGcSeeds : List String
youngGcSeeds =
    keepRtDependencies [ "Rt.gcScavenge", "Rt.vecStoreYoung" ]


{-| The Mid-routed CONSTRUCTOR seeds (zigretire stage 5): the Rt defuns Lower
retargets a surface construct to under QBE_MIDGC=1 — `Rt.con` (the ADT
constructor) and its transitive closure.  Seeded alongside `gcSeeds` when the
hatch is on, because Lower's `lowerCon` names `q_Rt_con` directly (it is not
a prim, so the used-prim census does not seed it).
-}
conSeeds : List String
conSeeds =
    keepRtDependencies [ "Rt.con" ]


{-| The Mid-routed CLOSURE seed (zigretire stage 5 PART 2): `Rt.closure` (the
closure env allocator) and its transitive closure — Rt.closureFill, the
0-based copy loop.  Seeded alongside `conSeeds` when the hatch is on, because
Lower's `lowerClosure` names `q_Rt_closure` directly (it is not a prim, so the
used-prim census does not seed it).
-}
closureSeeds : List String
closureSeeds =
    keepRtDependencies [ "Rt.closure" ]


{-| THE SEATS LOWER NAMES DIRECTLY (zighost Z2/Z3): the plain vec-store writer
and the per-Desc closure-cache slot.  Neither is a prim (so the used-prim
census does not seed them) and neither is a collector defun (so `gcSeeds`
does not either), yet both are ALWAYS PRESENT and always emitted when Lower's
RawVecStore arm / `lowerGRefValue` names them.

The YOUNG vec-store seat is the exception: its body lives in runtime.mid's
QBE_MIDGC_YOUNG-ONLY region, so it is seeded from `youngGcSeeds` instead — an
always-present row here naming it would drag an absent defun into a plain
build's seed closure and Lower would die "unknown global".
-}
lowerSeatSeeds : List String
lowerSeatSeeds =
    keepRtDependencies [ "Rt.vecStorePlain", "Rt.globalClosure" ]


{-| THE RAW-WORD DEFUN CONVENTION (stage 6 U2, plan obs-4): the Rt keys that
lower with a WORD calling convention instead of the lean `:val` ABI — their
defuns emit `(params Base L, ret Base L/W)` and every caller (Lower-generated
sites AND surface `call` sites) emits a matching WORD call.
`driverSeeds` (below) is the seed list, `seeds`/`gcSeeds`/`conSeeds`/
`closureSeeds` are the `:val` ones.
  * B6 CHANGED THIS SET'S ROLE: it is no longer the ONLY place the ABI class
    is declared.  The class is now DERIVED from the signature (`abiTable`
    below, plan Q7) for every surface and user defun; THIS set is the
    OVERRIDE that keeps the FOUR aggregate-returning keys (Rt.apply,
    Rt.apply-tail, Rt.tail-known, Rt.bounce — all-word parameters, `val`/
    `:ret` results) on the word side, where the signature rule alone would
    move them and the corpus with them.  The other nine keys are word-ABI
    because their signatures say so; declaring them here as well is what makes
    the two statements agree, and TestMain pins that they do (the `derived ==
    rawAbi` row).
-}
rawAbi : Set String
rawAbi =
    Set.fromList
        [ "Rt.cStrEq"
        , "Rt.die"
        , "Rt.halt"
        , "Rt.main"
        , -- ===== the stage-6 B0 frame machinery (raw-word ABI: word in/out).
          -- Rt.frame-enter/leave are the raw-word pair the prologue/return
          -- retarget reaches; Rt.frameBlock (the freelist pop-or-malloc) is a
          -- word helper so the rawAbi->rawAbi `call` stays on the raw-word
          -- path.  P1e's bulk-zero is a rawcall memset (RawCallRaw — no
          -- rawAbi defun), so frameZero no longer exists.
          "Rt.frame-enter"
        , "Rt.frame-leave"
        , "Rt.frameBlock"
        , -- ===== the stage-6 B1 apply family.  Rt.apply/Rt.apply-tail are
          -- raw-word defuns whose RESULT is an AGGREGATE (the stage-6 B1
          -- rawAbi-ret-class extension — Mid.Qbe.Lower.rawAbiRetClass maps
          -- them to Agg "val"/Agg "ret"): 3 word params (fslot *Value,
          -- args [*]Value, nargs), reached from Lower's rtApply retarget.
          -- Their LOOP bodies (Rt.applyGo/Rt.applyTailGo) are :val defuns
          -- (recur needs the val self-tail), NOT rawAbi.
          "Rt.apply"
        , "Rt.apply-tail"
        , -- ===== the stage-6 B1fix copyWords WORD pair.  Rt.copyWords (the
          -- wrapper: dst/src/n word params, allocates the counter cell) and
          -- Rt.copyWordsGo (the loop: dst/src/cnt word params, self-tail
          -- `recur` on its three constant params with the count in the cell)
          -- are BOTH rawAbi word defuns — no :val on the copy path (the same
          -- frameZero discipline), removing the per-word blit/boxing.
          "Rt.copyWords"
        , "Rt.copyWordsGo"
        , -- ===== zighost Z2's VEC-STORE SEAM.  Both writers are all-word
          -- signatures, so the B6 rule derives them anyway; declaring them
          -- here is what makes the two statements AGREE (the B6 THE TABLE row
          -- asserts derived == rawAbi over the shipped text), and the arity
          -- record is what checks every call site's 3 words.
          "Rt.vecStorePlain"
        , "Rt.vecStoreYoung"
        , -- ===== zighost Z3's CLOSURE CACHE.  Its signature is (word) -> val,
          -- so the B6 signature rule would put it on the VALUE side; this
          -- override is load-bearing (that is the override's whole purpose),
          -- and the ret class is Agg "val" (Lower.rawAbiRetClass) — the
          -- deleted Zig seat's sret ABI.
          "Rt.globalClosure"
        , -- ===== the stage-6 B2 mid-tail family.  Rt.tail-known is a raw-word
          -- defun whose RESULT is the 80-byte `:ret` (Agg "ret", the
          -- rt_tail_known seat's C ABI — 3 word params code/argblock/nargs,
          -- reached from Lower's directCall TAIL retarget).  Rt.bounce is a
          -- raw-word defun whose RESULT is the 40-byte `.done` Value (Agg
          -- "val", the rt_bounce seat's C ABI — 1 word param, the :ret
          -- pointer, reached from Lower's bounce retarget).  Their :val
          -- helper/loop (Rt.bounceGo) is NOT rawAbi — recur needs the val
          -- self-tail.
          "Rt.tail-known"
        , -- Q1b stage 1: the tcall STAGING seat.  An all-word signature
          -- ((argblock, nargs) -> buf), so the B6 rule derives it; declaring
          -- it here is what keeps the derived set and this table in step (the
          -- B6 THE TABLE row asserts they agree over the shipped text), and
          -- rawAbiArity is what checks both the defun and Lower's call site.
          "Rt.stage-tail"
        , "Rt.bounce"
        , -- ===== THE STAGE 7A HOST's die family (QBE_MIDHOST).  These are not
          -- driver seats: they are declared so the B6 RULE's derived set (an
          -- all-word SIGNATURE) and this table agree — they are word-ABI by
          -- signature, and declaring them keeps the two statements of one fact
          -- from drifting.  Rt.die's own precedent: a die takes the raw C
          -- string it prints.
          "Rt.dieErr"
        , "Rt.hostDieErr"
        , -- ===== THE MID-OWNED ROOT REGISTRY (ZIGHOST Z1): eight word-ABI
          -- defuns, word-ABI by SIGNATURE (all-word params, word result), so
          -- they land in the derived set and are declared here to keep the two
          -- statements of one fact in step.  Rt.rootPush is the ONE push body
          -- (kind, slot, np), the three public pushes are its 1/1/2-param
          -- spellings, and Rt.rootWatermark/Rt.rootPop/Rt.rootPopTo are the
          -- depth seats.
          "Rt.rootGrow"
        , "Rt.rootPush"
        , "Rt.rootPushPtr"
        , "Rt.rootPushValue"
        , "Rt.rootPushValueArray"
        , "Rt.rootPop"
        , "Rt.rootWatermark"
        , "Rt.rootPopTo"
        ]


{-| THE rawAbi ARITY RECORD (stage 6 A1, U2 review nice-to-have 5): the ONE
place the raw-word defuns' param counts are declared, beside the `rawAbi`
set above (which keys are word-ABI) — the two tables are the convention.
Checked by Mid.Qbe.Lower against the defun's ACTUAL params at lowerDefun
(a param added in U3-U5 without touching this record is a compile Err, not
a silent under-apply) and against the hand-wired generated call sites (the
die arm passes exactly 1 word, the halt arm 0).  The arity is an Int —
backend-neutral (the RESULT CLASS, `l` vs `w`, is a QBE fact and lives in
Mid.Qbe.Lower.rawAbiRetClass, not here).  Rt.main's 2 = argc + argv.
-}
rawAbiArity : Dict String Int
rawAbiArity =
    Dict.fromList
        [ ( "Rt.cStrEq", 2 )
        , ( "Rt.die", 1 )
        , ( "Rt.halt", 0 )
        , ( "Rt.main", 2 )
        , ( "Rt.frame-enter", 1 )
        , ( "Rt.frame-leave", 0 )
        , ( "Rt.frameBlock", 1 )
        , -- stage 6 B1: Rt.apply/Rt.apply-tail take the SAME 3 word params
          -- as the Zig seats (fslot, args, nargs) — the retarget site and
          -- lowerDefun both check this against the actual param count.
        ( "Rt.apply", 3 )
        , ( "Rt.apply-tail", 3 )
        , -- ZIGHOST Z1: the root registry's eight word-ABI defuns.
          ( "Rt.rootGrow", 0 )
        , ( "Rt.rootPush", 3 )
        , ( "Rt.rootPushPtr", 1 )
        , ( "Rt.rootPushValue", 1 )
        , ( "Rt.rootPushValueArray", 2 )
        , ( "Rt.rootPop", 0 )
        , ( "Rt.rootWatermark", 0 )
        , ( "Rt.rootPopTo", 1 )
        , -- stage 6 B1fix: the copyWords WORD pair — the wrapper takes 3 word
          -- params (dst, src, n), the loop 3 (dst, src, cnt).  Both checked
          -- against the actual param count at lowerDefun (rawAbiArityAgree).
        ( "Rt.copyWords", 3 )
        , ( "Rt.copyWordsGo", 3 )
        , -- stage 6 B2: Rt.tail-known takes the SAME 3 word params as the
          -- Zig seat (code, argblock, nargs); Rt.bounce takes 1 (the :ret
          -- pointer) — both checked against the actual param count at
          -- lowerDefun (rawAbiArityAgree).
        ( "Rt.tail-known", 3 )
        , -- Q1b stage 1: the tcall staging seat takes (argblock, nargs) — the
          -- block to copy and its arg count — and returns the buffer address.
          ( "Rt.stage-tail", 2 )
        , ( "Rt.bounce", 1 )
        , -- zighost Z2: the two vec-store writers take (vec, index, *Value) —
          -- three words, checked against both the defun and Lower's seam.
          ( "Rt.vecStorePlain", 3 )
        , ( "Rt.vecStoreYoung", 3 )
        , -- zighost Z3: the closure-cache seat takes the descriptor's address.
          ( "Rt.globalClosure", 1 )
        , -- stage 7A's die family (see the rawAbi set above): the message, and
          -- the two-part variant's prefix + name.
          ( "Rt.dieErr", 1 )
        , ( "Rt.hostDieErr", 2 )
        ]


{-| The MIDDRIVER seed (stage 6 U2): the rawAbi defuns reached from
LOWER-GENERATED call sites (not from an Rt body, so the used-prim census
cannot seed them — the `conSeeds`/`closureSeeds` precedent).  Seeded by
Lower when QBE_MIDDRIVER=1; transitively closed over `rtDeps` so Rt.die
pulls Rt.cStrLenGo.  The MIDGC collector reaches Rt.die through its own
`gcSeeds` closure (the gc* defuns' rtDeps edges), so the two hatches agree
on the same defun.
-}
driverSeeds : List String
driverSeeds =
    -- The B0 frame pair joins the seed roots: Lower's prologue/return
    -- retarget (QBE_MIDDRIVER=1) names q_Rt_x2eframeEnter/Leave directly, so
    -- the census cannot seed them — the driverSeeds precedent.  Rt.die is
    -- already a root; frame-leave's Rt.die edge is a closure edge, not a
    -- new root.
    keepRtDependencies
        [ "Rt.die"
        , "Rt.halt"
        , "Rt.main"
        , "Rt.frame-enter"
        , "Rt.frame-leave"
        , -- stage 6 B1: Lower's rtApply retarget (QBE_MIDDRIVER=1) names
          -- q_Rt_x2eapply/q_Rt_x2eapply_x2dtail directly, so the census
          -- cannot seed them — the frame-pair precedent.
        "Rt.apply"
        , "Rt.apply-tail"
        , -- stage 6 B2: Lower's directCall/bounce retarget (QBE_MIDDRIVER=1)
          -- names q_Rt_x2etail_x2dknown / q_Rt_x2ebounce directly, so the
          -- census cannot seed them — the tail-known/bounce pair joins the
          -- driverSeeds roots (Rt.bounceGo is a closure edge off Rt.bounce).
        "Rt.tail-known"
        , -- Q1b stage 1: the tcall staging seat, named directly by Lower's
          -- tcall arm — the same "the census cannot seed it" argument.
          "Rt.stage-tail"
        , "Rt.bounce"
        ]


-- THE SAFEPOINT WALKERS ARE TOP-LEVEL, NOT let-BOUND INSIDE `allocating`.
-- `safepoint` and `unsafeSafepoint` are MUTUALLY recursive (an unsafe
-- node's arms walk Exp children, and an Exp's `Unsafe` arm walks the
-- node), and the tree's OWN front end — the Mid lane, which compiles
-- this file in the selfhost/bootstrap emit — resolves `let` binders
-- STRICTLY IN ORDER: a forward reference inside a `let` is "unknown
-- name", where elm 0.19.2 accepts it.  MEASURED, not assumed: with
-- these let-bound, `tools/qbe-bootstrap.sh --freeze` died with
--   err type error at 239:21: unknown name: safepoint
-- i.e. the compiler could not compile itself and the bootstrap seed
-- could not be regenerated.  Top-level declarations are order-
-- independent in this lane (the parser modules already rely on it),
-- so the walkers live here.  Semantics are unchanged: the refactor is
-- pinned by the corpus byte-identity check (the emit must stay
-- identical to the frozen baseline).

-- the DIRECT safepoints: one walk per body, every constructor
-- handled (a future Mid.Ir node forces this walker's arm to exist,
-- which is the point of writing it over the tree instead of over a
-- hand-maintained key list).
direct : Defun -> Bool
direct d =
    case d.value of
        Lam l ->
            safepoint d.key (List.length l.params) l.body

        _ ->
            True

safepoint : String -> Int -> Exp -> Bool
safepoint selfKey selfArity e =
    case e of
        Lit (LString _) ->
            True

        Lit _ ->
            False

        Var _ ->
            False

        GRef _ ->
            True

        StreamRef _ ->
            True

        Lam _ ->
            True

        NoTail inner ->
            safepoint selfKey selfArity inner

        App app ->
            -- A SATURATED, NON-FORCED GRef-App on THIS defun's own key is
            -- an EDGE, not a direct safepoint, exactly like RawCall below.
            -- In TAIL position it is the SELF-TAIL LOOP (Lower's
            -- lowerSelfTail: stage the args into slots, blit the params,
            -- jmp @body — no call, no rt_tail_known, so no staging
            -- allocation at ANY arity); out of tail position it is the
            -- saturated direct call + rt_bounce chase, which allocate
            -- nothing themselves (the .tail staging allocation lives in
            -- rt_tail_known, the CROSS-defun tail path, never taken here).
            -- The args are walked; the callee is SELF, and a loop re-runs
            -- THIS body, so any allocation the body can reach is already
            -- caught by this very walk — no cycle is introduced.
            --
            -- EVERY OTHER SHAPE IS A DIRECT SAFEPOINT, deny-by-default:
            -- an UNDER-/OVER-applied head, or a forced one, routes
            -- lowerGRefValue + rtApply (Lower.elm lowerApp's GRef arm),
            -- and rt_apply BUILDS A PARTIAL CLOSURE (applyGo's env
            -- allocArray — a real GC safepoint) — so treating those as an
            -- edge would keep an allocating defun classified frame-free,
            -- the exact unsoundness the partition exists to prevent.  The
            -- arity is the walked Lam's OWN param count (always known
            -- here); had it been unavailable, the rule denies (safepoint)
            -- — the conservative direction.
            case app.fn of
                GRef r ->
                    if r.key == selfKey && not r.force && List.length app.args == selfArity then
                        List.any (safepoint selfKey selfArity) app.args

                    else
                        True

                _ ->
                    True

        PrimApp _ ->
            True

        Let b ->
            List.any (\v -> safepoint selfKey selfArity (letValue v)) b.binders || safepoint selfKey selfArity b.body

        Case c ->
            safepoint selfKey selfArity c.scrutinee || List.any (\alt -> List.any (safepointMatch) alt.matches || List.any (\( _, p ) -> safepointPath p) alt.binds || safepoint selfKey selfArity alt.body) c.alts

        Con _ ->
            True

        Tup _ ->
            True

        RecordLit _ ->
            True

        RecordGet root _ ->
            safepoint selfKey selfArity root

        RecordUpdate r ->
            safepoint selfKey selfArity r.base || List.any (\( _, v ) -> safepoint selfKey selfArity v) r.updates

        ListLit _ ->
            True

        If b ->
            safepoint selfKey selfArity b.cond || safepoint selfKey selfArity b.thenBranch || safepoint selfKey selfArity b.elseBranch

        ShortAnd b ->
            safepoint selfKey selfArity b.left || safepoint selfKey selfArity b.right

        ShortOr b ->
            safepoint selfKey selfArity b.left || safepoint selfKey selfArity b.right

        NotEqual b ->
            safepoint selfKey selfArity b.left || safepoint selfKey selfArity b.right

        Loop b ->
            -- (B4) both subtrees are ordinary code; Break/Continue allocate
            -- and call nothing at all.
            safepoint selfKey selfArity b.cond || safepoint selfKey selfArity b.body

        Break ->
            False

        Continue ->
            False

        Unsafe node ->
            unsafeSafepoint selfKey selfArity node

unsafeSafepoint : String -> Int -> UnsafeNode -> Bool
unsafeSafepoint selfKey selfArity node =
    case node of
        RawCall c ->
            -- edge, not a direct safepoint: the FIXED POINT below
            -- resolves it (a call to a non-allocating helper is
            -- allocation-free).
            List.any (safepoint selfKey selfArity) c.args

        RawCallRaw _ ->
            False

        RawCallExtern _ ->
            -- (cffi U2) a DECLARED C call: the callee is libc, and no C
            -- callee can move the MID heap — the same class RawCallRaw has.
            -- Marking it allocating would force every libc call into a
            -- mallocing frame (a performance cliff with no rooting reason),
            -- and the reason for changing this must be a MID-heap reason
            -- (a Mid-allocating seat), never a C-heap one (plan §10.2).
            False

        RawCallAgg _ ->
            -- CONSERVATIVELY ALLOCATING, deny-by-default: the callee is
            -- UNKNOWN GENERATED CODE (a runtime word — the stage-6
            -- apply/bounce port's Desc code pointer), so the node allocates
            -- nothing itself but its CALLEE can allocate, and an apply
            -- defun containing one must never classify frame-free (the
            -- stage-1 lesson: a False here silently misclassifies the
            -- apply defuns and hands them unrooted scratch across the
            -- callee's collection).
            True

        RawTagOf _ ->
            False

        RawPayload p ->
            safepoint selfKey selfArity p.value

        RawMkValue m ->
            List.any (safepoint selfKey selfArity) m.words

        RawAllocVector _ ->
            True

        RawVecLoad v ->
            safepoint selfKey selfArity v.vec || safepoint selfKey selfArity v.index

        RawVecAddr v ->
            safepoint selfKey selfArity v.vec || safepoint selfKey selfArity v.index

        RawVecStore v ->
            -- the write-barrier seat is malloc-class, NOT a GC
            -- safepoint (MEASUREDED in heap.zig dirtyVectorsAdd;
            -- the consspike record), so the store alone does not
            -- frame a defun — address-> stores into an existing
            -- vector frame-free.
            safepoint selfKey selfArity v.vec || safepoint selfKey selfArity v.index || safepoint selfKey selfArity v.value

        RawStrByte b ->
            safepoint selfKey selfArity b.str || safepoint selfKey selfArity b.index

        WithRoots _ ->
            True

        RawPayload32 p ->
            safepoint selfKey selfArity p.value

        RawTagIs t ->
            safepoint selfKey selfArity t.value

        RawBin r ->
            safepoint selfKey selfArity r.a || safepoint selfKey selfArity r.b

        RawUn r ->
            safepoint selfKey selfArity r.v

        RawCmp r ->
            safepoint selfKey selfArity r.a || safepoint selfKey selfArity r.b

        RawFltBin r ->
            safepoint selfKey selfArity r.a || safepoint selfKey selfArity r.b

        RawFltCmp r ->
            safepoint selfKey selfArity r.a || safepoint selfKey selfArity r.b

        RawIToF x ->
            safepoint selfKey selfArity x

        RawLoadFlt x ->
            safepoint selfKey selfArity x

        RawAllocRaw _ ->
            True

        RawByteLoad b ->
            safepoint selfKey selfArity b.ptr || safepoint selfKey selfArity b.index

        RawByteStore b ->
            safepoint selfKey selfArity b.ptr || safepoint selfKey selfArity b.index || safepoint selfKey selfArity b.value

        RawWordLoad w ->
            safepoint selfKey selfArity w.ptr || safepoint selfKey selfArity w.index

        RawWordStore w ->
            safepoint selfKey selfArity w.ptr || safepoint selfKey selfArity w.index || safepoint selfKey selfArity w.value

        RawMemLoad m ->
            -- cffi U6: a width-typed load allocates nothing.
            safepoint selfKey selfArity m.ptr

        RawMemStore m ->
            -- cffi U6: a width-typed store allocates nothing; the VALUE still
            -- rides through (a sibling operand may itself allocate).
            safepoint selfKey selfArity m.ptr || safepoint selfKey selfArity m.value

        RawDataAddr _ ->
            False

        RawCStr _ ->
            -- (stage 6 U2) a static data-def address — no allocation, no
            -- safepoint (the def is content-keyed static data, never moved).
            False

        RawSym _ ->
            -- (stage 6 A1b) a static FUNCTION-symbol address — like RawCStr,
            -- no allocation and no safepoint (a code label is never moved).
            False

        RawAllocN _ ->
            -- (B4) STACK storage: the block is carved from the current frame,
            -- touches no heap, triggers no collection and holds no Value the
            -- collector scans.  NOT a safepoint — which is also why a defun
            -- whose only allocation is a cell can keep the frame-free lean
            -- ABI (its liveness never has to be spilled to a root array).
            False

letValue : LetBinder -> Exp
letValue b =
    case b of
        LetBind bind ->
            bind.value

        LetDestruct d ->
            d.value

safepointMatch : Match -> Bool
safepointMatch m =
    False

safepointPath : ValuePath -> Bool
safepointPath p =
    case p of
        VPath _ ->
            False

        VField _ _ ->
            True
