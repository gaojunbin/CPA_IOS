#!/usr/bin/env python3
"""Generate the iOS AppIcon set from the macOS-matching SVG.

Renders AppIcon-iOS.svg (a full-bleed variant of the macOS AppIcon.svg) with
QuickLook, center-crops away QuickLook's rounded-corner margin, flattens the
alpha channel (App Store rejects alpha on icons), then resizes every slot
declared in Contents.json.

Usage: python3 Scripts/generate_app_icons.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
SVG = ICONSET / "AppIcon-iOS.svg"
CONTENTS = ICONSET / "Contents.json"
RENDER = 1240  # render larger so QuickLook's rounded margin is cropped away
MASTER = 1024


def make_master(tmp: Path) -> Image.Image:
    subprocess.run(
        ["qlmanage", "-t", "-s", str(RENDER), "-o", str(tmp), str(SVG)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    rendered = tmp / f"{SVG.name}.png"
    if not rendered.exists():
        sys.exit(f"QuickLook did not produce {rendered}")
    img = Image.open(rendered).convert("RGBA")
    # center-crop to MASTER to drop the rounded/transparent margin
    left = (img.width - MASTER) // 2
    top = (img.height - MASTER) // 2
    img = img.crop((left, top, left + MASTER, top + MASTER))
    # flatten alpha onto opaque background (corners are already filled gradient)
    flat = Image.new("RGB", img.size, (15, 23, 42))  # #0f172a, matches gradient start
    flat.paste(img, mask=img.split()[3])
    return flat


def main() -> None:
    contents = json.loads(CONTENTS.read_text())
    with tempfile.TemporaryDirectory() as td:
        master = make_master(Path(td))
        for image in contents["images"]:
            size = float(image["size"].split("x")[0])
            scale = int(image["scale"].rstrip("x"))
            px = round(size * scale)
            out = master.resize((px, px), Image.LANCZOS)
            out.save(ICONSET / image["filename"], "PNG")
            print(f"{image['filename']:<28} {px}x{px}")
    print(f"\nGenerated {len(contents['images'])} icons into {ICONSET}")


if __name__ == "__main__":
    main()
