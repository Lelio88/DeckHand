"""Catalogue Disney Lorcana, depuis Lorcast — **et ses prix avec**.

Septième jeu du projet, et le premier dont **une seule source rend tout** :
catalogue, illustrations et cotes. Partout ailleurs il a fallu deux connecteurs
— Scryfall puis rien pour Magic, un catalogue puis TCGCSV pour quatre jeux, et
rien du tout pour Wankul qu'aucun index public ne cote.

**L'identité est l'identifiant de la source**, `crd_d9f3b86af…`. Quatre clés ont
été éprouvées côte à côte au banc, et deux tiennent : l'identifiant de la source
et le couple extension-numéro, tous deux à 3 192 valeurs distinctes pour
3 192 cartes. Les deux autres fusionnent massivement — **le nom seul en fusionne
1 910**, « Mickey Mouse » désignant à lui seul des dizaines de cartes, et même
`nom + version` en fusionne 704. C'est la leçon de Pokémon, où 92 % des cartes
partagent leur nom, et elle se répète ici à l'identique.

Entre les deux clés valables, l'identifiant de la source gagne pour la raison
qui a fait choisir celui de Wankul : il est **opaque et stable**, là où un couple
reconstitué dépend de la façon dont la source nomme ses extensions — et c'est
précisément cette reconstitution qui a coûté 1 100 impressions non cotées chez
One Piece.

**Ce que porte chaque colonne**, et ce que ça décide :

- `layout` reçoit le **type** (`Character`, `Action`, `Item`, `Song`,
  `Location`). La source publie *aussi* un champ nommé `layout`, valant `normal`
  ou `landscape` — et les 106 `landscape` sont **exactement** les 106
  `Location`, vérifié carte par carte. Deux axes pour une seule information :
  on garde celui dont le constructeur a besoin, l'orientation s'en déduisant.
- `color_identity` reçoit l'**encre**. 160 cartes n'en ont aucune ; elles
  restent constructibles, la contrainte des deux encres ne portant que sur
  celles qui en déclarent une.
- `cmc` reçoit le **coût en encre**.
- `finishes` est rempli **depuis les prix publiés**, et c'est le seul jeu où la
  finition et la cote viennent du même champ. La règle du §IV reste celle des
  autres : la finition se lit là où le jeu la déclare — ici, `prices.usd` et
  `prices.usd_foil` sont deux clés distinctes, dont la présence dit l'existence
  du tirage.

**Les prix sont en dollars et convertis en euros** par le taux de référence
quotidien de la BCE, comme les quatre autres jeux cotés. Le dollar d'origine
reste dans `price_usd`.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.lorcast_ingest
    #   --refresh  ignore le cache disque de la sonde
"""

from __future__ import annotations

import argparse
import sys
import uuid
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name
from app.ingestion.state import record
from app.ingestion.tcgcsv_prices import USER_AGENT, euro_rate, to_euros
from app.measure.lorcast_probe import Probe

GAME = "lorcana"
SOURCE = "lorcast_ingest"

#: Espace de nommage des identités dérivées. Comme pour les cinq autres jeux non
#: Magic, il est propre au jeu : deux sources différentes ne doivent jamais
#: produire la même identité par coïncidence.
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://deckhand.local/lorcana")


@dataclass(frozen=True)
class Card:
    """Une carte, telle que la collection la comptera."""

    oracle_id: uuid.UUID
    name: str
    type_line: str
    text: str
    inks: tuple[str, ...]
    cost: float
    layout: str


@dataclass(frozen=True)
class Printing:
    """Un tirage, tel que le classeur le rangera."""

    key: uuid.UUID
    oracle_id: uuid.UUID
    printed_name: str
    set_code: str
    set_name: str
    collector_number: str
    rarity: str
    image: str
    illustration_id: uuid.UUID
    finishes: tuple[str, ...]
    usd: Decimal | None
    usd_foil: Decimal | None


def full_name(row: dict[str, Any]) -> str:
    """« Ariel » + « On Human Legs » -> « Ariel - On Human Legs ».

    **Le sous-titre fait partie du nom pour l'utilisateur**, qui le lit sur la
    carte et le dira à voix haute. Il ne suffit pas à identifier (704 cartes
    partagent leur couple nom-version), mais il est ce qu'on affiche et ce qu'on
    cherche. Le séparateur est celui que la communauté emploie.
    """
    nom = (row.get("name") or "").strip()
    version = (row.get("version") or "").strip()
    return f"{nom} - {version}" if version else nom


def type_line(row: dict[str, Any]) -> str:
    """« Character — Storyborn, Hero, Princess ».

    La forme est celle de Magic, et c'est délibéré : `CardRole` lit le premier
    mot de cette ligne chez cinq jeux sur sept, et une carte Lorcana doit s'y
    lire de la même façon.
    """
    types = " ".join(row.get("type") or [])
    classes = ", ".join(row.get("classifications") or [])
    return f"{types} — {classes}" if classes else types


def inks_of(row: dict[str, Any]) -> tuple[str, ...]:
    """Les encres, une ou deux, éventuellement aucune.

    La source publie `ink` (une chaîne) **et** `inks` (une liste, souvent nulle).
    Les deux sont lus : `inks` porte les cartes bi-encre, `ink` les autres. Ne
    lire que le premier laisserait 160 cartes sans encre par construction plutôt
    que par constat.
    """
    multiples = row.get("inks")
    if isinstance(multiples, list) and multiples:
        return tuple(str(i) for i in multiples if i)
    unique = row.get("ink")
    return (str(unique),) if unique else ()


def money(value: Any) -> Decimal | None:
    """Un prix publié en chaîne, ou rien.

    **Le zéro n'est pas rien** : une carte cotée 0,00 $ est cotée, une carte sans
    clé ne l'est pas. Confondre les deux ferait valoriser une collection à partir
    d'absences.
    """
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def parse(row: dict[str, Any]) -> tuple[Card, Printing]:
    """Une entrée de la source, dépliée en sa carte et son tirage."""
    source_id = str(row.get("id") or "")
    oracle_id = uuid.uuid5(NAMESPACE, source_id)
    card_set = row.get("set") or {}

    prices = row.get("prices") or {}
    usd = money(prices.get("usd"))
    usd_foil = money(prices.get("usd_foil"))

    # La finition se lit sur la **présence de la clé**, jamais sur la valeur.
    # C'est la règle du §IV, et elle a un coût mesuré ailleurs : déduire les
    # finitions des prix conclurait « n'existe pas en brillante » à partir de
    # « personne n'en vend en ce moment ».
    #
    # Les deux clés sont indépendantes, et il fallait le vérifier : 96,6 % des
    # cartes ont un prix brillante contre 83,9 % en ordinaire, soit **12,7 % qui
    # n'existent qu'en brillante** — les Enchanted et compagnie. Ajouter
    # `nonfoil` d'office les rendrait achetables dans une finition qui n'existe
    # pas, et une collection les compterait à zéro euro.
    finishes: list[str] = []
    if "usd" in prices:
        finishes.append("nonfoil")
    if "usd_foil" in prices:
        finishes.append("foil")
    if not finishes:
        # **Repli, et non lecture.** 68 cartes ne publient aucune des deux clés.
        # Sans finition, `card_editions` les refuse dans les deux sens et elles
        # deviennent **insaisissables** : introuvables à l'ajout, impossibles à
        # ranger en classeur. Le contrôle du §6 les compterait, et il doit
        # continuer de valoir zéro sur les sept jeux.
        #
        # `nonfoil` est le repli sûr : toute carte de ce jeu existe en tirage
        # ordinaire, seule la brillante étant conditionnelle. L'inverse aurait
        # été faux.
        finishes.append("nonfoil")

    images = (row.get("image_uris") or {}).get("digital") or {}

    return (
        Card(
            oracle_id=oracle_id,
            name=full_name(row),
            type_line=type_line(row),
            text=str(row.get("text") or ""),
            inks=inks_of(row),
            cost=float(row.get("cost") or 0),
            # Le **type**, non le champ `layout` de la source : les deux disent
            # la même chose sur l'orientation, et seul celui-ci sert au dosage.
            layout=(row.get("type") or ["Unknown"])[0],
        ),
        Printing(
            key=uuid.uuid5(NAMESPACE, f"print|{source_id}"),
            oracle_id=oracle_id,
            printed_name=full_name(row),
            set_code=str(card_set.get("code") or ""),
            set_name=str(card_set.get("name") or ""),
            collector_number=str(row.get("collector_number") or ""),
            rarity=str(row.get("rarity") or "").lower(),
            image=str(images.get("normal") or images.get("large") or ""),
            # Un rendu par carte : l'identité de l'illustration suit celle de la
            # carte. Aucune impression n'en partage une autre, contrairement à
            # One Piece où 56 entrées partageaient leur rendu.
            illustration_id=uuid.uuid5(NAMESPACE, f"art|{source_id}"),
            finishes=tuple(finishes),
            usd=usd,
            usd_foil=usd_foil,
        ),
    )


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
            list(card.inks),
            card.cost,
            card.layout,
            GAME,
        )
        for card in cards
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def write_prints(
    conn: psycopg.Connection, printings: Iterable[Printing], rate: Decimal
) -> int:
    """Écrit les impressions, **prix compris**.

    C'est la seule écriture d'impressions du projet qui porte les cotes : chez
    les cinq autres jeux, un second connecteur les pose après coup. Les poser
    ici évite qu'un catalogue à jour côtoie des prix d'un autre jour.
    """
    statement = """
        INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, printed_name,
                                        set_code, set_name, collector_number,
                                        rarity, art_crop_url, illustration_id,
                                        finishes, price_usd, price_eur,
                                        price_usd_foil, price_eur_foil)
        VALUES (%s, %s, 'en', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (scryfall_id) DO UPDATE SET
            oracle_id        = EXCLUDED.oracle_id,
            set_code         = EXCLUDED.set_code,
            set_name         = EXCLUDED.set_name,
            collector_number = EXCLUDED.collector_number,
            printed_name     = EXCLUDED.printed_name,
            rarity           = EXCLUDED.rarity,
            art_crop_url     = EXCLUDED.art_crop_url,
            illustration_id  = EXCLUDED.illustration_id,
            finishes         = EXCLUDED.finishes,
            price_usd        = EXCLUDED.price_usd,
            price_eur        = EXCLUDED.price_eur,
            price_usd_foil   = EXCLUDED.price_usd_foil,
            price_eur_foil   = EXCLUDED.price_eur_foil
    """
    rows = [
        (
            str(p.key),
            str(p.oracle_id),
            p.printed_name or None,
            p.set_code,
            p.set_name,
            p.collector_number,
            p.rarity or None,
            p.image or None,
            str(p.illustration_id),
            list(p.finishes),
            p.usd,
            to_euros(p.usd, rate) if p.usd is not None else None,
            p.usd_foil,
            to_euros(p.usd_foil, rate) if p.usd_foil is not None else None,
        )
        for p in printings
    ]
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def write_search_names(conn: psycopg.Connection, cards: Iterable[Card]) -> int:
    """Alimente l'index de saisie. Sans lui, aucune carte n'est trouvable.

    **Deux entrées par carte** : le nom complet et le nom seul. « Ariel - On
    Human Legs » se cherche entier quand on lit la carte, mais on tape « Ariel »
    quand on cherche de mémoire — et 1 910 cartes partageant leur nom seul, la
    recherche rendra la liste, à l'utilisateur de trancher sur la vignette.
    C'est le comportement des 62 « Monkey.D.Luffy » de One Piece et des 80
    homonymes de Riftbound.
    """
    statement = """
        INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
        VALUES (%s, %s, %s, 'en')
        ON CONFLICT (oracle_id, normalized, lang) DO NOTHING
    """
    rows: list[tuple[str, str, str]] = []
    for card in cards:
        rows.append((str(card.oracle_id), card.name, normalize_name(card.name)))
        court = card.name.split(" - ", 1)[0]
        if court != card.name:
            rows.append((str(card.oracle_id), court, normalize_name(court)))
    with conn.cursor() as cursor:
        cursor.executemany(statement, rows)
    return len(rows)


def prune(conn: psycopg.Connection, gardees: set[str], impressions: set[str]) -> tuple[int, int]:
    """Retire ce que la source ne publie plus.

    **Sans cette passe, le catalogue enfle en silence** : c'est le défaut trouvé
    sur SWU, où la base gardait 2 181 cartes pour 2 180 produites. Une carte
    citée par un deck n'est jamais retirée — on ne casse pas une liste
    existante pour faire propre.
    """
    with conn.cursor() as cursor:
        supprimees_prints = cursor.execute(
            """
            DELETE FROM public.card_prints p
            USING public.cards c
            WHERE c.oracle_id = p.oracle_id AND c.game = %s
              AND NOT (p.scryfall_id::text = ANY(%s))
            """,
            (GAME, list(impressions)),
        ).rowcount
        supprimees_cards = cursor.execute(
            """
            DELETE FROM public.cards c
            WHERE c.game = %s
              AND NOT (c.oracle_id::text = ANY(%s))
              AND NOT EXISTS (
                  SELECT 1 FROM public.deck_cards d WHERE d.oracle_id = c.oracle_id
              )
            """,
            (GAME, list(gardees)),
        ).rowcount
    return supprimees_cards, supprimees_prints


def run(*, refresh: bool = False) -> None:
    print("catalogue Disney Lorcana, depuis Lorcast")

    with Probe(refresh=refresh) as probe:
        rows = probe.all_cards()
    print(f"  {len(rows)} entrées lues")

    cartes: dict[uuid.UUID, Card] = {}
    impressions: list[Printing] = []
    for row in rows:
        card, printing = parse(row)
        cartes[card.oracle_id] = card
        impressions.append(printing)

    cfg = SupabaseConfig.load()
    with psycopg.connect(cfg.db_url) as conn:
        with httpx.Client(timeout=30, headers={"User-Agent": USER_AGENT}) as client:
            jour, rate = euro_rate(client)
        print(f"  taux BCE du {jour} : 1 EUR = {rate} USD")

        n_cards = write_cards(conn, cartes.values())
        n_prints = write_prints(conn, impressions, rate)
        n_names = write_search_names(conn, cartes.values())
        retirees, retirees_prints = prune(
            conn,
            {str(k) for k in cartes},
            {str(p.key) for p in impressions},
        )
        record(conn, SOURCE, version=str(len(rows)), items=n_prints)
        conn.commit()

    print(f"  {n_cards} cartes, {n_prints} impressions, {n_names} noms de recherche")
    if retirees or retirees_prints:
        print(f"  retirées : {retirees} cartes, {retirees_prints} impressions")

    cotees = sum(1 for p in impressions if p.usd is not None or p.usd_foil is not None)
    print(f"  {cotees}/{len(impressions)} impressions cotées "
          f"({100 * cotees / len(impressions):.1f} %)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args(argv)
    run(refresh=args.refresh)
    return 0


if __name__ == "__main__":
    sys.exit(main())
