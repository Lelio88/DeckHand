"""Tests de la confrontation entre le coût annoncé et son recalcul.

**Ce qu'ils protègent tient en une phrase : un écart doit se voir.** Ce script
existe pour attraper les erreurs d'arithmétique de l'écran Decks — « il te
manque 3 cartes pour 4,20 € » engage l'argent de l'utilisateur. Un comparateur
qui laisserait passer un écart serait pire qu'inutile : il donnerait une
assurance fausse.

Le cas particulier verrouillé ici est celui des **terrains de base**. Ils sont
volontairement hors du calcul — on ne les achète pas, on les prend dans la
boîte — mais la fonction les publie à part. Le harnais les comptait dans le
total, ce qui produisait des écarts imputés à tort à la fonction. Les exclure
sans plus les regarder aurait fait concorder les deux calculs tout en aveuglant
le script sur la règle : ils sont donc comparés eux aussi.
"""

from __future__ import annotations

from app.measure.deck_math import Suggestion, compare


def suggestion(**overrides) -> Suggestion:
    base = dict(
        deck_id="d1",
        deck_name="Deck",
        total=41,
        owned=15,
        missing=26,
        cost=35.58,
        basics=19,
    )
    base.update(overrides)
    return Suggestion(**base)


class TestConcordance:
    def test_deux_calculs_identiques_ne_relevent_rien(self):
        assert compare([suggestion()], {"d1": suggestion()}) == []

    def test_un_deck_absent_du_recalcul_se_dit(self):
        # Le silence serait pire : un deck que le recalcul ignore est un deck
        # dont personne ne vérifie les nombres.
        faults = compare([suggestion()], {})
        assert len(faults) == 1
        assert "inconnu" in faults[0]


class TestCeQuiEstCompare:
    def test_une_carte_d_ecart_se_voit(self):
        faults = compare([suggestion(missing=27)], {"d1": suggestion()})
        assert any("missing" in f for f in faults)

    def test_le_cout_tolere_le_centime_et_pas_plus(self):
        # L'arrondi du serveur et celui de Python peuvent diverger d'un centime ;
        # deux, c'est une erreur de calcul.
        assert compare([suggestion(cost=35.585)], {"d1": suggestion()}) == []
        assert compare([suggestion(cost=35.60)], {"d1": suggestion()}) != []

    def test_les_terrains_de_base_sont_compares_eux_aussi(self):
        # Sans cette comparaison, la fonction pourrait cesser de les écarter
        # sans que rien ne le signale : le total resterait juste des deux côtés,
        # puisque le harnais suivrait le même changement.
        faults = compare([suggestion(basics=0)], {"d1": suggestion(basics=19)})
        assert any("basics" in f for f in faults)

    def test_un_deck_sans_terrain_de_base_reste_conforme(self):
        # Riftbound n'en a aucun : la comparaison ne doit pas inventer d'écart.
        assert compare([suggestion(basics=0)], {"d1": suggestion(basics=0)}) == []
