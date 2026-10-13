#!/usr/bin/env bash
# qbe-check.sh — the stage-1 verification runner (native-backend slice).
#
# P7 (handoff osier-evidence): THE VM-vs-NATIVE DIFFERENTIAL IS GONE FROM THIS
# SCRIPT — replaced, while the VM still exists, by GOLDEN OUTPUTS HARVESTED
# FROM IT.  What the differential was: for every slice fixture, compile BOTH
# ways from the same source, run the SAME entry with the same args on the VM
# reference (an emitted csexp bundle) and on the native binary (emitted .ssa
# through vendored qbe + cc), and require IDENTICAL stdout.  That net — TWO backends,
# TWO value representations — caught the pre-fix float `0.0`, the argvPrimThunk
# arity bug, the TCO/closure bugs, and pinned the depth guard.  With the ZINC
# backend retired there is ONE backend, and a same-input backend disagreement
# on an unpinned shape becomes INVISIBLE: golden outputs are a REGRESSION net,
# not a differential.  They pin the shapes the VM verified on 2026-10-10 (the
# freeze run IS the differential's last execution: a golden is only written
# where native and VM agreed byte-for-byte).  The eventual restoration is the
# planned LUA backend — lua-vs-native would be a true differential again (two
# backends, two value representations, lua's own GC), and nothing here
# precludes adding it: run_golden()/run_io()/run_argv() compare against a
# value any correct backend must produce.
#
# The replacement checks, in strength order:
#   * GOLDEN: every slice fixture's native stdout must equal its frozen
#     golden (tools/qbe/golden/<name>.txt) — byte identity against the
#     VM-verified present, not against a live second engine.
#   * GC CHURN: rerun under a tiny QBE_HEAP_MB so the moving collector runs
#     constantly (the minimum viable heap, so every allocation pressure point
#     scavenges); output must still match the golden.  This is the behavioural
#     proof that the pooled-frame roots actually root (a promotion bug =
#     silently stale pointers, not a crash).
#   * ROOT STORES SURVIVE: grep the emitted .s for stores/loads through the
#     pooled frame pointer (%rbx = rt_frame_enter's result) around the
#     recursive callq sites — the structural counterpart of the behavioural
#     check (a future qbe that starts promoting would show as 0).
#   * TAIL: a cross-defun tail fixture (mutual recursion) must complete 1e6
#     hops — unbounded after the bounce loop (golden-pinned).
#   * CROSS-TARGET SMOKE: the emitted .ssa must also COMPILE through the
#     vendored qbe for arm64 and rv64 (-t).  The gate executes on the HOST
#     target only (amd64 here); this is the cheap half of the multi-target
#     claim — structurally portable, x86_64-MEASURED (see ARTIFACT.md).
#
# FREEZING.  The goldens are committed files (tools/qbe/golden/*.txt);
# re-freezing one is a deliberate edit of that file plus a commit message
# that says what moved and why (the corpus-baseline 8da6fd7 discipline).
#
#     tools/qbe/qbe-check.sh --freeze[=DIR]     (DIR default: tools/qbe/golden)
#
# writes every golden from the ONE backend's CURRENT output.  Read what that
# means before using it: the freeze-from-VM mode that originally wrote these
# (write-only-where-native-and-VM-agreed) died with the interpreter at P8, so
# NOTHING verifies a value being frozen — a freeze records what this tree
# prints today, not that it is right.  A golden is therefore a regression
# anchor ("this output did not change"), never independent evidence, and
# re-freezing discards the only thing it was holding.  A missing golden in
# compare mode is a FAIL, never an auto-freeze.
#
# Usage: tools/qbe/qbe-check.sh [--freeze[=DIR]]   (exit 0 = all checks pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Per-run scratch dir (mktemp, NOT a fixed path).  A fixed path persists across
# runs, so anything that reads it without rebuilding tests whatever the
# PREVIOUS run left behind: a stale pre-bounce binary was once reused here and
# the suite reported an old crash ceiling as a current measurement.  qbe-mk
# rebuilds its outputs on every call, but the checks that read an artifact
# WITHOUT rebuilding it first -- root-stores' fib.s, vfield-lowers' oos.ssa,
# the structural mutual-tail binary -- would otherwise answer from the last
# run's tree after a failed build.  rt.o, the one artifact meant to survive,
# lives in tools/qbe/ under qbe-mk's own freshness guard.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qbe-check.XXXXXX")" || {
  echo "qbe-check: mktemp failed" >&2
  exit 2
}
trap 'rm -rf "$TMP"' EXIT
FAIL=0

GOLDEN="$ROOT/tools/qbe/golden"

# ---- freeze mode (see FREEZING in the header) ------------------------------
FREEZE=0
FREEZE_DIR=""
case "${1:-}" in
  "")           ;;
  --freeze)     FREEZE=1 ;;
  --freeze=*)   FREEZE=1; FREEZE_DIR="${1#--freeze=}" ;;
  *) echo "qbe-check: unknown argument '$1' (usage: qbe-check.sh [--freeze[=DIR]])" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "qbe-check: at most one argument (usage: qbe-check.sh [--freeze[=DIR]])" >&2; exit 2; }
[ -z "$FREEZE_DIR" ] || GOLDEN="$FREEZE_DIR"
if [ "$FREEZE" = 1 ]; then
  mkdir -p "$GOLDEN" || { echo "qbe-check: cannot create golden dir $GOLDEN" >&2; exit 2; }
  echo "qbe-check: FREEZE MODE — writing goldens into $GOLDEN from the ONE backend." >&2
  echo "qbe-check:   nothing verifies a value being frozen (the second engine died at P8)," >&2
  echo "qbe-check:   so a golden pins 'the output did not change', not 'the output is right'." >&2
fi

# Fail loud before ~50 cryptic per-fixture mismatches: the native pipeline
# needs the vendored qbe and cc (rt.o is built by qbe-mk under its own
# freshness guard).  Nothing runs a VM anymore — the interpreter is deleted
# (P8) and this suite is single-backend by construction.
[ -x "$ROOT/vendor/qbe/qbe" ] || {
  echo "qbe-check: vendored qbe missing at $ROOT/vendor/qbe/qbe (run: tools/qbe-build.sh)" >&2
  exit 2
}
command -v cc >/dev/null 2>&1 || { echo "qbe-check: cc not found" >&2; exit 2; }
echo "qbe-check: artifacts in $TMP" >&2

# GC-churn heap, in MB: the minimum viable heap (MIN_HEAP_BYTES = 16MB,
# vendor/osier-rt/src/gc/heap.zig:61 — a literal 1 fails gc init), so every
# allocation-pressure point collects.  One definition: the rerun below and
# every message derive from this, so they cannot drift apart again.
CHURN_MB=16

# golden_read <name>: the pinned expected stdout for a row.  A MISSING golden
# is a FAIL (never an auto-freeze: a check that heals itself is not a check).
golden_read() {
  cat "$GOLDEN/$1.txt" 2>/dev/null || echo "__NO_GOLDEN__"
}

# fixture entry args...
run() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local nat_out
  # `timeout` guards the native run: bug-2 (clostail) is an infinite loop
  # when the closure self-tail miscompiles, and a regression must fail loudly
  # here rather than wedge the whole check script.
  nat_out="$(timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)"
  local exp
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the one backend's current output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt (a golden is frozen deliberately, in a commit that says why)"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: golden='$exp' native='$nat_out'"
    FAIL=1
    return
  fi
  # truncate: a fixture whose RESULT prints large (bigprint) would flood the
  # log; the comparison above is still on the full outputs.
  echo "PASS $name: golden (${nat_out:0:80})"

  # GC churn: CHURN_MB above (the minimum viable heap), so every
  # allocation-pressure point collects.
  # A fixture whose LIVE SET cannot fit it opts out by ending in "-nochurn".
  if [[ "$name" != *-nochurn ]]; then
  local churn_out
  churn_out="$(QBE_HEAP_MB=$CHURN_MB "$bin" "$entry" "${args[@]}" 2>&1)" || true
  if [ "$churn_out" != "$exp" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=$CHURN_MB): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=$CHURN_MB) identical"
  fi
  fi
}

# like run(), but QBE_MIDGC=1: the fixture compiles through the MID mark-sweep
# collector (the raw allocating nodes route to Rt.allocVector/Rt.allocRaw) and
# runs at the minimum heap, where the collector actually collects.  The golden
# is the value any correct backend must print — midgc-live's use-after-free
# shape (a live list survives the churn) and midgc-reclaim's leak shape
# (allocation >> heap must be observably reclaimed, else "midgc: out of
# memory" lands in the output and the comparison fails).
run_midgc() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$(QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk (QBE_MIDGC=1)"; FAIL=1; return
  }
  local nat_out exp
  nat_out="$(QBE_HEAP_MB=$CHURN_MB timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)" || true
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the Mid collector's current output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: midgc golden='$exp' native='$nat_out'"
    FAIL=1
  else
    echo "PASS $name: midgc (QBE_MIDGC=1 QBE_HEAP_MB=$CHURN_MB) identical (${nat_out:0:60})"
  fi
}

# like run_midgc(), but with QBE_NOSTRINGINTERN=1 in the runtime env: the
# zigretire stage-5 PART 4 STRING probe's hole is the rt_string FALLBACK, which
# fires on QBE_NOSTRINGINTERN=1 (and at run time once intern_live >= 2048).  A
# plain run_midgc row would intern the strings (rooted -> safe) and pass on the
# broken tree too, so the golden row must drive the flag.
run_midgc_nsi() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$(QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk (QBE_MIDGC=1)"; FAIL=1; return
  }
  local nat_out exp
  nat_out="$(QBE_HEAP_MB=$CHURN_MB QBE_NOSTRINGINTERN=1 timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)" || true
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the Mid collector's current output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: midgc golden='$exp' native='$nat_out'"
    FAIL=1
  else
    echo "PASS $name: midgc (QBE_MIDGC=1 QBE_NOSTRINGINTERN=1 QBE_HEAP_MB=$CHURN_MB) identical (${nat_out:0:60})"
  fi
}

# run_midgc_refusal — the QBE_MIDGC=1 REFUSAL row (zigretire stage 5 PART 5):
# the fixture MUST be refused at COMPILE time under QBE_MIDGC=1 (qbe-mk exits
# non-zero, the .ssa begins "err " and names `$expect` — the effect-loop seam
# "Runtime.program" for host-IO programs, or the refused prim (backtick-quoted,
# e.g. `str`) for the CENSUS arm).  This is the IN-TREE documented-fail row:
# the gate asserts the refusal rather than letting the program silently run to
# corruption under the hatch.
run_midgc_refusal() {
  local name="$1" entry="$2" fixture="$3" expect="$4"
  local out
  out="$TMP/$name-refusal"
  mkdir -p "$out"
  if QBE_MIDGC=1 "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$out" >/dev/null 2>&1; then
    echo "FAIL $name: QBE_MIDGC=1 compiled the program — the refusal (naming $expect) is missing"
    FAIL=1; return
  fi
  local ssa
  ssa="$out/$(basename "$fixture" .elm).ssa"
  if ! head -c 4 "$ssa" | grep -q '^err '; then
    echo "FAIL $name: QBE_MIDGC=1 failed but not with an 'err' refusal"
    FAIL=1; return
  fi
  if ! grep -q "$expect" "$ssa"; then
    echo "FAIL $name: the refusal does not name $expect"
    FAIL=1; return
  fi
  echo "PASS $name: QBE_MIDGC=1 refuses the program (names $expect)"
}

# run_midgc_io — the DEFAULT-path control for the host-IO fixture: with the Zig
# collector (no MIDGC) the kept string is rooted -> evacuated, not reclaimed,
# so the fixture prints the golden.  Proves the refusal did not change the
# default path.
run_midgc_io() {
  local name="$1" entry="$2" fixture="$3"
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk (default)"; FAIL=1; return
  }
  local nat_out exp
  nat_out="$(MIDGC_IO_IN="$ROOT/tools/qbe/fixtures/input/midgc-io.txt" QBE_HEAP_MB=$CHURN_MB timeout 60 "$bin" "$entry" 2>&1)"
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the default path's output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: golden='$exp' native='$nat_out'"
    FAIL=1
  else
    echo "PASS $name: default path golden (${nat_out:0:80})"
  fi
}

# like run(), but with AOTRUN_ARGV=1: the trailing args are the APP's *argv*
# pseudo-global (string list), NOT int call args — the selfhost CLI-driver
# contract.  Guards the argvPrimThunk arity bug (the class the old
# differential caught; now golden-pinned).
run_argv() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local args=("$@")
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local nat_out exp
  nat_out="$(timeout 60 env AOTRUN_ARGV=1 "$bin" "$entry" "${args[@]}" 2>&1)"
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the one backend's current output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: golden='$exp' native='$nat_out'"
    FAIL=1; return
  fi
  echo "PASS $name: golden (${nat_out:0:80})"
}

# ---- the slice fixtures (in-scope constructs only) ----
run fib        Fib.fib          tests/elm-fixtures/fib.elm 10
run fib20      Fib.fib          tests/elm-fixtures/fib.elm 20
run countdown  Countdown.countdown tests/elm-fixtures/countdown.elm 100000
run applytwice ApplyTwice.main  tests/elm-fixtures/applytwice.elm
run closure    Closure.main     tests/elm-fixtures/closure.elm
run const42    Const42.main     tools/qbe/fixtures/const42.elm
run idn        Idn.idn          tools/qbe/fixtures/idn.elm 7
run ifx        Ifx.main         tools/qbe/fixtures/ifx.elm
# churn: 150k conses = ~13.2MB live, just under the CHURN_MB minimum heap, so
# the gc-churn stress rerun collects/promotes constantly and still fits the
# reservation; 500k at the default heap is the identity run.
run churn      Churn.build      tools/qbe/fixtures/churn.elm 150000 0
run churnbig-nochurn Churn.build tools/qbe/fixtures/churn.elm 500000 0

# zigretire stage 4 — the Mid mark-sweep collector's memory-safety probes
# (QBE_MIDGC=1; the Zig collector stays the oracle and is untouched).  Two of
# the five probes the brief requires, chosen because they catch the two
# classes a mark-sweep cannot recover from: a USE-AFTER-FREE (midgc-live —
# a live list survives a collection) and a LEAK (midgc-reclaim — allocation
# >> heap must be observably reclaimed).  Each was proven fail-before /
# pass-after (the cons-mark arm and the free-list link removed in turn make
# the matching probe go red).
run_midgc midgc-live    MidgcLive.main    tools/qbe/fixtures/midgc-live.elm
run_midgc midgc-reclaim MidgcReclaim.main tools/qbe/fixtures/midgc-reclaim.elm
# zigretire stage 5 — the ADT-construction cross-heap probe: a Mid cons list
# whose elements are ADT constructors must share the MID heap (Rt.con).  The
# fail-before/pass-after asymmetry is scripted in tools/qbe/probe-midgc-adt.sh.
run_midgc midgc-adt     MidgcAdt.main     tools/qbe/fixtures/midgc-adt.elm
# zigretire stage 5 PART 2 — the CLOSURE and PARTIAL-APPLICATION cross-heap
# probes: a Mid cons list whose elements are closures-with-a-capture /
# partials must share the MID heap (Rt.closure / the rt.zig weak-extern
# bridge).  The fail-before/pass-after asymmetries are scripted in
# tools/qbe/probe-midgc-closure.sh and tools/qbe/probe-midgc-partial.sh.
run_midgc midgc-closure MidgcClosure.main tools/qbe/fixtures/midgc-closure.elm
run_midgc midgc-partial MidgcPartial.main tools/qbe/fixtures/midgc-partial.elm
# zigretire stage 5 PART 3 — the RECORD-construction cross-heap probe (the
# LAST live pointer-bearing Zig allocation): a Mid cons list whose elements
# are positional records, plus an open-row INSERT (dynamic names array) and a
# Record.remove, must all live in the MID heap.  The fail-before/pass-after
# asymmetry is scripted in tools/qbe/probe-midgc-record.sh.
run_midgc midgc-record MidgcRecord.main tools/qbe/fixtures/midgc-record.elm
# zigretire stage 5 PART 4 — the STRING-LITERAL cross-heap probe (the
# corrected-criterion hole: rt_string's Zig-nursery fallback, reachable only
# from Mid, reclaimed by the Zig scavenge).  Driven under QBE_NOSTRINGINTERN=1
# because the hole is the FALLBACK path.  The fail-before/pass-after asymmetry
# + the zero-rt_string-emission pin are scripted in tools/qbe/probe-midgc-string.sh.
run_midgc_nsi midgc-string MidgcString.main tools/qbe/fixtures/midgc-string.elm
# zigretire stage 5 PART 5 — THE OTHER HALF of the census refusal: a PURE
# program churning a >3-arg MUTUAL tail recursion must NOT corrupt.  The
# transient tail array (rt_tail_known's nargs>3 fallback, rt.zig:817) is a
# Zig-scavenge TRIGGER (tail_gcarray=3,000,000) but not itself live across a
# safepoint — so it is not a hole by itself.  The kept string is Mid-allocated
# (++ -> cn -> Rt.cn -> RawAllocRaw), so it is NOT reclaimable by the Zig
# collector and survives.  This is the probe that distinguishes THE TRIGGER
# from THE HOLE (the hole is the host-IO fixture, refused at compile time).
run_midgc midgc-tail MidgcTail.main tools/qbe/fixtures/midgc-tail.elm
# zigretire stage 5 PART 5 nice-to-have 4 — THE MID-RAW STRING MARKING PROBE:
# a concat/++-built (Rt.cn -> RawAllocRaw -> Mid) string kept across a MID
# COLLECT (the churn's 150k conses force the collector).  Every prior string
# fixture kept STATIC literals, whose mark is a no-op; this one makes gcMarkValue's
# tag-1 (data-pointer) marking falsifiable (verified: disabling that one mark
# prints "0|150" — the sweep reclaims the kept data bytes).
run_midgc midgc-rawstr MidgcRawstr.main tools/qbe/fixtures/midgc-rawstr.elm
# zigretire stage 5 PART 5 — THE HOST-IO CENSUS REFUSAL: a host-IO program
# (Io.readFile -> keeper -> 4-arg mutual tail churn) must be REFUSED under
# QBE_MIDGC=1 (its effect-loop seam builds Zig-nursery strings/conses the
# scavenge reclaims — the reproduced cross-heap hole), while its DEFAULT path
# prints the golden.  The fail-before/pass-after asymmetry is scripted in
# tools/qbe/probe-midgc-io.sh; this row re-asserts the refusal and the
# default-path golden in the gate.
run_midgc_refusal midgc-io MidgcIo.main tools/qbe/fixtures/midgc-io.elm 'Runtime.program'
run_midgc_io midgc-io MidgcIo.main tools/qbe/fixtures/midgc-io.elm
# zigretire stage 3 GROUP 2 — THE `str` CENSUS-ARM CLOSED: a PURE program whose
# census used to trip the `str` entry (String.fromFloat of NaN kept through a
# function boundary).  Since GROUP 2 routed `str` to the Mid body Rt.str (which
# renders the float into a GC string, not the Zig-nursery string primStr
# produced), the `str` entry left nurseryHostPrims and the program now COMPILES
# under QBE_MIDGC=1 and prints "100" — the kept "NaN" is Mid-allocated, so the
# churn's Zig scavenge cannot reclaim it.  This run_midgc row (plus the default
# `run` row below) pins BOTH arms: a reversion that re-adds the `str` refusal
# makes THIS row go red (refusal at compile time), and a Rt.str that still
# returned the nursery string makes it go red (prints "0").  The
# fail-before/pass-after asymmetry is scripted in tools/qbe/probe-midgc-str.sh.
run_midgc midgc-str MidgcStr.main tools/qbe/fixtures/midgc-str.elm
run midgc-str MidgcStr.main tools/qbe/fixtures/midgc-str.elm

# nice-to-have 9: a result whose printed form EXCEEDS the old 16384-byte print
# buffer (~24KB here).  Both runners stream now, so native and VM must agree
# at this size; before the fix native died with "print failed" and the VM with
# "error: WriteFailed".  Same shape as churn (the slice supports `::`).
run bigprint   BigPrint.build   tools/qbe/fixtures/bigprint.elm 2000 0

# ---- the four regression fixtures (the 22/22 suite was structurally blind
#      to these shapes; one per stage-1 review must-fix) ----
# bug 1: arity-2 self-tail whose accumulator is OBSERVABLE (the committed
# churn has this shape but returns 0, hiding the (n-1)::acc miscompile).
run selftail2  SelfTail2.build  tools/qbe/fixtures/selftail2.elm 3 0
# bug 4: a non-tail If (every fixture If was in tail position).
run nontailif  IfElse.main      tools/qbe/fixtures/nontailif.elm
# bug 2: a closure tail-calling its ENCLOSING defun (VM terminates; the
# miscompile was an in-frame loop of the closure = hang, hence `timeout`).
run clostail   ClosTail.main    tools/qbe/fixtures/clostail.elm 5
# bug 3: i64-boundary equality (32-bit ceqw was wrong on the full payload).
run eq64       Eq.eq            tools/qbe/fixtures/eq64.elm 4294967296 0

# ---- stage 2: pattern matching (Case / Con / match steps / LetDestruct) ----
# match: constructor patterns with sub-patterns, NESTED ctor patterns, a
# destructuring let (tuple pattern), ordered alts where order changes the
# result (Some 0 before Some _), int literal patterns + catch-all, and a Case
# inside a closure body — all summed into one observable number.
run match      Match.main       tools/qbe/fixtures/match.elm
# matchlit: literal patterns beyond Int — Bool, String, Char (a 1-char string),
# and a string literal inside a constructor sub-pattern (order matters).
run matchlit   MatchLit.main    tools/qbe/fixtures/matchlit.elm

# ---- stage 3: aggregates and literals (records / tuples / lists / bools) ----
# record: RecordLit read back by 3 fields in a DIFFERENT order + a nested
# record (fields -> 4312); RecordUpdate must be domain-preserving (upd returns
# the full updated assoc-list structure); main returns the record so the
# printed assoc-list ORDER is compared against the VM.
run record      Record.main     tools/qbe/fixtures/record.elm
run record-fields Record.fields tools/qbe/fixtures/record.elm
run record-upd  Record.upd      tools/qbe/fixtures/record.elm
run record-readupd Record.readUpd tools/qbe/fixtures/record.elm
# list: ListLit + MEmpty/MCons (stage 2's MEmpty, now fixture-able because
# `[]` lowers): fold a literal, match an empty literal, head/tail a literal.
run list        ListAgg.main    tools/qbe/fixtures/list.elm
# bool: ShortAnd/ShortOr where the RIGHT side is infinite self-recursion — it
# must NOT be evaluated (the `timeout` guard fails the run if it is) — and
# NotEqual on 5/6 vs 5/5.
run bool        Bool.main       tools/qbe/fixtures/bool.elm
# tup: a right-nested cons chain to and from a destructuring let, a 2-tuple
# (snd is a plain value), and a nested tuple pattern.
run tup         Tup.main        tools/qbe/fixtures/tup.elm
# utf8: non-ASCII string literals — UTF-8 byte length and byte identity
# (eq uses `==`'s byte compare; main returns the string for a print compare).
run utf8        Utf8.main       tools/qbe/fixtures/utf8.elm
run utf8-eq     Utf8.eq         tools/qbe/fixtures/utf8.elm
# aggchurn: a ListLit of 4 large lists (each ~2.6MB) built INLINE, so the
# collector runs DURING the outer list's construction while earlier elements
# are rooted — the partial-aggregate rooting hazard, under CHURN_MB below.
run aggchurn    AggChurn.main   tools/qbe/fixtures/aggchurn.elm

# ---- stage 4: arity > 8 (the old rt_callN table stopped at rt_call8) ----
# arity9: a 9-ary defun called DIRECTLY from the driver (rt_call9).  arity9apply:
# apply9 add9 -> f 1..9 where f is a Var, so the 9-ary call goes through
# rt_apply's saturation buffer (the generic/partial path the direct shape
# does not exercise).
run arity9      Arity9.add9     tools/qbe/fixtures/arity9.elm 1 2 3 4 5 6 7 8 9
run arity9apply Arity9.main9    tools/qbe/fixtures/arity9.elm

# ---- stage 5: record field patterns (VField) ----
# vfield-let: a destructuring let field pattern ({x,y} = p).  vfield-nested: a
# field pattern nested inside a ctor pattern (VField [IdxStep 1]).  vfield-mixed:
# a field-pattern alt alongside literal/wildcard/nullary alts in ONE case.
# vfield-rooted: a field-pattern value used ACROSS a 200000-cell allocation (the
# rooting path — under CHURN_MB below the collector runs while x is live).
run vfield-let    VField.letField   tools/qbe/fixtures/vfield.elm
run vfield-nested VField.nestedField tools/qbe/fixtures/vfield.elm
run vfield-mixed  VField.mixedCase  tools/qbe/fixtures/vfield.elm
run vfield-rooted VField.rootedField tools/qbe/fixtures/vfield.elm
run vfield-main   VField.main       tools/qbe/fixtures/vfield.elm

# ---- stage 5: the argv pseudo-global (found by the selfhost behavioural
#      run — no fixture used argv, so the suite was blind to it) ----
# argvPrimThunk was a 0-param Lam read as arity 0 but applied with 1 arg; the
# fix gives it a real 1-arg binder.  run_argv sets AOTRUN_ARGV=1 on BOTH
# runners (string list, not int args).
run_argv argvrepro-empty ArgvRepro.main tools/qbe/fixtures/argvrepro.elm
run_argv argvrepro-count ArgvRepro.count tools/qbe/fixtures/argvrepro.elm a b c d

# ---- stage 4: the effect loop (StreamRef) + host I/O (golden-pinned) ----
# io-read: read a file (QBE_IO_IN) and write a stdout sentinel through the
# StreamRef (*stoutput*) path.  io-write: write QBE_IO_OUT, read it back, AND
# compare the on-disk CONTENT (the write path itself, not just the round-trip).
# io-fail: a missing readFile (empty-string parity) plus a Task.fail ->
# Task.onError error path — the only failing effect in the host is an explicit
# Task.fail (leaf readFile completes "" on open failure by design).
IO_IN="$ROOT/tools/qbe/fixtures/io-read-input.txt"
IO_OUT="$TMP/io-write-out.txt"
run_io() {
  local name="$1" entry="$2" fixture="$3"
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local exp=""
  rm -f "$IO_OUT"
  local nat_out nat_file
  nat_out="$(timeout 60 env QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)"
  nat_file="$(cat "$IO_OUT" 2>/dev/null)"
  if [ "$FREEZE" = 1 ]; then
    printf '%s\n' "$nat_out" > "$GOLDEN/$name.txt"
    exp="$nat_out"
    echo "FROZE $name: golden <- the one backend's current output (${nat_out:0:80})"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: golden='$exp' native='$nat_out'"
    FAIL=1
    return
  fi
  echo "PASS $name: golden (${nat_out:0:80})"

  # gc churn: same env, minimum-viable heap
  local churn_out
  churn_out="$(QBE_HEAP_MB=$CHURN_MB QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)" || true
  if [ "$churn_out" != "$exp" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=$CHURN_MB): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=$CHURN_MB) identical"
  fi
}
run_io io-read   IoRead.main  tools/qbe/fixtures/io-read.elm
run_io io-write  IoWrite.main tools/qbe/fixtures/io-write.elm
run_io io-fail   IoFail.main  tools/qbe/fixtures/io-fail.elm
# the write path's on-disk bytes: both runs wrote IO_OUT, and both must equal
# the exact expected content (a round-trip read could hide a wrong write).
EXPECTED_IO="hello native
line2"
rm -f "$IO_OUT"
"$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/io-write.elm IoWrite.main "$TMP/io-write" >/dev/null 2>&1
QBE_IO_OUT="$IO_OUT" "$TMP/io-write/io-write" IoWrite.main >/dev/null 2>&1 || true
if [ "$(cat "$IO_OUT" 2>/dev/null)" = "$EXPECTED_IO" ]; then
  echo "PASS io-write-content: on-disk bytes match expected"
else
  echo "FAIL io-write-content: got '$(cat "$IO_OUT" 2>/dev/null)'"
  FAIL=1
fi
rm -f "$IO_OUT"

# ---- structural root-store check on fib's assembly ----
S="$TMP/fib/fib.s"
if [ -f "$S" ]; then
  # stores through the pooled frame pointer (%rbx holds rt_frame_enter's
  # result in fib's compiled body) that must survive around the two
  # recursive callq sites
  n=$(sed -n '/^q_Fib_x2efib:/,/end function q_Fib_x2efib/p' "$S" \
        | grep -c '(%rbx)')
  c=$(sed -n '/^q_Fib_x2efib:/,/end function q_Fib_x2efib/p' "$S" \
        | grep -c 'callq q_Fib_x2efib')
  if [ "$n" -ge 20 ] && [ "$c" -eq 2 ]; then
    echo "PASS root-stores: $n frame-pointer memory ops around $c recursive callq in fib.s"
  else
    echo "FAIL root-stores: only $n frame-pointer ops around $c calls (promotion?)"
    FAIL=1
  fi
else
  echo "FAIL root-stores: $S missing"
  FAIL=1
fi

# ---- the last loud-fail is GONE: a record field pattern now LOWERS ----
# VField was the final unsupported construct (rg -c 'Err "qbe:' Lower.elm == 0).
# This is a positive regression guard: `{ x } = { x = 1 }` must compile (no
# `err ` prefix) — if a future regression drops VField, this fails loudly.
printf 'module Oos exposing (main)\n\nmain =\n    let\n        { x } =\n            { x = 1 }\n    in\n    x\n' \
  > "$TMP/oos.elm"
# The compile's own status decides, not the old artifact's absence: with no
# build this run there is no oos.ssa, and "no err prefix in a missing file"
# must not read as a pass.
if (cd "$ROOT/elm-compiler" &&
      QBE=1 QBE_ENTRY=Oos.main node run.js "$TMP/oos.elm" "$TMP/oos.ssa") >/dev/null 2>&1 \
   && [ -f "$TMP/oos.ssa" ] \
   && ! head -c 4 "$TMP/oos.ssa" | grep -q '^err '; then
  echo "PASS vfield-lowers: record field pattern ({ x } = {x=1}) now lowers (no loud failure)"
else
  echo "FAIL vfield-lowers: record field pattern still fails loudly: $(head -c 200 "$TMP/oos.ssa" 2>/dev/null)"
  FAIL=1
fi

# ---- raw/unsafe node set (osier-rawnodes): the front end NEVER emits one ----
# Two TEXTUAL rows in the rg -c precedent shape (the `rg -c 'Err "qbe:' ==
# 0 full-construct-coverage pin).  The MECHANICAL seat is Mid.Audit, wired
# into Mid.QbeModule.lowerAll so every compile fails loudly on an Unsafe
# node outside Rt.*; its must-fail fixture is TestMain's audit rows (a
# violating tree is not producible from surface code, by construction).
# Row 1: the front end must not even NAME the raw surface — any `Unsafe`/`Raw`
# token in FromAst.elm is a front end that can emit one.
n="$(rg -c 'Unsafe|Raw' "$ROOT/elm-compiler/src/Mid/FromAst.elm" || true)"
if [ -z "$n" ]; then
  echo "PASS rawnodes-front-end: FromAst.elm names no Unsafe/Raw constructor (the front end cannot emit one)"
else
  echo "FAIL rawnodes-front-end: FromAst.elm mentions Unsafe/Raw $n time(s) — the front end must never touch the raw surface"
  FAIL=1
fi
# Row 2: the wiring pin — the audit must be CALLED on every compile, not
# merely exist (a seat never called is indistinguishable from an absent one).
n="$(rg -c 'Audit\.run' "$ROOT/elm-compiler/src/Mid/QbeModule.elm" || true)"
if [ "$n" = "1" ]; then
  echo "PASS rawnodes-audit-wired: Mid.QbeModule runs Mid.Audit on every compile"
else
  echo "FAIL rawnodes-audit-wired: QbeModule.elm calls Audit.run $n time(s), expected exactly 1 — the audit is not on the compile path"
  FAIL=1
fi

# ---- stage 6: FLATTEN (defun-local, escape-safe aggregate flattening) ----
# flatten.elm: every aggregate is built AND consumed in ONE defun, so the pass
# must delete the record representation entirely (assoc/snd/@p, plus the cons/
# emptylist chain they sit on).  noflatten.elm: structurally similar aggregates
# that all ESCAPE (returned, captured, passed, stored in a tuple that escapes,
# aliased, or a list pattern whose bind lands on the tail) — the pass must
# change NOTHING there.  Same source shapes, opposite outcomes.
run flatten   Flatten.main   tools/qbe/fixtures/flatten.elm
run noflatten NoFlatten.main tools/qbe/fixtures/noflatten.elm
# flatnest: patterns that walk PAST a component, where nothing is known about
# the value — the pass must DENY.  This is the fixture that reproduces the
# miscompile the selfhost run caught: a tag test whose path lands on a `Var`
# answered FALSE (a decided verdict about an unknown value), so BOTH real alts
# were skipped and the catch-all was selected — `Type/Exhaustive.unifyList`'s
# whole body became `Nothing`.  `zipPair` is that shape verbatim: the wrong
# answer is 999 instead of 1/31.
run flatnest  FlatNest.main  tools/qbe/fixtures/flatnest.elm

# ---- structural: an A/B on the SAME source.  QBE_NOFLATTEN=1 disables the
#      pass, so the two builds differ ONLY by it — which is the asymmetry
#      proof ("fails before, passes after"), and strictly sharper than an
#      absolute count, which a fixture change could quietly satisfy.
#
# prim_count <ssa> <prim-name>: the number of PRIM CALL SITES whose prim is
# <name>, in ANY emission form.  A prim site is one of
#   * Zig route  : `call $rt_prim_<mangled>(l ..., w n)`  — the name is in
#                 the SYMBOL, so it is demangled back (`_xHH` -> byte);
#   * Zig generic (pass-A OFF / arity 0 / arity > direct_arity):
#                 `call $rt_prim(l $d7, ...)` — the prim travels as a static
#                 data address, resolved from its `data $d7 = ... { b "assoc"
#                 }` definition;
#   * Mid route  : `call $q_Rt_<mangled>(` — POST-FLIP THE DEFAULT.  The
#                 seeded Rt program carries its OWN internal `call $q_Rt_*`
#                 edges (Rt.+ -> Rt.asF etc.) the moment it is seeded, so
#                 these sites count ONLY from defuns that are NOT q_Rt_*
#                 (the fixture's own code) — the same attribution rule
#                 primsdiff's exercise contract uses.  Without it every
#                 seeded program would count every prim it merely carries.
# All three are counted, so a structural row keeps measuring the SAME thing
# across the route hatch (counting only the Zig forms would have made every
# "the pass removed this prim" row pass for the wrong reason post-flip).  The
# demangler is a second, independent implementation of Mid.Qbe.Lower.mangle:
# if the emission side ever changes the mangling, these counters fall to 0
# and the rows FAIL.
prim_count() {
  awk -v want="$2" '
    function hexval(h,   j,c,v) {
      v=0
      for(j=1;j<=length(h);j++) { c=tolower(substr(h,j,1)); v=v*16+index("0123456789abcdef",c)-1 }
      return v
    }
    function demangle(s,   i,out) {
      out=""; i=1
      while (i <= length(s)) {
        if (substr(s,i,2)=="_x" && length(substr(s,i,4))==4) { out=out sprintf("%c",hexval(substr(s,i+2,2))); i+=4 }
        else { out=out substr(s,i,1); i+=1 }
      }
      return out
    }
    FNR==NR {
      l=$0; gsub(/[(),]/," ",l); n=split(l,f," ")
      nm=""
      for(i=1;i<=n;i++) if(f[i]=="b" && f[i+1] ~ /^"/) { nm=f[i+1]; gsub(/"/,"",nm) }
      if (nm != "") for(j=1;j<=n;j++) if(f[j] ~ /^\$d[0-9]+$/) { map[f[j]]=nm; break }
      next
    }
    /^function / { cur=$3; sub(/^\$/,"",cur) }
    {
      l=$0; gsub(/[(),]/," ",l); n=split(l,f," ")
      for(i=1;i<=n;i++) {
        if (f[i] !~ /^\$rt_prim/ && f[i] !~ /^\$q_Rt_/) continue
        if (f[i] == "$rt_prim") {
          for(j=i+1;j<=n;j++) if(f[j] ~ /^\$d[0-9]+$/) { if (map[f[j]]==want) c++; break }
        } else if (index(f[i],"$rt_prim_")==1) {
          if (demangle(substr(f[i],10)) == want) c++
        } else if (index(f[i],"$q_Rt_")==1 && cur !~ /^q_Rt_/) {
          # "$q_" is 3 chars; the rest is mangle("Rt." ++ prim), e.g.
          # $q_Rt_x2econs -> "Rt_x2econs" -> demangle -> "Rt.cons"
          if (demangle(substr(f[i],4)) == "Rt." want) c++
        }
      }
    }
    END { print c+0 }
  ' "$1" "$1"
}

# count an aggregate's presence: the Rt prims go through prim_count; the
# tag-14 RawMkValue (`storew 14`) is a raw instruction, so grep for it.
agg_count() {
  if [ "$2" = "storew 14" ]; then
    grep -c -- "storew 14" "$1"
  else
    prim_count "$1" "$2"
  fi
}

# compile one fixture entry to .ssa with the pass ON or OFF, via a SCRATCH
# output path (run.js writes to the path it is given; nothing here can clobber
# a tracked artifact).
qbe_ssa() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_NOFLATTEN=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  fi
}

# aggregate prims: any of these is a heap aggregate the pass exists to remove.
# Under E (positional records) the record heap object is the tag-14 RawMkValue
# (`storew 14`); tuples/lists stay cons/emptylist chains.
AGGPRIMS="storew 14
cons
emptylist"

qbe_ssa tools/qbe/fixtures/flatten.elm   Flatten.main   "$TMP/flat-on.ssa"  on
qbe_ssa tools/qbe/fixtures/flatten.elm   Flatten.main   "$TMP/flat-off.ssa" off
qbe_ssa tools/qbe/fixtures/noflatten.elm NoFlatten.main "$TMP/noflat-on.ssa"  on
qbe_ssa tools/qbe/fixtures/noflatten.elm NoFlatten.main "$TMP/noflat-off.ssa" off
qbe_ssa tools/qbe/fixtures/flatnest.elm  FlatNest.main  "$TMP/flatnest-on.ssa"  on
qbe_ssa tools/qbe/fixtures/flatnest.elm  FlatNest.main  "$TMP/flatnest-off.ssa" off

if [ -s "$TMP/flat-on.ssa" ] && [ -s "$TMP/flat-off.ssa" ]; then
  f_bad=0
  # (a) the POSITIVE direction: under E a record is a tag-14 positional
  #     vector, so the heap object Flatten deletes is the `storew 14`
  #     RawMkValue — gone with the pass, present without it.  cons/emptylist
  #     (tuples/lists) must not grow either.
  on=$(agg_count "$TMP/flat-on.ssa" "storew 14")
  off=$(agg_count "$TMP/flat-off.ssa" "storew 14")
  if [ "$on" -ne 0 ]; then
    echo "FAIL flatten-structural: 'storew 14' still emitted $on time(s) with the pass ON"
    f_bad=1
  elif [ "$off" -lt 1 ]; then
    echo "FAIL flatten-structural: 'storew 14' was ALREADY absent without the pass — fixture does not exercise it"
    f_bad=1
  fi
  for p in emptylist cons; do
    on=$(prim_count "$TMP/flat-on.ssa" "$p")
    off=$(prim_count "$TMP/flat-off.ssa" "$p")
    if [ "$on" -gt "$off" ]; then
      echo "FAIL flatten-structural: '$p' grew with the pass ON ($on > $off)"
      f_bad=1
    fi
  done
  if [ "$f_bad" -eq 0 ]; then
    echo "PASS flatten-structural: storew-14 $off->0 with the pass; cons/emptylist $(prim_count "$TMP/flat-off.ssa" cons)/$(prim_count "$TMP/flat-off.ssa" emptylist) -> $(prim_count "$TMP/flat-on.ssa" cons)/$(prim_count "$TMP/flat-on.ssa" emptylist)"
  else
    FAIL=1
  fi
else
  echo "FAIL flatten-structural: flatten .ssa missing (compile failed?)"
  FAIL=1
fi

if [ -s "$TMP/noflat-on.ssa" ] && [ -s "$TMP/noflat-off.ssa" ]; then
  # (b) the NEGATIVE direction: EVERY aggregate here escapes, so the pass must
  #     be a NO-OP — counted per prim, ON vs OFF, exactly.
  n_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    on=$(agg_count "$TMP/noflat-on.ssa" "$p")
    off=$(agg_count "$TMP/noflat-off.ssa" "$p")
    if [ "$on" -ne "$off" ]; then
      echo "FAIL noflatten-structural: '$p' changed under the pass ($off -> $on): an escaping aggregate was flattened"
      n_bad=1
    elif [ "$on" -lt 1 ]; then
      echo "FAIL noflatten-structural: '$p' is absent from the fixture — it does not exercise that escape route"
      n_bad=1
    fi
  done <<< "$AGGPRIMS"
  if [ "$n_bad" -eq 0 ]; then
    echo "PASS noflatten-structural: pass is a NO-OP on every escaping aggregate (storew-14 5, emptylist 3, cons 8 — identical ON/OFF)"
  else
    FAIL=1
  fi
else
  echo "FAIL noflatten-structural: noflatten .ssa missing (compile failed?)"
  FAIL=1
fi

if [ -s "$TMP/flatnest-on.ssa" ] && [ -s "$TMP/flatnest-off.ssa" ]; then
  # (c) UNDECIDABLE paths: `zipPair`'s alts test `[]` / `::` at a path that
  #     lands on a COMPONENT (`Var a`), which carries no structure, so the pass
  #     must leave the whole function ALONE.  `fn_body` prints the function's
  #     instructions with every static data symbol ($dN — the prim/error-name
  #     table) replaced by the NAME it refers to, because the pass shifts those
  #     INDICES without changing what they mean; comparing the raw text would
  #     fail on that shift alone.  This is the regression probe for the
  #     miscompile above, and it is sharper than a prim count: the failure mode
  #     was WRONG ALT SELECTION (the whole case collapsed to the catch-all),
  #     which a count of surviving prims does not see.
  fn_body() { # <ssa> <name-substring>
    awk -v want="$2" '
      FNR==NR {
        l=$0; gsub(/[(),]/," ",l); n=split(l,w," ")
        nm=""
        for(i=1;i<=n;i++) if(w[i]=="b" && w[i+1] ~ /^"/) { nm=w[i+1]; gsub(/"/,"",nm) }
        if (nm!="") for(j=1;j<=n;j++) if(w[j] ~ /^\$d[0-9]+$/) { map[w[j]]=nm; break }
        next
      }
      /^function / { infn = (index($0, want) > 0) }
      !infn { next }
      {
        line=$0
        sub(/^[ \t]+/, "", line)
        n=split(line, g, " ")
        for (i=1;i<=n;i++) {
          tok=g[i]; trail=""
          while (length(tok)>0 && (substr(tok,length(tok))=="," || substr(tok,length(tok))==")")) {
            trail=substr(tok,length(tok)) trail; tok=substr(tok,1,length(tok)-1)
          }
          if (tok in map) g[i]=(map[tok]) trail
        }
        out=""
        for (i=1;i<=n;i++) out=out g[i] " "
        print out
        if ($0 ~ /^\}$/) exit
      }
    ' "$1" "$1"
  }
  off_body="$(fn_body "$TMP/flatnest-off.ssa" zipPair)"
  on_body="$(fn_body "$TMP/flatnest-on.ssa" zipPair)"
  if [ -n "$on_body" ] && [ "$on_body" = "$off_body" ]; then
    echo "PASS flatnest-undecidable: zipPair unchanged with the pass ON (a tag test past a component does not decide)"
  else
    echo "FAIL flatnest-undecidable: zipPair changed under the pass — an undecidable tag test was decided"
    FAIL=1
  fi
  # ...and the pass must still FIRE on the decidable entries of the same
  # fixture, so the identity above cannot be satisfied by the pass not running.
  fn_on=$(prim_count "$TMP/flatnest-on.ssa" cons)
  fn_off=$(prim_count "$TMP/flatnest-off.ssa" cons)
  if [ "$fn_on" -lt "$fn_off" ]; then
    echo "PASS flatnest-decidable: cons $fn_off -> $fn_on (the decidable tuple/list scratch cases do flatten)"
  else
    echo "FAIL flatnest-decidable: the pass changed nothing on flatnest ($fn_off -> $fn_on) — the gate above is vacuous"
    FAIL=1
  fi
else
  echo "FAIL flatnest-undecidable: flatnest .ssa missing (compile failed?)"
  FAIL=1
fi

# ---- S4/M1 + S4f: UNBOXED Int AND Float LOCALS — the structural A/B ------
# The pass changes the REPRESENTATION of an Int local (a raw `l` operand) and
# of a Float local (a raw `d` operand) instead of a tagged 40-byte frame slot,
# and de-tags `+ - *` / `< <= > >=` / `=` when both operands are PROVEN Ints
# (i64) or both PROVEN Floats (QBE's `add`/`sub`/`mul`/`div` at type `d`, and
# the `ceqd`/`cltd`/... compare family).  QBE_NOREP=1 disables BOTH halves —
# one switch, both predicates read it — so the two builds of one source differ
# ONLY by it: the "fails before, passes after" asymmetry, and sharper than an
# absolute count a fixture edit could satisfy.
#
# THE COUNTERS, not the clock: a structural counter that does not move while
# the time does is the misattribution this project keeps catching, so the pass
# has to PROVE it acted on the code, in the .ssa.
#
# frame_slots <ssa>: the entry defun's frame-slot count, read off the .ssa's
# OWN account (`call $rt_frame_enter(w N)`).  The meta table roots only the
# requested entry, so the first one in the file is the entry's.
frame_slots() {
  sed -n 's/.*call \$rt_frame_enter(w \([0-9]*\)).*/\1/p' "$1" | head -1
}
# rtprim_sites <ssa>: PRIM CALL sites — the tag-test fallback the Int fast
# path exists to delete.  BOTH emission forms count (pass A's direct entries
# are `call $rt_prim_<name>(`, the generic one is `call $rt_prim(`), because
# what these rows measure is "how many prim calls does this defun still make",
# which must not change meaning when the CALL FORM changes.  The pass-A rows
# below split the two forms apart.
rtprim_sites() {
  # BOTH routes count: the Zig forms (`call $rt_prim` / `call $rt_prim_*`)
  # and the Mid route's `call $q_Rt_*` sites ATTRIBUTED to non-q_Rt_ defuns
  # (the seeded Rt program's internal edges are not the entry's prim calls —
  # without the attribution filter every seeded fixture would count every
  # prim it merely carries).  POST-FLIP the Mid form is what a DEFAULT build
  # emits.
  awk '
    /^function / { cur=$3; sub(/^\$/,"",cur) }
    /call \$rt_prim/ { c++ }
    /call \$q_Rt_/ && cur !~ /^q_Rt_/ { c++ }
    END { print c+0 }
  ' "$1"
}

# rtprim_generic_sites <ssa>: the GENERIC (`call $rt_prim(`) form alone.
rtprim_generic_sites() {
  grep -c 'call \$rt_prim(' "$1" || true
}

# primdirect_sites <ssa>: pass-A DIRECT (`call $rt_prim_<name>(`) sites alone.
primdirect_sites() {
  grep -c 'call \$rt_prim_' "$1" || true
}

# primdirect_arities <ssa>: the `w N` argument count of every DIRECT call
# site.  Pass A's runtime ABI is a fixed three pointer arguments plus this
# count (tools/qbe/rt.zig Direct), so a site outside 1..3 would hand the
# wrapper a count it refuses or a pointer it never got — this is the static
# half of that contract.
primdirect_arities() {
  sed -n 's/.*call \$rt_prim_[A-Za-z0-9_]*(.*, w \([0-9]*\)).*/\1/p' "$1"
}
qbe_ssa_rep() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_NOREP=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  fi
}
for pair in slotCount:slot chain:chain capture:cap polyLocal:poly boxed:box floatLocal:float floatParam:floatp floatCapture:floatc; do
  e="${pair%%:*}"; n="${pair##*:}"
  qbe_ssa_rep tools/qbe/fixtures/norep.elm "NoRep.$e" "$TMP/norep-$n-on.ssa"  on
  qbe_ssa_rep tools/qbe/fixtures/norep.elm "NoRep.$e" "$TMP/norep-$n-off.ssa" off
done
# pass A DELETES the per-call staging block, so it deletes FRAME SLOTS too
# (stageSlots reserves one slot per argument, per call).  The FIXTURE-STRENGTH
# guards below are thresholds on "how many frame slots does this entry reserve
# WITHOUT the pass being checked" — a quantity pass A itself moves.  So the
# guard is measured on the emitter pass A REPLACED (both passes off), while
# every asymmetry above/below stays on the ordinary ON/OFF pair.  Measuring it
# on the pass-A build would silently weaken a guard instead of preserving it.
# <fixture> <entry> <out.ssa> — BOTH passes off, so the frame-slot count is
# the one the pre-pass-A emitter produced for the same entry.
# POST-FLIP (osier-flip): this build additionally selects the ZIG ROUTE
# (QBE_MIDZIG=1) — the guard is calibrated to the PRE-PASS-A ZIG emitter's
# slot count, and the flip's default (Mid) route stages FEWER slots per prim
# call (MEASURED: floatLocal 23 slots Zig-route vs 15 Mid-route), which would
# silently weaken the fixture-strength bound.
qbe_ssa_norep_offpd() {
  (cd "$ROOT/elm-compiler" && QBE=1 QBE_MIDZIG=1 QBE_NOREP=1 QBE_NOPRIMDIRECT=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
}

if [ -s "$TMP/norep-slot-on.ssa" ] && [ -s "$TMP/norep-slot-off.ssa" ]; then
  s_on=$(frame_slots "$TMP/norep-slot-on.ssa")
  s_off=$(frame_slots "$TMP/norep-slot-off.ssa")
  qbe_ssa_norep_offpd tools/qbe/fixtures/norep.elm NoRep.slotCount "$TMP/norep-slot-offpd.ssa"
  s_off_pd=$(frame_slots "$TMP/norep-slot-offpd.ssa")
  p_on=$(rtprim_sites "$TMP/norep-slot-on.ssa")
  p_off=$(rtprim_sites "$TMP/norep-slot-off.ssa")
  # NoRep.slotCount is 16 chained Int locals over one Int param: without the
  # pass each takes a slot and each `+` a tag test + an rt_prim fallback.
  if [ "$s_off_pd" -lt 16 ]; then
    echo "FAIL norep-structural: slotCount reserved only $s_off_pd slots without the pass (both passes off) — the fixture does not exercise 16 locals"
    FAIL=1
  elif [ "$s_on" -ge "$s_off" ]; then
    echo "FAIL norep-structural: slotCount frame slots did NOT drop ($s_off -> $s_on): no local was unboxed"
    FAIL=1
  elif [ "$p_on" -ne 0 ]; then
    echo "FAIL norep-structural: $p_on rt_prim site(s) survive with the pass ON — the tag test was not removed"
    FAIL=1
  elif [ "$p_off" -lt 15 ]; then
    echo "FAIL norep-structural: only $p_off rt_prim site(s) without the pass — the fixture does not exercise the tagged arith"
    FAIL=1
  else
    echo "PASS norep-structural: slotCount frame slots $s_off -> $s_on, rt_prim sites $p_off -> $p_on"
  fi

  # the IR half of the type source: `NoRep.polyTwice` is POLYMORPHIC
  # ((a -> a) -> a -> a), so the checker's monotype gate yields NOTHING inside
  # it — if the rt_prim sites there do not drop, the pass is only reaching
  # monotype defuns and this half is untested.
  pp_on=$(rtprim_sites "$TMP/norep-poly-on.ssa")
  pp_off=$(rtprim_sites "$TMP/norep-poly-off.ssa")
  if [ "$pp_on" -lt "$pp_off" ]; then
    echo "PASS norep-structural: a POLYMORPHIC defun's Int locals are unboxed too (rt_prim $pp_off -> $pp_on)"
  else
    echo "FAIL norep-structural: polyTwice rt_prim did not drop ($pp_off -> $pp_on) — only monotype defuns are reached"
    FAIL=1
  fi

  # the FLOAT half (S4f): `NoRep.floatLocal`'s Float locals are seeded by
  # float LITERALS, so they are proven from the tree and must be unboxed.  The
  # asymmetry here is the INVERSE of the deny control below: this .ssa MUST
  # differ with the pass on and off.  If it does not, the Float half is not
  # working — that is the flip this unit was built to produce, not a check to
  # be adjusted until it passes.
  fl_on=$(rtprim_sites "$TMP/norep-float-on.ssa")
  fl_off=$(rtprim_sites "$TMP/norep-float-off.ssa")
  fs_on=$(frame_slots "$TMP/norep-float-on.ssa")
  fs_off=$(frame_slots "$TMP/norep-float-off.ssa")
  qbe_ssa_norep_offpd tools/qbe/fixtures/norep.elm NoRep.floatLocal "$TMP/norep-float-offpd.ssa"
  fs_off_pd=$(frame_slots "$TMP/norep-float-offpd.ssa")
  if cmp -s "$TMP/norep-float-on.ssa" "$TMP/norep-float-off.ssa"; then
    echo "FAIL norep-float-fired: floatLocal .ssa is BYTE-IDENTICAL on and off — the Float locals were NOT unboxed"
    FAIL=1
  elif [ "$fs_off_pd" -lt 16 ]; then
    echo "FAIL norep-float-fired: floatLocal reserved only $fs_off_pd slots without the pass (both passes off) — the fixture does not exercise the float locals"
    FAIL=1
  elif [ "$fs_on" -ge "$fs_off" ]; then
    echo "FAIL norep-float-fired: floatLocal frame slots did NOT drop ($fs_off -> $fs_on): no Float local was unboxed"
    FAIL=1
  elif [ "$fl_on" -ge "$fl_off" ]; then
    echo "FAIL norep-float-fired: floatLocal rt_prim did NOT drop ($fl_off -> $fl_on): the tag test was not removed"
    FAIL=1
  else
    echo "PASS norep-float-fired: floatLocal .ssa DIFFERS ON/OFF, frame slots $fs_off -> $fs_on, rt_prim sites $fl_off -> $fl_on"
  fi

  # the FLOAT DENY control, and the MEASURED reason it exists:
  # `NoRep.floatParam` is the SAME chain seeded by the Float PARAMETER instead
  # of by literals.  A Float parameter is not a raw source (an integer token
  # the checker typed Float is materialized as `tagNumber` by this front end
  # while the VM PROMOTES it), so this entry must be left ALONE — byte
  # identical, counters equal.  Paired with the firing check above (same
  # fixture, same pipeline), so the identity cannot be satisfied by the pass
  # not running at all.
  fp_on=$(rtprim_sites "$TMP/norep-floatp-on.ssa")
  fp_off=$(rtprim_sites "$TMP/norep-floatp-off.ssa")
  fsp_on=$(frame_slots "$TMP/norep-floatp-on.ssa")
  fsp_off=$(frame_slots "$TMP/norep-floatp-off.ssa")
  if cmp -s "$TMP/norep-floatp-on.ssa" "$TMP/norep-floatp-off.ssa" &&
    [ "$fsp_on" = "$fsp_off" ] && [ "$fp_on" = "$fp_off" ] && [ "$fp_off" -ge 3 ]; then
    echo "PASS norep-float-denied: floatParam .ssa byte-identical ON/OFF ($fsp_off slots, $fp_off rt_prim sites) — a Float PARAMETER is not a raw source"
  else
    echo "FAIL norep-float-denied: floatParam changed under the pass ($fsp_off->$fsp_on slots, $fp_off->$fp_on rt_prim) — a Float parameter was read raw, which is a silent wrong answer"
    FAIL=1
  fi

  # the capture boundary: a raw float escaping into a closure goes through
  # `captureBlits`, the one boundary that does not pass through `lowerVal`.
  # Its own rebox must fire (rt_prim drops) while the capture slot itself
  # remains (the slot count is expected NOT to move here).
  fc_on=$(rtprim_sites "$TMP/norep-floatc-on.ssa")
  fc_off=$(rtprim_sites "$TMP/norep-floatc-off.ssa")
  if cmp -s "$TMP/norep-floatc-on.ssa" "$TMP/norep-floatc-off.ssa"; then
    echo "FAIL norep-float-capture: floatCapture .ssa byte-identical ON/OFF — the raw float did not reach the capture rebox"
    FAIL=1
  elif [ "$fc_on" -lt "$fc_off" ]; then
    echo "PASS norep-float-capture: floatCapture .ssa differs, rt_prim $fc_off -> $fc_on (a raw float is reboxed into its capture slot)"
  else
    echo "FAIL norep-float-capture: floatCapture rt_prim did not drop ($fc_off -> $fc_on)"
    FAIL=1
  fi

  # ...and the pass must FIRE on the entries it does claim, so the identity
  # above cannot be satisfied by the pass not running at all.
  c_on=$(rtprim_sites "$TMP/norep-chain-on.ssa")
  c_off=$(rtprim_sites "$TMP/norep-chain-off.ssa")
  if [ "$c_off" -ge 6 ] && [ "$c_on" -eq 0 ]; then
    echo "PASS norep-fired: chain rt_prim $c_off -> $c_on (the fixture does exercise the pass)"
  else
    echo "FAIL norep-fired: chain rt_prim $c_off -> $c_on — the fixture does not exercise the pass"
    FAIL=1
  fi
else
  echo "FAIL norep-structural: norep .ssa missing (compile failed?)"
  FAIL=1
fi

# ---- S5/M2: MONOMORPHISATION (tools/qbe/fixtures/mono.elm, monorefuse.elm) --
# The specialiser CLONES a polymorphic defun at the instantiations its
# saturated direct call sites use (QBE_NOMONO=1 disables it, on the SAME
# source).  Two things must hold, and neither is a clock:
#
#   * the MECHANISM: a clone lands in the type table as a CLOSED MONOTYPE, so
#     S4/M1's `intParamsOf` can prove its parameters and the tag tests and
#     `q_Rt_*` fallbacks INSIDE the clone disappear.  The counters below are
#     per-FUNCTION, read out of the emitted .ssa by symbol, because a global
#     site count would be satisfied by the original defun simply falling out of
#     reachability;
#   * the REFUSAL: a site whose instantiation is unclosed (a), rigid (b) or
#     refinement-touched (c) must NOT be cloned, and the pass's own note line
#     (`# mono: candidates=... refused_b=...`) is what distinguishes "refused"
#     from "never looked at".  Each refusing entry's .ssa must then be
#     BYTE-IDENTICAL to its QBE_NOMONO=1 arm once the note line is removed —
#     the pass saw the site and changed nothing else.
#
# The note is emitted IFF the pass made any decision, which is also what makes
# `mono-inert` a real check: an entry with no candidate at all must be
# byte-identical INCLUDING its first line.
qbe_ssa_mono() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_NOMONO=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  fi
}
# mono_note <ssa>: the pass's one-line report ("" when it decided nothing).  A
# mangle-escaped `$` in a symbol is `_x24`, and only a clone key can contain
# one, so `_x24` is the clone marker (a surface identifier cannot contain `$`).
mono_note() {
  sed -n 's/^# mono: //p' "$1" | head -1
}
# mono_field <ssa> <key>: one counter out of that line.
mono_field() {
  printf '%s\n' "$(mono_note "$1")" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}
mono_clones() {
  grep -c '^function :ret \$[A-Za-z0-9_]*_x24' "$1" || true
}
# num <str>: a counter as an INTEGER. An empty or non-numeric capture becomes
# 0 so a comparison can never pass just because a helper failed (an empty
# string tests as 0 in `[ ... -lt ...]`, which is how a broken probe reads as a
# green row).
num() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}
# mono_fn_prim <ssa> <name-regex>: `rt_prim`/`q_Rt_*` CALL SITES inside the
# functions whose emitted symbol matches the regex.
mono_fn_prim() {
  awk -v re="$2" '
    /^function |^export function / {
      n=$0; sub(/^.*\$/, "", n); sub(/\(.*/, "", n); cur=n
    }
    cur ~ re && $0 ~ /call \$(rt_prim|q_Rt_)/ { c++ }
    END { print c+0 }
  ' "$1"
}

# mono_fn_sym <ssa> <name-regex> <call-substring>: the call sites to ONE
# runtime symbol inside those functions — the sharpest form of the mechanism
# claim ("this fallback is gone from the clone and still present in the
# polymorphic original").
mono_fn_sym() {
  awk -v re="$2" -v sym="$3" '
    /^function |^export function / {
      n=$0; sub(/^.*\$/, "", n); sub(/\(.*/, "", n); cur=n
    }
    cur ~ re && $0 ~ /call / && index($0, sym) > 0 { c++ }
    END { print c+0 }
  ' "$1"
}
qbe_ssa_mono tools/qbe/fixtures/mono.elm Mono.main "$TMP/mono-main-on.ssa" on
qbe_ssa_mono tools/qbe/fixtures/mono.elm Mono.main "$TMP/mono-main-off.ssa" off
# the FIRING entry: two clones (fib at Int, foldPair at Int), and the clone's
# own body must have LOST the arithmetic fallbacks while the still-polymorphic
# original keeps them.
if [ -s "$TMP/mono-main-on.ssa" ] && [ -s "$TMP/mono-main-off.ssa" ]; then
  mn_on=$(num "$(mono_clones "$TMP/mono-main-on.ssa")")
  mn_off=$(num "$(mono_clones "$TMP/mono-main-off.ssa")")
  # the clone marker in the OFF arm would mean the pass ran with the hatch on.
  cp_on=$(num "$(mono_fn_prim "$TMP/mono-main-on.ssa" 'x2efib_x24')")
  cp_off=$(num "$(mono_fn_prim "$TMP/mono-main-off.ssa" 'x2efib_x24')")
  # the original `fib` — kept by clone-do-not-replace, because its own
  # recursive calls are instantiated at its own type variables and refused.
  # `mono_fn_prim` strips the parameter list, so the original's symbol is
  # exactly this name while a clone's carries the `_x24` suffix.
  fp_on=$(num "$(mono_fn_prim "$TMP/mono-main-on.ssa" '^q_Mono_x2efib$')")
  fp_off=$(num "$(mono_fn_prim "$TMP/mono-main-off.ssa" '^q_Mono_x2efib$')")
  if [ "$mn_off" -ne 0 ]; then
    echo "FAIL mono-hatch: $mn_off clone function(s) in the QBE_NOMONO=1 arm — the hatch does not restore the pre-S5 emission"
    FAIL=1
  elif [ "$mn_on" -lt 2 ]; then
    echo "FAIL mono-fired: only $mn_on clone(s) with the pass on — fib/foldPair were not specialised"
    FAIL=1
  elif [ "$cp_off" -ne 0 ] || [ "$fp_off" -lt 3 ]; then
    echo "FAIL mono-fired: OFF arm counters look wrong (clone sites $cp_off, original fib rt_prim $fp_off)"
    FAIL=1
  elif [ "$cp_on" -ge "$fp_on" ]; then
    echo "FAIL mono-fired: the clone did not lose its fallbacks ($cp_on vs the original's $fp_on)"
    FAIL=1
  elif [ "$fp_on" -lt 3 ]; then
    echo "FAIL mono-fired: the ORIGINAL fib lost sites too ($fp_on) — clone-do-not-replace did not hold"
    FAIL=1
  else
    # the specific fallbacks: `<` and `-` must be GONE from the clone (their
    # operands are the INT parameter, which the clone's monotype entry proves)
    # and still present in the polymorphic original, which nothing can prove.
    cl_lt=$(num "$(mono_fn_sym "$TMP/mono-main-on.ssa" 'x2efib_x24' '$q_Rt_x2e_x3c')")
    cl_sub=$(num "$(mono_fn_sym "$TMP/mono-main-on.ssa" 'x2efib_x24' '$q_Rt_x2e_x2d')")
    og_lt=$(num "$(mono_fn_sym "$TMP/mono-main-on.ssa" '^q_Mono_x2efib$' '$q_Rt_x2e_x3c')")
    og_sub=$(num "$(mono_fn_sym "$TMP/mono-main-on.ssa" '^q_Mono_x2efib$' '$q_Rt_x2e_x2d')")
    if [ "$cl_lt" -ne 0 ] || [ "$cl_sub" -ne 0 ] || [ "$og_lt" -lt 1 ] || [ "$og_sub" -lt 2 ]; then
      echo "FAIL mono-fired: the clone still calls the tag-test fallback (< $cl_lt, - $cl_sub) or the original lost it (< $og_lt, - $og_sub)"
      FAIL=1
    else
      echo "PASS mono-fired: $mn_on clones ON / $mn_off OFF; clone rt_prim $cp_on vs original $fp_on, clone's < / - fallbacks $cl_lt/$cl_sub vs the original's $og_lt/$og_sub"
    fi
  fi
  # the note line is the pass's own account, and it must AGREE with the .ssa.
  mn_cand=$(num "$(mono_field "$TMP/mono-main-on.ssa" candidates)")
  if [ "$mn_cand" -ge "$mn_on" ] && [ "$mn_on" -ge 2 ]; then
    echo "PASS mono-note: candidates=$mn_cand clones=$(mono_field "$TMP/mono-main-on.ssa" clones) converted=$(mono_field "$TMP/mono-main-on.ssa" converted) untyped=$(mono_field "$TMP/mono-main-on.ssa" untyped)"
  else
    echo "FAIL mono-note: the note line disagrees with the emitted clones (candidates=$mn_cand, clones=$mn_on)"
    FAIL=1
  fi
else
  echo "FAIL mono-fired: mono .ssa missing (compile failed?)"
  FAIL=1
fi

# the REFUSAL entries: each must report its clause in the note AND leave the
# emitted code alone (byte-identical once the note line is dropped).
mono_refuse_row() { # <name> <entry> <key>
  qbe_ssa_mono tools/qbe/fixtures/monorefuse.elm "MonoRefuse.$2" "$TMP/mr-$1-on.ssa" on
  qbe_ssa_mono tools/qbe/fixtures/monorefuse.elm "MonoRefuse.$2" "$TMP/mr-$1-off.ssa" off
  if [ ! -s "$TMP/mr-$1-on.ssa" ] || [ ! -s "$TMP/mr-$1-off.ssa" ]; then
    echo "FAIL mono-refuse-$1: .ssa missing (compile failed?)"
    FAIL=1
    return
  fi
  local n_clones n_key n_cand
  n_clones=$(num "$(mono_clones "$TMP/mr-$1-on.ssa")")
  n_key=$(num "$(mono_field "$TMP/mr-$1-on.ssa" "$3")")
  n_cand=$(num "$(mono_field "$TMP/mr-$1-on.ssa" candidates)")
  if [ "$n_clones" -ne 0 ]; then
    echo "FAIL mono-refuse-$1: $n_clones clone(s) were emitted for a refused entry"
    FAIL=1
  elif [ "$n_cand" -lt 1 ]; then
    echo "FAIL mono-refuse-$1: candidates=$n_cand — the entry does not exercise the trigger at all, so the refusal is vacuous"
    FAIL=1
  elif [ "$n_key" -lt 1 ]; then
    echo "FAIL mono-refuse-$1: the note reports $3=$n_key — a different clause refused the site"
    FAIL=1
  elif ! cmp -s <(tail -n +2 "$TMP/mr-$1-on.ssa") "$TMP/mr-$1-off.ssa"; then
    echo "FAIL mono-refuse-$1: the .ssa differs from the QBE_NOMONO=1 arm by more than the note line"
    FAIL=1
  else
    echo "PASS mono-refuse-$1: candidates=$n_cand clones=0 $3=$n_key, and the emission is identical to the hatch arm"
  fi
}
mono_refuse_row rigid  hget      refused_b
mono_refuse_row refined hgetPlain refused_c
mono_refuse_row unclosed apply2  refused_a
mono_refuse_row untyped  fold     untyped
# the FIRING control in the same file: the pass must act on this compile, so
# the refusals above cannot be satisfied by the pass simply not running.
qbe_ssa_mono tools/qbe/fixtures/monorefuse.elm MonoRefuse.plainAt "$TMP/mr-plain-on.ssa" on
mn_ctl=$(num "$(mono_clones "$TMP/mr-plain-on.ssa")")
if [ "$mn_ctl" -ge 1 ]; then
  echo "PASS mono-refuse-control: MonoRefuse.plainAt clones $mn_ctl defun(s) — the pass runs on this fixture"
else
  echo "FAIL mono-refuse-control: no clone for MonoRefuse.plainAt — every refusal row above is vacuous"
  FAIL=1
fi
# INERTNESS: an entry with no candidate at all must be byte-identical INCLUDING
# the first line (no note is emitted).  This is the corpus-attribution property
# (QBE_NOMONO=1 must reproduce the committed baseline) at fixture scale.
qbe_ssa_mono tools/qbe/fixtures/monorefuse.elm MonoRefuse.twice "$TMP/mr-inert-on.ssa" on
qbe_ssa_mono tools/qbe/fixtures/monorefuse.elm MonoRefuse.twice "$TMP/mr-inert-off.ssa" off
if [ -s "$TMP/mr-inert-on.ssa" ] && cmp -s "$TMP/mr-inert-on.ssa" "$TMP/mr-inert-off.ssa"; then
  echo "PASS mono-inert: an entry with no candidate is BYTE-IDENTICAL on and off ($(wc -c <"$TMP/mr-inert-on.ssa") bytes)"
else
  echo "FAIL mono-inert: an entry with no candidate changed under the pass"
  FAIL=1
fi

# ---- stage 7: FLOAT (the silent-wrong class) ----
# The float path was NOT "not expressible" in the mere sense: hand-patching
# the emitted .ssa past the data-item lexer rejection produced a binary that
# BUILT, RAN, EXITED 0 and printed 0.0 (tools/bench/suite/mono_float.elm's VM
# answer is 600000.0).  Two causes: Mid/Qbe/Lower.elm's LFloat arm loaded the
# double INTO the payload-address temporary instead of storing through it
# (leaving a tag-only cell — the tag was written and the payload never was),
# and Mid/Qbe/Print.elm printed the static data item as `d 0.0`, which the
# vendored QBE's data lexer rejects.  A silent-wrong defect cannot be closed
# by one happy path, so tools/qbe/fixtures/float.elm is a MATRIX: each entry
# is a separate build (the meta table roots only the requested entry), and
# every one of them must match its frozen golden byte-for-byte (the values
# were the VM reference's, harvested 2026-10-10 while the differential still
# ran — before the interpreter retired at P8).
# The inline fast path inlines ONLY the both-Number case, so the operand
# shapes matter: `add/sub/mul` and `ltc/lec/gtc/gec` exercise BOTH arms (the
# inline integer op and the rt_prim fallback), `div` is rt_prim-only (`/` is
# absent from the inline table), `eqc/neq` is lowerNumEq's both-Number arm.
# The S4f entries at the end of the list are the cases a Float UNBOXING can get
# wrong: `nanEq`/`nanLt`/`nanGe` (IEEE ordered compares on raw operands),
# `negZeroEq`/`negZeroInv` (signed zero: `-0.0 == 0.0` is true, and the sign
# reaches `1.0 / -0.0`), `infArith`/`infCmp` (produced Infinity),
# `maxF`/`denormSum` (the ends of the f64 range), `recFieldRaw`/`listRaw` (a
# RAW float crossing a heap aggregate — a rebox boundary plus an unprovable
# read-back), `floatCmpChain` (every compare on raw operands at once) and
# `intAtFloat` (an integer TOKEN at a Float parameter position — the measured
# case that denies the float-parameter half of the pass), and
# `fdivIntTokens`/`fdivZero`/`fdivMixed` — `/` is Elm's FLOAT division even
# when its operands are integer tokens (`7 / 2` is 3.5, `1 / 0` is Infinity),
# so `f/` must never reach an integer arm; the first cut of this pass did
# exactly that and these entries catch it (3 and SIGFPE respectively).
# `tiny`/`big`/`bigNeg` pin printFloat's edges, where JS Number::toString
# switches to exponential ("1e-7" / "-1e+22") and QBE's data lexer runs C's
# `%lf` over the text; `infLit`/`negInfLit` are the NON-FINITE literals
# (1.0e400 overflows to "Infinity", which used to get printFloat's ".0"
# suffix appended and die as `d_Infinity.0`); `denorm` is the other end
# (5e-324); `nan` is produced (0.0/0.0), which is the only way a NaN can
# reach printValue at all (there is no literal spelling for it).
for e in lit neg add sub mul div ltc lec gtc gec eqc neq tiny big bigNeg infLit negInfLit denorm fromIntF recField tupleF listSum viaFn strF strI nan loop negZeroEq negZeroInv infArith infCmp nanEq nanLt nanGe maxF denormSum recFieldRaw listRaw intAtFloat floatCmpChain fdivIntTokens fdivZero fdivMixed; do
  run "float-$e" "Flt.$e" tools/qbe/fixtures/float.elm
done
run float-main Flt.main tools/qbe/fixtures/float.elm
# the driver's FLOAT ARGUMENT path (tools/qbe/rt.zig isFloatArg): pre-fix the
# native runner refused `2.5` with "entry arg '2.5' is not an int" while the
# VM printed 3.5 (the differential catch; now the golden pins 3.5).  The int-arg control stays, so widening the heuristic cannot
# have stolen the int path (or vice versa).
run float-arg      Flt.idF tools/qbe/fixtures/float.elm 2.5
run float-arg-int  Flt.idF tools/qbe/fixtures/float.elm 3
run float-arg-tiny Flt.idF tools/qbe/fixtures/float.elm 1e-7
run float-arg-neg  Flt.idF tools/qbe/fixtures/float.elm -1.5

# ---- S5/M2: MONOMORPHISATION, behaviourally (tools/qbe/fixtures/mono*.elm) ---
# The specialiser changes REPRESENTATIONS inside a clone, so a wrong answer is
# a wrong NUMBER, not a crash: each entry runs against its golden and again
# under QBE_HEAP_MB=16.
run mono-main       Mono.main       tools/qbe/fixtures/mono.elm
run mono-refuse     MonoRefuse.main tools/qbe/fixtures/monorefuse.elm
run mono-refuse-arg MonoRefuse.plainAt tools/qbe/fixtures/monorefuse.elm 3

# ---- S4/M1: UNBOXED Int LOCALS (tools/qbe/fixtures/norep.elm) ----
# Every entry is a SEPARATE BUILD (the meta table roots only the requested
# entry) and each one's stdout must match its golden byte-for-byte, plus the
# gc-churn rerun — the representation mismatch this pass can cause is a WRONG
# ANSWER, not a crash.  `main`/`polyLocal` are arity 0; the rest take one arg.
run norep-main    NoRep.main      tools/qbe/fixtures/norep.elm
run norep-poly    NoRep.polyLocal tools/qbe/fixtures/norep.elm
for e in chain boxed intCase cmp eqInt slotCount; do
  run "norep-$e" "NoRep.$e" tools/qbe/fixtures/norep.elm 7
done
run norep-cap   NoRep.capture    tools/qbe/fixtures/norep.elm 7
# the FLOAT half, behaviourally: unboxed Float locals must still agree with the
# VM, incl. at the rebox boundary (`v + x`) and through a closure capture.
run norep-float      NoRep.floatLocal   tools/qbe/fixtures/norep.elm 1.5
run norep-floatcap   NoRep.floatCapture tools/qbe/fixtures/norep.elm 1.5
# ...and the FLOAT PARAMETER deny control, behaviourally, WITH AN INT ARGUMENT:
# `3` is an integer token typed Float, so this entry is exactly the shape a raw
# parameter read would get wrong (the VM promotes it).  The float argument is
# kept beside it so the control cannot pass by refusing all arguments.
run norep-floatparam-i NoRep.floatParam tools/qbe/fixtures/norep.elm 3
run norep-floatparam-f NoRep.floatParam tools/qbe/fixtures/norep.elm 1.5
# THE HATCH, behaviourally: the SAME source with the pass OFF must also build,
# run and agree.  Off-switch builds that are never executed are not controls.
QBE_NOREP=1 run norep-main-off NoRep.main tools/qbe/fixtures/norep.elm

# ---- PASS A: DIRECT PER-PRIM CALLS (QBE_NOPRIMDIRECT=1) ----
# The pass replaces `call $rt_prim(l $d7, l %sN, w k)` (a NAME dispatch plus a
# vaInit'd GC staging array) with `call $rt_prim_<mangled>(l ..., w k)` — one
# comptime-generated C entry per prim in the runtime's table, all of them
# calling the SAME handler bodies in rt/prims.zig.  Same source, two builds:
# the counters must MOVE (the PathCSE lesson — a pass whose counters do not
# move is not firing) and the emitted symbol set must stay inside what rt.o
# actually defines (the one cross-language contract left is the name mangle,
# and this row is the net under it).
# POST-FLIP (osier-flip): both arms run on the ZIG ROUTE (QBE_MIDZIG=1) —
# the Mid route is the DEFAULT now and emits NO rt_prim site for a flipped
# prim, so pass A has nothing to convert in a default build.  The Zig route
# is EMIT-ONLY post-flip (its .ssa cannot LINK — the handlers are deleted),
# which is exactly what these rows do with it: they EMIT and count.
qbe_ssa_prim() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_MIDZIG=1 QBE_NOPRIMDIRECT=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/elm-compiler" && QBE=1 QBE_MIDZIG=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  fi
}
# flatten.elm is the fixture with the widest prim mix already on the row list
# above (assoc/snd/@p/cons/emptylist); norep.elm's `chain` supplies the
# arithmetic prims (`+`) and a second, independent shape.
qbe_ssa_prim tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/pd-flat-on.ssa"  on
qbe_ssa_prim tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/pd-flat-off.ssa" off
# `chain` is arithmetic, and S4's unboxing DELETES its `+` sites on its own —
# so this pair is compiled with QBE_NOREP=1 in BOTH arms, which is what keeps
# a real prim call in the fixture for pass A to convert (the ON/OFF difference
# is then pass A's alone).
QBE_NOREP=1 qbe_ssa_prim tools/qbe/fixtures/norep.elm NoRep.chain "$TMP/pd-chain-on.ssa" on
QBE_NOREP=1 qbe_ssa_prim tools/qbe/fixtures/norep.elm NoRep.chain "$TMP/pd-chain-off.ssa" off

pd_bad=0
for pair in "pd-flat:flatten" "pd-chain:chain"; do
  t="${pair%%:*}"; lbl="${pair##*:}"
  on_ssa="$TMP/$t-on.ssa"; off_ssa="$TMP/$t-off.ssa"
  [ -s "$on_ssa" ] && [ -s "$off_ssa" ] || {
    echo "FAIL primdirect-$lbl: .ssa missing (compile failed?)"; FAIL=1; pd_bad=1; continue; }
  d_on=$(primdirect_sites "$on_ssa")
  d_off=$(primdirect_sites "$off_ssa")
  g_on=$(rtprim_generic_sites "$on_ssa")
  g_off=$(rtprim_generic_sites "$off_ssa")
  if [ "$d_off" -ne 0 ]; then
    echo "FAIL primdirect-$lbl: $d_off direct site(s) survive with the pass OFF — the hatch does not gate the emission"
    pd_bad=1
  elif [ "$d_on" -lt 1 ]; then
    echo "FAIL primdirect-$lbl: the pass emitted NO direct call — it does not fire on this fixture"
    pd_bad=1
  elif [ "$g_on" -ne 0 ]; then
    echo "FAIL primdirect-$lbl: $g_on generic site(s) survive with the pass ON (arity 0/>3 only should keep the generic route)"
    pd_bad=1
  elif [ "$g_off" -ne "$((d_on + g_on))" ]; then
    echo "FAIL primdirect-$lbl: the call sites did not CONVERT but changed count ($d_on direct + $g_on generic ON vs $g_off generic OFF)"
    pd_bad=1
  else
    echo "PASS primdirect-$lbl: same source, $g_off generic sites OFF -> $d_on direct + $g_on generic ON (counters move, count identical)"
  fi
  # the runtime ABI is 3 pointer args + the count: every direct site's count
  # must be inside what tools/qbe/rt.zig Direct accepts.
  bad_ar=""
  for k in $(primdirect_arities "$on_ssa"); do
    [ "$k" -ge 1 ] && [ "$k" -le 3 ] || bad_ar="$bad_ar $k"
  done
  if [ -n "$bad_ar" ]; then
    echo "FAIL primdirect-$lbl: direct site(s) with an out-of-ABI arg count:$bad_ar (rt.zig Direct accepts 1..3)"
    pd_bad=1
  fi
done
if [ "$pd_bad" -eq 0 ]; then
  echo "PASS primdirect-abis: every direct site's arg count is inside the wrapper ABI (1..3)"
fi

# THE NAME CONTRACT, POST-FLIP: the pass-A .ssa above is emitted on the ZIG
# route (QBE_MIDZIG=1, emit-only), so it REFERENCES wrappers the flip deleted
# — by design.  The row therefore splits the referenced set:
#   * every symbol rt.o DOES define is fine;
#   * every symbol rt.o does NOT define must demangle to one of the FLIP'S
#     DELETED PRIMS (the list below mirrors prims.zig's header) — a missing
#     symbol outside that list is a mangling/table disagreement between
#     Mid.Qbe.Lower.mangle and tools/qbe/rt.zig symSuffix on a KEPT row,
#     which is otherwise only caught by a LINK error on whatever LINKABLE
#     fixture happens to be built;
#   * rt.o must define exactly one wrapper per prim-table entry (23 post-flip).
FLIP_DELETED="assoc cons = empty? + / f/ * - > < >= <= bitwise-and bitwise-or bitwise-xor bitwise-not bitwise-shift-left bitwise-shift-right bitwise-shift-right-zf number? string? cons? cn repeat c-strlen char-code substring shen.str->bytes shen.bytes->string absvector address-> <-address emptylist snd"
RTO="$ROOT/tools/qbe/rt.o"
if [ -s "$RTO" ]; then
  nm --defined-only "$RTO" 2>/dev/null | awk '$3 ~ /^rt_prim_/ { print $3 }' | sort -u > "$TMP/pd-defined.txt"
  cat "$TMP"/pd-*.ssa 2>/dev/null | grep -ho '\$rt_prim_[A-Za-z0-9_]*' | sed 's/^\$//' | sort -u > "$TMP/pd-referenced.txt"
  n_def=$(wc -l < "$TMP/pd-defined.txt")
  n_ref=$(wc -l < "$TMP/pd-referenced.txt")
  bad_missing=""
  n_deleted=0
  while read -r sym; do
    [ -n "$sym" ] || continue
    grep -qx "$sym" "$TMP/pd-defined.txt" && continue
    prim="$(printf '%s' "$sym" | sed 's/^rt_prim_//' | awk '{ out=""; i=1; s=$0
      while (i <= length(s)) { if (substr(s,i,2)=="_x" && length(s) >= i+3) { h=substr(s,i+2,2); c=0; for(j=1;j<=2;j++){d=tolower(substr(h,j,1)); c=c*16+index("0123456789abcdef",d)-1}; out=out sprintf("%c",c); i+=4 } else { out=out substr(s,i,1); i+=1 } } ; print out }')"
    # (QUOTED + tr: an unquoted $FLIP_DELETED would GLOB the '*'/'?' words
    # against the repo's files — the flip's own prim names are glob chars.)
    if printf '%s' "$FLIP_DELETED" | tr ' ' '\n' | grep -qxF -- "$prim"; then
      n_deleted=$((n_deleted + 1))
    else
      bad_missing="$bad_missing $sym"
    fi
  done < "$TMP/pd-referenced.txt"
  if [ -n "$bad_missing" ]; then
    echo "FAIL primdirect-symbols: emitted direct symbol(s) outside rt.o AND outside the flip-deleted set:$bad_missing — a mangle/table disagreement on a KEPT row"
    FAIL=1
  elif [ "$n_ref" -lt 1 ]; then
    echo "FAIL primdirect-symbols: no direct symbol referenced by the pass-A .ssa — nothing was checked"
    FAIL=1
  elif [ "$n_deleted" -lt 1 ]; then
    echo "FAIL primdirect-symbols: the QBE_MIDZIG arms referenced no deleted wrapper — they no longer emit the old path"
    FAIL=1
  elif [ "$n_def" -ne 23 ]; then
    echo "FAIL primdirect-symbols: rt.o defines $n_def direct entries, expected one per prims.prim_table row (23 post-flip: the host surface + the no-spelling prims; the flip deleted the 35 flipped rows)"
    FAIL=1
  else
    echo "PASS primdirect-symbols: $((n_ref - n_deleted)) emitted symbol(s) defined in rt.o ($n_def entries = the post-flip table) + $n_deleted flip-deleted symbol(s) the emit-only Zig route still references, all inside the deleted set"
  fi
else
  echo "FAIL primdirect-symbols: $RTO missing"
  FAIL=1
fi

# BEHAVIOUR under the hatch: the OFF build must still run and agree — an
# off-switch that is never executed is not a control.
# GOLDEN PROVENANCE (not a re-freeze): these two rows run the SAME source,
# entry and arguments as the pre-existing `flatten` and `churn` rows, so their
# goldens are those rows' already-pinned bytes COPIED under the new row names.
# Nothing was re-measured and no existing golden was overwritten; the check
# below is a real comparison of the hatch build's output against the pinned
# bytes, so a hatch that changes behaviour fails here.
# POST-FLIP NOTE (osier-flip): QBE_NOPRIMDIRECT only acts on the ZIG route,
# which a LINKABLE build no longer uses (the Mid route is the default and the
# flipped Zig handlers are deleted) — these rows now build-and-run the
# no-op-flag default as build-path sanity rows; pass A's conversion itself is
# checked STRUCTURALLY on the emit-only QBE_MIDZIG arms above.
QBE_NOPRIMDIRECT=1 run primdirect-off Flatten.main tools/qbe/fixtures/flatten.elm
# ...and under GC CHURN, on the cons-shaped stress fixture whose unrooted
# staging historically went stale (the rooting this pass rewrites is exactly
# that code path).
QBE_NOPRIMDIRECT=1 run primdirect-churn-off Churn.build tools/qbe/fixtures/churn.elm 150000 0

# ---- MID-WRITTEN RUNTIME: ONE PRIM END-TO-END (osier-consspike) ----
# Rt.cons is the runtime's first Mid-implemented defun: injected by
# QbeModule (seeded ONLY through the used-prim census — a program that never
# conses carries none of it), lowered from the raw node set, and — since THE
# FLIP (osier-flip), by DEFAULT — CALLED at every cons site instead of the
# Zig entry (whose handler is deleted; the QBE_MIDCONS=1 prefixes below are
# retired no-ops kept for row-name stability, the builds are the default).
# BEHAVIOURAL rows first: the same sources, entry and arguments as the
# pre-existing `flatten` and `churn` rows above, compiled with the route
# hatch, must print those rows' already-pinned golden bytes COPIED under the
# new names (the primdirect-off provenance discipline: nothing re-measured,
# no existing golden overwritten, the check a real comparison against the
# pinned bytes).  run()'s built-in churn sub-row is the QBE_HEAP_MB=16 row:
# the cons loop at the minimum viable heap through the MID cons.
# The ZIG-vs-MID FUZZ DIFFERENTIAL over generated vectors is a separate,
# heavier oracle: tools/qbe/consdiff/consdiff.sh (its header states what it
# covers and what it deliberately does not).
QBE_MIDCONS=1 run midcons Flatten.main tools/qbe/fixtures/flatten.elm
QBE_MIDCONS=1 run midcons-churn Churn.build tools/qbe/fixtures/churn.elm 150000 0
# The cons-STRUCTURE rows (the pair that can FAIL on a broken cons): the
# fixture's printed result IS a nested list/record spine, so a wrong tag or a
# stale interior pointer in ANY cons implementation changes the printed
# bytes.  `conslist` freezes the DEFAULT (Zig rt_prim_cons) build's output;
# `midcons-list` runs the Mid-routed build against the SAME bytes (golden
# COPIED from conslist.txt, the primdirect-off provenance discipline) — the
# in-gate Zig-vs-Mid comparison.  MEASURED while sizing these rows: a
# corrupted Rt.cons (tag 4 -> 0) left the churn/flatten goldens green (their
# printed results never traverse a cons) and flipped this fixture's output
# to a pointer-sized number — the mutation proof that these are the
# load-bearing behavioural rows.
run conslist ConsList.a tools/qbe/fixtures/conslist.elm
QBE_MIDCONS=1 run midcons-list ConsList.a tools/qbe/fixtures/conslist.elm

# The STEP-5 prim-structure rows (osier-midprims), the conslist lesson
# extended: this fixture's printed result TRAVERSES what the Mid-implemented
# string/vector prims build — strToBytes walks every byte of the Mid cn/
# repeat/substring-constructed string, the vector reads walk the Mid
# absvector array — so a wrong tag, a stale buffer pointer or a mis-sized len
# in ANY of them changes the printed bytes.  Golden frozen from the DEFAULT
# (Zig rt_prim) build; the Mid-routed twin must match byte-for-byte.
run primstruct PrimStruct.a tools/qbe/fixtures/primstruct.elm
QBE_MIDCONS=1 run midprim-struct PrimStruct.a tools/qbe/fixtures/primstruct.elm

# THE USED-PRIM CENSUS' SIX SEATS (handoff osier-midrt-fix, the step-5
# pre-flip review).  `calledPrims` decides which Rt.* defuns a compile SEEDS
# and emits; the review found it wrong in six seats (a non-inlinable record
# get, record-field patterns on BOTH the let-destructure and the case-alt
# path, literal patterns (which run the REAL `=`), a 2+-element tuple, and
# record/list literals), and each wrong seat produced a binary that failed to
# LINK on an undefined `q_Rt_*` the moment QBE_MIDCONS=1 routed the prim.
# This fixture puts all six in one committed program and PRINTS the result as
# a structure, so a wrong tag or a mis-sized payload in any of them changes
# the printed bytes.  Golden frozen from the DEFAULT (Zig rt_prim) build;
# `midcons-censusseats` runs the Mid-routed build against the SAME bytes
# (golden COPIED from censusseats.txt, the primdirect-off provenance
# discipline — nothing re-measured, no existing golden overwritten).
# MEASURED while adding these rows: with the RecordGet census arm alone
# reverted, this row's Mid twin FAILS (the compiler now refuses it with the
# seed guard's named error) and the whole language gate drops to
# PASS=124 FAIL=30 — the row is load-bearing, not decorative.
run censusseats CensusSeats.a tools/qbe/fixtures/censusseats.elm
QBE_MIDCONS=1 run midcons-censusseats CensusSeats.a tools/qbe/fixtures/censusseats.elm

# PINNED POST-FLIP DIVERGENCE: deepEqual's depth-1000 CYCLE GUARD (capture
# item 4).  values.zig:346 answered FALSE past 1000 levels so a cyclic
# structure terminated; the Mid deepEq has NO counter, so a self-referential
# vector recurses until the native stack is exhausted.  PRE-FLIP there were
# two rows (the default printed `false`, the QBE_MIDCONS=1 build died
# loudly); THE FLIP made the Mid route the DEFAULT and deleted the Zig `=`
# handler, so the `false` golden is FROZEN EVIDENCE of the deleted reference
# behaviour (tools/qbe/golden/cycleeq.txt) and the DEFAULT build now dies
# loudly.  The row asserts that death in BOTH directions: a Mid deepEq that
# silently answered wrong, or one that grew a cycle counter, both fail here
# and must re-point deliberately.
cyc_bin="$(RUN_STACK_KB=131072 "$ROOT/tools/qbe/qbe-mk.sh" "$ROOT/tools/qbe/fixtures/cycleeq.elm" CycleEq.main "$TMP/cycleeq-mid" 2>/dev/null)"
if [ -n "$cyc_bin" ] && [ -x "$cyc_bin" ]; then
  cyc_out="$(RUN_STACK_KB=131072 timeout 60 "$cyc_bin" CycleEq.main 2>&1)"
  cyc_rc=$?
  if [ "$cyc_rc" -ne 0 ] && printf '%s' "$cyc_out" | grep -q "native stack depth exceeded"; then
    echo "PASS cycleeq-dies-loudly: the default (Mid) \`=\` has no cycle guard (exit $cyc_rc, loud stack message) — the KNOWN post-flip divergence, pinned"
  else
    echo "FAIL cycleeq-dies-loudly: expected a LOUD native-stack death on the default route, got rc=$cyc_rc out='${cyc_out:0:120}' — if the cycle guard was ported, re-point this row"
    FAIL=1
  fi
else
  echo "FAIL cycleeq-dies-loudly: the default-route build failed (qbe-mk) — the row no longer measures what it names"
  FAIL=1
fi

# STRUCTURAL A/B rows (the counters must MOVE — a row that cannot fail is
# not a row):
#   * midrt-injected: the DEFAULT build of the cons-using fixture carries the
#     injected defun (`function :ret $q_Rt_x2econs`), and carries NO global
#     Desc / meta row for it (Rt defuns are internal);
#   * midrt-route: THE FLIP'S OWN ROW — the DEFAULT build (no flag) routes
#     every cons site to the Rt defun (`call $q_Rt_x2econs(` >= 1) and NO
#     `rt_prim_cons` site survives;
#   * midrt-zig: the OLD path is still selectable (QBE_MIDZIG=1) and emits
#     `call $rt_prim_cons(` sites again — the bisect hatch, measured at the
#     emission level (post-flip it cannot link; see qbe_ssa_midrt);
#   * midrt-pruned: the hatch ON a cons-FREE entry (NoRep.chain is pure
#     arithmetic) emits NO Rt defun at all — the pruning claim, measured;
#   * midrt-hatch: QBE_NOMIDRT=1 removes the injection from the cons-using
#     fixture — the same-source control that attributes every .ssa move
#     above to the injection (the corpus-ssa attribution's in-gate twin).
# POST-FLIP (osier-flip): `route` is the DEFAULT (no flag — the Mid route IS
# the compile default now); `zig` selects the OLD path with QBE_MIDZIG=1 (an
# EMIT-ONLY arm on this tree: the deleted Zig handlers mean the emitted
# rt_prim_cons sites cannot link — the row asserts the EMISSION, which is
# what a bisect needs).  `off` stays QBE_NOMIDRT=1 (also emit-only post-flip).
qbe_ssa_midrt() { # <fixture> <entry> <out.ssa> <mode: on|off|route|zig>
  local flags=""
  case "$4" in
    off)   flags="QBE_NOMIDRT=1" ;;
    route) flags="" ;;
    zig)   flags="QBE_MIDZIG=1" ;;
  esac
  (cd "$ROOT/elm-compiler" && env QBE=1 $flags QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
}
midrt_ssa() { grep -c 'q_Rt_x2econs' "$1" 2>/dev/null || true; }
midrt_calls() { grep -c 'call \$q_Rt_x2econs(' "$1" 2>/dev/null || true; }
midrt_zigcons() { grep -c 'rt_prim_cons' "$1" 2>/dev/null || true; }

qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-on.ssa"  on
qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-off.ssa" off
qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-route.ssa" route
qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-zig.ssa"  zig
QBE_NOREP=1 qbe_ssa_midrt tools/qbe/fixtures/norep.elm NoRep.chain "$TMP/midrt-chain-route.ssa" route

midrt_bad=0
if [ -s "$TMP/midrt-flat-on.ssa" ]; then
  n=$(midrt_ssa "$TMP/midrt-flat-on.ssa")
  if [ "$n" -lt 1 ]; then
    echo "FAIL midrt-injected: the default build carries no q_Rt_x2econs defun — the injection does not fire"
    midrt_bad=1
  elif grep -q 'gd_Rt_x2econs\|mname.*Rt_x2econs' "$TMP/midrt-flat-on.ssa"; then
    echo "FAIL midrt-injected: the Rt defun leaked into the surface tables (Desc/meta) — Rt defuns are internal"
    midrt_bad=1
  else
    echo "PASS midrt-injected: default build carries the injected q_Rt_x2econs ($n mention(s)), no Desc/meta leak"
  fi
else
  echo "FAIL midrt-injected: .ssa missing (compile failed?)"; midrt_bad=1
fi
if [ -s "$TMP/midrt-flat-route.ssa" ]; then
  c=$(midrt_calls "$TMP/midrt-flat-route.ssa")
  z=$(midrt_zigcons "$TMP/midrt-flat-route.ssa")
  if [ "$c" -lt 1 ]; then
    echo "FAIL midrt-route: no call \$q_Rt_x2econs site — the route does not fire on this fixture"
    midrt_bad=1
  elif [ "$z" -ne 0 ]; then
    echo "FAIL midrt-route: $z rt_prim_cons site(s) survive with the route ON — cons did not convert"
    midrt_bad=1
  else
    echo "PASS midrt-route: $c cons site(s) -> q_Rt_x2econs, 0 rt_prim_cons left (the DEFAULT route)"
  fi
else
  echo "FAIL midrt-route: .ssa missing (compile failed?)"; midrt_bad=1
fi
if [ -s "$TMP/midrt-flat-zig.ssa" ]; then
  zc=$(midrt_zigcons "$TMP/midrt-flat-zig.ssa")
  zq=$(midrt_calls "$TMP/midrt-flat-zig.ssa")
  if [ "$zc" -lt 1 ]; then
    echo "FAIL midrt-zig: QBE_MIDZIG=1 emitted no rt_prim_cons site — the old path is not selectable"
    midrt_bad=1
  elif [ "$zq" -ne 0 ]; then
    echo "FAIL midrt-zig: $zq q_Rt_x2econs call site(s) under QBE_MIDZIG=1 — the hatch does not gate the route"
    midrt_bad=1
  else
    echo "PASS midrt-zig: QBE_MIDZIG=1 emits $zc rt_prim_cons site(s), 0 q_Rt cons calls (the seeded defun may still be present, uncalled)"
  fi
else
  echo "FAIL midrt-zig: .ssa missing (compile failed?)"; midrt_bad=1
fi
if [ -s "$TMP/midrt-chain-route.ssa" ]; then
  n=$(midrt_ssa "$TMP/midrt-chain-route.ssa")
  if [ "$n" -ne 0 ]; then
    echo "FAIL midrt-pruned: a cons-free entry carries $n q_Rt_x2econs mention(s) — the used-prim census over-seeds"
    midrt_bad=1
  else
    echo "PASS midrt-pruned: the cons-free entry carries NO Rt defun (used-prim seeding prunes it)"
  fi
else
  echo "FAIL midrt-pruned: .ssa missing (compile failed?)"; midrt_bad=1
fi
if [ -s "$TMP/midrt-flat-off.ssa" ]; then
  n=$(midrt_ssa "$TMP/midrt-flat-off.ssa")
  if [ "$n" -ne 0 ]; then
    echo "FAIL midrt-hatch: QBE_NOMIDRT=1 build still carries the Rt defun — the hatch does not gate the injection"
    midrt_bad=1
  else
    echo "PASS midrt-hatch: QBE_NOMIDRT=1 removes the injection from the cons-using fixture"
  fi
else
  echo "FAIL midrt-hatch: .ssa missing (compile failed?)"; midrt_bad=1
fi

# THE `Rt` MODULE-NAME RESERVATION (the audit's residual hole, closed by this
# step): a surface module named Rt would emit keys under the whitelisted
# Rt.* prefix and never be audited, so every compile rejects it loudly.
printf 'module Rt exposing (f)\n\nf x =\n    x + 1\n' > "$TMP/rtmod.elm"
if (cd "$ROOT/elm-compiler" &&
      QBE=1 QBE_ENTRY=Rt.f node run.js "$TMP/rtmod.elm" "$TMP/rtmod.ssa") >/dev/null 2>&1 \
   && head -c 200 "$TMP/rtmod.ssa" 2>/dev/null | grep -q 'module name Rt is reserved'; then
  echo "PASS rt-name-reserved: a surface module named Rt is rejected loudly at collect time"
else
  echo "FAIL rt-name-reserved: the Rt module name is not reserved (the audit's prefix hole is open)"
  midrt_bad=1
fi
if [ "$midrt_bad" -eq 0 ]; then
  echo "PASS midrt-seats: injected + routed + pruned + hatched + reserved (all counters move)"
else
  # The gate is the EXIT CODE, not the transcript: a printed FAIL that does
  # not fail the run is not a check (this exact bug shipped with the first
  # cut of these rows and was caught by the mutation proof's exit 0).
  FAIL=1
fi

# ---- cross-defun tail: UNBOUNDED after the bounce loop ----
# (qbe-mk rebuilds this binary from the current tree on every call and $TMP is
# per-run, so a pre-bounce binary left by an earlier commit cannot answer here
# -- that reuse via a fixed-path existence-guard was this check's stale-artifact
# bug.)
if "$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/mutualtail.elm Mutual.even "$TMP/mutual" >/dev/null 2>&1; then
  # Mutual.even n -> odd (n-1) -> even (n-2) is MUTUAL tail recursion.  Before
  # the bounce loop these cross-defun tails were PLAIN CALLS and died between
  # 20k-40k hops on an 8MB stack (2 native frames/hop).  After it, a tail call
  # returns a .tail chased by rt_bounce at constant native stack, so 1e6 hops —
  # the same depth the VM's appterm handled — must COMPLETE with the pinned
  # answer ("1": the differential-proven value, frozen as its golden).
  d=1000000
  nat_out="$(timeout 120 "$TMP/mutual/mutualtail" Mutual.even "$d" 2>&1)"
  if [ "$nat_out" = "1" ]; then
    echo "PASS mutual-tail $d hops: unbounded (golden 1; pre-bounce ceiling was 20k-40k)"
  else
    echo "FAIL mutual-tail $d hops: golden='1' native='$nat_out'"
    FAIL=1
  fi
  # GC-CHURN counterpart (handoff osier-passc): every hop builds a .tail, and
  # rt_tail_known stages an arity<=3 call's args in a STATIC buffer instead of a
  # fresh GC array (rt.zig).  That buffer is unrooted, and sound only because no
  # collection can run between the .tail build and the callee's prologue blit
  # (the blit and rt_frame_enter allocate nothing in the GC heap).  What this row
  # checks is the honest half: the whole path runs at the minimum heap, where the
  # collector works constantly around it, and the pinned answer must be
  # unchanged.  It CANNOT prove that window is collection-free — only the
  # argument in rt.zig does that — so a green row here is a regression net, not
  # evidence for the invariant.
  churn_out="$(QBE_HEAP_MB=$CHURN_MB timeout 120 "$TMP/mutual/mutualtail" Mutual.even "$d" 2>&1)"
  if [ "$churn_out" = "1" ]; then
    echo "PASS mutual-tail gc-churn (QBE_HEAP_MB=$CHURN_MB, $d hops): staged tail args, minimum heap"
  else
    echo "FAIL mutual-tail gc-churn (QBE_HEAP_MB=$CHURN_MB): golden='1' native='$churn_out'"
    FAIL=1
  fi
fi

# ---- cross-target smoke: the .ssa is target-NEUTRAL IL, so it must also
#      COMPILE under qbe's other targets.  The behavioural gate runs on the
#      HOST target only (amd64 here, MEASURED); this is the honest cheap half
#      of the portability claim -- structurally portable, x86_64-measured.  A
#      lowering that ever emits a host-specific pattern into the IL stops
#      compiling here, loudly.  fib.ssa/float.ssa come from the rows above
#      (a missing .ssa already failed that row); float covers the data-item
#      lexer corners (Print.elm's d_ sigil).
for tgt in arm64 rv64; do
  ok=1
  for s in "$TMP/fib/fib.ssa" "$TMP/float-lit/float.ssa"; do
    [ -s "$s" ] || continue
    if ! "$ROOT/vendor/qbe/qbe" -t "$tgt" "$s" > /dev/null 2>"$TMP/xtgt.err"; then
      echo "FAIL cross-$tgt: vendored qbe -t $tgt rejected $(basename "$s"): $(head -c 120 "$TMP/xtgt.err")"
      FAIL=1; ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "PASS cross-$tgt: fib.ssa and float.ssa compile under qbe -t $tgt (the IL is target-neutral)"
  fi
done

# ---- zigretire stage 5 PART 3: THE MIDGC GUARD'S COMPLETENESS ----
# The guard that names ONE incompatible flag is not a guard (this arc paid for
# that twice: NORTLEAN then NOMIDRT).  run.js's MIDGC_DEPENDS_ON list is the
# single source of truth; this row re-derives its entries from THAT list (not
# a hand-written copy) and re-runs run.js with each `off` flag under
# QBE_MIDGC=1, asserting a LOUD exit 2.  A future flag QBE_MIDGC newly depends
# on but forgets to add to the list keeps compiling silently — and the only
# instrument that sees it is the probe for that shape, so this row also pins
# that the list is non-empty (a refactor that deletes the enumeration fails
# here, not silently).
midgc_guard_offs="$(grep -o "off: 'QBE_[A-Z]*'" "$ROOT/elm-compiler/run.js" | sed "s/off: '//; s/'//")"
if [ -z "$midgc_guard_offs" ]; then
  echo "FAIL midgc-guard: MIDGC_DEPENDS_ON in run.js lists no flags — the enumeration was deleted"
  FAIL=1
else
  mg_ok=1
  for off in $midgc_guard_offs; do
    (cd "$ROOT/elm-compiler" && env QBE_MIDGC=1 "$off=1" node run.js >/dev/null 2>&1)
    mg_rc=$?
    if [ "$mg_rc" -ne 2 ]; then
      echo "FAIL midgc-guard: QBE_MIDGC=1 $off=1 exited $mg_rc, want 2 (the incompatible combination is no longer refused loudly)"
      FAIL=1; mg_ok=0
    fi
  done
  if [ "$mg_ok" = 1 ]; then
    echo "PASS midgc-guard: QBE_MIDGC=1 refuses each of its $(echo "$midgc_guard_offs" | wc -w) incompatible flag(s) — $midgc_guard_offs (enumerated from run.js, not hand-copied)"
  fi
fi

exit $FAIL
