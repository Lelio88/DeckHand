"""Les trois commandes sans argument, jouées sans réseau (#21).

**Ce que ces tests protègent.** D'abord qu'une commande sans argument se
distingue d'une phrase qui commence par le même mot : `!classeur de mon ami` ne
doit rien déclencher, sans quoi le bot répondrait à des conversations.

Ensuite que le **débit** s'applique à ces commandes comme aux autres. Elles sont
plus tentantes à répéter que `!card` — elles n'ont rien à taper — et une réponse
identique dix fois d'affilée est exactement ce qu'un chat modère.

Et enfin que `!deckhand` ne **prétende pas** partager un classeur qui ne l'est
pas : annoncer une adresse qui ne mène nulle part vaut moins que se taire.
"""

from __future__ import annotations

import httpx

from app.twitch.bot import Bot
from app.twitch.irc import ChatMessage
from app.twitch.locator import Locator
from app.twitch.reply import (
    Addition,
    Shelf,
    format_recent,
    format_shelf,
    parse_bare_command,
)
from app.twitch.throttle import Throttle


class FauxLocator(Locator):
    """Un locator qui ne touche à rien, et qui note ce qu'on lui demande."""

    def __init__(
        self,
        *,
        recentes: list[Addition] | None = None,
        rayonnage: list[Shelf] | None = None,
    ) -> None:
        super().__init__(supabase_url="https://x", anon_key="k", handle="lelio")
        object.__setattr__(self, "_recentes", recentes or [])
        object.__setattr__(self, "_rayonnage", rayonnage or [])
        object.__setattr__(self, "appels", [])

    def recent(self, client: httpx.Client, limit: int = 3) -> list[Addition]:
        self.appels.append("recent")
        return self._recentes

    def shelf(self, client: httpx.Client) -> list[Shelf]:
        self.appels.append("shelf")
        return self._rayonnage


def une_addition(nom: str = "Shuri", numero: str = "75") -> Addition:
    return Addition(
        name="Shuri, Wakandan Inventor",
        printed_name=nom,
        set_code="msh",
        collector_number=numero,
    )


def une_etagere(code: str = "msh", possedees: int = 234, total: int = 453) -> Shelf:
    return Shelf(
        set_code=code,
        set_name="Marvel Super Heroes" if code == "msh" else code.upper(),
        total_cells=total,
        owned_cells=possedees,
    )


class TestReconnaissance:
    def test_la_commande_seule_declenche(self) -> None:
        assert parse_bare_command("!classeur", "!classeur")
        assert parse_bare_command("  !CLASSEUR  ", "!classeur")

    def test_une_phrase_qui_commence_pareil_ne_declenche_pas(self) -> None:
        """**La différence avec `!card`.** Celle-ci exige un argument ; celles-ci
        exigent l'inverse. Sans quoi « !classeur de mon ami est mieux rangé »
        ferait répondre le bot au milieu d'une conversation."""
        assert not parse_bare_command("!classeur de mon ami", "!classeur")
        assert not parse_bare_command("!classeurs", "!classeur")


class TestFormes:
    def test_les_dernieres_montrent_le_nom_imprime(self) -> None:
        """Répondre « Island » à qui vient de voir « Île » donnerait
        l'impression d'une autre carte."""
        phrase = format_recent([une_addition(nom="Île")])
        assert "Île" in phrase
        assert "MSH 75" in phrase

    def test_ce_qui_deborde_est_compte_jamais_tronque(self) -> None:
        phrase = format_recent([une_addition(numero=str(n)) for n in range(6)])
        assert "+3 autres" in phrase

    def test_un_classeur_vide_se_dit_sans_mentir(self) -> None:
        """Rien à montrer et rien de partagé se disent pareil : distinguer
        confirmerait l'existence d'une collection fermée."""
        assert "pas encore partagé" in format_shelf([])
        assert "rien d'ajouté" in format_recent([])

    def test_le_rayonnage_donne_le_compte_par_extension(self) -> None:
        phrase = format_shelf([une_etagere(), une_etagere("ltr", 88, 281)])
        assert "Marvel Super Heroes 234/453" in phrase
        assert "LTR 88/281" in phrase


class TestBot:
    def _bot(self, **kwargs: object) -> Bot:
        defauts: dict[str, object] = {
            "locator": FauxLocator(recentes=[une_addition()], rayonnage=[une_etagere()]),
            "channel": "lelio",
        }
        defauts.update(kwargs)
        return Bot(**defauts)  # type: ignore[arg-type]

    def test_dernieres_repond(self) -> None:
        bot = self._bot()
        reply = bot.answer(ChatMessage("alice", "#lelio", "!dernieres"), httpx.Client())
        assert reply is not None
        assert reply.startswith("@alice")
        assert "Shuri" in reply

    def test_classeur_repond(self) -> None:
        bot = self._bot()
        reply = bot.answer(ChatMessage("alice", "#lelio", "!classeur"), httpx.Client())
        assert reply is not None
        assert "234/453" in reply

    def test_deckhand_ne_touche_pas_au_reseau(self) -> None:
        locator = FauxLocator()
        bot = self._bot(locator=locator, share_url="https://exemple/?c=abc")
        reply = bot.answer(ChatMessage("a", "#lelio", "!deckhand"), httpx.Client())
        assert reply is not None
        assert "https://exemple/?c=abc" in reply
        # §IV.2 : l'attribution doit être visible de qui regarde.
        assert "Scryfall" in reply
        assert locator.appels == []

    def test_deckhand_ne_promet_pas_un_classeur_non_partage(self) -> None:
        bot = self._bot(share_url="")
        reply = bot.answer(ChatMessage("a", "#lelio", "!deckhand"), httpx.Client())
        assert reply is not None
        assert "non partagé" in reply
        assert "http" not in reply

    def test_le_debit_s_applique_aussi_a_ces_commandes(self) -> None:
        """Elles n'ont rien à taper, donc elles se répètent — et une réponse
        identique dix fois d'affilée est ce qu'un chat modère."""
        bot = self._bot(throttle=Throttle(burst=1, window_seconds=60.0))
        assert bot.answer(ChatMessage("a", "#lelio", "!classeur"), httpx.Client())
        assert bot.answer(ChatMessage("b", "#lelio", "!dernieres"), httpx.Client()) is None

    def test_un_autre_canal_ne_declenche_rien(self) -> None:
        bot = self._bot()
        assert bot.answer(ChatMessage("a", "#autre", "!classeur"), httpx.Client()) is None

    def test_card_repond_toujours(self) -> None:
        """**La commande d'origine n'est pas devenue une branche morte.** Le
        routeur essaie `!card` en premier ; une erreur d'ordre l'aurait fait
        tomber dans les commandes sans argument, qui l'auraient ignorée."""
        locator = FauxLocator()
        bot = self._bot(locator=locator)
        reply = bot.answer(
            ChatMessage("a", "#lelio", "!card Ka-Zar"),
            httpx.Client(transport=httpx.MockTransport(lambda _r: httpx.Response(200, json=[]))),
        )
        assert reply is not None
        assert "Ka-Zar" in reply
