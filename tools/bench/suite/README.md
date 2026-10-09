# tools/bench/suite — the representative workload suite

## Why this directory exists

Every optimisation in this tree was, until now, measured on **one** workload: the
compiler compiling its own 58-source corpus. That corpus was measured to be
**unrepresentative**, and the measurement is the reason this suite exists
(`docs/qbe-backend.md`, "Aggregate flattening — what it buys, and on what"):

| the corpus has | per 58 sources |
| --- | --- |
| let-bound record **literals** (born and consumed in one defun) | **9** |
| record literals total — all returned, passed or stored | 667 |
| `RecordUpdate` sites — **all** with PARAMETER bases (`{ state | .. }`) | 459 |
| numeric loops | none |
| loop-invariant computation | none |
| nested aggregates | none |

Consequences already paid for: `Mid/Qbe/Flatten.elm` measured **−0.08%** on that
corpus, and four passes (contify/loop-\*, monomorphise, poly-equal) were
eliminated or deferred on ratios measured from it. `Flatten` is *on by default*
on a workload that cannot show what it does.

This suite is the **instrument** whose absence caused those calls: twelve small,
self-contained Elms programs, **one shape each**, all of them shapes the corpus
lacks (plus one — `recflow` — that it has, kept so the mix stays honest).

Run it with `tools/osier-bench.sh`.

## The programs

`main` is the timed entry (heavy enough to be measurable, ≈0.3–1.1 s on the VM).
`once` is the per-call unit for `zig-out/bin/vmbench`, following the idiom of
`tools/bench/*.elm` (see `tools/midtier-runtime.sh`).

| program | shape | the corpus gap it fills |
| --- | --- | --- |
| `localrec.elm` | `let r = { a = n, b = 2 } in ... r.a ... r.b`, in a loop | the **exact shape `Flatten` targets**, of which the corpus has 9 |
| `recupd_local.elm` | `{ r \| f = v }` with a **local literal** base | the corpus's 459 `RecordUpdate` sites all have *parameter* bases; a local base is `Flatten`'s documented "known gap" |
| `recupd_param.elm` | `{ r \| f = v }` with a **parameter** base | the corpus's actual shape — contrast/control for the row above |
| `recflow.elm` | records passed in as arguments, returned as results | **the corpus's shape** — included so the mix is honest about what was already covered, and as a negative control (a pass that helps `localrec` must not hurt this) |
| `numloop.elm` | integer loop with a genuine **loop-invariant** computation in the body | **no loop optimisation exists** in this stack (QBE's `fillloop` only computes loop depth for register allocation; Mid has no loop pass) and the corpus has no loops to justify one |
| `nestagg.elm` | nested aggregates `{ p = ( n, 2 ), q = [ 3, 4 ] }`, `( ( 1, 2 ), 3 )`, read back by patterns in the same defun | `Flatten`'s other documented gap — and the mix of tuple patterns and list patterns that produced a silent miscompile in `unifyList` (`tools/qbe/fixtures/flatnest.elm`) |
| `listbuild.elm` | a 1000-cell list built and folded, per round | the aggregate that **escapes**: separates "the object goes away" from "the object is walked" |
| `deepnontail.elm` | `n + depth (n - 1)` — non-tail recursion, 10 × 50000 live frames | the native path's **missing depth guard**; the corpus is all self-tail loops |
| `adtmatch.elm` | a 4-constructor `Expr` built and matched apart every round | the corpus's matches are record-ish and tiny; tag-dispatch-heavy matching was the last thing reached on the native path |
| `mono_int.elm` | **the monomorphisation axis** — ONE generic `fold` used at `Int` and at a record type | no polymorphic function is ever instantiated twice in the corpus, so a specialiser/unboxer has nothing to bite on |
| `mono_record.elm` | the same ONE generic `fold`, weighted on the **record** instantiation (record accumulator, rebuilt and returned every step) | as above, on the representation a flattening/unboxing change would move |
| `mono_float.elm` | the same ONE generic `fold`, weighted on the **Float** instantiation | as above — was **not expressible on the native backend**; RESOLVED 2026-10-09, it now measures on both backends (finding 1 below) |

### The monomorphisation axis, specifically

The brief for this axis is "**one** generic function, instantiated at Int, at
Float and at a record type — do not duplicate the source". What was built:

* `mono_int`, `mono_float` and `mono_record` each define the generic `fold`
  **exactly once**, between the two `>>> generic fold` / `<<< generic fold`
  markers. `tools/osier-bench.sh` hashes that region in all three files and
  **fails the run if a copy drifts** (it prints `mono generic sha=…`).
* Each program uses that one generic at **several types in one compilation
  unit**, because that is what a monomorphiser actually sees. The program's
  name says which instantiation dominates its timed loop.
* The Float instantiation lives **only** in `mono_float`, for a measured
  reason: any float literal anywhere in a unit makes the whole unit
  unbuildable on the vendored QBE (next section). Putting it in `mono_int` or
  `mono_record` would take the entire axis off the **native** backend — the
  backend the axis exists to inform. *(That reason is historical: finding 1
  is RESOLVED and float literals build and run on the native backend now.
  The layout is kept — the three files' timed bodies are measurements, and
  re-homing the Float instantiation would change them for no measured
  gain.)*

**A shared `Mono.elm` module is not possible here**, and that is *measured*, not
assumed: `node elm-compiler/run.js <one.elm> <out.csexp>` does not resolve
cross-module imports. A two-module `App.elm` + `Lib.elm` compiles to
`err type error at 7:5: unknown name: Lib.twice` written **into the bundle**,
with `run.js` still exiting **0**. The compile unit is the file, so "one
generic, not three" is honoured per file plus the checksum assertion above.

## What the suite does **NOT** measure

Stated explicitly, because a suite that cannot say what it omits invites exactly
the mistake that created it.

* **Not an A/B of any pass.** The runner times each backend's **default**
  build. Its only explicit flag is `MIDTIER=0` on the VM compile
  (`tools/osier-bench.sh`), which is the compiler's default anyway; nothing
  sets `QBE_NOFLATTEN` or any other flag. To attribute
  a change to `Flatten`, re-run with the flag toggled (`QBE_NOFLATTEN=1`); the
  suite tells you a shape *moved*, not *why*.
* **Not correctness beyond `main`'s stdout.** The runner requires the VM and the
  native binary to print byte-identical stdout for the same entry, and requires
  every repetition to print the same bytes. It does not compare intermediate
  state, and the `once` entries are not exercised.
* **Not a representative program.** Twelve shapes are an instrument for the
  named gaps, not a workload distribution. Nothing here says how often real
  Osier code writes a local record literal.
* **Not memory.** No peak RSS, no allocation counts, no GC statistics. The only
  memory statement made is the binary one "this run was not heap-bounded"
  (a `grow_heap`/`panic` line on stderr fails the row).
* **Not compile time.** By design: every program is compiled **once per
  backend** and the compile is never inside the timer. Compile-time cost of a
  pass is not measured here at all.
* **Not the AOT backend.** `zig-out/bin/aotbench` is not produced by this
  tree's `build.zig` (it imports a per-app generated module), so the AOT column
  is `MISSING-TOOL` for every row. The runner measures it if the binary exists;
  it cannot build it.
* **Not effects, IO, Strings, or multi-module programs.** One module, `Int`
  results (except `mono_float`, `Float`), no `StreamRef`, no `argv`.
* ~~**Not Float on native.**~~ CLOSED 2026-10-09: Float **is** measured on the
  native backend — finding 1 below is RESOLVED, `mono_float` has a QBE row,
  and the runner's declared-not-expressible array is empty by design.
* **Not the `once` entries.** They are timed by `tools/vmbench.zig`
  (`tools/midtier-runtime.sh`), not by this runner.

## Measured findings that came out of building this suite

Marked MEASURED / INTERPRETATION. The first two are general-use completeness
findings, not suite trivia.

### 1. ~~Float is not expressible on the native (QBE) backend~~ — RESOLVED 2026-10-09 — MEASURED

*(Everything down to the RESOLVED block is the original finding, kept as
history: the diagnosis is correct about what the vendored lexer does, and the
silent-wrong half is why the correction is recorded rather than the section
deleted.)*

Every `Float` value in this front end originates from a float literal
(`Mid/Qbe/Lower.elm`, `LFloat` → `freshData ("flt:" ++ …)`), and
`elm-compiler/src/Mid/Qbe/Print.elm:89` emits that static as

```
data $d0 = align 8 { d 0.0 }
```

The vendored QBE cannot parse it. `vendor/qbe/parse.c` lexes numbers with
`getint()`, which reads **digits only** — there is no decimal in the lexer — so
the token after `d ` is `0`, and `.0` becomes an unknown keyword:

```
qbe: <out>/mono_float.ssa:15: unknown keyword .0
```

MEASURED directly against the vendored binary: `data $d0 = align 8 { d 0 }`
parses; `{ d_0.0 }`, `{ s_0.0 }` and `{ d 1.5 }` do **not** ("invalid size
specifier d in data"). The working form for a float in a data section on this
QBE build is `{ d d_1.5 }` (size letter `d`, then the `d_…` float token) — the
emitter uses neither that nor `d_…` alone.

INTERPRETATION: this is why `docs/qbe-backend.md`'s "Float args in the driver
(int-only by design here)" is a *smaller* statement than the actual gap — the
driver's int-only args are a deliberate restriction, but a Float value cannot
reach the native backend at all, even without arguments. The doc's own
"Files" list does not record it.

The runner does **not** silently drop this shape. `mono_float`'s QBE row is a
declared, printed `NOT-EXPRESSIBLE` with the observed error inlined, and
`OSIER_BENCH_STRICT=1` turns it into a hard failure so the exemption itself can
be audited.

**RESOLVED 2026-10-09.** The gap is closed on every front the diagnosis names:

* `Mid/Qbe/Print.elm` now emits a double data item in the working form this
  finding measured — `{ d d_0.0 }` (size letter `d`, then the `d_…` float
  token) — and spells a non-finite static as a bare FP token (`d_Infinity`).
  The non-finite case is a **third** member of the same lexer class that no
  literal in this suite reached: `String.fromFloat 1.0e400` renders
  `"Infinity"`, the old `".0"` suffix produced `d_Infinity.0`, and C's
  `strtod` stops at the `.` — `unknown keyword .0` again (found by the new
  fixture, not by this suite).
* `Mid/Qbe/Lower.elm`'s `LFloat` now **stores** the double through the
  payload address. Before, it loaded the double *into* the payload-address
  temp, so the payload was never written and the peephole's dead-pure-def
  rule deleted the load — the **silent-wrong** half of this finding: the
  native binary built, exited 0, and printed `0.0` where the VM prints
  `600000.0`.
* `Mid/Qbe/Il.elm` gained the `StoreD` instruction the above needs, and
  `tools/qbe/rt.zig` takes float entry args (closing the driver's int-only
  half, the part `docs/qbe-backend.md`'s next-stage list named).
* New evidence, re-produced at the fix: `tools/qbe/qbe-check.sh` → exit 0,
  **153 PASS / 0 FAIL** (was 89), including the new 27-entry float
  differential matrix `tools/qbe/fixtures/float.elm`; `tools/osier-bench.sh`
  → exit 0 with `mono_float` **measured** on both backends (this host:
  VM 411 ms / QBE 129 ms, stdout byte-identical; 12/12 on both) — and the
  runner's `DECLARED` array is **empty by design**: a stale declaration is
  itself flagged by the mechanism, so removing the entry is the fix's
  receipt, not a papering-over.

### 2. The VM is silently WRONG from 65526 non-tail frames — MEASURED

`deepnontail.elm` walks a non-tail recursion whose depth is the workload:

| depth | elmvm (VM) | QBE native |
| --- | --- | --- |
| 50000 | `1250025000` correct | `1250025000` correct |
| 65525 | correct — **but only with a large heap** (`ELMC_HEAP_MB>=2048`); at this suite's 512 MB default the same run is **heap-bound** and aborts `rc=134` in `grow_heap`, which is a *different* failure | (not run) |
| 65526 | **prints a garbage lambda structure** — the first bad depth through the `main` entry | (not run) |
| 65536 | **same garbage** | `2147516416` correct |
| 100000 | **same garbage** | `5000050000` correct |
| 200000 | (not run) | **SIGSEGV / core dump** |

The VM's failure is **silent and wrong**: exit status `0`, stderr **empty**,
and stdout is a printed value that is not the answer — and it starts a few
frames **below** the cap, not at it: through the `main` entry the first bad
depth is 65526, and 65525 is still correct when the heap is large enough
(the probe's own `main`/`rounds`/apply frames are on the
stack, so the exact edge moves with the entry path; a rounds-1 probe stays
correct to 65534). `vendor/zinc-vm/src/gc/types.zig:205` defines
`CALL_STACK_DEPTH = 65536`, and the guard is a **silent break out of the run
loop** — `vendor/zinc-vm/src/vm/interp.zig:873`:
`if (frames_sp >= types.CALL_STACK_DEPTH) break :run;` (faithfully ported
from ZINC's C:3296) — which leaves whatever `acc` holds as the result. (Do
not re-probe the edge at this suite's 512 MB default heap: 10 × these depths
also outgrow the heap, which aborts the run — use a larger `ELMC_HEAP_MB`.)

**SUPERSEDED 2026-10-09** (handoff osier-vmdepth, follow-up osier-vmfollowup):
the paragraph above is HISTORY — the boundary transcript stays as measured.
The VM no longer fails *silently and wrong*: the `CALL_STACK_DEPTH` guard in
`vendor/zinc-vm/src/vm/interp.zig` (formerly the `break :run` at :873) now
uses the VM's own fatal idiom (`std.debug.panic`, as `gc/types.zig` documents
for C's `stderr message + exit(1)`): **exit status 134, a
`fatal: call stack depth exceeded` diagnostic on stderr, empty stdout**.
Evidence: the `calloverflow` check in `tests/elm-fixtures/run-elm-gate.sh`
(registered by the `depth()` helper, kind `depth`), which asserts exactly that
in three invocations — control depth correct, `CALL_STACK_DEPTH-1` correct,
and past the cap a non-zero exit with the named diagnostic on stderr and **no
value on stdout**. One consequence for the INTERPRETATION below: the VM's
failure is now a *reported* fatal; only the native path's SIGSEGV remains
unreported.

INTERPRETATION: the two backends fail in *opposite* places — the VM has a
16-bit-ish frame cap that corrupts results, the native path has no cap at all
and dies on the real C stack (which is the gap `docs/qbe-backend.md` already
names). Neither is currently a *reported* failure. `deepnontail`'s `main`
therefore uses depth 50000 (correct on both) so the row is a measurement, and
the transcript above is the finding.

This is also why the runner **cross-checks** the two backends' stdout and fails
the row on a mismatch — a benchmark whose two backends disagree is not a
measurement. The cross-check is itself proved by that divergence: a temporary
probe at depth 65536 makes the runner exit 1 with
`zz-mismatch: VM/native output mismatch`.

### 3. `run.js` exits 0 on a type error — MEASURED

`node elm-compiler/run.js <src> <out.csexp>` exits **0** when the source does
not compile and writes `err type error at L:C: …` **into the csexp**. The
**oracle is the file**, not `$?`. The QBE path already checks the `err ` prefix;
this runner applies the same check to the VM path. (Without it every
compile-failing shape would be timed as a bundle that loads nothing.)

### 4. `zig-out/bin/aotbench` is not buildable in this tree — MEASURED

`build.zig` installs `elmvm`, `vmbench`, `aotdump` and the AOT spike exes;
`tools/aot/main.zig` imports `aot_gen`, a **per-app generated** module. So the
AOT column is `MISSING-TOOL` on every row, and the runner reports it as a skip —
not as a pass, and not as a failure.

### 5. The suite's own times (best of 3, heap 512 MB) — MEASURED

One full run of `tools/osier-bench.sh`, this host, 2026-10-09 (after the QBE
float fix; the pre-fix snapshot is below the table):

| program | VM ms | QBE native ms |
| --- | --- | --- |
| `localrec` | 656 | 23 |
| `numloop` | 427 | 44 |
| `listbuild` | 327 | 58 |
| `deepnontail` | 755 | 93 |
| `mono_int` | 417 | 107 |
| `mono_float` | 411 | 129 |
| `adtmatch` | 578 | 156 |
| `nestagg` | 1167 | 267 |
| `recupd_param` | 557 | 370 |
| `mono_record` | 533 | 382 |
| `recflow` | 468 | 394 |
| `recupd_local` | 701 | 516 |

Per-backend totals from that run: VM 12/12, 6997 ms; QBE 12/12, 2539 ms;
AOT 0/12 (`MISSING-TOOL`). All 12 VM/native cross-checks compared
byte-identical.

Pre-fix snapshot, kept as the historical baseline (before the QBE float fix,
same table then): `mono_float` was 403 ms VM / *not expressible* native, and
the totals were VM 12/12, 6630 ms; QBE 11/12, 2267 ms.

The three mono rows are **not cross-comparable row-to-row**: their fold loops
run different step counts (mono_int and mono_float 400 000 steps, mono_record
100 000 heavier steps — the programs' own comments carry the numbers). Only a
same-row VM-vs-native comparison is a measurement.

INTERPRETATION, and the reason a suite is needed at all: the two cheapest rows
for the native backend are precisely two shapes the corpus lacks — `localrec`
(`Flatten`'s target, 23 ms native vs 656 ms on the VM) and `numloop` (the
loop-invariant shape, 44 ms vs 427 ms). `mono_float` — the third corpus-absent
shape — now measures on the same side of that contrast (129 ms native vs
411 ms VM). Every row the corpus *did* cover (`recflow`, `recupd_param`,
`recupd_local`) is 370–516 ms native. That contrast
is a property of these programs' structure, and it is exactly the contrast a
single-workload corpus could not show. It is **not** a claim about any pass: no
pass was toggled to produce it, and raw VM-vs-native ratios are dominated by
the VM's per-call frame cost, not by `Flatten`.

## Running it

```
tools/osier-bench.sh                 # all programs, all present backends
tools/osier-bench.sh localrec numloop
```

| env | default | meaning |
| --- | --- | --- |
| `OSIER_BENCH_RUNS` | 3 | runs per (program, backend) |
| `OSIER_BENCH_STAT` | `best` | `best` or `median` (lower median); printed in the output |
| `OSIER_BENCH_HEAP_MB` | 512 | `ELMC_HEAP_MB` (VM/AOT) and `QBE_HEAP_MB` (native) |
| `OSIER_BENCH_TIMEOUT` | 300 | per-run timeout, seconds; a timeout is a RUN-FAIL |
| `OSIER_BENCH_STRICT` | 0 | `1` ignores the declared-not-expressible pair |
| `OSIER_BENCH_XCHECK` | 1 | `0` skips the VM-vs-native stdout cross-check |

**Exit status.** `0` only if every non-declared (program, backend) pair
compiled, ran, was not heap-bounded, was deterministic, and agreed with the VM.

* a backend whose **tool is absent** (`elmvm` absent is exit 2; `qbe`/`aotbench`
  absent is a `MISSING-TOOL` skip) is **not** a failure;
* a program that **did not compile**, **did not run**, **ran out of heap**, or
  **disagreed with the VM** **is** a failure.

**Heap.** 512 MB by default because `deepnontail` (10 × 50 000 live non-tail
frames) needs it: at `ELMC_HEAP_MB=256` the VM answers
`[gc] grow_heap: need 512 MB but reservation is 512 MB` and then panics. The
runner treats a `grow_heap` or panic line on stderr as RUN-FAIL, so a
heap-bounded run can never be reported as a time. Every other program in the
suite completes at 256 MB.

**Scratch.** `mktemp -d`, removed by a `trap … EXIT`. A fixed scratch path
persists across runs, and an artifact read back without being rebuilt then
answers from the **previous** run — the bug documented in the header of
`tools/qbe/qbe-check.sh`.

## Adding a shape

1. Add `tools/bench/suite/<name>.elm`. Keep the header conventions: the
   `-- SHAPE: <token> -- …` line is parsed by the runner and printed in the
   workload-mix table. Export `main` (the timed entry) and, where it fits the
   `tools/bench/*.elm` idiom, `once` (the `vmbench` unit).
2. That is all — the runner globs `tools/bench/suite/*.elm`. Do **not** put
   files directly in `tools/bench/`: `tools/midtier-runtime.sh` globs
   `tools/bench/*.elm` (non-recursive) and those four files are pass-specific
   microbenchmarks for a different purpose.

## Relations

* `tools/osier-bench.sh` — the runner.
* `tools/qbe/fixtures/` — the native backend's *correctness* fixtures, whose
  job is VM/native parity and structural pass assertions, not wall clock.
* `tools/midtier-runtime.sh` + `tools/bench/*.elm` — the pass-specific
  microbenchmarks (`Inline`, `Arity`, `eta`, `letfallback`, `overapp`), one
  pass each, MIDTIER flag matrix. Complementary: those answer "does this pass
  help its own shape", this suite answers "which shapes exist at all".
* `docs/qbe-backend.md`, "Aggregate flattening — what it buys, and on what" —
  the measurement this directory is the instrument for.
