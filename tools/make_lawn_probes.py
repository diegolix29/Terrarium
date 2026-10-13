"""Solid-swirl probe tiles for Gen4Lawn, matching grass.png / road.png size."""
import math
import os
import struct
import zlib

DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "ground", "grass")

# Distinct hues so walking the map shows which unmapped id is which.
PROBES = {
    "flowers.png": (232, 72, 168),   # magenta -- flower beds
    "wild.png":    (168, 216, 24),   # yellow-green -- tall-grass floor
    "snow.png":    (232, 244, 255),  # pale ice
    "waterp.png":  (40, 196, 220),   # cyan -- puddles / leftover water
    "lamp.png":    (240, 176, 32),   # amber -- Jubilife lamps
    "object.png":  (138, 74, 224),   # purple -- city objects
    "trees.png":   (24, 104, 40),    # forest -- leftover native tree cards
    "shadow.png":  (36, 32, 48),     # near-black -- tshadow
    "step.png":    (96, 108, 128),   # slate -- stairs / cycle stop / fence
}


def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def swirl_png(path, w, h, rgb):
    cr, cg, cb = rgb
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            n = (
                math.sin(x * 0.11 + y * 0.07)
                + 0.55 * math.sin(x * 0.05 - y * 0.13)
                + 0.35 * math.sin((x + y) * 0.19)
            ) / 1.9
            k = 0.58 + 0.42 * (0.5 + 0.5 * n)
            row += bytes((
                max(0, min(255, int(cr * k))),
                max(0, min(255, int(cg * k))),
                max(0, min(255, int(cb * k))),
            ))
        rows.append(bytes(row))
    raw = b"".join(rows)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(DIR, exist_ok=True)
    for name, rgb in PROBES.items():
        path = os.path.normpath(os.path.join(DIR, name))
        swirl_png(path, 128, 128, rgb)
        print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
