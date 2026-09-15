"""Ce que le rafraîchissement enchaîne, et ce qu'il ne garde pas ouvert.

Aucun réseau, aucune base : les imports sont remplacés par des fonctions qui
notent leur passage, et chaque connexion est factice.
"""

from __future__ import annotations

from app.db import Session
from app.ingestion import refresh
from app.vision import index_builder
from app.vision.index_builder import BuildReport


class Curseur:
    def __init__(self, conn: "ConnexionFactice") -> None:
        self.conn = conn
        self.rowcount = 0
        self._rows: list[tuple] = []

    def __enter__(self) -> "Curseur":
        return self

    def __exit__(self, *_) -> bool:
        return False

    def execute(self, query: str, params: tuple = ()) -> "Curseur":
        self.conn.requetes.append((query, params))
        self._rows = [(self.conn.compte,)] if "count(*)" in query else []
        return self

    def fetchall(self) -> list[tuple]:
        return self._rows

    def fetchone(self) -> tuple | None:
        return self._rows[0] if self._rows else None


class ConnexionFactice:
    """Retient ses requêtes ; répond `compte` à tout `count(*)`, rien au reste."""

    def __init__(self, compte: int = 0) -> None:
        self.compte = compte
        self.requetes: list[tuple[str, tuple]] = []

    def cursor(self) -> Curseur:
        return Curseur(self)

    def commit(self) -> None:
        pass

    def close(self) -> None:
        pass


class DbFactice:
    """Joue chaque unité sur une connexion neuve, et note le passage au journal."""

    def __init__(self, journal: list[str], compte: int = 0) -> None:
        self.journal = journal
        self.compte = compte
        self.connexions: list[ConnexionFactice] = []

    def __call__(self, unit):
        conn = ConnexionFactice(self.compte)
        self.connexions.append(conn)
        self.journal.append("unité")
        return unit(conn)

    def consignes(self) -> list[tuple]:
        return [
            params
            for conn in self.connexions
            for query, params in conn.requetes
            if "INSERT INTO public.ingestion_state" in query
        ]


def test_les_empreintes_se_calculent_dans_une_session():
    """**La régression qui cassait l'étape à chaque passage** : `build` attend
    une `Session` et recevait une connexion nue — `'Connection' object has no
    attribute 'run'`."""
    conn = ConnexionFactice()
    session = Session("postgresql://factice", connect=lambda: conn)

    assert refresh.refresh_art_hashes(session) == 0
    # La propagation passe même quand rien n'est à calculer.
    assert any("INSERT INTO public.art_hashes" in query for query, _ in conn.requetes)


def test_des_empreintes_calculees_consignent_le_total_de_l_index(monkeypatch):
    conn = ConnexionFactice(compte=51741)
    monkeypatch.setattr(index_builder, "build", lambda session: BuildReport(hashed=9))
    session = Session("postgresql://factice", connect=lambda: conn)

    assert refresh.refresh_art_hashes(session) == 9
    consignes = [
        params
        for query, params in conn.requetes
        if "INSERT INTO public.ingestion_state" in query
    ]
    assert consignes == [("art_hashes", None, 51741, None)]


def test_le_catalogue_consigne_sur_une_connexion_ouverte_apres_l_ingestion(monkeypatch):
    """**Aucune connexion n'attend pendant l'ingestion** : celle qui consigne la
    version s'ouvre une fois l'ingestion finie, pas avant."""
    journal: list[str] = []
    monkeypatch.setattr(refresh, "_scryfall_version", lambda: "2026-09-16T09:00")
    monkeypatch.setattr(refresh.scryfall_sets, "run", lambda conn: 812)
    monkeypatch.setattr(refresh.scryfall_ingest, "run", lambda: journal.append("ingestion"))
    db = DbFactice(journal, compte=38797)

    assert refresh.refresh_catalogue(db) is True
    assert journal == ["unité", "unité", "ingestion", "unité"]
    assert db.consignes() == [("scryfall", "2026-09-16T09:00", 38797, None)]


def test_chaque_import_de_decks_consigne_sur_une_connexion_ouverte_apres_lui(monkeypatch):
    journal: list[str] = []
    monkeypatch.setattr(refresh.topdeck_ingest, "run", lambda days: journal.append("topdeck"))
    monkeypatch.setattr(refresh.mtgjson_ingest, "run", lambda: journal.append("mtgjson"))
    db = DbFactice(journal, compte=190)

    refresh.refresh_decks(db, days=30)

    assert journal == ["topdeck", "unité", "mtgjson", "unité"]
    assert db.consignes() == [("topdeck", "30j", 190, None), ("mtgjson", None, 190, None)]


def test_un_import_en_panne_est_consigne_sans_priver_l_autre(monkeypatch):
    journal: list[str] = []

    def en_panne(days: int) -> None:
        raise RuntimeError("TopDeck injoignable")

    monkeypatch.setattr(refresh.topdeck_ingest, "run", en_panne)
    monkeypatch.setattr(refresh.mtgjson_ingest, "run", lambda: journal.append("mtgjson"))
    db = DbFactice(journal, compte=190)

    refresh.refresh_decks(db, days=30)

    assert db.consignes() == [
        ("topdeck", None, 0, "TopDeck injoignable"),
        ("mtgjson", None, 190, None),
    ]
