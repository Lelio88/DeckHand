"""Quels jeux le produit porte, et lesquels sont retirés le temps d'un quota.

**Ce module existe à cause d'une contrainte d'hébergement, pas d'un choix de
produit** (#48). Supabase a signalé le 2026-09-17 que la base occupait 855 Mo
pour 500 autorisés sur le plan gratuit, et annonce la lecture seule au-delà —
ce qui arrêterait toute écriture, l'ajout à la collection compris. Le corpus de
decks pesait 53 % de la base, dont ~262 Mo pour les 23 574 decks Pokémon, contre
~18 Mo pour les 1 395 decks Magic.

Les cinq jeux retirés sont ceux dont personne n'a les cartes : la promesse « que
puis-je construire ? » suppose une collection en face, et la collection réelle
est à 100 % Magic. Magic et Riftbound portent la promesse du produit, Wankul est
ingéré sous autorisation nominative et pèse moins d'un mégaoctet.

**Vider `JEUX_RETIRES` remet tout.** C'est la seule ligne à toucher côté
serveur ; son jumeau côté application est `Game.retires`
(`app/lib/src/config/selected_game.dart`). Les catalogues se réingèrent par
leurs connecteurs — rien n'est perdu, seulement déchargé.

**Le garde est posé sur les connecteurs de catalogue**, pas sur les douze
connecteurs du jeu. C'est là que les données entrent : sans cartes, un connecteur
de prix n'a rien à mettre à jour et un connecteur de decks échoue sur sa clé
étrangère, bruyamment. Brider les cinq portes d'entrée suffit, et laisse cinq
lignes à retirer plutôt que douze.

Usage :

    from app.ingestion.jeux_actifs import exiger_actif

    def main() -> int:
        exiger_actif("pokemon")   # lève JeuRetire si le jeu est déchargé
        ...

Purge de ce qui reste en base — **par lots, et reprenable** : la relancer
après une coupure continue là où elle s'est arrêtée. Le compactage qui suit
est **obligatoire pour que le quota en tienne compte** : supprimer des lignes
ne rend rien au disque.

    cd api && .venv/Scripts/python -u -m app.ingestion.jeux_actifs --purger
    cd api && .venv/Scripts/python -u -m app.ingestion.jeux_actifs --compacter
"""

from __future__ import annotations

import sys

import psycopg

from app.config import SupabaseConfig
from app.db import Session

#: Tous les jeux que le produit sait ingérer, actifs ou non.
JEUX = ("magic", "riftbound", "wankul", "pokemon", "yugioh", "swu", "onepiece", "lorcana")

#: Les jeux déchargés le temps de tenir dans le quota (#48).
#: **Vider ce tuple les remet** — puis relancer leurs connecteurs.
JEUX_RETIRES = ("pokemon", "yugioh", "swu", "onepiece", "lorcana")

#: Ceux qu'on sert réellement.
JEUX_ACTIFS = tuple(j for j in JEUX if j not in JEUX_RETIRES)


class JeuRetire(RuntimeError):
    """Un connecteur d'un jeu déchargé a été lancé."""


def exiger_actif(jeu: str) -> None:
    """Refuse de faire entrer les données d'un jeu retiré.

    Sans ce garde, une ingestion lancée par habitude ramènerait en quelques
    minutes les centaines de mégaoctets qu'on vient de décharger, et le projet
    repasserait en lecture seule sans que personne ne fasse le lien.
    """
    if jeu in JEUX_RETIRES:
        raise JeuRetire(
            f"« {jeu} » est retiré du produit le temps de tenir dans le quota "
            f"Supabase (#48). Pour le remettre : vider JEUX_RETIRES dans "
            f"app/ingestion/jeux_actifs.py, et Game.retires côté application."
        )


#: L'ordre compte : `deck_cards` et `decks` référencent `cards` en NO ACTION,
#: donc les decks partent d'abord. `card_prints`, `card_search_names` et
#: `art_hashes` suivent `cards` en CASCADE et n'ont pas à être nommés.
_ETAPES = (
    ("profils de decks", "deck_profile",
     "deck_id IN (SELECT id FROM public.decks WHERE game = ANY(%s))", 20_000),
    ("besoins de decks", "deck_needs",
     "deck_id IN (SELECT id FROM public.decks WHERE game = ANY(%s))", 20_000),
    ("cartes de decks", "deck_cards",
     "deck_id IN (SELECT id FROM public.decks WHERE game = ANY(%s))", 20_000),
    ("decks", "decks", "game = ANY(%s)", 5_000),
    # **Le lot le plus petit, et c'est là que ça se joue.** Supprimer une carte
    # entraîne ses impressions, ses noms de recherche et ses empreintes ; mille
    # cartes en cascade coûtent déjà plusieurs secondes.
    ("cartes (et, en cascade, impressions, noms, empreintes)", "cards",
     "game = ANY(%s)", 1_000),
)


def _en_collection(conn: psycopg.Connection, jeux: tuple[str, ...]) -> int:
    """Combien d'exemplaires possédés appartiennent aux jeux à décharger."""
    with conn.cursor() as cur:
        return cur.execute(
            """SELECT count(*) FROM public.collection_items ci
               JOIN public.card_prints p ON p.scryfall_id = ci.print_id
               JOIN public.cards c ON c.oracle_id = p.oracle_id
               WHERE c.game = ANY(%s)""",
            (list(jeux),),
        ).fetchone()[0]


def purger(
    conn: psycopg.Connection,
    jeux: tuple[str, ...] = JEUX_RETIRES,
    *,
    journal=None,
) -> dict[str, int]:
    """Décharge les données des jeux retirés, et rend ce qui a été supprimé.

    **Par lots, et non d'un bloc.** La première version tenait tout dans une
    transaction : le `DELETE` sur `cards` a dépassé le `statement_timeout` de
    deux minutes du rôle, et les deux millions de lignes déjà supprimées sont
    reparties avec le *rollback* — une demi-heure pour rien. Chaque lot est donc
    commité, et l'opération est **reprenable** : la relancer continue là où elle
    s'est arrêtée au lieu de tout refaire.

    **La collection est vérifiée avant, pas pendant.** Les clés étrangères
    `NO ACTION` de `collection_items` feraient échouer la purge sur une carte
    possédée — mais à mi-chemin, decks déjà supprimés. Mieux vaut refuser
    d'entrée : perdre une collection pour gagner des mégaoctets serait un
    mauvais échange, et s'arrêter au milieu n'est pas un bon lot de consolation.
    """
    if not jeux:
        return {}

    possedes = _en_collection(conn, jeux)
    if possedes:
        raise RuntimeError(
            f"{possedes} exemplaire(s) de ces jeux sont en collection. "
            f"La purge est refusée : vider la collection de ces jeux d'abord, "
            f"ou les retirer de la liste."
        )

    bilan: dict[str, int] = {}
    for libelle, table, condition, lot in _ETAPES:
        total = 0
        while True:
            with conn.cursor() as cur:
                cur.execute(
                    f"DELETE FROM public.{table} WHERE ctid IN ("
                    f"SELECT ctid FROM public.{table} WHERE {condition} LIMIT {lot})",
                    (list(jeux),),
                )
                supprimees = cur.rowcount
            conn.commit()
            total += supprimees
            if journal and supprimees:
                journal(f"  {table} : {total}")
            if supprimees < lot:
                break
        bilan[libelle] = total
    return bilan


#: Les tables que la purge vide, de la plus allégée à la moins.
#: `VACUUM FULL` réécrit la table dans un fichier neuf : il lui faut l'espace de
#: ce qui **reste**, pas de ce qui partait — d'où l'ordre, qui libère d'abord le
#: plus de place possible avant d'attaquer les tables encore grosses.
_A_COMPACTER = (
    "deck_needs",
    "deck_cards",
    "decks",
    "deck_profile",
    "card_prints",
    "card_search_names",
    "cards",
    "art_hashes",
)


def compacter(conn: psycopg.Connection, journal=None) -> None:
    """Rend au disque la place des lignes supprimées.

    **Supprimer ne rend rien.** Postgres marque l'espace réutilisable, mais le
    fichier garde sa taille : `pg_database_size` — et donc le quota que Supabase
    facture — ne bouge pas d'un octet tant qu'un `VACUUM FULL` n'a pas réécrit
    la table.

    **Il verrouille la table qu'il réécrit**, en `ACCESS EXCLUSIVE` : personne ne
    lit ni n'écrit dessus pendant ce temps. Sur une base servie à une poignée de
    personnes, la gêne est théorique ; sur une base ouverte, ce serait une
    coupure. Table par table, donc, et jamais sur la base entière d'un coup.

    Le `statement_timeout` de deux minutes du rôle est levé **pour cette session
    seulement** : un `VACUUM FULL` ne se découpe pas en lots, il finit ou il
    échoue.
    """
    conn.autocommit = True  # VACUUM refuse de tourner dans une transaction
    try:
        with conn.cursor() as cur:
            cur.execute("SET statement_timeout = 0")
            for table in _A_COMPACTER:
                avant_octets = cur.execute(
                    "SELECT pg_total_relation_size(%s)", (f"public.{table}",)
                ).fetchone()[0]
                cur.execute(f"VACUUM (FULL, ANALYZE) public.{table}")
                apres_octets = cur.execute(
                    "SELECT pg_total_relation_size(%s)", (f"public.{table}",)
                ).fetchone()[0]
                if journal:
                    gagne = (avant_octets - apres_octets) / 1024 / 1024
                    journal(
                        f"  {table:<20}{avant_octets / 1024 / 1024:>8.0f} Mo "
                        f"→ {apres_octets / 1024 / 1024:>6.0f} Mo "
                        f"(rendu {gagne:.0f} Mo)"
                    )
    finally:
        conn.autocommit = False


def _taille(conn: psycopg.Connection) -> str:
    with conn.cursor() as cur:
        return cur.execute(
            "SELECT pg_size_pretty(pg_database_size(current_database()))"
        ).fetchone()[0]


def main() -> int:
    if "--compacter" in sys.argv:
        cfg = SupabaseConfig.load()
        with Session(cfg.db_url) as session:
            print(f"base avant : {session.run(_taille)}")
            session.run(lambda c: compacter(c, journal=print))
            print(f"base après : {session.run(_taille)}")
        return 0

    if "--purger" not in sys.argv:
        print("jeux servis  :", ", ".join(JEUX_ACTIFS))
        print("jeux retirés :", ", ".join(JEUX_RETIRES) or "aucun")
        print("\nRien n'a été supprimé. Ajouter --purger pour décharger.")
        return 0

    cfg = SupabaseConfig.load()
    with Session(cfg.db_url) as session:
        avant = session.run(_taille)
        print(f"base avant : {avant}")
        bilan = session.run(lambda c: purger(c, journal=print))
        for libelle, n in bilan.items():
            print(f"  {n:>9} {libelle}")
        apres = session.run(_taille)
        print(f"base après : {apres}")
        print("\nLa place n'est rendue qu'après VACUUM — l'autovacuum s'en charge,")
        print("ou `VACUUM FULL` la rend tout de suite en verrouillant les tables.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
