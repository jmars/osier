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
import Mid.Ir exposing (Alt, AltKind(..), Binder, Defun, Exp(..), FfiWidth(..), LetBinder(..), Lit(..), MemWidth(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), UnsafeNode(..), ValuePath)
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
            report (String.join "\n" (checks rt runtimeMidText))

        Err msg ->
            report ("FAIL runtime.mid load: " ++ msg ++ "\nFAIL runtime.mid anti-empty (the census rows could not run)")


checks : Rt.Runtime -> String -> List String
checks rt runtimeMidText =
    [ -- M1 ANTI-EMPTY: the census rows below read `rt` (the once-per-process
      -- load of runtime.mid).  If test-run.js (or run.js) ever stops reading
      -- the file, the flag text is empty, `Rt.load` would parse nothing, and
      -- every `rtProgram`-derived row could pass VACUOUSLY over an empty
      -- program.  This row pins the full surface program (189 defuns — the
      -- MEASURED `defun` count of osier-compiler/runtime.mid; 178 + the ten stage-6 B1/B2
      -- apply + tail defuns + perf-gc1's Rt.gcClearClasses, after P1e deleted
      -- the frameZero loop), so an empty or truncated load turns it RED,
      -- loudly, before any vacuous row can.
      check "M1 anti-empty: the loaded runtime.mid parsed to the full surface program (349 defuns — perf U1 added THREE: Rt.join/Rt.joinLen/Rt.joinFill, the linear String.join; zighost Z2/Z3 added Rt.vecStorePlain/Rt.vecStoreYoung/Rt.globalClosure (GC NURSERY added the ten scavenge-family defuns; O5 added the five string-stream registry + the nine intern-table defuns + seat 3's values-table walk) — prof-fixes unit 1 added TWO: Rt.countGo/Rt.bytesOfGo, the O(1)-stack text walkers; GC-ARC F1 added the two stats-instrument defuns Rt.gcNum/Rt.gcNumOut, stage 7A added the 27-defun Mid effect host, stage 7B its 12 leaf/deadline defuns, stage 7C its 14 fd-table/poll defuns, stage 7D its 23 exec defuns and stage 7E its SEVEN dir/stat defuns — which also DELETED Rt.hostDieUnported, so the net is +6 — stage 7 O3-fix added ONE: Rt.applyPartGo, the shared capture/args interleave, and GC ARC unit 4 added ONE: Rt.gcEnvNum, the decimal reader behind QBE_MIDGC_MAXMB) + GC ARC unit 1b added ONE: Rt.gcGrow, the growth transcript"
        (case rt.parsedSource of
            Ok ast ->
                List.length ast == 349

            Err _ ->
                False
        )
    , check "gc-fixes2 F1: the four equality loops are recur-on-mismatch, not per-byte/per-element `&& call Rt.<self>` recursion (the 179.4s 8-MiB SIGSEGV's shape: 14,888 bytesEqGo frames)"
        (String.contains "recur(a, bb, mknum(payload(i, 0) + 1));" runtimeMidText
            && String.contains "recur(vecload(payload(a, 0), 1), vecload(payload(bb, 0), 1));" runtimeMidText
            && not (String.contains "&& call Rt.bytesEqGo(a, bb, mknum(payload(i, 0) + 1))" runtimeMidText)
            && not (String.contains "&& call Rt.symEq(a, bb, mknum(payload(i, 0) + 1))" runtimeMidText)
            && not (String.contains "&& call Rt.vecEq(a, bb, mknum(payload(i, 0) + 1))" runtimeMidText)
            && not (String.contains "&& call Rt.deepEq(vecload(payload(a, 0), 1), vecload(payload(bb, 0), 1))" runtimeMidText)
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
    , check "37 prim-wrapper schemes registered"
        (Dict.size Builtins.primWrapperSchemes == 37)

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
    , check "rt program: 309 defuns, all Rt.*; cons 2-ary, substring 3-ary, con 3-ary, open 2-ary, glob 1-ary, read-file-as-string 1-ary, exec-run 3-ary (E added the record walk/rebuild defuns; stage 5 added the ADT constructor and the closure; stage 3 GROUP 1 added the fd prims write-byte/read-byte/open/close + readFull/cStrFill; stage 3 GROUP 2 added intern/value/str + floatCopy; stage 3 GROUP 3A added getpid/getcwd/cd/getenv/setenv + cStrLenGo/cStrCopyGo; GROUP 3B added glob + its 8 helpers; GROUP 3B-2a added exec-plan + its 20 ep* decode helpers; GROUP 3B-2b added the RUN defuns execGo + its 21 helpers; GROUP 3B-3 added read-file-as-string + readFileGo/memGo — the LAST rt_prim route); GROUP 3B-2c added exec-run (the slurp+result half; the rt_exec_run seat is deleted)"
        (List.length (rtProgram rt True True True) == 309
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

            -- STAGE 7A: the ONE edge that is not in rtDeps is Rt.main's host
            -- arm.  It cannot be: Rt.main is seeded in EVERY compile ($main is
            -- in every artifact), so an rtDeps edge there would seed the whole
            -- host into the default route and move all 159 corpus hashes.  The
            -- host's entry points are GATED ROOTS instead (Rt.hostSeeds, live
            -- only when the surface text carries the splice marker), so the
            -- predicate is: a RawCall target is a program key AND reachable —
            -- declared in rtDeps, OR one of the gated host roots.
            ok key =
                List.all
                    (\sym ->
                        List.member sym allKeys
                            && (List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps))
                                    || (key == "Rt.main" && List.member sym [ "Rt.hostRun", "Rt.hostIsProgram" ])
                               )
                    )
                    (syms key)
         in
         List.all ok allKeys
        )
    , check "rt cons lowers to a QBE function named q_Rt_x2econs"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.cons" of
            Ok mod ->
                List.any (\f -> f.name == "q_Rt_x2econs") mod.funcs

            Err _ ->
                False
        )
    , check "rt lowering REJECTS a raw-word binder read in a value position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rtRawBinderMisuse ] "Rt.bad" of
            Err msg ->
                String.contains "raw word binder" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a word node in a value position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rtWordInValuePosition ] "Rt.bad2" of
            Err msg ->
                String.contains "value position" msg

            Ok _ ->
                False
        )
    , check "rt lowering REJECTS a value binder in a raw-argument position (must-fail)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rtValueInRawPosition ] "Rt.bad3" of
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
        (case QbeLower.lower rt True False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ charOrdProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ charOrdProbe ]) "Rt.charOrdProbe" of
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
        (case QbeLower.lower rt True False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ intLtProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ intLtProbe ]) "Rt.intLtProbe" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggProbe ]) "Rt.rawCallAggProbe" of
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
    , check "rawAbi set + classification: Rt.cStrEq/Rt.die/Rt.halt/Rt.main + the B0 frame pair + stage 7A's die family (dieErr/hostDieErr — hostDieUnported left BOTH the family and the runtime at 7E, the unit that gave every Task ctor a real arm) are the word-ABI keys and the die/halt/cStrEq/metaGo/parseArgsGo/frame set are frame-free (a die path must not reach a safepoint; the meta-walk compare and the A4a arg loop are non-allocating — their only seat calls are rawcall, which the classifier treats alloc-free — so they stay frame-free; Rt.main stays rawAbi frame-free regardless of its RawCallAgg dispatch, because the rawAbi arm is checked before the allocating set; the frame pair is FRAME-FREE by construction — its only nodes are rawcall/raw-word loads/stores and rawAbi->rawAbi calls to its one non-allocating helper)"
        (Rt.rawAbi
            == Set.fromList [ "Rt.cStrEq", "Rt.die", "Rt.halt", "Rt.main", "Rt.frame-enter", "Rt.frame-leave", "Rt.frameBlock", "Rt.apply", "Rt.apply-tail", "Rt.copyWords", "Rt.copyWordsGo", "Rt.tail-known", "Rt.bounce", "Rt.dieErr", "Rt.hostDieErr", "Rt.rootGrow", "Rt.rootPush", "Rt.rootPushPtr", "Rt.rootPushValue", "Rt.rootPushValueArray", "Rt.rootPop", "Rt.rootWatermark", "Rt.rootPopTo", "Rt.vecStorePlain", "Rt.vecStoreYoung", "Rt.globalClosure" ]
            && not (Set.member "Rt.die" rt.allocating)
            && not (Set.member "Rt.halt" rt.allocating)
            && not (Set.member "Rt.cStrEq" rt.allocating)
            && not (Set.member "Rt.cStrEqGo" rt.allocating)
            && not (Set.member "Rt.metaGo" rt.allocating)
            && not (Set.member "Rt.parseArgsGo" rt.allocating)
            && not (Set.member "Rt.frame-enter" rt.allocating)
            && not (Set.member "Rt.frame-leave" rt.allocating)
            && not (Set.member "Rt.frameBlock" rt.allocating)
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
            -- stage 6 B2: Rt.tail-known allocates (the allocvec fallback is a
            -- direct safepoint); Rt.bounce reaches its allocating loop helper
            -- via rtDeps; Rt.bounceGo is CONSERVATIVELY allocating (aggcall,
            -- the unknown-generated-code deny-by-default).  All three stay
            -- rawAbi-frame-free regardless (the rawAbi arm wins the frame
            -- decision before `allocating` is consulted).
            && Set.member "Rt.tail-known" rt.allocating
            && Set.member "Rt.bounce" rt.allocating
            && Set.member "Rt.bounceGo" rt.allocating
            -- ZIGHOST Z1: the root registry is FRAME-FREE — the only seat its
            -- bodies reach is libc malloc/free (RawCallRaw) through
            -- Rt.rootGrow, so a push can run inside a collector-free window
            -- and the push sites need no frame of their own.
            && not (Set.member "Rt.rootGrow" rt.allocating)
            && not (Set.member "Rt.rootPush" rt.allocating)
            && not (Set.member "Rt.rootPushPtr" rt.allocating)
            && not (Set.member "Rt.rootPushValue" rt.allocating)
            && not (Set.member "Rt.rootPushValueArray" rt.allocating)
            && not (Set.member "Rt.rootPop" rt.allocating)
            && not (Set.member "Rt.rootWatermark" rt.allocating)
            && not (Set.member "Rt.rootPopTo" rt.allocating)
            && not (Set.member "Rt.gcMarkValuesTab" rt.allocating)
            && not (Set.member "Rt.gcScavValuesTab" rt.allocating)
        )
    , check "rawAbi emission shape: Rt.die (1 word param) emits (params [a0:l], ret l, frame-free alloc scratch)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.die" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.halt" of
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
    , check "P1e frame-enter bulk-zero is a SINGLE rawcall memset(dst, 0, 40*nslots) — 3 word args, the middle the zero byte, a 40*x Mul for the length, and NO q_Rt_x2eframeZero call or in-frame loop (the per-slot frameZero loop is gone; fails on the pre-P1e loop)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.frame-enter" of
            Ok mod ->
                case funcByName "q_Rt_x2eframe_x2denter" mod of
                    Just f ->
                        memsetBulkZeroShape f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "P1e zero-BEFORE-root: frame-enter's memset is emitted BEFORE the Rt.rootPushValueArray call (a reused block's stale slots must be zeroed before the GC scans them — the rt.zig:279 correctness memset)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.frame-enter" of
            Ok mod ->
                case funcByName "q_Rt_x2eframe_x2denter" mod of
                    Just f ->
                        memsetBeforeRootPush f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "P5 PLeaf emission (THE H3 REGRESSION PIN): a leaf-qualified SURFACE defun emits NO pooled frame — no frame-enter call, no frame-leave call, an alloc8 block — and materialises BOTH non-tag-directed return reads as EIGHT-BYTE zero stores: `storel 0, %s0` (the .done result tag) and `storel 0, %tzk` at f+retKindOffset (the .done marker). EXACT emitted text, and the 4-byte `storew` spelling at that offset is asserted ABSENT: it is what shipped first and it cost a SEGV. runtime.mid's own `struct Ret { kind : word }` makes the marker an 8-byte word while QBE's :ret spells it `w` + 4 padding bytes, so Rt.bounce's `r->kind == 0` compiles to `movq 40(%rax)` + `cmpq $0, %rcx`; a storew leaves those padding bytes as stack garbage and rt_bounce chases a .tail built out of it (MEASURED: wild jump into the heap, one defun changed). This row would have failed at emit time."
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities [ leafProbe ]) [ leafProbe ] "Lf.f" of
            Ok mod ->
                case funcByName "q_Lf_x2ef" mod of
                    Just f ->
                        let
                            -- the function ALONE, rendered by the one printer
                            -- the pipeline uses — so this is the text qbe reads
                            txt =
                                Print.print { layout = RtLayout.valLayout, types = [], datas = [], funcs = [ f ] }
                        in
                        String.contains ("\t%f =l alloc8 " ++ String.fromInt (RtLayout.valLayout.valSizeBytes * 2) ++ "\n") txt
                            && String.contains
                                ("\tstorel 0, %s0\n\t%tzk =l add %f, "
                                    ++ String.fromInt (RtLayout.retKindOffset RtLayout.valLayout)
                                    ++ "\n\tstorel 0, %tzk\n"
                                )
                                txt
                            && not (String.contains "frame_x2denter" txt)
                            && not (String.contains "frame_x2dleave" txt)
                            && not (String.contains "storew 0, %tzk" txt)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "VR3b1 THE WORD ARM'S INSTANCE: `wordLayout` states handoff-valrep2-plan §2(a) — ONE 8-byte word per value, no tag word before the payload (payloadBase 0), no payload words, `:val` = { l } — against `valLayout`'s 40/8/4/{ w, l, l, l, l }; and the two things that must NOT move with the representation DO NOT: `wordBytes` (the `l` width every offset is counted in) and `maxArity` (the rt_callN dispatch bound, not a cell size)"
        (RtLayout.wordLayout.valSizeBytes
            == 8
            && RtLayout.wordLayout.payloadBase
            == 0
            && RtLayout.wordLayout.valueTagBytes
            == 0
            && RtLayout.wordLayout.valuePayloadWords
            == 0
            && RtLayout.wordLayout.valQbeFields
            == [ "l" ]
            && RtLayout.wordLayout.wordBytes
            == RtLayout.valLayout.wordBytes
            && RtLayout.wordLayout.maxArity
            == RtLayout.valLayout.maxArity
            && RtLayout.valLayout.valSizeBytes
            == 40
            && RtLayout.valLayout.valQbeFields
            == [ "w", "l", "l", "l", "l" ]
            -- THE TYPE LAYER RESPECTS THE KNOB, end to end: `Il.valType` is
            -- built from the instance and `Print`/`Encode` read `m.layout`, so
            -- a module printed FOR the word instance carries the word `:val`
            -- typedef and the val instance the 40-byte one.  This is the one
            -- part of the word arm that IS ported.
            && String.contains "type :val = align 8 { l }\n"
                (Print.print { layout = RtLayout.wordLayout, types = [], datas = [], funcs = [] })
            && String.contains "type :val = align 8 { w, l, l, l, l }\n"
                (Print.print { layout = RtLayout.valLayout, types = [], datas = [], funcs = [] })
        )
    , check "VR3b1 THE `:ret` COUPLING IS DERIVED, NOT A CONSTANT (VR3a's finding): the aggregate's first field IS a Value, so retKindOffset/retFOffset/retEOffset/retArgsOffset/retArityOffset/retSizeBytes are FUNCTIONS of the instance — 40/48/56/64/72/80 on the val arm (the offsets the 40-byte representation has always emitted) and 8/16/24/32/40/48 on the word arm. A `40` left as a constant is the stale-40 trap this row exists to make loud"
        (List.map
            (\l ->
                [ RtLayout.retKindOffset l
                , RtLayout.retFOffset l
                , RtLayout.retEOffset l
                , RtLayout.retArgsOffset l
                , RtLayout.retArityOffset l
                , RtLayout.retSizeBytes l
                ]
            )
            [ RtLayout.valLayout, RtLayout.wordLayout ]
            == [ [ 40, 48, 56, 64, 72, 80 ], [ 8, 16, 24, 32, 40, 48 ] ]
        )
    , check "VR3b1 QBE_VALREP=word IS LOUD, NEVER HALF-WORKING: the word arm returns an Err NAMING the first construct it cannot lower (the `:val` frame slot stride) and emits NOTHING — a half-flipped emit links cleanly and then reads another representation's bytes at the wrong offset, so the arm must fail before the reachability walk. The SAME program on the VAL arm still compiles, i.e. the guard is the arm's, not the program's"
        (case
            ( QbeLower.lowerWith RtLayout.wordLayout rt False False False True True True True False False True QbeTypes.empty (rtArities [ leafProbe ]) [ leafProbe ] "Lf.f"
            , QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities [ leafProbe ]) [ leafProbe ] "Lf.f"
            )
         of
            ( Err msg, Ok _ ) ->
                String.contains "QBE_VALREP=word is NOT IMPLEMENTED" msg
                    && String.contains "FRAME SLOT STRIDE" msg
                    && String.contains "Mid/RtLayout.elm" msg

            _ ->
                False
        )
    , check "B1fix copyWords is a rawAbi WORD pair: the WRAPPER (3 l params, ret l, frame-free) hands off to the LOOP, and the LOOP (3 l params, ret l, frame-free) is an in-frame self-tail with NO :val aggregate or 40-byte blit in its body — the per-word blit/boxing is gone (fails on the pre-fix :val copyWords, which had ret :val, a 40-byte blit, a self-CALL recur and no copyWordsGo)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.copyWords" of
            Ok mod ->
                (case funcByName "q_Rt_x2ecopyWords" mod of
                    Just f ->
                        List.map Tuple.second f.params
                            == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L ]
                            && f.ret == Il.Base Il.L
                            && frameBaseIsAlloc f
                            && callsSym "q_Rt_x2ecopyWordsGo" f
                            && not (hasValOrBlit f.blocks)

                    Nothing ->
                        False
                )
                    && (case funcByName "q_Rt_x2ecopyWordsGo" mod of
                            Just f ->
                                List.map Tuple.second f.params
                                    == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L ]
                                    && f.ret == Il.Base Il.L
                                    && frameBaseIsAlloc f
                                    && selfLoopIsLoop ( "q_Rt_x2ecopyWordsGo", f )
                                    && not (hasValOrBlit f.blocks)

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "B2 Rt.tail-known is a rawAbi Agg-ret defun: params [a0:l,a1:l,a2:l], ret Agg \"ret\" (the 80-byte .tail), frame-free alloc8 (the rawAbi arm wins the frame decision) — the rt_tail_known seat's C ABI, ready for Lower's directCall TAIL retarget"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.tail-known" of
            Ok mod ->
                case funcByName "q_Rt_x2etail_x2dknown" mod of
                    Just f ->
                        List.map Tuple.second f.params
                            == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L ]
                            && f.ret == Il.Agg "ret"
                            && frameBaseIsAlloc f
                            && not (callsSym "rt_frame_enter" f)
                            && not (callsSym "q_Rt_x2eframe_x2denter" f)
                            && callsSym "q_Rt_x2ecopyWords" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B2 Rt.bounce is a rawAbi Agg-val defun: params [a0:l], ret Agg \"val\" (the 40-byte .done), frame-free alloc8, single-iteration fast path (vecload) + hand-off to the :val loop q_Rt_x2ebounceGo — the rt_bounce seat's C ABI"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.bounce" of
            Ok mod ->
                case funcByName "q_Rt_x2ebounce" mod of
                    Just f ->
                        List.map Tuple.second f.params
                            == [ Il.Base Il.L ]
                            && f.ret == Il.Agg "val"
                            && frameBaseIsAlloc f
                            && not (callsSym "rt_frame_enter" f)
                            && not (callsSym "q_Rt_x2eframe_x2denter" f)
                            && callsSym "q_Rt_x2ebounceGo" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B2 Rt.bounceGo is the FRAMED :val tail-chase loop: reaches the rt_callN bridge by name AND its recur is an in-frame self-tail (jmp @body, no self-call) — CONSTANT native stack, exactly the Zig bounce trampoline (fails on a self-CALL recur, which would build one C frame per hop and blow the 1e6 clostail stack)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.bounce" of
            Ok mod ->
                case funcByName "q_Rt_x2ebounceGo" mod of
                    Just f ->
                        callsSym "q_Rt_x2eframe_x2denter" f
                            && callsSym "rt_call0" f
                            && callsSym "rt_call16" f
                            && selfLoopIsLoop ( "q_Rt_x2ebounceGo", f )

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0perf-2 nested word-tail If: the ret-bound arm's word SURVIVES the join end-to-end — the BLOCKER fix (the old lastBlockJump read only the INNER else's jmp @body and silently dropped %a0 to ret 0)"
        (case lowl nestedWordTailIfSrc of
            Ok [ fixture ] ->
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ fixture ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ fixture ]) "Rt.die" of
                    Ok mod ->
                        case funcByName "q_Rt_x2edie" mod of
                            Just f ->
                                retBlockReturns (Il.Tmp "a0") f

                            Nothing ->
                                False

                    Err _ ->
                        False

            _ ->
                False
        )
    , check "rawAbi VALUE-position reject (fail-before): a WORD-ABI call in a :val tail is a loud Err, never a silent word->val reinterpretation (the message names the callee since B6 — a user word-ABI key can land here too, so 'rawAbi Rt call' was too narrow)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rawAbiValueMisuse ] "Rt.bad4" of
            Err msg ->
                String.contains "word-ABI call in a VALUE position" msg

            Ok _ ->
                False
        )
    , check "rawAbi caller shape: the midgc die arm emits a WORD call q_Rt_x2edie(l msg) — one Base L arg, never the lean 4-arg :val shape"
        (case QbeLower.lower rt False False False True True True True True False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.allocVector" of
            Ok mod ->
                case funcByName "q_Rt_x2egcInit" mod of
                    Just f ->
                        rawAbiWordCall "q_Rt_x2edie" f

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "rawAbi caller shape: the halt arm retargets rt_halt -> q_Rt_x2ehalt (B4 deleted the Zig rt_halt seat, so the symbol swap is unconditional)"
        (let
            prog =
                (driverProg rt)
         in
         case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities prog) prog "Rt.emptylist" of
            Ok mod ->
                case funcByName "q_Rt_x2eemptylist" mod of
                    Just f ->
                        callsSym "q_Rt_x2ehalt" f && not (callsSym "rt_halt" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )

    -- STAGE 6 A1: the LOWER INTERFACE THE DRIVER NEEDS (the six items of the
    -- re-plan's "THE LOWER INTERFACE" obs).  The driver BODY is A3a's job —
    -- these rows pin only the INTERFACE: the rawAbi ret-class, the export-
    -- name override, the driverSeeds addition, the RawCallAgg named-symbol
    -- accept + still-rejected shape, the val-position Blit, and the arity
    -- record totality.
    , check "A1 ret-class: Rt.main (2 word params argc/argv) emits params [a0:l,a1:l] and ret w (the exit code) — the per-key rawAbi RET CLASS (Rt.die/Rt.halt stay ret l, pinned above)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggSymProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggSymProbe ]) "Rt.rawCallAggSymProbe" of
            Ok mod ->
                List.any rawCallAggSymCallShape mod.funcs

            Err _ ->
                False
        )
    , check "A1b RawCallAgg DATA-symbol callee rejected: a rawstr data-def stand-in (RawCStr \"rt_bounce\") is a loud Err, not a silent call into static data (the A1-review blocker's over-acceptance half)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rawCallAggDataSymProbe ] "Rt.rawCallAggDataSymProbe" of
            Err msg ->
                String.contains "DATA" msg

            Ok _ ->
                False
        )
    , check "A1 RawCallAgg still-rejected shape: a CONSTANT callee is a loud Err (the callee must be a RawSym function symbol or a loaded code pointer, never a constant)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty Dict.empty [ rawCallAggConstProbe ] "Rt.rawCallAggConstProbe" of
            Err msg ->
                String.contains "not a constant" msg

            Ok _ ->
                False
        )
    , check "A1b RawCallAgg VALUE-position Blit: a val-shaped aggregate call of rt_bounce emits Call (Just _) (Agg \"val\") (Il.Sym \"rt_bounce\") + a 40-byte Blit into the dest slot (the rtApply non-tail shape, never a word-address return)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggValProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggValProbe ]) "Rt.rawCallAggValProbe" of
            Ok mod ->
                List.any rawCallAggValBlitShape mod.funcs

            Err _ ->
                False
        )
    , check "A1b emitted .ssa names the FUNCTION symbol as the call target: the lowered module RENDERED as .ssa contains `call $rt_bounce` (a code label), not a data-def call"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggSymProbe ])) (rtProgram rt True True True ++ rtProgramGc rt True True True ++ [ rawCallAggSymProbe ]) "Rt.rawCallAggSymProbe" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (List.any (\d -> List.member (Il.DStr "usage: <prog> <entry-name> [int|float-arg ...]\n") d.items) mod.datas)
                    && (List.any (\d -> List.member (Il.DStr "qbe-rt: >16 entry args not supported\n") d.items) mod.datas)

            Err _ ->
                False
        )
    , check "A3a MIDDRIVER emission — the error paths CALL write and exit IN $main: $main's OWN blocks emit >=2 call $write and >=2 call $exit (usage and toomany each write fd-2 then exit 2; notmeta adds more writes) — COUNTED, not just scoped, so neither Rt.die/Rt.halt (other functions) NOR the notmeta path alone can satisfy it (the A3a-review SHOULD-FIX 1, the count form)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (List.any (\d -> List.member (Il.DStr "qbe-rt: entry '") d.items) mod.datas)
                    && (List.any (\d -> List.member (Il.DStr "' not in qbe_meta\n") d.items) mod.datas)

            Err _ ->
                False
        )
    , check "A3b MIDDRIVER emission — the meta walk reads the exported table: the rendered .ssa references $qbe_meta and $qbe_meta_len (the wload base/count of the walk)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
    , check "A4a MIDDRIVER emission — the seats + root push (RE-PINNED AT O5 SEAT 4b): the rendered .ssa references $rt_boot and $q_Rt_x2erootPushValueArray (the A2 seat the driver still rawcalls, and ZIGHOST Z1's Mid registry push it now calls), and the entry-arg parser + *argv* installer are now MID DEFUNS the driver CALLS — q_Rt_x2eparseArg from the arg loop and q_Rt_x2eargvInstall from Rt.main — with no $rt_parse_arg/$rt_argv_install anywhere (the Zig seats are deleted)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                let
                    ssa =
                        Print.print mod
                in
                String.contains "call $q_Rt_x2eboot" ssa
                    && not (String.contains "$rt_boot" ssa)
                    && String.contains "call $q_Rt_x2erootPushValueArray" ssa
                    && String.contains "call $q_Rt_x2eparseArg" ssa
                    && String.contains "call $q_Rt_x2eargvInstall" ssa
                    && not (String.contains "$rt_parse_arg" ssa)
                    && not (String.contains "$rt_argv_install" ssa)

            Err _ ->
                False
        )
    , check "A4a MIDDRIVER emission — the 17-arm entry dispatch: $main calls the rt_callN dispatchers by NAME (aggcall ret rawsym) and q_Rt_x2ebounce (aggcall val, the stage-6 B2 Mid bounce — the driver's entry chase routes through the MID trampoline, not the Zig rt_bounce seat) — the RawCallAgg named-symbol shape, not a call into data"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                case funcByName "main" mod of
                    Just f ->
                        callsSym "rt_call1" f
                            && callsSym "rt_call9" f
                            && callsSym "rt_call16" f
                            && callsSym "q_Rt_x2ebounce" f
                            && not (callsSym "rt_bounce" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "A4b MIDDRIVER emission — the program/print tail (RE-PINNED AT O4): the Zig seats rt_is_program/rt_run_program are RETIRED with the effect loop — $main now asks Rt.hostIsProgram (the Mid predicate), drives Rt.hostRun (the only host), and prints through rt_print_value with Rt.rootPushValue for the model root"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                case funcByName "main" mod of
                    Just f ->
                        callsSym "q_Rt_x2ehostIsProgram" f
                            && callsSym "q_Rt_x2ehostRun" f
                            && callsSym "q_Rt_x2eprintValue" f
                            && callsSym "q_Rt_x2erootPushValue" f
                            && not (callsSym "rt_is_program" f)
                            && not (callsSym "rt_run_program" f)

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
         case QbeLower.lower rt False False False True True True True True False True QbeTypes.empty (rtArities prog) prog "Rt.allocVector" of
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
         case QbeLower.lower rt False False False True True True True True False True QbeTypes.empty (rtArities prog) prog "Rt.allocVector" of
            Ok mod ->
                List.any (\d -> List.member (Il.DStr "qbe-rt: midgc: mmap failed") d.items) mod.datas
                    && not (List.any (\d -> List.member (Il.DStr "midgc: mmap failed") d.items) mod.datas)

            Err _ ->
                False
        )

    -- STAGE 6 U2 fix 4 (re-pinned at B4, at STAGE 7 O3, and at ZIGHOST Z0):
    -- THE NativeMain VECTOR PIN (plan obs-5's deferred obligation, the
    -- unpinned-drift class).  The hatch pair this row was written for is GONE:
    -- B4 removed midDriver, and Z0 removed the collector hatch — there is no
    -- QBE_MIDGC flag left in run.js to disagree with.  What remains is the
    -- POSITIONAL SLOT: `Mid.QbeModule.compileEntry`'s call shape still carries
    -- a collector bit, so selfhost/NativeMain.elm passes the literal True in it
    -- and `defaultMidGc` pins that literal.  The slot is INERT (QbeLower.lower
    -- binds it `_midGc`, unread), so this row no longer pins a DEFAULT — it
    -- pins that the slot has not silently started selecting something again,
    -- together with the route it used to select and which is now unconditional:
    -- q_Rt_x2ehalt IS emitted (the driver's Rt.halt), rt_glob IS emitted (the
    -- B0 frame pair's freelist/frame_top block), and the halt arm retargets
    -- rt_halt -> q_Rt_x2ehalt.
    , check "U2 fix 4 — NativeMain vector pin (re-pinned at ZIGHOST Z0): the selfhost call shape's collector slot is the literal True (INERT — the hatch is retired, no arm reads it), and the route it once selected is now unconditional: q_Rt_x2ehalt emitted, rt_halt retargeted, rt_glob emitted for the B0 frame pair"
        (let
            midGc =
                defaultMidGc

            prog =
                rtProgram rt True True True
         in
         (defaultMidGc == True)
            && -- THE COLLECTOR HALF IS PART OF THE PROGRAM THE SEEDING
               -- REACHES: the allocation seats are Rt.allocVector/Rt.allocRaw,
               -- which live in rtProgramGc — a program without them fails the
               -- lowering LOUDLY ("qbe: unknown global Rt.allocVector",
               -- MEASURED).  Since Z0 the gc seeds are seeded unconditionally
               -- (Lower's gcSeeds line reads no flag), so the row lowers the
               -- same union rt.programGc participates in at emit time.
               (case QbeLower.lower rt False False False True True True True midGc False True QbeTypes.empty (rtArities (prog ++ rtProgramGc rt True True True)) (prog ++ rtProgramGc rt True True True) "Rt.emptylist" of
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

    -- STAGE 6 U1c + B4: the Mid-owned globals block + its 0-arg accessor.
    -- Originally GATED on the midgc flag (plan correction C3); B4 made the
    -- block UNCONDITIONAL because the Mid frame pair (the default route)
    -- always reads rt_glob's freelist/frame_top words.  Z0 RETIRED the row
    -- that pinned "midGc OFF still emits rt_glob + rt_glob_addr": the flag it
    -- set is gone and the slot it passed is inert, so that row could no longer
    -- fail for the reason it named.  The row below asserts the same two defs,
    -- in their pinned shapes, on the one route there is.
    , check "stage6 globals block: both defs are emitted unconditionally (Z0: no collector flag), in the pinned shapes, and no gc defun names the deleted seats"
        (case QbeLower.lower rt False False False True True True True defaultMidGc False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.allocVector" of
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

    -- O5 SEAT 4: the globals block must COVER every slot the Mid runtime
    -- addresses.  Seat 2 read the intern table's words 8208..8210 while
    -- globWords was still `globFreelistSlot + 8192` = 8208, so those 24 bytes
    -- sat PAST the emitted `z 65664` and landed on hostshim's
    -- rt_string_calls/intern_hits/intern_misses in the linked binary.  This
    -- pin reads the EMITTED block size (Lower's DZero item, i.e. what the
    -- linker actually sees) and requires it to reach past the intern slot, so
    -- a slot added without growing the block fails here instead of silently
    -- escaping $rt_glob again.  globInternSlot + 3 = the table's last word.
    , check "O5 seat 4 glob pin: the emitted $rt_glob covers the intern table's last word (globInternSlot + 2), computed from the DZero byte count — a freelist-sized block would fail"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.allocVector" of
            Ok mod ->
                case List.filter (\d -> d.name == RtGc.globDataSym) mod.datas of
                    [ d ] ->
                        case d.items of
                            [ Il.DZero bytes ] ->
                                bytes >= 8 * (RtGc.globInternSlot + 3) && bytes == 8 * RtGc.globWords

                            _ ->
                                False

                    _ ->
                        False

            Err _ ->
                False
        )

    -- ZIGHOST Z1: THE ROOT REGISTRY'S LAYOUT.  The registry lives in globals
    -- words 4/5/6 (base/count/cap), the three words RtGc's table names, and
    -- the emitted $rt_glob covers them; the two collector walkers read THAT
    -- pair of words (not a seat) and dispatch on the 3-word {kind,slot,np}
    -- entry stride.  The fail-before this row is for: a walker left reading
    -- the retired rt_gc_root_* seats (deleted from rt.o) would link-fail on a
    -- fixture build, but a walker reading the WRONG WORD would silently walk
    -- garbage — so the word indices are pinned against RtGc's own constants,
    -- not spelled twice.
    , check "Z1 root registry pin: globRootSlot == 4 (base), count at +1 and cap at +2, the emitted $rt_glob covers word 6, and BOTH collector walkers read the registry (no rt_gc_root_* seat anywhere)"
        (RtGc.globRootSlot
            == 4
            && RtGc.globWords
            >= 7
            && String.contains "word nRoots = wload(glob, 5);" runtimeMidText
            && String.contains "word kind = wload(base, iW * 3);" runtimeMidText
            && String.contains "word np = wload(base, iW * 3 + 2);" runtimeMidText
            && not (String.contains "rt_gc_root_kind" runtimeMidText)
            && not (String.contains "rt_gc_roots_len" runtimeMidText)
            && not (String.contains "rt_root_push" runtimeMidText)
        )

    -- ZIGHOST Z4a: THE FLOAT TEXT IS MID'S.  The two seats are deleted, so the
    -- structural half is: nothing names them, Rt.str's float arm is a Mid
    -- call, and the heap knob is read by gcInit through the Mid env reader.
    -- The BEHAVIOURAL half is the float matrix (46 goldens, including the two
    -- 64-byte truncations float-maxF / float-denorm and the nan/inf spellings),
    -- which is why no row here re-states the text.
    , check "Z4a float text pin: Rt.str's float arm calls q_Rt_x2efloatText (the rt_float_text seat is gone), gcInit reads QBE_HEAP_MB through Rt.gcEnvNum (the rt_gc_heap_bytes seat is gone), and the eight float-text defuns are in the surface"
        ((case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.str" of
            Ok mod ->
                List.any (\f -> f.name == "q_Rt_x2estr" && callsSym "q_Rt_x2efloatText" f) mod.funcs
                    && not (List.any (callsSym "rt_float_text") mod.funcs)

            Err _ ->
                False
         )
            && String.contains "rawcall getenv(rawstr(\"QBE_HEAP_MB\"))" runtimeMidText
            && not (String.contains "rawcall rt_gc_heap_bytes" runtimeMidText)
            && not (String.contains "rawcall rt_float_text" runtimeMidText)
            && List.all (\k -> List.member k (List.map .key (driverProg rt)))
                [ "Rt.floatText", "Rt.fShortest", "Rt.fRender", "Rt.fExpAt", "Rt.fExpGo", "Rt.fEmit", "Rt.fEmitByte", "Rt.fDigit" ]
        )

    -- ZIGHOST Z4b: THE PRINTER IS MID'S.  The seat is deleted, so the
    -- structural half is: Rt.main calls q_Rt_x2eprintValue, nothing names the
    -- Zig seat, the eight walk defuns are in the surface, and the ONE
    -- non-reproducible tag is refused BY NAME rather than printed as an
    -- address.  The behavioural half is the whole corpus (every golden is the
    -- printer's output), which is why no row here re-states a shape.
    , check "Z4b printer pin: Rt.main calls q_Rt_x2eprintValue (the rt_print_value seat is gone), the eight walk defuns are in the surface, and a LAMBDA is refused by name (its printed form would carry code/env addresses)"
        ((case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                List.any (\f -> f.name == "main" && callsSym "q_Rt_x2eprintValue" f) mod.funcs
                    && not (List.any (callsSym "rt_print_value") mod.funcs)

            Err _ ->
                False
         )
            && not (String.contains "rawcall rt_print_value" runtimeMidText)
            && String.contains "refused by name" runtimeMidText
            && List.all (\k -> List.member k (List.map .key (driverProg rt)))
                [ "Rt.printValue", "Rt.pvV", "Rt.pvRec", "Rt.pvNeed", "Rt.pvN", "Rt.pvByte", "Rt.pvZ", "Rt.pvS" ]
        )

    -- ZIGHOST Z5: THE LAST ZIG OWNER IS GONE.  rt_boot is deleted, so the
    -- structural half is: nothing names the seat, Rt.main calls the Mid boot,
    -- the values table and the three streams are installed by Mid (the same
    -- globals word 3 the Z1 walkers read), and the surface carries the pair.
    -- The BEHAVIOURAL half is the whole gate (every fixture boots, and the
    -- ioecho/io-read rows are what read *stinput*/*stoutput*).
    , check "Z5 boot pin: Rt.main calls q_Rt_x2eboot (the rt_boot seat is gone), no rawcall names it, Rt.boot publishes the values table into globals word 3 and installs the three standard streams, and the boot pair is in the surface"
        ((case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                List.any (\f -> f.name == "main" && callsSym "q_Rt_x2eboot" f) mod.funcs
                    && not (List.any (callsSym "rt_boot") mod.funcs)

            Err _ ->
                False
         )
            && not (String.contains "rawcall rt_boot" runtimeMidText)
            && String.contains "wstore(rawcall rt_glob_addr(), 3, tab);" runtimeMidText
            && String.contains "*stinput*" runtimeMidText
            && String.contains "*stoutput*" runtimeMidText
            && String.contains "*sterror*" runtimeMidText
            && List.all (\k -> List.member k (List.map .key (driverProg rt))) [ "Rt.boot", "Rt.valSlot" ]
        )

    -- STAGE 6 B0: the frame machinery retarget.  Under QBE_MIDDRIVER=1 the
    -- pooled-frame prologue calls the Mid rawAbi defun q_Rt_x2eframe_x2denter
    -- (nslots as an `l` word — the raw-word ABI, NOT the Zig seat's `w` i32)
    -- and the return calls q_Rt_x2eframe_x2dleave; the DEFAULT route keeps
    -- the Zig rt_frame_enter/rt_frame_leave seats.  These pins are the
    -- byte-identity boundary for the hatch.
    , check "B0 prologue retarget: under QBE_MIDDRIVER a framed defun enters through q_Rt_x2eframe_x2denter with an l-word nslots (Base L, not the Zig seat's Base W)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.cons" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.cons" of
            Ok mod ->
                case funcByName "q_Rt_x2econs" mod of
                    Just f ->
                        callsSym "q_Rt_x2eframe_x2dleave" f && not (callsSym "rt_frame_leave" f)

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "B0 frame defuns are rawAbi frame-free emission: q_Rt_x2eframe_x2denter/Leave emit frame-FREE alloc8 scratch (no rt_frame_enter), l params/ret, and the frame pair + helpers are EMITTED (driverSeeds)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
    , check "B0 globals-block ungating: the driver route emits rt_glob + rt_glob_addr — the frames' freelist/frame_top block (B4 made it unconditional; Z0 removed the flag the label used to name)"
        (case QbeLower.lower rt False False False True True True True defaultMidGc False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
    , check "B1 loop/helper framing: the loops and the dispatch are FRAMED (they reach a safepoint), copyWords is frame-free, and the dispatch reaches rt_callN/q_Rt_x2ebounce by name (the stage-6 B2 retarget — the apply dispatch routes through the MID bounce, not the Zig rt_bounce seat)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
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
                                callsSym "rt_call16" f && callsSym "q_Rt_x2ebounce" f && not (callsSym "rt_bounce" f)

                            Nothing ->
                                False
                       )
                    && (case funcByName "q_Rt_x2ecopyWords" mod of
                            Just f ->
                                frameBaseIsAlloc f && not (callsSym "rt_frame_enter" f) && callsSym "q_Rt_x2ecopyWordsGo" f

                            Nothing ->
                                False
                       )
                    && (case funcByName "q_Rt_x2ecopyWordsGo" mod of
                            Just f ->
                                frameBaseIsAlloc f && not (callsSym "rt_frame_enter" f)

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "B1 root-order: THE PARTIAL ARM's env slot is rooted BEFORE the alloc and RE-READ AFTER (push_ptr -> q_Rt_x2eallocVector -> loadl, in ONE block) — the cStrFill lesson.  A push-after-alloc or a pre-alloc-copy mutation breaks this shape (the emitted .ssa loses the post-alloc load or the pre-alloc push) and fails HERE, because the runtime churn rows CANNOT see the hazard (the moving collector copies bodies without destroying them, so a stale read is output-silent).  STAGE 7 O3-fix MOVED THE PIN'S TARGET: applyGo and applyTailGo no longer spell this dance (three copies were three chances to drift), so the ONE site is Rt.applyPartGo — and the second half of the row is what keeps it one: both loops' partial arms must CALL it, so a re-inlined copy in either loop is RED here."
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (driverProg rt)) (driverProg rt) "Rt.main" of
            Ok mod ->
                (case funcByName "q_Rt_x2eapplyPartGo" mod of
                    Just f ->
                        partialRootOrder f

                    Nothing ->
                        False
                )
                    && (case ( funcByName "q_Rt_x2eapplyGo" mod, funcByName "q_Rt_x2eapplyTailGo" mod ) of
                            ( Just a, Just b ) ->
                                callsSym "q_Rt_x2eapplyPartGo" a && callsSym "q_Rt_x2eapplyPartGo" b

                            _ ->
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
            -- text-fix: the byte-copy and digit loops MUST be frame-free — an
            -- ALLOCATING callee allocates a GC frame at CALL time, i.e. a
            -- safepoint, and cn2/numText/substring/symToStr call them while
            -- holding a freshly `allocraw`'d — UNROOTED — buffer (the
            -- cStrFill lesson: a collect there scavenges it).  Their bodies
            -- are `mknum` (a frame-slot box, not a GC allocation) + `recur`.
            && not (Set.member "Rt.byteCopyGo" rt.allocating)
            && not (Set.member "Rt.digitCount" rt.allocating)
            && not (Set.member "Rt.numFill" rt.allocating)
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
            && not (Set.member "Rt.gcClearClasses" rt.allocating)
            && not (Set.member "Rt.gcAlloc" rt.allocating)
            && not (Set.member "Rt.gcAllocGo" rt.allocating)
            && not (Set.member "Rt.gcScanValueArray" rt.allocating)
            && not (Set.member "Rt.gcInit" rt.allocating)
            && not (Set.member "Rt.gcEnvNum" rt.allocating)
            && not (Set.member "Rt.gcVD" rt.allocating)
            && not (Set.member "Rt.gcVerify" rt.allocating)
            && not (Set.member "Rt.gcVerifyList" rt.allocating)
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

            -- GC NURSERY carve-out, and why it is not a hole: Rt.gcAlloc's
            -- and Rt.collect's calls into the scavenge family exist ONLY in
            -- a QBE_MIDGC_YOUNG=1 build (the call sites are inside the
            -- spliced region), so they can NEVER be a static rtDeps row —
            -- gcSeeds closes over those rows in EVERY MIDGC build and would
            -- drag the absent defuns into a plain one ("unknown global").
            -- The edge's declaration lives in Rt.youngGcSeeds instead (the
            -- young build's OWN seed closure), so THAT membership is what the
            -- row accepts here — and youngGcSeeds' closure covers the whole
            -- family, which the next conjunct pins.
            ok key =
                List.all
                    (\sym ->
                        List.member sym programKeys
                            && (List.member sym (Maybe.withDefault [] (Dict.get key Rt.rtDeps))
                                    || List.member sym Rt.youngGcSeeds
                               )
                    )
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
    , check "rt gc seeds: the collector seeds are exactly the two seats plus their transitive closure (stage 6 U2 adds Rt.die + Rt.cStrLenGo through the die arm's RawCall edge; GC-ARC F1 adds the stats printer Rt.gcNumOut + its digit loop Rt.gcNum through Rt.collect; GC ARC unit 2 adds the verifier walk Rt.gcVerify -> Rt.gcVerifyList and its die printer Rt.gcVD through Rt.collect and Rt.gcMarkPtr)"
        (Rt.gcSeeds
            == [ "Rt.allocVector", "Rt.gcInit", "Rt.die", "Rt.cStrLenGo", "Rt.gcEnvNum", "Rt.gcAlloc", "Rt.gcAllocGo", "Rt.collect", "Rt.gcMarkRoots", "Rt.gcScanValueArray", "Rt.gcMarkValue", "Rt.gcMarkPtr", "Rt.gcVD", "Rt.gcNumOut", "Rt.gcNum", "Rt.gcMarkValuesTab", "Rt.gcDrain", "Rt.gcSweep", "Rt.gcClearClasses", "Rt.gcVerify", "Rt.gcVerifyList", "Rt.gcGrow", "Rt.allocRaw" ]
        )
    , check "rt con seeds: the Mid ADT constructor and its fill helper"
        (Rt.conSeeds == [ "Rt.con", "Rt.conFill" ]
        )
    -- ==================== GC-ARC F1: the mark-stack bound ====================
    -- The bound was an ASSERTION in the plan ("holds by 0.05% at 16 MB").  It is
    -- now a DERIVED guard in Rt.gcInit (it dies at init when the mark stack is
    -- smaller than the heap can hold) plus the arithmetic below, which states
    -- the margin at the probe heaps.  The numbers are a MIRROR of gcInit's
    -- formula — a TestMain row cannot execute Mid — so the row's job is to make
    -- the margin a stated quantity and to go RED if the SHAPE of the derivation
    -- is deleted; the LIVE check is the runtime guard, proven by
    -- probe-midgc-guards.sh (a halved mark stack dies at init with the fix and
    -- runs silently without it).
    , check "GC-ARC F1 mark-stack margin, RE-DERIVED AGAINST THE CEILING (GC ARC unit 4): capacity (markEnd - 64 = ceiling/512 words /8 + 64) EXCEEDS the largest block count the whole RESERVE can hold (ceiling/64) — and the margin is now the CONSTANT 64 at every heap and every ceiling, because the stack is sized for the ceiling rather than for the initial heap.  The smallest physical block is class 1 = 8 words = 64 bytes, so no heap this geometry can map holds more than (capEnd - heapStart)/64 bodies, and the mark walk pushes at most one entry per body: the stack CANNOT overflow, and a grown limit can never outrun it"
        (List.all
            (\mb ->
                let
                    ( capacity, maxBlocks ) =
                        marginParts (mb * 8)
                in
                capacity >= maxBlocks && maxBlocks > 0
            )
            [ 16, 32, 64, 128 ]
        )
    , check "GC-ARC F1 mark-stack margin, the MEASURED points gcInit's comment quotes: 16 MB heap / 128 MB ceiling -> 2097216 capacity vs 2097152 bodies, 64 MB / 512 MB -> 8388672 vs 8388608 — a margin of exactly 64 entries at both"
        (( marginParts 128, marginParts 512 )
            == ( ( 2097216, 2097152 ), ( 8388672, 8388608 ) )
        )
    , check "GC ARC unit 4 GEOMETRY: the layout is sized for the CEILING — markEnd, numClasses and regionSize are all derived from capBytes (never from the initial heap), so a grown heap cannot outrun the mark stack or the free-list table.  A heap-sized derivation would put the margin at ZERO and this row is what makes that substitution RED"
        (String.contains "word capWords = capBytes / 8;" runtimeMidText
            && String.contains "word markEnd = 64 + capWords / 8 + 64;" runtimeMidText
            && String.contains "word regionSize = markEnd * 8 + rsWords * 8 + numClasses * 8 + 16 + bmBytes + capBytes + youngFit;" runtimeMidText
            && String.contains "wstore(base, 24, capEnd);" runtimeMidText
            && String.contains "word bmBytes = capBytes / 64;" runtimeMidText
        )
    , check "GC ARC unit 4 GROWTH is PRESENT in runtime.mid (the tripwire that keeps it from being deleted): gcAlloc raises heapEnd by a doubling clamped to capEnd, reports it under QBE_MIDGC_STATS, and DIES LOUDLY at the ceiling instead of failing at the initial size"
        (String.contains "word limUp = payload((dbl < needLim) ? mknum(needLim) : mknum(dbl), 0);" runtimeMidText
            && String.contains "word limCap = payload((limUp < capLim) ? mknum(limUp) : mknum(capLim), 0);" runtimeMidText
            && String.contains "midgc: grow " runtimeMidText
            && String.contains "out of memory: heap at its ceiling of " runtimeMidText
        )
    , check "GC-ARC F1 guards are PRESENT in runtime.mid (the tripwire that keeps them from being deleted): gcInit carries the derived capacity check and collect tests the region WORD before it dereferences it"
        (String.contains "word maxBlocks = (capEnd - heapStart) / 64;" runtimeMidText
            && String.contains "mark stack smaller than the heap can hold" runtimeMidText
            && String.contains "midgc: collect before init (no region mapped)" runtimeMidText
        )
    , check "rt closure seeds: the Mid closure and its 0-based fill helper"
        (Rt.closureSeeds == [ "Rt.closure", "Rt.closureFill" ]
        )
    , check "rt lean ABI: a frame-free callee has pointer params, :val return and NO frame enter/leave"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.+" of
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
    , check "rt lean ABI: a framing callee (cons) enters/leaves through the Mid frame pair and keeps the lean signature"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.cons" of
            Ok mod ->
                case List.filter (\f -> f.name == "q_Rt_x2econs") mod.funcs of
                    f :: _ ->
                        List.map Tuple.second f.params == [ Il.Base Il.L, Il.Base Il.L, Il.Base Il.L, Il.Base Il.W ]
                            && f.ret == Il.Agg "val"
                            && callsSym "q_Rt_x2eframe_x2denter" f
                            && callsSym "q_Rt_x2eframe_x2dleave" f

                    [] ->
                        False

            Err _ ->
                False
        )
    , check "rt lean ABI: the Zig rt_bounce seat appears NOWHERE in any emit (B4 deleted it — the Mid q_Rt_x2ebounce is the only bounce)"
        (case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.+" of
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
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) key of
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
        (case ( QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True True ++ rtProgramGc rt True True True)) (rtProgram rt True True True ++ rtProgramGc rt True True True) "Rt.="
              , QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities (rtProgram rt True True False ++ rtProgramGc rt True True False)) (rtProgram rt True True False ++ rtProgramGc rt True True False) "Rt.="
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
    , check "parse: true/false are BOOL literals (B1: EBool, no longer the mkbool(1)/mkbool(0) sugar tree) and mknil is the bare nil literal"
        (Parse.parseExp "true" == Ok (Ast.EBool True)
            && Parse.parseExp "false"
                == Ok (Ast.EBool False)
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

    -- ==================== U1: structs, enums, pointers (midlang-u1) ====================
    -- The grammar only: decls carry on the module record, `*S`/`*word`/
    -- `*val` annotate types, and the postfix/store forms parse into new
    -- constructors — all REJECTED downstream today (U2's checker / U3's
    -- lowerer are the next units).  Every row asserts the exact AST so a
    -- silent re-association cannot pass; the anti-empty guard pins a
    -- NON-empty decl list (a vacuous `[]` parse must not pass).

    , check "parse U1: a struct declaration lands on the module's decls (declaration-order fields, exact AST)"
        (case Parse.parseModule "struct Region { magic : word; count : word; }" of
            Ok m ->
                m.header == { name = Nothing, exports = [] }
                    && m.decls
                    == [ Ast.StructDecl
                            { name = "Region"
                            , members =
                                [ Ast.MField { name = "magic", ty = Ast.TWord, width = Nothing }
                                , Ast.MField { name = "count", ty = Ast.TWord, width = Nothing }
                                ]
                            }
                       ]
                    && m.defuns == []

            Err _ ->
                False
        )
    , check "parse U1 ANTI-EMPTY: the decl list is NON-empty and the fields carry their names/types (a vacuous parse must not pass)"
        (case Parse.parseModule "struct Hdr { flags : word; next : *Hdr; }" of
            Ok m ->
                case m.decls of
                    (Ast.StructDecl s) :: _ ->
                        s.name == "Hdr"
                            && List.length s.members == 2
                            && s.members == [ Ast.MField { name = "flags", ty = Ast.TWord, width = Nothing }, Ast.MField { name = "next", ty = Ast.TPtr (Ast.PStruct "Hdr"), width = Nothing } ]

                    _ ->
                        False

            Err _ ->
                False
        )
    , check "parse U1: an enum declaration (C-style named word constants, exact AST)"
        (case Parse.parseModule "enum RootKind { ptr = 0; value = 1; }" of
            Ok m ->
                m.decls
                    == [ Ast.EnumDecl
                            { name = "RootKind"
                            , entries =
                                [ { name = "ptr", value = 0 }
                                , { name = "value", value = 1 }
                                ]
                            }
                       ]

            Err _ ->
                False
        )
    , check "parse U1: a pointer annotation in the type position (*Region as a param type)"
        (case Parse.parseProgram "defun Rt.f(p: *Region) -> word { return wload(p, 0); }" of
            Ok defuns ->
                case defuns of
                    d :: _ ->
                        d.params == [ { name = "p", ty = Ast.TPtr (Ast.PStruct "Region") } ]
                            && d.ret == Ast.TWord

                    [] ->
                        False

            Err _ ->
                False
        )
    , check "parse U1: postfix field read p->f and the chained a->b->c (EField)"
        (Parse.parseExp "p->f" == Ok (Ast.EField (Ast.EVar "p") "f")
            && Parse.parseExp "a->b->c" == Ok (Ast.EField (Ast.EField (Ast.EVar "a") "b") "c")
        )
    , check "parse U1: postfix index read p[i] (EIndex) and a field-then-index chain a->tab[i]"
        (Parse.parseExp "p[i]" == Ok (Ast.EIndex (Ast.EVar "p") (Ast.EVar "i"))
            && Parse.parseExp "a->tab[i]" == Ok (Ast.EIndex (Ast.EField (Ast.EVar "a") "tab") (Ast.EVar "i"))
        )
    , check "parse U1: prefix deref *p (EDeref) and postfix binds tighter than * (*p->f is *(p->f))"
        (Parse.parseExp "*p" == Ok (Ast.EDeref (Ast.EVar "p"))
            && Parse.parseExp "*p->f" == Ok (Ast.EDeref (Ast.EField (Ast.EVar "p") "f"))
        )
    , check "parse U1: field/index store statements (SFieldStore / SIndexStore, exact AST)"
        (Parse.parseBlock "{ p->f = e;\n  p[i] = e;\n  return mknil; }"
            == Ok
                { stmts =
                    [ Ast.SFieldStore (Ast.EVar "p") "f" (Ast.EVar "e")
                    , Ast.SIndexStore (Ast.EVar "p") (Ast.EVar "i") (Ast.EVar "e")
                    ]
                , term = Ast.TRet (Ast.EBuiltin Ast.MkNil [])
                }
        )
    , check "parse U1: a pointer-typed binder (*Region r = e;) parses to SBind with a TPtr type"
        (case Parse.parseBlock "{ *Region r = payload(v, 0);\n  return mknum(r); }" of
            Ok b ->
                case b.stmts of
                    Ast.SBind (Ast.TPtr (Ast.PStruct "Region")) "r" (Ast.EBuiltin Ast.Payload [ Ast.EVar "v", Ast.EInt 0 ]) :: _ ->
                        True

                    _ ->
                        False

            Err _ ->
                False
        )

    -- must-fail rejects (each pins the message fragment — a loud-but-wrong failure must not pass)
    , check "parse U1 REJECTS a malformed struct decl (a dropped `;` separator)"
        (case Parse.parseModule "struct Region { magic : word }" of
            Err msg ->
                String.contains "expected `;`" msg

            Ok _ ->
                False
        )
    , check "parse U1 REJECTS a lowercase struct name (structs/enums are Uppercase identifiers)"
        (case Parse.parseModule "struct region { magic : word; }" of
            Err msg ->
                String.contains "Uppercase struct/enum name" msg

            Ok _ ->
                False
        )
    , check "parse U1 REJECTS a misplaced decl (a struct AFTER a defun is trailing input, not a declaration)"
        (case Parse.parseModule "defun Rt.f() -> val { return mknil; }\nstruct Region { magic : word; }" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    , check "parse U1 REJECTS `*p = e;` (v1 has no deref-store — at statement start a `*` is a pointer bind, and `p` is no pointee)"
        (case Parse.parseBlock "{ *p = e; return mknil; }" of
            Err msg ->
                String.contains "pointer pointee" msg

            Ok _ ->
                False
        )

    -- ==================== cffi U1: `extern` declarations (grammar + CARRYING, no semantics) ====================
    -- An `extern` is the THIRD file-scoped declaration: it lands on
    -- `Module.decls` beside `struct`/`enum` and NOTHING consults it yet (the
    -- typed call boundary is cffi U2), so these rows are about the GRAMMAR and
    -- the CARRIED record only.  Every accept row asserts the exact `FfiSig`
    -- (a silently re-ordered parameter list must fail), every reject row pins
    -- a message fragment AND its position, so a row cannot pass on a parse
    -- that failed for a different reason.  The INERT rows at the end are the
    -- unit's real claim: a declaration moves no byte and rejects nothing.

    , check "parse cffi U1: an extern declaration lands on the module's decls (exact AST: declaration-order params, varargs False, i32 result) and the defuns are untouched"
        (case Parse.parseModule "extern access(path : ptr, mode : i32) -> i32;\ndefun Rt.f() -> word { return 0; }" of
            Ok m ->
                m.decls
                    == [ Ast.ExternDecl
                            { name = "access"
                            , sig =
                                { params =
                                    [ { name = "path", ty = Ast.FPtr }
                                    , { name = "mode", ty = Ast.FI32 }
                                    ]
                                , varargs = False
                                , result = Ast.FI32
                                }
                            }
                       ]
                    && List.map .key m.defuns
                    == [ "Rt.f" ]

            Err _ ->
                False
        )
    , check "parse cffi U1: ALL SEVEN widths parse in the RESULT position — the table is exactly i32 u32 i64 u64 ptr f64 void (and every one of these declarations also pins ZERO params)"
        (List.all
            (\( width, want ) ->
                case Parse.parseModule ("extern g() -> " ++ width ++ ";") of
                    Ok m ->
                        List.filterMap externSigOf m.decls
                            == [ { params = [], varargs = False, result = want } ]

                    Err _ ->
                        False
            )
            [ ( "i32", Ast.FI32 )
            , ( "u32", Ast.FU32 )
            , ( "i64", Ast.FI64 )
            , ( "u64", Ast.FU64 )
            , ( "ptr", Ast.FPtr )
            , ( "f64", Ast.FF64 )
            , ( "void", Ast.FVoid )
            ]
        )
    , check "parse cffi U1: the six non-void widths parse in the PARAMETER position (a parameter is a register class — `void` is not one, see the R-05 reject)"
        (case Parse.parseModule "extern seven(a : i32, b : u32, c : i64, d : u64, e : ptr, f : f64) -> i32;" of
            Ok m ->
                List.filterMap externSigOf m.decls
                    == [ { params =
                            [ { name = "a", ty = Ast.FI32 }
                            , { name = "b", ty = Ast.FU32 }
                            , { name = "c", ty = Ast.FI64 }
                            , { name = "d", ty = Ast.FU64 }
                            , { name = "e", ty = Ast.FPtr }
                            , { name = "f", ty = Ast.FF64 }
                            ]
                         , varargs = False
                         , result = Ast.FI32
                         }
                       ]

            Err _ ->
                False
        )
    , check "parse cffi U1: the trailing `...` is CARRIED (varargs True) and the fixed params stay before it"
        (case Parse.parseModule "extern printf(fmt : ptr, ...) -> i32;" of
            Ok m ->
                List.filterMap externSigOf m.decls
                    == [ { params = [ { name = "fmt", ty = Ast.FPtr } ]
                         , varargs = True
                         , result = Ast.FI32
                         }
                       ]

            Err _ ->
                False
        )
    , check "parse cffi U1: a zero-parameter `void` declaration (the `_exit` shape) — `()` with no params and a RESULT-position void"
        (case Parse.parseModule "extern _exit(code : i32) -> void;\nextern getpid() -> i32;" of
            Ok m ->
                List.filterMap externSigOf m.decls
                    == [ { params = [ { name = "code", ty = Ast.FI32 } ], varargs = False, result = Ast.FVoid }
                       , { params = [], varargs = False, result = Ast.FI32 }
                       ]

            Err _ ->
                False
        )
    , check "parse cffi U1: an extern rides BETWEEN the struct/enum decls and the defuns without disturbing either (3 decls in order, the header and the defun set intact)"
        (case Parse.parseModule "module M\nstruct S { f : word; }\nextern access(path : ptr, mode : i32) -> i32;\nenum K { a = 0; }\ndefun M.g(p : *S) -> word { return p->f; }" of
            Ok m ->
                m.header.name
                    == Just "M"
                    && List.length m.decls
                    == 3
                    && List.filterMap externSigOf m.decls
                    /= []
                    && List.map .key m.defuns
                    == [ "M.g" ]

            Err _ ->
                False
        )

    -- the named rejections, each pinning its OWN fragment (a loud-but-wrong failure must not pass)
    , check "parse cffi U1 REJECTS R-01: a width outside the table (`u8` — a MEMORY width, not a call class) — the message names the found token AND the whole admissible set"
        (case Parse.parseModule "extern f(a : u8) -> i32;" of
            Err msg ->
                String.contains "expected an FFI width (i32, u32, i64, u64, ptr, f64, void), found `u8`" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS R-02: `f32` is not a width (Mid has ONE float class, `d`/f64; QBE's `s` class is unbuilt) — the same table, the same message"
        (case Parse.parseModule "extern f(a : f32) -> i32;" of
            Err msg ->
                String.contains "expected an FFI width" msg
                    && String.contains "found `f32`" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS a `val` in a parameter slot — at parse it is simply not a width (the 40-byte aggregate has no C ABI, and the J15 wording that says so is cffi U2's)"
        (case Parse.parseModule "extern f(a : val) -> i32;" of
            Err msg ->
                String.contains "found `val`" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS R-05: `void` as a PARAMETER — 'void' is a RESULT-only width (and the row above proves `-> void` is accepted, so this is not a blanket void reject)"
        (case Parse.parseModule "extern f(a : void) -> i32;" of
            Err msg ->
                String.contains "'void' is a RESULT-only width" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS R-10: `...` that is not last — a COMMITTED reject naming the rule, never a silent end of the parameter list"
        (case Parse.parseModule "extern f(a : i32, ..., b : i64) -> i32;" of
            Err msg ->
                String.contains "'...' must be the last parameter" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS R-10 (the second arm): a SECOND `...` is not last either"
        (case Parse.parseModule "extern f(a : i32, ..., ...) -> i32;" of
            Err msg ->
                String.contains "'...' must be the last parameter" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS a non-plain extern symbol: a DOTTED name is a Mid defun key (`Rt.open`), never a C symbol"
        (case Parse.parseModule "extern Rt.open(path : ptr) -> i32;" of
            Err msg ->
                String.contains "expected a plain `extern` symbol" msg

            Ok _ ->
                False
        )
    , check "parse cffi U1 REJECTS a dropped `;` after a declaration (the same loud-separator discipline the struct fields keep)"
        (case Parse.parseModule "extern access(path : ptr) -> i32" of
            Err msg ->
                String.contains "expected `;`" msg

            Ok _ ->
                False
        )

    -- THE UNIT'S REAL CLAIM: parsed, CARRIED, NOT CONSULTED.  A declaration
    -- must check and lower to exactly what the same module without it produces
    -- — no J15, no node, no byte (U2 is what makes it mean something).
    , checkOkModule "check cffi U1 INERT: a module carrying an extern declaration CHECKS (the five decl folds have their arm, and the declaration contributes no table row — no J15 in this unit)"
        "extern access(path : ptr, mode : i32) -> i32;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , check "lower cffi U1 INERT: the same module LOWERS to the one defun it declares (the extern rides beside the defuns and emits nothing)"
        (case loweredRuntime "extern access(path : ptr, mode : i32) -> i32;\ndefun Rt.g() -> word {\n  return 0;\n}" of
            Ok ( _, defuns ) ->
                List.map .key defuns
                    == [ "Rt.g" ]

            Err _ ->
                False
        )

    -- ============ cffi U2: THE TYPED CALL BOUNDARY (the width fix) ============
    -- U1's seat was CARRIED-NOT-CONSULTED; these rows are what make the
    -- declaration mean something.  Three things must hold together, and each
    -- has its own row family:
    --   (a) LowerToIr puts the DECLARATION's widths ON THE NODE (so the
    --       emitter cannot re-derive them and cannot default them),
    --   (b) an UNDECLARED rawcall still lowers to the unchanged RawCallRaw
    --       (plan §6: the runtime's internal seats and the not-yet-migrated
    --       libc surface do not move a byte),
    --   (c) J15/J3 refuse what the declaration cannot express.
    -- The end-to-end shape proof (`=w call` + `extsw` vs `=l call`) is NOT
    -- here: it needs the emitter, and it lives in qbe-check.sh's
    -- `run_midshape` rows for tools/qbe/fixtures/ffiw-{i32,i64}.mid.
    , check "lower cffi U2 i32 RESULT — THE WIDTH FIX: a declared `-> i32` lowers to RawCallExtern with result FW32S (the QBE arm emits `=w call` + `extsw`) and the ARGUMENT widths come from the declaration (ptr -> FW64, i32 -> FW32S)"
        (case lowlModuleBody "extern access(path : ptr, mode : i32) -> i32;\ndefun Rt.g(p : word) -> val {\n  word r = rawcall access(p, 0);\n  return mkbool(r < 0);\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.sym
                            == "access"
                            && c.result
                            == FW32S
                            && c.argWidths
                            == [ FW64, FW32S ]
                            && c.varargs
                            == False

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U2 i64 RESULT — THE CONTROL (the same call, the declared width the only difference): `-> i64` lowers the SAME call with result FW64 and NO extension"
        (case lowlModuleBody "extern access(path : ptr, mode : i32) -> i64;\ndefun Rt.g(p : word) -> val {\n  word r = rawcall access(p, 0);\n  return mkbool(r < 0);\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.result == FW64 && c.argWidths == [ FW64, FW32S ]

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U2 u32 RESULT is its OWN width (FW32U, the `extuw` arm) — not collapsed into i32: the declared width, not the register class, is what the node carries"
        (case lowlModuleBody "extern getuidcount() -> u32;\ndefun Rt.g() -> word {\n  word r = rawcall getuidcount();\n  return r;\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.result == FW32U && c.argWidths == []

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U2 `-> void` lowers to FVoid (the dead `l` temp rawcall free(..) already yields — plan §3.1: a declared void moves no existing shape)"
        (case lowlModuleBody "extern shimv(x : ptr) -> void;\ndefun Rt.g(p : word) -> word {\n  word r = rawcall shimv(p);\n  return r;\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.result == FVoid && c.argWidths == [ FW64 ]

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U2 UNDECLARED rawcall is UNCHANGED: `getpid` (a rawcallArity row, no extern in the file) still lowers to RawCallRaw — the all-word shape the runtime's own seats keep by plan §6"
        (case lowlModuleBody "defun Rt.g() -> word {\n  return rawcall getpid();\n}" of
            Ok (Unsafe (RawCallRaw r)) ->
                r.sym == "getpid"

            _ ->
                False
        )
    , checkErrModule "check cffi U2 J15 R-06 (the duplicate U1 deferred): one symbol declared TWICE is refused — the extern symbol namespace had no owner until this unit" "is declared twice" "extern access(path : ptr) -> i32;\nextern access(path : ptr, mode : i32) -> i64;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check cffi U2 J15 R-07: a symbol that collides with a BUILTIN spelling is refused — the call site would resolve to the builtin, never to the C symbol" "is a BUILTIN" "extern wload(p : ptr) -> i64;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check cffi U2 J15 R-08: a symbol that is ALSO a rawcallArity row is refused — two tables for one symbol is the skew this repo keeps paying for" "is a rawcallArity row" "extern getpid() -> i32;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check cffi U2 J3 R-11: a declared extern's ARITY is at least the declaration's FIXED parameters (2 declared, 1 passed)" "is declared extern with 2 fixed parameter(s), got 1" "extern access(path : ptr, mode : i32) -> i32;\ndefun Rt.g(p : word) -> word {\n  word r = rawcall access(p);\n  return r;\n}"
    , checkErrModule "check cffi U2 J3 R-14/R-16: the DECLARED class is what an argument is checked against — a word at an f64 slot is the existing wording" "needs float, got word" "extern fmodx(x : f64) -> i32;\ndefun Rt.g(p : word) -> word {\n  word r = rawcall fmodx(p);\n  return r;\n}"
    , checkErrModule "check cffi U2 J3 result class: an f64 RESULT is `float`, so binding it to a `word` is the existing word-slot reject (not a silent word read)" "declares word but its initializer is float" "extern fv() -> f64;\ndefun Rt.g() -> word {\n  word r = rawcall fv();\n  return r;\n}"
    , checkOkModule "check cffi U2 ACCEPT (the other side of the row above): a DECLARED f64 result enters a float slot — `mkflt(rawcall fv())` proves the call's class is `float` and not a word"
        "extern fv() -> f64;\ndefun Rt.g() -> val {\n  return mkflt(rawcall fv());\n}"
    -- ================ cffi U4: VARARGS (the `...` marker) ================
    -- U2 REFUSED a call to a `...` extern with a message naming this unit,
    -- because accepting it would have emitted a call with no IL marker — and
    -- QBE derives the vector-register count (%al) from the arguments AFTER the
    -- marker, so the callee's va_start would read whatever the previous code
    -- left in %eax.  The rows below are that refusal MOVED, not deleted: the
    -- same source that was `Err "cffi U4"` is now an accepted call whose node
    -- carries the fixed count, and the three ways a variadic call can still be
    -- wrong (too few, too many on a fixed extern, a float among the extras)
    -- each have their own row.
    , checkOkModule "check cffi U3/U4 ACCEPT: a call to a `...` extern with WORD arguments is accepted (the refusal row that stood here in U2 named this unit)"
        "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g(p : word) -> val {\n  word r = rawcall printfx(p, 1);\n  return mknum(r);\n}"
    , check "lower cffi U4: the node carries the split — `varargs` True, `fixedArgs` 1 (the declaration's own fixed count), and the VARIADIC argument arrives as FW64 (plan §5: v1 admits word-class variadic arguments only)"
        (case lowlModuleBody "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g(p : word) -> word {\n  word r = rawcall printfx(p, 1);\n  return r;\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.varargs
                            == True
                            && c.fixedArgs
                            == 1
                            && c.argWidths
                            == [ FW64, FW64 ]

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U4: a variadic declaration with NO extra arguments keeps `fixedArgs` == the arity and `varargs` True — the marker is still emitted (the callee's va_start reads %al regardless of the count), so this is the case the emitter must not drop"
        (case lowlModuleBody "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g(p : word) -> word {\n  word r = rawcall printfx(p);\n  return r;\n}" of
            Ok body ->
                case ffiCallOfBody body of
                    Just c ->
                        c.varargs == True && c.fixedArgs == 1 && c.argWidths == [ FW64 ]

                    Nothing ->
                        False

            Err _ ->
                False
        )
    , check "lower cffi U4 THE MARKER: the emitted call carries `...` BETWEEN the fixed and the variadic arguments (QBE's IL spelling) and every variadic argument is an `l` word"
        (case emitUserSsa rt "module Ffv\nextern printfx(fmt : ptr, ...) -> i32;\ndefun Ffv.g() -> word {\n  word r = rawcall printfx(rawstr(\"x\"), 1, 2);\n  return r;\n}" of
            Ok ssa ->
                -- the marker sits AFTER the fixed `fmt` argument and EVERY
                -- variadic argument is an `l` word
                String.contains "call $printfx(l $d0, ..., l 1, l 2)" ssa

            Err _ ->
                False
        )
    , checkErrModule "check cffi U4 R-11: a variadic call still needs EVERY fixed parameter (1 fixed, 0 passed) — the `...` does not make the fixed half optional" "is declared extern with 1 fixed parameter(s), got 0" "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g() -> val {\n  word r = rawcall printfx();\n  return mknum(r);\n}"
    , checkErrModule "check cffi U4 R-12: a declaration with NO `...` takes exactly its parameters — one extra argument is refused, not silently passed" "parameter(s) and no '...', got 3" "extern access2(path : ptr, mode : i32) -> i32;\ndefun Rt.g(p : word) -> val {\n  word r = rawcall access2(p, 0, 0);\n  return mknum(r);\n}"
    , checkErrModule "check cffi U4 R-13 THE DELIBERATE HOLE: an `f64` among the variadic arguments is REFUSED in v1, and the message says why (%al is the vector-register count QBE derives from exactly those arguments) and what to do instead" "variadic argument must be word-class in this version" "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g(p : word) -> val {\n  word r = rawcall printfx(p, itof(1));\n  return mknum(r);\n}"
    , checkErrModule "check cffi U4: a `val` among the variadic arguments is refused too — the variadic half is WORD-class, and the message names the class it got rather than the position-only wording" "takes word-class variadic arguments, got val" "extern printfx(fmt : ptr, ...) -> i32;\ndefun Rt.g(p : word, v : val) -> val {\n  word r = rawcall printfx(p, v);\n  return mknum(r);\n}"
    -- These two were the stated U2/U3 seam: U2 refused an f64 OPERAND/RESULT
    -- LOUDLY at the emitter (naming this unit), because a `d` temp in a word
    -- slot is the silent register-class bug.  cffi U3 lifts both — so these
    -- rows now assert the EMITTED shape instead of the refusal, and they are
    -- the asymmetry proof for that seam: the same two sources went from Err to
    -- this .ssa text.
    , check "lower cffi U3 an f64 ARGUMENT emits a `d` operand: the argument is lowered through rawFltArg, so the call carries `d %t` (the float-producer route, plan §3.2) and the checker's TFloat class and the emitter's class are the same function"
        (case emitUserSsa rt "module Ffm\nextern fmodx(x : f64) -> i64;\ndefun Ffm.g() -> word {\n  word r = rawcall fmodx(itof(1));\n  return r;\n}" of
            Ok ssa ->
                String.contains "(d %t" ssa && String.contains "=l call $fmodx(d %t" ssa

            Err _ ->
                False
        )
    , check "lower cffi U3 an f64 RESULT emits `=d call` (no extension: there is nothing to extend) — THE SIXTH CLASSIFICATION SITE now answers 'float producer' instead of the U2 refusal"
        (case emitUserSsa rt "module Ffr\nextern fv() -> f64;\ndefun Ffr.g() -> val {\n  return mkflt(rawcall fv());\n}" of
            Ok ssa ->
                String.contains "=d call $fv()" ssa

            Err _ ->
                False
        )
    , check "lower cffi U3 an f64 result is a FLOAT WORD in a float COMPARE — the classification U3 added (isFloatWordExp/isWordCondNode): `rawcall fv() f> 0.0` lowers to a `d` compare against the call's own `d` temp"
        (case emitUserSsa rt "module Ffrq\nextern fv() -> f64;\ndefun Ffrq.g() -> val {\n  return mkbool(rawcall fv() f> itof(0));\n}" of
            Ok ssa ->
                String.contains "=d call $fv()" ssa && String.contains "cgtd " ssa

            Err _ ->
                False
        )
    , checkErrModule "check cffi U3 R-14 (the other direction): a FLOAT expression at a WORD-class parameter slot is the existing wording — the declared class is what both sides are read against" "needs word, got float" "extern fvy(x : i32) -> i32;\ndefun Rt.g() -> word {\n  word r = rawcall fvy(itof(1));\n  return r;\n}"
    , checkOkModule "check cffi U3 R-09 (ACCEPTED, and the hazard is stated not enforced): a `-> void` extern's result types as the dead WORD, so `word r = rawcall srand(1)` binds it — reading it is undefined data, exactly as `rawcall free(..)` is today"
        "extern srand(seed : u32) -> void;\ndefun Rt.g() -> word {\n  word r = rawcall srand(1);\n  return r;\n}"

    -- ==================== A1: the checker (J11-J14, the U1 reject arms become real checks) ====================
    -- Each positive row parses a MODULE (decls + defuns) and runs Check.checkModule;
    -- each negative row pins the judgment's message fragment, so a parse failure
    -- (which has no fragment) cannot pass the row vacuously.

    -- J13 field/index/deref: the accepted forms
    , checkOkModule "check A1: field access yields the FIELD's class (a word field reads as word)"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  return p->f;\n}"
    , checkOkModule "check A1: a val field reads as val (the field class, not a word)"
        "struct S { vf : val; }\ndefun Rt.g(p: *S) -> val {\n  return p->vf;\n}"
    , checkOkModule "check A1: index access on *word reads a word (the wload stride)"
        "defun Rt.g(p: *word) -> word {\n  return p[0];\n}"
    , checkOkModule "check A1: index access on *val reads a val (the vecload stride)"
        "defun Rt.g(p: *val) -> val {\n  return p[0];\n}"
    , checkOkModule "check A1: index access on *S reads the word at the struct-scaled element base"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  return p[1];\n}"
    , checkOkModule "check A1: deref *p is *word only, yielding word"
        "defun Rt.g(p: *word) -> word {\n  return *p;\n}"
    , checkOkModule "check A1: index store on *word (wstore shape)"
        "defun Rt.g(p: *word) -> word {\n  p[0] = 1;\n  return 0;\n}"
    , checkOkModule "check A1: index store on *val (vecstore shape)"
        "defun Rt.g(p: *val, v: val) -> val {\n  p[0] = v;\n  return v;\n}"
    , checkOkModule "check A1: field store of a word into a word field"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  p->f = 1;\n  return 0;\n}"
    , checkOkModule "check A1: field store of a val into a val field"
        "struct S { vf : val; }\ndefun Rt.g(p: *S, v: val) -> val {\n  p->vf = v;\n  return v;\n}"
    , checkOkModule "check A1: a chained field-then-index a->tab[i] composes"
        "struct S { tab : *word; }\ndefun Rt.g(p: *S) -> word {\n  return p->tab[0];\n}"

    -- J12: the one-way coercion matrix — the accepted directions
    , checkOkModule "check A1 coercion: word -> *T at a typed binder (the view-cast)"
        "struct S { f : word; }\ndefun Rt.g(v: val) -> word {\n  *S p = payload(v, 0);\n  return p->f;\n}"
    , checkOkModule "check A1 coercion: *T -> word at a typed binder (a pointer is a word)"
        "struct S { f : word; }\ndefun Rt.g(v: val) -> word {\n  *S p = payload(v, 0);\n  word w = p;\n  return w;\n}"
    , checkOkModule "check A1 coercion: *S -> *word (the universal raw view)"
        "struct S { f : word; }\ndefun Rt.g(v: val) -> word {\n  *S p = payload(v, 0);\n  *word w = p;\n  return w[0];\n}"
    , checkOkModule "check A1 coercion: pointer comparison p == 0 / p != 0 is address comparison"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> val {\n  return mkbool(p == 0);\n}"

    -- J11/J14: accepted declarations
    , checkOkModule "check A1: self-reference BY POINTER (*S) is legal (the only recursion)"
        "struct Hdr { flags : word; next : *Hdr; }\ndefun Rt.g(h: *Hdr) -> word {\n  return h->flags;\n}"
    , checkOkModule "check A1: a forward struct pointer reference resolves order-independently"
        "struct A { b : *B; }\nstruct B { x : word; }\ndefun Rt.g(a: *A) -> word {\n  return a->b->x;\n}"
    , checkOkModule "check A1: an enum declaration builds its table (no use site yet)"
        "enum RootKind { ptr = 0; value = 1; }\ndefun Rt.g() -> word {\n  return 0;\n}"

    -- the named rejections, each pinning the judgment fragment
    , checkErrModule "check A1 reject: a val into a WORD FIELD is a J13 reject" "needs word, got val"
        "struct S { f : word; }\ndefun Rt.g(v: val) -> word {\n  *S p = 0;\n  p->f = v;\n  return 0;\n}"
    , checkErrModule "check A1 reject: a val READ AS A WORD (a val field into a word binder) is a J1 reject" "initializer is val"
        "struct S { vf : val; }\ndefun Rt.g(p: *S) -> word {\n  word x = p->vf;\n  return x;\n}"
    , checkErrModule "check A1 reject: *S pointer arithmetic (p + 1 — the off-by-one firewall) is a J12 reject" "J12: pointer arithmetic"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  return p + 1;\n}"
    , checkErrModule "check A1 reject: a float struct field is a J11 reject (no raw f64 load node)" "float field"
        "struct S { f : float; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check A1 reject (REWRITTEN by B2): a self-by-value struct is an INFINITE-SIZE reject — it used to be structurally unspellable (a bare-name field was a parse reject, 'expected a type'); B2's TStruct type makes it spellable, so the judgment moves to the layout table where the A1 note reserved it" "contains itself BY VALUE"
        "struct S { next : S; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check A1 reject: an unknown field is a J13 reject" "has no field"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  return p->g;\n}"
    , checkErrModule "check A1 reject: an unknown struct (a *Region binder with no decl) is a J11 reject" "names no declared struct"
        "defun Rt.g(v: val) -> word {\n  *Region p = payload(v, 0);\n  return 0;\n}"
    , checkErrModule "check A1 reject: cross-struct cast *A -> *B is a J12 reject (go through a word binder)" "declares *B"
        "struct A { x : word; }\nstruct B { y : word; }\ndefun Rt.g(a: *A) -> word {\n  *B b = a;\n  return b->y;\n}"
    , checkErrModule "check A1 reject: *word -> *S is a J12 reject (go through a word binder)" "declares *S"
        "struct S { f : word; }\ndefun Rt.g(w: *word) -> word {\n  *S s = w;\n  return 0;\n}"
    , checkErrModule "check A1 reject: *val -> *S is a J12 reject (go through a word binder)" "declares *S"
        "struct S { f : word; }\ndefun Rt.g(v: *val) -> word {\n  *S s = v;\n  return 0;\n}"
    , checkErrModule "check A1 reject: a word into a VAL slot (index store on *val) is a J13 reject" "needs val, got word"
        "defun Rt.g(p: *val) -> val {\n  p[0] = 1;\n  return mknil;\n}"
    , checkErrModule "check A1 reject: a word into a VAL FIELD is a J13 reject" "needs val, got word"
        "struct S { vf : val; }\ndefun Rt.g(p: *S) -> word {\n  p->vf = 1;\n  return 0;\n}"
    , checkErrModule "check A1 reject: deref on a *S is a J13 reject (*p is *word only)" "deref '*p' is '*word' only"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  return *p;\n}"
    , checkErrModule "check A1 reject: bare if(p) on a pointer is a J1 reject (write the compare inline)" "must be val or word"
        "struct S { f : word; }\ndefun Rt.g(p: *S) -> word {\n  if (p) { return 1; } else { return 0; }\n}"
    , checkErrModule "check A1 reject: field access on a *word is a J13 reject (needs a struct pointer)" "field access needs a struct pointer"
        "defun Rt.g(p: *word) -> word {\n  return p->f;\n}"
    , checkErrModule "check A1 reject: a val index (p[v]) is a J13 reject (the index is a word offset)" "index must be a word"
        "defun Rt.g(p: *word, v: val) -> word {\n  return p[v];\n}"
    , checkErrModule "check A1 reject: a duplicate struct name is a J11 reject (one file-scoped namespace)" "declared more than once"
        "struct S { f : word; }\nstruct S { g : word; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check A1 reject: a struct/enum name collision is a J11/J14 reject" "declared more than once"
        "struct S { f : word; }\nenum S { A = 0; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check A1 reject: a duplicate field name is a J11 reject" "more than once"
        "struct S { f : word; f : word; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "check A1 reject: a duplicate enum constant is a J14 reject" "more than once"
        "enum E { A = 0; A = 1; }\ndefun Rt.g() -> word {\n  return 0;\n}"

    -- LAYOUT pins: sizes and offsets computed from the table, against runtime.mid's actuals
    -- (gcInit writes the region's words 0..12 with a hole at word 7; frame-enter writes
    -- hdr words 0..3 of the 40-byte = 5-word header, base = hdr + 40).
    , check "A1 layout: sizeof(Region) == 13 words (the gcInit wstore offsets 0..12 + the word-7 pad hole)"
        (Check.sizeofStruct
            (declsOf "struct Region { magic : word; classTab : *word; heapStart : word; cursor : word; heapEnd : word; markTop : word; markEnd : word; _pad : word; kind : word; count : word; heapBytes : word; allocated : word; numClass : word; }")
            "Region"
            == Just 13
        )
    , check "A1 layout: sizeof(FrameHdr) == 5 words (frameBlock's 40-byte header: live/wm/next/freeNext/slot-word 4 — the names runtime.mid's own `struct FrameHdr` uses since U6, where word 4 is the `_pad` hole)"
        (Check.sizeofStruct
            (declsOf "struct FrameHdr { live : word; wm : word; next : word; freeNext : word; _pad : word; }")
            "FrameHdr"
            == Just 5
        )
    , check "A1 layout: Region._pad is at BYTE 56 (word 7) and Region.numClass at byte 96 (word 12) — cffi U6 made the table byte-granular; the word slots are unchanged, and the pad hole does not shift later fields"
        (Check.fieldOffset
            (declsOf "struct Region { magic : word; classTab : *word; heapStart : word; cursor : word; heapEnd : word; markTop : word; markEnd : word; _pad : word; kind : word; count : word; heapBytes : word; allocated : word; numClass : word; }")
            "Region"
            "_pad"
            == Just 56
            && Check.fieldOffset
                (declsOf "struct Region { magic : word; classTab : *word; heapStart : word; cursor : word; heapEnd : word; markTop : word; markEnd : word; _pad : word; kind : word; count : word; heapBytes : word; allocated : word; numClass : word; }")
                "Region"
                "numClass"
            == Just 96
        )
    , check "A1 layout: a val field is 5 words inline (one val field sizes the struct at 5)"
        (Check.sizeofStruct (declsOf "struct V { v : val; }") "V" == Just 5)

    -- ==================== U5: runtime.mid's REGION layout (midlang-u5) ====================
    -- The pins above check the LAYOUT TABLE on a copy of the declaration.  These
    -- read runtime.mid's OWN `struct Region` — the declaration the collector's
    -- `region->f` accesses resolve against — so a reordered/renamed/padded field
    -- in the runtime fails HERE and not as wrong output.  The expected numbers
    -- are the word slots the code spelled as `wstore(base, k, ..)` /
    -- `wload(regionW, k)` BEFORE the re-spelling: the migration is only sound if
    -- every name still lands on the slot that code used (the pre-U5 emission is
    -- the independent record of the mapping, and the corpus gate holds the
    -- accesses to it).  MEASURED: slot 7 was a HOLE — nothing in the runtime or
    -- in tools/qbe/hostshim.zig read or wrote region word 7 — which is why it
    -- was a named `_pad`; GC ARC unit 1b gave that hole its first tenant
    -- (`noreuse`, the QBE_MIDGC_NOREUSE flag, set once by Rt.gcInit), so the
    -- hole did its job: slots 8..12 did not shift.
    , check "U5 LAYOUT PIN: runtime.mid's own `struct Region` puts every field at the word slot the collector used before the re-spelling (magic 0, classTab 1, heapStart 2, cursor 3, heapEnd 4, markTop 5, markEnd 6, noreuse 7, kind 8, count 9, heapBytes 10, allocated 11, numClass 12)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "magic", "classTab", "heapStart", "cursor", "heapEnd", "markTop", "markEnd", "noreuse", "kind", "count", "heapBytes", "allocated", "numClass", "ts0s", "ts0n", "ts1s", "ts1n", "ts2s", "ts2n", "collects", "marked", "sweptBytes", "markUs", "sweepUs", "capEnd", "bmPtr", "freedN", "verify", "young", "youngStart", "youngEnd", "youngCursor", "rsBase", "rsTop", "rsEnd", "scavenges", "scavBytes", "scavBodies" ]
         in
         List.map (\n -> Check.fieldOffset d "Region" n) names == List.map Just (byteSlots 38)
        )
    , check "U5 LAYOUT PIN: sizeof(Region) == 38 words in runtime.mid's own declaration (slots 0..12 + GC-ARC F1's stats instrument at 13..23 + GC ARC unit 4's growth ceiling at 24 + GC ARC unit 2's block map at 25..27 + GC NURSERY's young/remembered-set family at 28..37 + GC NURSERY's young/remembered-set family at 28..37 — the mark stack starts at word 64, so it is NOT a field, and the digit scratch the printer writes into is at BYTE 320, outside the struct)"
        (Check.sizeofStruct (declsOf runtimeMidText) "Region" == Just 38)
    -- ==================== GC NURSERY: the hatch's own pins ====================
    -- The young defuns live ONLY inside the QBE_MIDGC_YOUNG-ONLY splice region
    -- (run.js drops them unless the build flag is set), so a young key leaking
    -- into an ALWAYS-PRESENT rtDeps row would drag an absent defun into a
    -- plain MIDGC build's seed closure and Lower would die "unknown global" —
    -- the loud end of the rule; the pin makes the rule itself a test.
    , check "NURSERY PIN: the QBE_MIDGC_YOUNG-ONLY region of runtime.mid holds EXACTLY the twelve nursery defuns (the eleven scavenge-family ones + zighost Z2's Rt.vecStoreYoung, the write barrier's record half (balanced markers, every young defun inside, no young defun outside)"
        (let
            youngKeys =
                [ "Rt.gcScavenge", "Rt.gcScavRoots", "Rt.gcScavValue", "Rt.gcScavValueArray", "Rt.gcScavValuesTab", "Rt.gcScavPtr", "Rt.gcScavCopyWords", "Rt.gcScavRemembered", "Rt.gcScavOne", "Rt.gcScavDrain", "Rt.gcPromoteAlloc", "Rt.vecStoreYoung" ]

            countInside ls =
                List.foldl
                    (\line ( inside, defuns ) ->
                        if String.contains "// >>> QBE_MIDGC_YOUNG-ONLY" line then
                            ( True, defuns )

                        else if String.contains "// <<< QBE_MIDGC_YOUNG-ONLY" line then
                            ( False, defuns )

                        else if inside && String.startsWith "defun " line then
                            ( inside, defuns + 1 )

                        else
                            ( inside, defuns )
                    )
                    ( False, 0 )
                    lines

            lines =
                String.split "\n" runtimeMidText

            ( _, insideN ) =
                countInside lines

            -- the text with the young region's BODY removed: a young defun
            -- leaking OUTSIDE the region fails the name scan below
            outside =
                List.foldl
                    (\line ( inside, acc ) ->
                        if String.contains "// >>> QBE_MIDGC_YOUNG-ONLY" line then
                            ( True, acc )

                        else if String.contains "// <<< QBE_MIDGC_YOUNG-ONLY" line then
                            ( False, acc )

                        else if inside then
                            ( inside, acc )

                        else
                            ( inside, acc ++ [ line ] )
                    )
                    ( False, [] )
                    lines
                    |> Tuple.second
         in
         (insideN == 12)
            && List.all
                (\k -> not (String.contains ("defun " ++ k) (String.join "\n" outside)))
                youngKeys
            && List.all
                (\k -> String.contains ("defun " ++ k) runtimeMidText)
                youngKeys
        )
    , check "NURSERY PIN (the register-class landmine, the stage-A drain bug): the young region's FORWARDED test is a COMPARE (`flags > ((2147483648 * 2147483648) - 1)`) and the RS test is a DIVISION — never a word `&` with a constant >= 2^32, because a word `&` in this surface lowers to a w-CLASS (32-bit) and whose result TRUNCATES both operands: `flags & 2^62` was identically ZERO, the forwarding test never fired, every forwarded body was re-copied, and the drain read the re-copy's word -1 (an ADDRESS) as its scan count (MEASURED: valchurn's rooted arm died at the poison detector; post-fix it prints 10001).  The masked CLASS reads are exempt: classes live in bits 2..21 and the truncation keeps bits 0..31, so the masked read is exact for every class a heap can name."
        (let
            young =
                -- the text of the QBE_MIDGC_YOUNG-ONLY regions (may be empty
                -- in a spliced copy; the row reads the RAW file text)
                runtimeMidText
         in
         String.contains "if (mkbool(flags > ((2147483648 * 2147483648) - 1))) {" young
            && String.contains "mkbool((flags / (1073741824 * 2147483648)) == 1)" young
            -- the BROKEN spellings, as tests: an `&`-with-big-constant whose
            -- result is COMPARED (the w-class and is fine only as the masked
            -- class read, whose result feeds a shift-free arithmetic consumer)
            && not (String.contains "& (2147483648 * 2147483648)) != 0" young)
            && not (String.contains "& ((1073741824 * 2147483648)) != 0" young)
        )
    , check "NURSERY PIN (the write barrier's SEAM, re-pinned at zighost Z2): a surface vecstore lowers to the MID seat q_Rt_x2evecStoreYoung in a young build and to q_Rt_x2evecStorePlain otherwise — THREE words each (vec, index, *Value), the callee loading the region from rt_glob_addr ITSELF, so the CALLER fetches nothing (the deleted Zig seat took the region as a 4th argument because hostshim could not name the block; Mid reads it directly) — and the two deleted Zig seats are named by nothing on either route.  The Z0-retired third combo (the old collector's rt_vec_store) is gone with the flag that selected it"
        (let
            probeY =
                z2Probe rt True True

            probeP =
                z2Probe rt True False

            youngCall =
                z2Line "call $q_Rt_x2evecStoreYoung(" probeY

            plainCall =
                z2Line "call $q_Rt_x2evecStorePlain(" probeP
         in
         String.contains "call $q_Rt_x2evecStoreYoung(l " youngCall
            && String.contains "call $q_Rt_x2evecStorePlain(l " plainCall
            -- three arguments: the first has no leading comma, the other two do
            && List.length (String.indexes ", l " youngCall) == 2
            && List.length (String.indexes ", l " plainCall) == 2
            && not (String.contains "call $q_Rt_x2evecStorePlain(" probeY)
            && not (String.contains "call $q_Rt_x2evecStoreYoung(" probeP)
            -- NO REGION FETCH IN THE CALLER.  `export function l $rt_glob_addr()`
            -- is emitted unconditionally by finishModule (stage 6 B0), so the
            -- assertion is on the CALL, which only the seam ever made.
            && not (String.contains "call $rt_glob_addr" probeY)
            && not (String.contains "call $rt_glob_addr" probeP)
            && not (String.contains "rt_vec_store" probeY)
            && not (String.contains "rt_vec_store" probeP)
        )
    , check "Z2 SEAM PIN (the barrier's MASK SAFETY, the stage-A drain bug's spelling): Rt.vecStoreYoung tests the RS bit by DIVISION (flags / 2^61) and SETS it by ADDING the same product — never `&`, which lowers to a w-class op and truncates bit 61 away (the measured bug: `flags & 2^62` was identically ZERO, the forwarding test never fired, every forwarded body was re-copied); and the tag read is a zero-EXTEND (uext), not a mask.  The negatives are the fail-before half: either big-constant `&` spelling in this defun is RED"
        (let
            body =
                defunText "Rt.vecStoreYoung" runtimeMidText
         in
         String.contains "(flags / (1073741824 * 2147483648)) == 0" body
            && String.contains "flags + (1073741824 * 2147483648)" body
            && String.contains "uext(wload(val, 0))" body
            && not (String.contains "& (1073741824 * 2147483648)" body)
            && not (String.contains "& (2147483648 * 2147483648)" body)
            -- the defun is where the policy lives, not a stub
            && String.contains "region->rsBase" body
            && String.contains "region->rsTop" body
        )
    , check "NURSERY PIN (promote bumps before it grows): Rt.gcPromoteAlloc's bump arm precedes its growth ladder — the stage-A bug was a promote path that ran the ladder UNCONDITIONALLY (every free-list miss doubled the limit even with the cursor at offset 0, the startup grow-to-the-ceiling; reserve-only, but still wrong)"
        (case List.head (String.indexes "defun Rt.gcPromoteAlloc" runtimeMidText) of
            Nothing ->
                False

            Just i ->
                let
                    seg =
                        String.slice i (i + 2200) runtimeMidText

                    b =
                        List.head (String.indexes "BUMP FIRST" seg)

                    l =
                        List.head (String.indexes "word needLim = (cursor + phys * 8) - heapStart;" seg)
                in
                case ( b, l ) of
                    ( Just bb, Just ll ) ->
                        bb < ll

                    _ ->
                        False
        )    , check "O5 PIN (the string-stream registry): Rt.open's ENOENT arm / Rt.read-byte's string arm / Rt.close's string arm call the MID registry (Rt.ssIn/ssReadbyte/ssClose), no rawcall rt_ss_* seat remains, and rawcallArity carries no rt_ss_* row (the fail-before: pre-O5 this row fails on the rawcall + the rawcallArity row)"
        (String.contains "call Rt.ssIn(mknum(bufW)" (defunText "Rt.open" runtimeMidText)
            && String.contains "call Rt.ssReadbyte(mknum(i))" (defunText "Rt.read-byte" runtimeMidText)
            && String.contains "call Rt.ssClose(mknum(payload(stream, 0)))" (defunText "Rt.close" runtimeMidText)
            && not (String.contains "rawcall rt_ss_" runtimeMidText)
            && List.all (\k -> not (Dict.member k Ast.rawcallArity)) [ "rt_ss_in", "rt_ss_readbyte", "rt_ss_close" ]
        )
    , check "NURSERY PIN (the seeding discipline): no ALWAYS-PRESENT rtDeps row names a young-only key — a plain MIDGC build closes gcSeeds over those rows, and an absent key is Lower's loud 'unknown global'"
        (let
            youngKeys =
                [ "Rt.gcScavenge", "Rt.gcScavRoots", "Rt.gcScavValue", "Rt.gcScavValueArray", "Rt.gcScavValuesTab", "Rt.gcScavPtr", "Rt.gcScavCopyWords", "Rt.gcScavRemembered", "Rt.gcScavOne", "Rt.gcScavDrain", "Rt.gcPromoteAlloc", "Rt.vecStoreYoung" ]
         in
         Dict.toList Rt.rtDeps
            |> List.all
                (\( from, deps ) ->
                    if List.member from youngKeys then
                        True

                    else
                        List.all (\d -> not (List.member d youngKeys)) deps
                )
        )
    -- ==================== THE RETURN-FLIP (was: the RETURN LANDMINE) ====================
    -- `return` inside a STATEMENT-position `if` now EXITS.  Until the
    -- return-flip unit it did not: the lowerer's `thenDiv && elseDiv` arm
    -- evaluated the chosen arm's value, bound the whole `If` to a fresh binder
    -- nothing read, and CONTINUED — so `if (c) { return a; } else { return b; }`
    -- ran the rest of the block whatever `c` was, which is a silent-wrong for
    -- every program that meant the return.  Stage 1 migrated the 69 runtime.mid
    -- sites that depended on the fall-through (see the SPELLING rows above);
    -- stage 2 changed the arm, and the rows below pin the new shape.
    --
    -- The emitted code is UNCHANGED on this tree (corpus 159/159 byte-identical
    -- before and after the flip) BECAUSE the migration came first — that is the
    -- point of doing it in two stages, and the shape that made it necessary is
    -- exactly the shape the first row below now REJECTS.
    , check "THE FLIP: a both-diverging statement `if` EXITS — `if (c) { return 1; } else { return 2; } return 7;` lowers to the `If` ITSELF (`If c (1) (2)`), and the `7` is not in the tree at all because the rest of the block is unreachable from both arms (it used to dead-bind the If and return 7 whatever `c` was: the GC1b landmine)"
        (case
            lowlModuleBody "defun Rt.t(d : val) -> val {\n  if (mkbool(1)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n  return mknum(7);\n}"
         of
            Ok e ->
                canon e
                    == canon
                        (liff (lmkBool (ltn 1))
                            (lmkNum (ltn 1))
                            (lmkNum (ltn 2))
                        )

            Err _ ->
                False
        )
    , check "GC1b EARLY-EXIT PIN (the shape that DOES exit): a ONE-SIDED diverging `if` splices the continuation into its FALSE path — `if (c) { return 1; } return 7;` lowers to `If c (1) (7)`, so the then arm's value IS the body's value and nothing dead-binds"
        (case
            lowlModuleBody "defun Rt.t(d : val) -> val {\n  if (mkbool(1)) {\n    return mknum(1);\n  }\n  return mknum(7);\n}"
         of
            Ok e ->
                case e of
                    If { thenBranch, elseBranch } ->
                        numLit 1 thenBranch && numLit 7 elseBranch

                    _ ->
                        False

            _ ->
                False
        )
    -- ==================== THE `return`-inside-`if` FLIP: THE THREE SPELLINGS ====================
    -- Stage 1 of the return-flip unit migrated EVERY statement-position `if` in
    -- runtime.mid whose BOTH branches `return` (69 sites, 19 defuns) out of the
    -- dead-bind shape, because that shape is what a `return`-that-exits flips.
    -- Three spellings carry the migration, and each has a row HERE so a later
    -- change to the lowering cannot rot one silently.  They are not decoration:
    -- all three are live in runtime.mid (spelling 1 in 333 sites, spelling 2 in
    -- the 69 migrated ones, spelling 3 in Rt.gcMarkRoots' four-way dispatch).
    , check "SPELLING 1 (one-sided guard): the guard's work lives in the then arm and the CONTINUATION lands in the FALSE path, so the guard is a real early exit and nothing dead-binds — `if (c) { word h = rawcall rt_halt(); return 1; } return 7;` lowers to `If c (let h = rt_halt() in 1) (7)`"
        (case
            lowlModuleBody "defun Rt.t(d : val) -> val {\n  if (mkbool(1)) {\n    word h = rawcall rt_halt();\n    return mknum(1);\n  }\n  return mknum(7);\n}"
         of
            Ok e ->
                case e of
                    If { thenBranch, elseBranch } ->
                        (case thenBranch of
                            Let { body } ->
                                numLit 1 body

                            _ ->
                                False
                        )
                            && numLit 7 elseBranch

                    _ ->
                        False

            _ ->
                False
        )
    , check "SPELLING 2 (conditional VALUE — the migration's form): `val u = if (c) { A; return x; } else { B; return y; }` puts the same If in a DECLARATION, where `return` is the BRANCH's value by L3 — so the statement means what the dead-bind meant (run one arm for its effects, then carry on) under EITHER reading of a statement `return`.  The tree is the LANDMINE PIN's tree: `Let u = If c x y in 7`"
        (case
            lowlModuleBody "defun Rt.t(d : val) -> val {\n  val u = if (mkbool(1)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  };\n  return mknum(7);\n}"
         of
            Ok e ->
                case e of
                    Let { binders, body } ->
                        case binders of
                            [ LetBind b ] ->
                                (b.binder.name == "u")
                                    && (case b.value of
                                            If _ ->
                                                numLit 7 body

                                            _ ->
                                                False
                                       )

                            _ ->
                                False

                    _ ->
                        False

            _ ->
                False
        )
    , check "SPELLING 3 (dispatch chain + TAIL CALLS): each arm does its work and tail-calls the next dispatcher, so the chain needs no dead bind and no join — the Rt.gcMarkRoots shape, here as `if (a) { work; return call Rt.t(n); } if (b) { work; return call Rt.t(n); } return mknil;` folding into nested Ifs whose then arms END in a self-call"
        (case
            lowlModuleBody "defun Rt.t(d : val) -> val {\n  if (mkbool(tagis(d, 1) == 1)) {\n    word z = payload(d, 0);\n    return call Rt.t(mknum(z));\n  }\n  if (mkbool(tagis(d, 2) == 1)) {\n    word z = payload(d, 0);\n    return call Rt.t(mknum(z));\n  }\n  return mknil;\n}"
         of
            Ok e ->
                case e of
                    If { thenBranch, elseBranch } ->
                        tailSelfCall "Rt.t" thenBranch
                            && (case elseBranch of
                                    If inner ->
                                        tailSelfCall "Rt.t" inner.thenBranch

                                    _ ->
                                        False
                               )

                    _ ->
                        False

            _ ->
                False
        )
    , check "SPELLING 2 INVENTORY (the migration is present and complete): runtime.mid carries 69 `val _uN = if` declarations — the re-derived count of statement-position ifs whose BOTH branches `return` (24 in the 4 sites whose continuation halts / 45 in the 15 whose continuation does work, counted by the LOWERER's own both-diverge arm and by an independent parser scan, which agree at 69/69 per defun).  A site reverted to the bare form drops this count"
        (List.length (List.filter isMigratedSite (String.split "\n" runtimeMidText)) == 69)
    , check "U5 ACCEPT: the collector's `*Region` binder is the typed VIEW over the word it already held — `*Region r = payload(v, 0); r->cursor` loads the same node as `word r = payload(v, 0); wload(r, 3)`, and `wload(r, <computed>)` (the mark stack) still type-checks on the POINTER, which is what lets tier (i) convert only the constant-offset sites"
        (case
            ( lowlModuleBody "struct R { a : word; b : word; c : word; d : word; }\ndefun Rt.a(v : val, i : word) -> word {\n  *R r = payload(v, 0);\n  return r->d + wload(r, i);\n}"
            , lowlBody "defun Rt.a(v : val, i : word) -> word {\n  word r = payload(v, 0);\n  return wload(r, 3) + wload(r, i);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )

    -- ==================== U6: runtime.mid's FRAME HEADER layout (midlang-u6) ====================
    -- The same pair of pins as U5, for the frame family: read runtime.mid's OWN
    -- `struct FrameHdr` — the declaration frameBlock/frame-enter/frame-leave's
    -- `h->f` / `hdr->f` accesses resolve against — so a reordered, renamed or
    -- re-padded field fails HERE instead of as a wrong frame header.  The
    -- expected numbers are the word slots the code spelled as `wload(hdr, k)` /
    -- `wstore(hdr, k, v)` BEFORE the re-spelling (the pre-U6 emission is the
    -- independent record of the mapping, and the corpus gate holds the accesses
    -- to it).  Slot 4 is a HOLE for the frame path: it is the rt.zig `slots`
    -- pointer field, which neither shape writes (P1e dropped the counter
    -- seeding with the zero loop), hence `_pad` — the same choice U5 made for
    -- region word 7.
    , check "U6 LAYOUT PIN: runtime.mid's own `struct FrameHdr` puts every field at the word slot the frame family used before the re-spelling (live 0, wm 1, next 2, freeNext 3, _pad 4)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "live", "wm", "next", "freeNext", "_pad" ]
         in
         List.map (\n -> Check.fieldOffset d "FrameHdr" n) names == List.map Just (byteSlots 5)
        )
    , check "U6 LAYOUT PIN: sizeof(FrameHdr) == 5 words in runtime.mid's own declaration — the 40 bytes frameBlock computes (40 + 40*nslots) and frame-enter adds to reach the slots (base = hdr + 40).  The SLOTS are not a field (variable count, computed offsets); if one ever became one, this row and every `base` row go RED together"
        (Check.sizeofStruct (declsOf runtimeMidText) "FrameHdr" == Just 5)

    -- ==================== cffi U5: runtime.mid's C FFI boundary ====================
    -- The MIGRATION as a checked artifact, not as text.  Three things this row
    -- can see that no grep can: (a) the result WIDTH of each declaration (a
    -- dropped `-> i32` on `openat` puts the site back on the all-word read,
    -- plan §7.1's silent class); (b) the count, so an extern silently
    -- disappearing from the block is RED rather than "fewer rows than before";
    -- (c) DISJOINTNESS with `Ast.rawcallArity` — the state R-08 refuses, stated
    -- here so the failure names the symbol instead of "runtime.mid did not
    -- load".  Deliberately NOT a pin on the emitted bytes: the corpus gate
    -- holds those, and a site moving is a different claim (the STRUCTURAL
    -- oracle in the unit's report is the emitted `=w call` + `extsw` shape).
    , check "cffi U5 (+ stage 7B's poll, stage 7E's getdents64/fstatat, O5 seat 4b's strtod/strtoll): runtime.mid declares its migrated libc surface with the C prototypes' RESULT widths, and no declared symbol is also a rawcallArity row"
        (let
            decls =
                declsOf runtimeMidText

            externs =
                List.filterMap
                    (\d ->
                        case d of
                            Ast.ExternDecl e ->
                                Just ( e.name, e.sig.result )

                            _ ->
                                Nothing
                    )
                    decls

            has name want =
                case List.filter (\( n, _ ) -> n == name) externs of
                    [ ( _, got ) ] ->
                        got == want

                    _ ->
                        False
         in
         List.length externs
            == 33
            && has "fcntl" Ast.FI32
            && has "getrlimit" Ast.FI32
            && has "setrlimit" Ast.FI32
            && has "openat" Ast.FI32
            && has "waitpid" Ast.FI32
            && has "closedir" Ast.FI32
            && has "fork" Ast.FI32
            && has "__errno_location" Ast.FPtr
            && has "readdir" Ast.FPtr
            && has "getcwd" Ast.FPtr
            && has "read" Ast.FI64
            && has "lseek" Ast.FI64
            && has "memset" Ast.FPtr
            && has "poll" Ast.FI32
            && has "getdents64" Ast.FI32
            && has "fstatat" Ast.FI32
            && has "_exit" Ast.FVoid
            && has "strtod" Ast.FF64
            && has "strtoll" Ast.FI64
            && has "strfromd" Ast.FI32
            && List.all
                (\d ->
                    case d of
                        Ast.ExternDecl e ->
                            not (Dict.member e.name Ast.rawcallArity)

                        _ ->
                            True
                )
                decls
        )
    , check "U6 ACCEPT: the header's byte math stays WORD math — `*FrameHdr hdr = payload(v, 0); word base = [word](hdr) + 40;` (the tier-(i) spelling: the pointer binder IS the header view, the `[word]` cast — J12's `*T -> word` view row — is the identity node) lowers canon-EQUAL to the word-spelled `word hdr = ...; word base = hdr + 40;`, so `base`/memset/Rt.rootPushValueArray keep the pre-U6 emission"
        (case
            ( lowlModuleBody "struct FrameHdr { live : word; wm : word; next : word; freeNext : word; _pad : word; }\ndefun Rt.e(v : val) -> word {\n  *FrameHdr hdr = payload(v, 0);\n  word base = [word](hdr) + 40;\n  return base;\n}"
            , lowlBody "defun Rt.e(v : val) -> word {\n  word hdr = payload(v, 0);\n  word base = hdr + 40;\n  return base;\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )
    , check "U6 ACCEPT: the frame-leave shape type-checks on the POINTER — `h == 0` (pointer COMPARISON is address comparison, so no scaling and no J12 firewall), the `h->next` / `h->wm` / `h->live` loads, the FIELD STORE `h->freeNext = wload(g, 16 + n)`, and `h` itself at a builtin WORD slot (`wstore(g, 16 + n, h)`, `*T -> word`) — all the same nodes as the wload/wstore spelling"
        (case
            ( lowlModuleBody "struct FrameHdr { live : word; wm : word; next : word; freeNext : word; _pad : word; }\ndefun Rt.l(v : val, g : word) -> word {\n  *FrameHdr h = payload(v, 0);\n  word bad = if (h == 0) { return 0; } else { return 0; };\n  wstore(g, 1, h->next);\n  rawcall free(h->wm);\n  word n = h->live;\n  h->freeNext = wload(g, 16 + n);\n  wstore(g, 16 + n, h);\n  return n;\n}"
            , lowlBody "defun Rt.l(v : val, g : word) -> word {\n  word h = payload(v, 0);\n  word bad = if (h == 0) { return 0; } else { return 0; };\n  wstore(g, 1, wload(h, 2));\n  rawcall free(wload(h, 1));\n  word n = wload(h, 0);\n  wstore(h, 3, wload(g, 16 + n));\n  wstore(g, 16 + n, h);\n  return n;\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )

    -- ==================== U7: runtime.mid's APPLY STATE + `:ret` layouts (midlang-u7) ====================
    -- The same pins as U5/U6, for the two blocks the apply/tail family passes
    -- around: read runtime.mid's OWN `struct ApplyState` / `struct Ret` — the
    -- declarations the `sp->f` / `state->f` / `retbuf->f` accesses resolve
    -- against — so a reordered, renamed or re-padded field fails HERE instead of
    -- as a wrong `:ret` offset.  The expected numbers are the word slots the
    -- code spelled as `wload(sp, k)` / `wstore(retbuf, k, v)` BEFORE the
    -- re-spelling (the pre-U7 emission is the independent record of the mapping,
    -- and the corpus gate holds the accesses to it).
    --
    -- WHY THIS BLOCK NEEDS THE PIN MORE THAN THE OTHER TWO: `struct Ret` is an
    -- ABI in three directions (the builder here, Rt.bounceGo, and Lower's @ret
    -- blit that moves all 80 bytes), and a swap of two same-typed words there
    -- emits the SAME instruction SHAPE — the mutual-tail run would then chase a
    -- code pointer read out of the wrong slot.  The round-trip is pinned here so
    -- the failure is a red row, not a segfault.
    , check "U7 LAYOUT PIN: runtime.mid's own `struct ApplyState` puts every field at the word slot the apply family used before the re-spelling (args 0, nargs 1, live 2, env 3)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "args", "nargs", "live", "env" ]
         in
         List.map (\n -> Check.fieldOffset d "ApplyState" n) names == List.map Just (byteSlots 4)
        )
    , check "U7 LAYOUT PIN: sizeof(ApplyState) == 4 words in runtime.mid's own declaration — the 32 bytes both wrappers malloc, with Rt.rootPushValueArray's `np` pointer at word 2 (`[word](state) + 16`) and the partial arm's rooted env at word 3 (`[word](sp) + 24`)"
        (Check.sizeofStruct (declsOf runtimeMidText) "ApplyState" == Just 4)
    , check "U7 LAYOUT PIN: runtime.mid's own `struct Ret` puts every field at the word slot the builder wrote and the chaser read before the re-spelling (result 0, kind 5, code 6, e 7, args 8, arity 9)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "result", "kind", "code", "e", "args", "arity" ]
         in
         List.map (\n -> Check.fieldOffset d "Ret" n) names == [ Just 0, Just 40, Just 48, Just 56, Just 64, Just 72 ]
        )
    , check "U7 LAYOUT PIN: sizeof(Ret) == 10 words = the 80 bytes Rt.tail-known/Rt.applyTailGo malloc and Lower's @ret blit moves — a `val` field is 5 words, so the `.done` payload is words 0..4 and the tail-call record 5..9.  A word added or dropped anywhere in the declaration moves this and the 80 in every `malloc(80)` is then a lie"
        (Check.sizeofStruct (declsOf runtimeMidText) "Ret" == Just 10)
    , check "U7 LAYOUT PIN: Ret.result is 5 words WIDE, not just at offset 0 (the field-width read, from the same one table): that width is what makes `malloc(80)` = sizeof(Ret) and what makes the `vecload(r, 0)` / `r->result` read the whole `.done` Value"
        (Check.fieldWidth (declsOf runtimeMidText) "Ret" "result" == Just 5)
    , check "U7 ACCEPT: the `:ret` builder/chaser shape is node-identical on the typed view — `*Ret r = payload(v, 0); r->kind = 1; r->code = wl; word k = r->kind; word f = r->code; rawcall free([word](r) + 16); return r->result;` lowers canon-EQUAL to the word-spelled `word r = ...; wstore(r, 5, 1); wstore(r, 6, wl); word k = wload(r, 5); word f = wload(r, 6); rawcall free(r + 16); return vecload(r, 0);` — the val field READ at offset 0 is `vecload(r, 0)` (`addrPlus p 0 = p`), the word field stores/loads are the same RawWord nodes, and `[word](r)` is J12's identity `*T -> word` view cast, which is why the word offsets and the temp numbering do not move"
        (case
            ( lowlModuleBody "struct Ret { result : val; kind : word; code : word; e : word; args : word; arity : word; }\ndefun Rt.r(v : val, wl : word) -> val {\n  *Ret r = payload(v, 0);\n  r->kind = 1;\n  r->code = wl;\n  word k = r->kind;\n  word f = r->code;\n  rawcall free([word](r) + 16);\n  return r->result;\n}"
            , lowlBody "defun Rt.r(v : val, wl : word) -> val {\n  word r = payload(v, 0);\n  wstore(r, 5, 1);\n  wstore(r, 6, wl);\n  word k = wload(r, 5);\n  word f = wload(r, 6);\n  rawcall free(r + 16);\n  return vecload(r, 0);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )
    , check "U7 ACCEPT: the apply state's shape type-checks on the POINTER — the field stores (`state->args = ..`, `sp->env = env`, `sp->args = args + rem * 40`), the reload-after-alloc (`word env2 = sp->env`), the pointer at a builtin word slot (`mknum(state)`, `free(state)`) and the `[word](sp) + 24` / `[word](state) + 16` cast the root seats need all ACCOMPANIED the same nodes as their `wstore`/`wload` spelling"
        (case
            ( lowlModuleBody "struct ApplyState { args : word; nargs : word; live : word; env : word; }\ndefun Rt.a(v : val, args : word, nargs : word) -> val {\n  *ApplyState state = rawcall malloc(32);\n  state->args = args;\n  state->nargs = nargs;\n  state->live = nargs;\n  rawcall clock_gettime(args, [word](state) + 16);\n  rawcall free(state);\n  *ApplyState sp = payload(v, 0);\n  sp->env = sp->args;\n  word env2 = sp->env;\n  sp->args = env2 + 40;\n  sp->nargs = sp->nargs - 1;\n  rawcall free([word](sp) + 24);\n  recur(mknum(sp), env2, nargs);\n}"
            , lowlBody "defun Rt.a(v : val, args : word, nargs : word) -> val {\n  word state = rawcall malloc(32);\n  wstore(state, 0, args);\n  wstore(state, 1, nargs);\n  wstore(state, 2, nargs);\n  rawcall clock_gettime(args, state + 16);\n  rawcall free(state);\n  word sp = payload(v, 0);\n  wstore(sp, 3, wload(sp, 0));\n  word env2 = wload(sp, 3);\n  wstore(sp, 0, env2 + 40);\n  wstore(sp, 1, wload(sp, 1) - 1);\n  rawcall free(sp + 24);\n  recur(mknum(sp), env2, nargs);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )

    -- ==================== U8: runtime.mid's PROCESS/EXEC scratch blocks (midlang-u8) ====================
    -- The same pins as U5/U6/U7, for the effect parser's plan-tree nodes and
    -- the exec runner's state: read runtime.mid's OWN `struct` declarations —
    -- the ones the `p->f` accesses resolve against — so a reordered, renamed or
    -- re-padded field fails HERE instead of as a wrong argv pointer or a
    -- garbage chain.
    --
    -- THIS FAMILY IS REACHED THROUGH `val`-BOXED BLOCK ADDRESSES (`mknum(pipeW)`
    -- and friends), so most of its sites have no binder to retype and the view
    -- is spelled `[*Pipe](payload(p, 0))->ncmds`.  That spelling needed the
    -- `[*T]`-base arm in LowerToIr's `resolvePointee` (the cast IS its operand);
    -- the ACCEPT row below is what pins it, and the corpus is the proof that the
    -- arm moved no emitted byte of any existing program.
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Prog` puts every field at the word slot the plan builder used before the re-spelling (nchains 0, chains 1)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "nchains", "chains" ]
         in
         List.map (\n -> Check.fieldOffset d "Prog" n) names == List.map Just (byteSlots 2)
        )
    , check "U8 LAYOUT PIN: sizeof(Prog) == 2 words = the 16 bytes Rt.epProg mallocs — a field added anywhere moves this and every `nchains` count with it"
        (Check.sizeofStruct (declsOf runtimeMidText) "Prog" == Just 2)
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Chain` puts every field at the word slot the chain builder used before the re-spelling (op 0, pipe 1) — and sizeof == 2 words is the 16-byte STRIDE Prog.chains is indexed by"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "op", "pipe" ]
         in
         List.map (\n -> Check.fieldOffset d "Chain" n) names == List.map Just (byteSlots 2)
            && Check.sizeofStruct d "Chain"
            == Just 2
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Pipe` puts every field at the word slot the pipeline builder used before the re-spelling (ncmds 0, cmds 1), and sizeof == 2 words is the 16 bytes Rt.epPipeline mallocs"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "ncmds", "cmds" ]
         in
         List.map (\n -> Check.fieldOffset d "Pipe" n) names == List.map Just (byteSlots 2)
            && Check.sizeofStruct d "Pipe"
            == Just 2
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Scratch` puts every field at the word slot the plan parser used before the re-spelling (cbuf 0, depth 1, lim 2), and sizeof == 3 words is the 24 bytes Rt.exec-plan mallocs — `lim` is a STAGING field (rewritten before each Rt.epCount), which is why it is a word and not a constant"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "cbuf", "depth", "lim" ]
         in
         List.map (\n -> Check.fieldOffset d "Scratch" n) names == List.map Just (byteSlots 3)
            && Check.sizeofStruct d "Scratch"
            == Just 3
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Redir` puts every field at the word slot the redirect builder/reader used before the re-spelling (kind 0, fd 1, path 2, dupfd 3, body 4, tmpfd 5), and sizeof == 6 words is the 48-byte STRIDE the redirect ARRAY is indexed by — the stride is `i * 48` at six malloc/free/lookup sites, so a dropped field here is a walking offset, not a wrong field"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "kind", "fd", "path", "dupfd", "body", "tmpfd" ]
         in
         List.map (\n -> Check.fieldOffset d "Redir" n) names == List.map Just (byteSlots 6)
            && Check.sizeofStruct d "Redir"
            == Just 6
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct CmdState` puts every field at the word slot the decoded-command builder used before the re-spelling (argv 0, argc 1, redirs 2, nredirs 3, subprog 4), and sizeof == 5 words is the 40-byte STRIDE `Rt.epPipeline` mallocs and `[word](cmdsArr) + i * 40` walks — one word too few is a command read out of its neighbour's argv"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "argv", "argc", "redirs", "nredirs", "subprog" ]
         in
         List.map (\n -> Check.fieldOffset d "CmdState" n) names == List.map Just (byteSlots 5)
            && Check.sizeofStruct d "CmdState"
            == Just 5
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct Exec` puts every field at the word slot the runner used before the re-spelling (cbuf 0, outfd 1, errfd 2, inChild 3, subprog 4, pipe 5, code 6, chain 7, ncmds 8, npipes 9, pfds 10, pids 11, nforked 12, forkFailed 13, status 14, bodyOff 15, bodyFd 16, waitStatus 17, curCmd 18, cursor 19, argIdx 20)"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "cbuf", "outfd", "errfd", "inChild", "subprog", "pipe", "code", "chain", "ncmds", "npipes", "pfds", "pids", "nforked", "forkFailed", "status", "bodyOff", "bodyFd", "waitStatus", "curCmd", "cursor", "argIdx" ]
         in
         List.map (\n -> Check.fieldOffset d "Exec" n) names == List.map Just (byteSlots 21)
        )
    , check "U8 LAYOUT PIN: sizeof(Exec) == 21 words = the 168 bytes Rt.exec-plan mallocs, and slot 17 is at byte 136 — the address `waitpid(pid, payload(st, 0) + 136, 0)` passes, which is the one slot reached by arithmetic rather than by name"
        (Check.sizeofStruct (declsOf runtimeMidText) "Exec" == Just 21)
    , check "U8 LAYOUT PIN: runtime.mid's own `struct ReadBlk` puts every field at the word slot both slurps used before the re-spelling (fd 0, tmp 1, acc 2, len 3, cap 4, _pad 5), and sizeof == 6 words — the allocation is 72 bytes, so the struct is a PREFIX: words 6..8 are the `*CopyDesc` at `[word](blkW) + 48` (48 == 6 words), which is why 48 is pinned here and not merely written in a comment"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "fd", "tmp", "acc", "len", "cap", "_pad" ]
         in
         List.map (\n -> Check.fieldOffset d "ReadBlk" n) names == List.map Just (byteSlots 6)
            && Check.sizeofStruct d "ReadBlk"
            == Just 6
            && (Maybe.map (\w -> w * 8) (Check.sizeofStruct d "ReadBlk") == Just 48)
        )
    , check "U8 LAYOUT PIN: runtime.mid's own `struct CopyDesc` is Rt.memGo's (src 0, dst 1, n 2) — the 3 words the two slurps write at `[word](blkW) + 48`, so it must stay 3 words: a field added here walks into nothing"
        (let
            d =
                declsOf runtimeMidText

            names =
                [ "src", "dst", "n" ]
         in
         List.map (\n -> Check.fieldOffset d "CopyDesc" n) names == List.map Just (byteSlots 3)
            && Check.sizeofStruct d "CopyDesc"
            == Just 3
        )
    , check "U8 ACCEPT: the NESTED view cast (`[*Pipe]([*Exec](payload(v, 0))->pipe)->cmds`, Rt.execGo's mode-3 re-read) is node-identical too — the arm resolves the OUTER cast and the inner field read is the ordinary nodes, so it lowers canon-EQUAL to `wload(wload(payload(v, 0), 5), 1)`"
        (case
            ( lowlModuleBody "struct Exec { cbuf : word; outfd : word; errfd : word; inChild : word; subprog : word; pipe : word; }\nstruct Pipe { ncmds : word; cmds : word; }\ndefun Rt.a(v : val) -> word {\n  return [*Pipe]([*Exec](payload(v, 0))->pipe)->cmds;\n}"
            , lowlBody "defun Rt.a(v : val) -> word {\n  return wload(wload(payload(v, 0), 5), 1);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )
    , check "U8 ACCEPT: the `[*S](payload(p, 0))->f` VIEW CAST is node-identical — a `val`-boxed block address read through the cast lowers canon-EQUAL to the `wload(payload(p, 0), k)` spelling (this is the shape LowerToIr's `resolvePointee` gained the cast arm for; without it the checker admitted the form and the lowerer refused it)"
        (case
            ( lowlModuleBody "struct Pipe { ncmds : word; cmds : word; }\ndefun Rt.a(p : val) -> word {\n  return [*Pipe](payload(p, 0))->cmds;\n}"
            , lowlBody "defun Rt.a(p : val) -> word {\n  return wload(payload(p, 0), 1);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )
    , check "U8 ACCEPT: the retyped-binder shape is node-identical too — `*Redir r = arrN + j * 48; r->tmpfd` lowers canon-EQUAL to `word r = arrN + j * 48; wload(r, 5)` (`word -> *T` is J12's source-spelled view: no node), so every `wload(redirN, k)` -> `redirN->f` site keeps its emission"
        (case
            ( lowlModuleBody "struct Redir { kind : word; fd : word; path : word; dupfd : word; body : word; tmpfd : word; }\ndefun Rt.a(arrN : word, j : word) -> word {\n  *Redir r = arrN + (j * 48);\n  return r->tmpfd;\n}"
            , lowlBody "defun Rt.a(arrN : word, j : word) -> word {\n  word r = arrN + (j * 48);\n  return wload(r, 5);\n}"
            )
         of
            ( Ok typed, Ok plain ) ->
                canon typed == canon plain

            _ ->
                False
        )

    -- ==================== STAGE 7A: the Mid effect host (QBE_MIDHOST) ====================
    -- The host's STATE is one malloc'd blob whose size Mid cannot spell
    -- (`sizeof` does not exist at the surface), so `Rt.hostInit` computes it
    -- as literal ARITHMETIC.  These rows recompute the same number from
    -- runtime.mid's OWN declarations, which is what makes a field added to
    -- `struct Host`/`struct HostEv` without the malloc line a RED ROW instead
    -- of a heap overflow.  MEASURED values (the emitted .ssa agrees: the host's
    -- field accesses carry 1321296 for `evals` and 4216 for its stride).
    , check "7A LAYOUT PIN: runtime.mid's own `struct Host` puts nslots at 0, the rooted slot array at byte 8 and the eval table at 1321296 — the three offsets Rt.hostInit/Rt.hostRun/TestMain all name — and stage 7C APPENDED npoll/poll after the eval table (1861968/1861976 once 7D widened the eval stride to 4224), so no earlier offset moved"
        (let
            d =
                declsOf runtimeMidText
         in
         [ Check.fieldOffset d "Host" "nslots", Check.fieldOffset d "Host" "slots", Check.fieldOffset d "Host" "evals", Check.fieldOffset d "Host" "npoll", Check.fieldOffset d "Host" "poll" ]
            == [ Just 0, Just 8, Just 1321296, Just 1861968, Just 1861976 ]
        )
    , check "7A LAYOUT PIN (stage 7C extended the blob by two words, stage 7D widened the eval stride by one): sizeof(struct Host) == 232748 words == 1861984 bytes == Rt.hostInit's `8 + (33031 * 40) + (6 * 8) + (128 * 4224) + 16` (nslots + the slot array + nevals..clrBase + the eval table + 7C's npoll/poll).  A field added to struct Host without the malloc line is a RED ROW, not a heap overflow"
        (Check.sizeofStruct (declsOf runtimeMidText) "Host" == Just 232748
            && String.contains "word bytes = 8 + (33031 * 40) + (6 * 8) + (128 * 4224) + 16;" runtimeMidText
        )
    , check "7A LAYOUT PIN: sizeof(struct HostEv) == 528 words == 4224 bytes (4 header words + 256 two-word frames + etag + the 11-word effect union, 7D's `ex` growing it by HostEX.code) and sizeof(struct HostFrame) == 2 — the eval table's stride and the frame stack's stride"
        (Check.sizeofStruct (declsOf runtimeMidText) "HostEv" == Just 528 && Check.sizeofStruct (declsOf runtimeMidText) "HostFrame" == Just 2)
    , check "7A LAYOUT PIN: the effect union's three members all start at byte 4136 (one anonymous promoted `union { rf ex sl }` block, its widest member `ex` 11 words after 7D added HostEX.code) — the plan §5.1 shape"
        (let
            d =
                declsOf runtimeMidText
         in
         [ Check.fieldOffset d "HostEv" "rf", Check.fieldOffset d "HostEv" "ex", Check.fieldOffset d "HostEv" "sl" ]
            == [ Just 4136, Just 4136, Just 4136 ]
        )
    , check "7A SLOT-ARITHMETIC PIN: the last evaluation block (2 + 127 * 258 + 257 = 33025) ends BEFORE the five scratch cells (33026..33030), and nslots = 33031 = 2 + 128 * 258 + 5 — so a spawn/clear can never walk over SCR_CUR/SCR_A0/SCR_A1/SCR_RES/SCR_TMP"
        (2 + 127 * 258 + 257 < 33026 && 33031 == 2 + 128 * 258 + 5 && String.contains "lp->nslots = 33031;" runtimeMidText)
    , check "7A APPLIER PIN (the plan §4.1 trap): Rt.apply-at calls Rt.callArity AND Rt.applyPartGo (stage 7 O3-fix added the partial arm's helper; the saturated napp == 0 case is STILL the Disp/rt_callN route) and names NEITHER Rt.apply NOR Rt.applyGo — applyGo's saturated arm returns an UNFORCED `:ret` tail (a heap address where a value belongs), and this is the ONE place the port could ship that silently"
        (case List.filter (\d -> d.key == "Rt.apply-at") (rtProgram rt True True True) of
            d :: _ ->
                let
                    syms =
                        rawCallSyms d.value
                in
                List.member "Rt.callArity" syms
                    && List.member "Rt.applyPartGo" syms
                    && not (List.member "Rt.apply" syms)
                    && not (List.member "Rt.applyGo" syms)

            [] ->
                False
        )
    , check "7A APPLIER PIN: the Disp's arity is the closure's FULL static arity (`wload(code, 1)`), never `arity - rem` — the second trap, which passes zero arguments for a global closure"
        (String.contains "word arity = wload(code, 1) & 4294967295;" runtimeMidText
            && String.contains "dp->arity = arity;" runtimeMidText
            && not (String.contains "dp->arity = arity - rem;" runtimeMidText)
        )
    , check "7O3F APPLIER PIN (the bootstrap blocker): Rt.apply-at handles ALL THREE nargs/rem shapes, and the two guards 7A shipped for the UNPORTED ones are GONE from its body — not reworded, ported.  MEASURED at O3's re-frozen seed: the failing call was `arity=2 rem=1 nargs=1`, i.e. a SATURATED call on a HALF-APPLIED closure, which 7A's `rem != arity` guard could not tell apart from an unported case.  This row is a TEXT pin on the defun body (the BEHAVIOUR is the hostapply fixture's, whose new partial/over arms route exactly these shapes through the host applier and are printed as numbers): the partial arm must hand off to Rt.applyPartGo (the ONE interleave, shared with the two apply loops), the over-applied arm must apply the first `rem` and `recur` on the rest, and the saturated napp > 0 arm must be the two-range bridge (rt_call2r with the closure's napp and the caller's buf — rt_call2r, NOT Rt.apply/Rt.applyGo: trap 1)."
        (let
            body =
                defunText "Rt.apply-at" runtimeMidText
         in
         not (String.contains "partially applied closure reached the applier" body)
            && not (String.contains "different number of arguments than the closure's arity" body)
            && String.contains "val p = call Rt.applyPartGo(mknum(sp), cN);" body
            && String.contains "val f2 = call Rt.apply-at(cN, bufN, mknum(rem));" body
            && String.contains "recur(f2, mknum(buf + rem * 40), mknum(nargs - rem));" body
            && String.contains "aggcall ret rawsym(\"rt_call2r\")(wload(code, 0), env, napp, buf, rem);" body
            && String.contains "more arguments than an already fully applied closure" body
        )
    , check "7O3F APPLIER PIN (no silent case): the saturated arm's missing-env guard keeps the RUNTIME's message (`qbe-rt: closure env missing for applied args`) — one condition, one string, the same one applyGo's saturated arm raises — so a half-applied closure with no env still dies BY NAME on the host route instead of reading a garbage capture"
        (String.contains "call Rt.die(rawstr(\"qbe-rt: closure env missing for applied args\"));" (defunText "Rt.apply-at" runtimeMidText))
    , check "7O3F APPLIER PIN: Rt.applyPartGo is the ONLY defun that spells the capture/args interleave — the three copyWords lines appear ONCE in runtime.mid (applyGo's and applyTailGo's partial arms call the helper instead), so the host route and the generated-code route cannot drift; and the helper's own root-order is the pinned dance (the B1 row above)"
        ((runtimeMidText
            |> String.split "\n"
            |> List.filter (\l -> String.contains "call Rt.copyWords(envv + napp * 40, args, nargs * 5);" l)
            |> List.length
         )
            == 1
            && String.contains "defun Rt.applyPartGo(state : val, f : val) -> val {" runtimeMidText
        )
    , check "7A CTOR TABLE PIN: Rt.hostArity's 20 (name, expected vector length) pairs are exactly effectloop.zig's taskArity + 1 — the transcription, pinned"
        (hostArityPairs (defunText "Rt.hostArity" runtimeMidText)
            == [ ( "TaskSucceed", 2 ), ( "TaskFail", 2 ), ( "TaskAndThen", 3 ), ( "TaskOnError", 3 ), ( "TaskWrite", 2 ), ( "TaskReadLine", 1 ), ( "TaskReadFile", 2 ), ( "TaskWriteFile", 3 ), ( "TaskExec", 2 ), ( "TaskGetenv", 2 ), ( "TaskSetenv", 3 ), ( "TaskCd", 2 ), ( "TaskGetcwd", 1 ), ( "TaskGetpid", 1 ), ( "TaskGlob", 2 ), ( "TaskNow", 1 ), ( "TaskSleep", 2 ), ( "TaskQuit", 1 ), ( "TaskListDir", 2 ), ( "TaskStat", 2 ) ]
        )
    , check "7A DISPATCH PIN (stage 7B extended it to SIXTEEN, 7C to SEVENTEEN, 7D to EIGHTEEN, and 7E CLOSES IT AT TWENTY — the whole Runtime.elm Task ctor table): the dispatch implements exactly the pure six (Succeed/Fail/AndThen/OnError/Now/Quit) + 7B's synchronous ten (Write/ReadLine/WriteFile + the six prim leaves + Sleep) + 7C's ReadFile (the first SUSPENDING fd leaf) + 7D's Exec (the forking one) + 7E's ListDir/Stat (the two RECORD-BUILDING leaves, both synchronous), and its fallthrough is NO LONGER A PORTING GATE: it is the Zig's own unhandled-ctor arm (Rt.hostDieErr with `unhandled Task effect: `), which no ctor in the table can reach and which exists so a name OUTSIDE the twenty still dies loudly instead of stalling"
        (let
            handled =
                ctorNames (defunText "Rt.hostDispatch" runtimeMidText)
         in
         List.sort handled
            == List.sort
                [ "TaskAndThen"
                , "TaskCd"
                , "TaskExec"
                , "TaskFail"
                , "TaskGetcwd"
                , "TaskGetenv"
                , "TaskGetpid"
                , "TaskGlob"
                , "TaskListDir"
                , "TaskNow"
                , "TaskOnError"
                , "TaskQuit"
                , "TaskReadFile"
                , "TaskReadLine"
                , "TaskSetenv"
                , "TaskSleep"
                , "TaskStat"
                , "TaskSucceed"
                , "TaskWrite"
                , "TaskWriteFile"
                ]
            && String.contains "call Rt.hostDieErr(rawstr(\"unhandled Task effect: \"), nm);" (defunText "Rt.hostDispatch" runtimeMidText)
        )
    , check "7A SPLICE PIN (RETIRED AT O4): runtime.mid carries ZERO QBE_MIDHOST markers — the splice, the hatch, and Rt.main's Zig arm are deleted with src/effectloop.zig (the Mid host is the only host, its defuns unconditionally present)"
        (List.isEmpty (List.filter (\l -> String.contains "QBE_MIDHOST-ONLY" l) (String.lines runtimeMidText)))
    , check "7O3 RUN-TIME OVERRIDE PIN (RETIRED AT O4): zero QBE_MIDGC-ONLY markers remain in runtime.mid — the run-time refusal guarded the QBE_MIDHOST=0 hatch, which is deleted"
        (List.isEmpty (List.filter (\l -> String.contains "QBE_MIDGC-ONLY" l) (String.lines runtimeMidText)))
    , check "7A GATE PIN (RE-PINNED AT O4): with the splice retired there is ONE runtime text and it is HOSTED — Rt.load reports `hosted` (the structural witness: the program defines Rt.hostRun), so hostSeeds is live in every compile including the selfhost lane"
        (case Rt.load runtimeMidText of
            Ok withHost ->
                withHost.hosted

            Err _ ->
                False
        )
    , check "7A REACHABILITY PIN: hostSeeds is the closure of the host's two entry points over rtDeps (52 keys = every REACHED host defun), so a host defun added without an rtDeps edge is a RED ROW (a compiled call to a pruned defun is an undefined symbol, i.e. a link failure at qbe-mk, not a red suite)"
        (List.all (\k -> List.member k Rt.hostSeeds) hostDefunKeys
            && List.length (List.filter (\k -> List.member k hostDefunKeys) Rt.hostSeeds) == List.length hostDefunKeys
        )
    , check "7A REACHABILITY PIN (the default route does NOT move): the host's entry points are NOT in Rt.main's rtDeps edges — Rt.main is a seed root in EVERY compile ($main is in every artifact), so an edge there would pull the whole host into all 159 corpus artifacts"
        (not (List.member "Rt.hostRun" (Maybe.withDefault [] (Dict.get "Rt.main" Rt.rtDeps)))
            && not (List.member "Rt.hostIsProgram" (Maybe.withDefault [] (Dict.get "Rt.main" Rt.rtDeps)))
            && List.member "Rt.hostRun" Rt.hostSeeds
            && List.member "Rt.hostIsProgram" Rt.hostSeeds
        )
    , check "7A ERROR-MODEL PIN (gap G-J): the host's die path writes the 'qbe-rt: error: ' prefix the Zig host's rt_run_program printed — Rt.die has no prefix, so the port carries it (no fixture pins the shape today; the host's loud leaves are the second half of the oracle)"
        (String.contains "qbe-rt: error: " runtimeMidText && String.contains "defun Rt.hostDieErr(a : word, b : word) -> word {" runtimeMidText)
    -- ==================== STAGE 7B: the synchronous leaves ====================
    -- Text rows for the same reason 7A's are: the dispatch is a 20-arm if
    -- chain and the deadline machinery is statement order, neither of which a
    -- tree pin reads as cheaply as the defun's own text.  The BEHAVIOUR is the
    -- fixtures' (arm A == arm B on nowunit + progio); these pin the SHAPE the
    -- fixtures cannot see — which defun each leaf calls, and that a sleeping
    -- eval completes NOTHING.
    , check "7B LEAF PIN: each of the nine non-sleeping ctors 7B added calls the defun its Zig leaf reached — Write->hostWriteStr(1,..), ReadLine->hostReadLine, WriteFile->hostWriteFileLeaf, and the six prim leaves ONE `call` each to the existing Rt defun (the runPrim/varray dance has no Mid counterpart, so it must NOT reappear)"
        (let
            d =
                defunText "Rt.hostDispatch" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "call Rt.hostWriteStr(mknum(1), s);"
            , "call Rt.hostReadLine(mknil)"
            , "call Rt.hostWriteFileLeaf(path, contents);"
            , "call Rt.getenv(a)"
            , "call Rt.setenv(n2, v2)"
            , "call Rt.cd(p3)"
            , "call Rt.getcwd(mknil)"
            , "call Rt.getpid(mknil)"
            , "call Rt.glob(g1)"
            ]
            && not (List.any (\t -> String.contains t d) [ "vaInit", "vaPush", "execPrimitive" ])
        )
    , check "7B SLEEP PIN: TaskSleep SUSPENDS — it records an ABSOLUTE deadline (now + ms, both monotonic ms), sets etag = 3 and completes NOTHING (no hostCompleteOk in the arm); the etag ladder is the Zig enum's order 1 readFile / 2 exec / 3 sleep"
        (case String.split "rawstr(\"TaskSleep\")" (defunText "Rt.hostDispatch" runtimeMidText) of
            _ :: rest :: _ ->
                case String.split "return mknil;" rest of
                    body :: _ ->
                        String.contains "lp->evals[i].etag = 3;" body
                            && String.contains "lp->evals[i].sl.deadline = now + ms;" body
                            && not (String.contains "hostComplete" body)
                            && not (String.contains "vecstore" body)

                    [] ->
                        False

            _ ->
                False
        )
    , check "7B DEADLINE PIN (stage 7C completed the tail): the driver is step -> flush expired sleeps -> (runnable? loop) -> rebuild the fd table -> poll(that table, the nearest deadline) -> drain what is ready -> flush expired sleeps, so the ONE poll both waits for an fd and IS the bounded sleep a sleep-only program needs; -1 with no fd and no runnable work is a LOUD die, not the Zig's silent break"
        (let
            d =
                defunText "Rt.hostRunLoop" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "call Rt.hostStepAll(hN);"
            , "call Rt.hostFlushExpiredSleeps(hN);"
            , "call Rt.hostRunnableScan(hN, mknum(0))"
            , "call Rt.hostPollTimeout(hN)"
            , "call Rt.hostRebuildPollfds(hN);"
            , "call Rt.hostDrainReady(hN);"
            , "rawcall poll(lp->poll, lp->npoll, to);"
            , "a pending effect has no pollable fd"
            ]
        )
    , check "7B DEADLINE PIN (the timeout's three arms): no pending sleep -> -1 (block), a due one -> 0, otherwise the remainder in ms CLAMPED to maxInt(i32) — the Zig's @min, without which a long sleep would wrap negative and block forever"
        (let
            d =
                defunText "Rt.hostPollTimeout" runtimeMidText
         in
         String.contains "return mknum(-1);" d
            && String.contains "if (mkbool(remain <= 0)) {" d
            && String.contains "return mknum(2147483647);" d
        )
    , check "7B HATCH PIN (RE-PINNED AT O4): Rt.main's host arm is UNCONDITIONAL — no mhEnv/mhOff hatch read, no rt_is_program Zig probe — and it still PRINTS AND EXITS itself (the 7B measured rule: an expression arm's `return` does not return, so falling through ran a program twice)"
        (let
            arm =
                defunText "Rt.main" runtimeMidText
         in
         String.contains "call Rt.hostIsProgram" arm
            && String.contains "call Rt.printValue(vecload(modelslot, 0))" arm
            && String.contains "rawcall exit(0);" arm
            && not (String.contains "mhEnv" arm)
            && not (String.contains "rt_is_program" arm)
            && not (String.contains "rt_run_program" arm)
        )
    , check "7B DECLARATION PIN (stage 7C added fcntl): `poll` and the VARIADIC `fcntl` are DECLARED (C prototypes) rather than added to rawcallArity — the plan's gap G-I route for the effect-loop port, and the reason Ast.rawcallArity must not grow a row for either (R-08 forbids both tables)"
        (String.contains "extern poll(fds : ptr, nfds : i64, timeout : i32) -> i32;" runtimeMidText
            && String.contains "extern fcntl(fd : i32, cmd : i32, ...) -> i32;" runtimeMidText
            && not (Dict.member "poll" Ast.rawcallArity)
            && not (Dict.member "fcntl" Ast.rawcallArity)
        )

    -- ==================== STAGE 7C: the fd table + the poll ====================
    -- Text + layout rows for the same reason 7A/7B's are: the poll is a
    -- STATEMENT ORDER and the table is a LAYOUT, and neither reads as cheaply
    -- from a tree as from the defun that spells it.  The BEHAVIOUR is the
    -- fixtures' (readpipe reaches the suspended arm; nowunit keeps the
    -- sleep-only arm green through the same poll).
    , check "7C POLLFD PIN: the fd table's cells are the KERNEL'S struct pollfd — fd i32@0, events u16@4, revents u16@6, one word (8 bytes) each.  A word-granular layout would put revents at bytes 8..15 where the kernel never writes, so readiness would read back 0 forever"
        (let
            d =
                declsOf runtimeMidText
         in
         [ Check.fieldOffset d "Pollfd" "fd", Check.fieldOffset d "Pollfd" "events", Check.fieldOffset d "Pollfd" "revents" ]
            == [ Just 0, Just 4, Just 6 ]
            && Check.sizeofStruct d "Pollfd" == Just 1
        )
    , check "7C TABLE PIN: struct HostPoll is 258 cells x 3 arrays = 6192 bytes = 774 words, with the three arrays at 0 / 2064 / 4128 — and hostInit allocates it as `sizeof(HostPoll) * 8` (BYTES, since sizeof is a word count) and memsets it, so a cell that was never registered is zero rather than stale stack garbage"
        (let
            d =
                declsOf runtimeMidText
         in
         [ Check.fieldOffset d "HostPoll" "fds", Check.fieldOffset d "HostPoll" "evals", Check.fieldOffset d "HostPoll" "roles" ]
            == [ Just 0, Just 2064, Just 4128 ]
            && Check.sizeofStruct d "HostPoll" == Just 774
            && String.contains "word pollBytes = sizeof(HostPoll) * 8;" runtimeMidText
            && String.contains "rawcall memset(pp, 0, pollBytes);" runtimeMidText
            && String.contains "rawcall malloc(pollBytes);" runtimeMidText
        )
    , check "7C NFDS PIN (the kernel's nfds matches the registered set by CONSTRUCTION, not by two places agreeing): every write to lp->npoll is either the scan's reset to 0 or hostAddPoll's +1, and the ONE poll call reads both the pointer and the count from the same two fields — so no code path can poll a count the table does not hold"
        (let
            writers =
                List.filter (\l -> String.contains "lp->npoll = " l) (String.lines runtimeMidText)
         in
         writers
            == [ "  lp->npoll = n + 1;"
               , "  lp->npoll = 0;"
               , "  lp->npoll = 0;"
               ]
            && String.contains "rawcall poll(lp->poll, lp->npoll, to);" runtimeMidText
            && String.contains "if (mkbool(lp->npoll == 0) && mkbool(to < 0)) {" runtimeMidText
        )
    , check "7C POLL ENTRY PIN: one table cell is drained only when the kernel SET revents, the eval is still ACTIVE and still carries the effect THIS ROLE belongs to (7C: etag 1 readFile — 7D extended the same guard per role: 2 = exec stdout, 3 = exec stderr) — the table is one poll old, so a completion earlier in the same pass can free a slot and respawn a different evaluation into it, and stepping that one would be a silent wrong answer"
        (let
            d =
                defunText "Rt.hostPollEntry" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "if (pp->fds[k].revents == 0) {"
            , "word ev = pp->evals[k];"
            , "word role = pp->roles[k];"
            , "if (lp->evals[ev].active == 0) {"
            , "if (role == 1) {"
            , "if (lp->evals[ev].etag != 1) {"
            , "return call Rt.hostReadFileComplete(hN, mknum(ev));"
            , "if (role == 2) {"
            , "if (lp->evals[ev].etag != 2) {"
            , "return call Rt.hostExecDrainOut(hN, mknum(ev));"
            , "if (role == 3) {"
            , "return call Rt.hostExecDrainErr(hN, mknum(ev));"
            ]
            && String.contains "lp->npoll = 0;" (defunText "Rt.hostRebuildPollfds" runtimeMidText)
            && String.contains "if (lp->evals[i].active == 0) {" (defunText "Rt.hostRebuildPollGo" runtimeMidText)
            && String.contains "if (lp->evals[i].etag == 1) {" (defunText "Rt.hostRebuildPollGo" runtimeMidText)
        )
    , check "7C WOULDBLOCK PIN: `read` returning -1 with errno EAGAIN (11) is NOT an error — it returns 0 = STILL PENDING and the eval stays suspended for the next poll — while any other errno completes with the bytes gathered so far (1) and EINTR (4) retries the SAME read in place (std.posix.read's own loop).  This is the distinction the whole suspending arm rests on"
        (let
            d =
                defunText "Rt.hostReadFileDrain" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "word e = byteload(rawcall __errno_location(), 0);"
            , "if (mkbool(e == 4)) {"
            , "recur(hN, iN);                       // EINTR: retry the same read"
            , "if (mkbool(e == 11)) {"
            , "return mknum(0);                   // EAGAIN: STILL PENDING, poll again"
            , "return mknum(1);                   // a real error: complete as-is"
            , "if (mkbool(n == 0)) {"
            , "return mknum(1);                       // EOF: complete with what we have"
            ]
        )
    , check "7C GROW PIN (7B's double-free class, re-checked here): hostRfGrow reads the OLD block and the length from the effect, copies through Rt.memGo, and only THEN frees the old block and republishes bptr/bcap; every caller re-reads bptr/blen FROM THE EFFECT afterwards (`rf.bptr + rf.blen`), so no local taken before a grow can be freed or dereferenced after it.  The OOM arm leaves bcap UNCHANGED, which is the caller's failure signal"
        (let
            g =
                defunText "Rt.hostRfGrow" runtimeMidText

            d =
                defunText "Rt.hostReadFileDrain" runtimeMidText
         in
         List.all (\t -> String.contains t g)
            [ "word old = lp->evals[i].rf.bptr;"
            , "word len = lp->evals[i].rf.blen;"
            , "call Rt.memGo(mknum([word](d)), mknum(0)); // memGo copies nothing for n == 0"
            , "rawcall free(d);"
            , "rawcall free(old);                       // free(0) on the first grow: a no-op"
            , "lp->evals[i].rf.bptr = nbuf;"
            , "lp->evals[i].rf.bcap = ncap;"
            ]
            && String.contains "if (mkbool(nbuf == 0)) {" g
            && String.contains "d->dst = lp->evals[i].rf.bptr + lp->evals[i].rf.blen;" d
            && String.contains "if (mkbool(lp->evals[i].rf.bcap < need)) {" d
            && String.contains "lp->evals[i].rf.blen = need;" d
        )
    , check "7C COMPLETE PIN: the String is built BEFORE either block is freed and out of `bptr`/`blen` read ONCE, the fd is closed once (the leaf owns it), and the effect's four words are cleared so cleanupAll cannot close a recycled fd and cannot free a block twice"
        (let
            d =
                defunText "Rt.hostReadFileComplete" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "word len = lp->evals[i].rf.blen;"
            , "word src = lp->evals[i].rf.bptr;"
            , "val s = mkstr(dst, len);"
            , "rawcall close(lp->evals[i].rf.fd);       // the leaf opened it; it is valid"
            , "rawcall free(src);"
            , "rawcall free(lp->evals[i].rf.tmp);"
            , "lp->evals[i].rf.fd = -1;"
            , "lp->evals[i].rf.bptr = 0;"
            , "lp->evals[i].etag = 0;"
            , "return call Rt.hostCompleteOk(hN, iN);"
            ]
            && not (String.contains "lp->evals[i].etag = 3;" d)
        )
    , check "7C SUSPEND PIN: the readFile leaf opens with O_NONBLOCK (0x800) and NO O_CREAT, sets etag = 1 BEFORE the first drain, and completes at once only when the drain says COMPLETE — so a regular file finishes inside its dispatch (the property `asyncorder` needs to overtake a suspended exec) and a pipe suspends on the poll"
        (let
            d =
                defunText "Rt.hostLeafReadFile" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "word fd = rawcall openat(-100, buf, 2048, 0);   // O_RDONLY|O_NONBLOCK"
            , "lp->evals[i].etag = 1;                   // the ladder's order: 1 readFile"
            , "if (payload(call Rt.hostReadFileDrain(hN, iN), 0) == 0) {"
            , "return mknil;                          // EAGAIN: the poll resumes it"
            , "return call Rt.hostReadFileComplete(hN, iN);"
            , "val empty = \"\";"
            ]
            && String.contains "call Rt.hostLeafReadFile(hN, iN, path)" (defunText "Rt.hostDispatch" runtimeMidText)
        )
    , check "7C SETNONBLOCK PIN (the seat 7D calls): Rt.hostSetNonblocking is F_GETFL then F_SETFL|O_NONBLOCK through the VARIADIC fcntl — the FFI arc's U4 shape — and it is UNCALLED in 7C (the readFile leaf asks openat itself), so this row is the only thing that can see it until the exec pipes land"
        (let
            d =
                defunText "Rt.hostSetNonblocking" runtimeMidText
         in
         List.all (\t -> String.contains t d)
            [ "word fl = rawcall fcntl(fd, 3, 0);       // F_GETFL"
            , "rawcall fcntl(fd, 4, fl | 2048);         // F_SETFL, | O_NONBLOCK (0x800)"
            , "if (fl < 0) {"
            ]
        )

    -- ==================== STAGE 7D: the async exec ====================
    -- Text + layout rows for the same reason 7A/7B/7C's are: the child side is
    -- a STATEMENT ORDER (a wrong order truncates output without failing), the
    -- reaps are a division of labour, and the symbol buffer is a table of
    -- offsets.  The BEHAVIOUR is the fixtures': exechost (async grow + err +
    -- non-zero code), execfallback (the predicate's negative arm), fastexec
    -- (the same-iteration reap), asyncorder (out-of-order delivery) and
    -- signaldeathasync (the signal arm through this reap).
    , check "7D CHILD PIN (the `_exit` rule): Rt.hostExecChild's statements are ORDERED — close the read ends, dup2 the write ends onto 1/2, close the (now duplicated) write ends, run the builtin IN THIS PROCESS, and ONLY THEN `_exit` with its code.  An `_exit` before the builtin returns truncates its output to nothing while still answering a plausible exit code, which no fixture can see (a truncated capture still parses); the execvp arm then reads the errno BYTE and answers 127/126 with childW2's cbuf strings, exactly as Rt.exec-run's child arm does"
        (let
            d =
                defunText "Rt.hostExecChild" runtimeMidText
         in
         inOrder d
            [ "rawcall close(s->outr);"
            , "rawcall close(s->errr);"
            , "rawcall dup2(s->outw, 1);"
            , "rawcall dup2(s->errw, 2);"
            , "call Rt.hostCloseFd(mknum(s->outw), mknum(3), mknum(-1));"
            , "call Rt.hostCloseFd(mknum(s->errw), mknum(3), mknum(s->outw));"
            , "val bcode = call Rt.childBuiltin("
            , "if (payload(bcode, 0) >= 0) {"
            , "rawcall _exit(payload(bcode, 0));"
            , "rawcall execvp(a0, s->argv);"
            , "byteload(rawcall __errno_location(), 0) == 2"
            , "rawcall _exit(127);"
            , "rawcall _exit(126);"
            ]
            && not (String.contains "_exit(0)" d)
        )
    , check "7D PREDICATE PIN (agrees with the Zig's singleCommandArgv): ONE seq chain, ONE command, no subshell, no redirects, non-empty argv — six guards, in the Zig's order, and the leaf runs Rt.exec-plan only when the predicate answers 0.  `execfallback` is this row's behavioural arm: a two-command pipeline must take the fallback on BOTH hosts, and if the predicate disagreed it would fork a bogus argv and diverge on the VALUE"
        (let
            d =
                defunText "Rt.hostSingleCommandArgv" runtimeMidText
            leaf =
                defunText "Rt.hostLeafExec" runtimeMidText
         in
         inOrder d
            [ "if (mkbool(p->nchains != 1)) {"
            , "if (mkbool(ch->op != 0)) {"
            , "if (mkbool(pp->ncmds != 1)) {"
            , "if (mkbool(c->subprog != 0)) {"
            , "if (mkbool(c->nredirs != 0)) {"
            , "if (mkbool(c->argc == 0)) {"
            , "if (mkbool(c->argv == 0)) {"
            ]
            && String.contains "return mknum(cmds);" d
            && String.contains "call Rt.hostSingleCommandArgv(mknum(progW))" leaf
            && String.contains "call Rt.exec-plan(vecload(tv, 1))" leaf
        )
    , check "7D REAP PIN (who may reap what): the WNOHANG scan (option 1) reaps only a COMPLETED child and — like the blocking one — CLEARS ex.pid, so one pid is waited for exactly once (a second waitpid is ECHILD at best and, after the kernel recycles the number, somebody else's child at worst).  rc == 0 is the 'still running' answer and must NOT clear the pid (the measured bug this row exists for).  The BLOCKING reap (option 0) retries EINTR on the SAME child and is called ONLY from the driver's npoll == 0 arm — with a registered fd it would deadlock against a child blocked writing into the pipe we are not draining"
        (let
            w =
                defunText "Rt.hostReapGo" runtimeMidText
            b =
                defunText "Rt.hostReapBlockGo" runtimeMidText
            loop =
                defunText "Rt.hostRunLoop" runtimeMidText
         in
         String.contains "rawcall waitpid(pid, stw, 1);" w
            && String.contains "if (mkbool(rc < 0)) {" w
            && String.contains "// ECHILD: nothing left to wait for" w
            && String.contains "// rc == 0: WNOHANG, still running" w
            && String.contains "rawcall waitpid(pid, stw, 0);" b
            && inOrder b [ "rawcall waitpid(pid, stw, 0);", "== 4)) {", "recur(hN, iN, stN);", "return mknum(1);" ]
            && String.contains "lp->evals[i].ex.pid = 0;" w
            && String.contains "lp->evals[i].ex.pid = 0;" b
            && inOrder loop [ "if (mkbool(lp->npoll == 0) && mkbool(to < 0)) {", "call Rt.hostReapBlocking" ]
            && List.length (String.indexes "Rt.hostReapBlocking" runtimeMidText) == 2
        )
    , check "7D COMPLETION PIN (the Zig's completeReady): an exec completes on ONE predicate over the three booleans — (oflags & 7) == 7 — and the three are written by exactly four places (bit 1 in hostExOutEof, bit 2 in hostExErrEof, bit 4 in BOTH reap paths), so 'child reaped AND both pipes EOF'd' cannot be satisfied by a subset.  The pass takes the caller's SNAPSHOT of nevals, because a completion delivers a message that can spawn into the table"
        (let
            d =
                defunText "Rt.hostCompleteReadyGo" runtimeMidText
            ex =
                defunText "Rt.hostExecComplete" runtimeMidText
         in
         String.contains "if ((lp->evals[i].ex.oflags & 7) != 7) {" d
            && String.contains "call Rt.hostExecComplete(hN, mknum(i));" d
            && String.contains "mknum(lp->nevals)" (defunText "Rt.hostCompleteReady" runtimeMidText)
            && String.contains "| 1;" (defunText "Rt.hostExOutEof" runtimeMidText)
            && String.contains "| 2;" (defunText "Rt.hostExErrEof" runtimeMidText)
            && String.contains "| 4;" (defunText "Rt.hostReapGo" runtimeMidText)
            && String.contains "| 4;" (defunText "Rt.hostReapBlockGo" runtimeMidText)
            && String.contains "ex.code = code;" (defunText "Rt.hostReapGo" runtimeMidText)
            && String.contains "Rt.waitStatusCode" (defunText "Rt.hostReapGo" runtimeMidText)
            && inOrder ex
                [ "vecstore(resAddr, 0, call Rt.hostCStrOf("
                , "val errS = call Rt.hostCStrOf("
                , "val inner = call Rt.cons(vecload(resAddr, 0), errS);"
                , "vecstore(resAddr, 0, inner);"
                , "vecstore(resAddr, 0, call Rt.cons(mknum(code), vecload(resAddr, 0)));"
                , "call Rt.hostEpFreePlan(hN, iN);"
                , "return call Rt.hostCompleteOk(hN, iN);"
                ]
        )
    , check "7D ROOTING PIN (the accumulators): every read of bptr/blen/eptr/elen happens THROUGH THE EFFECT, after the allocating call — the drain re-reads `bptr + blen` for its copy destination only after hostExOutGrow (which FREES the old block), and the completion builds BOTH Strings into the eval's result slot (a slice of the registered slot array) and re-reads them at each cons, so a collect between the two allocations cannot strand a raw copy"
        (let
            og =
                defunText "Rt.hostExOutGrow" runtimeMidText
            dg =
                defunText "Rt.hostExecDrainOutGo" runtimeMidText
            dge =
                defunText "Rt.hostExecDrainErrGo" runtimeMidText
         in
         inOrder og
            [ "word old = lp->evals[i].ex.bptr;"
            , "d->src = old;"
            , "call Rt.memGo("
            , "rawcall free(old);"
            , "lp->evals[i].ex.bptr = nbuf;"
            ]
            && String.contains "d->dst = lp->evals[i].ex.bptr + lp->evals[i].ex.blen;" dg
            && String.contains "d->dst = lp->evals[i].ex.eptr + lp->evals[i].ex.elen;" dge
            && String.contains "if (mkbool(lp->evals[i].ex.bcap < need)) {" dg
        )
    , check "7D CBUF PIN (the symbol/diagnostic buffer the decoder and the CHILD share): Rt.hostEpCbuf writes 34 strings at the offsets Rt.exec-plan's own inline fill uses, so the host's decode reads the SAME table the prim route reads and the child's builtin names and childW2 messages are the same bytes.  A missing offset is a decode against garbage (the plan silently classifies wrong) and a wrong childW2 offset writes a fragment of a neighbour"
        (let
            d =
                defunText "Rt.hostEpCbuf" runtimeMidText
            fills =
                List.filterMap cStrFillAt (String.lines d)
            offsets =
                List.map Tuple.first fills
         in
         List.length fills
            == 34
            && offsets
            == [ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 109, 114, 120, 122, 125, 129, 132, 137, 139, 141, 173, 175, 200, 209, 222, 240, 245, 266, 289, 312 ]
            && List.head (List.map Tuple.second fills) == Just "cons"
            && List.member ( 200, "shensh: " ) fills
            && List.member ( 209, ": not found\\n" ) fills
            && List.member ( 222, ": cannot execute\\n" ) fills
            && List.member ( 104, "echo" ) fills
            && List.member ( 96, "hstr" ) fills
            && String.contains "rawcall memset(c, 0, 336);" d
            && String.contains "rawcall malloc(336);" d
        )
    , check "7D LAYOUT PIN: struct HostEX puts prog 0, pid 8, outfd 16, errfd 20, code 24, bptr 32 ... oflags 80 and is 11 words — the union's widest member, one word wider than plan §5.1's sketch because that sketch has no place for the exit code and the Zig's ExecEff carries `exit_code` as a field"
        (let
            d =
                declsOf runtimeMidText
         in
         [ Check.fieldOffset d "HostEX" "prog"
         , Check.fieldOffset d "HostEX" "pid"
         , Check.fieldOffset d "HostEX" "outfd"
         , Check.fieldOffset d "HostEX" "errfd"
         , Check.fieldOffset d "HostEX" "code"
         , Check.fieldOffset d "HostEX" "oflags"
         ]
            == [ Just 0, Just 8, Just 16, Just 20, Just 24, Just 80 ]
            && Check.sizeofStruct d "HostEX" == Just 11
        )
    , check "7D SPAWN PIN (the child's whole input in one pointer): struct HostSpawn is 7 words (argc, argv, the four pipe ends, the `*Exec` scratch) and struct HostPipe is one 8-byte cell of two i32s — the fd halves read by NAME, since a `wload` of a pipe(2) cell would take both ints at once.  The leaf fills the two pipe cells separately (`pipe(pb)`, `pipe(pb + 8)`), writes the NEGATIVE SENTINEL into outfd/errfd BEFORE anything can fail, and only then classifies"
        (let
            d =
                declsOf runtimeMidText
            leaf =
                defunText "Rt.hostLeafExec" runtimeMidText
         in
         Check.sizeofStruct d "HostSpawn"
            == Just 7
            && Check.sizeofStruct d "HostPipe"
            == Just 1
            && Check.fieldOffset d "HostPipe" "rd"
            == Just 0
            && Check.fieldOffset d "HostPipe" "wr"
            == Just 4
            && inOrder leaf
                [ "lp->evals[i].ex.outfd = -1;"
                , "word cbuf = payload(call Rt.hostEpCbuf(mknil), 0);"
                , "word progW = payload(call Rt.epProg(planN, mknum(stw)), 0);"
                , "call Rt.hostSingleCommandArgv(mknum(progW))"
                , "word rcOut = rawcall pipe(pb);"
                , "word rcErr = rawcall pipe(pb + 8);"
                , "word pid = rawcall fork();"
                , "call Rt.hostExecChild(mknum(sp));"
                , "call Rt.hostSetNonblocking(mknum(po->rd));"
                , "call Rt.hostSetNonblocking(mknum(pe->rd));"
                , "call Rt.hostRegisterChild(hN, mknum(i), mknum(pid));"
                , "lp->evals[i].etag = 2;"
                ]
            && String.contains "exec-plan: malformed plan" leaf
            && String.contains "exec-plan: fork/pipe failed" leaf
        )
    , check "7D CLEANUP ORDER PIN (the raw-model hazard): Rt.hostRun runs hostCleanupAll BEFORE it copies the model out, because the exec arm's plan free is a value-ABI call and therefore a GC ALLOCATION — and `outAddr` is Rt.main's RAW `modelslot`, which no collector scans.  With the copy first, a collect inside cleanup moves the model in the blob's slot 0 and leaves a stale pointer in the cell rt_print_value reads (the row goes red on the swap, which is why it is pinned rather than commented)"
        (inOrder (defunText "Rt.hostRun" runtimeMidText)
            [ "call Rt.hostRunLoop(hN);"
            , "call Rt.hostCleanupAll(hN);"
            , "vecstore(outAddr, 0, vecload(h + 8, 0));"
            , "rawcall free(lp->poll);"
            , "call Rt.rootPop();"
            ]
            && String.contains "call Rt.hostEpFreePlan" (defunText "Rt.hostCleanupGo" runtimeMidText)
        )
    , check "7D DRIVER PIN (the Zig's reap/complete seams): the driver reaps TWICE per iteration and completes THREE times — after stepAll (so a child that exited during the step is noticed without a poll), again after the poll BEFORE the drain (so a reaped child and freshly ready fds complete in the same pass), and once inside the npoll == 0 arm right after the blocking reap — and that arm blocks for the reap before declaring a stuck program"
        (let
            d =
                defunText "Rt.hostRunLoop" runtimeMidText
            occurrences =
                List.length (String.indexes "call Rt.hostReapChildren(hN);" d)
         in
         occurrences
            == 2
            && List.length (String.indexes "call Rt.hostCompleteReady(hN);" d)
            == 3
            && inOrder d
                [ "call Rt.hostStepAll(hN);"
                , "call Rt.hostReapChildren(hN);"
                , "call Rt.hostCompleteReady(hN);"
                , "call Rt.hostRebuildPollfds(hN);"
                , "rawcall poll(lp->poll, lp->npoll, to);"
                , "call Rt.hostReapChildren(hN);"
                , "call Rt.hostDrainReady(hN);"
                , "call Rt.hostCompleteReady(hN);"
                ]
        )

    -- ==================== STAGE 7E: listDir + stat ==========================
    -- Text + layout rows, for 7A-7D's reason: the record builders are a SHAPE
    -- (which pair is prepended when, and what the tail is consed onto — the
    -- Zig's dirRecord comment records the bug of getting it wrong) and the
    -- leaves are a STATEMENT ORDER, and neither reads as cheaply from a tree as
    -- from the text.  The BEHAVIOUR is the fixtures': dirunit / statunit /
    -- statplus disagree between the arms before this unit and agree after it.
    , check "7E STAT LAYOUT PIN: struct Stat is libc's x86_64 `struct stat` — mode at BYTE 24, `__pad0` at 36, rdev at 40 (the 8-byte alignment bump past pad0), size at 48, blocks at 64, mtim at 88 with its tv_nsec at 96, and 144 bytes (18 words) in all.  The numbers are MEASURED twice over: tools/qbe/fixtures/ffim-mem.mid's arms 3/4 write exactly these bytes through the typed fields and read the words back, and this host's own <sys/stat.h> agrees (cc + offsetof, glibc 2.44).  A word-granular layout would put mode/uid/gid/pad0 at words 3..6 — reading the right struct's wrong bytes"
        (let
            d =
                declsOf runtimeMidText
            off name =
                Check.fieldOffset d "Stat" name
         in
         [ off "dev", off "ino", off "nlink", off "mode", off "uid", off "gid", off "pad0", off "rdev", off "size", off "blksize", off "blocks", off "atim", off "mtim", off "ctim", off "reserved" ]
            == [ Just 0, Just 8, Just 16, Just 24, Just 28, Just 32, Just 36, Just 40, Just 48, Just 56, Just 64, Just 72, Just 88, Just 104, Just 120 ]
            && Check.sizeofStruct d "Stat"
            == Just 18
            && Check.sizeofStruct d "HostTs"
            == Just 2
        )
    , check "7E DIRENT LAYOUT PIN: getdents64's record is ino64 8 / off64 8 / reclen u16 @16 / d_type u8 @18, so the NAME starts at byte 19 and the record's stride is d_reclen — never `sizeof(Dirent)`, which is 24 (the four headers padded to alignment) and would over-step every record by 5 to 13 bytes.  The name tail is not a FIELD because a narrow array element is not expressible (Parse's fieldType rejects `u8[256]` naming this struct), which is why the walk reads it with `byteload` at base + 19"
        (let
            d =
                declsOf runtimeMidText
            off name =
                Check.fieldOffset d "Dirent" name
         in
         [ off "ino", off "off", off "reclen", off "dtype" ]
            == [ Just 0, Just 8, Just 16, Just 18 ]
            && Check.sizeofStruct d "Dirent"
            == Just 3
            && String.contains "word nptr = base + 19;" (defunText "Rt.hostListDirChunk" runtimeMidText)
            && String.contains "word rlen = d->reclen;" (defunText "Rt.hostListDirChunk" runtimeMidText)
        )
    , check "7E STRIDE PIN: the walk advances by d_reclen and NOTHING ELSE — every `dd->off = ` in the chunk walk adds `rlen`, so a fixed-stride mutation (the obvious wrong idea, since the record's declared size is a different number) cannot hide.  `rlen` and not `reclen`: `reclen` is a BUILTIN spelling (Ast.RecLen, a record's length), so a binder of that name is a parse error — MEASURED while writing this unit"
        (let
            walks =
                List.filter (\l -> String.contains "dd->off = " l) (String.lines (defunText "Rt.hostListDirChunk" runtimeMidText))
         in
         List.sort walks
            == [ "    dd->off = off + rlen;"
               , "  dd->off = off + rlen;"
               ]
        )
    , check "7E DT_UNKNOWN PIN: the d_type answer is PER ENTRY — `dtype` is read from THIS record and passed to hostDirIsDir as a param, and only DT_UNKNOWN (0) falls back to fstatat (AT_SYMLINK_NOFOLLOW = 256, RELATIVE to the open dirfd) while any known type answers with no syscall at all.  Go DirEntry.IsDir parity: a symlink TO a directory is NOT a directory here (TaskStat follows symlinks, and answers the other way — the two are deliberately different questions).  MEASURED GAP: this host's filesystems report real d_types for every entry the gate sees (ZFS: gamma=DT_DIR(4), alpha.txt/beta.txt=DT_REG(8), read off a getdents64 walk), so the fallback arm has NO fixture — this row is the only thing that can see it"
        (let
            f =
                defunText "Rt.hostDirIsDir" runtimeMidText
            caller =
                defunText "Rt.hostListDirChunk" runtimeMidText
         in
         inOrder f
            [ "if (mkbool(dt != 0)) {"
            , "return mkbool(dt == 4);"
            , "rawcall fstatat(payload(fdN, 0), payload(nameN, 0), &st, 256);"
            , "return mkbool((st.mode & 61440) == 16384);"
            ]
            && String.contains "call Rt.hostDirIsDir(mknum(dd->fd), mknum(nptr), mknum(dtype));" caller
            && String.contains "word dtype = d->dtype;" caller
        )
    , check "7E DIRRECORD PIN (the Zig's buried-list bug): the {name,isDir} record's SPINE ENDS AT NIL and the tail is consed on the OUTSIDE — `inner` is cons(isDir-pair, nil), `rec` is cons(name-pair, inner), and the returned value is cons(rec, tail).  Threading the tail into the isDir pair instead buries the rest of the list inside the record, and then `assoc`/field j read the tail where a Bool belongs"
        (let
            f =
                defunText "Rt.hostDirRecord" runtimeMidText
         in
         inOrder f
            [ "val pName = call Rt.@p(call Rt.intern(\"name\"), nameN);"
            , "val inner = call Rt.cons(call Rt.@p(call Rt.intern(\"isDir\"), isDirN), mknil);"
            , "val rec = call Rt.cons(pName, inner);"
            , "return call Rt.cons(rec, tailN);"
            ]
            && not (String.contains "cons(pName, call Rt.cons" f)
        )
    , check "7E STATRECORD PIN: {size, mode, mtimeMs, isDir, isFile} is FIVE assoc pairs built right-to-left — isFile prepended FIRST and size LAST, so the list's head is `size`, the source's first field.  The reader is the record layout rule (field j of the source at depth j), so a reordering here is a silent wrong answer on every stat consumer, which is what `statplus`'s arithmetic on `size` catches"
        (let
            f =
                defunText "Rt.hostStatRecord" runtimeMidText
         in
         inOrder f
            [ "val fFile = call Rt.cons(call Rt.@p(call Rt.intern(\"isFile\"), isFile), mknil);"
            , "val fDir = call Rt.cons(call Rt.@p(call Rt.intern(\"isDir\"), isDir), fFile);"
            , "val fMtime = call Rt.cons(call Rt.@p(call Rt.intern(\"mtimeMs\"), mknum(ms)), fDir);"
            , "val fMode = call Rt.cons(call Rt.@p(call Rt.intern(\"mode\"), mknum(mode)), fMtime);"
            , "val fSize = call Rt.cons(call Rt.@p(call Rt.intern(\"size\"), mknum(sz)), fMode);"
            , "vecstore(resAddr, 0, fSize);"
            ]
            && String.contains "word ms = (st->mtim.sec * 1000) + (st->mtim.nsec / 1000000);" f
        )
    , check "7E ROOTING PIN (the record builders): every intermediate is a `val` binder — a rooted frame slot for the whole body (Lower's WithRoots note) — and the LIST accumulator, which outlives one record, lives in the eval's RESULT SLOT: mknil is stored there BEFORE the open (so the failed-open arm still completes a rooted []), each record's cons re-READS it (`vecload(resAddr, 0)`) instead of holding a raw copy, and the reversal runs only AFTER the dirfd and the getdents64 buffer are closed and freed (the walk itself DOES allocate with the fd open — a deliberate divergence from the Zig's drain-then-build split, sound because both raw resources are C heap, which the collector cannot see or move; the same class as 7D's `oaddr`)"
        (let
            leaf =
                defunText "Rt.hostLeafListDir" runtimeMidText
            chunk =
                defunText "Rt.hostListDirChunk" runtimeMidText
         in
         inOrder leaf
            [ "vecstore(resAddr, 0, mknil);"
            , "word fd = rawcall openat(-100, pb, 589824, 0);"
            , "call Rt.hostListDirDrain(hN, iN, mknum(cell));"
            , "rawcall close(fd);"
            , "rawcall free([*HostDir](cell)->buf);"
            , "rawcall free(cell);"
            , "vecstore(resAddr, 0, call Rt.revGo(vecload(resAddr, 0), mknil));"
            , "return call Rt.hostCompleteOk(hN, iN);"
            ]
            && String.contains "vecstore(resAddr, 0, call Rt.hostDirRecord(nm, isDirV, vecload(resAddr, 0)));" chunk
            && not (String.contains "rootPush" (defunText "Rt.hostDirRecord" runtimeMidText))
            && not (String.contains "rootPush" (defunText "Rt.hostStatRecord" runtimeMidText))
        )
    , check "7E STATLEAF PIN (the zero record is STRUCTURAL): the 144-byte block is malloc'd and memset to 0 BEFORE fstatat, so a failed stat (ENOENT …) leaves size = mode = mtimeMs = 0 and `mode & S_IFMT` = 0 — neither a dir nor a file, which is the Zig's five `if (ok)` arms with no `ok` flag to get wrong, and `statunit`'s absent-path line is what pins it.  The flag is 0 (symlinks FOLLOWED, Go os.Stat parity) and the dirfd is AT_FDCWD"
        (let
            f =
                defunText "Rt.hostLeafStat" runtimeMidText
         in
         inOrder f
            [ "word stW = rawcall malloc(144);"
            , "rawcall memset(stW, 0, 144);"
            , "rawcall fstatat(-100, pb, stW, 0);"
            , "call Rt.hostStatRecord(hN, iN, mknum(stW));"
            , "rawcall free(stW);"
            , "return call Rt.hostCompleteOk(hN, iN);"
            ]
        )
    , check "7E UNPORTED PIN (this unit's headline): the UNPORTED SET IS EMPTY.  `Rt.hostDieUnported` — the seat every unimplemented Task ctor died in, from 7A through 7D — is DELETED: no defun, no rtDeps edge, no rawAbi entry, and its MESSAGE (`unported Task effect: `) went with it — the only surviving mention is runtime.mid's own note recording where the seat went.  The dispatch's tail is the ZIG's own unhandled-ctor arm instead (Rt.hostDieErr with `unhandled Task effect: `), reachable only by a ctor name outside Runtime.elm's twenty.  With the DISPATCH PIN above (which fixes the twenty arms exactly) this is the whole claim: no known Task effect can reach a porting gate any more, which is what O2's flip needs"
        (not (String.contains "defun Rt.hostDieUnported" runtimeMidText)
            && not (String.contains "unported Task effect: " runtimeMidText)
            && not (Dict.member "Rt.hostDieUnported" Rt.rtDeps)
            && not (Set.member "Rt.hostDieUnported" Rt.rawAbi)
            && String.contains "call Rt.hostDieErr(rawstr(\"unhandled Task effect: \"), nm);" (defunText "Rt.hostDispatch" runtimeMidText)
        )

    -- ==================== A2: the lowering (field/index/deref arms) ====================
    -- THE TREE-EQUALITY PIN is this unit's strongest oracle (plan §3, risk R1).
    -- A field access IS its `wload` spelling: the defun written with `p->f` and
    -- the SAME defun written with `wload(p, k)` lower to the SAME Mid.Ir tree,
    -- node for node (canon-normalized — binder ids renumbered in first-appearance
    -- order, names/labels zeroed, the F1 facts).  This is the pin that would have
    -- caught the word-cond mis-lowering class (handoff-perf-a3-review): a
    -- checker-accepted form silently lowering to a DIFFERENT tree shows HERE as an
    -- inequality, not as wrong emitted bytes found later.  Proven ASYMMETRIC: a
    -- one-word offset mutation in the lowering makes the first row FAIL (a
    -- scratch-mutated LowerToIr, rebuilt, observed; see handoff-midlang-a2-result).
    , check "A2 PIN field access IS its wload spelling: `p->g` (field at word offset 1) lowers canon-EQUAL to `wload(p, 1)` — NODE FOR NODE"
        (case
            ( lowlModuleBody "struct S { f : word; g : word; }\ndefun Rt.a(p: *S) -> word {\n  return p->g;\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  return wload(p, 1);\n}"
            )
         of
            ( Ok fieldBody, Ok wloadBody ) ->
                canon fieldBody == canon wloadBody

            _ ->
                False
        )
    , check "A2 PIN offset zero: `p->f` (first field) ≡ `wload(p, 0)` — the same node, offset zero included"
        (case
            ( lowlModuleBody "struct S { f : word; }\ndefun Rt.a(p: *S) -> word {\n  return p->f;\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  return wload(p, 0);\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN val field: `p->vf` ≡ `vecload(p, 0)` — a val field is the 5-word Blit shape, NOT a word load (the per-field-type pin: a val field misread as a word is caught here)"
        (case
            ( lowlModuleBody "struct S { vf : val; }\ndefun Rt.a(p: *S) -> val {\n  return p->vf;\n}"
            , lowlBody "defun Rt.a(p: *val) -> val {\n  return vecload(p, 0);\n}"
            )
         of
            ( Ok f, Ok v ) ->
                canon f == canon v

            _ ->
                False
        )
    , check "A2 PIN field store: `p->g = 7;` ≡ `wstore(p, 1, 7);` — a dead-binder Let of the SAME RawWordStore (the wstore spelling)"
        (case
            ( lowlModuleBody "struct S { f : word; g : word; }\ndefun Rt.a(p: *S) -> word {\n  p->g = 7;\n  return 0;\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  wstore(p, 1, 7);\n  return 0;\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN val field store: `p->vf = v;` ≡ `vecstore(p, 0, v);`"
        (case
            ( lowlModuleBody "struct S { vf : val; }\ndefun Rt.a(p: *S, v: val) -> val {\n  p->vf = v;\n  return v;\n}"
            , lowlBody "defun Rt.a(p: *val, v: val) -> val {\n  vecstore(p, 0, v);\n  return v;\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN index in `*word`: `p[i]` ≡ `wload(p, i)` — the index IS the word offset"
        (case
            ( lowlModuleBody "defun Rt.a(p: *word, i: word) -> word {\n  return p[i];\n}"
            , lowlBody "defun Rt.a(p: *word, i: word) -> word {\n  return wload(p, i);\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN index in `*val`: `p[i]` ≡ `vecload(p, i)` — the value-element stride"
        (case
            ( lowlModuleBody "defun Rt.a(p: *val, i: word) -> val {\n  return p[i];\n}"
            , lowlBody "defun Rt.a(p: *val, i: word) -> val {\n  return vecload(p, i);\n}"
            )
         of
            ( Ok f, Ok v ) ->
                canon f == canon v

            _ ->
                False
        )
    , check "A2 PIN index in `*S` (literal): `p[1]` ≡ `wload(p, 2)` — the index scaled by sizeof S=2, folded to the literal"
        (case
            ( lowlModuleBody "struct S { f : word; g : word; }\ndefun Rt.a(p: *S) -> word {\n  return p[1];\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  return wload(p, 2);\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN index in `*S` (computed): `p[i]` lowers to `RawWordLoad{p, i * 2}` (the RMul scale, not a mis-scaled literal)"
        (case lowlModuleBody "struct S { f : word; g : word; }\ndefun Rt.a(p: *S, i: word) -> word {\n  return p[i];\n}" of
            Ok body ->
                canon body == canon (Unsafe (RawWordLoad { ptr = ltv 1, index = limul (ltv 2) (ltn 2) }))

            Err _ ->
                False
        )
    , check "A2 PIN index store in `*S`: `p[1] = 9;` ≡ `wstore(p, 2, 9);` — the store scaled the same way"
        (case
            ( lowlModuleBody "struct S { f : word; g : word; }\ndefun Rt.a(p: *S) -> word {\n  p[1] = 9;\n  return 0;\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  wstore(p, 2, 9);\n  return 0;\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN deref: `*p` ≡ `wload(p, 0)`"
        (case
            ( lowlModuleBody "defun Rt.a(p: *word) -> word {\n  return *p;\n}"
            , lowlBody "defun Rt.a(p: *word) -> word {\n  return wload(p, 0);\n}"
            )
         of
            ( Ok f, Ok w ) ->
                canon f == canon w

            _ ->
                False
        )
    , check "A2 PIN chained pointer field: `p->next->x` composes through the struct table (each hop its own offset — the second hop reads Offset 1 of A through the `*A` field at Offset 0)"
        (case lowlModuleBody "struct A { next : *A; x : word; }\ndefun Rt.a(p: *A) -> word {\n  return p->next->x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (Unsafe
                            (RawWordLoad
                                { ptr = Unsafe (RawWordLoad { ptr = ltv 1, index = ltn 0 })
                                , index = ltn 1
                                }
                            )
                        )

            Err _ ->
                False
        )

    -- ==================== A3: stage A's EXIT GATE ====================
    -- (1) THE .ssa-LEVEL EQUALITY PIN — the strongest form of A2's tree pin
    -- (plan §3 risk R1).  A2 proved the two spellings lower to the SAME Mid.Ir
    -- tree; this proves that equality SURVIVES codegen: the defun written with
    -- `p->g` and the SAME defun written with `wload(p, 1)` go through the REAL
    -- pipeline (parse -> check -> LowerToIr -> Mid.Qbe.Lower -> Print) and emit
    -- the SAME .ssa TEXT.  A tree equality the EMITTER does not honour (a typed
    -- raw node, a spelling-dependent temp, a second lowering path reached only
    -- by one spelling) shows HERE even though the trees matched.  The fixture is
    -- the real shape a user `.mid` writes (the A2 smoke program): a word LOCAL
    -- from `rawcall malloc`, not a param — a param's ABI would differ from the
    -- wload module's unless both are spelled identically, which would make the
    -- row compare ABI, not the field access.  ASYMMETRY: a one-word offset
    -- mutation in LowerToIr's fieldLoad makes the read row FAIL (scratch-mutated,
    -- rebuilt, observed; see handoff-midlang-a3-result).
    , check "A3 .ssa PIN field read IS its wload spelling: `p->g` and `wload(p, 1)` emit the SAME .ssa TEXT through the REAL pipeline (parse -> check -> LowerToIr -> Qbe.Lower -> Print)"
        (case ( emitUserSsa rt a3FieldReadMid, emitUserSsa rt a3WloadReadMid ) of
            ( Ok fieldSsa, Ok wloadSsa ) ->
                fieldSsa
                    == wloadSsa
                    && String.contains "loadl" fieldSsa
                    && String.length fieldSsa
                    > 200

            _ ->
                False
        )
    , check "A3 .ssa PIN field store IS its wstore spelling: `p->g = 7;` and `wstore(p, 1, 7);` emit the SAME .ssa TEXT"
        (case ( emitUserSsa rt a3FieldStoreMid, emitUserSsa rt a3WstoreStoreMid ) of
            ( Ok fieldSsa, Ok wloadSsa ) ->
                fieldSsa
                    == wloadSsa
                    && String.contains "storel" fieldSsa
                    && String.length fieldSsa
                    > 200

            _ ->
                False
        )

    -- (2) THE ANTI-EMPTY CENSUS.  This repo has shipped a battery that ran zero
    -- parts and "passed", so the new AST constructors are counted, not assumed:
    -- each of EField/EIndex/EDeref/SFieldStore/SIndexStore/StructDecl/EnumDecl/
    -- ExternDecl must appear >= 1 time in a PARSED fixture, and the CONTROL row proves the
    -- walker cannot report a trivially-positive count (it reports 0 for every one
    -- of them on a fixture that carries none, while still counting a form that
    -- fixture does carry).  The fixture nests the forms inside an `if` whose
    -- blocks are a Stmt list + a Term, so a walker that forgets to descend fails
    -- the census row.
    , check "A3 ANTI-EMPTY census: every new AST constructor (EField, EIndex, EDeref, SFieldStore, SIndexStore, StructDecl, EnumDecl, ExternDecl) is counted >= 1 in a parsed fixture — nested in an if's blocks, so the walk must descend"
        (let
            counts =
                censusOfSource a3CensusMid
         in
         List.all (\tag -> tagCount tag counts > 0) a3CensusTags
            && tagCount "EField" counts
            >= 2
            && tagCount "EDeref" counts
            >= 2
        )
    , check "A3 census CONTROL (the count cannot be trivially nonzero): the same walk over a fixture carrying NONE of the new forms reports 0 for every one of them, and still counts a form that fixture does carry"
        (let
            counts =
                censusOfSource "defun C.b(a: word, b: word) -> word {\n  word z = a + b;\n  return z;\n}"
         in
         List.all (\tag -> tagCount tag counts == 0) a3CensusTags
            && tagCount "SBind" counts
            > 0
            && tagCount "EWordBin" counts
            > 0
        )

    -- (3) THE ONE-TABLE ROW (the negative pin for the layout's ONE definition).
    -- A2 made LowerToIr IMPORT Check.fieldOffset/sizeofStruct instead of keeping
    -- its own layout; this row fails if a SECOND copy ever appears, by asserting
    -- the constant the lowerer emits IS the value the checker's table computes
    -- (the val field's 5-word inline size is the part a hand-rolled second copy
    -- gets wrong first: a 1-word val field would put `c` at 2, not 6).
    , check "A3 ONE TABLE (offset): the constant LowerToIr emits for `p->a` IS Check.fieldOffset's value — a second layout copy in the lowerer shows here as a different constant"
        (case ( lowlModuleBody a3OffsetMidA, Check.fieldOffset (declsOf a3OffsetDecls) "M" "a" ) of
            ( Ok a, Just offA ) ->
                wordLoadIndexOf a
                    == Just offA
                    && offA
                    == 0

            _ ->
                False
        )
    , check "A3 ONE TABLE (offset past a val field): `p->c` sits at BYTE 48 (word 6) — the checker's byte offset, and the emitted word index IS that offset / 8, so a hand-rolled second copy that sized the val field at 1 word would emit 2 here"
        (case ( lowlModuleBody a3OffsetMidC, Check.fieldOffset (declsOf a3OffsetDecls) "M" "c" ) of
            ( Ok c, Just offC ) ->
                wordLoadIndexOf c
                    == Just (offC // 8)
                    && offC
                    == 48

            _ ->
                False
        )
    , check "A3 ONE TABLE (scale): `p[i]` in `*M` multiplies the index by Check.sizeofStruct M — the element scale and the offset table are the SAME value"
        (case ( lowlModuleBody a3ScaleMid, Check.sizeofStruct (declsOf a3OffsetDecls) "M" ) of
            ( Ok body, Just size ) ->
                canon body
                    == canon
                        (Unsafe
                            (RawWordLoad
                                { ptr = ltv 1
                                , index = limul (ltv 2) (ltn size)
                                }
                            )
                        )

            _ ->
                False
        )

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
    , check "M2 header: the runtime.mid module is named Rt and its export block names the crossed keys (read-file-as-string, exec-run, main, frame-enter, frame-leave + stage 7A's applier seat apply-at + ZIGHOST Z1's six root-registry WRITE seats — the keys the port widens the block for, each because a Mid PROGRAM must be able to reach it and J2 lets a user module call only EXPORTED keys)"
        (rt.header.name == Just "Rt"
            && List.map .key rt.header.exports
            == [ "Rt.read-file-as-string", "Rt.exec-run", "Rt.main", "Rt.frame-enter", "Rt.frame-leave", "Rt.apply-at", "Rt.rootPushValueArray", "Rt.rootPushValue", "Rt.rootPushPtr", "Rt.rootPop", "Rt.rootWatermark", "Rt.rootPopTo" ]
        )

    -- ==================== M3: user .mid modules ====================
    -- The namespace rule (the module NAME qualifies every key), the SAME
    -- Parse->Check->LowerToIr pipeline as runtime.mid, and the collision
    -- rules defined against the export block's namespace.
    , check "M3 namespace: a well-formed user module parses, and its keys are module-name-qualified defuns"
        (case Rt.parseUserModule ("module UserMid\nexport UserMid.answer : val -> val -> val\ndefun UserMid.answer(a: val, b: val) -> val {\n  return mknum(payload(a, 0) + payload(b, 0));\n}") of
            Ok m ->
                m.name
                    == "UserMid"
                    && List.map .key m.exports
                    == [ "UserMid.answer" ]
                    && List.map .key m.ast
                    == [ "UserMid.answer" ]
                    && m.decls
                    == []

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

    -- A2: THE USER-MODULE DECL GAP (A1's trade-off 3).  `parseUserModule` used
    -- to return a 3-tuple that silently DROPPED `module_.decls`, so a user .mid
    -- carrying a `struct` parsed it into nothing before the checker (the runtime
    -- lane was threaded, the user lane was not).  The record now carries decls,
    -- and `checkLowerUserModule` threads them into the SAME `Check.checkModule`
    -- (decl-carrying) + `LowerToIr.lowerModule` the runtime lane uses.  ASYMMETRY:
    -- before the fix, row 1's `*S` param had no struct table ("names no declared
    -- struct", Err) and row 3's bad decl was never checked (silently Ok).
    , check "A2 user decls: a user .mid that declares a STRUCT checks + lowers (the decls the parse used to drop now reach the checker), and its defun reads a field"
        (case Rt.parseUserModule "module U\nexport U.read : val -> val\nstruct S { f : word; }\ndefun U.read(a: val) -> val {\n  *S p = payload(a, 0);\n  return mknum(p->f);\n}" of
            Ok parsed ->
                not (List.isEmpty parsed.decls)
                    && (case Rt.checkLowerUserModule rt.exportedTypes parsed of
                            Ok m ->
                                List.map .key m.defuns == [ "U.read" ]

                            Err _ ->
                                False
                       )

            Err _ ->
                False
        )
    , check "A2 user decls: a user module's struct is usable in its OWN defuns — a field READ, a field STORE and a scaled `p[i]`, all through the user lane"
        (case Rt.parseUserModule "module U\nexport U.rw : val -> val\nstruct S { f : word; g : word; }\ndefun U.rw(a: val) -> val {\n  *S p = payload(a, 0);\n  p->f = p->g + p[1];\n  return mknum(p->f);\n}" of
            Ok parsed ->
                case Rt.checkLowerUserModule rt.exportedTypes parsed of
                    Ok m ->
                        List.map .key m.defuns == [ "U.rw" ]

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "A2 user decls: a BAD decl in a user .mid still fails LOUDLY — a float struct field is J11's reject, through the same checkLowerUserModule the user lane uses (before A2 it was dropped and never checked)"
        (case Rt.parseUserModule "module U\nexport U.f : val -> val\nstruct S { f : float; }\ndefun U.f(a: val) -> val {\n  return mknil;\n}" of
            Ok parsed ->
                case Rt.checkLowerUserModule rt.exportedTypes parsed of
                    Err msg ->
                        String.contains "float field" msg

                    Ok _ ->
                        False

            Err _ ->
                False
        )
    , check "A2 user decls (loadUserMids): the group path threads a struct-declaring .mid through to a lowered defun too (not only checkLowerUserModule)"
        (case QbeModule.loadUserMids rt [ "module U\nexport U.read : val -> val\nstruct S { f : word; }\ndefun U.read(a: val) -> val {\n  *S p = payload(a, 0);\n  return mknum(p->f);\n}" ] of
            Ok [ m ] ->
                List.map .key m.defuns == [ "U.read" ]

            Ok _ ->
                False

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
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (Dict.fromList [ ( "A.f", 1 ), ( "B.g", 1 ) ]) (mA.defuns ++ mB.defuns) "A.f" of
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
                        case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (Dict.fromList [ ( "A.f", 1 ) ]) mA.defuns "A.f" of
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
                        rtProgram rt True True True ++ rtProgramGc rt True True True ++ mA.defuns
                in
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities prog) prog "A.f" of
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
    -- handoff-midlang-grefs: the census gap B5 MEASURED.  `payload(call
    -- A.helper(k), 0)` lowers to `RawWordLoad { ptr = RawCall .., index = 0 }`,
    -- and `grefsOf`'s Unsafe arm used to take the edge from a RawCall NODE only
    -- — a call sitting in a raw node's other operand was invisible, the callee
    -- was never reached, never emitted, and the program failed to LINK with an
    -- undefined `q_A_x2ehelper` (MEASURED before the fix, on this exact
    -- program).  The failure was loud but the wrong one, and `payload(f(x), 0)`
    -- is idiomatic, so the row pins the CALLEE IN THE EMITTED SET.
    , check "grefs (raw operand): a val-ABI `call` sitting INSIDE a raw node's operand — `payload(call A.helper(a), 0)` — IS a reachability edge, so the callee is EMITTED (fail-before: the link's undefined q_A_x2ehelper)"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.helper(k: val) -> val {\n  return mknum(payload(k, 0) + 1);\n}\ndefun A.f(a: val) -> val {\n  return mknum(payload(call A.helper(a), 0));\n}" ] of
            Ok [ mA ] ->
                let
                    prog =
                        rtProgram rt True True True ++ rtProgramGc rt True True True ++ mA.defuns
                in
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities prog) prog "A.f" of
                    Ok mod ->
                        List.any (\f -> f.name == "q_A_x2ehelper") mod.funcs

                    Err _ ->
                        False

            _ ->
                False
        )
    -- The same edge one level in: a val-ABI call as an ARGUMENT of another
    -- val-ABI call is a `RawCall` inside a RawCall's arg list, which the raw
    -- arm now walks (it used to return the callee's own edge and stop).
    , check "grefs (call in a call's argument): `call A.id(call A.helper(a))` emits BOTH callees — the raw arm walks a RawCall's own args too"
        (case QbeModule.loadUserMids rt [ "module A\nexport A.f : val -> val\ndefun A.helper(k: val) -> val {\n  return mknum(payload(k, 0) + 1);\n}\ndefun A.id(x: val) -> val {\n  return x;\n}\ndefun A.f(a: val) -> val {\n  return call A.id(call A.helper(a));\n}" ] of
            Ok [ mA ] ->
                let
                    prog =
                        rtProgram rt True True True ++ rtProgramGc rt True True True ++ mA.defuns
                in
                case QbeLower.lower rt False False False True True True True False False True QbeTypes.empty (rtArities prog) prog "A.f" of
                    Ok mod ->
                        List.any (\f -> f.name == "q_A_x2ehelper") mod.funcs
                            && List.any (\f -> f.name == "q_A_x2eid") mod.funcs

                    Err _ ->
                        False

            _ ->
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
    , checkOk "check: J1 accept — a bare word compare IS an if condition now (stage 6 P1c word cond; no mkbool)"
        "defun Rt.wordcond(n: word) -> val {\n  if (n == 1) { return mknil; } else { return mkbool(1); }\n}"
    , checkOk "check: J1 accept — the old boxed spelling still checks (the :val compatibility seat)"
        "defun Rt.valcond(n: word) -> val {\n  if (mkbool(n == 1)) { return mknil; } else { return mkbool(1); }\n}"
    , checkErr "check: J1 REJECT — a word-VALUED '?:' join as an if condition (its value needs a slot; no bare word test)"
        "J1"
        "defun Rt.badjoincond(n: word) -> val {\n  if ((n == 1) ? 1 : 0) { return mknil; } else { return mkbool(1); }\n}"
    , checkErr "check: J1 REJECT — a bare word literal as an if condition (jnz on a constant is not a test)"
        "J1"
        "defun Rt.badlit(n: word) -> val {\n  if (1) { return mknil; } else { return mkbool(1); }\n}"
    , checkErr "check: J1 REJECT — a bare word variable as an if condition (its representation is the lowering's)"
        "J1"
        "defun Rt.badvar(a: val) -> val {\n  word x = payload(a, 0);\n  if (x) { return mknil; } else { return mkbool(1); }\n}"
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

    , check "lower: a WORD cond stays UNBOXED — `if (n == 1)` lowers to If { cond = RawCmp } (no mkbool wrapper), the :val branches unchanged"
        (case lowlBody "defun Rt.wc(n : word) -> val {\n  if (n == 1) { return mknil; } else { return mkbool(1); }\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lcmpW RCeq (ltv 1) (ltn 1))
                            lmkNilV
                            (lmkBool (ltn 1))
                        )

            Err _ ->
                False
        )

    , check "lower: a boxed :val cond still lowers EXACTLY as before — `mkbool(n == 1)` wraps the word in RawMkValue tagBoolean"
        (case lowlBody "defun Rt.vc(n : word) -> val {\n  if (mkbool(n == 1)) { return mknil; } else { return mkbool(1); }\n}" of
            Ok body ->
                canon body
                    == canon
                        (liff (lmkBool (lcmpW RCeq (ltv 1) (ltn 1)))
                            lmkNilV
                            (lmkBool (ltn 1))
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

    , check "THE FLIP IN A `rawAbi` (WORD) DEFUN: the same exit holds where the defun's ABI is the all-word one and its value is a `word` — `defun Rt.w(n : word) -> word { if (mkbool(n == 0)) { return 1; } else { return 2; } return 7; }` lowers to `If c (1) (2)` with the 7 dropped, so the flip is a property of the STATEMENT FORM and not of the `:val` class (the 69 migrated runtime.mid sites are all `:val`; this row is the other ABI)"
        (case
            lowlModuleBody "defun Rt.w(n : word) -> word {\n  if (mkbool(n == 0)) {\n    return 1;\n  } else {\n    return 2;\n  }\n  return 7;\n}"
         of
            Ok e ->
                canon e
                    == canon
                        (liff (lmkBool (lcmpW RCeq (ltv 1) (ltn 0)))
                            (ltn 1)
                            (ltn 2)
                        )

            Err _ ->
                False
        )
    , check "THE FLIP IN THE EMITTED .ssa: a user module whose answer depends on the early exit — `if (c) { return mknum(11); } else { return mknum(22); } return mknum(424242);` — emits NO 424242 (the dead tail is not lowered, so the program cannot return it) while the branch test survives, i.e. the answer is 11 or 22 and never the pre-flip 424242"
        (case emitUserSsa rt "module Flipf\ndefun Flipf.g(c : val) -> val {\n  if (mkbool(tagis(c, 1) == 1)) {\n    return mknum(11);\n  } else {\n    return mknum(22);\n  }\n  return mknum(424242);\n}" of
            Ok ssa ->
                not (String.contains "424242" ssa) && String.contains "jnz" ssa

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
                                                    , b = Unsafe (RawTagIs { value = ltv 1, tag = RtLayout.valLayout.tagNil })
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
        "T17/T18/T20/T21/T22/T24 pipeline (the wave-9 + collector + never-scheduled + T24 key-set row, post-T24's one-hundred-sixty-two, + GC-ARC F1's two stats defuns = one-hundred-sixty-four, + stage 7 O3-fix's Rt.applyPartGo = one-hundred-sixty-five, + GC ARC unit 4's Rt.gcEnvNum = one-hundred-sixty-six, + GC ARC unit 1b's Rt.gcGrow = one-hundred-sixty-seven, + GC ARC unit 2's THREE verifier defuns Rt.gcVD/Rt.gcVerify/Rt.gcVerifyList = one-hundred-seventy, + prof-fixes unit 1's two STACK-DEPTH loop helpers Rt.countGo/Rt.bytesOfGo = one-hundred-seventy-two): surf is Ok with EXACTLY the one-hundred-seventy migrated keys under the default flags — T24 added the LAST THREE wall-class holdouts (Rt.readFileGo, Rt.epCmd, Rt.childCd), so the DSL-bodied set is now EMPTY — the TWENTY exec-plan RUN keys (applyOneRedir, applyRedirects, bodyWriteGo, childBuiltin, childPwd, closeCmdTmpfds, closeOthersGo, closePipeTmpfds, closePipesGo, echoGo, envHome, exec-run, exec-plan, execGo, isChildBuiltin, mkTmpAt, openBodyTmpfile, runBuiltinInprocess, wireCmdGo, wirePipeGo — the RUN machinery incl. the 7-mode execGo state machine; childCd stays DSL-side) on top of the T16 ep* decode keys — the TWENTY ep* decode keys (epArgvGo, epChain, epCount, epCountStdin, epElem, epFreeArgv, epFreeChains, epFreeCmd, epFreeCmds, epFreeRedirs, epNum, epPipeGo, epPipeline, epProg, epProgGo, epRedir, epRedirsGo, epStr, epSymIs, epSymOf — the epUnwrap template written out; epCmd stays DSL-side) on top of the nine glob keys, the fd/process + string/value, records/vector, number/string and equality families, with the equality AND consArr guard families still collapsing into one dict entry per key; T18 adds the TWELVE collector keys (allocRaw, allocVector, collect, gcAlloc, gcAllocGo, gcDrain, gcInit, gcMarkPtr, gcMarkValue, gcMarkRoots, gcScanValueArray, gcSweep — the whole mark-sweep, the second DSL copy deleted) + GC NURSERY's TEN scavenge-family defuns = one-hundred-eighty-two, + O5's FIVE string-stream registry defuns = one-hundred-eighty-seven, + O5 seat 2's NINE intern-table defuns = one-hundred-ninety-six, + O5 seat 3's Rt.valScanGo = one-hundred-ninety-seven (a silently-lost or silently-added surface defun shows here)"
        (case rt.surf [ Ast.ConsArr, Ast.Rec, Ast.EqPtrFast ] of
            Ok s ->
                List.sort (Dict.keys s)
                    == [ "Rt.*", "Rt.+", "Rt.-", "Rt./", "Rt.<", "Rt.<-address"
                       , "Rt.<=", "Rt.=", "Rt.>", "Rt.>=", "Rt.@p", "Rt.absvector"
                       , "Rt.address->", "Rt.allocRaw", "Rt.allocVector", "Rt.apply", "Rt.apply-at"
                       , "Rt.apply-tail", "Rt.applyGo", "Rt.applyOneRedir", "Rt.applyPartGo", "Rt.applyRedirects", "Rt.applyTailGo"
                       , "Rt.argErrFloat", "Rt.argErrGo", "Rt.argErrInt", "Rt.argHasFloatCh", "Rt.argIsFloat", "Rt.argWs"
                       , "Rt.argvGo", "Rt.argvInstall", "Rt.argvPush", "Rt.asF"
                       , "Rt.assoc", "Rt.assocGo", "Rt.bitwise-and", "Rt.bitwise-not", "Rt.bitwise-or", "Rt.bitwise-shift-left"
                       , "Rt.bitwise-shift-right", "Rt.bitwise-shift-right-zf", "Rt.bitwise-xor", "Rt.bodyWriteGo", "Rt.boot", "Rt.bounce", "Rt.bounceGo"
                       , "Rt.byteCopyGo", "Rt.bytesBuild", "Rt.bytesEqGo", "Rt.bytesToStr", "Rt.c-strlen", "Rt.cStrCopyGo"
                       , "Rt.cStrEq", "Rt.cStrEqGo", "Rt.cStrEqLit", "Rt.cStrFill", "Rt.cStrLenGo", "Rt.callArity"
                       , "Rt.cd", "Rt.char-code", "Rt.childBuiltin", "Rt.childCd", "Rt.childPwd", "Rt.close"
                       , "Rt.closeCmdTmpfds", "Rt.closeOthersGo", "Rt.closePipeTmpfds", "Rt.closePipesGo", "Rt.closure", "Rt.closureFill"
                       , "Rt.cn", "Rt.cn2", "Rt.collect", "Rt.con", "Rt.conFill", "Rt.cons"
                       , "Rt.cons?", "Rt.copyWords", "Rt.copyWordsGo", "Rt.countGo", "Rt.countL", "Rt.deepEq"
                       , "Rt.die", "Rt.dieErr", "Rt.digitCount", "Rt.echoGo", "Rt.empty?", "Rt.emptylist", "Rt.envHome"
                       , "Rt.epArgvGo", "Rt.epChain", "Rt.epCmd", "Rt.epCount", "Rt.epCountStdin", "Rt.epElem"
                       , "Rt.epFreeArgv", "Rt.epFreeChains", "Rt.epFreeCmd", "Rt.epFreeCmds", "Rt.epFreeRedirs", "Rt.epNum"
                       , "Rt.epPipeGo", "Rt.epPipeline", "Rt.epProg", "Rt.epProgGo", "Rt.epRedir", "Rt.epRedirsGo"
                       , "Rt.epStr", "Rt.epSymIs", "Rt.epSymOf", "Rt.exec-plan", "Rt.exec-run", "Rt.execGo"
                       , "Rt.f/", "Rt.fDigit", "Rt.fEmit", "Rt.fEmitByte", "Rt.fExpAt", "Rt.fExpGo", "Rt.fRender"
                       , "Rt.fShortest", "Rt.fillGo", "Rt.floatCopy", "Rt.floatText", "Rt.frame-enter", "Rt.frame-leave", "Rt.frameBlock"
                       , "Rt.gcAlloc", "Rt.gcAllocGo", "Rt.gcClearClasses", "Rt.gcDrain", "Rt.gcEnvNum", "Rt.gcGrow", "Rt.gcInit", "Rt.gcMarkPtr"
                       , "Rt.gcMarkRoots", "Rt.gcMarkValue", "Rt.gcMarkValuesTab", "Rt.gcNum", "Rt.gcNumOut", "Rt.gcPromoteAlloc"
                       , "Rt.gcScanValueArray", "Rt.gcScavCopyWords", "Rt.gcScavDrain", "Rt.gcScavOne", "Rt.gcScavPtr"
                       , "Rt.gcScavRemembered", "Rt.gcScavRoots", "Rt.gcScavValue", "Rt.gcScavValueArray", "Rt.gcScavValuesTab", "Rt.gcScavenge"
                       , "Rt.gcSweep", "Rt.gcVD", "Rt.gcVerify", "Rt.gcVerifyList"
                       , "Rt.getcwd", "Rt.getenv", "Rt.getpid", "Rt.glob", "Rt.globBuildGo", "Rt.globIsDot"
                       , "Rt.globIsDotDot", "Rt.globLastSlash", "Rt.globScanGo", "Rt.globSortGo", "Rt.globSortShift", "Rt.globStrLess", "Rt.globalClosure"
                       , "Rt.halt", "Rt.hostAddPoll", "Rt.hostArity", "Rt.hostCStrOf", "Rt.hostCall", "Rt.hostCleanupAll"
                       , "Rt.hostCleanupGo", "Rt.hostClearFrom", "Rt.hostClearGo", "Rt.hostCloseFd", "Rt.hostCompleteErr", "Rt.hostCompleteOk"
                       , "Rt.hostCompleteReady", "Rt.hostCompleteReadyGo", "Rt.hostDeactivate", "Rt.hostDeliver", "Rt.hostDieErr", "Rt.hostDirIsDir"
                       , "Rt.hostDirRecord", "Rt.hostDispatch", "Rt.hostDrainReady", "Rt.hostDrainReadyGo", "Rt.hostEpCbuf", "Rt.hostEpFreePlan"
                       , "Rt.hostExErrEof", "Rt.hostExErrGrow", "Rt.hostExOutEof", "Rt.hostExOutGrow", "Rt.hostExecChild", "Rt.hostExecComplete"
                       , "Rt.hostExecDrainErr", "Rt.hostExecDrainErrGo", "Rt.hostExecDrainOut", "Rt.hostExecDrainOutGo", "Rt.hostFlushExpiredSleeps", "Rt.hostInit"
                       , "Rt.hostIsProgram", "Rt.hostLeafExec", "Rt.hostLeafListDir", "Rt.hostLeafReadFile", "Rt.hostLeafStat", "Rt.hostLineGrow"
                       , "Rt.hostListDirChunk", "Rt.hostListDirDrain", "Rt.hostNearestSleep", "Rt.hostNowMs", "Rt.hostPollEntry", "Rt.hostPollFd"
                       , "Rt.hostPollTimeout", "Rt.hostPushFrame", "Rt.hostReadFileComplete", "Rt.hostReadFileDrain", "Rt.hostReadLine", "Rt.hostReadLineLoop"
                       , "Rt.hostReapBlockGo", "Rt.hostReapBlocking", "Rt.hostReapChildren", "Rt.hostReapGo", "Rt.hostRebuildPollGo", "Rt.hostRebuildPollfds"
                       , "Rt.hostRegisterChild", "Rt.hostRfGrow", "Rt.hostRun", "Rt.hostRunLoop", "Rt.hostRunnableScan", "Rt.hostSetNonblocking"
                       , "Rt.hostSingleCommandArgv", "Rt.hostSleepComplete", "Rt.hostSleepScan", "Rt.hostSpawn", "Rt.hostSpawnAt", "Rt.hostSpawnFind"
                       , "Rt.hostSpawnFromCmd", "Rt.hostStatRecord", "Rt.hostStep", "Rt.hostStepAll", "Rt.hostStepAllGo", "Rt.hostStepGo"
                       , "Rt.hostWriteAll", "Rt.hostWriteFileLeaf", "Rt.hostWriteStr", "Rt.intBytesEq", "Rt.intFindGo"
                       , "Rt.intGrow", "Rt.intInsert", "Rt.intInsertAt", "Rt.intInsertGo", "Rt.intPairsCopy", "Rt.intStrCopy"
                       , "Rt.intTab", "Rt.intern", "Rt.isChildBuiltin", "Rt.join", "Rt.joinFill", "Rt.joinLen"
                       , "Rt.main"
                       , "Rt.memGo", "Rt.metaGo", "Rt.mkTmpAt", "Rt.numFill", "Rt.numText", "Rt.number?"
                       , "Rt.open", "Rt.openBodyTmpfile", "Rt.parseArg", "Rt.parseArgsGo", "Rt.printValue", "Rt.pvByte", "Rt.pvN"
                       , "Rt.pvNeed", "Rt.pvRec", "Rt.pvS", "Rt.pvV", "Rt.pvZ", "Rt.read-byte", "Rt.read-file-as-string", "Rt.readFileGo"
                       , "Rt.readFull", "Rt.recAppend", "Rt.recAppendDataGo", "Rt.recAppendFind", "Rt.recAppendNamesGo", "Rt.recGet"
                       , "Rt.recGetGo", "Rt.recInsert", "Rt.recToChain", "Rt.recToChainGo", "Rt.recUpd", "Rt.recUpdCopy"
                       , "Rt.recUpdFind", "Rt.repGo", "Rt.repeat", "Rt.revGo", "Rt.rootGrow", "Rt.rootPop"
                       , "Rt.rootPopTo", "Rt.rootPush", "Rt.rootPushPtr", "Rt.rootPushValue", "Rt.rootPushValueArray", "Rt.rootWatermark"
                       , "Rt.runBuiltinInprocess", "Rt.setenv"
                       , "Rt.shen.bytes->string", "Rt.shen.str->bytes", "Rt.snd", "Rt.ssClose", "Rt.ssIn", "Rt.ssInGo"
                       , "Rt.ssReadbyte", "Rt.ssTab", "Rt.str", "Rt.strOf", "Rt.string?"
                       , "Rt.substring", "Rt.symEq", "Rt.symLess", "Rt.symToStr", "Rt.tail-known"
                       , "Rt.toI32", "Rt.valEntry", "Rt.valFreeGo", "Rt.valScanGo", "Rt.valSlot", "Rt.value", "Rt.vecEq", "Rt.vecStorePlain", "Rt.vecStoreYoung", "Rt.wRaw", "Rt.wStr", "Rt.waitStatusCode"
                       , "Rt.wireCmdGo", "Rt.wirePipeGo", "Rt.write-byte"
                     ]

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
        "T25 splice identity (the byte-identity precondition the corpus proves at the byte level): the empty surface splices to the DSL list UNCHANGED, and with the SHIPPED surface exactly the one-hundred-and-twenty-seven appended keys (ZIGHOST Z1 added its eight root-registry defuns, Z4a its eight float-text defuns, Z4b its eight printer defuns, Z5 its boot pair) (the twenty stage-6 ABI keys + the fifty-three host defuns of stages 7A/7B/7C + stage 7 O3-fix's Rt.applyPartGo + O5's five string-stream registry defuns + O5 seat 2's nine intern-table defuns + O5 seat 3's Rt.valScanGo + O5 seat 4b's twelve entry-arg-parser/*argv* defuns) (Rt.apply, Rt.apply-tail, Rt.applyGo, Rt.applyTailGo, Rt.bounce, Rt.bounceGo, Rt.cStrEq, Rt.cStrEqGo, Rt.callArity, Rt.copyWords, Rt.copyWordsGo, Rt.die, Rt.frame-enter, Rt.frame-leave, Rt.frameBlock, Rt.halt, Rt.main, Rt.metaGo, Rt.parseArgsGo, Rt.tail-known) are appended — for all 8 flag combos the spliced program's key ORDER is the DSL union list's ++ the sorted append set"
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
                                    List.map .key spliced == List.map .key union ++
                                               [ "Rt.apply", "Rt.apply-at", "Rt.apply-tail", "Rt.applyGo"
                                                 , "Rt.applyPartGo", "Rt.applyTailGo"
                                                 , "Rt.argErrFloat", "Rt.argErrGo", "Rt.argErrInt", "Rt.argHasFloatCh", "Rt.argIsFloat", "Rt.argWs"
                                                 , "Rt.argvGo", "Rt.argvInstall", "Rt.argvPush"
                                                 , "Rt.boot", "Rt.bounce", "Rt.bounceGo", "Rt.cStrEq"
                                                 , "Rt.cStrEqGo", "Rt.callArity", "Rt.copyWords", "Rt.copyWordsGo"
                                                 , "Rt.die", "Rt.dieErr"
                                                 , "Rt.fDigit", "Rt.fEmit", "Rt.fEmitByte", "Rt.fExpAt", "Rt.fExpGo"
                                                 , "Rt.fRender", "Rt.fShortest", "Rt.floatText"
                                                 , "Rt.frame-enter", "Rt.frame-leave"
                                                 , "Rt.frameBlock", "Rt.halt", "Rt.hostAddPoll", "Rt.hostArity", "Rt.hostCStrOf", "Rt.hostCall"
                                                 , "Rt.hostCleanupAll", "Rt.hostCleanupGo", "Rt.hostClearFrom", "Rt.hostClearGo", "Rt.hostCloseFd"
                                                 , "Rt.hostCompleteErr", "Rt.hostCompleteOk", "Rt.hostCompleteReady", "Rt.hostCompleteReadyGo", "Rt.hostDeactivate", "Rt.hostDeliver"
                                                 , "Rt.hostDieErr", "Rt.hostDirIsDir", "Rt.hostDirRecord", "Rt.hostDispatch", "Rt.hostDrainReady"
                                                 , "Rt.hostDrainReadyGo", "Rt.hostEpCbuf", "Rt.hostEpFreePlan", "Rt.hostExErrEof", "Rt.hostExErrGrow", "Rt.hostExOutEof", "Rt.hostExOutGrow", "Rt.hostExecChild", "Rt.hostExecComplete", "Rt.hostExecDrainErr", "Rt.hostExecDrainErrGo", "Rt.hostExecDrainOut", "Rt.hostExecDrainOutGo", "Rt.hostFlushExpiredSleeps", "Rt.hostInit", "Rt.hostIsProgram", "Rt.hostLeafExec", "Rt.hostLeafListDir"
                                                 , "Rt.hostLeafReadFile", "Rt.hostLeafStat", "Rt.hostLineGrow", "Rt.hostListDirChunk", "Rt.hostListDirDrain", "Rt.hostNearestSleep", "Rt.hostNowMs"
                                                 , "Rt.hostPollEntry", "Rt.hostPollFd", "Rt.hostPollTimeout", "Rt.hostPushFrame"
                                                 , "Rt.hostReadFileComplete", "Rt.hostReadFileDrain", "Rt.hostReadLine", "Rt.hostReadLineLoop", "Rt.hostReapBlockGo", "Rt.hostReapBlocking", "Rt.hostReapChildren", "Rt.hostReapGo"
                                                 , "Rt.hostRebuildPollGo", "Rt.hostRebuildPollfds", "Rt.hostRegisterChild", "Rt.hostRfGrow", "Rt.hostRun"
                                                 , "Rt.hostRunLoop", "Rt.hostRunnableScan", "Rt.hostSetNonblocking", "Rt.hostSingleCommandArgv", "Rt.hostSleepComplete"
                                                 , "Rt.hostSleepScan", "Rt.hostSpawn", "Rt.hostSpawnAt", "Rt.hostSpawnFind"
                                                 , "Rt.hostSpawnFromCmd", "Rt.hostStatRecord", "Rt.hostStep", "Rt.hostStepAll", "Rt.hostStepAllGo"
                                                 , "Rt.hostStepGo", "Rt.hostWriteAll", "Rt.hostWriteFileLeaf", "Rt.hostWriteStr"
                                                 , "Rt.intBytesEq", "Rt.intFindGo", "Rt.intGrow", "Rt.intInsert", "Rt.intInsertAt"
                                                 , "Rt.intInsertGo", "Rt.intPairsCopy", "Rt.intStrCopy", "Rt.intTab"
                                                 , "Rt.main", "Rt.metaGo", "Rt.parseArg", "Rt.parseArgsGo"
                                                 , "Rt.printValue", "Rt.pvByte", "Rt.pvN", "Rt.pvNeed"
                                                 , "Rt.pvRec", "Rt.pvS", "Rt.pvV", "Rt.pvZ"
                                                 , "Rt.rootGrow", "Rt.rootPop", "Rt.rootPopTo", "Rt.rootPush"
                                                 , "Rt.rootPushPtr", "Rt.rootPushValue", "Rt.rootPushValueArray", "Rt.rootWatermark"
                                                 , "Rt.ssClose", "Rt.ssIn"
                                                 , "Rt.ssInGo", "Rt.ssReadbyte", "Rt.ssTab", "Rt.tail-known"
                                                 , "Rt.valEntry", "Rt.valFreeGo", "Rt.valScanGo", "Rt.valSlot"
                                               ]

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
            , { key = "Rt.revGo", arity = 2 }
            , { key = "Rt.numText", arity = 1 }
            , { key = "Rt.digitCount", arity = 2 }
            , { key = "Rt.numFill", arity = 2 }
            , { key = "Rt.bytesToStr", arity = 1 }
            , { key = "Rt.countGo", arity = 2 }
            , { key = "Rt.countL", arity = 1 }
            , { key = "Rt.fillGo", arity = 3 }
            , { key = "Rt.cn2", arity = 2 }
            , { key = "Rt.byteCopyGo", arity = 3 }
            , { key = "Rt.symToStr", arity = 1 }
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
            , { key = "Rt.repGo", arity = 3 }
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
    -- machinery).  dgs and bytesOf are DELETED by text-fix (the
    -- cons-per-character representation they built); numText now writes its
    -- digits into one raw buffer via digitCount/numFill, and countL/fillGo
    -- survive for shen.bytes->string's byte-LIST input, over `recur` (the
    -- T11 brief's "revGo/countL/fillGo are recur" guess was refuted then by
    -- reading the builders; text-fix made fillGo a recur for real).
    , t8SplicedRow rt "Rt.asF"
    , t8SplicedRow rt "Rt.toI32"
    , t8SplicedRow rt "Rt.revGo"
    , t8SplicedRow rt "Rt.numText"
    , t8SplicedRow rt "Rt.digitCount"
    , t8SplicedRow rt "Rt.numFill"
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
    , t8SplicedRow rt "Rt.byteCopyGo"
    , t8SplicedRow rt "Rt.symToStr"
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
    , t18SplicedRow rt "Rt.gcClearClasses"
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
                                    (Ast.EBool False)
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
                case Result.map Tuple.second (loweredRuntime runtimeMidText) of
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
                case Result.map Tuple.second (loweredRuntime runtimeMidText) of
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
                case Result.map Tuple.second (loweredRuntime runtimeMidText) of
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
                case Result.map Tuple.second (loweredRuntime runtimeMidText) of
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
    , checkOk "check: ?: accept — a WORD cond with :val branches (the frameBlock shape: (nslots < 8192) ? mknum(..) : mknum(0))"
        "defun Rt.qcond(a: val) -> val {\n  val x = (payload(a, 0) == 1) ? mknum(1) : mknum(2);\n  return x;\n}"

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
    , check "lower: a WORD-cond ?: keeps the cond UNBOXED — `(payload(a,0) == 1) ? mknum(1) : mknum(2)` lowers to If { cond = RawCmp } (no mkbool)"
        (case lowlBody "defun Rt.qwc(a: val) -> val {\n  val x = (payload(a, 0) == 1) ? mknum(1) : mknum(2);\n  return x;\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2
                              , liff (lcmpW RCeq (lpay (ltv 1) 0) (ltn 1))
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
    , checkOk "check: block-if accept — a WORD cond with :val branches (the frame-leave shape)"
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

    -- ===== B1 — bool, int, literals, casts, sizeof (handoff-midlang-b1) =====
    -- The unit is CHECKER-ONLY and must stay EMISSION-NEUTRAL: the class
    -- change (`wordCmpSig`/`fltCmpSig` -> bool) moved no tree, so the corpus
    -- stays byte-identical (tools/osier-corpus-ssa.sh, the oracle), and the
    -- three byte-identity rows below pin the half a corpus gate cannot see
    -- (they compare two spellings of the SAME program, so a moved tree fails
    -- them even where no corpus group spells either).
    , check "B1 parse: `int` IS `word` — a binder, a parameter and the result all parse to TWord (one class, two spellings)"
        (Parse.parseProgram
            "defun F.g(a: int) -> int {\n  int n = a;\n  return n;\n}"
            == Ok
                [ { key = "F.g"
                  , flags = []
                  , params = [ { name = "a", ty = Ast.TWord } ]
                  , ret = Ast.TWord
                  , body =
                        { stmts = [ Ast.SBind Ast.TWord "n" (Ast.EVar "a") ]
                        , term = Ast.TRet (Ast.EVar "n")
                        }
                  }
                ]
        )
    , check "B1 parse: `*int` is `*word` (the same PWord pointee — no second pointer family)"
        (Parse.parseExp "[*int](1)"
            == Ok (Ast.ECast (Ast.TPtr Ast.PWord) (Ast.EInt 1))
        )
    , check "B1 parse: `bool b = (a == b);` is SBind TBool over an EWordCmp (the binder class, spelled ONLY in binder position)"
        (Parse.parseProgram
            "defun F.g(a: word, b: word) -> val {\n  bool c = (a == b);\n  return mknil;\n}"
            == Ok
                [ { key = "F.g"
                  , flags = []
                  , params = [ { name = "a", ty = Ast.TWord }, { name = "b", ty = Ast.TWord } ]
                  , ret = Ast.TVal
                  , body =
                        { stmts = [ Ast.SBind Ast.TBool "c" (Ast.EWordCmp Ast.WCeq (Ast.EVar "a") (Ast.EVar "b")) ]
                        , term = Ast.TRet (Ast.EBuiltin Ast.MkNil [])
                        }
                  }
                ]
        )
    , check "B6 parse (REWRITTEN from B1's reject): `bool` IS a signature type now — the parameter parses as TBool and the CHECKER is what refuses it in a value-ABI signature (the two-row pair below)"
        (Parse.parseProgram "defun F.g(b: bool) -> val {\n  return mknil;\n}"
            == Ok
                [ { key = "F.g"
                  , flags = []
                  , params = [ { name = "b", ty = Ast.TBool } ]
                  , ret = Ast.TVal
                  , body =
                        { stmts = []
                        , term = Ast.TRet (Ast.EBuiltin Ast.MkNil [])
                        }
                  }
                ]
        )
    , checkErrModule "B6 check REJECT: a `bool` parameter in a VALUE-ABI signature — a bool is a 0/1 WORD register, and the `v : val` parameter forces the value ABI (a 40-byte Value slot is not a bool)" "is a bool, which is a 0/1 word REGISTER" "defun F.g(b: bool, v: val) -> word {\n  return 1;\n}"
    , checkOkModule "B6 check ACCEPT (the control): the same bool parameter and a bool RESULT are legal in an ALL-WORD signature — the word ABI is the only place a bool parameter can exist" "defun F.g(b: bool, w: word) -> bool {\n  return b;\n}"
    , check "B1 parse: `[T](e)` casts — [bool] of a word, [word] of a bool, [*S] of a word, [val], [int]"
        (Parse.parseExp "[bool](x)" == Ok (Ast.ECast Ast.TBool (Ast.EVar "x"))
            && Parse.parseExp "[word](b)"
                == Ok (Ast.ECast Ast.TWord (Ast.EVar "b"))
            && Parse.parseExp "[*S](p)"
                == Ok (Ast.ECast (Ast.TPtr (Ast.PStruct "S")) (Ast.EVar "p"))
            && Parse.parseExp "[val](b)"
                == Ok (Ast.ECast Ast.TVal (Ast.EVar "b"))
            && Parse.parseExp "[int](x)"
                == Ok (Ast.ECast Ast.TWord (Ast.EVar "x"))
        )
    , check "B1 parse: a cast COMPOSES as an atom — [word](a) + 1 is a sum, and p[[word](a)] is an index (the bracket in atom position is a cast, never the postfix [i])"
        (Parse.parseExp "[word](a) + 1"
            == Ok (Ast.EWordBin Ast.WAdd (Ast.ECast Ast.TWord (Ast.EVar "a")) (Ast.EInt 1))
            && Parse.parseExp "p[[word](a)]"
                == Ok (Ast.EIndex (Ast.EVar "p") (Ast.ECast Ast.TWord (Ast.EVar "a")))
        )
    , check "B1 parse: `sizeof(R)` is a STRUCT target and `sizeof(*word)` a TYPE target (the two spellings Q9 names)"
        (Parse.parseExp "sizeof(R)" == Ok (Ast.ESizeof (Ast.SizeStruct "R"))
            && Parse.parseExp "sizeof(*word)"
                == Ok (Ast.ESizeof (Ast.SizeType (Ast.TPtr Ast.PWord)))
            && Parse.parseExp "sizeof(val)"
                == Ok (Ast.ESizeof (Ast.SizeType Ast.TVal))
        )
    , check "B1 parse: `'c'` is a WORD byte literal with the string escape table plus \' — and `'ab'`/an unknown escape are loud rejects"
        (Parse.parseExp "'a'" == Ok (Ast.EInt 97)
            && Parse.parseExp "'\\n'"
                == Ok (Ast.EInt 10)
            && Parse.parseExp "'\\''"
                == Ok (Ast.EInt 39)
            && Parse.parseExp "' '"
                == Ok (Ast.EInt 32)
            && (case Parse.parseExp "'ab'" of
                    Err _ ->
                        True

                    Ok _ ->
                        False
               )
            && (case Parse.parseExp "'\\q'" of
                    Err _ ->
                        True

                    Ok _ ->
                        False
               )
        )

    -- the class judgments: what bool admits, and the three shapes whose
    -- representation is NOT a temp (each refused for the lowering reason the
    -- Check header states).
    , checkOk "B1 check accept: a BOOL BINDER is branchable — `bool c = (a == b); if (c) {..}` (the seam closer: its representation is the class's)"
        "defun F.g(a: word, b: word) -> val {\n  bool c = (a == b);\n  if (c) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , checkOk "B1 check accept: the ONE implicit coercion — `val v = (a == b);` (bool->val BOXES; this was a J1 reject before the class change: the fail-before/pass-after row)"
        "defun F.g(a: word, b: word) -> val {\n  val v = (a == b);\n  return v;\n}"
    , checkOk "B1 check accept: `word w = (a == b);` STAYS legal — the plan expected zero such sites and runtime.mid has two (Rt.close's isStr), so bool->word is the identity, not a reject"
        "defun F.g(a: word, b: word) -> val {\n  word w = (a == b);\n  return mknum(w);\n}"
    , checkOk "B1 check accept: bool in WORD arithmetic — `payload(a, 0) + (x == 0)` (MEASURED: Rt.epCountStdin's shape) and mkbool(compare) (the 309-site corpus spelling)"
        "defun F.g(a: val, x: word) -> val {\n  return mknum(payload(a, 0) + (x == 0));\n}\n\ndefun F.h(x: word) -> val {\n  return mkbool(x == 1);\n}"
    , checkErr "B1 check REJECT: `if (true)` — a constant bool branch is not a test (the plan's negative row)"
        "CONSTANT bool"
        "defun F.g() -> val {\n  if (true) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , checkErrModule "B1 check REJECT: `if (sizeof(R))` — the same rule extended: a sizeof is a constant, so it is not a test either"
        "CONSTANT word"
        "struct R { aa : word; }\n\ndefun F.g() -> val {\n  if (sizeof(R)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , checkErr "B1 check REJECT: `bool b = true;` — a literary bool has no branchable lowering (Lower's raw-Int binder reboxes as a NUMBER and a value test would read tag 0: the always-then misread)"
        "not a bool TEMP"
        "defun F.g() -> val {\n  bool b = true;\n  if (b) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , checkErr "B1 check REJECT: `bool b = (fload(v) f< fload(v));` — a float compare IS a word 0/1 but is not a raw-word BINDER node, so the binder would fail in the backend instead of here (the compare itself is still a legal INLINE cond)"
        "not a bool TEMP"
        "defun F.g(v: val) -> val {\n  bool b = (fload(v) f< fload(v));\n  return mknum(1);\n}"
    , checkErr "B1 check REJECT: a bool JOIN — `bool b = c ? (a == b) : (d == e);` needs a slot, and a bool value is a raw temp"
        "branches agree on bool"
        "defun F.g(a: word, b: word, d: word, e: word, c: val) -> val {\n  bool j = c ? (a == b) : (d == e);\n  return mknum(1);\n}"
    , checkErr "B1 check REJECT: `[word](v)` — a val cast is NO cast (Q11: the opaque handle; payload/tagis are the sanctioned reads)"
        "not in the cast matrix"
        "defun F.g(v: val) -> val {\n  word w = [word](v);\n  return mknum(w);\n}"
    , checkErr "B1 check REJECT: `[val](x)` — only a BOOL boxes into a val; a word->val cast is not a row"
        "not in the cast matrix"
        "defun F.g(x: word) -> val {\n  val v = [val](x);\n  return v;\n}"
    , checkErr "B1 check REJECT: `[val](v)` — a val identity cast is refused too (Q10: val casts NONE)"
        "not in the cast matrix"
        "defun F.g(v: val) -> val {\n  val w = [val](v);\n  return w;\n}"
    , checkErrModule "B1 check REJECT: `[*S2](p)` — pointer->pointer is J12's reject spelled as a cast (go through a `word` binder)"
        "not in the cast matrix"
        "struct S1 { aa : word; }\nstruct S2 { bb : word; }\n\ndefun F.g(p: *S1) -> val {\n  *S2 q = [*S2](p);\n  return mknum(1);\n}"
    , checkErr "B1 check REJECT: an IMPLICIT float->word (no row folds it) — `word w = fload(v);`"
        "declares word but its initializer is float"
        "defun F.g(v: val) -> val {\n  word w = fload(v);\n  return mknum(w);\n}"
    , checkErr "B1 check REJECT: `sizeof(Nope)` — an unknown struct (the ONE table has no such entry)"
        "no such struct is declared"
        "defun F.g() -> val {\n  return mknum(sizeof(Nope));\n}"
    , checkErr "B1 check REJECT: `sizeof(float)` — no raw f64 seat, the J11 float-field reason"
        "no raw-memory f64 seat"
        "defun F.g() -> val {\n  return mknum(sizeof(float));\n}"

    -- THE EMISSION ROWS.  Two of them are byte-identity pins between a NEW
    -- spelling and the OLD one it replaces (so `true`/`false` and the
    -- bool->val box are proven to emit the sugar's own tree), one is the SEAM
    -- (a bool binder branches with a direct jnz on the compare's temp, with
    -- NO boolean box) with the BOXED spelling as its two-sided control, and
    -- the rest pin the cast/sizeof rows' nodes.
    , b1SameSsaRow rt "B1 .ssa IDENTITY: `return true;` emits the SAME text as `return mkbool(1);` — the bool literal's bool->val box IS the sugar's tree (the byte-identity the corpus gate cannot see, because no corpus group spells `true`)"
        "module B1t\n\ndefun B1t.f() -> val {\n  return true;\n}"
        "module B1t\n\ndefun B1t.f() -> val {\n  return mkbool(1);\n}"
    , b1SameSsaRow rt "B1 .ssa IDENTITY: `mkbool(x == y) ? false : mknum(7)` emits the SAME text as the mkbool(0) spelling (the ?: arm's implicit box — the MEASURED Rt.clone/fdIsSeekable shape)"
        "module B1t\n\ndefun B1t.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  return mkbool(x == y) ? false : mknum(7);\n}"
        "module B1t\n\ndefun B1t.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  return mkbool(x == y) ? mkbool(0) : mknum(7);\n}"
    , b1SameSsaRow rt "B1 .ssa IDENTITY: `return [val](x == y);` emits the SAME text as `return mkbool(x == y);` — the explicit box (Q10's [val](b) row) is the builtin's own tree"
        "module B1t\n\ndefun B1t.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  return [val](x == y);\n}"
        "module B1t\n\ndefun B1t.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  return mkbool(x == y);\n}"
    , check "B1 SEAM: a `bool` binder branches with a DIRECT jnz on the comparison's temp — no boolean box (`storew 3`), and the jump is true-first — where the boxed :val spelling boxes and INVERTS (the control row below)"
        (case ( emitUserSsa rt b1SeamMid, emitUserSsa rt b1BoxedMid ) of
            ( Ok seam, Ok boxed ) ->
                String.length seam > 400
                    && String.contains "jnz %" seam
                    && String.contains ", @then_0, @else_1" seam
                    && not (String.contains "storew 3" seam)
                    && not (String.contains ", @then_0, @else_1" boxed)
                    && String.contains "storew 3" boxed
                    && String.contains ", @else_1, @then_0" boxed

            _ ->
                False
        )
    , checkErr "B1 SEAM CONTRAST: the SAME program with a `word` binder is a J1 REJECT — `word c = (a == b); if (c)` (a word binder's representation is the lowering's, so only the bool class can be branchable)"
        "bare word variable"
        "defun F.g(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  word c = (x == y);\n  if (c) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , check "B1 LOWER: `[bool](w)` emits exactly ONE nonzero compare (`cnel %t, 0`) — the row's `[word](b)` identity is pinned by the byte-identity row below"
        (case emitUserSsa rt b1CastMid of
            Ok ssa ->
                String.length ssa > 400
                    && List.length (String.indexes "cnel " ssa) == 1

            Err _ ->
                False
        )
    , b1SameSsaRow rt "B1 .ssa IDENTITY: `if ([word](c))` emits the SAME text as `if (c)` — the [word] cast of a bool is NO node (Q10's identity row, proven at emit level)"
        "module B1t\n\ndefun B1t.f(a: val) -> val {\n  word x = payload(a, 0);\n  bool c = (x == 0);\n  if ([word](c)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
        "module B1t\n\ndefun B1t.f(a: val) -> val {\n  word x = payload(a, 0);\n  bool c = (x == 0);\n  if (c) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"
    , check "B1 LOWER: `sizeof(R)` is the ONE layout table's number (R = word+val+word = 7 words, emitted as a `mul 7, 1000000`) and `sizeof(*word)` is 1"
        (case ( declsOf "struct R { aa : word; bb : val; cc : word; }", emitUserSsa rt b1SzMid ) of
            ( decls, Ok ssa ) ->
                case Check.sizeofStruct decls "R" of
                    Just n ->
                        n == 7
                            && String.length ssa > 400
                            && String.contains ("mul " ++ String.fromInt n ++ ", 1000000") ssa

                    Nothing ->
                        False

            _ ->
                False
        )
    , check "B1 LOWER: a NON-literal bool at a `-> val` return goes through the box — `return (x == y);` emits `storew 3` + the payload store (no raw word in a value position)"
        (case emitUserSsa rt b1RetBoolMid of
            Ok ssa ->
                String.length ssa > 400
                    && String.contains "storew 3" ssa

            Err _ ->
                False
        )
    , check "B2 parse: `S s;` is a STRUCT-VALUE binder with ZEROED storage (SStructBind InitZero — a statement, not an SBind: the ALLOCATION is the point)"
        (Parse.parseBlock "{ Outer o;\n  return 0; }"
            == Ok
                { stmts =
                    [ Ast.SStructBind { sname = "Outer", name = "o", init = Ast.InitZero } ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B2 parse: `Outer o = { a = 1; in_.k = 7; };` — the field-wise initialiser (name = expression, each `;`-terminated)"
        (Parse.parseBlock "{ Outer o = { a = 1; in_ = t; };\n  return 0; }"
            == Ok
                { stmts =
                    [ Ast.SStructBind
                        { sname = "Outer"
                        , name = "o"
                        , init =
                            Ast.InitFields
                                [ ( "a", Ast.EInt 1 )
                                , ( "in_", Ast.EVar "t" )
                                ]
                        }
                    ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B2 parse: `Outer c = o;` is a COPY initialiser and `c = o;` the aggregate ASSIGNMENT (`SVarStore`) — the same `=` tail, a different statement"
        (Parse.parseBlock "{ Outer c = o;\n  c = o;\n  return 0; }"
            == Ok
                { stmts =
                    [ Ast.SStructBind { sname = "Outer", name = "c", init = Ast.InitCopy (Ast.EVar "o") }
                    , Ast.SVarStore "c" (Ast.EVar "o")
                    ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B2 parse: `.` IS `->` — `p.f` and `p->f` parse to the SAME AST (`EField`), and both chain (`s.inner.f`, `p->f.g`): Terra's alias, not a second form"
        (Parse.parseExp "p.f"
            == Parse.parseExp "p->f"
            && Parse.parseExp "s.inner.f" == Parse.parseExp "s->inner->f"
            && Parse.parseExp "p->f.g"
            == Ok (Ast.EField (Ast.EField (Ast.EVar "p") "f") "g")
        )
    , check "B2 parse: `&place` is the PREFIX address-of (`EAddrOf`) and never eats the infix `&` — `x & &y` is bitand-by-address-of"
        (Parse.parseExp "&s.f"
            == Ok (Ast.EAddrOf (Ast.EField (Ast.EVar "s") "f"))
            && Parse.parseExp "x & &y"
            == Ok (Ast.EWordBin Ast.WBitAnd (Ast.EVar "x") (Ast.EAddrOf (Ast.EVar "y")))
            && Parse.parseExp "&p->f.g"
            == Ok (Ast.EAddrOf (Ast.EField (Ast.EField (Ast.EVar "p") "f") "g"))
        )
    , check "B2 parse: the `.` ROUTING MOVED NO KEY — a defun header and a `call` keep their dotted keys verbatim while a body's `p.f` splits (the two readers are different on purpose)"
        (case Parse.parseProgram "defun Rt.a.b(p: *S) -> word {\n  return call Rt.getpid(p.f);\n}" of
            Ok [ d ] ->
                d.key == "Rt.a.b" && d.body.term == Ast.TRet (Ast.ECall "Rt.getpid" [ Ast.EField (Ast.EVar "p") "f" ])

            _ ->
                False
        )
    , checkErr "B2 check REJECT: a bare key in EXPRESSION position is still not an expression — `Rt.getpid` is `Rt` `.` `getpid`, so it is an unbound name (the site moved from a parse reject to a CHECK reject, never to a silent accept)" "unbound name 'Rt'"
        "defun Rt.g(a: val) -> val {\n  return Rt.getpid;\n}"
    , checkOkModule "B2 check accept: THE MILESTONE SHAPE — a struct local with a NESTED struct and a `val` field, field-wise init through `.`, `&o` bound to a `*Outer`, mutation through `p.a`/`p.in_.k`, a COPY initialiser, a nested store, and the val field read back"
        b2MilestoneMid
    , checkErrModule "B2 check REJECT: `&` of a WORD local — a scalar binder is a temp or a 40-byte slot, so there is no address to take (the struct local and the struct field are the memory-backed seats)" "'&' needs a struct value"
        "struct S { a : word; }\ndefun Rt.g() -> word {\n  word w = 1;\n  *word p = &w;\n  return 0;\n}"
    , checkOkModule "B2 check accept CONTROL for the row above: `&` of a struct FIELD is legal and types as `*word` (the storage exists)"
        "struct S { a : word; }\ndefun Rt.g() -> word {\n  S s;\n  *word p = &s.a;\n  return *p;\n}"
    , checkErrModule "B2 check REJECT: `&` of a VAL field — a GC-interior address exposed as a raw word is the unrooted-view hazard (vecaddr/payload are the sanctioned reads, plan Q11)" "unrooted-view hazard"
        "struct S { a : word; v : val; }\ndefun Rt.g() -> word {\n  S s;\n  *val p = &s.v;\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: `&p` of a POINTER — the pointer IS an address; the operand would have to be the address of the BINDER holding it, and a binder has no storage" "the pointer IS an address"
        "struct S { a : word; }\ndefun Rt.g(p: *S) -> word {\n  *word q = &p;\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: `.` on a NON-STRUCT (`w.f` on a word) — field access needs a struct value or a struct pointer" "field access needs a struct pointer or a struct value"
        "defun Rt.g(w: word) -> word {\n  return w.f;\n}"
    , checkErrModule "B2 check REJECT: a STRUCT RETURN (plan Q7 — the ret path is one word; the out-parameter is the way)" "a struct RETURN is REJECTED"
        "struct S { a : word; }\ndefun Rt.g() -> S {\n  S s;\n  return s;\n}"
    , checkOkModule "B6 check ACCEPT (REWRITTEN from B2's reject): a STRUCT PARAMETER by value in an ALL-WORD signature — the defun takes the word ABI, so the parameter has a register to live in (the caller passes its address; the callee copies it at entry)"
        "struct S { a : word; }\ndefun Rt.g(s: S) -> word {\n  return s.a;\n}"
    , checkErrModule "B6 check REJECT: the same STRUCT PARAMETER in a VALUE-ABI signature — a struct parameter is legal ONLY where the whole signature is word-class (plan Q7), and the `v : val` parameter forces the value ABI" "a struct parameter is legal only in a WORD-ABI defun"
        "struct S { a : word; }\ndefun Rt.g(s: S, v: val) -> word {\n  return s.a;\n}"
    , checkOkModule "B2 check accept CONTROL for the two rows above: a `*S` parameter and a `-> val` result are the legal spellings"
        "struct S { a : word; }\ndefun Rt.g(p: *S) -> val {\n  return mknum(p.a);\n}"
    , checkErrModule "B2 check REJECT: copying a DIFFERENT struct (`T t = o;`) — a copy needs the SAME struct value" "the SAME struct"
        "struct S { a : word; }\nstruct T { b : word; }\ndefun Rt.g() -> word {\n  S o;\n  T t = o;\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: the same field initialised TWICE (`{ a = 1; a = 2; }`)" "initialised twice"
        "struct S { a : word; }\ndefun Rt.g() -> word {\n  S s = { a = 1; a = 2; };\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: an UNKNOWN field in an initialiser" "has no field 'nope'"
        "struct S { a : word; }\ndefun Rt.g() -> word {\n  S s = { nope = 1; };\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: a struct binder SHADOWING an existing one (J5 — a binder is a NEW id, and a struct binder owns fresh storage)" "already a binder in scope"
        "struct S { a : word; }\ndefun Rt.g() -> word {\n  S s;\n  S s;\n  return 0;\n}"
    , checkErrModule "B2 check REJECT: a TWO-STRUCT by-value cycle (S { b : B } beside B { s : S }) — infinite size, the layout table's judgment" "contains itself BY VALUE"
        "struct B { s : S; }\nstruct S { b : B; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , check "B2 LAYOUT (ONE TABLE, nested + val): Outer{a:word; in_:Inner{k:word}; v:val} is 7 words — sizeof reads the nested struct's OWN size and the val's 5-word inline slot, and the offsets/width follow"
        (let
            decls =
                declsOf "struct Inner { k : word; }\nstruct Outer { a : word; in_ : Inner; v : val; }"
         in
         Check.sizeofStruct decls "Outer"
            == Just 7
            && Check.sizeofStruct decls "Inner"
            == Just 1
            && Check.structSizeBytes decls "Outer"
            == Just 56
            && Check.fieldOffset decls "Outer" "a"
            == Just 0
            && Check.fieldOffset decls "Outer" "in_"
            == Just 8
            && Check.fieldOffset decls "Outer" "v"
            == Just 16
            && Check.fieldWidth decls "Outer" "v"
            == Just 5
            && Check.fieldWidth decls "Outer" "in_"
            == Just 1
        )
    , check "B2 LOWER (re-seated by B4b): a struct binder ALLOCATES off the ONE layout table — `Outer o;` binds `RawAllocN 7` (SEVEN words of QBE stack memory = `alloc8 56`, no `malloc` call at all) for a 7-word struct, then `memset(addr, 0, 56)`, which is a memset over the frame block"
        (case lowlModuleBody b2LocalMid of
            Ok body ->
                b2LetValue body
                    == Just (Unsafe (RawAllocN 7))
                    && (case b2LetBody body of
                            Just inner ->
                                b2LetValue inner
                                    == Just (Unsafe (RawCallRaw { sym = "memset", args = [ Var 2, Lit (LNumber 0), Lit (LNumber 56) ] }))

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "B2 LOWER: `&s` on a struct VALUE is the IDENTITY — no node at all (the value IS its address), so binding it to a `*S` binds exactly the struct's binder"
        (case lowlModuleBody "struct S { a : word; }\ndefun Rt.a() -> word {\n  S s;\n  *S p = &s;\n  p.a = 3;\n  return p.a;\n}" of
            Ok body ->
                -- `S s;` -> Let s = alloc in Let dead = memset in Let p = <&s> in ..
                case b2Shell body of
                    Just (Let block) ->
                        case block.binders of
                            LetBind b :: _ ->
                                b.value == Var 1

                            _ ->
                                False

                    _ ->
                        False

            Err _ ->
                False
        )
    , check "B4 REJECT: `return &s;` on a struct LOCAL is refused — the address of an `allocN` block dies with the frame, so a returned pointer would dangle (B2's row above pinned the identity; this is the obligation that keeps it sound)"
        (case lowlModuleBody "struct S { a : word; }\ndefun Rt.a() -> *S {\n  S s;\n  return &s;\n}" of
            Err msg ->
                String.contains "returns the ADDRESS of this frame" msg

            Ok _ ->
                False
        )
    , check "B2 LOWER: `&p->b` is the field's ADDRESS — `p + 8*offset`, no load (offset 1 -> `RawBin RAdd (Var 1) (Lit 8)`); the same arithmetic the field read uses"
        (lowlModuleBody "struct S { a : word; b : word; }\ndefun Rt.a(p: *S) -> *word {\n  return &p->b;\n}"
            == Ok (Unsafe (RawBin { op = RAdd, a = Var 1, b = Lit (LNumber 8) }))
        )
    , check "B2 LOWER: the aggregate COPY is the field-wise word copy — `Outer c = o;` emits SEVEN word stores at dst offsets 0..6 (a `val` field is 5 words, a nested struct its own size: the widths are the ONE table's)"
        (case lowlModuleBody b2CopyMid of
            Ok body ->
                b2StoreOffsets body == [ 0, 1, 2, 3, 4, 5, 6 ]

            Err _ ->
                False
        )
    , check "B2 LOWER: a `val` FIELD at word 2 is addressed in BYTES — `p.v` is `RawVecLoad { vec = p + 16, index = 0 }`, NOT `vecload(p, 2)` (the vec index is a 40-byte VALUE stride; passing a word offset straight through misplaced every val field at a non-zero offset — MEASURED, unpinned by A1/A2 because their structs put the val field first)"
        (case lowlModuleBody "struct S { a : word; b : word; v : val; }\ndefun Rt.a(p: *S) -> val {\n  return p.v;\n}" of
            Ok body ->
                b2VecField body == Just (Unsafe (RawBin { op = RAdd, a = Var 1, b = Lit (LNumber 16) }), 0)

            Err _ ->
                False
        )
    , b2SameSsaRow rt "B2 .ssa: `.` IS `->` THROUGH THE WHOLE PIPELINE — `p.a + p.b` and `p->a + p->b` emit BYTE-IDENTICAL text (a `*S` binder from malloc, so the ABI is the same on both sides)"
        (b2DotMid "p.a + p.b")
        (b2DotMid "p->a + p->b")
    , check "B2 .ssa (re-seated by B4b): the WORKED EXAMPLE's shapes are in the emitted text — `alloc8 56` (FRAME memory, never `malloc`), memset, the nested field store at offset 8, and the val field addressed at +16 through the barrier seat"
        (case emitUserSsa rt b2WorkedMid of
            Ok ssa ->
                String.length ssa > 400
                    && String.contains "%t2 =l alloc8 56" ssa
                    && not (String.contains "call $malloc" ssa)
                    && String.contains "call $memset(l " ssa
                    && String.contains "call $q_Rt_x2evecStorePlain(l " ssa
                    && String.contains "%t9 =l add %t2, 16" ssa

            Err _ ->
                False
        )

    -- ================== B3: ARRAYS (plan Q5) ==================
    , check "B3 parse: `word[5] a;` is an ARRAY BINDER — the type is `TArray TWord 5` and the initialiser is AInitZero"
        (Parse.parseBlock "{ word[5] a;\n  return 0; }"
            == Ok
                { stmts = [ Ast.SArrayBind { aty = Ast.TArray Ast.TWord 5, name = "a", init = Ast.AInitZero } ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B3 parse: `word[3][4] m = { .. };` NESTS with the LEFTMOST group OUTER — `TArray (TArray TWord 4) 3` (three rows of four), the row-major flat order"
        (Parse.parseBlock "{ word[3][4] m = { 1, 2, 3 };\n  return 0; }"
            == Ok
                { stmts =
                    [ Ast.SArrayBind
                        { aty = Ast.TArray (Ast.TArray Ast.TWord 4) 3
                        , name = "m"
                        , init = Ast.AInitFull [ Ast.EInt 1, Ast.EInt 2, Ast.EInt 3 ]
                        }
                    ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B3 parse: an UPPERCASE base is an array of STRUCTS — `S[2] xs;` is the same statement shape with a `TStruct` element"
        (Parse.parseBlock "{ S[2] xs;\n  return 0; }"
            == Ok
                { stmts = [ Ast.SArrayBind { aty = Ast.TArray (Ast.TStruct "S") 2, name = "xs", init = Ast.AInitZero } ]
                , term = Ast.TRet (Ast.EInt 0)
                }
        )
    , check "B3 parse: the array type composes EVERYWHERE a type goes — a struct FIELD (`tab : word[3]`) and a `sizeof` operand (`sizeof(word[5])`)"
        ((Parse.parseModule "struct S { tab : word[3]; }\ndefun S.f() -> word {\n  return sizeof(word[5]);\n}"
            |> Result.map (\m -> ( m.decls, m.defuns ))
         )
            == Ok
                ( [ Ast.StructDecl { name = "S", members = [ Ast.MField { name = "tab", ty = Ast.TArray Ast.TWord 3, width = Nothing } ] } ]
                , [ { key = "S.f"
                    , params = []
                    , ret = Ast.TWord
                    , body = { stmts = [], term = Ast.TRet (Ast.ESizeof (Ast.SizeType (Ast.TArray Ast.TWord 5))) }
                    , flags = []
                    }
                  ]
                )
        )
    , checkErr "B3 parse REJECT: an array-to-array COPY initialiser (`word[5] b = a;`) — the tail is the brace list or nothing"
        "FULL brace list"
        "defun Rt.g(a: *word) -> word {\n  word[5] b = a;\n  return 0;\n}"
    , checkOk "B3 check ACCEPT: a FULL initialiser, element scaling and mutation through the base (`a[i] = a[i] + ..`) — the array's value is its address, so no cast is needed to index it"
        "defun Rt.g(s: val) -> word {\n  word[5] a = { 1, 2, 3, 4, 5 };\n  a[2] = a[2] + payload(s, 0);\n  return a[2] + a[0];\n}"
    , checkOk "B3 check ACCEPT: the DECAY row is in the checker's matrix — `*word p = a;` types (an array decays to its element's pointer), and so does `word w = a;` (an address is a word)"
        "defun Rt.g() -> word {\n  word[5] a = { 1, 2, 3, 4, 5 };\n  *word p = a;\n  word w = a;\n  return p[2] + w;\n}"
    , check "B3 MEASURED GAP — CLOSED BY B6 (the row that pinned it is now the row that proves it): `*word p = a;` (the decay binder cast) emitted nothing valid before B6 — it died in the QBE lane with the PRE-EXISTING raw-Var gap, because a Let's value had to be a raw PRODUCER node and `Var` of a raw binder was not one.  B6 made this defun's signature all-word (0 params, `-> word`), so the ABI is the word ABI and `Var a` is a raw alias that now EMITS.  `IsNotVacuouslyOk` below: the load is present and the array's base is the block the free list handed back"
        (case emitUserSsa rt "module B3g\ndefun B3g.g() -> word {\n  word[5] a = { 1, 2, 3, 4, 5 };\n  *word p = a;\n  return p[2];\n}" of
            Ok ssa ->
                String.contains "function l $q_B3g_x2eg() {" ssa
                    && String.contains "alloc8 40" ssa
                    && not (String.contains "call $malloc" ssa)
                    && String.contains "mul 8, 2" ssa

            Err _ ->
                False
        )
    , checkOk "B3 check ACCEPT: `&a` on an ARRAY VALUE is the identity (the value IS its address) — typed `*word` by the decay"
        "defun Rt.g() -> word {\n  word[5] a;\n  *word p = &a;\n  p[0] = 1;\n  return p[0];\n}"
    , checkOk "B3 check ACCEPT: an array ARGUMENT passes where its element's pointer is expected (`f(a)` into a `*word` parameter) — the decay row at the call boundary (the callee's own `p[i]` is B6's `*T`-parameter work: MEASURED, a `*word` PARAMETER is a Value slot and dies in the raw lane)"
        "defun Rt.n(p: *word, i: word) -> word {\n  return p[i];\n}\ndefun Rt.g() -> word {\n  word[3] a = { 7, 8, 9 };\n  return call Rt.n(a, 2);\n}"
    , checkOk "B3 check ACCEPT: MULTIDIMENSIONAL `word[3][4] m;` — a nested element store and a nested read (`m[1][2]`), the inner `[4]` stratifying the layout"
        "defun Rt.g() -> word {\n  word[3][4] m;\n  m[1][2] = 7;\n  m[2][0] = m[1][2] + 1;\n  return m[2][0];\n}"
    , checkOkModule "B3 check ACCEPT: an ARRAY OF STRUCTS — the element is a struct VALUE, so a whole-element store COPIES and `xs[0].k` reads through it"
        "struct I { k : word; }\ndefun Rt.g() -> word {\n  I one;\n  I[2] xs;\n  one.k = 4;\n  xs[0] = one;\n  xs[1].k = 5;\n  return xs[0].k + xs[1].k;\n}"
    , checkOk "B3 check ACCEPT: an ARRAY OF VAL — 40-byte handles in raw memory: a handle stored and read back by INDEX (`vs[1]`)"
        "defun Rt.g(v: val) -> val {\n  val[3] vs;\n  vs[0] = v;\n  vs[1] = mknum(payload(vs[0], 0) + 1);\n  return vs[1];\n}"
    , checkOk "B3 check ACCEPT: a HEAP array — `rawcall malloc(8 * sizeof(word[5]))` plus the typed `*word` view, `sizeof(T[N])` making it spellable"
        "defun Rt.g() -> word {\n  *word h = rawcall malloc(8 * sizeof(word[5]));\n  h[3] = 4;\n  return h[3];\n}"
    , checkOkModule "B3 check ACCEPT: an ARRAY FIELD of a struct — `s.tab[1]`, and `&s.tab` decays to `*word`"
        "struct S { tab : word[3]; }\ndefun Rt.g() -> word {\n  S s;\n  s.tab[1] = 9;\n  *word p = &s.tab;\n  return p[1] + s.tab[1];\n}"
    , checkErr "B3 check REJECT: a PARTIAL initialiser — and C's `{0}` IS one: zero-filling the elements not spelled manufactures garbage-tag `val` handles"
        "a PARTIAL initialiser is refused"
        "defun Rt.g() -> word {\n  word[5] a = { 1, 2 };\n  return a[0];\n}"
    , checkErr "B3 check REJECT: the SAME rule on a `val` array — the message names the garbage-tag trap and both zero-init spellings"
        "garbage-tag trap"
        "defun Rt.g() -> val {\n  val[4] vs = { mknil };\n  return vs[0];\n}"
    , checkOk "B3 check ACCEPT (control for the two rows above): the FULL list of the same length is legal, and the bare declaration is the zeroed spelling"
        "defun Rt.g() -> word {\n  word[2] a = { 1, 2 };\n  word[4] b;\n  return a[1] + b[3];\n}"
    , checkErr "B3 check REJECT: `a[i]` on a NON-ARRAY, non-pointer (`w[0]` on a word) — index access needs a pointer or an array"
        "index access needs a pointer"
        "defun Rt.g(w: word) -> word {\n  return w[0];\n}"
    , checkErr "B3 check REJECT: an index class that is not word/int — a `val` index (`a[v]`) is the one integer class's reject"
        "index must be a word offset"
        "defun Rt.g(v: val) -> word {\n  word[3] a = { 1, 2, 3 };\n  return a[v];\n}"
    , checkErr "B3 check REJECT: an array of an UNKNOWN struct — every dimension resolves in the file's struct table"
        "names no declared struct"
        "defun Rt.g() -> word {\n  Nope[2] xs;\n  return 0;\n}"
    , checkErr "B3 check REJECT: a ZERO-LENGTH array — no storage, so no address and no elements"
        "at least 1"
        "defun Rt.g() -> word {\n  word[0] a;\n  return 0;\n}"
    , checkErr "B3 check REJECT: an ARRAY PARAMETER by value — B6's word-ABI flattening; a `*word` view is what to write today"
        "ARRAY VALUE"
        "defun Rt.g(a: word[3]) -> word {\n  return 0;\n}"
    , checkErr "B3 check REJECT: an ARRAY RETURN (the ret path is one word; a caller-supplied `*word` out-parameter is the way)"
        "ARRAY RETURN is REJECTED"
        "defun Rt.g() -> word[3] {\n  word[3] a;\n  return a;\n}"
    , checkErr "B3 check REJECT: a WHOLE-array assignment (`a = b;`) — that is an element-wise copy, not a v1 form"
        "cannot be assigned whole"
        "defun Rt.g() -> word {\n  word[2] a;\n  word[2] b;\n  a = b;\n  return 0;\n}"
    , checkErr "B3 check REJECT: a NESTED-array element store (`m[0] = n;`) — the leaves are what store"
        "cannot be stored whole"
        "defun Rt.g(n: *word) -> word {\n  word[2][3] m;\n  m[0] = *n;\n  return 0;\n}"
    , checkErr "B3 check REJECT: a FLOAT array — no raw-memory f64 seat (the J11 float-field rule, same reason)"
        "no raw-memory seat"
        "defun Rt.g() -> word {\n  float[2] a;\n  return 0;\n}"
    , check "B3 PIN full initialiser: `word[5] a = { .. };` emits malloc(40) then FIVE stores at word offsets 0..4 (one per element, in written order)"
        (case lowlModuleBody "defun Rt.g() -> word {\n  word[5] a = { 11, 12, 13, 14, 15 };\n  return a[0];\n}" of
            Ok body ->
                b2StoreOffsets body == [ 0, 1, 2, 3, 4 ]

            Err _ ->
                False
        )
    , check "B3 PIN zero init: the BARE declaration memsets the block — `malloc(8*N)` then `memset(base, 0, 8*N)`, no element stores"
        (case lowlModuleBody "defun Rt.g() -> word {\n  word[4] a;\n  return a[1];\n}" of
            Ok body ->
                b2StoreOffsets body == []

            Err _ ->
                False
        )
    , check "B3 PIN stride: `word[3][4] m; m[1][2]` reads at `base + 32` (row 1 = 4 words) and word offset 2 — the emitted constant IS the table's arithmetic (4 = the inner array's width)"
        (case lowlModuleBody "defun Rt.g() -> word {\n  word[3][4] m;\n  return m[1][2];\n}" of
            Ok body ->
                canon (b3BlockValue body)
                    == canon
                        (Unsafe
                            (RawWordLoad
                                { ptr = Unsafe (RawBin { op = RAdd, a = ltv 1, b = ltn 32 })
                                , index = ltn 2
                                }
                            )
                        )

            Err _ ->
                False
        )
    , check "B3 PIN stride (structured element): `I[3] xs;` scales the index by `Check.sizeofStruct I` — the ONE layout table, not a second copy"
        (case lowlModuleBody "struct I { a : word; b : word; }\ndefun Rt.g(i: word) -> word {\n  I[3] xs;\n  return xs[i].a;\n}" of
            Ok body ->
                -- the `xs[i]` ADDRESS is `base + i*8*sizeof(I)` and the field
                -- read is the word at that address (`index = Lit 0`), with
                -- `sizeof I` = 2 read from the ONE layout table
                canon (b3BlockValue body)
                    == canon
                        (Unsafe
                            (RawWordLoad
                                { ptr = Unsafe (RawBin { op = RAdd, a = ltv 2, b = Unsafe (RawBin { op = RMul, a = ltv 1, b = ltn 16 }) })
                                , index = ltn 0
                                }
                            )
                        )

            Err _ ->
                False
        )
    , check "B3 PIN val element: a `val` array element is a RAW VEC node in VALUE units (`vecload(base, 1)` = byte 40), never a word-scaled offset"
        (case lowlModuleBody "defun Rt.g() -> val {\n  val[3] vs;\n  return vs[1];\n}" of
            Ok body ->
                canon (b3BlockValue body) == canon (Unsafe (RawVecLoad { vec = ltv 1, index = ltn 1 }))

            Err _ ->
                False
        )
    , check "B3 PIN sizeof: `sizeof(word[3][4])` is the LITERAL 12 — element width times both counts, from the same width walk the allocation uses"
        (case lowlModuleBody "defun Rt.g() -> word {\n  return sizeof(word[3][4]);\n}" of
            Ok body ->
                canon body == canon (ltn 12)

            Err _ ->
                False
        )
    , check "B3 PIN val element STORE: `vs[1] = e;` is `RawVecStore { vec = base, index = Lit 1 }` — a VALUE-unit index (byte 40), never a word offset"
        (case lowlModuleBody "defun Rt.g() -> val {\n  val[3] vs;\n  vs[1] = mknil;\n  return vs[1];\n}" of
            Ok body ->
                List.any
                    (\node ->
                        canon node
                            == canon
                                (Unsafe
                                    (RawVecStore
                                        { vec = ltv 1
                                        , index = ltn 1
                                        , value = Unsafe (RawMkValue { tag = RtLayout.valLayout.tagNil, words = [] })
                                        }
                                    )
                                )
                    )
                    (b3StoreNodes body)

            Err _ ->
                False
        )
    , check "B3 .ssa (re-seated by B4b): the worked source emits its THREE blocks at the sizes the table computes (the same three shapes as tools/qbe/fixtures/Warr.mid — ONE defun here because `emitUserSsa` lowers the first defun only, MEASURED) — alloc8 40 (word[5]), alloc8 96 + memset 96 (word[3][4] = 12 words), alloc8 32 + memset 32 (Outer[2] = 2 x 4 words) — and NOT ONE `malloc`, because a declared aggregate local is frame memory now"
        (case emitUserSsa rt b3WorkedMid of
            Ok ssa ->
                String.length ssa > 400
                    && String.contains "alloc8 40" ssa
                    && String.contains "alloc8 96" ssa
                    && String.contains "l 0, l 96)" ssa
                    && String.contains "alloc8 32" ssa
                    && String.contains "l 0, l 32)" ssa
                    && not (String.contains "call $malloc" ssa)

            Err _ ->
                False
        )

    -- ================== B6: THE WORD ABI IS DERIVED FROM THE SIGNATURE ==================
    -- Plan Q7.  The ABI class is no longer a hand-maintained KEY SET for user
    -- code: `Mid.Rt.abiTable` derives it from the declared signature (every
    -- parameter and the result word-class -> the word ABI) and MERGES the
    -- declared `Mid.Rt.rawAbi` keys in as an override.  The rows below pin the
    -- rule class by class, the merge, and the two things it unblocks: struct
    -- parameters by value and the raw-`Var` binder the B3 row below pins.
    , check "B6 ABI class (word/word): `word` params + a `word` result emit the WORD ABI — `function l` with one `l` register per parameter, and the body's tail is the raw word itself (no frame slot, no :val blit)"
        (b6Sig rt "module B6a\ndefun B6a.f(a : word) -> word {\n  return a;\n}"
            == Ok "function l $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (int/word): `int` IS `word` (B1's alias), so an `int` parameter classifies identically — one class, not two"
        (b6Sig rt "module B6a\ndefun B6a.f(a : int) -> word {\n  return a;\n}"
            == Ok "function l $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (bool/bool): a `bool` parameter and a `bool` result are word-class — a bool IS the 0/1 word, so the defun takes the WORD ABI"
        (b6Sig rt "module B6a\ndefun B6a.f(a : bool) -> bool {\n  return a;\n}"
            == Ok "function l $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (*T/word): a POINTER parameter is word-class (J12: a pointer IS a word) — the word ABI with an `l` register"
        (b6Sig rt "module B6a\ndefun B6a.f(p : *word) -> word {\n  return p[0];\n}"
            == Ok "function l $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (val -> the VALUE ABI): ONE `:val` in the signature (here the parameter) keeps the VALUE ABI — `function :ret` (the 80-byte sret), a frame and the blit.  VR1 changed the PARAMETER's register class: it crosses as an `l` POINTER to the caller's 40-byte Value, not as a by-value `:val` aggregate — the return path (the `:ret` sret) is unchanged"
        (b6Sig rt "module B6a\ndefun B6a.f(v : val) -> val {\n  return v;\n}"
            == Ok "function :ret $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (a val RESULT -> the VALUE ABI): the rule is PARAMS **AND** RESULT — a word parameter with a `val` result is still the value ABI (the ret path is the `:val` tail).  VR1: the parameter itself is still a 40-byte Value, so it crosses as an `l` POINTER (the class VR1 gave every value parameter)"
        (b6Sig rt "module B6a\ndefun B6a.f(w : word) -> val {\n  return mknum(1);\n}"
            == Ok "function :ret $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (float -> the VALUE ABI): a `float` is a `d` register class, NOT a word, so it never gets the word ABI (no defun in the tree has a float parameter, so nothing moves).  VR1: the `val`-classed parameter crosses as an `l` POINTER to the boxed 40-byte Value"
        (b6Sig rt "module B6a\ndefun B6a.f(f : float) -> word {\n  return 1;\n}"
            == Ok "function :ret $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 ABI class (a struct param -> the WORD ABI): a struct VALUE is word-class (its fields are flat words), so `defun f(s : S) -> word` takes the word ABI — MEASURED: ONE `l` register (the address of the caller's storage), which the callee copies at entry"
        (b6Sig rt "module B6a\nstruct S { a : word; }\ndefun B6a.f(s : S) -> word {\n  return s.a;\n}"
            == Ok "function l $q_B6a_x2ef(l %a0) {"
        )
    , check "B6 THE MERGE (the rule alone is NOT enough): the four aggregate-returning rawAbi keys (Rt.apply/apply-tail/tail-known/bounce) have ALL-WORD parameters and a `val` result, so `Ast.allWordSig` classifies them value-ABI — the hand set's OVERRIDE is what keeps them word-ABI, which is why the merge is load-bearing and not a safety net"
        (List.all
            (\key ->
                (Dict.member key rt.abi)
                    && (case List.filter (\d -> d.key == key) (Result.withDefault [] rt.parsedSource) of
                            d :: _ ->
                                Ast.allWordSig (List.map .ty d.params) d.ret == False

                            [] ->
                                False
                       )
            )
            [ "Rt.apply", "Rt.apply-tail", "Rt.tail-known", "Rt.bounce" ]
        )
    , check "B6 THE TABLE (totality + agreement, over the REAL runtime text): every declared rawAbi key is in the table, every table key the rule contributed (i.e. NOT a rawAbi key) has an all-word signature, and the TWENTY-ONE all-word surface defuns are exactly the rawAbi keys the rule derives (nine stage-6 + stage 7A's Rt.dieErr/hostDieErr + ZIGHOST Z1's eight root-registry defuns + ZIGHOST Z2's two vec-store writers — it was twelve until 7E deleted Rt.hostDieUnported with the unported set)"
        (let
            surface =
                Result.withDefault [] rt.parsedSource

            derived =
                List.filter (\d -> Ast.allWordSig (List.map .ty d.params) d.ret) surface
                    |> List.map .key
                    |> Set.fromList

            rawSet =
                Set.fromList (Set.toList Rt.rawAbi)
         in
         List.all (\k -> Set.member k rawSet) (Set.toList derived)
            && List.all (\d -> Dict.member d.key rt.abi) (List.filter (\d -> Set.member d.key rawSet) surface)
            && Set.size derived == 21
        )

    -- ---- B6: THE RAW-`Var` GAP (B3's pinned row, now CLOSED for a word binder) ----
    , check "B6 RAW-VAR (the brief's own MEASURED case, fail-before): `defun Vf.t(a : word) -> word { word z = a; return z; }` — `word z = a;` where `a` is a word PARAMETER now emits (`ret %a0`), where before B6 the parameter had no register at all (B3 pinned the same seam as `binder id 1 is not a raw word`)"
        (case emitUserSsa rt "module Vf\ndefun Vf.t(a : word) -> word {\n  word z = a;\n  return z;\n}" of
            Ok ssa ->
                String.contains "function l $q_Vf_x2et(l %a0) {" ssa
                    && String.contains "ret %a0" ssa
                    && not (String.contains "frame" ssa)

            Err _ ->
                False
        )
    , check "B6 RAW-VAR stays CLOSED for a val binder: `val z = a;` on a word parameter is still a loud reject at CHECK (a word does not pass into a `:val` slot unwrapped) — B6 widened the raw-Var GATE, not the class matrix"
        (case b6CheckErr rt "module Vf\ndefun Vf.t(a : word) -> word {\n  val z = a;\n  return 1;\n}" of
            Err msg ->
                String.contains "declares val but its initializer is word" msg

            Ok _ ->
                False
        )
    , check "B6 PINNED PRE-EXISTING GAP (not widened by this unit): a WORD parameter in a VALUE-ABI signature is still a 40-byte Value slot, so `mknum(w)` dies at emit with 'binder id 1 is not a raw word' — MEASURED IDENTICALLY before B6 (a word param in a -> val defun was always a slot); the fix is to make the signature all-word"
        (case emitUserSsa rt "module Vf\ndefun Vf.t(w : word) -> val {\n  return mknum(w);\n}" of
            Err e ->
                String.contains "is not a raw word" e

            Ok _ ->
                False
        )

    -- ---- B6: STRUCT PARAMETERS BY VALUE ----
    , check "B6 STRUCT PARAM: the entry copy IS the by-value hand-off — ONE `alloc8 16` block for a 2-word struct parameter, then one load+store per word from the incoming address register; the parameter binder names THAT block, so `s.a` reads block+0 and `s.b` reads block+8 through the ordinary field rules"
        (case emitUserSsa rt "module B6s\nstruct S { a : word; b : word; }\ndefun B6s.f(s : S) -> word {\n  return s.a + s.b;\n}" of
            Ok ssa ->
                String.contains "function l $q_B6s_x2ef(l %a0) {" ssa
                    && String.contains "%bx0 =l alloc8 16" ssa
                    && String.contains "%ca0_0 =l add %a0, 0" ssa
                    && String.contains "%cv0_0 =l loadl %ca0_0" ssa
                    && String.contains "storel %cv0_0, %ba0_0" ssa
                    && String.contains "%ca0_1 =l add %a0, 8" ssa
                    && String.contains "add %bx0, %t" ssa

            Err _ ->
                False
        )
    , check "B6 STRUCT PARAM: a field STORE through the parameter is legal and lands in the callee's OWN copy (by-value semantics: the caller's struct is untouched) — `s.a = 7;` is a storel to the block, and `&s` is the block's address (no second copy, no node)"
        (case emitUserSsa rt "module B6s\nstruct S { a : word; b : word; }\ndefun B6s.f(s : S) -> word {\n  s.a = 7;\n  *S p = &s;\n  return p.b;\n}" of
            Ok ssa ->
                String.contains "%bx0 =l alloc8 16" ssa
                    && String.contains "storel 7," ssa
                    && String.contains "add %bx0, 8" ssa

            Err _ ->
                False
        )
    , check "B6 STRUCT PARAM is CALLABLE from another Mid defun: the caller passes the struct VALUE (its address — `Var o` is already a raw word), so a struct argument needs no call-site signature table and no flattening on the caller's side — the whole by-value hand-off is `call $q_..(l %t)`, the alloc is the callee's"
        (case b6SsaAt rt "B6s.g" "module B6s\nstruct S { a : word; b : word; }\ndefun B6s.f(s : S) -> word {\n  return s.a;\n}\ndefun B6s.g() -> word {\n  S o;\n  o.a = 1;\n  o.b = 2;\n  return call B6s.f(o);\n}" of
            Ok ssa ->
                String.contains "call $q_B6s_x2ef(l %t" ssa
                    && String.contains "alloc8 16" ssa
                    && not (String.contains "call $malloc" ssa)

            Err _ ->
                False
        )
    , check "B6 `*S` PARAMETERS work in a word-ABI defun too (B2's stated limit, closed): the pointer arrives in `l %a0` and `p.a = p.a + 10` is a load+store through it — MEASURED end-to-end (Ptr.bump over `&o` mutates the CALLER's storage and prints 1117), which is the shape B2's example had to route through `val`/`payload`"
        (case emitUserSsa rt "module B6p\nstruct I { k : word; }\nstruct O { a : word; i : I; }\ndefun B6p.b(p : *O) -> word {\n  p.a = p.a + 10;\n  return p.a;\n}" of
            Ok ssa ->
                String.contains "function l $q_B6p_x2eb(l %a0) {" ssa
                    && String.contains "%t1 =l add %a0, %t0" ssa
                    && String.contains "storel %t3, %t5" ssa
                    && not (String.contains "blit" ssa)

            Err _ ->
                False
        )
    , check "B6 STRUCT RETURN stays REJECTED (loudly, with the reason): the word ABI's ret path is ONE register, so a struct cannot come back — the message names the out-parameter, and B6 did not quietly open it"
        (case b6CheckErr rt "module B6s\nstruct S { a : word; }\ndefun B6s.f(s : S) -> S {\n  return s;\n}" of
            Err msg ->
                String.contains "a struct RETURN is REJECTED" msg

            Ok _ ->
                False
        )

    -- ================== B4: LOOPS (plan Q6) ==================
    -- The ONE new IR family (`Loop` + the `Break`/`Continue` leaves +
    -- `RawAllocN`), the four surface forms, and the AUTO-CELL rule.  The
    -- rows are ordered as the unit was built: PARSE (exact AST), CHECK (the
    -- judgments), IR (the exact tree), .ssa (the block structure — and the
    -- absence of a phi), and the memory path.
    , check "B4 PARSE (exact AST): `while (c) {..}` is an `SWhile` STATEMENT whose body's fall-through is synthesized as `TContinue` — the relaxation is in the PARSER, so every Block the checker and lowerer read still has a terminator"
        (Parse.parseProgram "defun Rt.w(i: word) -> word {\n  while (i < 3) {\n    i = i + 1;\n  }\n  return i;\n}"
            == Ok
                [ { key = "Rt.w"
                  , flags = []
                  , params = [ { name = "i", ty = Ast.TWord } ]
                  , ret = Ast.TWord
                  , body =
                        { stmts =
                            [ Ast.SWhile
                                (Ast.EWordCmp Ast.WClts (Ast.EVar "i") (Ast.EInt 3))
                                { stmts =
                                    [ Ast.SVarStore "i"
                                        (Ast.EWordBin Ast.WAdd (Ast.EVar "i") (Ast.EInt 1))
                                    ]
                                , term = Ast.TContinue
                                }
                            ]
                        , term = Ast.TRet (Ast.EVar "i")
                        }
                  }
                ]
        )
    , check "B4 PARSE (exact AST): `do {..} while (c);` keeps its CONDITION on the statement (`SDoWhile`) — C's continue-evaluates-the-condition rule needs it, so it is not desugared away in the parser"
        (Parse.parseProgram "defun Rt.d(i: word) -> word {\n  do {\n    i = i + 1;\n  } while (i < 3);\n  return i;\n}"
            == Ok
                [ { key = "Rt.d"
                  , flags = []
                  , params = [ { name = "i", ty = Ast.TWord } ]
                  , ret = Ast.TWord
                  , body =
                        { stmts =
                            [ Ast.SDoWhile
                                { stmts =
                                    [ Ast.SVarStore "i"
                                        (Ast.EWordBin Ast.WAdd (Ast.EVar "i") (Ast.EInt 1))
                                    ]
                                , term = Ast.TContinue
                                }
                                (Ast.EWordCmp Ast.WClts (Ast.EVar "i") (Ast.EInt 3))
                            ]
                        , term = Ast.TRet (Ast.EVar "i")
                        }
                  }
                ]
        )
    , check "B4 PARSE (exact AST): `for (init; c; step) {..}` carries BOTH head statements — `init` (`i = 0;`) and `step` (`i = i + 1`, its `;` optional as in C) — and an EMPTY body is `TContinue`"
        (Parse.parseProgram "defun Rt.f(i: word) -> word {\n  for (i = 0; i < 3; i = i + 1) {\n  }\n  return i;\n}"
            == Ok
                [ { key = "Rt.f"
                  , flags = []
                  , params = [ { name = "i", ty = Ast.TWord } ]
                  , ret = Ast.TWord
                  , body =
                        { stmts =
                            [ Ast.SFor
                                { init = Just (Ast.SVarStore "i" (Ast.EInt 0))
                                , cond = Ast.EWordCmp Ast.WClts (Ast.EVar "i") (Ast.EInt 3)
                                , step =
                                    Just
                                        (Ast.SVarStore "i"
                                            (Ast.EWordBin Ast.WAdd (Ast.EVar "i") (Ast.EInt 1))
                                        )
                                , body = { stmts = [], term = Ast.TContinue }
                                }
                            ]
                        , term = Ast.TRet (Ast.EVar "i")
                        }
                  }
                ]
        )
    , check "B4 PARSE (exact AST): `break;`/`continue;` are TERMS (they end the block, like `return`), so `if (c) { break; }` parses as the ordinary mid-block if with a diverging branch"
        (Parse.parseProgram "defun Rt.b(i: word) -> word {\n  while (i < 9) {\n    if (i == 4) { break; }\n    i = i + 1;\n  }\n  return i;\n}"
            == Ok
                [ { key = "Rt.b"
                  , flags = []
                  , params = [ { name = "i", ty = Ast.TWord } ]
                  , ret = Ast.TWord
                  , body =
                        { stmts =
                            [ Ast.SWhile
                                (Ast.EWordCmp Ast.WClts (Ast.EVar "i") (Ast.EInt 9))
                                { stmts =
                                    [ Ast.SIf (Ast.EWordCmp Ast.WCeq (Ast.EVar "i") (Ast.EInt 4))
                                        { stmts = [], term = Ast.TBreak }
                                        Nothing
                                    , Ast.SVarStore "i"
                                        (Ast.EWordBin Ast.WAdd (Ast.EVar "i") (Ast.EInt 1))
                                    ]
                                , term = Ast.TContinue
                                }
                            ]
                        , term = Ast.TRet (Ast.EVar "i")
                        }
                  }
                ]
        )
    , check "B4 PARSE: the fall-through relaxation is LOOP-BODY-ONLY — the same terminator-less block at a DEFUN's body is still the exactly-one-terminator reject (the invariant did not move)"
        (case Parse.parseProgram "defun Rt.n() -> val {\n  word x = 1;\n}" of
            Err msg ->
                String.contains "exactly one terminator" msg

            Ok _ ->
                False
        )
    , check "B4 PARSE: `goto` is REJECTED with the Q6 argument in the message (it is a COMMITTED failure, so the block's own terminator message cannot hide it)"
        (case Parse.parseProgram "defun Rt.g() -> val {\n  goto done;\n  return mknil;\n}" of
            Err msg ->
                String.contains "`goto` is not in this language" msg
                    && String.contains "exactly TWO targets" msg

            Ok _ ->
                False
        )
    , check "B4 PARSE: a DECLARATION in a `for` step is a parse reject (C's step is an expression; a declaration there would shadow a binder once per iteration)"
        (case Parse.parseProgram "defun Rt.f(j: word) -> word {\n  for (j = 0; j < 2; word k = 1) {\n    j = j + 1;\n  }\n  return j;\n}" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    , check "B4 CHECK: `break;` outside any loop is a reject naming the rule — the nearest loop is the one it leaves, so nesting needs no labels"
        (case b6CheckErr rt "module B4b\ndefun B4b.f() -> word {\n  break;\n}" of
            Err msg ->
                String.contains "outside any loop" msg

            Ok _ ->
                False
        )
    , check "B4 CHECK: `continue;` outside any loop is the same reject"
        (case b6CheckErr rt "module B4c\ndefun B4c.f() -> word {\n  continue;\n}" of
            Err msg ->
                String.contains "outside any loop" msg

            Ok _ ->
                False
        )
    , check "B4 CHECK: a WORD-class local IS assignable (`x = 1;`) — the auto-cell is what makes a loop-carried word legal at all — and a cross-class assignment is still the class reject"
        (case b6CheckErr rt "module B4w\ndefun B4w.f() -> word {\n  word x = 0;\n  x = 1;\n  return x;\n}" of
            Ok _ ->
                case b6CheckErr rt "module B4w\ndefun B4w.g() -> word {\n  word x = 0;\n  x = mknil;\n  return x;\n}" of
                    Err msg ->
                        String.contains "but the assigned value is" msg

                    Ok _ ->
                        False

            Err _ ->
                False
        )
    , check "B4 CHECK: a BOOL local takes a bool TEMP only (the J1 binder closure, at the assignment site) — `b = i < 5;` is legal, `b = 1;` is the reject"
        (case b6CheckErr rt "module B4o\ndefun B4o.f(i: word) -> word {\n  bool b = i < 3;\n  b = i < 5;\n  return payload(mkbool(b), 0);\n}" of
            Ok _ ->
                case b6CheckErr rt "module B4o\ndefun B4o.g(i: word) -> word {\n  bool b = i < 3;\n  b = 1;\n  return 0;\n}" of
                    Err msg ->
                        String.contains "can only be assigned a bool TEMP" msg

                    Ok _ ->
                        False

            Err _ ->
                False
        )
    , check "B4 CHECK: a `val` local cannot be ASSIGNED, and the reject names the escape (`recur` params, the gcSweep idiom) — Mid.Ir has no node that stores a Value into a frame slot, so this is a stated cut, not a silent one"
        (case b6CheckErr rt "module B4v\ndefun B4v.f() -> val {\n  val v = mknum(1);\n  while (payload(v, 0) < 3) {\n    v = mknum(2);\n  }\n  return v;\n}" of
            Err msg ->
                String.contains "cannot be ASSIGNED" msg
                    && String.contains "recur` PARAMETER" msg

            Ok _ ->
                False
        )
    , check "B4 IR: the AUTO-CELL shape — `word i = 0; while (i < 3) { i = i + 1; }` lowers the declaration to `RawAllocN 1` + a `RawWordStore` of the initialiser, the condition to a `RawWordLoad`, and the assignment to a store (NO phi anywhere: the state lives in memory)"
        (case lowlBody "defun Rt.c(n: word) -> word {\n  word i = 0;\n  while (i < 3) {\n    i = i + 1;\n  }\n  return i;\n}" of
            Ok body ->
                b4CellInit body == Just 1
                    && b4CellStores body == [ 0, 0 ]
                    && b4CellLoads body >= 2
                    && b4HasLoop body

            Err _ ->
                False
        )
    , check "B4 IR: a READ-ONLY local in a loop stays a REGISTER (no cell, no load) — the auto-cell set is `assigned anywhere`, not `in a loop`"
        (case lowlBody "defun Rt.r(n: word) -> word {\n  word k = 0;\n  word lim = 3;\n  while (k < lim) {\n    k = k + 1;\n  }\n  return k;\n}" of
            Ok body ->
                -- ONE cell (k) — `lim` is read-only and is a plain `Var`, so
                -- if the auto-cell rule widened to "in a loop" this is 2
                b4CellInits body == 1 && b4CellLoads body >= 1

            Err _ ->
                False
        )
    , check "B4 IR: `for` desugars so that `continue` RUNS the step — the body's `continue` block carries the step statement BEFORE the `Continue` leaf (a continue that jumped to the loop top would hang the fixture, not misprint it)"
        (case lowlBody "defun Rt.f(i: word) -> word {\n  for (i = 0; i < 3; i = i + 1) {\n    if (i == 1) { continue; }\n  }\n  return i;\n}" of
            Ok body ->
                -- the step's `i = i + 1` appears TWICE: at the continue and
                -- at the body's fall-through end.  Once = a continue that
                -- skips the step (C-wrong); three = a doubled rewrite
                b4StepStores body == 2

            Err _ ->
                False
        )
    , check "B4 IR: `do {..} while (c);` is a `Loop` whose condition is the constant 1 with C's TEST placed where an iteration leaves — `if (c) { continue; }` followed by `break` (no body duplication, no new flag)"
        (case lowlBody "defun Rt.d(i: word) -> word {\n  do {\n    i = i + 1;\n  } while (i < 3);\n  return i;\n}" of
            Ok body ->
                b4DoWhileShape body

            Err _ ->
                False
        )
    , check "B4 .ssa STRUCTURE: a `while` emits `<cond test> jnz @loopbody / @loopexit`, the body, `jmp @loop`, and @loopexit — and NO `phi` appears ANYWHERE in the emitted text (the no-phi rule is the whole point of the cell)"
        (case emitUserSsa rt "module B4s\ndefun B4s.f(n: word) -> word {\n  word i = 0;\n  word s = 0;\n  while (i < n) {\n    i = i + 1;\n    s = s + i;\n  }\n  return s;\n}" of
            Ok ssa ->
                String.contains "@loop_0" ssa
                    && String.contains "jnz %t" ssa
                    && String.contains "@loopbody_2" ssa
                    && String.contains "jmp @loop_0" ssa
                    && String.contains "@loopexit_1" ssa
                    && not (String.contains "phi" ssa)

            Err _ ->
                False
        )
    , check "B4 .ssa AUTO-CELL: the cell is STACK storage — `alloc8 8` (Il.Alloc), never `malloc(l 8)` — and its init is a store into it, so the state a back edge needs lives in the frame (the exact cell COUNT is pinned by the IR rows above, where no runtime defun's allocs are in the text)"
        (case emitUserSsa rt "module B4a\ndefun B4a.f(n: word) -> word {\n  word lim = 3;\n  word i = 0;\n  while (i < lim) {\n    i = i + 1;\n  }\n  return i;\n}" of
            Ok ssa ->
                String.contains "alloc8 8" ssa
                    && not (String.contains "malloc(l 8)" ssa)
                    && String.contains "loadl" ssa

            Err _ ->
                False
        )
    , check "B4b IR: a declared ARRAY local is a FRAME block — `word[5] a;` binds `RawAllocN 5` (five WORDS of QBE stack memory, the node B4 landed for the auto-cells) and a nested `word[3][4] m;` binds `RawAllocN 12`; NO `malloc` node is left in the tree"
        (case lowlModuleBody "defun Rt.g() -> word {\n  word[5] a;\n  word[3][4] m;\n  a[0] = 1;\n  m[0][0] = 2;\n  return a[0] + m[0][0];\n}" of
            Ok body ->
                b2LetValue body
                    == Just (Unsafe (RawAllocN 5))
                    && b4AllocNs body == [ 5, 12 ]
                    && not (List.any (\e -> e == Unsafe (RawCallRaw { sym = "malloc", args = [ Lit (LNumber 40) ] })) (b4Exps body))

            Err _ ->
                False
        )
    , check "B4b .ssa: a struct local AND an array local live in the FRAME — `alloc8 16` / `alloc8 48` in the emitted text, not one `$malloc` call and not one `$free` (a scope exit cannot leak what the frame owns, so no destructor exists to go wrong)"
        (case emitUserSsa rt "module B4bq\nstruct P { x : word; y : word; }\ndefun B4bq.f(n: word) -> word {\n  P acc;\n  word[6] a = { 3, 1, 4, 1, 5, 9 };\n  acc.x = a[0] + n;\n  return acc.x;\n}" of
            Ok ssa ->
                String.contains "alloc8 16" ssa
                    && String.contains "alloc8 48" ssa
                    && not (String.contains "call $malloc" ssa)
                    && not (String.contains "call $free" ssa)

            Err _ ->
                False
        )
    , check "B4b .ssa: the memset of a zeroed local addresses the FRAME block — `S s;` emits `alloc8` then `call $memset(l <that temp>, l 0, l <8*words>)`, so uninitialised-memory discipline survives the move off the heap"
        (case emitUserSsa rt "module B4bm\nstruct P { x : word; y : word; }\ndefun B4bm.f() -> word {\n  P acc;\n  return acc.x;\n}" of
            Ok ssa ->
                String.contains "alloc8 16" ssa
                    && String.contains "call $memset(l %t" ssa
                    && String.contains "l 0, l 16)" ssa

            Err _ ->
                False
        )
    , check "B4b REGRESSION (B4's auto-cell may not lose): a word local ASSIGNED in a loop is still a CELL (`RawAllocN 1` + a store of its initialiser + loads in the body) while an ARRAY local declared INSIDE the same loop body is its own frame block — two `RawAllocN`s, no phi, no malloc"
        (case lowlBody "defun Rt.c(n: word) -> word {\n  word i = 0;\n  while (i < n) {\n    word[2] t;\n    t[0] = i;\n    i = i + t[0];\n  }\n  return i;\n}" of
            Ok body ->
                b4AllocNs body == [ 1, 2 ]
                    && b4CellInits body == 2
                    && b4CellInit body == Just 1
                    && b4CellLoads body >= 2
                    && b4HasLoop body

            Err _ ->
                False
        )

    -- ---- B4b: THE WIDENED ESCAPE RULE (one negative row per shape) ----
    , check "B4b ESCAPE REJECT: `p->ptr = &a;` — a FIELD store through a POINTER target may outlive this frame, so a frame address stored there dangles; the message names the site and the place"
        (case b6CheckErr rt "module B4be\nstruct S { a : word; ptr : *word; }\ndefun B4be.f(p : *S) -> word {\n  word[3] a = { 1, 2, 3 };\n  p->ptr = &a;\n  return p->a;\n}" of
            Err msg ->
                String.contains "ADDRESS of this frame's own storage" msg
                    && String.contains "p->ptr = &a" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `p[0] = &a;` — an INDEX store through a POINTER (`*word p` may point at a heap block or a caller's frame)"
        (case b6CheckErr rt "module B4bx\ndefun B4bx.f(p : *word) -> word {\n  word[3] a = { 1, 2, 3 };\n  p[0] = &a;\n  return p[0];\n}" of
            Err msg ->
                String.contains "ADDRESS of this frame's own storage" msg
                    && String.contains "p[0] = &a" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `p[0] = a;` — the DECAY spelling of the same store (an array VALUE is its address), so the reject cannot be dodged by dropping the `&`"
        (case b6CheckErr rt "module B4bd\ndefun B4bd.f(p : *word) -> word {\n  word[3] a;\n  p[0] = a;\n  return p[0];\n}" of
            Err msg ->
                String.contains "ADDRESS of this frame's own storage" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `*S p = &s; return p;` — the alias the provenance set follows (`Ctx.frameAddr`), and the message names the binder it went through (`(via p)`) instead of pretending the source said `&s`"
        (case b6CheckErr rt "module B4bp\nstruct S { a : word; }\ndefun B4bp.f() -> *S {\n  S s;\n  *S p = &s;\n  return p;\n}" of
            Err msg ->
                String.contains "returns the ADDRESS of this frame" msg
                    && String.contains "(via p)" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `return a;` on an ARRAY local in a `-> *word` defun — MEASURED as a live hole before this unit (it emitted a return of the block's address); an array value IS its address, so this is the same dangling return"
        (case b6CheckErr rt "module B4ba\ndefun B4ba.f() -> *word {\n  word[3] a;\n  return a;\n}" of
            Err msg ->
                String.contains "returns the ADDRESS of this frame" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `word w = &a; return w;` — a scalar binder carries the address just as a `*T` does, so the provenance set tracks it too (and is CLEARED by any assignment to the name, below)"
        (case b6CheckErr rt "module B4bw\ndefun B4bw.f() -> word {\n  word[3] a;\n  word w = &a;\n  return w;\n}" of
            Err msg ->
                String.contains "returns the ADDRESS of this frame" msg
                    && String.contains "(via w)" msg

            Ok _ ->
                False
        )
    , check "B4b ESCAPE REJECT: `return &s.f;` — interior of a frame block is still this frame's storage (the B4 rule, kept)"
        (case b6CheckErr rt "module B4bi\nstruct I { k : word; }\nstruct S { inner : I; }\ndefun B4bi.f() -> *I {\n  S s;\n  return &s.inner;\n}" of
            Err msg ->
                String.contains "returns the ADDRESS of this frame" msg

            Ok _ ->
                False
        )

    -- ---- B4b ACCEPT: the rule must not reject what is SOUND ----
    , check "B4b ACCEPT (no false positive): a store into a SAME-FRAME aggregate is legal — `s.ptr = &t;` and `a[0] = &t;` on locals: the address and the block die together, so there is nothing to dangle"
        (case b6CheckErr rt "module B4bs\nstruct S { a : word; ptr : *word; }\ndefun B4bs.f() -> word {\n  S t;\n  S s;\n  t.a = 5;\n  s.ptr = &t;\n  word[3] a;\n  a[0] = &t;\n  return t.a + a[0];\n}" of
            Err _ ->
                False

            Ok _ ->
                True
        )
    , check "B4b ACCEPT: PASSING `&local` to a callee is legal — the ordinary out-parameter idiom.  RETENTION by the callee is the DOCUMENTED obligation (no checker can see it): the fixture Wesc.mid/wescprobe.elm is the probe that makes its consequence visible (a read through a retained frame address answers 0, not the 7 written)"
        (case b6CheckErr rt "module B4bc\nstruct S { a : word; }\ndefun B4bc.take(p : *S) -> word {\n  return p->a;\n}\ndefun B4bc.f() -> word {\n  S s;\n  s.a = 4;\n  return call B4bc.take(&s);\n}" of
            Err _ ->
                False

            Ok _ ->
                True
        )
    , check "B4b ACCEPT: an assignment CLEARS the provenance — `*S p = &s; p = rawcall malloc(16); return p;` is legal, because `p` no longer holds a frame address (a flow-blind rule would reject a correct program here)"
        (case b6CheckErr rt "module B4br\nstruct S { a : word; }\ndefun B4br.f() -> *S {\n  S s;\n  *S p = &s;\n  p = rawcall malloc(16);\n  return p;\n}" of
            Err _ ->
                False

            Ok _ ->
                True
        )

    -- ==================== B5: anonymous unions (midlang-b5) ====================
    -- The union rule is the ONE layout table's (plan Q4): a block's members
    -- share the block's offset, the block contributes `max(member sizes)`,
    -- and a member is PROMOTED into the struct's field namespace.  Every row
    -- below reads that table through the public surface (`fieldOffset`/
    -- `fieldWidth`/`sizeofStruct`) or the lowered tree — no second rule.
    , check "parse B5: an anonymous union block inside a struct is its OWN body item — the block carries its members in declaration order and the fields around it keep theirs (exact AST, so a silent re-grouping cannot pass)"
        (declsOf "struct Msg { tag : word; union { n : word; p : *Msg; pair : Pair; }; pad : word; }"
            == [ Ast.StructDecl
                    { name = "Msg"
                    , members =
                        [ Ast.MField { name = "tag", ty = Ast.TWord, width = Nothing }
                        , Ast.MUnion
                            [ { name = "n", ty = Ast.TWord, width = Nothing }
                            , { name = "p", ty = Ast.TPtr (Ast.PStruct "Msg"), width = Nothing }
                            , { name = "pair", ty = Ast.TStruct "Pair", width = Nothing }
                            ]
                        , Ast.MField { name = "pad", ty = Ast.TWord, width = Nothing }
                        ]
                    }
               ]
        )
    , check "parse B5: the block keyword is `union` FOLLOWED BY `{` only — a field NAMED `union` still parses as a field (no keyword was stolen from the field namespace)"
        (declsOf "struct S { union : word; }"
            == [ Ast.StructDecl { name = "S", members = [ Ast.MField { name = "union", ty = Ast.TWord, width = Nothing } ] } ]
        )
    , checkErrModule "parse B5 REJECT: a union block OUTSIDE a struct — there is no union VALUE and no union TYPE, so the grammar has nowhere to put one"
        "unexpected input after the expression"
        "union { a : word; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "parse B5 REJECT: a block INSIDE a block — a nested block would be a second overlap at the same offset with no name to tell the two apart (v1 has no such spelling)"
        "expected `:`"
        "struct S { union { union { a : word; }; }; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , check "B5 LAYOUT (THE RULE): tag/union{n,p,pair}/pad — `n`, `p` and `pair` ALL sit at word 1, the block advances by max(1,1,2) = 2, so `pad` is at word 3 and sizeof(Msg) is 4 (a SUM would put `pad` at word 5 and sizeof at 6)"
        (let
            decls =
                declsOf "struct Pair { lo : word; hi : word; }\nstruct Msg { tag : word; union { n : word; p : *Msg; pair : Pair; }; pad : word; }"
         in
         Check.sizeofStruct decls "Msg"
            == Just 4
            && Check.sizeofStruct decls "Pair"
            == Just 2
            && Check.fieldOffset decls "Msg" "n"
            == Just 8
            && Check.fieldOffset decls "Msg" "p"
            == Just 8
            && Check.fieldOffset decls "Msg" "pair"
            == Just 8
            && Check.fieldOffset decls "Msg" "pad"
            == Just 24
            && Check.fieldWidth decls "Msg" "n"
            == Just 1
            && Check.fieldWidth decls "Msg" "pair"
            == Just 2
        )
    , check "B5 LAYOUT: a `val` member sizes the block at 5 words beside a `word` member's 1 — pure layout arithmetic, no new rule (the next field is at 6, sizeof is 7)"
        (let
            decls =
                declsOf "struct V { tag : word; union { w : word; v : val; }; after : word; }"
         in
         Check.sizeofStruct decls "V"
            == Just 7
            && Check.fieldOffset decls "V" "w"
            == Just 8
            && Check.fieldOffset decls "V" "v"
            == Just 8
            && Check.fieldOffset decls "V" "after"
            == Just 48
            && Check.fieldWidth decls "V" "v"
            == Just 5
        )
    , checkErrModule "B5 REJECT: an EMPTY union block — a block with no members has no size and no shared offset, so silently contributing 0 would put the next field at an offset nothing declares"
        "has an EMPTY union block"
        "struct S { tag : word; union { }; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "B5 REJECT: a duplicate member NAME inside one block — one name, one offset"
        "declares field 'n' more than once"
        "struct S { tag : word; union { n : word; n : word; }; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "B5 REJECT: a union member colliding with a SIBLING FIELD — promotion means the block's members live in the STRUCT's namespace, so `n` beside `n` is the same duplicate"
        "declares field 'n' more than once"
        "struct S { n : word; union { n : word; }; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , check "B5 LOWER: `m.n` and `m.p` lower to the SAME tree — two members of one block are byte-for-byte the same load (`RawWordLoad (Var 1) 1`), which is what sharing an offset MEANS in this pipeline"
        (case
            ( lowlModuleBody "struct M { tag : word; union { n : word; p : *M; }; }\ndefun Rt.f(m : *M) -> word {\n  return m.n;\n}"
            , lowlModuleBody "struct M { tag : word; union { n : word; p : *M; }; }\ndefun Rt.f(m : *M) -> word {\n  return [word](m.p);\n}"
            )
         of
            ( Ok a, Ok b ) ->
                a == b && a == Unsafe (RawWordLoad { ptr = Var 1, index = Lit (LNumber 1) })

            _ ->
                False
        )
    , check "B5 LOWER: a STRUCT member of the block is addressed off the block's offset — `m.pair.hi` is `loadl (m + 8) + 1`, i.e. block offset 1 plus the inner field's 1"
        (lowlModuleBody "struct Pair { lo : word; hi : word; }\nstruct M { tag : word; union { n : word; pair : Pair; }; }\ndefun Rt.f(m : *M) -> word {\n  return m.pair.hi;\n}"
            == Ok
                (Unsafe
                    (RawWordLoad
                        { ptr = Unsafe (RawBin { op = RAdd, a = Var 1, b = Lit (LNumber 8) })
                        , index = Lit (LNumber 1)
                        }
                    )
                )
        )
    , check "B5 LOWER: the aggregate COPY of a union-bearing struct is ONE overlapped run — words 0,1,2 for tag/block(max 2)/pad, NOT one store per member (a per-member walk would emit 0,1,1,1,2: the same bytes written over themselves)"
        (case lowlModuleBody "struct Pair { lo : word; hi : word; }\nstruct M { tag : word; union { n : word; p : *M; pair : Pair; }; }\ndefun Rt.f() -> word {\n  M b;\n  M a = b;\n  return a.tag;\n}" of
            Ok body ->
                b2StoreOffsets body == [ 0, 1, 2 ]

            Err _ ->
                False
        )
    , check "B5 .ssa: the union-bearing struct's emitted shapes — `alloc8 32` and a 32-byte memset for a 4-word struct (a SUM layout would emit 48), the word member stored at the block's offset, and `pad` addressed at word 3 (max 2 + 1)"
        (case emitUserSsa rt "module B5u\nstruct Pair { lo : word; hi : word; }\nstruct M { tag : word; union { n : word; p : *M; pair : Pair; }; pad : word; }\ndefun B5u.f() -> word {\n  M v;\n  v.tag = 1;\n  v.n = 11;\n  v.pad = 5;\n  return v.pair.hi;\n}" of
            Ok ssa ->
                String.length ssa > 200
                    && String.contains "alloc8 32" ssa
                    && String.contains "l 32)" ssa
                    && String.contains "storel 11" ssa
                    && String.contains "mul 8, 3" ssa

            Err _ ->
                False
        )
    , checkOkModule "B5 ACCEPT: THE TAGGED-UNION SHAPE (plan Q4/Q2) — a `word` tag field beside the block, and dispatch as an if-CHAIN reading a different member per arm.  There is no `match`/`switch` in this language and this unit does not add one"
        "struct Pair { lo : word; hi : word; }\nstruct Msg { tag : word; union { n : word; p : *Msg; pair : Pair; }; pad : word; }\ndefun Rt.pick(vm : val) -> val {\n  *Msg m = payload(vm, 0);\n  if (m.tag == 1) {\n    return mknum(m.n);\n  } else {\n    if (m.tag == 2) {\n      return mknum(m.p->n);\n    } else {\n      return mknum(m.pair.lo + m.pair.hi);\n    }\n  }\n}"
    , checkOkModule "B5 ACCEPT: a union member is initialised through the PROMOTED name (`M a = { tag = 1; n = 5; };`) — the block's members are the struct's own field namespace, so no `a.u.n` spelling exists or is needed"
        "struct M { tag : word; union { n : word; p : *M; }; }\ndefun Rt.f() -> word {\n  M a = { tag = 1; n = 5; };\n  return a.n;\n}"
    , checkOkModule "B5 DOCUMENTED, NOT ENFORCED: a `val` member in a union block is LEGAL — raw memory holding a handle is the §Q11 obligation on the WRITER (nothing traces it), and the layout arithmetic is all this unit rules on (plan Q4 says exactly that)"
        "struct V { tag : word; union { w : word; v : val; }; }\ndefun Rt.f(x : val) -> val {\n  V s;\n  s.tag = 1;\n  s.v = x;\n  return s.v;\n}"

    -- ==================== B7: the `val` bridge, as rules (midlang-b7) ====================
    -- THE SET IS THE GATE (plan Q11's illegal list, five items).  Three of
    -- them already had rows BEFORE this unit, so they are not duplicated —
    -- the pointers, so a reader can check the set is complete:
    --   * "a val in a word slot"  -> "J1 REJECT — a binder whose initializer
    --     class differs" (`word n = mknil;`), the J1 builtin-argument row,
    --     the J3 rawcall row, and the TWO J13 rows "needs word, got val"
    --     (a val into a word FIELD; a word into a VAL field/slot);
    --   * "a word reading a val"  -> "check A1 reject: a val READ AS A WORD
    --     (a val field into a word binder) is a J1 reject";
    --   * "any cast of a val"     -> the three B1 rows under "not in the cast
    --     matrix" ([word](v), [val](v), [val](x)).
    -- The two with NO row ("a word reading a val" through a raw-word ADDRESS,
    -- and the compares) are the first rows below; then the ONE judgment this
    -- unit ADDS (the val condition), then the legal set as POSITIVE rows.
    , checkErr "B7 ENFORCED: `wload(v, 0)` — a val passed into a raw word ADDRESS slot (the other direction of \"word reading a val\": the copy IS a word, its class is not)"
        "builtin 'wload' argument"
        "defun Rt.b7w(v: val) -> val {\n  word n = wload(v, 0);\n  return mknum(n);\n}"
    , checkErr "B7 ENFORCED: `==` on two vals — the compares are word,word -> bool, and the reject names the REMEDY (`call Rt.=` / `Rt.deepEq`), not just the class"
        "there is no `==` on values"
        "defun Rt.b7eq(a: val, b: val) -> val {\n  val c = mkbool(a == b);\n  return c;\n}"
    , checkErr "B7 ENFORCED: `<` on two vals — there is no value ORDERING at all (the six compares are the word family)"
        "there is no `<` on values"
        "defun Rt.b7lt(a: val, b: val) -> val {\n  val c = mkbool(a < b);\n  return c;\n}"
    , checkErr "B7 ENFORCED (the judgment this unit adds): `if (mknil)` — a val condition must be a BOXED BOOL, and nil is provably not one; the value test is false only for a boolean with payload 0, so this branch is ALWAYS taken"
        "condition is mknil"
        "defun Rt.b7c1() -> val {\n  if (mknil) { return mknum(1); } else { return mknum(2); }\n}"
    , checkErr "B7 ENFORCED: `if (mknum(0))` — the sharpest case: a NUMBER is TRUTHY to the value test whatever its payload, so this silently took the then-branch before the rule"
        "condition is a mknum(..) value"
        "defun Rt.b7c2() -> val {\n  if (mknum(0)) { return mknum(1); } else { return mknum(2); }\n}"
    , checkErr "B7 ENFORCED: `if (\"x\")` — a string literal is a val and never a boolean (and it is a SAFEPOINT, so it cannot even be the window's cond by accident)"
        "condition is a string literal"
        "defun Rt.b7c3() -> val {\n  if (\"x\") { return mknum(1); } else { return mknum(2); }\n}"
    , checkOk "B7 ACCEPT (the rule must NOT swallow the boxed path — runtime.mid's own `if (isDup)`/`if (lessB)` shape): a `val` BINDER and a `val` RETURN of a `call` are both legal conditions"
        "defun Rt.b7c4(n: word) -> val {\n  val isBig = mkbool(n == 3);\n  if (isBig) { return mknum(1); } else { return mknum(2); }\n}\n\ndefun Rt.b7c5(n: word) -> val {\n  if (call Rt.b7c4(n)) { return mknum(1); } else { return mknum(2); }\n}"
    , checkOk "B7 DOCUMENTED HOLE, PINNED POSITIVE: `mkval(tag, ..)` as a condition stays legal — its tag is an arbitrary expression, so deciding it would mean reading tag constants the checker does not own (a later 'louder' rule must not tighten this silently)"
        "defun Rt.b7c6() -> val {\n  if (mkval(1, 7)) { return mknum(1); } else { return mknum(2); }\n}"
    , checkOk "B7 ACCEPT (the legal set, in one defun): bind a val, BOX via mk*, store into a `val` array element via vecstore, read back, pass to a call, root with `withroots`, and return it"
        "defun Rt.b7v(v: val) -> val {\n  val boxed = mknum(payload(v, 0) + 1);\n  word base = allocvec(1);\n  vecstore(base, 0, boxed);\n  val back = vecload(base, 0);\n  val e = call Rt.b7same(back, v);\n  return withroots [back, e] { return e; };\n}\n\ndefun Rt.b7same(a: val, b: val) -> val {\n  return mkbool(payload(a, 0) == payload(b, 0));\n}"
    , checkOkModule "B7 ACCEPT (the legal set, the RAW-MEMORY half): a `val` struct FIELD — store through the value (`b.item = v;`), store again through a POINTER (`p->item = v;`), read back both ways.  Nothing traces the field: that is obligation 1, documented in Ast's header, not a checker judgment"
        "struct Bag { tag : word; item : val; }\ndefun Rt.b7bg(v : val) -> val {\n  Bag b;\n  b.tag = 1;\n  b.item = v;\n  *Bag p = &b;\n  p->item = b.item;\n  return b.item;\n}"

    -- ==================== cffi U6: WIDTH-TYPED MEMORY ====================
    -- (plan §8 U6, handoff-cffi-u6.)  The layout table is BYTE-granular with
    -- PER-FIELD ALIGNMENT, and a struct field may declare a MEMORY WIDTH
    -- (`i8 u8 i16 u16 i32 u32 i64 u64`) whose size, alignment, load mnemonic
    -- and sign rule all come from the one declaration.
    --
    -- THE NUMBERS BELOW ARE FROM THIS HOST'S HEADERS (glibc 2.44, x86_64),
    -- confirmed with a C `offsetof`/`sizeof` program compiled and run here:
    --   sys/poll.h:36-41               sizeof 8,   fd@0, events@4, revents@6
    --   bits/struct_stat.h             sizeof 144, mode@24, uid@28, gid@32,
    --                                  __pad0@36, rdev@40, size@48, blocks@64
    --   bits/types/struct_timespec.h   sizeof 16, tv_sec@0, tv_nsec@8
    -- The RUNTIME oracle for them is the `ffim-mem` fixture (a real `poll()`
    -- writes the bytes); this is the same census one level down, where a wrong
    -- alignment rule is a number rather than a mystery.
    , check "cffi U6 LAYOUT (the width matrix): one struct carrying EVERY admissible width — i8/u8/i16/u16/i32/u32/i64/u64/word/val/*T/word[2] — lays out at the C offsets 0,1,2,4,8,12,16,24,32,40,80,88 and is 104 bytes (13 words), i.e. every width carries its OWN size and alignment and the mixed struct's total is the sum plus the padding C inserts"
        (let
            decls =
                declsOf "struct All { a : i8; b : u8; c : i16; d : u16; e : i32; f : u32; g : i64; h : u64; w : word; v : val; p : *All; l : word[2]; }"
         in
         List.map (\n -> Check.fieldOffset decls "All" n) [ "a", "b", "c", "d", "e", "f", "g", "h", "w", "v", "p", "l" ]
            == List.map Just [ 0, 1, 2, 4, 8, 12, 16, 24, 32, 40, 80, 88 ]
            && Check.structSizeBytes decls "All"
            == Just 104
            && Check.sizeofStruct decls "All"
            == Just 13
            && Check.structAlign decls "All"
            == Just 8
        )
    , check "cffi U6 LAYOUT (alignment is per field, and it is the WIDTH's): a `u32` after a `u8` lands at byte 4 (not 1), a `u16` after a `u16` lands at 2 (not 1), and a `u16`/`u32` pair then fills a word exactly — the offsets that discriminate align-1/2/4"
        (let
            p1 =
                declsOf "struct P1 { a : u8; b : u32; c : word; }"

            p3 =
                declsOf "struct P3 { a : u16; b : u16; c : u32; }"
         in
         Check.fieldOffset p1 "P1" "b"
            == Just 4
            && Check.fieldOffset p1 "P1" "c"
            == Just 8
            && Check.fieldOffset p3 "P3" "b"
            == Just 2
            && Check.fieldOffset p3 "P3" "c"
            == Just 4
            && Check.structSizeBytes p3 "P3"
            == Just 8
        )
    , check "cffi U6 CENSUS: struct pollfd — the effect-loop port's own struct (fd i32, events u16, revents u16) is 8 bytes with events at byte 4 and revents at 6, exactly the header's offsets; a word-granular table could not express byte 4 at all, and a rounded one would put events at 8"
        (let
            decls =
                declsOf "struct Pollfd { fd : i32; events : u16; revents : u16; }"
         in
         Check.fieldOffset decls "Pollfd" "fd"
            == Just 0
            && Check.fieldOffset decls "Pollfd" "events"
            == Just 4
            && Check.fieldOffset decls "Pollfd" "revents"
            == Just 6
            && Check.structSizeBytes decls "Pollfd"
            == Just 8
            && Check.structAlign decls "Pollfd"
            == Just 4
        )
    , check "cffi U6 CENSUS: struct stat's x86_64 layout through the typed fields — mode@24 (u32), uid@28, gid@32, __pad0@36, rdev@40 (the 8-byte ALIGNMENT BUMP past pad0), size@48, blksize@56, blocks@64, atim@72, mtim@88, ctim@104, reserved@120, sizeof 144"
        (let
            decls =
                statCensusDecls
         in
         List.map (\n -> Check.fieldOffset decls "Stat" n)
            [ "dev", "ino", "nlink", "mode", "uid", "gid", "pad0", "rdev", "size", "blksize", "blocks", "atim", "mtim", "ctim", "reserved" ]
            == List.map Just [ 0, 8, 16, 24, 28, 32, 36, 40, 48, 56, 64, 72, 88, 104, 120 ]
            && Check.structSizeBytes decls "Stat"
            == Just 144
            && Check.sizeofStruct decls "Stat"
            == Just 18
        )
    , check "cffi U6 CENSUS: struct timespec nests by VALUE at its own size — sizeof(timespec) is 16 bytes / 2 words, so `atim`/`mtim`/`ctim` in `struct stat` are 16 bytes apart (72/88/104), which the row above reads off the ONE table"
        (let
            decls =
                statCensusDecls
         in
         Check.structSizeBytes decls "Timespec"
            == Just 16
            && Check.structAlign decls "Timespec"
            == Just 8
            && Check.sizeofStruct decls "Timespec"
            == Just 2
        )
    , check "cffi U6 LOWER (u16 READ): `p->events` on the pollfd struct is `RawMemLoad { MemH, unsigned, offset 4 }` — the width AND the sign are node data, and the offset is the table's BYTE offset"
        (lowlModuleBody "struct Pollfd { fd : i32; events : u16; revents : u16; }\ndefun Rt.f(p : *Pollfd) -> word {\n  return p->events;\n}"
            == Ok (Unsafe (RawMemLoad { width = MemH, signed = False, ptr = Var 1, off = 4 }))
        )
    , check "cffi U6 LOWER (i16 IS sign-extended, u16 is not): the same source with `events : i16` lowers to the SAME width and offset with `signed = True` — the sign rule is the declaration's, carried in the node, never inferred from a type at the emission site"
        (case
            ( lowlModuleBody "struct S { fd : i32; events : i16; }\ndefun Rt.f(p : *S) -> word {\n  return p->events;\n}"
            , lowlModuleBody "struct S { fd : i32; events : u16; }\ndefun Rt.f(p : *S) -> word {\n  return p->events;\n}"
            )
         of
            ( Ok signedTree, Ok unsignedTree ) ->
                signedTree
                    == Unsafe (RawMemLoad { width = MemH, signed = True, ptr = Var 1, off = 4 })
                    && unsignedTree
                    == Unsafe (RawMemLoad { width = MemH, signed = False, ptr = Var 1, off = 4 })

            _ ->
                False
        )
    , check "cffi U6 LOWER (u8): `s->a` is `RawMemLoad { MemB, unsigned, offset 0 }` — an 8-byte UNSIGNED byte read at the field's byte offset"
        (lowlModuleBody "struct S { a : u8; b : i8; c : u32; d : i32; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return s->a;\n}"
            == Ok (Unsafe (RawMemLoad { width = MemB, signed = False, ptr = Var 1, off = 0 }))
        )
    , check "cffi U6 LOWER (i8): `s->b` at byte 1 with `signed = True` — the same width, the other extension rule"
        (lowlModuleBody "struct S { a : u8; b : i8; c : u32; d : i32; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return s->b;\n}"
            == Ok (Unsafe (RawMemLoad { width = MemB, signed = True, ptr = Var 1, off = 1 }))
        )
    , check "cffi U6 LOWER (u32): `s->c` at BYTE 4 — the `u8`+`i8` pair before it is two bytes, so the `u32`'s align-4 rounds the cursor up: the offset that a word-granular table could not produce"
        (lowlModuleBody "struct S { a : u8; b : i8; c : u32; d : i32; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return s->c;\n}"
            == Ok (Unsafe (RawMemLoad { width = MemW, signed = False, ptr = Var 1, off = 4 }))
        )
    , check "cffi U6 LOWER (i32): `s->d` at byte 8 with `signed = True`"
        (lowlModuleBody "struct S { a : u8; b : i8; c : u32; d : i32; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return s->d;\n}"
            == Ok (Unsafe (RawMemLoad { width = MemW, signed = True, ptr = Var 1, off = 8 }))
        )
    , check "cffi U6 LOWER (u64 IS the word path): `s->e` on a `u64` field lowers to the ORDINARY `RawWordLoad { index = 2 }` (byte 16 / 8) — an 8-byte field is a word, so its declared width buys the LAYOUT, not a new op"
        (lowlModuleBody "struct S { a : u8; b : i8; c : u32; d : i32; e : u64; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return s->e;\n}"
            == Ok (Unsafe (RawWordLoad { ptr = Var 1, index = Lit (LNumber 2) }))
        )
    , check "cffi U6 LOWER (STORE): `p->revents = e;` is `RawMemStore { MemH, offset 6 }` — the store's width comes from the same declaration (both signs store the same bytes, so the store node carries no sign).  The store sits under the dead-binder Let every effect statement gets, so the row searches the tree"
        (case lowlModuleBody "struct P { fd : i32; events : u16; revents : u16; }\ndefun Rt.f() -> val {\n  P p;\n  p.revents = 7;\n  return mknil;\n}" of
            Ok body ->
                List.any (\node -> canon node == canon (Unsafe (RawMemStore { width = MemH, ptr = Var 1, off = 6, value = Lit (LNumber 7) }))) (b4Exps body)

            Err _ ->
                False
        )
    , check "cffi U6 LOWER (a WORD field is UNCHANGED): `p->w` still lowers to `RawWordLoad { index = 1 }` — the WORD-offset node with its 8*index address arithmetic, byte-for-byte the tree the corpus pins; the byte table feeds it `offset / 8`"
        (lowlModuleBody "struct S { a : word; w : word; }\ndefun Rt.f(p : *S) -> word {\n  return p->w;\n}"
            == Ok (Unsafe (RawWordLoad { ptr = Var 1, index = Lit (LNumber 1) }))
        )
    , check "cffi U6 EMIT (.ssa): the narrow access really prints as the sub-word op — `p.events = 4` emits `storeh 4, %t..` and the read emits `=l loaduh %t..` (an `l`-typed WIDENING load, with no extension after it)"
        (case emitUserSsa rt "module U6e\nstruct Pollfd { fd : i32; events : u16; revents : u16; }\ndefun U6e.f() -> val {\n  Pollfd p;\n  p.events = 4;\n  return mknum(p.events);\n}" of
            Ok ssa ->
                String.contains "=l loaduh " ssa
                    && String.contains "storeh 4, %t" ssa

            Err _ ->
                False
        )
    , checkErrModule "cffi U6 REJECT (J11, the word-quantised block): a struct whose BYTE SIZE is not a whole number of 8-byte words is refused by name, with the remedy — a 2-byte layout would make the word-for-word copy write past its own end into the next field"
        "not a whole number of 8-byte words"
        "struct P { a : u16; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "cffi U6 REJECT (a narrow ARRAY element): `u8[256]` — the `struct dirent` name tail — is refused at PARSE with the reason (a narrow element type in `TArray` is not part of this unit), never silently word-scaled"
        "is a MEMORY width, and an ARRAY of one is not expressible yet"
        "struct D { type : u8; name : u8[256]; }\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "cffi U6 REJECT (a narrow width at the CALL boundary): `u16` in an `extern` parameter is refused at parse, and the message says it is a FIELD width — the four sub-word `FfiTy` constructors stay unreachable from an `extern` line, so no sub-word argument class exists to get wrong"
        "is a MEMORY width: it is spellable as a struct FIELD type"
        "extern f(x : u16) -> i32;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , checkErrModule "cffi U6 REJECT (J13, the address of a narrow field): `&p->events` is refused — the only pointer family here is `*word`, 8 bytes wide, so the address would licence overwriting the neighbouring fields; the message names the width and the remedy (read the field itself)"
        "has no address: the only pointer family here is `*word`"
        "struct Pollfd { fd : i32; events : u16; revents : u16; }\ndefun Rt.g(p : *Pollfd) -> word {\n  *word q = &p->events;\n  return *q;\n}"
    , check "cffi U6 ACCEPT (the control): `&p->w` on a struct with NO narrow field is still legal (`*word`) — so the J13 reject above is about the declared WIDTH and not about `&` on a field (and note it fires for `i32` too: a 4-byte field has no 8-byte view either)"
        (case chkModuleFlags [] "struct S { w : word; x : word; }\ndefun Rt.g(p : *S) -> word {\n  *word q = &p->w;\n  return *q;\n}" of
            Ok () ->
                True

            Err _ ->
                False
        )

    -- ============ cffi U6 FIX: the `off / 8` invariant, CHECKED ============
    -- The post-U6 review's should-fix.  Until now the rule "every
    -- word-class field is at a multiple of 8" was stated in three comments
    -- and checked NOWHERE, and two shapes the grammar accepts broke it with a
    -- SILENT wrong answer (both MEASURED by emission in the review):
    --   (A) a union block placed by `widthAlign` — the DECLARED widths only —
    --       while the cursor was advanced by the full `fieldSizeOf`
    --       alignment, so a block after a sub-word field sat at byte 1;
    --   (B) an align-4 nested struct at byte 4, whose word-indexed copy ran
    --       from word 0 to word 0.
    -- No row could fail on either before these four: every union row above
    -- and both union fixtures sit at an already-8-aligned cursor, and no row
    -- nested an align-4 struct.
    , check "cffi U6 FIX LAYOUT (probe A): a union block is aligned by its MEMBER's alignment, read from the SAME table the walk advances the cursor by — in `struct S { a : u8; union { p : *word; }; tail : word; }` the block starts at BYTE 8 (C's rule: the union's alignment is its widest member's, 8), so `p` is at 8, `tail` at 16 and the struct is 24 bytes.  FAIL-BEFORE (0af695d): `p` sat at byte 1 — an offset the block's own cursor advance already knew was wrong, because `unionAlign` answered 1 for a member aligned by its TYPE"
        (let
            decls =
                declsOf "struct S { a : u8; union { p : *word; }; tail : word; }"
         in
         Check.fieldOffset decls "S" "a"
            == Just 0
            && Check.fieldOffset decls "S" "p"
            == Just 8
            && Check.fieldOffset decls "S" "tail"
            == Just 16
            && Check.structSizeBytes decls "S"
            == Just 24
            && Check.sizeofStruct decls "S"
            == Just 3
        )
    , check "cffi U6 FIX LOWER (probe A's access): that union member is addressed at WORD 1 (`RawWordLoad { index = 1 }`, i.e. the emitted `mul 8, 1`).  FAIL-BEFORE: the same field lowered to `index = 0` — the store landed on byte 0, overwriting the `a = 7` written just before it"
        (lowlModuleBody "struct S { a : u8; union { p : *word; }; tail : word; }\ndefun Rt.f(s : *S) -> word {\n  return [word](s->p);\n}"
            == Ok (Unsafe (RawWordLoad { ptr = Var 1, index = Lit (LNumber 1) }))
        )
    , checkErrModule "cffi U6 FIX REJECT (probe B, and the invariant now CHECKED): an align-4 nested struct placed at byte 4 is a J11 reject naming the field and the word the division would truncate to.  `struct Inner { a : u32; b : u32; }` is legal (8 bytes, align 4), so `inner` follows `x : u32` at byte 4 — where the WORD-indexed copy machinery copied from word 0 to word 0, clobbering `o.x` and leaving `o.inner.b` unlanded.  FAIL-BEFORE: this module checked and emitted cleanly.  The EXEMPTION is the declared sub-word widths (a byte-addressed access), which is what keeps the width-matrix row above legal"
        "places field 'inner' at byte 4"
        "struct Inner { a : u32; b : u32; }\nstruct Outer { x : u32; inner : Inner; tail : word; }\ndefun Rt.g() -> word {\n  Inner i;\n  Outer o;\n  o.inner = i;\n  return o.x;\n}"
    , check "cffi U6 FIX CONTROL (the reject is about the OFFSET, not about nesting): the same nested field at an 8-aligned offset is ACCEPTED and its copy lands on WORD 1 of the destination (`o.inner` at byte 8) — so nothing writes word 0, which is `o.x`.  The two stores are both word 1 because `Inner`'s own two `u32` fields word-index into its word 0: a redundant but content-correct store of the same 8 bytes, and the reason the row pins the DESTINATION base rather than a store count"
        (case lowlModuleBody "struct Inner { a : u32; b : u32; }\nstruct Outer { x : word; inner : Inner; tail : word; }\ndefun Rt.f() -> word {\n  Inner i;\n  Outer o;\n  o.inner = i;\n  return o.x;\n}" of
            Ok body ->
                b2StoreOffsets body == [ 1, 1 ]

            Err _ ->
                False
        )
    , checkErrModule "cffi U6 FIX REJECT (the review's extern-namespace nice-to-have): `extern rt_vec_alloc(n : i64) -> ptr;` is refused — the `rt_`/`q_Rt_` prefix belongs to the lowering's OWN seats, and the Mid heap's allocating seat is one of them.  It is neither a builtin nor a `rawcallArity` row, so before this rule the declaration passed J15 and the call was classified a NON-safepoint C call: the enclosing defun could be classified frame-free, i.e. unrooted across an allocation"
        "names a MID RUNTIME seat"
        "extern rt_vec_alloc(n : i64) -> ptr;\ndefun Rt.g() -> word {\n  return 0;\n}"
    , check "cffi U6 FIX (the ONE declaration table's two readers AGREE on the FIRST declaration): a symbol declared twice cannot be typed from one declaration and emitted from another even when a caller lowers without `declCheck`.  NOT a fail-before row, and the record should say so: the review read `ffiTable`'s `Dict.insert e.name e.sig (ffiTable rest)` as last-wins, but the recursion inserts each declaration AFTER its successors, so the head won there too (MEASURED: this row passes unchanged on 0af695d).  The fix is legibility — a `List.foldl` in file order — and this row is the pin that keeps the two readers agreeing if either one is ever rewritten"
        (let
            decls =
                declsOf "extern f(a : i64) -> i64;\nextern f(a : i32, b : i32) -> i32;"
         in
         case ( Dict.get "f" (Check.ffiTable decls), Check.externSig decls "f" ) of
            ( Just fromTable, Just fromDecls ) ->
                fromTable == fromDecls && List.length fromTable.params == 1

            _ ->
                False
        )

    -- ============== THE BOOLEAN PAYLOAD IS A WORD, NOT A PAYLOAD WORD ======
    -- A bool Value's payload is the `i32` member of the Zig `Value` union
    -- (gc/types.zig: `boolean: i32`), and BOTH non-literal writers store it
    -- with a 32-bit store (Mid/Qbe/Lower's `lowerLit` LBoolean arm and
    -- `reboxBoolean`; `storeValueWords` — what `mkbool(..)` uses — writes 8).
    -- So the HIGH HALF of a bool's payload word belongs to whatever the cell
    -- held before, and it is UNDEFINED for a Value the Zig runtime built (its
    -- union literal writes only the active member).  A reader that takes the
    -- full 64 bits (`payload`) therefore reads a half-uninitialised word; the
    -- READ the compiler's own `:val`-cond test emits is a 32-bit `loadw` of
    -- that word (Lower, the boxed-bool test).  These two rows pin the READ on
    -- both sides of that contract:
    --   (a) the lowering — `payload32` is the 32-bit read, `payload` is not;
    --   (b) the runtime's own readers — every site in runtime.mid that reads a
    --       BOOLEAN spells `payload32`, and the four 64-bit spellings that were
    --       there are GONE (the negative half is what a revert turns red).
    -- The EMITTED shape (`loadw`+`extsw` vs `loadl`) and the behaviour on a
    -- boolean with GARBAGE in its high half are pinned where they can be
    -- measured: qbe-check.sh's `boolpay` row (the fixture
    -- tools/qbe/fixtures/boolpay.mid + its golden) and its `BOOLPAY-SHAPE`
    -- emitted-.ssa row.
    , check "BOOL PAYLOAD WIDTH (a): `payload32(a, 0)` lowers to RawPayload32 — the payload WORD read (QBE `loadw` + `extsw`) — while `payload(a, 0)` lowers to RawPayload (QBE `loadl` of the same word).  The two nodes differ in WIDTH alone, which is why a runtime site spelling `payload` on a boolean reads the stale high half"
        (case lowlBody "defun Rt.t(a : val) -> val {\n  word lo = payload32(a, 0);\n  word wide = payload(a, 0);\n  return mknum(lo + wide);\n}" of
            Ok body ->
                canon body
                    == canon
                        (llets
                            [ ( ltb 2, Unsafe (RawPayload32 { value = ltv 1, word = 0 }) )
                            , ( ltb 3, Unsafe (RawPayload { value = ltv 1, word = 0 }) )
                            ]
                            (lmkNum (liadd (ltv 2) (ltv 3)))
                        )

            Err _ ->
                False
        )
    , check "BOOL PAYLOAD WIDTH (b): the FOUR runtime.mid sites that read a BOOLEAN Value spell payload32 (RE-PINNED AT O4: the two mhOff reads retired with the QBE_MIDHOST hatch) — Rt.cStrEq's word result, Rt.main's metaGo `found`, Rt.main's `hostIsProgram` read, and Rt.hostListDirChunk's `skip` ('..' filter).  The negatives are the fail-before half: each 64-bit spelling of those five names is absent"
        (let
            mid =
                runtimeMidText

            routeText =
                defunText "Rt.main" mid

            absent name =
                not (String.contains ("payload(" ++ name ++ ", 0)") mid)
         in
         String.contains "return payload32(eq, 0);" (defunText "Rt.cStrEq" mid)
            && String.contains "payload32(found, 0)" routeText
            && String.contains "payload32(call Rt.hostIsProgram(vecload(fptr, 0)), 0)" routeText
            && String.contains "payload32(skip, 0)" (defunText "Rt.hostListDirChunk" mid)
            && absent "eq"
            && not (String.contains "payload(found, 0)" routeText)
            -- (the `found` negative is scoped to Rt.main's own text: O5 seat
            -- 2's Rt.intern has a `found` WORD binder of its own, a plain
            --  i64 word never a Boolean Value read)
            && absent "mhOff"
            && absent "skip"
            && not (String.contains "payload(call Rt.hostIsProgram" mid)
        )
    ]


{- The two rows above are the post-U6 review's second and third nice-to-haves,
kept beside the U6 fix because they are the same class (two seats that could
disagree). -}


{-| B4 — every subexpression of a tree, pre-order (the loop rows count nodes
of a shape; a shape-specific walker per row would restate the IR).
-}
b4Exps : Exp -> List Exp
b4Exps e =
    e :: List.concatMap b4Exps (b4Kids e)


b4Kids : Exp -> List Exp
b4Kids e =
    case e of
        Lit _ ->
            []

        Var _ ->
            []

        GRef _ ->
            []

        StreamRef _ ->
            []

        Lam l ->
            [ l.body ]

        NoTail inner ->
            [ inner ]

        App app ->
            app.fn :: app.args

        PrimApp app ->
            app.args

        Let block ->
            List.concatMap
                (\b ->
                    case b of
                        LetBind lb ->
                            [ lb.value ]

                        LetDestruct d ->
                            [ d.value ]
                )
                block.binders
                ++ [ block.body ]

        Case branch ->
            branch.scrutinee :: List.map .body branch.alts

        Con c ->
            c.args

        Tup es ->
            es

        RecordLit setters ->
            List.map Tuple.second setters

        RecordGet rec _ ->
            [ rec ]

        RecordUpdate update ->
            update.base :: List.map Tuple.second update.updates

        ListLit es ->
            es

        If block ->
            [ block.cond, block.thenBranch, block.elseBranch ]

        ShortAnd block ->
            [ block.left, block.right ]

        ShortOr block ->
            [ block.left, block.right ]

        NotEqual block ->
            [ block.left, block.right ]

        Loop block ->
            [ block.cond, block.body ]

        Break ->
            []

        Continue ->
            []

        Unsafe node ->
            case node of
                RawCall c ->
                    c.args

                RawCallRaw c ->
                    c.args

                RawCallExtern c ->
                    c.args

                RawCallAgg c ->
                    c.fn :: c.args

                RawTagOf x ->
                    [ x ]

                RawPayload r ->
                    [ r.value ]

                RawPayload32 r ->
                    [ r.value ]

                RawTagIs r ->
                    [ r.value ]

                RawMkValue r ->
                    r.words

                RawAllocVector x ->
                    [ x ]

                RawAllocRaw x ->
                    [ x ]

                RawVecLoad r ->
                    [ r.vec, r.index ]

                RawVecAddr r ->
                    [ r.vec, r.index ]

                RawVecStore r ->
                    [ r.vec, r.index, r.value ]

                RawStrByte r ->
                    [ r.str, r.index ]

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

                RawIToF x ->
                    [ x ]

                RawLoadFlt x ->
                    [ x ]

                RawByteLoad r ->
                    [ r.ptr, r.index ]

                RawByteStore r ->
                    [ r.ptr, r.index, r.value ]

                RawWordLoad r ->
                    [ r.ptr, r.index ]

                RawWordStore r ->
                    [ r.ptr, r.index, r.value ]

                -- cffi U6: width-typed memory — the offset is node data.
                RawMemLoad r ->
                    [ r.ptr ]

                RawMemStore r ->
                    [ r.ptr, r.value ]

                WithRoots r ->
                    [ r.body ]

                RawDataAddr _ ->
                    []

                RawCStr _ ->
                    []

                RawSym _ ->
                    []

                RawAllocN _ ->
                    []


{-| The FIRST cell allocation's word count (`Just n` for `RawAllocN n`).
-}
b4CellInit : Exp -> Maybe Int
b4CellInit body =
    List.head
        (List.filterMap
            (\e ->
                case e of
                    Unsafe (RawAllocN n) ->
                        Just n

                    _ ->
                        Nothing
            )
            (b4Exps body)
        )


{-| Every `RawAllocN`'s word count, in tree order (B4b reads the frame
blocks this way: a cell is 1 word, an array/struct block is its width).
-}
b4AllocNs : Exp -> List Int
b4AllocNs body =
    List.filterMap
        (\e ->
            case e of
                Unsafe (RawAllocN n) ->
                    Just n

                _ ->
                    Nothing
        )
        (b4Exps body)


b4CellInits : Exp -> Int
b4CellInits body =
    List.length
        (List.filter
            (\e ->
                case e of
                    Unsafe (RawAllocN _) ->
                        True

                    _ ->
                        False
            )
            (b4Exps body)
        )


{-| Every `RawWordStore`'s constant dst index, in tree order.
-}
b4CellStores : Exp -> List Int
b4CellStores body =
    List.filterMap
        (\e ->
            case e of
                Unsafe (RawWordStore r) ->
                    case r.index of
                        Lit (LNumber n) ->
                            Just n

                        _ ->
                            Nothing

                _ ->
                    Nothing
        )
        (b4Exps body)


b4CellLoads : Exp -> Int
b4CellLoads body =
    List.length
        (List.filter
            (\e ->
                case e of
                    Unsafe (RawWordLoad _) ->
                        True

                    _ ->
                        False
            )
            (b4Exps body)
        )


b4HasLoop : Exp -> Bool
b4HasLoop body =
    List.any
        (\e ->
            case e of
                Loop _ ->
                    True

                _ ->
                    False
        )
        (b4Exps body)


b4HasBreak : Exp -> Bool
b4HasBreak body =
    List.any (\e -> e == Break) (b4Exps body)


b4HasContinue : Exp -> Bool
b4HasContinue body =
    List.any (\e -> e == Continue) (b4Exps body)


{-| The stores whose VALUE is an addition — the `for` step's `i = i + 1`.  A
continue site that ran the step and the body's own end are two such stores;
any other count is the rewrite having doubled (or dropped) one.
-}
b4StepStores : Exp -> Int
b4StepStores body =
    List.length
        (List.filter
            (\e ->
                case e of
                    Unsafe (RawWordStore r) ->
                        case r.value of
                            Unsafe (RawBin b) ->
                                b.op == RAdd

                            _ ->
                                False

                    _ ->
                        False
            )
            (b4Exps body)
        )


{-| The `do`-`while` desugar's shape: a `Loop` whose condition is the constant
1, carrying BOTH leaves (a `Continue` for "the test held" and a `Break` for
"it did not").
-}
b4DoWhileShape : Exp -> Bool
b4DoWhileShape body =
    List.any
        (\e ->
            case e of
                Loop l ->
                    l.cond == Lit (LNumber 1) && b4HasContinue l.body && b4HasBreak l.body

                _ ->
                    False
        )
        (b4Exps body)


{-| How many times a literal substring appears (the .ssa alloc census).
-}
b4Count : String -> String -> Int
b4Count needle hay =
    if String.length hay < String.length needle then
        0

    else if String.startsWith needle hay then
        1 + b4Count needle (String.dropLeft (String.length needle) hay)

    else
        b4Count needle (String.dropLeft 1 hay)


{-| The block's VALUE: the innermost `body` of the Let chain a declaration's
stores wrap it in (the array pins compare the READ node, not the memset/store
prefix).
-}
b3StoreNodes : Exp -> List Exp
b3StoreNodes e =
    case e of
        Let l ->
            List.concatMap
                (\b ->
                    case b of
                        LetBind lb ->
                            [ lb.value ]

                        _ ->
                            []
                )
                l.binders
                ++ b3StoreNodes l.body

        _ ->
            []


b3BlockValue : Exp -> Exp
b3BlockValue e =
    case e of
        Let l ->
            b3BlockValue l.body

        _ ->
            e


{-| The B3 fixtures, as source text (the rows drive the REAL pipeline).
-}
b3WorkedMid : String
b3WorkedMid =
    "module B3w\nstruct Inner { k : word; }\nstruct Outer { tag : word; inner : Inner; }\ndefun B3w.run(seed : val) -> val {\n  word s = payload(seed, 0);\n  word[5] a = { 1, 2, 3, 4, 5 };\n  a[2] = a[2] + s;\n  word[3][4] m;\n  m[0][3] = 7;\n  m[1][2] = a[2];\n  Outer[2] xs;\n  xs[0].tag = 11;\n  xs[1].inner.k = 33;\n  return mknum((a[2] * 100000000) + (m[1][2] * 10000) + (xs[0].tag * 100) + xs[1].inner.k);\n}"


{-| The B2 fixtures, as source text (the rows drive the REAL pipeline).
-}
b2MilestoneMid : String
b2MilestoneMid =
    "module B2m\nstruct Inner { k : word; }\nstruct Outer { a : word; in_ : Inner; v : val; }\ndefun B2m.f(s : val) -> val {\n  Outer o;\n  o.a = payload(s, 0);\n  o.in_.k = 7;\n  o.v = mknum(9);\n  *Outer p = &o;\n  p.a = p.a + 1;\n  Outer c = o;\n  c = o;\n  c.in_.k = c.in_.k + 1;\n  return mknum(c.a + c.in_.k + payload(c.v, 0) + p.a);\n}"


b2LocalMid : String
b2LocalMid =
    "module B2loc\nstruct Inner { k : word; }\nstruct Outer { a : word; in_ : Inner; v : val; }\ndefun B2loc.f(s : val) -> val {\n  Outer o;\n  o.a = payload(s, 0);\n  return mknum(o.a);\n}"


b2CopyMid : String
b2CopyMid =
    "module B2copy\nstruct Inner { k : word; }\nstruct Outer { a : word; in_ : Inner; v : val; }\ndefun B2copy.f(s : val) -> val {\n  word w = payload(s, 0);\n  Outer o;\n  Outer c = o;\n  return mknum(w);\n}"


b2DotMid : String -> String
b2DotMid tail =
    -- A `val` parameter and a `word` LOCAL on purpose: a user defun's `word`
    -- parameter is still a 40-byte Value slot (the word-ABI generalization is
    -- B6), so a word param would make the two sides differ by ABI rather than
    -- by the access spelling.
    "module B2dot\nstruct S { a : word; b : word; }\ndefun B2dot.f(v : val) -> val {\n  word i = payload(v, 0);\n  *S p = rawcall malloc(16);\n  p.a = i;\n  return mknum("
        ++ tail
        ++ ");\n}"


b2WorkedMid : String
b2WorkedMid =
    "module B2w\nstruct Inner { k : word; }\nstruct Outer { a : word; in_ : Inner; v : val; }\ndefun B2w.f(s : val) -> val {\n  word w = payload(s, 0);\n  Outer o;\n  o.a = w;\n  o.in_.k = 7;\n  o.v = mknum(99);\n  Outer c = o;\n  c.a = c.a + 1000;\n  return mknum(c.a + c.in_.k + payload(c.v, 0));\n}"


{-| The FIRST Let binder's value — the struct ALLOCATION in a B2 body.
-}
b2LetValue : Exp -> Maybe Exp
b2LetValue e =
    case e of
        Let block ->
            case block.binders of
                LetBind b :: _ ->
                    Just b.value

                _ ->
                    Nothing

        _ ->
            Nothing


{-| The FIRST Let's body.
-}
b2LetBody : Exp -> Maybe Exp
b2LetBody e =
    case e of
        Let block ->
            Just block.body

        _ ->
            Nothing


{-| The body under the struct binder's `Let` (skipping the allocation and the
`memset`) — what `&s` / `&s.f` rows read.
-}
b2Shell : Exp -> Maybe Exp
b2Shell body =
    -- `S s;` lowers to `Let s = malloc in Let dead = memset in <shell>`
    case b2LetBody body of
        Just inner ->
            b2LetBody inner

        Nothing ->
            Nothing


{-| Every `RawWordStore`'s CONSTANT dst index, in emission order — the copy
rows' read (the number of stores IS the struct's width, and the indexes are
the ONE table's offsets).
-}
b2StoreOffsets : Exp -> List Int
b2StoreOffsets e =
    case e of
        Unsafe (RawWordStore ws) ->
            (case ws.index of
                Lit (LNumber n) ->
                    [ n ]

                _ ->
                    []
            )
                ++ b2StoreOffsets ws.value

        Let block ->
            List.concatMap b2BinderStores block.binders ++ b2StoreOffsets block.body

        Unsafe (RawBin bin) ->
            b2StoreOffsets bin.a ++ b2StoreOffsets bin.b

        Unsafe (RawVecStore st) ->
            b2StoreOffsets st.vec ++ b2StoreOffsets st.value

        Unsafe (RawMkValue mk) ->
            List.concatMap b2StoreOffsets mk.words

        _ ->
            []


b2BinderStores : LetBinder -> List Int
b2BinderStores b =
    case b of
        LetBind lb ->
            b2StoreOffsets lb.value

        LetDestruct ld ->
            b2StoreOffsets ld.value


{-| The `(vec, index)` of a `RawVecLoad` — the val-field addressing row's read.
-}
b2VecField : Exp -> Maybe ( Exp, Int )
b2VecField e =
    case e of
        Unsafe (RawVecLoad vl) ->
            case vl.index of
                Lit (LNumber n) ->
                    Just ( vl.vec, n )

                _ ->
                    Nothing

        _ ->
            Nothing


b2SameSsaRow : Rt.Runtime -> String -> String -> String -> String
b2SameSsaRow rt name a b =
    check name
        (case ( emitUserSsa rt a, emitUserSsa rt b ) of
            ( Ok sa, Ok sb ) ->
                String.length sa > 400 && sa == sb

            _ ->
                False
        )





b1SameSsaRow : Rt.Runtime -> String -> String -> String -> String
b1SameSsaRow rt name a b =
    check name
        (case ( emitUserSsa rt a, emitUserSsa rt b ) of
            ( Ok sa, Ok sb ) ->
                -- anti-vacuity: two ERRORS are not a byte-identity proof
                String.length sa > 400 && sa == sb

            _ ->
                False
        )


b1CastMid : String
b1CastMid =
    "module B1cast\n\ndefun B1cast.f(a: val) -> val {\n  word x = payload(a, 0);\n  bool c = [bool](x);\n  if ([word](c)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"


b1SzMid : String
b1SzMid =
    "module B1sz\n\nstruct R { aa : word; bb : val; cc : word; }\n\ndefun B1sz.f(a: val) -> val {\n  return mknum((sizeof(R) * 1000000) + sizeof(*word));\n}"


b1RetBoolMid : String
b1RetBoolMid =
    "module B1ret\n\ndefun B1ret.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  return (x == y);\n}"


b1BoxedMid : String
b1BoxedMid =
    "module B1box\n\ndefun B1box.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  if (mkbool(x == y)) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"


b1SeamMid : String
b1SeamMid =
    "module B1seam\n\ndefun B1seam.f(a: val, b: val) -> val {\n  word x = payload(a, 0);\n  word y = payload(b, 0);\n  bool c = (x == y);\n  if (c) {\n    return mknum(1);\n  } else {\n    return mknum(2);\n  }\n}"


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


{-| cffi U6: `struct stat`'s x86_64 layout as the CENSUS rows spell it — the
header's field order and widths (glibc 2.44, `bits/struct_stat.h`, the
`__x86_64__` arm without time64 redirects), including glibc's own `__pad0` int
and its `__glibc_reserved[3]` tail, so `sizeof` is 144 = 18 words.  The SAME
declaration the `ffim-mem` fixture's `Stat` uses.
-}
statCensusDecls : List Ast.Decl
statCensusDecls =
    declsOf "struct Timespec { sec : i64; nsec : i64; }\nstruct Stat { dev : u64; ino : u64; nlink : u64; mode : u32; uid : u32; gid : u32; pad0 : i32; rdev : u64; size : i64; blksize : i64; blocks : i64; atim : Timespec; mtim : Timespec; ctim : Timespec; reserved : word[3]; }"


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


{-| The A1 rows' drivers: parse a whole MODULE (decls + defuns) and run the
decl-carrying checker (`Check.checkModule`).  `checkOkModule` asserts
acceptance; `checkErrModule` asserts a rejection whose message names the
judgment — a parse failure would Err WITHOUT the fragment, so a source
that did not even parse cannot pass the row vacuously.
-}
chkModuleFlags : List Ast.Flag -> String -> Result String ()
chkModuleFlags flags src =
    case Parse.parseModule src of
        Ok module_ ->
            Check.checkModule Dict.empty flags module_

        Err e ->
            Err ("parse: " ++ e)


checkOkModule : String -> String -> String
checkOkModule name src =
    check name
        (case chkModuleFlags [] src of
            Ok () ->
                True

            Err _ ->
                False
        )


checkErrModule : String -> String -> String -> String
checkErrModule name frag src =
    check name
        (case chkModuleFlags [] src of
            Err msg ->
                String.contains frag msg

            Ok () ->
                False
        )


{-| True iff every needle occurs in `hay`, in the given order.  Each search
continues AFTER the previous match, so a needle that must appear twice has to
appear twice — which is what makes this stronger than a bag of
`String.contains` calls (7D's child side and driver are both STATEMENT
ORDERS, and a reordering is exactly the bug that must be RED).
-}
inOrder : String -> List String -> Bool
inOrder hay needles =
    let
        advance : String -> Maybe String -> Maybe String
        advance needle acc =
            case acc of
                Nothing ->
                    Nothing

                Just rest ->
                    case String.split needle rest of
                        _ :: after ->
                            case after of
                                [] ->
                                    Nothing

                                _ ->
                                    -- `after` holds the pieces that FOLLOWED
                                    -- each occurrence; re-inserting the needle
                                    -- yields exactly the text past the first.
                                    Just (String.join needle after)

                        [] ->
                            Nothing
    in
    List.foldl advance (Just hay) needles /= Nothing


{-| Read one `call Rt.cStrFill(mknum(c + N), "S", mknum(0));` line of
Rt.hostEpCbuf as `( N, S )`.  `Nothing` for any other line — a malformed fill
is thereby DROPPED, which the offset-list equality in the 7D CBUF row turns
into a red row rather than a vacuous pass.
-}
cStrFillAt : String -> Maybe ( Int, String )
cStrFillAt line =
    case String.split "call Rt.cStrFill(mknum(c + " line of
        _ :: rest ->
            case rest of
                r :: _ ->
                    case
                        String.toInt (String.trim (Maybe.withDefault "" (List.head (String.split "), \"" r))))
                    of
                        Nothing ->
                            Nothing

                        Just off ->
                            case String.split "\"" r of
                                _ :: s :: _ ->
                                    Just ( off, s )

                                _ ->
                                    Nothing

                [] ->
                    Nothing

        [] ->
            Nothing


{-| STAGE 7A — the host's text helpers.  `runtimeMidText` is the surface TEXT
(as a source string), so three of the host's facts are read out of it rather
than out of a tree: the defun bodies are prose-shaped (a 20-arm if chain), and
the region marker is text by construction (run.js splices lines).
-}
{- Z2: the first line of `src` naming `needle` — the seam row's read of a CALL
   SITE (the whole-text `contains` is too coarse there: the module always
   carries `export function l $rt_glob_addr()`, and the young/plain seats are
   both seeded).
-}
z2Line : String -> String -> String
z2Line needle src =
    String.lines src
        |> List.filter (String.contains needle)
        |> List.head
        |> Maybe.withDefault "NONE"


{- Z2: the probe module the seam row lowers — one surface vecstore — printed
   for a (gc, young) flag pair.  `Err` renders its message, so a pipeline
   failure is a named red, never a vacuous pass.
-}
z2Probe : Rt.Runtime -> Bool -> Bool -> String
z2Probe r gc young_ =
    let
        probeDefuns =
            case loweredRuntime "module Wb\nexport Wb.f : val -> val\ndefun Wb.f(a : val) -> val {\n  word base = allocvec(1);\n  vecstore(base, 0, mknil);\n  return mkvec(base, 1);\n}" of
                Ok ( _, defuns ) ->
                    defuns

                Err _ ->
                    []
    in
    case QbeLower.lower r False False False True True True True gc young_ True QbeTypes.empty (rtArities probeDefuns) probeDefuns "Wb.f" of
        Ok mod ->
            Print.print mod

        Err msg ->
            "ERR:" ++ msg


defunText : String -> String -> String
defunText key src =
    let
        after =
            case String.split ("defun " ++ key ++ "(") src of
                _ :: rest ->
                    String.join ("defun " ++ key ++ "(") rest

                [] ->
                    ""
    in
    case String.split "\ndefun " after of
        body :: _ ->
            body

        [] ->
            ""


{-| Every `"Task..."` literal in a text slice, in order.  The surface forbids
non-ASCII and exercises no escapes in these names, so splitting on the quote
is exact: each element after the first starts at the opening quote's payload.
-}
ctorNames : String -> List String
ctorNames text =
    String.split "\"" text
        |> List.drop 1
        |> List.filter (\t -> String.startsWith "Task" t)
        |> List.map (\t -> Maybe.withDefault t (List.head (String.split "\"" t)))


{-| `Rt.hostArity`'s (ctor name, expected vector length) pairs, in chain order:
the name from `rawstr("...")` and the first `mknum(<digits>)` that follows it in
the same arm.
-}
hostArityPairs : String -> List ( String, Int )
hostArityPairs body =
    String.split "rawstr(\"" body
        |> List.drop 1
        |> List.filterMap
            (\piece ->
                let
                    name =
                        Maybe.withDefault "" (List.head (String.split "\"" piece))

                    tail =
                        String.split "mknum(" piece

                    digits =
                        case List.drop 1 tail of
                            d :: _ ->
                                String.toInt
                                    (String.fromList (List.filter Char.isDigit (String.toList (String.left 3 d))))

                            [] ->
                                Nothing
                in
                Maybe.map (\n -> ( name, n )) digits
            )


{-| The text run.js hands the DEFAULT route: every line from the BEGIN marker
to the END marker (inclusive) removed.  This is the Elm-side twin of
`spliceMidHost` in run.js, and it is what makes the `hosted` gate testable
without a node process.
-}
spliceRegionOut : String -> String
spliceRegionOut src =
    let
        step line ( inside, acc ) =
            if String.contains ">>> QBE_MIDHOST-ONLY" line then
                ( True, acc )

            else if String.contains "<<< QBE_MIDHOST-ONLY" line then
                ( False, acc )

            else if inside then
                ( True, acc )

            else
                ( False, line :: acc )
    in
    String.join "\n" (List.reverse (Tuple.second (List.foldl step ( False, [] ) (String.lines src))))


{-| The host's 82 REACHABLE defun keys — the enumeration `Rt.hostSeeds` must
close over.  (27 from stage 7A + stage 7B's 12 leaf/deadline defuns + stage 7C's
14 fd-table/poll defuns + stage 7D's 23 exec defuns + stage 7E's 7 dir/stat
defuns, MINUS `Rt.hostDieUnported`: 7E implemented the last two Task ctors and
DELETED that seat, so the count is 76 - 1 + 7 = 82.)

`Rt.hostSetNonblocking` JOINS the list in stage 7D: 7C declared it uncalled (the
readFile leaf asks `openat` for O_NONBLOCK itself) and left it out for exactly
that reason — the row below is an EQUALITY, so an uncalled seat is RED.  7D's
exec pipe setup is its first caller, which is what moves it from a text-only
seat into the closure.
-}
hostDefunKeys : List String
hostDefunKeys =
    [ "Rt.dieErr"
    , "Rt.hostDieErr"
    , "Rt.hostNowMs"
    , "Rt.hostInit"
    , "Rt.hostIsProgram"
    , "Rt.hostArity"
    , "Rt.apply-at"
    , "Rt.hostCall"
    , "Rt.hostClearGo"
    , "Rt.hostClearFrom"
    , "Rt.hostDeactivate"
    , "Rt.hostSpawnAt"
    , "Rt.hostSpawnFind"
    , "Rt.hostSpawn"
    , "Rt.hostSpawnFromCmd"
    , "Rt.hostPushFrame"
    , "Rt.hostDispatch"
    , "Rt.hostCompleteOk"
    , "Rt.hostCompleteErr"
    , "Rt.hostDeliver"
    , "Rt.hostStepGo"
    , "Rt.hostStep"
    , "Rt.hostStepAllGo"
    , "Rt.hostStepAll"
    , "Rt.hostRunLoop"
    , "Rt.hostRun"
    , "Rt.hostWriteAll"
    , "Rt.hostWriteStr"
    , "Rt.hostWriteFileLeaf"
    , "Rt.hostLineGrow"
    , "Rt.hostReadLineLoop"
    , "Rt.hostReadLine"
    , "Rt.hostSleepScan"
    , "Rt.hostNearestSleep"
    , "Rt.hostPollTimeout"
    , "Rt.hostSleepComplete"
    , "Rt.hostFlushExpiredSleeps"
    , "Rt.hostRunnableScan"
    , "Rt.hostRfGrow"
    , "Rt.hostReadFileDrain"
    , "Rt.hostReadFileComplete"
    , "Rt.hostLeafReadFile"
    , "Rt.hostPollFd"
    , "Rt.hostAddPoll"
    , "Rt.hostRebuildPollGo"
    , "Rt.hostRebuildPollfds"
    , "Rt.hostPollEntry"
    , "Rt.hostDrainReadyGo"
    , "Rt.hostDrainReady"
    , "Rt.hostCleanupGo"
    , "Rt.hostCleanupAll"
    , "Rt.hostSetNonblocking"
    , "Rt.hostEpCbuf"
    , "Rt.hostSingleCommandArgv"
    , "Rt.hostCloseFd"
    , "Rt.hostExecChild"
    , "Rt.hostCStrOf"
    , "Rt.hostExOutGrow"
    , "Rt.hostExErrGrow"
    , "Rt.hostExOutEof"
    , "Rt.hostExErrEof"
    , "Rt.hostExecDrainOutGo"
    , "Rt.hostExecDrainErrGo"
    , "Rt.hostExecDrainOut"
    , "Rt.hostExecDrainErr"
    , "Rt.hostRegisterChild"
    , "Rt.hostReapGo"
    , "Rt.hostReapChildren"
    , "Rt.hostReapBlockGo"
    , "Rt.hostReapBlocking"
    , "Rt.hostEpFreePlan"
    , "Rt.hostExecComplete"
    , "Rt.hostCompleteReadyGo"
    , "Rt.hostCompleteReady"
    , "Rt.hostLeafExec"
    , "Rt.hostLeafListDir"
    , "Rt.hostListDirDrain"
    , "Rt.hostListDirChunk"
    , "Rt.hostDirIsDir"
    , "Rt.hostDirRecord"
    , "Rt.hostLeafStat"
    , "Rt.hostStatRecord"
    ]


{-| The A1 layout rows' decl source: parse a declaration-only module and
hand back its `decls` (the layout pin consumes the table via
`Check.sizeofStruct`/`Check.fieldOffset`).  A parse failure yields `[]`, so
a layout row comparing on `Just n` cannot pass vacuously.
-}
declsOf : String -> List Ast.Decl
declsOf src =
    case Parse.parseModule src of
        Ok m ->
            m.decls

        Err _ ->
            []


{-| U5 — the runtime's own defuns lowered through the DECL-CARRYING entry the
runtime lane uses (`LowerToIr.lowerModule`, the same call `Mid.Rt.load`'s
`surf` makes).  The guard-selection rows compare live runtime trees against
`rt.surf`, so they must lower through the SAME entry: a runtime body that
needs its file-scoped decls (midlang-u5's `region->f` accesses need
`struct Region`) lowers to `Err` through the decl-less `lowerProgram`, which
made those rows FAIL for a reason that had nothing to do with guard selection.
-}
loweredRuntime : String -> Result String ( Ast.Program, List Defun )
loweredRuntime src =
    case Parse.parseModule src of
        Err e ->
            Err e

        Ok module_ ->
            Result.map (\defuns -> ( module_.defuns, defuns ))
                (LowerToIr.lowerModule module_)


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


{-| The A2 driver: parse + Check.checkModule + LowerToIr.lowerModule — a
DEFUN body out of a decl-carrying MODULE (the tree-equality pin's pipeline:
the field/index arms need the decls the headerless `lowl` has none of).
-}
lowlModuleBody : String -> Result String Exp
lowlModuleBody src =
    case Parse.parseModule src of
        Err e ->
            Err ("parse: " ++ e)

        Ok module_ ->
            case Check.checkModule Dict.empty [] module_ of
                Err e ->
                    Err e

                Ok () ->
                    case LowerToIr.lowerModule module_ of
                        Err e ->
                            Err e

                        Ok (d :: _) ->
                            case d.value of
                                Lam l ->
                                    Ok l.body

                                _ ->
                                    Err "lower: defun value is not a Lam"

                        Ok [] ->
                            Err "lower: no defuns"


{-| The A3 driver: a user `.mid` through the REAL pipeline to .ssa TEXT —
parse -> `Rt.checkLowerUserModule` (check + LowerToIr) -> `Mid.Qbe.Lower.lower`
-> `Print.print`.  The .ssa-level equality pin compares two of these strings
verbatim; a source that does not parse/check/lower is an `Err`, never an empty
string that would compare equal to another empty string.
-}
emitUserSsa : Rt.Runtime -> String -> Result String String
emitUserSsa rt src =
    case Rt.parseUserModule src of
        Err e ->
            Err e

        Ok parsed ->
            case Rt.checkLowerUserModule rt.exportedTypes parsed of
                Err e ->
                    Err e

                Ok m ->
                    case m.defuns of
                        d :: _ ->
                            -- B6: the module's own word-ABI table joins the
                            -- runtime's — the SAME union QbeModule.lowerAll
                            -- performs, so a row emitting a user defun with an
                            -- all-word signature sees the word ABI it would ship
                            -- with.
                            QbeLower.lower { rt | abi = Dict.union rt.abi m.abi }
                                True
                                False
                                False
                                True
                                True
                                True
                                True
                                False
                                False True
                                QbeTypes.empty
                                (rtArities m.defuns)
                                m.defuns
                                d.key
                                |> Result.map Print.print

                        [] ->
                            Err "lower: no defuns"


{-| B6: the SIGNATURE line of a one-defun user `.mid` through the real
pipeline — the ABI class made literal (`function l` = the word ABI,
`function :ret` = the value ABI).  `Err` on any pipeline failure, so a row
comparing on a signature can never pass vacuously.
-}
b6Sig : Rt.Runtime -> String -> Result String String
b6Sig rt src =
    case b6SsaAt rt "" src of
        Err e ->
            Err e

        Ok ssa ->
            case List.filter (String.startsWith "function ") (String.lines ssa) of
                line :: _ ->
                    Ok line

                [] ->
                    Err "b6Sig: no function line in the emitted .ssa"


{-| B6: the emitted `.ssa` for a whole user module with an explicit ENTRY key —
`emitUserSsa` lowers the module's FIRST defun only, which cannot show a CALL
SITE (the caller is the second defun).  An empty `entryKey` means the first
defun's key.
-}
b6SsaAt : Rt.Runtime -> String -> String -> Result String String
b6SsaAt rt entryKey src =
    case Rt.parseUserModule src of
        Err e ->
            Err e

        Ok parsed ->
            case Rt.checkLowerUserModule rt.exportedTypes parsed of
                Err e ->
                    Err e

                Ok m ->
                    case m.defuns of
                        [] ->
                            Err "b6SsaAt: no defuns"

                        d :: _ ->
                            let
                                entry =
                                    if entryKey == "" then
                                        d.key

                                    else
                                        entryKey
                            in
                            QbeLower.lower { rt | abi = Dict.union rt.abi m.abi }
                                True
                                False
                                False
                                True
                                True
                                True
                                True
                                False
                                False True
                                QbeTypes.empty
                                (rtArities m.defuns)
                                m.defuns
                                entry
                                |> Result.map Print.print


{-| B6: check + lower a user `.mid` for the REJECT/ACCEPT rows.  `Ok "ok"` on
acceptance, `Err msg` with the pipeline's own message otherwise (a PARSE
failure surfaces as `Err ("parse: " ++ e)`, so an expected-fragment row cannot
pass on a parse accident).
-}
b6CheckErr : Rt.Runtime -> String -> Result String String
b6CheckErr rt src =
    case Rt.parseUserModule src of
        Err e ->
            Err ("parse: " ++ e)

        Ok parsed ->
            Rt.checkLowerUserModule rt.exportedTypes parsed
                |> Result.map (\_ -> "ok")


{-| cffi U6 — the WORD slots 0..n-1 as BYTE offsets: `Check.fieldOffset` is
byte-granular now, and a word-class field's slot k is byte 8k.  The layout pins
below keep stating the SLOT LIST they always stated (the pre-U6 emission is the
independent record of that mapping) and convert here, so the assertion is the
same relationship measured in the table's new unit rather than an expectation
rewritten to whatever the table now says.
-}
byteSlots : Int -> List Int
byteSlots n =
    List.map (\i -> 8 * i) (List.range 0 (n - 1))


-- GC ARC unit 1b — `mknum(n)` as the lowered tree spells it: a `RawMkValue` of
-- the NUMBER tag whose single word is the literal `n`.  Used by the two
-- landmine rows to name which arm's value they are looking at, without pinning
-- the rest of the tree.
{-| The stage-1 migration's own line shape: a `val _uN = if (..)` DECLARATION
(the sites are indented arbitrarily deep; the header comment that SPELLS the
form is a `//` line and must not count).
-}
isMigratedSite : String -> Bool
isMigratedSite line =
    let
        t =
            String.trim line
    in
    String.startsWith "val _u" t && not (String.startsWith "//" t)


{-| SPELLING 3's shape reader: a branch that ends in a tail call to `key`
(an `App` on the defun's own GRef), possibly after a statement chain.
-}
tailSelfCall : String -> Exp -> Bool
tailSelfCall key e =
    case e of
        App { fn } ->
            case fn of
                GRef g ->
                    g.key == key && not g.force

                _ ->
                    False

        Unsafe (RawCall rc) ->
            rc.sym == key

        Let { body } ->
            tailSelfCall key body

        _ ->
            False


numLit : Int -> Exp -> Bool
numLit n e =
    case e of
        Unsafe (RawMkValue mk) ->
            case mk.words of
                [ Lit (LNumber m) ] ->
                    mk.tag == RtLayout.valLayout.tagNumber && m == n

                _ ->
                    False

        _ ->
            False


wordLoadIndexOf : Exp -> Maybe Int
wordLoadIndexOf body =
    case body of
        Unsafe (RawWordLoad wl) ->
            case wl.index of
                Lit (LNumber n) ->
                    Just n

                _ ->
                    Nothing

        _ ->
            Nothing


{-| A3 fixtures: the SAME defun twice — once with the postfix field spelling,
once with the raw `wload`/`wstore` spelling it must be.  A word LOCAL from
`rawcall malloc` (the A2 smoke program's real shape) rather than a param, so
the two modules' ABI is identical and only the ACCESS spelling differs.
-}
a3FieldReadMid : String
a3FieldReadMid =
    "module A3\nstruct S { f : word; g : word; }\ndefun A3.a(dummy: val) -> val {\n  *S p = rawcall malloc(16);\n  return mknum(p->g);\n}"


a3WloadReadMid : String
a3WloadReadMid =
    "module A3\nstruct S { f : word; g : word; }\ndefun A3.a(dummy: val) -> val {\n  *S p = rawcall malloc(16);\n  return mknum(wload(p, 1));\n}"


a3FieldStoreMid : String
a3FieldStoreMid =
    "module A3\nstruct S { f : word; g : word; }\ndefun A3.a(dummy: val) -> val {\n  *S p = rawcall malloc(16);\n  p->g = 7;\n  return mknil;\n}"


a3WstoreStoreMid : String
a3WstoreStoreMid =
    "module A3\nstruct S { f : word; g : word; }\ndefun A3.a(dummy: val) -> val {\n  *S p = rawcall malloc(16);\n  wstore(p, 1, 7);\n  return mknil;\n}"


{-| The one-table rows' struct: a WORD field, a VAL field (5 words INLINE) and
a word past it, so a hand-rolled second layout gets `c` wrong (2, not 6).
-}
a3OffsetDecls : String
a3OffsetDecls =
    "struct M { a : word; v : val; c : word; }"


a3OffsetMidA : String
a3OffsetMidA =
    a3OffsetDecls ++ "\ndefun Rt.a(p: *M) -> word {\n  return p->a;\n}"


a3OffsetMidC : String
a3OffsetMidC =
    a3OffsetDecls ++ "\ndefun Rt.a(p: *M) -> word {\n  return p->c;\n}"


a3ScaleMid : String
a3ScaleMid =
    a3OffsetDecls ++ "\ndefun Rt.a(p: *M, i: word) -> word {\n  return p[i];\n}"


{-| cffi U1's rows read the CARRIED signature back off the module's own decl
list (nothing else consumes it in this unit, so the parse IS the observable).
A struct/enum declaration yields nothing here, so a row asserting the exact
list cannot pass on a module whose extern failed to land.
-}
externSigOf : Ast.Decl -> Maybe Ast.FfiSig
externSigOf d =
    case d of
        Ast.ExternDecl e ->
            Just e.sig

        _ ->
            Nothing


{-| (cffi U2) the `RawCallExtern` the first statement of a lowered module body
holds, or `Nothing`.  The U2 rows' modules all begin with the typed C call as
their first `let`, so the Let spine is enough — and reading the NODE (rather
than the emitted bytes) is what pins "the widths are the DECLARATION's" at the
place the emitter reads them.
-}
ffiCallOfBody : Exp -> Maybe { sym : String, argWidths : List FfiWidth, varargs : Bool, fixedArgs : Int, result : FfiWidth }
ffiCallOfBody body =
    case b2LetValue body of
        Just (Unsafe (RawCallExtern c)) ->
            Just { sym = c.sym, argWidths = c.argWidths, varargs = c.varargs, fixedArgs = c.fixedArgs, result = c.result }

        _ ->
            Nothing


{-| The census fixture: every NEW AST constructor, with the access forms nested
INSIDE an `if`'s blocks (a Stmt list + a Term) so a walker that forgets to
descend reports a short count and the census row fails.
-}
a3CensusMid : String
a3CensusMid =
    "module C\nstruct S { f : word; g : word; }\nenum K { a = 0; b = 1; }\nextern access(path : ptr, mode : i32) -> i32;\ndefun C.a(p: *S, q: *word, i: word) -> word {\n  *word d = q;\n  p->f = *d;\n  p[1] = p->g + p->f;\n  if (mkbool(i == 1)) {\n    return p[i];\n  } else {\n    return *d;\n  }\n}"


a3CensusTags : List String
a3CensusTags =
    [ "EField"
    , "EIndex"
    , "EDeref"
    , "SFieldStore"
    , "SIndexStore"
    , "StructDecl"
    , "EnumDecl"
    , "ExternDecl"
    ]


{-| Count the census tags in a parsed source.  A PARSE FAILURE yields the empty
dict, so a census row over a source that did not even parse fails (it can never
pass on zero hits).
-}
censusOfSource : String -> Dict String Int
censusOfSource src =
    case Parse.parseModule src of
        Ok m ->
            List.foldl
                (\tag acc -> Dict.update tag (\c -> Just (Maybe.withDefault 0 c + 1)) acc)
                Dict.empty
                (censusTags m)

        Err _ ->
            Dict.empty


tagCount : String -> Dict String Int -> Int
tagCount tag counts =
    Maybe.withDefault 0 (Dict.get tag counts)


censusTags : Ast.Module -> List String
censusTags m =
    List.concatMap censusDecl m.decls ++ List.concatMap (\d -> censusBlock d.body) m.defuns


censusDecl : Ast.Decl -> List String
censusDecl d =
    case d of
        Ast.StructDecl _ ->
            [ "StructDecl" ]

        Ast.EnumDecl _ ->
            [ "EnumDecl" ]

        Ast.ExternDecl _ ->
            [ "ExternDecl" ]


censusBlock : Ast.Block -> List String
censusBlock b =
    List.concatMap censusStmt b.stmts ++ censusTerm b.term


censusStmt : Ast.Stmt -> List String
censusStmt s =
    case s of
        Ast.SBind _ _ e ->
            "SBind" :: censusExp e

        Ast.SEffect e ->
            censusExp e

        Ast.SIf c t me ->
            censusExp c
                ++ censusBlock t
                ++ Maybe.withDefault [] (Maybe.map censusBlock me)

        Ast.SFieldStore p f v ->
            "SFieldStore" :: (censusExp p ++ censusExp v)

        Ast.SIndexStore p i v ->
            "SIndexStore" :: (censusExp p ++ censusExp i ++ censusExp v)

        Ast.SStructBind rec ->
            "SStructBind" :: censusInit rec.init

        Ast.SArrayBind rec ->
            "SArrayBind" :: censusArrayInit rec.init

        Ast.SVarStore _ v ->
            "SVarStore" :: censusExp v

        Ast.SWhile c b ->
            "SWhile" :: (censusExp c ++ censusBlock b)

        Ast.SDoWhile b c ->
            "SDoWhile" :: (censusBlock b ++ censusExp c)

        Ast.SFor rec ->
            "SFor"
                :: (Maybe.withDefault [] (Maybe.map censusStmt rec.init)
                        ++ censusExp rec.cond
                        ++ Maybe.withDefault [] (Maybe.map censusStmt rec.step)
                        ++ censusBlock rec.body
                   )


censusInit : Ast.StructInit -> List String
censusInit init =
    case init of
        Ast.InitZero ->
            []

        Ast.InitFields fields ->
            List.concatMap (\( _, e ) -> censusExp e) fields

        Ast.InitCopy e ->
            censusExp e


censusArrayInit : Ast.ArrayInit -> List String
censusArrayInit init =
    case init of
        Ast.AInitZero ->
            []

        Ast.AInitFull es ->
            List.concatMap censusExp es


censusTerm : Ast.Term -> List String
censusTerm t =
    case t of
        Ast.TRet e ->
            censusExp e

        Ast.TRecur es ->
            List.concatMap censusExp es

        Ast.TIf c t1 me ->
            censusExp c
                ++ censusBlock t1
                ++ Maybe.withDefault [] (Maybe.map censusBlock me)

        Ast.TBreak ->
            []

        Ast.TContinue ->
            []


censusExp : Ast.Exp -> List String
censusExp e =
    case e of
        Ast.EField p _ ->
            "EField" :: censusExp p

        Ast.EIndex p i ->
            "EIndex" :: (censusExp p ++ censusExp i)

        Ast.EDeref p ->
            "EDeref" :: censusExp p

        Ast.EWordBin _ a b ->
            "EWordBin" :: (censusExp a ++ censusExp b)

        Ast.EWordCmp _ a b ->
            censusExp a ++ censusExp b

        Ast.EFltBin _ a b ->
            censusExp a ++ censusExp b

        Ast.EFltCmp _ a b ->
            censusExp a ++ censusExp b

        Ast.EShortAnd a b ->
            censusExp a ++ censusExp b

        Ast.EShortOr a b ->
            censusExp a ++ censusExp b

        Ast.EIf c a b ->
            censusExp c ++ censusExp a ++ censusExp b

        Ast.EIfBlock c t f ->
            censusExp c ++ censusBlock t ++ censusBlock f

        Ast.ECall _ es ->
            List.concatMap censusExp es

        Ast.ERawCall _ es ->
            List.concatMap censusExp es

        Ast.EAggCall _ f es ->
            censusExp f ++ List.concatMap censusExp es

        Ast.EBuiltin _ es ->
            List.concatMap censusExp es

        Ast.EWithRoots _ b ->
            censusBlock b

        Ast.ECast _ inner ->
            "ECast" :: censusExp inner

        Ast.ESizeof _ ->
            ["ESizeof"]

        Ast.EAddrOf inner ->
            "EAddrOf" :: censusExp inner

        Ast.EBool _ ->
            ["EBool"]

        Ast.EInt _ ->
            []

        Ast.EFlt _ ->
            []

        Ast.EStr _ ->
            []

        Ast.EVar _ ->
            []


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

        Loop l ->
            let
                ( c1, st1 ) =
                    cexp st l.cond

                ( b1, st2 ) =
                    cexp st1 l.body
            in
            ( Loop { cond = c1, body = b1 }, st2 )

        Break ->
            ( Break, st )

        Continue ->
            ( Continue, st )

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

        RawMemLoad r ->
            let
                ( x1, st1 ) =
                    cexp st r.ptr
            in
            ( RawMemLoad { r | ptr = x1 }, st1 )

        RawMemStore r ->
            cnode2 st r .ptr .value RawMemStore (\rec a b -> { rec | ptr = a, value = b })

        RawCallRaw r ->
            let
                ( args, st1 ) =
                    cexps st r.args
            in
            ( RawCallRaw { r | args = args }, st1 )

        RawCallExtern r ->
            let
                ( args, st1 ) =
                    cexps st r.args
            in
            ( RawCallExtern { r | args = args }, st1 )

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

        RawAllocN _ ->
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
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagNumber, words = [ w ] })


lmkBool : Exp -> Exp
lmkBool w =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagBoolean, words = [ w ] })


lmkNilV : Exp
lmkNilV =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagNil, words = [] })


lmkStr : Exp -> Exp -> Exp
lmkStr d l =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagString, words = [ d, l ] })


lmkVec : Exp -> Exp -> Exp
lmkVec d l =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagVector, words = [ d, l ] })


lmkFlt : Exp -> Exp
lmkFlt f =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagFloat, words = [ f ] })


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


{-| The P5 PLeaf probe: a 0-ary SURFACE defun (a non-Rt key, so the generic
closure ABI) whose body is one number literal — no call, no frame address, no
safepoint — which is exactly the class the P5 classification must emit WITHOUT
a pooled frame.  Kept beside the other probes so the emitted-text row above
compiles it through the real `lower`.
-}
leafProbe : Defun
leafProbe =
    { key = "Lf.f"
    , value =
        Lam
            { params = []
            , body = Lit (LNumber 42)
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


{-| The DRIVER ROUTE's program: the prim half PLUS the collector half.
Since stage 6 A3a, Rt.main has a REAL surface body (the A3a slice: usage +
toomany + rlimit), so it is already part of `rtProgram` — the A1 `rtMainStub`
stand-in is gone (appending it would now emit a SECOND Rt.main and a duplicate
`main` symbol).
ZIGHOST Z0 made the collector half MANDATORY here: the Mid allocation seats
(Rt.allocVector/Rt.allocRaw) are what every Con/vector/string/closure site
lowers to now, so a program that omits `rtProgramGc` fails the lowering LOUDLY
("qbe: unknown global Rt.allocVector") — which is exactly how the rows below
went red until this union matched what Mid.QbeModule actually emits.
-}
driverProg : Rt.Runtime -> List Defun
driverProg rt =
    rtProgram rt True True True ++ rtProgramGc rt True True True


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


{-| P1e bulk-zero shape: ONE `memset(dst, 0, 40 * nslots)` — 3 args with the
zero byte constant in the middle, a `40 * x` Mul feeding the byte length (a
Value is 40 bytes), and NO `q_Rt_x2eframeZero` call or in-frame loop.  The
per-slot frameZero loop this replaced pinned the OPPOSITE properties (a
self-loop, no blit); the bulk-zero has no loop at all.

TWO accepted operand shapes, and they are the SAME call: cffi U5 declared
`memset(dst : ptr, c : i32, n : i64) -> ptr` in runtime.mid, so frame-enter's
surface site emits the declared boundary (`w` for the C `int` middle argument)
where it emitted the all-word convention (`Base L` everywhere).  Both arms
require the CONSTANT 0 in the same position and a `Tmp` byte length, so the
assertion is not weakened by admitting the declared one — and the pre-U5 arm
stays so the row can still fail for the reason it was written for.
-}
memsetBulkZeroShape : Il.Func -> Bool
memsetBulkZeroShape f =
    symCount "memset" f
        == 1
        && List.any
            (\b ->
                List.any
                    (\i ->
                        case i of
                            Il.Call _ (Il.Base Il.L) (Il.Sym "memset") [ Il.ArgVal (Il.Base Il.L) _, Il.ArgVal (Il.Base Il.W) (Il.Con 0), Il.ArgVal (Il.Base Il.L) (Il.Tmp _) ] ->
                                True

                            Il.Call _ (Il.Base Il.L) (Il.Sym "memset") [ Il.ArgVal (Il.Base Il.L) _, Il.ArgVal (Il.Base Il.L) (Il.Con 0), Il.ArgVal (Il.Base Il.L) (Il.Tmp _) ] ->
                                True

                            _ ->
                                False
                    )
                    b.body
            )
            f.blocks
        && List.any
            (\b ->
                List.any
                    (\i ->
                        case i of
                            Il.Bin _ Il.L Il.Mul (Il.Con 40) _ ->
                                True

                            _ ->
                                False
                    )
                    b.body
            )
            f.blocks
        && not (callsSym "q_Rt_x2eframeZero" f)


{-| P1e zero-BEFORE-root: in frame-enter's straight-line body the bulk-zero
`memset` is emitted before `q_Rt_x2erootPushValueArray`.  The correctness order
from rt.zig:279 — a reused block's stale slots must be zeroed before the GC
can scan them, or scanValue chases freed pages.
-}
memsetBeforeRootPush : Il.Func -> Bool
memsetBeforeRootPush f =
    let
        insts =
            List.concatMap (\b -> b.body) f.blocks

        isSym sym i =
            case i of
                Il.Call _ _ (Il.Sym s) _ ->
                    s == sym

                _ ->
                    False

        first pred =
            List.head
                (List.filterMap
                    (\( ix, i ) ->
                        if pred i then
                            Just ix

                        else
                            Nothing
                    )
                    (List.indexedMap Tuple.pair insts)
                )
    in
    case ( first (isSym "memset"), first (isSym "q_Rt_x2erootPushValueArray") ) of
        ( Just m, Just p ) ->
            m < p

        _ ->
            False


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


{-| B1 root-order: within ONE block, `q_Rt_x2erootPushPtr` must precede the
allocating seat and a word LOAD must follow the alloc (the `wload(sp, 3)`
re-read).  Both the push-after-alloc and the pre-alloc-copy mutations break
this — the first puts the alloc before the push (the `seenPush` guard fires),
the second removes the re-read (no Load is ever seen after the alloc).
RE-PINNED AT ZIGHOST Z0: the alloc is the Mid seat `q_Rt_x2eallocVector` (an
`aggcall val`), not the Zig barrier's `rt_vec_alloc` — the escape route that
spelled the latter is deleted.  THE HALF THAT GOT WEAKER, stated: the seat's
own emission ENDS in a load (the payload read-back, Lower.midGcAllocSeat), so
"a Load after push+alloc" no longer distinguishes the `sp->env` re-read from
that read-back.  The order half (push BEFORE the alloc) is unchanged and is
the one the cStrFill lesson is about.
-}
partialRootOrder : Il.Func -> Bool
partialRootOrder f =
    List.any blockRootOrder f.blocks


blockRootOrder : Il.Block -> Bool
blockRootOrder b =
    rootOrderStep False False b.body


rootOrderStep : Bool -> Bool -> List Il.Inst -> Bool
rootOrderStep seenPush seenAlloc instrs =
    case instrs of
        [] ->
            False

        i :: rest ->
            case i of
                Il.Call _ _ (Il.Sym s) _ ->
                    if s == "q_Rt_x2erootPushPtr" then
                        rootOrderStep True seenAlloc rest

                    else if s == "q_Rt_x2eallocVector" then
                        -- the alloc must come AFTER the env-root push.
                        if seenPush then
                            rootOrderStep seenPush True rest

                        else
                            False

                    else
                        rootOrderStep seenPush seenAlloc rest

                Il.Load _ _ _ _ ->
                    -- a word load reached after BOTH the push and the alloc is
                    -- the re-read (wload(sp, 3)); a load before the alloc is
                    -- the pre-alloc env read, which must not be the copy source.
                    if seenPush && seenAlloc then
                        True

                    else
                        rootOrderStep seenPush seenAlloc rest

                _ ->
                    rootOrderStep seenPush seenAlloc rest


{-| T7: `rt.program` is now the SURFACE PIPELINE (Result-valued — a bad
`Mid.RtSource` text must fail the compile, never shrink the runtime); the
pre-T7 rows read the List it produces.  With `Mid.RtSource.source = []` the
pipeline is the identity, so this unwrap cannot fail while the T7 rows are
green — and the dedicated T7 identity row asserts the `Ok` DIRECTLY, so a
broken pipeline turns red there first, loudly.
-}
-- THE COLLECTOR SLOT of Mid.QbeModule's call shape, as
-- selfhost/NativeMain.elm spells it (a HAND-COPIED twin — Elm cannot read the
-- other driver).  The hatch this constant used to mirror is RETIRED (zighost
-- Z0): run.js has no QBE_MIDGC any more, and QbeLower.lower binds the slot
-- `_midGc`, unread.  So the VALUE no longer selects anything; the constant
-- exists so the two drivers' call shapes stay legible and cannot drift apart
-- silently, and the row above pins it together with the route that is now
-- unconditional.
defaultMidGc : Bool
defaultMidGc =
    True


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
    , abi = Dict.empty
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


{-| Does a body carry a `:val` aggregate call or a 40-byte blit?  A rawAbi word
loop (the copyWords pair) must contain NEITHER — a word defun's loop should be
pure word loads/stores and an in-frame jmp, never a Value copy.
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


{-| The nested word-tail If fixture (stage 6 B0perf-2 BLOCKER fix): a rawAbi
WORD defun whose tail is an If whose ELSE branch is ITSELF an If — one branch
closes TWO blocks.  The ret-bound arm returns the param word `msg` (a0); every
other arm self-tails.  The buggy join read only the INNER else's `jmp @body`
and silently dropped `msg` (join -> `Il.Con 0`); the fix threads the
`TailShape`, so the ret-bound arm's word survives end-to-end to `@ret`.
-}
nestedWordTailIfSrc : String
nestedWordTailIfSrc =
    "defun Rt.die(msg : word) -> word {\n  word i = wload(msg, 4);\n  if (mkbool(i == 0)) {\n    recur(msg);\n  } else {\n    if (mkbool(i == 1)) {\n      return msg;\n    } else {\n      recur(msg);\n    }\n  }\n}\n"


{-| Does a func's @ret block return the given word?  A rawAbi word defun's
final block is labelled `ret` and jumps `Ret (Just <word>)` — the seat the
nested-If fix must hand the surviving branch word to.
-}
retBlockReturns : Il.Arg -> Il.Func -> Bool
retBlockReturns w f =
    List.any
        (\b -> b.label == "ret" && b.jump == Il.Ret (Just w))
        f.blocks


{-| GC ARC unit 4 — the mark-stack geometry as a PURE FUNCTION OF THE CEILING,
mirroring Rt.gcInit's derivation (a TestMain row cannot execute Mid, so the row
mirrors the formula and goes RED if its SHAPE is deleted; the LIVE check is the
runtime guard, proven by probe-midgc-guards.sh).  Returns (capacity, the largest
block count the ceiling can hold).  Capacity = capWords/8 + 64 entries and the
largest block count = capBytes/64 = capWords/8, so the margin is the CONSTANT 64
at every ceiling — that constant is what a "sized for the initial heap"
substitution destroys (it would put the margin at ZERO the moment the heap
grows).
-}
marginParts : Int -> ( Int, Int )
marginParts capMB =
    let
        capBytes =
            capMB * 1024 * 1024

        capWords =
            capBytes // 8

        markEnd =
            64 + capWords // 8 + 64

        numClasses =
            1
                + (if capWords <= 4096 then
                    (capWords + 7) // 8

                   else
                    512 + (capWords - 4096 + 4095) // 4096
                  )

        heapStart =
            markEnd * 8 + numClasses * 8 + 16

        capEnd =
            heapStart + capBytes
    in
    ( markEnd - 64, (capEnd - heapStart) // 64 )


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

        Loop block ->
            rawCallSyms block.cond ++ rawCallSyms block.body

        Break ->
            []

        Continue ->
            []

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

                RawMemLoad ml ->
                    rawCallSyms ml.ptr

                RawMemStore ms ->
                    rawCallSyms ms.ptr ++ rawCallSyms ms.value

                RawCallRaw seat ->
                    List.concatMap rawCallSyms seat.args

                RawCallExtern seat ->
                    List.concatMap rawCallSyms seat.args

                RawCallAgg call ->
                    rawCallSyms call.fn ++ List.concatMap rawCallSyms call.args

                RawDataAddr _ ->
                    []

                RawCStr _ ->
                    []

                RawSym _ ->
                    []

                RawAllocN _ ->
                    []


