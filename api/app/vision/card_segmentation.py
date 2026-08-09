"""Delimiter chaque carte d'une photo d'etalement.

**Trois tentatives avaient echoue, et une quatrieme faillit echouer pour une
autre raison.** Chercher les aretes trouve le cadre interne de la carte ; la
variance trouve le texte de regles ; la luminosite du fond trouve le panneau de
regles, blanc comme la table. Consigne dans `docs/spread-detection.md`.

Ce qui debloque : traiter le panneau de regles pour ce qu'il est — un **trou**
dans la forme, cerne par la bordure noire, et non une echancrure. Reste a le
boucher correctement.

**Le piege du bouchage par balayage.** Combler, sur chaque ligne, tout ce qui se
trouve entre le premier et le dernier pixel de carte est juste pour un objet
isole, et faux pour une grille : cela soude une rangee entiere. Une premiere
version le faisait et ne voyait plus que trois blocs au lieu de onze cartes ;
aucune erosion ne pouvait les redecouper, puisqu'elles etaient soudees sur toute
leur longueur.

Un trou, c'est du fond **qui ne touche pas le bord de l'image**. On inonde donc
le fond depuis les bords ; ce qui reste sec appartient a la carte qui l'entoure.

**Ce que ca vaut, mesure.** Sur une photo de onze cartes separees par un jour
visible : onze formes, dont dix au rapport d'une carte, chacune epousant la
sienne. Sur une photo de dix-sept cartes **jointives** : dix formes seulement,
plusieurs cartes fondues ensemble. La methode exige donc un espace entre les
cartes — contrainte de geste, a dire a l'utilisateur plutot qu'a compenser.

Usage : python -m app.vision.card_segmentation <photo> <nombre attendu>
"""


import sys
import numpy as np
from PIL import Image, ImageDraw

TMP = "C:/Users/buton/.claude/jobs/fb20a77f/tmp/"


def load(name, width=800):
    image = Image.open(TMP + name).convert("RGB")
    return image.resize((width, int(image.height * width / image.width)))


def card_mask(rgb):
    a = np.asarray(rgb, dtype=np.float32)
    grey = a.mean(axis=2)
    high, low = a.max(axis=2), a.min(axis=2)
    saturation = np.where(high > 0, (high - low) / np.maximum(high, 1), 0)
    table = np.median(grey[grey > np.percentile(grey, 40)])
    return (grey < table * 0.72) | (saturation > 0.38)


def flood_from_border(free):
    """Marque tout le fond joignable depuis le bord de l'image."""
    h, w = free.shape
    seen = np.zeros_like(free)
    stack = []
    for x in range(w):
        for y in (0, h - 1):
            if free[y, x]:
                stack.append((y, x))
                seen[y, x] = True
    for y in range(h):
        for x in (0, w - 1):
            if free[y, x] and not seen[y, x]:
                stack.append((y, x))
                seen[y, x] = True
    while stack:
        y, x = stack.pop()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and free[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                stack.append((ny, nx))
    return seen


def fill_holes(mask):
    outside = flood_from_border(~mask)
    return mask | ~outside


def erode(mask, radius):
    out = mask.copy()
    for _ in range(radius):
        shifted = out.copy()
        shifted[1:, :] &= out[:-1, :]
        shifted[:-1, :] &= out[1:, :]
        shifted[:, 1:] &= out[:, :-1]
        shifted[:, :-1] &= out[:, 1:]
        out = shifted
    return out


def label(mask):
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    current = 0
    for y0 in range(h):
        for x0 in np.flatnonzero(mask[y0]):
            if labels[y0, x0]:
                continue
            current += 1
            stack = [(y0, int(x0))]
            labels[y0, x0] = current
            while stack:
                y, x = stack.pop()
                for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not labels[ny, nx]:
                        labels[ny, nx] = current
                        stack.append((ny, nx))
    return labels, current


def shapes(labels, count, floor):
    out = []
    for i in range(1, count + 1):
        ys, xs = np.nonzero(labels == i)
        if ys.size < floor:
            continue
        out.append((int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()), int(ys.size)))
    return out


def main(name, truth):
    image = load(name)
    mask = fill_holes(card_mask(image))
    area = mask.sum()
    print(f"=== {name} — {truth} cartes attendues ===")
    print(f"image {image.width}x{image.height}, masque {area} px "
          f"({area / mask.size:.0%} de l'image)\n")

    best = None
    for radius in (0, 2, 3, 4, 5, 6, 8, 10):
        core = erode(mask, radius) if radius else mask
        labels, count = label(core)
        found = shapes(labels, count, area * 0.01)
        good = 0
        for x0, y0, x1, y1, _ in found:
            bw, bh = max(x1 - x0, 1), max(y1 - y0, 1)
            if 1.15 < max(bw, bh) / min(bw, bh) < 1.75:
                good += 1
        mark = ""
        if good == truth:
            mark = "  <- compte juste"
            best = best or (radius, found)
        print(f"  erosion {radius:2d} px : {len(found):3d} formes, "
              f"{good:3d} au rapport d'une carte{mark}")

    radius, found = best if best else (int(sys.argv[3]) if len(sys.argv) > 3 else 4, None)
    if found is None:
        labels, count = label(erode(mask, radius))
        found = shapes(labels, count, area * 0.008)

    canvas = image.copy()
    pen = ImageDraw.Draw(canvas)
    for x0, y0, x1, y1, _ in found:
        bw, bh = max(x1 - x0, 1), max(y1 - y0, 1)
        ratio = max(bw, bh) / min(bw, bh)
        colour = (60, 255, 60) if 1.15 < ratio < 1.75 else (255, 60, 60)
        pen.rectangle([x0 - radius, y0 - radius, x1 + radius, y1 + radius],
                      outline=colour, width=3)
    out = TMP + f"v3_{name}"
    canvas.save(out, quality=80)
    print(f"\nrendu a l'erosion {radius} px -> {out}")


main(sys.argv[1] if len(sys.argv) > 1 else "doublons.jpg",
     int(sys.argv[2]) if len(sys.argv) > 2 else 11)
