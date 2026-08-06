"""Ingestion du catalogue Scryfall vers Postgres.

Deux passes, dans cet ordre imposé par les clés étrangères :

1. `oracle_cards` → table `cards`. Seules les cartes légales dans au moins un des
   trois formats couverts sont retenues.
2. `all_cards` → tables `card_prints` et `card_search_names`.

**Pourquoi une seule impression par carte.** Le catalogue complet compte plusieurs
centaines de milliers d'impressions ; les stocker toutes, index de recherche compris,
saturerait les 500 Mo du plan Supabase gratuit. On ne conserve donc que l'impression
**la moins chère** de chaque carte, qui est précisément celle qui sert de référence à
la valorisation de collection et au coût de complétion. Le schéma, lui, reste capable
d'en accueillir davantage : c'est l'ingestion qui filtre, pas la structure.

De même, un seul nom français est retenu par carte plutôt qu'un par impression — les
traductions ne varient pas d'une édition à l'autre.

`all_cards` est parcouru plutôt que `default_cards` parce qu'il est le seul à contenir
les impressions localisées, indispensables à une collection mêlant français et anglais.
Il pèse environ 390 Mo compressés : le parcours prend plusieurs minutes.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable, Iterator
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from app.config import SupabaseConfig
from app.ingestion.scryfall_client import BULK_ALL, BULK_ORACLE, stream_bulk
from app.ingestion.scryfall_parse import (
    CardPrint,
    is_relevant,
    normalize_name,
    parse_card,
    parse_print,
    search_names_for,
)

BATCH_SIZE = 1000


def _batched(items: Iterable[Any], size: int) -> Iterator[list[Any]]:
    batch: list[Any] = []
    for item in items:
        batch.append(item)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


def _price_rank(printing: CardPrint) -> tuple[int, float]:
    """Clé de comparaison pour désigner l'impression la moins chère.

    Une impression sans prix connu est classée après toutes celles qui en ont un :
    elle ne sert que de repli quand la carte n'est cotée nulle part.
    """
    if printing.price_eur is not None:
        return (0, printing.price_eur)
    if printing.price_usd is not None:
        return (1, printing.price_usd)
    return (2, 0.0)


def ingest_cards(conn: psycopg.Connection) -> set[str]:
    """Remplit `cards` et renvoie les `oracle_id` retenus.

    L'écriture est idempotente : relancer l'ingestion met à jour les lignes
    existantes au lieu d'échouer, ce qui permet de rafraîchir le catalogue quand
    Scryfall publie de nouvelles cartes ou révise des légalités.
    """
    statement = """
        INSERT INTO public.cards (oracle_id, name, mana_cost, cmc, type_line,
                                  oracle_text, color_identity, legalities, layout,
                                  updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (oracle_id) DO UPDATE SET
            name           = EXCLUDED.name,
            mana_cost      = EXCLUDED.mana_cost,
            cmc            = EXCLUDED.cmc,
            type_line      = EXCLUDED.type_line,
            oracle_text    = EXCLUDED.oracle_text,
            color_identity = EXCLUDED.color_identity,
            legalities     = EXCLUDED.legalities,
            layout         = EXCLUDED.layout,
            updated_at     = NOW()
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        for payload in stream_bulk(BULK_ORACLE):
            if not is_relevant(payload.get("legalities") or {}):
                continue
            try:
                card = parse_card(payload)
            except (ValueError, KeyError):
                continue
            yield (
                card.oracle_id,
                card.name,
                card.mana_cost,
                card.cmc,
                card.type_line,
                card.oracle_text,
                card.color_identity,
                Jsonb(card.legalities),
                card.layout,
            )

    kept: set[str] = set()
    with conn.cursor() as cur:
        for batch in _batched(rows(), BATCH_SIZE):
            cur.executemany(statement, batch)
            kept.update(row[0] for row in batch)
            conn.commit()
            print(f"  cartes ingérées : {len(kept)}", end="\r", flush=True)

    print(f"  cartes ingérées : {len(kept)}      ")
    return kept


def collect_prints_and_names(
    known: set[str],
) -> tuple[dict[str, CardPrint], dict[str, tuple[str, str]]]:
    """Parcourt `all_cards` et retient, par carte, l'impression la moins chère
    et un nom français.

    Le parcours est en flux mais l'accumulation tient en mémoire : une entrée par
    carte du catalogue, soit quelques dizaines de milliers, pas plusieurs centaines
    de milliers.
    """
    cheapest: dict[str, CardPrint] = {}
    french: dict[str, tuple[str, str]] = {}
    seen = 0

    for payload in stream_bulk(BULK_ALL):
        seen += 1
        if seen % 50_000 == 0:
            print(
                f"  impressions parcourues : {seen} — retenues : {len(cheapest)}",
                end="\r",
                flush=True,
            )

        oracle_id = payload.get("oracle_id")
        if not oracle_id or oracle_id not in known:
            continue

        try:
            printing = parse_print(payload)
        except KeyError:
            continue

        best = cheapest.get(oracle_id)
        if best is None or _price_rank(printing) < _price_rank(best):
            cheapest[oracle_id] = printing

        if printing.lang == "fr" and printing.printed_name and oracle_id not in french:
            french[oracle_id] = (printing.printed_name, normalize_name(printing.printed_name))

    print(f"  impressions parcourues : {seen} — retenues : {len(cheapest)}      ")
    return cheapest, french


def write_prints(conn: psycopg.Connection, cheapest: dict[str, CardPrint]) -> int:
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number, rarity,
                                        art_crop_url, price_eur, price_usd, released_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE SET
            price_eur = EXCLUDED.price_eur,
            price_usd = EXCLUDED.price_usd
    """
    rows = (
        (
            p.scryfall_id,
            p.oracle_id,
            p.lang,
            p.printed_name,
            p.set_code,
            p.set_name,
            p.collector_number,
            p.rarity,
            p.art_crop_url,
            p.price_eur,
            p.price_usd,
            p.released_at,
        )
        for p in cheapest.values()
    )

    written = 0
    with conn.cursor() as cur:
        for batch in _batched(rows, BATCH_SIZE):
            cur.executemany(statement, batch)
            written += len(batch)
            conn.commit()
    return written


def write_search_names(
    conn: psycopg.Connection,
    cards: dict[str, str],
    french: dict[str, tuple[str, str]],
) -> int:
    """Écrit l'index de saisie : le nom oracle anglais, plus le nom français connu."""
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    def rows() -> Iterator[tuple[str, str, str, str]]:
        for oracle_id, name in cards.items():
            yield (oracle_id, name, normalize_name(name), "en")
            fr = french.get(oracle_id)
            if fr:
                yield (oracle_id, fr[0], fr[1], "fr")

    written = 0
    with conn.cursor() as cur:
        for batch in _batched(rows(), BATCH_SIZE):
            cur.executemany(statement, batch)
            written += len(batch)
            conn.commit()
    return written


def run() -> None:
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        print("1/3 — catalogue oracle")
        kept = ingest_cards(conn)

        print("2/3 — impressions et noms localisés (export volumineux, patience)")
        cheapest, french = collect_prints_and_names(kept)

        print("3/3 — écriture")
        with conn.cursor() as cur:
            names = dict(
                cur.execute("SELECT oracle_id::text, name FROM public.cards").fetchall()
            )
        printed = write_prints(conn, cheapest)
        indexed = write_search_names(conn, names, french)

        print(
            f"\nterminé — {len(kept)} cartes, {printed} impressions, "
            f"{indexed} entrées de recherche ({len(french)} noms français)"
        )


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
