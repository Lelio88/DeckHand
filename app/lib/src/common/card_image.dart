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
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Rendu pendant le chargement, et à défaut d'[errorBuilder] en cas d'échec.
  final Widget? placeholder;

  final Widget Function(BuildContext context)? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final source = url;
    final blank = placeholder ?? const SizedBox.shrink();
    if (source == null || source.isEmpty) return blank;

    final preview = previewCardImage(source);
    if (preview == null) return _full(context, source, blank);

    // La vignette tient toute la place sous la grande : quand celle-ci arrive,
    // elle la recouvre exactement, sans que rien ne bouge.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: _Sharp(
            url: preview,
            fit: fit,
            // La vignette n'a pas d'espace réservé à elle : elle occupe celui
            // de la grande, sans quoi la case changerait de taille en cours de
            // chargement.
            placeholder: blank,
          ),
        ),
        _full(context, source, blank),
      ],
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

/// Fournisseur d'image qui regarde le disque avant le réseau.
///
/// Une sous-classe d'`ImageProvider` plutôt qu'un `FutureBuilder` : c'est ce
/// qui permet à l'`ImageCache` de Flutter de continuer à jouer son rôle en
/// mémoire par-dessus, sans décoder deux fois la même carte affichée sur deux
/// écrans.
@immutable
class CardImageProvider extends ImageProvider<CardImageProvider> {
  const CardImageProvider(this.url, {this.scale = 1.0});

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
