#!/usr/bin/env bash
# run-elm-gate.sh — the Osier LANGUAGE gate (BATCH mode).
#
# For each fixture under tests/elm-fixtures, compiles it with the elm-compiler
# (node run.js -> .csexp), loads it into the ZINC VM via elmvm, runs the named
# function with the given args, and diffs the printed value against
# expected/<name>.txt.
#
# osier split Phase 1: the 19 UI-host rows (16 pty + the pty_app todos row + the
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
# Every check this script REGISTERS is listed, generated from the registration
# calls below, in tests/elm-fixtures/MATRIX.md
# (regenerate/verify: tools/gen-fixture-matrix.sh [--check]; raw dump:
# ELM_GATE_MATRIX=1 tests/elm-fixtures/run-elm-gate.sh).
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

# ELM_GATE_MATRIX=1 (or a path) dumps the REGISTERED check matrix and stops
# BEFORE any build/compile step (tools/gen-fixture-matrix.sh uses it), so the
# elmvm / compiler.js / jq prerequisites are not required in that mode.
if [ "${ELM_GATE_MATRIX:-0}" != "0" ]; then
  : # matrix dump mode: no elmvm / compiler.js / jq required (see the dump below)
elif [ ! -x "$ELMVM" ]; then
  echo "error: elmvm not found at $ELMVM (run: zig build elmvm)" >&2
  exit 2
elif [ ! -f "$CDIR/compiler.js" ]; then
  echo "error: $CDIR/compiler.js missing (run: build.sh)" >&2
  exit 2
elif ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required to build the batch manifest" >&2
  exit 2
elif [ ! -x "$ROOT/vendor/qbe/qbe" ]; then
  echo "error: vendored qbe missing at $ROOT/vendor/qbe/qbe (the natdepth check builds natively)" >&2
  exit 2
elif ! command -v cc >/dev/null 2>&1; then
  echo "error: cc required to link the natdepth check's native binary" >&2
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
declare -a CKIND CNAME CFN CEXP CARG CSTDIN CFIX COUT CHLP

register_group() {
  local out="$1"; shift
  GOUT[$ngroup]="$out"
  GSRC[$ngroup]="$*"
  ngroup=$((ngroup+1))
}

# add_check <kind> <name> <fn> <expected> <args> <stdin> <fixture> <out> <helper>
# $9 is the REGISTERING HELPER's name (run / compile_error / ...) — printed by
# the ELM_GATE_MATRIX dump so the matrix names the check the way a reader of
# this file does.  The dispatcher keys on $1 only.
add_check() {
  CKIND[$ncheck]="$1"; CNAME[$ncheck]="$2"; CFN[$ncheck]="$3"
  CEXP[$ncheck]="$4"; CARG[$ncheck]="$5"; CSTDIN[$ncheck]="$6"
  CFIX[$ncheck]="$7"; COUT[$ncheck]="$8"; CHLP[$ncheck]="$9"
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
  add_check run "$name" "$fn" "$exp" "$*" "" "$FIX/$name.elm" "$OUT/$name.csexp" run
}

# run2 <name> <auxname> <fn> <expected>: multi-module fixture — compile
# <aux>.elm TOGETHER WITH <name>.elm (cross-module import); entry is looked
# up under "<NameModule>.<fn>" scanned from the MAIN fixture header.
run2() {
  local name="$1" aux="$2" fn="$3" exp="$4"; shift 4
  register_group "$OUT/$name.csexp" "$FIX/$aux.elm" "$FIX/$name.elm"
  add_check run2 "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp" run2
}

# run_io <name> <fn> <expected> <stdin-file>
#
# Like run(), but elmvm's stdin is redirected from "$FIX/input/<stdin-file>"
# instead of being inherited — the M6 stream-prims fixtures (Cmd.readLine via
# read-byte on fd 0) consume stdin.  Still checks the printed FINAL MODEL.
run_io() {
  local name="$1" fn="$2" exp="$3" stdin="$4"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check io "$name" "$fn" "$exp" "" "$stdin" "$FIX/$name.elm" "$OUT/$name.csexp" run_io
}

# compile_clean <name>: asserts compilation SUCCEEDS (the artifact is a real
# bundle, not an "err ..." payload) but does not run it through the value
# gate — for fixtures whose value cannot be driven from argv (e.g. functions
# taking record arguments).
compile_clean() {
  local name="$1"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check ok "$name" "" "" "" "" "$FIX/$name.elm" "$OUT/$name.csexp" compile_clean
}

# compile_error <name> <expected-substring>: asserts compilation emits
# "err <message>" and that <message> contains the expected substring.  Used for
# fixtures that must FAIL to compile (duplicate/unknown names, etc.) rather than
# run through the value gate.
compile_error() {
  local name="$1" exp="$2"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check err "$name" "" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp" compile_error
}

# out_cmp <name>: compare the raw file an elmvm run wrote (iofile's hello.out)
# against its expected bytes.
out_cmp() {
  add_check cmp "$1" "" "" "" "" "" "" out_cmp
}

# rawrun <name> <fn> <expected>: run elmvm on a CHECKED-IN bundle (not compiled
# here) — for hand-crafted bundles no Elm source can produce (the synthetic
# unknown-Task tag, unhandledtask).  $FIX/$name.csexp is a committed .csexp.
rawrun() {
  local name="$1" fn="$2" exp="$3"
  add_check rawrun "$name" "$fn" "$exp" "" "" "$FIX/$name.csexp" "$FIX/$name.csexp" rawrun
}

# sigdeath <name> <fn> <expected>
#
# THE SIGNAL-DEATH CHECK (osier-rtsplit follow-up).  waitStatusCode's SIGNAL
# ARM (vendor/osier-rt/src/rt/execplan.zig:904-906, `if WIFEXITED -> EXITSTATUS;
# else 128 + (st & 0x7f)`) translates a child reaped WIFSIGNALED into 128+signum.
# Its only test was the deleted `wait/kill` prim test, and the arm SURVIVES on
# two live paths: execplan.zig's runPipeline (:970 the fork/waitpid path, :1092
# the pipeline reap) and src/effectloop.zig's reapChildren (:1042) /
# reapBlocking (:1073), the M9 event loop.  The two
# fixtures cover those two call sites — signaldeath.elm (Platform.worker ->
# synchronous) and signaldeathasync.elm (Platform.program -> effect loop) —
# and both expect 137: their plan is `sh -c 'kill -9 $$'`, so the child dies
# by SIGKILL, the status WORD is 9, and the arm must answer 128+9.
#
# WHY THE EXPECTED VALUE DISCRIMINATES: a decoder with the signal arm dropped
# answers EXITSTATUS(9) = (9 >> 8) & 0xff = 0, so it prints "0||" and cannot
# produce "137||".  That asymmetry was MEASURED, not assumed: waitStatusCode
# was mutated to the exit-only form in a scratch copy of the tree, and both
# rows failed there ("exp[137||] got[0||]") while the unmutated tree passes —
# which also rules the fixtures out as vacuous, because a child that exited
# NORMALLY with code 137 would have kept passing under the mutation.
#
# Registered WITHOUT a compile group, like `depth`/`natdepth`:
# tools/osier-corpus-baseline.sha256 pins the batch's artifact set
# (149 artifacts = 149 manifest entries), so these rows compile their bundle on
# demand instead (one extra node process each, ~0.4s).
sigdeath() {
  local name="$1" fn="$2" exp="$3"
  add_check sigdeath "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "" sigdeath
}

# depth <name> <fn> <control-depth> <past-cap-margin> <expected-control-value>
#
# THE OUT-OF-FRAMES CHECK (handoff osier-vmdepth).  `run`/`rawrun` compare
# stdout text and cannot see an EXIT STATUS, which is the whole point here: the
# VM's call-frame stack (CALL_STACK_DEPTH, vendor/osier-rt/src/gc/types.zig) used
# to run out SILENTLY — exit 0, empty stderr, and whatever `acc` held printed as
# the answer.  A user must never get a wrong answer with a success status, so
# this check asserts on the process instead of on the value:
#
#   1. CONTROL — <fn> at <control-depth> (a legal depth, far below the cap):
#      must print <expected-control-value> AND exit 0.  Same source, same
#      shape, only the depth differs, so the failure below can only be the cap.
#   2. NEAR-CAP — <fn> at CALL_STACK_DEPTH-1 (the LAST usable frame): must
#      still print the correct sum.  This is the half that keeps the check from
#      "fixing" the defect by refusing work it should do, and it fails loudly
#      if a change to the entry path ever moves the boundary.
#   3. PAST-CAP — <fn> at CALL_STACK_DEPTH + <past-cap-margin>: must exit
#      NON-ZERO with the named diagnostic on stderr ($DEPTH_MSG), and must not
#      print a value on stdout.
#
# CALL_STACK_DEPTH is READ FROM THE SOURCE here (not baked in), so raising the
# cap cannot silently turn this check into a no-op — the probe follows it.
#
# It is registered WITHOUT a compile group: tools/osier-corpus-baseline.sha256
# pins the batch's artifact set, so this fixture is compiled on demand instead
# (one extra node process, ~0.4s).  It runs at $DEPTH_HEAP_MB because the frame
# cap has to be reached BEFORE the heap runs out — at elmvm's default 64MB heap
# this probe aborts in grow_heap instead, which is a DIFFERENT failure and would
# make the row pass vacuously.
depth() {
  local name="$1" fn="$2" ctl="$3" margin="$4" exp="$5"
  add_check depth "$name" "$fn" "$exp" "$ctl $margin" "" "$FIX/$name.elm" "$OUT/$name.depth.csexp" depth
}

# natdepth <name> <fn> <control-depth> <past-depth> <deep-depth> <expected-control-value>
#
# THE NATIVE OUT-OF-STACK CHECK (handoff osier-natdepth) — the native twin of
# `depth` above, and the arm that SURVIVES the interpreter's retirement: the
# VM check asserts the interpreter's CALL_STACK_DEPTH cap; this one asserts
# the QBE native path's OWN resource boundary, the C stack.  Before the guard
# (tools/qbe/rt.zig), a non-tail recursion deep enough to exhaust
# RLIMIT_STACK died with a BARE SIGSEGV — non-zero, so never a silent wrong
# answer, but unnamed and unassertable.  The guard installs sigaltstack + a
# SIGSEGV handler that recognises a stack-exhaustion fault and exits 1 with
# the NAT_DEPTH_MSG diagnostic; this check pins that property.
#
# Like `depth` it registers NO compile group (the corpus baseline pins the
# batch artifact set): it builds its own native binary on demand via
# tools/qbe/qbe-mk.sh.  And because the native boundary is a BYTE budget,
# not a frame count, the check OWNS the budget instead of reading a constant:
# every budgeted arm runs with QBE_NO_RLIMIT=1 (the driver's 64 MiB raise
# suppressed) under its own `ulimit -s 1024` — a 1 MiB stack under which the
# boundary sits near 3.8k levels (256 B/level, MEASURED; see
# docs/qbe-backend.md), so <control-depth> (1000) is comfortably inside and
# <past-depth> (20000) far beyond, whatever small drift the per-level stride
# later takes.
natdepth() {
  local name="$1" fn="$2" ctl="$3" past="$4" deep="$5" exp="$6"
  add_check natdepth "$name" "$fn" "$exp" "$ctl $past $deep" "" "$FIX/$name.elm" "$OUT/$name.nat.ssa" natdepth
}

# The named diagnostic the VM must print when it runs out of call frames —
# asserted verbatim (see vendor/zinc-vm/src/vm/interp.zig, the CALL_STACK_DEPTH
# guard) so the check cannot be satisfied by an unrelated abort.
DEPTH_MSG="call stack depth exceeded"
DEPTH_HEAP_MB=1024

# The named diagnostic the QBE NATIVE runtime prints when the C stack is
# exhausted (tools/qbe/rt.zig's stack-depth guard: sigaltstack + a SIGSEGV
# handler that recognises a stack-exhaustion fault).  Deliberately distinct
# from DEPTH_MSG ("native" vs "call") so neither arm's grep can match the
# other backend's message.
NAT_DEPTH_MSG="native stack depth exceeded"

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
# --- osier-rtsplit follow-up: a child that dies BY SIGNAL is 128+sig ---
# The two call sites of waitStatusCode's signal arm (see the sigdeath helper):
# the synchronous runner and the M9 effect-loop reap.
sigdeath signaldeath      main "$(read_expected signaldeath)"
sigdeath signaldeathasync main "$(read_expected signaldeathasync)"
compile_error dup          "duplicate top-level definition in Dup: f"
compile_error shadowerr    "is both a top-level definition and imported via"
compile_error shadowtyperr "is both a top-level definition and imported via"
compile_error ambimperr    "from two different modules"
# --- osier split Phase 3: an unhandled effect fails LOUDLY and FAST ---
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

# --- osier-vmdepth: running OUT of call frames must be LOUD.  The VM used to
# break out of its run loop silently at CALL_STACK_DEPTH (65536, gc/types.zig)
# and return whatever `acc` held: exit 0, EMPTY stderr, and a printed value
# that is not the answer.  calloverflow is a non-tail recursion whose depth IS
# the workload (cf. countcase above, which pins the TAIL path at 100000 — a tail
# call reuses its frame and is unbounded — and tools/bench/suite/deepnontail.elm,
# whose `main` deliberately stays at depth 50000 because that is the deepest
# depth correct on BOTH backends: the VM dies at 65536, the native path is
# correct past 100000).
#
# Registered by depth(), NOT by run(): it asserts on the process (non-zero exit
# + the named diagnostic, and NO value on stdout), which is the half `run`
# cannot see.  See the depth() helper for the three invocations it makes.
depth calloverflow main 1000 5000 500500

# --- osier-natdepth: running out of NATIVE stack must be LOUD too.  The VM
# arm above dies with the interpreter (its cap constant lives in
# vendor/zinc-vm); this arm pins the same PROPERTY on the QBE native path —
# a deep non-tail recursion past the C-stack budget must fail with a NAMED
# diagnostic and no stdout value — using the native guard in tools/qbe/rt.zig
# (see the natdepth helper for the three invocations it makes: a control at
# depth 1000 under the check's own 1 MiB budget, a past-boundary run at 20000
# that must exit non-zero with NAT_DEPTH_MSG, and a deep LEGAL run at 100000
# — 25.6 MiB of stack — that must still complete at the driver's RAISED
# 64 MiB limit, proving the guard did not make the runtime refuse work the
# raise exists to allow).
natdepth natcalloverflow main 1000 20000 100000 500500

# ==================== ELM_GATE_MATRIX: dump the registry ====================
# ELM_GATE_MATRIX=1 prints every REGISTERED check as TSV (one row per check, in
# declaration order) and exits WITHOUT compiling or running anything; with any
# other value (a path) it writes the same TSV to that file.  It is the
# generator input for tests/elm-fixtures/MATRIX.md (see
# tools/gen-fixture-matrix.sh); the registration above is the only source of
# truth, so the matrix cannot drift from the gate.
if [ "${ELM_GATE_MATRIX:-0}" != "0" ]; then
  # An expected value may span lines (ioecho, iofile, unhandledtask).  Every
  # read_expected value carries a trailing newline that the gate's own "$( )"
  # comparison strips; strip it here too, and escape any remaining tab/newline
  # so each check stays exactly one row.
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\t/\\t/g' -e ':a;N;$!ba;s/\n/\\n/g'; }
  dump_matrix() {
    printf 'helper\tname\tentry\tkind\texpected\targs\tstdin\tfixture\n'
    for ((i=0;i<ncheck;i++)); do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${CHLP[$i]}" "${CNAME[$i]}" "${CFN[$i]}" "${CKIND[$i]}" \
        "$(esc "${CEXP[$i]%$'\n'}")" "${CARG[$i]}" "${CSTDIN[$i]}" \
        "$(basename "${CFIX[$i]}")"
    done
  }
  if [ "$ELM_GATE_MATRIX" = "1" ]; then
    dump_matrix
  else
    dump_matrix > "$ELM_GATE_MATRIX"
  fi
  rm -rf "$OUT"
  exit 0
fi

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
    sigdeath)
      # See the sigdeath() helper: no compile group (the corpus baseline pins
      # the batch artifact set), so compile the bundle on demand — the same
      # shape as `depth`, and the reason the batch stays at 149 artifacts.
      if ! node "$CDIR/run.js" "$fixfile" "$OUT/$name.csexp" >/dev/null 2>&1 || [ ! -s "$OUT/$name.csexp" ]; then
        echo "FAIL $name: on-demand compile failed: $fixfile"; fail=$((fail+1)); return
      fi
      if head -c 4 "$OUT/$name.csexp" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$OUT/$name.csexp")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$ELMVM" "$OUT/$name.csexp" "$qname" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($qname -> $got)"; pass=$((pass+1))
      else
        echo "FAIL $name ($qname): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    depth)
      # See the depth() helper: this is one of the checks that compile their
      # own bundle (no register_group — the corpus baseline pins the batch
      # set; see also `sigdeath` and `natdepth`) and
      # the ONE check that asserts on the EXIT STATUS, both because the defect
      # it pins is a silent wrong answer with a SUCCESS status.
      if ! node "$CDIR/run.js" "$fixfile" "$outfile" >/dev/null 2>&1 || [ ! -s "$outfile" ]; then
        echo "FAIL $name: on-demand compile failed: $fixfile"; fail=$((fail+1)); return
      fi
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      cap="$(sed -n 's/.*CALL_STACK_DEPTH *= *\([0-9][0-9]*\).*/\1/p' \
               "$ROOT/vendor/osier-rt/src/gc/types.zig" | head -1)"
      if [ -z "$cap" ]; then
        echo "FAIL $name: cannot read CALL_STACK_DEPTH from vendor/osier-rt/src/gc/types.zig"; fail=$((fail+1)); return
      fi
      read -r ctl margin <<< "$args"
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      near=$((cap - 1))
      past=$((cap + margin))
      # (2) the last usable frame — expected sum 1+2+...+near.
      near_exp=$(( near * (near + 1) / 2 ))
      # (1) the control at a legal depth.
      ctl_out=$(ELMC_HEAP_MB="$DEPTH_HEAP_MB" "$ELMVM" "$outfile" "$qname" "$ctl" 2>&1); ctl_rc=$?
      if [ "$ctl_rc" -ne 0 ] || [ "$ctl_out" != "$exp" ]; then
        echo "FAIL $name $qname $ctl (control): exp rc=0 out[$exp], got rc=$ctl_rc out[$ctl_out]"
        fail=$((fail+1)); return
      fi
      near_out=$(ELMC_HEAP_MB="$DEPTH_HEAP_MB" "$ELMVM" "$outfile" "$qname" "$near" 2>&1); near_rc=$?
      if [ "$near_rc" -ne 0 ] || [ "$near_out" != "$near_exp" ]; then
        echo "FAIL $name $qname $near (CALL_STACK_DEPTH-1): exp rc=0 out[$near_exp], got rc=$near_rc out[$near_out]"
        fail=$((fail+1)); return
      fi
      # (3) past the cap: non-zero exit, the named diagnostic on stderr, and
      # NO value on stdout (a printed value here is the old silent-wrong-answer
      # defect, whatever the exit status says).
      #
      # THIS IS THE ONE INVOCATION IN THE GATE THAT CRASHES ITS CHILD ON
      # PURPOSE, and bash reports a signal-killed job with
      #   "<script>: line N: <PID> Aborted (core dumped) <the command>"
      # on the SHELL's stderr -- not the child's, so the `2>` on the command
      # below does NOT capture it.  That line lands in the gate TRANSCRIPT
      # carrying a fresh PID on every run, which makes the transcript
      # non-deterministic and makes `tools/midtier-diff.sh`'s transcript
      # comparison fail spuriously (it compares MIDTIER=0 against MIDTIER=1).
      # So redirect the shell's own stderr around this ONE invocation to a
      # file (the child's stderr still goes to its own, which the asserts
      # below read), and drop core dumps -- this check exists to panic the VM.
      ulimit -c 0 2>/dev/null || true
      exec 3>&2
      exec 2>"$OUT/$name.past.shellstderr"
      ELMC_HEAP_MB="$DEPTH_HEAP_MB" "$ELMVM" "$outfile" "$qname" "$past" \
        >"$OUT/$name.past.stdout" 2>"$OUT/$name.past.stderr"
      past_rc=$?
      exec 2>&3 3>&-
      if [ "$past_rc" -eq 0 ]; then
        echo "FAIL $name $qname $past (past CALL_STACK_DEPTH=$cap): exit 0 — stdout=$(head -c 80 "$OUT/$name.past.stdout")"
        fail=$((fail+1)); return
      fi
      if ! grep -q "$DEPTH_MSG" "$OUT/$name.past.stderr"; then
        echo "FAIL $name $qname $past (past CALL_STACK_DEPTH=$cap): exit $past_rc but stderr lacks [$DEPTH_MSG]: $(head -c 200 "$OUT/$name.past.stderr" | tr '\n' ' ')"
        fail=$((fail+1)); return
      fi
      if [ -s "$OUT/$name.past.stdout" ]; then
        echo "FAIL $name $qname $past (past CALL_STACK_DEPTH=$cap): exit $past_rc with a value on stdout: $(head -c 80 "$OUT/$name.past.stdout")"
        fail=$((fail+1)); return
      fi
      echo "PASS $name ($qname: $ctl -> $exp, $near -> $near_exp, $past -> exit $past_rc + \"$DEPTH_MSG\")"
      pass=$((pass+1))
      ;;
    natdepth)
      # See the natdepth helper: the native twin of `depth`.  Builds its own
      # binary via qbe-mk (no compile group), owns the budget with
      # QBE_NO_RLIMIT=1 + its own `ulimit -s 1024`, and asserts on the
      # PROCESS like `depth` does — the defect class is a bare fault with no
      # diagnostic, which `run` cannot see.
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      # qbe-mk joins "$ROOT/<fixture>", so hand it the path RELATIVE to the
      # repo root ($fixfile is absolute here); a doubled absolute path is
      # what its node step ENOENTs on.
      rel_fix="${fixfile#"$ROOT"/}"
      bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$rel_fix" "$qname" "$OUT/$name.nat" 2>/dev/null)" || {
        echo "FAIL $name: native build failed (tools/qbe/qbe-mk.sh $rel_fix $qname)"
        fail=$((fail+1)); return
      }
      read -r ctl past deep <<< "$args"
      deep_exp=$(( deep * (deep + 1) / 2 ))
      # (1) control: a legal depth under the 1 MiB budget must print the sum.
      ( ulimit -c 0; ulimit -s 1024; QBE_NO_RLIMIT=1 "$bin" "$qname" "$ctl" \
          >"$OUT/$name.ctl.out" 2>"$OUT/$name.ctl.err" ); ctl_rc=$?
      ctl_out="$(cat "$OUT/$name.ctl.out")"
      if [ "$ctl_rc" -ne 0 ] || [ "$ctl_out" != "$exp" ]; then
        echo "FAIL $name $qname $ctl (native control @1MiB): exp rc=0 out[$exp], got rc=$ctl_rc out[$ctl_out]"
        fail=$((fail+1)); return
      fi
      # (2) past the boundary: non-zero exit, the named diagnostic on stderr,
      # and NO value on stdout.  Same shell-stderr discipline as `depth`: the
      # guard exits cleanly, but a REGRESSED guard dies by signal and bash
      # would print a PID-bearing line on the SHELL's own stderr.
      ulimit -c 0 2>/dev/null || true
      exec 3>&2
      exec 2>"$OUT/$name.past.shellstderr"
      ( ulimit -s 1024; QBE_NO_RLIMIT=1 "$bin" "$qname" "$past" \
          >"$OUT/$name.past.stdout" 2>"$OUT/$name.past.stderr" )
      past_rc=$?
      exec 2>&3 3>&-
      if [ "$past_rc" -eq 0 ]; then
        echo "FAIL $name $qname $past (past the 1MiB stack budget): exit 0 — stdout=$(head -c 80 "$OUT/$name.past.stdout")"
        fail=$((fail+1)); return
      fi
      if ! grep -q "$NAT_DEPTH_MSG" "$OUT/$name.past.stderr"; then
        echo "FAIL $name $qname $past (past the 1MiB stack budget): exit $past_rc but stderr lacks [$NAT_DEPTH_MSG]: $(head -c 200 "$OUT/$name.past.stderr" | tr '\n' ' ')"
        fail=$((fail+1)); return
      fi
      if [ -s "$OUT/$name.past.stdout" ]; then
        echo "FAIL $name $qname $past (past the 1MiB stack budget): exit $past_rc with a value on stdout: $(head -c 80 "$OUT/$name.past.stdout")"
        fail=$((fail+1)); return
      fi
      # (3) deep LEGAL work at the driver's RAISED limit (no QBE_NO_RLIMIT,
      # no ulimit): $deep levels of stack must still complete with the exact
      # sum — the guard must not refuse work the raise exists to allow.  This
      # arm needs the raise to actually reach 64 MiB (a hard limit below
      # $deep * 256 B fails here for a different reason than the guard).
      "$bin" "$qname" "$deep" >"$OUT/$name.deep.out" 2>"$OUT/$name.deep.err"; deep_rc=$?
      deep_out="$(cat "$OUT/$name.deep.out")"
      if [ "$deep_rc" -ne 0 ] || [ "$deep_out" != "$deep_exp" ]; then
        echo "FAIL $name $qname $deep (raised-limit deep control): exp rc=0 out[$deep_exp], got rc=$deep_rc out[$deep_out] err[$(head -c 80 "$OUT/$name.deep.err")]"
        fail=$((fail+1)); return
      fi
      echo "PASS $name ($qname native: $ctl -> $exp @1MiB, $past -> exit $past_rc + \"$NAT_DEPTH_MSG\", $deep -> $deep_exp @raised)"
      pass=$((pass+1))
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
