"""Decks One Piece de compétition, depuis Limitless TCG.

**Deuxième jeu servi par Limitless**, après Pokémon, et la même API rend les
deux — `?game=OP` au lieu de `?game=PTCG`. Ce module n'est pourtant pas un
paramètre du connecteur Pokémon, et c'est délibéré : la forme des listes diffère
sur trois points qui touchent chacun une décision, pas un réglage.

**1. Le leader est un objet, pas une zone.** Les trois autres rubriques
(`character`, `event`, `stage`) portent une liste d'entrées avec un `count` ;
`leader` porte un objet unique, sans `count`. Une première version du banc l'a
rangé parmi les zones et l'a lu comme une liste : `isinstance(…, list)` était
faux, la rubrique était sautée sans un mot, et le rapport annonçait « 0 leaders
distincts » — un zéro qui se lit comme une absence alors qu'il signalait une
forme inattendue. Le leader va dans `decks.commander_oracle_id`, comme celui de
SWU et le général de Commander : **il ne compte pas** dans les cinquante cartes.

**2. La source ne publie aucun format.** `format` vaut `null` sur les 60
tournois sondés, là où Pokémon rend `STANDARD`. Il n'y a donc rien à
rapprocher : tous les decks sont rangés en `op_standard`, le seul format
construit du jeu.

**3. Un tournoi sur deux seulement porte des listes** — 51,7 % contre 99 % chez
Pokémon. Ce n'est pas un défaut : les petits tournois de boutique sont déclarés
sur Limitless sans que les joueurs y déposent leur decklist. Le connecteur les
traverse sans rien écrire.

**Le code se reconstitue, et c'est mesuré.** Chaque entrée porte `set` et
`number` séparément (`OP07` + `022`), quand le catalogue porte un `card_set_id`
d'un seul tenant. C'est exactement la reconstitution qui a échoué sur les prix,
où `OP14-EB04` agrégeait deux extensions ; ici la source publie l'extension
**telle qu'elle est imprimée sur la carte**, et la reconstitution résout 88,7 %
des lignes. Le reste tient à quatre decks de démarrage (`ST31` à `ST34`) que le
catalogue n'a pas encore — le même retard de source que l'extension `OP17` côté
prix, et il se comblera de lui-même.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.limitless_onepiece_ingest
    #   --days N     fenêtre de collecte (défaut 90)
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
from app.ingestion.state import record

API = "https://play.limitlesstcg.com/api"

#: L'identifiant du jeu chez Limitless. `ONEPIECE` et `OPTCG` rendent une liste
#: vide sans erreur — un 200 sur zéro tournoi, qui se lit comme « la fenêtre est
#: creuse » plutôt que comme « ce nom n'existe pas ».
LIMITLESS_GAME = "OP"

GAME = "onepiece"
SOURCE_ID = "limitless"
FORMAT = "op_standard"

USER_AGENT = "DeckHand/1.0 (collection manager; contact heianenterpriseyt@gmail.com)"
#: La source coupe à 429 quand on la presse : 1,2 s tient sur une course longue.
PAUSE_SECONDS = 1.2
PAGE_SIZE = 50
MAX_PAGES = 60

#: Les trois rubriques qui portent une liste d'entrées comptées.
ZONES = ("character", "event", "stage")

#: Plancher d'acceptation d'un deck, hors leader.
#:
#: Le corpus est **exceptionnellement net** : 50 cartes de médiane, écart
#: interquartile **0** sur 827 listes — la même figure que Pokémon à 60. Un deck
#: sous 40 cartes résolues est donc une liste tronquée par les codes manquants,
#: pas un deck court, et l'accepter ferait croire à une collection qu'elle est
#: à dix cartes d'un deck jouable.
MIN_MAIN_CARDS = 40


#: Reprises et attentes, reprises telles quelles du connecteur Pokémon.
ATTEMPTS = 5
FIRST_DELAY = 2.0
MAX_RETRY_AFTER = 120.0


def _retry_after(response: httpx.Response, fallback: float) -> float:
    """Attente demandée par le serveur, bornée ; la nôtre à défaut."""
    header = response.headers.get("Retry-After")
    if not header:
        return fallback
    try:
        return min(float(header.strip()), MAX_RETRY_AFTER)
    except ValueError:
        return fallback


def _get(client: httpx.Client, url: str) -> Any:
    """Requête GET, avec reprises à attente croissante.

    **Le 429 n'est pas théorique ici**, et la première course l'a payé : la
    source a coupé à la troisième page, et deux tournois ont perdu leurs
    classements en route sans que la course s'arrête — l'erreur était attrapée
    par tournoi, si bien que le corpus se serait constitué troué. Un quota
    partagé se dépasse aussi quand *autre chose* interroge la même API : les
    sondes lancées en parallèle ce jour-là ont suffi.

    Un 404 est terminal — la ressource n'existe pas, réessayer ne la fera pas
    apparaître. Tout le reste est retenté.
    """
    delay = FIRST_DELAY
    last: Exception | None = None
    for attempt in range(ATTEMPTS):
        try:
            response = client.get(url)
            if response.status_code == 404:
                response.raise_for_status()
            if response.status_code == 429 or response.status_code >= 500:
                if attempt == ATTEMPTS - 1:
                    response.raise_for_status()
                time.sleep(_retry_after(response, delay))
                delay *= 2
                continue
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404 or attempt == ATTEMPTS - 1:
                raise
            last = exc
        except httpx.HTTPError as exc:
            if attempt == ATTEMPTS - 1:
                raise
            last = exc
        time.sleep(delay)
        delay *= 2
    raise last if last else RuntimeError(f"échec inattendu sur {url}")


def parse_date(text: str | None) -> dt.datetime | None:
    if not text:
        return None
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def load_code_index(conn: psycopg.Connection) -> dict[str, str]:
    """`{code d'impression: oracle_id}` pour le catalogue One Piece.

    **Le code est relu de la source, comme pour les prix.** Il n'est stocké nulle
    part en base : l'identité de la carte en est *dérivée*
    (`uuid5(NAMESPACE, code)`), ce qui va dans un sens et pas dans l'autre. La
    sonde est mise en cache sur disque, donc cette relecture ne coûte rien après
    la première.

    Le filtre par les identités réellement présentes évite d'annoncer résolue
    une carte que le catalogue connaît mais que l'ingestion n'a pas écrite.
    """
    from app.ingestion.optcg_ingest import NAMESPACE
    from app.measure.optcgapi_probe import Probe, ProbeError

    probe = Probe(quiet=True)
    par_code: dict[str, str] = {}
    for origin in probe.set_ids() + probe.deck_ids():
        try:
            rows = (
                probe.deck_cards(origin)
                if origin.startswith("ST")
                else probe.cards(origin)
            )
        except ProbeError:
            continue
        for row in rows:
            code = (row.get("card_set_id") or "").strip()
            if code:
                par_code[PrintCodeResolver.normalise(code)] = str(
                    uuid.uuid5(NAMESPACE, code)
                )

    with conn.cursor() as cur:
        presents = {
            row[0]
            for row in cur.execute(
                "SELECT oracle_id::text FROM public.cards WHERE game = %s", (GAME,)
            ).fetchall()
        }
    return {code: oracle for code, oracle in par_code.items() if oracle in presents}


def tournaments(
    client: httpx.Client, *, days: int, before: dt.datetime | None = None
) -> Iterator[dict[str, Any]]:
    """Tournois One Piece de la fenêtre, du plus récent au plus ancien.

    `before` borne la fenêtre par le haut et sert à reprendre une course
    interrompue sans repayer ce qui est acquis. Un tournoi daté `before`
    exactement est **gardé** : la borne vient d'un deck observé, et un tournoi à
    moitié importé doit être refait, non sauté.
    """
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


def boards(decklist: dict[str, Any] | None) -> tuple[dict[str, int], str | None]:
    """Une decklist aplatie en `({code: quantité}, code du leader)`.

    Les trois rubriques sont fusionnées : ce sont trois familles d'un même deck
    de cinquante cartes, pas trois zones de jeu disjointes comme l'Extra Deck de
    Yu-Gi-Oh. Une même impression citée deux fois voit ses quantités cumulées.

    Le leader sort à part, et **n'entre pas dans le compte**.
    """
    cards: dict[str, int] = {}
    if not decklist:
        return cards, None

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

    chef = decklist.get("leader")
    return cards, code_of(chef) if isinstance(chef, dict) else None


def code_of(entry: dict[str, Any]) -> str | None:
    """`{'set': 'OP07', 'number': '022'}` -> `OP07-022`."""
    set_code = (entry.get("set") or "").strip().upper()
    number = str(entry.get("number") or "").strip()
    if not set_code or not number:
        return None
    return f"{set_code}-{number}"


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
    """Enregistre les decks d'un tournoi, commite, et rend (gardés, écartés).

    **C'est l'unité de reprise**, et elle est close par un commit : ce qui n'est
    pas commité part avec la connexion morte, donc la maille du commit doit être
    celle de la reprise. Les totaux sont *rendus* et non accumulés en place, pour
    qu'un rejeu après coupure ne les compte pas deux fois.
    """
    inserted = skipped = 0
    for entry in standings:
        cards, leader_code = boards(entry.get("decklist"))
        if not cards:
            continue
        leader_id = resolver.resolve(leader_code) if leader_code else None
        stored = store_deck(
            conn,
            source_id=SOURCE_ID,
            # Le joueur, et non son classement — Limitless rend `placing: null`
            # pour tout joueur non classé, si bien que tous partageraient la
            # même clé et s'écraseraient. Le défaut a coûté un quart du corpus
            # Pokémon avant d'être vu, et il ne se voyait qu'en comparant le
            # compteur d'écritures au décompte des lignes en base.
            external_id=f"{tournament_id}-{entry.get('player')}",
            name=deck_name(entry, tournament),
            fmt=FORMAT,
            tier="competitive",
            mainboard=cards,
            sideboard={},
            resolver=resolver,
            commander_oracle_id=leader_id,
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

    with psycopg.connect(cfg.db_url) as conn:
        index = load_code_index(conn)
        print(f"catalogue : {len(index)} codes d'impression", flush=True)
        resolver = PrintCodeResolver(index)

        with httpx.Client(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            for tournament in tournaments(client, days=days, before=before):
                tournament_id = str(tournament.get("id") or "")
                if not tournament_id:
                    continue
                try:
                    standings = _get(
                        client, f"{API}/tournaments/{tournament_id}/standings"
                    )
                except httpx.HTTPError as exc:
                    # Cinq reprises ont déjà échoué. Le tournoi manquera au
                    # corpus : on le dit assez fort pour qu'une relance le
                    # rattrape, plutôt que de laisser un trou muet.
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
                        f"  {tournament.get('name', '')[:44]:44} "
                        f"{inserted:3} decks",
                        flush=True,
                    )

        record(conn, SOURCE_ID + ":onepiece", version=str(dt.date.today()), items=gardes)
        conn.commit()

    print()
    print(f"  {tournois} tournois parcourus")
    print(f"  {gardes} decks enregistrés, {ecartes} écartés (trop lacunaires)")
    if manques:
        print(f"  {len(manques)} tournois perdus malgré les reprises — relancer pour les rattraper")
    unresolved = resolver.unresolved
    if unresolved:
        print(f"  {len(unresolved)} codes non résolus, les plus fréquents :")
        frequents = sorted(unresolved.items(), key=lambda kv: -kv[1])[:8]
        for code, n in frequents:
            print(f"      {code:16} {n}")
    return tournois, gardes, ecartes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=90)
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
