"""Le garde-fou de fraîcheur des profils de decks.

**Ce qu'il protège n'a pas d'autre alarme.** Des profils périmés ne lèvent rien :
`deck_suggestions` répond vite, et sur l'état de la veille. L'écran a l'air sain,
les chiffres sont faux. Il n'existe aucun point de passage où accrocher la
reconstruction — `deck_ingest.store_deck` s'appelle par deck, les prix n'ont pas
d'écrivain commun, et dix connecteurs n'inscrivent rien dans `ingestion_state` —
alors faute de garantir qu'elle sera lancée, on garantit qu'on saura qu'elle
manque.

La détection ne demande de mémoire à personne : elle compare le nombre de decks
à celui des profils, et la date de la dernière ingestion à celle de la dernière
reconstruction.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.ingestion.deck_profile import perime

JADIS = datetime(2026, 9, 15, 20, 0, tzinfo=timezone.utc)
NAGUERE = JADIS + timedelta(hours=2)


class FauxCurseur:
    """Rend une seule ligne, celle que `ETAT` produirait."""

    def __init__(self, ligne):
        self._ligne = ligne
        self.requetes: list[str] = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, requete, params=None):
        self.requetes.append(requete)
        return self

    def fetchone(self):
        return self._ligne


class FausseConnexion:
    def __init__(self, ligne):
        self.curseur = FauxCurseur(ligne)

    def cursor(self):
        return self.curseur


def etat(*, decks, profils, construit, derniere):
    return FausseConnexion((decks, profils, construit, derniere))


def test_jamais_construit_est_une_raison():
    conn = etat(decks=100, profils=0, construit=None, derniere=JADIS)
    assert perime(conn) == ["les profils n'ont jamais été construits"]


def test_tout_a_jour_ne_dit_rien():
    # Le cas courant, et celui qui doit coûter trente millisecondes : aucune
    # raison, donc aucune reconstruction de deux minutes.
    conn = etat(decks=39092, profils=39092, construit=NAGUERE, derniere=JADIS)
    assert perime(conn) == []


def test_des_decks_sont_entres():
    # **Le signal qui ne demande rien à personne.** Un connecteur qui n'inscrit
    # rien dans `ingestion_state` — il y en a dix — change quand même ce compte.
    conn = etat(decks=39200, profils=39092, construit=NAGUERE, derniere=JADIS)
    raisons = perime(conn)
    assert len(raisons) == 1
    assert "39200 decks pour 39092 profils" in raisons[0]


def test_des_decks_sont_sortis():
    # L'écart se lit dans les deux sens : un deck retiré laisse un profil
    # orphelin, et les suggestions le proposeraient encore.
    conn = etat(decks=39000, profils=39092, construit=NAGUERE, derniere=JADIS)
    assert perime(conn) != []


def test_une_source_a_tourne_depuis():
    # Les prix bougent sans changer le nombre de decks — c'est pour eux que la
    # comparaison de dates existe.
    conn = etat(
        decks=39092, profils=39092, construit=JADIS, derniere=NAGUERE
    )
    raisons = perime(conn)
    assert len(raisons) == 1
    assert "une source a tourné depuis" in raisons[0]


def test_les_deux_raisons_se_cumulent():
    conn = etat(decks=39200, profils=39092, construit=JADIS, derniere=NAGUERE)
    assert len(perime(conn)) == 2


def test_une_base_sans_aucune_ingestion_ne_perime_rien():
    # `derniere` nulle veut dire qu'aucune source n'a jamais tourné. Comparer une
    # date à rien renverrait une exception ; ici, il n'y a simplement rien à
    # reprocher aux profils.
    conn = etat(decks=0, profils=0, construit=NAGUERE, derniere=None)
    assert perime(conn) == []
