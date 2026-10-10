//! src/vm.zig — module root for the ZINC VM INTERPRETER (the half that dies
//! at P8; handoff-osier-rtsplit).
//!
//! The runtime (GC, values, state, tables, varray, prims, streams, execplan)
//! was split into the osier-rt package ("rt"), which this package depends on
//! and re-exports below so existing `@import("vm").values`-style references
//! keep working.  What is INTERPRETER-ONLY here:
//!   vm/parser.zig   — csexp parser + resolve_jumps + print_instr + the
//!                     bundle loader (loadBundle) — M3/M6
//!   vm/interp.zig   — the eval loop (vm_exec_env / vm_exec) — M4
//!   vm/hostcall.zig — host-side calls into BUNDLED closures via vmExecEnv
//!
//! DELETED with the split: vm/marshal.zig (its only consumer was the
//! eval-kl prim, unreachable from Osier) and the Shen catch machinery
//! (CatchSite/catch_chain/in_trap_error) with the trap-error prim.

const rt = @import("rt");

// ---- the runtime package, re-exported (osier-rt) ----
pub const state = rt.state;
pub const values = rt.values;
pub const symbols = rt.symbols;
pub const tables = rt.tables;
pub const varray = rt.varray;
pub const prims = rt.prims;
pub const streams = rt.streams;
pub const execplan = rt.execplan;

// ---- the interpreter (this package's own content) ----
pub const parser = @import("vm/parser.zig");
pub const interp = @import("vm/interp.zig");
pub const hostcall = @import("vm/hostcall.zig");
