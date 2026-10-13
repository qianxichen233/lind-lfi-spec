#!/usr/bin/env python3
"""numdiff.py A B: exit 0 if the files are the same except that numbers may differ by a
relative 1e-4 (SPEC's own output comparison is tolerance-based; libm/compiler differences
move the last digits)."""
import re, sys
num = re.compile(r'[-+]?\d+\.?\d*(?:[eE][-+]?\d+)?')
a, b = open(sys.argv[1], 'rb').read().decode('latin1'), open(sys.argv[2], 'rb').read().decode('latin1')
if a == b: sys.exit(0)
la, lb = a.splitlines(), b.splitlines()
if len(la) != len(lb): sys.exit(1)
for x, y in zip(la, lb):
    if x == y: continue
    if num.sub('#', x) != num.sub('#', y): sys.exit(1)
    for u, v in zip(num.findall(x), num.findall(y)):
        u, v = float(u), float(v)
        if abs(u - v) > 1e-4 * max(abs(u), abs(v), 1e-30) and abs(u - v) > 0.011: sys.exit(1)
sys.exit(0)
