#!/usr/bin/env python3
"""Convert Reloded / KIM HD Pokémon GIFs into Terrarium sprite sheets + Lua metadata.

Expected input names:
  <dex>-front-n.gif, <dex>-front-s.gif, <dex>-back-n.gif, <dex>-back-s.gif
Optional gender suffixes: ...-m.gif / ...-f.gif

Default National Dex range is 1-493 (Platinum). Sheets are written under
assets/battle/hd-pokemon/; metadata is data/hd_pokemon.lua (dex-keyed).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import io
import math
import os
import re
import shutil
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image
import threading

DEX_MAX_DEFAULT = 493
PROGRESS_LOCK = threading.Lock()
PROGRESS_PATH: Path | None = None
_LAST_PROGRESS = 0.0


def write_progress(state: str, current: int, total: int, message: str = "", force: bool = False) -> None:
    """Update the in-game bar. Never os.replace: LOVE may have the file open on
    Windows, and replace then raises WinError 5 and aborts the convert."""
    global _LAST_PROGRESS
    if PROGRESS_PATH is None:
        return
    now = time.monotonic()
    if not force and state == "converting" and (now - _LAST_PROGRESS) < 0.20:
        return
    _LAST_PROGRESS = now
    safe_message = message.encode('ascii', 'replace').decode('ascii')
    text = f"{state}\n{int(current)}\n{int(total)}\n{safe_message}\n"
    with PROGRESS_LOCK:
        last_error = None
        for _ in range(12):
            try:
                with open(PROGRESS_PATH, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(text)
                    fh.flush()
                    try:
                        os.fsync(fh.fileno())
                    except OSError:
                        pass
                return
            except OSError as err:
                last_error = err
                time.sleep(0.05)
        if last_error and force:
            raise last_error
NAME_RE = re.compile(
    r"^(?P<dex>\d+)-(?P<side>front|back)-(?P<color>[ns])(?:-(?P<gender>[fm]))?\.gif$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class SourceGif:
    source: Path
    member: str | None
    name: str

    def read_bytes(self) -> bytes:
        if self.member is None:
            return self.source.read_bytes()
        with zipfile.ZipFile(self.source) as zf:
            return zf.read(self.member)


def iter_source(path: Path) -> Iterable[SourceGif]:
    if path.is_dir():
        for p in sorted(path.rglob("*.gif")):
            yield SourceGif(p, None, p.name)
        return
    if path.is_file() and path.suffix.lower() == ".gif":
        yield SourceGif(path, None, path.name)
        return
    if not path.is_file() or not zipfile.is_zipfile(path):
        raise ValueError(f"Not a GIF folder or ZIP archive: {path}")
    with zipfile.ZipFile(path) as zf:
        for member in sorted(zf.namelist()):
            if member.lower().endswith(".gif"):
                yield SourceGif(path, member, Path(member).name)


def choose_grid(frame_count: int, width: int, height: int, max_texture: int) -> tuple[int, int]:
    max_cols = min(frame_count, max_texture // width)
    max_rows = max_texture // height
    if max_cols < 1 or max_rows < 1:
        raise ValueError(
            f"single frame {width}x{height} exceeds max texture size {max_texture}"
        )
    min_cols = max(1, math.ceil(frame_count / max_rows))
    if min_cols > max_cols:
        raise ValueError(
            f"{frame_count} frames of {width}x{height} cannot fit inside {max_texture}x{max_texture}"
        )
    best = None
    for cols in range(min_cols, max_cols + 1):
        rows = math.ceil(frame_count / cols)
        sw, sh = cols * width, rows * height
        if sw > max_texture or sh > max_texture:
            continue
        score = (max(sw, sh), abs(sw - sh), sw * sh, cols)
        if best is None or score < best[0]:
            best = (score, cols, rows)
    if best is None:
        raise ValueError("no valid sprite-sheet grid found")
    return best[1], best[2]


def display_scale(side: str) -> float:
    return 0.315 if side == "back" else 0.33


def gif_to_sheet(data: bytes, out_path: Path, max_texture: int, scale: float, compress_level: int) -> dict:
    im = Image.open(io.BytesIO(data))
    frames = int(getattr(im, "n_frames", 1) or 1)
    source_width, source_height = im.size
    width = max(1, int(round(source_width * scale)))
    height = max(1, int(round(source_height * scale)))
    cols, _rows = choose_grid(frames, width, height, max_texture)
    sheet = Image.new("RGBA", (cols * width, math.ceil(frames / cols) * height), (0, 0, 0, 0))
    durations: list[int] = []
    for i in range(frames):
        im.seek(i)
        frame = im.convert("RGBA")
        if frame.size != (width, height):
            frame = frame.resize((width, height), Image.Resampling.LANCZOS)
        x = (i % cols) * width
        y = (i // cols) * height
        sheet.alpha_composite(frame, (x, y))
        durations.append(max(1, int(im.info.get("duration") or 50)))
    sheet = sheet.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_path, format="PNG", optimize=False, compress_level=compress_level)
    return {"width": width, "height": height, "columns": cols, "frames": frames, "durations": durations}


def gif_metadata(data: bytes, image_path: str, max_texture: int, scale: float) -> dict:
    im = Image.open(io.BytesIO(data))
    frame_count = int(getattr(im, "n_frames", 1) or 1)
    source_w, source_h = im.size
    w = max(1, int(round(source_w * scale)))
    h = max(1, int(round(source_h * scale)))
    cols, _ = choose_grid(frame_count, w, h, max_texture)
    durations = []
    for i in range(frame_count):
        im.seek(i)
        durations.append(max(1, int(im.info.get("duration") or 50)))
    return {
        "width": w, "height": h, "columns": cols, "frames": frame_count,
        "durations": durations, "image": image_path,
    }


def output_png_is_valid(path: Path) -> bool:
    if not path.is_file() or path.stat().st_size <= 0:
        return False
    try:
        with Image.open(path) as im:
            im.verify()
        return True
    except Exception:
        return False


def lua_record(image: str, meta: dict) -> str:
    durations = ",".join(str(v) for v in meta["durations"])
    return (
        "{ image = %r, width = %d, height = %d, columns = %d, frames = %d, durations = {%s}, displayScale = %.6f }"
        % (
            image,
            meta["width"],
            meta["height"],
            meta["columns"],
            meta["frames"],
            durations,
            float(meta.get("displayScale", 1.0)),
        )
    ).replace("'", '"')


def write_metadata(path: Path, records: dict[int, dict]) -> None:
    lines = [
        "-- Generated by tools/import_hd_pokemon.py. Do not hand-edit.",
        "-- National Dex 1-493 HD front/back sheets (normal + shiny).",
        "return {",
    ]
    for dex in sorted(records):
        species = records[dex]
        lines.append(f"  [{dex}] = {{")
        lines.append(f"    dex = {dex},")
        for side in ("front", "back"):
            side_rec = species.get(side)
            if not side_rec:
                continue
            lines.append(f"    {side} = {{")
            for color_name in ("normal", "shiny"):
                color_rec = side_rec.get(color_name)
                if not color_rec:
                    continue
                lines.append(f"      {color_name} = {{")
                for gender in ("default", "male", "female"):
                    rec = color_rec.get(gender)
                    if rec:
                        lines.append(f"        {gender} = {lua_record(rec['image'], rec)},")
                lines.append("      },")
            lines.append("    },")
        lines.append("  },")
    lines.append("}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_file_list(path: Path, records: dict[int, dict], metadata_only: bool) -> None:
    names = ["data/hd_pokemon.lua"]
    if not metadata_only:
        for species in records.values():
            for side_rec in species.values():
                if not isinstance(side_rec, dict):
                    continue
                for color_rec in side_rec.values():
                    if not isinstance(color_rec, dict):
                        continue
                    for rec in color_rec.values():
                        image = rec.get("image") if isinstance(rec, dict) else None
                        if image:
                            names.append(str(image).replace("\\", "/"))
    unique = list(dict.fromkeys(names))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(unique) + "\n", encoding="utf-8")


def _convert_job(job, max_texture, scale, compress_level):
    dex, side, color, gender, item, out, rel = job
    data = item.read_bytes()
    meta = gif_to_sheet(data, out, max_texture, scale, compress_level)
    meta["image"] = rel.as_posix()
    meta["displayScale"] = display_scale(side)
    return dex, side, color, gender, item.name, meta


def main() -> int:
    ap = argparse.ArgumentParser(description="Convert HD Pokémon GIFs for Terrarium (dex 1-493).")
    ap.add_argument("sources", nargs="+", type=Path, help="GIF folders or ZIP archives")
    ap.add_argument("--target", type=Path, default=Path(__file__).resolve().parents[1],
                    help="Terrarium Advance Mod folder (ignored when --out is set)")
    ap.add_argument("--out", type=Path, default=None,
                    help="Write sheets and data/hd_pokemon.lua here instead of --target")
    ap.add_argument("--progress-file", type=Path, default=None,
                    help="Write CONVERTING/DONE/FAIL progress for the in-game import screen")
    ap.add_argument("--clean", action="store_true")
    ap.add_argument("--max-dex", type=int, default=DEX_MAX_DEFAULT)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--metadata-only", action="store_true")
    ap.add_argument("--max-texture", type=int, default=8192)
    ap.add_argument("--scale", type=float, default=0.60)
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    ap.add_argument("--compress-level", type=int, choices=range(0, 10), default=6, metavar="0-9")
    args = ap.parse_args()
    global PROGRESS_PATH
    if args.progress_file is not None:
        PROGRESS_PATH = args.progress_file.resolve()
        PROGRESS_PATH.parent.mkdir(parents=True, exist_ok=True)
        write_progress("converting", 0, 1, "STARTING")
    if not (0.10 <= args.scale <= 1.00):
        ap.error("--scale must be between 0.10 and 1.00")
    if not (1 <= args.max_dex <= 721):
        ap.error("--max-dex must be between 1 and 721")

    try:
        if args.out is not None:
            dest = args.out.resolve()
            dest.mkdir(parents=True, exist_ok=True)
        else:
            dest = args.target.resolve()
            if not (dest / "manifest.json").is_file():
                ap.error(f"target does not look like a Terrarium mod folder: {dest}")

        asset_root = dest / "assets" / "battle" / "hd-pokemon"
        metadata_path = dest / "data" / "hd_pokemon.lua"
        if args.clean:
            shutil.rmtree(asset_root, ignore_errors=True)
            try:
                metadata_path.unlink()
            except FileNotFoundError:
                pass

        found = {}
        write_progress("converting", 0, 1, "SCANNING")
        for source_path in args.sources:
            for item in iter_source(source_path.resolve()):
                m = NAME_RE.match(item.name)
                if not m:
                    continue
                dex = int(m.group("dex"))
                if not (1 <= dex <= args.max_dex):
                    continue
                side = m.group("side").lower()
                color = "normal" if m.group("color").lower() == "n" else "shiny"
                gender_raw = (m.group("gender") or "").lower()
                gender = "male" if gender_raw == "m" else "female" if gender_raw == "f" else "default"
                key = (dex, side, color, gender)
                if key in found:
                    raise RuntimeError(f"duplicate asset for {key}: {found[key].name} and {item.name}")
                found[key] = item

        if not found:
            raise RuntimeError("no matching HD Pokemon GIFs found")

        records: dict[int, dict] = {}
        total = len(found)
        write_progress("converting", 0, total, "CONVERTING")
        if args.metadata_only:
            for index, ((dex, side, color, gender), item) in enumerate(sorted(found.items()), 1):
                suffix = "" if gender == "default" else "-m" if gender == "male" else "-f"
                rel = Path("assets") / "battle" / "hd-pokemon" / side / color / f"{dex:03d}{suffix}.png"
                meta = gif_metadata(item.read_bytes(), rel.as_posix(), args.max_texture, args.scale)
                meta["displayScale"] = display_scale(side)
                species = records.setdefault(dex, {})
                species.setdefault(side, {}).setdefault(color, {})[gender] = meta
                write_progress("converting", index, total, item.name)
                if index % 100 == 0 or index == total:
                    safe_name = item.name.encode('ascii', 'replace').decode('ascii')
                    print(f"[{index:4d}/{total}] {safe_name}", flush=True)
        else:
            jobs = []
            reused = 0
            for (dex, side, color, gender), item in sorted(found.items()):
                suffix = "" if gender == "default" else "-m" if gender == "male" else "-f"
                rel = Path("assets") / "battle" / "hd-pokemon" / side / color / f"{dex:03d}{suffix}.png"
                out = dest / rel
                if not args.force and output_png_is_valid(out):
                    meta = gif_metadata(item.read_bytes(), rel.as_posix(), args.max_texture, args.scale)
                    meta["displayScale"] = display_scale(side)
                    species = records.setdefault(dex, {})
                    species.setdefault(side, {}).setdefault(color, {})[gender] = meta
                    reused += 1
                    write_progress("converting", reused, total, item.name)
                else:
                    jobs.append((dex, side, color, gender, item, out, rel))
            if reused:
                print(f"Reusing {reused} sheets; converting {len(jobs)} GIFs.", flush=True)
            workers = max(1, int(args.workers))
            if jobs:
                with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                    futures = [pool.submit(_convert_job, job, args.max_texture, args.scale, args.compress_level) for job in jobs]
                    for index, fut in enumerate(concurrent.futures.as_completed(futures), 1):
                        dex, side, color, gender, name, meta = fut.result()
                        species = records.setdefault(dex, {})
                        species.setdefault(side, {}).setdefault(color, {})[gender] = meta
                        write_progress("converting", reused + index, total, name)
                        if index % 25 == 0 or index == len(jobs):
                            safe_name = name.encode('ascii', 'replace').decode('ascii')
                            print(f"[{index:4d}/{len(jobs)}] {safe_name}", flush=True)

        write_progress("converting", total, total, "WRITING")
        write_metadata(metadata_path, records)
        write_file_list(dest / "files.txt", records, args.metadata_only)
        write_progress("done", len(records), total, "READY")
        print(f"\nGenerated metadata for {len(records)} species from {total} GIFs (max dex {args.max_dex}).")
        print(f"Metadata: {metadata_path.as_posix()}")
        if not args.metadata_only:
            print(f"Sprites:  {asset_root.as_posix()}")
        return 0
    except Exception as err:
        write_progress("fail", 0, 1, str(err))
        raise


if __name__ == "__main__":
    raise SystemExit(main())
