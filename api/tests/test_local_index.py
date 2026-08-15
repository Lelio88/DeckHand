"""L'index bâti depuis un dossier, et la maquette lue sur l'image.

**Aucun de ces tests ne touche le réseau ni la base.** Les cartes sont
fabriquées : une illustration de bruit, et les trois bandeaux dessinés là où la
mesure les a trouvés. C'est ce qui permet de vérifier la chaîne entière —
redressement, classement, découpage — sans dépendre du dossier de 958 fichiers
qui, lui, n'est pas dans le dépôt.
"""

from __future__ import annotations

import numpy as np
import pytest
from PIL import Image

from app.vision.art_box import (
    WANKUL_BANDS_BOTTOM,
    WANKUL_BANDS_TOP,
    WANKUL_LAYOUT_BANDS_BOTTOM,
    WANKUL_LAYOUT_BANDS_TOP,
)
from app.vision.local_index import (
    files_by_illustration,
    hash_one,
    load_card,
    refine,
)
from app.vision.wankul_frame import BANDS_BOTTOM, BANDS_TOP, maquette, upright

UUID_A = "b4372ef1-1c81-4d21-a91e-2c281cf86103"
UUID_B = "2b6f1a67-3898-45dc-829b-77ad8c71920f"


def terrain(bands: tuple[float, float, float, float]) -> Image.Image:
    """Une carte couchée synthétique : du bruit, et trois bandeaux clairs.

    Le bruit est tiré d'une graine fixe : deux appels rendent la même carte, et
    une empreinte calculée dessus est donc reproductible d'un test à l'autre.
    """
    width, height = 880, 630
    rng = np.random.default_rng(20260815)
    pixels = rng.integers(0, 120, size=(height, width, 3), dtype=np.uint8)

    x0, x1 = int(0.0440 * width), int(0.9536 * width)
    for top, bottom in zip(bands, bands[1:]):
        y0, y1 = int(top * height) + 2, int(bottom * height) - 2
        pixels[y0:y1, x0:x1] = 235  # l'aplat clair du bandeau
    for trait in bands:
        y = int(trait * height)
        pixels[y - 1 : y + 2, x0:x1] = 20  # le trait qui le borde
    return Image.fromarray(pixels)


def rangee(card: Image.Image) -> Image.Image:
    """La carte telle que la source la stocke : debout, tournée d'un quart de
    tour dans le sens **anti-horaire** — c'est `upright` qui la remet à plat."""
    return card.rotate(90, expand=True)


# --- le dossier -------------------------------------------------------------


def test_les_calques_holographiques_ne_sont_pas_des_illustrations(tmp_path):
    """**308 fichiers sur 1 268 chez Wankul**, et ce sont des images valides :
    un masque s'ouvre, se hache, et produirait une entrée d'index parfaitement
    fausse dont rien ne dirait qu'elle l'est."""
    for nom in (
        f"12_{UUID_A}_main.jpg",
        f"13_{UUID_B}_main.png",
        f"14_{UUID_A}_opw_band_mid.png",
        f"15_{UUID_B}_metal_inverted.png",
        f"16_{UUID_A}_diag_mask_l3.png",
        "150_Wankil_Logo_x320.png",
    ):
        (tmp_path / nom).write_bytes(b"")

    trouves = files_by_illustration(tmp_path)

    assert set(map(str, trouves)) == {UUID_A, UUID_B}
    assert trouves[__import__("uuid").UUID(UUID_A)].name.endswith("_main.jpg")


def test_un_dossier_sans_rendu_ne_rend_rien(tmp_path):
    (tmp_path / "notes.txt").write_text("rien", encoding="utf-8")
    assert files_by_illustration(tmp_path) == {}


def test_les_marges_transparentes_sont_retirees(tmp_path):
    """Mesurer sans les retirer fausserait les proportions de la valeur exacte
    de la marge — une erreur qui ne se voit qu'en comparant deux jeux."""
    image = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
    image.paste(Image.new("RGBA", (40, 60), (200, 30, 30, 255)), (30, 20))
    chemin = tmp_path / f"1_{UUID_A}_main.png"
    image.save(chemin)

    assert load_card(chemin).size == (40, 60)


# --- la maquette ------------------------------------------------------------


@pytest.mark.parametrize(
    "bands, attendu",
    [
        (BANDS_TOP, WANKUL_LAYOUT_BANDS_TOP),
        (BANDS_BOTTOM, WANKUL_LAYOUT_BANDS_BOTTOM),
    ],
)
def test_la_maquette_se_lit_sur_la_carte_redressee(bands, attendu):
    """La source ne publie rien qui distingue les deux maquettes : ni le champ
    `orientation`, déjà pris en défaut, ni la rareté, ni l'effigie."""
    verdict = maquette(upright(rangee(terrain(bands))))

    assert verdict.layout == attendu
    assert verdict.ratio > 1.28, "le pire cas mesuré sur le catalogue vaut 1,28"


def test_le_redressement_est_inconditionnel():
    """**Ce qui a été corrigé.** Un demi-tour conditionnel avait été ajouté pour
    recoller une image moyenne qui montrait deux jeux de bandeaux ; ces deux
    jeux venaient des deux maquettes, et le demi-tour introduisait le résidu
    qu'il croyait supprimer. Les 146 Terrains sont stockés dans le même sens.
    """
    for bands in (BANDS_TOP, BANDS_BOTTOM):
        droite = upright(rangee(terrain(bands)))
        assert droite.width > droite.height
        # Les bandeaux retombent bien là où la mesure les attend, dans les deux
        # maquettes : c'est ce qu'un demi-tour conditionnel casserait pour l'une.
        gris = np.asarray(droite.convert("L")).astype(float)
        milieu = gris[int(bands[0] * droite.height) + 8 : int(bands[1] * droite.height) - 8]
        assert milieu.mean() > 180


# --- le refus de hacher a l'aveugle -----------------------------------------


def test_une_couchee_est_redressee_et_sa_maquette_precisee():
    image = rangee(terrain(BANDS_BOTTOM))

    droite, layout, ratio = refine("wankul", "horizontal", image)

    assert droite.width > droite.height
    assert layout == WANKUL_LAYOUT_BANDS_BOTTOM
    assert ratio is not None


def test_un_jeu_sans_particularite_traverse_sans_rien_subir():
    image = terrain(BANDS_TOP)
    droite, layout, ratio = refine("magic", None, image)

    assert droite is image and layout is None and ratio is None


def test_une_maquette_sans_gabarit_mesure_n_est_pas_hachee(tmp_path, monkeypatch):
    """**Le mode de défaillance que ce refus existe pour empêcher.** Hacher la
    carte entière rendrait une empreinte valide, comparable aux autres, et rien
    n'annoncerait la panne — l'index se bâtirait sur des cartes prises pour des
    illustrations."""
    import app.vision.local_index as module

    monkeypatch.setattr(
        module, "LAYOUTS_AWAITING_ART_BOX", frozenset({("wankul", WANKUL_LAYOUT_BANDS_TOP)})
    )
    chemin = tmp_path / f"1_{UUID_A}_main.png"
    rangee(terrain(BANDS_TOP)).save(chemin)

    assert hash_one(chemin, "wankul", "horizontal") is None


def test_se_tromper_de_maquette_fait_hacher_le_pave_de_texte(tmp_path):
    """**Ce que coûte une erreur de classement**, et pourquoi le rapport signale
    les décisions serrées : la mauvaise fenêtre ne perd pas un peu de précision,
    elle avale le bloc de texte en entier — `[0,1700 ; 0,4150]` tient tout entier
    dans la fenêtre de l'autre maquette."""
    haut = tmp_path / f"1_{UUID_A}_main.png"
    bas = tmp_path / f"2_{UUID_B}_main.png"
    rangee(terrain(BANDS_TOP)).save(haut)
    rangee(terrain(BANDS_BOTTOM)).save(bas)

    a = hash_one(haut, "wankul", "horizontal")
    b = hash_one(bas, "wankul", "horizontal")

    assert a.layout == WANKUL_LAYOUT_BANDS_TOP
    assert b.layout == WANKUL_LAYOUT_BANDS_BOTTOM
    assert a.value != b.value

    assert WANKUL_BANDS_BOTTOM.top < BANDS_TOP[0] and BANDS_TOP[-1] < WANKUL_BANDS_BOTTOM.bottom
    assert WANKUL_BANDS_TOP.top < BANDS_BOTTOM[0] and BANDS_BOTTOM[-1] < WANKUL_BANDS_TOP.bottom
