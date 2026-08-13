"""Sonde de lecture sur TCGdex, pour les bancs de mesure Pokémon.

**Ce n'est pas un connecteur d'ingestion.** Rien ici n'écrit en base : ces
fonctions servent à *mesurer* si Pokémon est tenable — la question que pose
l'issue #28 — et le catalogue n'entrera pas tant que la réponse n'est pas venue.
Un connecteur d'ingestion vivrait dans `app/ingestion/`, avec ses UUID dérivés
et son idempotence ; celui-ci n'a ni l'un ni l'autre.

**Les conditions de TCGdex ne sont pas publiées.** Le garde-fou §IV.9 du
CLAUDE.md tranche ce cas : à défaut de règles explicites, on applique celles de
Scryfall — `User-Agent` descriptif, débit volontairement bas, attribution
visible. C'est ce que fait déjà `riftcodex_ingest`. Une précision de plus vaut
pour Pokémon, relevée par l'issue : les deux CDN d'images sont eux-mêmes des
tiers non affiliés, et **aucune source Pokémon n'a de bénédiction éditeur**
comparable à la *Fan Content Policy* qui légitime Scryfall. Raison de plus pour
ne rien réhéberger et pour rester sous le débit.

**Le réseau de ce poste coupe régulièrement.** Toute requête est donc reprise
avec une attente croissante, et tout ce qui est obtenu est mis en cache sur
disque : une deuxième exécution d'un banc ne redemande rien. Le cache vit sous
`api/data/`, que le `.gitignore` couvre — le dépôt est public et aucune donnée
de source n'y entre (garde-fou §IV.10).

Exemple canonique :

    probe = Probe()
    sets = probe.json("sets")                       # tous les sets
    cards = probe.json("cards", category="Energy")  # filtré côté serveur
    path = probe.image("https://assets.tcgdex.net/en/sv/sv08/001")
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE = "https://api.tcgdex.net/v2/en"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Deux à trois requêtes par seconde, comme pour Riftcodex. La source n'annonce
#: aucune limite, et un banc de mesure n'a aucune raison d'être pressé.
PAUSE_SECONDS = 0.4

#: Reprises à attente croissante — 1, 2, 4, 8, 16 secondes. Ce poste perd le
#: réseau par à-coups de quelques dizaines de secondes ; six tentatives couvrent
#: 31 secondes d'attente cumulée, assez pour traverser une coupure ordinaire
#: sans transformer un banc de dix minutes en veille d'une heure.
ATTEMPTS = 6
FIRST_DELAY = 1.0

#: Hors dépôt (`.gitignore` couvre `/api/data/`). Les images pèsent lourd et
#: sont de la donnée de source : elles ne sont ni commitées ni republiées.
DEFAULT_CACHE = Path(__file__).resolve().parents[2] / "data" / "pokemon_probe"


class ProbeError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    """Télécharge [url], en reprenant sur coupure avec une attente croissante.

    Un 404 n'est **pas** repris : la ressource n'existe pas, et réessayer cinq
    fois ne la fera pas apparaître. Les autres codes HTTP le sont — un 429 ou un
    503 sont précisément ce que l'attente croissante existe pour absorber.
    """
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
        except Exception as exc:  # réseau coupé, DNS, TLS, lecture tronquée
            last = exc
        time.sleep(delay)
        delay *= 2
    raise ProbeError(f"{url} : {last}")


def _cache_name(path: str, params: dict[str, str]) -> str:
    """Nom de fichier lisible et stable pour une requête.

    Les paramètres sont triés : deux appels équivalents écrits dans un ordre
    différent doivent frapper la même entrée de cache, sinon le banc
    retéléchargerait sans le dire.
    """
    parts = [path.replace("/", "_")]
    parts += [f"{k}={params[k]}" for k in sorted(params)]
    raw = "&".join(parts)
    return "".join(c if c.isalnum() or c in "._=-" else "_" for c in raw) + ".json"


class Probe:
    """Accès en lecture à TCGdex, mis en cache et volontairement lent."""

    def __init__(self, cache: Path | None = None, quiet: bool = False) -> None:
        self.cache = cache or DEFAULT_CACHE
        self.quiet = quiet
        self.requests = 0
        (self.cache / "json").mkdir(parents=True, exist_ok=True)
        (self.cache / "img").mkdir(parents=True, exist_ok=True)

    def _log(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)

    def json(self, path: str, **params: str) -> Any:
        """Réponse JSON de `{BASE}/{path}`, filtrée par [params], mise en cache.

        Les filtres sont appliqués **côté serveur** : c'est ce qui rend le
        recensement abordable. Demander `cards?rarity=Common` renvoie la liste
        des identifiants concernés en une requête, là où reconstituer la même
        information carte par carte en coûterait des dizaines de milliers.
        """
        target = self.cache / "json" / _cache_name(path, params)
        if target.is_file():
            return json.loads(target.read_text(encoding="utf-8"))

        url = f"{BASE}/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        self._log(f"  GET {url}")
        payload = _fetch(url)
        self.requests += 1
        time.sleep(PAUSE_SECONDS)

        data = json.loads(payload.decode("utf-8"))
        target.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return data

    def image(self, base_url: str, quality: str = "high") -> Path:
        """Chemin local de l'image de carte publiée à [base_url].

        Le champ `image` de la source est une URL *de base* : la qualité et
        l'extension s'y accolent. On prend `webp`, quatre fois plus léger que le
        PNG à dimensions identiques (600 × 825 dans les deux cas) — sur un
        millier de cartes, c'est 300 Mio d'économisés à la source comme ici.
        """
        suffix = base_url.rsplit("/en/", 1)[-1].replace("/", "_")
        target = self.cache / "img" / f"{suffix}_{quality}.webp"
        if target.is_file():
            return target

        payload = _fetch(f"{base_url}/{quality}.webp")
        self.requests += 1
        time.sleep(PAUSE_SECONDS)
        target.write_bytes(payload)
        return target
