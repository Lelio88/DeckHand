/// L'intro, et ce qu'elle recouvre.
///
/// **Elle empile, elle n'aiguille pas.** [child] — l'accueil — est monté dès le
/// premier frame, *sous* l'animation. Ses requêtes partent donc pendant qu'elle
/// joue : le résumé de collection, l'étagère et les suggestions de decks sont
/// déjà en vol quand l'écran se découvre, et les illustrations de la première
/// feuille avec eux.
///
/// C'est tout l'intérêt, et c'est mesuré. Le premier appel d'une session froide
/// coûte jusqu'à 7,4 s — le serveur n'a que 224 Mio de cache pour 742 Mo de
/// base, et aucune réécriture de requête ne raccourcit ce moment. Les 2,2 s de
/// l'intro en sont retranchées au lieu de s'y ajouter. Un `if/else` qui
/// n'aurait monté l'accueil qu'après aurait fait exactement l'inverse : deux
/// secondes d'animation **puis** sept secondes d'attente.
///
/// **Elle se joue à chaque lancement**, comme celle de DewDrop, et une touche
/// saute l'attente. On ne la montre pas « une fois par jour » : une ouverture
/// d'application est un moment, et c'est le moment où le serveur est froid.
///
/// **Le plancher vaut cent millisecondes de plus que l'animation** pour qu'on
/// en voie la dernière image — le logo posé — plutôt que de la quitter sur sa
/// fin. Même écart que `HomeGate` chez DewDrop.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'intro_screen.dart';

class IntroGate extends StatefulWidget {
  const IntroGate({super.key, required this.child, this.playSound = true});

  /// L'accueil, monté sous l'intro dès le premier frame.
  final Widget child;

  /// Faux dans les tests, où l'audio n'existe pas.
  final bool playSound;

  @override
  State<IntroGate> createState() => _IntroGateState();
}

class _IntroGateState extends State<IntroGate> {
  bool _fini = false;
  Timer? _plancher;

  @override
  void initState() {
    super.initState();
    _plancher = Timer(introFloor, _decouvrir);
  }

  @override
  void dispose() {
    _plancher?.cancel();
    super.dispose();
  }

  void _decouvrir() {
    _plancher?.cancel();
    if (mounted && !_fini) setState(() => _fini = true);
  }

  @override
  Widget build(BuildContext context) {
    // **L'accueil reste dans l'arbre, toujours au même endroit.** Le retirer de
    // la pile plutôt que de le reconstruire garde son état et ses requêtes en
    // vol : rien ne repart de zéro quand l'intro s'efface.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_fini)
          IntroScreen(onTap: _decouvrir, playSound: widget.playSound),
      ],
    );
  }
}
