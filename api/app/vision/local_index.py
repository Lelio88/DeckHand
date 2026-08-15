"""Index d'empreintes bâti depuis un dossier d'images **local**.

**Pourquoi une seconde voie.** `index_builder` télécharge chaque illustration.
Wankul l'interdit : son CDN rend `403 Hotlinking not allowed` sur toute requête
venue d'ailleurs — mesuré sans `Referer`, avec un `Referer` étranger, et même
avec celui de `wankul.fr`. Ce n'est pas une panne à contourner, c'est une
politique, et le garde-fou §IV.10 du `CLAUDE.md` interdit de la forcer :
l'autorisation nominative de l'éditeur couvre le catalogue, pas les images.

Les images existent pourtant hors ligne. Ce module les lit là où elles sont,
calcule les mêmes empreintes, et écrit les mêmes lignes. **Rien de la chaîne de
calcul n'est réimplémenté** : `box_for`, `crop` et `dhash` sont ceux de
`index_builder`, sans quoi les empreintes locales et téléchargées ne se
compareraient plus — et elles cohabitent dans la même table.

**Le rapprochement fichier ↔ impression se fait par un UUID.** La source nomme
chacun de ses rendus `<uuid>_main.jpg` et publie ce chemin ; l'ingestion en tire
`card_prints.illustration_id`. Le dossier local conserve ce nom. La
correspondance est donc exacte et vérifiable dans les deux sens — mesuré sur
Wankul : 958 fichiers, 958 impressions, aucun orphelin d'un côté ni de l'autre.

**Ce qu'un dossier local a de plus qu'un téléchargement, et qu'il faut traiter :**

- des **calques** qui ne sont pas des illustrations (masques holographiques
  `opw_*`, `diag_mask_*`, `metal_inverted`) — 308 fichiers sur 1 268 chez
  Wankul, écartés par le suffixe ;
- des **marges transparentes** possibles sur les PNG, qui fausseraient les
  proportions de la valeur exacte de la marge ;
- une **orientation de stockage** propre à la source : un Terrain Wankul est
  une carte couchée, mais son rendu principal la montre debout, tournée d'un
  quart de tour. L'empreinte doit porter sur la carte dans son sens de lecture,
  faute de quoi elle ne rencontrera jamais celle d'une photo.

Usage :
    cd api && .venv/Scripts/python -m app.vision.local_index wankul <dossier>
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from uuid import UUID

from PIL import Image, UnidentifiedImageError

from app.config import SupabaseConfig
from app.db import Session
from app.vision.art_box import (
    GAMES_AWAITING_ART_BOX,
    GAMES_WITH_PREDETOURED_ART,
    LAYOUTS_AWAITING_ART_BOX,
    box_for,
    crop,
)
from app.vision.dhash import dhash, to_signed_64
from app.vision.index_builder import pending_prints, write_hashes
from app.vision import wankul_frame

#: Suffixes des rendus de carte. Tout le reste du dossier est ignoré.
#:
#: **Le filtre porte sur le suffixe et non sur l'extension**, parce que les
#: calques d'effet brillant sont des images valides : un `opw_band_mid.png`
#: s'ouvre, se hache, et produirait une entrée d'index parfaitement fausse dont
#: rien ne dirait qu'elle l'est.
MAIN_SUFFIXES = ("_main.jpg", "_main.jpeg", "_main.png")

_UUID = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.I
)

#: Sous ce seuil d'opacité, un pixel est de la marge et non de la carte.
ALPHA_MIN = 16

BATCH_SIZE = 200


@dataclass
class LocalReport:
    hashed: int = 0
    missing_file: int = 0
    unreadable: int = 0
    no_box: int = 0
    #: Cartes dont la maquette a été décidée de justesse — voir `wankul_frame`.
    #: Elles ne sont pas des échecs : elles sont ce qu'il faut regarder d'abord
    #: si une carte se met à ne plus être reconnue.
    close_calls: list[tuple[float, str]] = field(default_factory=list)
    layouts: dict[str, int] = field(default_factory=dict)

    def summary(self) -> str:
        lignes = [
            f"empreintes calculées : {self.hashed}",
            f"impressions sans fichier : {self.missing_file}",
            f"fichiers illisibles : {self.unreadable}",
            f"maquettes sans gabarit mesuré : {self.no_box}",
        ]
        for layout, n in sorted(self.layouts.items()):
            lignes.append(f"  maquette « {layout} » : {n}")
        if self.close_calls:
            lignes.append("maquettes décidées de justesse (rapport des deux scores) :")
            for ratio, nom in self.close_calls[:5]:
                lignes.append(f"  x{ratio:.2f}  {nom}")
        return "\n".join(lignes)


def files_by_illustration(folder: Path) -> dict[UUID, Path]:
    """Les rendus de carte du dossier, indexés par l'UUID de leur nom.

    Un UUID vu deux fois est une anomalie du dossier (deux extensions pour le
    même rendu, un doublon de téléchargement) : le dernier dans l'ordre
    alphabétique gagne, ce qui est arbitraire mais **déterministe** — deux
    courses successives calculeront la même empreinte.
    """
    trouves: dict[UUID, Path] = {}
    for path in sorted(folder.iterdir()):
        if not path.name.lower().endswith(MAIN_SUFFIXES):
            continue
        found = _UUID.findall(path.stem)
        if found:
            trouves[UUID(found[-1])] = path
    return trouves


def load_card(path: Path) -> Image.Image:
    """L'image réduite à la carte elle-même, marges transparentes retirées.

    Les JPEG n'ont pas d'alpha : la carte y occupe toute l'image, et il n'y a
    rien à retirer. Le lot Wankul actuel n'a d'ailleurs aucune marge, PNG
    compris — le rognage est là pour la source qui en aura, pas pour celle-ci,
    et il ne coûte rien quand il ne trouve rien.
    """
    image = Image.open(path)
    if image.mode not in ("RGBA", "LA", "P"):
        return image.convert("RGB")

    image = image.convert("RGBA")
    alpha = image.getchannel("A")
    boite = alpha.point(lambda v: 255 if v > ALPHA_MIN else 0).getbbox()
    if boite is None:
        return image.convert("RGB")
    return image.crop(boite).convert("RGB")


@dataclass(frozen=True)
class Hashed:
    """Une empreinte, et de quoi juger la façon dont elle a été obtenue."""

    value: int
    layout: str | None
    #: Netteté de la décision de maquette, quand il a fallu en prendre une.
    #: `None` lorsque la maquette venait de la source et n'a rien coûté.
    ratio: float | None = None


def refine(
    game: str, layout: str | None, image: Image.Image
) -> tuple[Image.Image, str | None, float | None]:
    """Redresse l'image et précise sa maquette, selon ce que la source stocke.

    **C'est ici que vit tout ce qui est propre à une source**, et nulle part
    ailleurs : `box_for` reçoit ensuite un `layout` qu'il sait traduire, et
    `crop` une image dans le sens de lecture. Un jeu qui n'a rien de particulier
    traverse sans rien subir.

    Wankul : un Terrain est couché mais stocké debout. On le remet à plat, puis
    on lit sur l'image laquelle de ses deux maquettes il porte — la source ne le
    dit pas, et se tromper ne coûte pas un peu de précision : la fenêtre de
    l'autre maquette contient le bloc de texte en entier.
    """
    if game == "wankul" and layout == "horizontal":
        droite = wankul_frame.upright(image)
        verdict = wankul_frame.maquette(droite)
        return droite, verdict.layout, verdict.ratio
    return image, layout, None


def hash_one(path: Path, game: str, layout: str | None) -> Hashed | None:
    """L'empreinte d'un fichier local, et la maquette retenue pour la calculer.

    Rend `None` quand la maquette n'a pas de gabarit mesuré, plutôt que de
    hacher la carte entière. C'est le mode de défaillance que
    `GAMES_WITH_PREDETOURED_ART` existe pour empêcher : l'empreinte resterait
    valide et comparable aux autres, si bien que rien n'annoncerait la panne.
    """
    with load_card(path) as image:
        droite, layout, ratio = refine(game, layout, image)
        if (game, layout) in LAYOUTS_AWAITING_ART_BOX or game in GAMES_AWAITING_ART_BOX:
            return None
        box = box_for(game, layout)
        if box is None and game not in GAMES_WITH_PREDETOURED_ART:
            return None
        return Hashed(dhash(crop(droite, box) if box else droite), layout, ratio)


def build(session: Session, game: str, folder: Path, limit: int | None = None) -> LocalReport:
    todo = session.run(lambda conn: pending_prints(conn, limit, game))
    report = LocalReport()
    if not todo:
        print("  rien à faire — toutes les empreintes sont calculées")
        return report

    fichiers = files_by_illustration(folder)
    print(f"  {len(todo)} illustrations à traiter, {len(fichiers)} rendus dans le dossier")

    rows: list[tuple[str, str, int]] = []
    for scryfall_id, oracle_id, _url, _game, layout, illustration in todo:
        # **C'est `illustration_id` qui désigne le fichier, pas `art_crop_url`.**
        # L'URL d'affichage n'est pas toujours celle du rendu principal : chez
        # Wankul, un Terrain y porte son rendu *paysage*, qui n'est pas dans le
        # dossier. Les 146 Terrains seraient introuvables, et le rapport
        # annoncerait un index complet à 812 sur 958.
        path = fichiers.get(UUID(illustration))
        if path is None:
            report.missing_file += 1
            continue
        try:
            result = hash_one(path, game, layout)
        except (UnidentifiedImageError, OSError):
            report.unreadable += 1
            continue
        if result is None:
            report.no_box += 1
            continue
        rows.append((scryfall_id, oracle_id, to_signed_64(result.value)))
        report.hashed += 1
        nom = result.layout or "—"
        report.layouts[nom] = report.layouts.get(nom, 0) + 1
        if result.ratio is not None:
            report.close_calls.append((result.ratio, path.name))
        if len(rows) >= BATCH_SIZE:
            lot, rows = rows, []
            # Unité de reprise : les fichiers du lot sont déjà lus, l'écriture
            # seule est rejouée si la connexion cède. `ON CONFLICT DO UPDATE`
            # la rend rejouable telle quelle.
            session.run(lambda conn: write_hashes(conn, lot))
    if rows:
        session.run(lambda conn: write_hashes(conn, rows))
    report.close_calls.sort()
    return report


def run(game: str, folder: Path, limit: int | None = None) -> None:
    config = SupabaseConfig.load()
    with Session(config.db_url) as session:
        print(f"construction de l'index d'empreintes « {game} » depuis {folder}")
        report = build(session, game, folder, limit)
        print(report.summary())
        if session.recoveries:
            print(f"coupures de connexion encaissées : {session.recoveries}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage : python -m app.vision.local_index <jeu> <dossier> [limite]")
    run(sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else None)
