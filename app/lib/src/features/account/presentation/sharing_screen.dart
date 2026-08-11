/// Choisir ce qu'on donne à lire, et sous quelle adresse.
///
/// **Un interrupteur seul publiait tout** — les deux jeux et tous les classeurs.
/// C'est rarement ce qu'on veut : on montre le classeur qu'on est en train de
/// remplir, pas l'inventaire complet. Cet écran ajoute donc deux choix que
/// l'interrupteur ne pouvait pas porter.
///
/// **La portée est une règle de la base, pas un filtre d'affichage.** Masquer
/// des classeurs ici laisserait un visiteur curieux interroger la collection
/// directement et tout voir. Ce que l'écran coche descend dans
/// `collections.shared_sets`, que la politique consulte ligne par ligne.
///
/// **L'adresse se dicte.** Un UUID ne se transmet ni à l'oral ni de mémoire ;
/// un nom, oui. Il reste facultatif — l'identifiant continue de fonctionner
/// pour les liens déjà donnés.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../binders/data/binder_repository.dart';
import '../../collection/data/collection_repository.dart';

/// Où vit la page publique. Le lien complet en découle.
const String shareBaseUrl = 'https://lelio88.github.io/DeckHand/';

String shareLinkFor(String address) => '$shareBaseUrl?c=$address';

class SharingScreen extends ConsumerWidget {
  const SharingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(publicationProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Partage')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: state.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Partage indisponible : $error'),
              ),
              data: (publication) {
                final id = publication.collectionId;
                if (id == null) return const SizedBox.shrink();
                return _Body(publication: publication, collectionId: id);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.publication, required this.collectionId});

  final Publication publication;
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = publication.isPublic;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: open,
          title: const Text('Donner mes classeurs à lire'),
          subtitle: Text(
            open
                ? 'N\'importe qui ayant l\'adresse voit ce que vous partagez.'
                : 'Vous seul voyez votre collection.',
            style: theme.textTheme.bodySmall,
          ),
          onChanged: (wanted) async {
            await ref
                .read(collectionRepositoryProvider)
                .publish(collectionId, isPublic: wanted);
            ref.invalidate(publicationProvider);
          },
        ),

        // **Rien de plus tant que rien n'est ouvert.** Régler l'adresse et la
        // portée d'un partage qui n'existe pas donnerait des réglages sans
        // effet, et un lien qui ne mène nulle part.
        if (open) ...[
          const SizedBox(height: 20),
          _Handle(publication: publication, collectionId: collectionId),
          const SizedBox(height: 24),
          Text('Ce que vous partagez', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Décochez un classeur et il devient invisible — y compris à qui '
            'connaîtrait son adresse.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          _Scope(publication: publication, collectionId: collectionId),
        ],
      ],
    );
  }
}

/// L'adresse : un nom qu'on choisit, et le lien qui se copie.
class _Handle extends ConsumerStatefulWidget {
  const _Handle({required this.publication, required this.collectionId});

  final Publication publication;
  final String collectionId;

  @override
  ConsumerState<_Handle> createState() => _HandleState();
}

class _HandleState extends ConsumerState<_Handle> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.publication.handle ?? '',
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Ce que la base accepte, vérifié avant de l'y envoyer : minuscules,
  /// chiffres et tirets, de 3 à 32 caractères. Refuser ici évite de traduire
  /// une violation de contrainte en message compréhensible.
  static final _shape = RegExp(r'^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$');

  Future<void> _save() async {
    final raw = _controller.text.trim().toLowerCase();
    final wanted = raw.isEmpty ? null : raw;

    if (wanted != null && !_shape.hasMatch(wanted)) {
      setState(() {
        _error = 'Minuscules, chiffres et tirets, entre 3 et 32 caractères.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(collectionRepositoryProvider)
          .setHandle(widget.collectionId, wanted);
      ref.invalidate(publicationProvider);
    } on Object {
      // La base a un index unique : c'est elle qui tranche, et le seul échec
      // qu'on sache nommer est celui-là.
      if (mounted) setState(() => _error = 'Ce nom est déjà pris.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = widget.publication.address;
    final link = address == null ? null : shareLinkFor(address);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Adresse', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                autocorrect: false,
                // **Une étiquette, pas un préfixe d'URL.** Le préfixe masquait
                // l'indication tant que le champ n'avait pas le focus : on
                // voyait un rectangle vide sans savoir quoi y mettre.
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Nom (facultatif)',
                  hintText: 'un-nom-a-vous',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _saving ? null : _save,
              child: const Text('Enregistrer'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.publication.handle == null
              ? 'Sans nom, c\'est l\'identifiant de la collection qui sert — '
                    'il fonctionne, mais ne se dicte pas.'
              : 'L\'identifiant continue de fonctionner pour les liens déjà '
                    'donnés.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (link != null) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              title: SelectableText(link, style: theme.textTheme.bodySmall),
              trailing: IconButton(
                tooltip: 'Copier le lien',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Lien copié')));
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Les classeurs, à cocher un à un.
class _Scope extends ConsumerWidget {
  const _Scope({required this.publication, required this.collectionId});

  final Publication publication;
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final shelf = ref.watch(binderShelfProvider);

    return shelf.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (error, _) => Text('Classeurs illisibles : $error'),
      data: (entries) {
        if (entries.isEmpty) {
          return Text(
            'Aucun classeur à partager pour l\'instant.',
            style: theme.textTheme.bodySmall,
          );
        }

        final shared = publication.sharedSets;
        final all = shared == null;

        Future<void> write(List<String>? sets) async {
          await ref
              .read(collectionRepositoryProvider)
              .setSharedSets(collectionId, sets);
          ref.invalidate(publicationProvider);
        }

        return Column(
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: all,
              title: const Text('Tous mes classeurs'),
              subtitle: Text(
                'Y compris ceux à venir : une extension ajoutée plus tard sera '
                'partagée sans rien avoir à faire.',
                style: theme.textTheme.bodySmall,
              ),
              // **Tout n'est pas la même chose que tout coché.** Cocher les
              // cinq classeurs d'aujourd'hui figerait la liste ; « tous » suit
              // la collection.
              onChanged: (wanted) => write(wanted == true ? null : <String>[]),
            ),
            const Divider(height: 8),
            for (final entry in entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: all || shared.contains(entry.setCode),
                enabled: !all,
                title: Text(entry.setName),
                subtitle: Text(
                  '${entry.setCode.toUpperCase()} · '
                  '${entry.ownedCells} / ${entry.totalCells} cases',
                  style: theme.textTheme.bodySmall,
                ),
                onChanged: all
                    ? null
                    : (wanted) {
                        final next = {...shared};
                        if (wanted == true) {
                          next.add(entry.setCode);
                        } else {
                          next.remove(entry.setCode);
                        }
                        unawaited(write(next.toList()..sort()));
                      },
              ),
          ],
        );
      },
    );
  }
}
