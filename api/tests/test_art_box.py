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
    RIFTBOUND_LANDSCAPE,
    RIFTBOUND_PORTRAIT,
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
}

_CADRE = re.compile(
    r"(\w+)\(\(\s*left:\s*([\d.]+),\s*top:\s*([\d.]+),"
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


def test_le_gabarit_pendule_est_plus_large_que_l_ordinaire():
    # Ce que la mesure a montré, et ce qui justifie un second gabarit : les deux
    # échelles latérales repoussent l'illustration vers les bords.
    assert YUGIOH_PENDULUM.left < YUGIOH.left
    assert YUGIOH_PENDULUM.right > YUGIOH.right
