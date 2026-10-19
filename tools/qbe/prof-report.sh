#!/usr/bin/env bash
# prof-report.sh — resolve a tools/qbe/prof.c dump into a ranked symbol table.
#
#   tools/qbe/prof-report.sh <binary> <dump-file> [top-N]
#
# The dump (QBE_PROF=1 build) carries three sections:
#
#   # qbe-prof v1 hz=1000 ring=... samples=<kept> dropped=<overwritten>
#   # maps
#   <start>-<end> perms offset dev inode path      (executable mappings only)
#   # pcs
#   0x<addr> <count>
#
# WHY THE MAPS SECTION IS IN THE DUMP: the artifact is dynamically linked
# (-lc), so a sample can land in libc, and the artifact itself is PIE — a raw
# runtime PC is meaningless without the load bias.  The dump therefore records
# /proc/self/maps at exit, and this script subtracts each image's bias
# (start - file offset) before looking the PC up in that image's own `nm`.
#
# Resolution is by NEAREST PRECEDING SYMBOL inside its image — no DWARF (QBE
# emits real symbols: `q_<Mod>.<fn>` for Mid defuns, `q_Rt.<fn>` for the
# runtime surface, plain C/Zig names for the rest; the `_x2e` escapes are
# demangled for display).  Consequences to keep in mind when reading the
# table:
#   * a symbol that is not in `nm --defined-only` (a PLT stub's target inside
#     a stripped lib, a JIT region) lands in that image's `(unresolved)` row;
#   * a PC in a gap between two symbols is attributed to the preceding one
#     only up to the next symbol's address, and to `(gap)` in between;
#   * inlined code is attributed to its enclosing symbol, by construction.
#
# Usage: prof-report.sh <binary> <dump-file> [top-N]     (top-N default 25)
# Exit: 0 report printed; 2 a missing input / unreadable dump.
set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: prof-report.sh <binary> <dump-file> [top-N]" >&2; exit 2; }
BIN="$1"; DUMP="$2"; TOP="${3:-25}"
[ -f "$BIN" ]  || { echo "prof-report: no binary: $BIN" >&2; exit 2; }
[ -f "$DUMP" ] || { echo "prof-report: no dump: $DUMP" >&2; exit 2; }
command -v nm >/dev/null 2>&1 || { echo "prof-report: nm not found" >&2; exit 2; }
grep -q '^# pcs' "$DUMP" || { echo "prof-report: $DUMP is not a qbe-prof dump (no '# pcs')" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prof-report.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---- split the dump --------------------------------------------------------
awk -v maps="$TMP/maps" -v pcs="$TMP/pcs" '
  /^# qbe-prof/ { print > maps; next }
  /^# maps/     { sec = "maps"; next }
  /^# pcs/      { sec = "pcs";  next }
  /^#/          { next }
  sec == "maps" { print > maps; next }
  sec == "pcs"  { print > pcs;  next }
' "$DUMP"

HDR="$(grep '^# qbe-prof' "$DUMP" || true)"
SAMPLES="$(printf '%s\n' "$HDR" | sed -n 's/.*samples=\([0-9]*\).*/\1/p')"
DROPPED="$(printf '%s\n' "$HDR" | sed -n 's/.*dropped=\([0-9]*\).*/\1/p')"
HZ="$(printf '%s\n' "$HDR" | sed -n 's/.*hz=\([0-9]*\).*/\1/p')"

# ---- one symbol table per IMAGE, in absolute runtime addresses -------------
# An image = one executable mapping path; its bias is start - file offset
# (works for PIE and non-PIE alike, and for each shared library separately).
: > "$TMP/syms.abs"
awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) { print $i; break } }' \
    "$TMP/maps" | sort -u > "$TMP/paths"

while IFS= read -r path; do
  [ -f "$path" ] || continue
  # The FIRST executable mapping of this path gives the bias and the end of
  # the image's executable range.
  read -r base end < <(awk -v p="$path" '
    $NF == p && $2 ~ /x/ {
      # start-end perms offset ...
      n = split($1, r, "-"); start = strtonum("0x" r[1]); stop = strtonum("0x" r[2])
      off = strtonum("0x" $3)
      printf "%d %d\n", start - off, stop
      exit
    }' "$TMP/maps")
  [ -n "${base:-}" ] || continue
  # Static symtab first; a shared library has none, so fall back to -D.
  # (NOT `nm ... | grep -q .`: with pipefail, grep -q exits early, awk takes
  # SIGPIPE and the pipeline reads as FAILED -- which silently sent the main
  # binary down the -D branch, whose table is empty, and every sample then
  # resolved to nothing.)
  nm -n --defined-only "$path" 2>/dev/null > "$TMP/nm.raw" || true
  if ! awk '$2 ~ /^[TtWwiI]$/ { f = 1 } END { exit !f }' "$TMP/nm.raw"; then
    nm -D -n --defined-only "$path" 2>/dev/null > "$TMP/nm.raw" || true
  fi
  awk -v base="$base" -v end="$end" -v path="$path" '
    $2 ~ /^[TtWwiI]$/ && $1 ~ /^[0-9a-f]+$/ {
      printf "%.0f %s\n", base + strtonum("0x" $1), $3
    }
    END { printf "%.0f %s\n", end, "[" path " (gap)]" }
  ' "$TMP/nm.raw" >> "$TMP/syms.abs"
done < "$TMP/paths"

sort -k1,1 -g "$TMP/syms.abs" > "$TMP/syms.ord"

# ---- merge (both sides sorted by address) ---------------------------------
# A sample belongs to the greatest symbol address <= pc, but only while pc is
# still inside that symbol's image range; the per-image "(gap)" sentinel
# closes each image, so a pc past it falls to the next image's symbols.
sort -k1,1 -g "$TMP/pcs" > "$TMP/pcs.ord"
awk -v top="$TOP" '
  NR == FNR { nr++; sa[nr] = $1 + 0; sn[nr] = $2; next }
  {
    # strtonum, not `$1 + 0`: awk does NOT parse a "0x..." STRING as hex, it
    # yields 0, and every sample then resolved to "below every known symbol".
    pc = strtonum($1); c = $2 + 0
    while (i + 1 <= nr && sa[i + 1] <= pc) i++
    if (i == 0) { label = "?? (below every known symbol)" }
    else {
      label = sn[i]
      # past the last symbol of an image but before the next image first symbol
      next_a = (i + 1 <= nr) ? sa[i + 1] : pc + 1
      if (pc >= next_a) label = "?? (outside every image)"
    }
    tot += c; agg[label] += c
  }
  function hex(h,  i, v) {
    v = 0
    for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
    return v
  }
  function demangle(s,  out, i) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      if (substr(s, i, 2) == "_x" && substr(s, i + 2, 2) ~ /^[0-9a-f][0-9a-f]$/) {
        out = out sprintf("%c", hex(substr(s, i + 2, 2))); i += 3
      } else out = out substr(s, i, 1)
    }
    return out
  }
  END {
    for (l in agg) { lab[++k] = demangle(l); cnt[k] = agg[l] }
    # rank: largest count first, name as the tiebreak (stable, reproducible)
    for (x = 2; x <= k; x++) {
      cl = lab[x]; cc = cnt[x]; y = x - 1
      while (y > 0 && (cnt[y] < cc || (cnt[y] == cc && lab[y] > cl))) {
        lab[y + 1] = lab[y]; cnt[y + 1] = cnt[y]; y--
      }
      lab[y + 1] = cl; cnt[y + 1] = cc
    }
    printf "%9s %9s %9s  %s\n", "count", "%", "cum%", "symbol"
    cum = 0
    for (x = 1; x <= k; x++) {
      if (top > 0 && x > top) { rest += cnt[x]; continue }
      cum += cnt[x]
      printf "%9d %8.2f%% %8.2f%%  %s\n", cnt[x], 100 * cnt[x] / tot, 100 * cum / tot, lab[x]
    }
    if (top > 0 && k > top)
      printf "%9d %8.2f%% %8s  (%d more symbols, not shown)\n", \
        rest, 100 * rest / tot, "", k - top
    printf "%9d %8s %8s  TOTAL samples\n", tot, "100.00%", ""
  }
' "$TMP/syms.ord" "$TMP/pcs.ord" > "$TMP/table"

{
  printf 'prof-report: %s\n' "$BIN"
  printf 'prof-report: dump %s\n' "$DUMP"
  printf 'prof-report: hz=%s samples=%s' "${HZ:-?}" "${SAMPLES:-?}"
  if [ "${DROPPED:-0}" != 0 ]; then
    printf ' dropped=%s (THE RING WRAPPED: this profile is the LAST %s samples, not the whole run)' \
      "$DROPPED" "$SAMPLES"
  else
    printf ' dropped=0 (the whole run is in the profile)'
  fi
  printf '\n'
  printf 'prof-report: NOTE ITIMER_PROF counts CPU time (user+sys); the percentages are\n'
  printf 'prof-report:   of CPU, so blocking I/O time is NOT in them. Compare with the\n'
  printf 'prof-report:   run'"'"'s wall clock before concluding anything about I/O.\n'
  cat "$TMP/table"
} | sed '1d'  # the awk banner line is scratch
