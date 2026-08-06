"""Tests du décodage des exports groupés Scryfall.

Aucun appel réseau : les flux sont fabriqués localement. Ce qui est testé ici est
précisément ce qui a cassé en conditions réelles — Scryfall sert du `.jsonl.gz` sans
en-tête `content-encoding`, et les lignes arrivent à cheval sur les fragments réseau.
"""

import gzip
import json

from app.ingestion.scryfall_client import decode_jsonl


def _gzip_of(lines: list[dict]) -> bytes:
    payload = "\n".join(json.dumps(line) for line in lines).encode()
    return gzip.compress(payload)


def _chunks(data: bytes, size: int) -> list[bytes]:
    return [data[i : i + size] for i in range(0, len(data), size)]


def test_decodes_gzipped_jsonl():
    cards = [{"name": "Lightning Bolt"}, {"name": "Island"}]
    assert list(decode_jsonl([_gzip_of(cards)])) == cards


def test_decodes_lines_split_across_network_chunks():
    """Le cas réel : une carte est coupée en deux par la frontière d'un fragment."""
    cards = [{"name": f"Carte {i}", "oracle_id": str(i)} for i in range(50)]
    tiny_chunks = _chunks(_gzip_of(cards), 7)
    assert len(tiny_chunks) > 1
    assert list(decode_jsonl(tiny_chunks)) == cards


def test_decodes_plain_jsonl_when_not_gzipped():
    cards = [{"name": "Sol Ring"}]
    raw = b'{"name": "Sol Ring"}\n'
    assert list(decode_jsonl([raw], gzipped=False)) == cards


def test_skips_unreadable_lines_without_losing_the_import():
    """Un octet corrompu ne doit pas faire perdre un export de 400 Mo."""
    raw = b'{"name": "Bon"}\n{ceci n\'est pas du json}\n{"name": "Aussi bon"}\n'
    assert list(decode_jsonl([raw], gzipped=False)) == [
        {"name": "Bon"},
        {"name": "Aussi bon"},
    ]


def test_ignores_blank_lines():
    raw = b'\n\n{"name": "Seule"}\n\n'
    assert list(decode_jsonl([raw], gzipped=False)) == [{"name": "Seule"}]


def test_ignores_non_object_values():
    """Une ligne scalaire n'est pas une carte : la laisser passer casse le parsing en aval."""
    raw = b'123\n"texte"\n{"name": "Vraie carte"}\n'
    assert list(decode_jsonl([raw], gzipped=False)) == [{"name": "Vraie carte"}]


def test_handles_empty_stream():
    assert list(decode_jsonl([], gzipped=False)) == []
