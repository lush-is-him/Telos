"""Draws the Telos app icon: a 3x3 heatmap grid whose bright cells spell a T.

Run from the repo root:  python assets/icon/make_icon.py
Then:                    dart run flutter_launcher_icons
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).parent
S = 1024  # master size; drawn at 4x and downsampled for smooth edges
SS = S * 4

BG = (22, 64, 56)  # deep teal, darker than the app's seed colour
BRIGHT = (126, 226, 184)  # "MIT done" cell
DIM = (38, 90, 79)  # "nothing logged" cell
MID = (56, 122, 106)  # "something done" cell

# 1 = bright, 2 = mid, 0 = dim. Top row + middle column = T.
GRID = [
    [1, 1, 1],
    [0, 1, 2],
    [2, 1, 0],
]
COLOURS = {0: DIM, 1: BRIGHT, 2: MID}


def draw_grid(img: Image.Image, extent: float) -> None:
    """Draw the grid centred, spanning `extent` (fraction of the canvas)."""
    d = ImageDraw.Draw(img)
    size = img.width * extent
    gap = size * 0.07
    cell = (size - 2 * gap) / 3
    radius = cell * 0.22
    x0 = y0 = (img.width - size) / 2
    for r, row in enumerate(GRID):
        for c, v in enumerate(row):
            x, y = x0 + c * (cell + gap), y0 + r * (cell + gap)
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=radius, fill=COLOURS[v])


def save(img: Image.Image, name: str) -> None:
    img.resize((S, S), Image.LANCZOS).save(OUT / name)
    print("wrote", OUT / name)


# Full icon (iOS, legacy Android): solid background, grid fills ~62%.
full = Image.new("RGB", (SS, SS), BG)
draw_grid(full, 0.62)
save(full, "icon.png")

# Android adaptive foreground: transparent, grid kept inside the 66% safe zone
# because launchers crop the outer third into circles, squircles, etc.
fg = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
draw_grid(fg, 0.46)
save(fg, "icon_foreground.png")

# Android 13+ themed (monochrome) icon: the T only, single colour.
mono = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
GRID_SAVED = [row[:] for row in GRID]
GRID[:] = [[1 if v == 1 else None for v in row] for row in GRID_SAVED]
d = ImageDraw.Draw(mono)
size, gap = SS * 0.46, SS * 0.46 * 0.07
cell = (size - 2 * gap) / 3
x0 = (SS - size) / 2
for r, row in enumerate(GRID):
    for c, v in enumerate(row):
        if v:
            x, y = x0 + c * (cell + gap), x0 + r * (cell + gap)
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=cell * 0.22, fill=(255, 255, 255, 255))
GRID[:] = GRID_SAVED
save(mono, "icon_monochrome.png")
