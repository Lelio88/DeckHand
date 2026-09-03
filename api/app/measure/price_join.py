"""Ce que coûte le prix le moins cher, selon la façon dont on le joint.

**Pourquoi ce banc existe.** L'application rendait régulièrement
`canceling statement due to statement timeout` (57014) : le rôle `authenticated`
coupe à huit secondes, et le scan d'un étalement les dépassait. Le volume n'y
était pour rien — mesuré, cent cinquante noms tiennent en trois secondes à
chaud, et du texte qui ne ressemble à aucune carte coûte *moins* cher qu'un vrai
nom, la recherche floue ne trouvant rien à relire.

Le coupable est `card_cheapest_price`, une vue
`SELECT oracle_id, min(price_eur) ... GROUP BY oracle_id`. Postgres ne pousse
pas le filtre à travers son agrégat : il la calcule **pour tout le catalogue**
— 245 468 impressions, 76 873 cartes — puis joint les cinquante cartes trouvées.

**Ce qui se mesure ici n'est pas la moyenne mais les blocs touchés.** Un timeout
n'arrive pas quand la requête est lente en moyenne, il arrive quand le cache est
froid et qu'il faut aller lire au disque ce qu'on croyait gratuit. Les blocs
disent ce que coûterait ce moment-là ; le temps à chaud le cache.

Usage :

    cd api && .venv/Scripts/python -m app.measure.price_join
    cd api && .venv/Scripts/python -m app.measure.price_join --noms 10 50 150
"""

from __future__ import annotations

import argparse
import re
import statistics
import time

import httpx
import psycopg

from app.config import SupabaseConfig, load_env_file

# Le corps de `search_cards_bulk`, réduit à ce qui compte ici : la recherche
# par nom, puis le prix. Deux façons de joindre le prix, tout le reste égal.
CORPS = """
    WITH needles AS (
        SELECT DISTINCT t.txt AS query, public.normalize_card_name(t.txt) AS n
        FROM unnest(%(noms)s::text[]) AS t(txt)
        WHERE public.normalize_card_name(t.txt) <> ''
    )
    SELECT nd.query, b.oracle_id, b.name, {prix} AS price_eur,
           (SELECT pr.art_crop_url FROM public.card_prints pr
            WHERE pr.oracle_id = b.oracle_id AND pr.art_crop_url IS NOT NULL
            ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST, pr.scryfall_id
            LIMIT 1)
    FROM needles nd
    CROSS JOIN LATERAL (
        SELECT c.oracle_id, c.name,
               GREATEST(similarity(s.normalized, nd.n),
                   CASE WHEN s.normalized = nd.n THEN 1.0 ELSE 0 END)::real AS score
        FROM public.card_search_names s
        JOIN public.cards c ON c.oracle_id = s.oracle_id AND c.game = %(jeu)s
        WHERE s.normalized %% nd.n OR s.normalized LIKE nd.n || '%%'
        ORDER BY score DESC, length(c.name), c.name
        LIMIT 1
    ) b
    {jointure}
"""

VARIANTES: dict[str, dict[str, str]] = {
    "vue": {
        "prix": "p.price_eur",
        "jointure": (
            "LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id"
        ),
    },
    "latérale": {
        "prix": "p.price_eur",
        "jointure": (
            "LEFT JOIN LATERAL (SELECT min(pr.price_eur) AS price_eur "
            "FROM public.card_prints pr WHERE pr.oracle_id = b.oracle_id) p ON true"
        ),
    },
}

ECHANTILLON = """
    SELECT s.name
    FROM public.card_search_names s
    JOIN public.cards c ON c.oracle_id = s.oracle_id AND c.game = 'magic'
    WHERE s.lang = 'fr' AND length(s.name) BETWEEN 8 AND 40
    ORDER BY random()
    LIMIT %(combien)s
"""


def blocs_et_temps(cur, requete: str, noms: list[str]) -> tuple[int, int, float]:
    """Blocs déjà en cache, blocs lus au disque, millisecondes."""
    cur.execute(
        "EXPLAIN (ANALYZE, BUFFERS) " + requete, {"noms": noms, "jeu": "magic"}
    )
    plan = "\n".join(r[0] for r in cur.fetchall())
    touches = sum(int(m) for m in re.findall(r"shared hit=(\d+)", plan))
    lus = sum(int(m) for m in re.findall(r"shared [^)\n]*read=(\d+)", plan))
    duree = re.search(r"Execution Time: ([\d.]+)", plan)
    return touches, lus, float(duree.group(1)) if duree else 0.0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--noms",
        type=int,
        nargs="+",
        default=[10, 50, 150],
        help="tailles de lot à mesurer (l'application découpe à 50)",
    )
    parser.add_argument("--essais", type=int, default=5)
    parser.add_argument(
        "--cartes",
        type=int,
        nargs="*",
        default=[],
        help="scans à simuler, en nombre de cartes sur la photo (ex. 1 8 16 24)",
    )
    args = parser.parse_args()

    config = SupabaseConfig.load()
    with psycopg.connect(config.db_url) as conn, conn.cursor() as cur:
        cur.execute(ECHANTILLON, {"combien": max(args.noms)})
        tous = [r[0] for r in cur.fetchall()]

        for combien in args.noms:
            noms = tous[:combien]
            print(f"\n=== {combien} noms ===")
            for nom, parts in VARIANTES.items():
                requete = CORPS.format(**parts)
                mesures = []
                for _ in range(args.essais):
                    debut = time.perf_counter()
                    cur.execute(requete, {"noms": noms, "jeu": "magic"})
                    cur.fetchall()
                    mesures.append(time.perf_counter() - debut)

                touches, lus, ms = blocs_et_temps(cur, requete, noms)
                mediane = statistics.median(mesures)
                print(
                    f"  {nom:<10} médiane {mediane:6.3f}s   pire {max(mesures):6.3f}s"
                    f"   × {max(mesures) / mediane:.1f}"
                    f"   blocs {touches:>9,} ({touches * 8 / 1024:>6.0f} Mio)"
                    .replace(",", " ")
                )

    justesse(config)
    if args.cartes:
        photo(config, args.cartes)

    print(
        "\nLa colonne « × » est le rapport du pire au médian : c'est elle qui\n"
        "annonce un timeout, une bascule de plan ne se voyant pas dans la moyenne."
    )


# Lignes candidates par carte sur une photo d'étalement : dix-sept cartes en
# ont produit cent douze, mesuré sur une photo réelle.
LIGNES_PAR_CARTE = 112 / 17

# Ce que `card_repository.dart` envoie par appel.
LOT = 50


def photo(config: SupabaseConfig, nombres: list[int]) -> None:
    """Ce que coûte le scan d'une photo de N cartes, sous le rôle réel.

    **La question que pose l'utilisateur : photographier seize cartes d'un coup
    augmente-t-il le risque de timeout ?** Elle ne se répond pas au raisonnement,
    parce que deux effets s'opposent. Plus de cartes font plus de lignes lues,
    donc plus de noms — mais l'application découpe à cinquante, et le délai de
    huit secondes s'applique **par instruction**, pas au total. Ce qui grandit
    n'est donc pas le coût d'un appel, c'est leur nombre.

    Le banc mesure ce qui compte : le pire lot, celui qui décidera du timeout.
    """
    values = load_env_file("supabase.env")
    with psycopg.connect(config.db_url) as conn, conn.cursor() as cur:
        cur.execute(ECHANTILLON, {"combien": 200})
        vivier = [r[0] for r in cur.fetchall()]

    with httpx.Client(base_url=config.url, timeout=120) as client:
        ouverture = client.post(
            "/auth/v1/token",
            params={"grant_type": "password"},
            headers={"apikey": config.anon_key},
            json={
                "email": values.get("DECKHAND_TEST_EMAIL", ""),
                "password": values.get("DECKHAND_TEST_PASSWORD", ""),
            },
        )
        if ouverture.status_code != 200:
            print("\nphoto : session refusée, mesure sautée")
            return
        entetes = {
            "apikey": config.anon_key,
            "Authorization": f"Bearer {ouverture.json()['access_token']}",
        }

        print(f"\n{'cartes':>7}{'noms':>6}{'lots':>6}{'total':>9}{'pire lot':>10}")
        for cartes in nombres:
            combien = round(cartes * LIGNES_PAR_CARTE)
            noms = [vivier[i % len(vivier)] for i in range(combien)]
            lots = [noms[d : d + LOT] for d in range(0, len(noms), LOT)]

            durees = []
            for lot in lots:
                debut = time.perf_counter()
                client.post(
                    "/rest/v1/rpc/search_cards_bulk",
                    headers=entetes,
                    json={"p_names": lot, "p_game": "magic"},
                )
                durees.append(time.perf_counter() - debut)

            print(
                f"{cartes:>7}{combien:>6}{len(lots):>6}"
                f"{sum(durees):>8.2f}s{max(durees):>9.2f}s"
            )
        print(
            "  Le délai de huit secondes est par instruction : c'est la colonne\n"
            "  « pire lot » qu'il faut lire, jamais le total."
        )


def justesse(config: SupabaseConfig) -> None:
    """Les deux façons de joindre rendent-elles le même prix ?

    **Le contrôle qui compte le plus, et le seul qui ne soit pas une mesure de
    temps.** Une requête plus rapide qui rendrait un autre prix serait pire que
    le timeout qu'elle corrige : une collection mal valorisée ne se voit pas,
    là où une erreur se lit à l'écran. Comparé sur le catalogue entier, pas sur
    un échantillon — c'est une jointure, elle coûte une seconde.
    """
    with psycopg.connect(config.db_url) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*)
            FROM public.cards c
            LEFT JOIN public.card_cheapest_price v ON v.oracle_id = c.oracle_id
            LEFT JOIN LATERAL (
                SELECT min(pr.price_eur) AS price_eur
                FROM public.card_prints pr
                WHERE pr.oracle_id = c.oracle_id
            ) l ON true
            WHERE v.price_eur IS DISTINCT FROM l.price_eur
            """
        )
        ecarts = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM public.cards")
        total = cur.fetchone()[0]

    verdict = "OK" if ecarts == 0 else f"ÉCHEC — {ecarts} écarts"
    print(f"\njustesse : {total} cartes, vue et latérale d'accord — {verdict}")


if __name__ == "__main__":
    main()
