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


#: Ce qu'est un terrain de base, littéralement comme la fonction éprouvée.
#:
#: **Le harnais comptait les terrains de base, la fonction non**, et l'écart
#: était mis au compte de la fonction. C'est l'inverse : la migration 034 sort
#: les terrains de base de *tout* le calcul — attendues, possédées, manquantes,
#: coût — parce qu'on ne les achète pas, on les prend dans la boîte. Les compter
#: donnait 30 % de complétion à une collection qui ne partage avec un deck que
#: ses Plaines, et rendait le classement muet.
#:
#: Le prédicat est recopié plutôt que dérivé : deux chemins vers le même nombre
#: n'en sont plus qu'un s'ils lisent la même définition. S'il change d'un côté
#: sans l'autre, c'est précisément ce que ce script doit faire apparaître.
#:
#: `LIKE` et non une égalité : couvre « Basic Land — Plains » comme « Basic Snow
#: Land — Island », sans attraper les terrains légendaires ni les bicolores, qui
#: eux s'achètent vraiment.
_BASIC_LAND = "c.type_line LIKE 'Basic Land%'"


def _basic_land_sql() -> str:
    """Le prédicat, prêt à être inséré dans une requête paramétrée.

    Le `%` du `LIKE` doit être doublé : psycopg lit ce caractère comme le début
    d'un marqueur de paramètre et refuse la requête. Le doublement se fait ici
    plutôt que dans la constante, pour que celle-ci reste lisible et se compare
    à l'œil avec la migration dont elle est la copie.
    """
    return _BASIC_LAND.replace("%", "%%")


@dataclass(frozen=True)
class Suggestion:
    deck_id: str
    deck_name: str
    total: int
    owned: int
    missing: int
    cost: float
    #: Terrains de base du deck, comptés à part et **hors** des quatre nombres
    #: ci-dessus. Voir `_BASIC_LAND` pour ce que cela recouvre.
    basics: int = 0


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


@dataclass(frozen=True)
class Seeded:
    """Ce qu'une mesure a écrit, et de quoi l'effacer entièrement."""

    deck_id: str
    #: Lignes de collection créées. Seules celles-là seront supprimées.
    item_ids: list[int]
    #: Cartes touchées, pour borner la purge du journal.
    oracle_ids: list[str]
    #: Dernier mouvement enregistré **avant** la mesure. Tout ce qui porte un
    #: identifiant supérieur et concerne ces cartes vient de nous.
    movement_mark: int


def seed(conn: psycopg.Connection, collection_id: str, fmt: str, game: str) -> Seeded:
    """Ajoute une partie d'un deck réel. Rend de quoi tout défaire.

    Le deck est choisi parmi les plus fournis en cartes distinctes : plus il y a
    de lignes, plus il y a d'occasions pour l'arithmétique de dérailler.

    **On rend les identifiants des lignes insérées, et c'est le point.** La
    collection du compte de test contient de vraies cartes ; vider la table
    après coup les emporterait. En ne supprimant que ce qu'on a créé, une carte
    déjà possédée est laissée intacte — `ON CONFLICT DO NOTHING` fait qu'elle
    n'est même pas touchée.

    **On relève aussi où en est le journal des mouvements.** Écrire dans la
    collection déclenche un trigger qui consigne chaque entrée et chaque sortie :
    une mesure laissait donc, pour chaque carte du deck, une acquisition suivie
    d'une restitution que l'utilisateur n'a jamais faites. Huit cents lignes
    fantômes pour quatre exécutions. Une mesure ne doit rien laisser derrière
    elle, pas même dans un journal qu'elle ne regarde pas.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(id), 0) FROM public.collection_movements")
        movement_mark = cur.fetchone()[0]

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
            RETURNING id, oracle_id::text
            """,
            (collection_id, OWNED_FRACTION, deck_id),
        )
        rows = cur.fetchall()
        conn.commit()
    return Seeded(
        deck_id=deck_id,
        item_ids=[r[0] for r in rows],
        oracle_ids=[r[1] for r in rows],
        movement_mark=movement_mark,
    )


def expected(conn: psycopg.Connection, collection_id: str, fmt: str, game: str) -> dict[str, Suggestion]:
    """Recompte tout, sans passer par la fonction éprouvée.

    **Les terrains de base sont comptés à part, et non ignorés.** Les exclure du
    total suffirait à faire concorder les deux calculs, mais aveuglerait ce
    script sur la règle elle-même : si la fonction cessait un jour de les
    écarter, plus rien ne le signalerait. Ils sont donc dénombrés séparément et
    confrontés au `basic_lands` que la fonction publie — l'exclusion devient une
    chose vérifiée plutôt qu'une chose supposée.
    """
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT dc.deck_id, d.name, dc.oracle_id, SUM(dc.quantity)::int,
                   COALESCE(mine.owned, 0), COALESCE(p.price_eur, 0),
                   bool_or({_basic_land_sql()}) AS is_basic
            FROM public.deck_cards dc
            JOIN public.decks d ON d.id = dc.deck_id
            JOIN public.cards c ON c.oracle_id = dc.oracle_id
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
    for deck_id, name, _oracle, needed, owned, price, is_basic in rows:
        # psycopg rend des UUID, PostgREST des chaînes : sans normalisation les
        # deux calculs ne se rencontrent jamais et tout paraît diverger.
        deck_id = str(deck_id)
        acc = decks.setdefault(
            deck_id,
            {"name": name, "total": 0, "owned": 0, "missing": 0, "cost": 0.0, "basics": 0},
        )
        if is_basic:
            acc["basics"] += needed
            continue

        missing = max(needed - owned, 0)
        acc["total"] += needed
        acc["owned"] += needed - missing
        acc["missing"] += missing
        acc["cost"] += missing * float(price)

    return {
        deck_id: Suggestion(
            deck_id, a["name"], a["total"], a["owned"], a["missing"], a["cost"], a["basics"]
        )
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
            r.get("basic_lands") or 0,
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
        for field in ("total", "owned", "missing", "basics"):
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


def cleanup(conn: psycopg.Connection, collection_id: str, planted: Seeded) -> int:
    """Efface les lignes créées **et** la trace qu'elles ont laissée au journal.

    Trois bornes, et chacune sert : au-delà du repère, sur les seules cartes
    semées, et sur les seules lignes sans édition — la mesure n'en écrit pas
    d'autres. Un ajout réel fait au même instant depuis le téléphone porterait
    presque toujours une édition, et de toute façon une autre carte.

    L'ordre importe : le journal d'abord, la collection ensuite. L'inverse
    ferait consigner la suppression par le trigger, donc créerait la ligne même
    qu'on cherche à retirer.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            DELETE FROM public.collection_movements
            WHERE collection_id = %s
              AND id > %s
              AND print_id IS NULL
              AND oracle_id = ANY(%s::uuid[])
            """,
            (collection_id, planted.movement_mark, planted.oracle_ids),
        )
        erased = cur.rowcount

        cur.execute(
            "DELETE FROM public.collection_items WHERE id = ANY(%s)",
            (planted.item_ids,),
        )

        # La suppression vient d'être consignée à son tour : même repère, mêmes
        # cartes, même absence d'édition.
        cur.execute(
            """
            DELETE FROM public.collection_movements
            WHERE collection_id = %s
              AND id > %s
              AND print_id IS NULL
              AND oracle_id = ANY(%s::uuid[])
            """,
            (collection_id, planted.movement_mark, planted.oracle_ids),
        )
        erased += cur.rowcount
        conn.commit()
    return erased


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

        planted: Seeded | None = None
        try:
            planted = seed(conn, collection_id, fmt, game)
            truth = expected(conn, collection_id, fmt, game)
            seen = observed(config, email, password, fmt, game)

            target = next((s for s in seen if s.deck_id == planted.deck_id), None)
            print(f"{len(seen)} decks confrontés, format {fmt} ({game}).")
            if target:
                print(
                    f"Deck de référence « {target.deck_name} » : "
                    f"{target.owned}/{target.total} possédées, "
                    f"{target.missing} manquantes, {target.cost:.2f} €"
                    + (
                        f" — {target.basics} terrains de base, hors du compte"
                        if target.basics
                        else ""
                    )
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
            if planted and planted.item_ids:
                erased = cleanup(conn, collection_id, planted)
                print(
                    f"{len(planted.item_ids)} ligne(s) ajoutée(s) pour la mesure, "
                    f"retirées — et {erased} mouvement(s) effacé(s) du journal."
                )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
