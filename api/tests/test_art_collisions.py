"""Tests du banc qui mesure ce que l'index annonce à tort.

**Un banc faux est pire qu'un banc absent** : il produit des chiffres, on les
écrit dans la doc, et on décide sur eux. Ceux-ci vérifient la mécanique sur des
cas dont la réponse est connue d'avance, sans base ni réseau.

Le banc lui-même s'est validé par recoupement : interrogé avec les empreintes
Riftbound contre l'index Magic, il rend **379** entrées sous le seuil — le chiffre
relevé indépendamment lors du cloisonnement de l'index par jeu, et écrit dans
`art_index_repository.dart`.
"""

from __future__ import annotations

import numpy as np

from app.measure.art_collisions import (
    MAX_TRUSTED_DISTANCE,
    MIN_CONFIDENCE_MARGIN,
    Catalogue,
    distances,
    measure_internal,
    measure_intrusion,
)


def catalogue(
    hashes: list[int], cards: list[int], names: list[int] | None = None
) -> Catalogue:
    """Un catalogue d'essai.

    `names` vaut `cards` par défaut : c'est le cas des jeux dont l'identité
    réunit déjà les éditions, où les deux axes coïncident. Le passer
    explicitement sert à reproduire le cas Pokémon, où une même carte rééditée
    porte deux identités et un seul nom.
    """
    return Catalogue(
        game="essai",
        hashes=np.array(hashes, dtype=np.uint64),
        cards=np.array(cards, dtype=np.int32),
        names=np.array(names if names is not None else cards, dtype=np.int32),
    )


def test_la_distance_est_bien_celle_de_hamming():
    a = np.array([0b1011, 0b0000], dtype=np.uint64)
    b = np.array([0b1111, 0b1111], dtype=np.uint64)
    assert list(distances(a, b).diagonal()) == [1, 4]


def test_le_bit_de_poids_fort_ne_devient_pas_negatif():
    """`dhash` est un bigint signé côté Postgres ; mal converti, une empreinte
    de poids fort passerait en négatif et le XOR perdrait son sens."""
    a = np.array([1 << 63], dtype=np.uint64)
    b = np.array([0], dtype=np.uint64)
    assert int(distances(a, b)[0][0]) == 1


def test_deux_cartes_a_empreinte_identique_sont_annoncees_a_tort():
    """Le cas Riftbound : rien ne distingue deux cartes que le catalogue a
    dédoublées, et le second candidat est assez loin pour donner la marge — donc
    l'application affirme, au lieu d'hésiter."""
    cat = catalogue([7, 7, 1 << 40], [0, 1, 2])
    r = measure_internal(cat)
    assert r["closest_pair"] == 0
    assert r["confident_wrong"] == 2


def test_deux_cartes_eloignees_ne_sont_pas_confondues():
    cat = catalogue([0, 0xFFFFFFFFFFFFFFFF], [0, 1])
    r = measure_internal(cat)
    assert r["confusable"] == 0
    assert r["confident_wrong"] == 0
    assert r["closest_pair"] == 64


def test_deux_illustrations_d_une_meme_carte_ne_comptent_pas_comme_confusion():
    """Se tromper d'illustration sur la bonne carte n'est pas une erreur : c'est
    la même carte, et c'est elle que l'utilisateur possède."""
    cat = catalogue([7, 7], [0, 0])
    r = measure_internal(cat)
    assert r["confusable"] == 0
    assert r["confident_wrong"] == 0


def test_une_carte_se_fait_rejeter_par_ses_propres_jumelles():
    """`margin` compare deux *entrées*, pas deux cartes. Une carte à plusieurs
    illustrations proches se vole donc sa propre marge et fait rejeter une
    reconnaissance juste — un refus, non une erreur, mais il se corrige au même
    endroit.

    **Il en faut trois**, et c'est la mesure qui l'a appris : avec deux entrées
    seulement, la requête en est une, sa jumelle est le meilleur candidat, et le
    second est forcément une autre carte — donc loin, donc la marge est large et
    la reconnaissance passe. Il faut une troisième illustration pour que les deux
    meilleurs candidats appartiennent tous deux à la carte cherchée. Mesuré, le
    cas n'existe que chez Magic (129 entrées) et jamais dans les deux autres
    catalogues.
    """
    cat = catalogue([7, 7, 7, 0xFFFFFFFFFFFFFFFF], [0, 0, 0, 1])
    r = measure_internal(cat)
    assert r["self_starved"] == 3
    assert r["confident_wrong"] == 0
    assert r["confusable"] == 0


def test_l_intrusion_compte_ce_qui_franchit_les_deux_garde_fous():
    """Une carte absente de l'index : toute réponse est fausse. Seules comptent
    celles que l'application affirmerait — sous le seuil *et* avec la marge."""
    index = catalogue([0, 0xFFFF], [0, 1])
    intrus = catalogue([1], [0])  # à 1 bit du premier, à 15 du second
    r = measure_intrusion(intrus, index, sample=1)
    assert r["closest"] == 1
    assert r["under_threshold"] == 1
    assert r["confident"] == 1


def test_une_intrusion_ambigue_n_est_pas_annoncee():
    """Deux candidats aussi proches l'un que l'autre : la marge manque, et le
    banc doit compter l'entrée comme rejetée plutôt que comme affirmée."""
    index = catalogue([0b000, 0b011], [0, 1])
    intrus = catalogue([0b001], [0])  # à 1 bit de chacun
    r = measure_intrusion(intrus, index, sample=1)
    assert r["under_threshold"] == 1
    assert r["confident"] == 0


def test_les_seuils_mesures_sont_ceux_de_l_application():
    """Recopiés de `art_hash_index.dart`. S'ils divergent, le banc mesure un
    autre système que celui qui tourne."""
    assert MAX_TRUSTED_DISTANCE == 12
    assert MIN_CONFIDENCE_MARGIN == 4


# --- les deux axes d'identité ----------------------------------------------


def test_deux_reeditions_dune_meme_carte_ne_sont_pas_une_fausse_carte():
    """**Le piège qui a fait lire 7,36 % là où il y avait 1,49 %.** Chez Pokémon
    l'identité publiée est l'impression : une carte rééditée avec la même
    illustration porte deux identités et un seul nom. Compter leur ressemblance
    comme une fausse carte revient à reprocher au scan de bien reconnaître
    l'image qu'il a sous les yeux."""
    # Deux entrées identiques, deux cartes distinctes, un seul nom.
    cat = catalogue([0b1111, 0b1111], cards=[0, 1], names=[7, 7])
    r = measure_internal(cat)

    # Sur l'axe « carte », elles se confondent — c'est vrai et sans intérêt.
    assert r["confusable"] == 2
    # Sur l'axe « nom », il n'y a aucune confusion : c'est la même carte.
    assert r["confusable_name"] == 0
    assert r["confident_wrong_name"] == 0


def test_deux_cartes_de_noms_differents_restent_comptees():
    """L'axe du nom ne doit rien excuser : deux cartes réellement différentes
    qui se ressemblent sont une fausse carte sur les deux axes."""
    # Deux empreintes proches (2 bits), deux cartes, deux noms, et une
    # troisième **hors du seuil** — 32 bits, non 8 : à 8 elle tombait elle aussi
    # sous les 12 bits et se comptait comme confondable, ce qui faisait échouer
    # ce test sur un chiffre juste.
    cat = catalogue(
        [0b0000, 0b0011, 0xFFFFFFFF],
        cards=[0, 1, 2],
        names=[0, 1, 2],
    )
    r = measure_internal(cat)

    assert r["confusable_name"] == 2
    assert r["confident_wrong_name"] == 2


def test_lapostrophe_typographique_ne_fait_pas_deux_noms():
    """La source publie « Professor Elm's » et « Professor Elm’s » — deux
    graphies de la même carte, et les deux seuls cas où les noms semblaient
    différer sur 247 groupes d'empreintes identiques."""
    from app.measure.art_collisions import _name_key

    assert _name_key("Professor Elm's Training Method") == _name_key(
        "Professor Elm\u2019s Training Method"
    )
    # Deux cartes réellement différentes gardent des clés différentes.
    assert _name_key("Pikachu") != _name_key("Raichu")
