module Mid.Rt exposing (Impl, allocating, program, primImpl, rtDeps, seeds)

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
import Mid.RtPrims exposing (helperDefuns, primDefuns)
import Set exposing (Set)


{-| The Rt program: every Mid-implemented runtime defun.  Injected whole by
QbeModule; Lower keeps only the SEEDED (used) subset.
-}
program : List Defun
program =
    primDefuns ++ helperDefuns


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
                        program
            in
            if Set.size new == Set.size acc then
                acc

            else
                grow new
    in
    grow (Set.fromList (List.filter direct program |> List.map .key))



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
            safepoint l.body

        _ ->
            True

safepoint : Exp -> Bool
safepoint e =
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
            safepoint inner

        App _ ->
            True

        PrimApp _ ->
            True

        Let b ->
            List.any (\v -> safepoint (letValue v)) b.binders || safepoint b.body

        Case c ->
            safepoint c.scrutinee || List.any (\alt -> List.any (safepointMatch) alt.matches || List.any (\( _, p ) -> safepointPath p) alt.binds || safepoint alt.body) c.alts

        Con _ ->
            True

        Tup _ ->
            True

        RecordLit _ ->
            True

        RecordGet root _ ->
            safepoint root

        RecordUpdate r ->
            safepoint r.base || List.any (\( _, v ) -> safepoint v) r.updates

        ListLit _ ->
            True

        If b ->
            safepoint b.cond || safepoint b.thenBranch || safepoint b.elseBranch

        ShortAnd b ->
            safepoint b.left || safepoint b.right

        ShortOr b ->
            safepoint b.left || safepoint b.right

        NotEqual b ->
            safepoint b.left || safepoint b.right

        Unsafe node ->
            unsafeSafepoint node

unsafeSafepoint : UnsafeNode -> Bool
unsafeSafepoint node =
    case node of
        RawCall c ->
            -- edge, not a direct safepoint: the FIXED POINT below
            -- resolves it (a call to a non-allocating helper is
            -- allocation-free).
            List.any safepoint c.args

        RawCallRaw _ ->
            False

        RawTagOf _ ->
            False

        RawPayload p ->
            safepoint p.value

        RawMkValue m ->
            List.any safepoint m.words

        RawAllocVector _ ->
            True

        RawVecLoad v ->
            safepoint v.vec || safepoint v.index

        RawVecAddr v ->
            safepoint v.vec || safepoint v.index

        RawVecStore v ->
            -- the write-barrier seat is malloc-class, NOT a GC
            -- safepoint (MEASUREDED in heap.zig dirtyVectorsAdd;
            -- the consspike record), so the store alone does not
            -- frame a defun — address-> stores into an existing
            -- vector frame-free.
            safepoint v.vec || safepoint v.index || safepoint v.value

        RawStrByte b ->
            safepoint b.str || safepoint b.index

        WithRoots _ ->
            True

        RawPayload32 p ->
            safepoint p.value

        RawTagIs t ->
            safepoint t.value

        RawBin r ->
            safepoint r.a || safepoint r.b

        RawUn r ->
            safepoint r.v

        RawCmp r ->
            safepoint r.a || safepoint r.b

        RawFltBin r ->
            safepoint r.a || safepoint r.b

        RawFltCmp r ->
            safepoint r.a || safepoint r.b

        RawIToF x ->
            safepoint x

        RawLoadFlt x ->
            safepoint x

        RawAllocRaw _ ->
            True

        RawByteLoad b ->
            safepoint b.ptr || safepoint b.index

        RawByteStore b ->
            safepoint b.ptr || safepoint b.index || safepoint b.value

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
