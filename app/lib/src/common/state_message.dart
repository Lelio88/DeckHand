/// Ce qu'un écran affiche à la place de son contenu : vide, panne, ou rien
/// trouvé.
///
/// **Un seul dispositif pour toute l'application.** Le classeur s'était doté
/// d'une icône, d'un titre, d'un détail et d'un bouton « Réessayer » ; les
/// autres écrans se contentaient d'une ligne de texte au milieu de la page.
/// La différence n'était pas un choix : elle tenait à l'ordre dans lequel les
/// écrans ont été écrits. Or c'est l'écran le plus démuni qui a le plus besoin
/// du bouton — l'onglet Collection tombait sur « Collection illisible : … »
/// sans aucun recours, alors qu'une expiration de vingt secondes suffit à l'y
/// mener et que changer d'onglet ne rejoue rien.
///
/// **Le bouton n'apparaît que s'il y a quelque chose à refaire.** Une étagère
/// vide n'est pas une panne : proposer d'y « réessayer » laisserait croire que
/// l'application a échoué là où elle décrit simplement l'état des choses.
///
/// Usage canonique :
///
/// ```dart
/// StateMessage(
///   icon: Icons.cloud_off,
///   title: 'Collection illisible',
///   detail: '$error',
///   onRetry: () => ref.invalidate(collectionProvider),
/// )
/// ```
library;

import 'package:flutter/material.dart';

class StateMessage extends StatelessWidget {
  const StateMessage({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;

  /// Ce qu'il faut refaire pour s'en sortir, quand il y a quelque chose à
  /// refaire. **Une panne de réseau n'est pas un état définitif** : sans ce
  /// bouton, il ne resterait qu'à quitter l'application pour retenter.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Réessayer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
