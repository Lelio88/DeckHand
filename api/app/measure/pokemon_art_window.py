"""Banc : où se trouve l'illustration sur une carte Pokémon, famille par famille.

**La méthode qui a rendu Yu-Gi-Oh est fermée ici.** Cette source-là publiait la
carte entière *et* son illustration détourée : la fenêtre se retrouvait en
cherchant, dans la première, la région qui reproduit la seconde — à 0,001 près
sur vingt cartes. TCGdex ne publie que la carte entière. Reste la voie
Riftbound, qui avait demandé trois méthodes dont deux ont échoué : l'image
moyenne.

**Ce qui marche ici n'est pourtant ni la luminosité ni la variance.** Les deux
ont été mesurées, et voici pourquoi elles ne suffisent pas :

- *L'écart-type entre cartes* est **plat** — 50 à 65 niveaux de gris sur toute
  la carte, bords exceptés. La couleur du cadre Pokémon suit le type du
  Pokémon : le cadre varie donc autant que l'illustration, et l'écart-type ne
  distingue rien. C'est l'impasse propre à ce jeu, et elle était invisible avant
  de la chiffrer.
- *La luminosité moyenne* sépare bien l'illustration (140-160) du pavé de texte
  (170-185), mais de 30 niveaux seulement, sans arête franche.

Ce qui reste, et qui tranche : **ce qui survit à la moyenne, c'est ce qui ne
bouge pas — donc les traits du cadre.** L'amplitude du gradient de l'image
moyenne monte à 63 sur les bords de la fenêtre d'illustration, contre 6 de fond.
Un rapport de dix. L'illustration, elle, est la zone où le gradient reste plat :
aucune arête n'y est au même endroit deux fois.

Le gradient trouve donc la fenêtre, et la luminosité moyenne sert de **contrôle
croisé** : l'illustration doit ressortir plus sombre que le pavé de texte qui la
suit. Deux signaux qui se contredisent valent un avertissement, pas un gabarit.

**Une quatrième piste a été essayée et retirée**, et elle mérite d'être écrite
pour ne pas la refaire : délimiter d'abord la « zone imprimée » par l'écart-type,
en croyant que le bord d'une carte ne varie pas. L'écart-type tombe bien à zéro
dans les vingt premières colonnes des cartes ordinaires — mais parce que leur
**bordure jaune est identique partout**, non parce qu'on serait hors du carton.
Les cartes *ex*, à bordure argentée variable, y affichent 40. La même mesure
rendait 24..575 pour les unes et 0..599 pour les autres, sur des images pourtant
cadrées de la même façon.

**La vérification se fait dans les deux sens**, comme la règle d'identité de #29
aurait dû l'être : ce que la fenêtre inclut (elle doit être plate de bout en
bout) et ce qu'elle exclut (chaque arête doit avoir un trait juste dehors). Un
contrôle sur tirage disjoint dit ensuite si la fenêtre est une propriété du
gabarit ou de l'échantillon — c'est lui qui a démasqué `category` comme axe
manquant, en faisant dériver l'arête haute de 32 px entre deux tirages.

Usage :
    cd api && .venv/Scripts/python -m app.measure.pokemon_art_window
    #   --sample N     cartes par groupe (défaut 40)
    #   --group <nom>  ne mesure que les groupes dont le nom contient <nom>
    #   --min N        ignore les groupes de moins de N cartes (défaut 30)
    #   --dump         écrit aussi les images moyennes, pour les regarder
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from app.measure.art_collisions import MAX_TRUSTED_DISTANCE
from app.measure.pokemon_taxonomy import (
    HIGH_WINDOW_STAGES,
    HIGH_WINDOW_SUFFIXES,
    POCKET_SERIE,
    Card,
    load_attribute,
    load_catalogue,
)
from app.measure.tcgdex_probe import DEFAULT_CACHE, Probe, ProbeError
from app.vision.art_box import ArtBox, crop

# `_to_grey` est la conversion en gris **du pipeline**, et non `convert("L")` :
# mesurer la fenêtre dans un espace de luminance que l'empreinte n'emploierait
# pas reviendrait à régler un gabarit sur des valeurs que personne ne reverra.
from app.vision.dhash import _to_grey, dhash, hamming_distance

#: Toutes les images de TCGdex sortent à cette taille, quelle que soit l'époque.
#: Mesuré sur des cartes de 1999 et de 2024 : 600 x 825 dans les deux cas. C'est
#: ce qui rend l'empilement possible sans redimensionner, donc sans introduire
#: le flou d'un rééchantillonnage là où on cherche justement des arêtes.
CARD_WIDTH, CARD_HEIGHT = 600, 825

#: Un rang est « calme » tant que son gradient reste sous ce multiple du fond.
#: Le fond est mesuré dans la bande de sondage, où le gradient de l'image
#: moyenne vaut 4,5 à 5,6 — d'une planéité remarquable, puisque aucune arête
#: d'illustration n'y tombe deux fois au même endroit. Les traits de fenêtre y
#: culminent à 63. Le seuil coupe donc à 12, soit dix fois moins qu'un trait et
#: deux fois plus que le plus haut accident du fond : sa valeur exacte n'a
#: aucune influence, ce qui est la définition d'un bon seuil.
QUIET_FACTOR = 2.5

#: La bande de sondage, en fractions de la hauteur : une zone dont on part du
#: principe qu'elle est dans l'illustration, pour amorcer la recherche. Le banc
#: **vérifie** ensuite que la fenêtre trouvée la contient — une hypothèse qui ne
#: se contrôle pas est une supposition déguisée.
PROBE_TOP, PROBE_BOTTOM = 0.15, 0.45


@dataclass(frozen=True)
class Group:
    """Un lot de cartes censées partager une mise en page."""

    name: str
    cards: list[Card]

    def draw(self, size: int, offset: int = 0) -> list[Card]:
        """Tirage stable : même groupe, même taille, mêmes cartes.

        Le tri par empreinte de l'identifiant tient lieu de hasard. Un tirage
        aléatoire à chaque exécution rendrait deux mesures incomparables, et
        l'écart entre deux lots se confondrait avec l'écart entre deux méthodes.

        [offset] sert le tirage de contrôle : décaler de la taille d'un lot
        donne un second échantillon **disjoint** du premier, seule façon de
        savoir si la fenêtre mesurée décrit le gabarit ou l'échantillon.
        """
        ordered = sorted(self.cards, key=lambda c: hashlib.md5(c.id.encode()).digest())
        return ordered[offset : offset + size]


@dataclass(frozen=True)
class Stack:
    """Un empilement de cartes alignées, et ce qu'on en tire."""

    name: str
    count: int
    mean: np.ndarray  # (825, 600) — l'image moyenne
    deviation: np.ndarray  # (825, 600) — l'écart-type entre cartes
    planes: list[np.ndarray]  # les cartes elles-mêmes, pour les empreintes
    ids: list[str]  # leurs identifiants, pour nommer une collision

    @property
    def sharpness(self) -> np.ndarray:
        """Amplitude du gradient de l'image moyenne.

        Somme des différences absolues avec le voisin du dessus et celui de
        gauche. Le `prepend` reprend la première ligne et la première colonne,
        de sorte que le tableau garde sa taille : un décalage d'un pixel entre
        le gradient et l'image fausserait la position des arêtes, qui est
        précisément ce qu'on mesure.

        **La différence est arrière, et cela rentre les arêtes haute et gauche
        d'un pixel.** Un trait situé juste avant le premier pixel d'illustration
        se lit sur ce premier pixel : la recherche s'arrête donc un cran à
        l'intérieur en haut et à gauche, et pile sur le trait en bas et à
        droite. Vérifié sur figure de synthèse. Le biais va dans le sens sûr —
        mieux vaut perdre un pixel d'illustration qu'en gagner un de cadre, qui
        serait identique sur toutes les cartes — et il pèse 0,17 % de la carte,
        soit un centième de cellule de la grille d'empreinte.
        """
        vertical = np.abs(np.diff(self.mean, axis=0, prepend=self.mean[:1]))
        horizontal = np.abs(np.diff(self.mean, axis=1, prepend=self.mean[:, :1]))
        return vertical + horizontal


def load_plane(
    probe: Probe, card: Card, tally: Counter | None = None
) -> np.ndarray | None:
    """Une carte en niveaux de gris, ou `None` avec la raison dans [tally].

    **Une carte écartée doit dire pourquoi.** « 175 empreintes pour 336 cartes »
    se lit comme une couverture complète si l'on ne sait pas que 161 cartes n'ont
    pas d'image publiée — ou, tout autrement, que le réseau a lâché. Les deux
    causes n'appellent pas la même conclusion, et le banc ne doit pas laisser
    croire qu'il a mesuré ce qu'il a sauté.

    Les images en RGBA — les coins arrondis des cartes modernes — sont aplaties
    sur du blanc. Les coins ne touchent aucune illustration ; les laisser
    transparents les ferait compter comme du noir et creuserait un faux minimum
    dans les quatre angles.
    """
    def note(reason: str) -> None:
        if tally is not None:
            tally[reason] += 1

    if not card.image_url:
        note("sans image publiee")
        return None
    try:
        path = probe.image(card.image_url)
    except ProbeError:
        note("image absente du CDN")
        return None
    except Exception:
        note("telechargement echoue")
        return None
    with Image.open(path) as raw:
        if raw.size != (CARD_WIDTH, CARD_HEIGHT):
            note("dimensions inattendues")
            return None
        flat = Image.new("RGB", raw.size, (255, 255, 255))
        flat.paste(raw, mask=raw.getchannel("A") if raw.mode == "RGBA" else None)
        note("lue")
        return _to_grey(flat).astype(np.float32)


def build_stack(probe: Probe, group: Group, size: int, offset: int = 0) -> Stack | None:
    """Empile un tirage du groupe et en tire moyenne et écart-type."""
    read = [
        (card.id, plane)
        for card in group.draw(size, offset)
        if (plane := load_plane(probe, card)) is not None
    ]
    if len(read) < 12:
        return None
    planes = [plane for _, plane in read]
    cube = np.stack(planes)
    return Stack(
        name=group.name,
        count=len(planes),
        mean=cube.mean(axis=0),
        deviation=cube.std(axis=0),
        planes=planes,
        ids=[card_id for card_id, _ in read],
    )


def quiet_run(
    profile: np.ndarray, probe_lo: int, probe_hi: int, background: float
) -> tuple[int, int]:
    """Plage calme autour de la bande de sondage, arrêtée par les traits du cadre.

    « Calme » veut dire : aucune arête constante. On part de la bande de
    sondage — supposée dans l'illustration, et vérifiée telle après coup — et on
    s'étend des deux côtés jusqu'au premier trait. C'est la définition même de
    la fenêtre, dont les bords sont des traits imprimés au même endroit sur
    chaque carte.

    Le fond est mesuré **dans la bande de sondage** et non sur la carte entière.
    C'est ce détail qui a rendu la mesure reproductible : pris sur la carte
    entière, il incorporait le pavé de texte, dont la densité varie d'un tirage
    à l'autre, et le seuil bougeait avec l'échantillon — la fenêtre dérivait
    alors de 32 px entre deux tirages du même groupe.
    """
    threshold = QUIET_FACTOR * background
    last = profile.size - 1

    start = probe_lo
    while start > 0 and profile[start - 1] <= threshold:
        start -= 1
    stop = probe_hi
    while stop < last and profile[stop + 1] <= threshold:
        stop += 1
    return start, stop


@dataclass(frozen=True)
class Window:
    """Une fenêtre mesurée, et de quoi juger si elle vaut quelque chose."""

    box: ArtBox
    pixels: tuple[int, int, int, int]  # gauche, haut, droite, bas
    inside_flatness: float  # gradient moyen dans la fenêtre
    edge_relief: tuple[float, float, float, float]  # saillie de chaque arête
    art_luminance: float
    outside_luminance: float

    def describe(self) -> str:
        left, top, right, bottom = self.pixels
        return (
            f"({self.box.left:.4f} {self.box.top:.4f} "
            f"{self.box.right:.4f} {self.box.bottom:.4f})"
            f"  px [{left}, {top}, {right}, {bottom}]"
        )


def derive(stack: Stack) -> Window:
    """La fenêtre d'illustration, et les preuves qui vont avec."""
    sharp = stack.sharpness
    probe_top = int(PROBE_TOP * CARD_HEIGHT)
    probe_bottom = int(PROBE_BOTTOM * CARD_HEIGHT)

    # Les colonnes d'abord, sondées sur une bande certainement illustrée ; puis
    # les lignes, sondées entre les colonnes que l'on vient de fixer. L'inverse
    # ferait entrer le pavé de texte, pleine largeur, dans le profil des
    # colonnes.
    col_profile = sharp[probe_top:probe_bottom, :].mean(axis=0)
    quarter, three_quarters = CARD_WIDTH // 4, 3 * CARD_WIDTH // 4
    col_background = float(np.median(col_profile[quarter:three_quarters]))
    centre = CARD_WIDTH // 2
    left, right = quiet_run(col_profile, centre, centre, col_background)

    row_profile = sharp[:, left : right + 1].mean(axis=1)
    row_background = float(np.median(row_profile[probe_top:probe_bottom]))
    top, bottom = quiet_run(row_profile, probe_top, probe_bottom, row_background)

    inside = sharp[top : bottom + 1, left : right + 1]
    return Window(
        box=ArtBox(
            round(left / CARD_WIDTH, 4),
            round(top / CARD_HEIGHT, 4),
            round((right + 1) / CARD_WIDTH, 4),
            round((bottom + 1) / CARD_HEIGHT, 4),
        ),
        pixels=(left, top, right, bottom),
        inside_flatness=float(inside.mean()),
        edge_relief=(
            _relief(col_profile, left, -1),
            _relief(row_profile, top, -1),
            _relief(col_profile, right, +1),
            _relief(row_profile, bottom, +1),
        ),
        art_luminance=float(stack.mean[top : bottom + 1, left : right + 1].mean()),
        # Ce qui suit la fenêtre, douze pixels plus bas pour laisser passer le
        # trait qui la borde : c'est le pavé de texte, et il doit être plus
        # clair que l'illustration.
        outside_luminance=float(
            stack.mean[min(bottom + 12, CARD_HEIGHT - 1) :, left : right + 1].mean()
        ),
    )


#: Épaisseur, en pixels, des bandes comparées de part et d'autre d'une arête.
#: Un trait de cadre fait deux à quatre pixels à cette résolution ; cinq le
#: contiennent sans mordre sur l'illustration.
RELIEF_BAND = 5


def _relief(profile: np.ndarray, edge: int, direction: int) -> float:
    """De combien le trait qui borde la fenêtre dépasse le calme intérieur.

    C'est la vérification « dans l'autre sens » : une fenêtre juste n'est pas
    seulement plate à l'intérieur, elle est **bordée**. Une arête sans relief
    signale une fenêtre coupée au milieu de l'illustration — ou une arête qui
    n'est que le bord de la carte, ce qui est une réponse légitime mais qu'il
    faut savoir distinguer.

    [direction] vaut -1 quand le dehors est du côté des petits indices (arête
    gauche, arête haute) et +1 dans l'autre cas.
    """
    if direction < 0:
        outer = profile[max(0, edge - RELIEF_BAND) : edge]
        inner = profile[edge : edge + RELIEF_BAND]
    else:
        outer = profile[edge + 1 : edge + 1 + RELIEF_BAND]
        inner = profile[max(0, edge + 1 - RELIEF_BAND) : edge + 1]
    if outer.size == 0 or inner.size == 0:
        return 0.0
    return float(outer.max() / max(inner.mean(), 1e-6))


def crop_hashes(stack: Stack, box: ArtBox) -> list[int]:
    """Empreintes du tirage, découpé selon [box]."""
    hashes = []
    for plane in stack.planes:
        image = Image.fromarray(plane.clip(0, 255).astype(np.uint8), mode="L")
        hashes.append(dhash(crop(image, box)))
    return hashes


def separation(hashes: list[int]) -> tuple[float, int]:
    """Distance moyenne entre empreintes, et la paire la plus serrée.

    C'est la monnaie du pipeline : une fenêtre qui embarque du cadre gèle des
    bits identiques sur toutes les cartes, la distance moyenne s'effondre et les
    collisions montent. Mesurer la fenêtre en pixels dit où elle est ; mesurer
    ceci dit si elle **sert**.
    """
    pairs = [
        hamming_distance(a, b)
        for i, a in enumerate(hashes)
        for b in hashes[i + 1 :]
    ]
    return (sum(pairs) / len(pairs), min(pairs)) if pairs else (0.0, 0)


def tightest_pair(hashes: list[int], ids: list[str]) -> tuple[str, str, int]:
    """Les deux cartes que l'index départagerait le moins bien, nommées.

    **Un nombre ne dit pas s'il faut s'inquiéter.** Une paire à 0 bit peut être
    deux cartes distinctes que la reconnaissance confondrait — le défaut que #29
    a coûté — ou la même carte rééditée sous deux numéros, auquel cas c'est le
    modèle d'impressions qui doit la porter, pas l'index. Seuls les identifiants
    permettent de trancher, et un banc qui ne les rend pas laisse le doute.
    """
    best = (0, 1, 64)
    for i, a in enumerate(hashes):
        for j, b in enumerate(hashes[i + 1 :], start=i + 1):
            distance = hamming_distance(a, b)
            if distance < best[2]:
                best = (i, j, distance)
    return ids[best[0]], ids[best[1]], best[2]


def build_groups(probe: Probe, split_c_by_rarity: bool) -> dict[str, Group]:
    """Découpe le catalogue en groupes (famille x époque).

    **L'époque est un axe à part entière, pas une précaution.** Magic a changé
    de cadre une fois en 2003, et cela a suffi à imposer deux gabarits. Pokémon
    a vingt-sept ans et vingt séries : mesurer une fenêtre unique sur tout le
    catalogue moyennerait des mises en page différentes, c'est-à-dire rien. La
    série est publiée par la source — c'est le découpage qu'elle reconnaît
    elle-même.
    """
    cards = load_catalogue(probe)
    suffix = load_attribute(probe, "suffix", HIGH_WINDOW_SUFFIXES)
    stage = load_attribute(probe, "stage", HIGH_WINDOW_STAGES)
    energy = load_attribute(probe, "energyType", ("Normal", "Special"))
    category = load_attribute(probe, "category", ("Energy", "Pokemon", "Trainer"))
    rarity = load_attribute(probe, "rarity", tuple(probe.json("rarities")))

    groups: dict[str, list[Card]] = {}
    for card in cards:
        if card.serie == POCKET_SERIE:
            continue
        number = card.numbered
        if number is None or card.official <= 0:
            continue
        family = _family(card, number, suffix, stage, energy, category, rarity, split_c_by_rarity)
        groups.setdefault(f"{family}-{card.serie}", []).append(card)

    return {name: Group(name, cards) for name, cards in sorted(groups.items())}


def _family(
    card: Card,
    number: int,
    suffix: dict[str, str],
    stage: dict[str, str],
    energy: dict[str, str],
    category: dict[str, str],
    rarity: dict[str, str],
    split_c_by_rarity: bool,
) -> str:
    """À quelle mise en page une carte appartient.

    **`category` est un axe, et il a été payé pour l'apprendre.** Le relevé
    d'ouverture décrivait quatre familles sans mentionner la nature de la carte.
    Mesuré : dans la même série, la fenêtre d'un Pokémon s'arrête à la ligne 390
    et celle d'un Dresseur à la ligne 430 — quarante pixels, soit 5 % de la
    hauteur. Les mêler faisait dériver l'arête haute de 32 px d'un tirage à
    l'autre, et cette dérive était le seul symptôme.
    """
    if energy.get(card.id) == "Normal":
        return "D_energie"
    if number > card.official:
        if not split_c_by_rarity:
            return "C_pleine"
        return "C_pleine." + rarity.get(card.id, "?").replace(" ", "_")
    kind = category.get(card.id, "?")
    if kind == "Trainer":
        return "T_dresseur"
    if kind == "Energy":
        return "E_speciale"
    return "B_haute" if suffix.get(card.id) or stage.get(card.id) else "A_pokemon"


def dump(stack: Stack, out: Path) -> None:
    """Écrit l'image moyenne et celle des écarts, pour les regarder.

    **Regarder précède mesurer.** C'est en regardant ces deux images que
    l'écart-type s'est révélé plat et que les traits du cadre se sont imposés
    comme le seul signal net ; aucun profil numérique ne l'aurait dit aussi
    vite.
    """
    out.mkdir(parents=True, exist_ok=True)
    Image.fromarray(stack.mean.clip(0, 255).astype(np.uint8)).save(
        out / f"{stack.name}_moyenne.png"
    )
    spread = stack.deviation
    Image.fromarray(
        (255 * spread / max(spread.max(), 1e-6)).clip(0, 255).astype(np.uint8)
    ).save(out / f"{stack.name}_ecarts.png")


def measure(probe: Probe, group: Group, size: int, want_dump: bool) -> None:
    """Mesure un groupe, et rend compte des trois contrôles."""
    stack = build_stack(probe, group, size)
    if stack is None:
        print(f"  {group.name:<34} images insuffisantes")
        return
    window = derive(stack)
    print(f"  {group.name:<34} {stack.count:>3} cartes  {window.describe()}")
    relief = "  ".join(f"{v:.1f}x" for v in window.edge_relief)
    print(f"      plat dedans {window.inside_flatness:>5.1f}   "
          f"relief des aretes (g h d b) {relief}")
    ordre = "ordre attendu" if window.art_luminance < window.outside_luminance else "INVERSE"
    print(f"      luminance : illustration {window.art_luminance:>5.1f}, "
          f"sous la fenetre {window.outside_luminance:>5.1f}  ({ordre})")

    hashes = crop_hashes(stack, window.box)
    mean_distance, closest = separation(hashes)
    whole = ArtBox(0.0, 0.0, 1.0, 1.0)
    mean_whole, closest_whole = separation(crop_hashes(stack, whole))
    print(f"      empreintes : distance moyenne {mean_distance:>4.1f} bits "
          f"(paire la plus serree {closest}) "
          f"— carte entiere {mean_whole:.1f} / {closest_whole}")
    if closest <= MAX_TRUSTED_DISTANCE:
        first, second, distance = tightest_pair(hashes, stack.ids)
        print(f"      sous le seuil de confiance : {first} et {second} "
              f"a {distance} bits")

    control = build_stack(probe, group, size, offset=size)
    if control is not None:
        other = derive(control)
        drift = max(abs(a - b) for a, b in zip(window.pixels, other.pixels))
        print(f"      tirage de controle ({control.count} autres cartes) : "
              f"ecart maximal {drift} px  {other.describe()}")
    else:
        print("      tirage de controle : pas assez de cartes restantes")

    if want_dump:
        dump(stack, DEFAULT_CACHE / "moyennes")


def compare(probe: Probe, groups: dict[str, Group], names: list[str], size: int) -> None:
    """Deux familles peuvent-elles partager un gabarit ? La réponse est en bits.

    **La question n'est pas si les deux fenêtres se ressemblent, mais ce que
    coûte de n'en garder qu'une.** L'index et le scan appliquent toujours le
    même gabarit : partager n'empêche donc pas la rencontre. Le risque est
    ailleurs — une fenêtre trop large embarque du cadre, gèle des bits
    identiques sur toutes les cartes, et rapproche des empreintes qui devraient
    rester distinctes. C'est exactement ce que `art_collisions` mesure, et c'est
    donc dans cette monnaie qu'il faut trancher.

    Trois gabarits sont éprouvés sur chaque famille : le sien, celui de l'autre,
    et leur enveloppe commune. La paire la plus serrée compte plus que la
    distance moyenne : c'est elle qui décide s'il existe deux cartes que l'index
    confondrait.
    """
    measured: dict[str, tuple[Stack, Window]] = {}
    for name in names:
        stack = build_stack(probe, groups[name], size)
        if stack is None:
            print(f"  {name} : pas assez d'images")
            return
        measured[name] = (stack, derive(stack))

    boxes = {name: window.box for name, (_, window) in measured.items()}
    boxes["enveloppe"] = ArtBox(
        min(b.left for b in boxes.values()),
        min(b.top for b in boxes.values()),
        max(b.right for b in boxes.values()),
        max(b.bottom for b in boxes.values()),
    )

    print("\n=== un gabarit commun, ou deux ? ===")
    for label, box in boxes.items():
        print(f"  gabarit {label:<22} ({box.left:.4f} {box.top:.4f} "
              f"{box.right:.4f} {box.bottom:.4f})")
    print()
    for name, (stack, _) in measured.items():
        for label, box in boxes.items():
            mean_distance, closest = separation(crop_hashes(stack, box))
            own = " <- le sien" if label == name else ""
            print(f"  {name:<24} sous {label:<22} "
                  f"moyenne {mean_distance:>4.1f} bits, "
                  f"paire la plus serree {closest:>2}{own}")


def run(
    sample: int,
    only: str | None,
    minimum: int,
    want_dump: bool,
    split_c: bool,
    merge: str | None,
) -> None:
    probe = Probe(quiet=True)
    groups = build_groups(probe, split_c)

    if merge:
        names = merge.split(",")
        missing = [n for n in names if n not in groups]
        if missing:
            sys.exit(f"groupe inconnu : {', '.join(missing)}")
        compare(probe, groups, names, sample)
        return

    chosen = [
        g for name, g in sorted(groups.items())
        if (only is None or only in name) and len(g.cards) >= minimum
    ]
    if not chosen:
        sys.exit(f"aucun groupe d'au moins {minimum} cartes ne correspond a : {only}")

    print(f"{len(chosen)} groupes mesures sur {len(groups)}\n")
    for group in chosen:
        measure(probe, group, sample, want_dump)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fenetre d'illustration Pokemon")
    parser.add_argument("--sample", type=int, default=40)
    parser.add_argument("--group", default=None)
    parser.add_argument("--min", type=int, default=30, dest="minimum")
    parser.add_argument("--dump", action="store_true")
    parser.add_argument(
        "--split-c",
        action="store_true",
        help="decoupe la famille C par rarete, pour voir si elle est homogene",
    )
    parser.add_argument(
        "--merge",
        default=None,
        help="deux groupes separes par une virgule : un gabarit commun coute-t-il ?",
    )
    args = parser.parse_args()
    try:
        run(args.sample, args.group, args.minimum, args.dump, args.split_c, args.merge)
    except KeyboardInterrupt:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
