module Door exposing (..)

-- A door state machine with a ROW-TYPED state and a GADT witness for the
-- transition relation. This is the program from the discuss.ocaml.org thread
-- t/13718 ("Unable to refute impossible GADT pattern with polymorphic
-- variants"), expressed in Withe: octachron's recommendation there is to
-- encode the states as type-level RECORDS (object types, one row variable per
-- field) because OCaml's GADT equations "cannot narrow a polymorphic variant
-- constraint". In Withe the states ARE rows, so that encoding is native.
--
-- SCOPE (do not overclaim). This is a translation of the source's
-- DECLARATIONS, its legal-cycle CONSTRUCTION, and its CHAIN match (the
-- nested-pattern fix). The OCaml wall is pattern-matching over the CHAIN with
-- nested patterns such as
--   Then (Then (Then Start Unlock) Open) Close
-- binding per-arm event witnesses. `readCurrent` below does exactly that: the
-- Event ctor is matched NESTED inside the Then pattern, and the nested event's
-- arrival state narrows the chain's current-state row branch-locally
-- (sub-pattern unification now runs in branch mode — `peelCtor` in
-- Type/Infer.elm). `readFrom` still matches the Event at top level to read
-- the FROM-state field, and `count` still binds the event via `Then prev ev`.
-- The transition GADT's indices `from`/`to` are KType, so the narrowing below
-- refines the RECORD ARGUMENT's row variable, not the Event indices: the
-- honest claim is "an external FSM translated to rows where per-state reads
-- use branch-local row refinement", not "the FSM expressed directly".
--
-- The source's headline WALL -- refuting an impossible arm (OCaml's `-> .`) --
-- is now ANSWERED in Withe: `describeBroken` below leaves out the six
-- impossible arms at the concrete end-state `Step { broken : String }` and
-- matches only the one possible arm; the checker refutes the rest under the
-- branch equations. (Pinned generally by the gate fixtures `refutpos` /
-- `refutneg`; see examples/research/README.md.)
--
-- States are rows. `State marker = { marker | n : Int }` names the row
-- extension once: a state is its marker plus the shared counter `n : Int`.
--   Locked  = {}                  -> State {}                  = { n : Int }
--   Closed  = { closed : Int }    -> State { closed : Int }    = { n : Int, closed : Int }
--   Open    = { open : Int }      -> State { open : Int }      = { n : Int, open : Int }
--   Broken  = { broken : String } -> State { broken : String } = { n : Int, broken : String }


-- The extension above, named: the row variable `marker` is each state's
-- closed prefix (its marker field), extended with the counter.
type alias State marker =
    { marker | n : Int }


-- The transition relation as a WITNESS GADT: a value `Event from to` is a
-- proof that "from -> to" is a legal transition. Constructing an illegal
-- transition is a compile-time error (see examples/research/README.md).
type Event from to
    = Unlock : Event {} { closed : Int }
    | Open : Event { closed : Int } { open : Int }
    | Close : Event { open : Int } { closed : Int }
    | Lock : Event { closed : Int } {}
    | Jiggle : Event { closed : Int } { closed : Int }
    | Break : Event { open : Int } { broken : String }
    | Reset : Event { broken : String } {}


-- A statically-typed chain of events, indexed by the CURRENT state row.
type Step s
    = Start : Step {}
    | Then : Step from -> Event from to -> Step to


-- The legal full cycle: Locked -> Closed -> Open -> Closed -> Locked.
cycle : Step {}
cycle =
    Then (Then (Then (Then Start Unlock) Open) Close) Lock


-- Reducer loop: fold a chain to its length.
count : type s. Step s -> Int
count step =
    case step of
        Start ->
            0

        Then prev ev ->
            1 + count prev


-- The membership witness (the crux this FSM reduces to): `Has l t rho` proves
-- the row rho carries field l : t. `read` is DEFINABLE but NOT CALLABLE at any
-- concrete witness (`read Here { n = 1, closed = 2 }` errs "cannot unify a
-- with {l:a| b}" — the global bare-KRow-vs-TRecord gap); its row index is
-- constructible only inside branch refinement or at an abstract row. It is
-- kept as the shape readFrom reduces to, not as a working reducer. The rigid
-- `type l t rho.` binder is NOT forced by this declaration — the record-tail
-- second argument lets the plain-signature form check; the binder is forced
-- where the second argument's row position is a bare TCon arg (the hget/HList
-- form, cf. examples/research/hlist2.elm and fixture rowgadt_l3ii).
type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


read : type l t rho. Has l t rho -> { rho | n : Int } -> t
read w rec =
    case w of
        Here ->
            rec.l

        There rest ->
            read rest rec


-- Load-bearing row refinement: read the FROM-state's marker field. Matching
-- the event selects the branch and equates the record argument's `from` row
-- with the constructor's (KType) index; the branch-local row refinement on
-- `from` then makes `rec.closed` / `rec.open` / `rec.broken` each well-typed
-- only in the branch whose transition departs that state. (The Event's own
-- indices are KType and play no row-specific role — see the SCOPE note above.)
readFrom : type from to. State from -> Event from to -> String
readFrom rec ev =
    case ev of
        Unlock ->
            "locked#" ++ String.fromInt rec.n

        Open ->
            "closed:" ++ String.fromInt rec.closed

        Close ->
            "open:" ++ String.fromInt rec.open

        Lock ->
            "closed:" ++ String.fromInt rec.closed

        Jiggle ->
            "closed:" ++ String.fromInt rec.closed

        Break ->
            "open:" ++ String.fromInt rec.open

        Reset ->
            "broken:" ++ rec.broken


-- The source's CHAIN match: the Event ctor nested inside the Then pattern.
-- Each arm's nested event equates the chain's current-state row `from` (the
-- `to` index of the nested event) with that event's arrival state, so
-- `rec.closed` / `rec.open` / `rec.broken` are each well-typed only in the arm
-- whose nested event ARRIVES at that state. This is the same branch-local row
-- refinement as `readFrom`, but narrowed AT THE NESTED LEVEL (sub-pattern
-- unification in branch mode), reading the arrival state rather than the
-- departure state.
readCurrent : type from. { from | n : Int } -> Step from -> String
readCurrent rec step =
    case step of
        Start ->
            "locked#" ++ String.fromInt rec.n

        Then prev Unlock ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Open ->
            "open:" ++ String.fromInt rec.open

        Then prev Close ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Lock ->
            "locked#" ++ String.fromInt rec.n

        Then prev Jiggle ->
            "closed:" ++ String.fromInt rec.closed

        Then prev Break ->
            "broken:" ++ rec.broken

        Then prev Reset ->
            "locked#" ++ String.fromInt rec.n


-- REFUTATION (the source's headline wall, now answered). At the CONCRETE
-- end-state `Step { broken : String }` the only inhabitant is `Then prev
-- Break`: `Start : Step {}` is impossible (`{}` has no `broken` field) and no
-- other Event ends at Broken, so the checker refutes those six arms under the
-- branch equations and this case — matching only the one possible arm —
-- compiles clean. That is OCaml's `-> .` mechanism, the thing the
-- discuss.ocaml.org t/13718 author could not get working there.
describeBroken : Step { broken : String } -> String
describeBroken step =
    case step of
        Then prev Break ->
            "ends broken"


main : String
main =
    readFrom { n = 3, open = 42 } Close
