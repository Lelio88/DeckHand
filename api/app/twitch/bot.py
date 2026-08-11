"""La boucle qui relie le chat au classeur.

**Une commande, et c'est délibéré.** `!card <nom>` dit si la carte est possédée
et où. La désignation — un spectateur qui ferait afficher une carte sur
l'overlay — est repoussée, pas refusée : ce sera un petit ajout une fois
l'overlay en place, et la décision sera plus facile à prendre à ce moment-là.

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
from .reply import format_reply, parse_command
from .throttle import Throttle

logger = logging.getLogger(__name__)

_FIRST_RETRY_SECONDS = 2.0
_MAX_RETRY_SECONDS = 60.0

# **Le crédit est dû à qui regarde, pas à qui ouvre les réglages.** Le garde-fou
# §IV.2 impose une attribution visible partout où des inconnus voient ces
# données ; un chat en fait partie. Elle est annoncée à la connexion plutôt
# qu'accrochée à chaque réponse, qui deviendrait illisible.
ANNOUNCE = "DeckHand lit le classeur — !card <nom>. Cartes, images et prix : Scryfall."

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
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.locator = locator
        self.channel = channel_name(channel)
        self.throttle = throttle or Throttle()
        self.command = command
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
        if query is None:
            return None
        if not self.throttle.allows(message.author, query):
            return None

        locations = self.locator.locate(client, query)
        return f"@{message.author} {format_reply(query, locations)}"

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
