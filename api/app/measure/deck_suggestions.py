"""Ce que coute l'onglet Decks, jeu par jeu, sous le role qui le subit.

**Pourquoi ce banc existe.** Trois des huit jeux rendent une erreur 500 sur
l'onglet Decks — `57014 canceling statement due to statement timeout`. Le role
`authenticated` coupe a huit secondes, et `deck_suggestions` les depasse des que
le corpus du format est gros. Mesure du 2026-09-16, compte proprietaire :

    magic     pauper          2,0 s    30 decks
    magic     commander       2,4 s    30 decks
    magic     modern          0,5 s    30 decks
    pokemon   standard        8,1 s    HTTP 500 57014
    swu       premier         8,1 s    HTTP 500 57014
    yugioh    edison          7,5 s    30 decks   (timeout a l'essai precedent)
    onepiece  op_standard     3,5 s    30 decks
    riftbound constructed     4,4 s    30 decks

**Le materiel n'est pas en cause, la requete l'est.** `EXPLAIN (ANALYZE,
BUFFERS)` donne 248 036 blocs touches — pres de deux gigaoctets traverses — pour
rendre trente lignes. La fonction calcule les totaux, les couleurs et le prix des
cartes manquantes pour **tout le corpus du format**, puis n'en garde que trente.
Le volume suit donc le nombre de lignes de decklist du format, pas le nombre de
resultats :

    pokemon   standard    23 431 decks    595 239 lignes `main`
    swu       premier      5 038 decks    116 835
    yugioh    edison       3 050 decks    119 447
    magic     pauper       1 017 decks     18 294

Magic passe parce que Pauper est le plus petit corpus du lot. Le classement des
temps mesures suit exactement celui des volumes.

**Pourquoi mesurer par REST et non par `EXPLAIN`.** La connexion d'ingestion est
proprietaire : elle ne porte pas le plafond de huit secondes, et rend donc
« sain » ce qui expire en production. Seul un jeton d'utilisateur le montre.

Usage :

    cd api && .venv/Scripts/python -m app.measure.deck_suggestions
    cd api && .venv/Scripts/python -m app.measure.deck_suggestions --game magic
"""

from __future__ import annotations

import argparse
import sys
import time

import httpx

import psycopg

from app.config import SupabaseConfig, load_env_file
from app.ingestion.deck_profile import perime
from app.measure.collection_summary import any_token

REST = "/rest/v1/rpc/deck_suggestions"

#: Le role `authenticated` coupe ici. Au-dela, l'ecran rend une erreur, pas une
#: attente : c'est un jeu casse, pas un jeu lent.
PLAFOND_ROLE = 8.0

#: Au-dela, l'onglet se fait attendre assez pour qu'on le croie en panne.
SEUIL_CONFORT = 2.0

#: Le premier format de chaque jeu — celui que l'onglet ouvre par defaut, donc
#: le seul que beaucoup verront. Miroir de `deckFormatsFor` cote Dart.
PREMIERS_FORMATS = [
    ("magic", "pauper"),
    ("magic", "modern"),
    ("magic", "commander"),
    ("riftbound", "constructed"),
    ("yugioh", "edison"),
    ("pokemon", "standard"),
    ("wankul", "tournament"),
    ("swu", "premier"),
    ("onepiece", "op_standard"),
    ("lorcana", "lorcana_core"),
]


def demande(client: httpx.Client, headers: dict[str, str], jeu: str, fmt: str):
    """Une interrogation, telle que `DeckRepository.suggestions` l'envoie."""
    debut = time.perf_counter()
    reponse = client.post(
        REST,
        headers=headers,
        json={
            "p_format": fmt,
            "p_game": jeu,
            "p_max_missing": 100,
            "p_max_results": 30,
            "p_max_cost": None,
            "p_tier": None,
            "p_colors": [],
            "p_banned_colors": [],
            "p_commander": None,
            "p_owned_commander": False,
        },
    )
    return time.perf_counter() - debut, reponse


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", help="ne mesurer qu'un jeu")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args(argv)

    values = load_env_file("supabase.env")
    config = SupabaseConfig.load()

    opened = any_token(config, values)
    if opened is None:
        print("Aucun compte de supabase.env n'ouvre de session.", file=sys.stderr)
        return 64
    token, email = opened

    cas = [c for c in PREMIERS_FORMATS if args.game is None or c[0] == args.game]
    if not cas:
        print(f"Aucun format connu pour le jeu {args.game!r}.", file=sys.stderr)
        return 64

    # **Des profils perimes rendent la mesure fausse ET l'ecran faux.** La
    # fonction repondrait vite, sur l'etat de la veille. Il n'existe aucun point
    # de passage ou accrocher la reconstruction — `deck_ingest.store_deck`
    # s'appelle par deck, les prix n'ont pas d'ecrivain commun, dix connecteurs
    # n'inscrivent rien — alors faute de garantir qu'elle sera lancee, on
    # garantit qu'on saura qu'elle manque.
    with psycopg.connect(config.db_url) as conn:
        raisons = perime(conn)
    if raisons:
        for raison in raisons:
            print(f"PROFILS PERIMES : {raison}", file=sys.stderr)
        print(
            "Relancez `python -m app.ingestion.deck_profile` avant de mesurer.",
            file=sys.stderr,
        )
        return 65

    print(f"Mesure menee sous {email}.")
    print(f"{'jeu':<11}{'format':<14}{'temps':>9}  reponse")

    casses: list[str] = []
    lents: list[str] = []
    headers = {
        "apikey": config.anon_key,
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    with httpx.Client(base_url=config.url, timeout=args.timeout) as client:
        for jeu, fmt in cas:
            duree, reponse = demande(client, headers, jeu, fmt)
            if reponse.status_code == 200:
                etat = f"{len(reponse.json())} decks"
            else:
                corps = {}
                if reponse.headers.get("content-type", "").startswith("application/json"):
                    corps = reponse.json()
                etat = (
                    f"HTTP {reponse.status_code} {corps.get('code', '')} "
                    f"{corps.get('message', '')[:56]}"
                )
                casses.append(f"{jeu}/{fmt}")
            if reponse.status_code == 200 and duree > SEUIL_CONFORT:
                lents.append(f"{jeu}/{fmt} ({duree:.1f} s)")
            drapeau = "  <<< AU-DELA DU PLAFOND" if duree > PLAFOND_ROLE else ""
            print(f"{jeu:<11}{fmt:<14}{duree:>7.2f} s  {etat}{drapeau}")

    if casses:
        print(
            f"\nECHEC : l'onglet Decks ne repond pas pour {', '.join(casses)}. "
            f"Le role coupe a {PLAFOND_ROLE:.0f} s.",
            file=sys.stderr,
        )
        return 1
    if lents:
        print(f"\nAu-dela du confort ({SEUIL_CONFORT} s) : {', '.join(lents)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
