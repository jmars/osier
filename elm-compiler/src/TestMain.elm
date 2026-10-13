port module TestMain exposing (main)

-- M1a unit-test harness for the emitter infrastructure.  NOT part of the
-- compiler (Main.elm stays the M0 parse driver).  Built separately with:
--
--   ELM_HOME=.elm-cache elm make src/TestMain.elm --output=test-compiler.js
--   node test-run.js
--
-- Every assertion prints a "PASS <name>" or "FAIL <name>" line over the
-- `report` port; test-run.js exits nonzero if any FAIL appears.

import Dict
import Elm.Parser
import Elm.Syntax.Declaration as Declaration
import Elm.Syntax.Expression as Expression
import Elm.Syntax.File as File
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Range as Range
import Platform
import Set
import Char.Extra exposing (utf8ByteLength)
import Mid.Audit as Audit
import Mid.Ir exposing (AltKind(..), Defun, Exp(..), LetBinder(..), Lit(..), UnsafeNode(..))
import Mid.Module as MidModule
import Mid.Qbe.Il as Il
import Mid.Qbe.Lower as QbeLower
import Mid.Qbe.Types as QbeTypes
import Mid.Rt as Rt
import Mid.RtGc as RtGc
import Type.Builtins as Builtins
import Type.Env as Env
import Type.Error as Error
import Type.Infer as Infer
import Type.Representation as Rep
import Type.Unify as Uni
import Lower.Resolve as Resolve
import Lower.Scope as Scope


port report : String -> Cmd msg


type Msg
    = Noop


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), runTests )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


runTests : Cmd Msg
runTests =
    report (String.join "\n" checks)


checks : List String
checks =
    [ check "utf8ByteLength 'héllo' == 6" (utf8ByteLength "héllo" == 6)
    , check "utf8ByteLength '🦀' == 4" (utf8ByteLength "🦀" == 4)
    , check "utf8ByteLength 'abcde' == 5" (utf8ByteLength "abcde" == 5)
    , check "utf8ByteLength '' == 0" (utf8ByteLength "" == 0)
    , check "scope innermost == 0" (Scope.resolve "x" (Scope.push "x" (Scope.push "y" Scope.empty)) == Just 0)
    , check "scope one out == 1" (Scope.resolve "y" (Scope.push "x" (Scope.push "y" Scope.empty)) == Just 1)
    , check "scope not found == Nothing" (Scope.resolve "z" (Scope.push "x" Scope.empty) == Nothing)
    , check "scope pop" (Scope.resolve "y" (Scope.pop (Scope.push "x" (Scope.push "y" Scope.empty))) == Just 0)
    -- Type.Representation pretty-printer: scoped rows render VERBATIM (duplicate
    -- labels are not collapsed), row tails show their variable, function types
    -- parenthesize their argument.
    , check "pretty scoped row keeps duplicate labels"
        (Rep.pretty (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "x", Rep.tBool ) ], tail = Rep.REmpty }) == "{x:Int, x:Bool}")
    , check "pretty row with tail"
        (Rep.pretty (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }) == "{x:Int| a}")
    , check "pretty function parenthesizes left"
        (Rep.pretty (Rep.TFun (Rep.TFun Rep.tInt Rep.tInt) Rep.tInt) == "(Int -> Int) -> Int")
    , check "pretty list of function"
        (Rep.pretty (Rep.tList (Rep.TFun Rep.tInt Rep.tString)) == "List (Int -> String)")
    , check "pretty shares variable names"
        (Rep.pretty (Rep.TFun (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone))) == "a -> a")

    -- Type.Representation substitution/zonk/occurs.
    , check "zonk replaces a type variable"
        (Rep.zonk (Rep.extend (Rep.var 0 Rep.KType Rep.FNone) Rep.tInt Rep.emptySubst) (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) == Rep.tInt)
    , check "zonkRow splices a bound row tail"
        (Rep.zonkRow
            (Rep.extend (Rep.var 1 Rep.KRow Rep.FNone)
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.REmpty })
                Rep.emptySubst
            )
            { fields = [ ( "y", Rep.tBool ) ], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }
            == { fields = [ ( "y", Rep.tBool ), ( "x", Rep.tInt ) ], tail = Rep.REmpty }
        )
    , check "occurs finds a variable through a function"
        (Rep.occurs (Rep.var 0 Rep.KType Rep.FNone) (Rep.TFun (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) Rep.tInt))
    , check "occurs absent"
        (not (Rep.occurs (Rep.var 0 Rep.KType Rep.FNone) Rep.tInt))
    , check "occurs finds a row variable through a tail"
        (Rep.occurs (Rep.var 1 Rep.KRow Rep.FNone) (Rep.TRecord { fields = [], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }))

    -- Type.Error: source ranges flow into the rendered message.
    , check "type error renders row:col"
        (Error.render
            (Error.atRange
                { start = { row = 3, column = 7 }, end = { row = 3, column = 9 } }
                "missing field x"
                "cannot unify Int with Bool"
            )
            == "type error at 3:7: missing field x\ncannot unify Int with Bool"
        )
    , check "type error renders without detail"
        (Error.render (Error.atRange { start = { row = 1, column = 1 }, end = { row = 1, column = 2 } } "bad type" "") == "type error at 1:1: bad type")

    -- Type.Unify: paper examples. {x:Int,y:Int} ~ {y:Int,x:Int} unify up to
    -- swap (empty substitution); duplicate-label rows are order-sensitive.
    , check "unify swaps distinct adjacent labels"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "y", Rep.tInt ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [ ( "y", Rep.tInt ), ( "x", Rep.tInt ) ], tail = Rep.REmpty })
         of
            Ok { subst } ->
                subst == Rep.emptySubst

            Err _ ->
                False
        )
    , check "duplicate labels are order-sensitive (scoped)"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "x", Rep.tBool ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [ ( "x", Rep.tBool ), ( "x", Rep.tInt ) ], tail = Rep.REmpty })
         of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "row-var instantiation freshens kinded vars"
        (let
            alpha =
                Rep.var 0 Rep.KRow Rep.FNone

            beta =
                Rep.var 1 Rep.KRow Rep.FNone

            left =
                Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar alpha }

            right =
                Rep.TRecord { fields = [ ( "y", Rep.tInt ) ], tail = Rep.RVar beta }

            state0 =
                { subst = Rep.emptySubst, fresh = 100, rigid = Set.empty, eqs = [] }
         in
         case Uni.unify state0 left right of
            Err _ ->
                False

            Ok state ->
                case Rep.lookup beta state.subst of
                    Just (Rep.TRecord bound) ->
                        case Rep.zonkRow state.subst bound of
                            { fields, tail } ->
                                (fields == [ ( "x", Rep.tInt ) ])
                                    && (case tail of
                                            Rep.RVar b ->
                                                b.kind == Rep.KRow && b.id /= alpha.id && b.id /= beta.id

                                            _ ->
                                                False
                                       )

                    _ ->
                        False
        )
    , check "common-tail rows do not loop (alpha /= tail guard)"
        (let
            alpha =
                Rep.var 0 Rep.KRow Rep.FNone

            left =
                Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar alpha }

            right =
                Rep.TRecord { fields = [ ( "y", Rep.tInt ) ], tail = Rep.RVar alpha }
         in
         case Uni.unify Uni.emptyState left right of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number + comparable merge to number"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber

            c =
                Rep.var 1 Rep.KType Rep.FComparable
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) (Rep.TVar c) of
            Ok state ->
                Rep.zonk state.subst (Rep.TVar c) == Rep.TVar n

            Err _ ->
                False
        )
    , check "number + appendable cross is an error"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber

            a =
                Rep.var 1 Rep.KType Rep.FAppendable
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) (Rep.TVar a) of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number cannot bind to Bool"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) Rep.tBool of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number binds to Int"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) Rep.tInt of
            Ok state ->
                Rep.zonk state.subst (Rep.TVar n) == Rep.tInt

            Err _ ->
                False
        )
    , check "comparable propagates through List"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            a =
                Rep.var 1 Rep.KType Rep.FNone
         in
         case Uni.unify { subst = Rep.emptySubst, fresh = 100, rigid = Set.empty, eqs = [] } (Rep.TVar c) (Rep.tList (Rep.TVar a)) of
            Ok state ->
                case Rep.zonk state.subst (Rep.TVar a) of
                    Rep.TVar za ->
                        za.flex == Rep.FComparable

                    _ ->
                        False

            Err _ ->
                False
        )
    , check "occurs check rejects infinite type"
        (let
            a =
                Rep.var 0 Rep.KType Rep.FNone
         in
         case Uni.unify Uni.emptyState (Rep.TVar a) (Rep.TFun (Rep.TVar a) Rep.tInt) of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "unify missing field reports the label"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [], tail = Rep.REmpty })
         of
            Err (Uni.MissingField "x") ->
                True

            _ ->
                False
        )

    -- Type.Env: instantiation, generalization (incl. flex markers), and
    -- collection from a parsed File.
    , check "env instantiate freshens ids and keeps comparable marker"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            scheme =
                { quantifiers = [ c ], body = Rep.TFun (Rep.TVar c) (Rep.TVar c), bound = [] }

            ( t, state ) =
                Env.instantiate scheme { subst = Rep.emptySubst, fresh = 100, rigid = Set.empty, eqs = [] }
         in
         case t of
            Rep.TFun (Rep.TVar v1) (Rep.TVar v2) ->
                (v1.id == 100)
                    && (v2.id == 100)
                    && (v1.flex == Rep.FComparable)
                    && (state.fresh == 101)

            _ ->
                False
        )
    , check "env generalize keeps comparable in the scheme (Dict.get-style)"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            v =
                Rep.var 1 Rep.KType Rep.FNone

            dictGet =
                Rep.TFun (Rep.TVar c)
                    (Rep.TFun (Rep.TCon "Dict.Dict" [ Rep.TVar c, Rep.TVar v ])
                        (Rep.TCon "Prelude.Maybe" [ Rep.TVar v ])
                    )

            scheme =
                Env.generalize dictGet
         in
         (List.length scheme.quantifiers == 2)
            && List.any (\q -> q.id == 0 && q.flex == Rep.FComparable) scheme.quantifiers
            && List.any (\q -> q.id == 1 && q.flex == Rep.FNone) scheme.quantifiers
        )
    , check "env let-generalization avoids rigid vars"
        (let
            x =
                Rep.var 0 Rep.KType Rep.FNone

            y =
                Rep.var 1 Rep.KType Rep.FNone

            scheme =
                Env.generalizeAvoiding [ x ] (Rep.TFun (Rep.TVar x) (Rep.TVar y))
         in
         List.map .id scheme.quantifiers == [ 1 ]
        )
    , check "env freeVars includes flex-marked vars"
        (Env.freeVars (Rep.TVar (Rep.var 0 Rep.KType Rep.FComparable)) == [ Rep.var 0 Rep.KType Rep.FComparable ])
    , check "env collects ctor and signature schemes"
        (case
            Elm.Parser.parseToFile
                "module Mini exposing (..)\n\ntype Wrap a = Wrap a\n\nid : a -> a\nid x =\n    x\n"
         of
            Ok file ->
                let
                    env =
                        Env.collectFile file
                in
                (case Env.lookupCtor "Mini.Wrap" env of
                    Just s ->
                        Rep.pretty s.body == "a -> Mini.Wrap a"

                    Nothing ->
                        False
                )
                    && (case Env.lookupValue "Mini.id" env of
                            Just s ->
                                Rep.pretty s.body == "a -> a"

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )

    -- Type.Builtins: operator schemes, prim-wrapper alias-row schemes, and
    -- the Record.remove / trusted-bodies surface.
    , check "builtin (+) is number -> number -> number"
        (case Builtins.operatorScheme "+" of
            Just s ->
                Rep.pretty s.body == "number -> number -> number"

            Nothing ->
                False
        )
    , check "builtin (//) is Int -> Int -> Int"
        (case Builtins.operatorScheme "//" of
            Just s ->
                Rep.pretty s.body == "Int -> Int -> Int"

            Nothing ->
                False
        )
    , check "builtin (/) is Float -> Float -> Float"
        (case Builtins.operatorScheme "/" of
            Just s ->
                Rep.pretty s.body == "Float -> Float -> Float"

            Nothing ->
                False
        )
    , check "builtin (<) is comparable -> comparable -> Bool"
        (case Builtins.operatorScheme "<" of
            Just s ->
                Rep.pretty s.body == "comparable -> comparable -> Bool"

            Nothing ->
                False
        )
    , check "builtin (++) is appendable -> appendable -> appendable"
        (case Builtins.operatorScheme "++" of
            Just s ->
                Rep.pretty s.body == "appendable -> appendable -> appendable"

            Nothing ->
                False
        )
    , check "builtin (::) is a -> List a -> List a"
        (case Builtins.operatorScheme "::" of
            Just s ->
                Rep.pretty s.body == "a -> List a -> List a"

            Nothing ->
                False
        )
    , check "builtin String.append is String -> String -> String"
        (case Builtins.lookupValue "String.append" of
            Just s ->
                Rep.pretty s.body == "String -> String -> String"

            Nothing ->
                False
        )
    , check "builtin Bitwise.and is Int -> Int -> Int"
        (case Builtins.lookupValue "Bitwise.and" of
            Just s ->
                Rep.pretty s.body == "Int -> Int -> Int"

            Nothing ->
                False
        )
    , check "builtin vectorGet is JsArray a -> Int -> a"
        (case Builtins.lookupValue "vectorGet" of
            Just s ->
                Rep.pretty s.body == "JsArray a -> Int -> a"

            Nothing ->
                False
        )
    , check "builtin intern is String -> String"
        (case Builtins.lookupValue "intern" of
            Just s ->
                Rep.pretty s.body == "String -> String"

            Nothing ->
                False
        )
    , check "builtin writeByte is Int -> Stream -> Int"
        (case Builtins.lookupValue "writeByte" of
            Just s ->
                Rep.pretty s.body == "Int -> Stream -> Int"

            Nothing ->
                False
        )
    , check "builtin strPrim is String -> String"
        (case Builtins.lookupValue "strPrim" of
            Just s ->
                Rep.pretty s.body == "String -> String"

            Nothing ->
                False
        )
    , check "builtin removeFieldImpl is String -> a -> b"
        (case Builtins.lookupValue "Prelude.removeFieldImpl" of
            Just s ->
                Rep.pretty s.body == "String -> a -> b"

            Nothing ->
                False
        )
    , check "Record.remove surface name"
        (Builtins.recordRemove == "Record.remove")
    , check "Record.remove rewrites to removeFieldImpl"
        (Builtins.recordRemoveImpl == "Prelude.removeFieldImpl")
    , check "removeFieldImpl is a trusted body"
        (Builtins.isTrusted "Prelude.removeFieldImpl")
    , check "map is not a trusted body"
        (not (Builtins.isTrusted "Prelude.map"))
    , check "every prim-wrapper alias row has a builtin scheme"
        (Builtins.uncoveredPrimRows == [])
    , check "36 prim-wrapper schemes registered"
        (Dict.size Builtins.primWrapperSchemes == 36)

    -- Type.Infer: Algorithm W over expressions/patterns, record operations,
    -- let-generalization, top-level group, and the ++/Record.remove rewrites.
    , check "infer ++ zonks to String.append"
        (case inferSrc "module Main exposing (..)\n\nf x =\n    x ++ \"!\"\n" of
            Ok unit ->
                (prettyScheme "Main.f" unit == "String -> String")
                    && (case bodyOf "f" unit.file of
                            Just e ->
                                isAppendCall "String.append" e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer ++ zonks to List.append"
        (case inferSrc "module Main exposing (..)\n\ng x =\n    x ++ [1]\n" of
            Ok unit ->
                (prettyScheme "Main.g" unit == "List number -> List number")
                    && (case bodyOf "g" unit.file of
                            Just e ->
                                isAppendCall "List.append" e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer ambiguous (++) errors"
        (case inferSrc "module Main exposing (..)\n\nh x =\n    x ++ x\n" of
            Err err ->
                String.contains "ambiguous" err.summary

            Ok _ ->
                False
        )
    , check "infer arity error (applying a non-function)"
        (case inferSrc "module Main exposing (..)\n\nmain =\n    5 3\n" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    , check "import shadowing rejected (bare exposing row vs local def)"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (update)\n\nupdate = 1\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkImportShadowing [ "update", "main" ] file.imports
                    == Err "the name `update` is both a top-level definition and imported via `exposing` from B; remove it from the import's exposing list (real Elm rejects this)"

            Err _ ->
                False
        )
    , check "import shadowing allows clean explicit imports"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (update)\n\nhelper = 2\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkImportShadowing [ "helper", "main" ] file.imports == Ok ()

            Err _ ->
                False
        )

    -- TYPE-name half of the shadowing check: type aliases + ADT names join
    -- funs+ctors in the clash check (types are a separate namespace from
    -- values, so findDuplicate stays funs+ctors only).
    , check "collectTypeNames gathers alias + ADT names (skips funs/ctors)"
        (case Elm.Parser.parseToFile "module A exposing (main)\n\ntype alias Model = { n : Int }\n\ntype Msg = Inc | Dec\n\nhelper = 1\n\nmain = 0\n" of
            Ok file ->
                MidModule.collectTypeNames file.declarations == [ "Model", "Msg" ]

            Err _ ->
                False
        )
    , check "type-alias shadowing rejected (bare exposing row vs local type)"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (Model)\n\ntype alias Model = { n : Int }\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkImportShadowing (MidModule.collectTypeNames file.declarations) file.imports
                    == Err "the name `Model` is both a top-level definition and imported via `exposing` from B; remove it from the import's exposing list (real Elm rejects this)"

            Err _ ->
                False
        )
    -- AMBIGUOUS imports: the same bare name exposed by two different modules
    -- (first-match-wins used to silently pick one).
    , check "ambiguous imports rejected (same bare name from two modules)"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (foo)\nimport C exposing (foo)\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkAmbiguousImports file.imports
                    == Err "the name `foo` is imported via `exposing` from two different modules: B and C; qualify it at use sites (real Elm rejects ambiguous imports)"

            Err _ ->
                False
        )
    , check "ambiguous imports allow distinct names + same-module repeats"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (foo)\nimport B exposing (foo)\nimport C exposing (bar)\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkAmbiguousImports file.imports == Ok ()

            Err _ ->
                False
        )
    , check "infer let-generalizes (id used at Bool and String)"
        (case inferSrc "module Main exposing (..)\n\nmain =\n    let\n        id x =\n            x\n    in\n    ( id True, id \"a\" )\n" of
            Ok unit ->
                prettyScheme "Main.main" unit == "(Bool, String)"

            Err _ ->
                False
        )
    , check "infer top-level group is order-independent"
        (case inferSrc "module Main exposing (..)\n\nf =\n    g 1\n\ng x =\n    x\n" of
            Ok unit ->
                (prettyScheme "Main.f" unit == "number")
                    && (prettyScheme "Main.g" unit == "a -> a")

            Err _ ->
                False
        )
    , check "infer record ops: duplicate-label shadow + remove"
        (case inferSrc "module Main exposing (..)\n\na =\n    { x = 1, x = True }\n\nb =\n    a.x\n\nc =\n    Record.remove \"x\" a\n\nd =\n    c.x\n" of
            Ok unit ->
                (prettyScheme "Main.a" unit == "{x:number, x:Bool}")
                    && (prettyScheme "Main.b" unit == "number")
                    && (prettyScheme "Main.c" unit == "{x:Bool}")
                    && (prettyScheme "Main.d" unit == "Bool")
                    && (case bodyOf "c" unit.file of
                            Just e ->
                                isRemoveCall e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer insertion is free extension (may duplicate)"
        (case inferSrc "module Main exposing (..)\n\nins r =\n    { r | x <- 1 }\n" of
            Ok unit ->
                (prettyScheme "Main.ins" unit == "{| a} -> {x:number| a}")
                    && (case bodyOf "ins" unit.file of
                            Just (Expression.RecordUpdateExpression _ setters) ->
                                case setters of
                                    Node _ ( _, Node _ (Expression.Integer 1) ) :: [] ->
                                        True

                                    _ ->
                                        False

                            _ ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer update of a missing field errors"
        (case inferSrc "module Main exposing (..)\n\nf : { y : Int } -> { y : Int }\nf p =\n    { p | x = 1 }\n" of
            Err err ->
                String.contains "does not have field x" err.summary

            Ok _ ->
                False
        )
    , check "infer update keeps an existing field"
        (case inferSrc "module Main exposing (..)\n\nf : { x : Int } -> { x : Int }\nf p =\n    { p | x = 2 }\n" of
            Ok unit ->
                prettyScheme "Main.f" unit == "{x:Int} -> {x:Int}"

            Err _ ->
                False
        )
    , check "infer apply non-function diagnostic"
        (case inferSrc "module Main exposing (..)\n\nanswer : Int -> Int\nanswer x =\n    x + 1\n\nmain =\n    answer 1 2\n" of
            Err err ->
                String.contains "apply non-function" err.summary

            Ok _ ->
                False
        )
    , check "env expands a row-generic type alias (Named {age:Int})"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Named r = { name : String | r }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Named" [ Rep.TRecord { fields = [ ( "age", Rep.tInt ) ], tail = Rep.REmpty } ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{name:String, age:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env expands a type-generic type alias (Box Int)"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Box a = { value : a }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Box" [ Rep.tInt ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{value:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env expands a zero-generic alias applied to zero args"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Point = { x : Int, y : Int }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file
                in
                case Env.expandAliases env (Rep.TCon "Mini.Point" []) Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{x:Int, y:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env alias arity error on too many arguments"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Box a = { value : a }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Box" [ Rep.tInt, Rep.tBool ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Err msg ->
                        String.contains "expects 1 type argument but got 2" msg

                    Ok _ ->
                        False

            Err _ ->
                False
        )
    , check "infer rejects an unsaturated type-alias application"
        (case inferSrc "module Main exposing (..)\n\ntype alias Named r = { name : String | r }\n\nf : Named -> String\nf p =\n    p.name\n" of
            Err err ->
                String.contains "type alias Main.Named expects 1 type argument but got 0" err.summary

            Ok _ ->
                False
        )
    , check "alias sentinels never leak across call sites (two concrete rows)"
        (case inferSrc "module Main exposing (..)\n\ntype alias Named r = { name : String | r }\n\ngetName : Named r -> String\ngetName p =\n    p.name\n\na =\n    getName { name = \"a\", age = 1 }\n\nb =\n    getName { name = \"b\", foo = \"c\" }\n" of
            Ok unit ->
                (prettyScheme "Main.a" unit == "String")
                    && (prettyScheme "Main.b" unit == "String")

            Err err ->
                False
        )
    , check "Record.remove as a value gives a clear diagnostic"
        (case inferSrc "module Main exposing (..)\n\nf =\n    Record.remove \"x\"\n" of
            Err err ->
                String.contains "Record.remove must be fully applied" err.summary

            Ok _ ->
                False
        )

    -- Signature soundness: FNone-quantified signature variables are
    -- SKOLEMIZED while the body is checked, so a body cannot specialize them
    -- (the pre-fix hole compiled `f : a -> a / f x = "hello"` silently).
    , check "skolem: f : a -> a / f x = x passes"
        (inferPasses "module Main exposing (..)\n\nf : a -> a\nf x =\n    x\n")
    , check "skolem: f : a -> a / f x = \"hello\" fails"
        (not (inferPasses "module Main exposing (..)\n\nf : a -> a\nf x =\n    \"hello\"\n"))
    , check "skolem: f : a -> a / f x = x + 1 fails"
        (not (inferPasses "module Main exposing (..)\n\nf : a -> a\nf x =\n    x + 1\n"))
    , check "skolem: f : a -> a / f x = x < x fails"
        (not (inferPasses "module Main exposing (..)\n\nf : a -> a\nf x =\n    x < x\n"))
    , check "skolem: f : a -> b -> a / f x y = x passes"
        (inferPasses "module Main exposing (..)\n\nf : a -> b -> a\nf x y =\n    x\n")
    , check "skolem: f : a -> b -> a / f x y = y fails"
        (not (inferPasses "module Main exposing (..)\n\nf : a -> b -> a\nf x y =\n    y\n"))
    , check "skolem: f : (a -> a) -> a -> a / f g x = g x passes"
        (inferPasses "module Main exposing (..)\n\nf : (a -> a) -> a -> a\nf g x =\n    g x\n")
    , check "skolem: f : (a -> a) -> a -> a / f g x = g 1 fails"
        (not (inferPasses "module Main exposing (..)\n\nf : (a -> a) -> a -> a\nf g x =\n    g 1\n"))
    , check "skolem: f : List a -> List a / f xs = xs passes"
        (inferPasses "module Main exposing (..)\n\nf : List a -> List a\nf xs =\n    xs\n")
    , check "skolem: f : List a -> a / f xs = 1 fails"
        (not (inferPasses "module Main exposing (..)\n\nf : List a -> a\nf xs =\n    1\n"))
    , check "skolem: f : a -> List a / f x = [ \"s\" ] fails"
        (not (inferPasses "module Main exposing (..)\n\nf : a -> List a\nf x =\n    [ \"s\" ]\n"))

    -- Flex-marker regressions: `number`/`comparable` quantifiers stay FLEX
    -- (not skolemized), so constrained-super signatures still check. The
    -- plan's `List.foldl (+) 0 xs` spelling is NOT available to a
    -- self-contained `inferSrc` module (it aliases `Prelude.foldl`, which is
    -- only in the merged env), so `sum` is recursive and `min` uses `<` —
    -- both exercise the same flex markers.
    , check "skolem: number-signatured function still checks (flex marker)"
        (inferPasses "module Main exposing (..)\n\nsum : List number -> number\nsum xs =\n    case xs of\n        [] ->\n            0\n\n        x :: rest ->\n            x + sum rest\n")
    , check "skolem: comparable-signatured function that compares still checks"
        (inferPasses "module Main exposing (..)\n\nmin : comparable -> comparable -> comparable\nmin a b =\n    if a < b then\n        a\n\n    else\n        b\n")

    -- KRow skolems: a signature's row variable cannot be specialized (bound to
    -- a closed row or extended) by the body — the row analogue of the FNone fix.
    , check "skolem: row var must not collapse to a closed row (f r = { x = 1 })"
        (not (inferPasses "module Main exposing (..)\n\nf : { a | x : Int } -> { a | x : Int }\nf r =\n    { x = 1 }\n"))
    , check "skolem: reading a field of an open row passes"
        (inferPasses "module Main exposing (..)\n\nf : { a | x : Int } -> Int\nf r =\n    r.x\n")
    , check "skolem: record update preserves the open row passes"
        (inferPasses "module Main exposing (..)\n\nf : { a | x : Int } -> { a | x : Int }\nf r =\n    { r | x = 1 }\n")

    -- Mid.Audit (osier-rawnodes): THE INVARIANT'S MUST-FAIL SEAT.  A violating
    -- tree is NOT producible from surface code by construction (surface code
    -- cannot name an Rt.* defun; and `rg -c 'Unsafe|Raw' FromAst.elm == 0` is
    -- a qbe-check row), so the fixture builds the exact tree a FROMAST BUG
    -- would leave behind — an Unsafe node under a non-Rt key — and the audit
    -- must reject it.  If this row ever stops failing-on-violation, the
    -- invariant's load-bearing seat is gone.
    , check "audit REJECTS an Unsafe node under a non-Rt key (must-fail)"
        (Audit.run auditViolating
            == Err "qbe: unsafe node (withRoots) reached key Main.main — unsafe nodes are legal only inside Rt.* runtime defuns (front end must never emit one; Mid.Audit)"
        )
    , check "audit rejects a NESTED Unsafe node (walker descends)"
        (Result.toMaybe (Audit.run auditNested) == Nothing)
    , check "audit names the offending node kind (raw call)"
        (case Audit.run auditRawCall of
            Err msg ->
                String.contains "raw call rt_cons" msg

            Ok _ ->
                False
        )
    , check "audit ALLOWS the same node under an Rt.* key (the legal seat)"
        (Audit.run [ { key = "Rt.cons", value = auditBody } ]
            == Ok [ { key = "Rt.cons", value = auditBody } ]
        )
    , check "audit passes a clean program through UNCHANGED (inertness)"
        (Audit.run auditClean == Ok auditClean)

    -- Mid.Rt / the raw lowering (osier-consspike): the seats this step
    -- added, each with a must-fail twin.  The Rt program is the runtime's
    -- Mid-side entry; the census seeds and the register-class checks are
    -- what keep "one prim end-to-end" honest.
    , check "rt program: 85 defuns, all Rt.*; cons 2-ary, substring 3-ary, con 3-ary, open 2-ary (E added the record walk/rebuild defuns; stage 5 added the ADT constructor and the closure; stage 3 GROUP 1 added the fd prims write-byte/read-byte/open/close + readFull/cStrFill; stage 3 GROUP 2 added intern/value/str + floatCopy)"
        (List.length (Rt.program True True True) == 85
            && List.all (\d -> String.startsWith "Rt." d.key) (Rt.program True True True)
            && List.any
                (\d ->
                    d.key == "Rt.cons"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 2

                                _ ->
                                    False
                           )
                )
                (Rt.program True True True)
            && List.any
                (\d ->
                    d.key == "Rt.substring"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 3

                                _ ->
                                    False
                           )
                )
                (Rt.program True True True)
            && List.any
                (\d ->
                    d.key == "Rt.con"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 3

                                _ ->
                                    False
                           )
                )
                (Rt.program True True True)
            && List.any
                (\d ->
                    d.key == "Rt.open"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 2

                                _ ->
                                    False
                           )
                )
                (Rt.program True True True)
        )
    , check "rt seeds closure: cons/=/+ pull the 8-key deepEq closure; + alone pulls just Rt.+"
        (Rt.seeds (Set.fromList [ "cons", "+", "=" ])
            == [ "Rt.+", "Rt.asF", "Rt.=", "Rt.deepEq", "Rt.bytesEqGo", "Rt.symEq", "Rt.vecEq", "Rt.cons" ]
            && Rt.seeds (Set.fromList [ "+" ]) == [ "Rt.+", "Rt.asF" ]
        )
    , check "rt call graph: every RawCall target is a program key AND declared in rtDeps (the seed-closure skew must-fail)"
        (let
            syms key =
                case List.filter (\d -> d.key == key) (Rt.program True True True) of
                    d :: _ ->
                        rawCallSyms d.value

                    [] ->
                        []

            allKeys =
                List.map .key (Rt.program True True True)

            ok key =
                List.all (\sym -> List.member sym allKeys && List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps)))
                    (syms key)
         in
         List.all ok allKeys
        )
    , check "rt cons lowers to a QBE function named q_Rt_x2econs"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True True) "Rt.cons" of
            Ok mod ->
                List.any (\f -> f.name == "q_Rt_x2econs") mod.funcs

            Err _ ->
                False
        )
    , check "rt lowering REJECTS a raw-word binder read in a value position (must-fail)"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty [ rtRawBinderMisuse ] "Rt.bad" of
            Err msg ->
                String.contains "raw word binder" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a word node in a value position (must-fail)"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty [ rtWordInValuePosition ] "Rt.bad2" of
            Err msg ->
                String.contains "value position" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a value binder in a raw-argument position (must-fail)"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty [ rtValueInRawPosition ] "Rt.bad3" of
            Err msg ->
                String.contains "not a raw word" msg

            Ok _ ->
                False
        )

    -- THE LEAN ABI (osier-midabi).  The classification is the soundness
    -- fact (a frame-free callee must never reach a safepoint); pin BOTH
    -- sides of the partition so a new RtPrims body or node form that moves a
    -- defun across it fails HERE, not at a churn fixture.
    , check "rt allocation classification: the pure-read defuns are frame-free, the builders are framed"
        (Set.member "Rt.cons" Rt.allocating
            && Set.member "Rt.@p" Rt.allocating
            && Set.member "Rt.con" Rt.allocating
            && Set.member "Rt.closure" Rt.allocating
            && Set.member "Rt.cn" Rt.allocating
            && Set.member "Rt.repeat" Rt.allocating
            && Set.member "Rt.substring" Rt.allocating
            && Set.member "Rt.strOf" Rt.allocating
            && Set.member "Rt.str" Rt.allocating
            && Set.member "Rt.shen.bytes->string" Rt.allocating
            && Set.member "Rt.absvector" Rt.allocating
            && not (Set.member "Rt.=" Rt.allocating)
            && not (Set.member "Rt.+" Rt.allocating)
            && not (Set.member "Rt.<" Rt.allocating)
            && not (Set.member "Rt.deepEq" Rt.allocating)
            && not (Set.member "Rt.bytesEqGo" Rt.allocating)
            && not (Set.member "Rt.symEq" Rt.allocating)
            && not (Set.member "Rt.vecEq" Rt.allocating)
            && not (Set.member "Rt.asF" Rt.allocating)
            && not (Set.member "Rt.toI32" Rt.allocating)
            && not (Set.member "Rt.assoc" Rt.allocating)
            && not (Set.member "Rt.assocGo" Rt.allocating)
            && not (Set.member "Rt.address->" Rt.allocating)
            && not (Set.member "Rt.countL" Rt.allocating)
            && not (Set.member "Rt.conFill" Rt.allocating)
            && not (Set.member "Rt.closureFill" Rt.allocating)
            && not (Set.member "Rt.intern" Rt.allocating)
            && not (Set.member "Rt.value" Rt.allocating)
            && not (Set.member "Rt.floatCopy" Rt.allocating)
        )
    , check "rt gc (midgc) classification: the collector is FRAME-FREE by construction (a frame-free callee must never reach a safepoint)"
        (not (Set.member "Rt.collect" Rt.allocating)
            && not (Set.member "Rt.allocVector" Rt.allocating)
            && not (Set.member "Rt.allocRaw" Rt.allocating)
            && not (Set.member "Rt.gcMarkPtr" Rt.allocating)
            && not (Set.member "Rt.gcMarkValue" Rt.allocating)
            && not (Set.member "Rt.gcMarkRoots" Rt.allocating)
            && not (Set.member "Rt.gcDrain" Rt.allocating)
            && not (Set.member "Rt.gcSweep" Rt.allocating)
            && not (Set.member "Rt.gcAlloc" Rt.allocating)
            && not (Set.member "Rt.gcAllocGo" Rt.allocating)
            && not (Set.member "Rt.gcScanValueArray" Rt.allocating)
            && not (Set.member "Rt.gcInit" Rt.allocating)
        )
    , check "rt gc call graph: every RawCall target in the collector is a program key AND declared in rtDeps"
        (let
            gcSyms key =
                case List.filter (\d -> d.key == key) RtGc.gcProgram of
                    d :: _ ->
                        rawCallSyms d.value

                    [] ->
                        []

            gcKeys =
                List.map .key RtGc.gcProgram

            ok key =
                List.all (\sym -> List.member sym gcKeys && List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps)))
                    (gcSyms key)
         in
         List.all ok gcKeys
        )
    , check "rt gc seeds: the collector seeds are exactly the two seats plus their transitive closure"
        (Rt.gcSeeds
            == [ "Rt.allocVector", "Rt.gcInit", "Rt.gcAlloc", "Rt.gcAllocGo", "Rt.collect", "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkValue", "Rt.gcMarkPtr", "Rt.gcDrain", "Rt.gcSweep", "Rt.allocRaw" ]
        )
    , check "rt con seeds: the Mid ADT constructor and its fill helper"
        (Rt.conSeeds == [ "Rt.con", "Rt.conFill" ]
        )
    , check "rt closure seeds: the Mid closure and its 0-based fill helper"
        (Rt.closureSeeds == [ "Rt.closure", "Rt.closureFill" ]
        )
    , check "rt lean ABI: a frame-free callee has pointer params, :val return and NO frame enter/leave"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True True) "Rt.+" of
            Ok mod ->
                case List.filter (\f -> f.name == "q_Rt_x2e_x2b") mod.funcs of
                    f :: _ ->
                        List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L, Il.Base Il.W ]
                            && f.ret == Il.Agg "val"
                            && not (callsSym "rt_frame_enter" f)
                            && not (callsSym "rt_frame_leave" f)
                            && frameBaseIsAlloc f

                    [] ->
                        False

            Err _ ->
                False
        )
    , check "rt lean ABI: a framing callee (cons) keeps rt_frame_enter/leave and the lean signature"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True True) "Rt.cons" of
            Ok mod ->
                case List.filter (\f -> f.name == "q_Rt_x2econs") mod.funcs of
                    f :: _ ->
                        List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L, Il.Base Il.W ]
                            && f.ret == Il.Agg "val"
                            && callsSym "rt_frame_enter" f
                            && callsSym "rt_frame_leave" f

                    [] ->
                        False

            Err _ ->
                False
        )
    , check "rt lean ABI: rt_bounce appears NOWHERE in a lean emit, and the fat hatch restores it"
        (case QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True True) "Rt.+" of
            Ok mod ->
                not (List.any (callsSym "rt_bounce") mod.funcs)

            Err _ ->
                False
        )
    -- THE = SYMBOL FAST PATH (stage-3 zigretire): the pointer-identity
    -- short-circuit must be emitted as an OR over a byte-walk fallback, never
    -- a replacement.  Structural pin (the BEHAVIOURAL pin is the gate's
    -- symeq.elm): (a) the fast-path emit keeps the symEq fallback reachable
    -- (a pointer-only regression would drop it), and (b) the hatch emit
    -- differs from it (a deleted fast path would make them identical).
    , check "rt = symbol fast path: emitted as a pointer short-circuit that KEEPS the symEq fallback, and the hatch removes it"
        (case ( QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True True) "Rt.="
              , QbeLower.lower False False False True True True True False QbeTypes.empty Dict.empty (Rt.program True True False) "Rt.="
              ) of
            ( Ok onMod, Ok offMod ) ->
                case ( funcByName "q_Rt_x2e_x3d" onMod, funcByName "q_Rt_x2e_x3d" offMod ) of
                    ( Just onF, Just offF ) ->
                        callsSym "q_Rt_x2esymEq" onF
                            && callsSym "q_Rt_x2esymEq" offF
                            && onF.blocks /= offF.blocks

                    _ ->
                        False

            _ ->
                False
        )
    ]


-- The tree a FromAst bug would leave: a defun whose body carries a raw
-- rooting form and a raw call — exactly the `cons` shape step 4 will build
-- LEGALLY under Rt.*.
auditBody : Exp
auditBody =
    Lam
        { params = [ { id = 0, name = "hd" }, { id = 1, name = "tl" } ]
        , body =
            Unsafe
                (WithRoots
                    { binders = [ { id = 0, name = "hd" }, { id = 1, name = "tl" } ]
                    , body = Unsafe (RawCall { sym = "rt_cons", args = [ Var 0, Var 1 ] })
                    }
                )
        }


auditViolating : List Defun
auditViolating =
    [ { key = "Main.main", value = auditBody } ]


auditRawCall : List Defun
auditRawCall =
    [ { key = "Prelude.map"
      , value = Lam { params = [], body = Unsafe (RawCall { sym = "rt_cons", args = [] }) }
      }
    ]


auditNested : List Defun
auditNested =
    [ { key = "Main.main"
      , value =
            Lam
                { params = []
                , body =
                    Let
                        { binders =
                            [ LetBind { binder = { id = 7, name = "x" }, value = Lit (LNumber 3) } ]
                        , body =
                            Case
                                { scrutinee = Var 7
                                , scrutId = { id = 8, name = "$case" }
                                , alts =
                                    [ { kind = AltOther
                                      , matches = []
                                      , binds = []
                                      , body = Unsafe (RawTagOf (Var 8))
                                      , nextLabel = "$alt1"
                                      }
                                    ]
                                , endLabel = "$end"
                                }
                        }
                }
      }
    ]


auditClean : List Defun
auditClean =
    [ { key = "Prelude.id"
      , value = Lam { params = [ { id = 0, name = "x" } ], body = Var 0 }
      }
    , { key = "Main.main"
      , value =
            Lam
                { params = []
                , body =
                    App
                        { fn = GRef { key = "Prelude.id", force = False }
                        , args = [ Lit (LNumber 42) ]
                        }
                }
      }
    ]


check : String -> Bool -> String
check name ok =
    if ok then
        "PASS " ++ name

    else
        "FAIL " ++ name


-- ======================= Type.Infer helpers =======================

inferSrc : String -> Result Error.TypeError Infer.CheckedUnit
inferSrc src =
    case Elm.Parser.parseToFile src of
        Ok file ->
            Infer.inferUnit (Env.collectFile file) file

        Err _ ->
            Err (Error.atRange Range.empty "parse failed" "")


{-| Does a complete module typecheck against its own signatures?
-}
inferPasses : String -> Bool
inferPasses src =
    case inferSrc src of
        Ok _ ->
            True

        Err _ ->
            False


schemeFor : String -> Infer.CheckedUnit -> Maybe Env.Scheme
schemeFor qname unit =
    case List.filter (\( n, _ ) -> n == qname) unit.schemes of
        ( _, s ) :: _ ->
            Just s

        [] ->
            Nothing


prettyScheme : String -> Infer.CheckedUnit -> String
prettyScheme qname unit =
    case schemeFor qname unit of
        Just s ->
            Rep.pretty s.body

        Nothing ->
            "<missing>"


bodyOf : String -> File.File -> Maybe Expression.Expression
bodyOf name file =
    List.filterMap
        (\nd ->
            case Node.value nd of
                Declaration.FunctionDeclaration fn ->
                    case Node.value fn.declaration of
                        impl ->
                            if Node.value impl.name == name then
                                Just (Node.value impl.expression)

                            else
                                Nothing

                _ ->
                    Nothing
        )
        file.declarations
        |> List.head


isAppendCall : String -> Expression.Expression -> Bool
isAppendCall fnName expr =
    case expr of
        Expression.Application nodes ->
            case nodes of
                Node _ (Expression.FunctionOrValue [] n) :: _ ->
                    n == fnName

                _ ->
                    False

        _ ->
            False


isRemoveCall : Expression.Expression -> Bool
isRemoveCall expr =
    case expr of
        Expression.Application nodes ->
            case nodes of
                Node _ (Expression.FunctionOrValue [ "Prelude" ] "removeFieldImpl") :: _ ->
                    True

                _ ->
                    False

        _ ->
            False


-- The register-class misuse trees (osier-consspike must-fail rows): each is
-- a WELL-FORMED Mid tree under a legal Rt.* key — the audit lets all three
-- through by design (they are Rt-internal), and the LOWERING is the seat
-- that must refuse them.  Built exactly as a Mid.RtPrims bug would leave
-- them.

rtRawBinderMisuse : Defun
rtRawBinderMisuse =
    { key = "Rt.bad"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "pair" }
                            , value = Unsafe (RawAllocVector (Lit (LNumber 2)))
                            }
                        ]
                    , body = Var 1
                    }
            }
    }


rtWordInValuePosition : Defun
rtWordInValuePosition =
    { key = "Rt.bad2"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body = Unsafe (RawAllocVector (Lit (LNumber 2)))
            }
    }


rtValueInRawPosition : Defun
rtValueInRawPosition =
    { key = "Rt.bad3"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Unsafe
                    (RawMkValue
                        { tag = 0
                        , words = [ Var 0 ]
                        }
                    )
            }
    }


{-| Every `Rt.*` key a body RawCalls, in order (duplicates kept — the check
only needs membership).  The seed-closure skew detector: a RawCall to a key
missing from (Rt.program True True True) or from Rt.rtDeps makes that defun unreachable or
unseedable, and this row fails before any .ssa is emitted.
-}
callsSym : String -> Il.Func -> Bool
callsSym sym f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Call _ _ (Il.Sym s) _ ->
                            s == sym

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


funcByName : String -> Il.Module -> Maybe Il.Func
funcByName name mod =
    List.head (List.filter (\f -> f.name == name) mod.funcs)


frameBaseIsAlloc : Il.Func -> Bool
frameBaseIsAlloc f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Alloc r _ ->
                            r == "f"

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


rawCallSyms : Exp -> List String
rawCallSyms exp =
    case exp of
        Lit _ ->
            []

        Var _ ->
            []

        GRef _ ->
            []

        StreamRef _ ->
            []

        Lam lambda ->
            rawCallSyms lambda.body

        NoTail inner ->
            rawCallSyms inner

        App app ->
            rawCallSyms app.fn ++ List.concatMap rawCallSyms app.args

        PrimApp app ->
            List.concatMap rawCallSyms app.args

        Let block ->
            List.concatMap
                (\binder ->
                    case binder of
                        LetBind bind ->
                            rawCallSyms bind.value

                        LetDestruct d ->
                            rawCallSyms d.value
                )
                block.binders
                ++ rawCallSyms block.body

        Case branch ->
            rawCallSyms branch.scrutinee
                ++ List.concatMap (\a -> rawCallSyms a.body) branch.alts

        Con con ->
            List.concatMap rawCallSyms con.args

        Tup es ->
            List.concatMap rawCallSyms es

        RecordLit setters ->
            List.concatMap (\p -> rawCallSyms (Tuple.second p)) setters

        RecordGet rec _ ->
            rawCallSyms rec

        RecordUpdate update ->
            rawCallSyms update.base
                ++ List.concatMap (\p -> rawCallSyms (Tuple.second p)) update.updates

        ListLit es ->
            List.concatMap rawCallSyms es

        If block ->
            rawCallSyms block.cond
                ++ rawCallSyms block.thenBranch
                ++ rawCallSyms block.elseBranch

        ShortAnd block ->
            rawCallSyms block.left ++ rawCallSyms block.right

        ShortOr block ->
            rawCallSyms block.left ++ rawCallSyms block.right

        NotEqual block ->
            rawCallSyms block.left ++ rawCallSyms block.right

        Unsafe node ->
            case node of
                RawCall call ->
                    call.sym :: List.concatMap rawCallSyms call.args

                RawTagOf inner ->
                    rawCallSyms inner

                RawPayload p ->
                    rawCallSyms p.value

                RawPayload32 p ->
                    rawCallSyms p.value

                RawMkValue mk ->
                    List.concatMap rawCallSyms mk.words

                RawAllocVector len ->
                    rawCallSyms len

                RawVecLoad l ->
                    rawCallSyms l.vec ++ rawCallSyms l.index

                RawVecAddr a ->
                    rawCallSyms a.vec ++ rawCallSyms a.index

                RawVecStore st ->
                    rawCallSyms st.vec ++ rawCallSyms st.index ++ rawCallSyms st.value

                RawStrByte sb ->
                    rawCallSyms sb.str ++ rawCallSyms sb.index

                WithRoots rooted ->
                    rawCallSyms rooted.body

                RawTagIs ti ->
                    rawCallSyms ti.value

                RawBin bin ->
                    rawCallSyms bin.a ++ rawCallSyms bin.b

                RawUn un ->
                    rawCallSyms un.v

                RawCmp c ->
                    rawCallSyms c.a ++ rawCallSyms c.b

                RawFltBin f ->
                    rawCallSyms f.a ++ rawCallSyms f.b

                RawFltCmp f ->
                    rawCallSyms f.a ++ rawCallSyms f.b

                RawIToF inner ->
                    rawCallSyms inner

                RawLoadFlt inner ->
                    rawCallSyms inner

                RawAllocRaw len ->
                    rawCallSyms len

                RawByteLoad bl ->
                    rawCallSyms bl.ptr ++ rawCallSyms bl.index

                RawByteStore bs ->
                    rawCallSyms bs.ptr ++ rawCallSyms bs.index ++ rawCallSyms bs.value

                RawWordLoad wl ->
                    rawCallSyms wl.ptr ++ rawCallSyms wl.index

                RawWordStore ws ->
                    rawCallSyms ws.ptr ++ rawCallSyms ws.index ++ rawCallSyms ws.value

                RawCallRaw seat ->
                    List.concatMap rawCallSyms seat.args

                RawDataAddr _ ->
                    []
