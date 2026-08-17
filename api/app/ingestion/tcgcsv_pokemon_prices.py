"""Prix Pokémon, depuis l'export groupé TCGCSV, convertis en euros.

**Pourquoi pas les prix du catalogue.** TCGdex n'en sert aucun en masse : le type
GraphQL `Card` ne porte ni cote ni identifiant TCGplayer — l'introspection le
donne, ses 29 champs sont connus. Les prix n'existent que par la route REST,
carte par carte : 21 000 appels, écarté. C'est donc TCGCSV, comme pour Riftbound
et Yu-Gi-Oh.

**Le rapprochement se joue à deux niveaux, et un seul est difficile.** Dans une
extension, la carte se retrouve exactement : TCGplayer publie le numéro
d'impression (`001/102`) que le catalogue porte sous `localId` (`001`). C'est
l'**extension** qui pose problème, parce que les deux sources la nomment
librement — « SWSH09: Brilliant Stars » contre « Brilliant Stars ».

Ce module s'y prend en trois temps, et l'ordre importe :

1. **le nom propose**, généreusement : on retire le préfixe d'ère et un
   « Base Set » final que TCGplayer ajoute parfois ;
2. **une table d'alias tranche** les cas où les deux sources ont choisi des mots
   différents. Ils sont peu nombreux et systématiques — les promos (« Wizards
   Black Star Promos » contre « WoTC Promo ») et les collections McDonald's ;
3. **la date de sortie dispose.** Un couple dont les dates s'écartent de plus de
   200 jours est refusé.

Le troisième temps n'est pas une précaution théorique. Sans lui, *Base Set*
(1999) s'appariait à *SM Base Set* (2017) : le connecteur aurait écrit des prix
de Soleil et Lune sur des cartes de la première édition, sans qu'aucun écran ne
puisse le détromper. Un rapprochement de noms **produit des faux couples**, pas
seulement des manques, et c'est le faux couple qui coûte cher.

La réciproque est vraie : la date fait un mauvais **critère**. Les neuf POP
Series portent chez TCGplayer une date de publication égale au jour de la
requête — un remplissage. Une date invraisemblable est donc traitée comme une
absence d'information, pas comme un refus.

**Les finitions sont, elles, celles de Magic.** TCGplayer n'en emploie que trois
pour Pokémon — `Normal`, `Holofoil`, `Reverse Holofoil` —, ce qui recouvre
exactement la distinction ordinaire / brillante que le modèle porte déjà. C'est
la différence avec Yu-Gi-Oh, où `1st Edition` et `Unlimited` sont des tirages et
non des finitions, et où `price_eur_foil` reste donc vide.

Usage :
    cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_pokemon_prices
    #   --force   réingère même si le jour a déjà été traité
"""

from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Any, Iterable

import httpx
import psycopg

from app.config import SupabaseConfig
from app.ingestion.state import last_version, record
from app.ingestion.tcgcsv_prices import BASE, USER_AGENT, euro_rate, to_euros

#: Catégorie TCGplayer de Pokémon, relevée sur `/tcgplayer/categories`.
CATEGORY_POKEMON = 3

SOURCE = "tcgcsv_pokemon_prices"
ENDPOINT_TCGDEX = "https://api.tcgdex.net/v2/graphql"

PAUSE_SECONDS = 0.3

#: Série du jeu mobile, écartée du catalogue et donc sans prix de carton.
POCKET_SERIE = "tcgp"

#: Écart maximal toléré entre les deux dates d'un couple. Large à dessein : les
#: deux sources datent l'une la sortie, l'autre la mise en vente, et *Gym Heroes*
#: les sépare de deux mois. C'est un garde-fou contre dix-huit ans d'écart, pas
#: un critère de précision.
DATE_TOLERANCE = timedelta(days=200)

#: Une date de publication à quelques jours de la requête est un remplissage.
PLACEHOLDER_DAYS = 3

#: Finitions, par ordre de préférence dans chaque colonne. `Holofoil` avant
#: `Reverse Holofoil` : la première est le tirage brillant de la carte, la
#: seconde la variante à fond brillant d'un tirage ordinaire.
FINISH_PLAIN = ("Normal",)
FINISH_FOIL = ("Holofoil", "Reverse Holofoil")

#: Traduction vers le vocabulaire de `card_prints.finishes`, celui de Scryfall —
#: c'est lui que lit `card_editions` pour décider quelles finitions proposer.
#:
#: **Trois sous-types, et trois seulement.** Mesuré sur 15 016 lignes tirées de
#: 60 extensions : `Normal`, `Holofoil`, `Reverse Holofoil`, rien d'autre. La
#: table est donc fermée, comme celle de Riftbound.
#:
#: **La brillante inversée est repliée sur `foil`, et c'est déjà le cas des
#: prix.** [FINISH_FOIL] les range depuis toujours dans une même colonne. En
#: faire une troisième valeur demanderait de l'apprendre à `card_editions`, à la
#: collection et à l'écran, pour distinguer deux nuances de brillant — alors que
#: l'inventaire cherche à savoir si l'exemplaire possédé brille.
#:
#: **Le vocabulaire n'est pas celui de Riftbound**, dont la table dit
#: `Foil` : deux jeux servis par la même source nomment différemment la même
#: notion, d'où deux tables et non une constante partagée. Chez Yu-Gi-Oh, le même
#: champ porte une *édition* — la transposer là-bas serait une faute.
FINISH_BY_SUBTYPE = {
    "Normal": "nonfoil",
    "Holofoil": "foil",
    "Reverse Holofoil": "foil",
}

#: Extensions que le nom ne rapproche pas et que la date ne peut pas sauver,
#: faute de candidat. Toutes systématiques : TCGplayer ne dit ni « Black Star »
#: ni « Collection ». Clé = identifiant TCGdex, valeur = nom TCGplayer exact.
ALIASES: dict[str, str] = {
    # Promos, une par ère.
    "basep": "WoTC Promo",
    "np": "Nintendo Promos",
    "dpp": "Diamond and Pearl Promos",
    "hgssp": "HGSS Promos",
    "bwp": "Black and White Promos",
    "xyp": "XY Promos",
    "smp": "SM Promos",
    "swshp": "SWSH: Sword & Shield Promo Cards",
    "svp": "SV: Scarlet & Violet Promo Cards",
    "mep": "ME: Mega Evolution Promo",
    "bog": "Best of Promos",
    # Collections McDonald's : les deux sources inversent les mots.
    "2011bw": "McDonald's Promos 2011",
    "2012bw": "McDonald's Promos 2012",
    "2014xy": "McDonald's Promos 2014",
    "2015xy": "McDonald's Promos 2015",
    "2016xy": "McDonald's Promos 2016",
    "2017sm": "McDonald's Promos 2017",
    "2018sm": "McDonald's Promos 2018",
    "2019sm": "McDonald's Promos 2019",
    "2021swsh": "McDonald's 25th Anniversary Promos",
    "2022swsh": "McDonald's Promos 2022",
    "2023sv": "McDonald's Promos 2023",
    "2024sv": "McDonald's Promos 2024",
    # Deux noms que la normalisation ne peut pas rejoindre.
    "sv03.5": "SV: Scarlet & Violet 151",
    "sm1": "SM Base Set",
}

#: Préfixe d'ère en tête d'un nom TCGplayer : « SWSH09: », « EX », « SM - ».
_PREFIX = re.compile(
    r"^(ex|xy|sm|swsh|sv|bw|hs|dp|pl|me)\b[\s:-]*|^[a-z]{1,6}\d{0,3}\s*:\s*",
    re.IGNORECASE,
)
_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")
#: Zéros de tête d'une suite de chiffres finale : « SWSH001 » -> « SWSH1 ».
_PAD = re.compile(r"(?<![0-9])0+(?=[0-9])")


def name_key(name: str) -> str:
    """Nom réduit à ce qui l'identifie, préfixe d'ère et ponctuation retirés.

    Ne supprime **pas** les mots génériques : réduire « Base Set » à rien
    confondait Base Set et SM Base Set en une clé vide.
    """
    reduced = _PREFIX.sub("", (name or "").strip()).lower().replace("&", "and")
    reduced = re.sub(r"\b(pokemon|pok.mon|tcg)\b", " ", reduced)
    return re.sub(r"[^a-z0-9]+", "", reduced)


def name_keys(name: str) -> set[str]:
    """Clés sous lesquelles un nom TCGplayer peut être cherché.

    TCGplayer ajoute parfois « Base Set » là où le catalogue s'arrête au nom de
    l'ère (« SWSH01: Sword & Shield Base Set » contre « Sword & Shield »).
    """
    key = name_key(name)
    keys = {key}
    if key.endswith("baseset") and len(key) > len("baseset"):
        keys.add(key[: -len("baseset")])
    return keys


def released(text: str | None, *, today: date) -> date | None:
    """Date exploitable, ou `None` quand elle ne dit rien.

    Une publication datée du jour même est un remplissage — voir l'en-tête.
    """
    match = _DATE.match((text or "").strip())
    if not match:
        return None
    day = date(*(int(part) for part in match.groups()))
    if abs((day - today).days) <= PLACEHOLDER_DAYS:
        return None
    return day


def print_number(raw: str | None) -> str | None:
    """Numéro nu, comparable entre les deux sources.

    « 001/102 » et « 001 » désignent la même carte ; « SWSH001 » et « SWSH1 »
    aussi. Le dénominateur tombe, les zéros de tête avec.
    """
    text = (raw or "").split("/")[0].strip().upper()
    if not text:
        return None
    return _PAD.sub("", text)


def _get(client: httpx.Client, url: str) -> Any:
    response = client.get(url)
    response.raise_for_status()
    return response.json()


def tcgdex_sets(client: httpx.Client) -> list[dict[str, Any]]:
    """Extensions du catalogue, hors jeu mobile.

    Requête POST : en GET, l'endpoint rend la page GraphiQL — voir
    `tcgdex_ingest`.
    """
    response = client.post(
        ENDPOINT_TCGDEX,
        json={"query": "{sets{id name releaseDate serie{id}}}"},
        timeout=120.0,
    )
    response.raise_for_status()
    sets = response.json()["data"]["sets"]
    return [s for s in sets if (s.get("serie") or {}).get("id") != POCKET_SERIE]


def match_sets(
    sets: Iterable[dict[str, Any]],
    groups: Iterable[dict[str, Any]],
    *,
    today: date,
) -> tuple[dict[str, int], list[str]]:
    """Couples (extension du catalogue -> groupe TCGplayer), et les laissés-pour-compte.

    Le nom propose, les alias tranchent, la date dispose — dans cet ordre.
    """
    groups = list(groups)
    by_name: dict[str, list[dict[str, Any]]] = {}
    by_exact: dict[str, dict[str, Any]] = {}
    for group in groups:
        by_exact[group["name"]] = group
        for key in name_keys(group["name"]):
            if key:
                by_name.setdefault(key, []).append(group)

    taken: dict[str, int] = {}
    orphans: list[str] = []
    for card_set in sets:
        alias = ALIASES.get(card_set["id"])
        candidates = (
            [by_exact[alias]]
            if alias and alias in by_exact
            else by_name.get(name_key(card_set["name"]), [])
        )
        if not candidates:
            orphans.append(card_set["id"])
            continue

        set_day = released(card_set.get("releaseDate"), today=today)
        plausible: list[tuple[timedelta, dict[str, Any]]] = []
        for group in candidates:
            group_day = released(group.get("publishedOn"), today=today)
            if set_day is None or group_day is None:
                # Aucune information : on ne refuse pas sur une date absente.
                plausible.append((timedelta(0), group))
            elif abs(group_day - set_day) <= DATE_TOLERANCE:
                plausible.append((abs(group_day - set_day), group))

        if not plausible:
            orphans.append(card_set["id"])
            continue
        taken[card_set["id"]] = int(min(plausible, key=lambda p: p[0])[1]["groupId"])
    return taken, orphans


def best_prices(
    rows: Iterable[dict[str, Any]],
) -> dict[int, tuple[Decimal | None, Decimal | None]]:
    """Par produit, le prix ordinaire et le prix brillant.

    Un produit sans `marketPrice` est simplement absent : mieux vaut qu'il ne
    compte pas qu'être valorisé sur une annonce aberrante.
    """
    by_product: dict[int, dict[str, Decimal]] = {}
    for row in rows:
        value = row.get("marketPrice")
        if value is None:
            continue
        finish = row.get("subTypeName") or ""
        by_product.setdefault(int(row["productId"]), {})[finish] = Decimal(str(value))

    def pick(finishes: dict[str, Decimal], order: Iterable[str]) -> Decimal | None:
        for finish in order:
            if finish in finishes:
                return finishes[finish]
        return None

    return {
        product_id: (pick(finishes, FINISH_PLAIN), pick(finishes, FINISH_FOIL))
        for product_id, finishes in by_product.items()
    }


def declared_finishes(rows: Iterable[dict[str, Any]]) -> dict[int, list[str]]:
    """Les finitions que la source **déclare exister**, cotées ou non.

    **La présence de la ligne est le signal, pas la présence du prix.** TCGCSV
    publie une ligne par couple produit-finition, et elle existe même quand
    `marketPrice` est nul — mesuré, 112 lignes dans ce cas sur 15 016. Déduire
    les finitions des prix conclurait « cette carte n'existe pas en brillante »
    à partir de « personne n'en vend en ce moment », ce qui n'est pas la même
    phrase.

    C'est ce qui manquait pour que le classeur propose la case « brillante » :
    `card_editions` la refuse dès que `finishes` est vide, et seul le connecteur
    Scryfall la remplissait. Chez Pokémon, la combinaison la plus courante est
    précisément `Normal` + `Reverse Holofoil` — 3 493 produits sur l'échantillon
    mesuré, soit un tiers.
    """
    par_produit: dict[int, set[str]] = {}
    for row in rows:
        finish = FINISH_BY_SUBTYPE.get(row.get("subTypeName") or "")
        if finish is None:
            continue
        par_produit.setdefault(int(row["productId"]), set()).add(finish)
    # Ordre stable : deux courses écrivent le même tableau, et un diff de base ne
    # signale pas un changement là où il n'y en a pas.
    return {pid: sorted(f) for pid, f in par_produit.items()}


@dataclass(frozen=True)
class Quote:
    """Ce que la source dit d'une impression : ses prix, et ses finitions.

    Les trois voyagent ensemble parce qu'ils sortent de la **même** réponse. Une
    impression peut n'avoir aucun prix et une finition déclarée : c'est
    exactement le cas que cette classe existe pour ne plus perdre.
    """

    plain: Decimal | None = None
    foil: Decimal | None = None
    finishes: tuple[str, ...] = ()

    @property
    def worth_writing(self) -> bool:
        return self.plain is not None or self.foil is not None or bool(self.finishes)


def fetch(
    client: httpx.Client, pairs: dict[str, int]
) -> dict[tuple[str, str], Quote]:
    """Prix et finitions, indexés par (extension du catalogue, numéro nu)."""
    quotes: dict[tuple[str, str], Quote] = {}
    for index, (set_id, group_id) in enumerate(pairs.items(), start=1):
        root = f"{BASE}/{CATEGORY_POKEMON}/{group_id}"
        try:
            products = _get(client, f"{root}/products")["results"]
            time.sleep(PAUSE_SECONDS)
            rows = _get(client, f"{root}/prices")["results"]
        except httpx.HTTPError:
            # Une extension absente laisse ses cartes non cotées — visible —
            # plutôt que d'emporter les cent quarante autres.
            time.sleep(PAUSE_SECONDS)
            continue
        by_product = best_prices(rows)
        finishes = declared_finishes(rows)
        for product in products:
            extended = {d["name"]: d["value"] for d in product.get("extendedData", [])}
            number = print_number(extended.get("Number"))
            product_id = int(product["productId"])
            plain, foil = by_product.get(product_id, (None, None))
            quote = Quote(plain, foil, tuple(finishes.get(product_id, ())))
            # Les produits scellés (coffrets, displays) n'ont pas de numéro.
            if number and quote.worth_writing:
                quotes[(set_id, number)] = quote
        time.sleep(PAUSE_SECONDS)
        if index % 25 == 0:
            print(f"  {index}/{len(pairs)} extensions", end="\r", flush=True)
    return quotes


def write_prices(
    conn: psycopg.Connection,
    quotes: dict[tuple[str, str], Quote],
    rate: Decimal,
) -> int:
    """Écrit prix et finitions sur les impressions Pokémon. Rend le nombre touché.

    Une seule requête : `unnest` transpose les tableaux en autant de lignes, que
    la jointure consomme d'un coup — vingt mille allers-retours porteraient
    l'écriture à la demi-heure. Le filtre sur `cards.game` protège des
    identifiants d'extension qui ne sont réservés d'aucun jeu, et il protège
    aussi `finishes` chez Magic, que Scryfall renseigne et qu'on ne veut surtout
    pas réécrire depuis un vocabulaire étranger.

    `COALESCE` sur les finitions : une course qui ne sait rien d'une impression
    ne doit pas effacer ce qu'une précédente avait appris.
    """
    if not quotes:
        return 0

    statement = """
        UPDATE public.card_prints p
        SET price_usd      = v.usd,
            price_eur      = v.eur,
            price_usd_foil = v.usd_foil,
            price_eur_foil = v.eur_foil,
            -- **Les finitions voyagent en texte, découpé ici.** `unnest` ne sait
            -- pas transposer un tableau de tableaux : il aplatirait les deux
            -- dimensions et décalerait toutes les colonnes d'une ligne à
            -- l'autre. Une chaîne « foil,nonfoil » par impression reste un
            -- `text[]` ordinaire du point de vue de la transposition.
            finishes       = COALESCE(string_to_array(v.finishes, ','), p.finishes)
        FROM public.cards c,
             unnest(%(sets)s::text[], %(nums)s::text[],
                    %(usd)s::numeric[], %(eur)s::numeric[],
                    %(usd_foil)s::numeric[], %(eur_foil)s::numeric[],
                    %(finishes)s::text[])
                 AS v(set_code, num, usd, eur, usd_foil, eur_foil, finishes)
        WHERE c.oracle_id = p.oracle_id
          AND c.game = 'pokemon'
          AND p.set_code = v.set_code
          -- Même normalisation que `print_number` : les zéros de tête d'une
          -- suite de chiffres tombent, le caractère qui précède est restitué.
          AND regexp_replace(upper(p.collector_number), '(^|[^0-9])0+([0-9])',
                             '\1\2', 'g') = v.num
    """

    keys = list(quotes)
    with conn.cursor() as cur:
        cur.execute(
            statement,
            {
                "sets": [k[0] for k in keys],
                "nums": [k[1] for k in keys],
                "usd": [quotes[k].plain for k in keys],
                "eur": [to_euros(quotes[k].plain, rate) for k in keys],
                "usd_foil": [quotes[k].foil for k in keys],
                "eur_foil": [to_euros(quotes[k].foil, rate) for k in keys],
                "finishes": [",".join(quotes[k].finishes) or None for k in keys],
            },
        )
        touched = cur.rowcount
    conn.commit()
    return touched


def coverage(conn: psycopg.Connection) -> dict[str, int]:
    """Ce que la base porte **après** écriture, et non ce qu'on a écrit.

    Un compteur d'écritures n'est pas un compteur de résultats : la leçon vient
    du corpus Limitless, et la valorisation Riftbound l'a repayée en annonçant
    1 194 impressions cotées là où 492 portaient un prix ordinaire.
    """
    with conn.cursor() as cur:
        row = cur.execute(
            """
            SELECT count(*),
                   count(*) FILTER (WHERE p.price_eur IS NOT NULL
                                       OR p.price_eur_foil IS NOT NULL),
                   count(*) FILTER (WHERE 'foil' = ANY(p.finishes)),
                   count(*) FILTER (WHERE 'nonfoil' = ANY(p.finishes))
            FROM public.card_prints p
            JOIN public.cards c ON c.oracle_id = p.oracle_id
            WHERE c.game = 'pokemon'
            """
        ).fetchone()
    return dict(zip(("impressions", "cotees", "en_brillante", "en_ordinaire"), row))


def run(*, force: bool = False) -> int:
    today = datetime.now(timezone.utc).date()
    stamp = today.isoformat()
    config = SupabaseConfig.load()

    with psycopg.connect(config.db_url, connect_timeout=60) as conn:
        if not force and (last_version(conn, SOURCE) or "").startswith(stamp):
            print(f"  prix déjà relevés aujourd'hui ({stamp}) — rien à faire")
            return 0

        with httpx.Client(
            headers={"User-Agent": USER_AGENT}, timeout=60.0, follow_redirects=True
        ) as client:
            date_taux, rate = euro_rate(client)
            print(f"  taux BCE {date_taux} : 1 € = {rate} $")

            sets = tcgdex_sets(client)
            groups = _get(client, f"{BASE}/{CATEGORY_POKEMON}/groups")["results"]
            pairs, orphans = match_sets(sets, groups, today=today)
            # Le compte des laissés-pour-compte est imprimé : une couverture
            # partielle doit se voir, un silence ne vaut pas un succès.
            print(
                f"  {len(pairs)}/{len(sets)} extensions appariées, "
                f"{len(orphans)} sans prix"
            )

            quotes = fetch(client, pairs)
            print(f"  {len(quotes)} impressions connues chez TCGplayer")

        touched = write_prices(conn, quotes, rate)
        etat = coverage(conn)
        print(f"  {touched} lignes écrites — et voici ce que la base porte :")
        print(f"    {etat['cotees']}/{etat['impressions']} impressions cotées "
              f"dans au moins une finition")
        print(f"    {etat['en_ordinaire']} existent en ordinaire, "
              f"{etat['en_brillante']} en brillante")
        record(
            conn,
            SOURCE,
            version=f"{stamp} usd_par_eur={rate} (BCE {date_taux})",
            items=touched,
        )
    return 0


def main(argv: list[str]) -> int:
    return run(force="--force" in argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
