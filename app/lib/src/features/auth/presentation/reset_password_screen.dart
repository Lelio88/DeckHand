/// Choix du nouveau mot de passe, après qu'un lien a rouvert l'application.
///
/// `supabase_flutter` a déjà ouvert une session temporaire quand cet écran
/// s'affiche : le remplacement est donc autorisé sans redemander l'ancien mot de
/// passe, que l'utilisateur ne connaît par définition pas.
///
/// **Il n'y a pas de bouton « annuler ».** La session de récupération ne donne
/// accès à rien d'autre, et refermer l'écran laisserait l'utilisateur dans une
/// application à moitié ouverte, sans mot de passe utilisable. Le seul chemin
/// est d'en choisir un.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import 'auth_error_message.dart';
import 'auth_shell.dart';
import 'password_rules.dart';

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _obscured = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_password.text != _confirm.text) {
      setState(() => _error = 'Les deux mots de passe ne correspondent pas.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref.read(authRepositoryProvider).updatePassword(_password.text);
      if (!mounted) return;
      // Referme le mode récupération : la session redevient ordinaire, et
      // l'application reprend son cours à l'écran d'accueil.
      ref.read(passwordRecoveryProvider.notifier).clear();
    } on Object catch (e) {
      // Un mot de passe trop faible, un lien expiré ou une panne réseau ont
      // chacun leur message ; le texte brut du serveur n'est jamais montré.
      if (mounted) setState(() => _error = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      subtitle: 'Choisissez un nouveau mot de passe.',
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthPasswordField(
                controller: _password,
                label: 'Nouveau mot de passe',
                obscured: _obscured,
                onToggle: () => setState(() => _obscured = !_obscured),
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
                validator: (value) => passwordRuleError(value ?? ''),
              ),
              const SizedBox(height: 14),
              AuthPasswordField(
                controller: _confirm,
                label: 'Confirmez le mot de passe',
                obscured: _obscured,
                onToggle: () => setState(() => _obscured = !_obscured),
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                validator: (value) {
                  if ((value ?? '').isEmpty) return 'Confirmation requise';
                  return null;
                },
              ),
            ],
          ),
        ),
        if (_error != null) AuthErrorText(message: _error!),
        const SizedBox(height: 24),
        AuthSubmitButton(
          label: 'Changer le mot de passe',
          busy: _busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
