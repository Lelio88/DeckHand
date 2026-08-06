/// Écran de connexion et d'inscription.
///
/// Un seul écran pour les deux gestes : l'application vise un cercle restreint,
/// où l'inscription est un acte rare et la connexion la norme. Séparer en deux
/// écrans ajouterait une navigation pour rien.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/auth_repository.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _isRegistering = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

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
      return 'Mot de passe refusé : il doit faire au moins 8 caractères.';
    }
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('DeckHand', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    _isRegistering
                        ? 'Créez un compte pour enregistrer votre collection'
                        : 'Connectez-vous pour retrouver votre collection',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
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
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final v = value ?? '';
                      if (v.isEmpty) return 'Mot de passe requis';
                      // Le minimum est fixé à 8 côté projet Supabase ; le
                      // vérifier ici évite un aller-retour réseau pour rien.
                      if (_isRegistering && v.length < 8) {
                        return 'Au moins 8 caractères';
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _isRegistering ? 'Créer le compte' : 'Se connecter',
                          ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _isRegistering = !_isRegistering;
                            _error = null;
                          }),
                    child: Text(
                      _isRegistering
                          ? 'J\'ai déjà un compte'
                          : 'Créer un compte',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
