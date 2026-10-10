//! src/rt/prims.zig — the C primitives: table + dispatch + the pure subset
//! handlers (milestone M5; vendored into the osier runtime by
//! handoff-osier-rtsplit).
//!
//! C origin: zincvm.c:1780-2794 (exec_primitive, PURE cases only),
//! zincvm.c:957-974 (prim_names[] / exec_primitive_valid — the prims.def
//! X-macro becomes the comptime `prim_table` below) and zincvm.c:3752-3758
//! (init_globals, driven from state.zig).
//!
//! SCOPE (plan PRIMS deliverable — the pure subset of the ~70 prims.def
//! entries): the INCLUDE list is the plan's exact list (hot list ops,
//! arithmetic/comparison, predicates, strings+chars, vectors, control,
//! tuples/symbols/misc), plus the M6 stream I/O prims (write-byte/read-byte/
//! read-file-as-string/open/close) and the M8 process prims (exec-plan/cd/
//! getcwd/getpid/getenv/setenv/glob via execplan.zig).
//!
//! THE OSIER PRUNE (handoff-osier-rtsplit): 22 Shen-only prims are DELETED —
//! boolean? element? error? error-to-string eval-kl function? gensym
//! get-time hdstr kill newvar n->string pos set shen.fail! stream? string->n
//! symbol? tlstr trap-error variable? wait.  None is emission-reachable from
//! the Elm front end (no "call this prim" escape exists; the only source
//! mentions are a purity table in Mid/Shrink.elm, which is not an emission
//! path).  The two structural wins: trap-error took the CatchSite chain and
//! BOTH interpreter-loop calls with it, and eval-kl took marshal.zig with
//! it (it called three bundle functions by name that exist only in a Shen
//! image Osier never loads).  The oracle: the corpus and qbe-check stay
//! byte-identical because none of the 22 is ever emitted.
//!
//! ROOTING (plan exec_primitive ROOTING observation, ported VERBATIM — the C
//! audit note at zincvm.c:1772-1779 applies unchanged): every popped Value
//! whose interior pointers are read across an allocating call must be rooted
//! (rootPushValue) or copied through valStringFrom's slot-rooting; the
//! per-prim discipline is annotated at each handler.  Alloc-free prims take
//! no roots.  Write barriers fire on every store of a possibly-nursery Value
//! into a possibly-oldgen Value array (address-> via gc.writeBarrierVectorStore).

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const state = @import("state.zig");
const values = @import("values.zig");
const symbols = @import("symbols.zig");
const varray = @import("varray.zig");
const streams = @import("streams.zig");
const execplan = @import("execplan.zig");

const Gc = gc.Gc;
const Value = types.Value;
const ValueArray = types.ValueArray;
const Vm = state.Vm;
const VmError = state.VmError;

/// The handler shape shared by the table and the dispatcher.
pub const PrimFn = *const fn (vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void;

/// One table entry — the Zig translation of a prims.def `PRIM(n, a)` line.
/// `arity` is informational (handlers pop what they need, exactly like C);
/// it documents the Shen-side arity that zinc-c compiles calls against.
pub const PrimDef = struct {
    name: [:0]const u8,
    arity: u8,
    func: PrimFn,
};

/// C: zincvm.c:957-965 prim_names[] (the prims.def X-macro), single source of
/// truth driving: dispatch (prim_map), initGlobals (state.zig), isValid (the
/// defun_get prim fallback), and the bundle loader's primitive?-names list.
/// Order mirrors prims.def (hot-first) minus the deferred/omitted entries.
pub const prim_table = [_]PrimDef{
    // ---- hot list ops + interp-internal hot prims (prims.def order) ----
    .{ .name = "assoc", .arity = 2, .func = primAssoc },
    .{ .name = "cons", .arity = 2, .func = primCons },
    .{ .name = "hd", .arity = 1, .func = primHd },
    .{ .name = "tl", .arity = 1, .func = primTl },
    .{ .name = "=", .arity = 2, .func = primEq },
    .{ .name = "empty?", .arity = 1, .func = primEmptyP },
    .{ .name = "reverse", .arity = 1, .func = primReverse },
    .{ .name = "append", .arity = 2, .func = primAppend },
    // ---- arithmetic + comparison ----
    .{ .name = "+", .arity = 2, .func = primAdd },
    .{ .name = "/", .arity = 2, .func = primDiv },
    .{ .name = "f/", .arity = 2, .func = primFdiv },
    .{ .name = "*", .arity = 2, .func = primMul },
    .{ .name = "-", .arity = 2, .func = primSub },
    .{ .name = ">", .arity = 2, .func = primGt },
    .{ .name = "<", .arity = 2, .func = primLt },
    .{ .name = ">=", .arity = 2, .func = primGe },
    .{ .name = "<=", .arity = 2, .func = primLe },
    // ---- bitwise (elm/core Array support): JS int32 semantics ----
    .{ .name = "bitwise-and", .arity = 2, .func = primBitwiseAnd },
    .{ .name = "bitwise-or", .arity = 2, .func = primBitwiseOr },
    .{ .name = "bitwise-xor", .arity = 2, .func = primBitwiseXor },
    .{ .name = "bitwise-not", .arity = 1, .func = primBitwiseNot },
    .{ .name = "bitwise-shift-left", .arity = 2, .func = primShiftLeft },
    .{ .name = "bitwise-shift-right", .arity = 2, .func = primShiftRight },
    .{ .name = "bitwise-shift-right-zf", .arity = 2, .func = primShiftRightZf },
    // ---- predicates ----
    .{ .name = "number?", .arity = 1, .func = primNumberP },
    .{ .name = "string?", .arity = 1, .func = primStringP },
    .{ .name = "cons?", .arity = 1, .func = primConsP },
    .{ .name = "absvector?", .arity = 1, .func = primAbsvectorP },
    // ---- strings + chars ----
    .{ .name = "cn", .arity = 2, .func = primCn },
    .{ .name = "str", .arity = 1, .func = primStr },
    .{ .name = "repeat", .arity = 2, .func = primRepeat },
    .{ .name = "c-strlen", .arity = 1, .func = primCStrlen },
    .{ .name = "char-code", .arity = 2, .func = primCharCode },
    .{ .name = "substring", .arity = 3, .func = primSubstring },
    .{ .name = "shen.str->bytes", .arity = 1, .func = primStrToBytes },
    .{ .name = "shen.bytes->string", .arity = 1, .func = primBytesToStr },
    // ---- vectors / addresses ----
    .{ .name = "absvector", .arity = 1, .func = primAbsvector },
    .{ .name = "address->", .arity = 3, .func = primAddressSet },
    .{ .name = "<-address", .arity = 2, .func = primAddressGet },
    .{ .name = "emptylist", .arity = 1, .func = primEmptylist },
    // ---- stream I/O (M6) ----
    .{ .name = "write-byte", .arity = 2, .func = streams.primWriteByte },
    .{ .name = "read-byte", .arity = 1, .func = streams.primReadByte },
    .{ .name = "read-file-as-string", .arity = 1, .func = streams.primReadFileAsString },
    .{ .name = "open", .arity = 2, .func = streams.primOpen },
    .{ .name = "close", .arity = 1, .func = streams.primClose },
    // ---- process execution (M8, execplan.zig) ----
    .{ .name = "exec-plan", .arity = 1, .func = execplan.primExecPlan },
    .{ .name = "cd", .arity = 1, .func = execplan.primCd },
    .{ .name = "getcwd", .arity = 0, .func = execplan.primGetcwd },
    .{ .name = "getpid", .arity = 0, .func = execplan.primGetpid },
    .{ .name = "getenv", .arity = 1, .func = execplan.primGetenv },
    .{ .name = "setenv", .arity = 2, .func = execplan.primSetenv },
    .{ .name = "glob", .arity = 1, .func = execplan.primGlob },
    // ---- control ----
    .{ .name = "simple-error", .arity = 1, .func = primSimpleError },
    .{ .name = "intern", .arity = 1, .func = primIntern },
    .{ .name = "value", .arity = 1, .func = primValue },
    // ---- tuples / symbols / misc ----
    .{ .name = "@p", .arity = 2, .func = primAtP },
    .{ .name = "fst", .arity = 1, .func = primFst },
    .{ .name = "snd", .arity = 1, .func = primSnd },
};

/// Comptime name -> handler map (the dispatch half of the table).
const prim_map = std.StaticStringMap(PrimFn).initComptime(blk: {
    @setEvalBranchQuota(100000);
    var kvs: [prim_table.len]struct { []const u8, PrimFn } = undefined;
    for (&kvs, 0..) |*kv, i| kv.* = .{ prim_table[i].name, prim_table[i].func };
    break :blk kvs;
});

/// The table itself (initGlobals + bundle primitive?-names iterate this).
pub fn primNames() []const PrimDef {
    return &prim_table;
}

/// C: zincvm.c:967-974 exec_primitive_valid — true iff `name` is a known C
/// primitive (the defun_get prim fallback).
pub fn isValid(name: []const u8) bool {
    return name.len != 0 and prim_map.get(name) != null;
}

/// Table lookup returning the entry (state.defunGet uses the CANONICAL
/// [:0] name literal for valPrim, independent of the caller's buffer).
pub fn lookupDef(name: []const u8) ?*const PrimDef {
    for (&prim_table) |*def| {
        if (std.mem.eql(u8, std.mem.sliceTo(def.name, 0), name)) return def;
    }
    return null;
}

/// P1 fast dispatch: comptime-stable index of `name` in prim_table (the
/// table is a fixed comptime array — its order never changes at runtime), or
/// null when unknown.  parser.zig resolveJumps stores this +1 into
/// Instr.jmp_target (0 = by-name fallback, byte-identical unknownPrim path).
pub fn primIndex(name: []const u8) ?usize {
    for (&prim_table, 0..) |*def, i| {
        if (std.mem.eql(u8, std.mem.sliceTo(def.name, 0), name)) return i;
    }
    return null;
}

/// P1 fast dispatch: entry by table index (the caller stores index+1 in
/// jmp_target and subtracts 1 back here).  Caller bounds: jmp_target > 0
/// guarantees i < prim_table.len by construction (resolveJumps).
pub fn primByIndex(i: usize) *const PrimDef {
    return &prim_table[i];
}

/// C: zincvm.c:2790-2793 unknown tail — print + return -1.  Mapped to
/// error.Halt: the eval-loop call sites catch it and break to done with acc
/// preserved (the C `exec_primitive() < 0 -> goto done`).
fn unknownPrim(name: []const u8) VmError {
    std.debug.print("runtime: unknown primitive '{s}'\n", .{name});
    return error.Halt;
}

/// C: zincvm.c:1780-1783 exec_primitive head.  Every name dispatched through
/// the comptime map; unknown (or empty) names hard-stop.
pub fn execPrimitive(vm: *Vm, name: []const u8, acc: *Value, stack: *ValueArray) VmError!void {
    if (name.len == 0) return unknownPrim(name);
    const f = prim_map.get(name) orelse return unknownPrim(name);
    return f(vm, acc, stack);
}

// =====================================================================
//  'a': absvector, absvector?, address->, assoc, append
// =====================================================================

/// C: zincvm.c:1785-1788 absvector.  val_vector allocates the element array;
/// the popped arg is a number (no interior pointers) — no root needed.
fn primAbsvector(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a = varray.vaPop(stack);
    // C casts `(int)a.number` — truncating mod 2^32 (no range panic).
    const size: i32 = @truncate(a.payload.number);
    acc.* = values.valVector(vm.gc, size);
}

/// C: zincvm.c:1789-1791 absvector?.
fn primAbsvectorP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .vector);
}

/// C: zincvm.c:1792-1802 address->.  NO GC allocation — the element store
/// goes through the write barrier (heap.zig:982 ports C's gc_dirty_vectors_add
/// site exactly; the null `data` guard is the .? unwrap parity with C's UB).
fn primAddressSet(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    const vec = varray.vaPop(stack);
    const idx = varray.vaPop(stack);
    const val = varray.vaPop(stack);
    const i: usize = @intCast(idx.payload.number);
    g.writeBarrierVectorStore(vec.payload.vector.data.?, i, val);
    acc.* = vec;
}

/// C: zincvm.c:1810-1830 assoc.  Alloc-free (deep_equal); key/l rooted for
/// parity with C:1811-1812.
fn primAssoc(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var key = varray.vaPop(stack);
    var l = varray.vaPop(stack);
    g.rootPushValue(&key);
    g.rootPushValue(&l);
    var found = false;
    var result = values.valNil();
    while (l.tag == .cons) {
        const car = l.payload.cons.car.?;
        if (car.tag == .cons and values.deepEqual(key, car.payload.cons.car.?.*, 0)) {
            result = car.*;
            found = true;
            break;
        }
        l = l.payload.cons.cdr.?.*;
    }
    if (!found and l.tag != .nil) {
        g.rootPop();
        g.rootPop();
        return vm.throwShen("attempt to search a non-list with assoc");
    }
    acc.* = if (found) result else values.valNil();
    g.rootPop();
    g.rootPop();
}

/// C: zincvm.c:1836-1856 append.  cons-copy a1's prefix onto tail a2; both
/// args + rev + out rooted across the valCons loops (C parity: 4 roots).
fn primAppend(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var a1 = varray.vaPop(stack);
    var a2 = varray.vaPop(stack);
    if (a1.tag != .nil and a1.tag != .cons)
        return vm.throwShen("attempt to append a non-list");
    g.rootPushValue(&a1);
    g.rootPushValue(&a2);
    if (a1.tag == .nil) {
        g.rootPop();
        g.rootPop();
        acc.* = a2;
        return;
    }
    var rev = values.valNil();
    g.rootPushValue(&rev);
    while (a1.tag == .cons) {
        rev = values.valCons(g, a1.payload.cons.car.?.*, rev);
        a1 = a1.payload.cons.cdr.?.*;
    }
    var out = a2;
    g.rootPushValue(&out);
    while (rev.tag == .cons) {
        out = values.valCons(g, rev.payload.cons.car.?.*, out);
        rev = rev.payload.cons.cdr.?.*;
    }
    acc.* = out;
    g.rootPop();
    g.rootPop();
    g.rootPop();
    g.rootPop();
}

// =====================================================================
//  'c': cons, cons?, cn, c-strlen, char-code
// =====================================================================

/// C: zincvm.c:1867-1870 cons.  valCons roots its by-value params internally
/// (values.zig, C:274-294) — safe by construction.
fn primCons(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valCons(vm.gc, a1, a2);
}

/// C: zincvm.c:1871-1873 cons?.
fn primConsP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .cons);
}

/// Helper: rendered length of one cn operand; numbers are pre-formatted into
/// `t` (a non-GC stack buffer) so the second pass needs no re-format.
fn cnMeasure(v: Value, t: *[32]u8) usize {
    return switch (v.tag) {
        .string => @intCast(@max(v.payload.str.len, 0)),
        .number => blk: {
            const s = std.fmt.bufPrint(t, "{d}", .{v.payload.number}) catch unreachable;
            break :blk s.len;
        },
        .symbol => values.symSlice(v).len,
        .boolean => if (v.payload.boolean != 0) @as(usize, 4) else 5,
        .nil => 2,
        else => 3,
    };
}

/// Helper: write one cn operand into `buf` (l = cnMeasure length).  Interior
/// reads (str.data / sym.name) go through the caller's ROOTED locals.
fn cnWrite(buf: []u8, v: Value, l: usize, t: *const [32]u8) void {
    switch (v.tag) {
        .string => @memcpy(buf[0..l], values.strSlice(v)[0..l]),
        .number => @memcpy(buf[0..l], t[0..l]),
        .symbol => @memcpy(buf[0..l], values.symSlice(v)[0..l]),
        .boolean => @memcpy(buf[0..l], if (v.payload.boolean != 0) "true" else "false"),
        .nil => @memcpy(buf[0..2], "[]"),
        else => @memcpy(buf[0..3], "[?]"),
    }
}

/// C: zincvm.c:1879-1916 cn.  Two-pass: measure (into non-GC stack buffers),
/// then ONE GC_STR alloc with a1/a2 ROOTED across it; interior reads after
/// the alloc go through the rooted locals (C:1900-1921).
fn primCn(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var a1 = varray.vaPop(stack);
    var a2 = varray.vaPop(stack);
    var t1: [32]u8 = undefined;
    var t2: [32]u8 = undefined;
    const l1 = cnMeasure(a1, &t1);
    const l2 = cnMeasure(a2, &t2);
    const total = l1 + l2;
    g.rootPushValue(&a1);
    g.rootPushValue(&a2);
    const buf = g.allocRaw(total + 1);
    cnWrite(buf[0..l1], a1, l1, &t1);
    cnWrite(buf[l1..][0..l2], a2, l2, &t2);
    buf[total] = 0;
    g.rootPop();
    g.rootPop();
    acc.* = .{ .tag = .string, .payload = .{ .str = .{
        .data = buf,
        .len = @intCast(total),
    } } };
}

/// P2-9 native Str.repeat — repeat n s == s concatenated n times, ONE
/// allocRaw(slen*n+1) instead of the Elm loop's n x String.append (n allocs,
/// quadratic byte copy).  a1 = n (count, top — the wrapper pushes arg0 then
/// arg1, so the top is the FIRST source arg; see the cn hand-bundle
/// `m S"world" S"hello" g cn p` == "helloworld").  a2 (the string) is ROOTED
/// across allocRaw (pitfall 6 — str.data is an interior GC pointer).  n<=0 or
/// an empty string -> "" (byte-identical to the Elm loop).  Body filled by
/// doubling memcpy (each byte copied O(log n) times).
fn primRepeat(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    const a1 = varray.vaPop(stack); // count
    var a2 = varray.vaPop(stack); // string
    const n: i64 = a1.payload.number;
    const slen: i64 = a2.payload.str.len;
    if (n <= 0 or slen <= 0) {
        acc.* = values.valString(g, "");
        return;
    }
    const total = std.math.mul(usize, @intCast(slen), @intCast(n)) catch
        return vm.throwShen("repeat: out of memory");
    g.rootPushValue(&a2);
    const buf = g.allocRaw(total + 1);
    const src = values.strSlice(a2); // fresh read via the rooted slot
    @memcpy(buf[0..@intCast(slen)], src);
    var covered: usize = @intCast(slen);
    while (covered < total) {
        const chunk = @min(covered, total - covered);
        @memcpy(buf[covered .. covered + chunk], buf[0..chunk]);
        covered += chunk;
    }
    buf[total] = 0;
    g.rootPop();
    acc.* = .{ .tag = .string, .payload = .{ .str = .{
        .data = buf,
        .len = @intCast(total),
    } } };
}

/// C: zincvm.c:1937-1939 c-strlen (O(1) string length).
fn primCStrlen(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valNumber(a.payload.str.len);
}

/// C: zincvm.c:1943-1952 char-code (byte at index; -1 out of bounds).
fn primCharCode(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack); // string
    const n = varray.vaPop(stack); // index
    const i = n.payload.number;
    const len: i64 = a.payload.str.len;
    if (i >= 0 and i < len) {
        const data = a.payload.str.data.?;
        acc.* = values.valNumber(@intCast(data[@intCast(i)]));
    } else {
        acc.* = values.valNumber(-1);
    }
}

// =====================================================================
//  'e': emptylist, empty?
// =====================================================================

/// C: zincvm.c:2087-2091 emptylist: (number 0) -> nil; anything else falls
/// through the C dispatch to `unknown` -> return -1 (error.Halt here).
fn primEmptylist(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    if (a.tag == .number and a.payload.number == 0) {
        acc.* = values.valNil();
        return;
    }
    return error.Halt; // C falls through to unknown
}

/// C: zincvm.c:2094-2096 empty?.
fn primEmptyP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .nil);
}

// =====================================================================
//  'f': fst, function?
// =====================================================================

/// C: zincvm.c:2152-2155 fst — no nil guard in C (NULL deref); the .? unwrap
/// is the parity crash.
fn primFst(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = a.payload.cons.car.?.*;
}

// =====================================================================
//  'h': hd
// =====================================================================

/// C: zincvm.c:2264-2269 hd (nil -> nil; else car).
fn primHd(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    if (a.tag == .nil) {
        acc.* = values.valNil();
        return;
    }
    acc.* = a.payload.cons.car.?.*;
}

// =====================================================================
//  'i': intern
// =====================================================================

/// C: zincvm.c:2279-2286 intern (string -> symbol; 255-byte cap).
fn primIntern(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a = varray.vaPop(stack);
    var buf: [256]u8 = undefined;
    const raw_len: usize = @intCast(@max(a.payload.str.len, 0));
    const n = @min(raw_len, 255);
    @memcpy(buf[0..n], values.strSlice(a)[0..n]);
    acc.* = symbols.valSymbol(&vm.symbols, buf[0..n]);
}

// =====================================================================
//  'n': number?
// =====================================================================

/// C: zincvm.c:2339-2341 number?.
/// M4: floats are numbers too (Elm `number?`/`isNumber` parity).
fn primNumberP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .number or a.tag == .float);
}

// =====================================================================
//  'r': reverse
// =====================================================================

/// C: zincvm.c:2508-2526 reverse — acc-built reversal with a/out rooted
/// across the valCons loop (C:2418-2426 rooting, 2 roots).
fn primReverse(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var a = varray.vaPop(stack);
    if (a.tag != .nil and a.tag != .cons)
        return vm.throwShen("attempt to reverse a non-list");
    g.rootPushValue(&a);
    var out = values.valNil();
    g.rootPushValue(&out);
    while (a.tag == .cons) {
        out = values.valCons(g, a.payload.cons.car.?.*, out);
        a = a.payload.cons.cdr.?.*;
    }
    acc.* = out;
    g.rootPop();
    g.rootPop();
}

// =====================================================================
//  's': string?, simple-error, str, snd, substring, shen.str->bytes,
//       shen.bytes->string
// =====================================================================

/// C: zincvm.c:2290-2292 string?.
fn primStringP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .string);
}

/// C: zincvm.c:2293-2304 simple-error.  The message is copied into a STACK
/// buffer first (C's msg[256]) — a GC-interior str.data pointer must not
/// survive into throwShen's valError alloc (the popped `a` is unrooted).
/// repl_mode's longjmp exit is omitted with the meta REPL.
fn primSimpleError(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = acc; // C overwrites acc's slot only via the error path
    const a = varray.vaPop(stack);
    var buf: [256]u8 = undefined;
    var msg: []const u8 = "simple-error called";
    if (a.tag == .string) {
        const s = values.strSlice(a);
        const n = @min(s.len, 255); // C snprintf("%.*s", a.str.len <= 255)
        @memcpy(buf[0..n], s[0..n]);
        msg = buf[0..n];
    }
    return vm.throwShen(msg); // throwShen copies msg before buf dies
}

/// C: zincvm.c:2305-2341 str.  Scalars take a non-GC stack buffer; the
/// composite case grows a C-heap buffer (malloc/realloc parity) until
/// strValue fits, then valString copies from the non-GC buffer (the
/// valString CONTRACT holds).
fn primStr(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    const a = varray.vaPop(stack);
    switch (a.tag) {
        .symbol => acc.* = values.valString(g, values.symSlice(a)),
        .string => acc.* = a,
        .number => {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{a.payload.number}) catch unreachable;
            acc.* = values.valString(g, s);
        },
        .float => {
            var buf: [64]u8 = undefined;
            const s = values.floatText(&buf, a.payload.float);
            acc.* = values.valString(g, s);
        },
        .boolean => acc.* = values.valString(
            g,
            if (a.payload.boolean != 0) "true" else "false",
        ),
        else => {
            const a_alloc = std.heap.page_allocator;
            var cap: usize = 4096;
            while (true) {
                const buf = a_alloc.alloc(u8, cap) catch
                    return vm.throwShen("str: out of memory");
                var w: std.Io.Writer = .fixed(buf);
                if (values.strValue(&w, a, 0)) |_| {
                    const s = w.buffered();
                    acc.* = values.valString(g, s);
                    a_alloc.free(buf);
                    return;
                } else |e| {
                    a_alloc.free(buf);
                    if (e != error.NoSpaceLeft) return vm.throwShen("str: write error");
                    cap *= 2; // grow-until-fits (C realloc loop)
                    if (cap > (1 << 30)) return vm.throwShen("str: out of memory");
                }
            }
        },
    }
}

/// C: zincvm.c:2511-2513 snd — no nil guard (parity crash via .?).
fn primSnd(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = a.payload.cons.cdr.?.*;
}

/// C: zincvm.c:2514-2533 substring — clamped Str[Start..Start+Len); `s`
/// rooted across valStringFrom (C:2627 comment: keep the source alive — the
/// copy may alias s's buffer and s may be in the nursery).
fn primSubstring(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var s = varray.vaPop(stack); // string
    const st = varray.vaPop(stack); // start
    const ln = varray.vaPop(stack); // len
    var start = st.payload.number;
    var len = ln.payload.number;
    const slen: i64 = s.payload.str.len;
    if (start < 0) start = 0;
    if (start > slen) start = slen;
    if (len < 0) len = 0;
    if (start + len > slen) len = slen - start;
    g.rootPushValue(&s);
    const r = values.valStringFrom(g, &s, @intCast(start), @intCast(len));
    g.rootPop();
    acc.* = r;
}

/// C: zincvm.c:2542-2549 shen.str->bytes — string -> list of byte codes,
/// built back-to-front so byte[0] lands at the head; `a` and `out` rooted
/// across the valCons loop, interior reads through the rooted `a`.
fn primStrToBytes(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var a = varray.vaPop(stack);
    if (a.tag != .string)
        return vm.throwShen("attempt to convert a non-string with str->bytes");
    g.rootPushValue(&a);
    var out = values.valNil();
    g.rootPushValue(&out);
    var i: i64 = a.payload.str.len;
    while (i > 0) {
        i -= 1;
        const data = a.payload.str.data.?; // fresh read via the rooted slot
        out = values.valCons(g, values.valNumber(@intCast(data[@intCast(i)])), out);
    }
    acc.* = out;
    g.rootPop();
    g.rootPop();
}

/// C: zincvm.c:2562-2573 shen.bytes->string — count, ONE GC_STR alloc with
/// `a` rooted, then re-walk the list THROUGH the rooted `a` (cells may have
/// moved during the alloc).
fn primBytesToStr(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    var a = varray.vaPop(stack);
    if (a.tag != .nil and a.tag != .cons)
        return vm.throwShen("attempt to convert a non-list with bytes->string");
    g.rootPushValue(&a);
    var n: usize = 0;
    var cur = a;
    while (cur.tag == .cons) {
        n += 1;
        cur = cur.payload.cons.cdr.?.*;
    }
    const buf = g.allocRaw(n + 1);
    var i: usize = 0;
    cur = a; // restart through the rooted slot
    while (cur.tag == .cons) {
        buf[i] = @truncate(@as(u64, @bitCast(cur.payload.cons.car.?.payload.number)));
        i += 1;
        cur = cur.payload.cons.cdr.?.*;
    }
    buf[n] = 0;
    g.rootPop();
    acc.* = .{ .tag = .string, .payload = .{ .str = .{
        .data = buf,
        .len = @intCast(n),
    } } };
}

// =====================================================================
//  't': tl
// =====================================================================

/// C: zincvm.c:2625-2630 tl (nil -> nil; else cdr).
fn primTl(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    if (a.tag == .nil) {
        acc.* = values.valNil();
        return;
    }
    acc.* = a.payload.cons.cdr.?.*;
}

// =====================================================================
//  'v': value
// =====================================================================

/// C: zincvm.c:2692-2694 value (value_get carries the symbol fallback).
fn primValue(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a = varray.vaPop(stack);
    acc.* = vm.valueGet(values.symSlice(a));
}

// =====================================================================
//  Arithmetic: +, -, *, /
// =====================================================================

/// C: zincvm.c:2743-2746 + (wrapping — two's-complement, the behavior of
/// the compiled C on every target we care about).
///
/// M4 runtime tag dispatch: (Int,Int) stays wrapping Int; any Float operand
/// promotes Int->Float and computes in f64 (Elm numeric-literal polymorphism:
/// 1 + 2.5 = 3.5).  NO type guard — bare arithmetic reads the number bits
/// directly (shen semantics, AGENTS.md; the metacircular interpreter relies
/// on it), while Float operands promote as fx-ui's M4 requires.
fn primAdd(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // Bare arithmetic (shen semantics, AGENTS.md): NO type guard — the
    // metacircular interpreter passes Shen-level values the safe-wrapper
    // layer has validated, and shen's VM reads the number bits directly.
    // Float support (fx-ui M4): promote when either operand is a float.
    if (a1.tag == .float or a2.tag == .float) {
        acc.* = values.valFloat(asFloat(a1) + asFloat(a2));
    } else {
        acc.* = values.valNumber(a1.payload.number +% a2.payload.number);
    }
}

/// C: zincvm.c:2748-2751 -.
fn primSub(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // Bare arithmetic (shen semantics, AGENTS.md): no type guard.
    if (a1.tag == .float or a2.tag == .float) {
        acc.* = values.valFloat(asFloat(a1) - asFloat(a2));
    } else {
        acc.* = values.valNumber(a1.payload.number -% a2.payload.number);
    }
}

/// C: zincvm.c:2753-2756 *.
fn primMul(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // Bare arithmetic (shen semantics, AGENTS.md): no type guard.
    if (a1.tag == .float or a2.tag == .float) {
        acc.* = values.valFloat(asFloat(a1) * asFloat(a2));
    } else {
        acc.* = values.valNumber(a1.payload.number *% a2.payload.number);
    }
}

/// C: zincvm.c:2758-2761 /.  Elm `//` — INT-only division (Elm splits integer
/// `//` from float `/`; the latter is the separate `f/` prim).  Division by
/// zero traps (C: SIGFPE; Zig: panic).
fn primDiv(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // Bare integer division (shen semantics, AGENTS.md): no type guard.
    acc.* = values.valNumber(@divTrunc(a1.payload.number, a2.payload.number));
}

/// M4 `f/` — Elm `/`: ALWAYS f64 division, promoting Int->Float so 2 / 3 =
/// 0.666... (and x / 0.0 = Infinity, matching Elm's float division).
fn primFdiv(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // ALWAYS float division (fx-ui M4); no int type guard — f/ is the
    // dedicated float-division prim (shen has no f/; this is fx-ui-only).
    acc.* = values.valFloat(asFloat(a1) / asFloat(a2));
}

/// M4 numeric promote: a .number/.float Value as f64.  Callers guarantee the
/// tag is numeric (see the dispatch guards in the arithmetic/comparison prims).
fn asFloat(v: Value) f64 {
    return switch (v.tag) {
        .float => v.payload.float,
        .number => @floatFromInt(v.payload.number),
        else => unreachable,
    };
}

// =====================================================================
//  Comparison: =, <, <=, <-address, >, >=
// =====================================================================

/// C: zincvm.c:2765-2787 = — tag-pairwise, deep_equal for cons/vector,
/// SYMBOL-vs-PRIM name comparison in BOTH directions.
fn primEq(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    if (a1.tag == .number and a2.tag == .number) {
        acc.* = values.valBoolean(a1.payload.number == a2.payload.number);
    } else if (a1.tag == .string and a2.tag == .string) {
        acc.* = values.valBoolean(a1.payload.str.len == a2.payload.str.len and
            std.mem.eql(u8, values.strSlice(a1), values.strSlice(a2)));
    } else if (a1.tag == .symbol and a2.tag == .symbol) {
        acc.* = values.valBoolean(std.mem.eql(u8, values.symSlice(a1), values.symSlice(a2)));
    } else if (a1.tag == .boolean and a2.tag == .boolean) {
        acc.* = values.valBoolean(a1.payload.boolean == a2.payload.boolean);
    } else if ((a1.tag == .float or a1.tag == .number) and
        (a2.tag == .float or a2.tag == .number))
    {
        // M4: promote Int/Float so = and /= treat 2 == 2.0 as true (Elm
        // parity + consistency with the promoted < <= > >=).  The Int/Int
        // branch above already handled both-number, so asFloat sees at least
        // one .float here; both sides are numeric so else=>unreachable is
        // unreached.  IEEE NaN!=NaN preserved.  NOTE: the review fix's
        // literal `a1.tag == .float or a2.tag == .float` guard was widened
        // to both-numeric so a float-vs-nonnumber mismatch (2.0 == "x")
        // still falls through to false instead of panicking in asFloat.
        acc.* = values.valBoolean(asFloat(a1) == asFloat(a2));
    } else if ((a1.tag == .cons and a2.tag == .symbol) or
        (a1.tag == .symbol and a2.tag == .cons))
    {
        acc.* = values.valBoolean(false);
    } else if (a1.tag == .symbol and a2.tag == .prim) {
        acc.* = values.valBoolean(std.mem.eql(u8, values.symSlice(a1), values.primSlice(a2)));
    } else if (a1.tag == .prim and a2.tag == .symbol) {
        acc.* = values.valBoolean(std.mem.eql(u8, values.primSlice(a1), values.symSlice(a2)));
    } else if (a1.tag == .cons and a2.tag == .cons) {
        acc.* = values.valBoolean(values.deepEqual(a1, a2, 0));
    } else if (a1.tag == .vector and a2.tag == .vector) {
        acc.* = values.valBoolean(values.deepEqual(a1, a2, 0));
    } else {
        acc.* = values.valBoolean(a1.tag == .nil and a2.tag == .nil);
    }
}

/// C: zincvm.c:2789-2792 <.
/// M4 runtime tag dispatch: promote Int/Float across the comparison (2 < 2.5
/// is true); non-numeric operands compare False (unchanged).
fn primLt(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    if ((a1.tag == .float or a1.tag == .number) and
        (a2.tag == .float or a2.tag == .number))
    {
        if (a1.tag == .float or a2.tag == .float) {
            acc.* = values.valBoolean(asFloat(a1) < asFloat(a2));
        } else {
            acc.* = values.valBoolean(a1.payload.number < a2.payload.number);
        }
    } else {
        acc.* = values.valBoolean(false);
    }
}

/// C: zincvm.c:2793-2796 <=.
fn primLe(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    if ((a1.tag == .float or a1.tag == .number) and
        (a2.tag == .float or a2.tag == .number))
    {
        if (a1.tag == .float or a2.tag == .float) {
            acc.* = values.valBoolean(asFloat(a1) <= asFloat(a2));
        } else {
            acc.* = values.valBoolean(a1.payload.number <= a2.payload.number);
        }
    } else {
        acc.* = values.valBoolean(false);
    }
}

/// C: zincvm.c:2797-2801 <-address (no bounds guard — parity crash).
fn primAddressGet(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const vec = varray.vaPop(stack);
    const idx = varray.vaPop(stack);
    const i: usize = @intCast(idx.payload.number);
    acc.* = vec.payload.vector.data.?[i];
}

/// C: zincvm.c:2803-2806 >.
fn primGt(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    if ((a1.tag == .float or a1.tag == .number) and
        (a2.tag == .float or a2.tag == .number))
    {
        if (a1.tag == .float or a2.tag == .float) {
            acc.* = values.valBoolean(asFloat(a1) > asFloat(a2));
        } else {
            acc.* = values.valBoolean(a1.payload.number > a2.payload.number);
        }
    } else {
        acc.* = values.valBoolean(false);
    }
}

/// C: zincvm.c:2807-2810 >=.
fn primGe(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    if ((a1.tag == .float or a1.tag == .number) and
        (a2.tag == .float or a2.tag == .number))
    {
        if (a1.tag == .float or a2.tag == .float) {
            acc.* = values.valBoolean(asFloat(a1) >= asFloat(a2));
        } else {
            acc.* = values.valBoolean(a1.payload.number >= a2.payload.number);
        }
    } else {
        acc.* = values.valBoolean(false);
    }
}

// =====================================================================
//  Bitwise: JS int32 semantics (elm/core Bitwise, needed by the Array port).
//  ToInt32 truncates toward zero, the shift count is masked to 5 bits
//  (count & 31), and zero-fill right shift yields unsigned 0..2^32-1.
// =====================================================================

/// JS ToInt32 truncates toward zero; 0-for-nonnumeric mirrors the primLt
/// tolerance (Bitwise on a non-number can't be typed in Elm, so this is
/// VM-level tolerance only).
fn bitOperand(v: Value) i32 {
    return switch (v.tag) {
        .float => @intFromFloat(v.payload.float),
        .number => @truncate(v.payload.number),
        else => 0,
    };
}

/// JS masks the shift count mod 32 (two's-complement bits: -1 & 31 == 31).
fn shiftAmount(v: Value) u5 {
    return @intCast(@as(u64, @bitCast(v.payload.number)) & 31);
}

fn primBitwiseAnd(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    // Ops stay in i32 range, so the i64 result is exact.
    acc.* = values.valNumber(@as(i64, bitOperand(a1) & bitOperand(a2)));
}

fn primBitwiseOr(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valNumber(@as(i64, bitOperand(a1) | bitOperand(a2)));
}

fn primBitwiseXor(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valNumber(@as(i64, bitOperand(a1) ^ bitOperand(a2)));
}

fn primBitwiseNot(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valNumber(@as(i64, ~bitOperand(a)));
}

/// ZINC RTL: a1 = leftmost = count, a2 = value (Bitwise.shiftLeftBy count
/// value).  u32 << u5 discards the high bits (plain Zig <<), matching JS.
fn primShiftLeft(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    const r: u32 = @as(u32, @bitCast(bitOperand(a2))) << shiftAmount(a1);
    acc.* = values.valNumber(@as(i64, @as(i32, @bitCast(r))));
}

/// Arithmetic right shift (sign-extending).
fn primShiftRight(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valNumber(@as(i64, bitOperand(a2) >> shiftAmount(a1)));
}

/// Zero-fill right shift: >>> yields unsigned 0..2^32-1 (Elm's
/// shiftRightZfBy 1 -32 == 2147483632).
fn primShiftRightZf(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    const r: u32 = @as(u32, @bitCast(bitOperand(a2))) >> shiftAmount(a1);
    acc.* = values.valNumber(@as(i64, r));
}

// =====================================================================
//  '@': @p
// =====================================================================

/// C: zincvm.c:2814-2817 @p — valCons roots its params internally.
fn primAtP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valCons(vm.gc, a1, a2);
}
