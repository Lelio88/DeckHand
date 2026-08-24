"""Tests du banc de plafond d'identification.

**Un banc faux est pire qu'un banc absent** : il produit des chiffres, on les
écrit dans la doc, et on décide sur eux. Celui-ci a menti une fois — il annonçait
51 bits là où la production en trouvait 3 — et ce n'est pas la mesure qui l'a
révélé, c'est une contradiction avec un relevé Dart. Chaque cas ci-dessous
correspond à ce défaut ou à une propriété dont un résultat écrit dépend
directement.

Aucun réseau : les figures ont une réponse connue d'avance.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

from app.measure.magic_art_window import gradient
from app.measure.plafond_empreinte import (
    Rotation,
    Scene,
    _carte_ncc,
    _distance_hex,
    _ecart,
    _score_direct,
    lire_identites,
    pose_de,
    situer_fft,
    tourner,
)
from app.vision.dhash import dhash, hamming_distance, to_hex


# --------------------------------------------------------------------------
# L'empreinte reçue du Dart
# --------------------------------------------------------------------------


def test_distance_hex_traite_l_empreinte_comme_non_signee() -> None:
    """Le défaut qui faisait mentir le banc.

    `dhash` rend un entier **non signé**. La première version repliait la valeur
    reçue du Dart dans l'intervalle d'un `bigint` — donc en négatif dès que le
    bit de poids fort vaut 1 — puis la donnait à `hamming_distance`, dont le
    `int.bit_count()` compte les bits de la **valeur absolue** sans rien
    signaler. Une empreinte sur deux était mesurée de travers, en silence.
    """
    # Bit de poids fort à 1 : exactement le cas qui basculait en négatif.
    empreinte = 0x9B1F9DCD0D3B336B
    assert _distance_hex(to_hex(empreinte), empreinte) == 0

    voisine = empreinte ^ 0b101  # deux bits d'écart
    assert _distance_hex(to_hex(voisine), empreinte) == 2

    # Et l'opposé bit à bit : soixante-quatre, jamais zéro ni un nombre absurde.
    assert _distance_hex(to_hex(empreinte ^ ((1 << 64) - 1)), empreinte) == 64


def test_distance_hex_accepte_la_casse_du_dart() -> None:
    """`ArtHash.toHex()` rend des majuscules ; rien ne l'impose au banc."""
    empreinte = 0x1B1F9DCD0D3B734B
    assert _distance_hex("1B1F9DCD0D3B734B", empreinte) == 0
    assert _distance_hex("1b1f9dcd0d3b734b", empreinte) == 0


# --------------------------------------------------------------------------
# La rotation à affine connue
# --------------------------------------------------------------------------


def _image_marquee() -> tuple[Image.Image, tuple[int, int]]:
    image = Image.new("RGB", (200, 120), (0, 0, 0))
    for x in range(10, 31):
        for y in range(4, 17):
            image.putpixel((x, y), (255, 0, 0))
    return image, (20, 10)


def test_rotation_decrit_ce_que_tourner_a_fait() -> None:
    """L'affine est écrite, pas devinée — et un test le vérifie sur des pixels.

    Sans cela, la fenêtre trouvée serait ramenée dans le repère de la photo par
    une transformation *supposée*, et le banc comparerait deux cadres qui ne
    vivent pas au même endroit — sans que rien ne le signale.
    """
    image, marque = _image_marquee()
    for angle in (0, 90, 180, 270, 37, -23):
        tournee, rot = tourner(image, angle)
        x, y = rot.avant(*marque)
        assert tournee.getpixel((round(x), round(y)))[0] > 200, angle


def test_rotation_est_reversible() -> None:
    image, _ = _image_marquee()
    _, rot = tourner(image, 37)
    for point in ((0.0, 0.0), (199.0, 0.0), (100.0, 60.0), (12.5, 91.25)):
        aller = rot.avant(*point)
        retour = rot.arriere(*aller)
        assert retour[0] == np.float32(np.float32(point[0])) or abs(
            retour[0] - point[0]
        ) < 1e-6
        assert abs(retour[1] - point[1]) < 1e-6


def test_rotation_agrandit_le_cadre_juste_ce_qu_il_faut() -> None:
    """Un quart de tour échange les côtés ; 45° porte la diagonale."""
    image, _ = _image_marquee()
    tournee, _ = tourner(image, 90)
    assert tournee.size == (121, 200)

    oblique, _ = tourner(image, 45)
    diagonale = round((200 + 120) * 0.70710678)
    assert abs(oblique.size[0] - diagonale) <= 2
    assert abs(oblique.size[1] - diagonale) <= 2


# --------------------------------------------------------------------------
# La corrélation par FFT
# --------------------------------------------------------------------------


def _doux(graine: int, largeur: int, hauteur: int) -> np.ndarray:
    """Une figure qui se comporte comme une illustration, non comme du bruit.

    **Le piège que ce banc a déjà rencontré ailleurs.** Une figure de bruit blanc
    — ou un damier fin — ne survit pas au redimensionnement : la corrélation
    compare alors deux tirages sans rapport et le test échoue pour une raison qui
    n'a rien à voir avec le code. Une illustration a des structures à plusieurs
    échelles ; on l'imite en tirant un petit tableau et en l'agrandissant.
    """
    hasard = np.random.default_rng(graine)
    germe = hasard.integers(0, 255, (6, 8, 3), dtype=np.uint8)
    return np.asarray(
        Image.fromarray(germe).resize((largeur, hauteur), Image.BICUBIC)
    )


def _scene_avec_motif() -> tuple[Image.Image, Image.Image, tuple[int, int]]:
    """Un motif non répétitif collé à une position connue d'une scène."""
    fond = _doux(7, 240, 300).copy()
    motif = _doux(23, 80, 60)
    fond[90 : 90 + 60, 70 : 70 + 80] = motif
    return Image.fromarray(fond), Image.fromarray(motif), (70, 90)


def test_la_fft_calcule_le_meme_score_que_le_balayage() -> None:
    """L'exactitude, et non la ressemblance.

    C'est la seule chose qui autorise à remplacer le balayage de `situer` par
    une transformée : si les deux ne calculent pas la même quantité, accélérer
    revient à changer de vérité.
    """
    scene_img, motif, _ = _scene_avec_motif()
    scene = Scene(scene_img, largeur=240)
    ga = gradient(motif.resize((80, 60), Image.LANCZOS))
    grille = _carte_ncc(scene, ga)
    assert grille is not None

    py, px = divmod(int(np.argmax(grille)), grille.shape[1])
    for y, x in ((py, px), (py + 1, px), (py, px + 3), (0, 0)):
        if 0 <= y < grille.shape[0] and 0 <= x < grille.shape[1]:
            assert abs(
                float(grille[y, x]) - _score_direct(scene.gc, ga, y, x)
            ) < 1e-4


_ECHELLES = np.arange(0.20, 0.60, 0.02)


def test_situer_fft_retrouve_un_motif_place_a_la_main() -> None:
    """Ce qui compte est la **position**, pas la valeur de l'accord.

    Un seuil absolu sur l'accord serait un nombre inventé : il dépend de la
    figure, et celle-ci porte une couture au bord du collage qu'aucune photo
    réelle ne porte. La propriété dont le banc dépend est que la corrélation
    désigne le bon endroit.
    """
    scene_img, motif, (x, y) = _scene_avec_motif()
    fenetre, _ = situer_fft(scene_img, motif, largeur=240, parts=_ECHELLES)
    assert abs(fenetre.left - x / scene_img.width) < 0.02
    assert abs(fenetre.top - y / scene_img.height) < 0.02
    assert abs((fenetre.right - fenetre.left) - 80 / scene_img.width) < 0.02


def test_l_accord_separe_le_motif_present_de_l_etranger() -> None:
    """**Se taire compte autant que trouver.**

    Un accord aussi élevé sur une scène qui ne contient pas le motif ferait
    passer une vérité inventée pour établie — c'est exactement ce qui est arrivé
    sur quatre photos du banc réel, où la fenêtre est partie sur un pantalon.
    La comparaison est faite ici entre les deux, sans seuil arbitraire.
    """
    scene_img, motif, _ = _scene_avec_motif()
    _, present = situer_fft(scene_img, motif, largeur=240, parts=_ECHELLES)
    etranger = Image.fromarray(_doux(101, 80, 60))
    _, absent = situer_fft(scene_img, etranger, largeur=240, parts=_ECHELLES)
    assert present > absent + 0.1, (present, absent)


def test_la_coupe_a_la_fenetre_trouvee_rend_la_meme_empreinte() -> None:
    """La chaîne entière : situer, découper, hacher — le témoin du banc."""
    scene_img, motif, _ = _scene_avec_motif()
    fenetre, _ = situer_fft(
        scene_img, motif, largeur=240, parts=np.arange(0.20, 0.60, 0.02)
    )
    w, h = scene_img.size
    coupe = scene_img.crop(
        (
            int(fenetre.left * w),
            int(fenetre.top * h),
            int(fenetre.right * w),
            int(fenetre.bottom * h),
        )
    )
    assert hamming_distance(dhash(coupe), dhash(motif)) <= 4


# --------------------------------------------------------------------------
# L'écart de cadrage
# --------------------------------------------------------------------------


def test_ecart_se_compte_en_part_de_la_largeur_de_la_fenetre() -> None:
    vraie = [(100.0, 100.0), (300.0, 100.0), (300.0, 250.0), (100.0, 250.0)]
    identique = [[100.0, 100.0], [300.0, 100.0], [300.0, 250.0], [100.0, 250.0]]
    assert _ecart(identique, vraie) == 0.0

    # Vingt pixels sur deux cents de largeur : dix pour cent.
    decale = [[x + 20, y] for x, y in vraie]
    assert abs(_ecart(decale, vraie) - 0.10) < 1e-9


def test_ecart_retient_le_pire_coin_et_non_la_moyenne() -> None:
    """**Un seul coin de travers suffit à déplacer la fenêtre.** Moyenner les
    quatre écarts laisserait passer un cadre dont un côté déborde largement."""
    vraie = [(0.0, 0.0), (200.0, 0.0), (200.0, 150.0), (0.0, 150.0)]
    un_coin_faux = [[0.0, 0.0], [200.0, 0.0], [260.0, 150.0], [0.0, 150.0]]
    assert abs(_ecart(un_coin_faux, vraie) - 0.30) < 1e-9


# --------------------------------------------------------------------------
# Le fichier de vérité du banc
# --------------------------------------------------------------------------


def test_lire_identites_distingue_absence_de_carte_et_verite_perdue(tmp_path) -> None:
    """Deux notions à ne pas confondre.

    `-` dit qu'il n'y a pas **une** carte à trouver (décor, étalement) : la photo
    n'entre pas dans la mesure. `perdue` dit qu'il y en a une mais que la
    **corrélation** ne la retrouve pas : la photo est mesurée, puis écartée du
    résumé en le disant. Les fondre reviendrait à masquer une limite du banc.
    """
    fichier = tmp_path / "attendu.csv"
    fichier.write_text(
        "# commentaire\n"
        "\n"
        "decor.jpg;-;-;aucune carte\n"
        "carte.jpg;msh;348;Levée de bouclier — debout\n"
        "dure.jpg;msh;125;Crescendo brûlant — petite;perdue\n",
        encoding="utf-8",
    )
    identites = lire_identites(fichier)

    assert identites["decor.jpg"] is None
    assert identites["carte.jpg"] == ("msh", "348", "Levée de bouclier — debout", False)
    assert identites["dure.jpg"][:2] == ("msh", "125")
    assert identites["dure.jpg"][3] is True


def test_pose_lue_dans_la_note() -> None:
    assert pose_de("Levée de bouclier — debout") == "debout"
    assert pose_de("Levée de bouclier — couchée") == "couchée"
    assert pose_de("Levée de bouclier — à l'envers (180°)") == "à l'envers"
    assert pose_de("Dinosaure — inclinée d'environ 20°") == "inclinée"


def test_rotation_conserve_le_coin_haut_gauche_a_zero_degre() -> None:
    image, _ = _image_marquee()
    tournee, rot = tourner(image, 0)
    assert tournee.size == image.size
    assert rot.avant(0.0, 0.0) == (0.0, 0.0)
