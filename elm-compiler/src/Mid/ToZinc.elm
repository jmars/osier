module Mid.ToZinc exposing (render, entries)

-- Mid.ToZinc — the middle tier's EMITTER: Mid.Ir -> flat ZINC bytecode.
--
-- STAGE 1 CONTRACT: this module is `Lower/Expr.elm`'s emission rules MOVED
-- (copied) into the middle tier, and its output must be BYTE-IDENTICAL to the
-- `MIDTIER=0` path (`Lower.Module`/`Lower.Expr`) for every input.  No
-- optimization happens here — this is the same instruction stream, produced
-- from a tree instead of from the raw AST.  `Lower/Expr.elm`'s header
-- documents the contract this file implements, verbatim:
--
--   * POSITION (`Tail | NonTail`) decides `p` (apply) vs `t` (appterm) for an
--     application, and whether a `let`/`case` emits its `d` (endlet)
--     instructions: in genuine tail position the tail call / frame pop
--     discards the bindings naturally, so no endlet is emitted.
--   * binop  `lhs OP rhs`   -> code(rhs) code(lhs) P <prim>   (RTL prim args)
--   * call   `f a1..an`     -> m code(an)..code(a1) code(f) p|t  (RTL args;
--     the VM pops top-first so argbuf[0] = param1 = first source arg =
--     access(n-1)).  The CALLEE is always emitted in NonTail position (a
--     nested application in callee position is `p`, never `t`).
--   * let    x = e1 in e2   -> code(e1) e code(e2) [d]
--   * if     c t e          -> code(c) f Lf code(t) j Le Lf: code(e) Le:
--   * list   [a,b,c]        -> n0 P emptylist code(c) P cons code(b) P cons
--                              code(a) P cons
--   * tuple  (a,b)          -> code(b) code(a) P @p
--   * record {f=e}          -> n0 P emptylist, then per setter in REVERSE
--                              source order: code(e) s f P @p P cons
--   * 0-arg  const ref      -> m g name p   (apply the thunk to get its value)
--   * N-arg  fn as a value  -> g name       (load the closure)
--   * curried prim wrappers -> the VM prim apply branch is NOT curried, so
--     operators/partial applications route through `<op>.curried` wrapper
--     GLOBALS (Mid.Module emits one defun per wrapper).
--
-- THE VM'S N>A FAST PATH AND THE 0-ARG THUNK RULE are why `App` is n-ary in
-- the IR: the VM's apply has a fast path for an arity-N closure applied to N
-- args (N>A nests vmExecEnv frames, N<A builds a partial closure).  Stage 1
-- only PRESERVES today's shapes; the S5 arity/saturation pass is what will
-- eventually exploit them.
--
-- ENVIRONMENT: the emitter threads an env of BINDER IDS, innermost first, and
-- resolves `Var id` to `Access (depth of id in env)`.  That is exactly the
-- de Bruijn convention `Lower.Scope` implements by NAME (`Access n` loads
-- env[env_len - 1 - n]), including the fact that a closure body's env EXTENDS
-- the enclosing one (`emitLambda` in Lower.Expr pushes the lambda's params on
-- top of the enclosing scope).  Ids come from Mid.FromAst and are unique
-- within their Defun; a `Var` whose id is not in the env can only mean a
-- compiler bug in this tier, and it is emitted as `Access -1` so that the VM
-- faults loudly on the out-of-range read instead of silently returning a
-- neighbouring slot.

import Mid.Ir exposing (Alt, Binder, Defun, Exp(..), Lambda, LetBinder(..), Lit(..), Match(..), Step(..), ValuePath(..))
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit exposing (Instr(..), Target(..))


-- ============================ ENTRY ============================
-- render : the WHOLE bundle text.  `Lower.Module` concatenates each unit's
-- entry strings and wraps them ONCE in `Csexp.list`; this does the same over
-- the unit programs (order preserved: fns, then ctors, then wrappers).


render : List Mid.Ir.Program -> String
render programs =
    Csexp.list (List.concatMap entries programs)


-- One csexp bundle-entry text per defun, in program order.  The DRIVER
-- concatenates these across units and wraps them ONCE (that is what makes the
-- corpus cache byte-identical to a single whole-program compile).
entries : Mid.Ir.Program -> List String
entries defuns =
    List.map defunEntry defuns


defunEntry : Defun -> String
defunEntry defun =
    Csexp.bundleEntry defun.key
        (Emit.flatten (Emit.resolve (emitExp Tail [] defun.value)))


-- ============================ POSITION ============================


type Position
    = Tail
    | NonTail


-- ============================ EMITTER ============================


emitExp : Position -> List Int -> Exp -> List Instr
emitExp pos env exp =
    case exp of
        Lit lit ->
            [ litInstr lit ]

        Var id ->
            [ Access (depthOf env id) ]

        GRef ref ->
            if ref.force then
                -- 0-arg top-level constant: a thunk, so APPLY it for its value.
                [ Pushmark, Global ref.key, Apply ]

            else
                [ Global ref.key ]

        StreamRef ref ->
            -- M6 stdin/stdout pseudo-globals: `value` reads the VM value table.
            [ Symbol ref.varName, Prim "value" ]

        Lam lambda ->
            emitLam env lambda

        NoTail inner ->
            emitExp NonTail env inner

        App app ->
            Pushmark
                :: (List.concat (List.reverse (List.map (emitExp NonTail env) app.args))
                        ++ emitExp NonTail env app.fn
                        ++ [ applyInstr pos ]
                   )

        PrimApp app ->
            List.concat (List.reverse (List.map (emitExp NonTail env) app.args))
                ++ [ Prim app.prim ]

        Let block ->
            let
                ( bindCode, bodyEnv, slots ) =
                    emitLetBinders env block.binders
            in
            bindCode
                ++ emitExp pos bodyEnv block.body
                ++ (if pos == NonTail then List.repeat slots Endlet else [])

        Case branch ->
            emitExp NonTail env branch.scrutinee
                ++ [ Let_ ]
                ++ List.concatMap (emitAlt pos (branch.scrutId.id :: env) branch.scrutId branch.endLabel) branch.alts
                ++ [ String_ "non-exhaustive case", Prim "simple-error", Label_ branch.endLabel ]
                ++ (if pos == NonTail then [ Endlet ] else [])

        Con con ->
            -- MX ADT representation: vector[tag, a1..an].  The value/index
            -- pairs are pushed root-first (source order), the vector is
            -- allocated LAST so it sits on top, and n+1 `address->` stores
            -- each pop the vector/index/value triple and re-push the vector.
            [ Symbol con.tag, Number_ 0 ]
                ++ List.concat
                    (List.indexedMap
                        (\i arg -> emitExp NonTail env arg ++ [ Number_ (i + 1) ])
                        con.args
                    )
                ++ [ Number_ (List.length con.args + 1), Prim "absvector" ]
                ++ List.repeat (List.length con.args + 1) (Prim "address->")

        Tup es ->
            -- cons chain, right-to-left: (a,b,c) -> code(c) code(b) P @p
            -- code(a) P @p
            List.foldl
                (\e acc -> acc ++ emitExp NonTail env e ++ (if List.isEmpty acc then [] else [ Prim "@p" ]))
                []
                (List.reverse es)

        RecordLit setters ->
            List.foldl
                (\( field, value ) acc -> acc ++ emitExp NonTail env value ++ [ Symbol field, Prim "@p", Prim "cons" ])
                [ Number_ 0, Prim "emptylist" ]
                (List.reverse setters)

        RecordGet rec field ->
            emitExp NonTail env rec ++ [ Symbol field, Prim "assoc", Prim "snd" ]

        RecordUpdate update ->
            emitExp NonTail env update.base
                ++ List.concatMap
                    (\( field, value ) -> emitExp NonTail env value ++ [ Symbol field, Prim "@p", Prim "cons" ])
                    update.updates

        ListLit es ->
            [ Number_ 0, Prim "emptylist" ]
                ++ List.concatMap (\e -> emitExp NonTail env e ++ [ Prim "cons" ]) (List.reverse es)

        If block ->
            emitExp NonTail env block.cond
                ++ [ Jmpf (TRef block.falseLabel) ]
                ++ emitExp pos env block.thenBranch
                ++ [ Jmp (TRef block.endLabel) ]
                ++ [ Label_ block.falseLabel ]
                ++ emitExp pos env block.elseBranch
                ++ [ Label_ block.endLabel ]

        ShortAnd block ->
            emitExp NonTail env block.left
                ++ [ Jmpf (TRef block.falseLabel) ]
                ++ emitExp NonTail env block.right
                ++ [ Jmp (TRef block.endLabel) ]
                ++ [ Label_ block.falseLabel, Boolean_ False, Label_ block.endLabel ]

        ShortOr block ->
            emitExp NonTail env block.left
                ++ [ Jmpf (TRef block.falseLabel) ]
                ++ [ Boolean_ True, Jmp (TRef block.endLabel) ]
                ++ [ Label_ block.falseLabel ]
                ++ emitExp NonTail env block.right
                ++ [ Label_ block.endLabel ]

        NotEqual block ->
            emitExp NonTail env block.right
                ++ emitExp NonTail env block.left
                ++ [ Prim "=" ]
                ++ [ Jmpf (TRef block.falseLabel), Boolean_ False, Jmp (TRef block.endLabel) ]
                ++ [ Label_ block.falseLabel, Boolean_ True, Label_ block.endLabel ]


-- A closure: the body is compiled in Tail position and the body's env EXTENDS
-- the enclosing one (captures).  `grabs` = params - 1 (the first param arrives
-- by apply); zero grabs for a 0- or 1-param closure.
emitLam : List Int -> Lambda -> List Instr
emitLam env lambda =
    let
        bodyEnv =
            List.foldl (\p acc -> p.id :: acc) env lambda.params
    in
    [ Cur
        (List.repeat (List.length lambda.params - 1) Grab
            ++ emitExp Tail bodyEnv lambda.body
            ++ [ Return ]
        )
    ]


applyInstr : Position -> Instr
applyInstr pos =
    case pos of
        Tail ->
            Appterm

        NonTail ->
            Apply


litInstr : Lit -> Instr
litInstr lit =
    case lit of
        LNumber n ->
            Number_ n

        LFloat f ->
            Float_ f

        LString s ->
            String_ s

        LSymbol s ->
            Symbol s

        LBoolean b ->
            Boolean_ b


-- ============================ LET ============================
-- Each plain binder pushes ONE env slot (`Let_`); a pattern-destructuring
-- binder pushes one scrutinee temp PLUS one slot per pattern binding, which is
-- what the NonTail endlet count must add up to (matches Lower.Expr.bindAll).


emitLetBinders : List Int -> List LetBinder -> ( List Instr, List Int, Int )
emitLetBinders env binders =
    case binders of
        [] ->
            ( [], env, 0 )

        binder :: rest ->
            let
                ( code, env1 ) =
                    emitLetBinder env binder

                ( restCode, env2, restSlots ) =
                    emitLetBinders env1 rest
            in
            ( code ++ restCode, env2, letSlots binder + restSlots )


letSlots : LetBinder -> Int
letSlots binder =
    case binder of
        LetBind _ ->
            1

        LetDestruct destruct ->
            1 + List.length destruct.binds


emitLetBinder : List Int -> LetBinder -> ( List Instr, List Int )
emitLetBinder env binder =
    case binder of
        LetBind bind ->
            ( emitExp NonTail env bind.value ++ [ Let_ ]
            , bind.binder.id :: env
            )

        LetDestruct destruct ->
            let
                scrutEnv =
                    destruct.scrutId.id :: env

                ( bindCode, bodyEnv ) =
                    emitBinds scrutEnv destruct.scrutId destruct.binds
            in
            ( emitExp NonTail env destruct.value
                ++ [ Let_ ]
                ++ List.concatMap (\m -> matchInstrs scrutEnv destruct.scrutId m ++ [ Jmpf (TRef destruct.badLabel) ]) destruct.matches
                ++ [ Jmp (TRef destruct.okLabel) ]
                ++ [ Label_ destruct.badLabel, String_ "non-exhaustive let pattern", Prim "simple-error" ]
                ++ [ Label_ destruct.okLabel ]
                ++ bindCode
            , bodyEnv
            )


-- ============================ CASE ============================


emitAlt : Position -> List Int -> Binder -> String -> Alt -> List Instr
emitAlt pos env scrutId endLabel alt =
    let
        ( bindCode, bodyEnv ) =
            emitBinds env scrutId alt.binds
    in
    List.concatMap (\m -> matchInstrs env scrutId m ++ [ Jmpf (TRef alt.nextLabel) ]) alt.matches
        ++ bindCode
        ++ emitExp pos bodyEnv alt.body
        ++ (if pos == NonTail then List.repeat (List.length alt.binds) Endlet else [])
        ++ [ Jmp (TRef endLabel), Label_ alt.nextLabel ]


-- ============================ PATTERN READS ============================
-- Each binding is read from the scrutinee slot by its PATH and then pushed as
-- its own env slot, so binding j is read while j-1 binders sit on top of the
-- scrutinee (exactly the running slot index Lower.Expr.compileBindings uses).


emitBinds : List Int -> Binder -> List ( Binder, ValuePath ) -> ( List Instr, List Int )
emitBinds env scrutId binds =
    List.foldl
        (\( binder, path ) ( acc, e ) ->
            ( acc ++ pathInstrs e scrutId path ++ [ Let_ ], binder.id :: e )
        )
        ( [], env )
        binds


matchInstrs : List Int -> Binder -> Match -> List Instr
matchInstrs env scrutId match =
    case match of
        MCons path ->
            readPath env scrutId path ++ [ Prim "cons?" ]

        MEmpty path ->
            readPath env scrutId path ++ [ Prim "empty?" ]

        MVector path ->
            readPath env scrutId path ++ [ Prim "absvector?" ]

        MTagEq path tag ->
            readPath env scrutId path ++ [ Symbol tag, Prim "=" ]

        MLitEq path lit ->
            readPath env scrutId path ++ [ litInstr lit, Prim "=" ]


pathInstrs : List Int -> Binder -> ValuePath -> List Instr
pathInstrs env scrutId path =
    case path of
        VPath steps ->
            readPath env scrutId steps

        VField steps field ->
            readPath env scrutId steps ++ [ Symbol field, Prim "assoc", Prim "snd" ]


readPath : List Int -> Binder -> List Step -> List Instr
readPath env scrutId steps =
    let
        ( prefix, suffix ) =
            List.foldl collectStep ( [], [] ) steps
    in
    prefix ++ (Access (depthOf env scrutId.id) :: suffix)


-- `<-address` pops vec first then idx, so the index push precedes the vector
-- push; the steps stay post-fix prims in the suffix.
collectStep : Step -> ( List Instr, List Instr ) -> ( List Instr, List Instr )
collectStep step ( prefix, suffix ) =
    case step of
        FstStep ->
            ( prefix, suffix ++ [ Prim "fst" ] )

        SndStep ->
            ( prefix, suffix ++ [ Prim "snd" ] )

        HdStep ->
            ( prefix, suffix ++ [ Prim "hd" ] )

        TlStep ->
            ( prefix, suffix ++ [ Prim "tl" ] )

        IdxStep j ->
            ( Number_ j :: prefix, suffix ++ [ Prim "<-address" ] )


-- ============================ ENV ============================


depthOf : List Int -> Int -> Int
depthOf env id =
    case env of
        [] ->
            -- Unreachable for a tree Mid.FromAst built: every Var was resolved
            -- against a binder that this traversal also pushes.  -1 faults
            -- loudly (out-of-range Access) rather than reading a neighbour.
            -1

        head :: rest ->
            if head == id then
                0

            else
                1 + depthOf rest id
