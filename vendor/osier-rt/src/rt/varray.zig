//! src/rt/varray.zig — the ValueArray stack ops, extracted from interp.zig
//! (handoff-osier-rtsplit; C origin zincvm.c:406-437).
//!
//! These are ValueArray utilities, not interpretation: prims pop their
//! operands through vaPop, the QBE runtime stages prim args with
//! vaInit/vaPush/vaFree, and the interpreter's eval loop uses the same ops
//! for its operand stack.  Extracted so the runtime package shares ONE
//! implementation without importing the interpreter loop.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const values = @import("values.zig");

const Gc = gc.Gc;
const Value = types.Value;

/// C: zincvm.c:407 STACK_INIT_CAP.
pub const STACK_INIT_CAP: i32 = 12;

/// C: zincvm.c:410-413 va_init.  Must only be called once the caller's
/// stable slots for a->data (and anything read during the alloc) are rooted
/// — vmExecEnv's prologue does this before its va_init.
pub fn vaInit(g: *Gc, a: *types.ValueArray) void {
    a.data = g.allocArray(Value, @intCast(STACK_INIT_CAP));
    a.len = 0;
    a.cap = STACK_INIT_CAP;
}

/// C: zincvm.c:414-432 va_push.  On grow, v is rooted across the
/// GC_VALUE_ARRAY (v may carry interior pointers — lambda.code/env,
/// cons.car/cdr, str.data — that a collection fired during the grow would
/// otherwise leave stale in this local, C:416-421); after the store, the
/// write barrier records the element array in the remembered set iff it is
/// old-gen AND the stored Value references the nursery (C:429-431).
pub fn vaPush(g: *Gc, a: *types.ValueArray, v: Value) void {
    var vv = v;
    if (a.len >= a.cap) {
        const new_cap: i32 = a.cap * 2;
        var guard = g.rootValue(&vv); // root v across GC_VALUE_ARRAY — C:422
        defer guard.end();
        const new_data = g.allocArray(Value, @intCast(new_cap));
        const ln: usize = @intCast(a.len);
        @memcpy(new_data[0..ln], a.data.?[0..ln]);
        // M5 fix: the grow copies the OLD elements into a possibly-oldgen
        // array; barrier them (a copied nursery reference would otherwise go
        // stale at the next scavenge).  Mirrors applyBundledN / interp apply.
        if (g.inOldgen(@intFromPtr(new_data))) {
            var j: usize = 0;
            while (j < ln) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &a.data.?[j])) {
                    g.dirtyVectorsAdd(new_data);
                    break;
                }
            }
        }
        a.data = new_data;
        a.cap = new_cap;
    }
    const idx: usize = @intCast(a.len);
    a.data.?[idx] = vv;
    a.len += 1;
    // C checks &v (the stored copy); &a->data[a->len-1] is now that copy and
    // valueReferencesNursery is read-only — identical behaviour.
    if (g.inOldgen(@intFromPtr(a.data.?)) and
        gc.scan.valueReferencesNursery(g, &a.data.?[idx]))
        g.dirtyVectorsAdd(a.data.?);
}

/// C: zincvm.c:433-436 va_pop — pop from an empty stack is fatal
/// (C fprintf + exit(1) → std.debug.panic).
pub fn vaPop(a: *types.ValueArray) Value {
    if (a.len <= 0) std.debug.panic("fatal: pop from empty stack", .{});
    a.len -= 1;
    // Clear the vacated slot: the GC scans value_arrays by full capacity,
    // so a stale ref here would retain popped Values (closure envs).
    const v = a.data.?[@intCast(a.len)];
    a.data.?[@intCast(a.len)] = values.valNil();
    return v;
}

/// C: zincvm.c:437 va_peek.
pub fn vaPeek(a: *types.ValueArray) Value {
    return a.data.?[@intCast(a.len - 1)];
}

/// C: zincvm.c:438 va_free — release the slots only (the array itself is
/// GC-managed); the rooted &stack.data slot now pins nothing.
pub fn vaFree(a: *types.ValueArray) void {
    a.data = null;
    a.len = 0;
    a.cap = 0;
}
