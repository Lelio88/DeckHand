"""Vérifie que l'écran Decks dit vrai : cartes manquantes et coût de complétion.

**Pourquoi un recalcul plutôt qu'un coup d'œil.** Les chiffres de cet écran sont
la promesse du produit — « il te manque 3 cartes pour 4,20 € » engage l'argent
de l'utilisateur. Or ils sortent d'une fonction SQL dont personne n'a vérifié
l'arithmétique sur une collection réelle : une collection vide donne toujours
« il te manque tout », ce qui ne prouve rien. Regarder l'écran ne prouverait
rien non plus, faute de savoir ce qu'il *devrait* afficher.

Ce script construit donc une collection dont il connaît le contenu exact,
interroge la base **comme le fait l'application** — en REST, authentifié, pour
que `auth.uid()` soit celui du compte —, puis recompte tout de son côté depuis
`deck_cards` et `collection_items`. Deux chemins indépendants vers le même
nombre : s'ils divergent, l'un des deux ment.

**La collection est restaurée à son état initial**, y compris en cas d'échec :
elle appartient au compte de test, où sont saisies de vraies cartes.

Usage :
    cd api && .venv/Scripts/python -m app.measure.deck_math
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

import httpx
import psycopg

from app.config import SupabaseConfig, load_env_file

#: Format éprouvé par défaut. Pauper est le cas qui compte pour Magic — c'est
#: le seul où une collection ordinaire produit des decks réellement complets.
#: Le couple (format, jeu) se surcharge en ligne de commande :
#:     python -m app.measure.deck_math constructed riftbound
FORMAT = "pauper"
GAME = "magic"

#: Fraction des exemplaires d'un deck que l'on feint de posséder. Choisie
#: incomplète à dessein : posséder tout ou rien ne vérifierait pas le décompte
#: des quantités, qui est l'endroit où un moteur de complétion se trompe.
OWNED_FRACTION = 0.6


@dataclass(frozen=True)
class Suggestion:
    deck_id: str
    deck_name: str
    total: int
    owned: int
    missing: int
    cost: float


def collection_of(conn: psycopg.Connection, email: str) -> str:
    """Identifiant de la collection du compte, créée au besoin."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT c.id FROM public.collections c
            JOIN auth.users u ON u.id = c.owner_id
            WHERE u.email = %s
            """,
            (email,),
        )
        row = cur.fetchone()
        if row:
            return row[0]

        cur.execute(
            """
            INSERT INTO public.collections (owner_id)
            SELECT id FROM auth.users WHERE email = %s
            RETURNING id
            """,
            (email,),
        )
        created = cur.fetchone()
        if created is None:
            raise SystemExit(f"Aucun compte {email} dans auth.users.")
        conn.commit()
        return created[0]


def seed(conn: psycopg.Connection, collection_id: str, fmt: str, game: str) -> tuple[str, list[int]]:
    """Ajoute une partie d'un deck réel. Rend l'id du deck et les lignes créées.

    Le deck est choisi parmi les plus fournis en cartes distinctes : plus il y a
    de lignes, plus il y a d'occasions pour l'arithmétique de dérailler.

    **On rend les identifiants des lignes insérées, et c'est le point.** La
    collection du compte de test contient de vraies cartes ; vider la table
    après coup les emporterait. En ne supprimant que ce qu'on a créé, une carte
    déjà possédée est laissée intacte — `ON CONFLICT DO NOTHING` fait qu'elle
    n'est même pas touchée.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT dc.deck_id
            FROM public.deck_cards dc
            JOIN public.decks d ON d.id = dc.deck_id
            WHERE d.format = %s AND d.game = %s AND dc.board = 'main'
            GROUP BY dc.deck_id
            ORDER BY COUNT(*) DESC, dc.deck_id
            LIMIT 1
            """,
            (fmt, game),
        )
        deck_id = cur.fetchone()[0]

        # On possède une fraction des exemplaires de chaque carte : le deck
        # devient partiellement constructible, et chaque ligne exerce le calcul
        # `needed - owned` au lieu de le court-circuiter par un zéro.
        cur.execute(
            """
            INSERT INTO public.collection_items (collection_id, oracle_id, quantity)
            SELECT %s, dc.oracle_id, GREATEST(1, FLOOR(SUM(dc.quantity) * %s)::int)
            FROM public.deck_cards dc
            WHERE dc.deck_id = %s AND dc.board = 'main'
            GROUP BY dc.oracle_id
            ON CONFLICT DO NOTHING
            RETURNING id
            """,
            (collection_id, OWNED_FRACTION, deck_id),
        )
        inserted = [row[0] for row in cur.fetchall()]
        conn.commit()
    return deck_id, inserted


def expected(conn: psycopg.Connection, collection_id: str, fmt: str, game: str) -> dict[str, Suggestion]:
    """Recompte tout, sans passer par la fonction éprouvée."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT dc.deck_id, d.name, dc.oracle_id, SUM(dc.quantity)::int,
                   COALESCE(mine.owned, 0), COALESCE(p.price_eur, 0)
            FROM public.deck_cards dc
            JOIN public.decks d ON d.id = dc.deck_id
            LEFT JOIN (
                SELECT oracle_id, SUM(quantity)::int AS owned
                FROM public.collection_items
                WHERE collection_id = %s
                GROUP BY oracle_id
            ) mine ON mine.oracle_id = dc.oracle_id
            LEFT JOIN public.card_cheapest_price p ON p.oracle_id = dc.oracle_id
            WHERE d.format = %s AND d.game = %s AND dc.board = 'main'
            GROUP BY dc.deck_id, d.name, dc.oracle_id, mine.owned, p.price_eur
            """,
            (collection_id, fmt, game),
        )
        rows = cur.fetchall()

    decks: dict[str, dict] = {}
    for deck_id, name, _oracle, needed, owned, price in rows:
        # psycopg rend des UUID, PostgREST des chaînes : sans normalisation les
        # deux calculs ne se rencontrent jamais et tout paraît diverger.
        deck_id = str(deck_id)
        missing = max(needed - owned, 0)
        acc = decks.setdefault(
            deck_id, {"name": name, "total": 0, "owned": 0, "missing": 0, "cost": 0.0}
        )
        acc["total"] += needed
        acc["owned"] += needed - missing
        acc["missing"] += missing
        acc["cost"] += missing * float(price)

    return {
        deck_id: Suggestion(deck_id, a["name"], a["total"], a["owned"], a["missing"], a["cost"])
        for deck_id, a in decks.items()
    }


def observed(config: SupabaseConfig, email: str, password: str, fmt: str, game: str) -> list[Suggestion]:
    """Interroge la base comme le fait l'application."""
    with httpx.Client(base_url=config.url, timeout=60) as client:
        auth = client.post(
            "/auth/v1/token",
            params={"grant_type": "password"},
            headers={"apikey": config.anon_key},
            json={"email": email, "password": password},
        )
        auth.raise_for_status()
        token = auth.json()["access_token"]

        response = client.post(
            "/rest/v1/rpc/deck_suggestions",
            headers={"apikey": config.anon_key, "Authorization": f"Bearer {token}"},
            # Aucun plafond : on veut confronter chaque deck, pas les mieux
            # classés — une erreur d'arithmétique se cache volontiers en bas.
            json={
                "p_format": fmt,
                "p_game": game,
                "p_max_missing": 10_000,
                "p_max_results": 100,
            },
        )
        response.raise_for_status()

    return [
        Suggestion(
            r["deck_id"],
            r["deck_name"],
            r["total_cards"],
            r["owned_cards"],
            r["missing_cards"],
            float(r["missing_cost_eur"] or 0),
        )
        for r in response.json()
    ]


def compare(seen: list[Suggestion], truth: dict[str, Suggestion]) -> list[str]:
    """Relève les écarts. Le coût tolère le centime, jamais la carte."""
    faults: list[str] = []
    for s in seen:
        t = truth.get(s.deck_id)
        if t is None:
            faults.append(f"deck inconnu du recalcul : {s.deck_name}")
            continue
        for field in ("total", "owned", "missing"):
            if getattr(s, field) != getattr(t, field):
                faults.append(
                    f"{s.deck_name} — {field} : annoncé {getattr(s, field)}, "
                    f"recalculé {getattr(t, field)}"
                )
        if abs(s.cost - t.cost) > 0.01:
            faults.append(
                f"{s.deck_name} — coût : annoncé {s.cost:.2f} €, recalculé {t.cost:.2f} €"
            )
    return faults


def main(argv: list[str]) -> int:
    fmt = argv[0] if argv else FORMAT
    game = argv[1] if len(argv) > 1 else GAME
    values = load_env_file("supabase.env")
    email = values.get("DECKHAND_TEST_EMAIL")
    password = values.get("DECKHAND_TEST_PASSWORD")
    if not email or not password:
        print("Compte de test absent de supabase.env.", file=sys.stderr)
        return 64

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        collection_id = collection_of(conn, email)

        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM public.collection_items WHERE collection_id = %s",
                (collection_id,),
            )
            existing = cur.fetchone()[0]
        if existing:
            print(f"{existing} carte(s) déjà en collection — elles seront préservées.")

        inserted: list[int] = []
        try:
            deck_id, inserted = seed(conn, collection_id, fmt, game)
            truth = expected(conn, collection_id, fmt, game)
            seen = observed(config, email, password, fmt, game)

            target = next((s for s in seen if s.deck_id == deck_id), None)
            print(f"{len(seen)} decks confrontés, format {fmt} ({game}).")
            if target:
                print(
                    f"Deck de référence « {target.deck_name} » : "
                    f"{target.owned}/{target.total} possédées, "
                    f"{target.missing} manquantes, {target.cost:.2f} €"
                )

            faults = compare(seen, truth)
            if faults:
                print(f"\n{len(faults)} écart(s) :")
                for fault in faults[:20]:
                    print(f"  {fault}")
                return 1

            print("\nAucun écart : les deux calculs concordent sur tous les decks.")
            return 0
        finally:
            if inserted:
                with conn.cursor() as cur:
                    cur.execute(
                        "DELETE FROM public.collection_items WHERE id = ANY(%s)",
                        (inserted,),
                    )
                    conn.commit()
                print(f"{len(inserted)} ligne(s) ajoutée(s) pour la mesure, retirées.")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
