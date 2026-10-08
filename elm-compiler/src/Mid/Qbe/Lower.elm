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
--   excluded (Err): Case, LetDestruct, Con, Tup, RecordLit/Get/Update,
--     ListLit, StreamRef, ShortAnd/ShortOr/NotEqual, non-ASCII literals —
--     pattern matching, records/tuples/lists and the effect loop are later
--     stages.  Any REACHED defun that needs one of these fails the compile.
--
-- ============================== THE CONTRACTS ==============================
--
-- CALLING CONVENTION (ABI-verified against the vendored qbe; see
-- docs/qbe-backend.md): a Value is the 40-byte aggregate `:val`; QBE passes
-- :val params as POINTERS and returns them through sret, exactly like a C
-- struct by value.  A function of arity N with K captures compiles to
--
--     function :val $q_<mangled> [(env %env),] :val %a0 .. :val %a{N-1}
--
-- (`env` only when K > 0 — QBE passes it in a register invisible to C; the
-- generated rt_callN dispatchers pass env to env-less top-level defuns too,
-- which just ignore it).  %a_i POINTS at the caller's staging copy; the
-- prologue blits each param into the frame before anything else can run.
--
-- GC ROOTING (crux 2): every local lives in a RUNTIME-POOLED frame block
-- from `rt_frame_enter(nslots) -> *Value`, registered as ONE
-- ROOT_VALUE_ARRAY for the whole body, popped by rt_frame_leave().  The
-- frame ADDRESS is an opaque call result, so QBE cannot promote a slot's
-- store/load pair into a callee-saved register (MEASURED on the vendored
-- qbe: a non-escaping stack slot's store+reload ARE deleted across a call;
-- the pooled-frame loop shape keeps them — evidence in the handoff node and
-- docs/qbe-backend.md).  Slot 0 = result, 1..N params, N+1..N+K captures,
-- then expression temporaries.  A per-function GLOBAL frame would also
-- defeat promotion but CANNOT nest under recursion (a callee would zero its
-- caller's frame) — hence the pool.
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
--   * every other tail position (cross-defun call, rt_apply, thunk force of
--     another global) is a PLAIN CALL and therefore GROWS THE NATIVE STACK.
--     Honest slice answer — measured in docs/qbe-backend.md; the AOT's
--     bounce loop (tools/aot/runtime.zig Ret/.tail) is the known next stage.
--
-- NO SSA: temporaries are assigned freely; QBE builds SSA itself.

-- (Exp's Con variant is deliberately NOT exposed: Mid.Qbe.Il.Arg also has a
-- Il.Con (the integer-constant argument), and Elm cannot qualify constructors
-- in patterns — exposing only one of the two keeps the pattern arms clean.)
import Mid.Ir exposing (Defun, Exp(..), Lambda, LetBinder(..), Lit(..))
import Dict exposing (Dict)
import Mid.Qbe.Il as Il exposing (Module, Func, Block, Inst(..), Jump(..), Ty(..), AbiTy(..), BinOp(..), CmpOp(..), LoadOp(..), StoreTy(..), CallArg(..), TypeDef, DataDef, DataItem(..))
import Set exposing (Set)


-- sizeof(vm Value) = 40 (gc/types.zig), the `:val` aggregate.
vs : Int
vs =
    40


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


maxArity : Int
maxArity =
    8



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
        | blocks = Block s.curLabel (List.reverse s.curBody) jump :: s.blocks
        , curBody = []
    }


startBlock : String -> S -> S
startBlock label s =
    { s | curLabel = label, curBody = [] }


jumpTo : String -> S -> S
jumpTo label s =
    closeBlock (Jmp label) s


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


lower : Dict String Int -> List Defun -> String -> Result String Il.Module
lower arityTable program entryKey =
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

        Ok keys ->
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

        Con con ->
            List.concatMap grefsOf con.args

        Tup es ->
            List.concatMap grefsOf es

        RecordLit setters ->
            List.concatMap (grefsOf << Tuple.second) setters

        RecordGet rec _ ->
            grefsOf rec

        RecordUpdate update ->
            grefsOf update.base
                ++ List.concatMap (grefsOf << Tuple.second) update.updates

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
                                | funcs = pending :: sOuter.funcs
                                , datas = sInner.datas
                                , dataKeys = sInner.dataKeys
                                , dataN = sInner.dataN
                                , cloN = sInner.cloN
                            }
                        )

        _ ->
            Err ("qbe: defun " ++ defun.key ++ " has a non-Lambda value (corrupt Mid tree)")



-- ============================ FUNCTION BODY ============================
-- Frame layout: slot 0 result, 1..N params, N+1..N+K captures, then temps.
-- Blocks: @start (prologue; jump @body), @body (loop head for self-tail),
-- ... interior ..., @ret (rt_frame_leave; ret %s0).


lowerFunBody : Bool -> String -> String -> Lambda -> List Int -> S -> Result String ( PendingFunc, S )
lowerFunBody entry key qname lambda captures sOuter =
    let
        nparams =
            List.length lambda.params

        ncaps =
            List.length captures

        s0 =
            { blocks = []
            , curLabel = "start"
            , curBody = []
            , tmp = 0
            , lbl = 0
            , slot = 1 + nparams + ncaps
            , binderSlots =
                Dict.fromList
                    (List.indexedMap (\i p -> ( p.id, i + 1 )) lambda.params
                        ++ List.indexedMap (\j cid -> ( cid, nparams + 1 + j )) captures
                    )
            , funcs = []
            , datas = sOuter.datas
            , dataKeys = sOuter.dataKeys
            , dataN = sOuter.dataN
            , cloN = sOuter.cloN + 1
            , arities = sOuter.arities
            , defuns = sOuter.defuns
            , defunKey = key
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
                            Func qname
                                False
                                (Agg "val")
                                (ncaps > 0)
                                (List.map (\i -> ( "a" ++ String.fromInt i, Agg "val" )) (List.range 0 (nparams - 1)))
                                (List.reverse sRet.blocks)
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

        Lam lambda ->
            lowerClosure lambda 0 s

        _ ->
            lowerVal exp 0 s
                |> Result.map (jumpTo "ret")


lowerVal : Exp -> Int -> S -> Result String S
lowerVal exp dest s =
    case exp of
        Lit lit ->
            lowerLit lit dest s

        Var id ->
            case Dict.get id s.binderSlots of
                Just srcSlot ->
                    Ok (emit (Blit (Il.Tmp (slotTmp srcSlot)) (Il.Tmp (slotTmp dest)) vs) s)

                Nothing ->
                    Err ("qbe: unbound binder id " ++ String.fromInt id ++ " (corrupt Mid tree)")

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

        Case _ ->
            Err "qbe: Case (pattern matching) is not lowered by the native slice yet"

        Con _ ->
            Err "qbe: Il.Con (ADT construction) is not lowered by the native slice yet"

        Tup _ ->
            Err "qbe: Tup is not lowered by the native slice yet"

        RecordLit _ ->
            Err "qbe: RecordLit is not lowered by the native slice yet"

        RecordGet _ _ ->
            Err "qbe: RecordGet is not lowered by the native slice yet"

        RecordUpdate _ ->
            Err "qbe: RecordUpdate is not lowered by the native slice yet"

        ListLit _ ->
            Err "qbe: ListLit is not lowered by the native slice yet"

        StreamRef _ ->
            Err "qbe: StreamRef (effect loop) is not lowered by the native slice yet"

        ShortAnd _ ->
            Err "qbe: ShortAnd is not lowered by the native slice yet"

        ShortOr _ ->
            Err "qbe: ShortOr is not lowered by the native slice yet"

        NotEqual _ ->
            Err "qbe: NotEqual is not lowered by the native slice yet"



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
                ( d8, s1 ) =
                    afterTag (storeTag tagFloat)

                ( fname, s2 ) =
                    freshData ("flt:" ++ String.fromFloat f)
                        (\n -> { name = n, align = Just 8, items = [ DDouble f ] })
                        s1
            in
            Ok (emit (Load (Just d8) D LoadD (Il.Sym fname)) s2)

        LSymbol name ->
            if not (isAscii name) then
                Err "qbe: non-ASCII symbol literal is not supported by the native slice"

            else
                let
                    ( d8, s1 ) =
                        afterTag (storeTag tagSymbol)

                    ( sname, s2 ) =
                        freshData ("sym:" ++ name)
                            (\n -> { name = n, align = Just 8, items = [ DStr name, DByte 0 ] })
                            s1
                in
                Ok (emit (Store StoreL (Il.Sym sname) (Il.Tmp d8)) s2)

        LString str ->
            if not (isAscii str) then
                Err "qbe: non-ASCII string literal is not supported by the native slice"

            else
                let
                    ( strname, s1 ) =
                        freshData ("str:" ++ str)
                            (\n -> { name = n, align = Just 8, items = [ DStr str, DByte 0 ] })
                            s

                    ( rp, s2 ) =
                        freshTmp s1
                in
                Ok
                    (emit (Call (Just rp) (Agg "val") (Il.Sym "rt_string") [ ArgVal (Base L) (Il.Sym strname), ArgVal (Base W) (Il.Con (String.length str)) ]) s2
                        |> emit (Blit (Il.Tmp rp) (Il.Tmp d) vs)
                    )


isAscii : String -> Bool
isAscii str =
    String.all (\c -> Char.toCode c < 127) str



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
                -- 0-arg thunk head: force it, then apply any spine args to
                -- the result through the generic path.
                directCall ref.key [] dest False s
                    |> Result.andThen
                        (\s1 ->
                            if List.isEmpty args then
                                Ok
                                    (if isTail then
                                        jumpTo "ret" s1

                                     else
                                        s1
                                    )

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
    List.foldl
        (\( arg, i ) acc ->
            acc
                |> Result.andThen
                    (\s1 ->
                        let
                            ( tslot, s2 ) =
                                freshSlot s1
                        in
                        lowerVal arg tslot s2
                            |> Result.map
                                (\s3 ->
                                    emit (Blit (Il.Tmp (slotTmp tslot)) (Il.Tmp (slotTmp (i + 1))) vs) s3
                                )
                    )
        )
        (Ok s)
        (List.indexedMap (\i a -> ( a, i )) args)
        |> Result.map (jumpTo "body")



-- Lower every arg into a ROOTED frame slot first (an arg's own lowering can
-- contain calls — safepoints — and only slots survive those), THEN emit the
-- stack staging as pure copies immediately before the call.  Between the
-- staging blits and the callee's prologue copies into its own rooted frame
-- there is no safepoint, so the unrooted stack copies are safe; staging
-- EARLIER would leave stale interior pointers under the moving GC.


stageArgs : List Exp -> S -> Result String ( List String, String, S )
stageArgs args s =
    lowerArgsToSlots args s
        |> Result.andThen (\( slots, s1 ) -> Ok (stageSlots slots s1))


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


-- Pure staging: alloc + one blit per slot, in PARAMETER order (arg 1 first —
-- the callee's %a0).  The base is a valid block even for 0 args (never read).
stageSlots : List Int -> S -> ( List String, String, S )
stageSlots slots s =
    let
        n =
            List.length slots

        ( asTmp, s1 ) =
            freshTmp s
    in
    ( List.map (\i -> asTmp ++ "_" ++ String.fromInt i) (List.range 0 (n - 1))
    , asTmp
    , List.foldl
        (\( slot, i ) acc ->
            let
                ptmp =
                    asTmp ++ "_" ++ String.fromInt i
            in
            acc
                |> emit (Bin (Just ptmp) L Add (Il.Tmp asTmp) (Il.Con (vs * i)))
                |> emit (Blit (Il.Tmp (slotTmp slot)) (Il.Tmp ptmp) vs)
        )
        (emit (Alloc asTmp (Basics.max vs (vs * n))) s1)
        (List.indexedMap (\i slot -> ( slot, i )) slots)
    )


finishCallResult : String -> Int -> Bool -> S -> S
finishCallResult rp dest isTail =
    emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
        >> (if isTail then
                jumpTo "ret"

            else
                identity
           )


-- Direct saturated call to a known defun.  The returned :val points into the
-- CALLEE's (already-left) frame block — blitted into our rooted slot before
-- anything else can run, which is the only safe window (the block is
-- unread-but-stable until the next rt_frame_enter).
directCall : String -> List Exp -> Int -> Bool -> S -> Result String S
directCall key args dest isTail s =
    stageArgs args s
        |> Result.andThen
            (\( ptrs, _, s1 ) ->
                let
                    ( rp, s2 ) =
                        freshTmp s1
                in
                Ok
                    (emit (Call (Just rp) (Agg "val") (Il.Sym ("q_" ++ mangle key)) (List.map (\p -> ArgVal (Agg "val") (Il.Tmp p)) ptrs)) s2
                        |> finishCallResult rp dest isTail
                    )
            )


-- Generic application through the runtime (first-class closures, partials,
-- over-application): rt_apply(fslot, argsBlock, nargs).
rtApply : String -> List Exp -> Int -> Bool -> S -> Result String S
rtApply fslotTmp args dest isTail s =
    stageArgs args s
        |> Result.andThen
            (\( _, base, s1 ) ->
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
                            , ArgVal (Base L) (Il.Tmp base)
                            , ArgVal (Base W) (Il.Con (List.length args))
                            ]
                        )
                        s2
                        |> finishCallResult rp dest isTail
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
            let
                ( bslot, s1 ) =
                    freshSlot s
            in
            lowerVal bind.value bslot s1
                |> Result.map (\s2 -> { s2 | binderSlots = Dict.insert bind.binder.id bslot s2.binderSlots })

        LetDestruct _ ->
            Err "qbe: LetDestruct (pattern-matching let) is not lowered by the native slice yet"



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
                                    |> Result.map (startBlock joinLbl)
                        )
            )



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

                    arithOp =
                        case prim of
                            "+" ->
                                Add

                            "-" ->
                                Sub

                            _ ->
                                Mul
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
                        |> emit (Bin (Just r) L arithOp (Il.Tmp xa) (Il.Tmp xb))
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
                        |> emit (Cmp (Just c) W Ceq (Il.Tmp xa) (Il.Tmp xb))
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
rtPrimSlots : String -> List Int -> Int -> S -> Result String S
rtPrimSlots prim slots dest s =
    let
        ( pnm, s0 ) =
            freshData ("pnm:" ++ prim)
                (\n -> { name = n, align = Just 8, items = [ DStr prim, DByte 0 ] })
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
                , ArgVal (Base L) (Il.Tmp base)
                , ArgVal (Base W) (Il.Con (List.length slots))
                ]
            )
            s2
            |> emit (Blit (Il.Tmp rp) (Il.Tmp (slotTmp dest)) vs)
        )


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
                                                    |> (\s5 -> { s5 | funcs = pending :: s5.funcs })
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
                        case Dict.get cid s.binderSlots of
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
                                        d.scrutId.id :: List.map (Tuple.first >> .id) d.binds
                            )
                            block.binders
                        )

                inner =
                    Result.map2 Set.union
                        (setsUnion (List.map fvExp (letValues block.binders)))
                        (fvExp block.body)
            in
            Result.map (Set.diff binderIds) inner

        If block ->
            setsUnion (List.map fvExp [ block.cond, block.thenBranch, block.elseBranch ])

        ShortAnd block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        ShortOr block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        NotEqual block ->
            setsUnion (List.map fvExp [ block.left, block.right ])

        Case _ ->
            Err "qbe: Case inside a closure body is not lowered by the native slice yet"

        Con con ->
            setsUnion (List.map fvExp con.args)

        Tup es ->
            setsUnion (List.map fvExp es)

        RecordLit setters ->
            setsUnion (List.map (fvExp << Tuple.second) setters)

        RecordGet rec _ ->
            fvExp rec

        RecordUpdate update ->
            setsUnion (List.map fvExp (update.base :: List.map Tuple.second update.updates))

        ListLit es ->
            setsUnion (List.map fvExp es)


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
                                        }

                                _ ->
                                    Nothing

                        Nothing ->
                            Nothing
                )
                keys

        ( metaDatas, metaFuncs ) =
            metaTable pendings
    in
    { types = []
    , datas = List.reverse s.datas ++ globalDescs ++ metaDatas
    , funcs = funcs ++ metaFuncs
    }


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
                (\i -> Blit (Il.Tmp ("a" ++ String.fromInt i)) (Il.Tmp (slotTmp (i + 1))) vs)
                (List.range 0 (pending.nparams - 1))

        capBlitsPro =
            List.concatMap
                (\j ->
                    [ Bin (Just ("e" ++ String.fromInt j)) L Add (Il.Tmp "env") (Il.Con (vs * j))
                    , Blit (Il.Tmp ("e" ++ String.fromInt j)) (Il.Tmp (slotTmp (pending.nparams + 1 + j))) vs
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
rtCallFuncs : List Func
rtCallFuncs =
    List.map
        (\n ->
            let
                argNames =
                    List.map (\i -> "a" ++ String.fromInt i) (List.range 0 (n - 1))

                params =
                    ( "fn", Base L ) :: ( "e", Base L ) :: List.map (\a -> ( a, Agg "val" )) argNames

                callArgs =
                    ArgEnv (Il.Tmp "e") :: List.map (\a -> ArgVal (Agg "val") (Il.Tmp a)) argNames
            in
            Func ("rt_call" ++ String.fromInt n)
                True
                (Agg "val")
                False
                params
                [ { label = "start"
                  , body =
                        [ Call (Just "r") (Agg "val") (Il.Tmp "fn") callArgs
                        ]
                  , jump = Ret (Just (Il.Tmp "r"))
                  }
                ]
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
                    }
                )
                entries

        entryDatas =
            List.indexedMap
                (\i ( p, _ ) ->
                    { name = "meta" ++ String.fromInt i
                    , align = Just 8
                    , items = [ DRef ("mname" ++ String.fromInt i), DRef p.func.name, DWord p.nparams ]
                    }
                )
                entries

        tableDatas =
            [ { name = "qbe_meta"
              , align = Just 8
              , items = List.map (\i -> DRef ("meta" ++ String.fromInt i)) (List.range 0 (n - 1))
              }
            , { name = "qbe_meta_len"
              , align = Just 8
              , items = [ DWord n ]
              }
            ]
    in
    ( nameDatas ++ entryDatas ++ tableDatas, [] )


-- QBE identifiers are [a-zA-Z_$][a-zA-Z0-9_$]*; every other byte becomes
-- _xHH.  Deterministic, collision-free, and never parsed back.
mangle : String -> String
mangle str =
    String.concat (List.map mangleChar (String.toList str))


mangleChar : Char -> String
mangleChar c =
    let
        code =
            Char.toCode c
    in
    if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) then
        String.fromChar c

    else
        "_x" ++ hex2 code


hex2 : Int -> String
hex2 code =
    if code < 16 then
        String.fromChar (hexDigit code)

    else
        hex2 (code // 16) ++ String.fromChar (hexDigit (modBy 16 code))


hexDigit : Int -> Char
hexDigit d =
    if d < 10 then
        Char.fromCode (48 + d)

    else
        Char.fromCode (87 + d) -- 'a' - 10 + d
