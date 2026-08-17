"""Anatomie des decks du corpus : de quoi un deck est-il fait, par format ?

**Pourquoi cette mesure existe.** Un constructeur automatique doit décider
combien de terrains, de créatures, de sources de mana ou de cartes de retrait
mettre dans un deck. Ces nombres peuvent s'inventer — c'est ce que fait la
sagesse populaire, « trente-sept terrains en Commander » — ou se lire dans mille
decks réels. Le corpus est déjà là ; le deviner serait absurde.

**Ce que la dispersion décide.** Si les decks d'un format se ressemblent, les
quotas s'imposent d'eux-mêmes et le constructeur n'a plus qu'à les remplir. S'ils
sont trop dispersés, une médiane ne veut rien dire et il faudra une autre voie —
par exemple s'appuyer sur le deck le plus proche des couleurs disponibles plutôt
que sur une statistique globale. C'est pourquoi ce module rend des quartiles et
non des moyennes : l'écart est le résultat, autant que la valeur centrale.

**Les rôles sont reconnus par motifs de texte**, faute de mieux. Aucun catalogue
ne dit qu'une carte « sert de retrait » ; le texte oracle, lui, dit « Destroy
target ». C'est grossier — une carte peut détruire *et* piocher, un motif rate
les tournures inhabituelles — mais c'est la méthode qu'emploient les outils
communautaires, et elle suffit à empêcher un deck sans retrait ni pioche. Les
comptes qui suivent ne sont donc pas des vérités mais des ordres de grandeur, ce
que le constructeur cherche précisément.

**Les traits sont une propriété du jeu, pas du module.** Yu-Gi-Oh n'a ni
terrain, ni coût de mana, ni créature : ses axes sont Monstre / Magie / Piège, et
son deck se scinde en zones — Main, Extra, Side — que Magic ne connaît pas.
Mesurer un jeu avec les traits d'un autre rendrait des zéros partout, ce qui se
lit comme une absence et non comme une inadéquation. C'est la même leçon que le
format d'une carte (#24) : ce qui dépend du jeu doit être paramétré par le jeu.

Usage :
    python -m app.measure.deck_anatomy                     # Magic
    python -m app.measure.deck_anatomy --game yugioh
    python -m app.measure.deck_anatomy --format commander
"""

from __future__ import annotations

import argparse
import statistics
from dataclasses import dataclass, field

import psycopg

from app.config import SupabaseConfig

#: Les cartes d'Extra Deck, reconnues à leur type.
#:
#: **Le corpus ne les distingue pas.** TopDeck.gg ne publie qu'un `main` et un
#: `side` ; les quinze cartes de l'Extra Deck arrivent donc mêlées au deck
#: principal, et une taille lue naïvement sur ce board vaut 55 — un nombre qui
#: ne correspond à aucune zone réelle. Les séparer ici est la condition pour que
#: la mesure décrive un deck qui existe.
YUGIOH_EXTRA = (
    "c.type_line ILIKE '%Fusion Monster%' "
    "OR c.type_line ILIKE '%Synchro Monster%' "
    "OR c.type_line ILIKE '%Xyz Monster%' "
    "OR c.type_line ILIKE '%Link Monster%'"
)


@dataclass(frozen=True)
class GameAnatomy:
    """Ce qu'il faut savoir d'un jeu pour décrire ses decks."""

    formats: tuple[str, ...]

    #: Ce qui forme le corps du deck, et sert de dénominateur aux parts.
    body: str

    #: Traits dont on mesure la part, en pourcentage du corps.
    traits: dict[str, str]

    #: Paliers de coût, et le champ sur lequel les lire.
    curve: tuple[tuple[int, int], ...]
    curve_label: str
    curve_scope: str

    #: Zones comptées en **cartes** et non en parts : leur taille est le
    #: résultat, pas leur proportion.
    zones: dict[str, str] = field(default_factory=dict)

    #: Sur quelles cartes compter les exemplaires d'une même carte.
    #:
    #: **Les terrains de base sont illimités**, et les inclure rend la mesure
    #: absurde : elle annonce « maximum 32 exemplaires » en Commander, où la
    #: règle en autorise un — ce sont des Forêts. Un plafond qui se lit comme une
    #: infraction alors qu'il décrit une exception est pire qu'une absence de
    #: mesure.
    copies_scope: str = "TRUE"


MAGIC = GameAnatomy(
    formats=("commander", "pauper", "modern"),
    body="TRUE",
    traits={
        "terrains": "c.type_line LIKE '%Land%'",
        "terrains de base": "c.type_line LIKE 'Basic Land%'",
        "terrains spéciaux": "c.type_line LIKE '%Land%' AND c.type_line NOT LIKE 'Basic Land%'",
        "créatures": "c.type_line LIKE '%Creature%'",
        "éphémères et rituels": "c.type_line LIKE '%Instant%' OR c.type_line LIKE '%Sorcery%'",
        # Produire du mana ou aller chercher un terrain : dans les deux cas, la
        # carte sert à accélérer, ce que le constructeur doit doser.
        "rampe": (
            "c.type_line NOT LIKE '%Land%' AND ("
            "c.oracle_text ILIKE '%add {%' "
            "OR c.oracle_text ILIKE '%search your library for a%land%')"
        ),
        "retrait": (
            "c.oracle_text ILIKE '%destroy target%' "
            "OR c.oracle_text ILIKE '%exile target%' "
            "OR c.oracle_text ILIKE '%deals % damage to target%'"
        ),
        "pioche": "c.oracle_text ILIKE '%draw % card%'",
    },
    # Sur les seules cartes non-terrain : un terrain coûte zéro et écraserait la
    # distribution.
    curve=((0, 1), (2, 2), (3, 3), (4, 4), (5, 6), (7, 99)),
    curve_label="coût",
    curve_scope="c.type_line NOT LIKE '%Land%'",
    copies_scope="c.type_line NOT LIKE 'Basic Land%'",
)

YUGIOH = GameAnatomy(
    formats=("edison", "goat", "redu", "hat"),
    # Le deck principal seul : l'Extra Deck est une autre zone, comptée à part.
    body=f"NOT ({YUGIOH_EXTRA})",
    traits={
        "monstres": f"c.type_line ILIKE '%Monster%' AND NOT ({YUGIOH_EXTRA})",
        "magies": "c.type_line ILIKE '%Spell Card%'",
        "pièges": "c.type_line ILIKE '%Trap Card%'",
        # Les deux familles de pièges que tout deck dose : le piège continu, qui
        # reste en jeu, et le contre-piège, qui répond.
        "pièges continus": "c.type_line ILIKE '%Continuous Trap%'",
        "magies rapides": "c.type_line ILIKE '%Quick-Play Spell%'",
    },
    # **Le Niveau, non le coût de mana.** L'ingestion range le Niveau dans `cmc`
    # faute d'un champ dédié ; les paliers ci-dessous sont ceux du jeu, où l'on
    # invoque sans tribut jusqu'au niveau 4, avec un tribut à 5 et 6, avec deux
    # au-delà. C'est le seul découpage qui décrive une contrainte réelle.
    curve=((1, 4), (5, 6), (7, 99)),
    curve_label="niveau",
    curve_scope=f"c.type_line ILIKE '%Monster%' AND NOT ({YUGIOH_EXTRA})",
    zones={
        "deck principal": f"NOT ({YUGIOH_EXTRA})",
        "extra deck": YUGIOH_EXTRA,
    },
)

#: Énergie de base — celle qu'on prend dans la boîte, comme un terrain de base.
#:
#: `layout` porte la famille rangée par l'ingestion (#28) ; `energy` désigne
#: l'énergie de base, `special-energy` celle qui a une illustration et un texte.
POKEMON_BASIC_ENERGY = "c.layout = 'energy'"

POKEMON = GameAnatomy(
    # Choisis par volume mesuré : Standard porte 99,5 % du corpus importé.
    formats=("standard", "glc", "ex", "expanded"),
    body="TRUE",
    traits={
        # **Les trois familles sont LA décision de construction de ce jeu.** Un
        # deck Pokémon n'a ni terrains ni courbe de mana : il dose des Pokémon,
        # des cartes Dresseur et des Énergies, et c'est tout ce qu'il dose.
        "pokémon": "c.type_line LIKE 'Pokemon%'",
        "dresseurs": "c.type_line LIKE 'Trainer%'",
        "énergies": "c.type_line LIKE 'Energy%'",
        # Les sous-familles Dresseur, que les règles distinguent : un Supporter
        # par tour, un Stadium en jeu, les Objets sans limite.
        "supporters": "c.type_line LIKE 'Trainer — Supporter%'",
        "objets": "c.type_line LIKE 'Trainer — Item%'",
        "stades": "c.type_line LIKE 'Trainer — Stadium%'",
        "outils": "c.type_line LIKE 'Trainer — Tool%'",
        "énergies de base": POKEMON_BASIC_ENERGY,
        "énergies spéciales": "c.layout = 'special-energy'",
    },
    # **Aucune courbe.** `cmc` porte ici les points de vie — 70, 60, 80 sont les
    # valeurs les plus fréquentes — et non un coût. Découper les PV en paliers
    # décrirait la robustesse des créatures, pas une contrainte de construction :
    # ce serait le même contresens que de lire le Niveau de Yu-Gi-Oh comme un
    # coût de mana, avec l'aggravation qu'ici rien ne se paie.
    curve=(),
    curve_label="pv",
    curve_scope="TRUE",
    # **L'énergie de base est illimitée**, comme le terrain de base à Magic : la
    # compter ferait annoncer un plafond de vingt exemplaires là où la règle en
    # autorise quatre. Un plafond qui se lit comme une infraction alors qu'il
    # décrit une exception est pire qu'une absence de mesure.
    copies_scope=f"NOT ({POKEMON_BASIC_ENERGY})",
)

#: One Piece — trois familles, un coût réel, aucun terrain.
#:
#: **Le leader est hors du dosage**, et c'est structurel : il occupe
#: `decks.commander_oracle_id`, un exemplaire par deck, jamais dans les
#: cinquante cartes. Le doser reviendrait à mesurer la proportion d'une carte
#: dont il y a toujours exactement une.
ONEPIECE = GameAnatomy(
    formats=("op_standard",),
    body="TRUE",
    traits={
        "personnages": "c.type_line LIKE 'Character%'",
        "événements": "c.type_line LIKE 'Event%'",
        "décors": "c.type_line LIKE 'Stage%'",
    },
    # **Un vrai coût de mise en jeu**, contrairement à Pokémon dont le `cmc`
    # porte les points de vie et à Yu-Gi-Oh dont il porte le Niveau. Ici c'est
    # le coût en DON!!, qu'on paie chaque tour, et la courbe décrit donc bien
    # une contrainte de construction.
    curve=((0, 1), (2, 2), (3, 3), (4, 4), (5, 6), (7, 99)),
    curve_label="DON!!",
    curve_scope="TRUE",
    copies_scope="TRUE",
)

#: Disney Lorcana — cinq familles, un coût en encre, deux encres au plus.
LORCANA = GameAnatomy(
    formats=("lorcana_core",),
    body="TRUE",
    traits={
        "personnages": "c.type_line LIKE 'Character%'",
        "actions": "c.type_line LIKE 'Action%'",
        "objets": "c.type_line LIKE 'Item%'",
        # **Sous-famille, pas famille.** Une Chanson EST une Action — sa ligne
        # de type vaut « Action Song » — et elle s'ajoute au dosage au lieu de
        # le découper, comme le Supporter s'ajoute au Dresseur chez Pokémon.
        # `LIKE 'Song%'` n'aurait jamais rien trouvé.
        "chansons": "c.type_line LIKE '%Song%'",
        "lieux": "c.type_line LIKE 'Location%'",
    },
    curve=((0, 1), (2, 2), (3, 3), (4, 4), (5, 6), (7, 99)),
    curve_label="encre",
    curve_scope="TRUE",
    copies_scope="TRUE",
)

GAMES = {
    "magic": MAGIC,
    "yugioh": YUGIOH,
    "pokemon": POKEMON,
    "onepiece": ONEPIECE,
    "lorcana": LORCANA,
}


@dataclass
class Spread:
    """Ce qu'on retient d'une mesure : sa valeur centrale et son étalement."""

    label: str
    values: list[float]
    unit: str = "%"

    @property
    def median(self) -> float:
        return statistics.median(self.values) if self.values else 0.0

    def quantile(self, q: float) -> float:
        if not self.values:
            return 0.0
        ordered = sorted(self.values)
        return ordered[min(len(ordered) - 1, int(q * len(ordered)))]

    @property
    def spread(self) -> float:
        """Écart interquartile."""
        return self.quantile(0.75) - self.quantile(0.25)

    def line(self) -> str:
        verdict = "serré" if self.spread <= 6 else "large" if self.spread <= 14 else "dispersé"
        return (
            f"  {self.label:22} médiane {self.median:5.1f}   "
            f"quartiles {self.quantile(0.25):5.1f} – {self.quantile(0.75):5.1f}   "
            f"écart {self.spread:4.1f}  {verdict}"
        )


def per_deck(
    conn: psycopg.Connection, game: GameAnatomy, fmt: str
) -> tuple[dict[str, list[float]], dict[str, list[float]], list[float], int]:
    """Parts, tailles de zones et exemplaires maximaux, deck par deck."""
    columns = ",\n               ".join(
        f'SUM(dc.quantity) FILTER (WHERE ({game.body}) AND ({sql}))::real AS "{name}"'
        for name, sql in game.traits.items()
    )
    curve = ",\n               ".join(
        f"SUM(dc.quantity) FILTER (WHERE ({game.curve_scope}) "
        f'AND c.cmc BETWEEN {lo} AND {hi})::real AS "{game.curve_label} {lo}-{hi}"'
        for lo, hi in game.curve
    )
    zones = ",\n               ".join(
        f'SUM(dc.quantity) FILTER (WHERE {sql})::real AS "{name}"'
        for name, sql in game.zones.items()
    )
    # Les `%` des motifs `LIKE` sont doublés au dernier moment : psycopg les
    # prendrait sinon pour ses propres marques de paramètre et refuserait la
    # requête. Les doubler plus tôt rendrait les traits illisibles.
    body = game.body.replace("%", "%%")
    # **Une courbe peut être vide**, et le vide se filtre comme les zones : chez
    # Pokémon, `cmc` porte les points de vie et non un coût, si bien qu'aucun
    # découpage n'y décrit une contrainte de construction. Laisser passer la
    # chaîne vide produirait un `, ,` que Postgres refuse.
    parts = [
        p
        for p in (
            f"SUM(dc.quantity) FILTER (WHERE {body})::real AS \"corps\"",
            columns.replace("%", "%%"),
            curve.replace("%", "%%"),
            zones.replace("%", "%%"),
        )
        if p
    ]
    query = f"""
        SELECT d.id,
               {",".join(chr(10) + "               " + p for p in parts)},
               MAX(dc.quantity) FILTER (
                   WHERE {game.copies_scope.replace("%", "%%")}
               )::real AS "exemplaires"
        FROM public.decks d
        JOIN public.deck_cards dc ON dc.deck_id = d.id AND dc.board = 'main'
        JOIN public.cards c ON c.oracle_id = dc.oracle_id
        WHERE d.format = %s
        GROUP BY d.id
    """
    with conn.cursor() as cur:
        cur.execute(query, (fmt,))
        names = [d.name for d in cur.description][1:]
        rows = cur.fetchall()

    shares: dict[str, list[float]] = {}
    sizes: dict[str, list[float]] = {}
    copies: list[float] = []
    zone_names = set(game.zones)
    for row in rows:
        values = dict(zip(names, row[1:]))
        total = values.pop("corps") or 0
        copies.append(values.pop("exemplaires") or 0)
        if not total:
            continue
        for name, value in values.items():
            if name in zone_names:
                sizes.setdefault(name, []).append(value or 0)
            else:
                shares.setdefault(name, []).append(100 * (value or 0) / total)
        sizes.setdefault("corps du deck", []).append(total)
    return shares, sizes, copies, len(rows)


def report(conn: psycopg.Connection, game: GameAnatomy, fmt: str) -> None:
    shares, sizes, copies, deck_count = per_deck(conn, game, fmt)
    if not deck_count:
        print(f"\n{fmt} — aucun deck\n")
        return

    print(f"\n=== {fmt} — {deck_count} decks ===")
    if sizes:
        print("  (taille de chaque zone, en cartes)")
        for name, values in sizes.items():
            print(Spread(name, values, unit="cartes").line())
    print("  (part de chaque trait dans le corps du deck, en %)")
    for name, values in shares.items():
        print(Spread(name, values).line())
    if copies:
        top = max(copies)
        over = sum(1 for c in copies if c > 3)
        print(f"  exemplaires d'une même carte : maximum observé {top:.0f}"
              + (f", {over} decks au-dessus de 3" if over else ""))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", choices=sorted(GAMES), default="magic")
    parser.add_argument("--format")
    args = parser.parse_args()

    game = GAMES[args.game]
    formats = (args.format,) if args.format else game.formats

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        for fmt in formats:
            report(conn, game, fmt)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
