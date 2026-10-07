#!/usr/bin/env bash
# qbe-build.sh — build the VENDORED QBE backend (vendor/qbe) with the system C
# compiler.  No network, no dependency beyond cc + make; re-runnable.
#
# vendor/qbe is byte-identical upstream QBE, pinned (see THIRD-PARTY.md for the
# commit and its verification).  This script never patches it -- it only drives
# upstream's own POSIX Makefile, in-tree:
#
#   make -C vendor/qbe qbe
#
# Cost: 24 C translation units, ~3 s wall at -j32 on this host (x86_64);
# the build emits all three backends (amd64/arm64/rv64) into one binary, which
# selects its default target from config.h, generated at build time from `uname`.
#
# Outputs (all inside vendor/qbe, so a build leaves `git status` clean --
# upstream's own vendor/qbe/.gitignore covers every one of them):
#   vendor/qbe/qbe         the backend binary  (the only product)
#   vendor/qbe/config.h    default-target header, derived from `uname -m`
#   vendor/qbe/*.o vendor/qbe/*/*.o   objects
# `make -C vendor/qbe clean-gen` removes all of the above.
#
# Usage: tools/qbe-build.sh
# Exit:  0 built; 2 tooling or artifact failure.
#
# Env:
#   CC     C compiler (default: cc)
#   CFLAGS override upstream's "-std=c99 -g -Wall -Wextra -Wpedantic" (must
#          still be C99: QBE uses designated initializers)
#   JOBS   make parallelism (default: nproc)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/qbe"
CC="${CC:-cc}"

[ -f "$SRC/Makefile" ] || { echo "qbe-build: $SRC/Makefile missing (vendored tree?)" >&2; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "qbe-build: C compiler '$CC' not found" >&2; exit 2; }
command -v make >/dev/null 2>&1 || { echo "qbe-build: make not found" >&2; exit 2; }

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
MAKEARGS=(CC="$CC")
[ -n "${CFLAGS:-}" ] && MAKEARGS+=(CFLAGS="$CFLAGS")

# clean-gen first: makes the script re-runnable, and drops a config.h left by a
# build on a different machine (its content is `uname`-derived, not portable).
make -C "$SRC" clean-gen >/dev/null
make -C "$SRC" -j"$JOBS" "${MAKEARGS[@]}" qbe

BIN="$SRC/qbe"
[ -x "$BIN" ] || { echo "qbe-build: build produced no executable at $BIN" >&2; exit 2; }

printf 'qbe-build: %s (%s bytes, %s)\n' \
  "$BIN" "$(stat -c %s "$BIN")" \
  "$(printf '%s' "$("$BIN" -h 2>&1 | head -1)")"
