/// Le bandeau qui ne parle qu'en cas d'ennui (#8).
///
/// **Ce qu'il remplace, et pourquoi.** Le relevé de passe s'affichait en
/// permanence, en travers du retour vidéo : on le voyait quand il n'avait rien
/// à dire, et il masquait la carte qu'on était en train de filmer. Or ses
/// chiffres ne servent qu'à une chose — trancher entre trois pannes qui ne se
/// corrigent pas au même endroit. Le reste du temps, ils occupent l'écran.
///
/// Il monte donc en haut de l'aperçu, en surimpression, et **ne s'affiche que
/// lorsque la passe bloque** — ce que [ScanTally.stuckOn] décide, en refusant
/// de conclure sur une passe trop jeune ou qui a déjà retenu une carte.
///
/// **Le conseil d'abord, les chiffres ensuite.** « sans carte 96 % » demande de
/// savoir ce qu'est une carte sans carte ; « la carte n'est pas repérée »
/// suivi de « recadrez, ou changez de fond » se lit d'un coup d'œil, sur un
/// téléphone tenu au-dessus d'une table. Le relevé chiffré reste sous le
/// conseil, en petit : c'est lui qu'on relit au poste de travail, et une passe
/// de terrain qu'on ne peut pas relire est une passe perdue.
library;

import 'package:flutter/material.dart';

import '../domain/live_scanner.dart';
import '../domain/scan_tally.dart';

/// Ce qu'il faut faire, pour chacune des trois pannes.
///
/// La table est celle de `scan_tally.dart`, traduite en gestes. Elle vit ici et
/// non dans le domaine : le domaine sait *ce qui* échoue, l'écran sait comment
/// le dire.
({String title, String advice}) adviceFor(FrameOutcome outcome) =>
    switch (outcome) {
      FrameOutcome.notFound => (
        title: 'La carte n\'est pas repérée',
        advice: 'Approchez, posez-la à plat, ou changez de fond.',
      ),
      FrameOutcome.silent => (
        title: 'Illustration inconnue',
        advice: 'Vérifiez le jeu sélectionné.',
      ),
      FrameOutcome.unsure => (
        title: 'Deux cartes se ressemblent trop',
        advice: 'Stabilisez l\'appareil : la marge de confiance protège.',
      ),
      // Une passe qui reconnaît ne bloque sur rien ; `stuckOn` ne rend jamais
      // cette valeur, et ce cas n'existe que pour l'exhaustivité du filtrage.
      FrameOutcome.confident => (title: '', advice: ''),
    };

class ScanTroubleBar extends StatelessWidget {
  const ScanTroubleBar({super.key, required this.tally, required this.onReset});

  final ScanTally tally;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final stuck = tally.stuckOn;
    if (stuck == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final (:title, :advice) = adviceFor(stuck);
    return Container(
      width: double.infinity,
      // Assez opaque pour rester lisible sur n'importe quelle image, assez
      // sombre pour ne pas éblouir dans une pièce peu éclairée.
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  advice,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tally.describe(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Repartir de zéro pour la passe suivante',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: onReset,
          ),
        ],
      ),
    );
  }
}
