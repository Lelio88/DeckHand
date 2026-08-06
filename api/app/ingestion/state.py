"""Mémoire des ingestions : ce qui a déjà été fait, et depuis quelle version.

Permet de sauter un rafraîchissement lorsque la source n'a pas bougé. Sans cela,
une exécution quotidienne retéléchargerait des centaines de mégaoctets pour
réécrire exactement les mêmes lignes.

Le marqueur de fraîcheur est du texte libre : chaque source l'exprime à sa
manière — Scryfall date ses exports, MTGJSON les versionne, TopDeck.gg n'offre
rien d'équivalent.
"""

from __future__ import annotations

import psycopg


def last_version(conn: psycopg.Connection, source: str) -> str | None:
    """Version de la source lors de la dernière ingestion réussie."""
    with conn.cursor() as cur:
        row = cur.execute(
            "SELECT source_version FROM public.ingestion_state WHERE source = %s",
            (source,),
        ).fetchone()
    return row[0] if row else None


def record(
    conn: psycopg.Connection,
    source: str,
    *,
    version: str | None,
    items: int,
    error: str | None = None,
) -> None:
    """Enregistre le résultat d'une ingestion.

    En cas d'échec, la version **n'est pas** mise à jour : la prochaine
    exécution retentera. Consigner une version après un échec ferait sauter le
    rafraîchissement suivant et masquerait durablement le problème.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO public.ingestion_state
                (source, source_version, last_run_at, items_processed, last_error)
            VALUES (%s, %s, NOW(), %s, %s)
            ON CONFLICT (source) DO UPDATE SET
                source_version  = COALESCE(EXCLUDED.source_version,
                                           public.ingestion_state.source_version),
                last_run_at     = NOW(),
                items_processed = EXCLUDED.items_processed,
                last_error      = EXCLUDED.last_error
            """,
            (source, None if error else version, items, error),
        )
    conn.commit()
