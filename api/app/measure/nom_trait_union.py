"""Le trait d'union coûte-t-il des recherches ? — compter avant de corriger (#21).

**La question, et pourquoi elle ne se tranche pas à vue.** `!card ka zar` ne
trouve rien quand la carte s'appelle *Ka-Zar*. Deux issues possibles : un repli
côté bot — retenter en échangeant espaces et traits d'union — ou constater que le
cas est rare et ne rien faire. `normalize_card_name` est partagée avec toute
l'application **et son jumeau Dart** ; la modifier pour un cas de chat serait
disproportionné, et la faire diverger casserait la reconnaissance. Le seul
arbitre est donc le nombre.

**Deux mesures, et elles ne disent pas la même chose.**

1. *L'exposition* — combien de noms portent un trait d'union. C'est un plafond :
   le nombre de cartes qu'un spectateur pourrait mal saisir.
2. *Ce qui échoue* — pour chacun, la forme mal saisie retrouve-t-elle la carte ?
   Rien ne permet de le déduire du premier nombre : l'appariement passe par
   `similarity` (pg_trgm) et par le préfixe, et un trait d'union remplacé par une
   espace peut très bien rester au-dessus du seuil.

**Ce que ce banc mesure exactement, et pourquoi pas par le bot.** `binder_locate`
est `SECURITY INVOKER` : sous la clé anonyme, elle ne rend que ce qu'un classeur
**publié** expose. La collection de référence ne l'est pas (`is_public = false`),
et publier est un geste de l'utilisateur, pas du banc. Or ce que le partage
décide, ce sont les **lignes visibles** — jamais l'appariement. Ce banc éprouve
donc le prédicat lui-même, avec la vraie fonction de normalisation, le vrai
opérateur de similarité et le seuil réellement en vigueur, lu dans la base plutôt
qu'écrit ici. Il mesure sur le catalogue entier, ce qu'un classeur de trois cent
quarante-trois cartes n'aurait pas permis.

**Le sens inverse compte autant.** Un spectateur peut aussi taper un trait
d'union là où le nom n'en porte pas. Ne mesurer qu'un sens ferait prendre la
moitié du problème pour le tout.

Usage :
    .venv/Scripts/python -m app.measure.nom_trait_union
    .venv/Scripts/python -m app.measure.nom_trait_union --game lorcana
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass

import psycopg

from app.config import SupabaseConfig

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

#: Combien de noms éprouver dans le sens « espace tapé en trait d'union ».
#:
#: Cette population-là est immense — soixante mille noms rien qu'en Magic — et
#: son verdict ne bouge plus après quelques milliers. L'échantillon est pris
#: dans l'ordre alphabétique, pas au hasard : une mesure qu'on ne peut pas
#: rejouer à l'identique ne se discute pas.
ECHANTILLON_INVERSE = 3000

#: Le prédicat d'appariement de `binder_locate`, recopié tel quel.
#:
#: `similarity(a, b) >= seuil` **est** la définition de l'opérateur `%` — on
#: l'écrit ainsi parce que `%` se confond avec un marqueur de paramètre en
#: psycopg. Le seuil est **lu dans la base** et passé en paramètre : l'inscrire
#: en dur ferait mesurer un seuil qui n'est pas celui en vigueur.
PREDICAT = """
    similarity(t.normalized, cible.q) >= %s
    OR t.normalized LIKE cible.q || '%%'
"""


def seuil_de_similarite(conn: psycopg.Connection) -> float:
    """Le seuil réellement en vigueur, lu dans la base.

    **Le charger avant de le lire.** `pg_trgm.similarity_threshold` n'est
    enregistré qu'une fois la bibliothèque de l'extension chargée dans la
    session — la lire d'entrée échoue en « unrecognized configuration
    parameter », ce qui se lit comme une extension absente plutôt que comme un
    ordre d'appel.
    """
    with conn.cursor() as cur:
        cur.execute("SET search_path TO public, extensions")
        cur.execute("SELECT similarity('a', 'a')")
        cur.execute("SHOW pg_trgm.similarity_threshold")
        return float(cur.fetchone()[0])


@dataclass(frozen=True)
class Exposition:
    """Ce que le catalogue offre comme surface au défaut."""

    game: str
    noms: int
    avec_trait: int

    @property
    def part(self) -> float:
        return self.avec_trait / self.noms if self.noms else 0.0


@dataclass(frozen=True)
class Verdict:
    """Ce que la forme mal saisie retrouve — ou non."""

    eprouves: int
    retrouves: int
    exemples: list[str]

    @property
    def perdus(self) -> int:
        return self.eprouves - self.retrouves

    @property
    def part_perdue(self) -> float:
        return self.perdus / self.eprouves if self.eprouves else 0.0


def imputable(temoin: Verdict, mal_saisi: Verdict) -> int:
    """Combien de cartes le **trait d'union** coûte, et lui seul.

    **La perte du témoin n'est pas la sienne.** Un fragment trop court pour la
    similarité et trop rare pour le préfixe échoue déjà tapé correctement ; la
    compter deux fois gonflerait le défaut de tout ce qui n'a rien à voir avec
    lui. Mesuré sur Lorcana, l'écart est **entier** : trois fragments perdus,
    trois qui échouaient déjà, zéro imputable — alors que ce jeu est le plus
    exposé de tous par le simple compte des traits d'union.
    """
    return max(0, mal_saisi.perdus - temoin.perdus)


def compter(conn: psycopg.Connection) -> list[Exposition]:
    """Combien de noms de recherche portent un trait d'union, par jeu."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT c.game,
                   COUNT(*)                                        AS noms,
                   COUNT(*) FILTER (WHERE s.normalized LIKE '%-%') AS avec_trait
            FROM public.card_search_names s
            JOIN public.cards c ON c.oracle_id = s.oracle_id
            GROUP BY c.game
            ORDER BY c.game
            """
        )
        return [Exposition(*ligne) for ligne in cur.fetchall()]


def eprouver(
    conn: psycopg.Connection,
    game: str,
    vers_espace: bool,
    limite: int | None,
    seuil: float,
) -> Verdict:
    """La forme mal saisie retrouve-t-elle sa carte ?

    **Par carte, pas par nom.** Une carte porte plusieurs noms de recherche —
    l'oracle anglais et ses traductions. Elle est retrouvée dès que **l'un**
    d'eux répond au prédicat ; compter nom par nom déclarerait perdue une carte
    que son autre nom ramène.
    """
    de, vers = ("-", " ") if vers_espace else (" ", "-")
    filtre = "LIKE" if vers_espace else "NOT LIKE"
    borne = "LIMIT %s" if limite else ""

    with conn.cursor() as cur:
        cur.execute(
            f"""
            WITH cible AS (
                SELECT s.oracle_id,
                       s.name,
                       public.normalize_card_name(replace(s.name, %s, %s)) AS q
                FROM public.card_search_names s
                JOIN public.cards c ON c.oracle_id = s.oracle_id
                WHERE c.game = %s
                  AND s.normalized {filtre} '%%-%%'
                  AND s.normalized LIKE '%% %%'
                ORDER BY s.name
                {borne}
            ),
            juge AS (
                SELECT cible.name,
                       EXISTS (
                           SELECT 1
                           FROM public.card_search_names t
                           WHERE t.oracle_id = cible.oracle_id
                             AND ({PREDICAT})
                       ) AS retrouvee
                FROM cible
            )
            SELECT COUNT(*),
                   COUNT(*) FILTER (WHERE retrouvee),
                   (ARRAY_AGG(name) FILTER (WHERE NOT retrouvee))[1:6]
            FROM juge
            """,
            (de, vers, game) + ((limite,) if limite else ()) + (seuil,),
        )
        total, retrouves, exemples = cur.fetchone()
        return Verdict(total, retrouves, list(exemples or []))


def eprouver_fragment(
    conn: psycopg.Connection, game: str, seuil: float, avec_trait: bool
) -> Verdict:
    """Et si le spectateur ne tape que le mot à trait d'union ?

    **C'est le cas de l'issue, et le nom complet ne le contient pas.** `!card ka
    zar` ne cherche pas « Ka-Zar de la Terre sauvage » en entier : il cherche un
    **fragment**. Or les deux branches du prédicat ne se comportent pas pareil
    devant un fragment — la similarité s'effondre quand les longueurs divergent,
    et il ne reste que le préfixe, qui est un `LIKE` littéral où le trait
    d'union compte.

    [avec_trait] donne le témoin : le même fragment **avec** son trait d'union
    doit, lui, retrouver la carte. Sans ce contrôle, un zéro se lirait comme
    « le fragment ne marche jamais » au lieu de « le trait d'union décide ».
    """
    forme = "jeton" if avec_trait else "replace(jeton, '-', ' ')"
    with conn.cursor() as cur:
        cur.execute(
            f"""
            WITH cible AS (
                SELECT s.oracle_id,
                       s.name,
                       -- Au moins un caractère de chaque côté : Lorcana écrit
                       -- « Nom - Version », où le trait est un séparateur
                       -- entouré d'espaces. Le prendre pour un mot rendrait un
                       -- jeton vide et une mesure sans objet.
                       (regexp_match(s.normalized, '([^ ]+-[^ ]+)'))[1] AS jeton
                FROM public.card_search_names s
                JOIN public.cards c ON c.oracle_id = s.oracle_id
                WHERE c.game = %s
                  AND s.normalized LIKE '%%-%%'
                  AND s.normalized LIKE '%% %%'
            ),
            requete AS (
                SELECT oracle_id, name, {forme} AS q FROM cible WHERE jeton <> ''
            ),
            juge AS (
                SELECT cible.name,
                       EXISTS (
                           SELECT 1
                           FROM public.card_search_names t
                           WHERE t.oracle_id = cible.oracle_id
                             AND ({PREDICAT})
                       ) AS retrouvee
                FROM requete AS cible
            )
            SELECT COUNT(*),
                   COUNT(*) FILTER (WHERE retrouvee),
                   (ARRAY_AGG(name) FILTER (WHERE NOT retrouvee))[1:6]
            FROM juge
            """,
            (game, seuil),
        )
        total, retrouves, exemples = cur.fetchone()
        return Verdict(total, retrouves, list(exemples or []))


def main() -> None:
    parseur = argparse.ArgumentParser(description=__doc__)
    parseur.add_argument("--game", default="magic")
    parseur.add_argument("--inverse", type=int, default=ECHANTILLON_INVERSE)
    arguments = parseur.parse_args()

    supabase = SupabaseConfig.load()
    with psycopg.connect(supabase.db_url, connect_timeout=60) as conn:
        seuil = seuil_de_similarite(conn)

        print("EXPOSITION — noms de recherche portant un trait d'union\n")
        print(f"  {'jeu':12s} {'noms':>8s} {'avec trait':>11s} {'part':>8s}")
        for e in compter(conn):
            print(
                f"  {e.game:12s} {e.noms:8d} {e.avec_trait:11d} "
                f"{100 * e.part:7.2f}%"
            )

        print(
            f"\n\nCE QUI ECHOUE — {arguments.game}, predicat reel "
            f"(similarite >= {seuil}, ou prefixe)\n"
        )
        for titre, vers_espace, limite in (
            ("nom AVEC trait d'union, tape avec une espace", True, None),
            (
                f"nom SANS trait d'union, tape avec un trait "
                f"(echantillon de {arguments.inverse})",
                False,
                arguments.inverse,
            ),
        ):
            v = eprouver(conn, arguments.game, vers_espace, limite, seuil)
            if v.eprouves == 0:
                print(f"  {titre}\n     aucun nom concerne\n")
                continue
            print(
                f"  {titre}\n"
                f"     {v.eprouves} nom(s) eprouve(s), {v.retrouves} retrouve(s), "
                f"**{v.perdus} perdu(s)** ({100 * v.part_perdue:.1f} %)"
            )
            for exemple in v.exemples:
                deforme = exemple.replace(*(("-", " ") if vers_espace else (" ", "-")))
                print(f"       perdu : {exemple} → « {deforme} »")
            print()

        # **Le cas de l'issue : un fragment, pas le nom entier.**
        temoin = eprouver_fragment(conn, arguments.game, seuil, avec_trait=True)
        sans = eprouver_fragment(conn, arguments.game, seuil, avec_trait=False)
        impute = imputable(temoin, sans)
        print(
            f"  fragment — le seul mot a trait d'union\n"
            f"     temoin, tape AVEC le trait : {temoin.retrouves}/"
            f"{temoin.eprouves} retrouve(s) — {temoin.perdus} echouent deja\n"
            f"     tape avec une espace       : {sans.retrouves}/"
            f"{sans.eprouves} retrouve(s)\n"
            f"     imputable au trait d'union : **{impute} carte(s)** "
            f"({100 * impute / sans.eprouves if sans.eprouves else 0:.1f} % "
            f"des noms a trait d'union)"
        )
        for exemple in sans.exemples:
            print(f"       perdu : {exemple}")


if __name__ == "__main__":
    main()
