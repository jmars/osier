module Mid.Module exposing (Unit, parseAll, collectAll, mergedGlobals, compileUnit, sequenceMaps, collectTypeNames)

-- Mid.Module — the middle tier's ORCHESTRATION (sources -> Mid.Ir.Program).
--
-- Split (P8/P4): the ZINC-csexp OUTPUT half of this module — the batch
-- driver that ran the Simplify pass set over the programs and rendered them
-- to csexp — moved out when the surviving tree needed a backend-neutral
-- module here, and died with the format at P8.  What REMAINS is exactly the
-- orchestration every backend shares: parse, collect (with the loud
-- import-shadowing / ambiguous-import / duplicate-definition checks, in
-- order), the qualified global arity merge, and the per-unit lowering to
-- `Mid.Ir` via `Mid.FromAst`.  `Mid.QbeModule` (the QBE backend, the tree's
-- only backend since P8) builds on exactly these functions.
--
-- The corpus is parsed/typechecked/lowered ONCE and every group's program is
-- `corpusEntries ++ groupEntries`, so the emitted bytes are the same whether
-- the corpus was compiled in this process or in another.

import Dict exposing (Dict)
import Elm.Parser
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression, Function)
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range
import Elm.Syntax.Type as Type
import Lower.Expr as Expr
import Lower.Resolve as Resolve
import Mid.FromAst as FromAst
import Mid.Ir exposing (Defun, Exp(..), Program)



-- ================================ BATCH API ================================
-- No batch driver lives here anymore: the csexp one died with the format at
-- P8, and the QBE backend's driver is Mid.QbeModule.compileEntry, called
-- once per group by src/Main.elm (run.js) with the corpus paid for once.


-- ============================ PARSING / COLLECTION ============================


type alias Unit =
    { moduleName : List String
    , funs : List ( String, Function )
    , ctors : List ( String, Int )
    , file : File.File
    }


parseAll : List String -> Result String (List File.File)
parseAll sources =
    sequenceMaps (List.map parseOne sources)


parseOne : String -> Result String File.File
parseOne source =
    case Elm.Parser.parseToFile source of
        Ok file ->
            Ok file

        Err _ ->
            Err "parse failed"


collectAll : List File.File -> Result String (List Unit)
collectAll files =
    sequenceMaps (List.map collectUnit files)


collectUnit : File.File -> Result String Unit
collectUnit file =
    let
        modName =
            moduleNameOf file
    in
    collectFunctions file.declarations
        |> Result.andThen
            (\funs ->
                collectCtors file.declarations
                    |> Result.andThen
                        (\ctors ->
                            Resolve.checkImportShadowing
                                (List.map Tuple.first funs
                                    ++ List.map Tuple.first ctors
                                    ++ collectTypeNames file.declarations
                                )
                                file.imports
                                |> Result.andThen
                                    (\() -> Resolve.checkAmbiguousImports file.imports)
                                |> Result.map
                                    (\() ->
                                        { moduleName = modName
                                        , funs = funs
                                        , ctors = ctors
                                        , file = file
                                        }
                                    )
                        )
            )


mergedGlobals : List Unit -> Result String (Dict String Int)
mergedGlobals units =
    List.foldl mergeStep (Ok Dict.empty) units


mergeStep : Unit -> Result String (Dict String Int) -> Result String (Dict String Int)
mergeStep unit accResult =
    case accResult of
        Err msg ->
            Err msg

        Ok acc ->
            let
                locals =
                    List.map Tuple.first unit.funs ++ List.map Tuple.first unit.ctors
            in
            case findDuplicate locals of
                Just dup ->
                    Err
                        ("duplicate top-level definition in "
                            ++ String.join "." unit.moduleName
                            ++ ": "
                            ++ dup
                        )

                Nothing ->
                    let
                        fnsArity =
                            List.map (\( nm, fn ) -> ( nm, functionArity fn )) unit.funs

                        qualifiedPairs =
                            List.map (\( n, ar ) -> ( Resolve.qualify unit.moduleName n, ar ))
                                (fnsArity ++ unit.ctors)
                    in
                    Ok (List.foldl (\( k, v ) d -> Dict.insert k v d) acc qualifiedPairs)


sequenceMaps : List (Result String a) -> Result String (List a)
sequenceMaps results =
    List.foldr (Result.map2 (::)) (Ok []) results



-- ==================== DECLARATION COLLECTION ====================


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef


collectFunctions : List (Node Declaration.Declaration) -> Result String (List ( String, Function ))
collectFunctions decls =
    List.foldr collectOne (Ok []) decls


collectOne : Node Declaration.Declaration -> Result String (List ( String, Function )) -> Result String (List ( String, Function ))
collectOne node acc =
    case acc of
        Err msg ->
            Err msg

        Ok funs ->
            case asFunction node of
                Just f ->
                    Ok (f :: funs)

                Nothing ->
                    case forbiddenDecl node of
                        Just msg ->
                            Err msg

                        Nothing ->
                            Ok funs


collectCtors : List (Node Declaration.Declaration) -> Result String (List ( String, Int ))
collectCtors decls =
    List.foldr collectCtorOne (Ok []) decls


collectCtorOne : Node Declaration.Declaration -> Result String (List ( String, Int )) -> Result String (List ( String, Int ))
collectCtorOne node acc =
    case acc of
        Err msg ->
            Err msg

        Ok ctors ->
            case node of
                Node _ (CustomTypeDeclaration typeDecl) ->
                    Ok (List.foldl addCtor ctors typeDecl.constructors)

                _ ->
                    Ok ctors


addCtor : Node Type.ValueConstructor -> List ( String, Int ) -> List ( String, Int )
addCtor node acc =
    case node of
        Node _ vc ->
            ( nodeString vc.name, List.length vc.arguments ) :: acc


collectTypeNames : List (Node Declaration.Declaration) -> List String
collectTypeNames decls =
    List.filterMap typeName decls


typeName : Node Declaration.Declaration -> Maybe String
typeName (Node _ decl) =
    case decl of
        AliasDeclaration alias ->
            Just (nodeString alias.name)

        CustomTypeDeclaration typeDecl ->
            Just (nodeString typeDecl.name)

        _ ->
            Nothing


forbiddenDecl : Node Declaration.Declaration -> Maybe String
forbiddenDecl (Node _ decl) =
    case decl of
        Declaration.PortDeclaration _ ->
            Just "port declarations are not supported"

        Declaration.InfixDeclaration _ ->
            Just "infix declarations are not supported"

        _ ->
            Nothing


asFunction : Node Declaration.Declaration -> Maybe ( String, Function )
asFunction (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            case fn.declaration of
                Node _ impl ->
                    Just ( nodeString impl.name, fn )

        _ ->
            Nothing


findDuplicate : List String -> Maybe String
findDuplicate names =
    Tuple.second (List.foldl findDuplicateStep ( Dict.empty, Nothing ) names)


findDuplicateStep : String -> ( Dict String (), Maybe String ) -> ( Dict String (), Maybe String )
findDuplicateStep name ( seen, dup ) =
    case dup of
        Just _ ->
            ( seen, dup )

        Nothing ->
            if Dict.member name seen then
                ( seen, Just name )

            else
                ( Dict.insert name () seen, Nothing )


functionArity : Function -> Int
functionArity fn =
    case fn.declaration of
        Node _ impl ->
            List.length impl.arguments



-- ========================= UNIT COMPILATION =========================
-- One unit's Program: its function defuns, then its constructor defuns, then
-- the curried prim wrappers — the same order Lower.Module emits entries in.
--
-- (parseAll/collectAll/mergedGlobals/compileUnit are ALSO consumed by the
-- QBE native-backend driver Mid.QbeModule — exposed here so the native path
-- shares EXACTLY this orchestration.  Additive exposing only: no logic in
-- this module changed.)


compileUnit : Dict String Int -> Unit -> Result String (List Defun)
compileUnit globals unit =
    let
        modName =
            unit.moduleName

        definedNames =
            List.map Tuple.first unit.funs ++ List.map Tuple.first unit.ctors

        exported =
            Resolve.exportedNames unit.file.moduleDefinition definedNames

        aliasTable =
            Resolve.aliasTableFor modName exported unit.file.imports

        baseCtx =
            FromAst.newContext modName globals
                |> FromAst.withImport aliasTable
                |> FromAst.withModuleAliases (Resolve.moduleAliasTable unit.file.imports)
                |> FromAst.withOpenTypeModules (Resolve.openTypeModules unit.file.imports)
    in
    compileFuns baseCtx unit.funs
        |> Result.andThen
            (\fnDefuns ->
                sequenceMaps (List.map (\ctor -> FromAst.runGen (ctorDefun modName ctor)) unit.ctors)
                    |> Result.andThen
                        (\ctorDefuns ->
                            wrapperDefuns
                                |> Result.map (\wrapperDefs -> fnDefuns ++ ctorDefuns ++ wrapperDefs)
                        )
            )


compileFuns : FromAst.Context -> List ( String, Function ) -> Result String (List Defun)
compileFuns baseCtx funs =
    groupByName funs
        |> List.foldl (compileGroup baseCtx) (Ok [])


groupByName : List ( String, Function ) -> List ( String, List Function )
groupByName pairs =
    case pairs of
        [] ->
            []

        ( name, fn ) :: rest ->
            let
                ( same, others ) =
                    List.partition (\( n, _ ) -> n == name) rest
            in
            ( name, fn :: List.map Tuple.second same ) :: groupByName others


compileGroup : FromAst.Context -> ( String, List Function ) -> Result String (List Defun) -> Result String (List Defun)
compileGroup baseCtx ( name, funs ) accResult =
    case accResult of
        Err msg ->
            Err msg

        Ok acc ->
            case compileGroupOne baseCtx name funs of
                Err msg ->
                    Err msg

                Ok defun ->
                    Ok (acc ++ [ defun ])


compileGroupOne : FromAst.Context -> String -> List Function -> Result String Defun
compileGroupOne baseCtx name funs =
    case funs of
        [ single ] ->
            -- Fast path: single-clause, all-variable args.
            if allSimpleVarArgs single then
                compileOne baseCtx name single

            else
                desugarAndCompile baseCtx name funs

        _ ->
            desugarAndCompile baseCtx name funs


desugarAndCompile : FromAst.Context -> String -> List Function -> Result String Defun
desugarAndCompile baseCtx name funs =
    FromAst.runGen
        (FromAst.clauseCase baseCtx (List.map clauseOf funs)
            |> FromAst.andThen
                (\( params, caseExp ) ->
                    FromAst.pure
                        { key = Resolve.qualify baseCtx.moduleName name
                        , value = Lam { params = params, body = caseExp }
                        }
                )
        )


clauseOf : Function -> ( List (Node Pattern.Pattern), Node Expression )
clauseOf fn =
    case fn.declaration of
        Node _ impl ->
            ( impl.arguments, impl.expression )


compileOne : FromAst.Context -> String -> Function -> Result String Defun
compileOne baseCtx name fn =
    case fn.declaration of
        Node _ impl ->
            case FromAst.argNames impl.arguments of
                Err msg ->
                    Err msg

                Ok argNames ->
                    FromAst.runGen
                        (FromAst.freshBinders argNames
                            |> FromAst.andThen
                                (\params ->
                                    FromAst.fromExpression (FromAst.withScope baseCtx params) impl.expression
                                        |> FromAst.map
                                            (\body ->
                                                { key = Resolve.qualify baseCtx.moduleName name
                                                , value = Lam { params = params, body = body }
                                                }
                                            )
                                )
                        )


allSimpleVarArgs : Function -> Bool
allSimpleVarArgs fn =
    case fn.declaration of
        Node _ impl ->
            List.all isSimpleVarPattern impl.arguments


isSimpleVarPattern : Node Pattern.Pattern -> Bool
isSimpleVarPattern (Node _ pat) =
    case pat of
        VarPattern _ ->
            True

        ParenthesizedPattern inner ->
            isSimpleVarPattern inner

        _ ->
            False



-- ========================= CONSTRUCTOR / WRAPPER DEFUNS =========================
-- The three shapes `Lower.Module` emits as raw instruction lists, expressed as
-- Mid trees: a constructor defun builds the MX vector, a wrapper defun applies
-- a prim.  All are ordinary `Lam`s, so the emitter needs no special case for
-- them.


ctorDefun : List String -> ( String, Int ) -> FromAst.Gen Defun
ctorDefun modName ( name, n ) =
    FromAst.andThen
        (\params ->
            FromAst.pure
                { key = Resolve.qualify modName name
                , value =
                    Lam
                        { params = params
                        , body = Con { tag = name, args = List.map (\p -> Var p.id) params }
                        }
                }
        )
        (FromAst.freshBinders (List.map (\i -> "$arg" ++ String.fromInt i) (List.range 1 n)))


-- 2-arg curried wrapper: the body's args are in the prim's POP order, so the
-- emitter pushes param2 then param1 — the shape `Lower.Module.wrapperEntry`
-- writes by hand as `a[1:n]0 a[1:n]1 P<prim>`.
wrapperDefun : ( String, String ) -> FromAst.Gen Defun
wrapperDefun ( op, prim ) =
    let
        key =
            Expr.wrapperGlobalName (if op == "" then prim else op)
    in
    FromAst.andThen
        (\p1 ->
            FromAst.andThen
                (\p2 ->
                    FromAst.pure
                        { key = key
                        , value =
                            Lam
                                { params = [ p1, p2 ]
                                , body = PrimApp { prim = prim, args = [ Var p1.id, Var p2.id ] }
                                }
                        }
                )
                (FromAst.freshBinder "$p2")
        )
        (FromAst.freshBinder "$p1")


-- 1-arg wrapper: ZERO grabs (a lone `r` misbehaves on this VM — see
-- Lower.Module.unaryWrapperEntry), i.e. an arity-1 closure, and access 0 reads
-- back the pushed arg.
unaryWrapperDefun : String -> FromAst.Gen Defun
unaryWrapperDefun prim =
    FromAst.andThen
        (\p1 ->
            FromAst.pure
                { key = Expr.wrapperGlobalName prim
                , value =
                    Lam
                        { params = [ p1 ]
                        , body = PrimApp { prim = prim, args = [ Var p1.id ] }
                        }
                }
        )
        (FromAst.freshBinder "$p1")


-- 3-arg wrapper: two grabs; params in the prim's pop order.
ternaryWrapperDefun : String -> FromAst.Gen Defun
ternaryWrapperDefun prim =
    FromAst.andThen
        (\p1 ->
            FromAst.andThen
                (\p2 ->
                    FromAst.andThen
                        (\p3 ->
                            FromAst.pure
                                { key = Expr.wrapperGlobalName prim
                                , value =
                                    Lam
                                        { params = [ p1, p2, p3 ]
                                        , body = PrimApp { prim = prim, args = [ Var p1.id, Var p2.id, Var p3.id ] }
                                        }
                                }
                        )
                        (FromAst.freshBinder "$p3")
                )
                (FromAst.freshBinder "$p2")
        )
        (FromAst.freshBinder "$p1")


-- `substring` in String.sliceLen's SOURCE order (start len str), keyed
-- "substring.curried".  The prim pops (string, start, len), so the POP-order
-- arg list is [param3, param1, param2] — the permutation
-- `Lower.Module.substringWrapperEntry` writes by hand as
-- `a[1:n]1 a[1:n]2 a[1:n]0 P substring`.
substringWrapperDefun : FromAst.Gen Defun
substringWrapperDefun =
    FromAst.andThen
        (\p1 ->
            FromAst.andThen
                (\p2 ->
                    FromAst.andThen
                        (\p3 ->
                            FromAst.pure
                                { key = Expr.wrapperGlobalName "substring"
                                , value =
                                    Lam
                                        { params = [ p1, p2, p3 ]
                                        , body = PrimApp { prim = "substring", args = [ Var p3.id, Var p1.id, Var p2.id ] }
                                        }
                                }
                        )
                        (FromAst.freshBinder "$p3")
                )
                (FromAst.freshBinder "$p2")
        )
        (FromAst.freshBinder "$p1")


-- Every unit emits the same wrapper defuns (identical duplicates are harmless:
-- defunSet is later-store-wins with byte-identical bodies).
wrapperDefuns : Result String (List Defun)
wrapperDefuns =
    sequenceMaps
        (List.map (\w -> FromAst.runGen (wrapperDefun w)) Expr.primWrappers
            ++ List.map (\p -> FromAst.runGen (unaryWrapperDefun p)) Expr.unaryPrims
            ++ List.map (\p -> FromAst.runGen (ternaryWrapperDefun p)) Expr.ternaryPrims
            ++ [ FromAst.runGen substringWrapperDefun ]
        )


nodeString : Node String -> String
nodeString (Node _ s) =
    s
