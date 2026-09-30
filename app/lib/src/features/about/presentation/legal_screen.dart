/// Informations légales : l'essentiel en quelques lignes, et les pages web qui
/// font foi.
///
/// **Un résumé, pas une copie.** La politique, les conditions et les mentions
/// vivent sur le web (`legal_links.dart`), à l'adresse que Google Play et la
/// loi désignent ; les recopier ici ferait deux versions qui divergeraient. Cet
/// écran dit ce qu'il faut savoir d'un coup d'œil et ouvre le reste.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/legal_links.dart';

class LegalScreen extends ConsumerWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = ref.read(externalLinkOpenerProvider);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    Widget lien(IconData icone, String titre, Uri adresse) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icone),
      title: Text(titre),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => open(adresse),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Informations légales')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'DeckHand garde votre adresse e-mail et votre collection pour vous '
            'les rendre sur tous vos appareils, et rien de plus : ni publicité, '
            'ni mesure d\'audience, ni revente. Les photos de vos cartes ne '
            'quittent pas le téléphone.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          Text(
            'Votre collection est privée tant que vous ne la publiez pas. Vous '
            'pouvez supprimer votre compte et tout ce qu\'il contient depuis '
            'l\'écran Compte.',
            style: muted,
          ),
          const SizedBox(height: 20),
          lien(Icons.privacy_tip_outlined, 'Politique de confidentialité',
              LegalLinks.privacy),
          lien(Icons.gavel_outlined, 'Conditions d\'utilisation',
              LegalLinks.terms),
          lien(Icons.badge_outlined, 'Mentions légales', LegalLinks.legalNotice),
          const SizedBox(height: 12),
          Text(
            'Une question sur vos données : heianenterpriseyt@gmail.com',
            style: muted,
          ),
        ],
      ),
    );
  }
}
