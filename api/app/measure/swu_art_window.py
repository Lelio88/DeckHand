"""Banc : où tombe l'illustration sur une carte Star Wars Unlimited.

**La méthode est celle qui a abouti pour Pokémon**, et elle est reprise telle
quelle : empiler des cartes alignées éteint les illustrations en un gris terne
dont le gradient s'effondre, tandis que les traits imprimés au même endroit sur
chaque carte y montent en flèche. *Ce qui survit à la moyenne, c'est ce qui ne
bouge pas.* La fenêtre est la plage calme ; ses bords sont les traits qui
l'arrêtent. La luminance sert de contrôle croisé — l'illustration doit ressortir
plus sombre que le pavé de texte qui la suit —, et un second tirage **disjoint**
dit si la fenêtre décrit le gabarit ou seulement l'échantillon.

Les primitives numériques sont importées du banc Pokémon plutôt que recopiées :
`quiet_run`, `_relief`, `separation` et `Stack` ne connaissent rien à Pokémon,
elles ne manipulent que des tableaux. Les déplacer dans un module commun aurait
été plus propre, et aurait touché un banc éprouvé et couvert par des tests pour
un gain d'esthétique — le principe de préservation dit de ne pas le faire.

**Deux écarts avec le cas Pokémon, tous deux mesurés.**

*Les rendus n'ont pas une taille constante.* Pokémon sort tout en 600 × 825, ce
qui permet d'empiler sans redimensionner, donc sans introduire le flou d'un
rééchantillonnage là où on cherche des arêtes. SWU-DB publie treize formats —
1117 × 1560 pour 39 % des rendus, 1560 × 1117 pour 34 %, puis une traîne de
vignettes descendant à 418 × 300. La normalisation est donc obligatoire ici. Ce
qu'elle ne casse pas : les **rapports** sont stables à 0,4 % près (0,7154 à
0,7186 debout, 1,3929 à 1,3978 couché), donc la géométrie relative — la seule
chose que ce banc mesure, puisqu'il rend des fractions — est préservée. Les
vignettes sont écartées plutôt qu'agrandies : les agrandir inventerait des
arêtes que l'original n'a pas.

*Il y a deux orientations, et le type ne suffit pas à les prédire.* Mesuré sur
les 180 Bases non brillantes : 175 sont couchées, 5 debout, et **les cinq sont
des variantes `Hyperspace`**. L'orientation est une propriété du couple (type,
traitement), et le banc groupe donc sur ce couple plutôt que sur le seul type —
la leçon Wankul, où le champ `orientation` de la source annonçait horizontales
40 cartes dont 13 sont imprimées debout.

Usage :
    cd api && .venv/Scripts/python -m app.measure.swu_art_window
    #   --size N     cartes empilées par groupe (défaut 40)
    #   --group G    ne mesurer qu'un groupe, nommé « Type/Traitement »
    #   --dump DIR   écrire l'image moyenne et son gradient, pour regarder
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
from app.measure.pokemon_art_window import (
    QUIET_FACTOR,
    Stack,
    _relief,
    quiet_run,
    separation,
    tightest_pair,
)
from app.measure.swu_probe import Probe, ProbeError
from app.measure.swu_taxonomy import Print, load_catalogue
from app.vision.art_box import ArtBox, crop
from app.vision.dhash import _to_grey, dhash

#: Tailles de référence, par orientation : les deux modes relevés sur le cache.
#: Tout rendu y est ramené avant empilement.
CANONICAL_UPRIGHT = (1117, 1560)
CANONICAL_LAID = (1560, 1117)

#: En deçà de ce plus grand côté, le rendu est une vignette. L'agrandir
#: inventerait des arêtes ; il est écarté, et le rapport dit combien.
MIN_LONG_SIDE = 900

#: Où sonder, par **type de carte** : bande verticale en fractions de la
#: hauteur, puis abscisse de départ en fraction de la largeur.
#:
#: **La maquette suit le type, et rien d'autre ne la prédit.** C'est le même
#: constat que `category` chez Pokémon, où la fenêtre d'un Pokémon s'arrête
#: quarante pixels avant celle d'un Dresseur — et il s'est imposé ici de la
#: même façon, en regardant les images moyennes :
#:
#: * **Unit** et **Upgrade** portent l'illustration en haut, le pavé de texte
#:   en bas. C'est la maquette que l'on suppose spontanément.
#: * **Event** fait **l'inverse** — texte en haut, illustration en bas. Sonder
#:   à 0,20–0,40 y tombe en plein texte, et le banc rendait le pavé comme
#:   fenêtre : reproductible à 1 px près, et faux. 16,5 bits de séparation
#:   contre 31 ailleurs, avec une paire à 3 bits.
#: * **Leader** et **Base** sont couchés et portent l'illustration à gauche.
#:
#: Une bande est volontairement étroite : la plage calme s'étend d'elle-même
#: jusqu'aux traits. Ce qui compte est qu'elle tombe **dans** l'illustration.
PROBE_BY_TYPE: dict[str, tuple[tuple[float, float], float]] = {
    "Unit": ((0.20, 0.40), 0.50),
    "Upgrade": ((0.20, 0.40), 0.50),
    "Event": ((0.60, 0.80), 0.50),
    "Leader": ((0.35, 0.60), 0.25),
    "Base": ((0.35, 0.60), 0.25),
}

#: Repli pour un type inconnu — celui des cartes debout, le cas majoritaire.
#: Il est **signalé** plutôt que silencieux : une maquette non prévue mesurée
#: sous une bande empruntée rendrait un rectangle sans qu'on sache qu'il est
#: emprunté.
PROBE_FALLBACK = ((0.20, 0.40), 0.50)

#: Nombre minimal de cartes pour qu'un empilement veuille dire quelque chose.
#: En deçà, une illustration claire ou sombre déplace la moyenne à elle seule.
MIN_STACK = 12


@dataclass(frozen=True)
class Group:
    """Un lot d'impressions censées partager une mise en page."""

    name: str
    kind: str
    laid: bool
    prints: list[Print]

    @property
    def canonical(self) -> tuple[int, int]:
        return CANONICAL_LAID if self.laid else CANONICAL_UPRIGHT

    @property
    def probe_band(self) -> tuple[float, float]:
        return PROBE_BY_TYPE.get(self.kind, PROBE_FALLBACK)[0]

    @property
    def probe_x(self) -> float:
        return PROBE_BY_TYPE.get(self.kind, PROBE_FALLBACK)[1]

    @property
    def probe_is_borrowed(self) -> bool:
        """Ce type a-t-il sa propre bande, ou emprunte-t-il le repli ?"""
        return self.kind not in PROBE_BY_TYPE

    def draw(self, size: int, offset: int = 0) -> list[Print]:
        """Tirage stable : même groupe, même taille, mêmes cartes.

        Le tri par empreinte de l'identifiant tient lieu de hasard. Un tirage
        aléatoire à chaque exécution rendrait deux mesures incomparables, et
        l'écart entre deux lots se confondrait avec l'écart entre deux méthodes.

        [offset] sert le tirage de contrôle : décaler de la taille d'un lot
        donne un second échantillon **disjoint** du premier, seule façon de
        savoir si la fenêtre mesurée décrit le gabarit ou l'échantillon.
        """
        key = lambda p: hashlib.md5(f"{p.set_code}-{p.number}".encode()).digest()
        ordered = sorted(self.prints, key=key)
        return ordered[offset : offset + size]


def load_plane(
    probe: Probe, entry: Print, canonical: tuple[int, int], tally: Counter | None = None
) -> np.ndarray | None:
    """Une carte en niveaux de gris, ramenée à [canonical], ou `None`.

    **Une carte écartée doit dire pourquoi.** « 30 empreintes pour 40 cartes »
    se lit comme un gabarit mesuré si l'on ne sait pas que dix rendus étaient
    des vignettes — ou, tout autrement, que le réseau a lâché. Les deux causes
    n'appellent pas la même conclusion, et le banc ne doit pas laisser croire
    qu'il a mesuré ce qu'il a sauté.
    """

    def note(reason: str) -> None:
        if tally is not None:
            tally[reason] += 1

    if not entry.front_art:
        note("sans image publiee")
        return None
    try:
        path = probe.image(entry.front_art)
    except ProbeError:
        note("image refusee par le CDN")
        return None
    except Exception:
        note("telechargement echoue")
        return None

    with Image.open(path) as raw:
        if max(raw.size) < MIN_LONG_SIDE:
            note("vignette, trop petite pour etre agrandie")
            return None
        laid = canonical[0] > canonical[1]
        if (raw.width > raw.height) != laid:
            note("orientation contraire a celle du groupe")
            return None
        # Les images en RGBA — les coins arrondis — sont aplaties sur du blanc.
        # Les coins ne touchent aucune illustration ; les laisser transparents
        # les ferait compter comme du noir et creuserait un faux minimum dans
        # les quatre angles.
        flat = Image.new("RGB", raw.size, (255, 255, 255))
        flat.paste(raw, mask=raw.getchannel("A") if raw.mode == "RGBA" else None)
        if raw.size != canonical:
            # LANCZOS plutôt que le voisin le plus proche : on réduit presque
            # toujours, et un filtre net y crée du crénelage — c'est-à-dire de
            # fausses arêtes, exactement ce que le banc cherche.
            flat = flat.resize(canonical, Image.LANCZOS)
            note("redimensionnee")
        else:
            note("lue telle quelle")
        return _to_grey(flat).astype(np.float32)


def build_stack(
    probe: Probe, group: Group, size: int, offset: int = 0, tally: Counter | None = None
) -> Stack | None:
    """Empile un tirage du groupe et en tire moyenne et écart-type."""
    read = [
        (f"{p.set_code}-{p.number}", plane)
        for p in group.draw(size, offset)
        if (plane := load_plane(probe, p, group.canonical, tally)) is not None
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
    outside_luminance: float

    #: Une arête est-elle collée au bord de la carte ?
    #:
    #: **Le contrôle qui peut échouer**, et il a fallu un test pour s'en
    #: apercevoir : la première version vérifiait que la fenêtre contient la
    #: bande de sondage, ce qui est vrai *par construction* — `quiet_run` part
    #: de cette bande et ne fait que s'étendre. Un contrôle qui ne peut pas
    #: échouer n'en est pas un, et il aurait accompagné chaque mesure d'une
    #: approbation sans contenu.
    #:
    #: Ce qui peut réellement échouer, c'est l'arrêt : la plage calme est
    #: censée être bornée par les traits du cadre. Une arête qui atteint le
    #: bord du rendu n'a pas été trouvée, elle a été butée — le groupe est
    #: alors trop hétérogène pour qu'un trait survive à la moyenne, ou la
    #: bande de sondage tombe hors de l'illustration.
    touches_border: bool

    def describe(self) -> str:
        left, top, right, bottom = self.pixels
        return (
            f"({self.box.left:.4f} {self.box.top:.4f} "
            f"{self.box.right:.4f} {self.box.bottom:.4f})"
            f"  px [{left}, {top}, {right}, {bottom}]"
        )


def derive(stack: Stack, band: tuple[float, float], probe_x: float = 0.5) -> Window:
    """La fenêtre d'illustration, et les preuves qui vont avec.

    Les colonnes d'abord, sondées sur une bande certainement illustrée ; puis
    les lignes, sondées entre les colonnes que l'on vient de fixer. L'inverse
    ferait entrer le pavé de texte, pleine largeur, dans le profil des colonnes.

    [probe_x] dit **d'où** partir en largeur, en fraction de la carte. Pokémon
    part du centre parce que ses illustrations y sont ; une carte SWU couchée
    porte la sienne à gauche, et partir du centre y rendait le pavé de texte.
    """
    height, width = stack.mean.shape
    sharp = stack.sharpness
    probe_top = int(band[0] * height)
    probe_bottom = int(band[1] * height)

    col_profile = sharp[probe_top:probe_bottom, :].mean(axis=0)
    quarter, three_quarters = width // 4, 3 * width // 4
    col_background = float(np.median(col_profile[quarter:three_quarters]))
    start = min(max(int(probe_x * width), 0), width - 1)
    left, right = quiet_run(col_profile, start, start, col_background)

    row_profile = sharp[:, left : right + 1].mean(axis=1)
    row_background = float(np.median(row_profile[probe_top:probe_bottom]))
    top, bottom = quiet_run(row_profile, probe_top, probe_bottom, row_background)

    inside = sharp[top : bottom + 1, left : right + 1]
    # Le contrôle croisé : le pavé de texte doit être plus clair que
    # l'illustration. C'est lui qui empêche de prendre une bande de texte pour
    # une illustration — et il a servi, en signalant que la fenêtre des Leaders
    # tombait du mauvais côté.
    #
    # **Encore faut-il regarder là où le texte est.** Sur une carte debout il
    # suit l'illustration vers le bas ; sur une carte couchée il est à sa
    # droite. Chercher en bas dans ce cas compare l'illustration au bas
    # d'elle-même, ce qui ne dit rien. Douze pixels de garde laissent passer le
    # trait qui borde la fenêtre.
    if right - left < bottom - top:  # fenêtre plus haute que large : carte debout
        beyond = stack.mean[min(bottom + 12, height - 1) :, left : right + 1]
    else:
        beyond = stack.mean[top : bottom + 1, min(right + 12, width - 1) :]
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
        outside_luminance=float(beyond.mean()) if beyond.size else 0.0,
        touches_border=(
            left == 0 or top == 0 or right >= width - 1 or bottom >= height - 1
        ),
    )


def crop_hashes(stack: Stack, box: ArtBox) -> list[int]:
    """Empreintes du tirage, découpé selon [box]."""
    hashes = []
    for plane in stack.planes:
        image = Image.fromarray(plane.clip(0, 255).astype(np.uint8), mode="L")
        hashes.append(dhash(crop(image, box)))
    return hashes


def build_groups(probe: Probe) -> dict[str, Group]:
    """Les groupes à mesurer : un par couple (type, traitement) assez fourni.

    L'orientation d'un groupe est **lue sur ses rendus** et non déduite d'un
    champ : la source n'en publie aucun, et le précédent Wankul montre qu'un
    champ qui prétend la dire peut se tromper sur un tiers des cartes.

    Un groupe écarté le dit. Deux motifs, qui n'appellent pas la même suite :
    trop peu d'impressions pour qu'une moyenne veuille dire quelque chose, ou
    un lot dont l'échantillon mêle les deux orientations. Les taire ferait
    passer un groupe non mesuré pour un groupe sans particularité.
    """
    _, prints = load_catalogue(probe)
    playable = [p for p in prints if not p.is_token and p.front_art and not p.is_foil]

    pools: dict[tuple[str, str], list[Print]] = defaultdict(list)
    for p in playable:
        pools[(p.type, p.treatment)].append(p)

    groups: dict[str, Group] = {}
    thin: list[str] = []
    mixed: list[str] = []
    for (kind, treatment), entries in sorted(pools.items()):
        name = f"{kind}/{treatment or 'Normal'}"
        if len(entries) < MIN_STACK:
            thin.append(f"{name} ({len(entries)})")
            continue
        laid = _orientation_of(probe, entries)
        if laid is None:
            mixed.append(f"{name} ({len(entries)})")
            continue
        groups[name] = Group(name=name, kind=kind, laid=laid, prints=entries)

    if thin:
        print(f"\n{len(thin)} groupes trop maigres pour être empilés "
              f"(moins de {MIN_STACK} impressions) : {', '.join(thin[:12])}"
              + (" …" if len(thin) > 12 else ""))
    if mixed:
        print(f"\n{len(mixed)} groupes dont l'échantillon MÊLE les deux "
              f"orientations, non mesurés : {', '.join(mixed)}")
    return groups


def _orientation_of(probe: Probe, entries: list[Print], sample: int = 5) -> bool | None:
    """Vraie si les rendus du lot sont couchés, `None` si le lot est mêlé.

    Un lot mêlé n'est pas un lot : empiler des cartes de deux orientations
    produirait une moyenne sans signification, et une fenêtre qui n'existe sur
    aucune carte.
    """
    laid: list[bool] = []
    for entry in entries[:: max(1, len(entries) // sample)][:sample]:
        try:
            with Image.open(probe.image(entry.front_art)) as img:
                laid.append(img.width > img.height)
        except Exception:
            continue
    if not laid or len(set(laid)) != 1:
        return None
    return laid[0]


def measure(probe: Probe, group: Group, size: int, dump: Path | None) -> None:
    """Mesure un groupe, et le contrôle sur un tirage disjoint."""
    tally: Counter = Counter()
    stack = build_stack(probe, group, size, tally=tally)
    if stack is None:
        print(f"\n### {group.name} — trop peu de rendus exploitables "
              f"({dict(tally)})")
        return

    window = derive(stack, group.probe_band, group.probe_x)
    print(f"\n### {group.name} — {stack.count} cartes empilées, "
          f"{len(group.prints)} au catalogue "
          f"({'couchée' if group.laid else 'debout'})")
    print(f"  fenêtre        {window.describe()}")
    print(f"  platitude int. {window.inside_flatness:.2f}")
    print(f"  relief arêtes  g {window.edge_relief[0]:.1f}  h {window.edge_relief[1]:.1f}"
          f"  d {window.edge_relief[2]:.1f}  b {window.edge_relief[3]:.1f}")
    print(f"  luminance      illustration {window.art_luminance:.0f}, "
          f"pavé de texte {window.outside_luminance:.0f}"
          + ("" if window.art_luminance < window.outside_luminance
             else "   <-- ATTENDU PLUS SOMBRE, controle en echec"))
    if group.probe_is_borrowed:
        print(f"  <-- type « {group.kind} » sans bande de sondage propre : "
              f"le repli a servi, la fenêtre est donc mesurée sous une bande "
              f"empruntée")
    if window.touches_border:
        print("  <-- une arête touche le bord du rendu : aucun trait ne l'a "
              "arrêtée, la fenêtre n'a pas été trouvée mais butée")
    for reason, n in tally.most_common():
        print(f"      {reason:<38} {n}")

    # Le contrôle sur tirage disjoint. C'est lui qui a démasqué, chez Pokémon,
    # que deux familles étaient mêlées : tant qu'elles l'étaient, l'arête haute
    # dérivait de 32 px d'un tirage à l'autre, et cette dérive était le seul
    # symptôme.
    control = build_stack(probe, group, size, offset=size)
    if control is not None:
        other = derive(control, group.probe_band, group.probe_x)
        drift = max(abs(a - b) for a, b in zip(window.pixels, other.pixels))
        print(f"  contrôle disjoint ({control.count} cartes) : "
              f"dérive {drift} px  {other.describe()}")

    # Ce que la fenêtre vaut en bits : mesurer où elle est dit où elle est ;
    # ceci dit si elle **sert**.
    hashes = crop_hashes(stack, window.box)
    mean_distance, tightest = separation(hashes)
    a, b, distance = tightest_pair(hashes, stack.ids)
    print(f"  séparation     {mean_distance:.1f} bits en moyenne, "
          f"paire la plus serrée {tightest}")
    if distance <= MAX_TRUSTED_DISTANCE:
        print(f"      <-- sous le seuil de confiance : {a} et {b} ({distance} bits)")

    if dump is not None:
        dump.mkdir(parents=True, exist_ok=True)
        stem = group.name.replace("/", "_")
        Image.fromarray(stack.mean.clip(0, 255).astype(np.uint8), "L").save(
            dump / f"{stem}_moyenne.png"
        )
        sharp = stack.sharpness
        scaled = (255 * sharp / max(sharp.max(), 1e-6)).clip(0, 255)
        Image.fromarray(scaled.astype(np.uint8), "L").save(dump / f"{stem}_gradient.png")
        print(f"  écrit dans {dump}")


def compare(probe: Probe, groups: dict[str, Group], size: int) -> None:
    """Éprouve chaque groupe sous la fenêtre de ses voisins de même type.

    **La question « un gabarit ou deux » se tranche en bits, pas en pixels.**
    C'est ainsi que Pokémon a conclu que ses quatre époques étaient
    interchangeables — la distance moyenne restait entre 31,1 et 32,3 bits sous
    n'importe laquelle des quatre — et qu'un second gabarit pour sa famille à
    fenêtre haute ne se justifiait pas, la fenêtre standard tenant entièrement
    dans son illustration.

    Le motif à éprouver ici est visible sur les fenêtres mesurées :
    `Hyperspace` partage les bornes verticales de `Normal` et s'étend pleine
    largeur. Si la fenêtre étroite fait aussi bien sur les deux, elle suffit —
    et un gabarit de moins est un gabarit de moins à essayer sur chaque photo.
    """
    print("\n=== un gabarit ou plusieurs, par type ===")
    by_kind: dict[str, list[Group]] = defaultdict(list)
    for group in groups.values():
        by_kind[group.kind].append(group)

    for kind, members in sorted(by_kind.items()):
        if len(members) < 2:
            continue
        print(f"\n--- {kind} ---")
        stacks: dict[str, Stack] = {}
        windows: dict[str, Window] = {}
        for group in members:
            stack = build_stack(probe, group, size)
            if stack is None:
                continue
            stacks[group.name] = stack
            windows[group.name] = derive(stack, group.probe_band, group.probe_x)

        header = "  " + " " * 26 + "".join(f"{n.split('/')[1][:11]:>13}" for n in windows)
        print(header)
        for name, stack in stacks.items():
            cells = []
            for other, window in windows.items():
                mean_distance, tightest = separation(crop_hashes(stack, window.box))
                mark = "*" if other == name else " "
                cells.append(f"{mean_distance:8.1f}/{tightest:<2}{mark}")
            print(f"  {name[:26]:<26}" + "".join(f"{c:>13}" for c in cells))
        print("  (moyenne / paire la plus serrée ; * = sa propre fenêtre)")


def run(size: int, only: str | None, dump: Path | None, want_compare: bool) -> None:
    probe = Probe(quiet=True)
    groups = build_groups(probe)
    print(f"\n{len(groups)} groupes assez fournis pour être mesurés")
    for name, group in sorted(groups.items()):
        laid = "couchée" if group.laid else "debout"
        print(f"  {name:<28} {len(group.prints):>5} impressions  {laid}")

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
    parser.add_argument("--group", default=None, help="ne mesurer que ce groupe")
    parser.add_argument("--dump", type=Path, default=None, help="dossier de sortie")
    parser.add_argument(
        "--compare",
        action="store_true",
        help="éprouver chaque groupe sous la fenêtre de ses voisins de même type",
    )
    args = parser.parse_args()
    run(args.size, args.group, args.dump, args.compare)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
