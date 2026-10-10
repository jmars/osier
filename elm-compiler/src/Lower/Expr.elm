module Lower.Expr exposing
    ( resolveModuleAlias
    , binaryPrims
    , wrapperGlobalName
    , primWrappers
    , unaryPrims
    , ternaryPrims
    )

-- The language's SHARED name/prim tables — the single source of truth the
-- typechecker (Type/Infer, Type/Builtins via Lower.Resolve), the module
-- orchestration (Mid/Module) and the tree lowering (Mid/FromAst) all read.
--
-- P8 (osier-delete-zinc): this module was the direct AST-to-ZINC LOWERER; the
-- whole lowering body (the `Instr` machine over Zinc.Emit, Position, the
-- Context API, and every lower* function) died with the csexp backend, and
-- ONLY the backend-neutral tables below survive.  They stay UNDER THIS NAME
-- because Type/Infer imports Lower.Expr for `resolveModuleAlias` and the
-- typechecker is the research contribution — its imports do not move.  The
-- QBE backend lowers from Mid.FromAst's trees, not from here.
--
-- Historical note: the orchestration in Mid/Module still emits one curried
-- wrapper defun per primWrappers/unaryPrims/ternaryPrims row, so these tables
-- decide which `P <prim>` fast paths exist as VALUES in user programs, on
-- BOTH backends the tree has had.


-- Rewrite a dotted reference token through import aliases: `import
-- Elm.Syntax.Range as Range` rewrites "Range.empty" ->
-- "Elm.Syntax.Range.empty".  Tokens whose first segment is not an alias pass
-- through unchanged.
resolveModuleAlias : List ( String, String ) -> String -> String
resolveModuleAlias aliases token =
    case aliases of
        [] ->
            token

        ( alias, real ) :: rest ->
            if token == alias then
                real

            else if String.startsWith (alias ++ ".") token then
                real ++ String.dropLeft (String.length alias) token

            else
                resolveModuleAlias rest token


-- Operator -> VM prim-name table.  Single source of truth for BOTH the inline
-- `P <prim>` fast path and the curried wrapper globals (the orchestrator
-- emits a wrapper defun per row).
binaryPrims : List ( String, String )
binaryPrims =
    [ ( "+", "+" )
    , ( "-", "-" )
    , ( "*", "*" )
    , ( "//", "/" )
    , ( "/", "f/" )
    , ( "==", "=" )
    , ( "<", "<" )
    , ( "<=", "<=" )
    , ( ">", ">" )
    , ( ">=", ">=" )

    -- (::) as a VALUE (e.g. `foldr (::) []`): this row mints the `::`-curried
    -- wrapper (primWrappers derives from binaryPrims).  INLINE `x :: xs`
    -- keeps its dedicated operator-application case in the lowering, so
    -- operator lowering is unchanged.
    , ( "::", "cons" )
    ]


wrapperGlobalName : String -> String
wrapperGlobalName op =
    op ++ ".curried"


-- Prims that additionally get a CURRIED WRAPPER usable as a value.
-- The orchestrator emits one `<prim>.curried` wrapper global per row:
--   * primWrappers -> 2-ARG wrapper; covers every binary operator plus `cn`
--     (source-order concat).
--   * unaryPrims   -> 1-ARG wrapper; c-strlen pops exactly ONE value, and a
--     2-arg wrapper would under-apply into a stray partial closure when
--     called full-arity.
primWrappers : List ( String, String )
primWrappers =
    binaryPrims
        ++ [ ( "", "cn" )
           , ( "", "repeat" )
           , ( "", "write-byte" )
           , ( "", "open" )
           , ( "", "setenv" )
           , ( "", "char-code" )

           -- Vector read (JsArray substitute): `<-address` is 2-ARG (vec,
           -- idx), so a 2-arg wrapper is the right shape.
           , ( "", "<-address" )

           -- elm/core Bitwise support (Array port): 2-ARG prims exposed as
           -- <prim>.curried wrappers via the Bitwise.* primDotAliases.
           , ( "", "bitwise-and" )
           , ( "", "bitwise-or" )
           , ( "", "bitwise-xor" )
           , ( "", "bitwise-shift-left" )
           , ( "", "bitwise-shift-right" )
           , ( "", "bitwise-shift-right-zf" )
           ]


unaryPrims : List String
unaryPrims =
    [ "c-strlen", "read-byte", "read-file-as-string", "close", "shen.str->bytes", "shen.bytes->string"
    , "intern", "exec-plan", "cd", "getenv", "glob", "getcwd", "getpid"

    -- Vector make + Bitwise complement (Array port): both 1-ARG, so the
    -- 1-arg wrapper is the right shape (see the c-strlen note above).
    , "absvector", "bitwise-not"

    -- Structural-compare predicates (Prelude.compare dispatcher): number?
    -- covers Int AND Float (primNumberP), string? also matches Char (which
    -- lowers to a 1-byte string), cons? matches lists AND tuples (both cons
    -- chains), empty? is the nil test.
    , "string?", "number?", "cons?", "empty?"

    -- Str.fromFloat: the 1-arg `str` prim renders ANY scalar (float via
    -- values.floatText = shortest {d} + ".0" when integral) as a string.
    , "str"
    ]


-- 3-ARG prim wrappers: the wrapper body pushes param3 first so the vector
-- lands ON TOP — `address->` pops (vec, idx, val) in that order.
ternaryPrims : List String
ternaryPrims =
    [ "address->" ]
