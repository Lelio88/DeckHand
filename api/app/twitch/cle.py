"""Pose — ou renouvelle — la clé qui autorise le bot à écrire sur le calque.

    cd api && .venv/Scripts/python -m app.twitch.cle

**Pourquoi une clé.** Le calque affiche ce que le chat demande ; l'adresse du
classeur, elle, est à l'antenne. Tant que les écritures étaient ouvertes à la
clé anonyme, n'importe qui la connaissant pouvait afficher une carte sous le
pseudo de son choix, sans passer par le chat ni par sa modération. Les portes
`bot_request_*` exigent désormais cette clé (migration `conformite`).

**Ce que fait la commande.** Elle tire un jeton aléatoire de 256 bits, en range
**l'empreinte** SHA-256 en base (`collection_overlay_keys`, que ni `anon` ni
`authenticated` ne lisent), et **le jeton** dans le coffre du poste qui diffuse
(`twitch.env`, ligne `DECKHAND_OVERLAY_KEY`). Le jeton n'est jamais affiché :
il ne sert qu'au bot, qui le lit dans le coffre.

**Relancer, c'est renouveler.** L'ancienne clé cesse aussitôt de fonctionner —
c'est le geste à faire si le coffre a pu fuiter.

La collection est celle de `DECKHAND_HANDLE`. La connexion est celle de
l'ingestion (`SUPABASE_DB_URL`, propriétaire) : c'est la seule qui puisse écrire
une empreinte, et c'est voulu.
"""

from __future__ import annotations

import logging
import secrets
import sys

import psycopg

from ..config import ConfigError, SupabaseConfig, load_env_file, secrets_dir

NOM_VARIABLE = "DECKHAND_OVERLAY_KEY"


def avec_cle(texte: str, cle: str) -> str:
    """Le contenu de `twitch.env`, la ligne de la clé remplacée ou ajoutée.

    Toutes les autres lignes — commentaires compris — sont rendues telles
    quelles : ce fichier porte aussi le jeton Twitch, qu'une réécriture
    maladroite effacerait.
    """
    lignes = texte.splitlines()
    nouvelle = f"{NOM_VARIABLE}={cle}"
    remplacee = False
    for i, ligne in enumerate(lignes):
        if ligne.strip().startswith(f"{NOM_VARIABLE}="):
            lignes[i] = nouvelle
            remplacee = True
    if not remplacee:
        lignes.append(nouvelle)
    return "\n".join(lignes) + "\n"


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        supabase = SupabaseConfig.load()
    except ConfigError as error:
        logging.error("%s", error)
        return 1
    # Seule l'adresse du classeur compte ici : la clé se pose avant même que
    # les identifiants Twitch du bot ne soient renseignés.
    handle = load_env_file("twitch.env").get("DECKHAND_HANDLE")
    if not handle:
        logging.error("DECKHAND_HANDLE absent de %s", secrets_dir() / "twitch.env")
        return 1

    with psycopg.connect(supabase.db_url, connect_timeout=30) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, is_public FROM public.collections "
                "WHERE slug = lower(trim(%s)) OR id::text = lower(trim(%s))",
                (handle, handle),
            )
            ligne = cur.fetchone()
            if ligne is None:
                logging.error("aucune collection sous l'adresse %s", handle)
                return 1
            collection_id, publiee = ligne
            cle = secrets.token_urlsafe(32)
            cur.execute(
                """
                INSERT INTO public.collection_overlay_keys (collection_id, key_hash)
                VALUES (%s, sha256(convert_to(%s, 'UTF8')))
                ON CONFLICT (collection_id) DO UPDATE
                    SET key_hash = EXCLUDED.key_hash, created_at = NOW()
                """,
                (collection_id, cle),
            )
        # Le coffre d'abord, la base ensuite : si l'écriture du fichier échoue,
        # la transaction est annulée et l'ancienne clé reste valable.
        chemin = secrets_dir() / "twitch.env"
        chemin.write_text(avec_cle(chemin.read_text(encoding="utf-8"), cle), encoding="utf-8")
        conn.commit()

    logging.info("clé du calque posée pour la collection %s, rangée dans %s", collection_id, chemin)
    if not publiee:
        logging.warning("cette collection n'est pas publiée : le calque restera vide")
    return 0


if __name__ == "__main__":
    sys.exit(main())
