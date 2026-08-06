"""Construction de l'index d'empreintes à partir des illustrations Scryfall.

Télécharge chaque illustration, calcule son empreinte, **jette l'image**. Seuls
64 bits par carte sont conservés.

**Ménagement de Scryfall.** Le catalogue représente plusieurs gigaoctets
d'images pour un service gratuit qui demande explicitement de rester sous
10 requêtes par seconde. Le débit est donc bridé, les échecs ne sont pas
réessayés en boucle, et l'opération est conçue pour être **reprenable** : seules
les impressions sans empreinte sont traitées, si bien qu'une interruption ne
coûte que le travail déjà fait.

Le téléchargement est concurrent mais borné : quelques connexions parallèles
suffisent à saturer la limite de débit sans la dépasser.
"""

from __future__ import annotations

import io
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import httpx
import psycopg
from PIL import Image, UnidentifiedImageError

from app.config import SupabaseConfig
from app.vision.dhash import dhash, to_signed_64

USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

# Scryfall demande de rester sous 10 requêtes/seconde. Avec 6 ouvriers et une
# pause de 100 ms chacun, le débit plafonne autour de 6 req/s — une marge
# volontaire, l'opération n'ayant pas à être rapide.
WORKERS = 6
DELAY_PER_WORKER = 0.1

BATCH_SIZE = 200


@dataclass
class BuildReport:
    hashed: int = 0
    failed: int = 0
    skipped_no_art: int = 0

    def summary(self) -> str:
        return (
            f"empreintes calculées : {self.hashed}\n"
            f"échecs de téléchargement : {self.failed}\n"
            f"impressions sans illustration : {self.skipped_no_art}"
        )


def pending_prints(
    conn: psycopg.Connection, limit: int | None = None
) -> list[tuple[str, str, str]]:
    """Une impression de référence par carte encore dépourvue d'empreinte.

    **Le filtre porte sur la carte, pas sur l'impression**, et c'est ce qui rend
    l'ingestion des éditions sans conséquence ici. Depuis que `card_prints` contient
    les 161 000 impressions anglaises et françaises au lieu d'une par carte, demander
    « les impressions sans empreinte » réclamerait 130 000 téléchargements d'images
    supplémentaires, et quintuplerait l'index que l'application télécharge — pour
    aucun gain : une carte rééditée garde le plus souvent son illustration.

    L'ordre de départage privilégie l'anglais puis la sortie la plus ancienne, et non
    le prix : un critère fondé sur la cote désignerait une impression différente au
    gré des fluctuations, et ferait recalculer des empreintes déjà connues.

    (Indexer *toutes* les illustrations reconnaîtrait aussi les rééditions à l'art
    changé — piste réelle, mais qui se paie en poids d'index côté application ; elle
    n'est pas prise ici.)
    """
    query = """
        SELECT DISTINCT ON (p.oracle_id)
               p.scryfall_id::text, p.oracle_id::text, p.art_crop_url
        FROM public.card_prints p
        WHERE p.art_crop_url IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.art_hashes h WHERE h.oracle_id = p.oracle_id
          )
        ORDER BY p.oracle_id, (p.lang = 'en') DESC, p.released_at, p.scryfall_id
    """
    if limit:
        query += f" LIMIT {int(limit)}"
    with conn.cursor() as cur:
        return cur.execute(query).fetchall()


def hash_one(
    client: httpx.Client, url: str
) -> int | None:
    """Télécharge une illustration et renvoie son empreinte, ou None en cas d'échec.

    Un échec isolé est renvoyé plutôt que levé : sur des dizaines de milliers
    d'images, une poignée d'erreurs réseau ne doit pas interrompre la
    construction.
    """
    try:
        response = client.get(url)
        response.raise_for_status()
        with Image.open(io.BytesIO(response.content)) as image:
            return dhash(image)
    except (httpx.HTTPError, UnidentifiedImageError, OSError):
        return None
    finally:
        time.sleep(DELAY_PER_WORKER)


def build(conn: psycopg.Connection, limit: int | None = None) -> BuildReport:
    todo = pending_prints(conn, limit)
    report = BuildReport()
    total = len(todo)
    if total == 0:
        print("  rien à faire — toutes les empreintes sont calculées")
        return report

    print(f"  {total} illustrations à traiter")

    lock = threading.Lock()
    rows: list[tuple[str, str, int]] = []

    def work(item: tuple[str, str, str]) -> None:
        scryfall_id, oracle_id, url = item
        with httpx.Client(
            timeout=30, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            value = hash_one(client, url)
        with lock:
            if value is None:
                report.failed += 1
            else:
                rows.append((scryfall_id, oracle_id, to_signed_64(value)))
                report.hashed += 1
            done = report.hashed + report.failed
            if done % 50 == 0:
                print(f"  {done}/{total}", end="\r", flush=True)

    statement = """
        INSERT INTO public.art_hashes (scryfall_id, oracle_id, dhash)
        VALUES (%s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE
            SET dhash = EXCLUDED.dhash, computed_at = NOW()
    """

    for start in range(0, total, BATCH_SIZE):
        chunk = todo[start : start + BATCH_SIZE]
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            list(pool.map(work, chunk))

        with lock:
            pending, rows = rows, []
        if pending:
            with conn.cursor() as cur:
                cur.executemany(statement, pending)
            conn.commit()

    print(f"  {report.hashed + report.failed}/{total}      ")
    return report


def run(limit: int | None = None) -> None:
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        print("construction de l'index d'empreintes")
        report = build(conn, limit)
        print(report.summary())


if __name__ == "__main__":
    arg = int(sys.argv[1]) if len(sys.argv) > 1 else None
    try:
        run(arg)
    except KeyboardInterrupt:
        sys.exit("interrompu — relancer reprendra où l'on s'est arrêté")
