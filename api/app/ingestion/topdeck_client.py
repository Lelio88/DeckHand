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
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

import httpx

API_ROOT = "https://topdeck.gg/api"
GAME_MAGIC = "Magic: The Gathering"

USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

# Libellés de format tels que l'API les attend — sensibles à la casse.
FORMAT_PAUPER = "Pauper"
FORMAT_MODERN = "Modern"


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


def _board(raw: Any) -> dict[str, int]:
    """Convertit un pan de `deckObj` en dictionnaire nom -> quantité."""
    if not isinstance(raw, dict):
        return {}
    out: dict[str, int] = {}
    for name, payload in raw.items():
        count = payload.get("count") if isinstance(payload, dict) else payload
        try:
            quantity = int(count)
        except (TypeError, ValueError):
            continue
        if quantity > 0:
            out[name] = quantity
    return out


def fetch_decks(
    api_key: str,
    fmt: str,
    days: int = 90,
    client: httpx.Client | None = None,
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
            json={"game": GAME_MAGIC, "format": fmt, "last": days},
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

            mainboard = _board(deck_obj.get("Mainboard"))
            if not mainboard:
                continue

            yield TournamentDeck(
                tournament_id=tid,
                tournament_name=tournament.get("tournamentName") or "Tournoi",
                standing=index,
                started_at=tournament.get("startDate"),
                mainboard=mainboard,
                sideboard=_board(deck_obj.get("Sideboard")),
            )
