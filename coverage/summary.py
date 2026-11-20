#!/usr/bin/env python3
"""summary.py AGGREGATE.info [DEPTH]: line, function and branch coverage
from an LCOV file, totalled per directory.

Paths are as tcgcov wrote them, relative to the source root (work/src):
gcc/libgcc/..., newlib/newlib/libc/..., newlib/libgloss/....  Files are
grouped by their first DEPTH directory components (default 4), so
newlib/newlib/libc/stdio and gcc/libgcc/config/riscv come out separately.
"""
import collections
import sys


def group(path, depth):
    parts = path.split("/")
    return "/".join(parts[:min(depth, len(parts) - 1)]) or "."


def main():
    info = sys.argv[1]
    depth = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    tot = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0])  # lf lh fnf fnh brf brh
    path = None
    with open(info) as f:
        for line in f:
            line = line.strip()
            if line.startswith("SF:"):
                path = line[3:]
                t = tot[group(path, depth)]
            elif line.startswith("DA:"):
                t[0] += 1
                if int(line[3:].split(",")[1]) > 0:
                    t[1] += 1
            elif line.startswith("FNDA:"):
                t[2] += 1
                if int(line[5:].split(",")[0]) > 0:
                    t[3] += 1
            elif line.startswith("BRDA:"):
                t[4] += 1
                taken = line[5:].split(",")[3]
                if taken not in ("-", "0"):
                    t[5] += 1

    def pct(h, n):
        return f"{100.0 * h / n:5.1f}%" if n else "    -"

    rows = sorted(tot.items())
    w = max([len(k) for k, _ in rows] + [9])
    print(f"{'directory':<{w}}  {'lines':>15}  {'functions':>13}  {'branches':>15}")
    g = [0] * 6
    for k, t in rows:
        g = [a + b for a, b in zip(g, t)]
        print(f"{k:<{w}}  {t[1]:>6}/{t[0]:<6}{pct(t[1], t[0])}"
              f"  {t[3]:>5}/{t[2]:<5}{pct(t[3], t[2])}"
              f"  {t[5]:>6}/{t[4]:<6}{pct(t[5], t[4])}")
    print(f"{'total':<{w}}  {g[1]:>6}/{g[0]:<6}{pct(g[1], g[0])}"
          f"  {g[3]:>5}/{g[2]:<5}{pct(g[3], g[2])}"
          f"  {g[5]:>6}/{g[4]:<6}{pct(g[5], g[4])}")


if __name__ == "__main__":
    main()
