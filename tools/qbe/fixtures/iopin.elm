module IoPin exposing (main)

-- CONTRACT 3 (`!io`) — CARRIED, NOT ENFORCED (plan.md §2.5).  `import Iopin`
-- resolves to Iopin.mid next to this file (the .mid is NOT passed on the CLI),
-- and `Iopin.answer` is an IMPURE export: it raw-`write`s "io:" to stdout
-- before returning its argument.  Nothing refuses this call, and nothing
-- should yet — Osier has no effect system, so an `!io` marker is documentation.
-- The qbe-check row `iopin` is the pin (and the Phase-7 asymmetry oracle).
import Iopin

main =
    Iopin.answer 7
