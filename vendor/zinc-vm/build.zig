const std = @import("std");

// vendor/zinc-vm — the ZINC VM INTERPRETER package (the half that dies at
// P8; handoff-osier-rtsplit).  The runtime (GC + values/state/prims/...) is
// the osier-rt package, a path dependency this package owns nothing of; the
// interpreter DEPENDS on the runtime, never the reverse.
//
// Exports ONE module: "vm" (src/vm.zig), which re-exports osier-rt's modules
// alongside the interpreter's own parser/interp/hostcall so consumers keep
// their `@import("vm").values`-style references until P8 deletes them.
//
//   zig build test    run the VM suite (honours -Doptimize)
//   zig build gate    VM suite in Debug + ReleaseSafe + ReleaseFast
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rt_dep = b.dependency("osier_rt", .{
        .target = target,
        .optimize = optimize,
    });
    const gc_mod = rt_dep.module("gc");
    const rt_mod = rt_dep.module("rt");

    _ = b.addModule("vm", .{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "rt", .module = rt_mod },
        },
    });

    const test_step = b.step("test", "Run tests");

    // ---- VM test step: one self-contained set per optimize mode.  The gc
    // module comes from osier-rt's dependency instance so the Vm type the
    // tests build is the SAME module the vm module links. ----
    const vm_test_step = b.step("vm-test", "Run Shen VM tests (honours -Doptimize)");
    vm_test_step.dependOn(addVmTestSet(b, target, optimize));
    test_step.dependOn(vm_test_step);

    const gate_step = b.step("gate", "Run Shen VM tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addVmTestSet(b, target, .Debug));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseFast));
}

/// Build one self-contained VM test set compiled at `opt` and return its run
/// step.  Each mode resolves its OWN osier-rt dependency instance (matching
/// optimize) so the runtime modules carry that mode.
fn addVmTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const rt_dep = b.dependency("osier_rt", .{
        .target = target,
        .optimize = opt,
    });
    const gc_mod = rt_dep.module("gc");
    const rt_mod = rt_dep.module("rt");
    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = opt,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "rt", .module = rt_mod },
        },
    });

    const vm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/vm_test.zig"),
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
