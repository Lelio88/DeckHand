"""Banc : de quoi le catalogue Pokémon est-il fait, et par quel champ le dire.

**La question n'est pas « combien de cartes » mais « quel champ décide ».** Une
carte ne se scanne que si l'on sait où chercher son illustration, et Pokémon en
a plusieurs positions. Choisir le gabarit demande donc un discriminant — et un
discriminant tiré d'un vocabulaire mouvant est une heuristique déguisée. L'issue
#28 redoutait de devoir s'appuyer sur `rarity`, dont TCGdex compte **40 valeurs**
accumulées en 27 ans. Ce banc mesure ce que les champs *structurés* savent dire
à sa place, et ce qu'ils laissent dans l'ombre.

Quatre questions, dans l'ordre où elles bloquent la suite :

1. **Le périmètre.** Le vocabulaire de TCGdex mêle le jeu de carton et le jeu
   mobile *Pokémon TCG Pocket*, dont les cartes n'existent pas physiquement.
   Elles n'ont rien à faire dans un catalogue de collection.
2. **La règle du numéro.** `localId` comparé à `set.cardCount.official` sépare
   la carte encadrée de la carte pleine page. Vérifiée à l'œil sur trois sets
   par le relevé d'ouverture ; reste à savoir sur **combien de cartes elle
   s'applique**, ce qui est une autre question que celle de sa justesse.
3. **La famille à fenêtre haute** (`ex`, `V`, `VMAX`, `VSTAR`…) — le relevé la
   disait sans discriminant structuré. Ce banc mesure si `suffix` et `stage`,
   deux champs à vocabulaire fermé, la cernent, et ce que `rarity` en dirait.
4. **Les cartes sans illustration.** `category == "Energy"` était le
   discriminant pressenti ; il englobe les énergies spéciales, qui ont bel et
   bien une illustration. Mesuré ici sur le champ qui les sépare.

Aucune image n'est téléchargée : ce banc ne lit que de la structure. Les
fenêtres se mesurent dans `pokemon_art_window`.

Usage :
    cd api && .venv/Scripts/python -m app.measure.pokemon_taxonomy
"""

from __future__ import annotations

import sys
from collections import Counter
from dataclasses import dataclass

from app.measure.tcgdex_probe import Probe

#: Sous-familles à fenêtre haute. Deux champs, deux vocabulaires **fermés** —
#: `/suffixes` en publie 8, `/stages` en publie 10 — là où `/rarities` en publie
#: 40. Un vocabulaire fermé et publié par la source est un contrat ; une liste
#: de raretés qui s'allonge à chaque extension n'en est pas un.
#:
#: Le partage entre les deux champs ne suit aucune logique apparente : `ex`, `V`
#: et `GX` sont des suffixes, `VMAX`, `VSTAR` et `MEGA` sont des *stages*. C'est
#: la source qui en décide, et il faut lire les deux.
HIGH_WINDOW_SUFFIXES = ("EX", "GX", "Legend", "Prime", "SP", "TAG TEAM-GX", "V", "ex")
HIGH_WINDOW_STAGES = ("BREAK", "LEVEL-UP", "MEGA", "RESTORED", "V-UNION", "VMAX", "VSTAR")

#: Le jeu mobile. Une série entière, donc un filtre structuré et non une liste
#: de raretés à maintenir.
POCKET_SERIE = "tcgp"


@dataclass(frozen=True)
class Card:
    """Ce qu'il faut savoir d'une carte pour choisir son gabarit."""

    id: str
    local_id: str
    set_id: str
    serie: str
    official: int
    #: URL *de base* de l'image — la qualité et l'extension s'y accolent. Vide
    #: pour les quelques cartes dont la source ne publie aucun visuel.
    image_url: str

    @property
    def numbered(self) -> int | None:
        """Le numéro imprimé, ou `None` s'il n'est pas un nombre.

        Les promos et les galeries portent des `localId` comme `SWSH001`,
        `TG01` ou `XY-P` : la comparaison au décompte officiel n'a alors aucun
        sens, et la forcer donnerait une réponse fausse plutôt qu'une absence
        de réponse.
        """
        return int(self.local_id) if self.local_id.isdigit() else None


def load_catalogue(probe: Probe) -> list[Card]:
    """Toutes les cartes, avec le décompte officiel de leur set.

    Un appel par set — environ deux cents — plutôt qu'un par carte. La liste
    brève d'un set porte déjà l'identifiant et le numéro local de chacune de ses
    cartes, et l'enveloppe porte `cardCount.official` : c'est exactement le
    couple dont la règle du numéro a besoin.
    """
    sets = probe.json("sets")
    print(f"{len(sets)} sets au catalogue")

    cards: list[Card] = []
    for index, brief in enumerate(sets, start=1):
        detail = probe.json(f"sets/{brief['id']}")
        serie = detail.get("serie", {}).get("id", "?")
        official = int(detail.get("cardCount", {}).get("official") or 0)
        for card in detail.get("cards", []):
            cards.append(
                Card(
                    id=card["id"],
                    local_id=str(card.get("localId", "")),
                    set_id=brief["id"],
                    serie=serie,
                    official=official,
                    image_url=card.get("image", ""),
                )
            )
        if index % 50 == 0:
            print(f"  {index}/{len(sets)} sets, {len(cards)} cartes")
    return cards


def load_attribute(probe: Probe, field: str, values: tuple[str, ...]) -> dict[str, str]:
    """Table `identifiant de carte → valeur`, pour un champ et ses valeurs.

    Une requête filtrée par valeur, et non une lecture carte par carte : trente
    requêtes suffisent là où le catalogue en demanderait vingt-trois mille.
    """
    table: dict[str, str] = {}
    for value in values:
        for card in probe.json("cards", **{field: value}):
            table[card["id"]] = value
    return table


def report_scope(cards: list[Card]) -> list[Card]:
    """1. Le périmètre : ce qui existe sur carton, et ce qui n'existe que sur écran."""
    print("\n=== 1. périmètre : le jeu mobile n'est pas du carton ===")
    pocket = [c for c in cards if c.serie == POCKET_SERIE]
    physical = [c for c in cards if c.serie != POCKET_SERIE]
    pocket_sets = sorted({c.set_id for c in pocket})
    print(f"  catalogue entier          : {len(cards):>6} cartes")
    print(
        f"  série « {POCKET_SERIE} » (TCG Pocket)  : {len(pocket):>6} cartes "
        f"en {len(pocket_sets)} sets — {', '.join(pocket_sets)}"
    )
    print(f"  reste, sur carton         : {len(physical):>6} cartes")
    return physical


def report_rarity_pollution(
    physical: list[Card], pocket: list[Card], rarity: dict[str, str]
) -> None:
    """Le vocabulaire de rareté sépare-t-il les deux jeux, ou les mêle-t-il ?

    C'est la question qui décide **par quel champ** filtrer. Si une valeur de
    rareté sert des deux côtés, filtrer par rareté couperait du carton ou
    laisserait passer de l'écran ; la série, elle, est une propriété du set.
    """
    print("\n--- ce que la rareté dit du périmètre ---")
    # « None » est une valeur du vocabulaire publié par la source ; « (absente) »
    # dit que la carte n'apparaît dans aucune des 40 listes. Les confondre
    # ferait croire à un chevauchement là où il n'y en a pas, ou l'inverse.
    on_card = Counter(rarity.get(c.id, "(absente)") for c in physical)
    on_screen = Counter(rarity.get(c.id, "(absente)") for c in pocket)
    shared = sorted(set(on_card) & set(on_screen))
    screen_only = sorted(set(on_screen) - set(on_card))
    print(f"  valeurs vues sur carton seul : {len(set(on_card) - set(on_screen)):>3}")
    print(f"  valeurs vues sur écran seul  : {len(screen_only):>3}"
          f" — {', '.join(screen_only)}")
    print(f"  valeurs des deux côtés       : {len(shared):>3}"
          f" — {', '.join(shared)}")
    for value in shared:
        print(f"      {value:<24} {on_card[value]:>5} sur carton, "
              f"{on_screen[value]:>5} sur écran")


def report_number_rule(physical: list[Card]) -> tuple[list[Card], list[Card]]:
    """2. La règle du numéro : sur combien de cartes s'applique-t-elle ?"""
    print("\n=== 2. la règle du numéro : localId vs cardCount.official ===")
    unusable = [c for c in physical if c.numbered is None or c.official <= 0]
    usable = [c for c in physical if c.numbered is not None and c.official > 0]
    framed = [c for c in usable if c.numbered <= c.official]
    full = [c for c in usable if c.numbered > c.official]

    print(f"  applicable      : {len(usable):>6} cartes "
          f"({100 * len(usable) / len(physical):.1f} %)")
    print(f"      <= officiel  : {len(framed):>6} — encadrées (familles A, B, D)")
    print(f"      >  officiel  : {len(full):>6} — pleine carte (famille C)")
    print(f"  inapplicable    : {len(unusable):>6} cartes "
          f"({100 * len(unusable) / len(physical):.1f} %)")

    no_number = [c for c in unusable if c.numbered is None]
    no_official = [c for c in unusable if c.numbered is not None and c.official <= 0]
    print(f"      numéro non numérique : {len(no_number):>6} "
          f"— ex. {', '.join(c.local_id for c in no_number[:6])}")
    print(f"      set sans décompte    : {len(no_official):>6} "
          f"— ex. {', '.join(sorted({c.set_id for c in no_official})[:8])}")

    # Un huitième du catalogue mis de côté, ce n'est pas la même chose selon
    # qu'il s'agit d'une poignée de promos ou d'une famille visuelle entière.
    # La forme du numéro le dit : « 50a » est la carte 50 dans une variante,
    # « TG01 » est une galerie qui a sa propre mise en page.
    print("\n--- la forme des numéros que la règle ne sait pas lire ---")
    shapes = Counter(_shape(c.local_id) for c in no_number)
    for shape, n in shapes.most_common(6):
        sample = next(c.local_id for c in no_number if _shape(c.local_id) == shape)
        print(f"      {shape:<22} {n:>5}  ex. {sample}")
    recovered = [
        c for c in no_number
        if c.official > 0 and c.local_id[:-1].isdigit() and int(c.local_id[:-1]) <= c.official
    ]
    print(f"  dont récupérables en retirant une lettre finale : {len(recovered)}")
    return framed, full


def _shape(local_id: str) -> str:
    """Silhouette d'un numéro : chiffres, lettres et ponctuation, sans la valeur."""
    out: list[str] = []
    for char in local_id:
        kind = "9" if char.isdigit() else ("A" if char.isalpha() else char)
        if not out or out[-1] != kind:
            out.append(kind)
    return "".join(out)


def report_high_window(
    framed: list[Card],
    full: list[Card],
    suffix: dict[str, str],
    stage: dict[str, str],
    rarity: dict[str, str],
) -> None:
    """3. La famille à fenêtre haute a-t-elle un discriminant structuré ?

    Vérifiée **dans les deux sens**, ce qui est le seul contrôle qui ait du
    sens pour une règle de séparation : ce qu'elle réunit (toutes les cartes à
    fenêtre haute portent-elles bien la marque ?) et ce qu'elle sépare (la
    marque ne désigne-t-elle qu'elles ?). Une règle qui n'est vérifiée que dans
    un sens laisse passer la fusion silencieuse — celle qui a coûté #29.
    """
    print("\n=== 3. la famille à fenêtre haute : suffix ou stage ===")

    def marked(card: Card) -> str | None:
        return suffix.get(card.id) or stage.get(card.id)

    high = [c for c in framed if marked(c)]
    plain = [c for c in framed if not marked(c)]
    print(f"  encadrées marquées    : {len(high):>6} "
          f"({100 * len(high) / len(framed):.1f} % des encadrées)")
    print(f"  encadrées non marquées: {len(plain):>6}")

    counts = Counter(marked(c) for c in high)
    for value, n in counts.most_common():
        print(f"      {value:<14} {n:>5}")

    # Le sens inverse : la marque déborde-t-elle sur les pleines cartes ?
    # Si oui, elle ne peut pas servir seule — c'est le numéro qui doit trancher
    # d'abord, la marque ensuite.
    high_full = [c for c in full if marked(c)]
    print(f"  pleines cartes marquées : {len(high_full):>6} "
          f"({100 * len(high_full) / len(full):.1f} % des pleines cartes)"
          f" — la marque seule ne suffirait pas")

    print("\n--- ce que `rarity` en dirait, à la place ---")
    by_rarity: dict[str, list[int]] = {}
    for card in framed:
        slot = by_rarity.setdefault(rarity.get(card.id, "—"), [0, 0])
        slot[0 if marked(card) else 1] += 1
    mixed = {v: c for v, c in by_rarity.items() if c[0] and c[1]}
    pure_high = {v: c for v, c in by_rarity.items() if c[0] and not c[1]}
    print(f"  valeurs de rareté purement « fenêtre haute » : {len(pure_high):>3}")
    print(f"  valeurs de rareté mélangées                  : {len(mixed):>3}")
    for value, (h, p) in sorted(mixed.items(), key=lambda kv: -sum(kv[1]))[:10]:
        print(f"      {value:<24} {h:>5} marquées / {p:>5} non marquées")
    leaked = sum(h for h, _ in mixed.values())
    print(f"  cartes à fenêtre haute qu'une règle par rareté ne pourrait pas "
          f"isoler : {leaked}")


def report_energies(
    physical: list[Card], category: dict[str, str], energy_type: dict[str, str]
) -> None:
    """4. Les cartes sans illustration : quel champ les cerne exactement ?"""
    print("\n=== 4. les énergies : `category` est trop large ===")
    energies = [c for c in physical if category.get(c.id) == "Energy"]
    basic = [c for c in energies if energy_type.get(c.id) == "Normal"]
    special = [c for c in energies if energy_type.get(c.id) == "Special"]
    print(f"  category == Energy        : {len(energies):>6} cartes")
    print(f"      energyType == Normal  : {len(basic):>6} — énergies de base")
    print(f"      energyType == Special : {len(special):>6} — énergies spéciales, "
          f"qui ont une illustration")
    orphans = [c for c in energies if c.id not in energy_type]
    print(f"      sans energyType       : {len(orphans):>6}"
          + (f" — {', '.join(c.id for c in orphans[:4])}" if orphans else ""))
    print(f"  exclure sur `category` retirerait donc {len(special)} cartes "
          f"illustrées de l'index, à tort.")


def run() -> None:
    probe = Probe()
    cards = load_catalogue(probe)

    print("\nlecture des champs structurés (une requête par valeur)")
    rarity = load_attribute(probe, "rarity", tuple(probe.json("rarities")))
    suffix = load_attribute(probe, "suffix", HIGH_WINDOW_SUFFIXES)
    stage = load_attribute(probe, "stage", HIGH_WINDOW_STAGES)
    category = load_attribute(probe, "category", ("Energy", "Pokemon", "Trainer"))
    energy_type = load_attribute(probe, "energyType", ("Normal", "Special"))

    pocket = [c for c in cards if c.serie == POCKET_SERIE]
    physical = report_scope(cards)
    report_rarity_pollution(physical, pocket, rarity)
    framed, full = report_number_rule(physical)
    report_high_window(framed, full, suffix, stage, rarity)
    report_energies(physical, category, energy_type)

    print(f"\n{probe.requests} requêtes émises (le reste venait du cache)")


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
