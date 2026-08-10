"""Ingestion du catalogue Scryfall vers Postgres.

Deux passes, dans cet ordre imposé par les clés étrangères :

1. `oracle_cards` → table `cards`. Seules les cartes légales dans au moins un des
   trois formats couverts sont retenues.
2. `all_cards` → tables `card_prints` et `card_search_names`.

**Quelles impressions sont conservées.** Le catalogue complet compte 538 794 objets,
toutes langues confondues. Sont retenues les impressions **anglaises et françaises** des
cartes du périmètre, soit 161 304 lignes (103 239 en, 58 065 fr) pour ~33 Mo de texte —
mesuré, pas estimé. C'est ce qui permet à l'utilisateur de désigner l'édition qu'il
possède réellement, et donc de valoriser sa collection au bon prix.

Les autres langues sont écartées : elles tripleraient le volume sans servir une
collection franco-anglaise.

**Pourquoi aucun plafond par carte.** Ne garder que les N impressions les moins chères
ferait disparaître exactement l'édition qu'on cherche quand elle est ancienne et cotée —
or c'est précisément celle qu'on veut pouvoir désigner. Le plafond trahirait l'objectif.
Quelques cartes ont plus de mille impressions (les terrains de base) : c'est au
sélecteur de les rendre navigables, pas à l'ingestion de les amputer.

Un seul nom français est retenu par carte plutôt qu'un par impression — les traductions
ne varient pas d'une édition à l'autre.

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
    should_ingest,
    normalize_name,
    parse_card,
    parse_print,
    search_names_for,
)

BATCH_SIZE = 1000

# Langues conservées. Une collection franco-anglaise n'a que faire du japonais, et
# chaque langue supplémentaire alourdit la table d'environ 100 000 lignes.
KEEP_LANGS = frozenset({"en", "fr"})

# `DO UPDATE` sur les seuls prix : le reste d'une impression (édition, numéro de
# collection, illustration) est immuable ; seule sa cote dérive au fil des jours.
PRINT_UPSERT = """
    INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                    set_code, set_name, collector_number, rarity,
                                    art_crop_url, price_eur, price_usd, released_at,
                                    price_eur_foil, price_usd_foil, finishes,
                                    illustration_id, full_art)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT (scryfall_id) DO UPDATE SET
        price_eur      = EXCLUDED.price_eur,
        price_usd      = EXCLUDED.price_usd,
        price_eur_foil = EXCLUDED.price_eur_foil,
        price_usd_foil = EXCLUDED.price_usd_foil,
        finishes        = EXCLUDED.finishes,
        illustration_id = EXCLUDED.illustration_id,
        full_art        = EXCLUDED.full_art
"""


def _print_row(p: CardPrint) -> tuple[Any, ...]:
    return (
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
        p.price_eur_foil,
        p.price_usd_foil,
        p.finishes,
        p.illustration_id,
        p.full_art,
    )


def _batched(items: Iterable[Any], size: int) -> Iterator[list[Any]]:
    batch: list[Any] = []
    for item in items:
        batch.append(item)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


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
            if not should_ingest(payload):
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


def ingest_prints_and_names(
    conn: psycopg.Connection, known: set[str]
) -> tuple[int, dict[str, tuple[str, str]]]:
    """Écrit les impressions du périmètre et renvoie un nom français par carte.

    L'écriture se fait **au fil du parcours**, par lots : accumuler les 161 000
    impressions avant d'écrire coûterait une centaine de mégaoctets de mémoire sans
    rien apporter. Seuls les noms français sont retenus en mémoire — un par carte,
    donc quelques dizaines de milliers d'entrées légères.
    """
    french: dict[str, tuple[str, str]] = {}
    seen = 0
    written = 0

    def relevant() -> Iterator[CardPrint]:
        nonlocal seen
        for payload in stream_bulk(BULK_ALL):
            seen += 1
            if seen % 50_000 == 0:
                print(f"  parcourues : {seen} — écrites : {written}", end="\r", flush=True)

            oracle_id = payload.get("oracle_id")
            if not oracle_id or oracle_id not in known:
                continue
            if payload.get("lang") not in KEEP_LANGS:
                continue

            try:
                printing = parse_print(payload)
            except KeyError:
                continue

            if printing.lang == "fr" and printing.printed_name and oracle_id not in french:
                french[oracle_id] = (
                    printing.printed_name,
                    normalize_name(printing.printed_name),
                )
            yield printing

    with conn.cursor() as cur:
        for batch in _batched(relevant(), BATCH_SIZE):
            cur.executemany(PRINT_UPSERT, [_print_row(item) for item in batch])
            written += len(batch)
            conn.commit()

    print(f"  parcourues : {seen} — écrites : {written}      ")
    return written, french


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


def backfill_face_names(conn: psycopg.Connection) -> int:
    """Ajoute les noms de faces manquants à l'index de recherche.

    Rattrapage ciblé : les premières ingestions n'indexaient que le nom complet
    des cartes recto-verso, si bien que « Delver of Secrets » restait
    introuvable. Parcourt l'export oracle, bien plus léger que le catalogue
    complet, et n'ajoute que les entrées absentes.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    def rows() -> Iterator[tuple[str, str, str, str]]:
        for payload in stream_bulk(BULK_ORACLE):
            if not payload.get("card_faces"):
                continue
            if not should_ingest(payload):
                continue
            oracle_id = payload.get("oracle_id")
            if not oracle_id:
                continue
            for display, normalized, lang in search_names_for(payload):
                yield (oracle_id, display, normalized, lang)

    added = 0
    with conn.cursor() as cur:
        for batch in _batched(rows(), BATCH_SIZE):
            cur.executemany(statement, batch)
            added += len(batch)
            conn.commit()
            print(f"  entrées de faces traitées : {added}", end="\r", flush=True)

    print(f"  entrées de faces traitées : {added}      ")
    return added


def run() -> None:
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        print("1/3 — catalogue oracle")
        kept = ingest_cards(conn)

        print("2/3 — impressions et noms localisés (export volumineux, patience)")
        printed, french = ingest_prints_and_names(conn, kept)

        print("3/3 — index de saisie")
        with conn.cursor() as cur:
            names = dict(
                cur.execute("SELECT oracle_id::text, name FROM public.cards").fetchall()
            )
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
