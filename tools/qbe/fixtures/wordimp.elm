module WordImp exposing (main)

-- M4NICE item 3: THE END-TO-END PIN OF THE `word`-UNCALLABILITY CLAIM.
--
-- `Wordy.poke` is exported as `word -> val` (Wordy.mid, resolved reader-side by
-- the `import Wordy` below).  The `word` atom is the RIGID opaque type
-- `TCon "Word" []`, so the concrete literal `5` (an unannotated `number`) is
-- refused LOUDLY — the compile must fail naming the unifier, and the qbe-check
-- row pins the message ("cannot unify number with Word").
--
-- This is the seat the whole `word`-is-opaque design stands on: if `word` were
-- ever mapped to a fresh variable (`val`'s mapping) or downgraded to a concrete
-- scalar, `5` would unify and this fixture would COMPILE — the row goes red,
-- which is why it is here and not only in TestMain (whose rows pin the scheme
-- MAPPING and the two unifier facts separately, never the composition).
import Wordy

main =
    Wordy.poke 5
