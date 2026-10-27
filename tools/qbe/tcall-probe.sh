#!/usr/bin/env bash
# tcall-probe.sh — THE `tcall` INSTRUCTION'S BEHAVIOUR GATE (Q1a).
#
# WHAT IT PROVES.  vendor/qbe gained a `tcall` instruction whose whole point is
# that the callee returns to the CALLER's caller: the frame goes away and the
# stack does not grow.  A text pin cannot be the oracle for that — a text pin
# asserts the shape the author wrote, and the interesting failure is a shape
# one instruction away (a `jmp` where the teardown should have been, a teardown
# before the argument loads, an sret pointer forwarded to the wrong buffer).
# So the oracle is a program that RUNS.
#
# THE DECISIVE ROW IS AN ASYMMETRY, NOT A RESULT.  Under `ulimit -s 8192`
# (8 MiB) tools/qbe/tcall.ssa's `even`/`odd` pair must complete 1e7 mutual tail
# hops.  The fail-before is the SAME FILE hand-mutated `tcall`->`call` by the
# transformation below — derived here, so it cannot drift from the fixture — and
# it must DIE of stack exhaustion.  1e7 frames is hundreds of megabytes against
# an 8 MiB cap, so the two arms differ by an order of magnitude in stack use and
# not by a judgement call.  A probe never seen to fail is not evidence: if the
# mutated arm survives, this script FAILS rather than reporting the happy arm.
# MEASURED on the landed patch: mutated arm = SIGSEGV (139), tcall arm = exit 0.
#
# THE REFUSAL ROWS ARE THE OTHER HALF.  QBE must never silently degrade a
# `tcall` to a `call`: a silent fallback is correct-by-semantics and
# wrong-by-contract, because it cancels the unbounded-depth guarantee the tail
# call exists to give, and turns a program that ran into one that overflows the
# stack at depth.  Each illegal shape therefore has to fail the COMPILE with a
# message naming the condition — gated here on a non-zero exit AND the message,
# not on the absence of output.  arm64/rv64 must refuse loudly too (they do not
# implement the instruction; a wrong tail is worse than none).
#
# Usage (from the repo root):
#   tools/qbe/tcall-probe.sh            # build + run everything, gate on it
#   tools/qbe/tcall-probe.sh --keep     # leave the build dir for inspection
#
# Exit: 0 = every row passed; 1 = a row failed; 2 = tooling/prerequisite missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QBE="$ROOT/vendor/qbe/qbe"
FIX="$ROOT/tools/qbe/tcall.ssa"
MAIN="$ROOT/tools/qbe/tcall_main.c"
BAD="$ROOT/tools/qbe/tcall-bad"

# the number of checks tcall_main.c prints; a dropped probe must not read as a
# pass
WANT_CHECKS=14
# 1e7 mutual hops: ~1e7 * any frame >= 48 B = ~480 MB against an 8 MiB cap
STACK_KB=8192

[ -x "$QBE" ] || { echo "tcall-probe: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
[ -f "$FIX" ] || { echo "tcall-probe: $FIX missing" >&2; exit 2; }
[ -f "$MAIN" ] || { echo "tcall-probe: $MAIN missing" >&2; exit 2; }
[ -d "$BAD" ] || { echo "tcall-probe: $BAD missing" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "tcall-probe: cc missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "tcall-probe: python3 missing" >&2; exit 2; }

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tcall-probe.XXXXXX")" || exit 2
cleanup() { [ "$KEEP" = 1 ] && { echo "tcall-probe: build dir $BUILD"; return; }; rm -rf "$BUILD"; }
trap cleanup EXIT

fails=0
note() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- 1. the positive fixture, under the stack cap -------------------------
if ! "$QBE" "$FIX" -o "$BUILD/tcall.s" 2>"$BUILD/qbe.err"; then
  note "fixture: qbe rejected tools/qbe/tcall.ssa: $(head -3 "$BUILD/qbe.err" | tr '\n' ' ')"
elif ! cc -O1 -w -o "$BUILD/tcall" "$MAIN" "$BUILD/tcall.s" 2>"$BUILD/cc.err"; then
  note "fixture: cc rejected the assembly: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
else
  out="$( (ulimit -s "$STACK_KB"; "$BUILD/tcall") 2>&1 )"
  rc=$?
  got="$(printf '%s\n' "$out" | grep -c '^PASS')"
  bad="$(printf '%s\n' "$out" | grep -c '^FAIL')"
  # THE EXIT CODE IS PART OF THE ASSERTION: a corrupted sret pointer or a frame
  # read after the teardown prints a wrong NUMBER, and a wrong jump prints
  # nothing at all because it dies as SIGSEGV.
  if [ "$rc" -ne 0 ] || [ "$bad" -ne 0 ] || [ "$got" -ne "$WANT_CHECKS" ]; then
    note "fixture: rc=$rc pass=$got want=$WANT_CHECKS fail=$bad"
    printf '%s\n' "$out" | sed 's/^/    /'
  else
    echo "PASS fixture ($got checks, ${STACK_KB} KiB stack)"
  fi
fi

# --- 2. THE ASYMMETRY: the same fixture with tcall -> call must die --------
python3 - "$FIX" "$BUILD/mut.ssa" <<'PY' >"$BUILD/mut.count" 2>"$BUILD/mut.err"
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
out, n = [], 0
i = 0
while i < len(lines):
    l = lines[i]
    m = re.match(r'^\ttcall (\S+) (.*)$', l)
    if m:
        cls, rest = m.group(1), m.group(2)
        # the following line must be the bare ret this shape requires
        if i + 1 >= len(lines) or lines[i+1] != '\tret':
            sys.stderr.write('no bare ret after tcall on line %d\n' % (i+1))
            sys.exit(3)
        out.append('\t%%tc%d =%s call %s' % (n, cls, rest))
        out.append('\tret %%tc%d' % n)
        n += 1
        i += 2
        continue
    out.append(l)
    i += 1
open(dst, 'w').write('\n'.join(out))
print(n)
PY
mut_n="$(cat "$BUILD/mut.count" 2>/dev/null || echo 0)"
src_n="$(grep -c "$(printf '\t')tcall " "$FIX")"
if [ "$mut_n" != "$src_n" ] || [ "$src_n" -eq 0 ]; then
  note "asymmetry: mutation rewrote $mut_n of $src_n tcall site(s) — the fail-before arm would not exercise the tail path"
else
  if ! "$QBE" "$BUILD/mut.ssa" -o "$BUILD/mut.s" 2>"$BUILD/mutqbe.err"; then
    note "asymmetry: the call-mutated fixture does not even COMPILE ($(head -2 "$BUILD/mutqbe.err" | tr '\n' ' ')) — the fail-before must die at RUN time"
  elif ! cc -O1 -w -o "$BUILD/mut" "$MAIN" "$BUILD/mut.s" 2>"$BUILD/mutcc.err"; then
    note "asymmetry: cc rejected the call-mutated assembly: $(head -2 "$BUILD/mutcc.err" | tr '\n' ' ')"
  else
    # command substitution, not a plain redirect: bash reports a
    # signal-killed foreground child on the script's stderr, and that line
    # reads like a failure in the gate's output
    _="$( ulimit -s "$STACK_KB"; exec "$BUILD/mut" 2>&1 )"
    mrc=$?
    # killed by a signal = stack exhaustion. an exit STATUS (even non-zero)
    # would mean it returned, which is not the failure this arm exists to show.
    if [ "$mrc" -ge 128 ]; then
      echo "PASS asymmetry ($mut_n tcall->call site(s), killed by signal $((mrc - 128)) at ${STACK_KB} KiB)"
    else
      note "asymmetry: the call-mutated fixture SURVIVED (rc=$mrc) under a ${STACK_KB} KiB stack — this probe cannot distinguish a tail call from a call"
    fi
  fi
fi

# --- 3. the refusal rows: each illegal shape fails the COMPILE by name -----
# file | the message the refusal must name
REFUSALS=(
  "midblock.ssa|tcall must be the last instruction of its block"
  "notret.ssa|tcall must be followed by a bare ret"
  "stackargs.ssa|tcall cannot pass arguments on the stack"
  "varargs.ssa|tcall cannot call a variadic function"
  "voidcallee.ssa|the callee returns void"
  "classmismatch.ssa|the callee's return class does not match"
  "aggsize.ssa|aggregate return does not match"
  "aggtoscalar.ssa|the callee returns an aggregate"
)
for spec in "${REFUSALS[@]}"; do
  f="${spec%%|*}"; want="${spec#*|}"
  if [ ! -f "$BAD/$f" ]; then
    note "refusal $f: the fixture is missing — the condition has no test"
    continue
  fi
  msg="$("$QBE" "$BAD/$f" -o /dev/null 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    note "refusal $f: qbe ACCEPTED it — a tcall was silently degraded instead of refused"
  elif ! printf '%s' "$msg" | grep -qF "$want"; then
    note "refusal $f: refused without naming the condition (want \"$want\", got \"$(printf '%s' "$msg" | head -1)\")"
  else
    echo "PASS refusal $f"
  fi
done

# --- 4. the other targets refuse loudly (compile-only) --------------------
for tgt in arm64 rv64; do
  msg="$("$QBE" -t "$tgt" "$FIX" -o /dev/null 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    note "target $tgt: qbe emitted a tail call it does not implement"
  elif ! printf '%s' "$msg" | grep -qF "tcall is not implemented"; then
    note "target $tgt: refused without saying why (got \"$(printf '%s' "$msg" | head -1)\")"
  else
    echo "PASS target $tgt refuses"
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "=============================="
  echo "tcall-probe: $fails row(s) FAILED"
  exit 1
fi
echo "=============================="
echo "tcall-probe: all rows PASS"
