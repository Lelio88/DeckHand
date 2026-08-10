"""Banc de mesure du cadrage : que coûte une photo prise à main levée ?

**Pourquoi ce banc existe.** Le pipeline découpe l'illustration à une position
fixe dans le plus grand rectangle aux proportions d'une carte, centré dans la
photo. Il suppose donc que la carte remplit ce rectangle exactement. Le premier
test terrain a mesuré la tolérance de cette hypothèse — 2 à 3 % — sans que
personne ne sache ce qu'une vraie photo lui inflige. Ce banc le chiffre, et
servira de point de comparaison à toute détection de bords : sans lui, on
saurait qu'on a écrit du code, pas qu'on a amélioré quoi que ce soit.

**Les photos sont synthétiques, et c'est un choix.** Une photo réelle porte sa
vérité terrain dans la tête de celui qui l'a prise ; une photo composée la porte
dans ses paramètres. On sait exactement de combien la carte a été décalée,
tournée, inclinée — donc à quel écart correspond quel échec. Le protocole
reprend celui déjà employé pour l'étalement (`docs/spread-detection.md`).

**Ce que le banc ne mesure pas** : le flou de bougé, la mise au point ratée, les
reflets sur un protège-carte. Ils dégradent l'empreinte elle-même, pas le
cadrage, et le pipeline leur a déjà été confronté — 120 cartes dégradées,
reconnues à 98 % dans le pire régime.

Usage :
    python -m app.measure.framing_bench            # 40 cartes, tous les régimes
    python -m app.measure.framing_bench --cards 12 # échantillon plus petit
"""

from __future__ import annotations

import argparse
import io
import math
import random
from dataclasses import dataclass

import httpx
import numpy as np
import psycopg
from PIL import Image

from app.config import SupabaseConfig
from app.vision.card_bounds import find_card, sample_art
from app.vision.dhash import dhash, from_signed_64, hamming_distance

USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

#: Seuil de confiance du scan, en bits. Au-delà, la carte est « perdue » : ce
#: n'est pas une erreur silencieuse, l'application dit son doute — mais elle ne
#: reconnaît rien.
CONFIDENCE = 12

#: Proportions d'une carte Magic, 63 × 88 mm. Jumeau de `card_framing.dart`.
CARD_ASPECT = 63 / 88

#: Gabarit du cadre moderne, jumeau de `art_box.dart`. Le cadre ancien existe
#: aussi ; le banc s'en tient au moderne, qui couvre les cartes tirées ici.
ART_BOX = (0.080, 0.120, 0.920, 0.550)


@dataclass(frozen=True)
class Shot:
    """Un régime de prise de vue, décrit par ce que la main fait de travers."""

    name: str
    #: Marge de table autour de la carte, en fraction de sa hauteur.
    margin: float
    #: Décalage du centre, en fraction de la largeur de la carte.
    offset: float
    #: Rotation, en degrés.
    rotation: float

    def label(self) -> str:
        return (
            f"{self.name:22} marge {self.margin:4.0%}  "
            f"décalage {self.offset:4.0%}  rotation {self.rotation:4.1f}°"
        )


#: Du cadrage parfait — que personne n'atteint — au cadrage négligent.
#: Les valeurs intermédiaires encadrent ce qu'une main produit réellement :
#: quelques pour cent de marge, un ou deux degrés de travers.
REGIMES: tuple[Shot, ...] = (
    Shot("parfait", 0.00, 0.00, 0.0),
    Shot("soigné", 0.03, 0.01, 0.5),
    Shot("ordinaire", 0.08, 0.03, 2.0),
    Shot("à la volée", 0.15, 0.06, 5.0),
    Shot("négligent", 0.25, 0.10, 9.0),
)


def sample_prints(limit: int, salt: str = "cadrage") -> list[tuple[str, str, int]]:
    """Impressions tirées au hasard, avec leur empreinte de référence.

    Seules celles qui portent une empreinte comptent : c'est elle qui fait
    office de vérité terrain, puisque c'est elle que l'application cherchera.

    **Le tirage est reproductible, et c'est vital.** Un `ORDER BY random()`
    donnerait un échantillon différent à chaque exécution : deux mesures ne
    seraient plus comparables, et l'écart entre deux versions du code se
    confondrait avec l'écart entre deux paquets de cartes. Le hachage de
    l'identifiant fixe l'ordre une fois pour toutes.
    """
    config = SupabaseConfig.load()
    query = """
        SELECT p.scryfall_id::text, p.art_crop_url, a.dhash
        FROM public.card_prints p
        JOIN public.art_hashes a ON a.scryfall_id = p.scryfall_id
        JOIN public.cards c ON c.oracle_id = p.oracle_id
        WHERE c.game = 'magic'
          AND c.layout = 'normal'
          AND p.lang = 'en'
          AND p.released_at >= '2004-01-01'
        ORDER BY md5(p.scryfall_id::text || %s)
        LIMIT %s
    """
    with psycopg.connect(config.db_url, connect_timeout=30) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (salt, limit))
            return [(sid, url, from_signed_64(h)) for sid, url, h in cur.fetchall()]


def fetch_card_image(art_crop_url: str, client: httpx.Client) -> Image.Image | None:
    """Carte entière, obtenue en substituant la taille dans l'URL.

    Scryfall sert la même image sous plusieurs tailles au même chemin ; passer
    d'`art_crop` à `normal` évite un appel à l'API pour retrouver l'URL.
    """
    url = art_crop_url.replace("/art_crop/", "/normal/")
    try:
        response = client.get(url, timeout=30)
        response.raise_for_status()
        return Image.open(io.BytesIO(response.content)).convert("RGB")
    except (httpx.HTTPError, OSError):
        return None


def table_background(width: int, height: int, rng: random.Random) -> Image.Image:
    """Fond de table texturé.

    Un aplat uni rendrait la détection triviale et le banc menteur : c'est la
    texture qui met les approches en difficulté, comme l'ont montré les mesures
    d'étalement.
    """
    base = np.full((height, width, 3), (168, 150, 124), dtype=np.int16)
    grain = np.array(
        rng.choices(range(-14, 15), k=height * width), dtype=np.int16
    ).reshape(height, width, 1)
    # Un dégradé diagonal imite un éclairage inégal, l'autre écueil connu.
    gradient = np.linspace(-18, 18, width, dtype=np.int16).reshape(1, width, 1)
    canvas = np.clip(base + grain + gradient, 0, 255).astype(np.uint8)
    return Image.fromarray(canvas, mode="RGB")


def compose(card: Image.Image, shot: Shot, rng: random.Random) -> Image.Image:
    """Photo synthétique : la carte posée sur une table, vue de travers."""
    card_height = 900
    card_width = round(card_height * CARD_ASPECT)
    card = card.resize((card_width, card_height), Image.LANCZOS)

    margin = round(card_height * shot.margin)
    photo_width = card_width + 2 * margin
    photo_height = card_height + 2 * margin
    photo = table_background(photo_width, photo_height, rng)

    if shot.rotation:
        # **En RGBA, sans quoi le banc mesure un artefact.** `rotate` remplit
        # les coins libérés par la rotation avec la couleur de fond — noire sur
        # une image RGB. Ce losange noir ceignant la carte est exactement ce
        # qu'un masque de carte cherche, et la détection trouvait alors les
        # coins du losange au lieu de ceux de la carte.
        card = card.convert("RGBA").rotate(
            shot.rotation, resample=Image.BICUBIC, expand=True
        )

    dx = round(card_width * shot.offset)
    dy = round(card_height * shot.offset * CARD_ASPECT)
    x = (photo_width - card.width) // 2 + dx
    y = (photo_height - card.height) // 2 + dy
    photo.paste(card, (x, y), card if card.mode == "RGBA" else None)

    # La compression est celle d'un téléphone, pas celle d'un scanner.
    buffer = io.BytesIO()
    photo.save(buffer, format="JPEG", quality=78)
    return Image.open(buffer).convert("RGB")


def crop_to_card_frame(photo: Image.Image) -> Image.Image:
    """Jumeau de `cropToCardFrame` : plus grand rectangle 63:88, centré."""
    width, height = photo.size
    crop_width = width
    crop_height = round(width / CARD_ASPECT)
    if crop_height > height:
        crop_height = height
        crop_width = round(height * CARD_ASPECT)
    left = (width - crop_width) // 2
    top = (height - crop_height) // 2
    return photo.crop((left, top, left + crop_width, top + crop_height))


def crop_art(card: Image.Image) -> Image.Image:
    """Zone d'illustration, aux proportions du gabarit moderne."""
    width, height = card.size
    left, top, right, bottom = ART_BOX
    return card.crop(
        (
            round(left * width),
            round(top * height),
            round(right * width),
            round(bottom * height),
        )
    )


def measure(
    cards: int, seed: int = 20260810, detect: bool = False
) -> tuple[dict[str, list[int]], int]:
    """Distance de l'empreinte à sa référence, par régime de prise de vue.

    Avec [detect], la zone d'illustration est lue dans le quadrilatère détecté
    plutôt que dans le rectangle centré. Rend aussi le nombre de photos où la
    détection a renoncé — celles-là retombent sur le cadrage centré, comme le
    fera l'application.
    """
    rng = random.Random(seed)
    prints = sample_prints(cards)
    distances: dict[str, list[int]] = {shot.name: [] for shot in REGIMES}
    gave_up = 0

    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        for index, (_, art_url, expected) in enumerate(prints, start=1):
            card = fetch_card_image(art_url, client)
            if card is None:
                continue
            for shot in REGIMES:
                photo = compose(card, shot, rng)
                quad = find_card(photo) if detect else None
                if quad is None:
                    if detect:
                        gave_up += 1
                    art = crop_art(crop_to_card_frame(photo))
                else:
                    art = sample_art(photo, quad, ART_BOX)
                distances[shot.name].append(hamming_distance(dhash(art), expected))
            print(f"  {index}/{len(prints)}", end="\r", flush=True)

    print(" " * 20, end="\r")
    return distances, gave_up


def report(distances: dict[str, list[int]], gave_up: int = 0) -> None:
    print(f"\nSeuil de confiance : {CONFIDENCE} bits")
    if gave_up:
        print(f"détections abandonnées (repli sur le cadrage centré) : {gave_up}")
    print()
    print(f"{'régime':24} {'médiane':>8} {'reconnues':>11} {'perdues':>9}")
    for shot in REGIMES:
        values = sorted(distances[shot.name])
        if not values:
            continue
        median = values[len(values) // 2]
        found = sum(1 for v in values if v <= CONFIDENCE)
        print(
            f"{shot.name:24} {median:8} "
            f"{found:>6}/{len(values):<4} {len(values) - found:>9}"
        )
    print()
    for shot in REGIMES:
        print("  " + shot.label())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cards", type=int, default=40)
    parser.add_argument(
        "--detect",
        action="store_true",
        help="lire l'illustration dans le quadrilatère détecté",
    )
    args = parser.parse_args()

    mode = "détection des bords" if args.detect else "cadrage centré"
    print(f"Banc de cadrage — {args.cards} cartes × {len(REGIMES)} régimes — {mode}")
    distances, gave_up = measure(args.cards, detect=args.detect)
    report(distances, gave_up)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
