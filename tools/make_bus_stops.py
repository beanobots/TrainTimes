#!/usr/bin/env python3
"""Builds ios/App/bus_stops.json, every bus stop and the lines that stop there,
from the MTA's bus GTFS schedules, for marking stops along the bus routes on
Nearby's map (NearbyLines.swift).

    (download and unzip the feeds as make_bus_shapes.py says)
    python3 tools/make_bus_stops.py ios/App gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco

A line's stops are those of one trip of each shape it runs, which covers its
branches and short turns without reading every trip. Written as
{"lines": [names], "stops": [[latitude, longitude, line, line...], ...]}, the
position in hundred-thousandths of a degree and each line its place in
"lines", named as make_bus_shapes.py names them ("M15+").
"""
import csv
import json
import sys
from collections import defaultdict

from make_bus_shapes import canonical


def main(target_dir, feeds):
    stops = {}  # (latitude, longitude) in 1e-5 degrees: set of lines
    for feed in feeds:
        # One trip of each line's each shape
        sample = {}  # trip id: line
        seen = set()
        with open(f"{feed}/trips.txt", encoding="utf-8-sig", newline="") as file:
            for trip in csv.DictReader(file):
                key = (trip["route_id"], trip.get("shape_id"))
                if key not in seen:
                    seen.add(key)
                    sample[trip["trip_id"]] = canonical(trip["route_id"])
        places = {}
        with open(f"{feed}/stops.txt", encoding="utf-8-sig", newline="") as file:
            for stop in csv.DictReader(file):
                places[stop["stop_id"]] = (round(float(stop["stop_lat"]) * 1e5), round(float(stop["stop_lon"]) * 1e5))
        lines_at = defaultdict(set)
        with open(f"{feed}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                line = sample.get(row["trip_id"])
                if line and row["stop_id"] in places:
                    lines_at[places[row["stop_id"]]].add(line)
        for place, lines in lines_at.items():
            stops.setdefault(place, set()).update(lines)
    names = sorted({line for lines in stops.values() for line in lines})
    index = {name: i for i, name in enumerate(names)}
    rows = [[lat, lon] + sorted(index[line] for line in lines) for (lat, lon), lines in sorted(stops.items())]
    with open(f"{target_dir}/bus_stops.json", "w", encoding="utf-8") as file:
        json.dump({"lines": names, "stops": rows}, file, separators=(",", ":"))
        file.write("\n")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
