/// Localisation de l'illustration sur une carte.
///
/// L'empreinte porte sur l'illustration seule ; il faut donc la découper dans la
/// photo de la carte entière. Sa position est **fixe en proportions**, ce qui
/// évite toute détection : cadrer la carte suffit.
///
/// Les gabarits sont **cloisonnés par jeu** : une carte Riftbound n'a rien à
/// voir avec un cadre Magic, et les essayer tous multiplierait le calcul autant
/// que le risque de correspondance fortuite.
///
/// **Deux gabarits, et c'est mesuré.** Magic a changé de cadre en 2003, et
/// l'illustration n'occupe pas la même zone avant et après. Les proportions
/// ci-dessous ont été obtenues en cherchant, dans le rendu complet de la carte,
/// la fenêtre qui reproduit l'illustration publiée par Scryfall — et non
/// estimées à la règle.
///
/// Sur 50 cartes tirées au hasard, le gabarit moderne seul situe correctement
/// l'illustration dans 42 cas ; essayer les deux et retenir la meilleure
/// correspondance en situe 47. Le coût est négligeable : deux empreintes à
/// calculer, deux recherches linéaires de quelques millisecondes.
///
/// **Limite connue** : les mises en page spéciales — `saga` (illustration
/// verticale), `transform`, cartes pleine page — échappent aux deux gabarits.
/// Elles relèveront de l'OCR du nom, prévu en appoint.
library;

import 'package:image/image.dart' as img;

import 'art_hash.dart';
import 'card_bounds.dart';

/// Zone d'illustration, en proportions de la carte.
typedef ArtBox = ({double left, double top, double right, double bottom});

/// Cadres de carte reconnus.
enum CardFrame {
  /// Cadre introduit en 2003, majoritaire aujourd'hui.
  modern((left: 0.080, top: 0.120, right: 0.920, bottom: 0.550), 'magic'),

  /// Cadre d'origine, antérieur à 2003. Ses marges latérales sont plus larges.
  /// Loin d'être anecdotique : le Pauper puise dans toute l'histoire du jeu.
  legacy((left: 0.114, top: 0.100, right: 0.890, bottom: 0.538), 'magic'),

  /// Riftbound, cartes verticales — l'immense majorité.
  ///
  /// **Mesuré par la luminosité de l'image moyenne**, deux méthodes fondées sur
  /// la variance ayant échoué avant : la première confondait l'illustration
  /// avec le cadre ouvragé, la seconde désignait le texte de règles, dont le
  /// contraste noir sur blanc écrase celui d'illustrations aux tons moyens. Sur
  /// l'image moyenne de seize cartes, les trois zones se séparent par leur
  /// clarté — cadre sombre, illustration en tons moyens, pavés de texte quasi
  /// blancs. Une mesure indépendante retombe sur les mêmes valeurs à 0,008
  /// près.
  ///
  /// La borne basse (0,517) exclut la ligne de type, relevée au pixel : elle
  /// forme une bande pleine largeur qui, sinon, gèlerait une ligne entière de
  /// la grille d'empreinte — un huitième de son information dépensé en
  /// constante.
  riftbound((
    left: 0.065,
    top: 0.047,
    right: 0.934,
    bottom: 0.517,
  ), 'riftbound'),

  /// Riftbound, cartes couchées : les 64 champs de bataille.
  ///
  /// Leur nom est incrusté *dans* l'illustration et ne peut en être retiré ;
  /// il est donc haché avec elle, ce qui est sans conséquence puisqu'il est
  /// constant pour une carte donnée.
  ///
  /// **La carte est posée en travers**, d'où [landscape] : mesuré sur le
  /// catalogue, une carte couchée fait 1039 × 744, soit un rapport de 1,397 —
  /// exactement l'inverse de 0,716. Ce n'est pas un autre format, c'est la
  /// même carte tournée d'un quart de tour.
  riftboundWide(
    (left: 0.041, top: 0.199, right: 0.962, bottom: 0.777),
    'riftbound',
    landscape: true,
  ),

  /// Yu-Gi-Oh, cadre ordinaire — 14 101 cartes sur 14 491.
  ///
  /// **Mesuré par recoupement, non par une heuristique.** La source publie la
  /// carte entière *et* son illustration détourée : la fenêtre se retrouve donc
  /// en cherchant, dans la première, la région qui reproduit la seconde. C'est
  /// la méthode des deux cadres Magic, et elle rend ici un résultat sans
  /// équivalent — sur 20 cartes tirées dans dix familles de cadre (effet, magie,
  /// piège, normale, XYZ, fusion, lien, synchro, rituel, jeton), **la même
  /// fenêtre à 0,001 près**, pour un écart résiduel de 1 niveau de gris sur 255.
  ///
  /// Riftbound avait demandé trois méthodes et deux échecs pour un seul
  /// gabarit ; ici la source répond elle-même à la question.
  yugioh((left: 0.1181, top: 0.1823, right: 0.8807, bottom: 0.7055), 'yugioh'),

  /// Yu-Gi-Oh, cartes Pendulum — 390 cartes, soit 2,7 %.
  ///
  /// Leur illustration déborde sous le cadre ordinaire pour laisser place aux
  /// deux échelles latérales : plus large (0,062 → 0,936 contre 0,118 → 0,881)
  /// et un peu moins haute. Mesurée sur 18 cartes des six sous-familles
  /// Pendulum, la fenêtre est stable à 0,001 près.
  ///
  /// **Le discriminant est un contrat, pas une devinette.** `frameType` porte
  /// « pendulum » pour ces cartes et pour elles seules — là où Pokémon n'offre
  /// que la rareté, dont le vocabulaire compte quarante valeurs qui ont changé
  /// plusieurs fois en vingt-sept ans (#28).
  ///
  /// **L'illustration détourée de la source ne sert pas ici** : pour une
  /// Pendulum, elle englobe le pavé de texte en plus de l'illustration. C'est
  /// ce qui a fait échouer la première mesure, et c'est pourquoi l'index
  /// découpe lui-même la carte entière plutôt que de faire confiance au
  /// recadrage publié.
  yugiohPendulum((
    left: 0.0615,
    top: 0.1789,
    right: 0.9360,
    bottom: 0.6238,
  ), 'yugioh'),

  /// Pokémon encadré — 17 365 cartes, et **une seule fenêtre pour vingt ans**.
  ///
  /// Le cadre a changé cinq fois depuis 1999 ; la fenêtre presque pas. Chaque
  /// époque a été éprouvée sous la fenêtre des quatre autres : la distance
  /// moyenne entre empreintes reste entre 31,1 et 32,3 bits, et le gabarit
  /// d'origine n'est jamais meilleur de façon significative — il lui arrive
  /// d'être battu par un étranger. **Les gabarits d'époque sont
  /// interchangeables** (#28), celui-ci les remplace tous.
  ///
  /// Il sert aussi la **fenêtre haute** (`ex`, `V`, `VMAX`…) : la fenêtre
  /// standard tient entièrement dans leur illustration, donc y capte de
  /// l'illustration pure et fait aussi bien que la leur. L'inverse est faux, la
  /// fenêtre large embarquant du cadre sur une carte standard. Et l'**énergie
  /// spéciale**, dont les fenêtres d'époque ne sont pas stables (arête gauche de
  /// 0,028 à 0,200 selon la série) pour deux bits de marge en moins seulement.
  ///
  /// Limite connue : la série `base` (1999) résiste, 66 px de dérive entre deux
  /// tirages. C'est un regroupement commercial et non une mise en page.
  pokemon((
    left: 0.0850,
    top: 0.1055,
    right: 0.9200,
    bottom: 0.4727,
  ), 'pokemon'),

  /// Pokémon, cartes Dresseur — un axe qui a été payé pour être appris.
  ///
  /// Mesuré dans la même série, la fenêtre d'un Pokémon s'arrête à la ligne 390
  /// et celle d'un Dresseur à la ligne 430 : quarante pixels, 5 % de la hauteur.
  /// Tant que les deux familles étaient mêlées, l'arête haute dérivait de 32 px
  /// d'un tirage à l'autre, et cette dérive était le seul symptôme.
  ///
  /// Sous la fenêtre standard, le Dresseur perd 1,8 bit de moyenne et 3 bits sur
  /// la paire la plus serrée : il garde donc le sien.
  pokemonTrainer((
    left: 0.0850,
    top: 0.1455,
    right: 0.9200,
    bottom: 0.5164,
  ), 'pokemon'),

  /// Pokémon « pleine page » — 1 937 cartes, au-dessus du décompte officiel.
  ///
  /// **L'illustration *est* la carte.** Le banc le dit dans son vocabulaire :
  /// une `Special illustration rare` rend un relief d'arêtes de 3,3 / 1,1 / 0,0
  /// / 1,9, c'est-à-dire aucune arête dans aucune direction. Il n'y a pas de
  /// fenêtre à trouver, et la bonne réponse est de tout prendre.
  ///
  /// Ce cadre est déclaré plutôt qu'implicite parce que la photo, elle, ne dit
  /// pas à quelle famille appartient la carte : les trois hypothèses Pokémon
  /// sont calculées et la recherche retient la meilleure. Sans celle-ci, aucune
  /// des 1 937 cartes pleine page ne serait jamais retrouvée.
  pokemonFull((
    left: 0.0,
    top: 0.0,
    right: 1.0,
    bottom: 1.0,
  ), 'pokemon'),

  /// Wankul, cartes debout — les Personnages.
  ///
  /// **Mesuré sur onze cartes, par deux signaux qui concordent.** Le gradient
  /// de l'image moyenne donne les arêtes du cadre : la crête du bas culmine à
  /// 42,9 contre 5 à 6 pour le contenu, un rapport de huit. Le début du pavé de
  /// texte, relevé carte par carte, tombe à 0,6881 de médiane pour un écart
  /// interquartile de 0,0107 — soit 0,0024 du bord lu sur le gradient.
  ///
  /// **Une seule carte avait rendu un cadre asymétrique**, 8,9 % de marge à
  /// gauche contre 6,4 % à droite. L'échantillon a tranché : 0,048 et 0,055,
  /// l'écart venait de la détection et non de la maquette. C'est la raison
  /// d'être d'un banc, et un rappel que la mesure sur une pièce n'en est pas
  /// une.
  ///
  /// Les deux encoches d'angle du haut — l'icône de coût à gauche, la Force à
  /// droite — sont **dans** la fenêtre. Les retirer coûterait de l'illustration
  /// sur toute la largeur pour gagner deux coins, et la variance entre cartes
  /// montre qu'elles ne sont pas constantes : la Force change d'une carte à
  /// l'autre, donc elle discrimine au lieu de brouiller.
  ///
  /// **Éprouvé depuis sur les 812 verticales du catalogue, et conservé.** Le
  /// gradient de leur moyenne donne une fenêtre plus basse — bottom 0,7024 —
  /// qui pouvait passer pour une mesure plus solide. Elle est moins bonne :
  /// sous elle l'index annonce à tort avec assurance 1,04 % des cartes contre
  /// 0,84 % sous celle-ci. Les 0,017 de plus mordent sur le haut du pavé de
  /// texte, identique sur toutes les cartes. Un échantillon plus grand ne rend
  /// pas mécaniquement un meilleur gabarit.
  wankul((
    left: 0.0483,
    top: 0.0298,
    right: 0.9450,
    bottom: 0.6857,
  ), 'wankul'),

  /// Wankul couché — les Terrains, bloc de texte **en haut** (77 sur 146).
  ///
  /// **La carte est posée en travers**, comme un champ de bataille Riftbound,
  /// d'où [landscape]. Le rendu que publie la source la montre pourtant
  /// debout, tournée d'un quart de tour : c'est sa vignette. Un seul quart de
  /// tour horaire redresse les 146, vérifié en les regardant toutes — aucune
  /// n'est à l'envers.
  ///
  /// Deux signaux indépendants donnent la même arête haute : le gradient de
  /// l'image moyenne de 77 cartes place le bord bas des bandeaux à 0,4150, et
  /// la variance entre cartes ouvre sa plus longue plage libre à 0,4167. Un
  /// écart d'une ligne.
  ///
  /// Les marges 0,0440 / 0,9536 sont celles des bandeaux eux-mêmes.
  /// L'illustration, elle, va bord à bord : la marge est **prise
  /// volontairement**, un quadrilatère détecté de travers ramènerait sinon du
  /// fond de photo. La borne basse retient la même marge convertie dans
  /// l'autre sens (0,0440 × 88/63), le carton étant plus large que haut une
  /// fois couché.
  wankulWideBandsTop(
    (left: 0.0440, top: 0.4150, right: 0.9536, bottom: 0.9385),
    'wankul',
    landscape: true,
  ),

  /// Wankul couché, bloc de texte **en bas** (69 Terrains).
  ///
  /// **Ce n'est pas [wankulWideBandsTop] retournée**, et c'est pourquoi ce
  /// cadre existe : un demi-tour placerait le bloc à 0,5850 → 0,8300, or il
  /// est à 0,6300 → 0,8750. Ces 0,045 d'écart sont ce qui interdit de compter
  /// sur les deux quarts de tour que [artHashCandidatesInQuad] essaie déjà. Le
  /// bloc a en revanche exactement la même hauteur (0,2450) : le même gabarit
  /// de bandeaux, posé ailleurs.
  ///
  /// Le titre de la carte tombe **dans** la fenêtre — il est posé juste
  /// au-dessus des bandeaux, vers 0,52. Sans conséquence : il est constant
  /// pour une carte donnée, exactement comme le nom incrusté d'un champ de
  /// bataille Riftbound, et le retirer coûterait un dixième de la hauteur
  /// d'illustration.
  wankulWideBandsBottom(
    (left: 0.0440, top: 0.0615, right: 0.9536, bottom: 0.6300),
    'wankul',
    landscape: true,
  ),

  /// Star Wars Unlimited, Unité — 1 369 cartes, la maquette majoritaire.
  ///
  /// **Cinq gabarits pour ce jeu, un par type**, alors que son catalogue
  /// distingue vingt-et-un couples (type, traitement). Chacun a été éprouvé
  /// sous la fenêtre des autres, et le résultat est le même dans les cinq
  /// types : la fenêtre du traitement ordinaire est la meilleure ou l'égale de
  /// toutes. `Unit/Prestige` gagne même une paire sous elle — 32,0 / 20 contre
  /// 31,1 / 17 sous la sienne — quand `Unit/Normal` tombe à 23,5 / 11 sous
  /// celle de `Prestige`. La fenêtre étroite tient dans l'illustration des
  /// cartes bord à bord ; la large embarque du cadre sur une carte standard.
  swuUnit((
    left: 0.1495,
    top: 0.1397,
    right: 0.9042,
    bottom: 0.6269,
  ), 'swu'),

  /// SWU, Amélioration — même maquette que l'unité, illustration en haut, mais
  /// une fenêtre à elle : elle commence plus à gauche et s'arrête plus haut.
  swuUpgrade((
    left: 0.0976,
    top: 0.1212,
    right: 0.9069,
    bottom: 0.5622,
  ), 'swu'),

  /// SWU, Événement — **l'illustration est en bas**, le texte en haut.
  ///
  /// C'est l'inverse de l'unité, et rien ne le laissait prévoir. Le banc, qui
  /// sondait en haut, rendait le pavé de texte comme fenêtre avec une
  /// stabilité parfaite — 1 px de dérive entre deux tirages disjoints — et une
  /// séparation de 16,5 bits contre 31 ailleurs, avec une paire à 3 bits :
  /// *une fenêtre reproductible n'est pas une fenêtre juste*. C'est l'image
  /// moyenne, regardée, qui a nommé la cause.
  swuEvent((
    left: 0.1038,
    top: 0.5212,
    right: 0.8979,
    bottom: 0.9103,
  ), 'swu'),

  /// SWU, Leader — carte **couchée**, illustration sur la moitié gauche.
  ///
  /// Les 445 leaders sont imprimés en travers et double-face, et leur
  /// illustration n'occupe que la moitié gauche du carton, le pavé de texte
  /// prenant l'autre. Sonder au centre y tombait en plein texte : 18,7 bits
  /// avec une paire à 8, contre 31,1 et 21 une fois le sondage déplacé.
  swuLeader(
    (left: 0.0321, top: 0.0877, right: 0.4513, bottom: 0.8084),
    'swu',
    landscape: true,
  ),

  /// SWU, Base — couchée elle aussi, mais illustration pleine largeur.
  ///
  /// 175 des 180 bases non brillantes sont couchées ; les cinq debout sont des
  /// variantes `Hyperspace`, et aucune règle tirée du type, du traitement ou de
  /// l'extension ne les isole. Elles se lisent sur l'image — ce que la
  /// reconnaissance fait déjà, en essayant les deux quarts de tour.
  swuBase(
    (left: 0.0712, top: 0.1692, right: 0.9263, bottom: 0.6267),
    'swu',
    landscape: true,
  ),

  /// One Piece — **un seul cadre pour les quatre types**, et c'est mesuré.
  ///
  /// Chaque type a été éprouvé sous la fenêtre des trois autres : toutes les
  /// paires restent entre 14 et 21 bits, au-dessus du seuil de confiance de 12,
  /// et aucune fenêtre n'est significativement meilleure. C'est la conclusion de
  /// Pokémon sur ses quatre époques, mot pour mot — à l'opposé de SWU, dont les
  /// cinq types ont chacun le sien.
  ///
  /// **La borne basse est celle du filigrane, pas celle de l'illustration.** Les
  /// rendus publiés portent « SAMPLE » en travers, et il vient de l'éditeur :
  /// Bandai marque ainsi sa liste de cartes, la source ne fait que la reprendre.
  /// Mesuré sur les quatre types par la luminance de l'image moyenne, la bande
  /// claire commence à **0,4224 sur les quatre**, à la ligne près.
  ///
  /// C'est ce plafond qui rend le scan possible : la zone retenue est de
  /// l'illustration pure, **présente à l'identique sur une photo de carton**,
  /// qui n'est pas marqué. Descendre plus bas comparerait une empreinte marquée
  /// à une empreinte qui ne l'est pas, et la reconnaissance échouerait sans que
  /// rien ne le dise.
  onePiece(
    (left: 0.0567, top: 0.0835, right: 0.9550, bottom: 0.4212),
    'onepiece',
  ),

  /// Lorcana debout — Personnages, Actions et Objets, 3 086 cartes sur 3 192.
  ///
  /// **Une seule fenêtre pour les trois types**, et c'est `--compare` qui l'a
  /// choisie : chaque type éprouvé sous la fenêtre des deux autres reste entre
  /// 13 et 17 bits, au-dessus du seuil de confiance de 12.
  ///
  /// **C'est la fenêtre des Actions qui est retenue, et pas celle des
  /// Personnages** — pourtant huit fois plus nombreux. Le critère est la pire
  /// paire sous chaque fenêtre : 15 bits sous celle des Actions, 13 sous celle
  /// des Personnages, 12 sous celle des Objets. Elle fait même mieux chez les
  /// Objets que la leur (17 contre 12). Un échantillon plus grand ne fait pas un
  /// meilleur gabarit — la leçon des 812 verticales de Wankul, à l'identique.
  lorcana(
    (left: 0.0451, top: 0.1101, right: 0.9570, bottom: 0.5639),
    'lorcana',
  ),

  /// Lorcana couché — les 106 Lieux.
  ///
  /// **Le rendu de la source est publié debout, contenu tourné**, ce qu'aucune
  /// autre source ne fait : les Lieux sortent en 488 × 681 comme le reste, mais
  /// leur texte s'y lit de bas en haut. L'index les redresse d'un quart de tour
  /// horaire avant de hacher, et cette fenêtre s'exprime dans ce repère — celui
  /// de la carte telle qu'elle est posée sur la table, donc telle que l'appareil
  /// la photographie.
  ///
  /// Une première mesure les a redimensionnés sans tourner, donc **écrasés**, et
  /// le banc a rendu une paire à 1 bit sur quarante cartes. Le nombre disait
  /// « ces cartes sont indiscernables » là où il fallait lire « l'image est
  /// déformée ». **L'orientation se vérifie sur l'image, jamais sur un champ.**
  lorcanaLocation(
    (left: 0.0367, top: 0.1516, right: 0.9662, bottom: 0.4877),
    'lorcana',
    landscape: true,
  );

  const CardFrame(this.box, this.game, {this.landscape = false});

  final ArtBox box;

  /// Vrai lorsque la carte se pose en travers.
  ///
  /// **C'est la détection qui en a besoin, pas le découpage.** Le gabarit,
  /// lui, s'exprime déjà en proportions de la carte telle qu'elle est posée.
  /// Mais `findCard` rejette tout quadrilatère dont le rapport s'écarte de
  /// celui d'une carte debout, et une carte couchée s'en écarte de 0,68 pour
  /// une tolérance de 0,30 : elle était donc introuvable, et ce cadre — mesuré,
  /// juste, documenté — n'a jamais pu servir.
  ///
  /// Cette propriété n'ouvre l'orientation couchée qu'aux jeux qui en ont une.
  /// L'élargir à tous reviendrait à accepter n'importe quel rectangle en Magic,
  /// où toutes les cartes sont debout — et le mode de défaillance connu est
  /// précisément là : un quadrilatère faux qui passe le contrôle d'aspect.
  final bool landscape;

  /// Jeu auquel ce cadre appartient.
  ///
  /// **Essayer les cadres d'un autre jeu coûte deux fois** : le calcul, et le
  /// risque. Une carte Magic découpée au gabarit Riftbound produit une empreinte
  /// qui n'a plus de sens mais peut rencontrer par hasard une entrée de l'index
  /// — or le pipeline est mesuré à zéro faux positif annoncé avec assurance, et
  /// c'est ce résultat qu'il faut protéger.
  final String game;
}

/// Découpe la zone d'illustration correspondant à [frame].
img.Image cropArt(img.Image card, CardFrame frame) {
  final box = frame.box;
  final x = (box.left * card.width).round();
  final y = (box.top * card.height).round();
  final width = ((box.right - box.left) * card.width).round();
  final height = ((box.bottom - box.top) * card.height).round();

  return img.copyCrop(
    card,
    x: x.clamp(0, card.width - 1),
    y: y.clamp(0, card.height - 1),
    width: width.clamp(1, card.width - x),
    height: height.clamp(1, card.height - y),
  );
}

/// Une manière de lire la carte : un cadre, et l'orientation sous laquelle on
/// le cherche.
///
/// **L'orientation est une hypothèse comme le cadre.** On ignore autant l'un que
/// l'autre au moment de photographier ; la recherche tranche en retenant celle
/// qui trouve la meilleure correspondance.
typedef ArtHypothesis = ({CardFrame frame, int quarterTurns});

/// Empreintes candidates d'une carte photographiée, une par cadre du jeu.
///
/// On ne sait pas d'avance à quel cadre appartient la carte — c'est précisément
/// ce qu'on cherche à identifier. Les hypothèses du jeu courant sont donc toutes
/// calculées, et la recherche retiendra celle qui trouve la meilleure
/// correspondance.
///
/// [game] restreint les hypothèses : on sait toujours quel jeu on est en train
/// de saisir, et les cadres d'un autre jeu n'apporteraient que du bruit.
///
/// **Aucune rotation ici**, contrairement à [artHashCandidatesInQuad] : ce
/// chemin est le repli, et il reçoit une image déjà découpée aux proportions
/// d'une carte debout. Tourner ce découpage ne montrerait pas la carte sous un
/// autre angle, seulement le même rectangle mal cadré.
Map<ArtHypothesis, ArtHash> artHashCandidates(
  img.Image card, {
  String game = 'magic',
}) => {
  for (final frame in CardFrame.values)
    if (frame.game == game)
      (frame: frame, quarterTurns: 0): computeArtHash(cropArt(card, frame)),
};

/// Empreintes lues dans le quadrilatère d'une carte détectée dans la photo.
///
/// Même chose que [artHashCandidates], mais sans supposer que la carte remplit
/// l'image : la zone est lue en interpolant les quatre coins. C'est ce qui rend
/// le scan indifférent au cadrage — mesuré, la reconnaissance passe de 0 à 37
/// sur 40 dès qu'une photo s'écarte de 8 % du cadre idéal.
///
/// **Le rapport du quadrilatère choisit les sens, et n'en laisse que deux.**
/// Un carton debout donne un quadrilatère debout, que seuls les demi-tours
/// laissent debout ; un carton couché donne un quadrilatère couché, que seuls
/// les quarts de tour redressent. Les deux autres sens prélèveraient l'empreinte
/// sur une zone qu'aucune carte n'occupe.
///
/// Il en faut **deux** et pas un, parce qu'une empreinte ne survit pas au
/// demi-tour : mesuré sur du carton, la même carte lue dans le mauvais sens
/// retombe au rang 197.
///
/// **Ce que la règle recouvre.** Une carte couchée glissée dans une pochette
/// verticale se laisse détecter comme une carte debout : ce sont les bords de la
/// pochette que la détection trouve. Le gabarit couché s'appliquait alors à une
/// zone parcourue de travers — mesuré, « Altar of Blood » ressortait au rang 492
/// sur 1 035, quand le quart de tour la ramène **au rang 1, à 8 bits, avec une
/// marge de 9**.
///
/// **La réciproque a longtemps été refusée, et le refus se trompait de
/// conclusion.** L'argument était : un quadrilatère couché autour d'une carte
/// debout signale une détection fausse, et on n'échafaude pas d'hypothèse
/// dessus. Mesuré sur 36 photos réelles, **treize montrent un carton posé de
/// travers** : la prémisse est fausse, et aucune de ces treize n'était reconnue.
///
/// Mais l'argument avait raison sur le danger, et c'est ce qui fait la forme de
/// la règle. Chaque hypothèse est un tirage de plus dans l'index, avec environ
/// une chance sur cent de passer les deux garde-fous sur du bruit (mesuré,
/// `app.measure.art_collisions`). Or la lecture *telle quelle* — tour 0 d'un
/// gabarit droit dans un quadrilatère couché — est précisément celle qui a
/// produit les deux cartes annoncées à tort du banc réel. Elle est donc
/// **remplacée**, jamais ajoutée : sur ce banc, ouvrir les quatre sens rend 8
/// cartes justes et 2 inventées, n'ouvrir que les deux sens compatibles avec le
/// rapport en rend **8 et 1**, contre 3 et 2 auparavant.
///
/// **Le flux caméra garde sa propre règle**, plus fermée : il ne redresse que ce
/// que l'orientation de son capteur lui apprend, et rien n'a été mesuré sur un
/// flux réel pour justifier d'y ouvrir davantage. Voir `live_scanner.dart`.
Map<ArtHypothesis, ArtHash> artHashCandidatesInQuad(
  img.Image photo,
  CardQuad quad, {
  String game = 'magic',
}) {
  final quadIsUpright = quad.aspect <= 1;
  final candidates = <ArtHypothesis, ArtHash>{};

  for (final frame in CardFrame.values) {
    if (frame.game != game) continue;
    // Le gabarit et le quadrilatère pointent-ils dans le même sens ? Si oui la
    // carte est déjà lisible, au demi-tour près ; sinon il faut la redresser.
    final aligne = frame.landscape != quadIsUpright;
    for (final t in aligne ? const [0, 2] : const [1, 3]) {
      candidates[(frame: frame, quarterTurns: t)] = computeArtHash(
        sampleArt(photo, quad.quarterTurned(t), frame.box),
      );
    }
  }
  return candidates;
}
