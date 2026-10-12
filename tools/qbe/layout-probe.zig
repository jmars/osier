//! tools/qbe/layout-probe.zig — the ZIG side of the layout census
//! (handoff-osier-zigretire-plan STAGE 2).
//!
//! Prints, as `name=value` lines, every cross-ABI layout number the `gc`
//! package can attest BY ITSELF — computed by the Zig compiler from the
//! declarations, never restated here: `@sizeOf`/`@alignOf`/`@offsetOf` on
//! `types.Value`, `@intFromEnum` on `types.ValTag`, and the payload field
//! offsets read through the actual union member.
//!
//! WHY A PROGRAM AND NOT A GREP.  A textual extraction of `extern struct`
//! field lists would RE-IMPLEMENT the ABI in awk and then agree with itself;
//! this asks the compiler that lays the struct out.
//!
//! WHAT IT CANNOT SEE, stated rather than implied: `Desc`/`Meta`/`Ret` and
//! `max_arity` live in `tools/qbe/rt.zig`, which this probe cannot import —
//! rt.zig exports `main` (the driver), so linking a second executable that
//! imports it is an exported-symbol collision.  Those names are attested by
//! the `comptime` row INSIDE rt.zig against `gc/layout_gen.zig` instead (a
//! mismatch fails `zig build gate`).  `descQbeTypeBytes` has no Zig
//! declaration at all: it is the QBE `:desc` type's own prefix size, pinned
//! by the corpus byte-identity oracle.
//!
//! Run by tools/qbe/layout-census.sh --zig; not part of any Zig build.
const std = @import("std");
const gc = @import("gc");
const types = gc.types;

const StrField = @FieldType(@FieldType(types.Value, "payload"), "str");

fn w(comptime name: []const u8, value: anytype) void {
    std.debug.print("{s}={d}\n", .{ name, value });
}

pub fn main() void {
    w("abiAlign", @alignOf(types.Value));
    w("wordBytes", @sizeOf(usize));
    w("i32Bytes", @sizeOf(i32));
    w("valueTagBytes", @sizeOf(types.ValTag));
    w("valSizeBytes", @sizeOf(types.Value));
    w("payloadBase", @offsetOf(types.Value, "payload"));
    w("valuePayloadWords", @sizeOf(@FieldType(types.Value, "payload")) / 8);
    // The i32 FIELDS of a Value (str.len, vector.len, boolean) are the low
    // half of one payload word — read through the union's own member, so the
    // probe follows the struct rather than a remembered offset.
    w("lenFieldWord", @offsetOf(StrField, "len") / 8);
    w("lenFieldOffset", @offsetOf(types.Value, "payload") + @offsetOf(StrField, "len"));

    w("tagNumber", @intFromEnum(types.ValTag.number));
    w("tagString", @intFromEnum(types.ValTag.string));
    w("tagSymbol", @intFromEnum(types.ValTag.symbol));
    w("tagBoolean", @intFromEnum(types.ValTag.boolean));
    w("tagCons", @intFromEnum(types.ValTag.cons));
    w("tagNil", @intFromEnum(types.ValTag.nil));
    w("tagLambda", @intFromEnum(types.ValTag.lambda));
    w("tagMark", @intFromEnum(types.ValTag.mark));
    w("tagPrim", @intFromEnum(types.ValTag.prim));
    w("tagError", @intFromEnum(types.ValTag.error_));
    w("tagVector", @intFromEnum(types.ValTag.vector));
    w("tagStream", @intFromEnum(types.ValTag.stream));
    w("tagFloat", @intFromEnum(types.ValTag.float));
    w("tagRecord", @intFromEnum(types.ValTag.record));
}
