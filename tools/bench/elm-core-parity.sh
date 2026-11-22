#!/bin/bash
# elm-core-parity.sh — the elm/core 1.0.5 <-> Osier core-libs DIVERGENCE TABLE.
#
# WHAT IT MEASURES. The human's compatibility directive (ledger #120) is "an elm
# package should be droppable into Osier: swap its Elm.Kernel.* JS to Mid-C and
# leave the sources mostly unmolested".  A package's sources compile only if the
# module + exposed-name surface it imports exists.  That surface in Osier is
# split across THREE places, and a table that looks at only one of them lies:
#
#   1. osier-compiler/core-libs/*.elm      — real modules (Dict, Set, Maybe, ...)
#   2. osier-compiler/src/Prelude.elm      — the implicit-prelude module (Basics,
#                                            List, String, Char values/functions)
#   3. osier-compiler/src/Lower/Resolve.elm — the DOTTED alias rows
#                                            (`String.length`, `Char.toCode`, ...)
#                                            that rewrite to a Prelude/prim global
#
# So "absent module" is NOT the same as "absent surface": elm/core's Char.elm is
# absent as a FILE, but every Char function Parser.elm uses resolves through row 3.
#
# OUTPUT: (a) module-by-module status, (b) exposed-name diff for the modules that
# exist on both sides, (c) for the modules that do NOT, how many of their exposed
# names rows 2+3 already serve, (d) totals + coverage.
#
# USAGE: tools/bench/elm-core-parity.sh [--missing]   (--missing = name the gaps)
# EXIT:  0 always (this is a measurement, not a gate) unless a corpus dir is gone.
set -u
cd "$(dirname "$0")/../.." || exit 2
CORE=tools/bench/elm-corpus/elm__core/src
LIBS=osier-compiler/core-libs
PRELUDE=osier-compiler/src/Prelude.elm
RESOLVE=osier-compiler/src/Lower/Resolve.elm
for d in "$CORE" "$LIBS" "$PRELUDE" "$RESOLVE"; do
  [ -e "$d" ] || { echo "elm-core-parity: missing $d (re-run tools/bench/fetch-elm-corpus.sh)"; exit 2; }
done
exec python3 - "$CORE" "$LIBS" "$PRELUDE" "$RESOLVE" "$@" <<'PY'
import os, re, sys

core_dir, libs_dir, prelude_f, resolve_f = sys.argv[1:5]
show_missing = '--missing' in sys.argv[5:]

def module_header(text):
    """(module name, [exposed names]) for an Elm module, or (None, [])."""
    m = re.search(r'^(?:port\s+|effect\s+)?module\s+([\w.]+)\s+exposing\s*\(', text, re.M)
    if not m:
        return None, []
    i = m.end() - 1          # at the '('
    depth = 0
    start = i
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return m.group(1), split_exposed(text[start + 1:i])

def split_exposed(body):
    """Split an exposing list on top-level commas; keep the name/keyword token."""
    out, depth, cur = [], 0, ''
    for ch in body:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    names = []
    for item in out:
        item = item.strip()
        if not item:
            continue
        # `Type(..)` / `Type(A, B)` -> Type ; `(|=)` -> |=
        if item.startswith('('):
            names.append(item.replace(' ', ''))
        else:
            names.append(re.split(r'\(', item)[0].strip())
    if '..' in names:
        names.remove('..')
    return names

def scan_dir(root):
    mods = {}
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if not f.endswith('.elm'):
                continue
            p = os.path.join(dirpath, f)
            name, exposed = module_header(open(p, encoding='utf-8', errors='replace').read())
            if name:
                mods[name] = (os.path.relpath(p, root), exposed)
    return mods

core = scan_dir(core_dir)
libs = scan_dir(libs_dir)

# Row 3: the dotted alias rows — every `( "Mod.name", ...` key in Resolve.elm.
dotted = set()
for line in open(resolve_f, encoding='utf-8'):
    for m in re.finditer(r'\(\s*"([A-Z][\w.]*\.[\w]+)"\s*,', line):
        dotted.add(m.group(1))
    for m in re.finditer(r"dottedRows \"\w+\.\"", line):
        pass
# dottedRows "List." [ ("map","map"), ... ] — the prefix carries the module name.
for chunk in re.finditer(r'dottedRows\s+"([\w.]*\.)"\s*\[(.*?)\]', open(resolve_f, encoding='utf-8').read(), re.S):
    for m in re.finditer(r'\(\s*"([\w]+)"\s*,', chunk.group(2)):
        dotted.add(chunk.group(1) + m.group(1))

# Row 2: the implicit-prelude bare names (Prelude's own exposing list).  Every
# unit gets these in scope without importing anything, so a bare name counts as
# served exactly like a dotted row does.
_, prelude_bare = module_header(open(prelude_f, encoding='utf-8').read())
prelude_bare = set(prelude_bare)

# Row 4 (implied): the OPERATOR surface.  The expression parser carries a FIXED
# precedence table (src/Elm/Parser/Expression.elm), so `(+)`/`(::)`/`(++)`...
# are in scope in every module with no table row anywhere.
expr_f = 'osier-compiler/src/Elm/Parser/Expression.elm'
ops = set()
if os.path.exists(expr_f):
    for m in re.finditer(r'infix(?:Left|Right|NonAssociative)\s+\d+\s+"([^"]+)"',
                         open(expr_f, encoding='utf-8').read()):
        ops.add(m.group(1))

# Types are a NAME too: elm/core re-exports the builtin value types (Int, Char,
# String, ...) plus the three Prelude ADTs.  A package naming one of these needs
# no module at all — src/Type/Env.elm's qualifyTypeName spells them bare.
BUILTIN_TYPES = {'Int', 'Float', 'Bool', 'Char', 'String', 'List', 'Never',
                 'Maybe', 'Result', 'Order', '()'}

def why_served(mod, name):
    """None, or HOW the name is reachable.

    'operator' / 'dotted' / 'type'  -> the QUALIFIED spelling `Mod.name` works.
    'bare'                          -> only the UNQUALIFIED spelling works, via the
                                       implicit prelude.  A package doing
                                       `import String exposing (isEmpty)` gets the
                                       alias row ("isEmpty" -> "String.isEmpty"),
                                       which does NOT exist: bare-prelude serving
                                       is a partial serve and is counted as a gap
                                       for the qualified form.
    """
    if name.startswith('(') and name[1:-1] in ops:
        return 'operator'
    if name in BUILTIN_TYPES:
        return 'type'
    if (mod + '.' + name) in dotted:
        return 'dotted'
    if name in prelude_bare:
        return 'bare'
    return None

def qualified_served(mod, name):
    return why_served(mod, name) in ('operator', 'dotted', 'type')

print("elm/core 1.0.5  vs  osier-compiler/core-libs + src/Prelude.elm + Lower/Resolve.elm dotted rows")
print("=" * 100)
print("%-14s %-22s %5s %5s %5s %5s  %s" % ("elm/core mod", "osier home", "names", "same", "miss", "extra", "status"))

total_names = covered = 0
absent_rows, diff_rows = [], []
for mod in sorted(core):
    path, exposed = core[mod]
    total_names += len(exposed)
    if mod in libs:
        lib_path, lib_exposed = libs[mod]
        ks = set(exposed)
        ls = set(lib_exposed)
        same = ks & ls
        miss = ks - ls
        extra = ls - ks
        covered += len(same)
        total_names -= 0
        print("%-14s %-22s %5d %5d %5d %5d  PRESENT" % (mod, 'core-libs/' + os.path.basename(lib_path), len(exposed), len(same), len(miss), len(extra)))
        if miss or extra:
            diff_rows.append((mod, sorted(miss), sorted(extra)))
    else:
        via = [n for n in exposed if qualified_served(mod, n)]
        bare = [n for n in exposed if why_served(mod, n) == 'bare']
        if via and len(via) == len(exposed):
            status = 'ABSENT (all names via dotted rows/types)'
        elif via:
            status = 'ABSENT (%d/%d reachable qualified, %d bare-only)' % (len(via), len(exposed), len(bare))
        elif bare:
            status = 'ABSENT (bare-only: %d names, qualified spelling absent)' % len(bare)
        else:
            status = 'ABSENT (nothing serves it)'
        covered += len(via)
        print("%-14s %-22s %5d %5d %5d %5d  %s" % (mod, '-', len(exposed), len(via), len(exposed) - len(via), 0, status))
        absent_rows.append((mod, exposed, via))

print("-" * 100)
print("TOTALS: elm/core modules %d, same-name modules in core-libs %d (%s)"
      % (len(core), len([m for m in core if m in libs]), ', '.join(sorted(m for m in core if m in libs))))
print("        elm/core exposed names %d, reachable QUALIFIED (module/dotted row/type/operator) %d, NOT %d (%.1f%% coverage)"
      % (total_names, covered, total_names - covered, 100.0 * covered / max(1, total_names)))
print("        core-libs modules with no elm/core counterpart: %s"
      % (', '.join(sorted(m for m in libs if m not in core)) or '(none)'))
print("        dotted alias rows in Lower/Resolve.elm serving elm/core names: %d" % len(dotted))

# (c2) CROSS-MODULE RESIDENCE — the "renamed" half of the brief's question.
# For each elm/core module that has no same-name counterpart, the BEST-MATCH
# Osier home by exposed-name overlap, with its ratio.  A ratio that is high is
# the measurement of a RENAME (Elm.JsArray -> JsArray; String -> the implicit
# Prelude for the list-shaped half); a low one is just shared vocabulary
# (`map` exists on six modules and proves nothing).
homes = dict(libs)
homes['Prelude(src)'] = (prelude_f, sorted(prelude_bare))
print("\nCROSS-MODULE RESIDENCE (best same-name overlaps per absent module, >=3 names;")
print("the names are matched by SPELLING only, so read the list: Prelude.map is the")
print("LIST map and is NOT String.map)")
for mod in sorted(core):
    if mod in libs:
        continue
    _path, exposed = core[mod]
    best = []
    for home in sorted(homes):
        if home == mod:
            continue
        overlap = sorted(set(exposed) & set(homes[home][1]))
        if len(overlap) >= 3:
            best.append((len(overlap) / float(max(1, len(exposed))), home, overlap))
    if not best:
        print("  %-14s (nothing)" % mod)
        continue
    best.sort(key=lambda t: -t[0])
    for ratio, home, overlap in best[:2]:
        print("  %-14s %-14s %3d/%d = %3.0f%% %s  %s"
              % (mod, home, len(overlap), len(exposed), 100 * ratio,
                 'RENAMED' if ratio >= 0.20 else 'vocabulary', overlap))

if show_missing:
    print("\nEXPOSED-NAME DIFFS (modules on both sides)")
    for mod, miss, extra in diff_rows:
        print("  %s: missing %s%s" % (mod, miss or '[]', ('  extra ' + str(extra)) if extra else ''))
    print("\nABSENT MODULES, name by name")
    for mod, exposed, via in absent_rows:
        gaps = [n for n in exposed if n not in via]
        print("  %s: served %s" % (mod, via))
        if gaps:
            print("  %s: GAP %s" % (mod, gaps))
PY
