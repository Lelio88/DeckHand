"""Import des précons Commander officiels depuis MTGJSON.

**Pourquoi cette source est indispensable.** TopDeck.gg n'expose aucun Commander
multijoueur, et les listes de cEDH relevées ailleurs valent 10 000 $ pièce. Sans
les précons, l'onglet Commander resterait vide — et surtout, DeckHand n'aurait
que des decks marqués `competitive`, dont aucun n'est réellement à portée d'une
collection ordinaire. Ces decks sont les premiers à mériter l'étiquette
`accessible`.

MTGJSON est sous licence MIT : la redistribution est libre, contrairement à
toutes les autres sources du projet.

**Résolution directe.** Chaque carte porte son `scryfallOracleId`, ce qui évite
la résolution par nom et son cortège d'ambiguïtés. Reste à vérifier que
l'identifiant existe dans notre catalogue, qui ne retient que les cartes légales
dans les formats couverts.

L'archive complète est téléchargée en une fois plutôt que 190 fichiers un à un :
plus rapide, et plus correct vis-à-vis d'un service gratuit.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import sys
import zipfile
from collections.abc import Iterator
from typing import Any

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.card_resolver import OracleResolver
from app.ingestion.deck_ingest import IngestReport, store_deck

SOURCE_ID = "mtgjson"
ALL_DECKS_URL = "https://mtgjson.com/api/v5/AllDeckFiles.zip"
USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

COMMANDER_DECK_TYPE = "Commander Deck"


class MtgjsonError(RuntimeError):
    """Échec d'un échange avec MTGJSON."""


def _cards(entries: list[dict[str, Any]] | None) -> dict[str, int]:
    """Convertit une liste de cartes MTGJSON en `oracle_id` -> quantité."""
    out: dict[str, int] = {}
    for entry in entries or []:
        oracle_id = (entry.get("identifiers") or {}).get("scryfallOracleId")
        count = entry.get("count", 1)
        if not oracle_id:
            continue
        try:
            quantity = int(count)
        except (TypeError, ValueError):
            continue
        if quantity > 0:
            out[oracle_id] = out.get(oracle_id, 0) + quantity
    return out


def fetch_commander_decks() -> Iterator[dict[str, Any]]:
    """Télécharge l'archive des decks et livre les précons Commander."""
    try:
        response = httpx.get(
            ALL_DECKS_URL,
            headers={"User-Agent": USER_AGENT},
            timeout=300,
            follow_redirects=True,
        )
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise MtgjsonError(f"archive des decks injoignable : {exc}") from exc

    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        for name in archive.namelist():
            if not name.endswith(".json"):
                continue
            try:
                payload = json.loads(archive.read(name))
            except json.JSONDecodeError:
                continue
            deck = payload.get("data") or {}
            if deck.get("type") == COMMANDER_DECK_TYPE:
                deck["_fileName"] = name
                yield deck


def known_oracle_ids(conn: psycopg.Connection) -> set[str]:
    with conn.cursor() as cur:
        rows = cur.execute("SELECT oracle_id::text FROM public.cards").fetchall()
    return {row[0] for row in rows}


def run() -> None:
    config = SupabaseConfig.load()

    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        print("chargement du catalogue…")
        known = known_oracle_ids(conn)
        print(f"  {len(known)} cartes connues\n")

        resolver = OracleResolver(known)
        report = IngestReport()

        print("téléchargement de l'archive MTGJSON (peut prendre une minute)…")
        for deck in fetch_commander_decks():
            commander = _cards(deck.get("commander"))
            mainboard = _cards(deck.get("mainBoard"))

            # Le commandant est livré à part par MTGJSON, mais fait partie des
            # 100 cartes du deck : il doit compter dans le calcul de complétion.
            for oracle_id, quantity in commander.items():
                mainboard[oracle_id] = mainboard.get(oracle_id, 0) + quantity

            commander_id = next(
                (oid for oid in commander if oid in known),
                None,
            )
            released = deck.get("releaseDate")
            recorded_at = (
                dt.datetime.fromisoformat(released).replace(tzinfo=dt.timezone.utc)
                if released
                else None
            )

            stored = store_deck(
                conn,
                source_id=SOURCE_ID,
                external_id=deck.get("_fileName") or deck["name"],
                name=deck["name"],
                fmt="commander",
                tier="accessible",
                mainboard=mainboard,
                sideboard=_cards(deck.get("sideBoard")),
                resolver=resolver,
                commander_oracle_id=commander_id,
                source_url=deck.get("source"),
                recorded_at=recorded_at,
            )
            if stored:
                report.inserted += 1
            else:
                report.skipped_incomplete += 1

            if (report.inserted + report.skipped_incomplete) % 20 == 0:
                conn.commit()
                print(f"  {report.inserted} précons", end="\r", flush=True)

        conn.commit()
        report.unresolved_names = resolver.unresolved
        print(report.summary())


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit("interrompu")
