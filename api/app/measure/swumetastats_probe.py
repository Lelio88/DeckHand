"""Sonde de lecture sur SWU Meta Stats, pour mesurer le corpus de decks SWU.

**Pourquoi cette source, et pas celles qui servent déjà les autres jeux.**
Relevé site par site, comme le garde-fou §IV l'impose avant toute dépendance :

* **TopDeck.gg**, qui alimente Magic, Riftbound et Yu-Gi-Oh, *connaît* le jeu —
  36 tournois en `Premier`, 6 en `Twin Suns` sur un an — mais **aucun ne porte
  de decklist**. Le corpus est vide, pas la couverture. Le vérifier valait mieux
  que le supposer : c'est par la même porte que Riftbound a trouvé ses 2 500
  listes alors qu'on la croyait fermée.
* **Limitless**, qui alimente Pokémon, ne couvre pas SWU. Ses jeux, relevés sur
  500 tournois : `PTCG`, `VGC`, `POCKET`, `OP`, `DCG`, `GUNDAM`.
* **SWU Stats** (`swustats.net`) publie une API Melee sans clé, mais ses
  « decks » n'en sont pas : chaque entrée porte le leader, la base et le
  résultat, jamais la liste des cartes. C'est un corpus d'archétypes.

Reste SWU Meta Stats, qui publie ce qu'il faut : la liste complète, carte par
carte, avec les quantités et les quatre zones du jeu. Sa documentation annonce
« a public read-only REST API […] All endpoints return JSON and require no
authentication », son `robots.txt` est permissif, et il ne publie pas de
conditions — le garde-fou §IV.9 lui applique donc celles de Scryfall, comme à
Riftcodex, TCGCSV et TCGdex.

**Deux pièges de pagination, tous deux silencieux.** Mesurés, pas déduits :

* **`limit` est ignoré.** La page fait vingt entrées, qu'on en demande trois ou
  vingt-cinq. Un connecteur qui demanderait `limit=100` et compterait ce qu'il
  reçoit croirait avoir tout pris — c'est la leçon Pokémon, où un compteur
  d'écritures passait pour un compteur de résultats et masquait 5 533 decks
  manquants.
* **`page` et `offset` sont ignorés aussi**, et rendent la première page sans
  broncher. Seul **`skip`** déplace la fenêtre. Les trois auraient produit une
  ingestion qui tourne, qui n'échoue jamais, et qui réécrit vingt decks en
  boucle.

`totalCount` est donc la seule mesure de vérité du volume, et il faut le
comparer au nombre d'entrées réellement distinctes plutôt qu'au nombre de pages
lues.

Exemple canonique :

    probe = DeckProbe()
    total = probe.count("2026-05-01", "2026-08-17")
    for deck in probe.decklists("2026-05-01", "2026-08-17", limit=200):
        ...
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from pathlib import Path
from typing import Any

BASE = "https://www.swumetastats.com/api"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Une requête par seconde. La source annonce une protection anti-abus côté
#: serveur qui répond 429 ; rester bien en deçà évite de la déclencher, et un
#: banc de mesure n'a aucune raison d'être pressé.
PAUSE_SECONDS = 1.0

#: Taille de page **imposée par la source**, quoi qu'on demande. Elle est écrite
#: ici pour que le pas de `skip` ne soit pas un nombre magique semé dans le code.
PAGE_SIZE = 20

ATTEMPTS = 6
FIRST_DELAY = 2.0

DEFAULT_CACHE = Path(__file__).resolve().parents[2] / "data" / "swu_decks"


class ProbeError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    """Télécharge [url], en doublant l'attente à chaque échec.

    Le 429 est la raison d'être de cette reprise : la source le documente comme
    sa protection normale, pas comme une panne. Le 524 aussi — une requête non
    filtrée dépasse le délai de la passerelle, et c'est ce qui a imposé de
    borner chaque appel par une fenêtre de dates.
    """
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
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


class DeckProbe:
    """Accès en lecture à SWU Meta Stats, mis en cache et volontairement lent."""

    def __init__(self, cache: Path | None = None, quiet: bool = False) -> None:
        self.cache = cache or DEFAULT_CACHE
        self.quiet = quiet
        self.requests = 0
        #: Secondes passées à attendre la source, cache exclu. Ce n'est pas une
        #: statistique d'agrément : une page pèse un quart de mégaoctet et met
        #: plusieurs dizaines de secondes à venir, de sorte que le corpus entier
        #: se compte en heures. C'est ce chiffre qui décidera de la fenêtre
        #: retenue à l'ingestion, et il ne se voit qu'en mesurant.
        self.seconds = 0.0
        self.cache.mkdir(parents=True, exist_ok=True)

    def _log(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)

    def _page(self, start: str, end: str, skip: int) -> dict[str, Any]:
        name = f"decklists_{start}_{end}_{skip:06d}.json"
        target = self.cache / name
        if target.is_file():
            return json.loads(target.read_text(encoding="utf-8"))

        params = {"startDate": start, "endDate": end}
        if skip:
            params["skip"] = str(skip)
        url = f"{BASE}/decklists?" + urllib.parse.urlencode(params)
        self._log(f"  GET {url}")
        started = time.monotonic()
        payload = _fetch(url)
        self.seconds += time.monotonic() - started
        self.requests += 1
        time.sleep(PAUSE_SECONDS)

        data = json.loads(payload.decode("utf-8"))
        target.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return data

    def count(self, start: str, end: str) -> int:
        """Nombre de decklists que la source déclare sur la fenêtre.

        C'est la seule mesure de vérité du volume : le nombre de pages lues ne
        dit rien tant qu'on n'a pas vérifié que `skip` déplace vraiment la
        fenêtre.
        """
        return int(self._page(start, end, 0).get("totalCount") or 0)

    def decklists(
        self, start: str, end: str, limit: int | None = None
    ) -> Iterator[dict[str, Any]]:
        """Parcourt les decklists de la fenêtre, page par page.

        S'arrête dès qu'une page ne rapporte **aucune entrée nouvelle** : c'est
        le garde-fou contre le piège de pagination décrit en tête de module. Si
        `skip` cessait d'être honoré, la boucle s'arrêterait au lieu de tourner
        indéfiniment sur la première page.
        """
        seen: set[int] = set()
        skip = 0
        while True:
            page = self._page(start, end, skip)
            rows = page.get("decklists") or []
            fresh = [r for r in rows if r.get("id") not in seen]
            if not fresh:
                return
            for row in fresh:
                seen.add(row["id"])
                yield row
                if limit is not None and len(seen) >= limit:
                    return
            skip += PAGE_SIZE
