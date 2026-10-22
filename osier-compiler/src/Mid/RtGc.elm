module Mid.RtGc exposing
    ( gcProgram
    , globAddrSym, globDataSym, globFreelistSlot, globInternSlot, globKnobSlot
    , globRegionSlot, globRootSlot, globTailScratchSlot, globWords
    )

{-| Mid.RtGc — the FRESH non-moving, non-generational MARK-SWEEP collector
(zigretire stage 4, plan.md §2.2).  NOT a port of the moving generational
Zig collector (vendor/osier-rt/src/gc/*): that collector's hard parts serve
movement + generations (forwarding bits, nursery, promotion, remembered
sets), none of which mark-sweep needs.

MIGRATED (T18, handoff-osier-tier2-t18): the collector's 12 DEFUN BODIES
moved to the surface language in Mid.RtSource (the second DSL copy is
DELETED — the dedup payoff the tier-2 plan names).  This module keeps only
what is genuinely non-body: the U1c GLOBALS-BLOCK layout constants (the
block Lower emits is this module's contract, not a defun) and the
`gcProgram` LIST — now the migrated keys' SEATS, the defun-list positions
`Mid.Rt.spliceSurface` replaces by key (T18 extended the splice to this
list via `Mid.Rt.programPair`/`programGc`; QbeModule appends the SPLICED
half under QBE_MIDGC=1, never this module's seats — a seat body is the
`key ++ ".surface-seat"` tripwire, loud if ever emitted).

THE COLLECTOR'S SHAPE, as it now lives in RtSource (for the reader of this
header — the surface text is the truth, read it): one mmap'd region lazily
created by `Rt.gcInit`; a two-word header before every body (word -2 =
flags = mark + 2*kind + 4*class, word -1 = exact count); two object kinds
(value_array, raw); precise roots read from the MID-OWNED ROOT REGISTRY in the
globals block (ZIGHOST Z1: words 4/5/6 = base/count/cap of a malloc'd
{kind,slot,np} array — the writers are runtime.mid's Rt.rootPush*/Rt.rootPop*
and the readers Rt.gcMarkRoots/Rt.gcScavRoots; the ten Zig shadow-stack seats
that used to carry this are DELETED); the trigger inside
Rt.gcAlloc (threshold collect, per-class free list pop, bump, exhaustion
collect-and-retry); failure is LOUD through Rt.die (stage 6 U2: the raw-word
die defun — the six messages fold into its `rawstr` arguments, replacing the
deleted rt_midgc_die seat).

SIZE CLASSES (perf-gc1, plan.md stage-4 review finding 3).  The stage-4
collector kept ONE free list and accepted a block only on EXACT size match
(`2 + (fcount + 4*fcount*fkind) == total`), so a program that allocated two
different shapes died `midgc: out of memory` with free memory available.
This unit replaces it with a two-level size ladder — 8-word granularity for
blocks up to 4096 words, then 4096-word granularity above — and ONE free
list per class.  `classOf(total) = (total <= 4096) ? ((total+7)/8)
: (512 + (total-4096+4095)/4096)`; the physical block size is
`roundUp(cls) = (cls <= 512) ? (cls*8) : (4096 + (cls-512)*4096)`.  The
class is PACKED into the flags word (`flags = mark + 2*kind + 4*class`), so
the header stays two words: the marker reads `kind = (flags>>1)&1` and the
EXACT `count` (never scans padding), the sweeper reads `class = flags>>2`
for the physical advance and the return class.  The per-class heads live in
the region as a zeroed table after the mark stack (region word 1 = the table
pointer, word 12 = numClasses, both set by Rt.gcInit; Rt.collect zeroes the
table before each sweep via Rt.gcClearClasses).  THE INVARIANT this encodes:
a block's stored class must ALWAYS agree with its physical size — the bump
path rounds too, so the sweeper's `roundUp(class)` advance can never skip
into the next block.
FRAME-FREE BY CONSTRUCTION: no collector defun
contains an allocating node (no RawAllocVector/RawAllocRaw, no LString, no
WithRoots), so Mid.Rt.allocating leaves every one of them out of the framed
set — pinned by a TestMain row, kept green by the migration.

THE INSTRUMENT (GC ARC F1): `Rt.gcNum`/`Rt.gcNumOut` are the two non-collector
defuns in this list — the decimal printer behind `QBE_MIDGC_STATS=1`, which
prints one line per collect (count, bodies marked, bytes swept, per-phase µs)
on stderr.  They are HERE rather than in the driver on purpose: `Rt.main` is
emitted on BOTH routes, so a print there would move the default route's bytes;
these are seeded only under the hatch, and being alloc-free they can be called
from inside `Rt.collect` without violating the frame-free property above.

-}

import Mid.Ir exposing (Defun)
import Mid.RtPrims exposing (seat)


-- ============================ GLOBALS BLOCK ============================
-- The Mid-owned mutable globals (stage 6 U1c, plan correction C3 — the
-- recorded gap "Mid has no mutable-global-state facility" is REFUTED:
-- `vendor/qbe/emit.c:92` puts an all-zero data def in .bss, WRITABLE).  The
-- block is one `export data $rt_glob = { z N }` plus a 0-arg accessor func
-- whose body is `ret $rt_glob` (a global symbol is a legal `l` ret operand —
-- MEASURED, /tmp probe: assembles and runs; the address is a link-time
-- constant).  Both are built by Mid.Qbe.Lower's finishModule, GATED on the
-- midgc flag so the DEFAULT route emits neither and the corpus stays
-- byte-identical.  Mid reads/writes slots with the EXISTING RawCallRaw +
-- RawWordLoad/RawWordStore — which is how the `rt_midgc_region` /
-- `rt_midgc_set_region` Zig seats DIED (their 6 callW sites re-pointed here;
-- the block's word 0 is the old `var midgc_region` Zig global's job).  The
-- surface spells the accessor `rawcall rt_glob_addr()` (J3 row added T18).
--
-- LAYOUT (word slots; the reserved slots name their landing unit so U3/U4a/
-- U5a join the same block instead of growing new globals):
--   word 0         the Mid collector's region pointer (THIS unit)
--   word 1         the frame machinery's CURRENT-FRAME pointer (frame-enter
--                  pushes `hdr` here, frame-leave restores `hdr->next`;
--                  runtime.mid:5680-5695, and FrameHdr's `next` row).  NOT
--                  free: a value parked here survives only until the next
--                  frame push — MEASURED, it is how O5 seat 3's first draft
--                  lost its pointer.
--   word 2         no_reuse (Rt.main's QBE_NO_REUSE knob)
--   word 3         THE VALUES TABLE (O5 seat 3): the 256-entry
--                  {name,value} array base (48 B per entry) so
--                  Rt.value/Rt.valScanGo can walk it.  MID OWNS IT SINCE
--                  ZIGHOST Z5 (rt_boot and the Vm were deleted): `Rt.boot`
--                  mallocs the 12288 bytes, zeroes them and publishes the
--                  base here (runtime.mid:2755, called from Rt.main:7017),
--                  then installs the three standard streams through
--                  `Rt.valSlot`; `Rt.argvInstall` (runtime.mid:2698) writes
--                  the *argv* entry into the same table.  Nothing else
--                  publishes it, and the two collector walkers
--                  (`Rt.gcMarkValuesTab` / `Rt.gcScavValuesTab`) read the
--                  word straight out of this block — there is no separate
--                  registration call.
--   words 4..6     THE ROOT REGISTRY (ZIGHOST Z1): the shadow stack's
--                  replacement, and the only root source the Mid collector
--                  walks.  word 4 = the malloc'd entry array's base, word 5 =
--                  the live entry count, word 6 = the capacity in entries.
--                  An entry is THREE words `{kind, slot, np}` (24 B), the
--                  retired Zig `GcRoot` (vendor/osier-rt/src/gc/roots.zig:35)
--                  word for word; the writers/readers are runtime.mid's
--                  Rt.rootPush*/Rt.rootPop*/Rt.rootWatermark/Rt.rootPopTo and
--                  the two collector walkers.  HERE, not in the region,
--                  because a frame pushes roots BEFORE the lazy `gcInit` maps
--                  anything (the block is .bss, always emitted).
--   words 8..11    driver knobs, getenv read once (U5a)
--   word 12        the single .tail-in-flight scratch (U4a)
--   word 13        no_tail_stage (B2: QBE_NOTTAILSTAGE bypasses to allocvec)
--   words 14/15    THE STRING-STREAM REGISTRY (O5): word 14 = ssTab (a
--                  lazily-malloc'd 8-cell x 3-word (data,len,pos) C-heap
--                  table), word 15 = ssN (the count; MAX 8, a closed
--                  slot's index stays consumed).  NOT collector state, so
--                  it lives here: the block is .bss and always emitted,
--                  while a region is mapped lazily.
--   words 16..8207 the frame freelist heads, indexed by nslots (U3)
--   words 8208..8210  THE INTERN TABLE (O5 seat 2, re-homed by seat 4): 8208
--                  = the lazily-malloc'd (name,len)-pair array's base, 8209 =
--                  the live pair count, 8210 = the capacity in pairs.  Owner
--                  is `Mid.Rt.intern` (runtime.mid's Rt.intTab/intGrow); NOT
--                  collector state, because it must be reachable before a
--                  region is mapped (the block is .bss, always emitted).
-- The freelist bound is 8192 (MEASURED: the seed's max frame nslots is
-- 4,354; giants never pool).  The block is .bss: reserving the words costs
-- nothing on disk.
--
-- THE BLOCK MUST COVER EVERY SLOT ABOVE.  Seat 2 read words 8208..8210 while
-- globWords was still `globFreelistSlot + 8192` = 8208, so the intern table
-- sat 24 bytes PAST the emitted `z 65664` — in the linked binary exactly on
-- hostshim's rt_string_calls/intern_hits/intern_misses (MEASURED from the
-- .bss symbol layout).  Harmless by luck, a corruption hazard by
-- construction.  globWords now derives from globInternSlot, and TestMain pins
-- the emitted block size against the intern slot so a later slot added without
-- growing the block fails loudly instead of escaping again.

globDataSym : String
globDataSym =
    "rt_glob"


globAddrSym : String
globAddrSym =
    "rt_glob_addr"


globRegionSlot : Int
globRegionSlot =
    0


globKnobSlot : Int
globKnobSlot =
    8


{-| The root registry's three words (ZIGHOST Z1): base, live count, capacity.
runtime.mid's Rt.rootPush*/Rt.rootPop*/Rt.rootWatermark spell these indices
literally (the intern/string-stream precedent); this constant is the Mid-side
mirror TestMain's pin reads.
-}
globRootSlot : Int
globRootSlot =
    4


globTailScratchSlot : Int
globTailScratchSlot =
    12


globFreelistSlot : Int
globFreelistSlot =
    16


-- The intern table's three words (O5 seat 2's slots; see the layout table).
-- `Rt.intTab` in runtime.mid spells these indices literally, the same way it
-- spells the string-stream registry's — this constant is the Mid-side mirror
-- TestMain's pin reads.
globInternSlot : Int
globInternSlot =
    globFreelistSlot + 8192


globWords : Int
globWords =
    globInternSlot + 3


-- ============================ PROGRAM ============================


{-| The whole collector program: every defun above.  Injected by
Mid.QbeModule on every compile (unconditional since Z0) and seeded by
Mid.Rt.gcSeeds.  Since T18
these are SEATS (Mid.RtPrims.seat): the bodies live in Mid.RtSource's
surface text and arrive here through the splice (`Mid.Rt.programGc`); the
seat at each key is the position-holder and tripwire.  Its param count
MIRRORS the migrated defun's arity, and the reader that makes the mirror
load-bearing is TestMain's T19 seat-arity row (every seat's param count ==
the surface defun's arity at its key) — the splice substitutes the whole
defun, so the mirror is a declaration-consistency assertion, not a lowering
input, and the T7 safety-net row (surface arity vs externArities) reads no
seat.
-}
gcProgram : List Defun
gcProgram =
    [ seat "Rt.gcInit" 1
    , seat "Rt.gcEnvNum" 2
    , seat "Rt.allocVector" 1
    , seat "Rt.allocRaw" 1
    , seat "Rt.gcAlloc" 3
    , seat "Rt.gcAllocGo" 2
    , seat "Rt.gcGrow" 2
    , seat "Rt.collect" 1
    , seat "Rt.gcMarkRoots" 1
    , -- ZIGHOST Z1: the values table's root walk (the found *argv* hole).
      -- A COLLECTOR defun (it walks roots and marks), hence HERE and not in
      -- the prim half: a prim-half key may not name a gc key (TestMain's call
      -- graph row), and this one names Rt.gcMarkValue.
      seat "Rt.gcMarkValuesTab" 1
    , seat "Rt.gcScanValueArray" 2
    , seat "Rt.gcDrain" 1
    , seat "Rt.gcSweep" 1
    , seat "Rt.gcClearClasses" 1
    , seat "Rt.gcMarkPtr" 1
    , seat "Rt.gcMarkValue" 1
    , seat "Rt.gcNum" 2
    , seat "Rt.gcNumOut" 3
    , seat "Rt.gcVD" 3
    , seat "Rt.gcVerify" 2
    , seat "Rt.gcVerifyList" 3
    , -- ===== THE NURSERY'S SCAVENGE FAMILY (GC NURSERY unit).  Seated like
      -- every collector defun (the splice puts them in the GC HALF, where
      -- their calls to Rt.gcVD/gcNumOut/gcGrow live) but seeded ONLY in a
      -- QBE_MIDGC_YOUNG=1 build (Lower's youngGcSeeds): the surface defuns
      -- exist only in that build, so anywhere else these seats stay UNSEEDED
      -- and are pruned before emission — an unseeded seat never reaches the
      -- linker, which is what lets a build-conditional defun be seated at
      -- all.  Nothing ALWAYS-EMITTED may call one (TestMain's NURSERY PIN).
      seat "Rt.gcScavenge" 1
    , seat "Rt.gcScavRoots" 1
    , -- ZIGHOST Z1: the values table's scavenge twin (young builds only, the
      -- same build-conditional seating as the rest of this family).
      seat "Rt.gcScavValuesTab" 1
    , seat "Rt.gcScavValue" 1
    , seat "Rt.gcScavValueArray" 2
    , seat "Rt.gcScavPtr" 1
    , seat "Rt.gcScavCopyWords" 3
    , seat "Rt.gcScavRemembered" 1
    , seat "Rt.gcScavOne" 1
    , seat "Rt.gcScavDrain" 1
    , seat "Rt.gcPromoteAlloc" 3
    , -- ===== THE VEC-STORE SEAM (zighost Z2).  These are COLLECTOR seats, not
      -- prims: the young writer's whole job is to write collector state (the
      -- RS bit, the remembered set), and the plain writer is the same seam's
      -- no-barrier arm.  Lower's RawVecStore arm names them directly, so they
      -- are seeded from Mid.Rt.lowerSeatSeeds (plain) and youngGcSeeds
      -- (young — its body lives in runtime.mid's QBE_MIDGC_YOUNG-ONLY region,
      -- exactly like the scavenge family above).
      seat "Rt.vecStorePlain" 3
    , seat "Rt.vecStoreYoung" 3
    ]
