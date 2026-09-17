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


#: Une seule œuvre pour toutes ces impressions — le cas courant, et celui qui
#: rend le filtre de langue inoffensif : l'art ne dépend pas de la langue, donc
#: l'empreinte de l'anglaise reconnaît aussi la japonaise.
ILLUSTRATION = "3f7a1c88-0000-4000-8000-000000000001"


def payload(
    lang: str,
    printed: str | None,
    oracle: str = ORACLE,
    illustration: str = ILLUSTRATION,
) -> dict:
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
        "illustration_id": illustration,
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

    # Une liste par (carte, langue) : une carte a plusieurs faces en porte
    # plusieurs, et une carte ordinaire un seul.
    assert noms[(ORACLE, "de")] == [("Blitzschlag", "blitzschlag")]
    assert noms[(ORACLE, "ja")][0][0] == "稲妻"
    assert noms[(ORACLE, "fr")][0][0] == "Foudre"
    assert written == 2, "seules les impressions en et fr sont entreposées"


def test_les_impressions_restent_bornees_aux_langues_gardees(monkeypatch):
    """Le pendant du test précédent : récolter un nom ne doit **pas** faire
    entrer l'impression. C'est ce qui sépare 8 Mo de 62.

    **Une seule exception, et elle est bornée à l'illustration.** Une œuvre
    qu'aucune impression gardée ne porte serait invisible au scan ; une
    impression est alors retenue pour elle seule. Ici les deux langues partagent
    la même œuvre, donc **une** entre, pas deux — et les noms des deux restent
    récoltés. Voir `test_scryfall_illustrations_orphelines`.
    """
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([payload("de", "Blitzschlag"), payload("ja", "稲妻")]),
    )
    conn = ConnexionFactice()

    written, noms = ingest_prints_and_names(conn, {ORACLE})

    assert written == 1, "une impression par œuvre orpheline, pas une par langue"
    # **Les langues, pas le compte d'entrées.** La récolte porte aussi le nom
    # oracle anglais de chaque impression — `write_search_names` l'écarte
    # ensuite comme répétant celui de `cards`.
    assert {"de", "ja"} <= {lang for _, lang in noms}, (
        "les noms des deux langues sont là, eux"
    )
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
        (ORACLE, "fr"): [("Foudre", "foudre")],
        (ORACLE, "de"): [("Blitzschlag", "blitzschlag")],
        (ORACLE, "ja"): [("稲妻", "稲妻")],
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
    noms = {(ORACLE, "en"): [("Lightning Bolt", "lightning bolt")]}

    write_search_names(conn, {ORACLE: "Lightning Bolt"}, noms)

    assert [row[3] for row in conn.rows] == ["en"]


def test_un_nom_sans_carte_au_catalogue_est_ecarte():
    """Garde-fou de clé étrangère : `card_search_names.oracle_id` référence
    `cards`. Une entrée orpheline ferait échouer l'insertion entière du lot."""
    conn = ConnexionFactice()
    noms = {(AUTRE, "de"): [("Blitzschlag", "blitzschlag")]}

    write_search_names(conn, {ORACLE: "Lightning Bolt"}, noms)

    assert [row[0] for row in conn.rows] == [ORACLE]


# --- les cartes a plusieurs faces -------------------------------------------


def payload_multiface(lang: str, faces: list[tuple[str, str | None]]) -> dict:
    """Une carte recto-verso telle que le *bulk* la publie.

    **`printed_name` est vide a la racine**, et c'est tout le sujet : Scryfall le
    place dans `card_faces`, pour toutes les mises en page a plusieurs faces —
    `split`, `transform`, `adventure`, `modal_dfc`, `flip`.
    """
    base = payload(lang, None)
    base["name"] = " // ".join(nom for nom, _ in faces)
    base["printed_name"] = None
    base["card_faces"] = [
        {"name": nom, "printed_name": imprime} for nom, imprime in faces
    ]
    return base


def test_les_noms_traduits_des_faces_sont_recoltes(monkeypatch):
    """**Le trou constate sur l'appareil.** L'OCR lisait « Transformation » sur
    une carte *split* francaise, et le catalogue ne connaissait pas ce nom :
    aucune carte a plusieurs faces n'y portait de nom traduit. La recolte lisait
    `printed_name` a la racine, vide pour celles-la.

    Mesure du 2026-09-17 : 743 cartes du perimetre ont une traduction francaise
    publiee que nous jetions."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([
            payload_multiface("en", [("Turn", None), ("Burn", None)]),
            payload_multiface(
                "fr", [("Turn", "Transformation"), ("Burn", "Brûlage")]
            ),
        ]),
    )
    conn = ConnexionFactice()

    _, noms = ingest_prints_and_names(conn, {ORACLE})

    recoltes = {
        affiche for entrees in noms.values() for affiche, _ in entrees
    }
    assert "Transformation" in recoltes
    assert "Brûlage" in recoltes


def test_le_nom_complet_et_chaque_face_atteignent_l_index(monkeypatch):
    """Les trois se saisissent : les joueurs disent « Transformation » aussi
    souvent que le nom complet."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([
            payload_multiface(
                "fr", [("Turn", "Transformation"), ("Burn", "Brûlage")]
            ),
        ]),
    )
    conn = ConnexionFactice()
    _, noms = ingest_prints_and_names(conn, {ORACLE})

    conn2 = ConnexionFactice()
    write_search_names(conn2, {ORACLE: "Turn // Burn"}, noms)

    ecrits = {(row[1], row[3]) for row in conn2.rows}
    assert ("Transformation", "fr") in ecrits
    assert ("Brûlage", "fr") in ecrits
    assert ("Turn // Burn", "en") in ecrits


def test_les_faces_anglaises_entrent_aussi(monkeypatch):
    """`backfill_face_names` les ajoutait, mais elle n'est appelee par aucun
    flux : « Turn » et « Burn » ne tenaient en base que d'un rattrapage joue a
    la main une fois. L'ingestion normale doit suffire."""
    monkeypatch.setattr(
        scryfall_ingest,
        "stream_bulk",
        lambda _source: iter([
            payload_multiface("en", [("Turn", None), ("Burn", None)]),
        ]),
    )
    conn = ConnexionFactice()
    _, noms = ingest_prints_and_names(conn, {ORACLE})

    conn2 = ConnexionFactice()
    write_search_names(conn2, {ORACLE: "Turn // Burn"}, noms)

    ecrits = {(row[1], row[3]) for row in conn2.rows}
    assert ("Turn", "en") in ecrits
    assert ("Burn", "en") in ecrits
    assert ("Turn // Burn", "en") in ecrits
