#!/usr/bin/env python3
"""Generate ``proton-vpn/assets/land.json``: a dot-matrix land mask of the world.

One-off generator. It downloads the Natural Earth 110m land polygons (public
domain GeoJSON) with urllib, then rasterises them onto an equirectangular grid
by testing each cell centre against every polygon ring with even-odd ray
casting. The result is one string per grid row, ``#`` for land and ``.`` for
water, which ``bin/proton-vpn-map`` turns into the SVG background dots.

The grid is square-celled: the column pitch is 360/cols degrees of longitude and
rows use the same pitch in degrees of latitude, so the SVG can draw the mask on
a uniform pixel pitch. The latitude window stops at -58 so Antarctica drops out.

Output is deterministic: same input GeoJSON, same bytes. Run it, eyeball the
ASCII art it prints to stderr, and commit assets/land.json.

    python3 proton-vpn/tools/gen-land-mask.py [--out PATH] [--cols N]
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import sys
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    "master/geojson/ne_110m_land.geojson"
)

DEFAULT_COLS = 126
LAT_TOP = 75
LAT_BOTTOM = -58
LON_LEFT = -180
LON_RIGHT = 180


def fetch_geojson(url: str) -> dict:
    """Download and decode the land GeoJSON."""
    req = urllib.request.Request(url, headers={"User-Agent": "noctalia-proton-vpn/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def iter_rings(geojson: dict):
    """Yield every linear ring of every (Multi)Polygon as a list of (lon, lat)."""
    for feature in geojson.get("features", []):
        geom = feature.get("geometry") or {}
        kind = geom.get("type")
        coords = geom.get("coordinates") or []
        if kind == "Polygon":
            polygons = [coords]
        elif kind == "MultiPolygon":
            polygons = coords
        else:
            continue
        for polygon in polygons:
            for ring in polygon:
                if len(ring) >= 4:
                    yield [(float(p[0]), float(p[1])) for p in ring]


def ring_edges(rings) -> list[tuple[float, float, float, float]]:
    """Flatten rings into (lon1, lat1, lon2, lat2) edges, dropping horizontal ones."""
    edges = []
    for ring in rings:
        for i in range(len(ring) - 1):
            x1, y1 = ring[i]
            x2, y2 = ring[i + 1]
            if y1 != y2:
                edges.append((x1, y1, x2, y2))
    return edges


def row_crossings(edges, lat: float) -> list[float]:
    """Sorted longitudes where a westward ray at ``lat`` crosses the edges."""
    xs = []
    for x1, y1, x2, y2 in edges:
        if (y1 > lat) != (y2 > lat):
            xs.append(x1 + (lat - y1) * (x2 - x1) / (y2 - y1))
    xs.sort()
    return xs


def build_mask(edges, cols: int, rows: int, row_deg: float, col_deg: float) -> list[str]:
    """Rasterise the edges into ``rows`` strings of ``cols`` characters."""
    mask = []
    for r in range(rows):
        lat = LAT_TOP - (r + 0.5) * row_deg
        xs = row_crossings(edges, lat)
        line = []
        for c in range(cols):
            lon = LON_LEFT + (c + 0.5) * col_deg
            # Even-odd rule: odd number of crossings to the east means inside.
            inside = (len(xs) - bisect.bisect_right(xs, lon)) % 2 == 1
            line.append("#" if inside else ".")
        mask.append("".join(line))
    return mask


def print_ascii(mask: list[str], cols: int, col_deg: float) -> None:
    """Draw the mask to stderr with a longitude ruler so a human can check it."""
    ruler = [" "] * cols
    for lon in range(-180, 181, 30):
        c = int((lon - LON_LEFT) / col_deg)
        if 0 <= c < cols:
            ruler[c] = "|"
    print("".join(ruler), file=sys.stderr)
    for i, line in enumerate(mask):
        lat = LAT_TOP - (i + 0.5) * (360.0 / cols)
        print(f"{line}  {lat:6.1f}", file=sys.stderr)
    print("".join(ruler), file=sys.stderr)


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(os.path.dirname(here), "assets", "land.json")

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=default_out, help="output land.json path")
    parser.add_argument("--cols", type=int, default=DEFAULT_COLS, help="grid columns")
    parser.add_argument("--url", default=SOURCE_URL, help="Natural Earth land GeoJSON URL")
    parser.add_argument(
        "--geojson", help="read the GeoJSON from this local file instead of downloading"
    )
    args = parser.parse_args()

    if args.geojson:
        with open(args.geojson, "r", encoding="utf-8") as fh:
            geojson = json.load(fh)
    else:
        print(f"downloading {args.url}", file=sys.stderr)
        geojson = fetch_geojson(args.url)

    edges = ring_edges(list(iter_rings(geojson)))
    print(f"{len(edges)} polygon edges", file=sys.stderr)

    cols = args.cols
    col_deg = (LON_RIGHT - LON_LEFT) / cols
    row_deg = col_deg  # square cells
    rows = int(round((LAT_TOP - LAT_BOTTOM) / row_deg))

    mask = build_mask(edges, cols, rows, row_deg, col_deg)
    land = sum(line.count("#") for line in mask)
    print(f"grid {cols}x{rows}, {land} land cells", file=sys.stderr)
    print_ascii(mask, cols, col_deg)

    payload = {
        "cols": cols,
        "rows": rows,
        "latTop": LAT_TOP,
        "latBottom": LAT_BOTTOM,
        "lonLeft": LON_LEFT,
        "lonRight": LON_RIGHT,
        "mask": mask,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, sort_keys=False)
        fh.write("\n")
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
