"""Ce que le connecteur Wankul décide sans la source.

Ces tests portent sur la moitié du connecteur qui ne dépend d'aucun réseau :
l'identité d'une carte et ce qui est rangé dans quelle colonne. C'est là que les
quatre jeux précédents ont perdu du temps — un prix pris pour une cote, un nom
pris pour une identité, un champ d'affichage pris pour une clé — et c'est
testable avant que la première requête ne soit écrite.
"""

from __future__ import annotations

import pytest

from app.ingestion.wankul_ingest import GAME, WankulCard, fetch_all, write_cards


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


def test_l_effigie_tient_lieu_de_disposition():
    """Elle décide de la mise en page, donc de la fenêtre d'illustration —
    même usage que le `frameType` de Yu-Gi-Oh et le gabarit de #28."""
    conn = ConnexionFactice()
    write_cards(conn, [carte(effigy="Terracid")])

    (row,) = conn.rows
    assert row[6] == "Terracid"


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
