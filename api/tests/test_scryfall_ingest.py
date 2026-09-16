"""Ce que l'ingestion Scryfall garde, et de quelle langue.

Ces tests portent sur le **découplage** entre deux décisions qui n'avaient rien
à faire ensemble : quelles impressions on entrepose, et quels noms on sait lire.
Elles étaient jusqu'ici commandées par le même filtre, si bien qu'une carte
allemande ne pouvait pas être reconnue sans qu'on accepte aussi ses 100 000
impressions — 62 Mo pour un besoin qui en coûte 8.

Le symptôme se constatait sur l'appareil : le nom se lisait sans faute, puis ne
rencontrait aucune entrée. Une panne muette, que rien dans le code ne
distinguait d'une photo ratée.
"""

from __future__ import annotations

from uuid import uuid4

from app.ingestion import scryfall_ingest
from app.ingestion.scryfall_ingest import (
    KEEP_LANGS,
    ingest_prints_and_names,
    write_search_names,
)

ORACLE = str(uuid4())
AUTRE = str(uuid4())


def payload(lang: str, printed: str | None, oracle: str = ORACLE) -> dict:
    """Une impression telle que le *bulk* la publie, réduite à l'utile."""
    return {
        "id": str(uuid4()),
        "oracle_id": oracle,
        "lang": lang,
        "name": "Lightning Bolt",
        "printed_name": printed,
        "set": "m10",
        "set_name": "Magic 2010",
        "collector_number": "146",
        "rarity": "common",
        "prices": {"eur": "1.23", "eur_foil": "4.56"},
        "image_uris": {"art_crop": "https://example.invalid/a.jpg"},
        "illustration_id": str(uuid4()),
        "finishes": ["nonfoil", "foil"],
        "released_at": "2009-07-17",
    }


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

            def execute(self, _statement, *_args):
                return None

            def executemany(self, _statement, batch):
                conn.rows.extend(batch)

        return _Curseur()

    def commit(self) -> None:
        self.commits += 1


# --- la recolte des noms ne suit plus le filtre des impressions --------------


def test_une_langue_non_entreposee_donne_quand_meme_son_nom(monkeypatch):
    """**Le cœur du découplage.** L'allemand n'est pas dans `KEEP_LANGS` ; son
    nom doit pourtant être récolté, faute de quoi la carte reste invisible à la
    reconnaissance alors que l'OCR l'a parfaitement lue."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter(
            [
                payload("en", None),
                payload("fr", "Foudre"),
                payload("de", "Blitzschlag"),
                payload("ja", "稲妻"),
            ]
        ),
    )
    conn = ConnexionFactice()

    written, noms = ingest_prints_and_names(conn, {ORACLE})

    assert noms[(ORACLE, "de")][0] == "Blitzschlag"
    assert noms[(ORACLE, "ja")][0] == "稲妻"
    assert noms[(ORACLE, "fr")][0] == "Foudre"
    assert written == 2, "seules les impressions en et fr sont entreposées"


def test_les_impressions_restent_bornees_aux_langues_gardees(monkeypatch):
    """Le pendant du test précédent : récolter un nom ne doit **pas** faire
    entrer l'impression. C'est ce qui sépare 8 Mo de 62."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([payload("de", "Blitzschlag"), payload("ja", "稲妻")]),
    )
    conn = ConnexionFactice()

    written, noms = ingest_prints_and_names(conn, {ORACLE})

    assert written == 0
    assert noms, "les noms sont là, eux"
    assert "de" not in KEEP_LANGS and "ja" not in KEEP_LANGS


def test_une_carte_hors_perimetre_n_est_pas_recoltee(monkeypatch):
    """`known` borne le catalogue : une carte qu'on n'ingère pas ne doit pas
    laisser un nom orphelin derrière elle."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([payload("de", "Blitzschlag", oracle=AUTRE)]),
    )
    conn = ConnexionFactice()

    _, noms = ingest_prints_and_names(conn, {ORACLE})

    assert noms == {}


# --- ce qui atteint l'index de saisie ---------------------------------------


def test_chaque_langue_recoltee_atteint_l_index():
    conn = ConnexionFactice()
    noms = {
        (ORACLE, "fr"): ("Foudre", "foudre"),
        (ORACLE, "de"): ("Blitzschlag", "blitzschlag"),
        (ORACLE, "ja"): ("稲妻", "稲妻"),
    }

    write_search_names(conn, {ORACLE: "Lightning Bolt"}, noms)

    langues = {row[3] for row in conn.rows}
    assert langues == {"en", "fr", "de", "ja"}


def test_l_anglais_vient_du_nom_oracle_et_n_est_pas_doublonne():
    """Le nom oracle existe pour toute carte, y compris jamais imprimée en
    anglais. Le récolter *aussi* depuis les impressions produirait deux lignes
    pour la même chose — `ON CONFLICT` les absorberait, mais écrire deux fois ce
    qu'on sait écrire une fois est un coût qu'on paie à chaque ingestion."""
    conn = ConnexionFactice()
    noms = {(ORACLE, "en"): ("Lightning Bolt", "lightning bolt")}

    write_search_names(conn, {ORACLE: "Lightning Bolt"}, noms)

    assert [row[3] for row in conn.rows] == ["en"]


def test_un_nom_sans_carte_au_catalogue_est_ecarte():
    """Garde-fou de clé étrangère : `card_search_names.oracle_id` référence
    `cards`. Une entrée orpheline ferait échouer l'insertion entière du lot."""
    conn = ConnexionFactice()
    noms = {(AUTRE, "de"): ("Blitzschlag", "blitzschlag")}

    write_search_names(conn, {ORACLE: "Lightning Bolt"}, noms)

    assert [row[0] for row in conn.rows] == [ORACLE]
