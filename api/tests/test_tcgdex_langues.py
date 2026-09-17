"""Ce que le connecteur Pokémon indexe, et dans quelles langues.

**Ce que ces tests protègent.** Le catalogue Pokémon n'avait que l'anglais et le
français ; il porte désormais les cinq langues que TCGdex traduit **et** qui
recouvrent le catalogue anglais. Deux erreurs ne se verraient pas sans eux :
n'écrire qu'une langue sur cinq, et écrire un doublon pour chaque carte dont le
nom ne change pas d'une langue à l'autre — cas fréquent ici, les Pokémon gardant
souvent leur nom en écriture latine.

Deux pièges de la source sont verrouillés plus bas, et aucun ne se voit dans un
compte de cartes : trois routes répondent `200` avec zéro carte, et deux langues
publient leurs propres sets, donc leurs propres identifiants. Un catalogue vide
comme un catalogue qui ne recoupe rien se lisent tous deux comme un succès.
"""

from __future__ import annotations

from typing import Any

from app.ingestion.tcgdex_ingest import (
    TRANSLATED_LANGS,
    oracle_uuid,
    write_search_names,
)


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

            def executemany(self, _statement, batch):
                conn.rows.extend(batch)

        return _Curseur()

    def commit(self) -> None:
        self.commits += 1


def carte(card_id: str = "swsh3-136", name: str = "Bidoof") -> dict[str, Any]:
    return {"id": card_id, "name": name}


def langues_de(rows: list[tuple]) -> list[str]:
    return [r[3] for r in rows]


# --- toutes les langues recoltees atteignent l'index ------------------------


def test_chaque_langue_traduite_donne_sa_ligne():
    conn = ConnexionFactice()
    cartes = [carte()]
    traductions = {
        "fr": {"swsh3-136": "Keunotor"},
        "de": {"swsh3-136": "Bidiza"},
        "ja": {"swsh3-136": "ビッパ"},
    }

    write_search_names(conn, cartes, traductions)

    assert sorted(langues_de(conn.rows)) == ["de", "en", "fr", "ja"]


def test_le_nom_anglais_vient_de_la_carte_pas_des_traductions():
    """Il existe pour toute carte, y compris celles qu'aucune langue ne traduit."""
    conn = ConnexionFactice()

    write_search_names(conn, [carte()], {})

    assert langues_de(conn.rows) == ["en"]
    assert conn.rows[0][1] == "Bidoof"


# --- ce qui n'est PAS ecrit -------------------------------------------------


def test_une_traduction_identique_a_l_anglais_n_est_pas_ecrite():
    """**Le cas frequent, pas le cas limite.** Beaucoup de Pokémon gardent leur
    nom d'une langue à l'autre ; écrire l'entrée ferait un doublon sous un autre
    code de langue, au prix d'une ligne et d'une ambiguïté à l'affichage."""
    conn = ConnexionFactice()
    traductions = {
        "it": {"swsh3-136": "Bidoof"},   # identique
        "de": {"swsh3-136": "Bidiza"},   # traduit
    }

    write_search_names(conn, [carte()], traductions)

    assert sorted(langues_de(conn.rows)) == ["de", "en"]


def test_une_carte_absente_d_une_langue_ne_produit_rien():
    conn = ConnexionFactice()
    traductions = {"fr": {"une-autre-carte": "Keunotor"}}

    write_search_names(conn, [carte()], traductions)

    assert langues_de(conn.rows) == ["en"]


# --- la liste des langues ---------------------------------------------------


def test_les_langues_sans_catalogue_ne_sont_pas_demandees():
    """`nl`, `pl` et `ru` répondent `200` avec zéro carte — relevé, pas supposé.
    Les demander écrirait une langue qui n'existe pas et que le réglage
    d'affichage proposerait ensuite."""
    assert "nl" not in TRANSLATED_LANGS
    assert "pl" not in TRANSLATED_LANGS
    assert "ru" not in TRANSLATED_LANGS


def test_les_langues_a_sets_propres_sont_ecartees():
    """**Le piege que seul un recouvrement d'identifiants revele.** Le japonais
    et le chinois publient leurs propres sets : 14 cartes japonaises sur 12 781
    partagent un identifiant avec l'anglais, et zero chinoise sur 7 436. Les
    garder ferait proposer une langue qui rendrait 14 cartes sur 21 000."""
    assert "ja" not in TRANSLATED_LANGS
    assert "zh-tw" not in TRANSLATED_LANGS


def test_la_table_traduit_vers_les_codes_de_la_colonne():
    """Les codes de la source et ceux de `card_search_names` doivent coincider :
    une meme langue rangee sous deux noms serait introuvable."""
    assert set(TRANSLATED_LANGS.values()) == {"fr", "de", "es", "it", "pt"}


def test_l_identite_ne_depend_pas_de_la_langue():
    """Toutes les lignes d'une carte partagent son `oracle_id` : c'est ce qui
    fait qu'un nom japonais retrouve la même carte qu'un nom français."""
    conn = ConnexionFactice()
    traductions = {"fr": {"swsh3-136": "Keunotor"}, "ja": {"swsh3-136": "ビッパ"}}

    write_search_names(conn, [carte()], traductions)

    identites = {r[0] for r in conn.rows}
    assert identites == {str(oracle_uuid("swsh3-136"))}
