"""La boucle qui relie le chat au classeur.

**Quatre commandes, et toutes en lecture.** `!card <nom>` dit si la carte est
possédée et où ; `!dernieres` ce qui vient d'entrer au classeur ; `!classeur`
l'avancement par extension ; `!deckhand` l'adresse et le crédit. Aucune n'écrit,
et aucune ne le pourra : la porte publique est la clé anonyme, et une commande
qui aurait besoin de la clé de service serait le signal qu'elle n'a rien à faire
dans un chat.

**Ce qui n'y est pas.** La désignation — un spectateur qui ferait afficher une
carte sur l'overlay — attend l'overlay lui-même : ses questions (une file ou une
seule case ? qui a la main quand le diffuseur scanne ?) ne se tranchent que
devant lui.

**La reconnexion est le régime normal.** Twitch coupe une connexion inactive, et
un direct dure des heures : `run` reconnecte plutôt que de s'arrêter, avec une
attente qui double jusqu'à une minute. S'arrêter à la première coupure ferait un
bot qui marche en démonstration et jamais en émission.

**Le fil du bot ne fait rien d'autre.** Un appel réseau par commande, borné à
six secondes, avec le débit tenu par `Throttle` en amont : le pire cas est un
silence de six secondes, pas une file qui gonfle.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable

import httpx

from .irc import ChatMessage, IrcCredentials, channel_name, connect, parse_privmsg
from .locator import Locator
from .reply import (
    format_recent,
    format_reply,
    format_shelf,
    parse_bare_command,
    parse_command,
)
from .throttle import Throttle

logger = logging.getLogger(__name__)

_FIRST_RETRY_SECONDS = 2.0
_MAX_RETRY_SECONDS = 60.0

# **Le crédit est dû à qui regarde, pas à qui ouvre les réglages.** Le garde-fou
# §IV.2 impose une attribution visible partout où des inconnus voient ces
# données ; un chat en fait partie. Elle est annoncée à la connexion plutôt
# qu'accrochée à chaque réponse, qui deviendrait illisible.
ANNOUNCE = (
    "DeckHand lit le classeur — !card <nom> · !dernieres · !classeur · "
    "!deckhand. Cartes, images et prix : Scryfall."
)

# Une reconnexion ne réannonce pas : un réseau instable transformerait le crédit
# en spam, et un spam se fait couper — donc plus de crédit du tout.
_ANNOUNCE_EVERY_SECONDS = 1800.0


class Bot:
    """Le bot, monté par injection pour être jouable sans réseau."""

    def __init__(
        self,
        *,
        locator: Locator,
        channel: str,
        throttle: Throttle | None = None,
        command: str = "!card",
        share_url: str = "",
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.locator = locator
        self.channel = channel_name(channel)
        self.throttle = throttle or Throttle()
        self.command = command
        # Vide tant que rien n'est partagé : `!deckhand` le dit alors, plutôt
        # que d'annoncer une adresse qui ne mènerait nulle part.
        self.share_url = share_url
        self._clock = clock
        self._announced_at: float | None = None

    def announcement(self) -> str | None:
        """Le crédit à publier maintenant, ou `None` s'il est encore à l'écran."""
        now = self._clock()
        if self._announced_at is not None and now - self._announced_at < _ANNOUNCE_EVERY_SECONDS:
            return None
        self._announced_at = now
        return ANNOUNCE

    def answer(self, message: ChatMessage, client: httpx.Client) -> str | None:
        """La réponse à ce message, ou `None` s'il n'y a rien à dire.

        Trois silences : ce n'est pas la commande, elle vient d'un autre canal,
        ou le débit est déjà pris. Aucun ne mérite un message — voir
        `throttle`.
        """
        if message.channel.lower() != self.channel:
            return None

        query = parse_command(message.text, self.command)
        if query is not None:
            if not self.throttle.allows(message.author, query):
                return None
            locations = self.locator.locate(client, query)
            return f"@{message.author} {format_reply(query, locations)}"

        # **Les commandes sans argument passent par le même débit.** La clé de
        # cooldown est leur nom : sans elle, `!classeur` répété dix fois
        # produirait dix réponses identiques là où `!card ka-zar` en produit une.
        for nom, repondre in self._sans_argument.items():
            if not parse_bare_command(message.text, nom):
                continue
            if not self.throttle.allows(message.author, nom):
                return None
            return f"@{message.author} {repondre(client)}"
        return None

    @property
    def _sans_argument(self) -> dict[str, Callable[[httpx.Client], str]]:
        return {
            "!dernieres": lambda client: format_recent(self.locator.recent(client)),
            "!classeur": lambda client: format_shelf(self.locator.shelf(client)),
            "!deckhand": lambda _client: self._adresse(),
        }

    def _adresse(self) -> str:
        """L'adresse du classeur, et le crédit.

        **Aucun appel réseau** : l'adresse est celle qu'on a déjà. Et le crédit
        y figure parce que le §IV.2 veut une attribution visible de qui regarde
        — un spectateur qui tape cette commande n'a pas forcément vu l'annonce
        de connexion, qui ne repasse que toutes les demi-heures.
        """
        if not self.share_url:
            return "classeur non partagé pour l'instant."
        return f"le classeur : {self.share_url} — cartes, images et prix : Scryfall."

    def run(self, credentials: IrcCredentials) -> None:
        """Écoute le chat jusqu'à interruption, en se reconnectant."""
        wait = _FIRST_RETRY_SECONDS
        with httpx.Client() as client:
            while True:
                try:
                    self._session(credentials, client)
                    wait = _FIRST_RETRY_SECONDS
                except KeyboardInterrupt:
                    logger.info("arrêt demandé")
                    return
                except OSError as error:
                    logger.warning("connexion perdue (%s)", error)
                logger.info("reconnexion dans %.0f s", wait)
                time.sleep(wait)
                wait = min(wait * 2, _MAX_RETRY_SECONDS)

    def _session(self, credentials: IrcCredentials, client: httpx.Client) -> None:
        with connect(credentials, self.channel) as connection:
            logger.info("connecté à %s", self.channel)
            credit = self.announcement()
            if credit is not None:
                connection.say(self.channel, credit)
            for line in connection.read_lines():
                message = parse_privmsg(line)
                if message is None:
                    continue
                reply = self.answer(message, client)
                if reply is not None:
                    connection.say(self.channel, reply)
                    logger.info("%s → %s", message.text, reply)
