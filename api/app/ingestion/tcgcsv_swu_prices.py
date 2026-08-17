"""Prix Star Wars Unlimited, depuis l'export groupé TCGCSV, convertis en euros.

Cinquième jeu coté du projet, et le plus direct : SWU-DB sert un `tcgplayerId`
sur **99,3 %** de ses entrées, si bien que le rapprochement est un identifiant
et non une ressemblance. Riftbound doit composer avec 227 impressions non
chaînées, Yu-Gi-Oh et Pokémon avec un rapprochement par extension et numéro qui
a coûté deux tables d'alias et un veto par date. Ici, rien de tout cela.

**Ce connecteur n'écrit pas les finitions, et c'est un choix mesuré.** Les
quatre autres jeux les tirent de TCGCSV faute de mieux ; SWU les tient de son
catalogue, où `VariantType` les déclare pour **100 %** des impressions quand
TCGCSV n'en couvre que 99,3 %. La source la plus complète fait autorité, et le
connecteur se contente de **vérifier la concordance** : une divergence entre les
deux serait un signal, pas un détail, et la taire reviendrait à ne jamais savoir
laquelle des deux se trompe.

**Le vocabulaire de `subTypeName` est bien celui de Riftbound** — `Normal` et
`Foil`, relevés sur six extensions — et non celui de Yu-Gi-Oh, dont le champ
homologue porte une **édition** (`Unlimited`, `1st Edition`). Cette
vérification n'est pas une formalité : appliquer la table de Riftbound à
Yu-Gi-Oh déclarerait « existe en brillante » sur la foi d'un tirage.

**Les euros sont convertis, pas relevés**, par le taux de référence quotidien de
la Banque centrale européenne — donnée publique, officielle et datée. Le dollar
d'origine reste dans `price_usd` : le chiffre relevé et le chiffre dérivé
cohabitent, on peut toujours remonter à la source. Le taux et sa date sont
consignés dans `ingestion_state`.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_swu_prices
    #   --force   réingère même si le jour a déjà été traité
"""

from __future__ import annotations

import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
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

GAME = "swu"

#: Catégorie TCGplayer de Star Wars Unlimited, relevée sur `/tcgplayer/categories`.
CATEGORY_SWU = 79

SOURCE = "tcgcsv_swu_prices"


#: Reprises à attente croissante — 1, 2, 4, 8, 16 secondes.
#:
#: **Le connecteur Riftbound n'en a pas, et il n'en a pas besoin** : vingt et
#: une requêtes passent sans incident. SWU en demande trente et une, et la
#: première course a été coupée en vol — « Server disconnected without sending
#: a response » — sur un réseau qui lâche par à-coups de quelques dizaines de
#: secondes. Cinq tentatives couvrent 31 secondes d'attente cumulée, assez pour
#: traverser une coupure ordinaire sans transformer une course de deux minutes
#: en veille d'une heure.
ATTEMPTS = 5
FIRST_DELAY = 1.0


def _get(client: httpx.Client, url: str) -> Any:
    """Réponse JSON de [url], en reprenant sur coupure.

    Un 404 n'est **pas** repris : la ressource n'existe pas, et réessayer cinq
    fois ne la fera pas apparaître. Les autres échecs le sont — une coupure de
    transport comme un 503 sont précisément ce que l'attente croissante existe
    pour absorber.
    """
    delay = FIRST_DELAY
    last: Exception | None = None
    for _ in range(ATTEMPTS):
        try:
            response = client.get(url)
            if response.status_code == 404:
                response.raise_for_status()
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


def groups(client: httpx.Client) -> list[int]:
    """Extensions SWU connues de TCGplayer — trente et une, contre 38 chez SWU-DB."""
    payload = _get(client, f"{BASE}/{CATEGORY_SWU}/groups")
    return [int(g["groupId"]) for g in payload["results"]]


@dataclass(frozen=True)
class Products:
    """Ce que TCGCSV publie pour ce jeu."""

    market: dict[int, dict[str, Decimal]]
    #: Les finitions **déclarées** par la source des prix. Elles ne sont pas
    #: écrites : elles servent au contrôle de concordance avec le catalogue.
    declared: dict[int, set[str]]

    @property
    def product_ids(self) -> list[int]:
        return sorted(set(self.market) | set(self.declared))


def declared_subtypes(rows: Iterable[dict[str, Any]]) -> dict[int, set[str]]:
    """Les finitions que TCGCSV déclare exister, cotées ou non.

    **La présence de la ligne est le signal, pas celle du prix** : TCGCSV publie
    une ligne par couple produit-finition, même sans `marketPrice`. Déduire les
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
    """Prix et finitions de tout SWU, une requête par extension."""
    market: dict[int, dict[str, Decimal]] = {}
    declared: dict[int, set[str]] = {}
    for group_id in groups(client):
        payload = _get(client, f"{BASE}/{CATEGORY_SWU}/{group_id}/prices")
        market.update(market_prices(payload["results"]))
        declared.update(declared_subtypes(payload["results"]))
        time.sleep(PAUSE_SECONDS)
    return Products(market=market, declared=declared)


def write_prices(conn: psycopg.Connection, products: Products, rate: Decimal) -> int:
    """Écrit les prix sur les impressions SWU, et **rien d'autre**.

    Le rapprochement se fait par `tcgplayer_id` et seulement par lui : c'est un
    identifiant, pas une ressemblance. Le filtre sur `cards.game` protège du
    reste — TCGplayer numérote tous ses jeux dans le même espace, et une
    collision d'identifiant écrirait un prix SWU sur une carte Magic.

    **`finishes` est écrite ici, et le catalogue n'en est que le repli** — la
    mesure a renversé la décision inverse. Le catalogue couvre bien 100 % des
    impressions quand TCGCSV n'en chaîne que 99,3 %, mais couvrir n'est pas
    avoir raison : sur 5 154 impressions comparées, **1 981 seulement
    concordaient**. Les écarts ne sont pas du bruit —

    * **517 `Showcase`** n'existent qu'en brillante chez TCGplayer et le
      catalogue les déclarait ordinaires : une case que le carton n'a jamais
      eue, proposée à la saisie ;
    * **465 `OP Promo`** existent dans les deux finitions, le catalogue n'en
      connaissait qu'une ;
    * **2 165** cartes ordinaires que le catalogue disait aussi brillantes.

    `VariantType` ne publie une entrée brillante que lorsque la source l'a
    saisie ; `subTypeName` décrit ce qui se vend. C'est ce dernier qui répond à
    la question posée — « cette impression existe-t-elle en brillante ? » — et
    c'est déjà lui qui fait autorité pour Riftbound et Pokémon.

    **Les écritures sont groupées, et il l'a fallu.** Riftbound met à jour ses
    1 451 impressions une par une sans que cela se remarque ; à **7 916
    produits**, un aller-retour par ligne vers une base distante a fait *tomber
    la connexion* — « server closed the connection unexpectedly » en pleine
    course. C'est le seuil qu'avait déjà rencontré Yu-Gi-Oh et ses 44 139
    impressions. `executemany` les regroupe.
    """
    statement = """
        UPDATE public.card_prints p
        SET price_usd      = %(usd)s,
            price_usd_foil = %(usd_foil)s,
            price_eur      = %(eur)s,
            price_eur_foil = %(eur_foil)s,
            -- `COALESCE` : un produit dont TCGCSV ne déclare aucune finition
            -- laisse en place ce que le catalogue avait su. L'écraser à `NULL`
            -- rendrait l'impression impossible à saisir, `card_editions` la
            -- refusant dans les deux finitions.
            finishes       = COALESCE(%(finishes)s, p.finishes)
        FROM public.cards c
        WHERE c.oracle_id = p.oracle_id
          AND c.game = 'swu'
          AND p.tcgplayer_id = %(id)s
    """
    rows = []
    for product_id in products.product_ids:
        by_finish = products.market.get(product_id, {})
        usd = by_finish.get(SUBTYPE_NORMAL)
        usd_foil = by_finish.get(SUBTYPE_FOIL)
        declared = products.declared.get(product_id)
        rows.append(
            {
                "id": str(product_id),
                "usd": usd,
                "usd_foil": usd_foil,
                "eur": to_euros(usd, rate),
                "eur_foil": to_euros(usd_foil, rate),
                # Trié pour que deux courses écrivent la même valeur : sans
                # cela, un ensemble Python rendrait un ordre variable et le
                # diff d'une réingestion serait illisible.
                "finishes": sorted(declared) if declared else None,
            }
        )
    with conn.cursor() as cur:
        cur.executemany(statement, rows)
    conn.commit()
    # Le nombre de paramètres envoyés, pas de lignes touchées : `executemany`
    # ne les distingue pas. C'est `coverage` qui dit ce que la base porte, et
    # c'est elle qu'il faut lire — un compteur d'écritures n'est pas un
    # compteur de résultats.
    return len(rows)


def check_finishes(conn: psycopg.Connection, products: Products) -> dict[str, int]:
    """De combien l'état en base s'écarte-t-il de TCGCSV, **avant** écriture ?

    **À appeler avant, et pas après** : une fois `finishes` réécrite depuis
    TCGCSV, la comparer à TCGCSV rendrait l'accord parfait quoi qu'il arrive —
    un contrôle qui ne peut pas échouer, c'est-à-dire une approbation sans
    contenu. Le même piège s'était présenté dans le banc de mesure, où un
    contrôle vérifiait une propriété vraie par construction.

    **Ce qu'il mesure a changé de sens en route, et il faut le dire.** À la
    première course, la base portait ce que le catalogue avait écrit, et l'écart
    — 3 173 impressions sur 5 154 — a renversé la décision de lui faire
    autorité : 517 `Showcase` y étaient déclarées ordinaires alors qu'elles
    n'existent qu'en brillante. Depuis que TCGCSV écrit cette colonne, l'écart
    tombe à zéro et ne mesure plus les deux sources l'une contre l'autre, mais
    une éventuelle **dérive de la base** — une réingestion du catalogue qui
    réécrirait la colonne, une carte modifiée à la main. C'est moins qu'avant,
    et ce n'est pas rien.
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT p.tcgplayer_id, p.finishes
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'swu' AND p.tcgplayer_id IS NOT NULL
            """
        ).fetchall()

    tally = {"compares": 0, "concordent": 0, "catalogue_seul": 0, "tcgcsv_seul": 0}
    for tcgplayer_id, finishes in rows:
        declared = products.declared.get(int(tcgplayer_id))
        if declared is None:
            continue
        ours = set(finishes or ())
        tally["compares"] += 1
        if ours == declared:
            tally["concordent"] += 1
        else:
            if ours - declared:
                tally["catalogue_seul"] += 1
            if declared - ours:
                tally["tcgcsv_seul"] += 1
    return tally


def coverage(conn: psycopg.Connection) -> dict[str, int]:
    """Ce que la base porte **après** écriture, et non ce qu'on a écrit.

    Un compteur d'écritures n'est pas un compteur de résultats : le connecteur
    Riftbound annonçait « 1 194 impressions valorisées » quand 492 seulement
    portaient un prix ordinaire, les autres n'étant cotées qu'en brillante.
    """
    with conn.cursor() as cur:
        row = cur.execute(
            """
            SELECT count(*) AS impressions,
                   count(*) FILTER (WHERE p.price_eur IS NOT NULL
                                       OR p.price_eur_foil IS NOT NULL) AS cotees,
                   count(*) FILTER (WHERE p.price_eur IS NOT NULL)      AS en_ordinaire,
                   count(*) FILTER (WHERE p.price_eur_foil IS NOT NULL) AS en_brillante
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'swu'
            """
        ).fetchone()
    return dict(zip(("impressions", "cotees", "en_ordinaire", "en_brillante"), row))


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
                  f"{len(products.declared)} dont les finitions sont déclarées")

        # Avant l'écriture : après, la comparaison serait tautologique.
        accord = check_finishes(conn, products)
        print(f"  écart base / TCGCSV avant écriture : "
              f"{accord['compares'] - accord['concordent']}/{accord['compares']} "
              f"impressions divergent")
        if accord["catalogue_seul"] or accord["tcgcsv_seul"]:
            print(f"    {accord['catalogue_seul']} finitions déclarées par la seule "
                  f"base, {accord['tcgcsv_seul']} par le seul TCGCSV")

        touched = write_prices(conn, products, rate)
        etat = coverage(conn)
        print(f"  {touched} produits soumis — et voici ce que la base porte :")
        print(f"    {etat['cotees']}/{etat['impressions']} impressions cotées "
              f"dans au moins une finition")
        print(f"    {etat['en_ordinaire']} en ordinaire, "
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
