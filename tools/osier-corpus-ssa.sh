#!/usr/bin/env bash
# osier-corpus-ssa.sh — the QBE-emit corpus byte-identity baseline (P7,
# handoff osier-evidence).  The SUCCESSOR of tools/osier-corpus-baseline.sha256
# (149 CSEXP artifacts, a ZINC-output anchor that dies with the csexp format).
#
# WHAT IT PINS.  For every group the LANGUAGE GATE registers (the gate's own
# manifest, ELM_GATE_MANIFEST_ONLY=1, now carries each group's native ENTRY),
# compile the group's sources through the QBE backend
#
#     QBE_ENTRY=<Mod>.<fn> node run.js <sources...> <out>.ssa
#
# and sha256 the emitted .ssa — or its "err ..." payload: a group that must
# FAIL to compile (the gate's compile_error rows) has its error bytes pinned.  A moved hash is either a bug or
# a DELIBERATE re-freeze (--freeze, with the reason recorded in the commit —
# the 8da6fd7 discipline).
#
# WHY THE .ssa TEXT AND NOT THE NATIVE BINARIES' OUTPUTS.  (a) It is the
# direct analogue of the old anchor: the COMPILER'S OWN OUTPUT BYTES, so
# lowering drift is caught at emit time, independent of qbe/cc and of the
# runtime; (b) the binaries' BEHAVIOUR is already pinned by the gate's
# expected/*.txt on the native rows — pinning it twice would measure the same
# thing once more, not something new; (c) the .ssa is deterministic (the
# qbe-selfhost determinism oracle) and target-neutral.  What this baseline
# CANNOT see that the old one could, stated plainly:
#   * it pins the ENTRY-REACHABLE defun graph per group, not the whole
#     serialized bundle — a change to code unreachable from every group's
#     entry moves nothing (across 149 groups the reachable set is nearly all
#     of it, but "nearly" is the honest word);
#   * it says nothing about any other backend (there is none since P8).
#
# COST: one node process per group (the QBE path re-typechecks the corpus per
# group), MEASURED ~0.4-0.9 s each; -P OSIER_CORPUS_J (default 8) parallel.
#
# Usage (from the repo root):
#   tools/osier-corpus-ssa.sh             # check mode: diff vs the baseline
#   tools/osier-corpus-ssa.sh --freeze    # (re)write tools/osier-corpus-baseline.ssa.sha256
#
# Exit: 0 = byte-identical (or frozen); 1 = DIFFERS (or a compile produced no
# output at all — that is a failure, not a hash); 2 = tooling/prerequisite.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE="$ROOT/tools/osier-corpus-baseline.ssa.sha256"
GATE="$ROOT/tests/elm-fixtures/run-elm-gate.sh"
J="${OSIER_CORPUS_J:-8}"
MODE=check
[ "${1:-}" = "--freeze" ] && MODE=freeze

command -v node >/dev/null 2>&1 || { echo "osier-corpus-ssa: node not found" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "osier-corpus-ssa: jq not found" >&2; exit 2; }
[ -f "$ROOT/elm-compiler/compiler.js" ] || {
  echo "osier-corpus-ssa: elm-compiler/compiler.js missing (run build.sh)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/osier-corpus-ssa.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# ---- the groups + entries, from the GATE's own registry ----
MANIFEST="$(ELM_GATE_MANIFEST_ONLY=1 "$GATE" 2>/dev/null)" || {
  echo "osier-corpus-ssa: the gate refused to build its manifest" >&2; exit 2; }
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || {
  echo "osier-corpus-ssa: no manifest path from the gate" >&2; exit 2; }

# One plan line per group: <name>|<src1 elm> <src2 elm> ...|<entry>
# (the output file the manifest names is IGNORED — every .ssa goes to scratch,
# so nothing can clobber a committed artifact; see the stage-4 lesson).
jq -r '.groups[] | [(.output | split("/")[-1] | sub("\\.(csexp|ssa)$"; "")),
                   (.sources | join(" ")), .entry] | join("|")' \
  "$MANIFEST" > "$WORK/plan.tsv"
[ -s "$WORK/plan.tsv" ] || { echo "osier-corpus-ssa: empty plan" >&2; exit 2; }

# ---- one QBE emit per group, in parallel ----
cat > "$WORK/one.sh" <<'EOJ'
#!/usr/bin/env bash
# $1 = "<name>|<src...>|<entry>" -> $2/<name>.ssa (+ .ssa.log on failure)
IFS='|' read -r name srcs entry <<< "$1"
out="$2/$name.ssa"
if ! ( cd "$OSIER_ROOT/elm-compiler" &&
       QBE=1 QBE_ENTRY="$entry" node run.js $srcs "$out" ) > "$out.log" 2>&1; then
  : # run.js exits 0 on a compile error and writes the payload — a NONZERO
    # exit is the driver failing; the emptiness check below catches both.
fi
# An empty file is a FAILURE, not a hash: hash-of-empty would silently pin
# "the compiler wrote nothing".
[ -s "$out" ] || { echo "osier-corpus-ssa: $name produced NO output (see $out.log)" >&2; exit 1; }
EOJ
chmod +x "$WORK/one.sh"

mkdir -p "$WORK/ssa"
rc=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s\0' "$line"
done < "$WORK/plan.tsv" \
  | OSIER_ROOT="$ROOT" xargs -0 -r -P "$J" -I{} "$WORK/one.sh" "{}" "$WORK/ssa" || rc=1
[ "$rc" -eq 0 ] || { echo "osier-corpus-ssa: one or more groups failed to emit" >&2; exit 1; }

n_emitted="$(ls "$WORK/ssa"/*.ssa | wc -l | tr -d ' ')"

# ---- hash + compare / freeze ----
(cd "$WORK/ssa" && for f in *.ssa; do sha256sum "$f"; done) | sort -k2 > "$WORK/current.sha"

if [ "$MODE" = freeze ]; then
  sort -k2 > "$BASELINE" < "$WORK/current.sha"
  echo "osier-corpus-ssa: FROZE $n_emitted .ssa hashes into $BASELINE"
  echo "  (a later re-freeze is a COMMIT that says why — the 8da6fd7 discipline)"
  exit 0
fi

[ -f "$BASELINE" ] || {
  echo "osier-corpus-ssa: baseline missing: $BASELINE (freeze it first: --freeze)" >&2
  exit 2
}
n_base="$(wc -l < "$BASELINE" | tr -d ' ')"
sort -k2 "$BASELINE" > "$WORK/baseline.sha"
if diff -u "$WORK/baseline.sha" "$WORK/current.sha" > "$WORK/diff"; then
  echo "corpus .ssa: BYTE-IDENTICAL ($n_emitted artifacts = $n_base baseline entries)"
else
  echo "corpus .ssa: DIFFERS ($n_emitted artifacts vs $n_base baseline entries)"
  sed 's/^/    /' "$WORK/diff"
  echo "  a moved hash is a bug or a deliberate change: if deliberate, re-freeze"
  echo "  with tools/osier-corpus-ssa.sh --freeze and say why in the commit."
  exit 1
fi
