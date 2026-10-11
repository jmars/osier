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
//!
//! THE FLIP (handoff osier-flip, step 6): the 36 PURE prims that had Mid
//! implementations (Mid/RtPrims.elm, differentially proven 92/92 over
//! generated vectors) now live ONLY at the Mid level — compiled call sites
//! call their Rt.* defuns (run.js default route), and their Zig handlers and
//! table rows are DELETED here.  What remains is exactly the HOST surface
//! plus the prims no compiled site can name:
//!   * HOST-ONLY (the host calls them by name through execPrimitive):
//!     the fd layer (write-byte/read-byte/read-file-as-string/open/close),
//!     the process layer (exec-plan/cd/getcwd/getpid/getenv/setenv/glob),
//!     intern, value, simple-error, str, AND @p — @p is pure and its
//!     COMPILED sites route to Mid Rt.@p, but src/effectloop.zig:840,845,907
//!     calls runPrim("@p") internally (stat/listdir/glob result building),
//!     a host path no compiled code touches.
//!   * NO SURFACE SPELLING (unreachable from the Elm front end; no PrimApp
//!     site exists, so nothing compiled can call them and nothing Mid-side
//!     ports them): hd, tl, fst, reverse, append, absvector?.
//! The frozen reference behaviour of the deleted handlers lives in
//! tools/qbe/primsdiff/golden/batches/ (captured pre-deletion, git 8f581b8).

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
    // ---- THE FLIP (osier-flip): the 36 pure prims with Mid implementations
    // are GONE from this table — compiled call sites call their Rt.* defuns.
    // Kept: the HOST surface (fd/process/intern/value/simple-error/str/@p)
    // and the prims with no surface spelling (below).  The frozen reference
    // behaviour of the deleted rows: tools/qbe/primsdiff/golden/batches/.
    // ---- unreachable from the front end, but still the VM's table ----
    .{ .name = "hd", .arity = 1, .func = primHd },
    .{ .name = "tl", .arity = 1, .func = primTl },
    .{ .name = "reverse", .arity = 1, .func = primReverse },
    .{ .name = "append", .arity = 2, .func = primAppend },
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
    // str STAYS with its row: it is HOST-ONLY in classification (the
    // floatText shortest-render + strValue composite printer were NOT ported
    // to Mid), which means COMPILED String.fromFloat sites still emit
    // `rt_prim_str` — the flip's first gate run caught this row missing
    // (float-strF/strI: undefined reference to `rt_prim_str').
    .{ .name = "str", .arity = 1, .func = primStr },
    // ---- tuples / symbols / misc ----
    // @p STAYS: its compiled sites route to Mid Rt.@p, but effectloop.zig
    // calls runPrim("@p") as a HOST path (the flip's one host-referenced
    // pure prim).
    .{ .name = "@p", .arity = 2, .func = primAtP },
    .{ .name = "fst", .arity = 1, .func = primFst },
    .{ .name = "absvector?", .arity = 1, .func = primAbsvectorP },
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
//  'a': absvector?, append   (THE FLIP: absvector, address->, <-address,
//  assoc deleted — Mid Rt.* defuns; see the header)
// =====================================================================

/// C: zincvm.c:1789-1791 absvector?.
fn primAbsvectorP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    _ = vm;
    const a = varray.vaPop(stack);
    acc.* = values.valBoolean(a.tag == .vector);
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
//  'c': (THE FLIP: cons, cons?, cn, repeat, c-strlen, char-code deleted —
//  Mid Rt.* defuns; see the header)
// =====================================================================

// =====================================================================
//  'e': (THE FLIP: emptylist, empty? deleted — Mid Rt.* defuns)
// =====================================================================

// =====================================================================
//  'f': fst   (kept: no surface spelling)
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
//  'n': (THE FLIP: number? deleted — Mid Rt.number?)
// =====================================================================

// =====================================================================
//  'r': reverse   (kept: no surface spelling)
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
//  's': simple-error, str   (THE FLIP: string?, snd, substring,
//  shen.str->bytes, shen.bytes->string deleted — Mid Rt.* defuns)
// =====================================================================

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
/// (THE FLIP: deleted — Mid Rt.snd; the frozen reference behaviour is in
/// tools/qbe/primsdiff/golden/batches/.)

/// C: zincvm.c:2514-2533 substring — clamped Str[Start..Start+Len).
/// (THE FLIP: deleted — Mid Rt.substring.)

/// C: zincvm.c:2542-2549 shen.str->bytes.  (THE FLIP: deleted — Mid
/// Rt.x2eshen_x2estr_x2e_x3ebytes.)

/// C: zincvm.c:2562-2573 shen.bytes->string.  (THE FLIP: deleted — Mid
/// Rt.x2eshen_x2ebytes_x2e_x3estring.)

// =====================================================================
//  't': tl   (kept: no surface spelling)
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
//  Arithmetic / Comparison / Bitwise: (THE FLIP: + - * / f/ = < <= > >=
//  bitwise-and/or/xor/not/shift-left/shift-right/shift-right-zf and the
//  asFloat/bitOperand/shiftAmount helpers DELETED — Mid Rt.* defuns, the
//  36-prim set differentially proven in handoff osier-midrt-fix.  The frozen
//  reference behaviour: tools/qbe/primsdiff/golden/batches/.)
// =====================================================================

// =====================================================================
//  '@': @p
// =====================================================================

/// C: zincvm.c:2814-2817 @p — valCons roots its params internally.
fn primAtP(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const a1 = varray.vaPop(stack);
    const a2 = varray.vaPop(stack);
    acc.* = values.valCons(vm.gc, a1, a2);
}
