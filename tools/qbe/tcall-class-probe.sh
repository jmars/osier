#!/usr/bin/env bash
# tcall-class-probe.sh — THE `tcall` CLASS CONDITION, in BOTH directions, on the
# arm that only just started using it (perf word-arm-area6).
#
# WHY THIS EXISTS.  The word arm's `rt_call2r` did not `tcall` its callee, and
# the reason recorded for that was WRONG.  The record said the word arm emits
# `tcall :val %code(env %e, l %pv0)` "in a block that LOADED `%pv0` first" and
# that the vendored QBE rejects exactly that ("tcall must be the last
# instruction of its block").  MEASURED, four shapes: that exact shape
# ASSEMBLES.  The reproduction that had seemed to red it was malformed twice
# over — its `export function` omitted the return type (QBE: "newline expected,
# got ??"), and its mutation put the load AFTER the tcall, which trips the
# bare-`ret` rule instead.  The ONE shape QBE refuses is a CLASS MISMATCH: the
# callee's return class must equal the enclosing function's (abi1's C4), and
# both mismatch directions are refused BY NAME.
#
# AND THE FIRST CUT HIT A DIFFERENT, REAL REFUSAL — this script's row 3 is what
# caught it.  Removing the word-arm exclusion DID fail to assemble, for a
# reason nobody had written down: `gcm`'s `sink()` appends instructions AFTER a
# `tcall`.  gvn CSEs the arity blocks' shared address chains into a dominator,
# so a load has no local chain; `sink()` re-materialises that chain in the
# load's block, and `sinkref` emits the instruction BEFORE rewriting its args,
# so the copies it recurses into are DEAD; `addins` appends, so they land after
# the tcall, and `schedblk` has no use edge to order the dead ones by.  The
# val arm never sees it because it passes arg POINTERS and its tcall blocks
# hold no load at all.  The fix moves each argument's load one block earlier
# (into the dispatch block that proves the argument exists), leaving every
# tcall block with only env/args/tcall — row 3 asserts that shape, so a
# regression that moves a load back into a tcall block FAILS HERE.
#
# ROWS.
#   1  the legal shape assembles: a `:val` caller, the load immediately before
#      the `tcall`, a bare `ret` after it — rc 0.
#   2  a class MISMATCH is refused BY NAME, in BOTH directions (the polarity is
#      not one-sided: caller `l` + callee `:val`, and caller `:val` + callee
#      `l`).  Gated on the exit code AND the message, never on silence.
#   3  the REAL word-arm emit (the tree's own compiler, default arm) has NO
#      load in any `tcall` block, every `tcall` is the last instruction of its
#      block, and the whole program assembles.
#   4  NO MIXED-REPRESENTATION EMIT: the `:val` the tcall returns is the word
#      arm's 8-byte one, `rt_call2r` strides by 8, and the tcalls pass LOADED
#      WORDS (`l %pv<n>`) — never pointers (`l %p<n>`), which is what the val
#      arm passes and what a half-ported arm would silently pass here.
#
# The stack half of the same fix (1e6 hops under an OWNED 8 MiB stack) is
# qbe-check's `clostail-big` row, not repeated here: this script is about the
# SHAPE and the CLASS, that row is about the FRAME.
#
# Usage (from the repo root):
#   tools/qbe/tcall-class-probe.sh          # run every row, gate on it
#   tools/qbe/tcall-class-probe.sh --keep   # leave the scratch dir
#
# Exit: 0 = every row passed; 1 = a row failed; 2 = prerequisite missing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QBE="$ROOT/vendor/qbe/qbe"
FIXTURE="$ROOT/tools/qbe/fixtures/clostail.elm"
ENTRY="ClosTail.main"

[ -x "$QBE" ] || { echo "tcall-class-probe: $QBE missing (run: tools/qbe-build.sh)" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "tcall-class-probe: $FIXTURE missing" >&2; exit 2; }
[ -f "$ROOT/osier-compiler/run.js" ] || { echo "tcall-class-probe: osier-compiler/run.js missing" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "tcall-class-probe: node missing" >&2; exit 2; }

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tcall-class-probe.XXXXXX")" || exit 2
cleanup() { [ "$KEEP" = 1 ] && { echo "tcall-class-probe: build dir $BUILD"; return; }; rm -rf "$BUILD"; }
trap cleanup EXIT

fails=0
note() { echo "FAIL $*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# 1. THE LEGAL SHAPE — the word arm's own emitted tcall block, hand-written so
#    the row is independent of the compiler under test.
# ---------------------------------------------------------------------------
cat >"$BUILD/legal.ssa" <<'EOF'
type :val = align 8 { l }

export function :val $caller(l %code, l %p0) {
@start
	%pv0 =l loadl %p0
	tcall :val %code(env %code, l %pv0)
	ret
}
EOF
if "$QBE" "$BUILD/legal.ssa" -o "$BUILD/legal.s" 2>"$BUILD/legal.err"; then
	echo "PASS legal-shape: tcall :val with a load immediately before it and a bare ret after it assembles (the shape the record claimed QBE refuses)"
else
	note "legal-shape: qbe rejected the shape the word arm emits: $(head -2 "$BUILD/legal.err" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. THE CLASS CONDITION, BOTH DIRECTIONS — each mismatch must be refused and
#    must NAME the condition.
# ---------------------------------------------------------------------------
# 2a: caller returns `l`, callee returns `:val`.
cat >"$BUILD/mm-a.ssa" <<'EOF'
type :val = align 8 { l }

export function l $caller(l %code, l %p0) {
@start
	%pv0 =l loadl %p0
	tcall :val %code(env %code, l %pv0)
	ret
}
EOF
# 2b: caller returns `:val`, callee returns `l`.
cat >"$BUILD/mm-b.ssa" <<'EOF'
type :val = align 8 { l }

export function :val $caller(l %code, l %p0) {
@start
	%pv0 =l loadl %p0
	tcall l %code(env %code, l %pv0)
	ret
}
EOF
check_refusal() {
	local f="$1" want="$2" msg rc
	msg="$("$QBE" "$BUILD/$f" -o /dev/null 2>&1)"; rc=$?
	if [ "$rc" -eq 0 ]; then
		note "class-mismatch $f: qbe ASSEMBLED a tcall whose class disagrees with the enclosing function — a wrong tail is worse than none"
	elif ! printf '%s' "$msg" | grep -qF "$want"; then
		note "class-mismatch $f: refused without naming the condition (want \"$want\", got \"$(printf '%s' "$msg" | head -1)\")"
	else
		echo "PASS class-mismatch $f: refused by name"
	fi
}
check_refusal mm-a.ssa "tcall: the callee returns an aggregate, the enclosing function does not"
check_refusal mm-b.ssa "tcall: the callee's return class does not match the enclosing function's"

# ---------------------------------------------------------------------------
# 3. THE REAL EMIT — the tree's own compiler, DEFAULT arm (the word arm since
#    the VR3d flip), on the one fixture whose chain routes through the generic
#    apply path.
# ---------------------------------------------------------------------------
SSA="$BUILD/clostail.ssa"
if ! ( cd "$ROOT/osier-compiler" && QBE_ENTRY="$ENTRY" node run.js "$FIXTURE" "$SSA" ) >"$BUILD/emit.log" 2>&1; then
	note "real-emit: the compiler failed to emit: $(head -3 "$BUILD/emit.log" | tr '\n' ' ')"
else
	# rt_call2r's arity blocks, extracted from the emit (label TAB instruction).
	awk '/^export function .*rt_call2r\(/{f=1} f&&/^@arity[0-9]+$/{b=$0} f&&b!=""{print b"\t"$0} f&&/^\}$/{exit}' "$SSA" >"$BUILD/arity.lines"
	if [ ! -s "$BUILD/arity.lines" ]; then
		note "real-emit: \$rt_call2r is not in the emit at all"
	else
		# 3a: NO ARITY BLOCK THAT TCALLS MAY LOAD.  A block that both loads and
		# tcalls gets dead copies appended after its tcall by gcm's sink pass,
		# and abi1 refuses the emit.  Scoped to the TCALL blocks on purpose: the
		# last arity takes an ordinary CALL (over the tcall budget) and loading
		# there is legal and necessary.
		if python3 - "$BUILD/arity.lines" <<'PY'
import sys
blocks, cur = {}, None
for l in open(sys.argv[1]):
	lab, _, ins = l.partition('\t')
	blocks.setdefault(lab.strip(), []).append(ins)
bad = [b for b, ins in blocks.items() if any('tcall' in i for i in ins) and any('=l loadl' in i for i in ins)]
for b in bad:
	print('loads in tcall block %s' % b)
sys.exit(1 if bad else 0)
PY
		then
			echo "PASS real-emit: no tcall block loads (the load lives in the dispatch block that proves the argument exists)"
		else
			note "real-emit: a tcall block LOADS an argument — gcm's sink pass appends dead copies after a tcall in any block that both loads and tcalls, so qbe will refuse the emit"
		fi
		# 3b: every tcall in the WHOLE emit is the last instruction of its block.
		python3 - "$SSA" <<'PY' >"$BUILD/tcall.pos" 2>&1
import sys
lines = open(sys.argv[1]).read().split('\n')
bad = 0
for i, l in enumerate(lines):
	if l.lstrip().startswith('tcall'):
		nxt = lines[i + 1] if i + 1 < len(lines) else ''
		if nxt.strip() != 'ret':
			print('tcall at line %d is followed by %r' % (i + 1, nxt))
			bad += 1
print('total', sum(1 for l in lines if l.lstrip().startswith('tcall')), 'bad', bad)
sys.exit(1 if bad else 0)
PY
		if [ $? -ne 0 ]; then
			note "real-emit: a tcall is not the last instruction of its block: $(head -3 "$BUILD/tcall.pos" | tr '\n' ' ')"
		else
			echo "PASS real-emit: every tcall ($(awk '{print $2}' "$BUILD/tcall.pos") in the program) is followed by a bare ret"
		fi
	fi
	# 3c: THE DERIVED FAIL-BEFORE.  Give the block that tcalls its own address
	# chain and load again — the shape the first cut emitted — and the same file
	# must be REFUSED.  Derived from the real emit, so it cannot drift from the
	# thing it is about; without this row 3a would only ever prove the author's
	# own shape was the one written.  A bare re-load would NOT do: it is the
	# same address @c1 already loaded, and loadopt forwards it away, so the
	# mutation would assemble and prove nothing (MEASURED — that is why this
	# row duplicates the chain, which gvn then CSEs back out, leaving the load
	# with no local chain, which is the condition that makes sink() fire).
	python3 - "$SSA" "$BUILD/movedback.ssa" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
ci = lines.index('@c1')
body = []
j = ci + 1
while not lines[j].startswith('\tjnz') and not lines[j].startswith('@'):
	body.append(lines[j])
	j += 1
ai = lines.index('@arity1')
lines[ai + 1:ai + 1] = body
open(dst, 'w').write('\n'.join(lines))
a1 = []
k = ai + 1
while k < len(lines) and not lines[k].startswith('@'):
	a1.append(lines[k])
	k += 1
open(dst + '.arity1', 'w').write('\n'.join(a1) + '\n')
print('duplicated @c1\'s %d chain+load line(s) into @arity1' % len(body))
PY
	if [ ! -s "$BUILD/movedback.ssa" ]; then
		note "derived-fail-before: the mutation did not produce a file"
	elif ! grep -q 'tcall' "$BUILD/movedback.ssa.arity1"; then
		echo "SKIP derived-fail-before: @arity1 does not tcall on this tree, so there is no shape here for the row to break (an arm that emits no tcall at all is qbe-check's clostail-big red, not this row)"
	else
		msg="$("$QBE" "$BUILD/movedback.ssa" -o /dev/null 2>&1)"; rc=$?
		if [ "$rc" -eq 0 ]; then
			note "derived-fail-before: qbe ASSEMBLED a tcall block that loads its own argument — the shape this fix exists to avoid is silently accepted, so row 3a proves nothing"
		elif ! printf '%s' "$msg" | grep -qF 'tcall must be the last instruction of its block'; then
			note "derived-fail-before: refused, but not for the measured reason (got \"$(printf '%s' "$msg" | head -1)\")"
		else
			echo "PASS derived-fail-before: loading an argument inside the tcall block is REFUSED by name ($(printf '%s' "$msg" | head -1 | sed 's/^qbe:[^:]*: //'))"
		fi
	fi

	# 3d: the whole program assembles.
	if "$QBE" "$SSA" -o "$BUILD/clostail.s" 2>"$BUILD/real.err"; then
		echo "PASS real-emit: the word arm's .ssa assembles (rc 0)"
	else
		note "real-emit: qbe refused the word arm's own emit: $(head -2 "$BUILD/real.err" | tr '\n' ' ')"
	fi
fi

# ---------------------------------------------------------------------------
# 4. NO MIXED-REPRESENTATION EMIT — the class AND the argument convention.
# ---------------------------------------------------------------------------
if [ -s "$SSA" ]; then
	if ! grep -qx 'type :val = align 8 { l }' "$SSA"; then
		note "mixed-rep: :val is not the word arm's 8-byte aggregate ($(grep -m1 '^type :val' "$SSA"))"
	elif ! grep -q '^	%napp40 =l mul %napp, 8$' "$SSA"; then
		note "mixed-rep: rt_call2r does not stride by the word arm's 8 bytes ($(grep -m1 'napp40' "$SSA"))"
	elif awk '/^\ttcall :val %code\(env %e, l %p[0-9]+/ {found=1} END {exit !found}' "$SSA"; then
		note "mixed-rep: a tcall passes an arg POINTER (l %p<n>) — the val arm's convention — where the word arm's callee expects a loaded word"
	else
		echo "PASS mixed-rep: 8-byte :val, 8-byte stride, and the tcalls pass loaded words (l %pv<n>), never pointers"
	fi
else
	note "mixed-rep: no emit to inspect"
fi

if [ "$fails" -ne 0 ]; then
	echo "=============================="
	echo "tcall-class-probe: $fails row(s) FAILED"
	exit 1
fi
echo "=============================="
echo "tcall-class-probe: all rows PASS"
