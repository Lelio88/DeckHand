/// Écran de connexion et d'inscription.
///
/// Un seul écran pour les deux gestes : l'application vise un cercle restreint,
/// où l'inscription est un acte rare et la connexion la norme. Séparer en deux
/// écrans ajouterait une navigation pour rien.
///
/// **L'inscription demande deux fois le mot de passe, la connexion une seule.**
/// La différence n'est pas cosmétique : se connecter, c'est retaper un mot de
/// passe qu'on connaît, et le confirmer serait une friction sans contrepartie.
/// S'inscrire, c'est en inventer un.
///
/// **L'inscription ne dit jamais qu'une adresse est prise.** Qu'elle soit neuve
/// ou déjà inscrite, la réponse est le même écran « Vérifiez vos e-mails », qui
/// rappelle la connexion et « Mot de passe oublié ? » au titulaire d'un compte
/// existant (`blindSignUp`). Les erreurs passent par [authErrorMessage] : un
/// mauvais mot de passe et une adresse inconnue s'y confondent.
///
/// **« Continuer avec Google »** n'apparaît que là où le sélecteur natif existe
/// (Android). La mention sous les boutons vaut pour les deux chemins, puisque
/// Google crée aussi un compte à la première connexion.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../common/legal_links.dart';
import '../data/auth_repository.dart';
import 'auth_error_message.dart';
import 'auth_shell.dart';
import 'forgot_password_screen.dart';
import 'password_rules.dart';

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

  /// L'adresse à laquelle un lien de confirmation a (peut-être) été envoyé.
  /// Non nulle, elle remplace le formulaire par l'écran d'attente.
  String? _pendingEmail;

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

    final repository = ref.read(authRepositoryProvider);
    final email = _email.text.trim();
    final password = _password.text;

    await _run(() async {
      if (_isRegistering) {
        final pending = await repository.signUp(
          email: email,
          password: password,
        );
        if (pending && mounted) setState(() => _pendingEmail = email);
      } else {
        await repository.signIn(email: email, password: password);
      }
      // Pas de navigation ici : `sessionProvider` bascule l'application seul.
    });
  }

  Future<void> _signInWithGoogle() =>
      _run(() => ref.read(authRepositoryProvider).signInWithGoogle());

  /// Joue [action] en affichant l'attente, et traduit son échec.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => _error = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleMode() {
    setState(() {
      _isRegistering = !_isRegistering;
      _error = null;
      _confirm.clear();
    });
  }

  void _backToSignIn() {
    setState(() {
      _pendingEmail = null;
      _isRegistering = false;
      _password.clear();
      _confirm.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingEmail;
    if (pending != null) {
      return AuthShell(
        subtitle: 'Vérifiez vos e-mails',
        children: [
          _ConfirmationPending(email: pending),
          const SizedBox(height: 24),
          AuthSubmitButton(
            label: 'Revenir à la connexion',
            busy: false,
            onPressed: _backToSignIn,
          ),
        ],
      );
    }

    final supportsGoogle = ref.read(authRepositoryProvider).supportsGoogle;

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
                  // La règle ne vaut qu'à l'inscription : un compte ancien
                  // peut avoir un mot de passe d'avant la règle, et doit
                  // pouvoir encore se connecter.
                  return _isRegistering ? passwordRuleError(v) : null;
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
        if (supportsGoogle) ...[
          const _Or(),
          _GoogleButton(onPressed: _busy ? null : _signInWithGoogle),
        ],
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
        const SizedBox(height: 12),
        const _Notice(),
      ],
    );
  }
}

/// Ce qu'on dit après une inscription — que l'adresse soit neuve ou non.
class _ConfirmationPending extends StatelessWidget {
  const _ConfirmationPending({required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Si l\'adresse $email peut être utilisée, un lien de confirmation '
          'vient d\'y être envoyé. Ouvrez-le sur ce téléphone : DeckHand '
          's\'ouvrira, connecté.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 12),
        Text(
          'Ouvert ailleurs, le lien confirme quand même l\'adresse : '
          'connectez-vous ensuite ici. Rien reçu ? Regardez dans les '
          'indésirables, ou recommencez dans quelques minutes.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Text(
          'Vous avez déjà un compte avec cette adresse ? Connectez-vous, ou '
          'utilisez « Mot de passe oublié ? ».',
          style: muted,
        ),
      ],
    );
  }
}

class _Or extends StatelessWidget {
  const _Or();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'ou',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Le « G » de Google, en couleurs, tel que ses consignes de marque le
/// demandent sur un bouton de connexion. Dessiné plutôt qu'embarqué : aucun
/// fichier de plus dans les ressources.
const String _googleG =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">'
    '<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>'
    '<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>'
    '<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>'
    '<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>'
    '</svg>';

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      icon: SvgPicture.string(
        _googleG,
        width: 18,
        height: 18,
        excludeFromSemantics: true,
      ),
      label: const Text('Continuer avec Google'),
    );
  }
}

/// La mention d'information : ce qu'on accepte en continuant, et où lire le
/// reste (guide de conformité, A4). Pas de case à cocher : le compte relève du
/// contrat, pas du consentement.
class _Notice extends ConsumerWidget {
  const _Notice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = ref.read(externalLinkOpenerProvider);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final link = TextButton.styleFrom(
      textStyle: theme.textTheme.bodySmall,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(48, 32),
    );
    return Column(
      children: [
        Text(
          'En continuant, vous acceptez les conditions d\'utilisation. '
          'DeckHand garde votre adresse et votre collection pour vous les '
          'rendre sur tous vos appareils.',
          textAlign: TextAlign.center,
          style: small,
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              style: link,
              onPressed: () => open(LegalLinks.terms),
              child: const Text('Conditions d\'utilisation'),
            ),
            TextButton(
              style: link,
              onPressed: () => open(LegalLinks.privacy),
              child: const Text('Confidentialité'),
            ),
          ],
        ),
      ],
    );
  }
}
