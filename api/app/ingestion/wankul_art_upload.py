"""Versement des rendus Wankul dans le dépôt d'images.

**Ce module lit le disque et n'appelle jamais la source.** Les illustrations ne
sont pas téléchargeables (§IV.10) ; elles sont fournies hors ligne, exactement
comme pour la construction de l'index (`app.vision.local_index`). Ce que ce
module ajoute, c'est de les rendre atteignables **par le téléphone**, qui ne
peut pas lire le disque de la machine d'ingestion.

**Les Terrains sont versés couchés, dans leur sens de lecture.** Leur rendu
principal les montre debout, tournées d'un quart de tour — c'est la vignette du
Wankuldex. Verser cette vignette telle quelle remplirait mieux une case de
classeur, mais rendrait le texte illisible en plein écran, qui est justement la
vue où il compte. Redressées, elles se comportent comme un champ de bataille
Riftbound : `BoxFit.cover` les recadre au centre dans la case, en plein écran
elles se lisent.

**Reprenable, et sans rien redemander.** Les objets déjà présents sont lus dans
`storage.objects` en une requête, puis sautés. Une coupure ne coûte que le lot
en cours ; relancer reprend où l'on s'est arrêté.

Ordre des opérations : l'ingestion écrit les URL (déterministes, dérivées de
`illustration_id`), ce module remplit le bucket. L'inverse marche aussi — une
URL sans objet rend 404, ce qu'un classeur affiche comme une case vide, soit
exactement l'état d'avant.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.wankul_art_upload <dossier>
    #   --force   reverse même les objets déjà présents
"""

from __future__ import annotations

import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import psycopg
from PIL import Image, UnidentifiedImageError

from app.card_art import BUCKET, FULL, SMALL, encode, object_path
from app.config import SupabaseConfig
from app.vision.local_index import files_by_illustration, load_card
from app.vision.wankul_frame import upright

GAME = "wankul"

#: Notre propre infrastructure : aucun débit de politesse à respecter. Huit
#: connexions saturent la liaison montante d'un poste ordinaire bien avant de
#: gêner Supabase, et 1 916 objets se versent en quelques minutes.
WORKERS = 8


@dataclass
class UploadReport:
    sent: int = 0
    skipped: int = 0
    missing_file: int = 0
    failed: list[tuple[str, str]] = field(default_factory=list)

    def summary(self) -> str:
        lignes = [
            f"objets versés : {self.sent}",
            f"déjà présents, sautés : {self.skipped}",
            f"impressions sans fichier : {self.missing_file}",
            f"échecs : {len(self.failed)}",
        ]
        for chemin, raison in self.failed[:5]:
            lignes.append(f"  {chemin} — {raison}")
        return "\n".join(lignes)


def pending(conn: psycopg.Connection) -> list[tuple[str, str]]:
    """Les impressions à verser : (illustration_id, layout)."""
    with conn.cursor() as cur:
        return cur.execute(
            """
            SELECT DISTINCT p.illustration_id::text, c.layout
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = %s AND p.illustration_id IS NOT NULL
            ORDER BY 1
            """,
            (GAME,),
        ).fetchall()


def already_there(conn: psycopg.Connection) -> set[str]:
    """Les chemins déjà dans le bucket, en une requête.

    Interroger la base plutôt que le service de stockage évite 1 916 requêtes
    HTTP dont la seule réponse utile serait « oui ».
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            "SELECT name FROM storage.objects WHERE bucket_id = %s", (BUCKET,)
        ).fetchall()
    return {name for (name,) in rows}


def reading_orientation(image: Image.Image, layout: str | None) -> Image.Image:
    """L'image telle qu'on veut la voir — couchée pour un Terrain."""
    return upright(image) if layout == "horizontal" else image


def put(client: httpx.Client, base_url: str, key: str, path: str, payload: bytes) -> str | None:
    """Verse un objet. Rend `None` en cas de succès, la raison sinon.

    `x-upsert` est vrai : rejouer un versement doit remplacer, pas échouer.
    C'est ce qui rend `--force` utile le jour où la qualité d'encodage change.
    """
    response = client.post(
        f"{base_url.rstrip('/')}/storage/v1/object/{BUCKET}/{path}",
        content=payload,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "image/jpeg",
            "x-upsert": "true",
        },
    )
    if response.status_code in (200, 201):
        return None
    return f"HTTP {response.status_code} {response.text[:120]}"


def run(folder: Path, force: bool = False) -> int:
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        todo = pending(conn)
        presents = set() if force else already_there(conn)

    fichiers = files_by_illustration(folder)
    report = UploadReport()
    lock = threading.Lock()
    total = len(todo) * 2
    print(f"  {len(todo)} rendus, {total} objets à envisager "
          f"({len(presents)} déjà dans le bucket)")

    def work(item: tuple[str, str | None]) -> None:
        illustration, layout = item
        chemins = [(tier, object_path(GAME, tier, illustration)) for tier in (FULL, SMALL)]
        restants = [(t, c) for t, c in chemins if c not in presents]
        if not restants:
            with lock:
                report.skipped += len(chemins)
            return

        path = fichiers.get(uuid.UUID(illustration))
        if path is None:
            with lock:
                report.missing_file += 1
            return

        try:
            with load_card(path) as image:
                lisible = reading_orientation(image, layout)
                charges = [(c, encode(lisible, t)) for t, c in restants]
        except (UnidentifiedImageError, OSError) as erreur:
            with lock:
                report.failed.append((illustration, str(erreur)[:80]))
            return

        with httpx.Client(timeout=60) as client:
            for chemin, payload in charges:
                raison = put(client, config.url, config.service_key, chemin, payload)
                with lock:
                    if raison is None:
                        report.sent += 1
                    else:
                        report.failed.append((chemin, raison))
        with lock:
            report.skipped += len(chemins) - len(restants)
            fait = report.sent + report.skipped + len(report.failed)
            if fait % 100 < 2:
                print(f"  {fait}/{total}", end="\r", flush=True)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(work, todo))

    print(f"  {report.sent + report.skipped + len(report.failed)}/{total}      ")
    print(report.summary())
    return 1 if report.failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage : python -m app.ingestion.wankul_art_upload <dossier> [--force]")
    raise SystemExit(run(Path(sys.argv[1]), "--force" in sys.argv))
