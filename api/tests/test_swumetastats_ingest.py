"""Tests du connecteur de decks Star Wars Unlimited.

Chaque cas correspond à un piège mesuré sur la source, ou à une propriété dont
dépend le calcul de complétion. Aucun réseau.
"""

from __future__ import annotations

from typing import Any

from app.ingestion.swumetastats_ingest import (
    FORMAT,
    MIN_MAIN_CARDS,
    boards,
    deck_name,
    fold_punctuation,
)


def carte(name: str, section: str, count: int = 1) -> dict[str, Any]:
    return {"cardName": name, "section": section, "count": count}


# --- les zones, et ce qui compte dans la complétion --------------------------


def test_le_leader_et_la_base_comptent_dans_le_pan_principal():
    """**On ne pose pas un deck sans eux.** C'est le précédent Riftbound, dont
    les runes et les champs de bataille sont fondus dans le principal pour la
    même raison : les omettre ferait paraître constructible une liste dont il
    manque des cartes."""
    main, side, leader = boards(
        {
            "cards": [
                carte("Boba Fett | Daimyo", "Leader"),
                carte("Echo Base", "Base"),
                carte("Wampa", "MainDeck", 3),
            ]
        }
    )
    assert main == {"Boba Fett | Daimyo": 1, "Echo Base": 1, "Wampa": 3}
    assert side == {}
    assert leader == "Boba Fett | Daimyo"


def test_la_reserve_est_exclue_du_pan_principal():
    """Comme partout ailleurs : on peut jouer le deck sans elle."""
    main, side, _ = boards(
        {"cards": [carte("Wampa", "MainDeck", 2), carte("Vanquish", "Sideboard", 3)]}
    )
    assert main == {"Wampa": 2}
    assert side == {"Vanquish": 3}


def test_le_leader_est_retenu_a_part_pour_le_commandant():
    """C'est par lui qu'on choisit un deck, comme la Légende de Riftbound
    occupe `decks.commander_oracle_id`."""
    _, _, leader = boards({"cards": [carte("Sabine Wren | Galvanized Revolutionary",
                                           "Leader")]})
    assert leader == "Sabine Wren | Galvanized Revolutionary"


def test_une_zone_inconnue_est_ignoree_plutot_que_versee_au_principal():
    """Mieux vaut une zone perdue qu'une réserve comptée dans la complétion :
    un deck annoncé plus complet qu'il n'est est le pire défaut pour ce
    produit."""
    main, side, _ = boards({"cards": [carte("X", "Maybeboard", 4)]})
    assert main == {} and side == {}


def test_une_quantite_absente_ou_nulle_ne_compte_pas():
    main, _, _ = boards(
        {"cards": [carte("A", "MainDeck", 0), {"cardName": "B", "section": "MainDeck"}]}
    )
    assert main == {}


def test_deux_citations_d_une_meme_carte_se_cumulent():
    """La même carte peut apparaître deux fois dans une liste — deux lignes,
    une carte."""
    main, _, _ = boards(
        {"cards": [carte("Wampa", "MainDeck", 2), carte("Wampa", "MainDeck", 1)]}
    )
    assert main == {"Wampa": 3}


# --- la ponctuation, qui sépare deux sources qui disent la même chose --------


def test_les_guillemets_courbes_sont_replies():
    """Les listes citent « Benthic “Two Tubes” », le catalogue publie des
    guillemets droits. Trois citations perdues sur vingt decks mesurés."""
    assert fold_punctuation("Benthic “Two Tubes”") == 'Benthic "Two Tubes"'


def test_l_ellipse_est_retiree():
    """« Jar Jar Binks | Mesa Propose… » chez l'un, sans ellipse chez
    l'autre."""
    assert fold_punctuation("Mesa Propose…") == "Mesa Propose"


def test_le_pliage_ne_touche_pas_un_titre_ordinaire():
    """Une normalisation qui change ce qu'elle ne doit pas changer produit des
    faux couples, que nul écran ne détrompe."""
    for titre in ("Boba Fett | Daimyo", "Data Vault", "K-2SO | Cassian's Counterpart"):
        assert fold_punctuation(titre) == titre


# --- ce que le connecteur déclare -------------------------------------------


def test_le_format_declare_est_celui_qui_porte_le_corpus():
    """`premier` couvre 19 tournois sur 20, tous officiels — mesuré, et non
    déduit d'un nom. Yu-Gi-Oh a payé la déduction inverse : `Advanced` y avait
    été déclaré parce qu'il porte le nom du format courant du jeu, pour trois
    decklists sur 168 tournois."""
    assert FORMAT == "premier"


def test_le_seuil_de_taille_vient_de_la_distribution():
    """Les tailles observées vont de 50 à 64 cartes hors réserve. Le seuil est
    très en deçà de tout deck réel et très au-dessus d'un fragment : il écarte
    l'accident sans prétendre juger les règles du jeu."""
    assert 0 < MIN_MAIN_CARDS < 50


def test_le_nom_du_deck_porte_le_tournoi_et_le_classement():
    assert deck_name(
        {"tournament": {"name": "Galactic Championship"}, "standing": 3}
    ) == "Galactic Championship — 3e place"
    assert deck_name({"tournament": {"name": "Open"}}) == "Open"
    assert deck_name({}) == "Tournoi"
