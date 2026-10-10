//! src/effectloop.zig — the Osier LANGUAGE host: the CEK effect-manager event
//! loop over the compiler's Task effects (execplan + the stream prims + files
//! + time).  It is the host side of the language's effect protocol; the UI
//! (renderer + terminal input) lives in fx-ui and is NOT here.
//!
//! Design A (plan M9): effects run in the HOST, not by suspending a half-run
//! interpreter recursion.  `main`
//! returns a Program as DATA — a vector[Program, model0, cmd0, updateFn] with
//! tag = bare symbol 'Program'.  This module interprets each Task natively
//! (a CEK machine over the Task ADT) with nonblocking I/O via std.posix.poll,
//! applies continuation closures through the host_apply seam (a FRESH
//! application of the closure), feeds completed msgs to update, and loops
//! until the work set is
//! empty and no effects are pending.  The CEK scheduler, the poll loop, the
//! suspension/work-set machinery and the out-of-order interleaving stay.
//!
//! HANDLED (the 20 the compiler needs — see taskArity): TaskSucceed/TaskFail/
//! TaskAndThen/TaskOnError (composition), TaskWrite/TaskWriteFile/TaskReadFile/
//! TaskReadLine (stream prims), TaskExec (execplan), TaskGetenv/TaskSetenv/
//! TaskCd/TaskGetcwd/TaskGetpid/TaskGlob (env/cwd/pid/glob), TaskNow/TaskSleep/
//! TaskQuit (time/quit), TaskListDir/TaskStat (dir/stat).
//!
//! NOT HANDLED (deliberately): the UI effects left the language in osier split
//! Phase 3 — the Runtime.elm Task type no longer declares TaskRender /
//! TaskGuiOpen / TaskGuiPoll / TaskGuiClose / TaskReadKey / TaskReadMouse /
//! TaskMouseMode / TaskWinSize / TaskWaitResize / TaskRawMode, so the host's
//! handled set is exactly the Task ctor list above (taskArity) and nothing
//! more.  Any other Task ctor name — unknown, or a UI ctor that returns with a
//! future design — FAILS LOUDLY AND FAST: stepEval throws (throwShen) naming
//! the ctor, never silently completing it (which would make a program appear
//! to work while doing nothing) and never silently dropping it (which would
//! stall the program).
//!
//! THE SEAM (re-attaching UI): when the UI effects return, a consumer re-adds
//! the gui_model / gui_backend / terminal imports to the build.zig effectloop
//! module and re-wires those ctor names to leaves in stepEval's dispatch.
//!
//! THE TASK LAYOUT CONTRACT (the host owns this): a Task is the MX ADT rep
//! vector[tag, a1..an] — data[0] is a BARE tag Symbol, data[1..n] are the
//! ctor args in source order (Lower.Module.ctorEntry).  TaskAndThen ->
//! data[1]=cont closure, data[2]=inner task.  TaskReadFile -> data[1]=path
//! string.  The host compares values.symSlice(data[0]) against the ctor names.
//!
//! CONCURRENCY MODEL: each Task in the Cmd list becomes one *evaluation*.  A
//! pure evaluation steps to a leaf; an interleavable leaf (readFile, exec)
//! STARTS its effect natively and SUSPENDS (registers its fd/pid); other
//! evaluations keep stepping, so independent effects complete OUT OF ORDER.
//! write/writeFile and the env/cwd/getpid/glob leaves are SYNCHRONOUS (small,
//! bounded).  readLine is SYNCHRONOUS too: stdin is a single shared fd, so
//! interleaving its reads is meaningless (documented divergence).
//!
//! TERMINATION: the loop steps every runnable evaluation until each suspends
//! or delivers; when only effects remain it std.posix.poll(BLOCK)s on the
//! registered fds; on readiness it drains (nonblocking read) / reaps children
//! (waitpid WNOHANG — no zombies) and resumes.  It NEVER busy-spins and
//! delivers msgs in COMPLETION order (the feature).

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const rt = @import("rt");
const state = rt.state;
const values = rt.values;
const prims = rt.prims;
const varray = rt.varray;
const symbols = rt.symbols;
const execplan = rt.execplan;

const Gc = gc.Gc;
const Value = types.Value;
const ValueArray = types.ValueArray;
const Vm = state.Vm;
const VmError = state.VmError;

/// Host -> Elm apply dispatcher — the ONLY seam where the host calls Elm
/// (continuation/handler/update closures).  The DEFAULT is a loud stub: this
/// module links only the interpreter-free runtime (osier-rt), so the DRIVER
/// installs the real dispatcher at startup — native drivers install their
/// own (the QBE runtime's hostApply dispatches through rt_apply).  A plain
/// fn pointer keeps this module backend-optional: it never imports any
/// driver's module.
pub var host_apply: *const fn (vm: *Vm, fnv: Value, args: []const Value) VmError!Value = &hostApplyUninstalled;

/// The uninstalled-seam failure: LOUD, never a silent no-op (a program that
/// appeared to work while its continuations were dropped would be worse).
fn hostApplyUninstalled(vm: *Vm, fnv: Value, args: []const Value) VmError!Value {
    _ = fnv;
    _ = args;
    return vm.throwShen("effectloop: host_apply seam not installed — the driver must set effectloop.host_apply before driving a Program (native: the backend's applier)");
}

const pa = std.heap.page_allocator;

// ---------------------------------------------------------------------
//  Bounds — fixed tables, no dynamic growth (the host owns every fd/pid).
// ---------------------------------------------------------------------

const MAX_EVALS = 128; // concurrent evaluations in flight (Cmd.batch bound)
const MAX_FRAMES = 256; // continuation-stack depth per evaluation (Task.sequence bound)
const BLOCK = MAX_FRAMES + 2; // task slot + result slot + frame slots
const MAX_SLOTS = 2 + MAX_EVALS * BLOCK; // +2: model (0) and update (1)
const MAX_POLLFDS = MAX_EVALS * 2 + 2; // readFile=1 fd, exec=2 pipe fds
const MAX_CHILDREN = MAX_EVALS; // one child per exec evaluation

// ---------------------------------------------------------------------
//  libc externs (the process/syscall layer — same discipline as execplan.zig)
// ---------------------------------------------------------------------

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
/// glibc fstatat (std.c leaves it void on linux — 0.16 prefers statx; the
/// plain call matches the file's other libc externs and Go os.Stat semantics).
extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *Stat, flag: c_uint) c_int;

/// glibc `struct stat` on x86_64-linux (std.c.Stat is void there) — only the
/// fields the stat leaves read are named; layout must match bits/stat.h.
const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    pad0: c_int,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: std.os.linux.timespec,
    mtim: std.os.linux.timespec,
    ctim: std.os.linux.timespec,
    reserved: [3]c_long,
};

const F_GETFL: c_int = 3; // Linux
const F_SETFL: c_int = 4; // Linux
const O_NONBLOCK: c_int = 0x800; // Linux O_NONBLOCK (0o4000)

// ---------------------------------------------------------------------
//  Effect state — page_allocator-backed (never GC-scanned, never rooted).
// ---------------------------------------------------------------------

const ReadFileEff = struct {
    fd: i32 = -1,
    buf: std.ArrayListUnmanaged(u8) = .empty, // accumulated bytes (page_allocator)
};

const ExecEff = struct {
    prog: execplan.RProg = .{}, // decoded plan — kept alive until the child is reaped
    pid: c_int = -1,
    outfd: i32 = -1, // read end of stdout pipe
    errfd: i32 = -1, // read end of stderr pipe
    outbuf: std.ArrayListUnmanaged(u8) = .empty,
    errbuf: std.ArrayListUnmanaged(u8) = .empty,
    out_eof: bool = false,
    err_eof: bool = false,
    child_exited: bool = false,
    exit_code: i32 = 0,
};

/// TaskSleep suspends until `deadline_ms` (CLOCK_MONOTONIC).  No fd and no
/// buffer: the poll loop bounds its timeout by the nearest deadline and
/// flushExpiredSleeps completes expired sleeps after every poll return.
const SleepEff = struct {
    deadline_ms: i64 = 0,
};

const Eff = union(enum) {
    none,
    readfile: ReadFileEff,
    exec: ExecEff,
    sleep: SleepEff,
};

const FrameKind = enum { andthen, onerror };

const Frame = struct {
    kind: FrameKind,
    cont_slot: usize, // slot index holding the continuation/handler closure
};

const Eval = struct {
    active: bool = false,
    base: usize = 0, // block base slot index (task = base, result = base+1)
    /// Generation token: bumped every time this slot is (re)spawned.  stepEval
    /// captures it on entry and keeps looping only while it is unchanged — a
    /// deliver() deactivates the eval and spawn() can place a NEW eval into
    /// the just-freed slot (first-inactive reuse), which must NOT be stepped
    /// by the stale eval pointer still walking its while-loop.
    gen: usize = 0,
    nframes: usize = 0,
    frames: [MAX_FRAMES]Frame = [_]Frame{Frame{ .kind = .andthen, .cont_slot = 0 }} ** MAX_FRAMES,
    eff: Eff = .none,
};

const PollRole = enum { readfile, exec_out, exec_err };

const Child = struct {
    pid: c_int = -1,
    eval: usize = 0,
};

const HostLoop = struct {
    vm: *Vm,
    g: *Gc,
    /// R1: EVERY host-held Value (model, update, current tasks, continuation
    /// closures, effect results) lives in this permanently-rooted slot array.
    /// It is rooted ONCE for the whole run (rootPushValueArray) and every
    /// Value read must be (re)read FRESH after each allocating call.
    slots: [MAX_SLOTS]Value,
    nslots: i32 = MAX_SLOTS,
    evals: [MAX_EVALS]Eval = [_]Eval{Eval{}} ** MAX_EVALS,
    nevals: usize = 0,
    nactive: usize = 0,
    pollfds: [MAX_POLLFDS]std.posix.pollfd = [_]std.posix.pollfd{std.posix.pollfd{ .fd = -1, .events = 0, .revents = 0 }} ** MAX_POLLFDS,
    poll_eval: [MAX_POLLFDS]usize = [_]usize{0} ** MAX_POLLFDS,
    poll_role: [MAX_POLLFDS]PollRole = [_]PollRole{.readfile} ** MAX_POLLFDS,
    npoll: usize = 0,
    children: [MAX_CHILDREN]Child = [_]Child{Child{}} ** MAX_CHILDREN,
    nchildren: usize = 0,

    /// Quit latch: TaskQuit sets it; the main loop breaks once the current
    /// stepAll/completeReady round finishes (even with suspended evals still
    /// armed).
    quit: bool = false,

    const model_slot = 0;
    const update_slot = 1;

    fn slotBase(i: usize) usize {
        return 2 + i * BLOCK;
    }
    fn resultSlot(eval: *Eval) usize {
        return eval.base + 1;
    }

    fn evalIndex(self: *HostLoop, eval: *Eval) usize {
        return (@intFromPtr(eval) - @intFromPtr(&self.evals[0])) / @sizeOf(Eval);
    }

    // -------------------------------------------------------------
    //  Spawning / deactivating evaluations
    // -------------------------------------------------------------

    fn spawn(self: *HostLoop, task: Value) void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            if (!self.evals[i].active) break;
        }
        if (i == self.nevals) {
            if (i >= MAX_EVALS) std.debug.panic("effectloop: too many evaluations", .{});
            self.nevals += 1;
        }
        const base = slotBase(i);
        // Clear the whole block (the GC scans all MAX_SLOTS permanently, so a
        // stale ref here would retain dead closures/tasks).
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) self.slots[base + j] = values.valNil();
        self.evals[i] = .{ .active = true, .base = base, .gen = self.evals[i].gen + 1 };
        self.slots[base] = task; // root the task (no alloc — plain store)
        self.nactive += 1;
    }

    /// Iterate a Cmd (a cons list of Tasks, nil-terminated) and spawn one
    /// evaluation per Task.  ALLOCATION-FREE: the tasks are copied from the
    /// (rooted) cons list into rooted slots with no GC alloc in between, so
    /// the list's interior pointers stay valid throughout.
    fn spawnFromCmd(self: *HostLoop, cmd: Value) void {
        var cur = cmd;
        while (cur.tag == .cons) {
            const task = cur.payload.cons.car.?.*;
            self.spawn(task);
            cur = cur.payload.cons.cdr.?.*;
        }
    }

    fn deactivate(self: *HostLoop, eval: *Eval) void {
        eval.active = false;
        self.nactive -= 1;
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) self.slots[eval.base + j] = values.valNil();
        eval.nframes = 0;
        eval.eff = .none;
    }

    // -------------------------------------------------------------
    //  CEK stepping — TaskSucceed/Fail/AndThen/OnError compose purely;
    //  leaves start an effect (possibly suspending).
    // -------------------------------------------------------------

    fn stepEval(self: *HostLoop, eval: *Eval) VmError!void {
        // The loop re-reads eval fields each pass, so a deliver() that
        // deactivates this eval must stop the loop even when spawn() has
        // placed a fresh eval into the same slot (active becomes true again):
        // the generation token identifies the LOGICAL eval, not the slot.
        const start_gen = eval.gen;
        while (eval.active and eval.gen == start_gen and eval.eff == .none) {
            const task = self.slots[eval.base]; // fresh read (rooted slot)
            if (task.tag != .vector) {
                self.deactivate(eval);
                return;
            }
            const data = task.payload.vector.data;
            if (data == null or task.payload.vector.len < 1) {
                self.deactivate(eval);
                return;
            }
            const tag = data.?[0];
            if (tag.tag != .symbol) {
                self.deactivate(eval);
                return;
            }
            const name = values.symSlice(tag);

            // NICE-TO-HAVE 5: validate ctor arity before reading data[i]
            // (vector len == arity + 1).  Fixed arities today, so a mismatch
            // is a malformed Task — drop it instead of an OOB read.
            if (taskArity(name)) |a| {
                if (task.payload.vector.len != a + 1) {
                    self.deactivate(eval);
                    return;
                }
            }

            if (std.mem.eql(u8, name, "TaskSucceed")) {
                self.slots[resultSlot(eval)] = data.?[1];
                try self.completeSuccess(eval);
            } else if (std.mem.eql(u8, name, "TaskFail")) {
                self.slots[resultSlot(eval)] = data.?[1];
                try self.completeError(eval);
            } else if (std.mem.eql(u8, name, "TaskAndThen")) {
                self.pushFrame(eval, .andthen, data.?[1]);
                self.slots[eval.base] = data.?[2];
            } else if (std.mem.eql(u8, name, "TaskOnError")) {
                self.pushFrame(eval, .onerror, data.?[1]);
                self.slots[eval.base] = data.?[2];
            } else if (std.mem.eql(u8, name, "TaskWrite")) {
                try self.leafWrite(eval);
            } else if (std.mem.eql(u8, name, "TaskReadLine")) {
                try self.leafReadLine(eval);
            } else if (std.mem.eql(u8, name, "TaskReadFile")) {
                try self.leafReadFile(eval);
            } else if (std.mem.eql(u8, name, "TaskWriteFile")) {
                try self.leafWriteFile(eval);
            } else if (std.mem.eql(u8, name, "TaskExec")) {
                try self.leafExec(eval);
            } else if (std.mem.eql(u8, name, "TaskGetenv")) {
                try self.leafPrim(eval, "getenv", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskSetenv")) {
                try self.leafPrim(eval, "setenv", &.{ data.?[1], data.?[2] });
            } else if (std.mem.eql(u8, name, "TaskCd")) {
                try self.leafPrim(eval, "cd", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskGetcwd")) {
                try self.leafPrim(eval, "getcwd", &.{});
            } else if (std.mem.eql(u8, name, "TaskGetpid")) {
                try self.leafPrim(eval, "getpid", &.{});
            } else if (std.mem.eql(u8, name, "TaskGlob")) {
                try self.leafPrim(eval, "glob", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskNow")) {
                try self.leafNow(eval);
            } else if (std.mem.eql(u8, name, "TaskSleep")) {
                try self.leafSleep(eval, data.?[1]);
            } else if (std.mem.eql(u8, name, "TaskQuit")) {
                try self.leafQuit(eval);
            } else if (std.mem.eql(u8, name, "TaskListDir")) {
                try self.leafListDir(eval);
            } else if (std.mem.eql(u8, name, "TaskStat")) {
                try self.leafStat(eval);
            } else {
                // Unhandled Task ctor — fail LOUDLY and immediately, never a
                // silent drop: dropping the eval would leave the continuation
                // unresumed (the program stalls or silently loses work) with
                // no diagnostic.  The handled set is exactly taskArity; any
                // other ctor name (unknown, or a UI effect that left the
                // language in osier split Phase 3) lands here.
                var msgbuf: [160]u8 = undefined;
                return self.vm.throwShen(unhandledTaskMsg(&msgbuf, name));
            }
        }
    }

    fn pushFrame(self: *HostLoop, eval: *Eval, kind: FrameKind, cont: Value) void {
        if (eval.nframes >= MAX_FRAMES) std.debug.panic("effectloop: continuation stack overflow", .{});
        const slot = eval.base + 2 + eval.nframes;
        self.slots[slot] = cont;
        eval.frames[eval.nframes] = .{ .kind = kind, .cont_slot = slot };
        eval.nframes += 1;
    }

    /// Match M7 runTask EXACTLY (taskattempt proves fail/onError).
    /// success: no frame -> deliver; AndThen -> step (cont v); OnError -> pass
    /// through.  error: no frame -> drop; AndThen -> propagate; OnError ->
    /// step (handler e).
    fn completeSuccess(self: *HostLoop, eval: *Eval) VmError!void {
        while (true) {
            if (eval.nframes == 0) {
                try self.deliver(eval, self.slots[resultSlot(eval)]);
                return;
            }
            const frame = eval.frames[eval.nframes - 1];
            if (frame.kind == .onerror) {
                eval.nframes -= 1;
                self.slots[frame.cont_slot] = values.valNil();
                continue; // success passes through OnError
            }
            // .andthen
            eval.nframes -= 1;
            const cont = self.slots[frame.cont_slot];
            self.slots[frame.cont_slot] = values.valNil();
            const v = self.slots[resultSlot(eval)];
            const newtask = try host_apply(self.vm, cont, &.{v});
            self.slots[eval.base] = newtask;
            return;
        }
    }

    fn completeError(self: *HostLoop, eval: *Eval) VmError!void {
        while (true) {
            if (eval.nframes == 0) {
                self.deactivate(eval); // drop the msg (M7 runOne Err -> drive rest)
                return;
            }
            const frame = eval.frames[eval.nframes - 1];
            if (frame.kind == .andthen) {
                eval.nframes -= 1;
                self.slots[frame.cont_slot] = values.valNil();
                continue; // error propagates through AndThen
            }
            // .onerror
            eval.nframes -= 1;
            const handler = self.slots[frame.cont_slot];
            self.slots[frame.cont_slot] = values.valNil();
            const e = self.slots[resultSlot(eval)];
            const newtask = try host_apply(self.vm, handler, &.{e});
            self.slots[eval.base] = newtask;
            return;
        }
    }

    fn deliver(self: *HostLoop, eval: *Eval, msg: Value) VmError!void {
        const model = self.slots[model_slot]; // fresh
        const update = self.slots[update_slot]; // fresh
        // update msg model -> (model', cmd') = cons(model', cmd')
        const pair = try host_apply(self.vm, update, &.{ msg, model });
        if (pair.tag != .cons) {
            self.deactivate(eval);
            return;
        }
        self.slots[model_slot] = pair.payload.cons.car.?.*;
        const cmd = pair.payload.cons.cdr.?.*;
        self.deactivate(eval);
        self.spawnFromCmd(cmd);
    }

    // -------------------------------------------------------------
    //  Native leaf effects
    // -------------------------------------------------------------

    /// TaskWrite s — write s to stdout (fd 1) synchronously.  Completes with
    /// unit (nil — the continuation ignores it).
    fn leafWrite(self: *HostLoop, eval: *Eval) VmError!void {
        const s = self.slots[eval.base].payload.vector.data.?[1];
        writeFdAll(1, values.strSlice(s));
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskWriteFile path contents — synchronous open+write+close.
    fn leafWriteFile(self: *HostLoop, eval: *Eval) VmError!void {
        const data = self.slots[eval.base].payload.vector.data.?;
        const path = data[1];
        const contents = data[2];
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            values.strSlice(path),
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o666,
        ) catch {
            self.slots[resultSlot(eval)] = values.valNil();
            try self.completeSuccess(eval);
            return;
        };
        writeFdAll(fd, values.strSlice(contents));
        _ = close(fd);
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskReadLine — synchronous (stdin is a single shared fd; interleaving
    /// reads of fd 0 is meaningless).  Mirrors Runtime.elm readLineGo: read
    /// byte-by-byte, stop at 0x0A or EOF.
    fn leafReadLine(self: *HostLoop, eval: *Eval) VmError!void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(pa);
        var b: [1]u8 = undefined;
        while (true) {
            const n = std.posix.read(0, &b) catch break;
            if (n == 0) break; // EOF
            if (b[0] == 0x0A) break;
            buf.appendSlice(pa, &b) catch break;
        }
        self.slots[resultSlot(eval)] = values.valString(self.g, buf.items);
        try self.completeSuccess(eval);
    }

    /// TaskReadFile path — open O_NONBLOCK, read available bytes into a
    /// page_allocator accumulator, poll for more, on EOF (read==0) valString
    /// the contents.  A regular file drains to EOF synchronously (so it can
    /// overtake a concurrently-suspended slow exec — the concurrency proof).
    fn leafReadFile(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        const fd = std.posix.openat(std.posix.AT.FDCWD, values.strSlice(path), .{ .NONBLOCK = true }, 0) catch {
            self.slots[resultSlot(eval)] = values.valString(self.g, ""); // M6 open-failure parity
            try self.completeSuccess(eval);
            return;
        };
        eval.eff = .{ .readfile = .{ .fd = fd } };
        if (try readFileDrain(eval)) {
            try self.readFileComplete(eval);
        }
        // else: suspended — the poll loop resumes via readFileDrain.
    }

    fn readFileDrain(eval: *Eval) VmError!bool {
        const eff = &eval.eff.readfile;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.fd, &tmp) catch |e| {
                if (e == error.WouldBlock) return false; // EAGAIN — still pending
                return true; // read error — complete with what we have
            };
            if (n == 0) return true; // EOF
            eff.buf.appendSlice(pa, tmp[0..n]) catch return true;
        }
    }

    fn readFileComplete(self: *HostLoop, eval: *Eval) VmError!void {
        const eff = &eval.eff.readfile;
        _ = close(eff.fd);
        eff.fd = -1;
        const s = values.valString(self.g, eff.buf.items); // buf is page_allocator
        eff.buf.deinit(pa);
        eval.eff = .none;
        self.slots[resultSlot(eval)] = s;
        try self.completeSuccess(eval);
    }

    /// TaskExec plan — SINGLE-COMMAND async (fork+execvp, capture stdout/stderr
    /// via PIPE fds polled + waitpid WNOHANG).  Complex plans (pipeline/chain/
    /// redirect) fall back to SYNCHRONOUS execplan.primExecPlan (documented
    /// limitation — the concurrency proof needs one command).
    fn leafExec(self: *HostLoop, eval: *Eval) VmError!void {
        var plan = self.slots[eval.base].payload.vector.data.?[1];
        var plan_root = self.g.rootValue(&plan);
        defer plan_root.end();

        var prog: execplan.RProg = .{};
        if (!execplan.planDecode(plan, &prog)) {
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: malformed plan");
        }
        // Single plain command: one seq chain, one command, no redirs/sub.
        const argv = singleCommandArgv(&prog);
        if (argv == null) {
            // Complex plan — run synchronously via the existing prim.
            execplan.planFree(&prog);
            const r = try self.runPrim("exec-plan", &.{plan});
            self.slots[resultSlot(eval)] = r;
            try self.completeSuccess(eval);
            return;
        }

        // Fork + execvp the single command with piped capture.
        var outpipe: [2]c_int = undefined;
        var errpipe: [2]c_int = undefined;
        const ok_out = pipe(&outpipe) == 0;
        const ok_err = ok_out and pipe(&errpipe) == 0;
        if (!ok_err) {
            // A half-failed pipe() still owns the first pair — close it before
            // unwinding (the adjacent fork-fail path closes all four).
            if (ok_out) {
                _ = close(outpipe[0]);
                _ = close(outpipe[1]);
            }
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: fork/pipe failed");
        }
        const pid = fork();
        if (pid < 0) {
            _ = close(outpipe[0]);
            _ = close(outpipe[1]);
            _ = close(errpipe[0]);
            _ = close(errpipe[1]);
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: fork/pipe failed");
        }
        if (pid == 0) {
            execChild(argv.?, outpipe, errpipe);
        }
        // Parent: close write ends, keep read ends (nonblocking).
        _ = close(outpipe[1]);
        _ = close(errpipe[1]);
        setNonblocking(outpipe[0]);
        setNonblocking(errpipe[0]);

        const idx = self.evalIndex(eval);
        self.registerChild(idx, pid);
        eval.eff = .{ .exec = .{
            .prog = prog,
            .pid = pid,
            .outfd = outpipe[0],
            .errfd = errpipe[0],
        } };
    }

    fn execDrainOut(eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        if (eff.outfd < 0) return;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.outfd, &tmp) catch |e| {
                if (e == error.WouldBlock) return;
                break; // error -> treat as EOF
            };
            if (n == 0) break;
            eff.outbuf.appendSlice(pa, tmp[0..n]) catch break;
        }
        _ = close(eff.outfd);
        eff.outfd = -1;
        eff.out_eof = true;
    }

    fn execDrainErr(eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        if (eff.errfd < 0) return;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.errfd, &tmp) catch |e| {
                if (e == error.WouldBlock) return;
                break;
            };
            if (n == 0) break;
            eff.errbuf.appendSlice(pa, tmp[0..n]) catch break;
        }
        _ = close(eff.errfd);
        eff.errfd = -1;
        eff.err_eof = true;
    }

    /// Build the @p right-nested tuple (code, out, err) = cons(code,
    /// cons(out, err)) — exactly what Runtime.elm decodeExec would return.
    fn execComplete(self: *HostLoop, eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        const code = eff.exit_code;
        var out_v = values.valString(self.g, eff.outbuf.items);
        self.g.rootPushValue(&out_v);
        defer self.g.rootPop();
        var err_v = values.valString(self.g, eff.errbuf.items);
        self.g.rootPushValue(&err_v);
        defer self.g.rootPop();
        var inner = values.valCons(self.g, out_v, err_v);
        self.g.rootPushValue(&inner);
        defer self.g.rootPop();
        const tuple = values.valCons(self.g, values.valNumber(code), inner);

        eff.outbuf.deinit(pa);
        eff.errbuf.deinit(pa);
        execplan.planFree(&eff.prog);
        eval.eff = .none;
        self.slots[resultSlot(eval)] = tuple;
        try self.completeSuccess(eval);
    }

    /// TaskGetenv/Setenv/Cd/Getcwd/Getpid/Glob — synchronous native prims via
    /// the existing execplan handlers (runPrim wraps a fresh ValueArray).
    fn leafPrim(self: *HostLoop, eval: *Eval, name: []const u8, args: []const Value) VmError!void {
        const r = try self.runPrim(name, args);
        self.slots[resultSlot(eval)] = r;
        try self.completeSuccess(eval);
    }

    /// Run a prim by name with args pushed RTL (a1 popped first).  Roots the
    /// arg array + the stack.data slot across vaInit/vaPush; the prims
    /// themselves root their popped values (M8 discipline).
    fn runPrim(self: *HostLoop, name: []const u8, args: []const Value) VmError!Value {
        const g = self.g;
        var argbuf: [8]Value = undefined;
        var nargs: i32 = 0;
        for (args) |a| {
            argbuf[@intCast(nargs)] = a;
            nargs += 1;
        }
        g.rootPushValueArray(&argbuf, &nargs);
        defer g.rootPop();
        var stack: ValueArray = .{ .data = null, .len = 0, .cap = 0 };
        g.rootPushPtr(@ptrCast(&stack.data));
        defer g.rootPop();
        varray.vaInit(g, &stack);
        defer varray.vaFree(&stack);
        var i: usize = @intCast(nargs);
        while (i > 0) {
            i -= 1;
            varray.vaPush(g, &stack, argbuf[i]);
        }
        var acc: Value = values.valNil();
        try prims.execPrimitive(self.vm, name, &acc, &stack);
        return acc;
    }

    // -------------------------------------------------------------
    //  Time + quit leaves (M-FOUNDATION): TaskNow / TaskSleep / TaskQuit
    // -------------------------------------------------------------

    /// TaskNow — SYNCHRONOUS monotonic clock read (CLOCK_MONOTONIC).  The VM's
    /// get-time prim is CLOCK_REALTIME (wall clock — jumps break timers), so
    /// the host reads the monotonic clock directly and completes with ms.
    fn leafNow(self: *HostLoop, eval: *Eval) VmError!void {
        self.slots[resultSlot(eval)] = values.valNumber(nowMs());
        try self.completeSuccess(eval);
    }

    /// TaskSleep ms — SUSPENDING: record an absolute monotonic deadline.  The
    /// poll timeout is bounded by the nearest deadline (see pollTimeout) and
    /// flushExpiredSleeps completes expired sleeps after every poll return.
    fn leafSleep(self: *HostLoop, eval: *Eval, ms: Value) VmError!void {
        _ = self;
        const dur = ms.payload.number;
        eval.eff = .{ .sleep = .{ .deadline_ms = nowMs() + dur } };
    }

    fn sleepComplete(self: *HostLoop, eval: *Eval) VmError!void {
        eval.eff = .none;
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskQuit — set the quit latch; the main loop breaks after the current
    /// step.  The evaluation is deactivated (no deliver): quitting means exit
    /// with the model as-is, not a normal message round-trip.
    fn leafQuit(self: *HostLoop, eval: *Eval) VmError!void {
        self.quit = true;
        self.deactivate(eval);
    }

    // -------------------------------------------------------------
    //  Dir + stat leaves (M-FOUNDATION): TaskListDir / TaskStat
    // -------------------------------------------------------------

    /// TaskListDir path — SYNCHRONOUS directory listing.  openat(O_DIRECTORY)
    /// + getdents64 (raw fs order — NOT sorted; sorting is app-side, Go's
    /// os.ReadDir sorts but the filepicker wants insertion order anyway);
    /// '.'/'..' are skipped (Go os.ReadDir parity).  isDir comes from the
    /// dirent d_type (DT_UNKNOWN falls back to fstatat — symlinked dirs are
    /// NOT dirs, matching Go DirEntry.IsDir).  A failed open completes []
    /// (leafReadFile's empty-string parity).  Entries are drained into
    /// page_allocator storage first, the fd closed, and the Elm list built
    /// right-to-left afterwards — so no GC allocation happens while the fd is
    /// open and every cons cell is rooted per the execComplete discipline.
    fn leafListDir(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        var entries = std.ArrayListUnmanaged(DirEntryHost).empty;
        defer {
            for (entries.items) |e| pa.free(e.name);
            entries.deinit(pa);
        }
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            values.strSlice(path),
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
            0,
        ) catch {
            return self.listDirComplete(eval, entries.items);
        };
        defer _ = close(fd);
        var buf: [4096]u8 align(8) = undefined;
        drain: while (true) {
            const nread = std.os.linux.getdents64(fd, &buf, buf.len);
            if (std.os.linux.errno(nread) != .SUCCESS) break :drain; // read error: deliver what we have
            if (nread == 0) break :drain; // end of directory
            var off: usize = 0;
            while (off < nread) {
                const d: *std.os.linux.dirent64 = @alignCast(@ptrCast(&buf[off]));
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.name)), 0);
                const dot = name.len == 1 and name[0] == '.';
                const dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
                if (!dot and !dotdot) {
                    const is_dir = if (d.type == std.os.linux.DT.UNKNOWN)
                        dirEntryIsDir(fd, name)
                    else
                        d.type == std.os.linux.DT.DIR;
                    const copy = pa.dupe(u8, name) catch break :drain; // OOM
                    entries.append(pa, .{ .name = copy, .is_dir = is_dir }) catch {
                        pa.free(copy);
                        break :drain; // OOM: deliver the entries collected so far
                    };
                }
                off += d.reclen;
            }
        }
        try self.listDirComplete(eval, entries.items);
    }

    /// Drain results: build the Elm List of {name,isDir} records right-to-left
    /// (each new record consed onto the rooted tail), then completeSuccess.
    fn listDirComplete(self: *HostLoop, eval: *Eval, entries: []const DirEntryHost) VmError!void {
        var acc_r = values.valNil();
        self.g.rootPushValue(&acc_r);
        defer self.g.rootPop();
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            acc_r = try self.dirRecord(entries[i].name, entries[i].is_dir, acc_r);
        }
        self.slots[resultSlot(eval)] = acc_r;
        try self.completeSuccess(eval);
    }

    /// Build one {name,isDir} record pair-consed onto `tail`, every
    /// intermediate rooted (execComplete discipline).  Field pairs are
    /// cons(name, val) (@p) and the record spine is cons-first-field — the
    /// compiler's record layout (Lower/Expr.recordExpr: field j of the source
    /// sits at depth j; assoc access is first-match anyway).
    fn dirRecord(self: *HostLoop, name: []const u8, is_dir: bool, tail: Value) VmError!Value {
        const g = self.g;
        var tail_r = tail;
        g.rootPushValue(&tail_r);
        defer g.rootPop();
        const name_v = values.valString(g, name);
        var name_r = name_v;
        g.rootPushValue(&name_r);
        defer g.rootPop();
        const name_sym = symbols.valSymbol(&self.vm.symbols, "name");
        const pair_name = try self.runPrim("@p", &.{ name_sym, name_r });
        var pname_r = pair_name;
        g.rootPushValue(&pname_r);
        defer g.rootPop();
        const isdir_sym = symbols.valSymbol(&self.vm.symbols, "isDir");
        const pair_isdir = try self.runPrim("@p", &.{ isdir_sym, values.valBoolean(is_dir) });
        var pdir_r = pair_isdir;
        g.rootPushValue(&pdir_r);
        defer g.rootPop();
        // The RECORD spine ends at nil here — the list tail is only consed
        // onto the OUTSIDE of the finished record below (threading tail_r
        // into this cons would bury the rest of the list inside the isDir
        // pair, making assoc/isDir read the tail instead of the bool).
        const inner = values.valCons(g, pdir_r, values.valNil());
        var inner_r = inner;
        g.rootPushValue(&inner_r);
        defer g.rootPop();
        const rec = values.valCons(g, pname_r, inner_r);
        var rec_r = rec;
        g.rootPushValue(&rec_r);
        defer g.rootPop();
        return values.valCons(g, rec_r, tail_r);
    }

    /// TaskStat path — SYNCHRONOUS fstatat(AT_FDCWD) following symlinks (Go
    /// os.Stat parity).  Completes with {size, mode, mtimeMs, isDir, isFile};
    /// mtimeMs = st_mtim sec*1000 + nsec/1e6, isDir/isFile are the S_IFMT
    /// type bits.  A failed stat (ENOENT ...) completes the ZERO record —
    /// the same shape as the sync runTask no-op (pinned by statunit).
    fn leafStat(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        var st: Stat = undefined;
        var ok = false;
        if (std.posix.toPosixPath(values.strSlice(path))) |pathz| {
            ok = fstatat(std.posix.AT.FDCWD, &pathz, &st, 0) == 0;
        } else |_| {}
        const size: i64 = if (ok) @intCast(st.size) else 0;
        const mode: i64 = if (ok) @intCast(st.mode) else 0;
        const mtime_ms: i64 = if (ok)
            @as(i64, @intCast(st.mtim.sec)) * 1000 + @divTrunc(@as(i64, @intCast(st.mtim.nsec)), 1_000_000)
        else
            0;
        const type_bits: u32 = if (ok) st.mode & std.posix.S.IFMT else 0;
        const is_dir = type_bits == std.posix.S.IFDIR;
        const is_file = type_bits == std.posix.S.IFREG;
        self.slots[resultSlot(eval)] = try self.statRecord(size, mode, mtime_ms, is_dir, is_file);
        try self.completeSuccess(eval);
    }

    /// Build the {size,mode,mtimeMs,isDir,isFile} record right-to-left (field
    /// j of the source at depth j).  All field values are immediates, so the
    /// only GC allocations are the rooted pair + spine conses.
    fn statRecord(self: *HostLoop, size: i64, mode: i64, mtime_ms: i64, is_dir: bool, is_file: bool) VmError!Value {
        const g = self.g;
        const Field = struct { sym: []const u8, val: Value };
        const fields = [_]Field{
            .{ .sym = "isFile", .val = values.valBoolean(is_file) },
            .{ .sym = "isDir", .val = values.valBoolean(is_dir) },
            .{ .sym = "mtimeMs", .val = values.valNumber(mtime_ms) },
            .{ .sym = "mode", .val = values.valNumber(mode) },
            .{ .sym = "size", .val = values.valNumber(size) },
        };
        var acc_r = values.valNil();
        g.rootPushValue(&acc_r);
        defer g.rootPop();
        for (fields) |f| {
            const sym = symbols.valSymbol(&self.vm.symbols, f.sym);
            const pair = try self.runPrim("@p", &.{ sym, f.val });
            var pair_r = pair;
            g.rootPushValue(&pair_r);
            defer g.rootPop();
            acc_r = values.valCons(g, pair_r, acc_r);
        }
        return acc_r;
    }

    /// The earliest pending sleep deadline (monotonic ms), or null if none.
    fn nearestSleepDeadline(self: *HostLoop) ?i64 {
        var best: ?i64 = null;
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .sleep) continue;
            const d = eval.eff.sleep.deadline_ms;
            if (best == null or d < best.?) best = d;
        }
        return best;
    }

    /// Poll timeout: the nearest pending sleep deadline (so a sleeping eval
    /// wakes the poll instead of blocking past it).  -1 = block indefinitely.
    fn pollTimeout(self: *HostLoop) i32 {
        var t: i32 = -1;
        if (self.nearestSleepDeadline()) |deadline| {
            const remain = deadline - nowMs();
            const rem: i32 = if (remain <= 0)
                0
            else
                @intCast(@min(remain, @as(i64, std.math.maxInt(i32))));
            t = if (t < 0) rem else @min(t, rem);
        }
        return t;
    }

    /// Complete every expired sleep in deadline order (earliest first).  Each
    /// completion may deliver + spawn new evals, so re-scan from scratch after
    /// each — a freshly spawned sleep's deadline is now+ms (future), so it
    /// cannot make this loop livelock.
    fn flushExpiredSleeps(self: *HostLoop) VmError!void {
        const now = nowMs();
        while (true) {
            var best: ?*Eval = null;
            var i: usize = 0;
            while (i < self.nevals) : (i += 1) {
                const eval = &self.evals[i];
                if (!eval.active or eval.eff != .sleep) continue;
                if (eval.eff.sleep.deadline_ms > now) continue;
                if (best == null or eval.eff.sleep.deadline_ms < best.?.eff.sleep.deadline_ms) {
                    best = eval;
                }
            }
            if (best) |eval| {
                try self.sleepComplete(eval);
            } else return;
        }
    }

    // -------------------------------------------------------------
    //  Poll / reap / resume
    // -------------------------------------------------------------

    fn stepAll(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (eval.active and eval.eff == .none) {
                try self.stepEval(eval);
            }
        }
    }

    /// True iff some evaluation is active with no pending effect — i.e. PURE
    /// work stepAll can run right now.
    fn hasRunnable(self: *HostLoop) bool {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            if (self.evals[i].active and self.evals[i].eff == .none) return true;
        }
        return false;
    }

    fn rebuildPollfds(self: *HostLoop) void {
        self.npoll = 0;
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            switch (eval.eff) {
                .none => {},
                .readfile => if (eval.eff.readfile.fd >= 0)
                    self.addPoll(i, eval.eff.readfile.fd, .readfile),
                .exec => {
                    if (eval.eff.exec.outfd >= 0) self.addPoll(i, eval.eff.exec.outfd, .exec_out);
                    if (eval.eff.exec.errfd >= 0) self.addPoll(i, eval.eff.exec.errfd, .exec_err);
                },
                .sleep => {},
            }
        }
    }

    fn addPoll(self: *HostLoop, eval_idx: usize, fd: i32, role: PollRole) void {
        if (self.npoll >= MAX_POLLFDS) std.debug.panic("effectloop: too many pollfds", .{});
        self.pollfds[self.npoll] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        self.poll_eval[self.npoll] = eval_idx;
        self.poll_role[self.npoll] = role;
        self.npoll += 1;
    }

    fn registerChild(self: *HostLoop, eval_idx: usize, pid: c_int) void {
        var i: usize = 0;
        while (i < self.nchildren) : (i += 1) {
            if (self.children[i].pid < 0) break;
        }
        if (i == self.nchildren) {
            if (i >= MAX_CHILDREN) std.debug.panic("effectloop: too many children", .{});
            self.nchildren += 1;
        }
        self.children[i] = .{ .pid = pid, .eval = eval_idx };
    }

    fn reapChildren(self: *HostLoop) void {
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            var st: c_int = 0;
            const rc = waitpid(c.pid, &st, std.posix.W.NOHANG);
            if (rc == c.pid) {
                const eval = &self.evals[c.eval];
                if (eval.active and eval.eff == .exec) {
                    const status: u32 = @bitCast(st);
                    eval.eff.exec.child_exited = true;
                    eval.eff.exec.exit_code = execplan.waitStatusCode(status);
                }
                c.pid = -1;
            } else if (rc < 0) {
                c.pid = -1; // ECHILD/error — nothing more to reap
            }
        }
    }

    /// Block-reap the first pending child.  Returns true iff one was reaped.
    /// Used only when NO pollable fd remains: an exec's pipe fds EOF (waking
    /// poll) a moment BEFORE the exiting child becomes a waitpid-able zombie,
    /// so the WNOHANG reap above can race past it.  Once the fds are gone the
    /// child must have exited, so the blocking waitpid returns promptly and
    /// never busy-spins.
    fn reapBlocking(self: *HostLoop) bool {
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            var st: c_int = 0;
            const rc = blk: {
                while (true) {
                    const r = waitpid(c.pid, &st, 0); // BLOCKING (0 options)
                    if (r < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                    break :blk r;
                }
            };
            if (rc == c.pid) {
                const eval = &self.evals[c.eval];
                if (eval.active and eval.eff == .exec) {
                    const status: u32 = @bitCast(st);
                    eval.eff.exec.child_exited = true;
                    eval.eff.exec.exit_code = execplan.waitStatusCode(status);
                }
                c.pid = -1;
                return true;
            }
            c.pid = -1; // ECHILD/error — nothing more to reap
        }
        return false;
    }

    fn drainReady(self: *HostLoop) VmError!void {
        const n = self.npoll;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.pollfds[i].revents == 0) continue;
            const eval = &self.evals[self.poll_eval[i]];
            if (!eval.active) continue;
            switch (self.poll_role[i]) {
                .readfile => {
                    if (try readFileDrain(eval)) {
                        try self.readFileComplete(eval);
                    }
                },
                .exec_out => try execDrainOut(eval),
                .exec_err => try execDrainErr(eval),
            }
        }
    }

    fn completeReady(self: *HostLoop) VmError!void {
        const n = self.nevals;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .exec) continue;
            const eff = &eval.eff.exec;
            if (eff.child_exited and eff.out_eof and eff.err_eof) {
                try self.execComplete(eval);
            }
        }
    }

    /// Close/free every pending effect (error-exit cleanup): no zombies, no
    /// leaked fds/buffers.  No GC allocation — safe to run under any root set.
    fn cleanupAll(self: *HostLoop) void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            switch (eval.eff) {
                .none => {},
                .readfile => {
                    if (eval.eff.readfile.fd >= 0) _ = close(eval.eff.readfile.fd);
                    eval.eff.readfile.buf.deinit(pa);
                    eval.eff = .none;
                },
                .exec => {
                    if (eval.eff.exec.outfd >= 0) _ = close(eval.eff.exec.outfd);
                    if (eval.eff.exec.errfd >= 0) _ = close(eval.eff.exec.errfd);
                    eval.eff.exec.outbuf.deinit(pa);
                    eval.eff.exec.errbuf.deinit(pa);
                    execplan.planFree(&eval.eff.exec.prog);
                    eval.eff = .none;
                },
                .sleep => {
                    // No fd or buffer to free — just drop the pending sleep.
                    eval.eff = .none;
                },
            }
        }
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            _ = waitpid(c.pid, null, 0); // block-reap so no zombie survives
            c.pid = -1;
        }
    }
};

/// True iff `v` is the Program ADT vector (data[0] == bare symbol 'Program',
/// arity 3 -> vector len 4).
pub fn isProgram(v: Value) bool {
    if (v.tag != .vector) return false;
    if (v.payload.vector.len != 4) return false;
    const data = v.payload.vector.data;
    if (data == null) return false;
    const tag = data.?[0];
    if (tag.tag != .symbol) return false;
    return std.mem.eql(u8, values.symSlice(tag), "Program");
}

/// Drive the M9 event loop over a Program vector.
pub fn runProgram(vm: *Vm, prog: Value) VmError!Value {
    std.debug.assert(prog.tag == .vector);
    const data = prog.payload.vector.data.?;

    // Construct via `undefined` + explicit initialization: the struct literal
    // form makes LLVM materialize ~1.5MB of **-repeated array constants into
    // the loop's (escaping) storage at ReleaseFast, blowing up opt time
    // (>240s vs 3s Debug).  @memset lowers to llvm.memset instead
    // (verified: 17s).
    // HEAP-allocated, not a stack local.  The tables above are ~1.94MB of
    // fixed storage, and as a local they WERE the whole of a native caller's
    // frame: MEASURED on the QBE-compiled compiler, `main`'s frame was
    // 1,937,216 bytes with runProgram inlined into it — half of the 8.5MB
    // C-stack budget that exhausted the default 8MB RLIMIT_STACK.  Only the
    // ADDRESS moves: every field is initialized exactly as below, and
    // rootPushValueArray still registers `slots` as a root array, so the
    // rooting is unchanged (the tables are pinned by that root, not by the
    // conservative stack scan that used to see them for free).
    const loop: *HostLoop = pa.create(HostLoop) catch
        @panic("effectloop: out of memory allocating the host loop");
    defer pa.destroy(loop); // after rootPop/cleanupAll (defers run LIFO)
    loop.vm = vm;
    loop.g = vm.gc;
    @memset(&loop.slots, values.valNil());
    @memset(&loop.evals, Eval{});
    @memset(&loop.pollfds, std.posix.pollfd{ .fd = -1, .events = 0, .revents = 0 });
    @memset(&loop.poll_eval, 0);
    @memset(&loop.poll_role, PollRole.readfile);
    @memset(&loop.children, Child{});
    loop.nslots = MAX_SLOTS;
    loop.nevals = 0;
    loop.nactive = 0;
    loop.npoll = 0;
    loop.nchildren = 0;
    loop.quit = false;
    vm.gc.rootPushValueArray(&loop.slots, &loop.nslots);
    defer vm.gc.rootPop();
    defer loop.cleanupAll();

    loop.slots[HostLoop.model_slot] = data[1]; // model0
    loop.slots[HostLoop.update_slot] = data[3]; // updateFn
    loop.spawnFromCmd(data[2]); // cmd0

    while (loop.nactive > 0 and !loop.quit) {
        try loop.stepAll();
        if (loop.quit) break;
        if (loop.nactive == 0) break;
        loop.reapChildren();
        try loop.completeReady();
        if (loop.nactive == 0) break;
        // M9 fix: completeReady applies exec continuations and deliver() can
        // spawn into slots stepAll's cursor already passed, leaving PURE
        // evaluations runnable.  Step them to a fixpoint BEFORE touching the fd
        // tables — otherwise the npoll == 0 branch below breaks the loop and
        // silently drops their messages (fast execs, pure cmd spawns).
        while (loop.hasRunnable()) {
            try loop.stepAll();
            if (loop.quit) break;
            try loop.completeReady();
        }
        if (loop.quit) break;
        if (loop.nactive == 0) break;
        loop.rebuildPollfds();
        if (loop.npoll == 0) {
            // No pollable fd: the only remaining work is reaping children.
            // An exec's pipe fds EOF (waking poll) a moment BEFORE the exiting
            // child becomes reapable, so the WNOHANG reap can race past it and
            // leave the exec active with its fds already drained.  Block on
            // waitpid to reap the zombie (returns promptly — the fds being
            // gone means the child has exited), then let completeReady finish.
            if (loop.hasRunnable()) continue; // belt: never drop pure work
            if (loop.reapBlocking()) {
                try loop.completeReady();
                continue;
            }
            // Only pending sleeps remain: fall through to poll with an empty
            // fd set — poll(2) with nfds=0 + a timeout is a bounded sleep.
            if (loop.nearestSleepDeadline() == null) {
                std.debug.print("effectloop: pending effect with no pollable fd\n", .{});
                break;
            }
        }
        // A pending sleep tightens the poll timeout to its nearest deadline;
        // otherwise block until an fd is ready.
        const poll_timeout: i32 = loop.pollTimeout();
        _ = std.posix.poll(loop.pollfds[0..loop.npoll], poll_timeout) catch |e| switch (e) {
            error.NetworkDown, error.SystemResources => return error.ShenError,
            error.Unexpected => 0, // spurious wakeup — treat like a timeout
        };
        loop.reapChildren();
        try loop.drainReady();
        try loop.completeReady();
        try loop.flushExpiredSleeps();
    }

    return loop.slots[HostLoop.model_slot];
}

// ---------------------------------------------------------------------
//  Free functions (child side + fd helpers)
// ---------------------------------------------------------------------

/// The forked child for a single-command exec: bind the pipe write ends to
/// stdout/stderr, run a builtin in-process or execvp.  Never returns; only
/// write(2) + libc + _exit (no GC, no Zig error paths).
fn execChild(argv: [:null]const ?[*:0]const u8, outpipe: [2]c_int, errpipe: [2]c_int) noreturn {
    _ = close(outpipe[0]);
    _ = close(errpipe[0]);
    _ = dup2(outpipe[1], 1);
    _ = dup2(errpipe[1], 2);
    if (outpipe[1] > 2) _ = close(outpipe[1]);
    if (errpipe[1] > 2 and errpipe[1] != outpipe[1]) _ = close(errpipe[1]);

    const bcode = execplan.childBuiltin(argv.len, argv);
    if (bcode >= 0) _exit(bcode);
    _ = execvp(argv[0].?, argv.ptr);
    if (std.c._errno().* == @intFromEnum(std.c.E.NOENT)) {
        childW2("shensh: ", std.mem.sliceTo(argv[0].?, 0), ": not found\n");
        _exit(127);
    }
    childW2("shensh: ", std.mem.sliceTo(argv[0].?, 0), ": cannot execute\n");
    _exit(126);
}

/// Child-side stderr note (write(2) only).
fn childW2(a: []const u8, b: []const u8, c: []const u8) void {
    _ = write(2, a.ptr, a.len);
    _ = write(2, b.ptr, b.len);
    _ = write(2, c.ptr, c.len);
}

/// Return the argv of `prog` iff it is a SINGLE PLAIN COMMAND (one seq chain,
/// one command, no redirects, no subshell); else null (caller falls back to
/// sync).  The returned slice borrows from `prog` and stays valid until
/// planFree — the exec effect keeps `prog` alive across the fork+waitpid.
fn singleCommandArgv(prog: *execplan.RProg) ?[:null]const ?[*:0]const u8 {
    if (prog.chains.len != 1) return null;
    const ch = &prog.chains[0];
    if (ch.op != .seq) return null;
    if (ch.pipe.cmds.len != 1) return null;
    const c = &ch.pipe.cmds[0];
    if (c.sub != null or c.redirs.len != 0) return null;
    if (c.argv.len == 0) return null;
    return c.argv;
}

/// Task ctor arity (vector len == arity + 1), or null for an unknown ctor.
fn taskArity(name: []const u8) ?i32 {
    if (std.mem.eql(u8, name, "TaskSucceed") or std.mem.eql(u8, name, "TaskFail") or
        std.mem.eql(u8, name, "TaskWrite") or std.mem.eql(u8, name, "TaskReadFile") or
        std.mem.eql(u8, name, "TaskExec") or std.mem.eql(u8, name, "TaskGetenv") or
        std.mem.eql(u8, name, "TaskCd") or std.mem.eql(u8, name, "TaskGlob") or
        std.mem.eql(u8, name, "TaskSleep") or
        std.mem.eql(u8, name, "TaskListDir") or std.mem.eql(u8, name, "TaskStat")) return 1;
    if (std.mem.eql(u8, name, "TaskAndThen") or std.mem.eql(u8, name, "TaskOnError") or
        std.mem.eql(u8, name, "TaskWriteFile") or std.mem.eql(u8, name, "TaskSetenv")) return 2;
    if (std.mem.eql(u8, name, "TaskReadLine") or std.mem.eql(u8, name, "TaskGetcwd") or
        std.mem.eql(u8, name, "TaskGetpid") or
        std.mem.eql(u8, name, "TaskNow") or std.mem.eql(u8, name, "TaskQuit")) return 0;
    return null;
}

/// Diagnostic for a Task ctor this host does not handle.  The handled set is
/// exactly taskArity (the Runtime.elm Task ctor list); anything else — an
/// unknown ctor, or a UI effect that left the language in osier split Phase 3 —
/// lands here.  `buf` is caller-owned and must outlive the returned slice only
/// until the caller copies it (throwShen does, via values.valError).  On a
/// hypothetical overflow the raw ctor name is returned instead of truncating.
fn unhandledTaskMsg(buf: []u8, name: []const u8) []const u8 {
    const r = std.fmt.bufPrint(buf, "unhandled Task effect: {s}", .{name});
    return if (r) |m| m else |_| name;
}

/// Monotonic clock in milliseconds (CLOCK_MONOTONIC — NOT wall-clock; a wall
/// clock jump would break timers).  Returns 0 on a failed read.
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A drained directory entry — page_allocator OWNED name bytes (GC values are
/// only built in listDirComplete, after the dirfd is closed).
const DirEntryHost = struct { name: []u8, is_dir: bool };

/// d_type DT_UNKNOWN fallback (some filesystems): fstatat the entry relative
/// to the open dirfd without following symlinks (Go DirEntry.IsDir parity —
/// a symlink-to-dir is NOT a dir).
fn dirEntryIsDir(dirfd: c_int, name: []const u8) bool {
    const pathz = std.posix.toPosixPath(name) catch return false;
    var st: Stat = undefined;
    if (fstatat(dirfd, &pathz, &st, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return false;
    return st.mode & std.posix.S.IFMT == std.posix.S.IFDIR;
}

/// Set O_NONBLOCK on an fd (GETFL|SETFL — preserves any existing flags).
fn setNonblocking(fd: c_int) void {
    const fl = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl < 0) return;
    _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/// Write all of `data` to `fd` (loops over partial writes; retries EINTR).
fn writeFdAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..].ptr, data[off..].len);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return; // real error — stop (best-effort write)
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}
