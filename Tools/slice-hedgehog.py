# Cut the hedgehog sprite sheet into per-style frame strips for the menu bar
# Usage (needs pillow, numpy, scipy): python3 Tools/slice-hedgehog.py "Cute Pixel Hedgehog Animation Sheet.png" Resources/Animations preview.png
from PIL import Image; import numpy as np, sys, os
from scipy import ndimage
src, outdir = sys.argv[1], sys.argv[2]
im = Image.open(src).convert('RGBA'); a = np.array(im)
rows = {  # style: (top, bottom) of the row band, incl. effects above
  'classic': (80, 198), 'dash': (282, 405), 'sleep': (488, 618), 'ball': (712, 825), 'apple': (886, 995)}
H = 132           # source canvas height (common so all styles share a scale)
OUT_H = 36        # @2x pixels for an 18 pt menu bar image
os.makedirs(outdir, exist_ok=True)
sheet = []
for style, (t, b) in rows.items():
    band = a[t:b]
    mask = band[..., 3] > 100
    if style == 'apple': mask[:12, :240] = False   # row label
    lab, n = ndimage.label(mask, structure=np.ones((3, 3)))
    objs = ndimage.find_objects(lab)
    areas = ndimage.sum(mask, lab, range(1, n + 1))
    comps = []
    for i, sl in enumerate(objs):
        ys, xs = sl
        px = band[lab == i + 1]
        red = px[:, 0].mean() > px[:, 1].mean() + 60
        comps.append(dict(id=i + 1, x0=xs.start, x1=xs.stop, y0=ys.start, y1=ys.stop, area=areas[i], red=red))
    bodies = sorted([c for c in comps if c['area'] > 2500], key=lambda c: c['x0'])
    frames = [[bd] for bd in bodies]
    for c in comps:
        if c['area'] > 2500 or c['area'] < 8: continue
        if style == 'apple' and c['red'] and c['area'] > 1000:   # apples run ahead, so belong to the hedgehog on their left
            left = [i for i, bd in enumerate(bodies) if bd['x1'] <= c['x0']]
            if not left: continue   # the lone leading apple
            frames[left[-1]].append(c); continue
        gaps = [max(0, bd['x0'] - c['x1'], c['x0'] - bd['x1']) for bd in bodies]
        frames[int(np.argmin(gaps))].append(c)
    # Body centre anchors each frame so the hedgehog doesn't drift
    left_ext = max((f[0]['x0'] + f[0]['x1']) / 2 - min(c['x0'] for c in f) for f in frames)
    right_ext = max(max(c['x1'] for c in f) - (f[0]['x0'] + f[0]['x1']) / 2 for f in frames)
    W = int(np.ceil(left_ext + right_ext)) + 2
    imgs = []
    for f in frames:
        keep = np.isin(lab, [c['id'] for c in f])
        # also keep faint pixels (shadow / antialiasing) within the frame's x-range
        x0 = min(c['x0'] for c in f); x1 = max(c['x1'] for c in f)
        cell = band.copy()
        soft = (band[..., 3] <= 100) & (band[..., 3] > 0)
        # faint pixels (shadow / antialiasing) only right next to this frame's sprites
        near = ndimage.binary_dilation(keep, iterations=8)
        sel = keep | (soft & near)
        sel[:, :x0] = False; sel[:, x1:] = False
        cell[~sel] = 0
        cx = (f[0]['x0'] + f[0]['x1']) / 2
        ox = int(round(cx - left_ext)) - 1
        canvas = np.zeros((H, W, 4), np.uint8)
        h = b - t
        sx0 = max(0, ox); sx1 = min(a.shape[1], ox + W)
        canvas[H - h:, sx0 - ox:sx1 - ox] = cell[:, sx0:sx1]
        imgs.append(Image.fromarray(canvas))
    out_w = round(W * OUT_H / H)
    strip = Image.new('RGBA', (out_w * len(imgs), OUT_H))
    for i, img in enumerate(imgs):
        strip.paste(img.resize((out_w, OUT_H), Image.LANCZOS), (i * out_w, 0))
    strip.save(f'{outdir}/hedgehog-{style}@{len(imgs)}.png')
    print(style, len(imgs), 'frames', W, 'x', H, '->', out_w, 'x', OUT_H)
    sheet.append((style, imgs))
# preview at source resolution
pw = max(len(i) * i[0].width for _, i in sheet)
prev = Image.new('RGBA', (pw, H * len(sheet)), (40, 40, 40, 255))
for r, (_, imgs) in enumerate(sheet):
    for i, img in enumerate(imgs):
        prev.alpha_composite(img, (i * img.width, r * H))
prev.save(sys.argv[3])
