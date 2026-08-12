"""Proportions physiques d'une carte, par jeu.

**Ce module doit rester le jumeau de
`app/lib/src/features/scan/domain/card_geometry.dart`**, et c'est le Dart qui
fait foi : c'est lui qui tourne sur l'appareil. Une divergence ne se voit pas —
elle produit des coins différents, donc une empreinte différente, et le scan
échoue en silence.

**Ce rapport n'est pas une constante du produit.** Il l'a été tant que les deux
premiers jeux couverts partageaient le même carton — Magic et Riftbound
impriment tous deux en 63 × 88 mm —, et il était écrit en dur à huit endroits du
dépôt sans que rien ne le signale. Le jeu suivant le fera tomber : Yu-Gi-Oh
imprime plus petit.

**Ce que ce rapport décide.** Deux choses, et la seconde est celle qui coûte :

- il dit si un quadrilatère détecté est une carte ou un rectangle suspect
  (`find_card`) — là, la tolérance de 0,30 est si large que 4 % d'écart
  passeraient inaperçus ;
- il dit **ce qu'on découpe quand la détection renonce**. C'est le repli, et il
  n'a pas de tolérance : un découpage au mauvais rapport, suivi du bon gabarit
  d'illustration, rend une empreinte plausible et donc une mauvaise carte.
"""

from __future__ import annotations

#: Rapport largeur sur hauteur d'une carte debout, par jeu.
#:
#: **Mesuré, pas déduit d'un catalogue d'images.** Un rendu peut porter des
#: marges ou un rognage qui ne sont pas ceux du carton, alors que c'est bien le
#: carton que la photo montre. Pour les deux jeux couverts, les deux
#: coïncident : le carton fait 63 × 88 mm (0,7159) et le rendu Riftbound
#: 744 × 1039 (0,7160), à un millième près.
#:
#: Ajouter un jeu ici est **obligatoire** : sans entrée, il retombe sur
#: `DEFAULT_CARD_ASPECT` en silence. Jumeau de `cardAspects`.
CARD_ASPECTS: dict[str, float] = {
    # Magic : 63 × 88 mm. Le rendu Scryfall fait 745 × 1040, soit 0,7163.
    "magic": 63 / 88,
    # Riftbound : même carton que Magic. Mesuré sur le catalogue, une carte
    # debout fait 744 × 1039 et une couchée 1039 × 744 — ce n'est pas un autre
    # format, c'est la même carte tournée d'un quart de tour.
    "riftbound": 63 / 88,
    # Yu-Gi-Oh : 59 × 86 mm, le premier jeu couvert qui n'imprime pas au format
    # des deux autres. **Le rendu de la source s'aligne sur le carton**, ce que
    # rien ne garantissait : mesuré sur 20 cartes de dix cadres différents,
    # 813 × 1185 soit 0,6861, contre 0,68605 pour 59 × 86.
    "yugioh": 59 / 86,
}

#: Ce sur quoi retombe un jeu absent de `CARD_ASPECTS`.
#:
#: **Un repli, pas une valeur par défaut légitime.** Il existe pour que la
#: reconnaissance continue de fonctionner plutôt que de lever sur un jeu
#: inconnu — refuser de scanner serait pire que scanner de travers. Mais s'y
#: retrouver signifie qu'un jeu a été ajouté sans ses proportions.
DEFAULT_CARD_ASPECT = 63 / 88


def card_aspect_for(game: str) -> float:
    """Proportions d'une carte de `game`. Jumeau de `cardAspectFor`."""
    return CARD_ASPECTS.get(game, DEFAULT_CARD_ASPECT)
