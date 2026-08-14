"""Banc : ce que l'index d'empreintes peut annoncer à tort, et avec assurance.

**La question n'est pas « trouve-t-il la bonne carte ? » mais « que dit-il quand
il ne devrait rien dire ? »** Une carte absente de l'index — un jeton, une carte
abîmée, une carte du bon jeu mais hors catalogue, ou simplement une carte de
Magic photographiée alors que Riftbound est sélectionné — aura toujours un plus
proche voisin. Le proposer serait un faux positif, et l'utilisateur enregistrerait
une carte qu'il ne possède pas. `art_hash_index.dart` s'en défend par deux
garde-fous, et ce banc mesure ce qu'ils laissent passer :

- `maxTrustedDistance = 12` — au-delà, la correspondance n'est plus crédible ;
- `minConfidenceMargin = 4` — écart minimal avec le second candidat pour trancher.

Ces deux valeurs ont été calibrées quand l'index était petit. Il porte
aujourd'hui 64 126 empreintes pour trois jeux, et la densité change tout : plus
un index est peuplé, plus le plus proche voisin d'une empreinte quelconque est
proche, donc plus un intrus a de chances de se glisser sous le seuil. Rien ne le
signalerait — c'est précisément le genre de défaut qui n'a pas de symptôme.

Trois mesures, dans l'ordre de ce qu'elles coûteraient à l'utilisateur :

1. **Confusions entre deux cartes d'un même jeu.** Deux illustrations distinctes
   assez proches pour passer le seuil : la reconnaissance annoncerait l'une pour
   l'autre, sans hésiter. C'est le pire cas — une carte trouvée, plausible, et
   fausse.
2. **Intrusions.** Une empreinte d'un jeu interrogée contre l'index d'un autre.
   Le cloisonnement par jeu empêche les index de se mélanger, mais **pas
   l'utilisateur de se tromper de jeu** : c'est lui qui le choisit à la main.
3. **Auto-concurrence.** Une carte à plusieurs illustrations occupe plusieurs
   entrées de l'index. `margin` compare deux *entrées*, pas deux cartes : les
   illustrations d'une même carte peuvent donc se voler la marge et faire
   rejeter une reconnaissance pourtant juste. Ce défaut-là coûte des refus, pas
   des erreurs — mais il se corrige au même endroit. **Il en faut trois** pour
   qu'il se produise : avec deux, la requête en est une, sa jumelle est le
   meilleur candidat, et le second est forcément une autre carte, donc loin.

Usage :
    cd api && .venv/Scripts/python -m app.measure.art_collisions
    #   --game <jeu>   ne mesure qu'un jeu
    #   --sample N     borne l'échantillon d'intrusions (défaut 2 000)
"""

from __future__ import annotations

import sys
import unicodedata
from dataclasses import dataclass

import numpy as np
import psycopg

from app.config import SupabaseConfig

#: Les deux garde-fous, recopiés de `art_hash_index.dart`. Les tenir ici en dur
#: est délibéré : si l'un change là-bas sans changer ici, le banc mesurera
#: l'ancien seuil et le dira — mieux vaut un écart visible qu'une valeur lue
#: d'un fichier Dart par une expression régulière fragile.
MAX_TRUSTED_DISTANCE = 12
MIN_CONFIDENCE_MARGIN = 4

#: Taille des blocs de lignes comparés d'un coup. 512 × 33 000 octets tient
#: largement en mémoire, et la boucle Python devient négligeable.
BLOCK = 512


@dataclass(frozen=True)
class Catalogue:
    """Les empreintes d'un jeu, telles que l'application les embarque."""

    game: str
    hashes: np.ndarray  # uint64, une par illustration
    cards: np.ndarray  # int32, code de la carte porteuse
    #: Code du **nom** de la carte, normalisé. Second axe d'identité, et il est
    #: indispensable pour comparer deux jeux entre eux — voir `measure_internal`.
    names: np.ndarray  # int32

    @property
    def size(self) -> int:
        return int(self.hashes.size)

    @property
    def distinct_cards(self) -> int:
        return int(np.unique(self.cards).size)


def load(conn: psycopg.Connection) -> dict[str, Catalogue]:
    """Charge un catalogue d'empreintes par jeu.

    L'index embarqué porte **une entrée par illustration**, pas par carte : une
    carte à deux illustrations y occupe deux places, et c'est voulu — on cherche
    l'image qu'on a sous les yeux. La carte porteuse est retenue à côté, car
    c'est elle qui décide si une confusion est réelle : deux entrées d'une même
    carte qui se ressemblent ne trompent personne.
    """
    with conn.cursor() as cur:
        rows = cur.execute(
            """
            SELECT c.game, a.dhash, a.oracle_id::text, c.name
            FROM public.art_hashes a
            JOIN public.cards c ON c.oracle_id = a.oracle_id
            ORDER BY c.game
            """
        ).fetchall()

    by_game: dict[str, list[tuple[int, str, str]]] = {}
    for game, dhash, oracle_id, name in rows:
        by_game.setdefault(game, []).append((dhash, oracle_id, name))

    catalogues: dict[str, Catalogue] = {}
    for game, entries in by_game.items():
        # `dhash` est un bigint signé côté Postgres ; le masque le ramène aux
        # 64 bits qu'il représente, sans quoi les empreintes de poids fort
        # deviendraient négatives et le XOR perdrait son sens.
        hashes = np.array(
            [h & 0xFFFFFFFFFFFFFFFF for h, _, _ in entries], dtype=np.uint64
        )
        seen: dict[str, int] = {}
        seen_names: dict[str, int] = {}
        codes = np.empty(len(entries), dtype=np.int32)
        name_codes = np.empty(len(entries), dtype=np.int32)
        for i, (_, oracle_id, name) in enumerate(entries):
            codes[i] = seen.setdefault(oracle_id, len(seen))
            name_codes[i] = seen_names.setdefault(_name_key(name), len(seen_names))
        catalogues[game] = Catalogue(
            game=game, hashes=hashes, cards=codes, names=name_codes
        )
    return catalogues


def _name_key(name: str) -> str:
    """Nom réduit à ce qui le distingue vraiment.

    L'apostrophe est le piège : la source publie « Professor Elm's Training
    Method » **et** « Professor Elm’s Training Method », deux graphies de la même
    carte. Sans cette normalisation, elles comptaient pour deux noms différents
    et donc pour une fausse carte — les deux seuls cas, sur 247 groupes
    d'empreintes identiques, où les noms semblaient différer.
    """
    lowered = unicodedata.normalize("NFKD", name).replace("’", "'").lower()
    return "".join(c for c in lowered if c.isalnum() or c == "'")


def distances(queries: np.ndarray, index: np.ndarray) -> np.ndarray:
    """Distances de Hamming entre chaque requête et tout l'index."""
    return np.bitwise_count(queries[:, None] ^ index[None, :]).astype(np.int16)


def measure_internal(cat: Catalogue) -> dict[str, int]:
    """Deux cartes d'un même jeu peuvent-elles être confondues ?

    Pour chaque entrée, on cherche la plus proche qui appartient à une **autre**
    carte, puis on reconstitue la décision de l'application : distance sous le
    seuil, et marge suffisante avec le candidat suivant. Une confusion qui
    franchit les deux est une carte annoncée avec assurance et fausse.

    **Deux axes d'identité, et confondre les deux fait lire le résultat de
    travers.** « Une autre carte » ne veut pas dire la même chose d'un jeu à
    l'autre : chez Magic, `cards` porte l'`oracle_id`, qui **réunit toutes les
    éditions** d'une carte, si bien que deux éditions qui se ressemblent ne
    comptent pas. Chez Pokémon, l'identité de la source est l'impression : chaque
    réédition est une carte distincte, et une confusion entre deux tirages de la
    *même* illustration y était comptée comme une fausse carte.

    Mesuré sur les 19 326 empreintes Pokémon : **7,36 %** par carte, mais
    **1,49 %** par nom — et 99,2 % des 247 groupes d'empreintes identiques
    portent le même nom, ce sont des rééditions. Le second chiffre est le seul
    comparable d'un jeu à l'autre, et le seul qui décrive le risque réel : se
    tromper d'édition n'est pas annoncer une autre carte, et le §IV.8 le prévoit
    déjà — l'édition se déduit, la carte se confirme.
    """
    n = cat.size
    confusable = 0
    confident_wrong = 0
    confusable_name = 0
    confident_wrong_name = 0
    self_starved = 0
    worst = (64, -1, -1)

    for start in range(0, n, BLOCK):
        stop = min(start + BLOCK, n)
        block = distances(cat.hashes[start:stop], cat.hashes)
        rows = np.arange(start, stop)
        # Une entrée est toujours à zéro d'elle-même : on l'écarte.
        block[np.arange(stop - start), rows] = 127

        same_card = cat.cards[rows][:, None] == cat.cards[None, :]
        same_name = cat.names[rows][:, None] == cat.names[None, :]

        # Le plus proche d'une autre carte : c'est lui qui trompe.
        other = np.where(same_card, np.int16(127), block)
        nearest_other = other.min(axis=1)

        # Le plus proche d'un autre **nom** : celui-là trompe vraiment.
        other_name = np.where(same_name, np.int16(127), block)
        nearest_name = other_name.min(axis=1)
        two_name = np.partition(other_name, 1, axis=1)[:, :2]
        margin_name = two_name[:, 1] - two_name[:, 0]

        # Les deux plus proches toutes entrées confondues : c'est ce que
        # l'application voit, et donc la marge dont elle dispose.
        two = np.partition(block, 1, axis=1)[:, :2]
        best, second = two[:, 0], two[:, 1]
        margin = second - best

        for k in range(stop - start):
            if nearest_other[k] <= MAX_TRUSTED_DISTANCE:
                confusable += 1
                # Le candidat le plus proche est-il déjà la mauvaise carte, et
                # l'application le croit-elle sans réserve ?
                if best[k] == nearest_other[k] and margin[k] >= MIN_CONFIDENCE_MARGIN:
                    confident_wrong += 1
                if nearest_other[k] < worst[0]:
                    worst = (int(nearest_other[k]), int(rows[k]), 0)
            if nearest_name[k] <= MAX_TRUSTED_DISTANCE:
                confusable_name += 1
                if margin_name[k] >= MIN_CONFIDENCE_MARGIN:
                    confident_wrong_name += 1
            # Deux illustrations d'une même carte se volent-elles la marge ?
            if (
                best[k] <= MAX_TRUSTED_DISTANCE
                and margin[k] < MIN_CONFIDENCE_MARGIN
                and nearest_other[k] > MAX_TRUSTED_DISTANCE
            ):
                self_starved += 1

    return {
        "entries": n,
        "cards": cat.distinct_cards,
        "confusable": confusable,
        "confident_wrong": confident_wrong,
        "confusable_name": confusable_name,
        "confident_wrong_name": confident_wrong_name,
        "self_starved": self_starved,
        "closest_pair": worst[0],
    }


def measure_intrusion(
    intruder: Catalogue, target: Catalogue, sample: int
) -> dict[str, int]:
    """Que répond l'index d'un jeu à une carte qui n'en fait pas partie ?

    Le cas n'est pas théorique : le jeu est choisi à la main dans l'application,
    et rien n'empêche de photographier une carte de Magic alors que Riftbound
    est sélectionné. Toute réponse est alors fausse par construction — la seule
    bonne conduite est le silence.
    """
    rng = np.random.default_rng(20260812)
    take = min(sample, intruder.size)
    picked = rng.choice(intruder.size, size=take, replace=False)
    queries = intruder.hashes[picked]

    accepted = 0
    confident = 0
    best_seen = 64

    for start in range(0, take, BLOCK):
        block = distances(queries[start : start + BLOCK], target.hashes)
        two = np.partition(block, 1, axis=1)[:, :2]
        best, second = two[:, 0], two[:, 1]
        margin = second - best
        under = best <= MAX_TRUSTED_DISTANCE
        accepted += int(under.sum())
        confident += int((under & (margin >= MIN_CONFIDENCE_MARGIN)).sum())
        best_seen = min(best_seen, int(best.min()))

    return {
        "sampled": take,
        "under_threshold": accepted,
        "confident": confident,
        "closest": best_seen,
    }


def run(only: str | None = None, sample: int = 2000) -> None:
    supabase = SupabaseConfig.load()
    with psycopg.connect(supabase.db_url, connect_timeout=60) as conn:
        catalogues = load(conn)

    games = [g for g in sorted(catalogues) if only in (None, g)]
    if not games:
        sys.exit(f"jeu inconnu : {only}")

    print(f"seuils mesurés : distance <= {MAX_TRUSTED_DISTANCE}, "
          f"marge >= {MIN_CONFIDENCE_MARGIN}\n")

    print("=== 1. confusions entre deux cartes d'un même jeu ===")
    for game in games:
        cat = catalogues[game]
        r = measure_internal(cat)
        print(
            f"  {game:<10} {r['entries']:>6} empreintes / {r['cards']:>6} cartes"
        )
        print(
            f"             confondables (une autre carte sous le seuil) : "
            f"{r['confusable']:>5}"
            f"  ({100 * r['confusable'] / r['entries']:.2f} %)"
        )
        print(
            f"             annoncées à tort avec assurance             : "
            f"{r['confident_wrong']:>5}"
            f"  ({100 * r['confident_wrong'] / r['entries']:.2f} %)"
        )
        print(
            f"             — dont sous un AUTRE nom (comparable)       : "
            f"{r['confident_wrong_name']:>5}"
            f"  ({100 * r['confident_wrong_name'] / r['entries']:.2f} %)"
            f"   [confondables : {r['confusable_name']}]"
        )
        print(
            f"             rejetées par leur propre jumelle            : "
            f"{r['self_starved']:>5}"
            f"  ({100 * r['self_starved'] / r['entries']:.2f} %)"
        )
        print(f"             paire la plus serrée : {r['closest_pair']} bits")

    print("\n=== 2. intrusions : une carte étrangère à l'index interrogé ===")
    for target in games:
        for intruder in sorted(catalogues):
            if intruder == target:
                continue
            r = measure_intrusion(catalogues[intruder], catalogues[target], sample)
            print(
                f"  {intruder:<10} vu par l'index {target:<10} "
                f"sur {r['sampled']:>5} : "
                f"{r['under_threshold']:>4} sous le seuil, "
                f"{r['confident']:>4} annoncées avec assurance "
                f"({100 * r['confident'] / r['sampled']:.2f} %), "
                f"plus proche à {r['closest']} bits"
            )


if __name__ == "__main__":
    game = None
    sample = 2000
    if "--game" in sys.argv:
        game = sys.argv[sys.argv.index("--game") + 1]
    if "--sample" in sys.argv:
        sample = int(sys.argv[sys.argv.index("--sample") + 1])
    try:
        run(game, sample)
    except KeyboardInterrupt:
        sys.exit("interrompu")
