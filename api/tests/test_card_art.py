"""Le dépôt d'images : la convention d'URL, et ce que les paliers garantissent.

**Ce que ces tests protègent tient en une phrase** : l'application n'a pas été
modifiée pour accueillir ce dépôt. Elle sait déjà passer d'une grande image à sa
vignette légère en échangeant un segment d'URL, parce que Scryfall nomme ses
tailles ainsi. Le dépôt calque cette convention ; si elle se met à diverger, les
vignettes disparaissent sans qu'aucune erreur ne soit levée.
"""

from __future__ import annotations

import io

import pytest
from PIL import Image

from app.card_art import (
    BUCKET,
    FULL,
    SMALL,
    SMALL_MAX_SIDE,
    encode,
    object_path,
    public_url,
)

BASE = "https://abc.supabase.co"
ILLUSTRATION = "b4372ef1-1c81-4d21-a91e-2c281cf86103"


def test_l_url_suit_la_convention_que_l_application_sait_deja_lire():
    """`previewCardImage`, côté Dart, échange `/normal/` contre `/small/`. C'est
    ce qui donne les deux paliers sans une ligne de Dart à écrire."""
    grande = public_url(BASE, "wankul", FULL, ILLUSTRATION)

    assert grande == (
        f"{BASE}/storage/v1/object/public/{BUCKET}/wankul/normal/{ILLUSTRATION}.jpg"
    )
    assert grande.replace("/normal/", "/small/") == public_url(
        BASE, "wankul", SMALL, ILLUSTRATION
    )


def test_l_url_ne_porte_pas_le_segment_que_l_application_substituerait():
    """`fullCardImage` remplace `/art_crop/` par `/normal/`. Un chemin qui
    porterait ce segment serait réécrit au passage et pointerait dans le vide."""
    assert "/art_crop/" not in public_url(BASE, "wankul", FULL, ILLUSTRATION)


def test_une_barre_finale_ne_double_pas_le_separateur():
    assert public_url(BASE + "/", "wankul", FULL, ILLUSTRATION) == public_url(
        BASE, "wankul", FULL, ILLUSTRATION
    )


def test_le_jeu_prefixe_le_chemin():
    """**Ce bucket n'est pas un cache générique.** Chaque jeu qui y entre le fait
    avec son propre accord d'éditeur ; le préfixe est là pour que la question se
    pose à chaque fois."""
    assert object_path("wankul", FULL, ILLUSTRATION).startswith("wankul/")


@pytest.mark.parametrize("taille", [(430, 600), (600, 430)])
def test_le_palier_leger_garde_les_proportions_de_la_grande(taille):
    """**Le défaut que ce test verrouille**, trouvé en regardant ce qui avait été
    versé : une boîte fixe de 146 × 204 écrasait les Terrains, qui sont couchés.
    Leur grande sortait en 600 × 430 et leur vignette en 146 × 204 — deux
    proportions pour la même carte. L'application pose la seconde sur la première
    sans transition, la déformation se serait vue en mouvement.
    """
    source = Image.new("RGB", taille, (120, 60, 30))

    grande = Image.open(io.BytesIO(encode(source, FULL)))
    petite = Image.open(io.BytesIO(encode(source, SMALL)))

    assert grande.size == taille
    assert max(petite.size) == SMALL_MAX_SIDE
    assert abs(grande.width / grande.height - petite.width / petite.height) < 0.01


def test_tout_est_ramene_en_jpeg():
    """Le lot d'origine mêle 773 JPEG et 185 PNG ; un PNG de photo pèse plusieurs
    fois son équivalent JPEG sans rien apporter à l'écran."""
    source = Image.new("RGBA", (430, 600), (10, 200, 90, 255))

    assert Image.open(io.BytesIO(encode(source, FULL))).format == "JPEG"


def test_l_encodage_ne_touche_pas_l_image_qu_on_lui_donne():
    """Le versement encode deux paliers depuis la même image ouverte une fois :
    si le premier la réduisait sur place, le second verserait une vignette à la
    place de la grande."""
    source = Image.new("RGB", (430, 600), (10, 20, 30))

    encode(source, SMALL)

    assert source.size == (430, 600)
