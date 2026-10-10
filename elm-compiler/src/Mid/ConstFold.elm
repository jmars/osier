module Mid.ConstFold exposing (Stats, run)

-- Mid.ConstFold — the middle tier's SECOND pass: constant folding on the tree
-- IR, with the VM'S OWN PRIM SEMANTICS AS THE ORACLE.
--
-- WHY THE ORACLE RULE IS THE WHOLE PASS.  A fold rule is a claim about what
-- the ZINC VM would have computed at run time, so the rule must be read off
-- `vendor/osier-rt/src/rt/prims.zig` — not off Elm's semantics and not off the
-- source language's.  The three places the two disagree, and which therefore
-- shape this pass's rule set:
--
--   1. `+`, `-`, `*` are WRAPPING i64 (`+%`, `-%`, `*%` in primAdd/primSub/
--      primMul) while this pass runs in Elm, whose Int is a JS double.  They
--      agree EXACTLY only inside the 2^53 range, so `exactInt` guards every
--      operand and the result and refuses to fold outside it.  (Refusing is
--      free: no source literal in this corpus can even reach 2^53.)
--   2. `/` is `@divTrunc` and TRAPS on a zero divisor (`primDiv`), and `f/` is
--      a float division.  Folding `/` would trade a run-time trap for a
--      compile-time value (or for a crash in the COMPILER), so neither `/`
--      nor `f/` has a rule here.
--   3. `<`, `<=`, `>`, `>=` are numeric-only in the VM's tag dispatch
--      (`primLt` and friends return False for non-numeric operands), while
--      Elm orders strings and lists too.  A rule is therefore provided ONLY
--      for two `Number` literals; a string/string comparison is left alone,
--      because folding it with Elm's ordering would CHANGE the answer.
--
-- What IS folded, all with `LNumber`/`LSymbol`/`LString`/`LBoolean` operands
-- and a same-type result: `+ - *` (2^53-guarded), `=` (the VM's primEq
-- compares numbers numerically, strings by byte content and symbols by name —
-- all three agree with Elm's `==` on literals of one type), and the four
-- ORDER comparisons on two numbers.
--
-- ARGUMENT ORDER: `Mid.Ir.PrimApp.args` is in the prim's POP order (the
-- emitter pushes them in reverse), so for `lhs OP rhs` the list is
-- `[ lhs, rhs ]` and the VM's first pop is `lhs`.  The rules below read
-- args[0] as the LEFT operand, which is what `lhs - rhs` and `lhs < rhs`
-- require (`+`/`*`/`=` are symmetric and would hide an order bug).
--
-- CASE-OF-KNOWN-CONSTRUCTOR: NOT IMPLEMENTED — see `Stats.knownCtorSeen`.
-- The plan pairs it with folding, so this pass also carries the SEAT that
-- counts the shape it would need (a `case` whose scrutinee is a constructor
-- the tree already knows: either a `Con` node directly, or a `Var` whose
-- whole `let` chain binds it to one) and reports the count.  MEASURED on the
-- compiler's own 58 sources + the corpus: 0.  The transform is therefore not
-- built rather than built-and-never-taken, and the number is published so the
-- next reader does not have to re-measure to find that out.  See the module's
-- opportunity report and the pass's commit message; if a future corpus
-- produces a non-zero count, the rewrite is mechanical (select the alt whose
-- matches are all statically true, substitute the alt's bind binders with the
-- constructor's arguments, and re-run Shrink).
--
-- WHAT FOLDING DOES NOT DO HERE: it does not fold arithmetic that appears
-- inside a `Let` value used once (that would be Shrink's dead/trivial rule,
-- but Shrink runs ONCE, BEFORE this pass — Mid.Simplify's fixed order — and
-- is not re-run after it, so a let-bound fold it did not already collapse is
-- left for the emitter), and it does not touch `PrimApp`s whose args are
-- variables.

import Mid.Ir exposing (Alt, Defun, Exp(..), LetBinder(..), Lit(..))


type alias Stats =
    { folds : Int
    , primApps : Int
    , allLiteral : Int
    , refusedRange : Int
    , refusedOracle : Int
    , caseScrutineeCon : Int
    , letValueCon : Int
    }


zero : Stats
zero =
    { folds = 0
    , primApps = 0
    , allLiteral = 0
    , refusedRange = 0
    , refusedOracle = 0
    , caseScrutineeCon = 0
    , letValueCon = 0
    }


plus : Stats -> Stats -> Stats
plus a b =
    { folds = a.folds + b.folds
    , primApps = a.primApps + b.primApps
    , allLiteral = a.allLiteral + b.allLiteral
    , refusedRange = a.refusedRange + b.refusedRange
    , refusedOracle = a.refusedOracle + b.refusedOracle
    , caseScrutineeCon = a.caseScrutineeCon + b.caseScrutineeCon
    , letValueCon = a.letValueCon + b.letValueCon
    }


run : List Defun -> ( List Defun, String )
run defuns =
    let
        ( rev, stats ) =
            List.foldl foldDefun ( [], zero ) defuns
    in
    ( List.reverse rev, report stats )


report : Stats -> String
report s =
    if s.primApps == 0 then
        ""

    else
        "constfold: prims="
            ++ String.fromInt s.primApps
            ++ " allLiteral="
            ++ String.fromInt s.allLiteral
            ++ " folded="
            ++ String.fromInt s.folds
            ++ " refused(2^53)="
            ++ String.fromInt s.refusedRange
            ++ " refused(oracle)="
            ++ String.fromInt s.refusedOracle
            ++ " | caseOfKnownSeat: con-scrutinee="
            ++ String.fromInt s.caseScrutineeCon
            ++ " con-valued-let="
            ++ String.fromInt s.letValueCon


foldDefun : Defun -> ( List Defun, Stats ) -> ( List Defun, Stats )
foldDefun defun ( acc, accStats ) =
    let
        ( value, stats ) =
            foldExp defun.value
    in
    ( { defun | value = value } :: acc, plus accStats stats )



-- ============================ THE WALK ============================


foldExp : Exp -> ( Exp, Stats )
foldExp exp =
    case exp of
        PrimApp app ->
            let
                ( args, s1 ) =
                    foldAll app.args

                base =
                    { s1 | primApps = s1.primApps + 1 }
            in
            case allLiterals args of
                Just lits ->
                    let
                        withLiteral =
                            { base | allLiteral = base.allLiteral + 1 }
                    in
                    case evalPrim app.prim lits of
                        Folded lit ->
                            ( Lit lit, { withLiteral | folds = withLiteral.folds + 1 } )

                        NoRule ->
                            ( PrimApp { app | args = args }, { withLiteral | refusedOracle = withLiteral.refusedOracle + 1 } )

                        RefusedRange ->
                            ( PrimApp { app | args = args }, { withLiteral | refusedRange = withLiteral.refusedRange + 1 } )

                Nothing ->
                    ( PrimApp { app | args = args }, base )

        Case branch ->
            let
                ( scrutinee, s1 ) =
                    foldExp branch.scrutinee

                ( alts, s2 ) =
                    foldAlts branch.alts

                both =
                    plus s1 s2

                conScrutinee =
                    case scrutinee of
                        Con _ ->
                            1

                        _ ->
                            0
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }
            , { both | caseScrutineeCon = both.caseScrutineeCon + conScrutinee }
            )

        Lit _ ->
            ( exp, zero )

        Var _ ->
            ( exp, zero )

        GRef _ ->
            ( exp, zero )

        StreamRef _ ->
            ( exp, zero )

        Lam lam ->
            let
                ( body, s ) =
                    foldExp lam.body
            in
            ( Lam { lam | body = body }, s )

        NoTail inner ->
            let
                ( e, s ) =
                    foldExp inner
            in
            ( NoTail e, s )

        App app ->
            let
                ( fn, s1 ) =
                    foldExp app.fn

                ( args, s2 ) =
                    foldAll app.args
            in
            ( App { app | fn = fn, args = args }, plus s1 s2 )

        Let block ->
            let
                ( binders, s1 ) =
                    foldBinders block.binders

                ( body, s2 ) =
                    foldExp block.body
            in
            ( Let { binders = binders, body = body }, plus s1 s2 )

        Con con ->
            let
                ( args, s ) =
                    foldAll con.args
            in
            ( Con { con | args = args }, s )

        Tup es ->
            let
                ( es1, s ) =
                    foldAll es
            in
            ( Tup es1, s )

        RecordLit setters ->
            let
                ( setters1, s ) =
                    foldSetters setters
            in
            ( RecordLit setters1, s )

        RecordGet base field ->
            let
                ( b, s ) =
                    foldExp base
            in
            ( RecordGet b field, s )

        RecordUpdate upd ->
            let
                ( base, s1 ) =
                    foldExp upd.base

                ( updates, s2 ) =
                    foldSetters upd.updates
            in
            ( RecordUpdate { upd | base = base, updates = updates }, plus s1 s2 )

        ListLit es ->
            let
                ( es1, s ) =
                    foldAll es
            in
            ( ListLit es1, s )

        If block ->
            let
                ( cond, s1 ) =
                    foldExp block.cond

                ( t, s2 ) =
                    foldExp block.thenBranch

                ( f, s3 ) =
                    foldExp block.elseBranch
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, plus s1 (plus s2 s3) )

        ShortAnd block ->
            let
                ( left, s1 ) =
                    foldExp block.left

                ( right, s2 ) =
                    foldExp block.right
            in
            ( ShortAnd { block | left = left, right = right }, plus s1 s2 )

        ShortOr block ->
            let
                ( left, s1 ) =
                    foldExp block.left

                ( right, s2 ) =
                    foldExp block.right
            in
            ( ShortOr { block | left = left, right = right }, plus s1 s2 )

        NotEqual block ->
            let
                ( left, s1 ) =
                    foldExp block.left

                ( right, s2 ) =
                    foldExp block.right
            in
            ( NotEqual { block | left = left, right = right }, plus s1 s2 )


foldAll : List Exp -> ( List Exp, Stats )
foldAll exps =
    case exps of
        [] ->
            ( [], zero )

        e :: rest ->
            let
                ( e1, s1 ) =
                    foldExp e

                ( rest1, s2 ) =
                    foldAll rest
            in
            ( e1 :: rest1, plus s1 s2 )


foldSetters : List ( String, Exp ) -> ( List ( String, Exp ), Stats )
foldSetters setters =
    case setters of
        [] ->
            ( [], zero )

        ( field, value ) :: rest ->
            let
                ( v1, s1 ) =
                    foldExp value

                ( rest1, s2 ) =
                    foldSetters rest
            in
            ( ( field, v1 ) :: rest1, plus s1 s2 )


foldBinders : List LetBinder -> ( List LetBinder, Stats )
foldBinders binders =
    case binders of
        [] ->
            ( [], zero )

        b :: rest ->
            let
                ( b1, s1 ) =
                    foldBinder b

                ( rest1, s2 ) =
                    foldBinders rest
            in
            ( b1 :: rest1, plus s1 s2 )


foldBinder : LetBinder -> ( LetBinder, Stats )
foldBinder b =
    case b of
        LetBind bind ->
            let
                ( v, s ) =
                    foldExp bind.value

                isCon =
                    case bind.value of
                        Con _ ->
                            1

                        _ ->
                            0
            in
            ( LetBind { bind | value = v }, { s | letValueCon = s.letValueCon + isCon } )

        LetDestruct destruct ->
            let
                ( v, s ) =
                    foldExp destruct.value
            in
            ( LetDestruct { destruct | value = v }, s )


foldAlts : List Alt -> ( List Alt, Stats )
foldAlts alts =
    case alts of
        [] ->
            ( [], zero )

        alt :: rest ->
            let
                ( body, s1 ) =
                    foldExp alt.body

                ( rest1, s2 ) =
                    foldAlts rest
            in
            ( { alt | body = body } :: rest1, plus s1 s2 )


allLiterals : List Exp -> Maybe (List Lit)
allLiterals exps =
    case exps of
        [] ->
            Just []

        e :: rest ->
            case e of
                Lit lit ->
                    Maybe.map ((::) lit) (allLiterals rest)

                _ ->
                    Nothing



-- ============================ THE FOLD RULES ============================
-- `NoRule` ("no rule for this shape or prim") and `RefusedRange` (a rule
-- exists but the 2^53 guard forbids it) are both ALWAYS the safe answer; they
-- are separate so the opportunity report can tell a missing rule apart from a
-- range refusal.


type FoldResult
    = Folded Lit
    | NoRule
    | RefusedRange


exactInt : Int -> Bool
exactInt n =
    (n <= 9007199254740991) && (n >= -9007199254740991)


evalPrim : String -> List Lit -> FoldResult
evalPrim prim args =
    case ( prim, args ) of
        ( "+", [ LNumber a, LNumber b ] ) ->
            arith (+) a b

        ( "-", [ LNumber a, LNumber b ] ) ->
            arith (-) a b

        ( "*", [ LNumber a, LNumber b ] ) ->
            arith (*) a b

        ( "=", [ LNumber a, LNumber b ] ) ->
            Folded (LBoolean (a == b))

        ( "=", [ LString a, LString b ] ) ->
            Folded (LBoolean (a == b))

        ( "=", [ LSymbol a, LSymbol b ] ) ->
            Folded (LBoolean (a == b))

        ( "=", [ LBoolean a, LBoolean b ] ) ->
            Folded (LBoolean (a == b))

        ( "<", [ LNumber a, LNumber b ] ) ->
            Folded (LBoolean (a < b))

        ( "<=", [ LNumber a, LNumber b ] ) ->
            Folded (LBoolean (a <= b))

        ( ">", [ LNumber a, LNumber b ] ) ->
            Folded (LBoolean (a > b))

        ( ">=", [ LNumber a, LNumber b ] ) ->
            Folded (LBoolean (a >= b))

        _ ->
            NoRule


arith : (Int -> Int -> Int) -> Int -> Int -> FoldResult
arith op a b =
    let
        r =
            op a b
    in
    if exactInt a && exactInt b && exactInt r then
        Folded (LNumber r)

    else
        RefusedRange
