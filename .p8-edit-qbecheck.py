#!/usr/bin/env python3
"""Strip the VM-consuming FREEZE mode from tools/qbe/qbe-check.sh (P8 batch 2)."""
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
def cut(a, b):
    global s, n
    i = s.index(a); j = s.index(b); assert i < j
    s = s[:i] + s[j:]; n += 1

# run(): the FREEZE reference block
sub("""  local exp
  if [ "$FREEZE" = 1 ]; then
    # The differential's LAST RUN, recorded: the VM reference compiles the
    # same source (MIDTIER=0 -> csexp) and runs the same entry; a golden is
    # written ONLY where native and VM agree byte-for-byte.
    [ -x "$ROOT/zig-out/bin/elmvm" ] || {
      echo "qbe-check: freeze mode needs zig-out/bin/elmvm (the VM reference)" >&2
      exit 2
    }
    (cd "$ROOT/elm-compiler" &&
      MIDTIER=0 node run.js "$ROOT/$fixture" "$TMP/$name/ref.csexp") >/dev/null 2>&1
    local vm_out
    vm_out="$("$ROOT/zig-out/bin/elmvm" "$TMP/$name/ref.csexp" "$entry" "${args[@]}" 2>&1)"
  fi
  local nat_out
  # `timeout` guards the native run: bug-2 (clostail) is an infinite loop
  # when the closure self-tail miscompiles, and a regression must fail loudly
  # here rather than wedge the whole check script.
  nat_out="$(timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)"

  if [ "$FREEZE" = 1 ]; then
    if [ "$vm_out" != "$nat_out" ]; then
      echo "FAIL $name: FREEZE REFUSED — vm='$vm_out' native='$nat_out' (no golden written)"
      FAIL=1; return
    fi
    mkdir -p "$GOLDEN"
    printf '%s\\n' "$nat_out" > "$GOLDEN/$name.txt"
    echo "FROZE $name: golden <- vm==native (${nat_out:0:60})"
    exp="$nat_out"
  else
    exp="$(golden_read "$name")"
    if [ "$exp" = "__NO_GOLDEN__" ]; then
      echo "FAIL $name: no golden at $GOLDEN/$name.txt (freeze deliberately: QBE_CHECK_FREEZE=1)"
      FAIL=1; return
    fi
  fi""",
"""  local exp
  # `timeout` guards the native run: bug-2 (clostail) is an infinite loop
  # when the closure self-tail miscompiles, and a regression must fail loudly
  # here rather than wedge the whole check script.
  local nat_out
  nat_out="$(timeout 60 "$bin" "$entry" "${args[@]}" 2>&1)"
  exp="$(golden_read "$name")"
  if [ "$exp" = "__NO_GOLDEN__" ]; then
    echo "FAIL $name: no golden at $GOLDEN/$name.txt (a golden is frozen deliberately, in a commit that says why)"
    FAIL=1; return
  fi""")

open(p,'w').write(s)
print(f"part1 OK: {n}")
