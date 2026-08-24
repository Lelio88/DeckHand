/// Où l'index d'empreintes est conservé, selon la plateforme.
///
/// Un fichier là où `dart:io` existe, `localStorage` sur le web. Le choix se
/// fait à la compilation ; le reste de l'application ne connaît que les trois
/// fonctions exportées ici. Voir `art_index_store_io.dart` pour le pourquoi du
/// fichier, et `art_index_store_web.dart` pour ce que le web ne peut pas faire.
library;

export 'art_index_store_web.dart'
    if (dart.library.io) 'art_index_store_io.dart';
