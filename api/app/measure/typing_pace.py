"""Rythme de saisie d'une collection : combien de temps coûte une carte.

**Pourquoi lire la base plutôt que chronométrer à la main.** Un chronomètre
global donne une moyenne, et une moyenne masque exactement ce qu'on cherche :
la carte qui a pris quarante secondes parce que son nom se lisait mal, ou parce
que le sélecteur d'édition a fait hésiter. `collection_items.added_at` horodate
chaque ajout ; les intervalles entre lignes successives rendent visible le
grain de la saisie, friction par friction.

Le produit vise 500 à 2 000 cartes. À dix secondes la carte, une collection de
mille demande près de trois heures — le rythme n'est donc pas un détail de
confort, c'est ce qui décide si la promesse tient.

**Limite assumée.** Seules les lignes créées portent un horodatage : ajouter un
exemplaire à une carte déjà saisie met à jour la quantité sans créer de ligne,
et cet ajout-là reste invisible. La mesure porte donc sur des cartes distinctes,
ce qui est le cas d'une première saisie.

Usage :
    cd api && .venv/Scripts/python -m app.measure.typing_pace [courriel]

Le courriel vaut par défaut celui du compte de test.
"""

from __future__ import annotations

import statistics
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta

import psycopg

from app.config import SupabaseConfig, load_env_file

#: Au-delà, ce n'est plus une carte saisie mais une pause — on ne compte pas le
#: temps passé à répondre au téléphone dans le coût d'une carte.
PAUSE_THRESHOLD = timedelta(seconds=90)


@dataclass(frozen=True)
class Entry:
    """Une carte saisie, avec le temps qu'elle a demandé."""

    name: str
    added_at: datetime
    gap: timedelta | None
    has_print: bool


def fetch(conn: psycopg.Connection, email: str) -> list[Entry]:
    """Récupère les ajouts d'un utilisateur, du plus ancien au plus récent."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT c.name, ci.added_at, ci.print_id IS NOT NULL
            FROM public.collection_items ci
            JOIN public.collections c2 ON c2.id = ci.collection_id
            JOIN auth.users u ON u.id = c2.owner_id
            JOIN public.cards c ON c.oracle_id = ci.oracle_id
            WHERE u.email = %s
            ORDER BY ci.added_at
            """,
            (email,),
        )
        rows = cur.fetchall()

    entries: list[Entry] = []
    previous: datetime | None = None
    for name, added_at, has_print in rows:
        gap = None if previous is None else added_at - previous
        entries.append(Entry(name, added_at, gap, has_print))
        previous = added_at
    return entries


def report(entries: list[Entry]) -> str:
    """Résume le rythme, et nomme les cartes qui ont coûté le plus cher."""
    if len(entries) < 2:
        return f"{len(entries)} carte(s) — trop peu pour un rythme."

    gaps = [e.gap for e in entries if e.gap is not None]
    working = [g for g in gaps if g <= PAUSE_THRESHOLD]
    pauses = [g for g in gaps if g > PAUSE_THRESHOLD]

    seconds = sorted(g.total_seconds() for g in working)
    if not seconds:
        return "Aucun intervalle sous le seuil de pause — saisie trop espacée."

    def quantile(q: float) -> float:
        return seconds[min(int(len(seconds) * q), len(seconds) - 1)]

    span = entries[-1].added_at - entries[0].added_at
    precised = sum(1 for e in entries if e.has_print)

    slowest = sorted(
        (e for e in entries if e.gap is not None and e.gap <= PAUSE_THRESHOLD),
        key=lambda e: e.gap,
        reverse=True,
    )[:5]

    lines = [
        f"{len(entries)} cartes saisies en {span}, dont {len(pauses)} interruption(s).",
        f"Édition précisée sur {precised} carte(s) — le reste est valorisé au plancher.",
        "",
        f"Temps par carte (hors pauses) — médiane {statistics.median(seconds):.1f} s · "
        f"q1 {quantile(0.25):.1f} s · q3 {quantile(0.75):.1f} s · max {seconds[-1]:.1f} s",
        f"Projection à 500 cartes : {statistics.median(seconds) * 500 / 60:.0f} min · "
        f"à 2 000 : {statistics.median(seconds) * 2000 / 3600:.1f} h",
        "",
        "Les plus longues — ce sont elles qui portent les frictions :",
    ]
    lines += [
        f"  {e.gap.total_seconds():5.1f} s  {e.name}"
        f"{' (édition précisée)' if e.has_print else ''}"
        for e in slowest
    ]
    return "\n".join(lines)


def main() -> int:
    email = sys.argv[1] if len(sys.argv) > 1 else None
    if email is None:
        values = load_env_file("supabase.env")
        email = values.get("DECKHAND_TEST_EMAIL")
        if not email:
            print("Aucun courriel : passez-le en argument.", file=sys.stderr)
            return 64

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        entries = fetch(conn, email)

    if not entries:
        print(f"Aucune carte en collection pour {email}.")
        return 0

    print(report(entries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
