"""Accès à l'API TopDeck.gg — decklists de tournoi pour les formats 60 cartes.

**Obligation contractuelle** : tout projet consommant cette API doit afficher un
crédit visible et un lien vers TopDeck.gg. L'exigence est portée par la table
`deck_sources` pour que l'interface ne puisse pas l'oublier.

Deux constats relevés en explorant l'API, qui expliquent la forme de ce module :

* **Aucun Commander multijoueur n'y existe.** Dix libellés de format ont été
  essayés, tous vides ; seul « Duel Commander » répond, et c'est un format 1v1
  aux bannissements distincts. Le Commander passe donc par d'autres sources.
* **Environ un tiers des participations seulement porte une decklist.** Les
  organisateurs choisissent de les publier ou non. Une réponse pauvre en decks
  est donc normale, pas le signe d'une panne.

Les identifiants de cartes renvoyés ne sont **pas** des Scryfall IDs : la
résolution se fait par nom, via `CardResolver`.

**Riftbound passe par la même porte, et c'est la meilleure nouvelle du
chantier.** La source déjà employée pour Magic, sous la même clé et la même
obligation d'attribution, sert 159 tournois Riftbound en `Constructed` — dont 59
portent des decklists, pour 2 501 participations documentées. Aucune nouvelle
dépendance, aucune condition d'usage à re-vérifier.

Deux différences avec Magic, toutes deux à notre avantage :

* **Les cartes portent un code d'impression** (`OGS-019`, `UNL-113`) et non
  seulement un nom. Le rapprochement redevient exact — mesuré, 785 codes sur 786
  se résolvent contre le catalogue —, là où Magic doit composer avec la casse,
  les accents et les cartes à deux faces.
* **Le deck a plus de deux zones** : `Legend`, `Champion`, `Runes`,
  `Battlefields`, `Mainboard`, `Sideboard`. Toutes sauf la dernière désignent des
  cartes qu'il faut posséder ; elles sont donc fondues dans le pan principal, car
  c'est lui qui porte le calcul de complétion. La Légende est en outre retenue à
  part, pour occuper `decks.commander_oracle_id` comme le fait un commandant.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

import httpx

API_ROOT = "https://topdeck.gg/api"
GAME_MAGIC = "Magic: The Gathering"
GAME_RIFTBOUND = "Riftbound"

USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

# Libellés de format tels que l'API les attend — sensibles à la casse.
FORMAT_PAUPER = "Pauper"
FORMAT_MODERN = "Modern"
FORMAT_CONSTRUCTED = "Constructed"

#: Zones d'un deck Riftbound qui désignent des cartes à posséder.
#:
#: `Sideboard` en est exclu à dessein — il ne compte pas dans la complétion,
#: exactement comme pour Magic. `Legend` y figure : on doit posséder sa Légende,
#: même si elle est aussi retenue à part pour `commander_oracle_id`.
RIFTBOUND_MAIN_ZONES = ("Legend", "Champion", "Runes", "Battlefields", "Mainboard")
RIFTBOUND_LEGEND_ZONE = "Legend"


class TopdeckError(RuntimeError):
    """Échec d'un échange avec TopDeck.gg."""


@dataclass(frozen=True)
class TournamentDeck:
    """Une participation à un tournoi, avec sa decklist."""

    tournament_id: str
    tournament_name: str
    standing: int
    started_at: int | None
    mainboard: dict[str, int] = field(default_factory=dict)
    sideboard: dict[str, int] = field(default_factory=dict)

    #: Clé de la Légende dans `mainboard`, pour les decks Riftbound. `None`
    #: ailleurs : un deck Magic de tournoi n'a pas de commandant.
    legend: str | None = None

    @property
    def external_id(self) -> str:
        """Identifiant stable pour les réimports.

        Le classement fait partie de la clé : un même tournoi apporte plusieurs
        decks, et l'API ne fournit aucun identifiant par participation.
        """
        return f"{self.tournament_id}#{self.standing}"

    @property
    def name(self) -> str:
        return f"{self.tournament_name} — {self.standing}e place"


def _headers(api_key: str) -> dict[str, str]:
    return {
        "Authorization": api_key,
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    }


def _board(raw: Any, *, by_code: bool = False) -> dict[str, int]:
    """Convertit un pan de `deckObj` en dictionnaire clé -> quantité.

    La clé est le **nom** par défaut, le **code d'impression** quand la source en
    fournit un exploitable (`by_code`). Riftbound est dans ce cas : `OGS-019`
    désigne une case unique du catalogue, là où un nom demande une résolution
    tolérante aux accents et à la casse. Une entrée sans code est alors ignorée
    plutôt que rabattue sur son nom — mélanger les deux clés dans un même
    dictionnaire produirait un deck où certaines cartes se résolvent et d'autres
    non, sans que rien ne dise laquelle.
    """
    if not isinstance(raw, dict):
        return {}
    out: dict[str, int] = {}
    for name, payload in raw.items():
        count = payload.get("count") if isinstance(payload, dict) else payload
        try:
            quantity = int(count)
        except (TypeError, ValueError):
            continue
        if quantity <= 0:
            continue

        key = name
        if by_code:
            code = payload.get("id") if isinstance(payload, dict) else None
            if not code:
                continue
            key = str(code)
        # Cumul : deux zones peuvent citer la même carte.
        out[key] = out.get(key, 0) + quantity
    return out


def riftbound_boards(deck_obj: dict[str, Any]) -> tuple[dict[str, int], dict[str, int], str | None]:
    """Aplatit un `deckObj` Riftbound en (principal, réserve, code de la Légende).

    **Toutes les zones sauf la réserve comptent dans la complétion.** Runes et
    champs de bataille ne sont pas des accessoires : on doit les posséder pour
    jouer le deck, et les omettre ferait paraître constructible une liste dont
    quinze cartes manquent. La médiane mesurée est de 64 cartes par deck, dont
    une douzaine de runes et trois champs de bataille.
    """
    main: dict[str, int] = {}
    for zone in RIFTBOUND_MAIN_ZONES:
        for code, quantity in _board(deck_obj.get(zone), by_code=True).items():
            main[code] = main.get(code, 0) + quantity

    legend = next(iter(_board(deck_obj.get(RIFTBOUND_LEGEND_ZONE), by_code=True)), None)
    side = _board(deck_obj.get("Sideboard"), by_code=True)
    return main, side, legend


def fetch_decks(
    api_key: str,
    fmt: str,
    days: int = 90,
    client: httpx.Client | None = None,
    game: str = GAME_MAGIC,
) -> Iterator[TournamentDeck]:
    """Parcourt les decklists publiées d'un format sur les `days` derniers jours.

    Les participations sans decklist sont ignorées silencieusement : c'est le cas
    majoritaire, et le signaler ligne à ligne noierait les vrais problèmes.
    """
    owns_client = client is None
    client = client or httpx.Client(timeout=120)

    try:
        response = client.post(
            f"{API_ROOT}/v2/tournaments",
            headers=_headers(api_key),
            json={"game": game, "format": fmt, "last": days},
        )
        response.raise_for_status()
        tournaments = response.json()
    except httpx.HTTPError as exc:
        raise TopdeckError(f"tournois {fmt} injoignables : {exc}") from exc
    finally:
        if owns_client:
            client.close()

    if not isinstance(tournaments, list):
        raise TopdeckError(f"réponse inattendue pour {fmt} : {type(tournaments)}")

    for tournament in tournaments:
        tid = tournament.get("TID")
        if not tid:
            continue

        for index, entry in enumerate(tournament.get("standings") or [], start=1):
            deck_obj = entry.get("deckObj")
            if not isinstance(deck_obj, dict):
                continue

            legend: str | None = None
            if game == GAME_RIFTBOUND:
                mainboard, sideboard, legend = riftbound_boards(deck_obj)
            else:
                mainboard = _board(deck_obj.get("Mainboard"))
                sideboard = _board(deck_obj.get("Sideboard"))

            if not mainboard:
                continue

            yield TournamentDeck(
                tournament_id=tid,
                tournament_name=tournament.get("tournamentName") or "Tournoi",
                standing=index,
                started_at=tournament.get("startDate"),
                mainboard=mainboard,
                sideboard=sideboard,
                legend=legend,
            )
