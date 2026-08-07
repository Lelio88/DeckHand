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
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/card_name_text.dart';

class CardTextReader {
  CardTextReader();

  TextRecognizer? _recognizer;

  /// Vrai là où la reconnaissance de texte existe.
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Lit les lignes de texte de la photo désignée par [path].
  ///
  /// Renvoie une liste vide plutôt que de lever : une lecture infructueuse doit
  /// laisser la reconnaissance par illustration prendre le relais, pas faire
  /// échouer le scan entier.
  Future<List<ReadLine>> readLines(String path) async {
    if (!isSupported) return const [];

    try {
      final recognizer = _recognizer ??= TextRecognizer(
        script: TextRecognitionScript.latin,
      );
      final recognised = await recognizer.processImage(InputImage.fromFilePath(path));

      final height = _imageHeight(recognised);
      if (height <= 0) return const [];

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
