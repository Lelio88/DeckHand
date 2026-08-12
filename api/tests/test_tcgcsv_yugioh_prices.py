"""Tests de la valorisation Yu-Gi-Oh.

**Ce qu'ils protègent, c'est un prix plausible mais faux** — le seul défaut qui
ne lève rien et ne se voit pas à l'écran. Trois façons de se tromper sont
couvertes : rapprocher la mauvaise impression, retenir la mauvaise édition, et
valoriser sur un prix qui n'en est pas un.

Aucun réseau : les réponses de TCGCSV sont figées en fixtures.
"""

from __future__ import annotations

from decimal import Decimal

from app.ingestion.tcgcsv_yugioh_prices import EDITIONS, best_price, print_key


class TestClefDImpression:
    def test_les_deux_ecritures_du_meme_code_se_rejoignent(self):
        # **Le rapprochement tient à cela.** Le catalogue intercale le code de
        # langue (« LOB-EN005 »), TCGplayer non (« LOB-005 »). Sans cette
        # normalisation, aucune carte ne serait cotée — et l'échec serait
        # silencieux, la collection valant simplement zéro.
        assert print_key("LOB-EN005", "Ultra Rare") == print_key("LOB-005", "Ultra Rare")

    def test_la_rarete_fait_partie_de_la_cle(self):
        # Une même carte paraît dans une même extension sous plusieurs raretés,
        # à des prix qui n'ont rien à voir. Les confondre écrirait le prix d'une
        # Secret Rare sur une Common.
        assert print_key("LOB-005", "Ultra Rare") != print_key("LOB-005", "Common")

    def test_la_casse_et_les_espaces_ne_separent_pas(self):
        assert print_key("lob-en005", " ultra rare ") == ("LOB", "005", "ultra rare")

    def test_un_numero_a_lettre_reste_distinct(self):
        # Les extensions à sous-séries numérotent « SGX4-ENA03 » : la lettre fait
        # partie du numéro et ne doit pas être prise pour un code de langue.
        assert print_key("SGX4-ENA03", "Secret Rare") == ("SGX4", "A03", "secret rare")

    def test_un_code_illisible_ne_rapproche_rien(self):
        # Mieux vaut ne pas coter que coter au hasard : sans clé, l'impression
        # reste à zéro, ce qui est faux mais visible.
        assert print_key("bidon", "Common") is None
        assert print_key("", None) is None


class TestChoixDeLEdition:
    def test_l_edition_courante_l_emporte_sur_la_premiere(self):
        # **Une première édition n'est pas ce qu'on possède d'ordinaire.** La
        # retenir gonflerait la valeur d'une collection ordinaire — ici d'un
        # facteur quatre — sans que rien ne le signale.
        rows = [
            {"productId": 1, "subTypeName": "1st Edition", "marketPrice": 10.0},
            {"productId": 1, "subTypeName": "Unlimited", "marketPrice": 2.5},
        ]
        assert best_price(rows) == {1: Decimal("2.5")}

    def test_la_premiere_edition_sert_quand_elle_est_seule(self):
        # Beaucoup d'extensions ne paraissent qu'en première édition : refuser
        # de les coter laisserait des pans entiers du catalogue à zéro.
        rows = [{"productId": 2, "subTypeName": "1st Edition", "marketPrice": 7.0}]
        assert best_price(rows) == {2: Decimal("7.0")}

    def test_un_produit_sans_prix_de_marche_est_absent(self):
        # Il comptera pour zéro, jamais pour une estimation inventée.
        rows = [{"productId": 3, "subTypeName": "Unlimited", "marketPrice": None}]
        assert best_price(rows) == {}

    def test_l_ordre_des_editions_est_explicite(self):
        # Si quelqu'un réordonne cette constante, il change la valorisation de
        # toute la collection : le test le lui rappelle.
        assert EDITIONS[0] == "Unlimited"
        assert EDITIONS[1] == "1st Edition"
