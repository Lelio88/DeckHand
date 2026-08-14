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
from app.db import Session
from app.vision.art_box import box_for, crop
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
) -> list[tuple[str, str, str, str, str | None]]:
    """Une impression par **illustration** encore dépourvue d'empreinte.

    L'index portait une seule image par carte, si bien qu'une réédition à
    l'illustration changée restait invisible au scan — un quart des cas mesurés
    sur un échantillon de rééditions. Il couvre désormais chaque œuvre distincte.

    `illustration_id` évite l'explosion : commun à toutes les impressions qui
    réutilisent la même image, il ramène les 162 000 impressions au nombre
    d'illustrations réellement différentes. `DISTINCT ON` en retient une seule
    par œuvre, en privilégiant l'anglais puis la sortie la plus ancienne — un
    critère stable, là où le prix désignerait une impression différente à chaque
    fluctuation et ferait recalculer des empreintes déjà connues.

    Les impressions sans `illustration_id` (rares) sont écartées : sans lui, rien
    ne permet de savoir si leur image a déjà été hachée.

    **Les énergies de base Pokémon sont écartées, chiffres à l'appui.** Sur les
    175 dont la source publie une image, 170 (97,1 %) ont une *autre* énergie
    sous le seuil de confiance, 26 portent une empreinte déjà prise par une
    voisine, et la paire la plus serrée est à **0 bit**. Les accueillir ferait
    annoncer à tort et avec assurance 21 d'entre elles (12,0 %), ce qui casserait
    le résultat que tout le pipeline protège. Une énergie de base ne se scanne
    pas, elle se saisit. Ce qu'elles coûtent aux autres est en revanche modeste :
    aucune carte ordinaire n'en a une sous le seuil, six seulement en ont une
    assez proche pour leur manger leur marge.
    """
    query = """
        SELECT DISTINCT ON (p.illustration_id)
               p.scryfall_id::text, p.oracle_id::text, p.art_crop_url,
               c.game, c.layout
        FROM public.card_prints p
        JOIN public.cards c ON c.oracle_id = p.oracle_id
        WHERE p.art_crop_url IS NOT NULL
          AND p.illustration_id IS NOT NULL
          AND c.layout IS DISTINCT FROM 'energy'
          AND NOT EXISTS (
              SELECT 1
              FROM public.art_hashes h
              JOIN public.card_prints hp ON hp.scryfall_id = h.scryfall_id
              WHERE hp.illustration_id = p.illustration_id
          )
        ORDER BY p.illustration_id, (p.lang = 'en') DESC, p.released_at, p.scryfall_id
    """
    if limit:
        query += f" LIMIT {int(limit)}"
    with conn.cursor() as cur:
        return cur.execute(query).fetchall()


def image_url(url: str, game: str) -> str:
    """URL réellement téléchargeable, la source ne les servant pas toutes prêtes.

    **TCGdex publie une URL de base et refuse de la servir nue** : `.../base4/1`
    rend 404, il faut `.../base4/1/high.png`. L'ingestion stocke la base à dessein
    — figer une qualité en base obligerait à réécrire le catalogue pour en changer
    — donc la composition appartient à l'usage, et c'est ici.

    **`high.png` plutôt que `high.webp`**, alors que le WebP est 4,3 fois plus
    léger à résolution égale (600 × 825 dans les deux cas). Mesuré : sa
    compression avec perte déplace l'empreinte de 0 à 2 bits. C'est peu, mais
    l'index est la *référence* — le bruit de la photo viendra s'ajouter par-dessus,
    et les paires les plus serrées ne sont qu'à 14 bits. Le WebP ne ferait rien
    gagner sur la durée totale, celle-ci étant dictée par la pause de politesse et
    non par le poids des images.

    Scryfall, lui, sert des URL complètes : rien à composer.
    """
    if game != "pokemon":
        return url
    return f"{url}/high.png"


def hash_one(
    client: httpx.Client, url: str, game: str = "magic", layout: str | None = None
) -> int | None:
    """Télécharge une illustration et renvoie son empreinte, ou None en cas d'échec.

    Un échec isolé est renvoyé plutôt que levé : sur des dizaines de milliers
    d'images, une poignée d'erreurs réseau ne doit pas interrompre la
    construction.

    **Le découpage dépend du jeu.** Scryfall sert la zone illustrée seule ;
    Riftcodex sert la carte entière, qu'il faut recadrer exactement comme le
    fera l'application sur une photo, sans quoi les empreintes ne se
    rencontreront jamais.
    """
    try:
        response = client.get(image_url(url, game))
        response.raise_for_status()
        with Image.open(io.BytesIO(response.content)) as image:
            box = box_for(game, layout)
            # Aucune conversion ici : `dhash` fait déjà `convert("RGB")`, et la
            # conversion commute avec le découpage — vérifié sur les PNG en
            # palette de TCGdex, empreintes identiques au bit près dans les deux
            # ordres. En ajouter une changerait le chemin des trois index déjà
            # calculés pour ne rien gagner.
            return dhash(crop(image, box) if box else image)
    except (httpx.HTTPError, UnidentifiedImageError, OSError):
        return None
    finally:
        time.sleep(DELAY_PER_WORKER)


def build(session: Session, limit: int | None = None) -> BuildReport:
    todo = session.run(lambda conn: pending_prints(conn, limit))
    report = BuildReport()
    total = len(todo)
    if total == 0:
        print("  rien à faire — toutes les empreintes sont calculées")
        return report

    print(f"  {total} illustrations à traiter")

    lock = threading.Lock()
    rows: list[tuple[str, str, int]] = []

    def work(item: tuple[str, str, str, str, str | None]) -> None:
        scryfall_id, oracle_id, url, game, layout = item
        with httpx.Client(
            timeout=30, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            value = hash_one(client, url, game, layout)
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
            # Unité de reprise : les téléchargements du lot sont déjà payés et
            # restent dehors, l'écriture seule est rejouée si la connexion cède.
            # Rejouable telle quelle — l'INSERT est en ON CONFLICT DO UPDATE — et
            # elle commite, donc une coupure ne coûte au pire que ce lot.
            session.run(lambda conn: _write(conn, statement, pending))

    print(f"  {report.hashed + report.failed}/{total}      ")
    return report


def _write(
    conn: psycopg.Connection, statement: str, rows: list[tuple[str, str, int]]
) -> None:
    """Écrit un lot d'empreintes et commite. Unité de reprise de `build`."""
    with conn.cursor() as cur:
        cur.executemany(statement, rows)
    conn.commit()


def propagate_shared_art(conn: psycopg.Connection) -> int:
    """Attribue une empreinte connue à toute carte qui partage l'illustration.

    **Le calcul déduplique, l'attribution ne doit pas.** `pending_prints` ne
    hache qu'une impression par illustration, pour ne pas retélécharger une
    image déjà traitée. Mais deux cartes *différentes* peuvent partager une
    illustration : la seconde restait alors sans empreinte, donc invisible au
    scan. Mesuré sur Riftbound : 17 cartes dans ce cas.

    Leur donner la même empreinte est la bonne sémantique, pas un pis-aller :
    ces cartes sont visuellement identiques, le scan doit donc les proposer
    toutes et laisser l'utilisateur trancher — garde-fou §IV.8. Inventer une
    distinction que l'image ne porte pas serait pire.

    Aucune image n'est retéléchargée : on recopie une empreinte déjà calculée.
    """
    statement = """
        INSERT INTO public.art_hashes (scryfall_id, oracle_id, dhash)
        SELECT DISTINCT ON (p.oracle_id, p.illustration_id)
               p.scryfall_id, p.oracle_id, h.dhash
        FROM public.card_prints p
        JOIN public.card_prints hp ON hp.illustration_id = p.illustration_id
        JOIN public.art_hashes h ON h.scryfall_id = hp.scryfall_id
        WHERE p.illustration_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.art_hashes h2
              JOIN public.card_prints p2 ON p2.scryfall_id = h2.scryfall_id
              WHERE p2.oracle_id = p.oracle_id
                AND p2.illustration_id = p.illustration_id
          )
        ORDER BY p.oracle_id, p.illustration_id, p.scryfall_id
        ON CONFLICT (scryfall_id) DO NOTHING
    """
    with conn.cursor() as cur:
        cur.execute(statement)
        written = cur.rowcount
    conn.commit()
    return written


def run(limit: int | None = None) -> None:
    config = SupabaseConfig.load()
    # `Session` plutôt qu'une connexion nue : cette course dure des heures, et
    # une connexion tenue ouverte aussi longtemps sera coupée — Supabase a fermé
    # les siennes le 14 août à 00 h 10, le poste a perdu son DNS à 00 h 49. Le
    # module était déjà reprenable en le relançant à la main ; il n'a plus besoin
    # qu'on le relance.
    with Session(config.db_url) as session:
        print("construction de l'index d'empreintes")
        report = build(session, limit)
        print(report.summary())
        shared = session.run(propagate_shared_art)
        print(f"empreintes partagées propagées : {shared}")
        if session.recoveries:
            print(f"coupures de connexion encaissées : {session.recoveries}")


if __name__ == "__main__":
    arg = int(sys.argv[1]) if len(sys.argv) > 1 else None
    try:
        run(arg)
    except KeyboardInterrupt:
        sys.exit("interrompu — relancer reprendra où l'on s'est arrêté")
