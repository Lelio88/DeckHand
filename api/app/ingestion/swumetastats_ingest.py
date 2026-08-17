"""Corpus de decks Star Wars Unlimited, depuis SWU Meta Stats.

**Trois portes ont été essayées avant celle-ci**, et le noter évite de les
rouvrir : TopDeck.gg — qui alimente Magic, Riftbound et Yu-Gi-Oh — *connaît* le
jeu, 36 tournois en `Premier` sur un an, mais **aucun ne porte de decklist** ;
Limitless, qui alimente Pokémon, ne couvre pas SWU ; SWU Stats publie une API
Melee sans clé dont les « decks » portent le leader, la base et le résultat,
jamais la liste des cartes.

SWU Meta Stats ne publie aucune condition (404 sur `/terms`) et documente « a
public read-only REST API […] require no authentication » : le garde-fou §IV.9
lui applique celles de Scryfall, dont l'attribution visible — portée par
`deck_sources`.

**Deux pièges de pagination, tous deux silencieux et mesurés.** `limit` est
ignoré : la page fait vingt entrées qu'on en demande trois ou vingt-cinq.
`page` et `offset` le sont aussi, et rendent la première page sans broncher.
Seul **`skip`** déplace la fenêtre. Les trois auraient produit une ingestion qui
tourne, qui n'échoue jamais, et qui réécrit vingt decks en boucle — c'est la
leçon Pokémon, où un compteur d'écritures passait pour un compteur de résultats
et masquait 5 533 decks manquants. La boucle s'arrête donc dès qu'une page ne
rapporte **aucune entrée nouvelle**.

**Le débit décide de la fenêtre.** Une page de vingt pèse un quart de mégaoctet
et met environ 80 secondes à venir : couvrir les 11 744 listes de cent vingt
jours demanderait une douzaine d'heures. Le défaut est donc à trente jours, et
`--days` l'ouvre.

**La résolution est un nom, pas un code d'impression** — contrairement à
Riftbound et Pokémon. Elle se fait en trois temps, mesurés sur 220 listes :

* le **titre entier** décide (96,32 % des citations) ;
* le **nom seul** tranche, *et seulement s'il ne désigne qu'une carte* (3,41 %).
  C'est nécessaire — les bases sont citées sans leur sous-titre, « Data Vault »
  pour « Data Vault | Scarif » — et ce ne peut pas être aveugle : « Black One »
  désigne deux cartes réellement différentes ;
* le reste est **refusé** plutôt que deviné (0,26 %).

`load_name_index` ne suffit pas pour ce jeu : il construit un dictionnaire
nom -> carte où une collision **écrase silencieusement** la précédente. Ce module
retire donc les noms ambigus avant de résoudre.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.swumetastats_ingest
    #   --days N    fenêtre d'import (défaut 30)
    #   --limit N   plafond de decklists lues
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from typing import Any, Iterator

import psycopg

from app.config import SupabaseConfig
from app.db import Session
from app.ingestion.card_resolver import CardResolver
from app.ingestion.deck_ingest import IngestReport, store_deck
from app.ingestion.scryfall_parse import normalize_name

API = "https://www.swumetastats.com/api"
SOURCE_ID = "swumetastats"
GAME = "swu"

#: Le seul format qui porte le corpus, **mesuré et non déduit d'un nom** :
#: `Premier` couvre 19 tournois sur 20, tous officiels. Yu-Gi-Oh a payé la
#: déduction inverse — `Advanced` y avait été déclaré parce qu'il porte le nom
#: du format courant du jeu, pour trois decklists sur 168 tournois.
FORMAT = "premier"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Taille de page **imposée par la source**, quoi qu'on demande.
PAGE_SIZE = 20

#: Une requête par seconde. La source annonce une protection anti-abus qui
#: répond 429 ; rester bien en deçà évite de la déclencher.
PAUSE_SECONDS = 1.0

ATTEMPTS = 5
FIRST_DELAY = 2.0

#: Les zones qui comptent dans la complétion. **`Sideboard` en est exclu**,
#: comme partout ailleurs ; `Base` et `Leader` y sont, parce qu'on ne pose pas
#: un deck sans eux — c'est le précédent Riftbound, dont les runes et les champs
#: de bataille sont fondus dans le pan principal pour la même raison.
MAIN_ZONES = ("Leader", "Base", "MainDeck")
LEADER_ZONE = "Leader"
SIDE_ZONE = "Sideboard"

#: Séparateur entre le nom et le sous-titre dans les citations.
TITLE_SEPARATOR = " | "

#: Ponctuation typographique repliée avant de résoudre. **Les deux sources ne
#: s'accordent pas** : les listes citent « Benthic “Two Tubes” » et « Mesa
#: Propose… » là où le catalogue publie des guillemets droits et pas d'ellipse.
#: C'est le même désaccord que Riftbound, qui mêlait apostrophes droites et
#: typographiques d'une extension à l'autre.
#:
#: `normalize_name` gère déjà les apostrophes et les accents ; ces quatre
#: caractères-là lui échappent, et ils coûtaient trois citations sur vingt
#: decks mesurés.
PUNCTUATION = {
    "“": '"', "”": '"',   # guillemets courbes
    "…": "",                    # points de suspension
    "–": "-", "—": "-",   # tirets demi-cadratin et cadratin
}


def fold_punctuation(title: str) -> str:
    """Replie la ponctuation typographique d'une citation.

    **Ne peut pas créer de faux couple** : aucune paire de titres du catalogue
    ne diffère par ces seuls caractères — vérifié au banc, la seule réunion
    qu'une normalisation produisait était « Prepare For / for Takeoff », deux
    écritures d'une même carte que l'ingestion fusionne désormais en amont.
    """
    return "".join(PUNCTUATION.get(c, c) for c in title)

#: Seuil de taille, **tiré de la distribution** et non des règles du jeu. Les
#: tailles observées vont de 50 à 64 cartes hors réserve, avec deux modes à 50
#: et 60. Le seuil est posé à 30 : très en deçà de tout deck réel et très
#: au-dessus d'un fragment, il écarte l'accident sans prétendre juger les
#: règles.
#:
#: Ce qu'il garde : une decklist enregistrée à moitié à la source franchirait
#: sans peine le seuil de résolution — le peu qu'elle contient se résout
#: parfaitement — et s'afficherait comme presque constructible, le pire défaut
#: possible pour ce produit.
MIN_MAIN_CARDS = 30


class IngestError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise IngestError(f"{url} : introuvable (404)") from exc
            last = exc
        except Exception as exc:
            last = exc
        time.sleep(delay)
        delay *= 2
    raise IngestError(f"{url} : {last}")


def fetch_decklists(
    start: str, end: str, limit: int | None = None, skip_from: int = 0
) -> Iterator[dict]:
    """Parcourt les decklists de la fenetre, page par page.

    S'arrete des qu'une page ne rapporte **aucune entree nouvelle** : c'est le
    garde-fou contre le piege de pagination decrit en tete de module. Si `skip`
    cessait d'etre honore, la boucle s'arreterait au lieu de tourner
    indefiniment sur la premiere page.

    [skip_from] reprend une course interrompue, et il paie un cout reel : la
    source debite **80 secondes par page de vingt**, si bien que repasser sur
    1 796 listes deja acquises coute pres de deux heures avant d'atteindre du
    neuf. L'ingestion etant idempotente, ce temps ne produit rien.

    **La borne est un rang, pas une date**, contrairement au `--before` des
    connecteurs Limitless. C'est ce que cette source permet : elle n'accepte que
    `skip`, `limit` / `page` / `offset` etant ignores. Un rang derive donc de
    l'ordre de la source, et cet ordre bouge — un tournoi publie depuis la
    course precedente decale tout d'un cran. **Sauter moins que ce qu'on croit
    acquis** est donc la regle : le surcout est quelques pages relues, l'erreur
    inverse est un trou silencieux dans le corpus.
    """
    seen: set[int] = set()
    skip = max(0, skip_from)
    annonce = False
    while True:
        params = {"startDate": start, "endDate": end}
        if skip:
            params["skip"] = str(skip)
        payload = json.loads(
            _fetch(f"{API}/decklists?" + urllib.parse.urlencode(params)).decode("utf-8")
        )
        # **La source dit combien la fenetre en contient, et on ne le lisait
        # pas.** `totalCount` est publie a cote des listes, dans chaque reponse.
        # Sans lui, une course de plusieurs heures n'annonce que son compteur
        # brut : impossible de savoir s'il reste dix minutes ou deux heures.
        #
        # Ce n'est pas une commodite. Faute de ce chiffre, l'ordre de grandeur a
        # ete estime en extrapolant lineairement les 11 744 listes de 120 jours,
        # ce qui donnait ~2 900 pour un mois. Le total reel est **5 109** : le
        # mois ecoule est bien plus dense que la moyenne, et l'estimation etait
        # fausse d'un facteur deux.
        if not annonce:
            total = payload.get("totalCount")
            if total:
                reste = max(0, int(total) - skip)
                print(f"  {total} listes dans la fenetre, {reste} a parcourir", flush=True)
            annonce = True
        rows = payload.get("decklists") or []
        fresh = [r for r in rows if r.get("id") not in seen]
        if not fresh:
            return
        for row in fresh:
            seen.add(row["id"])
            yield row
            if limit is not None and len(seen) >= limit:
                return
        skip += PAGE_SIZE
        time.sleep(PAUSE_SECONDS)


def load_unambiguous_names(conn: psycopg.Connection) -> dict[str, str]:
    """Index nom normalisé -> carte, **les noms ambigus retirés**.

    `load_name_index` construit un dictionnaire où une collision écrase
    silencieusement la précédente : « Black One » y désignerait l'une des deux
    cartes selon l'ordre des lignes rendues par la base. Ici, un nom porté par
    plusieurs cartes est simplement **absent** — la citation sera refusée
    plutôt que résolue au hasard.

    Le titre entier, lui, n'est jamais ambigu : c'est l'identité même de la
    carte.
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT s.normalized, s.oracle_id::text
            FROM public.card_search_names s
            JOIN public.cards c ON c.oracle_id = s.oracle_id
            WHERE c.game = %s
            """,
            (GAME,),
        ).fetchall()

    par_nom: dict[str, set[str]] = defaultdict(set)
    for normalized, oracle_id in rows:
        par_nom[normalized].add(oracle_id)

    index = {name: next(iter(ids)) for name, ids in par_nom.items() if len(ids) == 1}
    ambigus = len(par_nom) - len(index)
    if ambigus:
        print(f"  {ambigus} noms écartés car portés par plusieurs cartes")
    return index


def boards(deck: dict[str, Any]) -> tuple[dict[str, int], dict[str, int], str | None]:
    """Aplatit une decklist en (principal, réserve, titre du leader).

    Le leader est retenu à part pour occuper `decks.commander_oracle_id`, comme
    la Légende de Riftbound : c'est par lui qu'on choisit un deck. Il reste dans
    le pan principal — on doit le posséder.
    """
    main: dict[str, int] = {}
    side: dict[str, int] = {}
    leader: str | None = None

    for row in deck.get("cards") or []:
        name = fold_punctuation(row.get("cardName") or "")
        if not name:
            continue
        try:
            quantity = int(row.get("count") or 0)
        except (TypeError, ValueError):
            continue
        if quantity <= 0:
            continue

        section = row.get("section")
        if section == SIDE_ZONE:
            side[name] = side.get(name, 0) + quantity
            continue
        if section not in MAIN_ZONES:
            continue
        main[name] = main.get(name, 0) + quantity
        if section == LEADER_ZONE and leader is None:
            leader = name

    return main, side, leader


def deck_name(deck: dict[str, Any]) -> str:
    tournament = (deck.get("tournament") or {}).get("name") or "Tournoi"
    standing = deck.get("standing")
    if standing:
        return f"{tournament} — {standing}e place"
    return tournament


def run(days: int, limit: int | None, skip: int = 0) -> None:
    end = dt.date.today()
    start = end - dt.timedelta(days=days)
    print(f"decks Star Wars Unlimited, du {start} au {end}")
    if skip:
        print(f"  reprise au rang {skip} — les pages precedentes ne sont pas relues")

    config = SupabaseConfig.load()
    with Session(config.db_url) as session:
        index = session.run(lambda conn: load_unambiguous_names(conn))
        resolver = CardResolver(index)
        report = IngestReport()

        for deck in fetch_decklists(
            start.isoformat(), end.isoformat(), limit, skip_from=skip
        ):
            main, side, leader_name = boards(deck)
            if not main:
                report.skipped += 1
                continue

            leader_id = resolver.resolve(leader_name) if leader_name else None
            def enregistre(conn, d=deck, m=main, s=side, chef=leader_id):
                """Écrit un deck **et le commite**.

                **`store_deck` n'engage rien**, et `Session.run` documente que
                l'unité doit commiter ce qu'elle veut garder. Sans ce commit,
                vingt decks annoncés « enregistrés » repartaient avec la
                connexion : le connecteur comptait ce qu'il croyait écrire, et
                la base restait vide. C'est la même leçon que les 5 533 decks
                Pokémon manquants — *un compteur d'écritures n'est pas un
                compteur de résultats*, et seul le décompte en base les sépare.

                La maille du commit est aussi celle de la reprise : un deck à la
                fois, de sorte qu'une coupure ne coûte que celui-là.
                """
                kept = store_deck(
                    conn,
                    source_id=SOURCE_ID,
                    external_id=str(d.get("id")),
                    name=deck_name(d),
                    fmt=FORMAT,
                    # `competitive` et non `accessible` : ces listes viennent de
                    # tournois officiels, et la colonne n'admet que ces deux
                    # valeurs. C'est le même choix que TopDeck et Limitless.
                    tier="competitive",
                    mainboard=m,
                    sideboard=s,
                    resolver=resolver,
                    commander_oracle_id=chef,
                    source_url=f"https://swumetastats.com/decklists/{d.get('guid')}",
                    game=GAME,
                    min_main_cards=MIN_MAIN_CARDS,
                )
                conn.commit()
                return kept

            stored = session.run(enregistre)
            if stored:
                report.inserted += 1
            else:
                report.skipped_incomplete += 1
            vus = report.inserted + report.skipped_incomplete
            if vus % 100 == 0:
                print(f"  {report.inserted} enregistrés, "
                      f"{report.skipped_incomplete} écartés")

        report.unresolved_names = resolver.unresolved
        print()
        print(report.summary())
        if session.recoveries:
            print(f"coupures de connexion encaissées : {session.recoveries}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="fenêtre (défaut 30 jours)")
    parser.add_argument("--limit", type=int, default=None, help="plafond de listes")
    parser.add_argument(
        "--skip",
        type=int,
        default=0,
        help=(
            "reprend a ce rang au lieu du debut. Sauter MOINS que ce qu'on croit "
            "acquis : l'ordre de la source bouge, et un trou est plus couteux "
            "que quelques pages relues"
        ),
    )
    args = parser.parse_args()
    run(args.days, args.limit, args.skip)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu — relancer reprendra, l'écriture étant idempotente")
