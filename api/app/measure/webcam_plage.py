"""Le `Y` d'une webcam est-il lisible par l'index ? — la plage vidéo (#41).

**Pourquoi ce banc existe.** `camera_frame.dart` lit la luminance d'un capteur
sans la convertir, et le pont webcam (#43) fera de même. Or le `Y` d'un capteur
est souvent en **plage vidéo** (16–235) là où l'index est calculé sur du RGB
**pleine plage** (0–255). Le passage est affine et croissant, donc il préserve
les comparaisons de voisins dont l'empreinte est faite — aux arrondis près. Le
Dart le vérifie en synthèse ; ce banc le vérifie sur une caméra réelle, avant
qu'une ligne du pont soit écrite.

**Deux mesures, et elles s'isolent l'une l'autre.**

- **A — la plage seule.** Sur la *même* capture et le *même* quadrilatère,
  l'empreinte tirée du plan `Y` brut contre celle tirée du RGB que le
  navigateur a converti. Tout est identique sauf la source du gris : l'écart en
  bits est imputable à la plage, et à rien d'autre. Ni index, ni vérité
  terrain ne sont nécessaires.
- **B — bout en bout.** L'empreinte du `Y` contre l'index réel : rang du bon
  candidat, distance, marge au second. C'est le verdict qui compte, mais il
  mêle plage, optique et cadrage — d'où A pour le lire.

**Pourquoi le RGB du navigateur sert de référence.** `drawImage(VideoFrame)`
applique la conversion YUV→RGB avec la plage que la caméra déclare : le PNG
obtenu est du RGB pleine plage, exactement ce sur quoi l'index est calculé.
Comparer `Y` à ce RGB, c'est comparer ce que le pont livrera à ce que l'index
attend.

**Ce que ce banc ne mesure pas.** La qualité de la détection sur un fond de
stream — c'est #33 — ni la latence du pont. `--carte-pleine` permet d'ailleurs
de s'en affranchir : la carte remplit l'image, le quadrilatère est l'image.

**Le contrôle de taille est un garde-fou, pas une formalité.** `copyTo()` rend
un plan dont le `stride` dépasse la largeur ; un PGM écrit sans le retirer a la
bonne en-tête et des lignes décalées. Ses empreintes n'ont plus rien à voir avec
la carte, et rien ne le signalerait. Le JSON dit la taille attendue, le banc
refuse tout PGM qui ne la fait pas.

Usage :

    # 1. ouvrir webcam_capture.html dans Chrome, capturer une trentaine de cartes
    # 2. décrire la vérité : attendu.csv, une ligne « capture-001.pgm;ext;numéro »
    .venv/Scripts/python -m app.measure.webcam_plage \\
        --captures ../../.deckhand-bench/webcam --attendu ../../.deckhand-bench/webcam/attendu.csv

    # A seul, sans base ni vérité — suffit à trancher la plage
    .venv/Scripts/python -m app.measure.webcam_plage --captures ../../.deckhand-bench/webcam
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path

import httpx
import numpy as np
from PIL import Image

from app.measure.art_probe import database_url
from app.measure.plafond_empreinte import BOITES, SEUIL_CONFIANCE
from app.measure.plafond_reel import USER_AGENT, lire_attendu, oracle_de
from app.vision.card_bounds import Quad, find_card, sample_art
from app.vision.dhash import dhash, hamming_distance

# La console Windows sort en cp1252 ; une flèche dans un `print` tuerait le banc
# après son travail. Même remède que les autres bancs.
for flux in (sys.stdout, sys.stderr):
    if hasattr(flux, "reconfigure"):
        flux.reconfigure(encoding="utf-8")

#: Les bornes de la plage vidéo (ITU-R BT.601 / BT.709, *limited range*).
PLAGE_VIDEO = (16, 235)

#: Centiles qui servent à lire la plage : un pixel chaud du capteur ou un
#: reflet ne doivent pas faire croire à la pleine plage.
CENTILES = (0.5, 99.5)

#: Marges de lecture. « Pleine » dès que les centiles franchissent nettement la
#: plage vidéo ; « vidéo » quand ils atteignent ses deux bords sans les
#: franchir. Entre les deux, la scène ne prouve rien.
_FRANCHIT_BAS, _FRANCHIT_HAUT = 12, 240
_ATTEINT_BAS, _ATTEINT_HAUT = 24, 225


# --------------------------------------------------------------------------
# La plage que les pixels montrent
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Plage:
    """Ce qu'un plan de luminance dit de sa propre plage."""

    minimum: int
    maximum: int
    bas: float  # centile 0,5
    haut: float  # centile 99,5
    verdict: str  # "video" | "pleine" | "indeterminee"


def plage_de(luma: np.ndarray) -> Plage:
    """Lit la plage d'un plan `Y`, en ignorant les pixels isolés."""
    bas, haut = np.percentile(luma, CENTILES)
    if bas < _FRANCHIT_BAS or haut > _FRANCHIT_HAUT:
        verdict = "pleine"
    elif bas <= _ATTEINT_BAS and haut >= _ATTEINT_HAUT:
        verdict = "video"
    else:
        verdict = "indeterminee"
    return Plage(int(luma.min()), int(luma.max()), float(bas), float(haut), verdict)


def vers_plage_video(pleine: np.ndarray) -> np.ndarray:
    """Ramène une luminance pleine plage en plage vidéo, en entiers.

    Sert aux tests de synthèse : c'est la transformation dont on veut vérifier
    qu'elle ne bascule aucun bit.
    """
    y = pleine.astype(np.int64)
    return ((y * 219 + 127) // 255 + 16).astype(np.uint8)


# --------------------------------------------------------------------------
# A — l'écart imputable à la plage seule
# --------------------------------------------------------------------------


def _empreintes(photo: Image.Image, quad: Quad) -> dict[str, int]:
    """Une empreinte par gabarit Magic, sur le quadrilatère donné."""
    return {nom: dhash(sample_art(photo, quad, boite)) for nom, boite in BOITES.items()}


def ecart_plage(rgb: Image.Image, luma: np.ndarray, quad: Quad) -> dict[str, int]:
    """Bits qui séparent l'empreinte du `Y` de celle du RGB, gabarit par gabarit.

    L'image de luminance est donnée à `sample_art` en mode `L` : convertie en
    RGB à trois canaux égaux, `dhash` en retire exactement `Y` —
    `(Y·299 + Y·587 + Y·114) ÷ 1000 = Y`. L'empreinte du `Y` est donc calculée
    par le **même** chemin que celle du RGB, seul le point de départ change.
    """
    depuis_rgb = _empreintes(rgb, quad)
    depuis_luma = _empreintes(Image.fromarray(luma, mode="L"), quad)
    return {nom: hamming_distance(depuis_rgb[nom], depuis_luma[nom]) for nom in BOITES}


# --------------------------------------------------------------------------
# B — le classement dans l'index
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Candidat:
    oracle_id: str
    distance: int
    nom: str


@dataclass(frozen=True)
class Rang:
    rang: int
    distance: int
    #: Positif : de combien la bonne carte gagne sur son premier rival.
    #: Négatif : de combien elle perd sur le vainqueur.
    marge: int


def classer(empreinte: int, lignes: list[tuple[str, int, str]]) -> list[Candidat]:
    """Le catalogue trié par distance, une entrée par carte.

    `lignes` vient de `art_hashes` ⋈ `cards` : `(oracle_id, dhash, name)`. Le
    `dhash` est un `bigint` signé — Postgres n'a pas d'entier 64 bits non signé
    — et se replie sur ses 64 bits avant toute comparaison. Plusieurs
    impressions partagent une carte : seule la plus proche est retenue, la
    marge se mesurant entre cartes distinctes.
    """
    meilleur: dict[str, Candidat] = {}
    for oracle_id, signe, nom in lignes:
        distance = hamming_distance(empreinte, signe & 0xFFFFFFFFFFFFFFFF)
        cle = str(oracle_id)
        if cle not in meilleur or distance < meilleur[cle].distance:
            meilleur[cle] = Candidat(cle, distance, nom)
    return sorted(meilleur.values(), key=lambda c: c.distance)


def rang_de(classement: list[Candidat], oracle_id: str) -> Rang | None:
    """Où tombe la carte attendue, et avec quelle marge."""
    for indice, candidat in enumerate(classement):
        if candidat.oracle_id != oracle_id:
            continue
        if indice == 0:
            rival = classement[1].distance if len(classement) > 1 else 64
            return Rang(1, candidat.distance, rival - candidat.distance)
        return Rang(indice + 1, candidat.distance, classement[0].distance - candidat.distance)
    return None


def charger_index(game: str) -> list[tuple[str, int, str]]:
    """Les empreintes du jeu, telles que l'application les sert."""
    import psycopg

    with psycopg.connect(database_url()) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT h.oracle_id, h.dhash, c.name
            FROM art_hashes h
            JOIN cards c ON c.oracle_id = h.oracle_id
            WHERE c.game = %s
            """,
            (game,),
        )
        return [(str(o), int(d), str(n)) for o, d, n in cur.fetchall()]


# --------------------------------------------------------------------------
# Le verdict
# --------------------------------------------------------------------------


def verdict_ecart(ecart_median: float) -> str:
    """La table de #41, mot pour mot."""
    if ecart_median <= 5:
        return "le pont peut s'écrire tel quel"
    if ecart_median <= 12:
        return (
            "une normalisation de plage est nécessaire avant l'empreinte — "
            "à placer sans créer un troisième jumeau"
        )
    return "l'hypothèse tombe : le chantier doit être repensé avant d'aller plus loin"


# --------------------------------------------------------------------------
# Les captures
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Capture:
    nom: str
    luma: np.ndarray
    rgb: Image.Image | None
    meta: dict


def lire_capture(chemin_pgm: Path) -> Capture:
    """Le triplet écrit par `webcam_capture.html` : `.pgm`, `.png`, `.json`."""
    nom = chemin_pgm.stem
    with Image.open(chemin_pgm) as pgm:
        luma = np.asarray(pgm.convert("L"), dtype=np.uint8).copy()

    meta: dict = {}
    chemin_json = chemin_pgm.with_suffix(".json")
    if chemin_json.exists():
        meta = json.loads(chemin_json.read_text(encoding="utf-8"))

    hauteur, largeur = luma.shape
    attendu = (meta.get("width"), meta.get("height"))
    if None not in attendu and attendu != (largeur, hauteur):
        raise ValueError(
            f"{chemin_pgm.name} : le JSON annonce {attendu[0]}×{attendu[1]}, "
            f"le PGM fait {largeur}×{hauteur} — stride oublié à l'écriture ?"
        )

    rgb = None
    chemin_png = chemin_pgm.with_suffix(".png")
    if chemin_png.exists():
        with Image.open(chemin_png) as png:
            rgb = png.convert("RGB")

    return Capture(nom, luma, rgb, meta)


def quad_plein(largeur: int, hauteur: int) -> Quad:
    """La carte remplit l'image : le quadrilatère est l'image."""
    return Quad(
        top_left=(0.0, 0.0),
        top_right=(largeur - 1.0, 0.0),
        bottom_right=(largeur - 1.0, hauteur - 1.0),
        bottom_left=(0.0, hauteur - 1.0),
    )


# --------------------------------------------------------------------------
# Le banc
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Ligne:
    """Une capture dépouillée."""

    nom: str
    plage: Plage
    declare: str  # ce que le navigateur dit de la plage : "video" | "pleine" | "?"
    format: str
    detectee: bool
    ecarts: dict[str, int] | None  # A, par gabarit ; None sans PNG ou sans quad
    rang: Rang | None  # B ; None sans index, sans vérité, ou carte absente
    gabarit: str | None  # le gabarit retenu en B
    carte: str  # le nom attendu, ou "?"


def _declare(meta: dict) -> str:
    full = (meta.get("colorSpace") or {}).get("fullRange")
    if full is True:
        return "pleine"
    if full is False:
        return "video"
    return "?"


def _cle_attendue(attendu: dict, nom: str) -> tuple[str, str, str] | None:
    for cle in (f"{nom}.pgm", f"{nom}.png", nom):
        if cle in attendu:
            return attendu[cle]
    return None


def depouiller(
    capture: Capture,
    *,
    carte_pleine: bool,
    index: list[tuple[str, int, str]] | None,
    verite: tuple[str, str] | None,
    game: str,
) -> Ligne:
    """Toutes les mesures d'une capture."""
    hauteur, largeur = capture.luma.shape
    luma_image = Image.fromarray(capture.luma, mode="L")

    if carte_pleine:
        quad: Quad | None = quad_plein(largeur, hauteur)
    else:
        # La détection de production travaille en couleur ; le PNG est la
        # meilleure entrée quand il existe, le `Y` sinon.
        quad = find_card(capture.rgb if capture.rgb is not None else luma_image, game)

    ecarts = None
    if quad is not None and capture.rgb is not None:
        ecarts = ecart_plage(capture.rgb, capture.luma, quad)

    rang, gabarit = None, None
    if quad is not None and index is not None and verite is not None:
        oracle_id, _ = verite
        empreintes = _empreintes(luma_image, quad)
        # Comme le Dart : chaque gabarit est une hypothèse, la distance tranche.
        meilleur_rang: Rang | None = None
        for nom_gabarit, empreinte in empreintes.items():
            classement = classer(empreinte, index)
            candidat = rang_de(classement, oracle_id)
            if candidat is None:
                continue
            if meilleur_rang is None or candidat.distance < meilleur_rang.distance:
                meilleur_rang, gabarit = candidat, nom_gabarit
        rang = meilleur_rang

    return Ligne(
        nom=capture.nom,
        plage=plage_de(capture.luma),
        declare=_declare(capture.meta),
        format=str(capture.meta.get("format", "?")),
        detectee=quad is not None,
        ecarts=ecarts,
        rang=rang,
        gabarit=gabarit,
        carte=verite[1] if verite else "?",
    )


def _resoudre_verites(
    captures: list[Capture], attendu: dict[str, tuple[str, str, str]]
) -> dict[str, tuple[str, str]]:
    """`oracle_id` et nom de chaque carte attendue, par Scryfall (en cache)."""
    verites: dict[str, tuple[str, str]] = {}
    with httpx.Client(headers={"User-Agent": USER_AGENT}) as client:
        for capture in captures:
            cle = _cle_attendue(attendu, capture.nom)
            if cle is None:
                continue
            extension, numero, _ = cle
            verites[capture.nom] = oracle_de(client, extension, numero)
    return verites


def _ligne_tableau(ligne: Ligne) -> str:
    a = "—"
    if ligne.ecarts is not None:
        a = "/".join(str(ligne.ecarts[g]) for g in BOITES)
    b = "—"
    if ligne.rang is not None:
        b = f"{ligne.rang.rang:>3} {ligne.rang.distance:>3} {ligne.rang.marge:>+3} {ligne.gabarit}"
    plage = f"{ligne.plage.verdict:<13} {ligne.plage.minimum:>3}–{ligne.plage.maximum:<3}"
    return (
        f"{ligne.nom:<16} {ligne.format:<6} {ligne.declare:<7} {plage} "
        f"{'oui' if ligne.detectee else 'NON':<4} {a:<9} {b:<22} {ligne.carte}"
    )


def rapport(lignes: list[Ligne], nb_index: int | None) -> str:
    """Le tableau puis la synthèse, prêts à coller dans l'issue."""
    sortie: list[str] = []
    sortie.append(
        f"{'capture':<16} {'format':<6} {'déclaré':<7} {'plage mesurée':<21} "
        f"{'dét.':<4} {'A m/l/f':<9} {'B rang dist marge gab.':<22} carte"
    )
    sortie.extend(_ligne_tableau(ligne) for ligne in lignes)

    n = len(lignes)
    sortie.append("")
    sortie.append("--- plage ---")
    for verdict in ("video", "pleine", "indeterminee"):
        sortie.append(
            f"mesurée {verdict:<13} {sum(1 for l in lignes if l.plage.verdict == verdict)}/{n}"
        )
    for declare in ("video", "pleine", "?"):
        k = sum(1 for l in lignes if l.declare == declare)
        if k:
            sortie.append(f"déclarée {declare:<12} {k}/{n}")

    sortie.append("")
    sortie.append("--- A : écart imputable à la plage seule (pire gabarit par capture) ---")
    pires = [max(l.ecarts.values()) for l in lignes if l.ecarts is not None]
    if pires:
        mediane = statistics.median(pires)
        sortie.append(
            f"médiane {mediane:g} bit(s), moyenne {statistics.mean(pires):.1f}, "
            f"max {max(pires)}, sur {len(pires)} capture(s)"
        )
        sortie.append(f"→ {verdict_ecart(mediane)}")
    else:
        sortie.append("aucune capture mesurable — il faut un PNG et un quadrilatère")

    sortie.append("")
    if nb_index is None:
        sortie.append("--- B : non mesuré (pas d'index ou pas de vérité) ---")
    else:
        sortie.append(f"--- B : contre l'index ({nb_index} carte(s)) ---")
        rangs = [l.rang for l in lignes if l.rang is not None]
        premieres = [r for r in rangs if r.rang == 1]
        sures = [r for r in premieres if r.distance <= SEUIL_CONFIANCE]
        total = len(rangs)
        sortie.append(f"première et sous le seuil (≤ {SEUIL_CONFIANCE}) : {len(sures)}/{total}")
        sortie.append(f"première mais au-delà du seuil : {len(premieres) - len(sures)}/{total}")
        perdues = [r for r in rangs if r.rang > 1]
        if perdues:
            sortie.append(
                f"pas première : {len(perdues)}/{len(rangs)} "
                f"(rang médian {statistics.median(r.rang for r in perdues):g})"
            )
        else:
            sortie.append(f"pas première : 0/{len(rangs)}")
        if premieres:
            marge = statistics.median(r.marge for r in premieres)
            sortie.append(f"marge médiane quand première : {marge:+g} bits")
    sortie.append(f"détection échouée : {sum(1 for l in lignes if not l.detectee)}/{n}")
    return "\n".join(sortie)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", required=True, type=Path, help="dossier des triplets")
    parser.add_argument("--attendu", type=Path, help="vérité : « fichier;extension;numéro »")
    parser.add_argument("--game", default="magic")
    parser.add_argument(
        "--carte-pleine",
        action="store_true",
        help="la carte remplit l'image : pas de détection, le quadrilatère est l'image",
    )
    args = parser.parse_args()

    chemins = sorted(args.captures.glob("*.pgm"))
    if not chemins:
        raise SystemExit(f"aucun .pgm dans {args.captures}")
    captures: list[Capture] = []
    ecartees = 0
    for chemin in chemins:
        try:
            captures.append(lire_capture(chemin))
        except (ValueError, OSError) as err:
            # Une capture mal écrite est écartée, pas mesurée : ses empreintes
            # n'auraient rien à voir avec la carte. Elle est dite, pas tue.
            print(f"écartée : {err}")
            ecartees += 1
    if not captures:
        raise SystemExit("aucune capture lisible")

    index = verites = None
    if args.attendu:
        attendu = lire_attendu(args.attendu)
        verites = _resoudre_verites(captures, attendu)
        index = charger_index(args.game)

    lignes = [
        depouiller(
            capture,
            carte_pleine=args.carte_pleine,
            index=index,
            verite=(verites or {}).get(capture.nom),
            game=args.game,
        )
        for capture in captures
    ]
    nb_index = len({o for o, _, _ in index}) if index is not None else None
    print(rapport(lignes, nb_index))
    if ecartees:
        print(f"captures écartées : {ecartees} (voir ci-dessus)")


if __name__ == "__main__":
    main()
