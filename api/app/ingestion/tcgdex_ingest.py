"""Ingestion du catalogue Pokémon depuis TCGdex.

**Le catalogue tient en deux requêtes, et c'est le moins cher des quatre jeux.**
L'API REST demanderait un appel par carte — 21 000 — mais le point GraphQL rend
le catalogue entier en une fois : **8,95 Mio en 1,5 seconde**, tous champs
utiles compris. Une seconde requête, en français, rapporte les noms traduits.
Yu-Gi-Oh tenait en un appel de 21 Mo ; celui-ci fait mieux.

Deux pièges de la source, tous deux mesurés :

- **le GraphQL se sert sans `pagination`.** L'argument existe et son resolveur
  est cassé (`value.indexOf is not a function`), quel que soit le champ demandé.
  Sans lui, tout passe ;
- **il faut un POST.** En GET, l'endpoint rend la page GraphiQL — 1,6 Mio de
  HTML qui ressemble à une réponse jusqu'à ce qu'on la parse.

**L'identité d'une carte est son identifiant TCGdex, pas son nom.** Mesuré :
**92 % des cartes de carton partagent leur nom avec une autre** — 112 Pikachu,
69 Évoli. Un Pikachu de 1999 et un de 2024 n'ont ni les mêmes attaques, ni les
mêmes PV, ni la même illustration : ce sont deux cartes, et les traiter comme
une seule en fusionnerait cent douze. C'est l'écueil inverse de Riftbound, où
l'identité se dérivait de champs d'affichage (#29) ; ici la source publie une
clé stable, `<set>-<numéro>`, qui est exactement ce que les decklists Limitless
citent.

**La conséquence est assumée et doit être dite.** Deux impressions d'un même
Dresseur, interchangeables en jeu, sont ici deux cartes : posséder l'une ne
comblera pas un deck qui demande l'autre. La complétion sera donc **sous-estimée**
plutôt que surestimée — le bon sens de l'erreur pour un outil qui annonce un coût.

**Ce qui n'entre pas** : la série `tcgp`, le jeu mobile *Pokémon TCG Pocket*,
dont les cartes n'existent pas sur carton — 2 480 cartes en 15 sets, écartées
par une propriété du set et non par une liste de raretés (#28).

**Conditions.** TCGdex ne publie pas les siennes : garde-fou §IV.9, on lui
applique celles de Scryfall. Aucune illustration n'est réhébergée ; seule l'URL
est stockée.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgdex_ingest
    #   --force   réécrit même si le catalogue n'a pas changé
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Iterator

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name
from app.ingestion.state import last_version, record

ENDPOINT = "https://api.tcgdex.net/v2/graphql"
USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

GAME = "pokemon"
SOURCE = "tcgdex"

#: Espace de noms des identifiants dérivés. Figé : le changer réécrirait tout le
#: catalogue sous de nouvelles clés et orphelinerait les collections.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/pokemon")

#: La série du jeu mobile. Une propriété du set, donc un filtre exact — là où le
#: vocabulaire de rareté mêle les deux jeux (#28).
POCKET_SERIE = "tcgp"

#: Ce que la carte porte, et qui sert à l'identifier ou à la ranger.
CARD_FIELDS = (
    "id localId name category rarity illustrator image hp types stage suffix "
    "regulationMark energyType trainerType set{id name cardCount{official total}}"
)

#: Reprises à attente croissante : ce poste perd le réseau par à-coups.
ATTEMPTS = 5


def ask(query: str, lang: str = "en") -> dict[str, Any]:
    """Interroge le point GraphQL. **En POST** — voir l'en-tête du module."""
    delay = 1.0
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(
            ENDPOINT,
            data=json.dumps({"query": query}).encode("utf-8"),
            headers={
                "User-Agent": USER_AGENT,
                "Content-Type": "application/json",
                # La langue se choisit par l'en-tête ; le même document rend
                # alors les noms traduits, sans seconde API.
                "Accept-Language": lang,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if payload.get("errors"):
                raise RuntimeError(json.dumps(payload["errors"])[:300])
            return payload["data"]
        except Exception as exc:  # réseau coupé, TLS, réponse partielle
            last = exc
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"TCGdex injoignable : {last}")


def french_names() -> dict[str, str]:
    """Les noms français, par identifiant de carte.

    **La langue passe par le chemin, pas par un en-tête.** `Accept-Language` est
    sans effet sur le point GraphQL : la première version l'a essayé et a écrit
    zéro nom français sans lever la moindre erreur — le pire mode de défaillance,
    puisqu'un catalogue amputé de sa moitié française se lit comme un catalogue
    complet. La route REST `/v2/fr/cards`, elle, rend 21 554 noms en une requête.

    Que le français compte n'est pas un agrément : la reconnaissance lit du
    carton français, et un nom qu'on ne peut pas chercher est une carte qu'on ne
    peut pas saisir au clavier.
    """
    delay = 1.0
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(
            "https://api.tcgdex.net/v2/fr/cards",
            headers={"User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                rows = json.loads(response.read().decode("utf-8"))
            return {r["id"]: r["name"] for r in rows if r.get("name")}
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"noms français injoignables : {last}")


def oracle_uuid(card_id: str) -> uuid.UUID:
    """Identité d'une carte, dérivée de sa clé TCGdex.

    Déterministe : une réingestion retombe sur les mêmes clés et met à jour au
    lieu de dupliquer.
    """
    return uuid.uuid5(NAMESPACE, card_id)


def physical_sets(sets: list[dict[str, Any]]) -> set[str]:
    """Les sets qui existent sur carton — tout sauf la série du jeu mobile."""
    return {
        s["id"]
        for s in sets
        if (s.get("serie") or {}).get("id") != POCKET_SERIE
    }


def art_layout(card: dict[str, Any]) -> str:
    """Quel gabarit d'illustration cette carte demande.

    **Mesuré par #28**, et rangé dans `layout` comme Riftbound y range son
    orientation et Yu-Gi-Oh son `frameType` : c'est la donnée qui dit au
    découpage quelle fenêtre appliquer.

    L'ordre des tests n'est pas indifférent. **Le numéro tranche avant la
    marque** : 684 cartes pleine page portent aussi un `suffix` ou un `stage`,
    et lire la marque d'abord les rangerait parmi les encadrées, où elles n'ont
    pas de cadre.
    """
    if card.get("energyType") == "Normal":
        # Une énergie de base n'a pas d'illustration : elle sera écartée de
        # l'index d'empreintes, où elle ne produirait que des collisions —
        # 97,1 % ont une jumelle sous le seuil de confiance, 12 % seraient
        # annoncées à tort avec assurance.
        return "energy"

    number = card.get("localId") or ""
    official = ((card.get("set") or {}).get("cardCount") or {}).get("official") or 0
    if number.isdigit() and official > 0 and int(number) > official:
        return "full"

    category = card.get("category")
    if category == "Trainer":
        return "trainer"
    if category == "Energy":
        # Énergie spéciale : elle a bien une illustration, contrairement à sa
        # cousine de base. `category` seul aurait écarté 196 cartes illustrées.
        return "special-energy"
    return "pokemon"


def type_line(card: dict[str, Any]) -> str:
    """Ligne de type lisible, dans l'esprit de celle de Magic."""
    parts: list[str] = [card.get("category") or "Pokemon"]
    detail = [
        p
        for p in (
            card.get("stage"),
            card.get("suffix"),
            card.get("trainerType"),
            " ".join(card.get("types") or []),
        )
        if p
    ]
    return f"{parts[0]} — {' '.join(detail)}" if detail else parts[0]


def catalogue_version(cards: list[dict[str, Any]]) -> str:
    """Empreinte du catalogue, pour sauter une réingestion inutile."""
    digest = hashlib.sha256()
    for card in sorted(cards, key=lambda c: c["id"]):
        digest.update(f"{card['id']}|{card.get('rarity')}|{card.get('name')}".encode())
    return digest.hexdigest()


def write_cards(conn: psycopg.Connection, cards: list[dict[str, Any]]) -> int:
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
            color_identity = EXCLUDED.color_identity,
            layout         = EXCLUDED.layout,
            game           = EXCLUDED.game,
            updated_at     = NOW()
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        for card in cards:
            hp = card.get("hp")
            yield (
                str(oracle_uuid(card["id"])),
                card["name"],
                # **Les PV occupent la place du coût.** Ce jeu n'a pas de coût
                # d'invocation ; les PV sont ce que l'utilisateur lit en haut du
                # cadre, et la seule grandeur numérique qui gradue une carte.
                str(hp) if hp is not None else None,
                float(hp) if hp is not None else 0,
                type_line(card),
                None,
                # Le type d'énergie occupe la place de l'identité de couleur :
                # même nature, même usage — c'est lui qui décide de l'énergie
                # qu'un deck doit embarquer.
                card.get("types") or [],
                "{}",
                art_layout(card),
                GAME,
            )

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def write_prints(
    conn: psycopg.Connection,
    cards: list[dict[str, Any]],
    french: dict[str, str],
) -> int:
    """Une impression par carte.

    **Les finitions ne font pas des lignes.** TCGdex distingue `normal`,
    `reverse` et `holo` ; le modèle porte déjà la finition sur la ligne de
    collection (`is_foil`), comme pour les trois autres jeux. En faire des
    impressions séparées tripleraient le catalogue pour une information que la
    collection porte mieux.
    """
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
            identity = oracle_uuid(card["id"])
            image = card.get("image")
            card_set = card.get("set") or {}
            yield (
                str(identity),
                str(identity),
                # Le nom français quand la source en a un ; sinon l'anglais.
                # La langue déclarée suit ce qui est réellement écrit.
                "fr" if card["id"] in french else "en",
                french.get(card["id"], card["name"]),
                card_set.get("id"),
                card_set.get("name"),
                card.get("localId"),
                card.get("rarity"),
                # **L'URL de base, sans qualité ni extension.** La source la
                # complète à l'usage (`/high.webp`), et figer une qualité ici
                # obligerait à réécrire le catalogue pour en changer.
                image,
                # L'illustration n'a pas d'identifiant propre chez cette source ;
                # la carte étant son unique impression, sa clé fait l'affaire et
                # garde l'invariant « une empreinte par illustration ».
                str(identity) if image else None,
            )

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def write_search_names(
    conn: psycopg.Connection, cards: list[dict[str, Any]], french: dict[str, str]
) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable.

    **Un nom désigne ici des dizaines de cartes** — 112 Pikachu —, et c'est
    voulu : la recherche par nom doit toutes les rendre, à charge pour
    l'utilisateur de choisir. C'est l'inverse de Magic, où un nom désigne une
    carte et une seule.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    def rows() -> Iterator[tuple[Any, ...]]:
        for card in cards:
            identity = str(oracle_uuid(card["id"]))
            yield (identity, card["name"], normalize_name(card["name"]), "en")
            translated = french.get(card["id"])
            if translated and translated != card["name"]:
                yield (identity, translated, normalize_name(translated), "fr")

    batch = list(rows())
    with conn.cursor() as cur:
        cur.executemany(statement, batch)
        conn.commit()
    return len(batch)


def run(force: bool) -> int:
    print("catalogue Pokémon — TCGdex")
    sets = ask("{sets{id serie{id}}}")["sets"]
    physical = physical_sets(sets)
    print(f"  {len(sets)} sets, dont {len(physical)} sur carton")

    everything = ask("{cards{%s}}" % CARD_FIELDS)["cards"]
    cards = [c for c in everything if (c.get("set") or {}).get("id") in physical]
    print(f"  {len(everything)} cartes, dont {len(cards)} sur carton")

    version = catalogue_version(cards)
    french = french_names()
    translated = sum(
        1
        for c in cards
        if french.get(c["id"]) and french[c["id"]] != c["name"]
    )
    print(f"  {translated} noms français")

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        if not force and last_version(conn, SOURCE) == version:
            print('  catalogue inchangé — rien à faire')
            return 0
        written = write_cards(conn, cards)
        print(f"  {written} cartes écrites")
        prints = write_prints(conn, cards, french)
        print(f"  {prints} impressions écrites")
        names = write_search_names(conn, cards, french)
        print(f"  {names} noms indexés")
        record(conn, SOURCE, version=version, items=written)

    layouts: dict[str, int] = {}
    for card in cards:
        key = art_layout(card)
        layouts[key] = layouts.get(key, 0) + 1
    print("  gabarits : " + ", ".join(f"{k} {v}" for k, v in sorted(layouts.items())))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Catalogue Pokémon (TCGdex)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        return run(args.force)
    except KeyboardInterrupt:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
