#!/usr/bin/env bash
# osier-bench.sh — the REPRESENTATIVE workload suite for the Osier language.
#
# WHY THIS EXISTS.  Every optimisation in this tree until now was measured on
# ONE workload: the compiler compiling its own 58-source corpus.  That corpus
# was measured to be unrepresentative — 9 let-bound record literals in 58
# sources, 667 record literals that all escape, 459 RecordUpdate sites ALL
# with parameter bases, no numeric loops (docs/qbe-backend.md, "Aggregate
# flattening — what it buys, and on what").  Flatten measured -0.08% on it,
# and four passes (contify/loop-*, monomorphise, poly-equal) were eliminated
# or deferred on ratios measured from it.  This runner is the instrument whose
# absence caused those calls: it times the shapes the corpus lacks.
#
# WHAT IT DOES.  For every program in tools/bench/suite/*.elm (one shape
# each):
#   * compiles it ONCE PER BACKEND (the compile is never inside the timing),
#   * runs it N times (OSIER_BENCH_RUNS, default 3) and keeps the BEST
#     (OSIER_BENCH_STAT=median for the median instead — the mode is printed),
#   * requires every run to produce the SAME bytes, and cross-checks the VM's
#     stdout against the native binary's — a benchmark whose two backends
#     disagree is not a measurement,
# and then prints a WORKLOAD-MIX summary that can express, per backend, which
# shapes WERE measured and which were NOT (declared-not-expressible, tool
# missing, compile failure, run failure, backend disagreement).
#
# BACKENDS
#   VM   (reference) node elm-compiler/run.js <src> <out.csexp>   MIDTIER=0
#                    zig-out/bin/elmvm <out.csexp> <Entry>        ELMC_HEAP_MB
#   QBE  (native)    tools/qbe/qbe-mk.sh <src> <Entry> <outdir>   (repo-rel src)
#                    <outdir>/<basename> <Entry>                  QBE_HEAP_MB
#   AOT  (if built)  zig-out/bin/aotbench <bundle.csexp> <Entry>  ELMC_HEAP_MB
#
# EXIT: 0 only if every non-declared (program, backend) pair compiled AND ran
# AND agreed with the VM.  A backend whose TOOL is absent is a skip, not a
# failure — it is reported as MISSING-TOOL and named in the summary.  A
# program that did not compile, did not run, or ran out of heap IS a failure.
#
# DECLARED NOT-EXPRESSIBLE.  The mechanism stays: a shape the native backend
# cannot express is a first-class RESULT, not something to drop, so a pair can
# be DECLARED below together with the exact error substring expected.  The
# declaration is honoured ONLY when the build really fails AND the observed
# error contains that substring:
#   * a pair that starts BUILDING is reported as a stale declaration (the
#     declared row simply becomes a measured row),
#   * a pair that fails for a DIFFERENT reason is a hard failure.
# So the declaration cannot hide anything.  OSIER_BENCH_STRICT=1 ignores every
# declaration, so the whole exemption mechanism can be audited in one command.
#
# THE ONE ENTRY THAT WAS HERE IS GONE, DELIBERATELY: mono_float was declared
# `qbe:unknown keyword .0` (Mid/Qbe/Print.elm emitted a float data item as
# `d 0.0`, which the vendored QBE's data lexer rejects).  The emitter now
# prints the CONST's `d_` sigil and Mid/Qbe/Lower.elm's LFloat arm stores the
# payload, so the pair builds and the row measures.  Deleting the entry is the
# point: leaving it in would be the stale declaration the mechanism detects —
# DECLARED is EMPTY on purpose.
#
# SCRATCH: mktemp -d, removed by a trap on EXIT.  A fixed scratch path
# persists across runs, and anything read back without being rebuilt then
# answers from the PREVIOUS run — the bug documented in tools/qbe/qbe-check.sh.
#
# Usage: tools/osier-bench.sh [program-name ...]      (default: all in the suite)
# Env:   OSIER_BENCH_RUNS=n        runs per (program, backend)   [3]
#        OSIER_BENCH_STAT=best|median                            [best]
#        OSIER_BENCH_HEAP_MB=n     VM + native heap, MB          [512]
#        OSIER_BENCH_TIMEOUT=s     per-run timeout, seconds      [300]
#        OSIER_BENCH_STRICT=1      ignore declared-not-expressible
#        OSIER_BENCH_XCHECK=0      skip the VM-vs-native output cross-check
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$ROOT/tools/bench/suite"
ELMVM="$ROOT/zig-out/bin/elmvm"
AOTBENCH="$ROOT/zig-out/bin/aotbench"
QBE_MK="$ROOT/tools/qbe/qbe-mk.sh"
CDIR="$ROOT/elm-compiler"

RUNS="${OSIER_BENCH_RUNS:-3}"
STAT="${OSIER_BENCH_STAT:-best}"
HEAP_MB="${OSIER_BENCH_HEAP_MB:-512}"
RUN_TIMEOUT="${OSIER_BENCH_TIMEOUT:-300}"
STRICT="${OSIER_BENCH_STRICT:-0}"
XCHECK="${OSIER_BENCH_XCHECK:-1}"

case "$STAT" in best|median) ;; *) echo "osier-bench: OSIER_BENCH_STAT must be best|median (got '$STAT')" >&2; exit 2 ;; esac
case "$RUNS" in ''|*[!0-9]*) echo "osier-bench: OSIER_BENCH_RUNS must be a positive integer" >&2; exit 2 ;; esac
[ "$RUNS" -ge 1 ] || { echo "osier-bench: OSIER_BENCH_RUNS must be >= 1" >&2; exit 2; }

# ---- declared not-expressible pairs: <program>:<backend>:<error substring> --
# The substring is matched against the backend's OWN error text, so the
# declaration can only ever excuse THAT failure.
DECLARED=(
)

# ---- required tools -------------------------------------------------------
for tool in node awk sed sort date head grep wc cmp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "osier-bench: $tool not on PATH" >&2; exit 2; }
done

HAVE_VM=0; HAVE_QBE=0; HAVE_AOT=0
if [ -x "$ELMVM" ]; then HAVE_VM=1; fi
if [ -x "$ROOT/vendor/qbe/qbe" ] && [ -x "$QBE_MK" ]; then HAVE_QBE=1; fi
if [ -x "$AOTBENCH" ]; then HAVE_AOT=1; fi
if [ "$HAVE_VM" = 0 ]; then
  echo "osier-bench: $ELMVM missing (run: zig build elmvm) — the VM is the REFERENCE backend" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osier-bench.XXXXXX")" || { echo "osier-bench: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ---- program selection ----------------------------------------------------
want=("$@")
selected=()
for src in "$SUITE"/*.elm; do
  [ -f "$src" ] || continue
  name="$(basename "$src" .elm)"
  if [ "${#want[@]}" -eq 0 ]; then
    selected+=("$src")
  else
    for w in "${want[@]}"; do
      if [ "$w" = "$name" ]; then selected+=("$src"); fi
    done
  fi
done
if [ "${#selected[@]}" -eq 0 ]; then
  if [ "${#want[@]}" -eq 0 ]; then
    echo "osier-bench: no programs in $SUITE" >&2
  else
    echo "osier-bench: no such suite program: ${want[*]}" >&2
  fi
  exit 2
fi

vm_yes=NO; [ "$HAVE_VM" = 1 ] && vm_yes=yes
qbe_yes=NO; [ "$HAVE_QBE" = 1 ] && qbe_yes=yes
aot_yes=NO; [ "$HAVE_AOT" = 1 ] && aot_yes=yes
echo "osier-bench: ${#selected[@]} programs, backends VM=$vm_yes QBE=$qbe_yes AOT=$aot_yes, $STAT of $RUNS run(s), heap ${HEAP_MB}MB, scratch $TMP"

# ---- the timer ------------------------------------------------------------
LAST_MS=0
LAST_RC=0
run_once() { # <prefix> <cmd...>   stdout -> <prefix>.out, stderr -> <prefix>.err
  local prefix="$1"; shift
  local t0 t1 rc
  t0="$(date +%s%N)"
  set +e
  timeout "$RUN_TIMEOUT" "$@" >"$prefix.out" 2>"$prefix.err"
  rc=$?
  set -e
  t1="$(date +%s%N)"
  LAST_RC=$rc
  LAST_MS=$(( (t1 - t0) / 1000000 ))
}

run_n_times() { # <prefix> <cmd...>   appends "<run> <ms> <rc>" to <prefix>.runs
  local prefix="$1"; shift
  local i
  : > "$prefix.runs"
  for ((i = 0; i < RUNS; i++)); do
    run_once "$prefix.$i" "$@"
    echo "$i $LAST_MS $LAST_RC" >> "$prefix.runs"
  done
}

# <ms> <run-index> of the representative run under $STAT (lower median).
pick_stat() {
  local prefix="$1" n line
  n="$(wc -l < "$prefix.runs")"
  if [ "$STAT" = "best" ]; then
    line="$(sort -k2,2n "$prefix.runs" | head -1)"
  else
    line="$(sort -k2,2n "$prefix.runs" | sed -n "$(( (n + 1) / 2 ))p")"
  fi
  awk '{ print $2, $1 }' <<<"$line"
}

n_ok_runs() { # number of runs that exited 0
  local prefix="$1"
  awk '$3 == 0' "$prefix.runs" | wc -l
}

# A shape is only measured if EVERY run produced the same bytes: a
# nondeterministic program must not pass as a measurement.
same_output_every_run() {
  local prefix="$1" first f
  first="$prefix.0.out"
  if [ ! -f "$first" ]; then return 1; fi
  for f in "$prefix".*.out; do
    if ! cmp -s "$first" "$f"; then return 1; fi
  done
  return 0
}

# stderr is not decoration: a heap that had to grow (or a panic) means the run
# was heap-bounded and its wall clock is not this shape's cost.
benign_stderr() {
  local prefix="$1" f
  for f in "$prefix".*.err; do
    if [ -s "$f" ] && grep -Eq 'grow_heap|panic|Unable to allocate' "$f"; then
      return 1
    fi
  done
  return 0
}


first_stderr_any() { # stderr of the representative run, or the first non-empty
  local prefix="$1" f
  if [ -s "$prefix.rep.err" ]; then head -1 "$prefix.rep.err"; return; fi
  for f in "$prefix".*.err; do
    if [ -s "$f" ]; then head -1 "$f"; return; fi
  done
}

# ---- result accumulation --------------------------------------------------
R_NAME=(); R_SHAPE=()
declare -A RES_VM=() RES_QBE=() RES_AOT=()
FAIL=0
XC_N=0   # VM/native cross-checks that actually compared byte-identical
WARN=()

note_fail() { echo "osier-bench: FAIL $1" >&2; FAIL=1; }

# declared_na <program> <backend> <error-text>: 0 = the declaration excuses
# exactly this failure.
declared_na() {
  if [ "$STRICT" = 1 ]; then return 1; fi
  local d p b sub
  for d in "${DECLARED[@]}"; do
    p="${d%%:*}"; d="${d#*:}"
    b="${d%%:*}"; sub="${d#*:}"
    if [ "$p" = "$1" ] && [ "$b" = "$2" ]; then
      case "$3" in *"$sub"*) return 0 ;; esac
    fi
  done
  return 1
}

declared_reason() { # <program> <backend>
  local d p b sub
  for d in "${DECLARED[@]}"; do
    p="${d%%:*}"; d="${d#*:}"
    b="${d%%:*}"; sub="${d#*:}"
    if [ "$p" = "$1" ] && [ "$b" = "$2" ]; then echo "$sub"; return; fi
  done
}

# enc <ms> <status> <note>
enc() { echo "$1|$2|$3"; }
enc_ms() { local e="${1:-|}"; if [ -n "${e%%|*}" ]; then printf '%9s' "${e%%|*}"; else printf '%9s' "-"; fi; }
enc_st() { local e="${1:-|}"; e="${e#*|}"; printf '%s' "${e%%|*}"; }
enc_note() { local e="${1:-|}"; printf '%s' "${e##*|}"; }

# ---- per-program ----------------------------------------------------------
for src in "${selected[@]}"; do
  name="$(basename "$src" .elm)"
  mod="$(awk '/^[[:space:]]*module[[:space:]]/{print $2; exit}' "$src")"
  shape="$(sed -n 's/^-- SHAPE: \([^ ]*\) .*/\1/p' "$src" | head -1)"
  if [ -z "$shape" ]; then
    shape="?"
    WARN+=("$name: no readable '-- SHAPE: <token> ...' comment (the regex needs text after the token) — the shape label is lost; the row prints '?'")
  fi
  entry="$mod.main"
  work="$TMP/$name"
  mkdir -p "$work"
  R_NAME+=("$name"); R_SHAPE+=("$shape")

  # ---------- VM (the reference) ----------
  vmb="$work/vm.csexp"
  ( cd "$CDIR" && MIDTIER=0 node run.js "$src" "$vmb" ) >"$work/vm.compile.log" 2>&1 || true
  # THE ORACLE IS THE FILE, NOT THE EXIT STATUS: run.js exits 0 on a type
  # error and writes "err ..." into the csexp (the QBE path checks the same
  # prefix — this is the VM's copy of that check).
  if [ ! -s "$vmb" ]; then
    RES_VM["$name"]="$(enc '' COMPILE-FAIL "no bundle written: $(tail -1 "$work/vm.compile.log" | head -c 120)")"
    note_fail "$name (vm): no bundle written"
  elif head -c 4 "$vmb" | grep -q '^err '; then
    RES_VM["$name"]="$(enc '' COMPILE-FAIL "$(head -c 160 "$vmb")")"
    note_fail "$name (vm): compile failed"
  else
    run_n_times "$work/vm" env ELMC_HEAP_MB="$HEAP_MB" "$ELMVM" "$vmb" "$entry"
    if [ "$(n_ok_runs "$work/vm")" -ne "$RUNS" ]; then
      RES_VM["$name"]="$(enc "$(pick_stat "$work/vm" | awk '{print $1}')" RUN-FAIL "rc!=0 or timeout (${RUN_TIMEOUT}s): $(first_stderr_any "$work/vm" | head -c 100)")"
      note_fail "$name (vm): run failed"
    elif ! same_output_every_run "$work/vm"; then
      RES_VM["$name"]="$(enc "$(pick_stat "$work/vm" | awk '{print $1}')" RUN-FAIL "stdout differs between runs")"
      note_fail "$name (vm): nondeterministic"
    elif ! benign_stderr "$work/vm"; then
      RES_VM["$name"]="$(enc "$(pick_stat "$work/vm" | awk '{print $1}')" RUN-FAIL "heap-bounded/panicking stderr: $(first_stderr_any "$work/vm" | head -c 90)")"
      note_fail "$name (vm): heap-bounded"
    else
      read -r ms idx <<<"$(pick_stat "$work/vm")"
      cp "$work/vm.$idx.out" "$work/vm.rep.out"
      cp "$work/vm.$idx.err" "$work/vm.rep.err"
      note=""
      if [ -s "$work/vm.rep.err" ]; then note="stderr:$(head -c 60 "$work/vm.rep.err" | tr '\n' ' ')"; fi
      RES_VM["$name"]="$(enc "$ms" OK "$note")"
    fi
  fi

  # ---------- QBE (native) ----------
  if [ "$HAVE_QBE" = 0 ]; then
    RES_QBE["$name"]="$(enc '' MISSING-TOOL 'vendor/qbe/qbe or tools/qbe/qbe-mk.sh not built')"
  else
    rel="tools/bench/suite/$name.elm"
    set +e
    qb="$("$QBE_MK" "$rel" "$entry" "$work/qbe" 2>"$work/qbe.build.err" | tail -1)"
    set -e
    if [ -x "$qb" ]; then
      run_n_times "$work/qbe" env QBE_HEAP_MB="$HEAP_MB" "$qb" "$entry"
      if [ "$(n_ok_runs "$work/qbe")" -ne "$RUNS" ]; then
        RES_QBE["$name"]="$(enc "$(pick_stat "$work/qbe" | awk '{print $1}')" RUN-FAIL "rc!=0 or timeout (${RUN_TIMEOUT}s): $(first_stderr_any "$work/qbe" | head -c 100)")"
        note_fail "$name (qbe): run failed"
      elif ! same_output_every_run "$work/qbe"; then
        RES_QBE["$name"]="$(enc "$(pick_stat "$work/qbe" | awk '{print $1}')" RUN-FAIL "stdout differs between runs")"
        note_fail "$name (qbe): nondeterministic"
      elif ! benign_stderr "$work/qbe"; then
        RES_QBE["$name"]="$(enc "$(pick_stat "$work/qbe" | awk '{print $1}')" RUN-FAIL "heap-bounded/panicking stderr: $(first_stderr_any "$work/qbe" | head -c 90)")"
        note_fail "$name (qbe): heap-bounded"
      else
        read -r ms idx <<<"$(pick_stat "$work/qbe")"
        cp "$work/qbe.$idx.out" "$work/qbe.rep.out"
        cp "$work/qbe.$idx.err" "$work/qbe.rep.err"
        note=""
        if [ -s "$work/qbe.rep.err" ]; then note="stderr:$(head -c 60 "$work/qbe.rep.err" | tr '\n' ' ')"; fi
        RES_QBE["$name"]="$(enc "$ms" OK "$note")"
      fi
    else
      # distinguish "the source is not expressible" from "the toolchain broke"
      errtext="$(cat "$work/qbe.build.err"; printf '%s' "$qb")"
      flat="$(printf '%s' "$errtext" | tr '\n' ' ')"
      case "$errtext" in
        # "not expressible on this backend": either the emitter refused the
        # source (the .ssa starts with `err `) or the VENDORED QBE refused the
        # emitted IL (`qbe: <file>.ssa:<line>: ...`).  A `cc:`/`zig build-obj`
        # failure is a toolchain bug instead and falls through to BUILD-FAIL.
        *"qbe-mk: compile failed"*|*"qbe:"*)
          if declared_na "$name" qbe "$errtext"; then
            # Show the LINE the declared substring matched, not the head of the
            # combined text: elm's DEV-mode banner lands on stderr BEFORE qbe's
            # error, so `head -c 110` displayed evidence that did not contain
            # the substring the declaration is actually checked against.
            ev_line="$(printf '%s\n' "$errtext" | grep -F -m1 "$(declared_reason "$name" qbe)" | head -c 170 || true)"
            [ -n "$ev_line" ] || ev_line="$(printf '%s' "$flat" | head -c 170)"
            RES_QBE["$name"]="$(enc '' NOT-EXPRESSIBLE "declared /$(declared_reason "$name" qbe)/ -> $ev_line")"
          else
            # Same evidence rule as the declared case above: show the error
            # line, not the head of the combined text (the DEV banner lands
            # on stderr first and would crowd the real failure out).
            ev_line="$(printf '%s\n' "$errtext" | grep -E -m1 '^(err |qbe: |cc: )' | head -c 170 || true)"
            [ -n "$ev_line" ] || ev_line="$(printf '%s' "$flat" | head -c 170)"
            RES_QBE["$name"]="$(enc '' COMPILE-FAIL "$ev_line")"
            note_fail "$name (qbe): compile failed"
          fi
          ;;
        *)
          ev_line="$(printf '%s\n' "$errtext" | grep -E -m1 '^(err |qbe: |cc: )' | head -c 170 || true)"
          [ -n "$ev_line" ] || ev_line="$(printf '%s' "$flat" | head -c 170)"
          RES_QBE["$name"]="$(enc '' BUILD-FAIL "$ev_line")"
          note_fail "$name (qbe): build failed"
          ;;
      esac
    fi
  fi

  # ---------- cross-check VM vs native ----------
  # Only when both produced a number: a disagreement means one of the two is
  # miscompiling, and a benchmark built on a wrong answer measures nothing.
  # An EMPTY stdout is not agreement either: a measured pair that prints
  # nothing has measured nothing, so it fails instead of comparing equal to
  # itself.
  if [ "$XCHECK" = 1 ] && [ "$(enc_st "${RES_VM[$name]:-}")" = OK ] && [ "$(enc_st "${RES_QBE[$name]:-}")" = OK ]; then
    if [ ! -s "$work/vm.rep.out" ] || [ ! -s "$work/qbe.rep.out" ]; then
      WARN+=("$name: VM/native cross-check FAILED: empty stdout on a measured pair — empty is a FAILURE, not agreement")
      RES_VM["$name"]="$(enc "${RES_VM[$name]%%|*}" EMPTY-STDOUT "measured pair printed nothing")"
      RES_QBE["$name"]="$(enc "${RES_QBE[$name]%%|*}" EMPTY-STDOUT "measured pair printed nothing")"
      note_fail "$name: empty stdout on a measured pair"
    elif ! cmp -s "$work/vm.rep.out" "$work/qbe.rep.out"; then
      vm_val="$(head -c 60 "$work/vm.rep.out")"
      qb_val="$(head -c 60 "$work/qbe.rep.out")"
      WARN+=("$name: VM and native DISAGREE: vm='$vm_val' native='$qb_val'")
      RES_VM["$name"]="$(enc "${RES_VM[$name]%%|*}" MISMATCH "native='$(head -c 50 "$work/qbe.rep.out")'")"
      RES_QBE["$name"]="$(enc "${RES_QBE[$name]%%|*}" MISMATCH "vm='$(head -c 50 "$work/vm.rep.out")'")"
      note_fail "$name: VM/native output mismatch"
    else
      XC_N=$((XC_N + 1))
    fi
  fi

  # ---------- AOT (only if the driver is built) ----------
  if [ "$HAVE_AOT" = 0 ]; then
    RES_AOT["$name"]="$(enc '' MISSING-TOOL 'no zig-out/bin/aotbench (the AOT driver builds per-fixture exes: zig build aotbench-<fixture>, build.zig:161-166)')"
  elif [ ! -s "$work/vm.csexp" ] || head -c 4 "$work/vm.csexp" | grep -q '^err '; then
    RES_AOT["$name"]="$(enc '' SKIPPED 'no VM bundle for this program to load')"
  else
    run_n_times "$work/aot" env ELMC_HEAP_MB="$HEAP_MB" "$AOTBENCH" "$work/vm.csexp" "$entry"
    if [ "$(n_ok_runs "$work/aot")" -ne "$RUNS" ]; then
      RES_AOT["$name"]="$(enc '' RUN-FAIL "rc!=0 or timeout (${RUN_TIMEOUT}s): $(first_stderr_any "$work/aot" | head -c 100)")"
      note_fail "$name (aot): run failed"
    else
      RES_AOT["$name"]="$(enc "$(pick_stat "$work/aot" | awk '{print $1}')" OK "")"
    fi
  fi

  # ---------- row ----------
  printf '%-14s %-11s vm=%-11s qbe=%-11s aot=%-11s\n' \
    "$name" "$shape" \
    "$(enc_ms "${RES_VM[$name]:-}") $(enc_st "${RES_VM[$name]:-}")" \
    "$(enc_ms "${RES_QBE[$name]:-}") $(enc_st "${RES_QBE[$name]:-}")" \
    "$(enc_ms "${RES_AOT[$name]:-}") $(enc_st "${RES_AOT[$name]:-}")"
done

# ---- the mono generic must be ONE source, not three copies ---------------
# The three mono_* programs carry the same generic function between the
# `>>> generic fold` / `<<< generic fold` markers.  If a copy drifted, the
# "monomorphisation axis" would be measuring three different functions.
mono_sig() { sed -n '/>>> generic fold/,/<<< generic fold/p' "$1" | sha256sum | cut -c1-16; }
MONO_FILES=(mono_int mono_float mono_record)
have_mono=1
for m in "${MONO_FILES[@]}"; do
  if [ ! -f "$SUITE/$m.elm" ]; then have_mono=0; fi
done
if [ "$have_mono" = 1 ]; then
  s0="$(mono_sig "$SUITE/mono_int.elm")"
  echo "osier-bench: mono generic sha=$s0 (asserted identical across ${MONO_FILES[*]})"
  for m in "${MONO_FILES[@]}"; do
    if [ "$(mono_sig "$SUITE/$m.elm")" != "$s0" ]; then
      WARN+=("mono generic DRIFTED: $m.elm differs from mono_int.elm (expected sha $s0)")
      note_fail "$m: generic function text differs from mono_int"
    fi
  done
else
  WARN+=("mono_* set incomplete (${MONO_FILES[*]:-}) — the monomorphisation axis is not fully covered")
fi

# ---- workload mix ---------------------------------------------------------
echo
echo "============================= WORKLOAD MIX ============================="
printf '%-14s %-11s %9s %9s %9s  %s\n' program shape vm_ms qbe_ms aot_ms status
for i in "${!R_NAME[@]}"; do
  n="${R_NAME[$i]}"

  printf '%-14s %-11s %9s %9s %9s  vm=%s qbe=%s aot=%s\n' "$n" "${R_SHAPE[$i]}" \
    "$(enc_ms "${RES_VM[$n]:-}")" "$(enc_ms "${RES_QBE[$n]:-}")" "$(enc_ms "${RES_AOT[$n]:-}")" \
    "$(enc_st "${RES_VM[$n]:-}")" "$(enc_st "${RES_QBE[$n]:-}")" "$(enc_st "${RES_AOT[$n]:-}")"
done
echo "times are $STAT of $RUNS run(s), in ms, heap ${HEAP_MB}MB; '-' = no number (see the status)"

echo
echo "---- per-backend coverage and totals ----"
for be in VM QBE AOT; do
  ok=0; tot=0; sum=0; notok=()
  for n in "${R_NAME[@]}"; do
    tot=$((tot + 1))
    case "$be" in
      VM) e="${RES_VM[$n]:-}";; QBE) e="${RES_QBE[$n]:-}";; AOT) e="${RES_AOT[$n]:-}";;
    esac
    st="$(enc_st "$e")"
    if [ "$st" = "OK" ]; then
      ok=$((ok + 1))
      ms="$(enc_ms "$e")"
      sum=$((sum + ${ms// /}))
    else
      notok+=("$n=$st")
    fi
  done
  line="$(printf '%s, ' "${notok[@]:-}" | sed 's/, $//')"
  mean=0
  if [ "$ok" -gt 0 ]; then mean=$((sum / ok)); fi
  printf '%-4s measured %d/%d  total %d ms  mean %d ms' "$be" "$ok" "$tot" "$sum" "$mean"
  if [ "${#notok[@]}" -gt 0 ]; then printf '   NOT MEASURED: %s' "$line"; fi
  printf '\n'
done

echo
echo "---- shapes NOT measured, and why ----"
any=0
for n in "${R_NAME[@]}"; do
  for be in VM QBE AOT; do
    case "$be" in VM) e="${RES_VM[$n]:-}";; QBE) e="${RES_QBE[$n]:-}";; AOT) e="${RES_AOT[$n]:-}";; esac
    st="$(enc_st "$e")"
    if [ "$st" != "OK" ]; then
      any=1
      printf '  %-14s %-4s %-15s %s\n' "$n" "$be" "$st" "$(enc_note "$e")"
    fi
  done
done
if [ "$any" = 0 ]; then echo "  (none: every shape measured on every backend present)"; fi

if [ "${#WARN[@]}" -gt 0 ]; then
  echo
  echo "---- warnings ----"
  for w in "${WARN[@]}"; do echo "  $w"; done
fi

echo
if [ "$FAIL" = 0 ]; then
  if [ "$XC_N" -gt 0 ]; then
    echo "osier-bench: OK — every present backend compiled, ran and agreed ($XC_N VM/native cross-check(s) compared byte-identical)"
  else
    echo "osier-bench: OK — every present backend compiled and ran (0 VM/native cross-checks ran — no agreement is claimed)"
  fi
else
  echo "osier-bench: FAIL — see the rows above" >&2
fi
exit "$FAIL"
