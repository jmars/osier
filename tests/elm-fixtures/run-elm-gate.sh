#!/usr/bin/env bash
# run-elm-gate.sh — the Osier LANGUAGE gate (BATCH mode).
#
# For each fixture under tests/elm-fixtures, compiles it with the osier-compiler
# (node run.js), and — for every EXECUTABLE row — builds the fixture through
# the QBE backend (tools/qbe/qbe-mk.sh: elm -> .ssa -> vendored qbe -> cc +
# rt.o) and runs the native binary, diffing the printed value against
# expected/<name>.txt.
#
# P8 (osier-delete-zinc): the ZINC interpreter rows are GONE — the VM package
# (the vendored zinc-vm package) and its harness binary were deleted, and the gate's
# execution model is the P7 native rows, which had already been proving the
# same fixtures against the same pinned expected/*.txt values beside the VM
# rows.  Each group's batch output is the group's .ssa (QBE IL text, or its
# "err ..." payload) — the compile-only rows (ok/err) check that payload.
# What
# died with the interpreter and is NOT replaced here, recorded losses:
#   * rawrun (a committed hand-crafted .csexp bundle no Elm source can
#     produce — the unknown-Task-tag fixture): the bundle format's own check;
#   * depth (the interpreter's CALL_STACK_DEPTH cap): its native counterpart
#     is the natdepth row (the C-stack budget guard), which stays.
#
# Native binaries build in PARALLEL (ELM_GATE_J jobs, default 8) in a build
# phase between the batch compile and the checks, so the PASS/FAIL transcript
# stays in declaration order.
#
# Since S8 the compile step is BATCHED: the fixed corpus (Prelude + Runtime +
# the eight core-libs) is parsed+typechecked+lowered ONCE, and every fixture
# group is compiled in the SAME node run.js process against the cached corpus.
# The script declares all fixtures up front (registering each (sources, output)
# group + its post-compile check), calls run.js ONCE with a batch manifest, then
# runs the checks in declaration order.
#
# Usage:
#   tests/elm-fixtures/run-elm-gate.sh [osier-compiler-dir] [fixtures-dir]
#
# Every check this script REGISTERS is listed, generated from the registration
# calls below, in tests/elm-fixtures/MATRIX.md
# (regenerate/verify: tools/gen-fixture-matrix.sh [--check]; raw dump:
# ELM_GATE_MATRIX=1 tests/elm-fixtures/run-elm-gate.sh).
#
# Defaults assume you are running from the repo root:
#   compiler -> osier-compiler/     (compiler.js built via build.sh)
#   fixtures -> tests/elm-fixtures
#
# NOTE: M6's iofile fixture resolves input/hello.txt and out/hello.out RELATIVE
# TO THE PROCESS CWD (the stream prims take plain paths), so the gate MUST be
# started from the repo root.
#
# Exit code 0 iff every check passes.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# THE TWO ARMS ARE RETIRED: there is ONE arm.  The Zig effect host went at O4
# (QBE_MIDHOST is inert — no reader survives in runtime.mid) and the Zig
# collector went at ZIGHOST Z0 (run.js refuses QBE_MIDGC=0 outright, exit 2), so
# an ordinary `run-elm-gate.sh` is the only route: the Mid host on the Mid
# collector.  The two exports below stay as PASS-THROUGH: a caller that still
# sets either flag gets run.js's loud refusal instead of a silently different
# route, and the RUN phase inherits the same environment the compile saw (that
# is why they are exported here rather than read at the call site).
[ -n "${QBE_MIDHOST:-}" ] && export QBE_MIDHOST
[ -n "${QBE_MIDGC:-}" ] && export QBE_MIDGC

CDIR="${1:-$ROOT/osier-compiler}"
FIX="${2:-$ROOT/tests/elm-fixtures}"
OUT="$(mktemp -d)"

# ELM_GATE_MATRIX=1 (or a path) dumps the REGISTERED check matrix and stops
# BEFORE any build/compile step (tools/gen-fixture-matrix.sh uses it), so the
# compiler.js / jq prerequisites are not required in that mode.
if [ "${ELM_GATE_MATRIX:-0}" != "0" ]; then
  : # matrix dump mode: no compiler.js / jq required (see the dump below)
elif [ "${ELM_GATE_MANIFEST_ONLY:-0}" = "1" ]; then
  # manifest-only mode (the .ssa corpus baseline consumes this): the manifest
  # is built from the REGISTRY alone, so qbe / cc are not needed — only
  # compiler.js (whose path the manifest names) and jq.
  if [ ! -f "$CDIR/compiler.js" ]; then
    echo "error: $CDIR/compiler.js missing (run: build.sh)" >&2
    exit 2
  elif ! command -v jq >/dev/null 2>&1; then
    echo "error: jq required to build the batch manifest" >&2
    exit 2
  fi
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

# ---- CWD GUARD (perf VR3b3 review, evidence hygiene) -----------------------
# THE GATE'S RESULT DEPENDS ON WHERE YOU STAND, so it now REFUSES to stand
# anywhere else.  MEASURED: run from inside tests/elm-fixtures/ it prints
# PASS=182 FAIL=8 — the eight are the fixtures that resolve repo-root-relative
# paths (the iofile fixture reads input/hello.txt and writes out/hello.out, and
# the stream prims take plain paths, so they resolve against the process CWD).
# A gate whose score depends on the caller's directory is one that will one day
# be quoted wrong, and a silent 182/8 reads exactly like a regression.  The
# matrix/manifest modes above are exempt: they emit a registry and touch no
# fixture.  Callers already `cd "$ROOT"` (tools/osier-numbers.sh,
# tools/osier-corpus-ssa.sh), so this changes nothing for them.
if [ "$(pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
  echo "error: run-elm-gate.sh MUST be run from the repo root ($ROOT)," >&2
  echo "       not from $(pwd -P): eight fixtures resolve repo-root-relative paths and" >&2
  echo "       would report a false PASS=182 FAIL=8.  Try: cd '$ROOT' && tests/elm-fixtures/run-elm-gate.sh" >&2
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
# output) and (b) its post-compile CHECK.  Nothing compiles or builds yet;
# the checks fire in declaration order after the one batch compile.

ngroup=0; ncheck=0
declare -a GOUT GSRC GENTRY
declare -a CKIND CNAME CFN CEXP CARG CSTDIN CFIX COUT CHLP CNAT

# Parallel jobs for the native builds — P7's native twins are the ONLY
# executable rows since the interpreter retired at P8.
NATJ="${ELM_GATE_J:-8}"

register_group() {
  local out="$1"; shift
  GOUT[$ngroup]="$out"
  GSRC[$ngroup]="$*"
  ngroup=$((ngroup+1))
}

# add_check <kind> <name> <fn> <expected> <args> <stdin> <fixture> <out> <helper> [nat-sources]
# $9 is the REGISTERING HELPER's name (run / compile_error / ...) — printed by
# the ELM_GATE_MATRIX dump so the matrix names the check the way a reader of
# this file does.  The dispatcher keys on $1 only.  ${10}, when non-empty, is
# the SOURCE LIST of the row's NATIVE build (the QBE binary of the same
# program); empty = no native row (compile_error, ...).
add_check() {
  CKIND[$ncheck]="$1"; CNAME[$ncheck]="$2"; CFN[$ncheck]="$3"
  CEXP[$ncheck]="$4"; CARG[$ncheck]="$5"; CSTDIN[$ncheck]="$6"
  CFIX[$ncheck]="$7"; COUT[$ncheck]="$8"; CHLP[$ncheck]="$9"
  CNAT[$ncheck]="${10:-}"
  ncheck=$((ncheck+1))
}

# run <name> <fn> <expected> [args...]
#
# Registers the compile group and the NATIVE row: the fixture builds through
# the QBE backend and the binary runs "<Mod>.<fn>" (module scanned from the
# fixture header) with the given args.
run() {
  local name="$1" fn="$2" exp="$3"; shift 3
  register_group "$OUT/$name.ssa" "$FIX/$name.elm"
  GENTRY[$((ngroup-1))]="$(module_name "$FIX/$name.elm").$fn"
  add_check natrun "$name" "$fn" "$exp" "$*" "" "$FIX/$name.elm" "" run "$FIX/$name.elm"
}

# run2 <name> <auxname> <fn> <expected>: multi-module fixture — <aux>.elm is
# compiled TOGETHER WITH <name>.elm (cross-module import); the native binary
# runs "<NameModule>.<fn>" scanned from the MAIN fixture header.
run2() {
  local name="$1" aux="$2" fn="$3" exp="$4"; shift 4
  register_group "$OUT/$name.ssa" "$FIX/$aux.elm" "$FIX/$name.elm"
  GENTRY[$((ngroup-1))]="$(module_name "$FIX/$name.elm").$fn"
  add_check natrun2 "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "" run2 "$FIX/$aux.elm $FIX/$name.elm"
}

# run_hostio <name> <fn> <expected> <stdin-file>
#
# STAGE 7B's arm-B row: a `Platform.program` fixture driven through the MID
# EFFECT HOST.  Like run_io it redirects stdin, and like run_io it inherits
# QBE_MIDHOST, so the SAME row is the Mid-host arm (unset/`=1`, the DEFAULT since
# stage 7 O2) or the Zig-host arm (`=0`) with no second registration.
#
# It registers NO compile group, DELIBERATELY: the corpus baseline pins the
# batch artifact set (159 groups), so a new .ssa group would move the corpus
# for a fixture whose point is a RUNTIME differential.  Same shape as
# `sigdeath`/`natdepth`: the native row builds its own binary on demand.
run_hostio() {
  local name="$1" fn="$2" exp="$3" stdin="$4"
  add_check natio "$name" "$fn" "$exp" "" "$stdin" "$FIX/$name.elm" "" run_hostio "$FIX/$name.elm"
}

# run_pipe <name> <fn> <expected>
#
# STAGE 7C's arm-B row: a `Platform.program` fixture that reads /dev/stdin,
# with stdin fed by a SLOW PRODUCER (a shell subshell: "he", a 50 ms pause,
# "llo") instead of a file.  That is what makes the read SUSPEND — the pipe is
# empty on the first read, so the leaf gets EAGAIN, polls, and the second chunk
# wakes it — which is the ONLY path that exercises the fd table (a regular file
# drains to EOF synchronously and never polls).
#
# Both arms agree because the fixture's ANSWER is the same however the bytes
# arrive: one read of five bytes or two reads of two and three.  Like
# run_hostio it registers NO compile group (the corpus baseline pins the batch
# artifact set at 159 groups) — the native row builds its own binary on demand.
run_pipe() {
  local name="$1" fn="$2" exp="$3"
  add_check natpipe "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "" run_pipe "$FIX/$name.elm"
}

# run_io <name> <fn> <expected> <stdin-file>
#
# Like run(), but the native binary's stdin is redirected from
# "$FIX/input/<stdin-file>" instead of being inherited — the M6 stream-prims
# fixtures (Cmd.readLine via read-byte on fd 0) consume stdin.
run_io() {
  local name="$1" fn="$2" exp="$3" stdin="$4"
  register_group "$OUT/$name.ssa" "$FIX/$name.elm"
  GENTRY[$((ngroup-1))]="$(module_name "$FIX/$name.elm").$fn"
  add_check natio "$name" "$fn" "$exp" "" "$stdin" "$FIX/$name.elm" "" run_io "$FIX/$name.elm"
}

# compile_clean <name>: asserts compilation SUCCEEDS (the artifact is a real
# bundle, not an "err ..." payload) but does not run it through the value
# gate — for fixtures whose value cannot be driven from argv (e.g. functions
# taking record arguments).
compile_clean() {
  local name="$1"
  register_group "$OUT/$name.ssa" "$FIX/$name.elm"
  GENTRY[$((ngroup-1))]="$(module_name "$FIX/$name.elm").main"
  add_check ok "$name" "" "" "" "" "$FIX/$name.elm" "$OUT/$name.ssa" compile_clean
}

# compile_error <name> <expected-substring>: asserts compilation emits
# "err <message>" and that <message> contains the expected substring.  Used for
# fixtures that must FAIL to compile (duplicate/unknown names, etc.) rather than
# run through the value gate.
compile_error() {
  local name="$1" exp="$2"
  register_group "$OUT/$name.ssa" "$FIX/$name.elm"
  # the entry never runs (the compile errs first); <Mod>.main keeps the .ssa
  # baseline's rule uniform over every group.
  GENTRY[$((ngroup-1))]="$(module_name "$FIX/$name.elm").main"
  add_check err "$name" "" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.ssa" compile_error
}

# out_cmp <name> <file>: compare the raw file the fixture's native run wrote
# (under "$FIX/out/") against "expected/<file>.txt".  <file> rides in the
# COUT column, which no other kind uses.
out_cmp() {
  add_check cmp "$1" "" "" "" "" "" "$2" out_cmp
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
# Registered WITHOUT a compile group (like `natdepth`):
# tools/osier-corpus-baseline.ssa.sha256 pins the batch's artifact set
# (149 artifacts = 149 manifest entries), so this row builds its binary on
# demand instead.
sigdeath() {
  local name="$1" fn="$2" exp="$3"
  add_check natsig "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "" sigdeath "$FIX/$name.elm"
}

# runhost <name> <fn> <expected>
#
# STAGE 7D's arm-B rows: `Platform.program` fixtures that drive TaskExec
# through the EFFECT HOST.  They exist because every pre-existing `exec*` row
# is a `Platform.worker` fixture — `Runtime.runTask` runs those SYNCHRONOUSLY
# through the `exec-plan` prim, so they never construct a Program vector and
# never reach the leaf (MEASURED: green on both arms with the leaf absent).
# Like sigdeath/run_pipe/natdepth it registers NO compile group (the corpus
# baseline pins the batch artifact set at 159 groups) — the native row builds
# its own binary on demand.
runhost() {
  local name="$1" fn="$2" exp="$3"
  add_check nathost "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "" runhost "$FIX/$name.elm"
}

# natdepth <name> <fn> <control-depth> <past-depth> <deep-depth> <expected-control-value>
#
# THE NATIVE OUT-OF-STACK CHECK (handoff osier-natdepth) — the arm that
# SURVIVES the interpreter's retirement (P8): it asserts the
# QBE native path's OWN resource boundary, the C stack.  Before the guard
# (tools/qbe/rt.zig), a non-tail recursion deep enough to exhaust
# RLIMIT_STACK died with a BARE SIGSEGV — non-zero, so never a silent wrong
# answer, but unnamed and unassertable.  The guard installed sigaltstack + a
# SIGSEGV handler that recognised a stack-exhaustion fault and exited 1 with
# the NAT_DEPTH_MSG diagnostic; this check pinned that property.  B4 (the
# shrink) DELETED the guard (owner decision), so the past-boundary arm now
# asserts the BARE SIGSEGV (rc 139) again — non-zero, never a silent wrong
# answer, just unnamed once more.
#
# Like `sigdeath` it registers NO compile group (the corpus baseline pins
# the batch artifact set): it builds its own native binary on demand via
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

# The named diagnostic the QBE NATIVE runtime prints when the C stack is
# exhausted (tools/qbe/rt.zig's stack-depth guard: sigaltstack + a SIGSEGV
# handler that recognises a stack-exhaustion fault).  Deliberately distinct
# from DEPTH_MSG ("native" vs "call") so neither arm's grep can match the
# other backend's message.
NAT_DEPTH_MSG="native stack depth exceeded"

# intproc <name> <fn> <expected-status> <expected-stdout> <expected-stderr> [args...]
#
# THE EXTREME-Int CORNER ROW (L3-U0, design §7).  It asserts the PROCESS — exit
# STATUS plus each stream separately — because two of its rows pin a SIGNAL
# DEATH, and a signal death cannot be expressed as a stdout diff: bash prints
# the "Floating point exception" notice on ITS OWN stderr with a PID in it, so
# that notice must never reach the capture (the natdepth check routes shell
# stderr to a file for the same reason).
#
# WHY A ROW THAT PINS A CRASH IS THE RIGHT THING TO WRITE FIRST.  The language's
# Int is already an i64 at execution — `+ - *` wrap, `//` truncates toward zero
# — but no row pinned any of it, and `//0` / INT64_MIN // -1 are SIGFPE core
# dumps today.  Pinning today's measured behaviour HERE makes L3-U2's fix an
# ASYMMETRY PROOF: the divzero/minbyneg rows are green on exit 136 now, and
# green on the named halt only after the pre-check lands.  A row written at the
# same time as the fix could not tell "the fix works" from "the row was written
# to match the fix".
#
# Like sigdeath/natdepth it registers NO compile group (the corpus baseline
# pins the batch artifact set at 159 groups, and these rows change no
# compiler behaviour) — the native row builds its own binary on demand.
intproc() {
  local name="$1" fn="$2" st="$3" out="$4" err="$5"; shift 5
  add_check natproc "$name" "$fn" "$st|$out|$err" "$*" "" "$FIX/$name.elm" "" intproc "$FIX/$name.elm"
}

# intreject <name> <expected-substring>
#
# THE LOUD-REFUSAL ROW (L3-U1).  Compiles the fixture on demand and requires the
# compiler's error payload to CONTAIN <expected-substring> — the "does it refuse,
# and does it say why" half of the literal-range work.  Like intproc it registers
# NO compile group (the corpus baseline pins the batch artifact set at 159
# groups); the row owns its own compile.
intreject() {
  local name="$1" exp="$2"
  add_check natreject "$name" "" "$exp" "" "" "$FIX/$name.elm" "" intreject
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
run symeq       main       "$(read_expected symeq)"
run fdstream    main       "$(read_expected fdstream)"
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
out_cmp iofile hello.out
# ioecho: readLine echo-until-quit — echoed lines + the final Int count.
run_io ioecho  main   "$(read_expected ioecho)" echo.txt
# readfile (GROUP 3B-3): read-file-as-string's four arms in one chain —
# existing / missing (the stderr note IS in the golden via 2>&1) / empty /
# 70000-byte (chunk 2 + the accumulator grow).  The golden is the ZIG arm's
# own output (the pre-conversion rt_prim route).
run readfile  main   "$(read_expected readfile)"
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
# --- STAGE 7D: TaskExec through the effect HOST (both arms' differential) ---
# exechost: the ASYNC single-command arm end to end — a child that writes past
# the 64 KiB drain chunk (the out accumulator GROWS while the child blocks on
# the full pipe), 5 bytes of captured stderr (the only row with a non-empty
# err accumulator through the host), and a NON-ZERO exit code decoded from
# WIFEXITED.  execfallback: the plan-shape predicate's NEGATIVE arm — a
# two-command pipeline, which must take the synchronous `exec-plan` fallback
# instead of being forked.  Both are Platform.program, which is the point.
runhost exechost      main "$(read_expected exechost)"
runhost execfallback  main "$(read_expected execfallback)"
# ... and the fallback's DISCRIMINATOR: only the synchronous runner applies the
# plan's `out` redirect, so the file exists iff the classification was right.
out_cmp execfallback execfallback.out
# --- 3B-2a (exec-plan decode in Mid): a MALFORMED plan must fail LOUDLY ---
# ExecMal's chain op is "bogus" — not seq/and/or — so Rt.epChain's OP GUARD
# rejects it and the run halts; the expected value IS the halt diagnostic
# (the gate's $(... 2>&1) captures it).  The silent-accept failure mode
# (decode as seq, run the pipeline, print "0|hi\n|") is the RED this row
# exists to catch — the row went red exactly that way when epChain's
# unknown-op arm was mutated to epOpSeq (handoff-osier-stage3-g3b2a-ii).
run execmal      main   "$(read_expected execmal)"
# --- 3B-2b (exec-plan RUN in Mid): the CHAIN short-circuit (&& skips its
# chain when the previous code is nonzero; || when zero) — no earlier fixture
# reaches the multi-chain path, and the 3B-2a probes' and/or rows are
# single-chain plans where the op never fires.  Expected = the ZIG arm's own
# output on this fixture (the implementation being replaced).
run execchain    main   "$(read_expected execchain)"
# --- exec-plan fix round: the IN-PROCESS ECHO SLOT (rEchoI) — a subshell
# whose inner program has TWO chains with an ECHO BUILTIN in chain 0; the
# builtin arm runs inside the program loop, and a cursor shared with the
# loop's rI ends the program after the echo chain (RED printed "0|a\n|").
run execsubchain main   "$(read_expected execsubchain)"
# --- 3B-2c (exec-plan SLURP+RESULT in Mid): the slurp GROW arm through
# exec — captured output beyond the 64 KiB read chunk (168894 bytes, two
# grows), with stderr EOF-ing empty AFTER the out slurp's grow (the shared
# C block's acc/len/cap reset between the two slurps).  Expected = the ZIG
# seat's own output on this fixture (the implementation being replaced).
run execbig      main   "$(read_expected execbig)"
# --- 3B-2b: the redirect-OPEN-FAILURE path — a valid `in` redirect naming a
# nonexistent file must answer 1 + the captured childW2 message (the only
# fixture exercising applyOneRedir's open-failure arm and its error string).
run execnofile   main   "$(read_expected execnofile)"
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

run cmporder    main   "$(read_expected cmporder)"
run resultmaybe main   "$(read_expected resultmaybe)"
run dictbasic   main   "$(read_expected dictbasic)"
run setops      main   "$(read_expected setops)"
run dictstress  main   "$(read_expected dictstress)"

# --- elm/core Bitwise + Array port (vector JsArray substitute, RRB tree) ---
# bitwise: int32 semantics pins for the 7 runtime prims (truncation, count
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
# progio (STAGE 7B): the SYNCHRONOUS leaves of the Mid effect host under a real
# Platform.program — readLine (stdin/input/progio.txt, a 260-byte LINE so the
# accumulator GROWS twice: the growth arm's only cheap probe), writeString (fd 1), setenv +
# getenv, getpid, writeFile (out/progio.out, compared below) and cd + getcwd,
# with a 15 ms sleep composed into the chain so the deadline machinery runs
# between them.  Registered WITHOUT a compile group (see run_hostio) and
# inheriting QBE_MIDHOST, so this ONE row is arm A and arm B.
run_hostio progio main "$(read_expected progio)" progio.txt
out_cmp progio progio.out
# readpipe (STAGE 7C): THE SUSPENDING readFile — the ONLY row that reaches the
# host's fd table.  Its stdin is a PIPE fed by a slow producer (see run_pipe),
# so the first read is EAGAIN: rebuildPollfds registers one fd, poll blocks on
# it, drainReady completes it, and the answer is the same however the bytes
# arrive.  The chain's second read (big.txt, 70000 bytes) is the accumulator's
# GROW under the host.  A `Platform.worker` fixture cannot see any of this: the
# synchronous driver runs the read-file-as-string prim instead of the effect.
run_pipe readpipe main   "$(read_expected readpipe)"

# --- S6 (M-FOUNDATION): host dir/stat leaves (getdents64 + fstatat) ---
# dirunit: Io.listDir over input/dirlist — '.'/'..' skipped, isDir from dirent
# d_type; RAW fs order re-sorted through Set for a deterministic join.
run dirunit     main   "$(read_expected dirunit)"
# statunit: Io.stat size + isDir/isFile + mode S_IFMT type bits (NOT mtime) +
# the zero-record failure parity for a missing path.
run statunit    main   "$(read_expected statunit)"
# statplus (unit-B item 3 blocker-1): ARITHMETIC (+ - *) on a HOST-BUILT
# Io.stat record field — the Zig-built assoc CHAIN (tag 4) the item-3 raw read
# wrongly treated as a positional vector.  statunit only compares/bitands
# (prims isIntKnown does not admit), so this is the fixture that fails loud if
# the raw read loses its tag-14 test.
run statplus    main   "$(read_expected statplus)"



run rowpoly     main   "$(read_expected rowpoly)"
run extrec      main   "$(read_expected extrec)"
run insrec      main   "$(read_expected insrec)"
run remrec      main   "$(read_expected remrec)"
# rmprobe (unit-B item 3 blocker-1): arithmetic on a Record.remove RESULT — a
# chain (tag 4) typed as a CLOSED {n:Int} by f's signature, the second host
# boundary the item-3 raw read's static licence got wrong.  remrec reads
# remove results too but its fields are unannotated number TVars (denied), so
# this is the fixture that fails loud if the raw read loses its tag-14 test.
run rmprobe     main   "$(read_expected rmprobe)"
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

# --- osier-natdepth: running out of NATIVE stack must be LOUD.  This arm
# pins the property the interpreter's CALL_STACK_DEPTH cap used to cover —
# a deep non-tail recursion past the C-stack budget must fail with a NAMED
# diagnostic and no stdout value — using the native guard in tools/qbe/rt.zig
# (see the natdepth helper for the three invocations it makes: a control at
# depth 1000 under the check's own 1 MiB budget, a past-boundary run at 20000
# that must exit non-zero with NAT_DEPTH_MSG, and a deep LEGAL run at 100000
# — 25.6 MiB of stack — that must still complete at the driver's RAISED
# 64 MiB limit, proving the guard did not make the runtime refuse work the
# raise exists to allow).
natdepth natcalloverflow main 1000 20000 100000 500500

# ==================== L3-U0: the extreme-Int corners ====================
# The rows the L3 design (§7 U0) puts in FIRST, because they pin what the
# language ALREADY does rather than what it is about to do:
#
#   wrapmul  — `*` wraps in two's complement: 1024^6 * 16 = 2^64 -> 0.
#   truncdiv — `//` truncates TOWARD ZERO: (0 - 7) // 2 = -3, not -4.
#   divzero  — 100 // 0 is SIGFPE (exit 136) TODAY; L3-U2 makes it a named halt.
#   minbyneg — INT64_MIN // -1 is SIGFPE TODAY, for the same reason (the
#              quotient 2^63 is not an i64, so the hardware idiv traps).
#
# The two crash rows are EXPECTED to flip in U2 (exit 136, empty streams ->
# exit 1 + the runtime's named message).  That flip is the proof that the
# pre-check, not the fixture, is what changed.  See the intproc helper for why
# the status and each stream are compared separately.
intproc intcorner wrapmul  0   "0"  ""  1
intproc intcorner truncdiv 0   "-3" ""  7
# The two division corners now HALT BY NAME (L3-U2). These rows were pinned to
# the SIGFPE in U0 and are flipped here — that flip is the asymmetry proof: the
# same row went from green-on-136 to green-on-1-with-a-message, so it is the
# pre-check that changed, not the fixture.  Exit 1 is `Rt.die`'s (the runtime's
# named-error channel), and the message is compared EXACTLY on the program's own
# stderr (see the natproc dispatch arm for why the shell's and timeout's
# notices are kept out of it).
intproc intcorner divzero  1   ""   'qbe-rt: division by zero: `// 0` has no i64 value'  0
intproc intcorner minbyneg 1   ""   'qbe-rt: division overflow: `INT64_MIN // -1` is 2^63, which is not an i64'  1

# ==================== L3-U1: the i64 LITERAL RANGE ====================
# The frontend's accept set is the i64 range now, carried EXACTLY (two-arm
# `Lit`: a host-exact small arm and a validated-digit-string big arm).  Every
# literal in intbig.elm is above the OLD bound (2^53), so before this unit not
# one of these rows could even be written — that is the fail-before half.
#
#   maxi64   INT64_MAX, digit for digit (a double rounds it UP to 2^63).
#   mini64   INT64_MIN, the one value legal only under a unary minus.
#   above53  2^53+1 — the "small but inexact" half of the defect.
#   bigmul   2^60-1, the VR3b2 trap value (a double cannot tell it from 2^60).
#   bigdiff  the same value reached by i64 ADDITION (the general prim path,
#            since the raw-Int fast path does not admit a big literal).
#   hexmax   the same bound in HEX, arriving as canonical decimal digits.
intproc intbig maxi64  0 "9223372036854775807"  ""
intproc intbig mini64  0 "-9223372036854775808" ""
intproc intbig above53 0 "9007199254740993"     ""
intproc intbig bigmul  0 "1152921504606846975"  ""
intproc intbig bigdiff 0 "1152921504606846976"  ""
intproc intbig hexmax  0 "9223372036854775807"  ""
# ... and a big literal in PATTERN position: `MLitEq` carries the digits and
# the runtime compare is an i64 compare, so the test is exact over the range.
# The argv argument goes through the runtime's own parser, which is exact too.
intproc intbig patmatch 0 "1" "" 9223372036854775807
intproc intbig patmatch 0 "0" "" 5
# THE LOUD REFUSALS. Three routes, because the range is decided in three
# places: the parser (> 2^63), and FromAst's negation site for the bare 2^63
# magnitude (decimal and hex), which the parser must accept so that
# -9223372036854775808 parses.
# SINGLE-QUOTED on purpose: the expected text contains BACKTICKS, and a
# backtick inside double quotes is command substitution (it silently ate the
# literal from these three expectations the first time they were written).
intreject inttoobigparse 'parse error at row 16 column 5: integer literal `99999999999999999999` is out of range: this language'"'"'s Int is a signed 64-bit integer'
intreject inttoobig      'integer literal `9223372036854775808` is out of range: it is the magnitude of INT64_MIN'
intreject inttoobighex   'integer literal `9223372036854775808` is out of range: it is the magnitude of INT64_MIN'

# ========== AREA 4 FOLLOW-UP: the BOXED-INT reader pairs (x FLOAT, and
# ========== BOXED+BOXED INTEGER whose sum re-boxes) ==========
# The word arm BOXES an Int outside the i61 fixnum range into a code-13 heap
# cell (`Rt.boxInt`), and `payload(x, 0)` is the unbox.  Every other reader of
# a boxed value was pinned by a row; `Rt.+`'s FLOAT arm was not — and it is the
# one reader that has to unbox a boxed int while its other operand is a float:
#
#   mkflt(fload(asF(a)) f+ fload(asF(bb)))      (Rt.+, runtime.mid)
#   asF = mkflt(itof(payload(x, 0)))            (Rt.asF, runtime.mid)
#
# Nothing in the tree reached that pair, so a regression in it is a SILENT
# wrong double with rc 0 (MEASURED: the one-instruction mutation below).
#
# WHY THE FIXTURE'S 2^60 REALLY BOXES.  `Mid/RtLayout.wordFixnumLimit` is
# 1152921504606846976 (2^60) at this HEAD, EXCLUSIVE in magnitude (`-limit <=
# n < limit`), so 2^60 is the first value that does not fit; the emitted
# `q_Boxfloat_x2ebig` contains `call $q_Rt_x2eboxInt` and no `n * 8` shift.
# It is also above 2^53, so it travels as digits and is rebuilt from limbs.
#
# WHY `Basics.toFloat` DOES NOT CONVERT FIRST: on the word arm an Int and a
# Float are both one word, so `Prelude.basicsToFloat` hands the SAME word on —
# the boxed cell's word reaches `Rt.+`, and the unbox happens in `asF` INSIDE
# the float arm.  The rows therefore pin the unbox, not an adjacent
# conversion.  (Without a genuine float operand the expression falls to
# `Rt.+`'s INT arm instead — `toFloat big + toFloat big` prints the exact i64
# `2305843009213693952`, not a float rendering — which is why every entry in
# boxfloat.elm carries a real float operand.)
#
#   boxadd     boxed on the LEFT of the add.
#   boxaddrev  boxed as the SECOND argument (the two `asF` sites are separate).
#   boxbigsum  the result path at scale: the sum is past INT64_MAX, so it can
#              only be a float — nothing on that path may re-box it.
#
# THE EXPECTATIONS ARE THE VAL ARM'S (the differential oracle, as for every row
# here): the val arm never boxes, so it reaches the same doubles another way.
# FAIL-ABILITY, MEASURED without touching the tree: replacing the `loadl` of
# `asF`'s heap arm in the emitted .ssa with `sar %t20, 3` (no unbox) turns all
# three rows RED at rc 0 — 17567033390210.5 / 17482234317962.5 /
# 10000017582384234000.0 instead of the pinned values.
intproc boxfloat boxadd    0 "1152921504606847000.0"   ""
intproc boxfloat boxaddrev 0 "1152921504606847000.0"   ""
intproc boxfloat boxbigsum 0 "11152921504606847000.0"  ""
#
# THE DOUBLE ROUND TRIP: boxed + boxed INTEGER addition whose SUM RE-BOXES
# (`boxaddint`).  The three rows above pin the UNBOX; none of them says
# anything about the other end of the round trip, because a float result is
# never re-boxed.  Here both operands are code-13 cells, `Rt.+` takes its INT
# arm, unboxes both through `payload(x, 0)`, adds, and the sum (2^61 + 1) is
# itself outside the i61 fixnum range — so `mknum`'s one overflow check must
# take its failure branch and box the result a SECOND time.
#
# WHY THE VALUES BOX (arithmetic, MEASURED in the emit): the fixnum bound is
# `-2^60 <= n < 2^60`, EXCLUSIVE in magnitude, so 2^60 and 2^60+1 are both
# outside it; the emitted `q_Boxfloat_x2ebig` / `q_Boxfloat_x2ebigodd` each
# contain `call $q_Rt_x2eboxInt` and no `n * 8` shift.  The sum
# 2305843009213693953 = 2^61 + 1 is greater than 2^60 (so it cannot be a
# fixnum) and far below INT64_MAX (so the boxed body holds it exactly).  The
# `+ 1` in the second operand is the only bit below 2^60 in the answer, so a
# truncated unbox, a lost low limb or a one-operand unbox prints a different
# number rather than the same one.
#
# BOTH ENDS ARE IN THE EMIT, which is why this row is not pinning something
# adjacent: operand end = the two `q_Rt_x2eboxInt` calls above; result end =
# inside `q_Rt_x2e_x2b`, the int arm's `@pfix_*`/`@pheap_*` unbox pair feeding
# `add`, the `shl`/`sar`/`ceql` round-trip check, and `@fixbox_*`'s
# `call $q_Rt_x2eboxInt`.
#
# THE VAL ARM IS THE ORACLE AND IT IS A GENUINELY DIFFERENT ROUTE: with
# `QBE_VALREP=val` the same fixture emits ZERO `q_Rt_x2eboxInt` calls, the
# literal is a plain i64 in a 40-byte Value's payload, and the add is inlined
# as two payload loads and an `add`.  It prints the same number, so the two
# arms agreeing is a differential, not a tautology.
#
# FAIL-ABILITY, MEASURED on /tmp copies of this row's own .ssa with the tree
# untouched, one branch each: (1) RESULT end — make `@fixbox_*` fall through to
# the fixnum store instead of calling the seat, and the row prints `1` (the
# sum's low word shifted back down) at rc 0; (2) OPERAND end — store the
# literal raw instead of calling `Rt.boxInt`, and it prints 1297036692682702849
# at rc 0.  Both are SILENT wrong answers with rc 0, which is the signature
# this row exists to catch.
intproc boxfloat boxaddint 0 "2305843009213693953" ""

# ==================== L1: the `^` operator ====================
# `^` was already in the parser (Elm's precedence 8, right-associative); what did
# not exist was a checker row, a lowering row and a runtime prim, so every `^`
# in a program was an unknown-operator error. These rows pin the semantics the
# design decides (§9): exponentiation by squaring, i64 wrap (consistent with
# `*`), `0 ^ 0 = 1`, and a NAMED HALT on a negative exponent rather than a quiet 0.
#
#   powsmall  2 ^ 10            -> 1024
#   powzero   0 ^ 0             -> 1        (the accumulator's start)
#   powwrap   2 ^ 64            -> 0        (i64 wrap, exactly as `*` does)
#   powbig    3 ^ 39            -> 4052555153018976267 (exact, big)
#   powneg    2 ^ (0 - 1)       -> rc 1 + the runtime's message
intproc intpow powsmall 0 "1024"  ""
intproc intpow powzero  0 "1"     ""
intproc intpow powwrap  0 "0"     ""
intproc intpow powbig   0 "4052555153018976267" ""
intproc intpow powneg   1 ""      'qbe-rt: negative exponent: `^` requires an exponent >= 0'  1

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
        --arg entry "${GENTRY[$i]:-}" \
        --argjson srcs "$(printf '%s\n' "${srcs[@]}" | jq -R . | jq -s .)" \
        '{sources: $srcs, output: $out, entry: $entry}' >> "$OUT/groups.jsonl"
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

# ============================ PHASE 2.5: native builds ============================
# Every registered native row (CNAT non-empty) builds HERE, in parallel, so
# PHASE 3 only RUNS binaries: the transcript stays in declaration order, and a
# build failure is a per-row FAIL carrying the build error — never a silently
# missing row.  THE SERIAL WARM-UP IS GONE (ZIGHOST Z6), and why it was there:
# the first build used to run ALONE because qbe-mk could rebuild the shared
# runtime object tools/qbe/rt.o (rt-o.sh -> `zig build-obj`), and two
# concurrent writes to that ONE path raced — after the serial build every
# parallel job found it fresh.  rt.o, rt-o.sh, hostshim.zig and every zig
# invocation are DELETED; what qbe-mk writes now all lives under the job's OWN
# outdir ($OUT/nat/<idx>/: <base>.ssa, <base>.s, <base>), run.js writes only
# the .ssa path it is handed (osier-compiler/run.js:488/529/550), and
# vendor/qbe/qbe is a prebuilt binary nothing writes.  There is no shared
# output path left, so every row goes straight into the pool.
{
  mkdir -p "$OUT/nat"
  : > "$OUT/nat.plan"
  for ((i=0;i<ncheck;i++)); do
    [ -n "${CNAT[$i]}" ] || continue
    mod="$(module_name "${CFIX[$i]}")"
    printf '%d|%s|%s.%s|%s\n' "$i" "${CNAT[$i]}" "$mod" "${CFN[$i]}" "$OUT/nat/$i" >> "$OUT/nat.plan"
  done
  cat > "$OUT/nat-one.sh" <<'EOJ'
#!/usr/bin/env bash
# One native build (spawned by the gate's PHASE 2.5 via xargs).
# $1 = "<idx>|<src...>|<Entry.key>|<outdir>".  Success writes the binary's
# path to <outdir>.binpath; failure leaves .builderr for the check to print.
IFS='|' read -r idx srcs entry outdir <<< "$1"
if bin="$("$OSIER_ROOT/tools/qbe/qbe-mk.sh" $srcs "$entry" "$outdir" 2>"$outdir.builderr")"; then
  printf '%s\n' "$bin" > "$outdir.binpath"
else
  rm -f "$outdir.binpath"
fi
EOJ
  chmod +x "$OUT/nat-one.sh"
  cp "$OUT/nat.plan" "$OUT/nat.jobs"
  # -r: an empty jobs file (only one native row) is legal, not an error.
  OSIER_ROOT="$ROOT" xargs -r -P "$NATJ" -I{} "$OUT/nat-one.sh" "{}" < "$OUT/nat.jobs" 2>/dev/null || :
}

# ============================ PHASE 3: checks ============================
dispatch() {
  local kind="$1" i="$2"
  local name fn exp args stdin fixfile outfile mod qname got out
  name="${CNAME[$i]}"; fn="${CFN[$i]}"; exp="${CEXP[$i]}"
  args="${CARG[$i]}"; stdin="${CSTDIN[$i]}"; fixfile="${CFIX[$i]}"; outfile="${COUT[$i]}"
  case "$kind" in
    cmp)
      if cmp -s "$FIX/out/$outfile" "$FIX/expected/$outfile.txt"; then
        echo "PASS $name out-file cmp"; pass=$((pass+1))
      else
        echo "FAIL $name out-file cmp: out/$outfile != expected/$outfile.txt"; fail=$((fail+1))
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
    natdepth)
      # See the natdepth helper: the out-of-stack check.  Builds its own
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
      # and NO value on stdout.  Same shell-stderr discipline as the retired
      # VM `depth` check had: the
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
      if [ "$past_rc" -ne 139 ]; then
        echo "FAIL $name $qname $past (past the 1MiB stack budget): exit $past_rc, want 139 (SIGSEGV — the SEGV net that used to print [$NAT_DEPTH_MSG] is DELETED at B4): $(head -c 200 "$OUT/$name.past.stderr" | tr '\n' ' ')"
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
      echo "PASS $name ($qname native: $ctl -> $exp @1MiB, $past -> SIGSEGV exit $past_rc, $deep -> $deep_exp @raised)"
      pass=$((pass+1))
      ;;
    natreject)
      # The loud-refusal row (see the intreject helper): the compile's error
      # payload must be an `err ` and must contain the expected text.
      mod=$(module_name "$fixfile")
      rel_fix="${fixfile#"$ROOT"/}"
      ( cd "$CDIR" && QBE_ENTRY="$mod.main" timeout 120 node run.js "$fixfile" "$OUT/$name.reject.ssa" >/dev/null 2>&1 )
      got="$(cat "$OUT/$name.reject.ssa" 2>/dev/null || true)"
      case "$got" in
        err*"$exp"*) echo "PASS $name: $got"; pass=$((pass+1));;
        *) echo "FAIL $name: expected err containing [$exp], got [$got]"; fail=$((fail+1));;
      esac
      ;;
    natproc)
      # The PROCESS-shaped native row (see the intproc helper): exit status and
      # the two streams compared SEPARATELY, so a row can pin a signal death.
      bin="$(cat "$OUT/nat/$i.binpath" 2>/dev/null || true)"
      if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        echo "FAIL $name (native build): $(head -c 200 "$OUT/nat/$i.builderr" 2>/dev/null || echo 'no build output')"
        fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      want_st="${exp%%|*}"
      rest="${exp#*|}"
      want_out="${rest%%|*}"
      want_err="${rest#*|}"
      ulimit -c 0 2>/dev/null || true
      exec 3>&2
      exec 2>"$OUT/$name.shellstderr"
      ( timeout 60 "$bin" "$qname" $args >"$OUT/$name.out" 2>"$OUT/$name.err" )
      got_st=$?
      exec 2>&3 3>&-
      got_out="$(cat "$OUT/$name.out")"
      # timeout(1) reports the CORE-DUMP bit on ITS OWN stderr ("the monitored
      # command dumped core").  The kernel sets WCOREDUMP for any death by a
      # coredump signal even under `ulimit -c 0`, so a row that pins a signal
      # death would otherwise be comparing timeout's notice, not the program's
      # stream.  Drop exactly that one line — timeout never writes any other.
      got_err="$(sed -e '/^timeout: the monitored command dumped core$/d' "$OUT/$name.err")"
      if [ "$got_st" = "$want_st" ] && [ "$got_out" = "$want_out" ] && [ "$got_err" = "$want_err" ]; then
        echo "PASS $name (native $qname $args) -> rc $got_st out[$got_out] err[$got_err]"; pass=$((pass+1))
      else
        echo "FAIL $name (native $qname $args): exp rc $want_st out[$want_out] err[$want_err], got rc $got_st out[$got_out] err[$got_err]"; fail=$((fail+1))
      fi
      ;;
    nat*)
      # The native row (P7; the ONLY execution model since P8): the binary
      # PHASE 2.5 built from this row's own sources must produce the pinned
      # expected value.  `timeout` guards the
      # run exactly like qbe-check.sh: a miscompile that loops must fail
      # loudly here, not wedge the gate.
      bin="$(cat "$OUT/nat/$i.binpath" 2>/dev/null || true)"
      if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        echo "FAIL $name (native build): $(head -c 200 "$OUT/nat/$i.builderr" 2>/dev/null || echo 'no build output')"
        fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      if [ "$kind" = natpipe ]; then
        # A SLOW PRODUCER, not a file: the pipe is empty on the first read, so
        # the readFile leaf suspends on EAGAIN and completes on the poll.  The
        # producer writes "he" at once and holds its end open >= 50 ms, so the
        # reader cannot see EOF before data (see `readpipe`'s header).
        got="$( ( printf 'he'; sleep 0.05; printf 'llo' ) | timeout 60 "$bin" "$qname" 2>&1)"
      elif [ "$kind" = natio ]; then
        got="$(timeout 60 "$bin" "$qname" < "$FIX/input/$stdin" 2>&1)"
      else
        got="$(timeout 60 "$bin" "$qname" $args 2>&1)"
      fi
      if [ "$got" = "$exp" ]; then
        echo "PASS $name (native $qname $args) -> $got"; pass=$((pass+1))
      else
        echo "FAIL $name (native $qname $args): exp[$exp] got[$got]"; fail=$((fail+1))
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
