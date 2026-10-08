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

const Gc = heap.Gc;
const Value = types.Value;

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

extern const qbe_meta: [*]const Meta;
extern const qbe_meta_len: usize;

extern fn rt_call0(f: ?*const anyopaque, e: ?[*]Value) callconv(.c) Value;
extern fn rt_call1(f: ?*const anyopaque, e: ?[*]Value, a0: *Value) callconv(.c) Value;
extern fn rt_call2(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value) callconv(.c) Value;
extern fn rt_call3(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value) callconv(.c) Value;
extern fn rt_call4(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value) callconv(.c) Value;
extern fn rt_call5(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value) callconv(.c) Value;
extern fn rt_call6(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value) callconv(.c) Value;
extern fn rt_call7(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value) callconv(.c) Value;
extern fn rt_call8(f: ?*const anyopaque, e: ?[*]Value, a0: *Value, a1: *Value, a2: *Value, a3: *Value, a4: *Value, a5: *Value, a6: *Value, a7: *Value) callconv(.c) Value;

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
    hdr.* = .{ .live = 0, .next = null, .freelist_next = null, .slots = @ptrCast(bytes.ptr + @sizeOf(FrameHdr)) };
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
    hdr.next = frame_top;
    frame_top = hdr;
    g.rootPushValueArray(hdr.slots, &hdr.live);
    return hdr.slots;
}

export fn rt_frame_leave() callconv(.c) void {
    const hdr = frame_top orelse @panic("qbe-rt: rt_frame_leave with no frame");
    frame_top = hdr.next;
    g.rootPop();
    const n = hdr.live;
    if (std.c.getenv("QBE_NO_REUSE") != null) return; // debug: never reuse
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
    return applyGo(&f, args, nargs);
}

fn applyGo(f: *Value, args: [*]Value, nargs: i32) Value {
    if (f.tag != .lambda) dieLoud("apply of a non-function value");
    const desc: *Desc = @ptrCast(@alignCast(f.payload.lambda.code));
    const rem = f.payload.lambda.code_len;
    const napp = desc.arity - rem;
    const env = f.payload.lambda.env;
    const envlen = f.payload.lambda.env_len;
    const n: usize = @intCast(nargs);

    if (rem == nargs) {
        var buf: [8]Value = undefined; // maxArity (Mid.Qbe.Lower)
        if (napp > 0) {
            if (env == null) dieLoud("closure env missing for applied args");
            @memcpy(buf[0..@intCast(napp)], env.?[0..@intCast(napp)]);
        }
        @memcpy(buf[@intCast(napp)..][0..n], args[0..n]);
        const caps: ?[*]Value = if (envlen > napp) env.? + @as(usize, @intCast(napp)) else null;
        return callArity(desc.arity, desc.code, caps, buf[0..].ptr);
    }

    if (rem > nargs) {
        // partial: env' = applied ++ args ++ captures (fresh reads of f's
        // fields AFTER the alloc — f is rooted by the caller)
        const capslen: usize = @intCast(envlen - napp);
        const total: usize = @as(usize, @intCast(napp)) + n + capslen;
        var envv: ?[*]Value = g.allocArray(Value, total);
        g.rootPushPtr(@ptrCast(&envv));
        defer g.rootPop();
        const dst = envv.?[0..total];
        @memcpy(dst[0..@intCast(napp)], env.?[0..@intCast(napp)]);
        @memcpy(dst[@intCast(napp)..][0..n], args[0..n]);
        if (capslen > 0) {
            const off: usize = @as(usize, @intCast(napp)) + n;
            const from: usize = @intCast(napp);
            const to: usize = @intCast(envlen);
            @memcpy(dst[off..], env.?[from..to]);
        }
        barrierIfOldgen(envv.?, dst);
        return .{
            .tag = .lambda,
            .payload = .{ .lambda = .{
                .code = @ptrCast(desc),
                .code_len = rem - nargs,
                .env = envv,
                .env_len = @intCast(total),
            } },
        };
    }

    // over-applied: saturate with the first `rem` args, then recurse
    var buf: [8]Value = undefined;
    const r: usize = @intCast(rem);
    if (napp > 0) @memcpy(buf[0..@intCast(napp)], env.?[0..@intCast(napp)]);
    @memcpy(buf[@intCast(napp)..][0..r], args[0..r]);
    const caps: ?[*]Value = if (envlen > napp) env.? + @as(usize, @intCast(napp)) else null;
    var res = callArity(desc.arity, desc.code, caps, buf[0..].ptr);
    g.rootPushValue(&res);
    defer g.rootPop();
    return applyGo(&res, args + r, nargs - rem);
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
        else => dieLoud("arity > 8 not supported by the qbe slice"),
    };
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
    var buf: [8]Value = undefined;
    const n: usize = @intCast(nargs);
    @memcpy(buf[0..n], args[0..n]);
    var live: i32 = nargs;
    g.rootPushValueArray(&buf, &live);
    defer g.rootPop();

    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    interp.vaInit(g, &stack);
    g.rootPushValueArray(stack.data orelse @ptrCast(&emptySlot), &stack.len);
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

var emptySlot: Value = .{ .tag = .number, .payload = .{ .number = 0 } };

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

export fn main(c_argc: c_int, c_argv: [*]?[*:0]u8) callconv(.c) c_int {
    const argc: usize = @intCast(c_argc);
    if (argc < 2) {
        werr("usage: <prog> <entry-name> [int-arg ...]\n");
        return 2;
    }
    const entry = std.mem.span(c_argv[1] orelse "");
    const nargs = argc - 2;
    if (nargs > 8) {
        werr("qbe-rt: >8 entry args not supported\n");
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

    // find the entry in the meta table
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
    var argv_buf: [8]Value = undefined;
    var j: usize = 0;
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
    var live: i32 = @intCast(nargs);
    g.rootPushValueArray(&argv_buf, &live);
    defer g.rootPop();

    const result = callArity(m.arity, m.code, null, &argv_buf);

    var outbuf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&outbuf);
    values.printValue(&w, result) catch {
        werr("qbe-rt: print failed\n");
        return 1;
    };
    wout(w.buffered());
    wout("\n");
    return 0;
}
