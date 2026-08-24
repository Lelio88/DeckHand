"""Lance le bot Twitch en lecture.

    cd api && .venv/Scripts/python -m app.twitch [--game riftbound]

Les identifiants viennent de `../.deckhand-secrets/twitch.env` :

    TWITCH_NICK=deckhandbot
    TWITCH_TOKEN=<jeton OAuth, portées chat:read et chat:edit>
    TWITCH_CHANNEL=lelio88
    DECKHAND_HANDLE=<le nom de partage de la collection, ou son identifiant>

Le bot s'arrête au Ctrl-C. Rien n'est déployé : il tourne le temps du direct,
sur le poste qui diffuse.
"""

from __future__ import annotations

import argparse
import logging

from ..config import ConfigError, SupabaseConfig, TwitchConfig
from .bot import Bot
from .irc import IrcCredentials
from .locator import Locator

#: Où la page publique des classeurs est servie.
#:
#: Le workflow `pages.yml` y publie le build web ; l'adresse de partage est
#: cette base suivie de la poignée. `--share-url` la remplace si elle bouge, sans
#: quoi une adresse périmée s'annoncerait dans le chat en silence.
DEFAULT_SHARE_BASE = "https://lelio88.github.io/DeckHand/"


def main() -> int:
    parser = argparse.ArgumentParser(description="Bot Twitch DeckHand, en lecture seule")
    parser.add_argument("--game", default="magic", choices=["magic", "riftbound"])
    parser.add_argument("--command", default="!card", help="préfixe de la commande")
    parser.add_argument(
        "--share-url",
        default="",
        help="adresse publique du classeur, si elle diffère de celle construite",
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    try:
        supabase = SupabaseConfig.load()
        twitch = TwitchConfig.load()
    except ConfigError as error:
        logging.error("%s", error)
        return 1

    bot = Bot(
        locator=Locator(
            supabase_url=supabase.url,
            anon_key=supabase.anon_key,
            handle=twitch.handle,
            game=args.game,
        ),
        channel=twitch.channel,
        command=args.command,
        # **Construite, pas configurée en double.** L'adresse de partage est la
        # poignée : une seconde variable dans le coffre pourrait la contredire,
        # et `!deckhand` annoncerait alors un classeur qui n'est pas celui que
        # le bot lit.
        share_url=args.share_url or f"{DEFAULT_SHARE_BASE}?c={twitch.handle}",
    )
    bot.run(IrcCredentials(nick=twitch.nick, token=twitch.token))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
