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
/// **Le son demande un clic, et l'aperçu le dit.** Un navigateur refuse de
/// démarrer l'audio avant un geste de l'utilisateur, et le refus est
/// *silencieux*. Comme l'animation démarre toute seule à l'ouverture, la
/// première lecture est muette — ce qui, dans l'outil qui sert justement à juger
/// le son, se lit comme « le son ne marche pas ». Le bandeau affiche donc l'état
/// de l'audio, n'importe quel clic le déverrouille, et le bouton **écouter**
/// rejoue dans la foulée. OBS, lui, n'a pas cette règle : une *browser source*
/// joue ses sons sans qu'on clique.
///
/// Usage :
///
///     cd app && flutter run -d chrome -t tool/apercu_montre.dart
library;

import 'dart:ui' as ui;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_request.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/card_back.dart';
import 'package:deckhand/src/features/binders/presentation/card_mat.dart';
import 'package:deckhand/src/features/binders/presentation/page_sound.dart';
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

  /// Le genre rejoué. Les trois se jugent côte à côte : c'est la seule façon
  /// de voir que la couverture se resserre quand il n'y a pas de carte à poser
  /// à droite, et que le tapis prend bien moins de place qu'une planche.
  _Genre _genre = _Genre.carte;
  AnimationController? _horloge;

  /// Le froissement des pages, comme en direct. **C'est ici qu'on l'entend** :
  /// le calque réel vit dans OBS, où l'on ne juge pas un son au casque. Un
  /// navigateur ordinaire n'ouvre l'audio qu'après un geste — les boutons de
  /// cet aperçu en font un.
  final RiffleSound _riffle = RiffleSound(createPageSound());

  /// Le vrai dos Magic, chargé chez Scryfall comme en direct.
  ui.Image? _back;

  @override
  void initState() {
    super.initState();
    _rejouer();
    loadCardBack(Game.magic).then((image) {
      if (mounted && image != null) setState(() => _back = image);
    });
  }

  @override
  void dispose() {
    _horloge?.dispose();
    _riffle.dispose();
    super.dispose();
  }

  /// Ce qu'on demande de montrer, selon le genre choisi.
  SpotlightRequest get _demande => switch (_genre) {
    _Genre.carte => _carte(_page),
    _Genre.page => SpotlightPage(
      requestId: _page,
      requestedBy: 'bob',
      setCode: 'msh',
      setName: 'Marvel Super Heroes',
      page: _page,
      pages: 51,
    ),
    _Genre.tapis => _tapis(),
  };

  /// Un tapis de quatre versions — le cas réel de la collection : quatre
  /// dessins de Forêt dans une même extension.
  SpotlightStrip _tapis() => SpotlightStrip(
    requestId: _page,
    requestedBy: 'carol',
    entries: [
      for (final cellule in _cases.take(4))
        SpotlightCard(
          requestId: _page,
          name: 'Forest',
          printedName: 'Forêt',
          setCode: 'msh',
          setName: 'Marvel Super Heroes',
          collectorNumber: cellule.collectorNumber,
          artCropUrl: cellule.artCropUrl,
          copies: 2,
        ),
    ],
  );

  /// La durée d'une apparition, quel qu'en soit le genre.
  double get _duree => switch (_demande) {
    final BinderRequest r => RevealTiming.of(r).total,
    final SpotlightStrip s => MatTiming(s.entries.length).total,
  };

  void _rejouer() {
    _horloge?.dispose();
    final demande = _demande;
    final horloge = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _duree.round()),
    );
    _riffle.restart();
    // Le froissement accompagne un feuilletage, pas un tapis.
    if (demande is BinderRequest) {
      final timing = RevealTiming.of(demande);
      horloge.addListener(
        () => _riffle.at(timing, horloge.value * timing.total),
      );
    }
    _horloge = horloge..forward();
    setState(() {});
  }

  void _choisir(int page) {
    _page = page;
    _rejouer();
  }

  void _basculer() {
    _genre = _Genre.values[(_genre.index + 1) % _Genre.values.length];
    _rejouer();
  }

  /// Ce que le bandeau dit de l'audio.
  String get _etatDuSon => switch (_riffle.status) {
    PageSoundStatus.silencieux => 'son indisponible hors navigateur',
    PageSoundStatus.attente => 'son : prêt au premier froissement',
    PageSoundStatus.suspendu => 'son : le navigateur attend un clic',
    PageSoundStatus.actif => 'son actif',
    PageSoundStatus.indisponible => 'son refusé par le navigateur',
  };

  @override
  Widget build(BuildContext context) {
    final horloge = _horloge;
    final demande = _demande;
    return Scaffold(
      // Un fond qui rappelle une image de caméra : le calque est transparent,
      // et le juger sur du blanc ne dit rien de ce qu'il donnera en direct.
      // **N'importe quel clic ouvre l'audio.** Le geste que le navigateur exige
      // n'a pas à être un geste *sur un bouton* : le lui donner au premier
      // contact évite d'expliquer une règle de navigateur dans une interface.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => setState(_riffle.unlock),
        child: DecoratedBox(
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
                        builder: (_, _) {
                          final ecoule = horloge.value * _duree;
                          return switch (demande) {
                            final BinderRequest r => BinderReveal(
                              request: r,
                              cells: _cases,
                              elapsed: ecoule,
                              sheetBack: _back,
                            ),
                            final SpotlightStrip s => CardMat(
                              strip: s,
                              elapsed: ecoule,
                            ),
                          };
                        },
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
                    _Bouton(
                      libelle: _genre.libelle,
                      actif: _genre != _Genre.carte,
                      onTap: _basculer,
                    ),
                    const SizedBox(width: 8),
                    _Bouton(
                      libelle: '↻ rejouer',
                      actif: false,
                      onTap: _rejouer,
                    ),
                    const SizedBox(width: 8),
                    _Bouton(
                      libelle: 'écouter',
                      actif: _riffle.status == PageSoundStatus.actif,
                      onTap: () {
                        _riffle.unlock();
                        _rejouer();
                      },
                    ),
                    const SizedBox(width: 14),
                    // **Le bandeau suit l'horloge**, et pas seulement les
                    // clics : `resume()` est asynchrone, si bien qu'un état lu
                    // juste après le geste dirait encore « suspendu ».
                    // Rafraîchi à chaque image, il dit la vérité.
                    AnimatedBuilder(
                      animation: horloge ?? kAlwaysCompleteAnimation,
                      builder: (_, _) => Text(
                        'intro ${_duree.round()} ms · $_etatDuSon',
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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

/// Les trois genres que le calque sait montrer.
enum _Genre {
  carte('carte'),
  page('page seule'),
  tapis('tapis');

  const _Genre(this.libelle);

  final String libelle;
}
