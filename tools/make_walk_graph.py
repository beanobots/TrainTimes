#!/usr/bin/env python3
"""The walking graph: every street, path and crossing in the city, for routing
walks on the phone by how safe their crossings are (`WalkRouter.swift`).

From NYC's Street Centerline (CSCL, data.cityofnewyork.us inkn-q76z): each
block of every street as a line, with its width, lanes, speed limit, traffic
direction and roadway type, and the level it's at (13 at grade) at each end.
Blocks meet where their ends are the same point at the same level, so a street
under an expressway doesn't meet it. OpenStreetMap's paths fill in the parks,
where the city has few.

    curl -G -o cscl.geojson \\
        'https://data.cityofnewyork.us/resource/inkn-q76z.geojson' \\
        --data-urlencode '$limit=200000' \\
        --data-urlencode '$select=physicalid,stname_label,full_street_name,rw_type,nonped,
            trafdir,from_level_code,to_level_code,streetwidth,number_travel_lanes,
            number_park_lanes,posted_speed,truck_route_type,bike_lane,segmentlength,
            status,the_geom'
    # OSM paths and parks (Overpass, the five boroughs), with tags and geometry:
    #   way[highway~footway|path|pedestrian|steps|cycleway|bridleway|track]
    #       [footway!~sidewalk|crossing], service/unclassified closed to cars
    #   way/relation[leisure~park|garden|nature_reserve(|playground)]

    python3 tools/make_walk_graph.py inspect cscl.geojson osm_paths.json osm_parks.json
    python3 tools/make_walk_graph.py debug cscl.geojson osm_paths.json osm_parks.json out_dir

`inspect` prints what the data holds, to settle how to read it; `debug` writes
GeoJSON of chosen places, each block coloured by how it's read, for
`render_walk_debug.swift` to draw.
"""
import json
import math
import os
import sys
from collections import Counter, defaultdict

# Roadway types (CSCL RW_TYPE)
STREET, HIGHWAY, BRIDGE, TUNNEL, BOARDWALK, PATH, STEP_STREET, DRIVEWAY, RAMP, ALLEY, \
    UNKNOWN, NON_PHYSICAL, U_TURN, FERRY = range(1, 15)
GRADE = 13  # the level code at grade; below it underground, above it in the air

# How the walking graph reads a block
WALK = "walk"      # a street with a sidewalk each side
PATH_ = "path"     # a way with no sides: park paths, walkways, step streets
ARM = "arm"        # crossed, never walked along: highways, ramps, driveways
DROP = "drop"      # not there for walking at all: ferry routes, non-physical lines


def classify(p):
    """How a CSCL block is read, from its properties."""
    rw = int(p.get("rw_type") or UNKNOWN)
    if p.get("status") not in (None, "2") or rw in (NON_PHYSICAL, FERRY):
        return DROP
    if p.get("nonped") == "V" or rw in (HIGHWAY, TUNNEL, RAMP, DRIVEWAY, U_TURN):
        return ARM
    if rw in (PATH, BOARDWALK, STEP_STREET) or p.get("trafdir") == "NV":
        return PATH_
    return WALK


def lines(feature):
    """The block's line as [(lon, lat)], its parts joined, and how many parts."""
    geometry = feature.get("geometry") or {}
    parts = geometry.get("coordinates") or []
    if geometry.get("type") == "LineString":
        parts = [parts]
    points = []
    for part in parts:
        for point in part:
            point = (point[0], point[1])
            if not points or points[-1] != point:
                points.append(point)
    return points, len(parts)


def key(point, level):
    """A junction: the point, to a ten-millionth of a degree, and its level."""
    return (round(point[0], 7), round(point[1], 7), level)


def metres(a, b):
    """Metres from (lon, lat) `a` to `b`, near enough across a city."""
    east = (b[0] - a[0]) * 111_320 * math.cos(math.radians((a[1] + b[1]) / 2))
    north = (b[1] - a[1]) * 111_320
    return math.hypot(east, north)


def length(points):
    return sum(metres(a, b) for a, b in zip(points, points[1:]))


def inside(point, ring):
    """Whether (lon, lat) `point` is inside `ring`, by the crossings to its east."""
    x, y = point
    count = 0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y) and x1 + (y - y1) / (y2 - y1) * (x2 - x1) > x:
            count += 1
    return count % 2 == 1


class Blocks:
    """CSCL's blocks, read: each one's line, properties, class and end junctions."""

    def __init__(self, path):
        with open(path, encoding="utf-8") as file:
            features = json.load(file)["features"]
        self.items = []
        self.multipart = 0
        for feature in features:
            p = feature.get("properties") or {}
            points, parts = lines(feature)
            if len(points) < 2:
                continue
            self.multipart += parts > 1
            levels = (int(p.get("from_level_code") or GRADE), int(p.get("to_level_code") or GRADE))
            self.items.append({
                "p": p,
                "points": points,
                "class": classify(p),
                "ends": (key(points[0], levels[0]), key(points[-1], levels[1])),
            })

    def junctions(self, classes=(WALK, PATH_, ARM)):
        """Each junction's blocks of `classes`, by index."""
        at = defaultdict(list)
        for index, item in enumerate(self.items):
            if item["class"] in classes:
                for end in item["ends"]:
                    at[end].append(index)
        return at


def components(blocks, classes=(WALK, PATH_)):
    """The walkable graph's connected parts: each junction's part, biggest first."""
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for item in blocks.items:
        if item["class"] in classes:
            a, b = (find(end) for end in item["ends"])
            if a != b:
                parent[a] = b
    groups = defaultdict(list)
    for junction in list(parent):
        groups[find(junction)].append(junction)
    return sorted(groups.values(), key=len, reverse=True)


# Places to look at closely: (name, south, west, north, east)
PLACES = [
    ("hamilton-gowanus", 40.6600, -74.0010, 40.6720, -73.9850),
    ("queens-blvd-63-dr", 40.7280, -73.8650, 40.7340, -73.8560),
    ("ocean-pkwy-ave-j", 40.6230, -73.9700, 40.6280, -73.9640),
    ("broadway-96-st", 40.7920, -73.9750, 40.7960, -73.9700),
    ("times-sq", 40.7550, -73.9890, 40.7600, -73.9840),
    ("columbus-circle", 40.7660, -73.9840, 40.7700, -73.9790),
    ("grand-army-plaza", 40.6710, -73.9730, 40.6760, -73.9670),
    ("atlantic-flatbush", 40.6820, -73.9800, 40.6860, -73.9740),
    ("central-park-south", 40.7640, -73.9820, 40.7740, -73.9680),
    ("prospect-park-north", 40.6600, -73.9750, 40.6720, -73.9640),
    ("brooklyn-bridge-manhattan", 40.7100, -74.0060, 40.7140, -74.0010),
    ("brooklyn-bridge-brooklyn", 40.6990, -73.9920, 40.7040, -73.9870),
    ("manhattan-bridge-manhattan", 40.7120, -73.9970, 40.7160, -73.9910),
    ("manhattan-bridge-brooklyn", 40.6990, -73.9910, 40.7030, -73.9850),
    ("park-slope-4-av-9-st", 40.6690, -73.9910, 40.6720, -73.9870),
]

# Big parks to compare path coverage in, by their OSM name
PARKS = ["Central Park", "Prospect Park", "Flushing Meadows Corona Park", "Van Cortlandt Park",
         "Pelham Bay Park", "Forest Park", "Fort Greene Park", "Washington Square Park",
         "Riverside Park", "Marine Park"]


def in_box(points, box):
    _, south, west, north, east = box
    return any(west <= x <= east and south <= y <= north for x, y in points)


def park_rings(path):
    """Each named OSM park's outer rings, as [(lon, lat)], by name."""
    with open(path, encoding="utf-8") as file:
        elements = json.load(file)["elements"]
    rings = defaultdict(list)
    for element in elements:
        name = (element.get("tags") or {}).get("name")
        if not name:
            continue
        if element["type"] == "way" and element.get("geometry"):
            rings[name].append([(g["lon"], g["lat"]) for g in element["geometry"]])
        elif element["type"] == "relation":
            # Outer members, joined end to end where they're split
            pieces = [[(g["lon"], g["lat"]) for g in m.get("geometry") or []]
                      for m in element.get("members", []) if m.get("role") == "outer" and m.get("geometry")]
            rings[name].extend(join(pieces))
    return rings


def join(pieces):
    """Ways joined end to end into closed rings, as a relation's outer members are."""
    rings = []
    pieces = [p for p in pieces if len(p) >= 2]
    while pieces:
        ring = pieces.pop()
        changed = True
        while ring[0] != ring[-1] and changed:
            changed = False
            for i, piece in enumerate(pieces):
                if piece[0] == ring[-1]:
                    ring += piece[1:]
                elif piece[-1] == ring[-1]:
                    ring += piece[-2::-1]
                elif piece[-1] == ring[0]:
                    ring = piece[:-1] + ring
                elif piece[0] == ring[0]:
                    ring = piece[:0:-1] + ring
                else:
                    continue
                pieces.pop(i)
                changed = True
                break
        rings.append(ring)
    return rings


def osm_ways(path):
    with open(path, encoding="utf-8") as file:
        return [e for e in json.load(file)["elements"] if e["type"] == "way" and e.get("geometry")]


def inspect(cscl, osm_paths, osm_parks):
    blocks = Blocks(cscl)
    items = blocks.items
    print(f"{len(items)} blocks, {blocks.multipart} in more than one part")
    print("\n== How blocks are read")
    for name, count in Counter(i["class"] for i in items).most_common():
        print(f"  {name}: {count}")

    print("\n== Roadway type x nonped x traffic direction (count, how read, samples)")
    combos = defaultdict(list)
    for i in items:
        p = i["p"]
        combos[(p.get("rw_type"), p.get("nonped"), p.get("trafdir"))].append(i)
    for combo, group in sorted(combos.items(), key=lambda c: -len(c[1])):
        names = Counter(i["p"].get("stname_label") for i in group).most_common(4)
        print(f"  rw {combo[0]:>2} nonped {str(combo[1]):4} {str(combo[2]):4} {len(group):6}  "
              f"{group[0]['class']:4}  {', '.join(str(n) for n, _ in names)}")

    print("\n== Levels where blocks' ends meet")
    by_point = defaultdict(set)
    for i in items:
        if i["class"] != DROP:
            for end in i["ends"]:
                by_point[end[:2]].add(end[2])
    mixed = {pt: levels for pt, levels in by_point.items() if len(levels) > 1}
    print(f"  {len(by_point)} end points, {len(mixed)} with ends at more than one level")
    print("  level sets:", Counter(tuple(sorted(v)) for v in mixed.values()).most_common(8))

    print("\n== Junction degree (walkable and crossed blocks)")
    junctions = blocks.junctions()
    print("  ", sorted(Counter(len(v) for v in junctions.values()).items()))

    print("\n== Walkable parts (streets and paths, no highways or ramps)")
    parts = components(blocks)
    total = sum(len(c) for c in parts)
    print(f"  {len(parts)} parts, the biggest {len(parts[0])} of {total} junctions "
          f"({len(parts[0]) / total:.1%}); sizes after it: {[len(c) for c in parts[1:12]]}")
    named = defaultdict(Counter)
    for index, item in enumerate(items):
        for end in item["ends"]:
            named[end][item["p"].get("stname_label")] += 1
    for part in parts[1:16]:
        if len(part) < 8:
            break
        names = Counter()
        for j in part:
            names.update(named[j])
        lon = sum(j[0] for j in part) / len(part)
        lat = sum(j[1] for j in part) / len(part)
        print(f"  {len(part):5} junctions near {lat:.4f},{lon:.4f}: {', '.join(str(n) for n, _ in names.most_common(4))}")

    print("\n== Bridge walkways and where their ends go")
    main = set(parts[0])
    for i in items:
        name = (i["p"].get("stname_label") or "")
        if i["class"] == PATH_ and int(i["p"].get("rw_type") or 0) == BRIDGE:
            ends = [f"L{e[2]} deg{len(junctions[e])}{'' if e in main else ' (cut off)'}" for e in i["ends"]]
            print(f"  {name[:44]:44} {length(i['points']):6.0f} m  {ends[0]:22} {ends[1]}")

    print("\n== Plaza and square blocks")
    for box in PLACES:
        if box[0] in ("times-sq", "columbus-circle", "grand-army-plaza"):
            print(f"  {box[0]}:")
            for i in items:
                if in_box(i["points"], box) and i["class"] != DROP:
                    p = i["p"]
                    if any(w in (p.get("stname_label") or "") for w in ("BROADWAY", "7 AVE", "PLZ", "PLAZA", "CIR", "FLATBUSH", "PROSPECT PARK W")):
                        print(f"    {p.get('stname_label')[:30]:30} rw {p.get('rw_type'):>2} nonped {str(p.get('nonped')):4} "
                              f"{p.get('trafdir')} lanes {p.get('number_travel_lanes')} {length(i['points']):5.0f} m -> {i['class']}")

    print("\n== Paths in big parks: the city's against OpenStreetMap's (metres of path)")
    rings = park_rings(osm_parks)
    ways = osm_ways(osm_paths)
    for park in PARKS:
        outer = max(rings.get(park, []), key=len, default=None)
        if not outer:
            print(f"  {park}: no polygon")
            continue
        xs, ys = [x for x, _ in outer], [y for _, y in outer]
        bounds = (min(xs), min(ys), max(xs), max(ys))

        def within(points):
            mid = points[len(points) // 2]
            return bounds[0] <= mid[0] <= bounds[2] and bounds[1] <= mid[1] <= bounds[3] and inside(mid, outer)

        city = sum(length(i["points"]) for i in items if i["class"] == PATH_ and within(i["points"]))
        drives = sum(length(i["points"]) for i in items if i["class"] == WALK and within(i["points"]))
        osm = sum(length([(g["lon"], g["lat"]) for g in w["geometry"]]) for w in ways
                  if within([(g["lon"], g["lat"]) for g in w["geometry"]]))
        print(f"  {park:30} city paths {city / 1000:6.1f} km, city streets/drives {drives / 1000:6.1f} km, OSM paths {osm / 1000:6.1f} km")

    print("\n== nonped D: what it's on")
    d = [i for i in items if i["p"].get("nonped") == "D"]
    print("  ", Counter((i["p"].get("rw_type"), i["p"].get("trafdir")) for i in d).most_common(10))
    print("   names:", ", ".join(n for n, _ in Counter(i["p"].get("stname_label") for i in d).most_common(25)))

    print("\n== Widths, lanes and speeds on streets")
    walk = [i["p"] for i in items if i["class"] == WALK]
    for field in ("streetwidth", "number_travel_lanes", "posted_speed", "truck_route_type", "trafdir"):
        values = Counter(p.get(field) for p in walk)
        missing = values.pop(None, 0)
        print(f"  {field}: {missing} missing; {sorted(values.items(), key=lambda kv: -kv[1])[:12]}")


def debug(cscl, osm_paths, osm_parks, out_dir):
    """GeoJSON for each of `PLACES`: blocks by how they're read, junctions by
    degree and level, OSM paths and parks."""
    blocks = Blocks(cscl)
    junctions = blocks.junctions()
    ways = osm_ways(osm_paths)
    with open(osm_parks, encoding="utf-8") as file:
        parks = [e for e in json.load(file)["elements"] if e["type"] == "way" and e.get("geometry")]
    os.makedirs(out_dir, exist_ok=True)
    for box in PLACES:
        features = []
        for park in parks:
            ring = [(g["lon"], g["lat"]) for g in park["geometry"]]
            if in_box(ring, box):
                features.append({"type": "Feature", "properties": {"kind": "park"},
                                 "geometry": {"type": "Polygon", "coordinates": [ring]}})
        for i in blocks.items:
            if in_box(i["points"], box):
                p = i["p"]
                features.append({"type": "Feature", "properties": {
                    "kind": i["class"], "name": p.get("stname_label"), "rw": p.get("rw_type"),
                    "nonped": p.get("nonped"), "levels": [e[2] for e in i["ends"]],
                    "lanes": p.get("number_travel_lanes"), "width_ft": p.get("streetwidth")},
                    "geometry": {"type": "LineString", "coordinates": i["points"]}})
        for junction, at in junctions.items():
            point = junction[:2]
            if in_box([point], box):
                features.append({"type": "Feature", "properties": {
                    "kind": "junction", "degree": len(at), "level": junction[2]},
                    "geometry": {"type": "Point", "coordinates": point}})
        for way in ways:
            points = [(g["lon"], g["lat"]) for g in way["geometry"]]
            if in_box(points, box):
                features.append({"type": "Feature", "properties": {
                    "kind": "osm", "highway": way["tags"].get("highway"), "name": way["tags"].get("name")},
                    "geometry": {"type": "LineString", "coordinates": points}})
        target = os.path.join(out_dir, f"{box[0]}.geojson")
        with open(target, "w", encoding="utf-8") as file:
            json.dump({"type": "FeatureCollection", "bbox": [box[2], box[1], box[4], box[3]],
                       "features": features}, file)
        print(f"{target}: {len(features)} features")


if __name__ == "__main__":
    commands = {"inspect": (inspect, 3), "debug": (debug, 4)}
    if len(sys.argv) < 2 or sys.argv[1] not in commands or len(sys.argv) != 2 + commands[sys.argv[1]][1]:
        sys.exit(f"usage: {sys.argv[0]} inspect cscl.geojson osm_paths.json osm_parks.json\n"
                 f"       {sys.argv[0]} debug cscl.geojson osm_paths.json osm_parks.json out_dir")
    function, _ = commands[sys.argv[1]]
    function(*sys.argv[2:])
