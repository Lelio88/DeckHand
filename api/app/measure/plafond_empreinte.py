"""Le cadre est-il faux, ou la carte muette ? — le plafond d'identification.

**Les deux hypothèses que ce banc départage.** Le CLAUDE.md en porte deux, et
elles se contredisent :

1. *La géométrie.* « L'empreinte tolère tout ce qu'une main peut infliger, à
   condition que le quadrilatère soit juste » — `flux_bench` montre que
   résolution 200 px, flou 8, inclinaison 30° et luminosité divisée par cinq
   **cumulés** coûtent 1 à 3 bits. Et « l'empreinte décroche au-delà de 3 %
   d'écart de cadrage ».
2. *Les reflets.* « Le plancher n'est pas géométrique » — découper à la fenêtre
   **réelle**, celle que la corrélation situe, donne quand même 14 bits sur une
   carte et 19 sur l'autre.

« 100 % des images détourées » ne les départage pas : cela dit qu'un
quadrilatère a été trouvé, **pas qu'il était juste**. Il faut trois nombres par
photo, et les croiser : l'écart entre le cadre de la production et la vraie
carte, la distance d'empreinte obtenue avec ce cadre, et celle obtenue avec la
vraie fenêtre.

**D'où vient la vérité.** De la corrélation, jamais de la chaîne qu'on mesure —
un banc qui se donne sa propre référence ne mesure que sa cohérence. Scryfall
publie l'**illustration seule** (`art_crop`) à côté de la carte : la fenêtre ne
se déduit pas, elle se retrouve. C'est la méthode de `magic_art_window`, dont ce
banc réutilise `gradient` et `situer` — le second comme **étalon de parité**.

**Pourquoi une corrélation par transformée de Fourier.** `situer` balaye les
positions une à une : quarante secondes par couple, et il en faut des centaines
ici (quatre orientations, une centaine d'échelles, un affinage angulaire). La
corrélation croisée normalisée se calcule exactement par FFT — numérateur par
produit spectral, dénominateur par image intégrale des carrés — pour quelques
millisecondes. `--parite` vérifie que les deux méthodes désignent la **même**
fenêtre ; sans ce contrôle, accélérer reviendrait à changer de vérité.

**Pourquoi la rotation est faite à la main.** `Image.rotate` connaît son affine,
pas nous ; or il faut ramener la fenêtre trouvée dans le repère de la photo pour
la comparer à celle de la production. L'affine est donc écrite ici, et son
inverse avec elle : la correspondance point à point est connue par construction
plutôt que devinée.

**Ce que ce banc ne mesure pas.** La corrélation cherche une fenêtre *rigide*
(position, échelle, angle) ; elle ne redresse pas la perspective, ce que le
quadrilatère de production fait. Sur des photos prises de face, l'écart est
négligeable ; l'accord rapporté le dit pour chacune.

Usage :

    .venv/Scripts/python -m app.measure.plafond_empreinte --parite
    .venv/Scripts/python -m app.measure.plafond_empreinte \\
        --releve ../app/tool/.cache/plafond-carte-seule.json \\
        --photos ../../.deckhand-bench/photos/carte-seule
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import time
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

import httpx
import numpy as np
from PIL import Image

from app.measure.magic_art_window import Fenetre, gradient, situer
from app.vision.dhash import dhash, hamming_distance

# La console Windows sort en cp1252, qui ne connaît ni « ≤ » ni « ↔ ». Sans
# cela le banc s'interrompt sur une ligne d'affichage après avoir fait tout son
# travail — un échec de sortie qui ressemble à un échec de mesure. Même remède
# que `art_probe`.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

USER_AGENT = "DeckHand/1.0 (banc de mesure ; contact heianenterpriseyt@gmail.com)"
DELAI = 0.15

#: Où les illustrations de référence sont conservées. `api/.cache/` est ignoré
#: par git — le dépôt est public, et une illustration n'est pas à nous.
CACHE = Path(".cache/plafond")

#: Largeur de travail de la corrélation, en pixels.
#:
#: `magic_art_window` travaille à 240 : assez pour situer une fenêtre qui occupe
#: la carte entière. Ici la carte n'occupe qu'une part de la photo — un dixième
#: dans le pire cas du banc — et 240 ne laisserait que vingt pixels
#: d'illustration. 480 rend la mesure lisible sans que la FFT se sente.
LARGEUR = 480

#: Part de la largeur de la photo que l'illustration peut occuper.
#:
#: `situer` s'arrête à 0,55 parce qu'il cherche dans une **carte**, où
#: l'illustration occupe toujours l'essentiel de la largeur. Dans une **photo**,
#: la carte peut être petite : la borne basse descend donc à un dixième.
PARTS = np.arange(0.10, 1.001, 0.02)

#: La même plage, plus lâche, pour la passe d'orientation grossière. L'échelle
#: exacte est retrouvée ensuite, autour de celle-ci.
PARTS_GROSSIER = np.arange(0.10, 1.001, 0.04)

#: Seuil de confiance de l'index, repris de `art_hash_index.dart`. Écrit ici
#: pour que le verdict se lise sans ouvrir le Dart ; un test de parité serait
#: excessif pour une constante que ce banc ne fait que citer.
SEUIL_CONFIANCE = 12


# --------------------------------------------------------------------------
# Corrélation croisée normalisée, par FFT
# --------------------------------------------------------------------------


class Scene:
    """Une scène préparée pour la corrélation.

    **Trois quantités qui ne dépendent pas du gabarit** : le gradient, son
    spectre, et l'image intégrale de ses carrés. Les recalculer à chaque échelle
    — ce que faisait la première version — multipliait le coût par quarante-six
    pour rien.
    """

    def __init__(self, image: Image.Image, largeur: int = LARGEUR) -> None:
        reduite = image.resize(
            (largeur, max(1, round(largeur * image.height / image.width))),
            Image.LANCZOS,
        )
        self.gc = gradient(reduite)
        self.forme = self.gc.shape
        self.spectre = np.fft.rfft2(self.gc)
        carres = np.cumsum(np.cumsum(self.gc * self.gc, axis=0), axis=1)
        self.carres = np.pad(carres, ((1, 0), (1, 0)))


class Gabarits:
    """Les gradients d'une illustration, un par échelle, calculés une fois.

    La recherche essaie une soixantaine d'orientations ; à chacune elle
    redemandait les mêmes redimensionnements. Ils ne dépendent que de l'échelle.
    """

    def __init__(self, art: Image.Image) -> None:
        self.art = art
        self._cache: dict[tuple[int, int], np.ndarray] = {}

    def a(self, w: int, h: int) -> np.ndarray:
        cle = (w, h)
        if cle not in self._cache:
            self._cache[cle] = gradient(
                self.art.resize((w, h), Image.LANCZOS)
            )
        return self._cache[cle]


def _carte_ncc(scene: Scene, ga: np.ndarray) -> np.ndarray | None:
    """Corrélation croisée normalisée de `ga` sur la scène, en toute position.

    **Exacte, pas approchée.** Le numérateur est une corrélation circulaire,
    mais aux positions valides (`y ≤ H-h`, `x ≤ W-w`) aucun indice ne déborde :
    elle y vaut la corrélation linéaire. Le dénominateur — la norme du bloc de
    la scène sous le gabarit — se lit dans l'image intégrale des carrés. C'est
    terme pour terme le score que `situer` calcule position par position, et
    `--parite` le vérifie.
    """
    hauteur, largeur = scene.forme
    h, w = ga.shape
    if h > hauteur or w > largeur:
        return None

    rembourre = np.zeros(scene.forme, dtype=scene.gc.dtype)
    rembourre[:h, :w] = ga
    produit = scene.spectre * np.conj(np.fft.rfft2(rembourre))
    numerateur = np.fft.irfft2(produit, s=scene.forme)[
        : hauteur - h + 1, : largeur - w + 1
    ]

    carres = scene.carres
    blocs = (
        carres[h:, w:] - carres[:-h, w:] - carres[h:, :-w] + carres[:-h, :-w]
    )

    norme = float(np.sqrt((ga * ga).sum()))
    if norme < 1e-6:
        return None
    return numerateur / (norme * np.sqrt(np.maximum(blocs, 0.0)) + 1e-6)


def situer_fft(
    scene: Image.Image | Scene,
    art: Image.Image | Gabarits,
    largeur: int = LARGEUR,
    parts: np.ndarray = PARTS,
) -> tuple[Fenetre, float]:
    """Où l'illustration s'inscrit dans la scène, et la qualité de l'accord.

    Même définition que `magic_art_window.situer`, calculée autrement. La fenêtre
    est rendue en fractions de la scène. Les deux arguments acceptent leur forme
    préparée (`Scene`, `Gabarits`) quand l'appelant les réutilise.
    """
    prete = scene if isinstance(scene, Scene) else Scene(scene, largeur)
    gabarits = art if isinstance(art, Gabarits) else Gabarits(art)
    hauteur_art = gabarits.art.height
    largeur_art = gabarits.art.width

    meilleur: tuple[Fenetre, float] | None = None
    for part in parts:
        w = round(largeur * float(part))
        h = round(w * hauteur_art / largeur_art)
        if w < 8 or h < 8 or h >= prete.forme[0] or w >= prete.forme[1]:
            continue
        carte = _carte_ncc(prete, gabarits.a(w, h))
        if carte is None:
            continue
        plat = int(np.argmax(carte))
        y, x = divmod(plat, carte.shape[1])
        score = float(carte[y, x])
        if meilleur is None or score > meilleur[1]:
            meilleur = (
                Fenetre(
                    left=x / prete.forme[1],
                    top=y / prete.forme[0],
                    right=(x + w) / prete.forme[1],
                    bottom=(y + h) / prete.forme[0],
                ),
                score,
            )
    if meilleur is None:
        return Fenetre(0.0, 0.0, 1.0, 1.0), -1.0
    return meilleur


# --------------------------------------------------------------------------
# Rotation à affine connue
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Rotation:
    """Une rotation d'image dont on connaît la correspondance point à point.

    `avant` envoie un point de la photo d'origine dans l'image tournée ;
    `arriere` fait le retour. Les deux sont écrites, non déduites — c'est ce qui
    permet de ramener la fenêtre trouvée dans le repère où la production a
    travaillé.
    """

    angle: float
    source: tuple[int, int]
    cible: tuple[int, int]

    @property
    def _cos_sin(self) -> tuple[float, float]:
        t = math.radians(self.angle)
        return math.cos(t), math.sin(t)

    def avant(self, x: float, y: float) -> tuple[float, float]:
        c, s = self._cos_sin
        cx, cy = self.source[0] / 2, self.source[1] / 2
        dx, dy = self.cible[0] / 2, self.cible[1] / 2
        return (
            c * (x - cx) - s * (y - cy) + dx,
            s * (x - cx) + c * (y - cy) + dy,
        )

    def arriere(self, x: float, y: float) -> tuple[float, float]:
        c, s = self._cos_sin
        cx, cy = self.source[0] / 2, self.source[1] / 2
        dx, dy = self.cible[0] / 2, self.cible[1] / 2
        return (
            c * (x - dx) + s * (y - dy) + cx,
            -s * (x - dx) + c * (y - dy) + cy,
        )


def tourner(image: Image.Image, angle: float) -> tuple[Image.Image, Rotation]:
    """L'image tournée de `angle` degrés, et l'affine qui l'a produite."""
    w, h = image.size
    c, s = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    coins = [(0, 0), (w, 0), (w, h), (0, h)]
    tournes = [(c * x - s * y, s * x + c * y) for x, y in coins]
    largeur = math.ceil(max(p[0] for p in tournes) - min(p[0] for p in tournes))
    hauteur = math.ceil(max(p[1] for p in tournes) - min(p[1] for p in tournes))

    rot = Rotation(angle=angle, source=(w, h), cible=(largeur, hauteur))
    cx, cy = w / 2, h / 2
    dx, dy = largeur / 2, hauteur / 2
    matrice = (c, s, cx - c * dx - s * dy, -s, c, cy + s * dx - c * dy)
    tournee = image.transform(
        (largeur, hauteur), Image.AFFINE, matrice, resample=Image.BICUBIC
    )
    return tournee, rot


# --------------------------------------------------------------------------
# Recherche de la fenêtre vraie, orientation comprise
# --------------------------------------------------------------------------


@dataclass
class Vraie:
    """Ce que la corrélation a trouvé dans une photo."""

    angle: float
    accord: float
    #: Les quatre coins de la fenêtre, dans le repère de la **photo d'origine**,
    #: dans l'ordre où l'illustration se lit : HG, HD, BD, BG.
    coins: list[tuple[float, float]]
    #: L'illustration extraite au cadrage trouvé — celle qu'on hache.
    coupe: Image.Image


def _fenetre_en_coins(
    fen: Fenetre, taille: tuple[int, int], rot: Rotation
) -> list[tuple[float, float]]:
    w, h = taille
    x0, y0 = fen.left * w, fen.top * h
    x1, y1 = fen.right * w, fen.bottom * h
    return [
        rot.arriere(x0, y0),
        rot.arriere(x1, y0),
        rot.arriere(x1, y1),
        rot.arriere(x0, y1),
    ]


#: Côté maximal de l'image sur laquelle la recherche angulaire travaille.
#:
#: Une photo du banc fait 4080 px, et la recherche la tourne une soixantaine de
#: fois : la réduire d'abord change des secondes en millisecondes, sans rien
#: coûter, puisque `situer_fft` ramène de toute façon la scène à `LARGEUR`.
#: **La coupe finale, elle, est reprise du plein format** — la recherche situe,
#: elle n'échantillonne pas.
TRAVAIL = 1000

#: Taille de la coupe rendue, identique à celle de `sampleArt`.
#:
#: **La même géométrie que la production**, faute de quoi la comparaison des
#: deux distances mêlerait le cadrage à un rééchantillonnage différent.
COUPE = (256, 190)


def chercher_vraie(
    photo: Image.Image,
    art: Image.Image,
    grossier: tuple[float, ...] = (0.0, 90.0, 180.0, 270.0),
) -> Vraie:
    """La fenêtre de l'illustration dans la photo, à toute orientation.

    Trois passes : les quatre quarts de tour, puis un affinage de ±24° au pas de
    3°, puis de ±3° au pas de 1°. Une carte posée de travers n'est pas un cas
    rare de ce banc — elle y est la règle, et une corrélation à orientation fixe
    ne trouverait rien sur la moitié des photos.

    La fenêtre est rendue par ses **quatre coins dans le repère de la photo
    d'origine** : c'est ce qui la rend soustractible à celle de la production,
    qui vit dans ce repère-là.
    """
    facteur = max(1.0, max(photo.size) / TRAVAIL)
    reduite = (
        photo
        if facteur <= 1.0
        else photo.resize(
            (round(photo.width / facteur), round(photo.height / facteur)),
            Image.LANCZOS,
        )
    )

    gabarits = Gabarits(art)
    meilleur: tuple[float, Fenetre, float, tuple[int, int], Rotation] | None = None

    def essayer(angle: float, parts: np.ndarray) -> None:
        nonlocal meilleur
        tournee, rot = tourner(reduite, angle)
        fen, accord = situer_fft(tournee, gabarits, parts=parts)
        if meilleur is None or accord > meilleur[2]:
            meilleur = (angle, fen, accord, tournee.size, rot)

    # **L'échelle se cherche large une fois, puis se resserre.** Rejouer la
    # centaine d'échelles à chacune des vingt-huit orientations coûterait cinq
    # fois le travail utile : une carte ne change pas de taille quand on la
    # regarde de biais.
    for angle in grossier:
        essayer(angle, PARTS_GROSSIER)
    assert meilleur is not None

    for pas, etendue in ((3.0, 24.0), (1.0, 3.0)):
        centre = meilleur[0]
        part = meilleur[1].right - meilleur[1].left
        voisines = np.arange(
            max(0.05, part - 0.05), min(1.0, part + 0.05) + 1e-9, 0.01
        )
        # **L'angle central est rejoué, et ce n'est pas redondant.** Il a été
        # retenu sur la grille grossière ; le laisser avec son ancien accord
        # donnerait aux angles voisins l'avantage d'une grille plus fine, et le
        # banc conclurait qu'une carte droite est de travers — mesuré, le témoin
        # passait de 0° à -1° et son accord de 0,806 à 0,491.
        n = int(etendue / pas)
        for k in range(-n, n + 1):
            essayer(centre + k * pas, voisines)

    angle, fen, accord, taille, rot = meilleur
    coins = [
        (x * facteur, y * facteur)
        for x, y in _fenetre_en_coins(fen, taille, rot)
    ]

    # **La coupe est reprise du plein format, par les quatre coins.** C'est
    # exactement ce que `sampleArt` fait du quadrilatère de production : lire un
    # quadrilatère et le rendre à plat. Découper la vignette réduite paierait la
    # réduction en plus du cadrage, et la distance mesurée ne serait plus celle
    # du seul cadrage.
    hg, hd, bd, bg = coins
    coupe = photo.transform(
        COUPE,
        Image.QUAD,
        (hg[0], hg[1], bg[0], bg[1], bd[0], bd[1], hd[0], hd[1]),
        resample=Image.BICUBIC,
    )
    return Vraie(angle=angle, accord=accord, coins=coins, coupe=coupe)


# --------------------------------------------------------------------------
# Références Scryfall
# --------------------------------------------------------------------------


def _telecharger(client: httpx.Client, url: str, vers: Path) -> Image.Image:
    if vers.exists():
        return Image.open(vers).convert("RGB")
    reponse = client.get(url, timeout=60, follow_redirects=True)
    reponse.raise_for_status()
    time.sleep(DELAI)
    vers.parent.mkdir(parents=True, exist_ok=True)
    vers.write_bytes(reponse.content)
    return Image.open(BytesIO(reponse.content)).convert("RGB")


@dataclass
class Reference:
    nom: str
    art: Image.Image
    carte: Image.Image
    empreinte: object


def reference(client: httpx.Client, extension: str, numero: str) -> Reference:
    """L'illustration de référence d'une impression, et son empreinte.

    **La même empreinte que celle de l'index**, et non une approximation :
    `index_builder` hache `art_crop` tel quel pour Magic (`GAMES_WITH`
    `_PREDETOURED_ART`), ce que cette fonction refait à l'identique.
    """
    fiche = CACHE / f"{extension}-{numero}.json"
    if fiche.exists():
        carte = json.loads(fiche.read_text(encoding="utf-8"))
    else:
        reponse = client.get(
            f"https://api.scryfall.com/cards/{extension}/{numero}", timeout=30
        )
        reponse.raise_for_status()
        carte = reponse.json()
        time.sleep(DELAI)
        fiche.parent.mkdir(parents=True, exist_ok=True)
        fiche.write_text(json.dumps(carte), encoding="utf-8")

    images = carte["image_uris"]
    art = _telecharger(
        client, images["art_crop"], CACHE / f"{extension}-{numero}-art.jpg"
    )
    entiere = _telecharger(
        client, images["normal"], CACHE / f"{extension}-{numero}-carte.jpg"
    )
    return Reference(
        nom=carte.get("name", "?"),
        art=art,
        carte=entiere,
        empreinte=dhash(art),
    )


# --------------------------------------------------------------------------
# Le relevé de production
# --------------------------------------------------------------------------


def _distance_hex(hexa: str, empreinte: int) -> int:
    """Distance entre une empreinte reçue du Dart et une référence Python.

    **Non signé des deux côtés, et c'est tout le piège.** `dhash` rend un entier
    non signé ; `to_signed_64` n'existe que pour le stockage Postgres. Replier la
    valeur du Dart en signé — ce que faisait la première version — donnait un
    XOR négatif, dont `int.bit_count()` compte les bits de la **valeur absolue**
    sans rien signaler. Le défaut ne frappait que les empreintes dont le bit de
    poids fort vaut 1 : une ligne sur deux était juste, et la mesure annonçait
    51 bits là où la production en trouvait 3.
    """
    return hamming_distance(int(hexa, 16), empreinte)


def _ecart(prod: list[list[float]], vrai: list[tuple[float, float]]) -> float:
    """De combien la fenêtre lue s'écarte de la vraie, en part de sa largeur.

    **Coin à coin, non bord à bord.** Les deux fenêtres sont des quadrilatères
    dans le même repère ; comparer leurs boîtes englobantes effacerait justement
    l'inclinaison, qui est une part de l'erreur. La normalisation se fait sur la
    largeur de la vraie fenêtre : c'est l'unité dans laquelle « 3 % » a été dit.
    """
    largeur = math.dist(vrai[0], vrai[1])
    if largeur < 1e-6:
        return float("inf")
    return max(
        math.dist((p[0], p[1]), v) for p, v in zip(prod, vrai, strict=True)
    ) / largeur


#: Les gabarits Magic de `art_box.dart`, en fractions de la carte.
#:
#: **Cités, pas redéfinis.** Ils servent uniquement à remonter de la fenêtre
#: d'illustration au contour de la carte ; s'ils dérivaient de leur jumeau Dart,
#: le contour reconstruit serait faux sans que rien ne le dise — et un test lit
#: le Dart pour l'interdire.
MODERN = (0.080, 0.120, 0.920, 0.550)
LEGACY = (0.114, 0.100, 0.890, 0.538)
BOITES = {"modern": MODERN, "legacy": LEGACY}


def carte_depuis_fenetre(
    coins: list[tuple[float, float]], box: tuple[float, float, float, float]
) -> list[tuple[float, float]]:
    """Le contour de la carte, déduit de sa fenêtre d'illustration.

    **Pourquoi remonter jusqu'au contour.** L'écart de fenêtre dit *combien* le
    cadrage se trompe, jamais *comment* : une fenêtre décalée de 10 % peut venir
    d'un contour translaté, d'un contour trop grand, ou d'un contour qui a suivi
    autre chose que la carte. Ces trois défauts se corrigent différemment. Le
    contour, lui, se compare taille à taille et centre à centre.

    La fenêtre est l'image affine du rectangle `box` dans le repère de la carte ;
    l'inverser rend les quatre coins. C'est exact tant que la fenêtre vient d'un
    rectangle tourné — ce que la corrélation produit par construction.
    """
    gauche, haut, droite, bas = box
    hg, hd, _, bg = coins
    # Vecteurs de la carte, par unité de u et de v.
    eu = ((hd[0] - hg[0]) / (droite - gauche), (hd[1] - hg[1]) / (droite - gauche))
    ev = ((bg[0] - hg[0]) / (bas - haut), (bg[1] - hg[1]) / (bas - haut))

    def au(u: float, v: float) -> tuple[float, float]:
        return (
            hg[0] + (u - gauche) * eu[0] + (v - haut) * ev[0],
            hg[1] + (u - gauche) * eu[1] + (v - haut) * ev[1],
        )

    return [au(0, 0), au(1, 0), au(1, 1), au(0, 1)]


def _cote(coins: list[tuple[float, float]] | list[list[float]]) -> tuple[float, float]:
    """Largeur et hauteur moyennes d'un quadrilatère."""
    p = [(c[0], c[1]) for c in coins]
    largeur = (math.dist(p[0], p[1]) + math.dist(p[3], p[2])) / 2
    hauteur = (math.dist(p[0], p[3]) + math.dist(p[1], p[2])) / 2
    return largeur, hauteur


def _centre(coins: list[tuple[float, float]] | list[list[float]]) -> tuple[float, float]:
    return (
        sum(c[0] for c in coins) / 4,
        sum(c[1] for c in coins) / 4,
    )


def diagnostiquer_contour(
    quad: list[list[float]], carte_vraie: list[tuple[float, float]]
) -> dict[str, float]:
    """Comment le contour détecté diffère du vrai — trois défauts, trois remèdes.

    - `taille_l` / `taille_h` : rapport des côtés. > 1 le contour déborde,
      < 1 il rogne. Un contour qui a suivi le décor donne un chiffre aberrant.
    - `decalage` : distance des centres, en part de la largeur vraie. Un contour
      de la bonne taille mais décalé signale un bord manqué d'un seul côté.
    - `coins` : le pire coin, en part de la largeur vraie — la mesure d'ensemble.
    """
    lp, hp = _cote(quad)
    lv, hv = _cote(carte_vraie)
    if lv < 1e-6 or hv < 1e-6:
        return {"taille_l": float("nan"), "taille_h": float("nan"),
                "decalage": float("nan"), "coins": float("nan")}
    cp, cv = _centre(quad), _centre(carte_vraie)
    return {
        "taille_l": lp / lv,
        "taille_h": hp / hv,
        "decalage": math.dist(cp, cv) / lv,
        "coins": max(
            math.dist((p[0], p[1]), v)
            for p, v in zip(quad, carte_vraie, strict=True)
        )
        / lv,
    }


def pose_de(note: str) -> str:
    """Comment la carte est posée, lu dans la note du fichier de vérité.

    **La pose est une variable de la mesure, pas un commentaire.** Un carton
    couché n'échoue pas pour la même raison qu'un carton droit et brillant :
    confondre les deux dans une moyenne effacerait précisément ce que ce banc
    cherche à séparer.
    """
    for marque, pose in (
        ("couchée", "couchée"),
        ("envers", "à l'envers"),
        ("inclinée", "inclinée"),
    ):
        if marque in note:
            return pose
    return "debout"


def lire_identites(chemin: Path) -> dict[str, tuple[str, str, str, bool] | None]:
    """Le fichier de vérité du banc : quelle carte porte quelle photo.

    **Comptée à l'œil**, comme `etalement/attendu.csv` : rien ne la déduit, et
    une vérité produite par la chaîne qu'on mesure ne mesurerait rien. Les
    photos sans carte unique (décor, étalement) y portent `-`.

    La cinquième colonne vaut `perdue` quand la **corrélation** de ce banc ne
    retrouve pas la carte — constaté à l'œil sur les tracés, pas déduit d'un
    seuil de distance. Déduire l'exclusion de la distance ferait dire au banc ce
    qu'il est censé mesurer.
    """
    identites: dict[str, tuple[str, str, str, bool] | None] = {}
    for ligne in chemin.read_text(encoding="utf-8").splitlines():
        nu = ligne.strip()
        if not nu or nu.startswith("#"):
            continue
        champs = [c.strip() for c in nu.split(";")]
        if len(champs) < 3 or champs[1] == "-":
            identites[champs[0]] = None
            continue
        identites[champs[0]] = (
            champs[1],
            champs[2],
            champs[3] if len(champs) > 3 else "",
            len(champs) > 4 and champs[4] == "perdue",
        )
    return identites


# --------------------------------------------------------------------------
# Contrôle de parité
# --------------------------------------------------------------------------


def _score_direct(gc: np.ndarray, ga: np.ndarray, y: int, x: int) -> float:
    """Le score de `situer`, écrit à sa manière, en une position.

    Sert d'étalon ponctuel à la carte rendue par `_carte_ncc` : si les deux ne
    coïncident pas en un point, c'est la FFT qui a tort.
    """
    h, w = ga.shape
    bloc = gc[y : y + h, x : x + w]
    norme = float(np.sqrt((ga * ga).sum()))
    return float((bloc * ga).sum()) / (
        norme * float(np.sqrt((bloc * bloc).sum())) + 1e-6
    )


def parite(client: httpx.Client) -> None:
    """La FFT calcule-t-elle le même score, et désigne-t-elle la même fenêtre ?

    **Sans ce contrôle, accélérer changerait la vérité.** Deux vérifications,
    et elles ne disent pas la même chose :

    1. *Exactitude du score.* La carte rendue par `_carte_ncc` est comparée au
       score de `situer`, réécrit à sa manière, en plusieurs positions. C'est la
       seule preuve que la FFT calcule bien la même quantité, et non une
       quantité voisine.
    2. *Accord sur la fenêtre.* Les deux méthodes sont lâchées dans les
       conditions de `magic_art_window` — largeur 240, échelles 0,55 à 1,00, une
       carte entière — où la réponse attendue est le gabarit `modern` en place.

    **Les accords rapportés diffèrent, et ce n'est pas une divergence.** Le pic
    de corrélation ne fait qu'**un pixel** de large : mesuré sur *Take Up the
    Shield*, il vaut 0,906 à son sommet et 0,588 un pixel plus bas. Le balayage
    de `situer` avance de deux en deux et le manque presque toujours — il situe
    donc la fenêtre juste, mais sous-estime son propre accord. C'est pourquoi ce
    banc rapporte des accords plus élevés que les 0,525 cités au CLAUDE.md : ce
    sont les mêmes fenêtres, mieux lues.
    """
    print("Parite FFT / balayage (conditions de magic_art_window)\n")
    parts = np.arange(0.55, 1.001, 0.01)
    for extension, numero in (("msh", "348"), ("msh", "271"), ("msh", "125")):
        ref = reference(client, extension, numero)
        debut = time.perf_counter()
        lent, score_lent = situer(ref.carte, ref.art)
        temps_lent = time.perf_counter() - debut
        debut = time.perf_counter()
        vite, score_vite = situer_fft(ref.carte, ref.art, largeur=240, parts=parts)
        temps_vite = time.perf_counter() - debut

        derive = max(
            abs(lent.left - vite.left),
            abs(lent.top - vite.top),
            abs(lent.right - vite.right),
            abs(lent.bottom - vite.bottom),
        )
        # Exactitude : la carte rendue par la FFT contre le score écrit à la main.
        prete = Scene(ref.carte, largeur=240)
        gc = prete.gc
        w = round(240 * (vite.right - vite.left))
        h = round(w * ref.art.height / ref.art.width)
        ga = gradient(ref.art.resize((w, h), Image.LANCZOS))
        grille = _carte_ncc(prete, ga)
        assert grille is not None
        py, px = divmod(int(np.argmax(grille)), grille.shape[1])
        sondes = [(py, px), (py + 1, px), (py, px + 1), (py + 5, px + 7)]
        pire = max(
            abs(float(grille[y, x]) - _score_direct(gc, ga, y, x))
            for y, x in sondes
            if 0 <= y < grille.shape[0] and 0 <= x < grille.shape[1]
        )
        dessous = float(grille[min(py + 1, grille.shape[0] - 1), px])

        print(f"  {ref.nom[:30]:32s}")
        print(f"    balayage {lent}  accord {score_lent:.3f}  {temps_lent:5.1f} s")
        print(f"    FFT      {vite}  accord {score_vite:.3f}  {temps_vite:5.2f} s")
        print(
            f"    score FFT contre score direct : ecart max {pire:.2e}"
            f" - {'EXACT' if pire < 1e-4 else 'DIVERGENT'}"
        )
        print(
            f"    largeur du pic : sommet {float(grille[py, px]):.3f}, "
            f"un pixel plus bas {dessous:.3f}"
        )
        etat = "identiques" if derive <= 0.01 else "DIVERGENTES"
        print(
            f"    fenetres : derive max {derive:.4f} - {etat}"
            f"  (acceleration x{temps_lent / max(temps_vite, 1e-6):.0f})\n"
        )
    print(
        "gabarit modern en place : left 0.080  top 0.120  right 0.920  "
        "bottom 0.550\n"
    )


def temoin(client: httpx.Client, extension: str, numero: str) -> None:
    """La chaîne de mesure rend-elle zéro bit sur le rendu de l'éditeur ?

    **Le témoin compte autant que la mesure.** Si la carte officielle, passée
    par la même recherche de fenêtre, le même découpage et la même empreinte, ne
    retombe pas sur sa propre référence, c'est la méthode qui est fausse — et
    tout ce qu'on lirait ensuite sur les photos serait du bruit.
    """
    ref = reference(client, extension, numero)
    trouve = chercher_vraie(ref.carte, ref.art)
    bits = hamming_distance(dhash(trouve.coupe), ref.empreinte)
    print(
        f"Témoin — {ref.nom} ({extension} {numero}) : rendu officiel passé dans "
        f"la même chaîne\n"
        f"  angle {trouve.angle:+.0f}°  accord {trouve.accord:.3f}  "
        f"**{bits} bits** de sa propre référence\n"
    )


# --------------------------------------------------------------------------
# La mesure
# --------------------------------------------------------------------------


@dataclass
class Ligne:
    fichier: str
    carte: str
    pose: str
    #: Faux quand la corrélation ne retrouve pas la carte : la ligne mesure
    #: alors le banc, pas la reconnaissance.
    verite_trouvee: bool
    detouree: bool
    ecart: float | None
    d_prod: int | None
    d_vrai: int | None
    accord: float
    angle: float
    #: Comment le contour détecté diffère du vrai — voir `diagnostiquer_contour`.
    taille_l: float | None
    taille_h: float | None
    decalage: float | None
    coins: float | None
    verdict_distance: int | None
    verdict_sur: bool
    verdict_juste: bool | None


def mesurer(
    releve: dict,
    photos: Path,
    identites: dict[str, tuple[str, str, str, bool] | None],
    dump: Path | None = None,
) -> list[Ligne]:
    lignes: list[Ligne] = []
    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        for entree in releve["photos"]:
            nom = entree["file"]
            cible = identites.get(nom)
            if cible is None:
                continue
            extension, numero, note, perdue = cible
            ref = reference(client, extension, numero)
            photo = Image.open(photos / nom).convert("RGB")
            trouve = chercher_vraie(photo, ref.art)
            d_vrai = hamming_distance(dhash(trouve.coupe), ref.empreinte)

            d_prod: int | None = None
            ecart: float | None = None
            fenetre_prod: list[list[float]] | None = None
            contour: dict[str, float] = {}
            # Le contour que la corrélation implique — la carte, pas sa fenêtre.
            carte_vraie = carte_depuis_fenetre(trouve.coins, MODERN)
            carte_prod: list[tuple[float, float]] | None = None
            if entree.get("located"):
                meilleure = min(
                    entree["hypotheses"],
                    key=lambda h: _distance_hex(h["hash"], ref.empreinte),
                )
                d_prod = _distance_hex(meilleure["hash"], ref.empreinte)
                fenetre_prod = meilleure["window"]
                ecart = _ecart(fenetre_prod, trouve.coins)
                # **Le contour tel que l'hypothèse gagnante l'a lu**, et non le
                # quadrilatère brut : c'est l'orientation retenue qui décide
                # quel coin est le haut-gauche, et comparer deux contours lus
                # dans des sens différents ne mesurerait rien.
                carte_prod = carte_depuis_fenetre(
                    [(p[0], p[1]) for p in fenetre_prod],
                    BOITES.get(meilleure["frame"], MODERN),
                )
                contour = diagnostiquer_contour(
                    [[p[0], p[1]] for p in carte_prod], carte_vraie
                )

            if dump is not None:
                tracer(
                    photo,
                    [[p[0], p[1]] for p in carte_prod] if carte_prod else None,
                    fenetre_prod,
                    trouve.coins,
                    dump / nom,
                    carte_vraie=carte_vraie,
                )

            verdict = entree.get("verdict") or {}
            lignes.append(
                Ligne(
                    fichier=nom,
                    carte=ref.nom,
                    pose=pose_de(note),
                    verite_trouvee=not perdue,
                    detouree=bool(entree.get("located")),
                    ecart=ecart,
                    d_prod=d_prod,
                    d_vrai=d_vrai,
                    accord=trouve.accord,
                    angle=trouve.angle,
                    taille_l=contour.get("taille_l"),
                    taille_h=contour.get("taille_h"),
                    decalage=contour.get("decalage"),
                    coins=contour.get("coins"),
                    verdict_distance=verdict.get("distance"),
                    verdict_sur=bool(verdict.get("confident")),
                    verdict_juste=(
                        None
                        if not verdict
                        else verdict.get("printId") is not None
                        and d_prod is not None
                        and verdict.get("distance") == d_prod
                    ),
                )
            )
            print(
                f"  {nom[-17:]:18s} {ref.nom[:24]:26s} {pose_de(note):10s} "
                f"{'VERITE PERDUE' if perdue else '             '} "
                f"angle {trouve.angle:+6.1f}  accord {trouve.accord:.3f}  "
                f"ecart "
                f"{'    -' if ecart is None else format(100 * ecart, '5.1f')} %"
                f"  prod {'  -' if d_prod is None else format(d_prod, '3d')} bits"
                f"  vraie {d_vrai:3d} bits"
            )
    return lignes


def tracer(
    photo: Image.Image,
    quad: list[list[float]] | None,
    fenetre_prod: list[list[float]] | None,
    fenetre_vraie: list[tuple[float, float]],
    vers: Path,
    carte_vraie: list[tuple[float, float]] | None = None,
) -> None:
    """Dessine les trois cadres sur la photo, et l'écrit.

    **Regarder les tracés n'est pas facultatif.** Le banc d'étalement le dit
    déjà : deux fois pendant les chantiers précédents, un compteur a annoncé un
    succès alors que la forme retenue était l'image entière, puis le bloc de
    texte. Un écart de 148 % ne dit pas *où* la fenêtre est partie.

    Rouge : le contour de la carte, tel que la production le lit.
    Orange : la fenêtre d'illustration qu'elle y prélève.
    Vert clair : le contour que la corrélation implique — la vraie carte.
    Vert : la fenêtre que la corrélation situe — la vérité de ce banc.

    **Les deux contours se superposent, et c'est ce qu'on regarde** : le rouge
    déborde-t-il, rogne-t-il, ou a-t-il suivi autre chose ?
    """
    from PIL import ImageDraw

    facteur = max(1.0, max(photo.size) / 1400)
    vue = photo.resize(
        (round(photo.width / facteur), round(photo.height / facteur)),
        Image.LANCZOS,
    )
    dessin = ImageDraw.Draw(vue)

    def polygone(coins, couleur, epaisseur) -> None:
        points = [(x / facteur, y / facteur) for x, y in coins]
        dessin.line(points + [points[0]], fill=couleur, width=epaisseur)

    if carte_vraie:
        polygone(carte_vraie, (150, 255, 150), 6)
    if quad:
        polygone(quad, (255, 60, 60), 4)
    if fenetre_prod:
        polygone(fenetre_prod, (255, 165, 0), 3)
    polygone(fenetre_vraie, (60, 230, 60), 3)

    vers.parent.mkdir(parents=True, exist_ok=True)
    vue.save(vers, quality=88)


def _mediane(valeurs: list[float]) -> float:
    return statistics.median(valeurs) if valeurs else float("nan")


def _bloc(titre: str, groupe: list[Ligne]) -> None:
    if not groupe:
        return
    bons_prod = sum(1 for l in groupe if (l.d_prod if l.d_prod is not None else 99) <= SEUIL_CONFIANCE)
    bons_vrai = sum(1 for l in groupe if (l.d_vrai if l.d_vrai is not None else 99) <= SEUIL_CONFIANCE)
    ecarts = [l.ecart for l in groupe if l.ecart is not None]
    prods = [float(l.d_prod) for l in groupe if l.d_prod is not None]
    vrais = [float(l.d_vrai) for l in groupe if l.d_vrai is not None]
    print(
        f"  {titre:26s} {len(groupe):3d}  "
        f"{_mediane(ecarts) * 100 if ecarts else float('nan'):6.1f} %  "
        f"{_mediane(prods):6.1f}       {_mediane(vrais):6.1f}       "
        f"{bons_prod:2d} / {bons_vrai:2d}"
    )


def resumer(lignes: list[Ligne]) -> None:
    perdues = [l for l in lignes if not l.verite_trouvee]
    bonnes = [l for l in lignes if l.verite_trouvee]
    utiles = [l for l in bonnes if l.d_prod is not None and l.ecart is not None]

    print(f"\n{'=' * 84}\nRESUME - {len(lignes)} photos a carte unique\n{'=' * 84}")
    if perdues:
        print(
            f"\n{len(perdues)} ecartee(s) : la correlation n'y retrouve pas la "
            f"carte (constate a l'oeil sur les traces)."
        )
        for l in perdues:
            print(f"    {l.fichier[-17:]:18s} {l.carte[:26]:28s} {l.pose}")

    print(
        f"\n  Sur les {len(bonnes)} photos ou la verite est etablie :\n"
        "\n  groupe                       n   ecart   d_prod       d_vraie   "
        "sous 12 bits (prod/vraie)"
    )

    # **Par pose d'abord.** Un carton couché et un carton droit n'échouent pas
    # pour la même raison ; les moyenner effacerait ce que le banc sépare.
    for pose in ("debout", "couchée", "à l'envers", "inclinée"):
        _bloc(pose, [l for l in bonnes if l.pose == pose])

    print()
    _bloc("cadre juste (ecart<=5%)", [l for l in utiles if (l.ecart or 9) <= 0.05])
    _bloc("cadre faux  (ecart >5%)", [l for l in utiles if (l.ecart or 9) > 0.05])

    print()
    _bloc("TOUTES", bonnes)

    droites = [l for l in bonnes if l.pose == "debout"]
    plancher = [float(l.d_vrai) for l in droites if l.d_vrai is not None]
    if plancher:
        sous_seuil = sum(1 for d in plancher if d <= SEUIL_CONFIANCE)
        print(
            f"\nPlancher sur cartes droites - la vraie fenetre rend une mediane "
            f"de {_mediane(plancher):.1f} bits ; {sous_seuil}/{len(plancher)} "
            f"passent sous {SEUIL_CONFIANCE}."
        )

    # **Le coefficient de correlation ne vaut rien ici, et il faut le dire.**
    # Les ecarts ne s'etalent pas : ils sont soit de quelques pour cent, soit de
    # plus de cent. Un r calcule sur une distribution a deux tas mesure l'ecart
    # entre les tas, pas une pente. Ce qui repond a la question, c'est le tableau
    # ci-dessus : combien passent sous le seuil dans chaque tas.
    tas_juste = [l for l in utiles if (l.ecart or 9) <= 0.05]
    tas_faux = [l for l in utiles if (l.ecart or 9) > 0.05]
    print(
        f"\nRepartition des ecarts : {len(tas_juste)} sous 5 %, "
        f"{len(tas_faux)} au-dela — dont "
        f"{sum(1 for l in tas_faux if (l.ecart or 0) > 0.5)} au-dela de 50 %. "
        "La grandeur n'est pas continue : inutile d'en tirer une pente."
    )

    # **De quoi l'erreur de cadre est faite.** Trois défauts se corrigent
    # differemment : un contour trop grand, un contour decale, un contour parti
    # ailleurs. Les confondre sous « ecart » ferait chercher au mauvais endroit.
    avec = [l for l in bonnes if l.taille_l is not None]
    if avec:
        print(f"\n{'=' * 84}\nDE QUOI L'ERREUR DE CADRE EST FAITE\n{'=' * 84}")
        print(
            "\n  Contour detecte contre contour vrai, en part de la largeur de "
            "la carte.\n"
            "  taille > 1 : deborde   taille < 1 : rogne   "
            "decalage : centres    coins : le pire\n"
        )
        print(
            f"  {'photo':>10s} {'carte':24s} {'taille l':>9s} {'taille h':>9s} "
            f"{'decalage':>9s} {'coins':>7s}  {'d_prod':>7s}  {'d_vraie':>8s}"
        )
        for l in sorted(avec, key=lambda x: x.coins or 0):
            print(
                f"  {l.fichier[-13:-4]:>10s} {l.carte[:24]:24s} "
                f"{l.taille_l:9.2f} {l.taille_h:9.2f} "
                f"{100 * (l.decalage or 0):8.1f}% {100 * (l.coins or 0):6.1f}%"
                f"  {l.d_prod:7d}  {l.d_vrai:8d}"
            )
        deborde = [l for l in avec if (l.taille_l or 0) > 1.10 or (l.taille_h or 0) > 1.10]
        rogne = [l for l in avec if (l.taille_l or 9) < 0.90 or (l.taille_h or 9) < 0.90]
        juste = [l for l in avec if l not in deborde and l not in rogne]
        print(
            f"\n  {len(deborde)} contour(s) qui debordent de plus de 10 %, "
            f"{len(rogne)} qui rognent de plus de 10 %, "
            f"{len(juste)} a la bonne taille."
        )


def main() -> None:
    parseur = argparse.ArgumentParser(description=__doc__)
    parseur.add_argument("--releve", default="../app/tool/.cache/plafond-carte-seule.json")
    parseur.add_argument("--photos", default="../../.deckhand-bench/photos/carte-seule")
    parseur.add_argument("--identites", default=None)
    parseur.add_argument("--parite", action="store_true")
    parseur.add_argument("--temoin", action="store_true")
    # **Le relevé se conserve.** La mesure coûte plusieurs minutes ; une
    # question voisine ne doit pas obliger à la refaire, sans quoi on se retient
    # d'en poser.
    parseur.add_argument("--sortie", default=".cache/plafond-mesure.json")
    parseur.add_argument(
        "--depuis", default=None, help="relire une mesure au lieu de la refaire"
    )
    parseur.add_argument(
        "--dump", default=None, help="dossier où écrire les tracés à regarder"
    )
    arguments = parseur.parse_args()

    if arguments.depuis:
        brut = json.loads(Path(arguments.depuis).read_text(encoding="utf-8"))
        resumer([Ligne(**l) for l in brut])
        return

    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        if arguments.parite:
            parite(client)
            return
        if arguments.temoin:
            temoin(client, "msh", "348")
            temoin(client, "msh", "271")
            return

    photos = Path(arguments.photos)
    identites = lire_identites(
        Path(arguments.identites) if arguments.identites else photos / "attendu.csv"
    )
    releve = json.loads(Path(arguments.releve).read_text(encoding="utf-8"))

    print(
        f"index de {releve['index']} empreintes, "
        f"{len(releve['photos'])} photos relevées\n"
    )
    lignes = mesurer(
        releve, photos, identites, Path(arguments.dump) if arguments.dump else None
    )
    sortie = Path(arguments.sortie)
    sortie.parent.mkdir(parents=True, exist_ok=True)
    sortie.write_text(
        json.dumps([vars(l) for l in lignes], indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    resumer(lignes)
    print(f"\nmesure conservée dans {sortie}")


if __name__ == "__main__":
    main()
