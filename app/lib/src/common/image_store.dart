/// Conservation des images de cartes sur l'appareil.
///
/// **Pourquoi un cache, et pourquoi celui-ci.** Les images de cartes venaient
/// de Scryfall à chaque affichage, sans autre mémoire que l'`ImageCache` de
/// Flutter — mille entrées, cent mégaoctets, **vidé à la fermeture**. Une
/// feuille de classeur, c'est neuf cartes plus les deux feuilles voisines
/// préchargées : vingt-sept images retéléchargées à chaque démarrage à froid,
/// pour un classeur qu'on rouvre tous les jours sur les mêmes pages.
///
/// **Les commiter en assets est interdit** (garde-fou §IV.10 : le dépôt est
/// public, et ces illustrations appartiennent à Wizards of the Coast). Le cache
/// sur l'appareil est la seule voie ouverte — et c'est exactement ce que fait
/// déjà `art_index_cache.dart` pour l'index d'empreintes.
///
/// **Zéro dépendance ajoutée, et c'est une contrainte, pas un hasard.** Le
/// remède habituel — `cached_network_image` — tire `flutter_cache_manager`,
/// `sqflite` et `path_provider`, soit deux greffons natifs de plus : il
/// augmenterait la volatilité de build qu'on cherche à réduire. On se contente
/// donc de `dart:io` et de `Directory.systemTemp`, que l'embarqueur Flutter
/// fait pointer sur le répertoire de cache privé de l'application (purgeable
/// par le système sous pression de stockage — ce qui est précisément la
/// sémantique voulue pour un cache).
///
/// **Le web n'en a pas besoin** : le cache HTTP du navigateur fait déjà le
/// travail, et `dart:io` n'y existe pas. L'implémentation web est donc une
/// coquille vide, choisie à la compilation.
///
/// Tout y est **best-effort** : un cache illisible, un disque plein ou un
/// répertoire interdit dégradent vers le téléchargement, jamais vers une
/// exception. Une image est un ornement ; elle ne doit pas pouvoir faire
/// tomber l'écran qui la porte.
library;

export 'image_store_web.dart' if (dart.library.io) 'image_store_io.dart';
