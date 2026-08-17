"""Où se trouve l'illustration sur une carte Lorcana, et si un cadre suffit.

**La méthode est celle de Pokémon, reprise mot pour mot.** On empile des cartes
alignées, on regarde le gradient de leur image moyenne : l'illustration diffère
d'une carte à l'autre et s'aplatit, le cadre est identique partout et survit.
Les primitives numériques sont importées, non recopiées — `quiet_run`,
`_relief`, `separation`, `tightest_pair` et `Stack` vivent dans
`pokemon_art_window`.

**Deux questions, et la seconde décide seule.**

1. *Où est la fenêtre ?* Le gradient la donne, et deux tirages **disjoints** la
   confirment : une fenêtre qui bouge d'un lot à l'autre décrit l'échantillon,
   pas la maquette.
2. *Combien en faut-il ?* `--compare` éprouve chaque type sous la fenêtre de
   chacun des autres. Si toutes les paires restent au-dessus du seuil de
   confiance, **un seul cadre suffit** — c'est la conclusion de Pokémon sur ses
   quatre époques et de One Piece sur ses quatre types. SWU est le contre-exemple
   : ses cinq types ont chacun le sien.

**Ce jeu a une particularité qu'aucun autre n'avait.** Les 106 Lieux sont
imprimés **en travers**, et la source le déclare deux fois — par son champ
`layout` valant `landscape`, et par son type valant `Location`. Les deux
ensembles sont identiques carte par carte, vérifié au banc de taxonomie. Ils sont
donc mesurés à part, comme les Terrains de Wankul et les Leaders de SWU : une
carte couchée n'a pas la même fenêtre qu'une carte debout, et les empiler
mêlerait deux maquettes.

**Les rendus sont en AVIF**, ce qu'aucune autre source ne sert. Pillow les ouvre
nativement (vérifié : `features.check("avif")` rend vrai), et le décodage est
sans perte visible à l'échelle où l'empreinte travaille.

Usage :
    cd api && .venv/Scripts/python -m app.measure.lorcana_art_window
    #   --group <type>  ne mesure qu'un type
    #   --compare       éprouve chaque type sous la fenêtre des autres
    #   --dump <dir>    écrit l'image moyenne et son gradient, pour les REGARDER
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import numpy as np
from PIL import Image

from app.measure.art_collisions import MAX_TRUSTED_DISTANCE
from app.ingestion.lorcast_ingest import identity_key
from app.measure.lorcast_probe import USER_AGENT, Probe
from app.measure.pokemon_art_window import (
    Stack,
    _relief,
    quiet_run,
    separation,
    tightest_pair,
)
from app.vision.art_box import ArtBox, crop
from app.vision.dhash import _to_grey, dhash

#: Taille commune à laquelle tout rendu est ramené.
#:
#: La source publie 488 × 681 en `normal` — 0,7166, à un millième du carton
#: (0,7159). On garde ce format plutôt que d'agrandir : agrandir n'ajoute aucune
#: information et coûte du temps sur trois mille images.
CANONICAL = (488, 681)

#: Les couchées, tournées d'un quart de tour pour être empilées ensemble.
CANONICAL_LANDSCAPE = (681, 488)

MIN_LONG_SIDE = 300
MIN_STACK = 12

#: Bande verticale certainement illustrée, d'où part la recherche des colonnes.
PROBE_BAND = (0.15, 0.35)
PROBE_X = 0.50

#: Idem pour les couchées, dont la mise en page diffère.
PROBE_BAND_LANDSCAPE = (0.20, 0.45)

CACHE = Path(__file__).resolve().parents[2] / ".cache" / "lorcana_images"


@dataclass(frozen=True)
class Entry:
    """Une carte, réduite à ce que le banc en regarde."""

    source_id: str
    name: str
    type: str
    layout: str
    image: str
    #: La clé d'identité de la **carte**, par-delà ses rééditions.
    #:
    #: Elle sert à juger une collision : deux empreintes à 1 bit sont un défaut
    #: si elles désignent deux cartes différentes, et **bénignes** si elles
    #: désignent deux tirages d'une même carte — se tromper entre eux ne change
    #: alors ni le nom, ni les règles, ni le deck. Un banc qui rend le nombre
    #: sans cette distinction laisse le doute, et le doute fait chercher un
    #: défaut là où il n'y en a pas.
    identity: str = ""

    @property
    def landscape(self) -> bool:
        return self.layout == "landscape"


def load(probe: Probe) -> list[Entry]:
    """Le catalogue, réduit aux cartes qui publient un rendu."""
    out: list[Entry] = []
    for row in probe.all_cards():
        images = (row.get("image_uris") or {}).get("digital") or {}
        url = images.get("normal") or images.get("large") or ""
        if not url:
            continue
        out.append(
            Entry(
                source_id=str(row.get("id") or ""),
                name=str(row.get("name") or ""),
                type=(row.get("type") or ["Unknown"])[0],
                layout=str(row.get("layout") or "normal"),
                image=url,
                identity=identity_key(row),
            )
        )
    return out


def fetch_image(url: str) -> Path | None:
    """Le rendu sur disque, téléchargé une seule fois."""
    CACHE.mkdir(parents=True, exist_ok=True)
    name = hashlib.md5(url.encode()).hexdigest() + ".avif"
    path = CACHE / name
    if path.exists():
        return path
    try:
        with httpx.Client(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            response = client.get(url)
            response.raise_for_status()
            path.write_bytes(response.content)
        return path
    except Exception:
        return None


def load_plane(entry: Entry, tally: Counter | None = None) -> np.ndarray | None:
    """Une carte en niveaux de gris, ramenée à sa taille commune, ou `None`.

    **Une carte écartée doit dire pourquoi.** « 30 empreintes pour 40 cartes »
    se lit comme un gabarit mesuré si l'on ne sait pas que dix rendus étaient
    des vignettes — ou, tout autrement, que le réseau a lâché.
    """

    def note(reason: str) -> None:
        if tally is not None:
            tally[reason] += 1

    path = fetch_image(entry.image)
    if path is None:
        note("telechargement echoue")
        return None

    try:
        with Image.open(path) as raw:
            if max(raw.size) < MIN_LONG_SIDE:
                note("vignette, trop petite pour etre agrandie")
                return None
            flat = Image.new("RGB", raw.size, (255, 255, 255))
            flat.paste(
                raw, mask=raw.getchannel("A") if raw.mode == "RGBA" else None
            )
            if entry.landscape:
                # **Le rendu est publié DEBOUT, contenu tourné.** Les 106 Lieux
                # sortent en 488 × 681 comme toutes les autres cartes, mais leur
                # texte s'y lit de bas en haut : c'est une carte physiquement
                # couchée, mise dans un cadre portrait.
                #
                # Une première version l'a redimensionnée en 681 × 488 — donc
                # ÉCRASÉE, sans tourner —, et le banc a rendu une paire à **1
                # bit** sur quarante cartes. Le nombre disait « ces cartes sont
                # indiscernables » là où il fallait lire « l'image est déformée ».
                # C'est le piège Wankul, où `orientation` ne disait pas non plus
                # comment la carte est imprimée : **l'orientation se vérifie sur
                # l'image, jamais sur un champ.**
                #
                # Un quart de tour **horaire** la redresse — texte horizontal,
                # illustration en haut —, c'est-à-dire la carte telle qu'elle est
                # posée sur la table, et donc telle que l'appareil la photographie.
                # Même sens que les Terrains de Wankul.
                flat = flat.rotate(-90, expand=True)
            cible = CANONICAL_LANDSCAPE if entry.landscape else CANONICAL
            if flat.size != cible:
                # LANCZOS plutôt qu'un filtre net : on réduit presque toujours,
                # et un filtre net y crée du crénelage — de fausses arêtes,
                # exactement ce que le banc cherche.
                flat = flat.resize(cible, Image.LANCZOS)
                note("redimensionnee")
            else:
                note("lue telle quelle")
            return _to_grey(flat).astype(np.float32)
    except Exception:
        note("rendu illisible")
        return None


@dataclass(frozen=True)
class Group:
    """Un lot d'entrées censées partager une mise en page."""

    name: str
    entries: list[Entry]

    @property
    def landscape(self) -> bool:
        return bool(self.entries) and self.entries[0].landscape

    def draw(self, size: int, offset: int = 0) -> list[Entry]:
        """Tirage stable : même groupe, même taille, mêmes cartes.

        Le tri par empreinte de l'identifiant tient lieu de hasard. Un tirage
        aléatoire à chaque exécution rendrait deux mesures incomparables, et
        l'écart entre deux lots se confondrait avec l'écart entre deux méthodes.

        [offset] sert le tirage de contrôle : décaler de la taille d'un lot donne
        un second échantillon **disjoint**, seule façon de savoir si la fenêtre
        décrit le gabarit ou l'échantillon.
        """
        ordered = sorted(
            self.entries, key=lambda e: hashlib.md5(e.source_id.encode()).digest()
        )
        return ordered[offset : offset + size]


def build_groups(entries: list[Entry]) -> dict[str, Group]:
    """Un groupe par type, les couchées à part.

    Les Lieux sont isolés **parce qu'ils sont imprimés en travers**, non parce
    qu'ils sont des Lieux : c'est l'orientation qui interdit de les empiler avec
    le reste, une carte couchée et une carte debout n'ayant pas la même
    géométrie.
    """
    par_type: dict[str, list[Entry]] = defaultdict(list)
    for entry in entries:
        par_type[entry.type].append(entry)
    return {nom: Group(nom, lot) for nom, lot in par_type.items() if len(lot) >= MIN_STACK}


def build_stack(
    group: Group, size: int, offset: int = 0, tally: Counter | None = None
) -> Stack | None:
    read = [
        (e, plane)
        for e in group.draw(size, offset)
        if (plane := load_plane(e, tally)) is not None
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
        # L'identité de la **carte**, non celle du tirage : deux tirages d'une
        # même carte y portent la même chaîne, et une collision entre eux se
        # reconnaît d'un coup d'œil.
        ids=[e.identity for e, _ in read],
    )


@dataclass(frozen=True)
class Window:
    """Une fenêtre mesurée, et de quoi juger si elle vaut quelque chose."""

    box: ArtBox
    pixels: tuple[int, int, int, int]
    inside_flatness: float
    edge_relief: tuple[float, float, float, float]
    touches_border: bool

    def describe(self) -> str:
        left, top, right, bottom = self.pixels
        return (
            f"({self.box.left:.4f} {self.box.top:.4f} "
            f"{self.box.right:.4f} {self.box.bottom:.4f})"
            f"  px [{left}, {top}, {right}, {bottom}]"
        )


def derive(stack: Stack, *, landscape: bool) -> Window:
    """La fenêtre d'illustration, et les preuves qui vont avec.

    Les colonnes d'abord, sondées sur une bande certainement illustrée ; puis les
    lignes, sondées entre les colonnes que l'on vient de fixer. L'inverse ferait
    entrer le pavé de texte, pleine largeur, dans le profil des colonnes.
    """
    height, width = stack.mean.shape
    sharp = stack.sharpness
    bande = PROBE_BAND_LANDSCAPE if landscape else PROBE_BAND
    probe_top = int(bande[0] * height)
    probe_bottom = int(bande[1] * height)

    col_profile = sharp[probe_top:probe_bottom, :].mean(axis=0)
    quarter, three_quarters = width // 4, 3 * width // 4
    col_background = float(np.median(col_profile[quarter:three_quarters]))
    start = min(max(int(PROBE_X * width), 0), width - 1)
    left, right = quiet_run(col_profile, start, start, col_background)

    row_profile = sharp[:, left : right + 1].mean(axis=1)
    row_background = float(np.median(row_profile[probe_top:probe_bottom]))
    top, bottom = quiet_run(row_profile, probe_top, probe_bottom, row_background)

    inside = sharp[top : bottom + 1, left : right + 1]
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
        image = Image.fromarray(plane.astype(np.uint8), mode="L").convert("RGB")
        hashes.append(dhash(crop(image, box)))
    return hashes


def measure(group: Group, size: int, dump: Path | None) -> None:
    tally: Counter = Counter()
    stack = build_stack(group, size, tally=tally)
    if stack is None:
        print(f"  {group.name:12} pas assez de rendus lisibles ({dict(tally)})")
        return

    window = derive(stack, landscape=group.landscape)
    print(f"  {group.name:12} {stack.count:3} cartes  {window.describe()}")
    print(f"      relief des arêtes  {tuple(round(v, 2) for v in window.edge_relief)}")
    print(f"      platitude interne  {window.inside_flatness:.2f}")
    if window.touches_border:
        print("      ! une arête bute sur le bord du rendu — non trouvée, butée")

    hashes = crop_hashes(stack, window.box)
    # **Les identifiants, pas seulement le nombre.** Une paire à 0 bit peut être
    # deux cartes distinctes que la reconnaissance confondrait, ou la même carte
    # rééditée sous deux identifiants — seuls les noms permettent de trancher.
    moyenne, _ = separation(hashes)
    gauche, droite, serree = tightest_pair(hashes, stack.ids)
    print(f"      séparation  moyenne {moyenne:.1f} bits, paire la plus serrée {serree}")
    if serree <= MAX_TRUSTED_DISTANCE:
        if gauche == droite:
            # Deux tirages d'une même carte. Se tromper entre eux ne change ni
            # le nom, ni les règles, ni le deck — seulement le prix affiché.
            print(
                f"      (paire serrée bénigne : deux tirages de « "
                f"{gauche.split('|')[0]} »)"
            )
        else:
            print(
                f"      ! sous le seuil de confiance ({MAX_TRUSTED_DISTANCE}) : "
                f"« {gauche.split('|')[0]} » / « {droite.split('|')[0]} »"
            )

    # **Le contrôle qui décide.** Un second lot, disjoint du premier : si la
    # fenêtre bouge, elle décrit l'échantillon et non la maquette.
    controle = build_stack(group, size, offset=size)
    if controle is not None:
        autre = derive(controle, landscape=group.landscape)
        derive_px = max(
            abs(a - b) for a, b in zip(window.pixels, autre.pixels)
        )
        print(f"      tirage disjoint    {autre.describe()}")
        print(f"      dérive maximale    {derive_px} px")
    else:
        print("      (pas de second lot disjoint : groupe trop petit)")

    if dump is not None:
        dump.mkdir(parents=True, exist_ok=True)
        Image.fromarray(stack.mean.astype(np.uint8), mode="L").save(
            dump / f"{group.name}_moyenne.png"
        )
        crete = stack.sharpness
        echelle = 255.0 / max(float(crete.max()), 1.0)
        Image.fromarray((crete * echelle).astype(np.uint8), mode="L").save(
            dump / f"{group.name}_gradient.png"
        )
        print(f"      écrit dans {dump}")


def compare(groups: dict[str, Group], size: int) -> None:
    """Chaque type sous la fenêtre de chacun des autres.

    **C'est la mesure qui décide du nombre de cadres.** Si toutes les paires
    restent au-dessus du seuil de confiance, un seul suffit — et le garder tous
    coûterait du temps de calcul pour rien, chaque cadre essayé étant une
    empreinte de plus à comparer.
    """
    stacks: dict[str, Stack] = {}
    fenetres: dict[str, ArtBox] = {}
    for nom, group in groups.items():
        stack = build_stack(group, size)
        if stack is None:
            continue
        stacks[nom] = stack
        fenetres[nom] = derive(stack, landscape=group.landscape).box

    print()
    print("  chaque type sous la fenêtre de chacun (paire la plus serrée, bits) :")
    entete = "  " + " " * 14 + "".join(f"{n[:10]:>12}" for n in fenetres)
    print(entete)
    for nom, stack in stacks.items():
        ligne = f"  {nom:12}  "
        for autre in fenetres:
            # Une fenêtre mesurée sur des cartes couchées n'a aucun sens
            # appliquée à des cartes debout : les proportions diffèrent, et le
            # découpage tomberait n'importe où. On ne compare que le comparable.
            if groups[nom].landscape != groups[autre].landscape:
                ligne += f"{'—':>12}"
                continue
            _, _, paire = tightest_pair(
                crop_hashes(stack, fenetres[autre]), stack.ids
            )
            marque = "*" if nom == autre else " "
            ligne += f"{str(paire) + marque:>12}"
        print(ligne)
    print(f"  (seuil de confiance : {MAX_TRUSTED_DISTANCE} bits ; * = sa propre fenêtre)")


def run(size: int, only: str | None, dump: Path | None, want_compare: bool) -> None:
    with Probe(quiet=True) as probe:
        entries = load(probe)
    groups = build_groups(entries)
    print(f"{len(entries)} cartes, {len(groups)} types d'au moins {MIN_STACK} cartes")
    for nom, group in sorted(groups.items(), key=lambda kv: -len(kv[1].entries)):
        couche = " (couché)" if group.landscape else ""
        print(f"  {nom:12} {len(group.entries):5}{couche}")
    print()

    if want_compare:
        compare({k: v for k, v in groups.items() if only in (None, k)}, size)
        return

    for nom, group in sorted(groups.items(), key=lambda kv: -len(kv[1].entries)):
        if only is not None and nom != only:
            continue
        measure(group, size, dump)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=40)
    parser.add_argument("--group", default=None)
    parser.add_argument("--dump", type=Path, default=None)
    parser.add_argument("--compare", action="store_true")
    args = parser.parse_args()
    run(args.size, args.group, args.dump, args.compare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
