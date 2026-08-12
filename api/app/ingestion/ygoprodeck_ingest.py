"""Ingestion du catalogue Yu-Gi-Oh depuis YGOPRODeck.

**Pourquoi cette source.** C'est la seule des trois relevées pour un troisième
jeu dont les quatre pièces — catalogue, prix, decks, illustrations — s'obtiennent
sans invention. Le catalogue entier tient en **un seul appel** (14 491 cartes,
21 Mo), sans clé, et la source **demande** le stockage local plutôt que de le
tolérer : « please download and store all data locally ».

**Ses conditions ne sont pas publiées sous forme de CGU**, seulement un guide
d'API. C'est le cas que prévoit le garde-fou §IV.9 : on lui applique celles de
Scryfall — `User-Agent` descriptif, débit volontairement bas, attribution
visible dans l'écran « à propos ».

**L'identité est donnée, pas dérivée.** Contrairement à Riftbound, dont il a
fallu construire des UUID à partir du triplet nom + type + texte, Yu-Gi-Oh a un
identifiant natif : le *passcode* à huit chiffres, **imprimé sur la carte
elle-même**. Mesuré, il est unique sur les 14 491 entrées. On en dérive un UUIDv5
déterministe, faute de colonne entière dans un modèle né avec les UUID de
Scryfall, mais la clé est stable par construction.

**Zéro homonyme**, et c'est le fait qui décide de la voie de reconnaissance.
Riftbound a 80 noms portés par plusieurs cartes réellement différentes, ce qui
oblige à passer par l'illustration ; ici aucun nom n'est partagé. Le nom lu
suffit, et il est servi **en français** avec son pendant anglais (`name_en`),
là où Riot ne sert que l'anglais. Yu-Gi-Oh rejoint donc Magic : le nom d'abord,
l'illustration en appoint.

**Les écritures partent par lots**, contrairement aux connecteurs précédents.
Riftbound écrit ses 1 451 impressions une par une sans que cela se remarque ;
ici il y en a **44 287**, et un aller-retour par ligne vers une base distante
porte l'ingestion à plusieurs dizaines de minutes. `executemany` les regroupe en
un seul échange. C'est le seul endroit où le volume de ce jeu change la manière
de faire.

**Ce que la source ne donne pas.** Les impressions listées sont quasi
exclusivement anglaises — 38 590 codes `XXXX-EN###` contre 456 `PT` et 4 `SE`.
Les éditions françaises existent en carton mais ne figurent pas au catalogue :
`card_prints` porte donc les impressions anglaises, et le français vit dans
`card_search_names`, qui est fait pour ça.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.ygoprodeck_ingest
    #   --force   réingère même si le catalogue n'a pas changé
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.request
import uuid
from typing import Any, Iterator

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name
from app.ingestion.state import last_version, record

BASE = "https://db.ygoprodeck.com/api/v7/cardinfo.php"
USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

GAME = "yugioh"
SOURCE = "ygoprodeck"

#: Langues rapatriées. L'anglais fait foi pour les impressions et les types ; le
#: français n'apporte que des noms, mais ce sont eux que l'utilisateur saisit et
#: que la reconnaissance lit sur le carton.
LANGS = ("en", "fr")

#: Politesse : la source annonce 20 requêtes par seconde et ce module en fait
#: deux en tout. La pause est symbolique, elle dit surtout l'intention.
PAUSE_SECONDS = 1.0

#: Espace de noms des identifiants dérivés. Figé : le changer réécrirait tout le
#: catalogue sous de nouvelles clés et orphelinerait les collections.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/yugioh")


def oracle_uuid(passcode: int) -> uuid.UUID:
    """Identité d'une carte, dérivée de son passcode.

    Le passcode est l'identifiant que Konami imprime sur la carte : il ne change
    pas d'une réimpression à l'autre, ne dépend pas de la langue, et la source le
    sert tel quel. Rien à inventer — seul le format change, un UUIDv5 tenant dans
    la colonne que Scryfall a façonnée.
    """
    return uuid.uuid5(NAMESPACE, f"card:{passcode}")


def print_uuid(set_code: str, rarity: str, passcode: int) -> uuid.UUID:
    """Identité d'une impression.

    **Le code d'extension ne suffit pas.** Une même carte paraît dans une même
    extension sous plusieurs raretés — mesuré, 44 287 impressions pour 38 297
    codes distincts, soit près de six mille doublons de code. La rareté fait
    donc partie de la clé, sans quoi une réingestion écraserait l'une par
    l'autre et la collection perdrait la version réellement possédée.
    """
    return uuid.uuid5(NAMESPACE, f"print:{passcode}:{set_code}:{rarity}")


def illustration_uuid(image_id: int) -> uuid.UUID:
    """Identité d'une œuvre.

    La source numérote ses illustrations : une carte à deux illustrations porte
    deux entrées dans `card_images`, et 124 cartes sont dans ce cas. Deux
    impressions partageant une illustration partagent donc l'identifiant, et
    l'index ne la hachera qu'une fois — même usage que l'`illustration_id` de
    Scryfall.
    """
    return uuid.uuid5(NAMESPACE, f"art:{image_id}")


def fetch(lang: str | None = None) -> list[dict[str, Any]]:
    """Rapatrie le catalogue entier, en un appel."""
    url = BASE if lang in (None, "en") else f"{BASE}?language={lang}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)["data"]


def catalogue_version(cards: list[dict[str, Any]]) -> str:
    """Empreinte du catalogue, pour sauter une ingestion inutile.

    **La source ne publie aucun numéro de version.** Riftcodex non plus, mais
    Scryfall date ses exports et `ingestion_state` sait s'en servir. À défaut, on
    hache ce qu'on a reçu : deux passages sur un catalogue inchangé rendent la
    même empreinte, et le second ne réécrit rien.
    """
    digest = hashlib.sha256()
    for card in cards:
        digest.update(str(card["id"]).encode())
        digest.update(str(len(card.get("card_sets") or [])).encode())
    return f"{len(cards)}-{digest.hexdigest()[:16]}"


def type_line(card: dict[str, Any]) -> str:
    """Ligne de type lisible, sur le modèle de Magic.

    `humanReadableCardType` dit « Continuous Spell » là où `type` dit « Spell
    Card » ; `race` ajoute la famille (« Dragon », « Equip »), et `typeline` les
    sous-types d'un monstre. Les trois sont réunis parce que la recherche par
    type cherche une **sous-chaîne** : une carte doit répondre au filtre
    « Monster » comme au filtre « Synchro », ce qui est la lecture juste.
    """
    parts: list[str] = []

    def ajoute(valeur: str | None) -> None:
        # **On écarte ce qui est déjà dit, entier et non mot à mot.** Découper
        # les mots casserait les expressions figées : « Spell Card » et « Trap
        # Card » sont le vocabulaire officiel, et ce sont eux que le filtre de
        # recherche cherche — « Spell » seul attraperait les 700 monstres
        # Spellcaster, le filtre étant un ILIKE sur la ligne entière.
        if not valeur:
            return
        deja = " — ".join(parts).lower()
        if valeur.lower() not in deja:
            parts.append(valeur)

    ajoute(card.get("humanReadableCardType") or card["type"])
    ajoute(card.get("type"))
    sous = card.get("typeline")
    ajoute(" ".join(sous) if isinstance(sous, list) else sous or card.get("race"))
    return " — ".join(parts)


def is_physical(card: dict[str, Any]) -> bool:
    """La carte existe-t-elle sur du carton ?

    **Deux familles n'y sont pas**, et les garder polluerait une application qui
    ne parle que de collections physiques :

    - les 124 *Skill Cards*, qui appartiennent au jeu vidéo Duel Links — elles
      n'ont d'ailleurs même pas d'illustration détourée, la source rendant 404 ;
    - les 501 cartes sans aucune impression, jamais parues hors de l'anime.

    Les deux ensembles se recoupent ; le filtre retient environ 13 990 cartes.
    """
    if card.get("frameType") == "skill":
        return False
    return bool(card.get("card_sets"))


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
        for card in cards:
            level = card.get("level")
            yield (
                str(oracle_uuid(card["id"])),
                card["name"],
                # Le niveau occupe la place du coût : c'est ce qui gradue une
                # carte du jeu, et ce que l'utilisateur lit en haut du cadre.
                str(level) if level is not None else None,
                float(level) if level is not None else 0,
                type_line(card),
                card.get("desc"),
                # L'attribut (FEU, EAU, TÉNÈBRES…) occupe la place de l'identité
                # de couleur : même nature, même usage — restreindre ce qui se
                # joue ensemble.
                [card["attribute"]] if card.get("attribute") else [],
                "{}",
                # **`layout` porte le `frameType`**, exactement comme il porte
                # l'orientation en Riftbound : c'est lui qui dira quel gabarit
                # d'illustration appliquer au découpage. « pendulum » y apparaît
                # pour les 390 cartes dont l'illustration déborde.
                card.get("frameType"),
                GAME,
            )

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def write_prints(conn: psycopg.Connection, cards: list[dict[str, Any]]) -> int:
    """Écrit chaque impression, avec l'URL de sa carte entière."""
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE SET
            oracle_id        = EXCLUDED.oracle_id,
            set_code         = EXCLUDED.set_code,
            set_name         = EXCLUDED.set_name,
            collector_number = EXCLUDED.collector_number,
            printed_name     = EXCLUDED.printed_name,
            rarity           = EXCLUDED.rarity,
            art_crop_url     = EXCLUDED.art_crop_url,
            illustration_id  = EXCLUDED.illustration_id
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        for card in cards:
            image = (card.get("card_images") or [{}])[0]
            # **La carte entière, pas l'illustration détourée que la source
            # publie.** Elle conviendrait pour les cartes ordinaires, mais pour
            # une Pendulum elle englobe le pavé de texte : plutôt que deux
            # chemins selon le cadre, l'index découpe lui-même, exactement comme
            # l'application le fera sur une photo.
            art = image.get("image_url")
            art_id = image.get("id")
            seen: set[uuid.UUID] = set()
            for impression in card.get("card_sets") or []:
                code = impression["set_code"]
                rarity = impression.get("set_rarity") or ""
                key = print_uuid(code, rarity, card["id"])
                if key in seen:
                    continue
                seen.add(key)
                yield (
                    str(key),
                    str(oracle_uuid(card["id"])),
                    # Les impressions servies sont anglaises ; les rares
                    # exceptions portent leur langue dans le code, mais la
                    # source ne la déclare pas ailleurs.
                    "en",
                    card["name"],
                    # Le code d'extension est la partie avant le tiret :
                    # « JUSH-EN040 » paraît dans « Justice Hunters ».
                    code.split("-")[0],
                    impression.get("set_name"),
                    # Le numéro est ce qui suit la langue. Le garder entier
                    # dupliquerait l'extension dans chaque numéro et
                    # empêcherait tout rapprochement par (extension, numéro).
                    code.split("-", 1)[1] if "-" in code else None,
                    rarity or None,
                    art,
                    str(illustration_uuid(art_id)) if art_id else None,
                )

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def write_search_names(
    conn: psycopg.Connection, cards: list[dict[str, Any]], lang: str
) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable."""
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        seen: set[tuple[str, str]] = set()
        for card in cards:
            identity = str(oracle_uuid(card["id"]))
            normalized = normalize_name(card["name"])
            if (identity, normalized) in seen:
                continue
            seen.add((identity, normalized))
            yield (identity, card["name"], normalized, lang)

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def main() -> int:
    force = "--force" in sys.argv

    print("Rapatriement du catalogue Yu-Gi-Oh…")
    brut = fetch("en")
    cards = [c for c in brut if is_physical(c)]
    print(f"  {len(brut)} cartes reçues, {len(cards)} imprimées sur carton")

    version = catalogue_version(cards)
    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        if not force and last_version(conn, SOURCE) == version:
            print(f"  catalogue inchangé ({version}) — rien à faire")
            return 0

        identities = write_cards(conn, cards)
        print(f"  {identities} cartes écrites")
        prints = write_prints(conn, cards)
        print(f"  {prints} impressions écrites")

        total_names = 0
        for lang in LANGS:
            if lang != "en":
                time.sleep(PAUSE_SECONDS)
                traduites = [c for c in fetch(lang) if is_physical(c)]
            else:
                traduites = cards
            names = write_search_names(conn, traduites, lang)
            total_names += names
            print(f"  {names} noms indexés en « {lang} »")

        record(conn, SOURCE, version=version, items=identities)
        print(f"  {total_names} noms au total, état consigné ({version})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
