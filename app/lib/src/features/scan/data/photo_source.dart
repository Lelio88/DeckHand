/// Obtention d'une photo de carte, cadrée par l'utilisateur.
///
/// **Pourquoi un recadrage explicite.** La reconnaissance découpe l'illustration
/// à une position fixe dans l'image — le gabarit suppose donc que l'image *est*
/// la carte. Une photo prise à main levée ne l'est jamais : il y a la table
/// autour, un angle, un cadrage approximatif. Sans recadrage, l'illustration est
/// prélevée au mauvais endroit et la reconnaissance échoue pour une raison qui
/// n'a rien à voir avec la qualité de l'empreinte — le pire des diagnostics,
/// puisqu'il fait accuser l'algorithme.
///
/// Le rapport largeur/hauteur est **verrouillé sur celui d'une carte Magic**.
/// L'utilisateur ne peut donc pas produire un cadre aberrant ; il lui reste à
/// poser les bords sur ceux de la carte, ce qu'un rectangle contraint rend
/// naturel.
///
/// Mesure faite depuis : ce recadrage ne suffit pas. L'empreinte d'illustration
/// décroche au-delà de 3 % d'écart, soit deux millimètres et demi — une
/// précision qu'aucun cadrage à main levée n'atteint. D'où la lecture du nom,
/// qui exige le **chemin du fichier** et non ses octets : c'est pourquoi la
/// capture renvoie les deux.
///
/// **Le recadrage est devenu facultatif.** Le nom se lit sur une photo large ;
/// exiger un cadrage à chaque carte coûtait un geste supplémentaire par carte,
/// soit des centaines pour une collection. Il reste proposé en seconde chance
/// quand la lecture échoue : l'empreinte prend alors le relais, et elle, exige
/// ce cadrage.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/card_geometry.dart';

/// Photo cadrée, sous ses deux formes.
///
/// Les octets alimentent le calcul d'empreinte, le chemin la lecture du texte —
/// ML Kit lit un fichier, pas un tampon mémoire.
class CapturedPhoto {
  const CapturedPhoto({required this.bytes, required this.path});

  final Uint8List bytes;
  final String path;
}

/// Hauteur de référence du cadre de recadrage.
///
/// Le paquet de recadrage attend deux nombres plutôt qu'un rapport ; on fixe
/// donc la hauteur et on en déduit la largeur, ce qui revient au même et évite
/// de garder ici une seconde écriture des proportions d'une carte.
const _cropFrameHeight = 88.0;

class PhotoSource {
  const PhotoSource();

  /// Prend ou choisit une photo, puis la fait cadrer sur la carte.
  ///
  /// Renvoie `null` si l'utilisateur renonce, à la prise de vue comme au
  /// recadrage — un abandon n'est pas une erreur et ne doit rien afficher.
  /// [webContext] n'est utilisé que par la variante web du paquet de recadrage,
  /// qui exige un `BuildContext` pour afficher sa boîte de dialogue. Ailleurs il
  /// reste nul, et aucune couche de données ne dépend de l'arbre de widgets.
  /// [game] décide des proportions du cadre imposé à l'utilisateur. **Ce n'est
  /// pas un détail d'affichage** : ce cadre est ce que l'empreinte lira, et un
  /// rapport emprunté à un autre jeu déplacerait la zone d'illustration
  /// exactement comme le ferait un cadrage de travers. La reconnaissance
  /// échouerait sans que rien ne l'explique.
  Future<CapturedPhoto?> capture({
    required ImageSource source,
    required Color toolbarColor,
    required Color toolbarWidgetColor,
    BuildContext? webContext,
    bool crop = false,
    String game = 'magic',
  }) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      // Au-delà, on transporte des pixels que l'empreinte n'exploitera jamais :
      // elle réduit l'illustration à une grille de 9 × 8.
      maxWidth: 1600,
      imageQuality: 92,
    );
    if (picked == null) return null;

    if (!crop) {
      return CapturedPhoto(
        bytes: await picked.readAsBytes(),
        path: picked.path,
      );
    }

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: CropAspectRatio(
        ratioX: _cropFrameHeight * cardAspectFor(game),
        ratioY: _cropFrameHeight,
      ),
      compressFormat: ImageCompressFormat.png,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Cadrez la carte',
          toolbarColor: toolbarColor,
          toolbarWidgetColor: toolbarWidgetColor,
          initAspectRatio: CropAspectRatioPreset.original,
          // Verrouillé : un cadre aux mauvaises proportions déplacerait la zone
          // d'illustration et ferait échouer la reconnaissance.
          lockAspectRatio: true,
          hideBottomControls: true,
        ),
        IOSUiSettings(
          title: 'Cadrez la carte',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
        // `mounted` est vérifié parce que la prise de vue précède ce point :
        // l'écran peut avoir été quitté entre-temps.
        if (webContext != null && webContext.mounted)
          WebUiSettings(
            context: webContext,
            presentStyle: WebPresentStyle.dialog,
          ),
      ],
    );
    if (cropped == null) return null;

    return CapturedPhoto(
      bytes: await cropped.readAsBytes(),
      path: cropped.path,
    );
  }
}

final photoSourceProvider = Provider<PhotoSource>((ref) => const PhotoSource());
