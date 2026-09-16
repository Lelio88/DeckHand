"""Rafraîchissement de toutes les données du produit.

Point d'entrée unique, pensé pour une exécution périodique. Chaque étape sait
déjà se relancer sans dommage — les écritures sont des upserts, le calcul
d'empreintes ne traite que ce qui manque — l'apport de ce module est
l'orchestration et, surtout, le fait de **sauter ce qui n'a pas changé**.

Rythmes réels des sources, qui dictent la fréquence utile :

* **Scryfall** republie ses exports une fois par jour, prix compris. Les prix
  dérivent donc chaque jour, et avec eux la valorisation de collection et le
  coût de complétion des decks — la donnée la plus périssable du produit.
* **TopDeck.gg** reçoit des tournois en continu.
* **MTGJSON** ne bouge qu'aux sorties de produits préconstruits, quelques fois
  par an.

Ordre imposé par les dépendances : le catalogue d'abord, puis les empreintes
(qui référencent les impressions), puis les decks (qui référencent les cartes),
et enfin les profils de decks — qui dérivent des deux, et sans lesquels l'onglet
Decks resterait sur l'état de la veille (`app.ingestion.deck_profile`).

**Aucune connexion n'attend d'une étape à l'autre.** Les travaux longs —
ingestion du catalogue, téléchargement des illustrations, import des tournois —
ouvrent leurs propres connexions ; ce module n'a besoin que de courtes écritures
autour d'eux : version d'une source, compte, bilan. Une connexion ouverte au
départ puis laissée inactive pendant ces minutes peut être fermée par le
serveur (`app/db.py`, incident du 14 août), et le script mourait alors en
consignant le bilan, tout le travail fait. Chaque écriture courte passe donc par
un `Db` : une unité de travail jouée sur une connexion ouverte pour elle, et
rejouée si elle cède.
"""

from __future__ import annotations

import sys
import time
from typing import Any, Callable

import psycopg

from app.config import SupabaseConfig
from app.db import Session
from app.ingestion import (
    deck_profile,
    mtgjson_ingest,
    scryfall_ingest,
    scryfall_sets,
    topdeck_ingest,
)
from app.ingestion.scryfall_client import BULK_ALL, fetch_bulk_catalog
from app.ingestion.state import last_version, record
from app.vision import index_builder

SOURCE_SCRYFALL = "scryfall"
SOURCE_TOPDECK = "topdeck"
SOURCE_MTGJSON = "mtgjson"
SOURCE_ART_HASHES = "art_hashes"

#: Joue une unité de travail sur une connexion ouverte pour elle et rend sa
#: valeur. Les tests en passent un qui la joue sur une connexion factice.
Db = Callable[[Callable[[psycopg.Connection], Any]], Any]


def short_units(db_url: str) -> Db:
    """Le `Db` de production : une `Session` neuve par unité, refermée aussitôt."""

    def run_unit(unit: Callable[[psycopg.Connection], Any]) -> Any:
        with Session(db_url) as session:
            return session.run(unit)

    return run_unit


def _count(conn: psycopg.Connection, query: str, params: tuple = ()) -> int:
    with conn.cursor() as cur:
        return cur.execute(query, params).fetchone()[0]


def _scryfall_version() -> str:
    """Date de publication de l'export Scryfall le plus complet."""
    catalog = fetch_bulk_catalog()
    return str(catalog[BULK_ALL]["updated_at"])


def refresh_catalogue(db: Db, *, force: bool = False) -> bool:
    """Rafraîchit cartes, impressions et noms. Renvoie vrai si un travail a eu lieu."""
    version = _scryfall_version()
    previous = db(lambda conn: last_version(conn, SOURCE_SCRYFALL))

    # **Les extensions sont ingérées quoi qu'il arrive**, avant le saut de
    # version. Elles coûtent une poignée de pages là où le catalogue en coûte
    # 390 Mo : les protéger par la même garde ferait qu'une table vide le
    # resterait tant que Scryfall n'aurait pas republié son export.
    def ingest_sets(conn: psycopg.Connection) -> int:
        count = scryfall_sets.run(conn)
        conn.commit()
        return count

    print(f"  {db(ingest_sets)} extensions")

    if not force and previous == version:
        print(f"  catalogue déjà à jour (export du {version[:16]})")
        return False

    print(f"  export Scryfall du {version[:16]} — ingestion")
    try:
        scryfall_ingest.run()
    except Exception as exc:  # noqa: BLE001
        error = str(exc)[:500]
        db(lambda conn: record(conn, SOURCE_SCRYFALL, version=version, items=0, error=error))
        raise

    db(
        lambda conn: record(
            conn,
            SOURCE_SCRYFALL,
            version=version,
            items=_count(conn, "SELECT count(*) FROM public.cards"),
        )
    )
    return True


def refresh_art_hashes(session: Session) -> int:
    """Calcule les empreintes manquantes et propage celles des illustrations
    partagées entre plusieurs cartes. Ne recalcule jamais l'existant.

    Reçoit la `Session` de l'étape, pas une connexion : `index_builder.build`
    y joue chaque lot d'empreintes comme une unité rejouable, et le
    téléchargement des illustrations peut courir plusieurs minutes.
    """
    report = index_builder.build(session)
    session.run(index_builder.propagate_shared_art)
    if report.hashed:
        session.run(
            lambda conn: record(
                conn,
                SOURCE_ART_HASHES,
                version=None,
                items=_count(conn, "SELECT count(*) FROM public.art_hashes"),
            )
        )
    return report.hashed


def _import_decks(
    db: Db, source: str, importer: Callable[[], None], *, version: str | None
) -> None:
    """Joue un import de decks, puis consigne son résultat sur une connexion neuve.

    Un échec est consigné et affiché sans interrompre l'étape : les deux sources
    sont indépendantes, et l'une en panne ne doit pas priver l'autre.
    """
    try:
        importer()
        db(
            lambda conn: record(
                conn,
                source,
                version=version,
                items=_count(
                    conn, "SELECT count(*) FROM public.decks WHERE source_id = %s", (source,)
                ),
            )
        )
    except Exception as exc:  # noqa: BLE001
        error = str(exc)[:500]
        db(lambda conn: record(conn, source, version=None, items=0, error=error))
        print(f"    échec : {exc}")


def refresh_decks(db: Db, *, days: int = 30) -> None:
    """Réimporte le corpus de decks.

    La fenêtre est plus courte qu'à l'import initial : les tournois anciens sont
    déjà en base et leur réimport n'apporterait rien qu'un long téléchargement.
    """
    print("  tournois TopDeck.gg")
    _import_decks(db, SOURCE_TOPDECK, lambda: topdeck_ingest.run(days=days), version=f"{days}j")

    print("  précons MTGJSON")
    _import_decks(db, SOURCE_MTGJSON, mtgjson_ingest.run, version=None)


def _print_summary(db: Db) -> None:
    def read(conn: psycopg.Connection) -> list[tuple]:
        with conn.cursor() as cur:
            return cur.execute("""
                SELECT source, source_version, last_run_at, items_processed, last_error
                FROM public.ingestion_state ORDER BY source
            """).fetchall()

    for source, version, ran, items, error in db(read):
        mark = "!" if error else " "
        stamp = ran.strftime("%Y-%m-%d %H:%M")
        print(f" {mark} {source:12} {items:7} éléments   {stamp}   {version or ''}")


def run(*, force: bool = False, skip_decks: bool = False) -> None:
    started = time.time()
    config = SupabaseConfig.load()
    db = short_units(config.db_url)

    print("1/4 — catalogue Scryfall")
    changed = refresh_catalogue(db, force=force)

    print("2/4 — empreintes manquantes")
    with Session(config.db_url) as session:
        hashed = refresh_art_hashes(session)
    print(f"  {hashed} nouvelles empreintes")

    if skip_decks:
        print("3/4 — decks ignorés")
    else:
        print("3/4 — corpus de decks")
        refresh_decks(db)

    # **En dernier, et sans condition.** Ces tables dérivent des decks *et* des
    # prix : un catalogue rafraîchi sans decks nouveaux change quand même le
    # coût de complétion de tout le corpus. Les sauter parce que `--skip-decks`
    # a été demandé laisserait l'onglet Decks sur les prix de la veille, sans
    # que rien ne le dise.
    print("4/4 — profils de decks")
    needs, profiles = deck_profile.run()
    print(f"  {needs} besoins, {profiles} profils")

    print()
    _print_summary(db)

    minutes = (time.time() - started) / 60
    print(f"\nterminé en {minutes:.1f} min" + ("" if changed else " (catalogue inchangé)"))


if __name__ == "__main__":
    try:
        run(
            force="--force" in sys.argv,
            skip_decks="--skip-decks" in sys.argv,
        )
    except KeyboardInterrupt:
        sys.exit("interrompu — relancer reprendra où l'on s'est arrêté")
