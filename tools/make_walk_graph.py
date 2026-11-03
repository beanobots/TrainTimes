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
    #   way/relation[leisure~park|garden|nature_reserve]                    (out geom)
    # OSM's sidewalks, crosswalks and traffic islands (osm_sidewalks.json):
    #   way[highway=footway][footway~sidewalk|crossing|traffic_island],
    #   way[highway~path|cycleway][footway~sidewalk|crossing]               (out tags geom)

    python3 tools/make_walk_graph.py inspect cscl.geojson osm_paths.json osm_parks.json
    python3 tools/make_walk_graph.py debug cscl.geojson osm_paths.json osm_parks.json out_dir

Where OSM maps a street's sidewalks they're walked instead of the city's sides, and
its crosswalks (each with its length, light and markings) are where the street's
crossed; the city's streets carry on where OSM has none, its corners linked to OSM's
sidewalks nearby.

    python3 tools/make_walk_graph.py build cscl.geojson osm_paths.json osm_parks.json \
        osm_sidewalks.json ios/App/sidewalks.sqlite safety/ ios/App/walkgraph.sqlite

Safety data in `safety/` (NYC Open Data, data.cityofnewyork.us/resource/…):

    vz_speed.geojson         5mad-ntua.geojson?$limit=200000         speed limits
    vz_corridors.geojson     36nr-7fbp.geojson                       priority corridors
    vz_intersections.json    tmt9-43em.json                          priority intersections
    crashes.json             h9gi-nx95.json, the last five years' with pedestrians hurt:
                             $select=crash_date,latitude,longitude,number_of_pedestrians_injured,
                             number_of_pedestrians_killed&$where=crash_date >= '…' AND
                             (number_of_pedestrians_injured > 0 OR number_of_pedestrians_killed > 0)
    ramps.json               ufzp-rrqu.json?$select=the_geom,cornerid,ramp_width&$limit=300000

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
    name = p.get("stname_label") or ""
    # A viaduct's for cars, though a piece or two of Park Ave's isn't marked so
    if p.get("nonped") == "V" or rw in (HIGHWAY, TUNNEL, RAMP, DRIVEWAY, U_TURN) or "VIADUCT" in name:
        return ARM
    # A bridge's bike path, beside its walkway: no one walks it (OSM's are left out likewise
    # unless foot's allowed)
    if ("BIKE PATH" in name or "BIKE PTH" in name) and "PEDESTRIAN" not in name:
        return DROP
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


# MARK: - Building the graph

FORMAT = 4  # the file's layout, as `WalkGraph.format` expects
SIMPLIFY = 0.5  # metres a block's line may stray from the city's
OSM_SIMPLIFY = 1.0  # metres an OSM way's may stray from OSM's: its sidewalks' corners have many points
ALONGSIDE = 12.0  # metres within which an OSM way runs along a street: its sidewalk
PARALLEL = 25.0  # degrees two lines may be apart and still run alongside each other
JOIN = 10.0  # metres from a street a path's loose end is joined to it
OSM_JOIN = 15.0  # the same, for OSM's paths, whose ends stop short of the curb more
SIGNAL_REACH = 30.0  # metres from a junction a signal may be and still be its
MID_BLOCK_SIGNAL = 10.0  # metres from a street a signal away from junctions is its crosswalk's
MEDIAN_LINK = 60.0  # metres long at most for the bit of street between a divided road's halves
# Metres from the cross street's line a refuge's put in the median, either side of it
REFUGE_SIDE = 2.0
# Safety data (Phase 6), by bit: a block's `safety`
S_CORRIDOR = 1 << 0  # a Vision Zero priority corridor, or a sidewalk along one
S_PRIORITY = 1 << 1  # a crosswalk at a Vision Zero priority intersection
S_RAMP_A = 1 << 2  # a crosswalk with a curb ramp at its start
S_RAMP_B = 1 << 3  # ...at its end
# A junction's
N_PRIORITY = 1 << 0
SPEED_NEAR = 15.0  # metres from a street's middle the speed limit layer's line may be
CORRIDOR_NEAR = 20.0  # metres a street keeps within of a priority corridor's line
PRIORITY_NEAR = 30.0  # metres from a priority intersection's point its junctions are
CRASH_NEAR = 20.0  # metres from a junction, or a crosswalk's middle, a crash is counted at
KILLED_COUNTS = 5  # a pedestrian killed counts as this many hurt
RAMP_NEAR = 10.0  # metres from a corner (a crosswalk's end) its curb ramp is
RAY = 40.0  # metres either side of a street to look for its sidewalk
SIDEWALK_REACH = 25.0  # metres out a street's own sidewalk may start, no other road between
PLAZA = 10.0  # metres wide a sidewalk can be before it's a plaza, where the way keeps near the curb
ELEVATED_NEAR = 20.0  # metres from a street an elevated road over it may be (3 Av's halves under the Gowanus)
OUTSIDE = 300.0  # metres from all the city's streets an OSM path is outside the city (New Jersey)
RIKERS = (40.776, -73.900, 40.800, -73.866)  # south, west, north, east: closed to the public

# Block flags, as `WalkGraph.Block.Flags` has them
ONE_WAY, TRUCK_LOCAL, TRUCK_THROUGH, BIKE_LANE, CAR_FREE, UNDER_ELEVATED, MEDIAN, STEPS, \
    FROM_OSM, CONNECTOR, ALLEY_, COVERED_LEFT, COVERED_RIGHT, OSM_SIDEWALK, CROSSWALK, ISLAND = \
    (1 << n for n in range(16))
# A crosswalk's (`block_crossing`), as `WalkGraph.Crossing` has them
X_SIGNAL, X_LEADING, X_EXCLUSIVE, X_MARKED, X_UNMARKED, X_ISLAND, X_RAMP = (1 << n for n in range(7))
COVER_SAMPLES = (0.25, 0.5, 0.75)  # how far along a street its sides are checked for OSM's sidewalks
COVER_REACH = 10.0  # metres past the curb an OSM sidewalk may be and still be that side's
CORNER_LINK = 20.0  # metres from a city corner to the OSM sidewalk junction it's linked to
UNMAPPED_NEAR = 40.0  # metres round a street's side OSM's sidewalks show it maps the place
SIDE_LEFT_UNMAPPED, SIDE_RIGHT_UNMAPPED = 1, 2  # `block_sides` bits
# Corner kinds
CORNER_NONE, CORNER_SIDEWALK, CORNER_REFUGE, CORNER_PATH = range(4)
# Classes as stored
CLASS_CODE = {WALK: 0, PATH_: 1, ARM: 2}

ORIGIN = (-74.0, 40.7)  # (lon, lat) the plane's measured from
EAST = 111_320 * math.cos(math.radians(40.7))
NORTH = 111_320.0


def xy(lon, lat):
    """(lon, lat) as metres east and north of `ORIGIN`."""
    return ((lon - ORIGIN[0]) * EAST, (lat - ORIGIN[1]) * NORTH)


def lonlat(x, y):
    return (x / EAST + ORIGIN[0], y / NORTH + ORIGIN[1])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def bearing(a, b):
    """Degrees clockwise from north from `a` to `b`, in the plane."""
    return math.degrees(math.atan2(b[0] - a[0], b[1] - a[1])) % 360


def turn_apart(a, b):
    """Degrees between two lines' bearings, either way along: 0 to 90."""
    d = abs(a - b) % 180
    return min(d, 180 - d)


def project(p, a, b):
    """The nearest point to `p` on `a`–`b`: (it, metres from p, 0–1 along)."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length))
    q = (a[0] + t * dx, a[1] + t * dy)
    return q, dist(p, q), t


def simplify_xy(points, tolerance):
    """Douglas–Peucker in the plane: the fewest points within `tolerance`."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        far, at = 0.0, None
        for i in range(first + 1, last):
            off = project(points[i], points[first], points[last])[1]
            if off > far:
                far, at = off, i
        if at is not None and far > tolerance:
            keep[at] = True
            stack += [(first, at), (at, last)]
    return [p for p, k in zip(points, keep) if k]


def polyline_length(points):
    return sum(dist(a, b) for a, b in zip(points, points[1:]))


def segment_intersection(a, b, c, d):
    """Where `a`–`b` crosses `c`–`d`: (point, 0–1 along a–b, 0–1 along c–d), or None."""
    r = (b[0] - a[0], b[1] - a[1])
    s = (d[0] - c[0], d[1] - c[1])
    den = r[0] * s[1] - r[1] * s[0]
    if abs(den) < 1e-9:
        return None
    t = ((c[0] - a[0]) * s[1] - (c[1] - a[1]) * s[0]) / den
    u = ((c[0] - a[0]) * r[1] - (c[1] - a[1]) * r[0]) / den
    if 0 <= t <= 1 and 0 <= u <= 1:
        return (a[0] + t * r[0], a[1] + t * r[1]), t, u
    return None


class Grid:
    """Things with lines, by the cells their segments pass: to find those near a point."""

    def __init__(self, size):
        self.size = size
        self.cells = defaultdict(set)

    def cells_of(self, a, b, pad=0.0):
        s = self.size
        x0, x1 = sorted((a[0], b[0]))
        y0, y1 = sorted((a[1], b[1]))
        for cx in range(int(math.floor((x0 - pad) / s)), int(math.floor((x1 + pad) / s)) + 1):
            for cy in range(int(math.floor((y0 - pad) / s)), int(math.floor((y1 + pad) / s)) + 1):
                yield cx, cy

    def add(self, item, points):
        for a, b in zip(points, points[1:]):
            for cell in self.cells_of(a, b):
                self.cells[cell].add(item)

    def near(self, p, radius):
        found = set()
        for cell in self.cells_of(p, p, radius):
            found |= self.cells.get(cell, set())
        return found


def nearest_on(points, p):
    """The nearest point to `p` on a polyline: (point, metres off, metres along, segment index)."""
    best = None
    along = 0.0
    for i, (a, b) in enumerate(zip(points, points[1:])):
        q, off, t = project(p, a, b)
        piece = dist(a, b)
        if best is None or off < best[1]:
            best = (q, off, along + t * piece, i)
        along += piece
    return best


def runs_alongside(points, grid, lines, near, every=5.0, share=0.6):
    """Whether most of polyline `points` keeps within `near` metres of, and parallel to,
    one of `lines` (by `grid`)."""
    samples = []
    for a, b in zip(points, points[1:]):
        piece = dist(a, b)
        n = max(1, int(piece // every))
        heading = bearing(a, b)
        for k in range(n):
            t = (k + 0.5) / n
            samples.append(((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])), heading))
    if not samples:
        return False
    hits = 0
    for p, heading in samples:
        for item in grid.near(p, near):
            line = lines[item]
            q = nearest_on(line, p)
            if q and q[1] <= near:
                i = q[3]
                if turn_apart(heading, bearing(line[i], line[i + 1])) <= PARALLEL:
                    hits += 1
                    break
    return hits >= share * len(samples)


# MARK: Sidewalk polygons, from sidewalks.sqlite

def read_varints(blob):
    value = shift = 0
    for byte in blob:
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            yield value
            value = shift = 0
        else:
            shift += 7


def unzigzag(v):
    return (v >> 1) ^ -(v & 1)


class Sidewalks:
    """The city's sidewalk polygons in the plane, their edges in a grid, for ray casting
    as `Sidewalks.Edges` does in the app."""

    def __init__(self, path):
        import sqlite3
        db = sqlite3.connect(path)
        self.segments = []
        self.grid = defaultdict(list)
        self.size = 10.0
        for (blob,) in db.execute("SELECT rings FROM sidewalks"):
            values = read_varints(blob)
            count = next(values)
            lat = lon = 0
            for _ in range(count):
                n = next(values)
                ring = []
                for _ in range(n):
                    lat += unzigzag(next(values))
                    lon += unzigzag(next(values))
                    ring.append(xy(lon / 1e6, lat / 1e6))
                for a, b in zip(ring, ring[1:]):
                    if a != b:
                        index = len(self.segments)
                        self.segments.append((a, b))
                        for cell in self._cells(a, b):
                            self.grid[cell].append(index)
        # Each polygon's rings and box, by 100 m cells, for whether a point's on one
        self.polygons = []
        self.polygon_grid = defaultdict(list)
        for (blob,) in db.execute("SELECT rings FROM sidewalks"):
            values = read_varints(blob)
            count = next(values)
            lat = lon = 0
            rings = []
            for _ in range(count):
                n = next(values)
                ring = []
                for _ in range(n):
                    lat += unzigzag(next(values))
                    lon += unzigzag(next(values))
                    ring.append(xy(lon / 1e6, lat / 1e6))
                rings.append(ring)
            xs = [q[0] for q in rings[0]]
            ys = [q[1] for q in rings[0]]
            box = (min(xs), min(ys), max(xs), max(ys))
            index = len(self.polygons)
            self.polygons.append((rings, box))
            for cx in range(int(box[0] // 100), int(box[2] // 100) + 1):
                for cy in range(int(box[1] // 100), int(box[3] // 100) + 1):
                    self.polygon_grid[(cx, cy)].append(index)
        self.signals = []
        row = db.execute("SELECT points FROM signals").fetchone()
        if row:
            values = read_varints(row[0])
            count = next(values)
            lat = lon = 0
            for _ in range(count):
                lat += unzigzag(next(values))
                lon += unzigzag(next(values))
                kind = next(values)
                self.signals.append((xy(lon / 1e6, lat / 1e6), kind))
        db.close()

    def _cells(self, a, b):
        s = self.size
        for cx in range(int(math.floor(min(a[0], b[0]) / s)), int(math.floor(max(a[0], b[0]) / s)) + 1):
            for cy in range(int(math.floor(min(a[1], b[1]) / s)), int(math.floor(max(a[1], b[1]) / s)) + 1):
                yield cx, cy

    def hits(self, p, direction, reach):
        """Metres along the ray from `p` (unit `direction`) where it meets an edge, nearest first."""
        end = (p[0] + direction[0] * reach, p[1] + direction[1] * reach)
        seen = set()
        out = []
        for cell in self._cells(p, end):
            for index in self.grid.get(cell, ()):
                if index in seen:
                    continue
                seen.add(index)
                a, b = self.segments[index]
                e = (b[0] - a[0], b[1] - a[1])
                den = direction[0] * e[1] - direction[1] * e[0]
                if abs(den) < 1e-9:
                    continue
                w = (a[0] - p[0], a[1] - p[1])
                t = (w[0] * e[1] - w[1] * e[0]) / den
                u = (w[0] * direction[1] - w[1] * direction[0]) / den
                if 0 <= t <= reach and 0 <= u < 1:
                    out.append(t)
        return sorted(out)

    def inside(self, p):
        """Whether `p` is on a sidewalk: inside a polygon's curb and out of its holes."""
        for index in self.polygon_grid.get((int(p[0] // 100), int(p[1] // 100)), ()):
            rings, (x0, y0, x1, y1) = self.polygons[index]
            if x0 <= p[0] <= x1 and y0 <= p[1] <= y1:
                if sum(inside(p, ring) for ring in rings) % 2 == 1:
                    return True
        return False

    def sidewalk(self, p, direction):
        """Metres to the middle of the first sidewalk from `p` going `direction`, near its
        curb where it's wider than a sidewalk; and to its curb. None if none within `RAY`."""
        if self.inside(p):
            return None
        enter = exit_ = None
        on = False
        for t in self.hits(p, direction, RAY):
            on = not on
            if on and enter is None:
                enter = t
            elif not on and enter is not None:
                exit_ = t
                break
        if enter is None:
            return None
        width = (exit_ if exit_ is not None else RAY) - enter
        return enter + (2.5 if width > PLAZA else width / 2), enter


# MARK: Park polygons and OSM paths

def park_polygons(path):
    """Every OSM park's outer rings in the plane, with their boxes."""
    with open(path, encoding="utf-8") as file:
        elements = json.load(file)["elements"]
    rings = []
    for element in elements:
        if element["type"] == "way" and element.get("geometry"):
            ring = [xy(g["lon"], g["lat"]) for g in element["geometry"]]
            if len(ring) >= 4 and ring[0] == ring[-1]:
                rings.append(ring)
        elif element["type"] == "relation":
            pieces = [[(g["lon"], g["lat"]) for g in m.get("geometry") or []]
                      for m in element.get("members", []) if m.get("role") == "outer" and m.get("geometry")]
            for ring in join(pieces):
                if len(ring) >= 4 and ring[0] == ring[-1]:
                    rings.append([xy(*p) for p in ring])
    out = []
    for ring in rings:
        xs, ys = [p[0] for p in ring], [p[1] for p in ring]
        out.append((ring, (min(xs), min(ys), max(xs), max(ys))))
    return out


class Parks:
    def __init__(self, polygons):
        self.polygons = polygons
        self.grid = defaultdict(list)
        for index, (_, (x0, y0, x1, y1)) in enumerate(polygons):
            for cx in range(int(x0 // 200), int(x1 // 200) + 1):
                for cy in range(int(y0 // 200), int(y1 // 200) + 1):
                    self.grid[(cx, cy)].append(index)

    def contains(self, p):
        for index in self.grid.get((int(p[0] // 200), int(p[1] // 200)), ()):
            ring, (x0, y0, x1, y1) = self.polygons[index]
            if x0 <= p[0] <= x1 and y0 <= p[1] <= y1 and inside(p, ring):
                return True
        return False


WALKABLE_HIGHWAY = {"footway", "path", "pedestrian", "steps", "bridleway", "track"}


def osm_walkable(tags):
    """Whether an OSM way is for walking on, by its tags, and not a sidewalk or crosswalk
    (the city's streets have those)."""
    highway = tags.get("highway")
    if tags.get("area") == "yes" or tags.get("indoor") == "yes":
        return False
    if tags.get("access") in ("private", "no") and tags.get("foot") not in ("yes", "designated", "permissive"):
        if highway not in ("service", "unclassified", "living_street"):
            return False
    if tags.get("foot") == "no" or tags.get("footway") in ("sidewalk", "crossing"):
        return False
    if highway in WALKABLE_HIGHWAY:
        return True
    if highway == "cycleway":
        return tags.get("foot") in ("yes", "designated", "permissive")
    # Park drives closed to cars
    return highway in ("service", "unclassified", "living_street") and \
        (tags.get("motor_vehicle") in ("no", "private") or tags.get("access") == "no")


def osm_layer(tags):
    """Whether an OSM way is off the ground: a bridge, a tunnel, or another layer."""
    return tags.get("bridge") not in (None, "no") or tags.get("tunnel") not in (None, "no") or \
        tags.get("layer") not in (None, "0")


# MARK: The graph

class Block:
    __slots__ = ("points", "a", "b", "cls", "rw", "flags", "name", "width", "lanes", "speed",
                 "levels", "offset", "source", "tags", "crossing", "unmapped", "safety", "crashes")

    def __init__(self, points, cls, rw, flags, name, width, lanes, speed, levels, source):
        self.points = points
        self.cls = cls
        self.rw = rw
        self.flags = flags
        self.name = name
        self.width = width
        self.lanes = lanes
        self.speed = speed
        self.levels = levels
        self.source = source
        self.a = self.b = None
        self.offset = [0.0, 0.0]  # metres to each side's sidewalk middle; 0 for none
        self.tags = {}  # an OSM way's tags
        self.crossing = 0  # a crosswalk's X_ bits
        self.unmapped = 0  # a street's sides OSM maps round but not along (SIDE_ bits)
        self.safety = 0  # S_ bits
        self.crashes = 0  # a crosswalk's pedestrians hurt (`crash_count`)


def number(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def join_walkway_levels(blocks):
    """Where only paths' ends meet at a point, but at different levels (a bridge's walkway in
    pieces the city gave different heights), they're one junction, at the lowest of them.
    Not where a street or highway's end is there too: that's one passing over another."""
    at = defaultdict(set)
    for block in blocks:
        for j in (block.a, block.b):
            at[j[:-1]].add((j[-1], block.cls))
    merged = {}
    for point, ends in at.items():
        levels = {level for level, _ in ends}
        if len(levels) > 1 and all(cls == PATH_ for _, cls in ends):
            for level in levels:
                merged[point + (level,)] = point + (min(levels),)
    for block in blocks:
        block.a = merged.get(block.a, block.a)
        block.b = merged.get(block.b, block.b)
    return len({j[:-1] for j in merged})


def cscl_blocks(path):
    """The city's blocks as `Block`s in the plane, simplified, without ferries,
    non-physical lines and Rikers Island."""
    with open(path, encoding="utf-8") as file:
        features = json.load(file)["features"]
    blocks = []
    for feature in features:
        p = feature.get("properties") or {}
        cls = classify(p)
        if cls == DROP:
            continue
        points, _ = lines(feature)
        if len(points) < 2:
            continue
        mid = points[len(points) // 2]
        if RIKERS[0] <= mid[1] <= RIKERS[2] and RIKERS[1] <= mid[0] <= RIKERS[3]:
            continue
        rw = int(p.get("rw_type") or UNKNOWN)
        flags = 0
        if p.get("trafdir") in ("FT", "TF"):
            flags |= ONE_WAY
        truck = p.get("truck_route_type")
        if truck == "2":
            flags |= TRUCK_LOCAL
        elif truck in ("1", "3"):
            flags |= TRUCK_THROUGH
        if p.get("bike_lane"):
            flags |= BIKE_LANE
        if p.get("nonped") == "D" or p.get("trafdir") == "NV":
            flags |= CAR_FREE
        if rw == STEP_STREET:
            flags |= STEPS
        if rw == ALLEY:
            flags |= ALLEY_
        levels = (int(p.get("from_level_code") or GRADE), int(p.get("to_level_code") or GRADE))
        # Exact ends as the city has them, the line between simplified
        line = [xy(*q) for q in points]
        line = simplify_xy(line, SIMPLIFY)
        block = Block(line, cls, rw, flags, p.get("stname_label") or p.get("full_street_name") or "",
                      number(p.get("streetwidth"), 0) * 0.3048, int(number(p.get("number_travel_lanes"), 0)),
                      int(number(p.get("posted_speed"), 0)), levels, "cscl")
        block.a = key(points[0], levels[0])
        block.b = key(points[-1], levels[1])
        blocks.append(block)
    return blocks


def osm_blocks(path, parks, streets, street_grid, pedestrian=None):
    """OSM's walking ways in parks as `Block`s, without those that run along a city street or
    path (its sidewalk, or the same path); and its sidewalks, crosswalks and traffic islands
    everywhere (`pedestrian`'s file); all split where they meet each other."""
    with open(path, encoding="utf-8") as file:
        ways = [e for e in json.load(file)["elements"] if e["type"] == "way" and e.get("geometry")]
    kept = []
    dropped = Counter()
    sidewalk_ids = set()
    if pedestrian:
        with open(pedestrian, encoding="utf-8") as file:
            for way in json.load(file)["elements"]:
                tags = way.get("tags") or {}
                if way["type"] != "way" or not way.get("geometry") or tags.get("access") in ("private", "no") \
                        or tags.get("indoor") == "yes" or tags.get("foot") == "no":
                    continue
                points = [xy(g["lon"], g["lat"]) for g in way["geometry"]]
                mid = points[len(points) // 2]
                if not any(nearest_on(streets[i], mid)[1] <= OUTSIDE for i in street_grid.near(mid, OUTSIDE)):
                    dropped["sidewalks outside the city"] += 1
                    continue
                sidewalk_ids.add(way["id"])
                kept.append((way, tags, points))
    for way in ways:
        tags = way.get("tags") or {}
        if way["id"] in sidewalk_ids:
            continue
        if not osm_walkable(tags):
            dropped["tags"] += 1
            continue
        points = [xy(g["lon"], g["lat"]) for g in way["geometry"]]
        inside_count = sum(parks.contains(p) for p in points)
        if inside_count < 0.6 * len(points):
            dropped["outside parks"] += 1
            continue
        if runs_alongside(points, street_grid, streets, ALONGSIDE):
            dropped["alongside a city street or path"] += 1
            continue
        mid = points[len(points) // 2]
        if not any(nearest_on(streets[i], mid)[1] <= OUTSIDE for i in street_grid.near(mid, OUTSIDE)):
            dropped["outside the city"] += 1
            continue
        kept.append((way, tags, points))
    # Split at the points ways share (OSM's shared nodes)
    uses = Counter(p for _, _, points in kept for p in set(points))
    blocks = []
    for way, tags, points in kept:
        piece = [points[0]]
        for p in points[1:]:
            piece.append(p)
            if uses[p] > 1 and p != points[-1]:
                blocks.append(_osm_block(piece, tags))
                piece = [p]
        if len(piece) >= 2:
            blocks.append(_osm_block(piece, tags))
    print(f"  OSM: {len(kept)} ways kept, {len(blocks)} blocks; dropped {dict(dropped)}")
    return blocks


def _osm_block(points, tags):
    flags = FROM_OSM | CAR_FREE
    if tags.get("highway") == "steps":
        flags |= STEPS
    footway = tags.get("footway")
    if footway == "sidewalk":
        flags = (flags | OSM_SIDEWALK) & ~CAR_FREE
    elif footway == "crossing":
        flags = (flags | CROSSWALK) & ~CAR_FREE
    elif footway == "traffic_island":
        flags |= ISLAND
    level = GRADE + (1 if osm_layer(tags) else 0)
    line = simplify_xy(points, OSM_SIMPLIFY)
    block = Block(line, PATH_, PATH, flags, tags.get("name") or "", 0.0, 0, 0, (level, level), "osm")
    block.a = ("osm",) + tuple(round(c, 2) for c in points[0]) + (level,)
    block.b = ("osm",) + tuple(round(c, 2) for c in points[-1]) + (level,)
    block.tags = tags
    return block


class Splits:
    """Points to cut blocks at, gathered before cutting so each is cut once. A cut at a
    block's very end isn't a cut: its junction is that end's, for every block using it."""

    END = 0.25  # metres from a block's end a cut is at the end

    def __init__(self):
        self.at = defaultdict(list)  # block index -> [(metres along, junction key)]

    def add(self, index, along, junction):
        self.at[index].append((along, junction))

    def apply(self, blocks):
        alias = {}
        cut = {}
        for index, block in enumerate(blocks):
            total = polyline_length(block.points)
            inner = []
            for along, j in sorted(self.at.get(index, [])):
                if along < self.END:
                    alias[j] = block.a
                elif along > total - self.END:
                    alias[j] = block.b
                elif not inner or along - inner[-1][0] > 0.05:
                    inner.append((along, j))
                else:
                    alias[j] = inner[-1][1]
            cut[index] = inner

        def resolve(j):
            seen = set()
            while j in alias and j not in seen:
                seen.add(j)
                j = alias[j]
            return j

        out = []
        for index, block in enumerate(blocks):
            inner = cut[index]
            if not inner:
                block.a, block.b = resolve(block.a), resolve(block.b)
                out.append(block)
                continue
            pieces = cut_line(block.points, [c[0] for c in inner])
            ends = [block.a] + [c[1] for c in inner] + [block.b]
            for k, piece in enumerate(pieces):
                part = Block(piece, block.cls, block.rw, block.flags, block.name, block.width,
                             block.lanes, block.speed, block.levels, block.source)
                part.tags, part.crossing = block.tags, block.crossing
                part.a, part.b = resolve(ends[k]), resolve(ends[k + 1])
                out.append(part)
        return out


def cut_line(points, alongs):
    """`points` cut at each of `alongs` (metres along, sorted): the pieces, in order."""
    pieces = []
    current = [points[0]]
    travelled = 0.0
    cuts = list(alongs)
    for a, b in zip(points, points[1:]):
        piece = dist(a, b)
        while cuts and cuts[0] <= travelled + piece:
            t = 0 if piece == 0 else (cuts[0] - travelled) / piece
            p = (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]))
            current.append(p)
            pieces.append(current)
            current = [p]
            cuts.pop(0)
        current.append(b)
        travelled += piece
    pieces.append(current)
    return [[q for i, q in enumerate(piece) if i == 0 or q != piece[i - 1]] for piece in pieces]


def point_key(p, level, tag="j"):
    return (tag, round(p[0], 2), round(p[1], 2), level)


def join_crossings(blocks, splits, osm_from):
    """OSM paths at grade crossing the city's streets and paths: a junction where they
    cross, cutting both."""
    grid = Grid(50)
    for index, block in enumerate(blocks[:osm_from]):
        if block.cls in (WALK, PATH_) and block.levels == (GRADE, GRADE):
            grid.add(index, block.points)
    count = 0
    for index in range(osm_from, len(blocks)):
        block = blocks[index]
        if block.levels != (GRADE, GRADE) or is_pedestrian(block):
            continue
        along_osm = 0.0
        for a, b in zip(block.points, block.points[1:]):
            for other in grid.near(a, dist(a, b) + 1):
                line = blocks[other].points
                along_other = 0.0
                for c, d in zip(line, line[1:]):
                    hit = segment_intersection(a, b, c, d)
                    if hit:
                        p, t, u = hit
                        j = point_key(p, GRADE)
                        splits.add(index, along_osm + t * dist(a, b), j)
                        splits.add(other, along_other + u * dist(c, d), j)
                        count += 1
                    along_other += dist(c, d)
            along_osm += dist(a, b)
    return count


def join_loose_ends(blocks, splits, degree, radius, which, onto=None):
    """Each loose end (a junction only one block meets) of `which` blocks within `radius`
    of another walkable block (of those `onto` allows): a connector to the nearest point on
    it, cutting it there."""
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.cls in (WALK, PATH_) and (onto is None or onto(block)):
            grid.add(index, block.points)
    connectors = []
    for index, block in enumerate(blocks):
        if not which(block):
            continue
        for end, p in ((block.a, block.points[0]), (block.b, block.points[-1])):
            if degree[end] != 1:
                continue
            best = None
            for other in grid.near(p, radius):
                if other == index:
                    continue
                o = blocks[other]
                if end in (o.a, o.b):
                    continue
                hit = nearest_on(o.points, p)
                if hit and hit[1] <= radius and (best is None or hit[1] < best[1][1]):
                    best = (other, hit)
            if best is None:
                continue
            other, (q, off, along, _) = best
            o = blocks[other]
            level = o.levels[0] if o.levels[0] == o.levels[1] else GRADE
            total = polyline_length(o.points)
            # At one of its ends, join there rather than cut
            if along < 1.0:
                j = o.a
            elif along > total - 1.0:
                j = o.b
            else:
                j = point_key(q, level)
                splits.add(other, along, j)
            if off > 0.5:
                link = Block([p, q], PATH_, PATH, CONNECTOR | CAR_FREE, "", 0.0, 0, 0, (level, level), "link")
                link.a, link.b = end, j
                connectors.append(link)
            else:
                # Close enough to be the same point: the end is the junction
                if end == block.a:
                    block.a = j
                else:
                    block.b = j
    return connectors


def degrees(blocks, classes=(WALK, PATH_, ARM)):
    count = Counter()
    for block in blocks:
        if block.cls in classes:
            count[block.a] += 1
            count[block.b] += 1
    return count


# MARK: OSM's sidewalks and crosswalks

PEDESTRIAN = OSM_SIDEWALK | CROSSWALK | ISLAND


def is_pedestrian(block):
    """One of OSM's sidewalks, crosswalks or traffic islands."""
    return bool(block.flags & PEDESTRIAN)


def mark_covered(blocks):
    """The city's streets' sides an OSM sidewalk runs along (most of the way): walked on
    OSM's, not as the city's side. Where both are, the street's crossed at OSM's crosswalks."""
    lines = {}
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.flags & OSM_SIDEWALK:
            lines[index] = block.points
            grid.add(index, block.points)
    counts = Counter()
    for block in blocks:
        if block.cls != WALK or block.source != "cscl":
            continue
        total = polyline_length(block.points)
        if total < 1:
            continue
        reach = (block.width / 2 if block.width else 6.0) + COVER_REACH
        hits = [0, 0]
        for share in COVER_SAMPLES:
            p, heading = point_along(block.points, share * total)
            d = (math.sin(math.radians(heading)), math.cos(math.radians(heading)))
            seen = [False, False]
            for index in grid.near(p, reach):
                q = nearest_on(lines[index], p)
                if not q or q[1] > reach:
                    continue
                line = lines[index]
                if turn_apart(heading, bearing(line[q[3]], line[q[3] + 1])) > PARALLEL:
                    continue
                # Left of the way the block goes, or right
                cross = d[0] * (q[0][1] - p[1]) - d[1] * (q[0][0] - p[0])
                seen[0 if cross > 0 else 1] = True
            for side in (0, 1):
                hits[side] += seen[side]
        for side, flag in ((0, COVERED_LEFT), (1, COVERED_RIGHT)):
            if hits[side] >= 2:
                block.flags |= flag
                counts[side] += 1
    print(f"  {counts[0] + counts[1]} sides of the city's streets have OSM's sidewalk along them")


def link_wedges(blocks):
    """The city's junctions where a street's side isn't OSM's joined to OSM's sidewalks
    there: each corner's wedge, between two streets, linked to the nearest OSM sidewalk in
    it within `WEDGE_LINK`, so walks pass between the city's corners and OSM's sidewalks.
    A link stays in its wedge, so it's never a way over a street."""
    lines = {}
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.flags & OSM_SIDEWALK:
            lines[index] = block.points
            grid.add(index, block.points)
    arms = defaultdict(list)
    for block in blocks:
        if block.source != "cscl" or block.cls not in (WALK, ARM):
            continue
        for j, line in ((block.a, block.points), (block.b, block.points[::-1])):
            arms[j].append((heading_out(line), block))
    splits = Splits()
    links = []
    for j, out in arms.items():
        if j[-1] != GRADE or len(out) < 2:
            continue
        # Only where a street here isn't OSM's both sides
        if all(b.flags & COVERED_LEFT and b.flags & COVERED_RIGHT for _, b in out if b.cls == WALK):
            continue
        origin = out[0][1].points[0] if out[0][1].a == j else out[0][1].points[-1]
        headings = sorted(h for h, _ in out)
        best = {}
        for index in grid.near(origin, WEDGE_LINK):
            q = nearest_on(lines[index], origin)
            if not q or q[1] > WEDGE_LINK or q[1] < 0.5:
                continue
            h = bearing(origin, q[0])
            # The wedge it's in: after the last arm clockwise before it
            wedge = max((k for k, a in enumerate(headings) if a <= h), default=len(headings) - 1)
            start, end = headings[wedge], headings[(wedge + 1) % len(headings)]
            spread = (end - start) % 360 or 360
            if min((h - start) % 360, (end - h) % 360) < min(10, spread / 4):
                continue
            if wedge not in best or q[1] < best[wedge][1][1]:
                best[wedge] = (index, q)
        for index, (point, off, along, _) in best.values():
            target = point_key(point, GRADE, "w")
            splits.add(index, along, target)
            link = Block([origin, point], PATH_, PATH, CONNECTOR | CAR_FREE, "", 0.0, 0, 0, (GRADE, GRADE), "link")
            link.a, link.b = j, target
            links.append(link)
    blocks[:] = splits.apply(blocks) + links
    print(f"  {len(links)} links from the city's corners to OSM's sidewalks")


def crossing_attributes(blocks, signals):
    """Each OSM crosswalk's street (the city's block it goes over, the widest), and what it
    has: a light (its tags, or a signal on it), a walk signal first or every car stopped
    (the city's lists), markings, an island, or a ramp it's over."""
    roads = Grid(50)
    for index, block in enumerate(blocks):
        if block.source == "cscl" and block.cls in (WALK, ARM) and block.levels == (GRADE, GRADE):
            roads.add(index, block.points)
    signal_grid = defaultdict(list)
    for p, kind in signals:
        signal_grid[(int(p[0] // 30), int(p[1] // 30))].append((p, kind))
    counts = Counter()
    for block in blocks:
        if not block.flags & CROSSWALK:
            continue
        tags = block.tags
        crossed = None
        for index in roads.near(block.points[0], polyline_length(block.points) + 5):
            road = blocks[index]
            if any(segment_intersection(a, b, c, d) for a, b in zip(block.points, block.points[1:])
                   for c, d in zip(road.points, road.points[1:])):
                if crossed is None or road.width > crossed.width:
                    crossed = road
        bits = 0
        if crossed is not None:
            block.width, block.lanes, block.speed = crossed.width, crossed.lanes, crossed.speed
            block.flags |= crossed.flags & (ONE_WAY | TRUCK_LOCAL | TRUCK_THROUGH | BIKE_LANE)
            block.name = crossed.name
            # Over a highway or its ramp: not a driveway, or a U-turn through a median
            if crossed.cls == ARM and crossed.rw not in (DRIVEWAY, U_TURN):
                bits |= X_RAMP
        if tags.get("crossing") in ("traffic_signals", "pedestrian_signals") or tags.get("crossing:signals") == "yes":
            bits |= X_SIGNAL
        middle = point_along(block.points, polyline_length(block.points) / 2)[0]
        cx, cy = int(middle[0] // 30), int(middle[1] // 30)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for p, kind in signal_grid.get((cx + dx, cy + dy), ()):
                    d = dist(p, middle)
                    if d <= 12 and kind & 1:
                        bits |= X_SIGNAL
                    if d <= SIGNAL_REACH and kind & 2:
                        bits |= X_LEADING
                    if d <= SIGNAL_REACH and kind & 4:
                        bits |= X_EXCLUSIVE
        if bits & (X_LEADING | X_EXCLUSIVE) and not bits & X_SIGNAL:
            # The city's lists are of signalled junctions; only on one that is
            bits &= ~(X_LEADING | X_EXCLUSIVE)
        if tags.get("crossing") == "unmarked" or tags.get("crossing:markings") == "no":
            bits |= X_UNMARKED
        elif tags.get("crossing") in ("marked", "zebra", "uncontrolled", "traffic_signals") \
                or tags.get("crossing:markings") not in (None, "no"):
            bits |= X_MARKED
        if tags.get("crossing:island") == "yes" or tags.get("traffic_island"):
            bits |= X_ISLAND
        block.crossing = bits
        counts["signal" if bits & X_SIGNAL else "no signal"] += 1
        counts["over a ramp"] += bool(bits & X_RAMP)
        counts["street not found"] += crossed is None
    print(f"  crosswalks: {dict(counts)}")


def sidewalk_attributes(blocks):
    """Each OSM sidewalk's traffic, from the city's street it runs along: its speed, lanes,
    trucks, and an expressway over it."""
    lines = {}
    grid = Grid(50)
    for index, block in enumerate(blocks):
        # Streets on the ground: not a viaduct over the street the sidewalk's beside
        if block.source == "cscl" and block.cls == WALK and min(block.levels) <= GRADE:
            lines[index] = block.points
            grid.add(index, block.points)
    found = 0
    for block in blocks:
        if not block.flags & OSM_SIDEWALK:
            continue
        total = polyline_length(block.points)
        p, heading = point_along(block.points, total / 2)
        best = None
        for index in grid.near(p, 25):
            q = nearest_on(lines[index], p)
            line = lines[index]
            if q and q[1] <= 25 and turn_apart(heading, bearing(line[q[3]], line[q[3] + 1])) <= PARALLEL \
                    and (best is None or q[1] < best[1]):
                best = (index, q[1])
        if best:
            street = blocks[best[0]]
            block.speed, block.lanes = street.speed, street.lanes
            block.flags |= street.flags & (TRUCK_LOCAL | TRUCK_THROUGH | UNDER_ELEVATED)
            block.safety |= street.safety & S_CORRIDOR
            block.name = block.name or street.name
            found += 1
    print(f"  {found} OSM sidewalks take their street's traffic")


def corner_links(blocks, nodes, arms, corners):
    """Each corner of the city's junctions linked to the nearest junction of OSM's sidewalks
    within `CORNER_LINK`, on its side of every street (the link crossing none of the city's
    street lines): where a walk steps between the city's streets and OSM's sidewalks. By
    (junction, arm), the OSM junction's index."""
    roads = Grid(50)
    for index, block in enumerate(blocks):
        if block.source == "cscl" and block.cls in (WALK, ARM) and block.levels == (GRADE, GRADE):
            roads.add(index, block.points)

    def crosses_a_street(a, b):
        for index in roads.near(a, dist(a, b)):
            line = blocks[index].points
            if any(segment_intersection(a, b, c, d) for c, d in zip(line, line[1:])):
                return True
        return False

    pedestrian_nodes = defaultdict(list)
    for node, arm_list in arms.items():
        if arm_list and all(is_pedestrian(blocks[b]) for _, b, _ in arm_list) and \
                any(blocks[b].flags & OSM_SIDEWALK for _, b, _ in arm_list):
            p = nodes[node][1]
            pedestrian_nodes[(int(p[0] // CORNER_LINK), int(p[1] // CORNER_LINK))].append(node)
    links = {}
    for node, arm_list in arms.items():
        if not any(blocks[b].source == "cscl" and blocks[b].cls == WALK for _, b, _ in arm_list):
            continue
        origin = nodes[node][1]
        for slot, (dx, dy, kind) in enumerate(corners[node]):
            if kind == CORNER_REFUGE:
                continue
            p = (origin[0] + dx, origin[1] + dy)
            cx, cy = int(p[0] // CORNER_LINK), int(p[1] // CORNER_LINK)
            near = []
            for ddx in (-1, 0, 1):
                for ddy in (-1, 0, 1):
                    for other in pedestrian_nodes.get((cx + ddx, cy + ddy), ()):
                        d = dist(p, nodes[other][1])
                        if d <= CORNER_LINK:
                            near.append((d, other))
            for d, other in sorted(near):
                if not crosses_a_street(p, nodes[other][1]):
                    links[(node, slot)] = other
                    break
    print(f"  {len(links)} corners linked to OSM's sidewalks")
    return links


def mark_unmapped(blocks):
    """The city's streets' sides OSM doesn't have a sidewalk along where it maps sidewalks all
    round (within `UNMAPPED_NEAR` along most of it): most likely none worth walking, as under
    an expressway; a median's sides aside, which have none anyway."""
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.flags & OSM_SIDEWALK:
            grid.add(index, block.points)
    count = 0
    for block in blocks:
        if block.cls != WALK or block.source != "cscl" or block.flags & MEDIAN:
            continue
        total = polyline_length(block.points)
        if total < 1:
            continue
        for side, covered, bit in ((0, COVERED_LEFT, SIDE_LEFT_UNMAPPED), (1, COVERED_RIGHT, SIDE_RIGHT_UNMAPPED)):
            if block.flags & covered or block.offset[side] == 0:
                continue
            mapped_round = 0
            for share in COVER_SAMPLES:
                p, _ = point_along(block.points, share * total)
                if any(nearest_on(blocks[i].points, p)[1] <= UNMAPPED_NEAR for i in grid.near(p, UNMAPPED_NEAR)):
                    mapped_round += 1
            if mapped_round >= 2:
                block.unmapped |= bit
                count += 1
    print(f"  {count} sides of the city's streets OSM maps round but not along")


def build(cscl, osm_paths, osm_parks, osm_sidewalks, sidewalks_db, safety, target):
    """`safety`: a folder with the Vision Zero speed limits, priority corridors and
    intersections, crashes and curb ramps (vz_speed.geojson, vz_corridors.geojson,
    vz_intersections.json, crashes.json, ramps.json; see the module's notes)."""
    pedestrian = osm_sidewalks
    import sqlite3
    import struct
    from datetime import datetime, timezone

    print("reading the city's blocks")
    blocks = cscl_blocks(cscl)
    print(f"  {len(blocks)} blocks: {Counter(b.cls for b in blocks)}")
    print(f"  {join_walkway_levels(blocks)} points where walkway pieces at different levels join")
    fill_speeds(blocks, os.path.join(safety, "vz_speed.geojson"))
    mark_corridors(blocks, os.path.join(safety, "vz_corridors.geojson"))

    print("reading parks and OSM paths")
    parks = Parks(park_polygons(osm_parks))
    street_lines = {i: b.points for i, b in enumerate(blocks) if b.cls in (WALK, PATH_)}
    street_grid = Grid(50)
    for i, line in street_lines.items():
        street_grid.add(i, line)
    osm = osm_blocks(osm_paths, parks, street_lines, street_grid, pedestrian)
    osm_from = len(blocks)
    blocks += osm
    print(f"  of them OSM's sidewalks, crosswalks and islands: {sum(is_pedestrian(b) for b in osm)}")
    mark_covered(blocks)

    print("joining OSM paths where they cross the city's")
    splits = Splits()
    crossed = join_crossings(blocks, splits, osm_from)
    blocks = splits.apply(blocks)
    print(f"  {crossed} crossings")

    print("joining loose ends of paths and alleys")
    degree = degrees(blocks, (WALK, PATH_))
    splits = Splits()
    # OSM's sidewalks' gaps first, among themselves; then to the city's streets they aren't
    connectors = join_loose_ends(blocks, splits, degree, 3.0, is_pedestrian, is_pedestrian)
    connectors += join_loose_ends(
        blocks, splits, degree, OSM_JOIN, lambda b: b.source == "osm",
        lambda b: not (b.flags & COVERED_LEFT and b.flags & COVERED_RIGHT) and not b.flags & CROSSWALK)
    connectors += join_loose_ends(
        blocks, splits, degree, JOIN, lambda b: b.source == "cscl" and (b.cls == PATH_ or b.rw == ALLEY))
    blocks = splits.apply(blocks) + connectors
    print(f"  {len(connectors)} connectors")

    print("signals at junctions")
    sidewalks = Sidewalks(sidewalks_db)
    signals_at = signal_junctions(blocks, sidewalks.signals)

    nodes, arms = topology(blocks)
    print(f"  {len(nodes)} junctions, {len(blocks)} blocks, {sum(len(a) for a in arms.values())} arms")

    report_components(blocks)

    print("sidewalks either side")
    sides(blocks, sidewalks)
    print("corners")
    corners = place_corners(blocks, nodes, arms, sidewalks)
    mark_medians(blocks, nodes, arms, corners)
    mark_elevated(blocks)
    sidewalk_attributes(blocks)
    crossing_attributes(blocks, sidewalks.signals)
    links = corner_links(blocks, nodes, arms, corners)
    mark_unmapped(blocks)
    print("safety")
    safety_data = safety_at(blocks, nodes, arms, corners, safety)

    write(target, blocks, nodes, arms, corners, signals_at, links, safety_data)


# MARK: Safety data (Phase 6)

def read_points(path):
    """[(x, y), row] of a Socrata JSON export's rows with a point (the_geom, or latitude and
    longitude)."""
    out = []
    with open(path, encoding="utf-8") as file:
        for row in json.load(file):
            g = row.get("the_geom") or {}
            c = g.get("coordinates") if g.get("type") == "Point" else None
            if c is None and row.get("latitude") and row.get("longitude"):
                c = (float(row["longitude"]), float(row["latitude"]))
            if c is None or not c[0] or not c[1]:
                continue
            out.append((xy(float(c[0]), float(c[1])), row))
    return out


def read_lines(path):
    """[(points, properties)] of a GeoJSON file's lines, each part its own."""
    out = []
    with open(path, encoding="utf-8") as file:
        for feature in json.load(file)["features"]:
            g = feature.get("geometry") or {}
            parts = g.get("coordinates") or []
            if g.get("type") == "LineString":
                parts = [parts]
            for part in parts:
                points = [xy(c[0], c[1]) for c in part]
                if len(points) >= 2:
                    out.append((points, feature.get("properties") or {}))
    return out


def fill_speeds(blocks, path):
    """The city's streets with no posted speed: the Vision Zero speed limit layer's, from its
    line alongside."""
    lines = read_lines(path)
    grid = Grid(50)
    for i, (points, _) in enumerate(lines):
        grid.add(i, points)
    filled = 0
    for block in blocks:
        if block.source != "cscl" or block.cls != WALK or block.speed:
            continue
        p, heading = point_along(block.points, polyline_length(block.points) / 2)
        best = None
        for i in grid.near(p, SPEED_NEAR):
            line, props = lines[i]
            q = nearest_on(line, p)
            if q and q[1] <= SPEED_NEAR and turn_apart(heading, bearing(line[q[3]], line[q[3] + 1])) <= PARALLEL \
                    and (best is None or q[1] < best[0]):
                speed = int(number(props.get("postvz_sl"), 0))
                if speed:
                    best = (q[1], speed)
        if best:
            block.speed = best[1]
            filled += 1
    print(f"  {filled} streets' speed limits filled in")


def mark_corridors(blocks, path):
    """The city's streets along a Vision Zero priority corridor."""
    lines = {i: points for i, (points, _) in enumerate(read_lines(path))}
    grid = Grid(50)
    for i, points in lines.items():
        grid.add(i, points)
    count = 0
    for block in blocks:
        if block.source == "cscl" and block.cls == WALK \
                and runs_alongside(block.points, grid, lines, CORRIDOR_NEAR, every=10, share=0.5):
            block.safety |= S_CORRIDOR
            count += 1
    print(f"  {count} streets on priority corridors")


def crash_count(points, grid, p, near=CRASH_NEAR):
    """Pedestrians hurt within `near` of `p`, each killed `KILLED_COUNTS`, at most 255."""
    total = 0
    cx, cy = int(p[0] // 50), int(p[1] // 50)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for q, hurt in grid.get((cx + dx, cy + dy), ()):
                if dist(p, q) <= near:
                    total += hurt
    return min(255, total)


def point_grid(points, size=50):
    grid = defaultdict(list)
    for p, value in points:
        grid[(int(p[0] // size), int(p[1] // size))].append((p, value))
    return grid


def safety_at(blocks, nodes, arms, corners, folder):
    """Each junction's priority bit and pedestrians hurt there, each corner's curb ramp, and
    the same for OSM's crosswalks (their blocks' `safety` and `crashes`). By node index, and
    by (node, slot)."""
    crashes = []
    for p, row in read_points(os.path.join(folder, "crashes.json")):
        hurt = int(number(row.get("number_of_pedestrians_injured"), 0)) \
            + KILLED_COUNTS * int(number(row.get("number_of_pedestrians_killed"), 0))
        if hurt:
            crashes.append((p, hurt))
    crash_grid = point_grid(crashes)
    priority = point_grid([(p, 1) for p, _ in read_points(os.path.join(folder, "vz_intersections.json"))])
    ramp_grid = point_grid([(p, 1) for p, _ in read_points(os.path.join(folder, "ramps.json"))])

    def any_near(grid, p, near):
        cx, cy = int(p[0] // 50), int(p[1] // 50)
        return any(dist(p, q) <= near for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                   for q, _ in grid.get((cx + dx, cy + dy), ()))

    node_safety, node_crashes, corner_ramp = {}, {}, {}
    for n, (j, origin) in enumerate(nodes):
        arm_list = arms.get(n, [])
        streets = sum(1 for _, b, _ in arm_list if blocks[b].source == "cscl" and blocks[b].cls in (WALK, ARM))
        # Junctions on the ground where city streets are crossed, the build's own too (a
        # signalled crosswalk mid-block, a path over a street): not OSM's sidewalks' alone
        if j[-1] != GRADE or streets < 2:
            continue
        if any_near(priority, origin, PRIORITY_NEAR):
            node_safety[n] = N_PRIORITY
        node_crashes[n] = crash_count(crashes, crash_grid, origin)
        for slot, (dx, dy, kind) in enumerate(corners.get(n, [])):
            if kind == CORNER_SIDEWALK and any_near(ramp_grid, (origin[0] + dx, origin[1] + dy), RAMP_NEAR):
                corner_ramp[(n, slot)] = 1
    for block in blocks:
        if not block.flags & CROSSWALK:
            continue
        middle = point_along(block.points, polyline_length(block.points) / 2)[0]
        block.crashes = crash_count(crashes, crash_grid, middle)
        if any_near(priority, middle, PRIORITY_NEAR):
            block.safety |= S_PRIORITY
        if any_near(ramp_grid, block.points[0], RAMP_NEAR):
            block.safety |= S_RAMP_A
        if any_near(ramp_grid, block.points[-1], RAMP_NEAR):
            block.safety |= S_RAMP_B
    print(f"  {len(node_safety)} junctions at priority intersections, {sum(1 for v in node_crashes.values() if v)} "
          f"with pedestrians hurt, {len(corner_ramp)} corners with curb ramps, "
          f"{sum(1 for b in blocks if b.safety & (S_RAMP_A | S_RAMP_B) == (S_RAMP_A | S_RAMP_B))} crosswalks ramped both ends")
    return node_safety, node_crashes, corner_ramp


def signal_junctions(blocks, signals):
    """Each signal's kind on the nearest grade junction within `SIGNAL_REACH` where three
    or more blocks meet; one away from junctions but by a street cuts it there, a
    signalled crosswalk mid-block. Kinds by junction key."""
    ends = defaultdict(list)
    degree = degrees([b for b in blocks if b.source == "cscl"])
    junction_grid = defaultdict(list)
    for block in blocks:
        for j, p in ((block.a, block.points[0]), (block.b, block.points[-1])):
            # The city's junctions, not OSM's sidewalks' corners
            if j[-1] == GRADE and degree[j] >= 3 and j not in ends and not isinstance(j[0], str):
                ends[j] = p
                junction_grid[(int(p[0] // 50), int(p[1] // 50))].append(j)
    at = defaultdict(int)
    loose = []
    for p, kind in signals:
        best = None
        cx, cy = int(p[0] // 50), int(p[1] // 50)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in junction_grid.get((cx + dx, cy + dy), ()):
                    d = dist(p, ends[j])
                    if d <= SIGNAL_REACH and (best is None or d < best[0]):
                        best = (d, j)
        if best:
            at[best[1]] |= kind
        else:
            loose.append((p, kind))
    # Mid-block signals: cut the street they're on
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.cls == WALK and block.levels == (GRADE, GRADE):
            grid.add(index, block.points)
    splits = Splits()
    mid = 0
    for p, kind in loose:
        best = None
        for other in grid.near(p, MID_BLOCK_SIGNAL):
            hit = nearest_on(blocks[other].points, p)
            if hit and hit[1] <= MID_BLOCK_SIGNAL and (best is None or hit[1] < best[1][1]):
                best = (other, hit)
        if best:
            other, (q, _, along, _) = best
            total = polyline_length(blocks[other].points)
            if 3 < along < total - 3:
                j = point_key(q, GRADE, "s")
                splits.add(other, along, j)
                at[j] |= kind
                mid += 1
    blocks[:] = splits.apply(blocks)
    print(f"  {len(signals)} signals: {len(signals) - len(loose)} at junctions, {mid} mid-block crosswalks, "
          f"{len(loose) - mid} not by a street")
    return at


def topology(blocks):
    """Junctions in a fixed order, and each one's arms clockwise: (block index, 0 at its
    start or 1 at its end), by the bearing of the block's first 10 m from the junction."""
    order = {}
    nodes = []
    for block in blocks:
        for j, p in ((block.a, block.points[0]), (block.b, block.points[-1])):
            if j not in order:
                order[j] = len(nodes)
                nodes.append((j, p))
    # Each block's line ends exactly at its junctions: joins made "close enough" moved its
    # ends' junctions, not its points
    for block in blocks:
        block.points[0] = nodes[order[block.a]][1]
        block.points[-1] = nodes[order[block.b]][1]
    arms = defaultdict(list)
    for index, block in enumerate(blocks):
        for end in (0, 1):
            j = block.a if end == 0 else block.b
            line = block.points if end == 0 else block.points[::-1]
            arms[order[j]].append((heading_out(line), index, end))
    for node in arms:
        arms[node].sort()
    return nodes, arms


def heading_out(line, reach=10.0):
    """The bearing a line leaves its first point by, over its first `reach` metres."""
    start = line[0]
    travelled = 0.0
    for a, b in zip(line, line[1:]):
        piece = dist(a, b)
        if travelled + piece >= reach:
            t = (reach - travelled) / piece
            return bearing(start, (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])))
        travelled += piece
    return bearing(start, line[-1])


def parts(blocks, nodes, links=None):
    """Each junction's walkable part (streets and paths joined up, and the city's corners to
    OSM's sidewalks by `links`), numbered biggest first, so the router can keep a walk's two
    ends in one."""
    order = {j: n for n, (j, _) in enumerate(nodes)}
    parent = list(range(len(nodes)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for block in blocks:
        if block.cls in (WALK, PATH_):
            ra, rb = find(order[block.a]), find(order[block.b])
            if ra != rb:
                parent[ra] = rb
    for (node, _), other in (links or {}).items():
        ra, rb = find(node), find(other)
        if ra != rb:
            parent[ra] = rb
    roots = [find(n) for n in range(len(nodes))]
    rank = {root: i for i, (root, _) in enumerate(Counter(roots).most_common())}
    return [rank[root] for root in roots]


def report_components(blocks):
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for block in blocks:
        if block.cls in (WALK, PATH_):
            ra, rb = find(block.a), find(block.b)
            if ra != rb:
                parent[ra] = rb
    sizes = Counter(find(j) for j in list(parent))
    top = sizes.most_common(6)
    total = sum(sizes.values())
    print(f"  walkable parts: {len(sizes)}; biggest {[n for _, n in top]} of {total} junctions; "
          f"parts under 10 junctions: {sum(1 for n in sizes.values() if n < 10)}")


def sides(blocks, sidewalks):
    """Each walkable street's sidewalk each side: metres from its line to the sidewalk's
    middle, by ray casting at a quarter, half and three quarters along; 0 for none. A
    sidewalk's the street's own unless, at ground level, its other half (a divided road's,
    across the median) or a highway is between them, within `SIDEWALK_REACH`; a side street
    joining at a slant, alongside for a while, isn't. Where the city's line for the street
    runs over its sidewalk, as under an expressway, that's it."""
    roads = Grid(50)
    lines = {}
    for index, block in enumerate(blocks):
        if block.cls in (WALK, ARM) and block.levels == (GRADE, GRADE):
            roads.add(index, block.points)
            lines[index] = block.points
    for count, block in enumerate(blocks):
        if count % 20000 == 0:
            print(f"    {count}/{len(blocks)}")
        if block.cls != WALK:
            continue
        total = polyline_length(block.points)
        found = [[], []]
        for share in (0.25, 0.5, 0.75):
            p, heading = point_along(block.points, share * total)
            # A bearing's direction is (sin, cos); its left (-cos, sin)
            direction = (math.sin(math.radians(heading)), math.cos(math.radians(heading)))
            left = (-direction[1], direction[0])
            for side, d in ((0, left), (1, (-left[0], -left[1]))):
                hit = own_sidewalk(sidewalks, p, d)
                if hit and hit[1] <= SIDEWALK_REACH and not road_between(p, d, hit[1], count, blocks, roads, lines):
                    found[side].append(hit[0])
        for side in (0, 1):
            if len(found[side]) >= 2:
                values = sorted(found[side])
                block.offset[side] = values[len(values) // 2]


def own_sidewalk(sidewalks, p, d):
    """The sidewalk from `p` going `d`: metres to its middle, and to its near edge. From
    inside one (a street's line drawn over its sidewalk), that one, if it reaches that way."""
    if sidewalks.inside(p):
        edges = sidewalks.hits(p, d, RAY)
        out = edges[0] if edges else RAY
        if out >= 1.5:
            return min(out / 2, 2.5), 0.0
        # Only just on it: the next one out that way
        beyond = sidewalks.sidewalk((p[0] + d[0] * (out + 0.05), p[1] + d[1] * (out + 0.05)), d)
        return (beyond[0] + out, beyond[1] + out) if beyond else None
    return sidewalks.sidewalk(p, d)


def road_between(p, d, metres, own, blocks, roads, lines):
    """Whether block `own`'s other half (a block of the same name) or a highway or ramp,
    at ground level, crosses the way from `p` going `d` for `metres`."""
    q = (p[0] + d[0] * metres, p[1] + d[1] * metres)
    name = blocks[own].name
    for index in roads.near(p, metres):
        other = blocks[index]
        if index == own or not (other.name == name or other.cls == ARM and other.rw != DRIVEWAY):
            continue
        line = lines[index]
        for a, b in zip(line, line[1:]):
            if segment_intersection(p, q, a, b):
                return True
    return False


def point_along(points, metres):
    """The point `metres` along a polyline, and the bearing there."""
    travelled = 0.0
    for a, b in zip(points, points[1:]):
        piece = dist(a, b)
        if travelled + piece >= metres and piece > 0:
            t = (metres - travelled) / piece
            return (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])), bearing(a, b)
        travelled += piece
    return points[-1], bearing(points[-2], points[-1])


def side_offset(block, side):
    """Metres from a block's line its way along `side` (0 left, 1 right) keeps: a street's
    sidewalk middle, or its curb where there's none; a highway's or ramp's curb (a corner
    beside one is off it); 0 for a path."""
    if block.cls == ARM:
        return max(block.width / 2, 3.0)
    if block.cls != WALK:
        return 0.0
    if block.offset[side] > 0:
        return block.offset[side]
    return max(block.width / 2, 2.0)


def place_corners(blocks, nodes, arms, sidewalks):
    """Each junction's corners: the wedge clockwise from each arm to the next, where the
    two sides' lines meet (or along the wedge's middle onto a sidewalk), and what's there.
    By junction, a list of (dx, dy, kind) in the arms' order."""
    corners = {}
    for node, arm_list in arms.items():
        _, origin = nodes[node]
        k = len(arm_list)
        if all(blocks[b].cls == ARM for _, b, _ in arm_list):
            # Only highways and ramps meet here: nobody walks to it
            corners[node] = [(0.0, 0.0, CORNER_NONE)] * k
            continue
        out = []
        for i in range(k):
            h1, b1, e1 = arm_list[i]
            h2, b2, e2 = arm_list[(i + 1) % k] if k > 1 else (h1 + 180, b1, e1)
            first, second = blocks[b1], blocks[b2]
            # The wedge from arm 1 clockwise to arm 2: arm 1's right (its own clockwise side),
            # arm 2's left. Going out along an arm from its start (end 0) its right is side 1.
            o1 = side_offset(first, 1 if e1 == 0 else 0)
            o2 = side_offset(second, 0 if e2 == 0 else 1)
            if first.cls == PATH_ and second.cls == PATH_ or k == 1 and first.cls != WALK:
                out.append((0.0, 0.0, CORNER_PATH))
                continue
            if k == 1:
                # A dead end: one corner, at the end of the street, where its sides meet
                out.append((0.0, 0.0, CORNER_SIDEWALK if sidewalks.inside(origin) else CORNER_NONE))
                continue
            p = corner_point(origin, h1, o1, h2, o2)
            kind = CORNER_SIDEWALK if sidewalks.inside(p) else CORNER_NONE
            if kind == CORNER_NONE:
                # Out along the wedge's middle, onto a sidewalk if there's one close
                spread = (h2 - h1) % 360 or 360
                middle = math.radians(h1 + spread / 2)
                for r in (2, 4, 6, 8, 10, 13, 16, 20):
                    q = (origin[0] + r * math.sin(middle), origin[1] + r * math.cos(middle))
                    if sidewalks.inside(q):
                        p, kind = q, CORNER_SIDEWALK
                        break
            out.append((p[0] - origin[0], p[1] - origin[1], kind))
        corners[node] = out
    return corners


def corner_point(origin, h1, o1, h2, o2):
    """Where the line `o1` metres right of bearing `h1` from `origin` meets the line `o2`
    metres left of `h2`; along the wedge's middle where they're near parallel."""
    def unit(h):
        r = math.radians(h)
        return (math.sin(r), math.cos(r))
    d1, d2 = unit(h1), unit(h2)
    right1 = (d1[1], -d1[0])
    left2 = (-d2[1], d2[0])
    p1 = (origin[0] + right1[0] * o1, origin[1] + right1[1] * o1)
    p2 = (origin[0] + left2[0] * o2, origin[1] + left2[1] * o2)
    den = d1[0] * d2[1] - d1[1] * d2[0]
    spread = (h2 - h1) % 360
    if abs(den) > 0.25 and spread < 180:
        w = (p2[0] - p1[0], p2[1] - p1[1])
        t = (w[0] * d2[1] - w[1] * d2[0]) / den
        q = (p1[0] + t * d1[0], p1[1] + t * d1[1])
        if dist(q, origin) <= 3 * max(o1, o2, 1) + 5:
            return q
    # Near parallel, or the outside of a bend: along the wedge's middle
    middle = math.radians(h1 + (spread or 360) / 2)
    r = max(o1, o2, 1.0) / max(math.sin(math.radians(min(spread, 360 - spread) / 2 or 90)), 0.3)
    r = min(r, 3 * max(o1, o2, 1) + 5)
    return (origin[0] + r * math.sin(middle), origin[1] + r * math.cos(middle))


def mark_medians(blocks, nodes, arms, corners):
    """The bit of a cross street between a divided road's two halves: short, with the same
    one-way road's name at both its ends, and maybe cut in pieces where it passes under
    something (the city cuts a street where an expressway goes over it). Its pieces are
    flagged, and the corners beside it at each end, and either side where it's cut, are
    refuges (in the median) where they aren't on a sidewalk."""
    order = {j: n for n, (j, _) in enumerate(nodes)}
    names_at = {}
    for node, arm_list in arms.items():
        names_at[node] = Counter(blocks[b].name for _, b, _ in arm_list
                                 if blocks[b].cls == WALK and blocks[b].flags & ONE_WAY)

    def through(node, came):
        """The block on past a node only this street's two blocks meet at, or None."""
        arm_list = arms[node]
        if len(arm_list) != 2:
            return None
        other = [(b, e) for _, b, e in arm_list if b != came]
        if len(other) != 1 or blocks[other[0][0]].cls != WALK:
            return None
        return other[0]

    seen = set()
    count = 0
    for index, block in enumerate(blocks):
        if index in seen or block.cls != WALK:
            continue
        # The chain this block's part of, end to end through two-block nodes
        chain = [index]
        ends = []
        for node in (order[block.a], order[block.b]):
            came, here = index, node
            while True:
                nxt = through(here, came)
                if nxt is None or nxt[0] in chain:
                    break
                chain.append(nxt[0])
                came = nxt[0]
                b = blocks[came]
                here = order[b.b] if order[b.a] == here else order[b.a]
            ends.append((here, came))
        seen.update(chain)
        length = sum(polyline_length(blocks[i].points) for i in chain)
        if length > MEDIAN_LINK:
            continue
        (a, block_a), (b, block_b) = ends
        if a == b:
            continue
        shared = {name for name, n in names_at[a].items() if n >= 2 and name != block.name} & \
                 {name for name, n in names_at[b].items() if n >= 2 and name != block.name}
        if not shared:
            continue
        count += 1
        for i in chain:
            blocks[i].flags |= MEDIAN
        # Refuges: beside the chain at its two ends, and at every corner where it's cut
        chained = set(chain)
        touched = {a, b}
        for i in chain:
            touched.update((order[blocks[i].a], order[blocks[i].b]))
        # The median's middle: halfway between the road's halves, along the cross street
        middle = ((nodes[a][1][0] + nodes[b][1][0]) / 2, (nodes[a][1][1] + nodes[b][1][1]) / 2)
        for node in touched:
            arm_list = arms[node]
            k = len(arm_list)
            origin = nodes[node][1]
            for slot, (heading, bi, _) in enumerate(arm_list):
                if bi not in chained:
                    continue
                for corner, side in ((slot, 1), ((slot - 1) % k, -1)):
                    dx, dy, kind = corners[node][corner]
                    if kind != CORNER_NONE:
                        continue
                    if node in (a, b):
                        # Out of the road: in the median, beside the cross street on the
                        # corner's side of it (clockwise of its arm, or before), where its
                        # crosswalk lands, not wherever the halves' lines put it
                        h = math.radians(heading)
                        right = (math.cos(h), -math.sin(h))
                        dx = middle[0] + side * REFUGE_SIDE * right[0] - origin[0]
                        dy = middle[1] + side * REFUGE_SIDE * right[1] - origin[1]
                    corners[node][corner] = (dx, dy, CORNER_REFUGE)
    print(f"  {count} median links")


def mark_elevated(blocks):
    """Streets with an elevated road over them most of the way: an expressway or ramp off
    the ground within `ELEVATED_NEAR` and running alongside."""
    lines = {}
    grid = Grid(50)
    for index, block in enumerate(blocks):
        if block.cls == ARM and min(block.levels) > GRADE:
            lines[index] = block.points
            grid.add(index, block.points)
    count = 0
    for block in blocks:
        if block.cls == WALK and runs_alongside(block.points, grid, lines, ELEVATED_NEAR, every=10, share=0.5):
            block.flags |= UNDER_ELEVATED
            count += 1
    print(f"  {count} streets under an elevated road")


# Each array's element type (Python's `array` codes; all little-endian in the file)
ARRAY_TYPES = {
    "node_lat": "i", "node_lon": "i", "node_level": "B", "node_signal": "B", "node_part": "I",
    "arm_start": "I", "arm_block": "I", "arm_end": "B",
    "corner_dx": "h", "corner_dy": "h", "corner_kind": "B",
    "block_a": "I", "block_b": "I", "block_slot_a": "H", "block_slot_b": "H",
    "block_class": "B", "block_rw": "B", "block_flags": "H", "block_name": "I",
    "block_width": "H", "block_lanes": "B", "block_speed": "B", "block_length": "I",
    "block_offset_left": "B", "block_offset_right": "B",
    "geom_start": "I", "geom_lat": "i", "geom_lon": "i",
    "block_crossing": "B",
    "corner_link": "I",
    "block_sides": "B",
    "node_safety": "B", "node_crashes": "B", "corner_ramp": "B", "block_safety": "B", "block_crashes": "B",
    # In tiles only
    "node_id": "I", "node_arms": "H", "block_id": "I", "block_whole": "B",
}
NO_LINK = 0xFFFFFFFF


TILE = 2000.0  # metres a tile of the graph is across, east and north


def tile_of(p):
    return (int(math.floor(p[0] / TILE)), int(math.floor(p[1] / TILE)))


def tile_arrays(arrays, nodes):
    """The graph's arrays cut into tiles, for the app to read only those round a walk. A tile
    has its junctions, each with all its arms and their corners, and every block that ends
    at one of them, with its line (a block between two tiles in both), all by global ids."""
    from array import array
    node_tile = [tile_of(p) for _, p in nodes]
    by_tile = defaultdict(list)
    for n, t in enumerate(node_tile):
        by_tile[t].append(n)
    block_tiles = defaultdict(set)
    for b in range(len(arrays["block_a"])):
        block_tiles[node_tile[arrays["block_a"][b]]].add(b)
        block_tiles[node_tile[arrays["block_b"][b]]].add(b)
    node_fields = ["node_lat", "node_lon", "node_level", "node_signal", "node_part", "node_safety", "node_crashes"]
    arm_fields = ["arm_block", "arm_end", "corner_dx", "corner_dy", "corner_kind", "corner_link", "corner_ramp"]
    block_fields = ["block_a", "block_b", "block_slot_a", "block_slot_b", "block_class", "block_rw",
                    "block_flags", "block_name", "block_width", "block_lanes", "block_speed", "block_length",
                    "block_offset_left", "block_offset_right", "block_crossing", "block_sides",
                    "block_safety", "block_crashes"]
    tiles = {}
    for t, members in by_tile.items():
        out = {name: array(ARRAY_TYPES[name]) for name in node_fields + arm_fields + block_fields}
        out["node_id"] = array("I")
        out["node_arms"] = array("H")
        out["block_id"] = array("I")
        out["block_whole"] = array("B")
        out["geom_start"] = array("I")
        out["geom_lat"] = array("i")
        out["geom_lon"] = array("i")
        for n in members:
            out["node_id"].append(n)
            for name in node_fields:
                out[name].append(arrays[name][n])
            first, last = arrays["arm_start"][n], arrays["arm_start"][n + 1]
            out["node_arms"].append(last - first)
            for name in arm_fields:
                out[name].extend(arrays[name][first:last])
        for b in sorted(block_tiles[t]):
            out["block_id"].append(b)
            for name in block_fields:
                out[name].append(arrays[name][b])
            out["geom_start"].append(len(out["geom_lat"]))
            g0, g1 = arrays["geom_start"][b], arrays["geom_start"][b + 1]
            # Its whole line where it leaves the tile; where both its ends are here, only the
            # points between them (its ends are its junctions'): first, then changes
            whole = node_tile[arrays["block_a"][b]] != t or node_tile[arrays["block_b"][b]] != t
            out["block_whole"].append(1 if whole else 0)
            if whole:
                out["geom_lat"].extend(arrays["geom_lat"][g0:g1])
                out["geom_lon"].extend(arrays["geom_lon"][g0:g1])
            elif g1 - g0 > 2:
                # Absolute points between, made changes again from the first of them
                lat = lon = 0
                points = []
                for k in range(g0, g1):
                    lat += arrays["geom_lat"][k]
                    lon += arrays["geom_lon"][k]
                    points.append((lat, lon))
                last = (0, 0)
                for p in points[1:-1]:
                    out["geom_lat"].append(p[0] - last[0])
                    out["geom_lon"].append(p[1] - last[1])
                    last = p
        out["geom_start"].append(len(out["geom_lat"]))
        tiles[t] = out
    return tiles


def write(target, blocks, nodes, arms, corners, signals_at, links, safety_data):
    """The graph as fixed-width little-endian arrays (`WalkGraph.swift` reads them)."""
    import sqlite3
    from array import array
    from datetime import datetime, timezone

    order = {j: n for n, (j, _) in enumerate(nodes)}
    names = {}

    def name_id(name):
        if name not in names:
            names[name] = len(names)
        return names[name]

    name_id("")
    node_safety, node_crashes, corner_ramp = safety_data
    arrays = {k: array(t) for k, t in ARRAY_TYPES.items()}
    part = parts(blocks, nodes, links)
    slots = {}
    for n, (j, p) in enumerate(nodes):
        lon, lat = lonlat(*p)
        arrays["node_lat"].append(round(lat * 1e6))
        arrays["node_lon"].append(round(lon * 1e6))
        arrays["node_level"].append(max(0, min(255, j[-1])))
        arrays["node_signal"].append(signals_at.get(j, 0))
        arrays["node_part"].append(part[n])
        arrays["node_safety"].append(node_safety.get(n, 0))
        arrays["node_crashes"].append(node_crashes.get(n, 0))
        arrays["arm_start"].append(len(arrays["arm_block"]))
        arm_list = arms.get(n, [])
        for slot, (_, index, end) in enumerate(arm_list):
            arrays["arm_block"].append(index)
            arrays["arm_end"].append(end)
            slots[(index, end)] = slot
            dx, dy, kind = corners[n][slot]
            arrays["corner_dx"].append(max(-32768, min(32767, round(dx * 10))))
            arrays["corner_dy"].append(max(-32768, min(32767, round(dy * 10))))
            arrays["corner_kind"].append(kind)
            arrays["corner_link"].append(links.get((n, slot), NO_LINK))
            arrays["corner_ramp"].append(corner_ramp.get((n, slot), 0))
    arrays["arm_start"].append(len(arrays["arm_block"]))
    for index, block in enumerate(blocks):
        arrays["block_a"].append(order[block.a])
        arrays["block_b"].append(order[block.b])
        arrays["block_slot_a"].append(slots[(index, 0)])
        arrays["block_slot_b"].append(slots[(index, 1)])
        arrays["block_class"].append(CLASS_CODE[block.cls])
        arrays["block_rw"].append(block.rw)
        arrays["block_flags"].append(block.flags)
        arrays["block_name"].append(name_id(block.name))
        arrays["block_width"].append(min(65535, round(block.width * 10)))
        arrays["block_lanes"].append(min(255, block.lanes))
        arrays["block_speed"].append(min(255, block.speed))
        arrays["block_length"].append(round(polyline_length(block.points) * 10))
        arrays["block_offset_left"].append(min(255, round(block.offset[0] * 4)))
        arrays["block_offset_right"].append(min(255, round(block.offset[1] * 4)))
        arrays["block_crossing"].append(block.crossing)
        arrays["block_sides"].append(getattr(block, "unmapped", 0))
        arrays["block_safety"].append(block.safety)
        arrays["block_crashes"].append(block.crashes)
        # Each block's line: its first point, then each one's change from the one before
        arrays["geom_start"].append(len(arrays["geom_lat"]))
        last = (0, 0)
        for p in block.points:
            lon, lat = lonlat(*p)
            here = (round(lat * 1e6), round(lon * 1e6))
            arrays["geom_lat"].append(here[0] - last[0])
            arrays["geom_lon"].append(here[1] - last[1])
            last = here
    arrays["geom_start"].append(len(arrays["geom_lat"]))

    tiles = tile_arrays(arrays, nodes)
    if os.path.exists(target):
        os.remove(target)
    db = sqlite3.connect(target)
    db.executescript("""
        CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE names (id INTEGER PRIMARY KEY, label TEXT NOT NULL);
        CREATE TABLE tiles (x INTEGER NOT NULL, y INTEGER NOT NULL, name TEXT NOT NULL, data BLOB NOT NULL,
                            PRIMARY KEY (x, y, name));
    """)
    db.executemany("INSERT INTO names VALUES (?, ?)", [(i, n) for n, i in names.items()])
    rows = []
    for (tx, ty), tile in tiles.items():
        for name, a in tile.items():
            if sys.byteorder != "little":
                a.byteswap()
            rows.append((tx, ty, name, deflate(a.tobytes())))
    db.executemany("INSERT INTO tiles VALUES (?, ?, ?, ?)", rows)
    db.executemany("INSERT INTO info VALUES (?, ?)", [
        ("format", str(FORMAT)),
        ("arrays", "by tile (TILE metres of the plane from ORIGIN), little-endian, raw deflate; "
                   "ids global; geom_lat/geom_lon each block's first point then changes"),
        ("tile", str(TILE)),
        ("origin", f"{ORIGIN[1]},{ORIGIN[0]}"),
        ("source", "NYC Street Centerline (CSCL, data.cityofnewyork.us inkn-q76z); "
                   "OpenStreetMap paths, sidewalks and crosswalks (ODbL); NYC Planimetric sidewalks; "
                   "signals as sidewalks.sqlite; NYC DOT Vision Zero speed limits, priority corridors and "
                   "intersections; NYPD motor vehicle collisions; NYC DOT pedestrian ramps"),
        ("built", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        ("nodes", str(len(nodes))),
        ("blocks", str(len(blocks))),
        ("arms", str(len(arrays["arm_block"]))),
        ("tiles", str(len(tiles))),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()
    sizes = {k: len(a) * a.itemsize for k, a in arrays.items()}
    print(f"{target}: {os.path.getsize(target) / 1e6:.1f} MB ({sum(sizes.values()) / 1e6:.1f} MB inflated); "
          f"biggest arrays {sorted(((round(v / 1e6, 2), k) for k, v in sizes.items()), reverse=True)[:5]}")
    print(f"  corners: {Counter(arrays['corner_kind'])} (0 none, 1 sidewalk, 2 refuge, 3 path)")
    print(f"  signalled junctions: {sum(1 for v in arrays['node_signal'] if v)}")


def deflate(data):
    """`data` raw-deflated, as Apple's Compression framework's zlib inflates it."""
    import zlib
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def read_graph(walkgraph):
    """The built graph's tiles put back together as the city's arrays, by name, as `write`
    had them (its lines' points whole again), and its names, by id."""
    import sqlite3
    import zlib
    from array import array
    db = sqlite3.connect(walkgraph)
    tiles = defaultdict(dict)
    for x, y, name, data in db.execute("SELECT x, y, name, data FROM tiles"):
        a = array(ARRAY_TYPES[name])
        a.frombytes(zlib.decompress(data, -15))
        if sys.byteorder != "little":
            a.byteswap()
        tiles[(x, y)][name] = a
    names = dict(db.execute("SELECT id, label FROM names"))
    db.close()
    node_count = sum(len(t["node_id"]) for t in tiles.values())
    block_count = 1 + max(max(t["block_id"], default=-1) for t in tiles.values())
    node_fields = ["node_lat", "node_lon", "node_level", "node_signal", "node_part", "node_safety", "node_crashes"]
    arm_fields = ["arm_block", "arm_end", "corner_dx", "corner_dy", "corner_kind", "corner_link", "corner_ramp"]
    block_fields = ["block_a", "block_b", "block_slot_a", "block_slot_b", "block_class", "block_rw",
                    "block_flags", "block_name", "block_width", "block_lanes", "block_speed", "block_length",
                    "block_offset_left", "block_offset_right", "block_crossing", "block_sides",
                    "block_safety", "block_crashes"]
    graph = {name: array(ARRAY_TYPES[name], [0]) * node_count for name in node_fields}
    graph.update({name: array(ARRAY_TYPES[name], [0]) * block_count for name in block_fields})
    arm_count = [0] * node_count
    arm_parts = [None] * node_count
    lines = [None] * block_count
    for tile in tiles.values():
        at = 0
        for i, n in enumerate(tile["node_id"]):
            for name in node_fields:
                graph[name][n] = tile[name][i]
            count = tile["node_arms"][i]
            arm_count[n] = count
            arm_parts[n] = {name: tile[name][at:at + count] for name in arm_fields}
            at += count
        for i, b in enumerate(tile["block_id"]):
            if lines[b] is not None and lines[b][2]:
                continue
            for name in block_fields:
                graph[name][b] = tile[name][i]
            g0, g1 = tile["geom_start"][i], tile["geom_start"][i + 1]
            lines[b] = (tile["geom_lat"][g0:g1], tile["geom_lon"][g0:g1], tile["block_whole"][i])
    graph["arm_start"] = array("I")
    for name in arm_fields:
        graph[name] = array(ARRAY_TYPES[name])
    for n in range(node_count):
        graph["arm_start"].append(len(graph["arm_block"]))
        for name in arm_fields:
            graph[name].extend(arm_parts[n][name])
    graph["arm_start"].append(len(graph["arm_block"]))
    graph["geom_start"], graph["geom_lat"], graph["geom_lon"] = array("I"), array("i"), array("i")
    for b, (lat, lon, whole) in enumerate(lines):
        graph["geom_start"].append(len(graph["geom_lat"]))
        # Each block's first point, then each one's change from the one before: whole again,
        # its ends its junctions' where only the points between were kept
        points = []
        total_lat = total_lon = 0
        for dlat, dlon in zip(lat, lon):
            total_lat += dlat
            total_lon += dlon
            points.append((total_lat, total_lon))
        if not whole:
            a, z = graph["block_a"][b], graph["block_b"][b]
            points = [(graph["node_lat"][a], graph["node_lon"][a])] + points + [(graph["node_lat"][z], graph["node_lon"][z])]
        for p_lat, p_lon in points:
            graph["geom_lat"].append(p_lat)
            graph["geom_lon"].append(p_lon)
    graph["geom_start"].append(len(graph["geom_lat"]))
    return graph, names


def graph_debug(walkgraph, out_dir):
    """GeoJSON of the built graph at each of `PLACES`, as the router will see it: blocks by
    class, each street's two sidewalk lines, corners by kind, signals and median links."""
    g, names = read_graph(walkgraph)
    os.makedirs(out_dir, exist_ok=True)
    kinds = {CORNER_NONE: "corner-none", CORNER_SIDEWALK: "corner-sidewalk",
             CORNER_REFUGE: "corner-refuge", CORNER_PATH: "corner-path"}
    classes = {code: cls for cls, code in CLASS_CODE.items()}
    for box in PLACES:
        _, south, west, north, east = box
        features = []
        for b in range(len(g["block_a"])):
            s, e = g["geom_start"][b], g["geom_start"][b + 1]
            line = [(g["geom_lon"][i] / 1e6, g["geom_lat"][i] / 1e6) for i in range(s, e)]
            if not in_box(line, box):
                continue
            cls = classes[g["block_class"][b]]
            flags = g["block_flags"][b]
            features.append({"type": "Feature", "properties": {
                "kind": "median" if flags & MEDIAN else cls, "name": names.get(g["block_name"][b], "")},
                "geometry": {"type": "LineString", "coordinates": line}})
            if cls == WALK:
                plane = [xy(*q) for q in line]
                for side, field in ((0, "block_offset_left"), (1, "block_offset_right")):
                    offset = g[field][b] / 4
                    kind = "side" if offset else "side-none"
                    offset = offset or max(g["block_width"][b] / 20, 2.0)
                    features.append({"type": "Feature", "properties": {"kind": kind},
                                     "geometry": {"type": "LineString",
                                                  "coordinates": [lonlat(*q) for q in offset_line(plane, offset, side)]}})
        for n in range(len(g["node_lat"])):
            lon, lat = g["node_lon"][n] / 1e6, g["node_lat"][n] / 1e6
            if not (west <= lon <= east and south <= lat <= north):
                continue
            origin = xy(lon, lat)
            if g["node_signal"][n]:
                features.append({"type": "Feature", "properties": {"kind": "signal", "signal": g["node_signal"][n]},
                                 "geometry": {"type": "Point", "coordinates": [lon, lat]}})
            if all(g["block_class"][g["arm_block"][a]] == CLASS_CODE[ARM]
                   for a in range(g["arm_start"][n], g["arm_start"][n + 1])):
                continue
            for a in range(g["arm_start"][n], g["arm_start"][n + 1]):
                point = lonlat(origin[0] + g["corner_dx"][a] / 10, origin[1] + g["corner_dy"][a] / 10)
                features.append({"type": "Feature", "properties": {"kind": kinds[g["corner_kind"][a]]},
                                 "geometry": {"type": "Point", "coordinates": list(point)}})
        target = os.path.join(out_dir, f"{box[0]}.geojson")
        with open(target, "w", encoding="utf-8") as file:
            json.dump({"type": "FeatureCollection", "bbox": [west, south, east, north], "features": features}, file)
        print(f"{target}: {len(features)} features")


def offset_line(points, offset, side):
    """A polyline moved `offset` metres to its left (side 0) or right (1), each point along
    the average of its pieces' normals."""
    sign = 1 if side == 0 else -1
    out = []
    for i, p in enumerate(points):
        pieces = []
        if i > 0:
            pieces.append((points[i - 1], p))
        if i < len(points) - 1:
            pieces.append((p, points[i + 1]))
        normals = []
        for a, b in pieces:
            d = dist(a, b) or 1
            normals.append((-(b[1] - a[1]) / d, (b[0] - a[0]) / d))
        nx = sum(n[0] for n in normals) / len(normals)
        ny = sum(n[1] for n in normals) / len(normals)
        length = math.hypot(nx, ny) or 1
        out.append((p[0] + sign * offset * nx / length, p[1] + sign * offset * ny / length))
    return out


if __name__ == "__main__":
    commands = {"inspect": (inspect, 3), "debug": (debug, 4), "build": (build, 7), "graph-debug": (graph_debug, 2)}
    if len(sys.argv) < 2 or sys.argv[1] not in commands or len(sys.argv) != 2 + commands[sys.argv[1]][1]:
        sys.exit(f"usage: {sys.argv[0]} inspect cscl.geojson osm_paths.json osm_parks.json\n"
                 f"       {sys.argv[0]} debug cscl.geojson osm_paths.json osm_parks.json out_dir\n"
                 f"       {sys.argv[0]} build cscl.geojson osm_paths.json osm_parks.json osm_sidewalks.json "
                 f"sidewalks.sqlite safety_dir walkgraph.sqlite\n"
                 f"       {sys.argv[0]} graph-debug walkgraph.sqlite out_dir")
    function, _ = commands[sys.argv[1]]
    function(*sys.argv[2:])
