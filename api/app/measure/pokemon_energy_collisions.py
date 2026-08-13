"""Banc : ce que les énergies de base feraient à un index d'empreintes.

L'issue #28 pose que ces cartes « produisent une empreinte qui n'encode rien de
propre, donc des collisions massives ». C'est une intuition juste et une
affirmation non chiffrée — or le pipeline est mesuré à **zéro fausse carte
annoncée avec assurance** (`art_collisions`), et c'est ce résultat qu'on
protège. Une exclusion se justifie par un nombre, pas par une évidence.

**Une énergie de base n'a pas d'illustration.** Elle porte un grand symbole de
type sur un fond, et rien d'autre. Là où deux Pokémon diffèrent par leur
illustration, deux énergies du même type ne diffèrent que par l'habillage de
l'extension qui les réimprime — parfois par rien du tout.

Trois mesures, dans l'ordre de ce qu'elles coûteraient :

1. **Combien d'empreintes distinctes** les énergies de base produisent-elles ?
   Si 336 cartes se réduisent à une poignée de valeurs, l'index ne peut pas les
   départager, et toute réponse qu'il donnerait serait tirée au sort.
2. **Combien seraient annoncées avec assurance, et fausses ?** On rejoue la
   décision de `art_hash_index.dart` — distance sous le seuil, marge suffisante
   — et on compte les cas où le plus proche voisin est une *autre* carte.
3. **Que volent-elles aux cartes légitimes ?** Une énergie proche d'une vraie
   carte lui prend sa marge et la fait rejeter. Ce défaut-là coûte des refus,
   pas des erreurs, mais il se paie au même endroit.

Usage :
    cd api && .venv/Scripts/python -m app.measure.pokemon_energy_collisions
    #   --others N   cartes ordinaires de comparaison (défaut 300)
"""

from __future__ import annotations

import argparse
from collections import Counter

import numpy as np
from PIL import Image

from app.measure.art_collisions import MAX_TRUSTED_DISTANCE, MIN_CONFIDENCE_MARGIN
from app.measure.pokemon_art_window import (
    CARD_HEIGHT,
    CARD_WIDTH,
    Group,
    build_groups,
    load_plane,
)
from app.measure.tcgdex_probe import Probe
from app.vision.art_box import ArtBox, crop
from app.vision.dhash import dhash

#: La carte entière. Une énergie de base n'ayant pas de fenêtre d'illustration,
#: c'est le seul découpage qu'on puisse lui appliquer — et c'est exactement ce
#: que ferait un index qui les accueillerait sans y penser.
WHOLE_CARD = ArtBox(0.0, 0.0, 1.0, 1.0)


def fingerprints(probe: Probe, cards: list, box: ArtBox) -> list[tuple[str, int]]:
    """Empreinte de chaque carte, découpée selon [box].

    Le décompte des cartes écartées est affiché plutôt que tu : sans lui, un
    échantillon amputé par le réseau se lit comme un échantillon complet.
    """
    out: list[tuple[str, int]] = []
    tally: Counter[str] = Counter()
    for index, card in enumerate(cards, start=1):
        plane = load_plane(probe, card, tally)
        if plane is not None:
            image = Image.fromarray(plane.clip(0, 255).astype(np.uint8), mode="L")
            out.append((card.id, dhash(crop(image, box))))
        if index % 100 == 0:
            print(f"    {index}/{len(cards)}", flush=True)
    for reason, count in tally.most_common():
        if reason != "lue":
            print(f"    {count} ecartees : {reason}")
    return out


def distances(queries: np.ndarray, index: np.ndarray) -> np.ndarray:
    """Distances de Hamming entre chaque requête et tout l'index."""
    return np.bitwise_count(queries[:, None] ^ index[None, :]).astype(np.int16)


def report_distinct(prints: list[tuple[str, int]]) -> None:
    """1. Combien de valeurs différentes pour combien de cartes ?"""
    print("\n=== 1. l'index peut-il seulement les distinguer ? ===")
    values = Counter(h for _, h in prints)
    print(f"  {len(prints)} energies de base hachees")
    print(f"  {len(values)} empreintes distinctes")
    crowded = [(h, n) for h, n in values.most_common(5) if n > 1]
    for _, n in crowded:
        print(f"      une empreinte partagee par {n} cartes")
    duplicated = sum(n for _, n in values.items() if n > 1)
    print(f"  cartes dont l'empreinte est portee par au moins une autre : "
          f"{duplicated} ({100 * duplicated / max(len(prints), 1):.1f} %)")


def report_confusion(prints: list[tuple[str, int]]) -> None:
    """2. Combien seraient annoncées avec assurance, et fausses ?"""
    print("\n=== 2. ce que la reconnaissance en dirait ===")
    hashes = np.array([h & 0xFFFFFFFFFFFFFFFF for _, h in prints], dtype=np.uint64)
    block = distances(hashes, hashes)
    n = len(hashes)
    block[np.arange(n), np.arange(n)] = 127  # une carte n'est pas sa propre voisine

    two = np.partition(block, 1, axis=1)[:, :2]
    best, second = two[:, 0], two[:, 1]
    margin = second - best
    under = best <= MAX_TRUSTED_DISTANCE
    confident = under & (margin >= MIN_CONFIDENCE_MARGIN)

    print(f"  seuils rejoues : distance <= {MAX_TRUSTED_DISTANCE}, "
          f"marge >= {MIN_CONFIDENCE_MARGIN}")
    print(f"  une AUTRE energie sous le seuil       : {int(under.sum()):>4} "
          f"({100 * float(under.mean()):.1f} %)")
    print(f"  annoncee a tort et avec assurance     : {int(confident.sum()):>4} "
          f"({100 * float(confident.mean()):.1f} %)")
    print(f"  paire la plus serree : {int(block.min())} bits")


def report_theft(
    energies: list[tuple[str, int]], others: list[tuple[str, int]]
) -> None:
    """3. Que volent-elles aux cartes qui, elles, ont une illustration ?"""
    print("\n=== 3. ce qu'elles couteraient aux cartes legitimes ===")
    if not others:
        print("  pas de cartes de comparaison")
        return
    energy_hashes = np.array(
        [h & 0xFFFFFFFFFFFFFFFF for _, h in energies], dtype=np.uint64
    )
    other_hashes = np.array(
        [h & 0xFFFFFFFFFFFFFFFF for _, h in others], dtype=np.uint64
    )

    block = distances(other_hashes, energy_hashes)
    nearest = block.min(axis=1)
    print(f"  {len(others)} cartes ordinaires interrogees contre "
          f"{len(energies)} energies")
    print(f"  cartes dont une energie tombe sous le seuil : "
          f"{int((nearest <= MAX_TRUSTED_DISTANCE).sum())}")
    print(f"  cartes dont une energie tombe dans la marge : "
          f"{int((nearest < MAX_TRUSTED_DISTANCE + MIN_CONFIDENCE_MARGIN).sum())}")
    print(f"  energie la plus proche d'une carte ordinaire : {int(nearest.min())} bits")


def run(others_count: int) -> None:
    probe = Probe(quiet=True)
    groups = build_groups(probe, split_c_by_rarity=False)

    energies = Group(
        "energies",
        [c for name, g in groups.items() if name.startswith("D_energie") for c in g.cards],
    )
    print(f"{len(energies.cards)} energies de base au catalogue physique")
    energy_prints = fingerprints(probe, energies.cards, WHOLE_CARD)

    report_distinct(energy_prints)
    report_confusion(energy_prints)

    # Les cartes de comparaison sont hachées **entières elles aussi** : comparer
    # une énergie entière à une illustration découpée mesurerait l'écart entre
    # deux découpages, pas entre deux cartes.
    ordinary = Group(
        "ordinaires",
        [c for name, g in groups.items() if name.startswith("A_pokemon") for c in g.cards],
    )
    print(f"\n{len(ordinary.cards)} cartes ordinaires disponibles, "
          f"{others_count} tirees")
    other_prints = fingerprints(probe, ordinary.draw(others_count), WHOLE_CARD)
    report_theft(energy_prints, other_prints)


def main() -> int:
    parser = argparse.ArgumentParser(description="Collisions des energies Pokemon")
    parser.add_argument("--others", type=int, default=300)
    args = parser.parse_args()
    try:
        run(args.others)
    except KeyboardInterrupt:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
