"""Prix Riftbound, depuis l'export groupé TCGCSV, convertis en euros.

**Le manque que ça comble.** Riftbound n'avait aucun prix : la collection ne se
valorisait pas, un deck ne se chiffrait pas, et c'est précisément ce que
DeckHand apporte en propre pour ce jeu. La source du catalogue, Riftcodex, ne
cote rien — sa spec OpenAPI ne porte que cartes et extensions. Elle sert en
revanche le `tcgplayer_id` de chaque impression, et c'est ce chaînage qu'on
suit ici.

**Pourquoi TCGCSV et pas un agrégateur.** Les API tierces relevées plafonnent à
une centaine de requêtes par jour en gratuit : un seul passage sur 1 451
impressions y demanderait une quinzaine de jours, quand les prix se
rafraîchissent quotidiennement. Le palier gratuit ne permet donc même pas un
cycle. TCGCSV publie les données TCGplayer par catégorie, rafraîchies chaque
jour vers 20:00 UTC : **tout le catalogue Riftbound tient en 21 requêtes**, soit
quelques secondes. C'est l'équivalent des *bulk data* de Scryfall, ce qui rend
l'ingestion Magic soutenable depuis le premier jour.

**Ses conditions d'utilisation ne sont pas publiées** — même configuration que
Riftcodex, et le garde-fou §IV impose de le dire plutôt que de l'ignorer. On lui
applique donc les règles de Scryfall : `User-Agent` descriptif, débit
volontairement bas, attribution visible dans l'écran « à propos ».

**Les euros sont convertis, pas relevés.** TCGplayer cote en dollars et
l'application affiche des euros de bout en bout. La conversion passe par le
**taux de référence quotidien de la Banque centrale européenne** — une donnée
publique, officielle et datée, non un taux inventé. Elle n'en fait pas pour
autant un prix de marché européen : Cardmarket et TCGplayer divergent sur ce
jeu. Le taux employé et sa date sont donc consignés dans `ingestion_state`, et
le dollar d'origine est conservé dans `price_usd` — le chiffre relevé et le
chiffre dérivé cohabitent, on peut toujours remonter à la source.

**Les 227 impressions de `VEN` restent sans prix.** Riftcodex ne leur a pas
encore attribué de `tcgplayer_id`, l'extension étant sortie le 31 juillet 2026.
TCGCSV, lui, connaît le groupe : on pourrait rapprocher par nom et numéro. On ne
le fait pas — un rapprochement approximatif écrirait un prix plausible sur la
mauvaise carte sans que rien ne le signale, là où une carte sans cote compte
pour zéro, ce qui est faux mais visible. Le chaînage arrivera par la source.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_prices
    #   --force   réingère même si le jour a déjà été traité
"""

from __future__ import annotations

import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.state import last_version, record

USER_AGENT = (
    "DeckHand/1.0 (collection perso, non commercial; "
    "contact via github.com/Lelio88/DeckHand)"
)

BASE = "https://tcgcsv.com/tcgplayer"
#: Catégorie TCGplayer de Riftbound, relevée sur `/tcgplayer/categories`.
CATEGORY_RIFTBOUND = 89

#: Taux de référence quotidiens de la BCE. Un seul fichier, 1,5 ko, sans clé.
ECB_DAILY = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"

SOURCE = "tcgcsv_prices"

#: Politesse envers une source qui n'annonce aucune limite. Vingt requêtes, on
#: peut se permettre d'attendre.
PAUSE_SECONDS = 0.3

#: Le nom que TCGplayer donne à la finition ordinaire et à la brillante.
SUBTYPE_NORMAL = "Normal"
SUBTYPE_FOIL = "Foil"


def _get(client: httpx.Client, url: str) -> Any:
    response = client.get(url)
    response.raise_for_status()
    return response.json()


def euro_rate(client: httpx.Client) -> tuple[str, Decimal]:
    """Taux BCE du jour : combien de dollars vaut un euro, et à quelle date.

    La date rendue est celle de la BCE, pas celle du jour : elle ne publie pas
    les week-ends ni les jours fériés, et le taux du vendredi tient jusqu'au
    lundi. La consigner évite de faire croire à une fraîcheur qu'elle n'a pas.
    """
    response = client.get(ECB_DAILY)
    response.raise_for_status()
    root = ET.fromstring(response.content)

    for cube in root.iter():
        if not cube.tag.endswith("Cube") or "time" not in cube.attrib:
            continue
        for line in cube:
            if line.attrib.get("currency") == "USD":
                return cube.attrib["time"], Decimal(line.attrib["rate"])
    raise RuntimeError("taux EUR/USD absent de la publication BCE")


def to_euros(usd: Decimal | None, rate: Decimal) -> Decimal | None:
    """Convertit un montant en dollars, au centime.

    `rate` est le taux BCE tel qu'il est publié : le nombre de dollars que vaut
    un euro. On divise donc, on ne multiplie pas — l'erreur inverse donnerait
    des prix majorés de 33 % qui resteraient parfaitement plausibles à l'œil.
    """
    if usd is None:
        return None
    return (usd / rate).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def groups(client: httpx.Client) -> list[int]:
    """Extensions Riftbound connues de TCGplayer."""
    payload = _get(client, f"{BASE}/{CATEGORY_RIFTBOUND}/groups")
    return [int(g["groupId"]) for g in payload["results"]]


def market_prices(rows: Iterable[dict[str, Any]]) -> dict[int, dict[str, Decimal]]:
    """Prix de marché par produit, séparés ordinaire et brillant.

    **`marketPrice` et non `lowPrice`.** Le prix bas est une annonce isolée, qui
    peut être une carte abîmée ou une erreur de saisie ; le prix de marché est
    la valeur calculée par TCGplayer sur les ventes réelles. C'est aussi ce que
    Scryfall publie pour Magic — les deux jeux se valorisent donc sur la même
    notion, ce qui est la condition pour que les totaux se comparent.

    Un produit sans prix de marché est simplement absent : mieux vaut qu'il
    compte pour zéro qu'être valorisé sur une annonce aberrante.
    """
    result: dict[int, dict[str, Decimal]] = {}
    for row in rows:
        value = row.get("marketPrice")
        if value is None:
            continue
        subtype = row.get("subTypeName")
        if subtype not in (SUBTYPE_NORMAL, SUBTYPE_FOIL):
            continue
        result.setdefault(int(row["productId"]), {})[subtype] = Decimal(str(value))
    return result


def fetch_prices(client: httpx.Client) -> dict[int, dict[str, Decimal]]:
    """Tous les prix Riftbound, une requête par extension."""
    prices: dict[int, dict[str, Decimal]] = {}
    for group_id in groups(client):
        payload = _get(client, f"{BASE}/{CATEGORY_RIFTBOUND}/{group_id}/prices")
        prices.update(market_prices(payload["results"]))
        time.sleep(PAUSE_SECONDS)
    return prices


def write_prices(
    conn: psycopg.Connection,
    prices: dict[int, dict[str, Decimal]],
    rate: Decimal,
) -> int:
    """Écrit les prix sur les impressions Riftbound. Renvoie le nombre touché.

    Le rapprochement se fait par `tcgplayer_id` et **seulement** par lui : c'est
    un identifiant, pas une ressemblance. Le filtre sur `cards.game` protège du
    reste — TCGplayer numérote tous ses jeux dans le même espace, et une
    collision d'identifiant écrirait un prix Riftbound sur une carte Magic.
    """
    statement = """
        UPDATE public.card_prints p
        SET price_usd      = %(usd)s,
            price_usd_foil = %(usd_foil)s,
            price_eur      = %(eur)s,
            price_eur_foil = %(eur_foil)s
        FROM public.cards c
        WHERE c.oracle_id = p.oracle_id
          AND c.game = 'riftbound'
          AND p.tcgplayer_id = %(id)s
    """

    touched = 0
    with conn.cursor() as cur:
        for product_id, by_finish in prices.items():
            usd = by_finish.get(SUBTYPE_NORMAL)
            usd_foil = by_finish.get(SUBTYPE_FOIL)
            cur.execute(
                statement,
                {
                    "id": product_id,
                    "usd": usd,
                    "usd_foil": usd_foil,
                    "eur": to_euros(usd, rate),
                    "eur_foil": to_euros(usd_foil, rate),
                },
            )
            touched += cur.rowcount
    conn.commit()
    return touched


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

            prices = fetch_prices(client)
            print(f"  {len(prices)} produits cotés chez TCGCSV")

        touched = write_prices(conn, prices, rate)
        print(f"  {touched} impressions Riftbound valorisées")

        record(
            conn,
            SOURCE,
            version=f"{today} usd_par_eur={rate} (BCE {rate_date})",
            items=touched,
        )
    return 0


def main(argv: list[str]) -> int:
    return run(force="--force" in argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
