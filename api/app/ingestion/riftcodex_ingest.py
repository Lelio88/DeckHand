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


#: Le nom porte souvent le champion en préfixe, mais pas toujours, et pas avec le
#: même séparateur : « Ambessa - Matriarch of War », « Lux, Crownguard »,
#: « Matriarch of War » tout court. Le tiret est essayé d'abord, sans quoi
#: « Yordle, Kennen - Heart of the Tempest » se couperait après « Yordle ».
_PREFIXE = re.compile(
    r"^(?P<avant>.+?)\s+-\s+(?P<titre>.+)$|^(?P<avant2>[^,]+),\s+(?P<titre2>.+)$"
)


def _decoupe(name: str) -> tuple[str | None, str]:
    """(préfixe, titre) si le nom en porte un, sinon (None, nom)."""
    m = _PREFIXE.match(name)
    if not m:
        return None, name
    if m.group("titre"):
        return m.group("avant"), m.group("titre")
    return m.group("avant2"), m.group("titre2")


def champion_names(cards: list[dict[str, Any]]) -> frozenset[str]:
    """Le vocabulaire des champions, déduit du catalogue lui-même.

    Ce sont les jetons qui apparaissent en préfixe de nom, coupés sur les deux
    séparateurs — « Yordle, Kennen - … » en fournit deux. Mesuré : 100 noms.

    **Pourquoi un vocabulaire plutôt que les tags bruts.** Les tags mélangent
    champions, régions et tribus (« Demacia », « Sentinel », « Yordle »), et ils
    **varient d'une impression à l'autre** : « Vayne - Hunter » gagne un tag
    « Sentinel » en VEN. Prendre l'ensemble des tags comme identité rendrait donc
    la carte instable ; l'intersecter avec ce vocabulaire ne garde que ce que la
    source dit de stable.
    """
    noms: set[str] = set()
    for card in cards:
        prefixe = _decoupe(base_name(card["name"]))[0]
        if prefixe:
            noms |= {t.strip() for t in re.split(r",|\s-\s", prefixe) if t.strip()}
    return frozenset(noms)


def oracle_uuid(card: dict[str, Any], champions: frozenset[str]) -> uuid.UUID:
    """Identité d'une carte : titre + type + champion.

    **Le triplet nom + type + texte, employé jusqu'ici, reposait sur deux champs
    d'affichage instables**, et enregistrait donc la même carte plusieurs fois.

    Le *nom* varie de deux façons : le champion y est tantôt présent tantôt
    absent (« Ambessa - Matriarch of War » / « Matriarch of War »), et son
    séparateur change d'une extension à l'autre (« Lux - Crownguard » en OGS,
    « Lux, Crownguard » en VEN). Le *texte* varie davantage encore : l'extension
    VEN retire les rappels de règles entre parenthèses, la source écrit tantôt
    `''` tantôt `'[NO TEXT]'` pour une carte sans texte, mêle apostrophes droites
    et typographiques, entités HTML (`[&gt;]`) et flèches, et reformule au
    passage (« Sand Soldiers you play have » → « Your Sand Soldiers have »).

    Mesuré sur les 1 451 entrées du catalogue : **87 identités nouvelles en
    réunissent 192 anciennes**, soit 105 cartes de trop. Le nom seul en explique
    5, le **texte seul 63**, les deux ensemble 19. L'issue #29 n'avait relevé que
    les 24 groupes visibles au nom : les trois quarts du défaut tenaient au
    texte, et aucune normalisation de nom ne les aurait touchés.

    **Le champion vient des tags, pas du nom** — voir [champion_names]. Il est
    nécessaire : trois titres sont portés par deux champions différents, et ce
    sont bien deux cartes (« Rumble - Hotheaded » et « Vi - Hotheaded »,
    « Vayne - Hunter » et « Warwick - Hunter », « Fiora - Victorious » et
    « Qiyana - Victorious »). Le titre seul les confondrait.

    **Trois pistes mesurées puis écartées :**

    - `riftbound_id` (« ven-190-166 ») ressemble à un identifiant de carte ; son
      dernier segment ne prend que **13 valeurs** sur tout le catalogue et
      regroupe des centaines de cartes sans rapport. C'est un code de produit.
    - le titre seul fusionne les trois paires ci-dessus.
    - l'ensemble des tags dédouble « Vayne - Hunter », dont le tag « Sentinel »
      n'apparaît qu'en VEN.

    Vérifié dans les deux sens : la règle réunit les dix groupes mesurés comme
    une seule carte, sépare les trois paires dangereuses, et **aucune identité
    n'y recouvre deux titres ou deux types**.
    """
    titre = _decoupe(base_name(card["name"]))[1]
    champion = "+".join(sorted(set(card.get("tags") or []) & champions))
    key = "|".join((titre, card["classification"]["type"] or "", champion))
    return uuid.uuid5(NAMESPACE, f"card:{key}")


def display_name(names: list[str]) -> str:
    """Le nom retenu pour une identité qui en porte plusieurs.

    Le plus long, à égalité le premier dans l'ordre alphabétique : c'est celui
    qui porte le champion, donc le plus informatif, et la règle est déterministe
    là où « le dernier écrit gagne » dépendait de l'ordre de pagination.

    Les autres orthographes ne sont pas perdues : `write_search_names` les indexe
    toutes, et la carte reste trouvable sous chacune.
    """
    return min(names, key=lambda n: (-len(n), n))


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


def write_cards(
    conn: psycopg.Connection,
    cards: list[dict[str, Any]],
    champions: frozenset[str],
) -> int:
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
        # Les noms de toute l'identité sont connus avant d'en écrire une seule
        # ligne : c'est ce qui permet de choisir le plus informatif plutôt que
        # de laisser gagner celui qui passe en dernier.
        noms: dict[uuid.UUID, list[str]] = {}
        for card in cards:
            noms.setdefault(oracle_uuid(card, champions), []).append(
                base_name(card["name"])
            )

        seen: set[uuid.UUID] = set()
        for card in cards:
            identity = oracle_uuid(card, champions)
            if identity in seen:
                continue
            seen.add(identity)
            energy = (card.get("attributes") or {}).get("energy")
            yield (
                str(identity),
                display_name(noms[identity]),
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


def tcgplayer_id(card: dict[str, Any]) -> int | None:
    """Identifiant marchand de l'impression, ou None.

    **Le seul chaînage vers un prix que la source offre.** Riftcodex ne cote
    rien ; ce numéro désigne la même impression chez un marchand qui, lui, cote.
    Il était reçu et jeté faute de colonne où l'écrire.

    Servi comme chaîne de chiffres, converti en entier pour tenir dans la même
    colonne que l'identifiant homonyme de Scryfall. Une valeur qui ne serait pas
    numérique est ignorée plutôt que de faire échouer l'ingestion entière : sans
    identifiant, l'impression reste parfaitement utilisable, simplement non
    cotée — c'est déjà le cas des 227 cartes de l'extension `VEN`.
    """
    raw = card.get("tcgplayer_id")
    if raw is None:
        return None
    try:
        return int(str(raw).strip())
    except ValueError:
        return None


def write_prints(
    conn: psycopg.Connection,
    cards: list[dict[str, Any]],
    champions: frozenset[str],
) -> int:
    """Écrit chaque impression, avec l'URL de son visuel officiel."""
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id,
                                        tcgplayer_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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
            illustration_id  = EXCLUDED.illustration_id,
            -- **COALESCE et non EXCLUDED seul.** Une extension trop récente
            -- n'a pas encore d'identifiant marchand ; le jour où elle en
            -- reçoit un, il s'écrit. Mais une réponse tronquée ne doit pas
            -- effacer un identifiant déjà connu.
            tcgplayer_id     = COALESCE(EXCLUDED.tcgplayer_id,
                                        public.card_prints.tcgplayer_id)
    """

    written = 0
    with conn.cursor() as cur:
        for card in cards:
            number = card.get("collector_number")
            cur.execute(
                statement,
                (
                    str(print_uuid(card)),
                    str(oracle_uuid(card, champions)),
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
                    tcgplayer_id(card),
                ),
            )
            written += 1
        conn.commit()
    return written


def write_search_names(
    conn: psycopg.Connection,
    cards: list[dict[str, Any]],
    champions: frozenset[str],
) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable.

    **Toutes les orthographes y entrent**, y compris celles que l'identité
    réunit désormais : une carte enregistrée « Matriarch of War » dans une
    extension et « Ambessa - Matriarch of War » dans une autre reste trouvable
    sous les deux, et pointe la même carte.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """

    written = 0
    with conn.cursor() as cur:
        seen: set[tuple[str, str]] = set()
        for card in cards:
            identity = str(oracle_uuid(card, champions))
            normalized = normalize_name(base_name(card["name"]))
            if (identity, normalized) in seen:
                continue
            seen.add((identity, normalized))
            cur.execute(statement, (identity, base_name(card["name"]), normalized, "en"))
            written += 1
        conn.commit()
    return written


def realign_art_hashes(conn: psycopg.Connection) -> int:
    """Fait suivre l'identité aux empreintes déjà calculées.

    `art_hashes` porte l'impression **et** la carte. L'impression ne bouge pas —
    son identifiant vient de la source —, mais la carte, si : c'est tout l'objet
    d'un changement de règle d'identité. Sans ce recalage, les empreintes
    resteraient rattachées à l'ancienne carte et disparaîtraient avec elle en
    cascade — 1 193 illustrations à retélécharger pour rien, chez une source
    qu'on s'est engagé à ménager.

    L'ordre compte : à jouer **après** `write_prints`, qui est ce qui repointe
    les impressions.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE public.art_hashes h
               SET oracle_id = p.oracle_id
              FROM public.card_prints p
             WHERE p.scryfall_id = h.scryfall_id
               AND h.oracle_id IS DISTINCT FROM p.oracle_id
            """
        )
        moved = cur.rowcount
        conn.commit()
    return moved


def prune_orphans(conn: psycopg.Connection) -> tuple[int, int]:
    """Supprime les cartes Riftbound qu'aucune impression ne porte plus.

    **Une règle d'identité qui change laisse des cartes derrière elle.** Les
    impressions se repointent d'elles-mêmes (`write_prints` réécrit leur
    `oracle_id`), mais les anciennes identités restent en base, sans impression,
    et continueraient d'apparaître en recherche.

    La suppression est **conditionnelle, et c'est le point délicat** : les decks
    et les collections référencent `oracle_id` sans cascade. Une orpheline encore
    citée est donc conservée plutôt que de faire échouer l'ingestion — le remède
    est de rejouer l'ingestion des decks, qui les repointera, puis de relancer.

    Rend (supprimées, conservées faute de pouvoir l'être).
    """
    orpheline = """
        SELECT c.oracle_id FROM public.cards c
        WHERE c.game = %s
          AND NOT EXISTS (SELECT 1 FROM public.card_prints p
                          WHERE p.oracle_id = c.oracle_id)
    """
    citee = """
        AND (EXISTS (SELECT 1 FROM public.deck_cards d WHERE d.oracle_id = c.oracle_id)
          OR EXISTS (SELECT 1 FROM public.collection_items i WHERE i.oracle_id = c.oracle_id)
          OR EXISTS (SELECT 1 FROM public.decks k
                     WHERE k.commander_oracle_id = c.oracle_id))
    """
    with conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM ({orpheline} {citee}) t", (GAME,))
        retenues = cur.fetchone()[0]
        cur.execute(
            f"DELETE FROM public.cards WHERE oracle_id IN "
            f"(SELECT oracle_id FROM ({orpheline}) o "
            f" WHERE NOT EXISTS (SELECT 1 FROM public.deck_cards d"
            f"                   WHERE d.oracle_id = o.oracle_id)"
            f"   AND NOT EXISTS (SELECT 1 FROM public.collection_items i"
            f"                   WHERE i.oracle_id = o.oracle_id)"
            f"   AND NOT EXISTS (SELECT 1 FROM public.decks k"
            f"                   WHERE k.commander_oracle_id = o.oracle_id))",
            (GAME,),
        )
        supprimees = cur.rowcount
        conn.commit()
    return supprimees, retenues


def main() -> int:
    print("Rapatriement du catalogue Riftbound…")
    cards = fetch_all()
    print(f"  {len(cards)} cartes reçues")
    champions = champion_names(cards)
    print(f"  {len(champions)} champions au vocabulaire")

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        identities = write_cards(conn, cards, champions)
        print(f"  {identities} cartes distinctes écrites")
        prints = write_prints(conn, cards, champions)
        print(f"  {prints} impressions écrites")
        names = write_search_names(conn, cards, champions)
        print(f"  {names} noms indexés")
        moved = realign_art_hashes(conn)
        print(f"  {moved} empreintes recalées sur leur carte")
        supprimees, retenues = prune_orphans(conn)
        print(f"  {supprimees} cartes orphelines supprimées")
        if retenues:
            print(
                f"  {retenues} orphelines conservées : encore citées par un deck "
                f"ou une collection\n"
                f"    rejouer « python -m app.ingestion.topdeck_ingest --riftbound » "
                f"puis relancer cette ingestion"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
