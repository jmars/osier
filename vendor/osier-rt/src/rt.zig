//! src/rt.zig — module root for the osier runtime package (the vendor/osier-rt
//! split of handoff-osier-rtsplit).
//!
//! The runtime is what BOTH backends share and what survives the interpreter's
//! retirement (P8): the GC (src/gc.zig, its own module) plus this module's
//! value model, symbol interner, global tables, Vm state, the ValueArray
//! stack ops, the normative primitive semantics, stream I/O, and the process
//! exec-plan layer.  NOTHING in this package imports the ZINC interpreter
//! loop — that (interp, parser, hostcall, the csexp bundle loader) stays in
//! vendor/zinc-vm and dies with the interpreter.
//!
//! Layout:
//!   rt/state.zig    — Vm struct (owns *Gc, err slot, symbol interner, tables)
//!   rt/values.zig   — value model (val_* constructors, print_value, str_value,
//!                     deep_equal)
//!   rt/symbols.zig  — symbol interner + val_symbol
//!   rt/tables.zig   — defun/values global tables + GC registration glue
//!   rt/varray.zig   — ValueArray stack ops (va_init/va_push/va_pop/va_peek/
//!                     va_free) — extracted from interp.zig; a ValueArray
//!                     utility, not interpretation
//!   rt/prims.zig    — prim table + dispatch + the pure-subset exec_primitive
//!   rt/streams.zig  — string/file stream registry + the stream prims
//!   rt/execplan.zig — the process exec-plan prims (exec-plan/cd/getenv/...)

pub const state = @import("rt/state.zig");
pub const values = @import("rt/values.zig");
pub const symbols = @import("rt/symbols.zig");
pub const tables = @import("rt/tables.zig");
pub const varray = @import("rt/varray.zig");
pub const prims = @import("rt/prims.zig");
pub const streams = @import("rt/streams.zig");
pub const execplan = @import("rt/execplan.zig");
