#!/usr/bin/env python3
"""Builds ios/App/bus_network.json: every bus line's each way drawn on its own side of the
street, its stops on it, for Nearby's and New Trip's maps (memory: bus-drawing-rework-plan).

From the MTA's bus GTFS schedules (as make_bus_shapes.py downloads them) and NYC's Street
Centerline (CSCL, as make_walk_graph.py downloads it):

    python3 tools/make_bus_network.py build cscl.geojson ios/App/bus_network.json \\
        gtfs_b gtfs_bx gtfs_m gtfs_q gtfs_si gtfs_busco
    python3 tools/make_bus_network.py debug cscl.geojson ios/App/bus_network.json out_dir
    swift tools/render_bus_network.swift out_dir out_dir

Each way of each line (its most-run shapes, and any others not running along them) is put
on the street centrelines it follows and moved out to its kerb by the street's width, as
the city has it: on the side its stops are on that street. Most are on the right; a few
lanes run on the left of a one-way street, or down its middle (a median, a busway), and
their stops show it. Where lines run the same street the same way, each runs on the first's
line there, exactly over each other; each stop is put on its line. Written as

    {"format": 2, "lines": [names],
     "ways": [[count, line..., latitude, longitude, change...], ...],
     "stops": [[latitude, longitude, bearing, line, line...], ...],
     "stopIDs": [the MTA's stop code of each of "stops"]}

each way and the lines along it (`count` of them, by their place in "lines"; one, as it's
written now), in the order its buses go; the positions in millionths of a degree, a piece's points as changes
from the one before; bearing in degrees clockwise from north, the way its buses go.
"""
import csv
import json
import math
import os
import sys
from collections import Counter, defaultdict
import multiprocessing

from make_bus_shapes import line_names
from make_shapes import simplify as simplify_ll

FORMAT = 2
KERB_IN = 3.0      # metres from the kerb a lane's middle is
MIDDLE_OUT = 1.5   # metres right of the middle for a lane down the middle of its street
SNAP = 22.0        # metres a shape's point may be from its street
STOP_SNAP = 30.0   # metres a stop may be from its street
PARALLEL = math.cos(math.radians(25))
STEP = 6.0         # metres between a shape's points as it's put on its streets
SMOOTH = 3         # points either way a way is averaged over, rounding its corners
GLITCH = 150.0     # metres on another street, at most, taken as a slip and bridged straight
STEADY = 25        # points either way (about 150 m) a lane's distance out is kept steady over
VARIANT_NEAR = 10.0   # metres a line's other shape may be off its first to be taken as along it
VARIANT_LEAST = 40.0  # metres a stretch of it elsewhere must be to be drawn
SHARE_NEAR = 4.0      # metres apart two lines' ways may be, going the same way, to be one piece
SHARE_STEP = 5.0      # metres between the points pieces are matched by
SHARE_LEAST = 30.0    # metres a stretch a line has on its own must be to be its own piece
TOLERANCE = 0.4    # metres a way, simplified, may stray
SIDE_FROM = 2.0    # metres off the middle a stop must be to tell its side
MOST_SHAPES = 4    # shapes of each way at most
STOP_REACH = 40    # metres a stop may be from its way's lines to be drawn on them
LAT0 = 40.70
KX = 111320 * math.cos(math.radians(LAT0))
KY = 110540
CELL = 50.0
SKIP_TYPES = {"7", "8", "12", "14"}  # stairs, boardwalks, ferry routes, paper streets


def xy(lat, lon):
    return ((lon + 73.95) * KX, (lat - LAT0) * KY)


def ll(x, y):
    return (LAT0 + y / KY, -73.95 + x / KX)


# The streets, for the workers (shared once forked)
SEGMENTS = []
GRID = defaultdict(list)


def load_streets(path):
    data = json.load(open(path))
    for feature in data["features"]:
        props = feature["properties"]
        if props.get("rw_type") in SKIP_TYPES or not feature.get("geometry"):
            continue
        width = float(props.get("streetwidth") or 30) * 0.3048
        way = props.get("trafdir") or "TW"
        name = props.get("stname_label") or ""
        for line in feature["geometry"]["coordinates"]:
            points = [xy(lat, lon) for lon, lat in line]
            for a, b in zip(points, points[1:]):
                length = math.dist(a, b)
                if length < 0.5:
                    continue
                index = len(SEGMENTS)
                SEGMENTS.append((a, ((b[0] - a[0]) / length, (b[1] - a[1]) / length), length, width, way, name))
                for gx in range(int(min(a[0], b[0]) // CELL) - 1, int(max(a[0], b[0]) // CELL) + 2):
                    for gy in range(int(min(a[1], b[1]) // CELL) - 1, int(max(a[1], b[1]) // CELL) + 2):
                        GRID[(gx, gy)].append(index)


def snap(point, heading, reach):
    """The nearest street running the way `heading` goes, within `reach`: (metres, point on
    it, its way along turned to `heading`, width, traffic direction, name)."""
    best = None
    for index in GRID.get((int(point[0] // CELL), int(point[1] // CELL)), ()):
        a, (ux, uy), length, width, way, name = SEGMENTS[index]
        along = ux * heading[0] + uy * heading[1]
        if abs(along) < PARALLEL:
            continue
        t = max(0.0, min(length, (point[0] - a[0]) * ux + (point[1] - a[1]) * uy))
        q = (a[0] + ux * t, a[1] + uy * t)
        d = math.dist(point, q)
        if d <= reach and (best is None or d < best[0]):
            best = (d, q, (ux, uy) if along > 0 else (-ux, -uy), width, way, name)
    return best


def densify(points):
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        n = max(1, int(math.dist(a, b) / STEP))
        for i in range(1, n + 1):
            out.append((a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n))
    return out


def heading_at(points, i, span=3):
    a, b = points[max(0, i - span)], points[min(len(points) - 1, i + span)]
    length = math.dist(a, b)
    return ((b[0] - a[0]) / length, (b[1] - a[1]) / length) if length > 1e-6 else None


def stop_sides(points, stops):
    """For each street the way's stops are on, the side they're on: 1 right, -1 left, 0 the
    middle, by most of them; and each stop's side and street."""
    by_street = defaultdict(list)
    for stop in stops:
        p = xy(stop[0], stop[1])
        j = min(range(len(points)), key=lambda k: math.dist(points[k], p))
        heading = heading_at(points, j)
        if not heading:
            continue
        found = snap(p, heading, STOP_SNAP)
        if not found:
            continue
        _, q, (ux, uy), _, _, name = found
        across = (p[0] - q[0]) * uy - (p[1] - q[1]) * ux
        by_street[name].append(across)
    sides = {}
    for name, acrosses in by_street.items():
        acrosses.sort()
        middle = acrosses[len(acrosses) // 2]
        sides[name] = 1 if middle > SIDE_FROM else -1 if middle < -SIDE_FROM else 0
    return sides


def lay_out(job):
    """One way of a line: its points put on its streets' kerb-side lane. (job key, points as
    latitude/longitude, counts) or None."""
    key, shape, stops = job
    points = densify([xy(lat, lon) for lat, lon in shape])
    if len(points) < 2:
        return None
    sides = stop_sides(points, stops)
    n = len(points)
    # Each point's street: where on its centreline, its right, the street's name, and how far
    # out the lane is (right of the way it goes; left, less than 0)
    found_at = [None] * n
    for i, p in enumerate(points):
        heading = heading_at(points, i)
        if not heading:
            continue
        found = snap(p, heading, SNAP)
        if not found:
            continue
        _, q, (ux, uy), width, way, name = found
        side = sides.get(name, 1)
        half = width / 2
        if side == 0:
            out = MIDDLE_OUT
        elif way == "TW":
            out = side * max(half - KERB_IN, half / 2)
        else:
            out = side * max(half - KERB_IN, 0.0)
        found_at[i] = (q, (uy, -ux), name, out)
    # A short stretch on another street than either side of it (a cross street, a slip road
    # by an intersection) is off any: bridged straight between them, not swerving onto it
    i = 0
    while i < n:
        if not found_at[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and found_at[j + 1] and found_at[j + 1][2] == found_at[i][2]:
            j += 1
        before = next((found_at[k][2] for k in range(i - 1, -1, -1) if found_at[k]), None)
        after = next((found_at[k][2] for k in range(j + 1, n) if found_at[k]), None)
        if before is not None and before == after and before != found_at[i][2] and (j - i + 1) * STEP < GLITCH:
            for k in range(i, j + 1):
                found_at[k] = None
        i = j + 1
    # How far out, kept steady along a street: the middle of those near, so a block the city
    # has narrower, or a point snapped to a slip road, doesn't pull the lane in and back out
    outs = [f[3] if f else None for f in found_at]
    steady = list(outs)
    for i in range(n):
        if outs[i] is None:
            continue
        near = sorted(o for o in outs[max(0, i - STEADY):i + STEADY + 1] if o is not None and (o > 0) == (outs[i] > 0))
        steady[i] = near[len(near) // 2]
    # Each point's lane: where its street's centreline is from it (`shift`), and how far out
    # to the right of the way it goes. Off any street (turns, bends, plazas), both eased between
    # the points either side, and out at right angles to its own way there: easing the whole
    # move instead pulled the lane toward the middle round every bend, the moves either side of
    # it pointing different ways
    shifts = [None] * n
    rights = [None] * n
    snapped = 0
    sided = Counter()
    for i, f in enumerate(found_at):
        if not f:
            continue
        (qx, qy), right, _, _ = f
        shifts[i] = (qx - points[i][0], qy - points[i][1])
        rights[i] = right
        snapped += 1
        out = steady[i]
        sided[1 if out > MIDDLE_OUT + 0.1 else -1 if out < 0 else 0] += 1
    known = [i for i, f in enumerate(shifts) if f]
    if not known:
        return None
    k = 0
    for i in range(n):
        if shifts[i]:
            continue
        while k < len(known) and known[k] < i:
            k += 1
        before = known[k - 1] if k > 0 else None
        after = known[k] if k < len(known) else None
        if before is None:
            shifts[i], steady[i] = shifts[after], steady[after]
        elif after is None:
            shifts[i], steady[i] = shifts[before], steady[before]
        else:
            t = (i - before) / (after - before)
            sb, sa = shifts[before], shifts[after]
            shifts[i] = (sb[0] + (sa[0] - sb[0]) * t, sb[1] + (sa[1] - sb[1]) * t)
            steady[i] = steady[before] + (steady[after] - steady[before]) * t
        heading = heading_at(points, i)
        rights[i] = (heading[1], -heading[0]) if heading else rights[before if before is not None else after]
    offsets = [(shift[0] + right[0] * out, shift[1] + right[1] * out)
               for shift, right, out in zip(shifts, rights, steady)]
    moved = [(p[0] + o[0], p[1] + o[1]) for p, o in zip(points, offsets)]
    smooth = []
    for i in range(n):
        window = moved[max(0, i - SMOOTH):i + SMOOTH + 1]
        smooth.append((sum(x for x, _ in window) / len(window), sum(y for _, y in window) / len(window)))
    smooth[0], smooth[-1] = moved[0], moved[-1]
    lane = simplify_xy(smooth, TOLERANCE)
    return key, [ll(x, y) for x, y in lane], {"points": n, "snapped": snapped, "sides": dict(sided)}


def simplify_xy(points, tolerance):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        a, b = points[i], points[j]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy) or 1e-9
        best, at = 0.0, None
        for k in range(i + 1, j):
            p = points[k]
            d = abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / length
            if d > best:
                best, at = d, k
        if at is not None and best > tolerance:
            keep[at] = True
            stack += [(i, at), (at, j)]
    return [p for p, k in zip(points, keep) if k]


def runs_along(shape, other, meters=25):
    """Whether most of `shape` is within `meters` of `other`."""
    if not other:
        return False
    grid = defaultdict(list)
    for p in other:
        q = xy(*p)
        grid[(int(q[0] // meters), int(q[1] // meters))].append(q)
    near = 0
    for p in shape:
        q = xy(*p)
        cx, cy = int(q[0] // meters), int(q[1] // meters)
        if any(math.dist(q, r) < meters for dx in (-1, 0, 1) for dy in (-1, 0, 1)
               for r in grid.get((cx + dx, cy + dy), ())):
            near += 1
    return near >= 0.9 * len(shape)


def read_feeds(feeds):
    """Each line's each way: its shapes to draw (latitude/longitude) and one trip's stops of
    each, as (latitude, longitude, stop id). Besides the most run, a shape whose trips stop
    where those don't, at a stop bus_routes.json times (`timetabled_stops`), so every stop
    timetabled is on a line drawn: a rush-hour variant's, a detour's."""
    timetabled = timetabled_stops(feeds)
    jobs = []
    for feed in feeds:
        names = line_names(feed)
        trips = defaultdict(Counter)       # (line, direction): trips of each shape
        sample = {}                        # shape: a trip of it
        with open(f"{feed}/trips.txt", encoding="utf-8-sig", newline="") as file:
            for trip in csv.DictReader(file):
                shape = trip.get("shape_id")
                if not shape:
                    continue
                key = (names.get(trip["route_id"], trip["route_id"]), trip.get("direction_id") or "0")
                trips[key][shape] += 1
                sample.setdefault(shape, trip["trip_id"])
        points = defaultdict(list)
        with open(f"{feed}/shapes.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                points[row["shape_id"]].append((int(row["shape_pt_sequence"]), float(row["shape_pt_lat"]),
                                                float(row["shape_pt_lon"])))
        stops = {}
        with open(f"{feed}/stops.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                stops[row["stop_id"]] = (float(row["stop_lat"]), float(row["stop_lon"]), row["stop_id"])
        # The shapes kept: the most run, and others not along those
        kept = {}
        for key, counts in trips.items():
            chosen = []
            for shape, _ in counts.most_common():
                if shape not in points or len(chosen) >= MOST_SHAPES:
                    continue
                coords = [(lat, lon) for _, lat, lon in sorted(points[shape])]
                if any(runs_along(coords, other) for _, other in chosen):
                    continue
                chosen.append((shape, coords))
            kept[key] = chosen
        # Every shape's sample trip's stops, to add those stopping where the kept don't
        wanted = {sample[shape]: shape for counts in trips.values() for shape in counts if shape in sample}
        order = defaultdict(list)
        with open(f"{feed}/stop_times.txt", encoding="utf-8-sig", newline="") as file:
            for row in csv.DictReader(file):
                shape = wanted.get(row["trip_id"])
                if shape:
                    order[shape].append((int(row["stop_sequence"]), row["stop_id"]))
        for key, counts in trips.items():
            missing = {code for _, _, code in timetabled.get(key, [])}
            for shape, _ in kept[key]:
                missing -= {code for _, code in order.get(shape, [])}
            for shape, _ in counts.most_common():
                if not missing:
                    break
                serves = missing & {code for _, code in order.get(shape, [])}
                if shape in points and serves and all(shape != chosen for chosen, _ in kept[key]):
                    kept[key].append((shape, [(lat, lon) for _, lat, lon in sorted(points[shape])]))
                    missing -= serves
        for key, chosen in kept.items():
            for shape, coords in chosen:
                way_stops = [stops[s] for _, s in sorted(order.get(shape, [])) if s in stops]
                jobs.append(((key[0], key[1], shape), coords, way_stops))
        print(f"{feed}: {len(kept)} ways, {sum(len(c) for c in kept.values())} shapes", file=sys.stderr)
    return jobs


def merge_variants(results):
    """Each line's each way drawn once: its most-run shape whole, and of its others only where
    they go somewhere else (a branch, a short turn's loop), joined onto it at either end. Laid
    out each on its own, the same street a metre or two apart, they read as the line swerving."""
    merged = []
    main = {}  # (line, direction): its first shape's points, and a grid of them
    for key, lane, counts in results:
        way = key[:2]
        points = densify([xy(*p) for p in lane])
        if way not in main:
            grid = defaultdict(list)
            for q in points:
                grid[(int(q[0] // VARIANT_NEAR), int(q[1] // VARIANT_NEAR))].append(q)
            main[way] = grid
            merged.append((key, lane, counts))
            continue
        grid = main[way]
        def nearest(q):
            cx, cy = int(q[0] // VARIANT_NEAR), int(q[1] // VARIANT_NEAR)
            near = [r for dx in (-1, 0, 1) for dy in (-1, 0, 1) for r in grid.get((cx + dx, cy + dy), ())]
            return min(near, key=lambda r: math.dist(q, r)) if near else None
        along = [(nearest(q) is not None and math.dist(q, nearest(q)) < VARIANT_NEAR) for q in points]
        # The stretches away from the first, each joined onto it where it leaves and comes back
        part = 0
        i = 0
        while i < len(points):
            if along[i]:
                i += 1
                continue
            j = i
            while j + 1 < len(points) and not along[j + 1]:
                j += 1
            run = points[i:j + 1]
            if i > 0 and (start := nearest(points[i - 1])):
                run = [start] + run
            if j + 1 < len(points) and (end := nearest(points[j + 1])):
                run = run + [end]
            if len(run) > 1 and sum(math.dist(a, b) for a, b in zip(run, run[1:])) >= VARIANT_LEAST:
                merged.append(((key[0], key[1], f"{key[2]}-{part}"), [ll(x, y) for x, y in simplify_xy(run, TOLERANCE)], counts))
                part += 1
            i = j + 1
    return merged


def place_stops(results, jobs):
    """Each stop on the line of its way stopping there (any of the line's drawn that way), and
    the way it goes: by stop id, its point, bearing and lines."""
    by_way = defaultdict(list)
    for key, lane, _ in results:
        by_way[key[:2]].append([xy(*p) for p in lane])
    stops = {}
    for key, _, way_stops in jobs:
        lanes = by_way.get(key[:2])
        if not lanes:
            continue
        for lat, lon, stop_id in way_stops:
            p = xy(lat, lon)
            best = None
            for a, b in ((a, b) for points in lanes for a, b in zip(points, points[1:])):
                dx, dy = b[0] - a[0], b[1] - a[1]
                length2 = dx * dx + dy * dy or 1e-9
                t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2))
                q = (a[0] + dx * t, a[1] + dy * t)
                d = math.dist(p, q)
                if best is None or d < best[0]:
                    best = (d, q, math.degrees(math.atan2(dx, dy)) % 360)
            if not best or best[0] > 40:
                continue
            stop = stops.setdefault(stop_id, {"point": best[1], "bearing": best[2], "lines": set()})
            stop["lines"].add(key[0])
    return stops


def merge_shared(results):
    """Each line's ways, where lines run the same street the same way (within `SHARE_NEAR`),
    on the first laid out's line there: exactly over each other, drawn as one. [(lines, points
    as x, y)], each way's one line."""
    pieces = []        # each: points, and the lines on each point
    grid = defaultdict(list)

    def heading(points, i):
        h = heading_at(points, i, span=2)
        return h or (1.0, 0.0)

    def find(q, h):
        cx, cy = int(q[0] // SHARE_NEAR), int(q[1] // SHARE_NEAR)
        best = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for piece, i, ph in grid.get((cx + dx, cy + dy), ()):
                    d = math.dist(q, pieces[piece][0][i])
                    if d < SHARE_NEAR and ph[0] * h[0] + ph[1] * h[1] > 0.85 and (best is None or d < best[0]):
                        best = (d, piece, i)
        return best

    def add(points, line):
        index = len(pieces)
        pieces.append((points, [{line} for _ in points]))
        for i, q in enumerate(points):
            grid[(int(q[0] // SHARE_NEAR), int(q[1] // SHARE_NEAR))].append((index, i, heading(points, i)))

    snapped_ways = []
    for key, lane, _ in results:
        line = key[0]
        points = [xy(*p) for p in lane]
        dense = [points[0]]
        for a, b in zip(points, points[1:]):
            n = max(1, int(math.dist(a, b) / SHARE_STEP))
            dense += [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(1, n + 1)]
        found = [find(q, heading(dense, i)) for i, q in enumerate(dense)]
        # The way itself, on the pieces where it runs along them: lines sharing a street then
        # lie exactly over each other there, one clean line, not a metre or two apart
        snapped_ways.append((key, [pieces[f[1]][0][f[2]] if f else q for q, f in zip(dense, found)]))
        # A gap of a point or two along a piece is along it still
        shared = [f is not None for f in found]
        for i in range(1, len(shared) - 1):
            if not shared[i] and shared[i - 1] and any(shared[i + 1:i + 3]):
                shared[i] = True
        i = 0
        while i < len(dense):
            if shared[i]:
                if found[i]:
                    _, piece, at = found[i]
                    pieces[piece][1][at].add(line)
                i += 1
                continue
            j = i
            while j + 1 < len(dense) and not shared[j + 1]:
                j += 1
            run = dense[i:j + 1]
            if i > 0 and found[i - 1]:
                run = [pieces[found[i - 1][1]][0][found[i - 1][2]]] + run
            if j + 1 < len(dense) and found[j + 1]:
                run = run + [pieces[found[j + 1][1]][0][found[j + 1][2]]]
            length = sum(math.dist(a, b) for a, b in zip(run, run[1:]))
            if len(run) > 1 and length >= SHARE_LEAST:
                add(run, line)
            elif len(run) > 1:
                # Too short to stand alone (a bus bay, a kink): on the piece it's beside
                for q in run:
                    near = find(q, heading(run, 0))
                    if near:
                        pieces[near[1]][1][near[2]].add(line)
            i = j + 1

    out = []
    for key, points in snapped_ways:
        points = simplify_xy(points, TOLERANCE) if len(points) > 1 else points
        # Not one snapped all onto a single point (a Q22 short turn's, at Beach 9 St)
        if len(points) > 1 and sum(math.dist(a, b) for a, b in zip(points, points[1:])) >= 1:
            out.append(([key[0]], points))
    return out


def timetabled_stops(feeds):
    """Each line's each direction's stops as bus_routes.json has them (make_bus_routes.py's
    kept patterns): [(latitude, longitude, stop id)] by (line, direction)."""
    from make_bus_routes import kept, read_patterns
    stops, patterns, _ = read_patterns(feeds)
    found = {}
    for way, by_pattern in patterns.items():
        codes = list(dict.fromkeys(code for pattern, _ in kept(by_pattern) for code in pattern))
        found[way] = [(stops[code][0] / 1e5, stops[code][1] / 1e5, code) for code in codes if code in stops]
    return found


def place_stops_on(pieces, timetabled):
    """Each stop on the nearest of its lines' ways (`merge_shared`'s), and the way it goes
    there: by stop id, its point, bearing and lines. The stops are bus_routes.json's
    (`timetabled_stops`), so the two files have the same; one further than STOP_REACH from
    its line's ways is left out, warned of."""
    by_line = defaultdict(list)
    for index, (lines, points) in enumerate(pieces):
        for line in lines:
            by_line[line].append(index)
    stops = {}
    far = []
    for key, way_stops in timetabled.items():
        candidates = by_line.get(key[0], [])
        for lat, lon, stop_id in way_stops:
            p = xy(lat, lon)
            best = None
            for index in candidates:
                points = pieces[index][1]
                for a, b in zip(points, points[1:]):
                    dx, dy = b[0] - a[0], b[1] - a[1]
                    length2 = dx * dx + dy * dy or 1e-9
                    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2))
                    q = (a[0] + dx * t, a[1] + dy * t)
                    d = math.dist(p, q)
                    if best is None or d < best[0]:
                        best = (d, q, math.degrees(math.atan2(dx, dy)) % 360)
            if not best or best[0] > STOP_REACH:
                far.append(f"{key[0]} {stop_id}")
                continue
            stop = stops.setdefault(stop_id, {"point": best[1], "bearing": best[2], "lines": set()})
            stop["lines"].add(key[0])
    if far:
        print(f"{len(far)} timetabled stops past {STOP_REACH} m of their line, not drawn: {', '.join(far[:20])}",
              file=sys.stderr)
    return stops


def build(cscl, target, feeds):
    load_streets(cscl)
    print(f"{len(SEGMENTS)} street segments", file=sys.stderr)
    jobs = read_feeds(feeds)
    # Forked, for the workers to share the streets loaded
    with multiprocessing.get_context("fork").Pool(max(1, (os.cpu_count() or 2) - 2)) as pool:
        results = merge_variants([r for r in pool.map(lay_out, jobs, chunksize=4) if r])
    total = sum(r[2]["points"] for r in results)
    snapped = sum(r[2]["snapped"] for r in results)
    sides = Counter()
    for r in results:
        sides.update(r[2]["sides"])
    print(f"{len(results)} ways laid out; {snapped / max(total, 1):.1%} of points on a street; "
          f"sides right {sides.get(1, 0)} left {sides.get(-1, 0)} middle {sides.get(0, 0)}", file=sys.stderr)
    # Busiest lines' ways first, so a street many run takes the first's place for all
    runs = Counter(r[0][0] for r in results)
    pieces = merge_shared(sorted(results, key=lambda r: (-runs[r[0][0]], r[0])))
    stops = place_stops_on(pieces, timetabled_stops(feeds))
    lines = sorted({r[0][0] for r in results})
    index = {line: i for i, line in enumerate(lines)}
    ways = []
    for piece_lines, points in pieces:
        row = [len(piece_lines)] + [index[line] for line in piece_lines]
        last_lat = last_lon = 0
        for x, y in points:
            lat, lon = ll(x, y)
            la, lo = round(lat * 1e6), round(lon * 1e6)
            row += [la - last_lat, lo - last_lon]
            last_lat, last_lon = la, lo
        ways.append(row)
    stop_rows, stop_ids = [], []
    for stop_id, stop in sorted(stops.items()):
        lat, lon = ll(*stop["point"])
        stop_rows.append([round(lat * 1e6), round(lon * 1e6), round(stop["bearing"]) % 360]
                         + sorted(index[line] for line in stop["lines"]))
        stop_ids.append(stop_id)
    with open(target, "w") as file:
        json.dump({"format": FORMAT, "lines": lines, "ways": ways, "stops": stop_rows, "stopIDs": stop_ids},
                  file, separators=(",", ":"))
    print(f"wrote {target}: {len(lines)} lines, {len(ways)} ways, {len(stop_rows)} stops, "
          f"{os.path.getsize(target) / 1e6:.1f} MB", file=sys.stderr)


# Places to look at, one or more in each borough: (name, south, west, north, east)
DEBUG_AREAS = [
    ("brooklyn-downtown", 40.677, -73.992, 40.695, -73.965),
    ("manhattan-midtown", 40.745, -73.995, 40.762, -73.968),
    ("manhattan-1st-2nd-ave", 40.765, -73.962, 40.780, -73.944),
    ("queens-blvd", 40.736, -73.926, 40.748, -73.902),
    ("queens-jamaica", 40.698, -73.812, 40.712, -73.785),
    ("bronx-fordham", 40.855, -73.905, 40.868, -73.880),
    ("statenisland-st-george", 40.635, -74.085, 40.648, -74.068),
]


def debug(cscl, network, out_dir):
    """A GeoJSON of each `DEBUG_AREAS` place: its streets, the ways drawn and the stops, for
    render_bus_network.swift."""
    os.makedirs(out_dir, exist_ok=True)
    data = json.load(open(network))
    streets = json.load(open(cscl))["features"]
    ways = []
    for row in data["ways"]:
        count = row[0]
        line, direction, flat = ",".join(data["lines"][i] for i in row[1:1 + count]), min(count - 1, 1), row[1 + count:]
        lat = lon = 0
        coords = []
        for i in range(0, len(flat), 2):
            lat += flat[i]
            lon += flat[i + 1]
            coords.append((lon / 1e6, lat / 1e6))
        ways.append((line, direction, coords))
    for name, south, west, north, east in DEBUG_AREAS:
        inside = lambda lon, lat: west <= lon <= east and south <= lat <= north
        features = []
        for f in streets:
            if not f.get("geometry"):
                continue
            for line in f["geometry"]["coordinates"]:
                if any(inside(lon, lat) for lon, lat in line):
                    features.append({"type": "Feature", "properties": {"kind": "street"},
                                     "geometry": {"type": "LineString", "coordinates": line}})
        for line, direction, coords in ways:
            # Each stretch with a point inside, and the points either side of it, so a long
            # straight piece crossing the edge isn't cut short
            run = []
            for i, c in enumerate(coords):
                near = any(inside(*coords[j]) for j in range(max(0, i - 1), min(len(coords), i + 2)))
                if near:
                    run.append(c)
                elif run:
                    if len(run) > 1:
                        features.append({"type": "Feature", "properties": {"kind": "way", "line": line, "direction": direction},
                                         "geometry": {"type": "LineString", "coordinates": run}})
                    run = []
            if len(run) > 1:
                features.append({"type": "Feature", "properties": {"kind": "way", "line": line, "direction": direction},
                                 "geometry": {"type": "LineString", "coordinates": run}})
        for row in data["stops"]:
            lat, lon = row[0] / 1e6, row[1] / 1e6
            if inside(lon, lat):
                features.append({"type": "Feature", "properties": {"kind": "stop", "bearing": row[2],
                                                                   "lines": [data["lines"][i] for i in row[3:]]},
                                 "geometry": {"type": "Point", "coordinates": [lon, lat]}})
        with open(os.path.join(out_dir, f"{name}.geojson"), "w") as file:
            json.dump({"type": "FeatureCollection", "bbox": [west, south, east, north], "features": features}, file)
        print(f"{name}: {len(features)} features", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif len(sys.argv) == 5 and sys.argv[1] == "debug":
        debug(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
