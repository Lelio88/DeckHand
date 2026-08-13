"""Écriture des decks en base, commune à toutes les sources.

Chaque connecteur produit des decklists nommées ; ce module les résout vers le
catalogue et les enregistre. Centraliser ici évite que chaque source réinvente
la résolution et le seuil de qualité.

**Seuil de qualité** : un deck dont trop de cartes restent introuvables est
rejeté plutôt qu'enregistré amputé. Un deck de 60 cartes stocké avec 55 d'entre
elles paraîtrait presque complet à l'utilisateur et fausserait tout le calcul de
complétion — c'est-à-dire la promesse même du produit.
"""

from __future__ import annotations

from dataclasses import dataclass

import psycopg

from app.ingestion.card_resolver import CardResolver

# Proportion maximale de cartes non résolues tolérée dans un deck.
# 5 % laisse passer une carte égarée sur 60, pas une decklist mal lue.
MAX_UNRESOLVED_RATIO = 0.05


@dataclass
class IngestReport:
    """Ce qu'un import a produit — et ce qu'il a laissé de côté."""

    inserted: int = 0
    skipped_incomplete: int = 0
    unresolved_names: dict[str, int] | None = None

    def summary(self) -> str:
        lines = [
            f"decks enregistrés : {self.inserted}",
            f"decks écartés (trop de cartes inconnues) : {self.skipped_incomplete}",
        ]
        if self.unresolved_names:
            worst = sorted(self.unresolved_names.items(), key=lambda kv: -kv[1])[:10]
            lines.append(f"noms non résolus : {len(self.unresolved_names)} distincts")
            lines.extend(f"    {count:4}x  {name}" for name, count in worst)
        return "\n".join(lines)


def load_name_index(
    conn: psycopg.Connection, game: str | None = None
) -> dict[str, str]:
    """Charge l'index nom normalisé -> oracle_id.

    Le catalogue tient largement en mémoire ; interroger la base une fois par
    carte de chaque decklist serait absurde.

    **`game` borne l'index à un seul catalogue, et il faut le passer.** La table
    est partagée par les trois jeux, et **227 noms normalisés sont portés par
    plusieurs d'entre eux** — « Blizzard », « Backfire », « Change of Heart »,
    « Apprenti sorcier ». Sans ce filtre, un deck reçoit l'une ou l'autre carte
    selon l'ordre des lignes rendues par la base, et rien ne le signale : la
    decklist se résout, le deck s'enregistre, et une carte d'un autre jeu y
    dort. Le paramètre reste facultatif pour ne pas rompre l'appel des sources
    qui fournissent un identifiant plutôt qu'un nom.
    """
    query = "SELECT s.normalized, s.oracle_id::text FROM public.card_search_names s"
    params: tuple = ()
    if game is not None:
        query += (
            " JOIN public.cards c ON c.oracle_id = s.oracle_id WHERE c.game = %s"
        )
        params = (game,)

    with conn.cursor() as cur:
        rows = cur.execute(query, params).fetchall()
    return {normalized: oracle_id for normalized, oracle_id in rows}


def store_deck(
    conn: psycopg.Connection,
    *,
    source_id: str,
    external_id: str,
    name: str,
    fmt: str,
    tier: str,
    mainboard: dict[str, int],
    sideboard: dict[str, int],
    resolver: CardResolver,
    commander_oracle_id: str | None = None,
    source_url: str | None = None,
    recorded_at=None,
    game: str = "magic",
    min_main_cards: int = 0,
) -> bool:
    """Enregistre un deck. Renvoie False s'il a été écarté comme trop lacunaire.

    L'écriture est idempotente : réimporter le même deck remplace ses cartes au
    lieu de les dupliquer.
    """
    main_resolved, main_missing = resolver.resolve_deck(mainboard)
    side_resolved, _ = resolver.resolve_deck(sideboard)

    total_main = sum(mainboard.values())
    if total_main == 0:
        return False
    if main_missing / total_main > MAX_UNRESOLVED_RATIO:
        return False
    # **Un deck trop court n'est pas un deck.** Le seuil précédent ne mesurait
    # que la proportion de cartes inconnues : une decklist enregistrée à moitié
    # à la source la franchissait sans peine, puisque le peu qu'elle contient se
    # résout parfaitement. Elle apparaîtrait ensuite comme presque constructible,
    # ce qui est le pire défaut possible pour ce produit.
    if total_main < min_main_cards:
        return False

    with conn.cursor() as cur:
        deck_id = cur.execute(
            """
            INSERT INTO public.decks (source_id, external_id, name, format, tier,
                                      commander_oracle_id, source_url, recorded_at,
                                      game)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (source_id, external_id) DO UPDATE SET
                name = EXCLUDED.name,
                recorded_at = EXCLUDED.recorded_at,
                -- **L'identité du commandant doit suivre**, pour la raison qui
                -- vaut déjà pour `card_prints.oracle_id` : quand la règle
                -- d'identité d'un jeu change, un deck déjà connu resterait
                -- accroché à une carte qui n'existe plus. Mesuré sur Riftbound :
                -- les cartes citées par les decklists s'étaient repointées, mais
                -- 48 anciennes cartes survivaient à la purge, retenues par cette
                -- seule colonne — et par elle seule, aucune n'étant plus citée
                -- par une decklist ni par une collection.
                commander_oracle_id = EXCLUDED.commander_oracle_id,
                -- Le jeu suit : une source qui couvre deux catalogues pourrait
                -- réattribuer un identifiant externe, et un deck Riftbound resté
                -- étiqueté « magic » polluerait les suggestions de l'autre jeu.
                game = EXCLUDED.game
            RETURNING id
            """,
            (source_id, external_id, name, fmt, tier,
             commander_oracle_id, source_url, recorded_at, game),
        ).fetchone()[0]

        # Remplacement plutôt que fusion : une decklist révisée à la source ne
        # doit pas laisser d'anciennes cartes derrière elle.
        cur.execute("DELETE FROM public.deck_cards WHERE deck_id = %s", (deck_id,))

        rows = [(deck_id, oid, qty, "main") for oid, qty in main_resolved.items()]
        rows += [(deck_id, oid, qty, "side") for oid, qty in side_resolved.items()
                 if oid not in main_resolved]

        if rows:
            cur.executemany(
                """
                INSERT INTO public.deck_cards (deck_id, oracle_id, quantity, board)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (deck_id, oracle_id, board) DO UPDATE
                    SET quantity = EXCLUDED.quantity
                """,
                rows,
            )

    return True
