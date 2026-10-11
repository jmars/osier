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
import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), Lambda, LetBinder(..), Lit(..), Match(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), Step(..), UnsafeNode(..), ValuePath(..))
import Mid.Rt as MidRt
import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (Module, Func, Block, Inst(..), Jump(..), Ty(..), AbiTy(..), BinOp(..), CmpOp(..), UnaryOp(..), LoadOp(..), StoreTy(..), CallArg(..), TypeDef, DataDef, DataItem(..))
import Set exposing (Set)
import Mid.Qbe.Types as QbeTypes
import Type.Representation as Rep
import Char.Extra exposing (utf8ByteLength)


-- sizeof(vm Value) = 40 (gc/types.zig), the `:val` aggregate.
vs : Int
vs =
    40


-- sizeof(:ret) = 80 (Il.retType): `{ :val, w, l, l, l, w }` = two pooled-frame
-- slots — slot 0 the finished value, slot 1 the .tail discriminator + payload.
rvs : Int
rvs =
    80


-- VM ValTag numbers this lowering switches on (gc/types.zig ValTag order).
tagNumber : Int
tagNumber =
    0


tagBoolean : Int
tagBoolean =
    3


tagFloat : Int
tagFloat =
    12


tagSymbol : Int
tagSymbol =
    2


tagCons : Int
tagCons =
    4


tagNil : Int
tagNil =
    5


tagVector : Int
tagVector =
    10


maxArity : Int
maxArity =
    16



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
    , funcs : List PendingFunc -- extra (closure) funcs, REVERSED
    , datas : List DataDef -- REVERSED
    , dataKeys : Dict String String -- content key -> data name (dedup)
    , dataN : Int
    , cloN : Int -- closure-name supply
    , arities : Dict String Int
    , defuns : Dict String Defun
    , defunKey : String
    , qname : String
    }


{-| A generated function plus the prologue facts only known completely after
the body walk (frame size), plus driver facts (static arity, captures).
-}
type alias PendingFunc =
    { func : Func
    , nslots : Int
    , nparams : Int
    , ncaps : Int
    , entryKey : Maybe String -- Just key for top-level defuns (meta table)
    }


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


lower : Bool -> Bool -> Bool -> QbeTypes.Table -> Dict String Int -> List Defun -> String -> Result String Il.Module
lower rep primDirect midCons table arityTable program entryKey =
    let
        defuns =
            Dict.fromList (List.map (\d -> ( d.key, d )) program)

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
            , funcs = []
            , datas = []
            , dataKeys = Dict.empty
            , dataN = 0
            , cloN = 0
            , arities = arityTable
            , defuns = defuns
            , defunKey = ""
            , qname = ""
            }
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
                                    Set.union acc (calledPrims defun.value)

                                Nothing ->
                                    acc
                        )
                        Set.empty
                        surfaceKeys

                rtKeys =
                    if List.any (\d -> isRtKey d.key) program then
                        List.filter (\k -> not (List.member k surfaceKeys)) (MidRt.seeds usedPrims)

                    else
                        []

                keys =
                    surfaceKeys ++ rtKeys
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
                                        lowerDefun defun s
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
                    (grefsOf defun.value)


grefsOf : Exp -> List String
grefsOf exp =
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
            grefsOf lambda.body

        NoTail inner ->
            grefsOf inner

        App app ->
            grefsOf app.fn ++ List.concatMap grefsOf app.args

        PrimApp app ->
            List.concatMap grefsOf app.args

        Let block ->
            List.concatMap grefsOf (letValues block.binders)
                ++ grefsOf block.body

        Case branch ->
            grefsOf branch.scrutinee
                ++ List.concatMap (\a -> grefsOf a.body) branch.alts

        Con con ->
            List.concatMap grefsOf con.args

        Tup es ->
            List.concatMap grefsOf es

        RecordLit setters ->
            List.concatMap (\p -> grefsOf (Tuple.second p)) setters

        RecordGet rec _ ->
            grefsOf rec

        RecordUpdate update ->
            grefsOf update.base
                ++ List.concatMap (\p -> grefsOf (Tuple.second p)) update.updates

        ListLit es ->
            List.concatMap grefsOf es

        If block ->
            grefsOf block.cond ++ grefsOf block.thenBranch ++ grefsOf block.elseBranch

        ShortAnd block ->
            grefsOf block.left ++ grefsOf block.right

        ShortOr block ->
            grefsOf block.left ++ grefsOf block.right

        NotEqual block ->
            grefsOf block.left ++ grefsOf block.right

        -- Unsafe (osier-rawnodes / osier-consspike): [] stays DELIBERATE.  A
        -- raw node cannot GRef anything — RawCall crosses the call graph as
        -- an opaque SYMBOL — so Rt->Rt references are invisible here BY
        -- DESIGN and Mid.Rt.seeds declares each prim's Rt-key closure
        -- instead (the used-prim seeding in `lower` is the only way an Rt
        -- defun becomes reachable; this arm returning [] is why it has to).
        Unsafe _ ->
            []


-- The reserved runtime namespace (Mid.Audit tests the same prefix; a surface
-- module named Rt is rejected at collect time by Mid.QbeModule).
isRtKey : String -> Bool
isRtKey key =
    String.startsWith "Rt." key


{-| The prim names a defun's lowering will CALL — the used-prim census the Rt
seeding reads.  This MIRRORS this module's own desugars (buildList /
buildRecord / buildRecordUpdate), because the Mid tree carries a `ListLit`
where the emitted code carries a `cons` chain: a census over `PrimApp` alone
would undercount and leave the pruning claim true for the wrong reason, while
a desugar this lowering does not perform would seed Rt defuns a program never
runs.  Every new prim ported to Mid (step 5) extends BOTH sides: its entry in
Mid.Rt.impls and, if a new CONSTRUCT desugars to it, the arm here.  Matches
and paths are deliberately absent: they call `=`/`hd`/`tl`-shape prims, never
a constructor prim.
-}
calledPrims : Exp -> Set.Set String
calledPrims exp =
    case exp of
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
            Set.insert "value" (calledPrims (Lit (LString varName)))

        Lam lambda ->
            calledPrims lambda.body

        NoTail inner ->
            calledPrims inner

        App app ->
            List.foldl (\e acc -> Set.union acc (calledPrims e)) (calledPrims app.fn) app.args

        PrimApp app ->
            List.foldl (\e acc -> Set.union acc (calledPrims e)) (Set.singleton app.prim) app.args

        Let block ->
            List.foldl
                (\e acc -> Set.union acc (calledPrims e))
                (calledPrims block.body)
                (letValues block.binders)

        Case branch ->
            List.foldl
                (\a acc -> Set.union acc (calledPrims a.body))
                (calledPrims branch.scrutinee)
                branch.alts

        Con con ->
            List.foldl (\e acc -> Set.union acc (calledPrims e)) Set.empty con.args

        Tup es ->
            -- (a, b) lowers to the `@p` prim (lowerTup).
            Set.insert "@p" (List.foldl (\e acc -> Set.union acc (calledPrims e)) Set.empty es)

        RecordLit setters ->
            -- {f = e} = cons (@p (sym f) e) ... (buildRecord).
            Set.insert "cons" <|
                Set.insert "@p" <|
                    List.foldl (\p acc -> Set.union acc (calledPrims (Tuple.second p))) Set.empty setters

        RecordGet rec _ ->
            calledPrims rec

        RecordUpdate update ->
            -- {r | f = e} prepends cons @p pairs (buildRecordUpdate).
            Set.insert "cons" <|
                Set.insert "@p" <|
                    List.foldl (\p acc -> Set.union acc (calledPrims (Tuple.second p))) (calledPrims update.base) update.updates

        ListLit es ->
            -- [a, b] = cons a (cons b (emptylist)) (buildList).
            Set.insert "cons" <|
                Set.insert "emptylist" <|
                    List.foldl (\e acc -> Set.union acc (calledPrims e)) Set.empty es

        If block ->
            List.foldl (\e acc -> Set.union acc (calledPrims e))
                Set.empty
                [ block.cond, block.thenBranch, block.elseBranch ]

        ShortAnd block ->
            Set.union (calledPrims block.left) (calledPrims block.right)

        ShortOr block ->
            Set.union (calledPrims block.left) (calledPrims block.right)

        NotEqual block ->
            Set.union (calledPrims block.left) (calledPrims block.right)

        Unsafe _ ->
            Set.empty


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


lowerDefun : Defun -> S -> Result String S
lowerDefun defun sOuter =
    case defun.value of
        Lam lambda ->
            let
                qname =
                    "q_" ++ mangle defun.key
            in
            if List.length lambda.params > maxArity then
                Err ("qbe: defun " ++ defun.key ++ " has arity > " ++ String.fromInt maxArity ++ " (rt_callN table limit)")

            else
                lowerFunBody True defun.key qname lambda [] sOuter
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


lowerFunBody : Bool -> String -> String -> Lambda -> List Int -> S -> Result String ( PendingFunc, S )
lowerFunBody entry key qname lambda captures sOuter =
    let
        nparams =
            List.length lambda.params

        ncaps =
            List.length captures

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
            , slot = 2 + nparams + ncaps
            , binderSlots =
                Dict.fromList
                    (List.indexedMap (\i p -> ( p.id, i + 2 )) lambda.params
                        ++ List.indexedMap (\j cid -> ( cid, nparams + 2 + j )) captures
                    )
            , rawInt = Dict.empty
            , rawFloat = Dict.empty
            , rawWord = Dict.empty
            , intBinders = intParams
            , table = sOuter.table
            , rep = sOuter.rep
            , primDirect = sOuter.primDirect
            , midCons = sOuter.midCons
            , funcs = []
            , datas = sOuter.datas
            , dataKeys = sOuter.dataKeys
            , dataN = sOuter.dataN
            , cloN = sOuter.cloN + 1
            , arities = sOuter.arities
            , defuns = sOuter.defuns
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
            , qname = qname
            }

        -- the (empty) @start block, closed by its fallthrough to @body
        sStart =
            closeBlock (Jmp "body") s0
    in
    startBlock "body" sStart
        |> lowerTail lambda.body
        |> Result.map
            (\s1 ->
                let
                    -- every tail path ended in a closed block (jmp @ret/@body)
                    sRet =
                        startBlock "ret" s1
                            |> emit (Call Nothing (Base W) (Il.Sym "rt_frame_leave") [])
                            |> closeBlock (Ret (Just (Il.Tmp (slotTmp 0))))

                    pending =
                        { func =
                            { name = qname
                            , export_ = False
                            , ret = Agg "ret"
                            , envParam = ncaps > 0
                            , params = List.map (\i -> ( "a" ++ String.fromInt i, Agg "val" )) (List.range 0 (nparams - 1))
                            , blocks = List.reverse sRet.blocks
                            }
                        , nslots = s1.slot
                        , nparams = nparams
                        , ncaps = ncaps
                        , entryKey =
                            if entry then
                                Just key

                            else
                                Nothing
                        }
                in
                ( pending, sRet )
            )



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

        _ ->
            lowerVal exp 0 s
                |> Result.map (jumpTo "ret")


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
            lowerVal (buildRecord setters) dest s

        RecordGet rec field ->
            lowerVal (buildRecordGet rec field) dest s

        RecordUpdate update ->
            lowerVal (buildRecordUpdate update) dest s

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

        -- Unsafe (osier-rawnodes / osier-consspike): the Rt-program
        -- lowering — legal only under Rt.* keys (Mid.Audit enforces that on
        -- every compile), and only VALUE producers reach here (RawMkValue,
        -- RawVecLoad, WithRoots; word producers are a loud error: they bind
        -- to raw temps in `let` positions, never to value destinations).
        Unsafe node ->
            lowerRawVal node dest s


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
                    case Dict.get id s.binderSlots of
                        Just srcSlot ->
                            Ok (emit (Blit (Il.Tmp (slotTmp srcSlot)) (Il.Tmp (slotTmp dest)) vs) s)

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
            -- Store the VALUE at vec[i] THROUGH the runtime's one barrier
            -- seat (tools/qbe/rt.zig rt_vec_store -> heap.zig
            -- writeBarrierVectorStore: store, then remember iff an old-gen
            -- array holds a nursery reference).  The stored value is lowered
            -- into a fresh ROOTED slot first — its address is the argument.
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
                                                -- The `w` index argument: an `l` value in a `w`
                                                -- context is legal QBE (il.txt Subtyping — the 32
                                                -- low bits are used), and indices are small
                                                -- non-negative words by contract.
                                                emit
                                                    (Call Nothing (Base W) (Il.Sym "rt_vec_store")
                                                        [ ArgVal (Base L) vecT
                                                        , ArgVal (Base W) idxT
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

        RawCall call ->
            -- STEP 5 (osier-midprims): Rt->Rt calls, the recursive helpers'
            -- voice (deepEqual, numberText, the list walks).  Lowered for
            -- `Rt.*` keys ONLY: args are VALUES lowered into fresh rooted
            -- slots, then the exact shape the route hatch emits — call the
            -- q_-mangled defun (:val args, :ret result), rt_bounce, move to
            -- dest.  A non-Rt symbol errs loudly: word-level C seats are
            -- RawCallRaw's, and the Value-level host seam is effectloop's.
            if String.startsWith "Rt." call.sym then
                if Dict.member call.sym s.defuns then
                    lowerArgsToSlots call.args s
                        |> Result.map
                            (\( slots, s1 ) ->
                                let
                                    ( rp, s2 ) =
                                        freshTmp s1

                                    ( vp, s3 ) =
                                        freshTmp s2
                                in
                                s3
                                    |> emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle call.sym)) (List.map (\sl -> ArgVal (Agg "val") (Il.Tmp (slotTmp sl))) slots))
                                    |> emit (Call (Just vp) (Agg "val") (Il.Sym "rt_bounce") [ ArgVal (Base L) (Il.Tmp rp) ])
                                    |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                            )

                else
                    Err ("qbe: rawCall to Rt defun " ++ call.sym ++ " — not in this compile (Mid.Rt.seeds must close the defun's Rt-key closure)")

            else
                Err ("qbe: rawCall to non-Rt symbol " ++ call.sym ++ " — Rt.* defun calls only (word-level C seats are rawCallRaw)")

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

        RawCallRaw _ ->
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
                                |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (8 + 8 * i)))
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
                                            |> emit (Bin (Just pT) L Add (Il.Tmp (slotTmp dest)) (Il.Con (8 + 8 * i)))
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
                    Err ("qbe: binder id " ++ String.fromInt id ++ " is not a raw word — value binders cannot appear in raw-argument positions")

        Unsafe (RawAllocVector len) ->
            rawWordArg len s
                |> Result.map
                    (\( lenA, s1 ) ->
                        let
                            ( t, s2 ) =
                                freshTmp s1
                        in
                        ( Il.Tmp t
                        , emit (Call (Just t) (Base L) (Il.Sym "rt_vec_alloc") [ ArgVal (Base W) lenA ]) s2
                        )
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
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal v vslot s1
                |> Result.map
                    (\s2 ->
                        let
                            ( t, s3 ) =
                                freshTmp s2
                        in
                        ( Il.Tmp t, emit (Load (Just t) W LoadW (Il.Tmp (slotTmp vslot))) s3 )
                    )

        Unsafe (RawPayload p) ->
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal p.value vslot s1
                |> Result.map
                (\s2 ->
                    let
                        ( aT, s3 ) =
                            freshTmp s2

                        ( t, s4 ) =
                            freshTmp s3
                    in
                    ( Il.Tmp t
                    , emit (Bin (Just aT) L Add (Il.Tmp (slotTmp vslot)) (Il.Con (8 + 8 * p.word))) s4
                        |> emit (Load (Just t) L LoadL (Il.Tmp aT))
                    )
                )

        -- ===== STEP 5 (osier-midprims): the scalar + string word producers
        Unsafe (RawPayload32 p) ->
            -- the i32 FIELDS (str.len, vector.len, boolean): loadsw at the
            -- word's low half + extsw to the l word class.  A 64-bit read
            -- here would compare garbage high halves against Zig-built
            -- Values (the extern-struct store never writes them).
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal p.value vslot s1
                |> Result.map
                (\s2 ->
                    let
                        ( aT, s3 ) =
                            freshTmp s2

                        ( wT, s4 ) =
                            freshTmp s3

                        ( t, s5 ) =
                            freshTmp s4
                    in
                    ( Il.Tmp t
                    , emit (Bin (Just aT) L Add (Il.Tmp (slotTmp vslot)) (Il.Con (8 + 8 * p.word))) s5
                        |> emit (Load (Just wT) W LoadW (Il.Tmp aT))
                        |> emit (Unary (Just t) L Extsw (Il.Tmp wT))
                    )
                )

        Unsafe (RawTagIs ti) ->
            -- tag == n as 0/1 (w), extended to the l word class — box it with
            -- RawMkValue tag 3 to branch (`If` reads a boolean Value).
            let
                ( vslot, s1 ) =
                    freshSlot s
            in
            lowerVal ti.value vslot s1
                |> Result.map
                (\s2 ->
                    let
                        ( tagT, s3 ) =
                            freshTmp s2

                        ( isT, s4 ) =
                            freshTmp s3

                        ( t, s5 ) =
                            freshTmp s4
                    in
                    ( Il.Tmp t
                    , emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp vslot))) s5
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
                                -- f64 word -> i32: stosi at `w` (truncate
                                -- toward zero), THEN extsw into the l class
                                -- (the ToInt32 result re-enters word math
                                -- sign-extended).
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
                        let
                            ( t, s2 ) =
                                freshTmp s1
                        in
                        ( Il.Tmp t
                        , emit (Call (Just t) (Base L) (Il.Sym "rt_raw_alloc") [ ArgVal (Base W) lenA ]) s2
                        )
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
                |> Result.map
                    (\( args, s1 ) ->
                        let
                            ( t, s2 ) =
                                freshTmp s1
                        in
                        ( Il.Tmp t, emit (Call (Just t) (Base L) (Il.Sym seat.sym) args) s2 )
                    )

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

        RawCallRaw seat ->
            "rawCallRaw " ++ seat.sym


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

                ( rp, s2 ) =
                    freshTmp s1
            in
            Ok
                (emit (Call (Just rp) (Agg "val") (Il.Sym "rt_string") [ ArgVal (Base L) (Il.Sym strname), ArgVal (Base W) (Il.Con (utf8ByteLength str)) ]) s2
                    |> emit (Blit (Il.Tmp rp) (Il.Tmp d) vs)
                )


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

        NoTail inner ->
            isIntKnown s inner

        PrimApp app ->
            List.member app.prim [ "+", "-", "*" ]
                && List.length app.args == 2
                && List.all (isIntKnown s) app.args

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
                    case Dict.get id s.binderSlots of
                        Just slot ->
                            let
                                ( p, s1 ) =
                                    freshTmp s

                                ( t, s2 ) =
                                    freshTmp s1
                            in
                            Ok
                                ( Il.Tmp t
                                , emit (Bin (Just p) L Add (Il.Tmp (slotTmp slot)) (Il.Con 8)) s2
                                    |> emit (Load (Just t) L LoadL (Il.Tmp p))
                                )

                        Nothing ->
                            Err ("qbe: raw Int operand not in scope: binder " ++ String.fromInt id ++ " (corrupt Mid tree)")

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
            (emit (Call (Just rp) (Agg "val") (Il.Sym "rt_global_closure") [ ArgVal (Base L) (Il.Sym (globalDescName ref.key)) ]) s1
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
    -- Stage EVERY arg into a fresh rooted slot BEFORE blitting any of them
    -- into the param slots: the VM's appterm evaluates all args before
    -- rebinding, and an arg that reads a param (directly or nested) must see
    -- the OLD value, not one already overwritten by an earlier arg's blit.
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
    stageArgs args s
        |> Result.andThen
            (\( ptrs, base, s1 ) ->
                if isTail then
                    let
                        ( rp, s2 ) =
                            freshTmp s1
                    in
                    Ok
                        (emit
                            (Call (Just rp)
                                (Agg "ret")
                                (Il.Sym "rt_tail_known")
                                [ ArgVal (Base L) (Il.Sym ("q_" ++ mangle key))
                                , ArgVal (Base L) (Il.Tmp (slotTmp base))
                                , ArgVal (Base W) (Il.Con (List.length args))
                                ]
                            )
                            s2
                            |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp 0)) rvs)
                            |> jumpTo "ret"
                        )

                else
                    let
                        ( rp, s2 ) =
                            freshTmp s1

                        ( vp, s3 ) =
                            freshTmp s2
                    in
                    Ok
                        (emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle key)) (List.map (\p -> ArgVal (Agg "val") (Il.Tmp p)) ptrs)) s3
                            |> emit (Call (Just vp) (Agg "val") (Il.Sym "rt_bounce") [ ArgVal (Base L) (Il.Tmp rp) ])
                            |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                        )
            )


-- Generic application through the runtime (first-class closures, partials,
-- over-application).  NON-TAIL: rt_apply bounces internally and returns a
-- .done value.  TAIL: rt_apply_tail returns the :ret (.tail or .done), blitted
-- into the return area.
rtApply : String -> List Exp -> Int -> Bool -> S -> Result String S
rtApply fslotTmp args dest isTail s =
    stageArgs args s
        |> Result.andThen
            (\( _, baseSlot, s1 ) ->
                if isTail then
                    let
                        ( rp, s2 ) =
                            freshTmp s1
                    in
                    Ok
                        (emit
                            (Call (Just rp)
                                (Agg "ret")
                                (Il.Sym "rt_apply_tail")
                                [ ArgVal (Base L) (Il.Tmp fslotTmp)
                                , ArgVal (Base L) (Il.Tmp (slotTmp baseSlot))
                                , ArgVal (Base W) (Il.Con (List.length args))
                                ]
                            )
                            s2
                            |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp 0)) rvs)
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
                                (Agg "val")
                                (Il.Sym "rt_apply")
                                [ ArgVal (Base L) (Il.Tmp fslotTmp)
                                , ArgVal (Base L) (Il.Tmp (slotTmp baseSlot))
                                , ArgVal (Base W) (Il.Con (List.length args))
                                ]
                            )
                            s2
                            |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
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

            else if isRawWordExp bind.value then
                -- Rt raw nodes (osier-consspike): a WORD-producing node binds
                -- to a raw temp, not a frame slot — a slot IS a 40-byte Value
                -- the collector scans, and a bare address in one is a garbage
                -- tag away from a crash.  The S4 rawInt shape, one register
                -- class over; reads go through rawWordArg, and lowerVal's Var
                -- arm rejects the value-position read.
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
isRawWordExp : Exp -> Bool
isRawWordExp exp =
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

                RawStrByte _ ->
                    True

                RawCallRaw _ ->
                    True

                _ ->
                    False

        _ ->
            False


-- Compute a word-producing raw node into a fresh `l` temp — the binder-side
-- entry into rawWordArg's node cases (isRawWordExp has already gated the
-- call, so the value-binder error paths there are unreachable here).
rawWordOf : Exp -> S -> Result String ( Il.Arg, S )
rawWordOf exp s =
    rawWordArg exp s



-- ============================ IF ============================
-- The VM's jmpf semantics EXACTLY (interp.zig .jmpf): false branch iff the
-- cond is a boolean with payload 0; anything else falls through.


lowerIf : { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String } -> Int -> Bool -> S -> Result String S
lowerIf block dest isTail s =
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
                emit (Load (Just tagT) W LoadW (Il.Tmp (slotTmp cslot))) s10
                    |> emit (Cmp (Just isbT) W Ceq (Il.Tmp tagT) (Il.Con tagBoolean))
                    |> emit (Bin (Just p8T) L Add (Il.Tmp (slotTmp cslot)) (Il.Con 8))
                    |> emit (Load (Just pldT) W LoadW (Il.Tmp p8T))
                    |> emit (Cmp (Just iszT) W Ceq (Il.Tmp pldT) (Il.Con 0))
                    |> emit (Bin (Just jfT) W And (Il.Tmp isbT) (Il.Tmp iszT))
                    |> closeBlock (Jnz (Il.Tmp jfT) elseLbl thenLbl)
                    |> startBlock thenLbl
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
            )



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
        ( scrutSlot, s1 ) =
            freshSlot s
    in
    lowerVal branch.scrutinee scrutSlot s1
        |> Result.andThen
            (\s2 ->
                lowerAlts branch.alts scrutSlot dest isTail
                    { s2 | binderSlots = Dict.insert branch.scrutId.id scrutSlot s2.binderSlots }
            )


lowerAlts : List Alt -> Int -> Int -> Bool -> S -> Result String S
lowerAlts alts scrutSlot dest isTail s =
    let
        ( errLbl, sE ) =
            freshLbl "cerr" s

        ( endLbl, sEnd ) =
            freshLbl "cend" sE
    in
    lowerAltsLoop alts errLbl endLbl scrutSlot dest isTail sEnd
        |> Result.andThen
            (\sA ->
                Ok (startBlock errLbl sA
                        |> lowerNonExhaustive "non-exhaustive case"
                        |> startBlock endLbl
                   )
            )


-- Emit alts in order: each alt's tests jump to the NEXT alt's entry on
-- failure (the last alt's to the error label).  A passing alt binds, runs its
-- body, and (non-tail) joins endLbl.
lowerAltsLoop : List Alt -> String -> String -> Int -> Int -> Bool -> S -> Result String S
lowerAltsLoop alts errLbl endLbl scrutSlot dest isTail s =
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
            lowerMatchTests alt.matches scrutSlot restFailLbl s1
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
                                lowerAltsLoop rest errLbl endLbl scrutSlot dest isTail (startBlock restFailLbl s3)
                    )


-- A destructuring let is the same machinery as a single always-matching alt:
-- value -> scrutinee slot, ordered tests (any failure -> simple-error), then
-- the pattern bindings in a block that FALLS THROUGH to the continuation.
lowerLetDestruct : { scrutId : Binder, value : Exp, matches : List Match, binds : List ( Binder, ValuePath ), badLabel : String, okLabel : String } -> S -> Result String S
lowerLetDestruct destruct s =
    let
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
                lowerMatchTests destruct.matches scrutSlot errLbl s5
                    |> Result.andThen
                        (\s6 ->
                            Ok (jumpTo okLbl s6
                                    |> startBlock errLbl
                                    |> lowerNonExhaustive "non-exhaustive let pattern"
                                    |> startBlock okLbl
                               )
                        )
                    |> Result.andThen (lowerBinds destruct.binds scrutSlot)
            )


-- Run each test in order; a failing test jumps to failLbl.  Falls through iff
-- ALL pass (the ZINC emitter's `matchInstrs ++ Jmpf nextLabel` per test).
lowerMatchTests : List Match -> Int -> String -> S -> Result String S
lowerMatchTests matches scrutSlot failLbl s =
    List.foldl
        (\m acc -> Result.andThen (lowerMatch m scrutSlot failLbl) acc)
        (Ok s)
        matches


lowerMatch : Match -> Int -> String -> S -> Result String S
lowerMatch match scrutSlot failLbl s =
    case match of
        MCons steps ->
            Ok (lowerTagMatch steps scrutSlot tagCons failLbl s)

        MEmpty steps ->
            Ok (lowerTagMatch steps scrutSlot tagNil failLbl s)

        MVector steps ->
            Ok (lowerTagMatch steps scrutSlot tagVector failLbl s)

        MTagEq steps tag ->
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
            -- A record field pattern reads the record via its steps, then looks
            -- the field up the VM's way: snd (assoc (sym field) rec) — exactly
            -- Mid.ToZinc's VField (pathInstrs: readPath ++ [Symbol field, assoc,
            -- snd]) and this slice's own RecordGet lowering (buildRecordGet), so
            -- parity is by construction.  The record lands in a ROOTED slot
            -- before the two rt_prim calls, so an allocation inside assoc/snd
            -- can never see an unrooted record (the stage-3 aggchurn discipline).
            let
                ( p, s1 ) =
                    freshSlot s

                sRead =
                    readSteps steps scrutSlot p s1

                ( l, s2 ) =
                    freshSlot sRead
            in
            lowerLit (LSymbol field) l s2
                |> Result.andThen
                    (\s3 ->
                        let
                            ( r, s4 ) =
                                freshSlot s3
                        in
                        rtPrimSlots "assoc" [ l, p ] r s4
                            |> Result.andThen (\s5 -> rtPrimSlots "snd" [ r ] dest s5)
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


-- fst/snd: blit the car/cdr body (at `off` in the cons Value) into dst.
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
        |> chaseField (if isHd then 8 else 16) src dst
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
lowerNonExhaustive : String -> S -> S
lowerNonExhaustive msg s =
    let
        ( msgName, s1 ) =
            freshData ("msg:" ++ msg)
                (\n -> { name = n, align = Just 8, items = [ DStr msg, DByte 0 ], export_ = False })
                s
    in
    emit (Call Nothing (Base W) (Il.Sym "rt_die") [ ArgVal (Base L) (Il.Sym msgName) ]) s1
        |> closeBlock Hlt


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

                                -- rt_con reads `args` as a CONTIGUOUS [*]Value
                                -- array, so stage the (rooted, but not
                                -- necessarily adjacent) arg slots into one
                                -- contiguous frame block immediately before the
                                -- call — pure copies, no safepoint between.
                                ( _, cbase, s4 ) =
                                    stageSlots slots s3

                                ( rp, s5 ) =
                                    freshTmp s4
                            in
                            Ok
                                (emit
                                    (Call (Just rp)
                                        (Agg "val")
                                        (Il.Sym "rt_con")
                                        [ ArgVal (Base L) (Il.Tmp (slotTmp tagSlot))
                                        , ArgVal (Base L)
                                            (if n == 0 then
                                                Il.Con 0

                                             else
                                                Il.Tmp (slotTmp cbase)
                                            )
                                        , ArgVal (Base W) (Il.Con n)
                                        ]
                                    )
                                    s5
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
    -- THE MID ROUTE (osier-consspike, QBE_MIDCONS=1): when the prim has a
    -- Mid implementation AND its Rt defun was injected, the staged slots call
    -- the Rt DEFUN through the ordinary saturated-call ABI instead of the Zig
    -- entry — the same shape directCall emits (call -> :ret -> rt_bounce ->
    -- dest).  The args are already in ROOTED frame slots, which is exactly
    -- what the callee's :val-pointer params expect.  Step 6 (the flip) makes
    -- this the DEFAULT and re-shapes it to A's lean ABI; today it is the
    -- differential's vehicle, OFF by default so the committed goldens and
    -- corpus move only by the INJECTED defun, with output provably unchanged
    -- (the fuzz differential + the midcons gate rows carry the behavioural
    -- proof).
    case ( s.midCons, midPrimRoute prim slots s ) of
        ( True, Just key ) ->
            let
                ( rp, s1 ) =
                    freshTmp s

                ( vp, s2 ) =
                    freshTmp s1
            in
            Ok
                (emit (Call (Just rp) (Agg "ret") (Il.Sym ("q_" ++ mangle key)) (List.map (\sl -> ArgVal (Agg "val") (Il.Tmp (slotTmp sl))) slots)) s2
                    |> emit (Call (Just vp) (Agg "val") (Il.Sym "rt_bounce") [ ArgVal (Base L) (Il.Tmp rp) ])
                    |> emit (Blit (Il.Tmp vp) (Il.Tmp (slotTmp dest)) vs)
                )

        _ ->
            rtPrimSlotsZig prim slots dest s


-- The Rt defun key to route `prim` through, if the hatch is worth taking:
-- the prim must HAVE a Mid implementation, the STAGED ARITY must be that
-- implementation's (read from Mid.Rt.impls, not hardcoded — step 5's
-- hand-off: a literal arity silently mis-handles every non-binary prim,
-- e.g. empty? 1, substring 3, absvector 1), and that defun must be present
-- in this compile (injected — QBE_NOMIDRT=1 removes it and the route quietly
-- falls back to the Zig entry rather than emitting a call to an absent
-- function).
midPrimRoute : String -> List Int -> S -> Maybe String
midPrimRoute prim slots s =
    case MidRt.primImpl prim of
        Just impl ->
            if List.length slots == impl.arity && Dict.member impl.key s.defuns then
                Just impl.key

            else
                Nothing

        Nothing ->
            Nothing


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
                                , items = [ DRef qname, DWord (List.length lambda.params), DWord k, DZero 8 ]
                                , export_ = False
                                }
                            )
                            s1
                in
                if List.length lambda.params > maxArity then
                    Err ("qbe: closure has arity > " ++ String.fromInt maxArity ++ " (rt_callN table limit)")

                else
                    lowerFunBody False s1.defunKey qname lambda captures s2
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
                                                (emit
                                                    (Call (Just rp)
                                                        (Agg "val")
                                                        (Il.Sym "rt_make_closure")
                                                        [ ArgVal (Base L) (Il.Sym descName)
                                                        , ArgVal (Base L)
                                                            (if k == 0 then
                                                                Il.Con 0

                                                             else
                                                                Il.Tmp (slotTmp cbase)
                                                            )
                                                        , ArgVal (Base W) (Il.Con k)
                                                        ]
                                                    )
                                                    s4
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
                                        case Dict.get cid s1.binderSlots of
                                            Just srcSlot ->
                                                Ok (emit (Blit (Il.Tmp (slotTmp srcSlot)) (Il.Tmp (slotTmp (cbase + i))) vs) s1)

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
                ++ rtCallFuncs

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
                                        , align = Just 8
                                        , items =
                                            [ DRef ("q_" ++ mangle key)
                                            , DWord (List.length lambda.params)
                                            , DWord 0
                                            , DZero 8
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
    , datas = List.reverse s.datas ++ globalDescs ++ metaDatas
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

        paramBlits =
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

        enter =
            Call (Just "f") (Base L) (Il.Sym "rt_frame_enter") [ ArgVal (Base W) (Il.Con pending.nslots) ]

        prologue =
            case f.blocks of
                b0 :: rest ->
                    { b0 | body = enter :: slotDefs ++ paramBlits ++ capBlitsPro ++ b0.body } :: rest

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
                    ArgEnv (Il.Tmp "e") :: List.map (\a -> ArgVal (Agg "val") (Il.Tmp a)) argNames
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
                    , DZero 4
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
