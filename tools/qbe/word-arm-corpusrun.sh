#!/usr/bin/env bash
# word-arm-corpusrun.sh — RUN THE WHOLE CORPUS ON BOTH ARMS AND DIFF THE
# PROGRAMS' OUTPUT (perf word-arm-corpusrun).
#
# WHY THIS ROW EXISTS, and why the census cannot be it.  `word-arm-refusals.sh`
# reports BOTH 125 — "both arms EMIT IL" — and a refusal count cannot see a
# program that compiles cleanly and then answers the wrong number.  This arc's
# own proof of that distinction is the host path: 7 groups printed `[vector 4]`
# with rc 0 and NO stderr, and the census was green over them.  The running
# coverage before this row was 21 word-arm-diff fixtures + 12 gcchurn rows + two
# hand-run subsets (26 `let`-destructuring, 7 host) — NOT the corpus.  This row
# is the corpus: every group that emits IL on both arms is built BOTH ways and
# RUN on both ways, and the two representations are compared on the only
# observable they share, the PROGRAM'S OUTPUT.
#
# WHAT IT DOES, per group the language gate registers (the gate's own manifest,
# as `word-arm-refusals.sh` reads it):
#
#   1. EMIT both arms (val: QBE_VALREP=val, word: QBE_VALREP=word — BOTH
#      EXPLICIT, see `emit()` below) and
#      classify the group exactly as the census does — BOTH / SAME-ERROR /
#      WORD-BLOCKED.  A group that does not emit IL on both arms cannot be run
#      on both arms and is reported as NOT RUN with its class; it is NOT
#      counted as coverage.  (The two instruments therefore always agree about
#      the denominator: BOTH here is the census's BOTH.)
#   2. For a BOTH group: assemble each arm through the SAME vendored qbe, link
#      each with cc, and RUN both binaries.
#   3. Compare EXIT CODE and STDOUT BYTES.  stderr is not compared — the exit
#      code is — because a wrong offset does not print FAIL, it dies as
#      SIGSEGV (139) or SIGABRT (134), and a named `Rt.die` line is a
#      legitimate difference in representation, not in behaviour.
#   4. A TIMEOUT IS A FAILURE, not a skip: a wrong COUNT or stride can LOOP
#      instead of crashing, and a gate that hangs reports nothing.
#
# THE ARGUMENT CONVENTION IS THE GATE'S OWN, and it is the one thing a corpus
# run has to get right: a group is a FIXTURE + an ENTRY, and the values the
# entry is called with are declared per CHECK, not per group.  So the vectors
# come from the gate's own registry (`ELM_GATE_MATRIX=1`): every DISTINCT
# (args, stdin) registered for the group's (fixture, entry) by a RUNNING helper
# (`run`/`run2`/`run_io`) is run on both arms.  That is strictly more than "one
# run per group": `sub` is registered twice with swapped args, and `intbig`-style
# arg vectors are the ones that exercise the ENTRY-ARGUMENT path, which is where
# the P-class root lives.  The six `compile_clean` groups register NO running
# check by design (their value cannot be driven from argv) and are run ONCE with
# no arguments, LABELLED as such in the table — an entry called with an argument
# it was never given is undefined INPUT, not a representation difference, so a
# differing row there is reported as `no-vector` for the reader to judge.
#
# CWD is the repo root, which is the gate's own convention and a hard
# requirement: eight fixtures resolve repo-root-relative paths, and the gate
# refuses to run anywhere else for exactly this reason.
#
# NOT A GATE ITSELF, but it IS an oracle: exit 0 = every group's two arms
# agreed; 1 = a group DISAGREES (a wrong number, a crash, or a hang) or does not
# build on one arm; 2 = the instrument failed (a group emitted nothing, so it
# cannot be classified — crediting that as "both arms agreed" is the same
# failure as crediting a rung that collected nothing).
#
# Usage (from the repo root):
#   tools/qbe/word-arm-corpusrun.sh             # the table
#   tools/qbe/word-arm-corpusrun.sh --vectors   # ... and every vector's line
#
# Cost: two emits + two builds per group (~0.5 s each) and one run per vector,
# OSIER_CORPUS_J parallel on the emits/builds.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
FIX="$ROOT/tests/elm-fixtures"
CDIR="$ROOT/osier-compiler"
QBE="$ROOT/vendor/qbe/qbe"
J="${OSIER_CORPUS_J:-8}"
SECS="${OSIER_CORPUSRUN_TIMEOUT:-20}"
SHOW=table
for a in "$@"; do
  case "$a" in
    --vectors) SHOW=vectors ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "word-arm-corpusrun: node not found" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "word-arm-corpusrun: jq not found" >&2; exit 2; }
command -v cc   >/dev/null 2>&1 || { echo "word-arm-corpusrun: cc missing" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || { echo "word-arm-corpusrun: $CDIR/compiler.js missing (run osier-compiler/build.sh)" >&2; exit 2; }
[ -x "$QBE" ] || { echo "word-arm-corpusrun: $QBE missing (run tools/qbe-build.sh)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-corpusrun.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/val" "$WORK/word" "$WORK/bin" "$WORK/runs" "$WORK/status"

MANIFEST="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)" || {
  echo "word-arm-corpusrun: the gate refused to build its manifest" >&2; exit 2; }
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || {
  echo "word-arm-corpusrun: no manifest path from the gate" >&2; exit 2; }

# DEDUPE BY GROUP NAME.  The manifest registers `sub` TWICE (two argument
# vectors), so `.groups[]` yields two byte-identical plan lines.  Phase 1 drives
# those lines through `xargs -P`, so the duplicate builds `sub` twice
# CONCURRENTLY into the same $W/val/sub.ssa and $W/bin/sub.* — a truncated .s or
# a cc reading a half-written one is the "BUILD-FAIL 1 sub" this gate showed
# intermittently.  The argument vectors come from `vectors.tsv` (keyed by
# fixture+entry), NOT from this plan, so keeping the first occurrence loses no
# coverage: phase 2 still joins BOTH vectors onto the one group.
jq -r '.groups[] | [(.output | split("/")[-1] | sub("\\.ssa$"; "")),
                   (.sources | join(" ")), .entry] | join("|")' \
  "$MANIFEST" | awk -F'|' '!seen[$1]++' > "$WORK/plan.tsv"
[ -s "$WORK/plan.tsv" ] || { echo "word-arm-corpusrun: empty plan" >&2; exit 2; }

# ---- the gate's own ARGUMENT VECTORS, per (fixture, entry fn) --------------
# One line per registered running check: <fixture>|<fn>|<args>|<stdin>|<kind>.
# The fixture column is a BASENAME in the matrix, and the group name is the same
# basename, so the join is exact.  `natproc`/`natrun`/`natrun2`/`natio` are the
# kinds whose binaries the gate RUNS; `nathost`/`natsig`/`natpipe`/`natdepth`
# register no compile group (they build their own binary) and cannot appear here.
ELM_GATE_MATRIX=1 "$GATE" 2>/dev/null | awk -F'\t' '
  NR > 1 && ($1 == "run" || $1 == "run2" || $1 == "run_io") {
    fx = $8; sub(/\.elm$/, "", fx)
    printf "%s|%s|%s|%s|%s\n", fx, $3, $6, $7, $1
  }' > "$WORK/vectors.tsv"
[ -s "$WORK/vectors.tsv" ] || {
  echo "word-arm-corpusrun: the gate's matrix produced no running rows" >&2; exit 2; }

# ---- phase 1: EMIT both arms, classify, and BUILD the BOTH groups ----------
cat > "$WORK/one.sh" <<'EOJ'
#!/usr/bin/env bash
# $1 = "<name>|<src...>|<entry>"
IFS='|' read -r name srcs entry <<< "$1"
W="$WORK"
emit() { # <arm> <out>
  # BOTH ARMS ARE EXPLICIT, NEVER "the default" (flip-prep).  The val arm used
  # to be expressed by QBE_VALREP being UNSET, which means that the day the
  # default flips to word this script compares word against word and still
  # prints 125/125 identical — a vacuous green wearing the headline.  Naming
  # the arm means the flip cannot silently disarm the row.
  local envs=()
  case "$1" in
    val)  envs=(QBE_VALREP=val) ;;
    word) envs=(QBE_VALREP=word) ;;
    *) echo "word-arm-corpusrun: unknown arm '$1'" >&2; exit 2 ;;
  esac
  ( cd "$OSIER_ROOT/osier-compiler" &&
    env "${envs[@]}" QBE=1 QBE_ENTRY="$entry" node run.js $srcs "$2" ) >/dev/null 2>&1
}
emit val  "$W/val/$name.ssa"
emit word "$W/word/$name.ssa"

read_out() { # <path> -> the emit's text, or empty
  [ -s "$1" ] && head -c 1 "$1" >/dev/null 2>&1 && cat "$1" || true
}
v="$(read_out "$W/val/$name.ssa")"
w="$(read_out "$W/word/$name.ssa")"
if [ -z "$v" ] || [ -z "$w" ]; then
  printf 'EMIT-FAIL\n' > "$W/status/$name"; exit 0
fi
case "$w" in
  "err "*) case "$v" in
             "err "*) printf 'SAME-ERROR\n' > "$W/status/$name";;
             *)       printf 'WORD-BLOCKED\n' > "$W/status/$name";;
           esac
           exit 0;;
esac
case "$v" in
  "err "*) printf 'VAL-ONLY-ERROR\n' > "$W/status/$name"; exit 0;;
esac
# BOTH: assemble and link each arm.  A qbe or cc failure is a BUILD-FAIL for
# that arm (a FAIL, never a skip) and is carried into the report.
for arm in val word; do
  ssa="$W/$arm/$name.ssa"
  if ! "$QBE" "$ssa" > "$W/bin/$name.$arm.s" 2> "$W/bin/$name.$arm.qerr"; then
    printf 'BUILD-FAIL %s qbe: %s\n' "$arm" "$(head -1 "$W/bin/$name.$arm.qerr")" >> "$W/status/$name.build"
    continue
  fi
  if ! cc "$W/bin/$name.$arm.s" -o "$W/bin/$name.$arm" -lc 2> "$W/bin/$name.$arm.cerr"; then
    printf 'BUILD-FAIL %s cc: %s\n' "$arm" "$(grep -m1 'undefined reference\|error' "$W/bin/$name.$arm.cerr")" >> "$W/status/$name.build"
    continue
  fi
done
if [ -s "$W/status/$name.build" ]; then
  printf 'BUILD-FAIL\n' > "$W/status/$name"
else
  printf 'BOTH\n' > "$W/status/$name"
fi
EOJ
chmod +x "$WORK/one.sh"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s\0' "$line"
done < "$WORK/plan.tsv" | xargs -0 -r -P "$J" -I{} \
  env WORK="$WORK" OSIER_ROOT="$ROOT" QBE="$QBE" "$WORK/one.sh" "{}"

# ---- phase 2: RUN every vector on both arms and compare --------------------
# <id>|<name>|<entry>|<args>|<stdin>|<kind>|<label>
: > "$WORK/runplan.tsv"
python3 - "$WORK" <<'PY' > "$WORK/runplan.tsv"
import sys, os, collections
W = sys.argv[1]
vec = collections.OrderedDict()
for line in open(os.path.join(W, "vectors.tsv"), errors="replace"):
    line = line.rstrip("\n")
    if not line:
        continue
    fx, fn, args, stdin, kind = line.split("|")
    vec.setdefault(fx, [])
    key = (fn, args, stdin, kind)
    if key not in vec[fx]:
        vec[fx].append(key)
n = 0
seen = set()
for line in open(os.path.join(W, "plan.tsv"), errors="replace"):
    line = line.rstrip("\n")
    if not line:
        continue
    name, srcs, entry = line.split("|")
    if name in seen:
        continue          # `sub` is registered twice; one group, both vectors
    seen.add(name)
    fn = entry.split(".", 1)[1] if "." in entry else entry
    got = vec.get(name, [])
    if not got:
        # no RUNNING check is registered for this group (the six
        # `compile_clean` rows): run it once, unargumented, and SAY SO.
        n += 1
        print("%d|%s|%s|||none|no-vector" % (n, name, entry))
        continue
    for (vfn, args, stdin, kind) in got:
        # the vector's fn is the registered one; the group's entry is the
        # same key unless a group is registered under two entries (none today)
        e = entry if vfn == fn else entry.split(".")[0] + "." + vfn
        n += 1
        print("%d|%s|%s|%s|%s|%s|%s" % (n, name, e, args, stdin, kind, "gate-row"))
PY

: > "$WORK/results.tsv"
while IFS='|' read -r id name entry args stdin kind label; do
  [ -n "$id" ] || continue
  st="$(cat "$WORK/status/$name" 2>/dev/null || echo MISSING)"
  case "$st" in
    BOTH) ;;
    *) printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$entry" "$args" "$stdin" "$label" "NOT-RUN:$st" >> "$WORK/results.tsv"; continue ;;
  esac
  [ -x "$WORK/bin/$name.val" ] && [ -x "$WORK/bin/$name.word" ] || {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$entry" "$args" "$stdin" "$label" "BUILD-FAIL" >> "$WORK/results.tsv"; continue; }
  # stdin: a `run_io` row names a file under tests/elm-fixtures/input/; every
  # other kind is fed /dev/null so the two arms see the SAME bytes (the gate
  # lets a natrun row inherit stdin, which is not a property of the program).
  if [ "$kind" = run_io ] && [ -n "$stdin" ]; then
    in="$FIX/input/$stdin"
  else
    in=/dev/null
  fi
  # `$args` is UNQUOTED on purpose: the gate itself splats this column.
  ( cd "$ROOT" && timeout "$SECS" "$WORK/bin/$name.val" "$entry" $args < "$in" \
      > "$WORK/runs/$id.val.out" 2> "$WORK/runs/$id.val.err" )
  vrc=$?
  ( cd "$ROOT" && timeout "$SECS" "$WORK/bin/$name.word" "$entry" $args < "$in" \
      > "$WORK/runs/$id.word.out" 2> "$WORK/runs/$id.word.err" )
  wrc=$?
  if [ "$vrc" = 124 ] || [ "$wrc" = 124 ]; then
    res="TIMEOUT val=$vrc word=$wrc"
  elif [ "$vrc" != "$wrc" ]; then
    res="EXIT val=$vrc word=$wrc"
  elif ! cmp -s "$WORK/runs/$id.val.out" "$WORK/runs/$id.word.out"; then
    res="STDOUT"
  else
    res="SAME rc=$vrc bytes=$(wc -c < "$WORK/runs/$id.val.out")"
    # A SIGNAL DEATH IS NOT AGREEMENT (flip-prep, review NICE 2).  rc >= 128 means
    # the process was KILLED (134 SIGABRT, 136 SIGFPE, 139 SIGSEGV), so neither
    # arm produced the program's answer: a shared crash must not be credited as
    # "identical".  It is carried in the result field and the report counts it
    # separately (and fails on it); the comparison itself stays rc+stdout.
    [ "$vrc" -ge 128 ] && res="$res CRASH=$vrc"
  fi
  # STDERR is compared INFORMATIONALLY, never fatally (the arms are allowed
  # different diagnostics — that is a representation difference, not a
  # behaviour one).  It is measured because a row whose only observable is its
  # diagnostic (a halt fixture printing nothing) would otherwise be credited as
  # "identical" on rc alone.
  if cmp -s "$WORK/runs/$id.val.err" "$WORK/runs/$id.word.err"; then
    res="$res err=same"
  else
    res="$res err=DIFFERS"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$entry" "$args" "$stdin" "$label" "$res" >> "$WORK/results.tsv"
done < "$WORK/runplan.tsv"

# ---- phase 3: the table ----------------------------------------------------
python3 - "$WORK" "$SHOW" "$SECS" <<'PY'
import sys, os
from collections import OrderedDict

W, show, secs = sys.argv[1], sys.argv[2], sys.argv[3]

status = {}
for f in os.listdir(os.path.join(W, "status")):
    if f.endswith(".build"):
        continue
    status[f] = open(os.path.join(W, "status", f)).read().strip()

emit_fail = sorted(n for n, s in status.items() if s == "EMIT-FAIL")
if emit_fail:
    print("word-arm-corpusrun: %d group(s) produced NO emit on one arm — the emit "
          "crashed or wrote an empty file, so this run cannot classify them (not a "
          "refusal, an instrument failure): %s" % (len(emit_fail), " ".join(emit_fail)),
          file=sys.stderr)
    sys.exit(2)

rows = []
for line in open(os.path.join(W, "results.tsv"), errors="replace"):
    line = line.rstrip("\n")
    if not line:
        continue
    rid, name, entry, args, stdin, label, res = line.split("\t")
    rows.append(dict(id=int(rid), name=name, entry=entry, args=args,
                     stdin=stdin, label=label, res=res))

both = sorted(n for n, s in status.items() if s == "BOTH")
same_error = sorted(n for n, s in status.items() if s == "SAME-ERROR")
blocked = sorted(n for n, s in status.items() if s in ("WORD-BLOCKED", "VAL-ONLY-ERROR"))
build_fail = sorted(n for n, s in status.items() if s == "BUILD-FAIL")

def base(res):
    # the stderr comparison rides on the same field; it is informational
    return res.split(" err=")[0]

def differing(r):
    # the two arms returned different rc or stdout bytes
    return not r["res"].startswith("SAME")

def crashed(r):
    # both arms died on the SAME signal: rc >= 128 on an arm-equal code
    return "CRASH=" in r["res"]

def bad(r):
    return differing(r) or crashed(r)

ran = sorted({r["name"] for r in rows if r["name"] in both})
not_run = [n for n in both if n not in ran]

groups_ok = [n for n in ran if all(not bad(r) for r in rows if r["name"] == n)]
groups_bad = [n for n in ran if n not in groups_ok and any(differing(r) for r in rows if r["name"] == n)]
groups_crash = [n for n in ran if n not in groups_ok and n not in groups_bad]

print("word-arm corpus run: BOTH 125-group column, RUN on both arms and DIFFED")
print("  groups the census calls BOTH  %3d" % len(both))
nvec = len([r for r in rows if r["name"] in both and r["label"] == "gate-row"])
print("  ... RUN on both arms         %3d  (%d argument vectors, from the gate's own registry)"
      % (len(ran), nvec))
print("  ... IDENTICAL                %3d  (exit code AND stdout bytes)" % len(groups_ok))
print("  ... DIFFERING                %3d" % len(groups_bad))
print("  ... CRASHED on BOTH arms     %3d  group(s) (rc >= 128: a shared SIGNAL"
      " DEATH is counted as a FAILURE, never as agreement)" % len(groups_crash))
print("  SAME-ERROR (not runnable)    %3d  (both arms refuse: not an arm gap)"
      % len(same_error))
print("  WORD-BLOCKED (not runnable)  %3d" % len(blocked))
if build_fail:
    print("  BUILD-FAIL                   %3d" % len(build_fail))
    # ONE LINE PER FAILED GROUP, carrying the reason phase 1 already recorded in
    # $W/status/$name.build (the qbe/cc first line).  A gate that names a group
    # but not a reason costs a whole 22-minute run to diagnose.
    for n in build_fail:
        p = os.path.join(W, "status", n + ".build")
        reason = "no reason recorded"
        if os.path.exists(p):
            reason = open(p, errors="replace").read().strip().split("\n")[0]
        print("    %-26s %s" % (n, reason[:200]))
if not_run:
    print("  BOTH but NOT RUN             %3d  %s" % (len(not_run), " ".join(not_run)))

def first_diff(rid):
    a = os.path.join(W, "runs", "%d.val.out" % rid)
    b = os.path.join(W, "runs", "%d.word.out" % rid)
    A = open(a, "rb").read() if os.path.exists(a) else b""
    B = open(b, "rb").read() if os.path.exists(b) else b""
    n = min(len(A), len(B))
    i = 0
    while i < n and A[i] == B[i]:
        i += 1
    if i == n and len(A) == len(B):
        return "stdout identical"
    return ("first difference at byte %d: val %r vs word %r (val %d B, word %d B)"
            % (i, A[i:i+24], B[i:i+24], len(A), len(B)))

if groups_bad or groups_crash:
    print("\nFAILING GROUPS — the two representations disagree on a program's output,"
          " or both arms died on the same signal (a crash is not an answer)")
    for n in sorted(set(groups_bad) | set(groups_crash)):
        for r in rows:
            if r["name"] != n or not bad(r):
                continue
            print("  %-28s [%s] %s" % (n, r["args"] or "no args", base(r["res"])))
            if crashed(r):
                print("      BOTH ARMS DIED ON A SIGNAL (%s) — a crash is not an"
                      " output, so this is NOT agreement; the word-arm stderr says"
                      " why:" % base(r["res"]).split("CRASH=")[-1])
                err = os.path.join(W, "runs", "%d.word.err" % r["id"])
                if os.path.exists(err):
                    line = open(err, errors="replace").readline().strip()
                    print("      word stderr: " + (line or "<empty>")[:200])
            elif base(r["res"]) == "STDOUT":
                print("      " + first_diff(r["id"]))
            else:
                err = os.path.join(W, "runs", "%d.word.err" % r["id"])
                if os.path.exists(err):
                    line = open(err, errors="replace").readline().strip()
                    if line:
                        print("      word stderr: " + line[:200])

errdiff = [r for r in rows if r["res"].endswith("err=DIFFERS")]
nruns = len([r for r in rows if r["name"] in both])
if not errdiff:
    print("\nSTDERR is byte-identical too, on every one of the %d run(s): the arms"
          " differ in representation only, not in a diagnostic." % nruns)
if errdiff:
    print("\nSTDERR DIFFERS on %d vector(s) — NOT a failure (the two arms may name a"
          " diagnostic differently), but these rows' stdout+rc agreement is the"
          " only behavioural claim being made:" % len(errdiff))
    for r in errdiff:
        print("  %-24s [%s]" % (r["name"], r["args"] or "no args"))
        for arm in ("val", "word"):
            p = os.path.join(W, "runs", "%d.%s.err" % (r["id"], arm))
            if os.path.exists(p):
                line = open(p, errors="replace").readline().strip()
                print("      %-4s %s" % (arm, (line or "<empty>")[:160]))
print("\nPER-GROUP TABLE (group, vectors, exit codes, stdout bytes)")
print("  %-24s %-4s %-8s %s" % ("GROUP", "VECS", "RC", "STDOUT"))
for n in ran:
    rs = [r for r in rows if r["name"] == n]
    if len(rs) == 1:
        r = rs[0]
        tag = "" if r["label"] == "gate-row" else "  (%s)" % r["label"]
        if crashed(r):
            print("  %-24s %-4d %-8s CRASHED on BOTH arms (%s) — NOT identical%s"
                  % (n, 1, base(r["res"]).split()[1].split("=")[1],
                     base(r["res"]).split("CRASH=")[-1], tag))
        elif r["res"].startswith("SAME"):
            rc = base(r["res"]).split()[1].split("=")[1]
            nb = base(r["res"]).split("bytes=")[-1]
            print("  %-24s %-4d %-8s identical, %s B%s" % (n, 1, rc, nb, tag))
        else:
            print("  %-24s %-4d %-8s DIFFERS%s" % (n, 1, base(r["res"]), tag))
    else:
        print("  %-24s %-4d %-8s %s"
              % (n, len(rs),
                 ",".join(sorted({base(r["res"]).split()[1].split("=")[1] for r in rs if r["res"].startswith("SAME")})) or "diff",
                 "identical on every vector" if all(not bad(r) for r in rs) else "DIFFERS on a vector"))

if show == "vectors":
    print("\nEVERY VECTOR")
    for r in rows:
        print("  %-24s %-22s %s" % (r["name"], r["entry"], r["res"]))

sys.exit(1 if (groups_bad or groups_crash or build_fail or not_run) else 0)
PY
exit $?
