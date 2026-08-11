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


def main() -> int:
    parser = argparse.ArgumentParser(description="Bot Twitch DeckHand, en lecture seule")
    parser.add_argument("--game", default="magic", choices=["magic", "riftbound"])
    parser.add_argument("--command", default="!card", help="préfixe de la commande")
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
    )
    bot.run(IrcCredentials(nick=twitch.nick, token=twitch.token))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
