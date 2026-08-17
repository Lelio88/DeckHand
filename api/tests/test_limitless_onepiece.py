"""Le connecteur de decks One Piece, sur des réponses figées.

Aucun appel réseau : ce qui est éprouvé ici est la lecture d'une liste, et elle
se lit sur une réponse en dur. Les trois pièges que le banc a trouvés ont chacun
leur test — un `leader` qui n'est pas une liste, un code reconstitué en deux
morceaux, un deck tronqué qui ne doit pas entrer.
"""

from __future__ import annotations

import datetime as dt

from app.ingestion.limitless_onepiece_ingest import (
    MIN_MAIN_CARDS,
    boards,
    code_of,
    deck_name,
    parse_date,
)


def liste_type() -> dict:
    """Une decklist telle que la source la publie."""
    return {
        "leader": {"name": "Dracule Mihawk", "set": "OP14", "number": "020"},
        "character": [
            {"count": 4, "name": "Otama", "set": "OP07", "number": "022"},
            {"count": 2, "name": "Brook", "set": "OP01", "number": "030"},
        ],
        "event": [
            {"count": 4, "name": "You Can Be My Samurai!!", "set": "OP01", "number": "055"},
        ],
        "stage": [
            {"count": 2, "name": "Coffin Boat", "set": "OP14", "number": "039"},
        ],
    }


def test_le_leader_sort_a_part_et_ne_compte_pas():
    """Le piège central : `leader` est un objet, pas une liste comptée.

    S'il entrait dans le principal, tout deck ferait 51 cartes et le gabarit
    mesuré à 50 rejetterait le corpus entier.
    """
    principal, chef = boards(liste_type())

    assert chef == "OP14-020"
    assert "OP14-020" not in principal
    assert sum(principal.values()) == 12


def test_les_trois_zones_fusionnent():
    """Trois rubriques d'un même deck, pas trois zones de jeu disjointes."""
    principal, _ = boards(liste_type())

    assert principal == {
        "OP07-022": 4,
        "OP01-030": 2,
        "OP01-055": 4,
        "OP14-039": 2,
    }


def test_une_impression_citee_deux_fois_cumule():
    principal, _ = boards(
        {
            "character": [
                {"count": 2, "name": "Otama", "set": "OP07", "number": "022"},
                {"count": 2, "name": "Otama", "set": "OP07", "number": "022"},
            ]
        }
    )

    assert principal == {"OP07-022": 4}


def test_un_leader_absent_ne_leve_pas():
    """Une liste sans leader existe — un deck en cours de saisie, par exemple."""
    principal, chef = boards({"character": [{"count": 4, "set": "OP07", "number": "022"}]})

    assert chef is None
    assert principal == {"OP07-022": 4}


def test_un_leader_publie_comme_une_liste_ne_casse_rien():
    """La forme inattendue est ignorée, elle ne fait pas tomber la course.

    C'est la symétrique du défaut trouvé au banc : là, une liste attendue là où
    la source publiait un objet ; ici, un objet attendu là où la source
    publierait une liste. Le connecteur doit traverser les deux.
    """
    principal, chef = boards(
        {
            "leader": [{"name": "Mihawk", "set": "OP14", "number": "020"}],
            "character": [{"count": 4, "set": "OP07", "number": "022"}],
        }
    )

    assert chef is None
    assert principal == {"OP07-022": 4}


def test_une_entree_sans_code_est_ecartee():
    principal, _ = boards(
        {
            "character": [
                {"count": 4, "name": "Sans extension", "number": "022"},
                {"count": 4, "name": "Sans numéro", "set": "OP07"},
                {"count": 0, "name": "Zéro exemplaire", "set": "OP07", "number": "023"},
            ]
        }
    )

    assert principal == {}


def test_le_code_se_reconstitue_en_deux_morceaux():
    assert code_of({"set": "OP07", "number": "022"}) == "OP07-022"
    assert code_of({"set": "op07", "number": "022"}) == "OP07-022"
    assert code_of({"set": " OP07 ", "number": " 022 "}) == "OP07-022"
    assert code_of({"set": "", "number": "022"}) is None
    assert code_of({"set": "OP07"}) is None


def test_une_liste_vide_rend_un_deck_vide():
    assert boards(None) == ({}, None)
    assert boards({}) == ({}, None)


def test_le_nom_prefere_l_archetype_au_tournoi():
    tournoi = {"name": "PHOENIX LA PLATA ONE PIECE 17°"}

    assert deck_name({"deck": {"name": "Purple Luffy"}}, tournoi) == "Purple Luffy"
    assert deck_name({}, tournoi) == "PHOENIX LA PLATA ONE PIECE 17°"
    assert deck_name({"deck": {}}, {}) == "Deck Limitless"


def test_le_plancher_est_sous_le_gabarit_sans_le_toucher():
    """40 cartes : assez bas pour laisser passer un deck amputé de ses codes
    manquants, assez haut pour écarter une liste tronquée.

    Le corpus est exceptionnellement net — 50 de médiane, écart interquartile 0
    sur 827 listes — donc le plancher ne doit surtout pas valoir 50 : 11 % des
    lignes ne se résolvent pas, et un deck en perdant trois serait rejeté alors
    qu'il est parfaitement réel.
    """
    assert MIN_MAIN_CARDS < 50
    assert MIN_MAIN_CARDS > 30


def test_les_dates_de_la_source_se_lisent():
    lu = parse_date("2026-08-17T17:00:00.000Z")

    assert lu is not None
    assert lu.year == 2026 and lu.month == 8 and lu.day == 17
    assert lu.tzinfo == dt.timezone.utc
    assert parse_date(None) is None
    assert parse_date("pas une date") is None
