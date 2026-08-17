"""Parité des gabarits d'illustration entre le Python et le Dart.

**Le module `art_box.py` annonce ce test depuis longtemps** — « `test_art_box.py`
verrouille cette parité en relisant les valeurs du fichier Dart » — sans qu'aucun
fichier ne le porte. Le voici, et le mécanisme est celui de
`test_card_geometry.py` : on **relit le Dart** plutôt que d'y recopier des
valeurs, un test qui les recopierait divergeant en même temps que le module qu'il
surveille.

Ce qui est en jeu : l'index est calculé ici, la reconnaissance s'exécute là-bas.
Deux gabarits qui différeraient de quelques millièmes produiraient des empreintes
incomparables, et le scan échouerait **en silence** — le pire mode de
défaillance, puisqu'il fait accuser l'algorithme.

**Magic n'a volontairement pas de gabarit côté Python.** Scryfall publie la seule
zone illustrée : l'index hache l'image telle qu'elle arrive, et la redécouper
l'amputerait. Les deux cadres Magic du Dart n'ont donc pas de pendant, et c'est
la seule asymétrie admise.
"""

from __future__ import annotations

import re
from pathlib import Path

from app.vision.art_box import (
    GAMES_AWAITING_ART_BOX,
    GAMES_WITH_LANDSCAPE,
    GAMES_WITH_PREDETOURED_ART,
    LAYOUTS_AWAITING_ART_BOX,
    POKEMON,
    POKEMON_FULL,
    POKEMON_TRAINER,
    RIFTBOUND_LANDSCAPE,
    RIFTBOUND_PORTRAIT,
    SWU_BASE,
    SWU_EVENT,
    SWU_LEADER,
    SWU_UNIT,
    SWU_UPGRADE,
    WANKUL,
    WANKUL_BANDS_BOTTOM,
    WANKUL_BANDS_TOP,
    WANKUL_LAYOUT_BANDS_BOTTOM,
    WANKUL_LAYOUT_BANDS_TOP,
    YUGIOH,
    YUGIOH_PENDULUM,
    ArtBox,
    box_for,
)

DART = (
    Path(__file__).resolve().parents[2]
    / "app" / "lib" / "src" / "features" / "scan" / "domain" / "art_box.dart"
)

#: Jeux dont l'index découpe lui-même, donc dont les gabarits doivent coïncider.
DECOUPES = {
    "riftbound": {RIFTBOUND_PORTRAIT, RIFTBOUND_LANDSCAPE},
    "yugioh": {YUGIOH, YUGIOH_PENDULUM},
    "pokemon": {POKEMON, POKEMON_TRAINER, POKEMON_FULL},
    # Wankul manquait à cette table tant que sa maquette couchée n'était pas
    # mesurée : le cadre debout existait des deux côtés sans que rien ne vérifie
    # qu'ils coïncidaient.
    "wankul": {WANKUL, WANKUL_BANDS_TOP, WANKUL_BANDS_BOTTOM},
    # SWU en a cinq, un par type — et non un par couple (type, traitement),
    # que le catalogue distingue pourtant vingt-et-une fois. `--compare` a
    # montré que la fenêtre du traitement ordinaire les sert tous.
    "swu": {SWU_UNIT, SWU_UPGRADE, SWU_EVENT, SWU_LEADER, SWU_BASE},
}

#: Le motif tolère les espaces et les sauts de ligne partout où `dart format`
#: peut en insérer — en particulier **entre le nom du cadre et sa parenthèse
#: d'enregistrement**. Il les exigeait collés, et la déclaration s'écrivait bien
#: ainsi jusqu'au jour où un cadre a gagné un argument nommé : le formateur a
#: alors passé chaque argument à la ligne, `riftboundWide` a cessé d'être lu, et
#: la parité n'était plus vérifiée que sur les cadres restants. Le test a bien
#: signalé la disparition — mais une regex qui dépend de la mise en page
#: surveille autant le formateur que les valeurs.
_CADRE = re.compile(
    r"(\w+)\(\s*\(\s*left:\s*([\d.]+),\s*top:\s*([\d.]+),"
    r"\s*right:\s*([\d.]+),\s*bottom:\s*([\d.]+),?\s*\)\s*,\s*'(\w+)'",
    re.S,
)


def cadres_dart() -> dict[str, set[ArtBox]]:
    """Les gabarits déclarés dans `CardFrame`, groupés par jeu."""
    source = DART.read_text(encoding="utf-8")
    par_jeu: dict[str, set[ArtBox]] = {}
    for _, left, top, right, bottom, game in _CADRE.findall(source):
        par_jeu.setdefault(game, set()).add(
            ArtBox(float(left), float(top), float(right), float(bottom))
        )
    assert par_jeu, "aucun cadre lu dans art_box.dart — la regex a-t-elle vieilli ?"
    return par_jeu


def test_les_jeux_decoupes_ont_les_memes_gabarits_des_deux_cotes():
    dart = cadres_dart()
    for game, boxes in DECOUPES.items():
        assert dart.get(game) == boxes, f"gabarits divergents pour « {game} »"


def test_chaque_jeu_couvert_a_une_decision_explicite():
    """**`None` est ambigu, et ce test lève l'ambiguïté.**

    Il signifie « ne rien découper », ce qui est juste pour Magic — Scryfall sert
    l'illustration seule — et faux pour tout jeu dont la source publie la carte
    entière. Un jeu ajouté sans gabarit y retombait en silence, et son index se
    bâtissait sur des cartes entières prises pour des illustrations : une panne
    qui ne s'annonce pas, les empreintes restant valides et comparables entre
    elles.

    Trois états sont donc admis, et le troisième est déclaré : gabarit mesuré,
    illustration déjà détourée, ou mesure en attente.
    """
    from app.vision.card_geometry import CARD_ASPECTS

    for game in CARD_ASPECTS:
        decide = (
            box_for(game, None) is not None
            or game in GAMES_WITH_PREDETOURED_ART
            or game in GAMES_AWAITING_ART_BOX
        )
        assert decide, (
            f"« {game} » n'a ni gabarit, ni dispense, ni mention d'attente : "
            "son index se bâtirait sur des cartes entières sans que rien ne le dise"
        )


def test_l_attente_n_est_pas_un_fourre_tout():
    """Un jeu déclaré « en attente » ne doit pas l'être en même temps que mesuré :
    sortir de l'attente est un geste, pas un oubli inverse."""
    for game in GAMES_AWAITING_ART_BOX:
        assert box_for(game, None) is None, (
            f"« {game} » a un gabarit mais reste déclaré en attente"
        )
        assert game not in GAMES_WITH_PREDETOURED_ART


def test_wankul_a_ses_trois_maquettes():
    """**Les deux orientations de Wankul ne sont pas deux rotations.** La
    verticale porte une illustration encadrée, l'horizontale la porte en plein
    cadre avec les textes posés dessus. Et la couchée en a deux, distinguées par
    la position de son bloc de texte — que la source ne publie pas et qui se
    mesure sur l'image (`app.vision.wankul_frame`).
    """
    assert box_for("wankul", "vertical") == WANKUL
    assert box_for("wankul", None) == WANKUL
    assert box_for("wankul", WANKUL_LAYOUT_BANDS_TOP) == WANKUL_BANDS_TOP
    assert box_for("wankul", WANKUL_LAYOUT_BANDS_BOTTOM) == WANKUL_BANDS_BOTTOM
    assert not LAYOUTS_AWAITING_ART_BOX


def test_une_couchee_sans_maquette_mesuree_prend_la_majoritaire():
    """Inconfortable — elle serait fausse pour 69 Terrains sur 146 — mais c'est
    le moins mauvais : `None` ferait hacher la carte entière **sans que rien ne
    le signale**. Le constructeur d'index ne s'y fie jamais, il classe chaque
    Terrain avant de découper."""
    assert box_for("wankul", "horizontal") == WANKUL_BANDS_TOP


def test_les_deux_maquettes_couchees_ne_sont_pas_un_demi_tour_l_une_de_l_autre():
    """**Le fait qui oblige à déclarer deux cadres.** La reconnaissance essaie
    déjà les deux quarts de tour d'un cadre couché : si la seconde maquette était
    la première retournée, elle serait couverte sans rien ajouter.

    Elle ne l'est pas. Le bloc de texte occupe 0,1700 → 0,4150 sur l'une et
    0,6300 → 0,8750 sur l'autre, là où un demi-tour le placerait à
    0,5850 → 0,8300 : 0,045 d'écart, mesuré sur 77 et 69 cartes.
    """
    demi_tour_du_haut = 1.0 - WANKUL_BANDS_TOP.top
    assert abs(demi_tour_du_haut - WANKUL_BANDS_BOTTOM.bottom) > 0.04

    # Le bloc a en revanche la même hauteur : c'est le même gabarit de bandeaux,
    # posé ailleurs. C'est ce qui rend les deux mesures crédibles l'une par
    # l'autre.
    haut = WANKUL_BANDS_TOP.top - 0.1700
    bas = 0.8750 - WANKUL_BANDS_BOTTOM.bottom
    assert abs(haut - bas) < 0.001


def test_les_cartes_couchees_ouvrent_la_detection_en_travers():
    """Un Terrain se pose en travers. Sans cette déclaration, `find_card`
    rejetterait son quadrilatère — son rapport s'écarte de 0,68 pour une
    tolérance de 0,30 — et les deux cadres mesurés ne serviraient jamais."""
    assert "wankul" in GAMES_WITH_LANDSCAPE


def test_le_gabarit_wankul_est_a_peu_pres_symetrique():
    """Le garde-fou de la mesure qui l'a produit. Une carte seule avait rendu
    8,9 % de marge à gauche pour 6,4 % à droite ; l'échantillon a ramené l'écart
    sous un point. Une régression au-delà signalerait un cadrage repris sur trop
    peu de pièces."""
    box = box_for("wankul", "vertical")
    gauche, droite = box.left, 1.0 - box.right
    assert abs(gauche - droite) < 0.02, (
        f"marges {gauche:.4f} / {droite:.4f} — mesure faite sur trop peu de cartes ?"
    )


def test_magic_est_la_seule_asymetrie_admise():
    # Si un jour un cadre Magic apparaissait côté Python, c'est que quelqu'un
    # aurait décidé de redécouper l'`art_crop` de Scryfall — ce qui l'amputerait.
    assert box_for("magic", None) is None
    assert "magic" in cadres_dart()


def test_le_gabarit_pendule_est_choisi_par_le_frame_type():
    # `layout` porte le `frameType` de la source. Les six sous-familles Pendulum
    # le contiennent toutes, et elles seules : c'est un contrat de la source, non
    # une heuristique.
    for frame in (
        "effect_pendulum", "normal_pendulum", "fusion_pendulum",
        "xyz_pendulum", "synchro_pendulum", "ritual_pendulum",
    ):
        assert box_for("yugioh", frame) == YUGIOH_PENDULUM
    for frame in ("effect", "spell", "trap", "xyz", "link", None):
        assert box_for("yugioh", frame) == YUGIOH


def test_les_familles_pokemon_sont_choisies_par_le_layout():
    # `layout` porte la sortie de `tcgdex_ingest.art_layout`, qui applique les
    # cinq discriminants mesurés par #28. Ce module ne fait que les traduire.
    assert box_for("pokemon", "trainer") == POKEMON_TRAINER
    assert box_for("pokemon", "full") == POKEMON_FULL
    assert box_for("pokemon", "pokemon") == POKEMON
    # L'énergie spéciale prend la standard : deux bits de marge en moins, contre
    # quatre que sa propre fenêtre coûterait aux Pokémon.
    assert box_for("pokemon", "special-energy") == POKEMON
    # Une famille inconnue retombe sur la fenêtre la plus étroite, jamais sur
    # rien : `None` ferait hacher la carte entière sans que rien ne le signale.
    assert box_for("pokemon", None) == POKEMON
    assert box_for("pokemon", "famille_a_venir") == POKEMON


def test_le_dresseur_commence_plus_bas_que_le_pokemon():
    # Ce que la mesure a montré, et ce qui justifie un second gabarit : quarante
    # pixels d'écart sur l'arête haute, 5 % de la hauteur.
    assert POKEMON_TRAINER.top > POKEMON.top
    assert POKEMON_TRAINER.bottom > POKEMON.bottom
    # Même largeur : c'est la hauteur seule qui distingue les deux familles.
    assert POKEMON_TRAINER.left == POKEMON.left
    assert POKEMON_TRAINER.right == POKEMON.right


def test_la_pleine_page_prend_toute_la_carte():
    # L'illustration *est* la carte : aucune arête n'a été trouvée, dans aucune
    # direction. Découper de 0 à 1 rend l'image entière des deux côtés.
    assert POKEMON_FULL == ArtBox(0.0, 0.0, 1.0, 1.0)


def test_le_gabarit_pendule_est_plus_large_que_l_ordinaire():
    # Ce que la mesure a montré, et ce qui justifie un second gabarit : les deux
    # échelles latérales repoussent l'illustration vers les bords.
    assert YUGIOH_PENDULUM.left < YUGIOH.left
    assert YUGIOH_PENDULUM.right > YUGIOH.right


def test_l_illustration_d_un_event_swu_est_sous_celle_d_une_unite():
    """**Le fait mesuré le plus coûteux de ce jeu.** Un Event porte son
    illustration en bas et son texte en haut — l'inverse d'une Unit. Le banc,
    qui sondait en haut, rendait le pavé de texte comme fenêtre avec 1 px de
    dérive entre deux tirages disjoints et 16,5 bits de séparation contre 31
    ailleurs : une fenêtre reproductible n'est pas une fenêtre juste.

    Les deux fenêtres **se chevauchent** entre 0,521 et 0,627 — elles ne sont
    pas disjointes, et l'affirmer serait dire plus que la mesure. Ce qui est
    vrai et qui suffit : celle de l'Event commence sous le milieu de la carte,
    celle de l'Unit bien au-dessus. Si l'une dérivait vers l'autre, le symptôme
    réapparaîtrait sans qu'aucun chiffre de dérive ne le signale."""
    assert SWU_EVENT.top > 0.5 > SWU_UNIT.top
    assert SWU_EVENT.bottom > SWU_UNIT.bottom
    # L'Event descend presque au bas du carton ; l'Unit s'arrête aux deux tiers.
    assert SWU_EVENT.bottom > 0.9
    assert SWU_UNIT.bottom < 0.7


def test_les_deux_maquettes_couchees_swu_ne_couvrent_pas_la_meme_largeur():
    """Un Leader porte son illustration sur la moitié gauche, une Base sur
    toute la largeur. Sonder le Leader au centre tombait dans son pavé de
    texte — 18,7 bits avec une paire à 8, sous le seuil de confiance."""
    assert SWU_LEADER.right < 0.5
    assert SWU_BASE.right > 0.9


def test_chaque_type_swu_a_son_gabarit():
    """Cinq types, cinq fenêtres, et un type inconnu retombe sur celle de
    l'Unit — la maquette majoritaire, 1 369 cartes sur 2 181. Rendre `None`
    ferait hacher la carte entière sans que rien ne le signale."""
    assert box_for("swu", "Unit") == SWU_UNIT
    assert box_for("swu", "Event") == SWU_EVENT
    assert box_for("swu", "Upgrade") == SWU_UPGRADE
    assert box_for("swu", "Leader") == SWU_LEADER
    assert box_for("swu", "Base") == SWU_BASE
    assert box_for("swu", None) == SWU_UNIT
    assert box_for("swu", "Vaisseau") == SWU_UNIT
