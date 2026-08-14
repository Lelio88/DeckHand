"""Ce que le connecteur Wankul décide sans la source.

Ces tests portent sur la moitié du connecteur qui ne dépend d'aucun réseau :
l'identité d'une carte et ce qui est rangé dans quelle colonne. C'est là que les
quatre jeux précédents ont perdu du temps — un prix pris pour une cote, un nom
pris pour une identité, un champ d'affichage pris pour une clé — et c'est
testable avant que la première requête ne soit écrite.
"""

from __future__ import annotations

import pytest

from app.ingestion.wankul_ingest import (
    EXPECTED_CARDS,
    EXPECTED_TOTAL,
    GAME,
    WankulCard,
    fetch_all,
    orientation_of,
    write_cards,
)


def carte(**kw) -> WankulCard:
    base = dict(
        number="78",
        name="Mort-Vivant",
        set_code="ORIGINS",
        type_line="Personnage",
        rarity="Rare",
        effigy="Laink",
    )
    base.update(kw)
    return WankulCard(**base)


class ConnexionFactice:
    """Retient ce qu'on lui donne à écrire, sans base derrière."""

    def __init__(self) -> None:
        self.rows: list[tuple] = []
        self.commits = 0

    def cursor(self):
        conn = self

        class _Curseur:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def execute(self, _statement, row):
                conn.rows.append(row)

        return _Curseur()

    def commit(self) -> None:
        self.commits += 1


# --- l'identite ne se derive pas du nom -------------------------------------


def test_deux_effigies_du_meme_nom_sont_deux_cartes():
    """**La leçon Pokémon, appliquée avant d'en payer le prix.** Là-bas, 92 % du
    catalogue partageait son nom avec une autre carte — 112 Pikachu — et dériver
    l'identité du nom les aurait fusionnés. Wankul imprime le même personnage
    sous deux effigies : `mort_vivant_laink` et `mort_vivant_terracid` portent le
    même nom et sont deux cartes distinctes."""
    laink = carte(number="78", effigy="Laink")
    terracid = carte(number="79", effigy="Terracid")

    assert laink.name == terracid.name
    assert laink.oracle_id != terracid.oracle_id


def test_le_meme_numero_dans_deux_extensions_ne_se_confond_pas():
    """Les numérotations recommencent à chaque extension : le numéro seul ne
    peut pas être la clé."""
    origins = carte(set_code="ORIGINS", number="1")
    saison2 = carte(set_code="S02", number="1")

    assert origins.oracle_id != saison2.oracle_id


def test_l_identite_est_stable_d_une_course_a_l_autre():
    """Elle est dérivée, donc reproductible : une réingestion doit remplacer la
    carte, pas en créer une seconde. Sans quoi chaque course doublerait la
    collection de l'utilisateur."""
    assert carte().oracle_id == carte().oracle_id
    # Ce qui ne participe pas à la clé ne doit pas la déplacer.
    assert carte().oracle_id == carte(name="Autre nom", rarity="Commune").oracle_id


# --- ce qui est range ou, et ce qui reste vide -------------------------------


def test_les_colonnes_de_magic_restent_vides():
    """**Wankul n'a ni couleur ni coût d'invocation.** Y ranger un analogue de
    forme referait l'erreur mesurée sur Yu-Gi-Oh, où l'Attribut logé dans
    `color_identity` aurait écarté 32 % du catalogue sur une règle inexistante."""
    conn = ConnexionFactice()
    write_cards(conn, [carte()])

    (row,) = conn.rows
    # L'ordre suit la requête : oracle_id, name, type_line, oracle_text,
    # color_identity, legalities, layout, game.
    assert row[4] == [], "l'identité de couleur doit rester vide"
    assert row[7] == GAME


def test_l_orientation_tient_lieu_de_disposition_et_non_l_effigie():
    """**Correction établie sur pièces.** Ce module rangeait d'abord l'effigie
    dans `layout`. Deux cartes ont montré que c'est faux : « Road Trip » est
    horizontale et porte son illustration en plein cadre, textes superposés ;
    « Braqueur » est verticale et porte une illustration encadrée, de 0,045 à
    0,672 de sa hauteur. Ce ne sont pas deux rotations d'une même maquette, ce
    sont deux mises en page — et c'est l'orientation qui les distingue, comme
    chez Riftbound. L'API du Wankuldex publie d'ailleurs ce champ.

    L'effigie reste une information de contenu : de quel personnage la carte
    porte le visage, ce qui ne décide d'aucun découpage."""
    conn = ConnexionFactice()
    write_cards(conn, [carte(orientation="horizontal", effigy="Terracid")])

    (row,) = conn.rows
    assert row[6] == "horizontal"


def test_l_orientation_se_deduit_du_rendu_et_non_du_champ_homonyme():
    """**Le champ `orientation` de la source ment, et c'est mesuré.**
    `?orientation=horizontal` rend 40 cartes dont 13 sont debout : les promos
    PGW 2023, 2024, 2025 et une Édition Spéciale. Trois d'entre elles ont été
    confrontées à leur rendu — 751 x 1059, des cartes verticales.

    Ce qui sépare réellement les deux maquettes est la présence d'un rendu
    paysage : les 27 Terrains du lot en ont un, aucune des 13 autres.
    """
    terrain = {"name": "NAVIRE PIRATE", "imagePaysage": "/…_paysage.jpg",
               "imageUrl": "/…_main.jpg"}
    promo = {"name": "CHIEN - PGW 2024", "imagePaysage": None,
             "imageUrl": "/…_main.jpg"}

    assert orientation_of(terrain) == "horizontal"
    assert orientation_of(promo) == "vertical", (
        "une promo PGW est annoncée horizontale par la source et imprimée debout"
    )


def test_le_volume_attendu_couvre_les_six_extensions():
    """Garde-fou de complétude : une course qui rendrait nettement moins a
    rencontré un mur, et le journal doit le dire plutôt que d'enregistrer un
    catalogue amputé — le défaut qui a coûté 93 decks sur Yu-Gi-Oh."""
    assert len(EXPECTED_CARDS) == 6
    assert EXPECTED_TOTAL == 958


def test_une_carte_citee_deux_fois_n_est_ecrite_qu_une_fois():
    """Une source qui sert la même carte sous deux entrées ne doit pas produire
    deux lignes : l'écriture est idempotente dans la course comme entre deux."""
    conn = ConnexionFactice()
    written = write_cards(conn, [carte(), carte(), carte(number="79")])

    assert written == 2
    assert conn.commits == 1


# --- la lecture n'est pas branchee, et le dit ------------------------------


def test_la_lecture_refuse_de_rendre_une_liste_vide():
    """**Lever plutôt que rendre zéro carte.** Une liste vide se propagerait
    jusqu'à une course qui n'écrirait rien, et le journal dirait « 0 carte » —
    ce qui se lit comme une source tarie, pas comme un connecteur inachevé."""
    with pytest.raises(NotImplementedError) as leve:
        fetch_all()

    assert "autorisation" in str(leve.value)
