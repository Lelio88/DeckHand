/// Chercheurs partagés par les tests d'écran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// La ligne de menu qui porte [label].
///
/// **Viser le texte d'une ligne cochée fait avertir l'outil de test.**
/// `CheckedPopupMenuItem` enveloppe son contenu dans un `IgnorePointer` : c'est
/// la ligne entière qui reçoit l'appui. Taper sur le texte atteint bien la
/// ligne, mais le texte visé n'est pas ce qui reçoit le geste, et chaque appui
/// l'écrit dans la sortie. Viser la ligne dit exactement ce que fait le doigt.
Finder menuItem(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<PopupMenuItem<Object?>>(),
);
