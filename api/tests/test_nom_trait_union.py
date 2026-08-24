"""Tests du banc du trait d'union (#21).

**Le calcul que ce banc a eu faux une fois.** Sa première version imputait au
trait d'union *toutes* les pertes du fragment, y compris celles qui survenaient
déjà quand le fragment était correctement tapé. Sur Lorcana, cela annonçait
« 3 cartes perdues » là où le trait d'union n'en coûte **aucune** — et ce jeu
étant le plus exposé de tous par le simple compte des traits d'union, le chiffre
faux était le plus crédible de tous.
"""

from __future__ import annotations

from app.measure.nom_trait_union import Exposition, Verdict, imputable


def verdict(eprouves: int, retrouves: int) -> Verdict:
    return Verdict(eprouves=eprouves, retrouves=retrouves, exemples=[])


def test_la_perte_du_temoin_n_est_pas_imputable_au_trait_d_union() -> None:
    """Le cas Lorcana : trois pertes des deux côtés, zéro imputable."""
    temoin = verdict(113, 110)
    mal_saisi = verdict(113, 110)
    assert imputable(temoin, mal_saisi) == 0


def test_seul_l_ecart_avec_le_temoin_est_compte() -> None:
    """Le cas Magic : 32 perdus, 11 qui échouaient déjà, 21 imputables."""
    assert imputable(verdict(2111, 2100), verdict(2111, 2079)) == 21


def test_un_ecart_negatif_ne_devient_pas_un_gain() -> None:
    """**Un défaut ne peut pas rendre des cartes.** Si la forme mal saisie en
    retrouve *plus* que la forme correcte, c'est du bruit de mesure, pas un
    bénéfice du trait d'union — et l'annoncer comme tel serait absurde."""
    assert imputable(verdict(100, 90), verdict(100, 95)) == 0


def test_un_verdict_sans_essai_ne_divise_pas_par_zero() -> None:
    vide = verdict(0, 0)
    assert vide.perdus == 0
    assert vide.part_perdue == 0.0


def test_l_exposition_se_lit_en_part() -> None:
    assert Exposition("magic", 64243, 2386).part == 2386 / 64243
    assert Exposition("vide", 0, 0).part == 0.0
