"""Applique une migration SQL à la base distante.

Le CLI Supabase n'est pas utilisé ici : il exige un lien de projet et une
authentification interactive, là où l'ingestion tourne déjà avec la chaîne de
connexion du coffre. Le fichier est joué tel quel, transaction comprise.

Usage : .venv/Scripts/python apply_migration.py ../supabase/migrations/<fichier>.sql
"""

import sys

import psycopg

from app.config import SupabaseConfig


def main() -> int:
    if len(sys.argv) < 2:
        print("usage : python apply_migration.py <fichier.sql>", file=sys.stderr)
        return 64

    path = sys.argv[1]
    sql = open(path, encoding="utf-8").read()

    config = SupabaseConfig.load()
    # autocommit : le fichier porte lui-même son BEGIN/COMMIT, comme le veut la
    # convention des migrations du projet.
    with psycopg.connect(config.db_url, connect_timeout=30, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(sql)

    print(f"appliquée : {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
