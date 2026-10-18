module MidB2 exposing (main)

-- B2 (handoff-midlang-b2): THE WORKED EXAMPLE — ladder rung 3+4 (a struct
-- by value, `&`, a `*T` parameter, mutation through it, `.` auto-deref).
-- `import Wext` resolves to Wext.mid next to this file.
--
-- Expected stdout: 1510150899
--   = o.a(15) | copy.a(1015) | copy.inner.k(8) | note(99)
-- o.a is 15 because Wext.bump MUTATED it through `&o` + `p.a`; copy.a is
-- 1015 because `Outer copy = o;` COPIED (an alias would leave 15 there and
-- print 1500150899).
import Wext

main =
    Wext.run 5
