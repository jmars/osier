//! tools/qbe/primsdiff/primsdiff-zig.zig — the ZIG ARM of the generalized
//! prim differential (handoff osier-midprims, step 5).  consdiff-zig.zig's
//! shape extended from ONE prim to EVERY ported one: the spec's per-line op
//! names the reference entry, the args parse with consdiff's kind-free
//! grammar, and every result lands in ONE list printed with the SAME
//! canonical printer (values.printValue) the compiled Mid arm's driver uses.
//!
//! Composite ops the surface spells with several prims run the same sequence
//! here, through execPrimitive only:
//!   vec   — absvector n; address-> v i x; <-address v i   (i < n guaranteed
//!           by the generator: both arms would fault on i >= n — parity crash)
//!   assoc — @p f a; @p g b; cons p1 p2; ... the record chain, then
//!           assoc (sym f) rec; snd
//!   @p    — the pair itself (tuple construction)
//!   cons  — one cons (the spike's own op, folded in)
//!
//! ROOTING: every intermediate Value that survives an allocating call lives
//! in a rooted slot (rootPushValue + explicit pop), the prims' own discipline.

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

fn die(msg: []const u8) noreturn {
    werr("primsdiff-zig: ");
    werr(msg);
    werr("\n");
    std.process.exit(1);
}

var g: *Gc = undefined;
var vm: *state.Vm = undefined;
var vmem: state.Vm = undefined;

const HEAP_BYTES: usize = 64 * 1024 * 1024;

// ---------------------------------------------------------------------
//  spec parsing (consdiff's parser, verbatim contract)
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

    fn until(self: *Spec, delims: []const u8) []const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and
            std.mem.indexOfScalar(u8, delims, self.bytes[self.pos]) == null) : (self.pos += 1)
        {}
        return self.bytes[start..self.pos];
    }
};

const Parsed = struct {
    kind: u8, // 'n' 'f' 'b' 's' '0' (nil) 'l'
    text: []const u8,
    elems: []Parsed,
};

fn parseSpec(sp: *Spec, arena: std.mem.Allocator) Parsed {
    sp.skipSpaces();
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
//  reference execution — EVERY prim call through execPrimitive
// ---------------------------------------------------------------------

fn runPrim(name: []const u8, args: []const Value) Value {
    // rt_prim's staging shape: copy by value into rooted storage, push
    // REVERSED so the first pop is args[0] (the ZINC emitter's order).
    var buf: [8]Value = undefined;
    const n = args.len;
    if (n > buf.len) die("op arity exceeds the staging buffer");
    // Push REVERSED so the first pop is args[0] (rt_prim's order: the ZINC
    // emitter's RTL pushes produce it, and every prim's vaPop sequence is
    // written against it).
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        buf[n - 1 - i] = args[i];
    }
    var live: i32 = @intCast(n);
    g.rootPushValueArray(&buf, &live);
    defer g.rootPop();
    var stack: types.ValueArray = .{ .data = &buf, .len = @intCast(n), .cap = @intCast(n) };
    var acc: Value = .{ .tag = .number, .payload = .{ .number = 0 } };
    g.rootPushValue(&acc);
    defer g.rootPop();
    prims.execPrimitive(vm, name, &acc, &stack) catch |e| {
        die(@errorName(e));
    };
    return acc;
}

fn consRef(car: Value, cdr: Value) Value {
    return runPrim("cons", &.{ car, cdr });
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
        's' => return values.valString(g, p.text),
        '0' => return values.valNil(),
        'l' => {
            var acc = values.valNil();
            g.rootPushValue(&acc);
            defer _ = g.rootPop();
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

fn symValue(name: []const u8) Value {
    // intern through the REFERENCE entry (the symbol table is VM state —
    // exactly what the surface's sym literals are).
    var s = values.valString(g, name);
    g.rootPushValue(&s);
    defer _ = g.rootPop();
    var arg = [1]Value{s};
    return runPrim("intern", &arg);
}

fn executeOp(op: []const u8, args: []Value) Value {
    // composite ops first
    if (std.mem.eql(u8, op, "vec")) {
        // absvector n; address-> v i x; <-address v i
        var v = runPrim("absvector", args[0..1]);
        g.rootPushValue(&v);
        defer _ = g.rootPop();
        var triple = [3]Value{ v, args[1], args[2] };
        v = runPrim("address->", &triple);
        g.rootPushValue(&v);
        defer _ = g.rootPop();
        var pair = [2]Value{ v, args[1] };
        return runPrim("<-address", &pair);
    }
    if (std.mem.eql(u8, op, "assoc")) {
        // { f = a, g = b } then .f : cons (@p (sym f) a) (cons (@p (sym g) b) nil)
        var fa = runPrim("@p", &[_]Value{ symValue("f"), args[0] });
        g.rootPushValue(&fa);
        defer _ = g.rootPop();
        var gb = runPrim("@p", &[_]Value{ symValue("g"), args[1] });
        g.rootPushValue(&gb);
        defer _ = g.rootPop();
        var tail = consRef(gb, values.valNil());
        g.rootPushValue(&tail);
        defer _ = g.rootPop();
        var rec = consRef(fa, tail);
        g.rootPushValue(&rec);
        defer _ = g.rootPop();
        var hit = runPrim("assoc", &[_]Value{ symValue("f"), rec });
        g.rootPushValue(&hit);
        defer _ = g.rootPop();
        var one = [1]Value{hit};
        return runPrim("snd", &one);
    }
    if (std.mem.eql(u8, op, "emptylist")) {
        return runPrim("emptylist", &.{values.valNumber(0)});
    }
    // every other op name IS the prim name
    return runPrim(op, args);
}

// ---------------------------------------------------------------------
//  main
// ---------------------------------------------------------------------

export fn main(c_argc: c_int, c_argv: [*]?[*:0]u8) callconv(.c) c_int {
    const argc: usize = @intCast(c_argc);
    if (argc < 2) {
        werr("usage: primsdiff-zig <vectors.spec>\n");
        return 2;
    }
    const specPath = std.mem.span(c_argv[1] orelse "");

    const fd = std.posix.openat(std.posix.AT.FDCWD, specPath, .{ .ACCMODE = .RDONLY }, 0) catch {
        werr("primsdiff-zig: cannot open spec\n");
        return 1;
    };
    var fileBuf: std.ArrayListUnmanaged(u8) = .empty;
    defer fileBuf.deinit(std.heap.page_allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch {
            werr("primsdiff-zig: spec read failed\n");
            return 1;
        };
        if (n == 0) break;
        fileBuf.appendSlice(std.heap.page_allocator, chunk[0..n]) catch {
            werr("primsdiff-zig: oom reading spec\n");
            return 1;
        };
    }
    _ = std.os.linux.close(fd);

    var lines = std.mem.splitScalar(u8, fileBuf.items, '\n');
    const header = lines.next() orelse {
        werr("primsdiff-zig: empty spec\n");
        return 1;
    };
    if (!(header.len >= 2 and header[0] == 'V')) {
        werr("primsdiff-zig: bad spec header\n");
        return 1;
    }
    const nVectors = std.fmt.parseInt(usize, std.mem.trim(u8, header[1..], " "), 10) catch {
        werr("primsdiff-zig: bad spec count\n");
        return 1;
    };

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
        werr("primsdiff-zig: gc init failed\n");
        return 1;
    };
    g = &gg;
    defer g.deinit();
    vmem.init(&gg);
    vm = &vmem;

    var acc = values.valNil();
    g.rootPushValue(&acc);
    defer g.rootPop();

    var vecLines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer vecLines.deinit(std.heap.page_allocator);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        vecLines.append(std.heap.page_allocator, line) catch {
            werr("primsdiff-zig: oom buffering vectors\n");
            return 1;
        };
    }
    if (vecLines.items.len != nVectors) {
        werr("primsdiff-zig: vector count mismatch with the header\n");
        return 1;
    }

    // last-first, matching the fixture's `all = [ v0, v1, ... ]` cons shape
    var vi: usize = vecLines.items.len;
    while (vi > 0) {
        vi -= 1;
        const line = vecLines.items[vi];
        var it = std.mem.splitScalar(u8, line, '|');
        const op = it.next() orelse die("vector line without op");
        var args: std.ArrayListUnmanaged(Value) = .empty;
        while (it.next()) |a| {
            if (a.len == 0) continue; // a 0-arity op's trailing separator
            var sp = Spec{ .bytes = a };
            const p = parseSpec(&sp, arena);
            args.append(std.heap.page_allocator, buildValue(&p)) catch die("oom args");
        }
        var r = executeOp(op, args.items);
        g.rootPushValue(&r);
        defer _ = g.rootPop();
        acc = consRef(r, acc);
    }

    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    values.printValue(&aw.writer, acc) catch {
        werr("primsdiff-zig: print failed\n");
        return 1;
    };
    wout(aw.written());
    wout("\n");
    return 0;
}
