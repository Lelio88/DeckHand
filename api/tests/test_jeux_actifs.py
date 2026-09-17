"""Le garde qui empêche un jeu déchargé de revenir par habitude.

**Ce que ces tests protègent** (#48) : cinq catalogues ont été déchargés pour
tenir dans le quota Supabase, et il suffirait de relancer un connecteur par
réflexe pour ramener en quelques minutes les centaines de mégaoctets qu'on vient
de rendre — sans que personne ne fasse le lien avec le passage en lecture seule
qui suivrait.

Le second point protégé est la **réversibilité** : le retrait est temporaire, et
un test vérifie qu'il tient dans une seule ligne. Un garde qu'on ne sait plus
lever est un garde qui devient une décision de produit par inadvertance.
"""

from __future__ import annotations

import re

import pytest

from app.ingestion import jeux_actifs
from app.ingestion.jeux_actifs import (
    JEUX,
    JEUX_ACTIFS,
    JEUX_RETIRES,
    JeuRetire,
    exiger_actif,
    purger,
)


class ConnexionFactice:
    """Retient les requêtes jouées, sans base derrière.

    `possedes` simule ce que `_en_collection` trouve ; `rowcount` reste sous la
    taille de lot pour que la boucle de purge fasse un seul tour par table.
    """

    def __init__(self, possedes: int = 0, rowcount: int = 3) -> None:
        self.requetes: list[tuple[str, tuple]] = []
        self.commits = 0
        self._possedes = possedes
        self._rowcount = rowcount

    def cursor(self):
        conn = self

        class _Curseur:
            rowcount = conn._rowcount

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def execute(self, statement, params=None):
                conn.requetes.append((statement, params))
                self._dernier = statement
                return self

            def fetchone(self):
                return (conn._possedes,)

        return _Curseur()

    def commit(self) -> None:
        self.commits += 1


def deletes(conn: ConnexionFactice) -> list[str]:
    """Les tables visées par un DELETE, dans l'ordre où elles l'ont été.

    **La cible du DELETE, pas une sous-chaîne** : « FROM public.decks » paraît
    aussi dans la sous-requête des trois premières étapes, et un relevé naïf
    désignait la mauvaise.
    """
    vues: list[str] = []
    for requete, _ in conn.requetes:
        trouve = re.search(r"DELETE FROM public\.(\w+)", requete)
        if trouve and (not vues or vues[-1] != trouve.group(1)):
            vues.append(trouve.group(1))
    return vues


# --- le garde ---------------------------------------------------------------


@pytest.mark.parametrize("jeu", JEUX_RETIRES)
def test_un_connecteur_de_jeu_retire_refuse_de_tourner(jeu):
    with pytest.raises(JeuRetire) as leve:
        exiger_actif(jeu)
    assert "#48" in str(leve.value), "le message doit dire où est expliqué le retrait"
    assert "JEUX_RETIRES" in str(leve.value), "et comment le lever"


@pytest.mark.parametrize("jeu", JEUX_ACTIFS)
def test_un_connecteur_de_jeu_servi_passe(jeu):
    exiger_actif(jeu)  # ne lève pas


def test_les_trois_jeux_servis_sont_ceux_qu_on_attend():
    """Magic et Riftbound portent la promesse du produit ; Wankul est ingéré
    sous autorisation nominative et pèse moins d'un mégaoctet."""
    assert JEUX_ACTIFS == ("magic", "riftbound", "wankul")


def test_aucun_jeu_ne_disparait_de_la_liste_complete():
    """`JEUX` reste entier : une préférence enregistrée sur un jeu déchargé doit
    continuer à se lire, et la purge a besoin de savoir qui purger."""
    assert set(JEUX_ACTIFS) | set(JEUX_RETIRES) == set(JEUX)
    assert len(JEUX) == 8


def test_vider_la_liste_des_retires_remet_tout(monkeypatch):
    """**La réversibilité est la raison d'être de ce module** : le retrait tient
    à une ligne, et la lever ne doit rien demander d'autre."""
    monkeypatch.setattr(jeux_actifs, "JEUX_RETIRES", ())
    for jeu in JEUX:
        jeux_actifs.exiger_actif(jeu)  # plus rien ne lève


# --- la purge ---------------------------------------------------------------


def test_la_purge_supprime_les_decks_avant_les_cartes():
    """`deck_cards.oracle_id` et `decks.commander_oracle_id` référencent `cards`
    en `NO ACTION` : supprimer les cartes d'abord échouerait sur la clé
    étrangère. L'ordre n'est donc pas cosmétique."""
    conn = ConnexionFactice()

    purger(conn, ("pokemon",))

    assert deletes(conn) == [
        "deck_profile",
        "deck_needs",
        "deck_cards",
        "decks",
        "cards",
    ]


def test_chaque_lot_est_commite():
    """**Ce qui a coûté une demi-heure.** La première version tenait tout dans
    une transaction ; le DELETE sur `cards` a dépassé le `statement_timeout` de
    deux minutes et le rollback a tout repris. Un commit par lot rend la purge
    reprenable."""
    conn = ConnexionFactice()

    purger(conn, ("pokemon",))

    assert conn.commits >= len(deletes(conn)), "au moins un commit par étape"


def test_une_carte_possedee_arrete_tout_avant_le_premier_delete():
    """**Vérifié avant, pas pendant.** Avec des lots commités, une clé étrangère
    qui casse à mi-chemin laisserait les decks supprimés et les cartes en place.
    Refuser d'entrée est le seul état propre."""
    conn = ConnexionFactice(possedes=4)

    with pytest.raises(RuntimeError, match="collection"):
        purger(conn, ("pokemon",))

    assert deletes(conn) == [], "aucune suppression ne doit avoir eu lieu"
    assert conn.commits == 0


def test_aucune_suppression_ne_nomme_la_collection():
    """**Le garde-fou qui compte.** La purge *lit* la collection pour refuser de
    tourner si elle contient ces jeux — mais aucune de ses suppressions ne doit
    la nommer. Ce test interdit qu'un futur correctif « débloque » la purge en
    vidant la collection plutôt qu'en s'arrêtant : perdre une collection pour
    gagner des mégaoctets serait un mauvais échange."""
    conn = ConnexionFactice()

    purger(conn, ("pokemon",))

    for requete, _ in conn.requetes:
        if requete.lstrip().upper().startswith("DELETE"):
            assert "collection" not in requete


def test_la_purge_ne_touche_que_les_jeux_demandes():
    conn = ConnexionFactice()

    purger(conn, ("pokemon", "yugioh"))

    for _, params in conn.requetes:
        assert params == (["pokemon", "yugioh"],)


def test_une_purge_sans_jeu_ne_joue_rien():
    """Le jour où `JEUX_RETIRES` est vidé, lancer la purge ne doit rien
    supprimer — surtout pas « tous les jeux » par lecture d'un tuple vide."""
    conn = ConnexionFactice()

    assert purger(conn, ()) == {}
    assert conn.requetes == []
    assert conn.commits == 0
