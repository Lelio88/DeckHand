"""Ingestion du catalogue Riftbound depuis Riftcodex.

**Pourquoi cette source et pas l'API officielle.** Riot expose bien un endpoint
de contenu Riftbound, mais il est fermé aux clés de développement : mesuré, une
clé valide obtient 403 sur les quatre routes régionales alors qu'elle répond 200
sur un endpoint banal. L'ouverture demande une approbation nommée. Riftcodex est
une base communautaire, publique et sans authentification, qui **référence les
illustrations du CDN officiel de Riot** plutôt que de les réhéberger.

**Ses conditions d'utilisation ne sont pas publiées**, ce que le garde-fou §IV du
CLAUDE.md impose normalement de vérifier avant toute dépendance. À défaut de
règles explicites, on lui applique celles de Scryfall : `User-Agent` descriptif,
débit volontairement bas, attribution visible dans l'écran « à propos ». La
bascule vers l'API Riot reste l'objectif dès qu'elle s'ouvrira.

**Le volume ne ressemble pas à celui de Magic.** 1 451 cartes contre 31 634, et
tout tient en quinze requêtes : là où l'ingestion Scryfall passe par des exports
en masse et dure des heures, celle-ci se compte en minutes.

**Identifiants dérivés, faute d'UUID à la source.** Le modèle est né avec Magic,
dont Scryfall fournit des UUID. Riftcodex expose des identifiants d'une autre
forme ; on en dérive des UUID **déterministes** (UUIDv5), de sorte qu'une
réingestion retombe exactement sur les mêmes clés et mette à jour au lieu de
dupliquer.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest
"""

from __future__ import annotations

import re
import time
import urllib.request
import json
import uuid
from typing import Any, Iterator

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name

BASE = "https://api.riftcodex.com/cards"
USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)
PAGE_SIZE = 100
#: Deux à trois requêtes par seconde : très en deçà de ce que Scryfall tolère,
#: et la source n'annonce aucune limite. Quinze pages, la politesse est gratuite.
PAUSE_SECONDS = 0.4

GAME = "riftbound"

#: Espace de noms des identifiants dérivés. Figé : le changer réécrirait tout le
#: catalogue sous de nouvelles clés et orphelinerait les collections.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/riftbound")


#: Suffixe de variante accolé au nom par la source : « (Alternate Art) »,
#: « (Signature) », « (Metal) »… 243 cartes sur 1 451 en portent un.
_VARIANT_SUFFIX = re.compile(r"\s\([^)]+\)$")


def base_name(name: str) -> str:
    """Nom sans son suffixe de variante.

    **Une variante est une impression, pas une carte.** La source distingue
    « Master Yi - Wuju Master » de « Master Yi - Wuju Master (Signature) », qui
    partagent illustration, type et texte : c'est la même carte de jeu, dans une
    autre impression. Les garder séparées en ferait deux entrées de collection
    pour un seul exemplaire possédé, et deux lignes identiques dans la
    recherche. C'est précisément ce que `card_prints` existe pour porter.

    Mesuré : la normalisation ramène 1 234 identités à 1 035, en fusionnant 131
    groupes dont les membres ont le même type et le même texte.
    """
    return _VARIANT_SUFFIX.sub("", name)


def oracle_uuid(card: dict[str, Any]) -> uuid.UUID:
    """Identité d'une carte, indépendante de son édition et de sa variante.

    La clé est le triplet nom + type + texte, et non le nom seul : 212 noms sont
    portés par plusieurs entrées, dont 36 recouvrent des cartes réellement
    différentes. Le nom seul les confondrait ; le triplet les sépare tout en
    réunissant les vraies réimpressions.
    """
    key = "|".join(
        (
            base_name(card["name"]),
            card["classification"]["type"] or "",
            (card["text"] or {}).get("plain") or "",
        )
    )
    return uuid.uuid5(NAMESPACE, f"card:{key}")


def print_uuid(card: dict[str, Any]) -> uuid.UUID:
    """Identité d'une impression : l'identifiant de la source, qui est unique."""
    return uuid.uuid5(NAMESPACE, f"print:{card['id']}")


def illustration_uuid(card: dict[str, Any]) -> uuid.UUID:
    """Identité d'une œuvre, dérivée de l'URL de son image.

    Sert au même usage que l'`illustration_id` de Scryfall : ne hacher qu'une
    fois une illustration réutilisée par plusieurs impressions.
    """
    return uuid.uuid5(NAMESPACE, f"art:{card['media']['image_url']}")


def type_line(card: dict[str, Any]) -> str:
    """Ligne de type lisible, sur le modèle de Magic.

    Les `tags` (« Vi », « Poppy ») ne sont pas repris : ce sont des personnages,
    pas des types, et les mêler brouillerait la recherche par type.
    """
    classification = card["classification"]
    parts = [classification["type"] or ""]
    if classification.get("supertype"):
        parts.append(classification["supertype"])
    return " — ".join(p for p in parts if p)


def fetch_all() -> list[dict[str, Any]]:
    """Rapatrie le catalogue, page par page."""

    def page(number: int) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{BASE}?size={PAGE_SIZE}&page={number}",
            headers={"User-Agent": USER_AGENT},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)

    first = page(1)
    cards = list(first["items"])
    for number in range(2, first["pages"] + 1):
        time.sleep(PAUSE_SECONDS)
        cards.extend(page(number)["items"])
    return cards


def write_cards(conn: psycopg.Connection, cards: list[dict[str, Any]]) -> int:
    """Écrit l'identité des cartes. Idempotent."""
    statement = """
        INSERT INTO public.cards (oracle_id, name, mana_cost, cmc, type_line,
                                  oracle_text, color_identity, legalities, layout,
                                  game, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (oracle_id) DO UPDATE SET
            name           = EXCLUDED.name,
            mana_cost      = EXCLUDED.mana_cost,
            cmc            = EXCLUDED.cmc,
            type_line      = EXCLUDED.type_line,
            oracle_text    = EXCLUDED.oracle_text,
            color_identity = EXCLUDED.color_identity,
            layout         = EXCLUDED.layout,
            game           = EXCLUDED.game,
            updated_at     = NOW()
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        seen: set[uuid.UUID] = set()
        for card in cards:
            identity = oracle_uuid(card)
            if identity in seen:
                continue
            seen.add(identity)
            energy = (card.get("attributes") or {}).get("energy")
            yield (
                str(identity),
                base_name(card["name"]),
                str(energy) if energy is not None else None,
                float(energy) if energy is not None else 0,
                type_line(card),
                (card["text"] or {}).get("plain"),
                # Les domaines occupent la place de l'identité de couleur : même
                # nature, même usage — restreindre les decks constructibles.
                card["classification"].get("domain") or [],
                "{}",
                # L'orientation tient lieu de disposition : c'est elle qui dira
                # quel gabarit d'illustration appliquer au découpage.
                card.get("orientation"),
                GAME,
            )

    written = 0
    with conn.cursor() as cur:
        for row in rows():
            cur.execute(statement, row)
            written += 1
        conn.commit()
    return written


def write_prints(conn: psycopg.Connection, cards: list[dict[str, Any]]) -> int:
    """Écrit chaque impression, avec l'URL de son visuel officiel."""
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE SET
            -- **L'identité doit suivre.** Sans cette ligne, une impression
            -- déjà connue reste rattachée à l'ancienne carte quand la règle
            -- d'identité change, et les deux versions coexistent en base.
            oracle_id        = EXCLUDED.oracle_id,
            set_code         = EXCLUDED.set_code,
            set_name         = EXCLUDED.set_name,
            collector_number = EXCLUDED.collector_number,
            printed_name     = EXCLUDED.printed_name,
            rarity           = EXCLUDED.rarity,
            art_crop_url     = EXCLUDED.art_crop_url,
            illustration_id  = EXCLUDED.illustration_id
    """

    written = 0
    with conn.cursor() as cur:
        for card in cards:
            number = card.get("collector_number")
            cur.execute(
                statement,
                (
                    str(print_uuid(card)),
                    str(oracle_uuid(card)),
                    # Riot ne sert que l'anglais en bêta ; le jour où les
                    # traductions arriveront, elles s'ajouteront ici sans
                    # toucher au reste.
                    "en",
                    # Le nom complet, suffixe de variante compris : c'est lui
                    # qui distingue une impression « Metal » d'une ordinaire au
                    # moment de désigner celle qu'on possède.
                    card["name"],
                    card["set"]["set_id"],
                    card["set"].get("label"),
                    str(number) if number is not None else None,
                    card["classification"].get("rarity"),
                    # **Ce n'est pas un recadrage d'illustration mais la carte
                    # entière.** Contrairement à Scryfall, la source ne fournit
                    # pas la seule zone illustrée : le découpage devra se faire
                    # au calcul d'empreinte, selon l'orientation.
                    (card.get("media") or {}).get("image_url"),
                    # **L'URL de l'image identifie l'œuvre.** Deux impressions
                    # qui partagent la même illustration partagent la même URL,
                    # donc le même identifiant : le constructeur d'index ne
                    # calculera l'empreinte qu'une fois, comme il le fait pour
                    # Magic via l'identifiant d'illustration de Scryfall.
                    str(illustration_uuid(card)) if (card.get("media") or {}).get("image_url") else None,
                ),
            )
            written += 1
        conn.commit()
    return written


def write_search_names(conn: psycopg.Connection, cards: list[dict[str, Any]]) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable."""
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    written = 0
    with conn.cursor() as cur:
        seen: set[tuple[str, str]] = set()
        for card in cards:
            identity = str(oracle_uuid(card))
            normalized = normalize_name(base_name(card["name"]))
            if (identity, normalized) in seen:
                continue
            seen.add((identity, normalized))
            cur.execute(statement, (identity, base_name(card["name"]), normalized, "en"))
            written += 1
        conn.commit()
    return written


def main() -> int:
    print("Rapatriement du catalogue Riftbound…")
    cards = fetch_all()
    print(f"  {len(cards)} cartes reçues")

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        identities = write_cards(conn, cards)
        print(f"  {identities} cartes distinctes écrites")
        prints = write_prints(conn, cards)
        print(f"  {prints} impressions écrites")
        names = write_search_names(conn, cards)
        print(f"  {names} noms indexés")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
