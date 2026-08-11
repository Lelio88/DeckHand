"""Tests de la valorisation Riftbound.

**Ce qu'ils protègent, c'est un chiffre plausible mais faux.** Un prix erroné ne
lève aucune exception et ne se voit pas à l'écran : 8,44 € au lieu de 6,33 €
reste parfaitement crédible sur une carte qu'on ne connaît pas. Les deux façons
de se tromper couvertes ici sont le **sens de la conversion** — multiplier au
lieu de diviser majore tout de 15 % — et la **confusion des finitions**, une
brillante valant couramment le triple d'une ordinaire.

Aucun réseau : les réponses de TCGCSV et de la BCE sont figées en fixtures.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from app.ingestion.tcgcsv_prices import market_prices, to_euros


class TestConversion:
    def test_le_taux_bce_se_divise_et_ne_se_multiplie_pas(self):
        # La BCE publie « 1 € = 1,1540 $ ». Une carte à 6,84 $ vaut donc 5,93 €.
        # Multiplier donnerait 7,89 € — plausible, et faux de 33 %.
        assert to_euros(Decimal("6.84"), Decimal("1.1540")) == Decimal("5.93")

    def test_l_arrondi_va_au_centime(self):
        assert to_euros(Decimal("1.00"), Decimal("3")) == Decimal("0.33")
        assert to_euros(Decimal("2.00"), Decimal("3")) == Decimal("0.67")

    def test_une_carte_sans_prix_reste_sans_prix(self):
        # Ne jamais fabriquer un zéro : une carte non cotée et une carte qui ne
        # vaut rien ne sont pas la même chose.
        assert to_euros(None, Decimal("1.1540")) is None


class TestPrixDeMarche:
    def test_les_finitions_ne_se_melangent_pas(self):
        prices = market_prices(
            [
                {"productId": 1, "subTypeName": "Normal", "marketPrice": 2.0},
                {"productId": 1, "subTypeName": "Foil", "marketPrice": 6.5},
            ]
        )
        assert prices[1]["Normal"] == Decimal("2.0")
        assert prices[1]["Foil"] == Decimal("6.5")

    def test_le_prix_bas_ne_remplace_pas_le_prix_de_marche(self):
        # `lowPrice` est une annonce isolée — carte abîmée, erreur de saisie.
        # Sans prix de marché, le produit est absent plutôt que mal valorisé.
        prices = market_prices(
            [
                {
                    "productId": 7,
                    "subTypeName": "Normal",
                    "marketPrice": None,
                    "lowPrice": 0.01,
                }
            ]
        )
        assert prices == {}

    def test_les_sous_types_inconnus_sont_ignores(self):
        # TCGplayer sert d'autres sous-types selon les jeux ; les accepter
        # écraserait le prix ordinaire par celui d'une finition étrangère.
        prices = market_prices(
            [
                {"productId": 3, "subTypeName": "Normal", "marketPrice": 1.0},
                {"productId": 3, "subTypeName": "1st Edition", "marketPrice": 90.0},
            ]
        )
        assert prices[3] == {"Normal": Decimal("1.0")}

    def test_le_flottant_passe_par_le_texte(self):
        # Decimal(0.1) vaut 0.1000000000000000055511151231257827…
        # La conversion par str est ce qui garde deux décimales exactes.
        prices = market_prices(
            [{"productId": 9, "subTypeName": "Normal", "marketPrice": 0.1}]
        )
        assert prices[9]["Normal"] == Decimal("0.1")


@pytest.mark.parametrize(
    "usd, rate, expected",
    [
        ("0.10", "1.1540", "0.09"),
        ("100.00", "1.1540", "86.66"),
        ("1234.56", "1.0000", "1234.56"),
    ],
)
def test_conversions_de_reference(usd, rate, expected):
    assert to_euros(Decimal(usd), Decimal(rate)) == Decimal(expected)
