#!/usr/bin/env bash
# withe-recount-runTask.sh — reproduce the G5 "16 of 20" interpreter-branch count.
#
# Gap G5 established that the paper's "29 of 30 branches check honestly" is
# WRONG.  Removing `Runtime.runTask` from the trusted set reports exactly ONE
# error (TaskExec) and stops — that fail-fast behaviour is how the 29/30 figure
# was born.  Masking each failure to reveal the next shows FOUR branches fail,
# so the honest figure is 16 of 20.  This script makes that recount a
# REPRODUCIBLE measurement rather than a single-source claim.
#
# withe-split Phase 3 note: the 10 UI effects left the Task type, so the count
# is now 20 branches (was 30) and 4 of them fail (was 5) — TaskGuiPoll, the
# old fifth failure, left with the UI.
#
# METHOD — temp-copy bisection (the working tree is NEVER edited):
#   1. copy elm-compiler/ to a scratch dir (mktemp);
#   2. in the COPY: remove `Runtime.runTask` from trustedBodies
#      (Type/Builtins.elm — compiled into compiler.js) and add the
#      `type x a.` binder to runTask's signature (Runtime.elm — read from disk
#      by run.js at compile time, so Runtime.elm masks need NO recompile);
#   3. rebuild compiler.js ONCE, then compile a trivial fixture and read the
#      oracle (the OUTPUT FILE, never the exit code — run.js always exits 0);
#   4. in source order, mask each revealed failure and re-run, recording the
#      next error, until all four are named and the trivial fixture then
#      compiles CLEAN (proof that no fifth branch fails).
#
# HONEST CONDITION — the measurement is taken UNDER a `type x a.` binder:
#   the COMMITTED signature is `runTask : Task x a -> Result x a` (no binder).
#   The branch-local result discharge the paper is measuring only exists when
#   the result index `a` is RIGID (the `type x a.` binder skolemizes it);
#   without the binder `a` is flexible and the first `Ok ()` branch fixes it
#   globally, so the per-branch refinement the paper claims is not what is
#   being exercised.  The count below is therefore the count UNDER that
#   binder — a number whose precondition is stated, not hidden.
#
# MASKS ARE ISOLATION DEVICES, NOT FIXES.  They are applied only to the
# scratch copy so the NEXT failure becomes visible:
#   TaskExec    body -> `Ok (0, "", "")`            (the ctor's own result type)
#   TaskNow     body -> `Ok (getpidPrim ())`        (an Int, so `a ~ Int` fires)
#   TaskQuit    ctor  -> `| TaskQuit : Task x ()`   (the "obvious" annotation)
#   TaskStat    ctor/body/wrapper -> `Task x ()`    (record -> unit: the
#               record-discharge over-approximation cannot be discharged, so
#               the result type is temporarily made non-record)
#
# USAGE (from the repo root):
#   tools/withe-recount-runTask.sh
#
# Prerequisite on PATH / env (same as tools/withe-numbers.sh):
#   ELM_BIN      elm 0.19.2 binary
#                (default ~/.npm-global/lib/node_modules/elm/bin/elm)
#
# Exit code 0 iff the measurement is reproduced exactly (every step's error
# matches the recorded expectation).  Any drift in the source or the checker's
# messages makes the script FAIL LOUDLY rather than print a stale number.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ELM_BIN="${ELM_BIN:-$HOME/.npm-global/lib/node_modules/elm/bin/elm}"
CDIR="$ROOT/elm-compiler"

# Name every missing tool HERE: without node/python3 the measurement dies inside
# the python block below with a FileNotFoundError traceback.
for t in node python3; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "FAIL: $t is required and was not found on PATH." >&2
        exit 2
    }
done

if [ ! -x "$ELM_BIN" ]; then
    cat >&2 <<EOF
FAIL: the elm 0.19.2 binary was not found.
      ELM_BIN=$ELM_BIN
      elm 0.19.2 is NOT on PATH in the paper's build host — set ELM_BIN to your
      elm binary, e.g. ELM_BIN="\$(npm root -g)/elm/bin/elm"
      (the default is \$HOME/.npm-global/lib/node_modules/elm/bin/elm)
EOF
    exit 2
fi
if [ ! -f "$CDIR/src/Runtime.elm" ] || [ ! -f "$CDIR/src/Type/Builtins.elm" ]; then
    echo "FAIL: elm-compiler sources not found under $CDIR" >&2
    exit 2
fi

note() { printf '%-28s %s\n' "$1:" "$2"; }

# Working-tree byte-identity: snapshot the two files the measurement EDITS IN
# THE COPY (never in place) so we can PROVE they are untouched afterwards.
h_builtins="$(sha256sum "$CDIR/src/Type/Builtins.elm" | cut -d' ' -f1)"
h_runtime="$(sha256sum "$CDIR/src/Runtime.elm" | cut -d' ' -f1)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cp -r "$CDIR" "$SCRATCH/elm-compiler"
rm -rf "$SCRATCH/elm-compiler/elm-stuff"   # force a clean dependency build (no stale .elmi)
S="$SCRATCH/elm-compiler"
printf 'module Main exposing (main)\nmain : Int\nmain = 1\n' > "$SCRATCH/trivial.elm"

HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')"

export S ELM_BIN TRIVIAL="$SCRATCH/trivial.elm" HEAD

python3 - "$S" <<'PY'
import os, re, subprocess, sys

S     = os.environ['S']
ELM   = os.environ['ELM_BIN']
TRIV  = os.environ['TRIVIAL']
HEAD  = os.environ.get('HEAD', 'no-git')

# --------------------------------------------------------------------------
# The exact edits, tied to THIS tree's source text.  `edit` fails loudly if a
# replacement is not found exactly once (the measurement is not valid on a
# drifted tree).
# --------------------------------------------------------------------------
BASE = [
    ("src/Type/Builtins.elm", '    , "Runtime.runTask"\n', ''),
    ("src/Runtime.elm", "runTask : Task x a -> Result x a\n",
     "runTask : type x a. Task x a -> Result x a\n"),
]

# Each mask: (branch being masked, [(relpath, old, new), ...]).
MASKS = [
    ("TaskExec", [
        ("src/Runtime.elm",
"""        TaskExec plan ->
            Ok (decodeExec (execPlanPrim plan))
""",
"""        TaskExec plan ->
            Ok (0, "", "")
"""),
    ]),
    ("TaskNow", [
        ("src/Runtime.elm",
"""        TaskNow ->
            Ok 0
""",
"""        TaskNow ->
            Ok (getpidPrim ())
"""),
    ]),
    ("TaskQuit", [
        ("src/Runtime.elm", "    | TaskQuit\n", "    | TaskQuit : Task x ()\n"),
    ]),
    ("TaskStat", [
        ("src/Runtime.elm",
"    | TaskStat String : Task x { size : Int, mode : Int, mtimeMs : Int, isDir : Bool, isFile : Bool }\n",
"    | TaskStat String : Task x ()\n"),
        ("src/Runtime.elm",
"""        TaskStat _ ->
            Ok { size = 0, mode = 0, mtimeMs = 0, isDir = False, isFile = False }
""",
"""        TaskStat _ ->
            Ok ()
"""),
        ("src/Runtime.elm",
"taskStat : String -> Task x { size : Int, mode : Int, mtimeMs : Int, isDir : Bool, isFile : Bool }\n",
"taskStat : String -> Task x ()\n"),
    ]),
]

# What each successive mask REVEALS, in order:
#   (line, distinctive substring, branch name, classification).  The 4th entry
#   is the TERMINAL check: after masking all four, the trivial fixture compiles
#   CLEAN (no "err " prefix) — proof that no fifth branch fails.
REVEAL = [
    (179, "number with a",              "TaskNow",  "DEFECT: number literal FlexConflict"),
    (185, "cannot be unified with ()",  "TaskQuit", "DESIGN: un-annotated nullary ctor"),
    (195, "escaping row equation",      "TaskStat", "OVER-APPROX: closed-record discharge"),
    (None, None,                        "CLEAN",    "no further runTask branch fails"),
]

def edit(pairs):
    for rel, old, new in pairs:
        p = os.path.join(S, rel)
        s = open(p).read()
        n = s.count(old)
        if n != 1:
            print(f"EDIT MISMATCH: {n} occurrence(s) of {old[:70]!r} in {rel}", file=sys.stderr)
            sys.exit(2)
        open(p, 'w').write(s.replace(old, new))

def elm_make():
    env = dict(os.environ)
    env["ELM_HOME"] = os.path.join(S, ".elm-cache")
    r = subprocess.run([ELM, "make", "src/Main.elm", "--output=compiler.js"],
                       cwd=S, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print("FAIL: elm make in scratch", file=sys.stderr)
        print((r.stdout + r.stderr)[-2000:], file=sys.stderr)
        sys.exit(1)

def compile_check():
    out = os.path.join(os.path.dirname(TRIV), "out.csexp")
    # run.js ALWAYS exits 0 and writes the verdict into the output file.
    subprocess.run(["node", os.path.join(S, "run.js"), TRIV, out],
                   capture_output=True, text=True)
    return open(out).read().strip()

def errline(err):
    m = re.search(r"at (\d+):\d+", err)
    return int(m.group(1)) if m else None

# --- branch census (from the COMMITTED tree, via the unedited scratch copy) --
orig = open(os.path.join(S, "src", "Runtime.elm")).read()
branches = re.findall(r"^\s{8}(Task\w+)\b[^\n]*->\s*$", orig, re.M)
fail = 0

print(f"withe-recount-runTask @ {HEAD}")
print()
print("CONDITION (honest): runTask is UNTRUSTED (removed from trustedBodies) and")
print("  its body is checked under a `type x a.` binder.  The committed signature")
print("  has NO binder; the binder is what the branch-local discharge the paper")
print("  measures requires (a rigid result index).  This count is UNDER that binder.")
print()
print(f"runTask branches: {len(branches)} total")
print()

# --- base: untrusted + binder, no masks --------------------------------------
edit(BASE)
elm_make()

err = compile_check()
line = errline(err)
print("fail-fast (untrusted, no masks):")
print(f"    {err}")
if err.startswith("err ") and line == 156 and "List a" in err:
    print('    -> exactly ONE error (TaskExec) — this is how "29 of 30" was born')
    print('    class: TaskExec = DEFECT: existential cast a ~ List a')
else:
    print("    ^^^ expected the TaskExec error (156:29); measurement FAILED")
    fail = 1
print()

# --- bisection ---------------------------------------------------------------
print("bisection (mask each failure to reveal the next):")
for i, (name, pairs) in enumerate(MASKS):
    edit(pairs)
    err = compile_check()
    line = errline(err)
    eline, esub, elabel, ewhy = REVEAL[i]

    if i < 3:
        ok = err.startswith("err ") and line == eline and esub in err
        if not ok:
            fail = 1
        print(f"  [{i+1}] mask {name:12s} -> reveals {elabel}")
        print(f"        {err}")
        print(f"        {'OK ' if ok else 'MISMATCH'}: expected line {eline} ({elabel})")
        print(f"        class: {ewhy}")
    else:
        # After masking all four, the trivial fixture must compile CLEAN —
        # no runTask branch error remains (proof that no fifth branch fails).
        ok = not err.startswith("err ")
        if not ok:
            fail = 1
        print(f"  [{i+1}] mask {name:12s} -> no runTask branch error remains")
        print(f"        {err[:60]}{'...' if len(err) > 60 else ''}")
        print(f"        {'OK ' if ok else 'MISMATCH'}: {ewhy}")
print()

# --- verdict -----------------------------------------------------------------
if fail == 0:
    print("RESULT: 16 of 20 branches check honestly; 4 fail —")
    print("  1 existential cast (TaskExec)")
    print("  1 number literal FlexConflict (TaskNow)")
    print("  1 deliberate generalization (TaskQuit)")
    print("  1 record-discharge over-approximation (TaskStat)")
    print()
    print("VERDICT: count reproduced (16/20 under the `type x a.` binder)")
else:
    print("VERDICT: measurement drifted — re-measure before citing")
sys.exit(fail)
PY
py_rc=$?

# --- prove the working tree is byte-identical --------------------------------
h2_builtins="$(sha256sum "$CDIR/src/Type/Builtins.elm" | cut -d' ' -f1)"
h2_runtime="$(sha256sum "$CDIR/src/Runtime.elm" | cut -d' ' -f1)"
if [ "$h_builtins" = "$h2_builtins" ] && [ "$h_runtime" = "$h2_runtime" ]; then
    note "working tree" "byte-identical (Builtins.elm + Runtime.elm sha256 unchanged)"
else
    note "working tree" "CHANGED — FAIL"
    py_rc=1
fi

exit "$py_rc"
