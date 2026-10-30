#!/usr/bin/env python3
"""Builds ios/Shared/stations.json and ios/Shared/equipment.json from MTA data.

    curl -o Stations.csv http://web.mta.info/developers/data/nyct/subway/Stations.csv
    curl -o entrances.json 'https://data.ny.gov/resource/i9wp-a4ja.json?$limit=5000'
    curl -o entrances_2015.csv https://raw.githubusercontent.com/P8105/p8105.github.io/master/data/NYC_Transit_Subway_Entrance_And_Exit_Data.csv
    curl -o equipment.json https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fnyct_ene_equipments.json
    curl -o google_transit.zip http://web.mta.info/developers/data/nyct/subway/google_transit.zip
    unzip google_transit.zip -d gtfs
    python3 tools/make_stations.py Stations.csv entrances.json entrances_2015.csv equipment.json gtfs ios/Shared

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
the lines it serves stop. The GTFS transfers give the walks between platforms
the MTA times at longer than its usual 3 minutes (Atlantic Av-Barclays Ctr's
D N R to its B Q, the length of the station and its stairs), kept with the
platform walked from; the app takes 3 minutes for any other.

For walking directions to and from the trains, each entrance is named by its
streets and corner, from the MTA's 2015 entrance list (data.ny.gov took it down
for today's, which leaves them out; a course's copy is above). That list also
says which stations' platforms aren't joined inside, such as 23 St on the 6,
whose Downtown stairs are on Park Av's west side; there each entrance says
which side it goes to, by where it is beside the tracks. And each says how far
along its platform it is, by the GTFS shapes' way through it, for which part of
the train to board for the exit.

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
        if row.get("exit_allowed") == "NO":
            entrance["entryOnly"] = True
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


def long_walks(gtfs_dir, stations):
    """For each platform, by its id, the platforms the GTFS transfers time a walk
    to at more than 3 minutes, in whole minutes rounded up."""
    ids = {s["id"] for s in stations}
    walks = {}
    with open(f"{gtfs_dir}/transfers.txt", encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            start, end, seconds = row["from_stop_id"], row["to_stop_id"], int(row["min_transfer_time"] or 0)
            if start != end and start in ids and end in ids and seconds > 180:
                walks.setdefault(start, {})[end] = math.ceil(seconds / 60)
    return walks


CORNERS = {"NE", "NW", "SE", "SW"}
# Metres an entrance can be from today's place for the 2015 list's: some were moved a little
OLD_MATCH = 25
# Metres an entrance can be off to the side of a platform's stop, or along it, and still be one of
# its own: farther ones are along passageways from elsewhere in the complex
BESIDE, ALONG = 60, 120
# Within this many metres of the middle of the tracks, which side an entrance is on isn't known
MIDDLE = 4
WORDS = [(r"\bAvenue\b|\bAve\b", "Av"), (r"\bStreet\b", "St"), (r"\bBoulevard\b", "Blvd"),
         (r"\bParkway\b", "Pkwy"), (r"\bRoad\b", "Rd"), (r"\bPlace\b", "Pl"),
         (r"\b(\d+)(st|nd|rd|th)\b", r"\1"), (r"^East (?=\d)", "E "), (r"^West (?=\d)", "W ")]


def street_name(text):
    """"4th Ave" -> "4 Av", "East 143rd St" -> "E 143 St": the MTA's way, as its stations are named."""
    name = " ".join(text.split())
    for pattern, replacement in WORDS:
        name = re.sub(pattern, replacement, name)
    return name


def metres(lat, lon):
    """Metres east and north, near enough at the city's latitude."""
    return (lon * 111320 * math.cos(math.radians(40.72)), lat * 111320)


def old_entrances(path):
    """The 2015 list's entrances, which name their streets and corner and whether their station's
    platforms are joined inside, by where they are: each (metres east, north, row)."""
    with open(path, encoding="utf-8-sig", newline="") as file:
        return [(*metres(float(row["Entrance Latitude"]), float(row["Entrance Longitude"])), row)
                for row in csv.DictReader(file)]


def southward(gtfs_dir, stations):
    """Which way the tracks run at each platform, by its id, toward where `south` names: a unit
    vector (east, north) along the GTFS shapes of its lines within BESIDE metres of it, southbound
    ones as they go, northbound ones backwards; `reversed` lines' the other way round. Nil where
    no line's shape passes it."""
    with open(f"{gtfs_dir}/trips.txt", encoding="utf-8-sig", newline="") as file:
        ways = {}
        for row in csv.DictReader(file):
            ways.setdefault(row["shape_id"], (row["route_id"], row["direction_id"] == "1"))
    shapes = {}
    with open(f"{gtfs_dir}/shapes.txt", encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            shapes.setdefault(row["shape_id"], []).append(
                metres(float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))

    def nearest(points, x, y):
        """The way along the nearest piece of `points` to (x, y), and how far it is."""
        best = (math.inf, None)
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            dx, dy = x1 - x0, y1 - y0
            length = math.hypot(dx, dy)
            if length:
                t = max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / length ** 2))
                gap = math.hypot(x - x0 - t * dx, y - y0 - t * dy)
                if gap < best[0]:
                    best = (gap, (dx / length, dy / length))
        return best

    headings = {}
    for station in stations:
        x, y = metres(station["lat"], station["lon"])
        east = north = 0
        for shape, points in shapes.items():
            route, southbound = ways.get(shape, (None, False))
            if route not in station["routes"]:
                continue
            gap, way = nearest(points, x, y)
            if gap < BESIDE:
                sign = (1 if southbound else -1) * (-1 if route in station.get("reversed", []) else 1)
                east, north = east + sign * way[0], north + sign * way[1]
        length = math.hypot(east, north)
        if length:
            headings[station["id"]] = (east / length, north / length)
    return headings


def place_entrances(stations, old_path, headings):
    """Gives each platform's entrances what the walk to them needs:
    - "streets" and "corner", from the 2015 list's entrance within OLD_MATCH metres: ["4 Av",
      "9 St"] (its north-south street first), "NW".
    - "along": metres from the platform's stop the way its `south` trains go, for those beside and
      along it; where to board for an exit there.
    - "side": "N" or "S", the platform its stairs go down to, named as `north` and `south` are,
      where the platform's sides aren't joined inside ("noCrossover"): trains keep right, so the
      stairs to the right of the way south go to the southbound side.
    A complex's entrances are listed under each of its platforms, so each gets its own copies."""
    old = old_entrances(old_path)
    unnamed = 0
    for station in stations:
        station["entrances"] = [dict(entrance) for entrance in station["entrances"]]
        crossings = Counter()
        x0, y0 = metres(station["lat"], station["lon"])
        heading = headings.get(station["id"])
        for entrance in station["entrances"]:
            x, y = metres(entrance["lat"], entrance["lon"])
            gap, row = min(((math.hypot(x - ox, y - oy), row) for ox, oy, row in old), key=lambda pair: pair[0])
            if gap <= OLD_MATCH:
                streets = [street_name(row[key]) for key in ("North South Street", "East West Street") if row[key].strip()]
                if streets:
                    entrance["streets"] = streets
                if row["Corner"] in CORNERS:
                    entrance["corner"] = row["Corner"]
                # Only its own lines' entrances say whether its platforms are joined
                lines = {row[f"Route{n}"].strip().upper() for n in range(1, 12)} - {""}
                if lines & set(station["routes"]):
                    crossings[row["Free Crossover"] == "TRUE"] += 1
            else:
                unnamed += 1
        apart = crossings[False] > crossings[True]
        if apart:
            station["noCrossover"] = True
        if not heading:
            continue
        for entrance in station["entrances"]:
            x, y = metres(entrance["lat"], entrance["lon"])
            dx, dy = x - x0, y - y0
            along = dx * heading[0] + dy * heading[1]
            # Positive to the left of the way south
            beside = heading[0] * dy - heading[1] * dx
            if abs(beside) > BESIDE or abs(along) > ALONG:
                continue
            entrance["along"] = round(along)
            if apart and abs(beside) >= MIDDLE:
                entrance["side"] = "S" if beside < 0 else "N"
    return unnamed


def check_corners(stations):
    """Drops the corners at a crossing where two of its entrances' are the wrong way round for
    where they are, as at Graham Av, whose "SW" stairs are its northernmost: compared by the
    compass, or turned 29 degrees either way for grids like Manhattan's. Returns the crossings."""
    crossings = {}
    for station in stations:
        for entrance in station["entrances"]:
            # A corner without streets (both blank in the 2015 list) names nothing
            if "corner" in entrance and "streets" in entrance:
                crossings.setdefault(tuple(entrance["streets"]), {})[(entrance["lat"], entrance["lon"])] = entrance["corner"]

    def agree(a, b, turn):
        (lat_a, lon_a), corner_a = a
        (lat_b, lon_b), corner_b = b
        dx, dy = (p - q for p, q in zip(metres(lat_a, lon_a), metres(lat_b, lon_b)))
        sin, cos = math.sin(math.radians(turn)), math.cos(math.radians(turn))
        east, north = dx * cos - dy * sin, dx * sin + dy * cos
        return ((corner_a[0] == corner_b[0] or (north > 0) == (corner_a[0] == "N"))
                and (corner_a[1] == corner_b[1] or (east > 0) == (corner_a[1] == "E")))

    wrong = set()
    for streets, corners in crossings.items():
        pairs = list(corners.items())
        if any(not any(agree(a, b, turn) for turn in (0, -29, 29))
               for i, a in enumerate(pairs) for b in pairs[i + 1:] if a[1] != b[1]):
            wrong.add(streets)
    for station in stations:
        for entrance in station["entrances"]:
            if tuple(entrance.get("streets", ())) in wrong:
                entrance.pop("corner", None)
    return wrong


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


def main(source, entrances_path, old_path, equipment_path, gtfs_dir, target_dir):
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
    walks = long_walks(gtfs_dir, stations)
    for station in stations:
        if station["id"] in walks:
            station["walks"] = dict(sorted(walks[station["id"]].items()))
    headings = southward(gtfs_dir, stations)
    unnamed = place_entrances(stations, old_path, headings)
    # Kept too, in degrees clockwise from north, for placing the station's other platforms'
    # entrances along this one, as the app does for an exit a passage away
    for station in stations:
        if station["id"] in headings:
            east, north = headings[station["id"]]
            station["heading"] = round(math.degrees(math.atan2(east, north))) % 360
    wrong = check_corners(stations)
    listed = [e for s in stations for e in s["entrances"]]
    print(f"Entrances: {sum('streets' in e for e in listed)} of {len(listed)} named by their streets "
          f"({unnamed} not in the 2015 list), {sum('corner' in e for e in listed)} by their corner "
          f"(left out at {len(wrong)} crossings where they're the wrong way round), "
          f"{sum('along' in e for e in listed)} placed along their platform, "
          f"{sum('side' in e for e in listed)} going to one side, at {sum('noCrossover' in s for s in stations)} "
          f"platforms not joined inside; no tracks found at {', '.join(sorted(s['id'] for s in stations if s['id'] not in headings)) or 'none'}")
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
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(*sys.argv[1:7])
