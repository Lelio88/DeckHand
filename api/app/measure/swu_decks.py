"""Banc : de quoi un deck Star Wars Unlimited est-il fait, et que promet le corpus.

**Un gabarit de deck se mesure sur un corpus, jamais sur les règles du jeu.**
C'est ce qui a fait rendre `null` à `DeckBlueprint.of` pour Riftbound tant que
rien n'était mesuré, et c'est ce qui a démasqué, chez Yu-Gi-Oh, que deux quotas
sur cinq étaient introuvables et qu'un filtrage par « couleur » écartait 32 %
du catalogue sur une règle inexistante. Le même travail se fait ici avant
qu'une ligne n'entre en base.

Cinq questions, dans l'ordre où elles bloquent la suite :

1. **Le volume et la profondeur.** Combien de listes, sur quelle fenêtre, et
   le corpus tient-il sur la durée ou seulement sur les dernières semaines ?
2. **Les zones.** La source en publie quatre — `Leader`, `Base`, `MainDeck`,
   `Sideboard`. Lesquelles comptent dans la complétion ? Riftbound a tranché
   le précédent : tout sauf la réserve, parce qu'on ne joue pas sans ses runes.
3. **Le gabarit.** Taille du deck principal, dispersion, et proportions par
   type. C'est ce qui décide si le constructeur peut viser quelque chose ou
   doit se taire.
4. **La résolution.** Les listes citent un nom, pas un code d'impression —
   contrairement à Riftbound et Pokémon. Le catalogue ne compte qu'un titre
   ambigu sur 2 180, ce qui devrait suffire ; reste à le vérifier sur les
   citations réelles, qui sont ce que la reconnaissance devra rapprocher.
5. **Les aspects contraignent-ils la construction ?** La question n'est pas
   rhétorique et elle décide de `usesColorIdentity`. Yu-Gi-Oh a montré qu'un
   champ qui *ressemble* à une identité de couleur peut n'imposer aucune
   contrainte ; SWU, lui, pénalise le hors-aspect sans l'interdire. Seul le
   corpus dit ce que les joueurs en font.

**Ce banc n'écrit rien en base.**

Usage :
    cd api && .venv/Scripts/python -m app.measure.swu_decks
    #   --days N     profondeur de la fenêtre (défaut 120)
    #   --limit N    plafond de decklists lues (défaut 600)
"""

from __future__ import annotations

import argparse
import datetime as dt
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Any

from app.measure.swu_probe import Probe, ProbeError
from app.measure.swumetastats_probe import PAGE_SIZE, PAUSE_SECONDS, DeckProbe

#: Les zones que la source publie. `Sideboard` est la seule qui ne compte pas
#: dans la complétion : on peut jouer le deck sans elle, exactement comme pour
#: Magic et Riftbound. Les trois autres désignent des cartes qu'il faut
#: posséder — un deck sans sa base ne se pose pas sur la table.
MAIN_ZONES = ("Leader", "Base", "MainDeck")
SIDE_ZONE = "Sideboard"

#: Séparateur entre le nom et le sous-titre, dans les citations de decklist.
#: Le catalogue publie les deux champs séparément ; les recoller est ce qui
#: rend la résolution exacte plutôt qu'approximative.
TITLE_SEPARATOR = " | "


def aspects_of(value: Any) -> set[str]:
    """Les aspects déclarés par une carte, un leader ou une base.

    La source les publie en une chaîne — « Cunning, Heroism ». Une carte qui
    n'en déclare aucun est jouable partout sans pénalité : rendre l'ensemble
    vide plutôt qu'un aspect fictif est ce qui évite de la compter « hors
    aspect » et de relâcher artificiellement la contrainte mesurée.
    """
    raw = (value or {}).get("aspect") or ""
    return {a.strip() for a in raw.split(",") if a.strip()}


#: Ponctuation typographique repliée sur son équivalent droit. Les deux sources
#: ne s'accordent pas : les listes citent « Benthic “Two Tubes” » et « Mesa
#: Propose… » là où le catalogue publie des guillemets droits et pas d'ellipse.
#: C'est le même désaccord que Riftbound, qui mêlait apostrophes droites et
#: typographiques d'une extension à l'autre.
PUNCTUATION = {
    "“": '"', "”": '"',   # guillemets courbes
    "‘": "'", "’": "'",   # apostrophes courbes
    "…": "",                    # points de suspension
    "–": "-", "—": "-",   # tirets demi-cadratin et cadratin
}


def normalise(title: str) -> str:
    """Forme comparable d'un titre : minuscules, ponctuation repliée, espaces réduits.

    **La casse seule coûtait 7 % des citations.** Les listes écrivent « Hold
    for Questioning » et « Black One | Straight at Them » là où le catalogue
    publie « Hold For Questioning » et « Straight At Them ». Rien ne signalait
    l'écart : ces cartes étaient simplement comptées introuvables, et le corpus
    aurait paru inutilisable.

    **Une normalisation ne produit pas que des retrouvailles, elle produit
    aussi de faux couples**, et c'est le danger qu'aucun écran ne détrompe —
    la leçon des extensions Pokémon, où réduire « Base Set » à une clé vide
    appariait la première édition de 1999 avec celle de 2017. `load_titles`
    vérifie donc qu'aucune paire de cartes distinctes ne se rejoint ici.
    """
    folded = "".join(PUNCTUATION.get(c, c) for c in title)
    return " ".join(folded.lower().split())


@dataclass(frozen=True)
class TitleIndex:
    """Le catalogue, indexé des deux façons dont les decklists le citent.

    **Deux formes coexistent dans les listes, et il a fallu les mesurer.** Une
    unité y est citée sous son titre entier — « Black One | Straight At Them » —
    tandis qu'une base l'est sous son seul nom : « Data Vault » quand le
    catalogue publie le nom « Data Vault » et le sous-titre « Scarif ».

    Retomber sur le nom seul est donc nécessaire, mais **pas inconditionnel** :
    « Black One » désigne deux cartes réellement différentes. Un repli aveugle
    en choisirait une au hasard et écrirait un deck faux sans que rien ne le
    signale — le défaut exact que le rapprochement des extensions Pokémon a
    évité en faisant de la date un veto plutôt qu'un critère. Le nom seul ne
    tranche donc que lorsqu'il ne désigne qu'une carte.
    """

    by_full: dict[str, str]
    by_name: dict[str, set[str]]

    def resolve(self, cited: str) -> tuple[str | None, str]:
        """La carte désignée, et par quelle voie — ou pourquoi elle échoue."""
        key = normalise(cited)
        if key in self.by_full:
            return self.by_full[key], "titre entier"
        candidates = self.by_name.get(key)
        if candidates and len(candidates) == 1:
            return next(iter(candidates)), "nom seul"
        if candidates:
            return None, "ambigu"
        return None, "introuvable"


def load_titles(probe: Probe) -> TitleIndex:
    """Indexe le catalogue par titre entier et par nom.

    La clé du titre entier est `Nom | Sous-titre` — la forme exacte qu'emploient
    les decklists —, reconstruite depuis les deux champs que la source publie
    séparément.
    """
    by_full: dict[str, str] = {}
    by_name: dict[str, set[str]] = defaultdict(set)
    merged: dict[str, set[str]] = defaultdict(set)
    for entry in probe.sets():
        code = entry.get("setId") or ""
        if not code:
            continue
        try:
            rows = probe.cards(code)
        except ProbeError:
            continue
        for row in rows:
            name = row.get("Name") or ""
            subtitle = row.get("Subtitle") or ""
            full = f"{name}{TITLE_SEPARATOR}{subtitle}" if subtitle else name
            key = normalise(full)
            by_full[key] = full
            merged[key].add(full)
            by_name[normalise(name)].add(full)

    # Le contrôle qui manque d'ordinaire : la normalisation a-t-elle réuni deux
    # titres réellement différents ? Un seul cas suffirait à écrire des cartes
    # sur le mauvais deck, en silence.
    #
    # Toutes les réunions ne sont pas des fautes, et les confondre ferait crier
    # au loup : quand deux titres ne diffèrent **que** par ce que la
    # normalisation cible — la casse, la ponctuation —, c'est la source qui
    # s'écrit de deux façons, et les réunir est précisément le but. Mesuré :
    # « Prepare For Takeoff » et « Prepare for Takeoff » sont la même carte.
    # Une réunion de titres qui diffèrent autrement, elle, est une faute.
    benign, real = [], []
    for values in (v for v in merged.values() if len(v) > 1):
        stripped = {"".join(c for c in v.lower() if c.isalnum()) for v in values}
        (benign if len(stripped) == 1 else real).append(sorted(values))
    if benign:
        print(f"  la normalisation réunit {len(benign)} titres que la source "
              f"écrit de deux façons — c'est son objet")
        for values in benign[:3]:
            print(f"      {values}")
    if real:
        print(f"  ATTENTION : elle réunit aussi {len(real)} paires de titres "
              f"RÉELLEMENT différents")
        for values in real[:5]:
            print(f"      {values}")

    return TitleIndex(by_full=by_full, by_name=dict(by_name))


def report_volume(
    decks: list[dict[str, Any]], declared: int, days: int, probe: DeckProbe
) -> None:
    """1. Le volume, la profondeur de l'historique, et ce que coûterait le tout."""
    print(f"\n=== 1. volume, sur une fenêtre de {days} jours ===")
    print(f"  déclaré par la source (`totalCount`) : {declared:>6}")
    print(f"  effectivement lues                   : {len(decks):>6}")
    print(f"  identifiants distincts               : {len({d['id'] for d in decks}):>6}")

    # Le débit est un résultat, pas une statistique d'agrément : il décide si
    # l'ingestion se compte en minutes ou en heures, donc quelle fenêtre le
    # connecteur pourra couvrir. Riftbound et Yu-Gi-Oh rendent leur corpus en
    # une poignée de requêtes ; ici chaque page de vingt listes est un
    # aller-retour, et elle pèse un quart de mégaoctet.
    if probe.requests:
        per_page = probe.seconds / probe.requests
        pages = -(-declared // PAGE_SIZE)
        hours = pages * (per_page + PAUSE_SECONDS) / 3600
        print(f"\n  débit : {probe.requests} pages en {probe.seconds:.0f} s "
              f"réseau, soit {per_page:.1f} s par page de {PAGE_SIZE}")
        print(f"  couvrir les {declared} listes demanderait {pages} pages, "
              f"soit environ {hours:.1f} h")

    dates = sorted(
        (d.get("tournament") or {}).get("startDate") or "" for d in decks
    )
    dates = [x[:10] for x in dates if x]
    if dates:
        # Pas de flèche ni d'autre caractère hors cp1252 dans une sortie de
        # banc : la console Windows plante à l'encodage, et le banc meurt sur
        # une ligne d'affichage après avoir fait tout son travail.
        print(f"  fenêtre réelle : {dates[0]} au {dates[-1]}")
    by_month = Counter(x[:7] for x in dates)
    for month, n in sorted(by_month.items()):
        print(f"      {month}  {n:>5}")

    tournaments = {d.get("tournamentId") for d in decks}
    print(f"  tournois représentés : {len(tournaments)}")


def report_zones(decks: list[dict[str, Any]]) -> None:
    """2. Les zones : ce qu'elles contiennent, et ce qu'elles pèsent."""
    print("\n=== 2. zones ===")
    per_zone: dict[str, list[int]] = defaultdict(list)
    for deck in decks:
        counts: Counter[str] = Counter()
        for row in deck.get("cards") or []:
            counts[row.get("section") or "?"] += int(row.get("count") or 0)
        for zone in set(counts) | {*MAIN_ZONES, SIDE_ZONE}:
            per_zone[zone].append(counts.get(zone, 0))

    for zone, sizes in sorted(per_zone.items()):
        present = [s for s in sizes if s]
        if not present:
            print(f"  {zone:<12} absente de toutes les listes")
            continue
        print(f"  {zone:<12} médiane {statistics.median(present):>5.0f} cartes, "
              f"présente dans {len(present)}/{len(sizes)} listes")

    # Ce que la réserve coûterait si on la comptait — le chiffre qui justifie
    # de l'exclure plutôt qu'un principe.
    with_side = statistics.median(
        [sum(int(r.get("count") or 0) for r in (d.get("cards") or []))
         for d in decks]
    )
    without = statistics.median(
        [sum(int(r.get("count") or 0) for r in (d.get("cards") or [])
             if r.get("section") in MAIN_ZONES)
         for d in decks]
    )
    print(f"\n  médiane toutes zones : {with_side:.0f} cartes")
    print(f"  médiane sans réserve : {without:.0f} cartes — c'est ce que la "
          f"complétion doit viser")


def report_blueprint(decks: list[dict[str, Any]]) -> None:
    """3. Le gabarit : taille, dispersion, et proportions par type."""
    print("\n=== 3. gabarit ===")
    sizes = [
        sum(int(r.get("count") or 0) for r in (d.get("cards") or [])
            if r.get("section") == "MainDeck")
        for d in decks
    ]
    sizes = [s for s in sizes if s]
    quartiles = statistics.quantiles(sizes, n=4) if len(sizes) > 3 else [0, 0, 0]
    print(f"  deck principal : médiane {statistics.median(sizes):.0f}, "
          f"écart interquartile {quartiles[2] - quartiles[0]:.1f}, "
          f"étendue {min(sizes)}–{max(sizes)}")
    for size, n in Counter(sizes).most_common(8):
        print(f"      {size:>3} cartes : {n:>4} listes")

    # Les proportions, comme `deck_anatomy` les mesure pour les autres jeux.
    # Le type est imprimé sur la carte, donc le rôle n'a pas à être deviné au
    # texte comme il l'est pour Magic.
    shares: dict[str, list[float]] = defaultdict(list)
    for deck, total in zip(decks, sizes):
        if not total:
            continue
        counts: Counter[str] = Counter()
        for row in deck.get("cards") or []:
            if row.get("section") != "MainDeck":
                continue
            kind = ((row.get("card") or {}).get("type")) or "?"
            counts[kind] += int(row.get("count") or 0)
        for kind, n in counts.items():
            shares[kind].append(100 * n / total)

    print("\n  part de chaque type dans le deck principal :")
    for kind, values in sorted(shares.items(), key=lambda kv: -statistics.median(kv[1])):
        q = statistics.quantiles(values, n=4) if len(values) > 3 else [0, 0, 0]
        print(f"      {kind:<10} {statistics.median(values):>5.1f} % "
              f"(écart {q[2] - q[0]:>4.1f}, présent dans {len(values)}/{len(sizes)})")

    # Le maximum d'exemplaires : un contrat du jeu, à vérifier plutôt qu'à lire.
    copies = Counter()
    for deck in decks:
        for row in deck.get("cards") or []:
            if row.get("section") == "MainDeck":
                copies[int(row.get("count") or 0)] += 1
    print(f"\n  exemplaires par carte : "
          f"{', '.join(f'{k}×{v}' for k, v in sorted(copies.items()))}")


def report_resolution(decks: list[dict[str, Any]], index: TitleIndex) -> None:
    """4. La résolution : les citations retombent-elles sur le catalogue ?"""
    print("\n=== 4. résolution des citations contre le catalogue ===")
    cited: Counter[str] = Counter()
    for deck in decks:
        for row in deck.get("cards") or []:
            cited[row.get("cardName") or ""] += 1

    routes: Counter[str] = Counter()
    failures: dict[str, tuple[str, int]] = {}
    for name, n in cited.items():
        resolved, route = index.resolve(name)
        routes[route] += n
        if resolved is None:
            failures[name] = (route, n)

    total = sum(cited.values())
    print(f"  citations              : {total:>6}")
    print(f"  titres distincts cités : {len(cited):>6}")
    for route, n in routes.most_common():
        print(f"      par {route:<14} {n:>6} citations ({100 * n / total:.2f} %)")

    if failures:
        print("\n  ce qui ne se résout pas :")
        for name, (route, n) in sorted(failures.items(), key=lambda kv: -kv[1][1])[:10]:
            print(f"      {route:<12} {name[:44]:<46} {n:>4} citations")

    # Combien de decks seraient enregistrés amputés ? C'est la question qui
    # compte : une carte perdue dans une liste par ailleurs complète ferait
    # annoncer un deck plus constructible qu'il n'est — le pire défaut possible
    # pour ce produit, et celui qui a coûté 93 decks à Yu-Gi-Oh.
    hurt = sum(
        1 for d in decks
        if any(
            index.resolve(r.get("cardName") or "")[0] is None
            for r in (d.get("cards") or [])
        )
    )
    print(f"\n  decks touchés par au moins une carte non résolue : {hurt} / {len(decks)}")


def report_aspects(decks: list[dict[str, Any]]) -> None:
    """5. Les aspects contraignent-ils la construction ?

    En SWU, jouer une carte hors des aspects du leader et de la base n'est pas
    interdit : cela coûte deux ressources de plus. C'est donc au corpus, et à
    lui seul, de dire si le pool d'un deck peut être filtré par aspect — la
    question que Yu-Gi-Oh a tranchée par la négative après avoir mesuré qu'un
    tel filtre y écartait 32 % du catalogue sur une règle inexistante.
    """
    print("\n=== 5. les aspects contraignent-ils le pool ? ===")
    off_shares: list[float] = []
    fully_inside = 0
    for deck in decks:
        allowed = aspects_of(deck.get("leaderCard")) | aspects_of(deck.get("baseCard"))
        if not allowed:
            continue
        inside = outside = 0
        for row in deck.get("cards") or []:
            if row.get("section") != "MainDeck":
                continue
            n = int(row.get("count") or 0)
            card_aspects = aspects_of(row.get("card"))
            # Une carte sans aspect est jouable partout : elle ne compte ni
            # pour ni contre la contrainte.
            if not card_aspects:
                continue
            if card_aspects <= allowed:
                inside += n
            else:
                outside += n
        if inside + outside == 0:
            continue
        share = 100 * outside / (inside + outside)
        off_shares.append(share)
        if outside == 0:
            fully_inside += 1

    if not off_shares:
        print("  aucun deck exploitable")
        return
    print(f"  decks mesurés                    : {len(off_shares)}")
    print(f"  entièrement dans leurs aspects   : {fully_inside} "
          f"({100 * fully_inside / len(off_shares):.1f} %)")
    print(f"  part hors aspect, médiane        : {statistics.median(off_shares):.1f} %")
    q = statistics.quantiles(off_shares, n=4) if len(off_shares) > 3 else [0, 0, 0]
    print(f"  écart interquartile              : {q[2] - q[0]:.1f} points")
    print(f"  pire deck                        : {max(off_shares):.1f} % hors aspect")


def run(days: int, limit: int) -> None:
    end = dt.date.today()
    start = end - dt.timedelta(days=days)
    probe = DeckProbe()
    declared = probe.count(start.isoformat(), end.isoformat())
    print(f"{declared} decklists déclarées entre {start} et {end}")

    decks = list(probe.decklists(start.isoformat(), end.isoformat(), limit=limit))
    if not decks:
        sys.exit("aucune decklist lue — la fenêtre est peut-être vide")

    report_volume(decks, declared, days, probe)
    report_zones(decks)
    report_blueprint(decks)

    print("\nlecture du catalogue pour la résolution…")
    report_resolution(decks, load_titles(Probe(quiet=True)))
    report_aspects(decks)
    print(f"\n{probe.requests} requêtes émises (le reste venait du cache)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=120, help="profondeur (défaut 120)")
    parser.add_argument("--limit", type=int, default=600, help="plafond (défaut 600)")
    args = parser.parse_args()
    run(args.days, args.limit)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
