"""Ce que Limitless publie de One Piece, avant d'en ingérer une ligne.

Quatre questions, dans l'ordre où une réponse négative arrête la suivante :

1. **le volume** — combien de tournois, et surtout combien portent des listes.
   Un tournoi sans liste n'apporte rien : chez Pokémon la proportion était de
   99 %, et rien ne dit qu'elle se retrouve ici ;
2. **les zones** — la liste est découpée en `leader` / `character` / `event` /
   `stage`, quatre noms qui ne sont ni ceux de Magic ni ceux de Pokémon. Il faut
   savoir si `leader` en est une comme les autres, et si l'une peut manquer ;
3. **la résolution** — chaque entrée porte `set` et `number` séparément, quand
   le catalogue porte un `card_set_id` d'un seul tenant. Le rapprochement se
   fait donc par reconstitution, `OP07` + `022` donnant `OP07-022`. **C'est
   exactement la reconstitution qui a échoué sur les prix**, où `OP14-EB04`
   agrégeait deux extensions : il faut mesurer combien de lignes elle résout
   ici avant de s'y fier ;
4. **le gabarit** — taille du deck, part de chaque zone, plafond d'exemplaires.

Ce banc ne touche pas la base en écriture : il lit le catalogue pour résoudre,
et rend des nombres.

Usage :
    cd api && .venv/Scripts/python -m app.measure.onepiece_decks
    #   --days N        fenêtre de collecte (défaut 30)
    #   --tournaments N plafond de tournois sondés (défaut 60)
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import statistics
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Iterator

import httpx
import psycopg

from app.config import SupabaseConfig

API = "https://play.limitlesstcg.com/api"
LIMITLESS_GAME = "OP"
GAME = "onepiece"

USER_AGENT = "DeckHand/1.0 (collection manager; contact heianenterpriseyt@gmail.com)"
PAUSE_SECONDS = 0.6
PAGE_SIZE = 50

#: Les trois zones qui portent une **liste** d'entrées, chacune avec un `count`.
ZONES = ("character", "event", "stage")

#: `leader` est publié à part, et sa forme n'est pas celle des trois autres.
#:
#: **C'est un objet unique, sans `count`.** Une première version le rangeait
#: parmi les zones et le lisait comme une liste : `isinstance(…, list)` était
#: faux, la zone était sautée sans un mot, et le banc a rendu « leader : 0
#: cartes, 0 leaders distincts » — un zéro qui se lisait comme une absence alors
#: qu'il signalait une forme inattendue.
#:
#: Il y en a exactement un par deck, et il **ne compte pas** dans les cinquante
#: cartes : c'est structurellement le général de Commander, une carte à part que
#: le deck désigne et qui reste hors du compte.
LEADER = "leader"


@dataclass
class Rapport:
    """Ce que le banc a vu."""

    tournois: int = 0
    tournois_avec_listes: int = 0
    listes: int = 0
    lignes: int = 0
    resolues: int = 0
    codes_manquants: collections.Counter = field(default_factory=collections.Counter)
    par_zone: collections.Counter = field(default_factory=collections.Counter)
    tailles: list[int] = field(default_factory=list)
    exemplaires_max: collections.Counter = field(default_factory=collections.Counter)
    leaders: collections.Counter = field(default_factory=collections.Counter)


def _get(client: httpx.Client, url: str) -> Any:
    response = client.get(url)
    response.raise_for_status()
    return response.json()


def parse_date(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def tournaments(client: httpx.Client, *, days: int, cap: int) -> Iterator[dict[str, Any]]:
    """Tournois One Piece de la fenêtre, du plus récent au plus ancien."""
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    vus = 0
    for page in range(1, 40):
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
            yield row
            vus += 1
            if vus >= cap:
                return
        if perimee:
            return


def code_of(entry: dict[str, Any]) -> str | None:
    """Le code d'une entrée de liste, reconstitué depuis `set` et `number`.

    **C'est la reconstitution que les prix ont démentie**, et le banc mesure
    précisément son taux d'échec. Ici, à la différence des prix, la source
    publie l'extension telle qu'elle est imprimée sur la carte (`OP07`) et non
    le nom d'un regroupement commercial (`OP14-EB04`) : la reconstitution a donc
    une chance de tenir. C'est à mesurer, pas à supposer.
    """
    jeu_de_cartes = (entry.get("set") or "").strip()
    numero = (entry.get("number") or "").strip()
    if not jeu_de_cartes or not numero:
        return None
    return f"{jeu_de_cartes}-{numero}"


def load_codes(conn: psycopg.Connection) -> set[str]:
    """Les codes du catalogue One Piece, tels que `printed_name` ne les porte pas.

    Le code vit dans `cards.name` ? Non — il vit dans l'identité, dérivée de lui.
    On le relit donc du catalogue par la sonde, comme le connecteur de prix.
    """
    import uuid

    from app.ingestion.optcg_ingest import NAMESPACE
    from app.measure.optcgapi_probe import Probe, ProbeError

    probe = Probe(quiet=True)
    connus: dict[str, str] = {}
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
                connus[code] = str(uuid.uuid5(NAMESPACE, code))

    with conn.cursor() as cur:
        presents = {
            row[0]
            for row in cur.execute(
                "SELECT oracle_id::text FROM public.cards WHERE game = %s", (GAME,)
            ).fetchall()
        }
    return {code for code, oracle in connus.items() if oracle in presents}


def mesure(*, days: int, cap: int) -> Rapport:
    rapport = Rapport()
    cfg = SupabaseConfig.load()
    with psycopg.connect(cfg.db_url) as conn:
        codes = load_codes(conn)
    print(f"catalogue : {len(codes)} codes connus", flush=True)

    with httpx.Client(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
        for tournoi in tournaments(client, days=days, cap=cap):
            rapport.tournois += 1
            try:
                standings = _get(client, f"{API}/tournaments/{tournoi['id']}/standings")
            except httpx.HTTPError:
                continue
            time.sleep(PAUSE_SECONDS)
            avec_liste = 0
            for place in standings:
                liste = place.get("decklist")
                if not liste:
                    continue
                avec_liste += 1
                rapport.listes += 1
                taille = 0
                chef = liste.get(LEADER)
                if isinstance(chef, dict):
                    rapport.lignes += 1
                    rapport.par_zone[LEADER] += 1
                    rapport.leaders[chef.get("name") or "?"] += 1
                    code = code_of(chef)
                    if code and code in codes:
                        rapport.resolues += 1
                    else:
                        rapport.codes_manquants[code or "(vide)"] += 1
                for zone in ZONES:
                    entrees = liste.get(zone) or []
                    if not isinstance(entrees, list):
                        continue
                    for entree in entrees:
                        nombre = int(entree.get("count") or 0)
                        rapport.lignes += 1
                        rapport.par_zone[zone] += nombre
                        rapport.exemplaires_max[nombre] += 1
                        taille += nombre
                        code = code_of(entree)
                        if code and code in codes:
                            rapport.resolues += 1
                        else:
                            rapport.codes_manquants[code or "(vide)"] += 1
                rapport.tailles.append(taille)
            if avec_liste:
                rapport.tournois_avec_listes += 1
    return rapport


def affiche(rapport: Rapport) -> None:
    print()
    print("=== volume ===")
    print(f"  tournois sondés            {rapport.tournois}")
    part = (
        100 * rapport.tournois_avec_listes / rapport.tournois if rapport.tournois else 0
    )
    print(
        f"  tournois avec des listes   {rapport.tournois_avec_listes} ({part:.1f} %)"
    )
    print(f"  decks                      {rapport.listes}")
    print(f"  lignes                     {rapport.lignes}")

    print()
    print("=== résolution ===")
    taux = 100 * rapport.resolues / rapport.lignes if rapport.lignes else 0
    print(f"  résolues contre le catalogue  {rapport.resolues}/{rapport.lignes} ({taux:.1f} %)")
    if rapport.codes_manquants:
        print("  codes les plus manquants :")
        for code, n in rapport.codes_manquants.most_common(8):
            print(f"      {code:16} {n}")

    print()
    print("=== gabarit ===")
    if rapport.tailles:
        tailles = sorted(rapport.tailles)
        q1 = tailles[len(tailles) // 4]
        q3 = tailles[3 * len(tailles) // 4]
        print(f"  taille hors leader : médiane {statistics.median(tailles):.0f}, "
              f"Q1 {q1}, Q3 {q3}, écart interquartile {q3 - q1}")
    total = sum(rapport.par_zone.values())
    for zone in (LEADER, *ZONES):
        n = rapport.par_zone[zone]
        print(f"  {zone:12} {n:7} cartes ({100 * n / total if total else 0:5.1f} %)")
    print("  exemplaires par ligne :", dict(sorted(rapport.exemplaires_max.items())))
    print(f"  leaders distincts : {len(rapport.leaders)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--tournaments", type=int, default=60)
    args = parser.parse_args(argv)

    affiche(mesure(days=args.days, cap=args.tournaments))
    return 0


if __name__ == "__main__":
    sys.exit(main())
