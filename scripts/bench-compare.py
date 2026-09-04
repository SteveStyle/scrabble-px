#!/usr/bin/env python3
"""Compare two per-move benchmark runs, excluding the hypervisor's outliers.

A percentile taken on a shared VM is not evidence about this code: on
2026-09-04 the VM's p99 was 12.9x the laptop's while its median was 1.6x, and
the difference was moves the hypervisor descheduled. Those moves are a
different set every run — four runs flagged 102 distinct moves between them and
exactly one in common — so they cannot be excluded by naming them. They are
excluded by pairing.

The games are seeded, so `(game, turn)` is the same position in both runs. A
move whose ratio between the two machines is far above the machine's own factor
did not become harder; it waited. The cut is not chosen: the per-move ratio has
a natural break, p97 at 2.7x and p98 at 10.4x, and any threshold between 3x and
8x isolates the same moves.

Usage: bench-compare.py <reference.csv> <subject.csv> [--cut 5.0]
"""

import csv
import statistics
import sys


def load(path):
    with open(path) as handle:
        return {
            (row["game"], row["turn"]): row for row in csv.DictReader(handle)
        }


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, int(fraction * (len(ordered) - 1)))
    return ordered[index]


def summarise(rows, keys):
    walls = [float(rows[k]["wall_ms"]) for k in keys]
    return (
        statistics.median(walls),
        percentile(walls, 0.95),
        percentile(walls, 0.99),
        max(walls),
    )


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    cut = 5.0
    if "--cut" in argv:
        cut = float(argv[argv.index("--cut") + 1])

    reference, subject = load(argv[1]), load(argv[2])
    keys = sorted(set(reference) & set(subject))
    if not keys:
        print("no moves in common — are these runs of the same benchmark?", file=sys.stderr)
        return 1
    missing = len(set(reference) ^ set(subject))
    if missing:
        print(f"warning: {missing} moves appear in only one run", file=sys.stderr)

    outliers = [
        k
        for k in keys
        if float(reference[k]["wall_ms"]) > 0
        and float(subject[k]["wall_ms"]) / float(reference[k]["wall_ms"]) > cut
    ]
    kept = [k for k in keys if k not in set(outliers)]

    print(f"paired on (game, turn): {len(keys)} moves")
    print(f"excluded: {len(outliers)} ({100 * len(outliers) / len(keys):.1f}%) over {cut:g}x the reference")
    print()
    header = f"{'':26}{'median':>9}{'p95':>9}{'p99':>9}{'max':>9}"
    print(header)
    ref = summarise(reference, keys)
    raw = summarise(subject, keys)
    clean = summarise(subject, kept)
    for name, stats in (("reference", ref), ("subject, all moves", raw), ("subject, cleaned", clean)):
        print(f"  {name:24}" + "".join(f"{v:9.2f}" for v in stats))
    print()
    print("  ratio, cleaned:          " + "".join(
        f"{c / r:8.1f}x" for c, r in zip(clean[:3], ref[:3])
    ))
    print("  ratio, all moves:        " + "".join(
        f"{a / r:8.1f}x" for a, r in zip(raw[:3], ref[:3])
    ))
    print()
    print("One factor across median, p95 and p99 is the machine. A p99 far above")
    print("the other two is the hypervisor, and is not evidence about this code.")

    if outliers:
        ref_cost = statistics.median(float(reference[k]["wall_ms"]) for k in outliers)
        with_blank = sum(1 for k in outliers if int(subject[k]["blanks"]) > 0)
        print()
        print(f"The excluded moves cost {ref_cost:.2f} ms on the reference, against its")
        print(f"{ref[0]:.2f} ms median, and {with_blank} of {len(outliers)} held a blank. Ordinary positions,")
        print("in other words, rather than hard ones.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
