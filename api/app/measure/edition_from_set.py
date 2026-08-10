"""Ce que le code d'extension suffit à trancher, sans lire le numéro.

**Pourquoi cette mesure.** Le numéro de collection donne la case d'un classeur,
mais il est imprimé en corps minuscule : sur une photo d'étalement réelle, ML
Kit l'a rendu « C O0O5 » et « 02 » — inexploitable. Le **code d'extension** de
la même ligne, lui, est sorti juste deux fois sur deux (« MSH FR MARC
AsPINALL »), parce qu'il est en capitales et plus large.

D'où la question que ce script tranche : une carte étant déjà identifiée par
son nom, **le seul code d'extension suffit-il à désigner une impression
unique ?** Si oui, l'édition se résout sur une photo ordinaire, sans caméra
fixe et sans lire le numéro.

Trois lectures, parce que trois choses différentes s'appellent « une
impression » :

1. **Impressions brutes** — chaque ligne de `card_prints`, langues comprises.
   Une carte publiée en anglais et en français dans la même extension en a
   deux, alors que le collectionneur n'en voit qu'une à ranger.
2. **Cases de classeur** — les couples `(set_code, collector_number)`
   distincts. C'est l'unité qui compte pour #11 : le #412 anglais et le #412
   français partagent la même case.
3. **Cases, langue connue** — le scan sait dans quelle langue il a lu le nom.
   Restreindre à cette langue avant de compter dit ce que le pipeline réel
   obtiendrait.

Le résultat est donné en part de **cartes** et en part d'**exemplaires du
corpus de decks** : une carte rare tranchée ne vaut pas une carte omniprésente
tranchée, et c'est la seconde qui décide du remplissage réel d'un classeur.

Usage :
    cd api && .venv/Scripts/python -m app.measure.edition_from_set
"""

from __future__ import annotations

import psycopg

from app.config import SupabaseConfig

# Une carte n'existant que dans une seule extension est tranchée d'avance : le
# code lu n'y ajoute rien. On les compte à part pour ne pas gonfler le résultat.
QUERY = """
WITH prints AS (
    SELECT p.oracle_id,
           p.set_code,
           p.collector_number,
           p.lang
    FROM public.card_prints p
    JOIN public.cards c ON c.oracle_id = p.oracle_id
    WHERE c.game = 'magic'
      AND c.layout NOT IN ('token', 'double_faced_token', 'emblem')
),
per_card AS (
    SELECT oracle_id,
           COUNT(DISTINCT set_code)                        AS sets,
           COUNT(*)                                        AS raw_prints,
           COUNT(DISTINCT (set_code, collector_number))    AS cells
    FROM prints
    GROUP BY oracle_id
),
per_card_set AS (
    SELECT oracle_id,
           set_code,
           COUNT(*)                                     AS raw_prints,
           COUNT(DISTINCT collector_number)             AS cells,
           COUNT(DISTINCT collector_number)
               FILTER (WHERE lang = 'en')               AS cells_en,
           COUNT(DISTINCT collector_number)
               FILTER (WHERE lang = 'fr')               AS cells_fr
    FROM prints
    GROUP BY oracle_id, set_code
)
SELECT
    (SELECT COUNT(*) FROM per_card)                                   AS cards,
    (SELECT COUNT(*) FROM per_card WHERE sets = 1)                    AS single_set_cards,
    (SELECT COUNT(*) FROM per_card_set)                               AS pairs,
    (SELECT COUNT(*) FROM per_card_set WHERE raw_prints = 1)          AS pairs_one_print,
    (SELECT COUNT(*) FROM per_card_set WHERE cells = 1)               AS pairs_one_cell,
    -- Rapportées à leur propre base : compter les couples « à une seule case
    -- française » sur l'ensemble des couples mêlerait deux échecs distincts —
    -- l'ambiguïté, et l'absence pure et simple d'édition française.
    (SELECT COUNT(*) FROM per_card_set WHERE cells_en > 0)            AS pairs_with_en,
    (SELECT COUNT(*) FROM per_card_set WHERE cells_en = 1)            AS pairs_one_cell_en,
    (SELECT COUNT(*) FROM per_card_set WHERE cells_fr > 0)            AS pairs_with_fr,
    (SELECT COUNT(*) FROM per_card_set WHERE cells_fr = 1)            AS pairs_one_cell_fr
"""

# Pondération par le corpus : ce qu'un joueur a réellement dans les mains.
WEIGHTED = """
WITH prints AS (
    SELECT p.oracle_id, p.set_code, p.collector_number
    FROM public.card_prints p
    JOIN public.cards c ON c.oracle_id = p.oracle_id
    WHERE c.game = 'magic' AND c.layout NOT IN ('token', 'double_faced_token', 'emblem')
),
per_card_set AS (
    SELECT oracle_id, set_code, COUNT(DISTINCT collector_number) AS cells
    FROM prints
    GROUP BY oracle_id, set_code
),
-- Deux lectures, parce que le corpus de decks ne dit pas de quelle extension
-- vient l'exemplaire joué :
--   • `always_single` — pire cas : la carte n'est tranchée que si **toutes**
--     ses extensions désignent une case unique. C'est ce qu'on obtient en
--     supposant que l'utilisateur possède justement la plus ambiguë.
--   • `share` — cas moyen : la part de ses extensions qui tranchent, ce qu'on
--     obtient en supposant l'exemplaire tiré au hasard parmi elles.
-- La vérité est entre les deux, plus près du cas moyen : rien n'incite un
-- joueur à posséder systématiquement la réédition la plus alambiquée.
decided AS (
    SELECT oracle_id,
           bool_and(cells = 1)                                    AS always_single,
           COUNT(*) FILTER (WHERE cells = 1)::numeric / COUNT(*)  AS share
    FROM per_card_set
    GROUP BY oracle_id
),
copies AS (
    SELECT dc.oracle_id, SUM(dc.quantity)::bigint AS copies
    FROM public.deck_cards dc
    WHERE dc.board = 'main'
    GROUP BY dc.oracle_id
)
SELECT SUM(c.copies)                                              AS copies_total,
       SUM(c.copies) FILTER (WHERE d.always_single)               AS copies_worst,
       ROUND(SUM(c.copies * d.share))                             AS copies_average
FROM copies c
JOIN decided d ON d.oracle_id = c.oracle_id
"""


def pct(part: int, whole: int) -> str:
    return "—" if not whole else f"{100 * part / whole:.1f} %"


def main() -> int:
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            (
                cards,
                single_set,
                pairs,
                one_print,
                one_cell,
                with_en,
                one_cell_en,
                with_fr,
                one_cell_fr,
            ) = cur.fetchone()

            cur.execute(WEIGHTED)
            copies_total, copies_worst, copies_average = cur.fetchone()

    print(f"Cartes Magic (jetons exclus)  : {cards}")
    print(f"  dont une seule extension    : {single_set} ({pct(single_set, cards)})")
    print("     — tranchées sans rien lire, le code n'y ajoute rien")
    print()
    print(f"Couples (carte, extension)    : {pairs}")
    print(f"  une seule impression brute  : {one_print} ({pct(one_print, pairs)})")
    print(f"  une seule case de classeur  : {one_cell} ({pct(one_cell, pairs)})")
    print("     — le couple désigne alors (set_code, collector_number) sans ambiguïté")
    print()
    print("En restreignant à la langue du nom lu, sur les couples publiés dans cette langue :")
    print(
        f"  anglais                     : {one_cell_en} / {with_en} "
        f"({pct(one_cell_en, with_en)})"
    )
    print(
        f"  français                    : {one_cell_fr} / {with_fr} "
        f"({pct(one_cell_fr, with_fr)})"
    )
    print()
    print("Pondéré par le corpus de decks (exemplaires réellement joués) :")
    print(f"  exemplaires                 : {copies_total}")
    print(
        f"  cas moyen                   : {int(copies_average or 0)} "
        f"({pct(int(copies_average or 0), copies_total or 0)})"
    )
    print(
        f"  pire cas                    : {copies_worst} "
        f"({pct(copies_worst or 0, copies_total or 0)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
