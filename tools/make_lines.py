#!/usr/bin/env python3
"""Builds ios/Shared/lines.json, the stations each line stops at in order, from
the MTA's GTFS schedule.

    curl -o google_transit.zip http://web.mta.info/developers/data/nyct/subway/google_transit.zip
    unzip google_transit.zip -d gtfs
    python3 tools/make_lines.py gtfs ios/Shared/stations.json ios/Shared

Each line is keyed by its bullet's label ("6" covers the 6 and the 6 express,
"S" all three shuttles; see line_styles.py) and lists GTFS stop ids from its
northern end south, as its southbound trains run, keeping only the stations
stations.json says it serves by day (trains rerouted for track work stop at
others). Where trains run different patterns, such as the A's three branches or
the R running short at night, the stops of the less common ones go in among
those before, a branch after the last stop it shares with them. A stop only
northbound trains make, such as Aqueduct Racetrack on the A, is then added from
those trains, run backwards.
"""
import csv
import json
import sys
from collections import Counter

from line_styles import label


def merge(order, pattern):
    """Adds the stops of `pattern` not yet in `order`: each run of them right
    before the stop after it, or after the stop before it where it has none
    after (a branch), or at the end where it has neither."""
    seen = set(order)
    at = None  # where in `order` the last shared stop is
    pending = []
    for stop in pattern:
        if stop in seen:
            index = order.index(stop)
            if pending:
                order[index:index] = pending
                seen.update(pending)
                index += len(pending)
                pending = []
            at = index
        else:
            pending.append(stop)
    if pending:
        spot = at + 1 if at is not None else len(order)
        order[spot:spot] = pending


def main(gtfs_dir, stations_path, target_dir):
    with open(stations_path, encoding="utf-8") as file:
        serves = {(station["id"], label(route))
                  for station in json.load(file) for route in station["routes"]}
    with open(f"{gtfs_dir}/trips.txt", encoding="utf-8-sig", newline="") as file:
        # Direction 1 is southbound, 0 northbound
        trips = {row["trip_id"]: (label(row["route_id"]), row["direction_id"] == "1")
                 for row in csv.DictReader(file)}
    stops = {}
    with open(f"{gtfs_dir}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            if row["trip_id"] in trips:
                # "R01S" is the southbound platform of R01
                stops.setdefault(row["trip_id"], []).append((int(row["stop_sequence"]), row["stop_id"][:-1]))
    patterns = {}
    for trip, (name, southbound) in trips.items():
        if trip in stops:
            # A northbound trip's stops backwards, from the north end south
            ordered = sorted(stops[trip], reverse=not southbound)
            pattern = tuple(stop for _, stop in ordered if (stop, name) in serves)
            patterns.setdefault(name, (Counter(), Counter()))[0 if southbound else 1][pattern] += 1
    lines = {}
    for name, (south, north) in sorted(patterns.items()):
        order = []
        # The southbound patterns first, so the northbound ones only add the stops they lack
        for pattern, _ in south.most_common() + north.most_common():
            merge(order, pattern)
        lines[name] = order
    missing = sorted(serves - {(stop, name) for name, order in lines.items() for stop in order})
    if missing:
        print(f"warning: no trips in the schedule stop at {', '.join(f'{stop} ({name})' for stop, name in missing)}", file=sys.stderr)
    target = f"{target_dir}/lines.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v)}" for k, v in lines.items()) + "\n}\n")
    print(f"{len(lines)} lines -> {target}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
