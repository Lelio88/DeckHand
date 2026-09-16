"""Reconstruit ce que les suggestions de decks lisent : `deck_needs` et `deck_profile`.

**Pourquoi ces deux tables existent.** `deck_suggestions` recalculait à chaque
ouverture de l'onglet le total de chaque deck, ses terrains, son identité
couleur et le prix de ses cartes — pour *tout le corpus du format*, avant d'en
garder trente. Elle rendait `57014 statement timeout` sur Pokémon, SWU et
Yu-Gi-Oh, dont les corpus vont jusqu'à 595 000 lignes de decklist. Aucune de ces
quatre grandeurs ne dépend d'une collection : elles sont donc calculées ici, une
fois, et la fonction n'a plus qu'à retrancher ce que l'utilisateur possède.
Voir `supabase/migrations/20260916140000_deck_profile.sql`.

**Quand la relancer.** Après toute écriture dans `decks`, `deck_cards` ou les
prix de `card_prints` — autrement dit à la fin de `app.ingestion.refresh`, qui
s'en charge. Les prix ne bougeant qu'une fois par jour (`CLAUDE.md` §IV.5), une
reconstruction quotidienne suffit.

**L'invariant à préserver** : un deck n'apparaît dans les suggestions qu'après
son passage ici. Une insertion faite à la main dans `decks` reste invisible
jusqu'à la reconstruction suivante — c'est le prix du précalcul, et il est
assumé parce que les decks n'entrent que par l'ingestion.

**TRUNCATE plutôt qu'un échange de tables.** Le verrou exclusif bloque les
lecteurs le temps de la passe — une cinquantaine de secondes. C'est le même
arbitrage que `20260824130000_card_prints_set_index.sql` : la table n'est
écrite que par l'ingestion, lancée à la main, et un échange de tables
demanderait de recréer index, droits et politiques à chaque passe pour un gain
qui n'existe pas la nuit. Un DELETE laisserait en prime un million de lignes
mortes par jour sur un serveur qui n'a pas la place.

Usage :

    cd api && .venv/Scripts/python -m app.ingestion.deck_profile
"""

from __future__ import annotations

import sys
import time

import psycopg

from app.config import SupabaseConfig
from app.db import Session
from app.ingestion.state import record

#: Nom sous lequel la reconstruction s'inscrit dans `ingestion_state`.
SOURCE = "deck_profile"

#: Sources dont le passage ne périme rien ici. `art_hashes` ne calcule que des
#: empreintes d'illustrations : ni un deck ni un prix n'en dépendent.
SANS_EFFET = (SOURCE, "art_hashes")

#: Les deux signaux de péremption, en une requête de trente millisecondes.
#:
#: **Rien à retenir, tout se calcule.** Le compte des decks se compare à celui
#: des profils : un deck entré ou sorti se voit sans qu'aucun connecteur ait eu
#: à le signaler. Et la date de la dernière ingestion se compare à la nôtre :
#: un prix qui bouge se voit de la même façon.
#:
#: **La faille assumée** : une decklist modifiée sur place, sans changer le
#: nombre de decks et depuis un connecteur qui n'inscrit rien dans
#: `ingestion_state`, passerait au travers. Les decks sont insérés, jamais
#: réécrits carte à carte — et le contrôle exact coûterait sept secondes et
#: demie, mesuré, pour attraper un cas qui ne se produit pas.
ETAT = """
SELECT (SELECT count(*) FROM public.decks)                     AS decks,
       (SELECT count(*) FROM public.deck_profile)              AS profils,
       (SELECT last_run_at FROM public.ingestion_state
         WHERE source = %(source)s)                            AS construit,
       (SELECT max(last_run_at) FROM public.ingestion_state
         WHERE source <> ALL(%(sans_effet)s))                  AS derniere_source
"""


def perime(conn: psycopg.Connection) -> list[str]:
    """Les raisons de reconstruire, ou une liste vide s'il n'y en a aucune.

    Trente millisecondes : assez peu pour être appelé partout, ce qui est le
    point. Il n'y a pas de point de passage unique où accrocher la
    reconstruction — `deck_ingest.store_deck` s'appelle par deck, les prix n'ont
    pas d'écrivain commun, et dix connecteurs n'inscrivent rien. Puisqu'on ne
    peut pas garantir qu'elle sera lancée, on garantit qu'on saura qu'elle
    manque.
    """
    with conn.cursor() as cur:
        cur.execute(ETAT, {"source": SOURCE, "sans_effet": list(SANS_EFFET)})
        decks, profils, construit, derniere = cur.fetchone()

    if construit is None:
        return ["les profils n'ont jamais été construits"]
    raisons = []
    if decks != profils:
        raisons.append(f"{decks} decks pour {profils} profils")
    if derniere is not None and derniere > construit:
        raisons.append(
            f"une source a tourné depuis ({derniere:%Y-%m-%d %H:%M} "
            f"contre {construit:%Y-%m-%d %H:%M})"
        )
    return raisons

#: Une carte du board principal, sa quantité, sa nature et son prix.
#:
#: `bool_or(... LIKE 'Basic Land%')` et non `=` : « Basic Land — Plains » comme
#: « Basic Snow Land — Island ». Ni les terrains légendaires ni les bicolores,
#: qui eux s'achètent.
NEEDS = """
INSERT INTO public.deck_needs (deck_id, oracle_id, needed, is_basic, unit_price_eur)
SELECT dc.deck_id,
       dc.oracle_id,
       SUM(dc.quantity)::integer,
       bool_or(c.type_line LIKE 'Basic Land%'),
       COALESCE(
           (SELECT min(pr.price_eur) FROM public.card_prints pr
            WHERE pr.oracle_id = dc.oracle_id),
           0)
FROM public.deck_cards dc
JOIN public.cards c ON c.oracle_id = dc.oracle_id
WHERE dc.board = 'main'
GROUP BY dc.deck_id, dc.oracle_id
"""

#: Le profil d'un deck, agrégé depuis `deck_needs`.
#:
#: L'identité couleur se lit sur le deck **entier**, terrains compris : un deck
#: qui ne contient de rouge que dans ses Montagnes reste un deck rouge. Les
#: totaux, eux, excluent les terrains de base — ils ne s'achètent pas.
PROFILE = """
INSERT INTO public.deck_profile
    (deck_id, game, format, total_cards, basic_lands, total_cost_eur, unpriced_cards, colors)
SELECT d.id,
       d.game,
       d.format,
       COALESCE(SUM(n.needed) FILTER (WHERE NOT n.is_basic), 0)::integer,
       COALESCE(SUM(n.needed) FILTER (WHERE n.is_basic), 0)::integer,
       COALESCE(SUM(n.needed * n.unit_price_eur) FILTER (WHERE NOT n.is_basic), 0),
       -- **Zéro euro veut dire « sans cote », et c'est vérifié** : aucune des
       -- 253 468 impressions n'est cotée exactement 0,00, la plus basse cote
       -- positive étant 0,01 €. Ce compte dit si `total_cost_eur` est entier —
       -- seule condition pour que `deck_suggestions` classe le deck au coût.
       COALESCE(SUM(n.needed) FILTER (WHERE NOT n.is_basic
                                        AND n.unit_price_eur = 0), 0)::integer,
       co.colors
FROM public.decks d
JOIN public.deck_needs n ON n.deck_id = d.id
JOIN LATERAL (
    SELECT COALESCE(
               array_agg(DISTINCT ci ORDER BY ci) FILTER (WHERE ci IS NOT NULL),
               ARRAY[]::text[]) AS colors
    FROM public.deck_needs n2
    JOIN public.cards c ON c.oracle_id = n2.oracle_id
    LEFT JOIN LATERAL unnest(c.color_identity) AS ci ON true
    WHERE n2.deck_id = d.id
) co ON true
GROUP BY d.id, d.game, d.format, co.colors
"""


def rebuild(conn: psycopg.Connection) -> tuple[int, int]:
    """Reconstruit les deux tables en une transaction. Rend (besoins, profils).

    **Le délai de l'instruction est relevé le temps de la passe.** Le rôle
    d'ingestion coupe à deux minutes, et l'insertion des besoins en prend une
    bonne partie sur un million de lignes : sans cette marge, la reconstruction
    céderait le jour où le corpus grandit, en laissant les deux tables vides et
    l'onglet Decks muet.
    """
    with conn.cursor() as cur:
        cur.execute("SET LOCAL statement_timeout = '10min'")
        # L'ordre importe : `deck_profile` se lit depuis `deck_needs`.
        cur.execute("TRUNCATE public.deck_needs, public.deck_profile")
        cur.execute(NEEDS)
        needs = cur.rowcount
        cur.execute(PROFILE)
        profiles = cur.rowcount
        # Sans cela le planificateur travaille sur des tables qu'il croit
        # vides, et choisit des parcours séquentiels là où les index servent.
        cur.execute("ANALYZE public.deck_needs")
        cur.execute("ANALYZE public.deck_profile")
    conn.commit()
    # Inscrit APRÈS le commit : une reconstruction qui a échoué ne doit pas
    # laisser croire qu'elle a eu lieu. Même raison que `state.record` ne
    # consigne pas de version après une erreur.
    record(conn, SOURCE, version=None, items=profiles)
    return needs, profiles


def run(*, force: bool = False) -> tuple[int, int] | None:
    """Reconstruit si nécessaire. Rend `None` quand il n'y avait rien à faire.

    **Bon marché quand tout est à jour** — trente millisecondes — ce qui permet
    de l'appeler à la fin de n'importe quelle ingestion sans y penser.
    """
    config = SupabaseConfig.load()
    with Session(config.db_url) as session:
        if not force:
            raisons = session.run(perime)
            if not raisons:
                return None
            for raison in raisons:
                print(f"  à reconstruire : {raison}")
        return session.run(rebuild)


if __name__ == "__main__":
    started = time.time()
    bilan = run(force="--force" in sys.argv)
    if bilan is None:
        print("profils déjà à jour — rien à faire (--force pour reconstruire)")
    else:
        needs, profiles = bilan
        print(
            f"{needs} besoins, {profiles} profils reconstruits "
            f"en {time.time() - started:.0f} s"
        )
