"""Zone d'illustration sur une carte, en proportions.

**Ce module doit rester le jumeau de `app/lib/src/features/scan/domain/art_box.dart`.**
L'index est calculé ici, la reconnaissance s'exécute là-bas : deux gabarits qui
divergeraient produiraient des empreintes incomparables, et le scan échouerait
**en silence** — le pire mode de défaillance, puisqu'il fait accuser
l'algorithme. `test_art_box.py` verrouille cette parité en relisant les valeurs
du fichier Dart.

**Pourquoi Magic n'a pas besoin de découpage ici.** Scryfall publie déjà la
seule zone illustrée (`art_crop`) : l'index Magic hache l'image telle qu'elle
arrive. Riftcodex, lui, ne sert que la carte entière — le découpage devient donc
l'affaire de ce module, et il doit reproduire exactement ce que l'application
fera sur la photo.
"""

from __future__ import annotations

from typing import NamedTuple


class ArtBox(NamedTuple):
    """Bornes en fractions de la carte."""

    left: float
    top: float
    right: float
    bottom: float


#: Cartes Riftbound verticales — l'immense majorité.
#:
#: La borne basse exclut la ligne de type : bande pleine largeur, elle gèlerait
#: sinon une ligne entière de la grille d'empreinte.
RIFTBOUND_PORTRAIT = ArtBox(0.065, 0.047, 0.934, 0.517)

#: Cartes Riftbound couchées : les 64 champs de bataille. Leur nom est
#: incrusté dans l'illustration et est haché avec elle — sans conséquence,
#: puisqu'il est constant pour une carte donnée.
#:
#: Mesuré sur le catalogue, une carte couchée fait 1039 × 744, soit un rapport
#: de 1,397 — exactement l'inverse de 0,716. Ce n'est pas un autre format, c'est
#: la même carte tournée d'un quart de tour.
RIFTBOUND_LANDSCAPE = ArtBox(0.041, 0.199, 0.962, 0.777)

#: Jeux dont certaines cartes se posent en travers.
#:
#: **C'est la détection qui en a besoin, pas le découpage.** `find_card` rejette
#: tout quadrilatère dont le rapport s'écarte de celui d'une carte debout ; une
#: carte couchée s'en écarte de 0,68 pour une tolérance de 0,30, et était donc
#: introuvable. Ouvrir l'orientation couchée à tous les jeux reviendrait à
#: accepter n'importe quel rectangle en Magic, où toutes les cartes sont debout.
#: Jumeau de `CardFrame.landscape`.
GAMES_WITH_LANDSCAPE = frozenset({"riftbound"})

#: Yu-Gi-Oh, cadre ordinaire — 14 101 cartes sur 14 491.
#:
#: **Mesuré par recoupement, non par une heuristique.** La source publie la carte
#: entière *et* son illustration détourée : la fenêtre se retrouve en cherchant,
#: dans la première, la région qui reproduit la seconde. Sur 20 cartes tirées
#: dans dix familles de cadre, la même fenêtre à 0,001 près, pour un écart
#: résiduel de 1 niveau de gris sur 255. Jumeau de `CardFrame.yugioh`.
YUGIOH = ArtBox(0.1181, 0.1823, 0.8807, 0.7055)

#: Yu-Gi-Oh, cartes Pendulum — 390 cartes, soit 2,7 %.
#:
#: Leur illustration déborde sous le cadre ordinaire pour laisser place aux deux
#: échelles latérales. Mesurée sur 18 cartes des six sous-familles Pendulum,
#: stable à 0,001 près. Jumeau de `CardFrame.yugiohPendulum`.
YUGIOH_PENDULUM = ArtBox(0.0615, 0.1789, 0.9360, 0.6238)


def box_for(game: str, layout: str | None) -> ArtBox | None:
    """Gabarit à appliquer, ou `None` si l'image est déjà découpée.

    Magic renvoie `None` : ses illustrations arrivent déjà recadrées de
    Scryfall, et les redécouper les amputerait.

    **Yu-Gi-Oh découpe malgré une illustration détourée disponible.** La source
    en publie une, et elle conviendrait pour les cartes ordinaires — mais pour
    une Pendulum elle englobe le pavé de texte en plus de l'illustration. Plutôt
    que deux chemins selon le cadre, l'index part de la carte entière dans les
    deux cas : c'est exactement ce que l'application fera sur une photo, et
    c'est la seule façon d'être sûr que les deux empreintes se rencontrent.

    [layout] porte ici le `frameType` de la source, comme il porte l'orientation
    pour Riftbound : dans les deux cas, c'est la donnée qui dit quel gabarit
    appliquer.
    """
    if game == "yugioh":
        return YUGIOH_PENDULUM if layout and "pendulum" in layout else YUGIOH
    if game != "riftbound":
        return None
    return RIFTBOUND_LANDSCAPE if layout == "landscape" else RIFTBOUND_PORTRAIT


def crop(image, box: ArtBox):
    """Découpe [image] selon [box]. Arrondi identique au côté Dart."""
    width, height = image.size
    return image.crop(
        (
            round(box.left * width),
            round(box.top * height),
            round(box.right * width),
            round(box.bottom * height),
        )
    )
