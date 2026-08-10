"""Tests de la détection des bords d'une carte.

Le jumeau Dart `app/lib/src/features/scan/domain/card_bounds.dart` rejoue la
même figure et attend les mêmes valeurs : deux implémentations qui
divergeraient produiraient des empreintes incomparables et feraient échouer le
scan **en silence**.
"""

import numpy as np
import pytest
from PIL import Image

from app.vision.card_bounds import CARD_ASPECT, find_card, sample_art

ART_BOX = (0.080, 0.120, 0.920, 0.550)


def photo(dx: int = 0, dy: int = 0) -> Image.Image:
    """Une carte sombre posée sur une table claire, illustration en haut."""
    canvas = Image.new("RGB", (300, 400), (170, 152, 126))
    card = Image.new("RGB", (126, 176), (18, 16, 20))
    card.paste(Image.new("RGB", (100, 74), (200, 60, 40)), (10, 21))
    canvas.paste(card, (70 + dx, 90 + dy))
    return canvas


def test_les_quatre_coins_epousent_la_carte():
    quad = find_card(photo())
    assert quad is not None
    assert quad.top_left == (70.0, 90.0)
    assert quad.bottom_right == (195.0, 265.0)


def test_le_rapport_reconnu_est_celui_d_une_carte():
    assert find_card(photo()).aspect == pytest.approx(CARD_ASPECT, abs=0.01)


def test_deplacer_la_carte_deplace_les_coins_d_autant():
    # C'est tout l'intérêt : le cadrage n'a plus à être centré.
    quad = find_card(photo(dx=40, dy=-30))
    assert quad.top_left == (110.0, 60.0)


def test_une_photo_sans_carte_ne_rend_rien():
    # Renoncer est un résultat : l'appelant retombe sur le cadrage centré,
    # jamais sur pire.
    assert find_card(Image.new("RGB", (300, 400), (170, 152, 126))) is None


def test_un_fond_parfaitement_uniforme_ne_produit_pas_de_seuil_indefini():
    # Sans garde, la moitié lumineuse d'un fond uni est vide et sa médiane vaut
    # NaN : toute comparaison devenait fausse et le masque restait vide.
    quad = find_card(photo())
    assert quad is not None


def test_la_zone_lue_est_celle_de_l_illustration():
    art = np.asarray(
        sample_art(photo(), find_card(photo()), ART_BOX, size=(16, 12)),
        dtype=float,
    ).reshape(-1, 3)
    # Mêmes valeurs que le jumeau Dart. La zone du gabarit déborde légèrement
    # sur la bordure sombre, d'où un rouge un peu en deçà des 200 de
    # l'illustration.
    assert art.mean(axis=0)[0] == pytest.approx(188.62, abs=1.5)
    assert art.mean(axis=0)[1] == pytest.approx(57.25, abs=1.5)
    assert art.mean(axis=0)[2] == pytest.approx(38.75, abs=1.5)


def test_la_lecture_reste_dans_les_bornes_de_la_photo():
    from app.vision.card_bounds import Quad

    art = sample_art(
        photo(),
        Quad((-50, -50), (400, -50), (400, 500), (-50, 500)),
        (0.0, 0.0, 1.0, 1.0),
        size=(8, 8),
    )
    assert art.size == (8, 8)
