#!/usr/bin/env python3
"""Strip the VM-consuming FREEZE mode from qbe-check.sh — parts 2 and 3."""
import sys
p = 'tools/qbe/qbe-check.sh'
s = open(p).read()
n = 0
def sub(old, new, count=1):
    global s, n
    c = s.count(old)
    if c != count:
        print(f"MISMATCH ({c} != {count}) for: {old[:100]!r}"); sys.exit(1)
    s = s.replace(old, new); n += 1

# ---------- run_argv ----------
sub("""  if [ "$FREEZE" = 1 ]; then
    [ -x "$ROOT/zig-out/bin/elmvm" ] || {
      echo "qbe-check: freeze mode needs zig-out/bin/elmvm (the VM reference)" >&2
      exit 2
    }
    (cd "$ROOT/elm-compiler" &&
      MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1
  fi
  local nat_out exp
  nat_out="$(timeout 60 env AOTRUN_ARGV=1 "$bin" "$entry" "${args[@]}" 2>&1)"
  if [ "$FREEZE" = 1 ]; then
    local vm_out
    vm_out="$(AOTRUN_ARGV=1 "$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" "${args[@]}" 2>&1)"
    if [ "$vm_out" != "$nat_out" ]; then
      echo "FAIL $name: FREEZE REFUSED — vm='$vm_out' native='$nat_out'"
      FAIL=1; return
    fi
    mkdir -p "$GOLDEN"
    printf '%s\\n' "$nat_out" > "$GOLDEN/$name.txt"
    echo "FROZE $name: golden <- vm==native (${nat_out:0:60})"
    exp="$nat_out"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi""",
"""  local nat_out exp
  nat_out="$(timeout 60 env AOTRUN_ARGV=1 "$bin" "$entry" "${args[@]}" 2>&1)"
  exp="$(golden_read "$name")"
  if [ "$exp" = "__NO_GOLDEN__" ]; then
    echo "FAIL $name: no golden at $GOLDEN/$name.txt"
    FAIL=1; return
  fi""")

# ---------- run_io ----------
sub("""  local exp=""
  if [ "$FREEZE" = 1 ]; then
    [ -x "$ROOT/zig-out/bin/elmvm" ] || {
      echo "qbe-check: freeze mode needs zig-out/bin/elmvm (the VM reference)" >&2
      exit 2
    }
    (cd "$ROOT/elm-compiler" &&
      MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1
  fi

  rm -f "$IO_OUT"
  local nat_out nat_file
  nat_out="$(timeout 60 env QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)"
  nat_file="$(cat "$IO_OUT" 2>/dev/null)"
  if [ "$FREEZE" = 1 ]; then
    local vm_out vm_file
    rm -f "$IO_OUT"
    vm_out="$(QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" 2>&1)"
    vm_file="$(cat "$IO_OUT" 2>/dev/null)"
    rm -f "$IO_OUT"
    if [ "$vm_out" != "$nat_out" ] || [ "$vm_file" != "$nat_file" ]; then
      echo "FAIL $name: FREEZE REFUSED — vm='$vm_out'/'$vm_file' native='$nat_out'/'$nat_file'"
      FAIL=1; return
    fi
    mkdir -p "$GOLDEN"
    printf '%s\\n' "$nat_out" > "$GOLDEN/$name.txt"
    echo "FROZE $name: golden <- vm==native (${nat_out:0:60})"
    exp="$nat_out"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt"
      FAIL=1; return
    fi
  fi""",
"""  local exp=""
  rm -f "$IO_OUT"
  local nat_out nat_file
  nat_out="$(timeout 60 env QBE_IO_IN="$IO_IN" QBE_IO_OUT="$IO_OUT" "$bin" "$entry" 2>&1)"
  nat_file="$(cat "$IO_OUT" 2>/dev/null)"
  exp="$(golden_read "$name")"
  if [ "$exp" = "__NO_GOLDEN__" ]; then
    echo "FAIL $name: no golden at $GOLDEN/$name.txt"
    FAIL=1; return
  fi""")

# ---------- the FREEZE env var + header prose ----------
sub("""GOLDEN="$ROOT/tools/qbe/golden"
FREEZE="${QBE_CHECK_FREEZE:-0}\"""",
"""GOLDEN="$ROOT/tools/qbe/golden\"""")

sub("""# elmvm is NOT a prerequisite anymore — compare mode never
# runs it; freeze mode checks for it itself.""",
"""# elmvm is gone entirely (P8 deleted the interpreter); nothing here runs a VM.""")

sub("""# FREEZING.  A golden is (re)frozen ON PURPOSE:
#     QBE_CHECK_FREEZE=1 tools/qbe/qbe-check.sh
# runs the OLD differential one more time (VM reference and all) and writes a
# golden ONLY where native and VM agree — then commits deserve a message that
# says what moved and why (the corpus-baseline 8da6fd7 discipline).  A missing
# golden in compare mode is a FAIL, never an auto-freeze.""",
"""# FREEZING.  The goldens are committed files (tools/qbe/golden/*.txt);
# re-freezing one is a deliberate edit of that file plus a commit message
# that says what moved and why (the corpus-baseline 8da6fd7 discipline).
# The freeze-from-VM mode that wrote them originally died with the
# interpreter at P8 — a golden no longer has a second engine to agree with,
# which is the recorded loss the header above states.""")

sub("""# golden_read <name>: the pinned expected stdout for a row.  In freeze mode
# the golden does not exist yet on a first freeze — echo a sentinel the caller
# replaces; in compare mode a MISSING golden is a FAIL (never an auto-freeze:
# a check that heals itself is not a check).""",
"""# golden_read <name>: the pinned expected stdout for a row.  A MISSING golden
# is a FAIL (never an auto-freeze: a check that heals itself is not a check).""")

open(p,'w').write(s)
print(f"OK: {n} edits")
