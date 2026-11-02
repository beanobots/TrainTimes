#!/usr/bin/env python3
"""Builds ios/App/bus_shapes.json, the streets each bus line runs along, from
the MTA's bus GTFS schedules (one for each borough, and MTA Bus), for the
pale bus routes on Nearby's and New Trip's maps (NearbyLines.swift).

    for feed in gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco; do
        curl -o $feed.zip https://rrgtfsfeeds.s3.amazonaws.com/$feed.zip
        unzip $feed.zip -d $feed
    done
    python3 tools/make_bus_shapes.py ios/App gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco

As make_shapes.py does for the subway: each line's shapes, the longest first,
leaving out any that runs along one already listed (so a two-way street is
drawn once, and a one-way pair twice), each simplified and written the same
way. Lines are keyed by their names as Bus Time's and Google's both come to
(`BusTime.canonical` on the server): "B63", "M15+" for Select Bus Service.
"""
import csv
import json
import sys
from collections import Counter, defaultdict

from make_shapes import encode, runs_along, simplify

TOLERANCE = 8  # meters a simplified shape may stray from the MTA's


def canonical(line):
    """`line` as `BusTime.canonical` has it: "M15-SBS" and "M15 SBS" are "M15+"."""
    name = "".join(c for c in line.upper() if not c.isspace() and c != "-")
    if name.endswith("SBS"):
        name = name[:-3] + "+"
    return name


def main(target_dir, feeds):
    trips = defaultdict(Counter)  # line: how many trips run each shape
    points = defaultdict(list)
    for feed in feeds:
        # Shape ids are only each feed's own
        with open(f"{feed}/trips.txt", encoding="utf-8-sig", newline="") as file:
            for trip in csv.DictReader(file):
                if trip.get("shape_id"):
                    trips[canonical(trip["route_id"])][(feed, trip["shape_id"])] += 1
        with open(f"{feed}/shapes.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                points[(feed, row["shape_id"])].append((int(row["shape_pt_sequence"]),
                                                        float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))
    shapes = {}
    for line, counts in sorted(trips.items()):
        candidates = [simplify([(lat, lon) for _, lat, lon in sorted(points[shape])], TOLERANCE)
                      for shape in counts if shape in points]
        kept = []
        for shape in sorted(candidates, key=len, reverse=True):
            if not any(runs_along(shape, other) for other in kept):
                kept.append(shape)
        shapes[line] = [encode(shape) for shape in kept]
    with open(f"{target_dir}/bus_shapes.json", "w", encoding="utf-8") as file:
        json.dump(shapes, file, separators=(",", ":"))
        file.write("\n")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
