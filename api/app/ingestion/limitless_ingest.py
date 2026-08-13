"""Import du corpus de tournoi Pokémon depuis Limitless TCG.

**Ce que la source rend, et pourquoi c'est le meilleur des trois cas.** La
decklist est *structurée* — trois zones (`pokemon`, `trainer`, `energy`) et,
sur chaque ligne, une extension et un numéro plutôt qu'un nom :

    {"count": 4, "set": "TWM", "number": "128", "name": "Dreepy"}

C'est un code d'impression, donc une case unique du catalogue. Aucune ambiguïté
de casse, d'accent ni d'homonymie — et l'homonymie n'est pas théorique ici :
**92 % des cartes Pokémon partagent leur nom avec une autre**, 112 s'appellent
Pikachu. Un rapprochement par nom aurait été inutilisable. C'est aussi mieux que
Yu-Gi-Oh, dont les libellés de zone étaient saisis à la main et coûtaient
305 decks quand on les lisait strictement.

**Le sigle d'extension a fallu le chercher, et il vient de trois gisements.**
Limitless écrit `TWM`, le catalogue range la carte sous `sv06` : il faut une
table. Aucune source unique ne la donne en entier, et les trois se complètent
exactement là où les autres manquent :

===========  ======  ===================================================
Gisement     Sigles  Ce qu'il couvre
===========  ======  ===================================================
`abbreviation` du groupe TCGplayer, atteint par le rapprochement déjà
mesuré pour les prix                153  les extensions modernes (`TWM`, `MEG`)
`Set.tcgOnline` du catalogue, le code PTCGO   37  l'ère PTCGO (`GRI`, `BUS`)
l'identifiant d'extension lui-même            190  le reste (`MEE`, `SVE`)
===========  ======  ===================================================

Mesuré : le seul gisement TCGplayer résout **86,55 %** des citations, et le
manque est concentré — `MEE` pèse à lui seul 6 762 citations, parce que
« Mega Evolution Energy » n'a pas de groupe TCGplayer. Les trois ensemble
résolvent **99,88 %** (204 cartes perdues sur ~170 000).

**Aucun deck partiel n'a été observé** : sur 4 116 listes relevées, toutes font
exactement 60 cartes. Le seuil de taille ne garde donc contre rien de constaté —
il est posé quand même, parce qu'une liste enregistrée à moitié à la source
franchirait sans peine le seuil de résolution (le peu qu'elle contient se résout
parfaitement) et s'afficherait comme presque constructible.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.limitless_ingest
    #   --days N   fenêtre d'import (défaut 90)
"""

from __future__ import annotations

import datetime as dt
import sys
import time
from typing import Any, Iterable, Iterator

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.card_resolver import PrintCodeResolver
from app.ingestion.deck_ingest import IngestReport, store_deck
from app.ingestion.tcgcsv_pokemon_prices import (
    BASE,
    CATEGORY_POKEMON,
    USER_AGENT,
    match_sets,
)
from app.ingestion.topdeck_ingest import load_print_code_index

API = "https://play.limitlesstcg.com/api"
ENDPOINT_TCGDEX = "https://api.tcgdex.net/v2/graphql"
SOURCE_ID = "limitless"
GAME = "pokemon"

#: Code du jeu chez Limitless. L'API est multi-jeux — sans ce filtre, la
#: première entrée rendue est du One Piece.
LIMITLESS_GAME = "PTCG"

#: Série du jeu mobile, absente du catalogue de carton.
POCKET_SERIE = "tcgp"

#: Libellé Limitless -> valeur de la colonne `format`, contrainte en minuscules.
#:
#: **Choisis par volume mesuré**, non par notoriété : sur 6 000 tournois et
#: 321 992 participations relevés sur dix-neuf mois, Standard en porte 95,4 %,
#: puis GLC 3 948, EX 1 720, Expanded 362. `CUSTOM` arrive deuxième (4 650) et
#: n'est pas importé — c'est un fourre-tout de règles maison, dont un deck ne dit
#: pas avec quelles cartes il peut être rejoué.
FORMATS = {
    "STANDARD": "standard",
    "GLC": "glc",
    "EXPANDED": "expanded",
    "EX": "ex",
}

#: Zones d'une decklist. Toutes trois vont au deck principal : ce jeu n'a pas de
#: réserve dans les données publiées.
ZONES = ("pokemon", "trainer", "energy")

#: Nombre minimal de cartes pour qu'une liste compte comme un deck. Voir
#: l'en-tête : rien de tel n'a été observé, le seuil garde contre l'apparition
#: d'une liste tronquée et non contre un cas mesuré.
MIN_POKEMON_CARDS = 50

#: Tournois par page. L'API en rend jusqu'à 500 d'un coup.
PAGE_SIZE = 500
MAX_PAGES = 40

#: Pause entre deux requêtes. **La source limite son débit et ne le publie pas.**
#: Une première version sans pause a tenu treize mille decks puis reçu un 429 en
#: pleine pagination : la fenêtre s'est arrêtée aux deux tiers. Le garde-fou
#: §IV.9 demandait ce débit bas dès le départ.
PAUSE_SECONDS = 0.4

#: Reprises sur 429 et sur erreur serveur, attente doublée à chaque tour :
#: 2, 4, 8, 16, 32 s. Le réseau de ce poste coupe régulièrement, et une coupure
#: ne doit pas coûter la fenêtre entière.
ATTEMPTS = 6
FIRST_DELAY = 2.0

#: Au-delà, l'attente demandée par le serveur est jugée hors de propos et
#: ramenée à la nôtre — un `Retry-After` d'une heure arrêterait l'import aussi
#: sûrement qu'une exception.
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

    Un 404 est terminal — la ressource n'existe pas, réessayer ne la fera pas
    apparaître. Tout le reste est retenté : 429 parce que la source limite son
    débit, 5xx et erreurs de transport parce que le réseau coupe.
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
    raise last if last else RuntimeError(f"echec inattendu sur {url}")


def tcgdex_sets(client: httpx.Client) -> list[dict[str, Any]]:
    """Extensions du catalogue, avec leur code PTCGO quand il existe.

    Requête POST : en GET, l'endpoint rend la page GraphiQL.
    """
    response = client.post(
        ENDPOINT_TCGDEX,
        json={"query": "{sets{id name releaseDate tcgOnline serie{id}}}"},
        timeout=120.0,
    )
    response.raise_for_status()
    sets = response.json()["data"]["sets"]
    return [s for s in sets if (s.get("serie") or {}).get("id") != POCKET_SERIE]


def set_abbreviations(
    sets: Iterable[dict[str, Any]],
    groups: Iterable[dict[str, Any]],
    *,
    today: dt.date,
) -> dict[str, str]:
    """Sigle d'extension -> identifiant d'extension du catalogue.

    Les trois gisements sont consultés dans l'ordre décrit en tête de module. Le
    **premier arrivé garde la clé** : un sigle déjà attribué n'est pas réécrit,
    faute de quoi un identifiant d'extension générique viendrait déloger une
    abréviation officielle.
    """
    groups = list(groups)
    pairs, _ = match_sets(sets, groups, today=today)
    abbrev_by_group = {
        int(g["groupId"]): (g.get("abbreviation") or "") for g in groups
    }

    table: dict[str, str] = {}
    for card_set in sets:
        candidates = (
            abbrev_by_group.get(pairs.get(card_set["id"], -1), ""),
            card_set.get("tcgOnline") or "",
            card_set["id"],
        )
        for candidate in candidates:
            key = (candidate or "").strip().upper()
            if key:
                table.setdefault(key, card_set["id"])
    return table


def load_code_index(
    conn: psycopg.Connection, abbreviations: dict[str, str]
) -> dict[str, str]:
    """Index `SIGLE-NUMÉRO` -> `oracle_id`.

    Repart de l'index par identifiant d'extension — même cadrage du numéro sur
    trois chiffres que `PrintCodeResolver` — et le réindexe sous chaque sigle
    connu. Plusieurs sigles peuvent pointer la même extension, ce qui est voulu :
    Limitless a changé de convention au fil des années.
    """
    by_set: dict[str, dict[str, str]] = {}
    for code, oracle_id in load_print_code_index(conn, GAME).items():
        set_id, _, number = code.rpartition("-")
        by_set.setdefault(set_id, {})[number] = oracle_id

    index: dict[str, str] = {}
    for abbreviation, set_id in abbreviations.items():
        for number, oracle_id in by_set.get(set_id.upper(), {}).items():
            index.setdefault(f"{abbreviation}-{number}", oracle_id)
    return index


def tournaments(client: httpx.Client, *, days: int) -> Iterator[dict[str, Any]]:
    """Tournois du jeu, page par page, jusqu'à sortir de la fenêtre.

    L'API rend les tournois du plus récent au plus ancien ; la pagination
    s'arrête donc dès qu'une page entière est antérieure à la fenêtre.
    """
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    for page in range(1, MAX_PAGES + 1):
        rows = _get(
            client,
            f"{API}/tournaments?game={LIMITLESS_GAME}"
            f"&limit={PAGE_SIZE}&page={page}",
        )
        time.sleep(PAUSE_SECONDS)
        if not rows:
            return
        stale = True
        for row in rows:
            when = parse_date(row.get("date"))
            if when is None or when >= cutoff:
                stale = False
                yield row
        if stale:
            return


def parse_date(text: str | None) -> dt.datetime | None:
    """`2026-08-13T18:30:00.000Z` -> datetime aware, ou None."""
    if not text:
        return None
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def deck_cards(decklist: dict[str, Any] | None) -> dict[str, int]:
    """Une decklist aplatie en `{code d'impression: quantité}`.

    Les trois zones sont fusionnées : ce sont trois rubriques d'un même deck de
    soixante cartes, pas trois zones de jeu disjointes comme l'Extra Deck de
    Yu-Gi-Oh. Une même impression citée deux fois voit ses quantités cumulées.
    """
    cards: dict[str, int] = {}
    if not decklist:
        return cards
    for zone in ZONES:
        for entry in decklist.get(zone) or []:
            set_code = (entry.get("set") or "").strip().upper()
            number = str(entry.get("number") or "").strip()
            count = int(entry.get("count") or 0)
            if not set_code or not number or count <= 0:
                continue
            code = f"{set_code}-{number}"
            cards[code] = cards.get(code, 0) + count
    return cards


def deck_name(entry: dict[str, Any], tournament: dict[str, Any]) -> str:
    """Nom d'archétype quand la source en donne un, nom du tournoi sinon."""
    archetype = (entry.get("deck") or {}).get("name")
    if archetype:
        return str(archetype)
    return str(tournament.get("name") or "Deck Limitless")


def ingest(
    conn: psycopg.Connection,
    client: httpx.Client,
    index: dict[str, str],
    *,
    days: int,
) -> IngestReport:
    resolver = PrintCodeResolver(index)
    report = IngestReport()
    seen = 0

    for tournament in tournaments(client, days=days):
        db_format = FORMATS.get(str(tournament.get("format") or "").upper())
        if db_format is None:
            continue
        tournament_id = tournament.get("id")
        try:
            details = _get(client, f"{API}/tournaments/{tournament_id}/details")
            time.sleep(PAUSE_SECONDS)
            # Un tournoi sans listes publiées n'a rien à donner ; l'interroger
            # plus loin coûterait une requête pour un tableau de `null`.
            if not details.get("decklists"):
                continue
            standings = _get(client, f"{API}/tournaments/{tournament_id}/standings")
            time.sleep(PAUSE_SECONDS)
        except httpx.HTTPError:
            # Un tournoi retiré ne doit pas emporter la fenêtre entière.
            time.sleep(PAUSE_SECONDS)
            continue

        recorded_at = parse_date(tournament.get("date"))
        for entry in standings:
            cards = deck_cards(entry.get("decklist"))
            if not cards:
                continue
            stored = store_deck(
                conn,
                source_id=SOURCE_ID,
                external_id=f"{tournament_id}-{entry.get('placing')}",
                name=deck_name(entry, tournament),
                fmt=db_format,
                # Ce sont des listes de compétition : l'étiquette permet à
                # l'interface de ne pas les confondre avec des decks accessibles.
                tier="competitive",
                mainboard=cards,
                sideboard={},
                resolver=resolver,
                source_url=(
                    f"https://play.limitlesstcg.com/tournament/{tournament_id}"
                ),
                recorded_at=recorded_at,
                game=GAME,
                min_main_cards=MIN_POKEMON_CARDS,
            )
            if stored:
                report.inserted += 1
            else:
                report.skipped_incomplete += 1

        seen += 1
        if seen % 10 == 0:
            conn.commit()
            print(f"  {seen} tournois, {report.inserted} decks", end="\r", flush=True)

    conn.commit()
    report.unresolved_names = resolver.unresolved
    return report


def run(days: int = 90) -> int:
    config = SupabaseConfig.load()
    with (
        psycopg.connect(config.db_url, connect_timeout=60) as conn,
        httpx.Client(
            headers={"User-Agent": USER_AGENT}, timeout=60.0, follow_redirects=True
        ) as client,
    ):
        sets = tcgdex_sets(client)
        groups = _get(client, f"{BASE}/{CATEGORY_POKEMON}/groups")["results"]
        abbreviations = set_abbreviations(
            sets, groups, today=dt.datetime.now(dt.timezone.utc).date()
        )
        index = load_code_index(conn, abbreviations)
        print(f"  {len(abbreviations)} sigles, {len(index)} codes d'impression")

        report = ingest(conn, client, index, days=days)
        print(report.summary())
    return 0


def main(argv: list[str]) -> int:
    days = 90
    if "--days" in argv:
        days = int(argv[argv.index("--days") + 1])
    return run(days=days)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
