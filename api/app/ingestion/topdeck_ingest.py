"""Import du corpus de tournoi depuis TopDeck.gg.

Alimente les formats 60 cartes de Magic et le format construit de Riftbound. Les
decks y sont marqués `competitive` : ce sont des listes de compétition, souvent
hors de portée d'une collection ordinaire. L'étiquette permet à l'interface de
les distinguer des précons accessibles, sans quoi la promesse « à quelques
cartes près » deviendrait mensongère.

**Riftbound n'a pas demandé de nouvelle source.** Le corpus manquait depuis le
début — aucun agrégateur communautaire n'expose d'API, et scraper est exclu par
le garde-fou §IV.1. Il se trouve que TopDeck.gg, déjà employé pour Magic sous
clé et sous obligation d'attribution, couvre le jeu. Deux différences, toutes
deux à notre avantage : les cartes portent un **code d'impression** exact plutôt
qu'un nom à résoudre, et la **Légende** occupe naturellement la place d'un
commandant.
"""

from __future__ import annotations

import datetime as dt
import sys

import psycopg

from app.config import SupabaseConfig, TopdeckConfig
from app.ingestion.card_resolver import CardResolver, PrintCodeResolver
from app.ingestion.deck_ingest import IngestReport, load_name_index, store_deck
from app.ingestion.topdeck_client import (
    FORMAT_CONSTRUCTED,
    FORMAT_MODERN,
    FORMAT_PAUPER,
    GAME_RIFTBOUND,
    fetch_decks,
)

SOURCE_ID = "topdeck"
GAME = "riftbound"

#: Nombre minimal de cartes pour qu'une liste Riftbound compte comme un deck.
#:
#: **Tiré de la distribution mesurée, non d'une lecture des règles** : sur 2 501
#: participations, 2 459 comptent exactement 56 cartes hors réserve, et l'écart
#: total va de 55 à 65 — sauf une liste à 5 cartes, visiblement enregistrée à
#: moitié à la source. Quarante est donc très en deçà de tout deck réel et très
#: au-dessus d'un fragment : le seuil écarte l'accident sans juger le jeu.
MIN_RIFTBOUND_CARDS = 40

# Libellé côté API -> valeur de la colonne `format`, contrainte en minuscules.
FORMATS = {FORMAT_PAUPER: "pauper", FORMAT_MODERN: "modern"}


def load_print_code_index(conn: psycopg.Connection, game: str) -> dict[str, str]:
    """Index code d'impression -> `oracle_id`, pour un jeu.

    Le numéro est cadré sur trois chiffres, comme le fait `PrintCodeResolver` :
    la source écrit `OGN-042` quand le catalogue retient `42`, et une comparaison
    littérale échouerait sur toute carte numérotée sous 100.

    Deux impressions d'une même carte partagent son `oracle_id` : le
    dictionnaire peut donc contenir plusieurs codes pointant vers la même
    valeur, ce qui est exactement ce qu'on veut — un deck cite une impression,
    la collection possède une carte.
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT upper(p.set_code) || '-' ||
                   CASE WHEN p.collector_number ~ '^[0-9]+$'
                        THEN lpad(p.collector_number, 3, '0')
                        ELSE upper(p.collector_number) END,
                   p.oracle_id::text
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = %s AND p.collector_number IS NOT NULL
            """,
            (game,),
        ).fetchall()
    return {code: oracle_id for code, oracle_id in rows}


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


def ingest_riftbound(
    conn: psycopg.Connection,
    api_key: str,
    index: dict[str, str],
    days: int = 180,
) -> IngestReport:
    """Importe le format construit de Riftbound.

    **La fenêtre est plus large que pour Magic** — 180 jours contre 90. Le jeu
    est sorti fin 2025 : une fenêtre de trois mois amputerait la moitié de son
    histoire compétitive, et un corpus mince est précisément ce qui rendrait le
    moteur de suggestion inutile.
    """
    resolver = PrintCodeResolver(index)
    report = IngestReport()

    for deck in fetch_decks(
        api_key, FORMAT_CONSTRUCTED, days=days, game=GAME_RIFTBOUND
    ):
        recorded_at = (
            dt.datetime.fromtimestamp(deck.started_at, tz=dt.timezone.utc)
            if deck.started_at
            else None
        )
        # La Légende occupe la place d'un commandant. Elle est résolue à part,
        # mais reste dans le pan principal : on doit la posséder pour jouer.
        legend_oracle_id = (
            index.get(PrintCodeResolver.normalise(deck.legend)) if deck.legend else None
        )
        stored = store_deck(
            conn,
            source_id=SOURCE_ID,
            external_id=deck.external_id,
            name=deck.name,
            fmt="constructed",
            tier="competitive",
            mainboard=deck.mainboard,
            sideboard=deck.sideboard,
            resolver=resolver,
            commander_oracle_id=legend_oracle_id,
            recorded_at=recorded_at,
            game=GAME,
            min_main_cards=MIN_RIFTBOUND_CARDS,
        )
        if stored:
            report.inserted += 1
        else:
            report.skipped_incomplete += 1

        if (report.inserted + report.skipped_incomplete) % 50 == 0:
            conn.commit()
            print(f"  riftbound : {report.inserted} decks", end="\r", flush=True)

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


def run_riftbound(days: int = 180) -> None:
    supabase = SupabaseConfig.load()
    topdeck = TopdeckConfig.load()

    with psycopg.connect(supabase.db_url, connect_timeout=30) as conn:
        print("chargement de l'index des codes d'impression…")
        index = load_print_code_index(conn, GAME)
        print(f"  {len(index)} codes connus\n")

        print("--- Riftbound / Constructed ---")
        report = ingest_riftbound(conn, topdeck.api_key, index, days)
        print(report.summary())


if __name__ == "__main__":
    try:
        if "--riftbound" in sys.argv:
            run_riftbound()
        else:
            run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
