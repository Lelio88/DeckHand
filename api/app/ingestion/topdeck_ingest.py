"""Import du corpus de tournoi depuis TopDeck.gg.

Alimente les formats 60 cartes. Les decks y sont marqués `competitive` : ce sont
des listes de compétition, souvent hors de portée d'une collection ordinaire.
L'étiquette permet à l'interface de les distinguer des précons accessibles, sans
quoi la promesse « à quelques cartes près » deviendrait mensongère.
"""

from __future__ import annotations

import datetime as dt
import sys

import psycopg

from app.config import SupabaseConfig, TopdeckConfig
from app.ingestion.card_resolver import CardResolver
from app.ingestion.deck_ingest import IngestReport, load_name_index, store_deck
from app.ingestion.topdeck_client import FORMAT_MODERN, FORMAT_PAUPER, fetch_decks

SOURCE_ID = "topdeck"

# Libellé côté API -> valeur de la colonne `format`, contrainte en minuscules.
FORMATS = {FORMAT_PAUPER: "pauper", FORMAT_MODERN: "modern"}


def ingest_format(
    conn: psycopg.Connection,
    api_key: str,
    api_format: str,
    db_format: str,
    index: dict[str, str],
    days: int = 90,
) -> IngestReport:
    resolver = CardResolver(index)
    report = IngestReport()

    for deck in fetch_decks(api_key, api_format, days=days):
        recorded_at = (
            dt.datetime.fromtimestamp(deck.started_at, tz=dt.timezone.utc)
            if deck.started_at
            else None
        )
        stored = store_deck(
            conn,
            source_id=SOURCE_ID,
            external_id=deck.external_id,
            name=deck.name,
            fmt=db_format,
            tier="competitive",
            mainboard=deck.mainboard,
            sideboard=deck.sideboard,
            resolver=resolver,
            recorded_at=recorded_at,
        )
        if stored:
            report.inserted += 1
        else:
            report.skipped_incomplete += 1

        if (report.inserted + report.skipped_incomplete) % 25 == 0:
            conn.commit()
            print(f"  {db_format} : {report.inserted} decks", end="\r", flush=True)

    conn.commit()
    report.unresolved_names = resolver.unresolved
    return report


def run(days: int = 90) -> None:
    supabase = SupabaseConfig.load()
    topdeck = TopdeckConfig.load()

    with psycopg.connect(supabase.db_url, connect_timeout=30) as conn:
        print("chargement de l'index de noms…")
        index = load_name_index(conn)
        print(f"  {len(index)} noms connus\n")

        for api_format, db_format in FORMATS.items():
            print(f"--- {api_format} ---")
            report = ingest_format(conn, topdeck.api_key, api_format, db_format, index, days)
            print(report.summary())
            print()


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
