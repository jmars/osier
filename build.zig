const std = @import("std");

// osier — the language repo (compiler + ZINC VM + Lean mechanization + the
// language's evidence chain).  This build.zig builds the LANGUAGE targets
// only: elmvm (the gate harness), vmbench, aotdump, the AOT spike exes, and the
// gc/vm test gates driven by the vendor/osier-rt + vendor/zinc-vm path
// dependencies (the runtime/GC package and the interpreter package).  The UI
// (fx_ui exe, src/renderer/*, gui_*/terminal, ptytest, genwidth) lives in the
// fx-ui repo and is deliberately NOT here.
//
//   zig build elmvm     build the gate harness (default install target)
//   zig build vmbench   build the throughput benchmark
//   zig build aotdump   build the AOT emitter
//   zig build aot       build the AOT spike exes
//   zig build test      gc (osier-rt) + vm (zinc-vm) suites via the path deps
//   zig build gate      gc + vm suites in Debug + ReleaseSafe + ReleaseFast
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast default: the interpreted VM is unusably slow in Debug
    // (~10-25x).  -Doptimize=Debug|ReleaseSafe|... and --release[=fast|safe|small]
    // still select an explicit mode.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .fast => std.builtin.OptimizeMode.ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    // ---- osier-rt + zinc-vm package dependencies (path deps, owned by osier) ----
    // osier-rt is the RUNTIME (GC + values/state/prims/varray/streams/
    // execplan) — what every backend links and what survives the VM's
    // retirement.  zinc-vm is the INTERPRETER (interp/parser/hostcall); it
    // depends on osier-rt and dies at P8.  Each package exports its modules
    // by name, so consumers keep their `@import("gc")` / `@import("rt")` /
    // `@import("vm")` calls.
    const osier_rt = b.dependency("osier_rt", .{ .target = target, .optimize = optimize });
    const gc_mod = osier_rt.module("gc");
    const rt_mod = osier_rt.module("rt");
    const zinc = b.dependency("zinc_vm", .{ .target = target, .optimize = optimize });
    const vm_mod = zinc.module("vm");

    // ---- the language host (src/effectloop.zig) ----
    // The CEK effect-manager over the compiler's Task effects (execplan +
    // stream/file prims + time + Quit).  It imports only gc + rt (the
    // RUNTIME — never the interpreter): the 10 UI effect ctors remain in
    // Runtime.elm's Task type but are unhandled here (they fail loudly), and
    // the renderer/terminal host lives in fx-ui.  Its host_apply seam
    // defaults to a loud stub; the driver installs the real one (elmvm/aot:
    // hostcall.applyClosureN, the QBE runtime: its native rt_apply wrapper).
    const effectloop_mod = b.createModule(.{
        .root_source_file = b.path("src/effectloop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "rt", .module = rt_mod },
        },
    });

    // ---- `elmvm`: the gate harness (tools/elmvm.zig) ----
    // Loads a csexp bundle and runs one function, proving the ZINC VM
    // parser/interp and the host effect loop end to end.  The DEFAULT install
    // target: `zig build` and `zig build elmvm` both produce zig-out/bin/elmvm.
    const elmvm_mod = b.createModule(.{
        .root_source_file = b.path("tools/elmvm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "effectloop", .module = effectloop_mod },
        },
    });
    const elmvm = b.addExecutable(.{
        .name = "elmvm",
        .root_module = elmvm_mod,
    });
    b.installArtifact(elmvm);
    const elmvm_install = b.addInstallArtifact(elmvm, .{});
    const elmvm_step = b.step("elmvm", "Build the elmvm gate harness");
    elmvm_step.dependOn(&elmvm_install.step);

    // ---- `vmbench`: the VM throughput benchmark harness (tools/vmbench.zig) ----
    const vmbench_mod = b.createModule(.{
        .root_source_file = b.path("tools/vmbench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const vmbench = b.addExecutable(.{
        .name = "vmbench",
        .root_module = vmbench_mod,
    });
    const vmbench_install = b.addInstallArtifact(vmbench, .{});
    const vmbench_step = b.step("vmbench", "Build the vmbench throughput harness");
    vmbench_step.dependOn(&vmbench_install.step);

    // ---- `aotrt`: the handwritten AOT runtime (tools/aot/runtime.zig) ----
    // Shared by every generated module and the aotbench driver.  Imports gc +
    // vm; the generated Zig calls back into it for tail dispatch, env builds,
    // and the code-array -> native-fn registry.
    const aotrt_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });

    // AOT instruction counting: `rt.count(n)` is emitted once per basic block
    // and costs ~4% of runtime.  ON for the aotbench spike exes (their
    // ns/instr report needs it), OFF for real apps (`aot-build`).
    const count_instrs_opt = b.option(bool, "count-instrs", "AOT: emit the per-block instruction counter (default: on for aotbench, off for aot-build apps)");
    const count_instrs_bench = b.addOptions();
    count_instrs_bench.addOption(bool, "count_instrs", count_instrs_opt orelse true);
    aotrt_mod.addOptions("count_instrs", count_instrs_bench);

    const aotrt_app_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const count_instrs_app = b.addOptions();
    count_instrs_app.addOption(bool, "count_instrs", count_instrs_opt orelse false);
    aotrt_app_mod.addOptions("count_instrs", count_instrs_app);

    // ---- `aotdump`: the AOT emitter (links gc+vm, real parseBundle) ----
    const aotdump_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/dump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });
    const aotdump = b.addExecutable(.{
        .name = "aotdump",
        .root_module = aotdump_mod,
    });
    const aotdump_install = b.addInstallArtifact(aotdump, .{});
    const aotdump_step = b.step("aotdump", "Build the AOT emitter (aotdump)");
    aotdump_step.dependOn(&aotdump_install.step);

    // ---- `aot`: the AOT-to-Zig spike exes ----
    // Each spike compiles a language fixture with node run.js -> aotdump -> a
    // generated Zig module, then links it against aotrt + gc + vm.
    const aot_step = b.step("aot", "Build the AOT spike exes (fib/countdown/biglist/letread/letclosure/letdeeprec)");
    aot_step.dependOn(&aotdump_install.step);
    inline for (.{
        .{ .name = "aotbench-fib", .fixture = "tests/elm-fixtures/fib.elm", .entry = "Fib.fib" },
        .{ .name = "aotbench-countdown", .fixture = "tests/elm-fixtures/countdown.elm", .entry = "Countdown.countdown" },
        .{ .name = "aotbench-biglist", .fixture = "tests/elm-fixtures/biglist.elm", .entry = "BigList.main" },
        .{ .name = "aotbench-letread", .fixture = "tests/elm-fixtures/letread.elm", .entry = "LetRead.main" },
        .{ .name = "aotbench-letclosure", .fixture = "tests/elm-fixtures/letclosure.elm", .entry = "LetClosure.main" },
        .{ .name = "aotbench-letdeeprec", .fixture = "tests/elm-fixtures/letdeeprec.elm", .entry = "LetDeepRec.main" },
    }) |sp| {
        aot_step.dependOn(addAotSpike(b, target, optimize, gc_mod, vm_mod, aotrt_mod, aotdump, sp.name, sp.fixture, sp.entry));
    }

    // ---- `aot-build`: the 'elm make'-style command (tools/aot/aot-build.sh) ----
    // Options-driven instance of addAotApp: -Dapp=<entry .elm> -Dentry=<Mod>.main
    // -Dout=<exe name>.  The build graph owns the node run.js -> aotdump ->
    // gen.zig -> native exe chain.  (Invoked through the script, not directly.)
    if (b.option([]const u8, "app", "aot-build: path to the app's entry .elm source")) |app_path| {
        const entry = b.option([]const u8, "entry", "aot-build: entry defun (<Module>.main)") orelse {
            std.debug.print("build.zig: -Dapp={s} requires -Dentry=<Module>.main\n", .{app_path});
            std.process.exit(1);
        };
        const out_name = b.option([]const u8, "out", "aot-build: output exe name") orelse "aot-app";
        const aot_build_step = b.step("aot-build", "Build a self-contained native exe from an .elm app (see tools/aot/aot-build.sh)");
        aot_build_step.dependOn(addAotApp(b, target, optimize, gc_mod, vm_mod, aotrt_app_mod, effectloop_mod, aotdump, out_name, &.{app_path}, entry));
    }

    // ---- tests: the GC (osier-rt) + VM (zinc-vm) suites via the path deps ----
    const test_step = b.step("test", "Run tests");
    const gc_test_step = b.step("gc-test", "Run Shen GC tests (honours -Doptimize)");
    gc_test_step.dependOn(addGcTestSet(b, target, optimize));
    test_step.dependOn(gc_test_step);
    const vm_test_step = b.step("vm-test", "Run Shen VM tests (honours -Doptimize)");
    vm_test_step.dependOn(addVmTestSet(b, target, optimize));
    test_step.dependOn(vm_test_step);

    // ---- `gate`: the permanent ReleaseSafe build gate ----
    const gate_step = b.step("gate", "Run Shen GC + VM tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addGcTestSet(b, target, .Debug));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseFast));
    gate_step.dependOn(addVmTestSet(b, target, .Debug));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseFast));
}

/// Build one AOT spike executable: node run.js compiles the fixture to a csexp
/// bundle, aotdump emits a generated Zig module from it, and the exe (aotbench
/// driver, tools/aot/main.zig) links that module against aotrt + gc + vm.
fn addAotSpike(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gc_mod: *std.Build.Module,
    vm_mod: *std.Build.Module,
    aotrt_mod: *std.Build.Module,
    aotdump: *std.Build.Step.Compile,
    name: []const u8,
    fixture: []const u8,
    entry: []const u8,
) *std.Build.Step {
    const node_cmd = b.addSystemCommand(&.{"node"});
    node_cmd.addArg("elm-compiler/run.js");
    node_cmd.addFileArg(b.path(fixture));
    const bundle_lp = node_cmd.addOutputFileArg(b.fmt("{s}.csexp", .{name}));

    const dump_cmd = b.addRunArtifact(aotdump);
    dump_cmd.addFileArg(bundle_lp);
    dump_cmd.addArg(entry);
    dump_cmd.addArg("-o");
    const gen_lp = dump_cmd.addOutputFileArg("gen.zig");

    const aot_gen_mod = b.createModule(.{
        .root_source_file = gen_lp,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
            .{ .name = "aot_gen", .module = aot_gen_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });
    const install = b.addInstallArtifact(exe, .{});
    return &install.step;
}

/// Build one AOT'd program exe linked against the GENERIC driver
/// (tools/aot/run.zig): node run.js compiles `sources` to a csexp bundle,
/// aotdump emits a generated Zig module (embedding the bundle + baking the
/// entry), and the exe links that module against gc + vm + aotrt + effectloop.
/// The driver runs the baked entry and drives the host effect loop.  With no
/// CLI bundle arg the exe runs the EMBEDDED bundle — the self-contained native
/// binary `aot-build` emits.
fn addAotApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gc_mod: *std.Build.Module,
    vm_mod: *std.Build.Module,
    aotrt_mod: *std.Build.Module,
    effectloop_mod: *std.Build.Module,
    aotdump: *std.Build.Step.Compile,
    name: []const u8,
    sources: []const []const u8,
    entry: []const u8,
) *std.Build.Step {
    const node_cmd = b.addSystemCommand(&.{"node"});
    node_cmd.addArg("elm-compiler/run.js");
    for (sources) |src| node_cmd.addFileArg(if (src[0] == '/') .{ .cwd_relative = src } else b.path(src));
    const bundle_lp = node_cmd.addOutputFileArg(b.fmt("{s}.csexp", .{name}));

    const dump_cmd = b.addRunArtifact(aotdump);
    dump_cmd.addFileArg(bundle_lp);
    dump_cmd.addArg(entry);
    dump_cmd.addArg("-o");
    const gen_lp = dump_cmd.addOutputFileArg("gen.zig");

    const aot_gen_mod = b.createModule(.{
        .root_source_file = gen_lp,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("tools/aot/run.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "runtime.zig", .module = aotrt_mod },
            .{ .name = "aot_gen", .module = aot_gen_mod },
            .{ .name = "effectloop", .module = effectloop_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_mod,
    });
    const install = b.addInstallArtifact(exe, .{});
    return &install.step;
}

/// SAFETY-ENFORCEMENT (unit C): build one self-contained GC test set
/// compiled at `opt` and return its run step.  Each mode resolves its OWN
/// osier-rt dependency instance so the package's "gc" module carries `opt`.
fn addGcTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const osier_rt = b.dependency("osier_rt", .{ .target = target, .optimize = opt });
    const gc_mod = osier_rt.module("gc");

    const gc_test_mod = b.createModule(.{
        .root_source_file = osier_rt.path("tests/gc_test.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });
    const run_gc_tests = b.addRunArtifact(gc_tests);

    // T9: expected-panic executable — the ROOT_PTR interior-pointer defense is
    // proven by a tiny exe that overrides its root panic handler and exits 42.
    const t9_mod = b.createModule(.{
        .root_source_file = osier_rt.path("tests/root_ptr_panic.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const t9_exe = b.addExecutable(.{
        .name = "gc_root_ptr_panic",
        .root_module = t9_mod,
    });
    const run_t9 = b.addRunArtifact(t9_exe);
    run_t9.expectExitCode(42);

    run_gc_tests.step.dependOn(&run_t9.step);

    return &run_gc_tests.step;
}

/// Build one self-contained VM test set compiled at `opt` and return its run
/// step (mirroring addGcTestSet).  The gc module comes from the osier-rt
/// dependency (the runtime owns it now); the vm module from zinc-vm — the
/// same dependency instances zinc-vm's own "vm" module links, so the Vm
/// type in the test is the one under test.
fn addVmTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const osier_rt = b.dependency("osier_rt", .{ .target = target, .optimize = opt });
    const gc_mod = osier_rt.module("gc");
    const zinc = b.dependency("zinc_vm", .{ .target = target, .optimize = opt });
    const vm_mod = zinc.module("vm");

    const vm_test_mod = b.createModule(.{
        .root_source_file = zinc.path("tests/vm_test.zig"),
        .target = target,
        .optimize = opt,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const vm_tests = b.addTest(.{ .root_module = vm_test_mod });
    const run_vm_tests = b.addRunArtifact(vm_tests);

    return &run_vm_tests.step;
}
