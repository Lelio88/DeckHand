"""Éprouve la désignation sous `anon` — la seule écriture ouverte du projet.

**Pourquoi ce banc et pas une relecture du SQL.** La connexion d'ingestion est
propriétaire de la base : elle traverse RLS sans la voir, et un `GRANT` oublié
n'y produit aucune erreur. `public_request_spotlight` est la première fonction
que DeckHand ouvre en **écriture** à la clé anonyme ; la seule vérification qui
prouve quelque chose emprunte le chemin d'un inconnu, c'est-à-dire l'API REST
avec la clé anonyme et rien d'autre.

**Une politique se vérifie dans les deux sens.** Le cas permis prouve qu'elle
marche, le cas refusé qu'elle sert. Les sept contrôles se lisent donc par
paires : ce qu'un spectateur peut faire, et les cinq choses qu'il ne peut pas.

**Le contrôle qui compte le plus est le sixième** — une extension retirée du
partage *après* la demande. Il ne se déduit d'aucune lecture du code : la ligne
existe toujours en base, elle est valide, et c'est la lecture qui doit refuser de
la rendre. Un filtre de portée posé du côté écriture passerait les cinq autres
contrôles et échouerait celui-là, sans que rien ne le signale.

L'état de la collection (publication, portée) est relevé puis **restauré** par la
connexion propriétaire, et la ligne de désignation effacée : le banc tourne sur
la collection réelle et ne doit rien laisser derrière lui.

Usage :

    cd api && .venv/Scripts/python -m app.measure.spotlight_rls
"""

from __future__ import annotations

import sys

import httpx
import psycopg

from app.config import SupabaseConfig


def _rpc(client: httpx.Client, key: str, fonction: str, corps: dict[str, object]) -> object:
    """Un appel à la porte publique sous la clé donnée, sans jeton d'utilisateur."""
    response = client.post(
        f"/rest/v1/rpc/{fonction}",
        json=corps,
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    if response.status_code >= 400:
        return {"_erreur": response.status_code, "_corps": response.text[:200]}
    return response.json()


def _verdict(libelle: str, obtenu: bool, attendu: bool) -> bool:
    marque = "OK  " if obtenu == attendu else "ECHEC"
    print(f"  {marque} {libelle}")
    return obtenu == attendu


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    config = SupabaseConfig.load()

    with psycopg.connect(config.db_url, connect_timeout=30, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, slug, is_public, shared_sets FROM public.collections "
                "ORDER BY created_at LIMIT 1"
            )
            ligne = cur.fetchone()
            if ligne is None:
                print("aucune collection en base — rien à mesurer")
                return 1
            collection_id, slug, etait_public, portee = ligne

            # Une case réellement possédée, et une qui ne l'est pas. La seconde
            # doit venir d'une extension que la collection touche, sinon le refus
            # pourrait s'expliquer par l'extension et non par la possession.
            cur.execute(
                """
                SELECT p.set_code, p.collector_number
                FROM public.collection_items i
                JOIN public.card_prints p ON p.scryfall_id = i.print_id
                WHERE i.collection_id = %s
                LIMIT 1
                """,
                (collection_id,),
            )
            possedee = cur.fetchone()
            if possedee is None:
                print("collection vide — rien à désigner")
                return 1
            set_code, numero = possedee

            cur.execute(
                """
                SELECT p.collector_number
                FROM public.card_prints p
                WHERE p.set_code = %s
                  AND NOT EXISTS (
                      SELECT 1 FROM public.collection_items i
                      JOIN public.card_prints q ON q.scryfall_id = i.print_id
                      WHERE i.collection_id = %s
                        AND q.set_code = p.set_code
                        AND q.collector_number = p.collector_number
                  )
                LIMIT 1
                """,
                (set_code, collection_id),
            )
            absente = cur.fetchone()

        handle = slug or str(collection_id)
        print(f"collection {handle} — case possédée {set_code.upper()} #{numero}")

        reussis = 0
        total = 0
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE public.collections SET is_public = true, shared_sets = NULL WHERE id = %s",
                    (collection_id,),
                )
                cur.execute("DELETE FROM public.collection_spotlight WHERE collection_id = %s", (collection_id,))

            with httpx.Client(base_url=config.url, timeout=30) as client:
                anon = config.anon_key

                print("\nce qu'un spectateur peut faire")
                accepte = _rpc(client, anon, "public_request_spotlight", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_collector_number": numero, "p_requested_by": "alice",
                })
                total += 1
                reussis += _verdict("désigner une case possédée d'un classeur publié", accepte is True, True)

                vu = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                rendu = isinstance(vu, list) and len(vu) == 1
                total += 1
                reussis += _verdict("relire la carte désignée", rendu, True)
                if rendu:
                    carte = vu[0]
                    total += 1
                    reussis += _verdict(
                        f"    → {carte.get('printed_name')} ({carte.get('set_code','').upper()} "
                        f"#{carte.get('collector_number')}), demandée par {carte.get('requested_by')}",
                        carte.get("requested_by") == "alice"
                        and carte.get("collector_number") == numero,
                        True,
                    )

                print("\nce qu'il ne peut pas")
                encore = _rpc(client, anon, "public_request_spotlight", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_collector_number": numero, "p_requested_by": "mallory",
                })
                total += 1
                reussis += _verdict("réécrire dans les trente secondes (délai de garde)", encore is True, False)

                if absente is not None:
                    with conn.cursor() as cur:
                        cur.execute(
                            "UPDATE public.collection_spotlight SET requested_at = NOW() - INTERVAL '1 minute' "
                            "WHERE collection_id = %s",
                            (collection_id,),
                        )
                    hors = _rpc(client, anon, "public_request_spotlight", {
                        "p_handle": handle, "p_set_code": set_code,
                        "p_collector_number": absente[0], "p_requested_by": "mallory",
                    })
                    total += 1
                    reussis += _verdict("désigner une case non possédée", hors is True, False)

                # Le contrôle décisif : la ligne existe et reste valide, seule la
                # portée a changé. C'est la lecture qui doit refuser.
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE public.collections SET shared_sets = ARRAY[%s]::text[] WHERE id = %s",
                        ("__aucune__", collection_id),
                    )
                masque = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                total += 1
                reussis += _verdict(
                    "voir une carte dont l'extension a été retirée du partage APRÈS la demande",
                    isinstance(masque, list) and len(masque) > 0,
                    False,
                )

                with conn.cursor() as cur:
                    cur.execute("UPDATE public.collections SET is_public = false WHERE id = %s", (collection_id,))
                ferme = _rpc(client, anon, "public_request_spotlight", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_collector_number": numero, "p_requested_by": "mallory",
                })
                total += 1
                reussis += _verdict("désigner sur un classeur non publié", ferme is True, False)

                table = client.get(
                    "/rest/v1/collection_spotlight",
                    params={"select": "*"},
                    headers={"apikey": anon, "Authorization": f"Bearer {anon}"},
                )
                lu = table.status_code == 200 and table.json() not in ([], None)
                total += 1
                reussis += _verdict("lire la table directement, sans passer par la fonction", lu, False)
        finally:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM public.collection_spotlight WHERE collection_id = %s", (collection_id,))
                cur.execute(
                    "UPDATE public.collections SET is_public = %s, shared_sets = %s WHERE id = %s",
                    (etait_public, portee, collection_id),
                )
            print(f"\nétat restauré : is_public={etait_public}, shared_sets={portee}")

    print(f"\n{reussis}/{total} contrôles conformes")
    return 0 if reussis == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
