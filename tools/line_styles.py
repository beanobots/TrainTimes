#!/usr/bin/env python3
"""The subway's bullets as the app draws them, for the other tools: read from
ios/Shared/Lines.swift, so they can't drift from it. A real-time route's bullet
has a label ("S" for the three shuttles), a color, and black or white text, and
an express route in the feeds ("6X") has its line's.
"""
import os
import re
import sys

SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios", "Shared", "Lines.swift")


def _read(path):
    """LineStyle.of's styles by route, its default, Lines.normalized's express
    routes and Lines.filterRoutes, from the Swift."""
    with open(path, encoding="utf-8") as file:
        swift = file.read()
    style = r'LineStyle\(label:\s*(route|"\w+"),\s*color:\s*0x([0-9A-Fa-f]{6}),\s*usesDarkText:\s*(true|false)\)'
    styles = {}
    # case "1", "2", "3": LineStyle(label: route, color: 0xEE352E, usesDarkText: false)
    for routes, label, color, dark in re.findall(r'case\s+((?:"\w+",\s*)*"\w+"):\s*' + style, swift):
        for route in re.findall(r'"(\w+)"', routes):
            styles[route] = (route if label == "route" else label.strip('"'), int(color, 16), dark == "true")
    default = re.search(r"default:\s*" + style, swift)
    # ["5X": "5", "6X": "6", "7X": "7", "FX": "F"][route] ?? route
    express = re.search(r'\[((?:\s*"\w+":\s*"\w+",?)+)\s*\]\[route\]\s*\?\?\s*route', swift)
    filters = re.search(r"static let filterRoutes\s*=\s*\[([^\]]*)\]", swift)
    if not (styles and default and express and filters):
        sys.exit(f"Couldn't read the lines' bullets from {path}")
    express = dict(re.findall(r'"(\w+)":\s*"(\w+)"', express.group(1)))
    filters = re.findall(r'"(\w+)"', filters.group(1))
    missing = [route for route in filters if route not in styles]
    if missing:
        sys.exit(f"No bullet for {', '.join(missing)} in {path}")
    return styles, (int(default.group(2), 16), default.group(3) == "true"), express, filters


_STYLES, _DEFAULT, _EXPRESS, FILTER_ROUTES = _read(SOURCE)


def style(route):
    """(label, color as 0xRRGGBB, whether the label is black) for a real-time
    route id such as "R", "FS" or "SI", as LineStyle.of has it."""
    return _STYLES.get(route) or (route, *_DEFAULT)


def label(route):
    """What `route`'s bullet says, as the app has it: "6" for the 6 express
    ("6X" in the feeds), "S" for "GS"."""
    return style(_EXPRESS.get(route, route))[0]
