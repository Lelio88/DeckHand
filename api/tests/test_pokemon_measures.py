"""Tests des bancs de mesure Pokémon (#28).

**Un banc faux est pire qu'un banc absent** : il produit des chiffres, on les
écrit dans la doc, et on décide sur eux. Ceux-ci vérifient la mécanique sur des
figures dont la réponse est connue d'avance, sans réseau ni source.

Chaque cas correspond à un défaut réellement rencontré pendant la mesure, ou à
une propriété dont un résultat écrit dépend directement.
"""

from __future__ import annotations

import numpy as np

from app.measure.pokemon_art_window import (
    CARD_HEIGHT,
    CARD_WIDTH,
    QUIET_FACTOR,
    Stack,
    _family,
    _relief,
    derive,
    quiet_run,
    separation,
)
from app.measure.pokemon_taxonomy import Card, _shape


def card(local_id: str = "007", official: int = 100, **kwargs) -> Card:
    defaults = dict(
        id="set-" + local_id,
        local_id=local_id,
        set_id="set",
        serie="sv",
        official=official,
        image_url="https://exemple/set/" + local_id,
    )
    defaults.update(kwargs)
    return Card(**defaults)


# --- la règle du numéro ------------------------------------------------------


def test_un_numero_non_numerique_ne_se_compare_pas_au_decompte():
    """« TG01 » ou « H01 » ne sont pas des nombres. Les forcer en donnerait une
    réponse fausse plutôt qu'une absence de réponse — et 1 602 cartes du
    catalogue sont dans ce cas."""
    assert card("H01").numbered is None
    assert card("SWSH001").numbered is None
    assert card("007").numbered == 7


def test_la_silhouette_d_un_numero_ignore_sa_valeur():
    """C'est la forme qui dit de quoi il s'agit : « 50a » est une variante de la
    carte 50, « H01 » appartient à un sous-ensemble qui a sa propre numérotation."""
    assert _shape("50a") == "9A"
    assert _shape("H01") == "A9"
    assert _shape("XY150a") == "A9A"
    assert _shape("007") == "9"


# --- l'appartenance à une famille -------------------------------------------


def famille(**tables) -> str:
    subject = tables.pop("card", card())
    return _family(
        subject,
        subject.numbered,
        tables.get("suffix", {}),
        tables.get("stage", {}),
        tables.get("energy", {}),
        tables.get("category", {"set-007": "Pokemon"}),
        tables.get("rarity", {}),
        tables.get("split", False),
    )


def test_une_energie_de_base_prime_sur_tout_le_reste():
    """Elle n'a pas d'illustration : aucune autre famille n'a de sens pour elle."""
    assert famille(energy={"set-007": "Normal"}) == "D_energie"


def test_une_energie_speciale_n_est_pas_une_energie_de_base():
    """`category == Energy` engloberait les deux. Mesuré : 196 énergies spéciales
    ont bel et bien une illustration, et les exclure serait une perte sèche."""
    assert famille(
        energy={"set-007": "Special"}, category={"set-007": "Energy"}
    ) == "E_speciale"


def test_le_numero_tranche_avant_la_marque():
    """684 cartes pleine page portent aussi un suffixe. Lire la marque en premier
    les rangerait dans la famille encadrée, où elles n'ont pas leur cadre."""
    hors = card("250", official=100)
    assert _family(hors, 250, {"set-250": "ex"}, {}, {}, {"set-250": "Pokemon"}, {}, False) == "C_pleine"


def test_une_carte_dresseur_a_sa_propre_mise_en_page():
    """Mesuré : sa fenêtre s'arrête 40 px plus bas que celle d'un Pokémon de la
    même série. Les mêler faisait dériver l'arête haute de 32 px entre deux
    tirages, et cette dérive était le seul symptôme."""
    assert famille(category={"set-007": "Trainer"}) == "T_dresseur"


def test_la_marque_vient_de_deux_champs_et_pas_d_un():
    """`ex` et `V` sont des suffixes, `VMAX` et `VSTAR` sont des *stages*. Ne lire
    que `suffix` manquerait 274 cartes."""
    assert famille(suffix={"set-007": "ex"}) == "B_haute"
    assert famille(stage={"set-007": "VMAX"}) == "B_haute"
    assert famille() == "A_pokemon"


# --- la recherche de la fenêtre ----------------------------------------------


def test_la_plage_calme_s_arrete_au_premier_trait():
    profile = np.full(100, 5.0)
    profile[20] = 60.0
    profile[80] = 60.0
    assert quiet_run(profile, 50, 50, background=5.0) == (21, 79)


def test_un_accident_sous_le_seuil_n_arrete_pas_la_plage():
    """Le fond mesuré vaut 5 et le seuil 12,5 : une ligne à 8 est du bruit
    d'illustration, pas un trait de cadre."""
    profile = np.full(100, 5.0)
    profile[30] = QUIET_FACTOR * 5.0 - 0.1
    profile[10] = 60.0
    assert quiet_run(profile, 50, 50, background=5.0)[0] == 11


def test_sans_aucun_trait_la_plage_couvre_toute_la_carte():
    """Réponse légitime : c'est le cas des cartes pleine page, dont
    l'illustration *est* la carte. Le banc ne doit pas inventer d'arête."""
    assert quiet_run(np.full(100, 5.0), 50, 50, background=5.0) == (0, 99)


def test_le_relief_distingue_une_arete_reelle_d_une_arete_absente():
    """C'est la vérification dans l'autre sens : une fenêtre juste est bordée.
    Sans relief, l'arête n'est qu'un bord d'image."""
    borde = np.full(100, 5.0)
    borde[20] = 60.0
    assert _relief(borde, 21, -1) == 12.0
    assert _relief(np.full(100, 5.0), 21, -1) == 1.0


def test_le_relief_lit_du_bon_cote_selon_l_arete():
    """Une inversion de sens ferait passer le trait pour de l'intérieur : le
    relief tombe alors **sous** 1, c'est-à-dire que le dehors paraît plus calme
    que le dedans. Le sens est donc lui-même vérifiable."""
    profile = np.full(100, 5.0)
    profile[80] = 60.0
    assert _relief(profile, 79, +1) == 12.0
    assert _relief(profile, 79, -1) < 1.0


def figure(left: int, top: int, right: int, bottom: int) -> Stack:
    """Une carte de synthèse : un cadre net, une fenêtre au bruit reproductible.

    L'image moyenne porte le cadre — traits constants — et un intérieur
    volontairement plat, comme l'est celui d'une vraie moyenne d'illustrations.
    """
    mean = np.full((CARD_HEIGHT, CARD_WIDTH), 200.0)
    mean[top : bottom + 1, left : right + 1] = 140.0
    # Les traits du cadre : deux pixels, comme sur le carton.
    for y in (top - 1, bottom + 1):
        mean[y, left - 1 : right + 2] = 20.0
    for x in (left - 1, right + 1):
        mean[top - 1 : bottom + 2, x] = 20.0
    return Stack(
        name="figure",
        count=2,
        mean=mean,
        deviation=np.zeros_like(mean),
        planes=[],
        ids=[],
    )


def test_la_fenetre_retrouve_le_cadre_qu_on_lui_a_dessine():
    """À un pixel près, et jamais du mauvais côté.

    Le contrat n'est pas l'égalité exacte mais l'**inclusion** : la fenêtre
    trouvée doit tenir dans l'illustration dessinée, sans mordre sur le trait.
    La différence arrière du gradient rentre les arêtes haute et gauche d'un
    pixel, ce qui va dans le sens sûr et est documenté dans `Stack.sharpness`.
    """
    left, top, right, bottom = 51, 87, 551, 389
    found = derive(figure(left, top, right, bottom)).pixels
    assert left <= found[0] <= left + 1
    assert top <= found[1] <= top + 1
    assert right - 1 <= found[2] <= right
    assert bottom - 1 <= found[3] <= bottom


def test_la_fenetre_est_rendue_en_fractions_de_la_carte():
    """C'est la forme qu'attend `ArtBox`, et la borne haute est exclusive : une
    fenêtre qui s'arrête au pixel 551 va jusqu'à 552/600."""
    window = derive(figure(51, 87, 551, 389))
    assert window.box.right == round((window.pixels[2] + 1) / CARD_WIDTH, 4)
    assert window.box.left == round(window.pixels[0] / CARD_WIDTH, 4)
    assert 0.0 < window.box.left < window.box.right < 1.0


def test_l_illustration_doit_ressortir_plus_sombre_que_le_dessous():
    """Contrôle croisé de la mesure : le pavé de texte est un fond clair, une
    illustration tend vers le gris moyen. Un ordre inversé signale une fenêtre
    posée au mauvais endroit."""
    window = derive(figure(51, 87, 551, 389))
    assert window.art_luminance < window.outside_luminance


# --- la monnaie du pipeline --------------------------------------------------


def test_la_separation_compte_les_paires_et_la_plus_serree():
    assert separation([0b000, 0b011, 0b111]) == (2.0, 1)


def test_deux_empreintes_identiques_donnent_une_paire_a_zero():
    """Le cas qui doit sauter aux yeux : deux cartes que l'index ne peut pas
    départager."""
    assert separation([5, 5])[1] == 0
