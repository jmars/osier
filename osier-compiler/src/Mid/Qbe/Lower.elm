module Mid.Qbe.Lower exposing (lower, lowerWith, wordArmDefunRefusals, wordArmUnported, wordSurfaceUnported, wordSurfaceUnportedWith)

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
--     rt_prim fallback for the float-promotion / non-numeric paths — ON THE VAL
--     ARM; under the word arm those prims route to the runtime unconditionally,
--     perf word-arm-arith), and
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
-- docs/qbe-backend.md).  On the SHIPPING (value) arm a Value is the 40-byte
-- aggregate `:val`; QBE passes :val params as POINTERS and returns them
-- through sret, exactly like a C struct by value.  A function of arity N with
-- K captures compiles to
--
--     function :val $q_<mangled> [(env %env),] l %a0 .. l %a{N-1}
--
-- — each `%a_i` is an `l` POINTER to the caller's staging slot (VR1), and the
-- body RETURNS the finished `:val` (40 B).  It does NOT return `:ret`: U3a
-- flipped the class and U3b deleted the `.tail` request, its builders and the
-- bounce loop that chased them, so nothing on this arm returns anything but
-- the value.  (`env` only when K > 0 — QBE passes it in a register invisible
-- to C; the generated rt_callN dispatchers pass env to env-less top-level
-- defuns too, which just ignore it).
--
-- THE WORD ARM RETURNS THE SAME CLASS, only narrower: `:val` at 8 bytes,
-- which the amd64 ABI returns in a register.  AREA 6 measured the one
-- remaining objection (see `closureRetClass`) and deleted `:ret` with its
-- kind word, so a defun's result area is ONE slot on both arms.
--
-- GC ROOTING (crux 2): every local lives in a RUNTIME-POOLED frame block
-- from `rt_frame_enter(nslots) -> *Value`, registered as ONE
-- ROOT_VALUE_ARRAY for the whole body, popped by rt_frame_leave().  The
-- frame ADDRESS is an opaque call result, so QBE cannot promote a slot's
-- store/load pair into a callee-saved register (MEASURED on the vendored
-- qbe: a non-escaping stack slot's store+reload ARE deleted across a call;
-- the pooled-frame loop shape keeps them — evidence in the handoff node and
-- docs/qbe-backend.md).  Slot 0 = the result value, 1..N params,
-- N+1..N+K captures, then expression temporaries.  A per-function GLOBAL
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
-- TAIL CALLS (crux 1): the vendored qbe DOES have a tail call, but its own
-- il.txt does not document it (the CALL BNF has no tail form; `tail` appears
-- there only in "width less than a word").  The IMPLEMENTATION has it —
-- parse.c's `tcall`/`Otcall` and amd64/emit.c's teardown+jmp — and Q1b uses
-- it.  So:
--   * a saturated App to the SAME defun in tail position = an IN-FRAME LOOP:
--     args into temp slots, blit temps into the param slots, `jmp @body`.
--     This stays the hot path — generality must not cost it.
--   * every other tail position (cross-defun call, rt_apply, thunk force) is
--     a REAL `tcall` (Q1b) after Rt.stage-tail/Rt.frame-leave; over the
--     four-register tcall budget (and in every non-tail position) the site is
--     an ordinary `call` that returns the finished value.  U3b DELETED the
--     `.tail` request, its builders (rt_tail_known / rt_apply_tail) and the
--     runtime bounce loop that chased them: no site builds one and none is
--     chased.
--
-- NO SSA: temporaries are assigned freely; QBE builds SSA itself.

-- (Exp's Con variant is deliberately NOT exposed: Mid.Qbe.Il.Arg also has a
-- Il.Con (the integer-constant argument), and Elm cannot qualify constructors
-- in patterns — exposing only one of the two keeps the pattern arms clean.)
import IntegerLiteral
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), FfiWidth(..), Lambda, LetBinder(..), Lit(..), Match(..), MemWidth(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), Step(..), TailTarget(..), UnsafeNode(..), ValuePath(..))
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
-- STAGE 2), and since VR3a it is read as a RECORD INSTANCE threaded in the
-- state: `S.layout`, seeded from `RtLayout.valLayout` at the entry point and
-- carried into every closure body's fresh state.  Nothing here names a layout
-- CONSTANT any more — `s.layout.valSizeBytes`/`s.layout.tagNil`/... are the
-- fields of the instance this compile was started with, which is what makes
-- a second instance (VR3b's word arm) a change at the SEED rather than at the
-- ~150 emit sites.
--
-- SIZEOF(:ret) IS NOT READ HERE ANY MORE (U3b), AND SINCE AREA 6 THE TYPE IS
-- GONE ENTIRELY.  The `:ret` aggregate was the bounce-loop result — two pooled
-- frame slots (slot 0 the finished value, slot 1 the `.tail` discriminator +
-- payload) — and its size was read as `RtLayout.retSizeBytes <instance>` at the
-- @ret blit.  U3b deleted that blit, the builder and the class; AREA 6 deleted
-- the word arm's last use of the type itself (see `closureRetClass`).


-- P5: the non-GC libc entries this emitter names as CALL TARGETS, i.e. the
-- ones a call may target without being a GC safepoint.  The list is EXACTLY
-- what the emitted runtime names (`rawcall free(...)` in runtime.mid — the
-- apply chain's staged-block release), a C-heap release that cannot run a
-- collect or move the Mid heap.
-- NOTHING ELSE may join it without the same argument — every other target is
-- a `q_*` symbol resolved against Mid.Rt.allocating, an indirect call, or a
-- cffi extern, and those are all treated as safepoints (deny by default):
-- a GC seat reached from C would be invisible here.
libcNoCollect : Set String
libcNoCollect =
    Set.fromList [ "free" ]



-- ============================ STATE ============================
-- One state record threads everything: block emission, temp/label/slot
-- supplies, the binder->slot scope, and module-level accumulation (extra
-- closure functions, data definitions).  Closures lower with a FRESH state
-- seeded from the enclosing one (datas/counters continue; blocks restart).


type alias S =
    { layout : RtLayout.ValLayout -- VR3a: the Value layout instance this compile emits FOR (seeded from RtLayout.valLayout, carried into every closure body's fresh state); NOTHING in this module may name a layout constant directly
    , blocks : List Block -- completed blocks, REVERSED
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
    , tailEmit : Bool -- Q1b: may this defun emit a real `tcall`?  TRUE only for an RtGeneric (closure-ABI) body, which is exactly the condition the backend's C4 re-checks — C4 demands the CALLEE's return class EQUAL the enclosing body's, and `closureRetClass` is the one statement of that class (`:val` on both arms)
    , pooledFrame : Bool -- (U1) does this defun hold a POOLED frame (proKind PFrame)?  A DSL `tailcall` must see the block's own `Rt.frame-leave` before it: the pooled block goes back to the pool and the CALLEE's frame-enter may pop and memset the very same block, so a tcall that skipped the leave would orphan (leak) the caller's frame per hop.  A PAlloc block (frame-free lean, rawAbi) dies with the C frame and needs no leave.
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
    , paramWords : Bool -- AREA 6: the incoming `l` registers ARE the VALUE WORDS (the word arm's RtGeneric ABI), so the prologue STORES each one into its slot instead of blitting from it as a pointer
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
the one thing a surface defun needs that a lean one does not — slot 0 (the
result) is read by the RETURN path WITHOUT a tag test, which the pooled frame
supplied by being memset at enter, so a PLeaf prologue materializes that word
with one 8-byte store (see leafTailZero in withPrologue).  ONE store on BOTH
arms: the word arm's second one (slot 1's `:ret` kind word) went with `:ret`.
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
        -- U3a: `:val` (40 B).  It used to be the 80-byte `:ret` because its
        -- body handed a `.tail` request upward for Rt.bounce to chase.  It now
        -- `tcall`s Rt.applyTailGo, which returns the finished Value — and
        -- abi1's C4 demands the tcall's class EQUAL the enclosing body's, so
        -- the two flips are one fact.  U3b then deleted the `.tail` family
        -- outright (Rt.tail-known/Rt.bounce/Rt.bounceGo) — see the note below
        -- where the `Rt.tail-known` case used to be.
        Agg "val"

    else if key == "Rt.applyTailGo" then
        -- U3a: the generic-apply TAIL LOOP.  A `:val` result (the finished
        -- value, or the partially-applied closure) through sret, and — the
        -- part that matters — WORD-class parameters, because it is the target
        -- of `Rt.apply-tail`'s `tcall` and J16 refuses a val parameter on a
        -- TailDefun.  Declared rawAbi for exactly that reason (Mid.Rt.rawAbi),
        -- the same override shape Rt.globalClosure has: an all-word parameter
        -- list with an aggregate result.
        Agg "val"

    -- U3b: the `Rt.tail-known` case (`Agg "ret"`, the 80-byte `.tail`
    -- request) is GONE with the defun.  NO rawAbi key returns `:ret` any
    -- more, so this function's aggregate answer is always `:val` — the
    -- `Agg "ret"` arm of lowerFunBody's @ret block below went with it, and
    -- with it the last reader of the `.tail` offsets in Mid.RtLayout.

    else if key == "Rt.boxInt" then
        -- AREA 4 (perf word-arm-area4): the boxed-integer seat returns the
        -- tagged Value (a code-13 heap pointer) through sret, so the emitter
        -- stores the loaded word straight into the destination slot.  Its one
        -- word param is the raw i64 that did not fit the fixnum.
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


{-| Q1b: the static arity budget for a `tcall`.  Our ABI spends rdi on the
hidden sret pointer (a closure body's result is an aggregate — the 40-byte
`:val` on the value arm, which is inmem, so the pointer is a real argument
register) and rax on `env` when the callee is a closure; the remaining integer
argument registers are rsi, rdx, rcx, r8, r9 — five.  The design's census
(MEASURED over the 4,786 static tail-call sites of the self-emit AT 81ae3fb,
where every one of them was an `Rt.tail-known` request) is 1→2113, 2→1759,
3→505, 4→169, 5→198, 6→24, ... so a budget of 4 covers 95.0% of them, and the
240 arity-5+ sites keep a correct non-tail lowering — a STATIC, compile-time
choice between two correct lowerings, never a fallback of an emitted tcall.
U3a did not change the POPULATION: the same 240 sites take the ordinary call.
What changed is the under-budget ones — they `tcall` the callee directly
instead of asking Rt.tail-known to build a `.tail` request for it.  (Five would
also fit a direct call, which passes no count word; the budget is held at the
design's number so the census above stays the claim it was measured as.)
-}
maxTailCallArgs : Int
maxTailCallArgs =
    4


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


{-| THE WORD ARM'S LOUD GATE, per construct (VR3b1 introduced it as ONE choke
point before the reachability walk; VR3b2 turned it into a per-construct gate
so the arm can port AREA BY AREA without ever emitting a half-word module).

`QBE_VALREP=word` does NOT make the word representation work.  The arm exists
so the representation is a knob with a LOUD off-switch rather than a
half-flipped emitter: a half-word emit LINKS CLEANLY and then reads another
representation's bytes at the wrong offset — the exact failure Mid.RtLayout's
header exists to prevent.  So every construct the word arm cannot lower YET
fails here, by name, and because every emit site returns `Result`, one failure
means NO IL AT ALL (there is no path that emits some word-arm code and some
val-arm code).

`what` NAMES THE CONSTRUCT AND ITS WORKLIST AREA.  The full worklist is beside
`RtLayout.wordLayout`; the running ported/un-ported table is in
`handoff-perf-vr3b2-result`.
-}
wordArmUnsupported : String -> String
wordArmUnsupported what =
    "qbe: QBE_VALREP=word is NOT IMPLEMENTED (perf VR3b2): the emitter cannot lower "
        ++ what
        ++ " — the word arm stops at its un-ported constructs instead of emitting half-word code (nothing was emitted). The worklist is beside `wordLayout` in Mid/RtLayout.elm; the ported/un-ported table is in handoff-perf-vr3b2-result."


{-| Is this emit running for the 8-byte tagged-word instance?  ONE predicate,
read by every per-construct gate, so a gate cannot disagree with the arm it is
guarding.
-}
wordArm : S -> Bool
wordArm s =
    s.layout == RtLayout.wordLayout


wordArmLayout : RtLayout.ValLayout -> Bool
wordArmLayout layout =
    layout == RtLayout.wordLayout


{-| U3b — THE RESULT AREA'S WIDTH IN SLOTS, the ONE statement of it.  A
defun's frame reserves the result first: ONE slot, on BOTH arms.  (It was TWO
on the word arm while that arm's frozen `:ret` put a kind word in slot 1;
AREA 6 deleted `:ret` — see `closureRetClass` — so slot 1 has no owner on
either arm.)  Everything that numbers a slot reads this — the fresh-slot
counter, the param and capture binder slots, the prologue's param/capture
blits and the self-tail param blits — so the arms cannot drift one slot apart.
(They DID drift once: U3b changed the counter and left `slotTmp (i + 2)` in the
blits, and qbe caught it as `invalid type for second operand %s2 in blit0` —
an UNDEFINED slot, because the frame was one slot shorter than the body
believed.)
-}
resultSlotBase : RtLayout.ValLayout -> Int
resultSlotBase _ =
    1


{-| U3a — the CLOSURE ABI's return class, in ONE place: `lowerFunBody`'s ret
type, `directCall`'s `tcall` annotation, and `directCall`'s ordinary-call
result class all read it, so the three cannot disagree (a disagreement is a
C4 err() at assembly or, worse, a wrong-width blit).

IT IS `:val` ON BOTH ARMS, and the WORD arm is where that was decided (AREA
6).  A closure body returns the finished Value — nothing builds a `.tail`
request any more — so the only question was the aggregate's WIDTH: 40 bytes on
the value arm, 8 on the word arm.  The word arm kept a 48-byte `:ret` until
AREA 6 on the stated ground that "collapsing it would put a slot address in a
register"; MEASURED FALSE against the vendored qbe (probe agg8.ssa): an
8-byte aggregate return is REGISTER class and `ret %s0` still means "the value
AT %s0", so qbe loads the word into rax and the caller's `%t =:val call` temp
is still the ADDRESS of a materialized block.  The premise describes a
NON-aggregate return, which nothing proposes.  With the type went its kind
word, its result slot and every reader of its offsets.
-}
closureRetClass : S -> AbiTy
closureRetClass _ =
    Agg "val"


{-| THE PER-DEFUN PRE-WALK CLASSIFIER (perf VR3b2) — which Mid.Ir constructs
the word arm can emit TODAY.

WHY A WHITELIST AND NOT PER-SITE GATES ALONE.  The value-materialising sites
are gated individually (and that is where the ports land, area by area), but a
gate at each of ~60 sites is only as complete as the enumeration behind it, and
a MISSED site is a mixed-representation emit — the one failure this arc exists
to prevent.  This classifier is the belt to that braces: under the word arm a
defun whose body contains ANY construct outside the ported set is refused
BEFORE its body walk starts, so a missed site cannot be reached.  The two must
agree, and the direction of the risk is chosen: a construct listed here is
claimed PORTED and is pinned in TestMain; a construct not listed stays loud
even if its emit site happens to work.

WHAT IS PORTED (perf VR3b2, area 1 — the frame slot stride):
  * the prologue/epilogue: the `alloc8 (valSizeBytes * nslots)` block, the slot
    address table, the param and capture blits, slot 0/1's materialisation;
  * a VALUE COPY (`Var`, `let x = y`, `NoTail` around either) — one `blit` of
    `valSizeBytes`.
NOTHING ELSE.  In particular a LITERAL is a tag WRITE (area 2) and is refused
here by name, so the arm's admitted language is exactly what has been ported.

IT RETURNS EVERY BLOCKER, NOT THE FIRST (perf word-arm-frontier review, item 1).
The walk used to short-circuit on its first refusal, which made the per-defun
answer FIRST-ONLY: a defun carrying a constructor-tag pattern AND a float
literal reported one of them, and a census built from that answer promises a
group that a port of the reported class cannot move.  MEASURED inside the
frontier census itself — its BEFORE table promised 15 movable groups for
`Con`+`MTagEq` and 14 moved, the 15th reappearing as float-blocked only once the
first class stopped refusing.  So the walk collects a LIST and every consumer
reads all of it; `wordArmUnported` below is the first-element view kept for the
classifier's own unit rows.
-}
wordArmUnportedList : Exp -> List String
wordArmUnportedList exp =
    case exp of
        Var _ ->
            []

        App _ ->
            -- AREA 6 (THE CALL ABI), ported: the arguments cross as WORDS on
            -- this arm (`argOperands`) and the callee stores them into its
            -- slots; the result is the same `:val` class at 8 bytes.  The
            -- per-site emit is `lowerApp`, which classifies the head (a known
            -- defun, a thunk, or a first-class value through Rt.apply) and
            -- refuses anything it cannot express by name.
            --
            -- THE ARGUMENTS ARE NOT WALKED, AND THAT IS A KNOWN GAP WITH A
            -- MEASURED COST (perf word-arm-floats).  A raw node reached ONLY as
            -- a call argument is invisible to this classifier, so its refusal
            -- comes from the emit site and — when the site has no `defunKey`
            -- in scope — does NOT NAME THE DEFUN: the float census's
            -- `<emit site, unnamed>` rows for `strunit` and `cmporder` were
            -- exactly that, and they were reachable only through the float
            -- literal that this unit ports (the port makes them emit, so they
            -- are no longer unnamed rows).
            --
            -- WALKING `app.args` HERE WAS TRIED IN THIS UNIT AND REVERTED, with
            -- the reason measured: it turns 5 corpus groups out of BOTH and
            -- into WORD-BLOCKED, because `StreamRef` reaches this walk and the
            -- classifier has NO ARM FOR IT — it falls through to the catch-all
            -- below, whose text ("a stream reference — it materialises a symbol
            -- Value") is a SEVENTH stale blanket refusal.  The site
            -- (`lowerVal`'s StreamRef arm) is `lowerLit (LSymbol v)` +
            -- `rtPrimSlots "value"`, i.e. the symbol cell R1 ported and
            -- `Rt.value`, whose WORD splice is live enough that perf
            -- word-arm-letdestr had to seed `Rt.symToStr` for it.  So the entry
            -- looks stale — but the 14 groups it blocks
            -- (`Runtime.readLineGo`/`Runtime.writeString`: execbig execchain
            -- execenv execglob execmal execnofile execpipe execsubchain ioecho
            -- iofile readfile taskattempt taskpure taskseq) have NEVER BEEN RUN
            -- on the word arm, and admitting a construct on emit-only evidence
            -- is the mistake the let-destructuring unit paid for.  Enabling
            -- this walk therefore OWES a StreamRef decision plus those 14 runs
            -- in the same commit, and that is its own unit.
            []

        NoTail inner ->
            wordArmUnportedList inner

        Let block ->
            -- ============ AREA 2/3: A `let` DESTRUCTURING PATTERN ============
            -- PORTED (perf word-arm-letdestr), and it is the FIFTH class in a
            -- row whose refusal was STALE rather than a representation gap —
            -- the same shape `Con`, `MTagEq` and the arithmetic family had.
            --
            -- THE CRUX THE CENSUS NAMED, ANSWERED: does the existing-binder
            -- path have a word-arm fork, or is it the pattern matcher's own
            -- `lowerBind`/`lowerPath`?  IT IS THE MATCHER'S PATH, and there is
            -- no fork to write.  `lowerLetDestruct` is the `Case` matcher's
            -- emission with a different control-flow epilogue:
            --   * the scrutinee is `lowerVal` (arm-forked at every site),
            --   * the TESTS are `lowerMatchTests` — the SAME `lowerMatch` a
            --     `Case` alt runs, i.e. `lowerTagMatch` -> `wordTagIs` for
            --     MCons/MEmpty/MVector and the forked tag-equality for MTagEq,
            --   * the BINDS are `lowerBinds` -> `lowerBind` -> `lowerPath` ->
            --     `readSteps` -> `fieldBase`/`chaseField`/`chaseCdr`/`lowerHdTl`
            --     — the one chase family `fieldBase`'s doc calls "the ONE
            --     statement of the difference between the arms",
            --   * the non-exhaustive arm is `Rt.die` through the raw-word ABI.
            -- So every layout decision this construct needs was already made
            -- for `Case`, which is why porting it is an admission here rather
            -- than an emitter change.  (MEASURED, not inferred: the 26 corpus
            -- groups in tools/qbe/WORD-ARM-FRONTIER.md compile on both arms and
            -- tools/qbe/word-arm-diff/letdestr.elm runs byte-identically on
            -- both.)
            --
            -- WHAT IT STILL REFUSES: everything the three walks refuse.  The
            -- scrutinee, each match's literal and each binder's PATH are
            -- classified by the same helpers the `Case` arm uses, so an
            -- un-ported construct anywhere inside a destructuring still refuses
            -- by name — "the pattern is ported" can never be read as "anything
            -- it binds is".
            let
                fromBinder b =
                    case b of
                        LetBind bind ->
                            wordArmUnportedList bind.value

                        LetDestruct d ->
                            wordArmUnportedList d.value
                                ++ wordArmUnportedMatches d.matches
                                ++ wordArmUnportedBinds d.binds
            in
            List.concatMap fromBinder block.binders ++ wordArmUnportedList block.body

        Lit (LNumber _) ->
            -- AREA 2, THE FIXNUM IMMEDIATE.  `lowerLitWord` owns the i61 range
            -- decision (it refuses an out-of-range literal by NAME, as area 4's
            -- boxing gap) so there is one place that decides, not two.
            []

        Lit (LNumberBig _) ->
            -- Same seat as `LNumber`: an immediate number needs no heap object
            -- here, and `lowerLitWord` owns the (area-4) decision about one it
            -- cannot inline.  Under the VALUE arm `lowerLitVal` emits it.
            []

        Lit (LBoolean _) ->
            []

        Lit (LString _) ->
            -- AREA 3, THE STRING CELL (perf VR3b3 area A/D).  A word-arm string
            -- is one heap block with a RAW body: the byte pointer in body unit
            -- 0 and the length in body unit `lenFieldWord`.  TWO writers own
            -- the shape — `storeWordStringCell` for a runtime `mkstr` (the cell
            -- `Rt.allocRaw` already allocated and the caller filled) and
            -- `storeWordStringLiteral` for a literal (a two-unit cell pointing
            -- at static bytes) — so this classifier only says the construct is
            -- ported.
            []

        RecordLit fields ->
            -- ============ THE SURFACE LANE: A RECORD LITERAL ============
            -- PORTED (perf word-arm-records R2).  A word-arm record is ONE
            -- code-14 block, `[data_0 .. data_{n-1} | namesBase]`, and the
            -- emission is `lowerRecordLitPos`'s own word fork — so this arm
            -- classifies the CONSTRUCT the emitter will see: every field VALUE.
            -- The two desugar routes behind it (duplicate labels, and
            -- `QBE_NOREC=1`) build a cons/`@p` chain whose symbol cars are the
            -- symbol cells R1 ported, so classifying the values covers all
            -- three routes; a field whose value is un-ported still refuses.
            wordArmUnportedRecordFields fields

        RecordGet rec _ ->
            -- ============ THE SURFACE LANE: A RECORD FIELD READ ============
            -- PORTED (perf word-arm-records R3).  `lowerRecordGet` binds the
            -- record, then tag-tests it (`boxTagIs` with the VALTAG constants):
            -- tag 14 -> the POSITIONAL `data[rank]` read (one `RawVecLoad` off
            -- `RawVecBody`, both of which absorb the arm — NAMES LAST is what
            -- makes that read need no fork) or the `Rt.recGet` NAME WALK, whose
            -- word splice reads the names base from the record's LAST body word
            -- and bounds by `veclen - 1`; tag 4 -> the assoc/snd chain (the
            -- QBE_NOREC/host route, already ported).  The field NAME is not an
            -- expression — it becomes a `symbol` literal (R1) — so the record
            -- is the only subexpression to classify.
            wordArmUnportedList rec

        RecordUpdate update ->
            -- ============ THE SURFACE LANE: A RECORD UPDATE ============
            -- PORTED FOR A CLOSED ROW (perf word-arm-records R4).  The closed
            -- form (`lowerRecordUpdateClosed`) is the one-block BUILD again —
            -- `Rt.allocRecord(n)` so the names word is inside the block, the
            -- data stores through the plain seat, ONE raw names store at index
            -- `n`, the tagged body through the cell writer — and its tag test
            -- and its field COPY go through `recordTagBranch`/`fieldBase` +
            -- `elemAddr` rather than the val arm's `slot + 8` payload
            -- indirection and `* valSizeBytes` stride (both wrong differently
            -- on a one-word slot).
            --
            -- WHAT THIS ARM DOES NOT REACH: the WALK form (a non-closed base,
            -- `recordUpdateWalkExp` -> `applyUpdates` -> `Rt.recInsert`) still
            -- refuses BY NAME at the Rt gate, because the runtime's update
            -- twins are not written yet.  So this arm classifies the construct
            -- the emitter will see and the refusal for the other route names
            -- the defun, not the construct.
            wordArmUnportedList update.base ++ wordArmUnportedRecordFields update.updates

        Lit (LSymbol _) ->
            -- AREA 3, THE SYMBOL CELL (perf word-arm-records R1).  A word-arm
            -- symbol is one code-2 heap block whose body is ONE raw word (the
            -- NUL-terminated name pointer) — the shape `Rt.intern` already
            -- builds.  `storeWordCell` owns the shape, so this classifier only
            -- says the construct is ported.
            []

        Lit (LFloat _) ->
            -- ============ AREA 5: A FLOAT LITERAL ============
            -- PORTED (perf word-arm-floats), and it is the SIXTH class in a row
            -- whose refusal described a path that already worked.  The refusal
            -- said "the word arm heap-boxes a float as a `[hdr | f64]` cell,
            -- WHICH DOES NOT EXIST YET" — and the cell does exist:
            -- `storeWordFloatCell` (below) has built it since perf
            -- word-arm-area3rt, for the runtime's `mkflt` lane, allocating
            -- through `Rt.allocFloat`.  The literal is the same cell with a
            -- different PRODUCER of the double (a `flt:` static data item
            -- instead of an expression), so this arm is an ADMISSION and the
            -- emitter work is `lowerLitWord`'s LFloat arm routing through that
            -- writer.
            --
            -- THE FRESH DEFECT THE ADMISSION EXPOSED IS NOT HERE, it is in
            -- `RawLoadFlt` (`fload`): the site every float READER goes through
            -- (`Rt.+`, `Rt.<`, `Rt.asF`, `Rt.fRender`) and which carried a
            -- standing "when area 5 lands, fork this in the same unit"
            -- instruction.  It is forked in this unit; see that site.
            []

        ShortAnd block ->
            wordArmUnportedList block.left ++ wordArmUnportedList block.right

        ShortOr block ->
            wordArmUnportedList block.left ++ wordArmUnportedList block.right

        NotEqual block ->
            -- AREA 2, THE `/=` OPERATOR (perf word-arm-arith).  It is PORTED by
            -- the same classification that ported `=`: `lowerNotEqual`
            -- delegates to `lowerNumEq` and then negates the tagged Boolean
            -- through `jmpfFalse` (both arm-clean), and under the word arm
            -- `lowerNumEq` takes the `rtPrimSlots "="` route into `Rt.=`, whose
            -- word splices ARE the ported arm.  The WORKLIST said this was NOT
            -- ported and gave the right reason at the time — "porting it means
            -- porting that inline, i.e. area 2/4" — and this is that port.
            wordArmUnportedList block.left ++ wordArmUnportedList block.right

        If block ->
            -- AREA 2, THE BOOLEAN TAG TEST (perf VR3b2).  The condition is a
            -- Value test whose lowering is `readTag` + a compare; the two
            -- BRANCHES are ordinary sub-expressions and are classified here,
            -- so an If only emits when everything inside it does.
            wordArmUnportedList block.cond
                ++ wordArmUnportedList block.thenBranch
                ++ wordArmUnportedList block.elseBranch

        Loop block ->
            -- AREA 2, THE LOOP.  Its condition is the SAME falsy test `lowerIf`
            -- uses (`falsyJump` — one statement of the arm's tag question), its
            -- body is an ordinary sub-expression and the back edge re-enters
            -- the condition block.  No phi, so nothing about the arm changes
            -- the shape.  `break`/`continue` are LEAVES that only close a block
            -- and jump to a label the frame already owns — no value crosses, so
            -- the arm cannot see them.
            wordArmUnportedList block.cond ++ wordArmUnportedList block.body

        Break ->
            []

        Continue ->
            []

        Unsafe node ->
            -- AREA 3 (PAYLOAD ACCESS), the RAW-NODE half (perf VR3b3 areas
            -- B/C).  A raw node is a WORD producer, and the word arm now emits
            -- the ones whose shape it has ported: the payload reads
            -- (`RawPayload`/`RawPayload32`), the tag read (`RawTagOf`), the tag
            -- test (`RawTagIs`) and the two allocator seats
            -- (`RawAllocVector`/`RawAllocRaw`).  Everything else stays LOUD —
            -- in particular every CALL node (area 6/7: the argument staging is
            -- the ABI) and every arithmetic node (area 4).
            case node of
                RawPayload _ ->
                    []

                RawPayload32 _ ->
                    []

                RawTagIs _ ->
                    []

                RawAllocVector _ ->
                    []

                RawAllocRaw _ ->
                    []

                RawStrByte _ ->
                    []

                RawMkValue _ ->
                    -- The `mk*` WRITE path (area A).  The classifier admits the
                    -- NODE; whether the CODE is writable is `wordCellRefusal`'s
                    -- single statement, checked on the Result path
                    -- (`storeValueWords`) so a heap code whose layout is not
                    -- settled refuses at COMPILE time, and its nested word
                    -- expressions still go through `rawWordArg`, which refuses
                    -- anything un-ported.  So the belt still holds: this arm
                    -- cannot let half-word code through.
                    []

                -- THE RAW-WORD FAMILY: ARM-INDEPENDENT BY CONSTRUCTION.
                -- A raw word is 8 bytes in BOTH arms and these nodes carry no
                -- `val` at all, so their emit sites never consult the layout
                -- (MEASURED by reading each: `wordAddr` is `ptr + 8*index`
                -- hardcoded, the byte/mem/C-call widths come from the FFI
                -- declaration, and the static-data nodes are addresses).  They
                -- are the runtime's own plumbing - VR3c's twinned strides live
                -- in the runtime TEXT, not in these nodes - so refusing them
                -- would report a lane boundary instead of a construct.
                RawWordLoad _ ->
                    []

                RawWordStore _ ->
                    []

                RawByteLoad _ ->
                    []

                RawByteStore _ ->
                    []

                RawMemLoad _ ->
                    []

                RawMemStore _ ->
                    []

                RawCallRaw _ ->
                    []

                RawCallExtern _ ->
                    []

                RawCStr _ ->
                    []

                RawSym _ ->
                    []

                RawDataAddr _ ->
                    []

                WithRoots _ ->
                    []

                RawBin _ ->
                    []

                RawCmp _ ->
                    []

                RawUn _ ->
                    []

                -- ================= AREA 6: THE CALL ABI =================
                -- Every node below was refused here until this unit, and each
                -- is admitted only because its EMIT SITE now handles the word
                -- arm.  The mapping, one line each, so a later reader can
                -- check the claim against the site:
                --
                --   RawCall       `lowerRawCall` — args through `argOperands`
                --                 (address on the val arm, WORD here), result
                --                 `closureRetClass` + a valSizeBytes blit.
                --   RawCallAgg    `lowerRawCallAgg` — unchanged: an aggregate
                --                 result is a materialized block either way and
                --                 `:val` is 8 bytes, so the blit width is the
                --                 layout's.  Only shape "val" is legal (U3b).
                --   RawAllocN     `Alloc t (8 * words)` — a raw STACK block,
                --                 arm-independent by construction.
                --   RawTailCall   `lowerRawTailCall` — the DSL's `tcall`; its
                --                 argument rule is `rawWordArg`, and its C4
                --                 class check reads `closureRetClass`, so a
                --                 word-arm tcall is checked exactly like the
                --                 val arm's.
                --   RawVecLoad    the val arm's `blit e, dest, valSizeBytes`
                --                 IS the word-arm read: `elemAddr` already
                --                 strides by the layout, so at 8 bytes it
                --                 copies the one word.
                --   RawVecStore   unchanged: the runtime's ONE barrier seat
                --                 twins the stride (VR3c twinned BOTH seams),
                --                 and the third word is the address of the
                --                 value's slot on both arms.
                RawCall _ ->
                    []

                RawCallAgg _ ->
                    []

                RawAllocN _ ->
                    []

                RawTailCall _ ->
                    []

                RawVecLoad _ ->
                    []

                RawVecStore _ ->
                    []

                -- AREA 3 (PAYLOAD ACCESS), the ELEMENT-BASE half (perf
                -- word-arm-area3rt).  `vecbody` is the base every `vecload`/
                -- `vecstore`/`vecaddr` wants, and it is admitted because its
                -- two arms are the same arithmetic the val arm already emitted
                -- (see `RawVecBody`'s emit site).  `RawVecAddr` was refused by
                -- the `_` fallback below, not by its own emit site, so it is
                -- named here too — its arm is unchanged (it is `elemAddr`).
                RawVecBody _ ->
                    []

                RawVecLen _ ->
                    []

                RawVecAddr _ ->
                    []

                _ ->
                    [ wordArea (wordAreaName exp) (wordAreaWhat exp) ]

        PrimApp app ->
            -- ============ THE SURFACE LANE: PRIM APPLICATIONS ============
            -- A `PrimApp` is not ONE construct on this arm, so it is not
            -- classified as one (perf word-arm-surface).  The AGGREGATE prims
            -- — `cons`, `@p`, `emptylist`, `assoc`, `snd` and every other prim
            -- with a Mid implementation — lower through `lowerArgsToSlots` ->
            -- `rtPrimSlots`, whose emission is ARM-INDEPENDENT by construction:
            -- the staged args are ROOTED frame slots, the callee is a
            -- `:val`-returning Rt defun reached by the lean ABI (pointer args
            -- in, one `valSizeBytes` blit out), and the only width it reads is
            -- the layout's.  That is the same ground `App` is admitted on
            -- (AREA 6) — the construct is ported because its EMIT SITE handles
            -- the arm, not because it looked harmless.
            --
            -- The ARITHMETIC prims do NOT take that route on the VAL arm:
            -- `lowerArith`/`lowerCompare`/`lowerNumEq` read the tag WORD and
            -- the payload at `+8`, i.e. the 40-byte representation, in their
            -- inline arms.  UNDER THE WORD ARM THOSE ARMS ARE SKIPPED
            -- (perf word-arm-arith): each of the three forks on `wordArm` and
            -- takes this same `rtPrimSlots` route, whose runtime defuns reach
            -- their operands through the layout-derived accessors.  So they
            -- are NOT refused here any more; only the float-only `f/` is (see
            -- `wordArmPrimUnported`), plus any prim with no Mid impl.
            wordArmPrimUnported app.prim ++ wordArmUnportedArgs app.args

        GRef _ ->
            -- ============ CLOSURES (perf word-arm-closures) ============
            -- A `GRef` in a VALUE position is `lowerGRefValue`, and its whole
            -- emission is one call to `Rt.globalClosure(desc)` whose argument
            -- is the descriptor's ADDRESS as a raw `l` word and whose result
            -- is the module's `:val` class.  Both are arm-independent, and the
            -- runtime half is now genuinely EXECUTED: the seat's word twin
            -- builds a 2-word header plus a 4-word body at `mkval(6, body)`,
            -- caches the BODY at `desc + 16`, and rebuilds the Value on the
            -- cache hit.  That cell is C-heap — outside [heapStart, cursor) —
            -- so the collector's range tests treat it as "not mine" and it is
            -- never moved; the tagging is the same `...001` every heap object
            -- carries.  The FORCED shape is a plain direct call, i.e. AREA 6's
            -- own path.
            []

        Lam lambda ->
            -- An INNER lambda is `lowerClosure`: contiguous capture staging in
            -- ROOTED frame slots (the slot stride is the instance's), the
            -- closure's own QBE function through `lowerFunBody ... RtGeneric`
            -- (whose prologue blits params and captures at `valSizeBytes`
            -- strides), and one `Rt.closure(desc, capBase, K)` call.  What the
            -- three boxed arguments carry is a RAW POINTER (`desc`, `capBase`)
            -- or a count, and a raw pointer crossing as a number IS the
            -- established `mknum(ptr)` wrap — the runtime reads it back with
            -- `payload(·, 0)`, which is `sar 3` on this arm, the exact inverse
            -- of `storeWordCell`'s `shl 3`.
            --
            -- The recursion is over the BODY, for the reason every other
            -- compound construct recurses: the closure's body is lowered into
            -- the same module, so a construct this arm cannot express must be
            -- named HERE rather than discovered at its emit.
            wordArmUnportedList lambda.body

        Con con ->
            -- ============ THE SURFACE LANE: A CONSTRUCTOR APPLICATION ============
            -- PORTED (perf word-arm-frontier).  This was a blanket refusal whose
            -- STATED REASON had gone stale, and the measurement is what found it:
            -- the entry said "under the word arm a heap object is one tagged
            -- pointer, not a tag word plus payload words", which is true and is
            -- not a reason — every part of `lowerCon` had already been ported by
            -- an earlier unit, on routes that are named at the site:
            --   * the TAG is `lowerLit (LSymbol tag)`, i.e. the code-2 symbol
            --     cell `storeWordSymbolLiteral` writes (R1) — the same shape
            --     `Rt.intern` builds, allocated through `Rt.allocSym`;
            --   * the ARGUMENTS are `lowerArgsToSlots` (ROOTED frame slots) staged
            --     contiguous by `stageSlots`, and the two boxed arguments are
            --     `storeValueCell tagNumber`, whose word-arm arm is `shl 3` —
            --     i.e. exactly the `mknum(ptr)` wrap the closure ABI already
            --     uses for `desc`/`capBase`, and `Rt.con`'s word twin reads them
            --     back with `payload(·, 0)` = `sar 3`;
            --   * the ALLOCATION is `Rt.con`'s, whose word splice was written in
            --     perf word-arm-area3rt (ONE code-10 block of `cnt + 1` body
            --     words, `vecstore(body, 0, tag)` then `Rt.conFill` from the
            --     staged block).
            -- So the classifier does what it does for every other compound
            -- construct: it recurses into the ARGUMENTS, so a constructor
            -- carrying an un-ported value still refuses here rather than at its
            -- emit.
            --
            -- MEASURED, not inferred (perf word-arm-frontier): `Circle 7` /
            -- `Square 3 4` / a nested `Wrap (Square 3 4)` / a `String` payload /
            -- a `Tree` built by 6000 inserts all compile, assemble, link and run
            -- BYTE-IDENTICALLY on both arms, and
            -- `tools/qbe/word-arm-gcchurn/con.elm` holds 6000 of them reachable
            -- across 18 scavenges at QBE_HEAP_MB=1 (6000/6000/0 on both arms).
            wordArmUnportedArgs con.args

        ListLit es ->
            -- ============ THE SURFACE LANE: A LIST LITERAL ============
            -- `lowerListLit` is `lowerVal (buildList es)` — a list literal has
            -- NO emission of its own, it desugars to a right-nested
            -- `cons`/`emptylist` chain and those route through `rtPrimSlots`
            -- into the runtime's own `Rt.cons`/`Rt.emptylist` (which ARE
            -- twinned for this arm, perf word-arm-area3rt).  So the honest
            -- classification is the one over the form the emitter will
            -- actually see: classify the DESUGAR, not the sugar.  Classifying
            -- `ListLit` as an opaque heap-object construction would refuse a
            -- construct whose whole emission is a call this arm already
            -- makes.
            wordArmUnportedList (buildList es)

        Tup es ->
            -- ============ THE SURFACE LANE: A TUPLE ============
            -- Same shape as `ListLit`: `lowerTup` is `lowerVal (buildTuple es)`
            -- — a tuple has no emission of its own either.  `buildTuple` is a
            -- right-nested `cons` chain terminated by the fixnum 0 (NOT by
            -- `emptylist`: Mid's tuple encoding is a cons spine whose tail is
            -- the number 0, which is what `Tup []` and the last element both
            -- are), so every part of it is already arm-clean.  Classify the
            -- desugar, for the reason stated at `ListLit`.
            wordArmUnportedList (buildTuple es)

        Case branch ->
            -- ============ THE SURFACE LANE: A CASE ============
            -- Every alternative is a tag test plus payload chases, and BOTH
            -- halves are ported: `lowerTagMatch` goes through `wordTagIs`
            -- (a word-tag compare for an IMMEDIATE valtag such as nil, a
            -- GC-header KIND read for a heap one such as cons/vector — never a
            -- bare tag compare, which would match every heap object), and the
            -- chase family goes through `fieldBase` (payload word 0 IS the
            -- element on this arm, so the base is its address).
            --
            -- What is NOT ported refuses here rather than at the emit:
            --   * a CONSTRUCTOR-TAG match (`MTagEq`) materialises the tag as a
            --     `symbol` literal, which is AREA 5's heap cell;
            --   * a RECORD field bind (`VField`) is the refused record family —
            --     its layout (the second parallel names array) is a design
            --     question, not a stride.
            wordArmUnportedList branch.scrutinee ++ wordArmUnportedAlts branch.alts

        _ ->
            [ wordArea (wordAreaName exp) (wordAreaWhat exp) ]


{-| The FIRST blocker in walk order, or `Nothing`.  The classifier's unit rows
read this view; every PLANNING consumer reads `wordArmUnportedList`, because a
first-only answer is what made the census over-promise (see the docstring above).
-}
wordArmUnported : Exp -> Maybe String
wordArmUnported exp =
    List.head (wordArmUnportedList exp)


{-| Every alternative of a `Case`: its matches, its pattern binds and its body.
-}
wordArmUnportedAlts : List Alt -> List String
wordArmUnportedAlts alts =
    List.concatMap
        (\alt ->
            wordArmUnportedMatches alt.matches
                ++ wordArmUnportedBinds alt.binds
                ++ wordArmUnportedList alt.body
        )
        alts


wordArmUnportedMatches : List Match -> List String
wordArmUnportedMatches matches =
    List.concatMap
        (\m ->
            case m of
                MTagEq _ _ ->
                    -- ============ THE SURFACE LANE: A TAG TEST ============
                    -- PORTED (perf word-arm-frontier).  The stated reason was
                    -- "the tag is materialised as a `symbol` literal, and under
                    -- the word arm a symbol is a heap object behind one tagged
                    -- pointer (AREA 5)" — the FIRST half of which is true and was
                    -- already ported by R1 (`LSymbol` is admitted by this very
                    -- classifier, `storeWordSymbolLiteral` writes the code-2
                    -- cell), and the second half of which is a description, not a
                    -- blocker.  What actually remained was the TAG-EQUALITY half,
                    -- and `lowerMatch` now forks it: on this arm the test is the
                    -- runtime's `=` (`lowerEqMatch`), not the pointer inline.
                    []

                MLitEq _ lit ->
                    wordArmUnportedList (Lit lit)

                _ ->
                    []
        )
        matches


wordArmUnportedBinds : List ( Binder, ValuePath ) -> List String
wordArmUnportedBinds binds =
    List.concatMap
        (\( _, path ) ->
            case path of
                VField _ _ ->
                    -- ============ A RECORD FIELD PATTERN ============
                    -- PORTED (perf word-arm-records R3).  It has no emission of
                    -- its own: `lowerPath`'s `VField` arm binds the record into
                    -- a ROOTED slot and then calls `recordAccessBody` — the
                    -- SAME tag test + positional/walk read a `.field` read uses
                    -- (`RecordGet`, below).  So this bind needs exactly what the
                    -- read needed and nothing more, and its STEPS are pointer
                    -- chases (`readSteps`), which are `VPath`'s own machinery.
                    []

                VPath _ ->
                    []
        )
        binds


{-| Every field VALUE of a record literal, left to right — the same recursion
the other compound constructs use.  The field NAMES are not expressions: they
become the static names array (`RawDataAddr`), whose word arm R1 forked.
-}
wordArmUnportedRecordFields : List ( String, Exp ) -> List String
wordArmUnportedRecordFields fields =
    List.concatMap (\( _, v ) -> wordArmUnportedList v) fields


{-| Every argument of a prim application, left to right — the same recursion
the other compound constructs use, so a nested refusal is named rather than
swallowed.
-}
wordArmUnportedArgs : List Exp -> List String
wordArmUnportedArgs args =
    List.concatMap wordArmUnportedList args


{-| THE PRIMS WHOSE EMIT SITE IS NOT ARM-CLEAN, refused by name.

THE ARITHMETIC CLASS LEFT THIS LIST (perf word-arm-arith), and it left as ONE
classification rather than a site sweep: `lowerPrimApp`'s inline fast paths are
a VAL-ARM SHAPE (they read the tag word at `slot + 0` and the payload at
`slot + 8`), and under the word arm the whole family takes the ordinary
`rtPrimSlots` route instead — the same route the AGGREGATE prims are admitted
on, where the runtime's own `Rt.+`/`Rt.-`/`Rt.*`/`Rt./`/`Rt.<`/`Rt.=` reach
their operands through the layout-derived accessors (`payload`, `payload32`,
`mknum`, `tagis`).  So `+ - * < <= > >= =` are no longer listed here and are no
longer refused.

NOTHING REMAINS: `f/` LEFT THIS LIST (perf word-arm-floats), and it left the
same way the arithmetic family did — the refusal described a path that no longer
existed.  Its text said "its inline arm emits the heap-boxed float cell, which
does not exist under the word arm (and `Rt.f/` is float-only, so routing it to
the runtime would build the same cell)" — and BOTH halves are now false: the
cell exists (`storeWordFloatCell`), and `Rt.f/` is exactly `mkflt(fload(asF a)
f/ fload(asF b))`, i.e. the two writers this unit ported.  So `f/` needs no
emitter change at all: `lowerPrimApp`'s inline branch is already denied on this
arm by `isFloatExp` (which is `s.rep && not (wordArm s) && ..`, the ONE place
the arm is read for the raw-float pass), so the prim falls through to the
ordinary `rtPrimSlots` route into `Rt.f/`.  MEASURED: `floatdiv` (7.0 / 2.0) and
`floatpartial` (`((/) 7.0) 2.0`, whose refusal named the generated `/.curried`
defun) both emit, link and print `3.5` on both arms, byte-identically.

THE LIST BELOW IS THEREFORE EMPTY, and that is stated rather than left to be
inferred: it protects NOTHING today.  It stays because it is the seat the NEXT
inline, representation-shaped prim must be listed in on the day it is written —
a memberless belt is a reminder, not a guarantee.

A prim NOT listed here and carrying a Mid implementation takes the plain
`rtPrimSlots` route, which is arm-clean (see the `PrimApp` case above).  A prim
with NO Mid implementation has no arm-clean route at all on this tree
(`rtPrimSlotsZig` emits `rt_prim_*` symbols the runtime no longer defines), so
it refuses here rather than at the linker.
-}
wordArmPrimUnported : String -> List String
wordArmPrimUnported prim =
    if List.member prim wordArmInlinePrims then
        [ wordArea "AREA 5 (FLOATS)" ("the primitive `" ++ prim ++ "` — its inline arm emits the heap-boxed float cell, which does not exist under the word arm (and `Rt.f/` is float-only, so routing it to the runtime would build the same cell)") ]

    else if MidRt.primImpl prim == Nothing then
        [ wordArea "AREA 4 (ARITHMETIC)" ("the primitive `" ++ prim ++ "` — it has no Mid implementation, so it has no arm-clean route (the Zig fallback would emit rt_prim_* symbols the runtime no longer defines)") ]

    else
        []


{-| The prims `lowerPrimApp` gives an inline, representation-shaped arm to AND
that the word arm must therefore not reach.

EMPTY, AND DELIBERATELY SO.  `+ - * < <= > >= =` left it at perf
word-arm-arith, in the same commit that made `lowerPrimApp` skip their inline
arms under the word arm, because the list and the fork are two halves of one
decision and a list entry without the fork is a refusal of a construct the arm
now gets RIGHT.  `f/` — the last member — left it at perf word-arm-floats, when
the float cell it was refused for landed.  So an entry here is only ever added
together with the arm fork that makes the inline arm unreachable.
-}
wordArmInlinePrims : List String
wordArmInlinePrims =
    []


{-| THE TAG OF THE VALUE WHOSE ADDRESS IS `base`, into the `w` temp `t`
(perf VR3b2, area 2).

val arm: the tag is a whole WORD at offset 0 of the Value.
word arm: the tag is the value word's LOW BITS (`tagMask`), so the word is
loaded and masked.  `%t =w and %l, 7` is legal QBE (an `l` value in a `w` context is
its low 32 bits) and the vendored qbe lowers it to `andl $7, %eax` — MEASURED.

This is the ONE place a tag is read, so "a tag test is `and`+compare" is a fact
about the emitter rather than a convention each site re-implements.
-}
readTag : String -> Il.Arg -> S -> S
readTag t base s =
    if wordArm s then
        let
            ( v, s1 ) =
                freshTmp s
        in
        s1
            |> emit (Load (Just v) L LoadL base)
            |> emit (Bin (Just t) W And (Il.Tmp v) (Il.Con s.layout.tagMask))

    else
        emit (Load (Just t) W LoadW base) s


wordArea : String -> String -> String
wordArea area what =
    area ++ " — " ++ what


{-| Drop repeated lines, keeping the first occurrence's position.  A key can be
reached twice (the same defun under two keys), and a refusal that names the same
construct twice reads as two blockers.  O(n^2) on a list of tens — the walk that
produced it is far more expensive.
-}
dedupStrings : List String -> List String
dedupStrings xs =
    List.reverse
        (List.foldl
            (\x acc ->
                if List.member x acc then
                    acc

                else
                    x :: acc
            )
            []
            xs
        )


{-| The same classifier over the whole reachable SURFACE, returning EVERY
un-ported construct (one `defun: AREA ..` line each), not just the first.
Rt keys are not walked here — they are refused by the area-7 gate below, which
states a stronger fact.

WHY THE WHOLE LIST AND NOT THE FIRST (perf word-arm-frontier, MEASURED).  The
first-only form is not merely terse, it is MISLEADING as a planning instrument:
it reports the refusal that comes first in `surfaceKeys` order, so a program
carrying BOTH a constructor-tag pattern and a constructor application is counted
as blocked by the pattern.  MEASURED over the 159 corpus groups: the
first-refusal table named 26 groups `MTagEq`-blocked and 14 `Con`-blocked, while
the source of all 26 shows `Ok`/`Err`/`Just` APPLIED — porting `MTagEq` alone
would have moved none of them.  A ranking can only be built from the set.

NOTHING IS RELAXED: a non-empty list refuses before any IL is produced, exactly
as a `Just` did.  The order is preserved (surface key order, then walk order
within a defun), so the first line is still the construct the port is actually
about — and EVERY construct is listed, per defun as well as per group (perf
word-arm-frontier review, item 1: the per-defun answer used to be first-only,
which is what let the census promise a group the named class could not move).
-}
wordSurfaceUnported : Dict String Defun -> List String -> List String
wordSurfaceUnported defuns keys =
    wordSurfaceUnportedWith wordArmDefunRefusals defuns keys


{-| THE SAME WALK WITH THE REFUSAL LIST AS A PARAMETER (perf word-arm-corpusrun,
the review's SHOULD-FIX 2).  It exists because the LIST is now EMPTY, and a pin
that calls `wordSurfaceUnported` with the shipped list cannot test the audit-list
branch at all: its "planted entry" assertion was implied by the emptiness of the
very list the branch consults, so DELETING the branch left the row green while
two comments claimed the row proved it.  A TAUTOLOGY IS NOT A TEST.  Threading
the list through lets the row plant an entry in a list the production path never
sees, which is the only shape that can observe the branch.
-}
wordSurfaceUnportedWith : List ( String, String ) -> Dict String Defun -> List String -> List String
wordSurfaceUnportedWith refusals defuns keys =
    List.concatMap (wordSurfaceUnportedOne refusals defuns) keys


wordSurfaceUnportedOne : List ( String, String ) -> Dict String Defun -> String -> List String
wordSurfaceUnportedOne refusals defuns k =
    if isRtKey k then
        -- An Rt key reached as the ENTRY (a TestMain probe into the runtime) is
        -- not a surface defun: it is refused wholesale by the area-7 gate, which
        -- states a stronger fact than "this node is un-ported".
        []

    else if List.any (\( rk, _ ) -> rk == k) refusals then
        -- THE AUDIT LIST IS CONSULTED FOR THE SURFACE TOO (perf
        -- word-arm-letdestr): a core-lib defun whose every construct is ADMITTED
        -- can still be wrong on this arm, and the refusal has to name it.  The
        -- list is EMPTY since perf word-arm-hostpath (its last entry,
        -- `Runtime.program`, is ported) — the arm remains live, and TestMain
        -- proves it by planting an entry through `wordSurfaceUnportedWith`, which
        -- is why this branch takes the list as a PARAMETER rather than reading
        -- the constant.
        List.map (\why -> k ++ ": " ++ why) (List.filterMap (\( rk, why ) -> if rk == k then Just why else Nothing) refusals)

    else
        case Dict.get k defuns of
            Nothing ->
                []

            Just defun ->
                case defun.value of
                    Lam lambda ->
                        List.map (\what -> k ++ ": " ++ what) (wordArmUnportedList lambda.body)

                    _ ->
                        [ k ++ ": a defun with a non-Lambda value (corrupt Mid tree)" ]


{-| THE DEFUNS THAT REFUSE BY NAME UNDER THE WORD ARM EVEN THOUGH EVERY
CONSTRUCT INSIDE THEM IS ADMITTED, with the reason — Rt defuns AND core-lib
surface defuns (`wordSurfaceUnportedOne` consults this list too, since perf
word-arm-letdestr).

WHY THIS LIST EXISTS AT ALL: the classifier is per-CONSTRUCT, so it cannot state
"this whole defun is wrong for a reason that is not a construct".

WHY A LIST AND NOT A SITE REFUSAL.  A site refusal only fires where a construct is
un-ported; these defuns contain NO refusing construct — every element access in
them is right-kind after `vecbody` — yet they are still wrong on the word arm
because they reach a SECOND array whose placement the arm has not decided. The
record family is exactly that: `payload(rec, 2)` is the field-NAMES array, and a
word-arm record body is a flat run of `count` Values, so where the names live
(after the data? in a second block? interleaved?) is a LAYOUT, not a stride. A
read that is merely unreachable today is what the polarity forbids shipping, so
these refuse LOUDLY until the record-layout unit lands.

THE AUDIT THAT PRODUCED IT (not recall): every `payload(x, <n>)` / `reclen(..)`
site in the word-spliced text with a non-zero word index, grouped by defun —
`grep -nE "payload\([a-zA-Z0-9_]+, [1-9]\)"` on the spliced text. The names-side
reads are runtime.mid's recGetGo/recUpdFind/recAppendFind/recAppendNamesGo/
recToChainGo (plus recUpd/recAppend, which BUILD the record), and the compiler
side has one more (`recordAccessBody`, guarded separately). Nothing else in the
runtime reads a non-zero payload word of a heap object: the closure's field 2 and
the stream's word 1 are BODY units, which is the same number on both arms.

TEN ENTRIES, NOT TWELVE (perf word-arm-records R3): `Rt.recGet`/`Rt.recGetGo`
LEFT the list in the commit that ported the READ.  Each now carries a
`QBE_WORDVAL-ONLY` splice that reads the names base from the record's LAST body
word and bounds by `veclen - 1` (the layout's own length reader), so the reason
above — a layout not decided — is no longer true OF THEM; the CHAIN half
(`recToChain`/`recToChainGo`) was the last holdout, and it is now twinned too
(perf word-arm-records R4): its car is a genuine Value position, so the word
twin MATERIALIZES a symbol cell per element and walks the SAME one-block
layout.  The list is now EMPTY — every `Rt.rec*` defun the record family owns
is ported to the word arm.
-}
wordArmDefunRefusals : List ( String, String )
wordArmDefunRefusals =
    []


-- THE LIST IS EMPTY, AND THAT IS THE MEASURED STATE (perf word-arm-hostpath).
--
-- Its LAST entry was `Runtime.program` — THE HOST PROGRAM PATH, 7 corpus groups,
-- the only class left in the census.  It was the first entry that was not a
-- construct: every node inside `Runtime.program` was already admitted, and the
-- defun was wrong for a reason the per-construct classifier cannot see, namely
-- that the HOST EVENT LOOP it feeds kept its state in ONE malloc'd blob laid out
-- with the val arm's 40-byte Value stride.
--
-- THAT IS NOW TWINNED, and the reason is worth recording because it was NOT the
-- literal the old text named.  The stride's origin is `struct Host`'s
-- `slots : val[33031]` — the ONE `val` field in the whole runtime — and
-- `Mid.RtLang.Check` sizes a `val` field at 40 bytes under any knob, so twinning
-- `Rt.hostInit`'s malloc alone would have sized the blob SMALLER than the field
-- offsets the checker writes into it.  The word arm's `struct Host` therefore
-- carries `slots : word[33031]` (spliced), and the blob, the five scratch cells,
-- the eval `base` slots, `Rt.apply-at`'s argument slice and `Rt.callArity`'s
-- `rt_callN` pitch all moved with it: 54 stride lines in three defun families
-- (see `tools/qbe/WORD-ARM-FRONTIER.md`'s STEP-0 table — the circulating counts
-- of 32, 29 and "about 30" were all undercounts of the same family, and none of
-- them included `Rt.callArity`).
--
-- THE LIST ITSELF STAYS.  An empty list is the honest value, not a dead seat: it
-- is the only mechanism the classifier has for "this whole defun is wrong for a
-- reason that is not a construct", and deleting it would delete the next such
-- reason's home.  TestMain pins BOTH directions — the list is empty, AND a
-- defun-level refusal placed in it still refuses by name through
-- `wordSurfaceUnported`/`wordRtUnported` — so the seat is proven live rather
-- than merely present.


{-| THE Rt SURFACE, CLASSIFIED BY THE SAME PRE-WALK WHITELIST (perf VR3b3).

VR3b2 refused any program that reached `runtime.mid` WHOLESALE, and the reason
it gave was true then: the runtime's stride-carrying defuns assumed 40-byte
values.  VR3c twinned those strides, so that reason is now stale, and a blanket
refusal cannot say WHERE a word-arm program actually stops — it reports the lane
boundary instead of the construct, which is exactly what the next unit does not
need.

So the Rt set is walked with the SAME `wordArmUnported` classifier the surface
gets, and the first Rt defun carrying an un-ported construct is named.  NOTHING
IS RELAXED: a word-arm emit still cannot happen unless EVERY reachable Rt defun
is fully ported, and an un-ported construct still refuses by name, before any IL
is produced.  What changes is only the PRECISION of the refusal: it now names
the defun and the construct (`Rt.main: AREA 6 (THE CALL ABI)`) instead of the
whole namespace.
-}
wordRtUnported : Dict String Defun -> List String -> List String
wordRtUnported defuns keys =
    List.concatMap (wordRtUnportedOne defuns) keys


wordRtUnportedOne : Dict String Defun -> String -> List String
wordRtUnportedOne defuns k =
    if isRtKey k then
        case List.filter (\( rk, _ ) -> rk == k) wordArmDefunRefusals of
            ( _, why ) :: _ ->
                [ k ++ ": " ++ why ]

            [] ->
                wordRtUnportedBody defuns k

    else
        wordRtUnportedBody defuns k


wordRtUnportedBody : Dict String Defun -> String -> List String
wordRtUnportedBody defuns k =
    case Dict.get k defuns of
        Nothing ->
            []

        Just defun ->
            case defun.value of
                Lam lambda ->
                    List.map (\what -> k ++ ": " ++ what) (wordArmUnportedList lambda.body)

                _ ->
                    [ k ++ ": a defun with a non-Lambda value (corrupt Mid tree)" ]


wordAreaName : Exp -> String
wordAreaName exp =
    case exp of
        App _ ->
            "AREA 6 (THE CALL ABI)"

        PrimApp _ ->
            "AREA 4 (ARITHMETIC)"

        Case _ ->
            "AREA 2 (TAG TESTS)"

        If _ ->
            "AREA 2 (TAG TESTS)"

        ShortAnd _ ->
            "AREA 2 (TAG TESTS)"

        ShortOr _ ->
            "AREA 2 (TAG TESTS)"

        NotEqual _ ->
            "AREA 2 (TAG TESTS)"

        Con _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        Tup _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        RecordLit _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        RecordGet _ _ ->
            "AREA 3 (PAYLOAD ACCESS)"

        RecordUpdate _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        ListLit _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        StreamRef _ ->
            "AREA 3 (HEAP-OBJECT CONSTRUCTION)"

        Loop _ ->
            "AREA 2 (TAG TESTS)"

        Break ->
            "AREA 2 (TAG TESTS)"

        Continue ->
            "AREA 2 (TAG TESTS)"

        Unsafe node ->
            rawNodeArea node

        _ ->
            "AN UNPORTED CONSTRUCT"


{-| WHICH WORKLIST AREA A REFUSED RAW NODE BELONGS TO.  `rawNodeName` says what
it is; this says which port it waits on, so the refusal is a worklist entry and
not a shrug.  The admitted families (payload, tag, alloc seats, vec, byte, the
raw WORD family, static data, C calls) never reach this.
-}
rawNodeArea : UnsafeNode -> String
rawNodeArea node =
    case node of
        RawCall _ ->
            "AREA 6 (THE CALL ABI)"

        RawCallAgg _ ->
            "AREA 6 (THE CALL ABI)"

        RawAllocN _ ->
            "AREA 6 (THE CALL ABI)"

        RawTailCall _ ->
            "AREA 6 (THE CALL ABI)"

        RawFltBin _ ->
            "AREA 5 (FLOATS)"

        RawFltCmp _ ->
            "AREA 5 (FLOATS)"

        RawIToF _ ->
            "AREA 5 (FLOATS)"

        RawLoadFlt _ ->
            "AREA 5 (FLOATS)"

        _ ->
            "AREA 3 (PAYLOAD ACCESS)"


wordAreaWhat : Exp -> String
wordAreaWhat exp =
    case exp of
        App _ ->
            "a call — its argument staging, `:ret` aggregate and .tail metadata are not ported"

        PrimApp _ ->
            -- Effectively unreachable now that the arithmetic class is ported:
            -- `wordArmPrimUnported` names the prim and its own area, and every
            -- other PrimApp takes the `rtPrimSlots` route.  Kept truthful
            -- anyway, because a refusal that lies about its cause is worse than
            -- none.
            "a primitive application — a prim with no Mid implementation, or the float-only `f/` (see `wordArmPrimUnported`, which names it)"

        Case _ ->
            "a case — every alternative is a tag test, and under the word arm a tag test is `and`+compare (immediates) or a header-kind read (heap objects)"

        If _ ->
            "an if — the condition is a tag test on the boolean value"

        ShortAnd _ ->
            "`&&` — a tag test on the boolean value"

        ShortOr _ ->
            "`||` — a tag test on the boolean value"

        NotEqual _ ->
            "`/=` — a tag test plus a payload compare"

        Con _ ->
            "a constructor application — under the word arm a heap object is one tagged pointer, not a tag word plus payload words"

        Tup _ ->
            "a tuple — a heap object under the word arm"

        RecordLit _ ->
            "a record literal — a heap object under the word arm"

        RecordGet _ _ ->
            "a record field read — a payload access"

        RecordUpdate _ ->
            "a record update — a heap object plus payload accesses"

        ListLit _ ->
            "a list literal — a cons chain of heap objects"

        StreamRef _ ->
            "a stream reference — it materialises a symbol Value"

        Loop _ ->
            "a loop — its condition is a tag test"

        Break ->
            "`break` inside a loop"

        Continue ->
            "`continue` inside a loop"

        Unsafe node ->
            "the raw node `" ++ rawNodeName node ++ "`"

        _ ->
            "a construct the word arm has not ported"


{-| The VAL-arm entry point — the layout this whole tree has always emitted,
and what every existing caller (TestMain's pins included) means by `lower`.

Spelled as a FULL application and not as `lower = lowerWith RtLayout.valLayout`:
a top-level PARTIAL application of a 16-parameter defun is a shape nothing in
this tree compiles today (this entry is unreachable from the self-host manifest,
so the fixed point never lowers it), and VR3b1 already paid once for shipping a
shape no oracle exercised.
-}
lower : MidRt.Runtime -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> QbeTypes.Table -> Dict String Int -> List Defun -> String -> Result String Il.Module
lower runtime rep primDirect midCons rtLean consArr rec typeSpec midGc midGcYoung leafFree table arityTable program entryKey =
    lowerWith RtLayout.valLayout runtime rep primDirect midCons rtLean consArr rec typeSpec midGc midGcYoung leafFree table arityTable program entryKey


{-| The SAME lowering, FOR A GIVEN LAYOUT INSTANCE (VR3b1).  The instance is
selected at the SEED (here) and not at the ~150 emit sites: that is exactly
what VR3a's `S.layout` threading was for.  The knob plumbing is
`QBE_NOLEAF`/`QBE_NOMONO`'s, copied — run.js reads the env, Main's flags carry
it, `Mid.QbeModule` hands it down, and the instance lands in `S.layout` at
`s0`.

VR3b1 refused the word arm HERE, in one place, before the reachability walk.
VR3b2 turned that into a PER-CONSTRUCT gate so the arm can be ported area by
area: the arm now walks the same path and refuses the first construct it has
not ported (`wordArmUnported` per defun — the whitelist — plus the Rt-surface
gate in `lowerArm`), so the loud error NAMES the construct that
stopped it instead of always naming area 1.  The invariant is unchanged: one
refusal means NO IL AT ALL.
-}
lowerWith : RtLayout.ValLayout -> MidRt.Runtime -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> QbeTypes.Table -> Dict String Int -> List Defun -> String -> Result String Il.Module
lowerWith layout runtime rep primDirect midCons rtLean consArr rec typeSpec midGc midGcYoung leafFree table arityTable program entryKey =
    lowerArm layout runtime rep primDirect midCons rtLean consArr rec typeSpec midGc midGcYoung leafFree table arityTable program entryKey


{-| The val arm's body.  Its 9th positional slot — spelled `_` — is the RETIRED
collector switch (zighost Z0): the Mid collector is the only collector, so no
arm here reads it.  The slot stays because `Mid.QbeModule.compileEntry` still
carries it in its call shape.  Nothing selects a collector; the slot is inert,
not a default.
-}
lowerArm : RtLayout.ValLayout -> MidRt.Runtime -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> QbeTypes.Table -> Dict String Int -> List Defun -> String -> Result String Il.Module
lowerArm layout runtime rep primDirect midCons rtLean consArr rec typeSpec _ midGcYoung leafFree table arityTable program entryKey =
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
                                -- THE WORD-ARM-ONLY SEATS (perf word-arm-area3rt):
                                -- seeded ONLY on the word arm.  MOST of the keys
                                -- exist in runtime.mid only inside a QBE_WORDVAL-ONLY
                                -- region, and the checker resolves a seeded key
                                -- against the spliced text and REFUSES an unknown
                                -- global (MEASURED: `unknown global Rt.kindHdr` the
                                -- moment the seat was seeded through a shared defun's
                                -- edge on the val arm).  NOT ALL OF THEM, though
                                -- (perf word-arm-letdestr): `Rt.symToStr` is an
                                -- always-present defun whose only caller is the WORD
                                -- arm's `Rt.value` splice, so it is seeded here for
                                -- the arm, not for its region — see
                                -- `Mid.Rt.wordArmSeeds`' "SECOND KIND" paragraph.
                                ++ (if layout.heapTagIsKind then
                                        List.filter (\k -> not (List.member k surfaceKeys)) (unique MidRt.wordArmSeeds)

                                    else
                                        []
                                   )
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
                    { layout = layout
                    , blocks = []
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
                    , -- Q1b: the MODULE-level seed.  False here and set per
                      -- defun by lowerFunBody: only an RtGeneric body may emit
                      -- a tcall, and nothing outside a defun body lowers an App.
                      tailEmit = False

                    -- U1: likewise module-level — no defun is being lowered, so
                    -- there is no frame for a `tailcall` guard to look at.
                    , pooledFrame = False
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
                -- half is pinned by the probe-midgc-* suite (19 scripts, run from
                -- the repo root).  THE EXAMPLE THIS SENTENCE USED TO NAME IS GONE:
                -- the transient `.tail` array (and `probe-midgc-tail.sh`, which
                -- pinned it) belonged to the `.tail` staging that U3a/U3b deleted —
                -- the apply chain now stages into ONE malloc'd block
                -- (`Rt.stage-apply`), freed on every exit of `Rt.applyTailGo`.
                -- THE Rt SURFACE GATE (perf VR3b2, worklist entry 7).  Every
                -- Rt.* defun is `runtime.mid` text written against the 40-byte
                -- layout — gcAlloc's `2 + count + 4*count*kind`, apply's
                -- `args + rem*40`, gcScav/copyWordsGo, the values table, argv,
                -- the printer — and VR3b2's write scope EXCLUDES runtime.mid
                -- (VR3c owns it, single-writer).  Lowering one of them under
                -- the word arm would emit a runtime whose own arithmetic reads
                -- 8-byte values at 40-byte strides.  So a word-arm program
                -- whose emitted set contains ANY Rt key is refused HERE,
                -- before a defun is lowered.
                --
                -- MEASURED consequence, stated so nobody mistakes the arm's
                -- reach: EVERY program compiled by run.js carries runtime.mid,
                -- and `MidRt.gcSeeds`/`conSeeds`/`closureSeeds` join the
                -- emitted set whenever the program carries any Rt defun at
                -- all — so under the word arm every real program stops HERE
                -- and only a runtime-free module (a TestMain probe, or a
                -- surface-only Mid program) can be emitted.  That is the
                -- honest state of the flip: area 7 is VR3c's, and until it
                -- lands the word arm cannot produce a runnable program.
                lowerKeys st0 =
                    List.foldl
                        (\key acc ->
                            acc
                                |> Result.andThen
                                    (\st ->
                                        case Dict.get key defuns of
                                            Nothing ->
                                                Err ("qbe: unknown global " ++ key)

                                            Just defun ->
                                                lowerDefun runtime defun st
                                    )
                        )
                        (Ok st0)
                        keys
                        |> Result.map (\sFinal -> finishModule sFinal keys)

                lowerAllKeys =
                    lowerKeys s0

                -- THE Rt SET, SAME CLASSIFIER (perf VR3b3): per-defun, so the
                -- refusal names the DEFUN and the CONSTRUCT the arm stops at.
                -- Loudness is unchanged — an un-ported construct anywhere in
                -- the reachable Rt set still refuses before any IL is produced.
                rtUnported =
                    if List.any isRtKey keys then
                        wordRtUnported defuns keys

                    else
                        []
            in
            -- ORDER MATTERS FOR THE ERROR, NOT FOR SAFETY.  The SURFACE
            -- constructs come first so a real program's refusal names the
            -- construct the port is actually about (area 2's tag write, area 4's
            -- arithmetic) instead of the blanket runtime gate; both refuse
            -- before any defun is lowered, so no IL is emitted.  BOTH SETS are
            -- reported (perf word-arm-frontier): the ranking a planning unit
            -- needs is over the SET of blockers, and the surface-only form hid
            -- every Rt blocker behind the first surface one.
            if wordArmLayout layout then
                case dedupStrings (wordSurfaceUnported defuns surfaceKeys ++ rtUnported) of
                    [] ->
                        lowerAllKeys

                    whats ->
                        Err (wordArmUnsupported (String.join "; " whats))

            else
                lowerAllKeys



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

        -- U1: a `tailcall` to a defun of this program is the same edge a
        -- `rawcall` to it is (and the same one `rtDeps` declares for the Rt
        -- lane); an extern target names no defun here.
        RawTailCall tc ->
            case tc.target of
                TailKey key ->
                    if Dict.member key defuns then
                        [ key ]

                    else
                        []

                TailSym _ ->
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

        RawVecBody r ->
            [ r.value ]

        RawVecLen r ->
            [ r.value ]

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

        RawTailCall tc ->
            tc.args

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
--   * a CLOSURE call (rt_apply -> rt_call2r) and a TAIL call (Rt.stage-tail ->
--     the callee) pass pointers into GC ARRAYS (`buf`, the closure
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
                    -- `lowerNotEqual` is `lowerNumEq` + a negated Boolean, and
                    -- `lowerNumEq`'s GENERIC tail calls `rtPrimSlots "="` —
                    -- which is the tail every operand pair takes except two
                    -- proven Ints (or two proven Floats).  So `=` must be
                    -- seeded here or the call site has no `Rt.=` to link
                    -- against.  MEASURED (perf word-arm-arith): without this
                    -- arm `if "a" /= "b" then ..` REFUSED TO COMPILE on the
                    -- VAL arm too, with the seed guard's own message — a
                    -- latent census miss this unit's `=` port surfaced, not a
                    -- word-arm problem.  Over-seeding the proven-Int case (where
                    -- the fast path emits no call) is the convention this
                    -- function already states at RecordGet.
                    Set.union (Set.singleton "=") (Set.union (go block.left) (go block.right))

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
            if List.length lambda.params > sOuter.layout.maxArity then
                Err ("qbe: defun " ++ defun.key ++ " has arity > " ++ String.fromInt sOuter.layout.maxArity ++ " (rt_callN table limit)")

            else if wordArm sOuter then
                -- perf VR3b2: the per-defun belt to the per-site braces — see
                -- `wordArmUnported`.  A defun containing a construct the arm
                -- has not ported is refused BEFORE its body walk, so a site
                -- missing its own gate cannot be reached.
                case wordArmUnported lambda.body of
                    Just what ->
                        Err (wordArmUnsupported what)

                    Nothing ->
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
-- Frame layout: slot 0 is the RESULT, then params, then captures, then temps.
-- U3b deleted the second result slot: slot 1 used to hold the `.tail` metadata
-- (kind/f/e/args/arity — the second half of the 80-byte `:ret` return), so a
-- frame's result area was `slotBase = 2`.  On the VALUE arm the result is
-- `:val` — one slot — so `slotBase` is 1 and every later slot moves down one.
-- It stays 2 on the WORD arm, whose frozen `:ret` return shape still has a
-- kind word (AREA 6; see `closureRetClass`).
-- Blocks: @start (prologue; jump @body), @body (loop head for self-tail),
-- ... interior ..., @ret (rt_frame_leave; ret %s0 — returns slot 0).
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

        -- AREA 6: does a value parameter arrive as a WORD (not a pointer)?
        -- Exactly the word arm's RtGeneric class — the closure ABI, whose
        -- callers (directCall, RawCall, the generated rt_callN) load the word
        -- out of the arg slot and pass it in the register.  The lean and
        -- rawAbi classes are Rt->Rt internal conventions and stay
        -- pointer/register as they were (their callee-side prologue blits, or
        -- reads the register directly, and both are arm-independent).
        paramWordsD =
            rt == RtGeneric && wordArm sOuter

        -- VR1: this defun reads its value params THROUGH the incoming `l`
        -- pointers instead of blitting them into its own frame at entry.
        -- Only a top-level RtGeneric defun with at least one value param is
        -- eligible (a closure body is called through rt_callN with GC-array
        -- pointers, and an Rt key's lean/word ABI has no `:val` params at all).
        --
        -- AREA 6: NEVER ON THE WORD ARM.  `%a<i>` there IS the value word, so
        -- a ptrRead body would dereference a fixnum as an address — the exact
        -- silent-wrong shape the arm's polarity forbids.  The walk that builds
        -- `sOuter.ptrRead` is arm-blind (it reasons about the val arm's
        -- pointers), so the arm is excluded HERE, at the one seat that decides.
        ptrReadD =
            entry
                && not rawAbi
                && not (wordArm sOuter)
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

        -- U3b: the result area's width — see `resultSlotBase`.
        slotBase =
            resultSlotBase sOuter.layout

        s0 =
            { blocks = []
            , curLabel = "start"
            , curBody = []
            , tmp = 0
            , lbl = 0
            , slot =
                -- VR1: a ptrRead defun's params occupy NO frame slots — the
                -- body reads them through `%a<i>`, so the params' slots are
                -- simply not reserved and the frame is N slots smaller (the
                -- memset at rt_frame_enter is proportional to it).
                if ptrReadD then
                    slotBase + ncaps

                else
                    slotBase + nparams + ncaps
            , binderSlots =
                Dict.fromList
                    ((if rawAbi then
                        -- rawAbi params are WORD registers, not frame slots —
                        -- the slot counter still reserves the params' slots so
                        -- the body's own temps get the SAME slot numbers as
                        -- every other Rt defun (the slots are simply never
                        -- written/read).
                        []

                      else if ptrReadD then
                        -- VR1: not frame slots either — s.paramPtr names them,
                        -- so an unhandled read path is a LOUD "unbound binder"
                        -- instead of a silent read of an unwritten slot.
                        []

                      else
                        List.indexedMap (\i p -> ( p.id, i + slotBase )) lambda.params
                     )
                        -- NOTE, because the two counters disagree on purpose: a
                        -- capture is numbered ABOVE the params
                        -- (nparams + slotBase + j) even under ptrReadD, whose
                        -- fresh-slot counter starts at slotBase + ncaps with NO
                        -- param reservation — so a ptrRead defun with captures
                        -- would hand out temps that collide with these slots.
                        -- That is unreachable, and reachable only from one place:
                        -- lowerDefun (:1528) passes captures = [] to EVERY entry
                        -- defun, so the capture list is always empty where
                        -- ptrReadD can be true.  If an entry defun ever gets
                        -- captures, the ptrRead slot base above must become
                        -- slotBase + nparams + ncaps to match.
                        ++ List.indexedMap (\j cid -> ( cid, nparams + slotBase + j )) captures
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
            , layout = sOuter.layout
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
            , -- Q1b: a `tcall` is legal exactly where OUR OWN return convention is
              -- the one the callee must produce into — abi1 forwards OUR hidden
              -- sret pointer to the callee and C4 re-checks that the two
              -- classes agree.  That is RtGeneric — every surface defun and
              -- every closure body — and nothing else: a lean body returns
              -- `:val`, a rawAbi word body a word, and a tcall from either is
              -- refused by the backend's C4 check (loudly, naming the
              -- condition), so Mid must not emit one there.
              --
              -- U3a moved the CLASS, not this rule: an RtGeneric body's return
              -- is now `:val` (see retTy), so its tcalls are `tcall :val`.
              tailEmit = rt == RtGeneric
            , -- U1: the frame CLASS, as `proKind` below decides it — the one
              -- fact `lowerRawTailCall`'s frame-leave guard needs.  Spelled as
              -- the same two-constructor case so the guard cannot drift from
              -- the prologue the defun actually emits.
              pooledFrame =
                case rt of
                    RtLeanFree ->
                        False

                    RtRawWord ->
                        False

                    _ ->
                        True
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
                    -- U3a — THE CLASS FLIP.  A surface defun / closure body
                    -- used to return the 80-byte `:ret` (`.done` | `.tail`),
                    -- because a tail call could only be expressed by RETURNING
                    -- a request for Rt.bounce to chase.  Nothing builds a
                    -- `.tail` any more (the apply chain `tcall`s, the static
                    -- arity-5+ sites went non-tail, and U3b deleted the
                    -- builders/chasers outright), so the closure ABI returns
                    -- the finished Value: 40 bytes,
                    -- `:val`.  That is what makes the F-site `tcall :val` into
                    -- Rt.apply-tail legal at abi1's C4 (the callee's class must
                    -- equal the enclosing body's).
                    --
                    -- The `@ret` block needs no change: an aggregate return is
                    -- "ret the ADDRESS of the block in slot 0" either way, so
                    -- only the declared TYPE and its width move.
                    closureRetClass sOuter

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
                                        -- The predicate is Mid.Qbe.Liveness's
                                        -- LINEAR tier: no allocation-capable
                                        -- call site anywhere in the defun (so
                                        -- no safepoint to be live across) and
                                        -- no frame address escaped it.  It is
                                        -- deliberately NOT the per-safepoint
                                        -- slot maps (P8's half): those need a
                                        -- backward CFG fixpoint, and a defun
                                        -- with no safepoint has nothing for
                                        -- that fixpoint to say.
                                        leaf =
                                            leafOk
                                                && Liveness.frameFree
                                                    (Liveness.classify
                                                        { nslots = s1.slot
                                                        , noCollect = sOuter.noCollect
                                                        , layout = s1.layout
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

                                    -- U3b: NO `Agg "ret"` ARM.  It was the
                                    -- 80-byte `.tail` blit (plus the P1a
                                    -- `free` of the malloc'd cell): the body
                                    -- left `mknum(retbuf)` in slot 0, this
                                    -- block read the pointer back out of the
                                    -- number's payload and copied 80 bytes
                                    -- into the sret area.  With `struct Ret`
                                    -- and `Rt.tail-known` deleted, no rawAbi
                                    -- key can return `:ret`, so every
                                    -- aggregate-returning rawAbi body takes the
                                    -- `Agg "val"` arm above — slot 0 IS the
                                    -- result and there is nothing to blit.

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
                        , paramWords = paramWordsD
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

        Unsafe (RawTailCall tc) ->
            -- U1 (handoff apply-chain): the DSL's own tail call.  This is the
            -- arm the construct exists for — `RawCall` below can only ever
            -- express a SELF-tail loop, and a cross-defun relay lowered to a
            -- `call` + `jmp @ret` keeps a frame per hop.
            lowerRawTailCall tc s

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
                                |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagBoolean))
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
                            Ok (emit (Blit src (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes) s)

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
        RawTailCall _ ->
            -- U1: unreachable for checked input — the DSL's J16 admits a
            -- `tailcall` only in TAIL position, and a value position would be
            -- asking a terminator for a value.  Loud rather than lowered into
            -- a slot the caller would then read.
            Err "qbe: a `tailcall` in a VALUE position — it is a TERMINATOR and produces no value (the DSL checker refuses this shape before lowering; reaching here is a compiler bug)"

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
            --
            -- AREA 3 (perf word-arm-area3rt): the ARM IS UNCHANGED — `elemAddr`
            -- strides by the layout and the blit width is `valSizeBytes`, so at
            -- 8 bytes this copies the one word that IS the element.  What the
            -- refusal that used to stand here was really about is the BASE: a
            -- word-arm site that computed one with `payload(v, 0)` gets element
            -- 0, not an array.  That is fixed at the SITES (runtime.mid's
            -- `vecbody(v)`, which is `payload(v, 0)` on the val arm and the
            -- BODY on the word arm), not by refusing the node — and the audit
            -- that makes it total is `vecbody`'s own contract.
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
                                    emit (Blit (Il.Tmp eT) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes) s3
                                )
                    )

        RawVecStore store ->
            -- Store the VALUE at vec[i] THROUGH the runtime's ONE barrier
            -- seat.  The stored value is lowered into a fresh ROOTED slot
            -- first — its address is the argument.
            -- `dest` is deliberately IGNORED: this node is an effect, and its
            -- let binder's slot stays zero (a valid Value; nothing reads it).
            -- AREA 3 (perf word-arm-area3rt): admitted on the same argument as
            -- RawVecLoad — the BASE is the sites' business (`vecbody`), and the
            -- seam (`Rt.vecStorePlain`/`Rt.vecStoreYoung`) is already twinned:
            -- 8-byte stride, one word stored, the barrier reading the block
            -- header at `-2` off the BODY.  The stored value is lowered into a
            -- fresh ROOTED slot first — its address is the argument, and it is
            -- an 8-byte slot on this arm.
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
            -- call.  QBE_NORTLEAN=1 restores the fat :val-args shape.
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
                                            |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
                                        )

                                else
                                    Err ("qbe: rawCall to " ++ call.sym ++ " stages arity " ++ String.fromInt (List.length slots) ++ " — the lean ABI passes 1.." ++ String.fromInt maxDirectArity ++ " pointer args")

                            else
                                let
                                    ( operands, s2 ) =
                                        argOperands slots s1

                                    ( rp, s3 ) =
                                        freshTmp s2
                                in
                                -- U3a: the generic-ABI callee returns the
                                -- finished `:val` (no `.done`/`.tail` pair to
                                -- unwrap), so there is no bounce here either —
                                -- the same flip as directCall's non-tail arm.
                                -- AREA 6: and the arguments cross through the
                                -- SAME fork (`argOperands`) — address on the
                                -- value arm, value word on the word arm.
                                Ok
                                    (emit (Call (Just rp) (closureRetClass s) (Il.Sym ("q_" ++ mangle call.sym)) operands) s3
                                        |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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

        RawVecBody _ ->
            Err wordProducerMessage

        RawVecLen _ ->
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
            -- This is how the driver turns rt_callN/rt_call2r's sret results
            -- into Values.  Only shape "val"
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
                                |> emit (Blit (Il.Tmp t) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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


-- ==================== THE WORD ARM'S CELL WRITER AND READERS (VR3b3) ====================
-- AREA A (the writer below) and AREA B (the readers).  EVERY number here comes
-- from `Mid.RtLayout`'s word-arm heap contract — `heapPtrTag`, `untagMask`,
-- `tagBits`, `heapHeaderBytes`, `heapHeaderOffset`, `heapBodyUnitOffset` — and
-- none is spelled: a
-- literal 1 / 3 / 8 / 16 / 24 in this section would be a second statement of
-- the layout, which is the failure this arc exists to prevent.
--
-- THE SHAPE.  A word-arm Value is ONE word, and untagging it (`w AND
-- untagMask`) yields the BODY, with the 2-word GC header `heapHeaderOffset`
-- (= -16) BEFORE it (RtLayout's THE CONVENTION, which is the RUNTIME's: a seat
-- returns `mknum(body)`).  A 40-byte Value's payload read is NOT that shape and
-- neither is a shifted field offset: the val arm's `payloadWordOffset` (a tag
-- word then payload words) has no word-arm meaning at all, which is why every
-- read below is a `if wordArm s then <body shape> else <record shape>` fork.


{-| The VALUE WORD at a slot address, into a fresh `l` temp. -}
wordValueWord : Il.Arg -> S -> ( String, S )
wordValueWord base s =
    let
        ( v, s1 ) =
            freshTmp s
    in
    ( v, emit (Load (Just v) L LoadL base) s1 )


{-| UNTAG: THE BODY ADDRESS of a word-arm heap object — the untagged word IS
the body, because a seat returns `mknum(body)` and the 2-word GC header sits
`heapHeaderOffset` (= -16) BEFORE it (`RtLayout`'s THE CONVENTION, aligned to
`runtime.mid`'s gcAlloc on the owner's decision).  On the val arm this is the
identity — `untagMask` is all ones — so the function is total, and only the
word arm ever calls it. -}
wordBodyOf : Il.Arg -> S -> ( String, S )
wordBodyOf valueWord s =
    let
        ( b, s1 ) =
            freshTmp s
    in
    ( b, emit (Bin (Just b) L And valueWord (Il.Con (RtLayout.untagMask s.layout))) s1 )


{-| The header's KIND CODE of a word-arm heap object, into a `w` temp — the ONE
reader of bits `heapKindShift..heapKindMask` in the emitter.

It ALSO refuses code 0 BY NAME (VR3b3 area C, discharging VR3c's promissory
note).  Code 0's single owner is NO CODE — a val-arm header — and no word-arm
allocator writes it (`Rt.allocKind` refuses 0 at run time).  So a word-arm
reader that meets 0 has been handed a val-arm block or uninitialised memory;
returning "not the code you asked for" would be the silent read of another
layout's bytes.  The die is emitted by the CALLER, which owns the block
structure; this function only computes the code and the "is it 0" flag.
-}
wordKindCode : Il.Arg -> S -> ( String, String, S )
wordKindCode valueWord s =
    let
        ( body, s1 ) =
            wordBodyOf valueWord s

        ( hdrA, s2 ) =
            freshTmp s1

        ( hdr, s3 ) =
            freshTmp s2

        ( code, s4 ) =
            freshTmp s3
    in
    ( code
    , hdr
    , s4
        -- THE HEADER IS `heapHeaderOffset` (= -16) FROM THE BODY, never at the
        -- body and never at a block base: a seat RETURNS the body, so the two
        -- header words precede it.  MEASURED (found by RUNNING): reading AT the
        -- untagged address saw the body's first word as a "header" (code 0) and
        -- refused a good cons; reading `block - 16` was off by a whole object.
        |> emit (Bin (Just hdrA) L Add (Il.Tmp body) (Il.Con (RtLayout.heapHeaderOffset s.layout)))
        |> emit (Load (Just hdr) L LoadL (Il.Tmp hdrA))
        |> emit (Bin (Just code) W Shr (Il.Tmp hdr) (Il.Con s.layout.heapKindShift))
        |> emit (Bin (Just code) W And (Il.Tmp code) (Il.Con s.layout.heapKindMask))
    )


{-| WHICH CODES THE WORD ARM'S CELL WRITER CAN WRITE — the ONE statement of it,
so the writer and every caller that can refuse at COMPILE time (the `mk*` path,
which returns `Result`) cannot disagree about what is ported.

The immediates (number, boolean, nil, error) need no heap object.  A STRING is
written here as a whole cell: its body is RAW (`heapKindScanned` false), so the
two raw words it carries (byte pointer, length) are never traced by the
collector and the cell is sound.  Every other heap code is writable ONLY as
`mkval(code, bodyBase)` — ONE word, the body its own Mid seat already allocated
and filled (the seat-return convention, perf word-arm-area3rt) — because a body
the emitter laid out itself would put the val arm's raw pointers into a body the
collector SCANS.  The WORD COUNT is therefore part of the judgment, not just the
code: `wordCellRefusal code wordCount`.
-}
wordCellRefusal : Int -> Int -> Maybe String
wordCellRefusal code wordCount =
    case RtLayout.wordTagShape code of
        RtLayout.WordNoForm why ->
            Just ("a cell with " ++ why)

        RtLayout.WordImmediate _ ->
            Nothing

        RtLayout.WordHeapCode c ->
            if c == RtLayout.tagString then
                Nothing

            else if wordCount == 1 then
                -- THE SEAT-RETURN CONVENTION (perf word-arm-area3rt).  ONE word
                -- means the CALLER already allocated the body through the
                -- code's Mid seat — `Rt.allocCons`/`allocKind`/`allocVector`
                -- return `mknum(body)` and write the 2-word header INCLUDING
                -- this code — so the cell writer's whole job is the tag
                -- (`body OR heapPtrTag`).  The scan contract is then the
                -- ALLOCATOR's (the scan bit is derived from the code by
                -- `Rt.kindHdr`), which is exactly why this is sound: the
                -- emitter is not inventing a body, it is tagging one.
                Nothing

            else
                Just
                    ("a heap cell with the kind code "
                        ++ String.fromInt c
                        ++ " and "
                        ++ String.fromInt wordCount
                        ++ " payload words - a word-arm heap cell is written by its ALLOCATOR (one word: the body the seat returned), because a body the emitter laid out itself would have to carry the val arm's raw pointers into a body the collector SCANS. Settle the layout in runtime.mid's constructor, not here"
                    )


{-| THE WORD ARM'S CELL WRITER (perf VR3b3, area A) - the ONE place the emitter
writes a Value word.

The val arm writes a 40-byte record (a tag word then payload words).  The word
arm writes ONE word, and WHICH word depends on the code's SHAPE
(`RtLayout.wordTagShape`):

  * `WordImmediate` - the code's word encoding is a tag, not a heap object: a
    number is the i61 fixnum (`n` shifted up into the tag's free low bits), a
    boolean is `tagTrue + (x == 0)` (there is no payload word to carry the
    flag), nil and error are the tag alone.  NOTHING is allocated.
  * `WordHeapCode` - a heap object: allocate through the code's Mid seat, write
    the body through `heapBodyUnitOffset` (the seat RETURNS the body), and store
    `body OR heapPtrTag` - the 2-word GC header is the SEAT's, at
    `heapHeaderOffset` (16 bytes) BEFORE the body, so no site here computes a
    header address or subtracts one.  The header's KIND CODE is written by the
    seat (`Rt.kindHdr`), which is why the seat call is the place the code is
    named, not a second store here.

Which codes are writable is `wordCellRefusal`'s ONE statement; this function
implements exactly that set.  A heap code whose body would have to carry a RAW
word into a body the collector SCANS is refused there: inlining the body changes
the object graph the collector walks, and keeping the val arm's
pointer-in-payload makes the body word an address the scanner reads as a fixnum,
i.e. an object nothing keeps alive.  That is a heap-LAYOUT decision
(runtime.mid's constructors + the scan contract), so it refuses rather than
emits something that links and corrupts.
-}
storeWordCell : Int -> List Il.Arg -> Int -> S -> Result String S
storeWordCell code words dest s0 =
    case RtLayout.wordTagShape code of
        RtLayout.WordNoForm why ->
            Err (wordArmUnsupported (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)" ("a cell with " ++ why)))

        RtLayout.WordImmediate tags ->
            case words of
                [] ->
                    -- nil / error: the tag ALONE is the value.
                    Ok (emit (Store StoreL (Il.Con (Maybe.withDefault 0 (List.head tags))) (Il.Tmp (slotTmp dest))) s0)

                [ w ] ->
                    if code == RtLayout.tagNumber then
                        -- A FIXNUM: the value is shifted UP into the bits the
                        -- tag leaves free (the exact inverse of the reader's
                        -- SAR).  Inline, no runtime call, no allocation.
                        --
                        -- AREA 4 (perf word-arm-area4): THE ONE OVERFLOW CHECK
                        -- PER ARITHMETIC WRITE, and now it BOXES instead of
                        -- refusing.
                        --
                        -- THE CHECK IS A ROUND TRIP, and that is what makes it
                        -- work for BOTH kinds of word this node is handed.  A
                        -- word-arm fixnum is an i61, so `w << 3 >> 3 == w`
                        -- exactly when `w` fits.  Two populations reach here:
                        --
                        --   * a NUMBER that may be out of range — the result of
                        --     an arithmetic op, which is the case this unit
                        --     exists for; it fails the round trip and is BOXED;
                        --   * a POINTER carried as a fixnum — the seat-return
                        --     convention (`mknum(body)`, `mknum(cell + 16)`,
                        --     `mknum(buf)`), which is how EVERY heap address in
                        --     the runtime travels.  A user-space address on
                        --     x86-64 is below 2^47, so `p << 3` cannot overflow
                        --     and the round trip HOLDS: a pointer never boxes.
                        --     That is a PRECONDITION of this arm and it is
                        --     stated as one, not assumed: the check COMPUTES the
                        --     answer, and the only thing taken on faith is that
                        --     no heap address reaches 2^60 (the address space
                        --     does not allow it).
                        --
                        -- SO THE FAILURE BRANCH IS THE BOXING SEAT.  `Rt.boxInt`
                        -- allocates a code-13 cell holding the raw i64, which is
                        -- why `wordMkAllocSeat` names it for `tagNumber` and why
                        -- every defun whose only allocation is a `mknum` is now
                        -- ROOTED on the word arm (the third place the
                        -- `mk*`-as-safepoint rule has had to hold).
                        case w of
                            Il.Con n ->
                                if n < 0 - RtLayout.wordFixnumLimit || n >= RtLayout.wordFixnumLimit then
                                    -- A COMPILE-TIME constant outside i61.  `n`
                                    -- is host-exact (it is a double that came
                                    -- from a host Int), so the i64 is rebuilt
                                    -- from base-2^26 LIMBS rather than emitted
                                    -- as an `Il.Con` — `String.fromInt` prints
                                    -- 2^60 as 1152921504606847000 (MEASURED), so
                                    -- a `Con` at this magnitude is a different
                                    -- number wearing the right spelling.
                                    let
                                        ( v, s1 ) =
                                            emitExactWord n s0
                                    in
                                    Ok (boxWordInt v dest s1)

                                else
                                    Ok (emit (Store StoreL (Il.Con (n * 8)) (Il.Tmp (slotTmp dest))) s0)

                            _ ->
                                let
                                    ( sh, s1 ) =
                                        freshTmp s0

                                    ( back, s2 ) =
                                        freshTmp s1

                                    ( fits, s3 ) =
                                        freshTmp s2

                                    ( okLbl, s4 ) =
                                        freshLbl "fixok" s3

                                    ( boxLbl, s5 ) =
                                        freshLbl "fixbox" s4

                                    ( joinLbl, s6 ) =
                                        freshLbl "fixjoin" s5
                                in
                                Ok
                                    (s6
                                        |> emit (Bin (Just sh) L Shl w (Il.Con s0.layout.tagBits))
                                        |> emit (Bin (Just back) L Sar (Il.Tmp sh) (Il.Con s0.layout.tagBits))
                                        |> emit (Cmp (Just fits) L Ceq (Il.Tmp back) w)
                                        |> closeBlock (Jnz (Il.Tmp fits) okLbl boxLbl)
                                        |> startBlock boxLbl
                                        |> (\st -> boxWordInt w dest st)
                                        |> jumpTo joinLbl
                                        |> startBlock okLbl
                                        |> storeWordWord (Il.Tmp sh) dest
                                        |> jumpTo joinLbl
                                        |> startBlock joinLbl
                                    )

                    else if code == RtLayout.tagBoolean then
                        -- A BOOLEAN: one bit of information, TWO immediates
                        -- (`booleanSplit`), so `tagTrue + (w == 0)` is
                        -- branch-free: true when the word is non-zero, false
                        -- when it is zero.
                        let
                            ( isZero, s1 ) =
                                freshTmp s0

                            ( isZeroL, s2 ) =
                                freshTmp s1

                            ( v, s3 ) =
                                freshTmp s2
                        in
                        Ok
                            (storeWordWord (Il.Tmp v) dest
                                (s3
                                    -- QBE's compare produces a `w` temp even at
                                    -- `l` width, and a `w` temp may not be the
                                    -- first operand of an `l` op (MEASURED:
                                    -- `invalid type for first operand %t in
                                    -- add` - the text pins could not see this,
                                    -- the assembler could), so the flag is
                                    -- widened before it is added.
                                    |> emit (Cmp (Just isZero) L Ceq w (Il.Con 0))
                                    |> emit (Unary (Just isZeroL) L Extsw (Il.Tmp isZero))
                                    |> emit (Bin (Just v) L Add (Il.Tmp isZeroL) (Il.Con s0.layout.tagTrue))
                                )
                            )

                    else
                        Err (wordArmUnsupported (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)" ("a cell with the code " ++ String.fromInt code ++ " and one payload word - that code's word encoding is a bare immediate and has no payload")))

                _ ->
                    Err (wordArmUnsupported (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)" ("a cell with the code " ++ String.fromInt code ++ " and " ++ String.fromInt (List.length words) ++ " payload words - that code's word encoding is a single immediate and has no payload")))

        RtLayout.WordHeapCode c ->
            if c == RtLayout.tagString then
                storeWordStringCell words dest s0

            else if c == RtLayout.tagFloat then
                storeWordFloatCell words dest s0

            else
                case words of
                    [ body ] ->
                        -- THE SEAT-RETURN CONVENTION, WRITTEN DOWN (perf
                        -- word-arm-area3rt).  ONE word means the caller has
                        -- ALREADY allocated and filled the body through the
                        -- code's Mid seat (`Rt.allocCons`/`allocKind`/
                        -- `allocVector`, which return `mknum(body)` and write
                        -- the 2-word header INCLUDING this code) — so the only
                        -- thing left is the tag: `body OR heapPtrTag`.
                        --
                        -- This is NOT the val arm's shape.  There, `mkval(code,
                        -- w0, w1, ..)` writes a 40-byte Value whose payload
                        -- words ARE w0, w1, ..; here the words are not a body,
                        -- the CALLER's allocation is.  A site passing more than
                        -- one word is therefore still refused below: it has not
                        -- allocated a body, and inventing one here would be the
                        -- layout decision `wordCellRefusal` exists to keep out
                        -- of the emitter.
                        let
                            ( w, s1 ) =
                                freshTmp s0
                        in
                        Ok
                            (s1
                                |> emit (Bin (Just w) L Or body (Il.Con (RtLayout.heapPtrTag s1.layout)))
                                |> storeWordWord (Il.Tmp w) dest
                            )

                    _ ->
                        -- The defun is NAMED: a site refusal is only useful if
                        -- the reader knows which runtime defun has not been
                        -- twinned yet (the same precision `wordVecRefusal` got).
                        Err
                            (wordArmUnsupported
                                (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)"
                                    ((if s0.defunKey == "" then "" else s0.defunKey ++ ": ")
                                        ++ Maybe.withDefault "an unwritable heap code" (wordCellRefusal code (List.length words))
                                    )
                                )
                            )


{-| The one store of a word-arm Value word.  Shared by every `storeWordCell`
arm so the tag has ONE writer. -}
storeWordWord : Il.Arg -> Int -> S -> S
storeWordWord value dest s =
    emit (Store StoreL value (Il.Tmp (slotTmp dest))) s


{-| THE RUNTIME'S `mkstr(bytes, len)` — the tag of a string cell `Rt.allocRaw`
already allocated, whose BYTES ARE INLINE (perf word-arm-rawroot item 1).

The cell is ONE code-1 block: body unit 0 = the byte pointer (the cell's own
bytes, `body + 2 units`), unit `lenFieldWord` = the length, units 2.. = the
bytes.  So the seat that handed the caller its byte base wrote unit 0 already
and this writer has NOTHING TO ALLOCATE — which is the whole point: `mkstr` used
to allocate the cell AFTER the caller had filled a separate byte block, so the
byte pointer was a RAW WORD live across an allocation (a collection there
reclaimed the bytes) and the block it named was reachable only through a body
the collector never walks (a collection afterwards reclaimed them again).

`bytes` is therefore the BYTE BASE — body + 2 units — and the body is
`bytes - 2 units`.  MEASURED, before: 154 of 6000 surviving `String.join`
strings at QBE_HEAP_MB=1; after: 6000, byte-identical to the val arm.

A LITERAL is not this writer: its bytes are a static data symbol, so its cell
owns none and is built by `storeWordStringLiteral`.
-}
storeWordStringCell : List Il.Arg -> Int -> S -> Result String S
storeWordStringCell words dest s0 =
    case words of
        [ bytes, len ] ->
            let
                ( bodyArg, s1 ) =
                    byteBaseToBody bytes s0

                s2 =
                    storeWordBodyWord bodyArg RtLayout.lenFieldWord len s1

                ( taggedWord, s3 ) =
                    freshTmp s2
            in
            Ok
                -- THE SEAT RETURNED THE BYTE BASE, so the body is one header and
                -- two units BELOW it and the Value word is `body OR heapPtrTag`
                -- - NO header arithmetic here (BLOCKER 1: the header is 16 bytes
                -- BEFORE the body, so subtracting it made the value word point
                -- one whole object too low, and the real allocator then aborted
                -- on the resulting body write).
                (s3
                    |> emit (Bin (Just taggedWord) L Or bodyArg (Il.Con (RtLayout.heapPtrTag s3.layout)))
                    |> storeWordWord (Il.Tmp taggedWord) dest
                )

        _ ->
            Err (wordArmUnsupported (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)" "a runtime mkstr that is not exactly (byte base, length) - the cell Rt.allocRaw returned and the length mkstr writes"))


{-| The body of a string cell, from the BYTE BASE `Rt.allocRaw` returns (perf
word-arm-rawroot item 1): the two units below it are the byte pointer and the
length, so `body = base - heapBodyUnitOffset layout 2`.

ONE spelling, used by both string writers, so the offset is not restated.
-}
byteBaseToBody : Il.Arg -> S -> ( Il.Arg, S )
byteBaseToBody base s0 =
    let
        ( body, s1 ) =
            freshTmp s0
    in
    ( Il.Tmp body
    , emit (Bin (Just body) L Sub base (Il.Con (RtLayout.heapBodyUnitOffset s0.layout 2))) s1
    )


{-| A word-arm STRING LITERAL's cell (area A) and where its length lives (area
D): body unit 0 is the byte pointer, body unit `lenFieldWord` is the length.

THE BYTES STAY THE STATIC DATA SYMBOL (perf word-arm-rawroot item 1 keeps it
that way): immutable, NUL-terminated, never moved, so there is no cross-heap edge
and nothing to scavenge — exactly as on the val arm.  The cell therefore owns NO
inline bytes and is allocated at TWO units: `Rt.allocRaw(0)` reserves exactly
`[byte pointer | length]`, and its returned byte base is one-past-the-block, so
the body is derived from it like any other (`byteBaseToBody`).

WHY THIS IS NOT `storeWordStringCell`: that writer tags a cell a caller FILLED,
and takes the byte base as the cell's own bytes.  A literal's byte pointer is a
static symbol, so it is written here and the promotion fixup in `Rt.gcScavPtr`
recognises the difference by exactly this: unit 0 names `body + 2 units` iff the
cell owns its bytes.
-}
storeWordStringLiteral : Il.Arg -> Int -> Int -> S -> Result String S
storeWordStringLiteral byteSym nbytes dest s0 =
    let
        ( baseArg, s1 ) =
            midGcAllocSeat "Rt.allocRaw" (Il.Con 0) s0

        ( bodyArg, s2 ) =
            byteBaseToBody baseArg s1

        s3 =
            storeWordBodyWord bodyArg 0 byteSym s2

        s4 =
            storeWordBodyWord bodyArg RtLayout.lenFieldWord (Il.Con nbytes) s3

        ( taggedWord, s5 ) =
            freshTmp s4
    in
    Ok
        (s5
            |> emit (Bin (Just taggedWord) L Or bodyArg (Il.Con (RtLayout.heapPtrTag s5.layout)))
            |> storeWordWord (Il.Tmp taggedWord) dest
        )


{-| A word-arm SYMBOL LITERAL's cell (perf word-arm-records R1): a code-2 block
whose body is ONE raw word, the NUL-terminated name pointer.

IT ALLOCATES, AND THAT IS WHY IT IS NOT IN `storeWordCell`.  `storeWordCell`'s
one-word heap arm means the CALLER has already allocated and filled the body —
and the runtime's own word-arm symbol construction says exactly that:
`Rt.intern`/`Rt.intInsertAt` are `vecbody(allocKind(mknum(2), mknum(1)))` +
`wstore(sym, 0, store)` + `mkval(2, sym)`, so their `mkval`'s word IS an
allocated BODY.  A literal's word is the static name pointer, which is a
different thing in the same position.  Routing both through one writer is the
defect shape this arc keeps paying for (a parameter whose MEANING two sites
disagree about), so the two live apart: `mkval(2, body)` keeps the generic arm,
and this writer is named for what it does.  MEASURED, not hypothesised: the
first cut put the allocating branch inside `storeWordCell` and every word-arm
program's link into the runtime's intern path refused (2 words expected, 1
passed) — the refusal was correct, and the lesson is that the two meanings
cannot share a dispatch.

THE SHAPE IS THE RUNTIME'S, MEASURED — NOT THE DESIGN'S.  The design priced this
cell as the STRING cell's twin (`[byte pointer, length]`, two body words, "the
length word kept so `len32(sym)` is honest the day one appears").  The runtime
already builds word-arm symbols, and it builds them with ONE word:
`Rt.intern`/`Rt.intInsertAt`'s word splices are `vecbody(allocKind(mknum(2),
mknum(1)))` + `wstore(sym, 0, store)` + `mkval(2, sym)` — the name pointer
only, because there IS no length reader (`symEq`/`symLess`/`pvZ` walk
NUL-terminated bytes, `deepEq`'s symbol arm is `symEq`).

A two-word LITERAL beside a one-word INTERNED symbol would make `len32(sym)`
honest for literals and an OVERRUN for interned ones — the same off-by-one class
this unit exists to kill, planted by the layout.  So the literal matches the
runtime: ONE word, no length.  That is also why the emitter needs this writer at
all rather than the string cell's: the CODE is the constructor on this arm
(`tagis(v, 2)` reads it), so a symbol written through the string's seat (code 1)
would be indistinguishable from a string — the mixed-representation read this
arm exists to prevent.  The code lives in `Rt.allocSym`'s body, never in a
caller's argument.

THE BYTES ARE STATIC AND SHARED with the `sym:` data def `RawCStr`/`RawDataAddr`
use, so a symbol's bytes are never copied and there is no cross-heap edge.
-}
storeWordSymbolLiteral : Il.Arg -> Int -> S -> Result String S
storeWordSymbolLiteral bytes dest s0 =
    let
        -- THE SEAT TAKES THE BODY WORD COUNT (1: the name pointer).
        ( bodyArg, s1 ) =
            midGcAllocSeat "Rt.allocSym" (Il.Con 1) s0

        s2 =
            storeWordBodyWord bodyArg 0 bytes s1

        ( taggedWord, s3 ) =
            freshTmp s2
    in
    Ok
        (s3
            |> emit (Bin (Just taggedWord) L Or bodyArg (Il.Con (RtLayout.heapPtrTag s3.layout)))
            |> storeWordWord (Il.Tmp taggedWord) dest
        )


{-| AREA 5's CELL (perf word-arm-area3rt, and only as much of it as the
construction path needs): a word-arm FLOAT is a code-12 block whose body is the
one f64 word — `heapKindScanned` false, so nothing traces it.

WHY IT IS BUILT HERE AND NOT BY A RUNTIME `mkval(12, ..)`.  A float's single
word is the DOUBLE, not a body base, so it must not go through the cell writer's
one-word rule (which tags a body) — and a `d`-class operand cannot cross the lean
ABI at all, so no runtime seat can receive it.  The shape is therefore the string
cell's: ALLOCATE through a seat that returns the body (`Rt.allocFloat`, code 12,
count 1), store the double at body unit 0 with `stored`, and tag the body.  NO
DETOUR through a scratch slot: MEASURED, the first version boxed the double's
address and called a `Rt.mkFloatCell` seat, which then had to tag its own cell
with `mkval(12, body)` — i.e. it re-entered this writer with a BODY where a
double was expected, and qbe rejected the result (`invalid type for first operand
%t15 in stored`).
-}
storeWordFloatCell : List Il.Arg -> Int -> S -> Result String S
storeWordFloatCell words dest s0 =
    case words of
        [ f ] ->
            let
                ( bodyArg, s1 ) =
                    midGcAllocSeat "Rt.allocFloat" (Il.Con 1) s0

                ( a, s2 ) =
                    freshTmp s1

                s3 =
                    emit (Bin (Just a) L Add bodyArg (Il.Con (RtLayout.heapBodyUnitOffset s2.layout 0))) s2
                        |> emit (Store StoreD f (Il.Tmp a))

                ( taggedWord, s4 ) =
                    freshTmp s3
            in
            Ok
                (s4
                    |> emit (Bin (Just taggedWord) L Or bodyArg (Il.Con (RtLayout.heapPtrTag s4.layout)))
                    |> storeWordWord (Il.Tmp taggedWord) dest
                )

        _ ->
            Err (wordArmUnsupported (wordArea "AREA 5 (FLOATS)" "a float cell that is not exactly one float word"))


{-| AREA 5: `fload(v)` ON THE WORD ARM — the f64 at body unit 0 of a code-12
cell, read as a `d` operand.

WHY A SHAPE TEST AND NOT A BLIND UNTAG.  On the val arm `fload` reads
`slot + 8` of ANY Value: a 40-byte record always has a payload word there, so a
mistagged argument answers garbage BITS rather than a fault.  Under the word arm
there is no such word — `v` is either a tagged heap pointer, a fixnum, or an
immediate — so the read has to name its shape, and the honest answer for the
three non-heap shapes is a LOUD refusal, not the zero the payload reader answers:
`payload(nil, i)` reads an unwritten (zeroed) slot on the val arm, but `fload`
of an immediate would read a DOUBLE out of nothing.

THE REACHABLE DOMAIN IS FLOAT CELLS ONLY, and it is stated rather than assumed:
every `fload` site in `runtime.mid` is a float arm (`Rt.asF` after its
`tagis(x, 12)` test, `Rt.toI32` after the same test, `Rt.fRender` on the value
`Rt.floatText` was handed, and the float arms of `Rt.+ - * f/ < <= > >= =` where
both operands have already been converted by `Rt.asF`).  So the refusal arm is
unreachable from a well-formed program and is there for the mistagged case — the
direction the arc always chooses: loud, never a wrong bit pattern.

THE CODE IS NOT TESTED (only the SHAPE): a word-arm heap block's kind is its
header, and `tagis`/`wordTagIs` is the ONE place a tag is tested.  A second
kind test here would be the duplicate reader this module's own layout note
forbids; the shape test is what the READ requires, and the caller's `tagis` is
what the SEMANTICS requires.
-}
wordFloatPayload : Il.Arg -> S -> ( Il.Arg, S )
wordFloatPayload valueWord s0 =
    let
        ( l, s1 ) =
            wordValueWord valueWord s0

        ( t, s2 ) =
            freshTmp s1

        ( isHeap, s3 ) =
            freshTmp s2

        ( okLbl, s4 ) =
            freshLbl "fltok" s3

        ( badLbl, s5 ) =
            freshLbl "fltbad" s4

        ( r, s6 ) =
            freshTmp s5

        msgText =
            (if s0.defunKey == "" then "" else s0.defunKey ++ ": ") ++ wordFloatRefusal

        ( msgName, s7 ) =
            freshData ("msg:" ++ msgText)
                (\n -> { name = n, align = Just 8, items = [ DStr msgText, DByte 0 ], export_ = False })
                s6
    in
    ( Il.Tmp r
    , s7
        |> emit (Bin (Just t) W And (Il.Tmp l) (Il.Con s0.layout.tagMask))
        |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s7.layout)))
        |> closeBlock (Jnz (Il.Tmp isHeap) okLbl badLbl)
        |> startBlock badLbl
        |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
        |> closeBlock Hlt
        |> startBlock okLbl
        |> (\s8 ->
                let
                    ( bodyArg, s9 ) =
                        wordBodyOf (Il.Tmp l) s8

                    ( a, s10 ) =
                        freshTmp s9
                in
                s10
                    |> emit (Bin (Just a) L Add (Il.Tmp bodyArg) (Il.Con (RtLayout.heapBodyUnitOffset s10.layout 0)))
                    |> emit (Load (Just r) D LoadD (Il.Tmp a))
           )
    )


{-| DOES A BIG LITERAL FIT THE WORD ARM'S i61 FIXNUM?  DECIDED ON THE DIGITS.

The bound is `Mid/RtLayout.wordFixnumLimit` (2^60) and it is EXCLUSIVE IN
MAGNITUDE: a fixnum is `-limit <= n < limit`.  It cannot be decided with host
arithmetic — this compiler's `Int` is a double, so 2^60-1 rounds UP to 2^60 and
the comparison would pass the first out-of-range value (the VR3b2 defect,
MEASURED).  So the decision is LEXICAL, on the same decimal digit string the
parser validated: strip leading zeros, compare lengths, then compare
lexicographically.  `String.fromInt wordFixnumLimit` is exact (2^60 IS
representable as a double), which is what makes the bound spellable as a digit
string at all.

`limit` itself fits when the literal is NEGATIVE (`-2^60 << 3` is INT64_MIN,
which sar-round-trips) and does not when it is positive (`2^60 << 3` overflows).
That asymmetry is the bound's whole content and it is stated once here.
-}
bigLiteralFitsFixnum : String -> Bool
bigLiteralFitsFixnum digits =
    let
        ( negative, magnitude ) =
            if String.startsWith "-" digits then
                ( True, String.dropLeft 1 digits )

            else
                ( False, digits )

        -- the decimal of `wordFixnumLimit`, exact on this host (a power of two)
        limitDigits =
            "1152921504606846976"

        leadingZeros str =
            if String.startsWith "0" str then
                1 + leadingZeros (String.dropLeft 1 str)

            else
                0

        normalised =
            String.dropLeft (leadingZeros magnitude) magnitude

        bound =
            if String.length normalised /= String.length limitDigits then
                String.length normalised < String.length limitDigits

            else
                normalised < limitDigits

        equalBound =
            normalised == limitDigits
    in
    if normalised == "" then
        True

    else if bound then
        True

    else if equalBound then
        negative

    else
        False


{-| AREA 4 (perf word-arm-area4): THE BOXING SEAT — store `w` into `dest` as a
BOXED integer, the i64 living in a code-13 heap cell instead of the fixnum's
tag bits.

`w` is a raw `l` operand holding the i64, NOT a Value: the whole reason this
function exists is that `w` does not fit the i61 fixnum, so there is no
fixnum-shaped word to hand over.  `Rt.boxInt` therefore takes a `word` parameter
(its own docstring states why a `val` one would be wrong) and returns the tagged
Value through sret, exactly as `Rt.globalClosure` does — so the loaded word IS
the Value and no untag follows.

THIS IS THE ALLOCATION THE CLASSIFIER CANNOT SEE.  It is a real safepoint, which
is why `Mid/RtLayout.wordMkAllocSeat` answers `Just "Rt.boxInt"` for
`tagNumber`; that table is the one statement `Mid.Rt.unsafeSafepoint` reads.
-}
boxWordInt : Il.Arg -> Int -> S -> S
boxWordInt w dest s0 =
    let
        ( vp, s1 ) =
            freshTmp s0

        ( v, s2 ) =
            freshTmp s1
    in
    s2
        |> emit (Call (Just vp) (Agg "val") (Il.Sym ("q_" ++ mangle "Rt.boxInt")) [ ArgVal (Base L) w ])
        -- The `:val` result is an ADDRESSABLE aggregate temp, so the one word
        -- is LOADED out of it rather than used directly (the same measured
        -- trap `midGcAllocSeat` records: an aggregate temp used in an integer
        -- op takes its own ADDRESS).
        |> emit (Load (Just v) L LoadL (Il.Tmp vp))
        |> storeWordWord (Il.Tmp v) dest


{-| THE EXACT i64 OF A HOST `Int`, as an `l` operand — the emission a value at
or beyond 2^53 needs, because `Il.Con` carries a host `Int` and its PRINTING
loses the low digits (`String.fromInt` answers 1152921504606847000 for 2^60 —
MEASURED; the same trap `lowerLitVal`'s `LNumberBig` arm avoids with limbs).

Three base-2^26 limbs, which is how `IntegerLiteral.limbsOf` splits a decimal
literal: each limb is host-exact, `2^26` and `2^52` are exact constants, and the
intermediate products WRAP in two's complement — which is exactly the i64 bit
pattern wanted.  A NEGATIVE `n` is `0 - v`, the same wrap `lowerLitVal` uses.

DOMAIN: any `n` this compiler can hold, i.e. a double.  The limb split is exact
for a double because each limb is an integer below 2^26 and the quotient chain
is exact (`n / 2^26` and `n / 2^52` are exact for a value whose magnitude is at
least 2^52; below that the value is already host-exact and `Con` would do, but
this function is only reached above 2^60).
-}
emitExactWord : Int -> S -> ( Il.Arg, S )
emitExactWord n s0 =
    let
        ( l0, s1 ) =
            freshTmp s0

        ( l1, s2 ) =
            freshTmp s1

        ( l2, s3 ) =
            freshTmp s2

        ( t1, s4 ) =
            freshTmp s3

        ( t2, s5 ) =
            freshTmp s4

        ( t3, s6 ) =
            freshTmp s5

        ( t4, s7 ) =
            freshTmp s6

        ( t5, s8 ) =
            freshTmp s7

        magnitude =
            if n < 0 then
                0 - n

            else
                n

        -- `//` is truncating integer division, and both operands are integral
        -- doubles, so every quotient here is EXACT (no rounding to lose).
        q1 =
            magnitude // 67108864

        limb2 =
            q1 // 67108864

        limb1 =
            q1 - limb2 * 67108864

        limb0 =
            magnitude - q1 * 67108864

        s9 =
            s8
                |> emit (Bin (Just t1) L Mul (Il.Con limb1) (Il.Con 67108864))
                |> emit (Bin (Just t2) L Add (Il.Tmp t1) (Il.Con limb0))
                |> emit (Bin (Just t3) L Mul (Il.Con limb2) (Il.Con 4503599627370496))
                |> emit (Bin (Just t4) L Add (Il.Tmp t3) (Il.Tmp t2))

        s10 =
            if n < 0 then
                emit (Bin (Just t5) L Sub (Il.Con 0) (Il.Tmp t4)) s9

            else
                s9
    in
    ( (if n < 0 then Il.Tmp t5 else Il.Tmp t4), s10 )


{-| One BODY word of a word-arm heap object, at `heapBodyUnitOffset`.  `bodyArg`
IS the body address — what the allocation seats return. -}
storeWordBodyWord : Il.Arg -> Int -> Il.Arg -> S -> S
storeWordBodyWord bodyArg word value s0 =
    let
        ( a, s1 ) =
            freshTmp s0
    in
    s1
        |> emit (Bin (Just a) L Add bodyArg (Il.Con (RtLayout.heapBodyUnitOffset s0.layout word)))
        |> emit (Store StoreL value (Il.Tmp a))


{-| S3 (VR3b3 FIX): the vec family's input contract is a RAW ELEMENT-ARRAY
ADDRESS, and on the word arm nothing can produce one: `payload(v, 0)` yields the
first body VALUE WORD (a tagged value), and `elemAddr` would then use a tagged
address as a base - a misaligned read into the wrong object.  The constructors
refuse loudly (`wordCellRefusal`), but a pure READER (`Rt.deepEq`, `Rt.revGo`)
contains no constructor, so once AREA 6 lands it would lower and read wrong.
Refused by name until `vecload`/`vecstore` are re-expressed over the word arm's
body (a real port, not a stride).
-}
wordVecRefusal : String -> String -> String
wordVecRefusal who what =
    wordArmUnsupported
        (wordArea
            "AREA 3 (PAYLOAD ACCESS)"
            ((if who == "" then "" else who ++ ": ")
                ++ "`"
                ++ what
                ++ "` - its input contract is a raw element-array address, which on the word arm nothing can produce: `payload(v, 0)` yields the first body VALUE WORD (a tagged value), so `elemAddr` would use a tagged address as a base and read into the wrong object"
            )
        )


{-| AREA B/D: the i32 FIELD of a word-arm payload word — the LOW HALF of body
unit `i`, read AT ITS ADDRESS.  Deliberately NOT `wordPayloadWord` followed by a
load: that function LOADS the 8-byte body word, so a second load would
dereference its VALUE (MEASURED: `payload32(s, 1)` emitted `movq 8(%rax), %rax`
then `movl (%rax), %eax`, i.e. it loaded the length 6 and then read memory at
address 6 — a SEGV, found by the len probe the moment it ran).

The shape test is the same tag test, and a word that is not a heap object
REFUSES: an i32 FIELD exists only in a heap body (a fixnum's value lives in a
register, and the val-arm sites that read `payload32` of a boolean are AREA 2's
boolean test, which the word arm does on the TAG, not on a payload field).
-}
wordPayloadField32 : Il.Arg -> Int -> S -> ( Il.Arg, S )
wordPayloadField32 base word s0 =
    let
        ( l, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( isFix, s3 ) =
            freshTmp s2

        ( isTrue, s3c ) =
            freshTmp s3

        ( isFalse, s3d ) =
            freshTmp s3c

        ( isBool, s4 ) =
            freshTmp s3d

        ( isHeap, s5 ) =
            freshTmp s4

        ( heapLbl, s6 ) =
            freshLbl "fheap" s5

        ( badLbl, s7 ) =
            freshLbl "fbad" s6

        ( joinLbl, s8 ) =
            freshLbl "fjoin" s7

        ( fixLbl, s9 ) =
            freshLbl "ffix" s8

        ( boolLbl, s10 ) =
            freshLbl "fbool" s9

        ( chkLbl, s11 ) =
            freshLbl "fchk" s10

        ( chk2Lbl, s11b ) =
            freshLbl "fchk2" s11

        ( r, s12 ) =
            freshTmp s11b

        msgText =
            (if s0.defunKey == "" then "" else s0.defunKey ++ ": ") ++ wordField32Refusal

        ( msgName, s13 ) =
            freshData ("msg:" ++ msgText)
                (\n -> { name = n, align = Just 8, items = [ DStr msgText, DByte 0 ], export_ = False })
                s12

        -- 1. the tag, then the IMMEDIATE arms (word 0 only) and the heap arm.
        --
        -- THE FIXNUM ARM IS A REAL PORT, NOT A RELAXATION (perf
        -- word-arm-area3rt).  `payload32(v, 0)` on a NUMBER is an idiom the
        -- runtime uses constantly (`payload32(found, 0)` in Rt.main reads the
        -- low half of a count returned as a fixnum): on the val arm it is a
        -- 32-bit LOAD of the payload word, which works for any Value.  A
        -- fixnum's word 0 on the word arm is its value in a register, so the
        -- same read is the low 32 bits of the arithmetic-shifted value,
        -- SIGN-EXTENDED exactly as the val arm's `loadw` + `extsw` is.
        --
        -- THE BOOLEAN ARM IS THE VAL ARM'S FIELD, PORTED.  A val-arm boolean is
        -- `{tag 3, payload word 0 = 1 | 0}`, so `payload32(b, 0)` is its FLAG;
        -- the word arm's boolean is an IMMEDIATE whose flag is the tag itself
        -- (`...011` true, `...100` false), so the same read is `t == tagTrue`
        -- as a word.
        --
        -- MEASURED (each cost one run of a real binary): without the fixnum
        -- arm, `main = 7` dies at Rt.main's first `payload32` of a count;
        -- without the boolean arm it dies in `Rt.cStrEq`, which returns
        -- `payload32(eq, 0)` of its own boolean.
        s14 =
            s13
                |> emit (Bin (Just t) W And (Il.Tmp l) (Il.Con s13.layout.tagMask))
                |> (\st ->
                        if word == 0 then
                            st
                                |> emit (Cmp (Just isFix) W Ceq (Il.Tmp t) (Il.Con s13.layout.tagNumber))
                                |> closeBlock (Jnz (Il.Tmp isFix) fixLbl chkLbl)
                                |> startBlock chkLbl
                                -- A BOOLEAN HAS **TWO** IMMEDIATES: `...011`
                                -- true and `...100` false.  Testing only
                                -- tagTrue let FALSE fall through to the heap
                                -- test and die — MEASURED: Rt.metaGo answers
                                -- `mkbool(0)` on a miss and Rt.main's
                                -- `payload32(found, 0)` killed the first run of
                                -- a real binary.
                                |> emit (Cmp (Just isTrue) W Ceq (Il.Tmp t) (Il.Con s13.layout.tagTrue))
                                |> emit (Cmp (Just isFalse) W Ceq (Il.Tmp t) (Il.Con s13.layout.tagFalse))
                                |> emit (Bin (Just isBool) W Or (Il.Tmp isTrue) (Il.Tmp isFalse))
                                |> closeBlock (Jnz (Il.Tmp isBool) boolLbl chk2Lbl)
                                |> startBlock chk2Lbl

                        else
                            st
                   )

        -- 2. a heap object, or the loud refusal.
        s15 =
            s14
                |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s14.layout)))
                |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl badLbl)
                |> startBlock badLbl
                |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
                |> closeBlock Hlt
                |> startBlock heapLbl

        -- 3. the heap arm: the LOW HALF of body unit `word`, sign-extended.
        s16 =
            let
                ( bodyArg, sa ) =
                    wordBodyOf (Il.Tmp l) s15

                ( a, sb ) =
                    freshTmp sa

                ( wT, sc ) =
                    freshTmp sb
            in
            sc
                |> emit (Bin (Just a) L Add (Il.Tmp bodyArg) (Il.Con (RtLayout.heapBodyUnitOffset sc.layout word)))
                |> emit (Load (Just wT) W LoadW (Il.Tmp a))
                |> emit (Unary (Just r) L Extsw (Il.Tmp wT))
                |> jumpTo joinLbl

        -- 4. the fixnum arm (word 0 only): shift the tag bits off, then take the
        -- low half.  The `W And -1` is how this file narrows an `l` temp to the
        -- `w` class (`extsw` takes a word); it is the same trick `readTag` uses
        -- for its mask.
        s17 =
            if word == 0 then
                -- THE FRESH TEMP MUST COME FROM THE STATE THE EMIT CHAIN RETURNS
                -- (perf word-arm-surface).  MEASURED: allocating `w32` in a
                -- `let` whose state was then DISCARDED (the chain started from
                -- `s16` again) left the counter one behind, so the NEXT
                -- `payload32` in the same defun was handed the same number — and
                -- because this arm defines it `l` (`sar`) and then `w` (`and`),
                -- qbe rejected the module: "invalid type for first operand
                -- %t250 in and".  One `payload32` per defun never showed it;
                -- `case s of "hi" -> ..` does (two reads in one body).
                let
                    ( w32, sa ) =
                        freshTmp (startBlock fixLbl s16)
                in
                sa
                    |> emit (Bin (Just w32) L Sar (Il.Tmp l) (Il.Con s13.layout.tagBits))
                    |> emit (Bin (Just w32) W And (Il.Tmp w32) (Il.Con -1))
                    |> emit (Unary (Just r) L Extsw (Il.Tmp w32))
                    |> jumpTo joinLbl

            else
                s16

        -- 5. the boolean arm (word 0 only): the flag IS the tag, so the field is
        -- the ALREADY-COMPUTED compare result (`isBool`, 0/1 in the `w` class),
        -- widened to the word class exactly as the other arms' fields are.
        s18 =
            if word == 0 then
                s17
                    |> startBlock boolLbl
                    |> emit (Unary (Just r) L Extsw (Il.Tmp isTrue))
                    |> jumpTo joinLbl

            else
                s17

        s19 =
            s18 |> startBlock joinLbl
    in
    ( Il.Tmp r, s19 )


{-| The i32-field refusal's message: an i32 field is a body unit, so a word that
is not a heap object has none. -}
wordField32Refusal : String
wordField32Refusal =
    "qbe-rt: word arm: i32 field read on a word that is not a heap object (...001) - a fixnum's value lives in a register and has no field, and an immediate (nil/true/false/error) has no body. Refusing."


{-| The `mknum` overflow refusal: a word-arm fixnum is an i61, so a value whose
top three bits survive the shift cannot be represented.  ASCII only. -}
wordFixnumRefusal : String
wordFixnumRefusal =
    "qbe-rt: word arm: mknum overflow - the value does not fit the i61 fixnum (its top three bits would be dropped by the tag shift) and boxing onto the heap is AREA 4's overflow path, which does not exist yet. Refusing instead of truncating."


{-| AREA B: the loud refusal a payload read emits when the word it was handed is
neither a fixnum nor a heap object.  ASCII only (the emitted data item is a
surface-language string literal, and a non-ASCII byte there is a parse error the
val arm never sees — MEASURED at VR3c). -}
wordPayloadRefusal : String
wordPayloadRefusal =
    "qbe-rt: word arm: payload read on a word that is neither a fixnum (...000) nor a heap object (...001) - nil/true/false/error have no payload, so this would read another layout's bits. Refusing."


{-| AREA 5: the loud refusal `fload` emits under the word arm when the word it
was handed is not a heap object.  ASCII only, for `wordPayloadRefusal`'s reason
(the emitted data item is a surface-language string literal).
-}
wordFloatRefusal : String
wordFloatRefusal =
    "qbe-rt: word arm: fload on a word that is not a heap object - a word-arm float is a code-12 [hdr | f64] cell, so its double lives in the cell's body unit 0; a fixnum or an immediate has no f64 word to read, and reading one out of the tag bits would print a wrong number. Refusing."


{-| AREA B, THE ONE PAYLOAD-WORD READER.  Under the word arm a payload word is
NOT a shifted field offset of a 40-byte record: it is a SHAPE, decided by the
value's low tag, and each shape reads different bytes.

  * `...000` fixnum: the payload IS the value, arithmetic-shifted DOWN out of
    the tag bits (`SAR`), and it exists only at word 0.
  * `...001` heap object: untag, step past the 2-word header, step `word` body
    units in, load 8 bytes.
  * anything else (nil, true, false, error, reserved): REFUSE, loudly.  Those
    have no payload word at all, so the val arm's blind read here is exactly the
    silent read of another layout's bytes this arm must not reproduce.

The two shapes need a branch (there is no arithmetic that covers both), and QBE
has no `phi`, so the ONE result temp is assigned in each arm and used after the
join — QBE's own SSA construction handles that.
-}
wordPayloadWord : Il.Arg -> Int -> S -> ( Il.Arg, S )
wordPayloadWord base word s0 =
    let
        ( l, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( isFix, s3 ) =
            freshTmp s2

        ( isHeap, s4 ) =
            freshTmp s3

        ( isNil, s4b ) =
            freshTmp s4

        ( isTrue, s4c ) =
            freshTmp s4b

        ( isFalse, s4d ) =
            freshTmp s4c

        ( isZeroTag, s4e ) =
            freshTmp s4d

        ( heapLbl, s5 ) =
            freshLbl "pheap" s4e

        ( badLbl, s6 ) =
            freshLbl "pbad" s5

        ( zeroLbl, s6b ) =
            freshLbl "pzero" s6

        ( joinLbl, s7 ) =
            freshLbl "pjoin" s6b

        ( fixLbl, s8 ) =
            freshLbl "pfix" s7

        ( chkLbl, s9 ) =
            freshLbl "pchk" s8

        ( chk2Lbl, s9b ) =
            freshLbl "pchk2" s9

        ( r, s10 ) =
            freshTmp s9b

        ( rw, s10b ) =
            freshTmp s10

        msgText =
            (if s0.defunKey == "" then "" else s0.defunKey ++ ": ") ++ wordPayloadRefusal

        ( msgName, s11 ) =
            freshData ("msg:" ++ msgText)
                (\n -> { name = n, align = Just 8, items = [ DStr msgText, DByte 0 ], export_ = False })
                s10b

        -- 1. the tag, and the FIRST branch: a fixnum (word 0 only) or not.
        s12 =
            emit (Bin (Just t) W And (Il.Tmp l) (Il.Con s11.layout.tagMask)) s11

        s13 =
            if word == 0 then
                s12
                    |> emit (Cmp (Just isFix) W Ceq (Il.Tmp t) (Il.Con s11.layout.tagNumber))
                    |> closeBlock (Jnz (Il.Tmp isFix) fixLbl chkLbl)
                    |> startBlock chkLbl

            else
                s12

        -- 2. a heap object, an IMMEDIATE, or the loud refusal.
        --
        -- THE IMMEDIATE ARM IS THE VAL ARM'S VALUE, PORTED (perf
        -- word-arm-area3rt).  On the val arm `payload(nil, i)`,
        -- `payload(true, i)` and `payload(false, i)` all read an UNWRITTEN
        -- payload word, i.e. ZERO — the slot is zeroed at frame entry and the
        -- tag write is the whole of `mknil`/`mkbool`.  Sites lean on that
        -- (`Rt.main`'s `payload(prc, 0) != 0`), so the faithful twin is 0, not
        -- a refusal.  ERROR is NOT here: its payload word 0 is a real message
        -- pointer on the val arm, so a word-arm error has no equivalent read
        -- and still refuses by name.
        s14 =
            s13
                |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s11.layout)))
                |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl chk2Lbl)
                |> startBlock chk2Lbl
                |> emit (Cmp (Just isNil) W Ceq (Il.Tmp t) (Il.Con s11.layout.tagNil))
                |> emit (Cmp (Just isTrue) W Ceq (Il.Tmp t) (Il.Con s11.layout.tagTrue))
                |> emit (Cmp (Just isFalse) W Ceq (Il.Tmp t) (Il.Con s11.layout.tagFalse))
                |> emit (Bin (Just isZeroTag) W Or (Il.Tmp isNil) (Il.Tmp isTrue))
                |> emit (Bin (Just isZeroTag) W Or (Il.Tmp isZeroTag) (Il.Tmp isFalse))
                |> closeBlock (Jnz (Il.Tmp isZeroTag) zeroLbl badLbl)
                |> startBlock badLbl
                |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
                |> closeBlock Hlt
                |> startBlock zeroLbl
                -- `r` is an `l` temp in every other arm, so the zero is built
                -- in its OWN `w` temp and widened — a temp has ONE class in
                -- QBE, and MEASURED: assigning it in both classes makes the
                -- assembler reject the shift in the fixnum arm ("invalid type
                -- for first operand %t28 in shl").
                |> emit (Bin (Just rw) W Xor (Il.Tmp t) (Il.Tmp t))
                |> emit (Unary (Just r) L Extsw (Il.Tmp rw))
                |> jumpTo joinLbl
                |> startBlock heapLbl

        -- 3. the heap arm: untag, past the header, `word` units in.
        s15 =
            let
                ( bodyArg, sa ) =
                    wordBodyOf (Il.Tmp l) s14

                ( a, sb ) =
                    freshTmp sa
            in
            sb
                |> emit (Bin (Just a) L Add (Il.Tmp bodyArg) (Il.Con (RtLayout.heapBodyUnitOffset sb.layout word)))
                |> emit (Load (Just r) L LoadL (Il.Tmp a))
                |> jumpTo joinLbl

        -- 4. the fixnum arm (word 0 only): shift the tag bits off.
        s16 =
            if word == 0 then
                s15
                    |> startBlock fixLbl
                    |> emit (Bin (Just r) L Sar (Il.Tmp l) (Il.Con s11.layout.tagBits))
                    |> jumpTo joinLbl

            else
                s15

        s17 =
            s16 |> startBlock joinLbl
    in
    ( Il.Tmp r, s17 )


{-| AREA 3, THE ELEMENT COUNT ON THE WORD ARM (perf word-arm-area3rt, the
review's BLOCKER 2).

A word-arm vector's length is NOT in the body — the body IS the elements — so it
lives where the ALLOCATOR put it: the GC header's count word, one word before the
body (`gcAlloc`: `wstore(cursor, -1, countW)`).  `RtLayout` states the header's
shape (`heapHeaderOffset` = -16 for word 0), so the count word's address is
`body + heapHeaderOffset + wordBytes` — written as that sum rather than a second
constant, so a header that ever gains a word moves this reader with it.

THE SHAPE FORK IS `wordVecBody`'s, and for the same reason: a fixnum's "count" is
not a length (it has no elements), and an immediate has neither — both REFUSE
loudly.  Only a heap object answers, and it answers from the header.

WHY THIS IS A SEPARATE READER FROM `len32`: a string's payload word 1 is its BYTE
length on the val arm, but the header's count for a word-arm string is
`2 + ceil(bytes/8)` — body WORDS (the byte pointer, the length, then the bytes,
which are INLINE since perf word-arm-rawroot item 1), a different number.  A
single reader would have to know the code, and `payload32`-shaped code has no way
to ask; so the two reads are two names and the runtime's sites are classified one
by one.  Nothing reads `veclen` of a string today, and this is the number it
would answer.
-}
wordVecLen : Il.Arg -> S -> ( Il.Arg, S )
wordVecLen base s0 =
    let
        ( l, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( isHeap, s3 ) =
            freshTmp s2

        ( heapLbl, s4 ) =
            freshLbl "lheap" s3

        ( badLbl, s5 ) =
            freshLbl "lbad" s4

        ( joinLbl, s6 ) =
            freshLbl "ljoin" s5

        ( r, s7 ) =
            freshTmp s6

        ( wT, s8 ) =
            freshTmp s7

        msgText =
            (if s0.defunKey == "" then "" else s0.defunKey ++ ": ") ++ wordVecLenRefusal

        ( msgName, s9 ) =
            freshData ("msg:" ++ msgText)
                (\n -> { name = n, align = Just 8, items = [ DStr msgText, DByte 0 ], export_ = False })
                s8

        s10 =
            s9
                |> emit (Bin (Just t) W And (Il.Tmp l) (Il.Con s9.layout.tagMask))
                |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s9.layout)))
                |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl badLbl)
                |> startBlock badLbl
                |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
                |> closeBlock Hlt
                |> startBlock heapLbl

        s11 =
            let
                ( bodyArg, sa ) =
                    wordBodyOf (Il.Tmp l) s10

                ( a, sb ) =
                    freshTmp sa
            in
            sb
                |> emit
                    (Bin (Just a) L Add
                        (Il.Tmp bodyArg)
                        (Il.Con (RtLayout.heapHeaderOffset sb.layout + RtLayout.wordBytes))
                    )
                |> emit (Load (Just wT) W LoadW (Il.Tmp a))
                |> emit (Unary (Just r) L Extsw (Il.Tmp wT))
                |> jumpTo joinLbl
                |> startBlock joinLbl
    in
    ( Il.Tmp r, s11 )


{-| The `veclen` refusal's message.  ASCII only. -}
wordVecLenRefusal : String
wordVecLenRefusal =
    "qbe-rt: word arm: element count of a word that is not a heap object (...001) - a fixnum is a number and an immediate (nil/true/false/error) is not a collection, so neither has a length; a string's length is len32, not this. Refusing."


{-| AREA 3 (PAYLOAD ACCESS), THE ELEMENT BASE ON THE WORD ARM (perf
word-arm-area3rt).

`vecbody(v)` answers "where do this Value's elements start", and on the word arm
the answer depends on the SHAPE, exactly as a payload read does:

  * `...000` fixnum: the payload IS the base word — this is how a raw C pointer
    travels through the runtime (`mknum(ptr)`), so it is returned
    arithmetic-shifted DOWN out of the tag bits (`SAR`), the exact inverse of
    the write.  A site that handed `payload(v, 0)` to `vecload` on the val arm
    was doing the same thing for the same reason.
  * `...001` heap object: the BODY — the untag (`AND untagMask`) and NOTHING
    ELSE, because the seat-return convention already makes the untagged word the
    body (`RtLayout` THE CONVENTION; `wordBodyOf` is the same one instruction).
    NOT a payload LOAD: the body's first word IS element 0 on this arm, so
    handing element 0 to `vecload` would use a tagged value as an address, which
    is the mixed-representation read this arm exists to prevent.
  * anything else (nil, true, false, error, reserved): REFUSE, loudly.  An
    immediate has no elements, so the val arm's blind `payload(v, 0)` here would
    read another layout's bytes.

The branch structure and the single result temp are `wordPayloadWord`'s (QBE has
no `phi`, so each arm assigns `r` and the join reads it) — the two functions are
SIBLINGS and deliberately not folded into one: a payload read returns the VALUE
WORD at a body unit, this returns the ADDRESS of body unit 0.
-}
wordVecBody : Il.Arg -> S -> ( Il.Arg, S )
wordVecBody base s0 =
    let
        ( l, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( isFix, s3 ) =
            freshTmp s2

        ( isHeap, s4 ) =
            freshTmp s3

        ( heapLbl, s5 ) =
            freshLbl "bheap" s4

        ( badLbl, s6 ) =
            freshLbl "bbad" s5

        ( joinLbl, s7 ) =
            freshLbl "bjoin" s6

        ( fixLbl, s8 ) =
            freshLbl "bfix" s7

        ( chkLbl, s9 ) =
            freshLbl "bchk" s8

        ( r, s10 ) =
            freshTmp s9

        ( msgName, s11 ) =
            freshData ("msg:" ++ wordVecBodyRefusal)
                (\n -> { name = n, align = Just 8, items = [ DStr wordVecBodyRefusal, DByte 0 ], export_ = False })
                s10

        -- 1. the tag, and the FIRST branch: a fixnum (a base word) or not.
        s12 =
            s11
                |> emit (Bin (Just t) W And (Il.Tmp l) (Il.Con s11.layout.tagMask))
                |> emit (Cmp (Just isFix) W Ceq (Il.Tmp t) (Il.Con s11.layout.tagNumber))
                |> closeBlock (Jnz (Il.Tmp isFix) fixLbl chkLbl)
                |> startBlock chkLbl

        -- 2. a heap object, or the loud refusal.
        s13 =
            s12
                |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s12.layout)))
                |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl badLbl)
                |> startBlock badLbl
                |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
                |> closeBlock Hlt
                |> startBlock heapLbl

        -- 3. the heap arm: THE UNTAG **IS** THE BODY.  No header step.
        --
        -- THIS WAS WRONG AND THE `vec` PROBE CAUGHT IT (review BLOCKER 1's fix
        -- earning its keep on its first run): the arm read
        -- `(v AND untagMask) + heapHeaderBytes`, i.e. 16 bytes PAST the body —
        -- element 2 where element 0 was asked for, on every heap object.  The
        -- seat-return convention is what settles it: a seat returns
        -- `mknum(BODY)` and the Value word is `body OR heapPtrTag`, so the
        -- UNTAG *is* the body (`RtLayout`'s THE CONVENTION: body unit 0 is at
        -- offset 0 from it, and the 2-word header sits `heapHeaderOffset` =
        -- -16 BEFORE it).  `wordBodyOf` — what every payload read uses — is the
        -- same one instruction, and a base cannot differ from it.
        --
        -- WHY NO ORACLE SAW IT: no word-arm program can construct a heap vector
        -- yet, so the arm was unexecuted; the diff row runs programs and the
        -- probe set had no element read.  Both are now closed.
        s14 =
            s13
                |> emit (Bin (Just r) L And (Il.Tmp l) (Il.Con (RtLayout.untagMask s13.layout)))
                |> jumpTo joinLbl

        -- 4. the fixnum arm: shift the tag bits off.
        s15 =
            s14
                |> startBlock fixLbl
                |> emit (Bin (Just r) L Sar (Il.Tmp l) (Il.Con s12.layout.tagBits))
                |> jumpTo joinLbl

        s16 =
            s15 |> startBlock joinLbl
    in
    ( Il.Tmp r, s16 )


{-| The `vecbody` refusal's message: an immediate names no elements.  ASCII only
(the emitted data item is a string the runtime prints). -}
wordVecBodyRefusal : String
wordVecBodyRefusal =
    "qbe-rt: word arm: element base of a word that is neither a fixnum nor a heap object (...001) - an immediate (nil/true/false/error) has no elements, so a vecload/vecstore/vecaddr on it would read another layout's bytes. Refusing."


{-| AREA C: THE WORD-ARM TAG TEST (`tagis(v, code)`), the reader VR3c's fix
and its review named as the promissory note.

A VALTAG is what the caller asks about, and under the word arm its ENCODING is
not the valtag (`RtLayout.wordTagShape`):

  * `WordImmediate tags` — nil, true/false and error are IMMEDIATES: the test is
    `(w AND tagMask) == tag`, one compare (two OR'd for a boolean, which has two
    immediates).
  * `WordHeapCode code` — a heap object: the tag must be `heapPtrTag` AND the
    header's kind code must be `code`.  The header read is BRANCHED, never
    unconditional: a fixnum untagged is a small integer, so reading a "header"
    off it would fault.
  * `WordNoForm why` — refused at COMPILE time by name.

AND CODE 0 IS REFUSED BY NAME, which is the note this function discharges.
Code 0's single owner is NO CODE (a val-arm header) and no word-arm allocator
writes it, so a word-arm reader that meets 0 has been handed a val-arm block or
uninitialised memory.  Returning "not the code you asked for" would hide that,
so the read dies with the reason.  A tag MISMATCH is not an error (a tag test
asks a question and gets an answer); only the impossible code is.
-}
wordTagIs : Il.Arg -> Int -> S -> Result String ( Il.Arg, S )
wordTagIs base code s0 =
    case RtLayout.wordTagShape code of
        RtLayout.WordNoForm why ->
            Err (wordArmUnsupported (wordArea "AREA 2 (TAG TESTS)" ("`tagis(v, " ++ String.fromInt code ++ ")` - " ++ why)))

        -- AREA 4 (perf word-arm-area4): A NUMBER HAS **TWO** WORD ENCODINGS, so
        -- `tagis(v, 0)` is the one immediate test that is not a tag compare.
        -- A value inside i61 is the `...000` fixnum; one outside it is a
        -- code-13 heap block.  Both ARE numbers, and `tagis(v, 0)` is the
        -- runtime's numeric predicate — it is what `Rt.+ - * / = < <= > >=`,
        -- `Rt.asF`, `Rt.numText`'s callers and `Rt.number?` all ask.  Answering
        -- the fixnum tag alone would say "not a number" for every boxed value,
        -- i.e. the printer would stop printing it and `=` would stop comparing
        -- it.  So this ONE reader is extended: fixnum OR kind code 13.
        --
        -- IT IS STILL ONE PLACE.  `wordTagShape tagNumber` keeps its
        -- `WordImmediate [0]` row, because that is the encoding a CONSTRUCTION
        -- site must produce for a value that fits; the second encoding is a
        -- question only a READER can be asked, and this is the reader.
        RtLayout.WordImmediate tags ->
            if code == RtLayout.tagNumber then
                wordNumberTagIs base s0

            else
                wordImmediateTagIs base tags s0


        RtLayout.WordHeapCode c ->
            let
                ( v, s1 ) =
                    wordValueWord base s0

                ( t, s2 ) =
                    freshTmp s1

                ( isHeap, s3 ) =
                    freshTmp s2

                ( isC, s4 ) =
                    freshTmp s3

                ( ext, s5 ) =
                    freshTmp s4

                ( heapLbl, s6 ) =
                    freshLbl "kheap" s5

                ( notLbl, s7 ) =
                    freshLbl "knot" s6

                ( badLbl, s8 ) =
                    freshLbl "kzero" s7

                ( okLbl, s9 ) =
                    freshLbl "kok" s8

                ( joinLbl, s10 ) =
                    freshLbl "kjoin" s9

                ( msgName, s11 ) =
                    freshData ("msg:" ++ wordKindZeroRefusal)
                        (\n -> { name = n, align = Just 8, items = [ DStr wordKindZeroRefusal, DByte 0 ], export_ = False })
                        s10

                -- 1. the tag says "a heap object" or it does not.  The header
                --    read is INSIDE the heap branch: untagging a fixnum yields a
                --    small integer, so an unconditional header load would fault.
                s12 =
                    s11
                        |> emit (Bin (Just t) W And (Il.Tmp v) (Il.Con s11.layout.tagMask))
                        |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s11.layout)))
                        |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl notLbl)
                        |> startBlock notLbl
                        |> emit (Bin (Just isC) W Xor (Il.Tmp isHeap) (Il.Tmp isHeap))
                        |> jumpTo joinLbl

                -- 2. the heap branch: the kind code, and CODE 0 REFUSED BY NAME.
                ( hdrCode, _, s13 ) =
                    wordKindCode (Il.Tmp v) (startBlock heapLbl s12)

                ( isZero, s14 ) =
                    freshTmp s13

                s15 =
                    s14
                        |> emit (Cmp (Just isZero) W Ceq (Il.Tmp hdrCode) (Il.Con 0))
                        |> closeBlock (Jnz (Il.Tmp isZero) badLbl okLbl)
                        |> startBlock badLbl
                        |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
                        |> closeBlock Hlt
                        |> startBlock okLbl
                        |> emit (Cmp (Just isC) W Ceq (Il.Tmp hdrCode) (Il.Con c))
                        |> jumpTo joinLbl
                        |> startBlock joinLbl
                        |> emit (Unary (Just ext) L Extsw (Il.Tmp isC))
            in
            Ok ( Il.Tmp ext, s15 )


{-| THE IMMEDIATE HALF of `wordTagIs`: the tag alone answers it, with one compare
or (a boolean, which has TWO immediates) the OR of two.

THE TAG AND THE COMPARE RESULT ARE DISTINCT TEMPS, and that is load-bearing
(VR3b3 FIX, BLOCKER 2).  Folding the compares into `t` - the tag temp -
destroyed the tag after the first compare, so the second compared the 0/1
RESULT against `tagFalse` and `tagis(v, tagBoolean)` answered FALSE for `false`;
MEASURED, and reachable through `Rt.deepEq`'s `tagis(a, 3)` the moment AREA 6
admits calls.  No text pin could see it (both spellings are two compares and an
`or`), which is why the probe set now carries a boolean `tagis`.
-}
wordImmediateTagIs : Il.Arg -> List Int -> S -> Result String ( Il.Arg, S )
wordImmediateTagIs base tags s0 =
    let
        ( v, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( is, s3 ) =
            freshTmp s2

        ( ext, s4 ) =
            freshTmp s3

        s5 =
            emit (Bin (Just t) W And (Il.Tmp v) (Il.Con s4.layout.tagMask)) s4

        s6 =
            case tags of
                [] ->
                    emit (Bin (Just is) W Xor (Il.Tmp t) (Il.Tmp t)) s5

                firstTag :: rest ->
                    List.foldl
                        (\one acc ->
                            let
                                ( o, sa ) =
                                    freshTmp acc
                            in
                            emit (Cmp (Just o) W Ceq (Il.Tmp t) (Il.Con one)) sa
                                |> emit (Bin (Just is) W Or (Il.Tmp is) (Il.Tmp o))
                        )
                        (emit (Cmp (Just is) W Ceq (Il.Tmp t) (Il.Con firstTag)) s5)
                        rest
    in
    Ok ( Il.Tmp ext, emit (Unary (Just ext) L Extsw (Il.Tmp is)) s6 )


{-| AREA 4: `tagis(v, 0)` — "is this a NUMBER?", where a word-arm number has TWO
encodings: the `...000` i61 fixnum, and a code-13 heap block for a value that
did not fit.  Answering only the fixnum tag would make every boxed value answer
"not a number", and `tagis(v, 0)` is the numeric predicate the whole runtime
asks (`Rt.+ - * / = < <= > >=`, `Rt.asF`, `Rt.toI32`, `Rt.number?`, and the
printer's dispatch), so that would stop the printer printing and `=` comparing.

THE HEAP HALF IS BRANCHED, for `wordTagIs`'s reason: untagging a fixnum yields a
small integer, so an unconditional header load would fault.  A heap object that
is NOT code 13 (a cons, a string) answers FALSE — and its header's code is read
by the same `wordKindCode`, which is what keeps code 0 a loud refusal here too.
-}
wordNumberTagIs : Il.Arg -> S -> Result String ( Il.Arg, S )
wordNumberTagIs base s0 =
    let
        ( v, s1 ) =
            wordValueWord base s0

        ( t, s2 ) =
            freshTmp s1

        ( isFix, s3 ) =
            freshTmp s2

        ( isHeap, s4 ) =
            freshTmp s3

        ( isBoxed, s5 ) =
            freshTmp s4

        -- ONE result temp, assigned in BOTH arms before the join: QBE has no
        -- phi and demands dominance, so a temp defined only in the `not` arm
        -- and read after the join is "used undefined" (MEASURED: `%t5 is used
        -- undefined in @nok_3` on `intbig`).
        ( isEither, s7 ) =
            freshTmp s5

        ( ext, s8 ) =
            freshTmp s7

        ( heapLbl, s9 ) =
            freshLbl "nheap" s8

        ( notLbl, s10 ) =
            freshLbl "nnot" s9

        ( badLbl, s11 ) =
            freshLbl "nzero" s10

        ( okLbl, s12 ) =
            freshLbl "nok" s11

        ( joinLbl, s13 ) =
            freshLbl "njoin" s12

        ( msgName, s14 ) =
            freshData ("msg:" ++ wordKindZeroRefusal)
                (\n -> { name = n, align = Just 8, items = [ DStr wordKindZeroRefusal, DByte 0 ], export_ = False })
                s13

        -- 1. the tag: a fixnum answers YES outright; a heap object has to be
        --    asked about its kind; anything else is not a number.
        s15 =
            s14
                |> emit (Bin (Just t) W And (Il.Tmp v) (Il.Con s14.layout.tagMask))
                |> emit (Cmp (Just isFix) W Ceq (Il.Tmp t) (Il.Con s14.layout.tagNumber))
                |> emit (Cmp (Just isHeap) W Ceq (Il.Tmp t) (Il.Con (RtLayout.heapPtrTag s14.layout)))
                |> closeBlock (Jnz (Il.Tmp isHeap) heapLbl notLbl)
                |> startBlock notLbl
                |> emit (Bin (Just isEither) W Or (Il.Tmp isFix) (Il.Tmp isFix))
                |> jumpTo joinLbl

        -- 2. the heap branch: a code-13 block is a boxed number, and code 0 is
        --    refused by name (it means NO CODE — a val-arm header).
        ( hdrCode, _, s16 ) =
            wordKindCode (Il.Tmp v) (startBlock heapLbl s15)

        ( isZero, s17 ) =
            freshTmp s16
    in
    Ok
        ( Il.Tmp ext
        , s17
            |> emit (Cmp (Just isZero) W Ceq (Il.Tmp hdrCode) (Il.Con 0))
            |> closeBlock (Jnz (Il.Tmp isZero) badLbl okLbl)
            |> startBlock badLbl
            |> emit (Call Nothing (Base L) (Il.Sym ("q_" ++ mangle "Rt.die")) [ ArgVal (Base L) (Il.Sym msgName) ])
            |> closeBlock Hlt
            |> startBlock okLbl
            |> emit (Cmp (Just isBoxed) W Ceq (Il.Tmp hdrCode) (Il.Con RtLayout.tagBigInt))
            |> emit (Bin (Just isEither) W Or (Il.Tmp isBoxed) (Il.Tmp isBoxed))
            |> jumpTo joinLbl
            |> startBlock joinLbl
            |> emit (Unary (Just ext) L Extsw (Il.Tmp isEither))
        )


-- The ONE refusal message of the kind-code reader: code 0 means NO CODE.
wordKindZeroRefusal : String
wordKindZeroRefusal =
    "qbe-rt: word arm: a heap header carries KIND CODE 0, which means NO CODE (a val-arm header). No word-arm allocator writes 0, so this object is not a word-arm block. Refusing the kind read."


-- The tag + payload words of a Value cell into the dest slot, temp supply
-- threaded (each word's payload-address temp is fresh — a first cut
-- allocated them all from one frozen state and every word shared a name).
storeValueCell : Int -> List Il.Arg -> Int -> S -> S
storeValueCell code words dest s0 =
    if wordArm s0 then
        -- The word arm's writer CAN refuse (a heap code whose layout is not
        -- settled).  Every call site is behind either the per-defun pre-walk
        -- whitelist or the area-7 Rt gate, so a refusal here is a
        -- belt-and-braces arm; it emits the POISON word (`...111`, the reserved
        -- tag the collector and every reader die on) rather than a plausible
        -- word, so a reach that slipped a gate fails at the first read instead
        -- of silently.
        case storeWordCell code words dest s0 of
            Ok s1 ->
                s1

            Err _ ->
                emit (Store StoreL (Il.Con s0.layout.tagMask) (Il.Tmp (slotTmp dest))) s0

    else
        let
            s1 =
                emit (Store StoreW (Il.Con code) (Il.Tmp (slotTmp dest))) s0

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
                                    |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (RtLayout.payloadWordOffset s0.layout i)))
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
    if wordArm s0 then
        -- AREA A (perf VR3b3): under the word arm a `mk*` cell is the ONE cell
        -- writer, and its refusals are COMPILE-TIME here (this path returns
        -- Result) rather than the writer's belt-and-braces poison.
        case wordCellRefusal tag (List.length words) of
            Just why ->
                -- The DEFUN is named, for the same reason `wordVecRefusal` names
                -- it: a site refusal is only useful if the reader knows which
                -- runtime defun has not been twinned yet (perf word-arm-area3rt).
                Err
                    (wordArmUnsupported
                        (wordArea "AREA 3 (HEAP-OBJECT CONSTRUCTION)"
                            ((if s0.defunKey == "" then "" else s0.defunKey ++ ": ") ++ why)
                        )
                    )

            Nothing ->
                List.foldl
                    (\e acc ->
                        Result.andThen
                            (\( ws, st ) ->
                                if isFloatWordExp e then
                                    rawFltArg e st
                                        |> Result.map (\( a, st2 ) -> ( ws ++ [ a ], st2 ))

                                else
                                    rawWordArg e st
                                        |> Result.map (\( a, st2 ) -> ( ws ++ [ a ], st2 ))
                            )
                            acc
                    )
                    (Ok ( [], s0 ))
                    words
                    |> Result.andThen (\( ws, s1 ) -> storeWordCell tag ws dest s1)

    else
        storeValueWordsVal tag words dest s0


storeValueWordsVal : Int -> List Exp -> Int -> S -> Result String S
storeValueWordsVal tag words dest s0 =
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
                                            |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (RtLayout.payloadWordOffset s0.layout i)))
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
            storeValueCell s.layout.tagNumber [ lenA ] slot s1

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
    if wordArm s then
        -- THE WORD ARM (perf VR3b3 area A).  The LEAN ABI's params are POINTERS
        -- to Value slots in BOTH arms (the callee reads `payload(count, 0)`
        -- through the pointer it was given), so the call's argument shape does
        -- not move — only the RESULT does.  Under the word arm the seat returns
        -- the block address as a FIXNUM (`mknum(addr)`), i.e. `addr` shifted up
        -- into the tag's free bits, so the body address is the untag (no load)
        -- plus the 2-word header.  That is what every caller consumes: a raw
        -- BODY pointer.
        let
            -- THE RETURN IS A FIXNUM, NOT A TAGGED POINTER.  VR3c's seats return
            -- `mknum(blockaddr)` (the address shifted UP into the tag bits), so
            -- the recovery is the FIXNUM untag - an arithmetic shift DOWN - and
            -- NOT `untagMask`: masking `addr << 3` with `-8` returns `addr << 3`
            -- again, i.e. eight times the address (MEASURED: the harness read a
            -- header 8x off and SEGFAULTED on the payload probe; the text pins
            -- could not see it because both spellings are one instruction).
            ( word, s6 ) =
                freshTmp s5

            ( body, s7 ) =
                freshTmp s6
        in
        ( Il.Tmp body
        , s7
            |> emit (Call (Just vp) (Agg "val") (Il.Sym ("q_" ++ mangle seatKey)) (padded ++ [ ArgVal (Base W) (Il.Con 1) ]))
            -- THE `:val` RESULT IS AN AGGREGATE TEMP, NOT A WORD.  QBE treats a
            -- temp of aggregate type as ADDRESSABLE, so using it directly in an
            -- integer op silently takes its ADDRESS (MEASURED: `sar %t1, 3`
            -- assembled to `leaq -8(%rbp), %rax; sarq $3, %rax` - it shifted the
            -- spill slot's address, and the harness SEGFAULTED on the store).
            -- So the single word is LOADED out of it first; under the word arm
            -- `:val` is `{ l }`, one word at offset 0.
            |> emit (Load (Just word) L LoadL (Il.Tmp vp))
            -- THE SEAT RETURNS `mknum(BODY)`, so the fixnum untag IS the body
            -- address: `sar tagBits`, and NO header arithmetic (BLOCKER 1).
            |> emit (Bin (Just body) L Sar (Il.Tmp word) (Il.Con s.layout.tagBits))
        )

    else
        ( Il.Tmp t
        , emit (Call (Just vp) (Agg "val") (Il.Sym ("q_" ++ mangle seatKey)) (padded ++ [ ArgVal (Base W) (Il.Con 1) ])) s5
            |> emit (Bin (Just aT) L Add (Il.Tmp vp) (Il.Con (RtLayout.payloadWordOffset s.layout 0)))
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

        Lit (LNumberBig digits) ->
            -- A raw WORD constant is `Il.Con`-shaped, i.e. a host number, so a
            -- literal above 2^53 has no honest form in this position.  Loud,
            -- never rounded.
            Err
                ("a raw-word literal above 2^53 (`"
                    ++ digits
                    ++ "`) has no exact `Il.Con` form — spell it as a value literal instead"
                )

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
            -- AREA 3 (PAYLOAD ACCESS), the ELEMENT-ADDRESS half (perf
            -- word-arm-area3rt).  The arm is UNCHANGED and it is `elemAddr`'s:
            -- it strides by the LAYOUT, so at 8 bytes it is the word arm's
            -- element address.  What was missing was not this node but a way to
            -- produce the BASE it takes — `RawVecBody`, which is why the
            -- refusal this arm used to raise is gone rather than relaxed.
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

        Unsafe (RawVecBody body) ->
            -- THE ELEMENT BASE of a Value (perf word-arm-area3rt).
            --
            -- THE VAL ARM IS THE SAME EMIT AS `payload(v, 0)` — same temps, same
            -- ops, same order — so every runtime site rewritten to `vecbody(v)`
            -- emits the val arm's .ssa BYTE FOR BYTE.  That is what keeps the
            -- corpus at 159/159 with NO re-freeze; a rewrite that emitted
            -- anything else here would MOVE the val arm, which is exactly the
            -- defect the corpus exists to catch.
            --
            -- THE WORD ARM is the SHAPE fork `wordPayloadWord` makes, one step
            -- earlier: a fixnum's payload IS the base word (a `mknum(ptr)` Value
            -- carries a raw C pointer, and the runtime's staging buffers travel
            -- that way), a heap object's base is its BODY (untag, then past the
            -- 2-word header), and an immediate has neither — so it refuses
            -- loudly, as a payload read does.  Note what is NOT here: no
            -- `payloadWordOffset`, because on this arm a payload word is not a
            -- shifted field of a 40-byte record.
            if wordArm s then
                rawValueBase body.value s
                    |> Result.map (\( base, s1 ) -> wordVecBody base s1)

            else
                rawValueBase body.value s
                    |> Result.map
                        (\( base, s1 ) ->
                            let
                                ( aT, s2 ) =
                                    freshTmp s1

                                ( t, s3 ) =
                                    freshTmp s2
                            in
                            ( Il.Tmp t
                            , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset s.layout 0))) s3
                                |> emit (Load (Just t) L LoadL (Il.Tmp aT))
                            )
                        )

        Unsafe (RawVecLen body) ->
            -- THE ELEMENT COUNT (perf word-arm-area3rt, the review's BLOCKER 2).
            --
            -- THE VAL ARM IS THE SAME EMIT AS `payload32(v, 1)` — same temps,
            -- same ops, same order — so a runtime site rewritten to `veclen(v)`
            -- emits the val arm's .ssa BYTE FOR BYTE (the corpus is the proof,
            -- and it is why this is a node rather than an arm-spliced defun: a
            -- `call Rt.vecLen(..)` would move every one of those sites on the
            -- val arm).
            --
            -- THE WORD ARM READS THE HEADER'S COUNT WORD.  `gcAlloc` writes
            -- `wstore(cursor, -1, countW)` — header word 1, i.e. ONE word
            -- before the body — because an inline body has no room for a count
            -- of its own.  The low half is taken and sign-extended, exactly as
            -- the val arm's `loadw` + `extsw` is: both arms answer an i32.
            if wordArm s then
                rawValueBase body.value s
                    |> Result.map (\( base, s1 ) -> wordVecLen base s1)

            else
                rawValueBase body.value s
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
                            , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset s.layout 1))) s4
                                |> emit (Load (Just wT) W LoadW (Il.Tmp aT))
                                |> emit (Unary (Just t) L Extsw (Il.Tmp wT))
                            )
                        )

        Unsafe (RawTagOf v) ->
            -- S2 (VR3b3 FIX): REFUSED under the word arm.  `tagof` promises the
            -- VALTAG (`Mid.Ir`'s `RawTagOf` contract), and on the word arm the
            -- value word's low bits name the SHAPE (...001 = "a heap object"),
            -- not the constructor - every heap object would answer 1, nil 2,
            -- error 5.  A consumer comparing against valtag constants would be
            -- silently wrong, so the honest answer is the loud one; `tagis` is
            -- the reader that dispatches correctly (`wordTagIs`).
            if wordArm s then
                Err
                    (wordArmUnsupported
                        (wordArea
                            "AREA 2 (TAG TESTS)"
                            "`tagof(v)` - the word arm's value tag names the SHAPE (...001 = a heap object), not the VALTAG the node promises, so a consumer comparing against valtag constants would be silently wrong; `tagis` dispatches to the word encoding and is the reader to use"
                        )
                    )

            else
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
            -- AREA B (perf VR3b3): a payload word.  A 40-byte Value's payload
            -- word `i` is at `payloadWordOffset i`; a word-arm payload is a
            -- SHAPE decided by the value's low tag (`wordPayloadWord`), and a
            -- read on a word that has no payload refuses loudly.
            if wordArm s then
                rawValueBase p.value s
                    |> Result.map (\( base, s1 ) -> wordPayloadWord base p.word s1)

            else
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
                            , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset s.layout p.word))) s3
                                |> emit (Load (Just t) L LoadL (Il.Tmp aT))
                            )
                        )

        -- ===== STEP 5 (osier-midprims): the scalar + string word producers
        Unsafe (RawPayload32 p) ->
            -- the i32 FIELDS (str.len, vector.len, boolean): loadsw at the
            -- word's low half + extsw to the l word class.  A 64-bit read
            -- here would compare garbage high halves against Zig-built
            -- Values (the extern-struct store never writes them).
            if wordArm s then
                -- AREA B + D (perf VR3b3): the i32 field of a word-arm payload
                -- word.  The shape dispatch is `wordPayloadWord`'s (the same
                -- fixnum/heap split, the same refusal), and the field is the
                -- LOW HALF of that 8-byte word: a string's `len` is body unit
                -- `lenFieldWord`, read here with no string-specific arm.
                rawValueBase p.value s
                    |> Result.map (\( base, s1 ) -> wordPayloadField32 base p.word s1)

            else
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
                            , emit (Bin (Just aT) L Add base (Il.Con (RtLayout.payloadWordOffset s.layout p.word))) s4
                                |> emit (Load (Just wT) W LoadW (Il.Tmp aT))
                                |> emit (Unary (Just t) L Extsw (Il.Tmp wT))
                            )
                        )

        Unsafe (RawTagIs ti) ->
            -- tag == n as 0/1 (w), extended to the l word class — box it with
            -- RawMkValue tag 3 to branch (`If` reads a boolean Value).
            -- AREA C (perf VR3b3): under the word arm the VALTAG is dispatched
            -- to its word ENCODING by `wordTagIs` (an immediate compare, or a
            -- header kind-code read with code 0 refused by name).
            if wordArm s then
                rawValueBase ti.value s
                    |> Result.andThen (\( base, s1 ) -> wordTagIs base ti.tag s1)

            else
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
            -- the generated-code call shape (rt_callN by name),
            -- not just a loaded code pointer in a temp.
            -- U3b: `ret` IS NO LONGER A LEGAL SHAPE HERE.  `:ret` survives
            -- only as the WORD arm's frozen closure return (see
            -- `closureRetClass`), and the word arm cannot reach a RawCallAgg
            -- at all (the ported-construct belt refuses everything but value
            -- copies), so an `aggcall ret` on the value arm would name a type
            -- the module no longer emits.  Loud, never a silent reinterpretation.
            if call.shape /= "val" then
                Err
                    ("qbe: rawCallAgg shape \""
                        ++ call.shape
                        ++ "\" — only \"val\" is legal since U3b collapsed the `:ret` call-result shape into `:val` (the `.tail` protocol is gone; a `:ret` sret block has no producer left)"
                    )

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
                            , -- THE TWO ARMS' NAMES ARRAYS CARRY DIFFERENT ELEMENT
                              -- KINDS, deliberately (perf word-arm-records R1):
                              --
                              --   val   an array of SYMBOL VALUE structs (40 B
                              --         each: tag 2, pad, name pointer, union
                              --         padding) — the SAME layout a runtime
                              --         dynamic names array has, so Rt.recGet
                              --         walks both with RawVecLoad.  Must match
                              --         gc/types.zig's Value extern struct
                              --         (tag u32@0, union@8).
                              --   word  an array of RAW NAME POINTERS (8 B
                              --         each, `DRef` words).  A word-arm symbol
                              --         is a heap block, so a symbol cannot live
                              --         in `.data` at all; the array holds the
                              --         NUL-terminated name bytes directly, and
                              --         the runtime materialises a symbol cell
                              --         only where a symbol is genuinely in a
                              --         Value position (recToChain's cars).
                              --         Each word is 8-aligned, so it reads as
                              --         tag `000` — a fixnum-looking word the
                              --         collector correctly skips.
                              items =
                                if wordArm s then
                                    List.map (\sn -> DRef sn) (List.reverse symNamesRev)

                                else
                                    List.concatMap
                                        (\sn ->
                                            [ DWord s.layout.tagSymbol
                                            , DZero (RtLayout.abiAlign - s.layout.valueTagBytes)
                                            , DRef sn
                                            , DZero (s.layout.valSizeBytes - s.layout.payloadBase - s.layout.wordBytes)
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
            -- name VERBATIM (rt_callN/a q_Rt_* defun) — a CODE
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
            -- `fload(v)` — payload word 0 of a float VALUE, read as an f64.
            --
            -- THE VAL ARM reads `slot + 8`, and the old comment here called that
            -- "a safe bit read of ANY Value (no trap on a mistagged arg)".  That
            -- is true only of a 40-byte Value: there `slot + 8` is always a
            -- payload word.  UNDER THE WORD ARM A SLOT IS EIGHT BYTES, so
            -- `slot + 8` is the NEXT FRAME SLOT — the same shape as the two
            -- defects perf word-arm-surface found, and a read of another
            -- binder's value rather than of garbage.
            --
            -- THIS IS THE SITE AREA 5 WAS OWED, and it is why the float port is
            -- not one arm in `lowerLitWord`.  The standing instruction here
            -- ("WHEN AREA 5 LANDS, THIS SITE MUST BE FORKED IN THE SAME UNIT")
            -- is discharged by `wordFloatPayload`: a word-arm float is a code-12
            -- heap block whose body unit 0 is the f64, so the read is untag ->
            -- body unit 0 -> `loadd`, with a LOUD refusal on a word that is not
            -- a heap object.  MEASURED before the fork: `main = 2.0` linked and
            -- ran on the word arm and printed a value read from the neighbouring
            -- slot, rc 0 and no stderr — the silent-wrong class.
            --
            -- EVERY float reader goes through here (`Rt.asF`, `Rt.toI32`,
            -- `Rt.fRender` — hence `Rt.floatText` and the printer — and the
            -- float arms of `Rt.=`/`Rt.<`/`Rt.<=`/`Rt.>`/`Rt.>=`/`Rt.+`/`-`/
            -- `*`/`f/`), which is what makes this the unit's second emitter
            -- change rather than an optional one.
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal v vslot s1
                |> Result.map
                    (\s2 ->
                        if wordArm s2 then
                            wordFloatPayload (Il.Tmp (slotTmp vslot)) s2

                        else
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
                            |> Result.andThen
                                (\s3 ->
                                    -- THE DATA POINTER IS A DIFFERENT SHAPE PER
                                    -- ARM (VR3b3 FIX, S1).  val: payload word 0
                                    -- of a 40-byte record, at slot+8.  word:
                                    -- body unit 0 of the heap object the value
                                    -- names, through the SAME reader as
                                    -- `payload(s, 0)` - the val-arm `slot+8`
                                    -- shape read the NEXT SLOT on the word arm,
                                    -- where a slot is 8 bytes.
                                    if wordArm s3 then
                                        let
                                            ( aT, s4 ) =
                                                wordPayloadWord (Il.Tmp (slotTmp vslot)) 0 s3
                                        in
                                        Ok
                                            (let
                                                ( bT, s5 ) =
                                                    freshTmp s4

                                                ( wT, s6 ) =
                                                    freshTmp s5

                                                ( rT, s7 ) =
                                                    freshTmp s6
                                             in
                                             ( Il.Tmp rT
                                             , s7
                                                |> emit (Bin (Just bT) L Add aT idxT)
                                                |> emit (Load (Just wT) W LoadUb (Il.Tmp bT))
                                                |> emit (Unary (Just rT) L Extuw (Il.Tmp wT))
                                             )
                                            )

                                    else
                                        Ok
                                            (let
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

        RawVecBody _ ->
            "rawVecBody"

        RawVecLen _ ->
            "rawVecLen"

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

        RawTailCall tc ->
            "rawTailCall " ++ tc.shape ++ " -> " ++ tailTargetName tc.target


tailTargetName : TailTarget -> String
tailTargetName target =
    case target of
        TailKey key ->
            key

        TailSym sym ->
            "rawsym(\"" ++ sym ++ "\")"


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
        |> emit (Bin (Just offT) L Mul (Il.Con s.layout.valSizeBytes) idxT)
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
    if wordArm s then
        lowerLitWord lit dest s

    else
        lowerLitVal lit dest s


{-| perf VR3b2, AREA 2 — THE IMMEDIATE TAG WRITES under the word arm.

A word-arm literal is a TAGGED IMMEDIATE, not a tag word plus payload words: a
fixnum is `n * 8` (tag `...000`, exact for every `n` in i61), `true`/`false` are
the `...011`/`...100` immediates.  A literal that is NOT an immediate — a float
cell, a symbol, a string — is a HEAP object and stays LOUD (areas 3/5), and so
does a fixnum outside i61, because boxing it is area 4's overflow path.
-}
lowerLitWord : Lit -> Int -> S -> Result String S
lowerLitWord lit dest s =
    case lit of
        LNumber n ->
            if n < 0 - RtLayout.wordFixnumLimit || n >= RtLayout.wordFixnumLimit then
                Err
                    (wordArmUnsupported
                        (wordArea
                            "AREA 4 (ARITHMETIC — THE i61 OVERFLOW/BOXING PATH)"
                            ("the literal " ++ String.fromInt n ++ " — it does not fit the word arm's i61 fixnum, so it has to be BOXED onto the heap, and the boxing path does not exist yet (emitting `n * 8` would silently drop its top three bits)")
                        )
                    )

            else
                Ok (emit (Store StoreL (Il.Con (n * 8)) (Il.Tmp (slotTmp dest))) s)

        LNumberBig digits ->
            -- AREA 4 (perf word-arm-area4): A BIG LITERAL IS NOW EXACT ON BOTH
            -- SIDES OF THE i61 BOUNDARY.  The range decision is made on the
            -- DIGITS — never on a host number, which is the VR3b2 trap this
            -- removes — and the value is then built from base-2^26 limbs, so a
            -- literal like 2^60-1 keeps every digit.  Inside i61 it is shifted
            -- up into the tag bits like any other fixnum; outside it is BOXED.
            --
            -- `bigmul` (2^60-1) and `above53` (2^53+1) are the inside rows;
            -- `maxi64`, `hexmax`, `mini64` are the boxed ones.  MEASURED
            -- fail-before: this arm was an EMIT refusal, so the whole `intbig`
            -- module refused to build on the word arm.
            case IntegerLiteral.limbsOf digits of
                Nothing ->
                    Err
                        ("LNumberBig \""
                            ++ digits
                            ++ "\" is not a decimal digit string — the parser validates before this form exists, so this is a compiler bug"
                        )

                Just limbs ->
                    let
                        ( t1, s1 ) =
                            freshTmp s

                        ( t2, s2 ) =
                            freshTmp s1

                        ( t3, s3 ) =
                            freshTmp s2

                        ( t4, s4 ) =
                            freshTmp s3

                        ( t5, s5 ) =
                            freshTmp s4

                        s6 =
                            s5
                                |> emit (Bin (Just t1) L Mul (Il.Con limbs.l1) (Il.Con 67108864))
                                |> emit (Bin (Just t2) L Add (Il.Tmp t1) (Il.Con limbs.l0))
                                |> emit (Bin (Just t3) L Mul (Il.Con limbs.l2) (Il.Con 4503599627370496))
                                |> emit (Bin (Just t4) L Add (Il.Tmp t3) (Il.Tmp t2))

                        s7 =
                            if limbs.negative then
                                emit (Bin (Just t5) L Sub (Il.Con 0) (Il.Tmp t4)) s6

                            else
                                s6

                        value =
                            if limbs.negative then
                                Il.Tmp t5

                            else
                                Il.Tmp t4
                    in
                    if bigLiteralFitsFixnum digits then
                        let
                            ( sh, s8 ) =
                                freshTmp s7
                        in
                        Ok (emit (Bin (Just sh) L Shl value (Il.Con s7.layout.tagBits)) s8
                                |> (\st -> storeWordWord (Il.Tmp sh) dest st)
                           )

                    else
                        Ok (boxWordInt value dest s7)

        LBoolean b ->
            Ok (emit (Store StoreL (Il.Con (if b then s.layout.tagTrue else s.layout.tagFalse)) (Il.Tmp (slotTmp dest))) s)

        LFloat f ->
            -- AREA 5, THE HEAP-BOXED FLOAT LITERAL (perf word-arm-floats).  The
            -- val arm's two steps with the CELL WRITER swapped: the double is
            -- loaded from the shared `flt:` static data item (the same
            -- `floatData` key `rawFloatOf` resolves to, so a literal has ONE
            -- data item), then handed to `storeWordFloatCell`, which allocates
            -- the code-12 block through `Rt.allocFloat`, stores the f64 at body
            -- unit 0 and tags the body.
            --
            -- THE ALLOCATION IS VISIBLE TO THE FRAME DECISION, and that is the
            -- difference from the val arm rather than a detail: this emits a
            -- real `q_Rt_x2eallocFloat` call, `Rt.allocFloat` is in
            -- `runtime.allocating`, so a surface defun whose only heap object
            -- is a float literal is ROOTED here and frame-free on the val arm.
            -- The double itself is an `l`/`d` temp across that call, never a
            -- `:val`, so there is no rooting question at this site.
            let
                ( fname, s1 ) =
                    floatData f s

                ( x, s2 ) =
                    freshTmp s1
            in
            Ok (emit (Load (Just x) D LoadD (Il.Sym fname)) s2)
                |> Result.andThen (\s3 -> storeWordFloatCell [ Il.Tmp x ] dest s3)

        LSymbol str ->
            -- A word-arm SYMBOL is a HEAP BLOCK (perf word-arm-records R1): code
            -- 2 (the constructor, so `tagis(v, 2)` answers) with ONE raw body
            -- word, the name pointer — the shape `Rt.intern` already builds,
            -- which `storeWordSymbolCell` states and justifies.  The bytes stay
            -- the static `sym:` data symbol (shared with RawCStr/RawDataAddr),
            -- so there is no copy and no cross-heap edge.
            --
            -- The one place a word-arm SYMBOL VALUE is materialised from
            -- nothing: the record family's names array holds raw name POINTERS
            -- (see `RawDataAddr`), and `recToChain` materialises cells like this
            -- one for the chain route's cars.
            let
                ( symname, s1 ) =
                    freshData ("sym:" ++ str)
                        (\n -> { name = n, align = Just 8, items = [ DStr str, DByte 0 ], export_ = False })
                        s
            in
            storeWordSymbolLiteral (Il.Sym symname) dest s1

        LString str ->
            -- A word-arm string is a HEAP BLOCK (perf VR3b3 area A): code 1 (a
            -- RAW body), body unit 0 = the byte pointer, body unit
            -- `lenFieldWord` = the length (area D's placement).  The bytes stay
            -- the static data symbol — immutable, NUL-terminated, no copy — so
            -- there is no cross-heap edge and nothing to scavenge, exactly as on
            -- the val arm; the cell owns no inline bytes (perf word-arm-rawroot
            -- item 1), which is what `storeWordStringLiteral` states.
            let
                ( strname, s1 ) =
                    freshData ("str:" ++ str)
                        (\n -> { name = n, align = Just 8, items = [ DStr str, DByte 0 ], export_ = False })
                        s
            in
            storeWordStringLiteral (Il.Sym strname) (utf8ByteLength str) dest s1


lowerLitVal : Lit -> Int -> S -> Result String S
lowerLitVal lit dest s =
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
                    afterTag (storeTag s.layout.tagNumber)
            in
            Ok (emit (Store StoreL (Il.Con n) (Il.Tmp d8)) s1)

        LNumberBig digits ->
            -- THE EXACT EMISSION (L3-U1).  The digits are the value; they reach
            -- the payload as three base-2^26 limbs (`IntegerLiteral.limbsOf`),
            -- because each limb is host-exact and the sum is the i64 the
            -- literal denotes (two's-complement wrap does the rest).
            --
            -- WHY NOT `Il.Con <digits>`: `Il.Con` carries a host `Int`, and
            -- that is exactly the number this arm exists because we do not
            -- have.  Emitting `storel <digits>` verbatim is the design's
            -- stated shape (§3.4); it needs a new `Arg` constructor read by all
            -- 85 `Con` sites, and this limb form is the same exactness with no
            -- new `Arg` arm — the emitted .ssa says two `mul`s and two `add`s
            -- where the design's sketch says one `storel`.
            case IntegerLiteral.limbsOf digits of
                Nothing ->
                    Err
                        ("LNumberBig \""
                            ++ digits
                            ++ "\" is not a decimal digit string — the parser validates before this form exists, so this is a compiler bug"
                        )

                Just limbs ->
                    let
                        ( d8, s1 ) =
                            afterTag (storeTag s.layout.tagNumber)

                        ( t1, s2 ) =
                            freshTmp s1

                        ( t2, s3 ) =
                            freshTmp s2

                        ( t3, s4 ) =
                            freshTmp s3

                        ( t4, s5 ) =
                            freshTmp s4

                        ( t5, s6 ) =
                            freshTmp s5

                        -- `l0 + l1 * 2^26 + l2 * 2^52`, then `0 - v` for a
                        -- negative literal.  2^26 and 2^52 are powers of two,
                        -- so both constants are exact on every host, and the
                        -- intermediate products WRAP in two's complement —
                        -- which is exactly the i64 bit pattern wanted (a
                        -- 2^63 magnitude lands on INT64_MIN).
                        s7 =
                            emit (Bin (Just t1) L Mul (Il.Con limbs.l1) (Il.Con 67108864)) s6

                        s8 =
                            emit (Bin (Just t2) L Add (Il.Tmp t1) (Il.Con limbs.l0)) s7

                        s9 =
                            emit (Bin (Just t3) L Mul (Il.Con limbs.l2) (Il.Con 4503599627370496)) s8

                        s10 =
                            emit (Bin (Just t4) L Add (Il.Tmp t3) (Il.Tmp t2)) s9

                        s11 =
                            if limbs.negative then
                                emit (Bin (Just t5) L Sub (Il.Con 0) (Il.Tmp t4)) s10

                            else
                                s10

                        stored =
                            if limbs.negative then
                                Il.Tmp t5

                            else
                                Il.Tmp t4
                    in
                    Ok (emit (Store StoreL stored (Il.Tmp d8)) s11)

        LBoolean b ->
            let
                ( d8, s1 ) =
                    afterTag (storeTag s.layout.tagBoolean)
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
                    afterTag (storeTag s.layout.tagSymbol)

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
            Ok (storeValueCell s.layout.tagString [ Il.Sym strname, Il.Con (utf8ByteLength str) ] dest s1)


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

NEVER UNDER THE WORD ARM, and the reason is measured (perf word-arm-surface).
S4's premise is that a raw `l` operand holds the number, and every reader and
writer of that premise is 40-byte-shaped: `rawIntOf`'s boxed `Var` reads the
payload at `slot + 8`, and `reboxArg` writes `tagNumber` at the slot and the
payload at `slot + 8` — i.e. SIXTEEN bytes into an EIGHT-byte slot, clobbering
the next one.  A program with no arithmetic at all reached it: `let ( a, b ) =
( 1, "hi" )` proved `a` an Int from its literal, held it raw, reboxed it at the
boundary, and the word arm printed `0` for `1`.  The val arm's tag/untag is AREA
4's worklist item, so the honest state is "this optimisation does not exist
here", and refusing it at the ONE decision point keeps the shape it would have
had anyway: a frame slot written by `lowerLitWord`.
-}
isIntExp : S -> Exp -> Bool
isIntExp s exp =
    s.rep && not (wordArm s) && isIntKnown s exp


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

        Lit (LNumberBig _) ->
            -- NOT admitted, deliberately: every caller of `isIntKnown` feeds
            -- `rawInt2`, whose operand form is `Il.Con Int` — a HOST number,
            -- i.e. exactly what a big literal is not. Denying it here routes
            -- the expression to the general path, which materializes the
            -- literal exactly (`lowerLitVal`'s limb arm) and then computes.
            -- Slower for that one expression, exact; admitting it would mean a
            -- rounded operand in the fast path.
            False

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

        Lit (LNumberBig digits) ->
            Err
                ("an i64 literal above 2^53 (`"
                    ++ digits
                    ++ "`) has no exact `Il.Con` operand — the raw Int fast path cannot carry it"
                )

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
                                                |> emit (Cmp (Just is14T) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagRecord))
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
                                                |> emit (Bin (Just p) L Add (Il.Tmp d) (Il.Con (s.layout.valSizeBytes * rank + 8)))
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
    emit (Store StoreW (Il.Con s.layout.tagNumber) (Il.Tmp (slotTmp dest))) s1
        |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dest)) (Il.Con 8))
        |> emit (Store StoreL raw (Il.Tmp d8))


{-| REBOX a `w`-typed comparison result as a tagged Boolean Value.  The VM's
booleans carry a WORD payload (`lowerLit`'s `LBoolean` arm stores `StoreW`), so
this is that same shape, not a new one.

VAL ARM ONLY, and the reason is the 40-byte shape it writes: `StoreW tagBoolean`
at `slot + 0` then the payload at `slot + 8` is TWELVE bytes into an EIGHT-byte
slot under the word arm — the next slot's value clobbered with a tag, the same
defect class perf word-arm-surface found in `reboxArg`.  A word-arm boolean is
ONE immediate (`tagTrue + (w == 0)`, `storeWordCell RtLayout.tagBoolean [w]`).

NOTHING FORKS IT HERE, and what keeps that safe is REACHABILITY, not a belt —
MEASURED, the same way `RawLoadFlt`'s note was: under the word arm every caller
is either dead or refused.  `lowerCompare`/`lowerNumEq`'s proven-Int and
proven-Float arms are denied by `isIntExp`/`isFloatExp` (which return False
under the arm), and `lowerStrCmp` — the only remaining caller — refuses BY NAME
at `lowerCompare`'s string branch before it can reach this function.  THE
STANDING INSTRUCTION: whoever ports Char/String ordering to the word arm must
fork this in the SAME unit, to `storeWordCell RtLayout.tagBoolean [ raw ]`.
-}
reboxBoolean : Int -> Il.Arg -> S -> S
reboxBoolean dest raw s =
    let
        ( d8, s1 ) =
            freshTmp s
    in
    emit (Store StoreW (Il.Con s.layout.tagBoolean) (Il.Tmp (slotTmp dest))) s1
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
one decision, one place to read `s.rep` — and, for the same measured reason, one
place to read the ARM.  `reboxFloat` writes a `tagFloat` word at the slot and
the double at `slot + 8`, the 40-byte shape; a raw Float local on the word arm
would clobber the next slot.  AREA 5 does not exist here yet.
-}
isFloatExp : S -> Exp -> Bool
isFloatExp s exp =
    s.rep && not (wordArm s) && isFloatKnown s exp


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
    emit (Store StoreW (Il.Con s.layout.tagFloat) (Il.Tmp (slotTmp dest))) s1
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
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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
                            emit (Blit (Il.Tmp (slotTmp slot)) (Il.Tmp (slotTmp (i + resultSlotBase s.layout))) s.layout.valSizeBytes) acc
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
                |> emit (Bin (Just ptmp) L Add (Il.Tmp base) (Il.Con (s.layout.valSizeBytes * i)))
                |> emit (Blit (Il.Tmp (slotTmp slot)) (Il.Tmp ptmp) s.layout.valSizeBytes)
        )
        s1
        (List.indexedMap (\i slot -> ( slot, i )) slots)
    )


{-| AREA 6 — WHAT ONE ARGUMENT CROSSES AS, in ONE place.

On the VALUE arm each argument is the ADDRESS of the rooted frame slot it was
lowered into (VR1): the callee blits 40 bytes out of it at entry, and a
pointer into the caller's live frame is what makes the lazy read sound.

On the WORD arm a value parameter IS ONE WORD (`:val` is 8 bytes, VR1's
word-arm convention), so the slot's WORD is loaded and the register carries
the value itself.  Passing the address there would make the callee dereference
a fixnum — the arm's silent-wrong shape, and the reason this is a fork and not
a comment.

BOTH arms hand the callee one `l` operand per argument; only its meaning
flips, which is why every RtGeneric call site goes through here.
-}
argOperands : List Int -> S -> ( List Il.CallArg, S )
argOperands slots s =
    if wordArm s then
        List.foldl
            (\sl ( acc, st ) ->
                let
                    ( v, st1 ) =
                        freshTmp st
                in
                ( acc ++ [ ArgVal (Base L) (Il.Tmp v) ]
                , emit (Load (Just v) L LoadL (Il.Tmp (slotTmp sl))) st1
                )
            )
            ( [], s )
            slots

    else
        ( List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots, s )


{-| U3a: an ORDINARY call reached from a TAIL position still has to close the
block.  Before this unit the non-tail lowering was unreachable in tail position
(the tcall arm and the tail-known arm both terminated), so `lowerTail`'s App arm
could hand the block straight to `@ret`; with the arity-5+ sites going non-tail
the value is blitted into slot 0 and the block must `jmp @ret` itself.  MEASURED
as the bug that made the first cut emit a function with no `@body` at all (a
qbe `block @body is used undefined`) — an unterminated block is DROPPED, not
an error.
-}
tailClose : Bool -> S -> S
tailClose isTail s =
    if isTail then
        jumpTo "ret" s

    else
        s


-- Direct saturated call to a known defun.  TWO lowerings, a STATIC choice:
--
--   * TAIL within the tcall budget (arity <= maxTailCallArgs): a real `tcall`
--     after Rt.stage-tail + rt_frame_leave.  The callee returns straight to
--     OUR caller, so the chain is constant-stack.
--   * everything else (non-tail, arity over the budget, or a body class that
--     cannot carry a `tcall`): an ordinary `call`.  U3a deleted the third
--     answer — `Rt.tail-known` building a `.tail` request for Rt.bounce to
--     chase — because nothing builds a `.tail` any more; the 240 arity-5+
--     sites keep a correct, rlimit-bounded, growing lowering (one frame per
--     hop, the design's priced 95%/240 split), and the non-tail call returns
--     the finished Value with NO bounce — U3b deleted the bounce itself.
directCall : String -> List Exp -> Int -> Bool -> S -> Result String S
directCall key args dest isTail s =
    if isTail && s.tailEmit && List.length args <= maxTailCallArgs then
        -- ================= Q1b: A REAL TAIL CALL =================
        -- `tcall :val $q_F(l %b0, ..., l %bN)` — the callee returns straight
        -- to OUR caller (abi1 forwards fn->retr as its hidden sret argument,
        -- which is why C4 demands the callee's return class equal ours).
        --
        -- THE MID CONVENTION, in the order the instructions are emitted:
        --   1. stageArgs: lower every arg into a ROOTED frame slot (an arg's
        --      own lowering can contain calls — safepoints — and only slots
        --      survive those), then copy them into ONE contiguous frame block.
        --   2. Rt.stage-tail: copy that block into memory that SURVIVES our
        --      rt_frame_leave (tsbuf for <=3 args, the GC allocvec above it).
        --      This copy is not redundant: our pooled frame goes back to the
        --      pool and the callee's frame-enter may pop and MEMSET the same
        --      block, so a pointer into our own frame would hand the callee
        --      its own zeroing.
        --   3. %b<i> = %buf + 40*i — the argument pointers the callee blits
        --      from at entry.
        --   4. rt_frame_leave: our pooled frame is left HERE, before the jump.
        --   5. the tcall (which tears down the machine frame and jumps), then
        --      a bare `ret` — required by the IL grammar; emit.c suppresses it
        --      because the block already ended in the jmp.
        -- Between (2) and the callee's prologue blit NOTHING can collect, so
        -- the unrooted staged copies are safe.  Keep it that way: do not add a
        -- GC-allocating call to this sequence.
        --
        -- AREA 6 — THE WORD ARM NEEDS NO STAGING AT ALL, and the reason is the
        -- convention, not a shortcut: its arguments cross in REGISTERS, so
        -- there is nothing that has to survive our rt_frame_leave.  The words
        -- are loaded out of their rooted slots BEFORE the leave (QBE spills a
        -- temp live across a call to its own machine frame, which the leave
        -- does not touch — the leave releases the POOLED block), and the
        -- staged copy exists only to keep POINTERS valid, which this arm never
        -- passes.  Keeping Rt.stage-tail here would be a copy of data nobody
        -- reads, and its `nargs * sizeof(val)` count is the one place the
        -- runtime's own stride would then have to be right for nothing.
        lowerArgsToSlots args s
            |> Result.andThen
                (\( slots, s1 ) ->
                    if wordArm s then
                        let
                            ( operands, s2 ) =
                                argOperands slots s1
                        in
                        Ok
                            (emit (Call Nothing (Base W) (Il.Sym ("q_" ++ mangle "Rt.frame-leave")) []) s2
                                |> emit (TailCall (closureRetClass s) (Il.Sym ("q_" ++ mangle key)) operands)
                                |> closeBlock (Ret Nothing)
                            )

                    else
                        let
                            ( _, base, s2 ) =
                                stageSlots slots s1

                            nargs =
                                List.length args

                            ( bp, s3 ) =
                                freshTmp s2

                            argPtrs =
                                List.map (\i -> ( bp ++ "_" ++ String.fromInt i, i )) (List.range 0 (nargs - 1))
                        in
                        rawAbiArityAgree "Rt.stage-tail" 2
                            |> Result.andThen
                                (\_ ->
                                    Ok
                                        (emit
                                            (Call (Just bp)
                                                (Base L)
                                                (Il.Sym ("q_" ++ mangle "Rt.stage-tail"))
                                                [ ArgVal (Base L) (Il.Tmp (slotTmp base))
                                                , ArgVal (Base L) (Il.Con nargs)
                                                ]
                                            )
                                            s3
                                            |> (\sx ->
                                                    List.foldl
                                                        (\( ptmp, i ) acc ->
                                                            emit (Bin (Just ptmp) L Add (Il.Tmp bp) (Il.Con (sx.layout.valSizeBytes * i))) acc
                                                        )
                                                        sx
                                                        argPtrs
                                               )
                                            |> emit (Call Nothing (Base W) (Il.Sym ("q_" ++ mangle "Rt.frame-leave")) [])
                                            |> emit
                                                (TailCall
                                                    (closureRetClass s)
                                                    (Il.Sym ("q_" ++ mangle key))
                                                    (List.map (\( ptmp, _ ) -> ArgVal (Base L) (Il.Tmp ptmp)) argPtrs)
                                                )
                                            |> closeBlock (Ret Nothing)
                                        )
                                )
                )

    else
        -- NON-TAIL — and, since U3a, ALSO the arity-5+ STATIC TAIL site: a
        -- tcall's register budget is four (rdi is spent on the hidden sret
        -- pointer, rax on a closure's env), and the old answer for the 240
        -- sites over that budget was `Rt.tail-known` — build a `.tail`
        -- request, blit it into the return area, and let Rt.bounce chase it.
        -- Nothing builds a `.tail` any more, so those sites take the ordinary
        -- call: a CORRECT, rlimit-bounded, growing lowering (the design's
        -- 95%/240 split, unchanged), one frame per hop instead of none.
        -- U3b deleted Rt.tail-known with the rest of the `.tail` family, so
        -- this arm is the ONLY answer left over the tcall budget.
        --
        -- VR1 — each arg crosses as an `l` POINTER to the rooted frame slot it
        -- was just lowered into.  The contiguous staging block (and the
        -- 40-byte copy into it) is gone: the slot IS the argument.  U3a: the
        -- callee returns the finished Value (a surface defun's body is `:val`
        -- now), so there is no `.done` to unwrap and NO BOUNCE.
        --
        -- AREA 6 made the two arms ONE shape again: the argument's MEANING
        -- flips (address vs word — `argOperands`) and the width flips (40 vs
        -- 8), but the result class is `:val` on both, so the call, the blit
        -- and the tail close are written once.
        lowerArgsToSlots args s
            |> Result.andThen
                (\( slots, s1 ) ->
                    let
                        ( operands, s2 ) =
                            argOperands slots s1

                        ( rp, s3 ) =
                            freshTmp s2
                    in
                    Ok
                        (emit (Call (Just rp) (closureRetClass s) (Il.Sym ("q_" ++ mangle key)) operands) s3
                            |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
                            |> tailClose isTail
                        )
                )


-- Generic application through the runtime (first-class closures, partials,
-- over-application).  BOTH arms now hand back the finished `:val`: the non-tail
-- Rt.apply returns applyGo's value, and the tail arm `tcall`s Rt.apply-tail
-- (U3a), whose chain returns the value too — there is no `.tail` shape left to
-- blit into the return area.
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
        -- that lowerDefun's ret type also reads.  The old code hard-wired
        -- `Agg "ret"`/`Agg "val"` and a second size table here: a 40-vs-80-byte
        -- sret drift (someone edits rawAbiRetClass, or adds a third aggregate
        -- class) would silently read/write 40 B of adjacent memory at the
        -- blit.  Deriving both from the one function makes that drift
        -- impossible.  U3b: with the `Agg "ret"` key gone there is exactly ONE
        -- aggregate answer left, so the size is simply the module's `:val`.
        retCls =
            rawAbiRetClass midKey

        retSize =
            s.layout.valSizeBytes
    in
    stageArgs args s
        |> Result.andThen
            (\( _, baseSlot, s1 ) ->
                rawAbiArityAgree midKey 3
                    |> Result.andThen
                        (\_ ->
                            if isTail && s.tailEmit then
                                -- ============ U2/U3a: A REAL TAIL CALL ============
                                -- `tcall :val $q_Rt.apply-tail(l %buf, l %b0, l %b1, l n)`
                                -- — the generic-apply tail site RETURNS THROUGH
                                -- US instead of nesting two frames per hop.
                                --
                                -- LEGAL ONLY BECAUSE THE CLASSES MATCH: `Rt.apply-tail`
                                -- is `rawAbiRetClass` Agg "val" (40 B) and so is the
                                -- enclosing RtGeneric body (`s.tailEmit` is TRUE
                                -- exactly there) — abi1's C4.  U2 emitted `:ret`
                                -- here because the body's class WAS `:ret`; U3a's
                                -- flip moved both together, which is the only way
                                -- the next hop (apply-tail -> applyTailGo) could
                                -- become a tcall as well.
                                --
                                -- THE SEQUENCE, in emission order (the Mid
                                -- convention, and the reason each step exists):
                                --   1. stageArgs: lower every arg into a ROOTED
                                --      frame slot, then copy them into ONE
                                --      contiguous frame block (an arg's own
                                --      lowering may call — safepoints — and only
                                --      slots survive those).
                                --   2. Rt.stage-apply: copy the closure CELL and
                                --      that block into ONE C-HEAP (malloc'd) block
                                --      shaped [closure, arg0..argN].  It SURVIVES our
                                --      rt_frame_leave (our pooled frame goes back
                                --      to the pool and the callee's frame-enter
                                --      may pop and MEMSET it).  NEVER the shared
                                --      tsbuf — an over-applied chain can hold two
                                --      staged blocks at once (see the seat).  NOT
                                --      the GC nursery either: the block must
                                --      survive the applied callee's whole body,
                                --      whose allocation volume is user-controlled
                                --      (the lapprobe row; U2's fix).
                                --   3. %b<i> = %buf + 40*i — the two argument
                                --      pointers Rt.apply-tail takes as
                                --      (fslot, args) = (buf, buf + 40).
                                --   4. rt_frame_leave: OUR frame is left HERE.
                                --   5. the tcall (teardown + jmp), then a bare
                                --      `ret` — required by the IL grammar; emit.c
                                --      suppresses it because the block already
                                --      ended in the jmp.
                                -- Between (2) and the callee's read of `buf`
                                -- NOTHING can collect, so the unrooted staged copy
                                -- is safe.  Keep it that way.
                                let
                                    nargs =
                                        List.length args

                                    ( bp, s2 ) =
                                        freshTmp s1

                                    argPtrs =
                                        List.map (\i -> ( bp ++ "_" ++ String.fromInt i, i )) (List.range 0 1)
                                in
                                rawAbiArityAgree "Rt.stage-apply" 3
                                    |> Result.andThen
                                        (\_ ->
                                            Ok
                                                (emit
                                                    (Call (Just bp)
                                                        (Base L)
                                                        (Il.Sym ("q_" ++ mangle "Rt.stage-apply"))
                                                        [ ArgVal (Base L) (Il.Tmp fslotTmp)
                                                        , ArgVal (Base L) (Il.Tmp (slotTmp baseSlot))
                                                        , ArgVal (Base L) (Il.Con nargs)
                                                        ]
                                                    )
                                                    s2
                                                    |> (\sx ->
                                                            List.foldl
                                                                (\( ptmp, i ) acc ->
                                                                    emit (Bin (Just ptmp) L Add (Il.Tmp bp) (Il.Con (sx.layout.valSizeBytes * i))) acc
                                                                )
                                                                sx
                                                                argPtrs
                                                       )
                                                    |> emit (Call Nothing (Base W) (Il.Sym ("q_" ++ mangle "Rt.frame-leave")) [])
                                                    |> emit
                                                        (TailCall
                                                            retCls
                                                            (Il.Sym callee)
                                                            [ ArgVal (Base L) (Il.Tmp (bp ++ "_0"))
                                                            , ArgVal (Base L) (Il.Tmp (bp ++ "_1"))
                                                            , ArgVal (Base L) (Il.Con nargs)
                                                            ]
                                                        )
                                                    |> closeBlock (Ret Nothing)
                                                )
                                        )

                            else if isTail then
                                -- ================= A GUARD, NOT A CODE PATH =================
                                -- PROVABLY UNREACHABLE (handoff-apply-chain-u2-review
                                -- NICE-TO-HAVE 4), and the pre-U2 lowering that used to
                                -- live here is DELETED rather than kept as a branch no gate
                                -- reaches.  Every body that can hold a generic apply is
                                -- RtGeneric: lowerFunBody classifies away from RtGeneric
                                -- only for Rt.* keys, lowerClosure always passes
                                -- RtGeneric, and the RtLang lane cannot express a generic
                                -- apply at all (every App it lowers has a GRef head).  It
                                -- is a GUARD because the alternative is worse than an
                                -- error: the old shape would now feed Rt.apply-tail the
                                -- pre-U2 (fslot, frame-args) convention, whose failure is a
                                -- rooting gap — a range of `nargs` from the block drops the
                                -- LAST ARG — and not a crash.  Loud here, loud in abi1's
                                -- C4 if it ever fires.
                                Err
                                    ("qbe: internal — a generic apply in TAIL position inside "
                                        ++ s.defunKey
                                        ++ ", whose body is not RtGeneric.  A `tcall` into Rt.apply-tail is legal only where the enclosing return class EQUALS the callee's (abi1's C4 — `closureRetClass`, i.e. `:val` on the value arm), and the pre-U2 call+blit+jump lowering is deleted because it would pass the old (fslot, frame-args) convention into the new Rt.apply-tail body."
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

                RawVecBody _ ->
                    True

                RawVecLen _ ->
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
rt_callN/rt_call2r are called BY NAME with an aggregate result,
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
                rawWordCallArgs call.args s1
                    |> Result.map (\( args, s2 ) -> ( fnA, args, s2 ))
            )


{-| The shared raw-WORD argument lowering: every argument through
`rawWordArg`, each a `Base L` word, in source order.  Shared by `RawCallAgg`
and the DSL tail call (U1) so the two call shapes cannot disagree about how
an argument crosses — and so the `tailcall`'s "word-class only" checker rule
(J16) has exactly ONE emitter to be true about.
-}
rawWordCallArgs : List Exp -> S -> Result String ( List Il.CallArg, S )
rawWordCallArgs args s =
    List.foldl
        (\e acc ->
            Result.andThen
                (\( accArgs, st ) ->
                    rawWordArg e st
                        |> Result.map (\( a, st2 ) -> ( accArgs ++ [ ArgVal (Base L) a ], st2 ))
                )
                acc
        )
        (Ok ( [], s ))
        args


{-| U1 (handoff apply-chain) — THE DSL TAIL CALL: `tcall <shape> <callee>(words)`
followed by a bare `ret`, BLOCK-FINAL (Q1a's `Il.TailCall`, the instruction
Q1b uses for Lower's own static tail sites).  The block's `@ret` stays
emitted and unreachable — MEASURED as 11 bytes of `.text` per defun (U2's
census), not per hop.

THE CALLEE.  A `TailKey` defun is mangled here, beside every other `q_` name,
and must be IN THIS COMPILE — a tcall to a defun that was never seeded would
be an undefined symbol at assembly, so it is refused by name instead.  A
`TailSym` symbol is baked in verbatim (the backend-generated `rt_call2r`
family is its site).  An empty symbol is refused: it would emit `$()`.

THE FRAME-LEAVE GUARD (the design's sixth refusal, and the one no other layer
can state).  A `tcall` jumps out of this machine frame: the IL's own teardown
frees the dynalloc/scratch region BEFORE the `jmp`, and — for a defun holding
a POOLED frame — the pooled block would never go back to the pool, so a chain
of hops would LEAK one block per hop (an RSS regression nothing in the gate
surface sees, because each individual run still answers correctly).  The DSL
spells its own exit protocol in Mid source (the LIFO order interleaves
runtime-owned pops with the frame pop, which no Lower-side automatic leave can
express), so this arm only CHECKS that the current block already emitted
`Rt.frame-leave` before the terminator.  A PAlloc body (frame-free lean /
rawAbi) owns no pooled block and needs none.
-}
lowerRawTailCall : { target : TailTarget, args : List Exp, shape : String } -> S -> Result String S
lowerRawTailCall tc s =
    if tc.shape /= "ret" && tc.shape /= "val" then
        Err ("qbe: rawTailCall shape \"" ++ tc.shape ++ "\" — only \"ret\" and \"val\" are legal")

    else if s.pooledFrame && not (emittedFrameLeave s) then
        Err
            ("qbe: `tailcall` in "
                ++ s.qname
                ++ " — this defun holds a POOLED frame and the block has not left it before the tail call.  The callee's frame-enter may pop and MEMSET the same pooled block, so the caller's frame must be left FIRST: spell `call Rt.frame-leave();` (after any registry pops it must follow) immediately before the `tailcall`.  Without it every hop orphans one pooled block — a leak no value check sees"
            )

    else
        case tailCallCallee s tc.target of
            Err msg ->
                Err msg

            Ok ( fnA, s0 ) ->
                rawWordCallArgs tc.args s0
                    |> Result.map
                        (\( args, s1 ) ->
                            let
                                ( parked, s2 ) =
                                    freshLbl "taildead" s1
                            in
                            -- `Ret Nothing` closes the block (the IL requires a
                            -- terminator; emit.c suppresses the `ret` because
                            -- the tcall already jumped).  The PARKED label is
                            -- defensive: a caller that emitted after this term
                            -- would otherwise reopen a block with this same
                            -- label and produce a duplicate — the checker
                            -- admits no such caller today, and the park makes
                            -- one a no-op instead of an unassemblable module.
                            startBlock parked
                                (closeBlock (Ret Nothing)
                                    (emit (TailCall (Agg tc.shape) fnA args) s2)
                                )
                        )


{-| The tail call's callee, as an `Il.Arg`, plus the loud refusals: a defun
key must be in this compile, an extern symbol must be a real name.  Mirrors
`lowerRawCallAgg`'s callee rule (a `Con`/data symbol is never a call target)
with the two extra facts only a tcall's target can carry.
-}
tailCallCallee : S -> TailTarget -> Result String ( Il.Arg, S )
tailCallCallee s target =
    case target of
        TailKey key ->
            if Dict.member key s.defuns then
                Ok ( Il.Sym ("q_" ++ mangle key), s )

            else
                Err ("qbe: `tailcall` to " ++ key ++ " — not in this compile (Mid.Rt.driverSeeds/gcSeeds must seed it); the emitted tcall would name an undefined symbol")

        TailSym sym ->
            if sym == "" then
                Err "qbe: `tailcall rawsym(\"\")` — an empty extern symbol would emit `$()`"

            else
                Ok ( Il.Sym sym, s )


{-| Has the CURRENT block already emitted `Rt.frame-leave`?  The DSL spells
its own exit protocol, so "before the terminator" is exactly "somewhere in
this block's instruction list" — the pops that must FOLLOW the frame-leave
(dance-pop -> frame-leave -> args-pop -> free) are in the same block, which is
why the check cannot be "the immediately preceding instruction".
-}
emittedFrameLeave : S -> Bool
emittedFrameLeave s =
    List.any
        (\inst ->
            case inst of
                Call _ _ (Il.Sym name) [] ->
                    name == "q_" ++ mangle "Rt.frame-leave"

                _ ->
                    False
        )
        s.curBody



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

        Lit (LNumberBig _) ->
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

        RawVecBody _ ->
            True

        RawVecLen _ ->
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
                            (if wordArm s then
                                -- WORD ARM (area 2): a boolean is an IMMEDIATE —
                                -- `true` is `...011`, `false` is `...100` — so the
                                -- test is the tag compare alone.  There is no
                                -- payload word to read (the val arm's second
                                -- compare and its AND are the whole difference),
                                -- and a non-boolean condition takes the ELSE
                                -- branch, exactly as the val arm's
                                -- `isBool && payload == 0` does.
                                readTag tagT (Il.Tmp (slotTmp cslot)) s10
                                    |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagTrue))
                                    |> closeBlock (Jnz (Il.Tmp isbT) thenLbl elseLbl)

                             else
                                emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp cslot))) s10
                                    |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagBoolean))
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
            in
            lowerVal block.cond cslot (startBlock topLbl (jumpTo topLbl s4))
                |> Result.map
                    (\st ->
                        -- the VM's jmpf test: a FALSY value EXITS the loop.  The
                        -- test itself is `falsyJump` — the same one `lowerIf`
                        -- uses, so the arm's tag question is asked in one place.
                        falsyJump cslot exitLbl bodyLbl st
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
        -- THE EXPECTED VALUE IS A VALTAG, and it is the TOP-LEVEL constant, not
        -- `s.layout.tagCons`.  MEASURED (this site, first run): the word
        -- instance's `tagCons` field is the POINTER TAG (1 — every word-arm heap
        -- object carries it), while the KIND that identifies a cons is the
        -- VALTAG 4.  Passing `s.layout.tagCons` therefore asked "is this a
        -- kind-1 block?" and every cons answered no, so `1 :: 2 :: []` fell
        -- through both alternatives and died "non-exhaustive case" on a
        -- well-formed value.  The val instance's fields equal the top-level
        -- constants, so the val emit is unchanged (the corpus says so).
        MCons steps ->
            lowerTagMatch steps scrutSlot RtLayout.tagCons failLbl s

        MEmpty steps ->
            lowerTagMatch steps scrutSlot RtLayout.tagNil failLbl s

        MVector steps ->
            lowerTagMatch steps scrutSlot RtLayout.tagVector failLbl s

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
            --
            -- THE WORD ARM NEVER INLINES IT (perf word-arm-frontier), and this
            -- is a CORRECTNESS fork, not a perf choice:
            --   * the inline's whole emission is "the name pointer is the
            --     payload WORD of the symbol Value", read at `slot + 8`.  On the
            --     word arm a slot holds ONE word (the tagged body), so `slot + 8`
            --     is the NEXT FRAME SLOT — the exact `fieldBase` defect this arc
            --     already paid for once.  The name there is BODY WORD 0
            --     (`fieldBase 0` plus a load): a different accessor, not a
            --     different constant;
            --   * the inline is LICENSED by pointer identity of the compiler's
            --     content-keyed `sym:` blobs.  That licence survives `Con` (a
            --     constructor's tag symbol and the pattern's literal both come
            --     from the same `freshData "sym:"` dedup), but it is a licence
            --     the runtime's symbols do not have to honour: `Rt.intern` builds
            --     a code-2 cell whose name is a MALLOC'd copy.  `Rt.=`'s symbol
            --     arm is `payload(a,0) == payload(b,0) || Rt.symEq(a, b, 0)`, and
            --     on the word arm `payload(v, 0)` IS the name pointer while
            --     `strbyte`/`symEq` are UNCHANGED (stated at `Rt.allocSym`), so
            --     the runtime route is byte-correct without that licence on
            --     EITHER arm.
            -- The cost is a call per tag test.  A word-arm inline is a follow-up,
            -- and if it is written it must go through ONE named accessor
            -- (`symbolNamePtr`: val = the payload word, word = body word 0) —
            -- the two arms' payload word means two different things, which is
            -- the rule `fieldBase`'s doc states.
            if (s.typeSpec && steps == [ IdxStep 0 ] && (Maybe.map isUserAdt scrutType == Just True)) && not (wordArm s) then
                lowerPtrEqMatch steps scrutSlot tag failLbl s

            else
                lowerEqMatch steps scrutSlot (LSymbol tag) failLbl s

        MLitEq steps lit ->
            lowerEqMatch steps scrutSlot lit failLbl s


-- Read the value at `steps`, test its tag == expected; pass -> passLbl,
-- fail -> failLbl.
--
-- THE TEST ITSELF IS ARM-SPLIT, and the word half is NOT a tag compare: under
-- the word arm every heap object carries the SAME `...001` pointer tag, so
-- `expected` names a KIND (cons = 4, vector = 10) that lives in the GC header,
-- not in the word — while nil is an IMMEDIATE and stays a tag compare.
-- `wordTagIs` is that reader, already written and probe-pinned for `tagis`, and
-- `RtLayout.wordTagShape` is what decides which of the two a valtag is, so this
-- site cannot disagree with the encoding.  A valtag with no word-arm encoding
-- refuses at COMPILE time (hence the `Result`).
lowerTagMatch : List Step -> Int -> Int -> String -> S -> Result String S
lowerTagMatch steps scrutSlot expected failLbl s =
    let
        ( p, s1 ) =
            freshSlot s

        sRead =
            readSteps steps scrutSlot p s1
    in
    if wordArm s then
        let
            ( passLbl, s2 ) =
                freshLbl "cpass" sRead
        in
        wordTagIs (Il.Tmp (slotTmp p)) expected s2
            |> Result.map
                (\( flag, s3 ) ->
                    closeBlock (Jnz flag passLbl failLbl) s3
                        |> startBlock passLbl
                )

    else
        let
            ( tagT, s2 ) =
                freshTmp sRead

            ( isM, s3 ) =
                freshTmp s2

            ( passLbl, s4 ) =
                freshLbl "cpass" s3
        in
        Ok
            (emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp p))) s4
                |> emit (Cmp (Just isM) W Ceq (Il.Tmp tagT) (Il.Con expected))
                |> closeBlock (Jnz (Il.Tmp isM) passLbl failLbl)
                |> startBlock passLbl
            )


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
--
-- VAL ARM ONLY (perf word-arm-frontier).  `+8` is the 40-byte shape; on the word
-- arm the name is body word 0 behind the tagged pointer, so `lowerMatch` never
-- reaches this function there.  The doc above ("the payload pointer at +8") is
-- therefore a statement about ONE arm — the reason a word-arm version of it must
-- be a named accessor rather than this constant.
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
                lowerVal (recordAccessBody s3.layout recB Nothing field) dest s3

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
            emit (Blit (Il.Tmp (slotTmp src)) (Il.Tmp (slotTmp dst)) s.layout.valSizeBytes) s

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
            chaseField 0 src dst s

        SndStep ->
            if s.consArr then
                chaseCdr src dst s

            else
                chaseField 1 src dst s

        HdStep ->
            lowerHdTl True src dst s

        TlStep ->
            lowerHdTl False src dst s

        IdxStep j ->
            -- Element `j` of an ADT vector.  `IdxStep` is produced ONLY for a
            -- constructor pattern's arguments (`Mid.FromAst`'s ADT branch,
            -- `IdxStep (j + 1)`), and `KindCon` is the only shape
            -- `Mid.Qbe.Flatten` resolves it against, so the base is always a
            -- VECTOR body — which is what `fieldBase` returns on both arms.
            let
                ( dataBase, s1 ) =
                    fieldBase 0 src s

                ( eT, s2 ) =
                    freshTmp s1
            in
            emit (Bin (Just eT) L Add dataBase (Il.Con (s.layout.valSizeBytes * j))) s2
                |> emit (Blit (Il.Tmp eT) (Il.Tmp (slotTmp dst)) s.layout.valSizeBytes)


{-| THE BASE OF PAYLOAD WORD `n` OF THE VALUE IN SLOT `src` — the ONE statement
of the difference between the arms for every pointer chase in the pattern
matcher (perf word-arm-surface).

`n` IS A PAYLOAD WORD INDEX, NOT A BYTE OFFSET, and that is load-bearing: the
val arm's payload words are 8 bytes apart (each HOLDS a pointer into a separate
array) while the Value itself is 40 bytes, so `payloadWordOffset` and
`valSizeBytes` are two different strides and only the first one indexes a
payload.  The word arm's are `wordBytes` apart.

val arm: the payload word HOLDS A POINTER to a separate array, so the base is
`[[src + payloadWordOffset n]]`.

word arm: the slot holds ONE WORD — the TAGGED POINTER to the body — so the
base is `untag([src]) + payloadWordOffset n`, the SAME `vecbody` identity the
runtime states (`wordBodyOf` is the untag, and a word-arm body is INLINE, so
"the array" and "the first element" are the same address).

MEASURED, AND IT IS WHY THIS IS AN INDIRECTION AND NOT AN OFFSET: the first cut
read `src + off` directly and `1 :: 2 :: []` printed the whole list instead of
its head.  `src` is a FRAME SLOT address; `src + 8` is the NEXT FRAME SLOT, not
the object's payload — and the slot allocator happened to hand the pattern
matcher's own scratch slot that exact address, so the "car" read back a copy of
the scrutinee.  A frame slot and a heap object are different memories.

THE VAL ARM'S EMIT IS UNCHANGED BYTE FOR BYTE: `payloadWordOffset n` on the val
instance is exactly the byte offset each caller already spelled (`8` for fst,
`16` for snd), the base temp is allocated FIRST and the address temp second —
the order every call site already used — so the corpus stays identical.
-}
fieldBase : Int -> Int -> S -> ( Il.Arg, S )
fieldBase n src s =
    if wordArm s then
        let
            ( v, s1 ) =
                freshTmp s

            ( body, s2 ) =
                wordBodyOf (Il.Tmp v) (emit (Load (Just v) L LoadL (Il.Tmp (slotTmp src))) s1)

            ( baseT, s3 ) =
                freshTmp s2
        in
        ( Il.Tmp baseT
        , emit (Bin (Just baseT) L Add (Il.Tmp body) (Il.Con (RtLayout.payloadWordOffset s.layout n))) s3
        )

    else
        let
            ( baseT, s1 ) =
                freshTmp s

            ( p8, s2 ) =
                freshTmp s1
        in
        ( Il.Tmp baseT
        , emit (Bin (Just p8) L Add (Il.Tmp (slotTmp src)) (Il.Con (RtLayout.payloadWordOffset s.layout n))) s2
            |> emit (Load (Just baseT) L LoadL (Il.Tmp p8))
        )


-- fst/snd: blit PAYLOAD WORD `n` of the value in `src` into dst — `0` for the
-- car (`FstStep`), `1` for the cdr when the cons carries two interior pointers
-- (`SndStep` with `consArr`).  `n` is a WORD INDEX and not a byte offset, which
-- is `fieldBase`'s contract and the reason `8`/`16` — the offsets every
-- pre-unit caller spelled — are no longer accepted here: `8` would compile
-- clean and mean "payload word 8", which is past the end of a cons on both
-- arms.  THE NAME AND THE DOC CARRY THE UNIT because this wrapper is exactly
-- where the old meaning used to live: it forwarded a byte offset to a function
-- that had become index-parameterised, and a caller copying an old call site
-- would have compiled and silently mis-read on BOTH arms.
chaseField : Int -> Int -> Int -> S -> S
chaseField n src dst s =
    let
        ( base, s1 ) =
            fieldBase n src s
    in
    emit (Blit base (Il.Tmp (slotTmp dst)) s1.layout.valSizeBytes) s1


-- (A) the cdr of a cons: element 1 of the 2-element array `car` heads
-- (*(car + vs)).  The cons Value's cdr payload word is now NULL, so the cdr
-- VALUE is derived through the car pointer, exactly like the Zig readers.
-- Under the word arm the body is inline, so this is element 1 of the SAME base
-- (`fieldBase 0` + one element) — see `fieldBase`.
chaseCdr : Int -> Int -> S -> S
chaseCdr src dst s =
    let
        ( carBase, s1 ) =
            fieldBase 0 src s

        ( cdrT, s2 ) =
            freshTmp s1
    in
    emit (Bin (Just cdrT) L Add carBase (Il.Con s.layout.valSizeBytes)) s2
        |> emit (Blit (Il.Tmp cdrT) (Il.Tmp (slotTmp dst)) s.layout.valSizeBytes)


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
    readTag tagT (Il.Tmp (slotTmp src)) s5
        |> emit (Cmp (Just isnil) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagNil))
        |> closeBlock (Jnz (Il.Tmp isnil) nilLbl chaseLbl)
        |> startBlock nilLbl
        |> storeNil dst
        |> jumpTo doneLbl
        |> startBlock chaseLbl
        |> (if isHd then
                chaseField 0 src dst

            else if s.consArr then
                chaseCdr src dst

            else
                chaseField 1 src dst
           )
        |> jumpTo doneLbl
        |> startBlock doneLbl


storeNil : Int -> S -> S
storeNil dst s =
    if wordArm s then
        -- perf VR3b2 (area 2): nil is the `...010` IMMEDIATE and the slot IS
        -- one word, so there is no payload word to clear — one store.
        emit (Store StoreL (Il.Con s.layout.tagNil) (Il.Tmp (slotTmp dst))) s

    else
        let
            ( d8, s1 ) =
                freshTmp s
        in
        emit (Store StoreW (Il.Con s.layout.tagNil) (Il.Tmp (slotTmp dst))) s1
            |> emit (Bin (Just d8) L Add (Il.Tmp (slotTmp dst)) (Il.Con 8))
            |> emit (Store StoreL (Il.Con 0) (Il.Tmp d8))


-- The VM's jmpf test (interp.zig .jmpf): false iff the slot is a boolean with
-- payload 0; anything else falls through.  Closes the current block and starts
-- the true branch's block.
jmpfFalse : Int -> String -> String -> S -> S
jmpfFalse slot falseLbl trueLbl s =
    startBlock trueLbl (falsyJump slot falseLbl trueLbl s)


{-| The BLOCK-CLOSING half of `jmpfFalse`, on its own for the one caller that
must supply its own next block: `lowerLoop`'s condition test, whose true branch
is the loop body's label and is started by the body's own lowering (starting it
here as well would emit a DUPLICATE block label — invalid QBE).

Keeping the test in ONE function is what makes the loop condition arm-correct:
the val arm's `isBool && payload == 0` pair and the word arm's single
`tagFalse` compare are the same question, and before AREA 6 `lowerLoop` spelled
the val arm's pair INLINE — a word-arm loop would have read a tag WORD off a
one-word value and tested a payload word that does not exist.
-}
falsyJump : Int -> String -> String -> S -> S
falsyJump slot falseLbl trueLbl s =
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
    (if wordArm s then
        -- perf VR3b2 (area 2): `false` is the `...100` IMMEDIATE, so the test
        -- is the tag compare alone — the val arm's `isBool && payload == 0`
        -- pair collapses to one compare, and the branch sense is preserved:
        -- a FALSE value goes to falseLbl, everything else to trueLbl.
        readTag tagT (Il.Tmp (slotTmp slot)) s6
            |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagFalse))
            |> closeBlock (Jnz (Il.Tmp isbT) falseLbl trueLbl)

     else
        emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp slot))) s6
            |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con s.layout.tagBoolean))
            |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp slot)) (Il.Con 8))
            |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
            |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
            |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
            |> closeBlock (Jnz (Il.Tmp jfT) falseLbl trueLbl)
    )


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
                                    storeValueCell s.layout.tagNumber [ Il.Tmp (slotTmp cbase) ] argsPtrSlot sB

                                sD =
                                    storeValueCell s.layout.tagNumber [ Il.Con n ] nSlot sC
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
                                    |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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


{-| `tagis(value, tag)` as a BOXED BOOLEAN, for `If`/`falsyJump`.

THE `tag` ARGUMENT IS A VALTAG, AND THE CALLER MUST PASS THE MODULE CONSTANT
(perf word-arm-records R3).  `RawTagIs`'s `tag` is dispatched by `wordTagShape`,
which is keyed on VALTAGS — and on the word arm the `ValLayout` INSTANCE's
`tag*` fields are the WORD ENCODINGS, where every heap code collapses to
`heapPtrTag` (1).  Passing `layout.tagRecord` therefore asks "is this a STRING"
on the word arm: the same meaning drift that produced the poisoned record in R2.
The val arm's instance fields ARE the valtags, so passing the constants changes
nothing there — the val emit is byte-identical (the corpus is the proof).

The BOXED-BOOLEAN tag is a valtag too (`wordTagShape tagBoolean` answers the two
word immediates), so it is spelled as the constant for the same reason.
-}
boxTagIs : RtLayout.ValLayout -> Exp -> Int -> Exp
boxTagIs layout value tag =
    Unsafe (RawMkValue { tag = RtLayout.tagBoolean, words = [ Unsafe (RawTagIs { value = value, tag = tag }) ] })


-- The shared access body: tag 14 -> positional (Just rank) or recGet walk;
-- tag 4 -> assoc/snd chain; else (defensive) -> recGet walk.  `recB` is the
-- binder the record subexpression was bound to (evaluated ONCE).
recordAccessBody : RtLayout.ValLayout -> Binder -> Maybe Int -> String -> Exp
recordAccessBody layout recB rank field =
    let
        recV =
            Var recB.id

        -- THE ELEMENT BASE, NOT PAYLOAD WORD 0 (perf word-arm-area3rt).  This is
        -- the ONE seat where the compiler itself spelled the val arm's
        -- "vector -> separate array" idiom instead of the runtime's text, so the
        -- runtime-wide rewrite could not reach it: on the word arm payload word 0
        -- of a record is element 0, and using it as an array base reads the
        -- wrong object.  `RawVecBody` is the same emit on the val arm (that is
        -- what the node IS), so the val arm's .ssa does not move.
        positional =
            Unsafe (RawVecLoad { vec = Unsafe (RawVecBody { value = recV }), index = Lit (LNumber (Maybe.withDefault 0 rank)) })

        walk =
            PrimApp { prim = "recGet", args = [ recV, Lit (LSymbol field) ] }

        chain =
            PrimApp { prim = "snd", args = [ PrimApp { prim = "assoc", args = [ Lit (LSymbol field), recV ] } ] }
    in
    If
        { cond = boxTagIs layout recV RtLayout.tagRecord
        , thenBranch = Maybe.withDefault walk (Maybe.map (\_ -> positional) rank)
        , elseBranch =
            If
                { cond = boxTagIs layout recV RtLayout.tagCons
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
recordAccessExp : RtLayout.ValLayout -> Binder -> Exp -> Maybe Int -> String -> Exp
recordAccessExp layout recB rec rank field =
    Let { binders = [ LetBind { binder = recB, value = rec } ], body = recordAccessBody layout recB rank field }


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
                                --
                                -- THE WORD ARM ALLOCATES A DIFFERENT OBJECT (perf
                                -- word-arm-records R2): ONE code-14 block whose body
                                -- is `[data_0 .. data_{n-1} | namesBase]`, so the
                                -- seat is `Rt.allocRecord` — which adds the names
                                -- word to the count itself (`n + 1`), because that
                                -- `+ 1` is the layout and no call site may be able
                                -- to disagree with it.
                                ( dataArg, s2 ) =
                                    midGcAllocSeat
                                        (if wordArm s then "Rt.allocRecord" else "Rt.allocVector")
                                        (Il.Con n)
                                        s1

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
                                |> Result.andThen
                                    (\( namesArg, s4 ) ->
                                        if wordArm s then
                                            -- THE NAMES WORD, at body index `n`: a
                                            -- RAW store of the static names-array
                                            -- address (NOT a value store — the
                                            -- word is a pointer the collector
                                            -- skips, not a Value).  The address
                                            -- is `elemAddr`, i.e. the layout's own
                                            -- stride, never a hand-spelled `+8n`.
                                            let
                                                ( aT, s5 ) =
                                                    elemAddr dataArg (Il.Con n) s4

                                                s6 =
                                                    emit (Store StoreL namesArg (Il.Tmp aT)) s5
                                            in
                                            -- the slot holds the TAGGED BODY: the
                                            -- one-word heap arm of `storeWordCell`
                                            -- ("the caller has already allocated
                                            -- the body"), so the tag has ONE writer
                                            -- on this arm too.
                                            --
                                            -- THE CODE IS THE MODULE CONSTANT, NOT
                                            -- `s.layout.tagRecord`: on the word arm
                                            -- the instance's `tag*` fields are the
                                            -- WORD ENCODINGS (every heap code is
                                            -- `heapPtrTag` = 1), so the instance
                                            -- field would name the STRING code here.
                                            -- MEASURED: that exact slip took the
                                            -- string branch, refused, and the
                                            -- poison-on-error path in
                                            -- `storeValueCell` emitted `...111`.
                                            storeWordCell RtLayout.tagRecord [ dataArg ] dest s6

                                        else
                                            Ok (storeValueCell s.layout.tagRecord [ dataArg, Il.Con n, namesArg ] dest s4)
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
        lowerVal (recordAccessExp s0.layout recB rec rank field) dest s0

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
recordUpdateWalkExp : RtLayout.ValLayout -> Binder -> Exp -> List ( String, Exp ) -> Exp
recordUpdateWalkExp layout baseB base updates =
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
                { cond = boxTagIs layout baseV RtLayout.tagRecord
                , thenBranch = walk
                , elseBranch =
                    If
                        { cond = boxTagIs layout baseV RtLayout.tagCons
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
--
-- THE TAG TEST IS A SEAT, NOT A SITE (perf word-arm-records R4): `recordTagBranch`
-- below opens both of this function's tag-test blocks (record vs cons), so the
-- two cannot drift from each other or from a `case`'s `lowerTagMatch`.
recordTagBranch : Int -> String -> String -> Int -> S -> Result String S
recordTagBranch slot yesLbl noLbl tag s =
    if wordArm s then
        -- The valtag names a GC-header KIND here, and every heap object carries
        -- the SAME `...001` pointer tag, so `wordTagIs` (which `wordTagShape`
        -- dispatches) is the only correct reader — and it DIES by name on a
        -- header code 0, i.e. a val-arm block, rather than answering "not the
        -- code you asked for".
        wordTagIs (Il.Tmp (slotTmp slot)) tag s
            |> Result.map (\( flag, s1 ) -> closeBlock (Jnz flag yesLbl noLbl) s1)

    else
        let
            ( tagT, s1 ) =
                freshTmp s

            ( isT, s2 ) =
                freshTmp s1
        in
        Ok
            (s2
                |> emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp slot)))
                |> emit (Cmp (Just isT) W Ceq (Il.Tmp tagT) (Il.Con tag))
                |> closeBlock (Jnz (Il.Tmp isT) yesLbl noLbl)
            )


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
                    ( recLbl, s3 ) =
                        freshLbl "updrec" s2

                    ( notRecLbl, s4 ) =
                        freshLbl "updchain" s3

                    ( joinLbl, s5 ) =
                        freshLbl "updjoin" s4
                in
                recordTagBranch baseSlot recLbl notRecLbl RtLayout.tagRecord s5
                    |> Result.andThen
                        (\s6 ->
                            let
                                -- tag-14 arm: allocate, copy/store, wrap.  The
                                -- update values were pre-lowered into rooted
                                -- slots, so the data array allocates AFTER them
                                -- (same load-bearing order as lowerRecordLitPos).
                                --
                                -- THE SEAT IS THE ARM'S (perf word-arm-records
                                -- R4): the word arm builds the SAME one-block
                                -- record a literal build does, so it allocates
                                -- `Rt.allocRecord(n)` — whose `+ 1` IS the names
                                -- word, in the seat and in its name — and NOT
                                -- `Rt.allocVector(n)`, which is a word short and
                                -- would put the names store past the block.
                                ( ndArg, s7 ) =
                                    midGcAllocSeat
                                        (if wordArm s6 then
                                            "Rt.allocRecord"

                                         else
                                            "Rt.allocVector"
                                        )
                                        (Il.Con n)
                                        (startBlock recLbl s6)

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
                                            -- copy base's value for this field:
                                            -- read base.data[baseRankOf name]
                                            -- (the base's data array is in the
                                            -- BASE's canonical order, which
                                            -- differs from the RESULT's when
                                            -- `<-` inserted a field).
                                            case baseRankOf name of
                                                Nothing ->
                                                    Err ("qbe: record update field " ++ name ++ " is absent from a closed base row (corrupt Mid tree)")

                                                Just brank ->
                                                    if wordArm st then
                                                        -- THE WORD ARM HAS NO
                                                        -- PAYLOAD INDIRECTION
                                                        -- AND NO 40-BYTE STRIDE
                                                        -- (perf word-arm-records
                                                        -- R4).  The value word
                                                        -- IS the body, so the
                                                        -- field is
                                                        -- `elemAddr body brank`:
                                                        -- the layout's own
                                                        -- stride through the
                                                        -- SHARED accessors, no
                                                        -- hand-spelled `+ 8`
                                                        -- (which is the next
                                                        -- FRAME SLOT here) and
                                                        -- no `* valSizeBytes`.
                                                        let
                                                            ( dataArg, st1 ) =
                                                                fieldBase 0 baseSlot st

                                                            ( elemT, st2 ) =
                                                                elemAddr dataArg (Il.Con brank) st1
                                                        in
                                                        Ok
                                                            (emit
                                                                (Call Nothing (Base W) storeSym
                                                                    [ ArgVal (Base L) ndArg
                                                                    , ArgVal (Base W) (Il.Con rank)
                                                                    , ArgVal (Base L) (Il.Tmp elemT)
                                                                    ]
                                                                )
                                                                st2
                                                            )

                                                    else
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
                                                                |> emit (Bin (Just elemT) L Add (Il.Tmp dataT) (Il.Con (s.layout.valSizeBytes * brank)))
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
                                    -- The result's names array is content-keyed
                                    -- on the RESULT field set (base ++
                                    -- `<-`-inserted fields), NOT the base's — an
                                    -- insertion extends the row.
                                    rawWordArg (Unsafe (RawDataAddr resultNames)) st
                                        |> Result.andThen
                                            (\( namesArg, st1 ) ->
                                                if wordArm st1 then
                                                    -- THE ONE-BLOCK BUILD (perf
                                                    -- word-arm-records R4): the
                                                    -- names blob's address is a
                                                    -- RAW body word at index `n`
                                                    -- (a pointer the collector
                                                    -- skips, not a Value), and
                                                    -- the slot holds the TAGGED
                                                    -- BODY through the cell
                                                    -- writer's one-word arm —
                                                    -- the same two statements
                                                    -- lowerRecordLitPos makes.
                                                    let
                                                        ( aT, st2 ) =
                                                            elemAddr ndArg (Il.Con n) st1
                                                    in
                                                    storeWordCell RtLayout.tagRecord [ ndArg ] dest (emit (Store StoreL namesArg (Il.Tmp aT)) st2)
                                                        |> Result.map (jumpTo joinLbl)

                                                else
                                                    Ok
                                                        (storeValueCell s.layout.tagRecord [ ndArg, Il.Con n, namesArg ] dest st1
                                                            |> jumpTo joinLbl
                                                        )
                                            )
                            in
                            List.foldl
                                (\( rank, name ) acc -> Result.andThen (storeOne rank name) acc)
                                (Ok s7)
                                (List.indexedMap (\rank name -> ( rank, name )) resultNames)
                                |> Result.andThen wrap
                                |> Result.andThen
                                    (\sRec ->
                                        -- not-rec arm: tag 4 -> chain prepend;
                                        -- else -> recUpd walk.
                                        let
                                            ( chainLbl, s8 ) =
                                                freshLbl "updassoc" sRec

                                            ( walkLbl, s9 ) =
                                                freshLbl "updwalk" s8

                                            chain =
                                                buildRecordUpdate { base = baseV, updates = List.map (\( f, b ) -> ( f, Var b.id )) updPairs }

                                            walk =
                                                applyUpdates baseV (List.map (\( f, b ) -> ( f, Var b.id )) updPairs)
                                        in
                                        recordTagBranch baseSlot chainLbl walkLbl RtLayout.tagCons (startBlock notRecLbl s9)
                                            |> Result.andThen
                                                (\s10 ->
                                                    lowerVal chain dest (startBlock chainLbl s10)
                                                        |> Result.map (jumpTo joinLbl)
                                                        |> Result.andThen
                                                            (\s11 ->
                                                                lowerVal walk dest (startBlock walkLbl s11)
                                                                    |> Result.map (\s12 -> startBlock joinLbl (jumpTo joinLbl s12))
                                                            )
                                                )
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
                lowerVal (recordUpdateWalkExp s0.layout baseB update.base update.updates) dest s0

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
    -- THE INLINE FAST PATHS ARE A VAL-ARM SHAPE (perf word-arm-arith).
    --
    -- `lowerArith`/`lowerCompare`/`lowerNumEq` end in a GENERIC tail that emits
    -- the 40-byte Value directly — the tag word at `slot + 0`, the payload at
    -- `slot + 8` — and each is gated on an operand TYPE, never on the arm.  So
    -- under the word arm each of the three SKIPS that tail and calls the
    -- runtime through `rtPrimSlots` instead, which is the SAME ground the
    -- AGGREGATE prims are admitted on: `Rt.+`/`-`/`*`/`/`/`<`/`=` read their
    -- operands through the layout-derived accessors (`payload`, `payload32`,
    -- `mknum`, `tagis`), so they are arm-clean BY CONSTRUCTION rather than by a
    -- site sweep.
    --
    -- THE FORK LIVES INSIDE EACH OF THE THREE, NOT HERE, and that is
    -- deliberate: `lowerCompare`'s PROVEN-STRING branch must still be ENTERED
    -- under the word arm so it can REFUSE by name (its inline byte loop reads
    -- `slot + 8` and `slot + 16`; the numeric-only `Rt.<` answers False for
    -- every string, the silent Char-ordering mislower).  Gating the whole call
    -- here instead SKIPPED that branch, so the refusal was unreachable and the
    -- word arm printed `0` for `"a" < "b"` — MEASURED, in this unit's first
    -- cut.
    --
    -- THIS IS A CLASSIFICATION, NOT A NEW MECHANISM, and that is MEASURED:
    -- `2 ^ 3` and `7 // 2` already built, linked and ran correctly under
    -- `QBE_VALREP=word` before this unit, because `pow` and `/` have no inline
    -- arm at all and so already took this route.  What was missing was only the
    -- three forks.
    --
    -- `f/` KEEPS its inline branch and is NOT routed: it is float-only, and
    -- under the word arm it is refused by name (AREA 5, `wordArmPrimUnported`)
    -- with `isFloatExp` already denying, so the branch is unreachable there
    -- rather than silently taken.
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

    else if wordArm s then
        -- ============ THE WORD ARM TAKES THE RUNTIME ROUTE ============
        -- (perf word-arm-arith.)  The tail below emits the 40-byte shape — the
        -- tag word at `slot + 0` and the payload at `slot + 8` — and under this
        -- arm those are the value word and THE NEXT FRAME SLOT.  `Rt.+`/`-`/`*`
        -- instead read their operands with `payload` (a fixnum's `SAR`, a heap
        -- object's body load) and write the result with `mknum`, which is the
        -- i61 shift AND its round-trip check: `+ - *` WRAP at i64 (L3's
        -- semantics) for every result that fits, and a result outside i61
        -- REFUSES LOUDLY by name instead of silently dropping its top three
        -- bits — the boxed overflow path is AREA 4's and does not exist yet.
        lowerArgsToSlots args s
            |> Result.andThen (\( slots, s1 ) -> rtPrimSlots prim slots dest s1)

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
                        |> emit (Cmp (Just fa) W Ceq (Il.Tmp ta) (Il.Con s.layout.tagFloat))
                        |> emit (Cmp (Just fb) W Ceq (Il.Tmp tb) (Il.Con s.layout.tagFloat))
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
                        |> emit (Store StoreW (Il.Con s.layout.tagNumber) (Il.Tmp (slotTmp dest)))
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
        --
        -- NOT UNDER THE WORD ARM (perf word-arm-arith): `lowerStrLess` reads
        -- the byte pointer at `slot + 8` and the length at `slot + 16` of a
        -- 40-byte Value, i.e. THE NEXT TWO FRAME SLOTS when a slot is one
        -- word.  It cannot be routed to `Rt.<` either — that answers False for
        -- any non-number, which is exactly the silent mislower this branch
        -- exists to prevent — so it refuses BY NAME here, at the construct's
        -- own emit site.  A real port is two accessor calls
        -- (`payload(x, 0)` for the bytes, `payload32(x, 1)` for the length,
        -- both already twinned); it is left out because this unit's scope is
        -- the ARITHMETIC prim class and a fork here would need its own
        -- behavioural fixture to be worth anything.
        if wordArm s then
            Err
                (wordArmUnsupported
                    (wordArea
                        "AREA 3 (PAYLOAD ACCESS)"
                        "Char/String ordering — its inline byte-lexicographic loop reads a Value's byte pointer at `slot + 8` and its length at `slot + 16`, i.e. the 40-byte shape, which under the word arm are the NEXT TWO FRAME SLOTS; and the numeric-only `Rt.<` answers False for any non-number, so routing it there would be the silent Char-ordering mislower the inline branch exists to prevent"
                    )
                )

        else
            lowerArgs2 args s
                |> Result.andThen (\( a1, a2, s1 ) -> lowerStrCmp op a1 a2 dest s1)

    else if wordArm s then
        -- ============ THE WORD ARM TAKES THE RUNTIME ROUTE ============
        -- (perf word-arm-arith.)  The tail below emits the 40-byte shape — the
        -- tag word at `slot + 0`, the payload at `slot + 8` — and under this
        -- arm those are the value word and THE NEXT FRAME SLOT.  `Rt.<`/`<=`/
        -- `>`/`>=` read their operands with `payload`/`tagis` and answer through
        -- `mkbool`, so the i64 compare and the Boolean are both the layout's.
        -- The PROVEN-FLOAT and PROVEN-STRING branches above are the ones this
        -- fork deliberately still lets run: the float one is dead (`isFloatExp`
        -- denies here) and the string one REFUSES by name.
        lowerArgsToSlots args s
            |> Result.andThen (\( slots, s1 ) -> rtPrimSlots (cmpName op) slots dest s1)

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
                        |> emit (Cmp (Just na) W Ceq (Il.Tmp ta) (Il.Con s.layout.tagNumber))
                        |> emit (Cmp (Just fa) W Ceq (Il.Tmp ta) (Il.Con s.layout.tagFloat))
                        |> emit (Bin (Just numa) W Or (Il.Tmp na) (Il.Tmp fa))
                        |> emit (Cmp (Just nb) W Ceq (Il.Tmp tb) (Il.Con s.layout.tagNumber))
                        |> emit (Cmp (Just fb) W Ceq (Il.Tmp tb) (Il.Con s.layout.tagFloat))
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
                        |> emit (Store StoreW (Il.Con s.layout.tagBoolean) (Il.Tmp (slotTmp dest)))
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

    else if wordArm s then
        -- ============ THE WORD ARM TAKES THE RUNTIME ROUTE ============
        -- (perf word-arm-arith.)  The tail below emits the 40-byte shape — the
        -- tag word at `slot + 0`, the payload at `slot + 8` — and under this arm
        -- those are the value word and THE NEXT FRAME SLOT.  `Rt.=` is the
        -- PORTED deep-equality: every arm of it reads through `tagis`/
        -- `payload`/`veclen`/`len32`, and its record arm is the word-spliced
        -- `Rt.recEqGo` (perf word-arm-records R2), so this fork is what makes
        -- `==` on records EXECUTE instead of merely compile.
        lowerArgsToSlots args s
            |> Result.andThen (\( slots, s1 ) -> rtPrimSlots "=" slots dest s1)

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
                        |> emit (Cmp (Just na) W Ceq (Il.Tmp ta) (Il.Con s.layout.tagNumber))
                        |> emit (Cmp (Just nb) W Ceq (Il.Tmp tb) (Il.Con s.layout.tagNumber))
                        |> emit (Bin (Just ok) W And (Il.Tmp na) (Il.Tmp nb))
                        |> closeBlock (Jnz (Il.Tmp ok) iLbl fLbl)
                        |> startBlock iLbl
                        |> emit (Bin (Just pa) L Add (Il.Tmp (slotTmp a1)) (Il.Con 8))
                        |> emit (Load (Just xa) L LoadL (Il.Tmp pa))
                        |> emit (Bin (Just pb) L Add (Il.Tmp (slotTmp a2)) (Il.Con 8))
                        |> emit (Load (Just xb) L LoadL (Il.Tmp pb))
                        |> emit (Cmp (Just c) L Ceq (Il.Tmp xa) (Il.Tmp xb))
                        |> emit (Store StoreW (Il.Con s.layout.tagBoolean) (Il.Tmp (slotTmp dest)))
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
                            |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
                        )

                else
                    Err ("qbe: prim " ++ prim ++ " stages arity " ++ String.fromInt (List.length slots) ++ " — the lean ABI passes 1.." ++ String.fromInt maxDirectArity ++ " pointer args (A's direct_arity bound)")

            else
                let
                    ( rp, s1 ) =
                        freshTmp s
                in
                -- U3a: same flip as the RawCall arm above — a generic-ABI
                -- callee returns the finished `:val`.
                Ok
                    (emit (Call (Just rp) (Agg "val") (Il.Sym ("q_" ++ mangle key)) (List.map (\sl -> ArgVal (Base L) (Il.Tmp (slotTmp sl))) slots)) s1
                        |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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
                |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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
                if List.length lambda.params > s.layout.maxArity then
                    Err ("qbe: closure has arity > " ++ String.fromInt s.layout.maxArity ++ " (rt_callN table limit)")

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
                                                        storeValueCell s.layout.tagNumber [ Il.Sym descName ] descSlot sC

                                                    sE =
                                                        storeValueCell s.layout.tagNumber
                                                            [ if k == 0 then
                                                                Il.Con 0

                                                              else
                                                                Il.Tmp (slotTmp cbase)
                                                            ]
                                                            capBaseSlot
                                                            sD

                                                    sF =
                                                        storeValueCell s.layout.tagNumber [ Il.Con k ] kSlot sE
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
                                                    |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) s.layout.valSizeBytes)
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
                                                Ok (emit (Blit src (Il.Tmp (slotTmp (cbase + i))) s.layout.valSizeBytes) s1)

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
            List.map (withPrologue s.layout) pendings
                ++ (globBlockFunc :: rtCallFuncs s.layout)
                -- stage 6 P1d Step B: the two-range apply bridge.  B4 closed
                -- the hatch (the Mid route is the only route), so it is
                -- unconditional.
                ++ [ rtCallTwoRange s.layout ]

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
    { layout = s.layout
    , types = []
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
withPrologue : RtLayout.ValLayout -> PendingFunc -> Func
withPrologue layout pending =
    let
        f =
            pending.func

        slotDefs =
            List.map
                (\i ->
                    Bin (Just (slotTmp i)) L Add (Il.Tmp "f") (Il.Con (layout.valSizeBytes * i))
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
            -- ABI copies the incoming `%a<i>` into its frame slot.
            --
            -- AREA 6: WHAT `%a<i>` IS DEPENDS ON THE ARM.  On the value arm it
            -- is a POINTER to the caller's 40-byte slot, so the copy is a
            -- `blit`.  On the word arm a value parameter IS ONE WORD (`:val` is
            -- 8 bytes, VR1's word-arm convention), so the copy is a plain
            -- 8-byte `storel` of the register — a `blit` there would dereference
            -- the VALUE WORD as an address (the word arm's silent-wrong shape).
            -- `paramWords` is set for exactly the RtGeneric class on the word
            -- arm (see lowerFunBody).
            if pending.rawAbi then
                structParamCopies

            else if pending.ptrRead then
                []

            else if pending.paramWords then
                List.map
                    (\i -> Store StoreL (Il.Tmp ("a" ++ String.fromInt i)) (Il.Tmp (slotTmp (i + resultSlotBase layout))))
                    (List.range 0 (pending.nparams - 1))

            else
                List.map
                    (\i -> Blit (Il.Tmp ("a" ++ String.fromInt i)) (Il.Tmp (slotTmp (i + resultSlotBase layout))) layout.valSizeBytes)
                    (List.range 0 (pending.nparams - 1))

        capBlitsPro =
            List.concatMap
                (\j ->
                    [ Bin (Just ("e" ++ String.fromInt j)) L Add (Il.Tmp "env") (Il.Con (layout.valSizeBytes * j))
                    , Blit (Il.Tmp ("e" ++ String.fromInt j)) (Il.Tmp (slotTmp (pending.nparams + resultSlotBase layout + j))) layout.valSizeBytes
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
                    Alloc "f" (layout.valSizeBytes * pending.nslots)

                PLeaf ->
                    Alloc "f" (layout.valSizeBytes * pending.nslots)

        -- P5 / H3 — THE RESULT AREA'S ZERO.  A frame-free defun has no
        -- enter-side memset, so whatever the RETURN path reads without a tag
        -- test of its own has to be MATERIALIZED here.  U3b cut that set down
        -- to ONE read on the value arm: the `.done` result at slot 0, which is
        -- read as the number 0 (tag 0) if nothing writes it.
        --
        -- SLOT 1 IS GONE, ON BOTH ARMS.  It used to carry the `.done`/
        -- `.tail` discriminator of the 80-byte `:ret` return shape, and the
        -- store here existed because a 64-bit reader compared that word
        -- against zero (MEASURED: with a 4-byte `storew` the four padding
        -- bytes at 44..47 stayed uninitialised, the compare saw non-zero, the
        -- `.done` path was missed, and the pre-U3a `Rt.bounce` chased a
        -- `.tail` built out of stack garbage — a wild jump into the heap,
        -- ASan: `PC is at a non-executable region`, with only that one defun
        -- changed).  U3b deleted the slot, the reader and the store on the
        -- value arm; AREA 6 deleted the word arm's `:ret` and its kind word
        -- with it (`closureRetClass`), so ONE store is the whole of this.
        --
        -- Every OTHER slot is read tag-directed, which is the SAME argument
        -- the lean frame-free arm (PAlloc) has always rested on: the block is
        -- never registered as a root and a blit is a raw copy, so an unzeroed
        -- word past a cell's last written one is never interpreted.
        leafTailZero =
            case pending.pro of
                PLeaf ->
                    [ Store StoreL (Il.Con 0) (Il.Tmp (slotTmp 0)) ]

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
rtCallFuncs : RtLayout.ValLayout -> List Func
rtCallFuncs layout =
    List.map
        (\n ->
            let
                argNames =
                    List.map (\i -> "a" ++ String.fromInt i) (List.range 0 (n - 1))

                params =
                    ( "fn", Base L ) :: ( "e", Base L ) :: List.map (\a -> ( a, Base L )) argNames

                -- PERF VR3b2 — THE `:val` PARAMETER ABI IS NOT SIZE-INVARIANT.
                -- MEASURED on the vendored qbe: a `:val` parameter arrives BY
                -- VALUE ON THE STACK when the aggregate is 40 bytes and IN A
                -- REGISTER when it is 8 (amd64/sysv.c passes <=16 B aligned
                -- aggregates in registers).  A `:val` CALL ARGUMENT built from
                -- an `l` operand is the 40-byte case only because qbe puts the
                -- aggregate in memory and reads the `l` as its address; at 8
                -- bytes it passes the `l` ITSELF as the word — i.e. the
                -- POINTER instead of the value it points at.  So under the
                -- word arm each pointer is dereferenced first and the loaded
                -- word is what crosses.  The callee side needs no change: its
                -- prologue `blit %a<i>, %s<slot>, 8` copies the aggregate
                -- either way.
                loadArgs =
                    if wordArmLayout layout then
                        List.map (\a -> Load (Just ("v" ++ a)) L LoadL (Il.Tmp a)) argNames

                    else
                        []

                callArgs =
                    if wordArmLayout layout then
                        ArgEnv (Il.Tmp "e") :: List.map (\a -> ArgVal (Base L) (Il.Tmp ("v" ++ a))) argNames

                    else
                        ArgEnv (Il.Tmp "e") :: List.map (\a -> ArgVal (Base L) (Il.Tmp a)) argNames
            in
            { name = "rt_call" ++ String.fromInt n
            , export_ = True
            -- U3a: the closure ABI returns the finished 40-byte Value, so
            -- this bridge FORWARDS it — `:val` in, `:val` out, one blit — and
            -- there is nothing left to bounce.  It deliberately does NOT
            -- become a `tcall`: its only growing-stack consumer was
            -- Rt.bounceGo (deleted with the trampoline), and every remaining
            -- caller READS the returned value.
            , ret = Agg "val"
            , envParam = False
            , params = params
            , blocks =
                [ { label = "start"
                  , body =
                        loadArgs
                            ++ [ Call (Just "r") (Agg "val") (Il.Tmp "fn") callArgs ]
                  , jump = Ret (Just (Il.Tmp "r"))
                  }
                ]
            }
        )
        (List.range 0 layout.maxArity)


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
rtCallTwoRange : RtLayout.ValLayout -> Func
rtCallTwoRange layout =
    let
        -- (i < napp) ? caps + i*40 : args + (i-napp)*40, branchless:
        --   p = (args - napp*40) + (i<napp)*(caps + napp*40 - args) + i*40
        paramPtr : Int -> List Inst
        paramPtr i =
            [ Cmp (Just ("ci" ++ String.fromInt i)) L Cslt (Il.Con i) (Il.Tmp "napp")
            , Unary (Just ("cl" ++ String.fromInt i)) L Extuw (Il.Tmp ("ci" ++ String.fromInt i))
            , Bin (Just ("sel" ++ String.fromInt i)) L Mul (Il.Tmp ("cl" ++ String.fromInt i)) (Il.Tmp "diff")
            , Bin (Just ("pa" ++ String.fromInt i)) L Add (Il.Tmp "base") (Il.Tmp ("sel" ++ String.fromInt i))
            , Bin (Just ("p" ++ String.fromInt i)) L Add (Il.Tmp ("pa" ++ String.fromInt i)) (Il.Con (i * layout.valSizeBytes))
            ]

        arityBlock : Int -> Block
        arityBlock n =
            let
                callArgs =
                    ArgEnv (Il.Tmp "e")
                        :: List.map
                            (\i ->
                                ArgVal (Base L)
                                    (Il.Tmp
                                        (if wordArmLayout layout then
                                            "pv" ++ String.fromInt i

                                         else
                                            "p" ++ String.fromInt i
                                        )
                                    )
                            )
                            (List.range 0 (n - 1))

                -- U3a — THE TCALL, and its budget.  The callee is the closure's
                -- code pointer and it now returns the finished `:val` (the
                -- closure ABI flipped), so this hop can JUMP: `rt_call2r`'s
                -- frame is reused by the callee instead of stacking under it.
                -- The budget is the same one `maxTailCallArgs` states for the
                -- DSL — rdi is spent on the hidden sret pointer and rax on the
                -- closure env, leaving four integer registers for params plus
                -- the sret/env pair.  Arity 5+ keeps the ordinary call: the
                -- callee then returns THROUGH this frame to this frame's
                -- caller — a CONSTANT +1 per such hop, not growth (this func
                -- was itself tcall'd into, so its frame is the loop's slot).
                --
                -- NOT under the word arm: there `:val` is 8 bytes, i.e. an
                -- aggregate the amd64 ABI passes in a register, and the tcall's
                -- class/`aggsize` rules would have to be re-measured.  AREA 6
                -- owns that; the word arm keeps the ordinary call and its wall.
                canTail =
                    not (wordArmLayout layout) && n <= maxTailCallArgs
            in
            { label = "arity" ++ String.fromInt n
            , body =
                List.concatMap paramPtr (List.range 0 (n - 1))
                    ++ (if wordArmLayout layout then
                            List.map (\i -> Load (Just ("pv" ++ String.fromInt i)) L LoadL (Il.Tmp ("p" ++ String.fromInt i))) (List.range 0 (n - 1))

                        else
                            []
                       )
                    ++ [ if canTail then
                            TailCall (Agg "val") (Il.Tmp "code") callArgs

                         else
                            Call (Just "r") (Agg "val") (Il.Tmp "code") callArgs
                       ]
            , jump =
                if canTail then
                    Ret Nothing

                else
                    Ret (Just (Il.Tmp "r"))
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
                    (if k < layout.maxArity - 1 then
                        "c" ++ String.fromInt (k + 1)

                     else
                        "arity" ++ String.fromInt layout.maxArity
                    )
            }

        start =
            { label = "start"
            , body =
                [ Bin (Just "napp40") L Mul (Il.Tmp "napp") (Il.Con layout.valSizeBytes)
                , Bin (Just "e") L Add (Il.Tmp "caps") (Il.Tmp "napp40")
                , Bin (Just "diff") L Sub (Il.Tmp "e") (Il.Tmp "args")
                , Bin (Just "base") L Sub (Il.Tmp "args") (Il.Tmp "napp40")
                , Bin (Just "arity") L Add (Il.Tmp "napp") (Il.Tmp "nargs")
                , Cmp (Just "d0") L Ceq (Il.Tmp "arity") (Il.Con 0)
                ]
            , jump =
                Jnz (Il.Tmp "d0") "arity0" (if layout.maxArity > 0 then "c1" else "arity0")
            }
    in
    { name = "rt_call2r"
    , export_ = True
    -- U3a: `:val` out — the callee returns the finished Value.
    , ret = Agg "val"
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
            :: (List.map dispatchBlock (List.range 1 (layout.maxArity - 1))
                    ++ List.map arityBlock (List.range 0 layout.maxArity)
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
