"""La connexion au chat Twitch, en TLS et sans dépendance nouvelle.

**Pourquoi IRC brut plutôt qu'une bibliothèque.** Twitch expose son chat en IRC
sur `irc.chat.twitch.tv:6697`, un protocole de texte à lignes que la
bibliothèque standard sait parler entière : `socket` ouvre, `ssl` chiffre, et
il reste à découper sur `\\r\\n`. Une dépendance de plus se justifierait par ce
qu'elle évite d'écrire ; ici c'est une centaine de lignes, et le paquet
`websockets` ferait entrer un client asynchrone dans un dépôt qui n'en a aucun.

**Ce que le protocole impose et qu'on ne peut pas sauter.** Le serveur envoie
`PING :tmi.twitch.tv` toutes les cinq minutes ; sans `PONG` en retour il
raccroche sans rien dire. Le silence prolongé est donc la panne normale d'un bot
IRC, pas une exception : `read_lines` pose un délai de lecture et rend la main,
et c'est à l'appelant de reconnecter.

**Le jeton ne transite jamais dans un journal.** `connect` l'envoie et l'oublie ;
aucune ligne sortante n'est tracée, précisément parce que la première est
`PASS oauth:…`.

Exemple canonique :

    with connect(IrcCredentials(nick="deckhandbot", token="oauth:…"), "lelio") as c:
        for line in c.read_lines():
            message = parse_privmsg(line)
            if message is not None:
                c.say("#lelio", f"@{message.author} bonjour")
"""

from __future__ import annotations

import socket
import ssl
from collections.abc import Iterator
from dataclasses import dataclass

TWITCH_HOST = "irc.chat.twitch.tv"
TWITCH_TLS_PORT = 6697

# Twitch coupe une ligne au-delà de 500 caractères. Tronquer ici plutôt que de
# laisser le serveur le faire garde la main sur l'endroit de la coupe.
MAX_MESSAGE_CHARS = 480

# Le serveur pingue toutes les cinq minutes. Un délai plus court rend la main
# régulièrement — utile pour qu'un arrêt clavier soit pris en compte — sans
# jamais être confondu avec une coupure.
_READ_TIMEOUT_SECONDS = 30.0


@dataclass(frozen=True)
class IrcCredentials:
    """De quoi s'annoncer au chat.

    `token` est un jeton OAuth Twitch avec la portée `chat:read` et
    `chat:edit`. Il vit dans le coffre hors dépôt, jamais ici.
    """

    nick: str
    token: str


@dataclass(frozen=True)
class ChatMessage:
    """Un message lu dans le chat."""

    author: str
    channel: str
    text: str


class IrcConnection:
    """Une connexion ouverte, vue comme des lignes qui entrent et sortent."""

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buffer = b""

    def send_line(self, line: str) -> None:
        self._sock.sendall(line.encode("utf-8") + b"\r\n")

    def say(self, channel: str, text: str) -> None:
        """Écrit dans le canal, sur une seule ligne.

        Les retours à la ligne sont écrasés : un `\\n` dans le texte couperait
        la commande IRC en deux et le reste partirait comme une commande brute.
        """
        flat = " ".join(text.split())
        self.send_line(f"PRIVMSG {channel} :{flat[:MAX_MESSAGE_CHARS]}")

    def read_lines(self) -> Iterator[str]:
        """Les lignes reçues, jusqu'à ce que la connexion se ferme ou se taise.

        Répond seule aux `PING` : un `PONG` manqué fait raccrocher le serveur,
        et ce n'est jamais une décision de l'appelant.
        """
        while True:
            try:
                chunk = self._sock.recv(4096)
            except (TimeoutError, socket.timeout):
                return
            if not chunk:
                return
            self._buffer += chunk
            while b"\r\n" in self._buffer:
                raw, _, self._buffer = self._buffer.partition(b"\r\n")
                line = raw.decode("utf-8", errors="replace")
                if line.startswith("PING"):
                    self.send_line("PONG :tmi.twitch.tv")
                    continue
                yield line

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def __enter__(self) -> IrcConnection:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def connect(credentials: IrcCredentials, channel: str) -> IrcConnection:
    """Ouvre la connexion, s'annonce, et rejoint le canal."""
    raw = socket.create_connection((TWITCH_HOST, TWITCH_TLS_PORT), timeout=15)
    raw.settimeout(_READ_TIMEOUT_SECONDS)
    context = ssl.create_default_context()
    sock = context.wrap_socket(raw, server_hostname=TWITCH_HOST)

    connection = IrcConnection(sock)
    connection.send_line(f"PASS oauth:{credentials.token.removeprefix('oauth:')}")
    connection.send_line(f"NICK {credentials.nick.lower()}")
    connection.send_line(f"JOIN {channel_name(channel)}")
    return connection


def channel_name(channel: str) -> str:
    """Le canal sous la forme qu'attend IRC, quelle que soit celle donnée."""
    return "#" + channel.lstrip("#").lower()


def parse_privmsg(line: str) -> ChatMessage | None:
    """Le message d'un humain, ou `None` pour tout le reste.

    Une ligne de chat a la forme
    `:pseudo!pseudo@pseudo.tmi.twitch.tv PRIVMSG #canal :texte`. Tout le trafic
    de service — codes numériques d'accueil, `JOIN`, `PART`, `NOTICE` — passe
    par ici aussi, et n'a rien à dire au bot.
    """
    if not line.startswith(":") or " PRIVMSG " not in line:
        return None

    prefix, _, rest = line[1:].partition(" PRIVMSG ")
    author = prefix.partition("!")[0]
    channel, _, text = rest.partition(" :")
    if not author or not channel or not text:
        return None
    return ChatMessage(author=author, channel=channel.strip(), text=text)
