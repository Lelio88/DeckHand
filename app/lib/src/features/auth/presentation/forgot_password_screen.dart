/// Demande d'un lien de réinitialisation.
///
/// **La réponse ne dit jamais si l'adresse a un compte.** Supabase répond de la
/// même façon dans les deux cas, et cet écran tient le même silence : distinguer
/// « lien envoyé » de « adresse inconnue » en ferait un test d'existence de
/// compte à la portée de n'importe qui. Le message est donc conditionnel — « si
/// un compte existe pour cette adresse » — et il s'affiche même quand rien n'est
/// parti.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/auth_repository.dart';
import 'auth_shell.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();

  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(authRepositoryProvider)
          .sendPasswordReset(_email.text.trim());
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      // Le débit est la seule erreur qu'on ait à dire ici : tout le reste
      // révélerait quelque chose sur l'adresse saisie.
      final lower = e.message.toLowerCase();
      final message = lower.contains('rate') || lower.contains('too many')
          ? 'Trop de demandes. Patientez quelques minutes.'
          : 'Envoi impossible pour le moment. Réessayez.';
      if (mounted) setState(() => _error = message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Envoi impossible pour le moment. Réessayez.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_sent) {
      return AuthShell(
        subtitle: 'Vérifiez votre boîte de réception.',
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: 44,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Si un compte existe pour cette adresse, vous allez recevoir un '
            'lien pour choisir un nouveau mot de passe. Il ouvre DeckHand '
            'directement.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          AuthSubmitButton(
            label: 'Retour',
            busy: false,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
    }

    return AuthShell(
      subtitle: 'Entrez votre adresse, nous envoyons un lien.',
      children: [
        Form(
          key: _formKey,
          child: TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Adresse e-mail',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = (value ?? '').trim();
              if (v.isEmpty) return 'Adresse requise';
              if (!v.contains('@') || !v.contains('.')) {
                return 'Adresse invalide';
              }
              return null;
            },
          ),
        ),
        if (_error != null) AuthErrorText(message: _error!),
        const SizedBox(height: 24),
        AuthSubmitButton(
          label: 'Envoyer le lien',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Retour à la connexion'),
        ),
      ],
    );
  }
}
