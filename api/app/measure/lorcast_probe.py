"""Sonde en lecture sur Lorcast, la source de catalogue Disney Lorcana.

**Pourquoi Lorcast et pas LorcanaJSON.** Les deux publient le catalogue, et
LorcanaJSON le fait en un seul fichier — un `allCards.json.zip` de 1,1 Mio, ce
qui aurait été plus économe que vingt-deux requêtes. Lorcast gagne pour une
raison qui n'a rien d'esthétique : **il porte le `tcgplayer_id` et les prix**,
les deux choses qu'aucun autre gisement du projet n'a jamais offertes ensemble.
Un seul appel rend donc ce qui a demandé deux connecteurs partout ailleurs.

**Ses conditions.** Lorcast ne publie ni conditions d'utilisation (`/terms`
répond 404) ni `robots.txt` exploitable (une page HTML). Le §IV.9 de la doctrine
s'applique tel quel : il reçoit le régime Scryfall — `User-Agent` descriptif,
débit bas, attribution visible, aucune illustration réhébergée. C'est le même
traitement que Riftcodex, TCGCSV, YGOPRODeck et TCGdex.

**Le cache est sur disque**, comme celui de la sonde One Piece. Une extension
relue est servie sans requête, ce qui permet aux bancs de tourner en boucle sans
peser sur la source — et permet surtout au connecteur de prix et à celui du
catalogue de partager le même téléchargement.

Usage :
    from app.measure.lorcast_probe import Probe
    probe = Probe()
    for code in probe.set_codes():
        for card in probe.cards(code):
            ...
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import httpx

BASE = "https://api.lorcast.com/v0"

USER_AGENT = "DeckHand/1.0 (collection manager; contact heianenterpriseyt@gmail.com)"

#: Régime Scryfall : dix requêtes par seconde sont tolérées, on en fait une
#: toutes les deux dixièmes. Vingt-deux extensions coûtent cinq secondes.
PAUSE_SECONDS = 0.2

CACHE = Path(__file__).resolve().parents[2] / ".cache" / "lorcast"

ATTEMPTS = 4
FIRST_DELAY = 1.5


class ProbeError(RuntimeError):
    """La source n'a pas rendu ce qu'on lui demandait."""


class Probe:
    """Lecture seule sur Lorcast, avec cache disque."""

    def __init__(self, *, quiet: bool = False, refresh: bool = False) -> None:
        self._quiet = quiet
        self._refresh = refresh
        CACHE.mkdir(parents=True, exist_ok=True)
        self._client = httpx.Client(
            timeout=60,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )

    def _say(self, message: str) -> None:
        if not self._quiet:
            print(message, flush=True)

    def _fetch(self, path: str, cache_name: str) -> Any:
        """Réponse JSON de `path`, servie du cache quand il l'a."""
        cached = CACHE / f"{cache_name}.json"
        if cached.exists() and not self._refresh:
            return json.loads(cached.read_text(encoding="utf-8"))

        delay = FIRST_DELAY
        last: Exception | None = None
        for attempt in range(ATTEMPTS):
            try:
                response = self._client.get(f"{BASE}{path}")
                if response.status_code == 404:
                    raise ProbeError(f"{path} : 404")
                response.raise_for_status()
                payload = response.json()
                cached.write_text(
                    json.dumps(payload, ensure_ascii=False), encoding="utf-8"
                )
                time.sleep(PAUSE_SECONDS)
                return payload
            except ProbeError:
                raise
            except Exception as exc:  # réseau, 5xx, JSON illisible
                last = exc
                if attempt == ATTEMPTS - 1:
                    break
                time.sleep(delay)
                delay *= 2
        raise ProbeError(f"{path} injoignable : {last}")

    def sets(self) -> list[dict[str, Any]]:
        """Les extensions publiées, dans l'ordre de la source."""
        payload = self._fetch("/sets", "sets")
        results = payload.get("results") if isinstance(payload, dict) else payload
        if not isinstance(results, list):
            raise ProbeError("/sets ne rend pas une liste")
        return results

    def set_codes(self) -> list[str]:
        """Les codes d'extension — `1`, `P1`, `Coconut`…

        **Ils ne sont pas tous numériques**, et c'est le premier piège : les
        extensions principales portent un nombre (`1` à `13`), les promos et les
        formats alternatifs portent un mot (`P1`, `D23`, `Coconut`). Les trier
        comme des nombres lèverait ; les traiter comme des chaînes suffit.
        """
        return [str(s.get("code")) for s in self.sets() if s.get("code")]

    def cards(self, set_code: str) -> list[dict[str, Any]]:
        """Les cartes d'une extension.

        La source rend une **liste nue**, non un objet paginé : rien à parcourir,
        et donc aucun des pièges de pagination rencontrés chez Wankul (503 au-delà
        de la page 1) ou chez SWU Meta Stats (`limit` ignoré, seul `skip` marche).
        """
        payload = self._fetch(f"/sets/{set_code}/cards", f"cards_{set_code}")
        if not isinstance(payload, list):
            raise ProbeError(f"/sets/{set_code}/cards ne rend pas une liste")
        return payload

    def all_cards(self) -> list[dict[str, Any]]:
        """Le catalogue entier — 3 192 cartes en vingt-deux requêtes."""
        out: list[dict[str, Any]] = []
        for code in self.set_codes():
            try:
                rows = self.cards(code)
            except ProbeError as exc:
                self._say(f"  ! {code} : {exc}")
                continue
            self._say(f"  {code:9} {len(rows):4} cartes")
            out.extend(rows)
        return out

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "Probe":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
