module MonoRefuse exposing (main, twice, plainAt, hget, hgetPlain, box, apply2, fold, litArg)

-- MONOMORPHISATION — the REFUSAL direction (S5/M2, Mid/Qbe/Monomorphise.elm;
-- switch QBE_NOMONO=1).
--
-- WHY THIS FIXTURE EXISTS.  The specialiser's whole risk is the instantiation
-- it must NOT clone: a monotype that is not closed, not rigid-free, or not
-- refinement-free is a fact about ONE branch of a GADT program, and baking it
-- into a body that runs outside that branch is a wrong answer the moment a
-- parameter is unboxed.  Deny-by-default is only testable if the fixture
-- contains sites that LOOK instantiable — every entry below is a saturated
-- direct call with a `GRef` head to a POLYMORPHIC defun, which is the
-- specialiser's trigger.
--
-- WHAT THE ROWS ASSERT is an ASYMMETRY inside one .ssa: `twice` at Int IS
-- cloned, and the four GADT/generic sites are NOT, while the pass's own note
-- line reports which clause refused each one.  A refusal row alone could be
-- satisfied by the pass never running; the firing site in the same file is
-- what makes it evidence.  The `.ssa` for a refusing entry must also be
-- BYTE-IDENTICAL to its `QBE_NOMONO=1` arm once the note line is removed: the
-- pass saw the site and changed nothing.
--
-- WHICH CLAUSE EACH SITE EXERCISES:
--   * `hget`      — (b) RIGID.  Its scheme's `bound` holds GADT type indices
--                   (`Has l t rho`, `HList rho`), and clause (b) is TOTAL:
--                   instantiation is impossible, not merely unwise.
--   * `hgetPlain` — (c) REFINED, the research-specific clause.  `box x` is
--                   applied to a binder whose type mentions a variable the
--                   `Here` branch's row equation refined.  `box` is INFERRED,
--                   so its scheme's `bound` is empty and clause (b) cannot
--                   fire — clause (c) is the only thing between this site and
--                   a clone that bakes a branch-local fact into a body that
--                   runs outside the branch.  (The same entry's recursive call
--                   is refused by (b), so both GADT clauses are visible in one
--                   compile.)
--   * `apply2`    — (a) UNCLOSED.  The arguments are the ENCLOSING polymorphic
--                   defun's own type variables, so the instantiation is not a
--                   monotype at all.
--   * `untyped`   — the ROW compiles entry `fold`, whose site is its own
--                   RECURSIVE call: `f`'s recorded type IS the very variable
--                   being instantiated and `(f y acc)` is an application, so no
--                   argument POSITION can type the scheme at all.  Same reason
--                   `Mono.fib`'s own recursive calls are refused in the sibling
--                   fixture.
--   * `litArg`    — the ADMITTED control beside the four refusals, and why it
--                   is in this file at all: `fold (\a b -> a + b) 0
--                   (rangeUp n)` IS cloned.  The literal and application
--                   positions are TOLERATED once the scheme's variables close,
--                   and here they do — the Lam's params carry `Int` in the S2
--                   binder map.  It is the live counterexample to "untyped
--                   arguments make `fold` unclonable".
--
-- THE GADT FUNCTIONS ARE NOT CALLED FROM `main`, deliberately.  This encoding
-- is a TYPE-SYSTEM probe, not an inhabited data structure: `HCons`'s result
-- row is `{ l : t | rho }` while its tail argument is `HList rho`, so a value
-- exists only up to the scope discipline the types exist to test.  `main` is
-- therefore the BEHAVIOURAL entry (golden output plus the QBE_HEAP_MB=16 churn
-- rerun) and exercises the runnable shapes; the GADT clauses are exercised
-- STRUCTURALLY, each under its own entry, by the `mono-refuse-*` rows.


-- --- the FIRING control (proves the pass runs on this compile) -------------

twice : (a -> a) -> a -> a
twice f x =
    f (f x)


plainAt : Int -> Int
plainAt n =
    twice (\k -> k + 1) n


-- --- (b) RIGID and (c) REFINED ---------------------------------------------

type Has l t rho
    = Here : Has l t { l : t | rho }
    | There : Has l t rho -> Has l t { k : s | rho }


type HList rho
    = HNil : HList {}
    | HCons : Has l t rho -> t -> HList rho -> HList { l : t | rho }


-- (b): the recursive call is a saturated direct call to a defun whose scheme
-- carries rigid GADT indices.
hget : Has l t rho -> HList rho -> t
hget h xs =
    case ( h, xs ) of
        ( Here, HCons _ x _ ) ->
            x

        ( There h2, HCons _ _ rest ) ->
            hget h2 rest


-- (c): an inferred helper (`bound` is empty, so (b) cannot fire) applied to a
-- branch-refined binder.
box x =
    x


hgetPlain : Has l t rho -> HList rho -> t
hgetPlain h xs =
    case ( h, xs ) of
        ( Here, HCons _ x _ ) ->
            box x

        ( There h2, HCons _ _ rest ) ->
            hgetPlain h2 rest


-- --- (a) UNCLOSED -----------------------------------------------------------

fold : (a -> b -> b) -> b -> List a -> b
fold f acc xs =
    case xs of
        [] ->
            acc

        y :: ys ->
            fold f (f y acc) ys


apply2 : (a -> b -> b) -> b -> List a -> b
apply2 f acc xs =
    fold f acc xs


-- --- untyped ----------------------------------------------------------------

litArg : Int -> Int
litArg n =
    fold (\a b -> a + b) 0 (rangeUp n)


rangeUp : Int -> List Int
rangeUp n =
    if n <= 0 then
        []

    else
        n :: rangeUp (n - 1)


-- --- the behavioural entry --------------------------------------------------

main : Int
main =
    plainAt 3 + apply2 (\a b -> a + b) 0 (rangeUp 4) + litArg 5
