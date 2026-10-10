module Mid.FromAst exposing
    ( Context
    , Gen
    , newContext
    , runGen
    , pure
    , map
    , andThen
    , fail
    , freshBinder
    , freshBinders
    , withScope
    , withImport
    , withModuleAliases
    , withOpenTypeModules
    , fromExpression
    , lambdaExp
    , clauseCase
    , argNames
    )

-- Mid.FromAst — elm-syntax AST -> Mid.Ir, i.e. the middle tier's FRONT END.
--
-- This module absorbs, for the MIDTIER=1 path, what these do on the
-- MIDTIER=0 path today:
--   * `Lower.Resolve`'s alias tables (REUSED, not copied — see below),
--   * `Lower.Expr`'s resolution order and AST walk,
--   * `Lower.Pattern`'s `normalizeClauses` desugar and `compilePattern`
--     (rewritten here to build structural `Mid.Ir.Match` values instead of
--     raw instruction lists, so a later pass can reason about a case alt
--     instead of pattern-matching on emitted code),
--   * name-based scope handling, replaced by UNIQUE-INT BINDERS: resolution
--     still happens here, by NAME, against the lexical scope (that is what
--     Elm's scoping rules are), but the RESULT is re-interned as a binder id,
--     so the tree below this point never mentions a name again.
--
-- STAGE 1 IS A PURE REFACTOR: every emitted instruction was previously
-- produced by `Lower.Expr` and must come out identical.  The rules this file
-- implements are therefore copied from `Lower.Expr` clause by clause —
-- including the ORDER in which sub-expressions are visited, because Elm is
-- strict and the first error raised is the error the compiler reports (the
-- gate pins several `err <msg>` fixtures).
--
-- WHAT IS DELIBERATELY *NOT* COPIED: emission.  `Position` (Tail | NonTail),
-- the `p`/`t` choice, the RTL argument pushes, the env-slot arithmetic and the
-- endlet counts are all DECISIONS OF THE EMITTER (`Mid.ToZinc`), derived from
-- the tree plus the position it is emitted in.  That split is the point of
-- the middle tier: the tree says WHAT, the emitter says HOW the ZINC VM
-- wants it.
--
-- REUSED TABLES (stage-1 pragmatism, to be reclaimed by Mid at S7): the
-- operator/prim tables (`Lower.Expr.binaryPrims`/`primWrappers`/`unaryPrims`/
-- `ternaryPrims`/`wrapperGlobalName`/`resolveModuleAlias`) and the alias
-- tables (`Lower.Resolve.*`) are imported rather than duplicated.
-- `Lower.Resolve` is already the SHARED leaf module between the typechecker
-- and the lowerer (that is why it exists), so importing it from the middle
-- tier cannot introduce a cycle; the prim tables live in `Lower.Expr`, which
-- cannot be edited in stage 1 without changing the committed selfhost seed
-- (see the stage report).  Duplicating them would create exactly the
-- drift-between-two-tables failure this project has already paid for once.
--
-- ERROR-MESSAGE PARITY: `Lower.Module` and `Lower.Expr` each carry a private
-- `patternNames` with slightly different wording for the SAME unreachable
-- condition (only reachable if a non-variable pattern reaches a defun/lambda
-- argument list, which the clause desugarer never produces — every such path
-- builds fresh `$argN` variable binders first).  This module uses one copy,
-- with `Lower.Module`'s wording.

import Dict exposing (Dict)
import Elm.Syntax.Expression as Expression exposing (Expression(..))
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..), QualifiedNameRef)
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Expr as LExpr
import Mid.Ir exposing (Alt, AltKind(..), Binder, Defun, Exp(..), LetBinder(..), Lit(..), Match(..), Step(..), ValuePath(..))



-- ============================ CONTEXT ============================


type alias Context =
    { moduleName : List String
    , scope : List Binder
    , globals : Dict String Int
    , imports : List ( String, String )
    , moduleAliases : List ( String, String )
    , openTypeModules : List (List String)
    }


newContext : List String -> Dict String Int -> Context
newContext moduleName globals =
    { moduleName = moduleName
    , scope = []
    , globals = globals
    , imports = []
    , moduleAliases = []
    , openTypeModules = []
    }


withScope : Context -> List Binder -> Context
withScope ctx binders =
    -- Binders are innermost-first, like Lower.Scope: appending the newly
    -- pushed block in SOURCE order puts its first binder outermost.
    { ctx | scope = binders ++ ctx.scope }


withImport : List ( String, String ) -> Context -> Context
withImport imports ctx =
    { ctx | imports = imports }


withModuleAliases : List ( String, String ) -> Context -> Context
withModuleAliases aliases ctx =
    { ctx | moduleAliases = aliases }


withOpenTypeModules : List (List String) -> Context -> Context
withOpenTypeModules mods ctx =
    { ctx | openTypeModules = mods }



-- ============================ BINDER SUPPLY ============================
-- The explicit threading the plan's addendum calls for: a generator is a
-- function from the next free binder id to a result plus the next free id.
-- Nothing clever — a state monad written out by hand, so it ports to a
-- module/functor argument when Osier grows rank-2 first-class modules.


type alias Gen a =
    Int -> Result String ( a, Int )


runGen : Gen a -> Result String a
runGen gen =
    Result.map Tuple.first (gen 0)


pure : a -> Gen a
pure a =
    \s -> Ok ( a, s )


map : (a -> b) -> Gen a -> Gen b
map f gen =
    \s -> Result.map (\( a, s1 ) -> ( f a, s1 )) (gen s)


andThen : (a -> Gen b) -> Gen a -> Gen b
andThen f gen =
    \s ->
        case gen s of
            Err msg ->
                Err msg

            Ok ( a, s1 ) ->
                f a s1


fail : String -> Gen a
fail msg =
    \_ -> Err msg


freshBinder : String -> Gen Binder
freshBinder name =
    \s -> Ok ( { id = s, name = name }, s + 1 )


freshBinders : List String -> Gen (List Binder)
freshBinders names =
    case names of
        [] ->
            pure []

        name :: rest ->
            andThen (\binder -> map (\binders -> binder :: binders) (freshBinders rest)) (freshBinder name)



-- ============================ SCOPE / NAME RESOLUTION ============================


resolveScope : Context -> String -> Maybe Int
resolveScope ctx name =
    indexOfBinder name ctx.scope


indexOfBinder : String -> List Binder -> Maybe Int
indexOfBinder name binders =
    case binders of
        [] ->
            Nothing

        binder :: rest ->
            if binder.name == name then
                Just binder.id

            else
                indexOfBinder name rest


resolveImport : String -> List ( String, String ) -> Maybe String
resolveImport name imports =
    Maybe.map Tuple.second (listAssoc lookupPair name imports)


lookupPair : String -> ( String, String ) -> Bool
lookupPair a ( b, _ ) =
    a == b


listAssoc : (String -> a -> Bool) -> String -> List a -> Maybe a
listAssoc pred key items =
    case items of
        [] ->
            Nothing

        item :: rest ->
            if pred key item then
                Just item

            else
                listAssoc pred key rest


primOf : String -> Maybe String
primOf op =
    List.filterMap (\( o, p ) -> if o == op then Just p else Nothing) LExpr.binaryPrims
        |> List.head


primWrapperName : String -> Maybe String
primWrapperName op =
    if List.any (\( o, _ ) -> o == op) LExpr.binaryPrims then
        Just (LExpr.wrapperGlobalName op)

    else
        Nothing



-- ============================ EXPRESSIONS ============================


fromExpression : Context -> Node Expression -> Gen Exp
fromExpression ctx (Node range expr) =
    case expr of
        Integer n ->
            pure (Lit (LNumber n))

        Hex n ->
            pure (Lit (LNumber n))

        Literal str ->
            pure (Lit (LString str))

        CharLiteral c ->
            pure (Lit (LString (String.fromChar c)))

        UnitExpr ->
            pure (Lit (LSymbol "()"))

        Floatable f ->
            pure (Lit (LFloat f))

        Negation inner ->
            negation ctx inner

        ParenthesizedExpression inner ->
            fromExpression ctx inner

        FunctionOrValue modName name ->
            functionOrValue ctx modName name

        PrefixOperator op ->
            operatorValue ctx op

        Operator op ->
            operatorValue ctx op

        OperatorApplication op _ left right ->
            operatorApplication ctx range op left right

        Application es ->
            application ctx es

        IfBlock cond thenExpr elseExpr ->
            ifBlock ctx range cond thenExpr elseExpr

        LambdaExpression lambda ->
            lambdaExp ctx lambda

        LetExpression block ->
            letExpr ctx block

        CaseExpression block ->
            caseExprRange ctx range block

        RecordExpr setters ->
            recordExpr ctx setters

        RecordAccess rec nameNode ->
            recordAccess ctx rec nameNode

        RecordAccessFunction name ->
            recordAccessFunction ctx name

        RecordUpdateExpression baseName updates ->
            recordUpdate ctx baseName updates

        ListExpr es ->
            listExpr ctx es

        TupledExpression es ->
            tupledExpr ctx es

        InsertionValue inner ->
            -- An insertion setter RHS (`{r | f <- v}`) lowers identically to an
            -- update (prepend-pair), so unwrap to the inner expression.
            fromExpression ctx inner

        _ ->
            fail "unsupported expression in the M1b subset (case/records/ADTs are M2)"


negation : Context -> Node Expression -> Gen Exp
negation ctx inner =
    case inner of
        Node _ (Integer n) ->
            pure (Lit (LNumber (-n)))

        Node _ (Hex n) ->
            pure (Lit (LNumber (-n)))

        Node _ (Floatable f) ->
            pure (Lit (LFloat (-f)))

        _ ->
            -- `-e` is `0 - e`: the emitter pushes the args right-to-left, so
            -- the popped pair is (0, e) — exactly `code(e) n0 P -`.
            map (\e -> PrimApp { prim = "-", args = [ Lit (LNumber 0), e ] }) (fromExpression ctx inner)


functionOrValue : Context -> List String -> String -> Gen Exp
functionOrValue ctx modName name =
    if not (List.isEmpty modName) then
        if modName == ctx.moduleName then
            resolveGlobal ctx (String.join "." (modName ++ [ name ]))

        else
            resolveName ctx (String.join "." (modName ++ [ name ]))

    else if name == "True" then
        pure (Lit (LBoolean True))

    else if name == "False" then
        pure (Lit (LBoolean False))

    else
        case resolveScope ctx name of
            Just id ->
                pure (Var id)

            Nothing ->
                if name == "stdin" then
                    pure (StreamRef { varName = "*stinput*" })

                else if name == "stdout" then
                    pure (StreamRef { varName = "*stoutput*" })

                else if name == "argvPrim" then
                    argvPrimThunk

                else
                    resolveName ctx name


-- The argvPrim rewrite body: a 1-arg thunk `\_ -> value *argv*` over the
-- driver-installed plain list of argument strings.  ONE real binder (a fresh
-- id, so it can never collide with a scope binder) makes the QBE backend's
-- static arity 1 — the arity-1 shape the ZINC `Cur []` (zero grabs + Return)
-- has — while ToZinc still emits ZERO grabs for it (`repeat (1-1) Grab`), so
-- the csexp output is byte-identical.
argvPrimThunk : Gen Exp
argvPrimThunk =
    map
        (\b -> Lam { params = [ b ], body = PrimApp { prim = "value", args = [ Lit (LSymbol "*argv*") ] } })
        (freshBinder "$argv")


-- THE UNIFIED NAME RESOLUTION ORDER for a reference token t (bare or dotted):
-- local scope, alias-table rows, raw globals membership, error.
resolveName : Context -> String -> Gen Exp
resolveName ctx token =
    case resolveScope ctx token of
        Just id ->
            pure (Var id)

        Nothing ->
            let
                -- Self-qualified spelling of a BARE token: a module's own
                -- top-level names resolve BEFORE the alias table, mirroring
                -- the typechecker's `ctx.top`-first order.
                qualified =
                    String.join "." ctx.moduleName ++ "." ++ token

                openTokens =
                    List.map (\m -> String.join "." (m ++ [ token ])) ctx.openTypeModules
            in
            case tryAllTokens ctx (qualified :: token :: LExpr.resolveModuleAlias ctx.moduleAliases token :: openTokens) of
                Just exp ->
                    exp

                Nothing ->
                    fail ("unknown name: " ++ token)


tryToken : Context -> String -> Maybe (Gen Exp)
tryToken ctx token =
    case resolveImport token ctx.imports of
        Just gkey ->
            Just (globalRefByKey ctx gkey)

        Nothing ->
            if Dict.member token ctx.globals then
                Just (globalRefByKey ctx token)

            else
                Nothing


tryAllTokens : Context -> List String -> Maybe (Gen Exp)
tryAllTokens ctx tokens =
    case tokens of
        [] ->
            Nothing

        token :: rest ->
            case tryToken ctx token of
                Just exp ->
                    Just exp

                Nothing ->
                    tryAllTokens ctx rest


-- A resolved global key is emitted by the KEY'S OWN ARITY: 0-arity entries are
-- thunks and must be APPLIED; everything else loads the closure directly.
globalRefByKey : Context -> String -> Gen Exp
globalRefByKey ctx name =
    case Dict.get name ctx.globals of
        Just 0 ->
            pure (GRef { key = name, force = True })

        _ ->
            pure (GRef { key = name, force = False })


resolveGlobal : Context -> String -> Gen Exp
resolveGlobal ctx name =
    case Dict.get name ctx.globals of
        Just 0 ->
            pure (GRef { key = name, force = True })

        Just _ ->
            pure (GRef { key = name, force = False })

        Nothing ->
            fail ("unknown name: " ++ name)


operatorValue : Context -> String -> Gen Exp
operatorValue _ op =
    case primWrapperName op of
        Just wname ->
            pure (GRef { key = wname, force = False })

        Nothing ->
            fail ("unsupported operator used as a value: " ++ op)


operatorApplication : Context -> Range -> String -> Node Expression -> Node Expression -> Gen Exp
operatorApplication ctx range op left right =
    case op of
        "&&" ->
            andShort ctx range left right

        "||" ->
            orShort ctx range left right

        "/=" ->
            notEqual ctx range left right

        "::" ->
            -- Cons sugar: `x :: xs` is a 2-arg cons application (RTL prim args).
            andThen
                (\rcode -> map (\lcode -> PrimApp { prim = "cons", args = [ lcode, rcode ] }) (fromExpression ctx left))
                (fromExpression ctx right)

        "|>" ->
            pipeApply ctx right left

        "<|" ->
            pipeApply ctx left right

        _ ->
            case primOf op of
                Just pname ->
                    andThen
                        (\rcode -> map (\lcode -> PrimApp { prim = pname, args = [ lcode, rcode ] }) (fromExpression ctx left))
                        (fromExpression ctx right)

                Nothing ->
                    fail ("unsupported operator: " ++ op)


-- `x |> f a b` desugars to the SINGLE application `f a b x` (and `<|`
-- likewise): a stack-level "apply the partial afterwards" is NOT equivalent,
-- because completing a partial whose callee collects its remaining args with
-- Grabs misbinds.
pipeApply : Context -> Node Expression -> Node Expression -> Gen Exp
pipeApply ctx funcExpr argExpr =
    -- ALWAYS NonTail, whatever the surrounding position: that is what
    -- Lower.Expr.pipeApply does, and it is observable in the emitted bytes
    -- (`p`, never `t`), so the tree records it.
    map NoTail
        (case funcExpr of
            Node _ (Application (head :: args)) ->
                application ctx (head :: (args ++ [ argExpr ]))

            _ ->
                application ctx [ funcExpr, argExpr ]
        )


andShort : Context -> Range -> Node Expression -> Node Expression -> Gen Exp
andShort ctx range left right =
    let
        lfalse =
            label range "and_false"

        lend =
            label range "and_end"
    in
    andThen
        (\lcode ->
            map
                (\rcode -> ShortAnd { left = lcode, right = rcode, falseLabel = lfalse, endLabel = lend })
                (fromExpression ctx right)
        )
        (fromExpression ctx left)


orShort : Context -> Range -> Node Expression -> Node Expression -> Gen Exp
orShort ctx range left right =
    let
        lfalse =
            label range "or_false"

        lend =
            label range "or_end"
    in
    andThen
        (\lcode ->
            map
                (\rcode -> ShortOr { left = lcode, right = rcode, falseLabel = lfalse, endLabel = lend })
                (fromExpression ctx right)
        )
        (fromExpression ctx left)


notEqual : Context -> Range -> Node Expression -> Node Expression -> Gen Exp
notEqual ctx range left right =
    let
        lfalse =
            label range "ne_false"

        lend =
            label range "ne_end"
    in
    andThen
        (\rcode ->
            map
                (\lcode -> NotEqual { left = lcode, right = rcode, falseLabel = lfalse, endLabel = lend })
                (fromExpression ctx left)
        )
        (fromExpression ctx right)


ifBlock : Context -> Range -> Node Expression -> Node Expression -> Node Expression -> Gen Exp
ifBlock ctx range cond thenExpr elseExpr =
    let
        lfalse =
            label range "if_false"

        lend =
            label range "if_end"
    in
    andThen
        (\ccode ->
            andThen
                (\tcode ->
                    map
                        (\ecode -> If { cond = ccode, thenBranch = tcode, elseBranch = ecode, falseLabel = lfalse, endLabel = lend })
                        (fromExpression ctx elseExpr)
                )
                (fromExpression ctx thenExpr)
        )
        (fromExpression ctx cond)


application : Context -> List (Node Expression) -> Gen Exp
application ctx es =
    case es of
        [] ->
            fail "empty application"

        fn :: args ->
            andThen
                (\argExps -> map (\f -> App { fn = f, args = argExps }) (callee ctx fn))
                (fromArgs ctx args)


fromArgs : Context -> List (Node Expression) -> Gen (List Exp)
fromArgs ctx exprs =
    case exprs of
        [] ->
            pure []

        e :: rest ->
            andThen (\code -> map (\codes -> code :: codes) (fromArgs ctx rest)) (fromExpression ctx e)


callee : Context -> Node Expression -> Gen Exp
callee ctx fn =
    case fn of
        Node _ (FunctionOrValue modName name) ->
            calleeFunctionOrValue ctx modName name

        _ ->
            fromExpression ctx fn


-- The callee side of name resolution MIRRORS functionOrValue over the joined
-- token, EXCEPT that it has no stdin/stdout rewrite (they are Stream values,
-- never called) while it DOES keep argvPrim's (it is used APPLIED).
calleeFunctionOrValue : Context -> List String -> String -> Gen Exp
calleeFunctionOrValue ctx modName name =
    if not (List.isEmpty modName) then
        if modName == ctx.moduleName then
            resolveGlobal ctx (String.join "." (modName ++ [ name ]))

        else
            resolveName ctx (String.join "." (modName ++ [ name ]))

    else
        case resolveScope ctx name of
            Just id ->
                pure (Var id)

            Nothing ->
                if name == "argvPrim" then
                    argvPrimThunk

                else
                    resolveName ctx name


lambdaExp : Context -> Expression.Lambda -> Gen Exp
lambdaExp ctx lambda =
    if List.all isSimpleVarPattern lambda.args then
        emitLambda ctx lambda.args lambda.expression

    else
        andThen
            (\( params, caseExp ) -> pure (Lam { params = params, body = caseExp }))
            (clauseCase ctx [ ( lambda.args, lambda.expression ) ])


emitLambda : Context -> List (Node Pattern.Pattern) -> Node Expression -> Gen Exp
emitLambda ctx argNodes bodyNode =
    case argNames argNodes of
        Err msg ->
            fail msg

        Ok names ->
            andThen
                (\params ->
                    map (\body -> Lam { params = params, body = body })
                        (fromExpression (withScope ctx params) bodyNode)
                )
                (freshBinders names)


letExpr : Context -> Expression.LetBlock -> Gen Exp
letExpr ctx block =
    andThen
        (\( binders, bodyCtx ) -> map (\body -> Let { binders = binders, body = body }) (fromExpression bodyCtx block.expression))
        (bindAll ctx block.declarations)


bindAll : Context -> List (Node Expression.LetDeclaration) -> Gen ( List LetBinder, Context )
bindAll ctx decls =
    case decls of
        [] ->
            pure ( [], ctx )

        decl :: rest ->
            andThen
                (\( binder, ctx1 ) -> map (\( restBinders, ctx2 ) -> ( binder :: restBinders, ctx2 )) (bindAll ctx1 rest))
                (bindOne ctx decl)


bindOne : Context -> Node Expression.LetDeclaration -> Gen ( LetBinder, Context )
bindOne ctx (Node _ decl) =
    case decl of
        Expression.LetDestructuring patNode eNode ->
            if isSimpleVarPattern patNode then
                case patternName patNode of
                    Err msg ->
                        fail msg

                    Ok name ->
                        andThen
                            (\value ->
                                map
                                    (\binder -> ( LetBind { binder = binder, value = value }, withScope ctx [ binder ] ))
                                    (freshBinder name)
                            )
                            (fromExpression ctx eNode)

            else
                bindDestructuring ctx patNode eNode

        Expression.LetFunction fn ->
            lowerLetFunction ctx fn


-- A complex-pattern let-binding desugars to
-- `let $case = e in <tests; bindings>`: ONE scrutinee temp slot plus one slot
-- per pattern binding, which is what the NonTail endlet count must add up to.
bindDestructuring : Context -> Node Pattern.Pattern -> Node Expression -> Gen ( LetBinder, Context )
bindDestructuring ctx patNode eNode =
    andThen
        (\value ->
            andThen
                (\scrutId ->
                    case caseMatches patNode of
                        Err msg ->
                            fail msg

                        Ok matched ->
                            map
                                (\binds ->
                                    ( LetDestruct
                                        { scrutId = scrutId
                                        , value = value
                                        , matches = matched.matches
                                        , binds = binds
                                        , badLabel = label (Node.range patNode) "let_bad"
                                        , okLabel = label (Node.range patNode) "let_ok"
                                        }
                                    , withScope ctx (List.map Tuple.first binds ++ [ scrutId ])
                                    )
                                )
                                (bindPatternNames matched.binds)
                )
                (freshBinder "$case")
        )
        (fromExpression ctx eNode)


lowerLetFunction : Context -> Expression.Function -> Gen ( LetBinder, Context )
lowerLetFunction ctx fn =
    case fn.declaration of
        Node _ impl ->
            let
                name =
                    nodeString impl.name
            in
            if List.isEmpty impl.arguments then
                -- `let a = <value>` parses as a 0-arg LetFunction: a VALUE
                -- binding (no Cur), so references Access the value.
                andThen
                    (\value ->
                        map
                            (\binder -> ( LetBind { binder = binder, value = value }, withScope ctx [ binder ] ))
                            (freshBinder name)
                    )
                    (fromExpression ctx impl.expression)

            else
                -- Simple variable args and pattern args alike go through the
                -- lambda desugar (which routes pattern args to a case).
                andThen
                    (\value ->
                        map
                            (\binder -> ( LetBind { binder = binder, value = value }, withScope ctx [ binder ] ))
                            (freshBinder name)
                    )
                    (lambdaExp ctx { args = impl.arguments, expression = impl.expression })


-- ============================ CASE ============================


caseExprRange : Context -> Range -> Expression.CaseBlock -> Gen Exp
caseExprRange ctx range block =
    andThen (\scrutinee -> buildCaseFrom ctx range block.cases scrutinee) (fromExpression ctx block.expression)


buildCaseFrom : Context -> Range -> Expression.Cases -> Exp -> Gen Exp
buildCaseFrom ctx range cases scrutinee =
    let
        endLabel =
            label range "case_end"
    in
    andThen
        (\scrutId ->
            let
                scrutCtx =
                    withScope ctx [ scrutId ]
            in
            map
                (\alts -> Case { scrutinee = scrutinee, scrutId = scrutId, alts = alts, endLabel = endLabel })
                (lowerClauses scrutCtx range (List.indexedMap Tuple.pair cases) endLabel)
        )
        (freshBinder "$case")


lowerClauses : Context -> Range -> List ( Int, Expression.Case ) -> String -> Gen (List Alt)
lowerClauses ctx caseRange indexed endLabel =
    case indexed of
        [] ->
            pure []

        ( i, clause ) :: rest ->
            andThen
                (\alt -> map (\alts -> alt :: alts) (lowerClauses ctx caseRange rest endLabel))
                (lowerClause ctx caseRange i clause endLabel)


lowerClause : Context -> Range -> Int -> Expression.Case -> String -> Gen Alt
lowerClause ctx caseRange i ( patNode, bodyNode ) endLabel =
    let
        nextLabel =
            labelIndex caseRange "case_next" i
    in
    case caseMatches patNode of
        Err msg ->
            fail msg

        Ok matched ->
            andThen
                (\binds ->
                    map
                        (\body ->
                            { kind = altKind patNode
                            , matches = matched.matches
                            , binds = binds
                            , body = body
                            , nextLabel = nextLabel
                            }
                        )
                        (fromExpression (withScope ctx (List.map Tuple.first binds)) bodyNode)
                )
                (bindPatternNames matched.binds)


-- What the alt is ABOUT (metadata for later passes; emission is driven by the
-- match sequence).
altKind : Node Pattern.Pattern -> AltKind
altKind (Node _ pat) =
    case pat of
        NamedPattern qref _ ->
            if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
                AltLit (LBoolean (qref.name == "True"))

            else
                AltCtor qref.name

        UnitPattern ->
            AltLit (LSymbol "()")

        CharPattern c ->
            AltLit (LString (String.fromChar c))

        StringPattern s ->
            AltLit (LString s)

        IntPattern n ->
            AltLit (LNumber n)

        HexPattern n ->
            AltLit (LNumber n)

        _ ->
            AltOther


-- ============================ CLAUSE DESUGAR ============================
-- normalizeClauses, rebuilt to produce Mid directly: `n` fresh `$argN`
-- variable binders plus a `case` over the tuple of them that re-matches the
-- original patterns.  The synthesized case's LABEL RANGE is the first clause's
-- first argument pattern (declaration-site-unique within the defun) — NOT the
-- body's range, because a body that is itself a `case` would otherwise collide
-- with it under Zinc.Emit's last-wins label map.


clauseCase : Context -> List ( List (Node Pattern.Pattern), Node Expression ) -> Gen ( List Binder, Exp )
clauseCase ctx clauses =
    case clauses of
        [] ->
            fail "empty clause list"

        ( firstArgs, firstBody ) :: _ ->
            let
                n =
                    List.length firstArgs

                uniform =
                    List.all (\( args, _ ) -> List.length args == n) clauses

                range =
                    case firstArgs of
                        (Node r _) :: _ ->
                            r

                        [] ->
                            Node.range firstBody
            in
            if not uniform then
                fail "clauses have differing arity"

            else if n == 0 then
                -- A 0-arg multi-clause function synthesizes `(,)` — an empty
                -- tuple, which the source-level rule rejects.  (Reproduced
                -- here so the MIDTIER=1 error is the MIDTIER=0 error.)
                fail "empty tuple"

            else
                andThen
                    (\params ->
                        let
                            paramCtx =
                                withScope ctx params

                            scrutinee =
                                case params of
                                    [ only ] ->
                                        Var only.id

                                    _ ->
                                        Tup (List.map (\p -> Var p.id) params)

                            wrappedCases =
                                List.map
                                    (\( args, body ) -> ( wrapPattern n args range, body ))
                                    clauses
                        in
                        map (\caseExp -> ( params, caseExp ))
                            (buildCaseFrom paramCtx range wrappedCases scrutinee)
                    )
                    (freshBinders (List.map (\i -> "$arg" ++ String.fromInt i) (List.range 0 (n - 1))))


wrapPattern : Int -> List (Node Pattern.Pattern) -> Range -> Node Pattern.Pattern
wrapPattern n args range =
    case n of
        1 ->
            -- Single arg: the pattern directly (no tuple wrapper).
            List.head args |> Maybe.withDefault (Node range (VarPattern ""))

        _ ->
            Node range (TuplePattern args)



-- ============================ PATTERN COMPILER ============================
-- Mid.Ir.Match values instead of instruction lists; the ORDER of the tests and
-- of the bindings is identical to Lower.Pattern's (that order is what makes
-- the emitted tests byte-identical).


type alias MatchResult =
    { matches : List Match
    , binds : List ( String, ValuePath )
    }


caseMatches : Node Pattern.Pattern -> Result String MatchResult
caseMatches (Node _ pat) =
    goPattern pat []


emptyMatch : MatchResult
emptyMatch =
    { matches = [], binds = [] }


goPattern : Pattern.Pattern -> List Step -> Result String MatchResult
goPattern pat path =
    case pat of
        AllPattern ->
            Ok emptyMatch

        VarPattern name ->
            Ok { matches = [], binds = [ ( name, VPath path ) ] }

        UnitPattern ->
            Ok { matches = [ MLitEq path (LSymbol "()") ], binds = [] }

        CharPattern c ->
            Ok { matches = [ MLitEq path (LString (String.fromChar c)) ], binds = [] }

        StringPattern s ->
            Ok { matches = [ MLitEq path (LString s) ], binds = [] }

        IntPattern n ->
            Ok { matches = [ MLitEq path (LNumber n) ], binds = [] }

        HexPattern n ->
            Ok { matches = [ MLitEq path (LNumber n) ], binds = [] }

        FloatPattern _ ->
            Err "float patterns not supported"

        TuplePattern subs ->
            tupleMatch subs path

        UnConsPattern left right ->
            unConsMatch left right path

        ListPattern [] ->
            Ok { matches = [ MEmpty path ], binds = [] }

        ListPattern (p :: ps) ->
            listMatch (p :: ps) path

        NamedPattern qref subs ->
            namedMatch qref subs path

        AsPattern inner alias ->
            Result.map (\res -> { res | binds = res.binds ++ [ ( nodeString alias, VPath path ) ] })
                (goPattern (nodeValue inner) path)

        ParenthesizedPattern inner ->
            goPattern (nodeValue inner) path

        RecordPattern fields ->
            Ok
                { matches = []
                , binds = List.map (\f -> ( nodeString f, VField path (nodeString f) )) fields
                }


tupleMatch : List (Node Pattern.Pattern) -> List Step -> Result String MatchResult
tupleMatch subs path =
    case subs of
        [] ->
            Err "empty tuple pattern"

        [ _ ] ->
            Err "single-element tuple pattern"

        _ ->
            let
                n =
                    List.length subs
            in
            Result.map (\res -> { res | matches = MCons path :: res.matches })
                (recurseIndexed subs (\j -> path ++ List.repeat j SndStep ++ (if j < n - 1 then [ FstStep ] else [])))


unConsMatch : Node Pattern.Pattern -> Node Pattern.Pattern -> List Step -> Result String MatchResult
unConsMatch left right path =
    Result.map2
        (\lres rres ->
            { matches = MCons path :: (lres.matches ++ rres.matches)
            , binds = lres.binds ++ rres.binds
            }
        )
        (goPattern (nodeValue left) (path ++ [ HdStep ]))
        (goPattern (nodeValue right) (path ++ [ TlStep ]))


listMatch : List (Node Pattern.Pattern) -> List Step -> Result String MatchResult
listMatch elems path =
    let
        n =
            List.length elems

        consMatches =
            List.range 0 (n - 1)
                |> List.map (\j -> MCons (path ++ List.repeat j TlStep))

        emptyMatchTest =
            MEmpty (path ++ List.repeat n TlStep)
    in
    Result.map (\res -> { res | matches = consMatches ++ [ emptyMatchTest ] ++ res.matches })
        (recurseIndexed elems (\j -> path ++ List.repeat j TlStep ++ [ HdStep ]))


namedMatch : QualifiedNameRef -> List (Node Pattern.Pattern) -> List Step -> Result String MatchResult
namedMatch qref subs path =
    if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
        -- Bool patterns arrive as NamedPattern; they compare against the
        -- boolean atom, never the ADT vector tag.
        case subs of
            [] ->
                Ok { matches = [ MLitEq path (LBoolean (qref.name == "True")) ], binds = [] }

            _ ->
                Err "boolean pattern cannot have sub-patterns"

    else
        let
            -- The tag is the BARE ctor name (ctor defuns emit `Symbol <bare>`).
            tag =
                qref.name

            baseMatches =
                [ MVector path, MTagEq (path ++ [ IdxStep 0 ]) tag ]
        in
        Result.map (\res -> { res | matches = baseMatches ++ res.matches })
            (recurseIndexed subs (\j -> path ++ [ IdxStep (j + 1) ]))


recurseIndexed : List (Node Pattern.Pattern) -> (Int -> List Step) -> Result String MatchResult
recurseIndexed subs pathOf =
    recurseIndexedHelp 0 subs pathOf


recurseIndexedHelp : Int -> List (Node Pattern.Pattern) -> (Int -> List Step) -> Result String MatchResult
recurseIndexedHelp idx subs pathOf =
    case subs of
        [] ->
            Ok emptyMatch

        sub :: rest ->
            Result.map2 mergeResults
                (goPattern (nodeValue sub) (pathOf idx))
                (recurseIndexedHelp (idx + 1) rest pathOf)


mergeResults : MatchResult -> MatchResult -> MatchResult
mergeResults a b =
    { matches = a.matches ++ b.matches
    , binds = a.binds ++ b.binds
    }


-- Allocate one binder per pattern variable, in source order (so binding j sits
-- j slots above the scrutinee temp, which is the index the emitter reads it at).
bindPatternNames : List ( String, ValuePath ) -> Gen (List ( Binder, ValuePath ))
bindPatternNames pairs =
    case pairs of
        [] ->
            pure []

        ( name, path ) :: rest ->
            andThen
                (\binder -> map (\tail -> ( binder, path ) :: tail) (bindPatternNames rest))
                (freshBinder name)


-- ============================ RECORDS / LISTS / TUPLES ============================


recordExpr : Context -> List (Node Expression.RecordSetter) -> Gen Exp
recordExpr ctx setters =
    -- Lower.Expr folds over the setters in REVERSE source order (the assoc list
    -- is built right-to-left), which also fixes which setter's error is
    -- reported first; the IR stores them in SOURCE order and the emitter
    -- reverses again.
    map (\xs -> RecordLit (List.reverse xs)) (gatherSetters ctx (List.reverse setters) [])


gatherSetters : Context -> List (Node Expression.RecordSetter) -> List ( String, Exp ) -> Gen (List ( String, Exp ))
gatherSetters ctx setters acc =
    case setters of
        [] ->
            pure acc

        setter :: rest ->
            andThen (\pair -> gatherSetters ctx rest (acc ++ [ pair ])) (setterPair ctx setter)


setterPair : Context -> Node Expression.RecordSetter -> Gen ( String, Exp )
setterPair ctx (Node _ ( fieldNode, valNode )) =
    map (\value -> ( nodeString fieldNode, value )) (fromExpression ctx valNode)


recordAccess : Context -> Node Expression -> Node String -> Gen Exp
recordAccess ctx rec nameNode =
    map (\target -> RecordGet target (nodeString nameNode)) (fromExpression ctx rec)


recordAccessFunction : Context -> String -> Gen Exp
recordAccessFunction ctx name =
    -- `.x` arrives with a leading dot; record fields are interned BARE.  A
    -- 1-param closure: no leading grab (the first param is bound by APPLY).
    andThen
        (\param -> pure (Lam { params = [ param ], body = RecordGet (Var param.id) (String.dropLeft 1 name) }))
        (freshBinder "rec")


recordUpdate : Context -> Node String -> List (Node Expression.RecordSetter) -> Gen Exp
recordUpdate ctx baseNode updates =
    let
        baseName =
            nodeString baseNode
    in
    case resolveScope ctx baseName of
        Just id ->
            andThen (\pairs -> pure (RecordUpdate { base = Var id, updates = pairs }))
                (gatherSetters ctx updates [])

        Nothing ->
            fail ("record update base must be a local variable: " ++ baseName)


listExpr : Context -> List (Node Expression) -> Gen Exp
listExpr ctx es =
    -- buildList lowers the tail first (error priority: last element first) and
    -- emits right-to-left; the IR keeps SOURCE order.
    map (\xs -> ListLit (List.reverse xs)) (fromArgs ctx (List.reverse es))


tupledExpr : Context -> List (Node Expression) -> Gen Exp
tupledExpr ctx es =
    case es of
        [] ->
            fail "empty tuple"

        [ _ ] ->
            fail "single-element tuple"

        _ ->
            -- tupleCode lowers the tail first, like buildList.
            map (\xs -> Tup (List.reverse xs)) (fromArgs ctx (List.reverse es))



-- ============================ LABELS / PATTERN HELPERS ============================
-- label names never reach the output (Zinc.Emit renders Label_ as nothing);
-- what must match is the POSITION and the uniqueness of each label.


label : Range -> String -> String
label range tag =
    tag ++ "_" ++ String.fromInt range.start.row ++ "_" ++ String.fromInt range.start.column


labelIndex : Range -> String -> Int -> String
labelIndex range tag i =
    label range tag ++ "_" ++ String.fromInt i


isSimpleVarPattern : Node Pattern.Pattern -> Bool
isSimpleVarPattern (Node _ pat) =
    case pat of
        VarPattern _ ->
            True

        ParenthesizedPattern inner ->
            isSimpleVarPattern inner

        _ ->
            False


argNames : List (Node Pattern.Pattern) -> Result String (List String)
argNames nodes =
    case nodes of
        [] ->
            Ok []

        n :: rest ->
            Result.map2 (::) (patternName n) (argNames rest)


patternName : Node Pattern.Pattern -> Result String String
patternName (Node _ pat) =
    patName pat


patName : Pattern.Pattern -> Result String String
patName pat =
    case pat of
        VarPattern name ->
            Ok name

        ParenthesizedPattern (Node _ inner) ->
            patName inner

        _ ->
            Err "M1b supports only variable patterns in function arguments (pattern compiler is M2)"


nodeValue : Node a -> a
nodeValue (Node _ value) =
    value


nodeString : Node String -> String
nodeString (Node _ s) =
    s
