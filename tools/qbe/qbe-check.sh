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

# run_mid — like run(), but the group is the Osier .elm fixture PLUS one or
# more user .mid modules (M3: a per-group mid-c input beside the Osier source;
# M3fix-4: a mid-c -> mid-c call needs the CALLEE module in the group too,
# hence the LIST).  The .mid(s) are classified by extension in run.js,
# compiled by Mid.RtLang, and merged; the entry is the Osier module's own.
# The golden + churn contract is `run`'s.  No entry args: the row's entry
# takes none (a row that needs them wants its own runner, not a silent
# trailing-argument reinterpretation).
run_mid() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local mids=("$@")
  local bin
  # MIDHOST_ROW=1 is `run_midhost`'s knob: it compiles with QBE_MIDHOST=1, which
  # is what makes a seat that lives INSIDE the QBE_MIDHOST region exist.  SINCE
  # STAGE 7 O2 THE KNOB IS REDUNDANT, NOT WRONG: the region is kept BY DEFAULT,
  # so every row here (including the ones that set nothing, i.e. `QBE_MIDHOST=""`
  # which is "unset" to run.js) now carries the Mid host, and `=1` merely says so
  # explicitly.  It is left in place because the row that flips a knob back is
  # the cheap fail-before for the flip itself: `MIDHOST_ROW=` -> QBE_MIDHOST=0
  # (O4: QBE_MIDHOST is RETIRED — the Mid host is the only host; the
  # MIDHOST_ROW knob's env is no longer set.  ZIGHOST Z0 RETIRED THE
  # MIDGC_OFF KNOB too: it built the row on the Zig collector's route so the
  # run_midshape rows' literal .ssa temp names stayed comparable, and that
  # route is deleted — the frozen shapes below are the MID route's, which is
  # now the only emission there is.)
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "${mids[@]}" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local nat_out
  nat_out="$(timeout 60 "$bin" "$entry" 2>&1)"
  local exp
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
  if [[ "$name" != *-nochurn ]]; then
  local churn_out
  churn_out="$(QBE_HEAP_MB=$CHURN_MB "$bin" "$entry" 2>&1)" || true
  if [ "$churn_out" != "$exp" ]; then
    echo "FAIL $name: CHURN mismatch (QBE_HEAP_MB=$CHURN_MB): '$churn_out'"
    FAIL=1
  else
    echo "PASS $name: gc-churn (QBE_HEAP_MB=$CHURN_MB) identical"
  fi
  fi
}

# run_midhost — `run_mid` for a row whose SURFACE SEAT only exists in an ARM-B
# (QBE_MIDHOST=1) build.  The golden + churn contract is `run_mid`'s, unchanged;
# the only difference is the compile-time flag.  Stage 7A's applier pin needs it
# because `Rt.apply-at` is exported INSIDE the QBE_MIDHOST region — an export
# must name an existing defun, and in the default arm that defun is spliced out
# with the host.
run_midhost() {
  MIDHOST_ROW=1 run_mid "$@"
}

# run_midrt — the M3-rtcall row: a user .mid `call Rt.<exported>` (an EXPORTED
# runtime key) end to end.  The fixture reads "rtcall-input.txt" RELATIVE to
# the process CWD, so this runner CREATES that file in the run dir and runs
# the binary with CWD = the run dir.  The golden is the file's CONTENT
# (load-bearing on the seeded call: unseeded, the compile fails to LINK on
# q_Rt_x2eread_x2dfile_x2das_x2dstring — the exported-key allowance was a
# trap).  No churn arm: reading is a single allocation, and the row's point is
# the LINK, not the GC.
run_midrt() {
  local name="$1" entry="$2" fixture="$3"; shift 3
  local mids=("$@")
  local dir="$TMP/$name"
  mkdir -p "$dir"
  printf 'rtcall-ok' > "$dir/rtcall-input.txt"
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "${mids[@]}" "$entry" "$dir")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local nat_out
  nat_out="$(cd "$dir" && timeout 60 "$bin" "$entry" 2>&1)"
  local exp
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
}

# run_midref — the M3fix-4 (b) row: a user .mid `call` whose target is NOT a
# defun of this program MUST be REFUSED at COMPILE time, loudly, naming the
# key.  The refusal is the RawCall arm's (Lower.elm), not J2's: the fixture's
# key resolves through the runtime EXPORT block, so only the emit-level check
# can stop it — and a compile that let it through would reach the linker as a
# dangling `q_<key>` (the symptom M3fix-4's acceptance predicate replaced with
# a named compile error).  `$5` asserts a substring of the REFUSAL MESSAGE, so
# a row cannot pass on an unrelated (e.g. J2) failure.  `$6...` optionally name
# the hatches to run under, as SEPARATE words (an array — one `env` argument per
# flag).  Since ZIGHOST Z0 no pairing can rescue a MIDGC_DEPENDS_ON hatch: the
# Mid collector is unconditional, so the guard refuses those builds outright and
# a row measuring one would read the GUARD's message instead of its own — which
# is why the rows that needed NOMIDRT are retired below.
run_midref() {
  local name="$1" entry="$2" fixture="$3" mid="$4" expect="$5"
  shift 5
  local hatch=("$@")
  local out="$TMP/$name-refusal"
  mkdir -p "$out"
  local rc=0
  if [ "${#hatch[@]}" -gt 0 ]; then
    env "${hatch[@]}" "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$mid" "$entry" "$out" >/dev/null 2>&1 || rc=1
  else
    "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$mid" "$entry" "$out" >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" = 0 ]; then
    echo "FAIL $name: the program compiled — the refusal (naming '$expect') is missing"
    FAIL=1; return
  fi
  local ssa="$out/$(basename "$mid").ssa"
  if ! head -c 4 "$ssa" | grep -q '^err '; then
    echo "FAIL $name: the compile failed but not with an 'err' refusal"
    FAIL=1; return
  fi
  if ! grep -q "$expect" "$ssa"; then
    echo "FAIL $name: the refusal does not name '$expect'"
    FAIL=1; return
  fi
  echo "PASS $name: refused (names '$expect')"
}

# run_midshape — `run_mid` PLUS a STRUCTURAL PIN on the emitted .ssa (cffi U2).
#
# WHY A SHAPE CHECK AND NOT ONLY A GOLDEN: the width fix is an EMITTED SHAPE
# (`=w call` plus an extension of THAT call's result), and a golden alone
# cannot say where the shape came from.  `$5` is a literal pattern the .ssa
# must contain (`grep -F`, so `$` is a dollar and not end-of-line); `$6` is the
# extension op that must appear on the line AFTER the call, applied to the
# call's own temp (`extsw`/`extuw`), or the empty string for "no extension" —
# an absence that must be asserted because the POSITIVE form of the bug is a
# lowering that extends unconditionally.
#
# The line-after read is deliberate: `extsw` occurs all over the runtime's own
# defuns in the same file, so "the .ssa contains an extsw" would pass on any
# program at all (instrument that cannot fail).  This pins it to the ONE line
# that consumes the accession's result.
#
# The ssa path is qbe-mk's own naming: the LAST source in the group names the
# output, and a .mid group member keeps its extension (BASE =
# basename <last> .elm -> "ffiw-i32.mid"), so the .ssa is "<mid>.ssa".
run_midshape() {
  local name="$1" entry="$2" fixture="$3" mid="$4" must="$5" extop="$6"
  run_mid "$name" "$entry" "$fixture" "$mid"
  local ssa="$TMP/$name/$(basename "$mid").ssa"
  if [ ! -f "$ssa" ]; then
    echo "FAIL $name: no emitted .ssa at $ssa"; FAIL=1; return
  fi
  if ! grep -qF "$must" "$ssa"; then
    echo "FAIL $name: the emitted .ssa lacks the required shape '$must' (the emitted call does not match the DECLARED boundary)"; FAIL=1; return
  fi
  local ln ctmp next
  ln="$(awk -v pat="$must" 'index($0, pat) { print NR; exit }' "$ssa")"
  next="$(sed -n "$((ln + 1))p" "$ssa")"
  if [ -n "$extop" ]; then
    ctmp="$(printf '%s\n' "$(sed -n "${ln}p" "$ssa")" | grep -o '%[A-Za-z0-9_]*' | head -1)"
    case "$next" in
      *"$extop $ctmp"*)
        echo "PASS $name: emitted shape '$must' + '$extop $ctmp' (the result IS extended)";;
      *)
        echo "FAIL $name: no '$extop $ctmp' after '$must' — next line: $next"; FAIL=1;;
    esac
  else
    case "$next" in
      *extsw*|*extuw*)
        echo "FAIL $name: the line after '$must' EXTENDS the result ($next) — the width was not honoured"; FAIL=1;;
      *)
        echo "PASS $name: emitted shape '$must' with NO extension (next line: $(printf '%s' "$next" | sed -e 's/^[[:space:]]*//' -e 's/\t/ /g'))";;
    esac
  fi
}

# run_importref — the M4 refusal rows: an Osier source IMPORTING a .mid by name
# (the .mid is NOT passed on the CLI — run.js resolves `import X` to X.mid next
# to the fixture).  The refusal is either READER-side (the .mid's `module`
# header disagrees with the import name) or CORE-side (an Osier call checked
# against the DECLARED type fails, e.g. Float vs String).  Both land in the
# group's output as "err <msg>", so `$4` asserts a substring of that message.
run_importref() {
  local name="$1" entry="$2" fixture="$3" expect="$4"
  local out="$TMP/$name-refusal"
  mkdir -p "$out"
  local rc=0
  "$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$out" >/dev/null 2>&1 || rc=1
  if [ "$rc" = 0 ]; then
    echo "FAIL $name: the program compiled — the refusal (naming '$expect') is missing"
    FAIL=1; return
  fi
  local ssa="$out/$(basename "$fixture" .elm).ssa"
  if ! head -c 4 "$ssa" | grep -q '^err '; then
    echo "FAIL $name: the compile failed but not with an 'err' refusal"
    FAIL=1; return
  fi
  if ! grep -q "$expect" "$ssa"; then
    echo "FAIL $name: the refusal does not name '$expect'"
    FAIL=1; return
  fi
  echo "PASS $name: refused (names '$expect')"
}

# run_midws — the M4NICE reader-rule row: a `.mid`'s WHITESPACE spelling must
# not change the compile.  The reader's `module`-header scan (run.js
# `midModuleName`, MIRRORED in selfhost/NativeMain.elm `firstModuleName`) skips
# a line after TRIMMING it, so a CRLF `\r`, a blank FIRST line and an indented
# comment are all skipped — the same reading the core's own `.mid` header
# parser has (it skips whitespace and comments before the `module` line,
# RtLang/Parse.elm:1217).  The native lane used to skip `l == ""` alone, which
# read a CRLF-plus-blank-line `.mid` as headerless and DIVERGED from run.js
# (MEASURED on a header-MISMATCHED .mid: run.js refused "declares module
# Othername" while the native lane compiled and failed later on "unknown name").
#
# TWO modes, both over the SAME four variants (crlf / blank first line / both /
# indented):
#   * no `$5`   — the `.mid` MATCHES its import name: every variant must emit a
#     `.ssa` BYTE-IDENTICAL to the LF baseline (`cmp`, not the exit code), which
#     is only true if the same header was found by the same rule.  The baseline
#     is checked NOT to be an `err` payload first — two identical refusals would
#     satisfy `cmp` vacuously.
#   * with `$5` — the `.mid` MISMATCHES (declares another module): every variant
#     must be REFUSED naming `$5`.  This is the mode that can actually go RED: a
#     reader that stops trimming loses the header on the `both` and `indent`
#     variants, so the compile falls through to the core's "unknown name"
#     instead of the reader's refusal (MEASURED by reverting run.js's trim).
run_midws() {
  local name="$1" entry="$2" fixture="$3" mid="$4" expect="${5:-}"
  local dir="$TMP/$name" v
  local bf mf
  bf="$(basename "$fixture")"
  mf="$(basename "$mid")"
  mkdir -p "$dir"
  cp "$ROOT/$fixture" "$dir/$bf"
  local orig="$dir/$mf.orig"
  cp "$ROOT/$mid" "$orig"
  cp "$orig" "$dir/$mf"
  (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY="$entry" node run.js "$dir/$bf" "$dir/lf.ssa") >/dev/null 2>&1
  local ok=1
  if [ -z "$expect" ]; then
    if [ ! -s "$dir/lf.ssa" ] || head -c 4 "$dir/lf.ssa" | grep -q '^err '; then
      echo "FAIL $name: the LF baseline did not compile: $(head -c 120 "$dir/lf.ssa" 2>/dev/null)"
      FAIL=1; return
    fi
  elif ! head -c 4 "$dir/lf.ssa" | grep -q '^err ' || ! grep -q "$expect" "$dir/lf.ssa"; then
    echo "FAIL $name: the LF baseline was not refused naming '$expect' ($(head -c 120 "$dir/lf.ssa" 2>/dev/null))"
    FAIL=1; return
  fi
  for v in crlf blank both indent; do
    case "$v" in
      crlf)   sed 's/$/\r/' "$orig" > "$dir/$mf" ;;
      blank)  { printf '\n'; cat "$orig"; } > "$dir/$mf" ;;
      both)   { printf '\r\n'; sed 's/$/\r/' "$orig"; } > "$dir/$mf" ;;
      indent) sed 's/^/ /' "$orig" > "$dir/$mf" ;;
    esac
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY="$entry" node run.js "$dir/$bf" "$dir/$v.ssa") >/dev/null 2>&1
    if [ -n "$expect" ]; then
      if ! head -c 4 "$dir/$v.ssa" | grep -q '^err ' || ! grep -q "$expect" "$dir/$v.ssa"; then
        echo "FAIL $name: the $v .mid was NOT refused naming '$expect' ($(head -c 90 "$dir/$v.ssa" 2>/dev/null))"
        FAIL=1; ok=0
      fi
    elif ! cmp -s "$dir/lf.ssa" "$dir/$v.ssa"; then
      echo "FAIL $name: the $v .mid emitted different bytes than the LF baseline ($(head -c 90 "$dir/$v.ssa" 2>/dev/null))"
      FAIL=1; ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    if [ -n "$expect" ]; then
      echo "PASS $name: the crlf/blank/both/indent .mid spellings are all refused naming '$expect'"
    else
      echo "PASS $name: the crlf/blank/both/indent .mid spellings emit a byte-identical .ssa"
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

# run_mdgc — a MIDGC row (stage 6 B1): the cross-heap probe
# fixtures compile through the Mid mark-sweep collector AND the Mid apply
# family (Rt.apply's partial arm allocates the env array via Rt.allocVector —
# the cross-heap edge; Rt.apply-tail's saturated arm the .tail env array).
# The golden is the SAME value run_midgc pins (the correct sum — the
# observable output is collector-agnostic).  B4 removed the QBE_MIDDRIVER flag
# (the Mid driver is the only route), so this is QBE_MIDGC=1 alone; runs at
# CHURN_MB so the collector actually collects.
run_mdgc() {
  local name="$1" golden="$2" entry="$3" fixture="$4"; shift 4
  local cli=("$@")
  local src ssa bin nat_out exp
  src="$ROOT/$fixture"
  [ -f "$src" ] || { echo "FAIL $name: no source: $src"; FAIL=1; return; }
  # (ZIGHOST Z6: no rt.o — the runtime is Mid and is emitted into the .ssa)
  ssa="$TMP/$name.ssa"
  (cd "$ROOT/osier-compiler" &&
    QBE=1 QBE_ENTRY="$entry" QBE_MIDGC=1 node run.js "$src" "$ssa") >&2 || {
    echo "FAIL $name: qbe-mk (QBE_MIDGC=1)"; FAIL=1; return
  }
  case "$(head -c 4 "$ssa")" in
    "err "*) echo "FAIL $name: compile failed: $(cat "$ssa")"; FAIL=1; return;;
  esac
  "$ROOT/vendor/qbe/qbe" "$ssa" > "$TMP/$name.s"
  bin="$TMP/$name"
  cc "$TMP/$name.s" -o "$bin" -lc || {
    echo "FAIL $name: link"; FAIL=1; return
  }
  nat_out="$(QBE_HEAP_MB=$CHURN_MB timeout 60 "$bin" "$entry" "${cli[@]}" 2>&1)" || true
  if [ "$FREEZE" = 1 ]; then
    echo "FAIL $name: a MIDGC row's golden is the run_midgc row's ($golden.txt) — freeze the run_midgc row, not this one"
    FAIL=1; return
  fi
  exp="$(golden_read "$golden")"
  if [ "$exp" = "__NO_GOLDEN__" ]; then
    echo "FAIL $name: no golden at $GOLDEN/$golden.txt"
    FAIL=1; return
  fi
  if [ "$nat_out" != "$exp" ]; then
    echo "FAIL $name: midgc golden='$exp' native='$nat_out'"
    FAIL=1; return
  fi
  echo "PASS $name: midgc (QBE_HEAP_MB=$CHURN_MB) identical (${nat_out:0:60})"
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

# run_midgc_io — the host-IO fixture's golden + churn row: the kept string is
# rooted across a 4-arg mutual tail recursion, so the fixture prints "100|150".
#
# IT WAS THE ZIG-COLLECTOR HALF OF A PAIR (stage 7 O3 pinned it at
# QBE_MIDGC=0 so each arm said which collector it was).  ZIGHOST Z0 DELETED the
# Zig collector: the flag is refused outright, and both halves of that pair now
# measure the same one route — this row and probe-midgc-io.sh.  The row is kept
# for the golden + churn contract (a reclaimed kept string turns it red); it no
# longer distinguishes a collector.
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

# run_err — a DRIVER ERROR-PATH row: builds exactly like run(), then runs the
# binary with an EXPLICIT command line (`cli...`, possibly EMPTY) and requires
# BOTH the merged stdout+stderr to match the golden AND the exit code to equal
# the pinned expected code.  run() compares output only and never reads the
# status, so every driver error path was invisible to it (a swap that turned
# an error exit into a success stayed green); these rows pin the exit codes
# and stderr bytes the stage-6 ABI swap must keep.
#   * `entry` is the BUILD entry (qbe-mk needs a real one, like run()); the
#     command line is `cli...` — NOT the build entry — because the pinned
#     shapes are exactly the ones where the CLI entry is absent (usage),
#     bogus (not in qbe_meta), or malformed (bad arg).
#   * the exit code is read DIRECTLY off the command substitution
#     (`out="$(...)"; rc=$?`), never through a pipe: a pipe would report the
#     last stage's status, not the binary's.
#   * NO gc-churn rerun: these rows exit from the driver's own argument
#     handling before generated code runs, so there is no allocation pressure
#     to vary — a churn rerun would only double-count the row.
#   * the expected code is pinned in the ROW, and freeze mode never writes it:
#     a frozen golden cannot heal a wrong expected exit code.
run_err() {
  local name="$1" entry="$2" fixture="$3" want_rc="$4"; shift 4
  local cli=("$@")
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local nat_out rc exp
  nat_out="$(timeout 60 "$bin" "${cli[@]}" 2>&1)"
  rc=$?
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
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL $name: exit=$rc want=$want_rc (output matched — the exit code is the pinned half)"
    FAIL=1
    return
  fi
  echo "PASS $name: golden + exit $rc (${nat_out:0:80})"
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
# M3: the FIRST user .mid — the Osier fixture (user-mid.elm) calls the mid-c
# defun UserMid.answer (user-mid.mid) by qualified name; the driver prints 13.
# M3fix-4: the group now carries a SECOND user .mid (user-mid2.mid), because
# `UserMid.answer` calls ITS exported defun `UserMid2.boxedSum` — the
# mid-c -> mid-c cross-module call.  It resolved at J2 (the cross-module extern
# table) but was REFUSED at emit time before this unit; now the RawCall arm
# accepts a key by MEMBERSHIP IN THE SET THIS COMPILE EMITS (no `Rt.`-shape
# predicate), and the call shape follows the callee's ABI (a user defun is
# RtGeneric, not lean).  The golden is UNCHANGED at 13: `answer` returns
# boxedSum's result verbatim, so the printed value is load-bearing on the
# cross-module call (emit it wrong, or not at all, and the row moves).
run_mid user-mid UserMidRun.main tools/qbe/fixtures/user-mid.elm tools/qbe/fixtures/user-mid.mid tools/qbe/fixtures/user-mid2.mid
# M3-rtcall: a user .mid `call Rt.<exported>` (an EXPORTED runtime key), end to
# end.  user-mid-rtcall.mid's `RtCall.read` calls `Rt.read-file-as-string`
# (exported, so J2 accepts it); before this unit the callee was never SEEDED
# into the emitted Rt subset, so the binary failed to LINK on
# q_Rt_x2eread_x2dfile_x2das_x2dstring.  run_midrt creates rtcall-input.txt in
# the run dir and expects its content (the printed value is load-bearing on
# the seeded call).  The golden is `"rtcall-ok"` (the driver quotes strings).
run_midrt user-mid-rtcall UserMidRtCall.main tools/qbe/fixtures/user-mid-rtcall.elm tools/qbe/fixtures/user-mid-rtcall.mid
# M3fix-4 (b) — THE midcallmissing ROW IS RETIRED AT ZIGHOST Z0, and this is
# why it cannot be re-pointed: its whole subject was a user .mid `call` naming a
# key that resolves at J2 but is NO defun of this program, and the ONLY way to
# reach that state was QBE_NOMIDRT=1 (withhold the Mid Rt program so
# `Rt.read-file-as-string` has nothing behind it).  NOMIDRT is a
# MIDGC_DEPENDS_ON entry, so while the Zig collector existed the row could pair
# it with QBE_MIDGC=0; the collector is unconditional now, the guard refuses
# every NOMIDRT=1 build outright (exit 2), and a row built on it would measure
# the GUARD's message instead of the program's.  The fixtures stay
# (tools/qbe/fixtures/midcallmissing.{elm,mid}) — the loud refusal they exercise
# is still covered by the rows above, which reach it through a plain dangling
# key.  Deleted: the run_midref call that named them.
# M4 (goal 4): the WORKED END-TO-END EXAMPLE — an Osier source IMPORTING a .mid
# BY NAME.  importmid.elm declares `import Midmath`; run.js resolves that to
# Midmath.mid next to the fixture (the .mid is NOT passed on the CLI — `run`
# passes only the .elm), and Midmath.answer does the raw-word arithmetic whose
# result 14 (= 6 + 7 + 1) is the .mid's own behaviour made visible.
run importmid ImportMid.main tools/qbe/fixtures/importmid.elm
# M4 (goal 2): the LOUD class-misuse refusal — ImportBad calls Midmath's
# `float -> val` export doubleIt with a String, so the Osier-side check against
# the DECLARED type refuses the compile (cannot unify Float with String).
run_importref importbad ImportBad.main tools/qbe/fixtures/importbad.elm 'cannot unify Float with String'
# M4 (goal 1): the LOUD header-mismatch refusal — importmis.elm imports
# `Mismatch`, but Mismatch.mid declares `module Othername`; the reader refuses
# because a .mid's module header must match the import name.
run_importref importmis ImportMis.main tools/qbe/fixtures/importmis.elm 'declares module Othername'
# CONTRACT 3 (`!io`) — CARRIED, NOT ENFORCED (plan.md §2.5).  This row is the
# HONEST PRESENT TENSE: Iopin.mid exports an IMPURE defun marked `!io` (it
# raw-`write`s "io:" to stdout before returning its argument) and an Osier
# module imports the .mid by name and calls it directly — the program compiles
# and runs, printing "io:7".  There is nothing to enforce it AGAINST: Osier has
# no effect system (MEASURED: no effect row anywhere in Type/*; Osier code is
# pure by construction, the only impurity sources are mid exports), so `!io`
# is documentation today.  The marker is genuinely PARSED (any other marker is
# a loud refusal: "unknown export marker `!bogus` — the markers are exactly
# `!io` and `!taint`") and genuinely INERT downstream (MEASURED: the emitted
# .ssa is BYTE-IDENTICAL with the marker removed; `ExportSig.effects` is read
# only by TestMain — nothing in the checker or the lowerer consumes it).
#
# WHY A GATE ROW: the day Phase 7 starts enforcing `!io`, THIS row goes RED —
# that flip is the asymmetry oracle showing the change was deliberate and
# exactly what it changed, instead of an enforcement that slipped in silently.
# Do not "fix" a red here by dropping the marker or the row: a red means the
# contract moved, and the plan (and this comment) must move with it.
# The write is load-bearing on the golden: drop the impure call and the fixture
# prints "7", not "io:7".
run iopin IoPin.main tools/qbe/fixtures/iopin.elm
# M4NICE item 3 (review NICE-TO-HAVE 3): THE END-TO-END PIN OF THE `word`
# UNCALLABILITY CLAIM.  Wordy.mid exports `poke : word -> val`; `word` maps to
# the RIGID opaque type (QbeModule.exportScheme), so the concrete literal `5`
# cannot inhabit it.  The refusal is composed from TWO unifier facts (a name
# mismatch CannotUnify: Type/Unify.elm:354-356, and a literal's FlexConflict:
# bindVar's propagate FNumber, Type/Unify.elm:491-497,708-719) — until this row
# only the MAPPING and the facts were pinned, in TestMain, never the composition.
run_importref wordcall WordImp.main tools/qbe/fixtures/wordimp.elm 'cannot unify number with Word'
# M4-enforce U1 (contract 4): THE RETURN-TAINT FLOOR.  Each REJECT row is the
# fail-before oracle — it COMPILED on the pre-U1 compiler (rc=0) and must now be
# REFUSED naming "taint error".  taintret returns the mid result directly;
# taintclosure returns a closure CAPTURING it; tainttrans returns a tainted
# helper's result (the least-fixpoint row).  The three stay-legal rows below
# (taintsafe/taintlocal/taintderived) are the over-tightening net: the owner's
# let + self-recursive-lambda case MUST still compile and print 42.
run_importref taintret Taintret.main tools/qbe/fixtures/taintret.elm 'taint error'
run_importref taintclosure Taintclosure.main tools/qbe/fixtures/taintclosure.elm 'taint error'
run_importref tainttrans Tainttrans.main tools/qbe/fixtures/tainttrans.elm 'taint error'
run taintsafe Taintsafe.main tools/qbe/fixtures/taintsafe.elm
run taintlocal Taintlocal.main tools/qbe/fixtures/taintlocal.elm
run taintderived Taintderived.main tools/qbe/fixtures/taintderived.elm
# M4NICE item 1 (review NICE-TO-HAVE 1): THE TOKEN-RULE MIRROR.  The reader's
# `import` scan is a column-0 LINE scan, so `importtab.elm`'s comment line
# `import<TAB>Tabimp` is a candidate — but a TAB is not an import separator in
# EITHER lane (the separator class is the CORE's whitespace, space/`\r`:
# ParserFast.elm:2852).  Tabimp.mid declares `module Othername` on purpose, so a
# reader that DOES resolve the line refuses the compile ("declares module
# Othername") — which is what run.js's old `\s+` regex did, to a LEGAL program.
# The row is green only if the tab line resolves nothing and the program prints 7.
run importtab ImportTab.main tools/qbe/fixtures/importtab.elm
# M4NICE item 2 (review NICE-TO-HAVE 2): the reader's WHITESPACE rules — a CRLF
# `.mid`, a blank first line, both, and an indented one must all emit the same
# bytes as the LF original, and all four spellings of a MISMATCHED `.mid` must
# be refused at the READER (never falling through to a core "unknown name").
# See run_midws for the two modes.
run_midws midws ImportMid.main tools/qbe/fixtures/importmid.elm tools/qbe/fixtures/Midmath.mid
run_midws midwsref ImportMis.main tools/qbe/fixtures/importmis.elm tools/qbe/fixtures/Mismatch.mid 'declares module Othername'
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
# PERF-DEBT gc1 (2026-10-18) — THE SIZE-CLASS ALLOCATOR and its OOB guard: the
# free list was EXACT-MATCH-ONLY (plan.md stage-4 finding 3), so a program
# allocating two shapes died "midgc: out of memory" with memory free.  The
# class ladder + this row's neighbours landed in `4c71924`, and `Rt.gcAllocGo`'s
# class-index bound in `29729d7` (a request bigger than the heap used to index
# PAST the class table — signal 11, not a loud die).  Both fail-before /
# pass-after asymmetries are scripted: `tools/qbe/probe-midgc-mixed.sh` (the
# exact-match OOM) and `tools/qbe/probe-midgc-oom.sh` (the OOB index; its
# control arm re-runs the same fixture at QBE_HEAP_MB=32, where the request
# fits, so the crash is attributable to the index and not to the request).
# zigretire stage 5 PART 5 — THE OTHER HALF of the census refusal: a PURE
# program churning a >3-arg MUTUAL tail recursion must NOT corrupt.  The
# transient tail array (rt_tail_known's nargs>3 fallback, rt.zig:817) is a
# Zig-scavenge TRIGGER (tail_gcarray=3,000,000) but not itself live across a
# safepoint — so it is not a hole by itself.  The kept string is Mid-allocated
# (++ -> cn -> Rt.cn -> RawAllocRaw), so it is NOT reclaimable by the Zig
# collector and survives.  This is the probe that distinguishes THE TRIGGER
# from THE HOLE (the hole is the host-IO fixture, refused at compile time).
run_midgc midgc-tail MidgcTail.main tools/qbe/fixtures/midgc-tail.elm

# stage 6 B1 — the MID APPLY arms under MIDGC x MIDDRIVER: the same three
# cross-heap probes, now with the apply family ROUTED TO MID (Rt.apply's
# partial arm allocates the env array via Rt.allocVector, Rt.apply-tail's
# saturated arm the .tail env array — the exact cross-heap edge the stage-5
# review named).  The golden is run_midgc's (the sum/string is collector- and
# routing-agnostic).
run_mdgc mdgc-partial   midgc-partial   MidgcPartial.main  tools/qbe/fixtures/midgc-partial.elm
run_mdgc mdgc-closure   midgc-closure   MidgcClosure.main  tools/qbe/fixtures/midgc-closure.elm
run_mdgc mdgc-tail      midgc-tail      MidgcTail.main     tools/qbe/fixtures/midgc-tail.elm
# zigretire stage 5 PART 5 nice-to-have 4 — THE MID-RAW STRING MARKING PROBE:
# a concat/++-built (Rt.cn -> RawAllocRaw -> Mid) string kept across a MID
# COLLECT (the churn's 150k conses force the collector).  Every prior string
# fixture kept STATIC literals, whose mark is a no-op; this one makes gcMarkValue's
# tag-1 (data-pointer) marking falsifiable (verified: disabling that one mark
# prints "0|150" — the sweep reclaims the kept data bytes).
run_midgc midgc-rawstr MidgcRawstr.main tools/qbe/fixtures/midgc-rawstr.elm
# zigretire stage 5 PART 5's HOST-IO REFUSAL ROW IS GONE (stage 7 O2): it
# asserted that QBE_MIDGC=1 REFUSES a host-IO program at compile time, and O2
# deleted that refusal arm with the census — the Mid host is the DEFAULT now, so
# the combination it refused is the SOUND one (one heap on the path).
# WHAT REPLACED IT: the default-path golden below (unchanged), plus the row that
# is no longer a refusal — QBE_MIDGC=1 on this fixture now COMPILES and must
# print the same golden, which is the whole point of the flip.  That assertion
# needs the builder that qbe-check has no shape for here (it wants MIDGC_IO_IN
# AND QBE_MIDGC=1 at build time), so it lives in tools/qbe/probe-midgc-io.sh as
# both arms of an asymmetric pair: PASS-AFTER = "MIDGC=1 compiles and prints
# 100|150" here, FAIL-BEFORE = "disable run.js's QBE_MIDHOST guard, force the
# Zig host, and the same build prints 0|150".  MEASURED, and it is the only
# scripted statement of which host the default selects.
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
# charord: Char ORDERING (<, <=, >, >=) must not silently lower to False —
# the four operators plus the == and Int controls are pinned as distinct
# decimal digits of one golden (see the fixture).  Fail-before: 10100000000
# (every ordering digit 0); the fix makes each ordering digit match real Elm's
# code-point order.
run charord     CharOrd.main    tools/qbe/fixtures/charord.elm
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

# ---- stage-6 B0: the two-arity-interleaved frame-reuse probe (R2's oracle) ----
# interleave: `small` (lean frame) and `big` (fat frame — six live conses)
# are mutually TAIL-recursive, so the bounce loop enters/leaves their frames
# in alternating sizes and the freelist pools BOTH.  A wrong freelist index
# cross-reuses the two sizes -> heap corruption or a stale slot surviving a
# collect, visible as a wrong answer under CHURN_MB.  The result is
# deterministic (20000 cycles x 2102 = 42040000).
run interleave Interleave.main tools/qbe/fixtures/interleave.elm

# ---- stage-6 B0perf: THE MISSING PERF GATE (why the 175x regression slipped) ----
# fib 28 is ~393k calls, every call entering a pooled frame.  Under the PRE-FIX
# per-byte frameZero the hatch-ON (Mid frames) arm took ~5s vs the hatch-OFF
# (Zig frames) arm's ~46ms — ~110x; fib 30 was ~175x.  B0perf's :val slot-loop
# landed at ~150ms — ~3.3x; B0perf-2's rawAbi WORD loop (no per-iteration Value
# blit) lands at ~1.6x.  No prior oracle saw this: the corpus checks BYTES and
# the churn rows check OUTPUT, so a 175x RUNTIME regression was invisible.
#
# THE BOUND IS A RATIO, not an absolute time — the loaded-host rule: a busy
# host slows BOTH arms of the SAME machine together, and the ratio cancels
# that; an absolute bound is exactly the flake this repo rejects.  Report the
# MEDIAN of 5 ALTERNATED pairs (a single scheduling spike on one arm is a
# non-median outlier).  BOUND BASIS (B0perf-2, MEASURED alternating pairs):
#   fib 28  before 156/50ms = 3.12x  ->  after 118/77ms = 1.53x
#   fib 30  before 407/125ms = 3.26x ->  after 207/122ms = 1.70x
# (the after floor is ~1.5-1.7x, with load-transition spikes to ~2.1x on a
# busy host; the pre-fix :val loop is ~3.1-3.3x).  The bound is 2.5x: ~0.9x
# headroom above the measured floor and its load spikes, and ~0.6x BELOW the
# pre-fix 3.12x — tight enough to catch a regression back to the :val blit
# loop, loose enough to never flake on a loaded host.
# BOTH arms must also print the SAME fib(28) (317811): a wrong zero is a
# wrong answer, caught here too (the churn rows already cover the GC side).
#
# B4 RE-BASE: the hatch-OFF (Zig) arm is DELETED, so the "OFF" side is now the
# committed pre-B4 reference binary (tools/qbe/ref/fib/fib, frozen at cf59488)
# instead of a live QBE_MIDDRIVER=0 build.  The ratio is Mid-vs-FROZEN-Zig, so
# it may read slightly differently than the live measurement (frame 0.97x,
# apply 1.6x, tail 1.5x measured against the LIVE Zig arm just before B4); the
# bounds are KEPT, not retuned to taste.  ASYMMETRY is preserved: a degraded
# Mid arm (QBE_NORTLEAN=1, the fat ABI) still exceeds the bound (shown once,
# for this gate, in the B4 handoff evidence — not as a permanent row).
frame_perf_gate() {
  local bin_on on_times=() ref_times=() i s e on_med ref_med ratio out_on out_ref ref_bin
  bin_on="$("$ROOT/tools/qbe/qbe-mk.sh" tests/elm-fixtures/fib.elm Fib.fib "$TMP/perf-on")" || {
    echo "FAIL frame-perf: qbe-mk (Mid arm)"; FAIL=1; return; }
  ref_bin="$ROOT/tools/qbe/ref/fib/fib"
  [ -x "$ref_bin" ] || { echo "FAIL frame-perf: reference binary missing ($ref_bin)"; FAIL=1; return; }
  out_on="$(timeout 60 "$bin_on" Fib.fib 28 2>&1)"
  out_ref="$(timeout 60 "$ref_bin" Fib.fib 28 2>&1)"
  if [ "$out_on" != "$out_ref" ]; then
    echo "FAIL frame-perf: Mid fib(28)='$out_on' != reference='$out_ref' (the zero differs across arms)"
    FAIL=1; return
  fi
  for i in 1 2 3 4 5 6 7; do
    s=$(date +%s%N); timeout 60 "$bin_on" Fib.fib 28 >/dev/null 2>&1; e=$(date +%s%N)
    on_times+=("$(( (e - s) / 1000000 ))")
    s=$(date +%s%N); timeout 60 "$ref_bin" Fib.fib 28 >/dev/null 2>&1; e=$(date +%s%N)
    ref_times+=("$(( (e - s) / 1000000 ))")
  done
  on_med="$(printf '%s\n' "${on_times[@]}" | sort -n | sed -n '4p')"
  ref_med="$(printf '%s\n' "${ref_times[@]}" | sort -n | sed -n '4p')"
  ratio="$(awk -v a="$on_med" -v b="$ref_med" 'BEGIN { printf "%.2f", (b > 0 ? a / b : 999) }')"
  if awk -v a="$on_med" -v b="$ref_med" 'BEGIN { exit !(a > 2.5 * b) }'; then
    echo "FAIL frame-perf: Mid median ${on_med}ms is ${ratio}x the reference median ${ref_med}ms — bound is 2.5x (the :val frame-zero blit regression shape)"
    FAIL=1; return
  fi
  echo "PASS frame-perf: Mid median ${on_med}ms / reference median ${ref_med}ms = ${ratio}x (bound 2.5x, reference frozen at cf59488), both fib(28)=${out_on}"
}
frame_perf_gate

# ---- stage 6 P1c/P1e: the FRAME-PATH structural pin (the feature FIRES) ----
# fib's frame enter/leave path was the boxed-boolean hot spot: frameBlock
# carried 4 `mkbool` conditions and frameZero 1, each a `storew 3` (boolean
# tag) + `storel` payload + load-back + compare chain before the `jnz`
# (~10 instructions apiece).  The P1c word cond replaced each with a direct
# `jnz` on the raw 0/1 word — no slot, no store, no reload — and P1e then
# DELETED frameZero (the per-slot zeroing loop) for ONE `memset` in
# frame-enter.  This pin reads the EMITTED .ssa (the lowering, not the
# result): frameBlock's mkbool shape (`storew 3,`) must be ABSENT and its
# instruction count at or under the word-cond bound, and frame-enter must
# carry exactly ONE bulk-zero memset call.  MEASURED:
#   frameBlock  107 instrs + 4 storew-3 (53be0c1)  ->  67 instrs + 0 (P1c)
#   frameZero    50 instrs + 1 storew-3 (53be0c1)  ->  39 instrs + 0 (P1c)  -> DELETED (P1e)
# The bound (80) splits the before/after with headroom; a regression back to
# boxing fails BOTH the grep and the count.  The memset count carries the
# P1e shape: 0 would mean the bulk zero is gone (or was never emitted), 2+
# that something re-introduced a second zeroing pass.
frame_wordcond_pin() {
  local ssa fb fe fb3 fb_i fe_memset ok
  ssa="$TMP/frame-wordcond.ssa"
  (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY=Fib.fib node run.js "$ROOT/tests/elm-fixtures/fib.elm" "$ssa") >/dev/null 2>&1
  if [ ! -s "$ssa" ]; then
    echo "FAIL frame-wordcond: fib .ssa missing (compile failed)"
    FAIL=1; return
  fi
  fb="$(sed -n '/^function l \$q_Rt_x2eframeBlock(/,/^}/p' "$ssa")"
  # P1e deleted Rt.frameZero (the per-slot loop) for a single memset in
  # Rt.frame-enter, so this pin tracks frameBlock ALONE and asserts the
  # memset the zeroing became.  It keeps the vacuity guard for both: a defun
  # that vanished would otherwise make "0 matches" read as a pass.
  fe="$(sed -n '/^function l \$q_Rt_x2eframe_x2denter(/,/^}/p' "$ssa")"
  if [ -z "$fb" ] || [ -z "$fe" ]; then
    echo "FAIL frame-wordcond: frameBlock/frame-enter defun not found in fib .ssa (the pin is vacuous)"
    FAIL=1; return
  fi
  fb3="$(printf '%s\n' "$fb" | grep -c 'storew 3,')"
  fb_i="$(printf '%s\n' "$fb" | awk '{ line=$0; sub(/^[ \t]+/,"",line); if (line !~ /^@/ && line !~ /^#/ && line !~ /^function/ && line !~ /^}/) c++ } END { print c+0 }')"
  fe_memset="$(printf '%s\n' "$fe" | grep -c 'call \$memset')"
  ok=1
  if [ "$fb3" -ne 0 ]; then echo "FAIL frame-wordcond: frameBlock still boxes a cond (storew 3 x $fb3)"; ok=0; fi
  if [ "$fb_i" -gt 80 ]; then echo "FAIL frame-wordcond: frameBlock instruction count $fb_i > 80 (boxed-cond shape)"; ok=0; fi
  if [ "$fe_memset" -ne 1 ]; then echo "FAIL frame-wordcond: frame-enter does not bulk-zero with exactly ONE memset call (found $fe_memset)"; ok=0; fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS frame-wordcond: frameBlock emits no mkbool shape (storew 3 x $fb3, $fb_i instructions, bound 80) and frame-enter bulk-zeroes with one memset call"
  else
    FAIL=1
  fi
}
frame_wordcond_pin

# ---- stage 6 B1: the apply-family perf gate ----
# frame_perf_gate's fib is DIRECT defun calls + frames — it never calls a
# closure VALUE, so the apply family (Rt.apply -> applyGo -> Rt.copyWords ->
# Rt.callArity) is OFF its hot path.  applyperf.elm makes every iteration a
# closure-VALUE call, so the apply arms are the whole cost.  MEASURED (median
# of 7 alternating pairs, the frame-gate method) at n=5e6:
#   B1debt (copyWords :val loop):  hatch-ON ~3.83s / OFF ~0.33s = ~11.6x
#   B1fix  (copyWords word loop):  hatch-ON ~3.16s / OFF ~0.33s = ~9.5x
# The B1fix copyWords word loop (no per-word blit/boxing) is a REAL ~17% ON-arm
# win, but it does NOT close the floor: the remaining ~9.5x is the apply
# family's per-call FRAMING + :val blit overhead (frame-enter x3 per call, the
# root push/pop, and applyGo's four 40-byte re-blits of the same `f` param to
# read its fields) — NOT copyWords (which copies only 5 words for this fixture).
# THE BOUND IS 12x = the measured post-fix floor 9.5x + 2.5x absolute headroom
# (the frame gate's ~1x discipline, widened for the apply family's higher load
# variance — the B1debt run saw a 2.2x load spike on the ON arm).  HONEST
# ASYMMETRY: because copyWords is ~15% of the floor, the pre-fix shape (11.6x)
# is NOT cleanly separated from the post-fix floor — a bound that FAILS the
# pre-fix shape would be ~10.5x, inside the floor's run-to-run noise (a flake).
# 12x keeps the gate a flake-proof catastrophic guard; closing the REAL floor
# (the apply-family framing) is a separate B1perf unit, out of this one's scope.
# Both arms must print the SAME n (identity: 2*n).
#
# B4 RE-BASE: the hatch-OFF (Zig) arm is DELETED; the "OFF" side is now the
# committed pre-B4 reference binary (tools/qbe/ref/applyperf/applyperf, frozen
# at cf59488).  The ratio is Mid-vs-FROZEN-Zig; the bound (12x) is KEPT, not
# retuned.  Measured just before B4 against the LIVE Zig arm: apply 1.6x.
apply_perf_gate() {
  local bin_on on_times=() ref_times=() i s e on_med ref_med ratio out_on out_ref ref_bin
  bin_on="$("$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/applyperf.elm ApplyPerf.main "$TMP/applyperf-on")" || {
    echo "FAIL apply-perf: qbe-mk (Mid arm)"; FAIL=1; return; }
  ref_bin="$ROOT/tools/qbe/ref/applyperf/applyperf"
  [ -x "$ref_bin" ] || { echo "FAIL apply-perf: reference binary missing ($ref_bin)"; FAIL=1; return; }
  out_on="$(timeout 60 "$bin_on" ApplyPerf.main 5000000 2>&1)"
  out_ref="$(timeout 60 "$ref_bin" ApplyPerf.main 5000000 2>&1)"
  if [ "$out_on" != "$out_ref" ]; then
    echo "FAIL apply-perf: Mid n(5e6)='$out_on' != reference='$out_ref' (the closure call differs across arms)"
    FAIL=1; return
  fi
  for i in 1 2 3 4 5 6 7; do
    s=$(date +%s%N); timeout 60 "$bin_on" ApplyPerf.main 5000000 >/dev/null 2>&1; e=$(date +%s%N)
    on_times+=("$(( (e - s) / 1000000 ))")
    s=$(date +%s%N); timeout 60 "$ref_bin" ApplyPerf.main 5000000 >/dev/null 2>&1; e=$(date +%s%N)
    ref_times+=("$(( (e - s) / 1000000 ))")
  done
  on_med="$(printf '%s\n' "${on_times[@]}" | sort -n | sed -n '4p')"
  ref_med="$(printf '%s\n' "${ref_times[@]}" | sort -n | sed -n '4p')"
  ratio="$(awk -v a="$on_med" -v b="$ref_med" 'BEGIN { printf "%.2f", (b > 0 ? a / b : 999) }')"
  if awk -v a="$on_med" -v b="$ref_med" 'BEGIN { exit !(a > 12 * b) }'; then
    echo "FAIL apply-perf: Mid median ${on_med}ms is ${ratio}x the reference median ${ref_med}ms — bound is 12x (the :val copyWords blit regression shape)"
    FAIL=1; return
  fi
  echo "PASS apply-perf: Mid median ${on_med}ms / reference median ${ref_med}ms = ${ratio}x (bound 12x, reference frozen at cf59488), both n(5e6)=${out_on}"
}
apply_perf_gate

# ---- stage 6 B2: the tail/bounce perf gate ----
# mutual-tail 1e6 is the deep-cross-defun-tail workload: every hop builds a
# .tail (Mid Rt.tail-known: static buffer + copy + malloc(80) Ret) and chases
# it (Mid Rt.bounce -> Rt.bounceGo: the 17-arm aggcall dispatch + :val recur).
# This is the B2 hot path — rt_bounce/rt_tail_known sit on ~20,318 corpus
# call sites.  MEASURED (median of 7 alternating pairs, 1e6 hops):
#   hatch-ON  ~161ms / hatch-OFF ~56ms = ~2.9x
# The 2.9x floor (vs the 1.6x frame floor) is the tail family's residual: the
# per-call malloc(80) Ret in Rt.tail-known (the rawAbi Agg-"ret" convention B1
# already chose for Rt.apply-tail's saturated arm), the 17-arm LINEAR if-chain
# dispatch (the Zig's jump table), and the bounceGo :val loop's per-hop
# mknum+blit.  None is a GC allocation and the loop is an in-frame jmp (the
# md-mutual-tail row pins constant stack), so this is a REPORTED floor, not a
# silent 175x-class regression.  THE BOUND IS 6x = the 2.9x floor + ~3x
# headroom (the frame gate's discipline, widened for the chain's higher
# per-hop variance) — tight enough to catch a regression to a per-hop GC
# allocArray or a full-Ret :val blit loop (10x+), loose enough never to flake.
# Both arms must print the SAME answer ("1").
#
# B4 RE-BASE: the hatch-OFF (Zig) arm is DELETED; the "OFF" side is now the
# committed pre-B4 reference binary (tools/qbe/ref/mutualtail/mutualtail,
# frozen at cf59488).  The ratio is Mid-vs-FROZEN-Zig; the bound (6x) is KEPT,
# not retuned.  Measured just before B4 against the LIVE Zig arm: tail 1.5x.
tail_perf_gate() {
  local bin_on on_times=() ref_times=() i s e on_med ref_med ratio out_on out_ref ref_bin
  bin_on="$("$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/mutualtail.elm Mutual.even "$TMP/tailperf-on")" || {
    echo "FAIL tail-perf: qbe-mk (Mid arm)"; FAIL=1; return; }
  ref_bin="$ROOT/tools/qbe/ref/mutualtail/mutualtail"
  [ -x "$ref_bin" ] || { echo "FAIL tail-perf: reference binary missing ($ref_bin)"; FAIL=1; return; }
  out_on="$(timeout 120 "$bin_on" Mutual.even 1000000 2>&1)"
  out_ref="$(timeout 120 "$ref_bin" Mutual.even 1000000 2>&1)"
  if [ "$out_on" != "$out_ref" ]; then
    echo "FAIL tail-perf: Mid mutual-tail(1e6)='$out_on' != reference='$out_ref' (the tail chase differs across arms)"
    FAIL=1; return
  fi
  for i in 1 2 3 4 5 6 7; do
    s=$(date +%s%N); timeout 120 "$bin_on" Mutual.even 1000000 >/dev/null 2>&1; e=$(date +%s%N)
    on_times+=("$(( (e - s) / 1000000 ))")
    s=$(date +%s%N); timeout 120 "$ref_bin" Mutual.even 1000000 >/dev/null 2>&1; e=$(date +%s%N)
    ref_times+=("$(( (e - s) / 1000000 ))")
  done
  on_med="$(printf '%s\n' "${on_times[@]}" | sort -n | sed -n '4p')"
  ref_med="$(printf '%s\n' "${ref_times[@]}" | sort -n | sed -n '4p')"
  ratio="$(awk -v a="$on_med" -v b="$ref_med" 'BEGIN { printf "%.2f", (b > 0 ? a / b : 999) }')"
  if awk -v a="$on_med" -v b="$ref_med" 'BEGIN { exit !(a > 6 * b) }'; then
    echo "FAIL tail-perf: Mid median ${on_med}ms is ${ratio}x the reference median ${ref_med}ms — bound is 6x (the per-hop GC-alloc / :val-blit regression shape)"
    FAIL=1; return
  fi
  echo "PASS tail-perf: Mid median ${on_med}ms / reference median ${ref_med}ms = ${ratio}x (bound 6x, reference frozen at cf59488), both mutual-tail(1e6)=${out_on}"
}
tail_perf_gate

# ---- stage 6 B2fix: the per-call malloc(80) Ret LEAK gate ----
# Rt.tail-known (and both Rt.apply-tail arms) malloc an 80-byte :ret buffer per
# tail call and, before B2fix, nothing ever freed it: the Lower Agg-ret @ret
# block blit the 80 bytes out into the caller's sret and dropped the pointer.
# Zig's rt_tail_known is heap-free (Ret by-value through sret), so this is a
# behaviour difference, not a perf nicety — ~80 B leaked per hop, ~936 MB peak
# RSS over the 1e7-hop mutual-tail chain measured PRE-fix (80 B payload + glibc
# chunk overhead), ~6 MB bounded POST-fix.  The gate runs the MID tail arm
# (the Mid tail arm, now the only route) at 1e7 hops and fails if peak RSS exceeds
# 200 MB — a bound the pre-fix binary blows through 4.5x and the fixed one
# never approaches.  A gate that cannot fail is not a gate: proven asymmetric.
leak_tail_gate() {
  local bin pid peak cur i out rc
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/mutualtail.elm Mutual.even "$TMP/leaktail")" || {
    echo "FAIL leak-tail: qbe-mk"; FAIL=1; return; }
  "$bin" Mutual.even 10000000 >"$TMP/leaktail.out" 2>&1 &
  pid=$!
  peak=0
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    cur="$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$cur" ] && [ "$cur" -gt "$peak" ] && peak="$cur"
    i=$((i + 1))
    if [ "$i" -gt 15000 ]; then
      kill "$pid" 2>/dev/null
      echo "FAIL leak-tail: mutual-tail(1e7) did not finish (killed after ~5min)"
      FAIL=1
      wait "$pid" 2>/dev/null
      return
    fi
    sleep 0.02
  done
  wait "$pid"
  rc=$?
  out="$(cat "$TMP/leaktail.out")"
  if [ "$rc" -ne 0 ] || [ "$out" != "1" ]; then
    echo "FAIL leak-tail: mutual-tail(1e7) exit=$rc out='$out' (golden 1)"
    FAIL=1
    return
  fi
  if [ "$peak" -gt 204800 ]; then
    echo "FAIL leak-tail: mutual-tail(1e7) peak RSS ${peak}kB > 200MB — the per-call malloc(80) Ret leaks"
    FAIL=1
    return
  fi
  echo "PASS leak-tail: mutual-tail(1e7) peak RSS ${peak}kB bounded (< 200MB; the Ret malloc(80) is freed per hop)"
}
leak_tail_gate

# ---- stage 6 P1a: the apply-family per-call malloc LEAK gate ----
# Rt.apply / Rt.apply-tail malloc a 32-byte state block per call and NEITHER
# freed it, and both the saturated and over-applied arms of Rt.applyGo /
# Rt.applyTailGo malloc a 640-byte args `buf` + 32-byte `disp` per dispatch —
# 704 B leaked per saturated closure call (state + buf + disp), NONE ever
# freed.  Zig's rt_apply is heap-free on the saturated path (a C-STACK
# `var buf: [max_arity]Value`, no state block), so this is a behaviour
# difference, not a perf nicety — MEASURED ~3.5 GB peak RSS over the 5e6-iter
# applyperf chain PRE-fix (~700 B/call x 5e6), ~6 MB bounded POST-fix.  The
# gate runs the MID apply arm (the Mid apply arm, now the only route) at 5e6 iters and
# fails if peak RSS exceeds 200 MB — a bound the pre-fix binary blows through
# ~17x and the fixed one never approaches.  A gate that cannot fail is not a
# gate: proven asymmetric (pre-fix 3668824 kB FAIL, post-fix 6164 kB PASS).
leak_apply_gate() {
  local bin pid peak cur i out rc
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" tools/qbe/fixtures/applyperf.elm ApplyPerf.main "$TMP/leakapply")" || {
    echo "FAIL leak-apply: qbe-mk"; FAIL=1; return; }
  "$bin" ApplyPerf.main 5000000 >"$TMP/leakapply.out" 2>&1 &
  pid=$!
  peak=0
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    cur="$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$cur" ] && [ "$cur" -gt "$peak" ] && peak="$cur"
    i=$((i + 1))
    if [ "$i" -gt 15000 ]; then
      kill "$pid" 2>/dev/null
      echo "FAIL leak-apply: applyperf(5e6) did not finish (killed after ~5min)"
      FAIL=1
      wait "$pid" 2>/dev/null
      return
    fi
    sleep 0.02
  done
  wait "$pid"
  rc=$?
  out="$(cat "$TMP/leakapply.out")"
  if [ "$rc" -ne 0 ] || [ "$out" != "10000000" ]; then
    echo "FAIL leak-apply: applyperf(5e6) exit=$rc out='$out' (golden 10000000)"
    FAIL=1
    return
  fi
  if [ "$peak" -gt 204800 ]; then
    echo "FAIL leak-apply: applyperf(5e6) peak RSS ${peak}kB > 200MB — the per-call malloc(640)+malloc(32)+malloc(32) leaks"
    FAIL=1
    return
  fi
  echo "PASS leak-apply: applyperf(5e6) peak RSS ${peak}kB bounded (< 200MB; the apply-family malloc(state/buf/disp) is freed per call)"
}
leak_apply_gate

# ---- THE GENERIC-APPLY TAIL CHAIN IS CONSTANT-STACK (the 2-frames-per-hop gate) ----
# WHY THIS ROW EXISTS.  `clostail` is the ONE fixture whose chain routes through
# the GENERIC apply path — main's tail call of a closure goes Rt.apply-tail ->
# Rt.applyTailGo -> the callee, and every hop of the `f n` / `main (x-1)` pair
# re-enters it.  Until this row existed it was checked only at n=5 (the `run
# clostail` row above), where per-hop stack growth is INVISIBLE: 5 hops x 2.7 KB
# is 13 KB.  What keeps that chain constant-stack is the .tail/bounce
# TRAMPOLINE (a hop hands its .tail descriptor back to Rt.bounceGo, whose `recur`
# loop runs the next hop after the previous hop's frames are GONE) — and NOTHING
# gated it.  mutualtail/leaktail do not: they are STATIC chains that never route
# through generic apply.  TestMain's B2 row pins that bounceGo is DELETED, not
# that the stack is bounded.  So this is the only instrument on a property the
# apply-chain rework must preserve (apply-chain-design.md §3), and it exists
# BEFORE the deletion so a regression cannot land behind a green suite.
#
# THE BUDGET IS THE MUTUALTAIL DISCIPLINE: an OWNED 8 MiB stack
# (`prlimit --stack=8388608`) + QBE_NO_RLIMIT=1, so the runtime's own 64 MiB
# raise cannot mask growth.  `prlimit` (not a `( ulimit -s ... )` subshell) is
# deliberate: it EXECS the binary, so /proc/$pid is the SUBJECT — a subshell
# would make the sampler read bash's RSS and the bound would gate nothing.
#
# ASYMMETRY — MEASURED, both directions.  The mutation is the "relay scratch"
# patch in Rt.applyTailGo's SATURATED arm: chase the hop's own .tail descriptor
# through the hop's OWN frame (`Rt.bounceGo(...)`) and return a `.done` Ret,
# instead of handing the descriptor back to the caller's trampoline — the
# 2-frames-per-hop shape Q1b's blocked Stage 2 would have produced.  (It must
# re-wrap as a `.done` Ret: apply-tail's rawAbi `ret` class cannot carry a
# value, which is the C4 constraint that makes a tcall legal there only after
# the class flip.)  Not runner-derivable, so it is recorded here and in the
# handoff node, not repeated in CI.
#   PASS (clean tree): n=1e6 -> rc 0, out "0", peak RSS 16276 kB; n=1e7 ->
#     rc 0, 16276 kB.  FLAT across a 10x n: constant-stack, no per-hop leak.
#   FAIL (relay patch, same tree): n=2000 -> rc 0; n=3000 -> rc 139 (SIGSEGV,
#     no output) = ~2.7 KB of C stack per hop under the 8 MiB cap; n=1e5 and
#     n=1e6 also rc 139.  n=0..2000 still print 0, so the build is CORRECT and
#     the row is red on the STACK, not on a wrong answer.
#
# THE RSS HALF catches the other silent class: a forgotten rootPop/free on the
# chain (the 32 B state / 80 B Ret / 640 B args buffer per hop).  The bound is
# 32 MB = 2x the measured 16.28 MB peak (the GC heap, stable to +-30 kB over 5
# runs), which fails on a >=16 B/hop leak at 1e6 hops and never flakes clean.
clostail_gate() {
  local fixture="$ROOT/tools/qbe/fixtures/clostail.elm" bin pid peak cur i out rc
  [ -f "$fixture" ] || {
    echo "FAIL clostail-big: $fixture is missing — the ONLY fixture whose tail chain routes through the generic apply path was deleted"
    FAIL=1; return; }
  [ -x "$ROOT/tools/qbe/qbe-mk.sh" ] || {
    echo "FAIL clostail-big: tools/qbe/qbe-mk.sh is missing or not executable — no runner, so the apply chain's stack behaviour has no oracle"
    FAIL=1; return; }
  command -v prlimit >/dev/null 2>&1 || {
    echo "FAIL clostail-big: prlimit is missing — the row cannot OWN an 8 MiB stack, and an inherited one measures nothing"
    FAIL=1; return; }
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" ClosTail.main "$TMP/clostailbig")" || {
    echo "FAIL clostail-big: qbe-mk"; FAIL=1; return; }
  [ -x "$bin" ] || {
    echo "FAIL clostail-big: qbe-mk produced no executable at $bin"; FAIL=1; return; }
  QBE_NO_RLIMIT=1 prlimit --stack=8388608:8388608 "$bin" ClosTail.main 1000000 \
    >"$TMP/clostailbig.out" 2>&1 &
  pid=$!
  peak=0
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    cur="$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$cur" ] && [ "$cur" -gt "$peak" ] && peak="$cur"
    i=$((i + 1))
    if [ "$i" -gt 3000 ]; then
      kill "$pid" 2>/dev/null
      echo "FAIL clostail-big: ClosTail.main(1e6) did not finish (killed after ~60s; the clean chain takes 0.3s)"
      FAIL=1
      wait "$pid" 2>/dev/null
      return
    fi
    sleep 0.02
  done
  wait "$pid"
  rc=$?
  out="$(cat "$TMP/clostailbig.out")"
  if [ "$rc" -ne 0 ] || [ "$out" != "0" ]; then
    echo "FAIL clostail-big: ClosTail.main(1e6) under an OWNED 8 MiB stack exit=$rc out='$out' (golden 0) — the generic-apply tail chain grew the stack per hop (a relay instead of a tail call; see this row's comment for the measured asymmetry)"
    FAIL=1
    return
  fi
  if [ "$peak" -gt 32768 ]; then
    echo "FAIL clostail-big: ClosTail.main(1e6) peak RSS ${peak}kB > 32MB — the apply chain leaks per hop (a forgotten rootPop/free on an apply arm)"
    FAIL=1
    return
  fi
  echo "PASS clostail-big: ClosTail.main(1e6) under an OWNED 8 MiB stack is constant-stack (rc 0, golden 0) and peak RSS ${peak}kB bounded (< 32MB)"
}
clostail_gate

# ---- U2: THE APPLY STAGING BLOCK MUST BE IN NON-GC MEMORY (the lap gate) ----
# WHY THIS ROW EXISTS.  U2's F-site tcall stages [closure, args...] into one
# block that Rt.apply-tail registers (kind 2, VALUE_ARRAY) and that the loop
# reads ACROSS USER CODE: the over-applied arm runs `rt_call2r` — the applied
# callee's whole body — and `recur`s, and the next iteration reads `sp->args`,
# an INTERIOR pointer into that block.  The first version of the seat used
# allocvec, which is YOUNG under the default nursery, and a kind-2 registration
# NEVER PROMOTES the block it names (gcScavRoots walks the cells via
# gcScavValueArray and never calls gcScavPtr on the base) while gcScavenge
# resets youngCursor — so the block's storage is reusable as soon as a scavenge
# ends, and the callee above is exactly what laps the nursery.  The old path
# (young off) had the same hole for the same reason: kind-2 marking never marks
# the block HEADER (gcScanValueArray marks the first CELL), so the block is
# sweepable while live.  The fix is that Rt.stage-apply mallocs: a C-heap block
# is neither young nor GC-owned, so the collector never moves it and never
# frees it, and the kind-2 registration does its real job — rewriting the
# CELLS' payload pointers in place.
#
# ASYMMETRY — MEASURED, both directions, through the fixture below (the
# reviewer's probe; the reason this is a row and not a comment):
#   RED on 2f58bfe (the allocvec seat): `qbe-rt: midgc: unknown value tag in
#     mark walk`, rc 1, at the DEFAULT nursery, at QBE_MIDGC_YOUNG_MB=1 and
#     under QBE_MIDGC_VERIFY=1.  With ONLY the 10 site lines reverted in the
#     emitted .ssa to the pre-U2 shape, the same binary prints 300042.
#   GREEN after the malloc fix: 300042 at the default nursery, at
#     QBE_MIDGC_YOUNG_MB=1, under VERIFY=1, and with QBE_MIDGC_YOUNG=0.
# The young-off arm is in the row deliberately: it is the regime where the
# block is sweepable rather than lappable, and it must stay closed too.
#
# THE ROW FAILS (never skips) when the fixture or the runner is absent — a
# deleted probe must not look like a pass.
lap_apply_gate() {
  local fixture="$ROOT/tools/qbe/fixtures/lapprobe.elm" bin out rc cfg
  [ -f "$fixture" ] || {
    echo "FAIL lap-apply: $fixture is missing — the ONLY fixture whose over-applied generic tail chain allocates across the staging block was deleted"
    FAIL=1; return; }
  [ -x "$ROOT/tools/qbe/qbe-mk.sh" ] || {
    echo "FAIL lap-apply: tools/qbe/qbe-mk.sh is missing or not executable — no runner, so the staging block's memory class has no oracle"
    FAIL=1; return; }
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" LapProbe.main "$TMP/lapapply")" || {
    echo "FAIL lap-apply: qbe-mk"; FAIL=1; return; }
  [ -x "$bin" ] || {
    echo "FAIL lap-apply: qbe-mk produced no executable at $bin"; FAIL=1; return; }
  for cfg in "" "QBE_MIDGC_YOUNG_MB=1" "QBE_MIDGC_VERIFY=1" "QBE_MIDGC_YOUNG=0"; do
    env $cfg "$bin" LapProbe.main >"$TMP/lapapply.out" 2>&1
    rc=$?
    out="$(cat "$TMP/lapapply.out")"
    if [ "$rc" -ne 0 ] || [ "$out" != "300042" ]; then
      echo "FAIL lap-apply: LapProbe.main${cfg:+ ($cfg)} exit=$rc out='$out' (golden 300042) — the F-site staging block was lapped or swept while the applied callee ran; it must be malloc'd, never allocvec (see this row's comment)"
      FAIL=1
      return
    fi
  done
  echo "PASS lap-apply: LapProbe.main prints 300042 in all 4 memory configurations (default nursery, YOUNG_MB=1, VERIFY=1, YOUNG=0) — the staged block survives a ~12 MB user allocation between hops"
}
lap_apply_gate

# ---- U3b stage 0(a): THE TWO STAGING SEATS MUST NEVER SHARE STORAGE (the
#      tsbuf-aliasing gate) ----
# WHY THIS ROW EXISTS.  There are TWO staging seats and they have OPPOSITE
# storage rules: Rt.stage-tail (the STATIC tail path) stages into the shared
# static buffer `tsbuf` (globals word 12) — sound there only because at most one
# .tail-shaped call is ever in flight — while Rt.stage-apply (the F-site generic
# path) must malloc.  The apply chain can hold TWO staged blocks at once: an
# over-applied hop's staged args stay live while the hop runs ARBITRARY USER
# CODE, and that user code can itself stage (a generic apply nested inside the
# hop, and a static tail hop inside that).  If Rt.stage-apply ever used tsbuf,
# the nested hops would overwrite the outer chain's staged args and hop 2 would
# read the NESTED staging's argument — every pointer still valid, no crash, a
# WRONG NUMBER.
#
# The hazard is closed BY CONSTRUCTION today (stage-apply's only allocation is
# `malloc`; tsbuf is loaded only by stage-tail) and NOTHING ELSE WATCHES IT: the
# lap-apply row above pins the block's MEMORY CLASS (GC vs C heap), not the
# aliasing, and a tsbuf arm would satisfy that row.  This row is the only
# witness, which is why it lands before U3b's deletions touch the staging family
# (u3a-review SHOULD-FIX 1: "the row MUST land before U3b's deletions").
#
# THE FIXTURE (tools/qbe/fixtures/tsbufprobe.elm) is the NESTED shape, and the
# row asserts BOTH halves of what makes it a test:
#   * STRUCTURAL — the emitted .ssa must still contain calls to BOTH seats.  A
#     fixture that stops reaching one of them is not a weaker test, it is no
#     test, and the behavioural half would keep passing.
#   * BEHAVIOURAL — the answer must be 42127 = 42*1000 + 1*100 + 2*10 + 7.  The
#     last factor is the OUTER chain's second staged arg, read at hop 2, after
#     the nested hops have staged twice.
#
# ASYMMETRY — MEASURED, both directions, on this tree.  The mutation is applied
# to the EMITTED .ssa (no rebuild), the same technique the lap-apply row used:
# (i) stage-apply's `malloc` + canary store replaced by a load of tsbuf, (ii)
# apply-tail's provenance-canary guard bypassed, (iii) applyTailGo's two
# `free(fslot - 8)` calls removed — (ii) and (iii) because with a tsbuf block
# the canary would fire and the free would abort, i.e. the loud guards would
# mask the class this row is about.
#   PASS (clean tree): TsbufProbe.main -> "42127", rc 0.
#   FAIL (mutated .ssa):  TsbufProbe.main -> "2127",  rc 0.  SILENT: the staged
#     arg was read back as 2 (the nested staging's second arg) instead of 42.
# The mutation is not runner-derivable, so it is recorded here and in the
# handoff node, not repeated in CI.
#
# THE ROW FAILS (never skips) when the fixture or the runner is absent — a
# deleted probe must not look like a pass.
tsbuf_apply_gate() {
  local fixture="$ROOT/tools/qbe/fixtures/tsbufprobe.elm" bin ssa out rc
  [ -f "$fixture" ] || {
    echo "FAIL tsbuf-apply: $fixture is missing — the ONLY fixture that holds two staged blocks at once (a generic tail apply nested inside an over-applied chain) was deleted"
    FAIL=1; return; }
  [ -x "$ROOT/tools/qbe/qbe-mk.sh" ] || {
    echo "FAIL tsbuf-apply: tools/qbe/qbe-mk.sh is missing or not executable — no runner, so the staging seats' storage classes have no oracle"
    FAIL=1; return; }
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" TsbufProbe.main "$TMP/tsbufapply")" || {
    echo "FAIL tsbuf-apply: qbe-mk"; FAIL=1; return; }
  [ -x "$bin" ] || {
    echo "FAIL tsbuf-apply: qbe-mk produced no executable at $bin"; FAIL=1; return; }
  ssa="$(dirname "$bin")/tsbufprobe.ssa"
  [ -f "$ssa" ] || {
    echo "FAIL tsbuf-apply: no emitted .ssa at $ssa — the structural half cannot be checked"
    FAIL=1; return; }
  grep -q 'call \$q_Rt_x2estage_x2dapply' "$ssa" || {
    echo "FAIL tsbuf-apply: the emitted .ssa never calls q_Rt_x2estage_x2dapply — the fixture no longer stages a generic apply inside the chain, so the nested-block half of this row tests nothing"
    FAIL=1; return; }
  grep -q 'call \$q_Rt_x2estage_x2dtail' "$ssa" || {
    echo "FAIL tsbuf-apply: the emitted .ssa never calls q_Rt_x2estage_x2dtail — the fixture no longer writes the shared static buffer inside the chain, so the aliasing half of this row tests nothing"
    FAIL=1; return; }
  out="$(timeout 60 "$bin" TsbufProbe.main 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$out" != "42127" ]; then
    echo "FAIL tsbuf-apply: TsbufProbe.main exit=$rc out='$out' (golden 42127) — the F-site staging block aliases the shared static buffer tsbuf: a nested hop overwrote the outer chain's staged args. Rt.stage-apply must malloc, never stage into tsbuf (see this row's comment)"
    FAIL=1; return
  fi
  echo "PASS tsbuf-apply: TsbufProbe.main prints 42127 (rc 0) with both staging seats exercised — two staged blocks were live at once and neither clobbered the other"
}
tsbuf_apply_gate

# ---- stage 4: arity > 8 (the old rt_callN table stopped at rt_call8) ----
# arity9: a 9-ary defun called DIRECTLY from the driver (rt_call9).  arity9apply:
# apply9 add9 -> f 1..9 where f is a Var, so the 9-ary call goes through
# rt_apply's saturation buffer (the generic/partial path the direct shape
# does not exercise).
run arity9      Arity9.add9     tools/qbe/fixtures/arity9.elm 1 2 3 4 5 6 7 8 9
run arity9apply Arity9.main9    tools/qbe/fixtures/arity9.elm
# partyapply: the PARTIAL -> OVER-APPLICATION chain (the stage-6 U0 ABI
# fixture).  add3 (arity 3) applied with 2 args yields a partial closure
# (applyGo's `rem > nargs` arm, the saturation buffer holding staged args);
# that closure is then applied with 2 MORE args than it still needs, so the
# OVER arm fires — saturate, call the body (which returns a FURTHER function),
# apply that result to the leftover arg.  Every rt_apply arm runs in one
# entry, and the answer is arg-order-sensitive: ((add3 1 2) 3) 4 = 1234.  The
# only other over-application row (arity9apply) is a single exactly-saturated
# call, not a chain.
run partyapply PartyApply.chain tools/qbe/fixtures/partyapply.elm

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

# ---- stage-6 U0: THE DRIVER CONTRACT — the error paths nothing pinned ----
# The four error paths rt.zig's main can take in its own argument handling
# (before generated code runs), each pinned on BOTH halves: the merged
# stdout+stderr bytes (golden, frozen from the CURRENT Zig driver) and the
# exit code (a row literal).  A stage-6 Mid driver that misprints the usage
# line, exits 0 on an unknown entry, accepts 17 entry args, or misroutes a
# malformed arg goes red here even while every normal run row stays green.
# All five rows build the SAME trivial fixture: the pinned behaviour lives in
# the driver, not the program.
run_err err-usage        Const42.main tools/qbe/fixtures/const42.elm 2
run_err err-notmeta      Const42.main tools/qbe/fixtures/const42.elm 2 NoSuch.entry
run_err err-toomany      Const42.main tools/qbe/fixtures/const42.elm 2 Const42.main 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
# the bad-arg heuristic has TWO arms (rt.zig isFloatArg): a '.'/'e'-spelled
# arg takes the float path, everything else the int path — pin both refusals.
run_err err-badarg-int   Const42.main tools/qbe/fixtures/const42.elm 2 Const42.main abc
run_err err-badarg-float Const42.main tools/qbe/fixtures/const42.elm 2 Const42.main 2.5.3

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

# the write path's on-disk bytes: the run must write IO_OUT with the exact
# expected content (a round-trip read could hide a wrong write).
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
if (cd "$ROOT/osier-compiler" &&
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
n="$(rg -c 'Unsafe|Raw' "$ROOT/osier-compiler/src/Mid/FromAst.elm" || true)"
if [ -z "$n" ]; then
  echo "PASS rawnodes-front-end: FromAst.elm names no Unsafe/Raw constructor (the front end cannot emit one)"
else
  echo "FAIL rawnodes-front-end: FromAst.elm mentions Unsafe/Raw $n time(s) — the front end must never touch the raw surface"
  FAIL=1
fi
# Row 2: the wiring pin — the audit must be CALLED on every compile, not
# merely exist (a seat never called is indistinguishable from an absent one).
n="$(rg -c 'Audit\.run' "$ROOT/osier-compiler/src/Mid/QbeModule.elm" || true)"
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
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_NOFLATTEN=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
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
# OWN account.  Two spellings: the DEFAULT (Mid-driver) route enters through
# the stage-6 B0 frame pair `call $q_Rt_x2eframe_x2denter(l N)` (an `l`
# word, the raw-word ABI); the ZIG route (QBE_MIDZIG=1) keeps the old
# `call $rt_frame_enter(w N)`.  The meta table roots only the requested
# entry, so the first one in the file is the entry's.
frame_slots() {
  sed -n -e 's/.*call \$rt_frame_enter(w \([0-9]*\)).*/\1/p' \
         -e 's/.*call \$q_Rt_x2eframe_x2denter(l \([0-9]*\)).*/\1/p' "$1" | head -1
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
  # emits.  STAGE-6 B0: the frame pair (q_Rt_x2eframe_x2denter/Leave) is the
  # pooled-frame prologue/return, NOT a prim route — it is excluded so the
  # pass-A rt_prim-site counters still measure ONLY prim/tag-test sites (the
  # pair is a constant 2-per-framed-defun offset, invisible to the ON/OFF
  # asymmetry the norep rows assert).
  awk '
    /^function / { cur=$3; sub(/^\$/,"",cur) }
    /call \$rt_prim/ { c++ }
    /call \$q_Rt_/ && cur !~ /^q_Rt_/ && $0 !~ /q_Rt_x2eframe_x2d(enter|leave)/ { c++ }
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
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_NOREP=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
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
  (cd "$ROOT/osier-compiler" && QBE=1 QBE_MIDZIG=1 QBE_NOREP=1 QBE_NOPRIMDIRECT=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
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
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_NOMONO=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
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
  # U3a: a clone is a SURFACE defun, so its result class is whatever the
  # closure ABI uses — `:ret` before the flip, `:val` after it.  The row's
  # claim is "the pass emitted a clone", not the class, so the pattern is
  # class-agnostic on purpose: pinning one spelling here made three mono rows
  # go red for an ABI change that did not touch the pass at all (MEASURED).
  grep -cE '^function :(ret|val) \$[A-Za-z0-9_]*_x24' "$1" || true
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
# `tiny`/`big`/`bigNeg` pin printFloat's edges at both ends of the DECIMAL
# expansion — 0.0000001 / 10000000000000000000000.0 / its negative.  (This
# comment used to say JS Number::toString "switches to exponential" here; the
# COMMITTED GOLDENS say otherwise and they are the specification — the native
# printValue renders the full decimal expansion with no exponent form, and the
# 1e-7 / 1e22 spellings belong to the OTHER formatter, Prelude's Elm-side
# jsFloatDigits, which String.fromFloat uses.  Corrected at ZIGHOST Z4a, where
# the Mid port had to reproduce the goldens' shape exactly.) `infLit`/`negInfLit` are the NON-FINITE literals
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
# POST-B4 (the shrink): the GENERIC arm `rt_prim` is DELETED from rt.o, so
# `QBE_NOPRIMDIRECT=1` is EMIT-ONLY and its `.ssa` cannot LINK (the generic
# `call $rt_prim(` sites below reference a symbol that no longer exists).  The
# `rt_prim_*` direct wrappers STAY — they are the live route.  These rows only
# EMIT and count, which is exactly the emit-only discipline QBE_MIDZIG=1 uses.
qbe_ssa_prim() { # <fixture> <entry> <out.ssa> <on|off>
  if [ "$4" = "off" ]; then
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_MIDZIG=1 QBE_NOPRIMDIRECT=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
  else
    (cd "$ROOT/osier-compiler" && QBE=1 QBE_MIDZIG=1 QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
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
# ZIGHOST Z6 TOMBSTONE: THERE IS NO rt.o.  This row used to cross-check the
# emitted `rt_prim_*` direct wrappers against the object that defined them; the
# object is deleted, and with it the wrappers (O4 deleted the prims table, Z6
# deleted the file).  What is left to assert is the DELETION plus the thing that
# would catch a survivor: every LINKABLE artifact in this run was built with NO
# runtime object at all, so a remaining client of one would have been a LINK
# ERROR, not a silent pass — and the pd-*.ssa above are the EMIT-ONLY
# QBE_MIDZIG arms whose wrappers were unlinkable since B4.
RTO="$ROOT/tools/qbe/rt.o"
if [ -e "$RTO" ]; then
  echo "FAIL primdirect-symbols: $RTO EXISTS — the Zig runtime object was deleted at ZIGHOST Z6; a rebuilt one means a client came back"
  FAIL=1
else
  echo "PASS primdirect-symbols (Z6 tombstone): no runtime object in the tree; every linkable row above linked without one (a remaining client would be a link error)"
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
# behaviour (tools/qbe/golden/cycleeq.txt) and the DEFAULT build now dies.
# B4 deleted the SEGV stack-depth net (owner decision), so the death is a BARE
# SIGSEGV (rc 139), not the "native stack depth exceeded" message the net used
# to print.  The row still asserts that death in BOTH directions: a Mid deepEq
# that silently answered wrong, or one that grew a cycle counter, both fail
# here and must re-point deliberately.
cyc_bin="$(RUN_STACK_KB=131072 "$ROOT/tools/qbe/qbe-mk.sh" "$ROOT/tools/qbe/fixtures/cycleeq.elm" CycleEq.main "$TMP/cycleeq-mid" 2>/dev/null)"
if [ -n "$cyc_bin" ] && [ -x "$cyc_bin" ]; then
  cyc_out="$(RUN_STACK_KB=131072 timeout 60 "$cyc_bin" CycleEq.main 2>&1)"
  cyc_rc=$?
  if [ "$cyc_rc" -eq 139 ]; then
    echo "PASS cycleeq-dies-loudly: the default (Mid) \`=\` has no cycle guard (bare SIGSEGV, exit $cyc_rc — the SEGV net that used to name it is DELETED at B4) — the KNOWN post-flip divergence, pinned"
  else
    echo "FAIL cycleeq-dies-loudly: expected a bare-SIGSEGV death (rc 139) on the default route, got rc=$cyc_rc out='${cyc_out:0:120}' — if the cycle guard was ported, re-point this row"
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
#     emission level (post-flip it cannot link; see qbe_ssa_midrt).  SURFACE
#     scoped: the hatch gates the surface prim route, never the injected
#     runtime's own Mid bodies (stage 7 O2-fix — see midrt_surface);
#   * midrt-hostseed (WAS midrt-pruned, halved at ZIGHOST Z0): the host-on
#     build of a cons-FREE entry (NoRep.chain is pure arithmetic) carries the
#     cons defun, and the only thing that can bring it is the Mid effect host's
#     own closure (MidRt.hostSeeds).  The pruning arm this row used to pair
#     that with — the no-Rt route, where the used-prim census is the only seed
#     source — is unreachable since Z0 (NOMIDRT is refused unconditionally).
#   * midrt-hatch: RETIRED at ZIGHOST Z0 — it measured QBE_NOMIDRT=1 removing
#     the injection from the cons-using fixture, and that build is now a loud
#     compile refusal (see the `off` mode note below).
# POST-FLIP (osier-flip): `route` is the DEFAULT (no flag — the Mid route IS
# the compile default now); `zig` selects the OLD path with QBE_MIDZIG=1 (an
# EMIT-ONLY arm on this tree: the deleted Zig handlers mean the emitted
# rt_prim_cons sites cannot link — the row asserts the EMISSION, which is
# what a bisect needs).
#
# THE `off` MODE IS GONE (zighost Z0).  It was QBE_NOMIDRT=1 (paired with
# QBE_MIDGC=0 while the Zig collector existed) — the only route on which the
# injection could be seen to be absent.  NOMIDRT is a MIDGC_DEPENDS_ON entry and
# the collector is now unconditional, so every NOMIDRT=1 build is a LOUD compile
# refusal (exit 2): there is no spelling of "the injection is gone" left, and
# the two rows that measured it (midrt-hatch, midrt-pruned) are retired below.
qbe_ssa_midrt() { # <fixture> <entry> <out.ssa> <mode: on|route|zig>
  local flags=""
  case "$4" in
    route) flags="" ;;
    zig)   flags="QBE_MIDZIG=1" ;;
  esac
  (cd "$ROOT/osier-compiler" && env QBE=1 $flags QBE_ENTRY="$2" node run.js "$ROOT/$1" "$3") >/dev/null 2>&1
}
midrt_ssa() { grep -c 'q_Rt_x2econs' "$1" 2>/dev/null || true; }
midrt_calls() { grep -c 'call \$q_Rt_x2econs(' "$1" 2>/dev/null || true; }
midrt_zigcons() { grep -c 'rt_prim_cons' "$1" 2>/dev/null || true; }

# SURFACE-ONLY counters (stage 7 O2-fix).  Since O2 made the Mid effect host
# the DEFAULT, every .ssa also carries the INJECTED Rt defuns, and their own
# bodies call q_Rt_* (Rt.globBuildGo conses, Rt.deepEq conses, ...).  Those
# calls are the runtime's own Mid emission, not the surface prim route, and no
# hatch gates them — so a WHOLE-FILE grep can no longer ask either row's
# question.  MEASURED on flatten.elm at c5373ec: 33 whole-file call sites, 0
# in the surface defuns; the same file under QBE_MIDHOST=0 (the unhosted
# escape route) is 0/0.  A surface defun is any defun whose mangled name does
# not start with `q_Rt_x2e`: the compiler REFUSES a surface module named `Rt`
# (the Rt name reservation, row `rtmod`), so that prefix is the injected
# runtime and nothing else.
midrt_surface() { # <ssa> <fixed substring>
  # FIXED-STRING match, not a regex: awk's -v processes backslash escapes in
  # the value, so a `-v pat='call \$q_Rt_x2econs\('` reached the regex engine
  # as `call $q_Rt_x2econs(` and died "unbalanced (" -- and with stderr
  # discarded the counter came back EMPTY, which every `[ "$c" -lt 1 ]` below
  # reads as false.  MEASURED during the O2-fix: that made midrt-route and
  # midrt-zig PASS with no measurement at all.  index() cannot fail that way,
  # and every caller still checks the value is a number.
  awk -v pat="$2" '
    /^function/ { surf = (index($0, "$q_Rt_x2e") == 0) }
    surf && index($0, pat) { n++ }
    END { print n+0 }
  ' "$1" 2>/dev/null
}
midrt_scalls() { midrt_surface "$1" 'call $q_Rt_x2econs('; }
midrt_szigcons() { midrt_surface "$1" 'rt_prim_cons'; }

qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-on.ssa"  on
qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-route.ssa" route
qbe_ssa_midrt tools/qbe/fixtures/flatten.elm Flatten.main "$TMP/midrt-flat-zig.ssa"  zig
QBE_NOREP=1 qbe_ssa_midrt tools/qbe/fixtures/norep.elm NoRep.chain "$TMP/midrt-chain-host.ssa" route
# THE NO-RT ARM IS RETIRED (zighost Z0): it was
# `QBE_MIDGC=0 QBE_NOREP=1 QBE_NOMIDRT=1` — the no-host, no-Mid-collector tree
# in which the used-prim census was the ONLY seed source.  Both halves are gone
# (the collector hatch deleted, NOMIDRT refused unconditionally), so the census
# can no longer be isolated at the emission level; the corpus .ssa byte-identity
# is what catches over-seeding now.

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
  c=$(midrt_scalls "$TMP/midrt-flat-route.ssa")
  z=$(midrt_szigcons "$TMP/midrt-flat-route.ssa")
  case "$c$z" in ''|*[!0-9]*) echo "FAIL midrt-route: a surface counter returned '$c'/'$z', not a number — the row cannot measure"; midrt_bad=1; c=0; z=1;; esac
  if [ "$c" -lt 1 ]; then
    echo "FAIL midrt-route: no SURFACE call \$q_Rt_x2econs site — the route does not fire on this fixture"
    midrt_bad=1
  elif [ "$z" -ne 0 ]; then
    echo "FAIL midrt-route: $z surface rt_prim_cons site(s) survive with the route ON — cons did not convert"
    midrt_bad=1
  else
    echo "PASS midrt-route: $c surface cons site(s) -> q_Rt_x2econs, 0 rt_prim_cons left (the DEFAULT route; the host's own $(midrt_calls "$TMP/midrt-flat-route.ssa") internal call(s) are the injected runtime, counted apart)"
  fi
else
  echo "FAIL midrt-route: .ssa missing (compile failed?)"; midrt_bad=1
fi
if [ -s "$TMP/midrt-flat-zig.ssa" ]; then
  # SURFACE-SCOPED (stage 7 O2-fix): the hatch gates the SURFACE prim route.
  # The injected Rt defuns are Mid IL and call q_Rt_x2econs in their own
  # bodies whatever the hatch says -- MEASURED on this fixture at c5373ec: 33
  # whole-file call sites, 0 of them in a surface defun, and the same build
  # under QBE_MIDHOST=0 is 0 whole-file.  A whole-file count here would fail
  # on a healthy tree and could never fail for the reason it names.
  zc=$(midrt_szigcons "$TMP/midrt-flat-zig.ssa")
  zq=$(midrt_scalls "$TMP/midrt-flat-zig.ssa")
  zi=$(midrt_calls "$TMP/midrt-flat-zig.ssa")
  case "$zc$zq" in ''|*[!0-9]*) echo "FAIL midrt-zig: a surface counter returned '$zc'/'$zq', not a number — the row cannot measure"; midrt_bad=1; zc=0; zq=1;; esac
  if [ "$zc" -lt 1 ]; then
    echo "FAIL midrt-zig: QBE_MIDZIG=1 emitted no SURFACE rt_prim_cons site — the old path is not selectable"
    midrt_bad=1
  elif [ "$zq" -ne 0 ]; then
    echo "FAIL midrt-zig: $zq SURFACE q_Rt_x2econs call site(s) under QBE_MIDZIG=1 — the hatch does not gate the route"
    midrt_bad=1
  else
    echo "PASS midrt-zig: QBE_MIDZIG=1 emits $zc surface rt_prim_cons site(s), 0 surface q_Rt cons calls (the $zi injected-runtime call(s) are the host's own Mid bodies, ungated by construction)"
  fi
else
  echo "FAIL midrt-zig: .ssa missing (compile failed?)"; midrt_bad=1
fi
# THE PRUNING ROW IS HALVED AT ZIGHOST Z0, and the half that survives is the
# one that still has a subject.  `midrt-pruned` was TWO ARMS: the NO-RT route
# (QBE_NOMIDRT=1, where the used-prim census is the ONLY seed source, so a
# cons-free entry must carry no cons defun) and the host-ON control that
# attributes the default build's cons defun to MidRt.hostSeeds.  The no-RT arm
# is UNREACHABLE now — NOMIDRT is refused unconditionally, so it would measure
# the guard — and with it goes the row's ability to isolate the census.  What
# survives is the attribution arm, kept and RENAMED so the row's name states
# what it still measures: the Mid effect host's own closure (Rt.globBuildGo ->
# Rt.cons) is what brings cons into a cons-free entry.  MEASURED at c5373ec:
# unhosted 0 mention(s) / 106,881 B, default 34 / 634,750 B.
if [ -s "$TMP/midrt-chain-host.ssa" ]; then
  h=$(midrt_ssa "$TMP/midrt-chain-host.ssa")
  if [ "$h" -lt 1 ]; then
    echo "FAIL midrt-hostseed: the host-ON build of a cons-free fixture carries no Rt defun — the host's closure is no longer what brings cons in"
    midrt_bad=1
  else
    echo "PASS midrt-hostseed: the cons-free entry's $h cons mention(s) are the Mid HOST's own closure, attributed not seeded"
  fi
else
  echo "FAIL midrt-hostseed: .ssa missing (compile failed?)"; midrt_bad=1
fi

# THE `Rt` MODULE-NAME RESERVATION (the audit's residual hole, closed by this
# step): a surface module named Rt would emit keys under the whitelisted
# Rt.* prefix and never be audited, so every compile rejects it loudly.
printf 'module Rt exposing (f)\n\nf x =\n    x + 1\n' > "$TMP/rtmod.elm"
if (cd "$ROOT/osier-compiler" &&
      QBE=1 QBE_ENTRY=Rt.f node run.js "$TMP/rtmod.elm" "$TMP/rtmod.ssa") >/dev/null 2>&1 \
   && head -c 200 "$TMP/rtmod.ssa" 2>/dev/null | grep -q 'module name Rt is reserved'; then
  echo "PASS rt-name-reserved: a surface module named Rt is rejected loudly at collect time"
else
  echo "FAIL rt-name-reserved: the Rt module name is not reserved (the audit's prefix hole is open)"
  midrt_bad=1
fi
if [ "$midrt_bad" -eq 0 ]; then
  echo "PASS midrt-seats: injected + routed + host-attributed + reserved (all counters move)"
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

# ---- stage 6 B2: the SAME 1e6 mutual tail (the Mid bounce's constant-stack
#      oracle).  The Mid tail-known builds every .tail and the MID bounce loop
#      chases it; a self-CALL recur in Rt.bounceGo would build one C frame per
#      hop and die on the 8MB stack between 20k-40k hops.  B4 made the Mid
#      route the default, so this links the plain rt.o (no main strip).
if true; then
  # (ZIGHOST Z6: the `rt-o.sh` gate that used to wrap this row is gone with the
  # object — the row links compiler.s + libc like every other one.)
  md_d=1000000
  ssa="$TMP/md-mutual.ssa"
  if (cd "$ROOT/osier-compiler" &&
    QBE=1 QBE_ENTRY=Mutual.even node run.js "$ROOT/tools/qbe/fixtures/mutualtail.elm" "$ssa") >&2; then
    case "$(head -c 4 "$ssa")" in
      "err "*) echo "FAIL md-mutual-tail: compile failed: $(cat "$ssa")"; FAIL=1;;
      *)
        "$ROOT/vendor/qbe/qbe" "$ssa" > "$TMP/md-mutual.s"
        if cc "$TMP/md-mutual.s" -o "$TMP/md-mutual" -lc 2>/dev/null; then
          md_out="$(timeout 120 "$TMP/md-mutual" Mutual.even "$md_d" 2>&1)"
          if [ "$md_out" = "1" ]; then
            echo "PASS md-mutual-tail $md_d hops: the MID bounce loop chases the chain at constant stack (golden 1)"
          else
            echo "FAIL md-mutual-tail $md_d hops: golden='1' native='$md_out'"
            FAIL=1
          fi
        else
          echo "FAIL md-mutual-tail: link"; FAIL=1
        fi
        ;;
    esac
  else
    echo "FAIL md-mutual-tail: qbe-mk"; FAIL=1
  fi
fi

# ---- cross-target smoke: the emitted IL must be TARGET-NEUTRAL apart from the
#      ONE instruction the other targets deliberately do not implement.
#
#      U3a changed what this row can honestly claim, and the change is stated
#      rather than papered over.  Before U3a the emitted runtime contained NO
#      `tcall` (Q1b's tcalls are emitted only where a program has a generic
#      TAIL apply, and fib/float have none), so "the IL is target-neutral" was
#      literally true and this row compiled both artifacts under arm64 and
#      rv64.  U3a's conversion makes `tcall` UNCONDITIONAL in the runtime —
#      rt_call2r's arity blocks (a hop must jump, or the chain grows a frame
#      per hop) and the apply loop's own self-handoff — so no program's .ssa is
#      arm64-assemblable any more, and the old assertion could only be restored
#      by reverting the unit.  vendor/qbe refuses `tcall` on arm64/rv64 BY
#      DESIGN ("a wrong tail is worse than none", tcall-probe.sh's target rows).
#
#      So the row now pins the SHARPER claim: each artifact's ONLY refusal is
#      that one, named, and it is still a REFUSAL (a non-zero exit with the
#      condition in the message) rather than a silent degradation.  A new
#      host-specific pattern in the IL would show up as a DIFFERENT first
#      error line and fail here exactly as before.  MEASURED: the first error
#      line for fib.ssa and float.ssa on both targets is the tcall one, and
#      the count of tcall sites is non-zero (a zero would make the row vacuous
#      — a runtime with no tcall would be re-neutral and this row must say so
#      out loud rather than pass on a stale premise).
for tgt in arm64 rv64; do
  ok=1
  for s in "$TMP/fib/fib.ssa" "$TMP/float-lit/float.ssa"; do
    [ -s "$s" ] || continue
    want="tcall is not implemented on $( [ "$tgt" = arm64 ] && echo arm64 || echo riscv64 )"
    if ! grep -q "$(printf '\t')tcall " "$s"; then
      echo "FAIL cross-$tgt: $(basename "$s") contains no tcall — the IL is target-neutral again, so this row's premise (and its assertion) must be re-derived, not left green on a stale claim"
      FAIL=1; ok=0
      continue
    fi
    if "$ROOT/vendor/qbe/qbe" -t "$tgt" "$s" > /dev/null 2>"$TMP/xtgt.err"; then
      echo "FAIL cross-$tgt: vendored qbe -t $tgt ACCEPTED $(basename "$s") — a tcall it does not implement was silently accepted"
      FAIL=1; ok=0
    elif ! grep -qF "$want" "$TMP/xtgt.err"; then
      echo "FAIL cross-$tgt: vendored qbe -t $tgt rejected $(basename "$s") for a reason OTHER than the unimplemented tcall: $(head -c 120 "$TMP/xtgt.err")"
      FAIL=1; ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "PASS cross-$tgt: fib.ssa and float.ssa are refused by qbe -t $tgt ONLY by the unimplemented tcall (the rest of the IL stays target-neutral)"
  fi
done

# ---- cross-rv64-lphi: THE DEPENDENCY FIX'S OWN PIN (stage 7 O2-fix).  The
#      row above compiles the EMITTER'S artifacts; this one compiles
#      HAND-WRITTEN IL with the one shape the vendored qbe mistyped (a
#      `w`-class jnz over a diamond whose arms `storel` the constants 0 and 1,
#      read back by an `l` load — see tools/qbe/fixtures/lphi-const.ssa and
#      THIRD-PARTY.md's "Local patch").  It is RED on the unpatched pin
#      (rv64/isel.c:80 fixarg asserts, rc 134) and GREEN with the patch, so it
#      fails for a reason independent of both the emitter and the fixture: a
#      future qbe pin bump that drops the patch goes red HERE, naming the
#      cause, instead of as an rv64 abort on a plain Elm fixture.
if [ -s "$ROOT/tools/qbe/fixtures/lphi-const.ssa" ]; then
  if "$ROOT/vendor/qbe/qbe" -t rv64 "$ROOT/tools/qbe/fixtures/lphi-const.ssa" >/dev/null 2>"$TMP/lphi.err"; then
    echo "PASS cross-rv64-lphi: hand-written IL with an l-class phi of \$0/\$1 under a w jnz compiles (the copy.c class guard is present)"
  else
    echo "FAIL cross-rv64-lphi: vendored qbe -t rv64 rejected the l-phi fixture: $(head -c 140 "$TMP/lphi.err") — the copy.c class guard (THIRD-PARTY.md, Local patch) is missing or was lost in a pin bump"
    FAIL=1
  fi
else
  echo "FAIL cross-rv64-lphi: tools/qbe/fixtures/lphi-const.ssa is missing — the row no longer measures the dependency fix"
  FAIL=1
fi

# ---- cffi U2: THE WIDTH PAIR (plan §7.2) — the oracle this arc exists for ----
# Two fixtures identical EXCEPT for the DECLARED RESULT WIDTH of the same libc
# call, both with goldens written from the expectation (not frozen from the
# tree) and both also pinned STRUCTURALLY on the emitted .ssa:
#
#   `-> i32`  : `=w call $access` + `extsw` of that temp   -> true   (sign)
#   `-> i64`  : `=l call $access`, NO extension            -> false  (legacy)
#
# MEASURED on this host's glibc 2.44 (plan §7.1): `access` sets its failure
# with `movl $-1, %eax`, so the raw `l` value is 4294967295, not -1.  The pair
# therefore cannot be passed by a lowering that ignores the declared width
# (both arms false) NOR by one that extends unconditionally (both arms true) —
# and both directions were RUN as mutations of Mid/Qbe/Lower.elm.
#
# `openat`/`getpid`/`poll`/`waitpid`/`readdir` are NOT usable here: they are
# PRE-EXTENDED on this glibc, so an oracle built on them would be a FALSE
# NEGATIVE that passes before the fix as well.
# BOTH halves of the boundary are pinned: the RESULT class (`=w call`/`=l call`
# plus the extension) and the ARGUMENT classes in the same line — `ptr` as `l`
# (FW64) and `i32` as `w` (FW32S).  Passing `l` for the `i32` argument happens
# to work on x86_64 (plan §3.2), which is why the argument half needs a SHAPE
# assertion rather than a behavioural one.
run_midshape ffiw-i32 Ffiw32Main.main tools/qbe/fixtures/ffiw-i32.elm tools/qbe/fixtures/ffiw-i32.mid '=w call $access(l $d0, w 0)' extsw
run_midshape ffiw-i64 Ffiw64Main.main tools/qbe/fixtures/ffiw-i64.elm tools/qbe/fixtures/ffiw-i64.mid '=l call $access(l $d0, w 0)' ''
# The THIRD arm pins FW32U's emission, which the pair leaves open: `extuw` and
# `extsw` have the same shape on the same temp, so a u32 arm that wrongly
# SIGN-extended would pass both rows above.  It cannot pass this one — `access`
# fails with 4294967295 in the raw `w`, so `extuw` -> false and `extsw` -> true
# (the golden is false).
run_midshape ffiw-u32 Ffiw32uMain.main tools/qbe/fixtures/ffiw-u32.elm tools/qbe/fixtures/ffiw-u32.mid '=w call $access(l $d0, w 0)' extuw

# ---- cffi U3: the `f64` RESULT and the `void` RESULT (plan §3.1, §8 U3) ----
# The `d` class, both directions in ONE call: `strfromd(str, n, fmt, x)` takes a
# `double` and returns an `int`.  The pin below therefore holds the whole
# boundary in one line — the `d` ARGUMENT (`d %t6`, lowered through rawFltArg),
# the `w` RESULT and the `extsw` after it — and the golden `"1.50"` is
# load-bearing twice: `1.50` is the argument, and the string's LENGTH is the 4
# that came back through the `w` return.
# RE-BASELINED AT THE GC NURSERY FLIP: the classes and the shape are unchanged
# from the Zig-route freeze; only the TEMP NAMES moved (%t0/%t3 -> %t7/%t6) —
# the Mid route's allocation seats number the surrounding temps differently.
# The MIDGC_OFF=1 pin that carried the first flip attempt is GONE: the default
# route is the Mid one now, and this row asserts ITS emission.
run_midshape ffid-f64 FfidMain.main tools/qbe/fixtures/ffid-f64.elm tools/qbe/fixtures/ffid-f64.mid '=w call $strfromd(l %t3, l 16, l $d0, d %t6)' extsw
# The RESULT half on its own: `atof(ptr) -> f64` takes no `d` argument, so the
# only thing this row can be reading is the `=d call`.  MEASURED failure shape
# (a mutation emitting `=l call` here): QBE refuses the program outright —
# "invalid type for first operand in stored" — so this arm is loud, never a
# wrong number.
run_midshape ffidr-f64 FfidrMain.main tools/qbe/fixtures/ffidr-f64.elm tools/qbe/fixtures/ffidr-f64.mid '=d call $atof(l $d0)' ''
# FVoid: a declared `-> void` must emit the shape today's UNDECLARED `rawcall`
# emits — `=l call`, a dead temp, NO extension.  The empty extension op is the
# arm that FAILS on an extension, which is the positive form of the bug.
# The legacy `free` line right after it in the same defun is the control.
# The golden is inert by nature (a void result has nothing to get wrong); the
# "moves nothing" claim is carried by osier-corpus-ssa.sh's byte-identity, which
# covers runtime.mid's own `rawcall free` sites.
run_midshape ffiv-void FfivMain.main tools/qbe/fixtures/ffiv-void.elm tools/qbe/fixtures/ffiv-void.mid '=l call $srand(w 7)' ''

# ---- cffi U4: VARARGS (plan §5) — the `...` MARKER and its position ----
# The golden half of these two rows is a smoke value (see the fixtures): with
# every variadic argument word-class, `%al` is always 0, so a dropped marker is
# NOT behaviourally visible — MEASURED by mutating the emitter to never emit it
# (`"1-2"` still printed).  The pin below is therefore the instrument that can
# fail, and it holds both halves at once: the fixed arguments' classes (`l`/`w`/
# `l` from the declaration), the marker's POSITION (between the fixed and the
# variadic ones), the variadic arguments' class (`l` words) and the `w` result
# plus its extension.
#
# `snprintf` is the printf shape; `fcntl` is the shape the effect-loop port
# needs (`effectloop.zig:117`), with the variadic argument a real argument
# rather than a format operand.
run_midshape ffis-vararg FfisMain.main tools/qbe/fixtures/ffis-vararg.elm tools/qbe/fixtures/ffis-vararg.mid '=w call $snprintf(l %t3, l 32, l $d0, ..., l 1, l 2)' extsw
run_midshape ffic-vararg FficMain.main tools/qbe/fixtures/ffic-vararg.elm tools/qbe/fixtures/ffic-vararg.mid '=w call $fcntl(w 1, w 3, ..., l 0)' extsw

# ---- cffi U6: WIDTH-TYPED MEMORY (plan §8 U6) — the offsets are MEASURED ----
# The effect-loop port's real backer: `struct pollfd` is `{ int; short; short; }`
# and `struct stat` is full of `off_t`/`mode_t`/`short`, so a word-granular
# layout cannot express them at all and a layout that ROUNDED to words would
# place `st_uid` at 32 instead of 28 — the right struct's wrong bytes.
#
# THE EXPECTED NUMBERS ARE FROM THIS HOST'S HEADERS, not from the tree:
#   /usr/include/sys/poll.h:36-41                  sizeof 8,  fd@0, events@4, revents@6
#   /usr/include/bits/struct_stat.h (__x86_64__)   sizeof 144, mode@24, uid@28,
#        gid@32, __pad0@36, rdev@40, size@48, blocks@64
#   /usr/include/bits/types/struct_timespec.h      sizeof 16, tv_sec@0, tv_nsec@8
# and confirmed by a C `offsetof`/`sizeof` program compiled and run here.
#
# THE GOLDEN (14 numbers, one per arm):
#   9007203549809287  struct pollfd read back as ONE 8-byte word after poll():
#                     fd(99999)@0 | events(1)<<32 | revents(POLLNVAL=32)<<48, plus
#                     1000*poll(1).  The KERNEL wrote bytes 6..7, so a
#                     self-consistent-but-wrong offset cannot produce it — the
#                     one thing a store/load round trip through our own table
#                     could never prove.
#   14                poll() on a pipe's WRITE end with events=POLLOUT(4):
#                     revents(4) + 10*poll(1).  POLLNVAL is reported regardless
#                     of the mask, so THIS is the arm that proves the kernel READ
#                     our events store at byte 4 (mask 0 gives 0 + 0).
#   1122              struct timespec: 11@0, 22@8
#   8589934593        struct stat word 3 = mode(1)@24 | uid(2)<<32  (so byte 24 and 28)
#   17179869187       struct stat word 4 = gid(3)@32 | __pad0(4)<<32 (bytes 32 and 36)
#   5                 struct stat word 5 = rdev@40 — the 8-byte alignment bump
#                     past __pad0; a no-alignment rule puts rdev at 36
#   48 / 64           struct stat words 6 and 8 = size@48, blocks@64
#   -1 -2 -3          i8/i16/i32 fields of 0xFF/0xFFFE/0xFFFFFFFD read with
#                     loadsb/loadsh/loadw (the unsigned spellings of the same
#                     bytes give 255/65534/4294967293)
#   65535 4294967295  u16/u32 fields read with loaduh/loaduw
#   200               a u8 at byte 1 that survived its i8 neighbour's store —
#                     a word-wide store for a 1-byte field would leave 255
#
# The SHAPE half (why this is a run_midshape row and not just a golden): the
# sub-word load must be an `l`-typed widening op with NO extension after it —
# `%t =l loaduh %t2`, not `loadub`+`extuw` and not a `w` temp.  `run_midshape`'s
# empty extension op FAILS on a trailing `extsw`/`extuw`, which is the positive
# form of the bug.
run_midshape ffim-mem FfimMain.main tools/qbe/fixtures/ffim-mem.elm tools/qbe/fixtures/ffim-mem.mid '=l loaduh %t' ''

# ---- stage 7A: THE APPLIER PIN (QBE_MIDHOST) ----
# Rt.apply-at is the one Mid applier (closure + a rooted raw arg array ->
# Rt.callArity).  Its FIRST caller is the new Mid effect host, and the failure
# this row exists to catch is SILENT: the two neighbours of the right entry are
# traps (the WRONG SEAT — pre-U3a Rt.applyGo handed back an unforced `:ret`
# tail, i.e. a heap address where a value belongs; and a Disp arity of
# `arity - rem` passes zero arguments), and neither is a crash.  So the oracle is a NUMBER: 417 =
# upd(msg 7, model 41) from a GLOBAL closure, 503 = a CAPTURING closure applied
# to 3, and the row's own churn arm (run_mid re-runs at QBE_HEAP_MB=$CHURN_MB)
# is the rooting half — the .mid churns 20 000 allocations between filling the
# registered root array and applying out of it, so a stale closure/arg reads
# garbage there.
#
# FAIL-BEFORE, MEASURED (the golden is not vacuous): with `dp->arity =
# arity - rem` the same row prints `[cons 1407343666249120 . [cons 500 . []]]`,
# and routing through Rt.apply is refused at compile time by J2.  Both were run
# as mutations of runtime.mid.
run_midhost hostapply HostApply.main tools/qbe/fixtures/hostapply.elm tools/qbe/fixtures/Whost.mid

# ---- THE BOOLEAN PAYLOAD'S WIDTH (the route's silent-wrong) ----
# A bool Value's payload is a WORD — `boolean: i32` in the Zig `Value` union
# (vendor/osier-rt/src/gc/types.zig), stored 32-bit by Mid/Qbe/Lower's
# `lowerLit` LBoolean arm and `reboxBoolean`, and READ 32-bit by the compiler's
# own `:val`-cond test (`loadw` of the payload word).  So the HIGH HALF of that
# word is not part of the value, and six sites in runtime.mid read a BOOLEAN
# with the 64-bit spelling — including `Rt.main`'s host-route decision
# (`payload(mhOff, 0)` twice and `payload(call Rt.hostIsProgram(..), 0)`), the
# entry gate's `payload(found, 0)`, the dir walk's `payload(skip, 0)` and
# `Rt.cStrEq`'s `return payload(eq, 0)` (a WORD returned to ~60 `!= 0` string
# tests, so a stale half makes EVERY compare succeed).
#
# THE GOLDEN IS THE DISAGREEMENT, made deterministic instead of waiting for a
# stale high half: boolpay.mid's `garb` builds a boolean-tagged Value whose
# payload WORD is 2^32 (low half 0 = FALSE, high half 1), so the two readings
# of one Value must differ.  Slots 0/1 and 2/3 are the pair — a `payload32`
# that widened back to `loadl` moves slot 1 to 4294967296, and a `payload` that
# narrowed moves slots 0/3 — and slots 4/5 pin that the everyday `mkbool` path
# still reads 1/0 through the same op.
run_mid boolpay BoolPayMain.main tools/qbe/fixtures/boolpay.elm tools/qbe/fixtures/boolpay.mid

# THE EMITTED WIDTHS, on the fixture's own two defuns (a golden alone cannot
# say WHERE the width came from, and a bare "the .ssa contains a loadw" would
# pass on any program at all — the runtime's own hundreds of `loadw`s are in
# the same file).  `=w loadw` + `=l extsw` is `payload32`; `=l loadl` alone is
# `payload`; each is asserted POSITIVELY in its own defun and NEGATIVELY in the
# other, so neither spelling can drift into the other's slot.
bpssa="$TMP/boolpay/boolpay.mid.ssa"
bpfn() { awk -v fn="q_Bpay_x2e$1(" 'index($0, "function ") == 1 && index($0, fn) { f = 1 } f { print } f && /^}/ { exit }' "$bpssa"; }
if [ ! -f "$bpssa" ]; then
  echo "FAIL BOOLPAY-SHAPE: no emitted .ssa at $bpssa — the width rows cannot measure anything"
  FAIL=1
else
  bp32="$(bpfn read32)"
  bp64="$(bpfn read64)"
  if printf '%s\n' "$bp32" | grep -A1 '=w loadw' | grep -q '=l extsw' \
    && printf '%s\n' "$bp64" | grep -q '=l loadl' \
    && ! printf '%s\n' "$bp32" | grep -q 'loadl'; then
    echo "PASS BOOLPAY-SHAPE: payload32 emits '=w loadw' + '=l extsw' (the payload WORD) and payload emits '=l loadl' (the whole 8 bytes) — the two reads differ in width alone"
  else
    echo "FAIL BOOLPAY-SHAPE: read32=[$(printf '%s' "$bp32" | grep -E 'load|l extsw' | tr '\n' ' ')] read64=[$(printf '%s' "$bp64" | grep -E 'load' | tr '\n' ' ')] — want loadw+extsw in read32 (and NO loadl) and loadl in read64"
    FAIL=1
  fi
fi

# ---- zigretire stage 5 PART 3: THE MIDGC GUARD'S COMPLETENESS ----
# The guard that names ONE incompatible flag is not a guard (this arc paid for
# that twice: NORTLEAN then NOMIDRT).  run.js's MIDGC_DEPENDS_ON list is the
# single source of truth; this row re-derives its entries from THAT list (not
# a hand-written copy) and re-runs run.js with each `off` flag, asserting a LOUD
# exit 2.  A future flag the Mid collector newly depends on but that is missing
# from the list keeps compiling silently — and the only
# instrument that sees it is the probe for that shape, so this row also pins
# that the list is non-empty (a refactor that deletes the enumeration fails
# here, not silently).
# STAGE 7 O2 EXTENDED the derivation: an entry may carry `val:` — the value of
# the dependent flag that is INCOMPATIBLE.  The first two entries name flags that
# default OFF, so `=1` disables them; O2's QBE_MIDHOST entry names a flag that
# defaults ON, so its incompatible value is `=0`.  A reader that assumed `=1`
# would test QBE_MIDHOST=1 (the Mid host, i.e. the COMPATIBLE value) and go red
# on a healthy tree, so the `val` travels with the `off` (default 1).
midgc_guard_offs="$(grep -o "off: 'QBE_[A-Z]*'\(, val: '[^']*'\)\?" "$ROOT/osier-compiler/run.js" \
  | sed "s/off: '//; s/', val: '/=/; s/'//g; s/,$//" \
  | sed "s/^\(QBE_[A-Z]*\)$/\1=1/")"
if [ -z "$midgc_guard_offs" ]; then
  echo "FAIL midgc-guard: MIDGC_DEPENDS_ON in run.js lists no flags — the enumeration was deleted"
  FAIL=1
else
  mg_ok=1
  for off in $midgc_guard_offs; do
    (cd "$ROOT/osier-compiler" && env "$off" node run.js >/dev/null 2>&1)
    mg_rc=$?
    if [ "$mg_rc" -ne 2 ]; then
      echo "FAIL midgc-guard: $off exited $mg_rc, want 2 (the incompatible combination is no longer refused loudly)"
      FAIL=1; mg_ok=0
    fi
  done
  if [ "$mg_ok" = 1 ]; then
    echo "PASS midgc-guard: the Mid collector refuses each of its $(echo "$midgc_guard_offs" | wc -w) incompatible flag(s) — $midgc_guard_offs (enumerated from run.js, not hand-copied)"
  fi
fi

# ---- UPSTREAM'S OWN TESTSUITE (vendor/qbe/test/*.ssa) ----
# WHY THIS ROW EXISTS.  vendor/qbe now carries TWO local patches (`copy.c`'s
# class test, and the `tcall` instruction across 15 files).  Upstream ships 76
# test/*.ssa files that exercise the passes we patched, and until this row
# existed NOTHING in tools/ ran them: only tools/qbe-build.sh drives `make`, and
# only to BUILD.  So a future vendor sync or a careless edit could break
# upstream behaviour with every other gate in this file still green — our gates
# check what WE depend on, not what the vendor already promised.
#
# THE ROW IS NOT JUST AN EXIT CODE.  `make check` prints "All is fine!" and
# exits 0 when it ran the suite, but it would also print that after running
# FEWER tests — test.sh enumerates test/[!_]*.ssa and skips silently if a file
# is gone.  So the row also requires one result line per enumerated file and
# zero [ko]: a suite that quietly shrank is a failure, not a pass.  (Upstream's
# script writes its scratch to a hard-coded /tmp/qbe.zzzz and ignores TMPDIR;
# that file is upstream's and is left unmodified.)
if [ -x "$ROOT/vendor/qbe/tools/test.sh" ] && [ -f "$ROOT/vendor/qbe/qbe" ]; then
  up_n=$(ls "$ROOT"/vendor/qbe/test/[!_]*.ssa 2>/dev/null | wc -l)
  if [ "$up_n" -eq 0 ]; then
    echo "FAIL upstream-suite: vendor/qbe/test/ holds no test cases — upstream's suite was deleted"
    FAIL=1
  elif ! up_out="$(make -C "$ROOT/vendor/qbe" check 2>&1)"; then
    # upstream marks a red case with the failing stage ("[qbe fail]",
    # "[run fail]", ...) and prints the case name on the line above it
    echo "FAIL upstream-suite: upstream's own testsuite FAILED against the patched vendor"
    printf '%s\n' "$up_out" | grep -B1 -E '\[[a-z ]+fail\]|^[0-9]+ of [0-9]+ tests failed!' | sed 's/^/    /'
    FAIL=1
  else
    up_ok=$(printf '%s\n' "$up_out" | grep -c '\[ok\]')
    if [ "$up_ok" -ne "$up_n" ]; then
      echo "FAIL upstream-suite: only $up_ok of $up_n enumerated upstream test case(s) reported ok — the suite ran, but not all of it"
      FAIL=1
    else
      echo "PASS upstream-suite: $up_ok/$up_n of upstream's own test/*.ssa pass against the patched vendor (2 local patches: copy.c's class test, the tcall instruction)"
    fi
  fi
else
  echo "FAIL upstream-suite: vendor/qbe/tools/test.sh is missing or not executable — upstream's own testsuite, the only oracle for the VENDOR as a whole, was deleted"
  FAIL=1
fi

# ---- THE `tcall` TAIL-CALL INSTRUCTION'S BEHAVIOUR PROBE (Q1a) ----
# WHY THIS ROW EXISTS.  QBE gained a `tcall` instruction (THIRD-PARTY.md's
# second local patch): the callee returns to the CALLER's caller, so the frame
# goes away and the stack does not grow.  The interesting failure of that is a
# shape one instruction away — a `jmp` where the teardown should have been, the
# teardown ahead of the argument loads, an sret pointer forwarded to the wrong
# buffer — and a text pin cannot see any of them: it asserts the shape the
# AUTHOR wrote.  So the oracle is a program that RUNS, and the decisive row in
# it is an ASYMMETRY (1e7 tail hops complete under an 8 MiB stack; the same
# fixture hand-mutated `tcall`->`call` dies of stack exhaustion).  A probe never
# seen to fail is not evidence, so the runner gates the fail-before arm too.
#
# WHY IT IS INVOKED FROM HERE, AND WHY THE PRESENCE CHECK IS PART OF THE ROW.
# A committed script is not a gate: without this row the probe runs only when
# someone remembers, which is the same failure as no probe at all.  And a row
# that SKIPS when its input is gone is worse than one that fails: the fixture is
# the only test this instruction has, so deleting it has to turn the gate red
# rather than quietly reduce what is covered.
if [ -x "$ROOT/tools/qbe/tcall-probe.sh" ] \
&& [ -f "$ROOT/tools/qbe/tcall.ssa" ] \
&& [ -f "$ROOT/tools/qbe/tcall_main.c" ] \
&& [ -d "$ROOT/tools/qbe/tcall-bad" ]; then
  if tcall_out="$(TMPDIR="$TMP" "$ROOT/tools/qbe/tcall-probe.sh" 2>&1)"; then
    echo "PASS tcall: $(printf '%s\n' "$tcall_out" | grep -c '^PASS') row(s) RUN and passed — $(printf '%s\n' "$tcall_out" | grep -c '^PASS fixture') fixture run under an 8 MiB stack, $(printf '%s\n' "$tcall_out" | grep -c '^PASS asymmetry') tcall->call asymmetry, $(printf '%s\n' "$tcall_out" | grep -c '^PASS refusal') named refusals, $(printf '%s\n' "$tcall_out" | grep -c '^PASS target') other targets"
  else
    echo "FAIL tcall: the tcall behaviour probe FAILED (a tail call no longer returns to the caller's caller, or a refusal stopped naming its condition)"
    printf '%s\n' "$tcall_out" | sed 's/^/    /'
    FAIL=1
  fi
else
  echo "FAIL tcall: tools/qbe/tcall-probe.sh, tcall.ssa, tcall_main.c or tcall-bad/ is missing — the ONLY oracle that RUNS the tcall instruction was deleted"
  FAIL=1
fi

# ---- THE WORD ARM'S BEHAVIOUR PROBE (perf VR3b3, wired here so it RUNS) ----
# WHY THIS ROW EXISTS AT ALL.  Under QBE_VALREP=word no program compiled through
# run.js can run: the runtime is always injected, so the emitted set always
# reaches Rt.main and the runtime's own text stops the arm (AREA 6 until this
# unit ported the call ABI; the runtime's CONSTRUCTION path — `Rt.con: vecstore`
# — since).  The emitter's heap side (tag writes, payload reads, kind tests, the
# string cell) AND its call ABI therefore have no executable oracle on the arm
# they target — and a TEXT pin cannot be one, because on this arm a text pin
# asserts the shape the AUTHOR wrote.  MEASURED: six bugs shipped past every
# text pin in VR3b3 before this probe existed; it caught all six.  The `call`
# probe (AREA 6) is the same instrument applied to the ABI: one ordinary call
# and one `tcall` in a runtime-free module, checked as an identity.
#
# WHY IT IS INVOKED FROM HERE.  A committed script is not a gate: the first
# version of this row did not exist, so the probe ran only when someone
# remembered — which is the same failure as the scratch harness it replaced
# ("an oracle that has to be rebuilt by hand will not run again" becomes "an
# oracle that has to be REMEMBERED will not run again").  qbe-check.sh is the
# natural home: it already drives vendor qbe + cc, and the probe costs ~20 s.
# Its own runner gates every probe on EXIT CODE, FAIL count and an exact PASS
# count (a wrong offset dies as SIGSEGV/SIGABRT with no FAIL line).
# ---- THE TWO ARMS' OUTPUTS MUST AGREE (perf word-arm-area3rt) ----
# The companion row to word-arm-probe, and the only oracle in this file that
# sees BOTH representations at once.  word-arm-probe runs word-arm code against
# hand-written seats; this row compiles ONE source twice (val arm and
# QBE_VALREP=word), assembles and links each, RUNS each, and requires identical
# exit codes and byte-identical stdout.  A .ssa comparison would be meaningless —
# the two representations are SUPPOSED to differ — so the program's OUTPUT is the
# only shared observable.  It exists because the milestone it gates is the first
# program the word arm ever ran: if a later twin moves a stride on either side,
# this is the row that says so.
if [ -x "$ROOT/tools/qbe/word-arm-diff.sh" ] && [ -d "$ROOT/tools/qbe/word-arm-diff" ]; then
  if diff_out="$(TMPDIR="$TMP" "$ROOT/tools/qbe/word-arm-diff.sh" 2>&1)"; then
    echo "PASS word-arm-diff: $(printf '%s\n' "$diff_out" | grep -c '^PASS ') program(s) RUN on BOTH arms with identical exit code and byte-identical stdout — the only row that compares the two representations"
  else
    echo "FAIL word-arm-diff: the two arms DISAGREE on a program's output (or one of them no longer builds)"
    printf '%s\n' "$diff_out" | sed 's/^/    /'
    FAIL=1
  fi
else
  echo "FAIL word-arm-diff: tools/qbe/word-arm-diff.sh or its fixture dir is missing — the ONLY oracle that compares the two arms was deleted"
  FAIL=1
fi

# ---- CLOSURES UNDER COLLECTION (perf word-arm-closures FIX) ----
# The ONE row that runs a closure ACROSS a collection, and it exists because
# none of the others can: every other word-arm fixture allocates far below one
# GC trigger, so a ROOTING defect is invisible to all of them.  MEASURED, and
# this is why the row is not optional: the closure class shipped with a running
# fixture, a source pin, a probe row and 368 green rows here, while the word arm
# answered 19709031 where the val arm answers 18003000 — silently, rc=0, EMPTY
# STDERR, at DEFAULT settings.  Six (fixture, heap) rows, both arms, compared on
# exit code and stdout; four of them were MEASURED RED with the two rooting
# fixes reverted.
if [ -x "$ROOT/tools/qbe/word-arm-gcchurn.sh" ] && [ -d "$ROOT/tools/qbe/word-arm-gcchurn" ]; then
  if churn_out="$(TMPDIR="$TMP" "$ROOT/tools/qbe/word-arm-gcchurn.sh" 2>&1)"; then
    echo "PASS word-arm-gcchurn: $(printf '%s
' "$churn_out" | grep -c '^PASS ') row(s) RUN on BOTH arms with identical exit code and byte-identical stdout, INCLUDING under QBE_HEAP_MB=1 and at DEFAULT knobs — the only row that runs a closure across a collection"
  else
    echo "FAIL word-arm-gcchurn: a closure does not survive a collection (or one arm no longer builds)"
    printf '%s
' "$churn_out" | sed 's/^/    /'
    FAIL=1
  fi
else
  echo "FAIL word-arm-gcchurn: tools/qbe/word-arm-gcchurn.sh or its fixture dir is missing — the ONLY row that runs a closure across a collection was deleted"
  FAIL=1
fi

# ---- RECORD INSERTION ACROSS COLLECTIONS, ON THE VAL (DEFAULT) ARM ----
# WHY A HEAP LADDER AND A LITERAL EXPECTATION, when the file's other rows either
# compare the two arms or read a golden.  The defect this row pins
# (`Rt.recAppend`'s data array, unrooted across the names array's allocation) is
# VAL-ARM code with no word-arm twin — the word arm refuses RecordUpdate
# outright — so there is no second representation to be the oracle, and the
# number IS the measurement.  What makes the row fail-able is the LADDER: the
# pre-fix fixture SEGFAULTED at QBE_HEAP_MB=1 and 2 and answered 5999 of 6000 at
# 4 and 8, so a single default-knob run would have passed it.  MEASURED RED
# before the fix and GREEN after, at every rung.
run_heap_ladder() {
  local name="$1" fixture="$2" entry="$3" want="$4"
  local bin
  bin="$("$ROOT/tools/qbe/qbe-mk.sh" "$fixture" "$entry" "$TMP/$name")" || {
    echo "FAIL $name: qbe-mk"; FAIL=1; return
  }
  local mb out rc first=""
  for mb in 1 2 4 default; do
    if [ "$mb" = "default" ]; then
      out="$(timeout 120 "$bin" "$entry" 2>&1)"
    else
      out="$(timeout 120 env QBE_HEAP_MB="$mb" "$bin" "$entry" 2>&1)"
    fi
    rc=$?
    if [ "$rc" != 0 ]; then
      echo "FAIL $name: QBE_HEAP_MB=$mb exited $rc (a crash IS the defect: an unrooted or half-filled array walked by the collector) — $out"
      FAIL=1
      return
    fi
    if [ "$out" != "$want" ]; then
      echo "FAIL $name: QBE_HEAP_MB=$mb printed '$out', expected '$want'"
      FAIL=1
      return
    fi
    first="$out"
  done
  echo "PASS $name: 4 heap rungs (QBE_HEAP_MB=1/2/4/default) all exit 0 and print '$first' — record insertion survives a collection on the DEFAULT arm"
}

if [ -f "$ROOT/tools/qbe/fixtures/recinschurn.elm" ]; then
  run_heap_ladder recins-churn "tools/qbe/fixtures/recinschurn.elm" M.main '"6000/6000/0"' 
else
  echo "FAIL recins-churn: tools/qbe/fixtures/recinschurn.elm is missing — the ONLY oracle that collects under record INSERTION was deleted"
  FAIL=1
fi

# ---- THE WORD ARM'S FIXNUM BOUNDARY, EXECUTED (perf word-arm-arith) ----
# The one place the two arms must NOT agree, so it cannot be a word-arm-diff
# row: a word-arm fixnum is an i61, so a result at or beyond 2^60 in magnitude
# has no fixnum encoding while the val arm carries the exact i64 value.  Before
# this row the `mknum` round-trip refusal existed only at EMISSION level (a
# TestMain row asserting the .ssa carries the `Rt.die` call) — a statement about
# TEXT.  A refusal nobody has ever seen fire is not a tested refusal, and the
# failure it guards against (silently dropping a fixnum's top three bits) is the
# silent-wrong class this whole arm exists to prevent.  The script gates the
# word arm on (exit 1 AND the named message), the val arm on the exact 2^61
# product, and the INSIDE edge (2^59) on NOT being refused — so it cannot pass
# by refusing everything large.
if [ -x "$ROOT/tools/qbe/word-arm-i61.sh" ] && [ -d "$ROOT/tools/qbe/word-arm-i61" ]; then
  if i61_out="$(TMPDIR="$TMP" "$ROOT/tools/qbe/word-arm-i61.sh" 2>&1)"; then
    echo "PASS word-arm-i61: $(printf '%s\n' "$i61_out" | grep -c '^PASS ') row(s) — the i61 boundary EXECUTED: 2^61 halts with the NAMED refusal on the word arm, the val arm prints the exact i64 value, and 2^59 (the inside edge) is not refused"
  else
    echo "FAIL word-arm-i61: the word arm's fixnum boundary no longer behaves (a silent truncation, a crash instead of the named refusal, or an over-refusal)"
    printf '%s\n' "$i61_out" | sed 's/^/    /'
    FAIL=1
  fi
else
  echo "FAIL word-arm-i61: tools/qbe/word-arm-i61.sh or its fixture dir is missing — the ONLY row that EXECUTES the i61 refusal was deleted"
  FAIL=1
fi

if [ -x "$ROOT/tools/qbe/word-arm-probe.sh" ]; then
  if probe_out="$(TMPDIR="$TMP" "$ROOT/tools/qbe/word-arm-probe.sh" 2>&1)"; then
    echo "PASS word-arm-probe: $(printf '%s\n' "$probe_out" | grep -c '^PASS ') probe(s) RUN and passed ($(printf '%s\n' "$probe_out" | grep -c '^PASS ') of $(printf '%s\n' "$probe_out" | grep -c '^PASS '), $(printf '%s\n' "$probe_out" | grep -oE '[0-9]+ checks' | grep -oE '^[0-9]+' | paste -sd+ | bc) checks) — the word arm's heap side AND its CALL ABI execute against the runtime's seat convention"
  else
    echo "FAIL word-arm-probe: the word arm's behaviour probe FAILED (the heap side no longer runs correctly under QBE_VALREP=word)"
    printf '%s\n' "$probe_out" | sed 's/^/    /'
    FAIL=1
  fi
else
  echo "FAIL word-arm-probe: tools/qbe/word-arm-probe.sh is missing or not executable — the ONLY oracle that runs word-arm code was deleted"
  FAIL=1
fi

exit $FAIL
