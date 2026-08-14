/// Regroupement des classeurs par famille d'extension.
///
/// **Une sortie ne produit pas une extension mais une famille.** « Marvel Super
/// Heroes » en compte quatre : l'extension de boosters (`msh`, 453 cartes), les
/// decks Commander (`msc`, 866), et un jeu de jetons pour chacune (`tmsh`,
/// `tmsc`). L'étagère les présentait à plat, cinq classeurs en vrac pour une
/// seule sortie, sans que rien ne dise lequel dépendait duquel — alors que la
/// base porte la parenté depuis l'origine et ne la lisait nulle part.
///
/// **Ce que ce regroupement ne fait pas : fusionner.** Chaque extension garde
/// son classeur, et ce n'est pas un compromis. Les numérotations se chevauchent
/// — le n° 1 vaut « Agent 13, Sharon Carter » dans `msh`, « Invisible Woman »
/// dans `msc` et « Wall » dans `tmsh`. Trois cartes ne tiennent pas dans une
/// case, et c'est exactement ainsi qu'on range de vraies pochettes : un classeur
/// par édition, du n° 1 au dernier.
///
/// Exemple canonique :
///
///     for (final famille in groupIntoFamilies(shelf)) {
///       afficher(famille.head);                  // l'extension principale
///       for (final s in famille.satellites) {    // decks, jetons…
///         afficherEnRetrait(s);
///       }
///     }
library;

import 'binder.dart';

/// Une sortie et tout ce qu'elle a produit, tel qu'on le possède.
class BinderFamily {
  const BinderFamily({required this.head, required this.satellites});

  /// L'extension qui donne son nom à la famille.
  ///
  /// C'est la **racine possédée** de la chaîne de parenté, et non la mieux
  /// garnie : posséder trois cents jetons et dix cartes de l'extension ne fait
  /// pas des jetons la tête de famille.
  final BinderShelfEntry head;

  /// Ce qui dépend de [head], jouable d'abord, jetons ensuite.
  final List<BinderShelfEntry> satellites;

  /// Vrai quand la famille se réduit à une extension isolée.
  bool get isAlone => satellites.isEmpty;

  /// Tous les classeurs de la famille, tête comprise.
  List<BinderShelfEntry> get all => [head, ...satellites];
}

/// Regroupe [shelf] par famille, en conservant l'ordre des têtes.
///
/// L'ordre reçu est celui de la base — le classeur le plus rempli d'abord,
/// c'est celui qu'on vient regarder — et il est conservé : une famille ne
/// remonte pas l'étagère au motif qu'elle a beaucoup de satellites.
List<BinderFamily> groupIntoFamilies(List<BinderShelfEntry> shelf) {
  final byCode = {for (final entry in shelf) entry.setCode: entry};

  /// Racine **possédée** de la chaîne de parenté.
  ///
  /// On remonte tant que le parent figure dans l'étagère. Un satellite dont la
  /// mère n'est pas possédée devient donc sa propre tête, plutôt que de
  /// disparaître sous une extension absente — on peut très bien avoir des
  /// jetons sans avoir ouvert un seul booster.
  String rootOf(BinderShelfEntry entry) {
    var current = entry;
    final seen = <String>{current.setCode};
    while (true) {
      final parent = current.parentSetCode;
      if (parent == null || !byCode.containsKey(parent)) return current.setCode;
      // **Une parenté circulaire rend chacun à lui-même.** La source ne devrait
      // pas en produire, mais s'arrêter sur le maillon courant désignerait une
      // racine qui n'appartient pas à son propre groupe — et la tête de famille
      // resterait introuvable. Un test l'a montré en faisant planter l'écran.
      if (!seen.add(parent)) return entry.setCode;
      current = byCode[parent]!;
    }
  }

  final members = <String, List<BinderShelfEntry>>{};
  for (final entry in shelf) {
    members.putIfAbsent(rootOf(entry), () => []).add(entry);
  }

  final families = <BinderFamily>[];
  final done = <String>{};
  for (final entry in shelf) {
    final root = rootOf(entry);
    if (!done.add(root)) continue;
    final group = members[root]!;
    // `orElse` plutôt qu'une exception : une donnée de parenté inattendue doit
    // dégrader l'affichage, jamais l'empêcher.
    final head = group.firstWhere(
      (e) => e.setCode == root,
      orElse: () => group.first,
    );
    final satellites = group.where((e) => e.setCode != root).toList()
      // **Les jetons en dernier**, quel que soit leur remplissage : ce sont des
      // marqueurs, dont aucune carte n'est jouable dans un format construit.
      // Les laisser passer devant un deck Commander au seul motif qu'on en a
      // rangé davantage mettrait en tête ce qui compte le moins.
      ..sort((a, b) {
        if (a.isTokenSet != b.isTokenSet) return a.isTokenSet ? 1 : -1;
        final byCells = b.ownedCells.compareTo(a.ownedCells);
        return byCells != 0 ? byCells : a.setCode.compareTo(b.setCode);
      });
    families.add(BinderFamily(head: head, satellites: satellites));
  }
  return families;
}
