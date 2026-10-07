module Mid.PathCse exposing (Stats, run)

-- Mid.PathCse — the middle tier's SIXTH pass: common-subexpression elimination
-- of the pattern compiler's repeated scrutinee-path reads.
--
-- MEASURED SEAT, NOT A TRANSFORM.  The plan's spec is "Lower.Pattern re-reads
-- the scrutinee path per clause test — CSE per case block".  This module
-- COUNTS the opportunity precisely (how many `readPath` invocations a CSE
-- could eliminate) and reports it, but it does not rewrite, for the measured
-- reason documented here — the same discipline as `Mid.ConstFold`'s
-- CaseOfKnown seat (measure the shape, publish the number, build the transform
-- only if the number earns it).
--
-- WHY THE COUNT IS THE WHOLE STORY.  The emitter already FUSES `Access <n>`
-- with a following `Prim` into one `A n p` instruction (`Zinc.Emit`'s fuse
-- peephole), so the common shared read — the tag read `[IdxStep 0]`, emitted
-- as `Number 0; A d <-address` — is TWO instructions.  Hoisting it into a
-- temp costs THREE (`Number 0; A d <-address; Let_`) plus ONE `Access` per
-- reuse, so the hoist is a net WIN only when the path is shared by 4+ matches
-- (saves `N - 3` instructions for N sharers) and is a WASH or LOSS for the
-- typical 2-3-alt case block.  The transform ALSO needs a Case-prelude IR
-- slot (temps bound after the scrutinee's `Let_`, which the Case has no room
-- for) and rewires the pattern-matching emission — the most subtle part of
-- the byte stream — so it is deliberately not built: the seat is measured,
-- the number is published, and the transform is left for a stage whose
-- budget earns it.
--
-- WHAT IS COUNTED: per Case (and per LetDestruct), the number of match tests
-- whose NON-EMPTY path is identical to an earlier test's path in the same
-- block — the `readPath` duplications a CSE would target.  The empty path is
-- the bare scrutinee read, which is ALREADY a shared temp (`scrutId`), so it
-- is not counted.

import Dict exposing (Dict)
import Mid.Ir exposing (Alt, Defun, Exp(..), LetBinder(..), Match(..), Step(..))
import Set exposing (Set)


type alias Stats =
    { defuns : Int
    , cases : Int
    , tests : Int
    , dupPaths : Int
    , estSaved : Int
    }


zero : Stats
zero =
    { defuns = 0
    , cases = 0
    , tests = 0
    , dupPaths = 0
    , estSaved = 0
    }


plus : Stats -> Stats -> Stats
plus a b =
    { defuns = a.defuns + b.defuns
    , cases = a.cases + b.cases
    , tests = a.tests + b.tests
    , dupPaths = a.dupPaths + b.dupPaths
    , estSaved = a.estSaved + b.estSaved
    }


run : List Defun -> ( List Defun, String )
run defuns =
    let
        ( rev, stats ) =
            List.foldl pathCseDefun ( [], zero ) defuns
    in
    ( List.reverse rev, report stats )


report : Stats -> String
report s =
    if s.cases == 0 then
        ""

    else
        "pathcse: defuns="
            ++ String.fromInt s.defuns
            ++ " cases="
            ++ String.fromInt s.cases
            ++ " tests="
            ++ String.fromInt s.tests
            ++ " dupPaths="
            ++ String.fromInt s.dupPaths
            ++ " (gross 2*dup="
            ++ String.fromInt s.estSaved
            ++ " upper bound; net ~0 for the typical <=3-alt block after Let_+Access hoist overhead)"


pathCseDefun : Defun -> ( List Defun, Stats ) -> ( List Defun, Stats )
pathCseDefun defun ( acc, accStats ) =
    let
        ( _, stats ) =
            pathCseExp defun.value
    in
    ( defun :: acc, plus accStats { stats | defuns = 1 } )



-- ============================ THE COUNTER ============================


pathCseExp : Exp -> ( Exp, Stats )
pathCseExp exp =
    case exp of
        Case branch ->
            let
                ( scrutinee, s1 ) =
                    pathCseExp branch.scrutinee

                ( alts, s2 ) =
                    pathCseAlts branch.alts

                block =
                    countBlock (List.concatMap .matches branch.alts)
            in
            ( Case { branch | scrutinee = scrutinee, alts = alts }, plus s1 (plus s2 block) )

        Let block ->
            let
                ( binders, s1 ) =
                    pathCseBinders block.binders

                ( body, s2 ) =
                    pathCseExp block.body
            in
            ( Let { binders = binders, body = body }, plus s1 s2 )

        Lam lam ->
            let
                ( body, s ) =
                    pathCseExp lam.body
            in
            ( Lam { lam | body = body }, s )

        NoTail inner ->
            let
                ( e, s ) =
                    pathCseExp inner
            in
            ( NoTail e, s )

        App app ->
            let
                ( fn, s1 ) =
                    pathCseExp app.fn

                ( args, s2 ) =
                    pathCseAll app.args
            in
            ( App { fn = fn, args = args }, plus s1 s2 )

        PrimApp app ->
            let
                ( args, s ) =
                    pathCseAll app.args
            in
            ( PrimApp { app | args = args }, s )

        Con con ->
            let
                ( args, s ) =
                    pathCseAll con.args
            in
            ( Con { con | args = args }, s )

        Tup es ->
            let
                ( es1, s ) =
                    pathCseAll es
            in
            ( Tup es1, s )

        RecordLit setters ->
            let
                ( s1, st ) =
                    pathCseSetters setters
            in
            ( RecordLit s1, st )

        RecordGet base field ->
            let
                ( b, s ) =
                    pathCseExp base
            in
            ( RecordGet b field, s )

        RecordUpdate upd ->
            let
                ( base, s1 ) =
                    pathCseExp upd.base

                ( updates, s2 ) =
                    pathCseSetters upd.updates
            in
            ( RecordUpdate { upd | base = base, updates = updates }, plus s1 s2 )

        ListLit es ->
            let
                ( es1, s ) =
                    pathCseAll es
            in
            ( ListLit es1, s )

        If block ->
            let
                ( cond, s1 ) =
                    pathCseExp block.cond

                ( t, s2 ) =
                    pathCseExp block.thenBranch

                ( f, s3 ) =
                    pathCseExp block.elseBranch
            in
            ( If { block | cond = cond, thenBranch = t, elseBranch = f }, plus s1 (plus s2 s3) )

        ShortAnd block ->
            let
                ( left, s1 ) =
                    pathCseExp block.left

                ( right, s2 ) =
                    pathCseExp block.right
            in
            ( ShortAnd { block | left = left, right = right }, plus s1 s2 )

        ShortOr block ->
            let
                ( left, s1 ) =
                    pathCseExp block.left

                ( right, s2 ) =
                    pathCseExp block.right
            in
            ( ShortOr { block | left = left, right = right }, plus s1 s2 )

        NotEqual block ->
            let
                ( left, s1 ) =
                    pathCseExp block.left

                ( right, s2 ) =
                    pathCseExp block.right
            in
            ( NotEqual { block | left = left, right = right }, plus s1 s2 )

        Lit _ ->
            ( exp, zero )

        Var _ ->
            ( exp, zero )

        GRef _ ->
            ( exp, zero )

        StreamRef _ ->
            ( exp, zero )


pathCseAll : List Exp -> ( List Exp, Stats )
pathCseAll exps =
    case exps of
        [] ->
            ( [], zero )

        e :: rest ->
            let
                ( e1, s1 ) =
                    pathCseExp e

                ( rest1, s2 ) =
                    pathCseAll rest
            in
            ( e1 :: rest1, plus s1 s2 )


pathCseSetters : List ( String, Exp ) -> ( List ( String, Exp ), Stats )
pathCseSetters setters =
    case setters of
        [] ->
            ( [], zero )

        ( field, value ) :: rest ->
            let
                ( v1, s1 ) =
                    pathCseExp value

                ( rest1, s2 ) =
                    pathCseSetters rest
            in
            ( ( field, v1 ) :: rest1, plus s1 s2 )


pathCseBinders : List LetBinder -> ( List LetBinder, Stats )
pathCseBinders binders =
    case binders of
        [] ->
            ( [], zero )

        b :: rest ->
            let
                ( b1, s1 ) =
                    pathCseBinder b

                ( rest1, s2 ) =
                    pathCseBinders rest
            in
            ( b1 :: rest1, plus s1 s2 )


pathCseBinder : LetBinder -> ( LetBinder, Stats )
pathCseBinder b =
    case b of
        LetBind bind ->
            let
                ( v, s ) =
                    pathCseExp bind.value
            in
            ( LetBind { bind | value = v }, s )

        LetDestruct destruct ->
            let
                ( v, s1 ) =
                    pathCseExp destruct.value

                block =
                    countBlock destruct.matches
            in
            ( LetDestruct { destruct | value = v }, plus s1 block )


pathCseAlts : List Alt -> ( List Alt, Stats )
pathCseAlts alts =
    case alts of
        [] ->
            ( [], zero )

        alt :: rest ->
            let
                ( body, s1 ) =
                    pathCseExp alt.body

                ( rest1, s2 ) =
                    pathCseAlts rest
            in
            ( { alt | body = body } :: rest1, plus s1 s2 )



-- ============================ THE COUNT ============================


-- Count duplicate PATHS within one block's match list: a path that appears in
-- a later match of the SAME block is a re-read that a CSE could eliminate.
-- Each duplicate beyond the first costs ~2 emitted instructions (the fused
-- `Number idx` + `A d <-address` pair).
countBlock : List Match -> Stats
countBlock matches =
    let
        result =
            List.foldl
                (\m acc ->
                    let
                        path =
                            matchPath m
                    in
                    -- The EMPTY path is the bare scrutinee read, which is
                    -- ALREADY a shared temp (scrutId) — no CSE to do there.
                    -- Only non-empty paths (an index or de-structuring step)
                    -- are genuinely re-computed per test.
                    if path == "" then
                        { acc | tests = acc.tests + 1 }

                    else if Set.member path acc.seen then
                        { acc | dup = acc.dup + 1, tests = acc.tests + 1 }

                    else
                        { acc | seen = Set.insert path acc.seen, tests = acc.tests + 1 }
                )
                { seen = Set.empty, dup = 0, tests = 0 }
                matches
    in
    { defuns = 0
    , cases = 1
    , tests = result.tests
    , dupPaths = result.dup
    , estSaved = 2 * result.dup
    }


matchPath : Match -> String
matchPath m =
    case m of
        MCons path ->
            pathString path

        MEmpty path ->
            pathString path

        MVector path ->
            pathString path

        MTagEq path _ ->
            pathString path

        MLitEq path _ ->
            pathString path


pathString : List Step -> String
pathString steps =
    String.join "." (List.map stepString steps)


stepString : Step -> String
stepString step =
    case step of
        FstStep ->
            "fst"

        SndStep ->
            "snd"

        HdStep ->
            "hd"

        TlStep ->
            "tl"

        IdxStep i ->
            "i" ++ String.fromInt i
