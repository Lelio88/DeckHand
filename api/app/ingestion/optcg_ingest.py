"""Catalogue One Piece, depuis OPTCG API.

**Pourquoi cette source, et pas les deux autres.** Trois catalogues relevés,
`robots.txt` en main — la vérification que le garde-fou §IV impose avant toute
dépendance : **apitcg.com** publie `Disallow: /api/`, l'API qui servirait étant
nommément interdite (le motif qui avait écarté piltoverarchive) ;
**onepiece-cardgame.dev** répond par une page Cloudflare « Just a moment… »,
c'est-à-dire une détection de robot qu'on ne contourne pas ; **optcgapi.com** ne
publie ni conditions ni `robots.txt` et documente son API — §IV.9, conditions de
Scryfall.

**Le catalogue se lit par deux portes, et l'oublier en couperait un huitième.**
Les 21 extensions viennent de `/allSets/` ; les **29 decks de démarrage** ont
leur propre chemin, et `/sets/ST-01/` répond « Card was not found! ». Ce sont
507 entrées et **286 codes que rien d'autre n'apporte** — or les decklists de
tournoi les citent couramment, `ST32` apparaissant dès le premier deck relevé
chez Limitless.

**L'identité est le code, et la source suffixe aussi les noms.** `card_set_id`
(`OP01-077`) désigne la carte ; `card_image_id` (`OP01-077_p1`) désigne
l'impression. Le nom, lui, porte des suffixes qui s'empilent — « Donquixote
Doflamingo (073) (Parallel) », « Buggy - OP03-008 (Pirate Foil) » — et n'en
retirer qu'un faisait conclure que 316 codes réunissaient deux cartes
différentes. Après les deux règles de retrait, il en reste **quatre**, et ce sont
des fautes de la source : une entrée « Buggy » rangée sous le code de
Zoro-Juurou, un tiret sans espace, un suffixe qui est un nom d'extension, et une
coquille — « Sakazuk » pour « Sakazuki ».

**Le vocabulaire des variantes a deux lettres** : `_p1` à `_p8` et `_r1` à
`_r3`, soit 1 439 entrées. N'en lire qu'une en manquait 335.

**Ce jeu compte 361 noms portés par plusieurs cartes** — « Monkey.D.Luffy » en
désigne 62 —, et 114 de ces groupes ne se séparent ni par le type, ni par la
couleur, ni par le coût. C'est bien au-delà des 80 homonymes de Riftbound, et
cela commande la suite : la reconnaissance devra s'appuyer sur l'empreinte, et
la saisie montrer les vignettes.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.optcg_ingest
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any, Iterable

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name

GAME = "onepiece"

BASE = "https://optcgapi.com/api"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Espace de noms des identifiants dérivés. **Figé** : le changer réécrirait
#: tout le catalogue sous de nouvelles clés et orphelinerait les collections
#: déjà saisies.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/onepiece")

PAUSE_SECONDS = 0.4
ATTEMPTS = 5
FIRST_DELAY = 1.0

#: Suffixes de variante dans le nom. **Ils s'empilent**, d'où le `+`.
VARIANT_SUFFIX = re.compile(r"(\s*\([^)]*\))+\s*$")

#: Le code accolé par un tiret **entouré d'espaces** — « Buggy - OP03-008 ».
#: Les espaces protègent les noms qui portent un tiret, « Zoro-Juurou » en tête.
VARIANT_CODE_SUFFIX = re.compile(r"\s+-\s+[A-Z]{1,4}\d*-\d+\s*$")

#: Suffixe d'identifiant de rendu : `_p1` à `_p8`, `_r1` à `_r3`.
PRINT_SUFFIX = re.compile(r"_[a-z]\d+$")


class IngestError(RuntimeError):
    """La source n'a pas répondu, malgré les reprises."""


def _fetch(url: str) -> bytes:
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise IngestError(f"{url} : introuvable (404)") from exc
            last = exc
        except Exception as exc:
            last = exc
        time.sleep(delay)
        delay *= 2
    raise IngestError(f"{url} : {last}")


def _json(path: str) -> Any:
    payload = _fetch(f"{BASE}/{path}")
    time.sleep(PAUSE_SECONDS)
    return json.loads(payload.decode("utf-8"))


@dataclass(frozen=True)
class Entry:
    """Une entrée du catalogue, telle que la source la publie."""

    origin: str
    code: str
    image_id: str
    name: str
    type: str
    color: str
    cost: str
    power: str
    rarity: str
    text: str
    subtypes: str
    image: str

    @property
    def base_name(self) -> str:
        """Le nom sans ses suffixes de variante — deux motifs, trois passes."""
        name = VARIANT_SUFFIX.sub("", self.name).strip()
        name = VARIANT_CODE_SUFFIX.sub("", name).strip()
        return VARIANT_SUFFIX.sub("", name).strip()

    @property
    def is_variant(self) -> bool:
        return bool(PRINT_SUFFIX.search(self.image_id or ""))

    @property
    def oracle_id(self) -> uuid.UUID:
        """L'identité de la **carte** : son code imprimé.

        Pas le nom : 361 noms sont portés par plusieurs cartes, et
        « Monkey.D.Luffy » en désigne 62. Les fusionner par le nom en ferait une
        seule — c'est le piège que Pokémon a posé de la même façon, avec 92 %
        de ses cartes partageant leur nom.
        """
        return uuid.uuid5(NAMESPACE, self.code)

    @property
    def print_key(self) -> uuid.UUID:
        """L'identité de l'**impression** : son identifiant de rendu.

        56 entrées le partagent — les cartes qu'un deck de démarrage réédite à
        l'identique, `OP02-018` paraissant dans `OP-02` et dans `ST-15`. Ce sont
        bien deux impressions du même carton, et non deux cartons : l'image est
        la même, et le pliage les réunit.
        """
        return uuid.uuid5(NAMESPACE, f"print|{self.image_id}")

    @property
    def colors(self) -> list[str]:
        """Les couleurs, **séparées par un espace** chez cette source.

        Une première version découpait sur une barre oblique, et le séparateur
        était supposé et non relevé. Le découpage ne s'appliquait donc jamais :
        les 96 cartes bicolores entraient en base sous la forme d'une couleur
        unique nommée « Blue Green », et 313 decks se retrouvaient avec un leader
        dont l'identité n'était incluse dans celle d'aucune carte.

        **Rien ne le signalait.** Le catalogue paraissait complet — 100 % des
        cartes portaient une couleur —, et l'inventaire des identités affichait
        `['Green Red']: 8` d'une façon qui se lisait « huit cartes bicolores ».
        Le défaut n'est apparu qu'en mesurant la part d'un deck hors de
        l'identité de son leader : **médiane 100 %** avec 36,5 % des decks à 0 %,
        une distribution binaire qu'aucune règle de jeu ne produit.

        Ce que ça aurait coûté : la contrainte de couleur est ce qui empêche le
        constructeur de proposer un deck illégal. Inexploitable, elle aurait
        laissé mêler six couleurs dans un jeu qui n'en autorise que deux.
        """
        return [c.strip() for c in (self.color or "").split() if c.strip()]


def parse(row: dict, origin: str) -> Entry:
    return Entry(
        origin=origin,
        code=(row.get("card_set_id") or "").strip(),
        image_id=(row.get("card_image_id") or "").strip(),
        name=(row.get("card_name") or "").strip(),
        type=(row.get("card_type") or "").strip(),
        color=(row.get("card_color") or "").strip(),
        cost=str(row.get("card_cost") or ""),
        power=str(row.get("card_power") or ""),
        rarity=(row.get("rarity") or "").strip(),
        text=(row.get("card_text") or "").strip(),
        subtypes=(row.get("sub_types") or "").strip(),
        image=(row.get("card_image") or "").strip(),
    )


def fetch_catalogue() -> tuple[list[Entry], dict[str, str], list[str]]:
    """Les deux parcours, les noms d'origine, et les origines injoignables."""
    entries: list[Entry] = []
    names: dict[str, str] = {}
    unreachable: list[str] = []

    sets = _json("allSets/")
    decks = _json("allDecks/")
    print(f"  {len(sets)} extensions, {len(decks)} decks de démarrage")

    for entry in sets:
        code = entry.get("set_id")
        if not code:
            continue
        names[code] = entry.get("set_name") or code
        try:
            entries.extend(parse(row, code) for row in _json(f"sets/{code}/"))
        except IngestError as exc:
            print(f"  extension {code} injoignable : {exc}")
            unreachable.append(code)

    for entry in decks:
        code = entry.get("structure_deck_id")
        if not code:
            continue
        names[code] = entry.get("structure_deck_name") or code
        try:
            entries.extend(parse(row, code) for row in _json(f"decks/{code}/"))
        except IngestError as exc:
            print(f"  deck {code} injoignable : {exc}")
            unreachable.append(code)

    return entries, names, unreachable


@dataclass(frozen=True)
class Card:
    """Une carte, telle qu'elle entrera dans `cards`."""

    oracle_id: uuid.UUID
    code: str
    name: str
    type_line: str
    text: str
    colors: tuple[str, ...]
    cost: str
    layout: str


def fold_cards(entries: Iterable[Entry]) -> list[Card]:
    """Réunit les entrées en cartes, par code.

    **L'entrée ordinaire est prioritaire** pour les champs d'affichage : son nom
    est celui de la carte, sans suffixe de tirage. Une variante rencontrée la
    première ne doit pas imposer « Perona (Box Topper) » comme nom de la carte.
    """
    def build(entry: Entry) -> Card:
        type_line = entry.type
        if entry.subtypes:
            type_line = f"{entry.type} — {entry.subtypes}"
        return Card(
            oracle_id=entry.oracle_id,
            code=entry.code,
            name=entry.base_name,
            type_line=type_line,
            text=entry.text,
            colors=tuple(entry.colors),
            cost=entry.cost,
            layout=entry.type,
        )

    # Deux passes plutôt qu'une condition à plusieurs négations : les entrées
    # ordinaires d'abord, les variantes ensuite et seulement pour les codes que
    # la première passe n'a pas couverts. Une carte qui n'existe que sous un
    # tirage alternatif garde ainsi une entrée, sans qu'une variante rencontrée
    # tôt puisse imposer son nom à une carte qui en a un propre.
    seen: dict[uuid.UUID, Card] = {}
    for entry in entries:
        if entry.code and not entry.is_variant and entry.oracle_id not in seen:
            seen[entry.oracle_id] = build(entry)
    for entry in entries:
        if entry.code and entry.oracle_id not in seen:
            seen[entry.oracle_id] = build(entry)
    return list(seen.values())


@dataclass
class Printing:
    """Une impression, une fois les rééditions réunies."""

    key: uuid.UUID
    oracle_id: uuid.UUID
    origin: str
    code: str
    image_id: str
    printed_name: str
    rarity: str
    image: str


def fold_printings(entries: Iterable[Entry]) -> list[Printing]:
    """Réunit les entrées en impressions, par identifiant de rendu."""
    folded: dict[uuid.UUID, Printing] = {}
    for entry in entries:
        if not entry.code or not entry.image_id:
            continue
        if entry.print_key in folded:
            continue
        folded[entry.print_key] = Printing(
            key=entry.print_key,
            oracle_id=entry.oracle_id,
            origin=entry.origin,
            code=entry.code,
            image_id=entry.image_id,
            # Le nom tel que la source le publie pour ce tirage — **toujours**,
            # et pas seulement quand il diffère du nom de la carte.
            #
            # Il sert deux choses. À l'écran, il dit quelle version on possède,
            # comme le `printed_name` de Riftbound porte « (Alternate Art) ». Et
            # il est la **clé de rapprochement des prix** : TCGplayer distingue
            # les variantes par le nom du produit, avec les mêmes suffixes —
            # « Trafalgar Law (002) » et « … (Parallel) » y sont deux produits.
            # Sans le nom de l'entrée ordinaire, le prix d'un Box Topper à 45 $
            # irait sur la carte ordinaire à 0,94 $.
            printed_name=entry.name,
            rarity=entry.rarity,
            image=entry.image,
        )
    return list(folded.values())


def write_cards(conn: psycopg.Connection, cards: Iterable[Card]) -> int:
    statement = """
        INSERT INTO public.cards (oracle_id, name, type_line, oracle_text,
                                  color_identity, cmc, layout, game, updated_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (oracle_id) DO UPDATE SET
            name           = EXCLUDED.name,
            type_line      = EXCLUDED.type_line,
            oracle_text    = EXCLUDED.oracle_text,
            color_identity = EXCLUDED.color_identity,
            cmc            = EXCLUDED.cmc,
            layout         = EXCLUDED.layout,
            game           = EXCLUDED.game,
            updated_at     = NOW()
    """
    rows = [
        (
            str(card.oracle_id),
            card.name,
            card.type_line,
            card.text,
            list(card.colors),
            _as_number(card.cost),
            card.layout,
            GAME,
        )
        for card in cards
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def _as_number(value: str) -> float:
    """Le coût en DON!!, ou zéro.

    **Le zéro est imposé par le schéma, pas choisi** : `cards.cmc` est
    `NOT NULL DEFAULT 0`. Les 285 Leaders n'ont pas de coût — on ne les joue
    pas, on commence la partie avec —, et leur zéro se lira « gratuit ». Même
    limite que les Bases de SWU, et de même ampleur : le constructeur les traite
    par leur type.
    """
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def write_prints(
    conn: psycopg.Connection, printings: Iterable[Printing], names: dict[str, str]
) -> int:
    """Écrit les impressions.

    `art_crop_url` désigne la carte **entière** : la source ne publie pas
    d'illustration détourée, et le découpage appartient au calcul d'empreinte.
    Ce découpage devra s'arrêter au filigrane « SAMPLE » que l'éditeur incruste
    — la fenêtre mesurée le fait.

    `price_eur` reste hors de la requête : les prix viennent de TCGCSV, par un
    connecteur distinct.
    """
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id)
        VALUES (%s, %s, 'en', %s, %s, %s, %s, %s, %s, %s)
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
    rows = [
        (
            str(printing.key),
            str(printing.oracle_id),
            printing.printed_name or None,
            printing.origin,
            names.get(printing.origin) or printing.origin,
            # Le numéro imprimé, extrait du code : « OP01-077 » → « 077 ».
            printing.code.split("-", 1)[-1],
            printing.rarity or None,
            printing.image or None,
            # L'illustration se dérive de son identifiant de rendu : deux
            # impressions qui partagent le même rendu partagent la même
            # empreinte, et l'index n'aura à la calculer qu'une fois.
            str(uuid.uuid5(NAMESPACE, printing.image_id)),
        )
        for printing in printings
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def write_search_names(conn: psycopg.Connection, cards: Iterable[Card]) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable.

    **Un même nom désigne souvent plusieurs cartes ici**, et c'est voulu :
    « Monkey.D.Luffy » en désigne 62. L'unicité porte sur le couple carte-nom,
    pas sur le nom, et la recherche rendra bien les 62 — c'est à l'utilisateur
    de trancher sur la vignette, comme il le fait pour les 80 homonymes de
    Riftbound.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, 'en')
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """
    rows = [
        (str(card.oracle_id), card.name, normalize_name(card.name))
        for card in cards
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def run() -> None:
    print("catalogue One Piece, depuis OPTCG API")
    entries, names, unreachable = fetch_catalogue()
    print(f"\n{len(entries)} entrées lues")

    cards = fold_cards(entries)
    printings = fold_printings(entries)
    variantes = sum(1 for e in entries if e.is_variant)
    print(f"{len(cards)} cartes, {len(printings)} impressions "
          f"(dont {variantes} entrées de tirage alternatif)")

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url) as conn:
        written_cards = write_cards(conn, cards)
        written_prints = write_prints(conn, printings, names)
        written_names = write_search_names(conn, cards)
        conn.commit()

    print(f"\n{written_cards} cartes, {written_prints} impressions, "
          f"{written_names} noms de recherche écrits")
    if unreachable:
        print(f"ATTENTION : {len(unreachable)} origines injoignables, "
              f"leur contenu manque : {', '.join(unreachable)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
