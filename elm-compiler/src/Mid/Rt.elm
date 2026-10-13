module Mid.Rt exposing (Impl, allocating, closureSeeds, conSeeds, direct, gcSeeds, program, primImpl, rtDeps, seeds)

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
import Mid.RtPrims exposing (helperDefuns, primDefuns)
import Set exposing (Set)


{-| The Rt program: every Mid-implemented runtime defun.  Injected whole by
QbeModule; Lower keeps only the SEEDED (used) subset.  `consArr` selects the
cons representation (QBE_NOCONSARR=1 -> False = the pre-(A) two-word cons).
-}
program : Bool -> Bool -> Bool -> List Defun
program consArr rec eqPtrFast =
    primDefuns consArr rec eqPtrFast ++ helperDefuns rec


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
        , ( "Rt.gcAlloc", [ "Rt.gcAllocGo", "Rt.collect" ] )
        , ( "Rt.gcAllocGo", [ "Rt.gcAllocGo" ] )
        , ( "Rt.gcInit", [] )
        , ( "Rt.collect", [ "Rt.gcMarkRoots", "Rt.gcDrain", "Rt.gcSweep" ] )
        , ( "Rt.gcMarkRoots", [ "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkPtr", "Rt.gcMarkValue" ] )
        , ( "Rt.gcScanValueArray", [ "Rt.gcScanValueArray", "Rt.gcMarkValue" ] )
        , ( "Rt.gcDrain", [ "Rt.gcDrain", "Rt.gcScanValueArray" ] )
        , ( "Rt.gcSweep", [ "Rt.gcSweep" ] )
        , ( "Rt.gcMarkPtr", [] )
        , ( "Rt.gcMarkValue", [ "Rt.gcMarkPtr" ] )
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
        -- cStrFill/cStrLenGo/cStrCopyGo recurse through `App` on their OWN
        -- key (the SF2 fix: App self-tail = the in-frame loop on the
        -- DEFAULT route; the RawCall self-tail is midGc-gated), so they
        -- name NO RawCall edge — no entries here.  A future revert to
        -- callR fails TestMain's rt-call-graph check loudly, by design.
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
        -- eqPtrFast = True).
        rtProgram =
            program True True True ++ gcProgram

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
