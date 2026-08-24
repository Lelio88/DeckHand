"""Vérifie la politique de `public.profiles` sous le rôle qui la subit.

**Pourquoi un banc plutôt qu'un coup d'oeil au SQL.** La connexion d'ingestion
est propriétaire de la base : elle traverse RLS sans la voir, et un `GRANT`
oublié n'y produit aucune erreur. La seule vérification qui prouve quelque chose
passe par l'API REST avec un jeton d'utilisateur, c'est-à-dire exactement le
chemin de l'application.

**Une politique se vérifie dans les deux sens.** Le cas permis prouve qu'elle
marche ; le cas refusé prouve qu'elle sert. Ce banc joue donc les deux : ce que
le titulaire du compte peut faire, et ce qu'il ne peut pas — écrire le profil
d'autrui, ou effacer le sien (le DELETE n'est pas accordé, sans quoi l'étape de
choix des jeux reviendrait à chaque lancement).

L'état initial du profil est relevé puis restauré par la connexion propriétaire :
le banc ne doit rien laisser derrière lui sur un compte réel.

Usage :

    cd api && .venv/Scripts/python -m app.measure.profiles_rls
"""

from __future__ import annotations

import json
import sys
import uuid

import httpx
import psycopg

from app.config import SupabaseConfig, load_env_file

TABLE = "public.profiles"
REST = "/rest/v1/profiles"


def token_for(config: SupabaseConfig, email: str, password: str) -> tuple[str, str] | None:
    """Ouvre une session utilisateur, et rend (jeton, identifiant) — ou None.

    Rendre None plutôt que lever : le coffre porte deux comptes et le premier
    peut avoir changé de mot de passe sans que le fichier suive. Mesuré le
    2026-08-18, `DECKHAND_TEST_PASSWORD` ne correspondait plus au compte.
    """
    with httpx.Client(base_url=config.url, timeout=30) as client:
        response = client.post(
            "/auth/v1/token",
            params={"grant_type": "password"},
            headers={"apikey": config.anon_key},
            json={"email": email, "password": password},
        )
        if response.status_code != 200:
            return None
        body = response.json()
    return body["access_token"], body["user"]["id"]


def any_account(config: SupabaseConfig, values: dict[str, str]) -> tuple[str, str, str] | None:
    """Le premier compte du coffre qui ouvre réellement une session.

    L'ordre compte : le compte du propriétaire d'abord, celui de démonstration
    en second — la vérification porte sur la politique, pas sur les données, et
    n'importe quel compte authentifié la prouve aussi bien.
    """
    for key in ("DECKHAND_TEST", "DECKHAND_DEMO"):
        email = values.get(f"{key}_EMAIL")
        password = values.get(f"{key}_PASSWORD")
        if not email or not password:
            continue
        opened = token_for(config, email, password)
        if opened is not None:
            return opened[0], opened[1], email
        print(f"{key} refusé par Supabase, on essaie le suivant.", file=sys.stderr)
    return None


def snapshot(config: SupabaseConfig, user_id: str) -> tuple[list[str], dict] | None:
    """L'état du profil vu du propriétaire de la base, ou None s'il n'y a pas de ligne.

    **Toutes les colonnes, pas seulement celle qu'on éprouve.** Le banc écrit un
    prix de booster ; ne relever que `games` le laisserait derrière lui, et le
    profil réel du propriétaire porterait un prix de test.
    """
    with psycopg.connect(config.db_url, connect_timeout=30) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT games, booster_prices FROM public.profiles WHERE user_id = %s",
            (user_id,),
        )
        row = cur.fetchone()
    return None if row is None else (list(row[0]), dict(row[1] or {}))


def restore(config: SupabaseConfig, user_id: str, state: tuple[list[str], dict] | None) -> None:
    with psycopg.connect(config.db_url, connect_timeout=30) as conn, conn.cursor() as cur:
        if state is None:
            cur.execute("DELETE FROM public.profiles WHERE user_id = %s", (user_id,))
        else:
            games, prices = state
            cur.execute(
                """
                INSERT INTO public.profiles (user_id, games, booster_prices)
                VALUES (%s, %s, %s)
                ON CONFLICT (user_id) DO UPDATE SET
                    games = EXCLUDED.games,
                    booster_prices = EXCLUDED.booster_prices
                """,
                (user_id, games, json.dumps(prices)),
            )
        conn.commit()


def main(argv: list[str]) -> int:
    values = load_env_file("supabase.env")
    config = SupabaseConfig.load()

    opened = any_account(config, values)
    if opened is None:
        print("Aucun compte de supabase.env n'ouvre de session.", file=sys.stderr)
        return 64
    token, user_id, email = opened
    print(f"Contrôle mené sous {email}.")
    print()

    initial = snapshot(config, user_id)

    headers = {
        "apikey": config.anon_key,
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    verdicts: list[tuple[str, bool, str]] = []

    try:
        with httpx.Client(base_url=config.url, timeout=30) as client:
            # PERMIS — écrire son propre profil.
            written = client.post(
                REST,
                headers={**headers, "Prefer": "resolution=merge-duplicates,return=representation"},
                json={"user_id": user_id, "games": ["pokemon", "magic"]},
            )
            verdicts.append(
                (
                    "ecrire son profil",
                    written.status_code in (200, 201),
                    f"HTTP {written.status_code}",
                )
            )

            # PERMIS — le relire, et retrouver l'ORDRE tel qu'il a été écrit.
            read = client.get(REST, headers=headers, params={"select": "user_id,games"})
            rows = read.json() if read.status_code == 200 else []
            mine = [r for r in rows if r["user_id"] == user_id]
            verdicts.append(
                (
                    "relire son profil",
                    len(mine) == 1 and mine[0]["games"] == ["pokemon", "magic"],
                    f"HTTP {read.status_code}, {mine[0]['games'] if mine else 'aucune ligne'}",
                )
            )

            # PERMIS mais BORNÉ — la lecture ne rend que sa propre ligne.
            verdicts.append(
                (
                    "ne voir que son profil",
                    len(rows) == len(mine),
                    f"{len(rows)} ligne(s) visible(s)",
                )
            )

            # PERMIS — déclarer ce qu'on paie un booster, et le relire.
            #
            # La politique `profiles_owner` est FOR ALL et porte sur la LIGNE :
            # elle est censée couvrir la colonne ajoutée sans être rejouée. Ce
            # « censée » est précisément ce qui se vérifie ici — un GRANT est
            # accordé table par table, pas colonne par colonne, mais rien ne
            # remplace le chemin réel.
            priced = client.post(
                REST,
                headers={**headers, "Prefer": "resolution=merge-duplicates,return=representation"},
                json={"user_id": user_id, "booster_prices": {"magic": 4.2}},
            )
            verdicts.append(
                (
                    "declarer son prix de booster",
                    priced.status_code in (200, 201),
                    f"HTTP {priced.status_code}",
                )
            )

            relu = client.get(
                REST, headers=headers, params={"select": "user_id,booster_prices"}
            )
            lignes = relu.json() if relu.status_code == 200 else []
            mien = [r for r in lignes if r["user_id"] == user_id]
            verdicts.append(
                (
                    "relire son prix de booster",
                    len(mien) == 1 and mien[0]["booster_prices"] == {"magic": 4.2},
                    f"HTTP {relu.status_code}, {mien[0]['booster_prices'] if mien else 'aucune ligne'}",
                )
            )

            # REFUSÉ — écrire le profil d'un autre.
            other = str(uuid.uuid4())
            forged = client.post(
                REST,
                headers=headers,
                json={"user_id": other, "games": ["magic"]},
            )
            verdicts.append(
                (
                    "REFUS d'ecrire le profil d'autrui",
                    forged.status_code in (401, 403),
                    f"HTTP {forged.status_code}",
                )
            )

            # REFUSÉ — effacer sa ligne, ce qui ferait revenir l'etape de choix.
            erased = client.delete(
                REST, headers=headers, params={"user_id": f"eq.{user_id}"}
            )
            still_there = client.get(
                REST, headers=headers, params={"select": "user_id"}
            ).json()
            verdicts.append(
                (
                    "REFUS d'effacer son profil",
                    len(still_there) == 1,
                    f"HTTP {erased.status_code}, {len(still_there)} ligne(s) restante(s)",
                )
            )
    finally:
        restore(config, user_id, initial)

    for name, ok, detail in verdicts:
        print(f"{'OK  ' if ok else 'ECHEC'} {name} ({detail})")

    failed = [v for v in verdicts if not v[1]]
    etat = (
        "aucune ligne"
        if initial is None
        else f"games = {initial[0]}, booster_prices = {initial[1]}"
    )
    print(f"\nProfil restauré dans son état initial : {etat}.")
    if failed:
        print(f"{len(failed)} contrôle(s) en échec.", file=sys.stderr)
        return 1
    print(f"{len(verdicts)} contrôles passés sur {TABLE}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
