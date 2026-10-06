import Lake
open Lake DSL

package rowgadt

/-- The λρG row-algebra library: RowGadt (H1 + H2), RowGadtEscape (the two
escape obligations, imports RowGadt) and Update (the update theorem, imports
RowGadt). -/
@[default_target]
lean_lib RowGadtLib where
  roots := #[`RowGadt, `RowGadtEscape, `Update, `Typing, `TypingStore, `Preserve]
