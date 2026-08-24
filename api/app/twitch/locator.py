"""Le seul point du bot qui touche au réseau.

Cinq fonctions publiques y sont appelées, et toutes par la même porte :
`binder_locate` (où est cette carte, et ce qu'elle vaut),
`public_recent_additions` (ce qui vient d'entrer au classeur),
`public_binder_shelf` (l'avancement par extension), `public_binder_page` (ce
qui manque à une page) et `public_request_spotlight` — **la seule qui écrive**.
Elles ont en commun d'accepter une **adresse de partage** — ce qui n'est pas le
cas de la plupart des fonctions du projet, dont `my_binder_shelf`, qui lisent la
collection de l'appelant et ne rendent donc rien sous la clé anonyme.

**Le bot passe par la porte publique, et par elle seule.** Clé anonyme, adresse
de partage, une fonction `SECURITY INVOKER` : les règles de ligne qui protègent
la page web protègent le bot par la même mécanique. Utiliser la clé de service
« pour simplifier » ferait de ce fichier un contournement de la portée choisie
dans l'écran de partage — c'est l'unique erreur qui rendrait cette
fonctionnalité dangereuse.

**L'écriture ne fait pas exception, et c'est tout son intérêt.**
`public_request_spotlight` est `SECURITY DEFINER` parce qu'elle touche une table
que personne d'autre n'atteint, mais elle est accordée à `anon` comme les
lectures : le bot n'a toujours aucun privilège qu'un spectateur n'ait pas. Ce
que la désignation peut faire au pire est borné dans la migration
`collection_spotlight`, pas ici — un garde-fou écrit côté client se contourne en
appelant la fonction sans le client.

**Une panne réseau ne dit rien de plus qu'une carte absente.** L'appelant reçoit
une liste vide, et le chat lit « pas dans le classeur ». Un direct n'est pas un
endroit où afficher une trace d'exception, et la distinction n'apprendrait rien
au spectateur.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

from .reply import Addition, Cell, Location, Shelf

logger = logging.getLogger(__name__)

# Un chat n'attend pas. Au-delà, mieux vaut ne pas répondre que répondre à une
# question que tout le monde a oubliée.
REQUEST_TIMEOUT_SECONDS = 6.0


def variante_trait_union(query: str) -> str | None:
    """La même saisie, traits d'union et espaces échangés — ou `None`.

    **Pourquoi ce repli existe, et pourquoi ici seulement.** `!card ka zar` ne
    trouve rien quand la carte s'appelle *Ka-Zar*. La cause n'est pas la
    normalisation : mesuré (`app.measure.nom_trait_union`), un **nom complet**
    mal saisi est retrouvé dans **100 %** des cas — 2 111 noms Magic éprouvés,
    zéro perdu, et autant dans l'autre sens. Le défaut ne vit que sur un
    **fragment** : pour une saisie courte la similarité trigramme s'effondre
    — « ka-zar » contre « ka-zar of the savage land » vaut 0,27 quand le seuil
    est à 0,30 — et il ne reste que la branche préfixe, un `LIKE` littéral où le
    trait d'union compte.

    Coût mesuré du défaut : **21 cartes en Magic** (1,0 % des noms à trait
    d'union), 32 en Yu-Gi-Oh, **zéro** en Lorcana et Riftbound. C'est rare, et
    on le corrige quand même : aujourd'hui le bot répond « pas dans le
    classeur » alors que **la carte y est**. Ce n'est pas une absence de
    réponse, c'est une réponse fausse.

    **Le repli est côté bot, et nulle part ailleurs.** `normalize_card_name` est
    partagée avec toute l'application et son jumeau Dart ; la tordre pour un cas
    de chat serait disproportionné, et la faire diverger casserait la
    reconnaissance embarquée.

    Rend `None` quand il n'y a rien à échanger — un seul mot sans trait d'union
    — pour ne pas payer un appel qui poserait la même question.
    """
    if "-" in query:
        variante = query.replace("-", " ")
    elif " " in query.strip():
        # **Le sens qui compte vraiment.** L'utilisateur tape deux mots là où le
        # nom n'en fait qu'un : « ka zar » pour « Ka-Zar ». L'autre sens ne
        # coûte rien à essayer, mais la mesure ne lui impute aucune perte.
        variante = query.replace(" ", "-")
    else:
        return None
    return variante if variante != query else None


@dataclass(frozen=True)
class Locator:
    """Où se rangent les cartes de la collection partagée sous cette adresse."""

    supabase_url: str
    anon_key: str
    handle: str
    game: str = "magic"

    def locate(self, client: httpx.Client, query: str) -> list[Location]:
        """Les cases où la carte se range, avec un second essai s'il le faut.

        **Le repli ne coûte qu'un échec.** Il ne part que lorsque la première
        recherche n'a rien rendu — c'est-à-dire quand le spectateur allait
        recevoir « pas dans le classeur ». Et le débit est vérifié **avant**
        cet appel, dans `Bot.answer` : une commande qui n'a pas mérité de
        réponse n'atteint jamais le réseau, repli compris.
        """
        trouvees = self._interroger(client, query)
        if trouvees:
            return trouvees
        variante = variante_trait_union(query)
        if variante is None:
            return []
        return self._interroger(client, variante)

    def recent(self, client: httpx.Client, limit: int = 3) -> list[Addition]:
        """Les dernières cartes entrées au classeur partagé."""
        rows = self._appeler(
            client, "public_recent_additions", {"p_handle": self.handle, "p_limit": limit}
        )
        return [Addition.from_row(row) for row in rows]

    def shelf(self, client: httpx.Client) -> list[Shelf]:
        """Les extensions visibles du classeur partagé, et leur remplissage."""
        rows = self._appeler(
            client, "public_binder_shelf", {"p_handle": self.handle, "p_game": self.game}
        )
        return [Shelf.from_row(row) for row in rows]

    def page(
        self, client: httpx.Client, set_code: str, page: int, per_page: int = 9
    ) -> list[Cell]:
        """Les cases d'une page du classeur partagé, vides comprises."""
        rows = self._appeler(
            client,
            "public_binder_page",
            {
                "p_handle": self.handle,
                "p_set_code": set_code,
                "p_page": page,
                "p_per_page": per_page,
                "p_game": self.game,
            },
        )
        return [Cell.from_row(row) for row in rows]

    def designate(
        self,
        client: httpx.Client,
        set_code: str,
        collector_number: str,
        requested_by: str,
    ) -> bool:
        """Fait monter une case sur l'overlay. Rend faux si la base refuse.

        **La base refuse pour trois raisons, et le bot n'en rencontre qu'une.**
        Collection non publiée et case non possédée sont écartées en amont : la
        commande n'appelle cette méthode qu'après avoir trouvé la carte par
        `binder_locate`, qui ne rend rien dans ces deux cas. Reste le délai de
        garde — l'écran est déjà pris.

        **Une panne réseau se lit comme un refus**, comme partout ailleurs ici.
        Le spectateur est invité à réessayer, ce qui est la bonne conduite dans
        les deux cas.
        """
        rendu = self._poster(
            client,
            "public_request_spotlight",
            {
                "p_handle": self.handle,
                "p_set_code": set_code,
                "p_collector_number": collector_number,
                "p_requested_by": requested_by,
                "p_game": self.game,
            },
        )
        return rendu is True

    def _interroger(self, client: httpx.Client, query: str) -> list[Location]:
        rows = self._appeler(
            client,
            "binder_locate",
            {"p_handle": self.handle, "p_query": query, "p_game": self.game},
        )
        return [Location.from_row(row) for row in rows]

    def _appeler(
        self, client: httpx.Client, fonction: str, corps: dict[str, object]
    ) -> list[dict[str, object]]:
        """Les lignes rendues par une fonction de lecture, ou une liste vide."""
        rows = self._poster(client, fonction, corps)
        if not isinstance(rows, list):
            return []
        return [row for row in rows if isinstance(row, dict)]

    def _poster(
        self, client: httpx.Client, fonction: str, corps: dict[str, object]
    ) -> object | None:
        """Un appel à la porte publique, brut — ou `None` si rien n'est revenu.

        **Une seule fonction touche au réseau**, quelle que soit la commande :
        la clé anonyme, l'en-tête et le traitement des pannes s'y écrivent une
        fois. Une commande qui appellerait Supabase de son côté échapperait au
        contrat de silence ci-dessus, et probablement à la clé anonyme.

        Elle rend la réponse **telle quelle** parce que toutes les fonctions ne
        rendent pas des lignes : `public_request_spotlight` répond un booléen. La
        mise en forme en liste appartient à `_appeler`, qui sert les lectures.
        """
        try:
            response = client.post(
                f"{self.supabase_url.rstrip('/')}/rest/v1/rpc/{fonction}",
                json=corps,
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
                "%s injoignable (%s)%s — réponse vide",
                fonction,
                type(error).__name__,
                detail,
            )
            return None

        return rows
