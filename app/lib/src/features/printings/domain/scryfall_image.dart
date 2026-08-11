/// Les tailles d'image de Scryfall, déduites les unes des autres.
///
/// **Pourquoi déduire plutôt que stocker.** Le catalogue ne conserve que
/// `art_crop_url`, l'illustration recadrée. Afficher la carte entière demandait
/// soit une colonne de plus sur les 167 000 impressions et une réingestion
/// complète, soit une substitution — car les URL de Scryfall ne diffèrent que
/// par un segment de chemin :
///
/// ```
/// https://cards.scryfall.io/art_crop/front/e/0/e040b456-….jpg?1783902897
/// https://cards.scryfall.io/normal/front/e/0/e040b456-….jpg?1783902897
/// ```
///
/// Vérifié sur de vraies URL du catalogue : la seconde répond 200 et rend un
/// JPEG de 95 Ko. La substitution est donc retenue — elle ne coûte rien, ni en
/// stockage ni en réingestion.
///
/// **Le risque assumé** est que Scryfall change la forme de ses URL. Il ne rend
/// pas la situation pire : `art_crop_url` casserait du même coup, puisqu'il
/// vient de la même convention. Si cela arrive, la colonne dédiée redeviendra
/// la bonne réponse.
///
/// Le segment `front` est conservé tel quel : sur une carte recto-verso, le
/// catalogue pointe déjà la face qui porte l'illustration, et c'est celle-là
/// qu'on veut voir dans une case de classeur.
library;

/// Taille servie par le catalogue.
const String _artCrop = '/art_crop/';

/// Carte entière, cadre et texte compris — 488 × 680 chez Scryfall.
const String _normal = '/normal/';

/// La même carte en 146 × 204. Mesuré : **14 Ko contre 99,6 Ko**.
const String _small = '/small/';

/// L'image de la carte entière, à partir de celle de son illustration.
///
/// Rend `null` quand l'illustration est inconnue, et l'URL telle quelle si elle
/// ne suit pas la convention attendue : mieux vaut afficher l'illustration que
/// rien du tout.
String? fullCardImage(String? artCropUrl) {
  if (artCropUrl == null || artCropUrl.isEmpty) return null;
  if (!artCropUrl.contains(_artCrop)) return artCropUrl;
  return artCropUrl.replaceFirst(_artCrop, _normal);
}

/// La version légère de la même carte, ou `null` si l'URL n'en a pas.
///
/// **Ce qu'elle sert à faire : donner à voir tout de suite.** Une feuille de
/// classeur charge neuf cartes, une double page dix-huit ; à 99,6 Ko l'unité,
/// cela fait 1,8 Mo avant que la page ne veuille dire quoi que ce soit. La même
/// page en 146 × 204 pèse 126 Ko — sept fois moins — et suffit largement à
/// reconnaître ses propres cartes, ce qui est tout ce qu'on demande à une case
/// de classeur.
///
/// Elle ne remplace donc pas la grande : elle la précède. La petite s'affiche
/// dès qu'elle arrive, la grande se pose par-dessus quand elle est là, et le
/// surcoût de 14 Ko n'est payé qu'une fois — les deux tailles vont au cache.
String? previewCardImage(String? url) {
  if (url == null || url.isEmpty) return null;
  for (final size in const [_normal, _artCrop]) {
    if (url.contains(size)) return url.replaceFirst(size, _small);
  }
  return null;
}
