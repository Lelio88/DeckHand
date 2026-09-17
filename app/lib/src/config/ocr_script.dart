/// Écriture que la reconnaissance de texte sait lire.
///
/// **Pourquoi c'est un réglage et non un défaut.** ML Kit n'a pas un modèle par
/// langue mais un par **écriture**, et les modèles non latins sont des
/// sur-ensembles du latin : `JapaneseTextRecognizerOptions` déclare
/// `LATIN_AND_JAPANESE`. On aurait donc pu livrer le japonais à tout le monde,
/// puisqu'il lit aussi le français et l'anglais — c'est l'hypothèse qui a été
/// posée, puis mesurée, puis écartée.
///
/// Le banc sur appareil, mêmes 41 photos sous les deux modèles, deux passages
/// chacun :
///
///     modèle      justes / 38   par le nom   la paire japonaise
///     latin            34            31     justes par l'illustration
///     japonais         33            30     justes PAR LE NOM, sans réserve
///
/// Le japonais gagne franchement sur les cartes qu'il vise — celle sous
/// pochette passe de trois candidats dont deux faux à **un seul, le bon** — et
/// perd **une carte couchée**, sur laquelle il ne lit qu'une ligne au lieu de
/// deux. Reproduit à l'identique aux deux passages : ce n'est pas du bruit.
///
/// Une carte couchée est fréquente dans un étalement, une carte japonaise est
/// rare. Imposer le japonais échangerait donc un cas courant contre un cas
/// rare, et c'est ce qui interdit d'en faire le défaut. D'où ce réglage : le
/// latin pour tout le monde, l'autre pour qui en a besoin.
///
/// **Chaque écriture ajoutée coûte une ligne dans
/// `android/app/build.gradle.kts`** — le greffon déclare les modèles non latins
/// en `compileOnly`, donc demander une écriture non empaquetée échoue à
/// l'exécution. Mesuré sur le bundle : le japonais pèse **1,2 Mo compressés**,
/// en *assets* et non en bibliothèques natives, donc livrés une fois quelle que
/// soit l'architecture. Les trois autres (chinoise, coréenne, devanagari)
/// s'ajouteraient de la même façon, une entrée ici et une ligne là.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Écritures proposées, c'est-à-dire celles dont le modèle est empaqueté.
///
/// L'identifiant est celui qui part en préférence ; le changer invaliderait les
/// choix déjà enregistrés, qui retomberaient silencieusement sur le latin.
enum OcrScript {
  latin(
    'latin',
    'Latine',
    'Français, anglais, allemand, italien, espagnol…',
  ),
  japanese(
    'japanese',
    'Japonaise',
    'Japonais et kanji — lit aussi l\'écriture latine',
  );

  const OcrScript(this.id, this.label, this.blurb);

  final String id;
  final String label;

  /// Ce que l'écriture couvre, dit à quelqu'un qui tient ses cartes en main.
  ///
  /// Le japonais mentionne qu'il lit **aussi** le latin : sans cela, le choisir
  /// ressemble à renoncer au français, et personne ne le cocherait.
  final String blurb;

  /// L'écriture portant cet identifiant, latin à défaut.
  ///
  /// Un identifiant inconnu — préférence d'une version plus récente, valeur
  /// corrompue — retombe sur le latin plutôt que de lever. Une reconnaissance
  /// muette serait presque invisible, le pipeline retombant sur l'illustration.
  static OcrScript fromId(String? id) =>
      OcrScript.values.firstWhere((s) => s.id == id, orElse: () => OcrScript.latin);
}

const _preferenceKey = 'ocr_script';

/// Écriture imposée à la compilation, pour le banc et lui seul.
///
/// **Le banc doit pouvoir comparer deux modèles sans qu'on touche à l'écran.**
/// `integration_test/plafond_reel_test.dart` monte son propre conteneur et
/// rejoue les mêmes photos ; lui faire naviguer dans les réglages entre deux
/// passages rendrait la mesure dépendante de l'interface qu'elle ne mesure pas.
///
/// Vide en production : le réglage reprend alors la main. Une valeur non vide
/// **court-circuite la préférence**, y compris un choix déjà enregistré — c'est
/// le but, et c'est pourquoi elle n'est pas un simple défaut.
///
/// ```
/// flutter test integration_test/plafond_reel_test.dart \
///     --dart-define=DECKHAND_OCR_SCRIPT=japanese ...
/// ```
const String _scriptImpose = String.fromEnvironment('DECKHAND_OCR_SCRIPT');

/// Écriture choisie, restaurée depuis les préférences.
///
/// Part sur [OcrScript.latin] puis se corrige dès que la préférence est lue —
/// même compromis que pour le jeu sélectionné : attendre la lecture ferait
/// clignoter l'application au démarrage, pour un réglage qui ne change presque
/// jamais et dont le cas majoritaire est justement le défaut.
class SelectedOcrScript extends Notifier<OcrScript> {
  @override
  OcrScript build() {
    if (_scriptImpose.isNotEmpty) return OcrScript.fromId(_scriptImpose);
    _restore();
    return OcrScript.latin;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = OcrScript.fromId(prefs.getString(_preferenceKey));
    if (saved != state) state = saved;
  }

  /// Change d'écriture et retient le choix.
  Future<void> select(OcrScript script) async {
    if (script == state) return;
    state = script;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, script.id);
  }
}

final selectedOcrScriptProvider = NotifierProvider<SelectedOcrScript, OcrScript>(
  SelectedOcrScript.new,
);
