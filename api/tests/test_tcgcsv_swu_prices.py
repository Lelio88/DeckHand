"""Tests du connecteur de prix Star Wars Unlimited.

Chaque cas correspond à un défaut réellement rencontré, ou à une propriété dont
dépend un chiffre affiché à l'utilisateur. Aucun réseau.
"""

from __future__ import annotations

from decimal import Decimal

from app.ingestion.tcgcsv_prices import market_prices, to_euros
from app.ingestion.tcgcsv_swu_prices import CATEGORY_SWU, Products, declared_subtypes


def ligne(product_id: int, subtype: str, market: float | None = 1.0) -> dict:
    return {"productId": product_id, "subTypeName": subtype, "marketPrice": market}


# --- les finitions, dont TCGCSV fait autorité pour ce jeu -------------------


def test_la_presence_de_la_ligne_declare_la_finition_pas_le_prix():
    """Déduire les finitions des prix conclurait « n'existe pas en brillante »
    à partir de « personne n'en vend en ce moment ». TCGCSV publie la ligne
    même sans `marketPrice`."""
    declared = declared_subtypes([ligne(1, "Foil", market=None)])
    assert declared == {1: {"foil"}}


def test_les_deux_finitions_d_un_produit_se_reunissent():
    declared = declared_subtypes([ligne(1, "Normal"), ligne(1, "Foil")])
    assert declared == {1: {"nonfoil", "foil"}}


def test_une_carte_qui_n_existe_qu_en_brillante_ne_declare_que_la_brillante():
    """**Le défaut que la mesure a révélé.** 517 impressions `Showcase`
    n'existent qu'en brillante chez TCGplayer, et le catalogue SWU-DB les
    déclarait ordinaires — une case que le carton n'a jamais eue, proposée à la
    saisie, et une carte à 290 € valorisée à zéro."""
    assert declared_subtypes([ligne(7, "Foil")]) == {7: {"foil"}}


def test_un_sous_type_inconnu_est_ignore():
    """Le vocabulaire de ce champ n'est pas universel : chez Yu-Gi-Oh il porte
    une **édition** (`Unlimited`, `1st Edition`) et non une finition. Y lire une
    finition déclarerait « existe en brillante » sur la foi d'un tirage."""
    assert declared_subtypes([ligne(3, "1st Edition")]) == {}
    assert declared_subtypes([ligne(3, "Unlimited")]) == {}


# --- les prix ---------------------------------------------------------------


def test_le_prix_retenu_est_celui_du_marche():
    """`marketPrice` et non `lowPrice` : le prix bas est une annonce isolée —
    carte abîmée, erreur de saisie —, le prix de marché est calculé sur les
    ventes réelles. C'est aussi ce que Scryfall publie pour Magic, condition
    pour que les totaux des deux jeux se comparent."""
    prices = market_prices([{"productId": 5, "subTypeName": "Normal",
                             "marketPrice": 2.5, "lowPrice": 0.01}])
    assert prices == {5: {"Normal": Decimal("2.5")}}


def test_un_produit_sans_prix_de_marche_est_absent_plutot_que_valorise():
    assert market_prices([ligne(9, "Normal", market=None)]) == {}


def test_la_conversion_divise_par_le_taux_publie():
    """Le taux BCE exprime combien de dollars vaut un euro. Multiplier au lieu
    de diviser majorerait tout de 15 % en restant parfaitement crédible à
    l'œil."""
    assert to_euros(Decimal("11.593"), Decimal("1.1593")) == Decimal("10.00")
    assert to_euros(None, Decimal("1.1593")) is None


# --- ce que le connecteur soumet -------------------------------------------


def test_les_produits_soumis_reunissent_les_cotes_et_les_declares():
    """Un produit déclaré sans prix doit tout de même passer : c'est lui qui
    porte la finition, et l'omettre laisserait une impression insaisissable."""
    products = Products(market={1: {"Normal": Decimal("1")}}, declared={2: {"foil"}})
    assert products.product_ids == [1, 2]


def test_la_categorie_est_celle_relevee_sur_la_source():
    """79, relevée sur `/tcgplayer/categories`. Une catégorie fausse écrirait
    les prix d'un autre jeu, et le filtre sur `cards.game` ne le verrait pas —
    il protège d'une collision d'identifiant, pas d'une erreur de catégorie."""
    assert CATEGORY_SWU == 79
