module Mid.Ir exposing
    ( Program
    , Defun
    , Exp(..)
    , UnsafeNode(..)
    , RawBinOp(..)
    , RawUnOp(..)
    , RawCmpOp(..)
    , RawFltBinOp(..)
    , RawFltCmpOp(..)
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
    | Unsafe UnsafeNode


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


-- ============================ UNSAFE (RAW) NODES ============================
-- The RUNTIME-FROM-MID seat (handoff osier-midruntime-plan TRACK 2 step 3 /
-- handoff osier-rawnodes).  The project decision: the runtime (primitives
-- first, the GC later) is written AT THIS LEVEL, as compiler-internal defuns
-- under the reserved `Rt.*` key namespace, using nodes THE FRONT END NEVER
-- EMITS.  That is what makes the runtime one implementation for every backend
-- (QBE today, Lua later) with no ABI skew, while the SURFACE language keeps
-- its clean rows-under-refinement type story — it gains no unsafe tier.
--
-- THE INVARIANT: `Mid.FromAst` (and everything upstream of it) never emits an
-- `Unsafe` node.  It is enforced MECHANICALLY, in three seats, and it is NOT
-- enforced at the Elm type level — that was evaluated and MEASURED out
-- (handoff osier-rawnodes, /tmp/elm-probe, elm 0.19.2):
--
--   * a module CANNOT re-expose another module's constructors (BAD EXPORT:
--     "(..) cannot be used with a type alias"), so `UnsafeNode`'s home must be
--     the one module that can see both itself and `Exp`;
--   * a SECOND home is an IMPORT CYCLE (`UnsafeNode` embeds `List Exp` in
--     RawCall's args, so `Mid.Ir.Raw` would import `Mid.Ir` while `Mid.Ir`
--     imports `Mid.Ir.Raw` — elm rejects the cycle outright), so the opaque-
--     payload sketch from the plan review does not compile;
--   * the buildable residue (constructors private here + exposed builder
--     functions) confines DESTRUCTION only: any builder is callable by ANY
--     importer of `Mid.Ir` — and `Mid.FromAst` imports `Mid.Ir` today, so
--     construction has no Elm-0.19 wall.  No friend modules, no per-importer
--     visibility, and a capability value must leave its home through some
--     exposed definition that FromAst can read just as well.
-- The intended END STATE remains a GADT (`type Exp mode = ... | Raw : ... ->
-- Exp Unsafe`), which real `elm make` rejects today (MEASURED: syntax problem
-- at the `:`) and which would strand `compiler.js` while sources are
-- dual-compiled.  Until that lane opens, the seats are:
--   1. `Mid.Audit` — wired into `Mid.QbeModule.lowerAll` so EVERY compile
--      fails loudly on an `Unsafe` node outside the `Rt.*` namespace;
--   2. the qbe-check TEXTUAL row `rg -c 'Unsafe|Raw' FromAst.elm == 0`;
--   3. name-level unreachability: surface code cannot NAME an `Rt.*` defun
--      (it is not a corpus unit), so the only route to a violating tree is a
--      FromAst bug — which the audit catches at the very next compile.
--
-- THE NODE SET was a hypothesis sized for `cons`; the cons spike (handoff
-- osier-consspike) sized it for real and CORRECTED it in three places, all
-- recorded at the seats:
--   * `RawMkValue` takes a WORD LIST, not one payload — `cons`'s payload is
--     TWO pointers into a 2-element GC array (values.zig valCons), and a
--     word list sizes every constructor in gc/types.zig (number/boolean 1,
--     cons/string/vector 2, stream 3, lambda 4; word i lands at Value offset
--     8 + 8i, the extern union behind the u32 tag).
--   * `RawVecAddr` is NEW — the ADDRESS of element i.  `RawVecLoad` loads
--     the element's VALUE, but a cons Value's car/cdr are INTERIOR POINTERS
--     `&pair[0]`/`&pair[1]`; without an address-of form the fused-pair
--     representation is unexpressible at this level.
--   * `RawPayload` gained a word index, mirroring the widened constructor.
-- THE REGISTER-CLASS SPLIT the spike found: raw nodes are VALUE producers
-- (`RawMkValue`, `RawVecLoad`) or WORD producers (`RawAllocVector`,
-- `RawVecAddr`, `RawTagOf`, `RawPayload`, `RawStrByte`, `RawByteLoad`,
-- `RawWordLoad`, and E's
-- `RawDataAddr`).  A word cannot live
-- in a frame slot (a slot IS a 40-byte Value the collector scans — a bare
-- address in one is a garbage tag away from a crash), so word-producing
-- binders are held in raw TEMPS (Mid.Qbe.Lower's `rawWord` side table, the
-- S4 `rawInt` precedent) and reading one in a value position is a LOUD
-- error, never a rebox.
--   * `RawCall` — call a runtime SYMBOL directly (QBE: a C symbol; Lua: a
--     host function) with full-arity args in source order.  LOWERED since
--     step 5 for `Rt.*` keys (the direct defun call: q_-mangled symbol,
--     :val args, :ret result, rt_bounce — the same shape the route hatch
--     emits), which is what makes the recursive Rt helpers (deepEqual,
--     numberText, the list walks) expressible; a NON-Rt symbol still errs
--     loudly (the word-level C seats are RawCallRaw's).
--   * `RawTagOf` / `RawPayload` — read a Value's tag / payload word i
--     (gc/types.zig: `Value` = `ValTag` + 32-byte union).
--   * `RawAllocVector` / `RawVecLoad` / `RawVecAddr` / `RawVecStore` — the
--     GC array level (allocArray of Values; `RawVecStore`'s barrier contract
--     is heap.zig `writeBarrierVectorStore`: store, then record the array in
--     the remembered set iff the array is old-gen AND the stored Value
--     references the nursery — the LOWERING routes the store through that
--     one runtime seat, so a node without the barrier is unrepresentable).
--     A raw array address is INVALID across a safepoint (it is a register
--     temp, not a root): the builder fills/stores before the next
--     allocation, and an unfilled element must never be scanned — the same
--     contract values.zig's valVector/valCons bodies obey.
--   * `RawStrByte` — byte i of a string Value (str.data[i]).  LOWERED since
--     step 5 (data pointer via RawPayload word 0, loadub, zero-extended —
--     the first string prim sized it, exactly as the spike predicted).
--   * `WithRoots` — STRUCTURAL ROOTING: the listed binders are live GC roots
--     across `body` (roots.zig ROOT_VALUE shape), so an allocation inside
--     `body` cannot stale them (the dd19b36 unrooted-staging class, made
--     unrepresentable at this level).  ON THE QBE BACKEND THIS LOWERS TO A
--     DOCUMENTED NO-OP (the spike's finding): `rt_frame_enter` already
--     registers the WHOLE pooled frame as one ROOT_VALUE_ARRAY, so every
--     Value binder is rooted for the entire body by construction.  The node
--     stays because the discipline is backend-INDEPENDENT — a backend
--     without the rooted-frame convention (and the phase-2 Mid-written GC)
--     lowers it to real root pushes.
-- REACHABILITY CAVEAT (why Rt.elm owns a seed list): `RawCall` crosses the
-- Mid-level call graph as an opaque SYMBOL, so Rt->Rt references are
-- invisible to the GRef walk — Mid.Rt.seeds declares each prim's Rt-key
-- closure (transitively closed by the builder that issued the RawCalls).
-- Nothing else in the compiler constructs these nodes EXCEPT Lower, a
-- second, TRANSIENT producer (E's record lowering builds RawDataAddr /
-- RawVecLoad / RawMkValue trees and lowers them in place —
-- they never enter the audited program, so Mid.Audit's rule is unaffected).
-- Mid.Rt is the only producer of the nodes that persist in a program, and
-- with injection hatched off (QBE_NOMIDRT=1) none exist at all — the corpus
-- `.ssa` reproduces the pre-Rt baseline byte-for-byte.


type UnsafeNode
    = RawCall { sym : String, args : List Exp }
    | RawTagOf Exp
    | RawPayload { value : Exp, word : Int }
    | RawMkValue { tag : Int, words : List Exp }
    | RawAllocVector Exp
    | RawVecLoad { vec : Exp, index : Exp }
    | RawVecAddr { vec : Exp, index : Exp }
    | RawVecStore { vec : Exp, index : Exp, value : Exp }
    | RawStrByte { str : Exp, index : Exp }
    | WithRoots { binders : List Binder, body : Exp }
    | -- ===== STEP 5 (osier-midprims): the SCALAR + STRING nodes the prim
      -- enumeration demanded.  The spike's set could build and walk Values but
      -- could not COMPUTE — `+`, `<`, bitwise, string bytes and the Rt->Rt
      -- calls the recursive helpers need were all unexpressible.  These forms
      -- close that at the same register-class discipline (word producers bind
      -- to raw temps; float words are a second class, `d` temps).
      -- 32-bit SIGNED payload read: str.len / vector.len / boolean are i32
      -- FIELDS (gc/types.zig extern struct) — a 64-bit RawPayload read of a
      -- ZIG-built Value's word reads GARBAGE in the high half (the extern
      -- struct store writes only 12 payload bytes; heap memory is recycled).
      -- Number payloads are i64 and keep RawPayload.
      RawPayload32 { value : Exp, word : Int }
    | -- tag == n as a BOOLEAN WORD (0/1, raw): the tag dispatch that must NOT
      -- go through Case MLitEq/MTagEq — those lower through rtPrimSlots "=",
      -- which ROUTES to Rt.eq when the route hatch is on, an infinite regress
      -- inside Rt.eq's own body.  Boxing it (RawMkValue tag 3) makes it an
      -- `If`/`ShortAnd` condition.
      RawTagIs { value : Exp, tag : Int }
    | -- semantic word ops (word x word -> word, raw).  The integer family
      -- (RAdd..RDiv) is i64 wrapping/truncating; the Bitwise family is i32
      -- (JS/Elm Bitwise: RBitAnd/Or/Xor at w, sign-extended back; RShl/RShAr
      -- sign-extended, RShR zero-extended; the count is masked mod 32 HERE,
      -- matching bitwise-shift-*'s shiftAmount) — the QBE widths live in the
      -- lowering, keeping this IR backend-neutral.
      RawBin { op : RawBinOp, a : Exp, b : Exp }
    | RawUn { op : RawUnOp, v : Exp }
    | -- signed i64 word compare -> 0/1 word (RClts RCles RCgts RCges, plus
      -- RCeq/RCne; equality on garbage-wide reads is exact, so no 32-bit
      -- compare form exists — use RawPayload32 first).
      RawCmp { op : RawCmpOp, a : Exp, b : Exp }
    | -- f64 word ops + compares (the M4 promote arms; operands are
      -- float-word EXPRESSIONS: RawLoadFlt/RawIToF or a nested bin — never a
      -- value or an integer word, register class loud on violation)
      RawFltBin { op : RawFltBinOp, a : Exp, b : Exp }
    | RawFltCmp { op : RawFltCmpOp, a : Exp, b : Exp }
    | -- i64 word -> f64 word (asFloat's number arm)
      RawIToF Exp
    | -- payload word 0 of a VALUE read as f64 (asFloat's float arm; a safe
      -- bit-read of any Value's payload — no trap on a mistagged arg, same
      -- class as the Zig `else => unreachable` in ReleaseFast)
      RawLoadFlt Exp
    | -- n raw BYTES (g.allocRaw — the GC_STR level, a SAFEPOINT like
      -- RawAllocVector: live Values must be rooted across it, and the
      -- returned address is a raw temp valid only to the next safepoint).
      -- The string-building seat under cn/substring/bytes->string.
      RawAllocRaw Exp
    | -- byte i of the RAW buffer at ptr (NOT of a string Value — that is
      -- RawStrByte; a string's data pointer arrives as RawPayload word 0)
      RawByteLoad { ptr : Exp, index : Exp }
    | -- store one byte into a raw buffer (effect, like RawVecStore; NO
      -- barrier — raw bytes hold no GC pointers by construction)
      RawByteStore { ptr : Exp, index : Exp, value : Exp }
    | -- word i of the RAW buffer at ptr: an 8-BYTE load at ptr + 8*index (the
      -- index is a WORD offset here, not a byte offset — a mark-sweep walks
      -- headers/page descriptors/free-list links a word at a time).  A WORD
      -- producer, like RawByteLoad.  Not a safepoint: a plain load allocates
      -- nothing and reads no Value.
      RawWordLoad { ptr : Exp, index : Exp }
    | -- store one 8-byte word at ptr + 8*index (effect, like RawByteStore;
      -- NO barrier — the word is host bookkeeping, not a GC Value reference)
      RawWordStore { ptr : Exp, index : Exp, value : Exp }
    | -- call a C runtime seat with WORD args and a WORD result (raw register
      -- class on both sides — rt_bytes_copy/rt_halt-class seats; alloc-FREE
      -- by contract, the allocating seats go through RawAllocVector /
      -- RawAllocRaw so the safepoint discipline stays stated at the node).
      -- Rt.* DEFUN calls are the OTHER constructor: RawCall above.
      RawCallRaw { sym : String, args : List Exp }
    | -- call through a RUNTIME WORD (a function/code pointer held in a
      -- register, not a named symbol) with an AGGREGATE result — the
      -- stage-6 apply/bounce port's voice (call the Desc code pointer).
      -- THE RESULT IS THE ADDRESS OF THE sret BUFFER, as a word: the node
      -- is a WORD producer (binds to a raw temp) and the caller reads the
      -- aggregate's fields with the EXISTING RawWordLoad at +0/+40/+48/...
      -- — no field-reading lives in this node.  `fn` is a WORD producer
      -- (the code pointer), `args` are WORD producers (raw-word lowering
      -- each), and `shape` is "ret" (the 80-B `:ret` call-result shape —
      -- val@0, kind@40, f@48, e@56, args@64, arity@72 — for unknown-code
      -- tail calls) or "val" (the 40-B tagged `:val` Value, for the
      -- saturated arm).  Lowered exactly like RawCallRaw but with the
      -- callee as a word ARGUMENT (`call %f(...)`) and an `Agg` result;
      -- legality probed against the vendored qbe (agg.ssa assembles exit 0,
      -- the sret temp addressable).  NOT allocation-free BY ITSELF — the
      -- callee is unknown generated code and may allocate, so the
      -- classification is conservatively a safepoint (Mid.Rt).
      RawCallAgg { fn : Exp, args : List Exp, shape : String }
    | -- (E) the ADDRESS of a static data def, built in Lower — an `Unsafe`
      -- WORD producer yielding the address of a content-keyed freshData
      -- array of `sym:<field>` DRefs (the names array of a positional
      -- record).  Transient: constructed by Lower's record lowering, never
      -- by Mid.Rt (Mid.Rt is the only producer of the other raw nodes).
      RawDataAddr (List String)
    | -- (stage 6 U2) the ADDRESS of a static NUL-terminated C-string data
      -- def — a WORD producer yielding the raw `l` pointer to a content-keyed
      -- `[DStr s, DByte 0]` def (the `sym:` key domain, shared with
      -- LSymbol/RawDataAddr's `sym:` dedup).  Built by Mid.RtLang's `rawstr`
      -- builtin and used by the rawAbi defuns (Rt.die/Rt.halt) to write
      -- STATIC messages to stderr WITHOUT allocating — a die path that
      -- interned via rt_string would recurse into the collector it is
      -- reporting on (the OOM/mmap-fail arms).  NOT a safepoint.
      RawCStr String
    | -- (stage 6 A1b) the ADDRESS of a FUNCTION symbol (a code label) — a
      -- WORD producer yielding `Il.Sym name` where `name` is the function's
      -- symbol VERBATIM (rt_bounce/rt_callN/a `q_Rt_*` defun), NOT a data
      -- def.  This is the producer the A1 review named: `RawCallAgg`'s
      -- callee can now name a FUNCTION by name, where `RawCStr`/`RawDataAddr`
      -- name DATA defs (a call into static data — MEASURED silently wrong).
      -- Built by Mid.RtLang's `rawsym` builtin; the ONLY surface route to a
      -- function symbol (RawCStr/RawDataAddr stay data-address producers and
      -- are rejected as call targets).  NOT a safepoint.
      RawSym String


-- The semantic word-op enums (backend-neutral: QBE's widths and mnemonics
-- are chosen in Mid.Qbe.Lower; a Lua backend maps each to its native op).
type RawBinOp
    = RAdd
    | RSub
    | RMul
    | RDiv
    | RBitAnd
    | RBitOr
    | RBitXor
    | RShl
    | RShAr
    | RShR


type RawUnOp
    = RBitNot -- i32 complement, sign-extended back to the word class
    | RSext -- w -> l sign-extend (the i32 result of a bitwise op)
    | RUext -- w -> l zero-extend (shift-right-zf's 0..2^32-1)
    | RFToI32 -- f64 word -> i32 (JS ToInt32: truncate toward zero), i32 result


type RawCmpOp
    = RCeq
    | RCne
    | RClts
    | RCles
    | RCgts
    | RCges


type RawFltBinOp
    = RFAdd
    | RFSub
    | RFMul
    | RFDiv


type RawFltCmpOp
    = RFLt
    | RFLe
    | RFGt
    | RFGe
    | RFEq
    | RFNe
