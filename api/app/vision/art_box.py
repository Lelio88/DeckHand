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
#: SWU y figure pour ses **599 cartes couchées** — 445 Leaders et 154 Bases,
#: soit un quart de son catalogue, la plus forte proportion des trois jeux.
GAMES_WITH_LANDSCAPE = frozenset({"riftbound", "wankul", "swu", "lorcana"})

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
#:
#: **Éprouvé depuis sur les 812 verticales du catalogue, et conservé.** Le
#: gradient de leur moyenne donne une fenêtre un peu plus large et surtout plus
#: basse — (0,0450, 0,0321, 0,9517, 0,7024) —, ce qui pouvait passer pour une
#: mesure plus solide. Elle est moins bonne : sous elle, l'index annonce à tort
#: avec assurance **1,04 %** des cartes contre 0,84 % sous celle-ci. Les 0,017
#: de hauteur supplémentaires mordent sur le haut du pavé de texte, qui est le
#: même sur toutes les cartes — de l'information dépensée en constante. Un
#: échantillon plus grand ne rend pas mécaniquement un meilleur gabarit.
WANKUL = ArtBox(0.0483, 0.0298, 0.9450, 0.6857)

#: Wankul couché, bloc de texte **en haut** — 77 Terrains sur 146.
#:
#: L'illustration occupe tout ce qui reste sous les bandeaux. Deux signaux
#: indépendants donnent la même arête haute : le gradient de l'image moyenne
#: place le bord bas des bandeaux à 0,4150, et la variance entre cartes ouvre sa
#: plus longue plage libre à 0,4167 — 0,0017 d'écart, soit une ligne.
#:
#: Les bords latéraux 0,0440 et 0,9536 sont ceux des bandeaux eux-mêmes, mesurés
#: à l'identique sur les deux maquettes. L'illustration, elle, va bord à bord :
#: cette marge n'est pas dans le dessin, elle est **prise volontairement**, parce
#: qu'un quadrilatère détecté de travers ramènerait sinon du fond de photo. La
#: borne basse retient la même marge convertie dans l'autre sens
#: (0,0440 × 88/63 = 0,0615), le carton étant plus large que haut une fois couché.
#:
#: La ligne de crédit du bas — « Art : … » à gauche, code d'extension à droite —
#: reste dans la fenêtre. Elle varie d'une carte à l'autre : elle discrimine au
#: lieu de brouiller, comme les encoches d'angle de la maquette debout.
#: Jumeau de `CardFrame.wankulWideBandsTop`.
WANKUL_BANDS_TOP = ArtBox(0.0440, 0.4150, 0.9536, 0.9385)

#: Wankul couché, bloc de texte **en bas** — 69 Terrains.
#:
#: **Ce n'est pas la précédente retournée**, et c'est le point à ne pas
#: reperdre : un demi-tour placerait le bloc à 0,5850 → 0,8300, or il est à
#: 0,6300 → 0,8750. Ces 0,045 d'écart sont ce qui oblige à déclarer deux cadres
#: plutôt que de compter sur les deux quarts de tour que la reconnaissance essaie
#: déjà. Le bloc a en revanche exactement la même hauteur (0,2450) : c'est le
#: même gabarit de bandeaux, posé ailleurs.
#:
#: Le titre de la carte, lui, tombe **dans** la fenêtre : il est posé juste
#: au-dessus des bandeaux, vers 0,52. C'est sans conséquence — il est constant
#: pour une carte donnée, comme le nom incrusté des champs de bataille
#: Riftbound — et le retirer coûterait un dixième de la hauteur d'illustration.
#: Jumeau de `CardFrame.wankulWideBandsBottom`.
WANKUL_BANDS_BOTTOM = ArtBox(0.0440, 0.0615, 0.9536, 0.6300)

#: Star Wars Unlimited — **cinq gabarits, un par type**, et c'est la mesure qui
#: le dit.
#:
#: Le catalogue distingue vingt-et-un couples (type, traitement). `--compare` les
#: a éprouvés les uns sous la fenêtre des autres, et le résultat est identique
#: dans les cinq types : **la fenêtre du traitement `Normal` est la meilleure ou
#: l'égale de toutes les autres**. `Base/Hyperspace` gagne même une paire sous
#: elle (31,7 / 20 contre 31,9 / 18 sous la sienne), et `Unit/Prestige` aussi
#: (32,0 / 20 contre 31,1 / 17). L'inverse est faux partout : `Base/Normal`
#: tombe à 25,2 / 13 sous la fenêtre `Hyperspace`, et la fenêtre `Showcase` est
#: ruineuse sur les autres Leaders — 13,8 / 6.
#:
#: La raison est celle que Pokémon avait déjà relevée : la fenêtre étroite tient
#: entièrement dans l'illustration des cartes bord à bord, où elle capte donc de
#: l'illustration pure ; la fenêtre large embarque du cadre sur une carte
#: standard et lui coûte sa marge. *Un seul gabarit, le plus étroit.*
#:
#: `layout` porte ici le **type de carte**, écrit par `swu_ingest`.
#: Jumeau de `CardFrame.swuUnit`.
SWU_UNIT = ArtBox(0.1495, 0.1397, 0.9042, 0.6269)

#: SWU, Upgrade — même maquette que l'Unit, illustration en haut, mais une
#: fenêtre à elle : elle commence plus à gauche et s'arrête plus haut.
#: Jumeau de `CardFrame.swuUpgrade`.
SWU_UPGRADE = ArtBox(0.0976, 0.1212, 0.9069, 0.5622)

#: SWU, Event — **l'illustration est en bas**, le pavé de texte en haut.
#:
#: C'est l'inverse de l'Unit, et rien ne le laissait prévoir : le banc, qui
#: sondait en haut, rendait le pavé de texte comme fenêtre avec une stabilité
#: parfaite — 1 px de dérive entre deux tirages disjoints — et une séparation
#: de 16,5 bits contre 31 ailleurs, avec une paire à 3 bits. *Une fenêtre
#: reproductible n'est pas une fenêtre juste.* C'est l'image moyenne, regardée,
#: qui a nommé la cause. Jumeau de `CardFrame.swuEvent`.
SWU_EVENT = ArtBox(0.1038, 0.5212, 0.8979, 0.9103)

#: SWU, Leader — carte **couchée**, illustration sur la moitié gauche.
#:
#: Les 445 Leaders sont imprimés en travers et double-face. Leur illustration
#: n'occupe que la moitié gauche du carton, le pavé de texte prenant l'autre :
#: sonder au centre, comme le fait Pokémon, y tombait en plein texte et rendait
#: 18,7 bits avec une paire à 8. Jumeau de `CardFrame.swuLeader`.
SWU_LEADER = ArtBox(0.0321, 0.0877, 0.4513, 0.8084)

#: SWU, Base — carte **couchée** elle aussi, mais illustration pleine largeur.
#:
#: 175 des 180 Bases non brillantes sont couchées ; les cinq debout sont des
#: variantes `Hyperspace`, et aucune règle tirée du type, du traitement ou de
#: l'extension ne les isole. Elles se lisent sur l'image, ce que la
#: reconnaissance fait déjà en essayant les deux quarts de tour.
#: Jumeau de `CardFrame.swuBase`.
SWU_BASE = ArtBox(0.0712, 0.1692, 0.9263, 0.6267)

#: One Piece — **une seule fenêtre pour les quatre types**, et c'est la mesure
#: qui le dit.
#:
#: `--compare` a éprouvé chaque type sous la fenêtre des trois autres : toutes
#: les paires restent entre 14 et 21 bits, au-dessus du seuil de confiance de
#: 12, et aucune fenêtre n'est significativement meilleure. C'est la conclusion
#: de Pokémon sur ses quatre époques, mot pour mot.
#:
#: **La borne basse est celle du filigrane, pas celle de l'illustration.** Les
#: rendus publiés portent « SAMPLE » en travers, et il vient de l'éditeur —
#: Bandai marque ainsi sa liste de cartes, optcgapi ne fait que la reprendre.
#: Mesuré sur les quatre types par la luminance de l'image moyenne, la bande
#: claire commence à **0,4224 sur les quatre**, à la ligne près. Les Personnages
#: et les Événements s'y arrêtaient d'eux-mêmes ; les Leaders et les Décors la
#: traversaient, dérivant de 156 et 130 px entre deux tirages disjoints.
#:
#: C'est ce plafond qui rend le scan possible : la zone retenue est de
#: l'illustration pure, **présente à l'identique sur une photo de carton**, qui
#: n'est pas marquée. Une fenêtre plus basse comparerait une empreinte marquée à
#: une empreinte qui ne l'est pas, et la reconnaissance échouerait sans que rien
#: ne le dise. Jumeau de `CardFrame.onePiece`.
ONEPIECE = ArtBox(0.0567, 0.0835, 0.9550, 0.4212)

#: Lorcana debout — Personnages, Actions et Objets, soit 3 086 cartes sur 3 192.
#:
#: **Une seule fenêtre pour les trois types**, et c'est `--compare` qui l'a
#: choisie. Chaque type a été éprouvé sous la fenêtre des deux autres : toutes
#: les paires restent entre 13 et 17 bits, au-dessus du seuil de confiance de
#: 12. Les trois sont donc interchangeables — comme les quatre époques de Pokémon
#: et les quatre types de One Piece.
#:
#: **C'est la fenêtre des Actions qui est retenue, et pas celle des
#: Personnages** — pourtant huit fois plus nombreux. Le critère est la pire paire
#: sous chaque fenêtre : 15 bits sous celle des Actions, 13 sous celle des
#: Personnages, 12 sous celle des Objets. Elle fait même mieux chez les Objets
#: que la leur (17 contre 12). Un échantillon plus grand ne fait pas un meilleur
#: gabarit — la leçon des 812 verticales de Wankul, à l'identique.
#:
#: Jumeau de `CardFrame.lorcana`.
LORCANA = ArtBox(0.0451, 0.1101, 0.9570, 0.5639)

#: Lorcana couché — les 106 Lieux.
#:
#: **Le rendu est publié DEBOUT, contenu tourné**, ce qu'aucune autre source ne
#: fait. Les Lieux sortent en 488 × 681 comme toutes les autres cartes, mais leur
#: texte s'y lit de bas en haut : c'est une carte physiquement couchée, mise dans
#: un cadre portrait. Le champ `layout` de la source dit `landscape` — il décrit
#: le carton, pas le fichier.
#:
#: Une première mesure a redimensionné ces rendus en 681 × 488, donc **écrasés**,
#: sans tourner. Le banc a rendu une paire à **1 bit** sur quarante cartes : le
#: nombre disait « ces cartes sont indiscernables » là où il fallait lire
#: « l'image est déformée ». C'est le piège Wankul, où `orientation` ne disait
#: pas non plus comment la carte est imprimée — **l'orientation se vérifie sur
#: l'image, jamais sur un champ.**
#:
#: Un quart de tour **horaire** redresse le Lieu — texte horizontal, illustration
#: en haut —, c'est-à-dire la carte telle qu'elle est posée sur la table, et donc
#: telle que l'appareil la photographie. Même sens que les Terrains de Wankul.
#: Cette fenêtre s'exprime dans ce repère redressé.
#:
#: Jumeau de `CardFrame.lorcanaLocation`.
LORCANA_LOCATION = ArtBox(0.0367, 0.1516, 0.9662, 0.4877)

#: Valeurs de `layout` qui désignent l'une des deux maquettes couchées.
#:
#: **Déclarées ici et non dans `wankul_frame`**, qui les produit : ce module doit
#: rester sans dépendance — il est le jumeau du Dart et le socle de tout le
#: pipeline —, et faire remonter numpy jusqu'ici pour trois chaînes de
#: caractères serait payer cher un import.
WANKUL_LAYOUT_BANDS_TOP = "horizontal-bandeaux-haut"
WANKUL_LAYOUT_BANDS_BOTTOM = "horizontal-bandeaux-bas"


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
        return _wankul_box(layout)
    if game == "swu":
        return _swu_box(layout)
    if game == "lorcana":
        # `layout` porte le type. Seul `Location` est imprimé en travers, et les
        # 106 cartes concernées sont exactement les 106 que la source déclare
        # `landscape` — vérifié carte par carte au banc de taxonomie.
        return LORCANA_LOCATION if layout == "Location" else LORCANA
    if game == "onepiece":
        # **Une seule fenêtre pour les quatre types**, `layout` n'y décidant
        # rien : les quatre sont interchangeables, mesuré en bits. Le type
        # reste écrit en base — le constructeur en a besoin — mais il ne
        # gouverne pas le découpage, contrairement aux cinq autres jeux.
        return ONEPIECE
    return None


def _swu_box(layout: str | None) -> ArtBox:
    """Fenêtre d'une carte SWU, d'après son **type**.

    `layout` porte ici le type publié par la source — `Unit`, `Event`,
    `Upgrade`, `Leader`, `Base` —, écrit tel quel par `swu_ingest`. C'est le
    seul discriminant : le traitement d'impression (`Hyperspace`, `Showcase`,
    `Prestige`…) n'en demande pas d'autre, `--compare` ayant montré que la
    fenêtre du traitement ordinaire les sert tous au moins aussi bien.

    Un type inconnu retombe sur celle de l'Unit, qui est la maquette
    majoritaire — 1 369 cartes sur 2 181. Ce n'est pas confortable : appliquée à
    un Event, elle capterait le pavé de texte. Mais `None` ferait hacher la
    carte entière **sans que rien ne le signale**, ce que le garde-fou de
    `GAMES_WITH_PREDETOURED_ART` existe précisément pour empêcher.
    """
    if layout == "Event":
        return SWU_EVENT
    if layout == "Upgrade":
        return SWU_UPGRADE
    if layout == "Leader":
        return SWU_LEADER
    if layout == "Base":
        return SWU_BASE
    return SWU_UNIT


def _wankul_box(layout: str | None) -> ArtBox:
    """Fenêtre d'une carte Wankul, d'après son orientation puis sa maquette.

    **Deux niveaux, et le second ne vient pas de la source.** L'orientation est
    publiée — enfin, elle se déduit de la présence d'un rendu paysage. La
    maquette d'une carte couchée, elle, ne l'est pas : elle se mesure sur
    l'image, et c'est `wankul_frame.maquette` qui la rend au constructeur
    d'index sous la forme d'un `layout` affiné.

    Une carte couchée dont la maquette n'a pas été mesurée retombe sur la
    maquette majoritaire (bandeaux en haut, 77 sur 146). Ce n'est pas un choix
    confortable — appliquée aux 69 autres, cette fenêtre avale leur bloc de
    texte en entier — mais c'est le moins mauvais : `None` ferait hacher la
    carte entière **sans que rien ne le signale**, ce que le garde-fou de
    `GAMES_WITH_PREDETOURED_ART` existe précisément pour empêcher. Le
    constructeur d'index ne s'y fie jamais : il classe chaque Terrain avant de
    découper.
    """
    if layout == WANKUL_LAYOUT_BANDS_BOTTOM:
        return WANKUL_BANDS_BOTTOM
    if layout in (WANKUL_LAYOUT_BANDS_TOP, "horizontal"):
        return WANKUL_BANDS_TOP
    return WANKUL


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
#: Plus fin que [GAMES_AWAITING_ART_BOX], qui raisonne par jeu : un même jeu peut
#: avoir deux mises en page dont une seule est mesurée. Wankul y a figuré tant
#: que sa maquette couchée manquait ; l'ensemble est vide aujourd'hui, et c'est
#: un état, pas un oubli — le test de couverture s'en sert dans les deux sens.
LAYOUTS_AWAITING_ART_BOX: frozenset[tuple[str, str]] = frozenset()


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
