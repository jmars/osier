module Mid.Qbe.Lower exposing (lower)

-- Mid.Qbe.Lower — Mid.Ir -> Qbe.Il (native-backend stage 1; handoff-qbe-lower).
--
-- WHAT THIS SLICE LOWERS (everything else FAILS LOUDLY with a message naming
-- the construct — never a silent miscompile):
--   supported: Lit (all five), Var, App with a GRef head (saturated = direct
--     call; a saturated self-call in tail position = an in-frame loop; under/
--     over-application goes through rt_apply, exactly the VM's partial
--     semantics), GRef as a value (runtime closure), GRef force (0-arg thunk
--     = direct call), Let (plain LetBind only), If, 2-ary integer PrimApp
--     (`+ - * < <= > >= =` inline on the VM's exact semantics with an
--     rt_prim fallback for the float-promotion / non-numeric paths), and
--     inner Lam (closures with captures — the env representation crux).
--   stage 2 adds: Case (incl. inside a closure body), Con (ADT construction
--     as the VM's vector[tag, args]), the match steps MCons/MEmpty/MVector/
--     MTagEq/MLitEq with the ordered AltKind tests, and LetDestruct.
--   Tup (a cons chain) is lowered as the MINIMAL route to a real
--     destructuring-let fixture: this compiler's parser only accepts
--     irrefutable let-patterns (tuple/record/unit — a constructor pattern
--     `let Some v = o` is "err parse failed"), record is out of scope, and a
--     tuple pattern needs a Tup expression to construct.  It is NOT full
--     tuple coverage — it exists so LetDestruct has a binding-bearing shape.
--   stage 3 adds: RecordLit/RecordGet/RecordUpdate and ListLit (desugared to
--     the VM's own cons/@p/emptylist/assoc/snd prim sequences via rt_prim, so
--     representation parity is by construction), ShortAnd/ShortOr/NotEqual
--     (the VM's jmpf semantics), and non-ASCII string/symbol literals (UTF-8
--     encoded, byte-length correct).
--   stage 4 adds: StreamRef (stdin/stdout/stderr) — lowered EXACTLY like
--     Mid.ToZinc does (Symbol <varName> + Prim "value"), so the emitted code
--     reads the SAME value-table slot the VM reads; arity is now 0..maxArity
--     (16, raised from 8 — the rt_callN dispatch table and the runtime's
--     value buffers are the only bounds).  The effect loop itself is HOSTED
--     by tools/qbe/rt.zig (mirroring tools/aot/run.zig), not lowered here.
--   stage 5 adds: record FIELD PATTERNS (VField) — the only remaining
--     unsupported construct.  A field pattern is snd (assoc (sym field) rec)
--     exactly like RecordGet, reached via the same Step machinery; see
--     lowerPath.
--
-- ============================== THE CONTRACTS ==============================
--
-- CALLING CONVENTION (ABI-verified against the vendored qbe; see
-- docs/qbe-backend.md): a Value is the 40-byte aggregate `:val`; QBE passes
-- :val params as POINTERS and returns them through sret, exactly like a C
-- struct by value.  A function of arity N with K captures compiles to
--
--     function :ret $q_<mangled> [(env %env),] :val %a0 .. :val %a{N-1}
--
-- — it RETURNS the 80-byte `:ret` (`.done` value | `.tail` request) rather
-- than a bare `:val`, which is what carries the bounce loop (see TAIL CALLS
-- below).  (`env` only when K > 0 — QBE passes it in a register invisible to
-- C; the generated rt_callN dispatchers pass env to env-less top-level defuns
-- too, which just ignore it).  %a_i POINTS at the caller's staging copy; the
-- prologue blits each param into the frame before anything else can run.
--
-- GC ROOTING (crux 2): every local lives in a RUNTIME-POOLED frame block
-- from `rt_frame_enter(nslots) -> *Value`, registered as ONE
-- ROOT_VALUE_ARRAY for the whole body, popped by rt_frame_leave().  The
-- frame ADDRESS is an opaque call result, so QBE cannot promote a slot's
-- store/load pair into a callee-saved register (MEASURED on the vendored
-- qbe: a non-escaping stack slot's store+reload ARE deleted across a call;
-- the pooled-frame loop shape keeps them — evidence in the handoff node and
-- docs/qbe-backend.md).  Slot 0 = the `.done` value, slot 1 = the `.tail`
-- metadata (kind/f/e/args/arity — the second half of `:ret`), 2..N+1 params,
-- N+2..N+1+K captures, then expression temporaries.  A per-function GLOBAL
-- frame would also defeat promotion but CANNOT nest under recursion (a
-- callee would zero its caller's frame) — hence the pool.
--
-- CLOSURES (env representation crux): a first-class function is the VM's own
-- `.lambda` Value with `code` = a static Desc (the GC passes non-heap
-- pointers through unchanged — collect.zig gcMove — so a static descriptor
-- is never moved or scanned), `code_len` = REMAINING arity (partials are
-- plain Values), `env` = [applied args ++ captures] in one GC array.
-- rt_apply splits env at saturation: n_applied = desc.arity - code_len.
-- Creation sites copy captures into CONTIGUOUS frame slots and call
-- rt_make_closure(desc, capBase, K) — rt re-reads them AFTER its internal
-- allocations (the caller's rooted frame slots were GC-rewritten in place).
--
-- TAIL CALLS (crux 1): QBE IL has NO tail-call instruction (vendor/qbe/doc/
-- il.txt: `tail` appears only in "width less than a word"; the CALL BNF has
-- no tail form; jump targets are intra-function).  So:
--   * a saturated App to the SAME defun in tail position = an IN-FRAME LOOP:
--     args into temp slots, blit temps into the param slots, `jmp @body`.
--     This stays the hot path — generality must not cost it.
--   * every other tail position (cross-defun call, rt_apply, thunk force)
--     returns a `.tail` via the `:ret` aggregate and is chased by the runtime
--     bounce loop (tools/qbe/rt.zig rt_bounce) — the AOT's Ret/.tail pattern
--     (tools/aot/runtime.zig) transcribed onto this backend.  A `.done` is
--     kind 0 + the value; a `.tail` is kind 1 + (f, e, args, arity), built by
--     rt_tail_known / rt_apply_tail so its args survive rt_frame_leave.
--
-- NO SSA: temporaries are assigned freely; QBE builds SSA itself.

-- (Exp's Con variant is deliberately NOT exposed: Mid.Qbe.Il.Arg also has a
-- Il.Con (the integer-constant argument), and Elm cannot qualify constructors
-- in patterns — exposing only one of the two keeps the pattern arms clean.)
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), FfiWidth(..), Lambda, LetBinder(..), Lit(..), Match(..), MemWidth(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), Step(..), UnsafeNode(..), ValuePath(..))
import Mid.Rt as MidRt
import Mid.RtGc as RtGc
import Mid.RtLayout as RtLayout
import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (Module, Func, Block, Inst(..), Jump(..), Ty(..), AbiTy(..), BinOp(..), CmpOp(..), UnaryOp(..), LoadOp(..), StoreTy(..), CallArg(..), TypeDef, DataDef, DataItem(..))
import Mid.Qbe.Liveness as Liveness
import Set exposing (Set)
import Mid.Qbe.Types as QbeTypes
import Type.Representation as Rep
import Char.Extra exposing (utf8ByteLength)


-- THE LAYOUT IS DEFINED ONCE, IN Mid.RtLayout (handoff-osier-zigretire-plan
-- STAGE 2).  These are the names this module's ~3500 lines already used; each
-- one is now READ from that single definition rather than restated here, so
-- the emitted IL and the Zig runtime cannot describe different bytes.
-- sizeof(vm Value) = 40 (gc/types.zig), the `:val` aggregate.
vs : Int
vs =
    RtLayout.valSizeBytes


-- sizeof(:ret) = 80 (Il.retType): `{ :val, w, l, l, l, w }` = two pooled-frame
-- slots — slot 0 the finished value, slot 1 the .tail discriminator + payload.
rvs : Int
rvs =
    RtLayout.retSizeBytes


-- P5: the non-GC libc entries this emitter names as CALL TARGETS, i.e. the
-- ones a call may target without being a GC safepoint.  The list is EXACTLY
-- what the emitter emits: `free` (the :ret buffer release in a rawAbi @ret
-- block), a C-heap release that cannot run a collect or move the Mid heap.
-- NOTHING ELSE may join it without the same argument — every other target is
-- a `q_*` symbol resolved against Mid.Rt.allocating, an indirect call, or a
-- cffi extern, and those are all treated as safepoints (deny by default):
-- a GC seat reached from C would be invisible here.
libcNoCollect : Set String
libcNoCollect =
    Set.fromList [ "free" ]



-- VM ValTag numbers this lowering switches on (gc/types.zig ValTag order).
tagNumber : Int
tagNumber =
    RtLayout.tagNumber


tagBoolean : Int
tagBoolean =
    RtLayout.tagBoolean


tagFloat : Int
tagFloat =
    RtLayout.tagFloat


tagSymbol : Int
tagSymbol =
    RtLayout.tagSymbol


tagString : Int
tagString =
    RtLayout.tagString


tagCons : Int
tagCons =
    RtLayout.tagCons


tagNil : Int
tagNil =
    RtLayout.tagNil


tagVector : Int
tagVector =
    RtLayout.tagVector


tagRecord : Int
tagRecord =
    RtLayout.tagRecord


maxArity : Int
maxArity =
    RtLayout.maxArity



-- ============================ STATE ============================
-- One state record threads everything: block emission, temp/label/slot
-- supplies, the binder->slot scope, and module-level accumulation (extra
-- closure functions, data definitions).  Closures lower with a FRESH state
-- seeded from the enclosing one (datas/counters continue; blocks restart).


type alias S =
    { blocks : List Block -- completed blocks, REVERSED
    , curLabel : String
    , curBody : List Il.Inst -- REVERSED
    , tmp : Int
    , lbl : Int
    , slot : Int -- next frame slot to allocate
    , binderSlots : Dict Int Int -- binder id -> frame slot
    , rawInt : Dict Int Il.Arg -- binder id -> the RAW `l` operand holding it (S4)
    , rawFloat : Dict Int Il.Arg -- binder id -> the RAW `d` operand holding it (S4f)
    , rawWord : Dict Int Il.Arg -- binder id -> raw word temp (Rt raw nodes; see lowerRawArg)
    , intBinders : Set Int -- binder ids whose value IS an Int (S4; boxed or raw)
    , table : Dict String QbeTypes.Entry -- the S1 side table (S4 reads it)
    , rep : Bool -- S4's pass switch (QBE_NOREP=1 -> False)
    , primDirect : Bool -- A's switch (QBE_NOPRIMDIRECT=1 -> False)
    , midCons : Bool -- the Mid-cons route switch (QBE_MIDCONS=1 -> True)
    , rtLean : Bool -- the Rt LEAN ABI switch (osier-midabi; QBE_NORTLEAN=1 -> False)
    , rec : Bool -- E's switch (QBE_NOREC=1 -> False = the assoc-chain route)
    , consArr : Bool -- (A)'s switch (QBE_NOCONSARR=1 -> False = the 2-word cons)
    , typeSpec : Bool -- Unit B's switch (QBE_NOTYPESPEC=1 -> False = no binder-map type specialization)
    , midGcYoung : Bool -- GC NURSERY unit's hatch (QBE_MIDGC_YOUNG=1 -> the nursery's barrier seat + seeding)
    , funcs : List PendingFunc -- extra (closure) funcs, REVERSED
    , datas : List DataDef -- REVERSED
    , dataKeys : Dict String String -- content key -> data name (dedup)
    , dataN : Int
    , cloN : Int -- closure-name supply
    , binderN : Int -- E's synthetic-binder supply (negative ids; see freshBinder)
    , arities : Dict String Int
    , defuns : Dict String Defun
    , seeded : Set.Set String
    , defunKey : String -- the SELF-TAIL key ("" for closures — lowerApp's self-call check)
    , binderKey : String -- the BINDER-MAP key (the enclosing defun's key for closures, whose params' types live in ITS binder map)
    , qname : String
    , abi : Dict String (List Int) -- B6: the WORD-ABI class table (key -> per-param word widths); MEMBERSHIP is the ABI class
    , loops : List LoopFrame -- (B4) the ENCLOSING loops, innermost first: what a Break/Continue leaf resolves against
    , ptrRead : Set String -- VR1: the defuns that READ their params through the incoming `l` pointer (no entry blit); see ptrReadKeys
    , paramPtr : Dict Int Il.Arg -- VR1: binder id -> the incoming `l` pointer holding that param (ptrRead defuns only)
    , noCollect : Set String -- P5: the CALL SYMBOLS whose execution cannot reach a GC safepoint (Mid.Rt.allocating's complement + the non-collecting libc entries); a call to anything else is a safepoint
    , leafFree : Bool -- P5's A/B switch (QBE_NOLEAF=1 -> False = every surface defun keeps its pooled frame, i.e. the pre-P5 shape)
    }


{-| (B4) one enclosing loop's two block labels, as the `Loop` emission built
them.  `top` is the loop's ENTRY block — the condition test — so `continue`
re-evaluates the condition (and a `for`'s step has already been emitted into
the body before the leaf), and `exit` is the block after the loop.
-}
type alias LoopFrame =
    { top : String
    , exit : String
    }


{-| A generated function plus the prologue facts only known completely after
the body walk (frame size), plus driver facts (static arity, captures).
-}
type alias PendingFunc =
    { func : Func
    , nslots : Int
    , nparams : Int
    , ncaps : Int
    , pro : Pro
    , rawAbi : Bool -- RtRawWord (stage 6 U2): the prologue skips the param blits — the params live in `l` registers, not frame slots
    , ptrRead : Bool -- VR1: the prologue skips the param blits — the body reads them through the incoming `l` pointer
    , paramWidths : List Int -- B6: this defun's per-parameter word widths (a struct VALUE parameter is its layout size; the entry copy spills that many words)
    , entryKey : Maybe String -- Just key for top-level defuns (meta table)
    }


{-| How the function's frame base `%f` materializes (osier-midabi).  `PFrame`
is the pooled, ROOTED, ZEROED block from `rt_frame_enter` — the generic
closure ABI, and every body that can reach a GC safepoint.  `PAlloc` is the
lean frame-FREE arm: a plain `alloc8` scratch block (a COMPILE-TIME QBE frame
slot — vendor/qbe amd64/isel.c turns a constant-size alloc8 into Onop plus a
slot assignment), unzeroed and unregistered as a root, which is sound exactly
because the classification proved no safepoint is reachable in this body.
`PLeaf` is the SAME frame-free shape for a SURFACE defun (perf P5): it adds
the two things a surface defun needs that a lean one does not — slot 0 (the
`.done` result) and slot 1 (the `.done`/`.tail` marker of the 80-byte `:ret`)
are read by the RETURN path WITHOUT a tag test, which the pooled frame
supplied by being memset at enter, so a PLeaf prologue materializes those two
words with two 8-byte stores (see leafTailZero in withPrologue).
-}
type Pro
    = PFrame
    | PAlloc
    | PLeaf


{-| The Rt defun calling convention (stage 6 U2 extends the two lean arms
with the raw-word one).  `RtGeneric` is the generic closure ABI (`:val`
params, `:ret` result, rt_frame_enter — the whole Rt program under
QBE_NORTLEAN=1); `RtLeanRooted`/`RtLeanFree` are the lean ABI (osier-midabi,
3 pointer params + count, direct `:val` return) with a pooled ROOTED frame
or a frame-FREE `alloc8` scratch block; `RtRawWord` is the raw-word ABI
(plan obs-4): one `l` param per defun param, an `l` result, frame-FREE —
the shape the stage-6 driver/ABI defuns (Rt.die/Rt.halt, the frame pair,
the apply family, Rt.main) lower with.
-}
type RtAbi
    = RtGeneric
    | RtLeanRooted
    | RtLeanFree
    | RtRawWord


{-| The rawAbi RESULT class per key (stage 6 A1): Rt.die/Rt.halt return an
`l` word (the message pointer / the dead halt binder — both never read), and
Rt.main returns the exit CODE as a `w` word — what crt0 reads back from
`int main(argc, argv)`.  The ARITY is backend-neutral and lives in
Mid.Rt.rawAbiArity; the CLASS is a QBE fact, so it lives here beside the
convention's lowering.
-}
rawAbiRetClass : String -> AbiTy
rawAbiRetClass key =
    if key == "Rt.main" then
        Base W

    else if key == "Rt.apply" then
        -- stage 6 B1: Rt.apply returns the 40-byte `:val` (applyGo's
        -- `.done` value) through sret, exactly the rt_apply seat's C ABI.
        Agg "val"

    else if key == "Rt.apply-tail" then
        -- stage 6 B1: Rt.apply-tail returns the 80-byte `:ret` (`.done`
        -- value | `.tail` request) through sret — rt_apply_tail's C ABI.
        Agg "ret"

    else if key == "Rt.tail-known" then
        -- stage 6 B2: Rt.tail-known returns the 80-byte `:ret` (the .tail
        -- request) through sret — rt_tail_known's C ABI.
        Agg "ret"

    else if key == "Rt.bounce" then
        -- stage 6 B2: Rt.bounce returns the 40-byte `.done` Value through
        -- sret — rt_bounce's C ABI.
        Agg "val"

    else if key == "Rt.globalClosure" then
        -- ZIGHOST Z3: the closure-cache seat returns the 40-byte lambda
        -- Value through sret, exactly the deleted Zig seat's C ABI
        -- (rt_global_closure -> Value).  Its ONE word param is the static
        -- descriptor's address.  AGG-returning rawAbi defuns lower their BODY
        -- through the value path (lowerTail), which is what lets this one
        -- keep a one-sided `return` guard on the cache hit.
        Agg "val"

    else
        Base L


{-| stage 6 B1: is a rawAbi defun's RESULT an aggregate (sret) rather than a
word?  Aggregate-returning rawAbi defuns lower their BODY through the value
path (`lowerTail` — so they may end in an If/recur, which the word tail
rejects) and hand slot 0 to the @ret block; word-returning ones keep the
`lowerTailWord` path.
-}
rawAbiRetIsAgg : String -> Bool
rawAbiRetIsAgg key =
    case rawAbiRetClass key of
        Agg _ ->
            True

        Base _ ->
            False


{-| The rawAbi ARITY agreement check (stage 6 A1): Mid.Rt.rawAbiArity is the
ONE place the raw-word defuns' param counts are declared.  Checked against
the defun's ACTUAL params at lowerDefun AND against the generated call
sites' actual word counts — a mismatch (a param added in U3-U5 without
touching the record, or a hand-wired call site left under-applied) is a
compile Err, never the silent register-class miscompile the record exists to
kill (the SEGV class the U2 review's nice-to-have 5 named).
-}
rawAbiArityAgree : String -> Int -> Result String ()
rawAbiArityAgree key actual =
    case Dict.get key MidRt.rawAbiArity of
        Just arity ->
            if arity == actual then
                Ok ()

            else
                Err
                    ("qbe: rawAbi arity mismatch for "
                        ++ key
                        ++ " — Mid.Rt.rawAbiArity says "
                        ++ String.fromInt arity
                        ++ " but this defun/call site has "
                        ++ String.fromInt actual
                        ++ " (a param added without updating the record, or a generated call site under-applying)"
                    )

        Nothing ->
            Err ("qbe: rawAbi key " ++ key ++ " has no Mid.Rt.rawAbiArity entry — the record must cover every rawAbi key")


{-| stage 6 B2: the bounce seat's symbol.  Under QBE_MIDDRIVER=1 every `rt_bounce`
emission site retargets to the Mid rawAbi defun q_Rt_x2ebounce — the SAME
`Agg "val"` (40-byte `.done` Value) result and a single `Base L` :ret-pointer
arg, a pure symbol swap.  The default (Zig) seat stays `rt_bounce`.  ONE
helper for ALL THREE sites (directCall's non-tail arm, the RawCall fat
QBE_NORTLEAN route, the rtPrimSlots fat QBE_NORTLEAN route) so a missed site
cannot drift from the other two.
-}
bounceSeat : S -> String
bounceSeat _ =
    "q_" ++ mangle "Rt.bounce"


emit : Il.Inst -> S -> S
emit inst s =
    { s | curBody = inst :: s.curBody }


freshTmp : S -> ( String, S )
freshTmp s =
    ( "t" ++ String.fromInt s.tmp, { s | tmp = s.tmp + 1 } )


freshLbl : String -> S -> ( String, S )
freshLbl word s =
    ( word ++ "_" ++ String.fromInt s.lbl, { s | lbl = s.lbl + 1 } )


freshSlot : S -> ( Int, S )
freshSlot s =
    ( s.slot, { s | slot = s.slot + 1 } )


slotTmp : Int -> String
slotTmp i =
    "s" ++ String.fromInt i


-- E's synthetic binder supply: a NEGATIVE id (FromAst issues positive ids from
-- a per-defun counter, so negatives can never collide) for the transient
-- binders Lower's record lowering builds (the record subexpression is bound
-- once and read through the tag test and its branches).
freshBinder : S -> ( Binder, S )
freshBinder s =
    ( { id = -1 - s.binderN, name = "rec" ++ String.fromInt s.binderN }
    , { s | binderN = s.binderN + 1 }
    )


freshBinders : Int -> S -> ( List Binder, S )
freshBinders n s =
    if n <= 0 then
        ( [], s )

    else
        let
            ( b, s1 ) =
                freshBinder s

            ( rest, s2 ) =
                freshBinders (n - 1) s1
        in
        ( b :: rest, s2 )


closeBlock : Jump -> S -> S
closeBlock jump s =
    { s
        | blocks = { label = s.curLabel, body = List.reverse s.curBody, jump = jump } :: s.blocks
        , curBody = []
    }


startBlock : String -> S -> S
startBlock label s =
    { s | curLabel = label, curBody = [] }


jumpTo : String -> S -> S
jumpTo label s =
    closeBlock (Jmp label) s


{-| Merge a closure body-walk's results into the caller's state: the closure's
own pending func and its datas/key supplies come from the body walk, every
other field carries over from the caller.  A NAMED function (not a lambda) so
the update base is an ANNOTATED closed `S`: the checker cannot discharge a
second setter from a fresh lambda-bound base.
-}
mergeClosureResult : PendingFunc -> S -> S -> S
mergeClosureResult pending sInner s5 =
    { s5
        | funcs = pending :: List.foldl (::) s5.funcs sInner.funcs
        , datas = sInner.datas
        , dataKeys = sInner.dataKeys
        , dataN = sInner.dataN
        , cloN = sInner.cloN
    }


-- Deduplicated static data: same content -> same symbol.
freshData : String -> (String -> DataDef) -> S -> ( String, S )
freshData key mk s =
    case Dict.get key s.dataKeys of
        Just name ->
            ( name, s )

        Nothing ->
            let
                name =
                    "d" ++ String.fromInt s.dataN
            in
            ( name
            , { s
                | dataN = s.dataN + 1
                , dataKeys = Dict.insert key name s.dataKeys
                , datas = mk name :: s.datas
              }
            )



-- ============================ ENTRY ============================
-- lower arityTable program entryKey: reachability from entryKey over GRef
-- edges, one QBE function per reachable defun (+ closure functions, + Desc/
-- string/symbol/float/prim-name data), the rt_callN dispatchers, the global
-- Descs, and the driver's meta table.


-- Order-preserving dedupe (the concatenated seed lists can overlap when two
-- hatches share a helper — emitting a defun twice is a duplicate QBE symbol,
-- a class this unit hit once before Rt.closure grew its own 0-based fill).
unique : List String -> List String
unique xs =
    List.foldl
        (\x ( seen, acc ) ->
            if Set.member x seen then
                ( seen, acc )

            else
                ( Set.insert x seen, acc ++ [ x ] )
        )
        ( Set.empty, [] )
        xs
        |> Tuple.second


{-| The 9th positional slot — spelled `_` here — is the RETIRED collector
switch (zighost Z0): the Mid collector is the only collector, so no arm here
reads it.  The slot stays because `Mid.QbeModule.compileEntry` still carries it
in its call shape — the one place this unit could not reach (another lane owns
that file).  Nothing selects a collector; the slot is inert, not a default.
-}
lower : MidRt.Runtime -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> QbeTypes.Table -> Dict String Int -> List Defun -> String -> Result String Il.Module
lower runtime rep primDirect midCons rtLean consArr rec typeSpec _ midGcYoung leafFree table arityTable program entryKey =
    let
        defuns =
            Dict.fromList (List.map (\d -> ( d.key, d )) program)
    in
    case reach defuns entryKey [] of
        Err msg ->
            Err msg

        Ok surfaceKeys ->
            -- USED-PRIM SEEDING (osier-consspike): the Rt program (if any was
            -- injected) joins the reachable set ONLY through the prims the
            -- REACHED surface defuns actually call — the census mirrors this
            -- lowering's own desugars (a ListLit is a cons chain, a record
            -- literal/update is cons + @p), so a program that never conses
            -- carries no cons machinery and its .ssa is byte-identical to the
            -- pre-Rt baseline.  Rt keys cannot arrive any other way: surface
            -- code cannot GRef them, and grefsOf deliberately ignores Unsafe
            -- nodes (Mid.Rt.seeds owns the Rt->Rt closure instead).
            let
                usedPrims =
                    List.foldl
                        (\key acc ->
                            case Dict.get key defuns of
                                Just defun ->
                                    Set.union acc (calledPrims rec defun.value)

                                Nothing ->
                                    acc
                        )
                        Set.empty
                        surfaceKeys

                rtKeys =
                    -- ONE `unique` OVER THE WHOLE CONCATENATION (stage 6 U2
                    -- fix): each of the three halves is deduped WITHIN itself,
                    -- but they OVERLAP across the boundary — the prim half
                    -- (MidRt.seeds over the surface's called prims) already
                    -- carries Rt.cStrLenGo, which is also in the
                    -- driverSeeds/gcSeeds closure (Rt.die -> Rt.cStrLenGo),
                    -- and gcSeeds carries Rt.die, which driverSeeds carries
                    -- too.  The emission fold below lowers ONE defun per key
                    -- with no seen-set, so a repeat is two definitions of the
                    -- same q_Rt_* symbol and qbe rejects the .ssa (MEASURED:
                    -- QBE_MIDDRIVER=1 alone already duplicated
                    -- q_Rt_x2ecStrLenGo; the Mid collector's seeding added
                    -- q_Rt_x2edie).  The plan declares MIDGC x MIDDRIVER a VALID combination,
                    -- so the cross-boundary repeat is the defect, not the
                    -- combination.  With both hatches off this is a no-op
                    -- (MidRt.seeds is already unique), so the DEFAULT route's
                    -- bytes do not move.
                    if List.any (\d -> isRtKey d.key) program then
                        unique
                            (List.filter (\k -> not (List.member k surfaceKeys)) (MidRt.seeds usedPrims)
                                ++ List.filter (\k -> not (List.member k surfaceKeys)) (unique (MidRt.gcSeeds ++ MidRt.conSeeds ++ MidRt.closureSeeds ++ MidRt.lowerSeatSeeds))
                                -- THE NURSERY SEEDS (GC NURSERY unit): the young
                                -- defuns exist in the surface only when run.js
                                -- kept the QBE_MIDGC_YOUNG-ONLY regions, so they
                                -- are seeded ONLY in a young build — a young-OFF
                                -- build must not name them (an absent key
                                -- here is "unknown global", loud, which is why
                                -- no ALWAYS-PRESENT rtDeps row may list one).
                                ++ (if midGcYoung then
                                        List.filter (\k -> not (List.member k surfaceKeys)) (unique MidRt.youngGcSeeds)

                                    else
                                        []
                                   )
                                ++ List.filter (\k -> not (List.member k surfaceKeys)) (unique MidRt.driverSeeds)
                                -- THE QBE_MIDHOST GATE (stage 7A): the Mid effect
                                -- host joins ONLY when the surface text carries the
                                -- host arm — i.e. when run.js kept the marked region
                                -- (Rt.midHostMarker witnesses it).  Since stage 7 O2
                                -- that is the DEFAULT route (the host IS seeded, and
                                -- the corpus re-freeze was declared with the flip);
                                -- the unseeded route is the QBE_MIDHOST=0 escape
                                -- hatch, still byte-identical to the pre-7A tree.
                                ++ (if runtime.hosted then
                                        List.filter (\k -> not (List.member k surfaceKeys)) (unique MidRt.hostSeeds)

                                    else
                                        []
                                   )
                            )

                    else
                        []

                keys =
                    surfaceKeys ++ rtKeys

                -- P5: THE NON-COLLECTING CALL TARGETS.  A call may be skipped
                -- as a GC safepoint only when its target is PROVABLY unable to
                -- reach one: an Rt defun OUTSIDE `runtime.allocating` (the
                -- existing fixed point over the Rt program's own call graph,
                -- so this is the SAME classification the lean ABI's frame
                -- decision already trusts), plus the libc entries the emitter
                -- names that cannot run a collect (`free` is a C-heap release;
                -- `malloc` is not a GC seat and cannot move the Mid heap).
                -- Everything else — a surface defun, an indirect call, an
                -- extern — is a safepoint.  Denying by default is what makes
                -- the predicate conservative.
                noCollect =
                    Set.union
                        (Set.fromList
                            (List.filterMap
                                (\k ->
                                    if isRtKey k && not (Set.member k runtime.allocating) then
                                        Just ("q_" ++ mangle k)

                                    else
                                        Nothing
                                )
                                keys
                            )
                        )
                        libcNoCollect

                s0 =
                    { blocks = []
                    , curLabel = "start"
                    , curBody = []
                    , tmp = 0
                    , lbl = 0
                    , slot = 0
                    , binderSlots = Dict.empty
                    , rawInt = Dict.empty
                    , rawFloat = Dict.empty
                    , rawWord = Dict.empty
                    , intBinders = Set.empty
                    , table = table.defuns
                    , rep = rep
                    , primDirect = primDirect
                    , midCons = midCons
                    , rtLean = rtLean
                    , rec = rec
                    , consArr = consArr
                    , typeSpec = typeSpec
                    , midGcYoung = midGcYoung
                    , funcs = []
                    , datas = []
                    , dataKeys = Dict.empty
                    , dataN = 0
                    , cloN = 0
                    , binderN = 0
                    , arities = arityTable
                    , defuns = defuns
                    , seeded = Set.fromList keys
                    , defunKey = ""
                    , binderKey = ""
                    , qname = ""
                    , abi = runtime.abi
                    , loops = []
                    , ptrRead = ptrReadKeys defuns arityTable
                    , paramPtr = Dict.empty
                    , noCollect = noCollect
                    , leafFree = leafFree
                    }

                -- THE MIDGC REFUSAL ARMS ARE GONE (stage 7 O2).  Two arms
                -- stood here, and they existed for ONE reason: while the ZIG
                -- effect host (src/effectloop.zig) was the host, every host leaf
                -- built its result in the ZIG nursery (values.valString /
                -- valCons) and handed it to compiled code through host_apply, so
                -- a Mid object could reference memory the Zig scavenge reclaims
                -- — the reproduced cross-heap hole (churn a host-IO program's
                -- 4-arg MUTUAL tail recursion on the Mid heap: content equality
                -- printed 0 while String.length printed 150).  Arm 1 was a CENSUS
                -- (`usedPrims ∩ nurseryHostPrims`: refuse when a used prim's Zig
                -- handler built a nursery value); arm 2 was the SEAM (refuse any
                -- program reaching Runtime.program / Runtime.worker, because a
                -- Platform.program never reaches runTask and so has an EMPTY
                -- census while the Zig loop still drove it).
                --
                -- O2 makes the MID host the DEFAULT and it allocates through the
                -- Mid seats (Rt.cons -> allocvec -> Rt.allocVector),
                -- so the hole closes BY CONSTRUCTION on the default route: there
                -- is no Zig nursery on the path any more.  The refusals therefore
                -- die in the SAME COMMIT as the flip — a refusal is a statement
                -- about what is legal, and one left standing would have the tree
                -- lying about a hole that no longer exists.
                --
                -- WHAT REPLACED THEM: the pairing that IS still unsound — a Mid
                -- heap driven by the ZIG host (the `QBE_MIDHOST=0` opt-out) — is
                -- refused LOUDLY in run.js's MIDGC_DEPENDS_ON, where the hole's
                -- condition is exactly expressible (WHICH HOST) instead of being
                -- approximated by a prim census that had to enumerate handlers.
                -- The census could only ever be as complete as its list (it was
                -- wrong twice, on `intern` and on `str`); the host choice cannot
                -- be wrong about which host runs.
                --
                -- NOT COVERED BY EITHER (before or after): this says nothing
                -- about whether every Mid-IMPLEMENTED prim is Mid-sound — that is
                -- the corrected-criterion audit (plan.md §2.2), whose pure-program
                -- half is pinned by probe-midgc-tail.sh (the transient tail array
                -- is a scavenge trigger but not a hole).
            in
            List.foldl
                (\key acc ->
                    acc
                        |> Result.andThen
                            (\s ->
                                case Dict.get key defuns of
                                    Nothing ->
                                        Err ("qbe: unknown global " ++ key)

                                    Just defun ->
                                        lowerDefun runtime defun s
                            )
                )
                (Ok s0)
                keys
                |> Result.map (\sFinal -> finishModule sFinal keys)



-- ============================ REACHABILITY ============================


reach : Dict String Defun -> String -> List String -> Result String (List String)
reach defuns key seen =
    if List.member key seen then
        Ok seen

    else
        case Dict.get key defuns of
            Nothing ->
                Err ("qbe: unknown global referenced: " ++ key)

            Just defun ->
                List.foldl
                    (\k acc -> Result.andThen (\s -> reach defuns k s) acc)
                    (Ok (key :: seen))
                    (grefsOf defuns defun.value)


grefsOf : Dict String Defun -> Exp -> List String
grefsOf defuns exp =
    case exp of
        Lit _ ->
            []

        Var _ ->
            []

        GRef ref ->
            [ ref.key ]

        StreamRef _ ->
            []

        Lam lambda ->
            grefsOf defuns lambda.body

        NoTail inner ->
            grefsOf defuns inner

        App app ->
            grefsOf defuns app.fn ++ List.concatMap (grefsOf defuns) app.args

        PrimApp app ->
            List.concatMap (grefsOf defuns) app.args

        Let block ->
            List.concatMap (grefsOf defuns) (letValues block.binders)
                ++ grefsOf defuns block.body

        Case branch ->
            grefsOf defuns branch.scrutinee
                ++ List.concatMap (\a -> grefsOf defuns a.body) branch.alts

        Con con ->
            List.concatMap (grefsOf defuns) con.args

        Tup es ->
            List.concatMap (grefsOf defuns) es

        RecordLit setters ->
            List.concatMap (\p -> grefsOf defuns (Tuple.second p)) setters

        RecordGet rec _ ->
            grefsOf defuns rec

        RecordUpdate update ->
            grefsOf defuns update.base
                ++ List.concatMap (\p -> grefsOf defuns (Tuple.second p)) update.updates

        ListLit es ->
            List.concatMap (grefsOf defuns) es

        If block ->
            grefsOf defuns block.cond ++ grefsOf defuns block.thenBranch ++ grefsOf defuns block.elseBranch

        ShortAnd block ->
            grefsOf defuns block.left ++ grefsOf defuns block.right

        ShortOr block ->
            grefsOf defuns block.left ++ grefsOf defuns block.right

        NotEqual block ->
            grefsOf defuns block.left ++ grefsOf defuns block.right

        -- (B4) a loop calls whatever its cond and body call; the leaves call
        -- nothing.
        Loop block ->
            grefsOf defuns block.cond ++ grefsOf defuns block.body

        Break ->
            []

        Continue ->
            []

        -- Unsafe (osier-rawnodes / osier-consspike): a raw node GRefs NOTHING
        -- except a RawCall, which is a real call edge — see below.  The
        -- USED-PRIM seeding (Mid.Rt.seeds -> rtDeps) remains how an Rt defun
        -- reached through a PRIM becomes reachable: a prim call is a PrimApp,
        -- not a RawCall, so this walk cannot see the Rt key it names; the
        -- prim->Rt closure is declared in Mid.Rt.rtDeps instead (the seeding
        -- in `lower`).
        --
        -- M3fix-4 + M3-rtcall: a RawCall to ANY PROGRAM defun is a real call
        -- edge — M3 lets a user .mid `call` another user module's exported
        -- defun (non-Rt) AND an EXPORTED runtime key (Rt.*), both of which
        -- lower to RawCall naming that defun's key and emit the `q_<key>`
        -- call.  Without the edge here the callee is never REACHED, so it is
        -- never emitted and the link fails (MEASURED on the first cut of each
        -- fix, predicate-only: `undefined reference to q_CrossB_x2eg`, and for
        -- the Rt direction `undefined reference to q_Rt_read-file-as-string`).
        -- Reported ONLY when the key already names a defun of this program: a
        -- key that names nothing stays invisible here so the RawCall arm's own
        -- reject — not a reachability "unknown global" — is the error that
        -- names a call to nothing.
        --
        -- HONEST SPAN: this also makes `reach` traverse an Rt->Rt RawCall
        -- edge when the walk is ALREADY inside an Rt defun (the collector's
        -- mark/sweep loops, the deepEq helpers).  That is exactly the call
        -- graph Mid.Rt.rtDeps declares by hand, so the two closures agree (a
        -- TestMain row pins every RawCall target is a program key AND in
        -- rtDeps); for a DEFAULT route (Elm surface only) the walk never
        -- ENTERS an Rt defun — surface code reaches Rt keys only through
        -- prims, never through GRef/RawCall — so the corpus .ssa stays
        -- byte-identical.  Mid.Rt.seeds/rtDeps remain the used-prim seeding
        -- path (the prim->Rt closure), orthogonal to this edge.
        --
        -- M-GREF-OPERAND (handoff-midlang-grefs): the edge above is NOT the
        -- whole story, because a RawCall can be an OPERAND of another raw
        -- node — `payload(call A.f(k), 0)` lowers to
        -- `RawWordLoad { ptr = RawCall .., index = Lit 0 }` — and the first
        -- cut of this arm returned the RawCall's own edge WITHOUT visiting
        -- the node's other operands, so the callee was never reached, never
        -- emitted, and the link failed (`undefined reference to
        -- q_Wgref_x2ehelper`; MEASURED, minimal two-defun repro).  The arm
        -- therefore walks every operand of the node (rawOperands) as well,
        -- which is what makes the census total: a call is a call edge
        -- wherever it sits.  A RawCall's own ARGS are walked too, so a call
        -- nested in a call's argument list is reached.
        Unsafe node ->
            rawCallEdges defuns node


{-| The call edges of ONE raw node: the node's OWN edge (a `RawCall` names its
callee) plus the edges of every expression OPERAND it holds, in the same
account of "the children of a raw node" as `Mid.Qbe.Monomorphise.unsafeChildren`
(the traversal's one source).  Two places hold that list because Lower cannot
import Monomorphise's (its `exposing` list is `Output, run`) — Elm's
exhaustiveness check is what keeps them from drifting: a new `UnsafeNode`
constructor fails the build HERE until it is given its operands.

Reported only for a key that already names a defun of this program, so a call
to nothing stays the RawCall arm's own reject, exactly as before.
-}
rawCallEdges : Dict String Defun -> UnsafeNode -> List String
rawCallEdges defuns node =
    (case node of
        RawCall call ->
            if Dict.member call.sym defuns then
                [ call.sym ]

            else
                []

        _ ->
            []
    )
        ++ List.concatMap (grefsOf defuns) (rawOperands node)


rawOperands : UnsafeNode -> List Exp
rawOperands node =
    case node of
        RawCall call ->
            call.args

        RawTagOf e ->
            [ e ]

        RawPayload r ->
            [ r.value ]

        RawMkValue r ->
            r.words

        RawAllocVector e ->
            [ e ]

        RawVecLoad r ->
            [ r.vec, r.index ]

        RawVecAddr r ->
            [ r.vec, r.index ]

        RawVecStore r ->
            [ r.vec, r.index, r.value ]

        RawStrByte r ->
            [ r.str, r.index ]

        WithRoots r ->
            [ r.body ]

        RawPayload32 r ->
            [ r.value ]

        RawTagIs r ->
            [ r.value ]

        RawBin r ->
            [ r.a, r.b ]

        RawUn r ->
            [ r.v ]

        RawCmp r ->
            [ r.a, r.b ]

        RawFltBin r ->
            [ r.a, r.b ]

        RawFltCmp r ->
            [ r.a, r.b ]

        RawIToF e ->
            [ e ]

        RawLoadFlt e ->
            [ e ]

        RawAllocRaw e ->
            [ e ]

        RawByteLoad r ->
            [ r.ptr, r.index ]

        RawByteStore r ->
            [ r.ptr, r.index, r.value ]

        RawWordLoad r ->
            [ r.ptr, r.index ]

        RawWordStore r ->
            [ r.ptr, r.index, r.value ]

        -- cffi U6: width-typed memory — the offset is node data, so the
        -- operands are the pointer (and the value for a store).
        RawMemLoad r ->
            [ r.ptr ]

        RawMemStore r ->
            [ r.ptr, r.value ]

        RawCallRaw call ->
            call.args

        -- cffi U2 — the typed C boundary's operands are its args, in order
        -- (the widths are NODE DATA, not expressions).
        RawCallExtern call ->
            call.args

        RawCallAgg call ->
            call.fn :: call.args

        RawDataAddr _ ->
            []

        RawCStr _ ->
            []

        RawSym _ ->
            []

        RawAllocN _ ->
            []


-- ============================ VR1 — POINTER PARAMS ============================
-- A Value parameter crosses as an `l` POINTER to the caller's 40-byte slot
-- (the ABI's ONE change).  What that pointer points at is what decides whether
-- the callee may read through it LAZILY — i.e. after its own safepoints —
-- instead of blitting it into its own rooted frame at entry:
--
--   * a DIRECT call site passes `slotTmp` of an arg it just lowered into a
--     FRESH ROOTED frame slot of the caller, and the caller's frame stays live
--     for the whole callee — so the collector rewrites the Value IN PLACE and
--     the pointer stays valid at every safepoint the callee reaches.
--   * a CLOSURE call (rt_apply -> rt_call2r) and a TAIL call (rt_tail-known ->
--     rt_bounce -> rt_callN) pass pointers into GC ARRAYS (`buf`, the closure
--     env, the apply args) — the MOVING collector relocates those, so a lazy
--     read is a stale pointer.  Both paths are sound today only because the
--     callee copies out at entry, before its first safepoint.
--   * a SELF-TAIL (the in-frame loop) REBINDS slots 2+i for the next
--     iteration, so a param read through `%a<i>` would never see the rebind.
--   * the driver's ENTRY call is NOT one of those: Rt.main stages the entry
--     args in `abuf`, a malloc'd block registered with rootPushValueArray, so
--     it is rooted AND immovable — a lazy read through it is sound.
--
-- So a defun may read through its pointers iff EVERY reference to it is a
-- direct non-tail call (or the entry table) and it has no self-tail.  The set
-- is computed here, before lowering, by walking every body with the same
-- tail-position rule lowerTail applies — and it is read in ONE place
-- (lowerFunBody's prologue); a defun outside the set keeps today's entry blit
-- and is CORRECT on every path, so a missed fact costs the copies, never
-- soundness.  The one direction that would be unsound — a defun IN the set
-- reached by a closure or a tail call — is what the walker's conservative
-- arms (an unknown arity, a forced GRef, an `Unsafe` operand) exclude.
type alias ParamFacts =
    { closure : Set String -- GRef'd in a non-direct-call position (closure Value)
    , tailed : Set String -- target of a cross-defun TAIL call
    , selfTail : Set String -- has an in-frame self-tail loop
    }


noParamFacts : ParamFacts
noParamFacts =
    { closure = Set.empty, tailed = Set.empty, selfTail = Set.empty }


ptrReadKeys : Dict String Defun -> Dict String Int -> Set String
ptrReadKeys defuns arities =
    let
        facts =
            allParamFacts defuns arities
    in
    Set.filter
        (\k ->
            not (Set.member k facts.closure)
                && not (Set.member k facts.tailed)
                && not (Set.member k facts.selfTail)
        )
        (Set.fromList (Dict.keys defuns))


allParamFacts : Dict String Defun -> Dict String Int -> ParamFacts
allParamFacts defuns arities =
    List.foldl
        (\d acc ->
            case d.value of
                Lam lambda ->
                    paramFacts arities d.key True lambda.body acc

                _ ->
                    acc
        )
        noParamFacts
        (Dict.values defuns)


-- The tail-position flag mirrors lowerTail: a Let body and both If arms and
-- every Case alt inherit the enclosing position, a Lam body is ALWAYS a tail
-- position (it is lowered as its own function, whose @ret it reaches), NoTail
-- is transparent (lowerTail strips it — so a NoTail'd tail App IS emitted as a
-- tail call today), and everything else is a value position.
paramFacts : Dict String Int -> String -> Bool -> Exp -> ParamFacts -> ParamFacts
paramFacts arities self tailPos exp acc =
    let
        value =
            paramFacts arities self False

        values es st =
            List.foldl (\e a -> value e a) st es
    in
    case exp of
        Lit _ ->
            acc

        Var _ ->
            acc

        StreamRef _ ->
            acc

        Break ->
            acc

        Continue ->
            acc

        GRef ref ->
            closureRef ref.key acc

        Lam lambda ->
            -- a closure body: its own function, no self key (lowerFunBody's
            -- defunKey is "" for a closure — so a saturated tail call to the
            -- ENCLOSING defun there is a cross-defun tail call, not a loop).
            paramFacts arities "" True lambda.body acc

        NoTail inner ->
            paramFacts arities self tailPos inner acc

        App app ->
            let
                ( head, args ) =
                    spine exp

                accArgs =
                    values args acc
            in
            case head of
                GRef ref ->
                    callFacts arities self tailPos ref (List.length args) accArgs

                _ ->
                    value head accArgs

        PrimApp app ->
            values app.args acc

        Let block ->
            paramFacts arities self tailPos block.body (values (letValues block.binders) acc)

        Case branch ->
            List.foldl
                (\a st -> paramFacts arities self tailPos a.body st)
                (value branch.scrutinee acc)
                branch.alts

        Con con ->
            values con.args acc

        Tup es ->
            values es acc

        RecordLit setters ->
            values (List.map Tuple.second setters) acc

        RecordGet rec _ ->
            value rec acc

        RecordUpdate update ->
            values (update.base :: List.map Tuple.second update.updates) acc

        ListLit es ->
            values es acc

        If block ->
            paramFacts arities self tailPos block.thenBranch
                (paramFacts arities self tailPos block.elseBranch (value block.cond acc))

        ShortAnd block ->
            values [ block.left, block.right ] acc

        ShortOr block ->
            values [ block.left, block.right ] acc

        NotEqual block ->
            values [ block.left, block.right ] acc

        Loop block ->
            values [ block.cond, block.body ] acc

        Unsafe node ->
            let
                accSelf =
                    case node of
                        RawCall call ->
                            if tailPos && call.sym == self then
                                { acc | selfTail = Set.insert self acc.selfTail }

                            else
                                acc

                        _ ->
                            acc
            in
            values (rawOperands node) accSelf


-- One saturated-App head.  `force` heads call the defun with ZERO args (a
-- thunk force), so no pointer crosses — they constrain nothing.
callFacts : Dict String Int -> String -> Bool -> { key : String, force : Bool } -> Int -> ParamFacts -> ParamFacts
callFacts arities self tailPos ref nargs acc =
    if ref.force then
        acc

    else
        case Dict.get ref.key arities of
            Nothing ->
                -- lowerApp rejects this ("no arity for global"); count it as a
                -- closure so the analysis can never be the looser side.
                closureRef ref.key acc

            Just n ->
                if nargs /= n then
                    -- under-/over-applied: lowerGRefValue materializes a closure
                    closureRef ref.key acc

                else if not tailPos then
                    acc

                else if ref.key == self then
                    { acc | selfTail = Set.insert self acc.selfTail }

                else
                    { acc | tailed = Set.insert ref.key acc.tailed }


closureRef : String -> ParamFacts -> ParamFacts
closureRef key acc =
    { acc | closure = Set.insert key acc.closure }


-- The reserved runtime namespace (Mid.Audit tests the same prefix; a surface
-- module named Rt is rejected at collect time by Mid.QbeModule).
isRtKey : String -> Bool
isRtKey key =
    String.startsWith "Rt." key


{-| The prim names a defun's lowering will CALL — the used-prim census the Rt
seeding reads.  This is the ONE place a desugar must be declared, and the
seats below are wired so it cannot drift:

  * every CONSTRUCT arm walks the SAME builder function `lowerVal` calls
    (buildTuple / buildRecord / buildRecordGet / buildRecordUpdate /
    buildList), so "what the census sees" IS "what the lowering emits" — not
    a restatement of it;
  * the two arms with no builder (alt/binder PATHS, and the match TESTS) run
    through `pathPrims` / `matchPrims`, one function per seat;
  * anything the census still misses is caught at the call site by
    `midPrimRoute`'s SEED GUARD, which fails the COMPILE naming the prim
    instead of emitting a call to a defun this compile will not emit.

The step-5 review (handoff osier-midrt-review) is why: the restated lists
were wrong in SIX of the seven seats — a tuple seeded `@p` and missed `cons`,
a record literal missed `emptylist`, a record get missed `assoc`+`snd`, and
BOTH pattern seats (case alt binds, let-destructure binds) missed `assoc`+
`snd` while BOTH match seats (MTagEq/MLitEq -> lowerEqMatch) missed `=`.
Each one built a binary that failed to LINK on an undefined `q_Rt_*`.
-}
calledPrims : Bool -> Exp -> Set.Set String
calledPrims rec exp =
    let
        go : Exp -> Set.Set String
        go e =
            case e of
                Lit _ ->
                    Set.empty

                Var _ ->
                    Set.empty

                GRef _ ->
                    Set.empty

                StreamRef { varName } ->
                    -- Materializing a stream's NAME and calling the `value` prim on
                    -- it (lowerVal's StreamRef arm) IS a prim call — the census must
                    -- mirror it (step 5's hand-off #2: this function mirrors every
                    -- desugar that calls a prim).  `value` has no Mid impl today, so
                    -- this seeds nothing yet — but a future Mid `value` port must
                    -- not find its desugar missing here.
                    Set.insert "value" (go (Lit (LString varName)))

                Lam lambda ->
                    go lambda.body

                NoTail inner ->
                    go inner

                App app ->
                    List.foldl (\arg acc -> Set.union acc (go arg)) (go app.fn) app.args

                PrimApp app ->
                    List.foldl (\arg acc -> Set.union acc (go arg)) (Set.singleton app.prim) app.args

                Let block ->
                    List.foldl
                        (\val acc -> Set.union acc (go val))
                        (List.foldl
                            (\b acc -> Set.union acc (letBinderPrims rec b))
                            (go block.body)
                            block.binders
                        )
                        (letValues block.binders)

                Case branch ->
                    List.foldl
                        (\a acc -> Set.union acc (altPrims rec a))
                        (go branch.scrutinee)
                        branch.alts

                Con con ->
                    List.foldl (\arg acc -> Set.union acc (go arg)) Set.empty con.args

                Tup es ->
                    -- (a, b) lowers through lowerTup -> buildTuple, which is a CONS
                    -- chain (`@p` is NOT what a surface tuple compiles to).
                    go (buildTuple es)

                RecordLit setters ->
                    if rec then
                        if hasDuplicateLabels setters then
                            -- scoped labels: the lowering takes the CHAIN route
                            -- (buildRecord); the census must mirror it.
                            go (buildRecord setters)

                        else
                            -- positional build: the VALUES' prims only; {}
                            -- keeps the emptylist route.
                            List.foldl
                                (\p acc -> Set.union acc (go (Tuple.second p)))
                                (if List.isEmpty (recordFields setters) then
                                    Set.singleton "emptylist"

                                 else
                                    Set.empty
                                )
                                setters

                    else
                        go (buildRecord setters)

                RecordGet recExpr field ->
                    if rec then
                        -- tag test: walk (recGet) + chain (snd/assoc).  recGet
                        -- is seeded even where the positional arm fires (a
                        -- closed row still carries the walk as the defensive
                        -- else) — over-seeding dead code, never a missing seed.
                        Set.union (Set.fromList [ "snd", "assoc", "recGet" ]) (go recExpr)

                    else
                        go (buildRecordGet recExpr field)

                RecordUpdate update ->
                    if rec then
                        -- tag test: walk (recInsert, the insert-or-update) +
                        -- chain (cons/@p prepend — the host-built fallback;
                        -- not assoc/snd, which is the READ route).  recInsert
                        -- is seeded even where the positional arm fires
                        -- (defensive else) — over-seeding, never a miss.
                        Set.union
                            (Set.fromList [ "cons", "@p", "recInsert" ])
                            (Set.union
                                (go update.base)
                                (List.foldl (\p acc -> Set.union acc (go (Tuple.second p))) Set.empty update.updates)
                            )

                    else
                        go (buildRecordUpdate update)

                ListLit es ->
                    -- [a, b] = cons a (cons b (emptylist)) (buildList).
                    go (buildList es)

                If block ->
                    List.foldl (\sub acc -> Set.union acc (go sub))
                        Set.empty
                        [ block.cond, block.thenBranch, block.elseBranch ]

                ShortAnd block ->
                    Set.union (go block.left) (go block.right)

                ShortOr block ->
                    Set.union (go block.left) (go block.right)

                NotEqual block ->
                    Set.union (go block.left) (go block.right)

                Loop block ->
                    Set.union (go block.cond) (go block.body)

                Break ->
                    Set.empty

                Continue ->
                    Set.empty

                Unsafe _ ->
                    Set.empty
    in
    go exp


{-| The prims one case alt stages ON TOP of its body: its pattern TESTS
(lowerMatchTests -> lowerMatch: MTagEq/MLitEq run the REAL `=` via
lowerEqMatch) and its pattern BINDS (lowerBinds -> lowerPath: a VField bind
runs assoc then snd — or recGet under E).  The census walked only `alt.body`
until the step-5 review; both seats were missing.
-}
altPrims : Bool -> Alt -> Set.Set String
altPrims rec alt =
    Set.union (calledPrims rec alt.body)
        (Set.union (matchPrims alt.matches) (pathPrims rec (List.map Tuple.second alt.binds)))


{-| Same two seats for a `let` destructure (lowerLetDestruct calls the same
lowerMatchTests / lowerBinds).
-}
letBinderPrims : Bool -> LetBinder -> Set.Set String
letBinderPrims rec b =
    case b of
        LetBind _ ->
            Set.empty

        LetDestruct d ->
            Set.union (matchPrims d.matches) (pathPrims rec (List.map Tuple.second d.binds))


{-| lowerMatch's own prim calls: the tag tests (MCons/MEmpty/MVector) are
inline loads, but MTagEq and MLitEq run the `=` prim (Lower.elm's lowerEqMatch).
-}
matchPrims : List Match -> Set.Set String
matchPrims matches =
    List.foldl
        (\m acc ->
            case m of
                MTagEq _ _ ->
                    Set.insert "=" acc

                MLitEq _ _ ->
                    Set.insert "=" acc

                MCons _ ->
                    acc

                MEmpty _ ->
                    acc

                MVector _ ->
                    acc
        )
        Set.empty
        matches


{-| lowerPath's prim calls: VPath is a pure pointer chase; VField is
`snd (assoc (sym field) rec)` — or `recGet` under E (the tag-14 walk).
-}
pathPrims : Bool -> List ValuePath -> Set.Set String
pathPrims rec paths =
    List.foldl
        (\p acc ->
            case p of
                VPath _ ->
                    acc

                VField _ _ ->
                    if rec then
                        Set.insert "recGet" (Set.insert "snd" (Set.insert "assoc" acc))

                    else
                        Set.insert "snd" (Set.insert "assoc" acc)
        )
        Set.empty
        paths


letValues : List LetBinder -> List Exp
letValues binders =
    List.filterMap
        (\b ->
            case b of
                LetBind bind ->
                    Just bind.value

                LetDestruct d ->
                    Just d.value
        )
        binders



-- ============================ DEFUN LOWERING ============================


lowerDefun : MidRt.Runtime -> Defun -> S -> Result String S
lowerDefun runtime defun sOuter =
    case defun.value of
        Lam lambda ->
            let
                qname =
                    "q_" ++ mangle defun.key

                -- THE Rt ABI (osier-midabi + stage 6 U2 raw-word): every
                -- Rt.* defun lowers with one of four conventions — the
                -- raw-word ABI for MidRt.rawAbi keys (Rt.die/Rt.halt here,
                -- the driver/ABI family in U3-U5); otherwise the lean ABI
                -- (3 pointer params + count, direct :val return) with a
                -- frame ONLY when the body can reach a GC safepoint
                -- (rt.allocating, the classification that owns the fact —
                -- threaded from the once-per-process Mid.Rt.load record,
                -- M1); otherwise the generic closure ABI (surface defuns,
                -- and the whole Rt program when QBE_NORTLEAN=1 restores the
                -- fat shape for a bisect).
                rt =
                    -- B6: the WORD ABI is now derived from the SIGNATURE
                    -- (`Mid.Rt.abiTable` — a key is in the table iff its
                    -- declared params and result are all word-class, OR it is
                    -- a declared Mid.Rt.rawAbi key, which the table merges as
                    -- an OVERRIDE).  Membership REPLACES the old
                    -- `Set.member defun.key MidRt.rawAbi` test, so the nine
                    -- all-word runtime keys classify byte-identically and the
                    -- four aggregate-return ones stay word-ABI by the merge.
                    if Dict.member defun.key runtime.abi then
                        RtRawWord

                    else if sOuter.rtLean && isRtKey defun.key then
                        if Set.member defun.key runtime.allocating then
                            RtLeanRooted

                        else
                            RtLeanFree

                    else
                        RtGeneric
            in
            if List.length lambda.params > maxArity then
                Err ("qbe: defun " ++ defun.key ++ " has arity > " ++ String.fromInt maxArity ++ " (rt_callN table limit)")

            else
                lowerFunBody True defun.key qname lambda [] rt sOuter
                    |> Result.map
                        (\( pending, sInner ) ->
                            { sOuter
                                | funcs = pending :: List.foldl (::) sOuter.funcs sInner.funcs
                                , datas = sInner.datas
                                , dataKeys = sInner.dataKeys
                                , dataN = sInner.dataN
                                , cloN = sInner.cloN
                            }

                        )

        _ ->
            Err ("qbe: defun " ++ defun.key ++ " has a non-Lambda value (corrupt Mid tree)")



-- ============================ FUNCTION BODY ============================
-- Frame layout: slot 0 result `:val`, slot 1 the `.tail` metadata (kind/f/e/
-- args/arity — the second half of the 80-byte `:ret` return), 2..N+1 params,
-- N+2..N+1+K captures, then temps.  Blocks: @start (prologue; jump @body),
-- @body (loop head for self-tail), ... interior ..., @ret (rt_frame_leave;
-- ret %s0 — returns the whole 80-byte `:ret` at slot 0).
--
-- THE Rt LEAN ARM (osier-midabi): when `rt` is Just _ the SAME slot layout
-- addresses off a DIFFERENT base (the function's signature, return type and
-- @ret block all switch — see lowerFunBody's body): the generic-ABI
-- machinery (slot defs, param blits, Var reads, dest slot 0) is reused
-- verbatim, which is what keeps the lean callee a small delta rather than a
-- second lowering.


lowerFunBody : Bool -> String -> String -> Lambda -> List Int -> RtAbi -> S -> Result String ( PendingFunc, S )
lowerFunBody entry key qname lambda captures rt sOuter =
    let
        nparams =
            List.length lambda.params

        ncaps =
            List.length captures

        -- B6: this defun's per-parameter word widths.  Only the word ABI
        -- consumes them (a value-ABI parameter is always one 40-byte slot);
        -- a key absent from the table takes the all-1s default so the shape
        -- below is total.
        widths =
            case Dict.get key sOuter.abi of
                Just ws ->
                    ws

                Nothing ->
                    List.repeat nparams 1

        -- The register a parameter's first word arrives in: the running sum of
        -- the widths before it (a struct VALUE parameter occupies `width`
        -- consecutive `l` registers).
        bases =
            paramBases widths

        -- The lean ABI's hard bound: 3 pointer params is the whole register
        -- argument budget A's direct entries standardized on (rt.zig
        -- direct_arity), and a count-less arity-0 call cannot be spelled in
        -- the C ABI.  Both are compile-time facts about the Rt program, so
        -- they fail the COMPILE naming the defun — never the linker.
        rtArityErr =
            if nparams < 1 || nparams > maxDirectArity then
                Err
                    ("qbe: Rt defun "
                        ++ key
                        ++ " has arity "
                        ++ String.fromInt nparams
                        ++ " — the lean ABI passes 1.."
                        ++ String.fromInt maxDirectArity
                        ++ " pointer args (A's direct_arity bound; extend the ABI before adding such a defun)"
                    )

            else
                Ok ()

        rtCapsErr =
            if ncaps /= 0 then
                Err ("qbe: Rt defun " ++ key ++ " captures " ++ String.fromInt ncaps ++ " binders — the lean ABI has no env param (an Rt defun is never a closure)")

            else
                Ok ()

        rawAbi =
            case rt of
                RtRawWord ->
                    True

                _ ->
                    False

        -- P5: is this defun even a CANDIDATE for a frame-free body?  Only a
        -- top-level SURFACE defun (the generic closure ABI) is.  An Rt defun
        -- already has its own frame decision (the lean ABI's `allocating`
        -- membership), a closure body is called through rt_callN with a
        -- GC-array env, and a rawAbi defun is frame-free by ABI — so this
        -- classification COMPOSES with those three instead of second-guessing
        -- them (H5/H6).  QBE_NOLEAF=1 restores the pre-P5 shape for the A/B.
        leafOk =
            sOuter.leafFree
                && entry
                && (case rt of
                        RtGeneric ->
                            True

                        _ ->
                            False
                   )

        -- VR1: this defun reads its value params THROUGH the incoming `l`
        -- pointers instead of blitting them into its own frame at entry.
        -- Only a top-level RtGeneric defun with at least one value param is
        -- eligible (a closure body is called through rt_callN with GC-array
        -- pointers, and an Rt key's lean/word ABI has no `:val` params at all).
        ptrReadD =
            entry
                && not rawAbi
                && not (isRtKey key)
                && nparams > 0
                && Set.member key sOuter.ptrRead

        -- S4: the ONLY binder types the S1 table can give is the defun's own
        -- MONOTYPE, peeled in parameter order (Mid's `params` is in the
        -- callee's order, param 1 outermost, and `Rep.TFun` is
        -- `arg -> result`, so the peel lines up). A polymorphic defun, a
        -- defun with no scheme, or a non-arrow type yields NOTHING — deny by
        -- default. Closure bodies (entry = False) get nothing: they are
        -- separate functions with no scheme of their own.
        intParams =
            if entry && sOuter.rep then
                intParamsOf (Dict.get key sOuter.table) lambda.params

            else
                Set.empty

        s0 =
            { blocks = []
            , curLabel = "start"
            , curBody = []
            , tmp = 0
            , lbl = 0
            , slot =
                -- VR1: a ptrRead defun's params occupy NO frame slots — the
                -- body reads them through `%a<i>`, so 2..N+1 (the params) are
                -- simply not reserved and the frame is N slots smaller (the
                -- memset at rt_frame_enter is proportional to it).
                if ptrReadD then
                    2 + ncaps

                else
                    2 + nparams + ncaps
            , binderSlots =
                Dict.fromList
                    ((if rawAbi then
                        -- rawAbi params are WORD registers, not frame slots —
                        -- the slot counter still reserves 2..N+1 so the body's
                        -- own temps get the SAME slot numbers as every other
                        -- Rt defun (the slots are simply never written/read).
                        []

                      else if ptrReadD then
                        -- VR1: not frame slots either — s.paramPtr names them,
                        -- so an unhandled read path is a LOUD "unbound binder"
                        -- instead of a silent read of an unwritten slot.
                        []

                      else
                        List.indexedMap (\i p -> ( p.id, i + 2 )) lambda.params
                     )
                        -- NOTE, because the two counters disagree on purpose: a
                        -- capture is numbered ABOVE the params (nparams + 2 + j)
                        -- even under ptrReadD, whose fresh-slot counter starts at
                        -- 2 + ncaps with NO param reservation — so a ptrRead defun
                        -- with captures would hand out temps that collide with
                        -- these slots.  That is unreachable, and reachable only
                        -- from one place: lowerDefun (:1528) passes captures = []
                        -- to EVERY entry defun, so the capture list is always
                        -- empty where ptrReadD can be true.  If an entry defun
                        -- ever gets captures, the ptrRead slot base at :1660 must
                        -- become 2 + nparams + ncaps to match.
                        ++ List.indexedMap (\j cid -> ( cid, nparams + 2 + j )) captures
                    )
            , rawInt = Dict.empty
            , rawFloat = Dict.empty
            , rawWord =
                if rawAbi then
                    -- each rawAbi param arrives in its own `l` register (a0..);
                    -- B6: a parameter wider than one word (a struct VALUE) is
                    -- COPIED from its incoming register into a fresh stack
                    -- block in the prologue, and the binder names THAT block —
                    -- so a struct parameter is an ordinary struct value (its
                    -- address) for the whole body.
                    Dict.fromList
                        (List.map2
                            (\base p ->
                                ( p.id
                                , if base.width > 1 then
                                    Il.Tmp ("bx" ++ String.fromInt base.reg)

                                  else
                                    Il.Tmp ("a" ++ String.fromInt base.reg)
                                )
                            )
                            bases
                            lambda.params
                        )

                else
                    Dict.empty
            , paramPtr =
                if ptrReadD then
                    Dict.fromList
                        (List.indexedMap (\i p -> ( p.id, Il.Tmp ("a" ++ String.fromInt i) )) lambda.params)

                else
                    Dict.empty
            , intBinders = intParams
            , table = sOuter.table
            , rep = sOuter.rep
            , primDirect = sOuter.primDirect
            , midCons = sOuter.midCons
            , rtLean = sOuter.rtLean
            , rec = sOuter.rec
            , consArr = sOuter.consArr
            , typeSpec = sOuter.typeSpec
            , midGcYoung = sOuter.midGcYoung
            , funcs = []
            , datas = sOuter.datas
            , dataKeys = sOuter.dataKeys
            , dataN = sOuter.dataN
            , cloN = sOuter.cloN + 1
            , binderN = sOuter.binderN
            , arities = sOuter.arities
            , defuns = sOuter.defuns
            , seeded = sOuter.seeded
            , defunKey =
                -- The SELF-tail check (lowerApp) must fire only when the
                -- function being compiled IS that defun.  A closure body
                -- (entry = False) is a SEPARATE function: tail-calling its
                -- enclosing defun there is a plain cross-function call, not
                -- an in-frame loop of the closure — so it gets no self key.
                if entry then
                    key

                else
                    ""
            , binderKey =
                -- The BINDER-MAP key is the `key` handed to lowerFunBody in
                -- BOTH cases: a top-level defun's own key, or — for a closure
                -- — its ENCLOSING defun's key (lowerClosure passes s.defunKey),
                -- which is exactly whose binder map holds the closure params'
                -- types.  A nested closure passes "" (its enclosing closure had
                -- no self key), so its lookups deny.
                key
            , qname = qname
            , abi = sOuter.abi
            , loops = sOuter.loops
            , ptrRead = sOuter.ptrRead
            , noCollect = sOuter.noCollect
            , leafFree = sOuter.leafFree
            }

        -- the (empty) @start block, closed by its fallthrough to @body
        sStart =
            closeBlock (Jmp "body") s0

        -- the signature, the return type and the prologue kind all switch on
        -- `rt` — RtGeneric is the GENERIC (closure-ABI) shape, byte-identical
        -- to the pre-midabi emission (the QBE_NORTLEAN=1 bisect hatch pins
        -- that identity).
        retTy =
            case rt of
                RtLeanRooted ->
                    Agg "val"

                RtLeanFree ->
                    Agg "val"

                RtRawWord ->
                    rawAbiRetClass key

                RtGeneric ->
                    Agg "ret"

        paramsList =
            case rt of
                RtLeanRooted ->
                    -- A's uniform direct shape: 3 pointer args (the caller
                    -- pads unused ones with the LAST REAL arg's pointer,
                    -- exactly rtPrimSlotsZig's convention — the padding is
                    -- never blitted) plus the count word, which the callee
                    -- ignores (the arity is static in the tree).
                    [ ( "a0", Base L ), ( "a1", Base L ), ( "a2", Base L ), ( "an", Base W ) ]

                RtLeanFree ->
                    [ ( "a0", Base L ), ( "a1", Base L ), ( "a2", Base L ), ( "an", Base W ) ]

                RtRawWord ->
                    -- B6: ONE `l` register per parameter, struct VALUE
                    -- parameters included — a struct crosses as the address of
                    -- the caller's storage and the callee copies it into its
                    -- own block at entry (see `structParamCopies`).
                    List.map (\i -> ( "a" ++ String.fromInt i, Base L )) (List.range 0 (nparams - 1))

                RtGeneric ->
                    -- VR1: a value param is an `l` POINTER to the caller's
                    -- 40-byte slot.  QBE's `:val` (a >16-byte aggregate) is
                    -- passed by value on the machine stack, so the old shape
                    -- paid a caller copy + a callee entry copy for every
                    -- argument; `l` passes the address the caller already has.
                    List.map (\i -> ( "a" ++ String.fromInt i, Base L )) (List.range 0 (nparams - 1))

        proKind =
            case rt of
                RtLeanFree ->
                    PAlloc

                RtRawWord ->
                    PAlloc

                _ ->
                    PFrame

        rtChecks =
            case rt of
                RtRawWord ->
                    -- no lean-arity bound: a word-ABI defun may take 0..maxArity
                    -- word params (Rt.halt is 0-ary); the capture bound still
                    -- holds (an Rt defun is never a closure).  The rawAbi
                    -- ARITY RECORD (stage 6 A1) checks the declared param
                    -- count against Mid.Rt.rawAbiArity instead of a bound —
                    -- for the DECLARED rawAbi keys only, which is what the
                    -- record covers (B6: a user defun's all-word signature
                    -- makes it word-ABI without the record ever naming it).
                    (if Set.member key MidRt.rawAbi then
                        rawAbiArityAgree key nparams

                     else
                        Ok ()
                    )
                        |> Result.andThen (\_ -> rtCapsErr)

                RtLeanRooted ->
                    rtArityErr |> Result.andThen (\_ -> rtCapsErr)

                RtLeanFree ->
                    rtArityErr |> Result.andThen (\_ -> rtCapsErr)

                RtGeneric ->
                    Ok ()
    in
    rtChecks
        |> Result.andThen
            (\_ ->
                case rt of
                    -- rawAbi bodies RETURN A WORD by default: lower the tail
                    -- through the raw-word path and hand the word to the @ret
                    -- block.  stage 6 B1: an AGGREGATE-returning rawAbi defun
                    -- (Rt.apply/Rt.apply-tail) lowers through the VALUE path
                    -- instead, so its body may end in an If/recur — the word
                    -- tail rejects both.
                    RtRawWord ->
                        if rawAbiRetIsAgg key then
                            startBlock "body" sStart
                                |> lowerTail lambda.body
                                |> Result.map (\s1 -> ( s1, Il.Tmp (slotTmp 0), False ))

                        else
                            startBlock "body" sStart
                                |> lowerTailWord lambda.body
                                |> Result.map (\( s1, retWord, _ ) -> ( s1, retWord, False ))

                    _ ->
                        startBlock "body" sStart
                            |> lowerTail lambda.body
                            |> Result.map
                                (\s1 ->
                                    let
                                        -- P5: THE FRAME-FREE DECISION.  It runs
                                        -- on the COMPLETE body (every path has
                                        -- closed its block) and BEFORE the @ret
                                        -- block exists — because the two things
                                        -- it decides are the frame-leave call
                                        -- here and the frame-enter in the
                                        -- prologue (via `pro`).
                                        --
                                        -- The predicate is the DEGENERATE case
                                        -- of Mid.Qbe.Liveness's per-safepoint
                                        -- slot maps (the analysis P8 consumes):
                                        -- no allocation-capable call site has a
                                        -- live frame slot, and no frame address
                                        -- escaped the defun.  Anything it
                                        -- cannot prove keeps the frame.
                                        leaf =
                                            leafOk
                                                && Liveness.frameFree
                                                    (Liveness.analyze
                                                        { retBytes = rvs
                                                        , nslots = s1.slot
                                                        , noCollect = sOuter.noCollect
                                                        }
                                                        (List.reverse s1.blocks)
                                                    )
                                    in
                                    ( s1, Il.Tmp (slotTmp 0), leaf )
                                )
            )
        |> Result.map
            (\( s1, rawWordResult, leaf ) ->
                let
                    -- every tail path ended in a closed block (jmp @ret/@body)
                    sRet =
                        case rt of
                            -- FRAME-FREE lean: no pooled frame was entered,
                            -- so there is nothing to pop — the scratch block
                            -- dies with this C frame at `ret`.
                            RtLeanFree ->
                                startBlock "ret" s1 |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                            -- rawAbi returns the body's WORD; an aggregate
                            -- return (stage 6 B1) hands slot 0 to sret — and
                            -- for the 80-byte `:ret`, the body leaves
                            -- mknum(buf) in slot 0 (buf = the :ret the loop
                            -- built in a malloc'd buffer), so the @ret block
                            -- reads the address back out of the number's
                            -- payload word 0 and blits the 80 bytes into the
                            -- sret area (slots 0+1).
                            RtRawWord ->
                                case rawAbiRetClass key of
                                    Agg "val" ->
                                        startBlock "ret" s1 |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                                    Agg "ret" ->
                                        -- THE .tail NO-COLLECT INVARIANT (stated
                                        -- at the Mid surface too, applyTailGo's
                                        -- saturated arm): this @ret block copies
                                        -- the .tail args out of the fresh allocvec
                                        -- array, which is UNROOTED and must be read
                                        -- EXACTLY ONCE by the callee prologue blit
                                        -- with NO collection in between.  Do NOT
                                        -- add a GC alloc to this block — it would
                                        -- break the invariant silently.
                                        --
                                        -- The `free(retBuf)` below is NOT a GC
                                        -- alloc (libc free is not a safepoint: it
                                        -- cannot collect, cannot move anything),
                                        -- and it runs AFTER the blit has copied
                                        -- the 80-byte :ret out of the malloc'd
                                        -- buffer — the buffer is dead from here.
                                        -- Without it every :ret producer leaks 80 B
                                        -- per call (Rt.apply-tail x2, Rt.tail-known
                                        -- — all three `malloc(80)` sites in
                                        -- runtime.mid), unbounded over a tail loop.
                                        startBlock "ret" s1
                                            |> emit (Bin (Just "retAddr") L Add (Il.Tmp (slotTmp 0)) (Il.Con (RtLayout.payloadWordOffset 0)))
                                            |> emit (Load (Just "retBuf") L LoadL (Il.Tmp "retAddr"))
                                            |> emit (Blit (Il.Tmp "retBuf") (Il.Tmp (slotTmp 0)) rvs)
                                            |> emit (Call Nothing (Base W) (Il.Sym "free") [ ArgVal (Base L) (Il.Tmp "retBuf") ])
                                            |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                                    _ ->
                                        startBlock "ret" s1 |> closeBlock (Ret (Just rawWordResult))

                            _ ->
                                if leaf then
                                    -- P5 FRAME-FREE: no pooled frame was
                                    -- entered, so there is nothing to pop and
                                    -- no registry entry to truncate — the
                                    -- alloc8 block dies with this C frame at
                                    -- `ret`, exactly the lean arm's shape.
                                    startBlock "ret" s1
                                        |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                                else
                                    -- stage 6 B0: the pooled frame is left through
                                    -- the Mid rawAbi defun q_Rt_x2eframe_x2dleave
                                    -- (0-arg, l result — the discarded-result call
                                    -- type is cosmetic: Print drops the AbiTy when
                                    -- dst is Nothing).  B4 deleted the Zig seat.
                                    startBlock "ret" s1
                                        |> emit
                                            (Call Nothing (Base W)
                                                (Il.Sym ("q_" ++ mangle "Rt.frame-leave"))
                                                []
                                            )
                                        |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                    pending =
                        { func =
                            { name =
                                -- stage 6 A1: the DRIVER ENTRY is exported as
                                -- `main`, not q_Rt_x2emain — crt0 links `main`
                                -- (the rtCallFuncs naming precedent: those
                                -- dispatchers are `export function` rt_callN).
                                -- Nothing else may name a defun `main`: the
                                -- override is keyed to Rt.main ONLY.
                                if key == "Rt.main" then
                                    "main"

                                else
                                    qname
                            , export_ =
                                -- The allocating seat is EXPORTED: the Zig
                                -- applyGo calls it for the partial-application env
                                -- array (the bridge in tools/qbe/rt.zig's weak
                                -- extern).  It was hatch-conditional until Z0; the
                                -- collector is unconditional, so the export is too.
                                -- Rt.main is ALWAYS exported: it is the program's
                                -- entry point under QBE_MIDDRIVER=1.
                                key == "Rt.allocVector" || key == "Rt.main"
                            , ret = retTy
                            , envParam = ncaps > 0
                            , params = paramsList
                            , blocks = List.reverse sRet.blocks
                            }
                        , nslots = s1.slot
                        , nparams = nparams
                        , ncaps = ncaps
                        , pro =
                            if leaf then
                                PLeaf

                            else
                                proKind
                        , rawAbi = rawAbi
                        , ptrRead = ptrReadD
                        , paramWidths = widths
                        , entryKey =
                            if entry then
                                Just key

                            else
                                Nothing
                        }
                in
                ( pending, sRet )
            )



{-| B6 — each parameter's incoming register and its width in words.  The
REGISTER is the parameter's ORDINAL (`a0`, `a1`, ...): the word ABI passes ONE
`l` register per parameter however wide it is — a struct VALUE crosses as the
ADDRESS of the caller's storage, and the callee copies `width` words out of it
at entry.  A parameter of width 1 is its own word, so the copy is skipped.
-}
paramBases : List Int -> List { reg : Int, width : Int }
paramBases widths =
    List.indexedMap (\i w -> { reg = i, width = w }) widths


-- ============================ TAIL / VALUE LOWERING ============================
-- Tail mode: the value lands in slot 0 and every COMPLETING path closes its
-- block with `jmp @ret` (or, for the self-tail loop, `jmp @body`).


lowerTail : Exp -> S -> Result String S
lowerTail exp s =
    case exp of
        NoTail inner ->
            lowerTail inner s

        App _ ->
            lowerApp exp 0 True s

        If block ->
            lowerIf block 0 True s

        Let block ->
            lowerLetBinders block.binders s
                |> Result.andThen (lowerTail block.body)

        Case branch ->
            lowerCase branch 0 True s

        Lam lambda ->
            lowerClosure lambda 0 s
                |> Result.map (jumpTo "ret")

        Unsafe (RawCall call) ->
            -- RawCall self-tail (zigretire stage 4): the collector's mark/sweep
            -- loops recurse through RawCall (Rt->Rt), and a 150k-deep list must
            -- not build 150k C frames.  When the call is THIS defun (the same
            -- key s.defunKey names), compile it as the in-frame loop the `App`
            -- self-tail already gets (stage args, blit to the param slots 2+i,
            -- jump @body).
            --
            -- NOT gated on the collector hatch (retired at Z0: this is the
            -- only route).  It was, on the stated non-assumption that
            -- "the pre-existing Rt helpers never put a self-RawCall in tail
            -- position" — MEASURED FALSE (2026-10-19): Rt.fillGo (runtime.mid,
            -- `return call Rt.fillGo(...)`) and ten more Rt helpers do exactly
            -- that, so under the default emit they were a native `call` with a
            -- 440-byte `alloc8` frame per iteration.  The seed-built compiler
            -- then died SIGSEGV with rsp 8 B below the stack bottom inside
            -- q_Rt.fillGo at the DEFAULT 8 MiB stack (and still at 64 MiB), on
            -- a workload the JS compiler runs in 1.5 s: the scale wall was
            -- stack depth.  A tail call is a tail call in either host mode, and
            -- the loop is what the hatch already emitted for these same defuns.
            if call.sym == s.defunKey then
                lowerSelfTail call.args s

            else
                lowerVal exp 0 s
                    |> Result.map (jumpTo "ret")

        _ ->
            lowerVal exp 0 s
                |> Result.map (jumpTo "ret")


{-| What a rawAbi WORD tail branch DID (stage 6 B0perf-2 nested-If fix):
`TailRet w` — the branch ended in `jmp @ret` carrying word `w`; `TailBody` —
the branch self-tailed (`jmp @body`).  The tail-`If` join combines THESE (a
branch that is itself an If has ALREADY reduced its own branches to one
shape), instead of peeking at the most-recently-closed block — which, for a
nested If, is the INNER else and hides the branch's real tail.  A
(TailRet,TailRet) join stays a loud Err (no phi node).
-}
type TailShape
    = TailRet Il.Arg
    | TailBody


{-| The rawAbi tail (stage 6 U2): the defun's tail VALUE is a WORD, not the
slot-0 `:val` `lowerTail` produces.  Statements (a `Let` chain) fold in the
same way; the leaf lowers through `rawWordArg` and the body block closes with
`jmp @ret`, handing the word to the caller's @ret block.  A tail `If` is the
word-valued branch join (`lowerIfWord`, stage 6 B0perf-2) and a tail `App` is
the self-tail loop (`lowerSelfTailWord`) — the two arms a word loop needs,
mirroring `lowerTail`'s handling of the same shapes.  Every OTHER tail shape
(an unknown App, a closure, a two-word join) stays a loud Err.  The returned
`TailShape` is the branch's OWN report (not a read of the block stack), so a
nested word-tail If joins on what each branch actually DID.
-}
lowerTailWord : Exp -> S -> Result String ( S, Il.Arg, TailShape )
lowerTailWord exp s =
    case exp of
        NoTail inner ->
            lowerTailWord inner s

        Let block ->
            lowerLetBinders block.binders s
                |> Result.andThen (lowerTailWord block.body)

        If block ->
            lowerIfWord block s

        App _ ->
            case wordSelfTailArgs exp s of
                Just args ->
                    lowerSelfTailWord args s

                Nothing ->
                    Err "qbe: raw-abi defun tail is an App (a word-valued tail call is not lowered — only a self-tail `recur` on the rawAbi word params is expressible)"

        _ ->
            rawWordArg exp s
                |> Result.map (\( a, s1 ) -> ( jumpTo "ret" s1, a, TailRet a ))


{-| The self-tail App check shared by `lowerTailWord`'s App arm — the same
test `lowerApp` makes (head is the self GRef at its declared arity), so a
rawAbi word defun's `recur` compiles to the in-frame loop the `:val` side
already gets.  A non-self App (or a `force` thunk) is `Nothing` -> loud.
-}
wordSelfTailArgs : Exp -> S -> Maybe (List Exp)
wordSelfTailArgs exp s =
    let
        ( head, args ) =
            spine exp
    in
    case head of
        GRef ref ->
            if not ref.force && ref.key == s.defunKey && Dict.get ref.key s.arities == Just (List.length args) then
                Just args

            else
                Nothing

        _ ->
            Nothing


{-| The rawAbi WORD self-tail (`recur` -> `jmp @body`).  The params are `l`
REGISTERS (a0..), never memory slots, so a loop-carried word can only re-enter
@body when it is ALREADY in its param register — the loop keeps its mutable
state in memory (the counter cell for Rt.copyWordsGo) and `recur`s on the
CONSTANT param.  A computed arg would need a register copy the word ABI cannot express
(no phi node, and `%a0` is already defined by the signature), so it is a loud
Err, not a silent wrong loop.
-}
lowerSelfTailWord : List Exp -> S -> Result String ( S, Il.Arg, TailShape )
lowerSelfTailWord args s =
    lowerSelfTailWordArgs args 0 s
        |> Result.map (\s1 -> ( jumpTo "body" s1, Il.Con 0, TailBody ))


lowerSelfTailWordArgs : List Exp -> Int -> S -> Result String S
lowerSelfTailWordArgs args i s =
    case args of
        [] ->
            Ok s

        e :: rest ->
            rawWordArg e s
                |> Result.andThen
                    (\( a, s1 ) ->
                        case a of
                            Il.Tmp t ->
                                if t == "a" ++ String.fromInt i then
                                    lowerSelfTailWordArgs rest (i + 1) s1

                                else
                                    Err
                                        ("qbe: raw-abi self-tail arg "
                                            ++ String.fromInt i
                                            ++ " is not the param register a"
                                            ++ String.fromInt i
                                            ++ " — the word loop can only recur on its constant params (the mutable state lives in memory)"
                                        )

                            _ ->
                                Err
                                    ("qbe: raw-abi self-tail arg "
                                        ++ String.fromInt i
                                        ++ " is not a param register — a computed word would need a register copy the word ABI cannot express"
                                    )
                    )


{-| The rawAbi WORD-valued tail If (stage 6 B0perf-2): each BRANCH is a
`lowerTailWord` tail, so a branch that `recur`s closes with `jmp @body` and a
branch that returns a word closes with `jmp @ret`.  The CONDITION is the
shared `condTest`: a WORD cond (`i == 0`) jumps on the raw 0/1 word directly
(`jnz` — no box, no slot); a `:val` cond (`mkbool(i == 0)`) keeps the
byte-identical jmpf machinery.  Exactly ONE branch may be ret-bound (the
other must be a self-tail): a two-word join would need a phi node and is a
LOUD Err, not a silent wrong word at @ret.  The join combines each branch's
`TailShape` (not a read of the block stack): a branch that is ITSELF an If
has already reduced its own arms to one shape, so a NESTED ret-bound word
survives.
-}
lowerIfWord : { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> S -> Result String ( S, Il.Arg, TailShape )
lowerIfWord block s =
    case condTest block.cond s of
        WordTest ->
            lowerIfWordWordCond block s

        ValTest ->
            let
                ( cslot, s0 ) =
                    freshSlot s
            in
            lowerVal block.cond cslot s0
                |> Result.andThen
                    (\s1 ->
                        let
                            ( tagT, s2 ) =
                                freshTmp s1

                            ( isbT, s3 ) =
                                freshTmp s2

                            ( pldT, s4 ) =
                                freshTmp s3

                            ( p8T, s5 ) =
                                freshTmp s4

                            ( iszT, s6 ) =
                                freshTmp s5

                            ( jfT, s7 ) =
                                freshTmp s6

                            ( thenLbl, s8 ) =
                                freshLbl "then" s7

                            ( elseLbl, s9 ) =
                                freshLbl "else" s8
                        in
                        Ok
                            (emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp cslot))) s9
                                |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con tagBoolean))
                                |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp cslot)) (Il.Con 8))
                                |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
                                |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
                                |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
                                |> closeBlock (Jnz (Il.Tmp jfT) elseLbl thenLbl)
                            )
                            |> Result.andThen (lowerTailWordBranches thenLbl elseLbl block)
                    )


{-| The WORD-cond tail If: `jnz` on the raw 0/1 word (then on nonzero, else
on zero) — no `mkbool`, no slot, no reload.  The branches are the same
`lowerTailWordBranches` tail join as the `:val` arm.
-}
lowerIfWordWordCond : { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> S -> Result String ( S, Il.Arg, TailShape )
lowerIfWordWordCond block s =
    let
        ( thenLbl, s1 ) =
            freshLbl "then" s

        ( elseLbl, s2 ) =
            freshLbl "else" s1
    in
    rawWordArg block.cond s2
        |> Result.andThen
            (\( w, s3 ) ->
                Ok (closeBlock (Jnz w thenLbl elseLbl) s3)
                    |> Result.andThen (lowerTailWordBranches thenLbl elseLbl block)
            )


{-| The two tail branches of a word-valued tail If, joined on `TailShape` —
the shared tail of `lowerIfWord`'s `:val` and word arms (byte-identical to the
pre-word-cond B0perf-2 body).
-}
lowerTailWordBranches : String -> String -> { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> S -> Result String ( S, Il.Arg, TailShape )
lowerTailWordBranches thenLbl elseLbl block s =
    startBlock thenLbl s
        |> lowerTailWord block.thenBranch
        |> Result.andThen
            (\( s_then, _, shapeThen ) ->
                lowerTailWord block.elseBranch (startBlock elseLbl s_then)
                    |> Result.andThen
                        (\( s_else, _, shapeElse ) ->
                            case ( shapeThen, shapeElse ) of
                                ( TailBody, TailBody ) ->
                                    Ok ( s_else, Il.Con 0, TailBody )

                                ( TailRet w, TailBody ) ->
                                    Ok ( s_else, w, TailRet w )

                                ( TailBody, TailRet w ) ->
                                    Ok ( s_else, w, TailRet w )

                                ( TailRet _, TailRet _ ) ->
                                    Err "qbe: raw-abi defun tail If joins two word-returning branches (a word-valued join is not lowered — one branch must be a self-tail recur)"
                        )
            )


lowerVal : Exp -> Int -> S -> Result String S
lowerVal exp dest s =
    case exp of
        Lit lit ->
            lowerLit lit dest s

        Var id ->
            -- Rt raw nodes (osier-consspike): a WORD binder (a raw address,
            -- tag or byte held in a temp) is NOT a Value and cannot be read
            -- in a value position — reboxing it as, say, a number would be a
            -- silent type confusion.  Loud, like every register-class error.
            if Dict.member id s.rawWord then
                Err ("qbe: raw word binder read in a VALUE position (binder id " ++ String.fromInt id ++ ") — raw binders are legal only inside raw node arguments")

            else
                lowerValValue id dest s

        GRef ref ->
            lowerGRefValue ref dest s

        NoTail inner ->
            lowerVal inner dest s

        App _ ->
            lowerApp exp dest False s

        PrimApp app ->
            lowerPrimApp app dest s

        Let block ->
            lowerLetBinders block.binders s
                |> Result.andThen (\s1 -> lowerVal block.body dest s1)

        If block ->
            lowerIf block dest False s

        Lam lambda ->
            lowerClosure lambda dest s

        Case branch ->
            lowerCase branch dest False s

        Con con ->
            lowerCon con dest s

        Tup es ->
            lowerTup es dest s

        RecordLit setters ->
            lowerRecordLit setters dest s

        RecordGet rec field ->
            lowerRecordGet rec field dest s

        RecordUpdate update ->
            lowerRecordUpdate update dest s

        ListLit es ->
            lowerVal (buildList es) dest s

        StreamRef { varName } ->
            -- Exactly Mid.ToZinc's `Symbol varName; Prim "value"`: materialize
            -- the stream's NAME as a symbol Value in a ROOTED frame slot, then
            -- run the REAL `value` primitive via rt_prim (which reads the value
            -- table the runtime wired — Vm.init's *stinput*/*stoutput*/*sterror*).
            let
                ( symSlot, s1 ) =
                    freshSlot s
            in
            lowerLit (LSymbol varName) symSlot s1
                |> Result.andThen (\s2 -> rtPrimSlots "value" [ symSlot ] dest s2)

        ShortAnd block ->
            lowerShortAnd block dest s

        ShortOr block ->
            lowerShortOr block dest s

        NotEqual block ->
            lowerNotEqual block dest s

        Loop block ->
            lowerLoop block dest s

        Break ->
            lowerLoopLeaf "exit" s

        Continue ->
            lowerLoopLeaf "top" s

        -- Unsafe (osier-rawnodes / osier-consspike): the Rt-program
        -- lowering — legal only under Rt.* keys (Mid.Audit enforces that on
        -- every compile), and only VALUE producers reach here (RawMkValue,
        -- RawVecLoad, WithRoots; word producers are a loud error: they bind
        -- to raw temps in `let` positions, never to value destinations).
        Unsafe node ->
            lowerRawVal node dest s


{-| VR1 — the base ADDRESS of a binder's 40-byte Value: the incoming `l`
pointer for a ptrRead parameter (the CALLER's rooted slot, read in place — no
copy), otherwise the binder's own frame slot.  The two maps are disjoint
(ptrRead params are registered in `paramPtr` and NOT in `binderSlots`), so this
is also the total answer for a Value binder.
-}
valueBaseOf : Int -> S -> Maybe Il.Arg
valueBaseOf id s =
    case Dict.get id s.paramPtr of
        Just p ->
            Just p

        Nothing ->
            Maybe.map (\slot -> Il.Tmp (slotTmp slot)) (Dict.get id s.binderSlots)


-- The original `Var` body (everything except the raw-word check above).
lowerValValue : Int -> Int -> S -> Result String S
lowerValValue id dest s =
    -- S4: a binder whose value is held RAW (unboxed Int local) is
    -- reconstructed as a tagged Value HERE.  This single place is the
    -- rebox-at-every-boundary rule: call arguments, aggregate stores,
    -- returns, tail-call moves and case scrutinees all reach their
    -- binder through `lowerVal`.
    case Dict.get id s.rawInt of
        Just raw ->
            Ok (reboxArg dest raw s)

        Nothing ->
            -- S4f: the same boundary for a raw FLOAT (`tagFloat` +
            -- `stored`) — the one place a raw `d` operand is turned
            -- back into a 40-byte value.
            case Dict.get id s.rawFloat of
                Just raw ->
                    Ok (reboxFloat dest raw s)

                Nothing ->
                    case valueBaseOf id s of
                        Just src ->
                            Ok (emit (Blit src (Il.Tmp (slotTmp dest)) vs) s)

                        Nothing ->
                            Err ("qbe: unbound binder id " ++ String.fromInt id ++ " (corrupt Mid tree)")



-- ============================ RT RAW NODES (osier-consspike) ============================
-- The Unsafe-node lowering — Rt.* defuns only (Mid.Audit holds that on every
-- compile).  THE REGISTER CLASS: value producers land in an ordinary rooted
-- frame slot through `dest`; word producers (addresses, tags, payload words)
-- are computed into raw TEMPS and reach this section only through
-- `rawWordArg` (raw-argument positions of other raw nodes) or through a
-- `let` binder recorded in `s.rawWord` (lowerLetBinder's isRawWordExp arm).
--
-- GC CONTRACT, restated from Mid.Ir's header: a raw array address is a
-- register temp, INVALID across any safepoint; `rt_vec_alloc` is the only
-- safepoint these nodes can introduce, and a well-formed Rt body fills and
-- consumes before the next one.  Values live in rooted frame slots (the
-- pooled ROOT_VALUE_ARRAY), which is also why `WithRoots` needs no code
-- here — see its arm.


lowerRawVal : UnsafeNode -> Int -> S -> Result String S
lowerRawVal node dest s =
    case node of
        RawMkValue mk ->
            -- Build a Value cell in the dest slot: the u32 tag, then payload
            -- word i at offset 8 + 8i (gc/types.zig's extern union behind the
            -- tag — :val = align 8 { w, l 4 }, word 0 at 8).  Unwritten
            -- payload words stay ZERO (the slot was zeroed at rt_frame_enter),
            -- which is a valid number-0-shaped tail — the caller writes every
            -- word its constructor has.  Float-typed words (isFloatWordExp)
            -- lower into `d` temps and store with `stored`.
            storeValueWords mk.tag mk.words dest s

        RawVecLoad load ->
            -- Element i's VALUE, blitted into the dest slot (a load never
            -- barriers).
            rawWordArg load.vec s
                |> Result.andThen
                    (\( vecT, s1 ) ->
                        rawWordArg load.index s1
                            |> Result.map
                                (\( idxT, s2 ) ->
                                    let
                                        ( eT, s3 ) =
                                            elemAddr vecT idxT s2
                                    in
                                    emit (Blit (Il.Tmp eT) (Il.Tmp (slotTmp dest)) vs) s3
                                )
                    )

        RawVecStore store ->
            -- Store the VALUE at vec[i] THROUGH the runtime's ONE barrier
            -- seat.  The stored value is lowered into a fresh ROOTED slot
            -- first — its address is the argument.
            -- `dest` is deliberately IGNORED: this node is an effect, and its
            -- let binder's slot stays zero (a valid Value; nothing reads it).
            rawWordArg store.vec s
                |> Result.andThen
                    (\( vecT, s1 ) ->
                        rawWordArg store.index s1
                            |> Result.andThen
                                (\( idxT, s2 ) ->
                                    let
                                        ( vslot, s3 ) =
                                            freshSlot s2
                                    in
                                    lowerVal store.value vslot s3
                                        |> Result.map
                                            (\s4 ->
                                                -- zighost Z2: THE SEAM IS MID'S.
                                                -- Both writers are rawAbi word
                                                -- defuns (runtime.mid
                                                -- Rt.vecStorePlain /
                                                -- Rt.vecStoreYoung), so the
                                                -- call is 3 words and the
                                                -- callee loads the region
                                                -- from rt_glob_addr ITSELF —
                                                -- the emission no longer has
                                                -- to fetch it (the deleted Zig
                                                -- seat took it as a 4th arg
                                                -- because hostshim could not
                                                -- name the block; it can, and
                                                -- Mid reads it directly).
                                                --
                                                -- young build: the NURSERY
                                                -- barrier — store, then
                                                -- record the vector in the
                                                -- remembered set iff it is an
                                                -- OLD live value-array and
                                                -- the stored Value references
                                                -- young.
                                                --
                                                -- young off: the PLAIN seat —
                                                -- a mark-sweep has no
                                                -- remembered set, so the
                                                -- store IS the whole contract
                                                -- (the record arms below name
                                                -- the same defun: a freshly
                                                -- allocated array cannot be
                                                -- old).
                                                --
                                                -- The index crosses as `l`
                                                -- (the callee's param is a
                                                -- word register, not the C
                                                -- `int` the Zig seat took).
                                                if s.midGcYoung then
                                                    emit
                                                        (Call Nothing (Base W)
                                                            (Il.Sym ("q_" ++ mangle "Rt.vecStoreYoung"))
                                                            [ ArgVal (Base L) vecT
                                                            , ArgVal (Base L) idxT
                                                            , ArgVal (Base L) (Il.Tmp (slotTmp vslot))
                                                            ]
                                                        )
                                                        s4

                                                else
                                                    emit
                                                        (Call Nothing (Base W)
                                                            (Il.Sym ("q_" ++ mangle "Rt.vecStorePlain"))
                                                            [ ArgVal (Base L) vecT
                                                            , ArgVal (Base L) idxT
                                                            , ArgVal (Base L) (Il.Tmp (slotTmp vslot))
                                                            ]
                                                        )
                                                        s4
                                            )
                                )
                    )

        WithRoots rooted ->
            -- DOCUMENTED NO-OP on this backend: rt_frame_enter already
            -- registered the WHOLE pooled frame as one ROOT_VALUE_ARRAY, so
            -- every Value binder of `rooted.binders` is a live root for the
            -- entire body — the node is the backend-INDEPENDENT statement of
            -- the discipline (Mid.Ir's header), and a backend without the
            -- rooted-frame convention lowers it to real pushes.  The body is
            -- lowered in place, into the same dest.
            lowerVal rooted.body dest s

        RawByteStore bs ->
            -- One byte into a raw buffer (effect; dest ignored like
            -- RawVecStore's).  NO write barrier — raw bytes hold no GC
            -- pointers by construction (Mid.Ir's node contract).
            rawWordArg bs.ptr s
                |> Result.andThen
                    (\( pT, s1 ) ->
                        rawWordArg bs.index s1
                            |> Result.andThen
                                (\( iT, s2 ) ->
                                    rawWordArg bs.value s2
                                        |> Result.map
                                            (\( vT, s3 ) ->
                                                let
                                                    ( aT, s4 ) =
                                                        freshTmp s3
                                                in
                                                emit
                                                    (Bin (Just aT) L Add pT iT)
                                                    s4
                                                    |> emit (Store StoreB vT (Il.Tmp aT))
                                            )
                                )
                    )

        RawWordStore ws ->
            -- One 8-byte word at ptr + 8*index (effect; dest ignored like
            -- RawByteStore's).  NO write barrier — the word is host
            -- bookkeeping (a header, a page descriptor, a free-list link),
            -- not a GC Value (Mid.Ir's node contract).
            rawWordArg ws.ptr s
                |> Result.andThen
                    (\( pT, s1 ) ->
                        rawWordArg ws.index s1
                            |> Result.andThen
                                (\( iT, s2 ) ->
                                    rawWordArg ws.value s2
                                        |> Result.map
                                            (\( vT, s3 ) ->
                                                let
                                                    ( aT, s4 ) =
                                                        wordAddr pT iT s3
                                                in
                                                emit (Store StoreL vT (Il.Tmp aT)) s4
                                            )
                                )
                    )

        RawMemStore ms ->
            -- (cffi U6) `width` bytes of the value's LOW bits at ptr + off —
            -- `storeb`/`storeh`/`storew`, addressed at a BYTE offset.  The
            -- value is a word expression and the sub-word stores take a `w`
            -- operand; QBE's Subtyping rule lets the `l` temp sit in that
            -- slot (MEASURED: the low 16 bits land), so no narrowing `copy`
            -- is emitted.  NO barrier: a narrow field is host data.
            rawWordArg ms.ptr s
                |> Result.andThen
                    (\( pT, s1 ) ->
                        rawWordArg ms.value s1
                            |> Result.map
                                (\( vT, s2 ) ->
                                    let
                                        ( aT, s3 ) =
                                            memAddr pT ms.off s2
                                    in
                                    emit (Store (memStoreTy ms.width) vT (Il.Tmp aT)) s3
                                )
                    )

        RawCall call ->
            -- STEP 5 (osier-midprims): Rt->Rt calls, the recursive helpers'
            -- voice (deepEqual, numberText, the list walks) — and since
            -- M3fix-4 a user .mid's cross-module call, which is this same
            -- shape.  Lowered for any key this program DEFINES: args are
            -- VALUES lowered into fresh slots, then the call.  THE LEAN ABI
            -- (osier-midabi): the same shape rtPrimSlots' mid route emits — 3
            -- pointer args padded with the last real slot, plus the count
            -- word, DIRECT :val return, one blit to dest — no rt_bounce
            -- anywhere on an Rt->Rt edge.  SOUNDNESS: the staged slots live in
            -- the CALLER's frame, and the classification guarantees the
            -- pairing — if the CALLEE can allocate, this caller is
            -- `allocating` too, so these slots are ROOTED (rt_frame_enter); if
            -- the callee is frame-free, no GC can run anywhere under this
            -- call.  QBE_NORTLEAN=1 restores the fat :val-args/:ret/rt_bounce
            -- shape.
            --
            -- THE ACCEPTANCE (M3fix-4) is MEMBERSHIP IN THIS PROGRAM's defun
            -- set (`s.defuns`) — the keys whose `q_` symbol the emission fold
            -- or the Rt seeding can produce — NOT a name SHAPE: since M3 a
            -- user .mid `call` may name ANOTHER user module's exported defun,
            -- and that RawCall lowers to this same `q_<key>` call (grefsOf's
            -- Unsafe arm supplies the call-graph edge, so the callee IS
            -- emitted — MEASURED: accepting without that edge links with an
            -- undefined `q_CrossB_x2eg`).  A key that names no defun of this
            -- program stays a LOUD Err below: that is what stops a call to
            -- nothing.  HONEST SPAN, MEASURED: `defuns` is the PROGRAM's, not
            -- the EMITTED set — for a non-Rt key the two coincide (the grefsOf
            -- edge just above), and since M3-rtcall the SAME edge reports an
            -- injected Rt KEY too (a RawCall to any program defun is a call
            -- edge), so `reach` pulls the Rt callee and its closure into the
            -- emitted set and the two coincide for an Rt key as well.  The
            -- residual: an Rt key reached ONLY through a PRIM (a PrimApp, not
            -- a RawCall) stays seeded by Mid.Rt.seeds/rtDeps, which this arm
            -- never sees — that path is the used-prim census, unchanged.
            if Dict.member call.sym s.abi then
                -- stage 6 U2 / B6: a WORD-ABI defun is WORD-in/WORD-out — it
                -- never appears in a VALUE position (its let binder is a raw
                -- temp, via isRawWordExp/rawWordArg).
                Err ("qbe: word-ABI call in a VALUE position (" ++ call.sym ++ ") — a word-producing defun binds to a let binder and is legal only in raw-argument/tail positions")

            else if Dict.member call.sym s.defuns then
                lowerArgsToSlots call.args s
                    |> Result.andThen
                        (\( slots, s1 ) ->
                            -- The callee's ABI is chosen by the SAME rule
                            -- lowerDefun uses: an Rt.* key is lean when
                            -- QBE_NORTLEAN is off, EVERY program defun
                            -- (a user .mid's exported defun included) is
                            -- RtGeneric.  Calling a RtGeneric defun with the
                            -- lean shape is a silent ABI clash (MEASURED on
                            -- the first cut of M3fix-4: the lean 4-arg call
                            -- reached a 1-:val-param callee and the built
                            -- binary SEGFAULTED), so the shape is keyed on the
                            -- callee, not on the program-wide flag alone.
                            if s.rtLean && isRtKey call.sym then
                                if List.length slots >= 1 && List.length slots <= maxDirectArity then
                                    let
                                        ( vp, s2 ) =
                                            freshTmp s1

                                        ptrs =
                                            List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots

                                        pad =
                                            ArgVal (Base L) (Il.Tmp (slotTmp (lastSlot slots)))

                                        padded =
                                            ptrs ++ List.repeat (maxDirectArity - List.length ptrs) pad
                                    in
                                    Ok
                                        (emit
                                            (Call (Just vp)
                                                (Agg "val")
                                                (Il.Sym ("q_" ++ mangle call.sym))
                                                (padded ++ [ ArgVal (Base W) (Il.Con (List.length slots)) ])
                                            )
                                            s2
                                            |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                                        )

                                else
                                    Err ("qbe: rawCall to " ++ call.sym ++ " stages arity " ++ String.fromInt (List.length slots) ++ " — the lean ABI passes 1.." ++ String.fromInt maxDirectArity ++ " pointer args")

                            else
                                let
                                    ( rp, s2 ) =
                                        freshTmp s1

                                    ( vp, s3 ) =
                                        freshTmp s2
                                in
                                Ok
                                    (s3
                                        |> emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle call.sym)) (List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots))
                                        |> emit (Call (Just vp) (Agg "val") (Il.Sym (bounceSeat s)) [ ArgVal (Base L) (Il.Tmp rp) ])
                                        |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                                    )
                        )

            else
                Err ("qbe: rawCall to " ++ call.sym ++ " — not a defun of this program (word-level C seats are rawCallRaw)")

        RawStrByte _ ->
            Err wordProducerMessage

        RawTagOf _ ->
            Err wordProducerMessage

        RawPayload _ ->
            Err wordProducerMessage

        RawAllocVector _ ->
            Err wordProducerMessage

        RawVecAddr _ ->
            Err wordProducerMessage

        -- step 5's word producers (and the float words, a class over) never
        -- appear in value positions either:
        RawPayload32 _ ->
            Err wordProducerMessage

        RawTagIs _ ->
            Err wordProducerMessage

        RawBin _ ->
            Err wordProducerMessage

        RawUn _ ->
            Err wordProducerMessage

        RawCmp _ ->
            Err wordProducerMessage

        RawFltBin _ ->
            Err "qbe: raw FLOAT-word node in a value position — float words are legal only nested in float-argument positions and RawMkValue word lists"

        RawFltCmp _ ->
            Err "qbe: raw FLOAT-word node in a value position — float words are legal only nested in float-argument positions and RawMkValue word lists"

        RawIToF _ ->
            Err "qbe: raw FLOAT-word node in a value position — float words are legal only nested in float-argument positions and RawMkValue word lists"

        RawLoadFlt _ ->
            Err "qbe: raw FLOAT-word node in a value position — float words are legal only nested in float-argument positions and RawMkValue word lists"

        RawAllocRaw _ ->
            Err wordProducerMessage

        RawByteLoad _ ->
            Err wordProducerMessage

        RawWordLoad _ ->
            Err wordProducerMessage

        -- cffi U6: a width-typed load is a WORD producer (an `l` temp — every
        -- sub-word load WIDENS into the word class), so a value position is
        -- the same loud error RawWordLoad gets.
        RawMemLoad _ ->
            Err wordProducerMessage

        RawCallRaw _ ->
            Err wordProducerMessage

        -- cffi U2: the typed C boundary is a WORD producer on every width it
        -- lowers (FW32S/FW32U arrive extended from the `w` result; FW64 and
        -- FVoid are an `l` temp), so a value position is the same loud
        -- "raw word in VALUE position" error RawCallRaw gets.  An `f64` result
        -- is a FLOAT word and gets the float family's message (cffi U3).
        RawCallExtern call ->
            case call.result of
                FF64 ->
                    Err "qbe: raw FLOAT-word node in a value position — float words are legal only nested in float-argument positions and RawMkValue word lists"

                _ ->
                    Err wordProducerMessage

        RawCallAgg call ->
            -- stage 6 A1: a rawCallAgg in VALUE position is the driver's
            -- "sret result as a Value" shape — `Call (Just t) (Agg "val")
            -- <callee> [word args]` then a Blit of the 40-B :val into the
            -- dest slot, EXACTLY the rtApply non-tail shape (lowerApp's
            -- rtApply arm: `%v =:val call rt_apply(...)` + blit into dest).
            -- This is how the driver turns rt_bounce/rt_parse_arg/
            -- rt_run_program's sret results into Values.  Only shape "val"
            -- fits a :val slot — "ret" is 80 B and cannot blit into 40.
            if call.shape /= "val" then
                Err "qbe: rawCallAgg in a VALUE position must be shape \"val\" (a 40-B :val fits the slot; \"ret\" is 80 B and cannot)"

            else
                lowerRawCallAgg call s
                    |> Result.map
                        (\( fnA, args, s1 ) ->
                            let
                                ( t, s2 ) =
                                    freshTmp s1
                            in
                            emit (Call (Just t) (Agg "val") fnA args) s2
                                |> emit (Blit (Il.Tmp t) (Il.Tmp (slotTmp dest)) vs)
                        )

        RawDataAddr _ ->
            Err wordProducerMessage

        RawCStr _ ->
            Err wordProducerMessage

        RawSym _ ->
            Err wordProducerMessage

        RawAllocN _ ->
            Err wordProducerMessage


wordProducerMessage : String
wordProducerMessage =
    "qbe: raw WORD node in a value position — word producers (rawAllocVector, rawVecAddr, rawTagOf, rawPayload) bind to let binders and are legal only in raw-argument positions"


-- The tag + payload words of a Value cell into the dest slot, temp supply
-- threaded (each word's payload-address temp is fresh — a first cut
-- allocated them all from one frozen state and every word shared a name).
storeValueCell : Int -> List Il.Arg -> Int -> S -> S
storeValueCell tag words dest s0 =
    let
        s1 =
            emit (Store StoreW (Il.Con tag) (Il.Tmp (slotTmp dest))) s0

        go : Int -> S -> List Il.Arg -> S
        go i acc ws =
            case ws of
                [] ->
                    acc

                w :: rest ->
                    let
                        ( pT, acc1 ) =
                            freshTmp acc

                        acc2 =
                            acc1
                                |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (RtLayout.payloadWordOffset i)))
                                |> emit (Store StoreL w (Il.Tmp pT))
                    in
                    go (i + 1) acc2 rest
    in
    go 0 s1 words


{-| The Exp-level RawMkValue path: lower each word (float-typed words into
`d` temps stored with `stored`, integer words into the l class with
`storel`), then the same cell stores as storeValueCell.
-}
storeValueWords : Int -> List Exp -> Int -> S -> Result String S
storeValueWords tag words dest s0 =
    List.foldl
        (\e acc ->
            Result.andThen
                (\( ws, st ) ->
                    if isFloatWordExp e then
                        rawFltArg e st
                            |> Result.map (\( a, st2 ) -> ( ws ++ [ ( a, True ) ], st2 ))

                    else
                        rawWordArg e st
                            |> Result.map (\( a, st2 ) -> ( ws ++ [ ( a, False ) ], st2 ))
                )
                acc
        )
        (Ok ( [], s0 ))
        words
        |> Result.map
            (\( ws, s1 ) ->
                let
                    sTag =
                        emit (Store StoreW (Il.Con tag) (Il.Tmp (slotTmp dest))) s1

                    go : Int -> S -> List ( Il.Arg, Bool ) -> S
                    go i st rest =
                        case rest of
                            [] ->
                                st

                            ( w, isFlt ) :: more ->
                                let
                                    ( pT, st1 ) =
                                        freshTmp st

                                    st2 =
                                        st1
                                            |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (RtLayout.payloadWordOffset i)))
                                            |> emit (Store (if isFlt then StoreD else StoreL) w (Il.Tmp pT))
                                in
                                go (i + 1) st2 more
                in
                go 0 sTag ws
            )



-- Evaluate a list of raw-word expressions (RawMkValue's payload words) in
-- order, threading the temp supply.
rawWordArgs : List Exp -> S -> Result String ( List Il.Arg, S )
rawWordArgs exps s =
    case exps of
        [] ->
            Ok ( [], s )

        e :: rest ->
            rawWordArg e s
                |> Result.andThen
                    (\( a, s1 ) ->
                        rawWordArgs rest s1
                            |> Result.map (\( as_, s2 ) -> ( a :: as_, s2 ))
                    )


{-| (cffi U2) ONE argument of a typed C call: the operand expression and the
REGISTER CLASS the `extern` declaration gives that position.  Zipped from the
IR node's parallel `argWidths`/`args` lists, so the emitter reads the width
the DECLARATION wrote (carried in the node) rather than re-deriving it.

A length disagreement is a LOUD internal error: the checker pins the arity
from the same declaration, so a mismatch here means the two readers of one
table drifted — the failure this repo keeps paying for — and it must never
fall back to the old all-word convention.
-}
type alias FfiArg =
    { exp : Exp
    , width : FfiWidth
    }


zipWidths : String -> List FfiWidth -> List Exp -> Result String (List FfiArg)
zipWidths sym widths exps =
    if List.length widths == List.length exps then
        Ok (List.map2 (\w e -> { exp = e, width = w }) widths exps)

    else
        Err
            ("qbe: cffi U2: the declaration's "
                ++ String.fromInt (List.length widths)
                ++ " argument width(s) and the call's "
                ++ String.fromInt (List.length exps)
                ++ " argument(s) disagree — the checker and the emitter read one table and it drifted"
            )


{-| (cffi U3) ONE declared argument's OPERAND: the `d` class goes through
`rawFltArg` (the float-producer route `RawLoadFlt`/`RawIToF` already use) and
every word class through `rawWordArg`.

The class this dispatches on is `ffiArgClass ew.width` — the SAME function the
call's `ArgVal` reads two lines below, so an operand cannot be LOWERED as one
class and TYPED as another.  Where the U2 unit refused an `f64` parameter
loudly, this is the arm that lifts it: `strfromd(str, n, fmt, 1.5)` is the
fixture (`tools/qbe/fixtures/ffid-f64.mid`), and plan §3.2 MEASURED the
`call $fmod(d %x, d %y)` shape this produces.

NOT `List.member`/`==` on `FfiWidth`: MEASURED, the selfhost's `List.member`
demands `comparable` elements and rejects a user ADT (the trap Check.elm:598
records — it broke a bootstrap emit in U2 with "cannot unify comparable with
Mid.Ir.FfiWidth").  A `case` walk is what both compilers accept.
-}
rawFfiArg : FfiArg -> S -> Result String ( Il.Arg, S )
rawFfiArg ew st =
    case ew.width of
        FF64 ->
            rawFltArg ew.exp st

        FW32S ->
            rawWordArg ew.exp st

        FW32U ->
            rawWordArg ew.exp st

        FW64 ->
            rawWordArg ew.exp st

        FVoid ->
            rawWordArg ew.exp st


{-| (cffi U4) Insert the IL's `...` marker after the declaration's FIXED
arguments — the one thing a variadic call needs that a fixed one does not.

WHY THE MARKER IS MANDATORY EVEN WITH ZERO VARIADIC ARGUMENTS: QBE sets the
SysV vector-register count (`%al`) from the arguments AFTER the marker
(MEASURED, plan §5: `movl $1, %eax` with one `d` among them, `movl $0, %eax`
with none).  A variadic callee's `va_start` prologue reads `%al` whatever the
number of arguments, so omitting the marker for `printf(fmt)` would hand it
whatever the previous code left in `%eax` — the silent ABI break this whole
arc exists to prevent.  Position, not argument count, is what QBE reads.

The split point is `fixedArgs`, NOT "the last word-class argument": a fixed
`ptr` argument is `FW64` exactly like a variadic word, so the count has to come
from the declaration (it rides on the node for that reason).
-}
withEllipsis : Bool -> Int -> List CallArg -> List CallArg
withEllipsis varargs fixedArgs args =
    if varargs then
        let
            ( fixedPart, variadicPart ) =
                splitAtCount fixedArgs args
        in
        fixedPart ++ [ ArgEllipsis ] ++ variadicPart

    else
        args


splitAtCount : Int -> List a -> ( List a, List a )
splitAtCount n xs =
    if n <= 0 then
        ( [], xs )

    else
        case xs of
            [] ->
                ( [], [] )

            x :: rest ->
                let
                    ( a, b ) =
                        splitAtCount (n - 1) rest
                in
                ( x :: a, b )


{-| The register class of one DECLARED argument.  `w` for the 32-bit family
(a C `int` parameter is read from %edi/%esi/...), `l` for i64/u64/ptr — plan
§3.2's measured table.  `FF64` and `FVoid` cannot appear in a parameter
position (the grammar refuses `void` there, and the `d` class is U3's); the
`w` fallback here is UNREACHABLE for checked input and is not a silent
default: the checker classified the argument against this same table.
-}
ffiArgClass : FfiWidth -> AbiTy
ffiArgClass w =
    case w of
        FW32S ->
            Base W

        FW32U ->
            Base W

        FW64 ->
            Base L

        FF64 ->
            Base D

        FVoid ->
            Base L



{-| The Mid routing for the two raw allocating nodes: box the length
word into a number Value slot, call the Mid seat's lean-ABI `q_Rt_*` entry
(one pointer arg, direct `:val` return), and read the body address back out
of the result's payload word 0 into a raw temp.  The seat is `Rt.allocVector`
/ `Rt.allocRaw` — the Mid allocating seats whose bodies own the heap and
trigger `Rt.collect` (Mid.RtGc).
-}
midGcAllocSeat : String -> Il.Arg -> S -> ( Il.Arg, S )
midGcAllocSeat seatKey lenA s =
    let
        ( slot, s1 ) =
            freshSlot s

        s2 =
            storeValueCell tagNumber [ lenA ] slot s1

        ( vp, s3 ) =
            freshTmp s2

        slotArg =
            ArgVal (Base L) (Il.Tmp (slotTmp slot))

        padded =
            slotArg :: List.repeat (maxDirectArity - 1) slotArg

        ( aT, s4 ) =
            freshTmp s3

        ( t, s5 ) =
            freshTmp s4
    in
    ( Il.Tmp t
    , emit (Call (Just vp) (Agg "val") (Il.Sym ("q_" ++ mangle seatKey)) (padded ++ [ ArgVal (Base W) (Il.Con 1) ])) s5
        |> emit (Bin (Just aT) L Add (Il.Tmp vp) (Il.Con (RtLayout.payloadWordOffset 0)))
        |> emit (Load (Just t) L LoadL (Il.Tmp aT))
    )


{-| stage 6 P1b Step B — the slot base of a Value operand, when that operand
is ALREADY a slot-resident binder (a `:val` param, a value `let`, a capture,
a case scrutinee).  A field projection (`payload`/`payload32`/`tagis`/
`tagOf`) on such a binder reads its word straight out of the binder's OWN
slot; the pre-existing shape re-`lowerVal`-ed the binder into a FRESH slot
first, which for a `:val` is a full 40-byte Blit — so `Rt.applyGo`'s five
`payload(f, k)`/`tagis(f, 6)` reads re-blitted the same 40-byte `f` five
times.  rawInt/rawFloat/rawWord binders are never in `binderSlots` (a binder
is registered in exactly ONE map — lowerLetBinder), so the membership test
alone picks out the real Value slots.
-}
slotBaseOf : Exp -> S -> Maybe Il.Arg
slotBaseOf exp s =
    -- stage 6 P1b Step B: the read-direct-from-slot fast path.  B4 removed the
    -- midDriver gate (there is no OFF route any more), so this is unconditional.
    case exp of
        Var id ->
            valueBaseOf id s

        _ ->
            Nothing


{-| The base address of a Value operand for a field projection: the binder's
own slot when `slotBaseOf` matches (no copy), else a fresh slot holding the
lowered Value (the pre-existing shape).  Exactly the semantics `lowerVal`-then-
load had; only the redundant Blit is gone.
-}
rawValueBase : Exp -> S -> Result String ( Il.Arg, S )
rawValueBase v s =
    case slotBaseOf v s of
        Just base ->
            Ok ( base, s )

        Nothing ->
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal v vslot s1
                |> Result.map (\s2 -> ( Il.Tmp (slotTmp vslot), s2 ))


{-| Evaluate ONE raw-word expression (a raw node argument position): a word
constant, a raw-word binder's temp, or a word-producing raw node computed
into a fresh temp.  Anything else — a Value binder, a value expression — is a
LOUD register-class error, never an implicit rebox or address-of.
-}
rawWordArg : Exp -> S -> Result String ( Il.Arg, S )
rawWordArg exp s =
    case exp of
        Lit (LNumber n) ->
            Ok ( Il.Con n, s )

        Var id ->
            case Dict.get id s.rawWord of
                Just a ->
                    Ok ( a, s )

                Nothing ->
                    -- B4: an INT binder (S4's raw `l` operand) IS a word — the
                    -- same register class, one representation.  Without this
                    -- arm a `word n = 3;` local could not be read in ANY raw
                    -- position (a compare, an index, `mknum(n)`), so a
                    -- READ-ONLY loop bound was unexpressible: exactly the
                    -- register the auto-cell rule promises to leave alone.
                    case Dict.get id s.rawInt of
                        Just a ->
                            Ok ( a, s )

                        Nothing ->
                            Err ("qbe: binder id " ++ String.fromInt id ++ " is not a raw word — value binders cannot appear in raw-argument positions")

        Unsafe (RawAllocVector len) ->
            rawWordArg len s
                |> Result.map
                    (\( lenA, s1 ) ->
                        midGcAllocSeat "Rt.allocVector" lenA s1
                    )

        Unsafe (RawVecAddr addr) ->
            rawWordArg addr.vec s
                |> Result.andThen
                    (\( vecT, s1 ) ->
                        rawWordArg addr.index s1
                            |> Result.map
                                (\( idxT, s2 ) ->
                                    let
                                        ( eT, s3 ) =
                                            elemAddr vecT idxT s2
                                    in
                                    ( Il.Tmp eT, s3 )
                                )
                    )

        Unsafe (RawTagOf v) ->
            rawValueBase v s
                |> Result.map
                    (\( base, s1 ) ->
                        let
                            ( t, s2 ) =
                                freshTmp s1
                        in
                        ( Il.Tmp t, emit (Load (Just t) W LoadW base) s2 )
                    )

        Unsafe (RawPayload p) ->
            rawValueBase p.value s
                |> Result.map
                    (\( base, s1 ) ->
                        let
                            ( aT, s2 ) =
                                freshTmp s1

                            ( t, s3 ) =
                                freshTmp s2
                        in
                        ( Il.Tmp t
                        , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset p.word))) s3
                            |> emit (Load (Just t) L LoadL (Il.Tmp aT))
                        )
                    )

        -- ===== STEP 5 (osier-midprims): the scalar + string word producers
        Unsafe (RawPayload32 p) ->
            -- the i32 FIELDS (str.len, vector.len, boolean): loadsw at the
            -- word's low half + extsw to the l word class.  A 64-bit read
            -- here would compare garbage high halves against Zig-built
            -- Values (the extern-struct store never writes them).
            rawValueBase p.value s
                |> Result.map
                    (\( base, s1 ) ->
                        let
                            ( aT, s2 ) =
                                freshTmp s1

                            ( wT, s3 ) =
                                freshTmp s2

                            ( t, s4 ) =
                                freshTmp s3
                        in
                        ( Il.Tmp t
                        , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset p.word))) s4
                            |> emit (Load (Just wT) W LoadW (Il.Tmp aT))
                            |> emit (Unary (Just t) L Extsw (Il.Tmp wT))
                        )
                    )

        Unsafe (RawTagIs ti) ->
            -- tag == n as 0/1 (w), extended to the l word class — box it with
            -- RawMkValue tag 3 to branch (`If` reads a boolean Value).
            rawValueBase ti.value s
                |> Result.map
                    (\( base, s1 ) ->
                        let
                            ( tagT, s2 ) =
                                freshTmp s1

                            ( isT, s3 ) =
                                freshTmp s2

                            ( t, s4 ) =
                                freshTmp s3
                        in
                        ( Il.Tmp t
                        , emit (Load (Just tagT) W LoadW base) s4
                            |> emit (Cmp (Just isT) W Ceq (Il.Tmp tagT) (Il.Con ti.tag))
                            |> emit (Unary (Just t) L Extsw (Il.Tmp isT))
                        )
                    )

        Unsafe (RawBin bin) ->
            -- RAdd..RDiv at `l` (i64 wrap/trunc); the Bitwise family at `w`
            -- with the JS contract: and/or/xor + shl/sar SIGN-extend back
            -- (extsw), shr ZERO-extends (extuw).  The shift count masking is
            -- the CALLER's (RtPrims) — the node is the bare op.
            rawWordArg bin.a s
                |> Result.andThen (\( aT, s1 ) -> rawWordArg bin.b s1 |> Result.map (\( bT, s2 ) -> ( aT, bT, s2 )))
                |> Result.map
                    (\( aT, bT, s3 ) ->
                        case bin.op of
                            RAdd ->
                                let
                                    ( t, s4 ) =
                                        freshTmp s3
                                in
                                ( Il.Tmp t, emit (Bin (Just t) L Add aT bT) s4 )

                            RSub ->
                                let
                                    ( t, s4 ) =
                                        freshTmp s3
                                in
                                ( Il.Tmp t, emit (Bin (Just t) L Sub aT bT) s4 )

                            RMul ->
                                let
                                    ( t, s4 ) =
                                        freshTmp s3
                                in
                                ( Il.Tmp t, emit (Bin (Just t) L Mul aT bT) s4 )

                            RDiv ->
                                let
                                    ( t, s4 ) =
                                        freshTmp s3
                                in
                                ( Il.Tmp t, emit (Bin (Just t) L Div aT bT) s4 )

                            _ ->
                                -- the i32 family: op at `w` into t, then the
                                -- extension INTO the l result temp (extuw for
                                -- the zero-fill shift, extsw elsewhere)
                                let
                                    ( t, s4 ) =
                                        freshTmp s3

                                    ( rT, s5 ) =
                                        freshTmp s4

                                    wop =
                                        case bin.op of
                                            RBitAnd ->
                                                And

                                            RBitOr ->
                                                Or

                                            RBitXor ->
                                                Xor

                                            RShl ->
                                                Shl

                                            RShAr ->
                                                Sar

                                            _ ->
                                                Shr
                                in
                                ( Il.Tmp rT
                                , emit (Bin (Just t) W wop aT bT) s5
                                    |> emit (Unary (Just rT) L (if bin.op == RShR then Extuw else Extsw) (Il.Tmp t))
                                )
                    )

        Unsafe (RawUn un) ->
            rawWordArg un.v s
                |> Result.map
                    (\( vT, s1 ) ->
                        case un.op of
                            RBitNot ->
                                -- ~i32: xor -1 at `w`, sign-extended back
                                let
                                    ( t, s2 ) =
                                        freshTmp s1

                                    ( rT, s3 ) =
                                        freshTmp s2
                                in
                                ( Il.Tmp rT
                                , emit (Bin (Just t) W Xor vT (Il.Con -1)) s3
                                    |> emit (Unary (Just rT) L Extsw (Il.Tmp t))
                                )

                            RSext ->
                                let
                                    ( rT, s2 ) =
                                        freshTmp s1
                                in
                                ( Il.Tmp rT, emit (Unary (Just rT) L Extsw vT) s2 )

                            RUext ->
                                let
                                    ( rT, s2 ) =
                                        freshTmp s1
                                in
                                ( Il.Tmp rT, emit (Unary (Just rT) L Extuw vT) s2 )

                            RFToI32 ->
                                -- f64 word -> i32: Dtosi at `w` (DOUBLE to
                                -- int — `stosi` is the SINGLE variant, the
                                -- stale spelling this comment carried), then
                                -- truncate toward zero, THEN extsw into the l
                                -- class (the ToInt32 result re-enters word
                                -- math sign-extended).
                                let
                                    ( t, s2 ) =
                                        freshTmp s1

                                    ( rT, s3 ) =
                                        freshTmp s2
                                in
                                ( Il.Tmp rT
                                , emit (Unary (Just t) W Dtosi vT) s3
                                    |> emit (Unary (Just rT) L Extsw (Il.Tmp t))
                                )
                    )

        Unsafe (RawCmp cmp) ->
            -- signed i64 compare -> 0/1: the Cmp lands at `w`, extsw widens
            -- (0/1 unchanged) into the l word class so RawMkValue can box it.
            rawWordArg cmp.a s
                |> Result.andThen (\( aT, s1 ) -> rawWordArg cmp.b s1 |> Result.map (\( bT, s2 ) -> ( aT, bT, s2 )))
                |> Result.map
                    (\( aT, bT, s3 ) ->
                        let
                            ( t, s4 ) =
                                freshTmp s3

                            ( rT, s5 ) =
                                freshTmp s4
                        in
                        ( Il.Tmp rT
                        , emit (Cmp (Just t) L (rawCmpOp cmp.op) aT bT) s5
                            |> emit (Unary (Just rT) L Extsw (Il.Tmp t))
                        )
                    )

        Unsafe (RawAllocRaw len) ->
            -- GC_STR safepoint (Mid.Ir's node contract): n raw bytes via the
            -- runtime's allocRaw seat.  The result is a raw temp, invalid
            -- across the NEXT safepoint — the same discipline RawAllocVector
            -- states.
            rawWordArg len s
                |> Result.map
                    (\( lenA, s1 ) ->
                        midGcAllocSeat "Rt.allocRaw" lenA s1
                    )

        Unsafe (RawByteLoad bl) ->
            -- loadub + extuw: a byte is 0..255 (zero-extend; there is no
            -- sign in a byte).
            rawWordArg bl.ptr s
                |> Result.andThen
                    (\( pT, s1 ) ->
                        rawWordArg bl.index s1
                            |> Result.map
                                (\( iT, s2 ) ->
                                    let
                                        ( aT, s3 ) =
                                            freshTmp s2

                                        ( t, s4 ) =
                                            freshTmp s3

                                        ( rT, s5 ) =
                                            freshTmp s4
                                    in
                                    ( Il.Tmp rT
                                    , emit (Bin (Just aT) L Add pT iT) s5
                                        |> emit (Load (Just t) W LoadUb (Il.Tmp aT))
                                        |> emit (Unary (Just rT) L Extuw (Il.Tmp t))
                                    )
                                )
                    )

        Unsafe (RawWordLoad wl) ->
            -- loadl at ptr + 8*index (the index is a WORD offset — Mid.Ir's
            -- node contract).  No extension: an `l` word IS the class.
            rawWordArg wl.ptr s
                |> Result.andThen
                    (\( pT, s1 ) ->
                        rawWordArg wl.index s1
                            |> Result.map
                                (\( iT, s2 ) ->
                                    let
                                        ( aT, s3 ) =
                                            wordAddr pT iT s2

                                        ( t, s4 ) =
                                            freshTmp s3
                                    in
                                    ( Il.Tmp t
                                    , emit (Load (Just t) L LoadL (Il.Tmp aT)) s4
                                    )
                                )
                    )

        Unsafe (RawMemLoad ml) ->
            -- (cffi U6) load{ub,sb,uh,sh,uw,w} at ptr + off, WIDENING to `l`
            -- in ONE instruction: the `l` result type IS the extension, which
            -- is why nothing follows it (MEASURED on the vendored qbe: `=l
            -- loadsh` of 0xFFFE gives -2, `=l loaduh` gives 65534, `=l
            -- loadsb` of 0xC8 gives -56, `=l loaduw` gives 4294967295).
            --
            -- Why not the `w` + `extuw` shape RawByteLoad uses: that shape is
            -- a two-instruction spelling of the same thing, and it is
            -- retained AS the existing shape it is (its sites are the string
            -- and byte-buffer reads, whose emitted bytes the corpus pins).
            rawWordArg ml.ptr s
                |> Result.map
                    (\( pT, s1 ) ->
                        let
                            ( aT, s2 ) =
                                memAddr pT ml.off s1

                            ( t, s3 ) =
                                freshTmp s2
                        in
                        ( Il.Tmp t
                        , emit (Load (Just t) L (memLoadOp ml.width ml.signed) (Il.Tmp aT)) s3
                        )
                    )

        Unsafe (RawCallRaw seat) ->
            -- alloc-FREE C seat, word args -> word result (Base L both
            -- sides).  rt_halt's `l` result is never defined (the seat exits)
            -- but nothing reads a halt's binder — dead-in-practice, valid IL.
            List.foldl
                (\e acc ->
                    Result.andThen
                        (\( args, st ) ->
                            rawWordArg e st
                                |> Result.map (\( a, st2 ) -> ( args ++ [ ArgVal (Base L) a ], st2 ))
                        )
                        acc
                )
                (Ok ( [], s ))
                seat.args
                |> Result.andThen
                    (\( args, s1 ) ->
                        let
                            ( t, s2 ) =
                                freshTmp s1

                            -- stage 6 U2: the surface's `rawcall rt_halt()`
                            -- (the prim halt arm) routes to the Mid rawAbi
                            -- defun Rt.halt (q_Rt_x2ehalt).  B4 deleted the
                            -- Zig rt_halt seat, so this is unconditional.
                            callee =
                                if seat.sym == "rt_halt" then
                                    "q_" ++ mangle "Rt.halt"

                                else
                                    seat.sym
                        in
                        -- stage 6 A1: the halt arm's 0 words are checked
                        -- against the rawAbi arity record (a param added to
                        -- Rt.halt in U3-U5 would under-apply here otherwise).
                        if seat.sym == "rt_halt" then
                            rawAbiArityAgree "Rt.halt" (List.length args)
                                |> Result.map (\_ -> ( Il.Tmp t, emit (Call (Just t) (Base L) (Il.Sym callee) args) s2 ))

                        else
                            Ok ( Il.Tmp t, emit (Call (Just t) (Base L) (Il.Sym callee) args) s2 )
                    )

        Unsafe (RawCallExtern seat) ->
            -- (cffi U2) THE TYPED C BOUNDARY — the width fix.  This is the
            -- ONE arm that emits a C call's register classes from the
            -- DECLARATION rather than from `RawCallRaw`'s "everything is a
            -- word" convention:
            --
            --   argument  FW32S / FW32U -> `w`   (a C `int` parameter is
            --                 what %edi holds; passing `l` happens to work,
            --                 which is why this half of the bug was
            --                 invisible — plan §3.2)
            --             FW64        -> `l`   (i64/u64/ptr)
            --   result    FW32S       -> `=w call` + `extsw`  (SIGN-extend:
            --                 the ABI leaves %rax's upper 32 bits
            --                 UNSPECIFIED, so an `l` read of a C `int`
            --                 return is the measured SILENT bug)
            --             FW32U       -> `=w call` + `extuw`
            --             FW64/FVoid  -> `=l call` (FVoid's temp is the
            --                 same dead word RawCallRaw yields today)
            --             FF64        -> `=d call` (an `xmm` result, the
            --                 float-word producer class — cffi U3)
            --
            -- MEASURED against the vendored QBE (plan §3.1): `=w call` +
            -- `extsw` emits `movslq %eax`; `=w call` + `extuw` emits
            -- `movl %eax, %r32d`; `=l call` emits a bare `movq %rax`; a
            -- `=d call` leaves the value in `%xmm0` (the strfromd/fmod
            -- probes).
            zipWidths seat.sym seat.argWidths seat.args
                |> Result.andThen
                    (\ws ->
                        List.foldl
                            (\ew acc ->
                                Result.andThen
                                    (\( args, st ) ->
                                        rawFfiArg ew st
                                            |> Result.map (\( a, st2 ) -> ( args ++ [ ArgVal (ffiArgClass ew.width) a ], st2 ))
                                    )
                                    acc
                            )
                            (Ok ( [], s ))
                            ws
                            |> Result.map
                                (\( args, st ) ->
                                    ( withEllipsis seat.varargs seat.fixedArgs args, st )
                                )
                            |> Result.andThen
                                (\( args, s1 ) ->
                                    let
                                        ( t, s2 ) =
                                            freshTmp s1

                                        -- the EXTENSION temp needs its own
                                        -- allocation: the counter must survive
                                        -- into s3, or the next freshTmp hands
                                        -- out the same name again (MEASURED:
                                        -- `%t1 =w csltl %t1, 0`, an
                                        -- unassemblable clash).
                                        ( e, s3 ) =
                                            freshTmp s2
                                    in
                                    case seat.result of
                                        FW32S ->
                                            Ok
                                                ( Il.Tmp e
                                                , emit (Call (Just t) (Base W) (Il.Sym seat.sym) args) s3
                                                    |> emit (Unary (Just e) L Extsw (Il.Tmp t))
                                                )

                                        FW32U ->
                                            Ok
                                                ( Il.Tmp e
                                                , emit (Call (Just t) (Base W) (Il.Sym seat.sym) args) s3
                                                    |> emit (Unary (Just e) L Extuw (Il.Tmp t))
                                                )

                                        FW64 ->
                                            Ok
                                                ( Il.Tmp t
                                                , emit (Call (Just t) (Base L) (Il.Sym seat.sym) args) s2
                                                )

                                        FVoid ->
                                            -- the declared result is DEAD — the
                                            -- same `l` temp `rawcall free(..)`
                                            -- emits today, so a `-> void`
                                            -- declaration moves no existing
                                            -- shape (R-09 states the read
                                            -- hazard).
                                            Ok
                                                ( Il.Tmp t
                                                , emit (Call (Just t) (Base L) (Il.Sym seat.sym) args) s2
                                                )

                                        FF64 ->
                                            -- (cffi U3) the `d` class: the
                                            -- value arrives in %xmm0, so the
                                            -- call's own result type is `d`
                                            -- and the temp is a FLOAT word —
                                            -- isFloatWordExp says so, and the
                                            -- checker only ever lets it into a
                                            -- float slot (R-16).  No extension:
                                            -- there is nothing to extend.
                                            Ok
                                                ( Il.Tmp t
                                                , emit (Call (Just t) (Base D) (Il.Sym seat.sym) args) s2
                                                )
                                )
                    )

        Unsafe (RawCall call) ->
            -- stage 6 U2: a rawAbi Rt->Rt call (Rt.die/Rt.halt) — WORD args,
            -- WORD result, named q_Rt_* callee.  The lean-:val RawCall lives
            -- in lowerRawVal; this arm is the raw-word twin, reached through
            -- isRawWordExp/rawWordOf when the let binder is a raw temp.
            if Dict.member call.sym s.abi then
                if Dict.member call.sym s.defuns then
                    List.foldl
                        (\e acc ->
                            Result.andThen
                                (\( args, st ) ->
                                    rawWordArg e st
                                        |> Result.map (\( a, st2 ) -> ( args ++ [ ArgVal (Base L) a ], st2 ))
                                )
                                acc
                        )
                        (Ok ( [], s ))
                        call.args
                        |> Result.map
                            (\( args, s1 ) ->
                                let
                                    ( t, s2 ) =
                                        freshTmp s1
                                in
                                ( Il.Tmp t, emit (Call (Just t) (Base L) (Il.Sym ("q_" ++ mangle call.sym)) args) s2 )
                            )

                else
                    Err ("qbe: rawCall to rawAbi defun " ++ call.sym ++ " — not in this compile (Mid.Rt.driverSeeds/gcSeeds must seed it)")

            else
                Err ("qbe: rawCall to " ++ call.sym ++ " in a word position — a non-rawAbi Rt call is a :val producer, never a word")

        Unsafe (RawCallAgg call) ->
            -- Call through a RUNTIME WORD with an AGGREGATE result (stage 6
            -- U1a; Mid.Ir's node contract).  The callee and every arg take
            -- the raw-word path; the result is the sret buffer ADDRESS as a
            -- word — the caller reads the fields with RawWordLoad at
            -- +0/+40/+48/... .  Shape "ret" emits `:ret` (80 B, the
            -- bounce-loop call-result shape), "val" emits `:val` (40 B, the
            -- tagged Value).  Legality MEASURED on the vendored qbe:
            -- `%r =:ret call %f(l %argv, w 2)` assembles exit 0 and the
            -- sret temp is addressable (movq %rax,%rcx; movq 40(%rcx),%rcx).
            -- NOT a safepoint-free seat — the callee is unknown generated
            -- code (Mid.Rt classifies the node conservatively allocating).
            -- A1: the callee may ALSO be a NAMED exported symbol (Il.Sym) —
            -- the generated-code call shape (rt_apply/rt_bounce by name),
            -- not just a loaded code pointer in a temp.
            if call.shape /= "ret" && call.shape /= "val" then
                Err ("qbe: rawCallAgg shape \"" ++ call.shape ++ "\" — only \"ret\" and \"val\" are legal")

            else
                lowerRawCallAgg call s
                    |> Result.map
                        (\( fnA, args, s1 ) ->
                            let
                                ( t, s2 ) =
                                    freshTmp s1
                            in
                            ( Il.Tmp t
                            , emit (Call (Just t) (Agg call.shape) fnA args) s2
                            )
                        )

        Unsafe (RawDataAddr names) ->
            -- (E) the STATIC names array of a positional record: first ensure
            -- each name's `sym:` data def exists (freshData is idempotent —
            -- the SAME defs LSymbol lowering creates), COLLECTING each def's
            -- ACTUAL symbol (freshData names it "dN"; a DRef must point at
            -- that generated name, NOT the "sym:" content key — a DRef to an
            -- undefined symbol fails qbe assembly), then freshData a
            -- content-keyed array of those DRefs and return Il.Sym of it
            -- (Il.Sym IS an Arg — lowerLit LSymbol stores the same class).
            let
                ensure : String -> ( List String, S ) -> ( List String, S )
                ensure name ( acc, st ) =
                    let
                        ( symName, st1 ) =
                            freshData ("sym:" ++ name)
                                (\n -> { name = n, align = Just 8, items = [ DStr name, DByte 0 ], export_ = False })
                                st
                    in
                    ( symName :: acc, st1 )

                ( symNamesRev, s1 ) =
                    List.foldl ensure ( [], s ) names

                ( arrName, s2 ) =
                    freshData ("recnames:" ++ String.join "," names)
                        (\n ->
                            { name = n
                            , align = Just 8
                            , -- the names array is an array of SYMBOL Value
                              -- structs (40 B each: tag 2, pad, name pointer,
                              -- union padding) — the SAME layout a runtime
                              -- dynamic names array (RawAllocVector of symbol
                              -- Values) has, so Rt.recGet walks both with
                              -- RawVecLoad.  Must match gc/types.zig's Value
                              -- extern struct (tag u32@0, union@8).
                              items =
                                List.concatMap
                                    (\sn ->
                                        [ DWord RtLayout.tagSymbol
                                        , DZero (RtLayout.abiAlign - RtLayout.valueTagBytes)
                                        , DRef sn
                                        , DZero (RtLayout.valSizeBytes - RtLayout.payloadBase - RtLayout.wordBytes)
                                        ]
                                    )
                                    (List.reverse symNamesRev)
                            , export_ = False
                            }
                        )
                        s1
            in
            Ok ( Il.Sym arrName, s2 )

        Unsafe (RawCStr content) ->
            -- (stage 6 U2) the ADDRESS of a static NUL-terminated string:
            -- freshData the `sym:`-keyed def (the SAME dedup LSymbol and
            -- RawDataAddr's ensure use — a rawstr literal and a symbol/record
            -- field of the same content share ONE data def) and return its
            -- symbol as the word (Il.Sym IS an Arg).
            let
                ( symName, s1 ) =
                    freshData ("sym:" ++ content)
                        (\n -> { name = n, align = Just 8, items = [ DStr content, DByte 0 ], export_ = False })
                        s
            in
            Ok ( Il.Sym symName, s1 )

        Unsafe (RawSym name) ->
            -- (stage 6 A1b) the ADDRESS of a FUNCTION symbol: Il.Sym of the
            -- name VERBATIM (rt_bounce/rt_callN/a q_Rt_* defun) — a CODE
            -- label, not a data def.  This is the ONLY rawWordArg producer of
            -- a function Il.Sym; RawCStr/RawDataAddr above go through
            -- freshData and yield dN DATA defs.  `lowerRawCallAgg` accepts
            -- ONLY this (and a loaded code pointer) as a call target.
            Ok ( Il.Sym name, s )

        Unsafe (RawAllocN words) ->
            -- (B4) `n` WORDS of STACK storage: QBE `%t =l allocN 8n`
            -- (Il.Alloc — the same node the prologue uses for the pooled and
            -- lean frames and B6 uses for a struct parameter's entry copy).
            -- A constant size, so vendor/qbe's amd64 isel turns it into a
            -- fixed frame slot: the block costs frame space, never a runtime
            -- call, and the frame's exit reclaims it — which is exactly what
            -- makes a cell or a declared local free-less.
            let
                ( t, s1 ) =
                    freshTmp s
            in
            Ok ( Il.Tmp t, emit (Alloc t (8 * words)) s1 )

        Unsafe (RawFltBin bin) ->
            -- f64 word binop -> `d` temp.  Operands are FLOAT-word
            -- expressions (rawFltArg); landing one in an integer-word
            -- position is a QBE type error at parse time — loud, by design.
            rawFltArg bin.a s
                |> Result.andThen (\( aT, s1 ) -> rawFltArg bin.b s1 |> Result.map (\( bT, s2 ) -> ( aT, bT, s2 )))
                |> Result.map
                    (\( aT, bT, s3 ) ->
                        let
                            ( t, s4 ) =
                                freshTmp s3
                        in
                        ( Il.Tmp t
                        , emit (Bin (Just t) D (rawFltBinOp bin.op) aT bT) s4
                        )
                    )

        Unsafe (RawFltCmp cmp) ->
            -- f64 compare -> 0/1 in an l word temp (the `*d` Cmp family,
            -- extsw-widened like RawCmp).
            rawFltArg cmp.a s
                |> Result.andThen (\( aT, s1 ) -> rawFltArg cmp.b s1 |> Result.map (\( bT, s2 ) -> ( aT, bT, s2 )))
                |> Result.map
                    (\( aT, bT, s3 ) ->
                        let
                            ( t, s4 ) =
                                freshTmp s3

                            ( rT, s5 ) =
                                freshTmp s4
                        in
                        ( Il.Tmp rT
                        , emit (Cmp (Just t) D (rawFltCmpOp cmp.op) aT bT) s5
                            |> emit (Unary (Just rT) L Extsw (Il.Tmp t))
                        )
                    )

        Unsafe (RawIToF v) ->
            -- i64 word -> f64 (asFloat's number arm): sltof.
            rawWordArg v s
                |> Result.map
                    (\( vT, s1 ) ->
                        let
                            ( t, s2 ) =
                                freshTmp s1
                        in
                        ( Il.Tmp t, emit (Unary (Just t) D Sltof vT) s2 )
                    )

        Unsafe (RawLoadFlt v) ->
            -- payload word 0 of a VALUE as f64: loadd at slot+8.  A safe bit
            -- read of ANY Value (no trap on a mistagged arg).
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal v vslot s1
                |> Result.map
                    (\s2 ->
                        let
                            ( aT, s3 ) =
                                freshTmp s2

                            ( t, s4 ) =
                                freshTmp s3
                        in
                        ( Il.Tmp t
                        , emit (Bin (Just aT) L Add (Il.Tmp (slotTmp vslot)) (Il.Con 8)) s4
                            |> emit (Load (Just t) D LoadD (Il.Tmp aT))
                        )
                    )

        Unsafe (RawStrByte sb) ->
            -- byte i of a string Value (str.data[i]) as a WORD: the data
            -- pointer is payload word 0 (a full 64-bit pointer — RawPayload),
            -- the read is loadub at ptr + index, widened ZERO (bytes are
            -- 0..255; extuw — char-code's -1 out-of-range answer is built by
            -- the CALLER's bounds test, not by sign bits).
            rawWordArg sb.index s
                |> Result.andThen
                    (\( idxT, s1 ) ->
                        let
                            ( vslot, s2 ) =
                                freshSlot s1
                        in
                        lowerVal sb.str vslot s2
                            |> Result.map
                                (\s3 ->
                                    let
                                        ( pT, s4 ) =
                                            freshTmp s3

                                        ( aT, s5 ) =
                                            freshTmp s4

                                        ( bT, s6 ) =
                                            freshTmp s5

                                        ( wT, s7 ) =
                                            freshTmp s6

                                        ( rT, s8 ) =
                                            freshTmp s7
                                    in
                                    ( Il.Tmp rT
                                    , s8
                                        |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp vslot)) (Il.Con 8))
                                        |> emit (Load (Just aT) L LoadL (Il.Tmp pT))
                                        |> emit (Bin (Just bT) L Add (Il.Tmp aT) idxT)
                                        |> emit (Load (Just wT) W LoadUb (Il.Tmp bT))
                                        |> emit (Unary (Just rT) L Extuw (Il.Tmp wT))
                                    )
                                )
                    )

        Unsafe other ->
            Err ("qbe: raw argument position holds a value-producing raw node (" ++ rawNodeName other ++ ") — only word producers are legal there")

        _ ->
            Err "qbe: raw argument position holds a value expression — only word constants, raw-word binders and word-producing raw nodes are legal"


{-| Evaluate ONE float-word expression (the `d` register class): a
float-producing raw node, nested.  A Var never appears — float words are not
let-bindable (recompute; they are pure) — and a Value or integer word is a
loud register-class error.
-}
rawFltArg : Exp -> S -> Result String ( Il.Arg, S )
rawFltArg exp s =
    case exp of
        Unsafe node ->
            case node of
                RawFltBin _ ->
                    rawWordArg exp s

                RawFltCmp _ ->
                    rawWordArg exp s

                RawIToF _ ->
                    rawWordArg exp s

                RawLoadFlt _ ->
                    rawWordArg exp s

                -- cffi U2/U3 — THE SIXTH CLASSIFICATION SITE, and the one that
                -- is NOT compiler-forced (this case has a wildcard): a typed C
                -- call in a float-word position is a float producer when the
                -- declaration says its result is `f64` (cffi U3 — the strfromd
                -- result feeding `mkflt`, a float compare or another `d`
                -- argument).  Any other result class is a WORD, which in a
                -- float slot is the same loud class error a word gets.
                RawCallExtern call ->
                    case call.result of
                        FF64 ->
                            rawWordArg exp s

                        _ ->
                            Err
                                ("qbe: float-word position holds a C call '"
                                    ++ call.sym
                                    ++ "' whose declared result is a WORD class — only a declared `f64` (`d`) result is a float word"
                                )

                _ ->
                    Err ("qbe: float-word position holds a non-float raw node (" ++ rawNodeName node ++ ")")

        _ ->
            Err "qbe: float-word position holds a non-raw expression — only the float-producing raw nodes are legal"


rawCmpOp : RawCmpOp -> CmpOp
rawCmpOp op =
    case op of
        RCeq ->
            Ceq

        RCne ->
            Cne

        RClts ->
            Cslt

        RCles ->
            Csle

        RCgts ->
            Csgt

        RCges ->
            Csge


rawFltBinOp : RawFltBinOp -> BinOp
rawFltBinOp op =
    case op of
        RFAdd ->
            Add

        RFSub ->
            Sub

        RFMul ->
            Mul

        RFDiv ->
            Div


rawFltCmpOp : RawFltCmpOp -> CmpOp
rawFltCmpOp op =
    case op of
        RFLt ->
            Cltd

        RFLe ->
            Cled

        RFGt ->
            Cgtd

        RFGe ->
            Cged

        RFEq ->
            Ceqd

        RFNe ->
            Cned


{-| A RawMkValue word is FLOAT-typed when it is one of the float-producing
nodes — storeValueCell writes those with `stored` (8 bytes at the word
offset), everything else with `storel`.
-}
isFloatWordExp : Exp -> Bool
isFloatWordExp exp =
    case exp of
        Unsafe node ->
            case node of
                RawFltBin _ ->
                    True

                RawIToF _ ->
                    True

                RawLoadFlt _ ->
                    True

                -- (cffi U3) a declared `f64` result IS a float word: the call
                -- emits `=d call` and its temp lives in an `xmm` register, so
                -- the mk* / payload-word paths that store float words with
                -- `stored` (8 bytes) must classify it here.
                RawCallExtern call ->
                    case call.result of
                        FF64 ->
                            True

                        _ ->
                            False

                _ ->
                    False

        _ ->
            False


rawNodeName : UnsafeNode -> String
rawNodeName node =
    case node of
        RawCall _ ->
            "rawCall"

        RawTagOf _ ->
            "rawTagOf"

        RawPayload _ ->
            "rawPayload"

        RawMkValue _ ->
            "rawMkValue"

        RawAllocVector _ ->
            "rawAllocVector"

        RawVecLoad _ ->
            "rawVecLoad"

        RawVecAddr _ ->
            "rawVecAddr"

        RawVecStore _ ->
            "rawVecStore"

        RawStrByte _ ->
            "rawStrByte"

        WithRoots _ ->
            "withRoots"

        RawPayload32 _ ->
            "rawPayload32"

        RawTagIs _ ->
            "rawTagIs"

        RawBin _ ->
            "rawBin"

        RawUn _ ->
            "rawUn"

        RawCmp _ ->
            "rawCmp"

        RawFltBin _ ->
            "rawFltBin"

        RawFltCmp _ ->
            "rawFltCmp"

        RawIToF _ ->
            "rawIToF"

        RawLoadFlt _ ->
            "rawLoadFlt"

        RawAllocRaw _ ->
            "rawAllocRaw"

        RawByteLoad _ ->
            "rawByteLoad"

        RawByteStore _ ->
            "rawByteStore"

        RawWordLoad _ ->
            "rawWordLoad"

        RawWordStore _ ->
            "rawWordStore"

        -- cffi U6 — the width and the sign in the NAME, so an error message
        -- about a misplaced narrow access says which access it was.
        RawMemLoad m ->
            "rawMemLoad " ++ memWidthName m.width ++ (if m.signed then "/signed" else "/unsigned")

        RawMemStore m ->
            "rawMemStore " ++ memWidthName m.width

        RawCallRaw seat ->
            "rawCallRaw " ++ seat.sym

        RawCallExtern seat ->
            "rawCallExtern " ++ seat.sym

        RawCallAgg call ->
            "rawCallAgg " ++ call.shape

        RawDataAddr _ ->
            "rawDataAddr"

        RawCStr _ ->
            "rawCStr"

        RawSym _ ->
            "rawSym"

        RawAllocN _ ->
            "rawAllocN"


-- &vec[index] — a fresh `l` temp holding vec + vs*index (the index may be a
-- constant or a computed word; either way it enters as an `l` operand).
elemAddr : Il.Arg -> Il.Arg -> S -> ( String, S )
elemAddr vecT idxT s =
    let
        ( offT, s1 ) =
            freshTmp s

        ( t, s2 ) =
            freshTmp s1
    in
    ( t
    , s2
        |> emit (Bin (Just offT) L Mul (Il.Con vs) idxT)
        |> emit (Bin (Just t) L Add vecT (Il.Tmp offT))
    )


-- &ptr[index] at WORD stride — elemAddr one size down, for the raw word
-- buffer (RawWordLoad/RawWordStore): ptr + 8*index, the index a word offset.
wordAddr : Il.Arg -> Il.Arg -> S -> ( String, S )
wordAddr ptrT idxT s =
    let
        ( offT, s1 ) =
            freshTmp s

        ( t, s2 ) =
            freshTmp s1
    in
    ( t
    , s2
        |> emit (Bin (Just offT) L Mul (Il.Con 8) idxT)
        |> emit (Bin (Just t) L Add ptrT (Il.Tmp offT))
    )


-- (cffi U6) &ptr[off BYTES] — the width-typed family's address: the offset
-- is a COMPILE-TIME constant, so it is one `add` (and NO `add` at all at
-- offset 0: the base temp IS the address).  Deliberately not `wordAddr` with a
-- divided index — a byte offset is not a word offset, and the whole point of
-- the byte layout table is that a field may sit at byte 4 or 6.
memAddr : Il.Arg -> Int -> S -> ( String, S )
memAddr ptrT off s =
    if off == 0 then
        case ptrT of
            Il.Tmp t ->
                ( t, s )

            _ ->
                let
                    ( t, s1 ) =
                        freshTmp s
                in
                ( t, emit (Bin (Just t) L Add ptrT (Il.Con 0)) s1 )

    else
        let
            ( t, s1 ) =
                freshTmp s
        in
        ( t, emit (Bin (Just t) L Add ptrT (Il.Con off)) s1 )


-- (cffi U6) the load MNEMONIC for a memory width and a sign rule — the table
-- `doc/il.txt:715-745` states and the vendored qbe was MEASURED against.  The
-- sign is an ARGUMENT, not an inference: `loaduw` and `loadw` are one word
-- apart in meaning and identical in register class.
memLoadOp : MemWidth -> Bool -> LoadOp
memLoadOp width signed =
    case ( width, signed ) of
        ( MemB, True ) ->
            LoadSb

        ( MemB, False ) ->
            LoadUb

        ( MemH, True ) ->
            LoadSh

        ( MemH, False ) ->
            LoadUh

        ( MemW, True ) ->
            LoadW

        ( MemW, False ) ->
            LoadUw


-- (cffi U6) the store MNEMONIC for a memory width — `storeb`/`storeh`/`storew`
-- (both signs write the same bytes; only a LOAD's extension is signed).
memStoreTy : MemWidth -> StoreTy
memStoreTy width =
    case width of
        MemB ->
            StoreB

        MemH ->
            StoreH

        MemW ->
            StoreW


-- (cffi U6) a memory width as this module's messages spell it.
memWidthName : MemWidth -> String
memWidthName width =
    case width of
        MemB ->
            "1B"

        MemH ->
            "2B"

        MemW ->
            "4B"


-- ============================ LITERALS ============================
-- Number/boolean/symbol materialize as INLINE stores (immediates; a symbol's
-- name pointer is the static data symbol — stable forever, the VM's own
-- "literal, never GC-allocated" contract).  Floats load from static data.
-- Strings need a GC copy (rt_string) because string bytes live in the heap.
-- Non-ASCII string/symbol literals are rejected loudly (Elm 0.19 has no byte
-- API, so a byte length cannot be computed honestly).


lowerLit : Lit -> Int -> S -> Result String S
lowerLit lit dest s =
    let
        d =
            slotTmp dest

        storeTag t =
            emit (Store StoreW (Il.Con t) (Il.Tmp d)) s

        afterTag s1 =
            let
                ( d8, s2 ) =
                    freshTmp s1
            in
            ( d8, emit (Bin (Just d8) L Add (Il.Tmp d) (Il.Con 8)) s2 )
    in
    case lit of
        LNumber n ->
            let
                ( d8, s1 ) =
                    afterTag (storeTag tagNumber)
            in
            Ok (emit (Store StoreL (Il.Con n) (Il.Tmp d8)) s1)

        LBoolean b ->
            let
                ( d8, s1 ) =
                    afterTag (storeTag tagBoolean)
            in
            Ok (emit (Store StoreW (Il.Con (if b then 1 else 0)) (Il.Tmp d8)) s1)

        LFloat f ->
            let
                ( fname, s1 ) =
                    floatData f s

                ( x, s2 ) =
                    freshTmp s1
            in
            Ok
                -- Load the double into a FRESH temp and let `reboxFloat` write
                -- the tagged cell — the same shape as LNumber above, and the
                -- only float-store path in the backend.  Targeting the payload
                -- address with the load itself (the old shape) clobbered that
                -- address with the loaded double and never wrote the payload at
                -- all, leaving a tag-only cell that printed as 0.0.
                (emit (Load (Just x) D LoadD (Il.Sym fname)) s2
                    |> (\s3 -> reboxFloat dest (Il.Tmp x) s3)
                )

        LSymbol name ->
            let
                ( d8, s1 ) =
                    afterTag (storeTag tagSymbol)

                ( sname, s2 ) =
                    freshData ("sym:" ++ name)
                        (\n -> { name = n, align = Just 8, items = [ DStr name, DByte 0 ], export_ = False })
                        s1
            in
            Ok (emit (Store StoreL (Il.Sym sname) (Il.Tmp d8)) s2)

        LString str ->
            let
                ( strname, s1 ) =
                    freshData ("str:" ++ str)
                        (\n -> { name = n, align = Just 8, items = [ DStr str, DByte 0 ], export_ = False })
                        s
            in
            -- The string data IS the static data symbol (immutable,
            -- null-terminated, the `str:` freshData key) — no Zig-nursery
            -- copy, so no cross-heap edge and nothing a Zig scavenge can
            -- reclaim.  rt_string is not called at all (its Zig-nursery
            -- allocation was the corrected-criterion hole), so both the
            -- QBE_NOSTRINGINTERN flag AND the intern_live >= 2048 runtime
            -- fallback are unreachable.
            Ok (storeValueCell tagString [ Il.Sym strname, Il.Con (utf8ByteLength str) ] dest s1)


-- ==================== S4: UNBOXED Int LOCALS (representation v1) ====================
--
-- WHAT THIS IS: monomorphisation step S4/M1 — the representation half, at a
-- scope that needs NO ABI change.  Inside a defun the CHECKER typed as a
-- CLOSED MONOTYPE, an Int local is held in a RAW QBE `l` operand instead of a
-- 40-byte frame slot, and `+ - *` / `< <= > >=` / `=` on operands already
-- KNOWN to be Ints emit the native i64 op with NO tag test and NO `rt_prim`
-- fallback.
--
-- WHERE THE TYPE COMES FROM — and the gap this step had to work around.
-- The plan's seat is `Dict binderId monotype`, the per-binder half of the S1
-- table.  THAT HALF DOES NOT EXIST and cannot exist at S1: `Type.Infer`
-- exposes only `inferUnit`/`CheckedUnit` (Type/Infer.elm:1) and
-- `CheckedUnit.file` is the UNTYPED elm-syntax `File.File` (Infer.elm:61-67),
-- so per-binder types live only in an `InferState` nothing exposes —
-- producing them is the plan's S2 accumulator plus the S3 seed re-freeze,
-- neither of which has landed.  So this step reads the half the table DOES
-- have (the defun's closed monotype, `QbeTypes.Monotype`) and derives binder
-- types from the Mid tree itself:
--
--   * PARAMETERS, from the checker: the monotype is peeled in parameter order
--     (`Rep.TFun arg res`; Mid's `Lambda.params` is in the callee's order,
--     param 1 outermost), so `Map : (a -> b) -> List a -> List b` yields
--     nothing while `Fib.fib : Int -> Int` yields exactly param 0.  This is
--     the brief's gate: a POLYMORPHIC defun (or one with no scheme) gets
--     NOTHING, which is why the reach is the ~30% of tabled defuns S1
--     measured as monotypes.
--   * LET binders, from the IR: deny-by-default, see `isIntKnown`.
--
-- WHY THE LOCAL HALF IS SOUND AND NOT A CHEAPER ANALOGUE: it is not a guess
-- about the checker's answer, it is a fact about the VM's values.  `LNumber n`
-- lowers to `tagNumber` + an i64 payload (lowerLit), the VM has ONE integer
-- tag and a separate float tag (gc/types.zig), and primAdd/Sub/Mul promote
-- only when a FLOAT is present.  So "this operand is an Int" is decidable from
-- the IR alone, and stays true regardless of what the surrounding scheme says
-- — a `let x = i + 1` inside a POLYMORPHIC `fold` is an Int too.  The two
-- halves are complementary: the checker half covers binders whose type comes
-- from a signature, the IR half covers binders whose defining expression is in
-- view.
--
-- WHAT IS DELIBERATELY NOT DONE (deny by default — the failure mode here is
-- WRONG BYTES, not a crash):
--   * FLOAT. `LFloat` locals are NOT unboxed: every float arithmetic route
--     goes through `rt_prim` (Mid/Qbe/Il.elm has NO `addd`/`subd`/`muld` and
--     no float compare), so a raw `d` temp would be reboxed into a staging
--     slot at every single use — churn, no win.  The Float half of this
--     step's brief needs IL ops in `Mid/Qbe/Il.elm` + `Mid/Qbe/Print.elm`,
--     which are OUTSIDE this step's write scope.  Reported as a gap, not
--     silently skipped.
--   * PARAMETERS as raw temps (no ABI change is the whole point of v1).
--   * CASE/destructuring-scrutinee binders and CASE alt binds: both are read
--     back through `slotTmp` by the path machinery (VPath/VField), i.e. as
--     40-byte Values; unboxing them would need every path step taught the
--     representation.  Denied.
--   * INNER LAMBDA parameters: no scheme of their own, so no source.  Denied.
--   * Anything whose Int-ness is not PROVEN by `isIntKnown`.  A binder that
--     escapes into a closure IS reboxed — `captureBlits` handles the raw case
--     explicitly — so escapes are covered, not denied.
--
-- GC SAFETY IS STRUCTURAL: a raw `l` operand is not a pointer and is never
-- placed in a `ROOT_VALUE_ARRAY` (it does not live in a frame slot at all);
-- the collector's `scanValue` is tag-directed with a total `else => {}` arm,
-- so nothing new gets scanned.  No new rooting protocol is added, deliberately.
--
-- REBOXING IS THE BOUNDARY RULE, and it is applied at ONE place: every use of
-- a binder as a VALUE goes through `lowerVal`, whose `Var` arm reboxes.  Call
-- arguments (`stageArgs`), aggregate stores, `:val` returns, tail-call
-- argument moves, case scrutinees and closure captures all route through
-- `lowerVal` or through the explicit rebox in `captureBlits`, so an escaping
-- value is reconstructed as a tagged `Value` exactly as before.


{-| The binder ids of `params` the checker says are `Int`, given the defun's
type.  `Nothing` (no scheme), `Polymorphic` (open — the plan's "wait for the
specialiser" case), a non-arrow type, and any parameter whose domain is not
literally `Int []` all yield NOTHING for that position: the peel STOPS rather
than guessing, so a partially-typed defun contributes only its leading Ints.
-}
intParamsOf : Maybe QbeTypes.Entry -> List Binder -> Set Int
intParamsOf maybeEntry params =
    case Maybe.map .defunType maybeEntry of
        Just (QbeTypes.Monotype t) ->
            peelIntParams t params

        _ ->
            Set.empty


peelIntParams : Rep.Type -> List Binder -> Set Int
peelIntParams t params =
    case params of
        [] ->
            Set.empty

        p :: rest ->
            case t of
                Rep.TFun arg res ->
                    Set.union
                        (if isIntType arg then
                            Set.singleton p.id

                         else
                            Set.empty
                        )
                        (peelIntParams res rest)

                _ ->
                    Set.empty


isIntType : Rep.Type -> Bool
isIntType t =
    case t of
        Rep.TCon "Int" [] ->
            True

        _ ->
            False


{-| UNIT B: the checker's zonked type for a binder id, read ONLY through the
per-defun binder map (`table[binderKey].binders`) — the same seat
`closedRecordNames` reads, but keyed by `binderKey` (the enclosing defun's key
for a closure, whose params' types live in ITS map).  `Nothing` is the
deny-by-default answer: a synthetic binder, a conflicted range, or a unit whose
inference never ran.  NEVER a guessed type.
-}
typeOfBinder : S -> Int -> Maybe Rep.Type
typeOfBinder s id =
    Dict.get s.binderKey s.table
        |> Maybe.andThen
            (\entry ->
                case entry.binders of
                    QbeTypes.Binders binderMap ->
                        Dict.get id binderMap

                    QbeTypes.BindersAbsent ->
                        Nothing
            )


{-| The MTagEq-inline license: a type whose VALUES are compiler-emitted `Con`
vectors (element 0 a content-keyed `sym:` pointer), so payload-pointer equality
== name equality.  Builtin value types (`Int`/`Float`/`Bool`/`Char`/`String`/
`List`/`Never`/`()`) are NOT `Con` vectors; user ADTs (and Prelude's
`Maybe`/`Result`/`Order`, qualified `"Mod.Name"`) are.  Anything else (TVar,
tuple, record, function) denies.
-}
isUserAdt : Rep.Type -> Bool
isUserAdt t =
    case t of
        Rep.TCon name _ ->
            not (List.member name [ "Int", "Float", "Bool", "Char", "String", "List", "Never", "()" ])

        _ ->
            False


{-| THE PREDICATE, with the pass switch folded in so every consumer reads
exactly one decision: an expression is Int-known iff the pass is ON and
`isIntKnown` proves it.  There is no second place to forget `s.rep`.
-}
isIntExp : S -> Exp -> Bool
isIntExp s exp =
    s.rep && isIntKnown s exp


{-| Deny-by-default proof that `exp`'s VALUE is an Int.  Deliberately small:
each admitted shape is one whose Int-ness is a fact about the VM's values (see
the section header).  `App`, `GRef`, `Con`, `If`, `Let`, `Case`, record/list
operations and every prim outside `+ - *` return False, so all of them keep
their frame slots and their `rt_prim` routes.
-}
isIntKnown : S -> Exp -> Bool
isIntKnown s exp =
    case exp of
        Lit (LNumber _) ->
            True

        Var id ->
            Set.member id s.intBinders
                || (s.typeSpec && typeOfBinder s id == Just (Rep.TCon "Int" []))

        RecordGet rec field ->
            -- UNIT B item 3: a closed-tail record Var whose FIELD is Int —
            -- the checker's type, not the field value's spelling.  `s.rec`
            -- because the raw positional read only exists under E's layout.
            s.rec && s.typeSpec && closedRecordFieldType s rec field == Just (Rep.TCon "Int" [])

        NoTail inner ->
            isIntKnown s inner

        PrimApp app ->
            List.member app.prim [ "+", "-", "*" ]
                && List.length app.args == 2
                && List.all (isIntKnown s) app.args

        _ ->
            False


{-| THE PREDICATE for the Char/String-ordering branch of `lowerCompare`: an
expression is PROVEN a string Value (a Char is a 1-byte String — see the
branch's doc) iff it is a string literal, or a binder whose checker type is
`Char`/`String` (read through the SAME per-defun binder map `isIntKnown` reads,
gated on `s.typeSpec` so the QBE_NOTYPESPEC=1 hatch reproduces the pre-change
emission).  Deny-by-default, exactly like `isIntKnown`.
-}
isStrExp : S -> Exp -> Bool
isStrExp s exp =
    isStrKnown s exp


isStrKnown : S -> Exp -> Bool
isStrKnown s exp =
    case exp of
        Lit (LString _) ->
            True

        Var id ->
            s.typeSpec && isStrType (typeOfBinder s id)

        RecordGet rec field ->
            -- a Char/String FIELD compared by ordering (the record-read result
            -- is a boxed string Value, so no `s.rec` positional gate — only the
            -- checker's field TYPE is needed, read like isIntKnown's arm).
            s.typeSpec && isStrType (closedRecordFieldType s rec field)

        NoTail inner ->
            isStrKnown s inner

        _ ->
            False


isStrType : Maybe Rep.Type -> Bool
isStrType t =
    case t of
        Just (Rep.TCon name []) ->
            name == "Char" || name == "String"

        _ ->
            False


{-| The RAW `l`-typed operand holding `exp`'s Int value.  DOMAIN: exactly
`isIntKnown`'s — every admitted shape here is an admitted shape there, and the
final arms are loud errors rather than a fallback, so a future shape added to
one and not the other cannot silently pick up a wrong representation.

`Var` covers both halves of the binder world: a raw binder contributes its own
operand with no instruction at all, and a BOXED Int binder (a parameter of a
monotype defun, which v1 does not unbox) contributes `loadl (slot + 8)` — the
tag is provably `tagNumber`, so its payload word IS the Int.
-}
rawIntOf : Exp -> S -> Result String ( Il.Arg, S )
rawIntOf exp s =
    case exp of
        Lit (LNumber n) ->
            Ok ( Il.Con n, s )

        NoTail inner ->
            rawIntOf inner s

        Var id ->
            case Dict.get id s.rawInt of
                Just raw ->
                    Ok ( raw, s )

                Nothing ->
                    case valueBaseOf id s of
                        Just base ->
                            let
                                ( p, s1 ) =
                                    freshTmp s

                                ( t, s2 ) =
                                    freshTmp s1
                            in
                            Ok
                                ( Il.Tmp t
                                , emit (Bin (Just p) L Add base (Il.Con 8)) s2
                                    |> emit (Load (Just t) L LoadL (Il.Tmp p))
                                )

                        Nothing ->
                            Err ("qbe: raw Int operand not in scope: binder " ++ String.fromInt id ++ " (corrupt Mid tree)")

        RecordGet rec field ->
            case closedRecordField s rec field of
                Just ( rank, Rep.TCon "Int" [] ) ->
                    -- UNIT B item 3: the field is Int by the checker's type, so
                    -- its boxed payload IS the i64 — but ONLY for a positional
                    -- tag-14 vector.  A closed-TRecord binder is NOT always a
                    -- vector (blocker-1): host-built records (Io.stat/TaskStat)
                    -- are assoc CHAINS (tag 4), and Record.remove returns a chain
                    -- through the trusted-lie scheme.  So tag-test the base slot:
                    -- tag 14 -> the raw data[rank]+8 read; anything else -> the
                    -- existing boxed route (assoc+snd / recGet walk), whose
                    -- tagNumber payload is the Int.  One predicted branch; the
                    -- compiler-built case stays on the raw arm.
                    case rec of
                        Var id ->
                            case valueBaseOf id s of
                                Just rbase ->
                                    let
                                        ( jt, s0 ) =
                                            freshTmp s

                                        ( tagT, s1 ) =
                                            freshTmp s0

                                        ( is14T, s2 ) =
                                            freshTmp s1

                                        ( rawLbl, s3 ) =
                                            freshLbl "rfieldraw" s2

                                        ( fallLbl, s4 ) =
                                            freshLbl "rfieldwalk" s3

                                        ( joinLbl, s5 ) =
                                            freshLbl "rfieldjoin" s4

                                        sTest =
                                            emit (Load (Just tagT) W LoadW rbase) s5
                                                |> emit (Cmp (Just is14T) W Ceq (Il.Tmp tagT) (Il.Con tagRecord))
                                                |> closeBlock (Jnz (Il.Tmp is14T) rawLbl fallLbl)

                                        ( d8, s6 ) =
                                            freshTmp sTest

                                        ( d, s7 ) =
                                            freshTmp s6

                                        ( p, s8 ) =
                                            freshTmp s7

                                        sRaw =
                                            emit (Bin (Just d8) L Add rbase (Il.Con 8)) (startBlock rawLbl s8)
                                                |> emit (Load (Just d) L LoadL (Il.Tmp d8))
                                                |> emit (Bin (Just p) L Add (Il.Tmp d) (Il.Con (vs * rank + 8)))
                                                |> emit (Load (Just jt) L LoadL (Il.Tmp p))
                                                |> jumpTo joinLbl

                                        ( fbSlot, s9 ) =
                                            freshSlot sRaw

                                        ( fp, s9b ) =
                                            freshTmp s9
                                    in
                                    lowerVal (RecordGet rec field) fbSlot (startBlock fallLbl s9b)
                                        |> Result.map
                                            (\s10 ->
                                                ( Il.Tmp jt
                                                , emit (Bin (Just fp) L Add (Il.Tmp (slotTmp fbSlot)) (Il.Con 8)) s10
                                                    |> emit (Load (Just jt) L LoadL (Il.Tmp fp))
                                                    |> jumpTo joinLbl
                                                    |> startBlock joinLbl
                                                )
                                            )

                                Nothing ->
                                    Err ("qbe: raw Int record base not in scope: binder " ++ String.fromInt id ++ " (corrupt Mid tree)")

                        _ ->
                            Err "qbe: deny-by-default violation — isIntKnown admitted a RecordGet with no raw Int form"

                _ ->
                    Err "qbe: deny-by-default violation — isIntKnown admitted a RecordGet with no raw Int form"

        PrimApp app ->
            case ( app.prim, app.args ) of
                ( "+", [ a, b ] ) ->
                    rawIntBin Add a b s

                ( "-", [ a, b ] ) ->
                    rawIntBin Sub a b s

                ( "*", [ a, b ] ) ->
                    rawIntBin Mul a b s

                _ ->
                    Err ("qbe: deny-by-default violation — isIntKnown admitted a PrimApp with no raw Int form: " ++ app.prim)

        _ ->
            Err "qbe: deny-by-default violation — isIntKnown admitted an expression with no raw Int form"


rawIntBin : BinOp -> Exp -> Exp -> S -> Result String ( Il.Arg, S )
rawIntBin op a b s =
    rawInt2 a b s
        |> Result.map
            (\( aa, bb, s1 ) ->
                let
                    ( r, s2 ) =
                        freshTmp s1
                in
                ( Il.Tmp r, emit (Bin (Just r) L op aa bb) s2 )
            )


{-| Both operands as raw `l` operands, LEFT FIRST (PrimApp args are in POP
order, so `a` is the VM's first pop = the lhs — the same order the existing
tag-testing inlines use).
-}
rawInt2 : Exp -> Exp -> S -> Result String ( Il.Arg, Il.Arg, S )
rawInt2 a b s =
    rawIntOf a s
        |> Result.andThen
            (\( aa, s1 ) ->
                rawIntOf b s1
                    |> Result.map (\( bb, s2 ) -> ( aa, bb, s2 ))
            )


{-| REBOX: write the raw `l` operand into frame slot `dest` as the tagged
40-byte Value it would have been — `tagNumber` at offset 0, the payload at
offset 8, the exact shape `lowerLit`'s `LNumber` arm produces.
-}
reboxArg : Int -> Il.Arg -> S -> S
reboxArg dest raw s =
    let
        ( d8, s1 ) =
            freshTmp s
    in
    emit (Store StoreW (Il.Con tagNumber) (Il.Tmp (slotTmp dest))) s1
        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
        |> emit (Store StoreL raw (Il.Tmp d8))


{-| REBOX a `w`-typed comparison result as a tagged Boolean Value.  The VM's
booleans carry a WORD payload (`lowerLit`'s `LBoolean` arm stores `StoreW`), so
this is that same shape, not a new one.
-}
reboxBoolean : Int -> Il.Arg -> S -> S
reboxBoolean dest raw s =
    let
        ( d8, s1 ) =
            freshTmp s
    in
    emit (Store StoreW (Il.Con tagBoolean) (Il.Tmp (slotTmp dest))) s1
        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
        |> emit (Store StoreW raw (Il.Tmp d8))


-- ==================== S4f: UNBOXED Float LOCALS ====================
--
-- WHAT THIS IS: the Float half of the representation pass.  A Float local whose
-- Float-ness is PROVEN FROM THE IR is held in a raw QBE `d` operand with NO
-- frame slot, and `+ - * f/` / `< <= > >= ==` on two such operands emit the
-- native double op with the tag test and the `rt_prim` CALL deleted.
--
-- THE TWO HALVES ARE NOT SYMMETRIC, AND THE MONOTYPE HALF IS DENIED —
-- MEASURED, NOT ASSUMED.  S4's Int proof has two sources: the checker's defun
-- monotype (peeled in parameter order, `intParamsOf`) and the IR.  For Int both
-- are sound because an Int-typed value is ALWAYS `tagNumber`: every integer
-- token is materialized as `storew tagNumber; storel n` (Mid/FromAst.elm
-- `Integer`/`Hex` arms), and Int and Float do not unify, so nothing else can
-- arrive at an Int parameter.
--
-- For Float the monotype half is UNSOUND on this front end, and the cause is
-- that SAME literal materialization: an integer token the checker types FLOAT
-- is still emitted as `tagNumber`.  MEASURED on the six-line
-- `f : Float -> Float; f x = x + 1.0; main = f 3`: the call site is
-- `storew 0; storel 3` (tagNumber = 0).  The VM is TAG-directed and
-- PROMOTES — `+ - *` take the f64 arm when EITHER operand is `.float`
-- (vendor/osier-rt/src/rt/prims.zig:727-764, primAdd/primSub/primMul) — so the VM answers 4.0, while a
-- raw `loadd` of that parameter's payload reinterprets the i64 payload bits as
-- a double.  MEASURED by hand-patching exactly what the monotype half would
-- emit into that .ssa: 4.0 (elmvm) vs 1.0 (native), BOTH exit 0.  That is the
-- silent-wrong class this project treats as disqualifying, and it is reachable
-- from the SOURCE LANGUAGE (`f 3` is well-typed Elm: `3` unifies with Float),
-- so a Float PARAMETER is not a raw source and `floatParamsOf` deliberately
-- does not exist.  The gate test for it is `NoRep.floatParam` (byte-identical
-- ON/OFF) plus `run norep-floatparam-i`, which calls it with an INT argument;
-- `Flt.intAtFloat` keeps the shape in the differential.
--
-- WHAT IS PROVEN INSTEAD, and why it is a fact about the VM's VALUES rather
-- than a guess about the checker — every admitted shape yields a value the VM
-- tags `tagFloat` UNCONDITIONALLY:
--   * `LFloat f` lowers to `storew tagFloat` + the double (lowerLit) — there is
--     no other way for that bit pattern to get there;
--   * `+ - * f/` whose operands are BOTH proven Float: the promote rule takes
--     the f64 arm (one float operand suffices) and returns `valFloat(...)`, so
--     the result is `tagFloat` too.  The float arithmetic is CLOSED under the
--     representation, which is what makes a raw chain legal.
-- Everything else — a Float-monotype parameter (measured above), an `App` (the
-- callee's tag is not in view), a record/list/tuple field read, a case or
-- destructure bind, `Basics.toFloat` — is DENIED and keeps its frame slot and
-- its `rt_prim` route.
--
-- CONSEQUENCE FOR THE TYPE SOURCE: unlike Int, there is no boxed-but-proven
-- Float binder (S4's `intBinders` holds Int-monotype parameters whose payload
-- is read on demand with `loadl (slot + 8)`), so `rawFloat` IS the binder half
-- of the predicate.  One map, because there is exactly one way to know.
--
-- REBOXING a raw Float at a boundary is `storew tagFloat` + `stored`
-- (`reboxFloat`, also the ONE place that writes a float Value — `lowerLit`'s
-- LFloat arm goes through it, so there is no second float-store path).
-- Escapes reach it through `lowerVal`'s `Var` arm, `rawFloatOf`'s `Nothing` is
-- a loud error rather than a fallback, and `captureBlits` reboxes explicitly:
-- the same boundaries, and no NEW `binderSlots` read, that S4's closed
-- enumeration established (S4 review Q1: exactly three reads of `binderSlots`
-- exist — lowerVal, rawIntOf's boxed-Var path, captureBlits).
--
-- COMPARISON SEMANTICS ARE THE VM'S, NaN INCLUDED.  The VM's primEq on two
-- floats is `asFloat a1 == asFloat a2` and primLt/Le/Gt/Ge is `asFloat a1 <
-- asFloat a2` (prims.zig:1328-1405) — IEEE, so `NaN == NaN` is FALSE, `NaN <
-- x` is FALSE and `-0.0 == 0.0` is TRUE.  QBE's `ceqd`/`cltd`/... are the
-- ORDERED IEEE compares and give the same answers; the unordered `cuod`/`cod`
-- pair is used nowhere here.  tools/qbe/fixtures/float.elm pins all of it
-- (nanEq/nanLt/negZeroEq/nanRel).
--
-- GC SAFETY IS STRUCTURAL, as for Int: a raw `d` temp is not a GC pointer and
-- is never placed in a `ROOT_VALUE_ARRAY` (it does not live in a frame slot at
-- all), and the collector's `scanValue` is tag-directed with a total
-- `else => {}` arm.  No new rooting protocol is added, deliberately.


{-| ONE definition of the static data item a Float value lives in, shared by
the literal arm (`lowerLit`) and the raw read (`rawFloatOf`) so that the same
float always resolves to the same `$dN` — `freshData` dedups on this key.
-}
floatData : Float -> S -> ( String, S )
floatData f s =
    freshData ("flt:" ++ String.fromFloat f)
        (\n -> { name = n, align = Just 8, items = [ DDouble f ], export_ = False })
        s


{-| THE PREDICATE, with the pass switch folded in exactly as `isIntExp` does:
one decision, one place to read `s.rep`.
-}
isFloatExp : S -> Exp -> Bool
isFloatExp s exp =
    s.rep && isFloatKnown s exp


{-| Deny-by-default proof that `exp`'s VALUE is `tagFloat`.  Each admitted
shape is one whose tag is settled by the VM's own rules (see the section
header) — NOT by the checker's opinion, which is what denies the parameter
case.  `App`, `GRef`, `Con`, `If`, `Let`, `Case`, every record/list operation
and every prim outside the float-arithmetic set return False.
-}
isFloatKnown : S -> Exp -> Bool
isFloatKnown s exp =
    case exp of
        Lit (LFloat _) ->
            True

        Var id ->
            -- the raw binder IS the proof: nothing else can put a binder here
            -- (no Float parameter is ever admitted, see the section header)
            Dict.member id s.rawFloat

        NoTail inner ->
            isFloatKnown s inner

        PrimApp app ->
            List.member app.prim [ "+", "-", "*", "f/" ]
                && List.length app.args == 2
                && List.all (isFloatKnown s) app.args

        _ ->
            False


{-| The RAW `d`-typed operand holding `exp`'s Float value.  DOMAIN: exactly
`isFloatKnown`'s, and the final arms are loud errors rather than a fallback, so
a shape added to one and not the other cannot silently pick up a wrong
representation.
-}
rawFloatOf : Exp -> S -> Result String ( Il.Arg, S )
rawFloatOf exp s =
    case exp of
        Lit (LFloat f) ->
            let
                ( fname, s1 ) =
                    floatData f s

                ( x, s2 ) =
                    freshTmp s1
            in
            Ok ( Il.Tmp x, emit (Load (Just x) D LoadD (Il.Sym fname)) s2 )

        NoTail inner ->
            rawFloatOf inner s

        Var id ->
            case Dict.get id s.rawFloat of
                Just raw ->
                    Ok ( raw, s )

                Nothing ->
                    Err ("qbe: raw Float operand not in scope: binder " ++ String.fromInt id ++ " (corrupt Mid tree)")

        PrimApp app ->
            case ( app.prim, app.args ) of
                ( "+", [ a, b ] ) ->
                    rawFloatBin Add a b s

                ( "-", [ a, b ] ) ->
                    rawFloatBin Sub a b s

                ( "*", [ a, b ] ) ->
                    rawFloatBin Mul a b s

                ( "f/", [ a, b ] ) ->
                    rawFloatBin Div a b s

                _ ->
                    Err ("qbe: deny-by-default violation — isFloatKnown admitted a PrimApp with no raw Float form: " ++ app.prim)

        _ ->
            Err "qbe: deny-by-default violation — isFloatKnown admitted an expression with no raw Float form"


rawFloatBin : BinOp -> Exp -> Exp -> S -> Result String ( Il.Arg, S )
rawFloatBin op a b s =
    rawFloat2 a b s
        |> Result.map
            (\( aa, bb, s1 ) ->
                let
                    ( r, s2 ) =
                        freshTmp s1
                in
                ( Il.Tmp r, emit (Bin (Just r) D op aa bb) s2 )
            )


{-| Both operands as raw `d` operands, LEFT FIRST — the same POP order
`rawInt2` documents (args[0] is the VM's first pop = the lhs).
-}
rawFloat2 : Exp -> Exp -> S -> Result String ( Il.Arg, Il.Arg, S )
rawFloat2 a b s =
    rawFloatOf a s
        |> Result.andThen
            (\( aa, s1 ) ->
                rawFloatOf b s1
                    |> Result.map (\( bb, s2 ) -> ( aa, bb, s2 ))
            )


{-| REBOX: write the raw `d` operand into frame slot `dest` as the tagged
40-byte Value it would have been — `tagFloat` at offset 0, the double at
offset 8.  This is the mirror of `reboxArg` and the ONLY place a float Value is
written.
-}
reboxFloat : Int -> Il.Arg -> S -> S
reboxFloat dest raw s =
    let
        ( d8, s1 ) =
            freshTmp s
    in
    emit (Store StoreW (Il.Con tagFloat) (Il.Tmp (slotTmp dest))) s1
        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
        |> emit (Store StoreD raw (Il.Tmp d8))


{-| Lift an integer-family `CmpOp` into the float family.  Total by
construction and the identity on everything else: at operand type `D` the
equality family already prints the same mnemonic (`ceqd`/`cned`), and the
`*d` variants were only ever built here.
-}
floatCmpOp : CmpOp -> CmpOp
floatCmpOp op =
    case op of
        Cslt ->
            Cltd

        Csle ->
            Cled

        Csgt ->
            Cgtd

        Csge ->
            Cged

        _ ->
            op


-- ============================ GREF AS A VALUE ============================


globalDescName : String -> String
globalDescName key =
    "gd_" ++ mangle key


lowerGRefValue : { key : String, force : Bool } -> Int -> S -> Result String S
lowerGRefValue ref dest s =
    if ref.force then
        -- 0-arg thunk: apply it for its value (the VM's `m g p` — the body
        -- re-executes on every reference; a direct call matches exactly).
        directCall ref.key [] dest False s

    else
        let
            ( rp, s1 ) =
                freshTmp s
        in
        Ok
            (emit (Call (Just rp) (Agg "val") (Il.Sym ("q_" ++ mangle "Rt.globalClosure")) [ ArgVal (Base L) (Il.Sym (globalDescName ref.key)) ]) s1
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
            )



-- ============================ APPLICATION ============================
-- App spines are flattened at lowering time (`twice add1 10` is NESTED Apps
-- in the raw tree; the Arity pass that flattens them for ZINC is not run).


spine : Exp -> ( Exp, List Exp )
spine exp =
    case exp of
        App app ->
            let
                ( head, args ) =
                    spine app.fn
            in
            ( head, args ++ app.args )

        NoTail inner ->
            spine inner

        _ ->
            ( exp, [] )


lowerApp : Exp -> Int -> Bool -> S -> Result String S
lowerApp exp dest isTail s =
    let
        ( head, args ) =
            spine exp
    in
    case head of
        GRef ref ->
            if ref.force then
                -- 0-arg thunk head: force it.  With no spine args in tail
                -- position the force IS the tail call; otherwise force as a
                -- plain value and apply the spine args through the generic
                -- path.
                if List.isEmpty args && isTail then
                    directCall ref.key [] dest True s

                else
                    directCall ref.key [] dest False s
                        |> Result.andThen
                            (\s1 ->
                                if List.isEmpty args then
                                    Ok s1

                                else
                                    rtApply (slotTmp dest) args dest isTail s1
                            )

            else
                case Dict.get ref.key s.arities of
                    Nothing ->
                        Err ("qbe: no arity for global " ++ ref.key)

                    Just n ->
                        if List.length args == n then
                            if isTail && ref.key == s.defunKey then
                                -- SELF-TAIL: the one tail call QBE can
                                -- express — an in-frame loop.
                                lowerSelfTail args s

                            else
                                directCall ref.key args dest isTail s

                        else
                            -- under-/over-applied known head: materialize the
                            -- global closure, then the generic apply path
                            -- (rt_apply builds/saturates partials exactly
                            -- like the VM's apply).
                            lowerGRefValue { key = ref.key, force = False } dest s
                                |> Result.andThen (\s1 -> rtApply (slotTmp dest) args dest isTail s1)

        _ ->
            -- first-class head (Var, call result, closure): value into a
            -- slot, generic apply.
            let
                ( hslot, s1 ) =
                    freshSlot s
            in
            lowerVal head hslot s1
                |> Result.andThen (\s2 -> rtApply (slotTmp hslot) args dest isTail s2)


lowerSelfTail : List Exp -> S -> Result String S
lowerSelfTail args s =
    -- VR1 TRIPWIRE: a ptrRead defun owns NO param slots, so this loop's rebind
    -- (blit into slots 2+i, jump @body) would write slots the body no longer
    -- reads.  ptrReadKeys excludes a defun with a self-tail by construction —
    -- so reaching this is a bug in THAT walk, and it must be a compile error,
    -- never a silent wrong loop.
    --
    -- Otherwise: stage EVERY arg into a fresh rooted slot BEFORE blitting any
    -- of them into the param slots.  The VM's appterm evaluates all args before
    -- rebinding, and an arg that reads a param (directly or nested) must see
    -- the OLD value, not one already overwritten by an earlier arg's blit.
    if Set.member s.defunKey s.ptrRead then
        Err ("qbe: internal — " ++ s.defunKey ++ " is a pointer-param callee and a self-tail loop (ptrReadKeys must exclude it)")

    else
        lowerArgsToSlots args s
            |> Result.map
                (\( slots, s1 ) ->
                    List.foldl
                        (\( slot, i ) acc ->
                            emit (Blit (Il.Tmp (slotTmp slot)) (Il.Tmp (slotTmp (i + 2))) vs) acc
                        )
                        s1
                        (List.indexedMap (\i slot -> ( slot, i )) slots)
                        |> jumpTo "body"
                )



-- Lower every arg into a ROOTED frame slot first (an arg's own lowering can
-- contain calls — safepoints — and only slots survive those), THEN emit the
-- stack staging as pure copies immediately before the call.  Between the
-- staging blits and the callee's prologue copies into its own rooted frame
-- there is no safepoint, so the unrooted stack copies are safe; staging
-- EARLIER would leave stale interior pointers under the moving GC.


stageArgs : List Exp -> S -> Result String ( List String, Int, S )
stageArgs args s =
    lowerArgsToSlots args s
        |> Result.andThen
            (\( slots, s1 ) -> Ok (stageSlots slots s1))


lowerArgsToSlots : List Exp -> S -> Result String ( List Int, S )
lowerArgsToSlots args s =
    List.foldl
        (\arg acc ->
            acc
                |> Result.andThen
                    (\( slots, s1 ) ->
                        let
                            ( tslot, s2 ) =
                                freshSlot s1
                        in
                        lowerVal arg tslot s2
                            |> Result.map (\s3 -> ( slots ++ [ tslot ], s3 ))
                    )
        )
        (Ok ( [], s ))
        args


-- Pure staging into CONTIGUOUS FRAME SLOTS, in PARAMETER order (arg 1 first
-- — the callee's %a0).  MEASURED CONSTRAINT: QBE lowers `alloc8 N` as a
-- DYNAMIC `subq $N, %rsp` (not a prologue slot), so a staging alloc inside a
-- loop body leaks N bytes of stack per iteration until the guard page kills
-- the process — churn.ssa's loop proved it.  Frame staging has no per-
-- iteration cost, and the staged copies are rooted (they sit inside the
-- ROOT_VALUE_ARRAY range), which is conservative-but-correct for the GC.
stageSlots : List Int -> S -> ( List String, Int, S )
stageSlots slots s =
    let
        n =
            List.length slots

        ( cbase, s1 ) =
            freshSlots (max 1 n) s

        base =
            slotTmp cbase
    in
    ( List.map (\i -> base ++ "_" ++ String.fromInt i) (List.range 0 (n - 1))
    , cbase
    , List.foldl
        (\( slot, i ) acc ->
            let
                ptmp =
                    base ++ "_" ++ String.fromInt i
            in
            acc
                |> emit (Bin (Just ptmp) L Add (Il.Tmp base) (Il.Con (vs * i)))
                |> emit (Blit (Il.Tmp (slotTmp slot)) (Il.Tmp ptmp) vs)
        )
        s1
        (List.indexedMap (\i slot -> ( slot, i )) slots)
    )


-- Direct saturated call to a known defun.  NON-TAIL: `%r =:ret call q_<key>`
-- then `rt_bounce(l %r)` chases any .tail the callee returned up to a .done
-- value (constant native stack across the tail chain).  TAIL (cross-defun):
-- `rt_tail_known(code, argblock, nargs)` builds a .tail whose args live in a
-- fresh GC array (surviving our rt_frame_leave) and returns the :ret, blitted
-- into the return area (slot 0) for the @ret block to hand upward.
directCall : String -> List Exp -> Int -> Bool -> S -> Result String S
directCall key args dest isTail s =
    let
        -- stage 6 B2: the tail-known seat retargets to the Mid rawAbi defun
        -- (the SAME `:ret` aggregate result shape, a symbol swap, and the
        -- nargs ARG CLASS is Base L — the rawAbi defun's params are `l`
        -- registers, and QBE subtyping is `l`->`w` only, so a `w` arg to an
        -- `l` param is a usecheck failure, the rtApply precedent).  B4 deleted
        -- the Zig rt_tail_known seat, so this is unconditional.
        ( tailCallee, nargsTy ) =
            ( "q_" ++ mangle "Rt.tail-known", Base L )

        bounceCallee =
            bounceSeat s
    in
    if isTail then
        -- TAIL: rt_tail-known takes ONE contiguous argblock pointer + nargs, so
        -- the staged block stays (the callee copies out of it at entry — the
        -- argblock itself dies with the GC array Rt.tail-known builds).
        stageArgs args s
            |> Result.andThen
                (\( _, base, s1 ) ->
                    let
                        ( rp, s2 ) =
                            freshTmp s1
                    in
                    rawAbiArityAgree "Rt.tail-known" 3
                        |> Result.andThen
                            (\_ ->
                                Ok
                                    (emit
                                        (Call (Just rp)
                                            (Agg "ret")
                                            (Il.Sym tailCallee)
                                            [ ArgVal (Base L) (Il.Sym ("q_" ++ mangle key))
                                            , ArgVal (Base L) (Il.Tmp (slotTmp base))
                                            , ArgVal nargsTy (Il.Con (List.length args))
                                            ]
                                        )
                                        s2
                                        |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp 0)) rvs)
                                        |> jumpTo "ret"
                                    )
                            )
                )

    else
        -- NON-TAIL: VR1 — each arg crosses as an `l` POINTER to the rooted
        -- frame slot it was just lowered into.  The contiguous staging block
        -- (and the 40-byte copy into it) is gone: the slot IS the argument.
        lowerArgsToSlots args s
            |> Result.andThen
                (\( slots, s1 ) ->
                    let
                        ( rp, s2 ) =
                            freshTmp s1

                        ( vp, s3 ) =
                            freshTmp s2
                    in
                    rawAbiArityAgree "Rt.bounce" 1
                        |> Result.andThen
                            (\_ ->
                                Ok
                                    (emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle key)) (List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots)) s3
                                        |> emit (Call (Just vp) (Agg "val") (Il.Sym bounceCallee) [ ArgVal (Base L) (Il.Tmp rp) ])
                                        |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                                    )
                            )
                )


-- Generic application through the runtime (first-class closures, partials,
-- over-application).  NON-TAIL: rt_apply bounces internally and returns a
-- .done value.  TAIL: rt_apply_tail returns the :ret (.tail or .done), blitted
-- into the return area.
--
-- stage 6 B1: under QBE_MIDDRIVER=1 the generic apply routes to the Mid
-- rawAbi defuns Rt.apply / Rt.apply-tail — the SAME aggregate result shapes
-- (`:val`/`:ret`), a symbol swap, and the nargs ARG CLASS changes: the Zig
-- seats take nargs as i32 `w`, the rawAbi defuns' params are `l` registers
-- (QBE subtyping is `l`->`w` only, so a `w` arg to an `l` param would be a
-- usecheck failure — MEASURED against the vendored qbe).
rtApply : String -> List Exp -> Int -> Bool -> S -> Result String S
rtApply fslotTmp args dest isTail s =
    let
        midKey =
            if isTail then
                "Rt.apply-tail"

            else
                "Rt.apply"

        ( callee, nargsTy ) =
            ( "q_" ++ mangle midKey, Base L )

        -- stage 6 B1fix (should-fix 1): the call site's aggregate class and
        -- sret size are DERIVED from rawAbiRetClass — the ONE source of truth
        -- that lowerDefun's ret type (line ~1334) and the @ret blit (line
        -- ~1435) also read.  The old code hard-wired `Agg "ret"`/`Agg "val"`
        -- and `rvs`/`vs` here in a second table: a 40-vs-80-byte sret drift
        -- (someone edits rawAbiRetClass, or adds a third aggregate class)
        -- would silently read/write 40 B of adjacent memory at the blit.
        -- Deriving both from the one function makes that drift impossible.
        retCls =
            rawAbiRetClass midKey

        retSize =
            case retCls of
                Agg "ret" ->
                    rvs

                _ ->
                    vs
    in
    stageArgs args s
        |> Result.andThen
            (\( _, baseSlot, s1 ) ->
                rawAbiArityAgree midKey 3
                    |> Result.andThen
                        (\_ ->
                            if isTail then
                                let
                                    ( rp, s2 ) =
                                        freshTmp s1
                                in
                                Ok
                                    (emit
                                        (Call (Just rp)
                                            retCls
                                            (Il.Sym callee)
                                            [ ArgVal (Base L) (Il.Tmp fslotTmp)
                                            , ArgVal (Base L) (Il.Tmp (slotTmp baseSlot))
                                            , ArgVal nargsTy (Il.Con (List.length args))
                                            ]
                                        )
                                        s2
                                        |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp 0)) retSize)
                                        |> jumpTo "ret"
                                    )

                            else
                                let
                                    ( rp, s2 ) =
                                        freshTmp s1
                                in
                                Ok
                                    (emit
                                        (Call (Just rp)
                                            retCls
                                            (Il.Sym callee)
                                            [ ArgVal (Base L) (Il.Tmp fslotTmp)
                                            , ArgVal (Base L) (Il.Tmp (slotTmp baseSlot))
                                            , ArgVal nargsTy (Il.Con (List.length args))
                                            ]
                                        )
                                        s2
                                        |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) retSize)
                                    )
                        )
            )



-- ============================ LET ============================


lowerLetBinders : List LetBinder -> S -> Result String S
lowerLetBinders binders s =
    List.foldl
        (\b acc -> Result.andThen (lowerLetBinder b) acc)
        (Ok s)
        binders


lowerLetBinder : LetBinder -> S -> Result String S
lowerLetBinder binder s =
    case binder of
        LetBind bind ->
            -- S4: an Int local gets NO FRAME SLOT AT ALL — it is held as a raw
            -- `l` operand and reboxed only where it escapes.  The slot counter
            -- does not advance, which is the structural half of this step's
            -- measurement.
            if isIntExp s bind.value then
                rawIntOf bind.value s
                    |> Result.map
                        (\( raw, s1 ) ->
                            { s1
                                | rawInt = Dict.insert bind.binder.id raw s1.rawInt
                                , intBinders = Set.insert bind.binder.id s1.intBinders
                            }
                        )

            else if isFloatExp s bind.value then
                -- S4f: the Float half of the same rule — a Float local PROVEN
                -- from the IR gets no frame slot either.  The two tests are
                -- disjoint (their base cases are `LNumber` vs `LFloat`, and a
                -- binder is registered by exactly one of them), so their order
                -- does not matter; Int is first because it came first.
                rawFloatOf bind.value s
                    |> Result.map
                        (\( raw, s1 ) ->
                            { s1 | rawFloat = Dict.insert bind.binder.id raw s1.rawFloat }
                        )

            else if isRawWordExp s.abi bind.value || isRawVarAlias s bind.value then
                -- Rt raw nodes (osier-consspike): a WORD-producing node binds
                -- to a raw temp, not a frame slot — a slot IS a 40-byte Value
                -- the collector scans, and a bare address in one is a garbage
                -- tag away from a crash.  The S4 rawInt shape, one register
                -- class over; reads go through rawWordArg, and lowerVal's Var
                -- arm rejects the value-position read.
                --
                -- B6 adds the SECOND half of that gate: `Var` of a binder that
                -- is ALREADY raw (`word z = a;` where `a` is a word-ABI
                -- parameter or a raw temp) is itself a word producer.  Before
                -- B6 no reachable program could have such a binder (a `word`
                -- parameter did not exist: every parameter was a 40-byte Value
                -- slot), which is exactly the gap B3 pinned — the same
                -- "`word z = w;` fails identically on two plain word binders"
                -- row.  rawWordArg's `Var` arm already resolves it; only the
                -- GATE was missing.
                rawWordOf bind.value s
                    |> Result.map
                        (\( raw, s1 ) ->
                            { s1 | rawWord = Dict.insert bind.binder.id raw s1.rawWord }
                        )

            else
                let
                    ( bslot, s1 ) =
                        freshSlot s
                in
                lowerVal bind.value bslot s1
                    |> Result.map (\s2 -> { s2 | binderSlots = Dict.insert bind.binder.id bslot s2.binderSlots })

        LetDestruct destruct ->
            lowerLetDestruct destruct s


-- The word-producing raw nodes (Mid.Ir's register-class split): exactly these
-- may bind a `let` binder to a raw temp.  RawVecStore is deliberately ABSENT
-- — it is an effect whose (ignored) result is the stored value's shape, and
-- it takes the ordinary slot path so its dummy binder's slot stays a valid
-- zeroed Value.
isRawWordExp : Dict String (List Int) -> Exp -> Bool
isRawWordExp abi exp =
    case exp of
        Unsafe node ->
            case node of
                RawAllocVector _ ->
                    True

                RawVecAddr _ ->
                    True

                RawTagOf _ ->
                    True

                RawPayload _ ->
                    True

                -- ===== STEP 5 word producers
                RawPayload32 _ ->
                    True

                RawTagIs _ ->
                    True

                RawBin _ ->
                    True

                RawUn _ ->
                    True

                RawCmp _ ->
                    True

                RawAllocRaw _ ->
                    True

                RawByteLoad _ ->
                    True

                RawWordLoad _ ->
                    True

                -- cffi U6: width-typed memory loads WIDEN into the word class
                -- (the `l` result type is what makes the extension the op's
                -- own), so the class is RawWordLoad's.
                RawMemLoad _ ->
                    True

                RawStrByte _ ->
                    True

                RawCallRaw _ ->
                    True

                -- cffi U2/U3: the typed C boundary is a WORD producer on every
                -- word width it lowers (the 32-bit family arrives EXTENDED into
                -- an `l` temp) — the same class RawCallRaw has.  An `f64`
                -- result is NOT: its temp is a `d` register, and binding it to
                -- a raw word binder would be a movq of an xmm (cffi U3).
                RawCallExtern call ->
                    case call.result of
                        FF64 ->
                            False

                        _ ->
                            True

                RawCallAgg _ ->
                    True

                RawDataAddr _ ->
                    True

                RawCStr _ ->
                    True

                RawSym _ ->
                    True

                RawAllocN _ ->
                    True

                RawCall call ->
                    -- stage 6 U2 / B6: a call to a WORD-ABI defun is a WORD
                    -- producer; a :val RawCall stays on the slot path.
                    Dict.member call.sym abi

                _ ->
                    False

        _ ->
            False


{-| B6 — is this expression a REBIND of an already-raw binder?  The one shape
`isRawWordExp` cannot see (it is a pure node test): `Var id` where `id` is in
`s.rawWord`.  `rawWordArg`'s `Var` arm resolves such a read, so the binding is
a straight alias of the same `l` operand — no temp, no slot, no copy.
-}
isRawVarAlias : S -> Exp -> Bool
isRawVarAlias s exp =
    case exp of
        Var id ->
            Dict.member id s.rawWord

        _ ->
            False


-- Compute a word-producing raw node into a fresh `l` temp — the binder-side
-- entry into rawWordArg's node cases (isRawWordExp has already gated the
-- call, so the value-binder error paths there are unreachable here).
rawWordOf : Exp -> S -> Result String ( Il.Arg, S )
rawWordOf exp s =
    rawWordArg exp s


{-| The shared RawCallAgg lowering (stage 6 A1/A1b): the callee is a FUNCTION
— either the `RawSym` producer (an `Il.Sym` naming a code label VERBATIM:
rt_bounce/rt_callN/rt_tail_known are called BY NAME with an aggregate result,
corpus-proven at Lower's directCall/rtApply arms) or a loaded code pointer in
a raw temp.  A DATA symbol (`RawCStr`/`RawDataAddr`, or any `Il.Sym` not from
a direct `RawSym`) and a constant (`Il.Con`) are NOT call targets and are
rejected loudly — qbe would otherwise silently assemble a call into static
data (the A1-review blocker).  Args are word producers, each a Base L word.
The two arms (word position returns the sret ADDRESS; value position blits
the :val into a slot) share this so the callee rule is ONE place.
-}
lowerRawCallAgg : { fn : Exp, args : List Exp, shape : String } -> S -> Result String ( Il.Arg, List Il.CallArg, S )
lowerRawCallAgg call s =
    let
        callee : Result String ( Il.Arg, S )
        callee =
            case call.fn of
                Unsafe (RawSym name) ->
                    Ok ( Il.Sym name, s )

                Unsafe (RawCStr _) ->
                    Err "qbe: rawCallAgg callee must be a FUNCTION symbol (rawsym(\"...\")) or a raw-word TEMP (a loaded code pointer), not a rawstr DATA address"

                Unsafe (RawDataAddr _) ->
                    Err "qbe: rawCallAgg callee must be a FUNCTION symbol (rawsym(\"...\")) or a raw-word TEMP (a loaded code pointer), not a recnames DATA address"

                _ ->
                    rawWordArg call.fn s
                        |> Result.andThen
                            (\( fnA, s1 ) ->
                                case fnA of
                                    Il.Tmp _ ->
                                        Ok ( fnA, s1 )

                                    Il.Con _ ->
                                        Err "qbe: rawCallAgg callee must be a FUNCTION symbol (rawsym(\"...\")) or a raw-word TEMP (a loaded code pointer), not a constant"

                                    Il.Sym _ ->
                                        Err "qbe: rawCallAgg callee must be a FUNCTION symbol (rawsym(\"...\")) or a raw-word TEMP (a loaded code pointer), not a DATA symbol (rawstr/recnames produce data defs, never call targets)"
                            )
    in
    callee
        |> Result.andThen
            (\( fnA, s1 ) ->
                List.foldl
                    (\e acc ->
                        Result.andThen
                            (\( args, st ) ->
                                rawWordArg e st
                                    |> Result.map (\( a, st2 ) -> ( args ++ [ ArgVal (Base L) a ], st2 ))
                            )
                            acc
                    )
                    (Ok ( [], s1 ))
                    call.args
                    |> Result.map (\( args, s2 ) -> ( fnA, args, s2 ))
            )



-- ============================ IF ============================
-- The VM's jmpf semantics EXACTLY (interp.zig .jmpf): false branch iff the
-- cond is a boolean with payload 0; anything else falls through.  THE
-- WORD-COND ARM (stage 6 P1c): a condition whose class is `:word` — a raw
-- 0/1 word — branches with a direct `jnz` on the word (no `mkbool`, no
-- frame slot, no reload); a `:val` condition keeps the byte-identical jmpf
-- machinery below (the compatibility seat: every existing `mkbool(..)`
-- spelling lowers exactly as it always did).


{-| Which lowering an `if` CONDITION takes.  `WordTest` — the cond is a raw
0/1 word, jumped on directly.  `ValTest` — the cond is a `:val` (a boolean
Value), tested by the jmpf machinery.  The word domain is EXACTLY the raw
word producers (`isRawWordExp`, plus `RawFltCmp` which is a word 0/1 but not
a raw-word BINDER) and a raw-word `Var` / `Lit (LNumber _)`.  Everything else
— a boolean Value, a `:val` `?:` join, `ShortAnd`/`ShortOr` (the checker
types them `:val`) — is `ValTest`.  A word-VALUED join (`If` with word
branches) is NOT admitted as a cond by the checker (J1 rejects it), so this
classifier never has to face it: treating such an `If` as `ValTest` would
box its 0/1 as a NUMBER and jmpf would silently misread it — which is
exactly why the checker refuses that shape loudly.
-}
type CondTest
    = WordTest
    | ValTest


condTest : Exp -> S -> CondTest
condTest exp s =
    case exp of
        NoTail inner ->
            condTest inner s

        Lit (LNumber _) ->
            WordTest

        Var id ->
            if Dict.member id s.rawWord then
                WordTest

            else
                ValTest

        Unsafe node ->
            if isWordCondNode s.abi node then
                WordTest

            else
                ValTest

        _ ->
            ValTest


{-| The word-producing `Unsafe` nodes that are a legal bare word CONDITION —
`isRawWordExp`'s domain (the raw-word producers, including a rawAbi
`RawCall`) plus `RawFltCmp` (a word 0/1 that `rawWordArg` lowers but
`isRawWordExp` deliberately excludes — it is not a raw-word BINDER node).
The float-word producers (`RawFltBin`/`RawIToF`/`RawLoadFlt`) are a `d`
class, not a 0/1 word, and are absent — the checker rejects a `:float` cond.
-}
isWordCondNode : Dict String (List Int) -> UnsafeNode -> Bool
isWordCondNode abi node =
    case node of
        RawCmp _ ->
            True

        RawBin _ ->
            True

        RawUn _ ->
            True

        RawTagIs _ ->
            True

        RawPayload _ ->
            True

        RawPayload32 _ ->
            True

        RawTagOf _ ->
            True

        RawWordLoad _ ->
            True

        -- cffi U6: a width-typed load is a 0/1-capable word (`if (p->u16)`),
        -- the same class RawWordLoad has.
        RawMemLoad _ ->
            True

        RawByteLoad _ ->
            True

        RawStrByte _ ->
            True

        RawVecAddr _ ->
            True

        RawAllocVector _ ->
            True

        RawAllocRaw _ ->
            True

        RawCallRaw _ ->
            True

        -- (cffi U3) a `d` result is not a 0/1 word — the same reason the
        -- float-word producers are absent from this list.
        RawCallExtern call ->
            case call.result of
                FF64 ->
                    False

                _ ->
                    True

        RawCallAgg _ ->
            True

        RawFltCmp _ ->
            True

        RawDataAddr _ ->
            True

        RawCStr _ ->
            True

        RawSym _ ->
            True

        RawAllocN _ ->
            True

        RawCall call ->
            Dict.member call.sym abi

        _ ->
            False


lowerIf : { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> Int -> Bool -> S -> Result String S
lowerIf block dest isTail s =
    case condTest block.cond s of
        WordTest ->
            lowerIfWordCond block dest isTail s

        ValTest ->
            let
                ( cslot, s0 ) =
                    freshSlot s
            in
            lowerVal block.cond cslot s0
                |> Result.andThen
                    (\s1 ->
                        let
                            ( tagT, s2 ) =
                                freshTmp s1

                            ( isbT, s3 ) =
                                freshTmp s2

                            ( pldT, s4 ) =
                                freshTmp s3

                            ( p8T, s5 ) =
                                freshTmp s4

                            ( iszT, s6 ) =
                                freshTmp s5

                            ( jfT, s7 ) =
                                freshTmp s6

                            ( thenLbl, s8 ) =
                                freshLbl "then" s7

                            ( elseLbl, s9 ) =
                                freshLbl "else" s8

                            ( joinLbl, s10 ) =
                                if isTail then
                                    ( "ret", s9 )

                                else
                                    freshLbl "join" s9
                        in
                        Ok
                            (emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp cslot))) s10
                                |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con tagBoolean))
                                |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp cslot)) (Il.Con 8))
                                |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
                                |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
                                |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
                                |> closeBlock (Jnz (Il.Tmp jfT) elseLbl thenLbl)
                            )
                            |> Result.andThen (lowerIfBranches thenLbl elseLbl joinLbl block dest isTail)
                    )


{-| The WORD-cond value/tail If: `jnz` on the raw 0/1 word (then on nonzero,
else on zero) — no `mkbool`, no slot, no reload.  The branches are the same
`lowerIfBranches` value join as the `:val` arm, so a `?:`/`EIfBlock` whose
CONDITION is a word but whose branches are VALUES (`(nslots < 8192) ?
mknum(..) : mknum(0)`) lowers with a word test and value branches — the
word cond threads through the `Let { x = If .. }` join without boxing.
-}
lowerIfWordCond : { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> Int -> Bool -> S -> Result String S
lowerIfWordCond block dest isTail s =
    let
        ( thenLbl, s1 ) =
            freshLbl "then" s

        ( elseLbl, s2 ) =
            freshLbl "else" s1

        ( joinLbl, s3 ) =
            if isTail then
                ( "ret", s2 )

            else
                freshLbl "join" s2
    in
    rawWordArg block.cond s3
        |> Result.andThen
            (\( w, s4 ) ->
                Ok (closeBlock (Jnz w thenLbl elseLbl) s4)
                    |> Result.andThen (lowerIfBranches thenLbl elseLbl joinLbl block dest isTail)
            )


{-| The two branches of a value/tail If — the shared tail of `lowerIf`'s
`:val` and word arms (byte-identical to the pre-word-cond body).
-}
lowerIfBranches : String -> String -> String -> { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> Int -> Bool -> S -> Result String S
lowerIfBranches thenLbl elseLbl joinLbl block dest isTail s =
    startBlock thenLbl s
        |> (\s11 ->
                if isTail then
                    lowerTail block.thenBranch s11

                else
                    lowerVal block.thenBranch dest s11
                        |> Result.map (jumpTo joinLbl)
           )
        |> Result.andThen
            (\s12 ->
                if isTail then
                    lowerTail block.elseBranch (startBlock elseLbl s12)

                else
                    lowerVal block.elseBranch dest (startBlock elseLbl s12)
                        |> Result.map (\st -> startBlock joinLbl (jumpTo joinLbl st))
            )



-- ============================ LOOPS (B4) ============================
-- The ONE new block structure: `Loop { cond, body }` emits, inside the
-- current defun,
--
--     <preceding block>  jmp @loopN
--     @loopN:            <cond test>  jnz @bodyN, @exitN   (word cond)
--                        <val test>  jnz @exitN, @bodyN   (val cond)
--     @bodyN:            <body>       jmp @loopN
--     @exitN:            <the continuation>
--
-- NO PHI: a loop-carried word local is a `RawAllocN` CELL the surface
-- lowerer emits (store/load), and a val local is a frame slot — the frame is
-- one pooled ROOT_VALUE_ARRAY, so every slot is a live root for the whole
-- body, including across the back edge.  Nothing is joined, so nothing needs
-- a phi, and the ONLY blocks a Break/Continue name are the frame's two
-- labels (no label strings enter the tree: `loops` is the enclosing stack,
-- so nested loops nest correctly by construction).
--
-- THE CONDITION IS RE-EVALUATED PER ITERATION at @loopN, never hoisted — the
-- surface `SWhile`'s cond is an ordinary expression lowered into that block.


lowerLoop : { cond : Exp, body : Exp } -> Int -> S -> Result String S
lowerLoop block dest s =
    let
        ( topLbl, s1 ) =
            freshLbl "loop" s

        ( exitLbl, s2 ) =
            freshLbl "loopexit" s1

        ( bodyLbl, s3 ) =
            freshLbl "loopbody" s2

        -- enter the loop: close the preceding block into the entry block, then
        -- start the CONDITION there (the back edge re-enters this same label)
        sEnter =
            startBlock topLbl (jumpTo topLbl s3)

        frame =
            { top = topLbl, exit = exitLbl }

        -- the body, then the back edge, then the exit block; `dest` receives a
        -- valid nil Value (the loop's own value — a dead binder in every
        -- surface use, but a frame slot is a scanned 40-byte Value and must
        -- never hold garbage)
        lowerBody st0 =
            let
                ( bodySlot, st1 ) =
                    freshSlot st0

                stBody =
                    startBlock bodyLbl { st1 | loops = frame :: st1.loops }
            in
            lowerVal block.body bodySlot stBody
                |> Result.map
                    (\st2 ->
                        storeNil dest
                            (startBlock exitLbl (jumpTo topLbl { st2 | loops = st0.loops }))
                    )
    in
    case condTest block.cond sEnter of
        WordTest ->
            rawWordArg block.cond sEnter
                |> Result.andThen (\( w, st ) -> Ok (closeBlock (Jnz w bodyLbl exitLbl) st))
                |> Result.andThen (\st -> lowerBody st)

        ValTest ->
            let
                ( cslot, s4 ) =
                    freshSlot sEnter

                ( tagT, s5 ) =
                    freshTmp s4

                ( isbT, s6 ) =
                    freshTmp s5

                ( pldT, s7 ) =
                    freshTmp s6

                ( p8T, s8 ) =
                    freshTmp s7

                ( iszT, s9 ) =
                    freshTmp s8

                ( jfT, s10 ) =
                    freshTmp s9
            in
            lowerVal block.cond cslot (startBlock topLbl (jumpTo topLbl s10))
                |> Result.map
                    (\st ->
                        emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp cslot))) st
                            |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con tagBoolean))
                            |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp cslot)) (Il.Con 8))
                            |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
                            |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
                            |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
                            -- the VM's jmpf test: `jfT` is 1 for a FALSY value,
                            -- so a nonzero test EXITS the loop
                            |> closeBlock (Jnz (Il.Tmp jfT) exitLbl bodyLbl)
                    )
                |> Result.andThen (\st -> lowerBody st)


{-| A `break`/`continue` LEAF: close the current block with the jump and then
PARK a fresh, unreachable block.  The park is what makes a leaf usable in a
VALUE position at all — every value-position caller (`lowerIfBranches`, the
`Let` binder arm, `lowerTail`) closes ITS block with a jump after lowering a
subexpression, and without a fresh label that second close would emit a
duplicate block label (invalid QBE).  Nothing ever enters the parked block.
-}
lowerLoopLeaf : String -> S -> Result String S
lowerLoopLeaf which s =
    case s.loops of
        [] ->
            Err "qbe: a break/continue leaf outside any loop — the surface checker must reject this first"

        frame :: _ ->
            let
                target =
                    if which == "top" then
                        frame.top

                    else
                        frame.exit

                ( parked, s1 ) =
                    freshLbl "loopdead" s
            in
            Ok (startBlock parked (closeBlock (Jmp target) s1))


-- ============================ SHORT-CIRCUIT BOOLEANS ============================
-- Mid.ToZinc's ShortAnd/ShortOr/NotEqual, transcribed onto the same jmpf
-- machinery lowerIf uses (jmpfFalse = the VM's exact .jmpf: false branch iff
-- the value is a boolean with payload 0; anything else falls through).
--   a && b  : a falsy -> literal False, else the VALUE of b (not coerced).
--   a || b  : a truthy -> literal True, else the VALUE of b.
--   a /= b  : `=` is the FULL primEq (deep for cons/vector, name for symbol);
--             False when a==b, True when a!=b.
-- The right side is only lowered on its own block reached by a jump, so it is
-- NOT evaluated when the left side decides (the brief's "must not evaluate"
-- requirement).


lowerShortAnd : { left : Exp, right : Exp, falseLabel : String, endLabel : String } -> Int -> S -> Result String S
lowerShortAnd block dest s =
    let
        ( cslot, s0 ) =
            freshSlot s
    in
    lowerVal block.left cslot s0
        |> Result.andThen
            (\s1 ->
                let
                    ( falseLbl, s2 ) =
                        freshLbl "andf" s1

                    ( trueLbl, s3 ) =
                        freshLbl "andt" s2

                    ( endLbl, s4 ) =
                        freshLbl "ande" s3
                in
                Ok (jmpfFalse cslot falseLbl trueLbl s4)
                    |> Result.andThen (lowerVal block.right dest)
                    |> Result.map (\st -> startBlock falseLbl (jumpTo endLbl st))
                    |> Result.andThen (lowerLit (LBoolean False) dest)
                    |> Result.map (\st -> startBlock endLbl (jumpTo endLbl st))
            )


lowerShortOr : { left : Exp, right : Exp, falseLabel : String, endLabel : String } -> Int -> S -> Result String S
lowerShortOr block dest s =
    let
        ( cslot, s0 ) =
            freshSlot s
    in
    lowerVal block.left cslot s0
        |> Result.andThen
            (\s1 ->
                let
                    ( falseLbl, s2 ) =
                        freshLbl "orf" s1

                    ( trueLbl, s3 ) =
                        freshLbl "ort" s2

                    ( endLbl, s4 ) =
                        freshLbl "ore" s3
                in
                Ok (jmpfFalse cslot falseLbl trueLbl s4)
                    |> Result.andThen (lowerLit (LBoolean True) dest)
                    |> Result.map (\st -> startBlock falseLbl (jumpTo endLbl st))
                    |> Result.andThen (lowerVal block.right dest)
                    |> Result.map (\st -> startBlock endLbl (jumpTo endLbl st))
            )


lowerNotEqual : { left : Exp, right : Exp, falseLabel : String, endLabel : String } -> Int -> S -> Result String S
lowerNotEqual block dest s =
    let
        ( eqSlot, s0 ) =
            freshSlot s
    in
    -- `=` here is primEq via lowerNumEq (inline i64 compare for number/number,
    -- rt_prim "=" for every other tag pair), exactly Mid.ToZinc's NotEqual.
    lowerNumEq [ block.left, block.right ] eqSlot s0
        |> Result.andThen
            (\s1 ->
                let
                    ( falseLbl, s2 ) =
                        freshLbl "nef" s1

                    ( trueLbl, s3 ) =
                        freshLbl "net" s2

                    ( endLbl, s4 ) =
                        freshLbl "nee" s3
                in
                Ok (jmpfFalse eqSlot falseLbl trueLbl s4)
                    |> Result.andThen (lowerLit (LBoolean False) dest)
                    |> Result.map (\st -> startBlock falseLbl (jumpTo endLbl st))
                    |> Result.andThen (lowerLit (LBoolean True) dest)
                    |> Result.map (\st -> startBlock endLbl (jumpTo endLbl st))
            )



-- ============================ CASE / PATTERNS ============================
-- The VM's own match semantics, transcribed from Lower.Pattern / Mid.ToZinc
-- (the ZINC emitter's readPath/matchInstrs/emitBinds) and prims.zig:
--   * MCons/MEmpty/MVector are TAG tests (cons=4, nil=5, vector=10).
--   * MTagEq/MLitEq run the REAL `=` primitive via rt_prim (deep/name
--     equality — a symbol tag is compared by NAME, never pointer: a QBE
--     symbol's name points at static data while the VM interns, so only the
--     byte compare in primEq is exact).
--   * The Steps are ALLOC-FREE pointer chases (fst/snd = car/cdr loads,
--     hd/tl = nil-guarded car/cdr, IdxStep = vector.data[i] blit), so no
--     GC can run mid-chase; the result lands in a ROOTED slot before any
--     later safepoint reads it.
-- ROOTING AUDIT (the hazard this construct is most prone to): the scrutinee
-- is lowered ONCE into a rooted slot and every test/bind reads it (or a
-- sub-value blitted into ANOTHER rooted slot) from there.  Every value live
-- across a safepoint — rt_prim "=", rt_con, and any alt body's own calls —
-- sits in a pooled-frame slot, so the GC rewrites it in place.  A sub-value
-- read into a slot and then followed by an allocation (lowerEqMatch reads the
-- sub-value BEFORE materializing a string literal via rt_string) is safe
-- because the slot is rooted the whole time.  Dead scrutinee/bind slots stay
-- conservative roots (they hold whole tagged Values, never interior
-- pointers), so the collector never chases a stale address.


lowerCase : { scrutinee : Exp, scrutId : Binder, alts : List Alt, endLabel : String } -> Int -> Bool -> S -> Result String S
lowerCase branch dest isTail s =
    let
        -- UNIT B item 1's license, computed ONCE: the scrutinee's checker type,
        -- only for a Var scrutinee (a non-Var scrutinee is Gap E — deny).
        scrutType =
            case branch.scrutinee of
                Var id ->
                    typeOfBinder s id

                _ ->
                    Nothing

        ( scrutSlot, s1 ) =
            freshSlot s
    in
    lowerVal branch.scrutinee scrutSlot s1
        |> Result.andThen
            (\s2 ->
                lowerAlts branch.alts scrutSlot scrutType dest isTail
                    { s2 | binderSlots = Dict.insert branch.scrutId.id scrutSlot s2.binderSlots }
            )


lowerAlts : List Alt -> Int -> Maybe Rep.Type -> Int -> Bool -> S -> Result String S
lowerAlts alts scrutSlot scrutType dest isTail s =
    let
        ( errLbl, sE ) =
            freshLbl "cerr" s

        ( endLbl, sEnd ) =
            freshLbl "cend" sE
    in
    lowerAltsLoop alts errLbl endLbl scrutSlot scrutType dest isTail sEnd
        |> Result.andThen
            (\sA ->
                lowerNonExhaustive "non-exhaustive case" (startBlock errLbl sA)
                    |> Result.map (startBlock endLbl)
            )


-- Emit alts in order: each alt's tests jump to the NEXT alt's entry on
-- failure (the last alt's to the error label).  A passing alt binds, runs its
-- body, and (non-tail) joins endLbl.
lowerAltsLoop : List Alt -> String -> String -> Int -> Maybe Rep.Type -> Int -> Bool -> S -> Result String S
lowerAltsLoop alts errLbl endLbl scrutSlot scrutType dest isTail s =
    case alts of
        [] ->
            Ok s

        alt :: rest ->
            let
                ( restFailLbl, s1 ) =
                    case rest of
                        [] ->
                            ( errLbl, s )

                        _ ->
                            freshLbl "cnext" s
            in
            lowerMatchTests alt.matches scrutSlot scrutType restFailLbl s1
                |> Result.andThen (lowerBinds alt.binds scrutSlot)
                |> Result.andThen
                    (\s2 ->
                        if isTail then
                            lowerTail alt.body s2

                        else
                            lowerVal alt.body dest s2
                                |> Result.map (jumpTo endLbl)
                    )
                |> Result.andThen
                    (\s3 ->
                        case rest of
                            [] ->
                                Ok s3

                            _ ->
                                lowerAltsLoop rest errLbl endLbl scrutSlot scrutType dest isTail (startBlock restFailLbl s3)
                    )


-- A destructuring let is the same machinery as a single always-matching alt:
-- value -> scrutinee slot, ordered tests (any failure -> simple-error), then
-- the pattern bindings in a block that FALLS THROUGH to the continuation.
lowerLetDestruct : { scrutId : Binder, value : Exp, matches : List Match, binds : List ( Binder, ValuePath ), badLabel : String, okLabel : String } -> S -> Result String S
lowerLetDestruct destruct s =
    let
        scrutType =
            case destruct.value of
                Var id ->
                    typeOfBinder s id

                _ ->
                    Nothing

        ( scrutSlot, s1 ) =
            freshSlot s
    in
    lowerVal destruct.value scrutSlot s1
        |> Result.andThen
            (\s2 ->
                let
                    ( errLbl, s3 ) =
                        freshLbl "lerr" s2

                    ( okLbl, s4 ) =
                        freshLbl "lok" s3

                    s5 =
                        { s4 | binderSlots = Dict.insert destruct.scrutId.id scrutSlot s4.binderSlots }
                in
                lowerMatchTests destruct.matches scrutSlot scrutType errLbl s5
                    |> Result.andThen
                        (\s6 ->
                            lowerNonExhaustive "non-exhaustive let pattern" (jumpTo okLbl s6 |> startBlock errLbl)
                                |> Result.map (startBlock okLbl)
                        )
                    |> Result.andThen (lowerBinds destruct.binds scrutSlot)
            )


-- Run each test in order; a failing test jumps to failLbl.  Falls through iff
-- ALL pass (the ZINC emitter's `matchInstrs ++ Jmpf nextLabel` per test).
lowerMatchTests : List Match -> Int -> Maybe Rep.Type -> String -> S -> Result String S
lowerMatchTests matches scrutSlot scrutType failLbl s =
    List.foldl
        (\m acc -> Result.andThen (lowerMatch m scrutSlot scrutType failLbl) acc)
        (Ok s)
        matches


lowerMatch : Match -> Int -> Maybe Rep.Type -> String -> S -> Result String S
lowerMatch match scrutSlot scrutType failLbl s =
    case match of
        MCons steps ->
            Ok (lowerTagMatch steps scrutSlot tagCons failLbl s)

        MEmpty steps ->
            Ok (lowerTagMatch steps scrutSlot tagNil failLbl s)

        MVector steps ->
            Ok (lowerTagMatch steps scrutSlot tagVector failLbl s)

        MTagEq steps tag ->
            -- UNIT B item 1: inline the payload-pointer compare when the
            -- scrutinee is a USER-ADT Var and the tag is read straight from the
            -- Con's element 0 (steps == [IdxStep 0] — the shape namedMatch
            -- emits for a bare-constructor pattern, e.g. adtmatch's `case e of
            -- Lit n -> ...`).  Under the user-ADT type the only reachable
            -- symbol value is a compiler-emitted content-keyed `sym:` pointer,
            -- so pointer equality == name equality.  Anything else (a non-Var
            -- scrutinee — Gap E; a nested path; a non-ADT scrutinee) keeps the
            -- real `=` call.
            if s.typeSpec && steps == [ IdxStep 0 ] && (Maybe.map isUserAdt scrutType == Just True) then
                lowerPtrEqMatch steps scrutSlot tag failLbl s

            else
                lowerEqMatch steps scrutSlot (LSymbol tag) failLbl s

        MLitEq steps lit ->
            lowerEqMatch steps scrutSlot lit failLbl s


-- Read the value at `steps`, test its tag == expected; pass -> passLbl,
-- fail -> failLbl.
lowerTagMatch : List Step -> Int -> Int -> String -> S -> S
lowerTagMatch steps scrutSlot expected failLbl s =
    let
        ( p, s1 ) =
            freshSlot s

        sRead =
            readSteps steps scrutSlot p s1

        ( tagT, s2 ) =
            freshTmp sRead

        ( isM, s3 ) =
            freshTmp s2

        ( passLbl, s4 ) =
            freshLbl "cpass" s3
    in
    emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp p))) s4
        |> emit (Cmp (Just isM) W Ceq (Il.Tmp tagT) (Il.Con expected))
        |> closeBlock (Jnz (Il.Tmp isM) passLbl failLbl)
        |> startBlock passLbl


-- Read the value at `steps`, then run the REAL `=` prim against `lit` (the
-- VM's deep/name equality).  args = [lit, sub-value] so rt_prim's first pop
-- (a1) is the literal — the same operand order Mid.ToZinc pushes.
lowerEqMatch : List Step -> Int -> Lit -> String -> S -> Result String S
lowerEqMatch steps scrutSlot lit failLbl s =
    let
        ( p, s1 ) =
            freshSlot s

        sRead =
            readSteps steps scrutSlot p s1

        ( l, s2 ) =
            freshSlot sRead
    in
    lowerLit lit l s2
        |> Result.andThen
            (\s3 ->
                let
                    ( r, s4 ) =
                        freshSlot s3
                in
                rtPrimSlots "=" [ l, p ] r s4
                    |> Result.map
                        (\s5 ->
                            let
                                ( passLbl, s6 ) =
                                    freshLbl "cpass" s5
                            in
                            jmpfFalse r failLbl passLbl s6
                        )
            )


-- UNIT B item 1: the MTagEq inline.  Read the Con's tag symbol at `steps`
-- (a bare symbol Value: tag at +0, content-keyed `sym:` pointer at +8) and the
-- materialized `LSymbol tag` literal, then compare the PAYLOAD POINTERS — not
-- the tags — and jump on equality.  Licensed by lowerMatch: only a user-ADT
-- scrutinee at `steps == [IdxStep 0]`, where pointer equality == name equality.
lowerPtrEqMatch : List Step -> Int -> String -> String -> S -> Result String S
lowerPtrEqMatch steps scrutSlot tag failLbl s =
    let
        ( p, s1 ) =
            freshSlot s

        sRead =
            readSteps steps scrutSlot p s1

        ( l, s2 ) =
            freshSlot sRead
    in
    lowerLit (LSymbol tag) l s2
        |> Result.map
            (\s3 ->
                let
                    ( pp, s4 ) =
                        freshTmp s3

                    ( lp, s5 ) =
                        freshTmp s4

                    ( sp, s6 ) =
                        freshTmp s5

                    ( lp2, s7 ) =
                        freshTmp s6

                    ( eq, s8 ) =
                        freshTmp s7

                    ( passLbl, s9 ) =
                        freshLbl "cpass" s8
                in
                emit (Bin (Just pp) L Add (Il.Tmp (slotTmp p)) (Il.Con 8)) s9
                    |> emit (Bin (Just lp) L Add (Il.Tmp (slotTmp l)) (Il.Con 8))
                    |> emit (Load (Just sp) L LoadL (Il.Tmp pp))
                    |> emit (Load (Just lp2) L LoadL (Il.Tmp lp))
                    |> emit (Cmp (Just eq) L Ceq (Il.Tmp sp) (Il.Tmp lp2))
                    |> closeBlock (Jnz (Il.Tmp eq) passLbl failLbl)
                    |> startBlock passLbl
            )


-- Bind each pattern variable by reading its path from the scrutinee slot into
-- a fresh rooted slot.
lowerBinds : List ( Binder, ValuePath ) -> Int -> S -> Result String S
lowerBinds binds scrutSlot s =
    List.foldl
        (\( binder, path ) acc ->
            Result.andThen (lowerBind binder path scrutSlot) acc
        )
        (Ok s)
        binds


lowerBind : Binder -> ValuePath -> Int -> S -> Result String S
lowerBind binder path scrutSlot s =
    let
        ( bslot, s1 ) =
            freshSlot s
    in
    lowerPath path scrutSlot bslot s1
        |> Result.map (\s2 -> { s2 | binderSlots = Dict.insert binder.id bslot s2.binderSlots })


lowerPath : ValuePath -> Int -> Int -> S -> Result String S
lowerPath path scrutSlot dest s =
    case path of
        VPath steps ->
            Ok (readSteps steps scrutSlot dest s)

        VField steps field ->
            -- A record field pattern reads the record via its steps into a
            -- ROOTED slot, then (E) tag-tests it: tag 14 -> Rt.recGet (the
            -- name walk — pattern sites do not take the positional arm, whose
            -- rank needs the scrutinee's binder type, which lowerPath does not
            -- carry); tag 4 -> the old assoc/snd chain.  The record is in a
            -- rooted slot before any call, so an allocation inside recGet/
            -- assoc/snd can never see an unrooted record.
            let
                ( p, s1 ) =
                    freshSlot s

                sRead =
                    readSteps steps scrutSlot p s1

                ( recB, s2 ) =
                    freshBinder sRead

                s3 =
                    { s2 | binderSlots = Dict.insert recB.id p s2.binderSlots }
            in
            if s.rec then
                lowerVal (recordAccessBody recB Nothing field) dest s3

            else
                let
                    ( l, s4 ) =
                        freshSlot s3
                in
                lowerLit (LSymbol field) l s4
                    |> Result.andThen
                        (\s5 ->
                            let
                                ( r, s6 ) =
                                    freshSlot s5
                            in
                            rtPrimSlots "assoc" [ l, p ] r s6
                                |> Result.andThen (\s7 -> rtPrimSlots "snd" [ r ] dest s7)
                        )


-- Apply `steps` from srcSlot, writing the reached value into dstSlot.  Pure:
-- every step is an alloc-free pointer chase.
readSteps : List Step -> Int -> Int -> S -> S
readSteps steps src dst s =
    case steps of
        [] ->
            emit (Blit (Il.Tmp (slotTmp src)) (Il.Tmp (slotTmp dst)) vs) s

        step :: rest ->
            let
                ( mid, s1 ) =
                    freshSlot s
            in
            readSteps rest mid dst (lowerStep step src mid s1)


lowerStep : Step -> Int -> Int -> S -> S
lowerStep step src dst s =
    case step of
        FstStep ->
            chaseField 8 src dst s

        SndStep ->
            if s.consArr then
                chaseCdr src dst s

            else
                chaseField 16 src dst s

        HdStep ->
            lowerHdTl True src dst s

        TlStep ->
            lowerHdTl False src dst s

        IdxStep j ->
            let
                ( dataT, s1 ) =
                    freshTmp s

                ( p8, s2 ) =
                    freshTmp s1

                ( eT, s3 ) =
                    freshTmp s2
            in
            emit (Bin (Just p8) L Add (Il.Tmp (slotTmp src)) (Il.Con 8)) s3
                |> emit (Load (Just dataT) L LoadL (Il.Tmp p8))
                |> emit (Bin (Just eT) L Add (Il.Tmp dataT) (Il.Con (vs * j)))
                |> emit (Blit (Il.Tmp eT) (Il.Tmp (slotTmp dst)) vs)


-- fst/snd: blit the car body (at `off` in the cons Value) into dst.
chaseField : Int -> Int -> Int -> S -> S
chaseField off src dst s =
    let
        ( ptrT, s1 ) =
            freshTmp s

        ( p8, s2 ) =
            freshTmp s1
    in
    emit (Bin (Just p8) L Add (Il.Tmp (slotTmp src)) (Il.Con off)) s2
        |> emit (Load (Just ptrT) L LoadL (Il.Tmp p8))
        |> emit (Blit (Il.Tmp ptrT) (Il.Tmp (slotTmp dst)) vs)


-- (A) the cdr of a cons: element 1 of the 2-element array `car` heads
-- (*(car + vs)).  The cons Value's cdr payload word is now NULL, so the cdr
-- VALUE is derived through the car pointer, exactly like the Zig readers.
chaseCdr : Int -> Int -> S -> S
chaseCdr src dst s =
    let
        ( carT, s1 ) =
            freshTmp s

        ( p8, s2 ) =
            freshTmp s1

        ( cdrT, s3 ) =
            freshTmp s2
    in
    emit (Bin (Just p8) L Add (Il.Tmp (slotTmp src)) (Il.Con 8)) s3
        |> emit (Load (Just carT) L LoadL (Il.Tmp p8))
        |> emit (Bin (Just cdrT) L Add (Il.Tmp carT) (Il.Con vs))
        |> emit (Blit (Il.Tmp cdrT) (Il.Tmp (slotTmp dst)) vs)


-- hd/tl (prims.zig primHd/primTl): nil -> nil, else car/cdr.  The nil arm is
-- dead in well-typed patterns (an MCons test precedes) but kept for exact
-- parity with the VM primitive.
lowerHdTl : Bool -> Int -> Int -> S -> S
lowerHdTl isHd src dst s =
    let
        ( tagT, s1 ) =
            freshTmp s

        ( isnil, s2 ) =
            freshTmp s1

        ( nilLbl, s3 ) =
            freshLbl "hnil" s2

        ( chaseLbl, s4 ) =
            freshLbl "hcar" s3

        ( doneLbl, s5 ) =
            freshLbl "hdone" s4
    in
    emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp src))) s5
        |> emit (Cmp (Just isnil) W Ceq (Il.Tmp tagT) (Il.Con tagNil))
        |> closeBlock (Jnz (Il.Tmp isnil) nilLbl chaseLbl)
        |> startBlock nilLbl
        |> storeNil dst
        |> jumpTo doneLbl
        |> startBlock chaseLbl
        |> (if isHd then
                chaseField 8 src dst

            else if s.consArr then
                chaseCdr src dst

            else
                chaseField 16 src dst
           )
        |> jumpTo doneLbl
        |> startBlock doneLbl


storeNil : Int -> S -> S
storeNil dst s =
    let
        ( d8, s1 ) =
            freshTmp s
    in
    emit (Store StoreW (Il.Con tagNil) (Il.Tmp (slotTmp dst))) s1
        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dst)) (Il.Con 8))
        |> emit (Store StoreL (Il.Con 0) (Il.Tmp d8))


-- The VM's jmpf test (interp.zig .jmpf): false iff the slot is a boolean with
-- payload 0; anything else falls through.  Closes the current block and starts
-- the true branch's block.
jmpfFalse : Int -> String -> String -> S -> S
jmpfFalse slot falseLbl trueLbl s =
    let
        ( tagT, s1 ) =
            freshTmp s

        ( isbT, s2 ) =
            freshTmp s1

        ( pldT, s3 ) =
            freshTmp s2

        ( p8T, s4 ) =
            freshTmp s3

        ( iszT, s5 ) =
            freshTmp s4

        ( jfT, s6 ) =
            freshTmp s5
    in
    emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp slot))) s6
        |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con tagBoolean))
        |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp slot)) (Il.Con 8))
        |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
        |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
        |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
        |> closeBlock (Jnz (Il.Tmp jfT) falseLbl trueLbl)
        |> startBlock trueLbl


-- The unreachable (in well-typed Elm) non-exhaustive failure arm: raise via a
-- runtime exit.  Loud, never a silent miscompile.
lowerNonExhaustive : String -> S -> Result String S
lowerNonExhaustive msg s =
    let
        ( msgName, s1 ) =
            freshData ("msg:" ++ msg)
                (\n -> { name = n, align = Just 8, items = [ DStr msg, DByte 0 ], export_ = False })
                s

        -- stage 6 U2: the die arm retargets from the Zig `rt_die` seat to the
        -- Mid rawAbi defun Rt.die (q_Rt_x2edie) — the same single WORD argument
        -- (the static message address), a symbol swap; the result type follows
        -- the callee (Base L for the Mid word-ABI defun).  B4 deleted the Zig
        -- rt_die seat, so this is unconditional.
        --
        -- stage 6 A1 (was the U2 review's nice-to-have 5, "NOT DERIVED"):
        -- the single WORD argument below is now checked against
        -- Mid.Rt.rawAbiArity — a param added to Rt.die in U3-U5 without
        -- touching this site is a compile Err, not the silent under-apply
        -- (the callee reading a garbage register) the rawAbi convention
        -- exists to kill.
        ( rtDieSym, rtDieRet ) =
            ( "q_" ++ mangle "Rt.die", Base L )

        dieArgs =
            [ ArgVal (Base L) (Il.Sym msgName) ]
    in
    rawAbiArityAgree "Rt.die" (List.length dieArgs)
        |> Result.map
            (\_ ->
                emit (Call Nothing rtDieRet (Il.Sym rtDieSym) dieArgs) s1
                    |> closeBlock Hlt
            )


-- ============================ CON (ADT construction) ============================
-- The VM's MX representation (Mid.ToZinc Con): a vector[tag, a1..an] — element
-- 0 is the BARE ctor name as a symbol, then the args in source order.  The tag
-- and each arg are lowered into ROOTED slots first, then rt_con allocates the
-- vector and copies them through the write barrier (values.valVector +
-- writeBarrierVectorStore, exactly the VM's absvector + address-> path), so
-- the collector sees the VM's own vector layout.
lowerCon : { tag : String, args : List Exp } -> Int -> S -> Result String S
lowerCon con dest s =
    let
        ( tagSlot, s1 ) =
            freshSlot s
    in
    lowerLit (LSymbol con.tag) tagSlot s1
        |> Result.andThen
            (\s2 ->
                lowerArgsToSlots con.args s2
                    |> Result.andThen
                        (\( slots, s3 ) ->
                            let
                                n =
                                    List.length slots

                                -- rt_con / Rt.con read `args` as a CONTIGUOUS
                                -- [*]Value array, so stage the (rooted, but not
                                -- necessarily adjacent) arg slots into one
                                -- contiguous frame block immediately before the
                                -- call — pure copies, no safepoint between.
                                ( _, cbase, s4 ) =
                                    stageSlots slots s3

                                ( rp, s5 ) =
                                    freshTmp s4
                            in
                            -- The Mid route: Con through the Mid defun
                            -- Rt.con (tag, argsPtr, n) — the allocation is
                            -- Rt.allocVector (the Mid collector), so the ADT
                            -- vector lands in the MID heap (no cross-heap
                            -- edge).  argsPtr and n are boxed as number
                            -- Values in fresh slots (the lean ABI passes
                            -- POINTERS to Value slots, plus a count word).
                            let
                                ( argsPtrSlot, sA ) =
                                    freshSlot s5

                                ( nSlot, sB ) =
                                    freshSlot sA

                                sC =
                                    storeValueCell tagNumber [ Il.Tmp (slotTmp cbase) ] argsPtrSlot sB

                                sD =
                                    storeValueCell tagNumber [ Il.Con n ] nSlot sC
                            in
                            Ok
                                (emit
                                    (Call (Just rp)
                                        (Agg "val")
                                        (Il.Sym ("q_" ++ mangle "Rt.con"))
                                        [ ArgVal (Base L) (Il.Tmp (slotTmp tagSlot))
                                        , ArgVal (Base L) (Il.Tmp (slotTmp argsPtrSlot))
                                        , ArgVal (Base L) (Il.Tmp (slotTmp nSlot))
                                        , ArgVal (Base W) (Il.Con 3)
                                        ]
                                    )
                                    sD
                                    |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
                                )
                        )
            )


-- Tuples are the VM's right-nested cons chain (Mid.ToZinc Tup: `@p` = cons),
-- so `(a, b, c)` = cons(a, cons(b, c)).  Lowered here — rather than left
-- failing loudly — because a destructuring LET (in scope) is only parseable by
-- this compiler as a tuple/record/list pattern, and the tuple form is the
-- minimal route to a real LetDestruct-with-bindings fixture (records and
-- ListLit stay out of scope).  The tuple PATTERN is MCons + FstStep/SndStep —
-- the same Step/Match machinery the Case lowering already implements.
lowerTup : List Exp -> Int -> S -> Result String S
lowerTup es dest s =
    lowerVal (buildTuple es) dest s


buildTuple : List Exp -> Exp
buildTuple es =
    case es of
        x :: xs ->
            if List.isEmpty xs then
                x

            else
                PrimApp { prim = "cons", args = [ x, buildTuple xs ] }

        [] ->
            Lit (LNumber 0)


-- ============================ AGGREGATES ============================
-- Records, tuples and lists all desugar to the VM's own prim sequences
-- (Mid.ToZinc's RecordLit/RecordGet/RecordUpdate/ListLit/Tup emission), so
-- representation parity is BY CONSTRUCTION: `cons`/`@p`/`emptylist`/`assoc`/
-- `snd` route through rt_prim, which runs the REAL VM primitive.  Every
-- element is lowered into a ROOTED frame slot before any later allocation
-- (lowerPrimApp -> lowerArgsToSlots -> rtPrimSlots), and the accumulator of
-- a right-nested cons chain is always the RESULT of an rt_prim call living in
-- a rooted slot, so a moving collection can never see an unrooted element or
-- a stale interior pointer mid-build (see ROOTING AUDIT in the report).


-- [a, b, c] = cons a (cons b (cons c nil)) — the VM's ListLit: start from
-- emptylist, cons each element in source order (right-nested).
buildList : List Exp -> Exp
buildList es =
    case es of
        x :: xs ->
            PrimApp { prim = "cons", args = [ x, buildList xs ] }

        [] ->
            PrimApp { prim = "emptylist", args = [ Lit (LNumber 0) ] }


-- {f=e1, g=e2} = cons (@p (sym f) e1) (cons (@p (sym g) e2) nil): an assoc
-- list in SOURCE order, the first field at the head.  `@p` = cons (prims.zig
-- primAtP), so a pair is (sym field . value); RecordGet then reads it with
-- assoc + snd.  This is EXACTLY Mid.ToZinc's RecordLit.
buildRecord : List ( String, Exp ) -> Exp
buildRecord setters =
    case setters of
        ( field, value ) :: rest ->
            PrimApp
                { prim = "cons"
                , args =
                    [ PrimApp { prim = "@p", args = [ Lit (LSymbol field), value ] }
                    , buildRecord rest
                    ]
                }

        [] ->
            PrimApp { prim = "emptylist", args = [ Lit (LNumber 0) ] }


-- rec.f = snd (assoc (sym f) rec) — Mid.ToZinc's RecordGet.  assoc takes
-- (key, list) in pop order (args[0] is the first pop = key), returns the
-- first (field . value) pair whose car matches by NAME, or nil if absent —
-- snd of nil then faults exactly as the VM does.
buildRecordGet : Exp -> String -> Exp
buildRecordGet rec field =
    PrimApp
        { prim = "snd"
        , args =
            [ PrimApp { prim = "assoc", args = [ Lit (LSymbol field), rec ] } ]
        }


-- {base | f=e1, g=e2} prepends each (field . value) pair onto base in source
-- order (Mid.ToZinc RecordUpdate): the result is (g,e2) :: (f,e1) :: base, so
-- assoc's FIRST-occurrence search finds the new value and the domain is
-- preserved (the old field, if present, is merely shadowed — the type
-- checker forbids adding fields, and duplicate labels shadow the same way).
buildRecordUpdate : { base : Exp, updates : List ( String, Exp ) } -> Exp
buildRecordUpdate update =
    List.foldl
        (\( field, value ) acc ->
            PrimApp
                { prim = "cons"
                , args = [ PrimApp { prim = "@p", args = [ Lit (LSymbol field), value ] }, acc ]
                }
        )
        update.base
        update.updates


-- ============================ E: POSITIONAL RECORDS ============================
-- The corrected design (handoff osier-phase3-ea-plan, Variant B): a record is
-- tag 14 (ValTag `record`) with payload [data, len, names] — data = the n
-- field VALUES in canonical order; len = n; names = the address of a STATIC,
-- content-keyed array of `sym:<field>` DRefs (RawDataAddr).  Equality is over
-- VALUES only (len + Rt.vecEq), exactly Elm's order-insensitive `==`.  Every
-- access site tag-tests: tag 14 -> positional data[rank] (closed row) or
-- Rt.recGet/Rt.recUpd (open/absent/non-Var); tag 4 -> the old assoc/snd chain
-- (host-built records).  QBE_NOREC=1 restores the assoc-chain route everywhere
-- (the hatch must reproduce the 00cc7da corpus byte-for-byte).


-- The canonical field order: first-occurrence dedup (scoped labels keep the
-- assoc first-match semantics), then a stable sort by name.  The selfhost
-- subset has NO List.sort (Basics.compare is numeric-only in this lane), so the
-- order is an insertion sort over Prelude.compare (byte-lexicographic).
dedupFirst : List String -> List String
dedupFirst names =
    List.foldl (\n acc -> if List.member n acc then acc else acc ++ [ n ]) [] names


-- Byte-lexicographic string comparison, expressible in the selfhost subset:
-- String.toList + Char.toCode + integer `<` (Prelude.compare is NOT importable
-- into Lower — the real-elm build refuses to compile Prelude's own prim names).
compareCharLists : List Char -> List Char -> Order
compareCharLists xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            EQ

        ( [], _ ) ->
            LT

        ( _, [] ) ->
            GT

        ( x :: xr, y :: yr ) ->
            let
                cx =
                    Char.toCode x

                cy =
                    Char.toCode y
            in
            if cx < cy then
                LT

            else if cx > cy then
                GT

            else
                compareCharLists xr yr


compareStrings : String -> String -> Order
compareStrings a b =
    compareCharLists (String.toList a) (String.toList b)


insertString : String -> List String -> List String
insertString x acc =
    case acc of
        [] ->
            [ x ]

        y :: rest ->
            case compareStrings x y of
                LT ->
                    x :: acc

                _ ->
                    y :: insertString x rest


sortStrings : List String -> List String
sortStrings names =
    List.foldl insertString [] names


canonicalNames : List String -> List String
canonicalNames names =
    sortStrings (dedupFirst names)


-- A record literal's canonical (name, value) pairs: first-occurrence dedup,
-- stable sort by name.
recordFields : List ( String, Exp ) -> List ( String, Exp )
recordFields setters =
    let
        dedup =
            List.foldl
                (\p acc ->
                    if List.any (\q -> Tuple.first q == Tuple.first p) acc then
                        acc

                    else
                        acc ++ [ p ]
                )
                []
                setters
    in
    sortByFirst dedup


sortByFirst : List ( String, Exp ) -> List ( String, Exp )
sortByFirst pairs =
    List.foldl insertPair [] pairs


insertPair : ( String, Exp ) -> List ( String, Exp ) -> List ( String, Exp )
insertPair p acc =
    case acc of
        [] ->
            [ p ]

        q :: rest ->
            case compareStrings (Tuple.first p) (Tuple.first q) of
                LT ->
                    p :: acc

                _ ->
                    q :: insertPair p rest


rankOf : String -> List String -> Maybe Int
rankOf field names =
    case List.indexedMap (\i n -> ( i, n )) names |> List.filter (\( _, n ) -> n == field) of
        ( i, _ ) :: _ ->
            Just i

        [] ->
            Nothing


-- The canonical sorted field names of a record subexpression, when it is a Var
-- whose binderId has a zonked TRecord with a CLOSED tail in the defun's
-- per-binder table (Lower's S already carries table + defunKey).  Anything else
-- (absent binder, non-Var subexpression, open-tail row) -> Nothing, i.e. the
-- walk (recGet/recUpd), never the positional arm.
closedRecordNames : S -> Exp -> Maybe (List String)
closedRecordNames s rec =
    case rec of
        Var id ->
            Dict.get s.defunKey s.table
                |> Maybe.andThen
                    (\entry ->
                        case entry.binders of
                            QbeTypes.Binders binderMap ->
                                Dict.get id binderMap
                                    |> Maybe.andThen
                                        (\ty ->
                                            case ty of
                                                Rep.TRecord row ->
                                                    case row.tail of
                                                        Rep.REmpty ->
                                                            Just (canonicalNames (List.map Tuple.first row.fields))

                                                        Rep.RVar _ ->
                                                            Nothing

                                                _ ->
                                                    Nothing
                                        )

                            QbeTypes.BindersAbsent ->
                                Nothing
                    )

        _ ->
            Nothing


{-| UNIT B item 3: the `(rank, field-type)` of a record field read, for a
closed-tail, DUPLICATE-LABEL-FREE `TRecord` Var in the binder map.  `Nothing` —
the walk or the ordinary boxed read, never a raw positional read — for an
absent binder, a non-Var base, an open-tail row, a duplicate-label row (whose
value is an assoc CHAIN, not a positional vector, even under E), or a field not
in the row.  Keyed by `binderKey` (not `defunKey`), so a closure's record base
resolves against its ENCLOSING defun's binder map.
-}
closedRecordField : S -> Exp -> String -> Maybe ( Int, Rep.Type )
closedRecordField s rec field =
    case rec of
        Var id ->
            typeOfBinder s id
                |> Maybe.andThen
                    (\ty ->
                        case ty of
                            Rep.TRecord row ->
                                case row.tail of
                                    Rep.REmpty ->
                                        let
                                            names =
                                                List.map Tuple.first row.fields
                                        in
                                        if List.length names /= List.length (dedupFirst names) then
                                            -- duplicate labels -> a scoped-label
                                            -- chain, never a positional vector.
                                            Nothing

                                        else
                                            case List.filter (\( n, _ ) -> n == field) row.fields of
                                                ( _, ft ) :: _ ->
                                                    rankOf field (canonicalNames names)
                                                        |> Maybe.map (\r -> ( r, ft ))

                                                [] ->
                                                    Nothing

                                    _ ->
                                        Nothing

                            _ ->
                                Nothing
                    )

        _ ->
            Nothing


{-| The field TYPE only (drop the rank).
-}
closedRecordFieldType : S -> Exp -> String -> Maybe Rep.Type
closedRecordFieldType s rec field =
    Maybe.map Tuple.second (closedRecordField s rec field)


boxTagIs : Exp -> Int -> Exp
boxTagIs value tag =
    Unsafe (RawMkValue { tag = tagBoolean, words = [ Unsafe (RawTagIs { value = value, tag = tag }) ] })


-- The shared access body: tag 14 -> positional (Just rank) or recGet walk;
-- tag 4 -> assoc/snd chain; else (defensive) -> recGet walk.  `recB` is the
-- binder the record subexpression was bound to (evaluated ONCE).
recordAccessBody : Binder -> Maybe Int -> String -> Exp
recordAccessBody recB rank field =
    let
        recV =
            Var recB.id

        positional =
            Unsafe (RawVecLoad { vec = Unsafe (RawPayload { value = recV, word = 0 }), index = Lit (LNumber (Maybe.withDefault 0 rank)) })

        walk =
            PrimApp { prim = "recGet", args = [ recV, Lit (LSymbol field) ] }

        chain =
            PrimApp { prim = "snd", args = [ PrimApp { prim = "assoc", args = [ Lit (LSymbol field), recV ] } ] }
    in
    If
        { cond = boxTagIs recV tagRecord
        , thenBranch = Maybe.withDefault walk (Maybe.map (\_ -> positional) rank)
        , elseBranch =
            If
                { cond = boxTagIs recV tagCons
                , thenBranch = chain
                , elseBranch = walk
                , falseLabel = "r4"
                , endLabel = "rg4"
                }
        , falseLabel = "r14"
        , endLabel = "rg"
        }


-- Bind the record subexpression ONCE, then the access body (its evaluation can
-- allocate; the Let slot roots it across the tag test and both arms).
recordAccessExp : Binder -> Exp -> Maybe Int -> String -> Exp
recordAccessExp recB rec rank field =
    Let { binders = [ LetBind { binder = recB, value = rec } ], body = recordAccessBody recB rank field }


lowerRecordLit : List ( String, Exp ) -> Int -> S -> Result String S
lowerRecordLit setters dest s =
    if s.rec then
        lowerRecordLitPos setters dest s

    else
        lowerVal (buildRecord setters) dest s


hasDuplicateLabels : List ( String, Exp ) -> Bool
hasDuplicateLabels setters =
    let
        names =
            List.map Tuple.first setters
    in
    List.length names /= List.length (dedupFirst names)


lowerRecordLitPos : List ( String, Exp ) -> Int -> S -> Result String S
lowerRecordLitPos setters dest s =
    if hasDuplicateLabels setters then
        -- scoped labels ({ x = 1, x = 2 }): the positional vector holds ONE
        -- value per name and cannot represent the duplicate, so keep the
        -- assoc-chain route (Record.remove's removeFieldImpl needs the chain).
        lowerVal (buildRecord setters) dest s

    else
        case recordFields setters of
            [] ->
                -- {} stays the old emptylist route (nil) — avoids allocArray(Value, 0).
                lowerVal (PrimApp { prim = "emptylist", args = [ Lit (LNumber 0) ] }) dest s

            fields ->
                let
                    n =
                        List.length fields

                    names =
                        List.map Tuple.first fields
                in
                -- All values FIRST (their lowering can allocate), THEN the data
                -- array, then alloc-free stores + wrap — the data temp stays valid
                -- because nothing between the alloc and the wrap can move the heap.
                lowerArgsToSlots (List.map Tuple.second fields) s
                    |> Result.andThen
                        (\( slots, s1 ) ->
                            let
                                -- All field values are in slots FIRST (their lowering
                                -- can allocate), THEN the data array, then alloc-free
                                -- stores + wrap — the data temp stays valid because
                                -- nothing between the alloc and the wrap moves the
                                -- heap.  The data array allocates through the
                                -- Mid seat Rt.allocVector (no cross-heap edge);
                                -- rt_vec_alloc is no longer emitted by anything.
                                ( dataArg, s2 ) =
                                    midGcAllocSeat "Rt.allocVector" (Il.Con n) s1

                                -- The store goes to the PLAIN Mid seat
                                -- (Rt.vecStorePlain, zighost Z2): the data array
                                -- was allocated one statement ago, so it cannot
                                -- be an old block and there is nothing to
                                -- remember — the plain store IS the whole
                                -- contract (the barrier would be a wasted
                                -- region load per field).
                                storeSym =
                                    Il.Sym ("q_" ++ mangle "Rt.vecStorePlain")

                                s3 =
                                    List.foldl
                                        (\( i, slot ) st ->
                                            emit
                                                (Call Nothing (Base W) storeSym
                                                    [ ArgVal (Base L) dataArg
                                                    , ArgVal (Base W) (Il.Con i)
                                                    , ArgVal (Base L) (Il.Tmp (slotTmp slot))
                                                    ]
                                                )
                                                st
                                        )
                                        s2
                                        (List.indexedMap (\i slot -> ( i, slot )) slots)
                            in
                            rawWordArg (Unsafe (RawDataAddr names)) s3
                                |> Result.map
                                    (\( namesArg, s4 ) ->
                                        storeValueCell tagRecord [ dataArg, Il.Con n, namesArg ] dest s4
                                    )
                        )


lowerRecordGet : Exp -> String -> Int -> S -> Result String S
lowerRecordGet rec field dest s =
    if s.rec then
        let
            ( recB, s0 ) =
                freshBinder s

            rank =
                rankOf field (Maybe.withDefault [] (closedRecordNames s rec))
        in
        lowerVal (recordAccessExp recB rec rank field) dest s0

    else
        lowerVal (buildRecordGet rec field) dest s


-- recInsert applied once per update, left to right (the walk form; no
-- positional copy — recInsert handles BOTH `=` update and `<-` insertion:
-- find-and-overwrite when present, append when absent).
applyUpdates : Exp -> List ( String, Exp ) -> Exp
applyUpdates base updates =
    List.foldl (\( f, e ) acc -> PrimApp { prim = "recInsert", args = [ acc, Lit (LSymbol f), e ] }) base updates


-- The update's walk form: tag 14 -> recUpd fold; tag 4 -> the old chain
-- prepend (host-built base); else -> recUpd fold (defensive).
recordUpdateWalkExp : Binder -> Exp -> List ( String, Exp ) -> Exp
recordUpdateWalkExp baseB base updates =
    let
        baseV =
            Var baseB.id

        walk =
            applyUpdates baseV updates

        chain =
            buildRecordUpdate { base = baseV, updates = updates }
    in
    Let
        { binders = [ LetBind { binder = baseB, value = base } ]
        , body =
            If
                { cond = boxTagIs baseV tagRecord
                , thenBranch = walk
                , elseBranch =
                    If
                        { cond = boxTagIs baseV tagCons
                        , thenBranch = chain
                        , elseBranch = walk
                        , falseLabel = "u4"
                        , endLabel = "ug4"
                        }
                , falseLabel = "u14"
                , endLabel = "ug"
                }
        }


-- The update's positional form (closed+Var): 1 alloc + one store per canonical
-- field (the update's pre-lowered slot, or a copy of base.data[rank]) + wrap,
-- reusing base's names pointer.  Direct IL so the update VALUES lower BEFORE
-- the data array allocates (their lowering can allocate; the data temp is only
-- live across alloc-free stores).
lowerRecordUpdateClosed : Binder -> List String -> List String -> List ( String, Binder ) -> Int -> S -> Result String S
lowerRecordUpdateClosed baseB baseNames resultNames updPairs dest s =
    let
        n =
            List.length resultNames

        baseV =
            Var baseB.id

        baseRankOf : String -> Maybe Int
        baseRankOf f =
            rankOf f baseNames

        slotFor : String -> Maybe Int
        slotFor f =
            case List.filter (\( uf, _ ) -> uf == f) updPairs of
                ( _, b ) :: _ ->
                    -- the update value's ROOTED slot (updB.id was mapped to it
                    -- in lowerRecordUpdate); NOT b.id itself, which is a
                    -- negative synthetic binder id.
                    Dict.get b.id s.binderSlots

                [] ->
                    Nothing

        ( baseSlot, s1 ) =
            freshSlot s
    in
    lowerVal baseV baseSlot s1
        |> Result.andThen
            (\s2 ->
                let
                    ( tagT, s3 ) =
                        freshTmp s2

                    ( is14T, s4 ) =
                        freshTmp s3

                    ( recLbl, s5 ) =
                        freshLbl "updrec" s4

                    ( notRecLbl, s6 ) =
                        freshLbl "updchain" s5

                    ( joinLbl, s7 ) =
                        freshLbl "updjoin" s6

                    s8 =
                        s7
                            |> emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp baseSlot)))
                            |> emit (Cmp (Just is14T) W Ceq (Il.Tmp tagT) (Il.Con tagRecord))
                            |> closeBlock (Jnz (Il.Tmp is14T) recLbl notRecLbl)

                    -- tag-14 arm: allocate, copy/store, wrap.  The update values
                    -- were pre-lowered into rooted slots, so the data array allocates
                    -- AFTER them (same load-bearing order as lowerRecordLitPos).
                    -- The allocation goes through the Mid seat Rt.allocVector.
                    ( ndArg, s10 ) =
                        midGcAllocSeat "Rt.allocVector" (Il.Con n) (startBlock recLbl s8)

                    -- The plain store seat (see lowerRecordLitPos).
                    storeSym =
                        Il.Sym ("q_" ++ mangle "Rt.vecStorePlain")

                    storeOne : Int -> String -> S -> Result String S
                    storeOne rank name st =
                        case slotFor name of
                            Just uslot ->
                                Ok
                                    (emit
                                        (Call Nothing (Base W) storeSym
                                            [ ArgVal (Base L) ndArg
                                            , ArgVal (Base W) (Il.Con rank)
                                            , ArgVal (Base L) (Il.Tmp (slotTmp uslot))
                                            ]
                                        )
                                        st
                                    )

                            Nothing ->
                                -- copy base's value for this field: read
                                -- base.data[baseRankOf name] (the base's data
                                -- array is in the BASE's canonical order, which
                                -- differs from the RESULT's when `<-` inserted
                                -- a field).
                                case baseRankOf name of
                                    Nothing ->
                                        Err ("qbe: record update field " ++ name ++ " is absent from a closed base row (corrupt Mid tree)")

                                    Just brank ->
                                        let
                                            ( dataT, st1 ) =
                                                freshTmp st

                                            ( p8T, st2 ) =
                                                freshTmp st1

                                            ( elemT, st3 ) =
                                                freshTmp st2
                                        in
                                        Ok
                                            (st3
                                                |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp baseSlot)) (Il.Con 8))
                                                |> emit (Load (Just dataT) L LoadL (Il.Tmp p8T))
                                                |> emit (Bin (Just elemT) L Add (Il.Tmp dataT) (Il.Con (vs * brank)))
                                                |> emit
                                                    (Call Nothing (Base W) storeSym
                                                        [ ArgVal (Base L) ndArg
                                                        , ArgVal (Base W) (Il.Con rank)
                                                        , ArgVal (Base L) (Il.Tmp elemT)
                                                        ]
                                                    )
                                            )

                    wrap : S -> Result String S
                    wrap st =
                        -- The result's names array is content-keyed on the
                        -- RESULT field set (base ++ `<-`-inserted fields), NOT
                        -- the base's — an insertion extends the row.
                        rawWordArg (Unsafe (RawDataAddr resultNames)) st
                            |> Result.map
                                (\( namesArg, st1 ) ->
                                    storeValueCell tagRecord [ ndArg, Il.Con n, namesArg ] dest st1
                                        |> jumpTo joinLbl
                                )
                in
                List.foldl
                    (\( rank, name ) acc -> Result.andThen (storeOne rank name) acc)
                    (Ok s10)
                    (List.indexedMap (\rank name -> ( rank, name )) resultNames)
                    |> Result.andThen wrap
                    |> Result.andThen
                        (\sRec ->
                            -- not-rec arm: tag 4 -> chain prepend; else -> recUpd walk.
                            let
                                ( tagT2, s11 ) =
                                    freshTmp sRec

                                ( is4T, s12 ) =
                                    freshTmp s11

                                ( chainLbl, s13 ) =
                                    freshLbl "updassoc" s12

                                ( walkLbl, s14 ) =
                                    freshLbl "updwalk" s13

                                s15 =
                                    s14
                                        |> startBlock notRecLbl
                                        |> emit (Load (Just tagT2) W LoadW (Il.Tmp (slotTmp baseSlot)))
                                        |> emit (Cmp (Just is4T) W Ceq (Il.Tmp tagT2) (Il.Con tagCons))
                                        |> closeBlock (Jnz (Il.Tmp is4T) chainLbl walkLbl)

                                chain =
                                    buildRecordUpdate { base = baseV, updates = List.map (\( f, b ) -> ( f, Var b.id )) updPairs }

                                walk =
                                    applyUpdates baseV (List.map (\( f, b ) -> ( f, Var b.id )) updPairs)
                            in
                            lowerVal chain dest (startBlock chainLbl s15)
                                |> Result.map (jumpTo joinLbl)
                                |> Result.andThen
                                    (\s16 ->
                                        lowerVal walk dest (startBlock walkLbl s16)
                                            |> Result.map (\s17 -> startBlock joinLbl (jumpTo joinLbl s17))
                                    )
                        )
            )


lowerRecordUpdate : { base : Exp, updates : List ( String, Exp ) } -> Int -> S -> Result String S
lowerRecordUpdate update dest s =
    if s.rec then
        case closedRecordNames s update.base of
            Just baseNames ->
                -- pre-lower base and the update values into rooted slots, bind
                -- them, then the positional (closed) form.  The RESULT's field
                -- set is the base's row UNION the updates (a `<-` insertion
                -- ADDS fields), canonicalized.
                let
                    resultNames =
                        canonicalNames (baseNames ++ List.map Tuple.first update.updates)

                    ( baseSlot, s0 ) =
                        freshSlot s

                    ( baseB, s1 ) =
                        freshBinder s0
                in
                lowerVal update.base baseSlot s1
                    |> Result.andThen
                        (\s2 ->
                            lowerArgsToSlots (List.map Tuple.second update.updates) s2
                                |> Result.andThen
                                    (\( updSlots, s3 ) ->
                                        let
                                            ( updBs, s4 ) =
                                                freshBinders (List.length updSlots) s3

                                            updPairs =
                                                List.map2 (\( f, _ ) b -> ( f, b )) update.updates updBs

                                            s5 =
                                                List.foldl
                                                    (\( b, slot ) st -> { st | binderSlots = Dict.insert b.id slot st.binderSlots })
                                                    { s4 | binderSlots = Dict.insert baseB.id baseSlot s4.binderSlots }
                                                    (List.map2 (\b slot -> ( b, slot )) updBs updSlots)
                                        in
                                        lowerRecordUpdateClosed baseB baseNames resultNames updPairs dest s5
                                    )
                        )

            Nothing ->
                let
                    ( baseB, s0 ) =
                        freshBinder s
                in
                lowerVal (recordUpdateWalkExp baseB update.base update.updates) dest s0

    else
        lowerVal (buildRecordUpdate update) dest s


-- ============================ PRIMAPPS ============================
-- Inline: the VM's own semantics, transcribed from prims.zig —
--   + - *  : NO tag guard; float promotion when EITHER side is .float;
--             i64 WRAPPING arithmetic otherwise (primAdd/Sub/Mul).
--   < <= > >= : both numeric AND neither float -> i64 compare; anything
--             else -> False (primLt/Le/Gt/Ge).
--   =       : both number -> payload compare; else rt_prim (primEq's
--             tag-pairwise string/symbol/bool/nil/deep paths).
-- Every non-fast path (and every other prim name) goes to rt_prim, which
-- runs the VM's REAL primitive — so the slow path is exact by construction.


lowerPrimApp : { prim : String, args : List Exp } -> Int -> S -> Result String S
lowerPrimApp app dest s =
    if List.length app.args == 2 && List.member app.prim [ "+", "-", "*" ] then
        lowerArith app.prim app.args dest s

    else if List.length app.args == 2 && app.prim == "f/" && List.all (isFloatExp s) app.args then
        -- S4f: Elm's `/` (prim `f/`) on two PROVEN Floats is QBE's `divd`.
        -- THIS IS A SEPARATE BRANCH ON PURPOSE: `f/` must NOT be routed
        -- through `lowerArith`, whose inline's integer arm assumes `+ - *`.
        -- MEASURED, on the first cut that did route it: `7 / 2` (integer
        -- TOKENS at type Float) took that arm and answered 3 where the VM's
        -- primFdiv promotes and answers 3.5, and `1 / 0` — which is Infinity
        -- in the VM — hit an i64 `div` and died with SIGFPE (no output).  A
        -- non-float operand pair therefore keeps the ordinary `rt_prim` route
        -- below, where primFdiv does the promotion.
        rawFloatBin Div (first app.args) (second app.args) s
            |> Result.map (\( r, s1 ) -> reboxFloat dest r s1)

    else if List.length app.args == 2 && List.member app.prim [ "<", "<=", ">", ">=" ] then
        lowerCompare (cmpOp app.prim) app.args dest s

    else if List.length app.args == 2 && app.prim == "=" then
        lowerNumEq app.args dest s

    else
        lowerArgsToSlots app.args s
            |> Result.andThen (\( slots, s1 ) -> rtPrimSlots app.prim slots dest s1)


cmpOp : String -> CmpOp
cmpOp prim =
    case prim of
        "<" ->
            Cslt

        "<=" ->
            Csle

        ">" ->
            Csgt

        _ ->
            Csge


arithOp : String -> BinOp
arithOp prim =
    case prim of
        "+" ->
            Add

        "-" ->
            Sub

        _ ->
            -- `+ - *` only: every caller is inside `lowerArith`, which
            -- `lowerPrimApp` gates to that set.  `Div` — the float division —
            -- is built directly in `lowerPrimApp`'s `f/` branch instead,
            -- because `lowerArith`'s inline integer arm is only correct for
            -- `+ - *`.
            Mul


lowerArgs2 : List Exp -> S -> Result String ( Int, Int, S )
lowerArgs2 args s =
    let
        ( a1, s1 ) =
            freshSlot s

        ( a2, s2 ) =
            freshSlot s1
    in
    -- PrimApp args are in POP order: args[0] is the VM's first pop = lhs.
    lowerVal (first args) a1 s2
        |> Result.andThen (\s3 -> lowerVal (second args) a2 s3)
        |> Result.map (\s3 -> ( a1, a2, s3 ))


first : List Exp -> Exp
first list =
    case list of
        x :: _ ->
            x

        [] ->
            Lit (LNumber 0)


second : List Exp -> Exp
second list =
    case list of
        _ :: y :: _ ->
            y

        _ ->
            Lit (LNumber 0)


lowerArith : String -> List Exp -> Int -> S -> Result String S
lowerArith prim args dest s =
    -- DOMAIN: `+ - *` only (`lowerPrimApp` gates it, and the else-branch below
    -- — its integer arm — is only correct for those).  `f/` has its OWN branch
    -- there for exactly that reason.
    --
    -- S4f: both operands PROVEN Float -> the native f64 op (`Bin dst D op`
    -- prints `%r =d add`/`sub`/`mul`, i.e. QBE's addd/subd/muld), with neither
    -- the tag test nor the `rt_prim` call emitted.  The VM's primAdd/Sub/Mul
    -- take the f64 arm as soon as ONE operand is a Float, so with both
    -- operands proven `tagFloat` this is the same arithmetic the fast path
    -- used to reach through a call.
    if List.length args == 2 && List.all (isFloatExp s) args then
        rawFloatBin (arithOp prim) (first args) (second args) s
            |> Result.map (\( r, s1 ) -> reboxFloat dest r s1)

    else if List.length args == 2 && List.all (isIntExp s) args then
        -- S4: both operands PROVEN Int -> the native i64 op, with neither the tag
        -- test nor the `rt_prim` fallback emitted at all.  The VM's primAdd/Sub/Mul
        -- take the i64 wrapping path exactly when neither operand is a Float, so
        -- this is the same semantics minus the runtime test.  Any other operand
        -- pair (a Float anywhere, an unknown type, a non-2-ary app) keeps the whole
        -- existing shape.
        rawIntBin (arithOp prim) (first args) (second args) s
            |> Result.map (\( r, s1 ) -> reboxArg dest r s1)

    else
        lowerArgs2 args s
        |> Result.andThen
            (\( a1, a2, s1 ) ->
                let
                    ( ta, s2 ) =
                        freshTmp s1

                    ( tb, s3 ) =
                        freshTmp s2

                    ( fa, s4 ) =
                        freshTmp s3

                    ( fb, s5 ) =
                        freshTmp s4

                    ( o1, s6 ) =
                        freshTmp s5

                    ( o2, s7 ) =
                        freshTmp s6

                    ( anyf, s8 ) =
                        freshTmp s7

                    ( iLbl, s9 ) =
                        freshLbl "pinline" s8

                    ( fLbl, s10 ) =
                        freshLbl "pfb" s9

                    ( jLbl, s11 ) =
                        freshLbl "pjoin" s10

                    ( xa, s12 ) =
                        freshTmp s11

                    ( xb, s13 ) =
                        freshTmp s12

                    ( pa, s14 ) =
                        freshTmp s13

                    ( pb, s15 ) =
                        freshTmp s14

                    ( r, s16 ) =
                        freshTmp s15

                    ( d8, s17 ) =
                        freshTmp s16

                    op =
                        arithOp prim
                in
                Ok
                    (emit (Load (Just ta) W LoadW (Il.Tmp (slotTmp a1))) s17
                        |> emit (Load (Just tb) W LoadW (Il.Tmp (slotTmp a2)))
                        |> emit (Cmp (Just fa) W Ceq (Il.Tmp ta) (Il.Con tagFloat))
                        |> emit (Cmp (Just fb) W Ceq (Il.Tmp tb) (Il.Con tagFloat))
                        |> emit (Bin (Just o1) W Or (Il.Tmp fa) (Il.Tmp fb))
                        |> emit (Bin (Just o2) W Xor (Il.Con 1) (Il.Tmp o1))
                        |> emit (Cmp (Just anyf) W Ceq (Il.Tmp o2) (Il.Con 0))
                        |> closeBlock (Jnz (Il.Tmp anyf) fLbl iLbl)
                        |> startBlock iLbl
                        |> emit (Bin (Just pa) L Add (Il.Tmp (slotTmp a1)) (Il.Con 8))
                        |> emit (Load (Just xa) L LoadL (Il.Tmp pa))
                        |> emit (Bin (Just pb) L Add (Il.Tmp (slotTmp a2)) (Il.Con 8))
                        |> emit (Load (Just xb) L LoadL (Il.Tmp pb))
                        |> emit (Bin (Just r) L op (Il.Tmp xa) (Il.Tmp xb))
                        |> emit (Store StoreW (Il.Con tagNumber) (Il.Tmp (slotTmp dest)))
                        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
                        |> emit (Store StoreL (Il.Tmp r) (Il.Tmp d8))
                        |> jumpTo jLbl
                        |> startBlock fLbl
                    )
                    |> Result.andThen (\s18 -> rtPrimSlots prim [ a1, a2 ] dest s18)
                    |> Result.map (jumpTo jLbl)
                    |> Result.map (startBlock jLbl)
            )


lowerCompare : CmpOp -> List Exp -> Int -> S -> Result String S
lowerCompare op args dest s =
    -- S4f: both operands PROVEN Float -> ONE ordered IEEE compare, no tag test
    -- and no `rt_prim` call.  The VM's primLt/Le/Gt/Ge take the f64 arm as soon
    -- as one operand is a Float, and it is `asFloat a1 < asFloat a2` — the same
    -- answer QBE's `cltd`/`cled`/`cgtd`/`cged` give, NaN included (both are
    -- ordered: NaN compares false).
    if List.length args == 2 && List.all (isFloatExp s) args then
        rawFloat2 (first args) (second args) s
            |> Result.map
                (\( aa, bb, s1 ) ->
                    let
                        ( c, s2 ) =
                            freshTmp s1
                    in
                    reboxBoolean dest (Il.Tmp c) (emit (Cmp (Just c) D (floatCmpOp op) aa bb) s2)
                )

    else if List.length args == 2 && List.all (isIntExp s) args then
        -- S4: both operands PROVEN Int -> one i64 compare, no tag test, no
        -- `rt_prim` fallback.  The VM's primLt/Le/Gt/Ge return False whenever
        -- either operand is a Float, so the fast path (taken only when NEITHER
        -- is) is the same answer via the i64 route they already use internally.
        rawInt2 (first args) (second args) s
            |> Result.map
                (\( aa, bb, s1 ) ->
                    let
                        ( c, s2 ) =
                            freshTmp s1
                    in
                    reboxBoolean dest (Il.Tmp c) (emit (Cmp (Just c) L op aa bb) s2)
                )

    else if List.length args == 2 && List.all (isStrExp s) args then
        -- Char ordering: a Char is a 1-byte String at the VM (there is NO Char
        -- ValTag — Mid/FromAst lowers a Char literal to an LString), so a Char
        -- (or String) ordering operand is tagString.  Both operands PROVEN a
        -- string Value -> ONE byte-lexicographic compare, inline, no tag test
        -- and no `rt_prim` call.  The Rt.< family answers False for ANY
        -- non-number, which is the silent Char-ordering mislower this branch
        -- replaces.  Byte-lexicographic UTF-8 order IS code-point order, so
        -- this is real-Elm's Char/String ordering in the VM's byte model.
        lowerArgs2 args s
            |> Result.andThen (\( a1, a2, s1 ) -> lowerStrCmp op a1 a2 dest s1)

    else
        lowerArgs2 args s
        |> Result.andThen
            (\( a1, a2, s1 ) ->
                let
                    ( ta, s2 ) =
                        freshTmp s1

                    ( tb, s3 ) =
                        freshTmp s2

                    ( na, s4 ) =
                        freshTmp s3

                    ( fa, s5 ) =
                        freshTmp s4

                    ( numa, s6 ) =
                        freshTmp s5

                    ( nb, s7 ) =
                        freshTmp s6

                    ( fb, s8 ) =
                        freshTmp s7

                    ( numb, s9 ) =
                        freshTmp s8

                    ( num2, s10 ) =
                        freshTmp s9

                    ( anyf, s11 ) =
                        freshTmp s10

                    ( o1, s12 ) =
                        freshTmp s11

                    ( ok, s13 ) =
                        freshTmp s12

                    ( iLbl, s14 ) =
                        freshLbl "pinline" s13

                    ( fLbl, s15 ) =
                        freshLbl "pfb" s14

                    ( jLbl, s16 ) =
                        freshLbl "pjoin" s15

                    ( xa, s17 ) =
                        freshTmp s16

                    ( xb, s18 ) =
                        freshTmp s17

                    ( pa, s19 ) =
                        freshTmp s18

                    ( pb, s20 ) =
                        freshTmp s19

                    ( c, s21 ) =
                        freshTmp s20

                    ( d8, s22 ) =
                        freshTmp s21
                in
                Ok
                    (emit (Load (Just ta) W LoadW (Il.Tmp (slotTmp a1))) s22
                        |> emit (Load (Just tb) W LoadW (Il.Tmp (slotTmp a2)))
                        |> emit (Cmp (Just na) W Ceq (Il.Tmp ta) (Il.Con tagNumber))
                        |> emit (Cmp (Just fa) W Ceq (Il.Tmp ta) (Il.Con tagFloat))
                        |> emit (Bin (Just numa) W Or (Il.Tmp na) (Il.Tmp fa))
                        |> emit (Cmp (Just nb) W Ceq (Il.Tmp tb) (Il.Con tagNumber))
                        |> emit (Cmp (Just fb) W Ceq (Il.Tmp tb) (Il.Con tagFloat))
                        |> emit (Bin (Just numb) W Or (Il.Tmp nb) (Il.Tmp fb))
                        |> emit (Bin (Just num2) W And (Il.Tmp numa) (Il.Tmp numb))
                        |> emit (Bin (Just anyf) W Or (Il.Tmp fa) (Il.Tmp fb))
                        |> emit (Bin (Just o1) W Xor (Il.Con 1) (Il.Tmp anyf))
                        |> emit (Bin (Just ok) W And (Il.Tmp num2) (Il.Tmp o1))
                        |> closeBlock (Jnz (Il.Tmp ok) iLbl fLbl)
                        |> startBlock iLbl
                        |> emit (Bin (Just pa) L Add (Il.Tmp (slotTmp a1)) (Il.Con 8))
                        |> emit (Load (Just xa) L LoadL (Il.Tmp pa))
                        |> emit (Bin (Just pb) L Add (Il.Tmp (slotTmp a2)) (Il.Con 8))
                        |> emit (Load (Just xb) L LoadL (Il.Tmp pb))
                        |> emit (Cmp (Just c) L op (Il.Tmp xa) (Il.Tmp xb))
                        |> emit (Store StoreW (Il.Con tagBoolean) (Il.Tmp (slotTmp dest)))
                        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
                        |> emit (Store StoreW (Il.Tmp c) (Il.Tmp d8))
                        |> jumpTo jLbl
                        |> startBlock fLbl
                    )
                    |> Result.andThen (\s23 -> rtPrimSlots (cmpName op) [ a1, a2 ] dest s23)
                    |> Result.map (jumpTo jLbl)
                    |> Result.map (startBlock jLbl)
            )


cmpName : CmpOp -> String
cmpName op =
    case op of
        Cslt ->
            "<"

        Csle ->
            "<="

        Csgt ->
            ">"

        _ ->
            ">="


{-| The `isStrExp` (both-operands-PROVEN-string) branch of `lowerCompare`:
byte-lexicographic ordering of two String VALUES (a Char is a 1-byte String in
this VM, so this is also Char ordering — and byte-lexicographic UTF-8 order IS
code-point order).  `<=`/`>=` are `not (b<a)`/`not (a<b)`, `>` is `b<a`, so ONE
`lowerStrLess` computation covers all four operators.  Emitted inline (the Rt
defuns are out of this module's budget, and there is no string-compare prim to
route through).  The comparison loop keeps its index AND its result in stack
slots (not SSA temps) because this IL has no phi nodes: a loop-carried value
must live in memory.
-}
lowerStrCmp : CmpOp -> Int -> Int -> Int -> S -> Result String S
lowerStrCmp op aSlot bSlot dest s =
    let
        ( x, y ) =
            case op of
                Cslt ->
                    ( aSlot, bSlot )

                Csle ->
                    -- a <= b  ==  not (b < a)
                    ( bSlot, aSlot )

                Csgt ->
                    -- a > b  ==  b < a
                    ( bSlot, aSlot )

                _ ->
                    -- a >= b  ==  not (a < b)
                    ( aSlot, bSlot )

        neg =
            op == Csle || op == Csge
    in
    lowerStrLess x y s
        |> Result.map
            (\( resT, s1 ) ->
                if neg then
                    let
                        ( rT, s2 ) =
                            freshTmp s1
                    in
                    reboxBoolean dest (Il.Tmp rT) (emit (Bin (Just rT) W Xor (Il.Con 1) (Il.Tmp resT)) s2)

                else
                    reboxBoolean dest (Il.Tmp resT) s1
            )


{-| Byte-lexicographic `x < y` of two String VALUES held in slots `xSlot`/`ySlot`.
Returns the name of the `w` temp holding 0/1, with the current block left at the
comparison's join label (started, OPEN) so the caller can negate/rebox into it.
The read is bounded: the loop body runs only while `i < lenX && i < lenY`, so
`loadub (data + i)` never reads past either string's bytes.
-}
lowerStrLess : Int -> Int -> S -> Result String ( String, S )
lowerStrLess xSlot ySlot s =
    let
        ( dxT, s0 ) =
            freshTmp s

        ( dyT, s1 ) =
            freshTmp s0

        ( lxw, s2 ) =
            freshTmp s1

        ( lyw, s3 ) =
            freshTmp s2

        ( lxT, s4 ) =
            freshTmp s3

        ( lyT, s5 ) =
            freshTmp s4

        ( idxSlot, s6 ) =
            freshSlot s5

        ( resSlot, s7 ) =
            freshSlot s6

        ( loopLbl, s8 ) =
            freshLbl "strloop" s7

        ( bodyLbl, s9 ) =
            freshLbl "strbody" s8

        ( nextLbl, s10 ) =
            freshLbl "strnext" s9

        ( diffLbl, s11 ) =
            freshLbl "strdiff" s10

        ( tieLbl, s12 ) =
            freshLbl "strtie" s11

        ( joinLbl, s13 ) =
            freshLbl "strjoin" s12

        ( iT, s14 ) =
            freshTmp s13

        ( geX, s15 ) =
            freshTmp s14

        ( geY, s16 ) =
            freshTmp s15

        ( doneT, s17 ) =
            freshTmp s16

        ( axT, s18 ) =
            freshTmp s17

        ( baT, s19 ) =
            freshTmp s18

        ( bxT, s20 ) =
            freshTmp s19

        ( bbT, s21 ) =
            freshTmp s20

        ( neT, s22 ) =
            freshTmp s21

        ( i1T, s23 ) =
            freshTmp s22

        ( ltDiff, s24 ) =
            freshTmp s23

        ( ltTie, s25 ) =
            freshTmp s24

        ( resT, s26 ) =
            freshTmp s25

        ( x8, s27 ) =
            freshTmp s26

        ( y8, s28 ) =
            freshTmp s27

        ( x16, s29 ) =
            freshTmp s28

        ( y16, s30 ) =
            freshTmp s29
    in
    Ok
        ( resT
        , emit (Bin (Just x8) L Add (Il.Tmp (slotTmp xSlot)) (Il.Con 8)) s30
            |> emit (Load (Just dxT) L LoadL (Il.Tmp x8))
            |> emit (Bin (Just y8) L Add (Il.Tmp (slotTmp ySlot)) (Il.Con 8))
            |> emit (Load (Just dyT) L LoadL (Il.Tmp y8))
            |> emit (Bin (Just x16) L Add (Il.Tmp (slotTmp xSlot)) (Il.Con 16))
            |> emit (Load (Just lxw) W LoadW (Il.Tmp x16))
            |> emit (Unary (Just lxT) L Extsw (Il.Tmp lxw))
            |> emit (Bin (Just y16) L Add (Il.Tmp (slotTmp ySlot)) (Il.Con 16))
            |> emit (Load (Just lyw) W LoadW (Il.Tmp y16))
            |> emit (Unary (Just lyT) L Extsw (Il.Tmp lyw))
            |> emit (Store StoreL (Il.Con 0) (Il.Tmp (slotTmp idxSlot)))
            |> closeBlock (Jmp loopLbl)
            |> startBlock loopLbl
            |> emit (Load (Just iT) L LoadL (Il.Tmp (slotTmp idxSlot)))
            |> emit (Cmp (Just geX) L Csle (Il.Tmp lxT) (Il.Tmp iT))
            |> emit (Cmp (Just geY) L Csle (Il.Tmp lyT) (Il.Tmp iT))
            |> emit (Bin (Just doneT) W Or (Il.Tmp geX) (Il.Tmp geY))
            |> closeBlock (Jnz (Il.Tmp doneT) tieLbl bodyLbl)
            |> startBlock bodyLbl
            |> emit (Bin (Just axT) L Add (Il.Tmp dxT) (Il.Tmp iT))
            |> emit (Load (Just baT) W LoadUb (Il.Tmp axT))
            |> emit (Bin (Just bxT) L Add (Il.Tmp dyT) (Il.Tmp iT))
            |> emit (Load (Just bbT) W LoadUb (Il.Tmp bxT))
            |> emit (Cmp (Just neT) W Cne (Il.Tmp baT) (Il.Tmp bbT))
            |> closeBlock (Jnz (Il.Tmp neT) diffLbl nextLbl)
            |> startBlock nextLbl
            |> emit (Bin (Just i1T) L Add (Il.Tmp iT) (Il.Con 1))
            |> emit (Store StoreL (Il.Tmp i1T) (Il.Tmp (slotTmp idxSlot)))
            |> jumpTo loopLbl
            |> startBlock diffLbl
            |> emit (Cmp (Just ltDiff) W Cslt (Il.Tmp baT) (Il.Tmp bbT))
            |> emit (Store StoreW (Il.Tmp ltDiff) (Il.Tmp (slotTmp resSlot)))
            |> jumpTo joinLbl
            |> startBlock tieLbl
            |> emit (Cmp (Just ltTie) L Cslt (Il.Tmp lxT) (Il.Tmp lyT))
            |> emit (Store StoreW (Il.Tmp ltTie) (Il.Tmp (slotTmp resSlot)))
            |> jumpTo joinLbl
            |> startBlock joinLbl
            |> emit (Load (Just resT) W LoadW (Il.Tmp (slotTmp resSlot)))
        )


lowerNumEq : List Exp -> Int -> S -> Result String S
lowerNumEq args dest s =
    -- S4f: both operands PROVEN Float -> one ordered f64 equality.  primEq on
    -- two floats is `asFloat a1 == asFloat a2` (IEEE: NaN != NaN, -0.0 == 0.0)
    -- and QBE's `ceqd` is the same compare.
    if List.length args == 2 && List.all (isFloatExp s) args then
        rawFloat2 (first args) (second args) s
            |> Result.map
                (\( aa, bb, s1 ) ->
                    let
                        ( c, s2 ) =
                            freshTmp s1
                    in
                    reboxBoolean dest (Il.Tmp c) (emit (Cmp (Just c) D Ceqd aa bb) s2)
                )

    else if List.length args == 2 && List.all (isIntExp s) args then
        -- S4: both operands PROVEN Int -> a single i64 payload compare.  primEq's
        -- number/number arm compares payloads, and two Ints are both
        -- `tagNumber`-tagged, so the tag loads and the branch are redundant.
        rawInt2 (first args) (second args) s
            |> Result.map
                (\( aa, bb, s1 ) ->
                    let
                        ( c, s2 ) =
                            freshTmp s1
                    in
                    reboxBoolean dest (Il.Tmp c) (emit (Cmp (Just c) L Ceq aa bb) s2)
                )

    else
        lowerArgs2 args s
        |> Result.andThen
            (\( a1, a2, s1 ) ->
                let
                    ( ta, s2 ) =
                        freshTmp s1

                    ( tb, s3 ) =
                        freshTmp s2

                    ( na, s4 ) =
                        freshTmp s3

                    ( nb, s5 ) =
                        freshTmp s4

                    ( ok, s6 ) =
                        freshTmp s5

                    ( iLbl, s7 ) =
                        freshLbl "pinline" s6

                    ( fLbl, s8 ) =
                        freshLbl "pfb" s7

                    ( jLbl, s9 ) =
                        freshLbl "pjoin" s8

                    ( xa, s10 ) =
                        freshTmp s9

                    ( xb, s11 ) =
                        freshTmp s10

                    ( pa, s12 ) =
                        freshTmp s11

                    ( pb, s13 ) =
                        freshTmp s12

                    ( c, s14 ) =
                        freshTmp s13

                    ( d8, s15 ) =
                        freshTmp s14
                in
                Ok
                    (emit (Load (Just ta) W LoadW (Il.Tmp (slotTmp a1))) s15
                        |> emit (Load (Just tb) W LoadW (Il.Tmp (slotTmp a2)))
                        |> emit (Cmp (Just na) W Ceq (Il.Tmp ta) (Il.Con tagNumber))
                        |> emit (Cmp (Just nb) W Ceq (Il.Tmp tb) (Il.Con tagNumber))
                        |> emit (Bin (Just ok) W And (Il.Tmp na) (Il.Tmp nb))
                        |> closeBlock (Jnz (Il.Tmp ok) iLbl fLbl)
                        |> startBlock iLbl
                        |> emit (Bin (Just pa) L Add (Il.Tmp (slotTmp a1)) (Il.Con 8))
                        |> emit (Load (Just xa) L LoadL (Il.Tmp pa))
                        |> emit (Bin (Just pb) L Add (Il.Tmp (slotTmp a2)) (Il.Con 8))
                        |> emit (Load (Just xb) L LoadL (Il.Tmp pb))
                        |> emit (Cmp (Just c) L Ceq (Il.Tmp xa) (Il.Tmp xb))
                        |> emit (Store StoreW (Il.Con tagBoolean) (Il.Tmp (slotTmp dest)))
                        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
                        |> emit (Store StoreW (Il.Tmp c) (Il.Tmp d8))
                        |> jumpTo jLbl
                        |> startBlock fLbl
                    )
                    |> Result.andThen (\s16 -> rtPrimSlots "=" [ a1, a2 ] dest s16)
                    |> Result.map (jumpTo jLbl)
                    |> Result.map (startBlock jLbl)
            )


-- rt_prim(name, argsBlock, nargs): the exact VM primitive, value-stack and
-- all (rt pushes the args REVERSED so the first pop is args[0] — the same
-- order the ZINC emitter's RTL pushes produce).  STAGES FROM SLOTS: the args
-- were lowered once, into rooted frame slots; re-lowering an expression here
-- would duplicate calls and mis-order effects.
--
-- PASS A (QBE_NOPRIMDIRECT=1 disables it): when the prim is one of the
-- runtime's table entries and the arity is 1..3, emit the DIRECT per-prim C
-- entry instead of the name-dispatched generic one —
--
--   %r =:val call $rt_prim_<mangled>(l %sA, l %sB, l %sC, w n)
--
-- with one `l` argument per staged slot padded to the runtime's uniform
-- 3-pointer ABI (the padding is passed, never read — see tools/qbe/rt.zig
-- Direct).  THE DIRECT FORM NEVER VARIES WITH ARITY: `n` is the count the
-- generic call would have passed, so the callee hands the handler exactly the
-- stack it would have got from `rt_prim` — the arity is the CALL SITE's, as
-- before, and there is no second arity table anywhere to drift from
-- prims.zig's.
--
-- WHAT IT DELETES, per call: the name-dispatch (std.mem.span + strlen + the
-- StaticStringMap hash), the vaInit `allocArray(Value, 12)` 480-byte GC array
-- and its ROOT_PTR slot, and the per-arg vaPush (each with an
-- inOldgen + valueReferencesNursery write-barrier scan); plus, at the call
-- site, the n-slot contiguous staging block stageSlots emits (2n
-- instructions).  MEASURED share of this mechanism: 48-54% of wall on the
-- five slowest suite programs (osier-midpasses plan).
--
-- FALLBACKS (the generic path is PRESERVED, unchanged): arity 0 (the C ABI
-- cannot express "no argument pointers"), arity > 3 (beyond the runtime's
-- direct_arity; no table prim is), and any name the runtime has no direct
-- entry for — which now fails at LINK time with the exact undefined symbol,
-- loudly, instead of at run time through unknownPrim.
rtPrimSlots : String -> List Int -> Int -> S -> Result String S
rtPrimSlots prim slots dest s =
    -- THE MID ROUTE (osier-consspike; THE FLIP, osier-flip step 6): when the
    -- prim has a Mid implementation AND its Rt defun was injected, the staged
    -- slots call the Rt DEFUN.  THE FLIP MADE THIS THE DEFAULT (run.js: the
    -- Mid route unless QBE_MIDZIG=1 selects the old Zig path for a bisect);
    -- QBE_MIDZIG=1 is emit-only on this tree (its .ssa references rt_prim_*
    -- symbols rt.o no longer defines — a loud link failure, never a silent
    -- fallback).
    --
    -- THE LEAN ABI (osier-midabi): the call is the EXACT SHAPE pass A
    -- established against the Zig wrappers (rtPrimSlotsZig below) — 3
    -- POINTER args padded with the last real slot's address, plus the count
    -- word, DIRECT :val return, one blit to dest — with the Rt defun's q_
    -- symbol in place of rt_prim_*.  No :val by-value argument copies, no
    -- 80-byte :ret staging, no rt_bounce call.  The args are already in the
    -- CALLER's ROOTED frame slots, which is precisely what the callee's
    -- pointer params read (a lean callee's prologue blits them before its
    -- first safepoint, and a frame-free callee has none).  QBE_NORTLEAN=1
    -- restores the fat generic-ABI emission for a bisect.
    case ( s.midCons, midPrimRoute prim slots s ) of
        ( True, Ok (Just key) ) ->
            if s.rtLean then
                if List.length slots >= 1 && List.length slots <= maxDirectArity then
                    let
                        ( vp, s1 ) =
                            freshTmp s

                        ptrs =
                            List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots

                        pad =
                            ArgVal (Base L) (Il.Tmp (slotTmp (lastSlot slots)))

                        padded =
                            ptrs ++ List.repeat (maxDirectArity - List.length ptrs) pad
                    in
                    Ok
                        (emit
                            (Call (Just vp)
                                (Agg "val")
                                (Il.Sym ("q_" ++ mangle key))
                                (padded ++ [ ArgVal (Base W) (Il.Con (List.length slots)) ])
                            )
                            s1
                            |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                        )

                else
                    Err ("qbe: prim " ++ prim ++ " stages arity " ++ String.fromInt (List.length slots) ++ " — the lean ABI passes 1.." ++ String.fromInt maxDirectArity ++ " pointer args (A's direct_arity bound)")

            else
                let
                    ( rp, s1 ) =
                        freshTmp s

                    ( vp, s2 ) =
                        freshTmp s1
                in
                Ok
                    (emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle key)) (List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots)) s2
                        |> emit (Call (Just vp) (Agg "val") (Il.Sym (bounceSeat s)) [ ArgVal (Base L) (Il.Tmp rp) ])
                        |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                    )

        ( True, Err msg ) ->
            Err msg

        _ ->
            rtPrimSlotsZig prim slots dest s


-- The Rt defun key to route `prim` through, if it has one:
-- the prim must HAVE a Mid implementation, the STAGED ARITY must be that
-- implementation's (read from Mid.Rt.impls, not hardcoded — step 5's
-- hand-off: a literal arity silently mis-handles every non-binary prim,
-- e.g. empty? 1, substring 3, absvector 1), and that defun must be present
-- in this compile (injected — QBE_NOMIDRT=1 removes it and the route falls
-- back to the Zig entry; POST-FLIP that fallback is EMIT-ONLY, because the
-- flip deleted the flipped prims' Zig handlers — the emitted rt_prim_* call
-- fails at LINK time, loudly, rather than reaching an absent function).
--
-- THE SEED GUARD (step-5 review): when the defun IS injected but is NOT in
-- the set this compile will EMIT (s.seeded, from used-prim seeding), the call
-- this seat is about to make could never resolve — that is exactly a census
-- miss (calledPrims did not report a prim the lowering stages), and it must
-- FAIL THE COMPILE naming the prim rather than reach the linker as an
-- undefined `q_Rt_*`.  A census miss is otherwise invisible on every default
-- (Zig-route) oracle and only shows up as a link error on the Mid route; six
-- such seats were found by reading after step 5 landed.
midPrimRoute : String -> List Int -> S -> Result String (Maybe String)
midPrimRoute prim slots s =
    case MidRt.primImpl prim of
        Just impl ->
            if List.length slots /= impl.arity then
                Ok Nothing

            else if not (Dict.member impl.key s.defuns) then
                Ok Nothing

            else if Set.member impl.key s.seeded then
                Ok (Just impl.key)

            else
                Err
                    ("qbe: the prim \""
                        ++ prim
                        ++ "\" has a Mid implementation ("
                        ++ impl.key
                        ++ ") and that defun is injected, but the used-prim census (calledPrims) does not report the prim as called — so "
                        ++ impl.key
                        ++ " would never be emitted and this call would not link. Add the missing census arm in Mid.Qbe.Lower (see calledPrims' doc comment)."
                    )

        Nothing ->
            Ok Nothing


rtPrimSlotsZig : String -> List Int -> Int -> S -> Result String S
rtPrimSlotsZig prim slots dest s =
    if s.primDirect && List.length slots >= 1 && List.length slots <= maxDirectArity then
        let
            ( rp, s1 ) =
                freshTmp s

            -- The uniform ABI is 3 pointers: pass the staged slots and pad
            -- with the last one.  Padding is never read by the wrapper.
            ptrs =
                List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots

            pad =
                ArgVal (Base L) (Il.Tmp (slotTmp (lastSlot slots)))

            padded =
                ptrs ++ List.repeat (maxDirectArity - List.length ptrs) pad
        in
        Ok
            (emit
                (Call (Just rp)
                    (Agg "val")
                    (Il.Sym ("rt_prim_" ++ manglePrim prim))
                    (padded ++ [ ArgVal (Base W) (Il.Con (List.length slots)) ])
                )
                s1
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
            )

    else
        let
            ( pnm, s0 ) =
                freshData ("pnm:" ++ prim)
                    (\n -> { name = n, align = Just 8, items = [ DStr prim, DByte 0 ], export_ = False })
                    s

            ( _, base, s1 ) =
                stageSlots slots s0

            ( rp, s2 ) =
                freshTmp s1
        in
        Ok
            (emit
                (Call (Just rp)
                    (Agg "val")
                    (Il.Sym "rt_prim")
                    [ ArgVal (Base L) (Il.Sym pnm)
                    , ArgVal (Base L) (Il.Tmp (slotTmp base))
                    , ArgVal (Base W) (Il.Con (List.length slots))
                    ]
                )
                s2
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
            )


-- The 3-pointer ABI's padding value: the LAST staged slot, reused.  Never
-- read by the wrapper (it only touches the first `nargs`), but it must be a
-- DEFINED `l` operand or the .ssa is malformed.  Only ever called with a
-- non-empty list — the direct branch requires at least one slot.
lastSlot : List Int -> Int
lastSlot slots =
    case slots of
        [] ->
            0

        [ x ] ->
            x

        _ :: rest ->
            lastSlot rest


-- The runtime's uniform direct-entry ABI width (tools/qbe/rt.zig
-- `direct_arity`).  A call site with more staged slots than this keeps the
-- generic route; no prim in the runtime's table is wider.
maxDirectArity : Int
maxDirectArity =
    3


-- Prim name -> the C symbol suffix of its direct entry.  REUSES `mangle`
-- below (the QBE-identifier mangler the defun keys already go through:
-- [a-zA-Z0-9] pass through, every other BYTE becomes `_xHH` at a fixed two
-- digits) — one mangler, one injective mapping, no second convention to keep
-- in step.  tools/qbe/rt.zig's `symChar`/`symSuffix` implement the SAME
-- function over the same table names (all 58 are ASCII, so Elm's codepoint
-- walk and Zig's byte walk agree); the two sides are held together by the
-- LINKER — a disagreement is an undefined symbol, never a silent
-- mis-dispatch.
manglePrim : String -> String
manglePrim prim =
    mangle prim


-- ============================ CLOSURES ============================
-- An inner Lam compiles to its own QBE function (env = captures array) plus,
-- at the creation site, contiguous staging of the captured values and one
-- rt_make_closure(desc, capBase, K).  Capture order is ASCENDING BINDER ID
-- (ids are unique per Defun, so the order is deterministic and stable).


lowerClosure : Lambda -> Int -> S -> Result String S
lowerClosure lambda dest s =
    freeVars lambda
        |> Result.andThen
            (\caps ->
                let
                    captures =
                        Set.toList caps

                    k =
                        List.length captures

                    ( cbase, s1 ) =
                        freshSlots k s

                    qname =
                        "clo" ++ String.fromInt s.cloN ++ "_" ++ mangle s.defunKey

                    ( descName, s2 ) =
                        freshData ("desc:" ++ qname)
                            (\n ->
                                { name = n
                                , align = Just 8
                                , items =
                                    [ DRef qname
                                    , DWord (List.length lambda.params)
                                    , DWord k
                                    , DZero (RtLayout.descTotalBytes - RtLayout.descCacheOffset)
                                    ]
                                , export_ = False
                                }
                            )
                            s1
                in
                if List.length lambda.params > maxArity then
                    Err ("qbe: closure has arity > " ++ String.fromInt maxArity ++ " (rt_callN table limit)")

                else
                    lowerFunBody False s1.defunKey qname lambda captures RtGeneric s2
                        |> Result.andThen
                            (\( pending, sInner ) ->
                                -- blit each capture's CURRENT slot into its
                                -- staging slot (contiguous, so the staging
                                -- base is one pointer)
                                captureBlits captures cbase s2
                                    |> Result.andThen
                                        (\s3 ->
                                            let
                                                ( rp, s4 ) =
                                                    freshTmp s3
                                            in
                                            Ok
                                                -- The Mid route: the closure goes through the Mid
                                                -- defun Rt.closure (desc, capBase, K) — the env array
                                                -- is Rt.allocVector (the Mid collector), so the
                                                -- closure's captures land in the MID heap (no
                                                -- cross-heap edge).  desc/capBase/K are boxed as number
                                                -- Values in fresh slots (the lean ABI passes POINTERS to
                                                -- Value slots + a count word).
                                                (let
                                                    ( descSlot, sA ) =
                                                        freshSlot s4

                                                    ( capBaseSlot, sB ) =
                                                        freshSlot sA

                                                    ( kSlot, sC ) =
                                                        freshSlot sB

                                                    sD =
                                                        storeValueCell tagNumber [ Il.Sym descName ] descSlot sC

                                                    sE =
                                                        storeValueCell tagNumber
                                                            [ if k == 0 then
                                                                Il.Con 0

                                                              else
                                                                Il.Tmp (slotTmp cbase)
                                                            ]
                                                            capBaseSlot
                                                            sD

                                                    sF =
                                                        storeValueCell tagNumber [ Il.Con k ] kSlot sE
                                                in
                                                emit
                                                    (Call (Just rp)
                                                        (Agg "val")
                                                        (Il.Sym ("q_" ++ mangle "Rt.closure"))
                                                        [ ArgVal (Base L) (Il.Tmp (slotTmp descSlot))
                                                        , ArgVal (Base L) (Il.Tmp (slotTmp capBaseSlot))
                                                        , ArgVal (Base L) (Il.Tmp (slotTmp kSlot))
                                                        , ArgVal (Base W) (Il.Con 3)
                                                        ]
                                                    )
                                                    sF
                                                    |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
                                                    |> mergeClosureResult pending sInner
                                                )
                                        )
                            )
            )


captureBlits : List Int -> Int -> S -> Result String S
captureBlits captures cbase s =
    List.foldl
        (\( cid, i ) acc ->
            acc
                |> Result.andThen
                    (\s1 ->
                        -- S4: a RAW binder captured by the closure is REBOXED
                        -- into its contiguous capture slot — the same boundary
                        -- rule as everywhere else.  Only after that does the
                        -- ordinary slot-to-slot blit apply.
                        case Dict.get cid s1.rawInt of
                            Just raw ->
                                Ok (reboxArg (cbase + i) raw s1)

                            Nothing ->
                                case Dict.get cid s1.rawFloat of
                                    Just raw ->
                                        Ok (reboxFloat (cbase + i) raw s1)

                                    Nothing ->
                                        case valueBaseOf cid s1 of
                                            Just src ->
                                                Ok (emit (Blit src (Il.Tmp (slotTmp (cbase + i))) vs) s1)

                                            Nothing ->
                                                Err ("qbe: capture not in scope (corrupt Mid tree): binder " ++ String.fromInt cid)
                    )
        )
        (Ok s)
        (List.indexedMap (\i cid -> ( cid, i )) captures)


freshSlots : Int -> S -> ( Int, S )
freshSlots n s =
    ( s.slot, { s | slot = s.slot + n } )


-- Free binder ids of a Lam (its params excluded, binders bound INSIDE
-- excluded).  Mid binder ids are unique per Defun, so there is no shadowing
-- to model: subtract exactly the binders this subtree introduces.
freeVars : Lambda -> Result String (Set Int)
freeVars lambda =
    fvExp lambda.body
        |> Result.map (\s -> Set.diff s (Set.fromList (List.map .id lambda.params)))


fvExp : Exp -> Result String (Set Int)
fvExp exp =
    case exp of
        Lit _ ->
            Ok Set.empty

        Var id ->
            Ok (Set.singleton id)

        GRef _ ->
            Ok Set.empty

        StreamRef _ ->
            Ok Set.empty

        Lam lambda ->
            freeVars lambda

        NoTail inner ->
            fvExp inner

        App app ->
            setsUnion (fvExp app.fn :: List.map fvExp app.args)

        PrimApp app ->
            setsUnion (List.map fvExp app.args)

        Let block ->
            let
                binderIds =
                    Set.fromList
                        (List.concatMap
                            (\b ->
                                case b of
                                    LetBind bind ->
                                        [ bind.binder.id ]

                                    LetDestruct d ->
                                        d.scrutId.id :: List.map (\p -> (Tuple.first p).id) d.binds
                            )
                            block.binders
                        )

                inner =
                    Result.map2 Set.union
                        (setsUnion (List.map fvExp (letValues block.binders)))
                        (fvExp block.body)
            in
            Result.map (\s -> Set.diff s binderIds) inner

        If block ->
            setsUnion (List.map fvExp [ block.cond, block.thenBranch, block.elseBranch ])

        ShortAnd block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        ShortOr block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        NotEqual block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        Loop block ->
            setsUnion (List.map fvExp [ block.cond, block.body ])

        Break ->
            Ok Set.empty

        Continue ->
            Ok Set.empty

        Case branch ->
            let
                boundIds =
                    Set.fromList
                        (branch.scrutId.id
                            :: List.concatMap
                                (\a -> List.map (\p -> (Tuple.first p).id) a.binds)
                                branch.alts
                        )
            in
            Result.map (\s -> Set.diff s boundIds)
                (setsUnion (fvExp branch.scrutinee :: List.map (\a -> fvExp a.body) branch.alts))

        Con con ->
            setsUnion (List.map fvExp con.args)

        Tup es ->
            setsUnion (List.map fvExp es)

        RecordLit setters ->
            setsUnion (List.map (\p -> fvExp (Tuple.second p)) setters)

        RecordGet rec _ ->
            fvExp rec

        RecordUpdate update ->
            setsUnion (List.map fvExp (update.base :: List.map Tuple.second update.updates))

        ListLit es ->
            setsUnion (List.map fvExp es)

        -- Unsafe (osier-rawnodes / osier-consspike): free-variable computation
        -- over a raw body is NOT sound to approximate — a raw node's args
        -- reference binders, and closure capture built on an
        -- under-approximation is a silent miscompile.  Loud Err instead.
        -- DECIDED by the spike: Rt defuns are TOP-LEVEL Lams (the lowerDefun
        -- path — this walker never sees their bodies), and Rt bodies close
        -- over nothing (every Rt defun's inputs are its params); a future Rt
        -- defun wanting an inner closure hits this loud seat and must decide.
        Unsafe _ ->
            Err "qbe: freeVars over an unsafe node — closure capture of raw bodies is not supported (Rt defuns are top-level by construction; osier-consspike)"


setsUnion : List (Result String (Set Int)) -> Result String (Set Int)
setsUnion results =
    List.foldl
        (\r acc -> Result.map2 Set.union acc r)
        (Ok Set.empty)
        results


-- THE MID-OWNED GLOBALS BLOCK (stage 6 U1c, plan correction C3): the
-- mutable state Mid cannot keep in a frame lives in one `export data
-- $rt_glob = { z N }` — .bss, WRITABLE (`vendor/qbe/emit.c:92`) — addressed
-- through this 0-arg accessor whose body is `ret $rt_glob` (a global symbol
-- IS a legal `l` ret operand — MEASURED: the /tmp probe assembles and runs,
-- the address is a link-time constant).  RtGc's slots go through the
-- EXISTING RawCallRaw (callW emits the symbol verbatim, word->word — the
-- same ABI the deleted `rt_midgc_region`/`rt_midgc_set_region` Zig seats
-- had) + RawWordLoad/RawWordStore.  UNCONDITIONAL since Z0 (it was gated on
-- the collector hatch, whose route was the only non-Mid one): both defs are
-- emitted on every compile.  The layout table (what each slot is
-- FOR) is Mid.RtGc's GLOBALS BLOCK section.
globBlockData : DataDef
globBlockData =
    { name = RtGc.globDataSym
    , align = Just 8
    , items = [ DZero (8 * RtGc.globWords) ]
    , export_ = True
    }


globBlockFunc : Func
globBlockFunc =
    { name = RtGc.globAddrSym
    , export_ = True
    , ret = Base L
    , envParam = False
    , params = []
    , blocks =
        [ { label = "start"
          , body = []
          , jump = Ret (Just (Il.Sym RtGc.globDataSym))
          }
        ]
    }


-- ============================ FINISH ============================
-- Assemble the final Module: inject each function's prologue into @start
-- (frame size is known only after the body walk), add the global Descs, the
-- rt_callN dispatchers (rt_apply calls through this table by static arity),
-- and the driver's meta table (name -> {code, arity} per top-level defun).


finishModule : S -> List String -> Il.Module
finishModule s keys =
    let
        pendings =
            List.reverse s.funcs

        funcs =
            List.map withPrologue pendings
                ++ (globBlockFunc :: rtCallFuncs)
                -- stage 6 P1d Step B: the two-range apply bridge.  B4 closed
                -- the hatch (the Mid route is the only route), so it is
                -- unconditional.
                ++ [ rtCallTwoRange ]

        -- Rt.* defuns (osier-consspike) are INTERNAL: no global Desc (only a
        -- GRef'd defun needs one, and surface code cannot GRef an Rt key), no
        -- meta-table row (the driver's entry table is the SURFACE program's
        -- callable surface — Rt defuns are called by emitted call sites, not
        -- by name from the command line).
        surfaceKeys =
            List.filter (\k -> not (isRtKey k)) keys

        globalDescs =
            List.filterMap
                (\key ->
                    case Dict.get key s.defuns of
                        Just defun ->
                            case defun.value of
                                Lam lambda ->
                                    Just
                                        { name = globalDescName key
                                        , align = Just RtLayout.abiAlign
                                        , items =
                                            [ DRef ("q_" ++ mangle key)
                                            , DWord (List.length lambda.params)
                                            , DWord 0
                                            , DZero (RtLayout.descTotalBytes - RtLayout.descCacheOffset)
                                            ]
                                        , export_ = False
                                        }

                                _ ->
                                    Nothing

                        Nothing ->
                            Nothing
                )
                surfaceKeys

        ( metaDatas, metaFuncs ) =
            metaTable (List.filter (\p -> surfaceEntry p.entryKey) pendings)
    in
    { types = []
    , datas =
        List.reverse s.datas
            ++ globalDescs
            ++ metaDatas
            -- stage 6 B0: the frame machinery's freelist/frame_top globals.
            -- B4 closed the hatch, so the block is unconditional (the Mid
            -- frame pair always reads rt_glob).
            ++ [ globBlockData ]
    , funcs = funcs ++ metaFuncs
    }


-- A pending's entry key names a SURFACE defun (Rt.* entries are internal —
-- see finishModule's Rt filter).
surfaceEntry : Maybe String -> Bool
surfaceEntry mkey =
    case mkey of
        Just k ->
            not (isRtKey k)

        Nothing ->
            True


-- @start gets: %f =l call rt_frame_enter(w F); one %s<i> per slot; param
-- blits from the %a<i> pointers; capture blits from the %env array.
withPrologue : PendingFunc -> Func
withPrologue pending =
    let
        f =
            pending.func

        slotDefs =
            List.map
                (\i ->
                    Bin (Just (slotTmp i)) L Add (Il.Tmp "f") (Il.Con (vs * i))
                )
                (List.range 0 (pending.nslots - 1))

        -- B6 — THE STRUCT-PARAMETER ENTRY COPY.  A struct VALUE parameter
        -- crosses as `width` consecutive `l` words (the caller passes the
        -- struct's address and its layout is the defun's own signature, so
        -- the callee is the only side that needs the width).  One `allocN`
        -- stack block per such parameter, then one store per word: after the
        -- prologue the parameter IS its storage — an ordinary struct value —
        -- so `x.f`, `x.f = e`, `&x` and a struct-typed copy all work through
        -- the rules that already exist, and the callee's writes reach only its
        -- OWN copy (C's by-value semantics).
        --
        -- MEASURED LIMIT (stated, not hidden): this is a copy at the callee's
        -- entry, not the plan's lazy register form (`x.f` reading the field's
        -- own register, `&x` triggering the spill).  The register form needs
        -- the field's register to be addressable and a way to name "field k of
        -- a register tuple", which no Ir node can spell — and it would make a
        -- field STORE through the parameter ill-defined (registers are not
        -- storage).  The entry copy is the same information, no new node, and
        -- it keeps the whole struct-value rule set (read, store, `&x`, copy)
        -- working unchanged inside the callee.
        structParamCopies =
            List.concatMap
                (\b ->
                    if b.width > 1 then
                        (Alloc ("bx" ++ String.fromInt b.reg) (8 * b.width)
                            :: List.concatMap
                                (\k ->
                                    let
                                        sfx =
                                            String.fromInt b.reg ++ "_" ++ String.fromInt k
                                    in
                                    -- SOURCE: the incoming address register (`%a<reg>`)
                                    -- plus the field's byte offset; DESTINATION: the
                                    -- fresh block.  Two addresses, two temps — the
                                    -- first cut of this emitted a load and a store at
                                    -- the SAME address (the block), i.e. a no-op
                                    -- copy that read uninitialised stack, and it took
                                    -- a RUN of the example to see it (the .ssa looked
                                    -- plausible; the .s showed `movq 0(%rsp), %rax` /
                                    -- `movq %rax, 0(%rsp)`).
                                    [ Bin (Just ("ca" ++ sfx)) L Add (Il.Tmp ("a" ++ String.fromInt b.reg)) (Il.Con (8 * k))
                                    , Load (Just ("cv" ++ sfx)) L LoadL (Il.Tmp ("ca" ++ sfx))
                                    , Bin (Just ("ba" ++ sfx)) L Add (Il.Tmp ("bx" ++ String.fromInt b.reg)) (Il.Con (8 * k))
                                    , Store StoreL (Il.Tmp ("cv" ++ sfx)) (Il.Tmp ("ba" ++ sfx))
                                    ]
                                )
                                (List.range 0 (b.width - 1))
                        )

                    else
                        []
                )
                (paramBases pending.paramWidths)

        paramBlits =
            -- rawAbi params are `l` REGISTERS (never blitted into slots —
            -- the body reads them through `s.rawWord`); VR1's ptrRead defuns
            -- are `l` POINTERS read in place through `s.paramPtr`; every other
            -- ABI blits the incoming `%a<i>` pointers into their frame slots.
            if pending.rawAbi then
                structParamCopies

            else if pending.ptrRead then
                []

            else
                List.map
                    (\i -> Blit (Il.Tmp ("a" ++ String.fromInt i)) (Il.Tmp (slotTmp (i + 2))) vs)
                    (List.range 0 (pending.nparams - 1))

        capBlitsPro =
            List.concatMap
                (\j ->
                    [ Bin (Just ("e" ++ String.fromInt j)) L Add (Il.Tmp "env") (Il.Con (vs * j))
                    , Blit (Il.Tmp ("e" ++ String.fromInt j)) (Il.Tmp (slotTmp (pending.nparams + 2 + j))) vs
                    ]
                )
                (List.range 0 (pending.ncaps - 1))

        -- The frame base.  PFrame: the pooled ROOTED block (zeroed before
        -- rooting — a reused block's stale slots must never be scanned).
        -- PAlloc: the lean frame-FREE scratch block (osier-midabi) — no
        -- runtime call, no zeroing, no root push; unzeroed slot TAILS are
        -- never interpreted (every read is tag-directed, the block is
        -- never registered as a root, and blit is a raw copy).
        -- PLeaf: the same block for a SURFACE defun (perf P5), plus the one
        -- zero the pooled frame used to supply (see leafTailZero below).
        enter =
            case pending.pro of
                PFrame ->
                    -- stage 6 B0: the pooled frame is entered through the Mid
                    -- rawAbi defun q_Rt_x2eframeEnter (its param is `l`, the
                    -- raw-word ABI — so the nslots arg is Base L, not the Zig
                    -- seat's Base W i32).  B4 deleted the Zig rt_frame_enter
                    -- seat, so this is unconditional.
                    Call (Just "f") (Base L) (Il.Sym ("q_" ++ mangle "Rt.frame-enter")) [ ArgVal (Base L) (Il.Con pending.nslots) ]

                PAlloc ->
                    Alloc "f" (vs * pending.nslots)

                PLeaf ->
                    Alloc "f" (vs * pending.nslots)

        -- P5 / H3 — THE .done MARKER.  A surface defun returns the 80-byte
        -- `:ret`, i.e. slots 0 AND 1, and slot 1 carries the .done/.tail
        -- discriminator that rt_bounce and every caller test.  On a .done path
        -- nothing writes it: the pooled frame's enter-side memset is what made
        -- it read 0.  A frame-free defun has no memset, so it MATERIALIZES
        -- that zero here.
        --
        -- The marker's offset is READ from Mid.RtLayout (`retKindOffset`), not
        -- spelled 40 here — the layout is defined once, and the same constant
        -- is what the emitted-text row in TestMain pins.
        --
        -- MEASURED, and it is why this is a 64-bit store and not a 32-bit one:
        -- the reader loads EIGHT bytes at retKindOffset — `Rt.bounce`'s
        -- `r->kind == 0` lowers to `movq 40(%rax), %rcx; cmpq $0, %rcx`
        -- (vendor/qbe, the emitted .s of tests/elm-fixtures/arraybasic.elm).
        -- A `storew 0` leaves the four PADDING bytes at 44..47 uninitialised,
        -- the 64-bit compare sees a non-zero word, the .done path is missed,
        -- and rt_bounce chases a .tail built out of stack garbage — MEASURED:
        -- a wild jump into the heap (ASan: `PC is at a non-executable
        -- region`) with only that one defun changed.  So: one `storel`.
        -- The remaining words of slot 1 (f/e/args/arity) are read ONLY when
        -- the marker is non-zero, which this store rules out.
        --
        -- SLOT 0 gets the same treatment for the same reason: the `.done`
        -- result is the one thing the RETURN path reads without a tag test of
        -- its own, and the pooled frame's memset is what made a never-written
        -- slot 0 read as the number 0 (tag 0).  Two stores reproduce exactly
        -- the two non-tag-directed reads the frame used to supply; every OTHER
        -- slot is read tag-directed, which is the SAME argument the lean
        -- frame-free arm (PAlloc) has always rested on: the block is never
        -- registered as a root and a blit is a raw copy, so an unzeroed word
        -- past a cell's last written one is never interpreted.
        leafTailZero =
            case pending.pro of
                PLeaf ->
                    [ Store StoreL (Il.Con 0) (Il.Tmp (slotTmp 0))
                    , Bin (Just "tzk") L Add (Il.Tmp "f") (Il.Con RtLayout.retKindOffset)
                    , Store StoreL (Il.Con 0) (Il.Tmp "tzk")
                    ]

                _ ->
                    []

        prologue =
            case f.blocks of
                b0 :: rest ->
                    { b0 | body = enter :: slotDefs ++ leafTailZero ++ paramBlits ++ capBlitsPro ++ b0.body } :: rest

                [] ->
                    []
    in
    { f | blocks = prologue }


-- rt_callN: the arity dispatch table entry.  rt_apply cannot call a
-- generated function directly (it only has the code pointer), so it calls
-- through these; QBE allows `call %fn(...)` through a temporary.
--
-- ABI NOTE (MEASURED, the hard way): a `:val %a` PARAMETER arrives by value
-- ON THE STACK — a Zig caller passing `*Value` in a register mismatches and
-- the callee reads garbage.  So these dispatchers take PLAIN `l` pointer
-- params and pass each as a `:val` CALL ARGUMENT — QBE copies the 40 bytes
-- from the pointer onto the outgoing stack at the call site, which is
-- exactly what a C/Zig `*Value` argument is.
rtCallFuncs : List Func
rtCallFuncs =
    List.map
        (\n ->
            let
                argNames =
                    List.map (\i -> "a" ++ String.fromInt i) (List.range 0 (n - 1))

                params =
                    ( "fn", Base L ) :: ( "e", Base L ) :: List.map (\a -> ( a, Base L )) argNames

                callArgs =
                    ArgEnv (Il.Tmp "e") :: List.map (\a -> ArgVal (Base L) (Il.Tmp a)) argNames
            in
            { name = "rt_call" ++ String.fromInt n
            , export_ = True
            , ret = Agg "ret"
            , envParam = False
            , params = params
            , blocks =
                [ { label = "start"
                  , body =
                        [ Call (Just "r") (Agg "ret") (Il.Tmp "fn") callArgs
                        ]
                  , jump = Ret (Just (Il.Tmp "r"))
                  }
                ]
            }
        )
        (List.range 0 maxArity)


-- rt_call2r: the two-range apply bridge (stage 6 P1d Step B).  Rt.apply's
-- saturated/over-applied arms build `buf = [captures(napp) ++ args(nargs)]`
-- and hand it to rt_callN, whose callee blits its params from ONE contiguous
-- array — so every closure call pays a malloc(640) + two copyWords loops just
-- to stage the two ranges together.  This bridge takes the two ranges
-- separately (code, caps, napp, args, nargs): the callee's free-variable
-- captures are passed as its env (`e = caps + napp*40`), and its params are
-- the applied captures (caps[0..napp)) then the applied args (args[0..nargs))
-- — param i's pointer is (i < napp) ? caps + i*40 : args + (i-napp)*40,
-- computed with a branchless select (no copy, no malloc).  B4 closed the
-- hatch, so finishModule emits it unconditionally (the Mid route is the only
-- route).
--
-- ARITY > 16: the dispatch chain ends at @arity{maxArity} (the last c{k} test
-- falls through), so arity > maxArity would run the arity-16 block and read
-- params past both ranges — silent corruption.  UNREACHABLE by construction:
-- Lower rejects an arity over maxArity loudly (the same convention as
-- Rt.callArity's table and Rt.bounceGo's 17-arm chain, whose own note at
-- runtime.mid:4332 documents the same gap).  Kept as a stated parity gap, not
-- a live hazard; if maxArity ever grows, this chain follows it automatically.
rtCallTwoRange : Func
rtCallTwoRange =
    let
        -- (i < napp) ? caps + i*40 : args + (i-napp)*40, branchless:
        --   p = (args - napp*40) + (i<napp)*(caps + napp*40 - args) + i*40
        paramPtr : Int -> List Inst
        paramPtr i =
            [ Cmp (Just ("ci" ++ String.fromInt i)) L Cslt (Il.Con i) (Il.Tmp "napp")
            , Unary (Just ("cl" ++ String.fromInt i)) L Extuw (Il.Tmp ("ci" ++ String.fromInt i))
            , Bin (Just ("sel" ++ String.fromInt i)) L Mul (Il.Tmp ("cl" ++ String.fromInt i)) (Il.Tmp "diff")
            , Bin (Just ("pa" ++ String.fromInt i)) L Add (Il.Tmp "base") (Il.Tmp ("sel" ++ String.fromInt i))
            , Bin (Just ("p" ++ String.fromInt i)) L Add (Il.Tmp ("pa" ++ String.fromInt i)) (Il.Con (i * 40))
            ]

        arityBlock : Int -> Block
        arityBlock n =
            { label = "arity" ++ String.fromInt n
            , body =
                List.concatMap paramPtr (List.range 0 (n - 1))
                    ++ [ Call (Just "r") (Agg "ret") (Il.Tmp "code")
                            (ArgEnv (Il.Tmp "e")
                                :: List.map (\i -> ArgVal (Base L) (Il.Tmp ("p" ++ String.fromInt i))) (List.range 0 (n - 1))
                            )
                       ]
            , jump = Ret (Just (Il.Tmp "r"))
            }

        -- @c{k}: arity == k ? arity{k} : next.  k runs 1..maxArity-1; the last
        -- falls through to @arity{maxArity} (arity is bounded <= maxArity by
        -- the closure arity check, so the chain is total).
        dispatchBlock : Int -> Block
        dispatchBlock k =
            { label = "c" ++ String.fromInt k
            , body =
                [ Cmp (Just ("d" ++ String.fromInt k)) L Ceq (Il.Tmp "arity") (Il.Con k) ]
            , jump =
                Jnz (Il.Tmp ("d" ++ String.fromInt k))
                    ("arity" ++ String.fromInt k)
                    (if k < maxArity - 1 then
                        "c" ++ String.fromInt (k + 1)

                     else
                        "arity" ++ String.fromInt maxArity
                    )
            }

        start =
            { label = "start"
            , body =
                [ Bin (Just "napp40") L Mul (Il.Tmp "napp") (Il.Con 40)
                , Bin (Just "e") L Add (Il.Tmp "caps") (Il.Tmp "napp40")
                , Bin (Just "diff") L Sub (Il.Tmp "e") (Il.Tmp "args")
                , Bin (Just "base") L Sub (Il.Tmp "args") (Il.Tmp "napp40")
                , Bin (Just "arity") L Add (Il.Tmp "napp") (Il.Tmp "nargs")
                , Cmp (Just "d0") L Ceq (Il.Tmp "arity") (Il.Con 0)
                ]
            , jump =
                Jnz (Il.Tmp "d0") "arity0" (if maxArity > 0 then "c1" else "arity0")
            }
    in
    { name = "rt_call2r"
    , export_ = True
    , ret = Agg "ret"
    , envParam = False
    , params =
        [ ( "code", Base L )
        , ( "caps", Base L )
        , ( "napp", Base L )
        , ( "args", Base L )
        , ( "nargs", Base L )
        ]
    , blocks =
        start
            :: (List.map dispatchBlock (List.range 1 (maxArity - 1))
                    ++ List.map arityBlock (List.range 0 maxArity)
               )
    }


-- The driver's lookup table: one name string, one {name, code, arity} entry
-- per top-level defun, plus the array + length the runtime walks.
metaTable : List PendingFunc -> ( List DataDef, List Func )
metaTable pendings =
    let
        entries =
            List.filterMap
                (\p ->
                    case p.entryKey of
                        Just key ->
                            Just ( p, key )

                        Nothing ->
                            Nothing
                )
                pendings

        n =
            List.length entries

        nameDatas =
            List.indexedMap
                (\i ( _, key ) ->
                    { name = "mname" ++ String.fromInt i
                    , align = Just 8
                    , items = [ DStr key, DByte 0 ]
                    , export_ = False
                    }
                )
                entries

        -- One INLINE array of rows (name ptr, code ptr, arity w + 4 pad =
        -- 24 B/row — exactly Zig's `extern struct Meta { name, code, arity }`
        -- at align 8).  The rows live in a SINGLE data symbol so their 24-byte
        -- stride holds by construction; the old `l $meta0, l $meta1` array of
        -- per-row POINTERS only resolved because QBE happened to emit the
        -- 20-byte row symbols contiguously at a 24-byte stride — a layout the
        -- Zig `[*]const Meta` type did not actually describe.
        metaRowsItems =
            List.concatMap
                (\( i, ( p, _ ) ) ->
                    [ DRef ("mname" ++ String.fromInt i)
                    , DRef p.func.name
                    , DWord p.nparams
                    , DZero (RtLayout.metaSizeBytes - RtLayout.metaArityOffset - RtLayout.i32Bytes)
                    ]
                )
                (List.indexedMap (\i e -> ( i, e )) entries)

        tableDatas =
            [ { name = "meta_rows"
              , align = Just 8
              , items = metaRowsItems
              , export_ = False
              }
            , { name = "qbe_meta"
              , align = Just 8
              , items = [ DRef "meta_rows" ]
              , export_ = True
              }
            , { name = "qbe_meta_len"
              , align = Just 8
              , items = [ DWord n ]
              , export_ = True
              }
            ]
    in
    ( nameDatas ++ tableDatas, [] )


-- QBE identifiers are [a-zA-Z_$][a-zA-Z0-9_$]*; every other BYTE becomes
-- _xHH at a FIXED two digits, and any codepoint above a byte becomes _uHHHHHH
-- at a fixed six.  Fixed width is what makes mangle INJECTIVE on all strings:
-- a variable-width escape collides — before this fix mangle "_" and
-- mangle "\u{0005}f" both rendered _x5f (0x5f vs 0x5-then-"f").  Deterministic,
-- collision-free, and never parsed back.
mangle : String -> String
mangle str =
    String.join "" (List.map mangleChar (String.toList str))


mangleChar : Char -> String
mangleChar c =
    let
        code =
            Char.toCode c
    in
    if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) then
        String.fromChar c

    else if code < 256 then
        "_x" ++ hex2 code

    else
        "_u" ++ hex6 code


hex2 : Int -> String
hex2 code =
    String.fromChar (hexDigit (code // 16)) ++ String.fromChar (hexDigit (modBy 16 code))


-- 0x10FFFF (the largest codepoint) fits exactly: top pair <= 0x10.
hex6 : Int -> String
hex6 code =
    hex2 (code // 65536) ++ hex2 (modBy 65536 code // 256) ++ hex2 (modBy 256 code)


hexDigit : Int -> Char
hexDigit d =
    if d < 10 then
        Char.fromCode (48 + d)

    else
        Char.fromCode (87 + d) -- 'a' - 10 + d
