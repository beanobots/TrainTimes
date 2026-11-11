#!/usr/bin/env python3
"""Builds tools/entrance_names.json, the streets and corner of each subway entrance, for walking
directions ("NW corner of 4 Av & 9 St"), which make_stations.py gives the entrances in stations.json.

    curl -o entrances.json 'https://data.ny.gov/resource/i9wp-a4ja.json?$limit=5000'
    curl -G -o centerlines.json https://data.cityofnewyork.us/resource/inkn-q76z.json \\
        --data-urlencode '$select=the_geom,stname_label,rw_type' --data-urlencode '$limit=300000'
    python3 tools/make_entrances.py entrances.json centerlines.json tools/entrance_exceptions.json tools/entrance_names.json

The MTA's entrance list says where each entrance is but not its streets, so they're worked out
from the city's street centerlines (NYC Street Centerline, CSCL, from the Office of Technology and
Innovation): the crossing nearest the entrance of the two streets nearest it, the more north-south
of them first, and its corner by which side of each street it's on. That's the streets' own way,
not the compass's, so Manhattan's grid, turned 29 degrees, still has its avenues running north.
Only ordinary streets count (not highways, ramps, paths or driveways), and the names are written
the MTA's way, as its stations are: "AVE OF THE AMERICAS" is "6 Av", "W 42 ST" is "W 42 St".

Where the MTA's own 2015 list, which named each entrance's streets and corner, is better, its
answer is kept in tools/entrance_exceptions.json, by the entrance's place, with why: the city's
centerlines draw a divided road's sides as two streets, so an entrance on its median is on the
wrong side of one, and some crossings have a short connector or a lane nearer the stairs than the
street people know them by. Those were picked by comparing the two, with OpenStreetMap's streets
and entrances as a third opinion where they disagreed. An exception's "streets" of null names
nothing for that entrance. One that no longer matches an entrance (the MTA moved or dropped it) is
warned of, and the city's answer stands.

Where a divided road's other roadway (a service road, as E 14 St's along Stuyvesant Town) is
nearer the entrance than its main one, across the entrance from it, the crossing's taken on the
main (the wider) roadway. And a corner that's the wrong side of its own streets on the city's
centrelines, or of a crossing more than REACH away (mid-block), is left out, the city's or the
2015 list's: the streets alone ("4 Av & 9 St") rather than send someone the wrong way.

Each entry says where its answer is from: "city" or "2015".
"""
import json
import math
import re
import sys
from collections import defaultdict

# Metres from an entrance a crossing can be and still be its own
REACH = 80
# Metres an entrance must be on the other side of one of its streets from where its corner
# says for the corner to be dropped (`Streets.disagrees`): the city's and the MTA's places are
# a few metres apart, and a stair on a wide avenue's sidewalk is 10 m or more off its line
WRONG_SIDE = 8
# Metres between a divided road's two roadways, across the entrance, at most
DIVIDED = 60
# Street names to skip: pieces of a crossing, not streets anyone knows
SKIPPED = re.compile(r"^(CONNECTOR|UNNAMED ST|BIKE PATH)$|^CONNECTOR | (EXIT|ENTRANCE|ENT)$")
CELL = 100
COS = math.cos(math.radians(40.72))


def metres(lat, lon):
    """Metres east and north, near enough at the city's latitude."""
    return (lon * 111320 * COS, lat * 111320)


# The city's labels, in capitals, the MTA's way
WHOLE = {"AVE OF THE AMERICAS": "6 Av", "GRAND CONC": "Grand Concourse", "MAC DOUGAL ST": "MacDougal St",
         "DEKALB AVE": "DeKalb Av", "METROTECH RDWY": "MetroTech", "PROSPECT PARK SW": "Prospect Park Southwest"}
WORDS = {"AVE": "Av", "AV": "Av", "ST": "St", "BLVD": "Blvd", "BL": "Blvd", "PKWY": "Pkwy", "RD": "Rd",
         "PL": "Pl", "DR": "Dr", "LN": "Ln", "CT": "Ct", "TER": "Ter", "SQ": "Sq", "PLZ": "Plaza",
         "AVENUE": "Av", "PARKWAY": "Pkwy", "BOULEVARD": "Blvd", "BRG": "Bridge", "ALY": "Alley", "HWY": "Hwy", "EXPY": "Expy", "TPKE": "Tpke", "FWY": "Fwy", "CIR": "Cir", "WAY": "Way",
         "BCH": "Beach", "FT": "Ft", "MT": "Mt", "JR": "Jr", "CONC": "Concourse", "SVC": "Service",
         "E": "E", "W": "W", "N": "N", "S": "S"}
# A direction last spelled out, as the MTA does: "Central Park South"
LAST = {"N": "North", "S": "South", "E": "East", "W": "West"}


def mta_name(label):
    """"W 42 ST" -> "W 42 St", "MC DONALD AVE" -> "McDonald Av", "AVE M" -> "Av M"."""
    label = " ".join(label.split())
    if label in WHOLE:
        return WHOLE[label]
    label = re.sub(r"\bMC (?=[A-Z])", "MC", label)
    words = label.split(" ")
    out = []
    for i, word in enumerate(words):
        # Not a lettered avenue's letter: "AVE N" is "Av N"
        if i == len(words) - 1 and i > 0 and word in LAST and words[i - 1] not in ("AVE", "AV"):
            out.append(LAST[word])
        elif word in WORDS:
            out.append(WORDS[word])
        elif re.fullmatch(r"\d+[A-Z]?", word):
            out.append(word)
        elif word.startswith("MC") and len(word) > 2:
            out.append("Mc" + word[2:].capitalize())
        elif word.startswith("O'"):
            out.append("O'" + word[2:].capitalize())
        else:
            out.append("-".join(part.capitalize() for part in word.split("-")))
    return " ".join(out)


class Streets:
    """The city's ordinary streets, as lines in metres, looked up by where they are."""

    def __init__(self, segments, widths=None):
        self.segments = segments  # (label, [(x, y), ...])
        # Each piece's feet curb to curb, as the city has it; 0 where not given
        self.widths = widths or [0] * len(segments)
        self.grid = defaultdict(set)
        for i, (_, points) in enumerate(segments):
            for (x0, y0), (x1, y1) in zip(points, points[1:]):
                steps = int(math.hypot(x1 - x0, y1 - y0) // CELL) + 1
                for s in range(steps + 1):
                    t = s / steps
                    self.grid[(int((x0 + t * (x1 - x0)) // CELL), int((y0 + t * (y1 - y0)) // CELL))].add(i)

    @classmethod
    def from_centerlines(cls, path):
        with open(path, encoding="utf-8") as file:
            rows = json.load(file)
        segments, widths = [], []
        for row in rows:
            label = " ".join((row.get("stname_label") or "").split())
            # 1: an ordinary street
            if row.get("rw_type") != "1" or not row.get("the_geom") or not label or SKIPPED.search(label):
                continue
            try:
                width = float(row.get("streetwidth") or 0)
            except ValueError:
                width = 0
            for line in row["the_geom"]["coordinates"]:
                segments.append((label, [metres(lat, lon) for lon, lat in line]))
                widths.append(width)
        return cls(segments, widths)

    def near(self, x, y, reach):
        found = set()
        for cx in range(int((x - reach) // CELL), int((x + reach) // CELL) + 1):
            for cy in range(int((y - reach) // CELL), int((y + reach) // CELL) + 1):
                found |= self.grid.get((cx, cy), set())
        return found

    def crossing(self, lat, lon):
        """(streets, corner) for an entrance: (["4 AVE", "9 ST"], "NW"), the north-south street
        first, in the city's labels; or None without a crossing within REACH."""
        x, y = metres(lat, lon)
        ids = self.near(x, y, REACH)
        if not ids:
            return None
        found = self.best_crossing(x, y, ids)
        if found is None:
            return None
        # A divided road's other roadway (a service road beside it, as E 14 St's along
        # Stuyvesant Town): the crossing's taken on its main roadway instead, the widest,
        # where the entrance is between the two
        for street in found[2:]:
            others = self.other_roadways(x, y, ids, street[0], found[1])
            if others:
                again = self.best_crossing(x, y, ids - others)
                if again is None or street[0] not in (again[2][0], again[3][0]):
                    # Its main roadway meets nothing near: the streets, but which corner
                    # isn't known
                    return [ns_first(found[2:])[0][0], ns_first(found[2:])[1][0]], None
                found = again
                break
        _, node, *two = found
        # The more north-south first, pointed north; the other pointed east
        (ns, up), (ew, right) = ns_first(two)
        if up[1] < 0:
            up = (-up[0], -up[1])
        if right[0] < 0:
            right = (-right[0], -right[1])
        dx, dy = x - node[0], y - node[1]
        north = dx * -right[1] + dy * right[0] > 0
        east = dx * up[1] - dy * up[0] > 0
        return [ns, ew], ("N" if north else "S") + ("E" if east else "W")

    def other_roadways(self, x, y, ids, label, node):
        """The pieces of `label` near (x, y) on the far side of it from the roadway the
        crossing at `node` is on, running alongside within DIVIDED metres, where those are
        wider (or as wide and two-way): the entrance is beside a service road or in a
        median, and the main roadway's across it. A set of piece indices; empty if none."""
        own = [i for i in ids if self.segments[i][0] == label
               and any(math.hypot(p[0] - node[0], p[1] - node[1]) < 0.5 for p in (self.segments[i][1][0], self.segments[i][1][-1]))]
        if not own:
            return set()
        def way(i):
            points = self.segments[i][1]
            dx, dy = points[-1][0] - points[0][0], points[-1][1] - points[0][1]
            length = math.hypot(dx, dy) or 1
            return dx / length, dy / length
        def side(i):
            """Which side of piece `i`'s nearest bit (x, y) is, and how far."""
            best = (math.inf, 0)
            points = self.segments[i][1]
            for (x0, y0), (x1, y1) in zip(points, points[1:]):
                dx, dy = x1 - x0, y1 - y0
                t = max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / (dx * dx + dy * dy or 1)))
                gap = math.hypot(x - x0 - t * dx, y - y0 - t * dy)
                if gap < best[0]:
                    best = (gap, 1 if dx * (y - y0) - dy * (x - x0) > 0 else -1)
            return best
        near_own = min(own, key=lambda i: side(i)[0])
        gap_own, side_own = side(near_own)
        along = way(near_own)
        this_side, far_side = set(), set()
        for i in ids:
            if self.segments[i][0] != label:
                continue
            w = way(i)
            if abs(w[0] * along[0] + w[1] * along[1]) < math.cos(math.radians(20)):
                continue
            gap, sign = side(i)
            # Across the entrance from `near_own`: on the other side of it, whichever way
            # each was drawn
            same_way = w[0] * along[0] + w[1] * along[1] > 0
            if (sign != side_own) == same_way:
                if gap + gap_own <= DIVIDED:
                    far_side.add(i)
            elif gap <= DIVIDED:
                this_side.add(i)
        if not far_side or max(self.widths[i] for i in far_side) <= max(self.widths[i] for i in this_side | set(own)):
            return set()
        return this_side | set(own)

    def disagrees(self, lat, lon, streets, corner):
        """Whether `corner` of `streets` (the MTA's way, the north-south one first) is wrong for
        where the entrance is: the nearest crossing of the two on the city's centrelines is
        past REACH (it's mid-block), or it's WRONG_SIDE metres or more across one of them. Not where they meet
        at under 30 degrees, or twice within 60 m (a divided road, whose roadways the
        entrance may be between), or don't meet near it: then nothing's known against it."""
        x, y = metres(lat, lon)
        ids = self.near(x, y, REACH * 2)
        ways = defaultdict(lambda: defaultdict(list))
        for i in ids:
            label, points = self.segments[i]
            name = mta_name(label)
            if name not in streets:
                continue
            for end, onward in ((points[0], points[1]), (points[-1], points[-2])):
                ways[(round(end[0], 1), round(end[1], 1))][name].append((onward[0] - end[0], onward[1] - end[1]))
        crossings = [node for node, named in ways.items() if len(named) == 2
                     and math.hypot(node[0] - x, node[1] - y) <= REACH * 2]
        if not crossings:
            return False
        node = min(crossings, key=lambda n: math.hypot(n[0] - x, n[1] - y))
        # Mid-block, past REACH from the nearest: not at a corner of it at all
        if math.hypot(node[0] - x, node[1] - y) > REACH:
            return True
        if any(other != node and math.hypot(other[0] - node[0], other[1] - node[1]) < 60 for other in crossings):
            return False

        def axis(name, north):
            sx = sy = 0.0
            for vx, vy in ways[node][name]:
                length = math.hypot(vx, vy) or 1
                vx, vy = vx / length, vy / length
                if (north and vy < 0) or (not north and vx < 0):
                    vx, vy = -vx, -vy
                sx, sy = sx + vx, sy + vy
            length = math.hypot(sx, sy) or 1
            return sx / length, sy / length

        up, right = axis(streets[0], True), axis(streets[1], False)
        if math.degrees(math.acos(min(1, abs(up[0] * right[0] + up[1] * right[1])))) < 30:
            return False
        dx, dy = x - node[0], y - node[1]
        north = dx * -right[1] + dy * right[0]
        east = dx * up[1] - dy * up[0]
        return ((corner[0] == "N") != (north > 0) and abs(north) >= WRONG_SIDE
                or (corner[1] == "E") != (east > 0) and abs(east) >= WRONG_SIDE)

    def best_crossing(self, x, y, ids):
        """The crossing of two streets of `ids` nearest (x, y): (score, node, (label, way),
        (label, way)), or None."""
        gap = {i: distance(x, y, self.segments[i][1]) for i in ids}
        # Where streets of two names meet: their pieces' ends, each with its way out of there
        arms = defaultdict(list)
        for i in ids:
            label, points = self.segments[i]
            for end, onward in ((points[0], points[1]), (points[-1], points[-2])):
                arms[(round(end[0], 1), round(end[1], 1))].append((label, (onward[0] - end[0], onward[1] - end[1]), gap[i]))
        best = None
        for node, out in arms.items():
            away = math.hypot(node[0] - x, node[1] - y)
            if away > REACH:
                continue
            # Each name's nearest arm: the two streets the entrance is between
            nearest = {}
            for label, way, off in out:
                if label not in nearest or off < nearest[label][1]:
                    nearest[label] = (way, off)
            if len(nearest) < 2:
                continue
            (a, (way_a, off_a)), (b, (way_b, off_b)) = sorted(nearest.items(), key=lambda kv: kv[1][1])[:2]
            score = away + off_a + off_b
            if best is None or score < best[0]:
                best = (score, node, (a, way_a), (b, way_b))
        return best


def ns_first(two):
    """Two (label, way) streets, the more north-south first."""
    return sorted(two, key=lambda street: -abs(street[1][1]) / math.hypot(*street[1]))


def distance(x, y, points):
    """Metres from a point to a line."""
    best = math.inf
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        dx, dy = x1 - x0, y1 - y0
        t = max(0, min(1, ((x - x0) * dx + (y - y0) * dy) / (dx * dx + dy * dy or 1)))
        best = min(best, math.hypot(x - x0 - t * dx, y - y0 - t * dy))
    return best


def place(lat, lon):
    """An entrance's key, as make_stations.py rounds its place."""
    return (round(float(lat), 6), round(float(lon), 6))


def main(entrances_path, centerlines_path, exceptions_path, target):
    with open(entrances_path, encoding="utf-8") as file:
        places = sorted({place(row["entrance_latitude"], row["entrance_longitude"]) for row in json.load(file)})
    with open(exceptions_path, encoding="utf-8") as file:
        exceptions = {place(e["lat"], e["lon"]): e for e in json.load(file)}
    streets = Streets.from_centerlines(centerlines_path)
    names, unnamed, kept, dropped = [], 0, 0, []
    for lat, lon in places:
        if (lat, lon) in exceptions:
            exception = exceptions[(lat, lon)]
            kept += 1
            if exception["streets"]:
                entry = {"lat": lat, "lon": lon, "streets": exception["streets"]}
                if exception.get("corner"):
                    entry["corner"] = exception["corner"]
                names.append({**entry, "source": "2015"})
            continue
        found = streets.crossing(lat, lon)
        if found is None:
            unnamed += 1
            continue
        labels, corner = found
        entry = {"lat": lat, "lon": lon, "streets": [mta_name(label) for label in labels]}
        if corner:
            entry["corner"] = corner
        names.append({**entry, "source": "city"})
    # A corner that's the wrong side of its own streets, by the city's centrelines, is left
    # out: the streets alone ("4 Av & 9 St") rather than send someone the wrong way
    for entry in names:
        if entry.get("corner") and streets.disagrees(entry["lat"], entry["lon"], entry["streets"], entry["corner"]):
            dropped.append(entry)
            del entry["corner"]
    stale = sorted(set(exceptions) - set(places))
    if stale:
        print(f"warning: exceptions for entrances no longer listed, left out: "
              f"{', '.join(f'{lat},{lon}' for lat, lon in stale)}", file=sys.stderr)
    with open(target, "w", encoding="utf-8") as file:
        file.write("[\n" + ",\n".join(json.dumps(n, ensure_ascii=False) for n in names) + "\n]\n")
    print(f"{len(places)} entrances: {sum(n['source'] == 'city' for n in names)} named from the city's streets, "
          f"{kept} by exceptions ({sum(n['source'] == '2015' for n in names)} from the 2015 list), "
          f"{unnamed} without a crossing nearby, {len(dropped)} corners left out as the wrong side of "
          f"their streets -> {target}")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:5])
