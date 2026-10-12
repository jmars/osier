#!/usr/bin/env bash
# elm-corpus-sweep.sh — which of the fetched Elm packages can THIS tree's
# compiler actually take?  Builds the "runnable subset" and, as a by-product,
# a defect leaderboard for the front end.
#
# WHY.  tools/bench/elm-corpus/ is the real-code pool (2765 packages).  For
# measuring anything we need the subset the TREE can compile — and every file
# it cannot compile is either a dialect gap or a DEFECT, which is worth knowing
# in its own right.  MEASURED first probe (2026-10-12): elm-community/list-extra
# PARSES and reaches the CHECKER, failing on a real type error
# (`cannot unify List a with Prelude.Maybe List a` at List/Extra.elm:116).
#
# WHAT IT DOES.  For each package: try up to $FILES_PER_PKG .elm files (largest
# first) as a one-module group with a chosen entry, via
# `QBE_ENTRY=<Mod>.<fn> node run.js <file> <out>`.  A compile error is written
# as an `err ...` payload with exit 0 (the run.js contract) — so the OUTPUT
# TEXT decides, never the exit code.
#
# HONEST LIMITS:
#   * A package is a LIBRARY: the entry is guessed from the module header (the
#     first exposed name), so a compile covers only the graph reachable from it.
#   * Most packages import OTHER packages, which are not on the search path —
#     a missing-module failure is a DEPENDENCY result, not a compilability one,
#     and is bucketed separately (`DEP`) from a real parse/type error (`ERR`).
#   * Only the corpus's own src/ is on the path; the tree's own core-libs
#     (Array/Dict/JsArray/Maybe/Result/Set/Str/Tuple) are what must satisfy the
#     imports.
#
# Usage: tools/bench/elm-corpus-sweep.sh [--limit N] [--jobs N] [--files N] [--out FILE]
# Writes a TSV: package  file  module  entry  status  error

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS="${ELM_CORPUS_DIR:-$ROOT/tools/bench/elm-corpus}"
CDIR="$ROOT/elm-compiler"
LIMIT=""; JOBS="${ELM_SWEEP_JOBS:-10}"; FPK="${ELM_SWEEP_FILES:-5}"; CLOSURE=""
OUT="$CORPUS/SWEEP.tsv"

while [ $# -gt 0 ]; do
    case "$1" in
        --limit) LIMIT="${2:-}"; shift 2 ;;
        --jobs)  JOBS="${2:-}"; shift 2 ;;
        --files) FPK="${2:-}"; shift 2 ;;
        --closure) CLOSURE=1; shift ;;
        --out)   OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "elm-corpus-sweep: unknown option '$1'" >&2; exit 2 ;;
    esac
done

[ -f "$CDIR/compiler.js" ] || { echo "elm-corpus-sweep: run elm-compiler/build.sh first" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "elm-corpus-sweep: node is required" >&2; exit 2; }

# The module index (module -> file) over the WHOLE corpus: most packages fail
# only because they import OTHER packages, which without this are simply not on
# the path.  Built once; used only with --closure.
MODINDEX="$CORPUS/MODINDEX.tsv"
if [ -n "$CLOSURE" ]; then
    if [ ! -s "$MODINDEX" ]; then
        echo "elm-corpus-sweep: building the module index (one pass over the corpus) ..."
        find "$CORPUS" -path '*/src/*' -name '*.elm' -print0 \
          | xargs -0 -P 8 -n 40 awk 'match($0,/^module[ \t]+([A-Za-z0-9_.]+)/,m){print m[1]"\t"FILENAME}' \
          | sort -u > "$MODINDEX" || exit 2
    fi
    echo "elm-corpus-sweep: module index $(wc -l < "$MODINDEX" | tr -d ' ') modules"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/elmsweep.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

ONE="$CORPUS/.sweep-one.sh"
cat > "$ONE" <<'ONE'
#!/usr/bin/env bash
# $1 = package dir; OUT / FPK / CDIR / WORK come from the environment
set -u
pkgdir="$1"; out="$OUT"; fpk="$FPK"; cdir="$CDIR"; work="$WORK"
pkg="$(basename "$pkgdir")"
mapfile -t files < <(find "$pkgdir/src" -name '*.elm' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n "$fpk" | cut -f2)
[ "${#files[@]}" -eq 0 ] && { echo -e "$pkg\t-\t-\t-\tNOSRC\t-" >> "$out"; exit 0; }
attempted=0
for f in "${files[@]}"; do
    mod="$(sed -n 's/^module[[:space:]]\+\([A-Za-z0-9_.]*\).*/\1/p' "$f" | head -1)"
    [ -n "$mod" ] || continue
    # the entry: the first exposed lowercase name, else the first top-level annotation
    if sed -n '/^module/,/^$/p' "$f" | head -5 | grep -q 'exposing (\.\.)'; then
        fn="$(sed -n 's/^\([a-z][A-Za-z0-9_]*\)[[:space:]]*:.*/\1/p' "$f" | head -1)"
    else
        fn="$(sed -n '/^module/,/)/p' "$f" | sed -n 's/^[[:space:]]*\([a-z][A-Za-z0-9_]*\).*/\1/p' | head -1)"
    fi
    [ -n "$fn" ] || continue
    attempted=1
    o="$work/$(echo "$pkg" | tr / _).$$.ssa"
    inputs=("$f")
    if [ -n "${CLOSURE:-}" ] && [ -s "$MODINDEX" ]; then
        declare -A seen idx
        while IFS=$'\t' read -r m pth; do idx["$m"]="$pth"; done < "$MODINDEX"
        q=("$f"); n_in=0
        while [ "${#q[@]}" -gt 0 ] && [ "$n_in" -lt 40 ]; do
            cur="${q[0]}"; q=("${q[@]:1}")
            [ -n "${seen[$cur]:-}" ] && continue
            seen["$cur"]=1
            [ "$cur" != "$f" ] && { inputs+=("$cur"); n_in=$((n_in+1)); }
            while read -r im; do
                rp="${idx[$im]:-}"
                [ -n "$rp" ] && q+=("$rp")
            done < <(sed -n 's/^import[[:space:]]\+\([A-Za-z0-9_.]*\).*/\1/p' "$cur" | sort -u)
        done
    fi
    ( cd "$cdir" && QBE=1 QBE_ENTRY="$mod.$fn" timeout 120 node run.js "${inputs[@]}" "$o" >/dev/null 2>&1 )
    if head -c 3 "$o" 2>/dev/null | grep -q '^err'; then
        msg="$(head -c 160 "$o" | tr '\n\t' '  ')"
        case "$msg" in
            *"unknown name"*|*"cannot find module"*|*"not found"*|*"unknown module"*) st=DEP ;;
            *) st=ERR ;;
        esac
        echo -e "$pkg\t${f##*/}\t$mod\t$fn\t$st\t$msg" >> "$out"
    elif [ -s "$o" ]; then
        echo -e "$pkg\t${f##*/}\t$mod\t$fn\tOK\t-" >> "$out"
        exit 0
    fi
    rm -f "$o"
done
rm -f "$work/$(echo "$pkg" | tr / _).$$.ssa"
# NOENTRY only when NO compile was ever attempted (no module header / no
# exposed name): a TOOL limit, not a compilability result.
[ "$attempted" -eq 0 ] && echo -e "$pkg\t-\t-\t-\tNOENTRY\t-" >> "$out"
exit 0
ONE
chmod +x "$ONE"

: > "$OUT"
ls -d "$CORPUS"/*/ 2>/dev/null | sort > "$WORK/pkgs.txt"
[ -n "$LIMIT" ] && head -n "$LIMIT" "$WORK/pkgs.txt" > "$WORK/pkgs2.txt" && mv "$WORK/pkgs2.txt" "$WORK/pkgs.txt"
n="$(wc -l < "$WORK/pkgs.txt" | tr -d ' ')"
echo "elm-corpus-sweep: $n packages, jobs=$JOBS, up to $FPK file(s) each"
export ONE
export OUT FPK CDIR WORK
xargs -P "$JOBS" -d '\n' -I{} bash -c '"$0" "$1"' "$ONE" {} < "$WORK/pkgs.txt" 2>/dev/null

ok=$(rg -c $'\tOK\t' "$OUT" || echo 0); err=$(rg -c $'\tERR\t' "$OUT" || echo 0)
dep=$(rg -c $'\tDEP\t' "$OUT" || echo 0); ns=$(rg -c $'\tNOSRC\t' "$OUT" || echo 0); ne=$(rg -c $'\tNOENTRY\t' "$OUT" || echo 0)
echo "elm-corpus-sweep: OK=$ok  ERR=$err  DEP=$dep  NOSRC=$ns  NOENTRY=$ne  (of $n packages)"
echo "--- the top parse/type errors (each is a dialect gap or a DEFECT) ---"
awk -F'\t' '$5=="ERR"{print $6}' "$OUT" | sed 's/at [0-9]*:[0-9]*/at L:C/' | sort | uniq -c | sort -rn | head -12
echo "elm-corpus-sweep: $OUT"
