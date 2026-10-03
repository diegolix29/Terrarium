#!/usr/bin/env python3
"""Paint Colosseum walk-rig vertices, then write walk_overrides.lua.

This is the only vertex painter. Opening CHARACTER VIEWER writes
walk_debug_<id>.txt into the LOVE save folder (console prints the path):

    python tools/paint_walk_override.py walk_debug_wes.txt

Click to paint the current brush (keys 0-6). S saves walk_overrides.lua
next to the dump. After the buckets look right you can delete this script.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

BRUSHES = [
    ("torso", 1, 0.0),
    ("arm", -1, 1.0),
    ("arm", 1, 1.0),
    ("thigh", -1, 1.0),
    ("thigh", 1, 1.0),
    ("shin", -1, 1.0),
    ("shin", 1, 1.0),
]

COLORS = {
    ("torso", 1): (140, 140, 150),
    ("torso", -1): (140, 140, 150),
    ("arm", -1): (50, 190, 255),
    ("arm", 1): (255, 115, 40),
    ("thigh", -1): (60, 230, 90),
    ("thigh", 1): (240, 215, 40),
    ("shin", -1): (25, 140, 65),
    ("shin", 1): (215, 140, 25),
}


def load_debug(path: Path):
    verts = []
    ident = path.parent.name
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# walk_debug") and "id=" in line:
            ident = line.split("id=", 1)[1].strip() or ident
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 8:
            continue
        verts.append(
            {
                "gi": int(parts[0]),
                "vi": int(parts[1]),
                "x": float(parts[2]),
                "y": float(parts[3]),
                "z": float(parts[4]),
                "bucket": parts[5],
                "side": int(float(parts[6])),
                "weight": float(parts[7]),
            }
        )
    return ident, verts


def encode_overrides(verts) -> str:
    groups: dict[int, list] = {}
    for vert in verts:
        groups.setdefault(vert["gi"], []).append(vert)
    out = [
        "-- DRAMATIC_SHAPE walk overlay membership only.\n",
        "-- Do not treat this as model_cache or native_v1; idle/victory stay extracted.\n",
        'return {version=1,purpose="walk-overlay",groups={\n',
    ]
    for gi in sorted(groups):
        out.append("[%d]={" % gi)
        first = True
        for vert in groups[gi]:
            if not first:
                out.append(",")
            first = False
            out.append(
                '[%d]={bucket="%s",side=%s,weight=%.3f}'
                % (vert["vi"], vert["bucket"], vert["side"], vert["weight"])
            )
        out.append("},\n")
    out.append("}}\n")
    return "".join(out)


def run_tk(ident: str, verts, out_path: Path) -> None:
    import tkinter as tk

    brush = [2]
    yaw = [0.4]
    width, height, margin = 720, 720, 40
    ys = [vert["y"] for vert in verts]
    min_y, max_y = min(ys), max(ys)
    span = max(0.01, max_y - min_y)
    scale = (height - margin * 2) / span

    def project(vert):
        c, s = math.cos(yaw[0]), math.sin(yaw[0])
        rx = vert["x"] * c + vert["z"] * s
        return width * 0.5 + rx * scale, margin + (max_y - vert["y"]) * scale

    root = tk.Tk()
    root.title("Walk paint — %s  [0-6 brush, A/D rotate, S save]" % ident)
    canvas = tk.Canvas(root, width=width, height=height, bg="#1a1a1e")
    canvas.pack()
    status = tk.StringVar(value="brush %s" % BRUSHES[brush[0]][0])
    tk.Label(root, textvariable=status).pack()

    def redraw():
        canvas.delete("all")
        for vert in verts:
            x, y = project(vert)
            col = COLORS.get((vert["bucket"], vert["side"]), (180, 180, 180))
            hx = "#%02x%02x%02x" % col
            canvas.create_rectangle(x, y, x + 2, y + 2, outline=hx, fill=hx)
        canvas.create_text(
            12,
            12,
            anchor="nw",
            fill="#eee",
            text="0 torso  1/2 arm L/R  3/4 thigh  5/6 shin",
        )

    def paint_at(sx, sy):
        bucket, side, weight = BRUSHES[brush[0]]
        radius = 8.0
        count = 0
        for vert in verts:
            x, y = project(vert)
            if (x - sx) ** 2 + (y - sy) ** 2 <= radius * radius:
                vert["bucket"] = bucket
                vert["side"] = side
                vert["weight"] = weight
                count += 1
        status.set("painted %d  brush %s" % (count, bucket))
        redraw()

    def on_click(ev):
        paint_at(ev.x, ev.y)

    def on_key(ev):
        key = ev.keysym.lower()
        if key in "0123456":
            brush[0] = int(key)
            status.set("brush %s" % BRUSHES[brush[0]][0])
        elif key in ("a", "left"):
            yaw[0] -= 0.12
            redraw()
        elif key in ("d", "right"):
            yaw[0] += 0.12
            redraw()
        elif key == "s":
            out_path.write_text(encode_overrides(verts), encoding="utf-8")
            status.set("wrote %s" % out_path)

    canvas.bind("<Button-1>", on_click)
    canvas.bind("<B1-Motion>", on_click)
    root.bind("<Key>", on_key)
    redraw()
    root.mainloop()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src = Path(sys.argv[1])
    ident, verts = load_debug(src)
    if not verts:
        print("no verts in", src)
        return 1
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_name("walk_overrides.lua")
    try:
        run_tk(ident, verts, out)
    except ImportError:
        out.write_text(encode_overrides(verts), encoding="utf-8")
        print("tkinter unavailable; wrote current buckets to", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
