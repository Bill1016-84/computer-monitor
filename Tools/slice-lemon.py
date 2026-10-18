# Cut the lemon storyboard (opaque black background) into per-animation frame strips for the menu bar
# Usage (needs pillow, numpy, scipy): python3 Tools/slice-lemon.py "Cute Lemon Blob Animation Storyboard.png" Resources/Animations preview.png
from PIL import Image; import numpy as np, sys, os
from scipy import ndimage
src, outdir = sys.argv[1], sys.argv[2]
rgb = np.array(Image.open(src).convert('RGB')).astype(int)
rows = {  # id: (top, bottom, label bottom) — the label pill sits top-left of each row
    'lemon-plane': (70, 218, 80), 'lemon-rain': (288, 436, 292), 'lemon-eat': (512, 632, 510),
    'lemon-costume': (695, 818, 706), 'lemon-nap': (884, 1010, 898)}
OUT_H = 36

def cutout(band, label_rows):
    """Alpha mask: coloured pixels, the holes inside them, and the dark outline hugging them"""
    color = band.max(2) > 45
    color[:label_rows, :290] = False
    # Line art is near-black but not pure black (≈5-8 vs 0-2), so keep faint pixels next to colour
    near = ndimage.binary_dilation(color, iterations=6)
    ink = ndimage.binary_opening(band.max(2) >= 4, iterations=1) & near
    return ndimage.binary_fill_holes(ink | color)

results = []
for name, (t, b, lab) in rows.items():
    band = rgb[t:b]
    mask = cutout(band, max(0, lab - t))
    # Lemon bodies (pale yellow, large) anchor the frames; everything between midpoints belongs to one
    yellow = (band[..., 0] > 200) & (band[..., 1] > 190) & (band[..., 2] < 190)
    yl, n = ndimage.label(ndimage.binary_opening(yellow, iterations=2))
    sizes = ndimage.sum(yellow, yl, range(1, n + 1))
    centers = sorted(ndimage.center_of_mass(yellow, yl, [i + 1 for i in range(n) if sizes[i] > 1500]), key=lambda c: c[1])
    xs = [c[1] for c in centers]
    # merge blobs belonging to the same lemon (e.g. split by a costume or an apple)
    merged = []
    for x in xs:
        if merged and x - merged[-1][-1] < 60: merged[-1].append(x)
        else: merged.append([x])
    xs = [float(np.mean(m)) for m in merged]
    bounds = [0] + [(a + c) / 2 for a, c in zip(xs, xs[1:])] + [band.shape[1]]
    half = max(max(x - bounds[i], bounds[i + 1] - x) for i, x in enumerate(xs))
    half = min(half, float(np.median(np.diff(xs))) * 0.6)
    frames = []
    for i, x in enumerate(xs):
        W, off = int(2 * half), int(round(x - half))
        x0, x1 = max(int(bounds[i]), off, 0), min(int(bounds[i + 1]), off + W, band.shape[1])
        cell = np.zeros((b - t, W, 4), np.uint8)
        cell[:, x0 - off:x1 - off, :3] = band[:, x0:x1]
        cell[:, x0 - off:x1 - off, 3] = mask[:, x0:x1] * 255
        frames.append(cell)
    results.append((name, frames))
    print(name, len(frames), 'frames, cell', frames[0].shape[1], 'x', frames[0].shape[0])

# Trim every row to its content, then use one scale for all rows so the lemon is the same size everywhere
def vbounds(frames):
    a = np.any(np.stack([f[..., 3] > 0 for f in frames]).any(0), 1)
    ys = np.where(a)[0]; return ys[0], ys[-1] + 1
H = max(e - s for _, fr in results for s, e in [vbounds(fr)])
scale = OUT_H / H
os.makedirs(outdir, exist_ok=True)
preview = []
for name, frames in results:
    s, e = vbounds(frames)
    w = round(frames[0].shape[1] * scale)
    strip = Image.new('RGBA', (w * len(frames), OUT_H))
    imgs = []
    for i, f in enumerate(frames):
        img = Image.fromarray(f[s:e]).resize((w, max(1, round((e - s) * scale))), Image.LANCZOS)
        canvas = Image.new('RGBA', (w, OUT_H)); canvas.paste(img, (0, OUT_H - img.height))   # stand on the ground
        strip.paste(canvas, (i * w, 0)); imgs.append(canvas)
    strip.save(f'{outdir}/{name}@{len(frames)}.png')
    preview.append(strip)
if len(sys.argv) > 3:
    # light and dark menu bar backgrounds side by side, enlarged 3x
    pw = max(p.width for p in preview)
    both = Image.new('RGBA', (pw * 2, OUT_H * len(preview)))
    for k, bg in enumerate([(235, 235, 235, 255), (35, 35, 35, 255)]):
        panel = Image.new('RGBA', (pw, both.height), bg)
        for i, p in enumerate(preview): panel.alpha_composite(p, (0, i * OUT_H))
        both.paste(panel, (k * pw, 0))
    both.resize((both.width * 3, both.height * 3), Image.NEAREST).save(sys.argv[3])
