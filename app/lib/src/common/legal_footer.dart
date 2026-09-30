/// Les liens légaux du pied de page public : mentions légales et confidentialité.
///
/// **Toute page vue par des inconnus les porte** (LCEN pour les mentions,
/// RGPD pour la politique) — c'est la même exigence que l'attribution des
/// sources (§IV.2), et ils vivent au même endroit qu'elle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'legal_links.dart';

class LegalFooterLinks extends ConsumerWidget {
  const LegalFooterLinks({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = ref.read(externalLinkOpenerProvider);
    final style = TextButton.styleFrom(
      textStyle: theme.textTheme.bodySmall,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(48, 32),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        TextButton(
          style: style,
          onPressed: () => open(LegalLinks.legalNotice),
          child: const Text('Mentions légales'),
        ),
        TextButton(
          style: style,
          onPressed: () => open(LegalLinks.privacy),
          child: const Text('Confidentialité'),
        ),
      ],
    );
  }
}
