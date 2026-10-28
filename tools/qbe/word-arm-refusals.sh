#!/usr/bin/env bash
# word-arm-refusals.sh — WHAT ACTUALLY BLOCKS THE WORD ARM, MEASURED (perf
# word-arm-frontier).
#
# WHY THIS EXISTS.  Every word-arm unit so far picked its next class from the
# WORKLIST, i.e. from the list of constructs the emitter still refuses — and
# that list is a claim about the arm written at some earlier time.  MEASURED
# (perf word-arm-frontier): its top two entries, `Con` and `MTagEq`, were
# blanket refusals whose stated reasons had gone stale, and admitting them moved
# the arm from 74 to 88 compiling corpus groups without a single emitter change
# for `Con`.  A worklist cannot answer "what is next" — a CENSUS can.
#
# WHAT IT DOES, per group the LANGUAGE GATE registers (the gate's own manifest,
# as tools/osier-corpus-ssa.sh reads it): compile the group through the QBE
# backend TWICE — once on the val arm and once with QBE_VALREP=word — and
# classify the result:
#
#   BOTH            both arms emitted IL                    (not blocked)
#   SAME-ERROR      both arms refused with IDENTICAL text   (not a word-arm
#                   blocker: the group is a compile_error row, or invalid)
#   WORD-BLOCKED    val emitted, word refused               (a real blocker)
#
# The refusal text is then split into one line per (defun, construct) and the
# lines are folded by CONSTRUCT CLASS.  The classifier reports EVERY blocker —
# at DEFUN granularity too, since the word-arm-frontier review's item 1: the
# per-defun walk used to short-circuit on its first refusal, so the group set
# was the union of per-defun FIRST blockers and a group carrying two blockers in
# one defun lost one of them.  MEASURED inside the frontier census itself: it
# promised 15 movable groups for `Con`+`MTagEq` and 14 moved.  The table printed
# is both numbers a ranking needs:
#
#   GROUPS  how many blocked groups carry this class among their blockers
#   ALONE   how many groups this class blocks ON ITS OWN, i.e. how many groups
#           a port of THIS class alone would unblock.  This is the number a
#           unit should be chosen on, and it is the one a first-refusal table
#           cannot produce: 26 groups carry a constructor-tag pattern as their
#           FIRST blocker and 0 of them are blocked by it alone.
#
# NOT A GATE.  It exits 0 whatever it FINDS: a refusal is the arm's current
# state, not a regression.  The gates are qbe-check.sh, the corpus baseline and
# the ladders.  It exits 2 when the INSTRUMENT fails — a group whose emit
# produced no output at all (crashed or empty) cannot be classified, and
# counting it as "both arms emitted" is the same failure as crediting a rung
# that collected zero.
#
# Usage (from the repo root):
#   tools/qbe/word-arm-refusals.sh            # the table
#   tools/qbe/word-arm-refusals.sh --groups   # ... and the group names per class
#   tools/qbe/word-arm-refusals.sh --raw      # ... and every refusal line
#
# Cost: two node emits per group (~0.4-0.9 s each), OSIER_CORPUS_J parallel.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
J="${OSIER_CORPUS_J:-8}"
SHOW=summary
for a in "$@"; do
  case "$a" in
    --groups) SHOW=groups ;;
    --raw)    SHOW=raw ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "word-arm-refusals: node not found" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "word-arm-refusals: jq not found" >&2; exit 2; }
[ -f "$ROOT/osier-compiler/compiler.js" ] || {
  echo "word-arm-refusals: osier-compiler/compiler.js missing (run osier-compiler/build.sh)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/word-arm-refusals.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

MANIFEST="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)" || {
  echo "word-arm-refusals: the gate refused to build its manifest" >&2; exit 2; }
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || {
  echo "word-arm-refusals: no manifest path from the gate" >&2; exit 2; }

# one line per group: <name>|<src...>|<entry>   (the gate can register one
# group twice — `sub` — so the plan has more lines than there are groups; the
# second emit overwrites the first and both are the same group)
jq -r '.groups[] | [(.output | split("/")[-1] | sub("\\.(csexp|ssa)$"; "")),
                   (.sources | join(" ")), .entry] | join("|")' \
  "$MANIFEST" > "$WORK/plan.tsv"
[ -s "$WORK/plan.tsv" ] || { echo "word-arm-refusals: empty plan" >&2; exit 2; }

mkdir -p "$WORK/val" "$WORK/word"
cat > "$WORK/one.sh" <<'EOJ'
#!/usr/bin/env bash
# $1 = "<name>|<src...>|<entry>"  $2 = out dir  $3 = "val" | "word"
IFS='|' read -r name srcs entry <<< "$1"
arm="$3"
envs=()
[ "$arm" = word ] && envs=(QBE_VALREP=word)
( cd "$OSIER_ROOT/osier-compiler" &&
  env "${envs[@]}" QBE=1 QBE_ENTRY="$entry" node run.js $srcs "$2/$name.ssa" ) >/dev/null 2>&1
EOJ
chmod +x "$WORK/one.sh"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s\0' "$line"
done < "$WORK/plan.tsv" | xargs -0 -r -P "$J" -I{} sh -c \
  "OSIER_ROOT='$ROOT' '$WORK/one.sh' \"\$1\" '$WORK/val' val; OSIER_ROOT='$ROOT' '$WORK/one.sh' \"\$1\" '$WORK/word' word" _ {} 

python3 - "$WORK/val" "$WORK/word" "$SHOW" <<'PY'
import sys, os, glob
from collections import Counter, defaultdict

valdir, worddir, show = sys.argv[1], sys.argv[2], sys.argv[3]

PRE = "err qbe: QBE_VALREP=word is NOT IMPLEMENTED (perf VR3b2): the emitter cannot lower "
POST = (" — the word arm stops at its un-ported constructs instead of emitting half-word code "
        "(nothing was emitted). The worklist is beside `wordLayout` in Mid/RtLayout.elm; the "
        "ported/un-ported table is in handoff-perf-vr3b2-result.")

def read(p):
    """The emit's output, or None if the emit produced NOTHING.

    A MISSING OR EMPTY output is an INSTRUMENT FAILURE, not a result: the old
    form returned "" here and is_err("") is False, so a crashed word emit was
    silently counted as BOTH (and a zero-byte .ssa as BOTH too) — the only trace
    was the header's group count.  A rung that collected nothing must not be
    credited as coverage, so this refuses instead.
    """
    try:
        t = open(p, errors="replace").read().strip()
    except FileNotFoundError:
        return None
    return t if t else None

def is_err(t):
    return t.startswith("err")

def refusal_lines(t):
    core = t[len(PRE):] if t.startswith(PRE) else t
    if core.endswith(POST):
        core = core[: -len(POST)]
    return [x.strip() for x in core.split("; ") if x.strip()]

# fold a refusal line onto its construct class: drop the `<Defun>: ` prefix
def cls(line):
    head = line.split(" — ")[0]
    return line.split(": ", 1)[1] if ": " in head else line

# the classifier's own class names, shortened for a table
SHORT = {
    "AREA 3 (HEAP-OBJECT CONSTRUCTION) — a constructor application":
        "Con (constructor application)",
    "AREA 3/5 (HEAP CELLS) — a constructor-tag pattern":
        "MTagEq (constructor-tag pattern)",
    "AREA 5 (FLOATS) — a float literal":
        "float literal (area 5)",
    "AREA 5 (FLOATS) — the primitive `f/`":
        "prim `f/` (area 5)",
    "AREA 2/3 (DESTRUCTURING) — a `let` destructuring pattern":
        "let-destructuring",
}

def short(c):
    for k, v in SHORT.items():
        if c.startswith(k):
            return v
    return c[:110]

# NAMES FROM THE VAL ARM, deliberately: the val arm is the baseline and must
# answer for EVERY group, so a word emit that crashed before writing anything
# still shows up (as a missing word output) instead of dropping out of the
# population — a census whose denominator silently shrinks is the same bug as a
# first-only refusal.
names = sorted({os.path.basename(f)[:-4] for f in glob.glob(os.path.join(valdir, "*.ssa"))})
stray = sorted({os.path.basename(f)[:-4] for f in glob.glob(os.path.join(worddir, "*.ssa"))} - set(names))
both = same = 0
blocked = {}
missing = []
for n in names:
    v = read(os.path.join(valdir, n + ".ssa"))
    w = read(os.path.join(worddir, n + ".ssa"))
    if v is None or w is None:
        # NOT a finding: a crashed or empty emit is the INSTRUMENT failing, and
        # classifying it would credit a group nobody measured.
        missing.append("%s (%s)" % (n, ", ".join(a for a, t in (("val", v), ("word", w)) if t is None)))
        continue
    if not is_err(w):
        both += 1
    elif is_err(v):
        same += 1
        if v != w:
            print("NOTE %s: both arms refused, but the WORD text differs — the word arm's "
                  "refusal is masking the val arm's error" % n)
    else:
        blocked[n] = refusal_lines(w)

for n in stray:
    print("NOTE %s: the WORD arm wrote an .ssa the val arm did not — the arms disagree about "
          "whether this group compiles at all" % n)

if missing:
    print("word-arm-refusals: %d group(s) produced NO output — the emit crashed or wrote an empty file, "
          "so this census cannot classify them (not a refusal, an instrument failure):" % len(missing),
          file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(2)

print("word-arm refusal census over %d corpus groups" % len(names))
print("  BOTH           %3d  (emit IL on both arms)" % both)
print("  SAME-ERROR     %3d  (both arms refuse identically: not a word-arm blocker)" % same)
print("  WORD-BLOCKED   %3d" % len(blocked))
if not blocked:
    print("\nnothing refuses: every corpus group compiles on the word arm")
    sys.exit(0)

groups = defaultdict(list)
defuns = defaultdict(set)
sets = Counter()
for n, lines in blocked.items():
    # ONE entry per (group, class): a group with four `let`-destructuring
    # defuns is ONE group blocked by that class, not four
    cs = frozenset(short(cls(l)) for l in lines)
    sets[tuple(sorted(cs))] += 1
    for l in lines:
        c = short(cls(l))
        if n not in groups[c]:
            groups[c].append(n)
        head = l.split(" — ")[0]
        defuns[c].add(head.split(": ", 1)[0] if ": " in head else "<emit site, unnamed>")

alone = Counter()
for s, k in sets.items():
    if len(s) == 1:
        alone[s[0]] += k

print("\nREFUSAL CLASS -> GROUPS BLOCKED BY IT")
print("  GROUPS  ALONE  CLASS")
for c, k in sorted(groups.items(), key=lambda kv: (-len(kv[1]), -alone[kv[0]])):
    print("  %6d  %5d  %s" % (len(k), alone.get(c, 0), c))

print("\nBLOCKER SETS (a class can only unblock a group whose set is JUST that class)")
for s, k in sets.most_common():
    print("  %3d  %s" % (k, " + ".join(s)))

if show in ("groups", "raw"):
    print("\nGROUPS PER CLASS")
    for c, k in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print("  [%d] %s" % (len(k), c))
        print("      " + " ".join(sorted(groups[c])))
        print("      defuns: " + " ".join(sorted(defuns[c])))

if show == "raw":
    print("\nRAW REFUSAL LINES PER GROUP")
    for n in sorted(blocked):
        print("  " + n)
        for l in blocked[n]:
            print("      " + l)
PY
exit 0
