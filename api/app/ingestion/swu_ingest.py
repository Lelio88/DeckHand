"""Catalogue Star Wars Unlimited, depuis SWU-DB.

**Pourquoi pas la source officielle.** L'API du site de l'éditeur ne demande
aucune clé, son `robots.txt` n'interdit rien, elle sert le **français** et
déclare orientation et finition — deux champs que les jeux précédents ont payés
en mesure. Ses conditions la ferment quand même, verbatim : « You will not
transmit any bugs, viruses, trojan horses, **bots, scrapers**, or any like or
related programming through or to the Website. » C'est le cas EDHREC du
garde-fou §IV.1, et le cas Wankul avant l'accord : la porte existe, elle se
demande à un humain. Tant qu'elle n'est pas ouverte, ce jeu rejoint Riftbound —
catalogue anglais seul, et **l'illustration prime sur le nom**.

SWU-DB ne publie aucune condition (404 sur `/terms` et `/about`, pas de
`robots.txt`) et documente son API publiquement : le garde-fou §IV.9 lui
applique celles de Scryfall — `User-Agent` descriptif, débit bas, attribution
visible, aucune illustration réhébergée.

**Une entrée « Foil » n'est pas une impression de plus.** C'est le piège
principal de cette source, et il gonflerait `card_prints` de moitié. Son champ
`VariantType` mêle deux notions : un *traitement d'impression* (`Normal`,
`Hyperspace`, `Showcase`, `Prestige`, `OP Promo`…) et une *finition* (le suffixe
` Foil`). La preuve qu'il s'agit bien d'une seule impression dans deux finitions
est dans les identifiants TCGplayer — sur 880 partagés, **878 ne recouvrent
qu'un seul traitement**. Une impression est donc identifiée ici par le triplet
(extension, traitement, carte), et l'entrée brillante n'y ajoute que sa
finition.

**Et la source rompt sa propre règle de suffixe** : la brillante de `Normal` ne
s'appelle pas « Normal Foil » mais `Foil` tout court. Lire un suffixe et rien
d'autre classe 1 148 impressions parmi les ordinaires — soit la moitié du
catalogue courant — et rien ne le signale.

**L'identité d'une carte est son titre imprimé**, nom et sous-titre réunis :
2 180 titres pour 8 424 impressions, dont 320 réimprimés d'une extension à
l'autre par les promos. Le type entre dans la clé parce qu'un titre, un seul,
est porté par deux cartes réellement différentes — « Snapshot Reflexes » existe
en Event et en Upgrade. `cid` ressemblait à une clé et n'en est pas une : 1 770
titres en portent deux, et 5 446 impressions n'en portent aucune.

**Ce que ce jeu remplit, et pourquoi.** `layout` porte le **type**, qui décide
seul de la fenêtre d'illustration — un Event porte la sienne en bas, une Unit en
haut, un Leader est imprimé en travers. `color_identity` porte les **aspects**,
et c'est légitime parce que mesuré : 79,1 % des decks du corpus y tiennent
entièrement. Yu-Gi-Oh a montré l'inverse, son Attribut n'imposant aucune
contrainte.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.swu_ingest
    #   --force   réécrit même si la source n'a pas changé
"""

from __future__ import annotations

import argparse
import sys
import time
import urllib.error
import urllib.request
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Iterable, Iterator

import json

import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name

GAME = "swu"

BASE = "https://api.swu-db.com"

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

#: Espace de noms des identifiants dérivés. **Figé** : le changer réécrirait
#: tout le catalogue sous de nouvelles clés et orphelinerait les collections
#: déjà saisies — chaque exemplaire possédé pointe sur un `oracle_id`.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/swu")

#: Débit volontairement bas, comme pour Riftcodex et TCGdex. La source
#: n'annonce aucune limite ; une trentaine de requêtes suffisent au catalogue
#: entier, il n'y a aucune raison de la presser.
PAUSE_SECONDS = 0.4

ATTEMPTS = 5
FIRST_DELAY = 1.0

#: Le suffixe qui marque une finition brillante, et la valeur qui rompt la
#: règle. Voir le commentaire de module : `Foil` seul est la brillante de
#: `Normal`, pas celle d'un traitement anonyme.
FOIL_SUFFIX = " Foil"
FOIL_ALONE = "Foil"
BASE_TREATMENT = "Normal"

#: Préfixe des types qui ne se jouent pas. Un jeton est créé en cours de partie,
#: n'entre dans aucune liste et ne se collectionne pas en vue d'un deck — le
#: précédent Magic est net, les 22 jetons possédés n'étant légaux dans aucun
#: format construit. Le type est un vocabulaire ; le nom d'extension, lui, est
#: un libellé qui se trompe : `GG` (Gamegenic) contient des jetons sans le dire.
TOKEN_TYPE_PREFIX = "Token"


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

    set_code: str
    number: str
    name: str
    subtitle: str
    type: str
    variant: str
    rarity: str
    aspects: tuple[str, ...]
    traits: tuple[str, ...]
    arenas: tuple[str, ...]
    cost: str
    text: str
    front_art: str
    tcgplayer_id: str

    @property
    def is_foil(self) -> bool:
        return self.variant == FOIL_ALONE or self.variant.endswith(FOIL_SUFFIX)

    @property
    def treatment(self) -> str:
        if self.variant == FOIL_ALONE:
            return BASE_TREATMENT
        if self.variant.endswith(FOIL_SUFFIX):
            return self.variant[: -len(FOIL_SUFFIX)]
        return self.variant

    @property
    def is_token(self) -> bool:
        return self.type.startswith(TOKEN_TYPE_PREFIX)

    @property
    def title(self) -> str:
        return f"{self.name} | {self.subtitle}" if self.subtitle else self.name

    @property
    def oracle_id(self) -> uuid.UUID:
        """L'identité de la **carte**.

        Le type entre dans la clé pour un seul cas sur 2 180 — « Snapshot
        Reflexes », qui est un Event et un Upgrade. L'omettre les fusionnerait,
        et la collection perdrait celle qui est réellement possédée.
        """
        return uuid.uuid5(NAMESPACE, f"{self.title}|{self.type}")

    @property
    def print_key(self) -> uuid.UUID:
        """L'identité de l'**impression** : extension, traitement, carte.

        Pas le numéro : l'entrée brillante en porte un différent tout en
        désignant la même impression, ce que les identifiants TCGplayer
        partagés confirment. Pas le `tcgplayerId` non plus, qui manque sur
        0,7 % des entrées et qu'une source peut réattribuer.
        """
        return uuid.uuid5(
            NAMESPACE, f"print|{self.set_code}|{self.treatment}|{self.oracle_id}"
        )


@dataclass
class Printing:
    """Une impression, une fois les deux finitions réunies."""

    key: uuid.UUID
    oracle_id: uuid.UUID
    set_code: str
    treatment: str
    #: Le numéro de l'entrée **ordinaire** quand elle existe. Les quatre Bases
    #: Gamegenic n'existent qu'en brillante ; leur numéro vient donc de
    #: l'entrée brillante, faute de mieux, et `finishes` le dit.
    number: str = ""
    rarity: str = ""
    front_art: str = ""
    tcgplayer_id: str = ""
    has_nonfoil: bool = False
    has_foil: bool = False

    @property
    def finishes(self) -> list[str]:
        out = []
        if self.has_nonfoil:
            out.append("nonfoil")
        if self.has_foil:
            out.append("foil")
        return out


def parse_entry(row: dict[str, Any], fallback_set: str) -> Entry:
    return Entry(
        set_code=(row.get("Set") or fallback_set).upper(),
        number=str(row.get("Number") or ""),
        name=row.get("Name") or "",
        subtitle=row.get("Subtitle") or "",
        type=row.get("Type") or "",
        variant=row.get("VariantType") or BASE_TREATMENT,
        rarity=row.get("Rarity") or "",
        aspects=tuple(row.get("Aspects") or ()),
        traits=tuple(row.get("Traits") or ()),
        arenas=tuple(row.get("Arenas") or ()),
        cost=str(row.get("Cost") or ""),
        text=row.get("FrontText") or "",
        front_art=row.get("FrontArt") or "",
        tcgplayer_id=str(row.get("tcgplayerId") or ""),
    )


def fetch_catalogue() -> tuple[list[Entry], dict[str, str], list[str]]:
    """Toutes les entrées jouables, les noms d'extension, et les injoignables.

    Une requête par extension — trente-huit. Il n'existe aucun endpoint qui
    rende le catalogue entier d'un coup.

    Une extension **injoignable** est distinguée d'une extension vide et
    remontée telle quelle : `TASH` rend un 502 déterministe, et confondre les
    deux ferait passer un trou de collecte pour un fait du catalogue.
    """
    sets = _json("sets")
    names = {
        (s.get("setId") or "").upper(): s.get("fullName") or ""
        for s in sets
        if s.get("setId")
    }

    entries: list[Entry] = []
    unreachable: list[str] = []
    for code in sorted(names):
        try:
            payload = _json(f"cards/{code.lower()}?format=json")
        except IngestError as exc:
            print(f"  {code} injoignable : {exc}")
            unreachable.append(code)
            continue
        rows = payload.get("data") or []
        entries.extend(parse_entry(row, code) for row in rows)
        if rows:
            print(f"  {code:<8} {len(rows):>5} entrées")
    return entries, names, unreachable


def fold_printings(entries: Iterable[Entry]) -> list[Printing]:
    """Réunit les entrées en impressions, une finition n'en créant pas une.

    L'entrée ordinaire fournit le numéro, la rareté et l'illustration ; la
    brillante n'ajoute que sa case. Quand seule la brillante existe — les quatre
    Bases Gamegenic —, elle fournit tout, et `finishes` ne portera que `foil`.
    """
    folded: dict[uuid.UUID, Printing] = {}
    for entry in entries:
        printing = folded.get(entry.print_key)
        if printing is None:
            printing = Printing(
                key=entry.print_key,
                oracle_id=entry.oracle_id,
                set_code=entry.set_code,
                treatment=entry.treatment,
            )
            folded[entry.print_key] = printing

        if entry.is_foil:
            printing.has_foil = True
        else:
            printing.has_nonfoil = True

        # L'entrée ordinaire est prioritaire pour tout ce qui s'affiche : son
        # numéro est celui imprimé sur la carte que l'on range en classeur, et
        # son illustration est celle que le CDN sert réellement — la brillante
        # rend 403.
        if not entry.is_foil or not printing.number:
            printing.number = entry.number or printing.number
            printing.rarity = entry.rarity or printing.rarity
            printing.front_art = entry.front_art or printing.front_art
        if entry.tcgplayer_id and not printing.tcgplayer_id:
            printing.tcgplayer_id = entry.tcgplayer_id
    return list(folded.values())


@dataclass(frozen=True)
class Card:
    """Une carte, telle qu'elle entrera dans `cards`."""

    oracle_id: uuid.UUID
    name: str
    type_line: str
    text: str
    aspects: tuple[str, ...]
    cost: str
    layout: str


def fold_cards(entries: Iterable[Entry]) -> list[Card]:
    """Réunit les entrées en cartes, par titre imprimé et type.

    Les champs d'affichage sont pris sur la **première** entrée rencontrée, dans
    l'ordre des extensions. Riftbound a montré qu'ils ne sont pas stables — sa
    source réécrivait ses textes d'une extension à l'autre, et 63 identités
    s'étaient dédoublées pour cette seule raison — mais ici ils ne servent qu'à
    l'affichage : l'identité, elle, ne dépend que du titre et du type.
    """
    seen: dict[uuid.UUID, Card] = {}
    for entry in entries:
        if entry.oracle_id in seen:
            continue
        # La ligne de type réunit ce que le joueur lit sur la carte : son type,
        # puis ses traits. C'est aussi ce que la recherche filtre.
        type_line = entry.type
        if entry.traits:
            type_line = f"{entry.type} — {' '.join(entry.traits)}"
        seen[entry.oracle_id] = Card(
            oracle_id=entry.oracle_id,
            name=entry.title,
            type_line=type_line,
            text=entry.text,
            aspects=entry.aspects,
            cost=entry.cost,
            layout=entry.type,
        )
    return list(seen.values())


def write_cards(conn: psycopg.Connection, cards: Iterable[Card]) -> int:
    """Écrit l'identité des cartes. Idempotent : rejouable sans doublon."""
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
            list(card.aspects),
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
    """Le coût en ressources, ou zéro.

    **Le zéro est imposé par le schéma, pas choisi** : `cards.cmc` est
    `NOT NULL DEFAULT 0`. Une Base n'a pas de coût — on ne la joue pas, on la
    pose —, et son zéro se lira donc « gratuite » plutôt que « la notion ne
    s'applique pas ». La perte est bornée : les Bases sont 214 impressions sur
    8 424, aucun deck n'en contient plus d'une, et le constructeur les traite
    par leur type et non par leur coût.
    """
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def write_prints(
    conn: psycopg.Connection, printings: Iterable[Printing], set_names: dict[str, str]
) -> int:
    """Écrit les impressions. Idempotent : rejouable sans doublon.

    `art_crop_url` désigne la carte **entière** et non une illustration
    détourée : la source ne publie pas celle-ci. Le découpage appartient donc au
    calcul d'empreinte, comme pour Riftbound, Yu-Gi-Oh et Pokémon — et le
    gabarit à appliquer se lit sur `cards.layout`, qui porte le type.

    `price_eur` reste hors de la requête : les prix viennent de TCGCSV, par un
    connecteur distinct, et les écraser ici les remettrait à zéro à chaque
    course du catalogue.
    """
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id,
                                        finishes, tcgplayer_id)
        VALUES (%s, %s, 'en', %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE SET
            oracle_id        = EXCLUDED.oracle_id,
            set_code         = EXCLUDED.set_code,
            set_name         = EXCLUDED.set_name,
            collector_number = EXCLUDED.collector_number,
            printed_name     = EXCLUDED.printed_name,
            rarity           = EXCLUDED.rarity,
            art_crop_url     = EXCLUDED.art_crop_url,
            illustration_id  = EXCLUDED.illustration_id,
            -- **Le catalogue est un repli sur les finitions, pas l'autorité**,
            -- et c'est mesuré. `VariantType` ne publie une entrée brillante que
            -- lorsque la source l'a saisie, et elle est incomplète : sur 5 154
            -- impressions comparées à TCGCSV, 1 981 seulement concordent. Les
            -- 517 `Showcase` n'existent **qu'en brillante** chez TCGplayer et
            -- ce catalogue les déclare ordinaires — une case que le carton n'a
            -- jamais eue. `tcgcsv_swu_prices` corrige donc après coup, comme
            -- pour Riftbound et Pokémon, et le `COALESCE` protège son travail
            -- d'une prochaine course du catalogue.
            finishes         = COALESCE(public.card_prints.finishes,
                                        EXCLUDED.finishes),
            tcgplayer_id     = COALESCE(EXCLUDED.tcgplayer_id,
                                        public.card_prints.tcgplayer_id)
    """
    rows = [
        (
            str(printing.key),
            str(printing.oracle_id),
            # Le traitement est ce qui distingue deux impressions d'une même
            # carte dans une même extension ; le porter ici est ce qui permet à
            # l'utilisateur de dire laquelle il possède.
            printing.treatment or None,
            printing.set_code,
            set_names.get(printing.set_code) or printing.set_code,
            printing.number,
            printing.rarity or None,
            printing.front_art or None,
            # L'illustration se dérive de son URL : deux impressions qui
            # partagent le même rendu partagent la même empreinte, et l'index
            # n'aura à la calculer qu'une fois.
            str(uuid.uuid5(NAMESPACE, printing.front_art)) if printing.front_art else None,
            printing.finishes or None,
            printing.tcgplayer_id or None,
        )
        for printing in printings
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def write_search_names(conn: psycopg.Connection, cards: Iterable[Card]) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable.

    Wankul l'a appris à ses dépens : 958 cartes en base, zéro ligne ici, et un
    catalogue qu'on ne pouvait ni chercher ni ranger en classeur — sans que rien
    ne le signale, la table `cards` étant pleine.

    **Deux formes sont indexées par carte** : le titre entier et le nom seul.
    C'est mesuré sur le corpus de decks, où les listes citent les unités sous
    leur titre complet et les bases sous leur seul nom. Le nom seul n'est pas
    ambigu ici — un seul titre du catalogue est porté par deux cartes.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, 'en')
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """
    rows: list[tuple[Any, ...]] = []
    for card in cards:
        forms = {card.name}
        head = card.name.split(" | ", 1)[0]
        forms.add(head)
        for form in forms:
            rows.append((str(card.oracle_id), form, normalize_name(form), ))
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def run(force: bool) -> None:
    print("catalogue Star Wars Unlimited, depuis SWU-DB")
    entries, set_names, unreachable = fetch_catalogue()
    playable = [e for e in entries if not e.is_token]
    print(f"\n{len(entries)} entrées, dont {len(entries) - len(playable)} jetons écartés")

    cards = fold_cards(playable)
    printings = fold_printings(playable)
    print(f"{len(cards)} cartes, {len(printings)} impressions")

    foil_only = sum(1 for p in printings if p.has_foil and not p.has_nonfoil)
    if foil_only:
        print(f"  dont {foil_only} qui n'existent qu'en brillante")

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url) as conn:
        written_cards = write_cards(conn, cards)
        written_prints = write_prints(conn, printings, set_names)
        written_names = write_search_names(conn, cards)
        conn.commit()

    print(f"\n{written_cards} cartes, {written_prints} impressions, "
          f"{written_names} noms de recherche écrits")
    if unreachable:
        print(f"ATTENTION : {len(unreachable)} extensions injoignables, "
              f"leur contenu manque : {', '.join(unreachable)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="réécrit sans condition")
    args = parser.parse_args()
    run(args.force)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("interrompu")
