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

#: Cartes Riftbound horizontales : les 71 champs de bataille. Leur nom est
#: incrusté dans l'illustration et est haché avec elle — sans conséquence,
#: puisqu'il est constant pour une carte donnée.
RIFTBOUND_LANDSCAPE = ArtBox(0.041, 0.199, 0.962, 0.777)


def box_for(game: str, layout: str | None) -> ArtBox | None:
    """Gabarit à appliquer, ou `None` si l'image est déjà découpée.

    Magic renvoie `None` : ses illustrations arrivent déjà recadrées de
    Scryfall, et les redécouper les amputerait.
    """
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
