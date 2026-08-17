"""Sonde de lecture sur OPTCG API, pour les bancs de mesure One Piece.

**Ce n'est pas un connecteur d'ingestion.** Rien ici n'écrit en base : ces
fonctions servent à mesurer ce que la source publie réellement, avant qu'une
seule ligne n'entre.

**Pourquoi celle-ci, et pas les deux autres.** Trois catalogues One Piece ont
été relevés, `robots.txt` en main — c'est la vérification que le garde-fou §IV
impose avant toute dépendance :

* **apitcg.com** publie `Disallow: /api/` : l'API qui servirait est
  nommément interdite. C'est le motif exact qui avait écarté piltoverarchive
  pour Riftbound ;
* **onepiece-cardgame.dev** répond à toute requête par une page Cloudflare
  « Just a moment… ». C'est une **détection de robot**, non une absence — et
  la confondre avec l'une ou l'autre serait une erreur des deux côtés :
  Cardmarket avait rendu 403 sur une requête simple alors qu'il fallait
  conclure « ce jeu n'y est pas », et ici il faut conclure « cette porte est
  fermée ». On ne contourne pas une protection ;
* **optcgapi.com** ne publie ni `robots.txt` ni conditions (404 sur les deux)
  et documente son API publiquement. Le garde-fou §IV.9 lui applique celles de
  Scryfall — `User-Agent` descriptif, débit bas, attribution visible.

**Le catalogue se lit par deux portes, et l'oublier en couperait un huitième.**
Les 21 extensions viennent de `/api/allSets/` puis `/api/sets/{id}/` ; les **29
decks de démarrage** ont leur propre chemin, `/api/allDecks/` puis
`/api/decks/{id}/`, et `/api/sets/ST-01/` rend « Card was not found! ». Ce sont
507 entrées et 433 codes — et surtout, les decklists de tournoi les citent :
`ST32` apparaît dès le premier deck relevé chez Limitless. Sans ce second
parcours, ces citations seraient restées introuvables sans que rien ne dise
pourquoi.

Exemple canonique :

    probe = Probe()
    for code in probe.set_ids():
        rows = probe.cards(code)
    for code in probe.deck_ids():
        rows = probe.deck_cards(code)
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE = "https://optcgapi.com/api"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Deux à trois requêtes par seconde, comme pour les autres sondes. La source
#: n'annonce aucune limite, et une cinquantaine de requêtes suffit au catalogue
#: entier.
PAUSE_SECONDS = 0.4

ATTEMPTS = 5
FIRST_DELAY = 1.0

DEFAULT_CACHE = Path(__file__).resolve().parents[2] / "data" / "optcg_probe"


class ProbeError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise ProbeError(f"{url} : introuvable (404)") from exc
            last = exc
        except Exception as exc:
            last = exc
        time.sleep(delay)
        delay *= 2
    raise ProbeError(f"{url} : {last}")


class Probe:
    """Accès en lecture à OPTCG API, mis en cache et volontairement lent."""

    def __init__(self, cache: Path | None = None, quiet: bool = False) -> None:
        self.cache = cache or DEFAULT_CACHE
        self.quiet = quiet
        self.requests = 0
        (self.cache / "json").mkdir(parents=True, exist_ok=True)
        (self.cache / "img").mkdir(parents=True, exist_ok=True)

    def _log(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)

    def json(self, path: str) -> Any:
        """Réponse JSON de `{BASE}/{path}`, mise en cache sur disque."""
        name = "".join(c if c.isalnum() or c in "._-" else "_" for c in path) + ".json"
        target = self.cache / "json" / name
        if target.is_file():
            return json.loads(target.read_text(encoding="utf-8"))

        url = f"{BASE}/{path}"
        self._log(f"  GET {url}")
        payload = _fetch(url)
        self.requests += 1
        time.sleep(PAUSE_SECONDS)

        data = json.loads(payload.decode("utf-8"))
        target.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return data

    def set_ids(self) -> list[str]:
        """Les extensions — boosters et collections premium."""
        return [s["set_id"] for s in self.json("allSets/") if s.get("set_id")]

    def deck_ids(self) -> list[str]:
        """Les decks de démarrage. **Une seconde porte, pas un supplément** —
        les decklists de tournoi citent leurs cartes couramment."""
        return [
            d["structure_deck_id"]
            for d in self.json("allDecks/")
            if d.get("structure_deck_id")
        ]

    def cards(self, set_id: str) -> list[dict[str, Any]]:
        return self.json(f"sets/{set_id}/")

    def deck_cards(self, deck_id: str) -> list[dict[str, Any]]:
        return self.json(f"decks/{deck_id}/")

    def image(self, url: str) -> Path:
        """Chemin local du rendu publié à [url]."""
        target = self.cache / "img" / url.rsplit("/", 1)[-1]
        if target.is_file():
            return target
        payload = _fetch(url)
        self.requests += 1
        time.sleep(PAUSE_SECONDS)
        target.write_bytes(payload)
        return target
