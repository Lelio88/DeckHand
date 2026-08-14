/// Écran de connexion et d'inscription.
///
/// Un seul écran pour les deux gestes : l'application vise un cercle restreint,
/// où l'inscription est un acte rare et la connexion la norme. Séparer en deux
/// écrans ajouterait une navigation pour rien.
///
/// **L'inscription demande deux fois le mot de passe, la connexion une seule.**
/// La différence n'est pas cosmétique : se connecter, c'est retaper un mot de
/// passe qu'on connaît, et le confirmer serait une friction sans contrepartie.
/// S'inscrire, c'est en inventer un — et une frappe de travers, sur une adresse
/// que rien ne vérifie, rendait jusqu'ici le compte irrécupérable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/auth_repository.dart';
import 'auth_shell.dart';
import 'forgot_password_screen.dart';
import 'reset_password_screen.dart' show minPasswordLength;

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _isRegistering = false;
  bool _obscured = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_isRegistering && _password.text != _confirm.text) {
      setState(() => _error = 'Les deux mots de passe ne correspondent pas.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final repository = ref.read(authRepositoryProvider);
    final email = _email.text.trim();
    final password = _password.text;

    try {
      if (_isRegistering) {
        await repository.signUp(email: email, password: password);
      } else {
        await repository.signIn(email: email, password: password);
      }
      // Pas de navigation ici : `sessionProvider` bascule l'application seul.
    } on AuthException catch (e) {
      // Le message de Supabase est en anglais et parfois cryptique ; on traduit
      // les cas courants et on garde le reste tel quel plutôt que de masquer une
      // cause qu'on n'a pas anticipée.
      setState(() => _error = _humanize(e.message));
    } catch (e) {
      setState(() => _error = 'Erreur inattendue : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanize(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('invalid login')) {
      return 'Adresse e-mail ou mot de passe incorrect.';
    }
    if (lower.contains('already registered') ||
        lower.contains('already exists')) {
      return 'Un compte existe déjà avec cette adresse.';
    }
    if (lower.contains('password')) {
      return 'Mot de passe refusé : il doit faire au moins '
          '$minPasswordLength caractères.';
    }
    return message;
  }

  void _toggleMode() {
    setState(() {
      _isRegistering = !_isRegistering;
      _error = null;
      _confirm.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      subtitle: _isRegistering
          ? 'Créez un compte pour enregistrer votre collection'
          : 'Connectez-vous pour retrouver votre collection',
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
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
              const SizedBox(height: 14),
              AuthPasswordField(
                controller: _password,
                label: 'Mot de passe',
                obscured: _obscured,
                onToggle: () => setState(() => _obscured = !_obscured),
                autofillHints: _isRegistering
                    ? const [AutofillHints.newPassword]
                    : const [AutofillHints.password],
                textInputAction: _isRegistering
                    ? TextInputAction.next
                    : TextInputAction.done,
                onSubmitted: _isRegistering ? null : (_) => _submit(),
                validator: (value) {
                  final v = value ?? '';
                  if (v.isEmpty) return 'Mot de passe requis';
                  if (_isRegistering && v.length < minPasswordLength) {
                    return 'Au moins $minPasswordLength caractères';
                  }
                  return null;
                },
              ),
              if (_isRegistering) ...[
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
            ],
          ),
        ),
        if (_error != null) AuthErrorText(message: _error!),
        const SizedBox(height: 24),
        AuthSubmitButton(
          label: _isRegistering ? 'Créer le compte' : 'Se connecter',
          busy: _busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _toggleMode,
          child: Text(
            _isRegistering ? 'J\'ai déjà un compte' : 'Créer un compte',
          ),
        ),
        // Seulement à la connexion : à l'inscription, il n'y a pas encore de
        // mot de passe à oublier.
        if (!_isRegistering)
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ForgotPasswordScreen(),
                    ),
                  ),
            child: const Text('Mot de passe oublié ?'),
          ),
      ],
    );
  }
}
