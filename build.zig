const std = @import("std");

// osier — the language repo (compiler + Lean mechanization + the language's
// evidence chain).  This build.zig builds the LANGUAGE targets only: the gc
// test gates driven by the vendor/osier-rt path dependency (the runtime/GC
// package).  The QBE native path's runtime object (tools/qbe/rt.o) is built
// by tools/qbe/qbe-mk.sh / tools/qbe/qbe-selfhost.sh via `zig build-obj`, not
// by this file.  The UI (fx_ui exe, src/renderer/*, gui_*/terminal, ptytest,
// genwidth) lives in the fx-ui repo and is deliberately NOT here.
//
// P8 (osier-delete-zinc): the ZINC interpreter package (vendor/zinc-vm) and
// everything that linked it are GONE — elmvm (the VM gate harness), vmbench
// (the throughput benchmark), aotdump + the AOT spike exes + aot-build (the
// csexp-consuming ahead-of-time path).  What remains here is the GC suite,
// which the QBE runtime links deliberately (vendor/osier-rt owns it).
//
//   zig build test      gc (osier-rt) suite via the path dependency
//   zig build gate      gc suite in Debug + ReleaseSafe + ReleaseFast
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // ---- tests: the GC (osier-rt) suite via the path dependency ----
    const test_step = b.step("test", "Run tests");
    const gc_test_step = b.step("gc-test", "Run Shen GC tests (honours -Doptimize)");
    gc_test_step.dependOn(addGcTestSet(b, target, .Debug));
    test_step.dependOn(gc_test_step);

    // ---- `gate`: the permanent multi-mode build gate ----
    const gate_step = b.step("gate", "Run Shen GC tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addGcTestSet(b, target, .Debug));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseFast));
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
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });
    const run_gc_tests = b.addRunArtifact(gc_tests);

    // T9: expected-panic executable — the ROOT_PTR interior-pointer defense is
    // proven by a tiny exe that overrides its root panic handler and exits 42.
    const t9_mod = b.createModule(.{
        .root_source_file = osier_rt.path("tests/root_ptr_panic.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
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
