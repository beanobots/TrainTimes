#!/usr/bin/env python3
"""Builds ios/Shared/bus_routes.json, each bus line's stops in order each way it
runs, with their names and the timetable's minutes between them, from the
MTA's bus GTFS schedules, for changing between a bus and the subway on a
saved widget (BusRoutes.swift): the stops along a bus ride to change at, the
stops near a station to change to, and when a bus gets to a stop further on.

    (download and unzip the feeds as make_bus_shapes.py says)
    python3 tools/make_bus_routes.py ios/Shared gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco

Each line's ways are its commonest stop patterns each direction (up to
PATTERNS, so branches and short turns are covered), the commonest headsign of
each, and each stop's minutes from the first, averaged over the pattern's
trips. Lines are named as make_bus_shapes.py names them, by route_short_name
("Q6", "M15+"). Written as
{"stops": [[code, latitude, longitude, name], ...],
 "lines": {"B63": [{"to": headsign, "stops": [index, ...], "minutes": [...]}, ...]}},
positions in hundred-thousandths of a degree, codes as on the stops' signs
(Bus Time's stop codes), minutes to a tenth.

With ios/Shared as the target, it also writes the server's bus_stop_lines.json,
every stop and each line any trip makes it on, {"308209": ["B63", ...], ...},
for checking a bus countdown's stop and lines (BusStops.swift).
"""
import csv
import json
import os
import sys
from collections import Counter, defaultdict

from make_bus_shapes import canonical, line_names

PATTERNS = 3  # each direction's commonest stop patterns kept
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_RESOURCES = os.path.join(REPO, "server", "Sources", "TrainResources", "Resources")


def seconds(clock):
    hours, minutes, secs = (int(part) for part in clock.split(":"))
    return hours * 3600 + minutes * 60 + secs


def read_patterns(feeds):
    """The feeds' stops, by code, (latitude, longitude, name) in hundred-thousandths of a
    degree; each line's each direction's stop patterns, {codes: [trips, headsigns, summed
    offsets]}; and every line stopping at each stop on any pattern."""
    stops = {}  # code: (latitude, longitude, name)
    # (line, direction): pattern (tuple of codes): [trip count, headsigns, summed offsets]
    patterns = defaultdict(dict)
    served = defaultdict(set)  # code: every line stopping there, on any pattern
    for feed in feeds:
        with open(f"{feed}/stops.txt", encoding="utf-8-sig", newline="") as file:
            for stop in csv.DictReader(file):
                stops[stop["stop_id"]] = (round(float(stop["stop_lat"]) * 1e5), round(float(stop["stop_lon"]) * 1e5),
                                          stop["stop_name"].strip())
        names = line_names(feed)
        trips = {}  # trip id: (line, direction, headsign)
        with open(f"{feed}/trips.txt", encoding="utf-8-sig", newline="") as file:
            for trip in csv.DictReader(file):
                line = names.get(trip["route_id"]) or canonical(trip["route_id"])
                trips[trip["trip_id"]] = (line, trip.get("direction_id", "0"), trip.get("trip_headsign", "").strip())
        calls = defaultdict(list)  # trip id: [(sequence, code, seconds)]
        with open(f"{feed}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                if row["trip_id"] in trips and row["arrival_time"]:
                    calls[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"], seconds(row["arrival_time"])))
                    served[row["stop_id"]].add(trips[row["trip_id"]][0])
        for trip_id, stops_called in calls.items():
            stops_called.sort()
            line, direction, headsign = trips[trip_id]
            codes = tuple(code for _, code, _ in stops_called)
            start = stops_called[0][2]
            offsets = [time - start for _, _, time in stops_called]
            entry = patterns[(line, direction)].setdefault(codes, [0, Counter(), [0] * len(codes)])
            entry[0] += 1
            entry[1][headsign] += 1
            entry[2] = [total + offset for total, offset in zip(entry[2], offsets)]
    return stops, patterns, served


def kept(found):
    """Of a line's direction's patterns, those kept: the PATTERNS commonest."""
    return sorted(found.items(), key=lambda item: -item[1][0])[:PATTERNS]


def main(target_dir, feeds):
    stops, patterns, served = read_patterns(feeds)
    used = {}
    rows = []
    lines = defaultdict(list)
    for (line, _direction), found in sorted(patterns.items()):
        for codes, (count, headsigns, totals) in kept(found):
            indices = []
            for code in codes:
                if code not in used:
                    used[code] = len(rows)
                    latitude, longitude, name = stops[code]
                    rows.append([code, latitude, longitude, name])
                indices.append(used[code])
            lines[line].append({"to": headsigns.most_common(1)[0][0], "stops": indices,
                                "minutes": [round(total / count / 60, 1) for total in totals]})
    with open(f"{target_dir}/bus_routes.json", "w", encoding="utf-8") as file:
        json.dump({"stops": rows, "lines": lines}, file, separators=(",", ":"))
        file.write("\n")
    if os.path.samefile(target_dir, os.path.join(REPO, "ios", "Shared")):
        write_stop_lines(served, SERVER_RESOURCES)


def write_stop_lines(served, target_dir):
    with open(f"{target_dir}/bus_stop_lines.json", "w", encoding="utf-8") as file:
        json.dump({code: sorted(lines) for code, lines in sorted(served.items())}, file, separators=(",", ":"))
        file.write("\n")
    print(f"{len(served)} stops' lines -> {target_dir}/bus_stop_lines.json")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
