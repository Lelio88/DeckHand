"""Où tombe une empreinte relevée sur le terrain, dans l'index réel.

**Pourquoi ce banc existe.** Le journal de l'application dit quelle carte
l'empreinte a désignée, à quelle distance et avec quelle marge — mais pas où se
trouve la carte qu'on tenait réellement dans la main. Or c'est cette seule
valeur qui départage les deux causes d'un échec de reconnaissance :

- la bonne carte est deuxième ou troisième, à deux ou trois bits du vainqueur →
  l'illustration est correctement prélevée, et ce sont les **seuils** qui
  refusent de trancher ;
- la bonne carte est au-delà de la centième → l'illustration n'est pas prélevée
  au bon endroit, et c'est le **gabarit** qu'il faut reprendre.

Le premier cas se règle en calibrant, le second en mesurant à nouveau la zone
d'illustration. Les confondre coûte des jours.

**Ce qu'il faut lui donner.** L'empreinte est journalisée en clair par
l'application depuis le terrain (`art_hash` dans `DHDIAG`), précisément pour
que ce banc puisse exister : la photo, elle, vit dans le cache interne de
l'application et n'est pas récupérable sur un build de production.

Usage :

    python -m app.measure.art_probe <hash_hex> --game riftbound --expect "Icevale Archer"

Invariant à préserver : la distance calculée ici doit être **exactement** celle
que calcule `ArtHashIndex.search` côté Dart — même sérialisation (16 chiffres
hexadécimaux, gros-boutiste, tels que `art_hash_page` les sert) et même
distance de Hamming sur 64 bits. Toute divergence rendrait ce banc menteur
plutôt qu'utile.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import psycopg

# La console Windows sort en cp1252, qui ne connaît ni « ≤ » ni les guillemets
# français. Sans cela le banc s'interrompt sur sa dernière ligne, après avoir
# fait tout son travail — un échec d'affichage qui ressemble à un échec de
# mesure.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

SECRETS = Path(r"C:\Users\buton\Documents\Projets\.deckhand-secrets\supabase.env")


def database_url() -> str:
    """Lit l'URL de connexion depuis le coffre hors dépôt."""
    for line in SECRETS.read_text(encoding="utf-8").splitlines():
        if line.startswith("SUPABASE_DB_URL="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("SUPABASE_DB_URL absent du coffre de secrets")


def hamming(a: int, b: int) -> int:
    """Nombre de bits qui diffèrent entre deux empreintes 64 bits."""
    return ((a ^ b) & 0xFFFFFFFFFFFFFFFF).bit_count()


def as_unsigned(dhash: int) -> int:
    """Ramène le `bigint` signé de Postgres à ses 64 bits non signés.

    La colonne est signée parce que Postgres n'a pas d'entier 64 bits non
    signé ; l'empreinte, elle, est un motif de bits. Comparer sans ce repli
    ferait diverger les distances sur la moitié du catalogue.
    """
    return dhash & 0xFFFFFFFFFFFFFFFF


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hash_hex", help="empreinte relevée, 16 chiffres hexadécimaux")
    parser.add_argument("--game", default="riftbound")
    parser.add_argument(
        "--expect",
        help="nom de la carte réellement photographiée, pour en donner le rang",
    )
    parser.add_argument("--top", type=int, default=10)
    args = parser.parse_args()

    query = int(args.hash_hex.strip().lower().replace("0x", ""), 16)

    with psycopg.connect(database_url()) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT h.oracle_id, h.dhash, c.name, c.type_line
            FROM art_hashes h
            JOIN cards c ON c.oracle_id = h.oracle_id
            WHERE c.game = %s
            """,
            (args.game,),
        )
        rows = cur.fetchall()

    if not rows:
        raise SystemExit(f"aucune empreinte pour le jeu {args.game}")

    # Une entrée par illustration : plusieurs impressions partagent la même.
    seen: dict[str, tuple[int, str, str]] = {}
    for oracle_id, dhash, name, type_line in rows:
        key = str(oracle_id)
        distance = hamming(query, as_unsigned(dhash))
        if key not in seen or distance < seen[key][0]:
            seen[key] = (distance, name, type_line)

    ranked = sorted(seen.items(), key=lambda kv: kv[1][0])

    print(f"empreinte  {args.hash_hex}")
    print(f"catalogue  {len(ranked)} illustrations ({args.game})\n")
    print(f"--- les {args.top} plus proches ---")
    for rank, (oracle_id, (distance, name, type_line)) in enumerate(
        ranked[: args.top], start=1
    ):
        print(f"{rank:>3}. {distance:>3} bits  {name}  [{type_line}]")

    if args.expect:
        print(f"\n--- où tombe « {args.expect} » ---")
        found = False
        for rank, (oracle_id, (distance, name, _)) in enumerate(ranked, start=1):
            if name.lower() == args.expect.lower():
                print(f"rang {rank} sur {len(ranked)}, à {distance} bits")
                found = True
        if not found:
            print("cette carte n'a pas d'empreinte au catalogue")

    # Les seuils de l'application, rappelés pour lire les chiffres ci-dessus.
    print("\nseuils : distance de confiance ≤ 12, marge minimale 4")


if __name__ == "__main__":
    main()
