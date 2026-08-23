/// Lecture du texte imprimé sur une carte.
///
/// S'appuie sur la reconnaissance de texte de ML Kit, **embarquée et hors
/// ligne** : aucune image ne quitte l'appareil, et la lecture fonctionne sans
/// réseau. Le modèle est empaqueté avec l'application.
///
/// **Pourquoi lire le nom alors qu'une empreinte d'illustration existe déjà.**
/// L'empreinte suppose deux choses qu'une photo à main levée ne garantit pas :
/// que l'illustration exacte figure dans l'index — un quart des rééditions
/// changent d'art — et que le cadrage soit juste à 2 ou 3 % près, soit deux
/// millimètres et demi sur la hauteur d'une carte. Le nom, lui, reste lisible
/// de travers, sous un reflet, et ne dépend d'aucune édition.
///
/// L'empreinte ne disparaît pas pour autant : elle départage les éditions, que
/// le nom ne distingue pas.
///
/// Indisponible sur le web, où ML Kit n'existe pas — [isSupported] permet à
/// l'appelant de retomber sur la seule empreinte.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/card_name_text.dart';

class CardTextReader {
  CardTextReader();

  TextRecognizer? _recognizer;

  /// Dimensions estimées de la dernière image lue, en pixels.
  ///
  /// **Uniquement pour la mesure.** Les positions des lignes sont relatives à
  /// ces bornes ; sans elles, impossible de les rapporter à la photo depuis un
  /// poste de travail — et donc de vérifier qu'on retrouve les bords d'une
  /// carte à partir de son nom.
  ({double width, double height})? lastImageSize;

  /// Vrai là où la reconnaissance de texte existe.
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Lit les lignes de texte d'une image venue du **flux caméra**.
  ///
  /// **Pourquoi le flux en a besoin.** Le mode vidéo n'identifie la carte que
  /// par son illustration, et cela plafonne : mesuré, une carte tenue à la main
  /// avec des reflets reste à 14 ou 19 bits de sa propre référence quand le
  /// seuil de confiance est à 12 — même avec un cadrage parfait. Le nom, lui,
  /// se lit malgré les reflets et ne dépend d'aucune édition. C'est l'ordre que
  /// le mode photo suit déjà.
  ///
  /// **Les octets sont lus là où ils sont.** [readLines] réclame un fichier ;
  /// en écrire un par image coûterait un aller-retour disque à trente images par
  /// seconde. ML Kit accepte un tampon brut, à condition de lui donner le format
  /// exact — d'où `nv21`, que la caméra sait produire directement et dont le
  /// premier plan reste la luminance que le reste du pipeline consomme.
  ///
  /// [rotationDegrees] est l'orientation du capteur : sans elle, ML Kit lit un
  /// texte couché et ne rend rien.
  Future<List<ReadLine>> readFrame(
    Uint8List bytes, {
    required int width,
    required int height,
    required int rotationDegrees,
    required int bytesPerRow,
  }) async {
    if (!isSupported) return const [];
    final rotation =
        InputImageRotationValue.fromRawValue(rotationDegrees) ??
        InputImageRotation.rotation0deg;
    return _lire(
      InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(width.toDouble(), height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: bytesPerRow,
        ),
      ),
    );
  }

  /// Lit les lignes de texte de la photo désignée par [path].
  ///
  /// Renvoie une liste vide plutôt que de lever : une lecture infructueuse doit
  /// laisser la reconnaissance par illustration prendre le relais, pas faire
  /// échouer le scan entier.
  Future<List<ReadLine>> readLines(String path) async {
    if (!isSupported) return const [];

    return _lire(InputImage.fromFilePath(path));
  }

  /// Le corps commun aux deux entrées : une image, des lignes.
  ///
  /// **Écrit une fois, appelé deux fois.** Le flux et la photo diffèrent par la
  /// façon d'atteindre les pixels, pas par ce qu'on en tire ; en dupliquer la
  /// lecture ferait diverger les deux modes en silence — c'est déjà arrivé aux
  /// bancs de ce projet.
  Future<List<ReadLine>> _lire(InputImage image) async {
    try {
      final recognizer = _recognizer ??= TextRecognizer(
        script: TextRecognitionScript.latin,
      );
      final recognised = await recognizer.processImage(image);

      final height = _imageHeight(recognised);
      if (height <= 0) return const [];
      final width = _imageWidth(recognised);
      lastImageSize = (width: width, height: height);

      return [
        for (final block in recognised.blocks)
          for (final line in block.lines)
            ReadLine(
              line.text,
              line.boundingBox.top / height,
              // La hauteur vient des coins, pas de la boîte : sur une carte
              // photographiée de travers, la boîte mesure la longueur de la
              // ligne bien plus que la taille de ses caractères.
              textHeightFromCorners(
                    line.cornerPoints,
                    line.boundingBox.height.toDouble(),
                  ) /
                  height,
              width <= 0 ? 0 : line.boundingBox.left / width,
              width <= 0 ? 0 : line.boundingBox.width / width,
            ),
      ];
    } on Object {
      return const [];
    }
  }

  /// Hauteur de l'image, déduite du texte lu.
  ///
  /// ML Kit ne la communique pas ; on la reconstitue à partir du bloc le plus
  /// bas. C'est une borne inférieure, donc les positions relatives sont
  /// légèrement surestimées — sans conséquence, la zone du nom étant large.
  double _imageHeight(RecognizedText recognised) {
    var lowest = 0;
    for (final block in recognised.blocks) {
      for (final line in block.lines) {
        final bottom = line.boundingBox.bottom.round();
        if (bottom > lowest) lowest = bottom;
      }
    }
    return lowest.toDouble();
  }

  /// Largeur de l'image, déduite du texte lu.
  ///
  /// Même approximation que pour la hauteur, et même raison : ML Kit ne
  /// communique pas les dimensions. C'est une borne inférieure, suffisante pour
  /// comparer des lignes entre elles.
  double _imageWidth(RecognizedText recognised) {
    var widest = 0;
    for (final block in recognised.blocks) {
      for (final line in block.lines) {
        final right = line.boundingBox.right.round();
        if (right > widest) widest = right;
      }
    }
    return widest.toDouble();
  }

  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}

final cardTextReaderProvider = Provider<CardTextReader>((ref) {
  final reader = CardTextReader();
  ref.onDispose(reader.dispose);
  return reader;
});
