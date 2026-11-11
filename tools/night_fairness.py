#!/usr/bin/env python3
"""What the night costs do across the city (`NightFairness.swift`'s walks.json), by how much
crime there is round each walk: no part of town should be walked round, only the worse of
the streets beside each other.

    python3 tools/night_fairness.py walks.json safety/night
"""
import json
import math
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
import make_walk_graph as graph  # noqa: E402

NEAR = 500.0  # metres round a walk's middle its crime's counted in
FAR_ROUND = 200.0  # metres longer a walk at 11 pm is to count as gone well round


def main(walks_path, night_dir):
    walks = json.load(open(walks_path))
    crimes = graph.point_grid([(p, 1) for p, _ in graph.night_crimes(night_dir)], size=250)

    def around(a, b):
        middle = graph.xy((a[1] + b[1]) / 2, (a[0] + b[0]) / 2)
        cx, cy = int(middle[0] // 250), int(middle[1] // 250)
        count = sum(1 for dx in range(-2, 3) for dy in range(-2, 3)
                    for q, _ in crimes.get((cx + dx, cy + dy), ()) if graph.dist(q, middle) <= NEAR)
        return count / (math.pi * (NEAR / 1000) ** 2) / 3  # a year's per km²

    for walk in walks:
        walk["crime_around"] = around(walk["from"], walk["to"])
    ordered = sorted(w["crime_around"] for w in walks)
    cuts = [ordered[int(len(ordered) * q)] for q in (0.25, 0.5, 0.75)]

    def quarter(value):
        return sum(1 for cut in cuts if value >= cut)

    names = ["quietest quarter", "second", "third", "most crime"]
    print(f"{len(walks)} routes; crime round them per km² a year: quarters from {[round(c) for c in cuts]}\n")
    print("| Preference | Area | Routes | Changed at 11 pm | Longer (median, worst) | Gone >200 m round "
          "| Crime walked past | Corner crime | Dark path m | Empty street m | Unlit crossings |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for preference in ("balanced", "safest"):
        groups = defaultdict(list)
        for walk in walks:
            if walk["preference"] == preference:
                groups[quarter(walk["crime_around"])].append(walk)
        for q in range(4):
            rows = groups[q]
            if not rows:
                continue
            longer = sorted(w["late"]["metres"] - w["noon"]["metres"] for w in rows)
            changed = sum(1 for w in rows if w["changed"])
            far = sum(1 for d in longer if d > FAR_ROUND)

            def total(key, when):
                return sum(w[when][key] for w in rows)

            def drop(key):
                before, after = total(key, "noon"), total(key, "late")
                return f"{before:.0f} → {after:.0f}" + (f" ({(after - before) / before:+.0%})" if before else "")

            print(f"| {preference} | {names[q]} | {len(rows)} | {changed / len(rows):.0%} | "
                  f"{longer[len(longer) // 2]:+.0f} m, {longer[-1]:+.0f} m | {far} | {drop('crime')} | "
                  f"{drop('cornerCrime')} | {drop('darkMetres')} | {drop('quietMetres')} | {drop('unsignalled')} |")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
