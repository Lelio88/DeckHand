"""Ingestion des extensions Scryfall dans `public.card_sets`.

**Ce job existe pour une seule colonne : `icon_svg_uri`.** Le symbole officiel
d'une extension est le marqueur que tout joueur reconnaît, et c'est ce que
l'étagère de classeurs affiche. Son URL ressemble pourtant assez au code
d'extension pour donner envie de la déduire, comme `fullCardImage` déduit la
carte de son illustration — mesuré sur les 1 047 extensions du catalogue, la
déduction est fausse deux fois sur trois :

* 342 extensions (32,7 %) ont une icône nommée d'après leur propre code ;
* 182 suivent la règle « `t` + code parent » (les jetons empruntent le symbole
  de leur extension mère : `tmsh` → `msh`) ;
* 523 sont arbitraires — `pl26` → `star`, `ysos` → `y26`.

D'où cette table. Elle porte aussi `set_type`, `parent_set_code` et
`card_count`, qui ne coûtent rien à ingérer et évitent d'y revenir.

**Le job est bon marché et idempotent** : une poignée de pages, un upsert par
extension. Il ne participe donc pas au saut de version qui protège le catalogue
des 390 Mo — le rejouer coûte moins cher que de vérifier s'il faut le rejouer.
"""

from __future__ import annotations

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_client import fetch_sets

UPSERT = """
    INSERT INTO public.card_sets
        (code, game, name, set_type, parent_set_code, released_at, card_count,
         icon_svg_uri, updated_at)
    VALUES (%s, 'magic', %s, %s, %s, %s, %s, %s, now())
    ON CONFLICT (code) DO UPDATE SET
        name            = EXCLUDED.name,
        set_type        = EXCLUDED.set_type,
        parent_set_code = EXCLUDED.parent_set_code,
        released_at     = EXCLUDED.released_at,
        card_count      = EXCLUDED.card_count,
        icon_svg_uri    = EXCLUDED.icon_svg_uri,
        updated_at      = now()
"""


def run(conn: psycopg.Connection | None = None) -> int:
    """Ingère toutes les extensions. Renvoie leur nombre.

    Accepte une connexion existante pour s'insérer dans un rafraîchissement en
    cours ; en ouvre une sinon, ce qui permet de lancer le module seul.
    """
    sets = fetch_sets()

    owns = conn is None
    conn = conn or psycopg.connect(SupabaseConfig.load().db_url, connect_timeout=30)

    try:
        with conn.cursor() as cur:
            cur.executemany(
                UPSERT,
                [
                    (
                        s["code"],
                        s.get("name") or s["code"].upper(),
                        s.get("set_type"),
                        s.get("parent_set_code"),
                        s.get("released_at"),
                        s.get("card_count"),
                        s.get("icon_svg_uri"),
                    )
                    for s in sets
                ],
            )
        conn.commit()
    finally:
        if owns:
            conn.close()

    return len(sets)


if __name__ == "__main__":
    print(f"{run()} extensions ingérées")
