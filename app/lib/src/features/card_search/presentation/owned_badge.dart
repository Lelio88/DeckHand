/// La pastille « Déjà N » : ce qu'on possède avant d'en ajouter un de plus.
///
/// **Extraite parce qu'elle est un mot du lexique, pas un ornement.** Le
/// tableau ci-dessous distingue trois formes de comptage employées dans toute
/// l'application ; le laisser dans l'écran de recherche condamnait le scan
/// photo à en recopier une quatrième, ou à choisir un mot au hasard.
library;

import 'package:flutter/material.dart';

/// « Déjà 3 » — ce qu'on possède, mis en avant plutôt que dans un coin.
///
/// C'est l'information qui évite de saisir deux fois la même carte quand on
/// remplit sa collection en plusieurs séances.
/// Combien d'exemplaires on possède déjà, avant d'en ajouter un.
///
/// **Trois formes, trois sens** — c'est le lexique du comptage dans toute
/// l'application, et il vaut mieux qu'un mot unique employé au hasard :
///
/// | Forme | Sens | Où |
/// |---|---|---|
/// | « Déjà N » | stock **avant** l'ajout, donc un avertissement anti-doublon | recherche, sélecteur d'édition |
/// | « ×N » | compte compact **posé sur une image**, faute de place pour un mot | case de classeur, résultat de recherche d'étagère |
/// | « N exemplaires » | la même chose en toutes lettres, quand la ligne a la place | feuille d'action d'une case |
///
/// « Déjà » n'est donc pas une graphie interchangeable des deux autres : il
/// dit *quand* on regarde le nombre, pas seulement lequel. Le lire ailleurs
/// qu'avant un ajout serait une faute.
class OwnedBadge extends StatelessWidget {
  const OwnedBadge({super.key, required this.quantity, this.dense = false});

  final int quantity;

  /// Le meme mot, sans le fond ni l'icone.
  ///
  /// **Mesure, pas preference.** La pastille pleine occupe 117,5 px ; la ligne
  /// d'un scan d'etalement porte deja une case a cocher et trois commandes de
  /// quantite, et n'en laisse que 58 sur un ecran de 320. La forme dense en
  /// prend 45. Le mot reste « Deja N » — c'est lui qui porte le sens, pas le
  /// fond colore, et en inventer un quatrieme pour cette ligne-la reviendrait a
  /// defaire le tableau ci-dessus.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (dense) {
      return Text(
        'Déjà $quantity',
        // Elle cède plutôt que de déborder : posée sur une ligne déjà chargée,
        // elle doit pouvoir s'élider sur un écran minuscule. Le nom de la carte
        // passe avant — il identifie, le compte informe.
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 13,
            color: theme.colorScheme.onPrimary,
          ),
          const SizedBox(width: 4),
          Text(
            'Déjà $quantity',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
