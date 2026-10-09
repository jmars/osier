//! tools/qbe/rt.zig — the runtime for the QBE native backend (stage 1,
//! handoff-qbe-lower).  Compiled to rt.o and linked with the assembly QBE
//! produced (`tools/qbe/qbe-mk.sh`); every symbol the GENERATED code calls is
//! here, C ABI, matching the call shapes Mid.Qbe.Lower emits:
//!
//!   rt_frame_enter(nslots) -> *Value   pooled, ROOTED frame slots
//!   rt_frame_leave()                    pop the frame + its root
//!   rt_string(ptr, len) -> Value        GC string from static bytes
//!   rt_global_closure(desc) -> Value    the (cached) closure of a defun
//!   rt_make_closure(desc, caps, n) -> Value   closure with captured env
//!   rt_apply(fslot, args, n) -> Value   generic/partial/over application
//!   rt_apply_tail(fslot, args, n) -> Ret   the tail-position twin (returns .tail)
//!   rt_tail_known(code, argblock, n) -> Ret   direct saturated tail call
//!   rt_bounce(ret) -> Value             chase a .tail chain to a .done value
//!   rt_prim(name, args, n) -> Value     the EXACT VM primitive (fallback)
//!   main(entry, args...)                the driver (elmvm-shaped output)
//!
//! GC CONTRACT (docs/gc-zig.md mutator rules): the collector is precise and
//! moving; anything held across an allocating call must be reachable from a
//! shadow-stack root.  The pooled frame IS the root set for generated code:
//! rt_frame_enter registers ONE ROOT_VALUE_ARRAY over all nslots (zeroed at
//! enter — a reused block's stale slots could otherwise point into freed
//! pages, which scanValue would chase).  Frame blocks are malloc-backed
//! (never in the GC heap), so their addresses are stable and the ROOT
//! registration stays valid across moves.  THE ZEROING IS NOT OPTIONAL.
//!
//! WHY POOLED FRAMES AND NOT PER-FUNCTION GLOBALS OR QBE STACK SLOTS: a
//! per-function global frame cannot nest under recursion (a callee would
//! zero its caller's frame), and a non-escaping QBE stack slot is silently
//! DEFEATED — qbe promotes the value into a callee-saved register and deletes
//! the store AND the reload (MEASURED on the vendored qbe; evidence in
//! handoff-qbe-lower-result and docs/qbe-backend.md).  The pooled pointer is
//! an opaque call result, which keeps every slot store/load in the assembly.

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
const scan = gc.scan;
const vm_mod = @import("vm");
const values = vm_mod.values;
const state = vm_mod.state;
const interp = vm_mod.interp;
const prims = vm_mod.prims;
const effectloop = @import("effectloop");

const Gc = heap.Gc;
const Value = types.Value;

/// The static-arity ceiling, mirrored from Mid.Qbe.Lower.maxArity (the
/// rt_callN dispatch-table bound).  Generated functions of arity <= max_arity
/// have a dispatcher; rt_apply's saturation buffers are sized to it.  NOT a
/// QBE/ABI limit — QBE's call takes any fixed arg list; the table is just
/// how rt_apply bridges a runtime code pointer to a fixed-arity call.
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
/// convention transcribed from tools/aot/runtime.zig's `Ret = .done | .tail`.
/// MUST be ABI-identical to the QBE `:ret` aggregate (Il.retType:
/// `type :ret = align 8 { :val, w, l, l, l, w }`), i.e. 80 bytes:
///   val   @0   (40) the finished value when kind == 0 (`.done`);
///   kind  @40  (4)  discriminator: 0 = done, 1 = tail;
///   f     @48  (8)  the callee code pointer (`.tail`);
///   e     @56  (8)  the captures array (env), or null;
///   args  @64  (8)  a fresh GC array of `arity` Value structs;
///   arity @72  (4)  the static arity == `args` length.
/// A `.tail`'s `args`/`e` are freshly allocated by rt_tail_known / rt_apply_tail
/// and survive the caller's rt_frame_leave because NO collection runs between
/// the .tail build and the next callee's prologue blitting them into its own
/// rooted frame (the AOT's single-referee buildEnv invariant).
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

extern const qbe_meta: [*]const Meta;
extern const qbe_meta_len: usize;

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
//  Global state (set once in main)
// =====================================================================

var g: *Gc = undefined;
var vm: *state.Vm = undefined;

// =====================================================================
//  Frame pool
// =====================================================================

const FrameHdr = extern struct {
    live: i32, // ROOT_VALUE_ARRAY's live count (== nslots for our use)
    wm: usize, // shadow-stack watermark at enter (leave pops back to it)
    next: ?*FrameHdr, // active-frame stack
    freelist_next: ?*FrameHdr, // when pooled
    slots: [*]Value, // just past the header
};

var frame_top: ?*FrameHdr = null;
// Free lists keyed by slot count; blocks are never returned to the
// allocator, so after warmup rt_frame_enter is malloc-free.
var freelists: std.AutoHashMapUnmanaged(i32, ?*FrameHdr) = .{};
var frame_alloc: std.heap.ArenaAllocator = undefined;
var rt_inited = false;

/// QBE_NO_REUSE, read ONCE at startup (main) instead of per call.
///
/// It used to be `std.c.getenv("QBE_NO_REUSE")` INSIDE rt_frame_leave, i.e. an
/// env lookup on every generated-function return — measured at 8.4% of the
/// native compiler's runtime (libc `getenv` walking `environ`;
/// handoff-midpass-profile-improve).  main() sets this before any generated
/// code runs, so the debug behaviour is identical.  Kept as a mutable global
/// (not comptime) so the runtime is buildable once and steered by the
/// environment, which is how the debug knob is used.
var no_frame_reuse: bool = false;

fn rtInit() void {
    if (!rt_inited) {
        frame_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        rt_inited = true;
    }
}

fn frameBlock(nslots: i32) *FrameHdr {
    const n: usize = @intCast(nslots);
    if (freelists.getPtr(nslots)) |head| {
        if (head.* != null) {
            const hdr = head.*.?;
            head.* = hdr.freelist_next;
            return hdr;
        }
    }
    const a = frame_alloc.allocator();
    const bytes = a.alignedAlloc(u8, .@"8", @sizeOf(FrameHdr) + @sizeOf(Value) * n) catch
        @panic("qbe-rt: frame pool out of memory");
    const hdr: *FrameHdr = @ptrCast(bytes.ptr);
    hdr.* = .{ .live = 0, .wm = 0, .next = null, .freelist_next = null, .slots = @ptrCast(bytes.ptr + @sizeOf(FrameHdr)) };
    return hdr;
}

export fn rt_frame_enter(nslots: i32) callconv(.c) [*]Value {
    rtInit();
    const hdr = frameBlock(nslots);
    // Zero BEFORE rooting: a reused block's stale slots can point into
    // freed GC pages; scanValue would chase them.  (MEASURED constraint —
    // this is a correctness memset, not a nicety.)
    @memset(hdr.slots[0..@intCast(nslots)], zeroValue());
    hdr.live = nslots;
    hdr.wm = g.rootWatermark();
    hdr.next = frame_top;
    frame_top = hdr;
    g.rootPushValueArray(hdr.slots, &hdr.live);
    return hdr.slots;
}

export fn rt_frame_leave() callconv(.c) void {
    const hdr = frame_top orelse @panic("qbe-rt: rt_frame_leave with no frame");
    frame_top = hdr.next;
    // Pop back to the enter-time watermark, NOT the top: rt_global_closure
    // pushes a never-popped root for its cache slot, and when that call
    // happens between rt_frame_enter and rt_frame_leave the top of the
    // shadow stack is the cache-slot reg, not this frame's.  A bare
    // rootPop() then pops the WRONG entry — the frame's ROOT_VALUE_ARRAY
    // reg LEAKS and every later GC scans the freed block's stale slots
    // (the qbe-gcbug segfault / 'gcalloc: object too large (-8)' panic).
    // Dropping the cache-slot root here is safe: the cached closure Value
    // holds NO GC pointers (static Desc* code, null env), so it never
    // needed scanning.  Any future forever-root pushed inside a frame must
    // hold no GC pointers, or this contract breaks.
    g.rootPopTo(hdr.wm);
    const n = hdr.live;
    if (no_frame_reuse) return; // debug: never reuse (flag set in main)
    const head = freelists.getOrPut(std.heap.page_allocator, n) catch @panic("qbe-rt: freelist oom");
    if (!head.found_existing) head.value_ptr.* = null;
    hdr.freelist_next = head.value_ptr.*;
    head.value_ptr.* = hdr;
}

fn zeroValue() Value {
    return .{ .tag = .number, .payload = .{ .number = 0 } };
}

// =====================================================================
//  Constructors
// =====================================================================

export fn rt_string(data: [*]const u8, len: i32) callconv(.c) Value {
    rtInit();
    return values.valString(g, data[0..@intCast(len)]);
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

/// The non-exhaustive-pattern failure arm.  Unreachable in well-typed Elm
/// (the compiler's exhaustiveness check), so this just needs to fail loudly —
/// never a silent miscompile.
export fn rt_die(msg: [*:0]const u8) callconv(.c) noreturn {
    werr(std.mem.span(msg));
    werr("\n");
    std.process.exit(1);
}

// =====================================================================
//  Application
// =====================================================================

/// Generic apply: f is a .lambda Value whose `code` is a Desc and whose
/// `code_len` is the REMAINING arity; `env` is [applied args ++ captures].
///   rem == n  : saturate — split env, rt_callN with all args
///   rem >  n  : partial  — new closure Value, env grows, code_len shrinks
///   rem <  n  : over-applied — saturate, then re-apply the rest
export fn rt_apply(fslot: *Value, args: [*]Value, nargs: i32) callconv(.c) Value {
    var f = fslot.*;
    g.rootPushValue(&f);
    defer g.rootPop();
    var live: i32 = nargs;
    g.rootPushValueArray(args, &live); // over-application re-reads after GCs
    defer g.rootPop();
    return applyGo(&f, args, nargs, false).val;
}

/// The tail-position twin of rt_apply: identical arity dispatch, but a
/// saturated full call returns a `.tail` (whose env/args live in ONE fresh
/// self-contained array, surviving the caller's rt_frame_leave) instead of
/// bouncing internally.  rt_bounce chases it to a .done.
export fn rt_apply_tail(fslot: *Value, args: [*]Value, nargs: i32) callconv(.c) Ret {
    var f = fslot.*;
    g.rootPushValue(&f);
    defer g.rootPop();
    var live: i32 = nargs;
    g.rootPushValueArray(args, &live);
    defer g.rootPop();
    return applyGo(&f, args, nargs, true);
}

fn done(v: Value) Ret {
    return .{ .val = v, .kind = 0, .f = null, .e = null, .args = null, .arity = 0 };
}

fn applyGo(f: *Value, args: [*]Value, nargs: i32, tail: bool) Ret {
    if (f.tag != .lambda) dieLoud("apply of a non-function value");
    const desc: *Desc = @ptrCast(@alignCast(f.payload.lambda.code));
    const rem = f.payload.lambda.code_len;
    const napp = desc.arity - rem;
    const env = f.payload.lambda.env;
    const envlen = f.payload.lambda.env_len;
    const n: usize = @intCast(nargs);

    if (rem == nargs) {
        if (tail) {
            // Build ONE self-contained env: [applied ++ new args ++ captures],
            // `args` = base, `e` = base + arity.  Root a COPY of env across the
            // alloc — a collect moves the env array and rewrites f's lambda.env
            // in place, so the raw `env` read is stale afterwards.
            const arity: usize = @intCast(desc.arity);
            const capslen: usize = @intCast(envlen - napp);
            const total = arity + capslen;
            var env_root: ?[*]Value = env;
            g.rootPushPtr(@ptrCast(&env_root));
            defer g.rootPop(); // env_root
            var buf = g.allocArray(Value, total);
            if (napp > 0) {
                if (env_root == null) dieLoud("closure env missing for applied args");
                @memcpy(buf[0..@intCast(napp)], env_root.?[0..@intCast(napp)]);
            }
            @memcpy(buf[@intCast(napp)..arity], args[0..n]);
            if (capslen > 0)
                @memcpy(buf[arity..total], env_root.?[@intCast(napp)..@intCast(envlen)]);
            const e: ?[*]Value = if (capslen > 0) buf + arity else null;
            return .{ .val = zeroValue(), .kind = 1, .f = desc.code, .e = e, .args = buf, .arity = desc.arity };
        }
        var buf: [max_arity]Value = undefined;
        if (napp > 0) {
            if (env == null) dieLoud("closure env missing for applied args");
            @memcpy(buf[0..@intCast(napp)], env.?[0..@intCast(napp)]);
        }
        @memcpy(buf[@intCast(napp)..][0..n], args[0..n]);
        const caps: ?[*]Value = if (envlen > napp) env.? + @as(usize, @intCast(napp)) else null;
        return done(callArity(desc.arity, desc.code, caps, buf[0..].ptr));
    }

    if (rem > nargs) {
        // partial: env' = applied ++ args ++ captures.  The scalars (napp,
        // envlen, capslen) are capture-safe, but `env` points into GC-managed
        // memory: the allocArray below can scavenge, evacuate the env array,
        // and rewrite f's lambda.env (f IS rooted by the caller) — so root a
        // COPY of the pointer and read through it after the alloc (same shape
        // as values.valLambda).  `args` needs no root here: it addresses the
        // caller's stack array, which rt_apply registered for in-place
        // scanning.
        const capslen: usize = @intCast(envlen - napp);
        const total: usize = @as(usize, @intCast(napp)) + n + capslen;
        var env_root: ?[*]Value = env;
        g.rootPushPtr(@ptrCast(&env_root));
        defer g.rootPop(); // env_root
        var envv: ?[*]Value = g.allocArray(Value, total);
        g.rootPushPtr(@ptrCast(&envv));
        defer g.rootPop(); // envv
        const dst = envv.?[0..total];
        @memcpy(dst[0..@intCast(napp)], env_root.?[0..@intCast(napp)]);
        @memcpy(dst[@intCast(napp)..][0..n], args[0..n]);
        if (capslen > 0) {
            const off: usize = @as(usize, @intCast(napp)) + n;
            const from: usize = @intCast(napp);
            const to: usize = @intCast(envlen);
            @memcpy(dst[off..], env_root.?[from..to]);
        }
        barrierIfOldgen(envv.?, dst);
        return done(.{
            .tag = .lambda,
            .payload = .{ .lambda = .{
                .code = @ptrCast(desc),
                .code_len = rem - nargs,
                .env = envv,
                .env_len = @intCast(total),
            } },
        });
    }

    // over-applied: saturate with the first `rem` args (a NON-tail call,
    // bounced internally), then recurse on the result with the rest — `tail`
    // carries over to the remaining application.
    var buf: [max_arity]Value = undefined;
    const r: usize = @intCast(rem);
    if (napp > 0) @memcpy(buf[0..@intCast(napp)], env.?[0..@intCast(napp)]);
    @memcpy(buf[@intCast(napp)..][0..r], args[0..r]);
    const caps: ?[*]Value = if (envlen > napp) env.? + @as(usize, @intCast(napp)) else null;
    var res = callArity(desc.arity, desc.code, caps, buf[0..].ptr);
    g.rootPushValue(&res);
    defer g.rootPop();
    return applyGo(&res, args + r, nargs - rem, tail);
}

/// Chases a `.tail` chain to its `.done` value at constant native stack — the
/// trampoline that makes cross-defun tails unbounded (the AOT's `bounce`).
fn bounce(r: Ret) Value {
    var rr = r;
    while (true) {
        if (rr.kind == 0) return rr.val;
        rr = callArityRet(rr.arity, rr.f.?, rr.e, rr.args.?);
    }
}

/// The generated-code entry point for a non-tail call: `%r =:ret call q_<key>`
/// then `%v =:val call rt_bounce(l %r)`.  `r` is a pointer to the 80-byte
/// `:ret` the callee returned through sret.
export fn rt_bounce(r: *const Ret) callconv(.c) Value {
    return bounce(r.*);
}

/// A direct saturated tail call to a known defun (no captures): copy the
/// staged args (in the caller's rooted frame) into a fresh GC array so they
/// survive the caller's rt_frame_leave, and return the `.tail`.
export fn rt_tail_known(code: *const anyopaque, argblock: [*]Value, nargs: i32) callconv(.c) Ret {
    const n: usize = @intCast(nargs);
    var buf = g.allocArray(Value, n);
    @memcpy(buf[0..n], argblock[0..n]);
    return .{ .val = zeroValue(), .kind = 1, .f = code, .e = null, .args = buf, .arity = nargs };
}

/// Write barrier for a hand-built env array (mirrors values.valLambda).
fn barrierIfOldgen(arr: [*]Value, elems: []Value) void {
    if (!g.inOldgen(@intFromPtr(arr))) return;
    for (elems) |*e| {
        if (scan.valueReferencesNursery(g, e)) {
            g.dirtyVectorsAdd(arr);
            return;
        }
    }
}

fn callArity(arity: i32, f: *const anyopaque, e: ?[*]Value, buf: [*]Value) Value {
    return bounce(callArityRet(arity, f, e, buf));
}

fn callArityRet(arity: i32, f: *const anyopaque, e: ?[*]Value, buf: [*]Value) Ret {
    return switch (arity) {
        0 => rt_call0(f, e),
        1 => rt_call1(f, e, @ptrCast(buf)),
        2 => rt_call2(f, e, &buf[0], &buf[1]),
        3 => rt_call3(f, e, &buf[0], &buf[1], &buf[2]),
        4 => rt_call4(f, e, &buf[0], &buf[1], &buf[2], &buf[3]),
        5 => rt_call5(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4]),
        6 => rt_call6(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5]),
        7 => rt_call7(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6]),
        8 => rt_call8(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7]),
        9 => rt_call9(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8]),
        10 => rt_call10(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9]),
        11 => rt_call11(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10]),
        12 => rt_call12(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10], &buf[11]),
        13 => rt_call13(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10], &buf[11], &buf[12]),
        14 => rt_call14(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10], &buf[11], &buf[12], &buf[13]),
        15 => rt_call15(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10], &buf[11], &buf[12], &buf[13], &buf[14]),
        16 => rt_call16(f, e, &buf[0], &buf[1], &buf[2], &buf[3], &buf[4], &buf[5], &buf[6], &buf[7], &buf[8], &buf[9], &buf[10], &buf[11], &buf[12], &buf[13], &buf[14], &buf[15]),
        else => dieLoud("arity exceeds the qbe rt_callN table"),
    };
}

// =====================================================================
//  Host -> Elm apply (the effect loop's seam)
// =====================================================================

/// The effect loop's `host_apply` hook.  Every lambda the QBE path produces
/// is Desc*-coded (never *Instr), so the interpreted default
/// (hostcall.applyClosureN -> vmExecEnv) would execute a Desc as instructions.
/// This dispatches natively through rt_apply — the exact path generated code
/// already uses — and rt_apply roots fnv + the arg array across its own
/// allocations before calling into the generated function.  The effect loop's
/// call sites are 1 continuation/handler arg or 2 update args (<< max_arity).
fn hostApply(vm_: *state.Vm, fnv: Value, args: []const Value) state.VmError!Value {
    _ = vm_;
    if (args.len > max_arity) dieLoud("host apply exceeds the qbe rt_callN table");
    var fslot = fnv;
    var argbuf: [max_arity]Value = undefined;
    var i: usize = 0;
    while (i < args.len) : (i += 1) argbuf[i] = args[i];
    return rt_apply(&fslot, &argbuf, @intCast(args.len));
}

// =====================================================================
//  Prim fallback — the EXACT VM primitive
// =====================================================================

export fn rt_prim(name: [*:0]const u8, args: [*]Value, nargs: i32) callconv(.c) Value {
    // `args` points at the CALLER's UNROOTED staging block: it must never be
    // read after an allocation.  Copy by value into rooted storage FIRST
    // (the copy itself runs before any alloc), then root the copies — the
    // GC rewrites them in place and every later read is fresh.  Found by
    // qbe-check.sh's churn fixture (a cons loop at the minimum heap): the
    // unrooted staging went stale across vaInit/vaPush allocations.
    var buf: [max_arity]Value = undefined;
    const n: usize = @intCast(nargs);
    if (n > max_arity) dieLoud("prim arity exceeds the qbe rt_callN table");
    @memcpy(buf[0..n], args[0..n]);
    var live: i32 = nargs;
    g.rootPushValueArray(&buf, &live);
    defer g.rootPop();

    // trap-error vmExecEnv's a lambda body as a VM *Instr stream
    // (prims.zig:1087/1141).  Every lambda the native slice produces is
    // Desc*-coded, never *Instr — handing it to trap-error would execute a
    // Desc struct as instructions.  Reject loudly rather than silently
    // misinterpreting (unreachable from today's frontend, but the loudness
    // contract must not have a silent-UB hole).
    if (std.mem.eql(u8, std.mem.span(name), "trap-error")) {
        for (buf[0..n]) |*a| {
            if (a.tag == .lambda) {
                dieLoud("prim 'trap-error' received a native closure (Desc* code) — no VM lambda exists in the qbe slice");
            }
        }
    }

    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    interp.vaInit(g, &stack);
    // Root the SLOT, not the base: vaInit's array is GC-allocated and moves
    // on collection; a registration-time copy of its base goes stale (the
    // effectloop's runPrim uses the same slot-rooting pattern).  ROOT_PTR
    // skips a null slot, so the pre-vaInit null case is covered.
    g.rootPushPtr(@ptrCast(&stack.data));
    defer g.rootPop();
    defer interp.vaFree(&stack);
    // Push REVERSED so the first pop is args[0] — the order the ZINC
    // emitter's RTL pushes produce (PrimApp args are in pop order).
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        interp.vaPush(g, &stack, buf[i]);
    }
    var acc: Value = zeroValue();
    g.rootPushValue(&acc);
    defer g.rootPop();
    prims.execPrimitive(vm, std.mem.span(name), &acc, &stack) catch |e| {
        diePrim(e, name);
    };
    return acc;
}

fn diePrim(e: anyerror, name: [*:0]const u8) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "qbe-rt: prim {s} failed: {s}\n", .{ std.mem.span(name), @errorName(e) }) catch "qbe-rt: prim failed\n";
    werr(msg);
    std.process.exit(1);
}

fn dieLoud(msg: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "qbe-rt: {s}\n", .{msg}) catch "qbe-rt: error\n";
    werr(out);
    std.process.exit(1);
}

// =====================================================================
//  Driver — elmvm-shaped: <entry-name> [int-arg ...]; prints the result
//  exactly like tools/elmvm.zig (values.printValue + "\n").
// =====================================================================

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

var vmem: state.Vm = undefined;

/// AOTRUN_ARGV: build the *argv* pseudo-global value — a plain cons LIST of
/// strings (run.js argv[2:] shape), built back-to-front (cdr-first) so each
/// valCons roots the previous tail.  The empty case returns the nil singleton
/// (Runtime.argv () -> []).  Mirrors tools/aot/run.zig's buildArgvList.
fn buildArgvList(nargs: usize, c_argv: [*]?[*:0]u8) Value {
    var acc: Value = values.valNil();
    var i: usize = nargs;
    while (i > 0) {
        i -= 1;
        acc = values.valCons(g, values.valString(g, std.mem.span(c_argv[2 + i] orelse "")), acc);
    }
    return acc;
}

export fn main(c_argc: c_int, c_argv: [*]?[*:0]u8) callconv(.c) c_int {
    // Read the debug knobs ONCE, here, before any generated code can run.
    // rt_frame_leave used to call getenv on every return (8.4% of the native
    // compiler's runtime — see no_frame_reuse); nothing below this line may
    // start calling generated code before the flag is set.
    no_frame_reuse = std.c.getenv("QBE_NO_REUSE") != null;

    // The generated code puts Elm recursion on the C stack (Lower.elm:76-84
    // documents the limitation), so the default 8MB RLIMIT_STACK can kill deep
    // programs -- hence this net.  Best-effort: raise only the SOFT limit
    // (raising the hard limit needs privileges and would fail the whole call),
    // never lower a higher one.
    //
    // HISTORY, measured (handoff-qbe-bug2-improve, complete 9,736-frame core of
    // the 610s selfhost SEGV): ~9,635 frames of Zinc.Emit.fuse's NON-tail
    // recursion (`merged :: fuse rest`, Zinc/Emit.elm:134 -- one native call per
    // ZINC instruction of a body; the crashing body, Char.Extra's unicode
    // dispatch, is ~9.6k instructions) at a 656-byte stride = 6.32MB, under
    // main's own 1.94MB frame (the effect-loop HostLoop local,
    // src/effectloop.zig:200-213, inlined via runProgram) plus ~0.27MB of
    // driver: 8.5MB > 8MB, and the faulting `call` died on its own
    // return-address push (fault addr rsp-8, 0x138 below the exactly-8MB stack
    // VMA).  The same workload COMPLETED at `ulimit -s 262144` (546s, exit 0)
    // and SEGVed at 8192 -- stack-size-dependent, therefore not a GC/rooting
    // bug.
    //
    // THAT BUDGET HAS SINCE FALLEN BY HALF, so for this workload the net is no
    // longer the thing keeping it alive.  Two changes: `fuse` is now an
    // iterative left fold whose self-tail call the backend compiles to an
    // IN-FRAME LOOP (VERIFIED in the emitted assembly: q_Zinc_x2eEmit_x2efuseHelp
    // has zero callq to itself, where the old q_Zinc_x2eEmit_x2efuse had five),
    // and the effect-loop HostLoop is HEAP-allocated instead of living in main's
    // frame (main's prologue went from `sub $0x1d8e68,%rsp` = 1,937,000 bytes to
    // `sub $0x10ca8,%rsp` = 68,776 bytes -- proven by asymmetry: identical
    // generated code, one source file toggled).  RE-MEASURED with this raise
    // SUPPRESSED (see QBE_NO_RLIMIT below) at the DEFAULT `ulimit -s 8192`: the
    // workload COMPLETES, exit 0, and an ITIMER_PROF rsp sampler puts the
    // HIGH-WATER at 4,409,776 bytes (4.41MB), against a bisection that SEGVs at
    // 4096KB and completes at 8192KB.
    //
    // SCOPE, kept honest: the net still covers every C-stack exhaustion up to
    // 64MB, and the residual 4.41MB is NOT either of the two items above.  The
    // frame chain AT THE PEAK is `Prelude.filterMap` recursing at a 0x260
    // (608-byte) stride, called from Zinc.Emit.flatten
    // (`List.filterMap instrText instrs`, Emit.elm:254) via Lower/Module.elm's
    // `Csexp.bundleEntry (Emit.flatten (Emit.resolve code))` -- the PRODUCTION
    // encoder for a defun body, i.e. one native call per ZINC instruction, the
    // same shape as the `fuse` recursion this unit removed; Prelude's own note
    // lists map/filter/reverse as tail-recursive accumulator walkers and
    // filterMap (Prelude.elm:659) was missed.  An EARLIER, shallower peak
    // (>1MB, 77s in) is a different one: the recursive-descent parser
    // (ParserFast.skipWhileWithoutLinebreakHelp / loopWhileSucceedsHelp /
    // symbolFollowedBy / map2), where every closure application costs four
    // native frames (rt_apply 0x610, rt.applyGo 0x320, rt.callArity 0x80,
    // rt_call1 0x80).  So the budget is still measured in megabytes and a
    // bigger input could still exhaust 8MB; what is gone is the class that made
    // it routine.  The loop-shaped (tail/mutual) recursion fix has SINCE LANDED:
    // the bounce loop above (Ret = .done|.tail, rt_bounce / rt_tail_known /
    // rt_apply_tail) makes cross-defun tails constant-stack.  What remains is
    // NON-tail deep recursion (the recursive-descent parser above) — the AOT's
    // nat_depth guard is the known fix and is still a later stage.
    //
    // QBE_NO_RLIMIT=1 SKIPS the raise.  It exists so the net is TESTABLE: with
    // it set, `ulimit -s` decides the budget and one can ask of any workload
    // whether it still needs the raise at all (a binary that completes under
    // the DEFAULT 8MB with the net suppressed does not).  Without a way to
    // turn the raise off, a higher limit silently hides the very regression
    // the limit was raised for.
    const want_stack: std.posix.rlim_t = 64 * 1024 * 1024;
    if (std.c.getenv("QBE_NO_RLIMIT") == null) {
        if (std.posix.getrlimit(.STACK)) |cur_lim| {
            if (cur_lim.cur < want_stack) {
                var lim = cur_lim;
                lim.cur = want_stack;
                std.posix.setrlimit(.STACK, lim) catch {};
            }
        } else |_| {}
    }

    const argc: usize = @intCast(c_argc);
    if (argc < 2) {
        werr("usage: <prog> <entry-name> [int-arg ...]\n");
        return 2;
    }
    const entry = std.mem.span(c_argv[1] orelse "");
    const nargs = argc - 2;

    // AOTRUN_ARGV (same contract as tools/elmvm.zig and tools/aot/run.zig):
    // the trailing args are the APP's command line, exposed as the *argv*
    // pseudo-global (a plain cons list of strings, run.js argv[2:] shape) —
    // NOT call arguments, and the entry is invoked with 0 call args.  This is
    // how a selfhosted CLI driver (NativeMain) reads its inputs.
    const argv_mode = std.c.getenv("AOTRUN_ARGV") != null;

    if (!argv_mode and nargs > max_arity) {
        var b: [128]u8 = undefined;
        const out = std.fmt.bufPrint(&b, "qbe-rt: >{d} entry args not supported\n", .{max_arity}) catch "qbe-rt: too many entry args\n";
        werr(out);
        return 2;
    }

    // heap knob for the GC-churn verification (small heap => many moves)
    const heap_bytes: usize = blk: {
        const env = std.c.getenv("QBE_HEAP_MB") orelse break :blk HEAP_BYTES;
        const s = std.mem.span(env);
        const mb = std.fmt.parseUnsigned(usize, s, 10) catch break :blk HEAP_BYTES;
        if (mb == 0) break :blk HEAP_BYTES;
        break :blk mb * 1024 * 1024;
    };

    rtInit();
    var gg = Gc.init(.{
        .heap_bytes = heap_bytes,
        .reserve_bytes = @max(heap_bytes * 2, RESERVE_BYTES),
        .verbose = std.c.getenv("QBE_GC_VERBOSE") != null,
        .verify_collects = std.c.getenv("QBE_GC_VERIFY") != null,
    }) catch {
        werr("qbe-rt: gc init failed\n");
        return 1;
    };
    g = &gg;
    defer g.deinit();
    vmem.init(&gg);
    vm = &vmem;

    // find the entry in the meta table.  $qbe_meta is a POINTER to a single
    // contiguous array of Meta rows (Mid.Qbe.Lower metaTable emits the rows
    // inline in one $meta_rows symbol and $qbe_meta as `l $meta_rows`), so
    // `[*]const Meta` describes the layout exactly — no reliance on QBE's
    // per-symbol emission order.
    var meta: ?*const Meta = null;
    var i: usize = 0;
    while (i < qbe_meta_len) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(qbe_meta[i].name), entry)) {
            meta = &qbe_meta[i];
            break;
        }
    }
    const m = meta orelse {
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "qbe-rt: entry '{s}' not in qbe_meta\n", .{entry}) catch "qbe-rt: entry not found\n";
        werr(out);
        return 2;
    };

    // args: ints only (the slice's fixtures need nothing else; floats die
    // loudly rather than guessing the VM's float-arg formatting)
    var argv_buf: [max_arity]Value = undefined;
    var entry_nargs: i32 = 0;
    var j: usize = 0;
    if (!argv_mode) {
        while (j < nargs) : (j += 1) {
            const a = std.mem.span(c_argv[2 + j] orelse "");
            const n = std.fmt.parseInt(i64, a, 10) catch {
                var buf: [256]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "qbe-rt: entry arg '{s}' is not an int (qbe slice)\n", .{a}) catch "qbe-rt: bad entry arg\n";
                werr(out);
                return 2;
            };
            argv_buf[j] = values.valNumber(n);
        }
        entry_nargs = @intCast(nargs);
    }
    var live: i32 = entry_nargs;
    g.rootPushValueArray(&argv_buf, &live);
    defer g.rootPop();

    // *argv* pseudo-global: in argv mode the APP's strings (built back-to-
    // front, each valCons rooting the previous tail — the same shape
    // tools/aot/run.zig builds); otherwise the empty list (the default
    // run.zig installs when argv_mode is off).
    if (argv_mode) {
        vmem.valueSet("*argv*", buildArgvList(nargs, c_argv));
    } else {
        vmem.valueSet("*argv*", values.valNil());
    }

    // Host the effect loop EXACTLY like tools/aot/run.zig and tools/elmvm.zig:
    // install the native host->Elm dispatcher (the default interpreted
    // hostcall.applyClosureN would vmExecEnv a Desc* as *Instr), run the entry,
    // and if it returns a Program vector drive the shared CEK effect manager
    // to the final model.  The Vm already wired *stinput*/*stoutput*/*sterror*
    // in initGlobals, so StreamRef reads the same value-table slots elmvm does.
    effectloop.host_apply = &hostApply;

    var result = callArity(m.arity, m.code, null, &argv_buf);
    g.rootPushValue(&result);
    defer g.rootPop();

    var final = result;
    if (effectloop.isProgram(result)) {
        final = effectloop.runProgram(&vmem, result) catch {
            var ebuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&ebuf, "qbe-rt: error: {s}\n", .{values.errSlice(vmem.err_slot)}) catch "qbe-rt: effect loop failed\n";
            werr(msg);
            return 1;
        };
        g.rootPushValue(&final);
        defer g.rootPop();
    }

    // Print through an ALLOCATING writer, not a fixed one: a result whose
    // printed form exceeds any fixed buffer must print in full (the VM runner
    // elmvm does the same), so native and VM output agree at every size.
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    values.printValue(&aw.writer, final) catch {
        werr("qbe-rt: print failed\n");
        return 1;
    };
    wout(aw.written());
    wout("\n");
    return 0;
}
