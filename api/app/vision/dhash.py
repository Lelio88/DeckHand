"""Empreinte perceptuelle d'illustration — *difference hash*.

**Pourquoi dHash et non pHash.** L'algorithme est réimplémenté à l'identique en
Dart (`app/lib/src/features/scan/domain/art_hash.dart`), puisque la
reconnaissance s'exécute embarquée. dHash tient en une vingtaine de lignes sans
transformée ; pHash exigerait une DCT en Dart, pour un gain de robustesse dont
rien ne prouve qu'il soit nécessaire ici.

**Pourquoi un redimensionnement fait à la main.** La première version confiait la
réduction à Pillow (Lanczos). Confrontée au portage Dart, elle a divergé sur 3
images de test sur 5 : deux bibliothèques n'implémentent pas le même
rééchantillonnage, et un seul bit d'écart suffit à désaligner la reconnaissance
embarquée de l'index serveur. La réduction est donc effectuée ici par un filtre
de moyenne à **bornes et divisions entières**, reproductible à l'identique dans
n'importe quel langage. C'est le prix de la parité, et il n'est pas négociable.

De même, la conversion en niveaux de gris utilise une formule entière explicite
plutôt que `convert("L")`, dont les coefficients et arrondis sont internes à
Pillow.

**Pourquoi 64 bits et non davantage — mesuré, pas supposé.** Une empreinte de
256 bits (grille 16×16) a été comparée à celle de 64 bits sur les mêmes
illustrations, dégradées comme le ferait une photo médiocre. Elle s'est révélée
**moins fiable** : rapport de séparation médian de 1,9× contre 3,5×. Une grille
plus fine capture des détails que le flou et la compression détruisent en
premier, si bien que la dégradation touche proportionnellement plus de bits.
Augmenter la résolution de l'empreinte est contre-productif ; inutile de
retenter.

Deux illustrations sont considérées comme la même en deçà d'une distance de
Hamming de quelques bits ; le seuil exact se règle sur des mesures réelles.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

# Côté de la grille d'empreinte. 8 donne 8×8 = 64 bits.
HASH_SIZE = 8
HASH_BITS = HASH_SIZE * HASH_SIZE

# Coefficients de luminance ITU-R BT.601, en millièmes pour rester entiers.
_GREY_R, _GREY_G, _GREY_B, _GREY_DIV = 299, 587, 114, 1000


def _to_grey(image: Image.Image) -> np.ndarray:
    """Niveaux de gris, en arithmétique entière explicite."""
    rgb = np.asarray(image.convert("RGB"), dtype=np.int64)
    return (
        rgb[:, :, 0] * _GREY_R + rgb[:, :, 1] * _GREY_G + rgb[:, :, 2] * _GREY_B
    ) // _GREY_DIV


def _cell_bounds(index: int, count: int, length: int) -> tuple[int, int]:
    """Bornes de la cellule `index` sur `count`, dans une dimension de `length`.

    Bornes entières, donc identiques dans tout langage. Le `max` garantit une
    cellule non vide même quand l'image source est plus petite que la grille.
    """
    start = index * length // count
    end = max(start + 1, (index + 1) * length // count)
    return start, min(end, length)


def _downscale(grey: np.ndarray, width: int, height: int) -> np.ndarray:
    """Réduit par moyenne de blocs, en divisions entières."""
    src_h, src_w = grey.shape
    cells = np.empty((height, width), dtype=np.int64)
    for dy in range(height):
        y0, y1 = _cell_bounds(dy, height, src_h)
        for dx in range(width):
            x0, x1 = _cell_bounds(dx, width, src_w)
            block = grey[y0:y1, x0:x1]
            cells[dy, dx] = int(block.sum()) // int(block.size)
    return cells


def dhash(image: Image.Image, size: int = HASH_SIZE) -> int:
    """Calcule l'empreinte d'une image, sous forme d'entier non signé.

    L'image est réduite à `(size + 1) × size` : la colonne supplémentaire fournit
    le voisin de droite du dernier pixel de chaque ligne. Chaque pixel est
    ensuite comparé à ce voisin — comparer des voisins plutôt que des valeurs
    absolues rend l'empreinte insensible à un éclairage global.
    """
    cells = _downscale(_to_grey(image), size + 1, size)

    bits = 0
    for y in range(size):
        for x in range(size):
            bits <<= 1
            if cells[y, x] > cells[y, x + 1]:
                bits |= 1
    return bits


def to_hex(value: int, size: int = HASH_SIZE) -> str:
    """Représentation hexadécimale, format d'échange avec l'application Dart."""
    return f"{value:0{size * size // 4}X}"


def hamming_distance(a: int, b: int) -> int:
    """Nombre de bits qui diffèrent entre deux empreintes."""
    return (a ^ b).bit_count()


def to_signed_64(value: int) -> int:
    """Replie une valeur 64 bits non signée dans l'intervalle d'un `bigint`.

    Postgres n'a pas d'entier 64 bits non signé. La conversion est réversible :
    ajouter 2^64 à une valeur négative restitue l'empreinte d'origine.
    """
    return value - 2**64 if value >= 2**63 else value


def from_signed_64(value: int) -> int:
    """Opération inverse de `to_signed_64`."""
    return value + 2**64 if value < 0 else value
