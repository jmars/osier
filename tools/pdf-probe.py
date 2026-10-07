#!/usr/bin/env python3
"""Read facts out of a PDF's bytes, with no external PDF tools.

This host has no poppler, qpdf, mutool, gs or pdftk, and the PDFs are written
with compressed object streams, so both the page count and the text have to
come out of the bytes directly.  Nothing here is a proxy for the PDF: the page
count is the page tree's own /Count (cross-checked against the number of page
objects) and the text is the real content streams decoded through each font's
ToUnicode CMap.

Modes:
    pages <pdf>                 print the page count
    text  <pdf>                 print the extracted text
    check <pdf> <needle>...     fail unless every needle is present
                                (needles are matched with whitespace ignored,
                                so they are also found when the writer emits
                                inter-word space as a positioning offset)
    absent <pdf> <needle>...    fail if any needle is present, same matching

Every mode exits nonzero when it cannot answer, rather than printing nothing:
an instrument that cannot say "I do not know" will say something else instead.
"""
import re
import sys
import zlib


# --------------------------------------------------------------- PDF objects
def inflate(chunk):
    try:
        return zlib.decompress(chunk)
    except zlib.error:
        try:
            return zlib.decompressobj().decompress(chunk)
        except zlib.error:
            return None


def stream_of(body):
    """The (inflated) stream of an object body, or None."""
    m = re.search(rb"stream\r\n|stream\n", body)
    if not m:
        return None
    raw = body[m.end():body.rfind(b"endstream")]
    if b"/FlateDecode" in body[:m.start()]:
        return inflate(raw)
    return raw


def objects(data):
    """Every indirect object, including those held in object streams."""
    objs = {}
    for m in re.finditer(rb"(?<![0-9])(\d+)\s+(\d+)\s+obj\b", data):
        end = data.find(b"endobj", m.end())
        objs[int(m.group(1))] = data[m.end():end if end > 0 else len(data)]
    for num, body in list(objs.items()):
        if b"/ObjStm" not in body:
            continue
        s = stream_of(body)
        if s is None:
            continue
        first = re.search(rb"/First\s+(\d+)", body)
        count = re.search(rb"/N\s+(\d+)", body)
        if not (first and count):
            continue
        header = s[:int(first.group(1))].split()
        pairs = [(int(header[i]), int(header[i + 1]))
                 for i in range(0, 2 * int(count.group(1)), 2)]
        for i, (objnum, off) in enumerate(pairs):
            start = int(first.group(1)) + off
            stop = (int(first.group(1)) + pairs[i + 1][1]
                    if i + 1 < len(pairs) else len(s))
            objs[objnum] = s[start:stop]
    return objs


def resolve(objs, ref):
    return objs.get(int(ref)) if ref else None


def page_tree(objs):
    """(root page-tree object number, page object numbers in page order)."""
    catalog = next((b for b in objs.values() if b"/Type/Catalog" in b
                    or b"/Type /Catalog" in b), None)
    if catalog is None:
        sys.exit("pdf-probe: no /Type/Catalog in the document")
    m = re.search(rb"/Pages\s+(\d+)\s+\d+\s+R", catalog)
    if not m:
        sys.exit("pdf-probe: catalog has no /Pages")
    root, seen, order = int(m.group(1)), set(), []

    def walk(num):
        if num in seen:
            return
        seen.add(num)
        body = objs.get(num)
        if body is None:
            sys.exit("pdf-probe: dangling page-tree reference %d" % num)
        kids = re.search(rb"/Kids\s*\[(.*?)\]", body, re.DOTALL)
        if kids:
            for k in re.finditer(rb"(\d+)\s+\d+\s+R", kids.group(1)):
                walk(int(k.group(1)))
        elif b"/Type/Page" in body or b"/Type /Page" in body:
            order.append(num)

    walk(root)
    return root, order


def page_objects(objs):
    return [objs[n] for n in page_tree(objs)[1]]


# ---------------------------------------------------------------- text decoding
def to_unicode_map(objs, font_body):
    m = re.search(rb"/ToUnicode\s+(\d+)\s+\d+\s+R", font_body)
    cmap = dict()
    if not m:
        return cmap
    s = stream_of(resolve(objs, m.group(1)) or b"")
    if s is None:
        return cmap
    text = s.decode("latin-1")
    for block in re.findall(r"beginbfchar(.*?)endbfchar", text, re.DOTALL):
        for src, dst in re.findall(r"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", block):
            cmap[int(src, 16)] = decode_utf16(dst)
    for block in re.findall(r"beginbfrange(.*?)endbfrange", text, re.DOTALL):
        for lo, hi, rest in re.findall(
                r"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]+>|\[.*?\])",
                block, re.DOTALL):
            lo_i, hi_i = int(lo, 16), int(hi, 16)
            if rest.startswith("["):
                for i, dst in enumerate(re.findall(r"<([0-9A-Fa-f]+)>", rest)):
                    cmap[lo_i + i] = decode_utf16(dst)
            else:
                base = int(rest[1:-1], 16)
                for i in range(hi_i - lo_i + 1):
                    cmap[lo_i + i] = decode_utf16("%04X" % (base + i))
    return cmap


def decode_utf16(hexstr):
    b = bytes.fromhex(hexstr if len(hexstr) % 2 == 0 else "0" + hexstr)
    try:
        return b.decode("utf-16-be")
    except UnicodeDecodeError:
        return ""


def unescape(lit):
    out, i = bytearray(), 0
    while i < len(lit):
        c = lit[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        i += 1
        if i >= len(lit):
            break
        e = lit[i]
        simple = {0x6E: 10, 0x72: 13, 0x74: 9, 0x62: 8, 0x66: 12}
        if e in simple:
            out.append(simple[e])
            i += 1
        elif 0x30 <= e <= 0x37:
            j = i
            while j < len(lit) and j < i + 3 and 0x30 <= lit[j] <= 0x37:
                j += 1
            out.append(int(lit[i:j], 8) & 0xFF)
            i = j
        else:
            out.append(e)
            i += 1
    return bytes(out)


def page_fonts(objs, page):
    res = page
    m = re.search(rb"/Resources\s+(\d+)\s+\d+\s+R", page)
    if m:
        res = resolve(objs, m.group(1)) or page
    fonts = {}
    fm = re.search(rb"/Font\s*<<(.*?)>>", res, re.DOTALL)
    if not fm:
        fm = re.search(rb"/Font\s+(\d+)\s+\d+\s+R", res)
        if fm:
            fd = resolve(objs, fm.group(1)) or b""
            fm = re.search(rb"<<(.*)>>", fd, re.DOTALL)
    if fm:
        for name, num in re.findall(rb"/([A-Za-z0-9]+)\s+(\d+)\s+\d+\s+R", fm.group(1)):
            body = resolve(objs, num) or b""
            fonts[name.decode()] = to_unicode_map(objs, body)
    return fonts


def page_text(objs, page):
    refs = []
    m = re.search(rb"/Contents\s+(\d+)\s+\d+\s+R", page)
    if m:
        refs = [m.group(1)]
    else:
        m = re.search(rb"/Contents\s*\[(.*?)\]", page, re.DOTALL)
        if m:
            refs = re.findall(rb"(\d+)\s+\d+\s+R", m.group(1))
    fonts = page_fonts(objs, page)
    out = []
    for ref in refs:
        s = stream_of(resolve(objs, ref) or b"")
        if s is None:
            continue
        out.append(decode_content(s.decode("latin-1"), fonts))
    return "\n".join(out)


TOKEN = re.compile(r"/([A-Za-z0-9]+)\s+[-\d.]+\s+Tf|\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>|\[[^\]]*\]|'|\"|TJ|Tj")


def decode_content(content, fonts):
    cur, chunks = None, []
    for m in TOKEN.finditer(content):
        tok = m.group(0)
        if tok.endswith("Tf"):
            cur = fonts.get(m.group(1), {})
        elif tok.startswith("(") or tok.startswith("<"):
            chunks.append(show(tok, cur))
        elif tok.startswith("["):
            for inner in re.finditer(
                    r"\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>|-?\d+(?:\.\d+)?", tok):
                s = inner.group(0)
                if s.startswith("(") or s.startswith("<"):
                    chunks.append(show(s, cur))
                elif float(s) < -180:      # a gap wide enough to be a word break
                    chunks.append(" ")
        elif tok in ("'", '"'):
            chunks.append("\n")
    return "".join(chunks)


def show(tok, cmap):
    if tok.startswith("("):
        raw = unescape(tok[1:-1].encode("latin-1"))
    else:
        hexstr = re.sub(r"\s", "", tok[1:-1])
        if len(hexstr) % 2:
            hexstr += "0"
        raw = bytes.fromhex(hexstr)
    if not cmap:
        return raw.decode("latin-1")
    out = []
    for i in range(0, len(raw) - 1, 2):
        out.append(cmap.get((raw[i] << 8) | raw[i + 1], ""))
    return "".join(out)


# ---------------------------------------------------------------- the interface
def main():
    mode, path = sys.argv[1], sys.argv[2]

    data = open(path, "rb").read()
    if mode == "pages":
        objs = objects(data)
        root, order = page_tree(objs)
        # The page-tree root's own /Count is the document's own answer; the
        # number of page objects is the independent one.  (The outline tree
        # carries a /Count too, which is why neither is read by regex over the
        # whole file.)
        m = re.search(rb"/Count\s+(\d+)", objs.get(root, b""))
        if not m:
            sys.exit("pdf-probe: the page-tree root has no /Count")
        counted = int(m.group(1))
        if counted != len(order):
            sys.exit("pdf-probe: page tree says %d pages, %d page objects"
                     % (counted, len(order)))
        if counted == 0:
            sys.exit("pdf-probe: zero pages")
        print(counted)
        return

    objs = objects(data)
    pages = page_objects(objs)
    texts = [page_text(objs, p) for p in pages]
    if mode == "text":
        print("\n\f\n".join(texts))
        return
    if mode == "page-of":
        needle = re.sub(r"\s+", "", sys.argv[3])
        hits = [i + 1 for i, t in enumerate(texts)
                if needle in re.sub(r"\s+", "", t)]
        if len(hits) != 1:
            sys.exit("pdf-probe: %r on %d pages (%s), expected exactly one"
                     % (sys.argv[3], len(hits), ", ".join(map(str, hits))))
        print(hits[0])
        return
    if mode not in ("check", "absent"):
        sys.exit("pdf-probe: unknown mode %r" % mode)

    if len("".join(texts)) < 2000:
        sys.exit("pdf-probe: extracted only %d characters from %s -- the decoder "
                 "is not reading this document, so a clean result would be "
                 "no evidence" % (len("".join(texts)), path))
    flat = re.sub(r"\s+", "", "\n".join(texts))
    bad = []
    for needle in sys.argv[3:]:
        hit = re.sub(r"\s+", "", needle) in flat
        if (mode == "check") != hit:
            bad.append(needle)
    if mode == "check":
        print("check: %d needles, %d present%s"
              % (len(sys.argv[3:]), len(sys.argv[3:]) - len(bad),
                 "" if not bad else " -- MISSING: " + ", ".join(repr(b) for b in bad)))
    else:
        print("absent: %d needles, %d absent%s"
              % (len(sys.argv[3:]), len(sys.argv[3:]) - len(bad),
                 "" if not bad else " -- PRESENT: " + ", ".join(repr(b) for b in bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
