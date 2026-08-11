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
(qui référencent les impressions), puis les decks (qui référencent les cartes).
"""

from __future__ import annotations

import sys
import time

import psycopg

from app.config import SupabaseConfig
from app.ingestion import mtgjson_ingest, scryfall_ingest, scryfall_sets, topdeck_ingest
from app.ingestion.scryfall_client import BULK_ALL, fetch_bulk_catalog
from app.ingestion.state import last_version, record
from app.vision import index_builder

SOURCE_SCRYFALL = "scryfall"
SOURCE_TOPDECK = "topdeck"
SOURCE_MTGJSON = "mtgjson"
SOURCE_ART_HASHES = "art_hashes"


def _scryfall_version() -> str:
    """Date de publication de l'export Scryfall le plus complet."""
    catalog = fetch_bulk_catalog()
    return str(catalog[BULK_ALL]["updated_at"])


def refresh_catalogue(conn: psycopg.Connection, *, force: bool = False) -> bool:
    """Rafraîchit cartes, impressions et noms. Renvoie vrai si un travail a eu lieu."""
    version = _scryfall_version()
    previous = last_version(conn, SOURCE_SCRYFALL)

    # **Les extensions sont ingérées quoi qu'il arrive**, avant le saut de
    # version. Elles coûtent une poignée de pages là où le catalogue en coûte
    # 390 Mo : les protéger par la même garde ferait qu'une table vide le
    # resterait tant que Scryfall n'aurait pas republié son export.
    print(f"  {scryfall_sets.run(conn)} extensions")

    if not force and previous == version:
        print(f"  catalogue déjà à jour (export du {version[:16]})")
        return False

    print(f"  export Scryfall du {version[:16]} — ingestion")
    try:
        scryfall_ingest.run()
    except Exception as exc:  # noqa: BLE001
        record(conn, SOURCE_SCRYFALL, version=version, items=0, error=str(exc)[:500])
        raise

    with conn.cursor() as cur:
        count = cur.execute("SELECT count(*) FROM public.cards").fetchone()[0]
    record(conn, SOURCE_SCRYFALL, version=version, items=count)
    return True


def refresh_art_hashes(conn: psycopg.Connection) -> int:
    """Calcule les empreintes manquantes — celles des impressions nouvellement
    ingérées. Ne recalcule jamais l'existant."""
    report = index_builder.build(conn)
    if report.hashed:
        with conn.cursor() as cur:
            total = cur.execute("SELECT count(*) FROM public.art_hashes").fetchone()[0]
        record(conn, SOURCE_ART_HASHES, version=None, items=total)
    return report.hashed


def refresh_decks(conn: psycopg.Connection, *, days: int = 30) -> None:
    """Réimporte le corpus de decks.

    La fenêtre est plus courte qu'à l'import initial : les tournois anciens sont
    déjà en base et leur réimport n'apporterait rien qu'un long téléchargement.
    """
    print("  tournois TopDeck.gg")
    try:
        topdeck_ingest.run(days=days)
        with conn.cursor() as cur:
            count = cur.execute(
                "SELECT count(*) FROM public.decks WHERE source_id = 'topdeck'"
            ).fetchone()[0]
        record(conn, SOURCE_TOPDECK, version=f"{days}j", items=count)
    except Exception as exc:  # noqa: BLE001
        record(conn, SOURCE_TOPDECK, version=None, items=0, error=str(exc)[:500])
        print(f"    échec : {exc}")

    print("  précons MTGJSON")
    try:
        mtgjson_ingest.run()
        with conn.cursor() as cur:
            count = cur.execute(
                "SELECT count(*) FROM public.decks WHERE source_id = 'mtgjson'"
            ).fetchone()[0]
        record(conn, SOURCE_MTGJSON, version=None, items=count)
    except Exception as exc:  # noqa: BLE001
        record(conn, SOURCE_MTGJSON, version=None, items=0, error=str(exc)[:500])
        print(f"    échec : {exc}")


def run(*, force: bool = False, skip_decks: bool = False) -> None:
    started = time.time()
    config = SupabaseConfig.load()

    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        print("1/3 — catalogue Scryfall")
        changed = refresh_catalogue(conn, force=force)

        print("2/3 — empreintes manquantes")
        hashed = refresh_art_hashes(conn)
        print(f"  {hashed} nouvelles empreintes")

        if skip_decks:
            print("3/3 — decks ignorés")
        else:
            print("3/3 — corpus de decks")
            refresh_decks(conn)

        print()
        with conn.cursor() as cur:
            for source, version, ran, items, error in cur.execute("""
                SELECT source, source_version, last_run_at, items_processed, last_error
                FROM public.ingestion_state ORDER BY source
            """).fetchall():
                mark = "!" if error else " "
                stamp = ran.strftime("%Y-%m-%d %H:%M")
                print(f" {mark} {source:12} {items:7} éléments   {stamp}   {version or ''}")

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
