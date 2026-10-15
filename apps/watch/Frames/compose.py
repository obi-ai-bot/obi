"""Turns render.mjs's frames into the watch's asset catalogs.

Usage: python3 apps/watch/Frames/compose.py <frames-dir> <repo-root>   (needs Pillow)

- apps/watch/Frames.xcassets: one image set per frame, oby-<loop>-<nnn>, 160 px (80 pt at 2x). Every
  loop shares one crop, so Oby doesn't jump when the loop changes. The last frames of each loop
  are crossfaded into the calm frames rendered before it, so the end runs into the start.
- apps/watch/Widget/Assets.xcassets: the still poses the complications draw, cropped tight.
"""
import json
import shutil
import sys
from pathlib import Path

from PIL import Image

FRAME_PX = 160
STILL_PX = 128
# The still poses: (image set, loop, frame).
STILLS = [("ObyCalm", "idle", 30), ("ObyWorking", "working", 30), ("ObyNeedsYou", "needs", 25)]
CROP_LOOPS = {"idle", "working", "needs"}


def contents(images=None):
    data = {"info": {"author": "xcode", "version": 1}}
    if images is not None:
        data["images"] = images
    return json.dumps(data, indent=2) + "\n"


def union_box(paths):
    box = None
    for path in paths:
        b = Image.open(path).getchannel("A").getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


def square(box, size, pad):
    """The smallest square around box, grown by pad, kept inside the frame."""
    x0, y0, x1, y1 = box
    side = min(size, int(max(x1 - x0, y1 - y0) * (1 + 2 * pad)))
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    left = int(min(max(cx - side / 2, 0), size - side))
    top = int(min(max(cy - side / 2, 0), size - side))
    return left, top, left + side, top + side


def scaled(image, crop, px):
    # Premultiplied, so the edges don't pick up a dark fringe when blended and scaled.
    return image.crop(crop).convert("RGBa").resize((px, px), Image.Resampling.LANCZOS).convert("RGBA")


def write_set(folder, name, image):
    folder = folder / f"{name}.imageset"
    folder.mkdir(parents=True)
    image.save(folder / f"{name}.png", optimize=True)
    (folder / "Contents.json").write_text(contents([{"filename": f"{name}.png", "idiom": "universal", "scale": "2x"}]))


def main(frames_dir, repo):
    frames_dir, repo = Path(frames_dir), Path(repo)
    loops = sorted(p for p in frames_dir.iterdir() if p.is_dir())
    every = sorted(frames_dir.glob("*/*.png"))
    size = Image.open(every[0]).width
    # The loops Home plays all the time set the crop; the tap reactions share it, so Oby keeps its
    # size, and a reaction's flourish past it is cut off.
    crop = square(union_box([p for p in every if p.parent.name in CROP_LOOPS]), size, 0.02)

    catalog = repo / "apps/watch/Frames.xcassets"
    shutil.rmtree(catalog, ignore_errors=True)
    catalog.mkdir(parents=True)
    (catalog / "Contents.json").write_text(contents())
    for loop in loops:
        pre = sorted(loop.glob("pre-*.png"))
        frames = sorted(p for p in loop.glob("*.png") if not p.name.startswith("pre-"))
        group = catalog / loop.name
        group.mkdir()
        (group / "Contents.json").write_text(contents())
        tail = len(frames) - len(pre)
        for i, path in enumerate(frames):
            image = Image.open(path).convert("RGBA")
            if i >= tail:
                # Fade into the calm frames that lead into frame 0.
                j = i - tail
                lead = Image.open(pre[j]).convert("RGBA")
                image = Image.blend(image.convert("RGBa"), lead.convert("RGBa"), (j + 1) / (len(pre) + 1)).convert("RGBA")
            write_set(group, f"oby-{loop.name}-{i:03d}", scaled(image, crop, FRAME_PX))
        print(f"{loop.name}: {len(frames)} frames")

    stills = repo / "apps/watch/Widget/Assets.xcassets"
    shutil.rmtree(stills, ignore_errors=True)
    stills.mkdir(parents=True)
    (stills / "Contents.json").write_text(contents())
    for name, loop, index in STILLS:
        image = Image.open(frames_dir / loop / f"{index:03d}.png").convert("RGBA")
        write_set(stills, name, scaled(image, square(image.getchannel("A").getbbox(), size, 0.04), STILL_PX))
    print("stills:", ", ".join(name for name, _, _ in STILLS))


if __name__ == "__main__":
    main(*sys.argv[1:3])
