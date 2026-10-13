module MidgcString exposing (main)

-- zigretire stage 5 PART 4 — THE CROSS-HEAP PROBE for STRING LITERALS.
--
-- The corrected criterion (plan.md §2.2): no Mid object may reference anything
-- the ZIG collector can reclaim.  The Zig collector frees by REACHABILITY, and
-- its nursery scavenge re-claims the WHOLE nursery (collect.zig:713-720) —
-- so a Zig-nursery string whose Value sits in a Mid object is reclaimed while
-- still live.  rt_string's fallback (rt.zig:405-408) allocates exactly such a
-- string: it fires on QBE_NOSTRINGINTERN=1 AND at run time once
-- intern_live >= 2048, so a flag guard cannot see the runtime case.
--
-- THIS FIXTURE CONSTRUCTS the scenario: `keep` is a Mid cons list of 100
-- DISTINCT string literals (their data lives in the Zig nursery on the
-- rt_string route), the churn below evaluates a literal ~400k times so the
-- nursery fills and scavenges, and then `keep == keep2` compares the kept
-- strings BY CONTENT (memcmp of the data bytes, not the length field — a
-- length-only read would hide the hole).  BEFORE the fix, under
-- QBE_MIDGC=1 + QBE_NOSTRINGINTERN=1, the scavenge reclaims keep's data and
-- the equality fails -> 31200100.  AFTER the fix, string literals are emitted
-- as STATIC data (the immutable, null-terminated data symbol itself), so
-- rt_string is never called, there is no nursery allocation to reclaim, and
-- both the flag AND the intern_live >= 2048 fallback are structurally
-- unreachable -> 31200200 (the content equality holds: +100).
--
-- The fail-before/pass-after asymmetry is scripted in
-- tools/qbe/probe-midgc-string.sh (revert ONE line in lowerLit's LString case
-- to restore the Zig rt_string route, rebuild, run, restore) and that script
-- ALSO asserts the emitted .ssa contains ZERO rt_string calls (the structural
-- pin: a re-added Zig string route under the hatch goes red on emission, not
-- just on behaviour).

keep =
    ["s0000", "s0001", "s0002", "s0003", "s0004", "s0005", "s0006", "s0007", "s0008", "s0009", "s0010", "s0011", "s0012", "s0013", "s0014", "s0015", "s0016", "s0017", "s0018", "s0019", "s0020", "s0021", "s0022", "s0023", "s0024", "s0025", "s0026", "s0027", "s0028", "s0029", "s0030", "s0031", "s0032", "s0033", "s0034", "s0035", "s0036", "s0037", "s0038", "s0039", "s0040", "s0041", "s0042", "s0043", "s0044", "s0045", "s0046", "s0047", "s0048", "s0049", "s0050", "s0051", "s0052", "s0053", "s0054", "s0055", "s0056", "s0057", "s0058", "s0059", "s0060", "s0061", "s0062", "s0063", "s0064", "s0065", "s0066", "s0067", "s0068", "s0069", "s0070", "s0071", "s0072", "s0073", "s0074", "s0075", "s0076", "s0077", "s0078", "s0079", "s0080", "s0081", "s0082", "s0083", "s0084", "s0085", "s0086", "s0087", "s0088", "s0089", "s0090", "s0091", "s0092", "s0093", "s0094", "s0095", "s0096", "s0097", "s0098", "s0099"]


keep2 =
    ["s0000", "s0001", "s0002", "s0003", "s0004", "s0005", "s0006", "s0007", "s0008", "s0009", "s0010", "s0011", "s0012", "s0013", "s0014", "s0015", "s0016", "s0017", "s0018", "s0019", "s0020", "s0021", "s0022", "s0023", "s0024", "s0025", "s0026", "s0027", "s0028", "s0029", "s0030", "s0031", "s0032", "s0033", "s0034", "s0035", "s0036", "s0037", "s0038", "s0039", "s0040", "s0041", "s0042", "s0043", "s0044", "s0045", "s0046", "s0047", "s0048", "s0049", "s0050", "s0051", "s0052", "s0053", "s0054", "s0055", "s0056", "s0057", "s0058", "s0059", "s0060", "s0061", "s0062", "s0063", "s0064", "s0065", "s0066", "s0067", "s0068", "s0069", "s0070", "s0071", "s0072", "s0073", "s0074", "s0075", "s0076", "s0077", "s0078", "s0079", "s0080", "s0081", "s0082", "s0083", "s0084", "s0085", "s0086", "s0087", "s0088", "s0089", "s0090", "s0091", "s0092", "s0093", "s0094", "s0095", "s0096", "s0097", "s0098", "s0099"]


-- Tail-recursive so the churn stays an in-frame loop; each iteration
-- evaluates the literal (a fresh Zig nursery string on the --before
-- route under QBE_NOSTRINGINTERN=1).
churn n acc =
    if n == 0 then
        acc

    else
        churn (n - 1) (acc + String.length "churn-payload-abcdefghijklmnopqrstuvwxyz-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ")


main =
    let
        kept =
            keep

        -- `List.length kept` forces keep's construction (and so the string
        -- allocations) BEFORE the churn; the churn's scavenge then reclaims
        -- the unrooted Zig-nursery data on the --before route.
        dropped =
            churn 400000 (List.length kept)

        ok =
            if kept == keep2 then
                100

            else
                0
    in
    dropped + ok
