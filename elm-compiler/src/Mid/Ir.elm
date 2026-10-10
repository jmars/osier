module Mid.Ir exposing
    ( Program
    , Defun
    , Exp(..)
    , Lambda
    , Binder
    , Lit(..)
    , Alt
    , AltKind(..)
    , Match(..)
    , LetBinder(..)
    , Step(..)
    , ValuePath(..)
    )

-- Mid.Ir — the MIDDLE TIER's intermediate representation (MLton's Xml/Sxml
-- level, ported to this compiler's needs).
--
-- LAYERING (handoff mid-tier-plan-result, stage S1):
--
--     parse -> Type.Check.checkUnits -> Mid.FromAst -> Mid.Qbe.* -> .ssa
--
-- Mid sits STRICTLY AFTER `Type.Check.checkUnits` and must never disturb
-- `Type/*` (the project's research contribution).  P8 (osier-delete-zinc):
-- the retired csexp output tier (Mid.ToZinc -> Zinc.Emit -> csexp, and the
-- Mid optimization-pass set behind the MIDTIER switch) is deleted; the QBE
-- backend (Mid.QbeModule) is this IR's only consumer, and the byte-identity
-- anchor is the per-fixture .ssa corpus baseline
-- (tools/osier-corpus-baseline.ssa.sha256).
--
-- WHY NO SSA/SSA2/RSSA (plan decision D1): those IRs exist in MLton to feed
-- NATIVE codegen (register allocation, def-use chains, machine-level
-- optimizations).  ZINC is a CURRIED CLOSURE VM whose cost model is
-- call/environment/closure-shaped — its expensive operations are env
-- allocation per call, closure allocation per partial application, the NESTED
-- vmExecEnv per over-applied arity, envPush per `let`, and O(1) `Access` —
-- so the analogous middle tier is a TREE IR, and MLton's own composition at
-- that level is Xml/Sxml (mlton/main/compile.fun), not SSA.
--
-- WHAT THE IR CARRIES (and what it deliberately does not):
--   * `Var` refers to a binder by a UNIQUE Int id, never by name: shadowing is
--     explicit in the tree and a pass can move a binder without re-resolving
--     string scopes.  Ids are unique WITHIN ONE `Defun` (each Defun's
--     allocation counter starts fresh); the emitter's environment is
--     per-Defun, so that is exactly the scope in which they must be unique.
--   * `App` is n-ary and `PrimApp` is full-arity, so SATURATION IS VISIBLE
--     (the plan's S5 arity/saturation pass needs to see it: ZINC pays for a
--     partial-closure copy at N<A and for nested vmExecEnv frames at N>A).
--   * `Let` is a SEQUENTIAL (non-recursive) binder list, matching Elm 0.19
--     semantics and the existing desugarer; `LetBinder` distinguishes a plain
--     value binding from a PATTERN-DESTRUCTURING binding (which the ZINC
--     emitter lowers to a case with a `simple-error` failure arm).
--   * `Case` has a flat list of alts, each carrying its ordered match TESTS,
--     its bindings and its body; `AltKind` records what the alt is ABOUT
--     (ctor tag / literal / other) so a later pass can recognize a
--     case-of-known-constructor without re-reading the test sequence.
--   * Values are type-ERASED: every ZINC value is a uniform tagged VM value,
--     which is why MLton's monomorphise/simplify-types/split-types/poly-equal
--     are all unnecessary here (plan §(a)).
--   * `Con` / `Tup` / `RecordLit` / `RecordUpdate` are REP-PRESERVING: they
--     name the source-level constructor, and `Mid.Qbe.Lower` maps them to
--     the runtime's value representations (per-ctor Desc vectors, cons
--     chains, assoc-list records).  THE REPRESENTATION IS A LOWER-LEVEL
--     CHOICE AND IS NOT CHANGED BY THE TIER: a pass must not silently alter
--     it.
--
-- LABELS: `Label` is a String; names matter only for uniqueness (a case
-- expression keys its jump targets by them).  `Mid.FromAst` names them from
-- the source range, which keeps them site-unique within a defun.
--
-- GC-REFERENCE INFORMATION — THE DOOR THIS IR MUST NOT CLOSE (plan §(a)
-- design constraint, recorded here, with NO machinery added in stage 1).
-- The eventual second backend is QBE IL, and the runtime keeps this project's
-- OWN MOVING GC (`vendor/zinc-vm/src/gc.zig`), which is a PRECISE collector:
-- `gc/roots.zig` keeps an authoritative shadow stack of explicit roots
-- (ROOT_VALUE for a by-value Value, ROOT_VALUE_ARRAY for an array of Values
-- plus a live count) and `gc/scan.zig` scans tag-directed, so the collector
-- must be told, at every allocation/call SAFEPOINT, which slots are live
-- GC-managed Values.  Since ZINC's representation is uniform (`Value` for
-- every local, every env slot, every element), what such a backend needs is
-- not per-value pointer-ness but the FRAME LAYOUT AND LIVENESS at each
-- safepoint.  THAT IS EXACTLY WHAT THIS IR KEEPS AND WHAT IT WOULD LOSE IF
-- IT WERE FLATTENED:
--   * every binder is a named, unique id and every use is an explicit `Var`,
--     so def-use (and therefore liveness at any node) is computable;
--   * the frame boundaries are explicit structure — `Lam.params` (one frame
--     per closure body), `Let.binders` (one envPush per binder), `Case.scrutId`
--     plus each alt's `binds` (the scrutinee temp and pattern bindings that
--     occupy env slots), and `Defun` (the top-level closure).
-- WHERE THE INFORMATION WOULD BE ATTACHED (no code for it in stage 1): the
-- natural seat is a per-`Defun` frame-layout table, and/or a per-node
-- annotation slot on the constructs that are safepoints (`App`, `PrimApp`,
-- `Con`, `RecordLit`, `ListLit`, `Tup`, `Lam` allocation) listing the live
-- binder ids at that node.  The IR's shapes above are chosen so that seat can
-- be added WITHOUT reshaping the tree — and, importantly, so that no pass is
-- forced to erase binder identity or frame structure to do its work.
-- MEASURED CAVEAT (this contradicts the brief's premise, so it is recorded
-- rather than assumed): `Type.Check.checkUnits` returns the checker-REWRITTEN
-- `List File.File` and nothing else — the inferred per-node types stay inside
-- `Type.Infer`/`Type.Env` and are NOT reachable from `Mid.FromAst` today.  So
-- FromAst is the right PLACE for GC-representation information (it is the only
-- post-inference consumer, and it is where the tree is born), but the
-- information would first have to be EXPOSED by `Type/*` (a change that is out
-- of scope here and touches the research contribution).  This matters only if
-- a future representation UNBOXES values (a slot that is not a GC reference
-- must not be scanned); today's uniform tagged representation does not need
-- it, and `Type/Representation.elm` computes HM type syntax, not a boxing
-- decision.
--
-- SCAFFOLD STATUS: this is deliberately PROVISIONAL and the plan's addendum
-- says so — plain variant data, Config-style records for arguments, explicit
-- threading of the binder-supply counter (`Mid.FromAst.Gen`).  It is intended
-- to be reclaimed verbatim by the cleaner Osier language (GADTs + rank-2
-- first-class modules): the variant data ports as-is, the record arguments
-- become module/functor arguments, and the explicit counter threading becomes
-- module state.  Because every ported pass is SINGLE-INSTANTIATION (there is
-- no SSA here), the functor problem never materialises.


-- ============================ PROGRAM ============================
-- One Defun per bundle entry, keyed by the QUALIFIED dotted name
-- ("Prelude.map", "Main.fib").  A Defun's value is always a `Lam` (the
-- curried closure the VM's defun table stores), including the value-
-- constructor defuns and the curried prim wrappers.


type alias Program =
    List Defun


type alias Defun =
    { key : String
    , value : Exp
    }


-- ============================ BINDERS ============================
-- A local binder.  `id` is the identity a `Var` refers to and is UNIQUE within
-- its Defun; `name` exists for diagnostics and provenance only — emission must
-- never read it (that is what makes shadowing explicit in the tree).


type alias Binder =
    { id : Int
    , name : String
    }


-- ============================ LITERALS ============================


type Lit
    = LNumber Int
    | LFloat Float
    | LString String
    | LSymbol String
    | LBoolean Bool


-- ============================ EXPRESSIONS ============================
-- `NoTail` pins an expression's EMISSION POSITION to non-tail whatever the
-- context: a PIPE application (`f <| x`, `x |> f`) completes its callee's
-- argument list with the piped value and applies NON-tail, so it is a call
-- even at the tail of a function body.  That is a real cost site, so it is
-- visible in the tree rather than hidden in the backend.
--
-- Argument order convention (the backend's contract):
--   * `App.args` are in SOURCE order, i.e. the CALLEE's parameter order
--     (arg 1 first).
--   * `PrimApp.args` are in POP order — the order the VM primitive pops them
--     (first-popped first).  The emitter pushes them in REVERSE.  For an
--     infix operator `lhs OP rhs` that means `[ lhs, rhs ]`; for `substring`
--     (which pops string, start, len) it means `[ str, start, len ]`.
--   * `Con.args` are in SOURCE order.


type Exp
    = Lit Lit
    | Var Int
    | GRef { key : String, force : Bool }
    | StreamRef { varName : String }
    | Lam Lambda
    | NoTail Exp
    | App { fn : Exp, args : List Exp }
    | PrimApp { prim : String, args : List Exp }
    | Let { binders : List LetBinder, body : Exp }
    | Case { scrutinee : Exp, scrutId : Binder, alts : List Alt, endLabel : String }
    | Con { tag : String, args : List Exp }
    | Tup (List Exp)
    | RecordLit (List ( String, Exp ))
    | RecordGet Exp String
    | RecordUpdate { base : Exp, updates : List ( String, Exp ) }
    | ListLit (List Exp)
    | If { cond : Exp, thenBranch : Exp, elseBranch : Exp, falseLabel : String, endLabel : String }
    | ShortAnd { left : Exp, right : Exp, falseLabel : String, endLabel : String }
    | ShortOr { left : Exp, right : Exp, falseLabel : String, endLabel : String }
    | NotEqual { left : Exp, right : Exp, falseLabel : String, endLabel : String }


-- A closure body: n-ary parameters plus the body.  Parameter 1 is the OUTERMOST
-- binder (the ZINC arg convention puts it at the deepest env slot, so
-- param_i = access(n-i)).
type alias Lambda =
    { params : List Binder
    , body : Exp
    }


-- A `let` declaration.  Elm 0.19 `let`s are sequential (not recursive), so the
-- binders are threaded left to right and later declarations see earlier ones.
type LetBinder
    = LetBind { binder : Binder, value : Exp }
    | LetDestruct
        { scrutId : Binder
        , value : Exp
        , matches : List Match
        , binds : List ( Binder, ValuePath )
        , badLabel : String
        , okLabel : String
        }


-- One clause of a `case`.  `matches` is the ORDERED test sequence (each test
-- is followed, by the emitter, by a jump to `nextLabel` on failure); `binds`
-- are the pattern variables, in source order, each read from the scrutinee
-- temp slot; `body` inherits the case's emission position.
type alias Alt =
    { kind : AltKind
    , matches : List Match
    , binds : List ( Binder, ValuePath )
    , body : Exp
    , nextLabel : String
    }


-- What the alt is ABOUT, recorded for later passes (see Mid.Ir's header).  It
-- is metadata: the emission is driven by `matches`.
type AltKind
    = AltCtor String
    | AltLit Lit
    | AltOther


-- ============================ PATTERN TESTS ============================
-- A match test: each test reads a value out of the scrutinee by `ValuePath`
-- and tests it (source order, first-match-wins).


type Match
    = MCons (List Step)
    | MEmpty (List Step)
    | MVector (List Step)
    | MTagEq (List Step) String
    | MLitEq (List Step) Lit


-- A value path locates a (sub-)value inside the scrutinee: a sequence of
-- de-structuring steps from the scrutinee root.  `VField` additionally treats
-- the reached value as a record and looks `f` up in it (assoc + snd).  The
-- encoding is the runtime's own value decomposition, unchanged from the
-- retired ZINC path that first carried it.
type Step
    = FstStep
    | SndStep
    | HdStep
    | TlStep
    | IdxStep Int


type ValuePath
    = VPath (List Step)
    | VField (List Step) String
