#!/usr/bin/env python3
"""Check a screenshot is legible and tightly cropped before it ships.

    python3 verify.py <file.png> [more.png ...]

Reports, per file:
  dimensions      and whether they clear the legibility floor
  uniform border  how much of each edge is a single flat colour - a wide band
                  means the capture region was too generous. This is the only
                  gating check.
  flat background share, for information. A light table is legitimately mostly
                  background, so this is not thresholded.

Exit status is non-zero if any file fails a check, so this can gate a commit.

Dimensions come from PIL when it is installed and from `sips` (a macOS builtin)
otherwise. The border and dead-area analysis needs PIL; without it those checks
are skipped and reported as skipped rather than silently passing.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

# Re-exec into the skill's own venv when PIL is missing here. The border and
# dead-area checks are the ones that actually discriminate a good capture from
# a bad one, so running without them is close to not running at all.
if "PIL_BOOTSTRAPPED" not in os.environ:
    try:
        import PIL  # noqa: F401
    except ImportError:
        _venv = pathlib.Path(__file__).resolve().parent / ".venv" / "bin" / "python"
        if _venv.exists():
            os.environ["PIL_BOOTSTRAPPED"] = "1"
            os.execv(str(_venv), [str(_venv), __file__, *sys.argv[1:]])

# A width floor catches only the most obvious failures: a full-viewport capture
# lands around 1512 wide too, so size alone does NOT separate a good capture
# from a bad one. Dead space does, which is why that check is the gating one.
MIN_WIDTH = 1200
MIN_HEIGHT = 300

# A uniform edge band wider than this is croppable margin. This is the GATING
# check: a wide flat border means the region took in more than the content.
MAX_BORDER_PX = 60

# Flat-background share is reported but NOT gated. A light-mode table is
# legitimately 90%+ background - whitespace between rows is not waste - so
# thresholding on it flags good captures. Read it alongside the border.

try:
    from PIL import Image
except ImportError:
    Image = None


def dims_via_sips(path: pathlib.Path):
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    w = h = None
    for line in out.splitlines():
        if "pixelWidth:" in line:
            w = int(line.split(":")[1])
        elif "pixelHeight:" in line:
            h = int(line.split(":")[1])
    return (w, h) if w and h else None


# JPEG does not preserve a flat colour exactly, so an equality test reports 0%
# background on an image that is visibly half empty. Compare with a tolerance.
TOL = 8


def near(a, b):
    return abs(a[0] - b[0]) <= TOL and abs(a[1] - b[1]) <= TOL and abs(a[2] - b[2]) <= TOL


def uniform_border(img, bg):
    """Width of the flat-coloured band on each edge, in pixels."""
    w, h = img.size
    px = img.load()

    def row_flat(y):
        return all(near(px[x, y], bg) for x in range(0, w, max(1, w // 120)))

    def col_flat(x):
        return all(near(px[x, y], bg) for y in range(0, h, max(1, h // 120)))

    top = next((y for y in range(h) if not row_flat(y)), h)
    bottom = next((y for y in range(h - 1, -1, -1) if not row_flat(y)), -1)
    left = next((x for x in range(w) if not col_flat(x)), w)
    right = next((x for x in range(w - 1, -1, -1) if not col_flat(x)), -1)
    return {"top": top, "bottom": h - 1 - bottom, "left": left, "right": w - 1 - right}


def dominant_colour(img):
    """The most common colour, quantised.

    NOT the top-left pixel: many consoles put a banner or a logo there, and
    sampling it makes every later comparison meaningless. The OpenShift console
    has a red notice bar across the top, which is how this was found.
    """
    small = img.resize((160, 160))
    counts = {}
    px = small.load()
    for y in range(160):
        for x in range(160):
            q = tuple(c // 8 * 8 for c in px[x, y])
            counts[q] = counts.get(q, 0) + 1
    return max(counts, key=counts.get)


def dead_share(img, bg):
    """Share of sampled pixels that are exactly the background colour."""
    w, h = img.size
    px = img.load()
    step_x, step_y = max(1, w // 200), max(1, h // 200)
    total = flat = 0
    for y in range(0, h, step_y):
        for x in range(0, w, step_x):
            total += 1
            if near(px[x, y], bg):
                flat += 1
    return flat / total if total else 0.0


def check(path: pathlib.Path) -> bool:
    if not path.exists():
        print("  %-44s MISSING" % path.name)
        return False

    ok = True
    size = None
    if Image is not None:
        with Image.open(path) as im:
            size = im.size
    else:
        size = dims_via_sips(path)

    if size is None:
        print("  %-44s could not read dimensions" % path.name)
        return False

    w, h = size
    kb = path.stat().st_size // 1024
    small = w < MIN_WIDTH or h < MIN_HEIGHT
    print("  %-44s %dx%d  %dKB%s" % (path.name, w, h, kb,
                                     "   <-- TOO SMALL" if small else ""))
    if small:
        print("      width %d < %d or height %d < %d." % (w, MIN_WIDTH, h, MIN_HEIGHT))
        print("      Looks like a full-viewport `screenshot`; use `zoom` with a region.")
        ok = False

    if Image is None:
        print("      (border and dead-area checks skipped: PIL not installed)")
        return ok

    with Image.open(path) as im:
        im = im.convert("RGB")
        bg = dominant_colour(im)
        border = uniform_border(im, bg)
        dead = dead_share(im, bg)

    worst = max(border.values())
    print("      border  top %(top)d  bottom %(bottom)d  left %(left)d  right %(right)d" % border)
    print("      flat background: %.0f%%" % (dead * 100))

    if worst > MAX_BORDER_PX:
        side = max(border, key=border.get)
        print("      <-- %d px of flat %s margin. Tighten the region." % (worst, side))
        ok = False
    return ok


def main() -> int:
    files = [pathlib.Path(a) for a in sys.argv[1:]]
    if not files:
        print(__doc__)
        return 2
    print("checking %d file(s)%s" % (len(files),
          "" if Image else "   [PIL absent: dimensions only]"))
    results = [check(f) for f in files]
    bad = results.count(False)
    print()
    print("  %d ok, %d need attention" % (results.count(True), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
