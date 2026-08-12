"""Exporte le tirage du banc de cadrage, pour que Dart puisse le rejouer.

**Pourquoi cet export existe.** `framing_bench.py` mesure la détection de bords
du jumeau **Python**. Or le code qui tourne sur le téléphone est le Dart, et
c'est lui qu'il faut départager quand plusieurs approches de détection sont en
concurrence. Porter quatre approches Dart vers Python multiplierait les
occasions de se tromper ; porter le banc une fois vers Dart ne les multiplie
pas.

Il ne reste alors qu'un obstacle : Dart n'a pas de client Postgres dans ce
projet, et n'a donc accès ni au tirage ni aux empreintes de référence. Ce
script les écrit dans un fichier que le banc Dart lit.

**Le tirage est le même que celui de `framing_bench.py`**, à la requête près :
même filtre, même `ORDER BY md5(...)`, même sel. Deux bancs qui mesureraient des
cartes différentes ne seraient pas comparables, et l'écart entre eux se
confondrait avec l'écart entre deux paquets.

Usage :
    python -m app.measure.export_framing_set --cards 40 --out ../app/tool/framing_set.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import psycopg

from app.config import SupabaseConfig
from app.vision.dhash import from_signed_64


def export(
    cards: int,
    game: str = "magic",
    layout: str = "normal",
    salt: str = "cadrage",
) -> list[dict[str, object]]:
    """Le tirage, avec pour chaque carte son image et son empreinte attendue.

    [layout] sélectionne la disposition : `normal` pour les cartes Magic,
    `portrait` ou `landscape` pour Riftbound. C'est lui qui permet de tirer un
    lot de **cartes couchées**, que le banc ne savait pas mesurer — et donc de
    chiffrer un défaut qui, faute de tirage, restait une affirmation.
    """
    config = SupabaseConfig.load()
    # Le filtre de langue et de date ne vaut que pour Magic : Riftbound n'a
    # qu'une langue au catalogue et une seule année d'impressions, et les
    # appliquer viderait le tirage sans le dire.
    magic_only = (
        "AND p.lang = 'en' AND p.released_at >= '2004-01-01'"
        if game == "magic"
        else ""
    )
    query = f"""
        SELECT p.scryfall_id::text, p.art_crop_url, a.dhash, c.layout
        FROM public.card_prints p
        JOIN public.art_hashes a ON a.scryfall_id = p.scryfall_id
        JOIN public.cards c ON c.oracle_id = p.oracle_id
        WHERE c.game = %s
          AND c.layout = %s
          {magic_only}
        ORDER BY md5(p.scryfall_id::text || %s)
        LIMIT %s
    """
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (game, layout, salt, cards))
            rows = cur.fetchall()

    return [
        {
            "id": sid,
            # L'image de la carte entière, pas de l'illustration seule : le banc
            # compose une photo, il lui faut la carte telle qu'on la pose.
            #
            # Scryfall sert la même image sous plusieurs tailles au même chemin,
            # d'où la substitution. Riftcodex, lui, ne publie que la carte
            # entière : son URL est déjà la bonne et ne contient pas ce segment,
            # le remplacement y est donc sans effet.
            "url": url.replace("/art_crop/", "/normal/"),
            # Les 64 bits en hexadécimal, la forme que lit `ArtHash.fromHex`.
            # Le passage par le non-signé est indispensable : Postgres stocke
            # un `bigint` signé, et Dart lirait autre chose sans ce repli.
            "hash": f"{from_signed_64(dhash) & 0xFFFFFFFFFFFFFFFF:016x}",
            # Le tirage décrit ce qu'il contient : le banc en déduit le gabarit
            # à appliquer et l'orientation dans laquelle poser la carte, au lieu
            # de les supposer.
            "game": game,
            "layout": card_layout,
        }
        for sid, url, dhash, card_layout in rows
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cards", type=int, default=40)
    parser.add_argument("--game", default="magic")
    parser.add_argument(
        "--layout",
        default="normal",
        help="normal (Magic), portrait ou landscape (Riftbound)",
    )
    parser.add_argument("--out", default="../app/tool/framing_set.json")
    args = parser.parse_args()

    entries = export(args.cards, game=args.game, layout=args.layout)
    path = Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, indent=1), encoding="utf-8")
    print(f"{len(entries)} cartes écrites dans {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
