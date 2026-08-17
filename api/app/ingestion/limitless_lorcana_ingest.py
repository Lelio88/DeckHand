"""Decks Disney Lorcana de compétition, depuis Limitless TCG.

**Troisième jeu servi par Limitless**, après Pokémon et One Piece, et il dément
une prévision : Lorcana devait être accueilli en « cas Wankul assumé » —
catalogue et prix, sans decks, faute de corpus publié. La sonde a montré le
contraire, `?game=LORCANA` rendant des tournois dont certains portent plus de
cent listes.

**Quatre zones, toutes des listes.** `character`, `action`, `item`, `location`
portent chacune des entrées avec un `count`. Aucune n'est un objet unique — pas
de leader ici, contrairement à One Piece et SWU : un deck Lorcana n'a pas de
carte de commandement, il a soixante cartes et deux encres.

**Le format est déclaré**, et c'est `CONSTRUCTED` pour 21 tournois sur 25. Les
`LIMITED` sont écartés : un deck de draft ne dit pas avec quelles cartes il peut
être rejoué, ce qui est précisément ce que le calcul de complétion doit savoir.
Même raison que les formats maison écartés chez Pokémon et One Piece.

**Le code demande une normalisation, et elle n'est pas celle des autres jeux.**
La source écrit l'extension sur trois chiffres — `set: "008"` — là où le
catalogue Lorcast la nomme `8`. Le numéro, lui, suit la convention habituelle et
`PrintCodeResolver` le ramène déjà à trois chiffres. Sans cette normalisation,
**aucune carte des extensions numérotées ne se résoudrait**, et l'échec serait
muet : les decks entreraient vides et seraient écartés comme lacunaires.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.limitless_lorcana_ingest
    #   --days N     fenêtre de collecte (défaut 730, le corpus étant clairsemé)
    #   --before ISO borne haute, pour reprendre une course coupée
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
import time
import uuid
from typing import Any, Iterable, Iterator

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.card_resolver import PrintCodeResolver
from app.ingestion.deck_ingest import store_deck
from app.ingestion.limitless_onepiece_ingest import _get, parse_date
from app.ingestion.state import record

API = "https://play.limitlesstcg.com/api"

LIMITLESS_GAME = "LORCANA"
GAME = "lorcana"
SOURCE_ID = "limitless"
FORMAT = "lorcana_core"

USER_AGENT = "DeckHand/1.0 (collection manager; contact heianenterpriseyt@gmail.com)"
PAUSE_SECONDS = 1.2
PAGE_SIZE = 50
MAX_PAGES = 60

#: Les quatre zones, toutes des listes d'entrées comptées.
ZONES = ("character", "action", "item", "location")

#: Le format construit de la source. Les `LIMITED` sont des drafts.
KEPT_FORMATS = {"CONSTRUCTED", ""}

#: Plancher d'acceptation d'un deck.
#:
#: Le format impose 60 cartes. 45 laisse passer un deck amputé de quelques codes
#: non résolus sans laisser entrer une liste tronquée.
MIN_MAIN_CARDS = 45


def normalise_set(code: str) -> str:
    """`008` -> `8`, `P1` -> `P1`.

    **Les zéros de tête n'existent que du côté des decks.** Le catalogue nomme
    ses extensions `1` à `13` et ses promos `P1`, `D23`, `Coconut` ; la source de
    decks écrit les numériques sur trois chiffres. Ne toucher qu'aux codes
    entièrement numériques : `P1` doit rester `P1`, et `int("P1")` lèverait.
    """
    propre = (code or "").strip().upper()
    if propre.isdigit():
        return str(int(propre))
    return propre


def code_of(entry: dict[str, Any]) -> str | None:
    """`{'set': '008', 'number': '045'}` -> `8-045`."""
    set_code = normalise_set(entry.get("set") or "")
    number = str(entry.get("number") or "").strip()
    if not set_code or not number:
        return None
    return PrintCodeResolver.normalise(f"{set_code}-{number}")


def load_code_index(conn: psycopg.Connection) -> dict[str, str]:
    """`{code d'impression: oracle_id}` pour le catalogue Lorcana.

    **Lu de la base et non de la source**, contrairement à One Piece. Ici le
    couple extension-numéro est *écrit* dans `card_prints` — l'ingestion l'y a
    posé —, alors que le code One Piece n'existait qu'en mémoire de la sonde.
    Une lecture suffit donc, sans requête réseau.
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT p.set_code, p.collector_number, p.oracle_id::text
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = %s
            """,
            (GAME,),
        ).fetchall()

    index: dict[str, str] = {}
    for set_code, number, oracle_id in rows:
        code = PrintCodeResolver.normalise(f"{normalise_set(set_code)}-{number}")
        # **Le premier gagne, et c'est sans conséquence.** Un même couple
        # extension-numéro ne désigne qu'une carte ; s'il en désignait deux, ce
        # serait le catalogue qu'il faudrait corriger, pas ce rapprochement.
        index.setdefault(code, oracle_id)
    return index


def tournaments(
    client: httpx.Client, *, days: int, before: dt.datetime | None = None
) -> Iterator[dict[str, Any]]:
    """Tournois Lorcana de la fenêtre, du plus récent au plus ancien."""
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    for page in range(1, MAX_PAGES + 1):
        rows = _get(
            client,
            f"{API}/tournaments?game={LIMITLESS_GAME}&limit={PAGE_SIZE}&page={page}",
        )
        time.sleep(PAUSE_SECONDS)
        if not rows:
            return
        perimee = True
        for row in rows:
            when = parse_date(row.get("date"))
            if when and when < cutoff:
                continue
            perimee = False
            if before is not None and when is not None and when > before:
                continue
            yield row
        if perimee:
            return


def boards(decklist: dict[str, Any] | None) -> dict[str, int]:
    """Une decklist aplatie en `{code: quantité}`.

    Les quatre zones sont fusionnées : ce sont quatre familles d'un même deck de
    soixante cartes, pas quatre zones de jeu disjointes comme l'Extra Deck de
    Yu-Gi-Oh.
    """
    cards: dict[str, int] = {}
    if not decklist:
        return cards
    for zone in ZONES:
        entries = decklist.get(zone)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            code = code_of(entry)
            count = int(entry.get("count") or 0)
            if not code or count <= 0:
                continue
            cards[code] = cards.get(code, 0) + count
    return cards


def deck_name(entry: dict[str, Any], tournament: dict[str, Any]) -> str:
    """Nom d'archétype quand la source en donne un, nom du tournoi sinon."""
    archetype = (entry.get("deck") or {}).get("name")
    if archetype:
        return str(archetype)
    return str(tournament.get("name") or "Deck Limitless")


def store_standings(
    conn: psycopg.Connection,
    standings: Iterable[dict[str, Any]],
    *,
    tournament: dict[str, Any],
    tournament_id: str,
    recorded_at: dt.datetime | None,
    resolver: PrintCodeResolver,
) -> tuple[int, int]:
    """Enregistre les decks d'un tournoi, commite, et rend (gardés, écartés)."""
    inserted = skipped = 0
    for entry in standings:
        cards = boards(entry.get("decklist"))
        if not cards:
            continue
        stored = store_deck(
            conn,
            source_id=SOURCE_ID,
            # Le joueur, et non son classement — Limitless rend `placing: null`
            # pour tout joueur non classé, si bien que tous partageraient la même
            # clé et s'écraseraient. Le défaut a coûté un quart du corpus Pokémon.
            external_id=f"{tournament_id}-{entry.get('player')}",
            name=deck_name(entry, tournament),
            fmt=FORMAT,
            tier="competitive",
            mainboard=cards,
            sideboard={},
            resolver=resolver,
            source_url=f"https://play.limitlesstcg.com/tournament/{tournament_id}",
            recorded_at=recorded_at,
            game=GAME,
            min_main_cards=MIN_MAIN_CARDS,
        )
        if stored:
            inserted += 1
        else:
            skipped += 1
    conn.commit()
    return inserted, skipped


def ingest(days: int, before: dt.datetime | None) -> tuple[int, int, int]:
    """Ingère la fenêtre. Rend (tournois, decks gardés, decks écartés)."""
    cfg = SupabaseConfig.load()
    tournois = gardes = ecartes = 0
    manques: list[str] = []
    resolver: PrintCodeResolver | None = None

    with psycopg.connect(cfg.db_url) as conn:
        index = load_code_index(conn)
        print(f"catalogue : {len(index)} codes d'impression", flush=True)
        resolver = PrintCodeResolver(index)

        with httpx.Client(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            for tournament in tournaments(client, days=days, before=before):
                fmt = str(tournament.get("format") or "").upper()
                if fmt not in KEPT_FORMATS:
                    continue
                tournament_id = str(tournament.get("id") or "")
                if not tournament_id:
                    continue
                try:
                    standings = _get(
                        client, f"{API}/tournaments/{tournament_id}/standings"
                    )
                except httpx.HTTPError as exc:
                    manques.append(tournament_id)
                    print(f"  ! {tournament_id} perdu : {exc}", flush=True)
                    continue
                time.sleep(PAUSE_SECONDS)

                inserted, skipped = store_standings(
                    conn,
                    standings,
                    tournament=tournament,
                    tournament_id=tournament_id,
                    recorded_at=parse_date(tournament.get("date")),
                    resolver=resolver,
                )
                tournois += 1
                gardes += inserted
                ecartes += skipped
                if inserted:
                    print(
                        f"  {tournament.get('name', '')[:44]:44} {inserted:3} decks",
                        flush=True,
                    )

        record(
            conn,
            SOURCE_ID + ":lorcana",
            version=str(dt.date.today()),
            items=gardes,
        )
        conn.commit()

    print()
    print(f"  {tournois} tournois parcourus")
    print(f"  {gardes} decks enregistrés, {ecartes} écartés (trop lacunaires)")
    if manques:
        print(f"  {len(manques)} tournois perdus malgré les reprises — relancer")
    if resolver is not None:
        unresolved = resolver.unresolved
        if unresolved:
            print(f"  {len(unresolved)} codes non résolus, les plus fréquents :")
            for code, n in sorted(unresolved.items(), key=lambda kv: -kv[1])[:8]:
                print(f"      {code:16} {n}")
    return tournois, gardes, ecartes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # **730 jours et non 90.** Le corpus est clairsemé : la sonde a trouvé un
    # tournoi de juillet puis un trou jusqu'en février. Une fenêtre courte
    # rendrait quelques dizaines de decks, trop peu pour un gabarit.
    parser.add_argument("--days", type=int, default=730)
    parser.add_argument(
        "--before",
        type=lambda s: dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc),
        default=None,
    )
    args = parser.parse_args(argv)
    ingest(args.days, args.before)
    return 0


if __name__ == "__main__":
    sys.exit(main())
