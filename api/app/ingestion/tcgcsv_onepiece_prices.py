"""Prix One Piece, depuis l'export groupé TCGCSV, convertis en euros.

Sixième jeu coté du projet, et son rapprochement se situe entre les deux
extrêmes déjà rencontrés. Riftbound et SWU se lient par un `tcgplayer_id` que
leur catalogue publie ; Yu-Gi-Oh et Pokémon doivent rapprocher extension et
numéro, ce qui a coûté deux tables d'alias et un veto par date. Ici, **TCGCSV
publie le code complet** — `extendedData` porte un champ `Number` valant
`OP17-028`, exactement le `card_set_id` du catalogue. Aucune extension à
rapprocher.

**Mais le code ne suffit pas, et c'est mesuré.** Sur la seule extension
*Romance Dawn*, **32 codes sur 121 sont portés par plusieurs produits** :
TCGplayer distingue les tirages par le **nom**, avec les mêmes suffixes que le
catalogue — « Trafalgar Law (002) » et « … (Parallel) » y sont deux produits, à
deux prix. Rapprocher par le seul code écrirait le prix d'un Box Topper à 45 $
sur la carte ordinaire à 0,94 $.

La clé est donc le couple **(code, nom normalisé)**, et le catalogue porte le
nom publié sur chaque impression pour cette raison.

Résultat sur les 3 935 impressions du catalogue :

| Voie | Impressions |
|---|---|
| code et nom | **3 876** |
| code porté par plusieurs produits, aucun nom ne correspond | 48 |
| code seul, non ambigu | 3 |
| code inconnu de TCGplayer | 8 |

**3 881 sur 3 935 sont cotées, soit 98,6 %** — le meilleur taux du projet après
Magic. Le sens inverse laisse davantage de reste : TCGCSV connaît l'extension
`OP17` que le catalogue n'a pas encore publiée, ce qui est un retard de la
source de catalogue et se comblera de lui-même.

**Le vocabulaire de `subTypeName` est celui de Riftbound** — `Normal` et
`Foil` —, vérifié plutôt que supposé : chez Yu-Gi-Oh le champ homologue porte
une **édition** (`1st Edition`, `Unlimited`), et lui appliquer cette table
déclarerait « existe en brillante » sur la foi d'un tirage.

**Les euros sont convertis, pas relevés**, par le taux de référence quotidien de
la Banque centrale européenne. Le dollar d'origine reste dans `price_usd`.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_onepiece_prices
    #   --force   réingère même si le jour a déjà été traité
"""

from __future__ import annotations

import sys
import time
import uuid
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.scryfall_parse import normalize_name
from app.ingestion.state import last_version, record
from app.ingestion.tcgcsv_prices import (
    BASE,
    PAUSE_SECONDS,
    SUBTYPE_FOIL,
    SUBTYPE_NORMAL,
    USER_AGENT,
    euro_rate,
    market_prices,
    to_euros,
)

GAME = "onepiece"

#: Catégorie TCGplayer de One Piece, relevée sur `/tcgplayer/categories`.
CATEGORY_ONEPIECE = 68

SOURCE = "tcgcsv_onepiece_prices"

ATTEMPTS = 5
FIRST_DELAY = 1.0


def _get(client: httpx.Client, url: str) -> Any:
    """Réponse JSON de [url], en reprenant sur coupure.

    Quatre-vingt-cinq groupes, contre vingt et un pour Riftbound : le réseau de
    ce poste a déjà lâché en pleine course sur trente et une requêtes, lors du
    chantier SWU. La reprise n'est pas une précaution théorique.
    """
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        try:
            response = client.get(url)
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                raise
            last = exc
        except Exception as exc:
            last = exc
        time.sleep(delay)
        delay *= 2
    raise RuntimeError(f"{url} injoignable après {ATTEMPTS} tentatives : {last}")


def card_number(product: dict[str, Any]) -> str | None:
    """Le code imprimé, tel que `extendedData` le porte."""
    for field in product.get("extendedData") or []:
        if field.get("name") == "Number":
            value = (field.get("value") or "").strip()
            return value or None
    return None


@dataclass(frozen=True)
class Products:
    """Ce que TCGCSV publie pour ce jeu."""

    #: (code, nom normalisé) -> identifiant de produit
    by_key: dict[tuple[str, str], int]
    #: code -> identifiants, pour le repli quand le code n'est pas ambigu
    by_code: dict[str, set[int]]
    market: dict[int, dict[str, Decimal]]
    declared: dict[int, set[str]]


def declared_subtypes(rows: Iterable[dict[str, Any]]) -> dict[int, set[str]]:
    """Les finitions que TCGCSV déclare exister, cotées ou non.

    **La présence de la ligne est le signal, pas celle du prix** : TCGCSV publie
    une ligne par couple produit-finition même sans `marketPrice`. Déduire les
    finitions des prix conclurait « n'existe pas en brillante » à partir de
    « personne n'en vend en ce moment ».
    """
    out: dict[int, set[str]] = {}
    for row in rows:
        subtype = row.get("subTypeName")
        if subtype not in (SUBTYPE_NORMAL, SUBTYPE_FOIL):
            continue
        out.setdefault(int(row["productId"]), set()).add(
            "nonfoil" if subtype == SUBTYPE_NORMAL else "foil"
        )
    return out


def fetch_products(client: httpx.Client) -> Products:
    """Produits, prix et finitions de tout One Piece — deux requêtes par groupe."""
    by_key: dict[tuple[str, str], int] = {}
    by_code: dict[str, set[int]] = defaultdict(set)
    market: dict[int, dict[str, Decimal]] = {}
    declared: dict[int, set[str]] = {}

    groups = _get(client, f"{BASE}/{CATEGORY_ONEPIECE}/groups")["results"]
    for group in groups:
        group_id = int(group["groupId"])
        products = _get(client, f"{BASE}/{CATEGORY_ONEPIECE}/{group_id}/products")
        for product in products["results"]:
            code = card_number(product)
            if not code:
                continue
            product_id = int(product["productId"])
            by_key[(code, normalize_name(product.get("name") or ""))] = product_id
            by_code[code].add(product_id)
        time.sleep(PAUSE_SECONDS)

        prices = _get(client, f"{BASE}/{CATEGORY_ONEPIECE}/{group_id}/prices")
        market.update(market_prices(prices["results"]))
        declared.update(declared_subtypes(prices["results"]))
        time.sleep(PAUSE_SECONDS)

    return Products(by_key=by_key, by_code=dict(by_code), market=market, declared=declared)


def load_printings(conn: psycopg.Connection) -> list[tuple[str, str, str]]:
    """Les impressions One Piece : (identifiant, code, nom publié).

    **Le code vient du catalogue, et non d'une reconstitution.** Une première
    version le rebâtissait depuis l'extension et le numéro — `OP-01` + `077`
    donnant `OP01-077` —, et cela marchait pour vingt origines sur vingt-neuf.
    Les autres l'ont démenti : `OP14-EB04` agrège **deux** extensions, et ses
    cartes portent des codes `OP14-…` ou `EB04-…` que le nom de l'origine ne
    permet pas de deviner. La reconstitution y produisait `OP14EB04-…`, un code
    qui n'existe nulle part — 394 impressions restaient non cotées, et rien ne
    disait pourquoi.

    L'identité de la carte étant `uuid5(NAMESPACE, code)`, la table se rebâtit
    en relisant le catalogue : une trentaine de requêtes, servies par le cache
    de la sonde. C'est le même choix que `limitless_ingest`, qui relit TCGdex
    pour rapprocher ses sigles d'extension.
    """
    from app.ingestion.optcg_ingest import NAMESPACE as OPTCG_NAMESPACE
    from app.measure.optcgapi_probe import Probe, ProbeError

    probe = Probe(quiet=True)
    par_oracle: dict[str, str] = {}
    for origin in probe.set_ids() + probe.deck_ids():
        try:
            rows = (
                probe.cards(origin)
                if not origin.startswith("ST")
                else probe.deck_cards(origin)
            )
        except ProbeError:
            continue
        for row in rows:
            code = (row.get("card_set_id") or "").strip()
            if code:
                par_oracle[str(uuid.uuid5(OPTCG_NAMESPACE, code))] = code

    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT p.scryfall_id::text, p.oracle_id::text,
                   COALESCE(p.printed_name, '')
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = %s
            """,
            (GAME,),
        ).fetchall()
    return [
        (scryfall_id, par_oracle[oracle_id], name)
        for scryfall_id, oracle_id, name in rows
        if oracle_id in par_oracle
    ]


def match(products: Products, code: str, name: str) -> tuple[int | None, str]:
    """L'identifiant de produit, et par quelle voie — ou pourquoi il échoue."""
    exact = products.by_key.get((code, normalize_name(name)))
    if exact is not None:
        return exact, "code et nom"
    candidates = products.by_code.get(code)
    if candidates and len(candidates) == 1:
        return next(iter(candidates)), "code seul"
    if candidates:
        return None, "code ambigu"
    return None, "code inconnu de TCGplayer"


def write_prices(
    conn: psycopg.Connection, products: Products, rate: Decimal
) -> dict[str, int]:
    """Écrit prix et finitions sur les impressions rapprochées.

    Les écritures sont groupées : à quelques milliers de lignes, un
    aller-retour par ligne vers une base distante a déjà fait *tomber la
    connexion* lors du chantier SWU.
    """
    statement = """
        UPDATE public.card_prints
        SET price_usd      = %(usd)s,
            price_usd_foil = %(usd_foil)s,
            price_eur      = %(eur)s,
            price_eur_foil = %(eur_foil)s,
            finishes       = COALESCE(%(finishes)s, finishes)
        WHERE scryfall_id = %(id)s
    """
    rows = []
    routes: dict[str, int] = defaultdict(int)
    for scryfall_id, code, name in load_printings(conn):
        product_id, route = match(products, code, name)
        routes[route] += 1
        if product_id is None:
            continue
        by_finish = products.market.get(product_id, {})
        usd = by_finish.get(SUBTYPE_NORMAL)
        usd_foil = by_finish.get(SUBTYPE_FOIL)
        declared = products.declared.get(product_id)
        rows.append(
            {
                "id": scryfall_id,
                "usd": usd,
                "usd_foil": usd_foil,
                "eur": to_euros(usd, rate),
                "eur_foil": to_euros(usd_foil, rate),
                "finishes": sorted(declared) if declared else None,
            }
        )

    with conn.cursor() as cur:
        cur.executemany(statement, rows)
    conn.commit()
    return dict(routes)


def coverage(conn: psycopg.Connection) -> dict[str, int]:
    """Ce que la base porte **après** écriture, et non ce qu'on a écrit.

    Un compteur d'écritures n'est pas un compteur de résultats : le connecteur
    Riftbound annonçait « 1 194 impressions valorisées » quand 492 seulement
    portaient un prix ordinaire.
    """
    with conn.cursor() as cur:
        row = cur.execute(
            """
            SELECT count(*),
                   count(*) FILTER (WHERE p.price_eur IS NOT NULL
                                       OR p.price_eur_foil IS NOT NULL),
                   count(*) FILTER (WHERE 'foil' = ANY(p.finishes)),
                   count(*) FILTER (WHERE p.finishes IS NULL)
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = %s
            """,
            (GAME,),
        ).fetchone()
    return dict(zip(("impressions", "cotees", "en_brillante", "sans_finition"), row))


def run(*, force: bool = False) -> int:
    today = datetime.now(timezone.utc).date().isoformat()

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        previous = last_version(conn, SOURCE)
        if not force and previous and previous.startswith(today):
            print(f"  prix déjà rafraîchis aujourd'hui ({previous})")
            return 0

        with httpx.Client(
            timeout=60, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            rate_date, rate = euro_rate(client)
            print(f"  taux BCE du {rate_date} : 1 € = {rate} $")
            products = fetch_products(client)
            print(f"  {len(products.by_key)} produits identifiés par (code, nom), "
                  f"{len(products.market)} cotés")

        routes = write_prices(conn, products, rate)
        print("  rapprochement des impressions :")
        for route, n in sorted(routes.items(), key=lambda kv: -kv[1]):
            print(f"      {route:<28} {n:>5}")

        etat = coverage(conn)
        print(f"  ce que la base porte :")
        print(f"      {etat['cotees']}/{etat['impressions']} impressions cotées")
        print(f"      {etat['en_brillante']} déclarent la brillante, "
              f"{etat['sans_finition']} n'ont aucune finition")

        record(
            conn,
            SOURCE,
            version=f"{today} usd_par_eur={rate} (BCE {rate_date})",
            items=sum(routes.values()),
        )
    return 0


def main(argv: list[str]) -> int:
    return run(force="--force" in argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
