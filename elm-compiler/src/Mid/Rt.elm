module Mid.Rt
    exposing
        ( Impl
        , Runtime
        , UserModule
        , checkLowerUserModule
        , load
        , parseUserModule
        , closureSeeds
        , conSeeds
        , driverSeeds
        , gcSeeds
        , primImpl
        , activeSurf
        , rawAbi
        , rawAbiArity
        , rtDeps
        , seeds
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
-- arrives as `load`'s argument — read from elm-compiler/runtime.mid by the
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
    }


load : String -> Result String Runtime
load source =
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
                -- lower run here (flag-dependent).
                surf flags =
                    case RtCheck.checkProgram externTypes flags ast of
                        Err msg ->
                            Err msg

                        Ok () ->
                            case Mid.RtLang.LowerToIr.lowerProgram ast of
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

                        -- fixed point: k allocates iff k has a DIRECT
                        -- safepoint or any rtDeps edge of k lands in the set.
                        grow : Set String -> Set String
                        grow acc =
                            let
                                new =
                                    List.foldl
                                        (\d set ->
                                            case Dict.get d.key rtDeps of
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
                        }


-- ============================ USER .mid modules (M3) ============================


{-| One user `.mid` module, checked and lowered (M3).  `name` is the module
header's name — the namespace every key is qualified by; `exports` the
export block (the declared types M4 checks against); `defuns` the
LOWERED Mid.Ir defuns, keyed `<name>.<fn>`, ready to be appended to the
program by the caller (QbeModule) through the SAME splice path the
runtime uses (T25's ADD arm — a user key has no DSL position).
-}
type alias UserModule =
    { name : String
    , exports : List RtAst.Export
    , defuns : List Defun
    }


{-| Parse a USER `.mid` module and enforce the NAMESPACE RULE (the module
NAME from the header qualifies every key): a user module must carry a
`module Name` header, and every defun/export key must be spelled
`Name.<fn>`.  The `Rt.*`-only shape check lives in `Check.keyCheck`
(generalized M3); THIS is the ownership half — the prefix must be the
module's OWN name, so two modules can never silently share a key through
a typo'd prefix.  Returns the parsed name/exports/ast for the caller to
build the cross-module extern table before the check+lower pass.
-}
parseUserModule : String -> Result String ( String, List RtAst.Export, RtAst.Program )
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
                                    Ok ( name, module_.header.exports, module_.defuns )


{-| Check + lower a PARSED user module against the given extern table — the
SAME pipeline as `runtime.mid` (`Check.checkExports` -> `Check.checkProgram`
-> `LowerToIr.lowerProgram`), with the runtime's own `surf` path.  `externs`
is the typed extern table the module's `call` sites resolve against: the
caller (QbeModule) supplies the runtime's EXPORTED keys (`exportedTypes` — the
M3fix privacy boundary) UNION every group user module's exports, so a user
module may `call Rt.<exported>` or another user module's exported defun at the
CHECKER (J2).  Flags are `[]`: user modules carry no `@flag` guards (those are
the runtime's internal switches).
-}
checkLowerUserModule : Dict String RtAst.ExportSig -> ( String, List RtAst.Export, RtAst.Program ) -> Result String UserModule
checkLowerUserModule externs ( name, exports, ast ) =
    let
        arities =
            Dict.fromList (List.map (\d -> ( d.key, List.length d.params )) ast)
    in
    RtCheck.checkExports exports arities
        |> Result.andThen (\_ -> RtCheck.checkProgram externs [] ast)
        |> Result.andThen (\_ -> Mid.RtLang.LowerToIr.lowerProgram ast)
        |> Result.map
            (\defuns ->
                { name = name
                , exports = exports
                , defuns = defuns
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
        , ( "Rt.dgs", [ "Rt.dgs", "Rt.cons" ] )
        , ( "Rt.revGo", [ "Rt.revGo", "Rt.cons" ] )
        , ( "Rt.bytesOf", [ "Rt.bytesOf", "Rt.cons" ] )
        , ( "Rt.appendL", [ "Rt.revGo" ] )
        , ( "Rt.numText", [ "Rt.dgs", "Rt.revGo", "Rt.bytesToStr", "Rt.cons" ] )
        , ( "Rt.bytesToStr", [ "Rt.countL", "Rt.fillGo" ] )
        , ( "Rt.countL", [ "Rt.countL" ] )
        , ( "Rt.fillGo", [ "Rt.fillGo" ] )
        , ( "Rt.cn", [ "Rt.cn2", "Rt.strOf" ] )
        , ( "Rt.cn2", [ "Rt.bytesToStr", "Rt.appendL", "Rt.bytesOf" ] )
        , ( "Rt.strOf", [ "Rt.numText", "Rt.symToStr" ] )
        , ( "Rt.symToStr", [ "Rt.bytesToStr", "Rt.nameBytes", "Rt.cons" ] )
        , ( "Rt.nameBytes", [ "Rt.nameBytes", "Rt.cons" ] )
        , ( "Rt.assoc", [ "Rt.assocGo" ] )
        , ( "Rt.assocGo", [ "Rt.assocGo", "Rt.deepEq" ] )
        , ( "Rt.substring", [ "Rt.bytesToStr", "Rt.subGo" ] )
        , ( "Rt.subGo", [ "Rt.subGo", "Rt.cons" ] )
        , ( "Rt.repeat", [ "Rt.bytesToStr", "Rt.repGo" ] )
        , ( "Rt.repGo", [ "Rt.repGo", "Rt.appendL", "Rt.bytesOf" ] )
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
        , ( "Rt.gcAlloc", [ "Rt.gcAllocGo", "Rt.collect", "Rt.die" ] )
        , ( "Rt.gcAllocGo", [ "Rt.gcAllocGo" ] )
        , ( "Rt.gcInit", [ "Rt.die" ] )
        , ( "Rt.collect", [ "Rt.gcMarkRoots", "Rt.gcDrain", "Rt.gcSweep", "Rt.die" ] )
        , ( "Rt.gcMarkRoots", [ "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkPtr", "Rt.gcMarkValue", "Rt.die" ] )
        , ( "Rt.gcScanValueArray", [ "Rt.gcScanValueArray", "Rt.gcMarkValue" ] )
        , ( "Rt.gcDrain", [ "Rt.gcDrain", "Rt.gcScanValueArray" ] )
        , ( "Rt.gcSweep", [ "Rt.gcSweep" ] )
        , ( "Rt.gcMarkPtr", [ "Rt.die" ] )
        , ( "Rt.gcMarkValue", [ "Rt.gcMarkPtr", "Rt.die" ] )
        , -- ===== the Mid ADT constructor (zigretire stage 5)
          ( "Rt.con", [ "Rt.conFill" ] )
        , ( "Rt.conFill", [ "Rt.conFill" ] )
        , -- ===== the Mid closure (zigretire stage 5 PART 2)
          ( "Rt.closure", [ "Rt.closureFill" ] )
        , ( "Rt.closureFill", [ "Rt.closureFill" ] )
        , -- ===== the fd prims (zigretire stage 3 GROUP 1)
          ( "Rt.write-byte", [] )
        , ( "Rt.read-byte", [ "Rt.readFull" ] )
        , ( "Rt.open", [ "Rt.=", "Rt.cStrFill" ] )
        , ( "Rt.close", [] )
        , -- readFull recurses only on the EINTR RETRY (one frame per retry,
          -- bounded by signal frequency, not by data length) — callR is fine.
        ( "Rt.readFull", [ "Rt.readFull" ] )
        , -- ===== the VM-state + str prims (zigretire stage 3 GROUP 2)
          ( "Rt.str", [ "Rt.floatCopy", "Rt.numText" ] )
        , ( "Rt.floatCopy", [ "Rt.floatCopy" ] )
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
        -- DEFAULT route; the RawCall self-tail is midGc-gated), so they
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
        , -- ===== the stage-6 A4a arg loop.  Rt.parseArgsGo is a frame-free
          -- val defun (self-tail via recur) whose only seat calls are the
          -- rawcall rt_parse_arg (RawCallRaw — NOT an rtDeps edge); it names
          -- no Rt RawCall target, so its edge list is empty (the cStrLenGo/
          -- cStrEqGo [] precedent).
          ( "Rt.parseArgsGo", [] )
        , -- ===== the stage-6 A3a driver entry.  Rt.main is a rawAbi defun
          -- (WORD argc/argv in, WORD exit-code out) reached from
          -- driverSeeds; its RawCall edges are Rt.cStrLenGo (the three
          -- not-in-meta writes' lengths), Rt.metaGo (the meta walk) and
          -- Rt.parseArgsGo (the A4a arg loop).  The usage/toomany error paths
          -- reached cStrLenGo before A3b; A3b adds the meta-walk edge, A4a
          -- the arg loop.  Everything else it reaches is a rawcall
          -- (write/exit/getenv/getrlimit/setrlimit/malloc/rt_boot/
          -- rt_parse_arg/rt_argv_install/rt_root_push_value_array +
          -- A4b's rt_root_push_value/rt_is_program/rt_run_program/
          -- rt_print_value) or a rawstr/rawsym static def — neither is an
          -- rtDeps edge.
          ( "Rt.main", [ "Rt.cStrLenGo", "Rt.metaGo", "Rt.parseArgsGo" ] )
        , -- ===== the stage-6 B0 frame machinery.  Rt.frame-enter's RawCall
          -- edges are its two helpers; Rt.frame-leave's only edge is Rt.die
          -- (the no-frame panic — Rt.die is already a driverSeed, so this is
          -- a closure edge, not a new root).  Rt.frameBlock (malloc + the
          -- freelist pop, all rawcall/raw-word) and Rt.frameZero (self-tail
          -- via recur, SLOT-granularity (5 words/iter) no-alloc zeroing — no
          -- RawCall edge, the cStrFill/[] precedent) name no Rt target.  The
          -- rt_root_push_value_array/rt_root_watermark/rt_root_pop_to calls
          -- are rawcall (RawCallRaw — NOT rtDeps edges).
          ( "Rt.frame-enter", [ "Rt.frameBlock", "Rt.frameZero" ] )
        , ( "Rt.frame-leave", [ "Rt.die" ] )
        , ( "Rt.frameBlock", [] )
        , ( "Rt.frameZero", [] )
        , -- ===== the stage-6 B1 apply family.  Rt.apply/Rt.apply-tail are
          -- rawAbi WRAPPERS (root the caller's f/args, then hand off); their
          -- one RawCall edge each is the val-ABI LOOP.  The loops reach
          -- Rt.callArity (the 17-arm rt_callN dispatch + rt_bounce) and
          -- Rt.copyWords (the raw-word Value-array copy) and Rt.die (the
          -- non-function/closure-env panics — already a driverSeed, so these
          -- are closure edges, not new roots).  rt_callN/rt_bounce are
          -- aggcall (RawCallAgg — NOT rtDeps edges); malloc/rt_root_* are
          -- rawcall (RawCallRaw — NOT rtDeps edges).
          ( "Rt.apply", [ "Rt.applyGo" ] )
        , ( "Rt.apply-tail", [ "Rt.applyTailGo" ] )
        , ( "Rt.applyGo", [ "Rt.callArity", "Rt.copyWords", "Rt.die" ] )
        , ( "Rt.applyTailGo", [ "Rt.callArity", "Rt.copyWords", "Rt.die" ] )
        , ( "Rt.callArity", [] )
        , ( "Rt.copyWords", [] )
        ]


keepRtDependencies : List String -> List String
keepRtDependencies roots =
    let
        step : List String -> List String -> List String
        step acc queue =
            case queue of
                [] ->
                    List.reverse acc

                key :: rest ->
                    if List.member key acc then
                        step acc rest

                    else
                        case Dict.get key rtDeps of
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


{-| THE RAW-WORD DEFUN CONVENTION (stage 6 U2, plan obs-4): the Rt keys that
lower with a WORD calling convention instead of the lean `:val` ABI — their
defuns emit `(params Base L, ret Base L/W)` and every caller (Lower-generated
sites AND surface `call` sites) emits a matching WORD call.  The set is the
ONE place Lower and the program builder agree on which keys are word-ABI;
`driverSeeds` (below) is the seed list, `seeds`/`gcSeeds`/`conSeeds`/
`closureSeeds` are the `:val` ones.  U2 carries the two smallest consumers
(Rt.die: one WORD param, Rt.halt: zero) to prove the convention; U3-U5 add
the frame/apply/driver family.
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
          -- path.  Rt.frameZero is a :val SLOT loop (the zero-before-root
          -- memset — `recur` needs the val self-tail loop, which the rawAbi
          -- tail rejects; five words per iteration, the counter is a raw
          -- word in header slot 4 so the recur arg is CONSTANT and the loop
          -- allocates nothing), NOT rawAbi.
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
