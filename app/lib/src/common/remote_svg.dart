/// Charger un SVG distant sans jamais faire tomber l'écran qui l'affiche.
///
/// **Ce que le réseau renvoie n'est pas toujours un SVG.** `SvgNetworkLoader`
/// ne regarde ni le code HTTP ni le type de contenu, et son `provideSvg`
/// déréférence sans garde : une URL morte — Scryfall répond alors 27 Ko de page
/// HTML — ou un portail captif suffisent à faire lever « Invalid SVG data » au
/// décodeur. L'exception naît dans un `compute`, hors de l'arbre, là où
/// l'`errorBuilder` du widget ne la voit jamais : elle remonte donc jusqu'à la
/// zone et emporte l'écran pour un ornement.
///
/// Le remède est pris à la source : l'échec réseau et le contenu qui n'est pas
/// du SVG rendent tous deux un SVG **valide et vide**, que le décodeur accepte
/// et qui ne dessine rien.
///
/// **Pourquoi le réseau plutôt que des fichiers embarqués.** Les symboles de
/// Magic — de mana comme d'extension — sont la propriété de Wizards of the
/// Coast ; Scryfall les sert au titre de la Fan Content Policy. Les commiter
/// dans un dépôt public reviendrait à les redistribuer, ce que le projet
/// s'interdit pour toute donnée venue d'une source. Rien ne l'impose d'ailleurs :
/// Scryfall documente que ses origines de fichiers `*.scryfall.io` n'ont
/// **aucune limite de débit**.
///
/// Usage canonique :
///
/// ```dart
/// SvgPicture(
///   SafeSvgLoader(manaSymbolUrl('W')),
///   placeholderBuilder: (_) => const SizedBox.shrink(),
/// )
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// L'URL du symbole de mana officiel d'une couleur.
///
/// Déductible du symbole, et vérifié sur la totalité des cas qui nous
/// concernent : l'endpoint `symbology` de Scryfall sert `W`, `U`, `B`, `R`,
/// `G` et `C` sous `card-symbols/<symbole>.svg`. C'est l'inverse des symboles
/// d'**extension**, dont l'URL ne se déduit pas et exige la table `card_sets`.
///
/// Le fichier porte le disque coloré complet, pictogramme compris : il remplace
/// la pastille, il ne se pose pas dessus.
String manaSymbolUrl(String symbol) =>
    'https://svgs.scryfall.io/card-symbols/$symbol.svg';

/// Un chargeur de SVG distant qui ne peut pas faire tomber l'écran.
class SafeSvgLoader extends SvgNetworkLoader {
  const SafeSvgLoader(super.url);

  /// Un SVG valide qui ne dessine rien.
  static const String _nothing =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>';

  @override
  Future<Uint8List?> prepareMessage(BuildContext? context) async {
    try {
      return await super.prepareMessage(context);
    } on Exception {
      // Réseau coupé, hôte injoignable, TLS refusé : il n'y a rien à montrer,
      // et rien à dire non plus — ces symboles sont décoratifs.
      return null;
    }
  }

  @override
  String provideSvg(Uint8List? message) {
    if (message == null || message.isEmpty) return _nothing;
    final text = utf8.decode(message, allowMalformed: true);
    return text.contains('<svg') ? text : _nothing;
  }
}
