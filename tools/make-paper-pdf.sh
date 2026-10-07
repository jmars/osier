#!/usr/bin/env bash
#
# make-paper-pdf.sh — build BOTH PDFs of the paper from source, with the REAL
# ACM `acmart` class in its `acmsmall` (single-column, 10pt) form.
#
#   readable variant   docs/research/withe-paper.md
#                        -> docs/research/build/withe-paper.tex
#                        -> docs/research/build/withe-paper.pdf
#
#   anonymized         docs/research/submission/withe-paper-submission.md
#   submission         (re-derived from the source paper first, by
#                       tools/make-submission.sh, which self-verifies)
#                        -> docs/research/build/withe-paper-submission.tex
#                        -> docs/research/build/withe-paper-submission.pdf
#
# The .tex of BOTH variants is committed, so a referee can read exactly what was
# typeset without running pandoc.  The PDFs, the TeX log and the intermediate
# files are build products and are git-ignored.
#
# Run it with:   bash tools/make-paper-pdf.sh
# It is re-runnable and idempotent: every product is regenerated from source.
#
# Toolchain: pandoc (markdown -> LaTeX) and tectonic (XeTeX + the TeX Live
# bundle, which resolves acmart.cls itself; no network is needed after the first
# run, which caches the bundle under ~/.cache/Tectonic).  No pdflatex/latexmk,
# no PDF utilities: the page count is read from the PDF bytes by
# tools/pdf-probe.py.
#
# What the conversion does NOT do: it never re-wraps, re-flows or edits the
# bytes of a fenced block, a table cell, a bibliography entry or any prose.
# The only per-block decision it makes is the FONT SIZE of a verbatim block --
# chosen, per block, as the largest size at which that block's widest line
# still fits \textwidth, so that the hand-drawn ASCII inference rules keep their
# alignment instead of running into the margin.  The size actually chosen for
# each block is printed as the build runs.
#
# Exit status is nonzero if the paper did not build cleanly: pandoc or tectonic
# failed, a required glyph is missing from the fonts, an overfull box remains,
# the conversion lost or altered any of the paper's text (fenced blocks, table
# rows, bibliography entries, URLs, title, headings, paragraphs), the PDF does
# not carry the text it should, or the anonymized variant would carry an
# identifying string in its .tex or its .pdf.  Defects in the paper's own
# markdown -- as opposed to defects in the conversion -- are printed and left
# alone.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=docs/research/build
PANDOC="${PANDOC:-pandoc}"
TECTONIC="${TECTONIC:-$HOME/.local/bin/tectonic}"
PROBE="$PWD/tools/pdf-probe.py"

mkdir -p "$BUILD"

# ---------------------------------------------------------------- pandoc glue
# A three-line template: the paper's H1 becomes the LaTeX title, everything
# else is the body, and the markers let the assembler below tell them apart
# (pandoc wraps template variables, so the title may run over several lines).
TEMPLATE="$BUILD/.pandoc-template.tex"
cat > "$TEMPLATE" <<'EOF'
%%PAPER-TITLE%%$title$
%%PAPER-BODY%%
$body$
EOF

# --------------------------------------------------------------- the assembler
# Reads pandoc's LaTeX output and emits a complete acmart document:
#   title -> \title, the "## Abstract" section -> the abstract environment,
#   everything else -> the body after \maketitle.
assemble() {  # $1 = pandoc output, $2 = destination .tex, $3 = variant label
  python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

raw, out, variant = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(raw, encoding="utf-8").read().split("\n")

# pandoc wraps its template variables at 72 columns, so the title can occupy
# more than one line; the second marker says where the body begins.
title_marker, body_marker = "%%PAPER-TITLE%%", "%%PAPER-BODY%%"
if not lines[0].startswith(title_marker) or body_marker not in lines:
    sys.exit("assemble: pandoc markers missing from %s" % raw)
split = lines.index(body_marker)
title = "\n".join(lines[:split])[len(title_marker):].strip()
body = lines[split + 1:]

HRULE = re.compile(r"^\s*\\begin\{center\}\\rule.*\\end\{center\}\s*$")


def index_of(pred, start):
    for i in range(start, len(body)):
        if pred(body[i]):
            return i
    sys.exit("assemble: expected heading not found in %s" % raw)


abs_i = index_of(lambda l: l.startswith("\\section{Abstract}"), 0)
sec_i = index_of(lambda l: l.startswith("\\section{"), abs_i + 1)


def clean(ls):
    # The "---" separators of the source come out of pandoc as centred rules;
    # they are dropped from the title note and the abstract (which the class
    # sets itself) and kept in the body.
    return "\n".join(l for l in ls if not HRULE.match(l)).strip("\n")


note = clean(body[:abs_i])
abstract = clean(body[abs_i + 1:sec_i])
rest = clean(body[sec_i:])

# Let the document report the page it is on when the bibliography starts.  This
# is the secondary reading: a heading that moves to the next page would be
# reported on the page it left, so the build reads the page back from the
# References label instead (see \AtEndDocument in the preamble below).
rest, nrefs = re.subn(r"(\\section\{References\}[^\n]*\n)",
                      lambda m: m.group(1) + "\\typeout{PAPER-REFS-PAGE: \\thepage}\n",
                      rest)
if nrefs != 1:
    sys.exit("assemble: expected exactly one References section, found %d" % nrefs)

# ------------------------------------------------- pandoc/acmart table fixup
# pandoc wraps every caption-less longtable in `{\def\LTcaptype{none} ...`,
# asking for a counter that must not be stepped.  Under acmart that is fatal --
# "No counter 'none' defined": the class hooks longtable's caption machinery
# through the caption package even when the table carries no \caption.  Dropping
# the def keeps the tables and lets longtable use its own default caption type.
rest = re.sub(r"\{\\def\\LTcaptype\{none\}\s*%(?: [^\n]*)?\n", "{\n", rest)

# ------------------------------------------------------------ verbatim sizing
# MEASURED on this toolchain (tectonic/XeTeX + acmart[acmsmall] + DejaVu Sans
# Mono, 10pt base): the advance of one monospace character, and \textwidth.
ADV = [
    ("normalsize", 6.020508),
    ("small", 5.418457),
    ("footnotesize", 4.816406),
    ("scriptsize", 4.214355),
    ("tiny", 3.612305),
]
TEXTWIDTH = 395.8225   # \textwidth
FALLBACK_ADV = 8.0     # widest of the fallback glyphs below, in DejaVu Sans
FALLBACK = set("\u2113\u20d7\u27fa")  # l-script, combining vector arrow, long iff

sizes = {}


def line_width(s, adv):
    n = sum(1 for c in s if c not in FALLBACK)
    return n * adv + (len(s) - n) * FALLBACK_ADV


def pick_size(block):
    for name, adv in ADV:
        if max((line_width(l, adv) for l in block.split("\n")), default=0) <= TEXTWIDTH - 1:
            return name
    return ADV[-1][0]


def wrap(m):
    block = m.group(1)
    size = pick_size(block)
    sizes[size] = sizes.get(size, 0) + 1
    return "{\\%s\\begin{verbatim}\n%s\n\\end{verbatim}}" % (size, block)


rest, nblocks = re.subn(r"\\begin\{verbatim\}\n(.*?)\n\\end\{verbatim\}",
                        wrap, rest, flags=re.DOTALL)
print("  verbatim blocks: %d, sized %s" % (
    nblocks, ", ".join("%s=%d" % kv for kv in sorted(sizes.items()))))

# ------------------------------------------------------------- line breaking
# Two kinds of unbreakable token run into the margin: inline code that is a
# path (tests/elm-fixtures/run-elm-gate.sh), a camelCase identifier
# (refinedTargetAliasedBy) or a bare URL.  \allowbreak{} inserts a zero-width
# break opportunity and prints nothing, so the text is untouched -- no hyphen,
# no space, no re-wrap.  (Verbatim is excluded: it is already wrapped.)
TEXT_BREAKS = re.compile(r"(?<=[/_.\-])(?!\\allowbreak)(?=.)")
CASE_BREAKS = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
URL_BREAKS = re.compile(r"(?<=[/_.\-?=&:@#,~])")
# A bare slash in prose (and in \texttt{...}/\texttt{...}) is as unbreakable as
# the tokens either side of it.
SLASH_BREAKS = re.compile(r"(?<=/)(?!\\allowbreak)(?=.)")
URL = re.compile(r"(?:https?|ftp)://(?:[A-Za-z0-9/\-._~?=&:@#+,;!*']|\\[_&%#]"
                 r"|\\textasciitilde )+")


def breakable(m):
    inner = TEXT_BREAKS.sub(r"\\allowbreak{}", m.group(1))
    inner = CASE_BREAKS.sub(r"\\allowbreak{}", inner)
    return "\\texttt{" + inner + "}"


def add_breakpoints(text):
    text = URL.sub(lambda m: URL_BREAKS.sub(r"\\allowbreak{}", m.group(0)), text)
    text = SLASH_BREAKS.sub(r"\\allowbreak{}", text)
    return re.sub(r"\\texttt\{((?:[^{}]|\{[^{}]*\})*)\}", breakable, text)


VERBATIM = re.compile(r"(\\begin\{verbatim\}.*?\\end\{verbatim\})", re.DOTALL)


def outside_verbatim(text):
    # Even indices of the split are the text between verbatim blocks; a print
    # statement inside a verbatim block is data, and must stay byte-identical.
    return "".join(p if i % 2 else add_breakpoints(p)
                   for i, p in enumerate(VERBATIM.split(text)))


note = outside_verbatim(note)
abstract = outside_verbatim(abstract)
rest = outside_verbatim(rest)


# --------------------------------------------------------------------- output
stem = out.rsplit("/", 1)[-1][:-4]

if variant == "paper":
    variant_label = "readable"
    source = "docs/research/withe-paper.md"
    class_options = "acmsmall,nonacm"
else:
    variant_label = "anonymized (double-blind) submission"
    source = ("the anonymized export of the source paper, re-derived by "
              "tools/make-submission.sh")
    class_options = "acmsmall,nonacm,anonymous"
    # The file's own name carries the repository tag, so the header must not
    # repeat it: this .tex travels to reviewers.
    stem = "this-file"

preamble = r"""%% --------------------------------------------------------------------------
%% The typeset source of the %(variant_label)s variant of the paper.
%% Generated by tools/make-paper-pdf.sh -- do not edit by hand; edit the
%% markdown paper and re-run the script.
%% Paper:   %(source)s
%% Compile: tectonic -X compile %(stem)s.tex   (acmart [acmsmall], XeTeX)
%% --------------------------------------------------------------------------
\documentclass[%(class_options)s]{acmart}

%% ---- support for pandoc's LaTeX output ------------------------------------
\providecommand{\tightlist}{\setlength{\itemsep}{0pt}\setlength{\parskip}{0pt}}
\usepackage{longtable,booktabs,array,calc}

%% ---- glyph coverage -------------------------------------------------------
%% acmart's acmsmall monospace font (Inconsolata) has no box-drawing, Greek,
%% mathematical or subscript glyphs, so the hand-drawn inference rules would
%% silently lose their rule lines.  DejaVu Sans Mono has all but four of the
%% characters the paper uses; those four come from DejaVu Sans, redefined here
%% as active characters so that they also expand inside verbatim.
\setmonofont{DejaVu Sans Mono}
\usepackage{newunicodechar}
\newfontfamily\glyphfallback{DejaVu Sans}
\newunicodechar{ℓ}{{\glyphfallback ℓ}}
\newunicodechar{⃗}{{\glyphfallback ⃗}}
\newunicodechar{⟺}{{\glyphfallback ⟺}}
\newunicodechar{≐}{{\glyphfallback ≐}}

%% ---- paragraphs -----------------------------------------------------------
%% A short paragraph built from long unbreakable tokens can end up with no
%% feasible line break at the default tolerance, and TeX then runs one line
%% into the margin.  A little emergency stretch gives it a way out; the
%% breakpoints added below are what keep those lines tight rather than loose.
\setlength{\emergencystretch}{2em}

\begin{document}
%% The markdown headings carry their own numbers ("## 1 Introduction"), so the
%% class must not number them a second time.
\setcounter{secnumdepth}{0}

\title{%(title)s}

\begin{abstract}
%(abstract)s
\end{abstract}

\maketitle

%(note)s

%(rest)s

\makeatletter
%% \r@references is {<section>}{<page>}{<title>}{<anchor>}{...}; take the page
%% and drop the rest rather than leave it in the log.
\def\paper@second#1#2#3\paper@end{#2}
\AtEndDocument{%%
  \typeout{PAPER-TOTAL-PAGES: \thepage}%%
  \typeout{PAPER-SECTION-COUNTER: \thesection}%%
  %% The bibliography's first page, read back from the label rather than from
  %% \thepage at the heading: a section heading that moves to the next page
  %% would otherwise be reported on the page it left.
  \ifcsname r@references\endcsname
    \protected@edef\paperrefspage{\expandafter\paper@second\r@references\paper@end}%%
    \typeout{PAPER-REFS-PAGE: \paperrefspage}%%
  \else
    \typeout{PAPER-REFS-PAGE: UNRESOLVED}%%
  \fi
}
\makeatother

\end{document}
""" % {
    "variant_label": variant_label,
    "source": source,
    "stem": stem,
    "class_options": class_options,
    "title": title,
    "abstract": abstract,
    "note": note,
    "rest": rest,
}

open(out, "w", encoding="utf-8").write(preamble)
PY
}

# ------------------------------------------------------------------- the build
build_variant() {  # $1 = markdown, $2 = stem, $3 = variant label
  local md=$1 stem=$2 variant=$3
  local tex="$BUILD/$stem.tex" raw="$BUILD/.$stem.pandoc.tex"
  local log="$BUILD/$stem.log"

  echo "== $stem ($variant)"
  echo "   source: $md"
  "$PANDOC" "$md" -f markdown -t latex --standalone \
      --shift-heading-level-by=-1 --syntax-highlighting=none \
      --template="$TEMPLATE" -o "$raw"
  assemble "$raw" "$tex" "$variant"

  # Anonymity is an assertion, not a hope: the submission .tex must not carry
  # any identifying string.  (tools/make-submission.sh already verified the
  # markdown; this checks that the conversion did not reintroduce one.)
  if [ "$variant" != paper ]; then
    local bad
    bad=$(grep -onE -i 'jmars|fixpoint|jaye|jaye\.ch|Jaye Marshall|github\.com/[a-z]+/withe|withe-[A-Za-z0-9._-]*' "$tex" || true)
    if [ -n "$bad" ]; then
      echo "FAIL: identifying string(s) in the anonymized .tex:" >&2
      echo "$bad" >&2
      exit 1
    fi
    echo "   anonymization: no identifying string in $tex"
  fi

  # tectonic's exit code is the gate; read it directly, never through a pipe.
  local rc=0
  "$TECTONIC" -X compile "$tex" --outdir "$BUILD" --keep-logs --print \
      > "$log" 2>&1 || rc=$?
  echo "   tectonic exit: $rc"
  if [ "$rc" != 0 ]; then
    tail -30 "$log" >&2
    echo "FAIL: tectonic failed on $tex (full log: $log)" >&2
    exit 1
  fi

  local missing overfull
  missing=$(grep -c 'Missing character' "$log" || true)
  overfull=$(grep -c 'Overfull \\hbox' "$log" || true)
  echo "   missing characters: $missing"
  echo "   overfull hboxes:    $overfull"
  if [ "$missing" != 0 ]; then
    grep -o 'Missing character: There is no [^ ]*' "$log" | sort -u >&2
    echo "FAIL: the fonts do not cover every character of $stem" >&2
    exit 1
  fi
  if [ "$overfull" != 0 ]; then
    # One paragraph is reported once per TeX pass; count distinct paragraphs.
    grep -o 'Overfull \\hbox ([0-9.]*pt too wide) in paragraph at lines [0-9]*--[0-9]*' "$log" \
        | sort -u >&2
    echo "FAIL: overfull boxes in $stem" >&2
    exit 1
  fi

  # ---------------------------------------------- fidelity: markdown -> .tex
  # The conversion is allowed to add typesetting instructions; it is not
  # allowed to change the paper.  Everything below is checked against the
  # source markdown, and every check fails the build rather than warning --
  # except the last one, which reports a defect *in the paper* (an unbalanced
  # emphasis marker) that this script must not fix.
  python3 - "$md" "$tex" <<'PYEOF'
import re
import sys

md_path, tex_path = sys.argv[1], sys.argv[2]
md = open(md_path, encoding="utf-8").read()
tex = open(tex_path, encoding="utf-8").read()
md = re.sub(r"<!--.*?-->", "", md, flags=re.DOTALL)


def die(msg):
    print("  STRUCTURAL CHECK FAILED: " + msg, file=sys.stderr)
    sys.exit(1)


# Normalisation for the text-presence checks below.  It removes *markup*, never
# content: LaTeX control sequences (on the .tex side only), braces, quotes,
# emphasis markers, dashes/ellipses and all whitespace.
STRIP = set("\\{}`'\"\u2018\u2019\u201c\u201d*~")


def norm(s, latex=False):
    if latex:
        for a, b in [("\\allowbreak{}", ""), ("\\textasciitilde", "~"),
                     ("\\textless{}", "<"), ("\\textgreater{}", ">"),
                     ("\\textbar{}", "|"), ("\\textquotesingle", "'"),
                     ("\\textbackslash{}", "\u00a4"), ("\\textbackslash", "\u00a4"),
                     ("\\ldots", "..."), ("\\dots", "..."), ("\\/", ""),
                     ("\\_", "_"), ("\\&", "&"), ("\\%", "%"), ("\\#", "#"),
                     ("\\$", "$")]:
            s = s.replace(a, b)
        s = s.replace("\\ ", " ")
        s = re.sub(r"\\[a-zA-Z]+\s*", "", s)
        s = s.replace("\u00a4", "\\")
    s = "".join(ch for ch in s if ch not in STRIP)
    s = s.replace("\u2026", "...")
    for dash in "\u2014\u2013":
        s = s.replace(dash, "-")
    return re.sub(r"\s+", "", re.sub(r"-{2,}", "-", s))


ntex = norm(tex, latex=True)
md_lines = md.split("\n")

# 1. every fenced block survives byte-identically (no reflow, no re-wrap)
fences, cur, inside = [], None, False
for line in md_lines:
    if line.startswith("```"):
        if not inside:
            cur, inside = [], True
        else:
            fences.append("\n".join(cur))
            inside = False
        continue
    if inside:
        cur.append(line)
bad = [i for i, b in enumerate(fences) if b not in tex]
if bad:
    die("fenced block(s) %s are not verbatim in the .tex" % bad)
print("  fenced blocks: %d, all byte-identical in the .tex" % len(fences))

# 2. every table keeps every data row
md_tables, cur = [], None
for line in md_lines + [""]:
    if line.startswith("|"):
        cur = (cur or []) + [line]
    elif cur:
        md_tables.append(cur[2:])
        cur = None
tex_rows = []
for block in re.finditer(r"\\begin\{longtable\}.*?\\end\{longtable\}", tex, re.DOTALL):
    body = block.group(0).split("endlastfoot")
    if len(body) > 1:
        tex_rows.append(sum(1 for l in body[1].split("\n") if l.rstrip().endswith("\\\\")))
md_rows = [len(t) for t in md_tables if len(t) > 0]
if md_rows != tex_rows:
    die("table rows differ: markdown %s, .tex %s" % (md_rows, tex_rows))
cells = []
for row in ("|".join(t) + "|" for t in md_tables):
    parts = [c.strip() for c in row.strip().strip("|").split("|")]
    if all(set(c) <= set("-: ") for c in parts):      # the header rule
        continue
    cells.extend(parts)
cell_missing = [c for c in cells if norm(c) and norm(c) not in ntex]
if cell_missing:
    die("table cell text lost in the .tex: %s" % cell_missing[:5])
print("  tables: %d, rows per table %s, all %d cells present (markdown and .tex agree)"
      % (len(md_rows), md_rows, len(cells)))

# 3. every bibliography entry survives (one \item per entry)
tail = md.split("\n## References\n", 1)
if len(tail) != 2:
    die("no '## References' section in the markdown")
entries = [l for l in tail[1].split("\n") if l.startswith("- **")]
tex_refs = tex.split("\\section{References}", 1)
if len(tex_refs) != 2:
    die("no References section in the .tex")
items = tex_refs[1].count("\\item")
if items != len(entries):
    die("bibliography entries: markdown %d, .tex %d" % (len(entries), items))
print("  bibliography entries: %d (markdown and .tex agree)" % items)

# 4. every URL survives
urls = re.findall(r"https?://[^\s)\]]+", md)
missing = [u for u in urls if norm(u) not in ntex]
if missing:
    die("URL(s) lost in the .tex: %s" % missing[:5])
print("  URLs: %d, all present in the .tex" % len(urls))

# 5. the ACM-required §6.7 AI-use disclosure is present
for needle in ["Provenance: AI assistance in building this artifact",
               "The ACM Policy on Authorship requires AI use that"]:
    if norm(needle) not in ntex:
        die("required text absent from the .tex: %r" % needle)
print("  \u00a76.7 AI-use disclosure: present")

# 6. nothing was dropped on the way: the title, every heading and every
#    paragraph of the markdown must be in the .tex.  (This is what caught the
#    title's second line being cut off: pandoc wraps template variables.)
blocks, cur, inside, start = [], [], False, 0
for i, line in enumerate(md_lines, 1):
    if line.startswith("```"):
        inside = not inside
        continue
    if inside:
        continue
    if line.strip() == "":
        if cur:
            blocks.append((start, cur))
            cur = []
        continue
    if line.startswith("|") or line.startswith("#") or line.strip() == "---":
        if cur:
            blocks.append((start, cur))
            cur = []
        continue
    if not cur:
        start = i
    cur.append(re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+", "", line))
if cur:
    blocks.append((start, cur))

title_line = next(l for l in md_lines if l.startswith("# "))
missing = []
if norm(title_line.lstrip("# ")) not in ntex:
    missing.append(("title", 1))
for i, line in enumerate(md_lines, 1):
    if re.match(r"^#{2,6} ", line) and norm(line.lstrip("# ")) not in ntex:
        missing.append(("heading", i))
for start, block in blocks:
    if norm(" ".join(block)) not in ntex:
        missing.append(("paragraph", start))
if missing:
    die("text in the markdown that is not in the .tex: %s"
        % ", ".join("%s at line %d" % m for m in missing[:10]))
print("  text: title + %d headings + %d paragraphs, all present in the .tex"
      % (sum(1 for l in md_lines if re.match(r"^#{2,6} ", l)), len(blocks)))

# 7. text defects in the paper itself: reported, never fixed.  An odd number of
#    emphasis markers in one markdown paragraph cannot pair up, so pandoc pairs
#    the odd one with the next italic run -- which then swallows text and shows
#    a literal marker.  The visible counterpart is an asterisk in the typeset
#    text (outside verbatim and outside inline code).
odd = [(start, " ".join(b).count("*") - 0) for start, b in blocks
       if re.sub(r"`[^`]*`", "", " ".join(b)).count("*") % 2]
outside = re.sub(r"\\begin\{verbatim\}.*?\\end\{verbatim\}", "", tex, flags=re.DOTALL)
texttt = re.compile(r"\\texttt\{")
stray = []
for i, line in enumerate(outside.split("\n"), 1):
    j, depth = 0, 0
    while True:
        m = texttt.search(line, j)
        if not m:
            break
        depth, k = 1, m.end()
        while k < len(line) and depth:
            if line[k] == "{":
                depth += 1
            elif line[k] == "}":
                depth -= 1
            k += 1
        line = line[:m.start()] + line[k:]
        j = m.start()
    line = re.sub(r"\*\s*\\real\{[^}]*\}", "", line)
    if "*" in line:
        stray.append((i, line.strip()[:80]))
for start, count in odd:
    print("  TEXT DEFECT (in the paper's markdown, not fixed): the paragraph at "
          "line %d of %s has an odd number of emphasis markers (%d), so pandoc "
          "pairs the odd one with the next one and italicises the wrong span."
          % (start, md_path, count))
for i, line in stray:
    print("  TEXT DEFECT SYMPTOM: a literal marker reaches the page at %s:%d -- %s"
          % (tex_path, i, line))
PYEOF

  # ---------------------------------------------- fidelity: the PDF itself
  local needles=()
  while IFS= read -r line; do needles+=("$line"); done < <(
      grep -oE 'https?://[^ )]+' "$md" | sort -u
      grep -oE '^\| `[^`]+`' "$md" | sed 's/^| `//; s/`$//'
      printf '%s\n' "Provenance: AI assistance in building this artifact"
      printf '%s\n' "The ACM Policy on Authorship requires AI use that"
  )
  python3 "$PROBE" check "$BUILD/$stem.pdf" "${needles[@]}"

  if [ "$variant" != paper ]; then
    python3 "$PROBE" absent "$BUILD/$stem.pdf" \
        jmars fixpoint jaye "jaye.ch" "Jaye Marshall" \
        withe-paper-artifact withe-artifact-eval
  fi

  # the log holds one such line per TeX pass; the last is the final pagination
  for key in PAPER-TOTAL-PAGES PAPER-REFS-PAGE PAPER-SECTION-COUNTER; do
    grep -o "^$key: [^ ]*" "$log" | tail -1 | sed 's/^/   /'
  done

  local pages total
  pages=$(python3 "$PROBE" pages "$BUILD/$stem.pdf")
  echo "   pages (PDF page tree): $pages"
  # \thepage late in the run reads one higher than the pages the PDF holds: the
  # final \clearpage advances the counter for a page that carries no material
  # and that the PDF writer does not write.  The page tree is authoritative
  # (and the folios printed in the PDF itself stop at $pages); the document's
  # own count is allowed that one page of slack, and no more.
  total=$(grep -o '^PAPER-TOTAL-PAGES: [0-9]*' "$log" | tail -1 | awk '{print $2}')
  if [ "$total" -lt "$pages" ] || [ "$total" -gt "$((pages + 1))" ]; then
    echo "FAIL: the document counts $total pages, the PDF page tree $pages" >&2
    exit 1
  fi
  if [ "$total" != "$pages" ]; then
    echo "   (\$\\thepage at \\end{document}: $total -- the counter's extra empty page)"
  fi
}

echo "== refreshing the anonymized export"
bash tools/make-submission.sh | tail -4

build_variant docs/research/withe-paper.md withe-paper paper
build_variant docs/research/submission/withe-paper-submission.md \
              withe-paper-submission submission

rm -f "$TEMPLATE" "$BUILD"/.*.pandoc.tex

echo
echo "== results"
echo "   (page counts are read from the PDF's own page tree; the page the"
echo "    bibliography starts on is read from the text of the PDF itself, and"
echo "    cross-checked against the label the document writes for its"
echo "    References heading -- a label page comes from the previous TeX pass,"
echo "    so a one-page disagreement is reported rather than hidden.)"
for stem in withe-paper withe-paper-submission; do
  log="$BUILD/$stem.log"
  pdf="$BUILD/$stem.pdf"
  pages=$(python3 "$PROBE" pages "$pdf")
  # the section head "REFERENCES" is printed on the bibliography's first page
  # (and, on this class, only there), so it locates the section's start.
  bib=$(python3 "$PROBE" page-of "$pdf" "REFERENCES")
  bib2=$(python3 "$PROBE" page-of "$pdf" "Provenance follows the companion survey")
  label=$(grep -o '^PAPER-REFS-PAGE: [0-9]*' "$log" | tail -1 | awk '{print $2}')
  [ "$bib" = "$bib2" ] || { echo "FAIL: $stem bibliography start: head p.$bib, text p.$bib2" >&2; exit 1; }
  echo "   $stem: $pages pages in total"
  echo "      bibliography starts on p. $bib (section head, and its first paragraph; the"
  echo "      LaTeX label for the heading reads p. $label)"
  echo "      => $((bib - 1)) pages excluding the bibliography (pages 1-$((bib - 1)))"
done
echo "   .tex committed; .pdf and .log are build products under $BUILD/"
