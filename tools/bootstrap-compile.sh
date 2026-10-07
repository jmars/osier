#!/usr/bin/env bash
# bootstrap-compile.sh — compile Elm with NOTHING BUT THE VM.
#
#   bootstrap-compile.sh <input1.elm> [input2.elm ...] <output.csexp>
#   bootstrap-compile.sh <manifest>          (line format: source paths one per
#                                             line, each group terminated by
#                                             "-> <out.csexp>")
#
# NO elm, NO node, NO AOT build.  The compiler here is the committed csexp
# BUNDLE tools/bootstrap/selfhost.csexp — the compiler's own 58 sources,
# compiled by the stock path (elm make + node run.js) — run INTERPRETED by the
# ZINC VM (zig-out/bin/elmvm).  That bundle is the self-hosting FIXED POINT:
# running it on the VM over its own sources reproduces these exact bytes, which
# is what makes it safe to trust a committed binary (tools/bootstrap/
# PROVENANCE.md).  Nothing in a fresh clone can otherwise produce a compiler.
#
# The args after the bundle are NativeMain.main's, verbatim:
#
#   elmvm tools/bootstrap/selfhost.csexp NativeMain.main <in.elm>... <out.csexp>
#
# so this script is a thin env-setting wrapper (cf. tools/elmc.sh, which does
# the same for the AOT binary).
#
# MEASURED COST (this host, 2026-10-07, `zig build elmvm` already cached):
#   one gate fixture                        ~52 s
#   the whole compiler (58 sources, 808 s)  ~13.5 min
# The per-fixture number does NOT scale down with the fixture: Lower.Module
# .compileBatch parses, type-checks and lowers the fixed corpus ONCE per
# process, and the corpus pass dominates.  Compiling N groups in ONE manifest
# pays it once — prefer one manifest over N invocations.
#
# Env:
#   ELMC_HEAP_MB   GC heap in MB (default 3072).  MUST be large enough: the
#                  corpus pass has a multi-GB live set.  Exhausting the
#                  reservation is now a LOUD panic (heap.GROW_FAIL_STREAK_MAX)
#                  rather than the old silent livelock, but it still costs you
#                  the run — 3072 is the measured value for the whole compiler,
#                  1024 fits a single fixture.
#   BOOTSTRAP_SEED use this bundle instead of tools/bootstrap/selfhost.csexp
#   ELMVM          use this elmvm binary instead of zig-out/bin/elmvm
#
# Exit: elmvm's exit code.  Compile ERRORS are not a nonzero exit: like
# `node run.js`, NativeMain writes "err <msg>" into the group's OUTPUT path and
# exits 0 (see tools/selfhost-gate.sh, which cmp's for exactly that).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${BOOTSTRAP_SEED:-$ROOT/tools/bootstrap/selfhost.csexp}"
ELMVM="${ELMVM:-$ROOT/zig-out/bin/elmvm}"

if [ "$#" -eq 0 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

[ -s "$SEED" ] || {
  echo "bootstrap-compile: no seed bundle at $SEED" >&2
  echo "  (it is committed at tools/bootstrap/selfhost.csexp; set BOOTSTRAP_SEED to override)" >&2
  exit 2
}

# The seed is a committed BINARY: check it against its recorded sha256 before
# trusting it.  --quiet prints only on mismatch; a missing .sha256 is a
# warning, not a failure (the bundle is still usable, just unverified).
if [ -f "$SEED.sha256" ]; then
  ( cd "$(dirname "$SEED")" && sha256sum -c --quiet "$(basename "$SEED").sha256" ) || {
    echo "bootstrap-compile: $SEED does NOT match $SEED.sha256 — refusing to run it" >&2
    exit 2
  }
else
  echo "bootstrap-compile: warning: $SEED.sha256 missing, seed UNVERIFIED" >&2
fi

if [ ! -x "$ELMVM" ]; then
  echo "bootstrap-compile: building zig-out/bin/elmvm" >&2
  ( cd "$ROOT" && zig build elmvm )
fi

# AOTRUN_ARGV: the trailing args are NativeMain.main's argv (*argv*, not call
# arguments).  AOTRUN_QUIET: keep stdout clean — the driver's final model print
# is not a compiler's business (same contract as tools/aot/run.zig).
export AOTRUN_ARGV=1
export AOTRUN_QUIET=1
export ELMC_HEAP_MB="${ELMC_HEAP_MB:-3072}"

exec "$ELMVM" "$SEED" NativeMain.main "$@"
