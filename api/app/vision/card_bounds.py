"""Retrouver les quatre coins d'une carte dans une photo, et y lire l'illustration.

**Le problème que ce module résout.** Le pipeline découpait l'illustration à une
position fixe dans le plus grand rectangle aux proportions d'une carte, centré
dans la photo — donc en supposant que la carte y tienne exactement. Mesuré, cet
espoir tolère 2 à 3 % d'écart, soit 2,6 mm sur la hauteur d'une carte. Aucun
cadrage à main levée n'atteint cette précision, et le banc le confirme : à
8 % de marge et 2° de travers, plus une seule carte n'est reconnue.

**Pourquoi ce cas réussit là où l'étalement a échoué.** Les impasses consignées
dans `docs/spread-detection.md` portent toutes sur une photo de plusieurs
cartes : ce qui y ruine la segmentation est le **contact**, deux cartes voisines
se soudant en une forme unique de proche en proche. Ici il n'y a qu'un objet, et
il occupe l'essentiel de l'image. La difficulté disparaît avec la voisine.

**Les quatre coins plutôt que la boîte englobante.** Une carte tournée de cinq
degrés a une boîte englobante nettement plus large qu'elle ; y découper une zone
en proportions rate l'illustration autant qu'avant. Les coins, eux, décrivent la
carte telle qu'elle est posée.

**L'illustration se lit par interpolation, sans redresser l'image.** Redresser
demanderait de résoudre une homographie puis de rééchantillonner toute la photo,
pour n'en garder qu'un huitième. On échantillonne directement la zone voulue en
interpolant les quatre coins : exact pour une carte photographiée de face, même
tournée, et suffisant pour la perspective légère d'une photo à main levée. C'est
aussi ce qui rend le portage Dart tenable — une quinzaine de lignes.

Ce module doit rester le jumeau de `app/lib/src/features/scan/domain/card_bounds.dart`.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image

#: Largeur à laquelle l'analyse travaille. La carte reste largement assez grande
#: pour que ses bords soient nets, et le coût du parcours de composantes — le
#: seul point coûteux — est divisé par quatre par rapport à une photo entière.
ANALYSIS_WIDTH = 400

#: Proportions d'une carte Magic, 63 × 88 mm.
CARD_ASPECT = 63 / 88

#: Une carte occupe au moins cette fraction de la photo. En deçà, ce qu'on a
#: trouvé est une tache sur la table, pas une carte : mieux vaut renoncer et
#: laisser le cadrage centré faire son travail.
MIN_AREA = 0.10

#: Écart toléré au rapport d'une carte. Large à dessein : une carte vue de
#: biais s'écarte de ses proportions nominales, et rejeter trop strictement
#: reviendrait à ne détecter que les photos déjà parfaites.
ASPECT_TOLERANCE = 0.30


@dataclass(frozen=True)
class Quad:
    """Les quatre coins d'une carte, en pixels de l'image analysée.

    Ordre : haut-gauche, haut-droit, bas-droit, bas-gauche — celui dans lequel
    on lit une carte, et celui qu'attend l'interpolation.
    """

    top_left: tuple[float, float]
    top_right: tuple[float, float]
    bottom_right: tuple[float, float]
    bottom_left: tuple[float, float]

    def scaled(self, factor: float) -> "Quad":
        def s(p: tuple[float, float]) -> tuple[float, float]:
            return (p[0] * factor, p[1] * factor)

        return Quad(
            s(self.top_left), s(self.top_right), s(self.bottom_right), s(self.bottom_left)
        )

    @property
    def aspect(self) -> float:
        """Largeur sur hauteur, moyennée sur les deux paires de côtés."""
        top = _distance(self.top_left, self.top_right)
        bottom = _distance(self.bottom_left, self.bottom_right)
        left = _distance(self.top_left, self.bottom_left)
        right = _distance(self.top_right, self.bottom_right)
        height = (left + right) / 2
        return ((top + bottom) / 2) / height if height else 0.0


def _distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    return float(np.hypot(a[0] - b[0], a[1] - b[1]))


def card_mask(rgb: np.ndarray) -> np.ndarray:
    """Ce qui est carte plutôt que table.

    Deux signatures, réunies : une carte porte une **bordure sombre** sur tout
    son pourtour, et son illustration est plus **saturée** qu'un plateau de bois
    ou une nappe. L'une sans l'autre laisse passer les cartes claires ou les
    tables colorées ; ensemble elles tiennent. Le seuil de table est pris sur la
    moitié la plus lumineuse de l'image, pour qu'une carte sombre occupant la
    moitié du cadre ne tire pas la référence vers le bas.
    """
    grey = rgb.mean(axis=2)
    high, low = rgb.max(axis=2), rgb.min(axis=2)
    saturation = np.where(high > 0, (high - low) / np.maximum(high, 1), 0)

    # Un fond parfaitement uniforme n'a aucun pixel *au-dessus* de son propre
    # centile : la moitié lumineuse est alors vide et la médiane vaut NaN, ce
    # qui rendait toute comparaison fausse et le masque désespérément vide. La
    # médiane globale prend le relais — sur un fond uni, c'est la même valeur.
    floor = np.percentile(grey, 40)
    bright = grey[grey > floor]
    table = np.median(bright) if bright.size else np.median(grey)

    return (grey < table * 0.72) | (saturation > 0.38)


def fill_holes(mask: np.ndarray) -> np.ndarray:
    """Bouche ce qui est cerné par la forme.

    Le panneau de règles d'une carte est clair comme la table : sans ce
    bouchage, il creuse la forme et la coupe en deux. Un trou se reconnaît à ce
    qu'il **ne touche pas le bord de l'image** ; on inonde donc le fond depuis
    les bords, et ce qui reste sec appartient à la carte qui l'entoure.
    """
    free = ~mask
    height, width = free.shape
    seen = np.zeros_like(free)
    stack: list[tuple[int, int]] = []

    for x in range(width):
        for y in (0, height - 1):
            if free[y, x] and not seen[y, x]:
                seen[y, x] = True
                stack.append((y, x))
    for y in range(height):
        for x in (0, width - 1):
            if free[y, x] and not seen[y, x]:
                seen[y, x] = True
                stack.append((y, x))

    while stack:
        y, x = stack.pop()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < height and 0 <= nx < width and free[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                stack.append((ny, nx))

    return mask | ~seen


def largest_component(mask: np.ndarray) -> np.ndarray | None:
    """La plus grande forme d'un seul tenant.

    Sur une photo d'une seule carte, c'est elle. Les autres composantes sont des
    ombres, des reflets, un bout de manche — toutes plus petites, et aucune ne
    peut fusionner avec la carte puisqu'il n'y a pas de voisine à toucher.
    """
    height, width = mask.shape
    labels = np.zeros((height, width), dtype=np.int32)
    current = 0
    best_label, best_size = 0, 0

    for y0 in range(height):
        for x0 in np.flatnonzero(mask[y0]):
            if labels[y0, x0]:
                continue
            current += 1
            size = 0
            stack = [(y0, int(x0))]
            labels[y0, x0] = current
            while stack:
                y, x = stack.pop()
                size += 1
                for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                    if (
                        0 <= ny < height
                        and 0 <= nx < width
                        and mask[ny, nx]
                        and not labels[ny, nx]
                    ):
                        labels[ny, nx] = current
                        stack.append((ny, nx))
            if size > best_size:
                best_label, best_size = current, size

    if not best_label:
        return None
    return labels == best_label


def corners_of(shape: np.ndarray) -> Quad:
    """Les quatre coins d'une forme rectangulaire, même tournée.

    **Par les extrêmes des sommes et des différences.** Le coin haut-gauche
    minimise `x + y`, le bas-droit le maximise ; le haut-droit maximise `x - y`,
    le bas-gauche le minimise. C'est exact pour un rectangle quelle que soit sa
    rotation, insensible au bruit du contour — un pixel isolé ne peut décaler un
    coin que de lui-même — et se porte en trois lignes.
    """
    ys, xs = np.nonzero(shape)
    total = xs + ys
    diff = xs - ys
    return Quad(
        top_left=(float(xs[total.argmin()]), float(ys[total.argmin()])),
        bottom_right=(float(xs[total.argmax()]), float(ys[total.argmax()])),
        top_right=(float(xs[diff.argmax()]), float(ys[diff.argmax()])),
        bottom_left=(float(xs[diff.argmin()]), float(ys[diff.argmin()])),
    )


def find_card(photo: Image.Image) -> Quad | None:
    """Coins de la carte, en pixels de la photo d'origine.

    Rend `None` plutôt qu'un quadrilatère douteux : l'appelant retombe alors sur
    le cadrage centré, c'est-à-dire sur le comportement d'avant. **Une détection
    qui échoue ne doit jamais faire moins bien que son absence.**
    """
    if photo.width < 8 or photo.height < 8:
        return None

    scale = photo.width / ANALYSIS_WIDTH if photo.width > ANALYSIS_WIDTH else 1.0
    small = (
        photo.resize(
            (ANALYSIS_WIDTH, max(1, round(photo.height / scale))), Image.BILINEAR
        )
        if scale > 1
        else photo
    )

    rgb = np.asarray(small.convert("RGB"), dtype=np.float32)
    shape = largest_component(fill_holes(card_mask(rgb)))
    if shape is None:
        return None

    if shape.sum() < MIN_AREA * shape.size:
        return None

    quad = corners_of(shape)
    if abs(quad.aspect - CARD_ASPECT) > ASPECT_TOLERANCE:
        return None

    return quad.scaled(scale)


def sample_art(
    photo: Image.Image,
    quad: Quad,
    box: tuple[float, float, float, float],
    size: tuple[int, int] = (256, 190),
) -> Image.Image:
    """Lit la zone [box] de la carte décrite par [quad], sans redresser la photo.

    Chaque pixel de sortie correspond à un couple `(u, v)` en proportions de la
    carte ; sa position dans la photo s'obtient en interpolant les quatre coins.
    Exact pour une carte photographiée de face, même tournée ; suffisant pour la
    perspective légère d'une photo à main levée.
    """
    left, top, right, bottom = box
    width, height = size

    us = left + (right - left) * (np.arange(width) + 0.5) / width
    vs = top + (bottom - top) * (np.arange(height) + 0.5) / height
    u = us.reshape(1, width)
    v = vs.reshape(height, 1)

    tl, tr, br, bl = quad.top_left, quad.top_right, quad.bottom_right, quad.bottom_left
    x = (
        (1 - u) * (1 - v) * tl[0]
        + u * (1 - v) * tr[0]
        + u * v * br[0]
        + (1 - u) * v * bl[0]
    )
    y = (
        (1 - u) * (1 - v) * tl[1]
        + u * (1 - v) * tr[1]
        + u * v * br[1]
        + (1 - u) * v * bl[1]
    )

    source = np.asarray(photo.convert("RGB"), dtype=np.float32)
    return Image.fromarray(_bilinear(source, x, y).astype(np.uint8), mode="RGB")


def _bilinear(source: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Lecture entre les pixels, pondérée par la distance aux quatre voisins.

    **Le plus proche voisin coûte des bits.** L'empreinte compare des moyennes
    de cellules ; échantillonner en arrondissant fait vibrer ces moyennes au
    gré du sous-pixel sur lequel tombe la grille — mesuré, une médiane de 4 bits
    là où l'interpolation la ramène à 1. Sur un seuil de confiance de 12, ces
    trois bits sont trois bits de marge en moins face au flou et aux reflets.
    """
    height, width = source.shape[:2]
    x = np.clip(x, 0, width - 1)
    y = np.clip(y, 0, height - 1)

    x0 = np.floor(x).astype(np.int32)
    y0 = np.floor(y).astype(np.int32)
    x1 = np.minimum(x0 + 1, width - 1)
    y1 = np.minimum(y0 + 1, height - 1)

    fx = (x - x0)[..., None]
    fy = (y - y0)[..., None]

    top = source[y0, x0] * (1 - fx) + source[y0, x1] * fx
    bottom = source[y1, x0] * (1 - fx) + source[y1, x1] * fx
    return top * (1 - fy) + bottom * fy
