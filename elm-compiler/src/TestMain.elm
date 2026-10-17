port module TestMain exposing (main, rawCallSyms, canon)

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
import Dict exposing (Dict)
import Mid.Audit as Audit
import Mid.Ir exposing (Alt, AltKind(..), Binder, Defun, Exp(..), LetBinder(..), Lit(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), UnsafeNode(..), ValuePath)
import Mid.Module as MidModule
import Mid.Qbe.Il as Il
import Mid.Qbe.Lower as QbeLower
import Mid.QbeModule as QbeModule
import Mid.Qbe.Print as Print
import Mid.Qbe.Types as QbeTypes
import Mid.Rt as Rt
import Mid.RtGc as RtGc
import Mid.RtLang.Ast as Ast
import Mid.RtLang.Check as Check
import Mid.RtLang.LowerToIr as LowerToIr
import Mid.RtLayout as RtLayout
import Mid.RtPrims as RtPrims
import Mid.RtLang.Parse as Parse
import Mid.TaintCheck as TaintCheck
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


main : Program String () Msg
main =
    Platform.worker
        { init = \runtimeMidText -> ( (), runTests runtimeMidText )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


runTests : String -> Cmd Msg
runTests runtimeMidText =
    case Rt.load runtimeMidText of
        Ok rt ->
            report (String.join "\n" (checks rt))

        Err msg ->
            report ("FAIL runtime.mid load: " ++ msg ++ "\nFAIL runtime.mid anti-empty (the census rows could not run)")


checks : Rt.Runtime -> List String
checks rt =
    [ -- M1 ANTI-EMPTY: the census rows below read `rt` (the once-per-process
      -- load of runtime.mid).  If test-run.js (or run.js) ever stops reading
      -- the file, the flag text is empty, `Rt.load` would parse nothing, and
      -- every `rtProgram`-derived row could pass VACUOUSLY over an empty
      -- program.  This row pins the full surface program (185 defuns — the
      -- MEASURED `defun` count of elm-compiler/runtime.mid; 179 + the six
      -- stage-6 B1 apply defuns), so an empty or truncated load turns it
      -- RED, loudly, before any vacuous row can.
      check "M1 anti-empty: the loaded runtime.mid parsed to the full surface program (185 defuns)"
        (case rt.parsedSource of
            Ok ast ->
                List.length ast == 185

            Err _ ->
                False
        )
    , check "utf8ByteLength 'héllo' == 6" (utf8ByteLength "héllo" == 6)
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
    , check "rt program: 150 defuns, all Rt.*; cons 2-ary, substring 3-ary, con 3-ary, open 2-ary, glob 1-ary, read-file-as-string 1-ary, exec-run 3-ary (E added the record walk/rebuild defuns; stage 5 added the ADT constructor and the closure; stage 3 GROUP 1 added the fd prims write-byte/read-byte/open/close + readFull/cStrFill; stage 3 GROUP 2 added intern/value/str + floatCopy; stage 3 GROUP 3A added getpid/getcwd/cd/getenv/setenv + cStrLenGo/cStrCopyGo; GROUP 3B added glob + its 8 helpers; GROUP 3B-2a added exec-plan + its 20 ep* decode helpers; GROUP 3B-2b added the RUN defuns execGo + its 21 helpers; GROUP 3B-3 added read-file-as-string + readFileGo/memGo — the LAST rt_prim route); GROUP 3B-2c added exec-run (the slurp+result half; the rt_exec_run seat is deleted)"
        (List.length (rtProgram rt True True True) == 167
            && List.all (\d -> String.startsWith "Rt." d.key) (rtProgram rt True True True)
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
                (rtProgram rt True True True)
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
                (rtProgram rt True True True)
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
                (rtProgram rt True True True)
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
                (rtProgram rt True True True)
            && List.any
                (\d ->
                    d.key == "Rt.setenv"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 2

                                _ ->
                                    False
                           )
                )
                (rtProgram rt True True True)
            && List.any
                (\d ->
                    d.key == "Rt.glob"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 1

                                _ ->
                                    False
                           )
                )
                (rtProgram rt True True True)
            && List.any
                (\d ->
                    d.key == "Rt.getpid"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 1

                                _ ->
                                    False
                           )
                )
                (rtProgram rt True True True)
            && List.any
                (\d ->
                    d.key == "Rt.read-file-as-string"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 1

                                _ ->
                                    False
                           )
                )
                (rtProgram rt True True True)
            && List.any
                (\d ->
                    d.key == "Rt.exec-run"
                        && (case d.value of
                                Lam lambda ->
                                    List.length lambda.params == 3

                                _ ->
                                    False
                           )
                )
                (rtProgram rt True True True)
        )
    , check "rt seeds closure: cons/=/+ pull the 8-key deepEq closure; + alone pulls just Rt.+"
        (Rt.seeds (Set.fromList [ "cons", "+", "=" ])
            == [ "Rt.+", "Rt.asF", "Rt.=", "Rt.deepEq", "Rt.bytesEqGo", "Rt.symEq", "Rt.vecEq", "Rt.cons" ]
            && Rt.seeds (Set.fromList [ "+" ]) == [ "Rt.+", "Rt.asF" ]
        )
    , check "rt call graph: every RawCall target is a program key AND declared in rtDeps (the seed-closure skew must-fail)"
        (let

            syms key =
                case List.filter (\d -> d.key == key) (rtProgram rt True True True) of
                    d :: _ ->
                        rawCallSyms d.value

                    [] ->
                        []

            allKeys =
                List.map .key (rtProgram rt True True True)

            ok key =
                List.all (\sym -> List.member sym allKeys && List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps)))
                    (syms key)
         in
         List.all ok allKeys
        )
    , check "rt cons lowers to a QBE function named q_Rt_x2econs"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True) "Rt.cons" of
            Ok mod ->
                List.any (\f -> f.name == "q_Rt_x2econs") mod.funcs

            Err _ ->
                False
        )
    , check "rt lowering REJECTS a raw-word binder read in a value position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rtRawBinderMisuse ] "Rt.bad" of
            Err msg ->
                String.contains "raw word binder" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a word node in a value position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rtWordInValuePosition ] "Rt.bad2" of
            Err msg ->
                String.contains "value position" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a value binder in a raw-argument position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rtValueInRawPosition ] "Rt.bad3" of
            Err msg ->
                String.contains "not a raw word" msg

            Ok _ ->
                False
        )

    -- THE CHAR-ORDERING FIX (osier-qbe-charfix): a `<` on a Char/string operand
    -- must INLINE the byte-lexicographic compare (a loadub byte walk) and NOT
    -- call the numeric-only Rt.< — which answers False for any non-number,
    -- the silent mislower whose fix this row pins structurally (the BEHAVIOURAL
    -- pin is the gate's charord.elm row).
    , check "char ordering: a Char/string `<` lowers to the inline byte compare (loadub), NOT a call to Rt.<"
        (case QbeLower.lower rt True False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True ++ [ charOrdProbe ]) "Rt.charOrdProbe" of
            Ok mod ->
                case funcByName "q_Rt_x2echarOrdProbe" mod of
                    Just f ->
                        not (callsSym "q_Rt_x2e_x3c" f) && hasLoadUb f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "char ordering CONTROL: a `<` on two Int literals keeps the i64 fast path (no loadub byte walk, no Rt.< call)"
        (case QbeLower.lower rt True False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True ++ [ intLtProbe ]) "Rt.intLtProbe" of
            Ok mod ->
                case funcByName "q_Rt_x2eintLtProbe" mod of
                    Just f ->
                        not (callsSym "q_Rt_x2e_x3c" f) && not (hasLoadUb f)

                    Nothing ->
                        False

            Err _ ->
                False
        )

    -- STAGE 6 U1a: the RawCallAgg node (the aggregate call through a
    -- runtime word).  Nothing emits it yet (EMIT-INERT — the corpus .ssa
    -- is byte-identical); these rows pin the MECHANISM U4a's apply/bounce
    -- port will call through.
    , check "rt RawCallAgg classification: a defun containing one is a DIRECT safepoint (allocating — the callee is unknown generated code)"
        (rt.direct rawCallAggProbe)
    , check "rt RawCallAgg lowers to a word-target aggregate call returning the sret address"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggProbe ] "Rt.rawCallAggProbe" of
            Ok mod ->
                List.any rawCallAggCallShape mod.funcs

            Err _ ->
                False
        )

    -- STAGE 6 U2: the raw-word defun convention (Mid.Rt.rawAbi).  Rt.die /
    -- Rt.halt lower with (params Base L, ret Base L) instead of the lean
    -- 4-arg :val ABI, and their Lower/surface callers emit matching WORD
    -- calls.  A :val-shaped arg or an under-applied call here is a SILENT
    -- MISCOMPILE (the callee reads a garbage register), so the emitted
    -- shapes are pinned, not just "it links".
    , check "rawAbi set + classification: Rt.cStrEq/Rt.die/Rt.halt/Rt.main + the B0 frame pair are the word-ABI keys and the die/halt/cStrEq/metaGo/parseArgsGo/frame set are frame-free (a die path must not reach a safepoint; the meta-walk compare and the A4a arg loop are non-allocating — their only seat calls are rawcall, which the classifier treats alloc-free — so they stay frame-free; Rt.main stays rawAbi frame-free regardless of its RawCallAgg dispatch, because the rawAbi arm is checked before the allocating set; the frame pair is FRAME-FREE by construction — its only nodes are rawcall/raw-word loads/stores and rawAbi->rawAbi calls to the two non-allocating helpers)"
        (Rt.rawAbi
            == Set.fromList [ "Rt.cStrEq", "Rt.die", "Rt.halt", "Rt.main", "Rt.frame-enter", "Rt.frame-leave", "Rt.frameBlock", "Rt.frameZero", "Rt.apply", "Rt.apply-tail" ]
            && not (Set.member "Rt.die" rt.allocating)
            && not (Set.member "Rt.halt" rt.allocating)
            && not (Set.member "Rt.cStrEq" rt.allocating)
            && not (Set.member "Rt.cStrEqGo" rt.allocating)
            && not (Set.member "Rt.metaGo" rt.allocating)
            && not (Set.member "Rt.parseArgsGo" rt.allocating)
            && not (Set.member "Rt.frame-enter" rt.allocating)
            && not (Set.member "Rt.frame-leave" rt.allocating)
            && not (Set.member "Rt.frameBlock" rt.allocating)
            && not (Set.member "Rt.frameZero" rt.allocating)
            -- stage 6 B1: Rt.apply/Rt.apply-tail are the word-ABI wrappers
            -- (NOT frame-free — they call the allocating loops, so the
            -- classifier marks them allocating); the loops and helpers are
            -- :val defuns (never rawAbi) and reach a safepoint (allocvec).
            && Set.member "Rt.apply" rt.allocating
            && Set.member "Rt.apply-tail" rt.allocating
            && Set.member "Rt.applyGo" rt.allocating
            && Set.member "Rt.applyTailGo" rt.allocating
            -- Rt.callArity is CONSERVATIVELY allocating (RawCallAgg is
            -- deny-by-default: the callee is unknown generated code) even
            -- though rt_callN/rt_bounce allocate nothing themselves.
            && Set.member "Rt.callArity" rt.allocating
            && not (Set.member "Rt.copyWords" rt.allocating)
        )
    , check "rawAbi emission shape: Rt.die (1 word param) emits (params [a0:l], ret l, frame-free alloc scratch)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.die" of
            Ok mod ->
                case funcByName "q_Rt_x2edie" mod of
                    Just f ->
                        List.map Tuple.second f.params == [ Il.Base Il.L ]
                            && f.ret == Il.Base Il.L
                            && not (callsSym "rt_frame_enter" f)
                            && frameBaseIsAlloc f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "rawAbi emission shape: Rt.halt (0-ary) emits an EMPTY param list — the lean 4-arg shape would be a silent miscompile"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.halt" of
            Ok mod ->
                case funcByName "q_Rt_x2ehalt" mod of
                    Just f ->
                        f.params == []
                            && f.ret == Il.Base Il.L
                            && frameBaseIsAlloc f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0perf-2 frameZero is a rawAbi WORD defun: params [a0:l], ret l, frame-free, an in-frame self-tail (jmp @body, no self-call) and NO :val aggregate or 40-byte blit in its body — the recur's Value blits are gone (fails on the pre-fix :val frameZero)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.frameZero" of
            Ok mod ->
                case funcByName "q_Rt_x2eframeZero" mod of
                    Just f ->
                        List.map Tuple.second f.params
                            == [ Il.Base Il.L ]
                            && f.ret
                            == Il.Base Il.L
                            && frameBaseIsAlloc f
                            && selfLoopIsLoop ( "q_Rt_x2eframeZero", f )
                            && not (hasValOrBlit f.blocks)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0perf-2 frame-enter calls frameZero with a WORD call (one Base L arg) — never the lean 4-arg :val shape the pre-fix :val defun needed"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.frame-enter" of
            Ok mod ->
                case funcByName "q_Rt_x2eframe_x2denter" mod of
                    Just f ->
                        rawAbiWordCall "q_Rt_x2eframeZero" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "rawAbi VALUE-position reject (fail-before): a rawAbi Rt call in a :val tail is a loud Err, never a silent word->val reinterpretation"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawAbiValueMisuse ] "Rt.bad4" of
            Err msg ->
                String.contains "rawAbi Rt call in a VALUE position" msg

            Ok _ ->
                False
        )
    , check "rawAbi caller shape: the midgc die arm emits a WORD call q_Rt_x2edie(l msg) — one Base L arg, never the lean 4-arg :val shape"
        (case QbeLower.lower rt False False False True True True True True False QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.allocVector" of
            Ok mod ->
                case funcByName "q_Rt_x2egcInit" mod of
                    Just f ->
                        rawAbiWordCall "q_Rt_x2edie" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "rawAbi caller shape: the halt arm retargets rt_halt -> q_Rt_x2ehalt under QBE_MIDDRIVER and keeps rt_halt by default (the symbol swap)"
        (let
            prog =
                (driverProg rt)
         in
         (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities prog) prog "Rt.emptylist" of
            Ok mod ->
                case funcByName "q_Rt_x2eemptylist" mod of
                    Just f ->
                        callsSym "q_Rt_x2ehalt" f && not (callsSym "rt_halt" f)

                    Nothing ->
                        False

            Err _ ->
                False
         )
            && (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (rtArities prog) prog "Rt.emptylist" of
                    Ok mod ->
                        case funcByName "q_Rt_x2eemptylist" mod of
                            Just f ->
                                callsSym "rt_halt" f && not (callsSym "q_Rt_x2ehalt" f)

                            Nothing ->
                                False

                    Err _ ->
                        False
               )
        )

    -- STAGE 6 A1: the LOWER INTERFACE THE DRIVER NEEDS (the six items of the
    -- re-plan's "THE LOWER INTERFACE" obs).  The driver BODY is A3a's job —
    -- these rows pin only the INTERFACE: the rawAbi ret-class, the export-
    -- name override, the driverSeeds addition, the RawCallAgg named-symbol
    -- accept + still-rejected shape, the val-position Blit, and the arity
    -- record totality.
    , check "A1 ret-class: Rt.main (2 word params argc/argv) emits params [a0:l,a1:l] and ret w (the exit code) — the per-key rawAbi RET CLASS (Rt.die/Rt.halt stay ret l, pinned above)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                case funcByName "main" mod of
                    Just f ->
                        List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L ]
                            && f.ret == Il.Base Il.W

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "A1 export-name override: Rt.main emits name \"main\" (not q_Rt_x2emain) with export_ = True — crt0 links main (the rt_callN naming precedent)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "main" mod of
                    Just f ->
                        f.export_

                    Nothing ->
                        False
                )
                    && not (List.any (\g -> g.name == "q_Rt_x2emain") mod.funcs)

            Err _ ->
                False
        )
    , check "A1 driverSeeds: Rt.main is seeded alongside the Rt.die/Rt.halt closure (keepRtDependencies keeps the leaf) — the driver entry is reachable under QBE_MIDDRIVER=1; A3b extends the closure with the meta-walk family (Rt.metaGo -> Rt.cStrEq -> Rt.cStrEqGo), A4a with the arg loop (Rt.parseArgsGo)"
        (List.member "Rt.main" Rt.driverSeeds
            && List.member "Rt.die" Rt.driverSeeds
            && List.member "Rt.halt" Rt.driverSeeds
            && List.member "Rt.cStrLenGo" Rt.driverSeeds
            && List.member "Rt.metaGo" Rt.driverSeeds
            && List.member "Rt.cStrEq" Rt.driverSeeds
            && List.member "Rt.cStrEqGo" Rt.driverSeeds
            && List.member "Rt.parseArgsGo" Rt.driverSeeds
        )
    , check "A1b RawCallAgg FUNCTION-symbol accept: a RawSym callee (not just a temp) lowers to Call (Just _) (Agg \"val\") (Il.Sym \"rt_bounce\") [word] — the code label, never a dN data ref"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggSymProbe ] "Rt.rawCallAggSymProbe" of
            Ok mod ->
                List.any rawCallAggSymCallShape mod.funcs

            Err _ ->
                False
        )
    , check "A1b RawCallAgg DATA-symbol callee rejected: a rawstr data-def stand-in (RawCStr \"rt_bounce\") is a loud Err, not a silent call into static data (the A1-review blocker's over-acceptance half)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggDataSymProbe ] "Rt.rawCallAggDataSymProbe" of
            Err msg ->
                String.contains "DATA" msg

            Ok _ ->
                False
        )
    , check "A1 RawCallAgg still-rejected shape: a CONSTANT callee is a loud Err (the callee must be a RawSym function symbol or a loaded code pointer, never a constant)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggConstProbe ] "Rt.rawCallAggConstProbe" of
            Err msg ->
                String.contains "not a constant" msg

            Ok _ ->
                False
        )
    , check "A1b RawCallAgg VALUE-position Blit: a val-shaped aggregate call of rt_bounce emits Call (Just _) (Agg \"val\") (Il.Sym \"rt_bounce\") + a 40-byte Blit into the dest slot (the rtApply non-tail shape, never a word-address return)"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggValProbe ] "Rt.rawCallAggValProbe" of
            Ok mod ->
                List.any rawCallAggValBlitShape mod.funcs

            Err _ ->
                False
        )
    , check "A1b emitted .ssa names the FUNCTION symbol as the call target: the lowered module RENDERED as .ssa contains `call $rt_bounce` (a code label), not a data-def call"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty [ rawCallAggSymProbe ] "Rt.rawCallAggSymProbe" of
            Ok mod ->
                String.contains "call $rt_bounce" (Print.print mod)

            Err _ ->
                False
        )
    , check "A1b rawsym surface → RawSym node: `rawsym(\"rt_bounce\")` parses and lowers to the FUNCTION-symbol word producer (RawSym, distinct from rawstr's RawCStr data def)"
        (case lowlBody "defun Rt.sym(a : val) -> val {\n  word p = rawsym(\"rt_bounce\");\n  return mknil;\n}" of
            Ok body ->
                canon body == canon (llets [ ( ltb 2, Unsafe (RawSym "rt_bounce") ) ] lmkNilV)

            Err _ ->
                False
        )
    , check "A1b aggcall surface → RawCallAgg with a RawSym callee: `aggcall val rawsym(\"rt_bounce\")(0)` lowers fn to the function-symbol producer (content, not a rawstr data def) — the binder is a WORD (the sret buffer address; A4b corrected J1: BOTH aggcall shapes are :word)"
        (case lowlBody "defun Rt.agg(a : val) -> val {\n  word r = aggcall val rawsym(\"rt_bounce\")(0);\n  return mknil;\n}" of
            Ok body ->
                canon body
                    == canon (llets [ ( ltb 2, Unsafe (RawCallAgg { fn = Unsafe (RawSym "rt_bounce"), args = [ ltn 0 ], shape = "val" }) ) ] lmkNilV)

            Err _ ->
                False
        )
    , check "A4b J1 aggcall shape classes (CORRECTED): `aggcall val` and `aggcall ret` BOTH check :word — the result is the sret buffer ADDRESS (40-B :val / 80-B :ret), matching Lower's isRawWordExp (every RawCallAgg is a word producer); a val binder is a LOUD J1 reject.  The A4a AggVal->TVal reading was the bug A4b fixed: it made `val r = aggcall val` check :val while Lower bound a raw word, an unreadable binder"
        (case ( lowlBody "defun Rt.av(a : val) -> val {\n  word r = aggcall val rawsym(\"rt_bounce\")(0);\n  return mknil;\n}", lowlBody "defun Rt.ar(a : val) -> val {\n  word r = aggcall ret rawsym(\"rt_bounce\")(0);\n  return mknil;\n}", lowlBody "defun Rt.aw(a : val) -> val {\n  val r = aggcall val rawsym(\"rt_bounce\")(0);\n  return r;\n}" ) of
            ( Ok _, Ok _, Err msg ) ->
                String.contains "declares val but its initializer is word" msg || String.contains "declares word" msg

            _ ->
                False
        )
    , check "A3a surface Rt.main: the driver body is in the surface-spliced program (a Let chain reaching the usage rawstr — the A1 stub was a bare Lit 0 placeholder; a parse/check failure would shrink rtProgram to [] and this goes red)"
        (case defunByKey "Rt.main" (driverProg rt) of
            Just { value } ->
                case value of
                    Lam l ->
                        case l.body of
                            Let _ ->
                                True

                            _ ->
                                False

                    _ ->
                        False

            Nothing ->
                False
        )
    , check "A3a MIDDRIVER emission — message DATA: the module carries the usage and toomany messages as content-keyed data defs (the exact frozen-golden bytes, err-usage.txt / err-toomany.txt)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (List.any (\d -> List.member (Il.DStr "usage: <prog> <entry-name> [int|float-arg ...]\n") d.items) mod.datas)
                    && (List.any (\d -> List.member (Il.DStr "qbe-rt: >16 entry args not supported\n") d.items) mod.datas)

            Err _ ->
                False
        )
    , check "A3a MIDDRIVER emission — the error paths CALL write and exit IN $main: $main's OWN blocks emit >=2 call $write and >=2 call $exit (usage and toomany each write fd-2 then exit 2; notmeta adds more writes) — COUNTED, not just scoped, so neither Rt.die/Rt.halt (other functions) NOR the notmeta path alone can satisfy it (the A3a-review SHOULD-FIX 1, the count form)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "main" mod of
                    Just f ->
                        symCount "write" f >= 2 && symCount "exit" f >= 2

                    Nothing ->
                        False
                )

            Err _ ->
                False
        )
    , check "A1 rawAbi arity record totality: rawAbiArity's keys are EXACTLY the rawAbi set, and each recorded arity matches the defun's Lam params (Rt.cStrEq 2 / Rt.die 1 / Rt.halt 0 / Rt.main 2) — a param added without touching the record is a compile Err"
        (Dict.keys Rt.rawAbiArity == Set.toList Rt.rawAbi
            && (Maybe.map4
                    (\eqN dieN haltN mainN ->
                        (eqN == Maybe.withDefault -1 (Maybe.map lamArity (defunByKey "Rt.cStrEq" (driverProg rt))))
                            && (dieN == Maybe.withDefault -1 (Maybe.map lamArity (defunByKey "Rt.die" (driverProg rt))))
                            && (haltN == Maybe.withDefault -1 (Maybe.map lamArity (defunByKey "Rt.halt" (driverProg rt))))
                            && (mainN == Maybe.withDefault -1 (Maybe.map lamArity (defunByKey "Rt.main" (driverProg rt))))
                    )
                    (Dict.get "Rt.cStrEq" Rt.rawAbiArity)
                    (Dict.get "Rt.die" Rt.rawAbiArity)
                    (Dict.get "Rt.halt" Rt.rawAbiArity)
                    (Dict.get "Rt.main" Rt.rawAbiArity)
                    == Just True
               )
        )
    , check "A3b surface defuns: Rt.cStrEq (rawAbi word,word->word), Rt.cStrEqGo (val byte loop) and Rt.metaGo (val row walker) are in the surface-spliced driver program — a parse/check failure would shrink rtProgram to [] and this goes red"
        (case ( defunByKey "Rt.cStrEq" (driverProg rt), defunByKey "Rt.cStrEqGo" (driverProg rt), defunByKey "Rt.metaGo" (driverProg rt) ) of
            ( Just _, Just _, Just _ ) ->
                True

            _ ->
                False
        )
    , check "A3b MIDDRIVER emission — the notmeta DATA: the module carries the not-in-meta prefix and suffix as content-keyed data defs (the exact frozen-golden bytes of err-notmeta.txt split at the entry name)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (List.any (\d -> List.member (Il.DStr "qbe-rt: entry '") d.items) mod.datas)
                    && (List.any (\d -> List.member (Il.DStr "' not in qbe_meta\n") d.items) mod.datas)

            Err _ ->
                False
        )
    , check "A3b MIDDRIVER emission — the meta walk reads the exported table: the rendered .ssa references $qbe_meta and $qbe_meta_len (the wload base/count of the walk)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                let
                    ssa =
                        Print.print mod
                in
                String.contains "$qbe_meta" ssa && String.contains "$qbe_meta_len" ssa

            Err _ ->
                False
        )
    , check "A4a surface defun: Rt.parseArgsGo (val, frame-free arg loop) is in the surface-spliced driver program — a parse/check failure would shrink rtProgram to [] and this goes red"
        (case defunByKey "Rt.parseArgsGo" (driverProg rt) of
            Just { value } ->
                case value of
                    Lam l ->
                        List.length l.params == 2

                    _ ->
                        False

            Nothing ->
                False
        )
    , check "A4a MIDDRIVER emission — the seats + root push: the rendered .ssa references $rt_boot, $rt_parse_arg, $rt_argv_install and $rt_root_push_value_array (the A2 seats the driver calls, each via rawcall)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                let
                    ssa =
                        Print.print mod
                in
                String.contains "call $rt_boot" ssa
                    && String.contains "call $rt_parse_arg" ssa
                    && String.contains "call $rt_argv_install" ssa
                    && String.contains "call $rt_root_push_value_array" ssa

            Err _ ->
                False
        )
    , check "A4a MIDDRIVER emission — the 17-arm entry dispatch: $main calls the rt_callN dispatchers by NAME (aggcall ret rawsym) and rt_bounce (aggcall val) — the RawCallAgg named-symbol shape, not a call into data"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                case funcByName "main" mod of
                    Just f ->
                        callsSym "rt_call1" f
                            && callsSym "rt_call9" f
                            && callsSym "rt_call16" f
                            && callsSym "rt_bounce" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "A4b MIDDRIVER emission — the program/print tail: $main calls the A4b seats BY NAME (rt_is_program/rt_run_program/rt_print_value via rawcall, rt_root_push_value for the result/model roots) — the seats the A2 result handed word-in/word-out"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                case funcByName "main" mod of
                    Just f ->
                        callsSym "rt_is_program" f
                            && callsSym "rt_run_program" f
                            && callsSym "rt_print_value" f
                            && callsSym "rt_root_push_value" f

                    Nothing ->
                        False

            Err _ ->
                False
        )

    -- STAGE 6 U2 fix 3: MIDGC x MIDDRIVER MUST DEDUPE ACROSS the seed lists.
    -- Lower concatenates the prim half (MidRt.seeds over the surface's called
    -- prims), the gc half (gcSeeds ++ conSeeds ++ closureSeeds) and the driver
    -- half (driverSeeds) — each unique WITHIN itself, but the halves OVERLAP:
    -- Rt.cStrLenGo sits in both the prim half and the driver/gc closure, and
    -- Rt.die sits in BOTH the gc and the driver closure.  The emission fold
    -- lowers one defun per key with no seen-set, so a repeat is a duplicate
    -- QBE symbol.  MEASURED fail-before (qbe-mk on fixtures/midgc-live.elm):
    -- QBE_MIDDRIVER=1 ALONE already dies with "symbol `q_Rt_x2ecStrLenGo' is
    -- already defined" (exit 1), and adding QBE_MIDGC=1 adds
    -- "symbol `q_Rt_x2edie' is already defined".  The plan declares the
    -- combination VALID, so the repeat is the defect; the fix is one `unique`
    -- over the whole concatenation, pinned here.
    , check "U2 fix 3 — MIDGC x MIDDRIVER dedupe: the seed halves overlap (Rt.cStrLenGo in the prim AND driver/gc closure, Rt.die in gc AND driver) and the one cross-boundary `unique` leaves EXACTLY ONE q_Rt_x2edie and ONE q_Rt_x2ecStrLenGo in the module"
        (let
            prog =
                rtProgram rt True True True ++ rtProgramGc rt True True True
         in
         case QbeLower.lower rt False False False True True True True True True QbeTypes.empty (rtArities prog) prog "Rt.allocVector" of
            Ok mod ->
                (List.length (List.filter (\f -> f.name == "q_Rt_x2edie") mod.funcs) == 1)
                    && (List.length (List.filter (\f -> f.name == "q_Rt_x2ecStrLenGo") mod.funcs) == 1)

            Err _ ->
                False
        )

    -- STAGE 6 U2 fix 2: THE midgc die MESSAGES CARRY THE "qbe-rt: " PREFIX.
    -- The deleted Zig seat (rt_midgc_die) wrote dieLoud(msgs[code]), and
    -- dieLoud's own format is "qbe-rt: {s}\n" (rt.zig:1221-1226), so the wire
    -- bytes were "qbe-rt: midgc: ...\n" — the fold emits "{msg}\n", so the
    -- prefix must live in the RAWSTR contents.  The ABSENCE half is what makes
    -- this row fail on the pre-fix mechanism (MEASURED before: the six data
    -- defs were the bare "midgc: ..." strings).  Rt.die's own format stays
    -- prefix-FREE — it is also the rt_die replacement (rt.zig:784-787 writes
    -- msg then "\n", no prefix), so baking the prefix into the defun would
    -- double it on the non-exhaustive-pattern path.
    , check "U2 fix 2 — midgc die prefix parity: the gc half's message data carries \"qbe-rt: midgc: mmap failed\" (dieLoud's prefix restored) and NOT the un-prefixed form"
        (let
            prog =
                rtProgram rt True True True ++ rtProgramGc rt True True True
         in
         case QbeLower.lower rt False False False True True True True True False QbeTypes.empty (rtArities prog) prog "Rt.allocVector" of
            Ok mod ->
                List.any (\d -> List.member (Il.DStr "qbe-rt: midgc: mmap failed") d.items) mod.datas
                    && not (List.any (\d -> List.member (Il.DStr "midgc: mmap failed") d.items) mod.datas)

            Err _ ->
                False
        )

    -- STAGE 6 U2 fix 4 (re-pinned at A5): THE NativeMain VECTOR PIN (plan
    -- obs-5's deferred obligation, the unpinned-midGc drift class).  run.js's
    -- DEFAULT hatch vector is now (midGc OFF, midDriver ON) — run.js:141
    -- QBE_MIDGC = (env === '1'), run.js:148 QBE_MIDDRIVER = (env !== '0') —
    -- and selfhost/NativeMain.elm:276's hard-coded ( False, True ) must carry
    -- the SAME pair: the selfhost lane and run.js have to emit byte-identical
    -- .ssa (the qbe-bootstrap --verify fixed point), so a flip in one and not
    -- the other is a SILENT divergence.  The MEASURED GAP, stated: Elm cannot
    -- read run.js, so this row pins the pair's VALUE (a pinned literal, the
    -- two Elm copies being named twins) and its MEANING (the default route it
    -- must select) — a run.js edit alone is NOT caught here; the machine
    -- check across that boundary is the bootstrap fixed point, and the cheap
    -- run.js-vs-NativeMain text row belongs in qbe-check.sh, outside this
    -- unit's write scope.  What the row DOES catch: an edit of the pinned
    -- pair (the routing half below turns a wrong pair into a FAIL), and a
    -- silent flip of either hatch at the B3/B4 landings.  POST-A5 the default
    -- route selects the MID DRIVER: q_Rt_x2ehalt IS emitted (the driver's
    -- Rt.halt), and the halt arm retargets rt_halt -> q_Rt_x2ehalt.  POST-B0
    -- rt_glob IS emitted too (midDriver now gates the globals block — the
    -- frame pair needs the freelist/frame_top words on this route).
    , check "U2 fix 4 — NativeMain vector pin: the selfhost hatch vector is (midGc=False, midDriver=True) = run.js's defaults, and routing THAT pair selects the driver route (q_Rt_x2ehalt emitted, rt_halt retargeted, rt_glob emitted for the B0 frame pair)"
        (let
            ( midGc, midDriver ) =
                defaultHatchVector

            prog =
                rtProgram rt True True True
         in
         (defaultHatchVector == ( False, True ))
            && (case QbeLower.lower rt False False False True True True True midGc midDriver QbeTypes.empty (rtArities prog) prog "Rt.emptylist" of
                    Ok mod ->
                        List.any (\f -> f.name == "q_Rt_x2ehalt") mod.funcs
                            && List.any (\d -> d.name == RtGc.globDataSym) mod.datas
                            && List.any (\f -> f.name == RtGc.globAddrSym) mod.funcs
                            && (case funcByName "q_Rt_x2eemptylist" mod of
                                    Just f ->
                                        callsSym "q_Rt_x2ehalt" f && not (callsSym "rt_halt" f)

                                    Nothing ->
                                        False
                               )

                    Err _ ->
                        False
               )
        )

    -- STAGE 6 U1c: the Mid-owned globals block + its 0-arg accessor, both
    -- GATED on the midgc flag (plan correction C3: the block replaces the
    -- deleted `rt_midgc_region`/`rt_midgc_set_region` Zig seats — the
    -- collector's region pointer is word 0, read/written through the
    -- EXISTING RawCallRaw + RawWordLoad/Store).  The gate is the FLAG, not
    -- the program contents: even a gcProgram-carrying compile emits neither
    -- def with midGc off (the DEFAULT route — the corpus byte-identity
    -- proof), and both with it on (the midgc route; U5a's driver joins the
    -- same gate).
    , check "stage6 globals block: midGc OFF emits neither rt_glob nor rt_glob_addr even with gcProgram in the compile (the gate; T19: an empty spliced half used to make the absence assertions vacuous — a pipeline Err now FAILs the row)"
        (case ( rtProgram rt True True True, rtProgramGc rt True True True ) of
            ( [], _ ) ->
                False

            ( _, [] ) ->
                False

            ( primProg, gcProg ) ->
                case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (rtArities (primProg ++ gcProg)) (primProg ++ gcProg) "Rt.allocVector" of
                    Ok mod ->
                        not (List.any (\d -> d.name == RtGc.globDataSym) mod.datas)
                            && not (List.any (\f -> f.name == RtGc.globAddrSym) mod.funcs)

                    Err _ ->
                        False
        )
    , check "stage6 globals block: midGc ON emits both, in the pinned shapes, and no gc defun names the deleted seats"
        (case QbeLower.lower rt False False False True True True True True False QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.allocVector" of
            Ok mod ->
                List.any
                    (\d ->
                        d.name
                            == RtGc.globDataSym
                            && d.align
                            == Just 8
                            && d.export_
                            && d.items
                            == [ Il.DZero (8 * RtGc.globWords) ]
                    )
                    mod.datas
                    && List.any
                        (\f ->
                            f.name
                                == RtGc.globAddrSym
                                && f.export_
                                && f.ret
                                == Il.Base Il.L
                                && f.params
                                == []
                                && f.blocks
                                == [ { label = "start", body = [], jump = Il.Ret (Just (Il.Sym RtGc.globDataSym)) } ]
                        )
                        mod.funcs
                    && not (List.any (callsSym "rt_midgc_region") mod.funcs)
                    && not (List.any (callsSym "rt_midgc_set_region") mod.funcs)
                    && List.any (callsSym RtGc.globAddrSym) mod.funcs

            Err _ ->
                False
        )

    -- STAGE 6 B0: the frame machinery retarget.  Under QBE_MIDDRIVER=1 the
    -- pooled-frame prologue calls the Mid rawAbi defun q_Rt_x2eframe_x2denter
    -- (nslots as an `l` word — the raw-word ABI, NOT the Zig seat's `w` i32)
    -- and the return calls q_Rt_x2eframe_x2dleave; the DEFAULT route keeps
    -- the Zig rt_frame_enter/rt_frame_leave seats.  These pins are the
    -- byte-identity boundary for the hatch.
    , check "B0 prologue retarget: under QBE_MIDDRIVER a framed defun enters through q_Rt_x2eframe_x2denter with an l-word nslots (Base L, not the Zig seat's Base W)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.cons" of
            Ok mod ->
                case funcByName "q_Rt_x2econs" mod of
                    Just f ->
                        rawAbiWordCall "q_Rt_x2eframe_x2denter" f && not (callsSym "rt_frame_enter" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0 return retarget: under QBE_MIDDRIVER a framed defun leaves through q_Rt_x2eframe_x2dleave, not the Zig rt_frame_leave"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.cons" of
            Ok mod ->
                case funcByName "q_Rt_x2econs" mod of
                    Just f ->
                        callsSym "q_Rt_x2eframe_x2dleave" f && not (callsSym "rt_frame_leave" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0 default-route identity: with the hatch OFF a framed defun keeps the Zig rt_frame_enter/rt_frame_leave seats"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.cons" of
            Ok mod ->
                case funcByName "q_Rt_x2econs" mod of
                    Just f ->
                        callsSym "rt_frame_enter" f && callsSym "rt_frame_leave" f && not (callsSym "q_Rt_x2eframe_x2denter" f) && not (callsSym "q_Rt_x2eframe_x2dleave" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0 frame defuns are rawAbi frame-free emission: q_Rt_x2eframe_x2denter/Leave emit frame-FREE alloc8 scratch (no rt_frame_enter), l params/ret, and the frame pair + helpers are EMITTED under the hatch (driverSeeds)"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "q_Rt_x2eframe_x2denter" mod of
                    Just f ->
                        List.map Tuple.second f.params == [ Il.Base Il.L ]
                            && f.ret == Il.Base Il.L
                            && not (callsSym "rt_frame_enter" f)
                            && frameBaseIsAlloc f

                    Nothing ->
                        False
                )
                    && (case funcByName "q_Rt_x2eframe_x2dleave" mod of
                            Just f ->
                                f.params == []
                                    && f.ret == Il.Base Il.L
                                    && not (callsSym "rt_frame_enter" f)
                                    && frameBaseIsAlloc f

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "B0 globals-block ungating: midDriver ON (midGc OFF) emits rt_glob + rt_glob_addr — the frames' freelist/frame_top block"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                List.any (\d -> d.name == RtGc.globDataSym) mod.datas
                    && List.any (\f -> f.name == RtGc.globAddrSym) mod.funcs
                    && List.any (callsSym RtGc.globAddrSym) mod.funcs

            Err _ ->
                False
        )

    -- STAGE 6 B1: the apply family.  Rt.apply/Rt.apply-tail are rawAbi
    -- WRAPPERS whose RESULT is an AGGREGATE (the rawAbi-ret-class extension):
    -- Rt.apply returns the 40-byte `:val` (applyGo's `.done` value) through
    -- sret, Rt.apply-tail the 80-byte `:ret` — both 3 word params (fslot,
    -- args, nargs), frame-FREE (alloc8, no rt_frame_enter — the rawAbi arm
    -- is checked before the allocating set).  The :val LOOP bodies
    -- (Rt.applyGo/Rt.applyTailGo) are FRAMED (they reach allocvec, a real
    -- safepoint — their f closure lives in a ROOTED frame slot, the over arm
    -- re-binds it via recur); Rt.callArity is CONSERVATIVELY framed
    -- (RawCallAgg denies by default); Rt.copyWords is frame-free (raw
    -- word loads/stores only).  The dispatch reaches rt_callN/rt_bounce by
    -- NAME — the same corpus-proven shape the driver's saturated arm uses.
    , check "B1 Rt.apply emission: Agg-val ret, 3 l params, frame-free alloc8, hands off to the val loop q_Rt_x2eapplyGo"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "q_Rt_x2eapply" mod of
                    Just f ->
                        List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L ]
                            && f.ret == Il.Agg "val"
                            && not (callsSym "rt_frame_enter" f)
                            && frameBaseIsAlloc f
                            && callsSym "q_Rt_x2eapplyGo" f

                    Nothing ->
                        False
                )
                    && (case funcByName "q_Rt_x2eapply_x2dtail" mod of
                            Just f ->
                                List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L ]
                                    && f.ret == Il.Agg "ret"
                                    && not (callsSym "rt_frame_enter" f)
                                    && frameBaseIsAlloc f
                                    && callsSym "q_Rt_x2eapplyTailGo" f

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "B1 loop/helper framing: the loops and the dispatch are FRAMED (they reach a safepoint), copyWords is frame-free, and the dispatch reaches rt_callN/rt_bounce by name"
        (case QbeLower.lower rt False False False True True True True False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "q_Rt_x2eapplyGo" mod of
                    Just f ->
                        callsSym "q_Rt_x2eframe_x2denter" f && not (frameBaseIsAlloc f)

                    Nothing ->
                        False
                )
                    && (case funcByName "q_Rt_x2eapplyTailGo" mod of
                            Just f ->
                                callsSym "q_Rt_x2eframe_x2denter" f

                            Nothing ->
                                False
                       )
                    && (case funcByName "q_Rt_x2ecallArity" mod of
                            Just f ->
                                callsSym "rt_call16" f && callsSym "rt_bounce" f

                            Nothing ->
                                False
                       )
                    && (case funcByName "q_Rt_x2ecopyWords" mod of
                            Just f ->
                                frameBaseIsAlloc f && not (callsSym "rt_frame_enter" f)

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )

    -- THE LEAN ABI (osier-midabi).  The classification is the soundness
    -- fact (a frame-free callee must never reach a safepoint); pin BOTH
    -- sides of the partition so a new RtPrims body or node form that moves a
    -- defun across it fails HERE, not at a churn fixture.
    --
    -- THE GROUP-3A ROWS protect a specific window: cStrLenGo/cStrCopyGo/
    -- cStrFill walk/copy bytes inside the callers' RAW-BUFFER windows — the
    -- raw temp from rt_raw_alloc/RawAllocRaw is valid only to the NEXT
    -- SAFEPOINT, so getcwd (strlen then wrap the same buffer), getenv
    -- (copy env->fresh buffer) and setenv/open/cd (fill then one libc call)
    -- are sound ONLY while those helpers contain no safepoint.  A future
    -- edit that adds an allocation (or a RawCall to an allocating defun) to
    -- any of them moves it INTO rt.allocating and fails THIS row — the
    -- alternative failure mode is a GC-timing bug no fixture can catch.
    -- (The three helpers are FRAME-FREE by emission — alloc8 scratch, no
    -- pooled frame; being framed would not itself be a safepoint (a frame
    -- is root registration), but frame-free is what the lean ABI grants
    -- ONLY on the strength of this classification, so the pinned property
    -- is the absence of a reachable allocation.)
    , check "rt allocation classification: the pure-read defuns are frame-free, the builders are framed"
        (Set.member "Rt.cons" rt.allocating
            && Set.member "Rt.@p" rt.allocating
            && Set.member "Rt.con" rt.allocating
            && Set.member "Rt.closure" rt.allocating
            && Set.member "Rt.cn" rt.allocating
            && Set.member "Rt.repeat" rt.allocating
            && Set.member "Rt.substring" rt.allocating
            && Set.member "Rt.strOf" rt.allocating
            && Set.member "Rt.str" rt.allocating
            && Set.member "Rt.shen.bytes->string" rt.allocating
            && Set.member "Rt.absvector" rt.allocating
            && not (Set.member "Rt.=" rt.allocating)
            && not (Set.member "Rt.+" rt.allocating)
            && not (Set.member "Rt.<" rt.allocating)
            && not (Set.member "Rt.deepEq" rt.allocating)
            && not (Set.member "Rt.bytesEqGo" rt.allocating)
            && not (Set.member "Rt.symEq" rt.allocating)
            && not (Set.member "Rt.vecEq" rt.allocating)
            && not (Set.member "Rt.asF" rt.allocating)
            && not (Set.member "Rt.toI32" rt.allocating)
            && not (Set.member "Rt.assoc" rt.allocating)
            && not (Set.member "Rt.assocGo" rt.allocating)
            && not (Set.member "Rt.address->" rt.allocating)
            && not (Set.member "Rt.countL" rt.allocating)
            && not (Set.member "Rt.conFill" rt.allocating)
            && not (Set.member "Rt.closureFill" rt.allocating)
            && not (Set.member "Rt.intern" rt.allocating)
            && not (Set.member "Rt.value" rt.allocating)
            && not (Set.member "Rt.floatCopy" rt.allocating)
            -- stage 3 groups 1 + 3A: the fd/process prim bodies and their
            -- byte-walk helpers (the windows named above).
            && not (Set.member "Rt.getpid" rt.allocating)
            && not (Set.member "Rt.cStrLenGo" rt.allocating)
            && not (Set.member "Rt.cStrCopyGo" rt.allocating)
            && not (Set.member "Rt.cStrFill" rt.allocating)
            && not (Set.member "Rt.readFull" rt.allocating)
            && not (Set.member "Rt.close" rt.allocating)
            -- stage 3 GROUP 3B (glob): globScanGo's soundness RESTS on
            -- staying frame-free — state[1] is a raw pointer into the GC
            -- pattern buffer, which a pooled frame cannot root (the C
            -- block's contents are not Values).  A future edit adding an
            -- allocation to ANY of these breaks the scan window with no
            -- other instrument — it must fail THIS row.
            && not (Set.member "Rt.globLastSlash" rt.allocating)
            && not (Set.member "Rt.globIsDot" rt.allocating)
            && not (Set.member "Rt.globIsDotDot" rt.allocating)
            && not (Set.member "Rt.globScanGo" rt.allocating)
            && not (Set.member "Rt.globStrLess" rt.allocating)
            && not (Set.member "Rt.globSortShift" rt.allocating)
            && not (Set.member "Rt.globSortGo" rt.allocating)
            && Set.member "Rt.getcwd" rt.allocating
            && Set.member "Rt.cd" rt.allocating
            && Set.member "Rt.getenv" rt.allocating
            && Set.member "Rt.setenv" rt.allocating
            && Set.member "Rt.open" rt.allocating
            && Set.member "Rt.write-byte" rt.allocating
            && Set.member "Rt.read-byte" rt.allocating
            && Set.member "Rt.glob" rt.allocating
            && Set.member "Rt.globBuildGo" rt.allocating
            -- stage 3 GROUP 3B-2a (exec-plan decode): the decode itself is
            -- safepoint-free BY CONSTRUCTION (tag names are BYTES in a
            -- malloc'd cbuf — an LString literal is a safepoint and cannot
            -- appear), so all 21 ep* helpers are frame-free; the ONE member
            -- is Rt.exec-plan itself — since 3B-2c via the rtDeps edge to
            -- Rt.exec-run (the MANUAL OVERRIDE the rt_exec_run C seat needed
            -- is deleted; the fixed point's caller-of-an-allocating-helper
            -- rule now roots the plan Value param across the result build's
            -- collections).  A future edit that adds an allocation
            -- (a string literal, an allocating callR) to any ep* helper
            -- moves it INTO the set and fails THIS row — the decode's raw
            -- temps (the blob, the cbuf, st) are C-heap and survive only
            -- while no safepoint intervenes.
            && Set.member "Rt.exec-plan" rt.allocating
            -- GROUP 3B-2c (exec-plan SLURP+RESULT): Rt.exec-run allocates
            -- DIRECTLY (the two result RawAllocRaws, the intern literals,
            -- the cons tree) so it is a MEMBER; the slurp loop and the byte
            -- memcpy it reuses (Rt.readFileGo/Rt.memGo) stay frame-free
            -- below.
            && Set.member "Rt.exec-run" rt.allocating
            -- GROUP 3B-2b (exec-plan RUN): every run defun is frame-free —
            -- the whole point of the port's child-after-fork discipline is
            -- that the run performs NO GC allocation (fork/exec/wait and the
            -- blob/cbuf/state walks are RawCallRaw + raw loads over C-heap
            -- memory); the allocating half is Rt.exec-run above.  A
            -- future edit adding an allocation to any of these reintroduces
            -- a GC safepoint into the fork'd child (INVARIANT 2) — it must
            -- fail THIS row.
            && not (Set.member "Rt.execGo" rt.allocating)
            && not (Set.member "Rt.mkTmpAt" rt.allocating)
            && not (Set.member "Rt.cStrEqLit" rt.allocating)
            && not (Set.member "Rt.wStr" rt.allocating)
            && not (Set.member "Rt.wRaw" rt.allocating)
            && not (Set.member "Rt.waitStatusCode" rt.allocating)
            && not (Set.member "Rt.envHome" rt.allocating)
            && not (Set.member "Rt.isChildBuiltin" rt.allocating)
            && not (Set.member "Rt.echoGo" rt.allocating)
            && not (Set.member "Rt.childCd" rt.allocating)
            && not (Set.member "Rt.childPwd" rt.allocating)
            && not (Set.member "Rt.childBuiltin" rt.allocating)
            && not (Set.member "Rt.applyOneRedir" rt.allocating)
            && not (Set.member "Rt.applyRedirects" rt.allocating)
            && not (Set.member "Rt.bodyWriteGo" rt.allocating)
            && not (Set.member "Rt.openBodyTmpfile" rt.allocating)
            && not (Set.member "Rt.wireCmdGo" rt.allocating)
            && not (Set.member "Rt.wirePipeGo" rt.allocating)
            && not (Set.member "Rt.closeCmdTmpfds" rt.allocating)
            && not (Set.member "Rt.closePipeTmpfds" rt.allocating)
            && not (Set.member "Rt.closePipesGo" rt.allocating)
            && not (Set.member "Rt.closeOthersGo" rt.allocating)
            && not (Set.member "Rt.runBuiltinInprocess" rt.allocating)
            && not (Set.member "Rt.epCount" rt.allocating)
            && not (Set.member "Rt.epCount" rt.allocating)
            && not (Set.member "Rt.epElem" rt.allocating)
            && not (Set.member "Rt.epNum" rt.allocating)
            && not (Set.member "Rt.epStr" rt.allocating)
            && not (Set.member "Rt.epSymOf" rt.allocating)
            && not (Set.member "Rt.epProg" rt.allocating)
            && not (Set.member "Rt.epProgGo" rt.allocating)
            && not (Set.member "Rt.epChain" rt.allocating)
            && not (Set.member "Rt.epPipeline" rt.allocating)
            && not (Set.member "Rt.epPipeGo" rt.allocating)
            && not (Set.member "Rt.epCmd" rt.allocating)
            && not (Set.member "Rt.epArgvGo" rt.allocating)
            && not (Set.member "Rt.epRedirsGo" rt.allocating)
            && not (Set.member "Rt.epRedir" rt.allocating)
            && not (Set.member "Rt.epCountStdin" rt.allocating)
            && not (Set.member "Rt.epFreeChains" rt.allocating)
            && not (Set.member "Rt.epFreeCmds" rt.allocating)
            && not (Set.member "Rt.epFreeCmd" rt.allocating)
            && not (Set.member "Rt.epFreeArgv" rt.allocating)
            && not (Set.member "Rt.epFreeRedirs" rt.allocating)
            -- GROUP 3B-3 (read-file-as-string): the prim allocates directly
            -- (cStrOf, the result RawAllocRaw) so it is a MEMBER; the C-heap
            -- read loop and the byte memcpy MUST stay frame-free — their
            -- acc/tmp/mblk raw pointers (and, in the final copy, the GC dst
            -- pointer stored as a raw word in the C block) are sound exactly
            -- while no safepoint can intervene under them.  A future edit
            -- adding an allocation to either breaks that window with no
            -- other instrument — it must fail THIS row.
            && Set.member "Rt.read-file-as-string" rt.allocating
            && not (Set.member "Rt.readFileGo" rt.allocating)
            && not (Set.member "Rt.memGo" rt.allocating)
        )
    , check "rt gc (midgc) classification: the collector is FRAME-FREE by construction (a frame-free callee must never reach a safepoint)"
        (not (Set.member "Rt.collect" rt.allocating)
            && not (Set.member "Rt.allocVector" rt.allocating)
            && not (Set.member "Rt.allocRaw" rt.allocating)
            && not (Set.member "Rt.gcMarkPtr" rt.allocating)
            && not (Set.member "Rt.gcMarkValue" rt.allocating)
            && not (Set.member "Rt.gcMarkRoots" rt.allocating)
            && not (Set.member "Rt.gcDrain" rt.allocating)
            && not (Set.member "Rt.gcSweep" rt.allocating)
            && not (Set.member "Rt.gcAlloc" rt.allocating)
            && not (Set.member "Rt.gcAllocGo" rt.allocating)
            && not (Set.member "Rt.gcScanValueArray" rt.allocating)
            && not (Set.member "Rt.gcInit" rt.allocating)
        )
    , check "rt gc call graph: every RawCall target in the collector is a program key (prim half included — Rt.die is appended to the prim half) AND declared in rtDeps (T18: read over the SPLICED gc half — the DSL list is tripwire seats, whose .surface-seat call would fail this row loudly if the splice ever dropped a body)"
        (let
            gcSyms key =
                case List.filter (\d -> d.key == key) (rtProgramGc rt True True True) of
                    d :: _ ->
                        rawCallSyms d.value

                    [] ->
                        []

            gcKeys =
                List.map .key (rtProgramGc rt True True True)

            programKeys =
                List.map .key (rtProgram rt True True True ++ rtProgramGc rt True True True)

            ok key =
                List.all (\sym -> List.member sym programKeys && List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps)))
                    (gcSyms key)
         in
         case gcKeys of
             -- T19: the driver maps a pipeline Err to [], and `List.all ok []`
             -- is trivially true — an Err must FAIL the row, not pass it.
             [] ->
                 False

             _ ->
                 List.all ok gcKeys
        )
    , check "rt gc seeds: the collector seeds are exactly the two seats plus their transitive closure (stage 6 U2 adds Rt.die + Rt.cStrLenGo through the die arm's RawCall edge)"
        (Rt.gcSeeds
            == [ "Rt.allocVector", "Rt.gcInit", "Rt.die", "Rt.cStrLenGo", "Rt.gcAlloc", "Rt.gcAllocGo", "Rt.collect", "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkValue", "Rt.gcMarkPtr", "Rt.gcDrain", "Rt.gcSweep", "Rt.allocRaw" ]
        )
    , check "rt con seeds: the Mid ADT constructor and its fill helper"
        (Rt.conSeeds == [ "Rt.con", "Rt.conFill" ]
        )
    , check "rt closure seeds: the Mid closure and its 0-based fill helper"
        (Rt.closureSeeds == [ "Rt.closure", "Rt.closureFill" ]
        )
    , check "rt lean ABI: a frame-free callee has pointer params, :val return and NO frame enter/leave"
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True) "Rt.+" of
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
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True) "Rt.cons" of
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
        (case QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True) "Rt.+" of
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
    -- SF2 (the g3-fix review): the STACK property itself has no pin until
    -- this row.  The partition rows above protect the GC window
    -- (no reachable safepoint); they are BLIND to a self-App that leaves
    -- TAIL position — a non-tail saturated self-App allocates nothing (so
    -- the classification stays 'edge', sound) but Lower compiles it as a
    -- NATIVE call per iteration, and the ~100 KB per-byte stack-overflow
    -- crash RETURNS with every suite green (only the corpus hash moves,
    -- and a deliberate re-freeze masks that).  What makes the loop a loop
    -- is the shape `jmp @body` with NO call to the defun's own q_ symbol —
    -- pin exactly that, structurally, for the three byte-walk helpers AND
    -- glob's per-entry loops (group 3B: a directory with N entries runs the
    -- scan/sort/build loops N times — a reverted loop shape is one native
    -- frame per ENTRY).
    , check "rt self-tail loops: cStrLenGo/cStrCopyGo/cStrFill/memGo + the glob + ep* + RUN loops emit jmp @body and NO native call to their own symbol (the O(1)-stack property)"
        (List.all
            (\( key, qname ) ->
                case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (rtArities (rtProgram rt True True True)) (rtProgram rt True True True) key of
                    Ok mod ->
                        case funcByName qname mod of
                            Just f ->
                                selfLoopIsLoop ( qname, f )

                            Nothing ->
                                False

                    Err _ ->
                        False
            )
            [ ( "Rt.cStrLenGo", "q_Rt_x2ecStrLenGo" )
            , ( "Rt.cStrCopyGo", "q_Rt_x2ecStrCopyGo" )
            , ( "Rt.cStrFill", "q_Rt_x2ecStrFill" )
            , ( "Rt.globLastSlash", "q_Rt_x2eglobLastSlash" )
            , ( "Rt.globScanGo", "q_Rt_x2eglobScanGo" )
            , ( "Rt.globStrLess", "q_Rt_x2eglobStrLess" )
            , ( "Rt.globSortShift", "q_Rt_x2eglobSortShift" )
            , ( "Rt.globSortGo", "q_Rt_x2eglobSortGo" )
            , ( "Rt.globBuildGo", "q_Rt_x2eglobBuildGo" )
            -- GROUP 3B-2a (exec-plan decode): the ep* walk/free loops are
            -- per-ELEMENT loops (one iteration per argv entry, per redir,
            -- per chain) over plans that can legally carry hundreds of
            -- elements — a reverted loop shape is one native frame per
            -- element.  The 12 SELF-RECURSIVE ep* defuns (App GRef
            -- own-key, saturated non-forced); epNum/epStr/epSymOf share
            -- epUnwrapDefun and epProg/epChain/epPipeline/epCmd/epRedir/
            -- epFreeCmd recurse only CROSS-defun, so they are correctly
            -- absent here.
            -- GROUP 3B-2b (exec-plan RUN): the run loops iterate per chain,
            -- per cmd, per redir and per pipe over the same plans, and
            -- execGo's mode machine is THE whole run — a reverted loop shape
            -- is one native frame per element again.
            , ( "Rt.execGo", "q_Rt_x2eexecGo" )
            , ( "Rt.cStrEqLit", "q_Rt_x2ecStrEqLit" )
            , ( "Rt.echoGo", "q_Rt_x2eechoGo" )
            , ( "Rt.applyRedirects", "q_Rt_x2eapplyRedirects" )
            , ( "Rt.bodyWriteGo", "q_Rt_x2ebodyWriteGo" )
            , ( "Rt.wireCmdGo", "q_Rt_x2ewireCmdGo" )
            , ( "Rt.wirePipeGo", "q_Rt_x2ewirePipeGo" )
            , ( "Rt.closeCmdTmpfds", "q_Rt_x2ecloseCmdTmpfds" )
            , ( "Rt.closePipeTmpfds", "q_Rt_x2eclosePipeTmpfds" )
            , ( "Rt.closePipesGo", "q_Rt_x2eclosePipesGo" )
            , ( "Rt.closeOthersGo", "q_Rt_x2ecloseOthersGo" )
            , ( "Rt.epSymIs", "q_Rt_x2eepSymIs" )
            , ( "Rt.epCount", "q_Rt_x2eepCount" )
            , ( "Rt.epElem", "q_Rt_x2eepElem" )
            , ( "Rt.epProgGo", "q_Rt_x2eepProgGo" )
            , ( "Rt.epPipeGo", "q_Rt_x2eepPipeGo" )
            , ( "Rt.epArgvGo", "q_Rt_x2eepArgvGo" )
            , ( "Rt.epRedirsGo", "q_Rt_x2eepRedirsGo" )
            , ( "Rt.epCountStdin", "q_Rt_x2eepCountStdin" )
            , ( "Rt.epFreeChains", "q_Rt_x2eepFreeChains" )
            , ( "Rt.epFreeCmds", "q_Rt_x2eepFreeCmds" )
            , ( "Rt.epFreeArgv", "q_Rt_x2eepFreeArgv" )
            , ( "Rt.epFreeRedirs", "q_Rt_x2eepFreeRedirs" )
            -- GROUP 3B-3 (read-file-as-string): the read loop iterates once
            -- per 64 KiB chunk and memGo once per BYTE — a reverted loop
            -- shape is one native frame per byte (the cStrFill crash class).
            , ( "Rt.readFileGo", "q_Rt_x2ereadFileGo" )
            , ( "Rt.memGo", "q_Rt_x2ememGo" )
            ]
        )

    -- SF1 (the g3-fix review): the classifier's self-GRef-App EDGE rule is
    -- valid ONLY for saturated non-forced heads — an under-/over-applied or
    -- forced one routes lowerGRefValue + rtApply, and rt_apply BUILDS A
    -- PARTIAL CLOSURE (a real GC safepoint) inside a defun the edge rule
    -- would keep frame-free.  Latent (no Rt body has these shapes), so the
    -- row CONSTRUCTS them: three probe defuns whose ONLY suspicious node is
    -- the malformed self-App, each asserted to lower FRAMED (rt_frame_enter
    -- present = classified allocating).  Under the pre-fix rule these
    -- lowered frame-free — the exact unsoundness.
    , check "rt classifier: an UNDER-/OVER-applied or FORCED self-GRef App is a DIRECT SAFEPOINT (rt_apply builds a partial closure), not an edge"
        (rt.direct probeUnderSelfApp
            && rt.direct probeOverSelfApp
            && rt.direct probeForcedSelfApp
            -- positive control: the SATURATED non-forced self-App that the
            -- real helpers use stays an EDGE (rt.direct False) — the rule
            -- was narrowed, not disabled.
            && not (rt.direct cStrLenGoDefunForControl)
        )

    , check "rt = symbol fast path: emitted as a pointer short-circuit that KEEPS the symEq fallback, and the hatch removes it"
        (case ( QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True True) "Rt.="
              , QbeLower.lower rt False False False True True True True False False QbeTypes.empty Dict.empty (rtProgram rt True True False) "Rt.="
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

    -- ==================== TIER-2 T2: the surface expression parser ====================
    -- (Mid.RtLang.Parse — parse -> Mid.RtLang.Ast.Exp).  One row per
    -- expression family, the precedence/associativity pins, and the
    -- must-fail rejects.  Nothing outside TestMain imports Parse yet (T7
    -- wires it), so these rows are the parser's only consumer and the
    -- compiler's emitted behaviour is untouched (corpus stays the
    -- emit-inert oracle).  `withroots` gets its row in the T3 section
    -- (T2 parsed its [ids] list and rejected the { block } body until the
    -- statement layer existed).

    -- literals
    , check "parse: int literal"
        (Parse.parseExp "42" == Ok (Ast.EInt 42))
    , check "parse: hex int literal"
        (Parse.parseExp "0x1A" == Ok (Ast.EInt 26))
    , check "parse: float literal"
        (Parse.parseExp "1.5" == Ok (Ast.EFlt 1.5))
    , check "parse: float exponent literal"
        (Parse.parseExp "1.5e3" == Ok (Ast.EFlt 1500))
    , check "parse: string literal"
        (Parse.parseExp "\"hi\"" == Ok (Ast.EStr "hi"))
    , check "parse: string escapes (backslash n, t, quote, backslash, r, 0)"
        (Parse.parseExp "\"a\\n\\t\\\"b\\\\c\\r\\0\"" == Ok (Ast.EStr "a\n\t\"b\\c\r\u{0000}"))
    , check "parse: true/false/mknil sugar (mkbool(1) / mkbool(0) / the bare nil literal)"
        (Parse.parseExp "true" == Ok (Ast.EBuiltin Ast.MkBool [ Ast.EInt 1 ])
            && Parse.parseExp "false"
                == Ok (Ast.EBuiltin Ast.MkBool [ Ast.EInt 0 ])
            && Parse.parseExp "mknil"
                == Ok (Ast.EBuiltin Ast.MkNil [])
        )
    , check "parse: variable"
        (Parse.parseExp "x_1" == Ok (Ast.EVar "x_1"))

    -- grouping and whitespace (space/CR/LF only -- the vendored skipper has no tab)
    , check "parse: parentheses group"
        (Parse.parseExp "(a + b) * c"
            == Ok (Ast.EWordBin Ast.WMul (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
        )
    , check "parse: newlines and repeated spaces between tokens"
        (Parse.parseExp "  a\n+   b  " == Ok (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EVar "b")))

    -- precedence and associativity pins (the silent-re-association catchers)
    , check "parse: * binds tighter than +"
        (Parse.parseExp "a + b * c"
            == Ok (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EWordBin Ast.WMul (Ast.EVar "b") (Ast.EVar "c")))
        )
    , check "parse: - is LEFT-associative (a - b - c is (a - b) - c)"
        (Parse.parseExp "a - b - c"
            == Ok (Ast.EWordBin Ast.WSub (Ast.EWordBin Ast.WSub (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
        )
    , check "parse: shifts are LEFT-associative and distinct (<< then >>; >>> is the zero-fill one)"
        (Parse.parseExp "a << b >> c"
            == Ok (Ast.EWordBin Ast.WShAr (Ast.EWordBin Ast.WShl (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
            && Parse.parseExp "a >>> b"
                == Ok (Ast.EWordBin Ast.WShR (Ast.EVar "a") (Ast.EVar "b"))
        )
    , check "parse: compares chain LEFT-associatively (a < b < c is (a < b) < c)"
        (Parse.parseExp "a < b < c"
            == Ok (Ast.EWordCmp Ast.WClts (Ast.EWordCmp Ast.WClts (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
        )
    , check "parse: == is tighter than & (C order), == chains left"
        (Parse.parseExp "a & b == c"
            == Ok (Ast.EWordBin Ast.WBitAnd (Ast.EVar "a") (Ast.EWordCmp Ast.WCeq (Ast.EVar "b") (Ast.EVar "c")))
            && Parse.parseExp "a == b == c"
                == Ok (Ast.EWordCmp Ast.WCeq (Ast.EWordCmp Ast.WCeq (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
        )
    , check "parse: & is tighter than | ; && is tighter than || ; || chains left"
        (Parse.parseExp "a & b | c"
            == Ok (Ast.EWordBin Ast.WBitOr (Ast.EWordBin Ast.WBitAnd (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
            && Parse.parseExp "a && b || c"
                == Ok (Ast.EShortOr (Ast.EShortAnd (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
            && Parse.parseExp "a || b || c"
                == Ok (Ast.EShortOr (Ast.EShortOr (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c"))
        )

    -- float family
    , check "parse: float binops, mul-level precedence (x f+ y f* z is x f+ (y f* z))"
        (Parse.parseExp "x f+ y f* z"
            == Ok (Ast.EFltBin Ast.FAdd (Ast.EVar "x") (Ast.EFltBin Ast.FMul (Ast.EVar "y") (Ast.EVar "z")))
            && Parse.parseExp "x f- y"
                == Ok (Ast.EFltBin Ast.FSub (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f/ y"
                == Ok (Ast.EFltBin Ast.FDiv (Ast.EVar "x") (Ast.EVar "y"))
        )
    , check "parse: float compares (f< f<= f> f>= f== f!=)"
        (Parse.parseExp "x f< y" == Ok (Ast.EFltCmp Ast.FLt (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f<= y"
                == Ok (Ast.EFltCmp Ast.FLe (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f> y"
                == Ok (Ast.EFltCmp Ast.FGt (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f>= y"
                == Ok (Ast.EFltCmp Ast.FGe (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f== y"
                == Ok (Ast.EFltCmp Ast.FEq (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x f!= y"
                == Ok (Ast.EFltCmp Ast.FNe (Ast.EVar "x") (Ast.EVar "y"))
        )
    , check "parse: f-op munch rule (MEASURED) -- the f must be AT the operator position: 'f < 3' and 'f<3' are the VARIABLE f word-compared to 3"
        (Parse.parseExp "f < 3" == Ok (Ast.EWordCmp Ast.WClts (Ast.EVar "f") (Ast.EInt 3))
            && Parse.parseExp "f<3"
                == Ok (Ast.EWordCmp Ast.WClts (Ast.EVar "f") (Ast.EInt 3))
        )

    -- calls
    , check "parse: call with the full dotted Rt key"
        (Parse.parseExp "call Rt.deepEq(a, b)"
            == Ok (Ast.ECall "Rt.deepEq" [ Ast.EVar "a", Ast.EVar "b" ])
        )
    , check "parse: rawcall with 6 word args (the measured mmap site)"
        (Parse.parseExp "rawcall mmap(a, b, c, d, e, f)"
            == Ok (Ast.ERawCall "mmap" [ Ast.EVar "a", Ast.EVar "b", Ast.EVar "c", Ast.EVar "d", Ast.EVar "e", Ast.EVar "f" ])
        )
    , check "parse: rawcall args nest builtins (the write(fd, payload(s, 0), n) shape)"
        (Parse.parseExp "rawcall write(fd, payload(s, 0), n)"
            == Ok
                (Ast.ERawCall "write"
                    [ Ast.EVar "fd"
                    , Ast.EBuiltin Ast.Payload [ Ast.EVar "s", Ast.EInt 0 ]
                    , Ast.EVar "n"
                    ]
                )
        )
    , check "parse: aggcall ret/val, fn a primary expression (the computed code-pointer shape)"
        (Parse.parseExp "aggcall ret f(a)" == Ok (Ast.EAggCall Ast.AggRet (Ast.EVar "f") [ Ast.EVar "a" ])
            && Parse.parseExp "aggcall val wload(p, 0)(a)"
                == Ok
                    (Ast.EAggCall Ast.AggVal
                        (Ast.EBuiltin Ast.WordLoad [ Ast.EVar "p", Ast.EInt 0 ])
                        [ Ast.EVar "a" ]
                    )
        )

    -- builtins: every spelling in Ast.builtinClass, arg shapes syntactic
    , check "parse: the 1-arg builtins"
        (List.all
            (\( src, exp ) -> Parse.parseExp src == Ok exp)
            [ ( "mknum(n)", Ast.EBuiltin Ast.MkNum [ Ast.EVar "n" ] )
            , ( "mkbool(x)", Ast.EBuiltin Ast.MkBool [ Ast.EVar "x" ] )
            , ( "mkflt(x)", Ast.EBuiltin Ast.MkFlt [ Ast.EVar "x" ] )
            , ( "allocvec(n)", Ast.EBuiltin Ast.AllocVec [ Ast.EVar "n" ] )
            , ( "allocraw(n)", Ast.EBuiltin Ast.AllocRaw [ Ast.EVar "n" ] )
            , ( "itof(w)", Ast.EBuiltin Ast.IToF [ Ast.EVar "w" ] )
            , ( "fload(v)", Ast.EBuiltin Ast.FLoad [ Ast.EVar "v" ] )
            , ( "ftoi32(f)", Ast.EBuiltin Ast.FToI32 [ Ast.EVar "f" ] )
            , ( "sext(w)", Ast.EBuiltin Ast.Sext [ Ast.EVar "w" ] )
            , ( "uext(w)", Ast.EBuiltin Ast.Uext [ Ast.EVar "w" ] )
            , ( "bitnot(w)", Ast.EBuiltin Ast.BitNot [ Ast.EVar "w" ] )
            , ( "reclen(v)", Ast.EBuiltin Ast.RecLen [ Ast.EVar "v" ] )
            , ( "len32(v)", Ast.EBuiltin Ast.Len32 [ Ast.EVar "v" ] )
            ]
        )
    , check "parse: the 2-arg builtins"
        (List.all
            (\( src, exp ) -> Parse.parseExp src == Ok exp)
            [ ( "mkstr(d, l)", Ast.EBuiltin Ast.MkStr [ Ast.EVar "d", Ast.EVar "l" ] )
            , ( "mkvec(d, l)", Ast.EBuiltin Ast.MkVec [ Ast.EVar "d", Ast.EVar "l" ] )
            , ( "vecload(p, i)", Ast.EBuiltin Ast.VecLoad [ Ast.EVar "p", Ast.EVar "i" ] )
            , ( "vecaddr(p, i)", Ast.EBuiltin Ast.VecAddr [ Ast.EVar "p", Ast.EVar "i" ] )
            , ( "strbyte(s, i)", Ast.EBuiltin Ast.StrByte [ Ast.EVar "s", Ast.EVar "i" ] )
            , ( "byteload(p, i)", Ast.EBuiltin Ast.ByteLoad [ Ast.EVar "p", Ast.EVar "i" ] )
            , ( "wload(p, i)", Ast.EBuiltin Ast.WordLoad [ Ast.EVar "p", Ast.EVar "i" ] )
            ]
        )
    , check "parse: the 3-arg store builtins"
        (List.all
            (\( src, exp ) -> Parse.parseExp src == Ok exp)
            [ ( "vecstore(p, i, v)", Ast.EBuiltin Ast.VecStore [ Ast.EVar "p", Ast.EVar "i", Ast.EVar "v" ] )
            , ( "bytestore(p, i, v)", Ast.EBuiltin Ast.ByteStore [ Ast.EVar "p", Ast.EVar "i", Ast.EVar "v" ] )
            , ( "wstore(p, i, v)", Ast.EBuiltin Ast.WordStore [ Ast.EVar "p", Ast.EVar "i", Ast.EVar "v" ] )
            ]
        )
    , check "parse: mkval is variadic (arity >= 1 per SigMkVal)"
        (Parse.parseExp "mkval(t)" == Ok (Ast.EBuiltin Ast.MkVal [ Ast.EVar "t" ])
            && Parse.parseExp "mkval(t, a, b)"
                == Ok (Ast.EBuiltin Ast.MkVal [ Ast.EVar "t", Ast.EVar "a", Ast.EVar "b" ])
        )
    , check "parse: payload/payload32 shorthand and the int-literal INDEX arg (payload(v, 2) -- the record-family read)"
        (Parse.parseExp "payload(v)" == Ok (Ast.EBuiltin Ast.Payload [ Ast.EVar "v", Ast.EInt 0 ])
            && Parse.parseExp "payload(v, 2)"
                == Ok (Ast.EBuiltin Ast.Payload [ Ast.EVar "v", Ast.EInt 2 ])
            && Parse.parseExp "payload32(v, 1)"
                == Ok (Ast.EBuiltin Ast.Payload32 [ Ast.EVar "v", Ast.EInt 1 ])
        )
    , check "parse: tagis takes a literal tag"
        (Parse.parseExp "tagis(v, 3)" == Ok (Ast.EBuiltin Ast.TagIs [ Ast.EVar "v", Ast.EInt 3 ]))

    -- must-fail rejects (the ParserFast commit/whitespace hazards' catchers)
    , check "parse REJECTS a missing operand (1 + -- an operator that matched must not re-associate or end quietly)"
        (case Parse.parseExp "1 +" of
            Err msg ->
                String.contains "expected an expression" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS an unterminated string"
        (case Parse.parseExp "\"abc" of
            Err msg ->
                String.contains "unterminated string" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS an unterminated call"
        (case Parse.parseExp "mknum(1" of
            Err msg ->
                String.contains "expected `)`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a bad token (@ starts no expression)"
        (case Parse.parseExp "@" of
            Err msg ->
                String.contains "found `@`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a non-literal payload index (RawPayload.word is a constant -- unrepresentable)"
        (case Parse.parseExp "payload(v, x)" of
            Err msg ->
                String.contains "expected an integer literal" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS trailing input (a b -- juxtaposition is not in the grammar)"
        (case Parse.parseExp "a b" of
            Err msg ->
                String.contains "unexpected input after the expression" msg

            Ok _ ->
                False
        )
    -- (`-1` was pinned REJECTING here in T2 — "no unary minus".  T8b gave
    -- the grammar negative literals; the row's replacement pins live in
    -- the T8b block below.)

    -- ==================== TIER-2 T3: the statement / block / defun parser ====================
    -- (the CONTAINER grammar: program := defun*, defun with @flag guards,
    -- block := stmt* term, stmt := bind | effect | mid-block if, term :=
    -- return | recur | branch-final if).  The positive rows assert exact
    -- Ast.Defun / Ast.Block trees; the rejects pin the REASON (message
    -- fragment) so a loud-but-wrong failure cannot pass.  Behavior was
    -- probe-proven (27 scratch cases) before these rows were written; the
    -- probe caught the effect-stmt keyword-munch bug and T2's latent
    -- withroots `]` bug.

    -- whole defuns
    , check "parse: a full small defun end-to-end (typed params, bind, effect call, return)"
        (Parse.parseProgram
            "defun Rt.add2(x: word, n: word) -> word {\n  word s = x + n;\n  call Rt.bump(s);\n  return s;\n}"
            == Ok
                [ { key = "Rt.add2"
                  , flags = []
                  , params =
                        [ { name = "x", ty = Ast.TWord }
                        , { name = "n", ty = Ast.TWord }
                        ]
                  , ret = Ast.TWord
                  , body =
                        { stmts =
                            [ Ast.SBind Ast.TWord "s" (Ast.EWordBin Ast.WAdd (Ast.EVar "x") (Ast.EVar "n"))
                            , Ast.SEffect (Ast.ECall "Rt.bump" [ Ast.EVar "s" ])
                            ]
                        , term = Ast.TRet (Ast.EVar "s")
                        }
                  }
                ]
        )
    , check "parse: an empty-param defun (the getpid shape) with a rawcall and mknum"
        (Parse.parseProgram "defun Rt.getpid() -> val {\n  word w = rawcall getpid();\n  return mknum(w);\n}"
            == Ok
                [ { key = "Rt.getpid"
                  , flags = []
                  , params = []
                  , ret = Ast.TVal
                  , body =
                        { stmts = [ Ast.SBind Ast.TWord "w" (Ast.ERawCall "getpid" []) ]
                        , term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EVar "w" ])
                        }
                  }
                ]
        )

    -- guards
    , check "parse: the @rec guard lands on the defun's flags"
        (Parse.parseProgram "@rec defun Rt.deepEq(a: val, b: val) -> val { return mkbool(1); }"
            == Ok
                [ { key = "Rt.deepEq"
                  , flags = [ Ast.Guard Ast.Rec ]
                  , params =
                        [ { name = "a", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body = { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EInt 1 ]) }
                  }
                ]
        )
    , check "parse: @!eqPtrFast lands as GuardNot, @consArr as Guard (the flag spellings are Ast's, exact)"
        (Parse.parseProgram "@!eqPtrFast defun Rt.eq(a: val, b: val) -> val { return mknil; }"
            == Ok
                [ { key = "Rt.eq"
                  , flags = [ Ast.GuardNot Ast.EqPtrFast ]
                  , params =
                        [ { name = "a", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body = { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNil []) }
                  }
                ]
                && (Parse.parseProgram "@consArr defun Rt.cons(h: val, t: val) -> val { return mknil; }"
                        == Ok
                            [ { key = "Rt.cons"
                              , flags = [ Ast.Guard Ast.ConsArr ]
                              , params =
                                    [ { name = "h", ty = Ast.TVal }
                                    , { name = "t", ty = Ast.TVal }
                                    ]
                              , ret = Ast.TVal
                              , body = { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNil []) }
                              }
                            ]
                   )
        )

    -- the SIf/TIf discrimination (the block's central mechanism)
    , check "parse: a mid-block if without else keeps the statements after it (SIf, not the terminator)"
        (Parse.parseBlock
            "{\n  if (tagis(v, 2) == 1) { return mknum(0); }\n  word w = payload(v);\n  return mknum(w);\n}"
            == Ok
                { stmts =
                    [ Ast.SIf
                        (Ast.EWordCmp Ast.WCeq (Ast.EBuiltin Ast.TagIs [ Ast.EVar "v", Ast.EInt 2 ]) (Ast.EInt 1))
                        { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EInt 0 ]) }
                        Nothing
                    , Ast.SBind Ast.TWord "w" (Ast.EBuiltin Ast.Payload [ Ast.EVar "v", Ast.EInt 0 ])
                    ]
                , term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EVar "w" ])
                }
        )
    , check "parse: a mid-block if with else (both branches diverge) still keeps the continuation"
        (Parse.parseBlock "{ if (w == 0) { return mknum(1); } else { return mknum(2); }\n  wstore(p, 0, w);\n  return mkbool(w); }"
            == Ok
                { stmts =
                    [ Ast.SIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "w") (Ast.EInt 0))
                        { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EInt 1 ]) }
                        (Just { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EInt 2 ]) })
                    , Ast.SEffect (Ast.EBuiltin Ast.WordStore [ Ast.EVar "p", Ast.EInt 0, Ast.EVar "w" ])
                    ]
                , term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EVar "w" ])
                }
        )
    , check "parse: a branch-final if is the block's terminator (TIf), with its else"
        (Parse.parseBlock "{ if (w == 0) { return mknil; } else { return mkbool(w); } }"
            == Ok
                { stmts = []
                , term =
                    Ast.TIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "w") (Ast.EInt 0))
                        { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNil []) }
                        (Just { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EVar "w" ]) })
                }
        )

    -- recur and withroots
    , check "parse: recur(a, b); is the terminator with its arguments (recur() too)"
        (Parse.parseBlock "{ recur(a, b); }" == Ok { stmts = [], term = Ast.TRecur [ Ast.EVar "a", Ast.EVar "b" ] }
            && Parse.parseBlock "{ recur(); }"
                == Ok { stmts = [], term = Ast.TRecur [] }
        )
    , check "parse: withroots [ids] { block } end-to-end (the T2 deferral completed)"
        (Parse.parseExp "withroots [x, y] { return vecload(x, 0); }"
            == Ok
                (Ast.EWithRoots [ "x", "y" ]
                    { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.VecLoad [ Ast.EVar "x", Ast.EInt 0 ]) }
                )
        )

    -- else binding and program shape
    , check "parse: a braced inner if does not steal the else (the else binds to the outer if)"
        (Parse.parseBlock "{ if (a == 1) { if (b == 2) { return mknil; } } else { return mkbool(1); } }"
            == Ok
                { stmts = []
                , term =
                    Ast.TIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "a") (Ast.EInt 1))
                        { stmts = []
                        , term =
                            Ast.TIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "b") (Ast.EInt 2))
                                { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNil []) }
                                Nothing
                        }
                        (Just { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EInt 1 ]) })
                }
        )
    , check "parse: a program is a list of defuns (the boundary handback between them)"
        (case Parse.parseProgram "defun Rt.a() -> val { return mknil; }\n\ndefun Rt.b() -> val { return mknil; }" of
            Ok defuns ->
                List.map .key defuns == [ "Rt.a", "Rt.b" ]

            Err _ ->
                False
        )
    , check "parse: the empty program (and whitespace-only) is zero defuns"
        (Parse.parseProgram "" == Ok [] && Parse.parseProgram "\n  " == Ok [])

    -- rejects (each pins the message fragment -- a loud-but-wrong failure must not pass)
    , check "parse REJECTS a defun missing its `-> ty` (a silently-untyped defun)"
        (case Parse.parseProgram "defun Rt.f(x: word) { return mknil; }" of
            Err msg ->
                String.contains "expected `->`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a statement missing its trailing `;`"
        (case Parse.parseProgram "defun Rt.f() -> val { word x = mknum(1) return mknil; }" of
            Err msg ->
                String.contains "expected `;`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS `if` without parentheses (the commit pins the reason, not a generic terminator error)"
        (case Parse.parseBlock "{ if x { return mknil; } }" of
            Err msg ->
                String.contains "parentheses" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a malformed param type (a type must be word, float or val)"
        (case Parse.parseProgram "defun Rt.f(x: wurd) -> val { return mknil; }" of
            Err msg ->
                String.contains "expected a type" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS an unterminated block (the `}` after the term is required)"
        (case Parse.parseProgram "defun Rt.f() -> val { return mknil;" of
            Err msg ->
                String.contains "expected `}`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS statements after the block's terminator (a silent drop/reorder would be a miscompile)"
        (case Parse.parseBlock "{ return mknil; wstore(p, 0, w); }" of
            Err msg ->
                String.contains "exactly one terminator" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a mid-block recur (a second terminator; recur is a term only, plan L4)"
        (case Parse.parseBlock "{ recur(a); recur(b); }" of
            Err msg ->
                String.contains "exactly one terminator" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS an unknown @flag (the flag set is exactly Ast's three, never a String)"
        (case Parse.parseProgram "@nope defun Rt.f() -> val { return mknil; }" of
            Err msg ->
                String.contains "unknown flag" msg

            Ok _ ->
                False
        )

    -- ==================== TIER-2 M0: `//` line comments ====================
    -- (handoff-osier-midfile-m0-result).  A `//` to end of line is a
    -- COMMENT, dropped at parse: nothing in Ast/Check/LowerToIr sees it
    -- (no new Ast ctor) and it never becomes a statement.  A comment IS
    -- whitespace — skipped wherever whitespace is legal — with ONE
    -- restriction PINNED here: a `//` whose immediately preceding
    -- character is a token character (`[A-Za-z0-9_.]`) is NOT a comment,
    -- so `a//b` is LOUD and a `//` inside a key or a string literal is
    -- never truncated.  One row per position, plus the abut-rule reject
    -- pair and a positive control for the separator rule.

    , check "parse comment: a leading comment line above the first defun (the top of a defun)"
        (case Parse.parseProgram "// Rt.getpid — the pid boxed as a val\ndefun Rt.getpid() -> val { return mknum(1); }" of
            Ok defuns ->
                List.map .key defuns == [ "Rt.getpid" ]

            Err _ ->
                False
        )
    , check "parse comment: after a statement and at the top of the block — and it creates NO statement"
        (Parse.parseBlock "{ // how the tag is read\n  word w = payload(v); // index 0\n  return mknum(w); }"
            == Ok
                { stmts = [ Ast.SBind Ast.TWord "w" (Ast.EBuiltin Ast.Payload [ Ast.EVar "v", Ast.EInt 0 ]) ]
                , term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EVar "w" ])
                }
        )
    , check "parse comment: a comment line BETWEEN two statements (nothing is dropped or reordered)"
        (Parse.parseBlock "{ word a = mknum(1);\n  // the second one\n  word b = mknum(2);\n  return b; }"
            == Ok
                { stmts =
                    [ Ast.SBind Ast.TWord "a" (Ast.EBuiltin Ast.MkNum [ Ast.EInt 1 ])
                    , Ast.SBind Ast.TWord "b" (Ast.EBuiltin Ast.MkNum [ Ast.EInt 2 ])
                    ]
                , term = Ast.TRet (Ast.EVar "b")
                }
        )
    , check "parse comment: between an expression's operands — after the operand, after the operator, and before it"
        (Parse.parseExp "a + b // trailing\n" == Ok (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EVar "b"))
            && Parse.parseExp "a // after the operand\n + b" == Ok (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EVar "b"))
            && Parse.parseExp "a +// after the operator\n b" == Ok (Ast.EWordBin Ast.WAdd (Ast.EVar "a") (Ast.EVar "b"))
        )
    , check "parse comment: in the whitespace-legal header slots (inside the parameter list, after `->`)"
        (case Parse.parseProgram "defun Rt.f(a: val, // the accumulator\n  b: val) -> // its class\nval { return mknil; }" of
            Ok defuns ->
                List.map .key defuns == [ "Rt.f" ]

            Err _ ->
                False
        )
    , check "parse comment: at end of file, after the closing brace"
        (case Parse.parseProgram "defun Rt.f() -> val { return mknil; }\n// EOF\n" of
            Ok defuns ->
                List.map .key defuns == [ "Rt.f" ]

            Err _ ->
                False
        )
    , check "parse comment: between a branch's closing brace and its `else`"
        (Parse.parseBlock "{ if (a == 1) { return mknil; } // the other arm\n else { return mkbool(1); } }"
            == Ok
                { stmts = []
                , term =
                    Ast.TIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "a") (Ast.EInt 1))
                        { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNil []) }
                        (Just { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EInt 1 ]) })
                }
        )
    , check "parse comment: a comment COUNTS as the whitespace separator a token boundary needs"
        (case Parse.parseProgram "defun //c\nRt.f() -> val { return mknil; }" of
            Ok defuns ->
                List.map .key defuns == [ "Rt.f" ]

            Err _ ->
                False
        )
    , check "parse comment CONTROL: with no separator at all the tokens merge (`defunRt`) and the parse is LOUD"
        (case Parse.parseProgram "defunRt.f() -> val { return mknil; }" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    , check "parse comment: `a//b` is NOT a comment — `/` is the division operator and the reject is loud (never a silent `a`)"
        (case Parse.parseExp "a//b" of
            Err msg ->
                String.contains "expected an expression" msg

            Ok _ ->
                False
        )
    , check "parse comment: `a //b` (separated by whitespace) IS a comment — the other half of the abut rule"
        (Parse.parseExp "a //b\n" == Ok (Ast.EVar "a"))
    , checkErr "check comment: a `//` inside a call key is part of the token (never truncated to `Rt.a`) and J2 rejects it"
        "J2"
        "defun Rt.f(a: val) -> val {\n  return call Rt.a//b(a);\n}"
    , check "parse comment: `//` inside a string literal is CONTENT (the string reader never consults the skipper)"
        (Parse.parseExp "\"http://x // not a comment\"" == Ok (Ast.EStr "http://x // not a comment"))

    -- ==================== M2: the module header + the export block ====================
    , check "M2 header: module name + export block parse, and a headerless module is an EMPTY header (the header is OPTIONAL)"
        ((case Parse.parseModule "module Rt\nexport Rt.f : val -> val\ndefun Rt.f(a: val) -> val { return mknil; }" of
            Ok m ->
                m.header
                    == { name = Just "Rt"
                       , exports =
                            [ { key = "Rt.f"
                              , sig = { ty = Ast.OArrow Ast.OVal Ast.OVal, effects = [], taint = False }
                              }
                            ]
                       }
                    && List.map .key m.defuns == [ "Rt.f" ]

            Err _ ->
                False
         )
            && (case Parse.parseModule "defun Rt.f(a: val) -> val { return mknil; }" of
                    Ok m ->
                        m.header == { name = Nothing, exports = [] } && List.map .key m.defuns == [ "Rt.f" ]

                    Err _ ->
                        False
               )
        )
    , check "M2 export type: quantifiers, a `Ref s` application, and a polymorphic arrow argument all parse (the forward-compat grammar — no grammar change needed later)"
        (parseExportTy "forall s. Ref s -> Int"
            == Just (Ast.OForall "s" (Ast.OArrow (Ast.OCon "Ref" [ Ast.OVar "s" ]) (Ast.OCon "Int" [])))
            && parseExportTy "exists s. Ref s"
            == Just (Ast.OExists "s" (Ast.OCon "Ref" [ Ast.OVar "s" ]))
            && parseExportTy "(forall s. Ref s -> Int) -> Int"
            == Just (Ast.OArrow (Ast.OForall "s" (Ast.OArrow (Ast.OCon "Ref" [ Ast.OVar "s" ]) (Ast.OCon "Int" []))) (Ast.OCon "Int" []))
        )
    , check "M2 export arity: `splitArrow` UNWRAPS a leading quantifier — the arrow chain under it IS the param list (`forall s. Ref s -> Int` is arity 1, not 0)"
        (Ast.splitArrow (Ast.OForall "s" (Ast.OArrow (Ast.OCon "Ref" [ Ast.OVar "s" ]) (Ast.OCon "Int" [])))
            == ( [ Ast.OCon "Ref" [ Ast.OVar "s" ] ], Ast.OCon "Int" [] )
            && Ast.splitArrow (Ast.OExists "s" (Ast.OArrow Ast.OVal Ast.OVal)) == ( [ Ast.OVal ], Ast.OVal )
        )
    , check "M2 export arity: a quantified export LOADS against its defun — `forall s. Ref s -> Int` over a 1-param defun is ACCEPTED (this row is the one the parse-only row above left open: the export PARSED but failed load with `declares arity 0`, blaming the defun)"
        (case Rt.load "module Rt\nexport Rt.f : forall s. Ref s -> Int\ndefun Rt.f(a: val) -> val { return mknil; }" of
            Ok m ->
                case Dict.get "Rt.f" m.externTypes of
                    Just sig ->
                        externArity sig
                            == 1
                            && Ast.splitArrow sig.ty
                            == ( [ Ast.OCon "Ref" [ Ast.OVar "s" ] ], Ast.OCon "Int" [] )

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "M2 export markers: `!io` and `!taint` parse and are CARRIED on the signature (enforcement is M4)"
        (case Parse.parseModule "export Rt.f : val -> val !io !taint\ndefun Rt.f(a: val) -> val { return mknil; }" of
            Ok m ->
                case m.header.exports of
                    e :: _ ->
                        e.sig == { ty = Ast.OArrow Ast.OVal Ast.OVal, effects = [ Ast.Io ], taint = True }

                    [] ->
                        False

            Err _ ->
                False
        )
    , check "M2 export marker: an unknown marker is a LOUD reject (a typo'd marker never passes silently)"
        (case Parse.parseModule "export Rt.f : val -> val !bogus\ndefun Rt.f(a: val) -> val { return mknil; }" of
            Err msg ->
                String.contains "unknown export marker" msg

            Ok _ ->
                False
        )
    , check "M2 export marker: a DROPPED `!` is LOUD — `Val Int io` is a parse ERROR, never a silent type application to a variable named `io` (io/taint are reserved, so only a MARKER can spell them)"
        ((case Parse.parseModule "export Rt.f : Val Int io\ndefun Rt.f(a: val) -> val { return mknil; }" of
            Err msg ->
                String.contains "unexpected input" msg

            Ok _ ->
                False
         )
            && (case Parse.parseModule "export Rt.f : Val Int !io\ndefun Rt.f(a: val) -> val { return mknil; }" of
                    Ok m ->
                        List.map (\e -> ( e.sig.effects, e.sig.taint )) m.header.exports == [ ( [ Ast.Io ], False ) ]

                    Err _ ->
                        False
               )
        )
    , check "M2 key agreement: exports naming existing defuns with agreeing arities ACCEPT"
        (Check.checkExports
            [ { key = "Rt.f", sig = { ty = Ast.OArrow Ast.OVal Ast.OVal, effects = [], taint = False } } ]
            (Dict.fromList [ ( "Rt.f", 1 ) ])
            == Ok ()
        )
    , check "M2 key agreement: an export naming no defun is a LOUD reject"
        (case Check.checkExports
            [ { key = "Rt.ghost", sig = { ty = Ast.OVal, effects = [], taint = False } } ]
            (Dict.fromList [ ( "Rt.f", 1 ) ])
         of
            Err msg ->
                String.contains "names no defun" msg

            Ok () ->
                False
        )
    , check "M2 key agreement: an export whose declared arity disagrees with the defun is a LOUD reject (J2 would check against a lying signature)"
        (case Check.checkExports
            [ { key = "Rt.f", sig = { ty = Ast.OArrow Ast.OVal Ast.OVal, effects = [], taint = False } } ]
            (Dict.fromList [ ( "Rt.f", 2 ) ])
         of
            Err msg ->
                String.contains "declares arity 1" msg

            Ok () ->
                False
        )
    , check "M2 key agreement: a duplicate export for one key is a LOUD reject"
        (case Check.checkExports
            [ { key = "Rt.f", sig = { ty = Ast.OVal, effects = [], taint = False } }
            , { key = "Rt.f", sig = { ty = Ast.OVal, effects = [], taint = False } }
            ]
            (Dict.fromList [ ( "Rt.f", 0 ) ])
         of
            Err msg ->
                String.contains "exported more than once" msg

            Ok () ->
                False
        )
    , check "M2 typed extern table: an EXPORTED key carries its declared (param types, result) + markers; an unexported key the all-val fallback"
        ((case Dict.get "Rt.exec-run" rt.externTypes of
            Just sig ->
                Ast.splitArrow sig.ty == ( [ Ast.OVal, Ast.OVal, Ast.OVal ], Ast.OVal )
                    && sig.effects == [ Ast.Io ]
                    && not sig.taint

            Nothing ->
                False
         )
            && (case Dict.get "Rt.getpid" rt.externTypes of
                    Just sig ->
                        externArity sig == 1 && Ast.splitArrow sig.ty == ( [ Ast.OVal ], Ast.OVal )

                    Nothing ->
                        False
               )
        )
    , check "M2 header: the runtime.mid module is named Rt and its export block names the crossed keys (read-file-as-string, exec-run, main, frame-enter, frame-leave)"
        (rt.header.name == Just "Rt"
            && List.map .key rt.header.exports
            == [ "Rt.read-file-as-string", "Rt.exec-run", "Rt.main", "Rt.frame-enter", "Rt.frame-leave" ]
        )

    -- ==================== M3: user .mid modules ====================
    -- The namespace rule (the module NAME qualifies every key), the SAME
    -- Parse->Check->LowerToIr pipeline as runtime.mid, and the collision
    -- rules defined against the export block's namespace.
    , check "M3 namespace: a well-formed user module parses, and its keys are module-name-qualified defuns"
        (case Rt.parseUserModule ("module UserMid\nexport UserMid.answer : val -> val -> val\ndefun UserMid.answer(a: val, b: val) -> val {\n  return mknum(payload(a, 0) + payload(b, 0));\n}") of
            Ok ( name, exports, ast ) ->
                name
                    == "UserMid"
                    && List.map .key exports
                    == [ "UserMid.answer" ]
                    && List.map .key ast
                    == [ "UserMid.answer" ]

            Err _ ->
                False
        )
    , check "M3 namespace: a user module with NO `module Name` header is a LOUD reject (a key needs a namespace)"
        (case Rt.parseUserModule "defun X.f() -> val { return mknil; }" of
            Err msg ->
                String.contains "no `module Name` header" msg

            Ok _ ->
                False
        )
    , check "M3 namespace: a key not qualified by the module name is a LOUD reject (a module owns only its own keys)"
        (case Rt.parseUserModule "module A\ndefun B.f() -> val { return mknil; }" of
            Err msg ->
                String.contains "not qualified by the module name" msg

            Ok _ ->
                False
        )
    , check "M3 pipeline: a user module checks+lowers through the SAME RtLang pipeline and lands as a Mid.Ir defun under its qualified key"
        (case Rt.parseUserModule ("module UserMid\nexport UserMid.answer : val -> val -> val\ndefun UserMid.answer(a: val, b: val) -> val {\n  return mknum(payload(a, 0) + payload(b, 0));\n}") of
            Err msg ->
                False

            Ok parsed ->
                case Rt.checkLowerUserModule rt.externTypes parsed of
                    Ok m ->
                        List.map .key m.defuns == [ "UserMid.answer" ]

                    Err _ ->
                        False
        )
    , check "M3 collision (a): a user key in the Rt.* namespace is a LOUD reject (the reserved compiler-internal namespace)"
        (case QbeModule.userCollisions Dict.empty [ mkUser "X" [ "Rt.foo" ] ] of
            Err msg ->
                String.contains "reserved Rt.* namespace" msg

            Ok () ->
                False
        )
    , check "M3 collision (b): two user modules claiming the same key is a LOUD reject"
        (case QbeModule.userCollisions Dict.empty [ mkUser "A" [ "A.f" ], mkUser "A" [ "A.f" ] ] of
            Err msg ->
                String.contains "defined by two modules" msg

            Ok () ->
                False
        )
    , check "M3 collision (bonus): a user key colliding with an Elm global is a LOUD reject"
        (case QbeModule.userCollisions (Dict.fromList [ ( "A.f", 1 ) ]) [ mkUser "A" [ "A.f" ] ] of
            Err msg ->
                String.contains "collides with an Elm global" msg

            Ok () ->
                False
        )
    , check "M3 collision accept: disjoint user modules (and no Elm overlap) pass"
        (QbeModule.userCollisions Dict.empty [ mkUser "A" [ "A.f" ], mkUser "B" [ "B.g" ] ] == Ok ())

    -- ==================== M3fix: the privacy boundary + the audit span ====================
    -- The user lane's extern table is the runtime's EXPORT BLOCK ONLY (the
    -- exportedTypes field), so an unexported runtime key is unresolvable from a
    -- user module — while an exported one still resolves.
    , check "M3fix privacy REJECT: a user .mid cannot `call Rt.getpid` (an UNEXPORTED runtime key) — the user lane's extern table is the runtime export block only"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call Rt.getpid(a);\n}" ] of
            Err msg ->
                String.contains "unseeded key" msg && String.contains "Rt.getpid" msg

            Ok _ ->
                False
        )
    , check "M3fix privacy ACCEPT: a user .mid CAN `call Rt.exec-run` (an EXPORTED runtime key) and it resolves at the declared arity"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call Rt.exec-run(a, a, a);\n}" ] of
            Ok _ ->
                True

            Err _ ->
                False
        )
    , check "M3fix audit span: a user .mid is the SANCTIONED unsafe lane — mknum/rawcall(getpid) lower through the RtLang checker (J1/J3) to a defun the audit never sees"
        (case Rt.parseUserModule "module A\nexport A.pid : val -> val\ndefun A.pid(dummy: val) -> val {\n  return mknum(rawcall getpid());\n}" of
            Ok parsed ->
                case Rt.checkLowerUserModule rt.exportedTypes parsed of
                    Ok m ->
                        not (List.isEmpty m.defuns)

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "M3fix cross-module (CHECK phase): a user defun called ONLY from another .mid resolves through the cross-module extern table (J2) and LowerToIr-lowers to a defun at the right arity"
        (case QbeModule.loadUserMids rt
            [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call B.g(a);\n}"
            , "module B\nexport B.g : val -> val\ndefun B.g(a: val) -> val {\n  return mknum(payload(a, 0) + 5);\n}"
            ] of
            Ok [ mA, mB ] ->
                midKeyArity "A.f" mA == Just 1 && midKeyArity "B.g" mB == Just 1

            Ok _ ->
                False

            Err _ ->
                False
        )
    , check "M3fix-4 (a) EMIT: a user .mid `call` to ANOTHER user module's exported defun is accepted and emitted — the callee joins the reachable set (its RawCall edge) and the call uses the CALLEE's ABI (RtGeneric: :ret/rt_bounce), never the lean Rt shape"
        (case QbeModule.loadUserMids rt
            [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call B.g(a);\n}"
            , "module B\nexport B.g : val -> val\ndefun B.g(a: val) -> val {\n  return mknum(payload(a, 0) + 5);\n}"
            ] of
            Ok [ mA, mB ] ->
                case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (Dict.fromList [ ( "A.f", 1 ), ( "B.g", 1 ) ]) (mA.defuns ++ mB.defuns) "A.f" of
                    Ok mod ->
                        let
                            ssa =
                                Print.print mod
                        in
                        -- the call is the GENERIC shape ... and NOT the lean one:
                        -- the lean 4-arg shape against a 1-:val-param callee is
                        -- the ABI clash MEASURED as a SEGFAULT in the first cut
                        -- of this fix (the shape is keyed on the CALLEE).
                        String.contains ":ret call $q_B_x2eg" ssa
                            && not (String.contains ":val call $q_B_x2eg" ssa)

                    Err _ ->
                        False

            Ok _ ->
                False

            Err _ ->
                False
        )
    , check "M3fix-4 (b): a user .mid `call` naming a key that is NO defun of this program is still a LOUD Err ('not a defun of this program') — the acceptance widened to member keys, so this arm is what still stops a call to nothing"
        (case Rt.parseUserModule "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call B.g(a);\n}" of
            Ok parsed ->
                case Rt.checkLowerUserModule (Dict.fromList [ ( "B.g", { ty = Ast.valArity 1, effects = [], taint = False } ) ]) parsed of
                    Ok mA ->
                        case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (Dict.fromList [ ( "A.f", 1 ) ]) mA.defuns "A.f" of
                            Err msg ->
                                String.contains "rawCall to B.g" msg && String.contains "not a defun of this program" msg

                            Ok _ ->
                                False

                    Err _ ->
                        False

            Err _ ->
                False
        )
    -- M3-rtcall: the EXPORTED-key trap M3fix-4 left open (a user .mid may
    -- `call Rt.<exported>` at J2 but the callee was never SEEDED, so the
    -- emitted `q_Rt_*` was a link error).  The fix is the CENSUS: grefsOf now
    -- reports a RawCall to ANY program defun (Rt keys included), so `reach`
    -- pulls the exported callee AND its body's own Rt->Rt closure into the
    -- emitted surface — computed from the ACTUAL user-mid call graph, not
    -- guessed (the same edges Mid.Rt.rtDeps declares by hand, which the
    -- "rt call graph" row pins as agreeing).
    , check "M3-rtcall seed: a user .mid `call Rt.read-file-as-string` (an EXPORTED runtime key) seeds that Rt defun AND its body closure into the emitted set, and the call site is the callee's LEAN ABI (Rt key + rtLean, never rt_bounce)"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call Rt.read-file-as-string(a);\n}" ] of
            Ok [ mA ] ->
                let
                    prog =
                        rtProgram rt True True True ++ mA.defuns
                in
                case QbeLower.lower rt False False False True True True True False False QbeTypes.empty (rtArities prog) prog "A.f" of
                    Ok mod ->
                        let
                            ssa =
                                Print.print mod
                        in
                        -- the exported callee IS emitted (this is the
                        -- fail-before: without the grefsOf edge it is absent
                        -- and the call would be a dangling q_Rt_*), its
                        -- transitive closure too (readFileGo, reached through
                        -- the Rt body's own RawCall edge), and the call is the
                        -- lean 4-slot shape, not the generic rt_bounce.
                        List.any (\f -> f.name == "q_Rt_x2eread_x2dfile_x2das_x2dstring") mod.funcs
                            && List.any (\f -> f.name == "q_Rt_x2ereadFileGo") mod.funcs
                            && String.contains ":val call $q_Rt_x2eread_x2dfile_x2das_x2dstring" ssa

                    Err _ ->
                        False

            _ ->
                False
        )
    , check "M3-rtcall uncallable: Rt.main (word -> word -> word, the rawAbi driver entry) is NOT val-callable — a user .mid `call Rt.main` with :val args is a LOUD J2 class reject ('needs word, got val'), never a link error"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.f(a: val) -> val {\n  return call Rt.main(a, a);\n}" ] of
            Err msg ->
                String.contains "call 'Rt.main'" msg && String.contains "needs word" msg

            Ok _ ->
                False
        )

    -- ==================== M4: Osier-side checking + the import mapping ====================
    -- `exportScheme` maps an export block's DECLARED Osier type to the checker
    -- scheme an Osier reference is checked against (§2.5's representation-pinned
    -- class mapping).  `word` is the rigid opaque `Word` (no Osier value
    -- inhabits it — see QbeModule.exportScheme's doc for the enforcement and
    -- the one honest leak); `float` is `Float`; `val`/unknown are fresh boxed
    -- vars; the declared arrow shape is the arity.
    , check "M4 exportScheme: val -> val -> val maps to a 2-param curried scheme of three DISTINCT fresh boxed vars"
        (case (QbeModule.exportScheme { ty = Ast.OArrow Ast.OVal (Ast.OArrow Ast.OVal Ast.OVal), effects = [], taint = False }).body of
            Rep.TFun (Rep.TVar a) (Rep.TFun (Rep.TVar b) (Rep.TVar c)) ->
                a.id /= b.id && b.id /= c.id && a.id /= c.id

            _ ->
                False
        )
    , check "M4 exportScheme: word -> val maps `word` to the rigid opaque Word (a TCon no Osier value inhabits), val to a fresh var"
        (case (QbeModule.exportScheme { ty = Ast.OArrow Ast.OWord Ast.OVal, effects = [], taint = False }).body of
            Rep.TFun (Rep.TCon "Word" []) (Rep.TVar _) ->
                True

            _ ->
                False
        )
    , check "M4 exportScheme: float -> val maps `float` to Float (boxed, ABI-pinned)"
        (case (QbeModule.exportScheme { ty = Ast.OArrow Ast.OFloat Ast.OVal, effects = [], taint = False }).body of
            Rep.TFun (Rep.TCon "Float" []) (Rep.TVar _) ->
                True

            _ ->
                False
        )
    , check "M4 exportScheme: Word -> val (the UPPERCASE opaque-word spelling) is the SAME rigid Word as the lowercase `word` atom"
        (case (QbeModule.exportScheme { ty = Ast.OArrow (Ast.OCon "Word" []) Ast.OVal, effects = [], taint = False }).body of
            Rep.TFun (Rep.TCon "Word" []) (Rep.TVar _) ->
                True

            _ ->
                False
        )
    , check "M4 exportScheme: Int -> val maps `Int` to the Elm Int scalar"
        (case (QbeModule.exportScheme { ty = Ast.OArrow (Ast.OCon "Int" []) Ast.OVal, effects = [], taint = False }).body of
            Rep.TFun (Rep.TCon "Int" []) (Rep.TVar _) ->
                True

            _ ->
                False
        )
    , check "M4 exportScheme: forall s. Ref s -> val (the M2-fix quantifier unwrap) still flattens to ONE param, with Ref s the conservative boxed-var default"
        (case (QbeModule.exportScheme { ty = Ast.OForall "s" (Ast.OArrow (Ast.OCon "Ref" [ Ast.OVar "s" ]) Ast.OVal), effects = [], taint = False }).body of
            Rep.TFun (Rep.TVar _) (Rep.TVar _) ->
                True

            _ ->
                False
        )
    , check "M4 exportScheme: the !io/!taint markers are CARRIED on the export sig (contract 3/4 statement, not enforcement)"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val !io !taint\ndefun A.f(a: val) -> val {\n  return mknil;\n}" ] of
            Ok [ mA ] ->
                case mA.exports of
                    [ e ] ->
                        e.sig.effects == [ Ast.Io ] && e.sig.taint

                    _ ->
                        False

            _ ->
                False
        )

    -- ============ M4-enforce U1: contract-4 return-taint floor ============
    -- The pure-core rows over Mid.TaintCheck (synthetic single-file groups,
    -- tainted key `Tainty.make`).  The REJECT rows are the fail-before oracle
    -- (each compiles on the pre-U1 compiler); the ACCEPT rows are the
    -- over-tightening net (the owner's let + self-recursive case MUST stay
    -- legal — head position contributes RESULT taint, value position CAPTURE
    -- taint).
    , check "taint: direct mid result is rejected"
        (taintRejected "module T exposing (main)\n\nmain =\n    Tainty.make 1\n")
    , check "taint: a returned closure capturing a tainted binder is rejected"
        (taintRejected "module T exposing (main)\n\nmain =\n    let\n        t =\n            Tainty.make 1\n    in\n    \\y -> t\n")
    , check "taint: a tainted helper's result propagates to its caller (least fixpoint)"
        (taintRejected "module T exposing (main)\n\nhelper x =\n    Tainty.make x\n\nmain =\n    helper 1\n")
    , check "taint: the owner's let + self-recursive-lambda case is LEGAL (invoked, not returned)"
        (taintAccepted "module T exposing (main)\n\nmain =\n    let\n        t =\n            Tainty.make 1\n\n        go n =\n            if n == 0 then\n                42\n\n            else\n                let\n                    _ =\n                        t\n                in\n                go (n - 1)\n    in\n    go 5\n")
    , check "taint: local use is unrestricted (bound, discarded, return 42)"
        (taintAccepted "module T exposing (main)\n\nmain =\n    let\n        t =\n            Tainty.make 1\n\n        _ =\n            t\n    in\n    42\n")
    , check "taint: a derived value ([t]) used locally and discarded is legal"
        (taintAccepted "module T exposing (main)\n\nmain =\n    let\n        t =\n            Tainty.make 1\n\n        _ =\n            [ t ]\n    in\n    42\n")
    , check "taint: returning a capture-free lambda that CALLS mid is legal (Phase-7 a -> T)"
        (taintAccepted "module T exposing (main)\n\nmain =\n    \\y -> Tainty.make y\n")
    , check "taint: an inner let shadowing the outer tainted binder is legal"
        (taintAccepted "module T exposing (main)\n\nmain =\n    let\n        t =\n            Tainty.make 1\n    in\n    let\n        t =\n            42\n    in\n    t\n")
    , check "taint: mutually recursive clean functions stay legal (least fixpoint over the group)"
        (taintAccepted "module T exposing (main)\n\nmain =\n    let\n        f n =\n            if n == 0 then\n                42\n\n            else\n                g (n - 1)\n\n        g n =\n            if n == 0 then\n                42\n\n            else\n                f (n - 1)\n    in\n    f 5\n")
    , check "taint: the reject error names the tainted export"
        (case taintCheck "module T exposing (main)\n\nmain =\n    Tainty.make 1\n" of
            Err msg ->
                String.contains "Tainty.make" msg

            Ok () ->
                False
        )

    -- ==================== TIER-2 T4: the typechecker J1-J6 ====================
    -- (Mid.RtLang.Check — checkProgram over the parsed Ast).  Each judgment
    -- gets an ACCEPT row plus REJECT rows whose message names it (the
    -- fail-before rows: a checker with that judgment deleted turns its
    -- rejects RED — proven below for J1's cond class and J4's arity by
    -- disabling the check).  Sources are REAL inputs a plausible author
    -- writes; the fragment pin guards against a vacuous red (a parse
    -- failure would Err without the fragment).  Nothing outside TestMain
    -- imports Check yet (T7 wires it) — the corpus stays the emit-inert
    -- oracle.

    -- ---- J1: fixed operand/result classes ----
    , checkOk "check: J1 accept — the getpid shape (rawcall, word bind, mknum)"
        "defun Rt.getpid() -> val {\n  word w = rawcall getpid();\n  return mknum(w);\n}"
    , checkOk "check: J1 accept — operator/builtin classes (word ops, boxed cmp, && ||, itof/mkflt, vecstore)"
        "defun Rt.rich(a: val) -> val {\n  word p = payload(a, 0);\n  word n = payload(a, 0);\n  val c = mkbool(n == 1);\n  val d = mknum(n);\n  val e = c && d;\n  vecstore(p, 0, e);\n  val g = mkflt(itof(n));\n  return e || g;\n}"
    , checkErr "check: J1 REJECT — a val used where a word operator operand is required"
        "J1"
        "defun Rt.badop(a: val) -> val {\n  word n = a + 1;\n  return mknum(n);\n}"
    , checkErr "check: J1 REJECT — an unboxed word compare as an if condition"
        "J1"
        "defun Rt.badcond(n: word) -> val {\n  if (n == 1) { return mknil; } else { return mkbool(1); }\n}"
    , checkErr "check: J1 REJECT — a builtin called with the wrong arity (mkstr needs 2)"
        "J1"
        "defun Rt.badmkstr(a: val) -> val {\n  val s = mkstr(a);\n  return s;\n}"
    , checkErr "check: J1 REJECT — an int literal where a float word is required"
        "J1"
        "defun Rt.badflt(n: word) -> val {\n  val g = mkflt(2);\n  return g;\n}"
    , checkErr "check: J1 REJECT — a float binder (float words are not let-bindable)"
        "J1"
        "defun Rt.badfloatbinder(n: word) -> val {\n  float x = itof(n);\n  return mkflt(x);\n}"
    , checkErr "check: J1 REJECT — a binder whose initializer class differs from its declaration"
        "J1"
        "defun Rt.badbind(a: val) -> val {\n  word n = mknil;\n  return mknum(n);\n}"

    -- ---- J2: call resolution, arity, val discipline ----
    , checkOk "check: J2 accept — a surface call resolves order-independently (callee defined later)"
        "defun Rt.two() -> val {\n  return call Rt.one();\n}\n\ndefun Rt.one() -> val {\n  return mknum(1);\n}"
    , check "check: J2 accept — an extern seat resolves through the extern table"
        (case Parse.parseProgram "defun Rt.caller() -> val {\n  return call Rt.getpid();\n}" of
            Ok program ->
                Check.checkProgram
                    (Dict.fromList [ ( "Rt.getpid", { ty = Ast.valArity 0, effects = [], taint = False } ) ])
                    []
                    program
                    == Ok ()

            Err _ ->
                False
        )
    , checkErr "check: J2 REJECT — a call target that is not a full Rt.* key"
        "J2"
        "defun Rt.badkey() -> val {\n  return call getpid();\n}"
    , checkErr "check: J2 REJECT — an unseeded call target (no surface defun, no extern)"
        "J2"
        "defun Rt.unseeded() -> val {\n  return call Rt.nosuchfn();\n}"
    , checkErr "check: J2 REJECT — a call whose arity exceeds the callee's"
        "J2"
        "defun Rt.overcall() -> val {\n  return call Rt.one(mknum(1));\n}\n\ndefun Rt.one() -> val {\n  return mknum(1);\n}"
    , checkErr "check: J2 REJECT — a val passed to a word-parameter callee"
        "J2"
        "defun Rt.wrongarg(a: val) -> val {\n  return call Rt.wid(a);\n}\n\ndefun Rt.wid(x: word) -> val {\n  return mknum(x);\n}"

    -- ---- J3: rawcall signature table ----
    , checkOk "check: J3 accept — a tabled rawcall with word args (write/3)"
        "defun Rt.wr(w: word) -> val {\n  word r = rawcall write(w, 1, 2);\n  return mknum(r);\n}"
    , checkErr "check: J3 REJECT — a rawcall symbol absent from the signature table"
        "J3"
        "defun Rt.badsym() -> val {\n  word r = rawcall nosuchseat(1);\n  return mknum(r);\n}"
    , checkErr "check: J3 REJECT — a rawcall whose arg count differs from the table (getpid/0)"
        "J3"
        "defun Rt.badrawarity() -> val {\n  word r = rawcall getpid(1);\n  return mknum(r);\n}"
    , checkErr "check: J3 REJECT — a val passed into an all-word rawcall"
        "J3"
        "defun Rt.badrawarg(a: val) -> val {\n  word r = rawcall write(a, 0, 0);\n  return mknum(r);\n}"

    -- ---- J4: recur saturation (the loop-demotion hazard) ----
    , checkOk "check: J4 accept — a saturated recur (2 args, 2 params)"
        "defun Rt.loop(a: val, b: val) -> val {\n  recur(a, b);\n}"
    , checkOk "check: J4 accept — the 0-arity boundary (recur() in a 0-param defun)"
        "defun Rt.recur0() -> val {\n  recur();\n}"
    , checkErr "check: J4 REJECT — an UNSATURATED recur (the loop would silently stop being a loop)"
        "J4"
        "defun Rt.loop2(a: val, b: val) -> val {\n  recur(a);\n}"
    , checkErr "check: J4 REJECT — an oversaturated recur"
        "J4"
        "defun Rt.loop1(a: val) -> val {\n  recur(a, a);\n}"
    , checkErr "check: J4 REJECT — a recur argument class differing from its parameter"
        "J4"
        "defun Rt.loopcls(n: val) -> val {\n  recur(1);\n}"

    -- ---- J5: scope discipline (strict order, no pre-collection) ----
    , checkOk "check: J5 accept — a shadowing initializer still sees the OUTER binding"
        "defun Rt.shadow(a: val) -> val {\n  word a = payload(a, 0);\n  return mkbool(a == 1);\n}"
    , checkErr "check: J5 REJECT — an unbound name"
        "J5"
        "defun Rt.unbound() -> val {\n  return n;\n}"
    , checkErr "check: J5 REJECT — a name used before its binding statement (strict order)"
        "J5"
        "defun Rt.before() -> val {\n  word y = k + 1;\n  word k = 1;\n  return mknum(y);\n}"
    , checkErr "check: J5 REJECT — duplicate parameters"
        "J5"
        "defun Rt.dup(a: val, a: val) -> val {\n  return a;\n}"

    -- ---- J6: return class matches the declared -> ty ----
    , checkOk "check: J6 accept — a word defun returning a word"
        "defun Rt.wret(a: val) -> word {\n  return payload(a, 0);\n}"
    , checkErr "check: J6 REJECT — a raw word returned from a -> val defun"
        "J6"
        "defun Rt.badret1() -> val {\n  return 1;\n}"
    , checkErr "check: J6 REJECT — a value returned from a -> word defun"
        "J6"
        "defun Rt.badret2() -> word {\n  return mknil;\n}"

    -- ---- program shape: the namespace-qualified key rule (M3: the Rt.*
    -- rule generalized — a bare key has no namespace to route a call to) ----
    , checkErr "check: REJECT — a defun keyed without a namespace (uncallable, unlowerable)"
        "must be namespace-qualified"
        "defun getpid() -> val {\n  return mknil;\n}"

    -- ==================== TIER-2 T5: the typechecker J7-J10 ====================
    -- The remaining judgments.  J7's rows lean on a MEASURED grammar fact:
    -- every block ends in a terminator (`return`/`recur`/`if`), so a
    -- "fall-through" branch always bottoms out at a terminating `if` with
    -- NO else — the only fall-through spelling the grammar has.  J8's rows
    -- go through the Flags drivers: the active flag set is the checker's
    -- parameter.  J9 has NO rows here BY DESIGN: allocating/safepoint is
    -- DERIVED from the produced tree (Mid.rt.allocating's fixed point,
    -- plan fact F3); the partition rows above are the enforcement.

    -- ---- J7: the mid-block divergence rule (plan L6, the honest floor) ----
    , checkOk "check: J7 accept — a mid-block if with ONE diverging branch (the else-nesting shape: the false path is the continuation)"
        "defun Rt.divacc(region: val) -> val {\n  if (mkbool(tagis(region, 1) == 1)) { return mknum(1); }\n  word base = rawcall getpid();\n  return mknum(base);\n}"
    , checkOk "check: J7 accept — the ELSE diverges while the then-branch falls through (one diverging branch suffices)"
        "defun Rt.divelse(n: val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); }\n  }\n  else { return mknum(2); }\n  return mknil;\n}"
    , checkOk "check: J7 accept — the nested pin's control: with the inner else present the branch's terminating if diverges on both arms, so the BRANCH diverges"
        "defun Rt.divnestok(n: val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); } else { return mknum(9); }\n  }\n  return mknum(3);\n}"
    , checkErr "check: J7 REJECT — a mid-block if with BOTH branches falling through (no join is invented)"
        "J7"
        "defun Rt.divboth(n: val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); }\n  }\n  else {\n    if (mkbool(tagis(n, 3) == 1)) { return mknum(2); }\n  }\n  return mknum(3);\n}"
    , checkErr "check: J7 REJECT — a deeper one-sided divergent if does NOT make the branch diverging (divergence is the terminator, BOTH TIf arms required)"
        "J7"
        "defun Rt.divnest(n: val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); }\n  }\n  return mknum(3);\n}"
    , checkErr "check: J7 REJECT — a TERMINATING if with no else whose then-branch falls through (L5: else is required except when the then diverges)"
        "J7"
        "defun Rt.divnoelse(n: val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); }\n  }\n}"

    -- ---- J8: @flag guard exclusivity (the active flag set is a parameter) ----
    , checkOkFlags "check: J8 accept — a guarded defun with its flag active (exactly one active definition for the key)"
        [ Ast.EqPtrFast ]
        "@eqPtrFast defun Rt.gfast() -> val {\n  return mknil;\n}"
    , checkOkFlags "check: J8 accept — complementary @rec/@!rec variants: exactly one active per flag combination, one logical key"
        [ Ast.Rec, Ast.ConsArr ]
        "@rec defun Rt.gvar(a: val) -> val {\n  recur(a);\n}\n\n@!rec defun Rt.gvar(a: val) -> val {\n  return a;\n}"
    , checkErrFlags "check: J8 REJECT — two guarded defuns for one key both active"
        [ Ast.Rec ]
        "J8"
        "@rec defun Rt.twice() -> val {\n  return mknil;\n}\n\n@rec defun Rt.twice() -> val {\n  return mknil;\n}"
    , checkErrFlags "check: J8 REJECT — zero active defuns for a key (the lone guard fails under the flag set)"
        []
        "J8"
        "@rec defun Rt.gone() -> val {\n  return mknil;\n}"
    , checkErr "check: J8 REJECT — duplicate unguarded keys are two active variants (the T4 last-wins note, closed loudly)"
        "J8"
        "defun Rt.dupkey() -> val {\n  return mknil;\n}\n\ndefun Rt.dupkey() -> val {\n  return mknil;\n}"

    -- ---- J10: withroots ids must be :val binders in scope ----
    , checkOk "check: J10 accept — withroots [x] where x is a :val parameter"
        "defun Rt.wracc(x: val) -> val {\n  val r = withroots [x] { return x; };\n  return r;\n}"
    , checkOk "check: J10 accept — withroots over an earlier :val binder (in scope at that point, not just parameters)"
        "defun Rt.wrlocal(x: val) -> val {\n  val v = mknum(1);\n  val r = withroots [v] { return v; };\n  return r;\n}"
    , checkErr "check: J10 REJECT — a withroots id that is not a binder in scope"
        "J10"
        "defun Rt.wrunk(x: val) -> val {\n  val r = withroots [nosuch] { return mknil; };\n  return r;\n}"
    , checkErr "check: J10 REJECT — a :word binder cannot be rooted"
        "J10"
        "defun Rt.wrw(x: val) -> val {\n  word w = payload(x, 0);\n  val r = withroots [w] { return mknil; };\n  return r;\n}"

    -- ==================== TIER-2 T6: the lowerer ====================
    -- (Mid.RtLang.LowerToIr — a checked Ast -> List Mid.Ir.Defun, the
    -- plan's L1-L7).  Each row lowers a REAL surface program (the `lowl`
    -- driver: parse + Check + lower) and compares the tree against a
    -- HAND-BUILT expected tree written with the SAME helper shapes
    -- RtPrims/RtGc build their defuns with (llets/liff/land2/... mirror
    -- lets/iff/and2).  The comparison is `canon`-normalized SHAPE
    -- equality: binder ids are renumbered in first-appearance order (they
    -- are Dict keys the backend never emits — plan fact F1 — but a
    -- wrong-Var or id-collision bug still shows, because every Var is
    -- renumbered consistently with ITS binder), binder names are zeroed
    -- (provenance only) and the invented If/ShortAnd label strings are
    -- zeroed (F1: Lower invents its own labels and never reads these).
    -- Everything else — constructors, argument order, GRef key/force,
    -- tag constants, symbol strings, literal payloads — must be EXACT.
    -- The last two rows are COMPILE-BACKS: a real DSL defun's surface
    -- form must lower to shape-identity with RtPrims' own tree.

    -- L3 + the defun shape (a full small defun)
    , check "lower: a full small defun — the last return is the Lam body; rawcall/mknum 1:1"
        (case lowlBody "defun Rt.getpid(x : val) -> val {\n  return mknum(rawcall getpid());\n}" of
            Ok body ->
                canon body == canon (lmkNum (lcallW "getpid" []))

            Err _ ->
                False
        )

    -- L1: statement nesting order
    , check "lower: L1 — each statement is ONE 1-binder Let nested to the LEFT around the rest"
        (case lowlBody "defun Rt.ord3(a : val) -> val {\n  word x = payload(a, 0);\n  word y = x + 1;\n  word z = y + 1;\n  return mknum(z);\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, Unsafe (RawPayload { value = ltv 1, word = 0 }) )
                            , ( ltb 3, liadd (ltv 2) (ltn 1) )
                            , ( ltb 4, liadd (ltv 3) (ltn 1) )
                            ]
                            (lmkNum (ltv 4))
                        )

            Err _ ->
                False
        )

    , check "lower: the surface id rides on the Binder as provenance; uses stay Var-by-id"
        (case lowlBody "defun Rt.names(a : val) -> val {\n  word x = payload(a, 0);\n  return mknum(x);\n}" of
            Ok body ->
                case body of
                    Let lb ->
                        case lb.binders of
                            [ LetBind ib ] ->
                                ib.binder.name
                                    == "x"
                                    && (case lb.body of
                                            Unsafe (RawMkValue m) ->
                                                m.words == [ Var ib.binder.id ]

                                            _ ->
                                                False
                                       )

                            _ ->
                                False

                    _ ->
                        False

            Err _ ->
                False
        )

    -- L2: the effect statement's fresh dead binder
    , check "lower: L2 — an effect statement dead-binds at a fresh UNUSED binder (the (b 107, rStore ..) shape)"
        (case lowlBody "defun Rt.eff(a : val) -> val {\n  rawcall getpid();\n  return mknil;\n}" of
            Ok body ->
                canon body == canon (llets [ ( ltb 2, lcallW "getpid" [] ) ] lmkNilV)

            Err _ ->
                False
        )

    -- L4: the self-tail loop
    , check "lower: L4 — recur is App{fn = GRef OWN key, force = False}, args in param order (THE ONLY LOOP)"
        (case lowlBody "defun Rt.loop(a : val, b : val) -> val {\n  recur(a, b);\n}" of
            Ok body ->
                canon body
                    == canon (App { fn = GRef { key = "Rt.loop", force = False }, args = [ ltv 1, ltv 2 ] })

            Err _ ->
                False
        )

    -- L5: the terminating if
    , check "lower: L5 — a terminating if with both branches lowers to If (branch values in order)"
        (case lowlBody "defun Rt.if2(n : val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) { return mknum(1); } else { return mknum(2); }\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                            (lmkNum (ltn 1))
                            (lmkNum (ltn 2))
                        )

            Err _ ->
                False
        )

    , check "lower: L5 — a terminating if with NO else and a diverging then: the false path is the DSL's mknil dead value"
        (case lowlBody "defun Rt.ifno(n : val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) { return mknum(1); }\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                            (lmkNum (ltn 1))
                            lmkNilV
                        )

            Err _ ->
                False
        )

    -- L6: the mid-block if (the owner's example shape)
    , check "lower: L6 — a mid-block if with a diverging THEN nests the whole continuation in the ELSE branch"
        (case lowlBody "defun Rt.guard(region : val) -> val {\n  if (mkbool(payload(region, 0) != 0)) { return mknum(payload(region, 0)); }\n  word base = rawcall getpid();\n  return mknum(base);\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lmkBool (lcmpW RCne (lwOf (ltv 1)) (ltn 0)))
                            (lmkNum (lwOf (ltv 1)))
                            (llets [ ( ltb 2, lcallW "getpid" [] ) ] (lmkNum (ltv 2)))
                        )

            Err _ ->
                False
        )

    , check "lower: L6 — a mid-block if with a diverging ELSE: the continuation splices into the THEN branch's fall-through slot (the T5 divelse shape)"
        (case lowlBody "defun Rt.divelse(n : val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) {\n    if (mkbool(tagis(n, 2) == 1)) { return mknum(1); }\n  }\n  else { return mknum(2); }\n  return mknil;\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                            (liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 2) (ltn 1)))
                                (lmkNum (ltn 1))
                                lmkNilV
                            )
                            (lmkNum (ltn 2))
                        )

            Err _ ->
                False
        )

    , check "lower: L6 — both branches diverging: the If dead-binds at a fresh unused binder and the continuation continues (the execGo (b 106, callW _exit ..) precedent)"
        (case lowlBody "defun Rt.bothdiv(n : val) -> val {\n  if (mkbool(tagis(n, 1) == 1)) { return mknum(1); } else { return mknum(2); }\n  return mknil;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                                    (lmkNum (ltn 1))
                                    (lmkNum (ltn 2))
                              )
                            ]
                            lmkNilV
                        )

            Err _ ->
                False
        )

    -- operators
    , check "lower: precedence round-trips onto the raw nodes (b*c before +, - left-associative)"
        (case lowlBody "defun Rt.prec(a : val, b : val, c : val, d : val) -> val {\n  return mknum(payload(a, 0) + payload(b, 0) * payload(c, 0) - payload(d, 0));\n}" of
            Ok body ->
                canon body
                    == canon
                        (lmkNum
                            (lisub (liadd (lwOf (ltv 1)) (limul (lwOf (ltv 2)) (lwOf (ltv 3))))
                                (lwOf (ltv 4))
                            )
                        )

            Err _ ->
                False
        )

    , check "lower: bitwise/shift families map 1:1 (& | ^, << arithmetic >>, >>> zero-fill; & tighter than |, ^ between)"
        (case lowlBody "defun Rt.bits(a : val) -> val {\n  word x = payload(a, 0);\n  return mkbool((x << 1 >> 2 >>> 3) == (x & 1 | 2 ^ 3));\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets [ ( ltb 2, lwOf (ltv 1) ) ]
                            (lmkBool
                                (lcmpW RCeq
                                    (lshr (lsar (lshl (ltv 2) (ltn 1)) (ltn 2)) (ltn 3))
                                    (lior (liand (ltv 2) (ltn 1)) (lixor (ltn 2) (ltn 3)))
                                )
                            )
                        )

            Err _ ->
                False
        )

    , check "lower: the float family (f* binds tighter than f+, f-cmp is a boxed word)"
        (case lowlBody "defun Rt.flt(n : val) -> val {\n  return mkbool(fload(n) f+ itof(payload(n, 0)) f* 1.5 f< fload(n));\n}" of
            Ok body ->
                canon body
                    == canon
                        (lmkBool
                            (lfcmp RFLt
                                (lfbin RFAdd (lfl (ltv 1)) (lfbin RFMul (litof (lwOf (ltv 1))) (lflt 1.5)))
                                (lfl (ltv 1))
                            )
                        )

            Err _ ->
                False
        )

    , check "lower: && || are ShortAnd/ShortOr verbatim, && tighter than ||"
        (case lowlBody "defun Rt.shorts(a : val) -> val {\n  return mkbool(tagis(a, 0) == 1) && mkbool(payload(a, 0) == 2) || mkbool(payload(a, 0) == 3);\n}" of
            Ok body ->
                canon body
                    == canon
                        (lor2
                            (land2
                                (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 0) (ltn 1)))
                                (lmkBool (lcmpW RCeq (lwOf (ltv 1)) (ltn 2)))
                            )
                            (lmkBool (lcmpW RCeq (lwOf (ltv 1)) (ltn 3)))
                        )

            Err _ ->
                False
        )

    -- the three call forms
    , check "lower: call/rawcall/aggcall 1:1 (RawCall Rt key, RawCallRaw sym, RawCallAgg shape) — aggcall as an L2 effect statement"
        (case lowlBody "defun Rt.calls(a : val) -> val {\n  word f = payload(a, 0);\n  aggcall ret f(1);\n  return call Rt.calls(mknum(rawcall getpid()));\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, lwOf (ltv 1) )
                            , ( ltb 3, Unsafe (RawCallAgg { fn = ltv 2, args = [ ltn 1 ], shape = "ret" }) )
                            ]
                            (lcallR "Rt.calls" [ lmkNum (lcallW "getpid" []) ])
                        )

            Err _ ->
                False
        )

    -- withroots
    , check "lower: withroots carries the listed binders' records and the block's value"
        (case lowlBody "defun Rt.wr(x : val) -> val {\n  val r = withroots [x] { return x; };\n  return r;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, Unsafe (WithRoots { binders = [ { id = 1, name = "x" } ], body = ltv 1 }) )
                            ]
                            (ltv 2)
                        )

            Err _ ->
                False
        )

    -- builtins
    , check "lower: the mk* family 1:1 (mkstr/mkvec words in order, mkflt takes the float word, payload indices as constants)"
        (case lowlBody "defun Rt.mks(a : val) -> val {\n  val s = mkstr(payload(a, 0), payload(a, 1));\n  val v = mkvec(payload(a, 0), 2);\n  val g = mkflt(itof(payload(a, 0)));\n  return s;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, lmkStr (lwOf (ltv 1)) (lpay (ltv 1) 1) )
                            , ( ltb 3, lmkVec (lwOf (ltv 1)) (ltn 2) )
                            , ( ltb 4, lmkFlt (litof (lwOf (ltv 1))) )
                            ]
                            (ltv 2)
                        )

            Err _ ->
                False
        )

    , check "lower: reclen expands to the RtPrims recLenOf macro tree (len * (1 - isNil), the nil-aware i32 length)"
        (case lowlBody "defun Rt.recl(a : val) -> val {\n  word n = reclen(a);\n  return mknum(n);\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , Unsafe
                                    (RawBin
                                        { op = RMul
                                        , a = Unsafe (RawPayload32 { value = ltv 1, word = 1 })
                                        , b =
                                            Unsafe
                                                (RawBin
                                                    { op = RSub
                                                    , a = ltn 1
                                                    , b = Unsafe (RawTagIs { value = ltv 1, tag = RtLayout.tagNil })
                                                    }
                                                )
                                        }
                                    )
                              )
                            ]
                            (lmkNum (ltv 2))
                        )

            Err _ ->
                False
        )

    , check "lower: the store builtins chain as L2 effect binds in statement order (vecstore then bytestore)"
        (case lowlBody "defun Rt.stores(a : val) -> val {\n  vecstore(payload(a, 0), 0, mknil);\n  bytestore(payload(a, 0), 1, 2);\n  return mknil;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, Unsafe (RawVecStore { vec = lwOf (ltv 1), index = ltn 0, value = lmkNilV }) )
                            , ( ltb 3, Unsafe (RawByteStore { ptr = lwOf (ltv 1), index = ltn 1, value = ltn 2 }) )
                            ]
                            lmkNilV
                        )

            Err _ ->
                False
        )

    -- compile-backs: real DSL defuns.  BOTH wave-1 compile-back rows
    -- (Rt.getpid, Rt.emptylist) were RETIRED at T8: they compared the
    -- surface lowering against the LIVE RtPrims builder, and those builders
    -- are deleted now — the shape pin they carried moved into the corpus
    -- byte-identity (the same trees must emit the same .ssa bytes) and the
    -- T8 splice rows (the built program IS the surface lowering).  The next
    -- compile-back pair belongs to the NEXT wave, written BEFORE its
    -- builders are deleted.

    -- program level
    , check "lower: multi-defun programs lower in input order with keys preserved, recur defun intact"
        (case lowl "defun Rt.one() -> val {\n  return mknum(1);\n}\n\ndefun Rt.two(a : val) -> val {\n  recur(a);\n}" of
            Ok ds ->
                List.map .key ds == [ "Rt.one", "Rt.two" ]
                    && (case ds of
                            [ d1, d2 ] ->
                                canon d1.value
                                    == canon (Lam { params = [], body = lmkNum (ltn 1) })
                                    && canon d2.value
                                        == canon
                                            (Lam
                                                { params = [ ltb 1 ]
                                                , body = App { fn = GRef { key = "Rt.two", force = False }, args = [ ltv 1 ] }
                                                }
                                            )

                            _ ->
                                False
                       )

            Err _ ->
                False
        )

    -- ===== T7 — the surface-pipeline wiring (handoff-osier-tier2-t7) =====
    -- T7 pinned the then-shipped EMPTY-source state; T8 landed the first six
    -- defuns, so the identity/empty rows became the post-migration invariants
    -- below (same teeth: the splice is total, surf's key set is exact, the
    -- extern table is total and flag-stable, and every migrated defun keeps
    -- the arity of the builder it replaced).  The corpus run is the
    -- byte-level oracle for the same facts (159/159 byte-identical).
    -- NOTE (T8fix review): this row is a DRIFT-GUARD, not an independent
    -- splice oracle — `program` IS splice(surf(activeFlags), dsl) by
    -- construction (Mid.Rt), so its real teeth are only against drift of
    -- `program`'s or `activeFlags`' DEFINITIONS; the corpus byte-identity
    -- and the t8SplicedRow structural rows are the independent oracles.
    , check
        "T8/T18 wiring (T7's identity row, post-T18): for all 8 flag combos, the union splice (prim ++ helper ++ gcProgram) and the pair (primHalf, gcHalf) agree — the gc defuns replace at their gcProgram positions, the split is order-preserving within each half, and nothing duplicates (stage 6 U2: the appended Rt.die/Rt.halt move from the splice's tail into the END of the prim half — the partition contract)"
        (List.all
            (\combo ->
                case ( rt.surf combo.flags, rt.programPair combo.c combo.r combo.e ) of
                    ( Ok s, Ok ( p, g ) ) ->
                        case Rt.spliceSurface s (RtPrims.primDefuns combo.c combo.r combo.e ++ RtPrims.helperDefuns combo.r ++ RtGc.gcProgram) of
                            Ok spliced ->
                                let
                                    gcKeySet =
                                        Set.fromList (List.map .key RtGc.gcProgram)
                                in
                                List.sort (List.map .key (p ++ g)) == List.sort (List.map .key spliced)
                                    && List.length (p ++ g) == List.length spliced
                                    && List.map .key g == List.map .key (List.filter (\d -> Set.member d.key gcKeySet) spliced)

                            Err _ ->
                                False

                    _ ->
                        False
            )
            [ { c = True, r = True, e = True, flags = [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] }
            , { c = True, r = True, e = False, flags = [ Ast.ConsArr, Ast.Rec ] }
            , { c = True, r = False, e = True, flags = [ Ast.ConsArr, Ast.EqPtrFast ] }
            , { c = True, r = False, e = False, flags = [ Ast.ConsArr ] }
            , { c = False, r = True, e = True, flags = [ Ast.Rec, Ast.EqPtrFast ] }
            , { c = False, r = True, e = False, flags = [ Ast.Rec ] }
            , { c = False, r = False, e = True, flags = [ Ast.EqPtrFast ] }
            , { c = False, r = False, e = False, flags = [] }
            ]
        )
    , check
        "T19 seat-arity row: every tripwire SEAT in the three DSL lists (prim/helper/gc) declares the param count of the surface defun that replaces it — the splice substitutes the whole defun, so the mirror is not a lowering input, but it is now a READ assertion (a seat arity drifting from its surface defun FAILs here instead of being silently inert)"
        (case rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] of
            Ok s ->
                let
                    seats =
                        List.filter isSeatDefun
                            (RtPrims.primDefuns True True True
                                ++ RtPrims.helperDefuns True
                                ++ RtGc.gcProgram
                            )
                in
                not (List.isEmpty seats)
                    && List.all
                        (\d ->
                            case Dict.get d.key s of
                                Just sd ->
                                    lamArity d == lamArity sd

                                Nothing ->
                                    False
                        )
                        seats

            Err _ ->
                False
        )
    , check
        "T17/T18/T20/T21/T22/T24 pipeline (the wave-9 + collector + never-scheduled + T24 key-set row, post-T24's one-hundred-sixty-two): surf is Ok with EXACTLY the one-hundred-sixty-two migrated keys under the default flags — T24 added the LAST THREE wall-class holdouts (Rt.readFileGo, Rt.epCmd, Rt.childCd), so the DSL-bodied set is now EMPTY — the TWENTY exec-plan RUN keys (applyOneRedir, applyRedirects, bodyWriteGo, childBuiltin, childPwd, closeCmdTmpfds, closeOthersGo, closePipeTmpfds, closePipesGo, echoGo, envHome, exec-run, exec-plan, execGo, isChildBuiltin, mkTmpAt, openBodyTmpfile, runBuiltinInprocess, wireCmdGo, wirePipeGo — the RUN machinery incl. the 7-mode execGo state machine; childCd stays DSL-side) on top of the T16 ep* decode keys — the TWENTY ep* decode keys (epArgvGo, epChain, epCount, epCountStdin, epElem, epFreeArgv, epFreeChains, epFreeCmd, epFreeCmds, epFreeRedirs, epNum, epPipeGo, epPipeline, epProg, epProgGo, epRedir, epRedirsGo, epStr, epSymIs, epSymOf — the epUnwrap template written out; epCmd stays DSL-side) on top of the nine glob keys, the fd/process + string/value, records/vector, number/string and equality families, with the equality AND consArr guard families still collapsing into one dict entry per key; T18 adds the TWELVE collector keys (allocRaw, allocVector, collect, gcAlloc, gcAllocGo, gcDrain, gcInit, gcMarkPtr, gcMarkValue, gcMarkRoots, gcScanValueArray, gcSweep — the whole mark-sweep, the second DSL copy deleted) (a silently-lost or silently-added surface defun shows here)"
        (case rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] of
            Ok s ->
                List.sort (Dict.keys s)
                    == [ "Rt.*", "Rt.+", "Rt.-", "Rt./", "Rt.<", "Rt.<-address", "Rt.<=", "Rt.=", "Rt.>", "Rt.>=",
                      "Rt.@p", "Rt.absvector", "Rt.address->", "Rt.allocRaw", "Rt.allocVector", "Rt.appendL", "Rt.apply", "Rt.apply-tail", "Rt.applyGo", "Rt.applyOneRedir",
                      "Rt.applyRedirects", "Rt.applyTailGo", "Rt.asF", "Rt.assoc", "Rt.assocGo", "Rt.bitwise-and", "Rt.bitwise-not", "Rt.bitwise-or",
                      "Rt.bitwise-shift-left", "Rt.bitwise-shift-right", "Rt.bitwise-shift-right-zf", "Rt.bitwise-xor",
                      "Rt.bodyWriteGo", "Rt.bytesBuild", "Rt.bytesEqGo", "Rt.bytesOf",
                      "Rt.bytesToStr", "Rt.c-strlen", "Rt.cStrCopyGo", "Rt.cStrEq", "Rt.cStrEqGo", "Rt.cStrEqLit", "Rt.cStrFill", "Rt.cStrLenGo",
                      "Rt.callArity", "Rt.cd", "Rt.char-code", "Rt.childBuiltin", "Rt.childCd",
                      "Rt.childPwd", "Rt.close", "Rt.closeCmdTmpfds", "Rt.closeOthersGo", "Rt.closePipeTmpfds", "Rt.closePipesGo", "Rt.closure",
                      "Rt.closureFill", "Rt.cn", "Rt.cn2", "Rt.collect", "Rt.con", "Rt.conFill", "Rt.cons", "Rt.cons?", "Rt.copyWords", "Rt.countL", "Rt.deepEq", "Rt.dgs", "Rt.die", "Rt.echoGo", "Rt.empty?",
                      "Rt.emptylist", "Rt.envHome", "Rt.epArgvGo", "Rt.epChain", "Rt.epCmd", "Rt.epCount", "Rt.epCountStdin", "Rt.epElem",
                      "Rt.epFreeArgv", "Rt.epFreeChains", "Rt.epFreeCmd", "Rt.epFreeCmds", "Rt.epFreeRedirs", "Rt.epNum", "Rt.epPipeGo",
                      "Rt.epPipeline", "Rt.epProg", "Rt.epProgGo", "Rt.epRedir", "Rt.epRedirsGo", "Rt.epStr", "Rt.epSymIs", "Rt.epSymOf",
                      "Rt.exec-plan", "Rt.exec-run", "Rt.execGo", "Rt.f/", "Rt.fillGo", "Rt.floatCopy",
                      "Rt.frame-enter", "Rt.frame-leave", "Rt.frameBlock", "Rt.frameZero",
                      "Rt.gcAlloc", "Rt.gcAllocGo",
                      "Rt.gcDrain", "Rt.gcInit", "Rt.gcMarkPtr", "Rt.gcMarkRoots", "Rt.gcMarkValue", "Rt.gcScanValueArray", "Rt.gcSweep",
                      "Rt.getcwd", "Rt.getenv", "Rt.getpid", "Rt.glob", "Rt.globBuildGo", "Rt.globIsDot", "Rt.globIsDotDot",
                      "Rt.globLastSlash", "Rt.globScanGo", "Rt.globSortGo", "Rt.globSortShift", "Rt.globStrLess", "Rt.halt", "Rt.intern",
                      "Rt.isChildBuiltin", "Rt.main", "Rt.memGo", "Rt.metaGo", "Rt.mkTmpAt", "Rt.nameBytes", "Rt.numText", "Rt.number?", "Rt.open",
                      "Rt.openBodyTmpfile", "Rt.parseArgsGo", "Rt.read-byte", "Rt.read-file-as-string", "Rt.readFileGo", "Rt.readFull", "Rt.recAppend", "Rt.recAppendDataGo", "Rt.recAppendFind",
                      "Rt.recAppendNamesGo", "Rt.recGet", "Rt.recGetGo", "Rt.recInsert", "Rt.recToChain", "Rt.recToChainGo", "Rt.recUpd",
                      "Rt.recUpdCopy", "Rt.recUpdFind", "Rt.repGo", "Rt.repeat", "Rt.revGo", "Rt.runBuiltinInprocess", "Rt.setenv", "Rt.shen.bytes->string", "Rt.shen.str->bytes", "Rt.snd", "Rt.str", "Rt.strOf",
                      "Rt.string?", "Rt.subGo", "Rt.substring", "Rt.symEq", "Rt.symLess", "Rt.symToStr", "Rt.toI32", "Rt.value", "Rt.vecEq", "Rt.wRaw", "Rt.wStr",
                      "Rt.waitStatusCode", "Rt.wireCmdGo", "Rt.wirePipeGo", "Rt.write-byte"]
            Err _ ->
                False
        )
    , check
        "T7 extern arities: every key rtDeps mentions (subject or target) has a declared arity (J2's extern table is total over the Rt call graph)"
        (List.all
            (\k -> Dict.member k rt.externTypes)
            (List.concatMap (\( k, deps ) -> k :: deps) (Dict.toList Rt.rtDeps))
        )
    , check
        "T7 extern arities are flag-stable (T12 hardening — the row used to be VACUOUS on a pipeline Err: rtProgram [] -> rtArities Dict.empty -> List.all vacuously true; it now FAILS on Err or an empty program): every combo's program parses and its arities agree per-key with the table derived at True/True/True (the table also covers the gcProgram seats program alone doesn't carry; a flag variant changing an arity must be a loud decision, not drift)"
        (List.all
            (\( c, r, e ) ->
                case rt.program c r e of
                    Ok p ->
                        not (List.isEmpty p)
                            && List.all
                                (\( k, v ) -> (Dict.get k rt.externTypes |> Maybe.map externArity) == Just v)
                                (Dict.toList (rtArities p))

                    Err _ ->
                        False
            )
            [ ( True, True, True )
            , ( True, True, False )
            , ( True, False, True )
            , ( True, False, False )
            , ( False, True, True )
            , ( False, True, False )
            , ( False, False, True )
            , ( False, False, False )
            ]
        )
    , check
        "T7 migration safety net: every ACTIVE surface defun keeps the extern arity of the key it replaces (vacuous while RtSource.source = []; LIVE from T8's first defun)"
        (case rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] of
            Ok s ->
                List.all
                    (\( k, d ) -> (Dict.get k rt.externTypes |> Maybe.map externArity) == Just (lamArity d))
                    (Dict.toList s)

            Err _ ->
                False
        )
    -- ===== T25 — the splice accepts NEW keys (handoff-osier-tier2-t25) =====
    -- T25 extends the splice so a surface defun whose key has NO DSL position
    -- is APPENDED after the DSL list (sorted by key) instead of being the old
    -- ORPHAN Err, so new runtime defuns (the stage-6 ABI/driver family) can be
    -- written in the mid-c surface.  REPLACEMENT is unchanged, and with no new
    -- keys the spliced program is IDENTICAL to the pre-T25 one (the identity
    -- rows below, the corpus byte-identity 159/159 the byte-level proof).
    -- The old row lived here: "T7 splice unit: an entry is replaced IN PLACE
    -- ... and a surf key with no DSL position is a loud Err" — the orphan half
    -- is now the append below; the loud Err moved to the key-agreement walk
    -- (row C), which is the collision/rename class the orphan check guarded.
    , check
        "T25 splice identity (the byte-identity precondition the corpus proves at the byte level): the empty surface splices to the DSL list UNCHANGED, and with the SHIPPED surface exactly the seventeen stage-6 keys (Rt.apply, Rt.apply-tail, Rt.applyGo, Rt.applyTailGo, Rt.cStrEq, Rt.cStrEqGo, Rt.callArity, Rt.copyWords, Rt.die, Rt.frame-enter, Rt.frame-leave, Rt.frameBlock, Rt.frameZero, Rt.halt, Rt.main, Rt.metaGo, Rt.parseArgsGo) are appended — for all 8 flag combos the spliced program's key ORDER is the DSL union list's ++ the sorted append set"
        (let
            d0 k =
                { key = k, value = Lam { params = [], body = Lit (LNumber 0) } }

            dsl2 =
                [ d0 "Rt.a", d0 "Rt.b" ]
         in
         Rt.spliceSurface Dict.empty dsl2
            == Ok dsl2
            && List.all
                (\combo ->
                    case rt.surf combo.flags of
                        Ok s ->
                            let
                                union =
                                    RtPrims.primDefuns combo.c combo.r combo.e
                                        ++ RtPrims.helperDefuns combo.r
                                        ++ RtGc.gcProgram
                            in
                            case Rt.spliceSurface s union of
                                Ok spliced ->
                                    List.map .key spliced == List.map .key union ++ [ "Rt.apply", "Rt.apply-tail", "Rt.applyGo", "Rt.applyTailGo", "Rt.cStrEq", "Rt.cStrEqGo", "Rt.callArity", "Rt.copyWords", "Rt.die", "Rt.frame-enter", "Rt.frame-leave", "Rt.frameBlock", "Rt.frameZero", "Rt.halt", "Rt.main", "Rt.metaGo", "Rt.parseArgsGo" ]

                                Err _ ->
                                    False

                        Err _ ->
                            False
                )
                t25Combos
        )
    , check
        "T25 splice append: a surface key with NO DSL position is APPENDED after the WHOLE DSL list, the appended group SORTED BY KEY (order is .ssa bytes, so it is pinned deliberately) — and replacement still happens IN PLACE with neighbours kept"
        (let
            d0 k =
                { key = k, value = Lam { params = [], body = Lit (LNumber 0) } }

            surfB =
                { key = "Rt.b", value = Lam { params = [ { id = 7, name = "q" } ], body = Var 7 } }

            za =
                { key = "Rt.za", value = Lam { params = [], body = Lit (LNumber 1) } }

            zb =
                { key = "Rt.zb", value = Lam { params = [], body = Lit (LNumber 2) } }

            zc =
                { key = "Rt.zc", value = Lam { params = [], body = Lit (LNumber 3) } }

            dsl =
                [ d0 "Rt.a", d0 "Rt.b", d0 "Rt.c" ]
         in
         Rt.spliceSurface (Dict.fromList [ ( "Rt.b", surfB ) ]) dsl
            == Ok [ d0 "Rt.a", surfB, d0 "Rt.c" ]
            && -- three new keys, inserted in SCRAMBLED source order: the append
               -- order is by KEY ascending (za < zb < zc), never insertion order
               Rt.spliceSurface (Dict.fromList [ ( "Rt.zc", zc ), ( "Rt.za", za ), ( "Rt.zb", zb ) ]) dsl
            == Ok [ d0 "Rt.a", d0 "Rt.b", d0 "Rt.c", za, zb, zc ]
        )
    , check
        "T25 splice collision: a NEW surface key whose own defun is keyed like an EXISTING program key is a loud Err (never a silent duplicate: two defuns, one emitted name), and a replacement whose own key differs from the DSL key it replaces is a loud Err too (never a silent rename/drop while rtDeps still routes to it) — the splice substitutes the whole defun, so the defun's key and the dict key must agree"
        (let
            d0 k =
                { key = k, value = Lam { params = [], body = Lit (LNumber 0) } }

            dsl =
                [ d0 "Rt.a", d0 "Rt.b", d0 "Rt.c" ]

            -- spliced under the NEW key "Rt.zza" but itself keyed "Rt.b" (an
            -- existing program key) — the append would duplicate "Rt.b"
            imposter =
                { key = "Rt.b", value = Lam { params = [], body = Lit (LNumber 9) } }

            -- spliced under the EXISTING key "Rt.b" but itself keyed "Rt.zz"
            -- — the replacement would drop "Rt.b" while rtDeps routes to it
            renamer =
                { key = "Rt.zz", value = Lam { params = [], body = Lit (LNumber 9) } }
         in
         (case Rt.spliceSurface (Dict.fromList [ ( "Rt.zza", imposter ) ]) dsl of
            Err msg ->
                String.contains "Rt.b" msg && String.contains "Rt.zza" msg

            Ok _ ->
                False
         )
            && (case Rt.spliceSurface (Dict.fromList [ ( "Rt.b", renamer ) ]) dsl of
                    Err msg ->
                        String.contains "Rt.zz" msg && String.contains "Rt.b" msg

                    Ok _ ->
                        False
               )
        )
    , check
        "T25 derived tables cover appended defuns (VERIFIED, not assumed): the safepoint walk `Mid.rt.direct` — the tree walk `allocating`'s fixed point runs over the PRODUCED program (Rt.elm rtProgram = programPair True True True) — classifies an appended defun's tree BOTH ways (an allocating body is a direct safepoint, a plain body is not); the arity table derived from the produced program carries an appended key; and `externArities` (surfaceSigs from the parsed AST ++ the DSL arities) is TOTAL over every combo's produced program, so a new surface key's `call` resolves and the T7 safety-net row holds it to an arity"
        (let
            d0 k =
                { key = k, value = Lam { params = [], body = Lit (LNumber 0) } }

            zAlloc =
                { key = "Rt.zz"
                , value = Lam { params = [ { id = 1, name = "p1" } ], body = Unsafe (RawAllocRaw (Var 1)) }
                }

            zPlain =
                { key = "Rt.zz", value = Lam { params = [], body = Lit (LNumber 0) } }

            dsl =
                [ d0 "Rt.a" ]
         in
         rt.direct zAlloc
            && not (rt.direct zPlain)
            && (case Rt.spliceSurface (Dict.fromList [ ( "Rt.zz", zAlloc ) ]) dsl of
                    Ok spliced ->
                        Dict.get "Rt.zz" (rtArities spliced) == Just 1

                    Err _ ->
                        False
               )
            && List.all
                (\combo ->
                    case ( rt.program combo.c combo.r combo.e, rt.programGc combo.c combo.r combo.e ) of
                        ( Ok p, Ok g ) ->
                            not (List.isEmpty p)
                                && List.all (\d -> Dict.member d.key rt.externTypes) (p ++ g)

                        _ ->
                            False
                )
                t25Combos
        )

    -- ===== T8 — wave-1 migration: the trivial prims (handoff-osier-tier2-t8) =====
    -- Six RtPrims builders moved to Mid.RtSource (getpid, emptylist,
    -- cStrEqLit, wStr, wRaw, waitStatusCode).  T8 deferred Rt.close (its
    -- Lit (-2) test was unrepresentable — no negative literals) and
    -- Rt.write-byte (its KEY could not lex — the token charset had no '-');
    -- BOTH grammar walls fell in T8b and T9 moved both defuns (below).
    -- Each row below asserts the BUILT program carries that key's defun as
    -- the SURFACE lowering — structural identity, not canon: the DSL builder
    -- hands out different binder ids/names (b 3..6 / "t3"..) than the
    -- surface pipeline (sequential ids, the surface names), so a program
    -- defun that still came from a DSL builder cannot satisfy ==.  A
    -- half-done migration (key dropped from the source, a check reject, a
    -- broken splice) leaves surf without the key and fails the row loudly.
    , t8SplicedRow rt "Rt.getpid"
    , t8SplicedRow rt "Rt.emptylist"
    , t8SplicedRow rt "Rt.cStrEqLit"
    , t8SplicedRow rt "Rt.wStr"
    , t8SplicedRow rt "Rt.wRaw"
    , t8SplicedRow rt "Rt.waitStatusCode"

    -- ===== T9 — wave-2 migration: the self-tail loops + the two T8 walls =====
    -- Seven more builders moved to Mid.RtSource: the byte-walk loops
    -- cStrLenGo / cStrCopyGo / cStrFill / memGo (the surface `recur` term
    -- lowers to the exact App{GRef own-key, force=False} the DSL builds, so
    -- the jmp @body loop is preserved — the self-tail row above still pins
    -- it on the SPLICED program), readFull (its EINTR retry is NOT recur —
    -- the DSL self-references via plain RawCall, a native call per rare
    -- retry, and the corpus pins that shape) and the two defuns T8 had to
    -- defer (close: `-2` is now a single negative literal; write-byte: the
    -- key now lexes).  Rt.readFileGo stayed DSL-side until T24 (its growB
    -- binder is an If in a Let VALUE position; the grammar gained the
    -- if-EXPRESSION in T23 and T24 migrated it — see the T24 rows).
    , t8SplicedRow rt "Rt.cStrLenGo"
    , t8SplicedRow rt "Rt.cStrCopyGo"
    , t8SplicedRow rt "Rt.cStrFill"
    , t8SplicedRow rt "Rt.readFull"
    , t8SplicedRow rt "Rt.memGo"
    , t8SplicedRow rt "Rt.close"
    , t8SplicedRow rt "Rt.write-byte"
    , check
        "T12/T24 no double definition (T11's row + the new builder seats): each migrated key's ONLY DSL-side entry is its seat (a re-added builder would displace it — this row is the alarm); T24 added the LAST THREE holdouts (Rt.readFileGo, Rt.epCmd, Rt.childCd — their builders are deleted, so ZERO DSL-bodied defuns remain; a regression would fail this row)"
        (List.all
            (\s ->
                -- Occurrence COUNT, not first-match: a re-added builder AFTER
                -- the seat's list position must fail this row too, so the
                -- match list must be EXACTLY the one seat.
                List.filter (\d -> d.key == s.key) (RtPrims.primDefuns True True True ++ RtPrims.helperDefuns True)
                    == [ RtPrims.seat s.key s.arity ]
            )
            [ { key = "Rt.getpid", arity = 1 }
            , { key = "Rt.emptylist", arity = 1 }
            , { key = "Rt.cStrEqLit", arity = 3 }
            , { key = "Rt.wStr", arity = 2 }
            , { key = "Rt.wRaw", arity = 3 }
            , { key = "Rt.waitStatusCode", arity = 1 }
            , { key = "Rt.cStrLenGo", arity = 2 }
            , { key = "Rt.cStrCopyGo", arity = 3 }
            , { key = "Rt.cStrFill", arity = 3 }
            , { key = "Rt.readFull", arity = 3 }
            , { key = "Rt.memGo", arity = 2 }
            , { key = "Rt.close", arity = 1 }
            , { key = "Rt.write-byte", arity = 2 }
            , { key = "Rt.deepEq", arity = 2 }
            , { key = "Rt.bytesEqGo", arity = 3 }
            , { key = "Rt.symEq", arity = 3 }
            , { key = "Rt.vecEq", arity = 3 }
            , { key = "Rt.=", arity = 2 }
            , { key = "Rt.asF", arity = 1 }
            , { key = "Rt.toI32", arity = 1 }
            , { key = "Rt.dgs", arity = 1 }
            , { key = "Rt.revGo", arity = 2 }
            , { key = "Rt.bytesOf", arity = 2 }
            , { key = "Rt.numText", arity = 1 }
            , { key = "Rt.bytesToStr", arity = 1 }
            , { key = "Rt.countL", arity = 1 }
            , { key = "Rt.fillGo", arity = 3 }
            , { key = "Rt.cn2", arity = 2 }
            , { key = "Rt.appendL", arity = 2 }
            , { key = "Rt.symToStr", arity = 2 }
            , { key = "Rt.nameBytes", arity = 2 }
            , { key = "Rt.strOf", arity = 1 }
            , { key = "Rt.floatCopy", arity = 3 }
            , { key = "Rt.cons", arity = 2 }
            , { key = "Rt.@p", arity = 2 }
            , { key = "Rt.assocGo", arity = 2 }
            , { key = "Rt.recGet", arity = 2 }
            , { key = "Rt.recGetGo", arity = 3 }
            , { key = "Rt.recUpd", arity = 3 }
            , { key = "Rt.recUpdFind", arity = 3 }
            , { key = "Rt.recUpdCopy", arity = 3 }
            , { key = "Rt.recAppendFind", arity = 3 }
            , { key = "Rt.recAppendDataGo", arity = 3 }
            , { key = "Rt.recAppendNamesGo", arity = 3 }
            , { key = "Rt.recAppend", arity = 3 }
            , { key = "Rt.recInsert", arity = 3 }
            , { key = "Rt.recToChain", arity = 1 }
            , { key = "Rt.recToChainGo", arity = 3 }
            , { key = "Rt.absvector", arity = 1 }
            , { key = "Rt.address->", arity = 3 }
            , { key = "Rt.<-address", arity = 2 }
            , { key = "Rt.assoc", arity = 2 }
            , { key = "Rt.snd", arity = 1 }
            , { key = "Rt.read-byte", arity = 1 }
            , { key = "Rt.open", arity = 2 }
            , { key = "Rt.intern", arity = 1 }
            , { key = "Rt.value", arity = 1 }
            , { key = "Rt.str", arity = 1 }
            , { key = "Rt.getcwd", arity = 1 }
            , { key = "Rt.cd", arity = 1 }
            , { key = "Rt.getenv", arity = 1 }
            , { key = "Rt.setenv", arity = 2 }
            , { key = "Rt.globLastSlash", arity = 2 }
            , { key = "Rt.globIsDot", arity = 1 }
            , { key = "Rt.globIsDotDot", arity = 1 }
            , { key = "Rt.globScanGo", arity = 1 }
            , { key = "Rt.globStrLess", arity = 3 }
            , { key = "Rt.globSortShift", arity = 3 }
            , { key = "Rt.globSortGo", arity = 3 }
            , { key = "Rt.globBuildGo", arity = 3 }
            , { key = "Rt.glob", arity = 1 }
            , { key = "Rt.epNum", arity = 2 }
            , { key = "Rt.epStr", arity = 2 }
            , { key = "Rt.epSymOf", arity = 2 }
            , { key = "Rt.epSymIs", arity = 3 }
            , { key = "Rt.epCount", arity = 3 }
            , { key = "Rt.epElem", arity = 3 }
            , { key = "Rt.epProg", arity = 2 }
            , { key = "Rt.epProgGo", arity = 3 }
            , { key = "Rt.epChain", arity = 3 }
            , { key = "Rt.epPipeline", arity = 2 }
            , { key = "Rt.epPipeGo", arity = 3 }
            , { key = "Rt.epArgvGo", arity = 3 }
            , { key = "Rt.epRedirsGo", arity = 3 }
            , { key = "Rt.epRedir", arity = 3 }
            , { key = "Rt.epCountStdin", arity = 3 }
            , { key = "Rt.epFreeChains", arity = 3 }
            , { key = "Rt.epFreeCmds", arity = 3 }
            , { key = "Rt.epFreeCmd", arity = 1 }
            , { key = "Rt.epFreeArgv", arity = 3 }
            , { key = "Rt.epFreeRedirs", arity = 3 }
            , { key = "Rt.envHome", arity = 1 }
            , { key = "Rt.isChildBuiltin", arity = 2 }
            , { key = "Rt.echoGo", arity = 3 }
            , { key = "Rt.childPwd", arity = 1 }
            , { key = "Rt.childBuiltin", arity = 3 }
            , { key = "Rt.applyOneRedir", arity = 2 }
            , { key = "Rt.applyRedirects", arity = 3 }
            , { key = "Rt.bodyWriteGo", arity = 3 }
            , { key = "Rt.openBodyTmpfile", arity = 2 }
            , { key = "Rt.wireCmdGo", arity = 3 }
            , { key = "Rt.wirePipeGo", arity = 3 }
            , { key = "Rt.closeCmdTmpfds", arity = 2 }
            , { key = "Rt.closePipeTmpfds", arity = 2 }
            , { key = "Rt.closePipesGo", arity = 3 }
            , { key = "Rt.closeOthersGo", arity = 3 }
            , { key = "Rt.runBuiltinInprocess", arity = 2 }
            , { key = "Rt.execGo", arity = 2 }
            , { key = "Rt.mkTmpAt", arity = 1 }
            , { key = "Rt.exec-plan", arity = 1 }
            , { key = "Rt.exec-run", arity = 3 }
            , { key = "Rt.+", arity = 2 }
            , { key = "Rt.-", arity = 2 }
            , { key = "Rt.*", arity = 2 }
            , { key = "Rt./", arity = 2 }
            , { key = "Rt.f/", arity = 2 }
            , { key = "Rt.<", arity = 2 }
            , { key = "Rt.<=", arity = 2 }
            , { key = "Rt.>", arity = 2 }
            , { key = "Rt.>=", arity = 2 }
            , { key = "Rt.number?", arity = 1 }
            , { key = "Rt.string?", arity = 1 }
            , { key = "Rt.cons?", arity = 1 }
            , { key = "Rt.empty?", arity = 1 }
            , { key = "Rt.bitwise-and", arity = 2 }
            , { key = "Rt.bitwise-not", arity = 1 }
            , { key = "Rt.bitwise-or", arity = 2 }
            , { key = "Rt.bitwise-shift-left", arity = 2 }
            , { key = "Rt.bitwise-shift-right", arity = 2 }
            , { key = "Rt.bitwise-shift-right-zf", arity = 2 }
            , { key = "Rt.bitwise-xor", arity = 2 }
            , { key = "Rt.c-strlen", arity = 1 }
            , { key = "Rt.char-code", arity = 2 }
            , { key = "Rt.substring", arity = 3 }
            , { key = "Rt.cn", arity = 2 }
            , { key = "Rt.repeat", arity = 2 }
            , { key = "Rt.shen.str->bytes", arity = 1 }
            , { key = "Rt.shen.bytes->string", arity = 1 }
            , { key = "Rt.con", arity = 3 }
            , { key = "Rt.conFill", arity = 3 }
            , { key = "Rt.closure", arity = 3 }
            , { key = "Rt.closureFill", arity = 3 }
            , { key = "Rt.subGo", arity = 3 }
            , { key = "Rt.repGo", arity = 2 }
            , { key = "Rt.bytesBuild", arity = 3 }
            , { key = "Rt.symLess", arity = 3 }
            , { key = "Rt.read-file-as-string", arity = 1 }
              -- T24: the LAST THREE wall-class holdouts migrated — their
              -- builders are DELETED, so the filter-per-key check above is
              -- now the only entry the row needs for them (a re-added
              -- builder would fail it loudly).
            , { key = "Rt.readFileGo", arity = 1 }
            , { key = "Rt.epCmd", arity = 3 }
            , { key = "Rt.childCd", arity = 3 }
            ]
        )

    -- ===== T10 — wave-3 migration: the equality family, the first @flag-guarded defuns =====
    -- Five keys moved to Mid.RtSource: deepEq (TWO @rec variants of one key),
    -- bytesEqGo / symEq / vecEq (unguarded), and Rt.= (FOUR variants — the
    -- DSL's eqDefun took rec AND eqPtrFast, so the trees are the 2x2 product,
    -- spelled as guard CONJUNCTIONS; Parse gained the repeated-@guard loop,
    -- the one grammar change this wave needed — Ast/Check/LowerToIr were
    -- already list-shaped and untouched).  All family self-recursion is
    -- `call Rt.<own-key>` (RawCall), matching the builders' callR — the
    -- corpus pins it (recur would emit the in-frame jmp @body instead).
    -- The per-arm oracle is the corpus: default AND QBE_NOREC=1 AND
    -- QBE_NOEQPTRFAST=1 must each stay byte-identical — only a guard-
    -- selection faithful to Rt.activeFlags can do that, which is what the
    -- selection rows below pin structurally.
    , t8SplicedRow rt "Rt.deepEq"
    , t8SplicedRow rt "Rt.="
    , t8SplicedRow rt "Rt.vecEq"
    , t8SplicedRow rt "Rt.bytesEqGo"
    , t8SplicedRow rt "Rt.symEq"

    -- ===== T11 — wave-4 migration: the number/string builder family =====
    -- Nine RtPrims builders moved to Mid.RtSource: asF / toI32 (the two
    -- class-conversion prims), dgs / revGo / numText (the decimal-text
    -- chain), bytesOf / countL / bytesToStr / fillGo (the bytes->string
    -- machinery).  ALL self-recursion here is `call Rt.<own-key>`
    -- (RawCall) — the T11 brief's "revGo/countL/fillGo are recur" guess
    -- was refuted by reading the builders: they self-reference via callR
    -- (the T9 readFull lesson), and the corpus pins that shape.  numText's
    -- `signed` and dgs's `rAbs` hold an If in a Let VALUE position — the
    -- wall that deferred readFileGo in T9 — spelled here with the T9b
    -- `?:` join (its FIRST surface use); bytesToStr's fillGo call is an
    -- effect statement (the DSL's dead b 7 binder).
    , t8SplicedRow rt "Rt.asF"
    , t8SplicedRow rt "Rt.toI32"
    , t8SplicedRow rt "Rt.dgs"
    , t8SplicedRow rt "Rt.revGo"
    , t8SplicedRow rt "Rt.bytesOf"
    , t8SplicedRow rt "Rt.numText"
    , t8SplicedRow rt "Rt.bytesToStr"
    , t8SplicedRow rt "Rt.countL"
    , t8SplicedRow rt "Rt.fillGo"

    -- ===== T12 — wave-4 part 2: the remaining builders + the @consArr guard family =====
    -- Eight keys moved to Mid.RtSource: cn2 / appendL / symToStr /
    -- nameBytes / strOf / floatCopy (the primCn coercion chain and the
    -- float-text fill — all self/sibling recursion via `call`, none
    -- recur), and the cons pair cons / @p as the SECOND @flag-guarded
    -- family (the DSL's consDefun took the consArr switch: @consArr =
    -- the (A) one-pointer fused pair, @!consArr = the pre-(A) two-word
    -- pair).  The wave's one grammar change (the T8b class): `@` joined
    -- keyTokenAt's charset so the key `Rt.@p` lexes — the guard parser
    -- only ever sees `@` BEFORE the `defun` keyword, so a key-position
    -- `@` is unambiguous.  The T10 review's forward obligation is
    -- closed here: the flag-stable row above lost its vacuous-Err hole,
    -- and the consArr axis gets the per-combo selection rows below.
    , t8SplicedRow rt "Rt.cn2"
    , t8SplicedRow rt "Rt.appendL"
    , t8SplicedRow rt "Rt.symToStr"
    , t8SplicedRow rt "Rt.nameBytes"
    , t8SplicedRow rt "Rt.strOf"
    , t8SplicedRow rt "Rt.floatCopy"
    , t8SplicedRow rt "Rt.cons"
    , t8SplicedRow rt "Rt.@p"

    -- ===== T13 — wave-5 migration: the records / vector family =====
    -- Eighteen keys moved to Mid/RtSource: the rec walk block from
    -- helperDefuns (assocGo; recGet/recGetGo; recUpd/recUpdFind/recUpdCopy;
    -- recAppendFind/recAppendDataGo/recAppendNamesGo/recAppend/recInsert;
    -- recToChain/recToChainGo) and five from primDefuns (absvector,
    -- address->, <-address, assoc, snd).  All family recursion is
    -- `call Rt.<key>` (RawCall), measured per defun — zero recur (the
    -- T9-T12 lesson).  `reclen` (the nil-aware length MACRO — exactly the
    -- DSL's recLenOf tree) makes every `recLenOf (v rec)` transcribe 1:1;
    -- `Rt.address->` / `Rt.<-address` are the first live keys carrying
    -- `<-`/`->` (the T8b charset); recAppendDataGo/NamesGo's `store`
    -- binder (an If in a Let VALUE position) spells with the T9b `?:`
    -- join.  The rec* defuns are called only from rec-route sites, so the
    -- QBE_NOREC=1 arm still never emits them (emission is per REACHABLE
    -- defun) — the corpus arms are the judge.
    , t8SplicedRow rt "Rt.assocGo"
    , t8SplicedRow rt "Rt.recGet"
    , t8SplicedRow rt "Rt.recGetGo"
    , t8SplicedRow rt "Rt.recUpd"
    , t8SplicedRow rt "Rt.recUpdFind"
    , t8SplicedRow rt "Rt.recUpdCopy"
    , t8SplicedRow rt "Rt.recAppendFind"
    , t8SplicedRow rt "Rt.recAppendDataGo"
    , t8SplicedRow rt "Rt.recAppendNamesGo"
    , t8SplicedRow rt "Rt.recAppend"
    , t8SplicedRow rt "Rt.recInsert"
    , t8SplicedRow rt "Rt.recToChain"
    , t8SplicedRow rt "Rt.recToChainGo"
    , t8SplicedRow rt "Rt.absvector"
    , t8SplicedRow rt "Rt.address->"
    , t8SplicedRow rt "Rt.<-address"
    , t8SplicedRow rt "Rt.assoc"
    , t8SplicedRow rt "Rt.snd"

    -- ===== T14 — wave-6 migration: fd / process + the string/value prims =====
    -- Nine keys moved to Mid/RtSource: read-byte/open (the fd layer; close
    -- went in T9), intern/value/str (the VM-state and float-text prims) and
    -- getcwd/cd/getenv/setenv (the libc process layer; getpid went in T8).
    -- ALL recursion in the family is a plain sibling `call` — measured PER
    -- DEFUN, zero recur (the T9-T13 lesson).  Three builder shapes
    -- transcribe throughout: mkval(11, f, i + 4294967296 * s) is the DSL's
    -- mkStream packing word; byteload(rawcall __errno_location(), 0) is
    -- errnoOf (the readFull precedent); and the cStrOf NUL-copy expands to
    -- its four binders in every NUL-terminating defun.  The mid-block ifs
    -- all have a diverging then-branch (the L6 else-nesting); open's out
    -- arm and read-byte's file arm end in the T9b `?:` join in return
    -- position.  The two now-unused fd helpers (isStringOf, mkStream) were
    -- deleted with their only caller; errnoOf's shape stays (the readFull
    -- / EINTR arms), and the cStrOf four-binder EXPANSION stays spelled
    -- out in every NUL-copying defun — the cStrOf ELM HELPER itself was
    -- deleted in T22 with its last DSL reader (read-file-as-string).
    , t8SplicedRow rt "Rt.read-byte"
    , t8SplicedRow rt "Rt.open"
    , t8SplicedRow rt "Rt.intern"
    , t8SplicedRow rt "Rt.value"
    , t8SplicedRow rt "Rt.str"
    , t8SplicedRow rt "Rt.getcwd"
    , t8SplicedRow rt "Rt.cd"
    , t8SplicedRow rt "Rt.getenv"
    , t8SplicedRow rt "Rt.setenv"

    -- ===== T15 — wave-7 migration: the glob family =====
    -- Nine keys moved to Mid/RtSource: the eight helpers (globLastSlash,
    -- globIsDot, globIsDotDot, globScanGo, globStrLess, globSortShift,
    -- globSortGo, globBuildGo) plus glob itself.  Recursion is MEASURED
    -- per defun: globLastSlash/globScanGo/globStrLess/globSortShift/
    -- globSortGo/globBuildGo are SELF-TAIL recur (their builders
    -- self-referenced via App on the own key — the T9 wave's other half);
    -- globIsDot/globIsDotDot/glob make no self-call.  The OOM checks and
    -- glob's in-place '/' NUL were Ifs in LET-VALUE positions with a LET
    -- branch (haltV; store-then-mknum(0)) — spelled as the mid-block if
    -- with BOTH branches diverging, which lowers to the DSL's exact
    -- Let { b = If { .. } } dead-binder shape; globScanGo's guard cond
    -- keeps the builders' RAW || inside the &&.
    , t8SplicedRow rt "Rt.globLastSlash"
    , t8SplicedRow rt "Rt.globIsDot"
    , t8SplicedRow rt "Rt.globIsDotDot"
    , t8SplicedRow rt "Rt.globScanGo"
    , t8SplicedRow rt "Rt.globStrLess"
    , t8SplicedRow rt "Rt.globSortShift"
    , t8SplicedRow rt "Rt.globSortGo"
    , t8SplicedRow rt "Rt.globBuildGo"
    , t8SplicedRow rt "Rt.glob"

    -- ===== T16 — wave-8 migration: the ep* exec-plan decode family =====
    -- Twenty keys moved to Mid/RtSource: the three epUnwrap template
    -- instances written out explicitly (epNum/epStr/epSymOf — the Elm
    -- template deleted), the tdl walkers (epSymIs/epCount/epElem), the
    -- record decoders (epProg/epProgGo/epChain/epPipeline/epPipeGo/
    -- epArgvGo/epRedirsGo/epRedir), the stdin guard (epCountStdin) and the
    -- free walk (epFreeChains/epFreeCmds/epFreeCmd/epFreeArgv/
    -- epFreeRedirs).  Recursion MEASURED per defun: SELF-TAIL recur in
    -- epSymIs/epCount/epElem/epProgGo/epPipeGo/epArgvGo/epRedirsGo/
    -- epCountStdin/epFreeChains (two sites)/epFreeCmds/epFreeArgv/
    -- epFreeRedirs; no self-call in the unwraps/epProg/epChain/epPipeline/
    -- epRedir/epFreeCmd.  The RtLayout offsets are literals in the surface
    -- text (MEASURED: all eight exec fixtures' .ssa reach every key, so
    -- the corpus pins each offset).  Rt.epCmd was NOT in T16 (its ago/rgo
    -- binders are Ifs in LET-VALUE positions whose branches carry Lets and
    -- whose values the continuation reads — unspellable until T23); T24
    -- migrated it with the block-branch if — see the T24 rows below.
    , t8SplicedRow rt "Rt.epNum"
    , t8SplicedRow rt "Rt.epStr"
    , t8SplicedRow rt "Rt.epSymOf"
    , t8SplicedRow rt "Rt.epSymIs"
    , t8SplicedRow rt "Rt.epCount"
    , t8SplicedRow rt "Rt.epElem"
    , t8SplicedRow rt "Rt.epProg"
    , t8SplicedRow rt "Rt.epProgGo"
    , t8SplicedRow rt "Rt.epChain"
    , t8SplicedRow rt "Rt.epPipeline"
    , t8SplicedRow rt "Rt.epPipeGo"
    , t8SplicedRow rt "Rt.epArgvGo"
    , t8SplicedRow rt "Rt.epRedirsGo"
    , t8SplicedRow rt "Rt.epRedir"
    , t8SplicedRow rt "Rt.epCountStdin"
    , t8SplicedRow rt "Rt.epFreeChains"
    , t8SplicedRow rt "Rt.epFreeCmds"
    , t8SplicedRow rt "Rt.epFreeCmd"
    , t8SplicedRow rt "Rt.epFreeArgv"
    , t8SplicedRow rt "Rt.epFreeRedirs"

    -- ===== T17 — wave-9 migration: the exec-plan RUN machinery =====
    -- Twenty keys moved to Mid/RtSource: the exec-plan prims (exec-plan,
    -- exec-run, mkTmpAt) and seventeen of the eighteen helperDefuns run
    -- builders (envHome/isChildBuiltin/echoGo/childPwd/childBuiltin/
    -- applyOneRedir/applyRedirects/bodyWriteGo/openBodyTmpfile/wireCmdGo/
    -- wirePipeGo/closeCmdTmpfds/closePipeTmpfds/closePipesGo/closeOthersGo/
    -- runBuiltinInprocess/execGo — the 565-line 7-mode execGo state machine
    -- itself, TWENTY-THREE recur sites MEASURED).  Rt.childCd was NOT in
    -- T17 (its second dirN binder is an If in a LET-VALUE position whose
    -- ELSE carries a Let-chain (ln = cStrLenGo dirN) and whose value the
    -- continuation reads); T24 migrated it with the block-branch if, and
    -- its runLits/runOff/rLoad helpers died with it.  The RtLayout offsets,
    -- the runLits cbuf offsets and the decode tag words are literals in the
    -- surface text (COMPUTED by replicating runLitsPacked/the lit folder,
    -- not transcribed by hand).
    , t8SplicedRow rt "Rt.envHome"
    , t8SplicedRow rt "Rt.isChildBuiltin"
    , t8SplicedRow rt "Rt.echoGo"
    , t8SplicedRow rt "Rt.childPwd"
    , t8SplicedRow rt "Rt.childBuiltin"
    , t8SplicedRow rt "Rt.applyOneRedir"
    , t8SplicedRow rt "Rt.applyRedirects"
    , t8SplicedRow rt "Rt.bodyWriteGo"
    , t8SplicedRow rt "Rt.openBodyTmpfile"
    , t8SplicedRow rt "Rt.wireCmdGo"
    , t8SplicedRow rt "Rt.wirePipeGo"
    , t8SplicedRow rt "Rt.closeCmdTmpfds"
    , t8SplicedRow rt "Rt.closePipeTmpfds"
    , t8SplicedRow rt "Rt.closePipesGo"
    , t8SplicedRow rt "Rt.closeOthersGo"
    , t8SplicedRow rt "Rt.runBuiltinInprocess"
    , t8SplicedRow rt "Rt.execGo"
    , t8SplicedRow rt "Rt.mkTmpAt"
    , t8SplicedRow rt "Rt.exec-plan"
    , t8SplicedRow rt "Rt.exec-run"

    -- ===== T18 — the COLLECTOR wave (Mid.RtGc's 12 defuns) =====
    -- The whole mark-sweep moved to Mid.RtSource (the second DSL copy
    -- DELETED — RtGc keeps only the globals-block constants and the seat
    -- list).  These read the GC half of the splice (`rtProgramGc`) — the
    -- gc keys are not in `rt.program` — and assert the built program
    -- carries the SURFACE lowering at each gcProgram position, the same
    -- tooth the t8SplicedRow rows have.  The gc call-graph row above is
    -- the structural twin (every RawCall target a rtDeps-declared program
    -- key — a tripwire seat would fail it loudly).
    , t18SplicedRow rt "Rt.gcInit"
    , t18SplicedRow rt "Rt.allocVector"
    , t18SplicedRow rt "Rt.allocRaw"
    , t18SplicedRow rt "Rt.gcAlloc"
    , t18SplicedRow rt "Rt.gcAllocGo"
    , t18SplicedRow rt "Rt.collect"
    , t18SplicedRow rt "Rt.gcMarkRoots"
    , t18SplicedRow rt "Rt.gcScanValueArray"
    , t18SplicedRow rt "Rt.gcDrain"
    , t18SplicedRow rt "Rt.gcSweep"
    , t18SplicedRow rt "Rt.gcMarkPtr"
    , t18SplicedRow rt "Rt.gcMarkValue"

    -- ===== T20 — the never-scheduled family, part 1 (handoff-osier-tier2-t20) =====
    -- Thirteen RtPrims builders NO wave T8-T18 ever scheduled (T19's
    -- holdout inventory): Rt.+ - * / f/ (float-promote or bare i64 wrap),
    -- the four comparisons (cmpDefun's numeric-guard + promote, spelled
    -- as a nested term-if), and the four tag predicates (predDefun's
    -- foldr OR-chain, spelled per defun).  Rt.+, Rt.*, Rt./, Rt.f/ and
    -- the four `?` keys needed THREE more key characters (`* / ?`) in
    -- Parse's key charset — the T8b/T12 precedent; the T20 grammar rows
    -- below pin the new keys and the untouched `?:` join.

    -- ---- parse: the new key characters (each measured ambiguity pinned) ----
    , check "parse: defun Rt.*(a, b) lexes the * key verbatim and calls it -- a key-position * never touches the body's mul operator"
        (Parse.parseProgram
            "defun Rt.*(a: val, b: val) -> val {\n  return mknum(payload(a, 0) * payload(b, 0));\n}"
            == Ok
                [ { key = "Rt.*"
                  , flags = []
                  , params =
                        [ { name = "a", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body =
                        { stmts = []
                        , term =
                            Ast.TRet
                                (Ast.EBuiltin Ast.MkNum
                                    [ Ast.EWordBin Ast.WMul
                                        (Ast.EBuiltin Ast.Payload [ Ast.EVar "a", Ast.EInt 0 ])
                                        (Ast.EBuiltin Ast.Payload [ Ast.EVar "b", Ast.EInt 0 ])
                                    ]
                                )
                        }
                  }
                ]
        )
    , check "parse: defun Rt.number?(a) lexes the ? key verbatim -- a key-position ? never touches the expression layer's ?: join"
        (Parse.parseProgram
            "defun Rt.number?(a: val) -> val {\n  return mkbool(tagis(a, 0)) || false;\n}"
            == Ok
                [ { key = "Rt.number?"
                  , flags = []
                  , params = [ { name = "a", ty = Ast.TVal } ]
                  , ret = Ast.TVal
                  , body =
                        { stmts = []
                        , term =
                            Ast.TRet
                                (Ast.EShortOr
                                    (Ast.EBuiltin Ast.MkBool [ Ast.EBuiltin Ast.TagIs [ Ast.EVar "a", Ast.EInt 0 ] ])
                                    (Ast.EBuiltin Ast.MkBool [ Ast.EInt 0 ])
                                )
                        }
                  }
                ]
        )
    , check "parse: call Rt.f/(a, b) -- the / key reads in call position; the body's f/ and / stay the float/word div operators"
        (Parse.parseExp "call Rt.f/(a, b)"
            == Ok (Ast.ECall "Rt.f/" [ Ast.EVar "a", Ast.EVar "b" ])
            && Parse.parseExp "x f/ y"
            == Ok (Ast.EFltBin Ast.FDiv (Ast.EVar "x") (Ast.EVar "y"))
            && Parse.parseExp "x / y"
            == Ok (Ast.EWordBin Ast.WDiv (Ast.EVar "x") (Ast.EVar "y"))
        )
    , check "parse: the ?: join is UNTOUCHED by the ? key char (T9b's accept row, re-run -- a body ? is still the value join)"
        (Parse.parseExp "c ? a : b" == Ok (Ast.EIf (Ast.EVar "c") (Ast.EVar "a") (Ast.EVar "b")))

    , t8SplicedRow rt "Rt.+"
    , t8SplicedRow rt "Rt.-"
    , t8SplicedRow rt "Rt.*"
    , t8SplicedRow rt "Rt./"
    , t8SplicedRow rt "Rt.f/"
    , t8SplicedRow rt "Rt.<"
    , t8SplicedRow rt "Rt.<="
    , t8SplicedRow rt "Rt.>"
    , t8SplicedRow rt "Rt.>="
    , t8SplicedRow rt "Rt.number?"
    , t8SplicedRow rt "Rt.string?"
    , t8SplicedRow rt "Rt.cons?"
    , t8SplicedRow rt "Rt.empty?"

    -- ===== T21 — the never-scheduled family, part 2 (handoff-osier-tier2-t21) =====
    -- Fourteen RtPrims builders NO wave T8-T20 ever scheduled: the
    -- Bitwise family (bit2Defun/bitNotDefun/shl/sar/shr — toI32
    -- operands, word-width ops, mod-32 shift counts) and seven string
    -- prims (c-strlen/char-code/substring/cn/repeat/shen.str->bytes/
    -- shen.bytes->string — substring's clamps are the T9b `?:` join
    -- class, the halt arms are the rt_halt dead binder).  NO parser
    -- change: every key character was already in the T8b/T12/T20
    -- charset (the splice rows themselves prove `Rt.shen.str->bytes`
    -- lexes — a parse failure would fail every surf row loudly).  The
    -- walk helpers these call (subGo/repGo/bytesBuild) are still
    -- DSL-bodied; J2's extern table resolves them with no new row.
    , t8SplicedRow rt "Rt.bitwise-and"
    , t8SplicedRow rt "Rt.bitwise-not"
    , t8SplicedRow rt "Rt.bitwise-or"
    , t8SplicedRow rt "Rt.bitwise-shift-left"
    , t8SplicedRow rt "Rt.bitwise-shift-right"
    , t8SplicedRow rt "Rt.bitwise-shift-right-zf"
    , t8SplicedRow rt "Rt.bitwise-xor"
    , t8SplicedRow rt "Rt.c-strlen"
    , t8SplicedRow rt "Rt.char-code"
    , t8SplicedRow rt "Rt.substring"
    , t8SplicedRow rt "Rt.cn"
    , t8SplicedRow rt "Rt.repeat"
    , t8SplicedRow rt "Rt.shen.str->bytes"
    , t8SplicedRow rt "Rt.shen.bytes->string"

    -- ===== T22 — the never-scheduled family, part 3 (FINAL) =====
    -- The LAST nine never-scheduled builders (T19's inventory, now
    -- empty on that side): the constructor layer con/conFill/closure/
    -- closureFill (allocvec + the staged-block copy walks + the
    -- tag-10/tag-6 wraps) and the four walk helpers subGo/repGo/
    -- bytesBuild/symLess, plus read-file-as-string — whose OOM binders
    -- looked like the T9 wall class but are DEAD-VALUE binders, spelled
    -- as the T15 both-diverge mid-block if.  NO parser/checker/lowerer
    -- change: every shape rode an existing spelling.  Recursion
    -- MEASURED per defun: ALL of it is the builders' callR (RawCall) —
    -- a plain `call`, NOT recur, in every one of the nine.  The wave's
    -- deletions killed seven Elm helpers (cStrOf, lenOf, mkVec, consV,
    -- byteOf, trueV, falseV — zero-ref verified); Rt.readFileGo,
    -- Rt.epCmd and Rt.childCd stayed DSL-side here — the three wall-class
    -- holdouts, migrated in T24 (see the T24 block below).
    , t8SplicedRow rt "Rt.con"
    , t8SplicedRow rt "Rt.conFill"
    , t8SplicedRow rt "Rt.closure"
    , t8SplicedRow rt "Rt.closureFill"
    , t8SplicedRow rt "Rt.subGo"
    , t8SplicedRow rt "Rt.repGo"
    , t8SplicedRow rt "Rt.bytesBuild"
    , t8SplicedRow rt "Rt.symLess"
    , t8SplicedRow rt "Rt.read-file-as-string"

    -- ---- the T10 parse additions: the guard conjunction ----
    , check
        "parse: a guard CONJUNCTION lands in source order — @rec @eqPtrFast defun Rt.=.. has flags [Guard Rec, Guard EqPtrFast]"
        (Parse.parseProgram "@rec @eqPtrFast defun Rt.=(a: val, b: val) -> val { return mkbool(1); }"
            == Ok
                [ { key = "Rt.="
                  , flags = [ Ast.Guard Ast.Rec, Ast.Guard Ast.EqPtrFast ]
                  , params =
                        [ { name = "a", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body = { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EInt 1 ]) }
                  }
                ]
        )
    , check
        "parse: @!rec @!eqPtrFast — the GuardNot polarities are preserved per guard in the conjunction"
        (case Parse.parseProgram "@!rec @!eqPtrFast defun Rt.=(a: val) -> val { return mknil; }" of
            Ok [ d ] ->
                d.flags == [ Ast.GuardNot Ast.Rec, Ast.GuardNot Ast.EqPtrFast ]

            _ ->
                False
        )
    , check
        "parse REJECTS an unknown flag inside a conjunction (@rec @bogus) — the SAME unknown-flag reject the head guard has"
        (case Parse.parseProgram "@rec @bogus defun Rt.x(a: val) -> val { return mknil; }" of
            Err msg ->
                String.contains "unknown flag" msg

            Ok _ ->
                False
        )

    -- ---- the T8fix positional-selection shape, now on live runtime bytes ----
    , check
        "T10 guard selection (Rt.deepEq): the @rec variant is FIRST, @!rec LAST; under [Rec] the active dict carries the FIRST slot's lowered tree, under [] the LAST — and the two trees differ (a swapped, OR-semantics, or last-wins selection cannot pass)"
        (case rt.parsedSource of
            Err _ ->
                False

            Ok ast ->
                case LowerToIr.lowerProgram ast of
                    Err _ ->
                        False

                    Ok lowered ->
                        case
                            List.filter (\( a, _ ) -> a.key == "Rt.deepEq")
                                (List.map2 Tuple.pair ast lowered)
                        of
                            ( aRec, vRec ) :: ( aNoRec, vNoRec ) :: [] ->
                                (aRec.flags == [ Ast.Guard Ast.Rec ])
                                    && (aNoRec.flags == [ Ast.GuardNot Ast.Rec ])
                                    && (vRec /= vNoRec)
                                    && (Dict.get "Rt.deepEq" (Rt.activeSurf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] [ ( aRec, vRec ), ( aNoRec, vNoRec ) ]) == Just vRec)
                                    && (Dict.get "Rt.deepEq" (Rt.activeSurf [ Ast.ConsArr, Ast.EqPtrFast ] [ ( aRec, vRec ), ( aNoRec, vNoRec ) ]) == Just vNoRec)

                            _ ->
                                False
        )
    , check
        "T10 guard selection (Rt.=, the conjunction): four variants in source order rec+fast / rec+!fast / !rec+fast / !rec+!fast; EVERY flag combo's dict carries ITS OWN slot's tree (under [Rec] the SECOND — a half-held or OR-skewed conjunction picks the first and fails), the four trees pairwise distinct, and the SPLICED program carries the same under its combos"
        (case rt.parsedSource of
            Err _ ->
                False

            Ok ast ->
                case LowerToIr.lowerProgram ast of
                    Err _ ->
                        False

                    Ok lowered ->
                        case
                            List.filter (\( a, _ ) -> a.key == "Rt.=")
                                (List.map2 Tuple.pair ast lowered)
                        of
                            ( a1, v1 ) :: ( a2, v2 ) :: ( a3, v3 ) :: ( a4, v4 ) :: [] ->
                                let
                                    picked flags =
                                        Rt.activeSurf flags [ ( a1, v1 ), ( a2, v2 ), ( a3, v3 ), ( a4, v4 ) ]

                                    inProgram c r e =
                                        defunByKey "Rt.=" (rtProgram rt c r e)
                                in
                                (a1.flags == [ Ast.Guard Ast.Rec, Ast.Guard Ast.EqPtrFast ])
                                    && (a2.flags == [ Ast.Guard Ast.Rec, Ast.GuardNot Ast.EqPtrFast ])
                                    && (a3.flags == [ Ast.GuardNot Ast.Rec, Ast.Guard Ast.EqPtrFast ])
                                    && (a4.flags == [ Ast.GuardNot Ast.Rec, Ast.GuardNot Ast.EqPtrFast ])
                                    && (v1 /= v2)
                                    && (v1 /= v3)
                                    && (v1 /= v4)
                                    && (v2 /= v3)
                                    && (v2 /= v4)
                                    && (v3 /= v4)
                                    && (picked [ Ast.Rec, Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.=", v1 ) ])
                                    && (picked [ Ast.Rec ] == Dict.fromList [ ( "Rt.=", v2 ) ])
                                    && (picked [ Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.=", v3 ) ])
                                    && (picked [] == Dict.fromList [ ( "Rt.=", v4 ) ])
                                    && (inProgram True True True == Just v1)
                                    && (inProgram True True False == Just v2)
                                    && (inProgram True False True == Just v3)
                                    && (inProgram False False False == Just v4)

                            _ ->
                                False
        )

    -- ---- T12: the consArr axis gets the T10 selection-row pattern (the
    -- T10 review's carry-forward obligation — a zero-active or
    -- two-active @consArr bug was ROW-SILENT before T12: no corpus arm
    -- existed for QBE_NOCONSARR=1 and the flag-stable row above was
    -- vacuous on a pipeline Err).  The inProgram conjuncts run the FULL
    -- pipeline (parse -> J8 check -> lower -> splice) under BOTH
    -- consArr settings; the per-arm corpus oracle (default AND
    -- QBE_NOCONSARR=1 each byte-identical) is the byte-level twin.
    , check
        "T12 guard selection (Rt.cons): the @consArr variant is FIRST, @!consArr LAST; under [ConsArr..] the active dict carries the FIRST slot's tree, without ConsArr the LAST — and the FULL pipeline under both consArr settings splices its OWN variant (a zero-active or two-active consArr bug cannot pass)"
        (case rt.parsedSource of
            Err _ ->
                False

            Ok ast ->
                case LowerToIr.lowerProgram ast of
                    Err _ ->
                        False

                    Ok lowered ->
                        case
                            List.filter (\( a, _ ) -> a.key == "Rt.cons")
                                (List.map2 Tuple.pair ast lowered)
                        of
                            ( aArr, vArr ) :: ( aTwo, vTwo ) :: [] ->
                                let
                                    picked flags =
                                        Rt.activeSurf flags [ ( aArr, vArr ), ( aTwo, vTwo ) ]

                                    inProgram c =
                                        defunByKey "Rt.cons" (rtProgram rt c True True)
                                in
                                (aArr.flags == [ Ast.Guard Ast.ConsArr ])
                                    && (aTwo.flags == [ Ast.GuardNot Ast.ConsArr ])
                                    && (vArr /= vTwo)
                                    && (picked [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.cons", vArr ) ])
                                    && (picked [ Ast.Rec, Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.cons", vTwo ) ])
                                    && (inProgram True == Just vArr)
                                    && (inProgram False == Just vTwo)

                            _ ->
                                False
        )
    , check
        "T12 guard selection (Rt.@p): the SAME @consArr/@!consArr pair under the second key — the parse itself proves the key lexes (T12's key-charset change), and both consArr settings splice their OWN variant"
        (case rt.parsedSource of
            Err _ ->
                False

            Ok ast ->
                case LowerToIr.lowerProgram ast of
                    Err _ ->
                        False

                    Ok lowered ->
                        case
                            List.filter (\( a, _ ) -> a.key == "Rt.@p")
                                (List.map2 Tuple.pair ast lowered)
                        of
                            ( aArr, vArr ) :: ( aTwo, vTwo ) :: [] ->
                                let
                                    picked flags =
                                        Rt.activeSurf flags [ ( aArr, vArr ), ( aTwo, vTwo ) ]

                                    inProgram c =
                                        defunByKey "Rt.@p" (rtProgram rt c True True)
                                in
                                (aArr.flags == [ Ast.Guard Ast.ConsArr ])
                                    && (aTwo.flags == [ Ast.GuardNot Ast.ConsArr ])
                                    && (vArr /= vTwo)
                                    && (picked [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.@p", vArr ) ])
                                    && (picked [ Ast.Rec, Ast.EqPtrFast ] == Dict.fromList [ ( "Rt.@p", vTwo ) ])
                                    && (inProgram True == Just vArr)
                                    && (inProgram False == Just vTwo)

                            _ ->
                                False
        )

    -- ---- TIER-2 PERF GUARD: the surface parser is O(n) (handoff-osier-tier2-perf) ----
    -- Mid.RtLang.Parse's hot path must never re-scan the source: its
    -- scanners are offset-threaded (ONE `String.slice n (n+1)` read per
    -- character) and the module carries ZERO `dropLeft` / tail-`toList`
    -- (the pre-fix form made ONE trivial fixture compile burn ~12s of
    -- user CPU, 85% of it inside Parse).  A pure-Elm row has no clock
    -- (elm.json is elm/core+json only), so the guard is TWO halves:
    --   * THIS row: a ~120KB synthetic program (~the live Mid.RtSource
    --     blob again) must parse to its EXACT defun list.  Its bound is
    --     the `node test-run.js` SUITE WALL (MEASURED ~1s post-fix; the
    --     O(n^2) pre-fix parser would push this one row past two
    --     minutes) — a regression is loud in the oracle's reported wall
    --     even though a PASS/FAIL row cannot see time;
    --   * the `rg -n "String.dropLeft" src/Mid/RtLang/Parse.elm` gate
    --     (run at every oracle pass): exit 1 = zero matches, comments
    --     included — catches the banned form itself, by inspection.
    -- Failure caught: a re-introduced O(n^2) scanner (dropLeft/toList of
    -- a tail) — visibly in the suite wall, structurally via the rg gate.
    , check
        "guard: a large synthetic program (1200 defuns, ~120KB) parses to its EXACT defun list — the O(n) parser canary (an O(n^2) regression shows up as the test-run.js WALL, minutes, not as a FAIL here)"
        (let
            n =
                1200

            defunSrc i =
                "defun Rt.perfguard"
                    ++ String.fromInt i
                    ++ "(a: val) -> val {\n  val t = mknum("
                    ++ String.fromInt i
                    ++ ");\n  return payload(t, 0);\n}\n"

            src =
                String.join "\n" (List.map defunSrc (List.range 1 n))
         in
         case Parse.parseProgram src of
            Err _ ->
                False

            Ok prog ->
                (List.length prog == n)
                    && (case prog of
                            d0 :: _ ->
                                (d0.key == "Rt.perfguard1")
                                    && (d0.flags == [])
                                    && (d0.params == [ { name = "a", ty = Ast.TVal } ])
                                    && (d0.body
                                        == { stmts =
                                                [ Ast.SBind Ast.TVal "t" (Ast.EBuiltin Ast.MkNum [ Ast.EInt 1 ]) ]
                                           , term =
                                                Ast.TRet (Ast.EBuiltin Ast.Payload [ Ast.EVar "t", Ast.EInt 0 ])
                                           }
                                       )

                            [] ->
                                False
                       )
                    && (case List.reverse prog of
                            dLast :: _ ->
                                dLast.key == "Rt.perfguard" ++ String.fromInt n

                            [] ->
                                False
                       )
        )

    -- ---- J8 on the conjunction itself (small programs, the checker's own rows) ----
    , check
        "check: J8 accept — a @rec @eqPtrFast conjunction holds only when BOTH flags are on; under [Rec] alone it is ZERO active (the loud reject — conjunction semantics, never OR)"
        (chkFlags [ Ast.Rec, Ast.EqPtrFast ] "@rec @eqPtrFast defun Rt.k(a: val) -> val { return mknil; }"
            == Ok ()
            && (case chkFlags [ Ast.Rec ] "@rec @eqPtrFast defun Rt.k(a: val) -> val { return mknil; }" of
                    Err msg ->
                        String.contains "no active defun" msg

                    Ok _ ->
                        False
               )
        )
    , check
        "check: J8 REJECT — a guarded variant PLUS an unguarded duplicate is TWO active under the guard's flags (fragment '2 flag-guarded defuns are active')"
        (case chkFlags [ Ast.Rec ] "@rec defun Rt.k(a: val) -> val { return mknil; }\ndefun Rt.k(a: val) -> val { return mknil; }" of
            Err msg ->
                String.contains "2 flag-guarded defuns are active" msg

            Ok _ ->
                False
        )
    , check
        "check: J8 on the consArr axis (T12 — the checker's sameFlag wiring for the second flag, pinned where a bug would be loud): @consArr holds under [ConsArr] and is ZERO active under [] (the exact bug class the corpus arm cannot see on its own)"
        (chkFlags [ Ast.ConsArr ] "@consArr defun Rt.k(a: val) -> val { return mknil; }"
            == Ok ()
            && (case chkFlags [] "@consArr defun Rt.k(a: val) -> val { return mknil; }" of
                    Err msg ->
                        String.contains "no active defun" msg

                    Ok _ ->
                        False
               )
        )

    -- ===== T8fix — activeSurf regression (handoff-osier-tier2-t8fix) =====
    -- Guard variants of ONE key lower 1:1 IN ORDER (LowerToIr.lowerAll), so
    -- the ACTIVE variant must be selected POSITIONALLY.  The old key-only
    -- `Dict.fromList (List.map (\d -> (d.key, d)) lowered)` was last-wins:
    -- under a flag combo whose ACTIVE variant is NOT last in source order it
    -- fetched and spliced the INACTIVE variant's tree.  This row pins that
    -- exact shape — the @rec variant FIRST, its @!rec twin LAST, pipeline
    -- run under [Rec] so the FIRST is active — and requires the dict to
    -- carry the FIRST variant's tree (and, as a control, the @!rec tree
    -- under []).  Both arms are J8-exactly-one-active, so Check runs too:
    -- the row tests the wiring, not the checker.
    , check
        "T8fix activeSurf regression: two exclusive @rec/@!rec variants of one key, ACTIVE variant FIRST; under [Rec] the splice dict carries the ACTIVE (first) variant's lowered tree, not the last-lowered (inactive) one — and under [] the @!rec tree"
        (let
            src =
                "@rec defun Rt.gv() -> val { return mkbool(1); }\n\n@!rec defun Rt.gv() -> val { return mkbool(0); }"
         in
         case Parse.parseProgram src of
            Err _ ->
                False

            Ok ast ->
                case Check.checkProgram Dict.empty [ Ast.Rec ] ast of
                    Err _ ->
                        False

                    Ok () ->
                        case LowerToIr.lowerProgram ast of
                            Err _ ->
                                False

                            Ok lowered ->
                                case lowered of
                                    dActive :: dInactive :: _ ->
                                        (dActive /= dInactive)
                                            && (Rt.activeSurf [ Ast.Rec ] (List.map2 Tuple.pair ast lowered)
                                                    == Dict.fromList [ ( "Rt.gv", dActive ) ]
                                               )
                                            && (Rt.activeSurf [] (List.map2 Tuple.pair ast lowered)
                                                    == Dict.fromList [ ( "Rt.gv", dInactive ) ]
                                               )

                                    _ ->
                                        False
        )
    -- ===== T8b — the surface grammar extended: negative literals + the full Rt.* key charset =====
    -- The TWO MEASURED WALLS T8 hit (recorded in RtSource's wave-1 note):
    -- (1) `Rt.close` compares against `Lit (LNumber -2)` — only a negative
    -- literal node is that tree (`0 - 2` lowers to a RawBin RSub), so a `-`
    -- immediately followed by digits in OPERAND position now parses as one
    -- negative literal; infix `-` stays subtraction, and a `-` not touching
    -- its digits is the loud no-unary-minus reject.  (2) The key charset
    -- gains `- + = < >` (MEASURED over the Rt.* key set), read ONLY in key
    -- positions (defun header, `call` name) so the expression lexer — and
    -- therefore every existing parse — is untouched.  Accept rows assert
    -- exact trees; reject rows pin the reason fragment.

    -- ---- wall 1: negative literals ----
    , check "parse: -2 is ONE negative literal (the Rt.close wall -- not 0 - 2, whose tree is a RawBin RSub)"
        (Parse.parseExp "-2" == Ok (Ast.EInt -2))
    , check "parse: -100 (the readFull/openat sentinel -- the T9/T14 wall)"
        (Parse.parseExp "-100" == Ok (Ast.EInt -100))
    , check "parse: -2.5 is one negative float literal (same rule, the float form)"
        (Parse.parseExp "-2.5" == Ok (Ast.EFlt -2.5))
    , check "parse: `x - 2` is still binary subtraction (infix - unchanged by the literal rule)"
        (Parse.parseExp "x - 2" == Ok (Ast.EWordBin Ast.WSub (Ast.EVar "x") (Ast.EInt 2)))
    , check "parse: `5 - -2` is subtraction of a negative literal (operator -, operand literal)"
        (Parse.parseExp "5 - -2" == Ok (Ast.EWordBin Ast.WSub (Ast.EInt 5) (Ast.EInt -2)))
    , check "parse REJECTS `- 2` (space after the -: not a literal, and there is no unary minus)"
        (case Parse.parseExp "- 2" of
            Err msg ->
                String.contains "no unary minus" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS a bare `-` (no operand to its right)"
        (case Parse.parseExp "-" of
            Err msg ->
                String.contains "no unary minus" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS `-x` (no unary minus on names -- only digits may follow the -)"
        (case Parse.parseExp "-x" of
            Err msg ->
                String.contains "no unary minus" msg

            Ok _ ->
                False
        )

    -- ---- wall 2: the key charset (each measured ambiguity pinned) ----
    , check "parse: defun Rt.write-byte(..) lexes its - key verbatim, calls the Rt.= key, and passes -1 -- both walls in one defun"
        (Parse.parseProgram
            "defun Rt.write-byte(fd: val, b: val) -> val {\n  word r = rawcall write(1, b, 1);\n  return call Rt.=(r, -1);\n}"
            == Ok
                [ { key = "Rt.write-byte"
                  , flags = []
                  , params =
                        [ { name = "fd", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body =
                        { stmts =
                            [ Ast.SBind Ast.TWord "r" (Ast.ERawCall "write" [ Ast.EInt 1, Ast.EVar "b", Ast.EInt 1 ])
                            ]
                        , term = Ast.TRet (Ast.ECall "Rt.=" [ Ast.EVar "r", Ast.EInt -1 ])
                        }
                  }
                ]
        )
    , check "parse: defun Rt.address->(..) -> .. -- the key's trailing -> is not the header's arrow (the key stops at the '(')"
        (Parse.parseProgram
            "defun Rt.address->(v: val, i: val) -> val {\n  return vecload(v, i);\n}"
            == Ok
                [ { key = "Rt.address->"
                  , flags = []
                  , params =
                        [ { name = "v", ty = Ast.TVal }
                        , { name = "i", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body = { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.VecLoad [ Ast.EVar "v", Ast.EVar "i" ]) }
                  }
                ]
        )
    , check "parse: defun Rt.=(..) with a body binding `word t = a == b;` -- = is a key char, a bind = and a compare == in the body still parse"
        (Parse.parseProgram
            "defun Rt.=(a: val, b: val) -> val {\n  word t = a == b;\n  return mkbool(t);\n}"
            == Ok
                [ { key = "Rt.="
                  , flags = []
                  , params =
                        [ { name = "a", ty = Ast.TVal }
                        , { name = "b", ty = Ast.TVal }
                        ]
                  , ret = Ast.TVal
                  , body =
                        { stmts =
                            [ Ast.SBind Ast.TWord "t" (Ast.EWordCmp Ast.WCeq (Ast.EVar "a") (Ast.EVar "b"))
                            ]
                        , term = Ast.TRet (Ast.EBuiltin Ast.MkBool [ Ast.EVar "t" ])
                        }
                  }
                ]
        )
    , check "parse: call Rt.=(a, b) -- a pure-symbol key in call position"
        (Parse.parseExp "call Rt.=(a, b)" == Ok (Ast.ECall "Rt.=" [ Ast.EVar "a", Ast.EVar "b" ]))
    , check "parse: call Rt.- (a, b) -- a symbol key stops at whitespace and the args still parse"
        (Parse.parseExp "call Rt.- (a, b)" == Ok (Ast.ECall "Rt.-" [ Ast.EVar "a", Ast.EVar "b" ]))
    , check "parse REJECTS `call Rt.write - byte(x)` -- a key never crosses whitespace, so this is a loud expected-( reject, never key+subtraction"
        (case Parse.parseExp "call Rt.write - byte(x)" of
            Err msg ->
                String.contains "expected `(`" msg

            Ok _ ->
                False
        )
    , check "parse REJECTS `defun Rt.(..)` -- an empty key segment (trailing dot)"
        (case Parse.parseProgram "defun Rt.(x: val) -> val {\n  return 0;\n}" of
            Err msg ->
                String.contains "expected a defun key" msg

            Ok _ ->
                False
        )
    , check "parse: defun Rt.c-strlen(..) whose body subtracts -- the SAME - is a key separator in the header and binary minus in the body"
        (Parse.parseProgram
            "defun Rt.c-strlen(s: val) -> val {\n  word n = rawcall strlen(s);\n  return n - 1;\n}"
            == Ok
                [ { key = "Rt.c-strlen"
                  , flags = []
                  , params = [ { name = "s", ty = Ast.TVal } ]
                  , ret = Ast.TVal
                  , body =
                        { stmts = [ Ast.SBind Ast.TWord "n" (Ast.ERawCall "strlen" [ Ast.EVar "s" ]) ]
                        , term = Ast.TRet (Ast.EWordBin Ast.WSub (Ast.EVar "n") (Ast.EInt 1))
                        }
                  }
                ]
        )

    -- ===== T9b — the surface grammar extended: the ?: value join =====
    -- The THIRD measured grammar wall (T9): `Rt.readFileGo`'s growB binder
    -- holds an If in a Let VALUE position and `Ast.Exp` had no if-form, so
    -- `ty x = e;` could not spell it and the grammar's no-rebinding rule
    -- blocks every statement restructure.  The plan L6 escape hatch is now
    -- spelled `c ? t : e` — precedence row 0 (loosest: looser than `||`,
    -- tighter than a call argument's comma), right-associative, cond :val,
    -- branches AGREE on a class.  `?:` is the ONLY spelling (no
    -- expression-position `if (c) {..} else {..}`: `if` is a legal plain
    -- variable there today, and the statement `if` keeps its
    -- block-position dispatch).  Accept rows assert exact trees / exact
    -- lowered shapes (the `Let { x = If { .. } }` the growB binder needs);
    -- reject rows pin the reason fragment.

    -- ---- parse: shape and precedence ----
    , check "parse: c ? a : b is EIf (the value join's exact tree)"
        (Parse.parseExp "c ? a : b" == Ok (Ast.EIf (Ast.EVar "c") (Ast.EVar "a") (Ast.EVar "b")))
    , check "parse: ?: binds LOOSER than || ((a || b) ? c : d) and TIGHTER than a call argument's comma (f(x ? y : z, w) is TWO args)"
        (Parse.parseExp "a || b ? c : d"
            == Ok (Ast.EIf (Ast.EShortOr (Ast.EVar "a") (Ast.EVar "b")) (Ast.EVar "c") (Ast.EVar "d"))
            && Parse.parseExp "call Rt.f(x ? y : z, w)"
                == Ok
                    (Ast.ECall "Rt.f"
                        [ Ast.EIf (Ast.EVar "x") (Ast.EVar "y") (Ast.EVar "z")
                        , Ast.EVar "w"
                        ]
                    )
        )
    , check "parse: ?: is RIGHT-associative and nests in BOTH slots (each ?: consumes its own :, so both two-colon shapes are unambiguous)"
        (Parse.parseExp "a ? b : c ? d : e"
            == Ok (Ast.EIf (Ast.EVar "a") (Ast.EVar "b") (Ast.EIf (Ast.EVar "c") (Ast.EVar "d") (Ast.EVar "e")))
            && Parse.parseExp "a ? b ? c : d : e"
                == Ok (Ast.EIf (Ast.EVar "a") (Ast.EIf (Ast.EVar "b") (Ast.EVar "c") (Ast.EVar "d")) (Ast.EVar "e"))
        )
    , check "parse REJECTS a ?: with a missing `:` (the arm is required -- no silent fall-through)"
        (case Parse.parseExp "c ? a" of
            Err msg ->
                String.contains "expected `:`" msg

            Ok _ ->
                False
        )

    -- ---- check: the class judgment (cond :val via checkCond, branches AGREE) ----
    , checkOk "check: ?: accept — :val branches, :val cond (the mkbool-boxed compare)"
        "defun Rt.q(a: val) -> val {\n  val x = mkbool(tagis(a, 1) == 1) ? mknum(1) : mknil;\n  return x;\n}"
    , checkOk "check: ?: accept — :word branches agree (the join can yield a raw word too)"
        "defun Rt.qw(a: val) -> word {\n  word w = mkbool(tagis(a, 1) == 1) ? 1 : 0;\n  return w;\n}"
    , checkErr "check: ?: REJECT — branches disagree on class (then :word, else :val) — a LOUD reject, never a silent widen"
        "branches disagree"
        "defun Rt.qbad(a: val) -> val {\n  word x = mkbool(tagis(a, 1) == 1) ? 1 : mknil;\n  return mknum(x);\n}"
    , checkErr "check: ?: REJECT — a non-:val cond (a raw word compare must be boxed: the SAME judgment as the statement if)"
        "condition must be val"
        "defun Rt.qcond(a: val) -> val {\n  word x = payload(a, 0) == 1 ? 2 : 3;\n  return mknum(x);\n}"

    -- ---- lower: the `Let { x = If { .. } }` join shapes (existing L1 + mkIf; no new machinery) ----
    , check "lower: the ?: VALUE JOIN — `val x = c ? t : e;` lowers to Let { x = If { .. } } (the Rt.readFileGo growB binder's wall)"
        (case lowlBody "defun Rt.growB(n : val) -> val {\n  val x = mkbool(tagis(n, 1) == 1) ? mknum(1) : mknum(2);\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                                    (lmkNum (ltn 1))
                                    (lmkNum (ltn 2))
                              )
                            ]
                            (ltv 2)
                        )

            Err _ ->
                False
        )
    , check "lower: nested ?: — the else arm re-enters the ?: level, each If carrying its own join labels"
        (case lowlBody "defun Rt.qnest(n : val) -> val {\n  val x = mkbool(tagis(n, 1) == 1) ? mknum(1) : mkbool(tagis(n, 2) == 1) ? mknum(2) : mknum(3);\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                                    (lmkNum (ltn 1))
                                    (liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 2) (ltn 1)))
                                        (lmkNum (ltn 2))
                                        (lmkNum (ltn 3))
                                    )
                              )
                            ]
                            (ltv 2)
                        )

            Err _ ->
                False
        )
    , check "lower: a ?: whose branches are CALLS (the Rt.eq/Rt.deepEq join shape) lowers in arm order"
        (case lowlBody "defun Rt.qcall(a: val, b: val) -> val {\n  val r = mkbool(tagis(a, 2) == 1) ? call Rt.thn(a, b) : call Rt.els(a, b);\n  return r;\n}\n\ndefun Rt.thn(x: val, y: val) -> val {\n  return y;\n}\n\ndefun Rt.els(x: val, y: val) -> val {\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 3
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 2) (ltn 1)))
                                    (lcallR "Rt.thn" [ ltv 1, ltv 2 ])
                                    (lcallR "Rt.els" [ ltv 1, ltv 2 ])
                              )
                            ]
                            (ltv 3)
                        )

            Err _ ->
                False
        )

    -- ===== T23 — the surface grammar extended: the BLOCK-BRANCH if =====
    -- The FOURTH and last measured grammar wall: the three remaining DSL
    -- holdouts (Rt.readFileGo's growB, Rt.epCmd's ago/rgo, Rt.childCd's
    -- dirN #2) all bind an If in a LET-VALUE whose BRANCHES carry
    -- let-chains and whose VALUE the continuation reads.  `?:` cannot
    -- spell those (expression branches, no statements) and the
    -- statement/term `if` cannot (no value in an initializer slot), so
    -- `if (cond) { block } else { block }` is now an EXPRESSION (an atom):
    -- each branch is the EXISTING block grammar, its terminator is the
    -- branch's value, else is REQUIRED, and the lowering is the TERM if's
    -- own (`mkIf` over two lowered blocks — no new machinery).  The
    -- statement dispatch keeps its own `if` arm, so SIf/TIf parse exactly
    -- as before (row below), and the `?:` join is a different token.
    -- Rows: parse shapes/positions/rejects, the class judgments, the
    -- lowering (canon vs hand-built), and THE ACCEPTANCE ROW: growB's
    -- region spelled on the surface lowers canon-EQUAL to HEAD's DSL tree.

    -- ---- parse: shape and positions ----
    , check "parse: the block-branch if — `if (c) { return a; } else { return b; }` is EIfBlock (T23; else REQUIRED)"
        (Parse.parseExp "if (c) { return a; } else { return b; }"
            == Ok
                (Ast.EIfBlock (Ast.EVar "c")
                    { stmts = [], term = Ast.TRet (Ast.EVar "a") }
                    { stmts = [], term = Ast.TRet (Ast.EVar "b") }
                )
        )
    , check "parse: the block-branch if in a CALL ARGUMENT (a value slot like any atom; the comma still separates args)"
        (Parse.parseExp "call Rt.f(if (c) { return 1; } else { return 2; }, w)"
            == Ok
                (Ast.ECall "Rt.f"
                    [ Ast.EIfBlock (Ast.EVar "c")
                        { stmts = [], term = Ast.TRet (Ast.EInt 1) }
                        { stmts = [], term = Ast.TRet (Ast.EInt 2) }
                    , Ast.EVar "w"
                    ]
                )
        )
    , check "parse: the block-branch if NESTED — a branch block binds an inner block-if (a block's value needs a binder: a bare expression is not a term)"
        (Parse.parseExp "if (c) { val t = if (d) { return 1; } else { return 2; }; return t; } else { return 0; }"
            == Ok
                (Ast.EIfBlock (Ast.EVar "c")
                    { stmts =
                        [ Ast.SBind Ast.TVal "t"
                            (Ast.EIfBlock (Ast.EVar "d")
                                { stmts = [], term = Ast.TRet (Ast.EInt 1) }
                                { stmts = [], term = Ast.TRet (Ast.EInt 2) }
                            )
                        ]
                    , term = Ast.TRet (Ast.EVar "t")
                    }
                    { stmts = [], term = Ast.TRet (Ast.EInt 0) }
                )
        )
    , check "parse REJECTS a block-branch if with a missing `else` (an expression needs a value from both arms — no silent fall-through)"
        (case Parse.parseExp "if (c) { return a; }" of
            Err msg ->
                String.contains "expected `else`" msg

            Ok _ ->
                False
        )
    , check "parse: the STATEMENT if is untouched — the same tokens at statement position are SIf with an else block, never EIfBlock"
        (case Parse.parseBlock "{ if (c) { return mknum(1); } else { return mknum(2); } return mknil; }" of
            Ok b ->
                b.stmts
                    == [ Ast.SIf (Ast.EVar "c")
                            { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EInt 1 ]) }
                            (Just { stmts = [], term = Ast.TRet (Ast.EBuiltin Ast.MkNum [ Ast.EInt 2 ]) })
                       ]
                    && (case b.term of
                            Ast.TRet (Ast.EBuiltin Ast.MkNil []) ->
                                True

                            _ ->
                                False
                       )

            Err _ ->
                False
        )
    , check "parse: the ?: join is UNTOUCHED by the block-branch if — a ?: arm can BE one (the arm parses the atom, the outer `:` still binds)"
        (Parse.parseExp "c ? if (a) { return 1; } else { return 2; } : d"
            == Ok
                (Ast.EIf (Ast.EVar "c")
                    (Ast.EIfBlock (Ast.EVar "a")
                        { stmts = [], term = Ast.TRet (Ast.EInt 1) }
                        { stmts = [], term = Ast.TRet (Ast.EInt 2) }
                    )
                    (Ast.EVar "d")
                )
        )

    -- ---- check: the class judgments (checkCond reused; branch classes AGREE) ----
    , checkOk "check: block-if accept — :val branches AGREE, :val cond (the growB shape's judgment)"
        "defun Rt.iba(a: val) -> val {\n  val x = if (mkbool(tagis(a, 1) == 1)) { return mknum(1); } else { return mknil; };\n  return x;\n}"
    , checkOk "check: block-if accept — :word branches agree in a -> word defun (the form composes in a word slot too)"
        "defun Rt.ibw(a: val) -> word {\n  word w = if (mkbool(tagis(a, 1) == 1)) { return 1; } else { return 2; };\n  return w;\n}"
    , checkErr "check: block-if REJECT — the agreed branch class flows to the bind slot: a :val join bound :word is a LOUD J1 reject"
        "declares word but its initializer is val"
        "defun Rt.ibbad(a: val) -> val {\n  word w = if (mkbool(tagis(a, 1) == 1)) { return mknum(1); } else { return mknum(2); };\n  return mknum(w);\n}"
    , checkErr "check: block-if REJECT — a true val-vs-word BRANCH mismatch (MEASURED: every term's class is the defun's -> ty — J6 pins each return — so the route is J6's, and the branch-agreement arm is correct-by-construction through the existing term grammar)"
        "J6"
        "defun Rt.ibarm(a: val) -> word {\n  word w = if (mkbool(tagis(a, 1) == 1)) { return 1; } else { return mknil; };\n  return w;\n}"
    , checkErr "check: block-if REJECT — a non-:val cond (a raw word compare must be boxed: the SAME checkCond as every if)"
        "condition must be val"
        "defun Rt.ibcond(a: val) -> val {\n  val x = if (payload(a, 0) == 1) { return mknum(1); } else { return mknum(2); };\n  return x;\n}"

    -- ---- lower: the TERM if's machinery in a value slot ----
    , check "lower: block-if — `val x = if (c) {..} else {..};` lowers to Let { x = If { branch values in order } } (the TIf machinery, value position)"
        (case lowlBody "defun Rt.ibl(n : val) -> val {\n  val x = if (mkbool(tagis(n, 1) == 1)) { return mknum(1); } else { return mknum(2); };\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                                    (lmkNum (ltn 1))
                                    (lmkNum (ltn 2))
                              )
                            ]
                            (ltv 2)
                        )

            Err _ ->
                False
        )
    , check "lower: block-if — a branch's STATEMENTS fold into the branch's 1-binder Let chain, its terminator is the branch's value (If { then = lets .., else = .. } in a let-value: THE wall shape)"
        (case lowlBody "defun Rt.iblets(a : val) -> val {\n  val x = if (mkbool(tagis(a, 1) == 1)) {\n    word u = payload(a, 0) + 1;\n    word v = u + 1;\n    return mknum(v);\n  } else {\n    return mknil;\n  };\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 4
                              , liff (lmkBool (lcmpW RCeq (ltagIs (ltv 1) 1) (ltn 1)))
                                    (llets
                                        [ ( ltb 2, liadd (lwOf (ltv 1)) (ltn 1) )
                                        , ( ltb 3, liadd (ltv 2) (ltn 1) )
                                        ]
                                        (lmkNum (ltv 3))
                                    )
                                    lmkNilV
                              )
                            ]
                            (ltv 4)
                        )

            Err _ ->
                False
        )
    , check "lower: block-if — the Rt.childCd dirN-#2 shape: SHADOWED rebinding reads the PREVIOUS binder in its own initializer, and a one-sided diverging if inside a branch ELSE-NESTS (the second wall's form)"
        (case lowlBody "defun Rt.ibdirn(argcN : val, stN : val) -> val {\n  val dirN = if (mkbool(payload(argcN, 0) > 1)) { return mknum(1); } else { return mknum(0); };\n  val dirN = if (mkbool(payload(dirN, 0) == 0)) {\n    return call Rt.envHome(stN);\n  } else {\n    val ln = call Rt.cStrLenGo(dirN, mknum(0));\n    if (mkbool(payload(ln, 0) == 0)) { return call Rt.envHome(stN); }\n    return dirN;\n  };\n  return dirN;\n}\n\ndefun Rt.envHome(st : val) -> val {\n  return st;\n}\n\ndefun Rt.cStrLenGo(s : val, i : val) -> val {\n  return i;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 3, liff (lmkBool (lcmpW RCgts (lwOf (ltv 1)) (ltn 1))) (lmkNum (ltn 1)) (lmkNum (ltn 0)) )
                            , ( ltb 5
                              , liff (lmkBool (lcmpW RCeq (lwOf (ltv 3)) (ltn 0)))
                                    (lcallR "Rt.envHome" [ ltv 2 ])
                                    (llets
                                        [ ( ltb 4, lcallR "Rt.cStrLenGo" [ ltv 3, lmkNum (ltn 0) ] ) ]
                                        (liff (lmkBool (lcmpW RCeq (lwOf (ltv 4)) (ltn 0)))
                                            (lcallR "Rt.envHome" [ ltv 2 ])
                                            (ltv 3)
                                        )
                                    )
                              )
                            ]
                            (ltv 5)
                        )

            Err _ ->
                False
        )

    -- ---- THE ACCEPTANCE ROW: HEAD's growB tree, spelled on the surface ----
    -- Rt.readFileGo's grow region verbatim (RtPrims-HEAD, the `growB =`
    -- binder): the If bound in a LET-VALUE, its branches carrying let-
    -- chains (newcapW/mW and the 8-statement store/memGo/free chain), the
    -- bound value READ by the continuation (`payload(growB, 0) == 1` is
    -- the OOM stop).  memGo/envHome/cStrLenGo stand in as one-line surface
    -- defuns (J2 needs the keys defined; their BODIES are irrelevant — the
    -- row pins the growB region's SHAPE).
    , check "lower: THE T23 ACCEPTANCE ROW — Rt.readFileGo's growB region, spelled with the block-branch if, lowers canon-EQUAL to HEAD's DSL tree (the wall is closed)"
        (case lowlBody "defun Rt.growBwall(blkN : val, nV : val) -> val {\n  word lenW = wload(payload(blkN, 0), 3);\n  word capW = wload(payload(blkN, 0), 4);\n  word neededW = lenW + payload(nV, 0);\n  val growB = if (mkbool(neededW > capW)) {\n    word newcapW = neededW + (capW * 2 - neededW) * (capW * 2 > neededW);\n    word mW = rawcall malloc(newcapW);\n    if (mkbool(mW == 0)) { return mknum(1); }\n    word oldW = wload(payload(blkN, 0), 2);\n    wstore(payload(blkN, 0), 6, oldW);\n    wstore(payload(blkN, 0), 7, mW);\n    wstore(payload(blkN, 0), 8, lenW);\n    call Rt.memGo(mknum(payload(blkN, 0) + 48), mknum(0));\n    rawcall free(oldW);\n    wstore(payload(blkN, 0), 2, mW);\n    wstore(payload(blkN, 0), 4, newcapW);\n    return mknum(0);\n  } else {\n    return mknum(0);\n  };\n  if (mkbool(payload(growB, 0) == 1)) { return mknil; }\n  return mknum(payload(growB, 0));\n}\n\ndefun Rt.memGo(blk : val, i : val) -> val {\n  return i;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 3, Unsafe (RawWordLoad { ptr = lwOf (ltv 1), index = ltn 3 }) )
                            , ( ltb 4, Unsafe (RawWordLoad { ptr = lwOf (ltv 1), index = ltn 4 }) )
                            , ( ltb 5, liadd (ltv 3) (lwOf (ltv 2)) )
                            , ( ltb 16
                              , liff (lmkBool (lcmpW RCgts (ltv 5) (ltv 4)))
                                    (llets
                                        [ ( ltb 6
                                          , liadd (ltv 5)
                                                (limul (lisub (limul (ltv 4) (ltn 2)) (ltv 5))
                                                    (lcmpW RCgts (limul (ltv 4) (ltn 2)) (ltv 5))
                                                )
                                          )
                                        , ( ltb 7, lcallW "malloc" [ ltv 6 ] )
                                        ]
                                        (liff (lmkBool (lcmpW RCeq (ltv 7) (ltn 0)))
                                            (lmkNum (ltn 1))
                                            (llets
                                                [ ( ltb 8, Unsafe (RawWordLoad { ptr = lwOf (ltv 1), index = ltn 2 }) )
                                                , ( ltb 9, Unsafe (RawWordStore { ptr = lwOf (ltv 1), index = ltn 6, value = ltv 8 }) )
                                                , ( ltb 10, Unsafe (RawWordStore { ptr = lwOf (ltv 1), index = ltn 7, value = ltv 7 }) )
                                                , ( ltb 11, Unsafe (RawWordStore { ptr = lwOf (ltv 1), index = ltn 8, value = ltv 3 }) )
                                                , ( ltb 12, lcallR "Rt.memGo" [ lmkNum (liadd (lwOf (ltv 1)) (ltn 48)), lmkNum (ltn 0) ] )
                                                , ( ltb 13, lcallW "free" [ ltv 8 ] )
                                                , ( ltb 14, Unsafe (RawWordStore { ptr = lwOf (ltv 1), index = ltn 2, value = ltv 7 }) )
                                                , ( ltb 15, Unsafe (RawWordStore { ptr = lwOf (ltv 1), index = ltn 4, value = ltv 6 }) )
                                                ]
                                                (lmkNum (ltn 0))
                                            )
                                        )
                                    )
                                    (lmkNum (ltn 0))
                              )
                            ]
                            (liff (lmkBool (lcmpW RCeq (lwOf (ltv 16)) (ltn 1)))
                                lmkNilV
                                (lmkNum (lwOf (ltv 16)))
                            )
                        )

            Err _ ->
                False
        )

    -- ===== T24 — the LAST THREE wall-class holdouts (handoff-osier-tier2-t24) =====
    -- Rt.readFileGo / Rt.epCmd / Rt.childCd migrated on the T23 block-branch
    -- if.  The three rows below are the SPLICE rows (each key's program
    -- defun IS the surface lowering — structural ==, so a surviving
    -- builder/seat cannot satisfy it); the corpus is the byte-level proof
    -- and the T23 acceptance rows pin the two canonical spellings (growB,
    -- dirN#2).  The T9/T16/T17 row-comment corrections above record the
    -- earlier deferrals.
    , t8SplicedRow rt "Rt.readFileGo"
    , t8SplicedRow rt "Rt.epCmd"
    , t8SplicedRow rt "Rt.childCd"
    ]


{-| T8: the one migrated key's row — the built program's defun at `key` IS
the surface lowering (structural ==, see the T8 block comment for why a
DSL-built defun cannot satisfy it).
-}
t8SplicedRow : Rt.Runtime -> String -> String
t8SplicedRow rt key =
    check
        ("T8 splice: " ++ key ++ " in the built program IS the surface defun (not an Elm builder)")
        (case ( rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ], rtProgram rt True True True ) of
            ( Ok s, prog ) ->
                case ( Dict.get key s, defunByKey key prog ) of
                    ( Just sd, Just pd ) ->
                        pd == sd

                    _ ->
                        False

            _ ->
                False
        )


{-| T18's twin of `t8SplicedRow`, over the GC half: `rt.program` is the
prim/helper half and carries no gc keys, so the row reads `rtProgramGc` —
the gcProgram list with its surface replacements in place.  Structural
`==` (binder ids/names differ between the DSL builder and the surface
pipeline, so a surviving DSL/seat body cannot satisfy it).
-}
t18SplicedRow : Rt.Runtime -> String -> String
t18SplicedRow rt key =
    check
        ("T18 splice: " ++ key ++ " in the spliced gc program IS the surface defun (not an Elm builder/seat)")
        (case ( rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ], rtProgramGc rt True True True ) of
            ( Ok s, prog ) ->
                case ( Dict.get key s, defunByKey key prog ) of
                    ( Just sd, Just pd ) ->
                        pd == sd

                    _ ->
                        False

            _ ->
                False
        )


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


{-| The SF1 probes: malformed self-Apps an Rt body must never contain today —
under-applied (0 args, 1 param), over-applied (2 args, 1 param), and forced
(saturated args but force=True).  Lower routes all three through
lowerGRefValue + rtApply (a partial-closure BUILD, a real safepoint), so the
classifier must mark the defun allocating (framed), never 'edge'.
-}
probeUnderSelfApp : Defun
probeUnderSelfApp =
    { key = "Rt.probeUnder"
    , value =
        Lam
            { params = [ { id = 1, name = "a1" } ]
            , body = App { fn = GRef { key = "Rt.probeUnder", force = False }, args = [] }
            }
    }


probeOverSelfApp : Defun
probeOverSelfApp =
    { key = "Rt.probeOver"
    , value =
        Lam
            { params = [ { id = 1, name = "a1" } ]
            , body =
                App
                    { fn = GRef { key = "Rt.probeOver", force = False }
                    , args = [ Lit (LNumber 0), Lit (LNumber 1) ]
                    }
            }
    }


probeForcedSelfApp : Defun
probeForcedSelfApp =
    { key = "Rt.probeForced"
    , value =
        Lam
            { params = [ { id = 1, name = "a1" } ]
            , body =
                App
                    { fn = GRef { key = "Rt.probeForced", force = True }
                    , args = [ Lit (LNumber 0) ]
                    }
            }
    }


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


{-| The T4/T5 rows' drivers: parse a surface program, then run the checker
against an EMPTY extern table (the extern row calls `Check.checkProgram`
directly with a table).  `checkOk` asserts acceptance; `checkErr` asserts
a rejection whose message names the judgment (the fragment pin — a parse
failure would Err WITHOUT the fragment and fail the row loudly).  The
`Flags` variants drive J8's rows: the active flag set is a checker
PARAMETER (T7 will derive it from `rt.program`'s three Bools).
-}
chkFlags : List Ast.Flag -> String -> Result String ()
chkFlags flags src =
    case Parse.parseProgram src of
        Ok program ->
            Check.checkProgram Dict.empty flags program

        Err e ->
            Err ("parse: " ++ e)


chk : String -> Result String ()
chk src =
    chkFlags [] src


checkOkFlags : String -> List Ast.Flag -> String -> String
checkOkFlags name flags src =
    check name
        (case chkFlags flags src of
            Ok () ->
                True

            Err _ ->
                False
        )


checkErrFlags : String -> List Ast.Flag -> String -> String -> String
checkErrFlags name flags frag src =
    check name
        (case chkFlags flags src of
            Err msg ->
                String.contains frag msg

            Ok () ->
                False
        )


checkOk : String -> String -> String
checkOk name src =
    checkOkFlags name [] src


checkErr : String -> String -> String -> String
checkErr name frag src =
    checkErrFlags name [] frag src


{-| Contract-4 return-taint floor (M4-enforce U1): parse an Elm module, then run
`Mid.TaintCheck.checkGroup` against the single tainted key `Tainty.make`.  The
module is a synthetic single-file group; a parse failure is an `Err` so a row
comparing on `Err _ -> False` cannot pass vacuously on a source that did not
even parse.
-}
taintCheck : String -> Result String ()
taintCheck src =
    case Elm.Parser.parseToFile src of
        Ok file ->
            TaintCheck.checkGroup (Set.singleton "Tainty.make") [ file ]

        Err _ ->
            Err "parse"


taintRejected : String -> Bool
taintRejected src =
    case taintCheck src of
        Err msg ->
            String.contains "taint error" msg

        Ok () ->
            False


taintAccepted : String -> Bool
taintAccepted src =
    case taintCheck src of
        Ok () ->
            True

        Err _ ->
            False





-- ======================= Tier-2 T6: the lowerer's oracle =======================

{-| The T6 driver: parse + Check + lower.  A parse or check failure is an
`Err` (a row comparing on `Err _ -> False` fails loudly — a row whose
source does not even PARSE is a vacuous pass, so every row's expected
tree is only trusted once the pipeline reaches the lowerer).
-}
lowlFlags : List Ast.Flag -> String -> Result String (List Defun)
lowlFlags flags src =
    case Parse.parseProgram src of
        Err e ->
            Err ("parse: " ++ e)

        Ok program ->
            case Check.checkProgram Dict.empty flags program of
                Err e ->
                    Err e

                Ok () ->
                    LowerToIr.lowerProgram program


lowl : String -> Result String (List Defun)
lowl src =
    lowlFlags [] src


lowlBody : String -> Result String Exp
lowlBody src =
    case lowl src of
        Ok (d :: _) ->
            case d.value of
                Lam l ->
                    Ok l.body

                _ ->
                    Err "lower: defun value is not a Lam"

        Ok [] ->
            Err "lower: no defuns"

        Err e ->
            Err e


defunByKey : String -> List Defun -> Maybe Defun
defunByKey key defuns =
    case defuns of
        [] ->
            Nothing

        d :: rest ->
            if d.key == key then
                Just d

            else
                defunByKey key rest


{-| CANONICAL SHAPE.  Renumbers every binder in first-appearance order,
zeroes binder names (provenance, never emitted) and zeroes the invented
If/ShortAnd/ShortOr label strings (plan fact F1: Lower invents its own
labels and never reads the tree's).  Everything else is kept EXACT —
constructors, argument order, GRef key/force, tag constants, symbol
strings, literal payloads, and the Var-to-binder correspondence (a wrong
Var or an id collision shows, because uses renumber consistently WITH
their binders).  Two trees are the same SHAPE iff their canons are `==`.
-}
type alias CSt =
    { next : Int
    , map : Dict Int Int
    }


canon : Exp -> Exp
canon e =
    Tuple.first (cexp { next = 1, map = Dict.empty } e)


cvar : CSt -> Int -> Int
cvar st i =
    case Dict.get i st.map of
        Just j ->
            j

        Nothing ->
            i


cbinder : CSt -> Binder -> ( Binder, CSt )
cbinder st b =
    ( { id = st.next, name = "" }
    , { next = st.next + 1, map = Dict.insert b.id st.next st.map }
    )


cbinders : CSt -> List Binder -> ( List Binder, CSt )
cbinders st bs =
    case bs of
        [] ->
            ( [], st )

        b :: rest ->
            let
                ( b1, st1 ) =
                    cbinder st b

                ( rest1, st2 ) =
                    cbinders st1 rest
            in
            ( b1 :: rest1, st2 )


cexps : CSt -> List Exp -> ( List Exp, CSt )
cexps st es =
    case es of
        [] ->
            ( [], st )

        x :: rest ->
            let
                ( x1, st1 ) =
                    cexp st x

                ( rest1, st2 ) =
                    cexps st1 rest
            in
            ( x1 :: rest1, st2 )


cletbinders : CSt -> List LetBinder -> ( List LetBinder, CSt )
cletbinders st bs =
    case bs of
        [] ->
            ( [], st )

        b :: rest ->
            case b of
                LetBind lb ->
                    let
                        ( binder, st1 ) =
                            cbinder st lb.binder

                        ( v, st2 ) =
                            cexp st1 lb.value

                        ( rest1, st3 ) =
                            cletbinders st2 rest
                    in
                    ( LetBind { lb | binder = binder, value = v } :: rest1, st3 )

                LetDestruct ld ->
                    let
                        ( sid, st1 ) =
                            cbinder st ld.scrutId

                        ( binds, st2 ) =
                            cpathbinds st1 ld.binds

                        ( v, st3 ) =
                            cexp st2 ld.value

                        ( rest1, st4 ) =
                            cletbinders st3 rest
                    in
                    ( LetDestruct { ld | scrutId = sid, value = v, binds = binds, badLabel = "", okLabel = "" } :: rest1, st4 )


cpathbinds : CSt -> List ( Binder, ValuePath ) -> ( List ( Binder, ValuePath ), CSt )
cpathbinds st binds =
    case binds of
        [] ->
            ( [], st )

        ( b, path ) :: rest ->
            let
                ( b1, st1 ) =
                    cbinder st b

                ( rest1, st2 ) =
                    cpathbinds st1 rest
            in
            ( ( b1, path ) :: rest1, st2 )


calts : CSt -> List Alt -> ( List Alt, CSt )
calts st alts =
    case alts of
        [] ->
            ( [], st )

        a :: rest ->
            let
                ( binds, st1 ) =
                    cpathbinds st a.binds

                ( body, st2 ) =
                    cexp st1 a.body

                ( rest1, st3 ) =
                    calts st2 rest
            in
            ( { a | binds = binds, body = body, nextLabel = "" } :: rest1, st3 )


cfields : CSt -> List ( String, Exp ) -> ( List ( String, Exp ), CSt )
cfields st fs =
    case fs of
        [] ->
            ( [], st )

        ( name, x ) :: rest ->
            let
                ( x1, st1 ) =
                    cexp st x

                ( rest1, st2 ) =
                    cfields st1 rest
            in
            ( ( name, x1 ) :: rest1, st2 )


cexp : CSt -> Exp -> ( Exp, CSt )
cexp st e =
    case e of
        Lit _ ->
            ( e, st )

        Var i ->
            ( Var (cvar st i), st )

        GRef _ ->
            ( e, st )

        StreamRef _ ->
            ( e, st )

        Lam l ->
            let
                ( ps, st1 ) =
                    cbinders st l.params

                ( body, st2 ) =
                    cexp st1 l.body
            in
            ( Lam { l | params = ps, body = body }, st2 )

        NoTail x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( NoTail x1, st1 )

        App a ->
            let
                ( f, st1 ) =
                    cexp st a.fn

                ( args, st2 ) =
                    cexps st1 a.args
            in
            ( App { a | fn = f, args = args }, st2 )

        PrimApp p ->
            let
                ( args, st1 ) =
                    cexps st p.args
            in
            ( PrimApp { p | args = args }, st1 )

        Let l ->
            let
                ( bs, st1 ) =
                    cletbinders st l.binders

                ( body, st2 ) =
                    cexp st1 l.body
            in
            ( Let { l | binders = bs, body = body }, st2 )

        Case c ->
            let
                ( scrut, st1 ) =
                    cexp st c.scrutinee

                ( sid, st2 ) =
                    cbinder st1 c.scrutId

                ( alts, st3 ) =
                    calts st2 c.alts
            in
            ( Case { c | scrutinee = scrut, scrutId = sid, alts = alts, endLabel = "" }, st3 )

        Con cn ->
            let
                ( args, st1 ) =
                    cexps st cn.args
            in
            ( Con { cn | args = args }, st1 )

        Tup xs ->
            let
                ( xs1, st1 ) =
                    cexps st xs
            in
            ( Tup xs1, st1 )

        RecordLit fs ->
            let
                ( fs1, st1 ) =
                    cfields st fs
            in
            ( RecordLit fs1, st1 )

        RecordGet x name ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RecordGet x1 name, st1 )

        RecordUpdate r ->
            let
                ( base, st1 ) =
                    cexp st r.base

                ( ups, st2 ) =
                    cfields st1 r.updates
            in
            ( RecordUpdate { r | base = base, updates = ups }, st2 )

        ListLit xs ->
            let
                ( xs1, st1 ) =
                    cexps st xs
            in
            ( ListLit xs1, st1 )

        If i ->
            let
                ( c1, st1 ) =
                    cexp st i.cond

                ( t1, st2 ) =
                    cexp st1 i.thenBranch

                ( e1, st3 ) =
                    cexp st2 i.elseBranch
            in
            ( If { i | cond = c1, thenBranch = t1, elseBranch = e1, falseLabel = "", endLabel = "" }, st3 )

        ShortAnd s ->
            let
                ( l1, st1 ) =
                    cexp st s.left

                ( r1, st2 ) =
                    cexp st1 s.right
            in
            ( ShortAnd { s | left = l1, right = r1, falseLabel = "", endLabel = "" }, st2 )

        ShortOr s ->
            let
                ( l1, st1 ) =
                    cexp st s.left

                ( r1, st2 ) =
                    cexp st1 s.right
            in
            ( ShortOr { s | left = l1, right = r1, falseLabel = "", endLabel = "" }, st2 )

        NotEqual n ->
            let
                ( l1, st1 ) =
                    cexp st n.left

                ( r1, st2 ) =
                    cexp st1 n.right
            in
            ( NotEqual { n | left = l1, right = r1, falseLabel = "", endLabel = "" }, st2 )

        Unsafe node ->
            let
                ( n1, st1 ) =
                    cnode st node
            in
            ( Unsafe n1, st1 )


cnode : CSt -> UnsafeNode -> ( UnsafeNode, CSt )
cnode st node =
    case node of
        RawCall r ->
            let
                ( args, st1 ) =
                    cexps st r.args
            in
            ( RawCall { r | args = args }, st1 )

        RawTagOf x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RawTagOf x1, st1 )

        RawPayload r ->
            let
                ( v, st1 ) =
                    cexp st r.value
            in
            ( RawPayload { r | value = v }, st1 )

        RawMkValue r ->
            let
                ( ws, st1 ) =
                    cexps st r.words
            in
            ( RawMkValue { r | words = ws }, st1 )

        RawAllocVector x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RawAllocVector x1, st1 )

        RawVecLoad r ->
            cnode2 st r .vec .index RawVecLoad (\rec vec idx -> { rec | vec = vec, index = idx })

        RawVecAddr r ->
            cnode2 st r .vec .index RawVecAddr (\rec vec idx -> { rec | vec = vec, index = idx })

        RawVecStore r ->
            cnode3 st r .vec .index .value RawVecStore (\rec a b c -> { rec | vec = a, index = b, value = c })

        RawStrByte r ->
            cnode2 st r .str .index RawStrByte (\rec a b -> { rec | str = a, index = b })

        WithRoots w ->
            let
                ( bs, st1 ) =
                    cbinders st w.binders

                ( body, st2 ) =
                    cexp st1 w.body
            in
            ( WithRoots { w | binders = bs, body = body }, st2 )

        RawPayload32 r ->
            let
                ( v, st1 ) =
                    cexp st r.value
            in
            ( RawPayload32 { r | value = v }, st1 )

        RawTagIs r ->
            let
                ( v, st1 ) =
                    cexp st r.value
            in
            ( RawTagIs { r | value = v }, st1 )

        RawBin r ->
            cnode2 st r .a .b RawBin (\rec a b -> { rec | a = a, b = b })

        RawUn r ->
            let
                ( v, st1 ) =
                    cexp st r.v
            in
            ( RawUn { r | v = v }, st1 )

        RawCmp r ->
            cnode2 st r .a .b RawCmp (\rec a b -> { rec | a = a, b = b })

        RawFltBin r ->
            cnode2 st r .a .b RawFltBin (\rec a b -> { rec | a = a, b = b })

        RawFltCmp r ->
            cnode2 st r .a .b RawFltCmp (\rec a b -> { rec | a = a, b = b })

        RawIToF x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RawIToF x1, st1 )

        RawLoadFlt x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RawLoadFlt x1, st1 )

        RawAllocRaw x ->
            let
                ( x1, st1 ) =
                    cexp st x
            in
            ( RawAllocRaw x1, st1 )

        RawByteLoad r ->
            cnode2 st r .ptr .index RawByteLoad (\rec a b -> { rec | ptr = a, index = b })

        RawByteStore r ->
            cnode3 st r .ptr .index .value RawByteStore (\rec a b c -> { rec | ptr = a, index = b, value = c })

        RawWordLoad r ->
            cnode2 st r .ptr .index RawWordLoad (\rec a b -> { rec | ptr = a, index = b })

        RawWordStore r ->
            cnode3 st r .ptr .index .value RawWordStore (\rec a b c -> { rec | ptr = a, index = b, value = c })

        RawCallRaw r ->
            let
                ( args, st1 ) =
                    cexps st r.args
            in
            ( RawCallRaw { r | args = args }, st1 )

        RawCallAgg r ->
            let
                ( f, st1 ) =
                    cexp st r.fn

                ( args, st2 ) =
                    cexps st1 r.args
            in
            ( RawCallAgg { r | fn = f, args = args }, st2 )

        RawDataAddr _ ->
            ( node, st )

        RawCStr _ ->
            ( node, st )

        RawSym _ ->
            ( node, st )


{-| The two-exp and three-exp raw-node records: the accessors name the
fields (each ctor's record has a different field set), the rebuild
function puts the canonicalized exps back.
-}
cnode2 :
    CSt
    -> r
    -> (r -> Exp)
    -> (r -> Exp)
    -> (r -> UnsafeNode)
    -> (r -> Exp -> Exp -> r)
    -> ( UnsafeNode, CSt )
cnode2 st r get1 get2 wrap put =
    let
        ( x1, st1 ) =
            cexp st (get1 r)

        ( x2, st2 ) =
            cexp st1 (get2 r)
    in
    ( wrap (put r x1 x2), st2 )


cnode3 :
    CSt
    -> r
    -> (r -> Exp)
    -> (r -> Exp)
    -> (r -> Exp)
    -> (r -> UnsafeNode)
    -> (r -> Exp -> Exp -> Exp -> r)
    -> ( UnsafeNode, CSt )
cnode3 st r get1 get2 get3 wrap put =
    let
        ( x1, st1 ) =
            cexp st (get1 r)

        ( x2, st2 ) =
            cexp st1 (get2 r)

        ( x3, st3 ) =
            cexp st2 (get3 r)
    in
    ( wrap (put r x1 x2 x3), st3 )


-- ---- expected-tree helpers: the SAME shapes RtPrims/RtGc build with ----
-- (labels "F"/"E" and any binder names — canon zeroes both).

ltn : Int -> Exp
ltn i =
    Lit (LNumber i)


lflt : Float -> Exp
lflt f =
    Lit (LFloat f)


ltv : Int -> Exp
ltv i =
    Var i


ltb : Int -> Binder
ltb i =
    { id = i, name = "t" ++ String.fromInt i }


llets : List ( Binder, Exp ) -> Exp -> Exp
llets binds body =
    case binds of
        [] ->
            body

        ( binder, value ) :: rest ->
            Let { binders = [ LetBind { binder = binder, value = value } ], body = llets rest body }


liff : Exp -> Exp -> Exp -> Exp
liff c t e =
    If { cond = c, thenBranch = t, elseBranch = e, falseLabel = "F", endLabel = "E" }


land2 : Exp -> Exp -> Exp
land2 l r =
    ShortAnd { left = l, right = r, falseLabel = "F", endLabel = "E" }


lor2 : Exp -> Exp -> Exp
lor2 l r =
    ShortOr { left = l, right = r, falseLabel = "F", endLabel = "E" }


lcallR : String -> List Exp -> Exp
lcallR key args =
    Unsafe (RawCall { sym = key, args = args })


lcallW : String -> List Exp -> Exp
lcallW sym args =
    Unsafe (RawCallRaw { sym = sym, args = args })


lmkNum : Exp -> Exp
lmkNum w =
    Unsafe (RawMkValue { tag = RtLayout.tagNumber, words = [ w ] })


lmkBool : Exp -> Exp
lmkBool w =
    Unsafe (RawMkValue { tag = RtLayout.tagBoolean, words = [ w ] })


lmkNilV : Exp
lmkNilV =
    Unsafe (RawMkValue { tag = RtLayout.tagNil, words = [] })


lmkStr : Exp -> Exp -> Exp
lmkStr d l =
    Unsafe (RawMkValue { tag = RtLayout.tagString, words = [ d, l ] })


lmkVec : Exp -> Exp -> Exp
lmkVec d l =
    Unsafe (RawMkValue { tag = RtLayout.tagVector, words = [ d, l ] })


lmkFlt : Exp -> Exp
lmkFlt f =
    Unsafe (RawMkValue { tag = RtLayout.tagFloat, words = [ f ] })


lwOf : Exp -> Exp
lwOf x =
    Unsafe (RawPayload { value = x, word = 0 })


lpay : Exp -> Int -> Exp
lpay x i =
    Unsafe (RawPayload { value = x, word = i })


ltagIs : Exp -> Int -> Exp
ltagIs x tag =
    Unsafe (RawTagIs { value = x, tag = tag })


liadd : Exp -> Exp -> Exp
liadd x y =
    Unsafe (RawBin { op = RAdd, a = x, b = y })


lisub : Exp -> Exp -> Exp
lisub x y =
    Unsafe (RawBin { op = RSub, a = x, b = y })


limul : Exp -> Exp -> Exp
limul x y =
    Unsafe (RawBin { op = RMul, a = x, b = y })


liand : Exp -> Exp -> Exp
liand x y =
    Unsafe (RawBin { op = RBitAnd, a = x, b = y })


lior : Exp -> Exp -> Exp
lior x y =
    Unsafe (RawBin { op = RBitOr, a = x, b = y })


lixor : Exp -> Exp -> Exp
lixor x y =
    Unsafe (RawBin { op = RBitXor, a = x, b = y })


lshl : Exp -> Exp -> Exp
lshl x c =
    Unsafe (RawBin { op = RShl, a = x, b = c })


lsar : Exp -> Exp -> Exp
lsar x c =
    Unsafe (RawBin { op = RShAr, a = x, b = c })


lshr : Exp -> Exp -> Exp
lshr x c =
    Unsafe (RawBin { op = RShR, a = x, b = c })


lcmpW : RawCmpOp -> Exp -> Exp -> Exp
lcmpW op x y =
    Unsafe (RawCmp { op = op, a = x, b = y })


lfl : Exp -> Exp
lfl x =
    Unsafe (RawLoadFlt x)


litof : Exp -> Exp
litof x =
    Unsafe (RawIToF x)


lfbin : RawFltBinOp -> Exp -> Exp -> Exp
lfbin op x y =
    Unsafe (RawFltBin { op = op, a = x, b = y })


lfcmp : RawFltCmpOp -> Exp -> Exp -> Exp
lfcmp op x y =
    Unsafe (RawFltCmp { op = op, a = x, b = y })



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


{-| The Char-ordering probe (osier-qbe-charfix): `'A' < 'B'` — two Char
literals (each a 1-char LString).  The lowering must emit the INLINE
byte-lexicographic compare (a loadub byte walk), not a call to the numeric-only
Rt.< — which answers False for any non-number, the silent Char-ordering
mislower.  (A Char-typed BINDER operand is the same branch via `isStrKnown`'s
`typeOfBinder` read; the end-to-end `c >= 'A'` shape is pinned behaviourally
by the gate's charord.elm fixture, where `c : Char` is in the real type table.)
-}
charOrdProbe : Defun
charOrdProbe =
    { key = "Rt.charOrdProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "c" } ]
            , body = PrimApp { prim = "<", args = [ Lit (LString "A"), Lit (LString "B") ] }
            }
    }


{-| The Int-ordering control: the SAME `<` on two Int literals must keep the
i64 fast path — no loadub byte walk, no Rt.< call.
-}
intLtProbe : Defun
intLtProbe =
    { key = "Rt.intLtProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body = PrimApp { prim = "<", args = [ Lit (LNumber 65), Lit (LNumber 66) ] }
            }
    }


{-| The RawCallAgg probe (stage 6 U1a): body = one aggregate call through a
runtime word, let-bound to a raw temp, with a plain number as the returned
Value.  `fn` is rt_vec_alloc's address word (a legal raw-word producer
standing in for a loaded code pointer); the IL row pins the emitted shape
`Call (Just _) (Agg "ret") (ArgVal (Base L) (Il.Tmp _)) [ArgVal (Base L) (Il.Con 2)]`.
-}
rawCallAggProbe : Defun
rawCallAggProbe =
    { key = "Rt.rawCallAggProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "r" }
                            , value =
                                Unsafe
                                    (RawCallAgg
                                        { fn = Unsafe (RawAllocVector (Lit (LNumber 1)))
                                        , args = [ Lit (LNumber 2) ]
                                        , shape = "ret"
                                        }
                                    )
                            }
                        ]
                    , body = Lit (LNumber 0)
                    }
            }
    }


{-| The rawAbi VALUE-position probe (stage 6 U2): a hand-built defun whose
TAIL is a rawAbi Rt call (Rt.die) — a word producer landed in a `:val`
position.  Lower must reject it loudly (the `lowerRawVal` rawAbi arm), never
reinterpret the word as a Value — the silent-miscompile class this unit's
pins exist to close.
-}
rawAbiValueMisuse : Defun
rawAbiValueMisuse =
    { key = "Rt.bad4"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body = Unsafe (RawCall { sym = "Rt.die", args = [ Lit (LNumber 0) ] })
            }
    }


{-| The prim half, for rows that lower WITH the driver hatch
(QBE_MIDDRIVER=1).  Since stage 6 A3a, Rt.main has a REAL surface body (the
A3a slice: usage + toomany + rlimit), so it is already part of `rtProgram` —
the A1 `rtMainStub` stand-in is gone (appending it would now emit a SECOND
Rt.main and a duplicate `main` symbol).
-}
driverProg : Rt.Runtime -> List Defun
driverProg rt =
    rtProgram rt True True True


{-| A RawCallAgg whose callee is a FUNCTION symbol (stage 6 A1b, the
A1-review blocker's fix): `fn` is `RawSym "rt_bounce"` — the function-symbol
producer, which lowers to `Il.Sym "rt_bounce"` (a CODE label, not a data
def).  The pin checks the symbol's CONTENT (`Il.Sym "rt_bounce"`, not a dN
data ref); the RawCStr data-def stand-in is rejected loudly by a separate
row.  Before A1 the word arm rejected everything but a temp.
-}
rawCallAggSymProbe : Defun
rawCallAggSymProbe =
    { key = "Rt.rawCallAggSymProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "r" }
                            , value =
                                Unsafe
                                    (RawCallAgg
                                        { fn = Unsafe (RawSym "rt_bounce")
                                        , args = [ Lit (LNumber 0) ]
                                        , shape = "val"
                                        }
                                    )
                            }
                        ]
                    , body = Lit (LNumber 0)
                    }
            }
    }


{-| A RawCallAgg whose callee is a DATA symbol (the A1-review blocker's
stand-in): `fn = RawCStr "rt_bounce"` — a rawstr data-def address.  A1b
rejects this LOUDLY (a call into static data would be silently wrong); the
RawSym producer is the only function-symbol callee.
-}
rawCallAggDataSymProbe : Defun
rawCallAggDataSymProbe =
    { key = "Rt.rawCallAggDataSymProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "r" }
                            , value =
                                Unsafe
                                    (RawCallAgg
                                        { fn = Unsafe (RawCStr "rt_bounce")
                                        , args = [ Lit (LNumber 0) ]
                                        , shape = "val"
                                        }
                                    )
                            }
                        ]
                    , body = Lit (LNumber 0)
                    }
            }
    }


{-| A RawCallAgg whose callee is a CONSTANT (stage 6 A1 item 4, the still-
rejected shape): `fn = Lit (LNumber 0)` lowers to `Il.Con 0` — not a call
target.  The relaxation accepts temps AND named symbols, never a constant.
-}
rawCallAggConstProbe : Defun
rawCallAggConstProbe =
    { key = "Rt.rawCallAggConstProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Let
                    { binders =
                        [ LetBind
                            { binder = { id = 1, name = "r" }
                            , value =
                                Unsafe
                                    (RawCallAgg
                                        { fn = Lit (LNumber 0)
                                        , args = [ Lit (LNumber 0) ]
                                        , shape = "val"
                                        }
                                    )
                            }
                        ]
                    , body = Lit (LNumber 0)
                    }
            }
    }


{-| A RawCallAgg in VALUE position (stage 6 A1b): the defun's TAIL is
the aggregate call (not a let-binder, so it takes the value path, not the
word temp) — the driver's "sret result as a Value" shape.  `fn` is a
FUNCTION symbol (RawSym "rt_bounce"), exercising the Sym callee through the
value arm too.
-}
rawCallAggValProbe : Defun
rawCallAggValProbe =
    { key = "Rt.rawCallAggValProbe"
    , value =
        Lam
            { params = [ { id = 0, name = "x" } ]
            , body =
                Unsafe
                    (RawCallAgg
                        { fn = Unsafe (RawSym "rt_bounce")
                        , args = [ Lit (LNumber 0) ]
                        , shape = "val"
                        }
                    )
            }
    }


{-| The RawCallAgg IL shape with a FUNCTION-symbol callee (stage 6 A1b):
`Call (Just _) (Agg "val") (Il.Sym "rt_bounce") [ArgVal (Base L) (Il.Con 0)]`
— the symbol CONTENT pinned, so a data-def stand-in (Il.Sym "d17") fails.
-}
rawCallAggSymCallShape : Il.Func -> Bool
rawCallAggSymCallShape f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Call (Just _) (Il.Agg "val") (Il.Sym "rt_bounce") [ Il.ArgVal (Il.Base Il.L) (Il.Con 0) ] ->
                            True

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


{-| The RawCallAgg VALUE-position Blit shape (stage 6 A1b): a `:val` call of
the FUNCTION symbol rt_bounce into a temp, then a 40-byte Blit of that temp
into the dest slot — the exact rtApply non-tail shape (call + blit), never a
word-address return.  The callee CONTENT (`Il.Sym "rt_bounce"`, not a dN data
ref) and the Blit SIZE (40 B = valSizeBytes, not the 80-B :ret) are both
pinned.
-}
rawCallAggValBlitShape : Il.Func -> Bool
rawCallAggValBlitShape f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Call (Just _) (Il.Agg "val") (Il.Sym "rt_bounce") _ ->
                            True

                        _ ->
                            False
                )
                b.body
                && List.any
                    (\i ->
                        case i of
                            Il.Blit (Il.Tmp _) (Il.Tmp _) 40 ->
                                True

                            _ ->
                                False
                    )
                    b.body
        )
        f.blocks


{-| The rawAbi WORD-call shape: a call to `sym` whose result is `Base L` and
whose argument list is EXACTLY one `Base L` word — the shape a rawAbi Rt
call (Rt.die) must emit, and the shape the lean 4-arg `:val` ABI must NOT
(a mismatch is a silent register-class miscompile, not a link error).
-}
rawAbiWordCall : String -> Il.Func -> Bool
rawAbiWordCall sym f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Call _ (Il.Base Il.L) (Il.Sym s) [ Il.ArgVal (Il.Base Il.L) _ ] ->
                            s == sym

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


{-| The RawCallAgg IL shape: a call with a result temp, an `:ret` aggregate
result, the callee as a WORD argument (`ArgVal (Base L) (Il.Tmp _)` — a
register target, not a symbol), and the word args in order.
-}
rawCallAggCallShape : Il.Func -> Bool
rawCallAggCallShape f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Call (Just _) (Il.Agg "ret") (Il.Tmp _) args ->
                            args == [ Il.ArgVal (Il.Base Il.L) (Il.Con 2) ]

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


{-| Does a func's body read a string BYTE (a `loadub`)?  The marker of the
inline byte-lexicographic compare (`lowerStrLess`); the numeric compare paths
never emit one.
-}
hasLoadUb : Il.Func -> Bool
hasLoadUb f =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Load _ _ Il.LoadUb _ ->
                            True

                        _ ->
                            False
                )
                b.body
        )
        f.blocks


{-| Every `Rt.*` key a body RawCalls, in order (duplicates kept — the check
only needs membership).  The seed-closure skew detector: a RawCall to a key
missing from (rt.program True True True) or from Rt.rtDeps makes that defun unreachable or
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


{-| How many times a function's own blocks CALL a symbol by name.  The A3a
SHOULD-FIX-1 counter: scoping alone (callsSym) still leaves the "error paths
CALL write and exit" check satisfiable by the notmeta path alone, so the row
counts — the two A3a error paths (usage + toomany) each write-then-exit, and
Rt.die/Rt.halt (in OTHER functions) supply nothing, so >=2 of each is the
non-vacuous pin.
-}
symCount : String -> Il.Func -> Int
symCount sym f =
    List.sum
        (List.map
            (\b ->
                List.length
                    (List.filter
                        (\i ->
                            case i of
                                Il.Call _ _ (Il.Sym s) _ ->
                                    s == sym

                                _ ->
                                    False
                            )
                        b.body
                    )
            )
            f.blocks
        )


funcByName : String -> Il.Module -> Maybe Il.Func
funcByName name mod =
    List.head (List.filter (\f -> f.name == name) mod.funcs)


{-| T7: `rt.program` is now the SURFACE PIPELINE (Result-valued — a bad
`Mid.RtSource` text must fail the compile, never shrink the runtime); the
pre-T7 rows read the List it produces.  With `Mid.RtSource.source = []` the
pipeline is the identity, so this unwrap cannot fail while the T7 rows are
green — and the dedicated T7 identity row asserts the `Ok` DIRECTLY, so a
broken pipeline turns red there first, loudly.
-}
-- run.js's DEFAULT hatch vector, (midGc, midDriver) — the pair
-- selfhost/NativeMain.elm:276 hard-codes as ( False, True ) and the pin row
-- above asserts.  MEASURED at A5: run.js:141 QBE_MIDGC = (env === '1') (OFF)
-- and run.js:148 QBE_MIDDRIVER = (env !== '0') (ON, flipped at A5).
-- This is a HAND-COPIED twin (Elm cannot read run.js) — when a default
-- moves, this constant, NativeMain.elm's vector and run.js move together,
-- and the row fails until they do.
defaultHatchVector : ( Bool, Bool )
defaultHatchVector =
    ( False, True )


rtProgram : Rt.Runtime -> Bool -> Bool -> Bool -> List Defun
rtProgram rt consArr rec eqPtrFast =
    case rt.program consArr rec eqPtrFast of
        Ok p ->
            p

        Err _ ->
            []


{-| T18: the GC half of the splice (`rt.programGc`) — the collector defuns
with their surface-migrated bodies at the `gcProgram` list positions.  The
rows that read `RtGc.gcProgram` DIRECTLY (the :1073/:1082 QbeLower probes,
the gc call-graph row, the per-key splice rows) were re-pointed here by
T18: after the migration the DSL list holds tripwire SEATS (the
`key ++ ".surface-seat"` bodies), so a seat-reading row would either fail
loudly (the call-graph row) or lower the wrong body (the probes).  The gc
keys are NOT in `rtProgram` — `rt.program` is the prim/helper half — so
this driver is the only seat-honest view of the collector.
-}
rtProgramGc : Rt.Runtime -> Bool -> Bool -> Bool -> List Defun
rtProgramGc rt consArr rec eqPtrFast =
    case rt.programGc consArr rec eqPtrFast of
        Ok p ->
            p

        Err _ ->
            []


{-| The arity of a typed extern entry (M2): the flattened param count of
its declared type.  An exported key's arity comes from its declared Osier
type; an unexported key's from the `valArity n` fallback — both via
`Ast.splitArrow`.
-}
externArity : Ast.ExportSig -> Int
externArity sig =
    List.length (Tuple.first (Ast.splitArrow sig.ty))


{-| M3: a hand-built user `.mid` module for the COLLISION rows — only the
defun KEYS matter to `QbeModule.userCollisions`, so the value is a dummy
literal.  The exports are empty (the collision rules read defun keys, not
the export block).
-}
mkUser : String -> List String -> Rt.UserModule
mkUser name keys =
    { name = name
    , exports = []
    , defuns = List.map (\k -> { key = k, value = Lit (LNumber 0) }) keys
    }


{-| M3fix (finding 4): the Lam arity of the named defun inside a loaded user
module, if present — used by the cross-module row to pin that BOTH halves of
a `.mid`-internal call land at the right arity.
-}
midKeyArity : String -> Rt.UserModule -> Maybe Int
midKeyArity key m =
    case List.filterMap (\d -> if d.key == key then Just (lamArity d) else Nothing) m.defuns of
        a :: _ ->
            Just a

        [] ->
            Nothing


{-| M2: parse a single export line's declared TYPE by wrapping it in a
minimal one-export module.  Used by the forward-compatibility rows, which
assert the grammar (not the semantics) of quantifiers/application/
polymorphic arrows.
-}
parseExportTy : String -> Maybe Ast.OTy
parseExportTy tySrc =
    case Parse.parseModule ("module Rt\nexport Rt.f : " ++ tySrc ++ "\ndefun Rt.f(a: val) -> val { return mknil; }") of
        Ok m ->
            case m.header.exports of
                e :: _ ->
                    Just e.sig.ty

                [] ->
                    Nothing

        Err _ ->
            Nothing


lamArity : Defun -> Int
lamArity d =
    case d.value of
        Lam l ->
            List.length l.params

        _ ->
            0


{-| T25's flag-combo sweep: the 8 (consArr, rec, eqPtrFast) combinations
with the matching surface ACTIVE flag set — the same table the T7/T8 wiring
row walks inline, named here so the T25 identity + derived-tables rows read
it without repeating it twice.
-}
t25Combos : List { c : Bool, r : Bool, e : Bool, flags : List Ast.Flag }
t25Combos =
    [ { c = True, r = True, e = True, flags = [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] }
    , { c = True, r = True, e = False, flags = [ Ast.ConsArr, Ast.Rec ] }
    , { c = True, r = False, e = True, flags = [ Ast.ConsArr, Ast.EqPtrFast ] }
    , { c = True, r = False, e = False, flags = [ Ast.ConsArr ] }
    , { c = False, r = True, e = True, flags = [ Ast.Rec, Ast.EqPtrFast ] }
    , { c = False, r = True, e = False, flags = [ Ast.Rec ] }
    , { c = False, r = False, e = True, flags = [ Ast.EqPtrFast ] }
    , { c = False, r = False, e = False, flags = [] }
    ]


{-| T19: is this defun a migration SEAT (the Mid.RtPrims.seat tripwire
shape) rather than a real body?  The seat's one RawCall names exactly
`key ++ ".surface-seat"` with no args — a real body cannot match unless it
issues that same dead call, which no holdout does.
-}
isSeatDefun : Defun -> Bool
isSeatDefun d =
    case d.value of
        Lam l ->
            case l.body of
                Unsafe (RawCall { sym, args }) ->
                    args == [] && sym == d.key ++ ".surface-seat"

                _ ->
                    False

        _ ->
            False


{-| The arity table a standalone `QbeLower.lower` call needs for the Rt
program's self-GRef Apps (QbeModule normally completes this; the scratch
lowerings here must pass it themselves).
-}
rtArities : List Defun -> Dict String Int
rtArities program =
    Dict.fromList
        (List.filterMap
            (\d ->
                case d.value of
                    Lam l ->
                        Just ( d.key, List.length l.params )

                    _ ->
                        Nothing
            )
            program
        )


{-| The SATURATED, non-forced self-App shape the real helpers use — the
positive control for the narrowed edge rule (must stay an EDGE, i.e.
rt.direct False).
-}
cStrLenGoDefunForControl : Defun
cStrLenGoDefunForControl =
    { key = "Rt.controlLoop"
    , value =
        Lam
            { params = [ { id = 1, name = "a1" }, { id = 2, name = "a2" } ]
            , body =
                If
                    { cond = Lit (LNumber 0)
                    , thenBranch = Lit (LNumber 0)
                    , elseBranch =
                        App
                            { fn = GRef { key = "Rt.controlLoop", force = False }
                            , args = [ Var 1, Lit (LNumber 1) ]
                            }
                    , falseLabel = "F"
                    , endLabel = "E"
                    }
            }
    }


{-| The SF2 structural property: the emitted body loops in-frame (a block
whose jump is `jmp @body`) and NEVER calls its own q_ symbol (which would be
one native frame per iteration — the ~100 KB stack crash).
-}
selfLoopIsLoop : ( String, Il.Func ) -> Bool
selfLoopIsLoop ( selfSym, f ) =
    List.any (\b -> b.jump == Il.Jmp "body") f.blocks
        && not (callsSym selfSym f)


{-| Framed = the pooled-frame enter seat is emitted (the lean ABI grants a
frame exactly when the defun is classified allocating).
-}
callsFrameEnter : Il.Func -> Bool
callsFrameEnter f =
    callsSym "rt_frame_enter" f


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


{-| Does a body carry a `:val` aggregate call or a 40-byte blit?  The B0perf-2
frameZero must contain NEITHER — a word defun's loop should be pure
word loads/stores and an in-frame jmp, never a Value copy.
-}
hasValOrBlit : List Il.Block -> Bool
hasValOrBlit blocks =
    List.any
        (\b ->
            List.any
                (\i ->
                    case i of
                        Il.Blit _ _ _ ->
                            True

                        Il.Call _ (Il.Agg "val") _ _ ->
                            True

                        _ ->
                            False
                )
                b.body
        )
        blocks


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

                RawCallAgg call ->
                    rawCallSyms call.fn ++ List.concatMap rawCallSyms call.args

                RawDataAddr _ ->
                    []

                RawCStr _ ->
                    []

                RawSym _ ->
                    []


