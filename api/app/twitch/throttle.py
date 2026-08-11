"""Ce qui borne le débit — horloge injectable, donc mesurable sans attendre.

Trois limites, et chacune répond à un abus différent :

- **Le plafond Twitch** (20 messages par 30 secondes hors modérateur) n'est pas
  une politesse : le franchir vaut une exclusion temporaire du canal, et le bot
  se tait alors pour tout le monde. C'est la seule limite dont la violation
  coûte quelque chose au diffuseur.
- **Le délai par spectateur** empêche qu'un seul occupe le bot. Il est court —
  poser deux questions d'affilée est normal ; en poser dix en dix secondes ne
  l'est pas.
- **Le délai par recherche** évite de réécrire une réponse encore à l'écran
  quand vingt personnes demandent la même carte après l'avoir vue passer. Il
  est plus long que le précédent, parce que la réponse, elle, n'a pas changé.

**Un refus est un silence, jamais un message.** Répondre « trop de commandes »
consomme précisément la ressource qu'on protège.

L'horloge est un paramètre pour que les tests avancent le temps au lieu de le
subir : une limite de 30 secondes vérifiée en dormant 30 secondes ne serait
vérifiée par personne.
"""

from __future__ import annotations

import time
from collections import deque
from collections.abc import Callable

Clock = Callable[[], float]

# Twitch : 20 messages par 30 secondes pour un compte ordinaire. On vise en
# dessous — un bot qui frôle son plafond finit par le franchir sur un pic.
DEFAULT_BURST = 15
DEFAULT_WINDOW_SECONDS = 30.0
DEFAULT_USER_COOLDOWN_SECONDS = 5.0
DEFAULT_QUERY_COOLDOWN_SECONDS = 30.0


class Throttle:
    """Décide si une commande mérite une réponse maintenant."""

    def __init__(
        self,
        *,
        clock: Clock = time.monotonic,
        burst: int = DEFAULT_BURST,
        window_seconds: float = DEFAULT_WINDOW_SECONDS,
        user_cooldown_seconds: float = DEFAULT_USER_COOLDOWN_SECONDS,
        query_cooldown_seconds: float = DEFAULT_QUERY_COOLDOWN_SECONDS,
    ) -> None:
        self._clock = clock
        self._burst = burst
        self._window = window_seconds
        self._user_cooldown = user_cooldown_seconds
        self._query_cooldown = query_cooldown_seconds
        self._sent: deque[float] = deque()
        self._last_by_user: dict[str, float] = {}
        self._last_by_query: dict[str, float] = {}

    def allows(self, user: str, query: str) -> bool:
        """Vrai si le bot peut répondre, et **enregistre** alors l'envoi.

        Interroger sans enregistrer laisserait deux commandes simultanées
        passer toutes les deux : la décision et sa trace ne peuvent pas être
        deux appels distincts.
        """
        now = self._clock()
        self._forget_old(now)

        if len(self._sent) >= self._burst:
            return False

        key_user = user.lower()
        key_query = " ".join(query.lower().split())
        if now - self._last_by_user.get(key_user, -1e9) < self._user_cooldown:
            return False
        if now - self._last_by_query.get(key_query, -1e9) < self._query_cooldown:
            return False

        self._sent.append(now)
        self._last_by_user[key_user] = now
        self._last_by_query[key_query] = now
        return True

    def _forget_old(self, now: float) -> None:
        while self._sent and now - self._sent[0] >= self._window:
            self._sent.popleft()
        # Les deux tables ne grandissent pas indéfiniment : un chat de plusieurs
        # heures verrait sinon un dictionnaire par spectateur croisé.
        horizon = max(self._user_cooldown, self._query_cooldown)
        for table in (self._last_by_user, self._last_by_query):
            stale = [key for key, seen in table.items() if now - seen > horizon]
            for key in stale:
                del table[key]
