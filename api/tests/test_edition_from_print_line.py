"""La décision du banc `edition_from_print_line`, sans base.

Une carte imaginaire, imprimée en quatre cases dont les différences couvrent
chaque cas : deux éditions la même année, une avant Exodus (ni numéro ni
total imprimés), une après M15 (code d'extension lisible, hors cible).
"""

from datetime import date

from app.measure.edition_from_print_line import (
    Cell,
    candidates,
    is_target,
    printed_number,
    printed_total,
)

PRE_EXODUS = Cell("4ed", "125", date(1995, 4, 1), 378)
INVASION = Cell("inv", "247", date(2000, 10, 2), 350)
INVASION_PROMO = Cell("pinv", "247", date(2000, 10, 2), None)
GATECRASH = Cell("gtc", "88", date(2013, 2, 1), 249)
M20 = Cell("m20", "247", date(2019, 7, 12), 280)
CARD = [PRE_EXODUS, INVASION, INVASION_PROMO, GATECRASH, M20]


def test_avant_exodus_ni_numero_ni_total():
    assert printed_number(PRE_EXODUS) is None
    assert printed_total(PRE_EXODUS) is None
    assert printed_number(INVASION) == "247"
    assert printed_total(INVASION) == 350


def test_la_cible_est_avant_m15():
    assert is_target(INVASION)
    assert is_target(GATECRASH)
    assert not is_target(M20)


def test_l_annee_stricte_tranche_entre_deux_annees():
    assert candidates(CARD, GATECRASH, ("year",)) == [GATECRASH]


def test_l_annee_ne_separe_pas_deux_editions_de_la_meme_annee():
    assert candidates(CARD, INVASION, ("year",)) == [INVASION, INVASION_PROMO]


def test_l_annee_toleree_garde_les_annees_voisines():
    one_year_apart = Cell("pls", "1", date(2001, 2, 5), 143)
    found = candidates([INVASION, one_year_apart], INVASION, ("year",), tolerant=True)
    assert found == [INVASION, one_year_apart]


def test_le_numero_lu_exclut_les_cases_qui_n_en_portent_pas():
    # Le #247 se lit sur INV et sur M20 ; la carte d'avant Exodus n'en porte
    # aucun, et la promo non plus : son « numéro » est un identifiant de
    # Scryfall, pas une mention imprimée.
    assert candidates(CARD, INVASION, ("number",)) == [INVASION, M20]


def test_une_promo_sans_taille_imprimee_n_a_pas_de_numero_lisible():
    assert printed_number(INVASION_PROMO) is None


def test_le_total_separe_la_promo_sans_total():
    assert candidates(CARD, INVASION, ("total",)) == [INVASION]


def test_rien_de_lisible_ne_tranche_rien():
    # Avant Exodus et sans clé d'année, on ne lit rien : toutes les cases restent.
    assert candidates(CARD, PRE_EXODUS, ("number",)) == CARD
