const std = @import("std");

// vendor/osier-rt — the osier runtime package (handoff-osier-rtsplit).
//
// TWO modules, by the user's ruling ("vendor the GC" + "the prims"):
//   gc — the precise moving collector (src/gc.zig + src/gc/*).  Imports
//        nothing outside itself and std; both backends link it deliberately.
//   rt — the runtime: value model, symbol interner, global tables, Vm state,
//        ValueArray stack ops (varray), the normative prims, streams, and the
//        exec-plan layer.  Imports gc ONLY — never the ZINC interpreter.
//
// The interpreter (interp, parser, hostcall, the csexp bundle loader) is the
// vendor/zinc-vm package, which DEPENDS on this one and dies at P8.
//
//   zig build test    run the gc suite (Debug; -Doptimize honours the mode)
//   zig build gate    gc suite in Debug + ReleaseSafe + ReleaseFast
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gc_mod = b.addModule("gc", .{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("rt", .{
        .root_source_file = b.path("src/rt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
    });

    const test_step = b.step("test", "Run tests");
    const gc_test_step = b.step("gc-test", "Run the GC tests (honours -Doptimize)");
    gc_test_step.dependOn(addGcTestSet(b, target, optimize));
    test_step.dependOn(gc_test_step);

    // `gate`: the permanent multi-mode gate (Debug + ReleaseSafe +
    // ReleaseFast).  ReleaseSafe keeps std.debug.assert live inside the
    // collector, so every safety enforcement is proven under the gate, not
    // just in Debug.
    const gate_step = b.step("gate", "Run the GC tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addGcTestSet(b, target, .Debug));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseSafe));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseFast));
}

/// Build one self-contained GC test set compiled at `opt` and return its run
/// step.  Each mode needs its own gc module (std.debug.assert inside the
/// collector is gated by that module's optimize), so every call builds an
/// independent gc_mod + gc_test_mod + addTest + run + T9 expected-panic exe.
/// The unnamed modules (b.createModule) avoid duplicate "gc" module names
/// across the gate's three instances.
fn addGcTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = opt,
    });

    const gc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc_test.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });
    const run_gc_tests = b.addRunArtifact(gc_tests);

    // T9: expected-panic executable — the ROOT_PTR interior-pointer defense
    // is proven by a tiny exe that overrides its root panic handler and
    // exits 42; the Run step expects exactly that (in-process panic
    // assertion does not exist in Zig 0.16).
    const t9_mod = b.createModule(.{
        .root_source_file = b.path("tests/root_ptr_panic.zig"),
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
