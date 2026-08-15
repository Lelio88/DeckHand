"""Banc : où se trouve l'illustration sur une carte Wankul.

**Trois mises en page, et aucune n'est la rotation d'une autre.** La verticale
porte une illustration **encadrée** — un rectangle cerné de noir, surmonté d'un
bandeau à icônes et suivi d'un pavé de texte. Les deux couchées, les Terrains,
portent la leur **en plein cadre**, les textes posés par-dessus, avec le bloc
titre + bandeaux tantôt en haut, tantôt en bas. Mesurer l'une ne dit rien des
autres, et c'est pourquoi ce banc les sépare.

**La méthode est celle qui a rendu Pokémon** : ce qui survit à la moyenne, c'est
ce qui ne bouge pas — donc les traits du cadre. Le gradient de l'image moyenne
monte sur les arêtes communes à toutes les cartes et reste plat là où chacune
dessine autre chose.

**Deux mesures, et elles se contrôlent l'une l'autre.** Le gradient de la
moyenne donne un gabarit ; la **variance entre cartes** dit où l'illustration
est libre. Un gabarit sans contrôle croisé serait une moyenne dont on ne saurait
pas si elle décrit quelque chose — c'est la leçon du gabarit de deck, où l'écart
interquartile vaut autant que la médiane. Sur les Terrains, les deux tombent à
une ligne près (0,4150 contre 0,4167).

**Ce que le mode Terrain corrige, et qu'il ne faut pas reperdre.** Une mesure
précédente avait vu deux jeux de bandeaux symétriques dans l'image moyenne et en
avait conclu que le lot mêlait les deux sens de rotation ; un demi-tour
conditionnel avait été ajouté au redressement. C'était l'inverse : les deux jeux
de bandeaux venaient des deux **maquettes**, et le demi-tour conditionnel
introduisait le résidu qu'il croyait supprimer. Le redressement est
inconditionnel (`wankul_frame.upright`), et le classement se fait après.

**Le banc mesure ce que l'index hache, et pas une seconde fois la même chose.**
Le chargement des fichiers, le redressement et le classement viennent de
`local_index` et `wankul_frame`. Une mesure obtenue par un autre chemin que le
calcul qu'elle sert ne prouverait rien de ce calcul.

Usage :
    cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier>
    cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier> --dump
    cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier> --terrains
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import psycopg
from PIL import Image

from app.config import SupabaseConfig
from app.vision.art_box import WANKUL_BANDS_BOTTOM, WANKUL_BANDS_TOP
from app.vision.local_index import files_by_illustration, load_card
from app.vision.wankul_frame import BANDS_BOTTOM, BANDS_TOP, maquette, upright

#: Taille commune à laquelle les cartes sont ramenées avant d'être moyennées.
#: Assez grande pour que le trait du cadre reste net, assez petite pour que la
#: moyenne de quelques dizaines de cartes tienne en mémoire.
NORM = (600, 840)

@dataclass(frozen=True)
class Window:
    left: float
    top: float
    right: float
    bottom: float

    def __str__(self) -> str:
        return (f"({self.left:.4f}, {self.top:.4f}, "
                f"{self.right:.4f}, {self.bottom:.4f})")


def pixels(path: Path) -> np.ndarray | None:
    """La carte en tableau, marges transparentes retirées.

    Le rognage vient de `local_index.load_card` — celui que le constructeur
    d'index applique — et non d'une seconde implémentation : mesurer sur un
    cadrage que le calcul n'emploierait pas ne prouverait rien de ce calcul.
    """
    try:
        with load_card(path) as image:
            return np.asarray(image).astype(np.float32)
    except OSError:
        return None


def normalized(card: np.ndarray) -> np.ndarray:
    """La carte ramenée à [NORM], en niveaux de gris."""
    img = Image.fromarray(card.astype(np.uint8)).resize(NORM, Image.LANCZOS)
    a = np.asarray(img).astype(np.float32)
    return a @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def window_from_gradient(mean: np.ndarray) -> Window:
    """Les arêtes du cadre, lues sur le gradient de l'image moyenne."""
    gy = np.abs(np.diff(mean, axis=0)).mean(axis=1)
    gx = np.abs(np.diff(mean, axis=1)).mean(axis=0)
    h, w = mean.shape

    def crete(profil: np.ndarray, debut: float, fin: float) -> int:
        """Position du plus fort gradient dans une plage."""
        a, b = int(len(profil) * debut), int(len(profil) * fin)
        return a + int(np.argmax(profil[a:b]))

    # Le haut de la fenêtre est sous le bandeau à icônes ; le bas est le trait
    # qui la sépare du pavé de texte. Les plages évitent les bords de carte,
    # dont le gradient est le plus fort de l'image et masquerait le reste.
    top = crete(gy, 0.03, 0.25)
    bottom = crete(gy, 0.55, 0.80)
    left = crete(gx, 0.02, 0.20)
    right = crete(gx, 0.80, 0.98)
    return Window(left / w, top / h, right / w, bottom / h)


def per_card_bottom(card: np.ndarray) -> float | None:
    """Où commence le pavé de texte sur *cette* carte.

    Contrôle indépendant du gradient : le pavé est un aplat clair et peu
    saturé, l'illustration ne l'est jamais sur toute une ligne.
    """
    g = normalized(card)
    h, w = g.shape
    bande = g[:, int(w * 0.20):int(w * 0.80)]
    med = np.median(bande, axis=1)
    bas = [y for y in range(int(h * 0.5), h) if med[y] > 175]
    return min(bas) / h if bas else None


#: Taille de travail des Terrains, en paysage. Le rapport suit celui du carton
#: (63 × 88 mm couché) plutôt que celui des rendus, qui varient de 430 × 600 à
#: 435 × 600 selon l'extension.
NORM_PAYSAGE = (840, 600)


def _paysage(image: Image.Image) -> np.ndarray:
    array = np.asarray(image.convert("RGB").resize(NORM_PAYSAGE, Image.LANCZOS))
    return array.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)


def _cretes(profil: np.ndarray, n: int = 8, ecart: float = 0.02) -> list[int]:
    """Les `n` plus fortes crêtes, séparées d'au moins `ecart` de la dimension.

    Sans cette séparation, les huit crêtes retenues seraient les huit pixels du
    même trait : un trait est épais de deux ou trois lignes après réduction.
    """
    gardees: list[int] = []
    for i in np.argsort(profil)[::-1]:
        if all(abs(i - j) > len(profil) * ecart for j in gardees):
            gardees.append(int(i))
        if len(gardees) == n:
            break
    return sorted(gardees)


def _plage_libre(profil: np.ndarray) -> tuple[float, float]:
    """La plus longue plage où les cartes **diffèrent** — donc l'illustration.

    Contrôle indépendant du gradient : le gradient dit où sont les traits du
    cadre, la variance dit où il n'y en a pas. Deux signaux qui se
    contrediraient vaudraient un avertissement, pas un gabarit.
    """
    seuil = (profil.max() + profil.min()) / 2
    meilleure, debut, longueur = (0, 0), None, 0
    for i, forte in enumerate(list(profil > seuil) + [False]):
        if forte and debut is None:
            debut = i
        elif not forte and debut is not None:
            if i - debut > longueur:
                meilleure, longueur = (debut, i), i - debut
            debut = None
    return meilleure[0] / len(profil), meilleure[1] / len(profil)


def mesure_terrains(dossier: Path) -> int:
    """Les deux gabarits couchés, mesurés sur les Terrains que la base connaît.

    La liste vient de la base — `cards.layout = 'horizontal'`, que l'ingestion
    déduit de la présence d'un rendu paysage — et non d'une heuristique d'image :
    elle est exacte, là où le classement à l'œil laissait passer un faux positif
    sur cent cinquante.
    """
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn, conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT p.illustration_id, c.name
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'wankul' AND c.layout = 'horizontal'
              AND p.illustration_id IS NOT NULL
            ORDER BY p.set_code, p.collector_number
            """
        ).fetchall()

    fichiers = files_by_illustration(dossier)
    groupes: dict[str, list[np.ndarray]] = {}
    serres: list[tuple[float, str]] = []
    absents = 0
    for illustration, nom in rows:
        chemin = fichiers.get(illustration)
        if chemin is None:
            absents += 1
            continue
        with load_card(chemin) as image:
            droite = upright(image)
            verdict = maquette(droite)
            groupes.setdefault(verdict.layout, []).append(_paysage(droite))
            serres.append((verdict.ratio, nom))

    print(f"\nTerrains en base : {len(rows)}   absents du dossier : {absents}")
    if absents:
        print("  (le dossier ne porte que les rendus principaux ; un manque ici "
              "signifie un fichier qui n'a pas été téléchargé)")

    attendus = {
        "horizontal-bandeaux-haut": WANKUL_BANDS_TOP,
        "horizontal-bandeaux-bas": WANKUL_BANDS_BOTTOM,
    }
    bandeaux = {
        "horizontal-bandeaux-haut": BANDS_TOP,
        "horizontal-bandeaux-bas": BANDS_BOTTOM,
    }
    for layout, lot in sorted(groupes.items()):
        pile = np.stack(lot)
        mean = pile.mean(axis=0)
        sd = pile.std(axis=0)
        h, w = mean.shape
        gy = np.abs(np.diff(mean, axis=0)).mean(axis=1)
        gx = np.abs(np.diff(mean, axis=1)).mean(axis=0)

        print(f"\n=== maquette « {layout} » — {len(lot)} cartes ===")
        print("  arêtes horizontales :", "  ".join(
            f"{y / h:.4f}({gy[y]:.0f})" for y in _cretes(gy)))
        print("  arêtes verticales   :", "  ".join(
            f"{x / w:.4f}({gx[x]:.0f})" for x in _cretes(gx)))
        y0, y1 = _plage_libre(sd.mean(axis=1))
        print(f"  plage libre (variance entre cartes) : y {y0:.4f} .. {y1:.4f}")
        print(f"  bandeaux attendus : "
              f"{' '.join(f'{b:.4f}' for b in bandeaux[layout])}")

        box = attendus[layout]
        # Le contrôle : l'arête que le gradient donne et celle que la variance
        # ouvre doivent tomber au même endroit, et le gabarit écrit dessus.
        bord = box.top if layout.endswith("haut") else box.bottom
        proche = y0 if layout.endswith("haut") else y1
        ecart = abs(bord - proche)
        verdict = "concordent" if ecart < 0.005 else "DIVERGENT"
        print(f"  gabarit écrit : {box}")
        print(f"  écart gradient / variance : {ecart:.4f} — les deux {verdict}")

    serres.sort()
    print("\nmaquettes décidées de justesse (rapport des deux scores) :")
    for ratio, nom in serres[:6]:
        print(f"  x{ratio:.2f}  {nom}")
    return 0


def chemins(dossier: Path, layout: str) -> list[tuple[Path, str]]:
    """Les rendus d'une maquette donnée, désignés par la base.

    **La base sait ce qu'un dossier ne peut pas dire.** Un Terrain est stocké
    debout : ses proportions sont celles d'une carte verticale, et le filtrer
    par sa taille laisserait 146 cartes couchées polluer la moyenne des debout —
    en silence, la moyenne restant une image plausible.
    """
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn, conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT p.illustration_id, c.name
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'wankul' AND c.layout = %s
              AND p.illustration_id IS NOT NULL
            ORDER BY p.set_code, p.collector_number
            """,
            (layout,),
        ).fetchall()
    fichiers = files_by_illustration(dossier)
    return [(fichiers[i], nom) for i, nom in rows if i in fichiers]


def mesure_verticales(dossier: Path, dump: bool) -> int:
    """Le gabarit des Personnages — les cartes debout, 812 sur 958."""
    cartes: list[tuple[Path, np.ndarray]] = []
    for chemin, _nom in chemins(dossier, "vertical"):
        card = pixels(chemin)
        if card is None:
            print(f"  {chemin.name}: illisible, ignorée")
            continue
        cartes.append((chemin, card))

    if not cartes:
        print(f"aucune carte verticale retrouvée dans {dossier}", file=sys.stderr)
        return 1

    print(f"\ncartes verticales retenues : {len(cartes)}")
    r = np.array([c.shape[1] / c.shape[0] for _, c in cartes])
    print(f"rapport : médiane {np.median(r):.4f}  min {r.min():.4f}  "
          f"max {r.max():.4f}   (63/88 = {63/88:.4f})")

    pile = np.stack([normalized(c) for _, c in cartes])
    mean = pile.mean(axis=0)
    fenetre = window_from_gradient(mean)
    print(f"\n=== fenêtre lue sur le gradient de la moyenne ===\n  {fenetre}")

    bas = [b for b in (per_card_bottom(c) for _, c in cartes) if b is not None]
    if bas:
        b = np.array(bas)
        print(f"\ncontrôle croisé — début du pavé de texte, carte par carte :")
        print(f"  médiane {np.median(b):.4f}   écart interquartile "
              f"{np.percentile(b, 75) - np.percentile(b, 25):.4f}"
              f"   min {b.min():.4f}  max {b.max():.4f}")
        ecart = abs(np.median(b) - fenetre.bottom)
        verdict = "concordent" if ecart < 0.02 else "DIVERGENT"
        print(f"  écart avec le gradient : {ecart:.4f} — les deux {verdict}")

    if dump:
        sortie = dossier / "moyenne.png"
        Image.fromarray(mean.astype(np.uint8)).save(sortie)
        print(f"\nimage moyenne écrite : {sortie}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage : python -m app.measure.wankul_art_window <dossier> "
              "[--dump] [--terrains] [--verticales]", file=sys.stderr)
        return 64
    dossier = Path(sys.argv[1])
    terrains = "--terrains" in sys.argv
    verticales = "--verticales" in sys.argv
    code = 0
    if verticales or not terrains:
        code |= mesure_verticales(dossier, "--dump" in sys.argv)
    if terrains or not verticales:
        code |= mesure_terrains(dossier)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
