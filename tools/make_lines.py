#!/usr/bin/env python3
"""Builds ios/Shared/lines.json, the stations each line stops at in order, from
the MTA's GTFS schedule.

    curl -o google_transit.zip http://web.mta.info/developers/data/nyct/subway/google_transit.zip
    unzip google_transit.zip -d gtfs
    python3 tools/make_lines.py gtfs ios/Shared/stations.json ios/Shared

Each line is keyed by its bullet's label ("6" covers the 6 and the 6 express,
"S" all three shuttles) and lists GTFS stop ids from its northern end south,
as its southbound trains run, keeping only the stations stations.json says it
serves by day (trains rerouted for track work stop at others). Where trains
run different patterns, such as the A's three branches or the R running short
at night, the stops of the less common ones go in after the last stop they
share with those before.
"""
import csv
import json
import sys
from collections import Counter

LABELS = {"6X": "6", "7X": "7", "FX": "F", "GS": "S", "FS": "S", "H": "S"}


def merge(order, pattern):
    """Adds the stops of `pattern` not yet in `order`, each run of them after
    the stop before it, or before the stop after it where it has none."""
    seen = set(order)
    at = None  # where in `order` the last shared stop is
    pending = []
    for stop in pattern:
        if stop in seen:
            index = order.index(stop)
            if pending:
                spot = at + 1 if at is not None else index
                order[spot:spot] = pending
                seen.update(pending)
                index = order.index(stop)
                pending = []
            at = index
        else:
            pending.append(stop)
    if pending:
        spot = at + 1 if at is not None else len(order)
        order[spot:spot] = pending


def main(gtfs_dir, stations_path, target_dir):
    with open(stations_path, encoding="utf-8") as file:
        serves = {(station["id"], LABELS.get(route, route))
                  for station in json.load(file) for route in station["routes"]}
    with open(f"{gtfs_dir}/trips.txt", encoding="utf-8-sig", newline="") as file:
        southbound = {row["trip_id"]: LABELS.get(row["route_id"], row["route_id"])
                      for row in csv.DictReader(file) if row["direction_id"] == "1"}
    stops = {}
    with open(f"{gtfs_dir}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            if row["trip_id"] in southbound:
                # "R01S" is the southbound platform of R01
                stops.setdefault(row["trip_id"], []).append((int(row["stop_sequence"]), row["stop_id"][:-1]))
    patterns = {}
    for trip, label in southbound.items():
        if trip in stops:
            pattern = tuple(stop for _, stop in sorted(stops[trip]) if (stop, label) in serves)
            patterns.setdefault(label, Counter())[pattern] += 1
    lines = {}
    for label, counts in sorted(patterns.items()):
        order = []
        for pattern, _ in counts.most_common():
            merge(order, pattern)
        lines[label] = order
    target = f"{target_dir}/lines.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v)}" for k, v in lines.items()) + "\n}\n")
    print(f"{len(lines)} lines -> {target}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
