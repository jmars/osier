# Shen GC — Zig port notes (src/gc)

A faithful Zig 0.16 port of the Shen Lisp generational moving GC in
`reference/shen-gc/gc.c` (+ `zincvm.c`'s scan helpers and `gc.md`'s write-barrier
design).  Each function carries a `/// C: gc.c:NNNN` (or `zincvm.c:NNNN`) doc
comment pointing at its C origin — that comment is the reviewability contract
against the reference.

Module layout (see `src/gc.zig`):

| file | ports |
|---|---|
| `src/gc/types.zig` | `zinctypes.h` + `gc.h` type layer, header helpers |
| `src/gc/heap.zig` | `Gc` state, init/deinit, queue, `gcalloc_internal`, `allocatepage`, `grow_heap`, nursery fast path, counters, dirty sets, predicates |
| `src/gc/collect.zig` | `collect`, `collectNursery`, `cheneyDrain`, `scanRoots`, `moveInternal`/`gcMove`, `debugVerifyHeap` |
| `src/gc/scan.zig` | `scanValue`, `evacuate`, `evacInstr`, `valueReferencesNursery` |
| `src/gc/roots.zig` | precise-root shadow stack + registrations |

## What was omitted (~1000 lines of opt-in diagnostics)

The C collector carries a large body of opt-in diagnostic/verification code that
is **not** ported, because it is unportable (C-stack frame walking), redundant
under precise roots, or only useful during C development:

- `check_closures`, `dump_roots`, `stale_scan`, `page_transition`, `watch_alloc`,
  `verify_codechains`, `verify_live` + reverse-search, and the C-stack frame
  walker.  Zig has no portable equivalent of walking the mutator's native stack,
  and with precise shadow-stack roots the collector never *needs* it.
- `SIGALRM`-blocking around collection.  The Zig runtime has no alarm-driven GC
  timeout yet; `std.posix.sigprocmask` will be available when the VM port lands.
- The only diagnostics kept are the two verbose collection banners
  (`[GC FULL #seq trigger live_pages]` / `[GC NURSERY #seq trigger nursery_free]`,
  gated on `Options.verbose`) and **`debugVerifyHeap`** — a test-only
  (caller-invoked) heap verifier used by the test suite instead of the C
  verifiers.  `debugVerifyHeap` checks page invariants and, for a given phase,
  that no live object holds a stale pointer (post-scavenge: no nursery pointer
  from a live object; post-collect: no pointer into dead/released space).
- `exit(1)` on OOM is mapped to `std.debug.panic`; `Gc.init` returns a proper
  Zig error union (`error.InvalidHeapSize`) instead of aborting.

## Mutator contract

The collector is a **moving** (copying, semi-space) GC: any allocation can
trigger a scavenge/full collect that **moves previously-allocated objects** and
rewrites the interior pointer slots of every *rooted* object.  The exact C
hazard ("any GC pointer held only in registers / un-rooted locals across a
`gc_alloc*`/`collect` goes stale") applies verbatim.

Rules to follow in any code that allocates from the `Gc` heap:

1. **Root before the allocating call.**  Any GC pointer that must survive a
   potential collection must have its *slot's address* pushed on the shadow
   stack **before** the allocating call that could trigger the GC.  `evacuate`
   rewrites through the slot during the collection.
2. **`var` locals are rootable; `const` locals are unrootable by construction.**
   Zig's "local variable is never mutated" compile error is an *asset*: a
   pointer local that is only read must be `const`, and a `const` cannot be
   mutated by the GC.  Treat the lint as a rooting-audit signal — a pointer that
   is only read is fine as `const` only if it cannot be invalidated by a
   collection (e.g. it points into old-gen that is itself rooted), otherwise it
   must be a `var` whose address is rooted.
3. **`ROOT_PTR` requires an object head.**  `gc.rootPushPtr(slot)` tells the
   scanner the slot points at the *head* of a GC object.  An interior pointer
   (into the middle of a multi-page object) is a fatal error (the
   `gc.c:1527-1539` defense; proven by the `gc_root_ptr_panic` test exe).

## Root rules (the precise-root API)

- `rootPushValue(&v)` — root a `Value` local (`v: var types.Value`).  The `Value`
  itself stays put; its interior pointers (`cons.car/cdr`, `lambda.code/env`,
  `vector.data`, `str.data`, `error_.message`) are rewritten in place via
  `scanValue`.  This is how you hold a cons list head across a collection.
- `rootPushPtr(&p)` — root a raw GC pointer slot (`p: var ?*Value` etc. —
  a *slot*, not the pointed-at value).  `p` must point at an object **head**.
- `rootPushValueVolatile`, `rootPushValueArray(base, &len)`,
  `rootPushCallframeArray` — API parity with the C roots.
- **Slices:** root a GC slice by rooting its head pointer:
  `gc.rootPushPtr(@ptrCast(&slice.ptr))`.  The object must be a single GC
  object (e.g. a `Value[n]` array allocated as one object).
- **Interior slice starts are invalid roots.**  `arr[i..]` (for `i > 0`) points
  into the middle of the object; registering it as a `ROOT_PTR` makes the GC
  read a garbage header at `*(ptr-1)`.  Root `&slice.ptr` (the object head) and
  re-derive `i..` after any collection.
- The shadow stack is **never** scanned by the GC itself — it is read by
  `scanRoots` as the root set; the drain never descends into it.  It lives in
  C-heap memory (`page_allocator`), outside both semi-spaces.
- `rootPop` / `rootPopTo(watermark)` / `rootWatermark` follow the C LIFO
  discipline.  Always pop what you push (or restore the watermark) before the
  `Gc` goes out of scope.

## Build / run

Prerequisites: Zig 0.16.x.  `ZIG_GLOBAL_CACHE_DIR` (e.g. `/tmp/zigcache`) is
recommended so the first compile reuses the std precompiled artifacts.

```sh
zig build test                     # Debug — full suite incl. the Shen GC tests
zig build test -Doptimize=ReleaseFast
zig build gc-test                  # Shen GC tests alone (incl. T8 churn + T9 panic exe)
zig build gc-test -Doptimize=ReleaseFast
zig build run                      # the main.zig demo (init → build (1 2 3) → scavenge → collect → stats)
```

The test gate (plan DECISION 7): `zig build test` and
`zig build test -Doptimize=ReleaseFast` must both pass.  `tests/gc_test.zig`
holds T1–T8; the T9 ROOT_PTR defense is a build-level expected-panic executable
(`tests/root_ptr_panic.zig`, wired into `gc-test`).

## The scheduling bug and the reservation arithmetic (gc-fix A/B/C)

Chased because the native QBE path aborted with "heap FULL" at EVERY heap size
— "not a 64 GB live set, two small bugs stacked".  All figures below are
MEASURED on this host (PAGEBYTES is **512**, so MB figures are
`pages x 512`); the historical headline (a 4096 MB corpus run) is in the
"before/after" table.

### A — the full-collect trigger was unreachable on a small-object workload

`gc_alloc`'s old-gen THRESHOLD trigger (`heap.zig`, C: gc.c:2262-2274) sat only
on the arm reached when the nursery REFUSED an allocation (object > 1 MB, or a
full nursery).  This compiler allocates almost entirely nursery-sized objects,
so the arm was rarely taken, `allocatedpages` accumulated promoted dead data,
and the two other full-collect triggers could not fire: `allocatepage`'s
LASTRESORT is gated `!in_scavenge` and promotions happen INSIDE a scavenge.
Death therefore landed mid-scavenge with the free-page scan exhausted.
MEASURED on the 4-file fixture manifest: **0 full collects at 512 MB** (abort)
and **exactly 1 at 1024 MB** (via THRESHOLD, `live_pages` 1564008 = 800.6 MB of
old-gen).

FIX: the THRESHOLD block is hoisted to the top of `gc_alloc`, above the nursery
fast path — collection TIMING only, so every byte oracle had to survive it
(the 4-file csexp is sha256 `0daa156e…` at pre-fix/1 full collect,
post-fix/3 and post-fix/8 alike).

### B — collection counts, before/after (same binaries, same workload)

4-file fixture manifest (`/tmp/small.manifest`, entry `NativeMain.main`):

| heap | scavenges | full collects | old-gen in use at the full collect | outcome |
|---|---|---|---|---|
| 512 MB before | 7345 | 0 | — | ABORT (`Unable to allocate 1 pages in a 1048576 page heap`) |
| 512 MB after | 11566 | 8 | 262202 pages = 128.0 MB (`heappages/4`) | exit 0, RSS 561 MiB |
| 1024 MB before | 11566 | 1 | 1564008 pages = 800.6 MB | exit 0 |
| 1024 MB after | 11566 | 3 | 524324 pages = 256.0 MB (`heappages/4`) | exit 0, RSS 1099 MiB |

Corpus `.ssa` emit (75-source manifest, `QBE_HEAP_MB=4096`): **before** ABORT
after 127.5 s / 75266 scavenges / 1 full collect / RSS 4357 MiB / no output
file; **after** exit 0, 944.2 s, 556075 scavenges, **472 full collects** (each
at `heappages/4`), RSS 4441 MiB, 13569941-byte `.ssa`.  The scavenge count is
workload-determined (nursery volume) and identical before/after; only the full
collects move.

### C — the reservation had zero growth headroom, by construction

`grow_heap` asks for `max(2 x heappages, (allocatedpages + pages_needed + 512) *
2)` pages and succeeds only if `new_heap_size + PAGEBYTES - 1 <= reservation`.
The drivers passed `reserve = max(2 x heap, 64 MB)`, so the request for the
first doubling was `2 x heap + 511 > 2 x heap` — every grow was refused BY
CONSTRUCTION.  That is the arithmetic behind "need N MB but reservation is N MB"
at 128 MB, 512 MB and 32768 MB alike.  New relationship, MEASURED with
`reserve_probe` (inits a `Gc` exactly as the drivers do, then loops
`grow_heap`):

    reserve = k x heap  =>  log2(k/2) doublings, heap ceiling (k/2) x heap
      k = 2   -> 0 grows  (the old driver formula: growth IMPOSSIBLE)
      k = 8   -> 2 grows, ceiling 4x
      k = 16  -> 3 grows, ceiling 8x   <- the drivers' new value (C's own policy)
    floor for ONE doubling, incl. the exhausted-scan slack:
      2 x heap + 1027 x PAGEBYTES - 1   (2H + 525823 B at H = 512 MB)
    — measured to land exactly at that floor and to be REFUSED at 2H + 1 MB.

The heap-derived call sites (`tools/qbe/rt.zig`, and — before P8 — `tools/elmvm.zig`,
`tools/aot/run.zig`, `tools/aot/main.zig`, all deleted with the interpreter) pass
`max(heap x 16, 64 MB)`.
16x, not a smaller multiplier: at `QBE_HEAP_MB=16` the fixture
`tools/qbe/fixtures/vfield.elm` reaches a live set of 16.1 MB, which needs a
threshold just above 16 MB, i.e. a heap over 64.4 MB — outside an 8x
reservation's 64 MB ceiling (MEASURED: a collect-per-allocation thrash, 4m02s
for one fixture) and comfortably inside 16x's 128 MB (0.04s).  `Gc.init`
shrinks a reservation the address space cannot map toward that floor and says
so on stderr (MEASURED: 64 GiB maps, 128 GiB does not, so 8x/16x at a 32768 MB
heap — 256/512 GiB — is shrunk; explicit `reserve_bytes` is otherwise honoured
exactly, which the M1 init test asserts).

### The anti-thrash grow is a silent, non-fatal optimization

Hoisting the trigger onto the hot path made the anti-thrash `grow_heap(1)`
reachable on every allocation, and three consecutive failures against a
reservation ceiling then armed `GROW_FAIL_STREAK_MAX`'s deliberate fatal panic —
MEASURED aborting `VField.rootedField` at `QBE_HEAP_MB=16` (rc 134) while it
still had a serviceable heap.  `grow_heap` now has two kinds: **critical**
(`allocatepage`; C's message, the streak and the panic, all unchanged) and
**antithrash** (the THRESHOLD arms: silent and non-fatal).  A failed
anti-thrash grow costs collection FREQUENCY only — the trigger keeps collecting
at the current threshold, and genuine exhaustion is still loud, from
`allocatepage`, which panics with the collector state (old-gen in use, its
peak, the live figure after the last full collect, both collection counts and
the reservation) instead of the two-page count that was twice misread as
live-set overflow.

### NOT done here: the conservative-rooting multiplier

`rt_frame_enter` roots ALL `nslots` for a frame's whole life and slots are
SSA-written-once and never cleared, so the collector's view of "live" includes
promoted garbage that pooled frames still reference.  MEASURED at
`QBE_HEAP_MB=16`: post-collect live 4.2 MB -> 8.4 MB -> 16.1 MB as the heap
doubled 16 -> 32 -> 64 MB, i.e. live tracks `heap/4` and the anti-thrash grow
chases it to the ceiling.  Clearing dead slots mid-frame is the real cure, but
it CHANGES THE EMITTED `.ssa` (it needs the fixed point re-established and must
land before any `.ssa` seed freeze) — a separate change, deliberately not made
here.
