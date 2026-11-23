"""Ce que la ligne basse d'une carte suffirait à trancher : année, numéro, total.

**Pourquoi cette mesure (issue n°50).** Sur un étalement, l'édition n'est
précisée d'office que si le catalogue n'en connaît qu'une. Avant M15 (2014),
aucun code d'extension n'est imprimé — `edition_from_set` n'y peut rien —, mais
le carton porte encore l'**année du copyright** (« ©1993-2001 ») et, depuis
Exodus (1998), le **numéro de collection et le total** (« 247/350 »). Cette
mesure répond à la question de viabilité, **côté catalogue seulement** : si
l'appareil lisait parfaitement ces trois mentions, quelle part des cartes à
plusieurs éditions serait tranchée ? La faisabilité — ML Kit sait-il les lire
sur une bande découpée en pleine résolution ? — reste à mesurer sur l'appareil.

**L'unité est la case de classeur** `(set_code, collector_number)`, langues
confondues, comme le deuxième comptage d'`edition_from_set` : le #247 anglais et
le #247 français se rangent au même endroit.

**Une case est tranchée** quand, la carte étant connue par son nom, une seule de
ses cases reste compatible avec ce qu'on a lu (`candidates`). Une mention
illisible sur la vraie carte — numéro d'avant Exodus, total d'une promo — ne
filtre rien : on n'a rien lu.

**Hypothèses, assumées et nommées** :

* L'année du copyright est l'année de sortie de l'extension (`released_at`). Ce
  n'est pas toujours vrai : une extension de janvier peut porter l'année
  précédente. La lecture **tolérante** accepte donc un an d'écart de part et
  d'autre ; c'est elle qui protège d'une édition fausse, et la stricte n'est
  qu'un plafond.
* Numéro et total ne sont imprimés que depuis Exodus (`NUMBERS_SINCE`).
* Le total est le `printed_size` de Scryfall. Une extension qui n'en a pas —
  la plupart des promos — n'imprime pas de « n/total » : ni son numéro ni son
  total ne sont alors réputés lisibles. Le numéro de Scryfall y est souvent un
  identifiant interne (`prm #35146`), et le compter comme lu gonflerait le
  résultat.

**La cible est avant M15** (`SET_CODE_SINCE`) : après, le code d'extension est
imprimé et `edition_from_set` le mesure déjà. Les cases d'après restent
**candidates** — lire « 2000 » écarte justement une réédition de 2019.

Pondération par le corpus de decks, comme `edition_from_set` : une carte
omniprésente pèse plus qu'une rareté, et c'est elle qui remplit un classeur.

Usage :
    cd api && .venv/Scripts/python -m app.measure.edition_from_print_line
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date
from itertools import combinations

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_client import fetch_sets

#: Exodus, première extension à imprimer le numéro de collection et le total.
NUMBERS_SINCE = date(1998, 6, 15)
#: M15, première extension à imprimer son code : au-delà, hors cible.
SET_CODE_SINCE = date(2014, 7, 18)
KEYS = ("year", "number", "total")


@dataclass(frozen=True)
class Cell:
    """Une case de classeur, avec ce que son carton peut porter."""

    set_code: str
    collector_number: str
    released_at: date
    printed_size: int | None


def printed_number(cell: Cell) -> str | None:
    # Sans taille imprimée, pas de « n/total » sur le carton : le numéro de
    # Scryfall est alors un identifiant à lui (`prm #35146`), pas une mention.
    if cell.released_at < NUMBERS_SINCE or cell.printed_size is None:
        return None
    return cell.collector_number


def printed_total(cell: Cell) -> int | None:
    return cell.printed_size if cell.released_at >= NUMBERS_SINCE else None


def is_target(cell: Cell) -> bool:
    """Sans code d'extension imprimé : seule la ligne basse peut trancher."""
    return cell.released_at < SET_CODE_SINCE


def _matches(candidate: Cell, truth: Cell, key: str, tolerant: bool) -> bool:
    if key == "year":
        gap = abs(candidate.released_at.year - truth.released_at.year)
        return gap <= 1 if tolerant else gap == 0
    read = printed_number(truth) if key == "number" else printed_total(truth)
    if read is None:
        return True  # rien de lu, rien d'écarté
    seen = printed_number(candidate) if key == "number" else printed_total(candidate)
    return seen == read


def candidates(
    cells: list[Cell], truth: Cell, keys: tuple[str, ...], tolerant: bool = False
) -> list[Cell]:
    """Les cases de la carte compatibles avec ce qu'on lit sur `truth`."""
    return [c for c in cells if all(_matches(c, truth, k, tolerant) for k in keys)]


# Cases distinctes des cartes Magic (jetons exclus) à plusieurs cases. La date
# retenue pour une case est la plus ancienne de ses langues.
CELLS = """
WITH cells AS (
    SELECT p.oracle_id, p.set_code, p.collector_number, MIN(p.released_at) AS released_at
    FROM public.card_prints p
    JOIN public.cards c ON c.oracle_id = p.oracle_id
    WHERE c.game = 'magic'
      AND c.layout NOT IN ('token', 'double_faced_token', 'emblem')
      AND p.released_at IS NOT NULL
    GROUP BY p.oracle_id, p.set_code, p.collector_number
)
SELECT oracle_id::text, set_code, collector_number, released_at
FROM cells
WHERE oracle_id IN (SELECT oracle_id FROM cells GROUP BY oracle_id HAVING COUNT(*) > 1)
"""

COPIES = """
SELECT dc.oracle_id::text, SUM(dc.quantity)::bigint
FROM public.deck_cards dc
WHERE dc.board = 'main'
GROUP BY dc.oracle_id
"""

# Les cartes de l'issue n°50, photographiées le 2026-09-29, en contrôle.
EXAMPLES = ("Gerrard's Command", "Goblin Legionnaire", "Hull Breach", "Zhur-Taa Druid")


def combos() -> list[tuple[str, ...]]:
    return [c for n in range(1, len(KEYS) + 1) for c in combinations(KEYS, n)]


def pct(part: float, whole: float) -> str:
    return "—" if not whole else f"{100 * part / whole:.1f} %"


def main() -> int:
    sizes = {s["code"]: s.get("printed_size") for s in fetch_sets()}
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        rows = conn.execute(CELLS).fetchall()
        copies = dict(conn.execute(COPIES).fetchall())
        names = dict(
            conn.execute(
                "SELECT name, oracle_id::text FROM public.cards "
                "WHERE game = 'magic' AND name = ANY(%s)",
                (list(EXAMPLES),),
            ).fetchall()
        )

    cards: dict[str, list[Cell]] = defaultdict(list)
    for oracle_id, set_code, number, released_at in rows:
        cards[oracle_id].append(Cell(set_code, number, released_at, sizes.get(set_code)))

    targets = [(o, c) for o, cells in cards.items() for c in cells if is_target(c)]
    with_numbers = sum(1 for _, c in targets if printed_number(c) is not None)
    print(f"Cartes Magic à plusieurs cases     : {len(cards)}")
    print(f"Cases cibles (avant M15)           : {len(targets)}")
    print(f"  dont numéro et total imprimés    : {with_numbers} ({pct(with_numbers, len(targets))})")
    print()

    total_copies = sum(copies.get(o, 0) for o in {o for o, _ in targets})
    print(f"{'lecture':<24}{'strict':>10}{'toléré':>10}{'corpus (toléré)':>18}")
    for keys in combos():
        line = f"{' + '.join(keys):<24}"
        for tolerant in (False, True):
            hit = sum(1 for o, c in targets if len(candidates(cards[o], c, keys, tolerant)) == 1)
            line += f"{pct(hit, len(targets)):>10}"
        # Cas moyen du corpus : chaque carte pèse ses exemplaires joués, tranchés
        # dans la proportion de ses cases cibles qui le sont.
        per_card: dict[str, list[bool]] = defaultdict(list)
        for o, c in targets:
            per_card[o].append(len(candidates(cards[o], c, keys, True)) == 1)
        weighted = sum(copies.get(o, 0) * sum(v) / len(v) for o, v in per_card.items())
        print(line + f"{pct(weighted, total_copies):>18}")

    print()
    print("Contrôle sur les cartes de l'issue (lecture tolérée, année + numéro + total) :")
    for name in EXAMPLES:
        oracle_id = names.get(name)
        if oracle_id not in cards:
            print(f"  {name:<20} une seule case ou introuvable")
            continue
        for cell in sorted(cards[oracle_id], key=lambda c: c.released_at):
            if not is_target(cell):
                continue
            left = candidates(cards[oracle_id], cell, KEYS, tolerant=True)
            verdict = "tranchée" if len(left) == 1 else f"{len(left)} candidates"
            print(f"  {name:<20} {cell.set_code:<6} #{cell.collector_number:<5} {verdict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
