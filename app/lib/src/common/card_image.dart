/// L'image d'une carte, servie du disque quand elle y est déjà.
///
/// **Un seul point de passage pour toutes les images de cartes.** Elles étaient
/// affichées par huit `Image.network` répartis dans cinq fichiers, chacun avec
/// son propre traitement du chargement et de l'échec — et l'un d'eux sans
/// aucun : l'aperçu plein écran du classeur n'avait pas d'`errorBuilder`, si
/// bien qu'une image morte y laissait la zone d'exception de Flutter. Passer
/// par un widget unique donne la même réponse partout, et un seul endroit où
/// brancher le cache.
///
/// **Ce que le cache change.** Sans lui, l'`ImageCache` de Flutter — mémoire
/// seule, vidé à la fermeture — faisait retélécharger vingt-sept images à
/// chaque démarrage à froid pour une feuille de classeur et ses voisines. Voir
/// `image_store.dart` pour le pourquoi du dispositif, et pourquoi il ne coûte
/// aucune dépendance.
///
/// **L'ordre est : disque, puis réseau, puis écriture du disque.** Un défaut de
/// cache n'est jamais bloquant, et une erreur d'écriture ne se voit pas.
///
/// **Et la carte se montre avant d'être nette.** Scryfall sert la même carte en
/// 146 × 204 pour 14 Ko, contre 99,6 Ko en 488 × 680 : une feuille de classeur
/// devient donc lisible pour 126 Ko au lieu de 900, une double page pour 250 Ko
/// au lieu de 1,8 Mo. La petite s'affiche dès qu'elle arrive, la grande se pose
/// par-dessus quand elle est là. On ne troque rien : la version nette finit
/// toujours par s'afficher, elle cesse simplement d'être une condition pour
/// voir quelque chose.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'card_art_url.dart';
import 'package:http/http.dart' as http;

import '../config/request_timeout.dart';
import '../features/printings/domain/scryfall_image.dart';
import 'image_store.dart';

/// L'image d'une carte, ou son absence.
///
/// [placeholder] tient la place pendant le chargement **et** en cas d'échec :
/// c'est la réponse qu'attendaient déjà les vignettes — « l'absence d'image
/// n'est pas une panne, la liste doit rester lisible ». Les appelants qui
/// veulent distinguer les deux cas passent [errorBuilder].
class CardImage extends StatelessWidget {
  const CardImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorBuilder,
    this.uprightInCell = false,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Rendu pendant le chargement, et à défaut d'[errorBuilder] en cas d'échec.
  final Widget? placeholder;

  final Widget Function(BuildContext context)? errorBuilder;

  /// Tourne une carte **couchée** d'un quart de tour pour qu'elle remplisse une
  /// case debout — comme on glisse un Terrain dans une pochette de classeur.
  ///
  /// **Sans cela, [BoxFit.cover] n'en montre qu'une bande centrale.** Une carte
  /// couchée fait 1,4 fois plus large que haut, une case 0,72 : le recadrage
  /// jette les deux tiers de la largeur, et ce qui reste est moitié
  /// illustration moitié pavé de texte. Vérifié sur les deux jeux concernés —
  /// 64 champs de bataille Riftbound, 146 Terrains Wankul.
  ///
  /// **À n'activer que là où la carte doit remplir un emplacement debout.** En
  /// plein écran ou dans une ligne de liste, la tourner rendrait son texte
  /// illisible pour rien : l'espace y est libre.
  final bool uprightInCell;

  @override
  Widget build(BuildContext context) {
    final source = url;
    final blank = placeholder ?? const SizedBox.shrink();
    if (source == null || source.isEmpty) return blank;

    final preview = previewCardImage(source);
    final content = preview == null
        ? _full(context, source, blank)
        // La vignette tient toute la place sous la grande : quand celle-ci
        // arrive, elle la recouvre exactement, sans que rien ne bouge.
        : Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: _Sharp(
                  url: preview,
                  fit: fit,
                  // La vignette n'a pas d'espace réservé à elle : elle occupe
                  // celui de la grande, sans quoi la case changerait de taille
                  // en cours de chargement.
                  placeholder: blank,
                ),
              ),
              _full(context, source, blank),
            ],
          );

    if (!uprightInCell) return content;
    // **La vignette sert de sonde, pas la grande.** C'est elle qui s'affiche en
    // premier : mesurer la grande ferait pivoter la case sous les yeux au
    // moment où celle-ci arrive. Les deux paliers ont les mêmes proportions —
    // le contraire a été un défaut, corrigé et testé côté serveur.
    return UprightInCell(
      probe: CardImageProvider(preview ?? source),
      child: content,
    );
  }

  Widget _full(BuildContext context, String source, Widget blank) {
    return Image(
      image: CardImageProvider(source),
      width: width,
      height: height,
      fit: fit,
      // Une image déjà décodée s'affiche sans transition ; celle qui arrive du
      // réseau apparaît en fondu, pour que la grille ne clignote pas au
      // remplissage.
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 180),
          child: frame == null ? blank : child,
        );
      },
      errorBuilder: (context, _, _) => errorBuilder?.call(context) ?? blank,
    );
  }
}

/// La vignette seule, sans fondu ni repli bavard.
///
/// Elle n'a pas à annoncer son échec : la grande arrive derrière, et deux
/// messages d'erreur pour une même carte en feraient un défaut là où il n'y a
/// qu'une image de plus.
class _Sharp extends StatelessWidget {
  const _Sharp({
    required this.url,
    required this.fit,
    required this.placeholder,
  });

  final String url;
  final BoxFit fit;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) => Image(
    image: CardImageProvider(url),
    fit: fit,
    gaplessPlayback: true,
    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
        frame == null && !wasSynchronouslyLoaded ? placeholder : child,
    errorBuilder: (context, _, _) => placeholder,
  );
}

/// Tourne son contenu d'un quart de tour si l'image sondée est couchée.
///
/// **L'orientation se lit sur l'image, pas sur une colonne.** Le classeur ne
/// connaît de la carte que son URL ; faire descendre `cards.layout` jusqu'ici
/// aurait demandé un RPC, quatre classes du modèle et leurs tests, pour une
/// information que l'image porte déjà — et qu'elle porte *juste*, là où un
/// champ peut se désynchroniser. C'est aussi ce qui fait que Riftbound et
/// Wankul sont réglés du même geste, sans que ni l'un ni l'autre ne soit cité.
///
/// **Le sens du quart de tour n'est pas arbitraire** : c'est l'anti-horaire,
/// celui que le Wankuldex applique à ses propres vignettes de Terrain. Le texte
/// se lit alors de bas en haut, et la case reproduit exactement ce que montre
/// la source — donc ce à quoi l'utilisateur est habitué.
///
/// [RotatedBox] plutôt que [Transform.rotate] : il tourne pendant la
/// **mise en page** et échange donc les contraintes. L'image reçoit une boîte
/// couchée, la remplit, et le résultat retombe droit dans la case. Une rotation
/// à la peinture laisserait l'image se cadrer dans une boîte debout avant
/// d'être tournée, ce qui ne réglerait rien.
class UprightInCell extends StatefulWidget {
  const UprightInCell({super.key, required this.probe, required this.child});

  /// Image dont on mesure les proportions. Ce n'est pas forcément celle qu'on
  /// affiche : la sonde est la vignette légère, qui arrive la première.
  final ImageProvider<Object> probe;

  final Widget child;

  /// Quart de tour anti-horaire. `RotatedBox` compte dans le sens horaire.
  static const int quarterTurns = 3;

  @override
  State<UprightInCell> createState() => _UprightInCellState();
}

class _UprightInCellState extends State<UprightInCell> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _landscape = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(covariant UprightInCell old) {
    super.didUpdateWidget(old);
    if (old.probe != widget.probe) _listen();
  }

  void _listen() {
    final stream = widget.probe.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stop();
    final listener = ImageStreamListener(
      (info, _) {
        final landscape = info.image.width > info.image.height;
        // Le listener reçoit un clone dont il est propriétaire : ne pas le
        // libérer retiendrait la texture décodée aussi longtemps que la case.
        info.dispose();
        if (landscape != _landscape && mounted) {
          setState(() => _landscape = landscape);
        }
      },
      // Une sonde qui échoue laisse la carte droite : c'est l'état d'avant,
      // et la grande image, elle, s'affichera peut-être quand même.
      onError: (_, _) {},
    );
    _stream = stream..addListener(listener);
    _listener = listener;
  }

  void _stop() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _landscape
      ? RotatedBox(
          quarterTurns: UprightInCell.quarterTurns,
          child: widget.child,
        )
      : widget.child;
}

/// Fournisseur d'image qui regarde le disque avant le réseau.
///
/// Une sous-classe d'`ImageProvider` plutôt qu'un `FutureBuilder` : c'est ce
/// qui permet à l'`ImageCache` de Flutter de continuer à jouer son rôle en
/// mémoire par-dessus, sans décoder deux fois la même carte affichée sur deux
/// écrans.
@immutable
class CardImageProvider extends ImageProvider<CardImageProvider> {
  /// **L'URL est composée ici, et nulle part ailleurs.** C'est le point de
  /// passage unique de toute illustration affichée par l'application : la
  /// recherche, les classeurs, l'aperçu et le constructeur passent tous par ce
  /// fournisseur. Compléter au cas par cas aurait laissé un appelant derrière —
  /// et c'est précisément ce qui est arrivé aux 20 964 cartes Pokémon, dont
  /// aucune illustration ne s'affichait faute d'un suffixe que la source exige.
  CardImageProvider(String url, {this.scale = 1.0}) : url = cardArtUrl(url);

  final String url;
  final double scale;

  @override
  Future<CardImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CardImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    CardImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [ErrorDescription('URL : ${key.url}')],
    );
  }

  Future<ui.Codec> _load(
    CardImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final cached = await readCachedImage(key.url);
    if (cached != null) {
      return decode(await ui.ImmutableBuffer.fromUint8List(cached));
    }

    final bytes = await _download(key.url);
    // L'écriture ne retarde pas l'affichage : la carte est déjà décodable.
    unawaited(writeCachedImage(key.url, bytes));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<Uint8List> _download(String url) async {
    // Le même délai que les appels au serveur : une connexion morte ne rend ni
    // réponse ni erreur, et sans plafond la carte resterait grise pour
    // toujours. Voir `request_timeout.dart`.
    final response = await http.get(Uri.parse(url)).timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: Uri.parse(url),
      );
    }
    return response.bodyBytes;
  }

  @override
  bool operator ==(Object other) =>
      other is CardImageProvider && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'CardImageProvider("$url", scale: $scale)';
}

/// Amène une image en cache sans l'afficher.
///
/// **À quoi cela sert dans un classeur.** La feuille suivante n'est construite
/// qu'une fois le geste de retournement commencé : ses neuf images ne partent
/// donc qu'à cet instant, et la feuille se découvre vide. La précharger dès que
/// ses données arrivent la rend lisible au moment où elle apparaît.
///
/// **La vignette seulement.** Neuf cartes en taille normale font 900 Ko ; en
/// 146 × 204 elles font 126 Ko. Précharger les grandes rapatrierait près de
/// deux mégaoctets par déplacement — le remède serait pire que le mal. La
/// grande continue d'arriver derrière, comme sur la feuille courante.
///
/// Rien n'est attendu et rien n'échoue : une image qu'on n'a pas pu précharger
/// se téléchargera au moment de l'afficher, exactement comme avant.
void precacheCardPreview(String? url) {
  final preview = previewCardImage(url);
  if (preview == null || preview.isEmpty) return;

  // `resolve` suffit : il passe par [CardImageProvider], donc par le cache
  // disque, et dépose le résultat dans l'`ImageCache` de Flutter. Celui-ci
  // déduplique par clé, ce qui rend cet appel sans effet quand l'image est
  // déjà connue — on peut donc l'émettre à chaque reconstruction sans compter.
  final stream = CardImageProvider(preview).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) => stream.removeListener(listener),
    onError: (_, _) => stream.removeListener(listener),
  );
  stream.addListener(listener);
}
