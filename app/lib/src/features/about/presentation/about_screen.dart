/// À propos : crédits, mentions légales et fraîcheur des données.
///
/// **Cet écran remplit une obligation, pas une coquetterie.** Scryfall et
/// TopDeck.gg conditionnent l'usage gratuit de leurs données à une attribution
/// visible. Jusqu'ici seul TopDeck.gg était crédité, en pied de la liste des
/// decks, et Scryfall — dont vient l'intégralité du catalogue — n'apparaissait
/// nulle part dans l'application.
///
/// La mention de contenu de fan n'est pas non plus décorative : les noms,
/// illustrations et symboles de Magic appartiennent à Wizards of the Coast, et
/// tout projet communautaire doit énoncer qu'il n'est ni officiel ni approuvé.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data_freshness_repository.dart';

/// Sources de données, avec ce qu'on leur doit.
const _credits = <({String name, String url, String role})>[
  (
    name: 'Scryfall',
    url: 'scryfall.com',
    role: 'Catalogue des cartes, noms français, légalités et prix',
  ),
  (
    name: 'TopDeck.gg',
    url: 'topdeck.gg',
    role: 'Decklists de tournoi, pour les trois jeux',
  ),
  (name: 'MTGJSON', url: 'mtgjson.com', role: 'Decks préconstruits officiels'),
  (
    name: 'Riftcodex',
    url: 'riftcodex.com',
    role: 'Catalogue des cartes Riftbound',
  ),
  // Riot n'est pas une source technique de DeckHand — son API Riftbound n'est
  // pas ouverte —, mais les illustrations affichées sont servies par son CDN et
  // les cartes sont sa propriété. Le crédit lui revient à ce titre.
  (
    name: 'Riot Games',
    url: 'riotgames.com',
    role: 'Riftbound, ses cartes et leurs illustrations',
  ),
  // Riftcodex ne cote rien : les prix Riftbound viennent d'ailleurs, et le
  // crédit doit suivre la donnée et non le chemin qui y mène.
  (
    name: 'TCGplayer, via TCGCSV',
    url: 'tcgcsv.com',
    role: 'Prix de marché des cartes Riftbound et Yu-Gi-Oh',
  ),
  // Le guide de l'API YGOPRODeck tient lieu de conditions, faute de CGU
  // publiées, et il demande explicitement le stockage local des données. Le
  // garde-fou §IV.9 s'applique : à défaut de règles écrites, celles de Scryfall,
  // dont l'attribution visible fait partie.
  (
    name: 'YGOPRODeck',
    url: 'ygoprodeck.com',
    role: 'Catalogue des cartes Yu-Gi-Oh, noms français et illustrations',
  ),
  // Konami est à Yu-Gi-Oh ce que Riot est à Riftbound : la source n'est pas
  // l'éditeur, mais les cartes et leurs illustrations lui appartiennent.
  (
    name: 'Konami',
    url: 'konami.com',
    role: 'Yu-Gi-Oh!, ses cartes et leurs illustrations',
  ),
  // **La conversion est une source comme une autre.** Les prix Riftbound sont
  // relevés en dollars ; l'euro affiché est une conversion au taux de référence
  // de la BCE, pas un prix de marché européen. Le taire ferait passer un chiffre
  // dérivé pour un chiffre relevé.
  (
    name: 'Banque centrale européenne',
    url: 'ecb.europa.eu',
    role: 'Taux de change quotidien dollar / euro',
  ),
];

/// Nom lisible de chaque source d'ingestion.
const _sourceLabels = <String, String>{
  'scryfall': 'Catalogue et prix',
  'art_hashes': 'Empreintes d\'illustrations',
  'topdeck': 'Decks de tournoi',
  'mtgjson': 'Précons Commander',
  'tcgcsv_prices': 'Prix Riftbound (convertis en euros)',
};

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final freshness = ref.watch(dataFreshnessProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('À propos')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Text('DeckHand', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  'Assistant de deckbuilding adossé à une collection physique.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 28),
                _SectionTitle('Sources de données'),
                Text(
                  'DeckHand n\'existe que grâce à ces services, qui ouvrent '
                  'gratuitement leurs données.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final credit in _credits) _Credit(credit: credit),

                const SizedBox(height: 24),
                _SectionTitle('Fraîcheur des données'),
                freshness.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                  error: (_, _) => Text(
                    'Indisponible pour le moment.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  data: (rows) => Column(
                    children: [
                      for (final row in rows) _FreshnessRow(status: row),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                _SectionTitle('Mentions'),
                Text(
                  'Contenu non officiel de fan. Non approuvé par Wizards of the '
                  'Coast. Certains éléments sont la propriété de Wizards of the '
                  'Coast LLC, filiale de Hasbro, Inc. DeckHand n\'est affilié ni '
                  'à Wizards of the Coast, ni à aucune des sources citées.\n\n'
                  'Projet personnel, sans finalité commerciale.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Credit extends StatelessWidget {
  const _Credit({required this.credit});

  final ({String name, String url, String role}) credit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(credit.name, style: theme.textTheme.titleSmall),
              Text(
                credit.url,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            credit.role,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FreshnessRow extends StatelessWidget {
  const _FreshnessRow({required this.status});

  final IngestionStatus status;

  /// Ancienneté en clair. Un nombre de jours parle plus qu'une date pour juger
  /// si un prix est encore d'actualité.
  String _age(DateTime? when) {
    if (when == null) return 'jamais';
    final days = DateTime.now().difference(when).inDays;
    if (days == 0) return 'aujourd\'hui';
    if (days == 1) return 'hier';
    return 'il y a $days jours';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _sourceLabels[status.source] ?? status.source,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text('${status.items} ', style: muted),
          SizedBox(
            width: 110,
            child: Text(
              _age(status.lastRun),
              textAlign: TextAlign.right,
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}
