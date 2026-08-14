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

#: Pokémon encadré — 17 365 cartes, et **une seule fenêtre pour vingt ans**.
#:
#: Le cadre a changé cinq fois ; la fenêtre presque pas. Chaque époque a été
#: éprouvée sous la fenêtre des quatre autres : la distance moyenne entre
#: empreintes reste entre 31,1 et 32,3 bits, la paire la plus serrée entre 16 et
#: 21, et le gabarit d'origine n'est jamais meilleur de façon significative — il
#: lui arrive d'être battu par un étranger (`ex` sous la fenêtre de `sv` : 18 bits
#: de marge, contre 16 sous la sienne). **Les gabarits d'époque sont
#: interchangeables**, celui-ci les remplace tous.
#:
#: Il sert aussi deux familles qui n'ont pas le leur :
#:
#: - la **fenêtre haute** (`ex`, `V`, `VMAX`… 1 882 cartes) : la fenêtre standard
#:   tient entièrement dans leur illustration, donc y capte de l'illustration
#:   pure et fait aussi bien que la leur — 32,1 bits de part et d'autre.
#:   L'inverse est faux : la fenêtre large embarque du cadre sur une carte
#:   standard et lui coûte deux bits. **Le plus étroit gagne.**
#: - l'**énergie spéciale** (196 cartes) : mesuré sur la série `sv`, 30,4 bits de
#:   moyenne et 14 sur la paire la plus serrée sous cette fenêtre, contre 30,4 et
#:   16 sous la sienne — deux bits, là où lui donner sa propre fenêtre en
#:   coûterait quatre aux Pokémon standard. Ses fenêtres d'époque ne sont de
#:   toute façon pas stables (arête gauche de 0,028 à 0,200 selon la série).
#:
#: Limite connue : la série `base` (1999) résiste — 66 px de dérive entre deux
#: tirages, arête gauche introuvable. C'est un regroupement commercial et non une
#: mise en page. Jumeau de `CardFrame.pokemon`.
POKEMON = ArtBox(0.0850, 0.1055, 0.9200, 0.4727)

#: Pokémon, cartes Dresseur — et c'est un axe qui a été payé pour être appris.
#:
#: Mesuré dans la même série, la fenêtre d'un Pokémon s'arrête à la ligne 390 et
#: celle d'un Dresseur à la ligne 430 : quarante pixels, 5 % de la hauteur. Tant
#: que les deux familles étaient mêlées, l'arête haute dérivait de 32 px d'un
#: tirage à l'autre, et cette dérive était le seul symptôme.
#:
#: Le Dresseur garde donc le sien : sous la fenêtre standard il perd 1,8 bit de
#: moyenne et 3 bits sur la paire la plus serrée. Jumeau de
#: `CardFrame.pokemonTrainer`.
POKEMON_TRAINER = ArtBox(0.0850, 0.1455, 0.9200, 0.5164)

#: Pokémon « pleine page » — 1 937 cartes, au-dessus du décompte officiel.
#:
#: **L'illustration *est* la carte**, et le banc le dit dans son vocabulaire :
#: une `Special illustration rare` rend un relief d'arêtes de 3,3 / 1,1 / 0,0 /
#: 1,9, c'est-à-dire aucune arête dans aucune direction. Il n'y a pas de fenêtre
#: à trouver, et la bonne réponse est de tout prendre.
#:
#: Le gabarit est déclaré plutôt que laissé à `None` pour que la parité avec le
#: Dart reste vérifiable : découper de 0 à 1 rend l'image entière des deux côtés,
#: mais un cadre sans pendant échapperait au test. Jumeau de
#: `CardFrame.pokemonFull`.
POKEMON_FULL = ArtBox(0.0, 0.0, 1.0, 1.0)


#: Wankul, cartes debout — les Personnages. Jumeau de `CardFrame.wankul`.
#:
#: Mesuré sur onze cartes par deux signaux concordants (`app.measure.
#: wankul_art_window`) : le gradient de l'image moyenne, dont la crête du bas
#: culmine à 42,9 contre 5 à 6 pour le contenu, et le début du pavé de texte
#: relevé carte par carte — médiane 0,6881, écart interquartile 0,0107, soit
#: 0,0024 du bord lu sur le gradient.
#:
#: Une carte seule avait rendu un cadre asymétrique ; l'échantillon a montré
#: que l'écart venait de la détection, pas de la maquette.
WANKUL = ArtBox(0.0483, 0.0298, 0.9450, 0.6857)


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
    if game == "pokemon":
        return _pokemon_box(layout)
    if game == "riftbound":
        return RIFTBOUND_LANDSCAPE if layout == "landscape" else RIFTBOUND_PORTRAIT
    if game == "wankul":
        # **La maquette horizontale n'est pas mesurée, et rend donc `None`.**
        # Ce n'est pas la verticale tournée d'un quart de tour, contrairement à
        # Riftbound : la verticale porte une illustration encadrée, l'horizontale
        # la porte en plein cadre avec les textes posés dessus. Leur appliquer le
        # même gabarit découperait un pavé de texte en croyant tenir un dessin.
        #
        # Deux cartes horizontales sont connues et elles ne concordent pas — la
        # seconde est une édition Gold, dont le traitement holographique déjoue
        # la détection des bandeaux et qui n'est de toute façon pas
        # représentative. Une seule pièce exploitable ne fait pas un gabarit ;
        # la verticale vient d'en administrer la preuve.
        return None if layout == "horizontal" else WANKUL
    return None


#: Jeux dont la source publie une illustration **déjà détourée**.
#:
#: Pour eux, `box_for` rend `None` et l'image part telle quelle : la redécouper
#: l'amputerait. C'est le cas de Magic, dont Scryfall sert l'illustration seule.
#:
#: **Cette liste existe parce que `None` est ambigu.** Il signifie « ne rien
#: découper », ce qui est juste pour Magic et faux pour tout jeu dont la source
#: publie la carte entière. Un cinquième jeu ajouté sans gabarit retombait
#: silencieusement dans ce cas et voyait son index bâti sur des cartes entières
#: prises pour des illustrations — une panne qui ne s'annonce pas, puisque les
#: empreintes restent valides et se comparent entre elles.
GAMES_WITH_PREDETOURED_ART = frozenset({"magic"})

#: Jeux couverts par l'application dont la fenêtre n'est **pas encore mesurée**.
#:
#: Y figurer est un état déclaré, pas un oubli : le test de couverture accepte
#: ces jeux-là et refuse tous les autres. En sortir demande une mesure sur de
#: vraies cartes — c'est ce que #28 a fait pour Pokémon, et ce que Riftbound a
#: payé de trois méthodes et deux échecs.
GAMES_AWAITING_ART_BOX = frozenset()

#: Maquettes connues mais **pas encore mesurées**, jeu par orientation.
#:
#: Plus fin que [GAMES_AWAITING_ART_BOX], qui raisonne par jeu : Wankul a deux
#: mises en page distinctes, et l'une est mesurée quand l'autre ne l'est pas.
#: Déclarer l'attente à ce grain évite de faire passer le jeu entier pour
#: inachevé, comme de faire passer la moitié manquante pour réglée.
LAYOUTS_AWAITING_ART_BOX = frozenset({("wankul", "horizontal")})


def _pokemon_box(layout: str | None) -> ArtBox:
    """Fenêtre d'une carte Pokémon, d'après la famille rangée par l'ingestion.

    `layout` porte ici la sortie de `tcgdex_ingest.art_layout`, qui applique les
    cinq discriminants mesurés — la série pour le périmètre, le numéro contre le
    décompte officiel pour la pleine page, `category` pour la mise en page,
    `suffix`/`stage` pour la fenêtre haute, `energyType` pour l'énergie de base.
    Aucun de ces choix n'est refait ici : ce module ne fait que traduire.

    Une énergie de base (`energy`) **n'arrive pas jusqu'ici** — elle est écartée
    de l'index par `pending_prints`, 97,1 % ayant une jumelle sous le seuil de
    confiance et 12 % étant annoncées à tort avec assurance. Si elle y arrivait,
    la fenêtre standard lui serait appliquée par défaut, ce qui est sans
    conséquence : c'est l'exclusion en amont qui la protège, pas ce gabarit.
    """
    if layout == "trainer":
        return POKEMON_TRAINER
    if layout == "full":
        return POKEMON_FULL
    # `pokemon`, `special-energy`, et tout ce qui viendrait s'ajouter : la
    # fenêtre la plus étroite, celle qui capte de l'illustration pure.
    return POKEMON


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
