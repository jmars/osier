//! tools/qbe/hostshim.zig — the Zig HOST SHIM the QBE native backend still
//! links against (stage 6 B4, "the shrink").  The ABI surface the generated
//! code used to call from THIS file (rt_frame_enter/leave, rt_apply/
//! rt_apply_tail/rt_tail_known/rt_bounce, rt_die/rt_halt, rt_prim, main) has
//! MOVED INTO Mid-emitted defuns (stage 6 A5 + B0-B2); this object SHRANK to
//! the collector/host seam that stays Zig until stage 7 (zighost):
//!
//!   the Zig GC (vendor/osier-rt gc/values/streams/tables/symbols/prims)
//!   rt_string / rt_con / rt_make_closure / rt_global_closure / rt_vec_* /
//!   rt_raw_alloc / rt_float_text (rt_sym_intern / rt_value_slot / rt_ss_*
//!   are GONE — Mid owns those tables; see the O5 notes below)
//!   the shadow-stack root seats (rt_root_*, rt_gc_root_*, rt_gc_heap_bytes)
//!   the driver host half: rt_boot / rt_parse_arg / rt_argv_install /
//!   rt_is_program / rt_run_program / rt_print_value (called by Mid Rt.main)
//!   the rt_prim_* direct per-prim entries (the QBE_NOPRIMDIRECT arm is
//!   DELETED — its generic rt_prim symbol no longer exists, so that hatch is
//!   EMIT-ONLY and cannot LINK)
//!
//! GC CONTRACT (docs/gc-zig.md mutator rules): the collector is precise and
//! moving; anything held across an allocating call must be reachable from a
//! shadow-stack root.  The generated code's root set is now the MID frame
//! machinery (q_Rt_x2eframeEnter/Leave), which registers into the Zig shadow
//! stack through the rt_root_* seats below (plan correction C1: the Mid
//! frames register roots into the Zig shadow stack; it dies at stage 7).
//!
//! This file is compiled by tools/qbe/rt-o.sh to tools/qbe/rt.o (the output
//! path is UNCHANGED so callers and the committed object keep working).

const std = @import("std");

// Raw libc write (the driver runs without the Zig start machinery, so there
// is no initialized std.Io to write through).
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

fn werr(msg: []const u8) void {
    _ = write(2, msg.ptr, msg.len);
}

fn wout(msg: []const u8) void {
    _ = write(1, msg.ptr, msg.len);
}
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const rt_mod = @import("rt");
const values = rt_mod.values;
const state = rt_mod.state;
const symbols = rt_mod.symbols;
const tables = rt_mod.tables;
const streams = rt_mod.streams;
// (src/effectloop.zig is DELETED at O4 — the Mid host is the only host.)

const Gc = heap.Gc;
const Value = types.Value;

/// The static-arity ceiling, mirrored from Mid.Qbe.Lower.maxArity (the
/// rt_callN dispatch-table bound).  Generated functions of arity <= max_arity
/// have a dispatcher; the host applier's saturation buffer is sized to it.
/// NOT a QBE/ABI limit — QBE's call takes any fixed arg list; the table is
/// just how a runtime code pointer bridges to a fixed-arity call.
const max_arity: i32 = 16;

/// Mirrors `type :desc = align 8 { l, w, w }` + the global-closure cache
/// word emitted by Mid.Qbe.Lower (`{ DRef fn, w arity, w ncaps, z 8 }`).
pub const Desc = extern struct {
    code: *const anyopaque, // the QBE function
    arity: i32, // STATIC arity (params of the Lam)
    ncaps: i32, // captures the function reads from env
    cache: ?*Value, // rt_global_closure's one-slot value cache (defuns only)
};

/// One row of the emitted `$qbe_meta` table.
pub const Meta = extern struct {
    name: [*:0]const u8,
    code: *const anyopaque,
    arity: i32,
};

/// The call-result shape every generated function returns — the bounce-loop
/// convention transcribed from the retired AOT runtime's `Ret = .done | .tail`
/// MUST be ABI-identical to the QBE `:ret` aggregate (Il.retType:
/// `type :ret = align 8 { :val, w, l, l, l, w }`), i.e. 80 bytes:
///   val   @0   (40) the finished value when kind == 0 (`.done`);
///   kind  @40  (4)  discriminator: 0 = done, 1 = tail;
///   f     @48  (8)  the callee code pointer (`.tail`);
///   e     @56  (8)  the captures array (env), or null;
///   args  @64  (8)  the `arity` Value structs, in a fresh GC array (built by
///                  the Mid Rt.apply-tail / Rt.tail-known);
///   arity @72  (4)  the static arity == `args` length.
/// A `.tail`'s `args`/`e` are built by the Mid apply/tail defuns and survive
/// the caller's frame-leave because NO collection runs between the .tail
/// build and the next callee's prologue blitting them into its own rooted
/// frame (the AOT's single-referee buildEnv invariant).
pub const Ret = extern struct {
    val: Value,
    kind: i32,
    f: ?*const anyopaque,
    e: ?[*]Value,
    args: ?[*]Value,
    arity: i32,
};

comptime {
    if (@sizeOf(Ret) != 80) @compileError("qbe rt: Ret must be 80 bytes to match the QBE :ret aggregate");
}

// ---------------------------------------------------------------------
//  THE LAYOUT CENSUS — the numbers are DEFINED IN MID
// ---------------------------------------------------------------------
// `Mid/RtLayout.elm` is the single definition; `gc/layout_gen.zig` is that
// definition as Zig constants (regenerated by tools/qbe/layout-census.sh
// --gen).  Desc/Meta/Ret live in THIS file, which the census's probe cannot
// import, so the correspondence is asserted here, at comptime, and a mismatch
// fails the BUILD rather than reading another struct's bytes at the wrong
// offset at run time.  THE COMPILER OF THIS FILE IS tools/qbe/rt-o.sh — `zig
// build gate` compiles vendor/osier-rt/src/rt.zig, a DIFFERENT file — so this
// (Desc/Meta/Ret) half of the contract is checked at rt.o build time and NOT
// by the GC suite.  layout-census.sh cannot verify the values either (its
// probe cannot import this file); what it does check is that the row below
// still NAMES every constant.
comptime {
    const L = gc.layout_gen;
    if (@sizeOf(Desc) != L.descTotalBytes) @compileError("qbe rt: @sizeOf(Desc) != Mid.RtLayout.descTotalBytes");
    if (@offsetOf(Desc, "code") != L.descCodeOffset) @compileError("qbe rt: Desc.code is not at Mid.RtLayout.descCodeOffset");
    if (@offsetOf(Desc, "arity") != L.descArityOffset) @compileError("qbe rt: Desc.arity is not at Mid.RtLayout.descArityOffset");
    if (@offsetOf(Desc, "ncaps") != L.descNcapsOffset) @compileError("qbe rt: Desc.ncaps is not at Mid.RtLayout.descNcapsOffset");
    if (@offsetOf(Desc, "cache") != L.descCacheOffset) @compileError("qbe rt: Desc.cache is not at Mid.RtLayout.descCacheOffset");
    if (@sizeOf(Meta) != L.metaSizeBytes) @compileError("qbe rt: @sizeOf(Meta) != Mid.RtLayout.metaSizeBytes");
    if (@offsetOf(Meta, "name") != L.metaNameOffset) @compileError("qbe rt: Meta.name is not at Mid.RtLayout.metaNameOffset");
    if (@offsetOf(Meta, "code") != L.metaCodeOffset) @compileError("qbe rt: Meta.code is not at Mid.RtLayout.metaCodeOffset");
    if (@offsetOf(Meta, "arity") != L.metaArityOffset) @compileError("qbe rt: Meta.arity is not at Mid.RtLayout.metaArityOffset");
    if (@sizeOf(Ret) != L.retSizeBytes) @compileError("qbe rt: @sizeOf(Ret) != Mid.RtLayout.retSizeBytes");
    if (@offsetOf(Ret, "val") != L.retValOffset) @compileError("qbe rt: Ret.val is not at Mid.RtLayout.retValOffset");
    if (@offsetOf(Ret, "kind") != L.retKindOffset) @compileError("qbe rt: Ret.kind is not at Mid.RtLayout.retKindOffset");
    if (@offsetOf(Ret, "f") != L.retFOffset) @compileError("qbe rt: Ret.f is not at Mid.RtLayout.retFOffset");
    if (@offsetOf(Ret, "e") != L.retEOffset) @compileError("qbe rt: Ret.e is not at Mid.RtLayout.retEOffset");
    if (@offsetOf(Ret, "args") != L.retArgsOffset) @compileError("qbe rt: Ret.args is not at Mid.RtLayout.retArgsOffset");
    if (@offsetOf(Ret, "arity") != L.retArityOffset) @compileError("qbe rt: Ret.arity is not at Mid.RtLayout.retArityOffset");
    if (max_arity != L.maxArity) @compileError("qbe rt: max_arity != Mid.RtLayout.maxArity");
}

extern fn rt_call0(f: ?*const anyopaque, e: ?[*]Value) callconv(.c) Ret;
extern fn rt_call1(f: ?*const anyopaque, e: ?[*]Value, a0: *Value) callconv(.c) Ret;
extern fn rt_call2(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value) callconv(.c) Ret;
extern fn rt_call3(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value) callconv(.c) Ret;
extern fn rt_call4(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value) callconv(.c) Ret;
extern fn rt_call5(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value) callconv(.c) Ret;
extern fn rt_call6(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value) callconv(.c) Ret;
extern fn rt_call7(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value) callconv(.c) Ret;
extern fn rt_call8(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value) callconv(.c) Ret;
extern fn rt_call9(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value) callconv(.c) Ret;
extern fn rt_call10(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value) callconv(.c) Ret;
extern fn rt_call11(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value) callconv(.c) Ret;
extern fn rt_call12(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value, a11: *Value) callconv(.c) Ret;
extern fn rt_call13(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value, a11: *Value, a12: *Value) callconv(.c) Ret;
extern fn rt_call14(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value, a11: *Value, a12: *Value, a13: *Value) callconv(.c) Ret;
extern fn rt_call15(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value, a11: *Value, a12: *Value, a13: *Value, a14: *Value) callconv(.c) Ret;
extern fn rt_call16(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value, a8: *Value, a9: *Value, a10: *Value, a11: *Value, a12: *Value, a13: *Value, a14: *Value, a15: *Value) callconv(.c) Ret;

// =====================================================================
//  Global state (set once in rt_boot)
// =====================================================================

var g: *Gc = undefined;
var vm: *state.Vm = undefined;

// =====================================================================
//  rt_global_closure's arena (the only surviving frame-pool remnant)
// =====================================================================
// B4 deleted the pooled-frame machinery (rt_frame_enter/leave moved to Mid).
// frame_alloc survives: rt_global_closure allocates its one-slot per-defun
// closure cache from it (the cached Value holds NO GC pointers — static
// Desc* code + null env — so it is the forever-root class rt_frame_leave
// used to unroot; rtInit still wires it, but only once, from rt_boot and
// rt_string, never from inside a generated frame).

var frame_alloc: std.heap.ArenaAllocator = undefined;
var rt_inited = false;

fn rtInit() void {
    if (!rt_inited) {
        frame_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        rt_inited = true;
    }
}

fn zeroValue() Value {
    return .{ .tag = .number, .payload = .{ .number = 0 } };
}

// =====================================================================
//  Static-literal caches: rt_string interning
// =====================================================================

// QBE_RT_COUNTS=1 prints one exit-time line of RUNTIME mechanism counters on
// stderr (the QBE_GC_STATS precedent: stdout is never touched, and the
// default run is unchanged).  These count rt_string's interning; the static
// `.ssa` census (rt_string SITE counts) is invariant by construction — no
// emitter was touched — so the runtime counters are the ones that can move.
var rt_string_calls: u64 = 0; // every rt_string entry
var intern_hits: u64 = 0; // already-interned symbol (no allocation)
var intern_misses: u64 = 0; // first evaluation of a symbol (ONE allocation, then cached)
var intern_fallbacks: u64 = 0; // hatch off / table full — the old per-call allocation

// ---- rt_string interning, per static data symbol ----
//
// MEASURED (handoff-osier-midpasses-plan, 2026-10-10): rt_string is called
// PER LITERAL EVALUATION — every time a string literal's code path runs, a
// fresh GC string is allocated.  A literal's bytes live in ONE static data
// symbol per source SITE (Mid.Qbe.Lower's `strname`), and that symbol's
// address is passed here, so the address IS the site's identity: intern once
// per site and hand back the SAME Value for the rest of the run.
//
// WHY THIS IS OBSERVABLE-SAFE: string values are compared by CONTENT

// `strSlice`), never by identity — so returning one object where there used
// to be many cannot change what a program prints or computes.
//
// ROOTING, and why this is NOT rt_global_closure's shape.  A closure cache
// slot holds NO GC pointers, so rt_frame_leave's rootPopTo may unroot it (see
// rt_frame_leave).  An interned string IS a heap pointer and must stay rooted
// for the life of the program, so the value array is registered as ONE
// ROOT_VALUE_ARRAY with a live count — pushed by internInit from MAIN, before
// any generated code can enter a frame, and never lazily from inside one.
const intern_cap: usize = 2048; // interned symbols; 2.7x the whole compiler's 747
const intern_slots: usize = intern_cap * 2; // power of two, never more than half full
var intern_vals: [intern_cap]Value = undefined;
var intern_live: i32 = 0;
// ONE 16-byte entry per slot (key + value index), not two parallel arrays:
// the probe is a random access into this table on every rt_string call, and
// two arrays means two cache lines per probe.  Sized so the table (64 KB at
// intern_cap 2048) stays near-resident; a table that overflows L2 makes the
// hit path cost roughly what the allocation it replaces did — measured on the
// earlier 655 KB shape, where the interning was a wash on a string-hot probe.
const InternEnt = extern struct { key: usize, idx: u32 };
var intern_tab: [intern_slots]InternEnt = [_]InternEnt{.{ .key = 0, .idx = 0 }} ** intern_slots; // key 0 = empty (a data symbol is never at address 0)
var intern_rooted = false;
var no_string_intern = false; // QBE_NOSTRINGINTERN=1: the A/B hatch (set in main)

fn internInit() void {
    if (intern_rooted) return;
    g.rootPushValueArray(&intern_vals, &intern_live);
    intern_rooted = true;
}

fn internHash(key: usize) usize {
    var h = key *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return h & (intern_slots - 1);
}

// =====================================================================
//  Constructors
// =====================================================================

export fn rt_string(data: [*]const u8, len: i32) callconv(.c) Value {
    rtInit();
    rt_string_calls += 1;
    // The table is only sound once its root array exists (internInit, main).
    std.debug.assert(intern_rooted);
    const key = @intFromPtr(data);
    var i = internHash(key);
    // insertions stop at intern_cap == intern_slots/2, so the probe always
    // meets an empty slot and terminates.
    while (intern_tab[i].key != 0) : (i = (i + 1) & (intern_slots - 1)) {
        if (intern_tab[i].key == key) {
            intern_hits += 1;
            return intern_vals[intern_tab[i].idx];
        }
    }
    if (no_string_intern or intern_live >= intern_cap) {
        intern_fallbacks += 1;
        return values.valString(g, data[0..@intCast(len)]);
    }
    const v = values.valString(g, data[0..@intCast(len)]);
    // no allocation between the probe above and these stores, so `i` is still
    // this key's empty slot (the table is not GC memory and cannot move).
    intern_tab[i] = .{ .key = key, .idx = @intCast(intern_live) };
    intern_vals[@intCast(intern_live)] = v;
    intern_live += 1;
    intern_misses += 1;
    return v;
}

/// The closure Value of a top-level defun — CACHED per descriptor in a
/// malloc'd, forever-rooted slot (the native mirror of the VM's defun
/// table, which also stores one closure per defun).
export fn rt_global_closure(desc: *Desc) callconv(.c) Value {
    if (desc.cache) |slot| return slot.*;
    const slot = frame_alloc.allocator().create(Value) catch @panic("qbe-rt: oom");
    slot.* = .{
        .tag = .lambda,
        .payload = .{ .lambda = .{
            .code = @ptrCast(desc),
            .code_len = desc.arity,
            .env = null,
            .env_len = 0,
        } },
    };
    g.rootPushValue(slot); // never popped: the closure lives for the program
    desc.cache = slot;
    return slot.*;
}

/// A closure with captures.  `caps` points into the CALLER's pooled frame
/// (a stable address whose CONTENTS the GC rewrites in place), and
/// values.valLambda roots and copies it exactly like the VM's own `cur`
/// instruction does — the audited path.
export fn rt_make_closure(desc: *Desc, caps: ?[*]Value, ncaps: i32) callconv(.c) Value {
    return values.valLambda(g, @ptrCast(desc), desc.arity, caps, ncaps);
}

/// ADT construction — the VM's MX representation (a vector[tag, a1..an]),
/// built exactly like the ZINC `Con` emission (Symbol tag; absvector n+1;
/// address-> x n+1): values.valVector for the array, then a write-barrier
/// store per element.  `tag` and `args` point into the CALLER's pooled frame
/// (rooted, so their CONTENTS are GC-rewritten in place); the vector is
/// rooted across the stores.  `args` may be null when `nargs == 0` (the
/// element loop is never entered).
export fn rt_con(tag: *Value, args: [*]Value, nargs: i32) callconv(.c) Value {
    const n: usize = @intCast(nargs);
    var acc = values.valVector(g, @intCast(n + 1));
    g.rootPushValue(&acc);
    defer g.rootPop();
    const data = acc.payload.vector.data.?;
    // tag.* is read AFTER valVector's allocArray (the caller's slot was
    // GC-rewritten in place); writeBarrierVectorStore is alloc-free.
    g.writeBarrierVectorStore(data, 0, tag.*);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        g.writeBarrierVectorStore(data, i + 1, args[i]);
    }
    return acc;
}

// =====================================================================
//  Rt raw-node seats (handoff osier-consspike) — the two C symbols the
//  Unsafe-node lowering (Mid.Qbe.Lower's RT RAW NODES section) calls.
//  These are the GC level under Mid.RtPrims' bodies: exactly what
//  values.zig's constructors do, exported once so the lowering carries no
//  second copy of the contracts.
// =====================================================================

/// `RawAllocVector n` — the GC array level: allocate `n` Value elements
/// (g.allocArray, the same seat values.valVector/valCons allocate through).
/// This is the ONE safepoint the raw nodes introduce: the caller's live
/// Values must be rooted across it (the QBE lowering keeps every Value in
/// the rooted pooled frame, so they are), and the RETURN is a raw address
/// held in a generated temp — invalid across any LATER safepoint, by the
/// discipline documented at Mid.Ir's UnsafeNode header.  The array's
/// contents are NOT zeroed: the builder fills every element before the next
/// safepoint (valVector/valCons obey the same contract on the Zig side).
export fn rt_vec_alloc(n: i32) callconv(.c) [*]Value {
    return g.allocArray(Value, @intCast(n));
}

/// `RawVecStore vec i val` — element store behind the collector's ONE
/// barrier seat, heap.zig writeBarrierVectorStore: the store, then the
/// remembered-set record iff the array is old-gen AND the stored value
/// references the nursery.  `val` points into the caller's rooted frame
/// slot (read immediately — nothing allocates in here, including
/// dirtyVectorsAdd, which is page_allocator/malloc-class: MEASURED at
/// heap.zig dirtyVectorsAdd — so the caller's raw vec temp also stays
/// valid across this call).
export fn rt_vec_store(vec: [*]Value, i: i32, val: *const Value) callconv(.c) void {
    g.writeBarrierVectorStore(vec, @intCast(i), val.*);
}

// =====================================================================
//  Rt raw-node seats, step 5 (handoff osier-midprims) — the byte-level

//  above: the lowering carries no second copy of it.
// =====================================================================

/// `RawAllocRaw n` — the GC_STR level: n raw bytes (g.allocRaw).  The ONE
/// string-prim safepoint: the caller's live Values must be rooted across it
/// (the QBE lowering keeps every Value in the rooted pooled frame), and the
/// returned address is a raw temp valid only to the next safepoint.  The
/// buffer is NOT zeroed — the builder writes every byte before the next
/// safepoint (values.valString/valStringFrom obey the same contract).
export fn rt_raw_alloc(n: i32) callconv(.c) [*]u8 {
    return g.allocRaw(@intCast(n));
}

// =====================================================================
//  Mid mark-sweep collector seats (zigretire stage 4)
// =====================================================================
// The Mid-written collector (QBE_MIDGC=1) owns a SEPARATE mmap'd heap and
// routes the two raw allocating nodes through its Mid seats Rt.allocVector /
// Rt.allocRaw.  The ROOT SET stays Zig-managed: the shadow stack below is
// still pushed by rt_frame_enter / rt_apply / rt_con etc., and these seats
// expose it to the Mid walker as alloc-free word->word calls.  The Zig GC
// remains untouched as the differential oracle.

/// The plain (NO write-barrier) vector store the Mid collector's non-moving
/// heap needs.  `rt_vec_store` above goes through writeBarrierVectorStore,
/// whose `inOldgen` page test indexes the ZIG heap's metadata by
/// (addr/512 - firstheappage) — for a Mid-heap address that index is garbage
/// and the barrier reads out of bounds.  A mark-sweep has no remembered set,
/// so the store is the whole of the contract.
export fn rt_vec_store_plain(vec: [*]Value, i: i32, val: *const Value) callconv(.c) void {
    vec[@intCast(i)] = val.*;
}

/// THE NURSERY'S WRITE BARRIER (GC NURSERY unit, stage B).  The store half of
/// the remembered set: store the Value, then — iff the VECTOR is an OLD
/// live value-array of the Mid heap AND the stored Value REFERENCES the young
/// space — record the vector's block address once (the RS bit, bit 61 of the
/// block's flags word, dedups; the scavenge's remembered walk clears it).
/// This is the SAME policy the Zig collector's writeBarrierVectorStore uses
/// on its own heap, spelled against the MID region's slots, which the caller
/// (Lower's RawVecStore emission under QBE_MIDGC_YOUNG) passes.  (That
/// comment used to say this file could NOT reference the block — the block is
/// emitted unconditionally since stage 6 B0; see THE MID GLOBALS BLOCK note
/// above rt_boot.)
///
/// REGION SLOT MAP (the mirror of runtime.mid's struct Region — offsets are
/// load-bearing and TestMain pins the declaration):
///   word 2 heapStart, 3 cursor, 25 bmPtr, 28 young, 29 youngStart,
///   30 youngEnd, 31 youngCursor, 32 rsBase, 33 rsTop, 34 rsEnd.
/// The young test uses [youngStart, youngCursor) — only ALLOCATED young
/// blocks are addressable.  A young VECTOR is not recorded (young->young is
/// the scavenge's own transitive closure); a target outside the Mid heap
/// (the C-heap rooted arrays — the exec-plan evals at h+8 — the frames) is
/// not recorded either: those are ROOTS, the root walk already scans them.
const RS_BIT: u64 = 1 << 61;

export fn rt_vec_store_young(vec: [*]Value, i: i32, val: *const Value, region: usize) callconv(.c) void {
    vec[@intCast(i)] = val.*;

    // THE MID REGION IS LAZY: rt_glob word 0 is 0 (the .bss zero) until the
    // first Mid allocation runs gcInit.  A vecstore that precedes ANY Mid
    // allocation — e.g. hostapply's `run` arm stores into its malloc'd blob
    // before its churn's first allocraw — hands the barrier a NULL region;
    // dereferencing w[28] here SIGSEGVs (the hostapply flip blocker).  The
    // store itself is already done, so a NULL region means "nothing to
    // remember yet" and is the plain-store case exactly like young-off.
    if (region == 0) return;

    const w: [*]u64 = @ptrFromInt(region);
    if (w[28] == 0) return; // the nursery is off at run time — plain store

    const vaddr = @intFromPtr(vec);
    const ystart = w[29];
    const ycursor = w[31];
    if (vaddr >= ystart and vaddr < w[30]) return; // young vector: no record

    // does the stored Value reference young?  the pointer tags and their
    // payload words mirror Rt.gcMarkValue exactly (1 string / 4 cons /
    // 9 error / 10 vector: word 1; 6 lambda / 14 record: words 1 AND 3)
    const cells: [*]const u64 = @ptrCast(val);
    const tag = @as(u32, @truncate(cells[0]));
    const refs_young = switch (tag) {
        1, 4, 9, 10 => refsYoung(cells[1], ystart, ycursor),
        6, 14 => refsYoung(cells[1], ystart, ycursor) or refsYoung(cells[3], ystart, ycursor),
        else => false,
    };
    if (!refs_young) return;

    // the vector must be an OLD LIVE VALUE-ARRAY: inside [heapStart, cursor),
    // block-map state 1 (LIVE), kind bit 1 (value array).  Anything else is
    // either dead (drop) or not a GC block at all (the rooted C arrays).
    const heap_start = w[2];
    if (vaddr < heap_start or vaddr >= w[3]) return;
    const bm: [*]const u8 = @ptrFromInt(w[25]);
    if (bm[(vaddr - heap_start) / 64] != 1) return;
    const hdr: [*]u64 = @ptrFromInt(vaddr - 16);
    if (((hdr[0] >> 1) & 1) != 1) return;

    if ((hdr[0] & RS_BIT) != 0) return; // already remembered this cycle
    hdr[0] |= RS_BIT;

    const rs: [*]u64 = @ptrFromInt(w[32]);
    const top = w[33];
    if (top >= w[34]) {
        werr("qbe-rt: midgc: remembered set overflow (capacity capBytes/64; raise the heap or report)\n");
        std.process.exit(1);
    }
    rs[top] = vaddr;
    w[33] = top + 1;
}

inline fn refsYoung(p: u64, ystart: u64, ycursor: u64) bool {
    return p >= ystart and p < ycursor;
}

/// The configured heap size (main's QBE_HEAP_MB, in bytes).  The Mid
/// collector mmaps its own region of this size so the churn differential's
/// QBE_HEAP_MB sweeps steer both arms alike.
export fn rt_gc_heap_bytes() callconv(.c) i64 {
    return @intCast(gc_heap_bytes);
}

var gc_heap_bytes: usize = 0;

// (stage 6 U1c) The Mid collector's region pointer no longer lives here:
// the two seats that served it are DELETED.  It moved to the Mid-owned
// globals block (`$rt_glob`, .bss) at word 0, addressed through the
// Lower-built `rt_glob_addr` accessor — plan correction C3 (the "no
// mutable-global-state facility" gap is refuted).  The BRIDGES row is
// updated to REMOVED in the same change; this file must not carry the old
// seat names (the row asserts `rg` finds none).

/// Shadow-stack bridge: the Mid mark walk reads the SAME precise roots the
/// Zig collector's scanRoots walks, entry by entry.  RootKind is u32:
/// ROOT_PTR=0 (slot is *usize), ROOT_VALUE=1 (slot is *Value),
/// ROOT_VALUE_ARRAY=2 (slot is [*]Value, count read from *np),
/// ROOT_VALUE_VOLATILE=3 (slot is *Value), ROOT_CALLFRAME_ARRAY=4 (VM-only,
/// unreachable on the native path — the Mid walker fails loudly on it).
export fn rt_gc_roots_len() callconv(.c) i64 {
    return @intCast(g.shadow_len);
}

export fn rt_gc_root_kind(i: i64) callconv(.c) i64 {
    return @intCast(@intFromEnum(g.shadow_stack[@intCast(i)].kind));
}

export fn rt_gc_root_slot(i: i64) callconv(.c) i64 {
    return @bitCast(@intFromPtr(g.shadow_stack[@intCast(i)].slot));
}

export fn rt_gc_root_np(i: i64) callconv(.c) i64 {
    const np = g.shadow_stack[@intCast(i)].np orelse return 0;
    return @bitCast(@intFromPtr(np));
}

/// Stage-6 U1b root seats: the Mid frame machinery's root-registration
/// surface.  Each is a thin C-ABI word->word bridge over the vendored
/// shadow-stack API (vendor/osier-rt/src/gc/roots.zig — rootPushPtr :85,
/// rootPushValue :94, rootPushValueArray :120, rootPop :149, rootPopTo :159,
/// rootWatermark :167).  Alloc-free BY CONTRACT from the collector's view:
/// a push may grow the shadow stack, but shadowStackGrow uses the page
/// allocator and runs NO collect (roots.zig:120-128 — rootPushValueArray's
/// body; the grow fn is :59-83), so Mid bodies may call
/// these under RawCallRaw's no-safepoint contract.  Each seat is a BRIDGE
/// removed at stage 7 (BRIDGES table, plan.md §3 Phase 4b).
///
/// rt_root_watermark / rt_root_pop_to carry the shadow-stack DEPTH the frame
/// machinery snapshots at enter and truncates back to at leave — popTo(wm),
/// never a bare pop: when anything (e.g. rt_global_closure's forever-root)
/// pushed between enter and leave, a bare rootPop pops the WRONG entry, the
/// frame's ROOT_VALUE_ARRAY LEAKS, and every later GC scans the freed
/// block's stale slots (the historical qbe-gcbug; rt_frame_leave's comment
/// below is the spec).  The i64 results are never read (the rt_halt
/// convention: the word-level call shape stays valid IL).
export fn rt_root_push_value_array(base: i64, np: i64) callconv(.c) i64 {
    gc.roots.rootPushValueArray(g, @ptrFromInt(@as(usize, @bitCast(base))), @ptrFromInt(@as(usize, @bitCast(np))));
    return 0;
}

export fn rt_root_push_value(ptr: i64) callconv(.c) i64 {
    gc.roots.rootPushValue(g, @ptrFromInt(@as(usize, @bitCast(ptr))));
    return 0;
}

export fn rt_root_push_ptr(ptr: i64) callconv(.c) i64 {
    gc.roots.rootPushPtr(g, @ptrFromInt(@as(usize, @bitCast(ptr))));
    return 0;
}

export fn rt_root_pop() callconv(.c) i64 {
    gc.roots.rootPop(g);
    return 0;
}

export fn rt_root_watermark() callconv(.c) i64 {
    return @intCast(gc.roots.rootWatermark(g));
}

export fn rt_root_pop_to(wm: i64) callconv(.c) i64 {
    gc.roots.rootPopTo(g, @intCast(wm));
    return 0;
}

// =====================================================================
//  (DELETED AT O5) the string-stream seats rt_ss_in/rt_ss_readbyte/
//  rt_ss_close — the registry is Mid-owned now (runtime.mid's Region slots
//  38..39 + Rt.ssTab/ssIn/ssInGo/ssReadbyte/ssClose), a lazily-malloc'd
//  8-cell C-heap table; no Zig seat remains.
// =====================================================================
//  (PARTIALLY DELETED AT O5 SEAT 2) rt_sym_intern is GONE — the intern
//  table is Mid-owned now (runtime.mid's Rt.intTab/intFindGo/intBytesEq/
//  intStrCopy/intPairsCopy over the GLOBALS BLOCK words 8208..8210): a
//  linear byte-compare find-or-insert (every measured call site is a
//  rawstr literal; 9 distinct names).  No Zig seat remains.
//  (DELETED AT O5 SEAT 3) rt_value_slot is GONE — the LOOKUP is Mid's now
//  (runtime.mid's Rt.valScanGo/Rt.value).  The TABLE is still this file's:
//  it is what rt_boot/rt_argv_install install the three standard streams and
//  *argv* into, so the host keeps the storage and PUBLISHES its base into
//  the Mid globals block (rt_glob[3]) for the Mid walk to read.
//  rt_float_text below stays until its own seat.
// =====================================================================
//

// =====================================================================
//  THE MID GLOBALS BLOCK, FROM THE ZIG SIDE
//
//  `export data $rt_glob` (.bss) is emitted by Mid.Qbe.Lower's finishModule
//  UNCONDITIONALLY (stage 6 B0 — the Mid frame pair always reads it), and
//  rt.o cannot be linked without a Mid-emitted module: B4 deleted the Zig
//  `main`, so the seed's Mid `main` is the only one (qbe-bootstrap.sh step
//  4/4).  So a reference from this file resolves in every link rt.o takes
//  part in — the stale "this file cannot reference $rt_glob" note above
//  rt_vec_store_young predates B0 and is corrected here.
//
//  Word indices are Mid.RtGc's LAYOUT table.  The values-table base (word 3)
//  is the ONE word this file writes: every other slot is Mid's own state.
// =====================================================================
extern var rt_glob: [8208]u64; // RtGc.globWords — keep the two in step

/// The globals-block word holding `vm.values_table`'s base (RtGc's layout
/// table, word 3).  Written once, by rt_boot, before any generated code runs.
/// WORD 1 IS TAKEN: it is the frame machinery's current-frame pointer
/// (runtime.mid's frame-enter/frame-leave `wstore(glob, 1, hdr)`), so a value
/// parked there survives only until the next frame push — MEASURED, that is
/// exactly how the first draft of this handoff failed.  3..7 are free (2 is
/// the no-reuse knob, 8..11 the driver knobs).
const GLOB_VALUES_TAB: usize = 3;

/// str's float-arm seat: render `bits` (an f64's raw bits) through
/// values.floatText into a static BSS buffer and return a pointer to a
/// { len: i64, data: [64]u8 } the Mid body copies into a GC string.  The 64-
/// byte data is primStr's own buf[64] bound (a `{d}` text longer than it
/// panics — the Zig reference behaviour, kept).  Static BSS: not moved by the
/// GC, so the pointer stays valid across the Mid body's RawAllocRaw.
///
/// RE-ENTRANCY (why ONE static scratch is sound): the bytes are valid only
/// from the render until the Mid body's Rt.floatCopy has copied them out.
/// That window contains exactly ONE safepoint — the RawAllocRaw itself, whose
/// collectors cannot call Rt.str (the VM is single-threaded and a collection
/// runs no generated code) — and Rt.floatCopy is frame-free (no safepoint).
/// So no second `str` call can interleave and overwrite `float_text_out`
/// before the copy is done.  Any future Rt.str body that adds a second
/// safepoint between this seat and the copy BREAKS this invariant (a nested
/// String.fromFloat would clobber the first call's bytes).
const FloatTextOut = extern struct { len: i64, data: [64]u8 };
var float_text_out: FloatTextOut = .{ .len = 0, .data = undefined };
export fn rt_float_text(bits: i64) callconv(.c) [*]const FloatTextOut {
    const u: u64 = @bitCast(bits);
    const v: f64 = @bitCast(u);
    const s = values.floatText(float_text_out.data[0..], v);
    // values.floatText returns a STATIC literal ("NaN"/"Infinity"/"-Infinity")
    // for the non-finite arms — NOT a slice into `data` — so copy those in;
    // finite floats already render into `data` (a self-copy would be @memcpy
    // UB).  Then set the length last.
    if (@intFromPtr(s.ptr) != @intFromPtr(&float_text_out.data)) {
        @memcpy(float_text_out.data[0..s.len], s);
    }
    float_text_out.len = @intCast(s.len);
    return @ptrCast(&float_text_out);
}

// =====================================================================
//  (DELETED AT O4) the effect loop's applier trampoline — bounce /
//  Mid host applies through its own Rt.apply-at, and nothing else called the
//  trampoline.  The rt_call0..16 / rt_call2r EXTERNS below stay: the
//  EMITTED Rt.bounceGo / Rt.apply defuns call them by symbol.
//
// ---------------------------------------------------------------------
//  exec-plan bridge (zigretire stage 3 GROUP 3B-2a..3B-2c): CLOSED.
// ---------------------------------------------------------------------
// The Mid `Rt.exec-plan` body now DECODES the plan into the flat C-heap
// blob, RUNS it (Rt.execGo over RawCallRaw libc seats), and SLURPS+BUILDs
// the TAGGED result itself (Rt.exec-run: lseek+readFileGo per capture fd,
// RawAllocRaw+memGo+mkStr strings, the cons/intern tree).  The rt_exec_run
// seat and the static ep_result_slot are DELETED (3B-2c) — nothing in this
// file reads the exec-plan blob anymore.

// =====================================================================
//  Direct per-prim entries (handoff osier-passa)
// =====================================================================
//  (DELETED AT O4) the rt_prim_* direct per-prim entries — they were
//  generated from rt/prims.zig's table, which is deleted with the Zig host;
//  the current default emits NO rt_prim calls (measured on the whole-compiler
//  .ssa), and every live prim has a Mid implementation or the Mid host.
// =====================================================================
//
fn dieLoud(msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "qbe-rt: {s}\n", .{msg}) catch "qbe-rt: error\n";
    werr(out);
    std.process.exit(1);
}

// =====================================================================
//  The driver seats — the host half the Mid driver (Rt.main) calls
// =====================================================================
// The Mid driver (Rt.main, stage 6 A5) cannot express these yet — the GC's
// bring-up, the entry-argument parse, the *argv* install, the Program
// predicate, the effect loop's entry and the printer — so they are exported
// here, C ABI, for the Mid driver to call.  Every body is a VERBATIM lift of
// the region it came from in the retired Zig `main` (same statements, same
// order, same helper calls, same error text and exit code); B4 deleted that
// Zig `main` itself, leaving only these seats.
//
// THE SHAPE: a seat hands its result back through a caller-provided slot and
// RETURNS the code the driver returns (0 = proceed, 2 = the driver's argument
// error, 1 = a runtime error).  No seat exits the process itself: the
// driver's exit path also runs the GC/RT stats defers, and an exit() inside a
// seat would drop them.
//
// These seats die with the Zig host at stage 7 (zighost), when the effect
// loop ports to Mid.

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

var vmem: state.Vm = undefined;

/// The Gc, promoted from main's stack frame to a global: `rt_boot` creates it
/// and the seats reach it through `g`.  Same lifetime as before — the Mid
/// driver (Rt.main) calls rt_boot and its `defer g.deinit()` still runs at
/// exit.
var gg: Gc = undefined;

/// rt_boot: everything the driver must do before ANY generated code can run —
/// the debug knobs (read ONCE, here), the heap knob, the Gc, the rt_string
/// intern table's root, the Vm, the three standard streams, and the effect
/// loop's host applier.  VERBATIM main:1476-1487 + 1590-1596 + 1599-1630 +
/// 1677-1688 + 1761.  Returns 0, or 1 after the SAME stderr line and exit
/// status as the pre-A2 main (the gc-init failure).
export fn rt_boot() callconv(.c) i64 {
    // Read the debug knob ONCE, here, before any generated code can run.
    // (B4 deleted the SEGV stack-depth net and the no_frame_reuse /
    // no_tail_stage hatches with the Zig frame/tail seats; the Mid driver
    // Rt.main raises the rlimit itself before calling this seat.)
    no_string_intern = std.c.getenv("QBE_NOSTRINGINTERN") != null;

    // heap knob for the GC-churn verification (small heap => many moves)
    const heap_bytes: usize = blk: {
        const env = std.c.getenv("QBE_HEAP_MB") orelse break :blk HEAP_BYTES;
        const s = std.mem.span(env);
        const mb = std.fmt.parseUnsigned(usize, s, 10) catch break :blk HEAP_BYTES;
        if (mb == 0) break :blk HEAP_BYTES;
        break :blk mb * 1024 * 1024;
    };
    gc_heap_bytes = heap_bytes;

    rtInit();
    gg = Gc.init(.{
        .heap_bytes = heap_bytes,
        // GC-FIX C: C's OWN reservation policy (16x the heap), not the 2x the
        // drivers used to pass.  grow_heap asks for a heap of 2 x heappages and
        // needs `new_size + PAGEBYTES - 1 <= reservation`, so a 2x reservation
        // made every grow fail BY CONSTRUCTION ("need N MB but reservation is N
        // MB" — the arithmetic behind the abort at 128 MB, 512 MB and 32768 MB
        // alike).  k x heap gives a heap CEILING of (k/2) x heap, and 16x is
        // MEASURED as the smallest multiplier that keeps a real fixture out of a
        // collect-per-allocation thrash at the minimum heap: at QBE_HEAP_MB=16,
        // tools/qbe/fixtures/vfield.elm's live set reaches 16.1 MB, which needs
        // a threshold just above 16 MB, i.e. a heap over 64.4 MB — unreachable
        // under an 8x reservation (64 MB ceiling), comfortable under a 16x one
        // (128 MB).  Gc.init shrinks the request toward 2x + 1027*PAGEBYTES only
        // if the address space cannot map it.  See heap.Options' "THE GROW
        // ARITHMETIC".
        .reserve_bytes = @max(heap_bytes * 16, RESERVE_BYTES),
        .verbose = std.c.getenv("QBE_GC_VERBOSE") != null,
        .verify_collects = std.c.getenv("QBE_GC_VERIFY") != null,
    }) catch {
        werr("qbe-rt: gc init failed\n");
        return 1;
    };
    g = &gg;
    // The rt_string intern table's root array.  HERE, not in rtInit: rtInit
    // also runs from the Mid frame machinery (q_Rt_x2eframeEnter), i.e. AFTER
    // a frame's watermark is taken, and a root pushed there would be popped by
    // the next frame-leave.  This is the last point that is provably before
    // any generated code — the entry call is far below.
    internInit();
    vmem.init(&gg);
    vm = &vmem;

    // Wire the standard I/O streams (M6) — the SAME three value variables
    // the former VM harness set at the same point.  initGlobals only registers the PRIM
    // globals; the *stinput*/*stoutput*/*sterror* slots are the HOST's to
    // install, and a native program that reads stdin (Cmd.readLine ->
    // read-byte on *stinput*) died with "prim read-byte failed: Halt" before
    // this — the gate's ioecho row is the fixture that catches its absence.
    vmem.valueSet("*stinput*", streams.valStreamInFd(0));
    vmem.valueSet("*stoutput*", streams.valStreamOutFd(1));
    vmem.valueSet("*sterror*", streams.valStreamOutFd(2));

    // O5 seat 3: PUBLISH the values table's base into the Mid globals block,
    // the one place both routes can read it (see THE MID GLOBALS BLOCK note
    // above, and GLOB_VALUES_TAB for why the word is 3 and not 1).  The table
    // is this file's — Vm.init page-allocates it and every write to it is here
    // (the three streams above, *argv* below) — and the LOOKUP is Mid's
    // (Rt.value/Rt.valScanGo), so the pointer is the whole handoff.  Done HERE
    // rather than in Vm.init because the vendored runtime is shared with the
    // Zig interpreter's own test suite, which links no Mid block; the base is
    // stable for the run, so one store is enough.
    rt_glob[GLOB_VALUES_TAB] = @intFromPtr(vmem.values_table);

    // Host the effect loop EXACTLY like the retired harnesses did:
    // install the native host->Elm dispatcher (the seam's default is a loud
    // stub — only a native applier can execute Desc*-coded closures), run the
    // entry, and if it returns a Program vector drive the shared CEK effect manager
    // to the final model.  The Vm already wired *stinput*/*stoutput*/*sterror*
    // in initGlobals, so StreamRef reads the same value-table slots the VM did.
    // Installed HERE, in the bring-up, because nothing before the entry call
    // may depend on it and the Mid driver must not have to reach the seam.
    return 0;
}

/// rt_parse_arg: ONE entry argument -> the Value main builds for it (VERBATIM
/// main:1715-1738's loop body: the isFloatArg heuristic, parseFloat/parseInt,
/// valFloat/valNumber, and both error strings).  Stores the value in `dst` and
/// returns 0, or writes the SAME stderr line and returns 2 for the caller to
/// exit with (the exit code is main's/the driver's to produce).
export fn rt_parse_arg(dst: *Value, arg: [*:0]const u8) callconv(.c) i64 {
    const a = std.mem.span(arg);
    if (isFloatArg(a)) {
        const f = std.fmt.parseFloat(f64, a) catch {
            var buf: [256]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "qbe-rt: entry arg '{s}' is not a float\n", .{a}) catch "qbe-rt: bad entry arg\n";
            werr(out);
            return 2;
        };
        dst.* = values.valFloat(f);
    } else {
        const n = std.fmt.parseInt(i64, a, 10) catch {
            var buf: [256]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "qbe-rt: entry arg '{s}' is not an int (qbe slice)\n", .{a}) catch "qbe-rt: bad entry arg\n";
            werr(out);
            return 2;
        };
        dst.* = values.valNumber(n);
    }
    return 0;
}

/// rt_argv_install: the *argv* pseudo-global for the AOTRUN_ARGV contract
/// (VERBATIM main:1745-1753).  `argv_mode` is the AOTRUN_ARGV test main
/// already makes for the max_arity guard, passed in so the seat has no env
/// logic of its own.
export fn rt_argv_install(argv_mode: i32, nargs: usize, c_argv: [*]?[*:0]u8) callconv(.c) void {
    if (argv_mode != 0) {
        // The list is Zig-heap (valCons/valString below) and valueSet stores
        // it in the Vm's values table — registered with the collector at
        // Vm.init (state.zig's g.registerValuesTable), which is what pins it
        // for the rest of the run.  The SCOPED root here is the lift's own
        // addition: main built the list inside the valueSet call, and the GC
        // contract (rt.zig's header) requires anything held across an
        // allocating call to sit on a shadow-stack root.  It must stay SCOPED:
        // a forever-root pushed here would be the entry main's own deferred
        // `g.rootPop()` (the argv_buf array root, pushed just above) pops
        // instead — the wrong-entry pop rt_frame_leave's comment warns about.
        var list = buildArgvList(nargs, c_argv);
        var rt = g.rootValue(&list);
        defer rt.end();
        vmem.valueSet("*argv*", list);
    } else {
        vmem.valueSet("*argv*", values.valNil());
    }
}

/// rt_print_value: print a Value, then the newline — the driver's output
/// contract (VERBATIM main:1779-1789).  Returns 0, or 1 after the SAME stderr
/// line as the pre-A2 main (the print failure).
///
/// Print through an ALLOCATING writer, not a fixed one: a result whose
/// printed form exceeds any fixed buffer must print in full (the VM runner
/// the VM did the same), so native and VM output agreed at every size.
export fn rt_print_value(final: *const Value) callconv(.c) i64 {
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    values.printValue(&aw.writer, final.*) catch {
        werr("qbe-rt: print failed\n");
        return 1;
    };
    wout(aw.written());
    wout("\n");
    rtCounts();
    return 0;
}

/// QBE_RT_COUNTS=1: the runtime MECHANISM counters, on STDERR, once per run.
/// RE-HOMED (GC-ARC F1, declared): the exit-time print used to live in the Zig
/// `main` that stage 6 B4 DELETED, so from `08e994d` on the counters were
/// incremented by rt_string and never emitted — and probe-midgc-string.sh's
/// runtime half (it greps `rt_string=0` as the structural kill for the
/// `intern_live >= 2048` nursery fallback) was RED at HEAD for that reason, not
/// because of a collector defect.  This is the only surviving hook on the exit
/// path a Mid driver calls (Rt.main -> rt_print_value, once), and it is gated
/// on the knob, so an un-knobbed run is byte-for-byte the same on stdout and
/// silent on stderr.  The three `tail_*` counters are GONE with their seats —
/// the line reports what still has a counter, not the retired shape.
fn rtCounts() void {
    if (std.c.getenv("QBE_RT_COUNTS") == null) return;
    var buf: [192]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[RT COUNTS] rt_string={d} intern_hits={d} intern_misses={d} intern_fallbacks={d} intern_live={d}\n", .{
        rt_string_calls,
        intern_hits,
        intern_misses,
        intern_fallbacks,
        intern_live,
    }) catch return;
    werr(line);
}

/// AOTRUN_ARGV: build the *argv* pseudo-global value — a plain cons LIST of
/// strings (run.js argv[2:] shape), built back-to-front (cdr-first).  The
/// empty case returns the nil singleton (Runtime.argv () -> []).  Mirrors the
/// retired AOT driver's buildArgvList.
///
/// THE ACCUMULATOR IS ROOTED ACROSS THE WHOLE LOOP, and that is a FIX, not
/// decoration (GC-ARC F1): the retired driver rooted only from inside
/// valCons, so `acc` was UNROOTED at the moment `valString`'s allocation ran
/// — a nursery scavenge there (the preemptive trigger fires at ~1 MB, i.e.
/// ~20k argv entries) reclaims the whole tail built so far and *argv* comes
/// back as garbage.  MEASURED pre-fix (default route, AOTRUN_ARGV=1, 60k
/// args): `[GC NURSERY #1 …] non-exhaustive case`; post-fix the same command
/// prints the argument count.  probe-midgc-argv.sh is the fail-before/
/// pass-after.
fn buildArgvList(nargs: usize, c_argv: [*]?[*:0]u8) Value {
    var acc: Value = values.valNil();
    var rt = g.rootValue(&acc); // the SLOT is rooted: a move rewrites acc in place
    defer rt.end();
    var i: usize = nargs;
    while (i > 0) {
        i -= 1;
        acc = values.valCons(g, values.valString(g, std.mem.span(c_argv[2 + i] orelse "")), acc);
    }
    return acc;
}

/// True when a CLI arg is spelled as a float literal.  VERBATIM the heuristic
/// the retired VM/AOT harnesses used, so the former VM reference and the
/// native driver accept the same command line — an arg is a float iff it
/// contains '.'/'e'/'E' or is one of the canonical non-finite tokens
/// (parseFloat accepts all four).  Everything else stays on the int path.
fn isFloatArg(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "NaN") or std.mem.eql(u8, arg, "Infinity") or
        std.mem.eql(u8, arg, "-Infinity")) return true;
    for (arg) |c| {
        if (c == '.' or c == 'e' or c == 'E') return true;
    }
    return false;
}
