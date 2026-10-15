module Mid.RtGc exposing
    ( gcProgram
    , globAddrSym, globDataSym, globFreelistSlot, globKnobSlot, globRegionSlot
    , globTailScratchSlot, globWords
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
created by `Rt.gcInit`; a two-word header before every body (flags =
kind*2 + mark, count); two object kinds (value_array, raw); precise roots
read through the rt_gc_roots_len/rt_gc_root_kind/rt_gc_root_slot/
rt_gc_root_np seats; the trigger inside Rt.gcAlloc (threshold collect,
first-fit free list, bump, exhaustion collect-and-retry); failure is LOUD
through rt_midgc_die.  FRAME-FREE BY CONSTRUCTION: no collector defun
contains an allocating node (no RawAllocVector/RawAllocRaw, no LString, no
WithRoots), so Mid.Rt.allocating leaves every one of them out of the framed
set — pinned by a TestMain row, kept green by the migration.

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
--   words 8..11    driver knobs, getenv read once (U5a)
--   word 12        the single .tail-in-flight scratch (U4a)
--   words 16..     the frame freelist heads, indexed by nslots (U3)
-- The freelist bound is 8192 (MEASURED: the seed's max frame nslots is
-- 4,354; giants never pool).  The block is .bss: reserving the words costs
-- nothing on disk.

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


globTailScratchSlot : Int
globTailScratchSlot =
    12


globFreelistSlot : Int
globFreelistSlot =
    16


globWords : Int
globWords =
    globFreelistSlot + 8192


-- ============================ PROGRAM ============================


{-| The whole collector program: every defun above.  Injected by
Mid.QbeModule when QBE_MIDGC=1 and seeded by Mid.Rt.gcSeeds.  Since T18
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
    , seat "Rt.allocVector" 1
    , seat "Rt.allocRaw" 1
    , seat "Rt.gcAlloc" 3
    , seat "Rt.gcAllocGo" 2
    , seat "Rt.collect" 1
    , seat "Rt.gcMarkRoots" 1
    , seat "Rt.gcScanValueArray" 2
    , seat "Rt.gcDrain" 1
    , seat "Rt.gcSweep" 1
    , seat "Rt.gcMarkPtr" 1
    , seat "Rt.gcMarkValue" 1
    ]
