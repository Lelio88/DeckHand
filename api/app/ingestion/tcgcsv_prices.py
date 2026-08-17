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
from dataclasses import dataclass
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

#: Traduction vers le vocabulaire de `card_prints.finishes`, qui est celui de
#: Scryfall — c'est lui que lit `card_editions` pour décider quelles finitions
#: proposer, et il ne se négocie pas jeu par jeu.
#:
#: **Ce vocabulaire n'est pas transposable aux autres jeux servis par TCGCSV, et
#: c'est mesuré.** Chez Yu-Gi-Oh, `subTypeName` porte une **édition** —
#: `Unlimited`, `1st Edition`, `Limited` — et non une finition : appliquer cette
#: table là-bas déclarerait « existe en brillante » sur la foi d'un tirage.
#: Chez Pokémon c'en est bien une (`Holofoil`, `Reverse Holofoil`), mais son
#: vocabulaire est plus riche et demande sa propre table.
FINISH_BY_SUBTYPE = {SUBTYPE_NORMAL: "nonfoil", SUBTYPE_FOIL: "foil"}


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


def declared_finishes(rows: Iterable[dict[str, Any]]) -> dict[int, list[str]]:
    """Les finitions que la source **déclare exister**, cotées ou non.

    **La présence de la ligne est le signal, pas la présence du prix.** TCGCSV
    publie une ligne par couple produit-finition, et cette ligne existe même
    quand `marketPrice` est nul — mesuré : 15 lignes dans ce cas sur 1 993, dont
    une qui porte pourtant un `lowPrice`. Déduire les finitions des prix
    conclurait « cette carte n'existe pas en brillante » à partir de « personne
    n'en vend en ce moment », ce qui n'est pas la même phrase.

    C'est ce qui manquait pour que le classeur propose la case « brillante » :
    `card_editions` la refuse dès que `finishes` est vide, et seul le connecteur
    Scryfall la remplissait. Sur Riftbound, cela cachait 511 impressions qui
    existent dans les deux finitions — avec des écarts de prix allant jusqu'à
    dix-huit fois.
    """
    par_produit: dict[int, set[str]] = {}
    for row in rows:
        finish = FINISH_BY_SUBTYPE.get(row.get("subTypeName"))
        if finish is None:
            continue
        par_produit.setdefault(int(row["productId"]), set()).add(finish)
    # Ordre stable : deux courses écrivent le même tableau, et un diff de base
    # ne signale pas un changement là où il n'y en a pas.
    return {pid: sorted(f) for pid, f in par_produit.items()}


@dataclass(frozen=True)
class Products:
    """Ce que TCGCSV dit du catalogue : les prix, et les finitions qui existent.

    Les deux voyagent ensemble parce qu'ils sortent de la **même** réponse : les
    séparer en deux courses doublerait les requêtes et ouvrirait la porte à ce
    qu'un produit soit coté dans une finition qu'on ne déclare pas.
    """

    market: dict[int, dict[str, Decimal]]
    finishes: dict[int, list[str]]

    @property
    def product_ids(self) -> list[int]:
        """Tous les produits connus, cotés **ou seulement déclarés**.

        Itérer sur les seuls produits cotés perdrait précisément les cartes que
        cette correction cherche à récupérer : celles dont la finition est
        publiée sans prix.
        """
        return sorted(set(self.market) | set(self.finishes))


def fetch_products(client: httpx.Client) -> Products:
    """Prix et finitions de tout Riftbound, une requête par extension."""
    market: dict[int, dict[str, Decimal]] = {}
    finishes: dict[int, list[str]] = {}
    for group_id in groups(client):
        payload = _get(client, f"{BASE}/{CATEGORY_RIFTBOUND}/{group_id}/prices")
        market.update(market_prices(payload["results"]))
        finishes.update(declared_finishes(payload["results"]))
        time.sleep(PAUSE_SECONDS)
    return Products(market=market, finishes=finishes)


def write_prices(
    conn: psycopg.Connection,
    products: Products,
    rate: Decimal,
) -> int:
    """Écrit prix et finitions sur les impressions Riftbound.

    Le rapprochement se fait par `tcgplayer_id` et **seulement** par lui : c'est
    un identifiant, pas une ressemblance. Le filtre sur `cards.game` protège du
    reste — TCGplayer numérote tous ses jeux dans le même espace, et une
    collision d'identifiant écrirait un prix Riftbound sur une carte Magic. Il
    protège aussi `finishes` chez Magic, que Scryfall renseigne et qu'on ne veut
    surtout pas réécrire depuis un vocabulaire étranger.

    `COALESCE` sur les finitions et non `EXCLUDED` seul : une course qui ne sait
    rien d'un produit ne doit pas effacer ce qu'une précédente avait appris.
    """
    statement = """
        UPDATE public.card_prints p
        SET price_usd      = %(usd)s,
            price_usd_foil = %(usd_foil)s,
            price_eur      = %(eur)s,
            price_eur_foil = %(eur_foil)s,
            finishes       = COALESCE(%(finishes)s, p.finishes)
        FROM public.cards c
        WHERE c.oracle_id = p.oracle_id
          AND c.game = 'riftbound'
          AND p.tcgplayer_id = %(id)s
    """

    touched = 0
    with conn.cursor() as cur:
        for product_id in products.product_ids:
            by_finish = products.market.get(product_id, {})
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
                    "finishes": products.finishes.get(product_id),
                },
            )
            touched += cur.rowcount
    conn.commit()
    return touched


def coverage(conn: psycopg.Connection) -> dict[str, int]:
    """Ce que la base porte **après** écriture, et non ce qu'on a écrit.

    **Un compteur d'écritures n'est pas un compteur de résultats**, et ce
    connecteur l'a payé : il annonçait « 1 194 impressions valorisées » quand
    492 seulement portaient un prix ordinaire — les autres n'étant cotées qu'en
    brillante. La lecture d'après coup est la seule qui décrive l'état réel.
    """
    with conn.cursor() as cur:
        row = cur.execute(
            """
            SELECT count(*) AS impressions,
                   count(*) FILTER (WHERE p.price_eur IS NOT NULL
                                       OR p.price_eur_foil IS NOT NULL) AS cotees,
                   count(*) FILTER (WHERE 'foil' = ANY(p.finishes))      AS en_brillante,
                   count(*) FILTER (WHERE 'nonfoil' = ANY(p.finishes))   AS en_ordinaire
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'riftbound'
            """
        ).fetchone()
    return dict(zip(("impressions", "cotees", "en_brillante", "en_ordinaire"), row))


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
            print(f"  {len(products.market)} produits cotés chez TCGCSV, "
                  f"{len(products.finishes)} dont les finitions sont déclarées")

        touched = write_prices(conn, products, rate)
        etat = coverage(conn)
        print(f"  {touched} lignes écrites — et voici ce que la base porte :")
        print(f"    {etat['cotees']}/{etat['impressions']} impressions cotées "
              f"dans au moins une finition")
        print(f"    {etat['en_ordinaire']} existent en ordinaire, "
              f"{etat['en_brillante']} en brillante")

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
