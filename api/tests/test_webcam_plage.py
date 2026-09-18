"""Tests du banc de plage vidéo (#41).

Ce banc décide si le chantier webcam peut commencer ; un chiffre faux ici
coûterait le pont entier. Chaque cas vérifie une propriété dont le verdict
dépend directement. Aucun réseau, aucune base : les figures ont une réponse
connue d'avance.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

from app.measure.webcam_plage import (
    PLAGE_VIDEO,
    Capture,
    classer,
    ecart_plage,
    lire_capture,
    plage_de,
    rang_de,
    verdict_ecart,
    vers_plage_video,
)
from app.vision.card_bounds import Quad


# --------------------------------------------------------------------------
# La plage que les pixels montrent
# --------------------------------------------------------------------------


def test_plage_video_reconnue_quand_rien_ne_sort_de_16_235() -> None:
    """Un `Y` qui touche 16 et 235 sans les dépasser est en plage vidéo."""
    luma = np.linspace(16, 235, 10_000).astype(np.uint8).reshape(100, 100)
    plage = plage_de(luma)
    assert plage.verdict == "video"
    assert (plage.minimum, plage.maximum) == PLAGE_VIDEO


def test_pleine_plage_reconnue_quand_les_pixels_touchent_0_et_255() -> None:
    luma = np.linspace(0, 255, 10_000).astype(np.uint8).reshape(100, 100)
    assert plage_de(luma).verdict == "pleine"


def test_scene_sans_noir_ni_blanc_ne_conclut_pas() -> None:
    """Une scène terne ne prouve rien : ni la plage vidéo, ni la pleine.

    Conclure « plage vidéo » parce que rien ne dépasse 235 serait une erreur
    : un tapis gris sous une lampe douce ne dépasse pas 200 non plus.
    """
    luma = np.linspace(40, 200, 10_000).astype(np.uint8).reshape(100, 100)
    assert plage_de(luma).verdict == "indeterminee"


def test_un_pixel_isole_ne_fait_pas_la_plage() -> None:
    """Un point chaud du capteur ne doit pas faire croire à la pleine plage."""
    luma = np.full((100, 100), 128, dtype=np.uint8)
    luma[0, 0] = 255
    luma[99, 99] = 0
    plage = plage_de(luma)
    # Les bornes brutes voient le pixel, les centiles ne le voient pas.
    assert (plage.minimum, plage.maximum) == (0, 255)
    assert plage.verdict == "indeterminee"


# --------------------------------------------------------------------------
# L'écart imputable à la plage seule
# --------------------------------------------------------------------------


def _degrade_rgb(largeur: int = 320, hauteur: int = 224) -> Image.Image:
    """Une carte de synthèse au contenu strictement monotone.

    Un dégradé à deux axes garantit que deux cellules voisines de l'empreinte
    ne sont jamais à égalité : la seule cause possible d'un bit basculé serait
    alors l'arrondi de la conversion, ce qu'on veut précisément mesurer.
    """
    x = np.linspace(0, 255, largeur, dtype=np.float64)[None, :]
    y = np.linspace(0, 255, hauteur, dtype=np.float64)[:, None]
    r = (0.7 * x + 0.3 * y).astype(np.uint8)
    g = (0.5 * x + 0.5 * y).astype(np.uint8)
    b = (0.2 * x + 0.8 * y).astype(np.uint8)
    return Image.fromarray(np.dstack([r, g, b]), mode="RGB")


def _luma_bt601(rgb: Image.Image) -> np.ndarray:
    """La luminance en arithmétique entière — la formule de `dhash`."""
    a = np.asarray(rgb, dtype=np.int64)
    return ((a[:, :, 0] * 299 + a[:, :, 1] * 587 + a[:, :, 2] * 114) // 1000).astype(
        np.uint8
    )


def test_vers_plage_video_est_affine_croissante_et_bornee() -> None:
    """0 → 16, 255 → 235, et l'ordre est préservé partout entre les deux."""
    pleine = np.arange(256, dtype=np.uint8)
    video = vers_plage_video(pleine)
    assert video[0] == 16
    assert video[255] == 235
    assert np.all(np.diff(video.astype(int)) >= 0)


def test_ecart_plage_est_nul_sur_un_contenu_monotone() -> None:
    """La plage vidéo est affine et croissante : elle préserve les comparaisons.

    C'est l'argument de `camera_frame.dart`, ici vérifié par le banc lui-même
    : sur un dégradé sans égalité, ramener le `Y` en 16–235 ne doit basculer
    aucun bit. Si ce test échouait, le banc mesurerait sa propre erreur.
    """
    rgb = _degrade_rgb()
    luma_video = vers_plage_video(_luma_bt601(rgb))
    quad = Quad(
        top_left=(0.0, 0.0),
        top_right=(rgb.width - 1.0, 0.0),
        bottom_right=(rgb.width - 1.0, rgb.height - 1.0),
        bottom_left=(0.0, rgb.height - 1.0),
    )
    ecarts = ecart_plage(rgb, luma_video, quad)
    assert set(ecarts) == {"modern", "legacy", "fullArt"}
    assert all(bits == 0 for bits in ecarts.values()), ecarts


def test_ecart_plage_voit_une_luminance_qui_ne_correspond_pas() -> None:
    """Le témoin : un `Y` sans rapport avec le RGB doit donner un écart franc.

    Sans ce cas, un banc qui rendrait toujours zéro passerait le test
    précédent.
    """
    rgb = _degrade_rgb()
    rng = np.random.default_rng(7)
    bruit = rng.integers(0, 256, size=(rgb.height, rgb.width), dtype=np.uint8)
    quad = Quad(
        top_left=(0.0, 0.0),
        top_right=(rgb.width - 1.0, 0.0),
        bottom_right=(rgb.width - 1.0, rgb.height - 1.0),
        bottom_left=(0.0, rgb.height - 1.0),
    )
    ecarts = ecart_plage(rgb, bruit, quad)
    assert all(bits > 10 for bits in ecarts.values()), ecarts


# --------------------------------------------------------------------------
# Le classement dans l'index
# --------------------------------------------------------------------------


def _index_factice() -> list[tuple[str, int, str]]:
    base = 0x9B1F9DCD0D3B336B
    return [
        ("oracle-a", base, "Carte A"),
        ("oracle-b", base ^ 0b111, "Carte B"),  # 3 bits
        ("oracle-c", base ^ 0xFFFF, "Carte C"),  # 16 bits
        ("oracle-b", base ^ 0b1, "Carte B"),  # une seconde impression, à 1 bit
    ]


def test_classer_garde_une_entree_par_carte_a_sa_meilleure_distance() -> None:
    """Deux impressions d'une même carte ne font pas deux lignes.

    C'est la règle d'`art_probe`, reprise : la marge se mesure entre cartes
    distinctes, pas entre deux tirages de la même.
    """
    empreinte = 0x9B1F9DCD0D3B336B
    classement = classer(empreinte, _index_factice())
    assert [c.oracle_id for c in classement] == ["oracle-a", "oracle-b", "oracle-c"]
    assert [c.distance for c in classement] == [0, 1, 16]


def test_classer_traite_le_bigint_signe_comme_non_signe() -> None:
    """Le piège de Postgres, déjà rencontré : un `bigint` négatif est une
    empreinte dont le bit de poids fort vaut 1, pas une valeur absurde."""
    empreinte = 0x9B1F9DCD0D3B336B
    signe = empreinte - 2**64  # ce que Postgres rend
    classement = classer(empreinte, [("oracle-a", signe, "Carte A")])
    assert classement[0].distance == 0


def test_rang_de_rend_rang_distance_et_marge() -> None:
    empreinte = 0x9B1F9DCD0D3B336B
    classement = classer(empreinte, _index_factice())
    juste = rang_de(classement, "oracle-a")
    assert juste is not None
    assert (juste.rang, juste.distance) == (1, 0)
    # La marge est l'écart au premier rival, ici « Carte B » à 1 bit.
    assert juste.marge == 1

    second = rang_de(classement, "oracle-b")
    assert second is not None
    assert second.rang == 2
    # Quand la bonne carte n'est pas première, la marge est négative : de
    # combien elle perd.
    assert second.marge == -1

    assert rang_de(classement, "inconnue") is None


# --------------------------------------------------------------------------
# Le verdict, tel que #41 l'écrit
# --------------------------------------------------------------------------


def test_verdict_suit_la_table_de_l_issue() -> None:
    assert verdict_ecart(0).startswith("le pont peut")
    assert verdict_ecart(5).startswith("le pont peut")
    assert "normalisation" in verdict_ecart(6)
    assert "normalisation" in verdict_ecart(12)
    assert "repens" in verdict_ecart(13)


# --------------------------------------------------------------------------
# La lecture d'une capture
# --------------------------------------------------------------------------


def _ecrire_capture(
    dossier: Path, nom: str, luma: np.ndarray, rgb: Image.Image, meta: dict
) -> None:
    hauteur, largeur = luma.shape
    entete = f"P5\n{largeur} {hauteur}\n255\n".encode("ascii")
    (dossier / f"{nom}.pgm").write_bytes(entete + luma.tobytes())
    rgb.save(dossier / f"{nom}.png")
    (dossier / f"{nom}.json").write_text(json.dumps(meta), encoding="utf-8")


def test_lire_capture_rend_le_triplet(tmp_path: Path) -> None:
    rgb = _degrade_rgb(64, 48)
    luma = _luma_bt601(rgb)
    meta = {"format": "NV12", "width": 64, "height": 48, "colorSpace": {"fullRange": False}}
    _ecrire_capture(tmp_path, "capture-001", luma, rgb, meta)

    capture = lire_capture(tmp_path / "capture-001.pgm")
    assert isinstance(capture, Capture)
    assert capture.nom == "capture-001"
    assert capture.luma.shape == (48, 64)
    assert capture.luma.dtype == np.uint8
    assert np.array_equal(capture.luma, luma)
    assert capture.rgb.size == (64, 48)
    assert capture.meta["format"] == "NV12"


def test_lire_capture_refuse_un_pgm_qui_ne_fait_pas_la_taille_annoncee(tmp_path: Path) -> None:
    """Le JSON dit ce que la caméra a livré ; un PGM d'une autre taille est un
    PGM mal écrit — un `stride` oublié, typiquement — et le mesurer donnerait
    des empreintes sans rapport avec la carte."""
    rgb = _degrade_rgb(64, 48)
    luma = _luma_bt601(rgb)
    meta = {"format": "NV12", "width": 80, "height": 48}
    _ecrire_capture(tmp_path, "capture-002", luma, rgb, meta)

    try:
        lire_capture(tmp_path / "capture-002.pgm")
    except ValueError as err:
        assert "80" in str(err) and "64" in str(err)
    else:
        raise AssertionError("un PGM de la mauvaise taille doit être refusé")


def test_lire_capture_sans_png_ne_rend_pas_de_rgb(tmp_path: Path) -> None:
    """Le PNG est facultatif : sans lui, la mesure A est impossible mais la
    mesure B reste faisable."""
    rgb = _degrade_rgb(64, 48)
    luma = _luma_bt601(rgb)
    _ecrire_capture(tmp_path, "capture-003", luma, rgb, {"format": "I420"})
    (tmp_path / "capture-003.png").unlink()

    capture = lire_capture(tmp_path / "capture-003.pgm")
    assert capture.rgb is None
