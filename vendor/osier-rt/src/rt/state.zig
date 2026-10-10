//! src/rt/state.zig — the Vm struct (M0 skeleton + M1 interner + M2 tables
//! + M4 DECISION-A error model).
//!
//! C origin: the VM's global interpreter state (zincvm.c statics) gathered
//! into one struct.  M0 adds the skeleton: owns `*Gc`, and roots `err_slot`
//! ONCE at init (this is the C "S3 cf.error_val rooting handled once" —
//! plan DECISION A).  M1 adds the symbol interner.  M2 adds the defun/values
//! global tables (tables.zig) plus their GC registration and the initGlobals
//! stub.  M4 adds VmError + throwShen + instr_limit.
//!
//! The csexp bundle loader (loadBundle) moved to vendor/zinc-vm's parser.zig
//! with the interpreter: it is Shen-image support only.  The Shen catch
//! machinery (CatchSite/catch_chain/in_trap_error) is DELETED with
//! trap-error (Osier has no exceptions and its front end cannot emit
//! trap-error); VmError keeps error.ShenError as the error-REPORTING channel
//! (throwShen + the once-rooted err_slot).
//!
//! err_slot is rooted via rootPushValue at init and popped at deinit, so it
//! never needs re-rooting: every ShenError message built by a future throw
//! writes into this permanently-rooted slot.  NOTE: the root holds the ADDRESS
//! of `vm.err_slot`, so the Vm must not be moved/copied after init (tests keep
//! it in one local; later milestones heap-allocate it).  The same address
//! stability requirement covers `&vm.defun_table_cap` / `&vm.values_table_cap`,
//! which the GC reads at scan time.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const symbols = @import("symbols.zig");
const tables = @import("tables.zig");
const values = @import("values.zig");
const prims = @import("prims.zig");
const streams = @import("streams.zig");

const Gc = gc.Gc;

/// Plan DECISION A: C's setjmp/longjmp CatchFrame chain (zincvm.c:706-720
/// vm_catch_chain / vm_throw) becomes Zig error unions.  error.Halt is the C
/// `exec_primitive() < 0` hard stop (non-catchable, acc preserved);
/// error.ShenError is the longjmp (the catch chain itself is DELETED with
/// trap-error — ShenError now unwinds to the host, which reports it).
pub const VmError = error{ ShenError, Halt };

/// M10 frame-stack pool: max idle old-gen CALLFRAME_ARRAYs held for reuse
/// across vmExecEnv entries (see interp.zig frameStackAcquire/Release).
/// Bounded to real vmExecEnv nesting depth — outer entry + N>A peel = 2.
/// Retaining more than the nesting depth never pays off (the LIFO free-list
/// can only hand them back at that depth) and pins ~3 MB per extra array:
/// at 3 idle arrays (9 MB) the base live set exceeds the grown 32 MB heap's
/// old-gen threshold (8 MB), forcing a failed grow_heap per old-gen alloc on
/// reserve-constrained heaps.  2 x 3 MB = 6 MB stays under the threshold.
pub const FRAME_POOL_MAX: usize = 2;

/// M12 value-stack pool: max idle VALUE_ARRAYs (value stacks) held for reuse
/// across vmExecEnv entries (see interp.zig stackPoolAcquire/Release).  Unlike
/// the frame pool, idle arrays are ALL-NIL at rest (release clears [0..len)),
/// so the full-capacity drain scan pins NOTHING and retention is impossible —
/// 16 is safe (the 3 MB-per-array math behind FRAME_POOL_MAX=2 does not
/// apply: a cap-12 stack is ~1 page).  Pooled arrays are rooted persistently
/// at init, so an idle array survives every collect below the vmExecEnv entry
/// watermark.
pub const STACK_POOL_MAX: usize = 16;

/// One idle value-stack pool slot: the array base + its TRUE physical capacity
/// (restored on acquire so vaPush's grow math reads the real cap).
pub const StackPoolSlot = struct {
    data: ?[*]types.Value = null,
    cap: i32 = 0,
};

/// C: zincvm.c:706 vm_catch_chain — DELETED with trap-error (the Shen catch
/// machinery; see the module doc).

pub const Vm = struct {
    /// Owned *Gc — the collector this VM allocates from.
    gc: *Gc,
    /// Rooted ONCE at init (plan DECISION A): the ShenError value slot.
    err_slot: types.Value,
    /// Dynamic symbol interner (M1).
    symbols: symbols.SymbolInterner,
    /// Defun global table (M2): page_allocator zeroed array OUTSIDE the GC heap
    /// (C BSS parity), registered via gc.registerGlobalTable.  [ * ]Types.TableEntry
    /// pointing at DEFUN_TABLE_CAP entries; the cap field is the GC's length
    /// register (sizes the dirty-defuns bitset).
    defun_table: [*]types.TableEntry = undefined,
    /// C: zincvm.c:479 defun_table_cap — read by the GC at scan time.
    defun_table_cap: i32 = @intCast(tables.DEFUN_TABLE_CAP),
    /// Values global table (M2): page_allocator zeroed array, registered via
    /// gc.registerValuesTable (always full-scanned).
    values_table: [*]types.TableEntry = undefined,
    /// C: zincvm.c:480 values_table_cap.
    values_table_cap: i32 = @intCast(tables.VALUES_TABLE_CAP),
    /// C: zincvm.c:3146-3153 get_instr_limit — hard instruction budget,
    /// default 5e9.  C caches the $ZINCVM_INSTR_LIMIT env override per
    /// vm_exec_env entry; the port keeps the constant default and exposes
    /// the field for the host to set directly (init comment).
    instr_limit: u64 = 5_000_000_000,
    /// Cumulative instructions executed across all vmExec calls (harness
    /// instrumentation; no C counterpart).
    instr_exec: u64 = 0,
    /// M6 string-stream registry (streams.zig): fixed array of 8 slots + a
    /// count, zero-initialized (`.{ }`), so a fresh Vm needs no setup.
    streams: streams.StreamRegistry = .{},
    /// M10 frame-stack pool: a LIFO free-list of up to FRAME_POOL_MAX idle
    /// old-gen CALLFRAME_ARRAYs (65536 x 48 B ≈ 3 MB each), reused across
    /// vmExecEnv entries instead of bump-allocating a fresh array per call.
    /// Each slot is a PERSISTENT ROOT_PTR pushed at init (err_slot
    /// precedent), so an idle pooled array is pinned below every vmExecEnv
    /// entry watermark — its full-capacity drain scan (collect.zig) then
    /// sees an all-null body and pins nothing.
    frame_pool: [FRAME_POOL_MAX]?[*]types.CallFrame = .{null} ** FRAME_POOL_MAX,
    /// Number of non-null entries in frame_pool[0..frame_pool_live).
    frame_pool_live: usize = 0,
    /// Instrumentation (instr_exec precedent): pool hits/misses across runs.
    frame_pool_hits: u64 = 0,
    frame_pool_misses: u64 = 0,
    /// M12 value-stack pool: a LIFO free-list of up to STACK_POOL_MAX idle
    /// VALUE_ARRAYs (value stacks), reused across vmExecEnv entries and apply
    /// frame pushes instead of bump-allocating a fresh array per frame.  Each
    /// slot's `data` is a PERSISTENT ROOT_PTR pushed at init (err_slot
    /// precedent); idle arrays are all-nil so the full-capacity drain scan
    /// pins nothing.
    stack_pool: [STACK_POOL_MAX]StackPoolSlot = [_]StackPoolSlot{.{ .data = null, .cap = 0 }} ** STACK_POOL_MAX,
    /// Number of non-empty entries in stack_pool[0..stack_pool_live).
    stack_pool_live: usize = 0,
    /// Instrumentation: pool hits/misses across runs.
    stack_pool_hits: u64 = 0,
    stack_pool_misses: u64 = 0,
    /// M11 tail-env reuse (interp.zig appterm N==A): hits = a tail call
    /// reused the current env array (the dead caller env fits the new
    /// arity); misses = a tail call had to allocate a fresh exact-size env
    /// array (first tail call after a frame restore, or the new env is
    /// larger than the retained physical capacity).
    env_reuse_hits: u64 = 0,
    env_reuse_misses: u64 = 0,

    /// Initialize a Vm into `vm` (caller-provided storage so `&vm.err_slot` /
    /// `&vm.defun_table_cap` / `&vm.values_table_cap` stay stable across the
    /// rooting and GC registration), rooting err_slot once.  Order (plan M2):
    /// alloc+zero tables -> gc.registerGlobalTable/registerValuesTable ->
    /// initGlobals.  The symbol interner is created empty (lazily allocates on
    /// first intern).
    pub fn init(vm: *Vm, g: *Gc) void {
        const a = std.heap.page_allocator;
        vm.* = .{
            .gc = g,
            .err_slot = .{ .tag = .nil, .payload = .{ .number = 0 } },
            .symbols = symbols.SymbolInterner.init(),
        };
        // alloc + zero the tables (C BSS calloc parity).
        const da = a.alloc(types.TableEntry, tables.DEFUN_TABLE_CAP) catch
            std.debug.panic("Vm.init: defun table alloc failed", .{});
        @memset(da, emptyEntry);
        vm.defun_table = da.ptr;
        const va = a.alloc(types.TableEntry, tables.VALUES_TABLE_CAP) catch
            std.debug.panic("Vm.init: values table alloc failed", .{});
        @memset(va, emptyEntry);
        vm.values_table = va.ptr;

        // Register with the GC BEFORE initGlobals stores any nursery value.
        g.registerGlobalTable(vm.defun_table, &vm.defun_table_cap);
        g.registerValuesTable(vm.values_table, &vm.values_table_cap);

        // C: zincvm.c:3146-3153 get_instr_limit reads $ZINCVM_INSTR_LIMIT per
        // vm_exec_env entry.  Zig 0.16 has no library-level env accessor
        // (std.posix.getenv / std.process.getEnvVarOwned are gone); the port
        // keeps the 5e9 DEFAULT here and lets the host set vm.instr_limit
        // directly before exec (strictly more flexible; M7's harness reads
        // the env once if the knob is needed).
        vm.instr_limit = 5_000_000_000;

        g.rootPushValue(&vm.err_slot);

        // M10/M12: persistent pool-slot roots (err_slot precedent), pushed at
        // init and popped in reverse at deinit so idle pooled arrays stay
        // pinned below every vmExecEnv entry watermark.  Stack-pool slots root
        // the `data` field (the GC-managed array base).
        for (0..FRAME_POOL_MAX) |i| g.rootPushPtr(@ptrCast(&vm.frame_pool[i]));
        for (0..STACK_POOL_MAX) |i| g.rootPushPtr(@ptrCast(&vm.stack_pool[i].data));

        vm.initGlobals();
    }

    /// Pop the err_slot root, free the table arrays and tear down the interner.
    pub fn deinit(vm: *Vm) void {
        const a = std.heap.page_allocator;
        a.free(vm.defun_table[0..@as(usize, @intCast(vm.defun_table_cap))]);
        a.free(vm.values_table[0..@as(usize, @intCast(vm.values_table_cap))]);
        // Pop the pool-slot roots in reverse (LIFO) BEFORE err_slot to keep
        // the root stack balanced.  Stack-pool slots were pushed last, so they
        // pop first.
        var i = STACK_POOL_MAX;
        while (i > 0) {
            i -= 1;
            vm.gc.rootPop(); // stack_pool[i].data
        }
        i = FRAME_POOL_MAX;
        while (i > 0) {
            i -= 1;
            vm.gc.rootPop(); // frame_pool[i]
        }
        vm.gc.rootPop(); // err_slot
        vm.symbols.deinit();
        vm.* = undefined;
    }

    // -----------------------------------------------------------------
    //  Defun / values table wrappers (fallback semantics live here so the
    //  prim half can be added in M5 when prims.zig exists).
    // -----------------------------------------------------------------

    /// C: zincvm.c:537-590 defun_set — insert/overwrite, always dirty-marked.
    pub fn defunSet(self: *Vm, name: []const u8, v: types.Value) void {
        tables.defunSet(self.gc, self.defun_table, tables.DEFUN_TABLE_CAP, name, v);
    }

    /// C: zincvm.c:593-618 defun_get — explicit entry, else the primitive /
    /// symbol fallback.  M5: known prim -> valPrim (the canonical table name
    /// literal), else valSymbol (macros/*stinput* must stay symbols).
    pub fn defunGet(self: *Vm, name: []const u8) types.Value {
        if (tables.defunLookup(self.defun_table, tables.DEFUN_TABLE_CAP, name)) |v| return v;
        if (prims.lookupDef(name)) |def| return values.valPrim(def.name);
        return symbols.valSymbol(&self.symbols, name);
    }

    /// Single-probe .global fetch: one defunLookup instead of the
    /// defunHas + defunGet double probe.  The prim/symbol fallback in
    /// defunGet is unreachable for a missing non-empty name (that throws),
    /// so only the empty-name edge (non-symbol operand) routes through
    /// defunGet, preserving its intern-"" behavior.
    pub fn defunGetChecked(self: *Vm, name: []const u8) VmError!types.Value {
        if (tables.defunLookup(self.defun_table, tables.DEFUN_TABLE_CAP, name)) |v| return v;
        if (name.len == 0) return self.defunGet(name);
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "global not found: {s}", .{name})
            catch "global not found";
        return self.throwShen(msg);
    }

    /// C: zincvm.c:624-642 defun_has — probe without the fallback.
    pub fn defunHas(self: *Vm, name: []const u8) bool {
        return tables.defunHas(self.defun_table, tables.DEFUN_TABLE_CAP, name);
    }

    /// C: zincvm.c:648-665 value_set.
    pub fn valueSet(self: *Vm, name: []const u8, v: types.Value) void {
        tables.valueSet(self.values_table, tables.VALUES_TABLE_CAP, name, v);
    }

    /// C: zincvm.c:668-676 value_get — no primitive fallback: (value +) must
    /// return the bare symbol `+`.
    pub fn valueGet(self: *Vm, name: []const u8) types.Value {
        if (tables.valueLookup(self.values_table, tables.VALUES_TABLE_CAP, name)) |v| return v;
        return symbols.valSymbol(&self.symbols, name);
    }

    // -----------------------------------------------------------------
    //  Error model — plan DECISION A
    // -----------------------------------------------------------------

    /// C: zincvm.c:711-720 vm_throw.  Builds the GC-allocated error value
    /// into vm.err_slot — rooted ONCE at init, which replaces the C S3
    /// per-catch-site error_val rooting — and unwinds as error.ShenError
    /// (the longjmp).  C aborts ("uncaught Shen error") when the catch
    /// chain is empty; the Zig port simply propagates the error to the
    /// host, which decides (harness reports failure).
    pub fn throwShen(vm: *Vm, msg: []const u8) VmError {
        vm.err_slot = values.valError(vm.gc, msg);
        return error.ShenError;
    }

    // -----------------------------------------------------------------
    //  initGlobals — C: zincvm.c:3752-3758
    // -----------------------------------------------------------------

    /// C: zincvm.c:3752-3758 init_globals — register every prim name as a
    /// VAL_PRIM global so [global X] falls back to it.  M5: the full
    /// prim_table (prims.zig), the single source (prims.def in C).
    pub fn initGlobals(self: *Vm) void {
        for (prims.primNames()) |def| self.defunSet(def.name, values.valPrim(def.name));
    }

};

/// A zeroed TableEntry (C `memset(&e,0,sizeof e)` — name=NULL, value tag 0).
const emptyEntry = types.TableEntry{
    .name = null,
    .value = .{ .tag = .nil, .payload = .{ .number = 0 } },
};
