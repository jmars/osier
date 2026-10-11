//! tools/qbe/consdiff/consdiff-zig.zig — the ZIG ARM of the cons differential
//! (handoff osier-consspike).  This is NOT part of the QBE runtime; it is a
//! test harness that drives the SAME generated argument vectors the compiled
//! fixture sees, through the REFERENCE implementation:
//!
//!   * the reference entry  — `prims.execPrimitive(vm, "cons", ...)`, the
//!     exact dispatcher the rt_prim generic route and the pass-A direct
//!     entries both call (ONE implementation, prims.prim_table);
//!   * the canonical form   — `values.printValue`, the same printer the
//!     native driver prints results with, so the two arms' outputs are the
//!     same function of the resulting Value graph.
//!
//! The MID arm is tools/qbe/consdiff/Fixture.elm compiled with QBE_MIDCONS=1
//! (every `::` in it routes through the Mid-implemented Rt.cons) and run by
//! the ordinary driver, which prints the entry with printValue.  consdiff.sh
//! requires the two stdout streams to be byte-identical — including under
//! QBE_HEAP_MB=16, so the moving collector churns BOTH sides.
//!
//! Nested lists are built through execPrimitive("cons") chains here — the
//! same construction path the fixture's own list literals take — so every
//! cons-shaped allocation in EITHER arm goes through that arm's cons.
//!
//! SPEC FORMAT (gen.js writes it; keep the grammar in step there):
//!   line 1: "V <n>"; then n lines "<car-spec> | <cdr-spec>" with
//!   n:<int> f:<float> b:0|1 s:<bytes> nil l(S,S,...)

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const rt_mod = @import("rt");
const values = rt_mod.values;
const state = rt_mod.state;
const prims = rt_mod.prims;

const Gc = heap.Gc;
const Value = types.Value;

extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

fn wout(msg: []const u8) void {
    _ = write(1, msg.ptr, msg.len);
}

fn werr(msg: []const u8) void {
    _ = write(2, msg.ptr, msg.len);
}

var g: *Gc = undefined;
var vm: *state.Vm = undefined;
var vmem: state.Vm = undefined;

const HEAP_BYTES: usize = 64 * 1024 * 1024;

// ---------------------------------------------------------------------
//  The spec parser (recursive descent over the whole file, in place)
// ---------------------------------------------------------------------

const Spec = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn peek(self: *Spec) u8 {
        return if (self.pos < self.bytes.len) self.bytes[self.pos] else 0;
    }

    fn advance(self: *Spec) u8 {
        const c = self.peek();
        self.pos += 1;
        return c;
    }

    fn skipSpaces(self: *Spec) void {
        while (self.peek() == ' ' or self.peek() == '\t') self.pos += 1;
    }

    // Read raw bytes until one of the delimiters (not consumed).
    fn until(self: *Spec, delims: []const u8) []const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and
            std.mem.indexOfScalar(u8, delims, self.bytes[self.pos]) == null) : (self.pos += 1)
        {}
        return self.bytes[start..self.pos];
    }
};

fn die(msg: []const u8) noreturn {
    werr("consdiff-zig: ");
    werr(msg);
    werr("\n");
    std.process.exit(1);
}

// One parsed vector half, kept as (kind, slice) so strings need no quoting.
const Parsed = struct {
    kind: u8, // 'n' 'f' 'b' 's' '0' (nil) 'l'
    text: []const u8,
    elems: []Parsed,
};

fn parseSpec(sp: *Spec, arena: std.mem.Allocator) Parsed {
    sp.skipSpaces();
    // "nil" FIRST: it begins with 'n', and matching the `n:` arm on it
    // survives ReleaseFast's disabled asserts as a silently wrong text
    // (found exactly that way — the parser died on the first cdr=nil line).
    if (sp.pos + 3 <= sp.bytes.len and std.mem.eql(u8, sp.bytes[sp.pos .. sp.pos + 3], "nil")) {
        sp.pos += 3;
        return .{ .kind = '0', .text = "", .elems = &.{} };
    }
    const c = sp.advance();
    switch (c) {
        'n', 'f', 'b', 's' => {
            std.debug.assert(sp.advance() == ':');
            const text = sp.until(",)|\n");
            return .{ .kind = c, .text = text, .elems = &.{} };
        },
        'l' => {
            std.debug.assert(sp.advance() == '(');
            var elems: std.ArrayListUnmanaged(Parsed) = .empty;
            sp.skipSpaces();
            if (sp.peek() == ')') {
                _ = sp.advance();
                return .{ .kind = 'l', .text = "", .elems = &.{} };
            }
            while (true) {
                elems.append(arena, parseSpec(sp, arena)) catch die("oom parsing spec");
                sp.skipSpaces();
                const d = sp.advance();
                if (d == ',') continue;
                if (d == ')') break;
                die("bad list syntax in spec");
            }
            return .{ .kind = 'l', .text = "", .elems = elems.items };
        },
        else => die("bad spec token"),
    }
}

// ---------------------------------------------------------------------
//  Value construction — the REFERENCE side
// ---------------------------------------------------------------------

/// cons through the REFERENCE dispatcher: the exact entry the Zig runtime
/// exposes (rt_prim's generic route and pass-A's direct entries both land in
/// `func` from prims.prim_table).  Args are rooted across the call.
fn consRef(car: Value, cdr: Value) Value {
    var buf = [2]Value{ cdr, car }; // first POP (last elem) is args[0] = car
    var live: i32 = 2;
    g.rootPushValueArray(&buf, &live);
    defer g.rootPop();
    var stack: types.ValueArray = .{ .data = &buf, .len = 2, .cap = 2 };
    var acc: Value = .{ .tag = .number, .payload = .{ .number = 0 } };
    g.rootPushValue(&acc);
    defer g.rootPop();
    prims.execPrimitive(vm, "cons", &acc, &stack) catch |e| {
        die(@errorName(e));
    };
    return acc;
}

fn buildValue(p: *const Parsed) Value {
    switch (p.kind) {
        'n' => {
            const n = std.fmt.parseInt(i64, p.text, 10) catch die("bad int in spec");
            return values.valNumber(n);
        },
        'f' => {
            const f = std.fmt.parseFloat(f64, p.text) catch die("bad float in spec");
            return values.valFloat(f);
        },
        'b' => {
            const v = if (p.text.len > 0 and p.text[0] == '1') true else false;
            return values.valBoolean(v);
        },
        's' => return values.valString(g, p.text), // p.text is malloc'd file bytes, never GC memory
        '0' => return values.valNil(),
        'l' => {
            // Right-to-left accumulation, the accumulator rooted across each
            // cons (the same discipline buildArgvList uses in rt.zig).
            var acc = values.valNil();
            g.rootPushValue(&acc);
            defer g.rootPop();
            var i: usize = p.elems.len;
            while (i > 0) {
                i -= 1;
                acc = consRef(buildValue(&p.elems[i]), acc);
            }
            return acc;
        },
        else => die("bad parsed kind"),
    }
}

// ---------------------------------------------------------------------
//  main
// ---------------------------------------------------------------------

// (export, not pub: cc's crt0 resolves the symbol — the rt.zig driver shape.)
export fn main(c_argc: c_int, c_argv: [*]?[*:0]u8) callconv(.c) c_int {
    const argc: usize = @intCast(c_argc);
    if (argc < 2) {
        werr("usage: consdiff-zig <vectors.spec>\n");
        return 2;
    }
    const specPath = std.mem.span(c_argv[1] orelse "");

    // Read the whole spec (plain openat/read — before any GC exists).
    const fd = std.posix.openat(std.posix.AT.FDCWD, specPath, .{ .ACCMODE = .RDONLY }, 0) catch {
        werr("consdiff-zig: cannot open spec\n");
        return 1;
    };
    // (ArrayList's unmanaged form: 0.16's std.ArrayList has no .init)
    var fileBuf: std.ArrayListUnmanaged(u8) = .empty;
    defer fileBuf.deinit(std.heap.page_allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch {
            werr("consdiff-zig: spec read failed\n");
            return 1;
        };
        if (n == 0) break;
        fileBuf.appendSlice(std.heap.page_allocator, chunk[0..n]) catch {
            werr("consdiff-zig: oom reading spec\n");
            return 1;
        };
    }
    _ = std.os.linux.close(fd);

    // First line "V <n>"; every following non-empty line is one vector.
    var lines = std.mem.splitScalar(u8, fileBuf.items, '\n');
    const header = lines.next() orelse {
        werr("consdiff-zig: empty spec\n");
        return 1;
    };
    if (!(header.len >= 2 and header[0] == 'V')) {
        werr("consdiff-zig: bad spec header\n");
        return 1;
    }
    const nVectors = std.fmt.parseInt(usize, std.mem.trim(u8, header[1..], " "), 10) catch {
        werr("consdiff-zig: bad spec count\n");
        return 1;
    };

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // GC + Vm, with the SAME heap knob discipline as the native driver, so
    // QBE_HEAP_MB=16 churns this arm identically (16x reservation etc.).
    const heap_bytes: usize = blk: {
        const env = std.c.getenv("QBE_HEAP_MB") orelse break :blk HEAP_BYTES;
        const s = std.mem.span(env);
        const mb = std.fmt.parseUnsigned(usize, s, 10) catch break :blk HEAP_BYTES;
        if (mb == 0) break :blk HEAP_BYTES;
        break :blk mb * 1024 * 1024;
    };
    var gg = Gc.init(.{
        .heap_bytes = heap_bytes,
        .reserve_bytes = @max(heap_bytes * 16, 64 * 1024 * 1024),
        .verbose = false,
        .verify_collects = std.c.getenv("QBE_GC_VERIFY") != null,
    }) catch {
        werr("consdiff-zig: gc init failed\n");
        return 1;
    };
    g = &gg;
    defer g.deinit();
    vmem.init(&gg);
    vm = &vmem;

    // Build the RESULT LIST the same way the fixture's `all` is built:
    // v0 at the HEAD, so the vectors are consed LAST-FIRST (the fixture's
    // `[ v0, v1, ... ]` lowers to cons v0 (cons v1 ... nil) — iterating the
    // spec forward would hand this arm the REVERSED list and every
    // comparison would diverge; caught by the first full-batch run).
    var acc = values.valNil();
    g.rootPushValue(&acc);
    defer g.rootPop();

    var vecLines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer vecLines.deinit(std.heap.page_allocator);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        vecLines.append(std.heap.page_allocator, line) catch {
            werr("consdiff-zig: oom buffering vectors\n");
            return 1;
        };
    }
    if (vecLines.items.len != nVectors) {
        werr("consdiff-zig: vector count mismatch with the header\n");
        return 1;
    }

    var vi: usize = vecLines.items.len;
    while (vi > 0) {
        vi -= 1;
        const line = vecLines.items[vi];
        const bar = std.mem.indexOfScalar(u8, line, '|') orelse {
            werr("consdiff-zig: vector line without |\n");
            return 1;
        };
        var carSp = Spec{ .bytes = line[0..bar] };
        var cdrSp = Spec{ .bytes = line[bar + 1 ..] };
        const carP = parseSpec(&carSp, arena);
        const cdrP = parseSpec(&cdrSp, arena);
        var r = consRef(buildValue(&carP), buildValue(&cdrP));
        g.rootPushValue(&r);
        defer _ = g.rootPop();
        acc = consRef(r, acc);
    }

    // The canonical form: the SAME printer the native driver uses.
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    values.printValue(&aw.writer, acc) catch {
        werr("consdiff-zig: print failed\n");
        return 1;
    };
    wout(aw.written());
    wout("\n");
    return 0;
}
