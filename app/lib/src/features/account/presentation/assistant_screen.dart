/// Brancher un assistant IA sur sa collection, et voir à qui on l'a confiée.
///
/// **Le « bouton » d'un serveur en ligne est une adresse.** Rien à installer :
/// l'utilisateur colle l'adresse du connecteur dans son assistant (claude.ai,
/// Claude Code…), qui ouvre alors la page de consentement de DeckHand. L'écran
/// donne donc l'adresse, un bouton pour la copier, et le geste exact pour les
/// deux clients les plus probables.
///
/// **La liste des accès accordés est la moitié de l'écran, pas un détail.**
/// Autoriser se fait hors de l'application, sur une page web ; sans cette
/// liste, l'utilisateur n'aurait aucun endroit où voir qui lit sa collection,
/// ni où le lui retirer. La politique de confidentialité renvoie ici.
///
/// **Ce que l'écran promet est ce que la base tient** : un assistant lit et
/// modifie les cartes, mais ne supprime pas le compte et ne publie pas le
/// classeur — refusé en base (`20261002100000_garde_assistant.sql`), pas
/// seulement absent des outils.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/legal_links.dart';
import '../../../common/settled_async.dart';
import '../../../common/state_message.dart';
import '../data/assistant_repository.dart';

/// L'entrée de l'écran, dans *Compte*.
class AssistantTile extends StatelessWidget {
  const AssistantTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.smart_toy_outlined),
      title: const Text('Brancher un assistant IA'),
      subtitle: const Text(
        'Claude ou un autre : lire la collection, proposer des decks, ranger des cartes',
      ),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const AssistantScreen())),
    );
  }
}

class AssistantScreen extends ConsumerWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final url = ref.watch(assistantRepositoryProvider).connectorUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Assistant IA')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Branchez un assistant IA — Claude, par exemple — sur votre collection. '
                  'À votre demande, il la lit, vous propose des decks, et ajoute ou retire '
                  'des cartes. Il ne peut ni supprimer votre compte, ni publier votre classeur.',
                ),
                const SizedBox(height: 28),
                Text(
                  'Adresse du connecteur',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                _Copiable(
                  texte: url,
                  libelle: "Copier l'adresse",
                  annonce: 'Adresse copiée',
                ),
                const SizedBox(height: 28),
                Text('Le brancher', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const Text(
                  'Assistants reconnus : Claude (web, Desktop, mobile et Claude Code), '
                  "ChatGPT, Cursor et VS Code. Un autre sera refusé au moment d'autoriser.",
                ),
                const SizedBox(height: 12),
                const Text(
                  'claude.ai (web et application) : Paramètres → Connecteurs → Ajouter un '
                  "connecteur personnalisé, puis collez l'adresse. Claude ouvre une page "
                  'DeckHand : connectez-vous, puis autorisez.',
                ),
                const SizedBox(height: 12),
                const Text('Claude Code :'),
                const SizedBox(height: 4),
                _Copiable(
                  texte: claudeCodeCommandFor(url),
                  libelle: 'Copier la commande',
                  annonce: 'Commande copiée',
                ),
                const SizedBox(height: 28),
                Text('Assistants autorisés', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const _Autorises(),
                const SizedBox(height: 8),
                Text(
                  "Retirer un accès empêche l'assistant de le renouveler ; celui qu'il "
                  "détient expire au plus tard dans l'heure.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => ref.read(externalLinkOpenerProvider)(
                      Uri.parse('$webBase/privacy.html#destinataires'),
                    ),
                    child: const Text("Ce que reçoit l'assistant"),
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

/// Un texte à recopier ailleurs, sélectionnable, avec son bouton.
class _Copiable extends StatelessWidget {
  const _Copiable({
    required this.texte,
    required this.libelle,
    required this.annonce,
  });

  final String texte;
  final String libelle;
  final String annonce;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(texte, style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: Text(libelle),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: texte));
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(annonce)));
          },
        ),
      ],
    );
  }
}

class _Autorises extends ConsumerWidget {
  const _Autorises();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(assistantGrantsProvider)
        .settled(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (error, _) => StateMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Liste indisponible',
            detail: '$error',
            onRetry: () => ref.invalidate(assistantGrantsProvider),
          ),
          data: (grants) {
            if (grants.isEmpty) {
              return const Text(
                "Aucun assistant n'a accès à votre collection.",
              );
            }
            return Column(
              children: [for (final grant in grants) _GrantTile(grant: grant)],
            );
          },
        );
  }
}

String _date(DateTime d) {
  final local = d.toLocal();
  String deux(int n) => n.toString().padLeft(2, '0');
  return '${deux(local.day)}/${deux(local.month)}/${local.year}';
}

class _GrantTile extends ConsumerStatefulWidget {
  const _GrantTile({required this.grant});

  final AssistantGrant grant;

  @override
  ConsumerState<_GrantTile> createState() => _GrantTileState();
}

class _GrantTileState extends ConsumerState<_GrantTile> {
  bool _enCours = false;

  Future<void> _revoquer() async {
    setState(() => _enCours = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(assistantRepositoryProvider).revoke(widget.grant.clientId);
      ref.invalidate(assistantGrantsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('Accès retiré à ${widget.grant.name}.')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      if (mounted) setState(() => _enCours = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grant = widget.grant;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.smart_toy_outlined),
      title: Text(grant.name),
      subtitle: grant.grantedAt == null
          ? null
          : Text('Autorisé le ${_date(grant.grantedAt!)}'),
      trailing: TextButton(
        onPressed: _enCours ? null : _revoquer,
        child: const Text('Révoquer'),
      ),
    );
  }
}
