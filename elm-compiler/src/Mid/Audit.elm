module Mid.Audit exposing (run)

-- Mid.Audit — the UNSAFE-NODE AUDIT (handoff osier-midruntime-plan TRACK 2
-- step 3 / handoff osier-rawnodes): the load-bearing seat of the invariant
-- "the front end never emits an unsafe node".
--
-- THE RULE: an `Mid.Ir.Unsafe` node is LEGAL only inside a defun whose key is
-- in the reserved `Rt.*` namespace (compiler-internal runtime defuns, built by
-- the Mid.Rt side from step 4 on).  Any `Unsafe` node under any other key —
-- i.e. anywhere the front end's output could carry one — is a LOUD compile
-- error naming the key and the node.
--
-- WHY THIS SHAPE AND NOT A TYPE-LEVEL WALL: measured out on elm 0.19.2 (see
-- Mid.Ir's UNSAFE NODES header for the three probes) — a second home for the
-- payload type is an import cycle, a re-export is a BAD EXPORT, and private
-- constructors plus builder functions wall DESTRUCTION only, not
-- construction.  So the property is enforced at COMPILER RUNTIME, on every
-- compile: this pass is wired into `Mid.QbeModule.lowerAll` immediately after
-- the program is born (before Flatten and Lower), which means EVERY QBE
-- compile — gate fixtures, corpus, and selfhost alike — fails loudly rather
-- than silently miscompiling a tree that should not exist.
--
-- The threat model is a FROMAST BUG (surface code cannot even NAME an `Rt.*`
-- defun — it is not a corpus unit — so name resolution already blocks the
-- direct route); this pass is the net under that bug class.  Its must-fail
-- fixture lives in `src/TestMain.elm` (a violating program is not producible
-- from surface code by construction, so the fixture builds one directly at
-- the Mid level, exactly as a FromAst bug would leave it).
--
-- RESIDUAL HOLE, recorded rather than hidden: the namespace test is a STRING
-- PREFIX.  A surface module actually named `Rt` would emit keys under the same
-- prefix and slip past this audit; closing that (reserving the `Rt` module
-- name where the collect-time ambiguity checks live) is step 4's business,
-- when the namespace's first real occupant lands.
--
-- COST: one tree walk over the program per compile, before Flatten (the
-- smallest tree it will ever be).  It CONSTRUCTS NOTHING: `run` returns the
-- program unchanged on Ok, so a green audit is byte-identity-preserving —
-- this step's whole oracle.

import Mid.Ir exposing (Defun, Exp(..), LetBinder(..), Program, UnsafeNode(..))


run : Program -> Result String Program
run program =
    auditDefuns program


auditDefuns : Program -> Result String Program
auditDefuns program =
    case program of
        [] ->
            Ok []

        defun :: rest ->
            auditDefun defun
                |> Result.andThen (\() -> auditDefuns rest)
                |> Result.map (\checked -> defun :: checked)


auditDefun : Defun -> Result String ()
auditDefun defun =
    if isRuntimeKey defun.key then
        Ok ()

    else
        case auditExp defun.value of
            Ok () ->
                Ok ()

            Err node ->
                Err
                    ("qbe: unsafe node ("
                        ++ node
                        ++ ") reached key "
                        ++ defun.key
                        ++ " — unsafe nodes are legal only inside Rt.* runtime defuns (front end must never emit one; Mid.Audit)"
                    )


isRuntimeKey : String -> Bool
isRuntimeKey key =
    String.startsWith "Rt." key


auditExp : Exp -> Result String ()
auditExp exp =
    case exp of
        Lit _ ->
            Ok ()

        Var _ ->
            Ok ()

        GRef _ ->
            Ok ()

        StreamRef _ ->
            Ok ()

        Lam lambda ->
            auditExp lambda.body

        NoTail inner ->
            auditExp inner

        App app ->
            auditExp app.fn
                |> Result.andThen (\_ -> auditExps app.args)

        PrimApp app ->
            auditExps app.args

        Let block ->
            letValues block.binders
                |> auditExps
                |> Result.andThen (\_ -> auditExp block.body)

        Case branch ->
            auditExp branch.scrutinee
                |> Result.andThen (\_ -> auditExps (List.map .body branch.alts))

        Con con ->
            auditExps con.args

        Tup es ->
            auditExps es

        RecordLit setters ->
            auditExps (List.map Tuple.second setters)

        RecordGet rec _ ->
            auditExp rec

        RecordUpdate update ->
            auditExp update.base
                |> Result.andThen (\_ -> auditExps (List.map Tuple.second update.updates))

        ListLit es ->
            auditExps es

        If block ->
            auditExps [ block.cond, block.thenBranch, block.elseBranch ]

        ShortAnd block ->
            auditExps [ block.left, block.right ]

        ShortOr block ->
            auditExps [ block.left, block.right ]

        NotEqual block ->
            auditExps [ block.left, block.right ]

        Unsafe node ->
            Err (describe node)


auditExps : List Exp -> Result String ()
auditExps exps =
    case exps of
        [] ->
            Ok ()

        e :: rest ->
            auditExp e
                |> Result.andThen (\_ -> auditExps rest)


letValues : List LetBinder -> List Exp
letValues binders =
    List.concatMap
        (\b ->
            case b of
                LetBind bind ->
                    [ bind.value ]

                LetDestruct d ->
                    [ d.value ]
        )
        binders


describe : UnsafeNode -> String
describe node =
    case node of
        RawCall call ->
            "raw call " ++ call.sym

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
            "rawVecAddr (element address)"

        RawVecStore _ ->
            "rawVecStore (write-barrier contract)"

        RawStrByte _ ->
            "rawStrByte"

        WithRoots _ ->
            "withRoots"

        RawPayload32 _ ->
            "rawPayload32 (i32 payload field read)"

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
            "rawAllocRaw (GC safepoint)"

        RawByteLoad _ ->
            "rawByteLoad"

        RawByteStore _ ->
            "rawByteStore"

        RawWordLoad _ ->
            "rawWordLoad"

        RawWordStore _ ->
            "rawWordStore"

        RawCallRaw call ->
            "raw call word seat " ++ call.sym

        RawCallAgg call ->
            "raw call aggregate " ++ call.shape

        RawDataAddr _ ->
            "rawDataAddr (static data address)"

        RawCStr _ ->
            "rawCStr (static C-string address)"
