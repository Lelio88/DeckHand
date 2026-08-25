"""Éprouve la désignation sous `anon` — la seule écriture ouverte du projet.

**Pourquoi ce banc et pas une relecture du SQL.** La connexion d'ingestion est
propriétaire de la base : elle traverse RLS sans la voir, et un `GRANT` oublié
n'y produit aucune erreur. `public_request_spotlight` est la première fonction
que DeckHand ouvre en **écriture** à la clé anonyme ; la seule vérification qui
prouve quelque chose emprunte le chemin d'un inconnu, c'est-à-dire l'API REST
avec la clé anonyme et rien d'autre.

**Une politique se vérifie dans les deux sens.** Le cas permis prouve qu'elle
marche, le cas refusé qu'elle sert. Les contrôles se lisent donc par paires : ce
qu'un spectateur peut faire — désigner une carte, désigner une page — et ce
qu'il ne peut pas.

**Les contrôles qui comptent le plus sont ceux de la portée retirée *après* la
demande**, une fois pour une carte et une fois pour une page. Ils ne se déduisent
d'aucune lecture du code : la ligne existe toujours en base, elle est valide, et
c'est la lecture qui doit refuser de la rendre. Un filtre posé du côté écriture
passerait tous les autres et échouerait ceux-là, sans que rien ne le signale. Le
jumeau côté page n'est pas un doublon : le filtre porte sur une colonne
différente selon qu'il y a une carte ou non, et une page passerait au travers
d'un filtre écrit pour les cartes.

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

            # Une carte dont la collection tient **plusieurs illustrations** —
            # c'est le seul cas où le tapis a le droit de monter. Et une qui
            # n'en tient qu'une, pour éprouver le refus.
            cur.execute(
                """
                WITH tenues AS (
                    SELECT i.oracle_id,
                           MIN(p.set_code)         AS set_code,
                           MIN(p.collector_number) AS collector_number,
                           COUNT(DISTINCT COALESCE(
                               p.illustration_id::text,
                               p.set_code || '/' || p.collector_number)) AS dessins
                    FROM public.collection_items i
                    JOIN public.card_prints p ON p.scryfall_id = i.print_id
                    WHERE i.collection_id = %s
                    GROUP BY i.oracle_id
                )
                SELECT set_code, collector_number, dessins
                FROM tenues WHERE dessins > 1
                ORDER BY dessins DESC LIMIT 1
                """,
                (collection_id,),
            )
            plusieurs = cur.fetchone()

            cur.execute(
                """
                WITH tenues AS (
                    SELECT i.oracle_id,
                           MIN(p.set_code)         AS set_code,
                           MIN(p.collector_number) AS collector_number,
                           COUNT(DISTINCT COALESCE(
                               p.illustration_id::text,
                               p.set_code || '/' || p.collector_number)) AS dessins
                    FROM public.collection_items i
                    JOIN public.card_prints p ON p.scryfall_id = i.print_id
                    WHERE i.collection_id = %s
                    GROUP BY i.oracle_id
                )
                SELECT set_code, collector_number
                FROM tenues WHERE dessins = 1 LIMIT 1
                """,
                (collection_id,),
            )
            unique_dessin = cur.fetchone()

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

                def rouvrir() -> None:
                    """Recule la dernière demande pour lever le délai de garde.

                    Le délai est **partagé** entre cartes et pages — même ligne,
                    même écran. Sans ce recul, chaque contrôle suivant se ferait
                    refuser pour la mauvaise raison, et le banc annoncerait
                    conforme un verrou qu'il n'a pas éprouvé.
                    """
                    with conn.cursor() as cur:
                        cur.execute(
                            "UPDATE public.collection_spotlight "
                            "SET requested_at = NOW() - INTERVAL '1 minute' "
                            "WHERE collection_id = %s",
                            (collection_id,),
                        )

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

                rouvrir()
                page_ok = _rpc(client, anon, "public_request_spotlight_page", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_page": 1, "p_requested_by": "bob",
                })
                total += 1
                reussis += _verdict(
                    "désigner une page d'une extension qu'il possède", page_ok is True, True
                )

                vue = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                page_rendue = isinstance(vue, list) and len(vue) == 1
                total += 1
                reussis += _verdict("relire la page désignée", page_rendue, True)
                if page_rendue:
                    ligne = vue[0]
                    total += 1
                    reussis += _verdict(
                        f"    → {ligne.get('set_code','').upper()} page {ligne.get('page')} "
                        f"sur {ligne.get('pages')}, genre « {ligne.get('kind')} », "
                        f"demandée par {ligne.get('requested_by')}",
                        ligne.get("kind") == "page"
                        and ligne.get("page") == 1
                        # **Une page n'a pas de case, et n'en invente pas.** Un
                        # zéro ici désignerait une case qui n'existe pas.
                        and ligne.get("collector_number") is None
                        and (ligne.get("pages") or 0) >= 1,
                        True,
                    )

                if plusieurs is not None:
                    tapis_set, tapis_num, dessins = plusieurs
                    rouvrir()
                    tapis = _rpc(client, anon, "public_request_spotlight_strip", {
                        "p_handle": handle, "p_set_code": tapis_set,
                        "p_collector_number": tapis_num, "p_requested_by": "carol",
                    })
                    total += 1
                    reussis += _verdict(
                        f"désigner le tapis d'une carte tenue en {dessins} dessins",
                        tapis is True,
                        True,
                    )

                    lignes = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                    rendu_tapis = isinstance(lignes, list) and len(lignes) >= 2
                    total += 1
                    reussis += _verdict("relire toutes les versions d'un coup", rendu_tapis, True)
                    if rendu_tapis:
                        cases = {
                            f"{l.get('set_code','').upper()} #{l.get('collector_number')}"
                            for l in lignes
                        }
                        total += 1
                        reussis += _verdict(
                            "    → " + ", ".join(sorted(cases)),
                            # **Une ligne par version, toutes de genre `strip` et
                            # toutes sous la même demande** : c'est ce qui permet
                            # au calque de les regrouper sans rien deviner.
                            len(cases) == len(lignes)
                            and len(cases) == dessins
                            and all(l.get("kind") == "strip" for l in lignes)
                            and len({l.get("request_id") for l in lignes}) == 1,
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
                    rouvrir()
                    hors = _rpc(client, anon, "public_request_spotlight", {
                        "p_handle": handle, "p_set_code": set_code,
                        "p_collector_number": absente[0], "p_requested_by": "mallory",
                    })
                    total += 1
                    reussis += _verdict("désigner une case non possédée", hors is True, False)

                rouvrir()
                inconnue = _rpc(client, anon, "public_request_spotlight_page", {
                    "p_handle": handle, "p_set_code": "__aucune__",
                    "p_page": 1, "p_requested_by": "mallory",
                })
                total += 1
                reussis += _verdict(
                    "désigner une page d'une extension absente du classeur",
                    inconnue is True,
                    False,
                )

                rouvrir()
                zero = _rpc(client, anon, "public_request_spotlight_page", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_page": 0, "p_requested_by": "mallory",
                })
                total += 1
                reussis += _verdict("désigner la page zéro", zero is True, False)

                # **Le jumeau du contrôle décisif, côté page.** Le filtre de
                # portée a changé de colonne — il porte désormais sur la demande
                # et non sur la carte, faute de quoi une page, qui n'en a pas,
                # passerait au travers. Une relecture du SQL ne le dirait pas.
                rouvrir()
                _rpc(client, anon, "public_request_spotlight_page", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_page": 1, "p_requested_by": "bob",
                })
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE public.collections SET shared_sets = ARRAY[%s]::text[] WHERE id = %s",
                        ("__aucune__", collection_id),
                    )
                page_masquee = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                total += 1
                reussis += _verdict(
                    "voir une PAGE dont l'extension a été retirée du partage",
                    isinstance(page_masquee, list) and len(page_masquee) > 0,
                    False,
                )
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE public.collections SET shared_sets = %s WHERE id = %s",
                        (portee, collection_id),
                    )
                rouvrir()
                _rpc(client, anon, "public_request_spotlight", {
                    "p_handle": handle, "p_set_code": set_code,
                    "p_collector_number": numero, "p_requested_by": "alice",
                })

                if unique_dessin is not None:
                    rouvrir()
                    seul = _rpc(client, anon, "public_request_spotlight_strip", {
                        "p_handle": handle, "p_set_code": unique_dessin[0],
                        "p_collector_number": unique_dessin[1],
                        "p_requested_by": "mallory",
                    })
                    total += 1
                    reussis += _verdict(
                        "monter un tapis pour une carte tenue en un seul dessin",
                        seul is True,
                        False,
                    )

                # **Le tapis se masque aussi, version par version.** Une carte
                # possédée dans quatre extensions dont deux sont partagées n'en
                # montre que deux ; tout retirer ne doit rien laisser.
                if plusieurs is not None:
                    rouvrir()
                    _rpc(client, anon, "public_request_spotlight_strip", {
                        "p_handle": handle, "p_set_code": plusieurs[0],
                        "p_collector_number": plusieurs[1], "p_requested_by": "carol",
                    })
                    with conn.cursor() as cur:
                        cur.execute(
                            "UPDATE public.collections SET shared_sets = ARRAY[%s]::text[] "
                            "WHERE id = %s",
                            ("__aucune__", collection_id),
                        )
                    tapis_masque = _rpc(client, anon, "public_spotlight", {"p_handle": handle})
                    total += 1
                    reussis += _verdict(
                        "voir un TAPIS dont les extensions ont été retirées du partage",
                        isinstance(tapis_masque, list) and len(tapis_masque) > 0,
                        False,
                    )
                    with conn.cursor() as cur:
                        cur.execute(
                            "UPDATE public.collections SET shared_sets = %s WHERE id = %s",
                            (portee, collection_id),
                        )
                    rouvrir()
                    _rpc(client, anon, "public_request_spotlight", {
                        "p_handle": handle, "p_set_code": set_code,
                        "p_collector_number": numero, "p_requested_by": "alice",
                    })

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
