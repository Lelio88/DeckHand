"""Prix Yu-Gi-Oh, depuis l'export groupé TCGCSV, convertis en euros.

**Pourquoi pas les prix du catalogue, qui existent pourtant.** YGOPRODeck sert un
`cardmarket_price` sur 96,6 % des cartes, en euros, ce qui semblait dispenser de
tout ce module. Mesuré, c'est un piège : le *Magicien Sombre* y vaut **0,02 €**.
Ce n'est pas un prix de marché mais un **plancher** — la plus basse annonce,
toutes impressions confondues, sur une carte dont certaines éditions se vendent
soixante euros. La règle du projet est explicite : `marketPrice` et non
`lowPrice`, la même notion que Scryfall publie pour Magic, sans quoi les totaux
de deux jeux ne se comparent plus. Le prix par carte est donc écarté.

`set_price`, le prix par impression du même catalogue, ne couvre que 27,9 % des
impressions. Il reste TCGCSV, qui est déjà la source des prix Riftbound.

**Le rapprochement est exact, pas approximatif.** Riftbound se lie par
`tcgplayer_id`, que sa source fournit ; YGOPRODeck n'en donne aucun. Mais
TCGplayer publie dans ses données étendues le **numéro d'impression** et la
**rareté**, et le catalogue porte les mêmes : « LOB-005 · Ultra Rare » désigne
une et une seule impression. C'est un identifiant composite, pas une
ressemblance de noms — la nuance est celle qui a fait renoncer au rapprochement
des 227 cartes `VEN` de Riftbound.

Mesuré sur douze extensions tirées au hasard : **79 % des produits TCGplayer**
trouvent leur impression, et **99,7 % de celles-ci portent un prix de marché**.

**Les éditions ne sont pas des finitions.** TCGplayer sépare `1st Edition`,
`Unlimited` et `Limited` là où Magic sépare ordinaire et brillante. Ce n'est pas
la même distinction, et le modèle n'en porte qu'une : `price_usd` reçoit donc
l'édition courante — `Unlimited` d'abord, `1st Edition` à défaut —, et
`price_usd_foil` reste vide. Écrire la première édition dans une colonne nommée
« foil » ferait passer une édition rare pour une brillante, ce qu'aucun écran ne
saurait détromper. La rareté, elle, est déjà portée par l'impression.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_yugioh_prices
    #   --force   réingère même si le jour a déjà été traité
"""

from __future__ import annotations

import re
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.state import last_version, record
from app.ingestion.tcgcsv_prices import BASE, USER_AGENT, euro_rate, to_euros

#: Catégorie TCGplayer de Yu-Gi-Oh, relevée sur `/tcgplayer/categories`.
CATEGORY_YUGIOH = 2

SOURCE = "tcgcsv_yugioh_prices"

#: 656 extensions, deux requêtes chacune. La pause reste celle des autres
#: connecteurs : la source n'annonce aucune limite, et rien ne presse.
PAUSE_SECONDS = 0.3

#: Éditions, par ordre de préférence. `Unlimited` d'abord : c'est le tirage
#: courant, donc le plus probable dans une collection ordinaire. `Normal`
#: n'apparaît que sur une poignée de produits hors normes.
EDITIONS = ("Unlimited", "1st Edition", "Limited", "Normal")

#: « LOB-EN005 » et « LOB-005 » désignent la même impression : le catalogue
#: intercale le code de langue, TCGplayer non. Les deux sont ramenés à
#: (« LOB », « 005 »).
_CODE = re.compile(r"^([A-Z0-9]+)-(?:[A-Z]{2})?([A-Z0-9]+)$")


def print_key(code: str, rarity: str | None) -> tuple[str, str, str] | None:
    """Clé d'impression : extension, numéro nu, rareté."""
    match = _CODE.match((code or "").strip().upper())
    if not match:
        return None
    return match.group(1), match.group(2), (rarity or "").strip().lower()


def _get(client: httpx.Client, url: str) -> Any:
    response = client.get(url)
    response.raise_for_status()
    return response.json()


def group_ids(client: httpx.Client) -> list[int]:
    """Extensions Yu-Gi-Oh connues de TCGplayer."""
    payload = _get(client, f"{BASE}/{CATEGORY_YUGIOH}/groups")
    return [int(g["groupId"]) for g in payload["results"]]


def best_price(rows: Iterable[dict[str, Any]]) -> dict[int, Decimal]:
    """Prix de marché retenu par produit.

    Un produit sans `marketPrice` est simplement absent : mieux vaut qu'il compte
    pour zéro qu'être valorisé sur une annonce aberrante.
    """
    par_produit: dict[int, dict[str, Decimal]] = {}
    for row in rows:
        value = row.get("marketPrice")
        if value is None:
            continue
        par_produit.setdefault(int(row["productId"]), {})[
            row.get("subTypeName") or ""
        ] = Decimal(str(value))

    retenu: dict[int, Decimal] = {}
    for product_id, editions in par_produit.items():
        for edition in EDITIONS:
            if edition in editions:
                retenu[product_id] = editions[edition]
                break
    return retenu


def fetch(client: httpx.Client) -> dict[tuple[str, str, str], Decimal]:
    """Les prix de tout le catalogue, indexés par clé d'impression."""
    prices: dict[tuple[str, str, str], Decimal] = {}
    ids = group_ids(client)
    for index, group_id in enumerate(ids, start=1):
        base = f"{BASE}/{CATEGORY_YUGIOH}/{group_id}"
        try:
            products = _get(client, f"{base}/products")["results"]
            time.sleep(PAUSE_SECONDS)
            par_produit = best_price(_get(client, f"{base}/prices")["results"])
        except httpx.HTTPError:
            # Une extension absente ne doit pas emporter les 655 autres : elle
            # laisse ses cartes non cotées, ce qui est visible, plutôt que
            # d'interrompre une ingestion de plusieurs minutes.
            time.sleep(PAUSE_SECONDS)
            continue
        for product in products:
            extended = {d["name"]: d["value"] for d in product.get("extendedData", [])}
            key = print_key(extended.get("Number", ""), extended.get("Rarity"))
            price = par_produit.get(int(product["productId"]))
            if key and price is not None:
                prices[key] = price
        time.sleep(PAUSE_SECONDS)
        if index % 50 == 0:
            print(f"  {index}/{len(ids)} extensions", end="\r", flush=True)
    return prices


def write_prices(
    conn: psycopg.Connection,
    prices: dict[tuple[str, str, str], Decimal],
    rate: Decimal,
) -> int:
    """Écrit les prix sur les impressions Yu-Gi-Oh. Renvoie le nombre touché.

    Le rapprochement se fait sur les trois composantes de la clé, et le filtre
    sur `cards.game` protège du reste : les codes d'extension ne sont pas
    réservés d'un jeu à l'autre, et `LOB` pourrait exister ailleurs.

    `price_usd_foil` et `price_eur_foil` restent nuls — voir l'en-tête du module.
    """
    #: **Une seule requête, et non une par prix.** Le connecteur Riftbound écrit
    #: ses 1 451 impressions une par une sans que cela se remarque ; ici il y en
    #: a trente mille, et un aller-retour chacun porte l'écriture à une demi-heure
    #: — le même défaut que l'ingestion du catalogue a déjà rencontré. `unnest`
    #: transpose cinq tableaux en autant de lignes, que la jointure consomme d'un
    #: coup. `executemany` ne conviendrait pas ici : il rendrait un `rowcount` par
    #: ligne et non le total des impressions réellement touchées.
    statement = """
        UPDATE public.card_prints p
        SET price_usd = v.usd,
            price_eur = v.eur
        FROM public.cards c,
             unnest(%(set_codes)s::text[], %(nums)s::text[], %(rarities)s::text[],
                    %(usds)s::numeric[], %(eurs)s::numeric[])
                 AS v(set_code, num, rarity, usd, eur)
        WHERE c.oracle_id = p.oracle_id
          AND c.game = 'yugioh'
          AND upper(p.set_code) = v.set_code
          AND upper(regexp_replace(p.collector_number, '^[A-Za-z]{2}', '')) = v.num
          AND lower(p.rarity) = v.rarity
    """

    if not prices:
        return 0

    cles = list(prices)
    with conn.cursor() as cur:
        cur.execute(
            statement,
            {
                "set_codes": [k[0] for k in cles],
                "nums": [k[1] for k in cles],
                "rarities": [k[2] for k in cles],
                "usds": [prices[k] for k in cles],
                "eurs": [to_euros(prices[k], rate) for k in cles],
            },
        )
        touched = cur.rowcount
    conn.commit()
    return touched


def run(*, force: bool = False) -> int:
    today = datetime.now(timezone.utc).date().isoformat()
    config = SupabaseConfig.load()

    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        if not force and (last_version(conn, SOURCE) or "").startswith(today):
            print(f"  prix déjà relevés aujourd'hui ({today}) — rien à faire")
            return 0

        with httpx.Client(
            headers={"User-Agent": USER_AGENT}, timeout=60.0, follow_redirects=True
        ) as client:
            date_taux, rate = euro_rate(client)
            print(f"  taux BCE {date_taux} : 1 € = {rate} $")
            prices = fetch(client)
            print(f"  {len(prices)} impressions cotées chez TCGplayer")

        touched = write_prices(conn, prices, rate)
        print(f"  {touched} impressions valorisées")
        record(
            conn,
            SOURCE,
            version=f"{today} usd_par_eur={rate} (BCE {date_taux})",
            items=touched,
        )
    return 0


def main(argv: list[str]) -> int:
    return run(force="--force" in argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
