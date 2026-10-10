#!/usr/bin/env bash
# qbe-selfhost.sh — P1: the QBE backend compiles the WHOLE compiler.
#
#   node run.js --batch (QBE=1 QBE_ENTRY=NativeMain.main) -> selfhost.ssa
#   vendor/qbe/qbe selfhost.ssa                            -> selfhost.s
#   cc selfhost.s tools/qbe/rt.o                           -> a NATIVE compiler
#   AOTRUN_ARGV=1 <native compiler> NativeMain.main <manifest> -> out.csexp
#   tools/selfhost-compile.sh (stock compiler, same sources)   -> ref.csexp
#   cmp out.csexp ref.csexp                                <- CSEXP FIXED POINT
#   AOTRUN_ARGV=1 <native compiler> NativeMain.main --ssa NativeMain.main <m> -> selfhost2.ssa
#   cmp selfhost2.ssa selfhost.ssa                         <- .ssa FIXED POINT
#
# THE POINT.  The self-host manifest NOW CONTAINS the `Mid/*` tier (75 sources,
# the QBE backend among them), so the compiler the QBE backend builds can emit
# QBE IL — `NativeMain`'s `--ssa <entry> <manifest>` mode drives
# `Mid.QbeModule.compileEntry`.  The two oracles together are the retirement
# claim, and BOTH are now about the CURRENT SOURCES rather than about a frozen
# artifact from a past tree: the stock (elm+node) compiler lowers the whole
# compiler to ONE QBE IL module; the vendored QBE backend and cc turn it into a
# native binary; that binary (a) reproduces the STOCK compiler's own csexp for
# these very sources — two compilers, one tree, one byte-identical whole-corpus
# bundle — AND (b) re-emits its OWN `.ssa`, byte-identical to the stock emit,
# the whole-corpus `.ssa` fixed point.  A byte-identity failure on EITHER is the
# most important possible finding — the script reports it and stops; it never
# adjusts the comparison.
#
# WHY (a) IS A FRESH REFERENCE AND NOT `tools/bootstrap/selfhost.csexp`.  The
# committed seed WAS the oracle, and that made the repo's strongest check a
# function of a frozen past artifact: `Mid/Qbe/Lower.elm` and
# `Mid/Qbe/Peephole.elm` are entries in $MANIFEST themselves, so ANY real change
# to the backend changes the compiled compiler and therefore the csexp.  The
# check would fail for a legitimate change and the only route back to green
# would be to RE-FREEZE THE SEED — i.e. to re-record whatever the tree now
# emits as "the truth".  Comparing two compilers built from one tree instead
# keeps the entire strength of the check (a whole-corpus byte identity over 75
# sources, on a binary the QBE backend itself produced) and removes the false
# failure, so the seed may drift harmlessly.
#
# This is the analogue of tools/selfhost-gate.sh for the QBE path (that one
# uses the AOT/zig driver, this one qbe+cc), and of tools/qbe/qbe-mk.sh for a
# single fixture.  The csexp milestone this reproduces was done BY HAND and its
# scripted form is the deliverable.
#
# Usage: tools/qbe/qbe-selfhost.sh
# Exit:  0 every oracle passed; 1 byte identity / determinism failed OR the emit
#        blew its wall-clock budget; 2 tooling failure (missing prerequisite,
#        emit produced an "err " payload).
#
# Oracles, in order (each printed):
#   0. each emit finishes inside QBE_SELFHOST_EMIT_BUDGET seconds (a quadratic
#      in the emit is a FINDING, and must not cost half an hour to discover);
#   1. the .ssa is emitted TWICE and the two are byte-identical (determinism);
#   2. vendor/qbe/qbe exits 0 and cc links a native compiler;
#   3. that compiler, run over the manifest, writes out.csexp;
#   4. cmp out.csexp <fresh csexp reference> -> exit 0 (CSEXP FIXED POINT): the
#      reference is `tools/selfhost-compile.sh`'s whole-corpus bundle, emitted by
#      the stock compiler from the SAME manifest in the same run (stage 1c).
#   5. that compiler, run over the manifest with `--ssa NativeMain.main`, writes
#      selfhost2.ssa; cmp selfhost2.ssa selfhost.ssa -> exit 0 (the `.ssa`
#      FIXED POINT: a compiler built from the .ssa re-emits its own .ssa).
# Per-stage wall clock is printed for every stage (emit / qbe / cc / run) so
# the later phases of the retire-the-VM plan have real numbers.
#
# MEASURED (this host, 2026-10-09, HEAD 1df8530; DEV-mode
# compiler.js, i.e. `elm make` without --optimize):
#   emit   27m01s  10,613,899-byte .ssa (the whole compiler, ONE group)
#   qbe      18.0s  32,977,198-byte .s
#   cc        3.3s  12,789,832-byte native compiler
#   run     269.3s  QBE_HEAP_MB=16384, writes the 1,466,335-byte bundle
#   (whole script 59m32s)
#
# AND THE SAME STAGES AFTER THE Peephole.elm:248 FIX, 2026-10-09 (the Set.union
# ARGUMENT FLIP in `usedInBlock`; before = the same tree, same manifest, same
# host, the flip reverted by rebuilding compiler.js):
#   emit       5.7s  PRE-FIX 1674.5s (re-measured, 10,613,899 B both, BYTE
#                    IDENTICAL) — 293x.  The 27 minutes were the QUADRATIC, not
#                    the frontend: `elm/core`'s Set.union iterates its FIRST
#                    argument (compiler.js:6861, `Dict.foldl insert t2 t1`), so
#                    `Set.union acc (readsTmps i)` in the dead-pure-defs
#                    FIXPOINT folded a 1-2 element set into the function's WHOLE
#                    accumulated temp set once per instruction.
#   qbe + cc + run   ~5 minutes, unchanged and untouched by the flip.
# Stage 1 used to dominate the script (~85%); it no longer does, so the
# headroom the budget below protects is now the difference between a ~6 s and a
# ~28 min script.  The pre-fix headline is retained above rather than reworded.
#
# Env:
#   QBE_HEAP_MB          GC heap in MB for the native compiler.  DEFAULT 32768
#                        (16384 — the value every pre-mid-tier whole-compiler
#                        run used — is recorded as panicking with heap
#                        exhaustion ONCE the manifest holds the 75-source
#                        middle tier: the corpus's live set grew past the
#                        16-GB heap's 32-GB reservation).
#                        This is a knob because the corpus's live set is
#                        multi-GB: too small a heap is a loud panic, not a
#                        wrong answer, but it still costs the run.
#   QBE_SELFHOST_BIN     where the native compiler lands
#                        (default zig-out/bin/qelmc; zig-out/ is gitignored).
#   QBE_SELFHOST_WORK    scratch dir to use instead of a fresh mktemp -d
#                        (kept on exit — for inspecting a failure).
#   QBE_SELFHOST_ENTRY   entry defun (default NativeMain.main).
#   QBE_SELFHOST_SSA      reuse an existing .ssa instead of emitting
#                        (SKIPS the emit AND the determinism oracle — for
#                        iterating on the qbe/cc/run half only).
#   QBE_SELFHOST_EMIT_BUDGET  wall-clock budget for ONE emit, in seconds.
#                        DEFAULT 60 — a ~10x multiple of the measured 5.7 s
#                        post-fix emit (wide enough for a loaded 32-core shared
#                        host) and ~28x below the 1674.5 s the pre-fix quadratic
#                        cost, so a re-introduced quadratic trips it in seconds
#                        instead of burning half an hour.  Raise it for a
#                        genuinely slower machine; it is a FINDING that fails
#                        the script (exit 1), not a warning.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Everything below resolves paths against the CWD: run.js reads manifest source
# paths against its process CWD, and NativeMain reads the fixed corpus from
# $ELMC_ROOT/elm-compiler (default "elm-compiler"), i.e. relative to the CWD.
# NOT running from the repo root yields a bogus `err parse failed` that looks
# like a compiler bug.
cd "$ROOT"

ENTRY="${QBE_SELFHOST_ENTRY:-NativeMain.main}"
HEAP_MB="${QBE_HEAP_MB:-32768}"
# One emit's wall-clock budget, in seconds (see the Env: note above).
EMIT_BUDGET="${QBE_SELFHOST_EMIT_BUDGET:-60}"
BIN="${QBE_SELFHOST_BIN:-$ROOT/zig-out/bin/qelmc}"
MANIFEST="$ROOT/elm-compiler/selfhost/manifest.json"
SEED="$ROOT/tools/bootstrap/selfhost.csexp"
RT="$ROOT/tools/qbe/rt.o"

say()  { printf '%s\n' "$*"; }
die()  { printf 'qbe-selfhost: %s\n' "$*" >&2; exit 2; }
# Per-stage wall clock, in seconds with millisecond resolution.
now()  { date +%s%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000000000 }'; }

# ---- the emit's wall-clock BUDGET (oracle 0) --------------------------------
# The emit was once a QUADRATIC: Peephole.elm's dead-pure-defs fixpoint wrote
# `Set.union acc (readsTmps i)`, and elm/core's Set.union ITERATES ITS FIRST
# ARGUMENT (compiler.js:6861 — `Dict.foldl insert t2 t1`), so every instruction
# folded a 1-2 element set into the function's whole accumulated temp set.  It
# cost 27 minutes per emit and nothing said so.  This is the check that was
# missing: without it the next such accident is discovered by a person waiting.
#
# An overrun is a FINDING about the TREE, so it exits 1 (like a byte-identity
# failure), not 2 (nothing is missing — the compiler is quadratic).  The
# baseline is printed with it so a reader can tell a real regression from a
# budget set too low.
check_emit_budget() { # $1 = seconds (string), $2 = which emit (label)
  if awk -v t="$1" -v b="$EMIT_BUDGET" 'BEGIN { exit !((t + 0) > (b + 0)) }'; then
    say "qbe-selfhost: EMIT BUDGET EXCEEDED — $2 took $1 s, budget $EMIT_BUDGET s" >&2
    say "   measured baseline (Peephole.elm:248 Set.union argument flip in place):" >&2
    say "     5.7 s for the whole-compiler emit — the default budget is ~10x that," >&2
    say "     and ~28x BELOW the 1674.5 s the pre-fix quadratic cost." >&2
    say "   A quadratic re-introduced in the emit looks exactly like this." >&2
    say "   If the host is simply slower, raise QBE_SELFHOST_EMIT_BUDGET=<secs>." >&2
    exit 1
  fi
}

# ---- scratch: mktemp -d + trap, never a fixed path a previous run left ----
CLEAN=1
if [ -n "${QBE_SELFHOST_WORK:-}" ]; then
  WORK="$QBE_SELFHOST_WORK"; CLEAN=0
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/qbe-selfhost.XXXXXX")" \
    || die "mktemp -d failed"
fi
if [ "$CLEAN" = 1 ]; then
  trap 'rm -rf "$WORK"' EXIT
else
  trap ':' EXIT
fi

# ---- preflight (fail loud, before anything expensive) ----
command -v node >/dev/null 2>&1 || die "node not found"
command -v jq   >/dev/null 2>&1 || die "jq not found"
command -v cc   >/dev/null 2>&1 || die "cc not found"
[ -f "$ROOT/elm-compiler/compiler.js" ] \
  || die "elm-compiler/compiler.js missing (run elm-compiler/build.sh once)"
[ -f "$MANIFEST" ] || die "manifest missing: $MANIFEST"

# THE COMMITTED SEED IS NO LONGER THIS SCRIPT'S ORACLE.  It used to be, and the
# comparison was a FROZEN PAST ARTIFACT: `Mid/Qbe/Lower.elm` and
# `Mid/Qbe/Peephole.elm` are themselves entries in $MANIFEST, so any real
# change to the backend changes the compiled compiler and therefore the csexp —
# the strongest check in the repo would fail for a LEGITIMATE change, and the
# only way back to green would be to re-freeze the seed.  That is exactly the
# temptation this re-pointing removes.  The oracle is now a FRESHLY COMPILED
# reference of the SAME CURRENT SOURCES (stage 1c, below), so a source change
# cannot break the check and the committed seed may drift harmlessly.
#
# The seed is a committed artifact `tools/bootstrap/PROVENANCE.md` and
# `tools/midtier-diff.sh` still pin, so this script REPORTS where it stands —
# never fails on it, and never fixes it.
if [ -s "$SEED" ] && [ -f "$SEED.sha256" ]; then
  if ( cd "$(dirname "$SEED")" && sha256sum -c --quiet "$(basename "$SEED").sha256" ); then
    say "qbe-selfhost: note: the committed seed still matches its sha256 — it is NOT the"
  else
    say "qbe-selfhost: NOTE: the committed seed no longer matches its recorded sha256." >&2
    say "qbe-selfhost:   That is EXPECTED once a manifest source moves, and it is NOT this" >&2
    say "qbe-selfhost:   script's oracle (see above). Do NOT re-freeze it as a 'fix'." >&2
  fi
  say "   oracle here (see above); it is only reported, so a manifest source cannot"
  say "   fail this script."
else
  say "qbe-selfhost: note: committed seed absent or unhashed — irrelevant, it is not the oracle"
fi

# One group exactly: this script's whole shape (one .ssa, one output) assumes
# it.  (NOT named GROUPS: that is a bash special variable holding the caller's
# group IDs, and an assignment to it is silently discarded — the check below
# then reads the user's gid instead of the manifest's group count.)
NGROUPS="$(jq '.groups | length' "$MANIFEST")"
[ "$NGROUPS" = 1 ] \
  || die "the selfhost manifest must have exactly one group (has $NGROUPS)"

# ---- the vendored backend (build it if it is not there) ----
QBE="$ROOT/vendor/qbe/qbe"
if [ ! -x "$QBE" ]; then
  say "qbe-selfhost: $QBE missing — building it (tools/qbe-build.sh)"
  "$ROOT/tools/qbe-build.sh" >&2 || die "qbe build failed"
fi

# ---- the runtime object (cached, freshness-invalidated) ----
# Verbatim the guard tools/qbe/qbe-mk.sh uses.  A cached rt.o answers only
# while NOTHING it was built from is newer than it; the probe must FAIL SAFE
# (if `find` errors, "no newer input" would silently reuse an rt.o built from
# different inputs — treat "cannot tell" as stale and rebuild), and a failed
# rebuild must refuse LOUDLY rather than answer from a stale object.  A stale
# rt.o is exactly this repo's documented stale-artifact class.
rt_newer="$(find "$ROOT/tools/qbe/rt.zig" "$ROOT/vendor/osier-rt/src" "$ROOT/src/effectloop.zig" \
              -newer "$RT" -print -quit 2>/dev/null)" || rt_newer="PROBE_FAILED"
if [ "$rt_newer" = "PROBE_FAILED" ]; then
  say "qbe-selfhost: rt.o freshness probe FAILED — rebuilding rather than trusting it" >&2
fi
if [ ! -f "$RT" ] || [ -n "$rt_newer" ]; then
  say "qbe-selfhost: building $RT (tools/qbe/rt.zig is newer than it)"
  zig build-obj -O ReleaseFast -lc -femit-bin="$RT" \
    --dep gc --dep rt --dep effectloop -Mroot="$ROOT/tools/qbe/rt.zig" \
    -Mgc="$ROOT/vendor/osier-rt/src/gc.zig" \
    --dep gc -Mrt="$ROOT/vendor/osier-rt/src/rt.zig" \
    --dep gc --dep rt -Meffectloop="$ROOT/src/effectloop.zig" \
    || die "rt.o rebuild FAILED — refusing to answer from a stale $RT"
fi

mkdir -p "$(dirname "$BIN")"

# ============================ 1. emit the .ssa ============================
# The manifest's OWN output path is zig-out/selfhost.csexp (the csexp batch
# output) — using it here would CLOBBER that path with QBE IL.  Every output
# is redirected into scratch for this reason; the compile only ever reads the
# sources.  (Stage 4 of the by-hand milestone re-paid exactly this.)
SSA="$WORK/selfhost.ssa"
t0=$(now)

emit_ssa() { # $1 = output path
  jq --arg out "$1" '.groups[0].output = $out' "$MANIFEST" > "$WORK/emit.json"
  ( cd "$ROOT" && QBE=1 QBE_ENTRY="$ENTRY" \
      node "$ROOT/elm-compiler/run.js" --batch "$WORK/emit.json" ) || return 1
  # run.js exits 0 on a compile error — the payload lands in the OUTPUT FILE.
  if head -c 4 "$1" | grep -q '^err '; then
    say "qbe-selfhost: emit FAILED: $(head -c 300 "$1")" >&2
    return 1
  fi
  [ -s "$1" ] || { say "qbe-selfhost: emit produced no output" >&2; return 1; }
}

if [ -n "${QBE_SELFHOST_SSA:-}" ]; then
  cp "$QBE_SELFHOST_SSA" "$SSA" || die "cannot read QBE_SELFHOST_SSA=$QBE_SELFHOST_SSA"
  say "== 1. emit: SKIPPED (reusing $QBE_SELFHOST_SSA) — determinism oracle NOT run"
  t_emit_a=$(now); t_emit_b="$t_emit_a"; determinism="NOT RUN"
else
  t0=$(now)
  emit_ssa "$SSA" || die "the stock compiler failed to emit the whole compiler as .ssa"
  t_emit_a=$(now)
  # Fail BEFORE paying for the second emit.
  check_emit_budget "$(secs "$t0" "$t_emit_a")" "the first emit"

  # ---- determinism: a second, independent emission must be byte-identical ----
  # If the .ssa is NOT deterministic, the seed story changes (a committed
  # .ssa cannot be a fixed point) — so this is reported as a finding, never
  # papered over.
  say "== 1b. emit again, for the determinism oracle"
  SSA_B="$WORK/selfhost-b.ssa"
  emit_ssa "$SSA_B" || die "the second emission failed"
  t_emit_b=$(now)
  check_emit_budget "$(secs "$t_emit_a" "$t_emit_b")" "the second emit"
  if cmp -s "$SSA" "$SSA_B"; then
    determinism="IDENTICAL"
  else
    determinism="DIFFERENT"
  fi
fi

# ---- 1c. THE FRESH REFERENCE: the SAME sources, the STOCK compiler ----
# `tools/selfhost-compile.sh` compiles the SAME $MANIFEST with the stock
# (elm+node) compiler to a csexp bundle at the manifest's own output path
# (zig-out/selfhost.csexp, a gitignored build product).  Snapshot it into
# scratch and compare against THAT: the oracle is now "the stock compiler and
# the QBE-built compiler agree on the CURRENT sources" — a byte-identity claim
# between two compilers built from one tree, instead of a claim about a frozen
# artifact from a past one.
say "== 1c. tools/selfhost-compile.sh (the fresh csexp reference, stock compiler)"
REF_SRC="$ROOT/zig-out/selfhost.csexp"
REF="$WORK/ref.csexp"
t_ref0=$(now)
"$ROOT/tools/selfhost-compile.sh" "$REF_SRC" || die "the stock compiler failed to emit the fresh csexp reference"
cp "$REF_SRC" "$REF" || die "cannot snapshot the fresh reference at $REF"
t_ref1=$(now)
say "   fresh reference: $(stat -c %s "$REF") bytes"

# ============================ 2. .ssa -> .s ============================
say "== 2. vendor/qbe/qbe $SSA -> $WORK/selfhost.s"
t1=$(now)
"$QBE" "$SSA" > "$WORK/selfhost.s"
qbe_rc=$?
t2=$(now)
[ "$qbe_rc" = 0 ] || die "qbe exited $qbe_rc"
[ -s "$WORK/selfhost.s" ] || die "qbe produced no output"

# ============================ 3. .s -> native compiler ============================
say "== 3. cc selfhost.s rt.o -> $BIN"
t3=$(now)
cc "$WORK/selfhost.s" "$RT" -o "$BIN" -lc
cc_rc=$?
t4=$(now)
[ "$cc_rc" = 0 ] || die "cc exited $cc_rc"
[ -x "$BIN" ] || die "cc produced no executable"

# ============================ 4. the native compiler compiles the compiler ============================
# The LINE manifest NativeMain consumes: one source per line, each group
# terminated by "-> <out>".  The output goes to SCRATCH — a batch compile
# writes to the output the manifest NAMES, so a manifest carrying the
# manifest's own output path clobbers a committed artifact.
RUN_MANIFEST="$WORK/run.manifest"
OUT="$WORK/out.csexp"
jq -r --arg out "$OUT" '.groups[] | (.sources[] | .), "-> \($out)"' \
  "$MANIFEST" > "$RUN_MANIFEST"

# AOTRUN_ARGV=1: the trailing args are NativeMain.main's *argv* (the app's
# command line), NOT call arguments — the same contract tools/bootstrap-compile.sh
# and tools/aot/run.zig install.  Note AOTRUN_QUIET=1 is passed for symmetry
# with those drivers but is a NO-OP here: rt.zig reads only AOTRUN_ARGV and
# QBE_HEAP_MB, so the driver's final model line still lands on stdout.  The
# oracle is the output FILE, never stdout and never a pipeline's `$?`.
say "== 4. AOTRUN_ARGV=1 QBE_HEAP_MB=$HEAP_MB $BIN $ENTRY <manifest>"
t5=$(now)
AOTRUN_ARGV=1 AOTRUN_QUIET=1 QBE_HEAP_MB="$HEAP_MB" \
  "$BIN" "$ENTRY" "$RUN_MANIFEST"
run_rc=$?
t6=$(now)
[ "$run_rc" = 0 ] || die "the native compiler exited $run_rc"
[ -s "$OUT" ] || die "the native compiler wrote no output to $OUT"
if head -c 4 "$OUT" | grep -q '^err '; then
  die "the native compiler FAILED: $(head -c 300 "$OUT")"
fi

# ============================ the oracle: the CSEXP FIXED POINT ============================
# The claim: the compiler the QBE backend builds, run over the manifest,
# reproduces what the STOCK compiler emits for the SAME CURRENT SOURCES.  Two
# compilers, one tree, one byte-identical whole-corpus bundle — no frozen
# artifact in the loop.
say "== 5. cmp $OUT $REF   (CSEXP FIXED POINT: QBE-built == stock, same sources)"
say "   $(sha256sum "$OUT" | cut -d' ' -f1)  out.csexp     ($(stat -c %s "$OUT") bytes)"
say "   $(sha256sum "$REF" | cut -d' ' -f1)  ref.csexp     ($(stat -c %s "$REF") bytes)"
if [ -s "$REF_SRC" ]; then
  say "   $(sha256sum "$REF_SRC" | cut -d' ' -f1)  tools/bootstrap/selfhost.csexp (NOT the oracle; reported only)"
fi

BOTH="FAIL"
cmp_rc=0
cmp "$OUT" "$REF" || cmp_rc=$?
if [ "$cmp_rc" = 0 ]; then
  BOTH="PASS"
fi

# ============================ 5. the .ssa FIXED POINT ============================
# The native compiler re-emits its OWN .ssa: `--ssa <entry> <manifest>` drives
# Mid.QbeModule.compileEntry (the same reachability+lower+peephole+print the
# stock emit used), so a compiler built from selfhost.ssa must reproduce
# selfhost.ssa byte-for-byte.  Same heap budget as the csexp run (the corpus
# pass dominates both).  Output goes to SCRATCH, never the manifest's own path.
SSA_MANIFEST="$WORK/run-ssa.manifest"
SSA_OUT="$WORK/selfhost2.ssa"
jq -r --arg out "$SSA_OUT" '.groups[] | (.sources[] | .), "-> \($out)"' \
  "$MANIFEST" > "$SSA_MANIFEST"

say "== 6. AOTRUN_ARGV=1 QBE_HEAP_MB=$HEAP_MB $BIN $ENTRY --ssa $ENTRY <manifest>"
t7=$(now)
AOTRUN_ARGV=1 AOTRUN_QUIET=1 QBE_HEAP_MB="$HEAP_MB" \
  "$BIN" "$ENTRY" --ssa "$ENTRY" "$SSA_MANIFEST"
ssa_rc=$?
t8=$(now)
[ "$ssa_rc" = 0 ] || die "the native compiler's --ssa run exited $ssa_rc"
[ -s "$SSA_OUT" ] || die "the native compiler wrote no .ssa to $SSA_OUT"
if head -c 4 "$SSA_OUT" | grep -q '^err '; then
  die "the native compiler's --ssa run FAILED: $(head -c 300 "$SSA_OUT")"
fi

say "== 7. cmp $SSA_OUT $SSA  (the .ssa fixed point)"
SSA_FP="FAIL"
ssa_cmp_rc=0
cmp "$SSA_OUT" "$SSA" || ssa_cmp_rc=$?
if [ "$ssa_cmp_rc" = 0 ]; then
  SSA_FP="PASS"
fi

# ============================ report ============================
say ""
say "qbe-selfhost: emit       $(secs "$t0" "$t_emit_a") s  ($(stat -c %s "$SSA") bytes .ssa)"
if [ "$determinism" != "NOT RUN" ]; then
  say "qbe-selfhost: emit(2)    $(secs "$t_emit_a" "$t_emit_b") s  -> $determinism"
fi
say "qbe-selfhost: qbe        $(secs "$t1" "$t2") s  ($(stat -c %s "$WORK/selfhost.s") bytes .s)"
say "qbe-selfhost: cc         $(secs "$t3" "$t4") s  ($(stat -c %s "$BIN") bytes native compiler)"
say "qbe-selfhost: run        $(secs "$t5" "$t6") s  (QBE_HEAP_MB=$HEAP_MB)"
say "qbe-selfhost: ssa-emit   $(secs "$t7" "$t8") s  ($(stat -c %s "$SSA_OUT") bytes .ssa)"
say "qbe-selfhost: determinism (--batch selfhost.ssa emitted twice): $determinism"
say "qbe-selfhost: CSEXP FIXED POINT (out.csexp == the fresh reference): $BOTH (cmp exit $cmp_rc)"
say "qbe-selfhost: .ssa FIXED POINT (selfhost2.ssa == selfhost.ssa): $SSA_FP (cmp exit $ssa_cmp_rc)"
[ "$CLEAN" = 1 ] || say "qbe-selfhost: scratch kept at $WORK"

# A nondeterministic .ssa is a FINDING (it changes the plan's seed story — a
# committed .ssa could not be a fixed point), not a flake to retry.
if [ "$determinism" = "DIFFERENT" ]; then
  say "qbe-selfhost: FINDING: the emitted .ssa is NOT deterministic — the two" >&2
  say "   emissions differ; the seed-as-.ssa option needs this answered first." >&2
  exit 1
fi
if [ "$BOTH" != "PASS" ]; then
  say "qbe-selfhost: CSEXP FIXED POINT FAILED (cmp exit $cmp_rc) — the QBE-built" >&2
  say "   compiler does NOT reproduce the STOCK compiler's output for these very" >&2
  say "   sources.  Reporting, not fixing." >&2
  exit 1
fi
if [ "$SSA_FP" != "PASS" ]; then
  say "qbe-selfhost: .ssa FIXED POINT FAILED (cmp exit $ssa_cmp_rc) — the" >&2
  say "   QBE-built compiler's OWN .ssa does NOT match the stock emit.  This is" >&2
  say "   the whole-corpus divergence the plan cannot proceed past.  Reporting." >&2
  exit 1
fi
say "qbe-selfhost: OK — the QBE-built compiler reproduces the stock compiler's csexp AND its own .ssa"
