"""La boucle qui relie le chat au classeur.

**Six commandes, dont cinq en lecture.** `!card <nom>` dit si la carte est
possédée, où, et ce qu'elle vaut ; `!page <ext> <n>` ce qui manque à une page ;
`!dernieres` ce qui vient d'entrer au classeur ; `!classeur` l'avancement par
extension ; `!deckhand` l'adresse et le crédit. `!montre <nom>` fait monter la
carte sur l'overlay OBS — **la seule qui écrive**.

**Ce que la clé de service reste interdite de faire.** La désignation écrit, mais
elle écrit par la même porte que les lectures : clé anonyme, adresse de partage,
une fonction accordée à `anon`. Une commande qui aurait besoin de la clé de
service serait le signal qu'elle n'a rien à faire dans un chat — la règle tient,
et c'est elle qui a dicté la forme de la migration `collection_spotlight` plutôt
que l'inverse.

**`!montre` lit avant d'écrire, et c'est ce qui la borne.** Elle passe par
`binder_locate` — la même fonction que `!card`, `SECURITY INVOKER`, exécutée sous
la clé anonyme — et n'écrit que ce que celle-ci a bien voulu rendre. Un
spectateur ne peut donc désigner que ce qu'il pouvait déjà voir, sans qu'aucune
ligne de Python n'ait à le vérifier.

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
    format_page,
    format_recent,
    format_reply,
    format_shelf,
    format_spotlight,
    parse_bare_command,
    parse_command,
    parse_page_command,
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
    "DeckHand lit le classeur — !card <nom> · !montre <nom> · !page <ext> <n> · "
    "!dernieres · !classeur · !deckhand. Cartes, images et prix : Scryfall."
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

        montre = parse_command(message.text, "!montre")
        if montre is not None:
            if not self.throttle.allows(message.author, f"!montre {montre}"):
                return None
            return f"@{message.author} {self._designer(client, montre, message.author)}"

        demande = parse_page_command(message.text)
        if demande is not None:
            set_code, page = demande
            if not self.throttle.allows(message.author, f"!page {set_code} {page}"):
                return None
            cellules = self.locator.page(client, set_code, page)
            return f"@{message.author} {format_page(set_code, page, cellules)}"

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

    def _designer(self, client: httpx.Client, query: str, author: str) -> str:
        """Fait monter une carte sur l'overlay, ou dit pourquoi non.

        **Rien n'est écrit avant d'avoir lu.** La recherche passe par la porte
        publique en lecture ; si elle ne rend rien, la commande répond
        exactement comme `!card` et n'appelle pas l'écriture. C'est ce qui rend
        superflu tout contrôle de portée côté bot : on ne peut désigner que ce
        qu'on pouvait déjà voir.

        **La première case, et non les trois.** `!card` en montre jusqu'à trois
        parce qu'un terrain de base occupe une douzaine de cases ; l'overlay,
        lui, n'a qu'une place. C'est la meilleure correspondance qui monte.
        """
        locations = self.locator.locate(client, query)
        if not locations:
            # La même phrase qu'une carte absente, une adresse inconnue ou une
            # extension retirée du partage : l'anti-énumération vaut ici aussi.
            return format_reply(query, [])
        place = locations[0]
        accepte = self.locator.designate(
            client, place.set_code, place.collector_number, author
        )
        return format_spotlight(place, accepte)

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
