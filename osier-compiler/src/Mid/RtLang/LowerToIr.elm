module Mid.RtLang.LowerToIr exposing
    ( lowerModule
    , lowerProgram
    )

{-| Mid.RtLang.LowerToIr — the surface language's LOWERER (tier-2 plan,
`handoff-osier-tier2-midlang-plan`, THE STATEMENT->EXPRESSION LOWERING
L1-L7): a checked `Mid.RtLang.Ast.Program` (T4/T5's `Check.checkProgram`
must have accepted it) goes in, `List Mid.Ir.Defun` comes out — the exact
trees the hand-rolled Elm DSL (Mid.RtPrims / Mid.RtGc) builds by hand.

Mid has NO CFG, NO join and NO early-return: a `Defun.value` is ONE nested
`Exp` whose head is a `Lam`.  The statement layer therefore lowers as
nested expression forms, rule by rule (the plan's numbering kept):

  * **L1** — `ty x = e; rest` -> `Let { binders = [ LetBind { binder, value
    = e } ], body = lower rest }`.  ONE binder per `Let`, nested to the
    LEFT — the DSL's `lets` shape (RtPrims.elm:145-156).  Binder ids come
    from a PER-DEFUN counter (params first: id 1..n, mirroring the DSL's
    `p1..p5`; locals continue n+1, n+2, ...).  Ids are Dict KEYS in the
    backend (plan fact F1: `binderSlots`/`rawWord : Dict Int`, never
    emitted), so they must be UNIQUE ACROSS THE WHOLE DEFUN — including
    across DISJOINT if-branches, where a collision would make two binders
    share one backend slot (the execGo b-100..277 discipline) — and the
    state is therefore threaded strictly sequentially through every
    subtree.  `name` = the surface id (provenance only; emission never
    reads it, Mid.Ir's Binder contract).
  * **L2** — an effect statement `e; rest` lowers exactly like L1 but with
    a FRESH UNUSED binder (the DSL's `(b 107, rStore ...)` dead-binding
    shape; the store builtins' result slot must be filled with a valid
    binder even though nothing reads it).
  * **L3** — `return e;` is the block's VALUE (`e` itself); a defun's last
    `return` is its `Lam` body.  Built by `lam`'s exact shape
    (RtPrims.elm:388-393): `{ key = key, value = Lam { params, body } }`.
  * **L4** — `recur(a..);` -> `App { fn = GRef { key = OWN key, force =
    False }, args }` — THE ONLY LOOP (MEASURED: all 31 DSL sites are this
    saturated non-forced self-GRef shape; the classifier grants
    edge-not-safepoint regardless of tailness, plan fact F3).
  * **L5** — a TERMINATING `if (c) A else B` (the block's value) lowers to
    `If { cond, thenBranch = lower A, elseBranch = lower B }` — both
    branches as block values.  A missing `else` lowers the false path to
    `mknil` (the DSL's dead-value convention: `haltV` = `(lets [(b 30,
    callW "rt_halt" [])] mkNil)` — a value the defun never returns because
    the true path diverged).  The LABEL STRINGS are IGNORED by the backend
    (plan fact F1: Lower invents `then_N/else_N/join_N` and never reads
    the tree's strings), so this module allocates readable per-defun
    `else_N`/`join_N` labels from its own counter; byte identity depends
    only on tree SHAPE.
  * **L6** — a MID-BLOCK `if` (an `SIf` statement) is a GUARD: at least one
    branch DIVERGES (Check J7; both-falling is a reject), and the
    CONTINUATION moves into the NON-DIVERGING branch — `if (c) { return x; }
    rest..` -> `If { c, then = x, else = lower rest.. }`, and symmetrically
    when only the else diverges.  So a `return` in a statement `if` EXITS:
    the arm it is in is that branch's value and the rest of the block is not
    reachable from it.
    BOTH branches diverging (a `return`/`recur` in each, or a both-diverging
    `if` nested in one) -> the `If` IS the block's value and the statements
    after it are UNREACHABLE, so they are not lowered at all (they ARE
    dropped from the emit — the C rule).  THIS ARM WAS THE LANDMINE until
    the return-flip unit: it used to bind the `If` to a fresh DEAD binder
    and CONTINUE, so a both-returning statement `if` silently fell through
    and its continuation ran whatever the condition.  69 sites in
    runtime.mid depended on that; they were migrated to a conditional-VALUE
    declaration (`val u = if (c) { ..; return x; } else { ..; return y; };`,
    where `return` is the BRANCH's value by L3) before the arm changed, so
    this tree's emit is byte-identical under both arms.
    If the lowerer still sees both branches FALL THROUGH it is a LOUD
    internal error naming the judgment, never a silent choice.
  * **L7** — the owner's example shape (`if (region != 0) { return
    mknum(region); } base = rawcall mmap(..); ..`) lowers by the L6
    else-nesting rule exactly as written (pinned by a TestMain row).

Expressions lower 1:1 onto `Mid.Ir`: the four operator families onto
`RawBin`/`RawCmp`/`RawFltBin`/`RawFltCmp` (constructor-by-constructor — a
new surface op without a row here is a compile error), `&& ||` verbatim
onto `ShortAnd`/`ShortOr`, `call`->`RawCall`, `rawcall`->`RawCallRaw`,
`aggcall`->`RawCallAgg` (`shape` = `"ret"`/`"val"`, exactly Lower's two
accepted strings), `withroots`->`WithRoots` (ids resolved to their in-scope
binder records), and the builtins onto `UnsafeNode`s per `Ast.builtinClass`
— including the two MEASURED macros: `reclen` expands to RtPrims'
`recLenOf` 3-node tree (RtPrims.elm:216-228) and `len32` to
`RawPayload32` word 1.  Nothing else is invented.

LITERAL SLOTS.  `mkval`'s tag and the index/tag slots of
`payload`/`payload32`/`tagis` are CONSTANTS inside their lowered nodes
(`RawMkValue.tag : Int`, `RawPayload.word : Int`, `RawTagIs.tag : Int`),
so the lowerer requires those AST arguments to be `EInt` literals — the
same unrepresentable-else-reject discipline the parser applies to its
literal token slots.  A computed tag cannot lower; that is a loud internal
error naming the gap, never a silent guess.

TRUSTED INPUT.  Classes, arities, name binding, recur saturation and the
divergence rules were checked by `Mid.RtLang.Check` (J1-J8, J10); this
module re-derives only what its OWN rules need (`diverges`, mirrored from
Check's J7 predicate because the else-nesting rule reads it) and turns
every should-be-impossible shape into a loud internal error naming the
judgment that should have rejected it.  A CHECKED program cannot reach
them; they exist so a lowerer/checker drift fails loudly instead of
lowering a wrong tree.

SELFHOST DISCIPLINE (the mid-lane hazard, Rt.elm:531-545): every helper is
a TOP-LEVEL definition — the mutually recursive walk (`lowerExp` ⇄
`lowerStmt` ⇄ `lowerRest` ⇄ `lowerTerm` ⇄ `lowerBlock`) closes through
top-level bodies, never let-bound.  Only `Dict`/`List`/`String` functions
MEASURED in the selfhost's merged table are used (`List.reverse`,
`List.length`, `String.fromInt`, `String.startsWith`, `++`).

BACKEND-NEUTRAL (the `Mid.Rt` contract): imports are `Dict`, `Mid.Ir`,
`Mid.RtLang.Ast`, `Mid.RtLang.Check` (only the layout TABLE readers —
`fieldOffset`/`sizeofStruct`, the one-table property) and `Mid.RtLayout` (the
tag constants — the same single source of truth RtPrims/RtGc read).  No QBE
type appears here.

NOT WIRED YET: nothing outside `TestMain` imports this module — T7 splices
`lowerProgram`'s output into `Mid.Rt.program`.  The corpus hash is the
emit-inert oracle.

-}

import Dict exposing (Dict)
import Mid.Ir exposing (Binder, Defun, Exp(..), FfiWidth(..), LetBinder(..), Lit(..), MemWidth(..), RawBinOp(..), RawCmpOp(..), RawFltBinOp(..), RawFltCmpOp(..), RawUnOp(..), UnsafeNode(..))
import Mid.RtLang.Ast as Ast
import Mid.RtLang.Ast
    exposing
        ( AggShape(..)
        , ArrayInit(..)
        , Builtin(..)
        , Block
        , Decl(..)
        , Field
        , FltBinOp(..)
        , FltCmpOp(..)
        , Module
        , PTy(..)
        , Param
        , Program
        , Stmt(..)
        , StructInit(..)
        , TailTarget(..)
        , Term(..)
        , Type(..)
        , WordBinOp(..)
        , WordCmpOp(..)
        , builtinName
        )
import Mid.RtLang.Check as Check
import Mid.RtLayout as RtLayout



-- ============================ the lowering state ============================


{-| Per-defun lowering state.  `nextId` hands out binder ids (unique across
the WHOLE defun — the backend keys its slot dicts by them, plan fact F1);
`nextLbl` hands out the If/ShortAnd/ShortOr label strings (IGNORED by the
backend — readability only); `scope` maps surface names to binder ids; `key`
is the defun's own key (L4's self-GRef target); `types` is the DECLARED class
of every binder in scope; `decls` is the file's struct/enum table; `ret` is
the defun's declared result class (B1: the `return` site needs it to know
whether a bool operand goes through the bool→val BOX).
-}
type alias St =
    { key : String
    , nextId : Int
    , nextLbl : Int
    , scope : Dict String Int
    , types : Dict String Ast.Type
    , decls : List Decl
    , ret : Ast.Type
    , cells : Dict String () -- B4: the AUTO-CELL set — every binder assigned anywhere in this defun
    }


{-| A fresh binder: provenance name = the surface id, id = the next counter
value.
-}
fresh : String -> St -> ( Binder, St )
fresh name st =
    ( { id = st.nextId, name = name }
    , { st | nextId = st.nextId + 1 }
    )


{-| The label pair an `If`/`ShortAnd`/`ShortOr` node carries.  The backend
INVENTS its own labels (plan fact F1) and never reads these strings.
-}
freshLabels : St -> ( String, String, St )
freshLabels st =
    ( "else_" ++ String.fromInt st.nextLbl
    , "join_" ++ String.fromInt st.nextLbl
    , { st | nextLbl = st.nextLbl + 1 }
    )


-- VR3a: the RawMkValue tags below are the VALUE LAYOUT's tag numbers, read
-- from the single instance `RtLayout.valLayout` — this module builds Mid IR
-- before any emitter state exists, so it names the instance rather than
-- threading it.  VR3b (the word arm, whose tag ENCODING differs) must thread
-- the layout through this module's own state; the sites are all marked by the
-- `RtLayout.valLayout.` prefix, so that sweep is a search, not a re-read.
mkNilExp : Exp
mkNilExp =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagNil, words = [] })



-- ==================== B4: AUTO-CELLS (the loop-carried word local) ====================


{-| The CELL CLASS — the types that need an `allocN` cell to be assignable.
`word`/`int` (one class), `bool` (the 0/1 word) and `*T` (a pointer IS a word)
are raw REGISTERS in this lowering, and a register cannot be live across a
back edge without a phi.  The three EXCLUSIONS are memory already: `val` is a
40-byte rooted frame slot, `float` is a `d` register (never let-bound at all,
J1), and a struct/array value IS the address of its own block.
-}
scalarWordTy : Ast.Type -> Bool
scalarWordTy ty =
    case ty of
        Ast.TWord ->
            True

        Ast.TBool ->
            True

        Ast.TPtr _ ->
            True

        _ ->
            False


{-| Is this binder a CELL?  Two facts, both syntactic: it is ASSIGNED
somewhere in the defun (`st.cells`) and its declared class is a raw word
(`scalarWordTy`).  The judgment is DEFUN-WIDE on purpose — "assigned anywhere"
is a superset of "loop-carried", so there is no loop analysis to mis-scope
(R3), and an assigned binder behaves the same inside and outside a loop.
-}
isCell : St -> String -> Bool
isCell st name =
    Dict.member name st.cells
        && (case Dict.get name st.types of
                Just ty ->
                    scalarWordTy ty

                Nothing ->
                    False
           )


{-| Every binder NAME assigned anywhere in the block (the auto-cell candidate
set — narrowed to the raw-word class at each use by `isCell`).  Statements are
walked through nested ifs and loops; expressions are walked because a
block-branch `if` expression (`.. ? {..} : {..}`, `EIfBlock`) carries blocks.
Names suffice as the key: this language keeps ONE flat scope per defun (a
duplicate declaration is J5's reject), so a name has one meaning.
-}
assignedNames : Block -> Dict String ()
assignedNames b =
    Dict.union (blockAssigned b) Dict.empty


blockAssigned : Block -> Dict String ()
blockAssigned b =
    List.foldl (\stmt acc -> Dict.union (stmtAssigned stmt) acc)
        (termAssigned b.term)
        b.stmts


termAssigned : Term -> Dict String ()
termAssigned term =
    case term of
        TRet e ->
            expAssigned e

        TRecur es ->
            List.foldl (\e acc -> Dict.union (expAssigned e) acc) Dict.empty es

        TIf c t me ->
            Dict.union (expAssigned c)
                (Dict.union (blockAssigned t)
                    (case me of
                        Just eb ->
                            blockAssigned eb

                        Nothing ->
                            Dict.empty
                    )
                )

        -- U1: a tail call's arguments are ordinary expressions, so their
        -- assignments count for the auto-cell judgment exactly as a `return`'s
        -- would.
        TTailCall tc ->
            List.foldl (\e acc -> Dict.union (expAssigned e) acc) Dict.empty tc.args

        TBreak ->
            Dict.empty

        TContinue ->
            Dict.empty


stmtAssigned : Stmt -> Dict String ()
stmtAssigned stmt =
    case stmt of
        SVarStore name e ->
            Dict.insert name () (expAssigned e)

        SBind _ _ e ->
            expAssigned e

        SEffect e ->
            expAssigned e

        SIf c t me ->
            Dict.union (expAssigned c)
                (Dict.union (blockAssigned t)
                    (case me of
                        Just eb ->
                            blockAssigned eb

                        Nothing ->
                            Dict.empty
                    )
                )

        SFieldStore p _ e ->
            Dict.union (expAssigned p) (expAssigned e)

        SIndexStore p i e ->
            Dict.union (expAssigned p) (Dict.union (expAssigned i) (expAssigned e))

        SStructBind rec ->
            structInitAssigned rec.init

        SArrayBind rec ->
            arrayInitAssigned rec.init

        SWhile c b ->
            Dict.union (expAssigned c) (blockAssigned b)

        SDoWhile b c ->
            Dict.union (blockAssigned b) (expAssigned c)

        SFor rec ->
            Dict.union
                (case rec.init of
                    Just st ->
                        stmtAssigned st

                    Nothing ->
                        Dict.empty
                )
                (Dict.union (expAssigned rec.cond)
                    (Dict.union
                        (case rec.step of
                            Just st ->
                                stmtAssigned st

                            Nothing ->
                                Dict.empty
                        )
                        (blockAssigned rec.body)
                    )
                )


structInitAssigned : StructInit -> Dict String ()
structInitAssigned init =
    case init of
        InitZero ->
            Dict.empty

        InitCopy e ->
            expAssigned e

        InitFields fields ->
            List.foldl (\( _, e ) acc -> Dict.union (expAssigned e) acc) Dict.empty fields


arrayInitAssigned : ArrayInit -> Dict String ()
arrayInitAssigned init =
    case init of
        AInitZero ->
            Dict.empty

        AInitFull es ->
            List.foldl (\e acc -> Dict.union (expAssigned e) acc) Dict.empty es


expAssigned : Ast.Exp -> Dict String ()
expAssigned e =
    case e of
        Ast.EIfBlock c t el ->
            Dict.union (expAssigned c) (Dict.union (blockAssigned t) (blockAssigned el))

        Ast.EWithRoots _ b ->
            blockAssigned b

        Ast.EInt _ ->
            Dict.empty

        Ast.EFlt _ ->
            Dict.empty

        Ast.EStr _ ->
            Dict.empty

        Ast.EBool _ ->
            Dict.empty

        Ast.EVar _ ->
            Dict.empty

        Ast.EWordBin _ a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EWordCmp _ a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EFltBin _ a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EFltCmp _ a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EShortAnd a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EShortOr a b ->
            Dict.union (expAssigned a) (expAssigned b)

        Ast.EIf a b c ->
            Dict.union (expAssigned a) (Dict.union (expAssigned b) (expAssigned c))

        Ast.ECall _ es ->
            List.foldl (\x acc -> Dict.union (expAssigned x) acc) Dict.empty es

        Ast.ERawCall _ es ->
            List.foldl (\x acc -> Dict.union (expAssigned x) acc) Dict.empty es

        Ast.EAggCall _ fn es ->
            List.foldl (\x acc -> Dict.union (expAssigned x) acc) (expAssigned fn) es

        Ast.EBuiltin _ es ->
            List.foldl (\x acc -> Dict.union (expAssigned x) acc) Dict.empty es

        Ast.EField base _ ->
            expAssigned base

        Ast.EIndex base i ->
            Dict.union (expAssigned base) (expAssigned i)

        Ast.EDeref x ->
            expAssigned x

        Ast.ECast _ x ->
            expAssigned x

        Ast.ESizeof _ ->
            Dict.empty

        Ast.EAddrOf x ->
            expAssigned x


-- ==================== B4: THE STATEMENT REWRITES ====================


{-| `for (init; c; step) B` — `continue` RUNS the step (C semantics), ONCE per
iteration.  Two different rewrites, and conflating them double-runs the step:

  * at the loop BODY's own reachable ends (`forTail`) — the fall-through and
    a tail `if`'s falling path — the step is appended, because falling off
    the body must advance the loop exactly as an explicit `continue` does;
  * inside the body, at a block whose term IS `TContinue` (a `continue;`
    site, `forContinueBlock`), the step is appended too.

What is NOT rewritten is a block that merely falls THROUGH inside the body:
its fall-through continues the enclosing block's flow (whose end gets the
step once).  Nothing crosses into a NESTED loop — its continues are its own.
-}
forBody : Maybe Stmt -> Block -> Block
forBody step body =
    case step of
        Nothing ->
            body

        Just st ->
            forTail st body


{-| The body's own ends: `TContinue`, and a tail `if` whose falling paths
leave the block.  A `TIf` with both arms explicit recurses into BOTH (each is
an end of this block).
-}
forTail : Stmt -> Block -> Block
forTail step b =
    let
        stmts1 =
            List.map (forStmt step) b.stmts
    in
    case b.term of
        TContinue ->
            { stmts = stmts1 ++ [ step ], term = TContinue }

        TIf c t Nothing ->
            -- the then-branch diverges (J7), so as a MID-BLOCK if it is legal
            -- and its false path is the continuation: the step, then the next
            -- iteration.  The BRANCH ITSELF is rewritten too — a `continue;`
            -- inside it is a continue site like any other, and leaving it
            -- alone is a continue that SKIPS the step (MEASURED: exactly this
            -- arm, found by this row — one step store where there should be
            -- two, i.e. an infinite loop in the .ssa).
            { stmts = stmts1 ++ [ SIf c (forContinueBlock step t) Nothing, step ]
            , term = TContinue
            }

        TIf c t (Just eb) ->
            { stmts = stmts1
            , term = TIf c (forTail step t) (Just (forTail step eb))
            }

        other ->
            { stmts = stmts1, term = other }


{-| A block reached through a STATEMENT (an `if`'s branch): only its explicit
`continue;` sites take the step.
-}
forContinueBlock : Stmt -> Block -> Block
forContinueBlock step b =
    let
        stmts1 =
            List.map (forStmt step) b.stmts
    in
    case b.term of
        TContinue ->
            { stmts = stmts1 ++ [ step ], term = TContinue }

        TIf c t me ->
            { stmts = stmts1
            , term = TIf c (forContinueBlock step t) (Maybe.map (forContinueBlock step) me)
            }

        other ->
            { stmts = stmts1, term = other }


forStmt : Stmt -> Stmt -> Stmt
forStmt step stmt =
    case stmt of
        SIf c t me ->
            SIf c (forContinueBlock step t) (Maybe.map (forContinueBlock step) me)

        _ ->
            -- a NESTED loop (or any other statement): its continues belong to
            -- it, so the rewrite stops here
            stmt


{-| `do { B } while (c);` — a `Loop` whose condition is the constant 1, with
C's test placed where control LEAVES an iteration: at every `continue` and at
the body's fall-through.  `continue` in a do-while evaluates `c` FIRST (C's
rule), which is exactly "test; then the loop's own next iteration or exit".
No body duplication and no backend flag: the shape needs only `Loop`,
`Break` and `Continue`.

The test is spelled `if (c) { continue; }` followed by the block's term being
`break` — i.e. "if the condition holds, iterate; otherwise leave".
-}
doWhileBody : Ast.Exp -> Block -> Block
doWhileBody cond b =
    doWhileTail cond { b | stmts = List.map (doWhileStmt cond) b.stmts }


{-| The BODY's own end: the `TContinue` term, or a tail `if` whose reachable
paths need the same treatment (`diverges` tells which — a block whose term
cannot be fallen past needs nothing).
-}
doWhileTail : Ast.Exp -> Block -> Block
doWhileTail cond b =
    case b.term of
        TContinue ->
            { stmts = b.stmts ++ [ doWhileTest cond ], term = TBreak }

        TIf c t Nothing ->
            -- the then-branch diverges (J7), so as a mid-block if it is legal
            -- and its false path is the continuation: the test, then break.
            -- The branch is rewritten too — a `continue;` in it must still
            -- evaluate the condition (C's do-while rule).
            { stmts = b.stmts ++ [ SIf c (doWhileContinue cond t) Nothing, doWhileTest cond ]
            , term = TBreak
            }

        TIf c t (Just eb) ->
            { stmts = b.stmts
            , term = TIf c (doWhileTail cond t) (Just (doWhileTail cond eb))
            }

        _ ->
            b


{-| A block whose term is `TContinue` anywhere INSIDE the body (a continue in
a nested `if`): test, then leave-or-iterate.
-}
doWhileContinue : Ast.Exp -> Block -> Block
doWhileContinue cond b =
    if b.term == TContinue then
        { stmts = List.map (doWhileStmt cond) b.stmts ++ [ doWhileTest cond ], term = TBreak }

    else
        { stmts = List.map (doWhileStmt cond) b.stmts
        , term =
            case b.term of
                TIf c t me ->
                    TIf c (doWhileContinue cond t) (Maybe.map (doWhileContinue cond) me)

                other ->
                    other
        }


doWhileStmt : Ast.Exp -> Stmt -> Stmt
doWhileStmt cond stmt =
    case stmt of
        SIf c t me ->
            SIf c (doWhileContinue cond t) (Maybe.map (doWhileContinue cond) me)

        _ ->
            stmt


{-| The condition test as a mid-block statement: `if (c) { continue; }`.  The
`break` is the ENCLOSING block's term, so a false condition falls past this
statement into it.
-}
doWhileTest : Ast.Exp -> Stmt
doWhileTest cond =
    SIf cond { stmts = [], term = TContinue } Nothing


-- ============================ entry point ============================


{-| Lower a checked program to Mid defuns, preserving input order and keys
(guarded variants of one key lower as separate defuns — selecting the ONE
active variant per flag set is the wiring's job, T7).  The headerless
delegate: no file-scoped decls, so the field/index/deref arms have no
struct table to read (they can only fire on a structless program — the
runtime lane, which uses none of the A2 spellings yet).
-}
lowerProgram : Program -> Result String (List Defun)
lowerProgram program =
    lowerAll [] [] program


{-| Lower a whole MODULE — the decl-carrying entry the user lane and the
tree-equality pin use.  `decls` ride in the lowering state so the
field/index arms read the SAME struct table the A1 checker laid out from
(`Check.fieldOffset`/`Check.sizeofStruct` — the one-table property: no
second copy to skew).
-}
lowerModule : Module -> Result String (List Defun)
lowerModule module_ =
    lowerAll module_.decls [] module_.defuns


lowerAll : List Decl -> List Defun -> Program -> Result String (List Defun)
lowerAll decls acc program =
    case program of
        [] ->
            Ok (List.reverse acc)

        d :: rest ->
            case lowerDefun decls d of
                Err msg ->
                    Err msg

                Ok idef ->
                    lowerAll decls (idef :: acc) rest


{-| L3's defun shape, identical to the DSL's `lam` (RtPrims.elm:388-393):
params are binders with ids 1..n in order (the DSL's `p1..p5` convention),
the body is the block's lowered value.
-}
lowerDefun : List Decl -> Ast.Defun -> Result String Defun
lowerDefun decls d =
    let
        params =
            paramBinders 1 d.params

        st0 =
            { key = d.key
            , nextId = List.length d.params + 1
            , nextLbl = 1
            , scope = paramScope params
            , types = paramTypes d.params
            , decls = decls
            , ret = d.ret
            , cells = assignedNames d.body
            }
    in
    case lowerBlock st0 d.body of
        Err msg ->
            Err msg

        Ok ( _, body ) ->
            Ok { key = d.key, value = Lam { params = params, body = body } }



-- ============================ params ============================


paramBinders : Int -> List Param -> List Binder
paramBinders i params =
    case params of
        [] ->
            []

        p :: rest ->
            { id = i, name = p.name } :: paramBinders (i + 1) rest


paramScope : List Binder -> Dict String Int
paramScope params =
    List.foldl (\p acc -> Dict.insert p.name p.id acc) Dict.empty params


{-| The parameter binder's DECLARED class, name -> type — the lowerer's own
scope for resolving a pointer base's pointee family (`*word`/`*val`/`*S`),
mirroring the checker's `paramScope` (Check.elm).  The lowerer reads only
this (and the `SBind` insert below); it does not re-derive classes.
-}
paramTypes : List Param -> Dict String Ast.Type
paramTypes params =
    List.foldl (\p acc -> Dict.insert p.name p.ty acc) Dict.empty params



-- ============================ blocks: L1/L2/L6 ============================


lowerBlock : St -> Block -> Result String (St, Exp)
lowerBlock st b =
    lowerRest st b.stmts b.term


{-| Lower `stmts` followed by `term` as ONE expression: statements are
folded right-to-left, each statement receiving the CONTINUATION (the rest
of the block's lowered value) — which is what L6's else-nesting needs.
-}
lowerRest : St -> List Stmt -> Term -> Result String (St, Exp)
lowerRest st stmts term =
    case stmts of
        [] ->
            lowerTerm st term

        s :: rest ->
            lowerStmt st s (\st1 -> lowerRest st1 rest term)


{-| Lower one statement against its continuation.  L1/L2 bind at a fresh
binder and wrap the continuation in a 1-binder `Let`; L6 else-nests.
-}
lowerStmt : St -> Stmt -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerStmt st stmt cont =
    case stmt of
        SBind ty name e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    let
                        -- B1: a bool initializer at a `:val` slot goes through
                        -- the box (the checker's ONE implicit coercion).
                        v2 =
                            if ty == Ast.TVal && isBoolExp st e then
                                boolToVal v1

                            else
                                v1

                        ( binder, st2 ) =
                            fresh name st1

                        st3 =
                            { st2
                                | scope = Dict.insert name binder.id st2.scope
                                , types = Dict.insert name ty st2.types
                            }
                    in
                    case cont st3 of
                        Err msg ->
                            Err msg

                        Ok ( st4, body ) ->
                            if isCell st3 name then
                                -- B4: the binder is a CELL — the declaration
                                -- allocates ONE word of stack storage and
                                -- STORES the initialiser, so every later
                                -- assignment is a store and every read a load.
                                -- The alloc sits INSIDE the declaration's own
                                -- `Let`, i.e. before the first jump into a
                                -- loop body and never inside a back edge: the
                                -- init-once rule is structural.
                                case
                                    withStores "_cellinit"
                                        st4
                                        [ Unsafe
                                            (RawWordStore
                                                { ptr = Var binder.id
                                                , index = Lit (LNumber 0)
                                                , value = v2
                                                }
                                            )
                                        ]
                                        (\st5 -> Ok ( st5, body ))
                                of
                                    Err msg ->
                                        Err msg

                                    Ok ( st5, stored ) ->
                                        Ok
                                            ( st5
                                            , Let
                                                { binders =
                                                    [ LetBind { binder = binder, value = Unsafe (RawAllocN 1) } ]
                                                , body = stored
                                                }
                                            )

                            else
                                Ok ( st4, Let { binders = [ LetBind { binder = binder, value = v2 } ], body = body } )

        SEffect e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    let
                        ( binder, st2 ) =
                            fresh "_eff" st1
                    in
                    case cont st2 of
                        Err msg ->
                            Err msg

                        Ok ( st4, body ) ->
                            Ok ( st4, Let { binders = [ LetBind { binder = binder, value = v1 } ], body = body } )

        SIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    let
                        thenDiv =
                            diverges t

                        elseDiv =
                            divergesMaybe me
                    in
                    if thenDiv && not elseDiv then
                        -- L6 else-nesting: the then-branch is a dead end (it
                        -- always diverges), so the continuation IS the false
                        -- path.  Lowered in reading order: then, else.
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        case cont st2 of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                    else if elseDiv && not thenDiv then
                        -- Symmetric: the else-branch is a dead end and the
                        -- continuation splices into the THEN branch at its
                        -- fall-through point (which may be a DEEPER slot —
                        -- a nested one-sided if's false path).
                        case me of
                            Just eb ->
                                case lowerBlock st1 eb of
                                    Err msg ->
                                        Err msg

                                    Ok ( st2, e1 ) ->
                                        case lowerBranch st2 t cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, t1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                            Nothing ->
                                Err (internal st "SIf" "a diverging else cannot be missing")

                    else if thenDiv && elseDiv then
                        -- BOTH DIVERGE: THE `return` EXITS (the return-flip
                        -- unit, stage 2).  Both arms END the block — they
                        -- `return`/`recur`, or are themselves a both-diverging
                        -- `if` — so the `If` IS this block's value and the
                        -- statements after it are UNREACHABLE.  The
                        -- continuation is therefore NOT lowered: under the old
                        -- (pre-flip) arm this was a DEAD BIND, the `If` was
                        -- bound to a fresh binder nothing read, and the
                        -- continuation RAN whatever the condition — a
                        -- silent-wrong for every program that wrote
                        -- `if (c) { return a; } else { return b; }` and meant
                        -- the return.  69 such sites lived in runtime.mid and
                        -- were migrated to a conditional-VALUE declaration
                        -- BEFORE this arm changed (see runtime.mid's header);
                        -- the corpus is byte-identical under both arms, so the
                        -- flip is inert on this tree and LOUD for a program
                        -- that still writes the shape.
                        --
                        -- Not an error: dropping the unreachable tail is what
                        -- C (and every block language) does with code after a
                        -- both-returning if.  A checker-side reject of the
                        -- shape is a separate, cheekier question — J7 admits
                        -- it, and it stays admitted because the value spelling
                        -- above is its own idiom.
                        case me of
                            Just eb ->
                                case lowerBlock st1 t of
                                    Err msg ->
                                        Err msg

                                    Ok ( st2, t1 ) ->
                                        case lowerBlock st2 eb of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                            Nothing ->
                                Err (internal st "SIf" "both branches diverge but there is no else block")

                    else
                        Err
                            (internal st "SIf"
                                "a mid-block if with both branches falling through reached the lowerer — Check J7 must reject it first"
                            )

        SFieldStore p f e ->
            -- A2: `p->f = e;` — dead-binder Lets of the field's store node(s)
            -- (the EXACT `wstore(p, off, e);` / `vecstore(p, off, e);` tree,
            -- plan §3).  The value lowers FIRST (state threading), then the
            -- dead binder binds the effect and the continuation continues.
            -- B2: a struct-typed FIELD stores as a word-for-word copy, so
            -- the node count is the field's width (`fieldStoreNodes`).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldInfo st sname f of
                        Err msg ->
                            Err msg

                        Ok ( off, fld ) ->
                            case lowerExp st p of
                                Err msg ->
                                    Err msg

                                Ok ( st1, p1 ) ->
                                    case lowerExp st1 e of
                                        Err msg ->
                                            Err msg

                                        Ok ( st2, e1 ) ->
                                            let
                                                -- B1: the same bool→val box, at
                                                -- a `val` FIELD slot.
                                                e2 =
                                                    if fld.ty == Ast.TVal && isBoolExp st2 e then
                                                        boolToVal e1

                                                    else
                                                        e1
                                            in
                                            case fieldStoreNodes st sname f p1 e2 of
                                                Err msg ->
                                                    Err msg

                                                Ok stores ->
                                                    withStores "_fieldstore" st2 stores cont

                Ok pty ->
                    Err
                        (internal st "field store (`p->f = e;`)"
                            ("needs a struct pointer, got *"
                                ++ ptyStr pty
                                ++ " — Check J13 must reject it first"
                            )
                        )

        SStructBind rec ->
            -- B2: the struct-VALUE binder.  Storage FIRST (`structAlloc`), then
            -- the initialiser's stores, then the binder and the continuation —
            -- `Let s = <addr> in Let dead = <store> in ..`, so the address is a
            -- raw word binder exactly like any other.
            case structAlloc st rec.sname of
                Err msg ->
                    Err msg

                Ok alloc ->
                    let
                        ( binder, st1 ) =
                            fresh rec.name st

                        st2 =
                            { st1
                                | scope = Dict.insert rec.name binder.id st1.scope
                                , types = Dict.insert rec.name (Ast.TStruct rec.sname) st1.types
                            }
                    in
                    -- The stores address the BINDER (`Var id`), never the
                    -- `malloc` expression: re-lowering the alloc as the store
                    -- base would fill a SECOND, discarded block (MEASURED —
                    -- the first cut read back an all-zero copy).
                    case structInitNodes st2 rec.sname (Var binder.id) rec.init of
                        Err msg ->
                            Err msg

                        Ok ( st3, stores ) ->
                            case withStores "_structinit" st3 stores cont of
                                Err msg ->
                                    Err msg

                                Ok ( st4, body ) ->
                                    Ok
                                        ( st4
                                        , Let
                                            { binders = [ LetBind { binder = binder, value = alloc } ]
                                            , body = body
                                            }
                                        )

        SArrayBind rec ->
            -- B3: the array-VALUE binder.  Storage FIRST (`arrayAlloc`), then
            -- the initialiser's stores, then the binder and the continuation —
            -- `Let a = <addr> in Let dead = <store> in ..`, exactly SStructBind's
            -- shape (the address is a raw word binder; the STORES address the
            -- BINDER, never the `malloc` expression, or they would fill a
            -- second discarded block — the B2 bug its row now pins).
            case arrayAlloc st rec.aty of
                Err msg ->
                    Err msg

                Ok alloc ->
                    let
                        ( binder, st1 ) =
                            fresh rec.name st

                        st2 =
                            { st1
                                | scope = Dict.insert rec.name binder.id st1.scope
                                , types = Dict.insert rec.name rec.aty st1.types
                            }
                    in
                    case arrayInitNodes st2 rec.aty (Var binder.id) rec.init of
                        Err msg ->
                            Err msg

                        Ok ( st3, stores ) ->
                            case withStores "_arrayinit" st3 stores cont of
                                Err msg ->
                                    Err msg

                                Ok ( st4, body ) ->
                                    Ok
                                        ( st4
                                        , Let
                                            { binders = [ LetBind { binder = binder, value = alloc } ]
                                            , body = body
                                            }
                                        )

        SVarStore name e ->
            -- B2: `s = other;` — the aggregate COPY into storage that already
            -- exists.  The destination's address is its binder (a raw word).
            -- B4: a WORD-class destination is a CELL STORE (`x = e;` — the
            -- assignment that makes a loop-carried local work at all); the
            -- binder holds the cell's ADDRESS, so the store is
            -- `wstore(cell, 0, v)`.
            case ( Dict.get name st.scope, Dict.get name st.types ) of
                ( Just id, Just (Ast.TStruct sname) ) ->
                    case lowerExp st e of
                        Err msg ->
                            Err msg

                        Ok ( st1, e1 ) ->
                            case copyStores st sname 0 0 (Var id) e1 of
                                Err msg ->
                                    Err msg

                                Ok stores ->
                                    withStores "_structcopy" st1 stores cont

                ( Just id, Just ty ) ->
                    if scalarWordTy ty && isCell st name then
                        case lowerExp st e of
                            Err msg ->
                                Err msg

                            Ok ( st1, e1 ) ->
                                withStores "_cellstore"
                                    st1
                                    [ Unsafe
                                        (RawWordStore
                                            { ptr = Var id
                                            , index = Lit (LNumber 0)
                                            , value = e1
                                            }
                                        )
                                    ]
                                    cont

                    else
                        Err
                            (internal st ("assignment to '" ++ name ++ "'")
                                "needs a struct-VALUE binder or an auto-celled WORD binder — Check J1 must reject it first"
                            )

                _ ->
                    Err
                        (internal st ("assignment to '" ++ name ++ "'")
                            "is unbound at the lowerer — Check J5 must reject it first"
                        )

        SIndexStore p i e ->
            -- A2: `p[i] = e;` — the same dead-binder Let, index scaled by the
            -- pointee family (word stride: the index IS the word offset;
            -- `*S`: the index is a struct element, scaled by sizeof S).
            -- B3 adds the ARRAY base (`a[i] = e;`), scaled by element size.
            case maybeValueTy st p of
                Just (TArray elem _) ->
                    arrayIndexStoreStmt st p i e elem cont

                _ ->
                    indexStoreOnPointer st p i e cont

        -- ==================== B4: the loop STATEMENTS ====================
        -- Each lowers to a dead-binder `Let` of the `Loop` node, then the
        -- continuation: the loop produces no value (its node's value is nil),
        -- so it is an EFFECT with a binder, exactly the `SEffect` shape.
        SWhile c b ->
            lowerLoopStmt st c b cont

        SDoWhile b c ->
            -- the C-correct test placement (see `doWhileBody`); the surface
            -- cond is DUPLICATED into each test site by the rewrite, which is
            -- exactly C's execution count
            lowerLoopStmt st (Ast.EInt 1) (doWhileBody c b) cont

        SFor rec ->
            let
                loopStmt =
                    SWhile rec.cond (forBody rec.step rec.body)
            in
            case rec.init of
                Nothing ->
                    lowerStmt st loopStmt cont

                Just initStmt ->
                    -- the continuation is a PARTIAL APPLICATION, not a lambda:
                    -- elm 0.19 compiles `lowerStmt` into a tail-call LOOP that
                    -- reassigns its own `cont` parameter, and a lambda closing
                    -- over `cont` here would capture that reassigned variable
                    -- and recurse into itself forever (MEASURED: a
                    -- `for (k = 0; ..)` blew the JS stack; the `for (; ..)`
                    -- form, which takes no continuation, was fine)
                    lowerStmt st initStmt (forCont loopStmt cont)


{-| The `for` head's init continuation — a NAMED function for the reason
stated at the call site (a lambda here captures `lowerStmt`'s reassigned
`cont`).
-}
forCont : Stmt -> (St -> Result String (St, Exp)) -> St -> Result String (St, Exp)
forCont loopStmt cont st =
    lowerStmt st loopStmt cont


{-| `while (c) { B }` (and the desugared forms above): lower the condition,
then the body, then the continuation — and SCOPE the body's binders to the
body (a binder declared inside a loop is not visible after it; restoring the
pre-body scope keeps that true of the lowerer's own table even though Check
already refused such a read).
-}
lowerLoopStmt : St -> Ast.Exp -> Block -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerLoopStmt st c b cont =
    case lowerExp st c of
        Err msg ->
            Err msg

        Ok ( st1, c1 ) ->
            case lowerBlock st1 b of
                Err msg ->
                    Err msg

                Ok ( st2, b1 ) ->
                    case cont { st2 | scope = st1.scope, types = st1.types } of
                        Err msg ->
                            Err msg

                        Ok ( st3, body ) ->
                            let
                                ( dead, st4 ) =
                                    fresh "_loop" st3
                            in
                            Ok
                                ( st4
                                , Let
                                    { binders =
                                        [ LetBind
                                            { binder = dead
                                            , value = Loop { cond = c1, body = b1 }
                                            }
                                        ]
                                    , body = body
                                    }
                                )


{-| B3 — `a[i] = e;` on an ARRAY base: the store node, its dead binder, the
continuation (the body of the pointer arm below, over the array's element
class).
-}
arrayIndexStoreStmt : St -> Ast.Exp -> Ast.Exp -> Ast.Exp -> Ast.Type -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
arrayIndexStoreStmt st p i e elem cont =
    case lowerExp st p of
        Err msg ->
            Err msg

        Ok ( st1, p1 ) ->
            case lowerExp st1 i of
                Err msg ->
                    Err msg

                Ok ( st2, i1 ) ->
                    case lowerExp st2 e of
                        Err msg ->
                            Err msg

                        Ok ( st3, e1 ) ->
                            let
                                -- B1's box, at a `val` ELEMENT slot (the same
                                -- rule the `*val` element store applies).
                                e2 =
                                    if elem == Ast.TVal && isBoolExp st3 e then
                                        boolToVal e1

                                    else
                                        e1
                            in
                            case arrayElemStore st3 elem p1 i i1 e2 of
                                Err msg ->
                                    Err msg

                                Ok stores ->
                                    withStores "_indexstore" st3 stores cont


{-| The pointer-base `p[i] = e;` arm (A2), unchanged — kept as its own
function so the array arm above and this one share the statement shape.
-}
indexStoreOnPointer : St -> Ast.Exp -> Ast.Exp -> Ast.Exp -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
indexStoreOnPointer st p i e cont =
    case resolvePointee st p of
        Err msg ->
            Err msg

        Ok pty ->
            case lowerExp st p of
                Err msg ->
                    Err msg

                Ok ( st1, p1 ) ->
                    case lowerExp st1 i of
                        Err msg ->
                            Err msg

                        Ok ( st2, i1 ) ->
                            case lowerExp st2 e of
                                Err msg ->
                                    Err msg

                                Ok ( st3, e1 ) ->
                                    let
                                        -- B1: the bool→val box at a
                                        -- `*val` ELEMENT slot.
                                        e2 =
                                            if pty == PVal && isBoolExp st3 e then
                                                boolToVal e1

                                            else
                                                e1
                                    in
                                    case indexStore st pty p1 i i1 e2 of
                                        Err msg ->
                                            Err msg

                                        Ok storeNode ->
                                            let
                                                ( dead, st4 ) =
                                                    fresh "_indexstore" st3
                                            in
                                            case cont st4 of
                                                Err msg ->
                                                    Err msg

                                                Ok ( st5, body ) ->
                                                    Ok
                                                        ( st5
                                                        , Let
                                                            { binders =
                                                                [ LetBind
                                                                    { binder = dead
                                                                    , value = storeNode
                                                                    }
                                                                ]
                                                            , body = body
                                                            }
                                                        )


{-| L3/L4/L5: the terminator IS the block's value.
-}
lowerTerm : St -> Term -> Result String (St, Exp)
lowerTerm st term =
    case term of
        TRet e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, v1 ) ->
                    -- B1: the bool→val box at a `-> val` return — the site
                    -- that keeps `return true;` byte-identical to the old
                    -- `mkbool(1)` sugar.
                    if st.ret == Ast.TVal && isBoolExp st e then
                        Ok ( st1, boolToVal v1 )

                    else
                        Ok ( st1, v1 )

        TRecur args ->
            case lowerArgs st args of
                Err msg ->
                    Err msg

                Ok ( st1, es ) ->
                    Ok ( st1, App { fn = GRef { key = st.key, force = False }, args = es } )

        -- U1: the DSL's TAIL CALL.  The terminator's value IS the raw node —
        -- `lowerTail` (Qbe.Lower) turns it into `tcall` + a bare `ret`, so the
        -- block never reaches `@ret` and the node produces no value of its own.
        TTailCall tc ->
            lowerTailCall st tc

        -- B4: the loop leaves — a bare `Break`/`Continue` node.  The backend
        -- resolves which loop from its own enclosing-loop stack, so nesting
        -- needs no labels in the tree.
        TBreak ->
            Ok ( st, Break )

        TContinue ->
            Ok ( st, Continue )

        TIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerBlock st1 t of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case me of
                                Just eb ->
                                    case lowerBlock st2 eb of
                                        Err msg ->
                                            Err msg

                                        Ok ( st3, e1 ) ->
                                            let
                                                ( ie, stF ) =
                                                    mkIf st3 c1 t1 e1
                                            in
                                            Ok ( stF, ie )

                                Nothing ->
                                    if diverges t then
                                        -- L5: the false path has no value — the
                                        -- DSL's dead-value convention fills it
                                        -- with mknil (never returned: the true
                                        -- path diverged).
                                        let
                                            ( ie, stF ) =
                                                mkIf st2 c1 t1 mkNilExp
                                        in
                                        Ok ( stF, ie )

                                    else
                                        Err
                                            (internal st "TIf"
                                                "a terminating if without else whose then-branch falls through reached the lowerer — Check J7 must reject it first"
                                            )


mkIf : St -> Exp -> Exp -> Exp -> ( Exp, St )
mkIf st cond thenB elseB =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( If
        { cond = cond
        , thenBranch = thenB
        , elseBranch = elseB
        , falseLabel = falseLbl
        , endLabel = endLbl
        }
    , st1
    )


{-| Lower a BRANCH BLOCK of a MID-BLOCK if, splicing `cont` — the
continuation after the whole if — at the branch's fall-through point(s).
A diverging terminator (`return`/`recur`, or a both-diverging if) is a
dead end and the continuation is never spliced there; the shapes are:

  * `TRet`/`TRecur` — dead end, the branch's value is the returned exp.
  * a one-sided `TIf` — the continuation splices into the ONE falling
    slot: the false path of a missing else, or the falling arm of an
    else'd if whose other arm diverges.  This is what makes the
    checker's divelse shape (J7 accept row) lower correctly: the
    outer branch's fall-through is its INNER if's false path, and that
    slot receives the continuation — not `mkNil`.
  * `mkNil` fills a fall-through slot ONLY at the defun's top-level
    terminator (`lowerTerm`), where no continuation exists.
  * a TIf with BOTH arms falling splices the continuation into BOTH —
    the continuation DUPLICATION the plan's J7 floor forbids at the
    direct-arm level, still legal one level down (the checker's
    `diverges` is terminator-only, so it admits this shape; MEASURED 0
    DSL sites — the DSL always nests the continuation into the one
    falling arm by hand).  Duplication is id-safe: each copy is lowered
    sequentially, so its binders get distinct ids.

-}
lowerBranch : St -> Block -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranch st b cont =
    lowerBranchRest st b.stmts b.term cont


lowerBranchRest : St -> List Stmt -> Term -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranchRest st stmts term cont =
    case stmts of
        [] ->
            lowerBranchTerm st term cont

        s :: rest ->
            lowerStmt st s (\st1 -> lowerBranchRest st1 rest term cont)


lowerBranchTerm : St -> Term -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
lowerBranchTerm st term cont =
    case term of
        TRet e ->
            lowerExp st e

        TRecur args ->
            case lowerArgs st args of
                Err msg ->
                    Err msg

                Ok ( st1, es ) ->
                    Ok ( st1, App { fn = GRef { key = st.key, force = False }, args = es } )

        -- U1: UNREACHABLE for checked input — `Check.checkTailCall` admits a
        -- `tailcall` only in TAIL position, and a branch block here is a
        -- mid-block `if`'s arm, which the checker marks `tailPos = False`.
        -- Loud rather than silently lowered: a tail call spliced with a
        -- continuation would be asked for a value it does not have.
        TTailCall _ ->
            Err "lower: a `tailcall` reached a spliced branch block — it is a TERMINATOR and the checker (J16) admits it only in tail position.  This is a compiler bug, not a source error"

        TBreak ->
            Ok ( st, Break )

        TContinue ->
            Ok ( st, Continue )

        TIf c t me ->
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    let
                        thenDiv =
                            diverges t

                        elseDiv =
                            divergesMaybe me
                    in
                    if thenDiv && not elseDiv then
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        -- The missing else IS the fall-through
                                        -- slot: splice the continuation there.
                                        case cont st2 of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                    else if elseDiv && not thenDiv then
                        case lowerBlock st1 (maybeElse me) of
                            Err msg ->
                                Err msg

                            Ok ( st2, e1 ) ->
                                case lowerBranch st2 t cont of
                                    Err msg ->
                                        Err msg

                                    Ok ( st3, t1 ) ->
                                        let
                                            ( ie, stF ) =
                                                mkIf st3 c1 t1 e1
                                        in
                                        Ok ( stF, ie )

                    else if thenDiv && elseDiv then
                        -- Both arms diverge: the inner if is a dead end and
                        -- the continuation is unreachable from here.
                        case lowerBlock st1 t of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBlock st2 eb of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        Err (internal st "TIf" "both branches diverge but there is no else block")

                    else
                        -- Both arms fall: the continuation splices into BOTH
                        -- (the duplication documented above).
                        case lowerBranch st1 t cont of
                            Err msg ->
                                Err msg

                            Ok ( st2, t1 ) ->
                                case me of
                                    Just eb ->
                                        case lowerBranch st2 eb cont of
                                            Err msg ->
                                                Err msg

                                            Ok ( st3, e1 ) ->
                                                let
                                                    ( ie, stF ) =
                                                        mkIf st3 c1 t1 e1
                                                in
                                                Ok ( stF, ie )

                                    Nothing ->
                                        Err
                                            (internal st "TIf"
                                                "a terminating if without else whose then-branch falls through reached the lowerer — Check J7 must reject it first"
                                            )


maybeElse : Maybe Block -> Block
maybeElse me =
    case me of
        Just eb ->
            eb

        Nothing ->
            -- Unreachable for checked input (J7: a terminating if without
            -- else needs a diverging then-branch, so this arm is only entered
            -- when the else diverges — which requires an else to exist).
            { stmts = []
            , term = TRet (Ast.EBuiltin MkNil [])
            }


{-| The J7 divergence predicate, MIRRORED from Mid.RtLang.Check (whose copy
is not exposed): a block diverges iff control can never fall past its end,
decided by the TERMINATOR alone (`return`/`recur` always; a terminating
`if` only when BOTH branches diverge).  The lowerer reads the same
predicate the checker admitted the block with — L6's else-nesting picks
the branch that receives the continuation by it.  KEEP IN SYNC with
`Check.diverges`; if the two ever disagree, the loud internal errors above
fire instead of a silent mis-nest.
-}
diverges : Block -> Bool
diverges b =
    case b.term of
        TRet _ ->
            True

        TRecur _ ->
            True

        -- U1: a tail call never falls past its block — KEEP IN SYNC with
        -- Check.diverges, which admits the J7 shapes this predicate picks the
        -- else-nesting for.
        TTailCall _ ->
            True

        -- B4: a loop leaf ends the block (control leaves for the loop's exit
        -- or its next iteration), so `if (c) { break; }` is the legal
        -- mid-block shape it looks like.
        TBreak ->
            True

        TContinue ->
            True

        TIf _ t me ->
            case me of
                Just e ->
                    diverges t && diverges e

                Nothing ->
                    False


divergesMaybe : Maybe Block -> Bool
divergesMaybe me =
    case me of
        Just e ->
            diverges e

        Nothing ->
            False



-- ============================ expressions ============================


lowerExp : St -> Ast.Exp -> Result String (St, Exp)
lowerExp st e =
    case e of
        Ast.EInt i ->
            Ok ( st, Lit (LNumber i) )

        Ast.EFlt f ->
            Ok ( st, Lit (LFloat f) )

        Ast.EStr s ->
            Ok ( st, Lit (LString s) )

        Ast.EBool b ->
            -- B1: the bool literal is the 0/1 WORD (`Lit 1`/`Lit 0`) — the
            -- bool class's constant form.  At a `:val` position the bool→val
            -- box wraps it (`boolToVal`), and `RawMkValue tagBoolean [Lit k]`
            -- is EXACTLY the tree the `mkbool(k)` sugar this replaced emitted
            -- — that is the byte-identity the corpus gate checks.
            Ok ( st, Lit (LNumber (boolWord b)) )

        Ast.ESizeof target ->
            case sizeofWords st target of
                Err msg ->
                    Err (internal st "sizeof" msg)

                Ok n ->
                    Ok ( st, Lit (LNumber n) )

        Ast.ECast target inner ->
            lowerCast st target inner

        Ast.EVar name ->
            case Dict.get name st.scope of
                Just id ->
                    if Dict.member name st.cells then
                        -- B4 auto-cell: the binder holds an ADDRESS (a
                        -- `RawAllocN` block), so a read is a LOAD of word 0.
                        -- A word producer, so it is legal exactly where the
                        -- binder's old raw-temp spelling was.
                        Ok ( st, Unsafe (RawWordLoad { ptr = Var id, index = Lit (LNumber 0) }) )

                    else
                        Ok ( st, Var id )

                Nothing ->
                    Err
                        (internal st ("name '" ++ name ++ "'")
                            "is unbound at the lowerer — Check J5 must reject it first"
                        )

        Ast.EWordBin op a b ->
            lower2 st a b (binLower (wordBinOp op))

        Ast.EWordCmp op a b ->
            lower2 st a b (cmpLower (wordCmpOp op))

        Ast.EFltBin op a b ->
            lower2 st a b (fltBinLower (fltBinOp op))

        Ast.EFltCmp op a b ->
            lower2 st a b (fltCmpLower (fltCmpOp op))

        Ast.EShortAnd a b ->
            -- B1: `&&`/`||` are val,val -> val (Ast.shortSig), so a bool
            -- operand is BOXED here — the inferred chain is
            -- `mkbool(x) || false`, whose `false` arm is the old mkbool(0) tree.
            lower2 st a b (\x y s1 -> shortLower (boxIfValBool st Ast.TVal a x) (boxIfValBool st Ast.TVal b y) s1)

        Ast.EShortOr a b ->
            lower2 st a b (\x y s1 -> shortOrLower (boxIfValBool st Ast.TVal a x) (boxIfValBool st Ast.TVal b y) s1)

        Ast.EIf c thn els ->
            -- the ?: VALUE JOIN (T9b), 1:1: the same `mkIf` the statement
            -- layer uses, so the form lowers to `If { .. }` with its
            -- falseLabel/endLabel — in an `SBind` value position that is
            -- exactly the plan L6 `Let { x = If { .. } }` shape, whose
            -- join label the backend handles natively.  No new lowering
            -- machinery: the L5/L6 statement rules are untouched.
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerExp st1 thn of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case lowerExp st2 els of
                                Err msg ->
                                    Err msg

                                Ok ( st3, e1 ) ->
                                    let
                                        -- B1: the join's ONE implicit
                                        -- coercion — a bool arm beside a
                                        -- `:val` arm is BOXED (the checker's
                                        -- `joinClass`; a bool-vs-bool join is
                                        -- its reject, so exactly one side can
                                        -- need this).
                                        t2 =
                                            if isBoolExp st thn && not (isBoolExp st els) then
                                                boolToVal t1

                                            else
                                                t1

                                        e2 =
                                            if isBoolExp st els && not (isBoolExp st thn) then
                                                boolToVal e1

                                            else
                                                e1

                                        ( ie, stF ) =
                                            mkIf st3 c1 t2 e2
                                    in
                                    Ok ( stF, ie )

        Ast.EIfBlock c thn els ->
            -- T23: the BLOCK-BRANCH if EXPRESSION — the TERM `if`'s own
            -- lowering (`mkIf` over the two blocks lowered by the EXISTING
            -- `lowerBlock`), in an expression slot.  Position-free by
            -- construction: Mid's `If` carries only its invented
            -- falseLabel/endLabel and the backend invents its own labels
            -- and never reads the tree's (plan fact F1) — there is no
            -- isTail flag in this pipeline to vary — so the SAME node
            -- serves the tail position (the defun's value) and the VALUE
            -- position (an `SBind` initializer: L1 wraps it into
            -- `Let { x = If { .. } }`, the join the backend handles
            -- natively).  Each branch lowers as a BLOCK (its statements
            -- fold into the 1-binder Let chain of L1/L2, its terminator is
            -- the branch's value — a `return`/`recur` branch value is
            -- exactly the TIf branch's), else-nesting and both-diverge
            -- mid-block ifs inside a branch work unchanged, and the else
            -- branch is parsed-required so no dead-value fill is needed.
            case lowerExp st c of
                Err msg ->
                    Err msg

                Ok ( st1, c1 ) ->
                    case lowerBlock st1 thn of
                        Err msg ->
                            Err msg

                        Ok ( st2, t1 ) ->
                            case lowerBlock st2 els of
                                Err msg ->
                                    Err msg

                                Ok ( st3, e1 ) ->
                                    let
                                        ( ie, stF ) =
                                            mkIf st3 c1 t1 e1
                                    in
                                    Ok ( stF, ie )

        Ast.ECall key args ->
            lowerCall st args (\es s -> ( Unsafe (RawCall { sym = key, args = es }), s ))

        Ast.ERawCall sym args ->
            -- (cffi U2) THE TYPED CALL BOUNDARY's one decision: does the FILE
            -- declare this symbol `extern`?
            --
            --   DECLARED   -> `RawCallExtern` carrying the declaration's
            --                 widths (the node the QBE arm turns into `=w
            --                 call` + `extsw` for an `i32` result).  Read
            --                 through `Check.externSig` — the SAME lookup
            --                 the checker's J3 uses, so a width cannot mean
            --                 two things (plan §10.1's one-table property).
            --   UNDECLARED -> the unchanged `RawCallRaw`: the runtime's
            --                 internal `rt_*` seats and the not-yet-migrated
            --                 libc surface keep their all-word shape
            --                 byte-for-byte (plan §6).
            case Check.externSig st.decls sym of
                Nothing ->
                    lowerCall st args (\es s -> ( Unsafe (RawCallRaw { sym = sym, args = es }), s ))

                Just sig ->
                    case declaredArgWidths sym sig (List.length args) of
                        Err msg ->
                            Err (st.key ++ ": " ++ msg)

                        Ok widths ->
                            case ffiWidthOf sym sig.result of
                                Err msg ->
                                    Err (st.key ++ ": " ++ msg)

                                Ok resWidth ->
                                    lowerCall st args
                                        (\es s ->
                                            ( Unsafe
                                                (RawCallExtern
                                                    { sym = sym
                                                    , args = es
                                                    , argWidths = widths
                                                    , varargs = sig.varargs
                                                    , fixedArgs = List.length sig.params
                                                    , result = resWidth
                                                    }
                                                )
                                            , s
                                            )
                                        )

        Ast.EAggCall shape fnExp args ->
            case lowerExp st fnExp of
                Err msg ->
                    Err msg

                Ok ( st1, f1 ) ->
                    case lowerArgs st1 args of
                        Err msg ->
                            Err msg

                        Ok ( st2, es ) ->
                            Ok ( st2, Unsafe (RawCallAgg { fn = f1, args = es, shape = aggShape shape }) )

        Ast.EBuiltin b args ->
            lowerBuiltin st b args

        Ast.EWithRoots ids block ->
            case resolveRoots st ids of
                Err msg ->
                    Err msg

                Ok ( st1, binders ) ->
                    case lowerBlock st1 block of
                        Err msg ->
                            Err msg

                        Ok ( st2, body ) ->
                            Ok ( st2, Unsafe (WithRoots { binders = binders, body = body }) )

        Ast.EField p f ->
            -- A2: `p->f` IS the `wload(p, off)` spelling (plan §3 — the
            -- one-node property the whole arc is cheap on).  A word/pointer
            -- field -> `RawWordLoad { ptr = p, index = Lit off }`; a `val`
            -- field -> `RawVecLoad { vec = p, index = Lit off }` (the 5-word
            -- `vecload` contract — the field offset is a word offset, so the
            -- backend's `elemAddr` lands on `p + 40*off`, exactly the inline
            -- val slot).
            case resolvePointee st p of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldInfo st sname f of
                        Err msg ->
                            Err msg

                        Ok ( off, fld ) ->
                            case lowerExp st p of
                                Err msg ->
                                    Err msg

                                Ok ( st1, p1 ) ->
                                    Ok ( st1, fieldLoad fld p1 off )

                Ok pty ->
                    Err
                        (internal st "field access (`p->f`)"
                            ("needs a struct pointer, got *"
                                ++ ptyStr pty
                                ++ " — Check J13 must reject it first"
                            )
                        )

        Ast.EIndex p i ->
            -- A2: `p[i]` — the index scaled by the pointee family.  `*word`:
            -- the index IS the word offset (`wload`'s contract).  `*val`:
            -- `vecload`.  `*S`: the index is a STRUCT ELEMENT, so the word
            -- offset is `i * sizeof S` (folded to `Lit (k*sizeofS)` for a
            -- literal index).
            --
            -- B3: when the base's declared VALUE type is an ARRAY, the same
            -- node shapes are chosen by the ELEMENT type instead (stride =
            -- the element's word width) — `arrayElemLoad`.  The dispatch is on
            -- `maybeValueTy`, so every pre-B3 base falls through unchanged.
            case maybeValueTy st p of
                Just (TArray elem _) ->
                    case lowerExp st p of
                        Err msg ->
                            Err msg

                        Ok ( st1, p1 ) ->
                            case lowerExp st1 i of
                                Err msg ->
                                    Err msg

                                Ok ( st2, i1 ) ->
                                    case arrayElemLoad st elem p1 i i1 of
                                        Err msg ->
                                            Err msg

                                        Ok loadNode ->
                                            Ok ( st2, loadNode )

                _ ->
                    indexLoadOnPointer st p i


        Ast.EDeref p ->
            -- A2: `*p` is `*word` only (J13) -> `RawWordLoad { ptr = p,
            -- index = Lit 0 }` — `wload(p, 0)`.
            case lowerExp st p of
                Err msg ->
                    Err msg

                Ok ( st1, p1 ) ->
                    Ok ( st1, Unsafe (RawWordLoad { ptr = p1, index = Lit (LNumber 0) }) )

        Ast.EAddrOf inner ->
            -- B2: `&place`.  A FIELD is its base's address plus the field's
            -- constant word offset (`addrPlus` — the same arithmetic the
            -- field read uses, with the load dropped); a struct VALUE is
            -- already its own address, so `&s` is the IDENTITY and emits
            -- nothing.  Check has already refused everything without
            -- storage, so the fallthrough is exact.
            case inner of
                Ast.EField base f ->
                    case resolvePointee st base of
                        Err msg ->
                            Err msg

                        Ok (PStruct sname) ->
                            case fieldInfo st sname f of
                                Err msg ->
                                    Err msg

                                Ok ( off, _ ) ->
                                    case lowerExp st base of
                                        Err msg ->
                                            Err msg

                                        Ok ( st1, b1 ) ->
                                            Ok ( st1, addrPlus b1 off )

                        Ok pty ->
                            Err
                                (internal st "address-of (`&p->f`)"
                                    ("needs a struct pointer, got *"
                                        ++ ptyStr pty
                                        ++ " — Check J13 must reject it first"
                                    )
                                )

                _ ->
                    lowerExp st inner



{-| The pointer-base `p[i]` read (A2), unchanged — the arm body B3 could not
destroy.
-}
indexLoadOnPointer : St -> Ast.Exp -> Ast.Exp -> Result String (St, Exp)
indexLoadOnPointer st p i =
    case resolvePointee st p of
        Err msg ->
            Err msg

        Ok pty ->
            case lowerExp st p of
                Err msg ->
                    Err msg

                Ok ( st1, p1 ) ->
                    case lowerExp st1 i of
                        Err msg ->
                            Err msg

                        Ok ( st2, i1 ) ->
                            case indexLoad st pty p1 i i1 of
                                Err msg ->
                                    Err msg

                                Ok loadNode ->
                                    Ok ( st2, loadNode )


-- ============================ B1: bool, casts, sizeof ============================


{-| `true`/`false` as the 0/1 word.
-}
boolWord : Bool -> Int
boolWord b =
    if b then
        1

    else
        0


{-| The bool→val BOX (plan Q2's ONE implicit coercion): the operand is a raw
0/1 word, the result is a boolean Value — the node `mkbool(..)` builds, which
is the tree the `true`/`false` sugar used to emit (`RawMkValue tagBoolean
[Lit 1|0]`).  The checker admits the operand at exactly the `:val` SLOTS this
module can see syntactically (a `:val` binder, a `:val` field/element store, a
`-> val` return, and a `?:` arm beside a val), so every site calls this with a
word it has already lowered.
-}
boolToVal : Exp -> Exp
boolToVal word =
    Unsafe (RawMkValue { tag = RtLayout.valLayout.tagBoolean, words = [ word ] })


{-| Does this expression have class `bool`?  The LOWERING's mirror of
`Check`'s TBool class, and it is TOTAL because the checker admits no other
bool shape (`Check.isBoolTemp` is the binder rule; a bool join, a bool
param/return and a bool field cannot parse or check).  Used for the two
decisions the checker cannot make for it: where the bool→val box goes, and
which cast rows are the identity.
-}
isBoolExp : St -> Ast.Exp -> Bool
isBoolExp st e =
    case e of
        Ast.EBool _ ->
            True

        Ast.EWordCmp _ _ _ ->
            True

        Ast.EFltCmp _ _ _ ->
            True

        Ast.ECast target _ ->
            target == Ast.TBool

        Ast.EVar name ->
            Dict.get name st.types == Just Ast.TBool

        _ ->
            False


{-| Is this expression a FLOAT word (`d`)?  Only the cast rows need it: the
`[word]`/`[int]` cast is the identity for a word operand and `ftoi32` for a
float one.  Float words are never let-bound (`Check` J1), so the binding
shapes are the four expression forms plus a float PARAMETER (a stage-6 rawAbi
seat; a user defun's float param is B6's).  A shape this misses is a shape
whose cast would be an identity on a `d` temp — a loud QBE-layer type error,
never a silent wrong value.
-}
isFloatExp : St -> Ast.Exp -> Bool
isFloatExp st e =
    case e of
        Ast.EFlt _ ->
            True

        Ast.EFltBin _ _ _ ->
            True

        Ast.EBuiltin Ast.IToF _ ->
            True

        Ast.EBuiltin Ast.FLoad _ ->
            True

        Ast.EVar name ->
            Dict.get name st.types == Just Ast.TFloat

        _ ->
            False


{-| Box every bool operand whose expected class is `:val` — the general form
of the ONE implicit coercion, used wherever the expected classes are STATIC in
the tree: a builtin's operand slots (`Ast.builtinClass`) and the `&&`/`||`
operands (`Ast.shortSig` is val,val).  The other coercion sites are the ones
whose `:val` slot is explicit in the node being built (a binder, a field/
element store, a return, a `?:` arm) and box inline.
-}
boxArgs : St -> List Ast.Type -> List Ast.Exp -> List Exp -> List Exp
boxArgs st tys args es =
    case ( tys, args, es ) of
        ( t :: ts, a :: as_, e :: es_ ) ->
            boxIfValBool st t a e :: boxArgs st ts as_ es_

        _ ->
            es


{-| ONE operand: box it iff the expected class is `:val` and the surface
expression is a bool.  The single decision `boxArgs` folds over, so the
`&&`/`||` arms (whose expected class is `Ast.shortSig`'s val,val) and the
builtin slot walk cannot disagree.
-}
boxIfValBool : St -> Ast.Type -> Ast.Exp -> Exp -> Exp
boxIfValBool st expected a e =
    if expected == Ast.TVal && isBoolExp st a then
        boolToVal e

    else
        e


{-| The builtin form of `boxArgs`: a fixed-arity `Sig`'s operand classes;
`SigMkVal`'s payload words take a bool AS a word (rawWordArg computes the
0/1 temp), so nothing is boxed there.
-}
boxBuiltinArgs : St -> Ast.Builtin -> List Ast.Exp -> List Exp -> List Exp
boxBuiltinArgs st b args es =
    case Ast.builtinClass b of
        Ast.Sig tys _ ->
            boxArgs st tys args es

        Ast.SigMkVal ->
            es


{-| `[T](e)` — one arm per row of the checker's matrix (`Check.castClass` is
the judge; this is the emission).  The identity rows emit NO node at all:

  * `[word]`/`[int]` of word|pointer|bool — identity; of a FLOAT — `ftoi32`.
  * `[bool]` of word — a nonzero compare (`RawCmp WCne e 0`); of bool —
    identity.
  * `[*T]` of word — identity (the J12 view-cast, made explicit).
  * `[float]` of word — `RawIToF` (itof).
  * `[val]` of bool — the box.

Anything else is the checker's reject, so a fall-through here is an internal
error and says so.
-}
lowerCast : St -> Ast.Type -> Ast.Exp -> Result String (St, Exp)
lowerCast st target inner =
    case lowerExp st inner of
        Err msg ->
            Err msg

        Ok ( st1, e1 ) ->
            if target == Ast.TVal then
                Ok ( st1, boolToVal e1 )

            else if target == Ast.TFloat then
                if isFloatExp st inner then
                    Err (internal st "cast to float" "the operand is already a float word — Check J10 must reject it first")

                else
                    Ok ( st1, Unsafe (RawIToF e1) )

            else if target == Ast.TBool then
                if isBoolExp st inner then
                    Ok ( st1, e1 )

                else
                    Ok ( st1, Unsafe (RawCmp { op = RCne, a = e1, b = Lit (LNumber 0) }) )

            else if target == Ast.TWord then
                if isFloatExp st inner then
                    Ok ( st1, Unsafe (RawUn { op = RFToI32, v = e1 }) )

                else
                    Ok ( st1, e1 )

            else
                -- a pointer target: the `[*T](w)` identity (J12's view-cast)
                Ok ( st1, e1 )


{-| `sizeof`'s word count, from the ONE layout table (`Check.sizeofStruct`,
the same numbers the checker validated) or the class width — `word`/`int`/
pointer = 1, `val` = 5 inline words, `bool` = 1.  `float` is the checker's
reject (no raw f64 seat), so it is an internal error here.
-}
sizeofWords : St -> Ast.SizeTarget -> Result String Int
sizeofWords st target =
    case target of
        Ast.SizeStruct name ->
            case Check.sizeofStruct st.decls name of
                Just n ->
                    Ok n

                Nothing ->
                    Err ("no struct '" ++ name ++ "' in the layout table — Check J11 must reject it first")

        Ast.SizeType ty ->
            case ty of
                Ast.TStruct sname ->
                    case Check.sizeofStruct st.decls sname of
                        Just n ->
                            Ok n

                        Nothing ->
                            Err ("no struct '" ++ sname ++ "' in the layout table — Check J11 must reject it first")

                Ast.TWord ->
                    Ok 1

                Ast.TBool ->
                    Ok 1

                Ast.TPtr _ ->
                    Ok 1

                Ast.TArray elem n ->
                    -- B3: the element's width times the count (row-major flat,
                    -- so a nested array is its element's width again).  This is
                    -- what sizes an array binder's malloc and the element
                    -- strides below.
                    case sizeofWords st (Ast.SizeType elem) of
                        Err msg ->
                            Err msg

                        Ok w ->
                            Ok (w * n)

                Ast.TVal ->
                    Ok 5

                Ast.TFloat ->
                    Err "a float has no raw-memory word width (Check J1 must reject it first)"


{-| The four operator families lower constructor-by-constructor onto the
matching raw-node enums (annotated top-level so the partial applications
passed to `lower2` carry the surface/IR distinction in their types).
-}
binLower : RawBinOp -> Exp -> Exp -> St -> ( Exp, St )
binLower op x y st =
    ( Unsafe (RawBin { op = op, a = x, b = y }), st )


cmpLower : RawCmpOp -> Exp -> Exp -> St -> ( Exp, St )
cmpLower op x y st =
    ( Unsafe (RawCmp { op = op, a = x, b = y }), st )


fltBinLower : RawFltBinOp -> Exp -> Exp -> St -> ( Exp, St )
fltBinLower op x y st =
    ( Unsafe (RawFltBin { op = op, a = x, b = y }), st )


fltCmpLower : RawFltCmpOp -> Exp -> Exp -> St -> ( Exp, St )
fltCmpLower op x y st =
    ( Unsafe (RawFltCmp { op = op, a = x, b = y }), st )


shortLower : Exp -> Exp -> St -> ( Exp, St )
shortLower left right st =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( ShortAnd { left = left, right = right, falseLabel = falseLbl, endLabel = endLbl }
    , st1
    )


shortOrLower : Exp -> Exp -> St -> ( Exp, St )
shortOrLower left right st =
    let
        ( falseLbl, endLbl, st1 ) =
            freshLabels st
    in
    ( ShortOr { left = left, right = right, falseLabel = falseLbl, endLabel = endLbl }
    , st1
    )


lower2 : St -> Ast.Exp -> Ast.Exp -> (Exp -> Exp -> St -> ( Exp, St )) -> Result String (St, Exp)
lower2 st a b k =
    case lowerExp st a of
        Err msg ->
            Err msg

        Ok ( st1, a1 ) ->
            case lowerExp st1 b of
                Err msg ->
                    Err msg

                Ok ( st2, b1 ) ->
                    let
                        ( ie, stF ) =
                            k a1 b1 st2
                    in
                    Ok ( stF, ie )


{-| (cffi U2) the DECLARED width -> the IR's call-boundary class.  `i64`,
`u64` and `ptr` collapse to `FW64` (one `l` class both ways) while `i32` and
`u32` stay apart, because the `extsw`/`extuw` after a `w` result differ — the
collapse is the IR's, the distinction is the DECLARATION's, and this is the
single place the two vocabularies meet.

(cffi U6) The four SUB-WORD widths have NO call-boundary class and this is
where that is stated once: they are MEMORY widths (a field's byte count and
sign rule), the `extern` parser refuses them, so a signature carrying one
here means a hand-built declaration — a loud internal error naming the symbol,
never a silent widening into `FW64`.  Returning a `Result` rather than a
defaulted classifier is deliberate: the caller cannot forget to look.
-}
ffiWidthOf : String -> Ast.FfiTy -> Result String FfiWidth
ffiWidthOf sym t =
    case t of
        Ast.FI32 ->
            Ok FW32S

        Ast.FU32 ->
            Ok FW32U

        Ast.FI64 ->
            Ok FW64

        Ast.FU64 ->
            Ok FW64

        Ast.FPtr ->
            Ok FW64

        Ast.FF64 ->
            Ok FF64

        Ast.FVoid ->
            Ok FVoid

        Ast.FI8 ->
            subWordWidth sym "i8"

        Ast.FU8 ->
            subWordWidth sym "u8"

        Ast.FI16 ->
            subWordWidth sym "i16"

        Ast.FU16 ->
            subWordWidth sym "u16"


subWordWidth : String -> String -> Result String FfiWidth
subWordWidth sym w =
    Err
        ("cffi U6: `"
            ++ w
            ++ "` reached the CALL BOUNDARY of '"
            ++ sym
            ++ "' — a sub-word width is a struct FIELD width (a byte count and a sign rule), not a register class; C carries such a value in a 32-bit register, and this language spells that `i32`/`u32`"
        )


{-| The positional widths of one DECLARED call's arguments.

The FIXED positions take the declaration's widths; every argument past them is
a VARIADIC one and is `FW64` (an `l` word) — plan §5: v1 admits only word-class
variadic arguments, and `FW64` is the one word class the emitter can spell
without a per-argument type.  The CHECKER (J3, `Check.checkExternCall`) has
already pinned the count against the same declaration, so a mismatch here is a
loud internal error rather than a silent all-word fallback — the shape the
whole unit exists to make unrepresentable.
-}
declaredArgWidths : String -> Ast.FfiSig -> Int -> Result String (List FfiWidth)
declaredArgWidths sym sig got =
    case List.foldr (\p acc -> Result.map2 (::) (ffiWidthOf sym p.ty) acc) (Ok []) sig.params of
        Err msg ->
            Err msg

        Ok fixed ->
            declaredArgWidthsHelp sym sig got fixed


declaredArgWidthsHelp : String -> Ast.FfiSig -> Int -> List FfiWidth -> Result String (List FfiWidth)
declaredArgWidthsHelp sym sig got fixed =
    if sig.varargs then
        if List.length fixed <= got then
            Ok (fixed ++ List.repeat (got - List.length fixed) FW64)

        else
            internalArgWidths sym (List.length fixed) got

    else if List.length fixed == got then
        Ok fixed

    else
        internalArgWidths sym (List.length fixed) got


internalArgWidths : String -> Int -> Int -> Result String (List FfiWidth)
internalArgWidths sym declared got =
    Err
        ("internal: J3 should have rejected rawcall '"
            ++ sym
            ++ "' — the declaration has "
            ++ String.fromInt declared
            ++ " parameter(s) and the call site has "
            ++ String.fromInt got
        )


lowerCall : St -> List Ast.Exp -> (List Exp -> St -> ( Exp, St )) -> Result String (St, Exp)
lowerCall st args k =
    case lowerArgs st args of
        Err msg ->
            Err msg

        Ok ( st1, es ) ->
            let
                ( ie, stF ) =
                    k es st1
            in
            Ok ( stF, ie )


{-| Arguments in source order, state threaded left to right.
-}
lowerArgs : St -> List Ast.Exp -> Result String (St, List Exp)
lowerArgs st args =
    case args of
        [] ->
            Ok ( st, [] )

        a :: rest ->
            case lowerExp st a of
                Err msg ->
                    Err msg

                Ok ( st1, a1 ) ->
                    case lowerArgs st1 rest of
                        Err msg ->
                            Err msg

                        Ok ( st2, es ) ->
                            Ok ( st2, a1 :: es )


resolveRoots : St -> List String -> Result String (St, List Binder)
resolveRoots st ids =
    case ids of
        [] ->
            Ok ( st, [] )

        id :: rest ->
            case Dict.get id st.scope of
                Just binderId ->
                    case resolveRoots st rest of
                        Err msg ->
                            Err msg

                        Ok ( st1, tail ) ->
                            Ok ( st1, { id = binderId, name = id } :: tail )

                Nothing ->
                    Err
                        (internal st ("withroots id '" ++ id ++ "'")
                            "is unbound at the lowerer — Check J10 must reject it first"
                        )


{-| U1 — the `tailcall` terminator's lowering: the block's VALUE is the raw
tail-call node.  The target is carried as a KEY (not a symbol) because the
key space and `mangle` live in `Qbe.Lower`, beside every other `q_` name; the
arguments go through the ordinary expression lowering, and their WORD-class
ness is the checker's J16 judgment rather than this pass's (this pass would
happily lower a `val` argument — which is exactly why the checker must not).
-}
lowerTailCall : St -> { target : TailTarget, shape : AggShape, args : List Ast.Exp } -> Result String ( St, Exp )
lowerTailCall st tc =
    case lowerArgs st tc.args of
        Err msg ->
            Err msg

        Ok ( st1, es ) ->
            Ok
                ( st1
                , Unsafe
                    (RawTailCall
                        { target = irTailTarget tc.target
                        , args = es
                        , shape = aggShape tc.shape
                        }
                    )
                )


{-| The surface target -> the IR target.  A NAMED function with an explicit
signature, not an inline `case`: the two `TailTarget` types live in different
modules and the selfhost lane's own type checker will not unify them from a
record literal alone (MEASURED: it reads the record's expected type from
`lowerTailCall`'s annotation and then rejects the IR constructor inside it —
`cannot unify Mid.Ir.TailTarget with Mid.RtLang.Ast.TailTarget`).  Naming the
conversion makes the two types explicit at the one place they meet, which is
also where a reader wants to see that they are the same two shapes.
-}
irTailTarget : TailTarget -> Mid.Ir.TailTarget
irTailTarget target =
    case target of
        TailDefun key ->
            Mid.Ir.TailKey key

        TailExtern sym ->
            Mid.Ir.TailSym sym


aggShape : AggShape -> String
aggShape shape =
    case shape of
        AggRet ->
            "ret"

        AggVal ->
            "val"



-- ============================ builtins ============================


{-| Lower a builtin: all arguments first (state threaded), then the node is
built by the `Ast.builtinClass` table's row — arity and classes were
checked (J1), so a mismatched shape here is an internal error.
-}
lowerBuiltin : St -> Builtin -> List Ast.Exp -> Result String (St, Exp)
lowerBuiltin st b args =
    case lowerArgs st args of
        Err msg ->
            Err msg

        Ok ( st1, es ) ->
            let
                -- B1: a bool operand at a `:val` slot is BOXED (the implicit
                -- coercion; `Ast.builtinClass` is the class table, so the
                -- slot's class is static — no guessing).
                es2 =
                    boxBuiltinArgs st b args es
            in
            case buildBuiltin b es2 of
                Err msg ->
                    Err (internal st ("builtin '" ++ builtinName b ++ "'") msg)

                Ok ie ->
                    Ok ( st1, ie )


buildBuiltin : Builtin -> List Exp -> Result String Exp
buildBuiltin b es =
    case b of
        MkNum ->
            buildMk RtLayout.valLayout.tagNumber es

        MkBool ->
            buildMk RtLayout.valLayout.tagBoolean es

        MkNil ->
            case es of
                [] ->
                    Ok (Unsafe (RawMkValue { tag = RtLayout.valLayout.tagNil, words = [] }))

                _ ->
                    Err arityBug

        MkStr ->
            buildMk2 RtLayout.valLayout.tagString es

        MkFlt ->
            buildMk RtLayout.valLayout.tagFloat es

        MkVec ->
            buildMk2 RtLayout.valLayout.tagVector es

        MkVal ->
            -- The generic value constructor: `mkval(tag, words..)`.  The tag
            -- is a CONSTANT inside RawMkValue, so the AST tag argument must
            -- be an int literal (the parser's literal-slot rule; a computed
            -- tag is unrepresentable and a loud error here, not a guess).
            case es of
                (Lit (LNumber tag)) :: rest ->
                    Ok (Unsafe (RawMkValue { tag = tag, words = rest }))

                _ ->
                    Err "needs an int-literal tag (RawMkValue's tag is a constant in Mid.Ir)"

        Payload ->
            case es of
                [ v, Lit (LNumber i) ] ->
                    Ok (Unsafe (RawPayload { value = v, word = i }))

                _ ->
                    Err "needs (value, int-literal index) — RawPayload's word is a constant"

        Payload32 ->
            case es of
                [ v, Lit (LNumber i) ] ->
                    Ok (Unsafe (RawPayload32 { value = v, word = i }))

                _ ->
                    Err "needs (value, int-literal index) — RawPayload32's word is a constant"

        Len32 ->
            -- The i32 len field = payload32(v, 1).
            case es of
                [ v ] ->
                    Ok (Unsafe (RawPayload32 { value = v, word = 1 }))

                _ ->
                    Err arityBug

        TagIs ->
            case es of
                [ v, Lit (LNumber t) ] ->
                    Ok (Unsafe (RawTagIs { value = v, tag = t }))

                _ ->
                    Err "needs (value, int-literal tag) — RawTagIs's tag is a constant"

        VecLoad ->
            build2 (\vec idx -> Unsafe (RawVecLoad { vec = vec, index = idx })) es

        VecAddr ->
            build2 (\vec idx -> Unsafe (RawVecAddr { vec = vec, index = idx })) es

        VecBody ->
            -- The element BASE of a Value (perf word-arm-area3rt).  It stays a
            -- NODE rather than being expanded here into `payload(v, 0)`: the
            -- val arm's payload word 0 and the word arm's "untag, step past the
            -- header" are different arithmetic, and only Lower knows the arm
            -- (this pass runs before it, under both).
            build1 (\v -> Unsafe (RawVecBody { value = v })) es

        VecStore ->
            build3 (\vec idx v -> Unsafe (RawVecStore { vec = vec, index = idx, value = v })) es

        StrByte ->
            build2 (\str idx -> Unsafe (RawStrByte { str = str, index = idx })) es

        ByteLoad ->
            build2 (\ptr idx -> Unsafe (RawByteLoad { ptr = ptr, index = idx })) es

        ByteStore ->
            build3 (\ptr idx v -> Unsafe (RawByteStore { ptr = ptr, index = idx, value = v })) es

        WordLoad ->
            build2 (\ptr idx -> Unsafe (RawWordLoad { ptr = ptr, index = idx })) es

        WordStore ->
            build3 (\ptr idx v -> Unsafe (RawWordStore { ptr = ptr, index = idx, value = v })) es

        AllocVec ->
            build1 (\w -> Unsafe (RawAllocVector w)) es

        AllocRaw ->
            build1 (\w -> Unsafe (RawAllocRaw w)) es

        IToF ->
            build1 (\w -> Unsafe (RawIToF w)) es

        FLoad ->
            build1 (\v -> Unsafe (RawLoadFlt v)) es

        FToI32 ->
            build1 (\f -> Unsafe (RawUn { op = RFToI32, v = f })) es

        Sext ->
            build1 (\w -> Unsafe (RawUn { op = RSext, v = w })) es

        Uext ->
            build1 (\w -> Unsafe (RawUn { op = RUext, v = w })) es

        BitNot ->
            build1 (\w -> Unsafe (RawUn { op = RBitNot, v = w })) es

        RecLen ->
            -- The MEASURED macro (Ast's J1 table row; the tree is RtPrims'
            -- recLenOf, RtPrims.elm:216-228): len * (1 - isNil), the
            -- nil-aware i32 length.  `v` is pure, so lowering it twice is
            -- exactly what the DSL's macro writes.
            case es of
                [ v ] ->
                    Ok
                        (Unsafe
                            (RawBin
                                { op = RMul
                                , a = Unsafe (RawPayload32 { value = v, word = 1 })
                                , b =
                                    Unsafe
                                        (RawBin
                                            { op = RSub
                                            , a = Lit (LNumber 1)
                                            , b = Unsafe (RawTagIs { value = v, tag = RtLayout.valLayout.tagNil })
                                            }
                                        )
                                }
                            )
                        )

                _ ->
                    Err arityBug

        RawStr ->
            -- the static C-string address (stage 6 U2): the content is the
            -- STRING LITERAL (an EStr — the only AST the parser admits for
            -- this builtin's one slot), lowered to `Lit (LString s)` then to
            -- the RawCStr WORD node.  A non-literal reaches this Err loudly
            -- (never a silent guess).
            case es of
                [ Lit (LString s) ] ->
                    Ok (Unsafe (RawCStr s))

                _ ->
                    Err "rawstr needs a string literal (the content is static data — RawCStr)"

        Ast.RawSym ->
            -- the FUNCTION-symbol address (stage 6 A1b): the symbol is the
            -- STRING LITERAL (an EStr, the only AST the parser admits for this
            -- builtin's one slot), lowered to the RawSym WORD node whose
            -- content is the function's name VERBATIM.  A non-literal reaches
            -- this Err loudly (never a silent guess).
            case es of
                [ Lit (LString s) ] ->
                    Ok (Unsafe (Mid.Ir.RawSym s))

                _ ->
                    Err "rawsym needs a string literal (the symbol is a static code label — RawSym)"


arityBug : String
arityBug =
    "lowered with the wrong arity — Check J1 must reject it first"


buildMk : Int -> List Exp -> Result String Exp
buildMk tag es =
    case es of
        [ w ] ->
            Ok (Unsafe (RawMkValue { tag = tag, words = [ w ] }))

        _ ->
            Err arityBug


buildMk2 : Int -> List Exp -> Result String Exp
buildMk2 tag es =
    case es of
        [ w1, w2 ] ->
            Ok (Unsafe (RawMkValue { tag = tag, words = [ w1, w2 ] }))

        _ ->
            Err arityBug


build1 : (Exp -> Exp) -> List Exp -> Result String Exp
build1 k es =
    case es of
        [ a ] ->
            Ok (k a)

        _ ->
            Err arityBug


build2 : (Exp -> Exp -> Exp) -> List Exp -> Result String Exp
build2 k es =
    case es of
        [ a, b ] ->
            Ok (k a b)

        _ ->
            Err arityBug


build3 : (Exp -> Exp -> Exp -> Exp) -> List Exp -> Result String Exp
build3 k es =
    case es of
        [ a, b, c ] ->
            Ok (k a b c)

        _ ->
            Err arityBug



-- ============================ the operator maps ============================


{-| 1:1 with Mid.Ir's RawBinOp (Ast's WordBinOp doc): `>>` is the ARITHMETIC
shift (RShAr), `>>>` the zero-fill one (RShR).
-}
wordBinOp : WordBinOp -> RawBinOp
wordBinOp op =
    case op of
        WAdd ->
            RAdd

        WSub ->
            RSub

        WMul ->
            RMul

        WDiv ->
            RDiv

        WBitAnd ->
            RBitAnd

        WBitOr ->
            RBitOr

        WBitXor ->
            RBitXor

        WShl ->
            RShl

        WShAr ->
            RShAr

        WShR ->
            RShR


wordCmpOp : WordCmpOp -> RawCmpOp
wordCmpOp op =
    case op of
        WCeq ->
            RCeq

        WCne ->
            RCne

        WClts ->
            RClts

        WCles ->
            RCles

        WCgts ->
            RCgts

        WCges ->
            RCges


fltBinOp : FltBinOp -> RawFltBinOp
fltBinOp op =
    case op of
        FAdd ->
            RFAdd

        FSub ->
            RFSub

        FMul ->
            RFMul

        FDiv ->
            RFDiv


fltCmpOp : FltCmpOp -> RawFltCmpOp
fltCmpOp op =
    case op of
        FLt ->
            RFLt

        FLe ->
            RFLe

        FGt ->
            RFGt

        FGe ->
            RFGe

        FEq ->
            RFEq

        FNe ->
            RFNe



-- ============================ A2: field/index/deref lowering ============================


{-| Resolve a pointer-typed expression's POINTEE family — the lowerer's own
read of the ONE table the A1 checker laid out.  Handles the forms that can
PRODUCE a pointer: a binder whose declared type is `*T` (the type scope the
lowerer threads beside the binder ids), a pointer FIELD via its struct table, a
pointer-valued `?:` join whose branches agree (J1), and the `[*T](w)` view cast
(midlang-u8 — it IS its operand, so its pointee is its target).  Anything else is a
LOUD internal error: the checker admitted a pointer here (J13 resolved `p`),
so an unresolvable base is a lowering gap named, never a silent guess.
-}
resolvePointee : St -> Ast.Exp -> Result String PTy
resolvePointee st e =
    case e of
        Ast.EVar name ->
            case Dict.get name st.types of
                Just (TPtr pty) ->
                    Ok pty

                Just (TStruct sname) ->
                    -- B2: a struct VALUE's value IS its address, so for
                    -- every field/index resolution below it behaves exactly
                    -- like a `*S` pointing at itself.
                    Ok (PStruct sname)

                Just ty ->
                    Err
                        (internal st ("field/index base '" ++ name ++ "'")
                            ("is " ++ typeStrOf ty ++ ", not a pointer — Check J13 must reject it first")
                        )

                Nothing ->
                    Err (internal st ("field/index base '" ++ name ++ "'") "is unbound at the lowerer — Check J5 must reject it first")

        Ast.EField base f ->
            case resolvePointee st base of
                Err msg ->
                    Err msg

                Ok (PStruct sname) ->
                    case fieldTyIn st.decls sname f of
                        Just (TPtr pty) ->
                            Ok pty

                        Just (TStruct inner) ->
                            Ok (PStruct inner)

                        Just ty ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f ++ "'")
                                    ("is " ++ typeStrOf ty ++ ", not a pointer — Check J13 must reject it first")
                                )

                        Nothing ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f ++ "'")
                                    "is not in the struct table — Check J13 must reject it first"
                                )

                Ok pty ->
                    Err
                        (internal st "field access"
                            ("needs a struct pointer, got *" ++ ptyStr pty ++ " — Check J13 must reject it first")
                        )

        Ast.EIndex base _ ->
            -- B3: `xs[i]` on an array of structs is a struct VALUE (the
            -- element's address), so it is a legal field base — `xs[i].k` and
            -- `xs[i].k = e` resolve here exactly as `s.k` does.  An array of
            -- POINTERS (`*S[2]`) yields the pointee family the same way.
            case maybeValueTy st base of
                Just (TArray (TStruct sname) _) ->
                    Ok (PStruct sname)

                Just (TArray (TPtr pty) _) ->
                    Ok pty

                _ ->
                    Err
                        (internal st "a field base"
                            "is an index whose element is not a struct (or a pointer) — Check J13 must reject it first"
                        )

        Ast.EIf _ a _ ->
            -- the branches agree (J1), so the then-branch's pointee is the
            -- join's.
            resolvePointee st a

        Ast.ECast (Ast.TPtr pty) _ ->
            -- midlang-u8: the `[*T](w)` VIEW CAST is the IDENTITY at lowering
            -- (`lowerCast`'s pointer arm emits no node — it is J12's
            -- `word -> *T` row), so the base's pointee IS the cast target.
            -- This is the spelling a `val`-BOXED block needs — the effect
            -- parser carries block ADDRESSES in `val`s, so without a binder to
            -- hold one, `[*CmdState](payload(p, 0))->argv` was the only
            -- tier-(i) way to name the field, and J13 had already admitted it
            -- (the cast's operand class is `word`) while the lowerer refused
            -- it as a gap.
            Ok pty

        _ ->
            Err
                (internal st "a field/index base"
                    "is a pointer-typed expression form the lowerer cannot resolve (a pointer-returning call / a pointer-valued block-if join) — a lowering gap, not a checker reject"
                )


{-| A struct field's BYTE offset and its declaration, from the SAME table the
checker built (`Check.fieldOffset` — the one-table property).  `Nothing` here
is a lowerer/checker drift, loud, never a guessed offset.

(cffi U6) The record comes back WHOLE (type AND declared width) because the
access node needs both: the type picks the word/val/address shape and the
width picks the load/store mnemonic and sign.  Taking the width from the same
declaration the layout measured is what makes "laid out as `u16`, accessed as
a word" unrepresentable — there is no second place to read it from.
-}
fieldInfo : St -> String -> String -> Result String ( Int, Ast.Field )
fieldInfo st sname fname =
    case Check.fieldOffset st.decls sname fname of
        Just off ->
            case fieldDeclIn st.decls sname fname of
                Just f ->
                    Ok ( off, f )

                Nothing ->
                    Err
                        (internal st ("field '" ++ sname ++ "." ++ fname ++ "'")
                            "is not in the struct table — Check J13 must reject it first"
                        )

        Nothing ->
            Err
                (internal st ("field '" ++ sname ++ "." ++ fname ++ "'")
                    "is not in the struct table — Check J13 must reject it first"
                )


{-| A struct field's DECLARED type, structurally — a pure read of the decl
(the same `.ty` the checker's layout and class rules read).  This is NOT
layout logic: the offset/size arithmetic lives in `Check`, this only
discriminates word/pointer vs `val` for the node shape.

(cffi U6) The WIDTH rides with the type (`fieldDeclIn`), so this wrapper is
only for the class discriminators that do not care which load a narrow field
gets.
-}
fieldTyIn : List Decl -> String -> String -> Maybe Type
fieldTyIn decls structName fieldName =
    Maybe.map .ty (fieldDeclIn decls structName fieldName)


{-| (cffi U6) The field's whole declaration — its `Type` AND its optional
declared memory width, from the same structural walk the class rules use.
-}
fieldDeclIn : List Decl -> String -> String -> Maybe Ast.Field
fieldDeclIn decls structName fieldName =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            case d of
                StructDecl s ->
                    if s.name == structName then
                        fieldDeclInMembers s.members fieldName

                    else
                        fieldDeclIn rest structName fieldName

                EnumDecl _ ->
                    fieldDeclIn rest structName fieldName

                ExternDecl _ ->
                    fieldDeclIn rest structName fieldName


{-| The declared type of a struct's field, walking the body — B5: a union
block's members are PROMOTED, so `m.n` finds `n` inside the block (that is
the same namespace the checker's table exposes).
-}
fieldDeclInMembers : List Ast.StructMember -> String -> Maybe Ast.Field
fieldDeclInMembers members name =
    case members of
        [] ->
            Nothing

        m :: rest ->
            case m of
                Ast.MField f ->
                    if f.name == name then
                        Just f

                    else
                        fieldDeclInMembers rest name

                Ast.MUnion ms ->
                    case fieldDeclInFields ms name of
                        Just f ->
                            Just f

                        Nothing ->
                            fieldDeclInMembers rest name


fieldDeclInFields : List Field -> String -> Maybe Ast.Field
fieldDeclInFields fields name =
    case fields of
        [] ->
            Nothing

        f :: rest ->
            if f.name == name then
                Just f

            else
                fieldDeclInFields rest name


{-| `base + off` — the ADDRESS of a struct's field, `off` in BYTES (cffi U6:
the layout table is byte-granular, so `events` in `{ i32; u16; u16 }` is
`base + 4`, not `base + 8*4`).  Two rules wear it:
a struct-typed field READ (the field IS a location, so no load happens)
and the `&place` lowering.  `off = 0` is the IDENTITY, so the emitted tree
for a field at offset 0 is unchanged from before B2 (the A2 pins compare
trees, and they must keep passing).

MEASURED NOTE — THE VAL-FIELD SCALING THIS FIXES.  `RawVecLoad`/
`RawVecStore` index in VALUE units (the backend's `elemAddr` multiplies by
40), while the layout table gives offsets in WORD units.  Passing a word
offset straight to a vec node was therefore a 40x misplacement for any
`val` field NOT at word 0 (`struct S { a : word; v : val; }` put `v` at
word 1 = byte 8; the node addressed byte 40).  A1's rows could not see it
(the pinned structs had a single val field, at offset 0) and A2's tree pins
still pass because offset 0 is the identity.  Addressing the field in BYTES
(`addrPlus`) and indexing the vec at 0 is exact for every offset.
-}
addrPlus : Exp -> Int -> Exp
addrPlus base off =
    if off <= 0 then
        base

    else
        Unsafe (RawBin { op = RAdd, a = base, b = Lit (LNumber off) })


{-| The field READ node.  `off` is the field's BYTE offset (`Check.fieldOffset`).

  * a field with a declared SUB-WORD width (cffi U6) -> `RawMemLoad` at that
    byte offset, with the WIDTH and the SIGN from the declaration
    (`loadub`/`loadsb`/`loaduh`/`loadsh`/`loaduw`/`loadw`, each widening into
    the word register);  an `i64`/`u64` field is exactly a word and takes the
    word path below;
  * `val` -> `RawVecLoad` (the 5-word Blit) at the field's byte address;
  * a nested STRUCT or an ARRAY -> its address (`addrPlus`, no load);
  * everything else (word/pointer — the checker rejects float fields, J11) ->
    `RawWordLoad { index = off / 8 }`, the WORD-offset form the emitted bytes
    already have.  The division is exact because a WORD-ADDRESSED field at a
    non-multiple-of-8 offset is a J11 REJECT (`layoutOf`'s `wordIndexed` rule)
    — that check, not an alignment hope, is what rules the truncation out.
-}
fieldLoad : Ast.Field -> Exp -> Int -> Exp
fieldLoad f p1 off =
    case subWordWidthOf f.width of
        Just ( w, signed ) ->
            Unsafe (RawMemLoad { width = w, signed = signed, ptr = p1, off = off })

        Nothing ->
            case f.ty of
                TVal ->
                    Unsafe (RawVecLoad { vec = addrPlus p1 off, index = Lit (LNumber 0) })

                TStruct _ ->
                    addrPlus p1 off

                TArray _ _ ->
                    -- B3: an ARRAY field's value is its ADDRESS (the array
                    -- repr), so the read is the field's location — no load,
                    -- exactly the nested struct's rule two lines up.
                    addrPlus p1 off

                _ ->
                    Unsafe (RawWordLoad { ptr = p1, index = Lit (LNumber (off // 8)) })


{-| The single-node field STORE, matching `fieldLoad`'s rows.  A `TStruct`
field never reaches here: `fieldStoreNodes` branches to the word-for-word
COPY first (one node cannot express it, and a one-word store of a struct's
address would be silently wrong).

(cffi U6) A declared MEMORY WIDTH stores `storeb`/`storeh`/`storew` — the
LOW bits of the word value, at the field's byte offset.  Both signs write the
same bytes; only the load's extension is signed.
-}
fieldStore : Ast.Field -> Exp -> Int -> Exp -> Exp
fieldStore f p1 off e1 =
    case subWordWidthOf f.width of
        Just ( w, _ ) ->
            Unsafe (RawMemStore { width = w, ptr = p1, off = off, value = e1 })

        Nothing ->
            case f.ty of
                TVal ->
                    Unsafe (RawVecStore { vec = addrPlus p1 off, index = Lit (LNumber 0), value = e1 })

                _ ->
                    Unsafe (RawWordStore { ptr = p1, index = Lit (LNumber (off // 8)), value = e1 })


{-| (cffi U6) A declared field width -> the SUB-WORD access it lowers to, or
`Nothing` for the two widths that are exactly a word.

`i64`/`u64` are 8 bytes with 8-byte alignment: their access IS the existing
`RawWordLoad`/`RawWordStore` at `offset / 8`, so they take the word path and
the declaration buys only the honest layout numbers (a `u64` field beside a
`u32` lands where C puts it).  Everything narrower is a `RawMemLoad`/
`RawMemStore` with a width and (for a LOAD) a sign.

The sign is returned WITH the width rather than inferred at the emission site
(the plan's "the sign rule is an explicit node field"): `i32` and `u32` are the
same four bytes and the same register class, and only the declaration says
which extension the read needs.

`FfiTy`'s call-boundary-only spellings (`ptr`/`f64`/`void`) cannot appear on a
field — the parser's field-width table admits exactly the eight integer
widths, and `Check`'s J11 refuses a non-memory width if one ever arrives — so
their arm is the word path, the total function's honest default.
-}
subWordWidthOf : Maybe Ast.FfiTy -> Maybe ( MemWidth, Bool )
subWordWidthOf mw =
    case mw of
        Just Ast.FI8 ->
            Just ( MemB, True )

        Just Ast.FU8 ->
            Just ( MemB, False )

        Just Ast.FI16 ->
            Just ( MemH, True )

        Just Ast.FU16 ->
            Just ( MemH, False )

        Just Ast.FI32 ->
            Just ( MemW, True )

        Just Ast.FU32 ->
            Just ( MemW, False )

        _ ->
            Nothing


-- ==================== B2: struct VALUES (storage, copy, address) ====================


{-| THE ONE PLACE STRUCT STORAGE IS ALLOCATED (B2, re-seated on the FRAME by
B4b).  `allocN sizeof S` — `size` WORDS of QBE stack memory (`RawAllocN` ->
`Il.Alloc`, the seat B4 landed and the loop cells use), NOT a `malloc` call:
the frame owns the block, so a scope exit cannot leak it and no `free` is
ever needed.  B2/B3 used `malloc` only because `Mid.Ir` had no frame-alloc
node at the time.

THE OBLIGATION THE SWAP CREATES is the reverse of the leak it removes: the
ADDRESS of the block dies with the frame, so the surface must not let it
outlive the frame (`Check`'s escape rule — `return &s`, a store through a
pointer, and the documented retention obligation).

`size` comes from `Check.sizeofStruct` — the one layout table.
-}
structAlloc : St -> String -> Result String Exp
structAlloc st sname =
    case Check.sizeofStruct st.decls sname of
        Just size ->
            -- cffi U6: the table's number is BYTES and `RawAllocN` takes
            -- WORDS; the byte size is always word-quantised (Check's J11
            -- rejects a layout that is not), so this is exact.
            Ok (Unsafe (RawAllocN size))

        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "has no layout in the struct table — Check J11 must reject it first"
                )


{-| The ZEROED tail of `S s;` — `memset(addr, 0, sizeof S)` in BYTES (cffi
U6: the table's size is bytes, so the `8 *` the word-granular table needed is
gone; the emitted number for every word-class struct is the same one it always
was).  Uninitialised raw memory is a silent-wrong-value generator, and this
language has no `unsafe` marker to opt into it.
-}
structZero : St -> String -> Exp -> Result String Exp
structZero st sname addr =
    case Check.structSizeBytes st.decls sname of
        Just size ->
            Ok
                (Unsafe
                    (RawCallRaw
                        { sym = "memset"
                        , args = [ addr, Lit (LNumber 0), Lit (LNumber size) ]
                        }
                    )
                )

        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "has no layout in the struct table — Check J11 must reject it first"
                )


{-| A struct declaration's BODY, structurally — the same `.members` the
checker's layout walks (NOT layout logic: offsets and widths are read from
`Check.fieldOffset`/`Check.fieldWidth`, the one table).  B5: a `MUnion`
block rides through unchanged, so the word walk can distinguish a block (one
`max`-sized overlap) from a plain field.
-}
fieldsOf : List Decl -> String -> Maybe (List Ast.StructMember)
fieldsOf decls sname =
    case decls of
        [] ->
            Nothing

        d :: rest ->
            case d of
                StructDecl sd ->
                    if sd.name == sname then
                        Just sd.members

                    else
                        fieldsOf rest sname

                EnumDecl _ ->
                    fieldsOf rest sname

                ExternDecl _ ->
                    fieldsOf rest sname


{-| The WORD OFFSETS a struct value occupies, relative to its base, in field
order — every field expanded to the whole words it covers (`val` = 5,
nested struct = its own size, word/pointer = 1).  This is what the COPY
walks: one 8-byte load/store per word is exact for a val slot too (a
40-byte Value is five words, which is why the copy needs no Blit node and
no class rule).
-}
structWordsAt : St -> String -> Int -> Result String (List Int)
structWordsAt st sname bias =
    case fieldsOf st.decls sname of
        Nothing ->
            Err
                (internal st ("struct value '" ++ sname ++ "'")
                    "is not in the decl table — Check J11 must reject it first"
                )

        Just fields ->
            fieldsWords st sname bias fields


fieldsWords : St -> String -> Int -> List Ast.StructMember -> Result String (List Int)
fieldsWords st sname bias members =
    case members of
        [] ->
            Ok []

        m :: rest ->
            case m of
                Ast.MField f ->
                    case Check.fieldOffset st.decls sname f.name of
                        Nothing ->
                            Err
                                (internal st ("field '" ++ sname ++ "." ++ f.name ++ "'")
                                    "has no offset in the struct table — Check J13 must reject it first"
                                )

                        Just off ->
                            case Check.fieldWidth st.decls sname f.name of
                                Nothing ->
                                    Err
                                        (internal st ("field '" ++ sname ++ "." ++ f.name ++ "'")
                                            "has no width in the struct table — Check J13 must reject it first"
                                        )

                                Just w ->
                                    case fieldsWords st sname bias rest of
                                        Err msg ->
                                            Err msg

                                        Ok tailWords ->
                                            case fieldWords st bias (off // 8) f.ty w of
                                                Err msg ->
                                                    Err msg

                                                Ok here ->
                                                    Ok (here ++ tailWords)

                Ast.MUnion ms ->
                    -- B5: the block's members are the SAME bytes, so the copy
                    -- must NOT walk them one by one (a `word` member beside a
                    -- `val` one would cover 1 word and then 5 at one offset) —
                    -- it copies the block's ONE overlapped range, `max` wide.
                    case fieldsWords st sname bias rest of
                        Err msg ->
                            Err msg

                        Ok tailWords ->
                            case unionWords st sname bias ms of
                                Err msg ->
                                    Err msg

                                Ok here ->
                                    Ok (here ++ tailWords)


{-| B5 — a union block's words: ONE range at the block's SHARED offset,
`max(member widths)` words wide (the offset is the same for every member, so
the first member's is the block's: MEASURED off the one table, never summed).
-}
unionWords : St -> String -> Int -> List Field -> Result String (List Int)
unionWords st sname bias ms =
    case ms of
        [] ->
            Err
                (internal st ("union block in '" ++ sname ++ "'")
                    "has no members — Check J11 rejects an empty block first"
                )

        f :: _ ->
            case Check.fieldOffset st.decls sname f.name of
                Nothing ->
                    Err
                        (internal st ("union member '" ++ sname ++ "." ++ f.name ++ "'")
                            "has no offset in the struct table — Check J11 must reject it first"
                        )

                Just off ->
                    case unionWidest st sname ms of
                        Err msg ->
                            Err msg

                        Ok w ->
                            Ok (intsFrom (bias + off // 8) w)


{-| The widest member of a union block — the block's size, the same `max`
`Check.layoutOf` advanced the cursor by (read through
`Check.fieldWidth`, i.e. the ONE `fieldSize` rule).
-}
unionWidest : St -> String -> List Field -> Result String Int
unionWidest st sname ms =
    case ms of
        [] ->
            Ok 0

        f :: rest ->
            case Check.fieldWidth st.decls sname f.name of
                Nothing ->
                    Err
                        (internal st ("union member '" ++ sname ++ "." ++ f.name ++ "'")
                            "has no width in the struct table — Check J11 must reject it first"
                        )

                Just w ->
                    case unionWidest st sname rest of
                        Err msg ->
                            Err msg

                        Ok tail ->
                            Ok (max w tail)


{-| One field's word offsets: a nested struct recurses (its own base is the
outer offset — a struct value is contiguous by the layout rule), everything
else is `w` consecutive words at `off`.
-}
fieldWords : St -> Int -> Int -> Type -> Int -> Result String (List Int)
fieldWords st bias off ty w =
    case ty of
        TStruct inner ->
            structWordsAt st inner (bias + off)

        _ ->
            Ok (intsFrom (bias + off) w)


intsFrom : Int -> Int -> List Int
intsFrom off n =
    if n <= 0 then
        []

    else
        off :: intsFrom (off + 1) (n - 1)


{-| ONE word copy: `dst[dOff] = src[sOff]`.
-}
wordCopy : Exp -> Int -> Exp -> Int -> Exp
wordCopy dst dOff src sOff =
    Unsafe
        (RawWordStore
            { ptr = dst
            , index = Lit (LNumber dOff)
            , value = Unsafe (RawWordLoad { ptr = src, index = Lit (LNumber sOff) })
            }
        )


{-| The word-for-word COPY of `sname`'s words from `src` (at `srcOff`) into
`dst` (at `dstOff`) — the aggregate-init / assignment / struct-field store
lowering (plan Q4).  `dstOff` is the field's offset when the destination is
a FIELD of a bigger struct, 0 for a whole value.
-}
copyStores : St -> String -> Int -> Int -> Exp -> Exp -> Result String (List Exp)
copyStores st sname dstOff srcOff dst src =
    case structWordsAt st sname 0 of
        Err msg ->
            Err msg

        Ok words ->
            Ok (List.map (\w -> wordCopy dst (dstOff + w) src (srcOff + w)) words)


{-| The store-node list for `base.f = e` (and for one `S s = { f = e; }`
initialiser entry): a `TStruct` field is a COPY (its own word list, at the
field's offset), every other field is the single `fieldStore` node.  A
one-node store of a struct's address would be silently wrong — that is the
seam this function closes.
-}
fieldStoreNodes : St -> String -> String -> Exp -> Exp -> Result String (List Exp)
fieldStoreNodes st sname f base e =
    case fieldInfo st sname f of
        Err msg ->
            Err msg

        Ok ( off, fld ) ->
            case fld.ty of
                TStruct inner ->
                    -- the copy walks WORD offsets, so the field's byte offset
                    -- must divide by 8 — which `Check.layoutOf` CHECKS (a
                    -- word-addressed field at a non-multiple-of-8 offset is a
                    -- J11 reject).  Before that check, a nested struct with a
                    -- 4-byte alignment (e.g. `struct Inner { a : u32; b : u32; }`
                    -- at byte 4) copied from word 0 to word 0 and clobbered
                    -- the fields above it.
                    copyStores st inner (off // 8) 0 base e

                _ ->
                    Ok [ fieldStore fld base off e ]


{-| The store nodes one `S s = ...` initialiser needs, WITH the state the
initialiser expressions consumed (an `InitCopy`/`InitFields` operand is a
real expression, lowered in order like any other).
-}
structInitNodes : St -> String -> Exp -> StructInit -> Result String ( St, List Exp )
structInitNodes st sname addr init =
    case init of
        InitZero ->
            case structZero st sname addr of
                Err msg ->
                    Err msg

                Ok zero ->
                    Ok ( st, [ zero ] )

        InitFields fields ->
            initFieldsNodes st sname addr fields []

        InitCopy e ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, e1 ) ->
                    case copyStores st sname 0 0 addr e1 of
                        Err msg ->
                            Err msg

                        Ok stores ->
                            Ok ( st1, stores )


initFieldsNodes : St -> String -> Exp -> List ( String, Ast.Exp ) -> List Exp -> Result String ( St, List Exp )
initFieldsNodes st sname addr fields acc =
    case fields of
        [] ->
            Ok ( st, acc )

        ( f, e ) :: rest ->
            case fieldInfo st sname f of
                Err msg ->
                    Err msg

                Ok ( _, fld ) ->
                    case lowerExp st e of
                        Err msg ->
                            Err msg

                        Ok ( st1, e1 ) ->
                            let
                                -- B1's box, at a `val` FIELD slot: the same
                                -- rule SFieldStore applies.
                                e2 =
                                    if fld.ty == Ast.TVal && isBoolExp st e then
                                        boolToVal e1

                                    else
                                        e1
                            in
                            case fieldStoreNodes st sname f addr e2 of
                                Err msg ->
                                    Err msg

                                Ok nodes ->
                                    initFieldsNodes st1 sname addr rest (acc ++ nodes)


-- ==================== B3: ARRAY values (storage, stride, init) ====================


{-| THE ONE PLACE ARRAY STORAGE IS ALLOCATED (B3, re-seated on the FRAME by
B4b) — `allocN words`, `words` from the SAME width walk `sizeof` uses
(`sizeofWords`), which is the same table `Check` laid out.  `RawAllocN` ->
`Il.Alloc` is the frame-alloc seat B2/B3 lacked (the plan put the missing
node in B4's row; `Il.Alloc` itself is a tier BELOW this module and was
never reachable from here).

WHAT THE SWAP CHANGES, stated because it is observable: the block belongs to
the FRAME, so (1) it can never leak, (2) its ADDRESS is the same on every
execution of the declaration (a `word[4] a;` inside a loop body reuses one
frame slot for every iteration — C's usual behaviour, not a guarantee), and
(3) the address must not outlive the frame (`Check`'s escape rule).
-}
arrayAlloc : St -> Ast.Type -> Result String Exp
arrayAlloc st aty =
    case sizeofWords st (Ast.SizeType aty) of
        Err msg ->
            Err msg

        Ok words ->
            if words <= 0 then
                Err
                    (internal st ("array value '" ++ typeStrOf aty ++ "'")
                        "has no words — Check J11 must reject a zero-length array first"
                    )

            else
                Ok (Unsafe (RawAllocN words))


{-| The ZEROED tail of `T[N] a;` — `memset(addr, 0, 8*words)`, the same rule
and node `S s;` uses (uninitialised raw memory in a language with no `unsafe`
marker is a silent-wrong-value generator).
-}
arrayZero : St -> Ast.Type -> Exp -> Result String Exp
arrayZero st aty addr =
    case sizeofWords st (Ast.SizeType aty) of
        Err msg ->
            Err msg

        Ok words ->
            Ok
                (Unsafe
                    (RawCallRaw
                        { sym = "memset"
                        , args = [ addr, Lit (LNumber 0), Lit (LNumber (8 * words)) ]
                        }
                    )
                )


{-| The store nodes one array initialiser needs, WITH the state its element
expressions consumed (lowered in written order, like every other expression
list).
-}
arrayInitNodes : St -> Ast.Type -> Exp -> ArrayInit -> Result String ( St, List Exp )
arrayInitNodes st aty addr init =
    case init of
        AInitZero ->
            case arrayZero st aty addr of
                Err msg ->
                    Err msg

                Ok zero ->
                    Ok ( st, [ zero ] )

        AInitFull es ->
            case aty of
                TArray elem _ ->
                    arrayElemStores st elem addr 0 es []

                _ ->
                    Err
                        (internal st "an array initialiser"
                            "on a non-array type — the parser only produces one from `T[N] id`, so this is a drift"
                        )


arrayElemStores : St -> Ast.Type -> Exp -> Int -> List Ast.Exp -> List Exp -> Result String ( St, List Exp )
arrayElemStores st elem addr i es acc =
    case es of
        [] ->
            Ok ( st, acc )

        e :: rest ->
            case lowerExp st e of
                Err msg ->
                    Err msg

                Ok ( st1, e1 ) ->
                    let
                        e2 =
                            if elem == Ast.TVal && isBoolExp st e then
                                boolToVal e1

                            else
                                e1
                    in
                    case arrayElemStore st elem addr (Ast.EInt i) (Lit (LNumber i)) e2 of
                        Err msg ->
                            Err msg

                        Ok nodes ->
                            arrayElemStores st1 elem addr (i + 1) rest (acc ++ nodes)


{-| ONE array element's store node(s): the element's AST index (`astI`) and
its lowered form (`i1`) decide where, exactly as the read does:

  * `val` -> `RawVecStore { vec = base, index = i }` — the backend's elemAddr
    multiplies by 40, and a val array IS a run of 40-byte handles;
  * struct -> an element COPY (the B2 word-for-word copy) into the element's
    own address (`elemAddr`) — a one-word store of the address would be
    silently wrong, the seam `fieldStoreNodes` closes for struct fields;
  * word/pointer/bool -> one `RawWordStore` at `i * stride` words (stride 1
    for every scalar class, so a literal index folds to the constant offset).

The stride comes from `sizeofWords` (the ONE width walk).  A nested-array
element cannot reach here — `Check` refuses to store or initialise one.
-}
arrayElemStore : St -> Ast.Type -> Exp -> Ast.Exp -> Exp -> Exp -> Result String (List Exp)
arrayElemStore st elem base astI i1 e =
    case elem of
        Ast.TVal ->
            Ok [ Unsafe (RawVecStore { vec = base, index = i1, value = e }) ]

        Ast.TStruct sname ->
            case sizeofWords st (Ast.SizeType elem) of
                Err msg ->
                    Err msg

                Ok stride ->
                    copyStores st sname 0 0 (elemAddr base astI i1 stride) e

        Ast.TArray _ _ ->
            Err
                (internal st "an array element store"
                    "whose element is itself an array — Check J13 must reject it first"
                )

        _ ->
            case sizeofWords st (Ast.SizeType elem) of
                Err msg ->
                    Err msg

                Ok stride ->
                    Ok [ Unsafe (RawWordStore { ptr = base, index = scaledIndex astI i1 stride, value = e }) ]


{-| `base + 8 * (i * stride)` — the ADDRESS of element `i` of a block whose
element stride is `stride` WORDS.  A literal index folds into the constant
(the plan §3 fold `scaledIndex` already does for pointer indices); a computed
index is `base + (i * 8*stride)`.
-}
elemAddr : Exp -> Ast.Exp -> Exp -> Int -> Exp
elemAddr base astI i1 stride =
    case astI of
        Ast.EInt k ->
            -- cffi U6: `stride` is WORDS (the table's byte size / 8) and
            -- `addrPlus` adds BYTES.
            addrPlus base (k * stride * 8)

        _ ->
            Unsafe
                (RawBin
                    { op = RAdd
                    , a = base
                    , b = Unsafe (RawBin { op = RMul, a = i1, b = Lit (LNumber (8 * stride)) })
                    }
                )


{-| The array element READ node, mirroring `arrayElemStore`:

  * `val` -> `RawVecLoad` (the 40-byte handle read, VALUE-unit index);
  * struct / nested array -> the element's ADDRESS (`elemAddr`, no load: the
    element is a location, so `a[i].f` and `m[i][j]` compose);
  * word/pointer/bool -> `RawWordLoad` at `i * stride` (stride 1 for every
    scalar class, so the index IS the word offset — the `wload` contract).
-}
arrayElemLoad : St -> Ast.Type -> Exp -> Ast.Exp -> Exp -> Result String Exp
arrayElemLoad st elem base astI i1 =
    case elem of
        Ast.TVal ->
            Ok (Unsafe (RawVecLoad { vec = base, index = i1 }))

        Ast.TStruct _ ->
            case sizeofWords st (Ast.SizeType elem) of
                Err msg ->
                    Err msg

                Ok stride ->
                    Ok (elemAddr base astI i1 stride)

        Ast.TArray _ _ ->
            case sizeofWords st (Ast.SizeType elem) of
                Err msg ->
                    Err msg

                Ok stride ->
                    Ok (elemAddr base astI i1 stride)

        Ast.TFloat ->
            Err
                (internal st "a float array element"
                    "has no raw-memory seat — Check J1 must reject the array first"
                )

        _ ->
            case sizeofWords st (Ast.SizeType elem) of
                Err msg ->
                    Err msg

                Ok stride ->
                    Ok (Unsafe (RawWordLoad { ptr = base, index = scaledIndex astI i1 stride }))


{-| A place expression's VALUE type, when the lowerer can name it: a binder
(`st.types`, which carries the declared classes of params and binders alike),
a struct FIELD (via the struct table the checker laid out), and an ARRAY
element (recursively).  `Nothing` when the form is outside this set — the
caller then takes its pre-B3 path, so no accepted lowering moves.

This is what routes `a[i]` to the ARRAY arithmetic (the base's type is a
`TArray`) instead of the pointer arithmetic, and it is a pure read of
declared types — no second class table.
-}
maybeValueTy : St -> Ast.Exp -> Maybe Ast.Type
maybeValueTy st e =
    case e of
        Ast.EVar name ->
            Dict.get name st.types

        Ast.EField base f ->
            case resolvePointee st base of
                Ok (PStruct sname) ->
                    fieldTyIn st.decls sname f

                _ ->
                    Nothing

        Ast.EIndex base _ ->
            case maybeValueTy st base of
                Just (TArray elem _) ->
                    Just elem

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Run a list of store nodes IN ORDER, each bound to its own fresh dead
binder (L2's `(b 107, rStore ..)` shape — a store's result slot must be a
valid binder even though nothing reads it), then the continuation.
-}
withStores : String -> St -> List Exp -> (St -> Result String (St, Exp)) -> Result String (St, Exp)
withStores label st stores cont =
    case stores of
        [] ->
            cont st

        e :: rest ->
            let
                ( dead, st1 ) =
                    fresh label st
            in
            case withStores label st1 rest cont of
                Err msg ->
                    Err msg

                Ok ( st2, body ) ->
                    Ok ( st2, Let { binders = [ LetBind { binder = dead, value = e } ], body = body } )



{-| The index READ node, scaled by the pointee family: `*word` -> `wload`'s
word-offset index; `*val` -> `vecload`; `*S` -> the index scaled by
`sizeof S` (a word multiply, folded to a literal for a literal index).
-}
indexLoad : St -> PTy -> Exp -> Ast.Exp -> Exp -> Result String Exp
indexLoad st pty p1 astI i1 =
    case pty of
        PWord ->
            Ok (Unsafe (RawWordLoad { ptr = p1, index = i1 }))

        PVal ->
            Ok (Unsafe (RawVecLoad { vec = p1, index = i1 }))

        PStruct sname ->
            case Check.sizeofStruct st.decls sname of
                Just size ->
                    Ok (Unsafe (RawWordLoad { ptr = p1, index = scaledIndex astI i1 size }))

                Nothing ->
                    Err
                        (internal st ("index access on '*" ++ sname ++ "'")
                            "has no struct in the table — Check J11 must reject it first"
                        )


{-| The index STORE node, matching `indexLoad`'s shape.
-}
indexStore : St -> PTy -> Exp -> Ast.Exp -> Exp -> Exp -> Result String Exp
indexStore st pty p1 astI i1 e1 =
    case pty of
        PWord ->
            Ok (Unsafe (RawWordStore { ptr = p1, index = i1, value = e1 }))

        PVal ->
            Ok (Unsafe (RawVecStore { vec = p1, index = i1, value = e1 }))

        PStruct sname ->
            case Check.sizeofStruct st.decls sname of
                Just size ->
                    Ok (Unsafe (RawWordStore { ptr = p1, index = scaledIndex astI i1 size, value = e1 }))

                Nothing ->
                    Err
                        (internal st ("index store on '*" ++ sname ++ "'")
                            "has no struct in the table — Check J11 must reject it first"
                        )


{-| The `*S` index scale: the index is a STRUCT ELEMENT, so the word offset
is `i * sizeof S`.  A literal index folds to `Lit (k*sizeofS)` (the plan §3
fold); a computed index lowers to `RawBin { op = RMul, a = i, b = Lit size }`.
-}
scaledIndex : Ast.Exp -> Exp -> Int -> Exp
scaledIndex astI i1 size =
    case astI of
        Ast.EInt k ->
            Lit (LNumber (k * size))

        _ ->
            Unsafe (RawBin { op = RMul, a = i1, b = Lit (LNumber size) })


ptyStr : PTy -> String
ptyStr pty =
    case pty of
        PStruct sname ->
            sname

        PWord ->
            "word"

        PVal ->
            "val"


typeStrOf : Type -> String
typeStrOf ty =
    case ty of
        TStruct sname ->
            sname

        TWord ->
            "word"

        TBool ->
            "bool"

        TFloat ->
            "float"

        TVal ->
            "val"

        TPtr pty ->
            "*" ++ ptyStr pty

        TArray elem n ->
            typeStrOf elem ++ "[" ++ String.fromInt n ++ "]"



-- ============================ internal errors ============================


{-| The loud internal error: names the defun, the nearest construct and the
judgment that should have rejected the shape first.  Checked input cannot
reach these.
-}
internal : St -> String -> String -> String
internal st what why =
    st.key ++ ": RtLang internal: " ++ what ++ " " ++ why
