"""Le protocole IRC et la boucle, joués sans réseau.

**Ce que ces tests protègent.** D'abord qu'un `PING` reçoive son `PONG` : sans
lui, Twitch raccroche au bout de cinq minutes et le bot meurt en direct sans
message d'erreur. Ensuite qu'un message venu d'un autre canal ne déclenche
rien — un bot présent sur deux canaux répondrait sinon dans le mauvais.

Et enfin qu'une **panne réseau se taise comme une carte absente** : un direct
n'est pas un endroit où afficher une trace d'exception.
"""

from __future__ import annotations

import json

import httpx
import pytest

from app.twitch.bot import Bot
from app.twitch.irc import ChatMessage, IrcConnection, parse_privmsg
from app.twitch.locator import Locator
from app.twitch.reply import Location
from app.twitch.throttle import Throttle


class FakeSocket:
    """Un socket qui rend ce qu'on lui a donné, et retient ce qu'on lui envoie."""

    def __init__(self, chunks: list[bytes]) -> None:
        self.chunks = list(chunks)
        self.sent: list[bytes] = []

    def recv(self, _size: int) -> bytes:
        return self.chunks.pop(0) if self.chunks else b""

    def sendall(self, data: bytes) -> None:
        self.sent.append(data)

    def close(self) -> None:
        pass


class FakeLocator(Locator):
    """Le classeur, sans base."""

    def __init__(self, rows: list[Location] | None = None, boom: bool = False) -> None:
        super().__init__(supabase_url="https://x", anon_key="k", handle="lelio")
        object.__setattr__(self, "rows", rows or [])
        object.__setattr__(self, "boom", boom)

    def locate(self, client: httpx.Client, query: str) -> list[Location]:
        if self.boom:  # type: ignore[attr-defined]
            raise AssertionError("locate ne doit pas être appelée")
        return list(self.rows)  # type: ignore[attr-defined]


def a_place() -> Location:
    return Location.from_row(
        {
            "name": "Ka-Zar of the Savage Land",
            "matched_name": "Ka-Zar of the Savage Land",
            "set_name": "Marvel Super Heroes",
            "collector_number": "174",
            "page": 20,
            "slot": 3,
            "copies": 1,
            "has_foil": False,
        }
    )


class TestParsePrivmsg:
    def test_une_ligne_de_chat_donne_son_auteur_et_son_texte(self) -> None:
        line = ":alice!alice@alice.tmi.twitch.tv PRIVMSG #lelio :!card Ka-Zar"
        assert parse_privmsg(line) == ChatMessage("alice", "#lelio", "!card Ka-Zar")

    def test_un_texte_a_deux_points_reste_entier(self) -> None:
        line = ":bob!bob@bob.tmi.twitch.tv PRIVMSG #lelio :!card Jace: le sculpteur"
        message = parse_privmsg(line)
        assert message is not None
        assert message.text == "!card Jace: le sculpteur"

    @pytest.mark.parametrize(
        "line",
        [
            ":tmi.twitch.tv 001 deckhandbot :Welcome, GLHF!",
            ":alice!alice@alice.tmi.twitch.tv JOIN #lelio",
            "PING :tmi.twitch.tv",
            "",
        ],
    )
    def test_le_trafic_de_service_ne_dit_rien(self, line: str) -> None:
        assert parse_privmsg(line) is None


class TestIrcConnection:
    def test_le_ping_recoit_son_pong_sans_remonter(self) -> None:
        # Sans PONG, Twitch raccroche au bout de cinq minutes.
        socket = FakeSocket([b"PING :tmi.twitch.tv\r\n:a!a@a PRIVMSG #c :salut\r\n"])
        lines = list(IrcConnection(socket).read_lines())
        assert socket.sent == [b"PONG :tmi.twitch.tv\r\n"]
        assert lines == [":a!a@a PRIVMSG #c :salut"]

    def test_une_ligne_coupee_en_deux_paquets_se_recolle(self) -> None:
        socket = FakeSocket([b":a!a@a PRIVMSG #c :sa", b"lut\r\n"])
        assert list(IrcConnection(socket).read_lines()) == [":a!a@a PRIVMSG #c :salut"]

    def test_un_retour_a_la_ligne_ne_peut_pas_forger_une_commande(self) -> None:
        socket = FakeSocket([])
        IrcConnection(socket).say("#c", "salut\r\nQUIT :bye")
        assert socket.sent == [b"PRIVMSG #c :salut QUIT :bye\r\n"]

    def test_une_phrase_trop_longue_est_coupee_avant_le_serveur(self) -> None:
        socket = FakeSocket([])
        IrcConnection(socket).say("#c", "x" * 900)
        assert len(socket.sent[0]) < 520


class TestBot:
    def test_la_commande_recoit_sa_localisation(self) -> None:
        bot = Bot(locator=FakeLocator([a_place()]), channel="lelio")
        reply = bot.answer(ChatMessage("alice", "#lelio", "!card Ka-Zar"), httpx.Client())
        assert reply is not None
        assert reply.startswith("@alice Ka-Zar of the Savage Land — Marvel Super Heroes #174")

    def test_le_canal_donne_sans_diese_est_le_meme(self) -> None:
        bot = Bot(locator=FakeLocator([a_place()]), channel="#LELIO")
        assert bot.answer(ChatMessage("a", "#lelio", "!card x"), httpx.Client()) is not None

    def test_un_autre_canal_ne_declenche_rien(self) -> None:
        bot = Bot(locator=FakeLocator(boom=True), channel="lelio")
        assert bot.answer(ChatMessage("a", "#autre", "!card x"), httpx.Client()) is None

    def test_une_phrase_ordinaire_n_appelle_pas_la_base(self) -> None:
        # Le classeur explose si on l'interroge : c'est l'assertion.
        bot = Bot(locator=FakeLocator(boom=True), channel="lelio")
        assert bot.answer(ChatMessage("a", "#lelio", "belle carte !"), httpx.Client()) is None

    def test_le_debit_epuise_se_tait_au_lieu_de_le_dire(self) -> None:
        # Répondre « trop de commandes » consomme la ressource qu'on protège.
        bot = Bot(
            locator=FakeLocator([a_place()]),
            channel="lelio",
            throttle=Throttle(clock=lambda: 0.0, burst=1),
        )
        assert bot.answer(ChatMessage("a", "#lelio", "!card x"), httpx.Client()) is not None
        assert bot.answer(ChatMessage("b", "#lelio", "!card y"), httpx.Client()) is None

    def test_une_base_muette_se_dit_comme_une_carte_absente(self) -> None:
        transport = httpx.MockTransport(lambda _request: httpx.Response(500))
        locator = Locator(supabase_url="https://x", anon_key="k", handle="lelio")
        bot = Bot(locator=locator, channel="lelio")
        with httpx.Client(transport=transport) as client:
            reply = bot.answer(ChatMessage("a", "#lelio", "!card Ka-Zar"), client)
        assert reply == "@a « Ka-Zar » : pas dans le classeur."

    def test_le_credit_est_annonce_a_qui_regarde(self) -> None:
        # Garde-fou §IV.2 : l'attribution doit être visible partout où des
        # inconnus voient ces données, et un chat en fait partie.
        bot = Bot(locator=FakeLocator(), channel="lelio")
        credit = bot.announcement()
        assert credit is not None
        assert "Scryfall" in credit

    def test_une_reconnexion_ne_transforme_pas_le_credit_en_spam(self) -> None:
        # Un réseau instable ferait couper le bot, donc plus de crédit du tout.
        now = [0.0]
        bot = Bot(locator=FakeLocator(), channel="lelio", clock=lambda: now[0])
        assert bot.announcement() is not None
        now[0] = 60.0
        assert bot.announcement() is None
        now[0] = 3600.0
        assert bot.announcement() is not None

    def test_le_bot_lit_par_la_porte_publique(self) -> None:
        # La clé de service ferait de ce chemin un contournement de la portée
        # choisie dans l'écran de partage.
        seen: dict[str, object] = {}

        def capture(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["apikey"] = request.headers.get("apikey")
            seen["body"] = json.loads(request.content)
            return httpx.Response(200, json=[])

        locator = Locator(supabase_url="https://x", anon_key="anon-key", handle="lelio")
        with httpx.Client(transport=httpx.MockTransport(capture)) as client:
            locator.locate(client, "Ka-Zar")

        assert seen["url"] == "https://x/rest/v1/rpc/binder_locate"
        assert seen["apikey"] == "anon-key"
        assert seen["body"] == {"p_handle": "lelio", "p_query": "Ka-Zar", "p_game": "magic"}
