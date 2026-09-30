/// Les actions du compte lui-même : Google lié ou non, informations légales,
/// suppression.
///
/// **Supprimer demande d'écrire SUPPRIMER.** Une collection se constitue en des
/// heures de saisie, carte par carte, et la suppression est immédiate et sans
/// retour : une confirmation d'un seul appui se franchit par réflexe. La même
/// épreuve que sur la page web de suppression.
///
/// **La liaison Google suit la session.** Lier ou délier met à jour les
/// identités de l'utilisateur, ce qui émet un changement d'état : la tuile
/// relit `sessionProvider` et se redessine d'elle-même.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../about/presentation/legal_screen.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/auth_error_message.dart';

/// Le mot à écrire pour confirmer la suppression du compte.
const String deleteConfirmationWord = 'SUPPRIMER';

/// Le compte Google : le lier, ou dire lequel est lié.
class GoogleLinkTile extends ConsumerStatefulWidget {
  const GoogleLinkTile({super.key});

  @override
  ConsumerState<GoogleLinkTile> createState() => _GoogleLinkTileState();
}

class _GoogleLinkTileState extends ConsumerState<GoogleLinkTile> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(authErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionProvider); // se redessine quand les identités changent
    final repository = ref.read(authRepositoryProvider);
    if (!repository.supportsGoogle) return const SizedBox.shrink();
    final link = repository.linkedGoogle;

    if (link == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.link),
        title: const Text('Lier mon compte Google'),
        subtitle: const Text('Pour vous connecter sans mot de passe'),
        enabled: !_busy,
        onTap: () => _run(repository.linkGoogle),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.verified_user_outlined),
      title: const Text('Compte Google lié'),
      subtitle: Text(link.email ?? 'Connexion avec Google active'),
      trailing: link.canUnlink
          ? TextButton(
              onPressed: _busy ? null : () => _run(repository.unlinkGoogle),
              child: const Text('Délier'),
            )
          : null,
    );
  }
}

/// Ouvre l'écran des informations légales.
class LegalTile extends StatelessWidget {
  const LegalTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.policy_outlined),
      title: const Text('Informations légales'),
      subtitle: const Text(
        'Confidentialité, conditions d\'utilisation, mentions légales',
      ),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const LegalScreen())),
    );
  }
}

/// Supprime le compte, après confirmation écrite.
class DeleteAccountTile extends ConsumerWidget {
  const DeleteAccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
      title: Text(
        'Supprimer mon compte',
        style: TextStyle(color: theme.colorScheme.error),
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const DeleteAccountDialog(),
      ),
    );
  }
}

class DeleteAccountDialog extends ConsumerStatefulWidget {
  const DeleteAccountDialog({super.key});

  @override
  ConsumerState<DeleteAccountDialog> createState() =>
      _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<DeleteAccountDialog> {
  final _word = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  bool get _confirmed => _word.text.trim() == deleteConfirmationWord;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).deleteAccount();
      // La session se ferme : l'aiguillage de `main.dart` affiche la
      // connexion. Il ne reste qu'à refermer la boîte.
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              '${authErrorMessage(e)} Si cela persiste, écrivez à '
              'heianenterpriseyt@gmail.com : la suppression sera faite à la main.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Supprimer mon compte ?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tout sera effacé immédiatement et définitivement : votre '
              'compte, votre collection, vos classeurs, votre journal, vos '
              'préférences et votre classeur partagé. Rien ne pourra être '
              'récupéré.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _word,
              enabled: !_busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Pour confirmer, écrivez $deleteConfirmationWord',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: _busy || !_confirmed ? null : _delete,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Supprimer définitivement'),
        ),
      ],
    );
  }
}
