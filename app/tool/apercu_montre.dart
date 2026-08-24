/// Aperçu de l'animation de `!montre`, sans base ni compte (#21).
///
/// **À quoi ça sert.** Le classeur qui s'ouvre ne se juge pas sur des nombres :
/// il faut le voir. Le voir en conditions réelles suppose de publier sa
/// collection, de lancer le bot et de taper dans un chat — trois gestes dont le
/// premier laisse une trace si l'on interrompt la manœuvre. Cet aperçu rejoue
/// **le widget de production**, avec des données représentatives, et ne touche
/// à rien.
///
/// **Il n'est pas un jumeau.** Il importe `BinderReveal` tel quel : la
/// géométrie, le tempo et les couleurs qu'on regarde ici sont ceux du direct. Un
/// aperçu qui recopierait le dessin ne mesurerait que lui-même — c'est la faute
/// que ce projet a déjà payée sur `probe_photo` et `recette.dart`, deux bancs
/// qui gardaient leur copie de la règle et annonçaient autre chose que la
/// production.
///
/// **Trois pages, et c'est le point.** Le feuilletage dépend de la distance à
/// parcourir : la page 1 n'en a aucune, la page 12 en a une courte, la page 48
/// en frôle le plafond (1 128 ms sur 1 200). Les regarder l'une après l'autre est la seule façon de
/// juger si le plafond tombe au bon endroit.
///
/// L'illustration est chargée depuis Scryfall, exactement comme l'application le
/// fait en direct — rien n'est réhébergé (§IV.3). Hors ligne, la carte affiche
/// son numéro et l'animation reste lisible.
///
/// Usage :
///
///     cd app && flutter run -d chrome -t tool/apercu_montre.dart
library;

import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_card.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ApercuApp());

/// Les illustrations sont chargées chez Scryfall, exactement comme
/// l'application le fait en direct — rien n'est réhébergé (§IV.3). Hors ligne,
/// les cases restent lisibles : elles portent leur numéro.
const _art = 'https://cards.scryfall.io/art_crop/front';

/// La page 48 de Marvel Super Heroes, telle que la collection réelle la
/// contient : deux cases pleines, sept vides. C'est le cas qui a servi à
/// débusquer les défauts d'affichage — cases indiscernables, et halo qui
/// remplissait la case au lieu de la creuser.
final _cases = <BinderCell>[
  const BinderCell(
    collectorNumber: '424',
    owned: 0,
    artCropUrl: '$_art/8/8/881fc33a-e6be-4ae7-bd58-c342f6697b82.jpg',
  ),
  const BinderCell(
    collectorNumber: '425',
    owned: 0,
    artCropUrl: '$_art/d/5/d58da877-ef5e-45d2-8aa6-b8705e9028f2.jpg',
  ),
  const BinderCell(
    collectorNumber: '426',
    owned: 0,
    artCropUrl: '$_art/1/8/189121b1-b626-4c1a-96bd-4e6e4a50fe80.jpg',
  ),
  const BinderCell(
    collectorNumber: '427',
    owned: 0,
    artCropUrl: '$_art/d/d/ddf764b8-326c-4132-ba6e-93ce3bfea28e.jpg',
  ),
  const BinderCell(
    collectorNumber: '428',
    owned: 0,
    artCropUrl: '$_art/1/2/12828632-7738-46d8-9a13-5c1aa4e3c637.jpg',
  ),
  const BinderCell(
    collectorNumber: '429',
    owned: 0,
    artCropUrl: '$_art/5/8/5836c508-e8a4-467f-9da3-59e2b4aa3a01.jpg',
  ),
  const BinderCell(
    collectorNumber: '431',
    owned: 2,
    hasFoil: true,
    artCropUrl: '$_art/1/e/1e664025-b92c-4481-9778-d228e50a6d34.jpg',
  ),
  const BinderCell(
    collectorNumber: '432',
    owned: 1,
    hasFoil: true,
    artCropUrl: '$_art/a/5/a5f5730d-8c6b-4708-887d-9499439da4e7.jpg',
  ),
  const BinderCell(
    collectorNumber: '433',
    owned: 0,
    artCropUrl: '$_art/4/2/427edc1d-0c8c-4a63-9c86-e38afbe7d35f.jpg',
  ),
];

SpotlightCard _carte(int page) => SpotlightCard(
  requestId: page,
  name: 'Daredevil, Man Without Fear',
  printedName: 'Daredevil, Man Without Fear',
  requestedBy: 'alice',
  setCode: 'msh',
  setName: 'Marvel Super Heroes',
  collectorNumber: '432',
  artCropUrl: '$_art/a/5/a5f5730d-8c6b-4708-887d-9499439da4e7.jpg',
  priceEur: 0.39,
  copies: 1,
  page: page,
  slot: 8,
  pages: 51,
);

class ApercuApp extends StatelessWidget {
  const ApercuApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Aperçu — !montre',
    // **Le nuancier de l'application, et non un thème d'aperçu.** Le calque
    // prend ses couleurs de `Theme.of(context)` : un aperçu sous un autre thème
    // montrerait des couleurs que le direct n'aura jamais.
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFB8860B),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: const _Apercu(),
  );
}

class _Apercu extends StatefulWidget {
  const _Apercu();

  @override
  State<_Apercu> createState() => _ApercuState();
}

class _ApercuState extends State<_Apercu> with TickerProviderStateMixin {
  /// Les trois distances qui comptent : nulle, courte, et au plafond.
  static const _pages = [1, 12, 48];

  int _page = 48;
  AnimationController? _horloge;

  @override
  void initState() {
    super.initState();
    _rejouer();
  }

  @override
  void dispose() {
    _horloge?.dispose();
    super.dispose();
  }

  void _rejouer() {
    _horloge?.dispose();
    _horloge =
        AnimationController(
          vsync: this,
          duration: Duration(
            milliseconds: RevealTiming(_page).total.round(),
          ),
        )..forward();
    setState(() {});
  }

  void _choisir(int page) {
    _page = page;
    _rejouer();
  }

  @override
  Widget build(BuildContext context) {
    final horloge = _horloge;
    final carte = _carte(_page);
    return Scaffold(
      // Un fond qui rappelle une image de caméra : le calque est transparent,
      // et le juger sur du blanc ne dit rien de ce qu'il donnera en direct.
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3B3A45), Color(0xFF57452F), Color(0xFF1B1B22)],
            stops: [0, 0.45, 1],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: horloge == null
                  ? const SizedBox.shrink()
                  : AnimatedBuilder(
                      animation: horloge,
                      builder: (_, _) => BinderReveal(
                        card: carte,
                        cells: _cases,
                        elapsed:
                            horloge.value * RevealTiming(_page).total,
                      ),
                    ),
            ),
            Positioned(
              left: 20,
              top: 20,
              child: Row(
                children: [
                  for (final page in _pages) ...[
                    _Bouton(
                      libelle: 'page $page',
                      actif: page == _page,
                      onTap: () => _choisir(page),
                    ),
                    const SizedBox(width: 8),
                  ],
                  _Bouton(libelle: '↻ rejouer', actif: false, onTap: _rejouer),
                  const SizedBox(width: 14),
                  Text(
                    'intro ${RevealTiming(_page).total.round()} ms · '
                    'feuilletage ${RevealTiming(_page).riffle.round()} ms',
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bouton extends StatelessWidget {
  const _Bouton({
    required this.libelle,
    required this.actif,
    required this.onTap,
  });

  final String libelle;
  final bool actif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: actif ? const Color(0xFF2F3E7A) : const Color(0x33FFFFFF),
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Text(
          libelle,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    ),
  );
}
