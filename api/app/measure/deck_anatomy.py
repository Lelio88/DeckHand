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

Usage :
    python -m app.measure.deck_anatomy
    python -m app.measure.deck_anatomy --format commander
"""

from __future__ import annotations

import argparse
import statistics
from dataclasses import dataclass

import psycopg

from app.config import SupabaseConfig

FORMATS = ("commander", "pauper", "modern")

#: Un deck est décrit par les proportions de ce qu'il contient. Chaque entrée
#: est une expression SQL évaluée sur les cartes du deck, pondérée par la
#: quantité — un exemplaire compte pour un, quatre pour quatre.
TRAITS: dict[str, str] = {
    "cartes": "TRUE",
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
}

#: Paliers de la courbe de mana, sur les seules cartes non-terrain : un terrain
#: coûte zéro et écraserait la distribution.
CURVE = ((0, 1), (2, 2), (3, 3), (4, 4), (5, 6), (7, 99))


@dataclass
class Spread:
    """Ce qu'on retient d'une mesure : sa valeur centrale et son étalement."""

    label: str
    values: list[float]

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
        """Écart interquartile, en points de pourcentage."""
        return self.quantile(0.75) - self.quantile(0.25)

    def line(self) -> str:
        verdict = "serré" if self.spread <= 6 else "large" if self.spread <= 14 else "dispersé"
        return (
            f"  {self.label:22} médiane {self.median:5.1f}   "
            f"quartiles {self.quantile(0.25):5.1f} – {self.quantile(0.75):5.1f}   "
            f"écart {self.spread:4.1f}  {verdict}"
        )


def per_deck(conn: psycopg.Connection, fmt: str) -> tuple[dict[str, list[float]], int]:
    """Part de chaque trait dans chaque deck du format, en pourcentage."""
    columns = ",\n               ".join(
        f"SUM(dc.quantity) FILTER (WHERE {sql})::real AS \"{name}\""
        for name, sql in TRAITS.items()
    )
    curve = ",\n               ".join(
        f"SUM(dc.quantity) FILTER (WHERE c.type_line NOT LIKE '%Land%' "
        f"AND c.cmc BETWEEN {lo} AND {hi})::real AS \"coût {lo}-{hi}\""
        for lo, hi in CURVE
    )
    # Les `%` des motifs `LIKE` sont doublés au dernier moment : psycopg les
    # prendrait sinon pour ses propres marques de paramètre et refuserait la
    # requête. Les doubler plus tôt rendrait `TRAITS` illisible.
    columns = columns.replace("%", "%%")
    curve = curve.replace("%", "%%")
    query = f"""
        SELECT d.id,
               {columns},
               {curve}
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

    shares: dict[str, list[float]] = {name: [] for name in names}
    for row in rows:
        total = row[1] or 0  # la colonne « cartes »
        if not total:
            continue
        for name, value in zip(names, row[1:]):
            shares[name].append(100 * (value or 0) / total)
    return shares, len(rows)


def report(conn: psycopg.Connection, fmt: str) -> None:
    shares, deck_count = per_deck(conn, fmt)
    if not deck_count:
        print(f"\n{fmt} — aucun deck\n")
        return

    # La colonne « cartes » sert de dénominateur : sa part vaut 100 % partout
    # et n'apprendrait rien.
    shares.pop("cartes", None)

    print(f"\n=== {fmt} — {deck_count} decks ===")
    print("  (part de chaque trait dans le deck, en %)")
    for name, values in shares.items():
        print(Spread(name, values).line())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=FORMATS)
    args = parser.parse_args()

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        for fmt in ([args.format] if args.format else FORMATS):
            report(conn, fmt)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
