"""Mesure `my_collection_summary` sous le rôle qui la subit, et lit ce qu'elle rend.

**Pourquoi un banc plutôt qu'un `EXPLAIN`.** La connexion d'ingestion est
propriétaire : elle ne porte pas le `statement_timeout` de huit secondes du rôle
`authenticated`, et elle a déjà montré une fonction « parfaitement saine » qui
expirait en production. Le seul chemin qui prouve quelque chose est l'API REST
avec un jeton d'utilisateur — celui de l'application.

**Le temps ET les valeurs.** Un chiffre rapide mais absurde — « votre meilleure
extension : un jeu de jetons » — est un défaut que la durée ne montre jamais.

Usage :

    cd api && .venv/Scripts/python -m app.measure.collection_summary
    cd api && .venv/Scripts/python -m app.measure.collection_summary --game riftbound
"""

from __future__ import annotations

import argparse
import sys
import time

import httpx

from app.config import SupabaseConfig, load_env_file

REST = "/rest/v1/rpc/my_collection_summary"

# Au-delà, la page de profil se fait attendre ; le rôle coupe à 8 s.
SEUIL_CONFORT = 2.0


def token_for(config: SupabaseConfig, email: str, password: str) -> str | None:
    with httpx.Client(base_url=config.url, timeout=30) as client:
        response = client.post(
            "/auth/v1/token",
            params={"grant_type": "password"},
            headers={"apikey": config.anon_key},
            json={"email": email, "password": password},
        )
        if response.status_code != 200:
            return None
    return response.json()["access_token"]


def any_token(config: SupabaseConfig, values: dict[str, str]) -> tuple[str, str] | None:
    for key in ("DECKHAND_TEST", "DECKHAND_DEMO"):
        email = values.get(f"{key}_EMAIL")
        password = values.get(f"{key}_PASSWORD")
        if not email or not password:
            continue
        token = token_for(config, email, password)
        if token is not None:
            return token, email
        print(f"{key} refuse par Supabase, on essaie le suivant.", file=sys.stderr)
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", default="magic")
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args(argv)

    values = load_env_file("supabase.env")
    config = SupabaseConfig.load()

    opened = any_token(config, values)
    if opened is None:
        print("Aucun compte de supabase.env n'ouvre de session.", file=sys.stderr)
        return 64
    token, email = opened
    print(f"Mesure menee sous {email}, jeu {args.game}.")
    print()

    headers = {
        "apikey": config.anon_key,
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    durees: list[float] = []
    payload = None
    with httpx.Client(base_url=config.url, timeout=30) as client:
        for _ in range(args.runs):
            debut = time.perf_counter()
            response = client.post(REST, headers=headers, json={"p_game": args.game})
            durees.append(time.perf_counter() - debut)
            if response.status_code != 200:
                print(f"HTTP {response.status_code} : {response.text}", file=sys.stderr)
                return 1
            body = response.json()
            payload = body[0] if isinstance(body, list) and body else body

    for i, d in enumerate(durees, 1):
        print(f"  passe {i} : {d:.2f} s")
    print(f"  mediane : {sorted(durees)[len(durees) // 2]:.2f} s")
    print()

    if payload is None:
        print("Aucune ligne rendue.", file=sys.stderr)
        return 1

    for cle, valeur in payload.items():
        print(f"  {cle:20} {valeur}")

    owned = payload.get("best_set_owned") or 0
    total = payload.get("best_set_total") or 0
    if total:
        print(f"\n  meilleure extension : {payload['best_set_name']} "
              f"— {owned}/{total} soit {100 * owned / total:.0f} %")

    mediane = sorted(durees)[len(durees) // 2]
    if mediane > SEUIL_CONFORT:
        print(
            f"\nATTENTION : {mediane:.2f} s de mediane, au-dela du confort "
            f"({SEUIL_CONFORT} s). Le role coupe a 8 s.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
