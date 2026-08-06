"""Accès réseau à Scryfall.

Séparé de `scryfall_parse` à dessein : ce module est le seul à toucher le réseau, ce qui
garde la logique de transformation testable sans connexion.

Contraintes imposées par Scryfall et respectées ici (cf. https://scryfall.com/docs/api) :
  * Un `User-Agent` descriptif est **obligatoire** — un client anonyme peut être bloqué.
  * Le débit soutenu doit rester sous 10 requêtes/seconde. `_THROTTLE` impose un délai
    entre deux appels.
  * Les gros volumes passent par les *exports groupés*, jamais par la pagination des
    endpoints de recherche. C'est explicitement demandé par Scryfall, et c'est aussi
    bien plus rapide.
  * Les prix ne changent qu'une fois par jour : réingérer plus souvent est du gaspillage.

Les exports sont volumineux (390 Mo compressés pour `all_cards`), d'où le parcours en
flux plutôt qu'un chargement intégral. Scryfall publie chaque export en **JSONL** — un
objet JSON par ligne — via `jsonl_download_uri` : il suffit donc de décoder ligne à
ligne, sans analyseur incrémental ni dépendance supplémentaire.
"""

from __future__ import annotations

import json
import time
import zlib
from collections.abc import Iterable, Iterator
from typing import Any

import httpx

API_ROOT = "https://api.scryfall.com"

USER_AGENT = "DeckHand/0.1 (https://github.com/Lelio88/DeckHand)"

# Délai minimal entre deux requêtes. Scryfall demande de rester sous 10 req/s ;
# 100 ms laisse une marge confortable.
_THROTTLE = 0.1

# Exports groupés utilisés par DeckHand.
#   oracle_cards  : une entrée par carte oracle, en anglais — alimente `cards`.
#   default_cards : une entrée par impression, langue par défaut — alimente les prix.
#   all_cards     : toutes les impressions, toutes langues — nécessaire aux noms français.
BULK_ORACLE = "oracle_cards"
BULK_DEFAULT = "default_cards"
BULK_ALL = "all_cards"


class ScryfallError(RuntimeError):
    """Échec d'un échange avec Scryfall."""


def _headers() -> dict[str, str]:
    return {"User-Agent": USER_AGENT, "Accept": "application/json"}


def fetch_bulk_catalog(client: httpx.Client | None = None) -> dict[str, dict[str, Any]]:
    """Renvoie les exports groupés disponibles, indexés par leur `type`.

    Chaque entrée porte notamment `jsonl_download_uri`, `updated_at` et
    `compressed_size`. C'est le point d'entrée obligatoire : les URLs de téléchargement
    changent à chaque régénération et ne doivent jamais être codées en dur.
    """
    owns_client = client is None
    client = client or httpx.Client(timeout=30, headers=_headers())

    try:
        response = client.get(f"{API_ROOT}/bulk-data")
        response.raise_for_status()
        payload = response.json()
    except httpx.HTTPError as exc:
        raise ScryfallError(f"catalogue des exports groupés injoignable : {exc}") from exc
    finally:
        if owns_client:
            client.close()

    entries = payload.get("data")
    if not entries:
        raise ScryfallError("catalogue des exports groupés vide ou inattendu")

    return {entry["type"]: entry for entry in entries}


def decode_jsonl(chunks: Iterable[bytes], gzipped: bool = True) -> Iterator[dict[str, Any]]:
    """Décode un flux JSONL, éventuellement compressé, en objets Python.

    Scryfall sert ses exports en `.jsonl.gz` avec l'en-tête `content-type:
    application/gzip` mais **sans** `content-encoding: gzip`. Les clients HTTP ne
    décompressent donc pas d'eux-mêmes : c'est à nous de le faire, au fil de l'eau pour
    ne jamais charger 400 Mo en mémoire.

    Les lignes arrivent à cheval sur les fragments réseau ; le tampon conserve la ligne
    partielle d'un fragment à l'autre. Une ligne illisible est ignorée plutôt que de
    faire échouer l'import complet.
    """
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS) if gzipped else None
    buffer = b""

    def emit(raw: bytes) -> Iterator[dict[str, Any]]:
        if not raw.strip():
            return
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            return
        if isinstance(value, dict):
            yield value

    for chunk in chunks:
        buffer += decompressor.decompress(chunk) if decompressor else chunk
        *complete, buffer = buffer.split(b"\n")
        for raw in complete:
            yield from emit(raw)

    if decompressor:
        buffer += decompressor.flush()
    for raw in buffer.split(b"\n"):
        yield from emit(raw)


def stream_bulk(bulk_type: str, client: httpx.Client | None = None) -> Iterator[dict[str, Any]]:
    """Parcourt un export groupé carte par carte, sans le charger en mémoire.

    `bulk_type` doit valoir l'une des constantes `BULK_*`. Le flux est décodé ligne à
    ligne : l'empreinte mémoire reste constante même sur `all_cards`.

    Une ligne illisible est ignorée plutôt que de faire échouer l'import complet — un
    export de 400 Mo ne doit pas être perdu pour un octet corrompu. En revanche, une
    coupure réseau lève `ScryfallError` : elle laisserait un catalogue tronqué.
    """
    owns_client = client is None
    client = client or httpx.Client(timeout=None, headers=_headers(), follow_redirects=True)

    try:
        catalog = fetch_bulk_catalog(client)
        if bulk_type not in catalog:
            raise ScryfallError(
                f"export groupé inconnu : {bulk_type!r} (disponibles : {sorted(catalog)})"
            )

        time.sleep(_THROTTLE)
        download_uri = catalog[bulk_type]["jsonl_download_uri"]

        with client.stream("GET", download_uri) as response:
            response.raise_for_status()
            gzipped = download_uri.endswith(".gz") or "gzip" in response.headers.get(
                "content-type", ""
            )
            yield from decode_jsonl(response.iter_bytes(), gzipped=gzipped)
    except httpx.HTTPError as exc:
        raise ScryfallError(f"téléchargement de l'export {bulk_type} interrompu : {exc}") from exc
    finally:
        if owns_client:
            client.close()
