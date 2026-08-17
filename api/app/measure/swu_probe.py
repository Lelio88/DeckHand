"""Sonde de lecture sur SWU-DB, pour les bancs de mesure Star Wars Unlimited.

**Ce n'est pas un connecteur d'ingestion.** Rien ici n'écrit en base : ces
fonctions servent à *mesurer* ce que la source publie réellement, avant qu'une
seule ligne n'entre. Un connecteur vivrait dans `app/ingestion/`, avec ses UUID
dérivés et son idempotence ; celui-ci n'a ni l'un ni l'autre.

**Pourquoi SWU-DB et non la source officielle.** L'API qui alimente le site de
l'éditeur (`admin.starwarsunlimited.com`) est ouverte techniquement — aucune
clé, un `robots.txt` qui n'interdit rien — et elle sert le **français**, ce que
SWU-DB ne fait pas. Ses conditions la ferment quand même, verbatim :

    « You will not transmit any bugs, viruses, trojan horses, **bots,
    scrapers**, or any like or related programming through or to the Website. »

C'est le cas EDHREC du garde-fou §IV.1 : accessible, interdit. Et c'est le cas
Wankul avant l'accord — la porte existe, elle se demande à un humain. Tant
qu'elle n'est pas ouverte, le français est hors d'atteinte pour ce jeu, qui
rejoint donc Riftbound : **l'illustration prime sur le nom**, puisqu'un nom lu
sur un carton français ne correspondrait à rien dans un catalogue anglais.

**Les conditions de SWU-DB ne sont pas publiées** — `/terms` et `/about`
répondent 404, et le domaine n'a pas de `robots.txt`. Le garde-fou §IV.9 tranche
ce cas comme il l'a fait pour Riftcodex, TCGCSV et TCGdex : à défaut de règles
explicites, on applique celles de Scryfall — `User-Agent` descriptif, débit
volontairement bas, attribution visible, aucune illustration réhébergée. La
source documente publiquement son API sur `www.swu-db.com/api`, ce qui vaut
invitation à s'en servir, non permission de la saturer.

**Le réseau de ce poste coupe régulièrement.** Toute requête est donc reprise
avec une attente croissante, et tout ce qui est obtenu est mis en cache sur
disque : une deuxième exécution d'un banc ne redemande rien. Le cache vit sous
`api/data/`, que le `.gitignore` couvre — le dépôt est public et aucune donnée
de source n'y entre (garde-fou §IV.11).

Exemple canonique :

    probe = Probe()
    sets = probe.sets()                  # les 38 extensions, avec leur date
    cards = probe.cards("sor")           # les 946 impressions de SOR
    path = probe.image(cards[0]["FrontArt"])
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE = "https://api.swu-db.com"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Deux à trois requêtes par seconde, comme pour Riftcodex et TCGdex. La source
#: n'annonce aucune limite, et un banc de mesure n'a aucune raison d'être pressé.
PAUSE_SECONDS = 0.4

#: Reprises à attente croissante — 1, 2, 4, 8, 16 secondes. Ce poste perd le
#: réseau par à-coups de quelques dizaines de secondes ; six tentatives couvrent
#: 31 secondes d'attente cumulée, assez pour traverser une coupure ordinaire
#: sans transformer un banc de dix minutes en veille d'une heure.
ATTEMPTS = 6
FIRST_DELAY = 1.0

#: Hors dépôt (`.gitignore` couvre `/api/data/`). Les images pèsent lourd et
#: sont de la donnée de source : elles ne sont ni commitées ni republiées.
DEFAULT_CACHE = Path(__file__).resolve().parents[2] / "data" / "swu_probe"


class ProbeError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    """Télécharge [url], en reprenant sur coupure avec une attente croissante.

    Un 404 n'est **pas** repris : la ressource n'existe pas, et réessayer cinq
    fois ne la fera pas apparaître. Les autres codes le sont — un 429 ou un 503
    sont précisément ce que l'attente croissante existe pour absorber.

    Le 403 mérite une mention : cette API est derrière une passerelle AWS, qui
    répond `403 Missing Authentication Token` pour une **route inconnue** et non
    pour un défaut d'autorisation. Le reprendre serait inutile, mais le
    distinguer d'un vrai refus demanderait de lire le corps de la réponse ; on
    le reprend donc comme les autres, et l'erreur finale porte le message de la
    source, qui est explicite.
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
    """Accès en lecture à SWU-DB, mis en cache et volontairement lent."""

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
        """Réponse JSON de `{BASE}/{path}`, mise en cache sur disque."""
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

    def sets(self) -> list[dict[str, Any]]:
        """Les extensions publiées, avec leur code, leur nom et leur date.

        **Le point d'entrée du catalogue, et il a fallu le chercher.** La
        documentation ne le mentionne pas ; les codes d'extension s'y devinent
        au nom affiché (`A Lawless Time` donne `LAW`, pas `LTA`). Deviner aurait
        marché sur les extensions principales et manqué les promos, les jetons
        et les exclusivités de convention — c'est-à-dire précisément ce dont
        l'inventaire du périmètre a besoin.
        """
        return self.json("sets")

    #: Marqueur d'échec durable, écrit en cache à la place d'une réponse.
    #:
    #: **Une extension cassée chez la source coûte sinon à chaque lancement.**
    #: `TASH` rend un 502 déterministe — mesuré trois fois de suite, en une
    #: demi-seconde, quand `TSOR` répond 200 — et la reprise à attente
    #: croissante y dépense 31 secondes pour rien, à chaque exécution du banc.
    #:
    #: Mettre l'échec en cache est un compromis assumé : il masquerait une
    #: source réparée. C'est pourquoi il est *visible* — le banc le compte parmi
    #: les extensions injoignables, jamais parmi les vides — et *effaçable* :
    #: supprimer le fichier de cache suffit à réessayer.
    UNREACHABLE = "__injoignable__"

    def cards(self, set_code: str) -> list[dict[str, Any]]:
        """Toutes les **impressions** d'une extension.

        Le mot compte : `/cards/sor` rend 946 entrées quand `/sets` annonce 252
        cartes pour la même extension. L'écart n'est pas une erreur — ce sont
        les variantes (`Hyperspace`, `Foil`, `Showcase`…), chacune avec son
        propre numéro et son propre `tcgplayerId`. C'est la distinction
        `cards` / `card_prints` du modèle, publiée telle quelle par la source.

        Une extension vide rend une liste vide plutôt qu'une erreur : les
        extensions de jetons et de promos en comptent parfois une poignée, et
        certaines annoncées par `/sets` ne sont pas encore servies. Une
        extension **injoignable**, elle, lève : les deux ne se confondent pas,
        et le rapport les compte séparément.
        """
        try:
            payload = self.json(f"cards/{set_code.lower()}", format="json")
        except ProbeError as exc:
            self._remember_failure(set_code, str(exc))
            raise
        if isinstance(payload, dict) and self.UNREACHABLE in payload:
            raise ProbeError(payload[self.UNREACHABLE])
        return payload.get("data") or []

    def _remember_failure(self, set_code: str, message: str) -> None:
        """Consigne un échec en cache, pour ne pas le repayer à chaque essai."""
        target = self.cache / "json" / _cache_name(
            f"cards/{set_code.lower()}", {"format": "json"}
        )
        target.write_text(
            json.dumps({self.UNREACHABLE: message}, ensure_ascii=False),
            encoding="utf-8",
        )

    def image(self, url: str) -> Path:
        """Chemin local de l'illustration publiée à [url].

        L'URL est prise **telle que la source la donne** (`FrontArt`,
        `BackArt`) plutôt que recomposée depuis le code d'extension et le
        numéro : les variantes numérotent au-delà du décompte officiel et les
        faces arrière suffixent `-b`, deux règles qu'on reconstituerait mal.
        """
        name = url.rsplit("/cards/", 1)[-1].replace("/", "_")
        target = self.cache / "img" / name
        if target.is_file():
            return target

        payload = _fetch(url)
        self.requests += 1
        time.sleep(PAUSE_SECONDS)
        target.write_bytes(payload)
        return target
