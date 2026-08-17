"""Tests du banc de mesure One Piece.

**Un banc faux est pire qu'un banc absent** : il produit des chiffres, on les
écrit dans la doc, et on décide sur eux. Ceux-ci portent sur la seule mécanique
qui a dû être corrigée deux fois — le retrait des suffixes de variante —, parce
qu'elle décide de l'identité des cartes.
"""

from __future__ import annotations

from typing import Any

from app.measure.onepiece_taxonomy import Entry, parse


def entree(**kwargs: Any) -> Entry:
    defaults: dict[str, Any] = dict(
        origin="OP-01",
        code="OP01-077",
        image_id="OP01-077",
        name="Perona",
        type="Character",
        color="Blue",
        cost="1",
        rarity="UC",
        text="",
        image="https://optcgapi.com/media/static/Card_Images/OP01-077.jpg",
    )
    defaults.update(kwargs)
    return Entry(**defaults)


# --- les suffixes de variante, qui s'empilent -------------------------------


def test_un_suffixe_parenthese_est_retire():
    """« Perona (Box Topper) » et « Perona » sont la même carte sous deux
    tirages — 0,94 $ et 45,24 $. C'est le motif de Riftbound, dont les 243
    variantes suffixées créaient deux lignes de collection pour un exemplaire."""
    assert entree(name="Perona (Box Topper)").base_name == "Perona"


def test_les_suffixes_s_empilent_et_se_retirent_tous():
    """**N'en retirer qu'un fait conclure à tort.** Une première version
    s'arrêtait au dernier, et le banc annonçait « 316 codes réunissent deux
    cartes différentes » — alors que « Donquixote Doflamingo (073) », « … (073)
    (Parallel) » et « … (SP) » sont la même carte sous trois tirages."""
    for nom in (
        "Donquixote Doflamingo (073)",
        "Donquixote Doflamingo (073) (Parallel)",
        "Donquixote Doflamingo (OP01-073)",
        "Donquixote Doflamingo (SP)",
    ):
        assert entree(name=nom).base_name == "Donquixote Doflamingo"


def test_le_code_accole_par_un_tiret_est_retire_lui_aussi():
    """Second motif, trouvé après le premier : « Buggy - OP03-008 (Pirate
    Foil) ». Le banc est passé de 316 codes divergents à 79, puis à 4."""
    assert entree(name="Buggy - OP03-008 (Pirate Foil)").base_name == "Buggy"
    assert entree(name="Sanji - OP06-119 (Reprint)").base_name == "Sanji"


def test_un_tiret_dans_le_nom_n_est_pas_un_suffixe():
    """**Ce sont les espaces autour du tiret qui protègent les noms**, et ce
    n'est pas cosmétique : « Zoro-Juurou » en porte un. Un motif plus lâche
    l'amputerait, et deux cartes deviendraient une."""
    assert entree(name="Zoro-Juurou").base_name == "Zoro-Juurou"
    assert entree(name="Zoro-Juurou (Alternate Art)").base_name == "Zoro-Juurou"


def test_un_nom_sans_suffixe_est_rendu_tel_quel():
    """Une normalisation qui change ce qu'elle ne doit pas changer produit des
    faux couples, que nul écran ne détrompe."""
    for nom in ("Perona", "Eustass\"Captain\"Kid", "Monkey.D.Luffy"):
        assert entree(name=nom).base_name == nom


# --- la marque d'impression -------------------------------------------------


def test_une_variante_se_reconnait_a_son_identifiant_de_rendu():
    """`card_image_id` porte `_p1` là où le nom peut mentir : « Donquixote
    Doflamingo (073) » porte un suffixe qui est le **numéro**, pas une
    variante. Les deux marques ne concordent que sur 3 225 entrées sur 3 992,
    et c'est le rendu qui a raison."""
    assert entree(image_id="OP01-077_p1").is_variant
    assert not entree(image_id="OP01-077").is_variant


# --- la lecture de la source ------------------------------------------------


def test_les_champs_se_lisent_avec_leur_origine():
    """L'origine — extension ou deck de démarrage — n'est pas dans la réponse :
    c'est l'appelant qui sait par quelle porte il est passé, et elle compte,
    286 codes n'étant apportés que par les starters."""
    lu = parse(
        {
            "card_set_id": "ST01-001",
            "card_image_id": "ST01-001",
            "card_name": "Monkey.D.Luffy",
            "card_type": "Leader",
            "card_color": "Red",
            "card_cost": None,
            "rarity": "L",
        },
        origin="ST-01",
    )
    assert lu.origin == "ST-01"
    assert lu.code == "ST01-001"
    assert lu.cost == ""
    assert lu.type == "Leader"


# --- les suffixes d'identifiant de rendu ------------------------------------


def test_les_deux_familles_de_suffixe_marquent_une_variante():
    """**Deux lettres, pas une**, et la seconde s'est fait oublier. Une
    première version ne lisait que `_p`, et manquait 335 variantes en `_r` : le
    vocabulaire complet va de `p1` à `p8` et de `r1` à `r3`.

    Le symptôme n'était pas une erreur mais un chiffre légèrement trop bon — la
    pile des Personnages contenait une variante, et sa paire la plus serrée
    tombait pile sur le seuil de confiance."""
    assert entree(image_id="OP01-077_p1").is_variant
    assert entree(image_id="OP01-077_p8").is_variant
    assert entree(image_id="ST18-001_r1").is_variant
    assert entree(image_id="OP01-077_r3").is_variant
    assert not entree(image_id="OP01-077").is_variant


def test_le_filigrane_borne_toutes_les_fenetres():
    """Les rendus publiés portent « SAMPLE » en travers de l'illustration, et
    il vient de l'**éditeur** — Bandai marque ainsi sa liste de cartes,
    optcgapi ne fait que la reprendre.

    Mesuré sur les quatre types par la luminance de l'image moyenne : la bande
    claire commence à 0,4224 sur les quatre, à la ligne près. Les Personnages
    et les Événements s'y arrêtaient d'eux-mêmes — un trait constant arrête la
    plage calme — quand les Leaders et les Décors le traversaient, dérivant de
    156 et 130 px entre deux tirages disjoints.

    C'est ce plafond qui rend le scan possible : la zone retenue est de
    l'illustration pure, présente à l'identique sur une photo de carton, qui
    n'est pas marquée."""
    from app.measure.onepiece_art_window import WATERMARK_TOP

    assert 0.42 < WATERMARK_TOP < 0.43
