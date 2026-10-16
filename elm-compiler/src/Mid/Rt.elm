module Mid.Rt
    exposing
        ( Impl
        , allocating
        , closureSeeds
        , conSeeds
        , direct
        , driverSeeds
        , externArities
        , gcSeeds
        , program
        , programGc
        , programPair
        , primImpl
        , activeSurf
        , rawAbi
        , rawAbiArity
        , rtDeps
        , seeds
        , spliceSurface
        , surf
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
-- (Since T7 this module ALSO imports the Mid.RtLang.* surface front end and
-- Mid.RtSource, which are backend-neutral by the same contract: Ast/Parse/
-- Check read only Ast + the vendored ParserFast (already in the seed — it is
-- the front end's own parser) and LowerToIr reads only Mid.Ir.)
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
import Mid.RtSource
import Set exposing (Set)


{-| The Rt program: every Mid-implemented runtime defun — the DSL-built
lists (`primDefuns`/`helperDefuns`) with any SURFACE defuns spliced into
their list positions (T7, handoff-osier-tier2-midlang-plan THE INJECTION
PATH).  Injected whole by QbeModule; Lower keeps only the SEEDED (used)
subset.  `consArr` selects the cons representation (QBE_NOCONSARR=1 ->
False = the pre-(A) two-word cons).

RESULT-VALUED (T7): `program` runs the surface pipeline
(`Mid.RtSource.source` -> Parse -> Check -> LowerToIr) and can FAIL.  A
silently-empty or silently-reduced runtime is the worst failure mode, so
the Err is real: Mid.QbeModule routes it through the compile's existing
error plumbing and EVERY compile fails loudly on a bad surface text.

T18: the splice domain is the WHOLE DSL program — `primDefuns` ++
`helperDefuns` ++ `gcProgram` — so the surface can replace collector
defuns too.  `program` is the PRIM/HELPER half of that splice (the same
list it always returned); `programPair` splits the spliced result into
the two halves QbeModule consumes (the gc half is emitted only under
QBE_MIDGC=1) and `programGc` is the gc half alone.
-}
program : Bool -> Bool -> Bool -> Result String (List Defun)
program consArr rec eqPtrFast =
    Result.map Tuple.first (programPair consArr rec eqPtrFast)


{-| The whole splice (T18): ONE `surf` evaluation (the compile path runs
this twice per compile — QbeModule's injection and `allocating` — exactly
as before T18), spliced over the UNION of the three DSL lists so
`spliceSurface`'s orphan check stays total over every surface key, then
split back into the two halves the injection consumes.  The split is
`List.partition` by the gc key set — MEASURED STABLE (elm/core 1.0.5:
foldr + cons, original order preserved on both sides), which is what
keeps the gc half in `gcProgram`'s exact list order (order is .ssa
bytes).  No gc key exists outside `gcProgram` and no prim/helper key
inside it, so the two halves are exactly the old two lists, each with
its surface replacements in place.

T25: an APPENDED (new) surface key is never in `gcKeys` — `gcKeys` is the
raw `gcProgram` key set (the 12 collector seats, MEASURED) and a key with
no DSL position is not one of them — so every appended defun lands at the
END of the prim half and `programGc`'s output is byte-identical to the
pre-T25 gc half.  The appended group's relative order is fixed by
`spliceSurface` (ascending by key) and preserved here by the same
order-preserving partition.
-}
programPair : Bool -> Bool -> Bool -> Result String ( List Defun, List Defun )
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


{-| The GC half of the splice (T18): `gcProgram` with any surface-migrated
collector defuns replaced at their list positions.  Emitted by QbeModule
only under QBE_MIDGC=1; TestMain's gc rows read it (the DSL seats left
behind by the migration are tripwires, never the live bodies).
-}
programGc : Bool -> Bool -> Bool -> Result String (List Defun)
programGc consArr rec eqPtrFast =
    Result.map Tuple.second (programPair consArr rec eqPtrFast)


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


{-| The surface text, PARSED ONCE PER PROCESS.  A top-level VALUE is the
Elm runtime's once-per-process memoization — MEASURED in the generated JS
(test-compiler.js: a top-level constant compiles to a plain `var`,
evaluated once at module load; a function like `program` compiles to `F3`
and is not memoized per flags).  Cost note (plan R4): the pipeline
therefore parses once per process even under QBE_NOMIDRT=1, while
check+lower re-run per `program` call (twice per compile: QbeModule's
injection and `allocating`'s fixed point below).
-}
parsedSource : Result String RtAst.Program
parsedSource =
    Mid.RtLang.Parse.parseProgram (String.join "\n" Mid.RtSource.source)


{-| The surface AST's declared arities: (key, param count) per defun,
guard variants included (they share one key and never differ in arity —
TestMain's T7 flag-stable row pins that).  A MIGRATED key's entry lives
HERE once its DSL builder is deleted (T8's six first), so the extern
table stays total over the Rt call graph and the T7 safety net keeps its
arity witness.  NO VALUE CYCLE: `parsedSource` is parse-only — it does
not touch `externArities` the way `surf` does.
-}
surfaceSigs : List ( String, Int )
surfaceSigs =
    case parsedSource of
        Ok ast ->
            List.map (\d -> ( d.key, List.length d.params )) ast

        Err _ ->
            []


{-| J2's extern/arity table, beside `rtDeps`: every Rt key a surface defun
may `call` while that key is still DSL-built.  Derived from the DSL program
plus the surface AST's declared arities (`surfaceSigs` above) rather than
hand-written beside `rtDeps` — a second hand table would be exactly the
arity-skew hazard (plan R5) — and the derivation is pinned flag-stable by
TestMain's T7 rows.  The DSL entries come LAST in the `fromList` fold, so
for a key defined on BOTH sides the DSL arity wins: a surface defun whose
Lam arity drifts from the DSL arity it replaced is a TestMain FAIL.
`resolveCall` prefers a surface signature, so a migrated key's entry here
is the shadowed witness the safety-net row reads.
-}
externArities : Dict String Int
externArities =
    Dict.fromList
        (surfaceSigs
            ++ List.map (\d -> ( d.key, lamArity d ))
                (primDefuns True True True ++ helperDefuns True ++ gcProgram)
        )


lamArity : Defun -> Int
lamArity d =
    case d.value of
        Lam l ->
            List.length l.params

        _ ->
            0


{-| The ACTIVE surface defuns for one flag combo, keyed for the splice.
Parse is the per-process `parsedSource`; check and lower run here (they
are flag-dependent: J8's exactly-one-active judgment reads the flag set).
The check has ALREADY run when `activeSurf` filters the positionally
paired `ast`/`lowered` lists by the active flags (see `activeSurf` for
why the pairing is positional, not key-keyed).
-}
surf : List RtAst.Flag -> Result String (Dict String Defun)
surf flags =
    case parsedSource of
        Err msg ->
            Err msg

        Ok ast ->
            case RtCheck.checkProgram externArities flags ast of
                Err msg ->
                    Err msg

                Ok () ->
                    case Mid.RtLang.LowerToIr.lowerProgram ast of
                        Err msg ->
                            Err msg

                        Ok lowered ->
                            Ok
                                (activeSurf flags (List.map2 Tuple.pair ast lowered))


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
LOUDLY in Lower's rawCall arm; and `externArities` covers every surface key
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
        [ "Rt.die"
        , "Rt.halt"
        , "Rt.main"
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
        [ ( "Rt.die", 1 )
        , ( "Rt.halt", 0 )
        , ( "Rt.main", 2 )
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
    keepRtDependencies [ "Rt.die", "Rt.halt", "Rt.main" ]


{-| The Rt defuns whose execution can reach a GC SAFEPOINT — the fact the
lean ABI (handoff osier-midabi) frames its callees on.  A defun in this set
keeps the pooled, ROOTED frame (`rt_frame_enter`'s zeroed+rooted block);
every other Rt defun lowers frame-FREE (a plain `alloc8` scratch block,
never registered as a root), which is sound exactly because no allocation —
and therefore no collection — can happen anywhere in its execution.

WHAT COUNTS AS A SAFEPOINT, by constructor, at the node (not by guessing
which prims allocate):
  * `RawAllocVector` / `RawAllocRaw` — the two allocating node forms (the
    Mid.Ir contract: every other node is allocation-free or routes its
    allocation through one of these);
  * `WithRoots` — the tree's OWN statement that a collection may act on
    this body, independent of what it contains today;
  * `Lit LString` — lowered through `rt_string`, an interning seat that can
    allocate (number/float/boolean/symbol literals are inline immediates —
    a symbol's name is static data, never GC-allocated);
  * every SURFACE construct that builds or allocates (`App`, `PrimApp`,
    `Con`, `Tup`, `RecordLit`, `RecordUpdate`, `ListLit`, `Lam`, `GRef`,
    `StreamRef`) — none exists in an Rt body today, and each is classified
    conservatively so a future RtPrims body that gains one lands FRAMED,
    not silently unrooted;
  * `RawCall` edges — closed transitively over `rtDeps` (the same edge
    table `seeds` closes; TestMain pins that every RawCall target is
    declared in it), so a caller of an allocating helper is itself
    allocating.  THIS IS THE LOAD-BEARING RULE: a frame-free defun that
    raw-called an allocating one would read the caller's unrooted scratch
    block across the callee's collection.
-}
allocating : Set String
allocating =
    let
        -- The cons representation does not change which Rt defuns allocate
        -- (cons is allocating either way), and neither does the equality
        -- fast path (it adds a pointer compare, no safepoint), so the set is
        -- computed over the default program (consArr = True, rec = True,
        -- eqPtrFast = True).  T18: the gc half is the SPLICED half — after
        -- the migration the surface bodies are the live trees; reading the
        -- DSL `gcProgram` here would classify the seats' tripwire bodies.
        rtProgram =
            case programPair True True True of
                Ok ( primHalf, gcHalf ) ->
                    primHalf ++ gcHalf

                Err _ ->
                    -- UNREACHABLE on a live compile (T7): `programPair`'s Err
                    -- aborts the compile in Mid.QbeModule's injection before
                    -- Lower/classification could read this set — the fixed
                    -- point below only needs the defun LIST.
                    []

        -- (zigretire stage 3 GROUP 3B-2a) THE MANUAL OVERRIDE IS GONE (3B-2c
        -- deleted the rt_exec_run C seat): Rt.exec-plan no longer needs a
        -- walker-blind override because its callee Rt.exec-run allocates
        -- DIRECTLY in Mid (RawAllocRaw + the intern literals + the cons
        -- tree), so the fixed point reaches Rt.exec-plan over the
        -- rtDeps edge and roots its plan Value param the same way.

        -- fixed point: k allocates iff k has a DIRECT safepoint or any
        -- rtDeps edge of k lands in the set.
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
