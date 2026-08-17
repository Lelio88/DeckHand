"""Tests du connecteur de catalogue One Piece.

Chaque cas correspond à un piège mesuré sur la source, ou à une propriété dont
dépend une ligne écrite en base. Aucun réseau.
"""

from __future__ import annotations

from typing import Any

from app.ingestion.optcg_ingest import (
    Entry,
    _as_number,
    fold_cards,
    fold_printings,
    parse,
)


def entree(**kwargs: Any) -> Entry:
    defaults: dict[str, Any] = dict(
        origin="OP-01",
        code="OP01-077",
        image_id="OP01-077",
        name="Perona",
        type="Character",
        color="Blue",
        cost="1",
        power="2000",
        rarity="UC",
        text="",
        subtypes="Thriller Bark Pirates",
        image="https://optcgapi.com/media/static/Card_Images/OP01-077.jpg",
    )
    defaults.update(kwargs)
    return Entry(**defaults)


# --- l'identité : le code, et non le nom ------------------------------------


def test_l_identite_est_le_code_et_non_le_nom():
    """**361 noms sont portés par plusieurs cartes**, et « Monkey.D.Luffy » en
    désigne 62. Les fusionner par le nom en ferait une seule — le piège que
    Pokémon a posé de la même façon, avec 92 % de ses cartes partageant leur
    nom."""
    luffy_un = entree(code="OP01-003", image_id="OP01-003", name="Monkey.D.Luffy")
    luffy_deux = entree(code="ST01-001", image_id="ST01-001", name="Monkey.D.Luffy")
    assert luffy_un.oracle_id != luffy_deux.oracle_id
    assert len(fold_cards([luffy_un, luffy_deux])) == 2


def test_une_variante_partage_la_carte_mais_pas_l_impression():
    """« Perona » et « Perona (Box Topper) » sont la même carte sous deux
    tirages — 0,94 $ et 45,24 $. Les compter comme deux cartes créerait deux
    lignes de collection pour un exemplaire, le défaut de Riftbound."""
    ordinaire = entree(image_id="OP01-077", name="Perona")
    variante = entree(image_id="OP01-077_p1", name="Perona (Box Topper)")
    assert ordinaire.oracle_id == variante.oracle_id
    assert ordinaire.print_key != variante.print_key
    assert len(fold_cards([ordinaire, variante])) == 1
    assert len(fold_printings([ordinaire, variante])) == 2


def test_le_nom_de_la_carte_vient_de_l_entree_ordinaire():
    """Et non de la première rencontrée : une variante vue en premier
    imposerait « Perona (Box Topper) » comme nom de la carte."""
    ordinaire = entree(image_id="OP01-077", name="Perona")
    variante = entree(image_id="OP01-077_p1", name="Perona (Box Topper)")
    for ordre in ([ordinaire, variante], [variante, ordinaire]):
        assert fold_cards(ordre)[0].name == "Perona"


def test_une_carte_qui_n_existe_qu_en_variante_garde_une_entree():
    """Sinon elle disparaîtrait du catalogue sans que rien ne le signale."""
    cartes = fold_cards([entree(image_id="OP01-077_p1", name="Perona (Manga)")])
    assert len(cartes) == 1
    assert cartes[0].name == "Perona"


def test_une_reedition_a_l_identique_ne_fait_qu_une_impression():
    """56 entrées partagent leur identifiant de rendu : ce sont les cartes
    qu'un deck de démarrage réédite à l'identique, `OP02-018` paraissant dans
    `OP-02` et dans `ST-15`. C'est le même carton, donc la même impression."""
    booster = entree(origin="OP-02", code="OP02-018", image_id="OP02-018")
    starter = entree(origin="ST-15", code="OP02-018", image_id="OP02-018")
    assert booster.print_key == starter.print_key
    assert len(fold_printings([booster, starter])) == 1


# --- les suffixes de variante, qui s'empilent -------------------------------


def test_les_suffixes_de_nom_se_retirent_tous():
    """N'en retirer qu'un faisait conclure que 316 codes réunissaient deux
    cartes différentes."""
    for nom in (
        "Donquixote Doflamingo (073)",
        "Donquixote Doflamingo (073) (Parallel)",
        "Donquixote Doflamingo (SP)",
    ):
        assert entree(name=nom).base_name == "Donquixote Doflamingo"


def test_le_code_accole_par_un_tiret_se_retire_aussi():
    assert entree(name="Buggy - OP03-008 (Pirate Foil)").base_name == "Buggy"


def test_un_tiret_dans_le_nom_survit():
    """Ce sont les espaces autour du tiret qui protègent « Zoro-Juurou ». Un
    motif plus lâche l'amputerait, et deux cartes deviendraient une."""
    assert entree(name="Zoro-Juurou (Alternate Art)").base_name == "Zoro-Juurou"


def test_les_deux_familles_de_suffixe_de_rendu_marquent_une_variante():
    """Le vocabulaire va de `p1` à `p8` et de `r1` à `r3` : n'en lire qu'une en
    manquait 335."""
    assert entree(image_id="OP01-077_p1").is_variant
    assert entree(image_id="ST18-001_r1").is_variant
    assert not entree(image_id="OP01-077").is_variant


# --- ce que les colonnes portent --------------------------------------------


def test_une_carte_bicolore_declare_ses_deux_couleurs():
    """La source les sépare par une barre. N'en garder qu'une écarterait la
    carte d'un deck où elle est légale."""
    assert entree(color="Red/Green").colors == ["Red", "Green"]
    assert entree(color="Blue").colors == ["Blue"]
    assert entree(color="").colors == []


def test_un_leader_sans_cout_recoit_zero_car_la_colonne_le_refuse():
    """`cards.cmc` est `NOT NULL DEFAULT 0`. Les 285 Leaders n'ont pas de coût —
    on ne les joue pas, on commence la partie avec — et leur zéro se lira
    « gratuit »."""
    assert _as_number("3") == 3.0
    assert _as_number("") == 0.0
    assert _as_number(None) == 0.0


def test_la_ligne_de_type_reunit_le_type_et_les_familles():
    carte = fold_cards([entree(type="Character", subtypes="Straw Hat Crew")])[0]
    assert carte.type_line == "Character — Straw Hat Crew"
    sans = fold_cards([entree(code="X-1", image_id="X-1", subtypes="")])[0]
    assert sans.type_line == "Character"


# --- la lecture de la source ------------------------------------------------


def test_un_cout_nul_de_la_source_est_lu_comme_absent():
    lu = parse({"card_set_id": "ST01-001", "card_image_id": "ST01-001",
                "card_name": "Monkey.D.Luffy", "card_type": "Leader",
                "card_cost": None}, origin="ST-01")
    assert lu.cost == ""
    assert lu.origin == "ST-01"
