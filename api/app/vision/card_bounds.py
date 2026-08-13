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

**Et c'est le Dart qui fait foi.** L'inversion est récente et volontaire : le
seuillage local a été conçu, balayé et retenu côté Dart, sur le banc
`app/tool/framing_bench.dart`, parce que c'est le code Dart qui tourne sur
l'appareil. Ce module en est le portage. Toute divergence future se corrige
donc en ramenant ce fichier vers le Dart, jamais l'inverse — et une divergence
ne se voit pas : elle produit des coins différents, donc une empreinte
différente, et le scan échoue en silence.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image

from app.vision.art_box import GAMES_WITH_LANDSCAPE
from app.vision.card_geometry import card_aspect_for

#: Largeur à laquelle l'analyse travaille. La carte reste largement assez grande
#: pour que ses bords soient nets, et le coût du parcours de composantes — le
#: seul point coûteux — est divisé par quatre par rapport à une photo entière.
ANALYSIS_WIDTH = 400

#: Une carte occupe au moins cette fraction de la photo. En deçà, ce qu'on a
#: trouvé est une tache sur la table, pas une carte : mieux vaut renoncer et
#: laisser le cadrage centré faire son travail.
MIN_AREA = 0.10

#: Écart toléré au rapport d'une carte. Large à dessein : une carte vue de
#: biais s'écarte de ses proportions nominales, et rejeter trop strictement
#: reviendrait à ne détecter que les photos déjà parfaites.
#:
#: **Ce garde-fou ne rattrape pas un masque faux.** Une photo de téléphone en
#: portrait vaut 0,750 et une carte 63:88 vaut 0,716 : 0,034 d'écart, quand la
#: tolérance en accepte 0,30. Un masque qui retient l'image entière passe donc
#: le contrôle sans broncher. C'est au seuillage de ne pas produire ce
#: masque-là — pas à cette constante de le rattraper.
ASPECT_TOLERANCE = 0.30

#: Fenêtre du seuillage local, en fraction du petit côté de l'image d'analyse.
#: Balayée sur le banc de cadrage à 6, 12, 20, 30 et 45 %, elle donne 105, 105,
#: 102, 91 puis 60 cartes reconnues sur les 120 régimes à lampe : plat en deçà
#: de 20 %, puis la fenêtre devient trop large pour épouser l'éclairage. 12 %
#: est pris au milieu du plateau. Jumeau de `localWindow`.
LOCAL_WINDOW = 0.12

#: Sous quelle fraction du niveau local de la table un pixel compte pour du
#: carton. Balayée de 0,60 à 1,00, elle culmine nominalement à 0,88 — mais à ce
#: plafond une table nue marque déjà 10 % de ses pixels comme du carton, contre
#: aucun à 0,84 ; et sur un second tirage au grain doublé le classement
#: s'inverse. 0,84 est le seul point haut des deux. Jumeau de `cardCeiling`.
CARD_CEILING = 0.84


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


def _has_card_aspect(aspect: float, game: str) -> bool:
    """Ce rapport est-il celui d'une carte de ce jeu, dans l'une de ses
    orientations ?

    **Une carte couchée a le rapport inverse d'une carte debout**, et rien de
    plus : mesuré sur le catalogue, 1039 × 744 contre 744 × 1039, soit 1,397
    contre 0,716. Les 64 champs de bataille Riftbound étaient donc rejetés à
    0,68 du rapport attendu, pour une tolérance de 0,30 — et leur gabarit,
    mesuré de longue date, n'avait jamais pu servir.

    **L'orientation couchée n'est ouverte qu'aux jeux qui en ont une.** En
    Magic, toutes les cartes sont debout : y accepter les deux reviendrait à
    laisser passer n'importe quel rectangle, alors que le mode de défaillance
    connu de ce module est justement le quadrilatère faux qui franchit le
    contrôle d'aspect.

    **Le rapport attendu vient du jeu**, et non d'une constante du module : les
    deux jeux couverts impriment en 63 × 88 mm, le suivant n'imprimera pas au
    même format. Voir `card_geometry.py`.

    Jumeau de `_hasCardAspect`.
    """
    debout = card_aspect_for(game)
    if abs(aspect - debout) <= ASPECT_TOLERANCE:
        return True
    if game not in GAMES_WITH_LANDSCAPE:
        return False
    return abs(aspect - 1 / debout) <= ASPECT_TOLERANCE


def _box_mean(source: np.ndarray, radius: int) -> np.ndarray:
    """Moyenne sur la fenêtre carrée de rayon [radius], par image intégrale.

    Quatre accès par pixel, quel que soit le rayon : le coût ne dépend plus de
    la taille de la fenêtre.

    **La fenêtre est écrêtée au cadre, et la moyenne divisée par ce qui reste.**
    On y verrait volontiers un artefact de bord — un pixel proche du cadre voit
    un voisinage tronqué, donc moins fiable. Mesuré, ce n'en est pas un : les
    trois traitements possibles (écrêter, glisser la fenêtre vers l'intérieur,
    prolonger en miroir) rendent des résultats identiques à la carte près sur
    les huit régimes du banc.
    """
    height, width = source.shape
    sums = np.zeros((height + 1, width + 1), dtype=np.float64)
    sums[1:, 1:] = source.cumsum(axis=0).cumsum(axis=1)

    rows = np.arange(height)
    cols = np.arange(width)
    y0 = np.maximum(rows - radius, 0)
    y1 = np.minimum(rows + radius, height - 1)
    x0 = np.maximum(cols - radius, 0)
    x1 = np.minimum(cols + radius, width - 1)

    top, bottom = y0[:, None], (y1 + 1)[:, None]
    left, right = x0[None, :], (x1 + 1)[None, :]
    total = (
        sums[bottom, right] - sums[top, right] - sums[bottom, left] + sums[top, left]
    )
    area = (y1 - y0 + 1)[:, None] * (x1 - x0 + 1)[None, :]
    return total / area


def box_reduce(photo: Image.Image, width: int, height: int) -> np.ndarray:
    """Moyenne de bloc, à bornes et divisions entières — jumeau de `_boxReduce`.

    **Pourquoi pas `Image.resize`.** Pillow réduit très bien : son filtre élargit
    son support à mesure que le facteur grandit, et c'est précisément ce qui a
    masqué le défaut pendant tout ce temps. Le Dart, lui, interpolait entre les
    quatre voisins immédiats — donc sous-échantillonnait à facteur élevé — et
    lisait la trame d'un tissu comme du carton. Les deux implémentations ne
    faisaient pas la même chose, **et c'est le Python qui avait raison** : la
    parité était rompue en silence, exactement comme l'en-tête le redoutait.

    Elle est refaite ici sur le filtre que le Dart calcule à la main, et non
    l'inverse, parce que c'est le seul dont les bornes soient reproductibles mot
    pour mot dans les deux langages. `Image.BOX` en serait proche mais pondère
    les bords fractionnaires ; le nôtre tronque, comme le fait `~/` en Dart.

    `np.add.reduceat` découpe sur exactement les mêmes bornes : le bloc `i` va de
    `x0[i]` inclus à `x0[i+1]` exclu, le dernier jusqu'au bord — ce que le Dart
    écrit `(x * dx).toInt()` et `((x + 1) * dx).toInt()`.
    """
    src = np.asarray(photo.convert("RGB"), dtype=np.uint32)
    h0, w0 = src.shape[:2]
    dx, dy = w0 / width, h0 / height

    x0 = (np.arange(width) * dx).astype(int)
    y0 = (np.arange(height) * dy).astype(int)
    sommes = np.add.reduceat(np.add.reduceat(src, x0, axis=1), y0, axis=0)

    largeurs = np.diff(np.append(x0, w0))
    hauteurs = np.diff(np.append(y0, h0))
    surfaces = (hauteurs[:, None] * largeurs[None, :])[..., None]
    return (sommes // surfaces).astype(np.float32)


def card_mask(rgb: np.ndarray) -> np.ndarray:
    """Ce qui est carte plutôt que table.

    Une carte porte une **bordure sombre** sur tout son pourtour : c'est cet
    anneau, et lui seul, que le masque cherche. L'intérieur est bouché ensuite
    par `fill_holes`, ce qui rend le contenu de la carte sans importance — seul
    compte que l'anneau ne cède nulle part.

    **La référence est locale, et c'est tout le sujet.** Un seuil calé sur
    l'image entière suppose un éclairage uniforme ; sous une lampe de côté, le
    coin de table le plus sombre passe sous ce seuil, touche la carte, et la
    recherche de forme réunit les deux — la boîte englobante devient l'image
    entière. Mesuré sur une carte de papier : la bonne empreinte tombe au rang
    146 sur 1 035, quand un cadrage exact la place au rang 1.

    **Mais pas la moyenne locale.** Sur une carte à fond perdu, dont
    l'illustration claire touche la table sans marche de clarté, la moyenne
    n'oppose plus rien au fond : il s'engouffre, remplit l'intérieur, et la plus
    grande composante n'est qu'un bas de carte. La référence retenue est la
    clarté moyenne de la **seule moitié claire** du voisinage — le niveau local
    de la table, estimé en écartant ce que la carte y met de sombre. Sur un
    voisinage plat elle ne dépasse la moyenne que de 3 %, donc la règle reste
    aussi stricte qu'avant et une table nue ne marque aucun pixel ; sur un
    voisinage contrasté elle monte avec lui, et le corps de la carte sort plein.

    Sur le banc : 181 cartes reconnues sur les 200 photos sans lampe (contre
    179 à la référence globale et 175 à la moyenne locale), 110 sur les 120 à
    lampe, abandons ramenés de 23 à 14.

    **Ce qui a été retiré.** Un second critère faisait entrer tout pixel de
    saturation supérieure à 0,38, au motif qu'une illustration est plus colorée
    qu'un plateau de bois. C'est l'inverse qui se mesure : un bureau de bois
    clair dépasse ce seuil sur la quasi-totalité de sa surface, et ce critère à
    lui seul reconduit l'échec — 29 bits de la bonne carte en le gardant, 8 en
    le retirant, à seuillage local identique.

    **Limite assumée** : une carte à bordure *blanche*, ou à fond perdu dont
    l'illustration claire touche le bord, n'a sur cette portion aucun pourtour
    plus sombre que la table. C'est alors son cadre intérieur qui forme
    l'anneau, et le quadrilatère rendu est légèrement plus petit que la carte.
    """
    grey = rgb.mean(axis=2)
    height, width = grey.shape

    # Le petit côté fixe le rayon : sur une photo en portrait, se caler sur la
    # largeur donnerait la même fenêtre, alors que se caler sur la hauteur la
    # rendrait plus grossière sans rien apporter.
    #
    # `floor(x + 0.5)` et non `round(x)` : Python arrondit les demis vers le
    # pair, Dart les éloigne de zéro. Sur un rayon, cet écart d'une unité
    # suffirait à faire diverger les deux masques — et un jumeau qui diverge
    # d'un pixel n'est plus un jumeau.
    radius = max(1, int(np.floor(min(width, height) * LOCAL_WINDOW / 2 + 0.5)))

    mean = _box_mean(grey, radius)

    # Ne retenir que ce qui dépasse sa propre moyenne locale : sur la table, à
    # peu près la moitié des pixels ; le long d'un bord de carte, la table
    # seule.
    is_lit = grey > mean
    # Les deux moyennes portent sur la même fenêtre : leur quotient est donc
    # exactement la moyenne des seuls pixels clairs, sans avoir à les compter à
    # part. Une fenêtre qui n'en contient aucun — un aplat parfaitement uni —
    # retombe sur la moyenne, qui y vaut la même chose.
    lit_mean = _box_mean(np.where(is_lit, grey, 0.0), radius)
    lit_share = _box_mean(is_lit.astype(np.float64), radius)

    table = np.where(lit_share > 0, lit_mean / np.where(lit_share > 0, lit_share, 1), mean)
    return grey < table * CARD_CEILING


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


def find_card(photo: Image.Image, game: str = "magic") -> Quad | None:
    """Coins de la carte, en pixels de la photo d'origine.

    Rend `None` plutôt qu'un quadrilatère douteux : l'appelant retombe alors sur
    le cadrage centré, c'est-à-dire sur le comportement d'avant. **Une détection
    qui échoue ne doit jamais faire moins bien que son absence.**
    """
    if photo.width < 8 or photo.height < 8:
        return None

    scale = photo.width / ANALYSIS_WIDTH if photo.width > ANALYSIS_WIDTH else 1.0
    if scale > 1:
        rgb = box_reduce(photo, ANALYSIS_WIDTH, max(1, round(photo.height / scale)))
    else:
        rgb = np.asarray(photo.convert("RGB"), dtype=np.float32)

    shape = largest_component(fill_holes(card_mask(rgb)))
    if shape is None:
        return None

    if shape.sum() < MIN_AREA * shape.size:
        return None

    quad = corners_of(shape)
    if not _has_card_aspect(quad.aspect, game):
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
