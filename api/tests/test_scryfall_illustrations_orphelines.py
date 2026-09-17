"""Les illustrations qu'aucune impression anglaise ni française ne porte.

**Ce que ces tests protègent.** `KEEP_LANGS` n'entrepose que les impressions
anglaises et françaises, et c'est inoffensif tant qu'une œuvre existe aussi dans
ces langues : l'art ne dépend pas de la langue, une carte japonaise se reconnaît
sur l'empreinte de sa jumelle anglaise.

Il cesse de l'être quand il n'y a pas de jumelle. Constaté sur trois cartes du
propriétaire — les terrains ukiyo-e de Kamigawa, que Scryfall ne publie qu'en
`ja` : aucune impression, donc aucun `illustration_id`, donc aucune empreinte.
Le scan échouait sans recours, et aucun gabarit n'y pouvait rien.

Mesuré sur l'export complet : 299 œuvres, soit 0,6 % du périmètre — 223
japonaises, 46 en chinois simplifié.

Les deux erreurs que ces tests ferment sont symétriques — ne rien rattraper, et
rattraper une œuvre déjà couverte, ce qui rouvrirait le catalogue d'impressions
par la bande.
"""

from __future__ import annotations

from typing import Any

from app.ingestion import scryfall_ingest
from app.ingestion.scryfall_ingest import KEEP_LANGS, ingest_prints_and_names

ORACLE = "1c0d8b2f-2f4a-4a1b-9a2c-6a3b7c9d0e1f"


def payload(lang: str, illus: str, number: str = "1") -> dict[str, Any]:
    return {
        "id": f"{lang}-{illus}-{number}",
        "oracle_id": ORACLE,
        "lang": lang,
        "name": "Forest",
        "printed_name": "森" if lang == "ja" else None,
        "set": "neo",
        "set_name": "Kamigawa: Neon Dynasty",
        "collector_number": number,
        "rarity": "common",
        "prices": {"eur": None, "eur_foil": None},
        "image_uris": {"art_crop": "https://example.invalid/a.jpg"},
        "illustration_id": illus,
        "finishes": ["nonfoil"],
        "released_at": "2022-02-18",
        "legalities": {"commander": "legal"},
        "games": ["paper"],
    }


class ConnexionFactice:
    """Retient ce qu'on lui donne à écrire, sans base derrière."""

    def __init__(self) -> None:
        self.rows: list[tuple] = []

    def cursor(self):
        conn = self

        class _Curseur:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def executemany(self, _statement, batch):
                conn.rows.extend(batch)

        return _Curseur()

    def commit(self) -> None:
        return None


def langues_ecrites(conn: ConnexionFactice) -> list[str]:
    """La langue est la troisième colonne de `PRINT_UPSERT`."""
    return [r[2] for r in conn.rows]


def joue(monkeypatch, payloads: list[dict[str, Any]]) -> ConnexionFactice:
    monkeypatch.setattr(scryfall_ingest, "stream_bulk", lambda _s: iter(payloads))
    conn = ConnexionFactice()
    ingest_prints_and_names(conn, {ORACLE})
    return conn


# --- ce qui est rattrape ----------------------------------------------------


def test_une_illustration_seulement_japonaise_est_rattrapee(monkeypatch):
    conn = joue(monkeypatch, [payload("ja", "ukiyoe", "302")])

    assert langues_ecrites(conn) == ["ja"], (
        "sans elle, l'œuvre n'entre nulle part et le scan n'a aucun recours"
    )


def test_une_seule_impression_par_illustration_orpheline(monkeypatch):
    """Deux impressions japonaises de la même œuvre ne valent qu'une empreinte ;
    en garder deux rouvrirait le catalogue d'impressions par la bande."""
    conn = joue(
        monkeypatch,
        [payload("ja", "ukiyoe", "302"), payload("ja", "ukiyoe", "302b")],
    )

    assert len(conn.rows) == 1


# --- ce qui ne l'est PAS ----------------------------------------------------


def test_une_illustration_deja_couverte_n_est_pas_rattrapee(monkeypatch):
    """Le cas courant, et de loin : l'art étant le même, l'impression anglaise
    suffit à reconnaître la carte japonaise."""
    conn = joue(
        monkeypatch,
        [payload("en", "commune", "1"), payload("ja", "commune", "1")],
    )

    assert langues_ecrites(conn) == ["en"]


def test_l_ordre_du_flux_ne_change_rien(monkeypatch):
    """**Le piège du passage unique.** Quand la japonaise arrive en premier, on
    ne sait pas encore qu'une anglaise suivra : le tri ne peut se faire qu'une
    fois le flux épuisé."""
    conn = joue(
        monkeypatch,
        [payload("ja", "commune", "1"), payload("en", "commune", "1")],
    )

    assert langues_ecrites(conn) == ["en"]


def test_une_impression_sans_illustration_n_est_pas_rattrapee(monkeypatch):
    """Sans `illustration_id`, rien ne permet de savoir si l'œuvre est ailleurs
    — et rien ne pourrait en calculer l'empreinte."""
    sans = payload("ja", "peu-importe", "302")
    sans["illustration_id"] = None
    sans["image_uris"] = {}

    conn = joue(monkeypatch, [sans])

    assert conn.rows == []


def test_le_filtre_de_langue_reste_celui_des_impressions():
    """Le rattrapage est une exception mesurée, pas un élargissement : la règle
    générale reste anglais et français."""
    assert KEEP_LANGS == frozenset({"en", "fr"})
