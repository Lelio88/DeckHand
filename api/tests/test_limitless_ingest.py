"""Le connecteur Limitless : la table des sigles, l'aplatissement, la fenêtre."""

from __future__ import annotations

import datetime as dt

import httpx
import psycopg
import pytest

from app.db import Session
from app.ingestion import limitless_ingest
from app.ingestion.limitless_ingest import (
    _get,
    _retry_after,
    deck_cards,
    deck_name,
    parse_date,
    set_abbreviations,
)

TODAY = dt.date(2026, 8, 13)


def _set(id_: str, name: str, day: str, ptcgo: str | None = None) -> dict:
    return {"id": id_, "name": name, "releaseDate": day, "tcgOnline": ptcgo}


def _group(gid: int, name: str, day: str, abbr: str | None = None) -> dict:
    return {"groupId": gid, "name": name, "publishedOn": day, "abbreviation": abbr}


# --- la table des sigles ---------------------------------------------------


def test_le_sigle_tcgplayer_est_retenu():
    sets = [_set("sv06", "Twilight Masquerade", "2024-05-24")]
    groups = [_group(1, "SV06: Twilight Masquerade", "2024-05-24", "TWM")]
    table = set_abbreviations(sets, groups, today=TODAY)
    assert table["TWM"] == "sv06"


def test_le_code_ptcgo_comble_ce_que_tcgplayer_ne_donne_pas():
    sets = [_set("sm2", "Guardians Rising", "2017-05-05", "GRI")]
    groups = [_group(1, "SM02: Guardians Rising", "2017-05-05", None)]
    table = set_abbreviations(sets, groups, today=TODAY)
    assert table["GRI"] == "sm2"


def test_lidentifiant_dextension_sert_de_dernier_recours():
    """« Mega Evolution Energy » n'a pas de groupe TCGplayer, et pèse 6 762 citations."""
    sets = [_set("mee", "Mega Evolution Energy", "2026-06-01")]
    table = set_abbreviations(sets, [], today=TODAY)
    assert table["MEE"] == "mee"


def test_le_premier_gisement_garde_la_cle():
    """Un identifiant générique ne doit pas déloger une abréviation officielle."""
    sets = [
        _set("sv06", "Twilight Masquerade", "2024-05-24"),
        # Une extension dont l'identifiant est justement « TWM ».
        _set("twm", "Autre chose", "2020-01-01"),
    ]
    groups = [_group(1, "SV06: Twilight Masquerade", "2024-05-24", "TWM")]
    table = set_abbreviations(sets, groups, today=TODAY)
    assert table["TWM"] == "sv06"


def test_un_couple_faux_ne_transmet_pas_son_sigle():
    """Le veto par date du rapprochement des prix protège aussi les decks."""
    sets = [_set("base1", "Base Set", "1999-01-09")]
    groups = [_group(7, "SM Base Set", "2017-02-03", "SUM")]
    table = set_abbreviations(sets, groups, today=TODAY)
    assert "SUM" not in table
    assert table["BASE1"] == "base1"  # le dernier recours joue quand même


# --- l'aplatissement d'une decklist ----------------------------------------


def test_les_trois_zones_forment_un_seul_deck():
    liste = {
        "pokemon": [{"count": 4, "set": "TWM", "number": "128", "name": "Dreepy"}],
        "trainer": [{"count": 4, "set": "MEG", "number": "119", "name": "Lillie"}],
        "energy": [{"count": 8, "set": "SVE", "number": "10", "name": "Psychic"}],
    }
    assert deck_cards(liste) == {"TWM-128": 4, "MEG-119": 4, "SVE-10": 8}


def test_une_impression_citee_deux_fois_est_cumulee():
    liste = {
        "pokemon": [
            {"count": 2, "set": "TWM", "number": "128"},
            {"count": 2, "set": "TWM", "number": "128"},
        ]
    }
    assert deck_cards(liste) == {"TWM-128": 4}


def test_une_ligne_sans_extension_ou_sans_quantite_est_ecartee():
    liste = {
        "pokemon": [
            {"count": 4, "set": "", "number": "128"},
            {"count": 0, "set": "TWM", "number": "129"},
            {"count": 3, "set": "TWM", "number": ""},
        ]
    }
    assert deck_cards(liste) == {}


def test_une_decklist_absente_ne_leve_pas():
    assert deck_cards(None) == {}
    assert deck_cards({}) == {}


# --- le nom et la date -----------------------------------------------------


def test_larchetype_nomme_le_deck_quand_la_source_le_donne():
    entry = {"deck": {"id": "dragapult-ex", "name": "Dragapult"}}
    assert deck_name(entry, {"name": "Moscow Play Night"}) == "Dragapult"


def test_a_defaut_darchetype_le_tournoi_nomme_le_deck():
    assert deck_name({"deck": None}, {"name": "Moscow Play Night"}) == (
        "Moscow Play Night"
    )
    assert deck_name({}, {}) == "Deck Limitless"


def test_la_date_est_lue_avec_son_fuseau():
    lu = parse_date("2026-08-13T18:30:00.000Z")
    assert lu == dt.datetime(2026, 8, 13, 18, 30, tzinfo=dt.timezone.utc)
    assert parse_date(None) is None
    assert parse_date("hier") is None


# --- le debit et les reprises ----------------------------------------------


@pytest.fixture(autouse=True)
def _sans_attente(monkeypatch):
    """Les tests mesurent la politique de reprise, pas la patience."""
    monkeypatch.setattr(limitless_ingest.time, "sleep", lambda _s: None)


def _client(reponses: list[httpx.Response]) -> httpx.Client:
    restant = list(reponses)

    def handler(request: httpx.Request) -> httpx.Response:
        if not restant:
            raise AssertionError("plus de reponse : une requete de trop")
        item = restant.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_un_429_est_retente_et_finit_par_passer():
    """Le defaut qui a coupe la fenetre aux deux tiers."""
    client = _client([
        httpx.Response(429),
        httpx.Response(429),
        httpx.Response(200, json={"ok": True}),
    ])
    assert _get(client, "https://exemple/api") == {"ok": True}


def test_un_404_ne_est_pas_retente():
    """La ressource n'existe pas : insister ne la fera pas apparaitre."""
    client = _client([httpx.Response(404)])
    with pytest.raises(httpx.HTTPStatusError):
        _get(client, "https://exemple/api")


def test_une_coupure_reseau_est_retentee():
    client = _client([
        httpx.ConnectError("coupure"),
        httpx.Response(200, json=[1, 2]),
    ])
    assert _get(client, "https://exemple/api") == [1, 2]


def test_un_429_persistant_finit_par_lever():
    client = _client([httpx.Response(429)] * limitless_ingest.ATTEMPTS)
    with pytest.raises(httpx.HTTPStatusError):
        _get(client, "https://exemple/api")


def test_le_retry_after_du_serveur_prime_mais_reste_borne():
    court = httpx.Response(429, headers={"Retry-After": "7"})
    assert _retry_after(court, 2.0) == 7.0
    # Une heure d'attente arreterait l'import aussi surement qu'une exception.
    long = httpx.Response(429, headers={"Retry-After": "3600"})
    assert _retry_after(long, 2.0) == limitless_ingest.MAX_RETRY_AFTER
    # Un en-tete illisible (date HTTP) retombe sur notre propre attente.
    date = httpx.Response(429, headers={"Retry-After": "Wed, 13 Aug 2026 12:00:00 GMT"})
    assert _retry_after(date, 2.0) == 2.0
    assert _retry_after(httpx.Response(429), 2.0) == 2.0


# --- reprendre une course interrompue --------------------------------------


def _t(id_: str, quand: dt.datetime) -> dict:
    return {
        "id": id_,
        "date": quand.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "format": "STANDARD",
    }


def test_la_reprise_saute_ce_qui_est_deja_couvert():
    maintenant = dt.datetime.now(dt.timezone.utc)
    borne = maintenant - dt.timedelta(days=5)
    client = _client([
        httpx.Response(
            200,
            json=[
                _t("recent", maintenant - dt.timedelta(days=1)),  # déjà acquis
                _t("aussi", maintenant - dt.timedelta(days=3)),  # déjà acquis
                _t("neuf", maintenant - dt.timedelta(days=8)),  # à faire
            ],
        ),
        httpx.Response(200, json=[]),
    ])

    vus = [t["id"] for t in limitless_ingest.tournaments(client, days=30, before=borne)]

    assert vus == ["neuf"]


def test_le_tournoi_date_de_la_borne_est_refait():
    """La borne vient d'un deck observé, pas d'un tournoi terminé : celui qui
    porte cette date peut n'avoir été importé qu'à moitié."""
    maintenant = dt.datetime.now(dt.timezone.utc)
    borne = maintenant - dt.timedelta(days=5)
    client = _client([
        httpx.Response(200, json=[_t("pile_dessus", borne)]),
        httpx.Response(200, json=[]),
    ])

    vus = [t["id"] for t in limitless_ingest.tournaments(client, days=30, before=borne)]

    assert vus == ["pile_dessus"]


def test_une_page_entiere_de_deja_vu_narrete_pas_la_pagination():
    """**Le piège de la reprise.** Ces tournois ne sont pas « hors fenêtre » —
    ils sont déjà faits. Les compter comme périmés arrêterait la pagination sur
    la première page et la reprise ne traiterait jamais rien."""
    maintenant = dt.datetime.now(dt.timezone.utc)
    borne = maintenant - dt.timedelta(days=5)
    client = _client([
        httpx.Response(200, json=[_t("deja", maintenant - dt.timedelta(days=1))]),
        httpx.Response(200, json=[_t("neuf", maintenant - dt.timedelta(days=8))]),
        httpx.Response(200, json=[]),
    ])

    vus = [t["id"] for t in limitless_ingest.tournaments(client, days=30, before=borne)]

    assert vus == ["neuf"]


def test_une_borne_sans_fuseau_est_lue_en_utc():
    """Lue dans le fuseau du poste, elle décalerait de deux heures — assez pour
    sauter les tournois d'une soirée sans que rien ne le signale."""
    assert limitless_ingest.parse_before("2026-08-08") == dt.datetime(
        2026, 8, 8, tzinfo=dt.timezone.utc
    )
    assert limitless_ingest.parse_before("2026-08-08T17:00") == dt.datetime(
        2026, 8, 8, 17, 0, tzinfo=dt.timezone.utc
    )


# --- la reprise quand c'est la base qui coupe ------------------------------


class ConnexionFactice:
    """Ce que l'unité reçoit. Elle ne lui fait rien écrire : `store_deck` et
    `store_standings` sont remplacés là où le test porte sur l'autre."""

    def __init__(self) -> None:
        self.commits = 0

    def commit(self) -> None:
        self.commits += 1


def _une_page_avec_un_tournoi(standings: list[dict]) -> list[httpx.Response]:
    """Les quatre réponses d'une fenêtre à un seul tournoi, dans l'ordre.

    La date est relative au jour du test : figée, elle sortirait de la fenêtre
    de trente jours au bout d'un mois et ferait échouer le test sans qu'aucun
    code n'ait bougé.
    """
    hier = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)
    return [
        httpx.Response(
            200,
            json=[
                {
                    "id": "T1",
                    "date": hier.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                    "format": "STANDARD",
                }
            ],
        ),
        httpx.Response(200, json={"decklists": True}),
        httpx.Response(200, json=standings),
        httpx.Response(200, json=[]),  # page 2 vide : fin de la pagination
    ]


def test_un_tournoi_rejoue_apres_coupure_ne_compte_pas_ses_decks_deux_fois():
    """**Le défaut que la reprise pourrait introduire.** Rejouer l'écriture est
    sans danger — `store_deck` est idempotente — mais un compteur muté dans
    l'unité, lui, compterait deux fois, et le rapport annoncerait des decks qui
    n'existent pas."""
    appels: list[str] = []

    def faux_store(conn, standings, **kwargs):
        appels.append(kwargs["tournament_id"])
        if len(appels) == 1:
            raise psycopg.OperationalError("server closed the connection unexpectedly")
        return (2, 1)

    session = Session(
        "postgresql://factice",
        connect=lambda: ConnexionFactice(),
        sleep=lambda _s: None,
    )
    client = _client(_une_page_avec_un_tournoi([{"placing": 1, "decklist": {}}]))

    original = limitless_ingest.store_standings
    limitless_ingest.store_standings = faux_store
    try:
        report = limitless_ingest.ingest(session, client, {}, days=30)
    finally:
        limitless_ingest.store_standings = original

    assert appels == ["T1", "T1"]  # rejoué une fois
    assert report.inserted == 2  # et non 4
    assert report.skipped_incomplete == 1
    assert session.recoveries == 1
    # `_client` lève « une requete de trop » si une requête est refaite : le
    # téléchargement du tournoi reste donc bien hors de l'unité rejouée.


def test_les_decks_dun_tournoi_sont_commites_avec_lui():
    """La maille du commit doit être celle de la reprise : ce qui n'est pas
    commité part avec la connexion morte et ne sera pas retrouvé."""
    verdicts = iter([True, False, True])

    original = limitless_ingest.store_deck
    limitless_ingest.store_deck = lambda conn, **kw: next(verdicts)
    conn = ConnexionFactice()
    try:
        inserted, skipped = limitless_ingest.store_standings(
            conn,
            [
                {"placing": 1, "decklist": {"pokemon": [{"count": 4, "set": "TWM", "number": "1"}]}},
                {"placing": 2, "decklist": {"pokemon": [{"count": 4, "set": "TWM", "number": "2"}]}},
                {"placing": 3, "decklist": {"pokemon": [{"count": 4, "set": "TWM", "number": "3"}]}},
                # Sans liste : ignorée, et ne compte comme rien du tout.
                {"placing": 4, "decklist": None},
            ],
            tournament={"name": "Regional"},
            tournament_id="T1",
            db_format="standard",
            recorded_at=None,
            resolver=None,
        )
    finally:
        limitless_ingest.store_deck = original

    assert (inserted, skipped) == (2, 1)
    assert conn.commits == 1
