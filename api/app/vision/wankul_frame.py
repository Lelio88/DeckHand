"""Redressement et maquette d'une carte Wankul couchée — les Terrains.

**Deux faits mesurés sur les 146 Terrains du catalogue, et le second renverse
une conclusion antérieure.**

1. *Le rendu principal d'un Terrain est la carte tournée d'un quart de tour,
   toujours dans le même sens.* Un unique quart de tour **horaire** redresse les
   146 ; aucune n'est à l'envers. Vérifié en regardant les 146 redressées, pas
   en faisant confiance à un critère.

2. *Il existe deux maquettes*, et elles ne sont **pas** deux rotations l'une de
   l'autre. Le bloc titre + bandeaux occupe `0,1700 → 0,4150` de la hauteur sur
   les unes, `0,6300 → 0,8750` sur les autres. Un demi-tour le placerait à
   `0,5850 → 0,8300` : l'écart de 0,045 dit que ce sont deux mises en page,
   dessinées séparément, et non une carte retournée.

**Ce que ce point 2 corrige.** Une mesure précédente avait vu deux jeux de
bandeaux symétriques dans l'image moyenne et en avait conclu que le lot
contenait les deux sens de rotation ; un demi-tour conditionnel avait alors été
ajouté au redressement pour « recoller » la moyenne. C'était l'inverse : les
deux jeux de bandeaux venaient des deux maquettes, et le demi-tour
conditionnel **introduisait** le résidu mal orienté qu'il croyait supprimer. Le
redressement est donc inconditionnel ici, et la distinction se fait après.

**La maquette se lit sur l'image, faute d'être publiée.** La source ne dit rien
qui la trahisse — ni le champ `orientation`, déjà pris en défaut (§IV du
`CLAUDE.md`), ni la rareté, ni l'effigie. Elle se mesure donc, en comparant deux
hypothèses aux quatre traits que les bandeaux dessinent : la bonne l'emporte par
un facteur 1,28 dans le pire cas mesuré, et les douze décisions les moins
tranchées ont été vérifiées à l'œil, toutes justes.

Invariant à préserver : [BANDS_TOP] et [BANDS_BOTTOM] doivent rester cohérents
avec `WANKUL_BANDS_TOP` et `WANKUL_BANDS_BOTTOM` d'`art_box.py`, dont les bornes
`top` et `bottom` en sont tirées.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image

#: Les quatre traits pleine largeur que dessinent les trois bandeaux — bord
#: haut, deux séparateurs, bord bas — sur la maquette dont le bloc est **en
#: haut**. Relevés sur le gradient de l'image moyenne de 77 cartes : forces 40,
#: 39, 38 et 37 pour une médiane de 1,2 sur le reste de la carte.
BANDS_TOP = (0.1700, 0.2533, 0.3300, 0.4150)

#: Les mêmes, sur la maquette dont le bloc est **en bas** — 69 cartes, forces
#: 45, 45, 48 et 55. Le bloc y a exactement la même hauteur (0,2450), ce qui
#: confirme qu'il s'agit du même gabarit de bandeaux posé ailleurs.
BANDS_BOTTOM = (0.6300, 0.7150, 0.7983, 0.8750)

#: Valeurs de `layout` que ce module produit, et que `box_for` sait traduire.
LAYOUT_BANDS_TOP = "horizontal-bandeaux-haut"
LAYOUT_BANDS_BOTTOM = "horizontal-bandeaux-bas"

#: Taille de travail pour la mesure, en paysage. Assez grande pour que les
#: traits des bandeaux restent nets, assez petite pour que les 146 cartes se
#: mesurent en quelques secondes.
NORM = (840, 600)

#: Un trait peut glisser d'un pixel ou deux d'une extension à l'autre : on
#: cherche donc le maximum du gradient dans un voisinage plutôt qu'à la ligne
#: exacte. Trop large, le voisinage attraperait le trait voisin (les bandeaux
#: sont espacés de 0,082, soit 49 lignes ici).
TOLERANCE = 3


@dataclass(frozen=True)
class Maquette:
    """La maquette retenue, et à quel point la décision était tranchée."""

    layout: str
    #: Rapport du score gagnant au score perdant. **1,0 signifie qu'aucune des
    #: deux hypothèses ne l'emporte** ; le pire cas mesuré sur le catalogue vaut
    #: 1,28 (« TERRADOLLAR », un billet de banque dont la texture imite des
    #: bandeaux). En dessous, la carte mérite d'être regardée.
    ratio: float

    @property
    def bands_on_top(self) -> bool:
        return self.layout == LAYOUT_BANDS_TOP


def upright(image: Image.Image) -> Image.Image:
    """La carte couchée, remise dans son sens de lecture.

    Un quart de tour **horaire**, sans condition. Le sens a été établi en
    lisant les rendus : le texte d'un Terrain stocké court de bas en haut.
    """
    return image.rotate(-90, expand=True)


def _grey(image: Image.Image) -> np.ndarray:
    array = np.asarray(image.convert("RGB").resize(NORM, Image.LANCZOS))
    return array.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)


def _score(grey: np.ndarray, bands: tuple[float, float, float, float]) -> float:
    """À quel point cette carte porte les bandeaux là où l'hypothèse les attend.

    Deux facteurs, et il en faut deux : la **force des quatre traits** seule se
    laisse imiter par n'importe quelle texture rayée, la **platitude des trois
    bandeaux** seule se laisse imiter par un ciel. Leur produit ne se laisse
    imiter par aucun des deux — c'est ce qui range « TERRADOLLAR », un billet
    de banque, du bon côté.

    Les bords sont écartés en x : le gradient du bord de carte écraserait tout.
    """
    height, width = grey.shape
    inner = grey[:, int(width * 0.12) : int(width * 0.88)]

    edges = np.abs(np.diff(inner, axis=0)).mean(axis=1)
    strength = float(
        np.mean(
            [
                edges[max(0, int(b * height) - TOLERANCE) : int(b * height) + TOLERANCE + 1].max()
                for b in bands
            ]
        )
    )

    flat = []
    for top, bottom in zip(bands, bands[1:]):
        zone = inner[int(top * height) + 4 : int(bottom * height) - 4]
        if zone.size == 0:
            continue
        median = np.median(zone, axis=1)
        # Un bandeau est un aplat clair : la ligne s'écarte peu de sa médiane,
        # et cette médiane est franchement au-dessus du gris moyen.
        flat.append(float(((np.abs(zone - median[:, None]) < 28).mean(axis=1) * (median > 135)).mean()))

    return strength * float(np.mean(flat)) if flat else 0.0


def maquette(image: Image.Image) -> Maquette:
    """Laquelle des deux maquettes cette carte **déjà redressée** porte.

    L'image attendue est celle que rend [upright] : passer le rendu stocké tel
    quel donnerait une réponse au hasard, les deux hypothèses portant sur des
    lignes horizontales qui n'existent pas sur une carte tournée.
    """
    grey = _grey(image)
    top = _score(grey, BANDS_TOP)
    bottom = _score(grey, BANDS_BOTTOM)
    high, low = max(top, bottom), min(top, bottom)
    return Maquette(
        layout=LAYOUT_BANDS_TOP if top > bottom else LAYOUT_BANDS_BOTTOM,
        ratio=high / low if low > 0 else float("inf"),
    )
