"""Le rapprochement des extensions Pokémon, vérifié dans les deux sens.

Un couple juste doit être pris ; un couple faux doit être refusé. Le second test
est le seul qui compte vraiment : écrire des prix de 2017 sur des cartes de 1999
ne se voit sur aucun écran.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from app.ingestion.tcgcsv_pokemon_prices import (
    best_prices,
    match_sets,
    name_key,
    name_keys,
    print_number,
    released,
)

TODAY = date(2026, 8, 13)


def _set(id_: str, name: str, day: str) -> dict:
    return {"id": id_, "name": name, "releaseDate": day}


def _group(gid: int, name: str, day: str) -> dict:
    return {"groupId": gid, "name": name, "publishedOn": day}


# --- le nom ----------------------------------------------------------------


def test_le_prefixe_dere_tombe():
    assert name_key("SWSH09: Brilliant Stars") == name_key("Brilliant Stars")
    assert name_key("EX Ruby & Sapphire") == name_key("Ruby & Sapphire")
    assert name_key("SM - Unified Minds") == name_key("Unified Minds")


def test_base_set_nest_pas_reduit_a_rien():
    """Le réduire à rien en faisait une clé vide, où tombait n'importe quoi.

    Les deux noms se rejoignent quand même une fois le préfixe d'ère retiré —
    c'est la générosité voulue, et c'est la date qui les sépare ensuite. Ce que
    ce test protège, c'est qu'ils se rejoignent sur *leur* clé et non sur le
    seau vide que partageaient alors toutes les extensions sans nom propre.
    """
    assert name_key("Base Set") == "baseset"
    assert name_key("SM Base Set") == "baseset"
    assert name_key("EX") == ""  # un nom qui n'est qu'un préfixe ne propose rien


def test_un_base_set_final_est_une_cle_de_plus_pas_a_la_place():
    keys = name_keys("SWSH01: Sword & Shield Base Set")
    assert name_key("Sword & Shield") in keys
    assert name_key("Sword & Shield Base Set") in keys


# --- la date ---------------------------------------------------------------


def test_une_date_du_jour_ne_dit_rien():
    """Les POP Series portent la date de la requête, pas leur sortie."""
    assert released("2026-08-13", today=TODAY) is None
    assert released("2026-08-12", today=TODAY) is None
    assert released("2004-09-01", today=TODAY) == date(2004, 9, 1)
    assert released(None, today=TODAY) is None


# --- le numéro -------------------------------------------------------------


def test_le_numero_perd_son_denominateur_et_ses_zeros():
    assert print_number("001/102") == "1"
    assert print_number("SWSH001") == "SWSH1"
    assert print_number("TG01/TG30") == "TG1"
    assert print_number("100") == "100"
    assert print_number("H01") == "H1"
    assert print_number("") is None


# --- le rapprochement, dans les deux sens ----------------------------------


def test_un_couple_juste_est_pris():
    sets = [_set("swsh9", "Brilliant Stars", "2022-02-25")]
    groups = [_group(1, "SWSH09: Brilliant Stars", "2022-02-25")]
    pairs, orphans = match_sets(sets, groups, today=TODAY)
    assert pairs == {"swsh9": 1}
    assert orphans == []


def test_un_couple_faux_est_refuse_par_la_date():
    """Base Set 1999 ne doit pas recevoir les prix de SM Base Set 2017."""
    sets = [_set("base1", "Base Set", "1999-01-09")]
    groups = [_group(7, "SM Base Set", "2017-02-03")]
    pairs, orphans = match_sets(sets, groups, today=TODAY)
    assert pairs == {}
    assert orphans == ["base1"]


def test_entre_deux_candidats_la_date_choisit():
    sets = [_set("base1", "Base Set", "1999-01-09")]
    groups = [
        _group(7, "SM Base Set", "2017-02-03"),
        _group(3, "Base Set", "1999-01-09"),
    ]
    pairs, _ = match_sets(sets, groups, today=TODAY)
    assert pairs == {"base1": 3}


def test_une_date_absente_ne_vaut_pas_un_refus():
    """POP Series 1 : nom identique, date TCGplayer inexploitable."""
    sets = [_set("pop1", "POP Series 1", "2004-09-01")]
    groups = [_group(9, "POP Series 1", "2026-08-13")]
    pairs, orphans = match_sets(sets, groups, today=TODAY)
    assert pairs == {"pop1": 9}
    assert orphans == []


def test_un_alias_passe_avant_le_nom():
    sets = [_set("swshp", "SWSH Black Star Promos", "2019-11-15")]
    groups = [
        _group(5, "SWSH: Sword & Shield Promo Cards", "2019-11-15"),
        _group(6, "Alternate Art Promos", "2019-11-15"),
    ]
    pairs, _ = match_sets(sets, groups, today=TODAY)
    assert pairs == {"swshp": 5}


def test_un_set_sans_candidat_est_compte_pas_tu():
    sets = [_set("tk-xy-b", "XY trainer Kit (Bisharp)", "2015-01-01")]
    pairs, orphans = match_sets(sets, [], today=TODAY)
    assert pairs == {}
    assert orphans == ["tk-xy-b"]


# --- les finitions ---------------------------------------------------------


def test_ordinaire_et_brillant_vont_dans_deux_colonnes():
    rows = [
        {"productId": 1, "subTypeName": "Normal", "marketPrice": 0.25},
        {"productId": 1, "subTypeName": "Reverse Holofoil", "marketPrice": 1.50},
    ]
    assert best_prices(rows) == {1: (Decimal("0.25"), Decimal("1.50"))}


def test_holofoil_prime_sur_reverse_holofoil():
    rows = [
        {"productId": 2, "subTypeName": "Reverse Holofoil", "marketPrice": 3.0},
        {"productId": 2, "subTypeName": "Holofoil", "marketPrice": 9.0},
    ]
    assert best_prices(rows)[2] == (None, Decimal("9.0"))


def test_une_finition_sans_prix_existe_quand_meme():
    """**Le cœur de la correction.** `card_editions` refuse la case « brillante »
    dès que `finishes` est vide, et seul le connecteur Scryfall la remplissait :
    aucune carte Pokémon ne pouvait être déclarée holographique. TCGCSV publie
    pourtant une ligne par couple produit-finition, et elle existe même sans
    `marketPrice` — mesuré, 112 lignes sur 15 016."""
    from app.ingestion.tcgcsv_pokemon_prices import declared_finishes

    rows = [
        {"productId": 1, "subTypeName": "Normal", "marketPrice": 0.25},
        {"productId": 1, "subTypeName": "Reverse Holofoil", "marketPrice": None},
    ]

    # Le prix reste absent : on ne valorise pas sur une annonce aberrante.
    assert best_prices(rows) == {1: (Decimal("0.25"), None)}
    # La finition, elle, est déclarée — c'est la combinaison la plus courante du
    # jeu, un tiers des produits mesurés.
    assert declared_finishes(rows)[1] == ["foil", "nonfoil"]


def test_la_brillante_inversee_compte_comme_brillante():
    """Elle l'est déjà pour les prix : `FINISH_FOIL` range les deux dans une même
    colonne depuis toujours. En faire une troisième valeur demanderait de
    l'apprendre à `card_editions`, à la collection et à l'écran, pour distinguer
    deux nuances de brillant — alors que l'inventaire cherche à savoir si
    l'exemplaire possédé brille."""
    from app.ingestion.tcgcsv_pokemon_prices import FINISH_BY_SUBTYPE

    assert FINISH_BY_SUBTYPE["Holofoil"] == "foil"
    assert FINISH_BY_SUBTYPE["Reverse Holofoil"] == "foil"
    assert FINISH_BY_SUBTYPE["Normal"] == "nonfoil"
    # Table fermée : trois sous-types mesurés sur 15 016 lignes, rien d'autre.
    assert set(FINISH_BY_SUBTYPE) == {"Normal", "Holofoil", "Reverse Holofoil"}


def test_un_sous_type_etranger_ne_declare_rien():
    """Le vocabulaire de Riftbound dit `Foil`, celui de Yu-Gi-Oh une édition. Deux
    jeux servis par la même source, deux tables — et aucune ne doit accepter les
    mots de l'autre."""
    from app.ingestion.tcgcsv_pokemon_prices import declared_finishes

    rows = [
        {"productId": 4, "subTypeName": "Normal", "marketPrice": 1.0},
        {"productId": 4, "subTypeName": "Foil", "marketPrice": 5.0},
        {"productId": 4, "subTypeName": "1st Edition", "marketPrice": 90.0},
    ]

    assert declared_finishes(rows)[4] == ["nonfoil"]


def test_une_impression_declaree_sans_prix_reste_a_ecrire():
    """Le filtre d'avant exigeait un prix ; il perdait exactement les cartes que
    cette correction récupère."""
    from app.ingestion.tcgcsv_pokemon_prices import Quote

    assert Quote(finishes=("foil",)).worth_writing
    assert Quote(plain=Decimal("1")).worth_writing
    assert not Quote().worth_writing


def test_un_produit_sans_prix_de_marche_est_absent():
    """Mieux vaut non coté qu'une valorisation sur une annonce aberrante."""
    rows = [{"productId": 3, "subTypeName": "Normal", "marketPrice": None}]
    assert best_prices(rows) == {}
