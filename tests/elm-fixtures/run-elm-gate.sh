#!/usr/bin/env bash
# run-elm-gate.sh — the Withe LANGUAGE gate (BATCH mode).
#
# For each fixture under tests/elm-fixtures, compiles it with the elm-compiler
# (node run.js -> .csexp), loads it into the ZINC VM via elmvm, runs the named
# function with the given args, and diffs the printed value against
# expected/<name>.txt.
#
# withe-split Phase 1: the 19 UI-host rows (16 pty + the pty_app todos row + the
# renderdump row + the lgstyled fixture) moved to run-ui-gate.sh, which is
# DEFERRED until the renderer is re-attached to the host effect loop.  This
# script is now the LANGUAGE gate: the corpus/typing rows + the 29 lambda-lift
# rows, run against a renderer-free elmvm.
#
# Since S8 the compile step is BATCHED: the fixed corpus (Prelude + Runtime +
# the eight core-libs) is parsed+typechecked+lowered ONCE, and every fixture
# group is compiled in the SAME node run.js process against the cached corpus.
# The script declares all fixtures up front (registering each (sources, output)
# group + its post-compile check), calls run.js ONCE with a batch manifest, then
# runs the elmvm/diff checks in declaration order — the PASS/FAIL output and
# counts are byte-identical to the pre-batch runner.
#
# Usage:
#   tests/elm-fixtures/run-elm-gate.sh [elmvm-binary] [elm-compiler-dir] [fixtures-dir]
#
# Defaults assume you are running from the fx-ui repo root:
#   elmvm    -> zig-out/bin/elmvm   (built via `zig build elmvm`)
#   compiler -> elm-compiler/       (compiler.js built via build.sh)
#   fixtures -> tests/elm-fixtures
#
# NOTE: M6's iofile fixture resolves input/hello.txt and out/hello.out RELATIVE
# TO THE PROCESS CWD (the stream prims take plain paths), so the gate MUST be
# started from the repo root.
#
# Exit code 0 iff every check passes.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ELMVM="${1:-$ROOT/zig-out/bin/elmvm}"
CDIR="${2:-$ROOT/elm-compiler}"
FIX="${3:-$ROOT/tests/elm-fixtures}"
OUT="$(mktemp -d)"

if [ ! -x "$ELMVM" ]; then
  echo "error: elmvm not found at $ELMVM (run: zig build elmvm)" >&2
  exit 2
fi
if [ ! -f "$CDIR/compiler.js" ]; then
  echo "error: $CDIR/compiler.js missing (run: build.sh)" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required to build the batch manifest" >&2
  exit 2
fi

pass=0; fail=0

# Derive a fixture's Elm MODULE NAME by scanning its `module X ...` header.
module_name() {
  awk '/^module /{print $2; exit}' "$1"
}

# read_expected <name> -> trims the trailing newline
read_expected() { cat "$FIX/expected/$1.txt"; }

# ============================ PHASE 1: declare ============================
# Every fixture call registers (a) its compile GROUP (user source file(s) +
# output .csexp) and (b) its post-compile CHECK.  Nothing compiles or runs
# elmvm yet; the checks fire in declaration order after the one batch compile.

ngroup=0; ncheck=0
declare -a GOUT GSRC
declare -a CKIND CNAME CFN CEXP CARG CSTDIN CFIX COUT

register_group() {
  local out="$1"; shift
  GOUT[$ngroup]="$out"
  GSRC[$ngroup]="$*"
  ngroup=$((ngroup+1))
}

add_check() {
  CKIND[$ncheck]="$1"; CNAME[$ncheck]="$2"; CFN[$ncheck]="$3"
  CEXP[$ncheck]="$4"; CARG[$ncheck]="$5"; CSTDIN[$ncheck]="$6"
  CFIX[$ncheck]="$7"; COUT[$ncheck]="$8"
  ncheck=$((ncheck+1))
}

# run <name> <fn> <expected> [args...]
#
# Entry resolution: since M3 keys defuns under QUALIFIED names ("<Mod>.<fn>",
# e.g. "Fib.fib"), the runner first calls "<Mod>.<fn>" with the module name
# scanned from the fixture header; bundles from older-style/anonymous content
# still fall back to the bare name.
run() {
  local name="$1" fn="$2" exp="$3"; shift 3
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check run "$name" "$fn" "$exp" "$*" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# run2 <name> <auxname> <fn> <expected>: multi-module fixture — compile
# <aux>.elm TOGETHER WITH <name>.elm (cross-module import); entry is looked
# up under "<NameModule>.<fn>" scanned from the MAIN fixture header.
run2() {
  local name="$1" aux="$2" fn="$3" exp="$4"; shift 4
  register_group "$OUT/$name.csexp" "$FIX/$aux.elm" "$FIX/$name.elm"
  add_check run2 "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# run_io <name> <fn> <expected> <stdin-file>
#
# Like run(), but elmvm's stdin is redirected from "$FIX/input/<stdin-file>"
# instead of being inherited — the M6 stream-prims fixtures (Cmd.readLine via
# read-byte on fd 0) consume stdin.  Still checks the printed FINAL MODEL.
run_io() {
  local name="$1" fn="$2" exp="$3" stdin="$4"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check io "$name" "$fn" "$exp" "" "$stdin" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# compile_clean <name>: asserts compilation SUCCEEDS (the artifact is a real
# bundle, not an "err ..." payload) but does not run it through the value
# gate — for fixtures whose value cannot be driven from argv (e.g. functions
# taking record arguments).
compile_clean() {
  local name="$1"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check ok "$name" "" "" "" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# compile_error <name> <expected-substring>: asserts compilation emits
# "err <message>" and that <message> contains the expected substring.  Used for
# fixtures that must FAIL to compile (duplicate/unknown names, etc.) rather than
# run through the value gate.
compile_error() {
  local name="$1" exp="$2"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check err "$name" "" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# out_cmp <name>: compare the raw file an elmvm run wrote (iofile's hello.out)
# against its expected bytes.
out_cmp() {
  add_check cmp "$1" "" "" "" "" "" ""
}

# rawrun <name> <fn> <expected>: run elmvm on a CHECKED-IN bundle (not compiled
# here) — for hand-crafted bundles no Elm source can produce (the synthetic
# unknown-Task tag, unhandledtask).  $FIX/$name.csexp is a committed .csexp.
rawrun() {
  local name="$1" fn="$2" exp="$3"
  add_check rawrun "$name" "$fn" "$exp" "" "" "$FIX/$name.csexp" "$FIX/$name.csexp"
}

run fib        fib        "$(read_expected fib)"        10
run rtl1       main       "$(read_expected rtl1)"
run rtl2       main       "$(read_expected rtl2)"
run sub        sub        "$(read_expected sub)"        10 3
run sub        sub        "-7"                           3 10
run div        main       "$(read_expected div)"
run nested     main       "$(read_expected nested)"
run closure    main       "$(read_expected closure)"
# --- S2.5 lex-frame (let/endlet core) fixtures: off-by-one env height, .cur
# reconstruction of a let-bound capture, and deep non-tail recursion from a
# let-body (depth-guard fallback). ---
run letread     main       "$(read_expected letread)"
run letclosure  main       "$(read_expected letclosure)"
run letdeeprec  main       "$(read_expected letdeeprec)"
# Self-tail INSIDE a lex frame: rebuilds lex[] in place at the tail, the path
# that carries the whole lex[] win (the hot list loops are self-tail recursive).
run lexselftail main       "$(read_expected lexselftail)"
run applytwice main       "$(read_expected applytwice)"
run countdown  countdown  "$(read_expected countdown)"  100000
run eqlist     main       "$(read_expected eqlist)"
run const      answer     "$(read_expected const)"
run partial    main       "$(read_expected partial)"
run subpartial main       "$(read_expected subpartial)"
run overapply  main       "$(read_expected overapply)"
run curry      main       "$(read_expected curry)"
run opvalue    main       "$(read_expected opvalue)"
run crossref   main       "$(read_expected crossref)"
run selfqual   main       "$(read_expected selfqual)"
# --- M2: case/pattern compiler, ADTs, records, short-circuit ---
run listcase    main       "$(read_expected listcase)"
run adteval     main       "$(read_expected adteval)"
run adtcase     main       "$(read_expected adtcase)"
run letcase     main       "$(read_expected letcase)"
run countcase   main       "$(read_expected countcase)"
run patterns    main       "$(read_expected patterns)"
run boolcase    main       "$(read_expected boolcase)"
run records     main       "$(read_expected records)"
run shortcircuit main      "$(read_expected shortcircuit)"
# --- M3: prelude (List API over 1000 elems), strings, multi-module ---
run biglist    main       "$(read_expected biglist)"
run strings    main       "$(read_expected strings)"
run2 multimod  auxlib     main       "$(read_expected multimod)"
# --- M4: floats ---
run floatlit     main  "$(read_expected floatlit)"
run floatarith   main  "$(read_expected floatarith)"
run floatdiv     main  "$(read_expected floatdiv)"
run floatmix     main  "$(read_expected floatmix)"
run floatcmp     main  "$(read_expected floatcmp)"
run floatfun     area  "$(read_expected floatfun)"     2.0
run floatpartial main  "$(read_expected floatpartial)"
run floatineq    main  "$(read_expected floatineq)"
# --- MX: terminal pure-core composed programs (main : Int / String) ---
run mxint     main   "$(read_expected mxint)"
run mxstring  main   "$(read_expected mxstring)"
# --- M6: I/O effects runtime (self-hosted Platform; stream prims) ---
# iofile: RdFile round-trip — the final String model is printed (printValue
# wraps it in quotes) AND the raw file is written to out/hello.out.
run_io iofile  main   "$(read_expected iofile)" hello.txt
out_cmp iofile
# ioecho: readLine echo-until-quit — echoed lines + the final Int count.
run_io ioecho  main   "$(read_expected ioecho)" echo.txt
# --- M7: async Kernel (Task monad + effect-manager loop) ---
run taskpure     main   "$(read_expected taskpure)"
run taskseq      main   "$(read_expected taskseq)"
run taskattempt  main   "$(read_expected taskattempt)"
# --- M8: process execution (exec-plan + env/cwd prims) ---
run execpipe     main   "$(read_expected execpipe)"
run execenv      main   "$(read_expected execenv)"
run execglob     main   "$(read_expected execglob)"
# --- M9: TRUE nonblocking async (host event loop drives a Program) ---
run asyncorder   main   "$(read_expected asyncorder)"
run fastexec     main   "$(read_expected fastexec)"
run asyncpure    main   "$(read_expected asyncpure)"
compile_error dup          "duplicate top-level definition in Dup: f"
compile_error shadowerr    "is both a top-level definition and imported via"
compile_error shadowtyperr "is both a top-level definition and imported via"
compile_error ambimperr    "from two different modules"
# --- withe-split Phase 3: an unhandled effect fails LOUDLY and FAST ---
# unhandledtask is a hand-crafted bundle (no Elm source can produce an unknown
# Task ctor) whose Program spawns a Task tagged TaskBogus; the host must throw
# naming the ctor and TERMINATE, never hang or silently drop it.
rawrun unhandledtask main   "$(read_expected unhandledtask)"

run cmporder    main   "$(read_expected cmporder)"
run resultmaybe main   "$(read_expected resultmaybe)"
run dictbasic   main   "$(read_expected dictbasic)"
run setops      main   "$(read_expected setops)"
run dictstress  main   "$(read_expected dictstress)"

# --- elm/core Bitwise + Array port (vector JsArray substitute, RRB tree) ---
# bitwise: int32 semantics pins for the 7 zinc-vm prims (truncation, count
# &31 masking, arithmetic vs zero-fill right shift, doc examples).
run bitwise     main   "$(read_expected bitwise)"
# arraybasic: sizes 0/1/5/32/33/64/100 (first Leaf at 32) — length/foldl/get
# corners, set OOB no-op + persistence, push 31->33 crossing, roundtrips,
# map/indexedMap/filter, repeat, append, slice doc cases, toIndexedList/Tuple.
run arraybasic  main   "$(read_expected arraybasic)"
# arraystress: 1023/1024/1025 (depth-2->3 boundary at 32*32) + 1000 — sums,
# set-every-32nd, foldr order check, push 1023->1026, append, deep slices,
# fromList 1025 positional roundtrip, map/filter over 1024, persistence.
run arraystress main   "$(read_expected arraystress)"

# --- S1 (M-FOUNDATION): core-libs/Str.elm string toolkit + Prelude.List.take ---
# strunit: width (ANSI-skip + UTF-8 cell tables), split/lines/repeat/pad/
# truncate/replace/affixes/trim/countChar, List.take, trusted Str.fromFloat.
run strunit     main   "$(read_expected strunit)"
# p2pad: the P2-9 native Str.repeat prim (n=0/1/40, negative, empty) + the
# padLeft/padRight cell-width interplay that rides it.
run p2pad       main   "$(read_expected p2pad)"



# --- S3 (M-FOUNDATION): host TaskNow/Sleep/Quit leaves (monotonic time) ---
# nowunit: sleep 30 then now-diff >= 25 (CLOCK_MONOTONIC, not the wall-clock
# get-time prim) + a two-sleep ORDER chain (sequential sleeps take >= 40ms).
run nowunit     main   "$(read_expected nowunit)"

# --- S6 (M-FOUNDATION): host dir/stat leaves (getdents64 + fstatat) ---
# dirunit: Io.listDir over input/dirlist — '.'/'..' skipped, isDir from dirent
# d_type; RAW fs order re-sorted through Set for a deterministic join.
run dirunit     main   "$(read_expected dirunit)"
# statunit: Io.stat size + isDir/isFile + mode S_IFMT type bits (NOT mtime) +
# the zero-record failure parity for a missing path.
run statunit    main   "$(read_expected statunit)"



run rowpoly     main   "$(read_expected rowpoly)"
run extrec      main   "$(read_expected extrec)"
run insrec      main   "$(read_expected insrec)"
run remrec      main   "$(read_expected remrec)"
run scopedup    main   "$(read_expected scopedup)"
run recalias    main   "$(read_expected recalias)"
run appendres   main   "$(read_expected appendres)"
compile_error tyerr_update_missing_field "does not have field"
compile_error tyerr_ambiguous_append      "ambiguous"
compile_error tyerr_numstr                "unify number with String"
compile_error tyerr_arity                 "apply non-function"
compile_error tyerr_remove_absent         "does not have field"

# --- row-GADT branch-local refinement (handoff-rowgadt; the paper's crux) ---
# rowgadt_select: the row-membership witness — Here refines rho ~ {l:t|rho'},
# There refines rho ~ {k:s|rho}: conflicting global substitutions, so only
# branch-local capture + discharge types select. Must compile CLEAN.
compile_clean rowgadt_select
# rowgadt_setx: update under refinement — shape-preserving update returns the
# same open row, no equation escapes. Must compile CLEAN.
compile_clean rowgadt_setx
# NEGATIVE: selection of a field absent from the refined shape still errs.
compile_error rowgadt_absentfield          "is rigid"
# NEGATIVE: a refined equation needed to type the RESULT escapes its branch.
compile_error rowgadt_escape               "escaping row equation"
# --- result-side discharge for classic GADTs (handoff-rowgadt-4) ---
# rowgadt_eval: the canonical GADT evaluator — per-ctor TYPE refinements
# (a ~ Int / a ~ Bool / a ~ (a',b')) are discharged at each branch's result,
# branch-locally; the classic program must compile CLEAN. It is RUNNABLE
# (main constructs Pair/IntLit/BoolLit via the ARROW spelling and matches), so
# it is run through the VM, not just compiled — this is the fixture whose
# ctor-arity crash (`apply non-callable`) F4 found.
run rowgadt_eval main "$(read_expected rowgadt_eval)"
# NEGATIVE: the equation says a ~ Int but the body is a String — the
# discharge re-check (String vs Int) rejects it; must ERR.
compile_error rowgadt_evalbad              "escaping row equation"
# --- type witnesses / heterogeneous containers (handoff-rowgadt-6) ---
# rowgadt_het: a Witness GADT + existential wrapper + a LIST of two elements
# with DIFFERENT witness types, folded to String by matching each witness and
# using the payload at its recovered type. Must compile CLEAN; main constructs
# `Some` (ARROW spelling) so it is also run through the VM.
run rowgadt_het main "$(read_expected rowgadt_het)"
# NEGATIVE: a witness match does not let an existential payload escape at the
# wrong type — `bad : Any -> String` returning the payload must ERR (the rigid
# existential cannot be a String).
compile_error rowgadt_noescape             "is rigid"
# --- L3 principality boundary (MEASURED): which side infers a principal type ---
# (i) witness-encoded access, no signature: ACCEPTED (inferred Any -> String).
# main constructs `Some` (ARROW spelling), so it is also run through the VM.
run rowgadt_l3i main "$(read_expected rowgadt_l3i)"
# (ii) native-row select, no signature: REJECTED (Here/There row refinements
# conflict once rho is flexible — infinite type, needs the `type rho l t.` binder).
compile_error rowgadt_l3ii                 "cannot unify {k:a| b} with {| a}"
# (iii) plain row access, no signature: ACCEPTED (inferred { r | x : a } -> a).
run rowgadt_l3iii main "$(read_expected rowgadt_l3iii)"
# --- witness-encoded HList (handoff-rowgadt L2(b)): recursion over a nested ---
# --- existential row index — the last L2(b) blocker. ---
# rowgadt_hget: the HList-of-witness encoding; hget recurses over the tail,
# unifying the two tails of the SAME rigid rho. Must compile CLEAN.
compile_clean rowgadt_hget
# rowgadt_hget_bare: the SAME hget with a bare signature (no `type l t rho.`
# binder). Position-directed rigidity makes the GADT indices l/t/rho rigid
# regardless of the surface, so the bare form now checks identically.
compile_clean rowgadt_hget_bare
# NEGATIVE (n2): returning the HList TAIL at the full row type — the tail is a
# proper sub-row of the head, so the flexible tail aliasing the head is the
# refinement escaping its branch. Must ERR 'escaping row equation'.
compile_error rowgadt_hget_escape        "escaping row equation"
# NEGATIVE (n3): a body of the wrong type must not slip out through the
# recursive tail unification. Must ERR ('is rigid ... String').
compile_error rowgadt_hget_badhead       "is rigid"
# NEGATIVE (n4): the tail laundered through a `let`-bound intermediate (the
# escapeViaTail let-generalization hole, closed 2026-10-05). Must ERR.
compile_error rowgadt_escape_launder     "escaping row equation"
# NEGATIVE (n5): the tail returned in one branch while a wildcard returns the
# full row (the shared-resultVar sibling leak, closed 2026-10-05). Must ERR.
compile_error rowgadt_escape_wildcard    "escaping row equation"
# NEGATIVE (CE-1, dropIntroduced scoping bypass): the body pre-aliases the tail
# to the head BEFORE the result unify, so the escape must fire on the
# branch-entry/post-pattern baseline, not only on what the result unify
# introduced. Must ERR 'escaping row equation'.
compile_error rowgadt_ce1_prealias       "escaping row equation"
# POSITIVE (domain-preserving REBUILD): the Here branch returns the scrutinee
# REBUILT (HCons x rest : HList {l:t|rho'}), whose row domain equals the head's
# under the equation — the DOMAIN-based escape rule accepts it (the syntactic
# tail-occurrence check used to false-reject it). Must compile CLEAN.
compile_clean rowgadt_shape_rebuild
# H1 DUPLICATE-LABEL probes (handoff-rowgadt plan Step 5): a duplicate label
# UNDER an active branch-local refinement. (a) a full-duplicate rebuild is
# accepted — proves the rebuild arm handles duplicate equation bodies; (b) a
# rebuild with FEWER duplicate occurrences is REJECTED — the KNOWN false reject
# (an incompleteness of the duplicate check, not a soundness requirement).
compile_clean rowgadt_dup_rebuild
compile_error rowgadt_dup_fewer    "cannot unify a with {x:Int|"
# G4 external example (discuss.ocaml.org t/13718 FSM pattern): a door machine
# with a row-typed state and a GADT witness for the transition relation. (a)
# the full program compiles clean — the transition witness rejects illegal
# transitions and the reducers read state-specific fields under branch-local
# row refinement; (b) the NEGATIVE: an illegal transition (Open departing the
# Locked state) is rejected at construction; (c) the NARROWING NEGATIVE: a
# wrong-field read in one branch (Close reading rec.broken, whose from-row is
# { open : Int }) errs — the per-branch field narrowing that OCaml's per-field
# workaround cannot do, pinned as a negative rather than asserted.
run rowgadt_fsm main "$(read_expected rowgadt_fsm)"
compile_error rowgadt_fsm_bad      "missing field closed"
compile_error rowgadt_fsm_narrow   "cannot be unified with {broken:a| b}"
# G4 nested form (the source's ACTUAL match shape): the Event ctor nested inside
# the Then pattern, with the per-state narrowing happening at the NESTED level.
# (a) compiles clean — the nested event's arrival state narrows the chain's
# current-state row branch-locally; (b) the NEGATIVE: a nested branch reading a
# field its refinement does not expose still errs.
run rowgadt_fsm_nested main "$(read_expected rowgadt_fsm_nested)"
compile_error rowgadt_fsm_nested_bad  "cannot be unified with {broken:a| b}"

# ==================== EXHAUSTIVENESS + REFUTATION (Parts A/B) ====================
# Part A pin: a `case` omitting a POSSIBLE arm used to compile clean and raise
# `non-exhaustive case` at runtime; it must now ERROR at compile time.
compile_error adtgaps                 "non-exhaustive case"
# Part B pin (refutation NEGATIVE): `HNil : HList {}` is POSSIBLE at an OPEN
# `HList rho` (rho may be {}), so a `case` matching only HCons must NOT refute
# HNil — the absence of HNil is still a coverage gap.
compile_error refutneg                "non-exhaustive case"
# Part B pin (refutation POSITIVE): `BoolLit : Bool -> Expr Bool` is IMPOSSIBLE
# at the scrutinee index `Expr Int` (Int ~ Bool cannot hold), so a case matching
# only IntLit must COMPILE CLEAN — the impossible arm is refuted, not required.
# main constructs `IntLit` (ARROW spelling), so it is also run through the VM.
run refutpos main "$(read_expected refutpos)"
# Part B pin (refutation NEGATIVE at a BARE index): `f : Tag a -> Int` with a
# bare (flexible) `a` matching only `A` is PARTIAL — `B` is possible at
# `Tag String`. The check must NOT refute `B` against the clause's concrete
# `Tag Int`; it must ERROR "missing B" exactly as the `type a.` binder form does.
compile_error refutbare               "non-exhaustive case"
# CE-2 (bare-variable scrutinee over-generalisation, GADT form): `f x = case x
# of A -> 1` with NO signature must NOT generalise to `forall a. a -> Int`. The
# lift is skipped for a bare scrutinee, so `x` binds to `Tag Int` and `f B` is a
# COMPILE-TIME type error (was: compiles clean, crashes at runtime).
compile_error rowgadt_ce2_barevar     "cannot unify Int with String"
# CE-2 (plain-ADT form — NOT GADT-specific): `eval` must bind to `Expr -> Int`,
# so `eval "hello"` is a compile-time type error, not a runtime crash.
compile_error rowgadt_ce2_plain       "cannot unify RowgadtCe2Plain.Expr with String"
# CE-3 (field-vs-index conflation): a GADT whose index WRAPS its field
# (`MkBox : a -> Box (List a)`) and a function returning the FIELD at the INDEX
# type. The body's bare `v : a` aliased the rigid index and dropped the equation
# `a ~ List a`, so `get (MkBox 3)` was accepted at `List Int` while its value is
# `3`. The result unify must reject the flex -> rigid alias of a variable to a
# refined target.
compile_error rowgadt_ce3_fieldalias  "type variable a is rigid"
# CE-3 class (equation lifecycle): the field-vs-index conflation's three
# runtime-confirmed bypasses — the flex -> rigid alias forms under a tuple
# (a), before the result unify via a pre-alias (b), or through a let-binding
# (c). Each must ERROR 'infinite type' (the equation a ~ List a is refuting),
# not compile clean and produce a wrong-typed value at runtime.
compile_error rowgadt_ce3a_tuple     "infinite type"
compile_error rowgadt_ce3b_prealias  "infinite type"
compile_error rowgadt_ce3c_let       "infinite type"

# --- S8 (lambda lifting): self-/mutually-recursive LOCAL let groups ---
# The lift hoists each recursive local group to the top level with captures
# threaded as leading params; these four fixtures pin the shapes: (a) a
# self-recursive helper with a capture (accumulator fold), (b) a MUTUALLY
# recursive pair in one let, (c) a recursive helper used FIRST-CLASS, and (d)
# a helper whose body SHADOWS a capture's name (the capture-set probe).
run liftself        main   "$(read_expected liftself)"
run liftmutual      main   "$(read_expected liftmutual)"
run liftfirstclass  main   "$(read_expected liftfirstclass)"
run liftshadow      main   "$(read_expected liftshadow)"
# --- S8 review follow-up: cycle-component lift + sequential rewrite ---
# BLOCKER 2 (forward reference is not recursion): a no-cycle forward ref to a
# later sibling stays sequential; and a mixed group lifts ONLY the recursive
# member.  BLOCKER 1 (sequential binder threading): nested value / tuple-
# destructuring / final-expr siblings that shadow a capture are seen by later
# siblings; plus a control that a genuinely mutual group still lifts.
run liftfwd         main   "$(read_expected liftfwd)"
run liftfwdmix      main   "$(read_expected liftfwdmix)"
run liftnested      main   "$(read_expected liftnested)"
run liftnestedtuple main   "$(read_expected liftnestedtuple)"
run liftnestedfinal main   "$(read_expected liftnestedfinal)"
run liftnestedrec   main   "$(read_expected liftnestedrec)"
# --- S8 review #2 follow-up: sequential walk + name-collision policy ---
# DEFECT B: the walk side's free-variable computation is sequential, so a
# capture referenced before a same-named nested value sibling is not masked.
# FIXTURE GAP: a forward-ref shape whose later sibling also references the
# earlier one pins the bound-filter (a regression fabricates a cycle h <-> x).
# NAME-COLLISION (Elm shadowing, user decision 2026-10-06): a local recursive
# helper whose name collides with a top-level (liftdelegate/liftdelegmut) or
# Prelude (liftprelude) binding is LIFTED -- the local shadows the module
# binding.  liftenclosing pins the KEPT exception: a name bound by an ENCLOSING
# parameter keeps the substrate's SEQUENTIAL priority (the self-reference
# resolves to the parameter, so the group is not lifted).
run liftdelegate    main   "$(read_expected liftdelegate)"
run liftdelegmut    main   "$(read_expected liftdelegmut)"
run liftprelude     main   "$(read_expected liftprelude)"
run liftenclosing   main   "$(read_expected liftenclosing)"
run liftseqcap      main   "$(read_expected liftseqcap)"
run liftfwdback     main   "$(read_expected liftfwdback)"
# --- S8 structural rewrite (positional/snapshot model) ---
# The four pre-rewrite blockers, each cut to a minimal fixture: a source name
# denoting two bindings at two member positions (liftcapconfl / liftcapconfl2,
# the destructuring variant), a forward reference to a module-named sibling
# (liftmodfwd -- keeps HEAD's sequential 999, NOT true Elm's 5000) and a
# forward reference to a Prelude-named sibling (liftpreludefwd).  The last four
# no longer lift at all and must stay LOUD: a cyclic VALUE (liftvaluecycle) and
# the ordering refusal (liftrefuse) are 'unknown name' compile errors, while
# liftstaycall (a staying value sibling calling a lifted member whose snapshots
# all precede it) and liftdisjoint (two disjoint cycles in one block) must run.
run liftcapconfl    main   "$(read_expected liftcapconfl)"
run liftcapconfl2   main   "$(read_expected liftcapconfl2)"
run liftmodfwd      main   "$(read_expected liftmodfwd)"
run liftpreludefwd  main   "$(read_expected liftpreludefwd)"
run liftprelfwdfn   main   "$(read_expected liftprelfwdfn)"
run liftstaycall    main   "$(read_expected liftstaycall)"
run liftdisjoint    main   "$(read_expected liftdisjoint)"
compile_error liftvaluecycle "unknown name: v"
compile_error liftrefuse     "unknown name: a"
# --- S8 round 5: one resolution procedure + a cycle-scoped shadowing census ---
# liftstayfwd pins DEFECT 1: a STAYING declaration's forward reference to a
# module-named sibling keeps the MODULE binding (the staying rewrite must use
# the positional resolver, not a name-keyed one).  liftcycshadows pins DEFECT 2:
# the shadowing census covers the recursive CYCLE, so an unrelated value sibling
# cannot flip a shadowing mutual pair back to the sequential reading.
run liftstayfwd     main   "$(read_expected liftstayfwd)"
run liftcycshadows  main   "$(read_expected liftcycshadows)"
# --- S8 round 6: per-SCC shadowing census + target-scoped forward veto ---
# liftrelaxleak pins BLOCKER B (relaxation over-reach): a cycle member's forward
# reference to a NON-cycle module-named sibling must stay the MODULE binding
# (999), not leak to the local sibling (555).  liftdisjointshadow pins BLOCKER A
# (census union-of-cycles): an unrelated non-shadowing disjoint cycle must not
# flip a fully-shadowing cycle's ratified answer (even 4 stays 0, so 0 + 3 = 3).
run liftrelaxleak    main   "$(read_expected liftrelaxleak)"
run liftdisjointshadow main "$(read_expected liftdisjointshadow)"

# ============================ PHASE 2: batch compile ============================
# Build the manifest {groups:[{sources:[...],output:"..."}]} and run.js ONCE.
: > "$OUT/groups.jsonl"
for ((i=0;i<ngroup;i++)); do
  read -r -a srcs <<< "${GSRC[$i]}"
  jq -n --arg out "${GOUT[$i]}" \
        --argjson srcs "$(printf '%s\n' "${srcs[@]}" | jq -R . | jq -s .)" \
        '{sources: $srcs, output: $out}' >> "$OUT/groups.jsonl"
done
jq -s '{groups: .}' "$OUT/groups.jsonl" > "$OUT/manifest.json"

# ELM_GATE_MANIFEST_ONLY=1: stop after building the manifest (debugging / the
# byte-identical bundle diff) — print its path and leave $OUT in place.
if [ "${ELM_GATE_MANIFEST_ONLY:-0}" = "1" ]; then
  echo "$OUT/manifest.json"
  exit 0
fi

node "$CDIR/run.js" --batch "$OUT/manifest.json" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "FAIL: node run.js --batch failed" >&2
  rm -rf "$OUT"
  exit 1
fi

# ============================ PHASE 3: checks ============================
dispatch() {
  local kind="$1" i="$2"
  local name fn exp args stdin fixfile outfile mod qname got out
  name="${CNAME[$i]}"; fn="${CFN[$i]}"; exp="${CEXP[$i]}"
  args="${CARG[$i]}"; stdin="${CSTDIN[$i]}"; fixfile="${CFIX[$i]}"; outfile="${COUT[$i]}"
  case "$kind" in
    cmp)
      if cmp -s "$FIX/out/hello.out" "$FIX/expected/hello.out.txt"; then
        echo "PASS iofile out-file cmp"; pass=$((pass+1))
      else
        echo "FAIL iofile out-file cmp: out/hello.out != expected/hello.out.txt"; fail=$((fail+1))
      fi
      ;;
    ok)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1))
      else
        echo "PASS $name (compiles clean)"; pass=$((pass+1))
      fi
      ;;
    err)
      out=$(cat "$outfile")
      case "$out" in
        err*"$exp"*) echo "PASS $name: $out"; pass=$((pass+1));;
        *) echo "FAIL $name: expected err containing [$exp], got [$out]"; fail=$((fail+1));;
      esac
      ;;
    run2)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      got=$("$ELMVM" "$outfile" "$mod.$fn" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($mod.$fn multi) -> $got"; pass=$((pass+1))
      else
        echo "FAIL $name ($mod.$fn multi): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    io)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$ELMVM" "$outfile" "$qname" < "$FIX/input/$stdin" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($qname < input/$stdin) -> $(echo "$got" | tail -1)"; pass=$((pass+1))
      else
        echo "FAIL $name ($qname < input/$stdin): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    run)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$ELMVM" "$outfile" "$qname" $args 2>&1)
      if [ "$got" != "unknown global: $qname" ] && [ "$got" != "unknown name: $qname" ]; then
        if [ "$got" = "$exp" ]; then
          echo "PASS $name ($qname $args) -> $got"; pass=$((pass+1))
        else
          echo "FAIL $name ($qname $args): exp[$exp] got[$got]"; fail=$((fail+1))
        fi
        return
      fi
      # fallback to the bare fn name (legacy single-module bundles)
      got=$("$ELMVM" "$outfile" "$fn" $args 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($fn $args) -> $got"; pass=$((pass+1))
      else
        echo "FAIL $name ($fn $args): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    rawrun)
      got=$("$ELMVM" "$fixfile" "$fn" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name (raw bundle $fn)"; pass=$((pass+1))
      else
        echo "FAIL $name (raw bundle $fn): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
  esac
}

for ((i=0;i<ncheck;i++)); do
  dispatch "${CKIND[$i]}" "$i"
done

rm -rf "$OUT"
echo "=============================="
echo "PASS=$pass FAIL=$fail"
exit $((fail>0?1:0))
