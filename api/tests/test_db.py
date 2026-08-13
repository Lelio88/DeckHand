"""La session qui survit à une coupure : ce qu'elle rejoue, et ce qu'elle laisse passer."""

from __future__ import annotations

import psycopg
import pytest

from app.db import Session


class FakeConnection:
    """Connexion de test. Retient si elle a été fermée."""

    def __init__(self, rang: int) -> None:
        self.rang = rang
        self.closed = False

    def close(self) -> None:
        self.closed = True


class FakeConnector:
    """Fabrique de connexions. Peut refuser les premières ouvertures."""

    def __init__(self, ouvertures_refusees: int = 0) -> None:
        self.ouvertes: list[FakeConnection] = []
        self.refus_restants = ouvertures_refusees
        self.tentatives = 0

    def __call__(self) -> FakeConnection:
        self.tentatives += 1
        if self.refus_restants > 0:
            self.refus_restants -= 1
            raise psycopg.OperationalError("serveur injoignable")
        conn = FakeConnection(len(self.ouvertes) + 1)
        self.ouvertes.append(conn)
        return conn


class Horloge:
    """Remplace `time.sleep` : retient les attentes au lieu de les subir."""

    def __init__(self) -> None:
        self.attentes: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.attentes.append(seconds)


def _session(connector: FakeConnector, horloge: Horloge, **kwargs) -> Session:
    return Session(
        "postgresql://fake",
        connect=connector,
        sleep=horloge,
        first_delay=2.0,
        **kwargs,
    )


def test_lunite_est_jouee_et_sa_valeur_rendue():
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)

    resultat = session.run(lambda conn: f"joue sur {conn.rang}")

    assert resultat == "joue sur 1"
    assert len(connector.ouvertes) == 1
    assert horloge.attentes == []


def test_la_connexion_est_reutilisee_dune_unite_a_lautre():
    """Une session ne rouvre pas à chaque unité : la coupure est l'exception."""
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)

    session.run(lambda conn: None)
    session.run(lambda conn: None)

    assert len(connector.ouvertes) == 1


def test_une_coupure_est_encaissee_et_lunite_rejouee():
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)
    vues: list[int] = []

    def unite(conn: FakeConnection) -> str:
        vues.append(conn.rang)
        if len(vues) == 1:
            raise psycopg.OperationalError("server closed the connection unexpectedly")
        return "abouti"

    assert session.run(unite) == "abouti"
    # Rejouée sur une connexion neuve, pas sur la morte.
    assert vues == [1, 2]
    assert len(connector.ouvertes) == 2
    assert horloge.attentes == [2.0]


def test_la_connexion_morte_est_fermee_avant_den_ouvrir_une_neuve():
    """Sans cela, chaque coupure laisserait une connexion pendante côté serveur."""
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)
    premier = True

    def unite(conn: FakeConnection) -> None:
        nonlocal premier
        if premier:
            premier = False
            raise psycopg.OperationalError("coupure")

    session.run(unite)

    assert connector.ouvertes[0].closed is True
    assert connector.ouvertes[1].closed is False


def test_une_connexion_deja_fermee_compte_comme_une_coupure():
    """psycopg lève InterfaceError, non OperationalError, sur une connexion close."""
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)
    essais = 0

    def unite(conn: FakeConnection) -> str:
        nonlocal essais
        essais += 1
        if essais == 1:
            raise psycopg.InterfaceError("the connection is closed")
        return "abouti"

    assert session.run(unite) == "abouti"


def test_une_erreur_de_programmation_ne_declenche_aucun_rejeu():
    """**Le garde-fou du correctif.** Rejouer une faute de SQL la masquerait en
    la répétant cinq fois, et la ferait passer pour une instabilité réseau."""
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)
    essais = 0

    def unite(conn: FakeConnection) -> None:
        nonlocal essais
        essais += 1
        raise psycopg.ProgrammingError('column "trucmuche" does not exist')

    with pytest.raises(psycopg.ProgrammingError):
        session.run(unite)

    assert essais == 1
    assert len(connector.ouvertes) == 1
    assert horloge.attentes == []


def test_une_erreur_du_code_appelant_remonte_intacte():
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)

    def unite(conn: FakeConnection) -> None:
        raise ValueError("sigle inconnu")

    with pytest.raises(ValueError, match="sigle inconnu"):
        session.run(unite)


def test_les_tentatives_sont_bornees_et_la_coupure_finit_par_remonter():
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge, attempts=3)

    def unite(conn: FakeConnection) -> None:
        raise psycopg.OperationalError("coupure sans fin")

    with pytest.raises(psycopg.OperationalError):
        session.run(unite)

    assert len(connector.ouvertes) == 3
    # Attente doublée entre les tours, aucune après le dernier.
    assert horloge.attentes == [2.0, 4.0]


def test_une_base_injoignable_est_reessayee_puis_remonte():
    """La coupure peut aussi frapper la réouverture ; elle compte comme un tour."""
    connector = FakeConnector(ouvertures_refusees=99)
    session = _session(connector, Horloge(), attempts=3)

    with pytest.raises(psycopg.OperationalError):
        session.run(lambda conn: None)

    assert connector.tentatives == 3


def test_une_base_momentanement_injoignable_finit_par_repondre():
    connector, horloge = FakeConnector(ouvertures_refusees=2), Horloge()
    session = _session(connector, horloge, attempts=5)

    assert session.run(lambda conn: "abouti") == "abouti"
    assert horloge.attentes == [2.0, 4.0]


def test_le_compte_des_reprises_est_expose():
    """Une ingestion doit pouvoir dire combien de coupures elle a encaissées :
    silencieuses, elles feraient passer une base instable pour une base saine."""
    connector, horloge = FakeConnector(), Horloge()
    session = _session(connector, horloge)
    essais = 0

    def unite(conn: FakeConnection) -> None:
        nonlocal essais
        essais += 1
        if essais <= 2:
            raise psycopg.OperationalError("coupure")

    session.run(unite)

    assert session.recoveries == 2


def test_la_fermeture_est_sans_effet_si_rien_na_ete_ouvert():
    connector = FakeConnector()
    session = _session(connector, Horloge())

    session.close()

    assert connector.ouvertes == []


def test_la_session_sert_de_gestionnaire_de_contexte():
    connector, horloge = FakeConnector(), Horloge()

    with _session(connector, horloge) as session:
        session.run(lambda conn: None)

    assert connector.ouvertes[0].closed is True
