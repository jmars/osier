module Mid.Simplify exposing (Config, defaultConfig, off, run, runWithReport)

-- Mid.Simplify — the middle tier's PASS PIPELINE and the ONE place its flag
-- scheme is documented.
--
-- STAGE HISTORY: S1 introduced the Mid IR with ZERO passes
-- (`MIDTIER=1` was byte-identical to `MIDTIER=0`).  This module is where the
-- passes live now.  The first pass to change an emitted byte breaks
-- byte-identity BY DESIGN (plan decision D5, accepted by the user): from here
-- on `tools/midtier-diff.sh` verifies MIDTIER=1 BEHAVIOURALLY (compile every
-- gate group under both modes, RUN both bundles on the VM, diff the outputs)
-- while `tools/withe-numbers.sh` still holds the MIDTIER=0 byte-identity
-- ANCHOR against `tools/withe-corpus-baseline.sha256` and the committed
-- bootstrap seed.  The anchor must hold forever: if a middle-tier change moves
-- a MIDTIER=0 byte, that is a bug, not a re-baseline.
--
-- PASS ORDER IS FIXED HERE (plan §(b), payoff order):
--
--   1. Shrink        dead bindings, copy propagation, beta, trivial inlining
--   2. ConstFold     fold rules ORACLED on the VM's own prim semantics
--      + CaseOfKnown case on a statically known constructor
--   3. Inline        full-arity call sites of small top-level defuns
--   4. Arity         saturation repair (partial-application fusion)
--   5. DeadGlobals   whole-program reachability
--   6. PathCSE       shared scrutinee reads inside one case block
--
-- The order COMPOUNDS and is not an accident: Shrink creates the beta-reduced
-- and single-use shapes Inline and ConstFold then see; Arity's fusion needs
-- the saturated shapes Inline leaves behind; DeadGlobals can only be exact
-- once Inline has stopped referencing a defun; PathCSE reads the case shapes
-- that none of the earlier passes rewrote.
--
-- FLAG SCHEME (one switch per pass, so any single pass can be disabled for
-- bisection; `MIDTIER=1` with NO flags = every pass ON):
--
--   MIDTIER=1                      all passes on (the default shape)
--   MIDTIER_NOSHRINK=1             pass 1 off
--   MIDTIER_NOCONSTFOLD=1          pass 2 off
--   MIDTIER_NOINLINE=1             pass 3 off
--   MIDTIER_NOARITY=1              pass 4 off
--   MIDTIER_NODEADGLOBALS=1        pass 5 off
--   MIDTIER_NOPATHCSE=1            pass 6 off
--   MIDTIER_INLINE_THRESHOLD=<n>   pass 3's size budget (default 30)
--
-- The switches are OFF-switches on purpose: "all passes on" is then the
-- zero-configuration shape, and disabling one pass is a single variable with
-- no risk of silently forgetting a pass added later.
--
-- MIDTIER=0 NEVER READS THIS MODULE (Main.elm picks `Lower.Module` before a
-- config exists), which keeps the byte-identity anchor structural rather than
-- conditional.

import Mid.Ir exposing (Defun)
import Mid.Shrink as Shrink


type alias Config =
    { shrink : Bool
    , constFold : Bool
    , inline : Bool
    , arity : Bool
    , deadGlobals : Bool
    , pathCse : Bool
    , inlineThreshold : Int
    }


defaultConfig : Config
defaultConfig =
    { shrink = True
    , constFold = True
    , inline = True
    , arity = True
    , deadGlobals = True
    , pathCse = True
    , inlineThreshold = 30
    }


{-| Every pass off.  Used by the differential's bisection mode: the pipeline
with all passes disabled must reproduce the S1 bytes exactly, which is what
separates "the passes changed nothing here" from "a pass is broken".  (That
check lives in `tools/midtier-diff.sh`; as of pass 1 the same property is what
`MIDTIER_NOSHRINK=1` gives, since Shrink is the only pass that exists.)
-}
off : Config
off =
    { defaultConfig
        | shrink = False
        , constFold = False
        , inline = False
        , arity = False
        , deadGlobals = False
        , pathCse = False
    }


{-| Run the pipeline over the FLAT defun list of one bundle, discarding the
report.  The report-carrying entry point is `runWithReport` (Mid.Module uses
it for `MIDTIER_STATS`).

The list is the WHOLE BUNDLE's defuns at once (corpus ++ group, flattened),
not one unit at a time: the later whole-program passes (Inline's
reachability, DeadGlobals) need corpus and group defuns together — a group
calls corpus defuns, and a corpus defun can be reachable only from a group.
Flattening also drops the per-unit boundary, which is correct here: a
`Defun`'s binder ids are unique WITHIN ITSELF (`Mid.Ir`), so no pass needs
the unit grouping back.

-}
run : Config -> List Defun -> List Defun
run config defuns =
    Tuple.first (runWithReport config defuns)


runWithReport : Config -> List Defun -> ( List Defun, String )
runWithReport config defuns =
    if config.shrink then
        Shrink.run defuns

    else
        ( defuns, "" )
