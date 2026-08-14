/// La coquille commune aux trois écrans d'authentification.
///
/// **Pourquoi l'extraire plutôt que la recopier.** Connexion, oubli et nouveau
/// mot de passe sont trois écrans du même moment : ils doivent se ressembler au
/// pixel, sans quoi passer de l'un à l'autre donne l'impression de changer
/// d'application. Recopiée trois fois, la mise en page aurait divergé au premier
/// ajustement — c'est exactement ce que `ui_coherence_test` a constaté ailleurs
/// dans le dépôt, où chaque écran avait réinventé sa réponse à une question déjà
/// tranchée.
///
/// La DA vient du thème et de nulle part ailleurs : `colorScheme`, `textTheme`,
/// et la largeur de 400 déjà retenue par l'écran de connexion. Aucune couleur
/// n'est écrite en dur ici, hormis celle de l'erreur, qui vient elle aussi du
/// thème (`colorScheme.error`).
///
/// Exemple :
///
/// ```dart
/// AuthShell(
///   subtitle: 'Entrez votre adresse, nous envoyons un lien.',
///   children: [ ...champs..., AuthErrorText(message: erreur) ],
/// )
/// ```
library;

import 'package:flutter/material.dart';

class AuthShell extends StatelessWidget {
  const AuthShell({super.key, required this.subtitle, required this.children});

  /// La phrase sous le nom : ce que cet écran-ci attend de l'utilisateur.
  final String subtitle;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('DeckHand', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le message d'erreur, dit de la même façon sur les trois écrans.
class AuthErrorText extends StatelessWidget {
  const AuthErrorText({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

/// Le bouton d'action principal, avec son état d'attente.
///
/// La roue remplace le libellé plutôt que de s'y ajouter : elle occupe la même
/// place, donc le bouton ne change pas de taille au moment où on le presse.
class AuthSubmitButton extends StatelessWidget {
  const AuthSubmitButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

/// Un champ de mot de passe, avec l'œil qui le montre.
///
/// **L'œil n'est pas un ornement.** Un mot de passe tapé à l'aveugle et confirmé
/// à l'aveugle laisse passer la même faute deux fois — la confirmation ne
/// rattrape que les fautes qu'on ne refait pas. Pouvoir relire ce qu'on a tapé
/// est ce qui ferme réellement la trappe.
class AuthPasswordField extends StatelessWidget {
  const AuthPasswordField({
    super.key,
    required this.controller,
    required this.label,
    required this.obscured,
    required this.onToggle,
    this.autofillHints,
    this.textInputAction,
    this.onSubmitted,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final bool obscured;
  final VoidCallback onToggle;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscured,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscured ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          ),
          tooltip: obscured
              ? 'Afficher le mot de passe'
              : 'Masquer le mot de passe',
        ),
      ),
    );
  }
}
