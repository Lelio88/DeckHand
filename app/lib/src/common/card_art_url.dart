/// Compose l'URL réellement téléchargeable d'une illustration.
///
/// **Toutes les sources ne servent pas l'URL qu'elles publient.** TCGdex publie
/// une base — `https://assets.tcgdex.net/en/pl/pl4/1` — et refuse de la servir
/// nue : elle rend un 404. Il faut lui adjoindre une qualité et un format,
/// `/high.png`. Les sept autres sources servent des URL complètes.
///
/// **Pourquoi la base est stockée telle quelle**, et non complétée à
/// l'ingestion : figer une qualité en base obligerait à réécrire les 20 964
/// lignes du catalogue pour en changer. La composition appartient donc à
/// l'usage — c'est la décision qu'`api/app/vision/index_builder.py` a prise
/// pour l'index d'empreintes, et ce module en est le jumeau côté application.
///
/// **Ce jumeau manquait, et cela se voyait sans se remarquer.** Aucune
/// illustration Pokémon ne s'affichait nulle part dans l'application — ni dans
/// la recherche, ni dans les classeurs, ni dans les aperçus — depuis
/// l'ingestion du jeu. Le symptôme était une vignette vide, c'est-à-dire
/// exactement ce qu'affiche une carte dont la source n'a pas encore répondu :
/// rien ne distinguait la panne de la lenteur. Il a fallu ouvrir Pokémon sur
/// l'appareil pour le voir.
///
/// `high.png` plutôt que `high.webp` : mesuré côté index, la compression avec
/// perte du WebP déplace l'empreinte de 0 à 2 bits. Ici l'écart ne coûterait
/// rien, mais garder le même chemin des deux côtés évite qu'une photo se
/// compare un jour à une référence encodée autrement.
library;

/// Qualité et format demandés à TCGdex.
const String _tcgdexQuality = '/high.png';

/// Hôte de la source Pokémon. Le test porte sur l'URL et non sur le jeu :
/// l'appelant ne connaît pas toujours le jeu de la carte qu'il affiche, alors
/// qu'il a toujours son URL.
const String _tcgdexHost = 'assets.tcgdex.net';

/// L'URL prête à être téléchargée.
///
/// Idempotente : une URL déjà complétée est rendue telle quelle, ce qui permet
/// de l'appeler sans savoir si elle l'a déjà été.
String cardArtUrl(String url) {
  if (!url.contains(_tcgdexHost)) return url;
  if (url.endsWith(_tcgdexQuality)) return url;
  // La source publie parfois une barre finale ; la doubler donnerait un 404.
  final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  return '$base$_tcgdexQuality';
}
