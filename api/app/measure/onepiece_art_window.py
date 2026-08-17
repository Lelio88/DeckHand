"""Banc : où tombe l'illustration sur une carte One Piece.

**La méthode est celle qui a abouti pour Pokémon puis pour SWU** : empiler des
cartes alignées éteint les illustrations en un gris terne dont le gradient
s'effondre, tandis que les traits imprimés au même endroit sur chaque carte y
montent en flèche. *Ce qui survit à la moyenne, c'est ce qui ne bouge pas.*

Les primitives numériques viennent du banc Pokémon — `quiet_run`, `_relief`,
`separation`, `Stack` ne connaissent rien à Pokémon, elles ne manipulent que des
tableaux. Les déplacer dans un module commun serait plus propre et toucherait un
banc éprouvé pour un gain d'esthétique ; le principe de préservation dit de ne
pas le faire.

**Deux choses distinguent ce jeu des deux précédents, et toutes deux le
simplifient.** Aucune carte n'est imprimée en travers — les quatre types sont
debout, mesuré sur les rendus —, et les tailles ne sont que deux : 600 × 838
pour la grande majorité, 868 × 1213 pour le reste, de rapports 0,7160 et 0,7156.
SWU en publiait treize. La normalisation reste nécessaire mais ne déforme rien :
les deux rapports encadrent celui du carton (63 × 88 = 0,7159) à un dix-millième.

**Ce que la mesure doit trancher** : combien de fenêtres pour quatre types. SWU
en a demandé cinq, une par type, après que `--compare` eut montré que la fenêtre
du traitement ordinaire les servait tous. La même question se pose ici, et elle
se tranche **en bits, pas en pixels**.

Usage :
    cd api && .venv/Scripts/python -m app.measure.onepiece_art_window
    #   --size N     cartes empilées par groupe (défaut 40)
    #   --group T    ne mesurer qu'un type
    #   --dump DIR   écrire l'image moyenne et son gradient, pour regarder
    #   --compare    éprouver chaque type sous la fenêtre des autres
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from app.measure.art_collisions import MAX_TRUSTED_DISTANCE
from app.measure.onepiece_taxonomy import Entry, load
from app.measure.optcgapi_probe import Probe, ProbeError
from app.measure.pokemon_art_window import (
    Stack,
    _relief,
    quiet_run,
    separation,
    tightest_pair,
)
from app.vision.art_box import ArtBox, crop
from app.vision.dhash import _to_grey, dhash

#: Taille de référence : le mode des rendus. Tout y est ramené avant empilement.
CANONICAL = (600, 838)

#: En deçà de ce plus grand côté, le rendu est une vignette — l'agrandir
#: inventerait des arêtes que l'original n'a pas.
MIN_LONG_SIDE = 500

#: Bande de sondage verticale, en fractions de la hauteur, et abscisse de
#: départ. Une zone dont on part du principe qu'elle est dans l'illustration,
#: pour amorcer la recherche.
#:
#: **Une seule bande pour les quatre types, et c'est une hypothèse à vérifier.**
#: SWU a montré qu'une maquette peut inverser l'ordre — son Event porte
#: l'illustration en bas quand son Unit la porte en haut, et sonder au mauvais
#: endroit rendait le pavé de texte comme fenêtre, avec une stabilité parfaite
#: et une séparation de 16,5 bits contre 31. Le banc écrit donc l'image moyenne
#: sur demande (`--dump`), et c'est elle qui tranche si un type résiste.
PROBE_BAND = (0.20, 0.40)
PROBE_X = 0.50

#: Nombre minimal de cartes pour qu'un empilement veuille dire quelque chose.
MIN_STACK = 12

#: **Le haut du filigrane, et c'est lui qui borne toutes les fenêtres.**
#:
#: Les rendus publiés portent « SAMPLE » en travers de l'illustration — et il
#: vient de l'**éditeur** : Bandai marque ainsi les images de sa liste de
#: cartes, optcgapi ne fait que les reprendre. Aucune source légitime n'en
#: publiera sans.
#:
#: Mesuré sur les quatre types, par la luminance de l'image moyenne : la bande
#: claire commence à **0,4224 sur les quatre**, à la ligne près, et court
#: jusqu'à 0,58. Les Personnages et les Événements s'y arrêtaient déjà d'
#: eux-mêmes — le filigrane est un trait constant, donc il arrête la plage
#: calme. Les Leaders (0,6086) et les Décors (0,5776) le traversaient, et leurs
#: fenêtres dérivaient de 156 et 130 px entre deux tirages disjoints.
#:
#: **Ce plafond est ce qui rend le scan possible malgré le filigrane.** La zone
#: retenue est de l'illustration pure, présente à l'identique sur une photo de
#: carton — qui, elle, n'est pas marquée. Une fenêtre qui descendrait plus bas
#: comparerait une empreinte marquée à une empreinte qui ne l'est pas, et la
#: reconnaissance échouerait sans que rien ne le dise.
WATERMARK_TOP = 0.4224


@dataclass(frozen=True)
class Group:
    """Un lot d'entrées censées partager une mise en page."""

    name: str
    entries: list[Entry]

    def draw(self, size: int, offset: int = 0) -> list[Entry]:
        """Tirage stable : même groupe, même taille, mêmes cartes.

        Le tri par empreinte du code tient lieu de hasard. Un tirage aléatoire à
        chaque exécution rendrait deux mesures incomparables, et l'écart entre
        deux lots se confondrait avec l'écart entre deux méthodes.

        [offset] sert le tirage de contrôle : décaler de la taille d'un lot
        donne un second échantillon **disjoint**, seule façon de savoir si la
        fenêtre décrit le gabarit ou l'échantillon.
        """
        ordered = sorted(self.entries, key=lambda e: hashlib.md5(e.image_id.encode()).digest())
        return ordered[offset : offset + size]


def load_plane(probe: Probe, entry: Entry, tally: Counter | None = None) -> np.ndarray | None:
    """Une carte en niveaux de gris, ramenée à [CANONICAL], ou `None`.

    **Une carte écartée doit dire pourquoi.** « 30 empreintes pour 40 cartes »
    se lit comme un gabarit mesuré si l'on ne sait pas que dix rendus étaient
    des vignettes — ou, tout autrement, que le réseau a lâché.
    """

    def note(reason: str) -> None:
        if tally is not None:
            tally[reason] += 1

    if not entry.image:
        note("sans rendu publie")
        return None
    try:
        path = probe.image(entry.image)
    except ProbeError:
        note("rendu refuse")
        return None
    except Exception:
        note("telechargement echoue")
        return None

    with Image.open(path) as raw:
        if max(raw.size) < MIN_LONG_SIDE:
            note("vignette, trop petite pour etre agrandie")
            return None
        if raw.width > raw.height:
            note("rendu couche, inattendu pour ce jeu")
            return None
        flat = Image.new("RGB", raw.size, (255, 255, 255))
        flat.paste(raw, mask=raw.getchannel("A") if raw.mode == "RGBA" else None)
        if raw.size != CANONICAL:
            # LANCZOS plutôt qu'un filtre net : on réduit presque toujours, et
            # un filtre net y crée du crénelage — de fausses arêtes, exactement
            # ce que le banc cherche.
            flat = flat.resize(CANONICAL, Image.LANCZOS)
            note("redimensionnee")
        else:
            note("lue telle quelle")
        return _to_grey(flat).astype(np.float32)


def build_stack(
    probe: Probe, group: Group, size: int, offset: int = 0, tally: Counter | None = None
) -> Stack | None:
    read = [
        (e.image_id, plane)
        for e in group.draw(size, offset)
        if (plane := load_plane(probe, e, tally)) is not None
    ]
    if len(read) < MIN_STACK:
        return None
    planes = [plane for _, plane in read]
    cube = np.stack(planes)
    return Stack(
        name=group.name,
        count=len(planes),
        mean=cube.mean(axis=0),
        deviation=cube.std(axis=0),
        planes=planes,
        ids=[name for name, _ in read],
    )


@dataclass(frozen=True)
class Window:
    """Une fenêtre mesurée, et de quoi juger si elle vaut quelque chose."""

    box: ArtBox
    pixels: tuple[int, int, int, int]
    inside_flatness: float
    edge_relief: tuple[float, float, float, float]
    art_luminance: float
    below_luminance: float
    touches_border: bool

    def describe(self) -> str:
        left, top, right, bottom = self.pixels
        return (
            f"({self.box.left:.4f} {self.box.top:.4f} "
            f"{self.box.right:.4f} {self.box.bottom:.4f})"
            f"  px [{left}, {top}, {right}, {bottom}]"
        )


def derive(stack: Stack) -> Window:
    """La fenêtre d'illustration, et les preuves qui vont avec.

    Les colonnes d'abord, sondées sur une bande certainement illustrée ; puis
    les lignes, sondées entre les colonnes que l'on vient de fixer. L'inverse
    ferait entrer le pavé de texte, pleine largeur, dans le profil des colonnes.
    """
    height, width = stack.mean.shape
    sharp = stack.sharpness
    probe_top = int(PROBE_BAND[0] * height)
    probe_bottom = int(PROBE_BAND[1] * height)

    col_profile = sharp[probe_top:probe_bottom, :].mean(axis=0)
    quarter, three_quarters = width // 4, 3 * width // 4
    col_background = float(np.median(col_profile[quarter:three_quarters]))
    start = min(max(int(PROBE_X * width), 0), width - 1)
    left, right = quiet_run(col_profile, start, start, col_background)

    row_profile = sharp[:, left : right + 1].mean(axis=1)
    row_background = float(np.median(row_profile[probe_top:probe_bottom]))
    top, bottom = quiet_run(row_profile, probe_top, probe_bottom, row_background)
    # Le filigrane borne la fenêtre, quoi que la plage calme dise. Deux types
    # s'y arrêtaient seuls, deux le traversaient — et ces deux-là dérivaient de
    # 130 et 156 px d'un tirage à l'autre.
    bottom = min(bottom, int(WATERMARK_TOP * height) - 1)

    inside = sharp[top : bottom + 1, left : right + 1]
    below = stack.mean[min(bottom + 12, height - 1) :, left : right + 1]
    return Window(
        box=ArtBox(
            round(left / width, 4),
            round(top / height, 4),
            round((right + 1) / width, 4),
            round((bottom + 1) / height, 4),
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
        below_luminance=float(below.mean()) if below.size else 0.0,
        # **Le contrôle qui peut échouer.** Vérifier que la fenêtre contient la
        # bande de sondage serait vrai par construction — `quiet_run` part de
        # cette bande et ne fait que s'étendre. Ce qui peut réellement échouer,
        # c'est l'arrêt : une arête qui atteint le bord du rendu n'a pas été
        # trouvée, elle a été butée.
        touches_border=(
            left == 0 or top == 0 or right >= width - 1 or bottom >= height - 1
        ),
    )


def crop_hashes(stack: Stack, box: ArtBox) -> list[int]:
    hashes = []
    for plane in stack.planes:
        image = Image.fromarray(plane.clip(0, 255).astype(np.uint8), mode="L")
        hashes.append(dhash(crop(image, box)))
    return hashes


def build_groups(entries: list[Entry]) -> dict[str, Group]:
    """Un groupe par type, les variantes écartées.

    **Les illustrations alternatives sont exclues du tirage**, et c'est mesuré :
    1 106 entrées portent un `card_image_id` suffixé `_p1`, et leurs rendus vont
    souvent bord à bord — les empiler avec les cartes ordinaires mêlerait deux
    maquettes, ce qui est exactement ce qui a fait dériver la fenêtre Pokémon de
    32 px tant que ses Dresseurs et ses Pokémon étaient confondus.
    """
    # **Dédupliquer par identifiant de rendu, et pas seulement par code.** 56
    # entrées partagent le leur : ce sont les cartes qu'un deck de démarrage
    # réédite à l'identique — `OP02-018` paraît dans `OP-02` et dans `ST-15`.
    # Empilées deux fois, elles rendent une paire à **0 bit** qui se lit comme
    # une collision de l'index alors que c'est deux fois la même image.
    pools: dict[str, list[Entry]] = defaultdict(list)
    vus: set[str] = set()
    for e in entries:
        if not e.image or e.is_variant or e.image_id in vus:
            continue
        vus.add(e.image_id)
        pools[e.type].append(e)

    groups: dict[str, Group] = {}
    thin: list[str] = []
    for kind, lot in sorted(pools.items()):
        if len(lot) < MIN_STACK:
            thin.append(f"{kind} ({len(lot)})")
            continue
        groups[kind] = Group(name=kind, entries=lot)
    if thin:
        print(f"\ngroupes trop maigres pour être empilés : {', '.join(thin)}")
    return groups


def measure(probe: Probe, group: Group, size: int, dump: Path | None) -> None:
    tally: Counter = Counter()
    stack = build_stack(probe, group, size, tally=tally)
    if stack is None:
        print(f"\n### {group.name} — trop peu de rendus exploitables ({dict(tally)})")
        return

    window = derive(stack)
    print(f"\n### {group.name} — {stack.count} cartes empilées, "
          f"{len(group.entries)} au catalogue")
    print(f"  fenêtre        {window.describe()}")
    print(f"  platitude int. {window.inside_flatness:.2f}")
    print(f"  relief arêtes  g {window.edge_relief[0]:.1f}  h {window.edge_relief[1]:.1f}"
          f"  d {window.edge_relief[2]:.1f}  b {window.edge_relief[3]:.1f}")
    print(f"  luminance      illustration {window.art_luminance:.0f}, "
          f"au-dessous {window.below_luminance:.0f}"
          + ("" if window.art_luminance < window.below_luminance
             else "   <-- ATTENDU PLUS SOMBRE, controle en echec"))
    if window.touches_border:
        print("  <-- une arête touche le bord du rendu : aucun trait ne l'a "
              "arrêtée, la fenêtre n'a pas été trouvée mais butée")
    for reason, n in tally.most_common():
        print(f"      {reason:<40} {n}")

    control = build_stack(probe, group, size, offset=size)
    if control is not None:
        other = derive(control)
        drift = max(abs(a - b) for a, b in zip(window.pixels, other.pixels))
        print(f"  contrôle disjoint ({control.count} cartes) : "
              f"dérive {drift} px  {other.describe()}")

    hashes = crop_hashes(stack, window.box)
    mean_distance, tightest = separation(hashes)
    a, b, distance = tightest_pair(hashes, stack.ids)
    print(f"  séparation     {mean_distance:.1f} bits en moyenne, "
          f"paire la plus serrée {tightest}")
    if distance <= MAX_TRUSTED_DISTANCE:
        print(f"      <-- sous le seuil de confiance : {a} et {b} ({distance} bits)")

    if dump is not None:
        dump.mkdir(parents=True, exist_ok=True)
        Image.fromarray(stack.mean.clip(0, 255).astype(np.uint8), "L").save(
            dump / f"{group.name}_moyenne.png"
        )
        sharp = stack.sharpness
        scaled = (255 * sharp / max(sharp.max(), 1e-6)).clip(0, 255)
        Image.fromarray(scaled.astype(np.uint8), "L").save(
            dump / f"{group.name}_gradient.png"
        )
        print(f"  écrit dans {dump}")


def compare(probe: Probe, groups: dict[str, Group], size: int) -> None:
    """Éprouve chaque type sous la fenêtre des autres.

    **La question « une fenêtre ou quatre » se tranche en bits, pas en
    pixels.** C'est ainsi que Pokémon a conclu que ses quatre époques étaient
    interchangeables, et que SWU a retenu la fenêtre du traitement ordinaire
    pour tous ses tirages.
    """
    print("\n=== une fenêtre ou plusieurs ===")
    stacks: dict[str, Stack] = {}
    windows: dict[str, Window] = {}
    for name, group in sorted(groups.items()):
        stack = build_stack(probe, group, size)
        if stack is None:
            continue
        stacks[name] = stack
        windows[name] = derive(stack)

    print("  " + " " * 14 + "".join(f"{n[:11]:>13}" for n in windows))
    for name, stack in stacks.items():
        cells = []
        for other, window in windows.items():
            mean_distance, tightest = separation(crop_hashes(stack, window.box))
            mark = "*" if other == name else " "
            cells.append(f"{mean_distance:8.1f}/{tightest:<2}{mark}")
        print(f"  {name[:14]:<14}" + "".join(f"{c:>13}" for c in cells))
    print("  (moyenne / paire la plus serrée ; * = sa propre fenêtre)")


def run(size: int, only: str | None, dump: Path | None, want_compare: bool) -> None:
    probe = Probe(quiet=True)
    entries, unreachable = load(probe)
    if unreachable:
        print(f"origines injoignables : {', '.join(unreachable)}")
    groups = build_groups(entries)
    print(f"\n{len(groups)} types assez fournis pour être mesurés")
    for name, group in sorted(groups.items()):
        print(f"  {name:<14} {len(group.entries):>5} cartes ordinaires")

    if want_compare:
        compare(probe, groups, size)
        return
    for name, group in sorted(groups.items()):
        if only and name != only:
            continue
        measure(probe, group, size, dump)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=40, help="cartes par pile (défaut 40)")
    parser.add_argument("--group", default=None, help="ne mesurer que ce type")
    parser.add_argument("--dump", type=Path, default=None, help="dossier de sortie")
    parser.add_argument("--compare", action="store_true", help="éprouver les fenêtres croisées")
    args = parser.parse_args()
    run(args.size, args.group, args.dump, args.compare)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
