#!/usr/bin/env bash
# fetch-elm-corpus.sh — fetch the WHOLE published Elm package registry as a
# source corpus, for measuring proposed optimizations on REAL code.
#
# WHY.  Every optimization verdict in this tree so far was judged on two
# samples that do not generalise: the compiler's OWN 149-group corpus (which
# plan.md §1.3 says outright "generalises poorly to general code") and a
# 12-program hand-built suite.  MEASURED 2026-10-12 on the question "how often
# does a prim operand need an expression type rather than a binder type?":
# the suite says 5 sites; real published Elm (elm/core + elm/json, comments
# stripped, syntactic census) says ~40% of top-level operator sites.  A verdict
# drawn from the corpus can therefore be wrong in the direction that matters.
# This script is the instrument that stops that.
#
# WHAT IT DOES.  Reads https://package.elm-lang.org/all-packages (the registry
# the elm compiler itself uses), and for every package fetches its LATEST
# version's source from GitHub, keeping ONLY `src/**/*.elm` + LICENSE.
#
# THE SOURCES ARE NOT COMMITTED (third-party code): the corpus dir is
# gitignored; this script and MANIFEST.tsv are the committed record, so the
# corpus is reproducible without vendoring anyone's code.
#
# HONEST LIMITS, stated because they bound what the corpus can prove:
#   * `owner/name` on the registry is USUALLY `github.com/owner/name`, not
#     always — a renamed or deleted repo 404s.  MEASURED on a 40-package
#     sample: 37 hit / 3 miss (92%).  Misses are recorded, not hidden.
#   * A package is a LIBRARY, not a program: this is a SOURCE corpus for static
#     shape censuses and for building runnable benchmarks on top, not a suite.
#   * Most packages that use `Elm.Kernel.*` are not compilable by this tree's
#     front end as-is.  The manifest records a kernel count so the pure-Elm
#     subset can be selected rather than assumed.
#
# Usage: tools/bench/fetch-elm-corpus.sh [--limit N] [--jobs N] [--registry FILE]
# Exit: 0 = finished (misses are reported; use the manifest for the count).

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${ELM_CORPUS_DIR:-$ROOT/tools/bench/elm-corpus}"
JOBS="${ELM_CORPUS_JOBS:-8}"
LIMIT=""
REG="${ELM_CORPUS_REGISTRY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --limit) LIMIT="${2:-}"; shift 2 ;;
        --jobs)  JOBS="${2:-}";  shift 2 ;;
        --registry) REG="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "fetch-elm-corpus: unknown option '$1'" >&2; exit 2 ;;
    esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "fetch-elm-corpus: $1 is required" >&2; exit 2; }; }
need curl; need tar; need jq

# ---- the registry ----------------------------------------------------------
if [ -z "$REG" ]; then
    REG="$DEST/.all-packages.json"
    if [ ! -s "$REG" ]; then
        mkdir -p "$DEST"
        curl -sS -m 60 -o "$REG.tmp" https://package.elm-lang.org/all-packages \
            || { echo "fetch-elm-corpus: registry fetch failed" >&2; exit 2; }
        mv "$REG.tmp" "$REG"
    fi
fi
[ -s "$REG" ] || { echo "fetch-elm-corpus: registry missing: $REG" >&2; exit 2; }

# pkg<TAB>latest-version  (the registry lists versions oldest-first)
PLAN="$(jq -r 'to_entries[] | "\(.key)\t\(.value[-1])"' "$REG" | sort)"
[ -n "$LIMIT" ] && PLAN="$(printf '%s\n' "$PLAN" | head -n "$LIMIT")"
echo "fetch-elm-corpus: $(printf '%s\n' "$PLAN" | wc -l | tr -d ' ') packages, jobs=$JOBS, dest=$DEST"

mkdir -p "$DEST"
FETCH="$DEST/.fetch-one.sh"
cat > "$FETCH" <<'ONE'
#!/usr/bin/env bash
# $1 = pkg (owner/name)   $2 = version   $3 = dest root
set -u
pkg="$1"; ver="$2"; dest="$3"
owner="${pkg%%/*}"; name="${pkg##*/}"
slug="${owner}__${name}"
out="$dest/$slug"
if [ -d "$out" ] && [ -f "$out/.ok" ]; then echo -e "$pkg\t$ver\tCACHED\t$slug"; exit 0; fi
tgz="$(mktemp /tmp/elmcorpus.XXXXXX.tgz)"
for tag in "$ver" "v$ver"; do
    if curl -sSL -m 90 -f -o "$tgz" "https://github.com/$owner/$name/archive/refs/tags/$tag.tar.gz" 2>/dev/null; then break; fi
done
if [ ! -s "$tgz" ]; then rm -f "$tgz"; echo -e "$pkg\t$ver\tMISS\t$slug"; exit 0; fi
stage="$(mktemp -d /tmp/elmcorpus.XXXXXX)"
tar xzf "$tgz" -C "$stage" 2>/dev/null
rm -f "$tgz"
inner="$(find "$stage" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [ -z "$inner" ] || [ ! -d "$inner/src" ]; then rm -rf "$stage"; echo -e "$pkg\t$ver\tNO_SRC\t$slug"; exit 0; fi
mkdir -p "$out/src"
# keep only the .elm sources (nested paths preserved) + the licence if present
(cd "$inner" && find src -name '*.elm' -print0 | tar cf - --null -T - 2>/dev/null) | tar xf - -C "$out" 2>/dev/null
for l in LICENSE LICENSE.md license; do [ -f "$inner/$l" ] && cp "$inner/$l" "$out/" && break; done
n=$(find "$out/src" -name '*.elm' | wc -l | tr -d ' ')
loc=$(find "$out/src" -name '*.elm' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
kern=$(rg -l 'Elm\.Kernel' "$out/src" 2>/dev/null | wc -l | tr -d ' ')
shas=$(cd "$out" && find src -name '*.elm' -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-16)
rm -rf "$stage"
touch "$out/.ok"
echo -e "$pkg\t$ver\tOK\t$slug\t$n\t$loc\t$kern\t$shas"
ONE
chmod +x "$FETCH"

printf 'package\tversion\tstatus\tslug\tfiles\tloc\tkernel_files\tsrc_sha\n' > "$DEST/MANIFEST.tsv"
printf '%s\n' "$PLAN" | awk -F'\t' '{print $1"\t"$2}' \
    | xargs -P "$JOBS" -d '\n' -I{} bash -c 'IFS=$'"'"'\t'"'"' read -r p v <<< "{}"; "'"$FETCH"'" "$p" "$v" "'"$DEST"'"' \
    >> "$DEST/MANIFEST.tsv"

# ---- the summary (the point of the run) ------------------------------------
tot=$(($(wc -l < "$DEST/MANIFEST.tsv") - 1))
ok=$(rg -c $'\tOK\t' "$DEST/MANIFEST.tsv" || echo 0)
miss=$(rg -c $'\tMISS\t' "$DEST/MANIFEST.tsv" || echo 0)
nosrc=$(rg -c $'\tNO_SRC\t' "$DEST/MANIFEST.tsv" || echo 0)
files=$(awk -F'\t' '$3=="OK"||$3=="CACHED" {s+=$5} END {print s+0}' "$DEST/MANIFEST.tsv")
loc=$(awk -F'\t' '$3=="OK"||$3=="CACHED" {s+=$6} END {print s+0}' "$DEST/MANIFEST.tsv")
kern=$(awk -F'\t' '$3=="OK"||$3=="CACHED" {s+=$7} END {print s+0}' "$DEST/MANIFEST.tsv")
echo "fetch-elm-corpus: $ok fetched, $miss unresolved (repo renamed/deleted), $nosrc without src/ — of $tot"
echo "fetch-elm-corpus: $files .elm files, $loc lines; $kern files import Elm.Kernel (not compilable here as-is)"
echo "fetch-elm-corpus: manifest $DEST/MANIFEST.tsv"
