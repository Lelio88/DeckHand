"""L'appel à `binder_locate` — le seul point du bot qui touche au réseau.

**Le bot passe par la porte publique, et par elle seule.** Clé anonyme, adresse
de partage, une fonction `SECURITY INVOKER` : les règles de ligne qui protègent
la page web protègent le bot par la même mécanique. Utiliser la clé de service
« pour simplifier » ferait de ce fichier un contournement de la portée choisie
dans l'écran de partage — c'est l'unique erreur qui rendrait cette
fonctionnalité dangereuse.

**Une panne réseau ne dit rien de plus qu'une carte absente.** L'appelant reçoit
une liste vide, et le chat lit « pas dans le classeur ». Un direct n'est pas un
endroit où afficher une trace d'exception, et la distinction n'apprendrait rien
au spectateur.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

from .reply import Location

logger = logging.getLogger(__name__)

# Un chat n'attend pas. Au-delà, mieux vaut ne pas répondre que répondre à une
# question que tout le monde a oubliée.
REQUEST_TIMEOUT_SECONDS = 6.0


@dataclass(frozen=True)
class Locator:
    """Où se rangent les cartes de la collection partagée sous cette adresse."""

    supabase_url: str
    anon_key: str
    handle: str
    game: str = "magic"

    def locate(self, client: httpx.Client, query: str) -> list[Location]:
        try:
            response = client.post(
                f"{self.supabase_url.rstrip('/')}/rest/v1/rpc/binder_locate",
                json={
                    "p_handle": self.handle,
                    "p_query": query,
                    "p_game": self.game,
                },
                headers={
                    "apikey": self.anon_key,
                    "Authorization": f"Bearer {self.anon_key}",
                    "Content-Type": "application/json",
                },
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            rows = response.json()
        except (httpx.HTTPError, ValueError) as error:
            # **Le chat ne voit rien, le journal voit tout.** Le corps de la
            # réponse porte le diagnostic — un cache de schéma PostgREST pas
            # encore rechargé rend un 404 nommant la fonction manquante, ce
            # qu'aucun nom d'exception ne dit. La requête, elle, n'est jamais
            # tracée : sa première ligne est l'en-tête d'autorisation.
            detail = ""
            if isinstance(error, httpx.HTTPStatusError):
                detail = f" [{error.response.status_code}] {error.response.text[:200]}"
            logger.warning(
                "binder_locate injoignable (%s)%s — réponse vide",
                type(error).__name__,
                detail,
            )
            return []

        if not isinstance(rows, list):
            return []
        return [Location.from_row(row) for row in rows if isinstance(row, dict)]
