#!/usr/bin/env python3
"""Builds ios/Shared/stations.json and ios/Shared/equipment.json from MTA data.

    curl -o Stations.csv http://web.mta.info/developers/data/nyct/subway/Stations.csv
    curl -o entrances.json 'https://data.ny.gov/resource/i9wp-a4ja.json?$limit=5000'
    curl -o equipment.json https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fnyct_ene_equipments.json
    curl -o google_transit.zip http://web.mta.info/developers/data/nyct/subway/google_transit.zip
    unzip google_transit.zip -d gtfs
    python3 tools/make_stations.py Stations.csv entrances.json equipment.json gtfs ios/Shared

Each station keeps its GTFS stop id (the real-time feeds name platforms by adding
N or S to it), the lines that serve it as real-time route ids, the labels the MTA
gives its two directions, where it is and where its entrances are, and how
accessible it is. The labels are for most of the station's lines, and the
feeds give each trip one direction all along its line, so a line whose trains
run the other way to theirs there, by the GTFS schedule, is listed as
reversed: at Marcy Av, whose south is "Manhattan" for the J, the M's
southbound trains are on their way to Middle Village. A track the feeds name
that the list doesn't, such as the one at Broad Channel where the Rockaway
Park Shuttle ends, is listed with its platform. The MTA lists a station's sets of platforms apart, such as
Atlantic Av-Barclays Ctr's D N R, B Q and 2 3 4 5; the app joins those with the
same name in the same complex into one station. The equipment list ties each elevator and escalator to its
station complex, so the outage feed, which names only the equipment, can be
matched to a station, and to the stops whose platforms it serves: those where
the lines it serves stop.

Written to ios/Shared, both files are also copied to the server's resources:
SwiftPM bundles a symlinked resource as the link, which doesn't resolve from
the built bundle, so the server keeps copies, and CI checks they match.
"""
import csv
import json
import math
import os
import re
import shutil
import sys
from collections import Counter

from line_styles import label

BOROUGHS = {"M": "Manhattan", "Bk": "Brooklyn", "Q": "Queens", "Bx": "Bronx", "SI": "Staten Island"}
STREET = re.compile(r"\b(St|Av|Blvd|Pkwy|Rd|Tpke)$")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_RESOURCES = os.path.join(REPO, "server", "Sources", "TrainResources", "Resources")
# Stops the real-time feeds name that neither the list nor the schedule has, by
# the platform they're part of: the Rockaway Park Shuttle ends on H19, its own
# track at Broad Channel
ALIASES = {"H04": ["H19"]}


def route_ids(row):
    """The list says "S" for all three shuttles and "SIR" for Staten Island; the feeds don't."""
    stop = row["GTFS Stop ID"]
    ids = []
    for token in row["Daytime Routes"].split():
        if token == "S":
            token = "GS" if stop in ("901", "902") else "H" if stop.startswith("H") else "FS"
        elif token == "SIR":
            token = "SI"
        ids.append(token)
    return ids


def short_name(name):
    """"Forest Hills-71 Av" -> "Forest Hills", for the space-starved end of a train's trip."""
    if name == "Broadway-Lafayette St":  # "Broadway" alone would mislead
        return name
    first, dash, rest = name.partition("-")
    first = first.strip()
    # "163 St-Amsterdam Av" stays whole: "163 St" alone would be ambiguous
    return first if dash and first and STREET.search(rest) and not STREET.search(first) else name


def natural(name):
    """Sorts numbers by their value: "2 Av" before "14 St", and "14 St" before "103 St"."""
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name.lower())]


def entrances_by_stop(path):
    with open(path, encoding="utf-8") as file:
        rows = json.load(file)
    entrances = {}
    for row in rows:
        entrance = {
            "lat": round(float(row["entrance_latitude"]), 6),
            "lon": round(float(row["entrance_longitude"]), 6),
            "type": row["entrance_type"],
        }
        if row.get("entry_allowed") == "NO":
            entrance["exitOnly"] = True
        # A station on two levels lists both its stops: "A32; D20"
        for stop in row["gtfs_stop_id"].split(";"):
            entrances.setdefault(stop.strip(), []).append(entrance)
    return entrances


def reversed_routes(gtfs_dir, stations):
    """The lines at each stop, by its id, whose southbound trains there head the
    way the MTA's north label names, and northbound ones its south: by the GTFS
    schedule, those whose southbound trips there go more than 120 degrees away
    from those of most of the stop's lines, or with as many each way, its first
    line's (lines bend and part at a stop, but not that much). Only where the
    MTA names both ways: at the end of a line, trains come in from wherever
    their lines do."""
    where = {s["id"]: (s["lon"] * math.cos(math.radians(s["lat"])), s["lat"]) for s in stations}
    routes = {s["id"]: s["routes"] for s in stations}
    with open(f"{gtfs_dir}/trips.txt", encoding="utf-8-sig", newline="") as file:
        # Direction 1 is southbound, 0 northbound
        trips = {row["trip_id"]: (label(row["route_id"]), row["direction_id"] == "1")
                 for row in csv.DictReader(file)}
    calls = {}
    with open(f"{gtfs_dir}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            # "R01S" is the southbound platform of R01
            if row["trip_id"] in trips and row["stop_id"][:-1] in where:
                calls.setdefault(row["trip_id"], []).append((int(row["stop_sequence"]), row["stop_id"][:-1]))
    # Each line's way south at each of its stops: every trip's way from the stop
    # before to the one after, added up (a northbound trip's backwards)
    heading = {}
    for trip, stops in calls.items():
        name, southbound = trips[trip]
        stops = [stop for _, stop in sorted(stops)]
        for at, stop in enumerate(stops):
            # A train rerouted to a stop its line doesn't serve by day says nothing about it
            route = next((route for route in routes[stop] if label(route) == name), None)
            (x0, y0), (x1, y1) = where[stops[max(at - 1, 0)]], where[stops[min(at + 1, len(stops) - 1)]]
            length = math.hypot(x1 - x0, y1 - y0)
            if route and length:
                sign = 1 if southbound else -1
                x, y = heading.get((stop, route), (0, 0))
                heading[(stop, route)] = (x + sign * (x1 - x0) / length, y + sign * (y1 - y0) / length)

    def cos(a, b):
        return (a[0] * b[0] + a[1] * b[1]) / (math.hypot(*a) * math.hypot(*b) or 1)

    turned = {}
    even = []
    for station in stations:
        ways = [(route, heading[(station["id"], route)]) for route in station["routes"]
                if (station["id"], route) in heading]
        if not (ways and station["north"] and station["south"]):
            continue
        # The labels are taken to be for the larger group of lines that head
        # one way, so a list that gives another line first can't turn them all
        # round: at Marcy Av the J and Z's, not the M's. Where as many head each
        # way, they're for the list's first line, as at Flushing Av.
        agreeing = [sum(cos(way, other) > 0 for _, other in ways) for _, way in ways]
        reference = ways[agreeing.index(max(agreeing))][1]
        if max(agreeing) * 2 == len(ways):
            even.append(station["id"])
        for route, way in ways:
            if cos(reference, way) < -0.5:
                turned.setdefault(station["id"], []).append(route)
    if even:
        print(f"As many lines head each way at {', '.join(sorted(even))}: their labels are taken to be the first line's")
    return turned


def served_lines(text):
    """"N/W/7" -> {"N", "W", "7"}: the lines an elevator or escalator serves, as
    real-time route ids. "S" could be any of the three shuttles; "LIRR" and
    "METRO-NORTH" are no subway platform's."""
    lines = set()
    for token in (text or "").split("/"):
        token = token.strip()
        if token == "S":
            lines |= {"GS", "FS", "H"}
        elif token == "SIR":
            lines.add("SI")
        elif token:
            lines.add(token)
    return lines


def equipment(path, stations):
    """The elevators and escalators at subway stations, by id, including those a
    building owner runs rather than the MTA (they're in the outage feed too).
    Each lists the GTFS stops whose platforms it serves: those of its complex
    (or listed for it) where the lines it serves stop. The MTA's own list of
    its stops mostly names every one in the complex, and at Queensboro Plaza
    leaves out the N W's, so it's gone by only where none of those lines stop,
    as for the LIRR's elevators at 61 St-Woodside."""
    with open(path, encoding="utf-8") as file:
        rows = json.load(file)
    routes = {station["id"]: set(station["routes"]) for station in stations}
    complexes = {}
    for station in stations:
        complexes.setdefault(station["complex"], []).append(station["id"])
    machines = {}
    for row in sorted(rows, key=lambda row: row["equipmentno"]):
        if row["stationcomplexid"] not in complexes:
            continue
        machine = {
            "complex": row["stationcomplexid"],
            "elevator": row["equipmenttype"] == "EL",
            "ada": row["ADA"] == "Y",
            "serving": row["serving"],
            "alternative": (row.get("alternativeroute") or "").strip(),
        }
        # "L03/R20", 14 St-Union Sq's L and its N Q R W, even for an elevator to the L alone
        listed = [stop.strip() for stop in (row.get("elevatorsgtfsstopid") or "").split("/") if stop.strip()]
        lines = served_lines(row.get("linesservedbyelevator"))
        candidates = set(complexes[row["stationcomplexid"]] + listed)
        stops = sorted(stop for stop in candidates if routes.get(stop, set()) & lines) or listed
        if stops:
            machine["stops"] = stops
        machines[row["equipmentno"]] = machine
    return machines


def main(source, entrances_path, equipment_path, gtfs_dir, target_dir):
    with open(source, encoding="utf-8-sig", newline="") as file:
        rows = list(csv.DictReader(file))
    entrances = entrances_by_stop(entrances_path)
    stations = [
        {
            "id": row["GTFS Stop ID"],
            "name": row["Stop Name"],
            "short": short_name(row["Stop Name"]),
            "borough": BOROUGHS[row["Borough"]],
            "routes": route_ids(row),
            "north": row["North Direction Label"],
            "south": row["South Direction Label"],
            "lat": float(row["GTFS Latitude"]),
            "lon": float(row["GTFS Longitude"]),
            "complex": row["Complex ID"],
            # 0: not accessible, 1: accessible, 2: partly (see adaNotes)
            "ada": int(row["ADA"]),
            "adaNotes": row["ADA Direction Notes"],
            "entrances": entrances.get(row["GTFS Stop ID"], []),
        }
        for row in rows
    ]
    unmatched = sorted(set(entrances) - {station["id"] for station in stations})
    if unmatched:
        print(f"warning: entrances of unknown stops left out: {', '.join(unmatched)}", file=sys.stderr)
    # The entrance list files a complex's shared entrances under one of its stations
    by_complex = {}
    for station in stations:
        by_complex.setdefault(station["complex"], []).extend(station["entrances"])
    for station in stations:
        if not station["entrances"]:
            station["entrances"] = by_complex[station["complex"]]
    turned = reversed_routes(gtfs_dir, stations)
    for station in stations:
        if station["id"] in turned:
            station["reversed"] = turned[station["id"]]
            # A partly accessible one's notes name the step-free way by the
            # labels, which the app takes to be every line's (Platform.stepFreeWay)
            if station["ada"] == 2:
                sys.exit(f"{station['id']} is partly accessible and has lines named the other way round "
                         f"({', '.join(turned[station['id']])}), so which way is step-free for them isn't known")
        if station["id"] in ALIASES:
            station["aliases"] = ALIASES[station["id"]]
    print(f"Named the other way round: {', '.join(f'{route} at {stop}' for stop, routes in turned.items() for route in routes)}")
    # The app looks each platform up by its id, so two with one id would crash it
    ids = [stop for station in stations for stop in [station["id"]] + station.get("aliases", [])]
    repeated = sorted(stop for stop, count in Counter(ids).items() if count > 1)
    if repeated:
        sys.exit(f"{source} lists these GTFS Stop IDs more than once: {', '.join(repeated)}")
    # By name, as the app lists them
    stations.sort(key=lambda station: (natural(station["name"]), station["borough"]))
    target = f"{target_dir}/stations.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("[\n" + ",\n".join(json.dumps(s, ensure_ascii=False) for s in stations) + "\n]\n")
    print(f"{len(stations)} stations, {sum(len(s['entrances']) for s in stations)} entrances -> {target}")

    machines = equipment(equipment_path, stations)
    target = f"{target_dir}/equipment.json"
    with open(target, "w", encoding="utf-8") as file:
        file.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in machines.items()) + "\n}\n")
    print(f"{len(machines)} elevators and escalators -> {target}")

    if os.path.samefile(target_dir, os.path.join(REPO, "ios", "Shared")):
        for name in ("stations.json", "equipment.json"):
            shutil.copyfile(f"{target_dir}/{name}", os.path.join(SERVER_RESOURCES, name))
        print(f"and copied to {os.path.relpath(SERVER_RESOURCES, REPO)}")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:6])
