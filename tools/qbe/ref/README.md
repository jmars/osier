# tools/qbe/ref — the pre-B4 Zig-arm reference binaries

Stage 6 B4 ("the shrink") deleted the Zig seats that the Mid runtime took over
(`rt_frame_enter/leave`, `rt_apply/rt_apply_tail`, `rt_bounce/rt_tail_known`,
`rt_die/rt_halt`, `rt_prim`, `main`), so the `QBE_MIDDRIVER=0` hatch-OFF arm the
three ratio gates (`frame_perf_gate`, `apply_perf_gate`, `tail_perf_gate` in
`tools/qbe/qbe-check.sh`) built against no longer exists.  These executables
are the **last pre-B4 Zig arm**, built at `cf59488` and committed so the gates
can keep measuring a RATIO after the arm's source is gone.

Each gate now builds only the Mid arm and compares against the committed
binary below, arms alternated, median-of-7 (the pre-B4 method).  The Zig arm is
FROZEN: it never changes, so a move in the ratio is attributable to the Mid arm.

Precedent for committing binaries: `tools/qbe/rt.o` is committed.

| fixture | entry | binary | sha256 | size |
|---|---|---|---|---|
| frame gate | `tests/elm-fixtures/fib.elm` `Fib.fib` | `fib/fib` | `ae86c1681a32e1a72694112ff6a912214ad463a585bcf6aa08e43a751c183dc2` | 3,913,152 |
| apply gate | `tools/qbe/fixtures/applyperf.elm` `ApplyPerf.main` | `applyperf/applyperf` | `68980e52ec1d9d854f3cf398b509fc50e3be91a9e4cfa74d9be14475b3831f0b` | 3,930,032 |
| tail gate | `tools/qbe/fixtures/mutualtail.elm` `Mutual.even` | `mutualtail/mutualtail` | `d86785d56852e8bd1e30d60e06b5f2577c5794247fdc3f207031eafb5cc12ed3` | 3,929,856 |

## Rebuild command (only if these are ever lost)

```
QBE_MIDDRIVER=0 tools/qbe/qbe-mk.sh <src> <entry> <outdir>
```

at any tree up to `cf59488` (the Zig seats are still in `tools/qbe/rt.zig`
there, and in git history after B4 — B4 is recoverable, not irreversible).
`rt.zig` is the pre-rename name of `tools/qbe/hostshim.zig`.

The recorded sha256s are the source of truth; a rebuilt binary must reproduce
them (the PERF-DEBT.md "pre-B4 reference binaries" table records the same
hashes).
