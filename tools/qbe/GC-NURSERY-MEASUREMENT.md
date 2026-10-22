# GC NURSERY — the scale measurement (step 3)

## Setup

Same shape as the gc-fixes2 retention measurement, with the nursery ON:

```
jq '.groups[0].output=emit.ssa | .groups[0].entry=NativeMain.main' \
   osier-compiler/selfhost/manifest.json   # the build manifest
QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 RUN_STACK_KB=131072 node osier-compiler/run.js --batch ...
vendor/qbe/qbe emit.ssa > emit.s; cc -O1 emit.s "$(tools/qbe/rt-o.sh)" -o qbemit -lc
# run, from the REPO ROOT (the manifest sources are repo-root-relative):
ulimit -s 524288
AOTRUN_ARGV=1 QBE_HEAP_MB=16384 QBE_MIDGC=1 QBE_MIDGC_YOUNG=1 QBE_MIDGC_STATS=1 \
  timeout 900 qbemit NativeMain.main --ssa NativeMain.main run.manifest
```

Both the baseline and this run are TIME-BOXED at 900 s and are STILL EMITTING
at the bound (the full emit is ~40 min); the comparison is at the same phase.

## The numbers

| | baseline (non-moving) | nursery ON |
|---|---|---|
| frontier (max old-space swept) | **7.57 GB** | **583 MB** (583 884 352 B) |
| collects | 99 | 109 |
| scavenges | — | 1092 |
| bytes copied (sum of scavenge copied=) | — | 2 322 679 680 B (2.16 GiB) |
| grow lines | 0 | **1** (see the anomaly) |
| last collect | mark=… swept=7.57 GB sweepUs 0.75–1.24 s | mark=2 848 867 swept=583 MB sweepUs 43 ms |
| exit | 143 (watchdog) | 124 (the 900 s timeout) |

The frontier is the OLD-space cursor: with the nursery it stays near the LIVE
set (mark ~2.8 M bodies, ~345 MB-class plus per-phase residue) while the
non-moving collector's frontier climbs to the allocation high-water (7.57 GB)
and its O(heap) sweep costs 0.75–1.24 s per collect (43 ms here).  The drop
is **13.0x**.

## The anomaly (flagged, not yet explained)

The nursery run shows ONE growth to the ceiling at STARTUP —
`midgc: grow 20480 MB (was 16384 MB, ceiling 20480 MB)` — before the first
collect, while the baseline showed ZERO grows.  The frontier stayed at 583 MB,
so the grow raised the LIMIT (reserved VAS), not the touched frontier — the
headline number is unaffected — but a spurious ~16 GB-class old-path/promote
request at startup is a real difference from the baseline and is the next
thing to chase (suspected: a giant allocation routed old-direct that the
non-moving path never made, or a promote whose class read is wrong).  It does
NOT block the movement or barrier claims: every fixture and probe is green,
and the frontier at the comparable time-box is the requested number.
